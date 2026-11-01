-- Migration 141: the packaging word on the lines the app prints. build_invoice_form_lines (through generate_invoice_data_for_grn_with_pricing),
-- get_invoice_detail, get_customer_dispatch_activity and get_customer_activity_detail answer "packaging" taken from the receipt line; nothing else
-- changes. Fictional data; runs only in migrations.sh's disposable, network-disabled database; rolls back.
\set ON_ERROR_STOP on
BEGIN;
CREATE FUNCTION pg_temp.pk_assert(ok boolean, label text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF NOT COALESCE(ok,false) THEN RAISE EXCEPTION 'packaging 141: %',label; END IF; END $$;
-- The single jsonb answer of a call, or {"raised": message, "state": sqlstate}.
CREATE FUNCTION pg_temp.pk_call(statement text) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE answer jsonb;
BEGIN
  BEGIN EXECUTE statement INTO answer;
  EXCEPTION WHEN OTHERS THEN RETURN jsonb_build_object('raised', SQLERRM, 'state', SQLSTATE); END;
  RETURN answer;
END $$;
CREATE FUNCTION pg_temp.pk_login(phone text) RETURNS jsonb LANGUAGE plpgsql AS $$
 DECLARE c jsonb; l jsonb; claims jsonb;
 BEGIN
  c:=public.operator_prepare_otp(phone);
  PERFORM pg_temp.pk_assert(c->>'success'='true','challenge prepared for '||phone);
  PERFORM public.operator_finish_otp((c#>>'{data,request_id}')::uuid,true,'mock-provider-only');
  l:=public.operator_verify_otp(phone,c#>>'{data,otp_code}');
  PERFORM pg_temp.pk_assert(l#>>'{data,action}'='login','login for '||phone);
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
SELECT warehouse_security.bootstrap_first_admin('9877778831','Cancel Test Administrator') AS admin_user \gset
SELECT id AS admin_profile FROM public.user_profiles WHERE auth_user_id=:'admin_user'::uuid \gset
INSERT INTO public.user_profiles(auth_user_id,mobile,name,role,active,enrollment_status) VALUES
 (gen_random_uuid(),'919877778832','Cancel Test Supervisor','supervisor',true,'approved'),
 (gen_random_uuid(),'919877778833','Cancel Test Staff','staff',true,'approved'),
 (gen_random_uuid(),'919877778834','Cancel Test Reader','customer',true,'approved'),
 (gen_random_uuid(),'919877778835','Cancel Test Other Reader','customer',true,'approved');
SELECT id AS staff_profile FROM public.user_profiles WHERE mobile='919877778833' \gset
SELECT pg_temp.pk_login('9877778831') AS admin_claims \gset
SELECT pg_temp.pk_login('9877778832') AS supervisor_claims \gset
SELECT pg_temp.pk_login('9877778833') AS staff_claims \gset
SELECT pg_temp.pk_login('9877778834') AS customer_claims \gset
SELECT pg_temp.pk_login('9877778835') AS other_claims \gset

SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.pk_assert(public.create_customer('Packaging Test Customer','9877788836')->>'success'='true','customer');
SELECT pg_temp.pk_assert(public.create_item('Packaging Test Garlic','Bag')->>'success'='true','catalog item');
SELECT id AS cust FROM public.customers WHERE name='Packaging Test Customer' \gset
SELECT id AS item_id FROM public.items WHERE name='Packaging Test Garlic' \gset
SELECT pg_temp.pk_assert(public.replace_item_rates(:'item_id'::uuid,:'cust'::uuid,'monthly','2026-01-01'::date,jsonb_build_array(jsonb_build_object('weight_min',0,'weight_max',100,'unit_price',5,'labour_rate',2,'tax_percent',5)))->>'success'='true','rate');
-- PK1 is dispatched in full and invoiced; PK2 keeps stock. The lots carry different packaging words on purpose (PK3 'Box' next to PK2 'Bag').
SELECT pg_temp.pk_assert(public.save_grn(p_gr_no=>'PK1',p_date=>'2026-04-01T12:00:00Z',p_customer_id=>:'cust'::uuid,p_customer_name=>'Packaging Test Customer',
 p_pricing_mode=>'ONE_TIME',p_idempotency_key=>'pk-grn-1',p_items=>jsonb_build_array(jsonb_build_object('item_id',:'item_id','item_name','Packaging Test Garlic',
 'packaging','Box','qty',20,'weight',10,'rack','PK1')))->>'success'='true','receipt PK1');
SELECT pg_temp.pk_assert(public.save_grn(p_gr_no=>'PK2',p_date=>'2026-04-01T12:00:00Z',p_customer_id=>:'cust'::uuid,p_customer_name=>'Packaging Test Customer',
 p_pricing_mode=>'ONE_TIME',p_idempotency_key=>'pk-grn-2',p_items=>jsonb_build_array(jsonb_build_object('item_id',:'item_id','item_name','Packaging Test Garlic',
 'packaging','Bag','qty',20,'weight',10,'rack','PK2')))->>'success'='true','receipt PK2');
SELECT pg_temp.pk_assert(public.save_grn(p_gr_no=>'PK3',p_date=>'2026-04-01T12:00:00Z',p_customer_id=>:'cust'::uuid,p_customer_name=>'Packaging Test Customer',
 p_pricing_mode=>'ONE_TIME',p_idempotency_key=>'pk-grn-3',p_items=>jsonb_build_array(jsonb_build_object('item_id',:'item_id','item_name','Packaging Test Garlic',
 'packaging','Bag','qty',20,'weight',10,'rack','PK3')))->>'success'='true','receipt PK3');
SELECT id AS grn1 FROM public.goodsreceived WHERE gr_no='PK1' \gset
SELECT public.create_dispatch_with_stock_check(jsonb_build_object('customer_id',:'cust','customer_name','Packaging Test Customer',
 'supervisor_id',:'admin_profile','supervisor_name','Packaging Test Administrator','disp_date','2026-05-02','disp_no','PKD1'),
 ARRAY[jsonb_build_object('gr_trl_id',(SELECT t.id FROM public.goodsreceived_trl t WHERE t.gr_id=:'grn1'::uuid),'disp_qty',20)],
 0,'pk-dispatch-1') AS disp \gset
SELECT pg_temp.pk_assert(:'disp'::jsonb->>'success'='true','dispatch PKD1: '||:'disp');

-- The invoice form lines (generate_invoice_data_for_grn_with_pricing).
SELECT public.generate_invoice_data_for_grn_with_pricing(:'grn1'::uuid) AS gen \gset
SELECT pg_temp.pk_assert(:'gen'::jsonb->>'success'='true' AND jsonb_array_length(:'gen'::jsonb->'items')=1
  AND :'gen'::jsonb#>>'{items,0,grn_items_packaging}'='Box' AND :'gen'::jsonb#>>'{items,0,grn_items_item_name}'='Packaging Test Garlic',
  'the invoice form line says Box: '||:'gen');

-- The saved invoice (get_invoice_detail).
SELECT set_config('request.jwt.claims',:'staff_claims',true);
SELECT public.save_invoice(NULL::uuid,
 jsonb_build_object('inv_fin_year',2026,'inv_no',9,'customer_id',:'cust','customer_name','Packaging Test Customer',
  'inv_date','2026-05-02T12:00:00Z','total',0,'tax_amount',0,'labour',0,'discount',0,'duration_mode','legacy','gr_id',:'grn1','gr_no','PK1'),
 ARRAY(SELECT jsonb_build_object('disp_trl_id',t.id,'grn_item_id',t.gr_trl_id,'duration',1,'charge',5,'tax',5,'labour_rate',2)
       FROM public.dispatch_trl t WHERE t.gr_id=:'grn1'::uuid)) AS saved \gset
SELECT pg_temp.pk_assert(:'saved'::jsonb->>'success'='true','invoice saved: '||:'saved');
SELECT public.get_invoice_detail((:'saved'::jsonb->>'invoice_id')::uuid) AS detail \gset
SELECT pg_temp.pk_assert(:'detail'::jsonb->>'success'='true' AND :'detail'::jsonb#>>'{items,0,packaging}'='Box','get_invoice_detail line says Box: '||:'detail');
SELECT public.get_invoice_data((:'saved'::jsonb->>'invoice_id')::uuid) AS idata \gset
SELECT pg_temp.pk_assert(:'idata'::jsonb::text LIKE '%"packaging": "Box"%','get_invoice_data still says Box');

-- The customer reports.
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SELECT public.get_customer_dispatch_activity(:'cust'::uuid,'2026-05-01'::date,'2026-05-31'::date) AS dact \gset
SELECT pg_temp.pk_assert(:'dact'::jsonb#>>'{dispatches,0,items,0,packaging}'='Box','dispatch activity row says Box: '||:'dact');
SELECT public.get_customer_activity_detail(:'cust'::uuid,'2026-05-01'::date,'2026-05-31'::date) AS adet \gset
-- Lots PK2 and PK3 are both Bag: one word. Add a Box lot with stock for the same item name: the word is then null (mixed), never a guess.
SELECT pg_temp.pk_assert(:'adet'::jsonb->>'success'='true' AND jsonb_array_length(COALESCE(:'adet'::jsonb#>'{data,top_stock_items}', :'adet'::jsonb->'top_stock_items'))=1
  AND COALESCE(:'adet'::jsonb#>>'{data,top_stock_items,0,packaging}', :'adet'::jsonb#>>'{top_stock_items,0,packaging}')='Bag','top stock row says Bag: '||:'adet');
SELECT pg_temp.pk_assert(public.save_grn(p_gr_no=>'PK4',p_date=>'2026-04-01T12:00:00Z',p_customer_id=>:'cust'::uuid,p_customer_name=>'Packaging Test Customer',
 p_pricing_mode=>'ONE_TIME',p_idempotency_key=>'pk-grn-4',p_items=>jsonb_build_array(jsonb_build_object('item_id',:'item_id','item_name','Packaging Test Garlic',
 'packaging','Box','qty',5,'weight',10,'rack','PK4')))->>'success'='true','receipt PK4');
SELECT public.get_customer_activity_detail(:'cust'::uuid,'2026-05-01'::date,'2026-05-31'::date) AS adet2 \gset
SELECT pg_temp.pk_assert(COALESCE(:'adet2'::jsonb#>'{data,top_stock_items,0}', :'adet2'::jsonb#>'{top_stock_items,0}') ? 'packaging'
  AND COALESCE(:'adet2'::jsonb#>>'{data,top_stock_items,0,packaging}', :'adet2'::jsonb#>>'{top_stock_items,0,packaging}') IS NULL,'mixed lots: the packaging key is present and null: '||:'adet2');
ROLLBACK;
