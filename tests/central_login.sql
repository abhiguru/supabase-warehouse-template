-- Migrations 49 and 81: central login, facility side. The exchange RPC, the single
-- use of a token, linking by the token alone and the facility's own optional code (migration 81),
-- conflicts, service accounts, the administrator's unlink, and who may call what. Fictional data; runs only in migrations.sh's disposable,
-- network-disabled database; every fixture row rolls back.
\set ON_ERROR_STOP on
BEGIN;
CREATE FUNCTION pg_temp.cl_assert(ok boolean, label text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF NOT COALESCE(ok,false) THEN RAISE EXCEPTION 'central login: %',label; END IF; END $$;
-- One exchange as the edge function calls it, with a token that expires in
-- five minutes. `jti` must be new for every call that is not a replay test.
CREATE FUNCTION pg_temp.cl_exchange(subject text, phone text, jti text, person text DEFAULT NULL, source inet DEFAULT NULL,
  issuer text DEFAULT 'https://login.association.example.test', otp text DEFAULT NULL) RETURNS jsonb LANGUAGE sql AS $$
  SELECT public.operator_central_exchange(issuer, subject, phone, jti, now()+interval '5 minutes', person, NULL, source, otp) $$;
-- A code this facility "sent" to a phone by SMS (the provider is mocked), as
-- operator-otp/request prepares it. Earlier codes are aged past the resend wait.
CREATE FUNCTION pg_temp.cl_code(phone text) RETURNS text LANGUAGE plpgsql AS $$
DECLARE challenge jsonb;
BEGIN
  UPDATE public.otp_verifications SET created_at=created_at-interval '61 seconds' WHERE phone_number=phone;
  challenge := public.operator_prepare_otp(phone);
  PERFORM pg_temp.cl_assert(challenge->>'success'='true','an SMS code is prepared for '||phone||': '||challenge::text);
  PERFORM public.operator_finish_otp((challenge#>>'{data,request_id}')::uuid,true,'mock-provider-only');
  RETURN challenge#>>'{data,otp_code}';
END $$;
-- Claims of a fresh session for a profile, as PostgREST would present them.
CREATE FUNCTION pg_temp.cl_claims(phone text) RETURNS text LANGUAGE plpgsql AS $$
DECLARE account uuid; session uuid;
BEGIN
  SELECT auth_user_id INTO STRICT account FROM public.user_profiles WHERE mobile=phone;
  INSERT INTO warehouse_security.refresh_sessions(user_id,token_hash,expires_at)
    VALUES (account,encode(extensions.gen_random_bytes(32),'hex'),now()+interval '1 hour') RETURNING id INTO session;
  RETURN jsonb_build_object('role','authenticated','sub',account,'session_id',session)::text;
END $$;
-- An exchange and the rows it changed are never read in one statement: a
-- statement does not see what a function it calls has written. The answer is
-- kept with \gset and the tables are checked in the next statement.
-- 'refused' for a 42501, else the answer or the error.
CREATE FUNCTION pg_temp.cl_outcome(statement text) RETURNS text LANGUAGE plpgsql AS $$
DECLARE answer jsonb;
BEGIN
  BEGIN EXECUTE statement INTO answer;
  EXCEPTION WHEN insufficient_privilege THEN RETURN 'refused';
    WHEN OTHERS THEN RETURN 'error: '||SQLSTATE||' '||SQLERRM; END;
  RETURN answer::text;
END $$;
CREATE FUNCTION pg_temp.cl_sessions(phone text) RETURNS bigint LANGUAGE sql AS $$
  SELECT count(*) FROM warehouse_security.refresh_sessions s JOIN public.user_profiles p ON p.auth_user_id=s.user_id WHERE p.mobile=phone $$;

INSERT INTO warehouse_security.auth_config(key,value) VALUES
 ('jwt_secret','isolated-test-secret-not-for-any-deployment-12345'),
 ('auth_mode','operator'),('demo_auth_enabled','false')
 ON CONFLICT(key) DO UPDATE SET value=excluded.value;
UPDATE public.sms_config SET provider='msg91',production_mode=true,msg91_auth_key='isolated-test-key',
 msg91_template_id='000000000000000000000001',msg91_pe_id='0000000000000000001',msg91_sender_id='CITEST'
 WHERE id=(SELECT id FROM public.sms_config ORDER BY id DESC LIMIT 1);
SELECT warehouse_security.bootstrap_first_admin('9000000201','Central Administrator') AS admin_user \gset
INSERT INTO public.user_profiles(auth_user_id,mobile,name,role,active,enrollment_status) VALUES
 (gen_random_uuid(),'919000000202','Central Supervisor','supervisor',true,'approved'),
 (gen_random_uuid(),'919000000203','Central Staff','staff',true,'approved'),
 (gen_random_uuid(),'919000000204','Central Customer','customer',true,'approved'),
 -- enrolled with an SMS code before central sign-in existed
 (gen_random_uuid(),'919000000103','Earlier Staff','staff',true,'approved'),
 (gen_random_uuid(),'919000000105','Earlier Rejected','customer',false,'rejected'),
 (gen_random_uuid(),'919000000106','Earlier Disabled','staff',false,'disabled'),
 (gen_random_uuid(),'919000000107','Earlier Pending','customer',false,'pending'),
 -- a machine account (migration 78), not linked, and another one that is linked already
 (gen_random_uuid(),'919000000108','Earlier Service','staff',true,'approved'),
 -- an approved person for the cases where the facility asks for its own code (migration 81)
 (gen_random_uuid(),'919000000109','Local Code Staff','staff',true,'approved');
INSERT INTO public.user_profiles(auth_user_id,mobile,name,role,active,enrollment_status,central_issuer,central_subject)
 VALUES (gen_random_uuid(),'919000000110','Linked Service','staff',true,'approved','https://login.association.example.test','central-user-0110');
UPDATE public.user_profiles SET is_service_account=true WHERE mobile IN ('919000000108','919000000110');
INSERT INTO public.customers(name,mobile) VALUES ('Central Customer Account','9000000205') RETURNING id AS customer_account \gset
SELECT pg_temp.cl_claims('919000000201') AS admin_claims \gset
SELECT pg_temp.cl_claims('919000000202') AS supervisor_claims \gset
SELECT pg_temp.cl_claims('919000000203') AS staff_claims \gset
SELECT pg_temp.cl_claims('919000000204') AS customer_claims \gset
SELECT id AS earlier_profile FROM public.user_profiles WHERE mobile='919000000103' \gset
SELECT count(*) AS profiles_start FROM public.user_profiles \gset

-- ---------------------------------------------------------------------------
-- Who may call the exchange
-- ---------------------------------------------------------------------------
SELECT pg_temp.cl_assert(NOT has_function_privilege('anon','public.operator_central_exchange(text,text,text,text,timestamptz,text,text,inet,text)','EXECUTE'),
 'anon cannot execute the exchange');
SELECT pg_temp.cl_assert(NOT has_function_privilege('authenticated','public.operator_central_exchange(text,text,text,text,timestamptz,text,text,inet,text)','EXECUTE'),
 'a signed-in user cannot execute the exchange');
SELECT pg_temp.cl_assert(has_function_privilege('service_role','public.operator_central_exchange(text,text,text,text,timestamptz,text,text,inet,text)','EXECUTE'),
 'the edge function''s service role executes the exchange');
SELECT pg_temp.cl_assert((SELECT prosecdef AND proconfig @> ARRAY['search_path=pg_catalog, public, extensions'] FROM pg_proc
  WHERE oid='public.operator_central_exchange(text,text,text,text,timestamptz,text,text,inet,text)'::regprocedure),
 'the exchange is SECURITY DEFINER with a fixed search_path');
INSERT INTO warehouse_security.auth_config(key,value) VALUES ('central_issuer','https://login.association.example.test');
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.cl_assert(pg_temp.cl_outcome($$SELECT public.operator_central_exchange('https://login.association.example.test','central-user-0900','919000000900','token-id-0000000000000900',now()+interval '5 minutes')$$)='refused',
 'even an administrator''s session cannot call the exchange');
RESET ROLE;
SET LOCAL ROLE anon;
SELECT pg_temp.cl_assert(pg_temp.cl_outcome($$SELECT public.operator_central_exchange('https://login.association.example.test','central-user-0900','919000000900','token-id-0000000000000900',now()+interval '5 minutes')$$)='refused',
 'the anon key cannot call the exchange');
RESET ROLE;
SELECT pg_temp.cl_assert(NOT has_table_privilege('service_role','warehouse_security.central_token_use','SELECT')
 AND NOT has_table_privilege('authenticated','warehouse_security.central_token_use','SELECT'),'no API role reads the token-use table');
DELETE FROM warehouse_security.auth_config WHERE key='central_issuer';

-- ---------------------------------------------------------------------------
-- Not configured, wrong issuer, malformed arguments
-- ---------------------------------------------------------------------------
SELECT pg_temp.cl_assert(pg_temp.cl_exchange('central-user-0001','919000000101','token-id-0000000000000001')
 = '{"success":false,"code":"central_unavailable"}'::jsonb,'no trusted issuer: central sign-in is unavailable');
INSERT INTO warehouse_security.auth_config(key,value) VALUES ('central_issuer','');
SELECT pg_temp.cl_assert(pg_temp.cl_exchange('central-user-0001','919000000101','token-id-0000000000000001',NULL,NULL,'')->>'code'='central_unavailable',
 'an empty trusted issuer matches nothing, not even an empty issuer');
UPDATE warehouse_security.auth_config SET value='https://login.association.example.test' WHERE key='central_issuer';
UPDATE warehouse_security.auth_config SET value='demo' WHERE key='auth_mode';
SELECT pg_temp.cl_assert(pg_temp.cl_exchange('central-user-0001','919000000101','token-id-0000000000000001')->>'code'='central_unavailable',
 'outside operator mode central sign-in is unavailable');
UPDATE warehouse_security.auth_config SET value='operator' WHERE key='auth_mode';
SELECT pg_temp.cl_assert(pg_temp.cl_exchange('central-user-0001','919000000101','token-id-0000000000000001',NULL,NULL,'https://other-issuer.example.test')
 = '{"success":false,"code":"central_unavailable"}'::jsonb,'another issuer is not trusted');
SELECT pg_temp.cl_assert(pg_temp.cl_exchange('central-user-0001','919000000101','token-id-0000000000000001',NULL,NULL,'https://login.association.example.test/')->>'code'='central_unavailable',
 'the issuer is compared as an exact string');
SELECT pg_temp.cl_assert(pg_temp.cl_exchange('central-user-0001','919000000101','token-id-0000000000000001',NULL,NULL,NULL)->>'code'='central_unavailable',
 'a missing issuer is not trusted');
SELECT pg_temp.cl_assert(bool_and(answer = '{"success":false,"code":"invalid_identity_token"}'::jsonb),'malformed arguments are refused: '||string_agg(answer::text,' '))
FROM (VALUES
  (pg_temp.cl_exchange('has spaces','919000000101','token-id-0000000000000001')),
  (pg_temp.cl_exchange('','919000000101','token-id-0000000000000001')),
  (pg_temp.cl_exchange(repeat('a',65),'919000000101','token-id-0000000000000001')),
  (pg_temp.cl_exchange(NULL,'919000000101','token-id-0000000000000001')),
  (pg_temp.cl_exchange('central-user-0001','9000000101','token-id-0000000000000001')),
  (pg_temp.cl_exchange('central-user-0001','+919000000101','token-id-0000000000000001')),
  (pg_temp.cl_exchange('central-user-0001','929000000101','token-id-0000000000000001')),
  (pg_temp.cl_exchange('central-user-0001',NULL,'token-id-0000000000000001')),
  (pg_temp.cl_exchange('central-user-0001','919000000101','short')),
  (pg_temp.cl_exchange('central-user-0001','919000000101','token id 0000000000000001')),
  (pg_temp.cl_exchange('central-user-0001','919000000101',repeat('a',129))),
  (pg_temp.cl_exchange('central-user-0001','919000000101',NULL)),
  (public.operator_central_exchange('https://login.association.example.test','central-user-0001','919000000101','token-id-0000000000000001',now()-interval '1 second')),
  (public.operator_central_exchange('https://login.association.example.test','central-user-0001','919000000101','token-id-0000000000000001',now()+interval '12 minutes')),
  (public.operator_central_exchange('https://login.association.example.test','central-user-0001','919000000101','token-id-0000000000000001',NULL))
) AS attempts(answer);
SELECT pg_temp.cl_assert((SELECT count(*)=0 FROM warehouse_security.central_token_use)
 AND (SELECT count(*) FROM public.user_profiles)=:'profiles_start'::bigint
 AND (SELECT count(*)=0 FROM warehouse_security.enrollment_log),
 'a refused call records no token, creates no profile and counts no access request');

-- ---------------------------------------------------------------------------
-- An unknown person: one pending access request
-- ---------------------------------------------------------------------------
SELECT pg_temp.cl_exchange('central-user-0001','919000000101','token-id-0000000000000001','  Asha   Central ') AS first_answer \gset
SELECT pg_temp.cl_assert(:'first_answer'::jsonb->>'success'='true' AND :'first_answer'::jsonb#>>'{data,action}'='pending'
 AND :'first_answer'::jsonb#>>'{data,enrollment_token}' ~ '^[0-9a-f]{64}$'
 AND (:'first_answer'::jsonb#>>'{data,expires_at}')::timestamptz > now()+interval '6 days'
 AND :'first_answer'::jsonb#>>'{data,user,name}'='Asha Central' AND :'first_answer'::jsonb#>>'{data,user,mobile}'='919000000101'
 AND :'first_answer'::jsonb#>>'{data,user,enrollment_status}'='pending' AND :'first_answer'::jsonb#>>'{data,user,active}'='false'
 AND NOT :'first_answer'::jsonb->'data' ? 'session',
 'first exchange of an unknown person answers pending: '||:'first_answer');
SELECT id AS person_profile FROM public.user_profiles WHERE mobile='919000000101' \gset
SELECT pg_temp.cl_assert((SELECT count(*) FROM public.user_profiles)=:'profiles_start'::bigint+1
 AND (SELECT central_issuer='https://login.association.example.test' AND central_subject='central-user-0001'
        AND role='customer' AND NOT active AND enrollment_status='pending' AND mobile_verified AND mobile_verified_at IS NOT NULL
        AND name='Asha Central' AND display_name='Asha Central'
      FROM public.user_profiles WHERE id=:'person_profile'::uuid)
 AND (SELECT count(*)=1 FROM warehouse_security.enrollment_log)
 AND pg_temp.cl_sessions('919000000101')=0,
 'exactly one pending customer profile carries the central identity, and no session exists');
SELECT pg_temp.cl_assert(public.operator_enrollment_status(:'first_answer'::jsonb#>>'{data,enrollment_token}')#>>'{data,status}'='pending',
 'the enrollment token of the answer reads the request''s status');
SELECT pg_temp.cl_assert((SELECT count(*)=1 AND bool_and(token_hash=encode(extensions.digest('https://login.association.example.test token-id-0000000000000001','sha256'),'hex')
   AND expires_at > now()+interval '4 minutes' AND expires_at <= now()+interval '5 minutes') FROM warehouse_security.central_token_use),
 'the token use is stored as the SHA-256 of issuer, a space and the token id, until the token expires');

-- A second token for the same person: pending again, nothing new.
SELECT pg_temp.cl_exchange('central-user-0001','919000000101','token-id-0000000000000002','Another Name') AS second_answer \gset
SELECT pg_temp.cl_assert(:'second_answer'::jsonb#>>'{data,action}'='pending' AND :'second_answer'::jsonb#>>'{data,user,id}'=:'person_profile'
 AND :'second_answer'::jsonb#>>'{data,user,name}'='Asha Central'
 AND :'second_answer'::jsonb#>>'{data,enrollment_token}' <> :'first_answer'::jsonb#>>'{data,enrollment_token}',
 'a second token for the same subject answers pending for the same profile: '||:'second_answer');
SELECT pg_temp.cl_assert((SELECT count(*) FROM public.user_profiles)=:'profiles_start'::bigint+1
 AND (SELECT count(*)=1 FROM warehouse_security.enrollment_log)
 AND (SELECT count(*)=1 FROM warehouse_security.enrollment_tokens t JOIN public.user_profiles p ON p.auth_user_id=t.user_id WHERE p.id=:'person_profile'::uuid),
 'the second token creates no profile, counts no new request and leaves one enrollment token');
SELECT pg_temp.cl_assert(public.operator_enrollment_status(:'first_answer'::jsonb#>>'{data,enrollment_token}')->>'code'='invalid_token'
 AND public.operator_enrollment_status(:'second_answer'::jsonb#>>'{data,enrollment_token}')#>>'{data,status}'='pending',
 'the fresh enrollment token replaces the earlier one');

-- Token reuse.
SELECT pg_temp.cl_assert(pg_temp.cl_exchange('central-user-0001','919000000101','token-id-0000000000000002')
 = '{"success":false,"code":"identity_token_used"}'::jsonb,'a token id is accepted once');
SELECT pg_temp.cl_exchange('central-user-0777','919000000777','token-id-0000000000000002') AS replayed \gset
SELECT pg_temp.cl_assert(:'replayed'::jsonb->>'code'='identity_token_used'
 AND NOT EXISTS (SELECT 1 FROM public.user_profiles WHERE mobile='919000000777'),
 'a used token id is refused whatever identity comes with it');
SELECT pg_temp.cl_assert(public.operator_enrollment_status(:'second_answer'::jsonb#>>'{data,enrollment_token}')#>>'{data,status}'='pending',
 'a replay does not disturb the pending request');

-- A name that is not a plain name falls back to the default, as for an SMS sign-in.
SELECT pg_temp.cl_assert(pg_temp.cl_exchange('central-user-0002','919000000102','token-id-0000000000000003','<b>Mallory</b>')#>>'{data,user,name}'='New customer',
 'markup in the name gives the default name');

-- ---------------------------------------------------------------------------
-- After approval: a session
-- ---------------------------------------------------------------------------
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.cl_assert(public.operator_review_enrollment(:'person_profile'::uuid,'approved',ARRAY[:'customer_account'::uuid])->>'success'='true',
 'the administrator approves the access request with the existing review');
RESET ROLE;
SELECT pg_temp.cl_exchange('central-user-0001','919000000101','token-id-0000000000000004') AS login_answer \gset
SELECT pg_temp.cl_assert(:'login_answer'::jsonb->>'success'='true' AND :'login_answer'::jsonb#>>'{data,action}'='login'
 AND :'login_answer'::jsonb#>>'{data,user,id}'=:'person_profile' AND :'login_answer'::jsonb#>>'{data,user,role}'='customer'
 AND :'login_answer'::jsonb#>>'{data,user,active}'='true'
 AND length(:'login_answer'::jsonb#>>'{data,session,access_token}')>100
 AND :'login_answer'::jsonb#>>'{data,session,refresh_token}' ~ '^[0-9a-f]{64}$'
 AND :'login_answer'::jsonb#>>'{data,session,token_type}'='bearer',
 'an approved person receives the facility''s own session: '||left(:'login_answer',300));
SELECT pg_temp.cl_assert(pg_temp.cl_sessions('919000000101')=1,'one session was issued');
SELECT pg_temp.cl_assert(public.refresh_jwt_token(:'login_answer'::jsonb#>>'{data,session,refresh_token}')->>'refresh_token' ~ '^[0-9a-f]{64}$',
 'the session refreshes like one from an SMS sign-in');
SELECT jsonb_build_object('role','authenticated','sub',p.auth_user_id,'session_id',s.id)::text AS person_claims
 FROM public.user_profiles p JOIN warehouse_security.refresh_sessions s ON s.user_id=p.auth_user_id WHERE p.id=:'person_profile'::uuid \gset
SELECT set_config('request.jwt.claims',:'person_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.cl_assert(warehouse_security.active_role()='customer','the session carries the role the facility approved');
RESET ROLE;

-- ---------------------------------------------------------------------------
-- Migration 81: the association's token opens an existing person profile
-- (the facility's own code is off here; the ON cases are further down)
-- ---------------------------------------------------------------------------
SELECT count(*) AS profiles_before_link FROM public.user_profiles \gset
SELECT (SELECT count(*) FROM warehouse_security.enrollment_log) AS requests_before_link \gset
-- The token alone links an existing, approved profile found by its verified mobile and signs it in.
SELECT pg_temp.cl_exchange('central-user-0003','919000000103','token-id-0000000000000005','Ignored Name') AS linked_answer \gset
SELECT pg_temp.cl_assert(:'linked_answer'::jsonb->>'success'='true' AND :'linked_answer'::jsonb#>>'{data,action}'='login'
 AND :'linked_answer'::jsonb#>>'{data,user,id}'=:'earlier_profile'
 AND :'linked_answer'::jsonb#>>'{data,user,role}'='staff' AND :'linked_answer'::jsonb#>>'{data,user,name}'='Earlier Staff'
 AND :'linked_answer'::jsonb#>>'{data,session,refresh_token}' ~ '^[0-9a-f]{64}$',
 'a token for the phone of an existing, unlinked profile signs it in without any code: '||left(:'linked_answer',300));
SELECT pg_temp.cl_assert((SELECT central_issuer='https://login.association.example.test' AND central_subject='central-user-0003'
     AND mobile_verified AND mobile_verified_at IS NOT NULL AND name='Earlier Staff' AND role='staff' AND active AND enrollment_status='approved'
   FROM public.user_profiles WHERE id=:'earlier_profile'::uuid)
 AND (SELECT count(*) FROM public.user_profiles)=:'profiles_before_link'::bigint
 AND (SELECT count(*) FROM warehouse_security.enrollment_log)=:'requests_before_link'::bigint
 AND pg_temp.cl_sessions('919000000103')=1,
 'the profile is linked and verified, exactly one session exists, nothing else changes, no profile or request is added');
SELECT pg_temp.cl_assert(:'linked_answer'::jsonb#>>'{data,user,central_issuer}'='https://login.association.example.test'
 AND :'linked_answer'::jsonb#>>'{data,user,central_subject}'='central-user-0003'
 AND :'linked_answer'::jsonb#>'{data,user}'=(SELECT to_jsonb(p) FROM public.user_profiles p WHERE p.id=:'earlier_profile'::uuid),
 'the answer names the link it made: its user is the stored, linked profile: '||left(:'linked_answer',600));
SELECT pg_temp.cl_assert(pg_temp.cl_exchange('central-user-0003','919000000103','token-id-0000000000000005')->>'code'='identity_token_used',
 'the token is spent like any other');
-- A code that comes along is not needed and not touched while the facility's own code is off.
SELECT pg_temp.cl_code('919000000103') AS unused_code \gset
SELECT pg_temp.cl_assert(pg_temp.cl_exchange('central-user-0003','919000000103','token-id-0000000000000064',NULL,NULL,
   'https://login.association.example.test','000000')#>>'{data,action}'='login'
 AND EXISTS (SELECT 1 FROM public.otp_verifications WHERE phone_number='919000000103' AND NOT verified AND attempts+source_attempts=0 AND expires_at>now()),
 'with the setting off a code sent along is ignored: no attempt is counted against the facility''s code');
DELETE FROM warehouse_security.refresh_sessions WHERE user_id=(SELECT auth_user_id FROM public.user_profiles WHERE id=:'earlier_profile'::uuid)
 AND id <> (SELECT min(id::text)::uuid FROM warehouse_security.refresh_sessions WHERE user_id=(SELECT auth_user_id FROM public.user_profiles WHERE id=:'earlier_profile'::uuid));
-- An administrator's profile is reachable on the association's word too (the owner's decision of 2026-10-15).
SELECT pg_temp.cl_sessions('919000000201') AS admin_sessions \gset
SELECT pg_temp.cl_exchange('central-user-0666','919000000201','token-id-0000000000000666') AS admin_attempt \gset
SELECT pg_temp.cl_assert(:'admin_attempt'::jsonb#>>'{data,action}'='login' AND :'admin_attempt'::jsonb#>>'{data,user,role}'='admin'
 AND (SELECT central_subject='central-user-0666' AND role='admin' FROM public.user_profiles WHERE mobile='919000000201')
 AND pg_temp.cl_sessions('919000000201')=:'admin_sessions'::bigint+1,
 'with the setting off the administrator''s profile is linked and signed in by the token alone: '||left(:'admin_attempt',200));

-- Rejected and disabled profiles: refused, no session, the facility's decision untouched.
SELECT pg_temp.cl_exchange('central-user-0005','919000000105','token-id-0000000000000058') AS rejected_answer \gset
SELECT pg_temp.cl_exchange('central-user-0006','919000000106','token-id-0000000000000059') AS disabled_answer \gset
SELECT pg_temp.cl_assert(:'rejected_answer'::jsonb = '{"success":false,"code":"account_unavailable"}'::jsonb
 AND :'disabled_answer'::jsonb = '{"success":false,"code":"account_unavailable"}'::jsonb,
 'an unlinked rejected or disabled profile answers account_unavailable: '||:'rejected_answer'||' '||:'disabled_answer');
SELECT pg_temp.cl_assert((SELECT enrollment_status='rejected' AND NOT active AND central_issuer IS NULL AND central_subject IS NULL
     AND NOT mobile_verified AND mobile_verified_at IS NULL FROM public.user_profiles WHERE mobile='919000000105')
 AND (SELECT enrollment_status='disabled' AND NOT active AND central_issuer IS NULL AND central_subject IS NULL
     AND NOT mobile_verified AND mobile_verified_at IS NULL FROM public.user_profiles WHERE mobile='919000000106')
 AND NOT EXISTS (SELECT 1 FROM public.user_profiles WHERE central_subject IN ('central-user-0005','central-user-0006'))
 AND (SELECT count(*)=2 FROM warehouse_security.central_token_use WHERE token_hash IN (
      encode(extensions.digest('https://login.association.example.test token-id-0000000000000058','sha256'),'hex'),
      encode(extensions.digest('https://login.association.example.test token-id-0000000000000059','sha256'),'hex')))
 AND pg_temp.cl_sessions('919000000105')=0 AND pg_temp.cl_sessions('919000000106')=0
 AND NOT EXISTS (SELECT 1 FROM warehouse_security.enrollment_tokens t JOIN public.user_profiles p ON p.auth_user_id=t.user_id
   WHERE p.mobile IN ('919000000105','919000000106')),
 'a refused profile is not linked or marked verified, gets no session or enrollment token, keeps its status, and its token is spent');
-- A service account is never opened by the association's token, and is not linked.
SELECT pg_temp.cl_exchange('central-user-0008','919000000108','token-id-0000000000000065') AS service_answer \gset
SELECT pg_temp.cl_assert(:'service_answer'::jsonb = '{"success":false,"code":"account_unavailable"}'::jsonb
 AND (SELECT central_issuer IS NULL AND central_subject IS NULL AND NOT mobile_verified FROM public.user_profiles WHERE mobile='919000000108')
 AND NOT EXISTS (SELECT 1 FROM public.user_profiles WHERE central_subject='central-user-0008')
 AND pg_temp.cl_sessions('919000000108')=0,
 'a service account found by phone answers account_unavailable and is not linked: '||:'service_answer');
SELECT pg_temp.cl_exchange('central-user-0110','919000000110','token-id-0000000000000066') AS linked_service_answer \gset
SELECT pg_temp.cl_assert(:'linked_service_answer'::jsonb = '{"success":false,"code":"account_unavailable"}'::jsonb
 AND pg_temp.cl_sessions('919000000110')=0,
 'a service account found by its subject answers account_unavailable too: '||:'linked_service_answer');
-- A waiting request that was never linked: the token links it and the answer is pending, with the link named.
SELECT pg_temp.cl_exchange('central-user-0007','919000000107','token-id-0000000000000061') AS pending_link \gset
SELECT pg_temp.cl_assert(:'pending_link'::jsonb#>>'{data,action}'='pending' AND :'pending_link'::jsonb#>>'{data,enrollment_token}' ~ '^[0-9a-f]{64}$'
 AND (SELECT central_subject='central-user-0007' AND enrollment_status='pending' AND NOT active FROM public.user_profiles WHERE mobile='919000000107')
 AND pg_temp.cl_sessions('919000000107')=0,
 'a waiting request is linked by the token and stays pending: '||:'pending_link');
-- Every pending answer names the link (migration 64 did so for the link case; migration 81 for all) and has no other new key.
SELECT pg_temp.cl_assert(:'pending_link'::jsonb#>>'{data,user,central_issuer}'='https://login.association.example.test'
 AND :'pending_link'::jsonb#>>'{data,user,central_subject}'='central-user-0007'
 AND (SELECT array_agg(k ORDER BY k) FROM jsonb_object_keys(:'pending_link'::jsonb#>'{data,user}') AS k)
     = ARRAY['active','central_issuer','central_subject','display_name','enrollment_status','id','mobile','name','role'],
 'the pending answer names the link and keeps its short shape: '||:'pending_link');
SELECT pg_temp.cl_assert((SELECT count(*) FROM public.user_profiles)=:'profiles_before_link'::bigint
 AND (SELECT count(*) FROM warehouse_security.enrollment_log)=:'requests_before_link'::bigint,
 'none of this created a profile or counted a new access request');

-- Conflict: the phone's profile is linked to another subject. Nothing changes.
SELECT (SELECT count(*) FROM warehouse_security.enrollment_log) AS requests_before_conflict \gset
SELECT pg_temp.cl_assert(pg_temp.cl_exchange('central-user-0099','919000000103','token-id-0000000000000006')
 = '{"success":false,"code":"identity_conflict"}'::jsonb,'a phone linked to another central identity is a conflict');
SELECT pg_temp.cl_code('919000000103') AS conflict_code \gset
SELECT pg_temp.cl_exchange('central-user-0099','919000000103','token-id-0000000000000062',NULL,NULL,
  'https://login.association.example.test',:'conflict_code') AS conflict_with_code \gset
SELECT pg_temp.cl_assert(:'conflict_with_code'::jsonb = '{"success":false,"code":"identity_conflict"}'::jsonb
 AND EXISTS (SELECT 1 FROM public.otp_verifications WHERE phone_number='919000000103' AND NOT verified AND attempts+source_attempts=0 AND expires_at>now()),
 'a correct SMS code does not override a conflict, and the code is not even tried: '||:'conflict_with_code');
SELECT pg_temp.cl_assert((SELECT central_subject='central-user-0003' FROM public.user_profiles WHERE id=:'earlier_profile'::uuid)
 AND NOT EXISTS (SELECT 1 FROM public.user_profiles WHERE central_subject='central-user-0099')
 AND (SELECT count(*) FROM public.user_profiles)=:'profiles_before_link'::bigint
 AND (SELECT count(*) FROM warehouse_security.enrollment_log)=:'requests_before_conflict'::bigint
 AND pg_temp.cl_sessions('919000000103')=1,
 'a conflict links nothing, creates nothing and issues no session');
-- The same when the profile is linked under another issuer (an installation that changed its issuer).
UPDATE public.user_profiles SET central_issuer='https://earlier-issuer.example.test' WHERE id=:'earlier_profile'::uuid;
SELECT pg_temp.cl_exchange('central-user-0003','919000000103','token-id-0000000000000007') AS other_issuer \gset
SELECT pg_temp.cl_assert(:'other_issuer'::jsonb->>'code'='identity_conflict'
 AND (SELECT central_issuer='https://earlier-issuer.example.test' FROM public.user_profiles WHERE id=:'earlier_profile'::uuid),
 'a profile linked under another issuer is a conflict too');
UPDATE public.user_profiles SET central_issuer='https://login.association.example.test' WHERE id=:'earlier_profile'::uuid;

-- A subject match with another phone: the facility's number stays.
UPDATE public.user_profiles SET mobile_verified=false,mobile_verified_at=NULL WHERE id=:'earlier_profile'::uuid;
SELECT pg_temp.cl_exchange('central-user-0003','919000000199','token-id-0000000000000008') AS moved_answer \gset
SELECT pg_temp.cl_assert(:'moved_answer'::jsonb#>>'{data,action}'='login' AND :'moved_answer'::jsonb#>>'{data,user,id}'=:'earlier_profile'
 AND :'moved_answer'::jsonb#>>'{data,user,mobile}'='919000000103',
 'the profile found by subject is used although the token names another phone: '||left(:'moved_answer',300));
SELECT pg_temp.cl_assert((SELECT mobile='919000000103' AND NOT mobile_verified AND mobile_verified_at IS NULL FROM public.user_profiles WHERE id=:'earlier_profile'::uuid)
 AND NOT EXISTS (SELECT 1 FROM public.user_profiles WHERE mobile='919000000199')
 AND (SELECT count(*) FROM public.user_profiles)=:'profiles_before_link'::bigint,
 'the facility''s mobile is kept, is not marked verified by another number, and no profile is made for that number');
SELECT pg_temp.cl_exchange('central-user-0003','919000000103','token-id-0000000000000009') AS own_number \gset
SELECT pg_temp.cl_assert(:'own_number'::jsonb#>>'{data,action}'='login'
 AND (SELECT mobile_verified AND mobile_verified_at IS NOT NULL FROM public.user_profiles WHERE id=:'earlier_profile'::uuid),
 'a token that names the profile''s own number marks it verified');
-- The subject decides before the phone: 0001's number with 0003's subject signs in 0003.
SELECT pg_temp.cl_exchange('central-user-0003','919000000101','token-id-0000000000000010') AS subject_first \gset
SELECT pg_temp.cl_assert(:'subject_first'::jsonb#>>'{data,user,id}'=:'earlier_profile'
 AND (SELECT mobile='919000000101' FROM public.user_profiles WHERE id=:'person_profile'::uuid)
 AND (SELECT central_subject='central-user-0001' FROM public.user_profiles WHERE id=:'person_profile'::uuid),
 'the subject is looked up before the phone');

-- The table itself keeps an identity whole and unique.
SELECT pg_temp.cl_assert(pg_temp.cl_outcome(format($$UPDATE public.user_profiles SET central_subject=NULL WHERE id=%L RETURNING '{}'::jsonb$$,:'earlier_profile')) LIKE 'error: 23514 %',
 'issuer and subject are set together');
SELECT pg_temp.cl_assert(pg_temp.cl_outcome(format($$UPDATE public.user_profiles SET central_subject='central-user-0001' WHERE id=%L RETURNING '{}'::jsonb$$,:'earlier_profile')) LIKE 'error: 23505 %',
 'one central identity belongs to one profile');

-- ---------------------------------------------------------------------------
-- Rejected and disabled profiles
-- ---------------------------------------------------------------------------
SELECT id AS second_person FROM public.user_profiles WHERE mobile='919000000102' \gset
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.cl_assert(public.operator_review_enrollment(:'second_person'::uuid,'rejected')->>'success'='true','the administrator rejects a request');
SELECT pg_temp.cl_assert(public.update_user_status(:'earlier_profile'::uuid,false)->>'success'='true','the administrator disables a linked profile');
RESET ROLE;
SELECT pg_temp.cl_assert(pg_temp.cl_sessions('919000000103')=0,'disabling revokes the sessions a central sign-in issued');
SELECT COALESCE(string_agg(t.token_hash,',' ORDER BY t.token_hash),'') AS tokens_before_refusal FROM warehouse_security.enrollment_tokens t
 JOIN public.user_profiles p ON p.auth_user_id=t.user_id WHERE p.mobile IN ('919000000102','919000000103') \gset
SELECT pg_temp.cl_assert(pg_temp.cl_exchange('central-user-0002','919000000102','token-id-0000000000000011')
 = '{"success":false,"code":"account_unavailable"}'::jsonb,'a rejected person is refused');
SELECT pg_temp.cl_assert(pg_temp.cl_exchange('central-user-0003','919000000103','token-id-0000000000000012')
 = '{"success":false,"code":"account_unavailable"}'::jsonb,'a disabled person is refused');
SELECT pg_temp.cl_assert(pg_temp.cl_sessions('919000000103')=0 AND pg_temp.cl_sessions('919000000102')=0
 AND (SELECT COALESCE(string_agg(t.token_hash,',' ORDER BY t.token_hash),'') FROM warehouse_security.enrollment_tokens t
   JOIN public.user_profiles p ON p.auth_user_id=t.user_id WHERE p.mobile IN ('919000000102','919000000103'))=:'tokens_before_refusal',
 'a refused person gets neither a session nor an enrollment token');
SELECT pg_temp.cl_assert((SELECT enrollment_status='rejected' FROM public.user_profiles WHERE id=:'second_person'::uuid)
 AND (SELECT enrollment_status='disabled' AND NOT active FROM public.user_profiles WHERE id=:'earlier_profile'::uuid),
 'a refused exchange leaves the facility''s decision as it is');
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.cl_assert(public.update_user_status(:'earlier_profile'::uuid,true)->>'success'='true','the administrator gives access back');
RESET ROLE;
SELECT pg_temp.cl_assert(pg_temp.cl_exchange('central-user-0003','919000000103','token-id-0000000000000013')#>>'{data,action}'='login',
 'a reactivated person signs in centrally again');

-- ---------------------------------------------------------------------------
-- clear_user_central_identity
-- ---------------------------------------------------------------------------
SELECT pg_temp.cl_assert(NOT has_function_privilege('anon','public.clear_user_central_identity(uuid)','EXECUTE')
 AND NOT has_function_privilege('service_role','public.clear_user_central_identity(uuid)','EXECUTE')
 AND has_function_privilege('authenticated','public.clear_user_central_identity(uuid)','EXECUTE'),
 'unlinking is granted to signed-in users only');
SELECT pg_temp.cl_assert(pg_temp.cl_sessions('919000000103')=1,'the linked profile holds a session');
SELECT set_config('request.jwt.claims',:'supervisor_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.cl_assert(warehouse_security.active_role()='supervisor'
 AND pg_temp.cl_outcome(format('SELECT public.clear_user_central_identity(%L)',:'earlier_profile'))='refused','a supervisor is refused');
SELECT set_config('request.jwt.claims',:'staff_claims',true);
SELECT pg_temp.cl_assert(warehouse_security.active_role()='staff'
 AND pg_temp.cl_outcome(format('SELECT public.clear_user_central_identity(%L)',:'earlier_profile'))='refused','staff are refused');
SELECT set_config('request.jwt.claims',:'customer_claims',true);
SELECT pg_temp.cl_assert(warehouse_security.active_role()='customer'
 AND pg_temp.cl_outcome(format('SELECT public.clear_user_central_identity(%L)',:'earlier_profile'))='refused','a customer account is refused');
SELECT set_config('request.jwt.claims','{"role":"authenticated"}',true);
SELECT pg_temp.cl_assert(pg_temp.cl_outcome(format('SELECT public.clear_user_central_identity(%L)',:'earlier_profile'))='refused','a caller without a session is refused');
SELECT set_config('request.jwt.claims','{"role":"service_role"}',true);
RESET ROLE;
-- Even where the function were reachable with the service key, it is a signed-in administrator's action.
SELECT pg_temp.cl_assert(pg_temp.cl_outcome(format('SELECT public.clear_user_central_identity(%L)',:'earlier_profile'))='refused','the service key is refused');
SELECT pg_temp.cl_assert((SELECT central_subject='central-user-0003' FROM public.user_profiles WHERE id=:'earlier_profile'::uuid)
 AND pg_temp.cl_sessions('919000000103')=1,'a refused unlink changes nothing');

SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.cl_assert(public.clear_user_central_identity(NULL)->>'error'='INVALID_INPUT','an id is required');
SELECT pg_temp.cl_assert(public.clear_user_central_identity(gen_random_uuid())->>'error'='NOT_FOUND','an unknown id is reported');
SELECT public.clear_user_central_identity(:'earlier_profile'::uuid) AS cleared \gset
RESET ROLE;
SELECT pg_temp.cl_assert(:'cleared'::jsonb->>'success'='true' AND :'cleared'::jsonb->>'was_linked'='true'
 AND :'cleared'::jsonb->>'user_id'=:'earlier_profile','the administrator unlinks a profile: '||:'cleared');
SELECT pg_temp.cl_assert((SELECT central_issuer IS NULL AND central_subject IS NULL AND active AND enrollment_status='approved'
     AND role='staff' AND mobile='919000000103' FROM public.user_profiles WHERE id=:'earlier_profile'::uuid)
 AND pg_temp.cl_sessions('919000000103')=0,
 'the identity is cleared and the sessions are gone; active, role and number are unchanged');
SELECT pg_temp.cl_assert(pg_temp.cl_sessions('919000000201')>=1,'the administrator''s own session is untouched');
-- This is how a conflict is resolved: the identity that was refused can now
-- link, by the association's token alone like any first link.
SELECT pg_temp.cl_exchange('central-user-0099','919000000103','token-id-0000000000000063') AS relinked \gset
SELECT pg_temp.cl_assert(:'relinked'::jsonb#>>'{data,action}'='login'
 AND (SELECT central_subject='central-user-0099' FROM public.user_profiles WHERE id=:'earlier_profile'::uuid)
 AND pg_temp.cl_sessions('919000000103')=1,
 'after the unlink the token alone links the phone''s profile to the identity that presents it: '||left(:'relinked',200));
-- (the facility code that the conflict above left untried was never needed)
SELECT pg_temp.cl_assert(EXISTS (SELECT 1 FROM public.otp_verifications WHERE phone_number='919000000103' AND NOT verified AND attempts+source_attempts=0 AND expires_at>now()),
 'the facility''s unused code stays untouched');
-- ... and the earlier identity is now the one in conflict.
SELECT pg_temp.cl_assert(pg_temp.cl_exchange('central-user-0003','919000000103','token-id-0000000000000015')->>'code'='identity_conflict',
 'the identity that was unlinked no longer opens the profile');
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.cl_assert(public.clear_user_central_identity(:'earlier_profile'::uuid)->>'was_linked'='true','the second identity is unlinked as well');
SELECT public.clear_user_central_identity(:'earlier_profile'::uuid) AS cleared_again \gset
SELECT pg_temp.cl_assert(:'cleared_again'::jsonb->>'success'='true' AND :'cleared_again'::jsonb->>'was_linked'='false',
 'unlinking a profile that has no identity is harmless: '||:'cleared_again');
RESET ROLE;
-- Local SMS sign-in is untouched by all of this.
SELECT pg_temp.cl_code('919000000103') AS sms_code \gset
SELECT public.operator_verify_otp('9000000103',:'sms_code') AS sms_login \gset
SELECT pg_temp.cl_assert(:'sms_login'::jsonb#>>'{data,action}'='login'
 AND (SELECT central_subject IS NULL FROM public.user_profiles WHERE id=:'earlier_profile'::uuid),
 'the SMS code signs the profile in and links nothing');

-- ---------------------------------------------------------------------------
-- Migration 81: a facility that asks for its own code too (auth_config central_local_code = 'on')
-- ---------------------------------------------------------------------------
INSERT INTO warehouse_security.auth_config(key,value) VALUES ('central_local_code','on');
SELECT pg_temp.cl_sessions('919000000101') AS linked_person_sessions \gset
-- A linked, approved person is asked at every sign-in.
SELECT pg_temp.cl_exchange('central-user-0001','919000000101','token-id-0000000000000401') AS ask_first \gset
SELECT pg_temp.cl_exchange('central-user-0001','919000000101','token-id-0000000000000402') AS ask_second \gset
SELECT pg_temp.cl_assert(:'ask_first'::jsonb = '{"success":false,"code":"link_required"}'::jsonb
 AND :'ask_second'::jsonb = '{"success":false,"code":"link_required"}'::jsonb
 AND pg_temp.cl_sessions('919000000101')=:'linked_person_sessions'::bigint,
 'a linked profile answers link_required without a code, every time, and gets no session: '||:'ask_first'||' '||:'ask_second');
-- An unlinked, approved profile (found by phone) is linked and asked.
SELECT pg_temp.cl_exchange('central-user-0109','919000000109','token-id-0000000000000403') AS ask_unlinked \gset
SELECT pg_temp.cl_assert(:'ask_unlinked'::jsonb = '{"success":false,"code":"link_required"}'::jsonb
 AND (SELECT central_subject='central-user-0109' FROM public.user_profiles WHERE mobile='919000000109')
 AND pg_temp.cl_sessions('919000000109')=0,
 'an unlinked approved profile is linked and answers link_required, with no session: '||:'ask_unlinked');
-- A wrong code, counted as a wrong SMS code is; a code of another number is wrong too.
SELECT pg_temp.cl_code('919000000109') AS local_code \gset
SELECT CASE WHEN :'local_code'='000000' THEN '111111' ELSE '000000' END AS wrong_code \gset
SELECT pg_temp.cl_exchange('central-user-0109','919000000109','token-id-0000000000000404',NULL,NULL,
  'https://login.association.example.test',:'wrong_code') AS wrong_answer \gset
SELECT pg_temp.cl_assert(:'wrong_answer'::jsonb = '{"success":false,"code":"invalid_otp"}'::jsonb
 AND pg_temp.cl_sessions('919000000109')=0
 AND (SELECT count(*)=1 AND bool_and(NOT verified AND attempts+source_attempts=1) FROM public.otp_verifications
      WHERE phone_number='919000000109' AND expires_at>now()),
 'a wrong code answers invalid_otp, issues no session and uses one of the code''s five attempts: '||:'wrong_answer');
SELECT pg_temp.cl_code('919000000103') AS other_number_code \gset
SELECT pg_temp.cl_assert(pg_temp.cl_exchange('central-user-0109','919000000109','token-id-0000000000000405',NULL,NULL,
  'https://login.association.example.test',:'other_number_code')->>'code'='invalid_otp'
 AND pg_temp.cl_exchange('central-user-0109','919000000109','token-id-0000000000000406',NULL,NULL,
  'https://login.association.example.test','12345')->>'code'='invalid_otp'
 AND pg_temp.cl_sessions('919000000109')=0,
 'another number''s code and a code that is not six digits are wrong codes');
SELECT pg_temp.cl_assert(pg_temp.cl_exchange('central-user-0109','919000000109','token-id-0000000000000407',NULL,NULL,
  'https://login.association.example.test',:'wrong_code')->>'code'='invalid_otp'
 AND pg_temp.cl_exchange('central-user-0109','919000000109','token-id-0000000000000408',NULL,NULL,
  'https://login.association.example.test',:'wrong_code')->>'code'='invalid_otp','the rest of the five wrong attempts');
SELECT pg_temp.cl_exchange('central-user-0109','919000000109','token-id-0000000000000409',NULL,NULL,
  'https://login.association.example.test',:'local_code') AS exhausted \gset
SELECT pg_temp.cl_assert(:'exhausted'::jsonb->>'code'='invalid_otp' AND pg_temp.cl_sessions('919000000109')=0,
 'after five wrong attempts even the right code no longer signs in: '||:'exhausted');
-- The right code: the SMS sign-in's own answer, with the link named.
SELECT pg_temp.cl_code('919000000109') AS local_code \gset
SELECT pg_temp.cl_exchange('central-user-0109','919000000109','token-id-0000000000000410','Ignored Name',NULL,
  'https://login.association.example.test',:'local_code') AS code_answer \gset
SELECT pg_temp.cl_assert(:'code_answer'::jsonb->>'success'='true' AND :'code_answer'::jsonb#>>'{data,action}'='login'
 AND :'code_answer'::jsonb#>>'{data,user,mobile}'='919000000109' AND :'code_answer'::jsonb#>>'{data,user,role}'='staff'
 AND :'code_answer'::jsonb#>>'{data,session,refresh_token}' ~ '^[0-9a-f]{64}$'
 AND pg_temp.cl_sessions('919000000109')=1
 AND NOT EXISTS (SELECT 1 FROM public.otp_verifications WHERE phone_number='919000000109' AND NOT verified AND expires_at>now()),
 'the right code signs in, one session exists and the code is consumed: '||left(:'code_answer',300));
SELECT pg_temp.cl_assert(:'code_answer'::jsonb#>>'{data,user,central_issuer}'='https://login.association.example.test'
 AND :'code_answer'::jsonb#>>'{data,user,central_subject}'='central-user-0109'
 AND :'code_answer'::jsonb#>'{data,user}'=(SELECT to_jsonb(p) FROM public.user_profiles p WHERE p.mobile='919000000109'),
 'the answer of a code sign-in carries the stored, linked profile: '||left(:'code_answer',600));
-- The next sign-in asks again; a fresh code signs in again.
SELECT pg_temp.cl_assert(pg_temp.cl_exchange('central-user-0109','919000000109','token-id-0000000000000411')->>'code'='link_required'
 AND pg_temp.cl_sessions('919000000109')=1,'the next sign-in of the same person asks for a code again');
SELECT pg_temp.cl_code('919000000109') AS local_code \gset
SELECT pg_temp.cl_assert(pg_temp.cl_exchange('central-user-0109','919000000109','token-id-0000000000000412',NULL,NULL,
  'https://login.association.example.test',:'local_code')#>>'{data,action}'='login'
 AND pg_temp.cl_sessions('919000000109')=2,'a fresh code signs in again');
-- Pending people, new people, refused and service accounts need no code.
SELECT pg_temp.cl_assert(pg_temp.cl_exchange('central-user-0007','919000000107','token-id-0000000000000413')#>>'{data,action}'='pending',
 'a waiting request answers pending without a code');
SELECT pg_temp.cl_exchange('central-user-0401','919000000401','token-id-0000000000000414','New Person') AS new_person \gset
SELECT pg_temp.cl_assert(:'new_person'::jsonb#>>'{data,action}'='pending' AND :'new_person'::jsonb#>>'{data,user,name}'='New Person'
 AND pg_temp.cl_sessions('919000000401')=0,'a new person files an access request without a code');
SELECT pg_temp.cl_assert(pg_temp.cl_exchange('central-user-0005','919000000105','token-id-0000000000000415')->>'code'='account_unavailable'
 AND pg_temp.cl_exchange('central-user-0006','919000000106','token-id-0000000000000416')->>'code'='account_unavailable'
 AND pg_temp.cl_exchange('central-user-0008','919000000108','token-id-0000000000000417')->>'code'='account_unavailable'
 AND pg_temp.cl_exchange('central-user-0110','919000000110','token-id-0000000000000418')->>'code'='account_unavailable',
 'rejected, disabled and service-account profiles answer account_unavailable, not link_required');
-- A conflict still comes first.
SELECT pg_temp.cl_assert(pg_temp.cl_exchange('central-user-0998','919000000109','token-id-0000000000000419')->>'code'='identity_conflict',
 'identity_conflict is unchanged');
-- Any value other than on means off.
UPDATE warehouse_security.auth_config SET value='off' WHERE key='central_local_code';
SELECT pg_temp.cl_assert(pg_temp.cl_exchange('central-user-0109','919000000109','token-id-0000000000000420')#>>'{data,action}'='login',
 'with the setting off the token alone signs in again');
DELETE FROM warehouse_security.auth_config WHERE key='central_local_code';
SELECT pg_temp.cl_assert(pg_temp.cl_exchange('central-user-0109','919000000109','token-id-0000000000000421')#>>'{data,action}'='login',
 'with the setting absent the token alone signs in');

-- ---------------------------------------------------------------------------
-- The new-access-request limit is the one of the SMS sign-in
-- ---------------------------------------------------------------------------
SELECT pg_temp.cl_assert(pg_temp.cl_exchange('central-user-0301','919000000301','token-id-0000000000000301',NULL,'203.0.113.7')#>>'{data,action}'='pending'
 AND pg_temp.cl_exchange('central-user-0302','919000000302','token-id-0000000000000302',NULL,'203.0.113.7')#>>'{data,action}'='pending'
 AND pg_temp.cl_exchange('central-user-0303','919000000303','token-id-0000000000000303',NULL,'203.0.113.7')#>>'{data,action}'='pending',
 'three new requests from one address are accepted');
SELECT pg_temp.cl_exchange('central-user-0304','919000000304','token-id-0000000000000304',NULL,'203.0.113.7') AS limited \gset
SELECT pg_temp.cl_assert(:'limited'::jsonb = '{"success":false,"code":"enrollment_limited"}'::jsonb
 AND NOT EXISTS (SELECT 1 FROM public.user_profiles WHERE mobile='919000000304' OR central_subject='central-user-0304'),
 'the fourth new request from that address is limited and creates nothing');
SELECT pg_temp.cl_assert(pg_temp.cl_exchange('central-user-0301','919000000301','token-id-0000000000000305',NULL,'203.0.113.7')#>>'{data,action}'='pending'
 AND pg_temp.cl_exchange('central-user-0001','919000000101','token-id-0000000000000306',NULL,'203.0.113.7')#>>'{data,action}'='login',
 'the limit counts new requests only: known people still get their answer from that address');
SELECT pg_temp.cl_assert(pg_temp.cl_exchange('central-user-0304','919000000304','token-id-0000000000000307',NULL,'203.0.113.8')#>>'{data,action}'='pending',
 'another address is not affected');

-- ---------------------------------------------------------------------------
-- Deleting the own account frees the central identity with the phone number
-- ---------------------------------------------------------------------------
SELECT jsonb_build_object('role','authenticated','sub',p.auth_user_id,'session_id',s.id)::text AS person_claims
 FROM public.user_profiles p JOIN warehouse_security.refresh_sessions s ON s.user_id=p.auth_user_id
 WHERE p.id=:'person_profile'::uuid ORDER BY s.created_at DESC LIMIT 1 \gset
SELECT set_config('request.jwt.claims',:'person_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.cl_assert(public.delete_user_account()->>'success'='true','a centrally signed-in person deletes the own account');
RESET ROLE;
SELECT pg_temp.cl_assert((SELECT central_issuer IS NULL AND central_subject IS NULL AND NOT active AND mobile LIKE 'DEL%'
  FROM public.user_profiles WHERE id=:'person_profile'::uuid),'the deleted profile gives up its central identity');
SELECT pg_temp.cl_exchange('central-user-0001','919000000101','token-id-0000000000000308',NULL,'203.0.113.9') AS again \gset
SELECT pg_temp.cl_assert(:'again'::jsonb#>>'{data,action}'='pending' AND :'again'::jsonb#>>'{data,user,id}'<>:'person_profile',
 'the person can ask for access again, as after deleting an SMS-enrolled account: '||:'again');

-- ---------------------------------------------------------------------------
-- Migration 51: the table of the earlier design is gone
-- ---------------------------------------------------------------------------
SELECT pg_temp.cl_assert(to_regclass('public.central_user_links') IS NULL,'central_user_links no longer exists');
SELECT pg_temp.cl_assert(NOT EXISTS (SELECT 1 FROM pg_policies WHERE schemaname='public' AND tablename='central_user_links'),
 'the policies of central_user_links are gone with it');
SELECT pg_temp.cl_assert((SELECT count(*)=2 FROM information_schema.columns WHERE table_schema='public' AND table_name='user_profiles'
   AND column_name IN ('central_issuer','central_subject')),'the link lives on user_profiles');

-- ---------------------------------------------------------------------------
-- Expired token records
-- ---------------------------------------------------------------------------
INSERT INTO warehouse_security.central_token_use(token_hash,expires_at) VALUES
 ('expired-a',now()-interval '1 second'),('expired-b',now()-interval '1 day');
SELECT pg_temp.cl_assert((warehouse_maintenance.run_database_retention(now(),false)#>>'{rows,central_token_use}')::int=2
 AND (SELECT count(*)=2 FROM warehouse_security.central_token_use WHERE token_hash LIKE 'expired-%'),
 'the retention preview counts expired token records and deletes nothing');
SELECT count(*) AS live_tokens FROM warehouse_security.central_token_use WHERE expires_at>=now() \gset
SELECT warehouse_maintenance.run_database_retention(now(),true) AS retained \gset
SELECT pg_temp.cl_assert((:'retained'::jsonb#>>'{rows,central_token_use}')::int=2
 AND (SELECT count(*) FROM warehouse_security.central_token_use)=:'live_tokens'::bigint,
 'retention removes expired token records and keeps the live ones');
INSERT INTO warehouse_security.central_token_use(token_hash,expires_at) VALUES ('expired-c',now()-interval '1 second');
SELECT pg_temp.cl_exchange('central-user-0001','919000000101','token-id-0000000000000309') AS purging \gset
SELECT pg_temp.cl_assert(:'purging'::jsonb->>'success'='true'
 AND NOT EXISTS (SELECT 1 FROM warehouse_security.central_token_use WHERE token_hash='expired-c'),
 'recording a new token removes the expired ones');
ROLLBACK;
\echo 'Central login exchange, single use, linking by the token, an optional own code of the facility, conflict, service accounts, refusals, unlink and grants checks passed.'
