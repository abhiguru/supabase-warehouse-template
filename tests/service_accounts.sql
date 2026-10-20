-- Migration 78 (2026-10-14): service accounts. user_profiles.is_service_account; the user list
-- and details return it; role, status and deletion of such a profile are refused with
-- SERVICE_ACCOUNT_READ_ONLY; it does not count for the last-administrator rule;
-- set_service_account is an administrator's call.
-- Fictional data; runs only in migrations.sh's disposable, network-disabled database.
\set ON_ERROR_STOP on
BEGIN;
CREATE FUNCTION pg_temp.sa_assert(ok boolean, label text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF NOT COALESCE(ok,false) THEN RAISE EXCEPTION 'service accounts: %',label; END IF; END $$;
CREATE FUNCTION pg_temp.sa_call(statement text) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE answer jsonb;
BEGIN
  BEGIN EXECUTE statement INTO answer;
  EXCEPTION WHEN OTHERS THEN RETURN jsonb_build_object('raised', SQLERRM, 'state', SQLSTATE); END;
  RETURN answer;
END $$;
CREATE FUNCTION pg_temp.sa_login(phone text) RETURNS jsonb LANGUAGE plpgsql AS $$
 DECLARE c jsonb; l jsonb; claims jsonb;
 BEGIN
  c:=public.operator_prepare_otp(phone);
  PERFORM pg_temp.sa_assert(c->>'success'='true','challenge prepared for '||phone);
  PERFORM public.operator_finish_otp((c#>>'{data,request_id}')::uuid,true,'mock-provider-only');
  l:=public.operator_verify_otp(phone,c#>>'{data,otp_code}');
  PERFORM pg_temp.sa_assert(l#>>'{data,action}'='login','login for '||phone||': '||l::text);
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
SELECT warehouse_security.bootstrap_first_admin('9555555501','Service Test Admin') AS admin_user \gset
INSERT INTO public.user_profiles(auth_user_id,mobile,name,role,active,enrollment_status) VALUES
 (gen_random_uuid(),'919555555502','Service Test Supervisor','supervisor',true,'approved'),
 (gen_random_uuid(),'919555555503','Service Test Staff','staff',true,'approved'),
 (gen_random_uuid(),'919555555504','Service Test Customer','customer',true,'approved'),
 (gen_random_uuid(),'919555555505','Service Test Sync','staff',true,'approved'),
 (gen_random_uuid(),'919555555506','Service Test Second Admin','admin',true,'approved'),
 (gen_random_uuid(),'919555555507','Service Test Person','staff',true,'approved');
SELECT id AS admin_id FROM public.user_profiles WHERE auth_user_id=:'admin_user'::uuid \gset
SELECT id AS sync_id FROM public.user_profiles WHERE mobile='919555555505' \gset
SELECT id AS admin2_id FROM public.user_profiles WHERE mobile='919555555506' \gset
SELECT id AS person_id FROM public.user_profiles WHERE mobile='919555555507' \gset
SELECT pg_temp.sa_login('9555555501') AS admin_claims \gset
SELECT pg_temp.sa_login('9555555502') AS supervisor_claims \gset
SELECT pg_temp.sa_login('9555555503') AS staff_claims \gset
SELECT pg_temp.sa_login('9555555504') AS customer_claims \gset
SELECT pg_temp.sa_login('9555555505') AS sync_claims \gset
SELECT pg_temp.sa_login('9555555506') AS admin2_claims \gset

-- The column and the function.
SELECT pg_temp.sa_assert((SELECT is_nullable='NO' AND column_default='false' AND data_type='boolean' FROM information_schema.columns
   WHERE table_schema='public' AND table_name='user_profiles' AND column_name='is_service_account')
 AND (SELECT count(*)=0 FROM public.user_profiles WHERE is_service_account),'the column is boolean NOT NULL DEFAULT false and nothing is marked by the migration');
SELECT pg_temp.sa_assert(has_function_privilege('authenticated','public.set_service_account(uuid,boolean)','EXECUTE')
 AND has_function_privilege('service_role','public.set_service_account(uuid,boolean)','EXECUTE')
 AND NOT has_function_privilege('anon','public.set_service_account(uuid,boolean)','EXECUTE'),'grants of set_service_account');

-- Before marking: the user list shows false everywhere, and the sync profile can be changed.
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.get_users_list('Service Test',NULL,NULL,100,0) AS list_before, public.get_user_details(:'sync_id'::uuid) AS details_before \gset
RESET ROLE;
SELECT pg_temp.sa_assert((SELECT bool_and(u->'is_service_account'='false'::jsonb) AND count(*)=7 FROM jsonb_array_elements(:'list_before'::jsonb->'users') u)
 AND :'details_before'::jsonb#>'{user,is_service_account}'='false'::jsonb,'list rows and details carry is_service_account=false before marking: '||:'list_before');

-- Only an administrator marks.
SELECT set_config('request.jwt.claims',:'supervisor_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.sa_call(format('SELECT public.set_service_account(%L,true)',:'sync_id')) AS by_supervisor \gset
RESET ROLE;
SELECT set_config('request.jwt.claims',:'staff_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.sa_call(format('SELECT public.set_service_account(%L,true)',:'sync_id')) AS by_staff \gset
RESET ROLE;
SELECT set_config('request.jwt.claims',:'customer_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.sa_call(format('SELECT public.set_service_account(%L,true)',:'sync_id')) AS by_customer \gset
RESET ROLE;
SELECT pg_temp.sa_assert(:'by_supervisor'::jsonb->>'state'='42501' AND :'by_staff'::jsonb->>'state'='42501' AND :'by_customer'::jsonb->>'state'='42501'
 AND NOT (SELECT is_service_account FROM public.user_profiles WHERE id=:'sync_id'::uuid),'a supervisor, staff and a customer are refused with 42501: '||:'by_supervisor'||:'by_staff'||:'by_customer');

-- The administrator marks the sync profile.
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.set_service_account(:'sync_id'::uuid,true) AS marked,
       public.set_service_account(:'sync_id'::uuid,true) AS marked_again,
       public.set_service_account(NULL,true) AS no_user,
       public.set_service_account(:'sync_id'::uuid,NULL) AS no_flag,
       public.set_service_account(gen_random_uuid(),true) AS unknown_user,
       public.set_service_account(:'admin_id'::uuid,true) AS myself \gset
RESET ROLE;
SELECT pg_temp.sa_assert(:'marked'::jsonb=jsonb_build_object('success',true,'user_id',:'sync_id'::uuid,'is_service_account',true,'message','Marked as a service account')
 AND (SELECT is_service_account FROM public.user_profiles WHERE id=:'sync_id'::uuid),'marked: '||:'marked');
SELECT pg_temp.sa_assert(:'marked_again'::jsonb->>'message'='Unchanged' AND :'no_user'::jsonb->>'error_code'='INVALID_INPUT' AND :'no_flag'::jsonb->>'error_code'='INVALID_INPUT'
 AND :'unknown_user'::jsonb->>'error_code'='NOT_FOUND' AND :'myself'::jsonb->>'error_code'='SELF_EDIT_FORBIDDEN'
 AND NOT (SELECT is_service_account FROM public.user_profiles WHERE id=:'admin_id'::uuid),'repeat, missing input, unknown user and yourself: '||:'marked_again'||:'no_user'||:'no_flag'||:'unknown_user'||:'myself');

-- List and details now show it; other rows stay false.
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.get_users_list('Service Test',NULL,NULL,100,0) AS list_after, public.get_user_details(:'sync_id'::uuid) AS details_after,
       public.get_user_details(:'person_id'::uuid) AS details_person \gset
RESET ROLE;
SELECT pg_temp.sa_assert((SELECT count(*) FILTER (WHERE (u->>'is_service_account')::boolean)=1 AND count(*)=7 AND bool_or(u->>'id'=:'sync_id' AND (u->>'is_service_account')::boolean)
    FROM jsonb_array_elements(:'list_after'::jsonb->'users') u)
 AND :'details_after'::jsonb#>'{user,is_service_account}'='true'::jsonb AND :'details_person'::jsonb#>'{user,is_service_account}'='false'::jsonb,
 'the list marks exactly the sync profile; details agree');

-- Role, status and deletion are refused for it; a person is still changeable.
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.update_user_role(:'sync_id'::uuid,'supervisor') AS role_try, public.update_user_status(:'sync_id'::uuid,true) AS status_try,
       public.update_user_role(:'person_id'::uuid,'supervisor') AS person_role, public.update_user_status(:'person_id'::uuid,false) AS person_status \gset
RESET ROLE;
SELECT set_config('request.jwt.claims',:'supervisor_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.update_user_role(:'sync_id'::uuid,'customer') AS sup_role_try, public.update_user_status(:'sync_id'::uuid,true) AS sup_status_try \gset
RESET ROLE;
SELECT set_config('request.jwt.claims',:'sync_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.delete_user_account() AS delete_try \gset
RESET ROLE;
SELECT pg_temp.sa_assert(:'role_try'::jsonb->>'error_code'='SERVICE_ACCOUNT_READ_ONLY' AND :'role_try'::jsonb->>'success'='false'
 AND :'status_try'::jsonb->>'error_code'='SERVICE_ACCOUNT_READ_ONLY' AND :'sup_role_try'::jsonb->>'error_code'='SERVICE_ACCOUNT_READ_ONLY'
 AND :'sup_status_try'::jsonb->>'error_code'='SERVICE_ACCOUNT_READ_ONLY' AND :'delete_try'::jsonb->>'error_code'='SERVICE_ACCOUNT_READ_ONLY'
 AND :'delete_try'::jsonb->>'success'='false','role, status (administrator and supervisor) and deletion refused: '||:'role_try'||:'status_try'||:'sup_role_try'||:'delete_try');
SELECT pg_temp.sa_assert((SELECT role='staff' AND active AND enrollment_status='approved' AND name='Service Test Sync' FROM public.user_profiles WHERE id=:'sync_id'::uuid)
 AND :'person_role'::jsonb->>'success'='true' AND :'person_status'::jsonb->>'success'='true','the refused calls changed nothing; a person is still changeable');

-- Last administrator: a service account is not another administrator who can sign in.
UPDATE public.user_profiles SET active=true,enrollment_status='approved',role='staff' WHERE id=:'person_id'::uuid;
SELECT pg_temp.sa_assert(warehouse_security.other_active_admin_exists(:'admin_id'::uuid),'before: the second administrator counts for the first');
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.set_service_account(:'admin2_id'::uuid,true) AS second_marked \gset
RESET ROLE;
SELECT pg_temp.sa_assert(:'second_marked'::jsonb->>'success'='true' AND NOT warehouse_security.other_active_admin_exists(:'admin_id'::uuid)
 AND warehouse_security.other_active_admin_exists(:'admin2_id'::uuid),'a service-account administrator no longer counts for the first');
-- The service-account administrator may not mark the only person administrator.
SELECT set_config('request.jwt.claims',:'admin2_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.set_service_account(:'admin_id'::uuid,true) AS last_admin_try, public.update_user_status(:'admin_id'::uuid,false) AS deactivate_last, public.update_user_role(:'admin_id'::uuid,'staff') AS demote_last \gset
RESET ROLE;
SELECT pg_temp.sa_assert(:'last_admin_try'::jsonb->>'error_code'='LAST_ADMIN' AND :'deactivate_last'::jsonb->>'error'='LAST_ADMIN' AND :'demote_last'::jsonb->>'error'='LAST_ADMIN'
 AND (SELECT role='admin' AND active AND NOT is_service_account FROM public.user_profiles WHERE id=:'admin_id'::uuid),
 'the only person administrator cannot be marked, deactivated or demoted: '||:'last_admin_try'||:'deactivate_last'||:'demote_last');
-- Unmarking restores the count and the profile can be changed again.
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.set_service_account(:'admin2_id'::uuid,false) AS unmarked, public.update_user_role(:'sync_id'::uuid,'supervisor') AS role_try_marked_still \gset
SELECT public.set_service_account(:'sync_id'::uuid,false) AS unmarked_sync \gset
SELECT public.update_user_role(:'sync_id'::uuid,'supervisor') AS role_after_unmark \gset
RESET ROLE;
SELECT pg_temp.sa_assert(:'unmarked'::jsonb->>'message'='No longer a service account' AND warehouse_security.other_active_admin_exists(:'admin_id'::uuid)
 AND :'role_try_marked_still'::jsonb->>'error_code'='SERVICE_ACCOUNT_READ_ONLY' AND :'unmarked_sync'::jsonb->>'success'='true'
 AND :'role_after_unmark'::jsonb->>'success'='true','unmarking restores everything: '||:'unmarked'||:'role_after_unmark');
-- The service key may mark (the FAS sync setup runs it).
SELECT set_config('request.jwt.claims','{"role":"service_role"}',true);
SET LOCAL ROLE service_role;
SELECT public.set_service_account(:'sync_id'::uuid,true) AS by_service_key \gset
RESET ROLE;
SELECT pg_temp.sa_assert(:'by_service_key'::jsonb->>'success'='true' AND (SELECT is_service_account FROM public.user_profiles WHERE id=:'sync_id'::uuid),'the service key marks a profile: '||:'by_service_key');

-- CR-35: customer assignment, the central sign-in link and the access-request review refuse a service account too.
INSERT INTO public.user_profiles(auth_user_id,mobile,name,role,active,enrollment_status,is_service_account,central_issuer,central_subject)
 VALUES (gen_random_uuid(),'919555555508','Service Test Machine Customer','customer',true,'approved',true,'https://central.example','subject-machine');
SELECT id AS machine_id FROM public.user_profiles WHERE mobile='919555555508' \gset
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.create_customer('Service Test Orchard','9555555590')->>'success' AS customer_made \gset
RESET ROLE;
SELECT id AS orchard FROM public.customers WHERE name='Service Test Orchard' \gset
-- Customer assignments apply only to the Customer role (owner decision 2026-10-20): the person is a Customer for the assignment and staff again after.
UPDATE public.user_profiles SET role='customer' WHERE id=:'person_id'::uuid;
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.sa_call(format('SELECT to_jsonb(public.assign_customer_to_user(%L,%L::uuid))','919555555505',:'orchard')) AS assign_try,
       pg_temp.sa_call(format('SELECT to_jsonb(public.remove_customer_assignment(%L,%L::uuid))','919555555505',:'orchard')) AS remove_try,
       pg_temp.sa_call(format('SELECT public.clear_user_central_identity(%L::uuid)',:'machine_id')) AS clear_try,
       pg_temp.sa_call(format('SELECT public.operator_review_enrollment(%L::uuid,''disabled'')',:'machine_id')) AS review_try,
       pg_temp.sa_call(format('SELECT to_jsonb(public.assign_customer_to_user(%L,%L::uuid))','919555555507',:'orchard')) AS assign_person,
       pg_temp.sa_call(format('SELECT public.clear_user_central_identity(%L::uuid)',:'person_id')) AS clear_person \gset
RESET ROLE;
SELECT pg_temp.sa_assert(:'assign_try'::jsonb->>'raised' LIKE 'SERVICE_ACCOUNT_READ_ONLY%' AND :'remove_try'::jsonb->>'raised' LIKE 'SERVICE_ACCOUNT_READ_ONLY%'
 AND :'clear_try'::jsonb->>'error_code'='SERVICE_ACCOUNT_READ_ONLY' AND :'review_try'::jsonb->>'error_code'='SERVICE_ACCOUNT_READ_ONLY'
 AND (SELECT count(*)=0 FROM public.users_customers_new WHERE user_profile_id=:'sync_id'::uuid)
 AND (SELECT central_subject='subject-machine' AND active AND enrollment_status='approved' FROM public.user_profiles WHERE id=:'machine_id'::uuid),
 'assignment, removal, central link and review refuse a service account and change nothing: '||:'assign_try'||:'remove_try'||:'clear_try'||:'review_try');
SELECT pg_temp.sa_assert(:'assign_person'::jsonb#>>'{}'='true' AND :'clear_person'::jsonb->>'success'='true'
 AND (SELECT count(*)=1 FROM public.users_customers_new WHERE user_profile_id=:'person_id'::uuid AND active),'a person is still assignable and unlinkable: '||:'assign_person'||:'clear_person');
UPDATE public.user_profiles SET role='staff' WHERE id=:'person_id'::uuid;

-- F41: the facility can always cut a connection off: switching a service account OFF works, and
-- deletes its refresh sessions; switching it back ON stays refused (read-only).
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.set_service_account(:'sync_id'::uuid,true) AS remarked \gset
RESET ROLE;
SELECT pg_temp.sa_assert((SELECT is_service_account AND active FROM public.user_profiles WHERE id=:'sync_id'::uuid)
 AND EXISTS (SELECT 1 FROM warehouse_security.refresh_sessions r JOIN public.user_profiles p ON p.auth_user_id=r.user_id WHERE p.id=:'sync_id'::uuid),
 'before the cut-off: marked, active, with a refresh session');
SET LOCAL ROLE authenticated;
SELECT public.update_user_status(:'sync_id'::uuid,false) AS cut_off \gset
RESET ROLE;
SELECT pg_temp.sa_assert(:'cut_off'::jsonb->>'success'='true'
 AND (SELECT NOT active AND enrollment_status='disabled' AND is_service_account FROM public.user_profiles WHERE id=:'sync_id'::uuid)
 AND NOT EXISTS (SELECT 1 FROM warehouse_security.refresh_sessions r JOIN public.user_profiles p ON p.auth_user_id=r.user_id WHERE p.id=:'sync_id'::uuid),
 'a service account can be cut off: disabled and its sessions are gone: '||:'cut_off');
SET LOCAL ROLE authenticated;
SELECT public.update_user_status(:'sync_id'::uuid,true) AS switch_on \gset
RESET ROLE;
SELECT pg_temp.sa_assert(:'switch_on'::jsonb->>'error_code'='SERVICE_ACCOUNT_READ_ONLY'
 AND (SELECT NOT active FROM public.user_profiles WHERE id=:'sync_id'::uuid),'switching a service account on stays refused: '||:'switch_on');

-- F45: the supervisor picker lists people, not connections.
UPDATE public.user_profiles SET active=true,enrollment_status='approved' WHERE id=:'sync_id'::uuid;
SELECT set_config('request.jwt.claims',:'staff_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.get_supervisors('Service Test') AS picker \gset
RESET ROLE;
SELECT pg_temp.sa_assert(NOT EXISTS (SELECT 1 FROM jsonb_array_elements(:'picker'::jsonb->'data') e WHERE e->>'id'=:'sync_id')
 AND EXISTS (SELECT 1 FROM jsonb_array_elements(:'picker'::jsonb->'data') e WHERE e->>'id'=:'person_id'),
 'the picker hides the marked profile and lists a person: '||:'picker');

-- F39: set_service_account takes the last-administrator lock before the row lock, as the other writers do.
SELECT pg_temp.sa_assert(position('pg_advisory_xact_lock(71043)' IN d) > 0
 AND position('pg_advisory_xact_lock(71043)' IN d) < position('FOR UPDATE' IN d),'lock order: advisory lock, then the row')
FROM (SELECT pg_get_functiondef('public.set_service_account(uuid,boolean)'::regprocedure) AS d) f;

-- F37: get_users_list pages by name, then id: two people with one name never skip or repeat across a page boundary.
RESET ROLE;
INSERT INTO public.user_profiles(auth_user_id,mobile,name,role,active,enrollment_status) VALUES
 (gen_random_uuid(),'919555555531','Zz Twin Name','staff',true,'approved'),
 (gen_random_uuid(),'919555555532','Zz Twin Name','staff',true,'approved'),
 (gen_random_uuid(),'919555555533','Zz Twin Name','staff',true,'approved');
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.get_users_list('Zz Twin',NULL,NULL,1,0) AS tw0, public.get_users_list('Zz Twin',NULL,NULL,1,1) AS tw1,
       public.get_users_list('Zz Twin',NULL,NULL,1,2) AS tw2, public.get_users_list('Zz Twin',NULL,NULL,100,0) AS twall \gset
RESET ROLE;
SELECT pg_temp.sa_assert((SELECT array_agg(u->>'id' ORDER BY u->>'id') FROM jsonb_array_elements(:'twall'::jsonb->'users') u)
   = ARRAY(SELECT x FROM (SELECT :'tw0'::jsonb#>>'{users,0,id}' x UNION ALL SELECT :'tw1'::jsonb#>>'{users,0,id}' UNION ALL SELECT :'tw2'::jsonb#>>'{users,0,id}') q ORDER BY x)
 AND (SELECT count(DISTINCT x)=3 FROM (SELECT :'tw0'::jsonb#>>'{users,0,id}' x UNION ALL SELECT :'tw1'::jsonb#>>'{users,0,id}' UNION ALL SELECT :'tw2'::jsonb#>>'{users,0,id}') q)
 AND (SELECT array_agg(u->>'id' ORDER BY ord) FROM jsonb_array_elements(:'twall'::jsonb->'users') WITH ORDINALITY e(u,ord))
   = (SELECT array_agg(id::text ORDER BY id) FROM public.user_profiles WHERE name='Zz Twin Name'),
 'same-name users: one page each, all distinct, ordered by id: '||:'twall');
ROLLBACK;
