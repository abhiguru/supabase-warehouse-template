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
-- Switching an existing local demo database to operator mode must invalidate
-- sessions minted while demo authentication was enabled. Repeated configuration
-- of an already configured operator instance leaves its sessions intact.
DELETE FROM warehouse_security.refresh_sessions
WHERE COALESCE((SELECT value FROM warehouse_security.auth_config WHERE key='auth_mode'),'') <> 'operator';
SELECT :'starter_mode'='operator' AND :'starter_environment'='production' AS valid_mode \gset
\if :valid_mode
\else
  DO $$ BEGIN RAISE EXCEPTION 'Operator authentication requires production mode'; END $$;
\endif
INSERT INTO warehouse_security.auth_config(key,value) VALUES
  ('demo_auth_enabled','false'),('auth_mode',:'starter_mode'),
  ('access_seconds',(:'starter_expiry')::integer::text)
ON CONFLICT(key) DO UPDATE SET value=excluded.value;
-- Session lifetime and the per-source OTP limits (migration 126, which seeds the same values). They are seeded once and never
-- rewritten: unlike access_seconds above, which setup sets from JWT_EXP on every run, they have no setting in compose.env, so a rerun
-- keeps the value an operator chose and only puts back one that was removed. otp_trusted_sources is not seeded: it does not exist until
-- the operator lists the facility's public address (docs/OPERATOR_INSTALL.md, "Authentication and OTP limits").
INSERT INTO warehouse_security.auth_config(key,value) VALUES
  ('session_idle_seconds','2592000'),('session_max_seconds','7776000'),
  ('otp_source_hourly_sends','30'),('otp_source_hourly_failures','20'),('otp_trusted_source_hourly_sends','120')
ON CONFLICT(key) DO NOTHING;
-- The signing secret lives in warehouse_security.auth_config only. An earlier install, or a restored one,
-- may still hold it as the database setting app.settings.jwt_secret, which every role can read through
-- current_setting() (migration 92). Reset it, and a role-level copy, on every run; this holds no secret.
DO $reset$
DECLARE
  this_database oid := (SELECT oid FROM pg_database WHERE datname = current_database());
  held record;
BEGIN
  EXECUTE format('ALTER DATABASE %I RESET "app.settings.jwt_secret"', current_database());
  FOR held IN
    SELECT s.setdatabase, s.setrole, r.rolname
    FROM pg_db_role_setting s
    LEFT JOIN pg_roles r ON r.oid = s.setrole
    WHERE s.setdatabase IN (0, this_database)
      AND NOT (s.setdatabase = this_database AND s.setrole = 0)
      AND EXISTS (SELECT 1 FROM unnest(s.setconfig) AS item WHERE starts_with(lower(item), 'app.settings.jwt_secret='))
  LOOP
    IF held.setrole = 0 THEN
      EXECUTE 'ALTER ROLE ALL RESET "app.settings.jwt_secret"';
    ELSIF held.setdatabase = 0 THEN
      EXECUTE format('ALTER ROLE %I RESET "app.settings.jwt_secret"', held.rolname);
    ELSE
      EXECUTE format('ALTER ROLE %I IN DATABASE %I RESET "app.settings.jwt_secret"', held.rolname, current_database());
    END IF;
  END LOOP;
END
$reset$;
COMMIT;
