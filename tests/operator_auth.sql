\set ON_ERROR_STOP on
BEGIN;
CREATE FUNCTION pg_temp.assert_true(ok boolean, message text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF NOT COALESCE(ok,false) THEN RAISE EXCEPTION 'operator auth: %',message; END IF; END $$;

INSERT INTO warehouse_security.auth_config(key,value) VALUES
  ('jwt_secret','isolated-test-secret-not-for-any-deployment-12345'),
  ('auth_mode','operator'),('demo_auth_enabled','false')
ON CONFLICT(key) DO UPDATE SET value=excluded.value;

SELECT pg_temp.assert_true(NOT (public.send_otp('919888888801')->>'success')::boolean,'demo send is unavailable');
SELECT pg_temp.assert_true(NOT (public.verify_otp_or_register('919888888801','123456')->>'success')::boolean,'fixed demo OTP is unavailable');
SELECT pg_temp.assert_true(NOT has_function_privilege('anon','public.send_otp(varchar,varchar,text,inet,text)','EXECUTE'),'anon cannot call historical demo send');
SELECT pg_temp.assert_true(NOT has_function_privilege('anon','public.verify_otp_or_register(varchar,varchar,varchar,varchar)','EXECUTE'),'anon cannot call historical demo verify');
SELECT pg_temp.assert_true(NOT has_function_privilege('anon','public.operator_prepare_otp(text,inet)','EXECUTE'),'anon cannot prepare OTP');
SELECT pg_temp.assert_true(NOT has_function_privilege('anon','public.operator_sms_config()','EXECUTE'),'anon cannot read provider credentials');
SELECT pg_temp.assert_true(NOT has_function_privilege('authenticated','public.operator_sms_config()','EXECUTE'),'users cannot read provider credentials');
SELECT pg_temp.assert_true(NOT has_table_privilege('anon','public.sms_config','SELECT'),'anon cannot read SMS config');
SELECT pg_temp.assert_true(NOT has_table_privilege('authenticated','public.sms_config','SELECT'),'users cannot read SMS config');
UPDATE public.sms_config SET provider='msg91',production_mode=true,msg91_auth_key='isolated-test-key',
  msg91_template_id='694a8ea0cd30ae1f432f445a',msg91_pe_id='1101817660000088076',msg91_sender_id='GCSAMD'
  WHERE id=(SELECT id FROM public.sms_config ORDER BY id DESC LIMIT 1);
SELECT pg_temp.assert_true((public.operator_sms_config()#>>'{data,flow_id}')='694a8ea0cd30ae1f432f445a',
  'worker reads the latest protected Flow ID');
SELECT pg_temp.assert_true(NOT has_function_privilege('authenticated','public.operator_verify_otp(text,text,text,text)','EXECUTE'),'authenticated cannot bypass provider');
SELECT pg_temp.assert_true(NOT has_function_privilege('anon','public.operator_review_enrollment(uuid,text,uuid[])','EXECUTE'),'anon cannot approve');

SELECT warehouse_security.bootstrap_first_admin('9888888801','Test Administrator') AS admin_user \gset
SELECT pg_temp.assert_true((SELECT mobile_verified=false FROM public.user_profiles WHERE auth_user_id=:'admin_user'::uuid),'bootstrap requires real verification');
DO $$ BEGIN
  BEGIN
    PERFORM warehouse_security.bootstrap_first_admin('9888888802','Second Administrator');
    RAISE EXCEPTION 'second admin bootstrap was accepted';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM='second admin bootstrap was accepted' THEN RAISE; END IF;
  END;
END $$;

SELECT public.operator_prepare_otp('9888888801') AS challenge \gset
SELECT pg_temp.assert_true(:'challenge'::jsonb->>'success'='true','admin OTP prepared');
SELECT pg_temp.assert_true((public.operator_prepare_otp('9888888801')->>'code')='resend_cooldown',
  'in-flight delivery blocks a second SMS challenge');
SELECT public.operator_finish_otp((:'challenge'::jsonb#>>'{data,request_id}')::uuid,true,'provider-accepted');
SELECT pg_temp.assert_true((SELECT delivery_status='accepted' AND msg91_status='success'
  AND msg91_request_id='provider-accepted' AND otp_code IS NULL AND otp_hash IS NULL
  AND otp_code_hash ~ '^[0-9a-f]{64}$' FROM public.otp_verifications
  WHERE id=(:'challenge'::jsonb#>>'{data,request_id}')::uuid),
  'accepted delivery stores a provider ID and hash only');
SELECT pg_temp.assert_true((public.operator_prepare_otp('9888888801')->>'code')='resend_cooldown','resend is bounded');
SELECT pg_temp.assert_true((public.operator_verify_otp('9888888801','000000')->>'code')='invalid_otp'
  OR (:'challenge'::jsonb#>>'{data,otp_code}')='000000','wrong OTP denied');
SELECT public.operator_verify_otp('9888888801',:'challenge'::jsonb#>>'{data,otp_code}') AS admin_login \gset
SELECT pg_temp.assert_true(:'admin_login'::jsonb#>>'{data,action}'='login','verified bootstrap admin signs in');
SELECT pg_temp.assert_true((public.operator_verify_otp('9888888801',:'challenge'::jsonb#>>'{data,otp_code}')->>'success')='false','OTP replay denied');
SELECT public.refresh_jwt_token(:'admin_login'::jsonb#>>'{data,session,refresh_token}') AS admin_refresh \gset
SELECT pg_temp.assert_true(:'admin_refresh'::jsonb->>'success'='true','operator session refreshes');
-- Migration 44: a retry of the rotation just made returns the same successor;
-- once the grace period is over the old token is reuse and ends the session
-- (tests/refresh_reuse.sql covers the rest).
SELECT pg_temp.assert_true((public.refresh_jwt_token(:'admin_login'::jsonb#>>'{data,session,refresh_token}')->>'refresh_token')
  =(:'admin_refresh'::jsonb->>'refresh_token'),'refresh token rotates; an immediate retry gets the same successor');
SAVEPOINT refresh_replay;
UPDATE warehouse_security.consumed_refresh_tokens SET consumed_at=now()-interval '61 seconds';
SELECT pg_temp.assert_true((public.refresh_jwt_token(:'admin_login'::jsonb#>>'{data,session,refresh_token}')->>'success')='false','refresh token rotates and cannot replay');
SELECT pg_temp.assert_true((public.refresh_jwt_token(:'admin_refresh'::jsonb->>'refresh_token')->>'success')='false','a replayed refresh token ends the session');
ROLLBACK TO SAVEPOINT refresh_replay;

SELECT public.operator_prepare_otp('9888888804') AS failed_delivery \gset
SELECT public.operator_finish_otp((:'failed_delivery'::jsonb#>>'{data,request_id}')::uuid,false,'provider_auth');
SELECT pg_temp.assert_true((SELECT delivery_status='failed' AND msg91_status='provider_auth'
  AND msg91_request_id IS NULL AND otp_code_hash IS NULL FROM public.otp_verifications
  WHERE id=(:'failed_delivery'::jsonb#>>'{data,request_id}')::uuid),
  'rejected delivery records a safe code without retaining OTP material');
SELECT pg_temp.assert_true((public.operator_verify_otp('9888888804',:'failed_delivery'::jsonb#>>'{data,otp_code}')->>'success')='false','provider failure seals challenge');
SELECT public.operator_prepare_otp('9888888806') AS late_delivery \gset
UPDATE public.otp_verifications SET expires_at=now()-interval '1 second'
  WHERE id=(:'late_delivery'::jsonb#>>'{data,request_id}')::uuid;
SELECT pg_temp.assert_true((public.operator_finish_otp((:'late_delivery'::jsonb#>>'{data,request_id}')::uuid,true,'late-provider-id')->>'success')='false',
  'late provider acceptance cannot activate expired OTP');
SELECT pg_temp.assert_true((SELECT delivery_status='failed' AND verified AND otp_code_hash IS NULL
  FROM public.otp_verifications WHERE id=(:'late_delivery'::jsonb#>>'{data,request_id}')::uuid),
  'expired challenge is sealed');
DO $$ DECLARE n integer; outcome jsonb; BEGIN
  FOR n IN 1..30 LOOP
    outcome:=public.operator_prepare_otp('988899'||lpad(n::text,4,'0'),'203.0.113.10');
    IF outcome->>'success'<>'true' THEN RAISE EXCEPTION 'IP rate test failed before threshold'; END IF;
  END LOOP;
  outcome:=public.operator_prepare_otp('9888990031','203.0.113.10');
  IF outcome->>'code'<>'rate_limited' THEN RAISE EXCEPTION 'IP rate threshold not enforced'; END IF;
END $$;
SELECT public.operator_prepare_otp('9888888805') AS attempt_limit \gset
SELECT public.operator_finish_otp((:'attempt_limit'::jsonb#>>'{data,request_id}')::uuid,true,'provider-accepted');
DO $$ DECLARE attempt integer; BEGIN
  FOR attempt IN 1..5 LOOP
    PERFORM public.operator_verify_otp('9888888805','not-an-otp');
  END LOOP;
END $$;
SELECT pg_temp.assert_true((public.operator_verify_otp('9888888805',:'attempt_limit'::jsonb#>>'{data,otp_code}')->>'success')='false','attempt cap denies even correct OTP');

SELECT public.operator_prepare_otp('9888888803') AS challenge_pending \gset
SELECT public.operator_finish_otp((:'challenge_pending'::jsonb#>>'{data,request_id}')::uuid,true,'provider-accepted');
SELECT public.operator_verify_otp('9888888803',:'challenge_pending'::jsonb#>>'{data,otp_code}','Pending Customer') AS pending_login \gset
SELECT pg_temp.assert_true(:'pending_login'::jsonb#>>'{data,action}'='pending','unknown verified user is pending');
SELECT pg_temp.assert_true(NOT (:'pending_login'::jsonb#>'{data}') ? 'session','pending enrollment has no warehouse session');
SELECT pg_temp.assert_true((SELECT active=false AND enrollment_status='pending' FROM public.user_profiles
  WHERE id=(:'pending_login'::jsonb#>>'{data,user,id}')::uuid),'pending profile inactive');
SELECT pg_temp.assert_true((public.operator_enrollment_status(:'pending_login'::jsonb#>>'{data,enrollment_token}')#>>'{data,status}')='pending','pending token reports status');

INSERT INTO public.customers(name) VALUES ('Operator Auth Test Customer') RETURNING id AS customer_id \gset
SELECT set_config('request.jwt.claims',jsonb_build_object('role','authenticated','sub',:'admin_user',
  'session_id',(SELECT id FROM warehouse_security.refresh_sessions WHERE user_id=:'admin_user'::uuid LIMIT 1))::text,true);
SET LOCAL ROLE authenticated;
SELECT set_config('warehouse_test.pending_user',:'pending_login'::jsonb#>>'{data,user,id}',true);
DO $$ BEGIN
  BEGIN
    PERFORM public.operator_review_enrollment(current_setting('warehouse_test.pending_user')::uuid,'approved',NULL::uuid[]);
    RAISE EXCEPTION 'approval without customer assignment was accepted';
  EXCEPTION WHEN invalid_parameter_value THEN NULL; END;
END $$;
SELECT public.operator_review_enrollment((:'pending_login'::jsonb#>>'{data,user,id}')::uuid,'approved',ARRAY[:'customer_id'::uuid]);
RESET ROLE;
SELECT pg_temp.assert_true((public.operator_enrollment_status(:'pending_login'::jsonb#>>'{data,enrollment_token}')#>>'{data,status}')='approved','enrollment token sees approval');
SELECT pg_temp.assert_true((SELECT count(*)=1 FROM public.users_customers_new WHERE user_profile_id=(:'pending_login'::jsonb#>>'{data,user,id}')::uuid AND active),'approval assigned customer');
SELECT pg_temp.assert_true((SELECT active AND enrollment_status='approved' FROM public.user_profiles WHERE id=(:'pending_login'::jsonb#>>'{data,user,id}')::uuid),'approval activates user');

UPDATE public.otp_verifications SET created_at=now()-interval '61 seconds'
  WHERE id=(:'challenge_pending'::jsonb#>>'{data,request_id}')::uuid;
SELECT public.operator_prepare_otp('9888888803') AS approved_challenge \gset
SELECT public.operator_finish_otp((:'approved_challenge'::jsonb#>>'{data,request_id}')::uuid,true,'provider-accepted');
SELECT public.operator_verify_otp('9888888803',:'approved_challenge'::jsonb#>>'{data,otp_code}') AS customer_login \gset
SELECT pg_temp.assert_true(:'customer_login'::jsonb#>>'{data,action}'='login','approved customer signs in with fresh OTP');
SELECT id AS customer_session_id FROM warehouse_security.refresh_sessions
  WHERE user_id=(:'customer_login'::jsonb#>>'{data,user,auth_user_id}')::uuid LIMIT 1 \gset
SELECT set_config('request.jwt.claims',jsonb_build_object('role','authenticated',
  'sub',:'customer_login'::jsonb#>>'{data,user,auth_user_id}',
  'session_id',:'customer_session_id')::text,true);
SET LOCAL ROLE authenticated;
SELECT public.check_session();
SELECT pg_temp.assert_true((SELECT count(*)=1 FROM public.customers),'approved customer sees only assigned records');
RESET ROLE;
SELECT set_config('request.jwt.claims',jsonb_build_object('role','authenticated','sub',:'admin_user',
  'session_id',(SELECT id FROM warehouse_security.refresh_sessions WHERE user_id=:'admin_user'::uuid LIMIT 1))::text,true);

SET LOCAL ROLE authenticated;
SELECT public.operator_review_enrollment((:'pending_login'::jsonb#>>'{data,user,id}')::uuid,'disabled');
RESET ROLE;
SELECT pg_temp.assert_true((SELECT NOT active AND enrollment_status='disabled' FROM public.user_profiles WHERE id=(:'pending_login'::jsonb#>>'{data,user,id}')::uuid),'disable deactivates user');
SELECT pg_temp.assert_true((SELECT count(*)=0 FROM public.users_customers_new WHERE user_profile_id=(:'pending_login'::jsonb#>>'{data,user,id}')::uuid AND active),'disable revokes assignments');
SELECT pg_temp.assert_true((public.refresh_jwt_token(:'customer_login'::jsonb#>>'{data,session,refresh_token}')->>'success')='false','disabled user cannot refresh');
SELECT set_config('request.jwt.claims',jsonb_build_object('role','authenticated',
  'sub',:'customer_login'::jsonb#>>'{data,user,auth_user_id}',
  'session_id',:'customer_session_id')::text,true);
SET LOCAL ROLE authenticated;
DO $$ BEGIN
  BEGIN PERFORM public.check_session(); RAISE EXCEPTION 'disabled session accepted';
  EXCEPTION WHEN insufficient_privilege THEN NULL; END;
  PERFORM pg_temp.assert_true((SELECT count(*)=0 FROM public.customers),'disabled user loses customer RLS access');
END $$;
RESET ROLE;
SELECT public.operator_enrollment_signout(:'pending_login'::jsonb#>>'{data,enrollment_token}');
SELECT pg_temp.assert_true((public.operator_enrollment_status(:'pending_login'::jsonb#>>'{data,enrollment_token}')->>'success')='false','signout invalidates enrollment token');

-- Migration 27: a resend keeps the earlier code valid, wrong attempts are
-- shared across live codes, success consumes all of them, and the warehouse
-- hourly cap is configurable.
SELECT public.operator_prepare_otp('9888888807') AS first_code \gset
SELECT public.operator_finish_otp((:'first_code'::jsonb#>>'{data,request_id}')::uuid,true,'provider-accepted');
UPDATE public.otp_verifications SET created_at=now()-interval '61 seconds'
  WHERE id=(:'first_code'::jsonb#>>'{data,request_id}')::uuid;
SELECT public.operator_prepare_otp('9888888807') AS second_code \gset
SELECT pg_temp.assert_true(:'second_code'::jsonb->>'success'='true','resend after cooldown');
SELECT public.operator_finish_otp((:'second_code'::jsonb#>>'{data,request_id}')::uuid,true,'provider-accepted');
SELECT pg_temp.assert_true((SELECT NOT verified AND otp_code_hash IS NOT NULL FROM public.otp_verifications
  WHERE id=(:'first_code'::jsonb#>>'{data,request_id}')::uuid),'resend keeps the earlier code valid');
DO $$ DECLARE n integer; BEGIN
  FOR n IN 1..3 LOOP PERFORM public.operator_verify_otp('9888888807','not-an-otp'); END LOOP;
END $$;
SELECT public.operator_verify_otp('9888888807',:'first_code'::jsonb#>>'{data,otp_code}','Resend Customer') AS first_login \gset
SELECT pg_temp.assert_true(:'first_login'::jsonb#>>'{data,action}'='pending','earlier code still verifies after a resend');
SELECT pg_temp.assert_true((public.operator_verify_otp('9888888807',:'second_code'::jsonb#>>'{data,otp_code}')->>'success')='false','later code is consumed by the successful verification');
SELECT public.operator_prepare_otp('9888888808') AS cap_first \gset
SELECT public.operator_finish_otp((:'cap_first'::jsonb#>>'{data,request_id}')::uuid,true,'provider-accepted');
UPDATE public.otp_verifications SET created_at=now()-interval '61 seconds'
  WHERE id=(:'cap_first'::jsonb#>>'{data,request_id}')::uuid;
SELECT public.operator_prepare_otp('9888888808') AS cap_second \gset
SELECT public.operator_finish_otp((:'cap_second'::jsonb#>>'{data,request_id}')::uuid,true,'provider-accepted');
DO $$ DECLARE n integer; BEGIN
  FOR n IN 1..5 LOOP PERFORM public.operator_verify_otp('9888888808','not-an-otp'); END LOOP;
END $$;
SELECT pg_temp.assert_true((public.operator_verify_otp('9888888808',:'cap_second'::jsonb#>>'{data,otp_code}')->>'success')='false','attempt cap is shared across live codes');
SELECT pg_temp.assert_true((SELECT value='300' FROM warehouse_security.auth_config WHERE key='otp_global_hourly_cap'),'global cap defaults to 300');
UPDATE warehouse_security.auth_config SET value='2' WHERE key='otp_global_hourly_cap';
UPDATE warehouse_security.operator_otp_global_limit SET hourly_count=0,window_started=now() WHERE id;
SELECT pg_temp.assert_true((public.operator_prepare_otp('9888888811')->>'success')='true','configurable cap: first request');
SELECT pg_temp.assert_true((public.operator_prepare_otp('9888888812')->>'success')='true','configurable cap: second request');
SELECT pg_temp.assert_true((public.operator_prepare_otp('9888888813')->>'code')='rate_limited','configurable cap enforced');
UPDATE warehouse_security.auth_config SET value='300' WHERE key='otp_global_hourly_cap';
ROLLBACK;
