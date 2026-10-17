-- Migration 96 (TW-BE-017): a refused central exchange writes nothing to the profile. A profile that is rejected, disabled
-- or deactivated, found by its central identity with the token's own number, is answered account_unavailable and its row,
-- its tuple version and the audit log stay as they were; an approved or pending profile still gets the verified mark and
-- its session or enrollment token; a profile created by the call is not written twice; the SMS path (operator_verify_otp)
-- keeps the same order. Fictional data; runs only in migrations.sh's disposable, network-disabled database; every
-- fixture row rolls back.
\set ON_ERROR_STOP on
BEGIN;
CREATE FUNCTION pg_temp.cr_assert(ok boolean, label text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF NOT COALESCE(ok,false) THEN RAISE EXCEPTION 'central refusal: %',label; END IF; END $$;
CREATE FUNCTION pg_temp.cr_exchange(subject text, phone text, jti text) RETURNS jsonb LANGUAGE sql AS $$
  SELECT public.operator_central_exchange('https://login.association.example.test', subject, phone, jti,
    now()+interval '5 minutes', NULL, NULL, NULL, NULL) $$;
CREATE FUNCTION pg_temp.cr_code(phone text) RETURNS text LANGUAGE plpgsql AS $$
DECLARE challenge jsonb;
BEGIN
  UPDATE public.otp_verifications SET created_at=created_at-interval '61 seconds' WHERE phone_number=phone;
  challenge := public.operator_prepare_otp(phone);
  PERFORM pg_temp.cr_assert(challenge->>'success'='true','an SMS code is prepared for '||phone||': '||challenge::text);
  PERFORM public.operator_finish_otp((challenge#>>'{data,request_id}')::uuid,true,'mock-provider-only');
  RETURN challenge#>>'{data,otp_code}';
END $$;
-- Everything that a write would change: the whole row, its tuple version (an UPDATE in this transaction still moves ctid,
-- though now() and xmin do not move inside it) and the number of audit rows of the table.
CREATE FUNCTION pg_temp.cr_snap(phone text) RETURNS text LANGUAGE sql AS $$
  SELECT COALESCE((SELECT to_jsonb(p)::text||' ctid='||p.ctid::text FROM public.user_profiles p WHERE p.mobile=phone),'(no row)')
    ||' audit='||(SELECT count(*) FROM public.audit_log WHERE table_name='user_profiles') $$;

-- Claims of a fresh session for a profile, as PostgREST would present them.
CREATE FUNCTION pg_temp.cr_claims(phone text) RETURNS text LANGUAGE plpgsql AS $$
DECLARE account uuid; session uuid;
BEGIN
  SELECT auth_user_id INTO STRICT account FROM public.user_profiles WHERE mobile=phone;
  INSERT INTO warehouse_security.refresh_sessions(user_id,token_hash,expires_at)
    VALUES (account,encode(extensions.gen_random_bytes(32),'hex'),now()+interval '1 hour') RETURNING id INTO session;
  RETURN jsonb_build_object('role','authenticated','sub',account,'session_id',session)::text;
END $$;

INSERT INTO warehouse_security.auth_config(key,value) VALUES
 ('jwt_secret','isolated-test-secret-not-for-any-deployment-12345'),
 ('auth_mode','operator'),('demo_auth_enabled','false'),
 ('central_issuer','https://login.association.example.test')
 ON CONFLICT(key) DO UPDATE SET value=excluded.value;
UPDATE public.sms_config SET provider='msg91',production_mode=true,msg91_auth_key='isolated-test-key',
 msg91_template_id='000000000000000000000001',msg91_pe_id='0000000000000000001',msg91_sender_id='CITEST'
 WHERE id=(SELECT id FROM public.sms_config ORDER BY id DESC LIMIT 1);
SELECT warehouse_security.bootstrap_first_admin('9000000501','Refusal Administrator') AS admin_user \gset
-- All of them are linked to a central identity already, are not marked verified, and have the token's own number.
INSERT INTO public.user_profiles(auth_user_id,mobile,name,role,active,enrollment_status,central_issuer,central_subject,mobile_verified,mobile_verified_at) VALUES
 (gen_random_uuid(),'919000000511','Refused Rejected','customer',false,'rejected','https://login.association.example.test','central-refusal-0511',false,NULL),
 (gen_random_uuid(),'919000000512','Refused Disabled','staff',true,'approved','https://login.association.example.test','central-refusal-0512',false,NULL),
 (gen_random_uuid(),'919000000513','Refused Inactive','staff',false,'approved','https://login.association.example.test','central-refusal-0513',false,NULL),
 (gen_random_uuid(),'919000000514','Allowed Approved','staff',true,'approved','https://login.association.example.test','central-refusal-0514',false,NULL),
 (gen_random_uuid(),'919000000515','Allowed Pending','customer',false,'pending','https://login.association.example.test','central-refusal-0515',false,NULL);
-- Found by the number only (not linked): rejected, and one for the SMS path.
INSERT INTO public.user_profiles(auth_user_id,mobile,name,role,active,enrollment_status,mobile_verified,mobile_verified_at) VALUES
 (gen_random_uuid(),'919000000516','Refused By Phone','customer',false,'rejected',false,NULL),
 (gen_random_uuid(),'919000000517','Refused By Code','customer',false,'rejected',false,NULL),
 (gen_random_uuid(),'919000000518','Allowed By Code','staff',true,'approved',false,NULL);
SELECT pg_temp.cr_claims('919000000501') AS admin_claims \gset
-- The administrator disables 919000000512 through the RPC, as the app does.
SELECT id AS disabled_profile FROM public.user_profiles WHERE mobile='919000000512' \gset
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.cr_assert(public.update_user_status(:'disabled_profile'::uuid,false)->>'success'='true','the administrator disables a linked profile');
RESET ROLE;
SELECT pg_temp.cr_assert((SELECT enrollment_status='disabled' AND NOT active FROM public.user_profiles WHERE id=:'disabled_profile'::uuid),'the profile is disabled');

-- ---------------------------------------------------------------------------
-- 1. Refused: account_unavailable and nothing written
-- ---------------------------------------------------------------------------
SELECT pg_temp.cr_snap('919000000511') AS before_rejected, pg_temp.cr_snap('919000000512') AS before_disabled,
       pg_temp.cr_snap('919000000513') AS before_inactive, pg_temp.cr_snap('919000000516') AS before_phone \gset
SELECT pg_temp.cr_exchange('central-refusal-0511','919000000511','token-refusal-00000511') AS answer_rejected \gset
SELECT pg_temp.cr_exchange('central-refusal-0512','919000000512','token-refusal-00000512') AS answer_disabled \gset
SELECT pg_temp.cr_exchange('central-refusal-0513','919000000513','token-refusal-00000513') AS answer_inactive \gset
SELECT pg_temp.cr_exchange('central-refusal-0516','919000000516','token-refusal-00000516') AS answer_phone \gset
SELECT pg_temp.cr_assert(:'answer_rejected'::jsonb='{"success":false,"code":"account_unavailable"}'::jsonb
  AND :'answer_disabled'::jsonb='{"success":false,"code":"account_unavailable"}'::jsonb
  AND :'answer_inactive'::jsonb='{"success":false,"code":"account_unavailable"}'::jsonb
  AND :'answer_phone'::jsonb='{"success":false,"code":"account_unavailable"}'::jsonb,
 'rejected, disabled, deactivated and number-only rejected profiles are answered account_unavailable');
SELECT pg_temp.cr_assert(pg_temp.cr_snap('919000000511')=:'before_rejected',
 'a rejected linked profile: row, tuple version and audit log unchanged: '||pg_temp.cr_snap('919000000511'));
SELECT pg_temp.cr_assert(pg_temp.cr_snap('919000000512')=:'before_disabled',
 'a profile disabled with update_user_status(false): row, tuple version and audit log unchanged: '||pg_temp.cr_snap('919000000512'));
SELECT pg_temp.cr_assert(pg_temp.cr_snap('919000000513')=:'before_inactive',
 'a deactivated linked profile: row, tuple version and audit log unchanged: '||pg_temp.cr_snap('919000000513'));
SELECT pg_temp.cr_assert(pg_temp.cr_snap('919000000516')=:'before_phone',
 'a rejected profile found by number only is not linked and not written (migration 81)');
SELECT pg_temp.cr_assert((SELECT bool_and(NOT mobile_verified AND mobile_verified_at IS NULL) FROM public.user_profiles
   WHERE mobile IN ('919000000511','919000000512','919000000513','919000000516')),
 'none of the refused profiles was marked verified');
SELECT pg_temp.cr_assert((SELECT count(*)=0 FROM warehouse_security.refresh_sessions s JOIN public.user_profiles p ON p.auth_user_id=s.user_id
   WHERE p.mobile IN ('919000000511','919000000512','919000000513','919000000516'))
 AND (SELECT count(*)=0 FROM warehouse_security.enrollment_tokens t JOIN public.user_profiles p ON p.auth_user_id=t.user_id
   WHERE p.mobile IN ('919000000511','919000000512','919000000513','919000000516')),
 'a refusal issues neither a session nor an enrollment token');
-- The single-use row stays: it is replay protection.
SELECT pg_temp.cr_assert(pg_temp.cr_exchange('central-refusal-0511','919000000511','token-refusal-00000511')='{"success":false,"code":"identity_token_used"}'::jsonb,
 'a refused token is still single-use');

-- ---------------------------------------------------------------------------
-- 2. Allowed: the verified mark, the session or the enrollment token
-- ---------------------------------------------------------------------------
SELECT pg_temp.cr_exchange('central-refusal-0514','919000000514','token-refusal-00000514') AS answer_approved \gset
SELECT pg_temp.cr_assert(:'answer_approved'::jsonb#>>'{data,action}'='login' AND :'answer_approved'::jsonb#>>'{data,session,access_token}' IS NOT NULL,
 'an approved linked profile signs in: '||left(:'answer_approved',200));
SELECT pg_temp.cr_assert((SELECT mobile_verified AND mobile_verified_at IS NOT NULL FROM public.user_profiles WHERE mobile='919000000514'),
 'an approved linked profile is marked verified');
SELECT pg_temp.cr_exchange('central-refusal-0515','919000000515','token-refusal-00000515') AS answer_pending \gset
SELECT pg_temp.cr_assert(:'answer_pending'::jsonb#>>'{data,action}'='pending' AND :'answer_pending'::jsonb#>>'{data,enrollment_token}' IS NOT NULL
 AND (SELECT mobile_verified AND mobile_verified_at IS NOT NULL FROM public.user_profiles WHERE mobile='919000000515'),
 'a pending linked profile gets its enrollment token and is marked verified: '||left(:'answer_pending',200));
-- A person new to the facility: created verified and pending, written once.
SELECT count(*) AS audit_before_new FROM public.audit_log WHERE table_name='user_profiles' \gset
SELECT pg_temp.cr_exchange('central-refusal-0519','919000000519','token-refusal-00000519') AS answer_new \gset
SELECT pg_temp.cr_assert(:'answer_new'::jsonb#>>'{data,action}'='pending'
 AND (SELECT mobile_verified AND mobile_verified_at IS NOT NULL AND central_subject='central-refusal-0519' FROM public.user_profiles WHERE mobile='919000000519'),
 'a new person files a pending request, created verified');
SELECT pg_temp.cr_assert((SELECT count(*) FROM public.audit_log WHERE table_name='user_profiles')=:audit_before_new+1,
 'the new profile is written once (one audit row, no second update): '||(SELECT count(*) FROM public.audit_log WHERE table_name='user_profiles')||' vs '||:audit_before_new);
-- A profile found by number only is still linked and marked once approved (migration 81).
INSERT INTO public.user_profiles(auth_user_id,mobile,name,role,active,enrollment_status,mobile_verified,mobile_verified_at)
 VALUES (gen_random_uuid(),'919000000520','Allowed By Phone','staff',true,'approved',false,NULL);
SELECT pg_temp.cr_exchange('central-refusal-0520','919000000520','token-refusal-00000520') AS answer_link \gset
SELECT pg_temp.cr_assert(:'answer_link'::jsonb#>>'{data,action}'='login'
 AND (SELECT mobile_verified AND central_subject='central-refusal-0520' FROM public.user_profiles WHERE mobile='919000000520'),
 'a profile found by number is linked and marked when approved');

-- ---------------------------------------------------------------------------
-- 3. The SMS path answers alike: a refusal after a correct code writes nothing to the profile
-- ---------------------------------------------------------------------------
SELECT pg_temp.cr_code('919000000517') AS refused_code \gset
SELECT pg_temp.cr_snap('919000000517') AS before_code \gset
SELECT public.operator_verify_otp('919000000517',:'refused_code') AS answer_code \gset
SELECT pg_temp.cr_assert(:'answer_code'::jsonb='{"success":false,"code":"account_unavailable"}'::jsonb,'operator_verify_otp: a rejected profile is account_unavailable: '||:'answer_code');
SELECT pg_temp.cr_assert(pg_temp.cr_snap('919000000517')=:'before_code','operator_verify_otp: a refused profile is not written: '||pg_temp.cr_snap('919000000517'));
SELECT pg_temp.cr_code('919000000518') AS allowed_code \gset
SELECT public.operator_verify_otp('919000000518',:'allowed_code') AS answer_allowed \gset
SELECT pg_temp.cr_assert(:'answer_allowed'::jsonb#>>'{data,action}'='login'
 AND (SELECT mobile_verified AND mobile_verified_at IS NOT NULL FROM public.user_profiles WHERE mobile='919000000518'),
 'operator_verify_otp: an approved profile still signs in and is marked verified');
SELECT pg_temp.cr_code('919000000521') AS new_code \gset
SELECT public.operator_verify_otp('919000000521',:'new_code') AS answer_sms_new \gset
SELECT pg_temp.cr_assert(:'answer_sms_new'::jsonb#>>'{data,action}'='pending'
 AND (SELECT mobile_verified FROM public.user_profiles WHERE mobile='919000000521'),
 'operator_verify_otp: a new person is created verified and pending');

-- ---------------------------------------------------------------------------
-- 4. The function kept its owner, options and grants
-- ---------------------------------------------------------------------------
SELECT pg_temp.cr_assert((SELECT bool_and(prosecdef AND proconfig @> ARRAY['search_path=pg_catalog, public, extensions'])
   FROM pg_proc WHERE oid IN ('public.operator_central_exchange(text,text,text,text,timestamptz,text,text,inet,text)'::regprocedure,
                              'public.operator_verify_otp(text,text,text,text,inet)'::regprocedure))
 AND has_function_privilege('service_role','public.operator_central_exchange(text,text,text,text,timestamptz,text,text,inet,text)','EXECUTE')
 AND NOT has_function_privilege('authenticated','public.operator_central_exchange(text,text,text,text,timestamptz,text,text,inet,text)','EXECUTE')
 AND NOT has_function_privilege('anon','public.operator_central_exchange(text,text,text,text,timestamptz,text,text,inet,text)','EXECUTE'),
 'the two functions keep SECURITY DEFINER, search_path and grants');
ROLLBACK;
