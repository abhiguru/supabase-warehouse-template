\set ON_ERROR_STOP on
-- The association's token issuer this facility trusts for central sign-in
-- (docs/CENTRAL_LOGIN.md). Read only from this database container's
-- environment; empty or absent turns central sign-in off in the database.
-- The edge function reads the same value and the key address from its own
-- environment; public.operator_central_exchange refuses any other issuer.
\set central_issuer ''
\getenv central_issuer CENTRAL_ISSUER
BEGIN;
SELECT pg_advisory_xact_lock(71042);
SELECT :'central_issuer' = '' AS central_off,
  :'central_issuer' ~ '^https://[^[:space:]]+$' AND length(:'central_issuer') <= 255 AS central_valid \gset
\if :central_off
  DELETE FROM warehouse_security.auth_config WHERE key='central_issuer';
\elif :central_valid
  INSERT INTO warehouse_security.auth_config(key,value) VALUES ('central_issuer',:'central_issuer')
  ON CONFLICT(key) DO UPDATE SET value=excluded.value;
\else
  DO $$ BEGIN RAISE EXCEPTION 'CENTRAL_ISSUER must be an https:// address without spaces, or empty'; END $$;
\endif
COMMIT;
