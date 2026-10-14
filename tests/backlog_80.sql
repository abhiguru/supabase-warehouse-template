-- Migration 80 (2026-10-14): backlog fixes.
--   1. save_grn / update_grn refuse a service account as supervisor (P0001); update_grn lets an edit
--      send back the supervisor a receipt already has.
--   2. get_or_create_cart refuses a deactivated or deleted business ('Business is not active').
--   3. Total weights are bags x kg per bag: get_grn_details statistics.total_weight, and the stock
--      aging report's summary.total_weight_kg and by_bucket total_weight (bags still in stock).
--   4. get_my_access_status(): 'active' | 'revoked' | 'none'; not callable without signing in.
-- Fictional data; runs only in migrations.sh's disposable, network-disabled database.
\set ON_ERROR_STOP on
BEGIN;
CREATE FUNCTION pg_temp.bl_assert(ok boolean, label text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF NOT COALESCE(ok,false) THEN RAISE EXCEPTION 'backlog 80: %',label; END IF; END $$;
CREATE FUNCTION pg_temp.bl_call(statement text) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE answer jsonb;
BEGIN
  BEGIN EXECUTE statement INTO answer;
  EXCEPTION WHEN OTHERS THEN RETURN jsonb_build_object('raised', SQLERRM, 'state', SQLSTATE); END;
  RETURN answer;
END $$;
CREATE FUNCTION pg_temp.bl_login(phone text) RETURNS jsonb LANGUAGE plpgsql AS $$
 DECLARE c jsonb; l jsonb; claims jsonb;
 BEGIN
  c:=public.operator_prepare_otp(phone);
  PERFORM pg_temp.bl_assert(c->>'success'='true','challenge prepared for '||phone);
  PERFORM public.operator_finish_otp((c#>>'{data,request_id}')::uuid,true,'mock-provider-only');
  l:=public.operator_verify_otp(phone,c#>>'{data,otp_code}');
  PERFORM pg_temp.bl_assert(l#>>'{data,action}'='login','login for '||phone||': '||l::text);
  SELECT jsonb_build_object('role','authenticated','sub',p.auth_user_id,'session_id',r.id) INTO claims
   FROM public.user_profiles p JOIN warehouse_security.refresh_sessions r ON r.user_id=p.auth_user_id
   WHERE p.mobile=warehouse_security.normalize_phone(phone) ORDER BY r.created_at DESC LIMIT 1;
  RETURN claims;
 END $$;
INSERT INTO warehouse_security.auth_config(key,value) VALUES
 ('jwt_secret','isolated-test-secret-not-for-any-deployment-12345'),('auth_mode','operator'),('demo_auth_enabled','false')
 ON CONFLICT(key) DO UPDATE SET value=excluded.value;
UPDATE public.sms_config SET provider='msg91',production_mode=true,msg91_auth_key='isolated-test-key',
 msg91_template_id='000000000000000000000001',msg91_pe_id='0000000000000000001',msg91_sender_id='CITEST'
 WHERE id=(SELECT id FROM public.sms_config ORDER BY id DESC LIMIT 1);
SELECT warehouse_security.bootstrap_first_admin('9555560001','Backlog Admin') AS admin_user \gset
INSERT INTO public.user_profiles(auth_user_id,mobile,name,role,active,enrollment_status) VALUES
 (gen_random_uuid(),'919555560002','Backlog Customer Active','customer',true,'approved'),
 (gen_random_uuid(),'919555560003','Backlog Customer None','customer',true,'approved'),
 (gen_random_uuid(),'919555560004','Backlog Customer Revoked','customer',true,'approved'),
 (gen_random_uuid(),'919555560005','Backlog Person Supervisor','supervisor',true,'approved'),
 (gen_random_uuid(),'919555560006','Backlog Sync Connection','staff',true,'approved'),
 (gen_random_uuid(),'919555560007','Backlog Customer Inactive','customer',true,'approved');
SELECT id AS admin_id FROM public.user_profiles WHERE auth_user_id=:'admin_user'::uuid \gset
SELECT id AS person_id FROM public.user_profiles WHERE mobile='919555560005' \gset
SELECT id AS sync_id FROM public.user_profiles WHERE mobile='919555560006' \gset
SELECT pg_temp.bl_login('9555560001') AS admin_claims \gset
SELECT pg_temp.bl_login('9555560002') AS active_claims \gset
SELECT pg_temp.bl_login('9555560003') AS none_claims \gset
SELECT pg_temp.bl_login('9555560004') AS revoked_claims \gset
SELECT pg_temp.bl_login('9555560007') AS inactive_claims \gset
INSERT INTO public.customers(name,mobile) VALUES ('Backlog Business One','9555560101') RETURNING id AS customer_one \gset
INSERT INTO public.customers(name,mobile) VALUES ('Backlog Business Two','9555560102') RETURNING id AS customer_two \gset
INSERT INTO public.customers(name,mobile) VALUES ('Backlog Business Three','9555560103') RETURNING id AS customer_three \gset
INSERT INTO public.items(name,packaging) VALUES ('Backlog Ginger','Bag') RETURNING id AS item_id \gset
INSERT INTO public.users_customers_new(user_profile_id,customer_id,active)
 SELECT p.id,c.id,true FROM public.user_profiles p CROSS JOIN (VALUES (:'customer_one'::uuid),(:'customer_two'::uuid),(:'customer_three'::uuid)) c(id)
 WHERE p.mobile='919555560002';
INSERT INTO public.users_customers_new(user_profile_id,customer_id,active)
 SELECT id,:'customer_one'::uuid,true FROM public.user_profiles WHERE mobile IN ('919555560004','919555560007');

-- ---- 4. get_my_access_status
SELECT pg_temp.bl_assert(has_function_privilege('authenticated','public.get_my_access_status()','EXECUTE')
 AND NOT has_function_privilege('anon','public.get_my_access_status()','EXECUTE')
 AND NOT has_function_privilege('public','public.get_my_access_status()','EXECUTE'),'grants of get_my_access_status');
SELECT pg_temp.bl_assert((SELECT prosecdef AND proconfig = ARRAY['search_path=pg_catalog'] AND prorettype='text'::regtype AND pronargs=0
   FROM pg_proc WHERE oid='public.get_my_access_status()'::regprocedure),'security definer, fixed search_path, text, no argument');
-- The revoked ones are revoked after they signed in: the assignment is switched off / the profile is switched off.
UPDATE public.users_customers_new SET active=false WHERE user_profile_id=(SELECT id FROM public.user_profiles WHERE mobile='919555560004');
UPDATE public.user_profiles SET active=false WHERE mobile='919555560007';
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.get_my_access_status() AS s_admin \gset
RESET ROLE;
SELECT set_config('request.jwt.claims',:'active_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.get_my_access_status() AS s_active \gset
RESET ROLE;
SELECT set_config('request.jwt.claims',:'none_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.get_my_access_status() AS s_none \gset
RESET ROLE;
SELECT set_config('request.jwt.claims',:'revoked_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.get_my_access_status() AS s_revoked \gset
RESET ROLE;
SELECT set_config('request.jwt.claims',:'inactive_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.get_my_access_status() AS s_inactive \gset
RESET ROLE;
SELECT pg_temp.bl_assert(:'s_admin'='active' AND :'s_active'='active' AND :'s_none'='none' AND :'s_revoked'='revoked' AND :'s_inactive'='revoked',
 'administrator active, customer with an active assignment active, customer without any none, all assignments off revoked, inactive profile revoked: '
 ||:'s_admin'||' '||:'s_active'||' '||:'s_none'||' '||:'s_revoked'||' '||:'s_inactive');
-- Not callable without signing in.
SELECT set_config('request.jwt.claims','{"role":"anon"}',true);
SET LOCAL ROLE anon;
SELECT pg_temp.bl_call('SELECT public.get_my_access_status()') AS s_anon \gset
RESET ROLE;
SELECT pg_temp.bl_assert(:'s_anon'::jsonb->>'state'='42501','anon is refused with 42501: '||:'s_anon');

-- ---- 1. A service account is not a supervisor
UPDATE public.user_profiles SET is_service_account=true WHERE id=:'sync_id'::uuid;
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.bl_call(format($q$SELECT public.save_grn(p_gr_no=>'BL80X',p_date=>now(),p_customer_id=>%L::uuid,p_customer_name=>'Backlog Business One',
  p_supervisor_id=>%L::uuid,p_items=>jsonb_build_array(jsonb_build_object('item_id',%L,'item_name','Backlog Ginger','packaging','Bag','qty',1,'weight',1)),
  p_idempotency_key=>'bl80-sa')$q$,:'customer_one',:'sync_id',:'item_id')) AS save_sa \gset
SELECT public.save_grn(p_gr_no=>'BL80A',p_date=>now(),p_customer_id=>:'customer_one'::uuid,p_customer_name=>'Backlog Business One',
  p_supervisor_id=>:'person_id'::uuid,p_pricing_mode=>'MONTHLY',
  p_items=>jsonb_build_array(jsonb_build_object('item_id',:'item_id','item_name','Backlog Ginger','packaging','Bag','qty',10,'weight',12,'rack','A1'),
                             jsonb_build_object('item_id',:'item_id','item_name','Backlog Ginger Small','packaging','Bag','qty',4,'weight',5,'rack','A2')),
  p_idempotency_key=>'bl80-person') AS save_person \gset
RESET ROLE;
SELECT pg_temp.bl_assert(:'save_sa'::jsonb->>'raised'='Supervisor must be a person, not a service account' AND :'save_sa'::jsonb->>'state'='P0001'
 AND NOT EXISTS (SELECT 1 FROM public.goodsreceived WHERE gr_no='BL80X'),'save_grn refuses a service account as supervisor and stores nothing: '||:'save_sa');
SELECT pg_temp.bl_assert(:'save_person'::jsonb->>'success'='true' AND (SELECT supervisor_id=:'person_id'::uuid FROM public.goodsreceived WHERE gr_no='BL80A'),
 'save_grn accepts a person as supervisor: '||:'save_person');
SELECT id AS grn_id FROM public.goodsreceived WHERE gr_no='BL80A' \gset
SELECT id AS lot_big FROM public.goodsreceived_trl WHERE gr_id=:'grn_id'::uuid AND item_name='Backlog Ginger' \gset
SELECT id AS lot_small FROM public.goodsreceived_trl WHERE gr_id=:'grn_id'::uuid AND item_name='Backlog Ginger Small' \gset
SELECT jsonb_build_array(
  jsonb_build_object('id',:'lot_big','item_id',:'item_id','item_name','Backlog Ginger','packaging','Bag','qty',10,'weight',12,'rack','A1'),
  jsonb_build_object('id',:'lot_small','item_id',:'item_id','item_name','Backlog Ginger Small','packaging','Bag','qty',4,'weight',5,'rack','A2')) AS lines \gset
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.bl_call(format('SELECT public.update_grn(p_grn_id=>%L::uuid,p_supervisor_id=>%L::uuid,p_items=>%L::jsonb)',:'grn_id',:'sync_id',:'lines')) AS update_sa \gset
RESET ROLE;
SELECT pg_temp.bl_assert(:'update_sa'::jsonb->>'raised'='Supervisor must be a person, not a service account' AND :'update_sa'::jsonb->>'state'='P0001'
 AND (SELECT supervisor_id=:'person_id'::uuid FROM public.goodsreceived WHERE id=:'grn_id'::uuid),'update_grn refuses a service account and keeps the supervisor: '||:'update_sa');
-- An edit that sends back a supervisor the receipt already has still saves, even if that profile was marked since.
UPDATE public.goodsreceived SET supervisor_id=:'sync_id'::uuid WHERE id=:'grn_id'::uuid;
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.update_grn(p_grn_id=>:'grn_id'::uuid,p_supervisor_id=>:'sync_id'::uuid,p_note=>'Same supervisor',p_items=>:'lines'::jsonb) AS update_same \gset
SELECT public.update_grn(p_grn_id=>:'grn_id'::uuid,p_supervisor_id=>:'person_id'::uuid,p_note=>'Back to a person',p_items=>:'lines'::jsonb) AS update_person \gset
RESET ROLE;
SELECT pg_temp.bl_assert(:'update_same'::jsonb->>'success'='true' AND :'update_person'::jsonb->>'success'='true'
 AND (SELECT supervisor_id=:'person_id'::uuid AND note='Back to a person' FROM public.goodsreceived WHERE id=:'grn_id'::uuid),
 'update_grn keeps an unchanged supervisor and accepts a person: '||:'update_same'||:'update_person');

-- ---- 3. Total weights are bags x kg per bag: 10 x 12 + 4 x 5 = 140 (the old sum of per-bag weights is 17)
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.get_grn_details(:'grn_id'::uuid) AS details \gset
SELECT public.get_stock_aging_report(:'customer_one'::uuid) AS aging_before \gset
RESET ROLE;
SELECT pg_temp.bl_assert((jsonb_path_query_first(:'details'::jsonb,'$.**.statistics.total_weight'))::text::numeric=140,
 'get_grn_details total_weight is 140: '||left(:'details',300));
SELECT pg_temp.bl_assert((:'aging_before'::jsonb#>>'{data,summary,total_weight_kg}')::numeric=140
 AND (:'aging_before'::jsonb#>>'{data,by_bucket,0-120,total_weight}')::numeric=140,'aging total 140 before a dispatch: '||left(:'aging_before',300));
-- Dispatch 3 bags of the 12 kg line: stock 7 x 12 + 4 x 5 = 104; the received weight stays 140.
SELECT jsonb_build_object('disp_no','BL80D','disp_date',now(),'customer_id',:'customer_one','customer_name','Backlog Business One',
  'supervisor_id',:'admin_id','supervisor_name','Backlog Admin') AS dispatch_data \gset
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.create_dispatch_with_stock_check(:'dispatch_data'::jsonb,
 ARRAY[jsonb_build_object('gr_trl_id',:'lot_big','disp_qty',3)],false,0,'bl80-dispatch') AS dispatch \gset
SELECT public.get_stock_aging_report(:'customer_one'::uuid) AS aging_after \gset
SELECT public.get_grn_details(:'grn_id'::uuid) AS details_after \gset
RESET ROLE;
SELECT pg_temp.bl_assert(:'dispatch'::jsonb->>'success'='true','dispatch of 3 bags: '||:'dispatch');
SELECT pg_temp.bl_assert((:'aging_after'::jsonb#>>'{data,summary,total_weight_kg}')::numeric=104
 AND (:'aging_after'::jsonb#>>'{data,by_bucket,0-120,total_weight}')::numeric=104
 AND (:'aging_after'::jsonb#>>'{data,by_bucket,121-240,total_weight}')::numeric=0
 AND (SELECT bool_or((i->>'weight')::numeric=12) FROM jsonb_array_elements(:'aging_after'::jsonb#>'{data,items}') i),
 'aging total is the stock left, 104, and a line keeps its per-bag weight 12: '||left(:'aging_after',400));
SELECT pg_temp.bl_assert((jsonb_path_query_first(:'details_after'::jsonb,'$.**.statistics.total_weight'))::text::numeric=140,
 'the receipt total stays the received 140 after a dispatch');

-- ---- 2. No order for a deactivated or deleted business
SELECT set_config('request.jwt.claims',:'active_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.bl_call(format('SELECT to_jsonb(public.get_or_create_cart(%L::uuid))',:'customer_two')) AS cart_ok \gset
RESET ROLE;
SELECT pg_temp.bl_assert(NOT (:'cart_ok'::jsonb ? 'raised') AND (SELECT count(*)=1 FROM public.orders WHERE customer_id=:'customer_two'::uuid),
 'an active business gets its order: '||:'cart_ok');
UPDATE public.customers SET active=false WHERE id=:'customer_one'::uuid;
UPDATE public.customers SET deleted_at=now() WHERE id=:'customer_three'::uuid;
SELECT set_config('request.jwt.claims',:'active_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.bl_call(format('SELECT to_jsonb(public.get_or_create_cart(%L::uuid))',:'customer_one')) AS cart_inactive \gset
SELECT pg_temp.bl_call(format('SELECT to_jsonb(public.get_or_create_cart(%L::uuid))',:'customer_three')) AS cart_deleted \gset
SELECT pg_temp.bl_call(format('SELECT to_jsonb(public.get_or_create_cart(%L::uuid))',:'customer_two')) AS cart_again \gset
RESET ROLE;
SELECT pg_temp.bl_assert(:'cart_inactive'::jsonb->>'raised'='Business is not active' AND :'cart_inactive'::jsonb->>'state'='P0001'
 AND :'cart_deleted'::jsonb->>'raised'='Business is not active' AND :'cart_deleted'::jsonb->>'state'='P0001'
 AND NOT EXISTS (SELECT 1 FROM public.orders WHERE customer_id IN (:'customer_one'::uuid,:'customer_three'::uuid)),
 'a deactivated and a deleted business get no order: '||:'cart_inactive'||:'cart_deleted');
SELECT pg_temp.bl_assert(:'cart_again'::jsonb = :'cart_ok'::jsonb,'the active business still gets the same cart: '||:'cart_again');
ROLLBACK;
