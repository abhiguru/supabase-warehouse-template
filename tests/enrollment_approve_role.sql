-- Migration 77 (2026-10-14): operator_review_enrollment takes a role. An administrator approves
-- a pending access request as customer (as before), staff or supervisor (no customers).
-- Fictional data; runs only in migrations.sh's disposable, network-disabled database.
\set ON_ERROR_STOP on
BEGIN;
CREATE FUNCTION pg_temp.ea_assert(ok boolean, label text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF NOT COALESCE(ok,false) THEN RAISE EXCEPTION 'enrollment approve role: %',label; END IF; END $$;
CREATE FUNCTION pg_temp.ea_call(statement text) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE answer jsonb;
BEGIN
  BEGIN EXECUTE statement INTO answer;
  EXCEPTION WHEN OTHERS THEN RETURN jsonb_build_object('raised', SQLERRM, 'state', SQLSTATE); END;
  RETURN answer;
END $$;
CREATE FUNCTION pg_temp.ea_login(phone text) RETURNS jsonb LANGUAGE plpgsql AS $$
 DECLARE c jsonb; l jsonb; claims jsonb;
 BEGIN
  c:=public.operator_prepare_otp(phone);
  PERFORM pg_temp.ea_assert(c->>'success'='true','challenge prepared for '||phone);
  PERFORM public.operator_finish_otp((c#>>'{data,request_id}')::uuid,true,'mock-provider-only');
  l:=public.operator_verify_otp(phone,c#>>'{data,otp_code}');
  PERFORM pg_temp.ea_assert(l#>>'{data,action}'='login','login for '||phone||': '||l::text);
  SELECT jsonb_build_object('role','authenticated','sub',p.auth_user_id,'session_id',r.id) INTO claims
   FROM public.user_profiles p JOIN warehouse_security.refresh_sessions r ON r.user_id=p.auth_user_id
   WHERE p.mobile=warehouse_security.normalize_phone(phone) ORDER BY r.created_at DESC LIMIT 1;
  RETURN claims;
 END $$;
-- The profile as "role/enrollment/active/assignments".
CREATE FUNCTION pg_temp.ea_state(p_profile uuid) RETURNS text LANGUAGE sql AS $$
  SELECT p.role||'/'||p.enrollment_status||'/'||p.active||'/'||(SELECT count(*) FROM public.users_customers_new u WHERE u.user_profile_id=p.id AND u.active)
  FROM public.user_profiles p WHERE p.id=p_profile $$;
INSERT INTO warehouse_security.auth_config(key,value) VALUES
 ('jwt_secret','isolated-test-secret-not-for-any-deployment-12345'),('auth_mode','operator'),('demo_auth_enabled','false')
 ON CONFLICT(key) DO UPDATE SET value=excluded.value;
UPDATE public.sms_config SET provider='msg91',production_mode=true,msg91_auth_key='isolated-test-key',
 msg91_template_id='000000000000000000000001',msg91_pe_id='0000000000000000001',msg91_sender_id='CITEST'
 WHERE id=(SELECT id FROM public.sms_config ORDER BY id DESC LIMIT 1);
SELECT warehouse_security.bootstrap_first_admin('9666666601','Approve Role Administrator') AS admin_user \gset
INSERT INTO public.user_profiles(auth_user_id,mobile,name,role,active,enrollment_status) VALUES
 (gen_random_uuid(),'919666666602','Approve Role Supervisor','supervisor',true,'approved'),
 (gen_random_uuid(),'919666666603','Approve Role Staff','staff',true,'approved'),
 (gen_random_uuid(),'919666666604','Approve Pending Staff','customer',false,'pending'),
 (gen_random_uuid(),'919666666605','Approve Pending Supervisor','customer',false,'pending'),
 (gen_random_uuid(),'919666666606','Approve Pending Customer','customer',false,'pending'),
 (gen_random_uuid(),'919666666607','Approve Pending Refused','customer',false,'pending'),
 (gen_random_uuid(),'919666666608','Approve Pending Three','customer',false,'pending'),
 (gen_random_uuid(),'919666666609','Approve Pending Reject','customer',false,'pending');
SELECT id AS p_staff FROM public.user_profiles WHERE mobile='919666666604' \gset
SELECT id AS p_sup FROM public.user_profiles WHERE mobile='919666666605' \gset
SELECT id AS p_cust FROM public.user_profiles WHERE mobile='919666666606' \gset
SELECT id AS p_refused FROM public.user_profiles WHERE mobile='919666666607' \gset
SELECT id AS p_three FROM public.user_profiles WHERE mobile='919666666608' \gset
SELECT id AS p_reject FROM public.user_profiles WHERE mobile='919666666609' \gset
SELECT pg_temp.ea_login('9666666601') AS admin_claims \gset
SELECT pg_temp.ea_login('9666666602') AS supervisor_claims \gset
SELECT pg_temp.ea_login('9666666603') AS staff_claims \gset
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.ea_assert(public.create_customer('Approve Role Orchard','9666666611')->>'success'='true','customer fixture');
RESET ROLE;
SELECT id AS orchard FROM public.customers WHERE name='Approve Role Orchard' \gset

-- Signature and grants: the fourth argument has a default; the old three-argument signature is gone.
SELECT pg_temp.ea_assert(to_regprocedure('public.operator_review_enrollment(uuid,text,uuid[],text)') IS NOT NULL
 AND to_regprocedure('public.operator_review_enrollment(uuid,text,uuid[])') IS NULL
 AND has_function_privilege('authenticated','public.operator_review_enrollment(uuid,text,uuid[],text)','EXECUTE')
 AND NOT has_function_privilege('anon','public.operator_review_enrollment(uuid,text,uuid[],text)','EXECUTE')
 AND (SELECT pronargdefaults=2 FROM pg_proc WHERE oid='public.operator_review_enrollment(uuid,text,uuid[],text)'::regprocedure),'signature and grants');

-- Non-administrators are refused, and nothing changes.
SELECT set_config('request.jwt.claims',:'supervisor_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.ea_call(format('SELECT public.operator_review_enrollment(%L,''approved'',''{}'',''staff'')',:'p_staff')) AS sup_try \gset
RESET ROLE;
SELECT set_config('request.jwt.claims',:'staff_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.ea_call(format('SELECT public.operator_review_enrollment(%L,''approved'',''{}'',''staff'')',:'p_staff')) AS staff_try \gset
RESET ROLE;
SELECT pg_temp.ea_assert(:'sup_try'::jsonb->>'state'='42501' AND :'staff_try'::jsonb->>'state'='42501' AND pg_temp.ea_state(:'p_staff'::uuid)='customer/pending/false/0',
 'a supervisor and a staff member are refused, the request stays pending: '||:'sup_try'||:'staff_try'||pg_temp.ea_state(:'p_staff'::uuid));

SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
-- Approve as staff.
SELECT public.operator_review_enrollment(:'p_staff'::uuid,'approved','{}','staff') AS as_staff \gset
-- Approve as supervisor.
SELECT public.operator_review_enrollment(:'p_sup'::uuid,'approved',NULL,'supervisor') AS as_sup \gset
-- Approve as customer, with the new argument and with three arguments.
SELECT public.operator_review_enrollment(:'p_cust'::uuid,'approved',ARRAY[:'orchard'::uuid],'customer') AS as_cust \gset
SELECT public.operator_review_enrollment(:'p_three'::uuid,'approved',ARRAY[:'orchard'::uuid]) AS as_three \gset
RESET ROLE;
SELECT pg_temp.ea_assert(:'as_staff'::jsonb=jsonb_build_object('success',true,'data',jsonb_build_object('status','approved','role','staff'))
 AND pg_temp.ea_state(:'p_staff'::uuid)='staff/approved/true/0','approved as staff: '||:'as_staff'||pg_temp.ea_state(:'p_staff'::uuid));
SELECT pg_temp.ea_assert(:'as_sup'::jsonb->'data'='{"status":"approved","role":"supervisor"}'::jsonb
 AND pg_temp.ea_state(:'p_sup'::uuid)='supervisor/approved/true/0','approved as supervisor (NULL customers): '||:'as_sup'||pg_temp.ea_state(:'p_sup'::uuid));
SELECT pg_temp.ea_assert(:'as_cust'::jsonb->'data'='{"status":"approved","role":"customer"}'::jsonb
 AND pg_temp.ea_state(:'p_cust'::uuid)='customer/approved/true/1','approved as customer: '||:'as_cust'||pg_temp.ea_state(:'p_cust'::uuid));
SELECT pg_temp.ea_assert(:'as_three'::jsonb->'data'='{"status":"approved","role":"customer"}'::jsonb
 AND pg_temp.ea_state(:'p_three'::uuid)='customer/approved/true/1','the three-argument call still approves a customer: '||:'as_three'||pg_temp.ea_state(:'p_three'::uuid));

-- The approved staff member signs in as staff, the supervisor as supervisor.
SELECT pg_temp.ea_login('9666666604') AS new_staff_claims \gset
SELECT pg_temp.ea_login('9666666605') AS new_sup_claims \gset
SELECT set_config('request.jwt.claims',:'new_staff_claims',true);
SET LOCAL ROLE authenticated;
SELECT warehouse_security.active_role() AS staff_role \gset
RESET ROLE;
SELECT set_config('request.jwt.claims',:'new_sup_claims',true);
SET LOCAL ROLE authenticated;
SELECT warehouse_security.active_role() AS sup_role \gset
RESET ROLE;
SELECT pg_temp.ea_assert(:'staff_role'='staff' AND :'sup_role'='supervisor','the approved people sign in with their roles: '||:'staff_role'||' '||:'sup_role');

-- Refusals.
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.operator_review_enrollment(:'p_refused'::uuid,'approved',ARRAY[:'orchard'::uuid],'staff') AS staff_with_customers,
       public.operator_review_enrollment(:'p_refused'::uuid,'approved',ARRAY[:'orchard'::uuid],'supervisor') AS sup_with_customers,
       public.operator_review_enrollment(:'p_refused'::uuid,'approved','{}','admin') AS bad_role,
       public.operator_review_enrollment(:'p_refused'::uuid,'approved','{}',NULL) AS null_role,
       pg_temp.ea_call(format('SELECT public.operator_review_enrollment(%L,''approved'',''{}'',''customer'')',:'p_refused')) AS customer_no_customers,
       pg_temp.ea_call(format('SELECT public.operator_review_enrollment(%L,''approved'',''{}'')',:'p_refused')) AS three_no_customers,
       pg_temp.ea_call(format('SELECT public.operator_review_enrollment(%L,''maybe'',''{}'',''staff'')',:'p_refused')) AS bad_decision,
       public.operator_review_enrollment(:'p_staff'::uuid,'approved','{}','staff') AS already_staff,
       public.operator_review_enrollment(gen_random_uuid(),'approved','{}','staff') AS unknown_user \gset
RESET ROLE;
SELECT pg_temp.ea_assert(:'staff_with_customers'::jsonb->>'error_code'='CUSTOMERS_NOT_ALLOWED' AND :'staff_with_customers'::jsonb->>'success'='false'
 AND :'sup_with_customers'::jsonb->>'error_code'='CUSTOMERS_NOT_ALLOWED' AND :'staff_with_customers'::jsonb->>'code'='CUSTOMERS_NOT_ALLOWED',
 'customers with staff or supervisor are refused: '||:'staff_with_customers'||:'sup_with_customers');
SELECT pg_temp.ea_assert(:'bad_role'::jsonb->>'error_code'='INVALID_ROLE' AND :'null_role'::jsonb->>'error_code'='INVALID_ROLE','unknown and NULL roles are refused: '||:'bad_role'||:'null_role');
SELECT pg_temp.ea_assert(:'customer_no_customers'::jsonb->>'state'='22023' AND :'three_no_customers'::jsonb->>'state'='22023' AND :'bad_decision'::jsonb->>'state'='22023',
 'a customer needs a customer, a bad decision is refused as before: '||:'customer_no_customers'||:'bad_decision');
SELECT pg_temp.ea_assert(:'already_staff'::jsonb->>'code'='unknown_user' AND :'unknown_user'::jsonb->>'code'='unknown_user','a profile that is no longer a request is unknown_user, as before');
SELECT pg_temp.ea_assert(pg_temp.ea_state(:'p_refused'::uuid)='customer/pending/false/0','every refusal left the request pending: '||pg_temp.ea_state(:'p_refused'::uuid));

-- Reject, and the role argument does not change a rejection (the profile stays a customer).
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.operator_review_enrollment(:'p_reject'::uuid,'rejected') AS rej3,
       pg_temp.ea_call(format('SELECT public.operator_review_enrollment(%L,''rejected'',''{}'',''staff'')',:'p_refused')) AS rej_staff \gset
RESET ROLE;
SELECT pg_temp.ea_assert(:'rej3'::jsonb=jsonb_build_object('success',true,'data',jsonb_build_object('status','rejected','role','customer'))
 AND pg_temp.ea_state(:'p_reject'::uuid)='customer/rejected/false/0','a rejection is as before, plus the role: '||:'rej3'||pg_temp.ea_state(:'p_reject'::uuid));
SELECT pg_temp.ea_assert(:'rej_staff'::jsonb->'data'='{"status":"rejected","role":"customer"}'::jsonb AND pg_temp.ea_state(:'p_refused'::uuid)='customer/rejected/false/0',
 'rejecting with p_role staff leaves a customer who is rejected: '||:'rej_staff');

-- F31: a decision on a request that is no longer pending is refused (a stale Access requests list).
-- p_cust was approved as a customer above?  Use fresh rows so the states are known.
RESET ROLE;
INSERT INTO public.user_profiles(auth_user_id,mobile,name,role,active,enrollment_status) VALUES
 (gen_random_uuid(),'919666666621','Stale Approved Customer','customer',true,'approved'),
 (gen_random_uuid(),'919666666622','Stale Disabled Customer','customer',false,'disabled'),
 (gen_random_uuid(),'919666666623','Stale Rejected Customer','customer',false,'rejected');
SELECT id AS s_appr FROM public.user_profiles WHERE mobile='919666666621' \gset
SELECT id AS s_dis FROM public.user_profiles WHERE mobile='919666666622' \gset
SELECT id AS s_rej FROM public.user_profiles WHERE mobile='919666666623' \gset
INSERT INTO public.users_customers_new(user_profile_id,customer_id,assigned_by,active) VALUES (:'s_appr'::uuid,:'orchard'::uuid,(SELECT id FROM public.user_profiles WHERE auth_user_id=:'admin_user'::uuid),true);
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.operator_review_enrollment(:'s_appr'::uuid,'approved','{}','staff') AS stale_staff,
       public.operator_review_enrollment(:'s_appr'::uuid,'rejected') AS stale_reject,
       public.operator_review_enrollment(:'s_dis'::uuid,'approved',ARRAY[:'orchard'::uuid]) AS stale_dis,
       public.operator_review_enrollment(:'s_rej'::uuid,'approved','{}','supervisor') AS stale_rej \gset
RESET ROLE;
SELECT pg_temp.ea_assert(:'stale_staff'::jsonb->>'code'='unknown_user' AND :'stale_reject'::jsonb->>'code'='unknown_user'
 AND :'stale_dis'::jsonb->>'code'='unknown_user' AND :'stale_rej'::jsonb->>'code'='unknown_user'
 AND pg_temp.ea_state(:'s_appr'::uuid)='customer/approved/true/1' AND pg_temp.ea_state(:'s_dis'::uuid)='customer/disabled/false/0'
 AND pg_temp.ea_state(:'s_rej'::uuid)='customer/rejected/false/0','stale decisions change nothing: '||:'stale_staff'||pg_temp.ea_state(:'s_appr'::uuid));
-- Disabling an approved customer is still allowed.
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.operator_review_enrollment(:'s_appr'::uuid,'disabled') AS disable_ok \gset
RESET ROLE;
SELECT pg_temp.ea_assert(:'disable_ok'::jsonb->>'success'='true' AND pg_temp.ea_state(:'s_appr'::uuid)='customer/disabled/false/0','an approved customer can still be disabled: '||:'disable_ok');
ROLLBACK;
