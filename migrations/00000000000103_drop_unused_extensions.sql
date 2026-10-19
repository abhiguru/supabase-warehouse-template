-- Migration 103: four extensions that nothing uses are removed: http, pg_net, pg_graphql and supabase_vault.
--
-- Why, in plain English. Each of these gives the database a capability this backend never uses, and each one
-- is a way in if something else ever goes wrong:
--
--   http           lets SQL send web requests to any address. It was installed by the first migration for an
--                  old function that migration 15 replaced; nothing calls it. service_role could still run
--                  public.http_post through REST, and the database container can reach the Studio helper
--                  (postgres-meta) that runs SQL as a superuser, so a stray request primitive in the database
--                  was a way to reach other containers.
--   pg_net         the same idea, asynchronous (net.http_post), and the database webhooks built on it
--                  (schema supabase_functions). No webhook has ever been defined here and its queue is empty.
--                  Migration 93 and tests/pg_net_grants.sql existed only to keep it locked down.
--   pg_graphql     a GraphQL endpoint. The app never calls it, yet anon could run graphql_public.graphql
--                  through the gateway route /graphql/v1.
--   supabase_vault the Supabase secrets store: no secret in it, no code refers to it. (public.secrets_vault is
--                  an unrelated table of this application and is not touched.)
--
-- The Supabase image installs event triggers that react to these extensions. issue_graphql_placeholder
-- re-creates a stand-in graphql_public.graphql function when pg_graphql is dropped, so it would undo this
-- migration; issue_pg_graphql_access and issue_pg_net_access hand out grants on them. Those three triggers
-- and their functions are dropped first, then the extensions. The triggers that stay: issue_pg_cron_access
-- (pg_cron is still used by the list refresher) and PostgREST's own pgrst_ddl_watch and pgrst_drop_watch.
--
-- What is dropped, in this order. Every step is skipped where the object is already gone: a new install, where
-- the image creates pg_graphql and vault but never pg_net, skips the pg_net steps, and an existing installation
-- runs all of them. The migration is safe to run on both.
--  1. the event triggers issue_graphql_placeholder, issue_pg_graphql_access, issue_pg_net_access and the
--     functions extensions.set_graphql_placeholder, extensions.grant_pg_graphql_access and
--     extensions.grant_pg_net_access;
--  2. the extension http;
--  3. the extension pg_net and the schema net, then the tables hooks and migrations and the
--     function http_request of the schema supabase_functions, then the schema. The migration stops, and
--     changes nothing, if a trigger anywhere still calls supabase_functions.http_request, because that
--     would be a webhook someone defined. It also stops, and changes nothing, if a pg_cron job calls net.* or
--     http(...), or if the vault holds a secret, because dropping the extension would silently delete them;
--  4. the role supabase_functions_admin, which only owned those webhook objects. It is dropped only if it
--     owns nothing afterwards in this database and has no entry at all in any other database or in the
--     cluster-wide catalogs (checked in pg_shdepend, which covers the postgres and _supabase databases);
--     otherwise it is left as it is (NOLOGIN, from migration 94) and a NOTICE says so. Only privileges
--     granted to it are removed (DROP OWNED BY on a role that owns nothing); nothing else is touched;
--  5. the extension pg_graphql and the schema graphql, any graphql function left in graphql_public that is
--     not part of the extension, and the schema graphql_public;
--  6. the extension supabase_vault and the schema vault.
-- The image creates the schemas graphql, graphql_public and vault itself, outside the extensions, so they are
-- dropped on their own; every DROP SCHEMA is without CASCADE and fails if anything else lives in the schema.
-- No extension is dropped with CASCADE: the dependencies were checked on a live installation (nothing outside
-- the four extensions' own objects depends on them), and a dependency that appears later makes the drop fail
-- instead of dragging an application object with it.
--
-- The last statement checks that none of the four extensions and none of their schemas remain.
-- Other changes in the same release: Kong no longer routes /graphql/v1, PostgREST no longer lists
-- graphql_public, and the database no longer preloads pg_net.

DO $drop$
DECLARE
  hook record;
  fn record;
  current_db oid := (SELECT oid FROM pg_database WHERE datname = current_database());
  owned_here bigint;
  referenced_elsewhere bigint;
  in_use boolean;
BEGIN
  -- 1. Event triggers first: issue_graphql_placeholder would put a stand-in graphql function back.
  DROP EVENT TRIGGER IF EXISTS issue_graphql_placeholder;
  DROP EVENT TRIGGER IF EXISTS issue_pg_graphql_access;
  DROP EVENT TRIGGER IF EXISTS issue_pg_net_access;
  DROP FUNCTION IF EXISTS extensions.set_graphql_placeholder();
  DROP FUNCTION IF EXISTS extensions.grant_pg_graphql_access();
  DROP FUNCTION IF EXISTS extensions.grant_pg_net_access();

  -- 2. http
  DROP EXTENSION IF EXISTS http;

  -- 3. pg_net and the webhook schema
  IF to_regprocedure('supabase_functions.http_request()') IS NOT NULL THEN
    FOR hook IN
      SELECT t.tgrelid::regclass AS table_name, t.tgname
      FROM pg_trigger t
      WHERE t.tgfoid = 'supabase_functions.http_request()'::regprocedure AND NOT t.tgisinternal
    LOOP
      RAISE EXCEPTION 'The database webhook % on % still calls supabase_functions.http_request(); remove it first.', hook.tgname, hook.table_name;
    END LOOP;
  END IF;
  -- The two tables below may not exist (a new install has no pg_net, a second run has no vault), so they are
  -- read through EXECUTE: a plain SELECT would fail when the statement is planned.
  IF to_regclass('cron.job') IS NOT NULL THEN
    EXECUTE $q$SELECT EXISTS (SELECT 1 FROM cron.job WHERE command ~* '\mnet\.|\mhttp(_[a-z]+)?\s*\(')$q$ INTO in_use;
    IF in_use THEN
      RAISE EXCEPTION 'A scheduled pg_cron job still calls net.* or http(...); remove or change that job first (select jobid, jobname, command from cron.job).';
    END IF;
  END IF;
  IF to_regclass('vault.secrets') IS NOT NULL THEN
    EXECUTE 'SELECT EXISTS (SELECT 1 FROM vault.secrets)' INTO in_use;
    IF in_use THEN
      RAISE EXCEPTION 'The vault still holds secrets; dropping it would delete them. Copy them somewhere safe and delete them from vault.secrets first.';
    END IF;
  END IF;
  DROP EXTENSION IF EXISTS pg_net;
  DROP SCHEMA IF EXISTS net;
  IF to_regnamespace('supabase_functions') IS NOT NULL THEN
    DROP TABLE IF EXISTS supabase_functions.hooks;
    DROP TABLE IF EXISTS supabase_functions.migrations;
    DROP FUNCTION IF EXISTS supabase_functions.http_request();
    DROP SCHEMA supabase_functions;
  END IF;

  -- 4. The role of the webhook objects.
  IF to_regrole('supabase_functions_admin') IS NOT NULL THEN
    SELECT count(*) FILTER (WHERE s.dbid = current_db AND s.deptype = 'o'),
           count(*) FILTER (WHERE s.dbid <> current_db)
      INTO owned_here, referenced_elsewhere
    FROM pg_shdepend s
    WHERE s.refclassid = 'pg_authid'::regclass AND s.refobjid = 'supabase_functions_admin'::regrole;
    IF owned_here = 0 AND referenced_elsewhere = 0 THEN
      DROP OWNED BY supabase_functions_admin;
      DROP ROLE supabase_functions_admin;
    ELSE
      RAISE NOTICE 'The role supabase_functions_admin is kept: it owns % object(s) in this database and is referenced by % object(s) in other databases or cluster-wide.', owned_here, referenced_elsewhere;
    END IF;
  END IF;

  -- 5. pg_graphql
  DROP EXTENSION IF EXISTS pg_graphql;
  -- The image creates the schema graphql itself, so it is not removed with the extension; it is empty by now.
  DROP SCHEMA IF EXISTS graphql;
  IF to_regnamespace('graphql_public') IS NOT NULL THEN
    -- A wrapper that was created outside the extension (a restore does that) is not removed with it.
    FOR fn IN
      SELECT p.oid::regprocedure AS signature
      FROM pg_proc p
      WHERE p.pronamespace = 'graphql_public'::regnamespace AND p.proname = 'graphql'
    LOOP
      EXECUTE format('DROP FUNCTION %s', fn.signature);
    END LOOP;
    DROP SCHEMA graphql_public;
  END IF;

  -- 6. supabase_vault
  DROP EXTENSION IF EXISTS supabase_vault;
  DROP SCHEMA IF EXISTS vault;

  -- Self-check.
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname IN ('http', 'pg_net', 'pg_graphql', 'supabase_vault')) THEN
    RAISE EXCEPTION 'Migration 103: an unused extension is still installed: %',
      (SELECT string_agg(extname, ', ' ORDER BY extname) FROM pg_extension WHERE extname IN ('http', 'pg_net', 'pg_graphql', 'supabase_vault'));
  END IF;
  IF EXISTS (SELECT 1 FROM pg_namespace WHERE nspname IN ('net', 'graphql', 'graphql_public', 'vault', 'supabase_functions')) THEN
    RAISE EXCEPTION 'Migration 103: a schema of the removed extensions is still there: %',
      (SELECT string_agg(nspname, ', ' ORDER BY nspname) FROM pg_namespace WHERE nspname IN ('net', 'graphql', 'graphql_public', 'vault', 'supabase_functions'));
  END IF;
END
$drop$;
