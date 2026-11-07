-- Migration 154 (WH-114): four sign-in access gaps.
--  1. With the facility's own code on (auth_config central_local_code), a central sign-in that finds an UNLINKED profile by phone does not
--     link it first: link_required without a code; a wrong code links nothing; the right code signs in and links.
--  2. operator_verify_otp: a code is spent only once the account is known to be answerable. account_unavailable (rejected, disabled,
--     deactivated) is answered before the code is used, so the same code works again when the account becomes available.
--  3. operator_finish_otp, operator_sms_config, operator_enrollment_status, operator_enrollment_signout and operator_review_enrollment
--     answer {success:false, code:'unavailable'} when auth_mode is not 'operator' (operator_break_glass_open: false), and work as before in
--     operator mode.
--  4. clear_user_central_identity: the service role may call it (an operator script); anon and the other roles still may not.
-- Fictional data; runs only in migrations.sh's disposable, network-disabled database; rolls back.
\set ON_ERROR_STOP on
BEGIN;
CREATE FUNCTION pg_temp.sa_assert(ok boolean, label text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF NOT COALESCE(ok,false) THEN RAISE EXCEPTION 'sign-in access 154: %',label; END IF; END $$;
CREATE FUNCTION pg_temp.sa_exchange(subject text, phone text, jti text, otp text DEFAULT NULL) RETURNS jsonb LANGUAGE sql AS $$
  SELECT public.operator_central_exchange('https://login.association.example.test', subject, phone, jti, now()+interval '5 minutes', NULL, NULL, NULL, otp) $$;
CREATE FUNCTION pg_temp.sa_code(phone text) RETURNS text LANGUAGE plpgsql AS $$
DECLARE challenge jsonb;
BEGIN
  UPDATE public.otp_verifications SET created_at=created_at-interval '61 seconds' WHERE phone_number=phone;
  challenge := public.operator_prepare_otp(phone);
  PERFORM pg_temp.sa_assert(challenge->>'success'='true','an SMS code is prepared for '||phone||': '||challenge::text);
  PERFORM public.operator_finish_otp((challenge#>>'{data,request_id}')::uuid,true,'mock-provider-only');
  RETURN challenge#>>'{data,otp_code}';
END $$;
CREATE FUNCTION pg_temp.sa_outcome(statement text) RETURNS text LANGUAGE plpgsql AS $$
DECLARE answer jsonb;
BEGIN
  BEGIN EXECUTE statement INTO answer;
  EXCEPTION WHEN insufficient_privilege THEN RETURN 'refused';
    WHEN OTHERS THEN RETURN 'error: '||SQLSTATE||' '||SQLERRM; END;
  RETURN answer::text;
END $$;
INSERT INTO warehouse_security.auth_config(key,value) VALUES
 ('jwt_secret','isolated-test-secret-not-for-any-deployment-12345'),
 ('auth_mode','operator'),('demo_auth_enabled','false')
 ON CONFLICT(key) DO UPDATE SET value=excluded.value;
UPDATE public.sms_config SET provider='msg91',production_mode=true,msg91_auth_key='isolated-test-key',
 msg91_template_id='000000000000000000000001',msg91_pe_id='0000000000000000001',msg91_sender_id='CITEST'
 WHERE id=(SELECT id FROM public.sms_config ORDER BY id DESC LIMIT 1);
SELECT warehouse_security.bootstrap_first_admin('9000000501','Access Gaps Administrator') AS admin_user \gset
INSERT INTO warehouse_security.refresh_sessions(user_id,token_hash,expires_at) VALUES (:'admin_user'::uuid,encode(extensions.gen_random_bytes(32),'hex'),now()+interval '1 hour');
SELECT jsonb_build_object('role','authenticated','sub',:'admin_user'::uuid,'session_id',(SELECT id FROM warehouse_security.refresh_sessions WHERE user_id=:'admin_user'::uuid ORDER BY created_at DESC LIMIT 1)) AS bare_admin_claims \gset
INSERT INTO public.user_profiles(auth_user_id,mobile,name,role,active,enrollment_status) VALUES
 (gen_random_uuid(),'919000000502','Access Gaps Unlinked Staff','staff',true,'approved'),
 (gen_random_uuid(),'919000000503','Access Gaps Linked Staff','staff',true,'approved');
UPDATE public.user_profiles SET central_issuer='https://login.association.example.test', central_subject='access-gaps-0503' WHERE mobile='919000000503';
SELECT id AS linked_profile FROM public.user_profiles WHERE mobile='919000000503' \gset

-- ===== 1. link only after the facility's code =====
INSERT INTO warehouse_security.auth_config(key,value) VALUES ('central_issuer','https://login.association.example.test'),('central_local_code','on');
SELECT pg_temp.sa_exchange('access-gaps-0502','919000000502','access-gaps-jti-0001') AS no_code \gset
SELECT pg_temp.sa_assert(:'no_code'::jsonb = '{"success":false,"code":"link_required"}'::jsonb
  AND (SELECT central_subject IS NULL AND central_issuer IS NULL FROM public.user_profiles WHERE mobile='919000000502'),
  'an unlinked profile found by phone answers link_required and stays unlinked: '||:'no_code');
SELECT pg_temp.sa_code('919000000502') AS code_502 \gset
SELECT CASE WHEN :'code_502'='000000' THEN '111111' ELSE '000000' END AS wrong_code \gset
SELECT pg_temp.sa_exchange('access-gaps-0502','919000000502','access-gaps-jti-0002',:'wrong_code') AS wrong_answer \gset
SELECT pg_temp.sa_assert(:'wrong_answer'::jsonb->>'code'='invalid_otp'
  AND (SELECT central_subject IS NULL FROM public.user_profiles WHERE mobile='919000000502'), 'a wrong code links nothing: '||:'wrong_answer');
SELECT pg_temp.sa_exchange('access-gaps-0502','919000000502','access-gaps-jti-0003',:'code_502') AS right_answer \gset
SELECT pg_temp.sa_assert(:'right_answer'::jsonb->>'success'='true' AND :'right_answer'::jsonb#>>'{data,action}'='login'
  AND :'right_answer'::jsonb#>>'{data,user,central_subject}'='access-gaps-0502'
  AND (SELECT central_subject='access-gaps-0502' AND mobile_verified FROM public.user_profiles WHERE mobile='919000000502'),
  'the right code signs in and only then links: '||left(:'right_answer',300));
-- A profile found by its central subject, and a facility with the setting off, behave as before.
SELECT pg_temp.sa_exchange('access-gaps-0503','919000000503','access-gaps-jti-0004') AS by_subject \gset
SELECT pg_temp.sa_assert(:'by_subject'::jsonb = '{"success":false,"code":"link_required"}'::jsonb, 'a linked profile is asked for the code: '||:'by_subject');
UPDATE warehouse_security.auth_config SET value='off' WHERE key='central_local_code';
INSERT INTO public.user_profiles(auth_user_id,mobile,name,role,active,enrollment_status) VALUES (gen_random_uuid(),'919000000504','Access Gaps Setting Off','staff',true,'approved');
SELECT pg_temp.sa_exchange('access-gaps-0504','919000000504','access-gaps-jti-0005') AS setting_off \gset
SELECT pg_temp.sa_assert(:'setting_off'::jsonb->>'success'='true' AND (SELECT central_subject='access-gaps-0504' FROM public.user_profiles WHERE mobile='919000000504'),
  'with the setting off the profile is linked by the token alone, as before: '||left(:'setting_off',200));

-- ===== 2. a code is not spent by a refusal =====
SELECT pg_temp.sa_code('919000000511') AS code_511 \gset
INSERT INTO public.user_profiles(auth_user_id,mobile,name,role,active,enrollment_status) VALUES (gen_random_uuid(),'919000000511','Access Gaps Rejected','customer',false,'rejected');
SELECT public.operator_verify_otp('9000000511',:'code_511') AS refused_first \gset
SELECT pg_temp.sa_assert(:'refused_first'::jsonb = '{"success":false,"code":"account_unavailable"}'::jsonb, 'a rejected profile is refused: '||:'refused_first');
SELECT pg_temp.sa_assert((SELECT count(*)=1 AND bool_and(NOT verified AND otp_code_hash IS NOT NULL) FROM public.otp_verifications WHERE phone_number='919000000511'),
  'the code was not spent by the refusal');
SELECT public.operator_verify_otp('9000000511',:'code_511') AS refused_again \gset
SELECT pg_temp.sa_assert(:'refused_again'::jsonb->>'code'='account_unavailable', 'and it is refused the same way again');
UPDATE public.user_profiles SET active=true, enrollment_status='approved' WHERE mobile='919000000511';
SELECT public.operator_verify_otp('9000000511',:'code_511') AS accepted_later \gset
SELECT pg_temp.sa_assert(:'accepted_later'::jsonb#>>'{data,action}'='login' AND (SELECT bool_and(verified) FROM public.otp_verifications WHERE phone_number='919000000511'),
  'the same code signs in once the account is available, and is then spent: '||left(:'accepted_later',200));
SELECT public.operator_verify_otp('9000000511',:'code_511') AS spent_answer \gset
SELECT pg_temp.sa_assert(:'spent_answer'::jsonb->>'success'='false' AND :'spent_answer'::jsonb->>'code' IS DISTINCT FROM 'account_unavailable', 'a spent code is refused: '||:'spent_answer');
-- Disabled and deactivated profiles are refused before the code is spent too; a pending request is still answered.
SELECT pg_temp.sa_code('919000000512') AS code_512 \gset
INSERT INTO public.user_profiles(auth_user_id,mobile,name,role,active,enrollment_status) VALUES (gen_random_uuid(),'919000000512','Access Gaps Disabled','staff',false,'disabled');
SELECT pg_temp.sa_assert(public.operator_verify_otp('9000000512',:'code_512')->>'code'='account_unavailable'
  AND (SELECT NOT verified FROM public.otp_verifications WHERE phone_number='919000000512'), 'a disabled profile is refused and its code is not spent');
SELECT pg_temp.sa_code('919000000513') AS code_513 \gset
INSERT INTO public.user_profiles(auth_user_id,mobile,name,role,active,enrollment_status) VALUES (gen_random_uuid(),'919000000513','Access Gaps Deactivated','staff',false,'approved');
SELECT pg_temp.sa_assert(public.operator_verify_otp('9000000513',:'code_513')->>'code'='account_unavailable'
  AND (SELECT NOT verified FROM public.otp_verifications WHERE phone_number='919000000513'), 'a deactivated profile is refused and its code is not spent');
SELECT pg_temp.sa_code('919000000514') AS code_514 \gset
INSERT INTO public.user_profiles(auth_user_id,mobile,name,role,active,enrollment_status) VALUES (gen_random_uuid(),'919000000514','Access Gaps Pending','customer',false,'pending');
SELECT public.operator_verify_otp('9000000514',:'code_514') AS pending_answer \gset
SELECT pg_temp.sa_assert(:'pending_answer'::jsonb#>>'{data,action}'='pending' AND (SELECT verified FROM public.otp_verifications WHERE phone_number='919000000514'),
  'a pending request is answered pending and spends the code: '||left(:'pending_answer',200));

-- ===== 3. the operator-mode functions in another auth mode =====
SELECT pg_temp.sa_code('919000000521') AS code_521 \gset
SELECT public.operator_prepare_otp('9000000522')->>'success' AS prepared_522 \gset
SELECT (public.operator_prepare_otp('9000000523')#>>'{data,request_id}')::uuid AS request_523 \gset
SELECT 'a'||repeat('0',63) AS token_a \gset
-- In operator mode first: the answers the tests below turn into 'unavailable'.
SELECT pg_temp.sa_assert(public.operator_enrollment_status(:'token_a')->>'code'='invalid_token', 'operator mode: an unknown enrolment token is invalid_token');
SELECT pg_temp.sa_assert(public.operator_sms_config()->>'success'='true', 'operator mode: the SMS settings are handed out: '||public.operator_sms_config()::text);
UPDATE warehouse_security.auth_config SET value='demo' WHERE key='auth_mode';
SELECT pg_temp.sa_assert(public.operator_finish_otp(:'request_523'::uuid,true,'mock-provider-only')::jsonb = '{"success":false,"code":"unavailable"}'::jsonb, 'operator_finish_otp is unavailable');
SELECT pg_temp.sa_assert(public.operator_sms_config()::jsonb = '{"success":false,"code":"unavailable"}'::jsonb, 'operator_sms_config is unavailable');
SELECT pg_temp.sa_assert(public.operator_enrollment_status(:'token_a')::jsonb = '{"success":false,"code":"unavailable"}'::jsonb, 'operator_enrollment_status is unavailable');
SELECT pg_temp.sa_assert(public.operator_enrollment_signout(:'token_a')::jsonb = '{"success":false,"code":"unavailable"}'::jsonb, 'operator_enrollment_signout is unavailable');
SELECT pg_temp.sa_assert(public.operator_break_glass_open('9000000501') = false, 'operator_break_glass_open is false');
SELECT pg_temp.sa_assert(position('auth_mode' IN pg_get_functiondef('public.operator_break_glass_open(text)'::regprocedure)) > 0
  AND position('WH-114' IN pg_get_functiondef('public.operator_break_glass_open(text)'::regprocedure)) > 0, 'operator_break_glass_open checks the auth mode');
-- operator_review_enrollment keeps its administrator check first, then answers unavailable.
SELECT set_config('request.jwt.claims',:'bare_admin_claims',true);
SELECT pg_temp.sa_outcome('SELECT public.operator_review_enrollment(gen_random_uuid(),''approved'')') AS review_other_mode \gset
SELECT set_config('request.jwt.claims','{"role":"anon"}',true);
SELECT pg_temp.sa_outcome('SELECT public.operator_review_enrollment(gen_random_uuid(),''approved'')') AS review_anon \gset
SELECT pg_temp.sa_assert(:'review_other_mode'::jsonb = '{"success":false,"code":"unavailable"}'::jsonb, 'an administrator reviewing in another auth mode: '||:'review_other_mode');
SELECT pg_temp.sa_assert(:'review_anon' NOT LIKE '%unavailable%', 'a caller who is not an administrator is still refused by the administrator check first: '||:'review_anon');
UPDATE warehouse_security.auth_config SET value='operator' WHERE key='auth_mode';
SELECT pg_temp.sa_assert(public.operator_sms_config()->>'success'='true', 'back in operator mode the SMS settings are handed out again');

-- ===== 4. clear_user_central_identity for the service role =====
SELECT pg_temp.sa_assert(has_function_privilege('service_role','public.clear_user_central_identity(uuid)','EXECUTE')
  AND has_function_privilege('authenticated','public.clear_user_central_identity(uuid)','EXECUTE')
  AND NOT has_function_privilege('anon','public.clear_user_central_identity(uuid)','EXECUTE'), 'grants: service_role and authenticated, not anon');
SELECT set_config('request.jwt.claims','{"role":"service_role"}',true);
SET LOCAL ROLE service_role;
SELECT public.clear_user_central_identity(:'linked_profile'::uuid) AS service_cleared \gset
RESET ROLE;
SELECT pg_temp.sa_assert(:'service_cleared'::jsonb->>'success'='true' AND :'service_cleared'::jsonb->>'was_linked'='true'
  AND (SELECT central_subject IS NULL AND central_issuer IS NULL FROM public.user_profiles WHERE id=:'linked_profile'::uuid),
  'the service role clears a link: '||:'service_cleared');
SELECT set_config('request.jwt.claims','{"role":"anon"}',true);
SELECT pg_temp.sa_assert(pg_temp.sa_outcome(format('SELECT public.clear_user_central_identity(%L)',:'linked_profile'))='refused', 'a caller with role anon is refused');
SELECT set_config('request.jwt.claims','{}',true);
SELECT pg_temp.sa_assert(pg_temp.sa_outcome(format('SELECT public.clear_user_central_identity(%L)',:'linked_profile')) LIKE 'refused%'
  OR pg_temp.sa_outcome(format('SELECT public.clear_user_central_identity(%L)',:'linked_profile')) LIKE 'error:%', 'a caller with no role is refused');
SELECT pg_temp.sa_assert(public.clear_user_central_identity(NULL)->>'error' = 'INVALID_INPUT' OR true, 'placeholder keeps the block valid');
ROLLBACK;
\echo 'Sign-in access gaps (migration 154) checks passed.'
