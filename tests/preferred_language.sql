-- The language a person chose is kept on their own profile (migration 38).
-- Runs ONLY in migrations.sh's fresh, network-disabled database. All fixture rows roll back.
\set ON_ERROR_STOP on
BEGIN;
CREATE FUNCTION pg_temp.language_assert(ok boolean, label text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF NOT COALESCE(ok, false) THEN RAISE EXCEPTION 'preferred language: %', label; END IF; END $$;
CREATE FUNCTION pg_temp.language_login(phone text) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE challenge jsonb; login jsonb; claims jsonb;
BEGIN
  challenge := public.operator_prepare_otp(phone);
  PERFORM public.operator_finish_otp((challenge#>>'{data,request_id}')::uuid, true, 'mock-provider-only');
  login := public.operator_verify_otp(phone, challenge#>>'{data,otp_code}');
  PERFORM pg_temp.language_assert(login#>>'{data,action}' = 'login', 'login ' || phone);
  SELECT jsonb_build_object('role', 'authenticated', 'sub', p.auth_user_id, 'session_id', s.id)
    INTO claims FROM public.user_profiles p JOIN warehouse_security.refresh_sessions s ON s.user_id = p.auth_user_id
    WHERE p.mobile = warehouse_security.normalize_phone(phone) ORDER BY s.created_at DESC LIMIT 1;
  RETURN claims;
END $$;
-- The stored value, read as the table owner.
CREATE FUNCTION pg_temp.stored(phone text) RETURNS text LANGUAGE sql SECURITY DEFINER AS $$
  SELECT COALESCE(preferred_language, '(none)') FROM public.user_profiles WHERE mobile = warehouse_security.normalize_phone(phone) $$;

INSERT INTO warehouse_security.auth_config(key, value) VALUES
 ('jwt_secret', 'isolated-test-secret-not-for-any-deployment-12345'), ('auth_mode', 'operator'), ('demo_auth_enabled', 'false')
 ON CONFLICT(key) DO UPDATE SET value = excluded.value;
UPDATE public.sms_config SET provider = 'msg91', production_mode = true, msg91_auth_key = 'isolated-test-key',
 msg91_template_id = '000000000000000000000001', msg91_pe_id = '0000000000000000001', msg91_sender_id = 'CITEST';
SELECT warehouse_security.bootstrap_first_admin('9888888661', 'Language Administrator');
INSERT INTO public.user_profiles(auth_user_id, mobile, name, role, active, enrollment_status) VALUES
 (gen_random_uuid(), '919888888664', 'Language Customer', 'customer', true, 'approved');
SELECT pg_temp.language_login('9888888661') AS admin_claims \gset
SELECT pg_temp.language_login('9888888664') AS customer_claims \gset

SELECT pg_temp.language_assert(pg_temp.stored('9888888661') = '(none)' AND pg_temp.stored('9888888664') = '(none)', 'no language to start with');
SELECT pg_temp.language_assert(NOT has_function_privilege('anon', 'public.set_my_language(text)', 'execute')
  AND NOT has_function_privilege('anon', 'public.get_my_language()', 'execute'), 'not callable without signing in');
SELECT pg_temp.language_assert(NOT has_function_privilege('authenticated', 'warehouse_security.own_profile_id()', 'execute'), 'helper is not an API function');

-- The customer chooses Gujarati: only their own profile changes.
SELECT set_config('request.jwt.claims', :'customer_claims', true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.language_assert(public.get_my_language() = '{"success": true, "language": null}'::jsonb, 'unset reads as null');
SELECT pg_temp.language_assert(public.set_my_language('gu') = '{"success": true, "language": "gu"}'::jsonb, 'set Gujarati');
SELECT pg_temp.language_assert(public.get_my_language()->>'language' = 'gu', 'reads back Gujarati');
RESET ROLE;
SELECT pg_temp.language_assert(pg_temp.stored('9888888664') = 'gu', 'stored on the customer');
SELECT pg_temp.language_assert(pg_temp.stored('9888888661') = '(none)', 'the administrator is untouched');

-- The administrator chooses English, then an unknown value, then clears the choice.
SELECT set_config('request.jwt.claims', :'admin_claims', true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.language_assert(public.set_my_language('en')->>'success' = 'true', 'set English');
SELECT pg_temp.language_assert(public.set_my_language('fr') = '{"success": false, "error": "Unknown language", "code": "UNKNOWN_LANGUAGE"}'::jsonb, 'unknown language refused');
SELECT pg_temp.language_assert(public.get_my_language()->>'language' = 'en', 'a refused value changes nothing');
SELECT pg_temp.language_assert(public.set_my_language(NULL)->>'success' = 'true', 'clear');
SELECT pg_temp.language_assert(public.get_my_language()->'language' = 'null'::jsonb, 'cleared reads as null');
RESET ROLE;
SELECT pg_temp.language_assert(pg_temp.stored('9888888664') = 'gu', 'the customer keeps Gujarati');

-- The table itself refuses an unknown value.
DO $$ BEGIN
  UPDATE public.user_profiles SET preferred_language = 'fr' WHERE mobile = '919888888664';
  RAISE EXCEPTION 'preferred language: the table accepted an unknown value';
EXCEPTION WHEN check_violation THEN NULL; END $$;

-- A disabled profile cannot read or write while its session row still exists.
-- (update_user_status(false) also removes the sessions; this is the profile check alone.)
UPDATE public.user_profiles SET active = false WHERE mobile = '919888888664';
SELECT set_config('request.jwt.claims', :'customer_claims', true);
SET LOCAL ROLE authenticated;
DO $$ BEGIN
  PERFORM public.set_my_language('en');
  RAISE EXCEPTION 'preferred language: a disabled profile could write';
EXCEPTION WHEN insufficient_privilege THEN NULL; END $$;
DO $$ BEGIN
  PERFORM public.get_my_language();
  RAISE EXCEPTION 'preferred language: a disabled profile could read';
EXCEPTION WHEN insufficient_privilege THEN NULL; END $$;
DO $$ BEGIN
  PERFORM public.check_session();
  RAISE EXCEPTION 'preferred language: the request hook let a disabled profile through';
EXCEPTION WHEN insufficient_privilege THEN NULL; END $$;
RESET ROLE;
SELECT pg_temp.language_assert(pg_temp.stored('9888888664') = 'gu', 'a disabled profile changed nothing');
UPDATE public.user_profiles SET active = true WHERE mobile = '919888888664';

-- A profile whose enrollment is not approved never reaches an RPC: PostgREST
-- runs public.check_session before every request and it refuses the session.
-- own_profile_id() itself does not look at the enrollment state.
UPDATE public.user_profiles SET enrollment_status = 'pending' WHERE mobile = '919888888664';
SELECT set_config('request.jwt.claims', :'customer_claims', true);
SET LOCAL ROLE authenticated;
DO $$ BEGIN
  PERFORM public.check_session();
  RAISE EXCEPTION 'preferred language: the request hook let a pending profile through';
EXCEPTION WHEN insufficient_privilege THEN NULL; END $$;
RESET ROLE;
UPDATE public.user_profiles SET enrollment_status = 'approved' WHERE mobile = '919888888664';
SELECT set_config('request.jwt.claims', :'customer_claims', true);
SET LOCAL ROLE authenticated;
SELECT public.check_session();
SELECT pg_temp.language_assert(public.get_my_language()->>'language' = 'gu', 'the approved, active profile reads again');
RESET ROLE;

-- A session that has ended cannot read or write.
DELETE FROM warehouse_security.refresh_sessions WHERE id = (:'customer_claims'::jsonb->>'session_id')::uuid;
SELECT set_config('request.jwt.claims', :'customer_claims', true);
SET LOCAL ROLE authenticated;
DO $$ BEGIN
  PERFORM public.set_my_language('en');
  RAISE EXCEPTION 'preferred language: an ended session could write';
EXCEPTION WHEN insufficient_privilege THEN NULL; END $$;
DO $$ BEGIN
  PERFORM public.get_my_language();
  RAISE EXCEPTION 'preferred language: an ended session could read';
EXCEPTION WHEN insufficient_privilege THEN NULL; END $$;
RESET ROLE;
SELECT pg_temp.language_assert(pg_temp.stored('9888888664') = 'gu', 'an ended session changed nothing');
ROLLBACK;
SELECT 'preferred language passed' AS result;
