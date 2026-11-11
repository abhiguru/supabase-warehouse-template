-- The optional invoice number prefix (migration 175, WH-139): an invoice stores the prefix it was saved with, the full number is the prefix and the digits,
-- the digits keep counting as before, and a facility with no prefix sees the digits as they were. Fictional data; runs only in migrations.sh's disposable,
-- network-disabled database.
\set ON_ERROR_STOP on
BEGIN;
-- The one-argument save_invoice(jsonb) is gone (migration 123): the app's save, a header and an array of lines, is used. This takes
-- the header with its lines under 'items' (as the old call did) and adds what the save asks of each line: its lot and a duration of 1.
CREATE FUNCTION pg_temp.save_invoice_doc(doc jsonb) RETURNS jsonb LANGUAGE sql AS $$
  SELECT public.save_invoice(NULL::uuid, doc - 'items', ARRAY(
    SELECT jsonb_build_object('grn_item_id', (SELECT d.gr_trl_id FROM public.dispatch_trl d WHERE d.id = (i->>'disp_trl_id')::uuid), 'duration', 1) || i
    FROM jsonb_array_elements(doc->'items') i)) $$;
CREATE FUNCTION pg_temp.pf_refused(statement text) RETURNS boolean LANGUAGE plpgsql AS $$
BEGIN
  BEGIN
    EXECUTE statement;
  EXCEPTION WHEN OTHERS THEN RETURN true;
  END;
  RETURN false;
END $$;
CREATE FUNCTION pg_temp.pf_assert(ok boolean, label text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF NOT COALESCE(ok,false) THEN RAISE EXCEPTION 'invoice prefix: %',label; END IF; END $$;
INSERT INTO warehouse_security.auth_config(key,value) VALUES
 ('jwt_secret','isolated-test-secret-not-for-any-deployment-12345'),
 ('auth_mode','operator'),('demo_auth_enabled','false')
 ON CONFLICT(key) DO UPDATE SET value=excluded.value;
UPDATE public.sms_config SET provider='msg91',production_mode=true,msg91_auth_key='isolated-test-key',
 msg91_template_id='000000000000000000000001',msg91_pe_id='0000000000000000001',msg91_sender_id='CITEST'
 WHERE id=(SELECT id FROM public.sms_config ORDER BY id DESC LIMIT 1);
SELECT warehouse_security.bootstrap_first_admin('9888888861','Prefix Demo Administrator') AS admin_user \gset
SELECT public.operator_prepare_otp('9888888861') AS challenge \gset
SELECT pg_temp.pf_assert(:'challenge'::jsonb->>'success'='true','operator challenge prepared');
SELECT public.operator_finish_otp((:'challenge'::jsonb#>>'{data,request_id}')::uuid,true,'mock-provider-only');
SELECT public.operator_verify_otp('9888888861',:'challenge'::jsonb#>>'{data,otp_code}') AS login \gset
SELECT pg_temp.pf_assert(:'login'::jsonb#>>'{data,action}'='login','mocked operator login');
SELECT id AS admin_profile FROM public.user_profiles WHERE auth_user_id=:'admin_user'::uuid \gset
SELECT set_config('request.jwt.claims',jsonb_build_object('role','authenticated','sub',:'admin_user',
 'session_id',(SELECT id FROM warehouse_security.refresh_sessions WHERE user_id=:'admin_user'::uuid LIMIT 1))::text,true);
SET LOCAL ROLE authenticated;
SELECT public.create_customer('Prefix Demo Customer','9888888862') AS customer \gset
SELECT pg_temp.pf_assert(:'customer'::jsonb->>'success'='true','customer creation');
SELECT public.create_item('Prefix Demo Potatoes','Bag') AS item \gset
SELECT pg_temp.pf_assert(:'item'::jsonb->>'success'='true','catalog creation');
SELECT id AS customer_id FROM public.customers WHERE name='Prefix Demo Customer' \gset
SELECT id AS item_id FROM public.items WHERE name='Prefix Demo Potatoes' \gset
SELECT public.replace_item_rates(:'item_id'::uuid,:'customer_id'::uuid,'monthly','2026-01-01'::date,jsonb_build_array(jsonb_build_object('weight_min',0,'weight_max',100,'unit_price',5,'labour_rate',2,'tax_percent',5))) AS price \gset
SELECT pg_temp.pf_assert(:'price'::jsonb->>'success'='true','fictional price creation');
SELECT public.save_grn(p_gr_no=>'PFXA',p_date=>'2026-04-01T12:00:00Z',p_customer_id=>:'customer_id'::uuid,
 p_customer_name=>'Prefix Demo Customer',p_pricing_mode=>'MONTHLY',p_idempotency_key=>'pfx-receipt',
 p_items=>jsonb_build_array(jsonb_build_object('item_id',:'item_id','item_name','Prefix Demo Potatoes',
 'packaging','Bag','qty',100,'weight',10,'rack','DEMO'))) AS grn \gset
SELECT pg_temp.pf_assert(:'grn'::jsonb->>'success'='true','receipt creation');
SELECT id AS grn_id FROM public.goodsreceived WHERE gr_no='PFXA' \gset
SELECT id AS stock_id FROM public.goodsreceived_trl WHERE gr_id=:'grn_id'::uuid \gset
SELECT pg_temp.pf_assert((SELECT stock=100 FROM public.goodsreceived_trl WHERE id=:'stock_id'::uuid),'receipt stock 100');
SELECT jsonb_build_object('disp_no','PFXA','disp_date','2026-05-02T12:00:00Z','customer_id',:'customer_id',
 'customer_name','Prefix Demo Customer','supervisor_id',:'admin_profile','supervisor_name','Prefix Demo Administrator') AS dispatch_data \gset
SELECT public.create_dispatch_with_stock_check(:'dispatch_data'::jsonb,
 ARRAY[jsonb_build_object('gr_trl_id',:'stock_id','disp_qty',20)],false,0,'pfx-partial') AS dispatch \gset
SELECT pg_temp.pf_assert(:'dispatch'::jsonb->>'success'='true','partial dispatch');
SELECT public.create_dispatch_with_stock_check(:'dispatch_data'::jsonb,
 ARRAY[jsonb_build_object('gr_trl_id',:'stock_id','disp_qty',20)],false,0,'pfx-partial') AS retry \gset
SELECT pg_temp.pf_assert(:'retry'::jsonb->>'success'='true','dispatch retry');
SELECT pg_temp.pf_assert((SELECT stock=80 FROM public.goodsreceived_trl WHERE id=:'stock_id'::uuid),'retry leaves 80 bags');
SELECT public.get_customer_stock_summary(:'customer_id'::uuid) AS summary \gset
SELECT pg_temp.pf_assert((:'summary'::jsonb#>>'{summary,total_quantity}')::numeric=80
 AND (:'summary'::jsonb#>>'{summary,total_weight_kg}')::numeric=800,'partial balance 80 bags / 800 kg');
RESET ROLE;
-- Two invoices of the same GRN, one per dispatch line (invoicing goods as they leave on), and a final dispatch for the second.
UPDATE warehouse_security.charging_rule SET invoice_as_goods_leave = true WHERE id;
SET LOCAL ROLE authenticated;
SELECT public.create_dispatch_with_stock_check(:'dispatch_data'::jsonb || '{"disp_no":"PFXB"}'::jsonb,
 ARRAY[jsonb_build_object('gr_trl_id', :'stock_id', 'disp_qty', 80)], false, 0, 'pfx-final') AS final_dispatch \gset
SELECT pg_temp.pf_assert(:'final_dispatch'::jsonb->>'success' = 'true', 'final dispatch');
SELECT jsonb_agg(jsonb_build_object('disp_trl_id', t.id, 'charge', 5, 'tax', 5, 'labour_rate', 2)) AS items_a
  FROM public.dispatch_trl t JOIN public.dispatch d ON d.id = t.disp_id WHERE d.disp_no = 'PFXA' \gset
SELECT jsonb_agg(jsonb_build_object('disp_trl_id', t.id, 'charge', 5, 'tax', 5, 'labour_rate', 2)) AS items_b
  FROM public.dispatch_trl t JOIN public.dispatch d ON d.id = t.disp_id WHERE d.disp_no = 'PFXB' \gset
SELECT jsonb_build_object('inv_fin_year', 2026, 'gr_id', :'grn_id', 'gr_no', 'PFXA', 'customer_id', :'customer_id', 'customer_name', 'Prefix Demo Customer',
  'inv_date', '2026-05-02T12:00:00Z', 'total', 0, 'tax_amount', 0, 'discount', 0, 'duration_mode', 'legacy') AS base_header \gset

-- 1. No prefix in the rule: the invoice stores '' and its full number is the digits (what every installation sees until it sets a prefix).
SELECT pg_temp.save_invoice_doc(:'base_header'::jsonb || jsonb_build_object('inv_no', 20270301, 'items', :'items_a'::jsonb)) AS plain \gset
SELECT pg_temp.pf_assert(:'plain'::jsonb->>'success' = 'true', 'an invoice without a prefix saves: ' || :'plain');
RESET ROLE;
SELECT pg_temp.pf_assert((SELECT inv_prefix = '' FROM public.invoice WHERE id = (:'plain'::jsonb->>'invoice_id')::uuid), 'it stores no prefix');
SELECT pg_temp.pf_assert(warehouse_security.invoice_label('', 20270301) = '20270301' AND warehouse_security.invoice_label(NULL, 12) = '12'
  AND warehouse_security.invoice_label('SRT/', 12) = 'SRT/12', 'the full number is the prefix and the digits, no space');

-- 2. A prefix in the rule: the next invoice of the financial year takes the prefix of the invoices the year already holds, not the rule's: all invoices of one
-- financial year carry one prefix.
UPDATE warehouse_security.document_numbering SET prefix = 'SRT/' WHERE document_type = 'invoice';
SET LOCAL ROLE authenticated;
SELECT pg_temp.save_invoice_doc(:'base_header'::jsonb || jsonb_build_object('inv_no', 20270302, 'items', :'items_b'::jsonb)) AS second \gset
SELECT pg_temp.pf_assert(:'second'::jsonb->>'success' = 'true', 'the second invoice saves: ' || :'second');
RESET ROLE;
SELECT pg_temp.pf_assert((SELECT inv_prefix = '' FROM public.invoice WHERE id = (:'second'::jsonb->>'invoice_id')::uuid),
  'a year that already holds invoices without a prefix keeps them all without one');
-- A new financial year takes the rule's prefix.
SET LOCAL ROLE authenticated;
SELECT public.cancel_invoice((:'second'::jsonb->>'invoice_id')::uuid, 'Prefix test', NULL) AS cancelled \gset
RESET ROLE;
INSERT INTO public.invoice (inv_no, inv_fin_year, customer_id, customer_name, inv_date, gr_id, gr_no, total) VALUES (7, 2099, :'customer_id', 'Prefix Demo Customer', '2099-05-02', :'grn_id', 'PFXA', 0);
SELECT pg_temp.pf_assert((SELECT inv_prefix = 'SRT/' FROM public.invoice WHERE inv_fin_year = 2099 AND inv_no = 7), 'the first invoice of a year takes the rule''s prefix');
INSERT INTO public.invoice (inv_no, inv_fin_year, customer_id, customer_name, inv_date, gr_id, gr_no, total) VALUES (8, 2099, :'customer_id', 'Prefix Demo Customer', '2099-05-03', :'grn_id', 'PFXA', 0);
UPDATE warehouse_security.document_numbering SET prefix = 'XYZ' WHERE document_type = 'invoice';
INSERT INTO public.invoice (inv_no, inv_fin_year, customer_id, customer_name, inv_date, gr_id, gr_no, total) VALUES (9, 2099, :'customer_id', 'Prefix Demo Customer', '2099-05-04', :'grn_id', 'PFXA', 0);
SELECT pg_temp.pf_assert((SELECT bool_and(inv_prefix = 'SRT/') FROM public.invoice WHERE inv_fin_year = 2099), 'a later invoice of that year keeps its year''s prefix, whatever the rule says now');
-- The stored prefix never changes, a prefix outside the set is refused, and the full number is unique per year.
SELECT pg_temp.pf_assert(pg_temp.pf_refused($$UPDATE public.invoice SET inv_prefix = 'ABC' WHERE inv_fin_year = 2099 AND inv_no = 7$$), 'a stored prefix can not be changed');
SELECT pg_temp.pf_assert(pg_temp.pf_refused($$UPDATE public.invoice SET inv_prefix = 'srt/' WHERE inv_fin_year = 2099 AND inv_no = 8$$)
  AND pg_temp.pf_refused($$INSERT INTO public.invoice (inv_no, inv_fin_year, customer_id, customer_name, inv_date, gr_id, gr_no, total, inv_prefix) SELECT 99, 2098, customer_id, customer_name, inv_date, gr_id, gr_no, total, 'TOOLONGPFX' FROM public.invoice WHERE inv_fin_year = 2099 AND inv_no = 7$$),
  'a prefix of lower case or longer than 8 characters is refused');
SELECT pg_temp.pf_assert(pg_temp.pf_refused($$INSERT INTO public.invoice (inv_no, inv_fin_year, customer_id, customer_name, inv_date, gr_id, gr_no, total) SELECT 7, 2099, customer_id, customer_name, inv_date, gr_id, gr_no, total FROM public.invoice WHERE inv_fin_year = 2099 AND inv_no = 7$$),
  'the same number twice in a financial year is refused');
ROLLBACK;
\echo 'Invoice prefix: the stored prefix, the full number, the year''s one prefix and the refusals passed.'
