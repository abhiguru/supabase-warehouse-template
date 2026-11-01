-- Migration 132: break-glass codes for every facility worker, the app's own sign-in with one (public.operator_break_glass_sign_in) and the
-- 24 hour session it opens (owner decisions D2 to D6 on the break-glass sign-in). Covered: who may get a code (administrator, supervisor,
-- staff; never a customer, a pending or switched-off profile, a service account), the answer shape and the refusal codes (
-- invalid_code, code_used, code_expired, code_locked, rate_limited), single use, five tries, the per-source failure limit, the audit rows,
-- that the session ends 24 hours after the code sign-in and a refresh never moves it past that (while another session still slides to 30
-- days), that the older code screen (operator_verify_otp) takes a worker's code too and gives the same 24 hour session, and that the
-- functions are for the service role (or the installer) alone. Fictional data; runs only in migrations.sh's disposable, network-disabled
-- database; every fixture row rolls back.
\set ON_ERROR_STOP on
BEGIN;
CREATE FUNCTION pg_temp.bw_assert(ok boolean, label text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF NOT COALESCE(ok,false) THEN RAISE EXCEPTION 'break glass workers: %',label; END IF; END $$;
CREATE FUNCTION pg_temp.bw_code(phone text) RETURNS text LANGUAGE sql AS $$
  SELECT (warehouse_security.break_glass_code(phone))->>'code' $$;
-- 'login' for a sign-in, otherwise the refusal code.
CREATE FUNCTION pg_temp.bw_in(phone text, code text, source inet DEFAULT NULL) RETURNS text LANGUAGE plpgsql AS $$
DECLARE answer jsonb := public.operator_break_glass_sign_in(phone,code,source);
BEGIN RETURN COALESCE(answer#>>'{data,action}',answer->>'code'); END $$;
CREATE FUNCTION pg_temp.bw_wrong(code text) RETURNS text LANGUAGE sql AS $$
  SELECT lpad(((code::integer+1)%1000000)::text,6,'0') $$;
-- The message of a refused issue, or 'ok'.
CREATE FUNCTION pg_temp.bw_issue(phone text) RETURNS text LANGUAGE plpgsql AS $$
BEGIN PERFORM warehouse_security.break_glass_code(phone); RETURN 'ok';
EXCEPTION WHEN OTHERS THEN RETURN SQLERRM; END $$;
-- SQLSTATE of calling a function as the given role, or 'ok'.
CREATE FUNCTION pg_temp.bw_as(who text, call text) RETURNS text LANGUAGE plpgsql AS $$
DECLARE outcome text := 'ok';
BEGIN
  EXECUTE format('SET LOCAL ROLE %I',who);
  BEGIN EXECUTE call;
  EXCEPTION WHEN OTHERS THEN outcome := SQLSTATE;
  END;
  RESET ROLE;
  RETURN outcome;
END $$;
-- 'success', 'refused' or 'raised' for a refresh.
CREATE FUNCTION pg_temp.bw_refresh(p_refresh text) RETURNS text LANGUAGE plpgsql AS $$
BEGIN
  IF public.refresh_jwt_token(p_refresh)->>'success'='true' THEN RETURN 'success'; END IF;
  RETURN 'refused';
EXCEPTION WHEN OTHERS THEN RETURN 'raised';
END $$;
-- The session row of a refresh token.
CREATE FUNCTION pg_temp.bw_session(p_refresh text) RETURNS warehouse_security.refresh_sessions LANGUAGE sql AS $$
  SELECT s FROM warehouse_security.refresh_sessions s WHERE s.token_hash=encode(extensions.digest(p_refresh,'sha256'),'hex') $$;
INSERT INTO warehouse_security.auth_config(key,value) VALUES
 ('jwt_secret','isolated-test-secret-not-for-any-deployment-12345'),
 ('auth_mode','operator'),('demo_auth_enabled','false'),('refresh_grace_seconds','60'),
 ('otp_global_hourly_cap','300'),('otp_unknown_hourly_cap','60'),('enrollment_daily_cap','30'),
 ('otp_phone_daily_cap','30'),('otp_trusted_daily_reserve','10')
 ON CONFLICT(key) DO UPDATE SET value=excluded.value;
UPDATE warehouse_security.operator_otp_global_limit SET hourly_count=0,unknown_count=0,window_started=now() WHERE id;
SELECT warehouse_security.bootstrap_first_admin('9888888931','Worker Glass Administrator') AS admin_user \gset
INSERT INTO public.user_profiles(auth_user_id,mobile,name,role,active,enrollment_status,is_service_account) VALUES
 (gen_random_uuid(),'919888888932','Worker Glass Supervisor','supervisor',true,'approved',false),
 (gen_random_uuid(),'919888888933','Worker Glass Staff','staff',true,'approved',false),
 (gen_random_uuid(),'919888888934','Worker Glass Customer','customer',true,'approved',false),
 (gen_random_uuid(),'919888888935','Worker Glass Pending Staff','staff',false,'pending',false),
 (gen_random_uuid(),'919888888936','Worker Glass Off Staff','staff',false,'approved',false),
 (gen_random_uuid(),'919888888937','Worker Glass Service Staff','staff',true,'approved',true),
 (gen_random_uuid(),'919888888938','Worker Glass Other Staff','staff',true,'approved',false);
SELECT auth_user_id AS sup_user, id AS sup_profile FROM public.user_profiles WHERE mobile='919888888932' \gset
SELECT auth_user_id AS staff_user, id AS staff_profile FROM public.user_profiles WHERE mobile='919888888933' \gset
SELECT auth_user_id AS customer_user FROM public.user_profiles WHERE mobile='919888888934' \gset
SELECT auth_user_id AS other_user FROM public.user_profiles WHERE mobile='919888888938' \gset

-- 1. Who may call what. The sign-in is for the service role (the edge function); the checking and session helpers for nobody but the database.
SELECT pg_temp.bw_assert(has_function_privilege('service_role','public.operator_break_glass_sign_in(text,text,inet)','EXECUTE')
  AND NOT has_function_privilege('anon','public.operator_break_glass_sign_in(text,text,inet)','EXECUTE')
  AND NOT has_function_privilege('authenticated','public.operator_break_glass_sign_in(text,text,inet)','EXECUTE'),
  'only the service role may run the break-glass sign-in');
SELECT pg_temp.bw_assert((SELECT bool_and(NOT has_function_privilege(r,f,'EXECUTE'))
    FROM unnest(ARRAY['anon','authenticated','service_role']) r,
         unnest(ARRAY['warehouse_security.redeem_break_glass(text,text,inet)','warehouse_security.limit_break_glass_session(jsonb)']) f),
  'the two helpers are for the database functions only');
SELECT pg_temp.bw_assert(pg_temp.bw_as('anon',$$SELECT public.operator_break_glass_sign_in('9888888933','123456',NULL)$$)='42501'
  AND pg_temp.bw_as('authenticated',$$SELECT public.operator_break_glass_sign_in('9888888933','123456',NULL)$$)='42501',
  'an app role is refused with 42501');

-- 2. Whom a code can be made for: administrators, supervisors and staff; no one else.
SELECT pg_temp.bw_assert(pg_temp.bw_issue('9888888931')='ok' AND pg_temp.bw_issue('9888888932')='ok' AND pg_temp.bw_issue('9888888933')='ok',
  'a code can be made for an administrator, a supervisor and a staff member');
SELECT pg_temp.bw_assert((warehouse_security.break_glass_code('9888888932'))->>'role'='supervisor'
  AND (warehouse_security.break_glass_code('9888888933'))->>'role'='staff'
  AND (warehouse_security.break_glass_code('9888888931'))->>'role'='admin','the answer names the role');
SELECT pg_temp.bw_assert(pg_temp.bw_issue('9888888934') LIKE 'No active, approved administrator, supervisor or staff member%'
  AND pg_temp.bw_issue('9888888935') LIKE 'No active, approved administrator, supervisor or staff member%'
  AND pg_temp.bw_issue('9888888936') LIKE 'No active, approved administrator, supervisor or staff member%'
  AND pg_temp.bw_issue('9888888937') LIKE 'No active, approved administrator, supervisor or staff member%'
  AND pg_temp.bw_issue('9888888999') LIKE 'No active, approved administrator, supervisor or staff member%',
  'a customer, a pending or switched-off profile, a service account and an unknown number get no code');
SELECT pg_temp.bw_assert(public.operator_break_glass_open('9888888933') AND public.operator_break_glass_open('9888888932')
  AND NOT public.operator_break_glass_open('9888888934') AND NOT public.operator_break_glass_open('9888888937'),
  'the edge function is told a code is open for workers only');
SELECT pg_temp.bw_assert((SELECT bool_and(new_data->>'role' IS NOT NULL AND NOT (new_data ? 'code')) FROM public.audit_log WHERE table_name='break_glass' AND action='CODE_ISSUED'),
  'issuing is audited with the role and without the code');

-- 3. A staff member signs in. Same shape as the SMS sign-in, a session that ends 24 hours later, audited, number not marked verified.
SELECT pg_temp.bw_code('9888888933') AS bg1 \gset
SELECT pg_temp.bw_assert((SELECT abs(extract(epoch FROM (expires_at - created_at)) - 600) < 1 FROM warehouse_security.break_glass_codes
    WHERE phone_number='919888888933' AND used_at IS NULL AND expires_at>now() AND code_hash IS NOT NULL),'a code lives 10 minutes');
SELECT count(*) AS sessions_before FROM warehouse_security.refresh_sessions WHERE user_id=:'staff_user'::uuid \gset
SELECT public.operator_break_glass_sign_in('+91 98888 88933',:'bg1','203.0.113.11') AS signed_in \gset
SELECT pg_temp.bw_assert(:'signed_in'::jsonb->>'success'='true' AND :'signed_in'::jsonb#>>'{data,action}'='login'
  AND :'signed_in'::jsonb#>>'{data,user,id}'=:'staff_profile' AND :'signed_in'::jsonb#>>'{data,user,role}'='staff'
  AND :'signed_in'::jsonb#>>'{data,session,access_token}' ~ '^[^.]+\.[^.]+\.[^.]+$'
  AND :'signed_in'::jsonb#>>'{data,session,refresh_token}' ~ '^[0-9a-f]{64}$'
  AND (:'signed_in'::jsonb#>>'{data,session,expires_in}')::integer>0,
  'the sign-in answers like the SMS sign-in: '||:'signed_in');
SELECT :'signed_in'::jsonb#>>'{data,session,refresh_token}' AS refresh1 \gset
SELECT :'signed_in'::jsonb#>>'{data,session,session_ends_at}' AS ends1 \gset
SELECT pg_temp.bw_assert((SELECT count(*)=:sessions_before+1 FROM warehouse_security.refresh_sessions WHERE user_id=:'staff_user'::uuid),'one session was made');
SELECT pg_temp.bw_assert((pg_temp.bw_session(:'refresh1')).hard_expires_at = (pg_temp.bw_session(:'refresh1')).created_at + interval '24 hours'
  AND (pg_temp.bw_session(:'refresh1')).expires_at = (pg_temp.bw_session(:'refresh1')).hard_expires_at
  AND :'ends1'::timestamptz = (pg_temp.bw_session(:'refresh1')).hard_expires_at,
  'the session ends 24 hours after the sign-in and the answer says when');
SELECT pg_temp.bw_assert((SELECT count(*)=1 AND bool_and(code_hash IS NOT NULL AND used_from='203.0.113.11'::inet) FROM warehouse_security.break_glass_codes
    WHERE user_id=:'staff_user'::uuid AND used_at IS NOT NULL),'the code is marked used, from that address, and its hash is kept (so that a repeat of that code can be told "used")');
SELECT pg_temp.bw_assert((SELECT count(*)=1 AND bool_and(user_id=:'staff_user'::uuid AND ip_address='203.0.113.11'::inet AND new_data->>'role'='staff'
    AND NOT (new_data ? 'code')) FROM public.audit_log WHERE table_name='break_glass' AND action='SIGN_IN'),'the sign-in is audited with role and address');
SELECT pg_temp.bw_assert((SELECT NOT mobile_verified FROM public.user_profiles WHERE id=:'staff_profile'::uuid)
  AND (SELECT count(*)=0 FROM warehouse_security.otp_trusted_sources WHERE phone_number='919888888933')
  AND (SELECT count(*)=0 FROM public.ip_rate_limits WHERE ip_address='203.0.113.11' AND verify_failures>0),
  'not verified by SMS, address not trusted, no failure counted for the source');

-- 4. One use only; a used code says so.
SELECT pg_temp.bw_assert(pg_temp.bw_in('9888888933',:'bg1','203.0.113.11')='code_used' AND pg_temp.bw_in('9888888933',:'bg1')='code_used',
  'the same code is refused as code_used the second time');
-- A wrong code (or an unknown number) gets the same answer as before: used, expired and locked are said only to the holder of the issued code.
SELECT pg_temp.bw_assert(pg_temp.bw_in('9888888933',pg_temp.bw_wrong(:'bg1'),'203.0.113.14')='invalid_code'
  AND pg_temp.bw_in('9888888999','123456','203.0.113.14')='invalid_code','a wrong code for a number whose code was used, and an unknown number, answer invalid_code');
SELECT pg_temp.bw_assert((SELECT count(*)=:sessions_before+1 FROM warehouse_security.refresh_sessions WHERE user_id=:'staff_user'::uuid),'and made no session');

-- 5. A supervisor and an administrator sign in the same way.
SELECT pg_temp.bw_code('9888888932') AS bg2 \gset
SELECT pg_temp.bw_assert(pg_temp.bw_in('9888888932',:'bg2','203.0.113.12')='login','a supervisor signs in');
SELECT pg_temp.bw_code('9888888931') AS bg3 \gset
SELECT pg_temp.bw_assert(pg_temp.bw_in('9888888931',:'bg3','203.0.113.13')='login','an administrator signs in');

-- 6. Wrong code, no code, a code of another number, a code that is not six digits.
SELECT pg_temp.bw_code('9888888933') AS bg4 \gset
SELECT pg_temp.bw_assert(pg_temp.bw_in('9888888933',pg_temp.bw_wrong(:'bg4'),'203.0.113.21')='invalid_code','a wrong code is invalid_code');
SELECT pg_temp.bw_assert(pg_temp.bw_in('9888888938','123456','203.0.113.22')='invalid_code','a worker with no code gets invalid_code');
SELECT pg_temp.bw_assert(pg_temp.bw_in('9888888999','123456','203.0.113.22')='invalid_code','an unknown number gets invalid_code (no error, no difference)');
SELECT pg_temp.bw_assert(pg_temp.bw_in('9888888935',:'bg4','203.0.113.22')='invalid_code' AND pg_temp.bw_in('9888888936',:'bg4','203.0.113.22')='invalid_code'
  AND pg_temp.bw_in('9888888937',:'bg4','203.0.113.22')='invalid_code','a pending, a switched-off and a service-account profile get invalid_code');
SELECT pg_temp.bw_assert(pg_temp.bw_in('9888888938',:'bg4','203.0.113.22')='invalid_code','the code of one worker does not open another');
SELECT pg_temp.bw_assert(public.operator_break_glass_sign_in('9888888933','12345',NULL)->>'code'='invalid_request'
  AND public.operator_break_glass_sign_in('9888888933','12345a',NULL)->>'code'='invalid_request'
  AND public.operator_break_glass_sign_in('9888888933',NULL,NULL)->>'code'='invalid_request','a code that is not six digits is invalid_request');
SELECT pg_temp.bw_assert((SELECT attempts=1 FROM warehouse_security.break_glass_codes WHERE phone_number='919888888933' AND used_at IS NULL AND expires_at>now()),
  'only the one wrong try on the right number was counted');
SELECT pg_temp.bw_assert((SELECT verify_failures>=1 FROM public.ip_rate_limits WHERE ip_address='203.0.113.21'),'a refusal counts as a failed verification of its source');
SELECT pg_temp.bw_assert(pg_temp.bw_in('9888888933',:'bg4','203.0.113.23')='login','the right code still signs in after the wrong one');

-- 7. Five wrong tries end the code, from any address; even the right one is then code_locked.
SELECT pg_temp.bw_code('9888888933') AS bg5 \gset
SELECT pg_temp.bw_assert(pg_temp.bw_in('9888888933',pg_temp.bw_wrong(:'bg5'),'203.0.113.31')='invalid_code'
  AND pg_temp.bw_in('9888888933',pg_temp.bw_wrong(:'bg5'),'203.0.113.32')='invalid_code'
  AND pg_temp.bw_in('9888888933',pg_temp.bw_wrong(:'bg5'),'203.0.113.33')='invalid_code'
  AND pg_temp.bw_in('9888888933',pg_temp.bw_wrong(:'bg5'),'203.0.113.34')='invalid_code'
  AND pg_temp.bw_in('9888888933',pg_temp.bw_wrong(:'bg5'),'203.0.113.35')='invalid_code','five wrong tries from five addresses');
SELECT pg_temp.bw_assert(pg_temp.bw_in('9888888933',:'bg5','203.0.113.36')='code_locked' AND NOT public.operator_break_glass_open('9888888933'),
  'after five wrong tries even the right code is code_locked');
SELECT pg_temp.bw_assert(pg_temp.bw_in('9888888933',pg_temp.bw_wrong(:'bg5'),'203.0.113.37')='invalid_code','and a wrong code for the locked number is plain invalid_code');

-- 8. Ten minutes.
SELECT pg_temp.bw_code('9888888933') AS bg6 \gset
UPDATE warehouse_security.break_glass_codes SET expires_at=now()+interval '1 second' WHERE used_at IS NULL AND phone_number='919888888933';
SELECT pg_temp.bw_assert(pg_temp.bw_in('9888888933',:'bg6','203.0.113.41')='login','a code with a second left still signs in');
SELECT pg_temp.bw_code('9888888933') AS bg7 \gset
UPDATE warehouse_security.break_glass_codes SET expires_at=now()-interval '1 second' WHERE used_at IS NULL AND phone_number='919888888933';
SELECT pg_temp.bw_assert(pg_temp.bw_in('9888888933',:'bg7','203.0.113.41')='code_expired','a code one second past its end is code_expired');
SELECT pg_temp.bw_assert(pg_temp.bw_in('9888888933',pg_temp.bw_wrong(:'bg7'),'203.0.113.42')='invalid_code','and a wrong code for the expired number is plain invalid_code');

-- 9. A customer is refused like an unknown number (invalid_code), also when a code row exists for the number, and counts against the source.
SELECT pg_temp.bw_assert(pg_temp.bw_in('9888888934','123456','203.0.113.51')='invalid_code','a customer gets invalid_code, as an unknown number does');
INSERT INTO warehouse_security.break_glass_codes(user_id,phone_number,code_hash,expires_at)
VALUES (:'customer_user'::uuid,'919888888934','x',now()+interval '5 minutes');
SELECT pg_temp.bw_assert(pg_temp.bw_in('9888888934','123456','203.0.113.51')='invalid_code','also when a code row was planted for the customer');
SELECT pg_temp.bw_assert((SELECT verify_failures=2 FROM public.ip_rate_limits WHERE ip_address='203.0.113.51'),'both refusals counted against the source');
SELECT pg_temp.bw_assert((SELECT count(*)=0 FROM warehouse_security.refresh_sessions WHERE user_id=:'customer_user'::uuid),'no session for the customer');

-- 10. The per-source failure limit refuses before a correct code is looked at; another address still signs in; a success counts nothing.
UPDATE warehouse_security.auth_config SET value='3' WHERE key='otp_source_hourly_failures';
SELECT pg_temp.bw_code('9888888938') AS bg8 \gset
SELECT pg_temp.bw_assert(pg_temp.bw_in('9888888938',pg_temp.bw_wrong(:'bg8'),'203.0.113.61')='invalid_code'
  AND pg_temp.bw_in('9888888938',pg_temp.bw_wrong(:'bg8'),'203.0.113.61')='invalid_code'
  AND pg_temp.bw_in('9888888938',pg_temp.bw_wrong(:'bg8'),'203.0.113.61')='invalid_code','three wrong tries from one address (its limit is 3)');
SELECT pg_temp.bw_assert(pg_temp.bw_in('9888888938',:'bg8','203.0.113.61')='rate_limited'
  AND (SELECT attempts=3 AND used_at IS NULL FROM warehouse_security.break_glass_codes WHERE phone_number='919888888938' AND used_at IS NULL AND expires_at>now()),
  'the right code from that address is rate_limited and was not looked at');
SELECT pg_temp.bw_assert(pg_temp.bw_in('9888888938',:'bg8','203.0.113.62')='login','from another address it signs in');
UPDATE warehouse_security.auth_config SET value='20' WHERE key='otp_source_hourly_failures';

-- 11. The 24 hours hold. A refresh answers, keeps the end, and never moves it later; at the end nothing refreshes and the session is gone.
SELECT pg_temp.bw_code('9888888933') AS bg9 \gset
SELECT public.operator_break_glass_sign_in('9888888933',:'bg9','203.0.113.71')#>>'{data,session,refresh_token}' AS r1 \gset
SELECT (pg_temp.bw_session(:'r1')).hard_expires_at AS hard1 \gset
SELECT public.refresh_jwt_token(:'r1') AS refreshed \gset
SELECT pg_temp.bw_assert(:'refreshed'::jsonb->>'success'='true','a refresh within the 24 hours answers');
SELECT :'refreshed'::jsonb->>'refresh_token' AS r2 \gset
SELECT pg_temp.bw_assert((pg_temp.bw_session(:'r2')).hard_expires_at=:'hard1'::timestamptz AND (pg_temp.bw_session(:'r2')).expires_at<=:'hard1'::timestamptz,
  'the refresh kept the hard end and did not slide past it');
-- Eight hours later, 30 days idle would be allowed; the end is still the 24th hour.
UPDATE warehouse_security.refresh_sessions SET created_at=created_at-interval '16 hours', hard_expires_at=hard_expires_at-interval '16 hours',
  expires_at=expires_at-interval '16 hours' WHERE token_hash=encode(extensions.digest(:'r2','sha256'),'hex');
SELECT public.refresh_jwt_token(:'r2')->>'refresh_token' AS r3 \gset
SELECT pg_temp.bw_assert((pg_temp.bw_session(:'r3')).expires_at<=(now()+interval '8 hours 2 minutes') AND (pg_temp.bw_session(:'r3')).expires_at>now()+interval '7 hours',
  'at the 16th hour the session still ends at the 24th hour, not 30 days later');
-- The 24th hour has passed.
UPDATE warehouse_security.refresh_sessions SET hard_expires_at=now()-interval '1 second', expires_at=now()-interval '1 second'
  WHERE token_hash=encode(extensions.digest(:'r3','sha256'),'hex');
SELECT pg_temp.bw_assert(pg_temp.bw_refresh(:'r3')<>'success','after the 24 hours the refresh is refused');
-- Belt and braces: a row whose expires_at was left ahead of its hard end is not refreshed either (issue_session checks hard_expires_at itself).
SELECT warehouse_security.issue_session(:'staff_user'::uuid)->>'refresh_token' AS r4 \gset
UPDATE warehouse_security.refresh_sessions SET hard_expires_at=now()-interval '1 second' WHERE token_hash=encode(extensions.digest(:'r4','sha256'),'hex');
SELECT pg_temp.bw_assert(pg_temp.bw_refresh(:'r4')<>'success','a session past its hard end is not renewed even if expires_at is later');
-- An ordinary session has no hard end and still slides.
SELECT warehouse_security.issue_session(:'other_user'::uuid)->>'refresh_token' AS rs \gset
SELECT pg_temp.bw_assert((pg_temp.bw_session(:'rs')).hard_expires_at IS NULL AND (pg_temp.bw_session(:'rs')).expires_at > now()+interval '29 days',
  'an ordinary session has no hard end and lasts the idle time (30 days)');

-- 12. The older code screen (operator_verify_otp) takes a worker's code too, and its session ends after 24 hours as well.
SELECT pg_temp.bw_code('9888888932') AS bg10 \gset
SELECT public.operator_verify_otp('9888888932',:'bg10',NULL,NULL,'203.0.113.81') AS via_otp \gset
SELECT pg_temp.bw_assert(:'via_otp'::jsonb#>>'{data,action}'='login' AND :'via_otp'::jsonb#>>'{data,user,role}'='supervisor'
  AND (pg_temp.bw_session(:'via_otp'::jsonb#>>'{data,session,refresh_token}')).hard_expires_at
    = (pg_temp.bw_session(:'via_otp'::jsonb#>>'{data,session,refresh_token}')).created_at + interval '24 hours'
  AND :'via_otp'::jsonb#>>'{data,session,session_ends_at}' IS NOT NULL,
  'a supervisor''s code on the SMS code screen signs in with a 24 hour session: '||:'via_otp');
SELECT pg_temp.bw_assert(public.operator_verify_otp('9888888932',:'bg10',NULL,NULL,'203.0.113.81')->>'code'='invalid_otp','and it works once there too');
SELECT pg_temp.bw_assert(public.operator_verify_otp('9888888934','123456',NULL,NULL,'203.0.113.82')->>'code'='invalid_otp','a customer''s number with a made-up code is refused there');
-- The SMS sign-in is unchanged: no hard end.
SELECT public.operator_prepare_otp('9888888938','203.0.113.91') AS challenge \gset
SELECT public.operator_finish_otp((:'challenge'::jsonb#>>'{data,request_id}')::uuid,true,'mock-provider-only') AS finished \gset
SELECT public.operator_verify_otp('9888888938',:'challenge'::jsonb#>>'{data,otp_code}',NULL,NULL,'203.0.113.91') AS via_sms \gset
SELECT pg_temp.bw_assert(:'via_sms'::jsonb#>>'{data,action}'='login' AND (pg_temp.bw_session(:'via_sms'::jsonb#>>'{data,session,refresh_token}')).hard_expires_at IS NULL
  AND :'via_sms'::jsonb#>>'{data,session,session_ends_at}' IS NULL,'an SMS sign-in still has an ordinary session');

-- 13. A new code ends the earlier open one, and the sign-in checks the account again: a worker who was switched off is refused.
SELECT pg_temp.bw_code('9888888933') AS bg11 \gset
SELECT pg_temp.bw_code('9888888933') AS bg12 \gset
SELECT pg_temp.bw_assert(:'bg11'=:'bg12' OR pg_temp.bw_in('9888888933',:'bg11','203.0.113.95') IN ('invalid_code','code_expired'),'the earlier code no longer signs in');
UPDATE public.user_profiles SET active=false WHERE id=:'staff_profile'::uuid;
SELECT pg_temp.bw_assert(pg_temp.bw_in('9888888933',:'bg12','203.0.113.96')='invalid_code' AND NOT public.operator_break_glass_open('9888888933'),
  'a switched-off worker is refused with a valid code');
UPDATE public.user_profiles SET active=true WHERE id=:'staff_profile'::uuid;
SELECT pg_temp.bw_assert(pg_temp.bw_in('9888888933',:'bg12','203.0.113.96')='login','and signs in when back');

-- 14. The operation is gated like the SMS verify: not in operator mode, it is unavailable.
UPDATE warehouse_security.auth_config SET value='demo' WHERE key='auth_mode';
SELECT pg_temp.bw_assert(public.operator_break_glass_sign_in('9888888933','123456',NULL)->>'code'='unavailable','outside operator mode the sign-in is unavailable');
UPDATE warehouse_security.auth_config SET value='operator' WHERE key='auth_mode';

ROLLBACK;
\echo 'Break-glass workers: administrators, supervisors and staff, never customers; refusal codes; once, ten minutes, five tries, source limit; 24 hour session that a refresh cannot extend; older code screen the same; service role only passed.'
