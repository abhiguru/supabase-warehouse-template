-- WH-308: an issued invoice keeps the package marking and rack its lot had when the invoice was issued; the lot itself can still be changed.
-- Owner, 2026-11-25: "As issued, AB-12". Fixture: a lot marked AB-12 on rack R1, dispatched and invoiced; then the lot's marking becomes AB-15 and
-- its rack R2. Expected:
--   * get_invoice_detail (the app's invoice details) lists the line with package_mark AB-12 and rack R1;
--   * get_invoice_data (the app's printable invoice data) shows grn_item.package_mark AB-12 and grn_item.rack R1;
--   * get_invoice_range_for_print (the slip printed by print-invoice-preprinted) carries grn_items_package_mark AB-12 and grn_items_rack R1;
--   * the lot itself (goodsreceived_trl, get_grn_details) shows AB-15 and R2;
--   * amounts and totals do not change.
-- The server-side PDF (functions/_shared/document-pdf.ts) prints no rack or marking; its guard is tests/invoice-keeps-issued-marking.test.mjs.
-- Fictional data; runs only in migrations.sh's disposable, network-disabled database; rolls back. Must FAIL before the WH-308 fix.
\set ON_ERROR_STOP on
BEGIN;
CREATE FUNCTION pg_temp.km_assert(ok boolean, label text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF NOT COALESCE(ok,false) THEN RAISE EXCEPTION 'issued marking 308: %',label; END IF; END $$;
CREATE FUNCTION pg_temp.km_login(phone text) RETURNS jsonb LANGUAGE plpgsql AS $$
 DECLARE c jsonb; l jsonb; claims jsonb;
 BEGIN
  c:=public.operator_prepare_otp(phone);
  PERFORM pg_temp.km_assert(c->>'success'='true','challenge prepared for '||phone);
  PERFORM public.operator_finish_otp((c#>>'{data,request_id}')::uuid,true,'mock-provider-only');
  l:=public.operator_verify_otp(phone,c#>>'{data,otp_code}');
  PERFORM pg_temp.km_assert(l#>>'{data,action}'='login','login for '||phone);
  SELECT jsonb_build_object('role','authenticated','sub',p.auth_user_id,'session_id',r.id) INTO claims
   FROM public.user_profiles p JOIN warehouse_security.refresh_sessions r ON r.user_id=p.auth_user_id
   WHERE p.mobile=warehouse_security.normalize_phone(phone) ORDER BY r.created_at DESC LIMIT 1;
  RETURN claims;
 END $$;
CREATE FUNCTION pg_temp.km_amounts(inv uuid) RETURNS text LANGUAGE sql AS $$
  SELECT (SELECT concat_ws('|',total,tax_amount,labour,discount) FROM public.invoice WHERE id=inv) || '#' ||
         COALESCE((SELECT string_agg(concat_ws('|',id,duration,no_of_days,charge,tax,labour_rate),',' ORDER BY id) FROM public.invoice_trl WHERE invoice_id=inv),'') $$;
INSERT INTO warehouse_security.auth_config(key,value) VALUES
 ('jwt_secret','isolated-test-secret-not-for-any-deployment-12345'),
 ('auth_mode','operator'),('demo_auth_enabled','false')
 ON CONFLICT(key) DO UPDATE SET value=excluded.value;
UPDATE public.sms_config SET provider='msg91',production_mode=true,msg91_auth_key='isolated-test-key',
 msg91_template_id='000000000000000000000001',msg91_pe_id='0000000000000000001',msg91_sender_id='KPTEST'
 WHERE id=(SELECT id FROM public.sms_config ORDER BY id DESC LIMIT 1);
SELECT warehouse_security.bootstrap_first_admin('9877777761','Marking Test Administrator') AS admin_user \gset
SELECT id AS admin_profile FROM public.user_profiles WHERE auth_user_id=:'admin_user'::uuid \gset
INSERT INTO public.user_profiles(auth_user_id,mobile,name,role,active,enrollment_status) VALUES
 (gen_random_uuid(),'919877777762','Marking Test Staff','staff',true,'approved');
SELECT pg_temp.km_login('9877777761') AS admin_claims \gset
SELECT pg_temp.km_login('9877777762') AS staff_claims \gset

-- Fixture: one lot of 20 bags marked AB-12 on rack R1, dispatched in full and invoiced (invoice 31).
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.km_assert(public.create_customer('Marking Test North','9877777763')->>'success'='true','customer');
SELECT pg_temp.km_assert(public.create_item('Marking Test Garlic','Bag')->>'success'='true','item');
SELECT id AS north FROM public.customers WHERE name='Marking Test North' \gset
SELECT id AS item_id FROM public.items WHERE name='Marking Test Garlic' \gset
SELECT pg_temp.km_assert(public.replace_item_rates(:'item_id'::uuid,:'north'::uuid,'monthly','2026-01-01'::date,jsonb_build_array(jsonb_build_object('weight_min',0,'weight_max',100,'unit_price',5,'labour_rate',2,'tax_percent',5)))->>'success'='true','price');
SELECT pg_temp.km_assert(public.save_grn(p_sender_name=>'Fixture Sender',p_supervisor_id=>(SELECT id FROM public.user_profiles WHERE NOT is_service_account ORDER BY created_at LIMIT 1),p_supervisor_name=>'Fixture Supervisor',p_gr_no=>'MK1',p_date=>'2026-04-01T12:00:00Z',p_customer_id=>:'north'::uuid,
 p_customer_name=>'Marking Test North',p_pricing_mode=>'ONE_TIME',p_idempotency_key=>'marking-grn-1',
 p_items=>jsonb_build_array(jsonb_build_object('item_id',:'item_id','item_name','Marking Test Garlic','packaging','Bag','qty',20,'weight',10,
   'rack','R1','package_mark','AB-12')))->>'success'='true','receipt MK1');
SELECT id AS grn1 FROM public.goodsreceived WHERE gr_no='MK1' \gset
SELECT pg_temp.km_assert(public.create_dispatch_with_stock_check(jsonb_build_object('customer_id',:'north','customer_name','Marking Test North',
 'supervisor_id',:'admin_profile','supervisor_name','Marking Test Administrator','disp_date','2026-05-02','disp_no','MKD1'),
 ARRAY[jsonb_build_object('gr_trl_id',(SELECT t.id FROM public.goodsreceived_trl t WHERE t.gr_id=:'grn1'::uuid),'disp_qty',20)],0,'marking-dispatch-1')->>'success'='true','dispatch MKD1');
RESET ROLE;
SELECT set_config('request.jwt.claims',:'staff_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.km_assert(public.save_invoice(NULL::uuid,
 jsonb_build_object('inv_fin_year',2026,'inv_no',31,'customer_id',:'north','customer_name','Marking Test North',
  'inv_date','2026-05-02T12:00:00Z','total',0,'tax_amount',0,'labour',0,'discount',0,'duration_mode','legacy','gr_id',:'grn1','gr_no','MK1'),
 ARRAY(SELECT jsonb_build_object('disp_trl_id',t.id,'grn_item_id',t.gr_trl_id,'duration',1,'charge',5,'tax',5,'labour_rate',2)
       FROM public.dispatch_trl t WHERE t.gr_id=:'grn1'::uuid))->>'success'='true','staff issues invoice 31');
RESET ROLE;
SELECT id AS inv1 FROM public.invoice WHERE inv_no=31 AND inv_fin_year=2026 \gset
SELECT pg_temp.km_amounts(:'inv1'::uuid) AS amounts_before \gset

-- Before the change: the invoice shows AB-12 and R1 (fixture sanity, so the later checks mean something).
SELECT set_config('request.jwt.claims',:'staff_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.get_invoice_detail(:'inv1'::uuid) AS detail_before \gset
RESET ROLE;
SELECT pg_temp.km_assert(:'detail_before'::jsonb#>>'{items,0,package_mark}'='AB-12' AND :'detail_before'::jsonb#>>'{items,0,rack}'='R1',
  'fixture: the issued invoice shows AB-12 and R1: '||:'detail_before');

-- The lot's marking becomes AB-15 and its rack R2 (trigger-free, as the other suites edit a lot after billing).
SET LOCAL session_replication_role = replica;
UPDATE public.goodsreceived_trl SET package_mark='AB-15', rack='R2' WHERE gr_id=:'grn1'::uuid;
RESET session_replication_role;

-- The invoice details keep what the invoice was issued with.
SELECT set_config('request.jwt.claims',:'staff_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.get_invoice_detail(:'inv1'::uuid) AS detail_after \gset
SELECT public.get_invoice_data(:'inv1'::uuid) AS data_after \gset
SELECT public.get_grn_details(:'grn1'::uuid)::text AS grn_after \gset
RESET ROLE;
SELECT pg_temp.km_assert(jsonb_array_length(:'detail_after'::jsonb->'items')=1
  AND :'detail_after'::jsonb#>>'{items,0,package_mark}'='AB-12' AND :'detail_after'::jsonb#>>'{items,0,rack}'='R1',
  'get_invoice_detail still shows AB-12 and R1 after the lot changed: '||:'detail_after');
-- The data behind the printed invoice.
SELECT pg_temp.km_assert(jsonb_array_length(:'data_after'::jsonb#>'{data,items}')=1
  AND :'data_after'::jsonb#>>'{data,items,0,grn_item,package_mark}'='AB-12' AND :'data_after'::jsonb#>>'{data,items,0,grn_item,rack}'='R1',
  'get_invoice_data still shows AB-12 and R1 after the lot changed: '||:'data_after');
-- The preprinted slip.
SELECT set_config('request.jwt.claims','{"role":"service_role"}',true);
SET LOCAL ROLE service_role;
SELECT public.get_invoice_range_for_print('31','31',2026,100) AS print_after \gset
RESET ROLE;
SELECT pg_temp.km_assert(jsonb_path_query_array(:'print_after'::jsonb,'$.**.grn_items_package_mark')='["AB-12"]'::jsonb
  AND jsonb_path_query_array(:'print_after'::jsonb,'$.**.grn_items_rack')='["R1"]'::jsonb,
  'get_invoice_range_for_print still carries AB-12 and R1 after the lot changed: '||:'print_after');

-- The lot itself shows the new values.
SELECT pg_temp.km_assert((SELECT package_mark='AB-15' AND rack='R2' FROM public.goodsreceived_trl WHERE gr_id=:'grn1'::uuid),'the lot row holds AB-15 and R2');
SELECT pg_temp.km_assert(:'grn_after' LIKE '%"AB-15"%' AND :'grn_after' LIKE '%"R2"%' AND :'grn_after' NOT LIKE '%"AB-12"%' AND :'grn_after' NOT LIKE '%"R1"%',
  'get_grn_details shows AB-15 and R2, not AB-12 or R1');

-- Amounts and totals do not change.
SELECT pg_temp.km_assert(pg_temp.km_amounts(:'inv1'::uuid)=:'amounts_before','totals and line amounts of invoice 31 are unchanged');
ROLLBACK;
