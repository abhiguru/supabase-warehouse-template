\set ON_ERROR_STOP on
BEGIN;
CREATE FUNCTION pg_temp.assert_true(ok boolean, label text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF ok IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAILED: %',label; END IF; END $$;

INSERT INTO warehouse_security.auth_config(key,value) VALUES
  ('jwt_secret','isolated-test-secret-not-for-any-deployment-12345'),('demo_auth_enabled','false');
SELECT pg_temp.assert_true(NOT (public.send_otp('0000000001')->>'success')::boolean,'demo auth is disabled by default');
UPDATE warehouse_security.auth_config SET value='true' WHERE key='demo_auth_enabled';
INSERT INTO public.user_profiles(id,auth_user_id,name,display_name,mobile,role,active) VALUES
  ('11111111-0000-4000-8000-000000000001','11111111-0000-4000-8000-000000000011','Test Admin','Test Admin','910000000001','admin',true),
  ('11111111-0000-4000-8000-000000000002','11111111-0000-4000-8000-000000000012','Test Customer','Test Customer','910000000002','customer',true),
  ('11111111-0000-4000-8000-000000000003','11111111-0000-4000-8000-000000000013','Inactive','Inactive','910000000003','customer',false);
INSERT INTO public.customers(id,name) VALUES
  ('22222222-0000-4000-8000-000000000001','Example Customer A'),
  ('22222222-0000-4000-8000-000000000002','Example Customer B');
INSERT INTO public.users_customers_new(user_profile_id,customer_id,active) VALUES
  ('11111111-0000-4000-8000-000000000002','22222222-0000-4000-8000-000000000001',true);

SET LOCAL ROLE anon;
DO $$ DECLARE login jsonb; refreshed jsonb; BEGIN
  PERFORM pg_temp.assert_true((public.send_otp('0000000002')->>'success')::boolean,'anonymous send OTP');
  PERFORM pg_temp.assert_true(NOT (public.verify_otp_or_register('0000000002','654321')->>'success')::boolean,'wrong OTP denied');
  login := public.verify_otp_or_register('0000000002','123456');
  PERFORM pg_temp.assert_true((login->>'success')::boolean,'correct OTP signs in');
  PERFORM pg_temp.assert_true(login#>>'{data,user,role}'='customer','customer role retained');
  PERFORM pg_temp.assert_true(NOT (public.verify_otp_or_register('0000000002','123456')->>'success')::boolean,'OTP replay denied');
  refreshed := public.refresh_jwt_token(login#>>'{data,session,refresh_token}');
  PERFORM pg_temp.assert_true((refreshed->>'success')::boolean,'opaque refresh accepted');
  PERFORM pg_temp.assert_true(refreshed->>'refresh_token'<>login#>>'{data,session,refresh_token}','refresh rotates its own session token');
  PERFORM pg_temp.assert_true(NOT (public.refresh_jwt_token(login#>>'{data,session,refresh_token}')->>'success')::boolean,'old refresh replay denied');
  PERFORM set_config('test.refresh',refreshed->>'refresh_token',true);
  PERFORM pg_temp.assert_true(NOT (public.refresh_jwt_token(repeat('0',64))->>'success')::boolean,'forged refresh denied');
  PERFORM public.send_otp('0000000003');
  PERFORM pg_temp.assert_true(NOT (public.verify_otp_or_register('0000000003','123456')->>'success')::boolean,'inactive account denied');
  BEGIN PERFORM * FROM public.customers; RAISE EXCEPTION 'anonymous customer read allowed'; EXCEPTION WHEN insufficient_privilege THEN NULL; END;
  BEGIN PERFORM * FROM public.jwt_config; RAISE EXCEPTION 'anonymous secret read allowed'; EXCEPTION WHEN insufficient_privilege THEN NULL; END;
  BEGIN PERFORM public.get_users_list(); RAISE EXCEPTION 'anonymous staff RPC allowed'; EXCEPTION WHEN insufficient_privilege THEN NULL; END;
END $$;
RESET ROLE;

DO $$ DECLARE claims jsonb; BEGIN
  SELECT jsonb_build_object('role','authenticated','sub',user_id,'session_id',id) INTO claims
    FROM warehouse_security.refresh_sessions WHERE user_id='11111111-0000-4000-8000-000000000012';
  PERFORM set_config('request.jwt.claims',claims::text,true);
END $$;
SET LOCAL ROLE authenticated;
SELECT public.check_session();
SELECT pg_temp.assert_true((SELECT count(*)=1 FROM public.customers),'customer sees only assigned customer');
SELECT pg_temp.assert_true((SELECT count(*)=1 FROM public.user_profiles),'customer sees only own active profile');
SELECT pg_temp.assert_true((SELECT count(*)=0 FROM public.customers WHERE id='22222222-0000-4000-8000-000000000002'),'cross-customer direct read denied');
DO $$ DECLARE result jsonb; BEGIN
  BEGIN UPDATE public.user_profiles SET role='admin'; RAISE EXCEPTION 'customer self-promotion allowed'; EXCEPTION WHEN insufficient_privilege THEN NULL; END;
  BEGIN PERFORM * FROM warehouse_security.auth_config; RAISE EXCEPTION 'customer signing-secret read allowed'; EXCEPTION WHEN insufficient_privilege THEN NULL; END;
  BEGIN
    result := public.get_customer_stock_summary('22222222-0000-4000-8000-000000000002');
    PERFORM pg_temp.assert_true(result->>'success'='false','cross-customer RPC returns no data');
  EXCEPTION WHEN insufficient_privilege THEN NULL; END;
  BEGIN
    result := public.get_users_list();
    PERFORM pg_temp.assert_true(result->>'success'='false','customer staff RPC denied');
  EXCEPTION WHEN insufficient_privilege THEN NULL; END;
  PERFORM public.logout_session(current_setting('test.refresh'));
  BEGIN PERFORM public.check_session(); RAISE EXCEPTION 'revoked access session accepted'; EXCEPTION WHEN insufficient_privilege THEN NULL; END;
  PERFORM pg_temp.assert_true((SELECT count(*)=0 FROM public.customers),'revoked session loses RLS access');
END $$;
RESET ROLE;

-- Effective grants include PUBLIC inheritance, not merely explicit role grants.
SELECT pg_temp.assert_true(NOT EXISTS (
  SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
  WHERE n.nspname='public' AND has_function_privilege('anon',p.oid,'EXECUTE')
    AND p.proname NOT IN ('send_otp','verify_otp_or_register','refresh_jwt_token','logout_session','check_session')
),'anonymous function allowlist');
SELECT pg_temp.assert_true(NOT EXISTS (
  SELECT 1 FROM pg_matviews WHERE schemaname='public' AND NOT ispopulated
),'all materialized views are queryable');
ROLLBACK;
SELECT 'auth, refresh, revocation and cross-customer access tests passed' AS result;
