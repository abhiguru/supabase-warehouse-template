-- Migration 108: session tokens are signed by a function of this repository, and the extension pgjwt is removed.
--
-- Why, in plain English. The only thing the database used pgjwt for is to sign the access token of a session
-- (HS256, the secret from warehouse_security.auth_config). That is one HMAC and a few lines of base64, so the
-- extension, which the next database image does not ship, is not needed. warehouse_security.jwt_sign_hs256
-- produces exactly the bytes pgjwt's extensions.sign(payload, secret) produced: the header
-- {"alg":"HS256","typ":"JWT"}, the payload text of the json value as given, base64url without padding, and
-- HMAC-SHA256 over "header.payload" keyed by the UTF-8 bytes of the secret. Tokens already issued keep verifying
-- (PostgREST, Storage and Realtime verify with JWT_SECRET, not with the database) and no session is affected.
--
-- What changes, in this order:
--  1. warehouse_security.jwt_sign_hs256(json, text) is created. Nobody but its owner can execute it: it is
--     called only from SECURITY DEFINER code owned by the same role. (extensions.sign was executable by PUBLIC;
--     nothing outside warehouse_security.sign_access_token ever called it.)
--  2. warehouse_security.sign_access_token(uuid, uuid) calls it instead of extensions.sign. Its definition is
--     read from the catalog and patched in place, so owner, SECURITY DEFINER, search_path and grants stay as
--     they are; the patch stops, changing nothing, unless both markers occur exactly once.
--     issue_session and refresh_jwt_token only call sign_access_token and need no change.
--  3. The extension pgjwt is dropped, without CASCADE: nothing else depends on it (checked: no function
--     in the database mentions extensions.sign, extensions.verify, algorithm_sign or url_encode).
-- tests/migrations.sh compares the new function with extensions.sign for many payloads before this runs
-- (the marked block below is extracted by that test), tests/jwt_sign_108.sql checks the result after it.

-- BEGIN jwt_sign_hs256
CREATE OR REPLACE FUNCTION warehouse_security.jwt_sign_hs256(p_payload json, p_secret text) RETURNS text
LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE
SET search_path = pg_catalog, extensions
AS $$
  SELECT signing_input || '.' ||
         translate(encode(hmac(convert_to(signing_input, 'UTF8'), convert_to(p_secret, 'UTF8'), 'sha256'), 'base64'), E'+/=\n', '-_')
  FROM (SELECT translate(encode(convert_to('{"alg":"HS256","typ":"JWT"}', 'UTF8'), 'base64'), E'+/=\n', '-_') || '.' ||
               translate(encode(convert_to(p_payload::text, 'UTF8'), 'base64'), E'+/=\n', '-_') AS signing_input) s
$$;
-- END jwt_sign_hs256
REVOKE ALL ON FUNCTION warehouse_security.jwt_sign_hs256(json, text) FROM PUBLIC, anon, authenticated, service_role;
COMMENT ON FUNCTION warehouse_security.jwt_sign_hs256(json, text) IS
  'Migration 108: HS256 JWT, byte-identical to pgjwt extensions.sign(payload, secret). Internal: no API role can execute it.';

DO $patch$
DECLARE
  fn regprocedure := 'warehouse_security.sign_access_token(uuid,uuid)'::regprocedure;
  definition text;
  marker_call constant text := 'access_token := extensions.sign(';
  marker_tail constant text := '::json, secret, ''HS256'');';
BEGIN
  definition := pg_get_functiondef(fn);
  IF (length(definition) - length(replace(definition, marker_call, ''))) / length(marker_call) <> 1
     OR (length(definition) - length(replace(definition, marker_tail, ''))) / length(marker_tail) <> 1 THEN
    RAISE EXCEPTION 'Migration 108: sign_access_token does not have the expected extensions.sign call exactly once; nothing changed';
  END IF;
  definition := replace(definition, marker_call, 'access_token := warehouse_security.jwt_sign_hs256(');
  definition := replace(definition, marker_tail, '::json, secret);');
  EXECUTE definition;
END
$patch$;

-- Refuse, changing nothing more, if any function outside the pgjwt extension (and other than the new signer) still calls
-- a pgjwt function. The DROP below has no CASCADE, but function bodies are text and would only fail when called.
DO $guard$
DECLARE callers text;
BEGIN
  SELECT string_agg(p.oid::regprocedure::text, ', ' ORDER BY p.oid::regprocedure::text) INTO callers
  FROM pg_proc p
  WHERE p.prosrc ~ '(extensions\.)?\m(verify|url_encode|url_decode|algorithm_sign|try_cast_double)\s*\(|extensions\.sign\s*\('
    AND p.oid <> 'warehouse_security.jwt_sign_hs256(json,text)'::regprocedure
    AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.classid = 'pg_proc'::regclass AND d.objid = p.oid AND d.deptype = 'e');
  IF callers IS NOT NULL THEN
    RAISE EXCEPTION 'Migration 108: these functions still call pgjwt, so it cannot be dropped: %', callers;
  END IF;
END
$guard$;

DROP EXTENSION IF EXISTS pgjwt;
