-- Migration 92: the JWT signing secret is no longer a database setting (TW-BE-003, operations review of 2026-10-17).
--
-- The Supabase template stored the signing secret as the database setting "app.settings.jwt_secret"
-- (docker/volumes/db/jwt.sql at the first start, scripts/rotate-auth.sql at every rotation) and PostgREST
-- set it again in every request transaction (PGRST_APP_SETTINGS_JWT_SECRET). current_setting() returns such
-- a setting to every role, anon included, so any future SQL path as anon or authenticated that ran a
-- statement or echoed a setting would have handed over the key that signs service_role tokens. Nothing
-- reads it: the database code reads warehouse_security.auth_config (key jwt_secret), which is untouched,
-- and PostgREST, Realtime and Storage take the secret from their own environment (PGRST_JWT_SECRET,
-- API_JWT_SECRET), which is also untouched.
--
-- This migration resets the setting at database level and, wherever pg_db_role_setting holds it, for a
-- role in this database or for a role in every database. It carries no secret and is idempotent; the same
-- reset is in scripts/configure-auth.sql, which setup.sh runs after every migration run. The rest of the
-- app.settings.* family (jwt_exp) is left alone. The migration fails if the setting is still there after
-- the reset.

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

  IF EXISTS (
    SELECT 1 FROM pg_db_role_setting s, unnest(s.setconfig) AS item
    WHERE s.setdatabase IN (0, this_database) AND starts_with(lower(item), 'app.settings.jwt_secret=')
  ) THEN
    RAISE EXCEPTION 'The signing secret is still held as a database or role setting';
  END IF;
END
$reset$;
