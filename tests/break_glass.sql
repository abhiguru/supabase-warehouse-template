-- Migration 126: break-glass administrator sign-in for the time SMS does not work (owner decision of 2026-10-25, review item 2).
-- warehouse_security.break_glass_code(phone) is executable by supabase_admin only; for an active, approved administrator it makes a
-- one-time six-digit code valid 10 minutes, which the NORMAL operator_verify_otp accepts (the app needs no change). It works once,
-- ends after five wrong tries, is refused for anyone who is not an active administrator, leaves the number unverified and the
-- address untrusted, and is written to audit_log when it is made and when it is used. public.operator_break_glass_open tells the
-- edge function whether a code is open. Fictional data; runs only in migrations.sh's disposable, network-disabled database; every
-- fixture row rolls back.
\set ON_ERROR_STOP on
BEGIN;
CREATE FUNCTION pg_temp.bg_assert(ok boolean, label text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF NOT COALESCE(ok,false) THEN RAISE EXCEPTION 'break glass: %',label; END IF; END $$;
-- The answer of break_glass_code, or 'raised: <message> (<state>)'.
CREATE FUNCTION pg_temp.bg_issue(phone text) RETURNS text LANGUAGE plpgsql AS $$
BEGIN
  RETURN warehouse_security.break_glass_code(phone)::text;
EXCEPTION WHEN OTHERS THEN RETURN 'raised: '||SQLERRM||' ('||SQLSTATE||')';
END $$;
-- The code of an issue, made again until it differs from the given one (the chance of a repeat is one in a million).
CREATE FUNCTION pg_temp.bg_code(phone text) RETURNS text LANGUAGE sql AS $$
  SELECT pg_temp.bg_issue(phone)::jsonb->>'code' $$;
-- 'login' for a sign-in, otherwise the refusal code.
CREATE FUNCTION pg_temp.bg_try(phone text, code text, source inet DEFAULT NULL) RETURNS text LANGUAGE plpgsql AS $$
DECLARE answer jsonb := public.operator_verify_otp(phone,code,NULL,NULL,source);
BEGIN RETURN COALESCE(answer#>>'{data,action}',answer->>'code'); END $$;
CREATE FUNCTION pg_temp.bg_wrong(code text) RETURNS text LANGUAGE sql AS $$
  SELECT lpad(((code::integer+1)%1000000)::text,6,'0') $$;
-- SQLSTATE of calling the function as the given role, or 'ok'.
CREATE FUNCTION pg_temp.bg_as(who text, phone text) RETURNS text LANGUAGE plpgsql AS $$
DECLARE outcome text := 'ok';
BEGIN
  EXECUTE format('SET LOCAL ROLE %I',who);
  BEGIN
    PERFORM warehouse_security.break_glass_code(phone);
  EXCEPTION WHEN OTHERS THEN outcome := SQLSTATE;
  END;
  RESET ROLE;
  RETURN outcome;
END $$;
INSERT INTO warehouse_security.auth_config(key,value) VALUES
 ('jwt_secret','isolated-test-secret-not-for-any-deployment-12345'),
 ('auth_mode','operator'),('demo_auth_enabled','false'),('refresh_grace_seconds','60'),
 ('otp_global_hourly_cap','300'),('otp_unknown_hourly_cap','60'),('enrollment_daily_cap','30'),
 ('otp_phone_daily_cap','30'),('otp_trusted_daily_reserve','10')
 ON CONFLICT(key) DO UPDATE SET value=excluded.value;
UPDATE warehouse_security.operator_otp_global_limit SET hourly_count=0,unknown_count=0,window_started=now() WHERE id;
SELECT warehouse_security.bootstrap_first_admin('9888888911','Break Glass Administrator') AS admin_user \gset
INSERT INTO public.user_profiles(auth_user_id,mobile,name,role,active,enrollment_status) VALUES
 (gen_random_uuid(),'919888888912','Second Administrator','admin',true,'approved'),
 (gen_random_uuid(),'919888888913','Glass Supervisor','supervisor',true,'approved'),
 (gen_random_uuid(),'919888888914','Glass Staff','staff',true,'approved'),
 (gen_random_uuid(),'919888888915','Glass Customer','customer',true,'approved'),
 (gen_random_uuid(),'919888888916','Switched Off Administrator','admin',false,'approved'),
 (gen_random_uuid(),'919888888917','Pending Administrator','admin',false,'pending');
SELECT id AS admin_profile FROM public.user_profiles WHERE mobile='919888888911' \gset
SELECT auth_user_id AS admin2_user FROM public.user_profiles WHERE mobile='919888888912' \gset

-- 1. Who may call it. Only the installer (supabase_admin): no app role can execute it, the table is closed, and the edge function's
--    helper is for the service role alone.
SELECT pg_temp.bg_assert(has_function_privilege('supabase_admin','warehouse_security.break_glass_code(text)','EXECUTE')
  AND NOT has_function_privilege('anon','warehouse_security.break_glass_code(text)','EXECUTE')
  AND NOT has_function_privilege('authenticated','warehouse_security.break_glass_code(text)','EXECUTE')
  AND NOT has_function_privilege('service_role','warehouse_security.break_glass_code(text)','EXECUTE'),
  'only supabase_admin may execute break_glass_code');
SELECT pg_temp.bg_assert(pg_temp.bg_as('anon','9888888911')='42501' AND pg_temp.bg_as('authenticated','9888888911')='42501'
  AND pg_temp.bg_as('service_role','9888888911')='42501',
  'anon, authenticated and service_role are refused with 42501 (and no code was made)');
SELECT pg_temp.bg_assert((SELECT count(*)=0 FROM warehouse_security.break_glass_codes),'a refused call made no code');
SELECT pg_temp.bg_assert(NOT has_table_privilege('anon','warehouse_security.break_glass_codes','SELECT')
  AND NOT has_table_privilege('authenticated','warehouse_security.break_glass_codes','SELECT')
  AND NOT has_table_privilege('service_role','warehouse_security.break_glass_codes','SELECT')
  AND NOT has_table_privilege('authenticated','warehouse_security.break_glass_codes','INSERT')
  AND (SELECT relrowsecurity FROM pg_class WHERE oid='warehouse_security.break_glass_codes'::regclass),
  'no API role reads or writes the code table and row security is on');
SELECT pg_temp.bg_assert(has_function_privilege('service_role','public.operator_break_glass_open(text)','EXECUTE')
  AND NOT has_function_privilege('anon','public.operator_break_glass_open(text)','EXECUTE')
  AND NOT has_function_privilege('authenticated','public.operator_break_glass_open(text)','EXECUTE'),
  'only the service role may ask whether a code is open');

-- 2. Whom it is for: an existing active, approved administrator. Everyone else is refused and nothing is written.
SELECT pg_temp.bg_assert(pg_temp.bg_issue('9888888999') = 'raised: No active, approved administrator has this phone number (P0001)','an unknown number is refused');
SELECT pg_temp.bg_assert(pg_temp.bg_issue('9888888913') LIKE 'raised: No active, approved administrator%','a supervisor is refused');
SELECT pg_temp.bg_assert(pg_temp.bg_issue('9888888914') LIKE 'raised: No active, approved administrator%','staff is refused');
SELECT pg_temp.bg_assert(pg_temp.bg_issue('9888888915') LIKE 'raised: No active, approved administrator%','a customer is refused');
SELECT pg_temp.bg_assert(pg_temp.bg_issue('9888888916') LIKE 'raised: No active, approved administrator%','a switched-off administrator is refused');
SELECT pg_temp.bg_assert(pg_temp.bg_issue('9888888917') LIKE 'raised: No active, approved administrator%','a pending administrator is refused');
SELECT pg_temp.bg_assert(pg_temp.bg_issue('98888') LIKE 'raised: Expected a 10-digit Indian mobile number%','a number that is not a mobile number is refused');
SELECT pg_temp.bg_assert((SELECT count(*)=0 FROM warehouse_security.break_glass_codes)
  AND (SELECT count(*)=0 FROM public.audit_log WHERE table_name='break_glass'),'refused calls wrote neither a code nor an audit row');
SELECT pg_temp.bg_assert(NOT public.operator_break_glass_open('9888888911'),'no code is open before one is made');
SELECT pg_temp.bg_assert(NOT public.operator_break_glass_open('9888888914'),'no code is open for a staff number');

-- 3. A code: six digits, valid 10 minutes, stored as a keyed hash, audited without the code.
SELECT warehouse_security.break_glass_code('9888888911') AS made \gset
SELECT :'made'::jsonb->>'code' AS bg1 \gset
SELECT pg_temp.bg_assert(:'bg1' ~ '^[0-9]{6}$' AND :'made'::jsonb->>'name'='Break Glass Administrator' AND (:'made'::jsonb->>'valid_minutes')::integer=10
  AND abs(extract(epoch FROM ((:'made'::jsonb->>'expires_at')::timestamptz - (now() + interval '10 minutes')))) < 5,
  'the answer carries a six-digit code, the administrator''s name and a 10 minute life: '||:'made');
SELECT pg_temp.bg_assert((SELECT count(*)=1 AND bool_and(code_hash ~ '^[0-9a-f]{64}$' AND code_hash<>:'bg1' AND used_at IS NULL AND attempts=0
    AND user_id=:'admin_user'::uuid AND phone_number='919888888911'
    AND code_hash=encode(extensions.hmac(phone_number||':'||:'bg1'||':'||id::text,'isolated-test-secret-not-for-any-deployment-12345','sha256'),'hex'))
  FROM warehouse_security.break_glass_codes),
  'one row holds the HMAC-SHA256 of phone:code:id keyed with the JWT secret, not the code');
SELECT pg_temp.bg_assert((SELECT count(*)=1 AND bool_and(user_id=:'admin_user'::uuid AND new_data->>'mobile'='919888888911'
    AND new_data->>'name'='Break Glass Administrator' AND NOT (new_data ? 'code') AND NOT (new_data ? 'code_hash'))
  FROM public.audit_log WHERE table_name='break_glass' AND action='CODE_ISSUED'),'making the code is audited, without the code');
SELECT pg_temp.bg_assert(public.operator_break_glass_open('9888888911') AND public.operator_break_glass_open('+91 98888 88911'),
  'the edge function is told that a code is open (the number may be written in other forms)');

-- 4. The code signs the administrator in through the ordinary verify function, from an address the phone never used.
SELECT count(*) AS sessions_before FROM warehouse_security.refresh_sessions WHERE user_id=:'admin_user'::uuid \gset
SELECT public.operator_verify_otp('9888888911',:'bg1',NULL,NULL,'203.0.113.11') AS signed_in \gset
SELECT pg_temp.bg_assert(:'signed_in'::jsonb->>'success'='true' AND :'signed_in'::jsonb#>>'{data,action}'='login'
  AND :'signed_in'::jsonb#>>'{data,user,id}'=:'admin_profile' AND :'signed_in'::jsonb#>>'{data,user,role}'='admin'
  AND :'signed_in'::jsonb#>>'{data,session,access_token}' ~ '^[^.]+\.[^.]+\.[^.]+$'
  AND :'signed_in'::jsonb#>>'{data,session,refresh_token}' ~ '^[0-9a-f]{64}$',
  'the break-glass code opens a normal session for the administrator: '||:'signed_in');
SELECT pg_temp.bg_assert((SELECT count(*)=:sessions_before+1 FROM warehouse_security.refresh_sessions WHERE user_id=:'admin_user'::uuid),
  'the sign-in made one session');
SELECT pg_temp.bg_assert((SELECT used_at IS NOT NULL AND code_hash IS NULL AND used_from='203.0.113.11'::inet FROM warehouse_security.break_glass_codes),
  'the code is marked used, from that address, and its hash is cleared');
SELECT pg_temp.bg_assert((SELECT count(*)=1 AND bool_and(user_id=:'admin_user'::uuid AND ip_address='203.0.113.11'::inet
    AND new_data->>'mobile'='919888888911' AND NOT (new_data ? 'code'))
  FROM public.audit_log WHERE table_name='break_glass' AND action='SIGN_IN'),'the sign-in is audited with the address it came from');
SELECT pg_temp.bg_assert((SELECT NOT mobile_verified AND mobile_verified_at IS NULL FROM public.user_profiles WHERE id=:'admin_profile'::uuid),
  'a break-glass sign-in does not mark the number as verified by SMS');
SELECT pg_temp.bg_assert((SELECT count(*)=0 FROM warehouse_security.otp_trusted_sources WHERE phone_number='919888888911'),
  'a break-glass sign-in does not make its address a trusted source of the phone');
SELECT pg_temp.bg_assert((SELECT count(*)=0 FROM public.ip_rate_limits WHERE ip_address='203.0.113.11' AND verify_failures>0),
  'a successful break-glass sign-in is no failed verification of its source');
SELECT pg_temp.bg_assert(NOT public.operator_break_glass_open('9888888911'),'a used code is no longer open');

-- 5. One use only.
SELECT pg_temp.bg_assert(pg_temp.bg_try('9888888911',:'bg1','203.0.113.11')='invalid_otp' AND pg_temp.bg_try('9888888911',:'bg1')='invalid_otp',
  'the same code is refused the second time, from the same or another address');
SELECT pg_temp.bg_assert((SELECT count(*)=:sessions_before+1 FROM warehouse_security.refresh_sessions WHERE user_id=:'admin_user'::uuid),
  'the refused second use made no session');

-- 6. Ten minutes: valid up to its end, refused after.
SELECT pg_temp.bg_code('9888888911') AS bg2 \gset
UPDATE warehouse_security.break_glass_codes SET expires_at=now()+interval '1 second' WHERE used_at IS NULL;
SELECT pg_temp.bg_assert(pg_temp.bg_try('9888888911',:'bg2','203.0.113.11')='login','a code with a second left still signs in');
SELECT pg_temp.bg_code('9888888911') AS bg3 \gset
UPDATE warehouse_security.break_glass_codes SET expires_at=now()-interval '1 second' WHERE used_at IS NULL;
SELECT pg_temp.bg_assert(NOT public.operator_break_glass_open('9888888911'),'an expired code is not open');
SELECT pg_temp.bg_assert(pg_temp.bg_try('9888888911',:'bg3','203.0.113.11')='invalid_otp','a code one second past its end is refused');

-- 7. Five wrong tries end the code, from any address; four do not.
SELECT pg_temp.bg_code('9888888911') AS bg4 \gset
SELECT pg_temp.bg_assert(pg_temp.bg_try('9888888911',pg_temp.bg_wrong(:'bg4'),'203.0.113.21')='invalid_otp'
  AND pg_temp.bg_try('9888888911',pg_temp.bg_wrong(:'bg4'),'203.0.113.22')='invalid_otp'
  AND pg_temp.bg_try('9888888911',pg_temp.bg_wrong(:'bg4'))='invalid_otp'
  AND pg_temp.bg_try('9888888911',pg_temp.bg_wrong(:'bg4'),'203.0.113.21')='invalid_otp','four wrong tries are refused');
SELECT pg_temp.bg_assert((SELECT attempts=4 FROM warehouse_security.break_glass_codes WHERE used_at IS NULL AND expires_at>now())
  AND public.operator_break_glass_open('9888888911'),'four wrong tries are counted and the code is still open');
SELECT pg_temp.bg_assert((SELECT verify_failures=2 FROM public.ip_rate_limits WHERE ip_address='203.0.113.21'),
  'a wrong try counts as a failed verification of its source');
SELECT pg_temp.bg_assert(pg_temp.bg_try('9888888911',:'bg4','203.0.113.23')='login','the right code on the fifth try signs in');
SELECT pg_temp.bg_code('9888888911') AS bg5 \gset
SELECT pg_temp.bg_assert(pg_temp.bg_try('9888888911',pg_temp.bg_wrong(:'bg5'),'203.0.113.24')='invalid_otp'
  AND pg_temp.bg_try('9888888911',pg_temp.bg_wrong(:'bg5'),'203.0.113.25')='invalid_otp'
  AND pg_temp.bg_try('9888888911',pg_temp.bg_wrong(:'bg5'),'203.0.113.26')='invalid_otp'
  AND pg_temp.bg_try('9888888911',pg_temp.bg_wrong(:'bg5'),'203.0.113.27')='invalid_otp'
  AND pg_temp.bg_try('9888888911',pg_temp.bg_wrong(:'bg5'),'203.0.113.28')='invalid_otp','five wrong tries from five addresses');
SELECT pg_temp.bg_assert(NOT public.operator_break_glass_open('9888888911') AND pg_temp.bg_try('9888888911',:'bg5','203.0.113.29')='invalid_otp',
  'after five wrong tries even the right code is refused');

-- 8. A code belongs to its number and its administrator.
SELECT pg_temp.bg_code('9888888911') AS bg6 \gset
SELECT pg_temp.bg_assert(pg_temp.bg_try('9888888912',:'bg6','203.0.113.31')='invalid_otp','the code of one administrator does not open another');
SELECT pg_temp.bg_assert((SELECT attempts=0 FROM warehouse_security.break_glass_codes WHERE phone_number='919888888911' AND used_at IS NULL AND expires_at>now()),
  'a try on another number is not counted against the code');
SELECT pg_temp.bg_assert(pg_temp.bg_try('9888888914',:'bg6','203.0.113.31')='invalid_otp','nor does it open a staff number');
-- The administrator is demoted, or switched off, after the code was made: the code stops working.
UPDATE public.user_profiles SET role='supervisor' WHERE id=:'admin_profile'::uuid;
SELECT pg_temp.bg_assert(NOT public.operator_break_glass_open('9888888911') AND pg_temp.bg_try('9888888911',:'bg6','203.0.113.32')='invalid_otp',
  'a code of a demoted administrator is refused');
UPDATE public.user_profiles SET role='admin', active=false WHERE id=:'admin_profile'::uuid;
SELECT pg_temp.bg_assert(NOT public.operator_break_glass_open('9888888911') AND pg_temp.bg_try('9888888911',:'bg6','203.0.113.32')='invalid_otp',
  'a code of a switched-off administrator is refused');
UPDATE public.user_profiles SET active=true WHERE id=:'admin_profile'::uuid;
SELECT pg_temp.bg_assert(pg_temp.bg_try('9888888911',:'bg6','203.0.113.32')='login','and works again when the administrator is back');

-- 9. A new code ends the earlier open one.
SELECT pg_temp.bg_code('9888888911') AS bg7 \gset
SELECT pg_temp.bg_code('9888888911') AS bg8 \gset
SELECT pg_temp.bg_assert((SELECT count(*)=1 FROM warehouse_security.break_glass_codes WHERE phone_number='919888888911' AND used_at IS NULL AND expires_at>now()),
  'one code is open at a time');
SELECT pg_temp.bg_assert(:'bg7'=:'bg8' OR pg_temp.bg_try('9888888911',:'bg7','203.0.113.41')='invalid_otp','the earlier code no longer signs in');
SELECT pg_temp.bg_assert(pg_temp.bg_try('9888888911',:'bg8','203.0.113.41')='login','the newest code signs in');
-- Rows older than two days go when a new code is made.
INSERT INTO warehouse_security.break_glass_codes(user_id,phone_number,code_hash,expires_at,created_at)
VALUES (:'admin_user'::uuid,'919888888911','x',now()-interval '3 days',now()-interval '3 days');
SELECT pg_temp.bg_code('9888888911') AS bg9 \gset
SELECT pg_temp.bg_assert((SELECT count(*)=0 FROM warehouse_security.break_glass_codes WHERE created_at<now()-interval '2 days'),
  'a code row older than two days is removed when a new code is made');
UPDATE warehouse_security.break_glass_codes SET expires_at=now()-interval '1 second' WHERE used_at IS NULL;

-- 10. SMS sign-in is unchanged, also while a break-glass code is open: the SMS code is looked at first and leaves the break-glass code alone.
SELECT pg_temp.bg_code('9888888912') AS bg10 \gset
SELECT public.operator_prepare_otp('9888888912','203.0.113.51') AS challenge \gset
SELECT public.operator_finish_otp((:'challenge'::jsonb#>>'{data,request_id}')::uuid,true,'mock-provider-only') AS finished \gset
SELECT pg_temp.bg_assert(pg_temp.bg_try('9888888912',:'challenge'::jsonb#>>'{data,otp_code}','203.0.113.51')='login','the SMS code still signs the administrator in');
SELECT pg_temp.bg_assert((SELECT used_at IS NULL AND attempts=0 FROM warehouse_security.break_glass_codes WHERE phone_number='919888888912'),
  'the SMS sign-in neither used nor counted against the open break-glass code');
SELECT pg_temp.bg_assert((SELECT mobile_verified FROM public.user_profiles WHERE auth_user_id=:'admin2_user'::uuid),'an SMS sign-in does mark the number as verified');
SELECT pg_temp.bg_assert((SELECT count(*)=1 FROM warehouse_security.otp_trusted_sources WHERE phone_number='919888888912' AND ip_address='203.0.113.51'),
  'an SMS sign-in still makes its address a trusted source');
SELECT pg_temp.bg_assert(pg_temp.bg_try('9888888912',:'bg10','203.0.113.52')='login','the break-glass code of that administrator still works after it');
-- A number that is not an administrator's gets nothing from a six-digit guess.
SELECT pg_temp.bg_assert(pg_temp.bg_try('9888888915','123456','203.0.113.53')='invalid_otp','a customer''s number with a made-up code is refused');

-- 11. The audit trail: ten codes were made and six of them were used to sign in.
SELECT pg_temp.bg_assert((SELECT count(*) FILTER (WHERE action='CODE_ISSUED')=10 AND count(*) FILTER (WHERE action='SIGN_IN')=6
    AND count(*)=16 FROM public.audit_log WHERE table_name='break_glass'),
  'ten CODE_ISSUED and six SIGN_IN rows are recorded in all: '||(SELECT string_agg(action||':'||COALESCE(ip_address::text,'-'),' ' ORDER BY action, ip_address) FROM public.audit_log WHERE table_name='break_glass'));
SELECT pg_temp.bg_assert((SELECT bool_and(ip_address IS NOT NULL) AND count(DISTINCT ip_address)=5 FROM public.audit_log WHERE table_name='break_glass' AND action='SIGN_IN'),
  'each sign-in names the address it came from');
ROLLBACK;
\echo 'Break-glass sign-in: installer only, administrators only, one use, ten minutes, five tries, not verified and not trusted, audited, SMS sign-in unchanged passed.'
