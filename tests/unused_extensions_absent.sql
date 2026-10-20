-- Migration 103: the extensions http, pg_net, pg_graphql and supabase_vault are gone, with everything they brought:
-- public.http_post, the schemas net, graphql, graphql_public, vault and supabase_functions, the role
-- supabase_functions_admin, and the event triggers that would have put a GraphQL stand-in or pg_net grants back.
-- anon sees no graphql function and cannot call one. PostgREST's own event triggers are still there.
-- Runs after all migrations in migrations.sh's disposable, network-disabled database; it writes nothing.
\set ON_ERROR_STOP on
BEGIN;
CREATE FUNCTION pg_temp.ue_assert(ok boolean, label text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF NOT COALESCE(ok, false) THEN RAISE EXCEPTION 'unused extensions: %', label; END IF; END $$;
CREATE FUNCTION pg_temp.ue_outcome(role_name text, statement text) RETURNS text LANGUAGE plpgsql AS $$
DECLARE answer text;
BEGIN
  EXECUTE format('SET LOCAL ROLE %I', role_name);
  BEGIN EXECUTE statement; answer := 'ok';
  EXCEPTION WHEN OTHERS THEN answer := SQLSTATE; END;
  RESET ROLE;
  RETURN answer;
END $$;

SELECT pg_temp.ue_assert(NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname IN ('http', 'pg_net', 'pg_graphql', 'supabase_vault')),
  'an unused extension is installed: ' || coalesce((SELECT string_agg(extname, ', ') FROM pg_extension WHERE extname IN ('http', 'pg_net', 'pg_graphql', 'supabase_vault')), ''));
SELECT pg_temp.ue_assert(NOT EXISTS (SELECT 1 FROM pg_proc WHERE pronamespace = 'public'::regnamespace AND proname IN ('http_post', 'http_get', 'http', 'http_put', 'http_delete', 'http_patch', 'http_head')),
  'a public.http_* function is left');
SELECT pg_temp.ue_assert(to_regprocedure('public.http_post(character varying,character varying,character varying)') IS NULL, 'public.http_post exists');
SELECT pg_temp.ue_assert(NOT EXISTS (SELECT 1 FROM pg_namespace WHERE nspname IN ('net', 'graphql', 'graphql_public', 'vault', 'supabase_functions')),
  'a schema of the removed extensions exists: ' || coalesce((SELECT string_agg(nspname, ', ') FROM pg_namespace WHERE nspname IN ('net', 'graphql', 'graphql_public', 'vault', 'supabase_functions')), ''));
SELECT pg_temp.ue_assert(to_regrole('supabase_functions_admin') IS NULL, 'the role supabase_functions_admin exists');
-- The unrelated application table keeps its name.
SELECT pg_temp.ue_assert(to_regclass('public.secrets_vault') IS NOT NULL, 'public.secrets_vault was dropped');

-- The event triggers: none of the three that react to the removed extensions, and not their functions;
-- PostgREST's schema-cache triggers stay.
SELECT pg_temp.ue_assert(NOT EXISTS (SELECT 1 FROM pg_event_trigger WHERE evtname IN ('issue_graphql_placeholder', 'issue_pg_graphql_access', 'issue_pg_net_access', 'graphql_watch_ddl', 'graphql_watch_drop')),
  'an event trigger of pg_graphql or pg_net is left');
SELECT pg_temp.ue_assert(NOT EXISTS (SELECT 1 FROM pg_proc WHERE proname IN ('set_graphql_placeholder', 'grant_pg_graphql_access', 'grant_pg_net_access')),
  'a function of those event triggers is left');
SELECT pg_temp.ue_assert((SELECT count(*) FROM pg_event_trigger WHERE evtname IN ('pgrst_ddl_watch', 'pgrst_drop_watch')) = 0, 'a PostgREST event trigger is present: the baseline strips them and the bootstrap makes none');

-- anon cannot see a graphql function, and calling one fails because the function or schema is not there (42883 or 3F000).
SELECT pg_temp.ue_assert(NOT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE p.proname = 'graphql' OR n.nspname LIKE 'graphql%'),
  'a graphql function or schema exists');
SELECT pg_temp.ue_assert(pg_temp.ue_outcome('anon', $q$SELECT graphql_public.graphql(query := '{ __typename }')$q$) IN ('3F000', '42883'), 'anon can reach graphql_public.graphql');
SELECT pg_temp.ue_assert(pg_temp.ue_outcome('anon', $q$SELECT graphql.resolve('{ __typename }')$q$) IN ('3F000', '42883'), 'anon can reach graphql.resolve');
SELECT pg_temp.ue_assert(pg_temp.ue_outcome('service_role', $q$SELECT public.http_post('http://hook.example.test/', '{}', 'application/json')$q$) IN ('3F000', '42883'), 'service_role can call public.http_post');
SELECT pg_temp.ue_assert(pg_temp.ue_outcome('service_role', $q$SELECT net.http_post('http://hook.example.test/')$q$) IN ('3F000', '42883'), 'service_role can reach net.http_post');
ROLLBACK;
