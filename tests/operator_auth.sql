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
SELECT pg_temp.assert_true((public.operator_prepare_otp('9888888801')->>'code')='resend_cooldown','resend is bounded');
SELECT pg_temp.assert_true((public.operator_verify_otp('9888888801','000000')->>'code')='invalid_otp'
  OR (:'challenge'::jsonb#>>'{data,otp_code}')='000000','wrong OTP denied');
SELECT public.operator_verify_otp('9888888801',:'challenge'::jsonb#>>'{data,otp_code}') AS admin_login \gset
SELECT pg_temp.assert_true(:'admin_login'::jsonb#>>'{data,action}'='login','verified bootstrap admin signs in');
SELECT pg_temp.assert_true((public.operator_verify_otp('9888888801',:'challenge'::jsonb#>>'{data,otp_code}')->>'success')='false','OTP replay denied');
SELECT public.refresh_jwt_token(:'admin_login'::jsonb#>>'{data,session,refresh_token}') AS admin_refresh \gset
SELECT pg_temp.assert_true(:'admin_refresh'::jsonb->>'success'='true','operator session refreshes');
SELECT pg_temp.assert_true((public.refresh_jwt_token(:'admin_login'::jsonb#>>'{data,session,refresh_token}')->>'success')='false','refresh token rotates and cannot replay');

SELECT public.operator_prepare_otp('9888888804') AS failed_delivery \gset
SELECT public.operator_finish_otp((:'failed_delivery'::jsonb#>>'{data,request_id}')::uuid,false);
SELECT pg_temp.assert_true((public.operator_verify_otp('9888888804',:'failed_delivery'::jsonb#>>'{data,otp_code}')->>'success')='false','provider failure seals challenge');
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
ROLLBACK;
