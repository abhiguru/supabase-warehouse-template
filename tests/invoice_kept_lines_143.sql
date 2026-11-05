-- Migration 143 (WH-13): a cancelled invoice keeps its line details on the line itself. Covers criteria 1, 2, 4, 5, 7 and 8 of the card:
--   * cancel_invoice copies item name, packaging, weight, rack, package mark, quantity, dispatch and GRN number and date into the kept_* columns;
--   * after the dispatch is deleted, get_invoice_detail and get_invoice_data still show every line in full;
--   * a later edit of the dispatch line, the GRN line or the item name does not change a cancelled invoice;
--   * amounts and totals are the same before and after; a live invoice reads from its dispatch line and keeps no copy;
--   * a refused cancel (stale token, payment) writes no copy; a line emptied before the copy existed is listed with "details_available" false.
-- Fictional data; runs only in migrations.sh's disposable, network-disabled database; rolls back.
\set ON_ERROR_STOP on
BEGIN;
CREATE FUNCTION pg_temp.k_assert(ok boolean, label text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF NOT COALESCE(ok,false) THEN RAISE EXCEPTION 'kept lines 143: %',label; END IF; END $$;
CREATE FUNCTION pg_temp.k_login(phone text) RETURNS jsonb LANGUAGE plpgsql AS $$
 DECLARE c jsonb; l jsonb; claims jsonb;
 BEGIN
  c:=public.operator_prepare_otp(phone);
  PERFORM pg_temp.k_assert(c->>'success'='true','challenge prepared for '||phone);
  PERFORM public.operator_finish_otp((c#>>'{data,request_id}')::uuid,true,'mock-provider-only');
  l:=public.operator_verify_otp(phone,c#>>'{data,otp_code}');
  PERFORM pg_temp.k_assert(l#>>'{data,action}'='login','login for '||phone);
  SELECT jsonb_build_object('role','authenticated','sub',p.auth_user_id,'session_id',r.id) INTO claims
   FROM public.user_profiles p JOIN warehouse_security.refresh_sessions r ON r.user_id=p.auth_user_id
   WHERE p.mobile=warehouse_security.normalize_phone(phone) ORDER BY r.created_at DESC LIMIT 1;
  RETURN claims;
 END $$;
-- The single line of an invoice's get_invoice_detail answer, by position.
CREATE FUNCTION pg_temp.k_amounts(inv uuid) RETURNS text LANGUAGE sql AS $$
  SELECT (SELECT concat_ws('|',total,tax_amount,labour,discount) FROM public.invoice WHERE id=inv) || '#' ||
         COALESCE((SELECT string_agg(concat_ws('|',id,duration,no_of_days,charge,tax,labour_rate),',' ORDER BY id) FROM public.invoice_trl WHERE invoice_id=inv),'') $$;
INSERT INTO warehouse_security.auth_config(key,value) VALUES
 ('jwt_secret','isolated-test-secret-not-for-any-deployment-12345'),
 ('auth_mode','operator'),('demo_auth_enabled','false')
 ON CONFLICT(key) DO UPDATE SET value=excluded.value;
UPDATE public.sms_config SET provider='msg91',production_mode=true,msg91_auth_key='isolated-test-key',
 msg91_template_id='000000000000000000000001',msg91_pe_id='0000000000000000001',msg91_sender_id='KPTEST'
 WHERE id=(SELECT id FROM public.sms_config ORDER BY id DESC LIMIT 1);
SELECT warehouse_security.bootstrap_first_admin('9877777751','Kept Test Administrator') AS admin_user \gset
SELECT id AS admin_profile FROM public.user_profiles WHERE auth_user_id=:'admin_user'::uuid \gset
INSERT INTO public.user_profiles(auth_user_id,mobile,name,role,active,enrollment_status) VALUES
 (gen_random_uuid(),'919877777752','Kept Test Staff','staff',true,'approved');
SELECT pg_temp.k_login('9877777751') AS admin_claims \gset
SELECT pg_temp.k_login('9877777752') AS staff_claims \gset

-- Fixture: one customer and item; three receipts of 20 bags (KP1, KP2, KP3), each dispatched in full (KPD1..KPD3) and invoiced (21, 22, 23).
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.k_assert(public.create_customer('Kept Test North','9877777753')->>'success'='true','customer');
SELECT pg_temp.k_assert(public.create_item('Kept Test Garlic','Bag')->>'success'='true','item');
SELECT id AS north FROM public.customers WHERE name='Kept Test North' \gset
SELECT id AS item_id FROM public.items WHERE name='Kept Test Garlic' \gset
SELECT pg_temp.k_assert(public.replace_item_rates(:'item_id'::uuid,:'north'::uuid,'monthly','2026-01-01'::date,jsonb_build_array(jsonb_build_object('weight_min',0,'weight_max',100,'unit_price',5,'labour_rate',2,'tax_percent',5)))->>'success'='true','price');
SELECT pg_temp.k_assert(public.save_grn(p_gr_no=>n.no::varchar,p_date=>'2026-04-01T12:00:00Z',p_customer_id=>:'north'::uuid,
 p_customer_name=>'Kept Test North',p_pricing_mode=>'ONE_TIME',p_idempotency_key=>'kept-grn-'||n.no,
 p_items=>jsonb_build_array(jsonb_build_object('item_id',:'item_id','item_name','Kept Test Garlic','packaging','Bag','qty',20,'weight',10,
   'rack','K-'||n.no,'package_mark','M-'||n.no)))->>'success'='true','receipt '||n.no)
FROM (VALUES ('KP1'),('KP2'),('KP3')) n(no);
SELECT id AS grn1 FROM public.goodsreceived WHERE gr_no='KP1' \gset
SELECT id AS grn2 FROM public.goodsreceived WHERE gr_no='KP2' \gset
SELECT id AS grn3 FROM public.goodsreceived WHERE gr_no='KP3' \gset
SELECT pg_temp.k_assert(public.create_dispatch_with_stock_check(jsonb_build_object('customer_id',:'north','customer_name','Kept Test North',
 'supervisor_id',:'admin_profile','supervisor_name','Kept Test Administrator','disp_date','2026-05-02','disp_no','KPD'||n.k),
 ARRAY[jsonb_build_object('gr_trl_id',(SELECT t.id FROM public.goodsreceived_trl t WHERE t.gr_id=n.g::uuid),'disp_qty',20)],0,'kept-dispatch-'||n.k)->>'success'='true','dispatch KPD'||n.k)
FROM (VALUES ('1',:'grn1'),('2',:'grn2'),('3',:'grn3')) n(k,g);
SELECT id AS disp1 FROM public.dispatch WHERE disp_no='KPD1' \gset
SELECT id AS disp2 FROM public.dispatch WHERE disp_no='KPD2' \gset
RESET ROLE;
SELECT set_config('request.jwt.claims',:'staff_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.k_assert(public.save_invoice(NULL::uuid,
 jsonb_build_object('inv_fin_year',2026,'inv_no',n.no,'customer_id',:'north','customer_name','Kept Test North',
  'inv_date','2026-05-02T12:00:00Z','total',0,'tax_amount',0,'labour',0,'discount',0,'duration_mode','legacy','gr_id',n.g,'gr_no',n.gno),
 ARRAY(SELECT jsonb_build_object('disp_trl_id',t.id,'grn_item_id',t.gr_trl_id,'duration',1,'charge',5,'tax',5,'labour_rate',2)
       FROM public.dispatch_trl t WHERE t.gr_id=n.g::uuid))->>'success'='true','staff save invoice '||n.no)
FROM (VALUES (21,:'grn1','KP1'),(22,:'grn2','KP2'),(23,:'grn3','KP3')) n(no,g,gno);
RESET ROLE;
SELECT id AS inv1 FROM public.invoice WHERE inv_no=21 AND inv_fin_year=2026 \gset
SELECT id AS inv2 FROM public.invoice WHERE inv_no=22 AND inv_fin_year=2026 \gset
SELECT id AS inv3 FROM public.invoice WHERE inv_no=23 AND inv_fin_year=2026 \gset
SELECT pg_temp.k_assert((SELECT count(*)=3 FROM public.invoice_trl WHERE invoice_id IN (:'inv1'::uuid,:'inv2'::uuid,:'inv3'::uuid)),'fixture: one line on each invoice');
SELECT pg_temp.k_assert((SELECT bool_and(details_kept_at IS NULL AND kept_item_name IS NULL AND kept_disp_qty IS NULL AND kept_grn_no IS NULL) FROM public.invoice_trl),
  'a live invoice keeps no copy');
SELECT pg_temp.k_amounts(:'inv1'::uuid) AS amounts1_before \gset
SELECT pg_temp.k_amounts(:'inv2'::uuid) AS amounts2_before \gset
SELECT updated_at AS token1 FROM public.invoice WHERE id=:'inv1'::uuid \gset
SELECT updated_at AS token2 FROM public.invoice WHERE id=:'inv2'::uuid \gset
SELECT updated_at AS token3 FROM public.invoice WHERE id=:'inv3'::uuid \gset

-- 7. A cancel that is refused writes no copy: a stale token, then a payment.
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.cancel_invoice(:'inv3'::uuid,'Entered twice',:'token3'::timestamptz - interval '1 second') AS r_stale \gset
RESET ROLE;
SELECT pg_temp.k_assert(:'r_stale'::jsonb->>'reason'='STALE_RECORD' AND (SELECT details_kept_at IS NULL AND kept_item_name IS NULL FROM public.invoice_trl WHERE invoice_id=:'inv3'::uuid),
  'a stale cancel writes no copy: '||:'r_stale');
INSERT INTO public.payments(payment_no,payment_date,customer_id,invoice_id,amount,payment_mode) VALUES ('KPP1','2026-05-03T00:00:00Z',:'north'::uuid,:'inv3'::uuid,10,'cash');
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.cancel_invoice(:'inv3'::uuid,'Entered twice',NULL) AS r_paid \gset
RESET ROLE;
SELECT pg_temp.k_assert(:'r_paid'::jsonb->>'reason'='INVOICE_HAS_PAYMENTS' AND (SELECT details_kept_at IS NULL AND kept_item_name IS NULL FROM public.invoice_trl WHERE invoice_id=:'inv3'::uuid),
  'a cancel refused for a payment writes no copy: '||:'r_paid');
DELETE FROM public.payments WHERE payment_no='KPP1';

-- Cancel invoice 21 and invoice 22: each line saves its own copy, in the same transaction.
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.cancel_invoice(:'inv1'::uuid,'Entered twice',:'token1'::timestamptz) AS r_c1 \gset
SELECT public.cancel_invoice(:'inv2'::uuid,'Entered twice',:'token2'::timestamptz) AS r_c2 \gset
RESET ROLE;
SELECT pg_temp.k_assert(:'r_c1'::jsonb->>'success'='true' AND :'r_c2'::jsonb->>'success'='true','both cancels succeed: '||:'r_c1'||:'r_c2');
SELECT pg_temp.k_assert((SELECT count(*)=1 AND bool_and(details_kept_at IS NOT NULL AND kept_item_name='Kept Test Garlic' AND kept_packaging='Bag' AND kept_weight=10
    AND kept_rack='K-KP1' AND kept_package_mark='M-KP1' AND kept_disp_qty=20 AND kept_disp_no='KPD1' AND kept_disp_date IS NOT NULL
    AND kept_grn_no='KP1' AND kept_grn_date IS NOT NULL) FROM public.invoice_trl WHERE invoice_id=:'inv1'::uuid),
  'cancel copies the ten details of the line');
SELECT pg_temp.k_assert((SELECT bool_and(details_kept_at IS NULL AND kept_item_name IS NULL) FROM public.invoice_trl WHERE invoice_id=:'inv3'::uuid),'the live invoice 23 still keeps no copy');

-- 5. A live invoice reads from its dispatch line, as before: the answer names the line's own item, quantity and numbers.
SELECT set_config('request.jwt.claims',:'staff_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.get_invoice_detail(:'inv3'::uuid) AS live_detail \gset
SELECT public.get_invoice_data(:'inv3'::uuid) AS live_data \gset
RESET ROLE;
SELECT pg_temp.k_assert(jsonb_array_length(:'live_detail'::jsonb->'items')=1
  AND :'live_detail'::jsonb#>>'{items,0,item_name}'='Kept Test Garlic' AND (:'live_detail'::jsonb#>>'{items,0,qty}')::int=20
  AND :'live_detail'::jsonb#>>'{items,0,dispatch_no}'='KPD3' AND :'live_detail'::jsonb#>>'{items,0,grn_no}'='KP3'
  AND (:'live_detail'::jsonb#>>'{items,0,weight}')::int=10 AND :'live_detail'::jsonb#>>'{items,0,rack}'='K-KP3' AND (:'live_detail'::jsonb#>>'{items,0,details_available}')='true',
  'get_invoice_detail of a live invoice: '||:'live_detail');
SELECT pg_temp.k_assert(jsonb_array_length(:'live_data'::jsonb#>'{data,items}')=1
  AND :'live_data'::jsonb#>>'{data,items,0,grn_item,name}'='Kept Test Garlic' AND (:'live_data'::jsonb#>>'{data,items,0,dispatch,quantity}')::int=20
  AND :'live_data'::jsonb#>>'{data,items,0,dispatch,disp_no}'='KPD3' AND :'live_data'::jsonb#>>'{data,items,0,grn_item,gr_no}'='KP3',
  'get_invoice_data of a live invoice: '||:'live_data');
-- A live invoice follows its dispatch line and GRN line (nothing is copied): the new text shows at once.
SET LOCAL session_replication_role = replica;
UPDATE public.goodsreceived_trl SET item_name='Kept Test Garlic Renamed' WHERE gr_id=:'grn3'::uuid;
RESET session_replication_role;
SELECT set_config('request.jwt.claims',:'staff_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.get_invoice_detail(:'inv3'::uuid)#>>'{items,0,item_name}' AS live_renamed \gset
RESET ROLE;
SELECT pg_temp.k_assert(:'live_renamed'='Kept Test Garlic Renamed','a live invoice reads the current GRN line: '||:'live_renamed');

-- 1. Cancel, delete the dispatch, open the invoice: every line still shows item, quantity, weight, dispatch number and GRN number.
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.delete_dispatch_with_order_cleanup(:'disp1'::uuid,NULL) AS r_dd \gset
RESET ROLE;
SELECT pg_temp.k_assert(:'r_dd'::jsonb->>'success'='true' AND NOT EXISTS (SELECT 1 FROM public.dispatch WHERE id=:'disp1'::uuid),'dispatch KPD1 is deleted: '||:'r_dd');
SELECT pg_temp.k_assert((SELECT count(*)=1 AND bool_and(disp_trl_id IS NULL) FROM public.invoice_trl WHERE invoice_id=:'inv1'::uuid),'the line stays and its dispatch reference is empty (migration 120)');
SELECT set_config('request.jwt.claims',:'staff_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.get_invoice_detail(:'inv1'::uuid) AS d1 \gset
SELECT public.get_invoice_data(:'inv1'::uuid) AS dd1 \gset
RESET ROLE;
SELECT pg_temp.k_assert(jsonb_array_length(:'d1'::jsonb->'items')=1
  AND :'d1'::jsonb#>>'{items,0,item_name}'='Kept Test Garlic' AND :'d1'::jsonb#>>'{items,0,packaging}'='Bag' AND (:'d1'::jsonb#>>'{items,0,qty}')::int=20
  AND (:'d1'::jsonb#>>'{items,0,weight}')::int=10 AND :'d1'::jsonb#>>'{items,0,dispatch_no}'='KPD1' AND :'d1'::jsonb#>>'{items,0,grn_no}'='KP1'
  AND :'d1'::jsonb#>>'{items,0,rack}'='K-KP1' AND :'d1'::jsonb#>>'{items,0,package_mark}'='M-KP1' AND (:'d1'::jsonb#>>'{items,0,details_available}')='true',
  'get_invoice_detail lists the line in full after the dispatch is gone: '||:'d1');
SELECT pg_temp.k_assert(jsonb_array_length(:'dd1'::jsonb#>'{data,items}')=1
  AND :'dd1'::jsonb#>>'{data,items,0,grn_item,name}'='Kept Test Garlic' AND (:'dd1'::jsonb#>>'{data,items,0,dispatch,quantity}')::int=20
  AND (:'dd1'::jsonb#>>'{data,items,0,grn_item,weight}')::int=10 AND :'dd1'::jsonb#>>'{data,items,0,dispatch,disp_no}'='KPD1'
  AND :'dd1'::jsonb#>>'{data,items,0,grn_item,gr_no}'='KP1' AND (:'dd1'::jsonb#>>'{data,items,0,details_available}')='true',
  'get_invoice_data shows the line in full after the dispatch is gone: '||:'dd1');
-- 4. Totals and each line's amounts are the same before and after.
SELECT pg_temp.k_assert(pg_temp.k_amounts(:'inv1'::uuid)=:'amounts1_before','totals and line amounts of invoice 21 are unchanged');

-- 2. Edit the dispatch line, the GRN line and the item after the cancel: the cancelled invoice 22 still shows the values at cancel.
SET LOCAL session_replication_role = replica;
UPDATE public.dispatch_trl SET disp_qty=15 WHERE disp_id=:'disp2'::uuid;
UPDATE public.goodsreceived_trl SET item_name='Kept Test Garlic Renamed', weight=12, rack='CHANGED', package_mark='CHANGED' WHERE gr_id=:'grn2'::uuid;
UPDATE public.goodsreceived SET gr_no='KP2X' WHERE id=:'grn2'::uuid;
UPDATE public.dispatch SET disp_no='KPD2X' WHERE id=:'disp2'::uuid;
RESET session_replication_role;
SELECT set_config('request.jwt.claims',:'staff_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.get_invoice_detail(:'inv2'::uuid) AS d2 \gset
SELECT public.get_invoice_data(:'inv2'::uuid) AS dd2 \gset
RESET ROLE;
SELECT pg_temp.k_assert(:'d2'::jsonb#>>'{items,0,item_name}'='Kept Test Garlic' AND (:'d2'::jsonb#>>'{items,0,qty}')::int=20 AND (:'d2'::jsonb#>>'{items,0,weight}')::int=10
  AND :'d2'::jsonb#>>'{items,0,dispatch_no}'='KPD2' AND :'d2'::jsonb#>>'{items,0,grn_no}'='KP2' AND :'d2'::jsonb#>>'{items,0,rack}'='K-KP2'
  AND :'d2'::jsonb#>>'{items,0,package_mark}'='M-KP2','get_invoice_detail ignores later edits: '||:'d2');
SELECT pg_temp.k_assert(:'dd2'::jsonb#>>'{data,items,0,grn_item,name}'='Kept Test Garlic' AND (:'dd2'::jsonb#>>'{data,items,0,dispatch,quantity}')::int=20
  AND (:'dd2'::jsonb#>>'{data,items,0,grn_item,weight}')::int=10 AND :'dd2'::jsonb#>>'{data,items,0,dispatch,disp_no}'='KPD2'
  AND :'dd2'::jsonb#>>'{data,items,0,grn_item,gr_no}'='KP2','get_invoice_data ignores later edits: '||:'dd2');
SELECT pg_temp.k_assert(pg_temp.k_amounts(:'inv2'::uuid)=:'amounts2_before','totals and line amounts of invoice 22 are unchanged');

-- 8. A line emptied before the copy existed (no copy, no dispatch line) is listed with its amounts and details_available false.
SET LOCAL session_replication_role = replica;
UPDATE public.invoice_trl SET disp_trl_id=NULL, details_kept_at=NULL, kept_item_name=NULL, kept_packaging=NULL, kept_weight=NULL, kept_rack=NULL,
  kept_package_mark=NULL, kept_disp_qty=NULL, kept_disp_no=NULL, kept_disp_date=NULL, kept_grn_no=NULL, kept_grn_date=NULL WHERE invoice_id=:'inv2'::uuid;
RESET session_replication_role;
SELECT set_config('request.jwt.claims',:'staff_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.get_invoice_detail(:'inv2'::uuid) AS d2e \gset
SELECT public.get_invoice_data(:'inv2'::uuid) AS dd2e \gset
RESET ROLE;
SELECT pg_temp.k_assert(jsonb_array_length(:'d2e'::jsonb->'items')=1 AND (:'d2e'::jsonb#>>'{items,0,details_available}')='false'
  AND (:'d2e'::jsonb#>>'{items,0,charge}')::numeric=5 AND (:'d2e'::jsonb#>>'{items,0,tax}')::numeric=5,'an emptied line is listed with its amounts: '||:'d2e');
SELECT pg_temp.k_assert(jsonb_array_length(:'dd2e'::jsonb#>'{data,items}')=1 AND (:'dd2e'::jsonb#>>'{data,items,0,details_available}')='false','get_invoice_data marks an emptied line: '||:'dd2e');
ROLLBACK;
