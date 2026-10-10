-- Migration 41: line rate ranges on all three invoice save paths, one invoice
-- per dispatch line, billable days counted between dates in India, the
-- append-only discount history, white-space-only reasons, the discount record
-- in get_invoice_detail, line amounts in get_invoice_items_detailed and the
-- payment guard of delete_invoice. Fictional data; runs only in migrations.sh's
-- disposable, network-disabled database (session time zone UTC).
\set ON_ERROR_STOP on
BEGIN;
CREATE FUNCTION pg_temp.rule_assert(ok boolean, label text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF NOT COALESCE(ok,false) THEN RAISE EXCEPTION 'invoice line rules: %',label; END IF; END $$;
-- True when the statement raises an error whose text matches the pattern.
CREATE FUNCTION pg_temp.rule_raises(statement text, pattern text) RETURNS boolean LANGUAGE plpgsql AS $$
BEGIN
  BEGIN EXECUTE statement; EXCEPTION WHEN OTHERS THEN RETURN SQLERRM LIKE pattern; END;
  RETURN false;
END $$;
-- The same lines with other rates.
CREATE FUNCTION pg_temp.rule_rates(items jsonb, rates jsonb) RETURNS jsonb LANGUAGE sql AS $$
  SELECT jsonb_agg(item || rates) FROM jsonb_array_elements(items) AS item $$;
-- The three save paths with one argument shape. A refused save answers
-- success=false; the one-argument path wraps the reason in "Database error: ...".
CREATE FUNCTION pg_temp.rule_save1(header jsonb, items jsonb) RETURNS jsonb LANGUAGE sql AS $$
  SELECT public.save_invoice(header || jsonb_build_object('items',items)) $$;
CREATE FUNCTION pg_temp.rule_save3(header jsonb, items jsonb) RETURNS jsonb LANGUAGE sql AS $$
  SELECT public.save_invoice(NULL::uuid, header, ARRAY(SELECT jsonb_array_elements(items))) $$;
CREATE FUNCTION pg_temp.rule_update(invoice uuid, header jsonb, items jsonb) RETURNS jsonb LANGUAGE sql AS $$
  SELECT public.update_invoice(invoice, header, ARRAY(SELECT jsonb_array_elements(items))) $$;
CREATE FUNCTION pg_temp.rule_refused(answer jsonb, reason text) RETURNS boolean LANGUAGE sql AS $$
  SELECT answer->>'success'='false' AND answer->>'error' LIKE '%' || reason || '%' $$;
CREATE FUNCTION pg_temp.rule_login(phone text) RETURNS jsonb LANGUAGE plpgsql AS $$
 DECLARE c jsonb; l jsonb; claims jsonb;
 BEGIN
  c:=public.operator_prepare_otp(phone);
  PERFORM pg_temp.rule_assert(c->>'success'='true','challenge prepared for '||phone);
  PERFORM public.operator_finish_otp((c#>>'{data,request_id}')::uuid,true,'mock-provider-only');
  l:=public.operator_verify_otp(phone,c#>>'{data,otp_code}');
  PERFORM pg_temp.rule_assert(l#>>'{data,action}'='login','login for '||phone);
  SELECT jsonb_build_object('role','authenticated','sub',p.auth_user_id,'session_id',r.id) INTO claims
   FROM public.user_profiles p JOIN warehouse_security.refresh_sessions r ON r.user_id=p.auth_user_id
   WHERE p.mobile=warehouse_security.normalize_phone(phone) ORDER BY r.created_at DESC LIMIT 1;
  RETURN claims;
 END $$;
INSERT INTO warehouse_security.auth_config(key,value) VALUES
 ('jwt_secret','isolated-test-secret-not-for-any-deployment-12345'),
 ('auth_mode','operator'),('demo_auth_enabled','false')
 ON CONFLICT(key) DO UPDATE SET value=excluded.value;
UPDATE public.sms_config SET provider='msg91',production_mode=true,msg91_auth_key='isolated-test-key',
 msg91_template_id='000000000000000000000001',msg91_pe_id='0000000000000000001',msg91_sender_id='CITEST'
 WHERE id=(SELECT id FROM public.sms_config ORDER BY id DESC LIMIT 1);
SELECT pg_temp.rule_assert(current_setting('TimeZone')='UTC','the session time zone is UTC, so a date cast in it differs from India''s date');
SELECT warehouse_security.bootstrap_first_admin('9888888861','Line Rule Administrator') AS admin_user \gset
SELECT id AS admin_profile FROM public.user_profiles WHERE auth_user_id=:'admin_user'::uuid \gset
INSERT INTO public.user_profiles(auth_user_id,mobile,name,role,active,enrollment_status) VALUES
 (gen_random_uuid(),'919888888862','Line Rule Staff','staff',true,'approved'),
 (gen_random_uuid(),'919888888863','Line Rule Customer Reader','customer',true,'approved');
SELECT id AS staff_profile FROM public.user_profiles WHERE mobile='919888888862' \gset
SELECT pg_temp.rule_login('9888888861') AS admin_claims \gset
SELECT pg_temp.rule_login('9888888862') AS staff_claims \gset
SELECT pg_temp.rule_login('9888888863') AS customer_claims \gset

-- Fixture, as the administrator. Price 5 per bag, labour 2, tax 5%.
--   RULA  monthly, 100 bags received 2026-04-01, dispatched 20 + 80 on
--         2026-05-02: the INVOICE_RULES fixture, total 998
--   RULB  one-time, 20 bags
--   RULC  monthly, 10 bags received 2026-04-01 02:00 in India, which is
--         2026-03-31 20:30 UTC, dispatched 2026-05-01: 30 days, one period
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.rule_assert(public.create_customer('Line Rule Customer','9888888864')->>'success'='true','customer');
SELECT pg_temp.rule_assert(public.create_item('Line Rule Potatoes','Bag')->>'success'='true','catalog item');
SELECT id AS customer_id FROM public.customers WHERE name='Line Rule Customer' \gset
SELECT id AS item_id FROM public.items WHERE name='Line Rule Potatoes' \gset
SELECT pg_temp.rule_assert(public.create_item_storage_price(p_item_id=>:'item_id'::uuid,p_price_type=>'monthly',p_unit_price=>5,
 p_weight_min=>0,p_weight_max=>100,p_labour_rate=>2,p_effective_from=>'2026-01-01',
 p_customer_id=>:'customer_id'::uuid,p_tax_percent=>5)->>'success'='true','monthly price');
SELECT pg_temp.rule_assert(public.save_grn(p_gr_no=>'RULA',p_date=>'2026-04-01T12:00:00Z',p_customer_id=>:'customer_id'::uuid,
 p_customer_name=>'Line Rule Customer',p_pricing_mode=>'MONTHLY',p_idempotency_key=>'line-rule-a',
 p_items=>jsonb_build_array(jsonb_build_object('item_id',:'item_id','item_name','Line Rule Potatoes',
 'packaging','Bag','qty',100,'weight',10,'rack','R1')))->>'success'='true','receipt RULA');
SELECT pg_temp.rule_assert(public.save_grn(p_gr_no=>'RULB',p_date=>'2026-04-01T12:00:00Z',p_customer_id=>:'customer_id'::uuid,
 p_customer_name=>'Line Rule Customer',p_pricing_mode=>'ONE_TIME',p_idempotency_key=>'line-rule-b',
 p_items=>jsonb_build_array(jsonb_build_object('item_id',:'item_id','item_name','Line Rule Potatoes',
 'packaging','Bag','qty',20,'weight',10,'rack','R2')))->>'success'='true','receipt RULB');
SELECT pg_temp.rule_assert(public.save_grn(p_gr_no=>'RULC',p_date=>'2026-03-31T20:30:00Z',p_customer_id=>:'customer_id'::uuid,
 p_customer_name=>'Line Rule Customer',p_pricing_mode=>'MONTHLY',p_idempotency_key=>'line-rule-c',
 p_items=>jsonb_build_array(jsonb_build_object('item_id',:'item_id','item_name','Line Rule Potatoes',
 'packaging','Bag','qty',10,'weight',10,'rack','R3')))->>'success'='true','receipt RULC');
SELECT id AS grn_a FROM public.goodsreceived WHERE gr_no='RULA' \gset
SELECT id AS grn_b FROM public.goodsreceived WHERE gr_no='RULB' \gset
SELECT id AS grn_c FROM public.goodsreceived WHERE gr_no='RULC' \gset
SELECT id AS lot_a FROM public.goodsreceived_trl WHERE gr_id=:'grn_a'::uuid \gset
SELECT id AS lot_b FROM public.goodsreceived_trl WHERE gr_id=:'grn_b'::uuid \gset
SELECT id AS lot_c FROM public.goodsreceived_trl WHERE gr_id=:'grn_c'::uuid \gset
SELECT jsonb_build_object('customer_id',:'customer_id','customer_name','Line Rule Customer',
 'supervisor_id',:'admin_profile','supervisor_name','Line Rule Administrator') AS dispatch_for \gset
SELECT pg_temp.rule_assert(public.create_dispatch_with_stock_check(:'dispatch_for'::jsonb || '{"disp_no":"RULA1","disp_date":"2026-05-02"}'::jsonb,
 ARRAY[jsonb_build_object('gr_trl_id',:'lot_a','disp_qty',20)],0,'line-rule-a1')->>'success'='true','RULA first dispatch');
SELECT pg_temp.rule_assert(public.create_dispatch_with_stock_check(:'dispatch_for'::jsonb || '{"disp_no":"RULA2","disp_date":"2026-05-02"}'::jsonb,
 ARRAY[jsonb_build_object('gr_trl_id',:'lot_a','disp_qty',80)],0,'line-rule-a2')->>'success'='true','RULA final dispatch');
SELECT pg_temp.rule_assert(public.create_dispatch_with_stock_check(:'dispatch_for'::jsonb || '{"disp_no":"RULB1","disp_date":"2026-05-02"}'::jsonb,
 ARRAY[jsonb_build_object('gr_trl_id',:'lot_b','disp_qty',20)],0,'line-rule-b1')->>'success'='true','RULB dispatch');
SELECT pg_temp.rule_assert(public.create_dispatch_with_stock_check(:'dispatch_for'::jsonb || '{"disp_no":"RULC1","disp_date":"2026-05-01"}'::jsonb,
 ARRAY[jsonb_build_object('gr_trl_id',:'lot_c','disp_qty',10)],0,'line-rule-c1')->>'success'='true','RULC dispatch');
RESET ROLE;
-- Lines with the price-list rates, in the shape every path accepts, and a
-- header per receipt. Client totals are ignored by the server.
SELECT jsonb_agg(jsonb_build_object('disp_trl_id',t.id,'grn_item_id',t.gr_trl_id,'duration',1,'charge',5,'tax',5,'labour_rate',2) ORDER BY t.disp_qty) AS a_items
 FROM public.dispatch_trl t WHERE t.gr_id=:'grn_a'::uuid \gset
SELECT jsonb_agg(jsonb_build_object('disp_trl_id',t.id,'grn_item_id',t.gr_trl_id,'duration',1,'charge',5,'tax',5,'labour_rate',2)) AS b_items
 FROM public.dispatch_trl t WHERE t.gr_id=:'grn_b'::uuid \gset
SELECT jsonb_agg(jsonb_build_object('disp_trl_id',t.id,'grn_item_id',t.gr_trl_id,'duration',1,'charge',5,'tax',5,'labour_rate',2)) AS c_items
 FROM public.dispatch_trl t WHERE t.gr_id=:'grn_c'::uuid \gset
SELECT jsonb_build_object('inv_fin_year',2026,'customer_id',:'customer_id','customer_name','Line Rule Customer',
 'inv_date','2026-05-02T12:00:00Z','total',0,'tax_amount',0,'labour',0,'discount',0,'duration_mode','legacy') AS header \gset
SELECT :'header'::jsonb || jsonb_build_object('gr_id',:'grn_a','gr_no','RULA') AS a_header \gset
SELECT :'header'::jsonb || jsonb_build_object('gr_id',:'grn_b','gr_no','RULB') AS b_header \gset
SELECT :'header'::jsonb || jsonb_build_object('gr_id',:'grn_c','gr_no','RULC') AS c_header \gset

-- 1. Line rates out of range are refused on both save paths, as staff. Nothing
-- is saved and the receipt stays uninvoiced.
SELECT set_config('request.jwt.claims',:'staff_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.rule_assert(warehouse_security.active_role()='staff','actual staff role');
SELECT pg_temp.rule_assert(pg_temp.rule_refused(pg_temp.rule_save1(:'a_header'::jsonb || '{"inv_no":20261041}'::jsonb,
 pg_temp.rule_rates(:'a_items'::jsonb,'{"labour_rate":-7.5}'::jsonb)),'Invoice line labour rate must be between 0 and 999999'),'one-argument save: negative labour rate refused');
SELECT pg_temp.rule_assert(pg_temp.rule_refused(pg_temp.rule_save1(:'a_header'::jsonb || '{"inv_no":20261041}'::jsonb,
 pg_temp.rule_rates(:'a_items'::jsonb,'{"tax":-100}'::jsonb)),'Invoice line tax must be between 0 and 100'),'one-argument save: negative tax refused');
SELECT pg_temp.rule_assert(pg_temp.rule_refused(pg_temp.rule_save1(:'a_header'::jsonb || '{"inv_no":20261041}'::jsonb,
 pg_temp.rule_rates(:'a_items'::jsonb,'{"tax":100.01}'::jsonb)),'Invoice line tax must be between 0 and 100'),'one-argument save: tax above 100 refused');
SELECT pg_temp.rule_assert(pg_temp.rule_refused(pg_temp.rule_save1(:'a_header'::jsonb || '{"inv_no":20261041}'::jsonb,
 pg_temp.rule_rates(:'a_items'::jsonb,'{"charge":-5}'::jsonb)),'Invoice line charge must be between 0 and 999999'),'one-argument save: negative charge refused');
SELECT pg_temp.rule_assert(pg_temp.rule_refused(pg_temp.rule_save1(:'a_header'::jsonb || '{"inv_no":20261041}'::jsonb,
 pg_temp.rule_rates(:'a_items'::jsonb,'{"charge":1000000}'::jsonb)),'Invoice line charge must be between 0 and 999999'),'one-argument save: absurd charge refused');
SELECT pg_temp.rule_assert(pg_temp.rule_refused(pg_temp.rule_save1(:'a_header'::jsonb || '{"inv_no":20261041}'::jsonb,
 pg_temp.rule_rates(:'a_items'::jsonb,'{"labour_rate":1000000}'::jsonb)),'Invoice line labour rate must be between 0 and 999999'),'one-argument save: absurd labour rate refused');
SELECT pg_temp.rule_save3(:'a_header'::jsonb || '{"inv_no":20261041}'::jsonb,pg_temp.rule_rates(:'a_items'::jsonb,'{"charge":-5}'::jsonb)) AS three_charge \gset
SELECT pg_temp.rule_assert(:'three_charge'::jsonb->>'success'='false','three-argument save: negative charge refused: ' || :'three_charge');
SELECT pg_temp.rule_assert(pg_temp.rule_refused(pg_temp.rule_save3(:'a_header'::jsonb || '{"inv_no":20261041}'::jsonb,
 pg_temp.rule_rates(:'a_items'::jsonb,'{"labour_rate":-2}'::jsonb)),'Invoice line labour rate must be between 0 and 999999'),'three-argument save: negative labour rate refused');
SELECT pg_temp.rule_assert(pg_temp.rule_refused(pg_temp.rule_save3(:'a_header'::jsonb || '{"inv_no":20261041}'::jsonb,
 pg_temp.rule_rates(:'a_items'::jsonb,'{"tax":-1}'::jsonb)),'Invoice line tax must be between 0 and 100'),'three-argument save: negative tax refused');
SELECT pg_temp.rule_assert(pg_temp.rule_refused(pg_temp.rule_save3(:'a_header'::jsonb || '{"inv_no":20261041}'::jsonb,
 pg_temp.rule_rates(:'a_items'::jsonb,'{"labour_rate":1000000}'::jsonb)),'Invoice line labour rate must be between 0 and 999999'),'three-argument save: absurd labour rate refused');
RESET ROLE;
SELECT pg_temp.rule_assert((SELECT count(*)=0 FROM public.invoice WHERE customer_id=:'customer_id'::uuid),'refused saves leave no invoice');
SELECT pg_temp.rule_assert((SELECT invoiced IS NOT TRUE FROM public.goodsreceived WHERE id=:'grn_a'::uuid),'refused saves leave the receipt uninvoiced');

-- Zero rates stay a permitted input on the one-argument path: total 0, no
-- discount, so no discount record either.
SET LOCAL ROLE authenticated;
SELECT pg_temp.rule_save1(:'a_header'::jsonb || '{"inv_no":20261041}'::jsonb,
 pg_temp.rule_rates(:'a_items'::jsonb,'{"charge":0,"labour_rate":0,"tax":0}'::jsonb)) AS zero \gset
SELECT pg_temp.rule_assert(:'zero'::jsonb->>'success'='true','one-argument save: zero rates accepted: ' || :'zero');
SELECT (:'zero'::jsonb->>'invoice_id') AS zero_invoice \gset
RESET ROLE;
SELECT pg_temp.rule_assert((SELECT total=0 AND tax_amount=0 AND labour=0 AND discount=0 AND discount_reason IS NULL AND discount_set_by IS NULL
 FROM public.invoice WHERE id=:'zero_invoice'::uuid),'zero rates give a zero invoice with no discount record');
SELECT pg_temp.rule_assert((SELECT invoiced FROM public.goodsreceived WHERE id=:'grn_a'::uuid),'the receipt is now invoiced');

-- 2. The receipt is invoiced, so a second invoice under a new number is
-- refused on both save paths, as staff.
SET LOCAL ROLE authenticated;
SELECT pg_temp.rule_assert(pg_temp.rule_refused(pg_temp.rule_save1(:'a_header'::jsonb || '{"inv_no":20261042}'::jsonb,:'a_items'::jsonb),
 'GRN is already invoiced'),'one-argument save: an invoiced receipt is refused');
SELECT pg_temp.rule_save3(:'a_header'::jsonb || '{"inv_no":20261042}'::jsonb,:'a_items'::jsonb) AS second_three \gset
SELECT pg_temp.rule_assert(:'second_three'::jsonb->>'success'='false' AND :'second_three'::jsonb->>'error'='GRN is already invoiced'
 AND :'second_three'::jsonb->>'error_code'='WH409','three-argument save: an invoiced receipt is refused: ' || :'second_three');
RESET ROLE;
-- The lines are checked on their own account: with the flag cleared behind the
-- invoice's back, a line that is on a live invoice is still refused, alone too.
UPDATE public.goodsreceived SET invoiced=false WHERE id=:'grn_a'::uuid;
SET LOCAL ROLE authenticated;
SELECT pg_temp.rule_assert(pg_temp.rule_refused(pg_temp.rule_save1(:'a_header'::jsonb || '{"inv_no":20261042}'::jsonb,:'a_items'::jsonb),
 'A dispatch line is already on another invoice'),'one-argument save: a line on another invoice is refused');
SELECT pg_temp.rule_save3(:'a_header'::jsonb || '{"inv_no":20261042}'::jsonb,:'a_items'::jsonb) AS line_three \gset
SELECT pg_temp.rule_assert(:'line_three'::jsonb->>'success'='false' AND :'line_three'::jsonb->>'error'='A dispatch line is already on another invoice',
 'three-argument save: a line on another invoice is refused: ' || :'line_three');
RESET ROLE;
SELECT pg_temp.rule_assert((SELECT count(*)=1 FROM public.invoice WHERE gr_id=:'grn_a'::uuid),'the receipt still has one invoice');
SELECT pg_temp.rule_assert((SELECT count(*)=2 FROM public.invoice_trl t JOIN public.dispatch_trl d ON d.id=t.disp_trl_id WHERE d.gr_id=:'grn_a'::uuid),
 'each dispatch line is on one invoice');
SELECT pg_temp.rule_assert((SELECT invoiced IS NOT TRUE FROM public.goodsreceived WHERE id=:'grn_a'::uuid),'a refused save does not mark the receipt');
UPDATE public.goodsreceived SET invoiced=true WHERE id=:'grn_a'::uuid;

-- Deleting the invoice (administrator) frees the receipt and its lines; staff
-- then invoices it again through the three-argument path with the fixture total.
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.rule_assert(public.delete_invoice(:'zero_invoice'::uuid)->>'success'='true','administrator deletes the zero invoice');
SELECT set_config('request.jwt.claims',:'staff_claims',true);
SELECT pg_temp.rule_save3(:'a_header'::jsonb || '{"inv_no":20261043}'::jsonb,:'a_items'::jsonb) AS again \gset
SELECT pg_temp.rule_assert(:'again'::jsonb->>'success'='true','the receipt is invoiced again after the delete: ' || :'again');
SELECT (:'again'::jsonb->>'invoice_id') AS invoice_a \gset
RESET ROLE;
SELECT pg_temp.rule_assert((SELECT total=998 AND tax_amount=48 AND labour=200 FROM public.invoice WHERE id=:'invoice_a'::uuid),'the new invoice has the fixture total 998');
SELECT pg_temp.rule_assert((SELECT bool_and(no_of_days=31 AND duration=1.5) AND count(*)=2 FROM public.invoice_trl WHERE invoice_id=:'invoice_a'::uuid),
 'the fixture dates still give 31 days and 1.5 periods');
SELECT pg_temp.rule_assert((SELECT invoiced FROM public.goodsreceived WHERE id=:'grn_a'::uuid),'and the receipt is invoiced');
SELECT pg_temp.rule_assert((SELECT count(*)=0 FROM public.invoice_discount_history),'no discount has changed so far');

-- 3. Billable days between dates in India. RULC was received at 02:00 on
-- 1 April in India (20:30 UTC on 31 March) and left on 1 May: 30 days, one
-- period, 10 x 5 + 10 x 2 = 70, tax 3.5 -> 4, total 74. Counted in UTC it was
-- 31 days, 1.5 periods and total 100.
SELECT pg_temp.rule_assert(warehouse_security.business_date('2026-03-31T18:30:00Z')='2026-04-01'
 AND warehouse_security.business_date('2026-03-31T18:29:59Z')='2026-03-31','midnight in India is 18:30 UTC');
SET LOCAL TIME ZONE 'America/Los_Angeles';
SELECT pg_temp.rule_assert(warehouse_security.business_date('2026-03-31T18:30:00Z')='2026-04-01','the session time zone does not move the date');
SET LOCAL TIME ZONE 'UTC';
SET LOCAL ROLE authenticated;
SELECT public.generate_invoice_data_for_grn_with_pricing(p_gr_id=>:'grn_c'::uuid,p_duration_mode=>'legacy') AS preview_c \gset
SELECT pg_temp.rule_assert(:'preview_c'::jsonb->>'success'='true' AND (:'preview_c'::jsonb#>>'{rows,0,no_of_days}')::int=30
 AND (:'preview_c'::jsonb#>>'{rows,0,duration}')::numeric=1 AND (:'preview_c'::jsonb#>>'{totals,grand_total}')::numeric=74,
 'preview: 30 days, one period, total 74: ' || (:'preview_c'::jsonb->'totals')::text);
SELECT pg_temp.rule_save3(:'c_header'::jsonb || '{"inv_no":20261044}'::jsonb,:'c_items'::jsonb) AS saved_c \gset
SELECT pg_temp.rule_assert(:'saved_c'::jsonb->>'success'='true','three-argument save of RULC: ' || :'saved_c');
SELECT (:'saved_c'::jsonb->>'invoice_id') AS invoice_c \gset
RESET ROLE;
SELECT pg_temp.rule_assert((SELECT no_of_days=30 AND duration=1 FROM public.invoice_trl WHERE invoice_id=:'invoice_c'::uuid),'three-argument save: 30 days, one period');
SELECT pg_temp.rule_assert((SELECT total=74 AND tax_amount=4 AND labour=20 FROM public.invoice WHERE id=:'invoice_c'::uuid),'three-argument save: total 74');
SET LOCAL ROLE authenticated;
SELECT pg_temp.rule_assert(pg_temp.rule_update(:'invoice_c'::uuid,:'c_header'::jsonb || '{"inv_no":20261044,"notes":"edited"}'::jsonb,:'c_items'::jsonb)->>'success'='true','edit of RULC');
RESET ROLE;
SELECT pg_temp.rule_assert((SELECT no_of_days=30 AND duration=1 FROM public.invoice_trl WHERE invoice_id=:'invoice_c'::uuid)
 AND (SELECT total=74 AND notes='edited' FROM public.invoice WHERE id=:'invoice_c'::uuid),'edit: 30 days, one period, total 74');
-- The one-argument path, after the administrator deletes that invoice.
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.rule_assert(public.delete_invoice(:'invoice_c'::uuid)->>'success'='true','administrator deletes the RULC invoice');
SELECT set_config('request.jwt.claims',:'staff_claims',true);
SELECT pg_temp.rule_save1(:'c_header'::jsonb || '{"inv_no":20261044}'::jsonb,:'c_items'::jsonb) AS saved_c1 \gset
SELECT pg_temp.rule_assert(:'saved_c1'::jsonb->>'success'='true','one-argument save of RULC: ' || :'saved_c1');
SELECT (:'saved_c1'::jsonb->>'invoice_id') AS invoice_c \gset
RESET ROLE;
SELECT pg_temp.rule_assert((SELECT no_of_days=30 AND duration=1 FROM public.invoice_trl WHERE invoice_id=:'invoice_c'::uuid)
 AND (SELECT total=74 FROM public.invoice WHERE id=:'invoice_c'::uuid),'one-argument save: 30 days, one period, total 74');
-- The other side of midnight: a dispatch recorded at 00:30 on 2 May in India
-- (19:00 UTC on 1 May) is 31 days after 1 April, so 1.5 periods.
UPDATE public.dispatch SET disp_date='2026-05-01T19:00:00Z' WHERE disp_no='RULC1';
SET LOCAL ROLE authenticated;
SELECT pg_temp.rule_assert(pg_temp.rule_update(:'invoice_c'::uuid,:'c_header'::jsonb || '{"inv_no":20261044}'::jsonb,:'c_items'::jsonb)->>'success'='true','edit after the dispatch date moved');
RESET ROLE;
SELECT pg_temp.rule_assert((SELECT no_of_days=31 AND duration=1.5 FROM public.invoice_trl WHERE invoice_id=:'invoice_c'::uuid)
 AND (SELECT total=100 FROM public.invoice WHERE id=:'invoice_c'::uuid),'00:30 on 2 May in India counts as 2 May: 31 days, total 100');

-- 1 again, on the edit path: rates out of range are refused and the invoice
-- keeps its lines and total; a negative discount is still a surcharge.
SET LOCAL ROLE authenticated;
SELECT pg_temp.rule_assert(pg_temp.rule_refused(pg_temp.rule_update(:'invoice_a'::uuid,:'a_header'::jsonb || '{"inv_no":20261043,"notes":"must roll back"}'::jsonb,
 pg_temp.rule_rates(:'a_items'::jsonb,'{"charge":-5}'::jsonb)),'Invoice line charge must be between 0 and 999999'),'edit: negative charge refused');
SELECT pg_temp.rule_assert(pg_temp.rule_refused(pg_temp.rule_update(:'invoice_a'::uuid,:'a_header'::jsonb || '{"inv_no":20261043,"notes":"must roll back"}'::jsonb,
 pg_temp.rule_rates(:'a_items'::jsonb,'{"labour_rate":-500}'::jsonb)),'Invoice line labour rate must be between 0 and 999999'),'edit: negative labour rate refused');
SELECT pg_temp.rule_assert(pg_temp.rule_refused(pg_temp.rule_update(:'invoice_a'::uuid,:'a_header'::jsonb || '{"inv_no":20261043,"notes":"must roll back"}'::jsonb,
 pg_temp.rule_rates(:'a_items'::jsonb,'{"tax":-100}'::jsonb)),'Invoice line tax must be between 0 and 100'),'edit: negative tax refused');
SELECT pg_temp.rule_assert(pg_temp.rule_refused(pg_temp.rule_update(:'invoice_a'::uuid,:'a_header'::jsonb || '{"inv_no":20261043,"notes":"must roll back"}'::jsonb,
 pg_temp.rule_rates(:'a_items'::jsonb,'{"charge":1000000}'::jsonb)),'Invoice line charge must be between 0 and 999999'),'edit: absurd charge refused');
RESET ROLE;
SELECT pg_temp.rule_assert((SELECT total=998 AND notes IS DISTINCT FROM 'must roll back' FROM public.invoice WHERE id=:'invoice_a'::uuid)
 AND (SELECT count(*)=2 AND bool_and(charge=5 AND labour_rate=2 AND tax=5) FROM public.invoice_trl WHERE invoice_id=:'invoice_a'::uuid),
 'refused edits leave the header and the lines');
-- The discount guard of migration 24 is unchanged.
SET LOCAL ROLE authenticated;
SELECT pg_temp.rule_assert(pg_temp.rule_refused(pg_temp.rule_update(:'invoice_a'::uuid,
 :'a_header'::jsonb || '{"inv_no":20261043,"discount":5000,"discount_reason":"Too much"}'::jsonb,:'a_items'::jsonb),'Discount exceeds the invoice amount'),
 'a discount above the invoice amount is still refused');
RESET ROLE;
SELECT pg_temp.rule_assert((SELECT count(*)=0 FROM public.invoice_discount_history),'a refused discount leaves no history row');

-- 4. Discount changes, as staff. A surcharge of 50 needs a reason like any
-- other change; given one it is saved and the total rises to 1048.
SET LOCAL ROLE authenticated;
SELECT pg_temp.rule_assert(pg_temp.rule_refused(pg_temp.rule_update(:'invoice_a'::uuid,:'a_header'::jsonb || '{"inv_no":20261043,"discount":-50}'::jsonb,:'a_items'::jsonb),
 'A reason is required for an invoice discount'),'staff surcharge without a reason refused');
SELECT pg_temp.rule_assert(pg_temp.rule_update(:'invoice_a'::uuid,
 :'a_header'::jsonb || '{"inv_no":20261043,"discount":-50,"discount_reason":"Late collection surcharge"}'::jsonb,:'a_items'::jsonb)->>'success'='true',
 'a negative discount is still accepted as a surcharge');
RESET ROLE;
SELECT pg_temp.rule_assert((SELECT total=1048 AND discount=-50 AND discount_reason='Late collection surcharge' AND discount_set_by=:'staff_profile'::uuid
 FROM public.invoice WHERE id=:'invoice_a'::uuid),'the surcharge raises the total to 1048');
-- A reason made only of white space or invisible characters is no reason:
-- tab and newline, no-break space, zero-width space, ideographic space.
SET LOCAL ROLE authenticated;
SELECT pg_temp.rule_assert(pg_temp.rule_refused(pg_temp.rule_update(:'invoice_a'::uuid,
 :'a_header'::jsonb || jsonb_build_object('inv_no',20261043,'discount',10,'discount_reason',blank.reason),:'a_items'::jsonb),
 'A reason is required for an invoice discount'),'white-space-only reason refused for staff: ' || blank.label)
 FROM (VALUES ('spaces','   '),('tab and newline',E'\t\n\r'),('no-break space',U&'\00A0'),('zero-width space',U&'\200B'),
  ('ideographic space',U&'\3000'),('a mix',U&' \00A0\2003\200B\FEFF\2060 ')) AS blank(label,reason);
-- A real reason is kept without the surrounding white space.
SELECT pg_temp.rule_assert(pg_temp.rule_update(:'invoice_a'::uuid,
 :'a_header'::jsonb || jsonb_build_object('inv_no',20261043,'discount',10,'discount_reason',U&' \00A0Damaged bags\200B '),:'a_items'::jsonb)->>'success'='true',
 'staff discount with a reason');
-- An edit that keeps the discount adds nothing to the history.
SELECT pg_temp.rule_assert(pg_temp.rule_update(:'invoice_a'::uuid,
 :'a_header'::jsonb || '{"inv_no":20261043,"discount":10,"notes":"same discount"}'::jsonb,:'a_items'::jsonb)->>'success'='true','edit keeping the discount');
-- The administrator removes the discount without giving a reason.
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SELECT pg_temp.rule_assert(pg_temp.rule_update(:'invoice_a'::uuid,:'a_header'::jsonb || '{"inv_no":20261043,"discount":0}'::jsonb,:'a_items'::jsonb)->>'success'='true',
 'administrator removes the discount');
RESET ROLE;
SELECT pg_temp.rule_assert((SELECT total=998 AND discount=0 AND discount_reason IS NULL AND discount_set_by=:'admin_profile'::uuid
 FROM public.invoice WHERE id=:'invoice_a'::uuid),'the invoice row keeps only the last change');
-- One history row per change, in order, each with the account from its session.
SELECT pg_temp.rule_assert((SELECT jsonb_agg(jsonb_build_array(h.old_discount,h.new_discount,h.reason,h.changed_by,h.changed_by_role) ORDER BY h.id)
 FROM public.invoice_discount_history h WHERE h.invoice_id=:'invoice_a'::uuid)
 = jsonb_build_array(
  jsonb_build_array(0,-50,'Late collection surcharge',:'staff_profile','staff'),
  jsonb_build_array(-50,10,'Damaged bags',:'staff_profile','staff'),
  jsonb_build_array(10,0,NULL,:'admin_profile','admin')),
 'three changes, three history rows: ' || COALESCE((SELECT jsonb_agg(to_jsonb(h) ORDER BY h.id)::text FROM public.invoice_discount_history h),'none'));
SELECT pg_temp.rule_assert((SELECT count(*)=3 AND bool_and(inv_no=20261043 AND inv_fin_year=2026 AND customer_id=:'customer_id'::uuid AND changed_at IS NOT NULL)
 FROM public.invoice_discount_history),'history rows carry the invoice number and customer, and nothing else was written');
-- A discount given when the invoice is first saved is a change too (RULB,
-- zero rates on the three-argument path, so the surcharge is the whole total).
SELECT set_config('request.jwt.claims',:'staff_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.rule_save3(:'b_header'::jsonb || '{"inv_no":20261045,"discount":-25,"discount_reason":"Handling"}'::jsonb,
 pg_temp.rule_rates(:'b_items'::jsonb,'{"charge":0,"labour_rate":0,"tax":0}'::jsonb)) AS saved_b \gset
SELECT pg_temp.rule_assert(:'saved_b'::jsonb->>'success'='true','three-argument save: zero rates accepted: ' || :'saved_b');
SELECT (:'saved_b'::jsonb->>'invoice_id') AS invoice_b \gset
RESET ROLE;
SELECT pg_temp.rule_assert((SELECT total=25 AND discount=-25 FROM public.invoice WHERE id=:'invoice_b'::uuid),'zero rates and a surcharge of 25 give total 25');
SELECT pg_temp.rule_assert((SELECT count(*)=1 AND bool_and(old_discount=0 AND new_discount=-25 AND reason='Handling' AND changed_by=:'staff_profile'::uuid)
 FROM public.invoice_discount_history WHERE invoice_id=:'invoice_b'::uuid),'a discount on a new invoice is recorded');

-- Who reads the history: administrators (and supervisors) only; nobody writes.
SELECT set_config('request.jwt.claims',:'staff_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.rule_assert((SELECT count(*)=0 FROM public.invoice_discount_history),'staff cannot read the history');
SELECT set_config('request.jwt.claims',:'customer_claims',true);
SELECT pg_temp.rule_assert((SELECT count(*)=0 FROM public.invoice_discount_history),'a customer account cannot read the history');
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SELECT pg_temp.rule_assert((SELECT count(*)=4 FROM public.invoice_discount_history),'the administrator reads the history');
SELECT pg_temp.rule_assert(pg_temp.rule_raises('UPDATE public.invoice_discount_history SET reason=''rewritten''','permission denied%'),'the administrator cannot rewrite it');
SELECT pg_temp.rule_assert(pg_temp.rule_raises('DELETE FROM public.invoice_discount_history','permission denied%'),'the administrator cannot delete from it');
SELECT pg_temp.rule_assert(pg_temp.rule_raises(format('INSERT INTO public.invoice_discount_history(invoice_id,old_discount,new_discount) VALUES (%L,0,1)',:'invoice_a'),
 'permission denied%'),'the administrator cannot add to it by hand');
RESET ROLE;
SET LOCAL ROLE anon;
SELECT pg_temp.rule_assert(pg_temp.rule_raises('SELECT count(*) FROM public.invoice_discount_history','permission denied%'),'no anonymous access');
RESET ROLE;
SELECT pg_temp.rule_assert(pg_temp.rule_raises('UPDATE public.invoice_discount_history SET reason=''rewritten''','Invoice discount history cannot be changed'),
 'rows cannot be changed even by the database owner');
SELECT pg_temp.rule_assert(pg_temp.rule_raises('DELETE FROM public.invoice_discount_history','Invoice discount history cannot be changed'),
 'rows cannot be deleted even by the database owner');
SELECT pg_temp.rule_assert((SELECT relrowsecurity FROM pg_class WHERE oid='public.invoice_discount_history'::regclass),'row level security is on');

-- 5. get_invoice_detail carries the discount record for the warehouse roles
-- and leaves it out for a customer account reading its own invoice.
SELECT set_config('request.jwt.claims',:'staff_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.rule_assert(pg_temp.rule_update(:'invoice_a'::uuid,
 :'a_header'::jsonb || '{"inv_no":20261043,"discount":10,"discount_reason":"Damaged bags"}'::jsonb,:'a_items'::jsonb)->>'success'='true','staff discount for the detail check');
SELECT public.get_invoice_detail(:'invoice_a'::uuid) AS detail_staff \gset
SELECT pg_temp.rule_assert(:'detail_staff'::jsonb->>'success'='true' AND :'detail_staff'::jsonb#>>'{invoice,discount_reason}'='Damaged bags'
 AND :'detail_staff'::jsonb#>>'{invoice,discount_set_by}'=:'staff_profile' AND :'detail_staff'::jsonb#>>'{invoice,discount_set_by_name}'='Line Rule Staff'
 AND (:'detail_staff'::jsonb#>>'{invoice,discount_set_at}') IS NOT NULL AND (:'detail_staff'::jsonb#>>'{invoice,discount}')::numeric=10
 AND jsonb_array_length(:'detail_staff'::jsonb->'items')=2,'staff reads the discount record with the invoice: ' || (:'detail_staff'::jsonb->'invoice')::text);
RESET ROLE;
INSERT INTO public.users_customers_new(user_profile_id,customer_id,active)
 SELECT id,:'customer_id'::uuid,true FROM public.user_profiles WHERE mobile='919888888863';
SELECT set_config('request.jwt.claims',:'customer_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.get_invoice_detail(:'invoice_a'::uuid) AS detail_customer \gset
SELECT pg_temp.rule_assert(:'detail_customer'::jsonb->>'success'='true' AND (:'detail_customer'::jsonb#>>'{invoice,discount}')::numeric=10
 AND NOT (:'detail_customer'::jsonb->'invoice' ?| ARRAY['discount_reason','discount_set_by','discount_set_by_name','discount_set_at']),
 'the customer reads the invoice without the internal discount record: ' || (:'detail_customer'::jsonb->'invoice')::text);
RESET ROLE;

-- 5. Line amounts follow the header. RULB is one-time: 20 x 5 = 100 with no
-- duration and no labour, tax 5, total 105 (the old formula gave 147).
SELECT set_config('request.jwt.claims',:'staff_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.rule_assert(pg_temp.rule_update(:'invoice_b'::uuid,:'b_header'::jsonb || '{"inv_no":20261045,"discount":-25}'::jsonb,
 pg_temp.rule_rates(:'b_items'::jsonb,'{"charge":0,"labour_rate":0,"tax":0}'::jsonb))->>'success'='true','edit: zero rates accepted');
SELECT pg_temp.rule_assert(pg_temp.rule_update(:'invoice_b'::uuid,:'b_header'::jsonb || '{"inv_no":20261045,"discount":0,"discount_reason":"Charged in the rates"}'::jsonb,
 :'b_items'::jsonb)->>'success'='true','edit of RULB to the price-list rates');
SELECT public.get_invoice_items_detailed(:'invoice_b'::uuid) AS lines_b \gset
SELECT public.get_invoice_items_detailed(:'invoice_a'::uuid) AS lines_a \gset
RESET ROLE;
SELECT pg_temp.rule_assert((SELECT total=105 AND tax_amount=5 AND labour=0 FROM public.invoice WHERE id=:'invoice_b'::uuid),'one-time header: 100 + 5 = 105');
SELECT pg_temp.rule_assert((:'lines_b'::jsonb#>>'{data,items,0,tax_amount}')::numeric=5 AND (:'lines_b'::jsonb#>>'{data,items,0,total_amount}')::numeric=105
 AND (:'lines_b'::jsonb#>>'{data,summary,total_amount}')::numeric=105,'one-time line amounts match the header: ' || (:'lines_b'::jsonb#>'{data,summary}')::text);
SELECT pg_temp.rule_assert((SELECT jsonb_agg(jsonb_build_array((l->>'dispatch_qty')::numeric,(l->>'tax_amount')::numeric,(l->>'total_amount')::numeric) ORDER BY (l->>'dispatch_qty')::numeric)
 FROM jsonb_array_elements(:'lines_a'::jsonb#>'{data,items}') l)='[[20,9.5,199.5],[80,38,798]]'::jsonb
 AND (:'lines_a'::jsonb#>>'{data,summary,total_amount}')::numeric=997.5,'monthly line amounts are the fixture''s: ' || (:'lines_a'::jsonb#>'{data,summary}')::text);

-- 2 on the edit path. An invoice cannot be moved onto a receipt that is
-- already invoiced (the RULC invoice onto RULA and its lines).
SET LOCAL ROLE authenticated;
SELECT pg_temp.rule_assert(pg_temp.rule_refused(pg_temp.rule_update(:'invoice_c'::uuid,:'a_header'::jsonb || '{"inv_no":20261044}'::jsonb,:'a_items'::jsonb),
 'GRN is already invoiced'),'edit: an invoice cannot move onto an invoiced receipt');
RESET ROLE;
SELECT pg_temp.rule_assert((SELECT gr_id=:'grn_c'::uuid AND total=100 FROM public.invoice WHERE id=:'invoice_c'::uuid)
 AND (SELECT invoiced FROM public.goodsreceived WHERE id=:'grn_c'::uuid),'the refused move leaves the invoice and both receipts as they were');
-- Records saved before this rule may already hold a dispatch line twice. The
-- rule looks only at what a save adds, so such an invoice can still be edited.
INSERT INTO public.invoice(id,inv_fin_year,inv_no,gr_id,gr_no,customer_id,customer_name,inv_date,labour,tax_amount,total,discount)
 VALUES ('00000000-0000-4000-8000-000000000041',2026,20261046,:'grn_a'::uuid,'RULA',:'customer_id'::uuid,'Line Rule Customer','2026-05-02T12:00:00Z',0,0,0,0);
INSERT INTO public.invoice_trl(invoice_id,disp_trl_id,duration,no_of_days,charge,tax,labour_rate)
 SELECT '00000000-0000-4000-8000-000000000041',t.disp_trl_id,t.duration,t.no_of_days,t.charge,t.tax,t.labour_rate
 FROM public.invoice_trl t WHERE t.invoice_id=:'invoice_a'::uuid;
SET LOCAL ROLE authenticated;
SELECT pg_temp.rule_assert(pg_temp.rule_update(:'invoice_a'::uuid,:'a_header'::jsonb || '{"inv_no":20261043,"discount":10,"notes":"older double"}'::jsonb,:'a_items'::jsonb)->>'success'='true',
 'an invoice whose lines were already doubled can still be edited');
RESET ROLE;
SELECT pg_temp.rule_assert((SELECT notes='older double' AND total=988 FROM public.invoice WHERE id=:'invoice_a'::uuid),'the edit of the older double is saved');
DELETE FROM public.invoice_trl WHERE invoice_id='00000000-0000-4000-8000-000000000041';
DELETE FROM public.invoice WHERE id='00000000-0000-4000-8000-000000000041';
UPDATE public.goodsreceived SET invoiced=true WHERE id=:'grn_a'::uuid;

-- 5. An invoice with a payment cannot be deleted; without it, it can, the
-- receipt is free again, staff invoices it again, and the history of the
-- deleted invoice stays.
INSERT INTO public.payments(payment_no,payment_date,customer_id,customer_name,amount,invoice_id)
 VALUES ('RULPAY1','2026-05-03T12:00:00Z',:'customer_id'::uuid,'Line Rule Customer',988,:'invoice_a'::uuid);
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.delete_invoice(:'invoice_a'::uuid) AS paid_delete \gset
SELECT pg_temp.rule_assert(:'paid_delete'::jsonb->>'success'='false' AND :'paid_delete'::jsonb->>'error'='Cannot delete an invoice that has payments',
 'an invoice with a payment is not deleted: ' || :'paid_delete');
RESET ROLE;
SELECT pg_temp.rule_assert((SELECT count(*)=1 FROM public.invoice WHERE id=:'invoice_a'::uuid)
 AND (SELECT count(*)=2 FROM public.invoice_trl WHERE invoice_id=:'invoice_a'::uuid)
 AND (SELECT invoice_id=:'invoice_a'::uuid FROM public.payments WHERE payment_no='RULPAY1')
 AND (SELECT invoiced FROM public.goodsreceived WHERE id=:'grn_a'::uuid),'the refused delete leaves invoice, lines, payment and receipt');
DELETE FROM public.payments WHERE payment_no='RULPAY1';
SET LOCAL ROLE authenticated;
SELECT pg_temp.rule_assert(public.delete_invoice(:'invoice_a'::uuid)->>'success'='true','the invoice is deleted once the payment is gone');
SELECT set_config('request.jwt.claims',:'staff_claims',true);
SELECT pg_temp.rule_save1(:'a_header'::jsonb || '{"inv_no":20261047}'::jsonb,:'a_items'::jsonb) AS third \gset
SELECT pg_temp.rule_assert(:'third'::jsonb->>'success'='true','one-argument save: the receipt is invoiced again after the delete: ' || :'third');
RESET ROLE;
SELECT pg_temp.rule_assert((SELECT total=998 FROM public.invoice WHERE id=(:'third'::jsonb->>'invoice_id')::uuid)
 AND (SELECT count(*)=1 FROM public.invoice WHERE gr_id=:'grn_a'::uuid),'one invoice of 998 for the receipt');
SELECT pg_temp.rule_assert((SELECT count(*)=4 FROM public.invoice_discount_history WHERE invoice_id=:'invoice_a'::uuid),
 'the deleted invoice''s discount history is kept');
ROLLBACK;
\echo 'Invoice line rate ranges, single invoicing, India-date durations, discount history and detail checks passed.'
