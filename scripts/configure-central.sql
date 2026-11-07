\set ON_ERROR_STOP on
-- The association's token issuer this facility trusts for central sign-in
-- (docs/CENTRAL_LOGIN.md). setup.sh reads CENTRAL_ISSUER from the state's
-- compose.env and passes it as the psql variable central_issuer; empty or
-- absent turns central sign-in off in the database. The edge function reads
-- the same value from its own environment; public.operator_central_exchange
-- refuses any other issuer.
-- central_local_code (setup.sh --central-local-code, CENTRAL_LOCAL_CODE in compose.env): 'on'
-- makes this facility ask for its own SMS code at every central sign-in
-- (auth_config key central_local_code, migration 81). Anything else, or central
-- sign-in off, removes the key: the default is the association's sign-in alone.
\if :{?central_issuer}
\else
  \set central_issuer ''
\endif
\if :{?central_local_code}
\else
  \set central_local_code ''
\endif
-- central_admin_trust (setup.sh --central-admin-trust, CENTRAL_ADMIN_TRUST in compose.env; WH-148): 'no' makes a central sign-in to
-- an administrator profile also ask for this facility's own SMS code, every time (auth_config key central_admin_trust, migration 168).
-- Anything else (yes, empty) removes the key: today's rule, the association's sign-in alone.
\if :{?central_admin_trust}
\else
  \set central_admin_trust ''
\endif
BEGIN;
SELECT pg_advisory_xact_lock(71042);
SELECT :'central_issuer' = '' AS central_off,
  :'central_issuer' ~ '^https://[^[:space:]]+$' AND length(:'central_issuer') <= 255 AS central_valid \gset
\if :central_off
  DELETE FROM warehouse_security.auth_config WHERE key IN ('central_issuer','central_local_code','central_admin_trust');
\elif :central_valid
  INSERT INTO warehouse_security.auth_config(key,value) VALUES ('central_issuer',:'central_issuer')
  ON CONFLICT(key) DO UPDATE SET value=excluded.value;
  SELECT :'central_local_code' = 'on' AS local_code_on \gset
  \if :local_code_on
    INSERT INTO warehouse_security.auth_config(key,value) VALUES ('central_local_code','on')
    ON CONFLICT(key) DO UPDATE SET value=excluded.value;
  \else
    DELETE FROM warehouse_security.auth_config WHERE key='central_local_code';
  \endif
  SELECT :'central_admin_trust' = 'no' AS admin_trust_no \gset
  \if :admin_trust_no
    INSERT INTO warehouse_security.auth_config(key,value) VALUES ('central_admin_trust','no')
    ON CONFLICT(key) DO UPDATE SET value=excluded.value;
  \else
    DELETE FROM warehouse_security.auth_config WHERE key='central_admin_trust';
  \endif
\else
  DO $$ BEGIN RAISE EXCEPTION 'CENTRAL_ISSUER must be an https:// address without spaces, or empty'; END $$;
\endif
COMMIT;
