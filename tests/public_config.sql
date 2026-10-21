-- Migration 123 (B3): get-public-config reads the public configuration through public.get_public_config(text) with the anon key, not with
-- the service-role key. The function returns the version, the maintenance flag and the feature flags of the environment, to anon
-- and the service role only; a signed-in role and PUBLIC cannot call it; anon still cannot read the two tables directly (api_configurations).
-- Runs after all migrations in migrations.sh's disposable, network-disabled database; every fixture row rolls back.
\set ON_ERROR_STOP on
BEGIN;
CREATE FUNCTION pg_temp.pc_assert(ok boolean, label text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF NOT COALESCE(ok, false) THEN RAISE EXCEPTION 'public config: %', label; END IF; END $$;
SELECT pg_temp.pc_assert((SELECT count(*) = 1 AND bool_and(p.prosecdef AND p.provolatile = 's' AND p.proconfig::text LIKE '%search_path=%')
  FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace AND p.proname = 'get_public_config'), 'one function, SECURITY DEFINER, STABLE, with a search_path');
SELECT pg_temp.pc_assert(has_function_privilege('anon', 'public.get_public_config(text)', 'EXECUTE')
  AND has_function_privilege('service_role', 'public.get_public_config(text)', 'EXECUTE')
  AND NOT has_function_privilege('authenticated', 'public.get_public_config(text)', 'EXECUTE')
  AND (SELECT NOT EXISTS (SELECT 1 FROM aclexplode(proacl) a WHERE a.grantee = 0) FROM pg_proc WHERE oid = 'public.get_public_config(text)'::regprocedure),
  'granted to anon and the service role only, not to PUBLIC');
SELECT pg_temp.pc_assert(NOT has_table_privilege('anon', 'public.api_configurations', 'SELECT'), 'anon cannot read api_configurations directly');
INSERT INTO public.api_configurations(environment, app_version, maintenance_mode, is_active) VALUES ('pc_test', '9.8.7', true, true);
INSERT INTO public.feature_flags(name, enabled) VALUES ('pc_flag_on', true), ('pc_flag_off', false);
SET LOCAL ROLE anon;
SELECT public.get_public_config('pc_test')::jsonb AS answer, public.get_public_config('pc_none') IS NULL AS unknown_is_null \gset
RESET ROLE;
SELECT pg_temp.pc_assert(:'answer'::jsonb->>'app_version' = '9.8.7' AND (:'answer'::jsonb->>'maintenance_mode')::boolean
  AND (:'answer'::jsonb#>>'{feature_flags,pc_flag_on}')::boolean AND NOT (:'answer'::jsonb#>>'{feature_flags,pc_flag_off}')::boolean
  AND (SELECT count(*) = 6 + 2 FROM jsonb_object_keys(:'answer'::jsonb->'feature_flags')) -- the six seeded flags and the two above
  AND (SELECT count(*) = 3 FROM jsonb_object_keys(:'answer'::jsonb)), 'the answer carries exactly the version, the maintenance flag and the flags: ' || :'answer');
SELECT pg_temp.pc_assert(:'unknown_is_null'::boolean, 'an environment with no active row answers null (the edge function then says "not seeded")');
-- An inactive row is not shown.
UPDATE public.api_configurations SET is_active = false WHERE environment = 'pc_test';
SELECT pg_temp.pc_assert(public.get_public_config('pc_test') IS NULL, 'an inactive environment answers null');
SET LOCAL ROLE authenticated;
SELECT pg_temp.pc_assert(NOT has_function_privilege('public.get_public_config(text)', 'EXECUTE'), 'a signed-in role cannot call it');
RESET ROLE;
ROLLBACK;
