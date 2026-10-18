-- Runs once, when the database starts on an empty data directory (an init
-- script). Every service login gets its own password from the database
-- container's environment, which docker-compose.yml fills from compose.env
-- (docs/CONTAINER_SECURITY.md, "Database passwords"). scripts/configure-db-roles.sql
-- sets the same values on every setup run and after a restore, and also covers
-- warehouse_monitoring, which a migration creates after this script has run.
\set authenticator_password `echo "$DB_PASSWORD_AUTHENTICATOR"`
\set storage_password `echo "$DB_PASSWORD_STORAGE"`
\set auth_password `echo "$DB_PASSWORD_AUTH"`
\set pooler_password `echo "$DB_PASSWORD_POOLER"`
\set superuser_password `echo "$POSTGRES_PASSWORD"`

SELECT bool_and(v ~ '^[A-Za-z0-9_-]{32,128}$') AND count(DISTINCT v) = 5 AS usable_passwords
FROM (VALUES (:'authenticator_password'), (:'storage_password'), (:'auth_password'),
             (:'pooler_password'), (:'superuser_password')) AS given(v) \gset
\if :usable_passwords
\else
  DO $$ BEGIN RAISE EXCEPTION 'roles.sql: DB_PASSWORD_AUTHENTICATOR, _STORAGE, _AUTH and _POOLER must be set, distinct and different from POSTGRES_PASSWORD; run setup.sh'; END $$;
\endif

ALTER USER authenticator WITH PASSWORD :'authenticator_password';
ALTER USER pgbouncer WITH PASSWORD :'pooler_password';
ALTER USER supabase_auth_admin WITH PASSWORD :'auth_password';
ALTER USER supabase_storage_admin WITH PASSWORD :'storage_password';
-- Nothing logs in as supabase_functions_admin; it only owns the webhook functions.
ALTER USER supabase_functions_admin WITH NOLOGIN PASSWORD NULL;
