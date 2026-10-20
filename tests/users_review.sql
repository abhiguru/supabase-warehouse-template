-- Users screens review (migration 113): access-request tags and the status guard, review again, role change
-- removing customer assignments, assigned-customer active/sort, deleted accounts, FAS Disconnect for
-- administrators only, stable error codes of the customer assignment RPCs.
-- Fictional data; runs only in migrations.sh's disposable, network-disabled database.
\set ON_ERROR_STOP on
BEGIN;
CREATE FUNCTION pg_temp.ur_assert(ok boolean, label text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF NOT COALESCE(ok,false) THEN RAISE EXCEPTION 'users review: %',label; END IF; END $$;
CREATE FUNCTION pg_temp.ur_call(statement text) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE answer jsonb;
BEGIN
  BEGIN EXECUTE statement INTO answer;
  EXCEPTION WHEN OTHERS THEN RETURN jsonb_build_object('raised', SQLERRM, 'state', SQLSTATE); END;
  RETURN answer;
END $$;
CREATE FUNCTION pg_temp.ur_login(phone text) RETURNS jsonb LANGUAGE plpgsql AS $$
 DECLARE c jsonb; l jsonb; claims jsonb;
 BEGIN
  c:=public.operator_prepare_otp(phone);
  PERFORM pg_temp.ur_assert(c->>'success'='true','challenge prepared for '||phone);
  PERFORM public.operator_finish_otp((c#>>'{data,request_id}')::uuid,true,'mock-provider-only');
  l:=public.operator_verify_otp(phone,c#>>'{data,otp_code}');
  PERFORM pg_temp.ur_assert(l#>>'{data,action}'='login','login for '||phone||': '||l::text);
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
SELECT warehouse_security.bootstrap_first_admin('9444444401','Review Admin') AS admin_user \gset
INSERT INTO public.user_profiles(auth_user_id,mobile,name,role,active,enrollment_status) VALUES
 (gen_random_uuid(),'919444444402','Review Supervisor','supervisor',true,'approved'),
 (gen_random_uuid(),'919444444403','Review Customer','customer',true,'approved'),
 (gen_random_uuid(),'919444444404','Review Pending','customer',false,'pending'),
 (gen_random_uuid(),'919444444405','Review Rejected','customer',false,'rejected'),
 (gen_random_uuid(),'919444444406','Review Sync','staff',true,'approved'),
 (gen_random_uuid(),'919444444407','Review Leaver','staff',true,'approved'),
 (gen_random_uuid(),'919444444408','Review Second Admin','admin',true,'approved');
INSERT INTO public.customers(name,mobile,active) VALUES ('Zeta Trading','9444444411',true) RETURNING id AS cust_z \gset
INSERT INTO public.customers(name,mobile,active) VALUES ('Alpha Trading','9444444412',true) RETURNING id AS cust_a \gset
INSERT INTO public.customers(name,mobile,active) VALUES ('Middle Trading','9444444413',false) RETURNING id AS cust_off \gset
SELECT id AS admin_id FROM public.user_profiles WHERE auth_user_id=:'admin_user'::uuid \gset
SELECT id AS customer_id FROM public.user_profiles WHERE mobile='919444444403' \gset
SELECT id AS pending_id FROM public.user_profiles WHERE mobile='919444444404' \gset
SELECT id AS rejected_id FROM public.user_profiles WHERE mobile='919444444405' \gset
SELECT id AS sync_id FROM public.user_profiles WHERE mobile='919444444406' \gset
SELECT id AS leaver_id FROM public.user_profiles WHERE mobile='919444444407' \gset
SELECT pg_temp.ur_login('9444444401') AS admin_claims \gset
SELECT pg_temp.ur_login('9444444402') AS supervisor_claims \gset
SELECT pg_temp.ur_login('9444444403') AS customer_claims \gset
SELECT pg_temp.ur_login('9444444407') AS leaver_claims \gset
INSERT INTO public.users_customers_new(user_profile_id,customer_id,customer_name,assigned_by,active) VALUES
 (:'customer_id'::uuid,:'cust_z'::uuid,'Zeta Trading',:'admin_id'::uuid,true),
 (:'customer_id'::uuid,:'cust_off'::uuid,'Middle Trading',:'admin_id'::uuid,true),
 (:'customer_id'::uuid,:'cust_a'::uuid,'Alpha Trading',:'admin_id'::uuid,true);
-- Distinct assignment times, Alpha the oldest and Zeta the newest, so a sort by time cannot give the name order.
UPDATE public.users_customers_new SET assigned_at = now() - interval '3 days' WHERE user_profile_id=:'customer_id'::uuid AND customer_id=:'cust_a'::uuid;
UPDATE public.users_customers_new SET assigned_at = now() - interval '2 days' WHERE user_profile_id=:'customer_id'::uuid AND customer_id=:'cust_off'::uuid;
UPDATE public.users_customers_new SET assigned_at = now() - interval '1 day' WHERE user_profile_id=:'customer_id'::uuid AND customer_id=:'cust_z'::uuid;

-- Tags, deleted flag and the sorted assignments with their active state.
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.get_users_list('Review',NULL,NULL,100,0) AS list1, public.get_user_details(:'customer_id'::uuid) AS det_customer,
       public.get_user_details(:'pending_id'::uuid) AS det_pending, public.get_user_details(:'rejected_id'::uuid) AS det_rejected \gset
RESET ROLE;
SELECT pg_temp.ur_assert((SELECT u->>'enrollment_status'='pending' FROM jsonb_array_elements(:'list1'::jsonb->'users') u WHERE u->>'id'=:'pending_id')
 AND (SELECT u->>'enrollment_status'='rejected' FROM jsonb_array_elements(:'list1'::jsonb->'users') u WHERE u->>'id'=:'rejected_id')
 AND (SELECT u->'enrollment_status'='null'::jsonb FROM jsonb_array_elements(:'list1'::jsonb->'users') u WHERE u->>'id'=:'customer_id')
 AND (SELECT bool_and(u->'is_deleted'='false'::jsonb) FROM jsonb_array_elements(:'list1'::jsonb->'users') u),'list tags: '||:'list1');
SELECT pg_temp.ur_assert(:'det_pending'::jsonb#>>'{user,enrollment_status}'='pending' AND :'det_rejected'::jsonb#>>'{user,enrollment_status}'='rejected'
 AND :'det_customer'::jsonb#>'{user,enrollment_status}'='null'::jsonb,'details tags');
SELECT pg_temp.ur_assert((SELECT array_agg(a->>'customer_name' ORDER BY ord) = ARRAY['Alpha Trading','Middle Trading','Zeta Trading']
   AND (SELECT a2->'customer_active' FROM jsonb_array_elements(:'det_customer'::jsonb->'assigned_customers') a2 WHERE a2->>'customer_name'='Middle Trading')='false'::jsonb
   AND (SELECT a2->'customer_active' FROM jsonb_array_elements(:'det_customer'::jsonb->'assigned_customers') a2 WHERE a2->>'customer_name'='Alpha Trading')='true'::jsonb
   FROM jsonb_array_elements(:'det_customer'::jsonb->'assigned_customers') WITH ORDINALITY t(a,ord)),'assignments sorted by name with customer_active: '||:'det_customer');

-- The Active switch does not approve an access request.
SET LOCAL ROLE authenticated;
SELECT public.update_user_status(:'pending_id'::uuid,true) AS st_pending, public.update_user_status(:'rejected_id'::uuid,true) AS st_rejected \gset
RESET ROLE;
SELECT pg_temp.ur_assert(:'st_pending'::jsonb->>'error_code'='ENROLLMENT_PENDING' AND :'st_pending'::jsonb->>'success'='false'
 AND :'st_rejected'::jsonb->>'error_code'='ENROLLMENT_REJECTED' AND :'st_rejected'::jsonb->>'success'='false'
 AND (SELECT NOT active AND enrollment_status='pending' FROM public.user_profiles WHERE id=:'pending_id'::uuid)
 AND (SELECT NOT active AND enrollment_status='rejected' FROM public.user_profiles WHERE id=:'rejected_id'::uuid),'pending and rejected are refused and unchanged: '||:'st_pending'||:'st_rejected');

-- Review again: administrators only, idempotent.
SET LOCAL ROLE authenticated;
SELECT public.review_enrollment_again(:'rejected_id'::uuid) AS again1, public.review_enrollment_again(:'rejected_id'::uuid) AS again2,
       public.review_enrollment_again(:'customer_id'::uuid) AS again_ok_user, public.review_enrollment_again(gen_random_uuid()) AS again_unknown,
       public.review_enrollment_again(NULL) AS again_null \gset
RESET ROLE;
SELECT pg_temp.ur_assert(:'again1'::jsonb->>'success'='true' AND :'again1'::jsonb->>'changed'='true'
 AND :'again2'::jsonb->>'success'='true' AND :'again2'::jsonb->>'changed'='false'
 AND :'again_ok_user'::jsonb->>'error_code'='NOT_REJECTED' AND :'again_unknown'::jsonb->>'error_code'='NOT_FOUND'
 AND :'again_null'::jsonb->>'error_code'='INVALID_INPUT'
 AND (SELECT NOT active AND enrollment_status='pending' AND role='customer' FROM public.user_profiles WHERE id=:'rejected_id'::uuid),'review again and repeat: '||:'again1'||:'again2'||:'again_ok_user');
-- A rejected person's role cannot be changed; one changed before this migration returns as a Customer.
UPDATE public.user_profiles SET enrollment_status='rejected', role='staff' WHERE id=:'rejected_id'::uuid;
SET LOCAL ROLE authenticated;
SELECT public.update_user_role(:'rejected_id'::uuid,'supervisor') AS role_rejected, public.review_enrollment_again(:'rejected_id'::uuid) AS again_staff \gset
RESET ROLE;
SELECT pg_temp.ur_assert(:'role_rejected'::jsonb->>'error_code'='ENROLLMENT_REJECTED' AND :'role_rejected'::jsonb->>'success'='false'
 AND :'again_staff'::jsonb->>'changed'='true'
 AND (SELECT role='customer' AND enrollment_status='pending' FROM public.user_profiles WHERE id=:'rejected_id'::uuid),'rejected role change refused, review again restores Customer: '||:'role_rejected'||:'again_staff');
UPDATE public.user_profiles SET enrollment_status='rejected' WHERE id=:'rejected_id'::uuid;
SELECT set_config('request.jwt.claims',:'supervisor_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.review_enrollment_again(:'rejected_id'::uuid) AS again_sup \gset
RESET ROLE;
SELECT set_config('request.jwt.claims',:'customer_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.ur_call(format('SELECT public.review_enrollment_again(%L)',:'rejected_id')) AS again_customer \gset
RESET ROLE;
SELECT pg_temp.ur_assert(:'again_sup'::jsonb->>'error_code'='PERMISSION_DENIED' AND :'again_customer'::jsonb->>'state'='42501'
 AND (SELECT enrollment_status='rejected' FROM public.user_profiles WHERE id=:'rejected_id'::uuid),'supervisor and customer refused: '||:'again_sup'||:'again_customer');

-- Role change away from Customer removes the assignments and counts them.
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.update_user_role(:'customer_id'::uuid,'staff') AS role_staff, public.update_user_role(:'customer_id'::uuid,'staff') AS role_again \gset
RESET ROLE;
SELECT pg_temp.ur_assert(:'role_staff'::jsonb->>'success'='true' AND (:'role_staff'::jsonb->>'removed_customer_count')::int=3
 AND (:'role_again'::jsonb->>'removed_customer_count')::int=0
 AND NOT EXISTS (SELECT 1 FROM public.users_customers_new WHERE user_profile_id=:'customer_id'::uuid AND active),'role change removed 3 assignments: '||:'role_staff'||:'role_again');

-- A supervisor cannot change an administrator's role: error stays PERMISSION_DENIED, error_code is CANNOT_MODIFY_ADMIN.
SELECT set_config('request.jwt.claims',:'supervisor_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.update_user_role(:'admin_id'::uuid,'staff') AS sup_role_admin \gset
RESET ROLE;
SELECT pg_temp.ur_assert(:'sup_role_admin'::jsonb->>'error_code'='CANNOT_MODIFY_ADMIN' AND :'sup_role_admin'::jsonb->>'error'='PERMISSION_DENIED'
 AND (SELECT role='admin' FROM public.user_profiles WHERE id=:'admin_id'::uuid),'supervisor cannot change an administrator: '||:'sup_role_admin');
SELECT set_config('request.jwt.claims',:'admin_claims',true);

-- FAS Disconnect: administrator only.
UPDATE public.user_profiles SET is_service_account=true WHERE id=:'sync_id'::uuid;
SELECT set_config('request.jwt.claims',:'supervisor_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.update_user_status(:'sync_id'::uuid,false) AS sup_cut \gset
RESET ROLE;
SELECT pg_temp.ur_assert(:'sup_cut'::jsonb->>'error_code'='PERMISSION_DENIED' AND (SELECT active FROM public.user_profiles WHERE id=:'sync_id'::uuid),'supervisor cannot disconnect: '||:'sup_cut');
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.update_user_status(:'sync_id'::uuid,false) AS admin_cut \gset
RESET ROLE;
SELECT pg_temp.ur_assert(:'admin_cut'::jsonb->>'success'='true' AND (SELECT NOT active FROM public.user_profiles WHERE id=:'sync_id'::uuid),'administrator disconnects');

-- Deleted account: marked, no phone, outside total_count, no changes, retry succeeds.
SELECT set_config('request.jwt.claims',:'leaver_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.delete_user_account() AS del1 \gset
SELECT public.delete_user_account() AS del2 \gset
RESET ROLE;
SELECT pg_temp.ur_assert(:'del1'::jsonb->>'success'='true' AND :'del2'::jsonb->>'success'='true'
 AND (SELECT deleted_at IS NOT NULL AND NOT active AND mobile LIKE 'DEL%' FROM public.user_profiles WHERE id=:'leaver_id'::uuid),'delete and retry: '||:'del1'||:'del2');
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.get_users_list('Deleted',NULL,NULL,100,0) AS list_del, public.get_users_list('Review',NULL,NULL,100,0) AS list_live,
       public.get_user_details(:'leaver_id'::uuid) AS det_del,
       public.update_user_status(:'leaver_id'::uuid,true) AS st_del, public.update_user_role(:'leaver_id'::uuid,'customer') AS role_del,
       public.review_enrollment_again(:'leaver_id'::uuid) AS again_del \gset
RESET ROLE;
SELECT pg_temp.ur_assert((:'list_del'::jsonb#>>'{pagination,total_count}')::int=0 AND (:'list_del'::jsonb#>>'{pagination,total_with_deleted}')::int>=1
 AND (SELECT bool_and(u->'is_deleted'='true'::jsonb AND u->'mobile'='null'::jsonb) AND count(*)>=1 FROM jsonb_array_elements(:'list_del'::jsonb->'users') u),'deleted rows: no phone, not counted: '||:'list_del');
SELECT pg_temp.ur_assert((:'list_live'::jsonb#>>'{pagination,total_count}')::int = (SELECT count(*) FROM public.user_profiles WHERE name ILIKE '%Review%' AND deleted_at IS NULL)
 AND (SELECT bool_and(u->'is_deleted'='false'::jsonb) FROM jsonb_array_elements(:'list_live'::jsonb->'users') u),'live total_count');
SELECT pg_temp.ur_assert(:'det_del'::jsonb#>'{user,is_deleted}'='true'::jsonb AND :'det_del'::jsonb#>'{user,mobile}'='null'::jsonb
 AND :'st_del'::jsonb->>'error_code'='ACCOUNT_DELETED' AND :'role_del'::jsonb->>'error_code'='ACCOUNT_DELETED' AND :'again_del'::jsonb->>'error_code'='ACCOUNT_DELETED','changes on a deleted account refused');

-- A list mixing live and deleted rows: live first, total_with_deleted counts both, has_more follows it,
-- and a phone search ignores the deleted rows (they have no phone).
INSERT INTO public.user_profiles(auth_user_id,mobile,name,role,active,enrollment_status,deleted_at) VALUES
 (gen_random_uuid(),'DEL0123456789ab','Deleted User','staff',false,'disabled',now());
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.get_users_list('',NULL,NULL,100,0) AS mix_all, public.get_users_list('',NULL,NULL,1,0) AS mix_p1,
       public.get_users_list('DEL0123456789ab',NULL,NULL,100,0) AS mix_phone \gset
RESET ROLE;
SELECT pg_temp.ur_assert((:'mix_all'::jsonb#>>'{pagination,total_with_deleted}')::int = (SELECT count(*) FROM public.user_profiles)
 AND (:'mix_all'::jsonb#>>'{pagination,total_count}')::int = (SELECT count(*) FROM public.user_profiles WHERE deleted_at IS NULL)
 AND (SELECT bool_and(u->'is_deleted'='false'::jsonb) FROM (SELECT u FROM jsonb_array_elements(:'mix_all'::jsonb->'users') WITH ORDINALITY t(u,o)
       WHERE o <= (:'mix_all'::jsonb#>>'{pagination,total_count}')::int) x)
 AND (SELECT bool_and(u->'is_deleted'='true'::jsonb) FROM (SELECT u FROM jsonb_array_elements(:'mix_all'::jsonb->'users') WITH ORDINALITY t(u,o)
       WHERE o > (:'mix_all'::jsonb#>>'{pagination,total_count}')::int) x),'mixed list: live first, then deleted: '||:'mix_all');
SELECT pg_temp.ur_assert((:'mix_p1'::jsonb#>>'{pagination,has_more}')::boolean AND jsonb_array_length(:'mix_p1'::jsonb->'users')=1,'has_more with limit 1: '||:'mix_p1');
SELECT pg_temp.ur_assert(jsonb_array_length(:'mix_phone'::jsonb->'users')=0,'phone search ignores deleted rows: '||:'mix_phone');
-- The migration's backfill cannot be re-run here (it ran before the fixtures exist); its WHERE is checked on a seeded row,
-- including a deleted account that was switched back on.
INSERT INTO public.user_profiles(auth_user_id,mobile,name,role,active,enrollment_status) VALUES
 (gen_random_uuid(),'DEL00000000beef','Deleted User','staff',true,'approved'),
 (gen_random_uuid(),'DEL00000000zzzz','Deleted User','staff',true,'approved');
SELECT pg_temp.ur_assert((SELECT count(*) FROM public.user_profiles WHERE deleted_at IS NULL AND mobile ~ '^DEL[0-9a-f]{12}$' AND name = 'Deleted User')=1,'backfill WHERE matches only the DEL+12 hex row, active or not');
DELETE FROM public.user_profiles WHERE mobile IN ('DEL00000000beef','DEL00000000zzzz','DEL0123456789ab');

-- A deleted administrator is not another administrator.
SELECT pg_temp.ur_assert(warehouse_security.other_active_admin_exists(:'admin_id'::uuid),'second administrator counts');
UPDATE public.user_profiles SET deleted_at=now() WHERE mobile='919444444408';
SELECT pg_temp.ur_assert(NOT warehouse_security.other_active_admin_exists(:'admin_id'::uuid),'a deleted administrator does not count');
UPDATE public.user_profiles SET deleted_at=NULL WHERE mobile='919444444408';

-- Customer assignment errors carry a code.
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.ur_call(format('SELECT public.assign_customer_to_user(%L,%L::uuid)','919444444406',:'cust_off')) AS as_off,
       pg_temp.ur_call(format('SELECT public.assign_customer_to_user(%L,%L::uuid)','919444444499',:'cust_a')) AS as_nouser,
       pg_temp.ur_call(format('SELECT public.assign_customer_to_user(%L,%L::uuid)','919444444403',gen_random_uuid())) AS as_nocust \gset
RESET ROLE;
UPDATE public.user_profiles SET active=true,enrollment_status='approved' WHERE id=:'sync_id'::uuid;
UPDATE public.user_profiles SET is_service_account=false, role='customer' WHERE id=:'sync_id'::uuid; -- assignments apply only to the Customer role
SET LOCAL ROLE authenticated;
SELECT pg_temp.ur_call(format('SELECT public.assign_customer_to_user(%L,%L::uuid)','919444444406',:'cust_off')) AS as_off2 \gset
RESET ROLE;
SELECT pg_temp.ur_assert(:'as_off2'::jsonb->>'raised' LIKE 'CUSTOMER_INACTIVE:%' AND :'as_nouser'::jsonb->>'raised' LIKE 'NOT_FOUND:%'
 AND :'as_nocust'::jsonb->>'raised' LIKE 'NOT_FOUND:%','assignment codes: '||:'as_off2'||:'as_nouser'||:'as_nocust');
ROLLBACK;
\echo 'Users review checks passed.'
