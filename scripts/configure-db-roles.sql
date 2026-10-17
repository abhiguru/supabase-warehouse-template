\set ON_ERROR_STOP on
-- Per-role database passwords (docs/CONTAINER_SECURITY.md, "Database passwords").
-- scripts/db-roles.sh prefixes this script on standard input with one psql
-- "\set" line per login: a SCRAM-SHA-256 verifier that scripts/db-roles.mjs
-- computes from config/compose.env. The passwords never reach the server, an
-- argument list, the environment or a log; ALTER ROLE stores a verifier as it is.
-- Idempotent. setup.sh runs it after every migration run and both restore paths
-- after their replay: docker/volumes/db/roles.sql runs only on an empty data
-- directory, so this script is what an existing installation relies on.
-- Keep the logins in step with DB_ROLE_LOGINS in scripts/db-roles.mjs
-- (tests/db-roles.test.mjs compares them).
SELECT :{?authenticator_verifier} AND :{?storage_verifier} AND :{?auth_verifier}
   AND :{?pooler_verifier} AND :{?monitoring_verifier} AS all_given \gset
\if :all_given
\else
  DO $$ BEGIN RAISE EXCEPTION 'configure-db-roles.sql needs every per-role verifier; run it through scripts/db-roles.sh'; END $$;
\endif
SELECT bool_and(v ~ '^SCRAM-SHA-256\$4096:[A-Za-z0-9+/]{22}==\$[A-Za-z0-9+/]{43}=:[A-Za-z0-9+/]{43}=$') AS valid_verifiers
FROM (VALUES (:'authenticator_verifier'), (:'storage_verifier'), (:'auth_verifier'),
             (:'pooler_verifier'), (:'monitoring_verifier')) AS given(v) \gset
\if :valid_verifiers
\else
  DO $$ BEGIN RAISE EXCEPTION 'configure-db-roles.sql accepts SCRAM-SHA-256 verifiers only; no password was changed'; END $$;
\endif
SELECT :{?postgres_verifier} AND :{?supabase_admin_verifier} AS rotate_superuser \gset

BEGIN;
-- The statements below carry verifiers, not passwords; they are kept out of
-- pg_stat_statements all the same (warehouse_monitoring may read it).
SET LOCAL pg_stat_statements.track = 'none';
-- The lock of the auth configuration scripts (configure-auth.sql, rotate-auth.sql).
SELECT pg_advisory_xact_lock(71042) \gset

-- The monitoring login: created by migration 94. A restore replays a backup's
-- roles as bare NOLOGIN names (scripts/restore.sh) and does not rerun an
-- applied migration, so the role and its one membership are made whole here.
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'warehouse_monitoring') THEN
    CREATE ROLE warehouse_monitoring NOLOGIN;
  END IF;
  ALTER ROLE warehouse_monitoring NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS INHERIT;
  IF NOT EXISTS (
    SELECT 1 FROM pg_auth_members m
    JOIN pg_roles granted ON granted.oid = m.roleid
    JOIN pg_roles member ON member.oid = m.member
    WHERE granted.rolname = 'pg_monitor' AND member.rolname = 'warehouse_monitoring'
  ) THEN
    GRANT pg_monitor TO warehouse_monitoring;
  END IF;
END $$;

ALTER ROLE authenticator WITH LOGIN PASSWORD :'authenticator_verifier';
ALTER ROLE supabase_storage_admin WITH LOGIN PASSWORD :'storage_verifier';
ALTER ROLE supabase_auth_admin WITH LOGIN PASSWORD :'auth_verifier';
ALTER ROLE pgbouncer WITH LOGIN PASSWORD :'pooler_verifier';
ALTER ROLE warehouse_monitoring WITH LOGIN PASSWORD :'monitoring_verifier';

-- Nothing logs in as supabase_functions_admin (it owns the webhook functions,
-- which run with its rights without a login). It had the shared password.
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'supabase_functions_admin') THEN
    ALTER ROLE supabase_functions_admin WITH NOLOGIN PASSWORD NULL;
  END IF;
END $$;

-- The superuser password: only scripts/rotate-db-passwords.sh --superuser
-- passes these two verifiers.
\if :rotate_superuser
SELECT :'postgres_verifier' ~ '^SCRAM-SHA-256\$4096:' AND :'supabase_admin_verifier' ~ '^SCRAM-SHA-256\$4096:' AS valid_superuser \gset
\if :valid_superuser
ALTER ROLE postgres WITH PASSWORD :'postgres_verifier';
ALTER ROLE supabase_admin WITH PASSWORD :'supabase_admin_verifier';
\else
  DO $$ BEGIN RAISE EXCEPTION 'configure-db-roles.sql accepts SCRAM-SHA-256 verifiers only; no password was changed'; END $$;
\endif
\endif
COMMIT;
