\set ON_ERROR_STOP on
-- Read only this new database container's environment; never inspect another project.
\getenv starter_secret JWT_SECRET
\getenv starter_expiry JWT_EXP
\getenv starter_mode AUTH_MODE
\getenv starter_environment APP_ENV
BEGIN;
SELECT pg_advisory_xact_lock(71042);
SELECT length(:'starter_secret')>=32 AND :'starter_secret' NOT LIKE 'your-%' AS valid_secret \gset
\if :valid_secret
\else
  DO $$ BEGIN RAISE EXCEPTION 'A generated JWT secret is required'; END $$;
\endif
INSERT INTO warehouse_security.auth_config(key,value) VALUES ('jwt_secret',:'starter_secret') ON CONFLICT DO NOTHING;
SELECT value=:'starter_secret' AS secret_matches FROM warehouse_security.auth_config WHERE key='jwt_secret' \gset
\if :secret_matches
\else
  DO $$ BEGIN RAISE EXCEPTION 'Existing database signing key differs; no key was changed'; END $$;
\endif
SELECT :'starter_mode' IN ('demo','disabled') AND (:'starter_mode'<>'demo' OR :'starter_environment'='development') AS valid_mode \gset
\if :valid_mode
\else
  DO $$ BEGIN RAISE EXCEPTION 'Demo authentication is allowed only in development'; END $$;
\endif
INSERT INTO warehouse_security.auth_config(key,value) VALUES
  ('demo_auth_enabled',(:'starter_mode'='demo')::text),('access_seconds',(:'starter_expiry')::integer::text)
ON CONFLICT(key) DO UPDATE SET value=excluded.value;
COMMIT;
