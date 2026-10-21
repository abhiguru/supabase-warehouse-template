-- Runs once, when the database starts on an empty data directory (an init
-- script). Every service login gets its own password from the database
-- container's environment, which docker-compose.yml fills from compose.env
-- (docs/CONTAINER_SECURITY.md, "Database passwords"). scripts/configure-db-roles.sql
-- sets the same values on every setup run and after a restore.
\set authenticator_password `echo "$DB_PASSWORD_AUTHENTICATOR"`
\set storage_password `echo "$DB_PASSWORD_STORAGE"`
\set superuser_password `echo "$POSTGRES_PASSWORD"`

SELECT bool_and(v ~ '^[A-Za-z0-9_-]{32,128}$') AND count(DISTINCT v) = 3 AS usable_passwords
FROM (VALUES (:'authenticator_password'), (:'storage_password'),
             (:'superuser_password')) AS given(v) \gset
\if :usable_passwords
\else
  DO $$ BEGIN RAISE EXCEPTION 'roles.sql: DB_PASSWORD_AUTHENTICATOR and DB_PASSWORD_STORAGE must be set, distinct and different from POSTGRES_PASSWORD; run setup.sh'; END $$;
\endif

ALTER USER authenticator WITH PASSWORD :'authenticator_password';
ALTER USER supabase_storage_admin WITH PASSWORD :'storage_password';
