-- Migration 108, AFTER it ran: pgjwt is gone, the signer is internal, nothing still calls extensions.sign/verify,
-- and sign_access_token returns a token that verifies with the HS256 secret.
-- Runs in migrations.sh's disposable database; every fixture row rolls back.
\set ON_ERROR_STOP on
BEGIN;
CREATE FUNCTION pg_temp.js_assert(ok boolean, label text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF NOT COALESCE(ok, false) THEN RAISE EXCEPTION 'jwt sign 108: %', label; END IF; END $$;

SELECT pg_temp.js_assert(NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pgjwt'), 'pgjwt is still installed');
SELECT pg_temp.js_assert(to_regprocedure('extensions.sign(json,text,text)') IS NULL AND to_regprocedure('extensions.verify(text,text,text)') IS NULL,
  'extensions.sign or extensions.verify still exists');
SELECT pg_temp.js_assert(NOT EXISTS (SELECT 1 FROM pg_proc p WHERE p.prosrc ~ '(extensions\.)?\m(verify|url_encode|url_decode|algorithm_sign|try_cast_double)\s*\(|extensions\.sign\s*\(' AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.classid = 'pg_proc'::regclass AND d.objid = p.oid AND d.deptype = 'e')),
  'a function still mentions pgjwt: ' || coalesce((SELECT string_agg(p.oid::regprocedure::text, ', ') FROM pg_proc p WHERE p.prosrc ~ '(extensions\.)?\m(verify|url_encode|url_decode|algorithm_sign|try_cast_double)\s*\(|extensions\.sign\s*\(' AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.classid = 'pg_proc'::regclass AND d.objid = p.oid AND d.deptype = 'e')), ''));
SELECT pg_temp.js_assert(to_regprocedure('warehouse_security.jwt_sign_hs256(json,text)') IS NOT NULL, 'the signer is missing');
-- no API role may execute the signer
SELECT pg_temp.js_assert(NOT has_function_privilege(r, 'warehouse_security.jwt_sign_hs256(json,text)', 'EXECUTE'), r || ' can execute the signer')
  FROM unnest(ARRAY['anon', 'authenticated', 'service_role']) AS r;
SELECT pg_temp.js_assert((SELECT proacl IS NULL OR NOT EXISTS (SELECT 1 FROM aclexplode(proacl) a WHERE a.grantee = 0)
  FROM pg_proc WHERE oid = 'warehouse_security.jwt_sign_hs256(json,text)'::regprocedure), 'PUBLIC can execute the signer');
-- sign_access_token still has its old shape and is still not callable by API roles
SELECT pg_temp.js_assert((SELECT prosecdef AND proconfig @> ARRAY['search_path=pg_catalog, public, extensions'] FROM pg_proc
  WHERE oid = 'warehouse_security.sign_access_token(uuid,uuid)'::regprocedure), 'sign_access_token lost SECURITY DEFINER or its search_path');
SELECT pg_temp.js_assert(NOT has_function_privilege(r, 'warehouse_security.sign_access_token(uuid,uuid)', 'EXECUTE'), r || ' can execute sign_access_token')
  FROM unnest(ARRAY['anon', 'authenticated', 'service_role']) AS r;
SELECT pg_temp.js_assert((SELECT prosrc FROM pg_proc WHERE oid = 'warehouse_security.sign_access_token(uuid,uuid)'::regprocedure) LIKE '%warehouse_security.jwt_sign_hs256(%'
  AND (SELECT prosrc FROM pg_proc WHERE oid = 'warehouse_security.sign_access_token(uuid,uuid)'::regprocedure) NOT LIKE '%extensions.sign%', 'sign_access_token does not call the new signer');

-- A real session: the token verifies with the secret.
INSERT INTO warehouse_security.auth_config(key, value) VALUES
 ('jwt_secret', 'isolated-test-secret-not-for-any-deployment-12345'),
 ('auth_mode', 'operator'), ('demo_auth_enabled', 'false'), ('refresh_grace_seconds', '60')
 ON CONFLICT (key) DO UPDATE SET value = excluded.value;
SELECT warehouse_security.bootstrap_first_admin('9888888108', 'Signer Administrator') AS user_id \gset
SELECT warehouse_security.issue_session(:'user_id'::uuid) AS issued \gset
SELECT :'issued'::jsonb->>'access_token' AS token \gset
SELECT pg_temp.js_assert(:'token' ~ '^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$', 'the access token is not three base64url parts');
SELECT split_part(:'token', '.', 1) AS h, split_part(:'token', '.', 2) AS p, split_part(:'token', '.', 3) AS sig \gset
SELECT pg_temp.js_assert(
  translate(encode(extensions.hmac(convert_to(:'h' || '.' || :'p', 'UTF8'), convert_to('isolated-test-secret-not-for-any-deployment-12345', 'UTF8'), 'sha256'), 'base64'), E'+/=\n', '-_') = :'sig',
  'the signature does not verify with the HS256 secret');
SELECT pg_temp.js_assert(convert_from(decode(translate(:'h', '-_', '+/') || repeat('=', (4 - length(:'h') % 4) % 4), 'base64'), 'UTF8') = '{"alg":"HS256","typ":"JWT"}', 'wrong header');
SELECT pg_temp.js_assert(convert_from(decode(translate(:'p', '-_', '+/') || repeat('=', (4 - length(:'p') % 4) % 4), 'base64'), 'UTF8')::jsonb ->> 'sub' = :'user_id'
  AND convert_from(decode(translate(:'p', '-_', '+/') || repeat('=', (4 - length(:'p') % 4) % 4), 'base64'), 'UTF8')::jsonb ->> 'role' = 'authenticated', 'wrong payload');
-- refresh_jwt_token (which also signs through sign_access_token) still works
SELECT :'issued'::jsonb->>'refresh_token' AS r1 \gset
SET LOCAL ROLE anon;
SELECT public.refresh_jwt_token(:'r1') AS rotated \gset
RESET ROLE;
SELECT pg_temp.js_assert(:'rotated'::jsonb->>'success' = 'true' AND :'rotated'::jsonb->>'access_token' ~ '^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$', 'refresh_jwt_token no longer returns a token');
ROLLBACK;
