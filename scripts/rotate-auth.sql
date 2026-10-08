\set ON_ERROR_STOP on
-- Signing-key rotation for one operator instance. rotate-keys.sh prefixes this
-- script on standard input with a psql "\set new_secret ..." line; the secret
-- never appears in arguments, the environment or logs. Keep this script quiet.
BEGIN;
SELECT pg_advisory_xact_lock(71042);
SELECT :'new_secret' ~ '^[0-9a-f]{96}$' AS valid_secret \gset
\if :valid_secret
\else
  DO $$ BEGIN RAISE EXCEPTION 'A generated 96-character hexadecimal JWT secret is required'; END $$;
\endif
SELECT COALESCE((SELECT value FROM warehouse_security.auth_config WHERE key='auth_mode'),'')='operator' AS operator_mode \gset
\if :operator_mode
\else
  DO $$ BEGIN RAISE EXCEPTION 'Key rotation requires a configured operator instance; no key was changed'; END $$;
\endif
INSERT INTO warehouse_security.auth_config(key,value) VALUES ('jwt_secret',:'new_secret')
ON CONFLICT(key) DO UPDATE SET value=excluded.value;
-- Every refresh session and access token was signed with the previous secret.
DELETE FROM warehouse_security.refresh_sessions;
-- Pending challenges hold HMACs of the previous secret and can never verify.
UPDATE public.otp_verifications SET verified=true, otp_code_hash=NULL WHERE NOT verified;
-- Realtime seeds its self-hosted tenant from API_JWT_SECRET only while the row
-- is absent; remove it so the recreated service registers the new secret.
DO $$ BEGIN
  IF to_regclass('_realtime.extensions') IS NOT NULL THEN
    DELETE FROM _realtime.extensions WHERE tenant_external_id='realtime-dev';
  END IF;
  IF to_regclass('_realtime.tenants') IS NOT NULL THEN
    DELETE FROM _realtime.tenants WHERE external_id='realtime-dev';
  END IF;
END $$;
ALTER DATABASE postgres SET "app.settings.jwt_secret" TO :'new_secret';
COMMIT;
