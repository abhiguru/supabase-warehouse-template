\set ON_ERROR_STOP on
-- Per-role database passwords (docs/CONTAINER_SECURITY.md, "Database passwords").
-- scripts/db-roles.sh prefixes this script on standard input with one psql
-- "\set" line per login: a SCRAM-SHA-256 verifier that scripts/db-roles.mjs
-- computes from config/compose.env. The passwords never reach the server, an
-- argument list, the environment or a log; ALTER ROLE stores a verifier as it is.
-- Idempotent. setup.sh runs it after every migration run and both restore paths
-- after their replay: docker/volumes/db/roles.sql runs only on an empty data
-- directory, so this script is what an existing installation relies on.
-- Keep the logins in step with DB_ROLE_LOGINS and POOLER_LOGIN in scripts/db-roles.mjs
-- (tests/db-roles.test.mjs compares them). pooler_verifier is given only while the pooler is on.
SELECT :{?authenticator_verifier} AND :{?storage_verifier} AS all_given \gset
\if :all_given
\else
  DO $$ BEGIN RAISE EXCEPTION 'configure-db-roles.sql needs every per-role verifier; run it through scripts/db-roles.sh'; END $$;
\endif
SELECT bool_and(v ~ '^SCRAM-SHA-256\$4096:[A-Za-z0-9+/]{22}==\$[A-Za-z0-9+/]{43}=:[A-Za-z0-9+/]{43}=$') AS valid_verifiers
FROM (VALUES (:'authenticator_verifier'), (:'storage_verifier')) AS given(v) \gset
\if :valid_verifiers
\else
  DO $$ BEGIN RAISE EXCEPTION 'configure-db-roles.sql accepts SCRAM-SHA-256 verifiers only; no password was changed'; END $$;
\endif
-- The pool user's verifier is given only while the pooler is on; its role exists then (scripts/configure-pooler.sql).
SELECT :{?pooler_verifier} AS pooler_given \gset
\if :pooler_given
SELECT :'pooler_verifier' ~ '^SCRAM-SHA-256\$4096:[A-Za-z0-9+/]{22}==\$[A-Za-z0-9+/]{43}=:[A-Za-z0-9+/]{43}=$' AS valid_pooler \gset
\if :valid_pooler
\else
  DO $$ BEGIN RAISE EXCEPTION 'configure-db-roles.sql accepts SCRAM-SHA-256 verifiers only; no password was changed'; END $$;
\endif
\endif
SELECT :{?supabase_admin_verifier} AS rotate_superuser \gset

BEGIN;
-- The statements below carry verifiers, not passwords; they are kept out of
-- pg_stat_statements all the same.
SET LOCAL pg_stat_statements.track = 'none';
-- The lock of the auth configuration scripts (configure-auth.sql, rotate-auth.sql).
SELECT pg_advisory_xact_lock(71042) \gset

ALTER ROLE authenticator WITH LOGIN PASSWORD :'authenticator_verifier';
ALTER ROLE supabase_storage_admin WITH LOGIN PASSWORD :'storage_verifier';
\if :pooler_given
ALTER ROLE pgbouncer WITH LOGIN PASSWORD :'pooler_verifier';
\endif

-- The superuser password (supabase_admin, the only superuser): only scripts/rotate-db-passwords.sh
-- --superuser passes this verifier.
\if :rotate_superuser
SELECT :'supabase_admin_verifier' ~ '^SCRAM-SHA-256\$4096:' AS valid_superuser \gset
\if :valid_superuser
ALTER ROLE supabase_admin WITH PASSWORD :'supabase_admin_verifier';
\else
  DO $$ BEGIN RAISE EXCEPTION 'configure-db-roles.sql accepts SCRAM-SHA-256 verifiers only; no password was changed'; END $$;
\endif
\endif
COMMIT;
