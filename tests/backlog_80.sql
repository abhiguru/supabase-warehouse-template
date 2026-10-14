-- Migration 80 (2026-10-14): backlog fixes.
--   1. save_grn, update_grn, create_dispatch_with_stock_check and update_dispatch_smart refuse a service
--      account as supervisor (P0001) unless it is the caller's own profile (the FAS sync names itself);
--      the two edits let a document keep the supervisor it already has.
--   2. get_or_create_cart refuses a deactivated or deleted business ('Business is not active'): never a
--      new order, never a customer; administrator, supervisor and staff may open the existing OPEN one.
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
 (gen_random_uuid(),'919555560007','Backlog Customer Inactive','customer',true,'approved'),
 (gen_random_uuid(),'919555560008','Backlog Other Connection','staff',true,'approved'),
 (gen_random_uuid(),'919555560009','Backlog Staff','staff',true,'approved'),
 (gen_random_uuid(),'919555560010','Backlog Customer Mixed','customer',true,'approved');
SELECT id AS admin_id FROM public.user_profiles WHERE auth_user_id=:'admin_user'::uuid \gset
SELECT id AS person_id FROM public.user_profiles WHERE mobile='919555560005' \gset
SELECT id AS sync_id FROM public.user_profiles WHERE mobile='919555560006' \gset
SELECT id AS other_sync_id FROM public.user_profiles WHERE mobile='919555560008' \gset
SELECT pg_temp.bl_login('9555560001') AS admin_claims \gset
SELECT pg_temp.bl_login('9555560002') AS active_claims \gset
SELECT pg_temp.bl_login('9555560003') AS none_claims \gset
SELECT pg_temp.bl_login('9555560004') AS revoked_claims \gset
SELECT pg_temp.bl_login('9555560007') AS inactive_claims \gset
SELECT pg_temp.bl_login('9555560005') AS supervisor_claims \gset
SELECT pg_temp.bl_login('9555560006') AS sync_claims \gset
SELECT pg_temp.bl_login('9555560009') AS staff_claims \gset
SELECT pg_temp.bl_login('9555560010') AS mixed_claims \gset
INSERT INTO public.customers(name,mobile) VALUES ('Backlog Business One','9555560101') RETURNING id AS customer_one \gset
INSERT INTO public.customers(name,mobile) VALUES ('Backlog Business Two','9555560102') RETURNING id AS customer_two \gset
INSERT INTO public.customers(name,mobile) VALUES ('Backlog Business Three','9555560103') RETURNING id AS customer_three \gset
INSERT INTO public.customers(name,mobile) VALUES ('Backlog Business Four','9555560104') RETURNING id AS customer_four \gset
INSERT INTO public.items(name,packaging) VALUES ('Backlog Ginger','Bag') RETURNING id AS item_id \gset
INSERT INTO public.users_customers_new(user_profile_id,customer_id,active)
 SELECT p.id,c.id,true FROM public.user_profiles p CROSS JOIN (VALUES (:'customer_one'::uuid),(:'customer_two'::uuid),(:'customer_three'::uuid),(:'customer_four'::uuid)) c(id)
 WHERE p.mobile='919555560002';
INSERT INTO public.users_customers_new(user_profile_id,customer_id,active)
 SELECT p.id,c.id,c.is_active FROM public.user_profiles p CROSS JOIN (VALUES (:'customer_two'::uuid,true),(:'customer_three'::uuid,false)) c(id,is_active)
 WHERE p.mobile='919555560010';
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
-- One active and one inactive assignment, a supervisor, staff, and a signed-in user with no profile at all.
SELECT set_config('request.jwt.claims',:'mixed_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.get_my_access_status() AS s_mixed \gset
RESET ROLE;
SELECT set_config('request.jwt.claims',:'supervisor_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.get_my_access_status() AS s_supervisor \gset
RESET ROLE;
SELECT set_config('request.jwt.claims',:'staff_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.get_my_access_status() AS s_staff \gset
RESET ROLE;
SELECT set_config('request.jwt.claims',jsonb_build_object('role','authenticated','sub',gen_random_uuid())::text,true);
SET LOCAL ROLE authenticated;
SELECT public.get_my_access_status() AS s_missing \gset
RESET ROLE;
SELECT pg_temp.bl_assert(:'s_mixed'='active' AND :'s_supervisor'='active' AND :'s_staff'='active' AND :'s_missing'='none',
 'one active + one inactive assignment active, supervisor active, staff active, no profile none: '||:'s_mixed'||' '||:'s_supervisor'||' '||:'s_staff'||' '||:'s_missing');

-- ---- 1. A service account is not a supervisor, unless it names itself
UPDATE public.user_profiles SET is_service_account=true WHERE id IN (:'sync_id'::uuid,:'other_sync_id'::uuid);
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
 AND NOT EXISTS (SELECT 1 FROM public.goodsreceived WHERE gr_no='BL80X'),'a person naming a service account in save_grn is refused and nothing is stored: '||:'save_sa');
SELECT pg_temp.bl_assert(:'save_person'::jsonb->>'success'='true' AND (SELECT supervisor_id=:'person_id'::uuid FROM public.goodsreceived WHERE gr_no='BL80A'),
 'save_grn accepts a person naming a person: '||:'save_person');
-- The service account acts as itself, as the FAS sync does (claims with its auth user): naming itself is accepted,
-- naming another service account is not.
SELECT set_config('request.jwt.claims',:'sync_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.save_grn(p_gr_no=>'BL80S',p_date=>now(),p_customer_id=>:'customer_one'::uuid,p_customer_name=>'Backlog Business One',
  p_supervisor_id=>:'sync_id'::uuid,p_pricing_mode=>'MONTHLY',
  p_items=>jsonb_build_array(jsonb_build_object('item_id',:'item_id','item_name','Backlog Ginger','packaging','Bag','qty',2,'weight',3,'rack','A3')),
  p_idempotency_key=>'bl80-self') AS save_self \gset
SELECT pg_temp.bl_call(format($q$SELECT public.save_grn(p_gr_no=>'BL80Y',p_date=>now(),p_customer_id=>%L::uuid,p_customer_name=>'Backlog Business One',
  p_supervisor_id=>%L::uuid,p_items=>jsonb_build_array(jsonb_build_object('item_id',%L,'item_name','Backlog Ginger','packaging','Bag','qty',1,'weight',1)),
  p_idempotency_key=>'bl80-other')$q$,:'customer_one',:'other_sync_id',:'item_id')) AS save_other \gset
RESET ROLE;
SELECT pg_temp.bl_assert(:'save_self'::jsonb->>'success'='true' AND (SELECT supervisor_id=:'sync_id'::uuid FROM public.goodsreceived WHERE gr_no='BL80S'),
 'a service account naming itself in save_grn is accepted: '||:'save_self');
SELECT pg_temp.bl_assert(:'save_other'::jsonb->>'raised'='Supervisor must be a person, not a service account' AND NOT EXISTS (SELECT 1 FROM public.goodsreceived WHERE gr_no='BL80Y'),
 'a service account naming another service account is refused: '||:'save_other');

SELECT id AS grn_id FROM public.goodsreceived WHERE gr_no='BL80A' \gset
SELECT id AS lot_big FROM public.goodsreceived_trl WHERE gr_id=:'grn_id'::uuid AND item_name='Backlog Ginger' \gset
SELECT id AS lot_small FROM public.goodsreceived_trl WHERE gr_id=:'grn_id'::uuid AND item_name='Backlog Ginger Small' \gset
SELECT jsonb_build_array(
  jsonb_build_object('id',:'lot_big','item_id',:'item_id','item_name','Backlog Ginger','packaging','Bag','qty',10,'weight',12,'rack','A1'),
  jsonb_build_object('id',:'lot_small','item_id',:'item_id','item_name','Backlog Ginger Small','packaging','Bag','qty',4,'weight',5,'rack','A2')) AS lines \gset
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.bl_call(format('SELECT public.update_grn(p_grn_id=>%L::uuid,p_supervisor_id=>%L::uuid,p_items=>%L::jsonb)',:'grn_id',:'sync_id',:'lines')) AS update_sa \gset
SELECT public.update_grn(p_grn_id=>gen_random_uuid(),p_supervisor_id=>:'sync_id'::uuid) AS update_missing \gset
RESET ROLE;
SELECT pg_temp.bl_assert(:'update_sa'::jsonb->>'raised'='Supervisor must be a person, not a service account' AND :'update_sa'::jsonb->>'state'='P0001'
 AND (SELECT supervisor_id=:'person_id'::uuid FROM public.goodsreceived WHERE id=:'grn_id'::uuid),'update_grn: a person naming a service account is refused, supervisor kept: '||:'update_sa');
SELECT pg_temp.bl_assert(:'update_missing'::jsonb->>'success'='false' AND :'update_missing'::jsonb->>'message'='GRN not found',
 'update_grn answers GRN not found before the supervisor rule: '||:'update_missing');
-- The service account edits as itself and names itself; the unchanged supervisor of a document is kept for anyone.
SELECT set_config('request.jwt.claims',:'sync_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.update_grn(p_grn_id=>:'grn_id'::uuid,p_supervisor_id=>:'sync_id'::uuid,p_note=>'Named itself',p_items=>:'lines'::jsonb) AS update_self \gset
RESET ROLE;
SELECT pg_temp.bl_assert(:'update_self'::jsonb->>'success'='true' AND (SELECT supervisor_id=:'sync_id'::uuid FROM public.goodsreceived WHERE id=:'grn_id'::uuid),
 'update_grn: a service account naming itself is accepted: '||:'update_self');
UPDATE public.goodsreceived SET supervisor_id=:'other_sync_id'::uuid WHERE id=:'grn_id'::uuid;
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.update_grn(p_grn_id=>:'grn_id'::uuid,p_supervisor_id=>:'other_sync_id'::uuid,p_note=>'Same supervisor',p_items=>:'lines'::jsonb) AS update_same \gset
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
-- Business One also holds BL80S (2 bags x 3 kg = 6) from section 1: stock 146 kg before the dispatch.
SELECT pg_temp.bl_assert((:'aging_before'::jsonb#>>'{data,summary,total_weight_kg}')::numeric=146
 AND (:'aging_before'::jsonb#>>'{data,by_bucket,0-120,total_weight}')::numeric=146,'aging total 146 before a dispatch: '||left(:'aging_before',300));
-- Dispatch 3 bags of the 12 kg line: stock 7 x 12 + 4 x 5 + 6 = 110; the received weight of BL80A stays 140.
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
SELECT pg_temp.bl_assert((:'aging_after'::jsonb#>>'{data,summary,total_weight_kg}')::numeric=110
 AND (:'aging_after'::jsonb#>>'{data,by_bucket,0-120,total_weight}')::numeric=110
 AND (:'aging_after'::jsonb#>>'{data,by_bucket,121-240,total_weight}')::numeric=0
 AND (SELECT bool_or((i->>'weight')::numeric=12) FROM jsonb_array_elements(:'aging_after'::jsonb#>'{data,items}') i),
 'aging total is the stock left, 110, and a line keeps its per-bag weight 12: '||left(:'aging_after',400));
SELECT pg_temp.bl_assert((jsonb_path_query_first(:'details_after'::jsonb,'$.**.statistics.total_weight'))::text::numeric=140,
 'the receipt total stays the received 140 after a dispatch');

-- ---- 1b. The same rule in the dispatch writers (BL80D, 3 bags of the 12 kg line, stands; 7 + 4 bags are left)
SELECT id AS disp_id FROM public.dispatch WHERE disp_no='BL80D' \gset
SELECT jsonb_build_object('disp_no','BL80E','disp_date',now(),'customer_id',:'customer_one','customer_name','Backlog Business One',
  'supervisor_id',:'sync_id','supervisor_name','Backlog Sync Connection') AS data_sa \gset
SELECT jsonb_build_object('disp_no','BL80F','disp_date',now(),'customer_id',:'customer_one','customer_name','Backlog Business One',
  'supervisor_id',:'person_id','supervisor_name','Backlog Person Supervisor') AS data_person \gset
SELECT jsonb_build_object('disp_no','BL80G','disp_date',now(),'customer_id',:'customer_one','customer_name','Backlog Business One',
  'supervisor_id',:'sync_id','supervisor_name','Backlog Sync Connection') AS data_self \gset
SELECT jsonb_build_object('disp_no','BL80H','disp_date',now(),'customer_id',:'customer_one','customer_name','Backlog Business One',
  'supervisor_id',:'other_sync_id','supervisor_name','Backlog Other Connection') AS data_other \gset
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.bl_call(format('SELECT public.create_dispatch_with_stock_check(%L::jsonb,ARRAY[jsonb_build_object(%L,%L,%L,1)],false,0,%L)',
  :'data_sa','gr_trl_id',:'lot_small','disp_qty','bl80-d-sa')) AS disp_sa \gset
SELECT pg_temp.bl_call(format('SELECT public.create_dispatch_with_stock_check(%L::jsonb,ARRAY[jsonb_build_object(%L,%L,%L,1)],0,%L)',
  :'data_sa','gr_trl_id',:'lot_small','disp_qty','bl80-d-sa3')) AS disp_sa3 \gset
SELECT public.create_dispatch_with_stock_check(:'data_person'::jsonb,ARRAY[jsonb_build_object('gr_trl_id',:'lot_small','disp_qty',1)],false,0,'bl80-d-person') AS disp_person \gset
RESET ROLE;
SELECT pg_temp.bl_assert(:'disp_sa'::jsonb->>'raised'='Supervisor must be a person, not a service account' AND :'disp_sa'::jsonb->>'state'='P0001'
 AND :'disp_sa3'::jsonb->>'raised'='Supervisor must be a person, not a service account'
 AND NOT EXISTS (SELECT 1 FROM public.dispatch WHERE disp_no='BL80E'),'create_dispatch: a person naming a service account is refused (both overloads): '||:'disp_sa'||:'disp_sa3');
SELECT pg_temp.bl_assert(:'disp_person'::jsonb->>'success'='true','create_dispatch: a person naming a person is accepted: '||:'disp_person');
SELECT set_config('request.jwt.claims',:'sync_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.create_dispatch_with_stock_check(:'data_self'::jsonb,ARRAY[jsonb_build_object('gr_trl_id',:'lot_small','disp_qty',1)],false,0,'bl80-d-self') AS disp_self \gset
SELECT pg_temp.bl_call(format('SELECT public.create_dispatch_with_stock_check(%L::jsonb,ARRAY[jsonb_build_object(%L,%L,%L,1)],false,0,%L)',
  :'data_other','gr_trl_id',:'lot_small','disp_qty','bl80-d-other')) AS disp_other \gset
RESET ROLE;
SELECT pg_temp.bl_assert(:'disp_self'::jsonb->>'success'='true' AND (SELECT supervisor_id=:'sync_id'::uuid FROM public.dispatch WHERE disp_no='BL80G'),
 'create_dispatch: a service account naming itself is accepted: '||:'disp_self');
SELECT pg_temp.bl_assert(:'disp_other'::jsonb->>'raised'='Supervisor must be a person, not a service account' AND NOT EXISTS (SELECT 1 FROM public.dispatch WHERE disp_no='BL80H'),
 'create_dispatch: a service account naming another service account is refused: '||:'disp_other');
-- update_dispatch_smart: the same lines of BL80D are sent each time.
SELECT jsonb_build_array(jsonb_build_object('gr_trl_id',:'lot_big','disp_qty',3)) AS d_lines \gset
-- The supervisor BL80D has now, read before each refused call: "unchanged" means equal to this, not to a guess.
SELECT COALESCE(supervisor_id::text,'') AS sup_before_sa FROM public.dispatch WHERE id=:'disp_id'::uuid \gset
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.bl_call(format('SELECT public.update_dispatch_smart(%L::uuid,%L::jsonb,ARRAY(SELECT jsonb_array_elements(%L::jsonb)))',
  :'disp_id',jsonb_build_object('supervisor_id',:'sync_id')::text,:'d_lines')) AS upd_sa \gset
-- Read straight after the refused call: the next call (upd_person) changes the supervisor on purpose.
SELECT COALESCE(supervisor_id::text,'') AS sup_after_sa FROM public.dispatch WHERE id=:'disp_id'::uuid \gset
SELECT pg_temp.bl_call(format('SELECT public.update_dispatch_smart(%L::uuid,%L::jsonb,ARRAY(SELECT jsonb_array_elements(%L::jsonb)))',
  :'disp_id',jsonb_build_object('supervisor_id',:'person_id','supervisor_name','Backlog Person Supervisor')::text,:'d_lines')) AS upd_person \gset
RESET ROLE;
-- update_dispatch_smart catches every exception and answers {success:false, error:<message>} (its own convention).
SELECT pg_temp.bl_assert(:'upd_sa'::jsonb->>'success'='false' AND :'upd_sa'::jsonb->>'error'='Supervisor must be a person, not a service account'
 AND :'sup_after_sa'=:'sup_before_sa' AND :'sup_before_sa'<>'',
 'update_dispatch_smart: a person naming a service account is refused, supervisor kept ('||:'sup_before_sa'||' -> '||:'sup_after_sa'||'): '||:'upd_sa');
SELECT pg_temp.bl_assert(:'upd_person'::jsonb->>'success'='true' AND (SELECT supervisor_id=:'person_id'::uuid FROM public.dispatch WHERE id=:'disp_id'::uuid),
 'update_dispatch_smart: a person naming a person is accepted: '||:'upd_person');
SELECT set_config('request.jwt.claims',:'sync_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.bl_call(format('SELECT public.update_dispatch_smart(%L::uuid,%L::jsonb,ARRAY(SELECT jsonb_array_elements(%L::jsonb)))',
  :'disp_id',jsonb_build_object('supervisor_id',:'sync_id')::text,:'d_lines')) AS upd_self \gset
SELECT COALESCE(supervisor_id::text,'') AS sup_before_other FROM public.dispatch WHERE id=:'disp_id'::uuid \gset
SELECT pg_temp.bl_call(format('SELECT public.update_dispatch_smart(%L::uuid,%L::jsonb,ARRAY(SELECT jsonb_array_elements(%L::jsonb)))',
  :'disp_id',jsonb_build_object('supervisor_id',:'other_sync_id')::text,:'d_lines')) AS upd_other \gset
RESET ROLE;
SELECT pg_temp.bl_assert(:'upd_self'::jsonb->>'success'='true' AND (SELECT supervisor_id=:'sync_id'::uuid FROM public.dispatch WHERE id=:'disp_id'::uuid),
 'update_dispatch_smart: a service account naming itself is accepted: '||:'upd_self');
SELECT pg_temp.bl_assert(:'upd_other'::jsonb->>'success'='false' AND :'upd_other'::jsonb->>'error'='Supervisor must be a person, not a service account'
 AND (SELECT COALESCE(supervisor_id::text,'')=:'sup_before_other' FROM public.dispatch WHERE id=:'disp_id'::uuid),
 'update_dispatch_smart: another service account is refused, supervisor kept ('||:'sup_before_other'||'): '||:'upd_other');
-- A dispatch that already has a service account as supervisor keeps it through an edit by anyone.
UPDATE public.dispatch SET supervisor_id=:'other_sync_id'::uuid WHERE id=:'disp_id'::uuid;
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.bl_call(format('SELECT public.update_dispatch_smart(%L::uuid,%L::jsonb,ARRAY(SELECT jsonb_array_elements(%L::jsonb)))',
  :'disp_id',jsonb_build_object('supervisor_id',:'other_sync_id')::text,:'d_lines')) AS upd_same \gset
RESET ROLE;
SELECT pg_temp.bl_assert(:'upd_same'::jsonb->>'success'='true' AND (SELECT supervisor_id=:'other_sync_id'::uuid FROM public.dispatch WHERE id=:'disp_id'::uuid),
 'update_dispatch_smart: the unchanged supervisor is kept: '||:'upd_same');

-- ---- 2. An inactive or deleted business: no new order, no customer; staff may open the existing OPEN one
-- customer_two has an OPEN order (made while active), customer_four a DISPATCHED one, customer_one and
-- customer_three none. Callers: customer (owns all four), administrator, supervisor, staff.
SELECT set_config('request.jwt.claims',:'active_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.bl_call(format('SELECT to_jsonb(public.get_or_create_cart(%L::uuid))',:'customer_two')) AS cart_ok \gset
SELECT pg_temp.bl_call(format('SELECT to_jsonb(public.get_or_create_cart(%L::uuid))',:'customer_four')) AS cart_four \gset
RESET ROLE;
SELECT pg_temp.bl_assert(NOT (:'cart_ok'::jsonb ? 'raised') AND NOT (:'cart_four'::jsonb ? 'raised')
 AND (SELECT count(*)=1 FROM public.orders WHERE customer_id=:'customer_two'::uuid),'an active business gets its order: '||:'cart_ok');
UPDATE public.orders SET status='DISPATCHED' WHERE customer_id=:'customer_four'::uuid;
UPDATE public.customers SET active=false WHERE id IN (:'customer_one'::uuid,:'customer_two'::uuid,:'customer_four'::uuid);
UPDATE public.customers SET deleted_at=now() WHERE id=:'customer_three'::uuid;
-- the customer: refused everywhere, also for the existing open order
SELECT set_config('request.jwt.claims',:'active_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.bl_call(format('SELECT to_jsonb(public.get_or_create_cart(%L::uuid))',:'customer_one')) AS c_new_inactive \gset
SELECT pg_temp.bl_call(format('SELECT to_jsonb(public.get_or_create_cart(%L::uuid))',:'customer_three')) AS c_new_deleted \gset
SELECT pg_temp.bl_call(format('SELECT to_jsonb(public.get_or_create_cart(%L::uuid))',:'customer_two')) AS c_existing \gset
RESET ROLE;
SELECT pg_temp.bl_assert(:'c_new_inactive'::jsonb->>'raised'='Business is not active' AND :'c_new_inactive'::jsonb->>'state'='P0001'
 AND :'c_new_deleted'::jsonb->>'raised'='Business is not active' AND :'c_existing'::jsonb->>'raised'='Business is not active',
 'customer: refused for new (inactive, deleted) and for the existing open order: '||:'c_new_inactive'||:'c_new_deleted'||:'c_existing');
-- administrator, supervisor and staff: the existing open order is returned, nothing new is made, a DISPATCHED one is not reset
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.bl_call(format('SELECT to_jsonb(public.get_or_create_cart(%L::uuid))',:'customer_two')) AS a_existing,
       pg_temp.bl_call(format('SELECT to_jsonb(public.get_or_create_cart(%L::uuid))',:'customer_one')) AS a_new,
       pg_temp.bl_call(format('SELECT to_jsonb(public.get_or_create_cart(%L::uuid))',:'customer_three')) AS a_deleted,
       pg_temp.bl_call(format('SELECT to_jsonb(public.get_or_create_cart(%L::uuid))',:'customer_four')) AS a_dispatched \gset
RESET ROLE;
SELECT set_config('request.jwt.claims',:'supervisor_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.bl_call(format('SELECT to_jsonb(public.get_or_create_cart(%L::uuid))',:'customer_two')) AS s_existing,
       pg_temp.bl_call(format('SELECT to_jsonb(public.get_or_create_cart(%L::uuid))',:'customer_one')) AS s_new \gset
RESET ROLE;
SELECT set_config('request.jwt.claims',:'staff_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.bl_call(format('SELECT to_jsonb(public.get_or_create_cart(%L::uuid))',:'customer_two')) AS t_existing,
       pg_temp.bl_call(format('SELECT to_jsonb(public.get_or_create_cart(%L::uuid))',:'customer_one')) AS t_new,
       pg_temp.bl_call(format('SELECT to_jsonb(public.get_or_create_cart(%L::uuid))',:'customer_four')) AS t_dispatched \gset
RESET ROLE;
SELECT id AS cart_two FROM public.orders WHERE customer_id=:'customer_two'::uuid \gset
SELECT pg_temp.bl_assert(:'a_existing'::jsonb=to_jsonb(:'cart_two'::uuid) AND :'s_existing'::jsonb=to_jsonb(:'cart_two'::uuid) AND :'t_existing'::jsonb=to_jsonb(:'cart_two'::uuid),
 'administrator, supervisor and staff get the existing open order: '||:'a_existing'||:'s_existing'||:'t_existing');
SELECT pg_temp.bl_assert(:'a_new'::jsonb->>'raised'='Business is not active' AND :'s_new'::jsonb->>'raised'='Business is not active'
 AND :'t_new'::jsonb->>'raised'='Business is not active' AND :'a_deleted'::jsonb->>'raised'='Business is not active'
 AND NOT EXISTS (SELECT 1 FROM public.orders WHERE customer_id IN (:'customer_one'::uuid,:'customer_three'::uuid)),
 'nobody creates an order for an inactive or deleted business: '||:'a_new'||:'s_new'||:'t_new'||:'a_deleted');
SELECT pg_temp.bl_assert(:'a_dispatched'::jsonb->>'raised'='Business is not active' AND :'t_dispatched'::jsonb->>'raised'='Business is not active'
 AND (SELECT status='DISPATCHED' FROM public.orders WHERE customer_id=:'customer_four'::uuid),
 'a DISPATCHED order of an inactive business is not reset to OPEN: '||:'a_dispatched'||:'t_dispatched');
ROLLBACK;
