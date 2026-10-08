-- Migration 25 regression: administrator status changes keep the operator
-- enrollment state consistent. Runs only in migrations.sh's disposable,
-- network-disabled database; every fixture row rolls back.
\set ON_ERROR_STOP on
BEGIN;
CREATE FUNCTION pg_temp.status_assert(ok boolean, label text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF NOT COALESCE(ok,false) THEN RAISE EXCEPTION 'user status: %',label; END IF; END $$;
CREATE FUNCTION pg_temp.status_login(phone text) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE challenge jsonb; login jsonb; claims jsonb;
BEGIN
  UPDATE public.otp_verifications SET created_at=created_at-interval '61 seconds'
    WHERE phone_number=warehouse_security.normalize_phone(phone);
  challenge := public.operator_prepare_otp(phone);
  PERFORM pg_temp.status_assert(challenge->>'success'='true','ordinary challenge for '||phone);
  PERFORM public.operator_finish_otp((challenge#>>'{data,request_id}')::uuid,true,'mock-provider-only');
  login := public.operator_verify_otp(phone,challenge#>>'{data,otp_code}');
  PERFORM pg_temp.status_assert(login#>>'{data,action}'='login','ordinary login for '||phone||': '||COALESCE(login->>'code',''));
  SELECT jsonb_build_object('role','authenticated','sub',p.auth_user_id,'session_id',s.id)
    INTO claims FROM public.user_profiles p JOIN warehouse_security.refresh_sessions s ON s.user_id=p.auth_user_id
    WHERE p.mobile=warehouse_security.normalize_phone(phone) ORDER BY s.created_at DESC LIMIT 1;
  RETURN claims;
END $$;
CREATE FUNCTION pg_temp.status_login_code(phone text) RETURNS text LANGUAGE plpgsql AS $$
DECLARE challenge jsonb; login jsonb;
BEGIN
  UPDATE public.otp_verifications SET created_at=created_at-interval '61 seconds'
    WHERE phone_number=warehouse_security.normalize_phone(phone);
  challenge := public.operator_prepare_otp(phone);
  PERFORM public.operator_finish_otp((challenge#>>'{data,request_id}')::uuid,true,'mock-provider-only');
  login := public.operator_verify_otp(phone,challenge#>>'{data,otp_code}');
  RETURN COALESCE(login->>'code',login#>>'{data,action}');
END $$;
INSERT INTO warehouse_security.auth_config(key,value) VALUES
 ('jwt_secret','isolated-test-secret-not-for-any-deployment-12345'),
 ('auth_mode','operator'),('demo_auth_enabled','false')
 ON CONFLICT(key) DO UPDATE SET value=excluded.value;
UPDATE public.sms_config SET provider='msg91',production_mode=true,msg91_auth_key='isolated-test-key',
 msg91_template_id='000000000000000000000001',msg91_pe_id='0000000000000000001',msg91_sender_id='CITEST'
 WHERE id=(SELECT id FROM public.sms_config ORDER BY id DESC LIMIT 1);
SELECT warehouse_security.bootstrap_first_admin('9888888881','Status Administrator') AS admin_user \gset
INSERT INTO public.user_profiles(auth_user_id,mobile,name,role,active,enrollment_status) VALUES
 (gen_random_uuid(),'919888888882','Status Staff','staff',true,'approved'),
 (gen_random_uuid(),'919888888883','Status Customer','customer',true,'approved'),
 (gen_random_uuid(),'919888888884','Status Pending','customer',false,'pending');
INSERT INTO public.customers(name,mobile) VALUES ('Status Customer Account','9888888885') RETURNING id AS customer_account \gset
INSERT INTO public.users_customers_new(user_profile_id,customer_id,active)
 SELECT id,:'customer_account'::uuid,true FROM public.user_profiles WHERE mobile='919888888883';
SELECT pg_temp.status_login('9888888881') AS admin_claims \gset
SELECT pg_temp.status_login('9888888882') AS staff_claims \gset
SELECT id AS staff_profile FROM public.user_profiles WHERE mobile='919888888882' \gset
SELECT id AS customer_profile FROM public.user_profiles WHERE mobile='919888888883' \gset
SELECT id AS pending_profile FROM public.user_profiles WHERE mobile='919888888884' \gset
SELECT count(*) AS audit_before FROM public.audit_log \gset

-- Deactivation: enrollment disabled, sessions revoked, audited, login refused.
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.update_user_status(:'staff_profile'::uuid,false) AS disabled \gset
SELECT pg_temp.status_assert(:'disabled'::jsonb->>'success'='true','administrator deactivates staff: '||COALESCE(:'disabled'::jsonb->>'message',''));
RESET ROLE;
SELECT pg_temp.status_assert((SELECT NOT active AND enrollment_status='disabled' FROM public.user_profiles WHERE id=:'staff_profile'::uuid),'deactivation marks the enrollment disabled');
SELECT pg_temp.status_assert((SELECT count(*)=0 FROM warehouse_security.refresh_sessions WHERE user_id=(SELECT auth_user_id FROM public.user_profiles WHERE id=:'staff_profile'::uuid)),'deactivation revokes sessions');
SELECT pg_temp.status_assert((SELECT count(*) FROM public.audit_log) > :'audit_before'::bigint,'deactivation is audited');
SELECT set_config('request.jwt.claims',:'staff_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.status_assert(warehouse_security.active_role() IS NULL,'deactivated staff has no active role');
RESET ROLE;
SELECT pg_temp.status_assert(pg_temp.status_login_code('9888888882')='account_unavailable','deactivated staff cannot sign in');

-- Reactivation through the ordinary status RPC restores approval and login.
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.update_user_status(:'staff_profile'::uuid,true) AS reactivated \gset
SELECT pg_temp.status_assert(:'reactivated'::jsonb->>'success'='true','administrator reactivates staff: '||COALESCE(:'reactivated'::jsonb->>'message',''));
RESET ROLE;
SELECT pg_temp.status_assert((SELECT active AND enrollment_status='approved' FROM public.user_profiles WHERE id=:'staff_profile'::uuid),'reactivation restores approval');
SELECT pg_temp.status_login('9888888882') AS staff_again \gset
SELECT set_config('request.jwt.claims',:'staff_again',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.status_assert(warehouse_security.active_role()='staff','reactivated staff signs in again');
RESET ROLE;

-- A customer disabled through enrollment review is also recoverable by status.
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.operator_review_enrollment(:'customer_profile'::uuid,'disabled') AS reviewed \gset
SELECT pg_temp.status_assert(:'reviewed'::jsonb->>'success'='true','review disables the customer');
SELECT public.update_user_status(:'customer_profile'::uuid,true) AS customer_back \gset
SELECT pg_temp.status_assert(:'customer_back'::jsonb->>'success'='true','status reactivates the review-disabled customer');
RESET ROLE;
SELECT pg_temp.status_assert((SELECT active AND enrollment_status='approved' FROM public.user_profiles WHERE id=:'customer_profile'::uuid),'review-disabled customer is approved again');
SELECT pg_temp.status_assert(pg_temp.status_login_code('9888888883')='login','review-disabled customer signs in after status reactivation');

-- Pending enrollments cannot be approved by the status RPC.
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.update_user_status(:'pending_profile'::uuid,true) AS pending_attempt \gset
SELECT pg_temp.status_assert(:'pending_attempt'::jsonb->>'success'='false','pending enrollment is not approvable by status');
RESET ROLE;
SELECT pg_temp.status_assert((SELECT NOT active AND enrollment_status='pending' FROM public.user_profiles WHERE id=:'pending_profile'::uuid),'pending profile unchanged');
ROLLBACK;
\echo 'User status deactivation, reactivation, review recovery and pending protection checks passed.'
