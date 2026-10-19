-- Migration 108, BEFORE it runs (pgjwt still installed): the new signer must produce the same token as
-- pgjwt's extensions.sign(payload, secret) for every payload below. tests/migrations.sh creates the function
-- under the name given in :fn (warehouse_security.<name>) from the block marked in the migration, then runs this file.
-- Writes nothing.
\set ON_ERROR_STOP on
-- psql variables are not expanded inside $$ bodies; hand the name over as a setting.
SELECT set_config('jwt108.fn', :'fn', false) \gset
DO $$
DECLARE
  fn text := current_setting('jwt108.fn');
  payloads text[] := ARRAY[
    -- the jwt.io HS256 example
    '{"sub":"1234567890","name":"John Doe","iat":1516239022}',
    -- base64 of these contain + and / (checked below)
    '{"a":"???>>>"}',
    '{"a":"~~~~~~~~~~>>>>>>>>>>????????"}',
    -- base64 padding (length not a multiple of 3, checked below)
    '{"a":1}',
    '{"a":12}',
    -- longer than 57 bytes, so the base64 text wraps at 76 characters
    '{"iss":"supabase","aud":"authenticated","role":"authenticated","sub":"6d5f0a9e-3f6a-4c1d-9a55-2f4f2f1e0a11","iat":1760000000,"exp":1760003600,"session_id":"0a1b2c3d-4e5f-6a7b-8c9d-0e1f2a3b4c5d","phone":"919000000021","user_role":"admin","user_metadata":{"name":"A long name for the wrapped line test","display_name":"Another long display name","role":"admin"}}',
    -- Gujarati text
    '{"name":"ગુરુ કોલ્ડ સ્ટોરેજ","display_name":"અભિનવ","role":"admin"}',
    -- escapes and unicode escapes are kept as written, spaces too
    '{ "a" : "line\nbreak ગ \"quoted\"" ,"b":[1, 2,3] }',
    '{}'
  ];
  secrets text[] := ARRAY['your-256-bit-secret', 'isolated-test-secret-not-for-any-deployment-12345', 'ગુપ્ત-સિક્રેટ-ключ-密钥-🔑-0123456789abcdef'];
  p text; s text; expected text; got text; compared integer := 0;
  plus_seen boolean := false; slash_seen boolean := false; pad_seen boolean := false;
BEGIN
  IF to_regprocedure('extensions.sign(json,text,text)') IS NULL THEN
    RAISE EXCEPTION 'jwt_sign_108_before: pgjwt is not installed, nothing to compare';
  END IF;
  FOREACH p IN ARRAY payloads LOOP
    plus_seen := plus_seen OR encode(convert_to(p, 'UTF8'), 'base64') LIKE '%+%';
    slash_seen := slash_seen OR encode(convert_to(p, 'UTF8'), 'base64') LIKE '%/%';
    pad_seen := pad_seen OR encode(convert_to(p, 'UTF8'), 'base64') LIKE '%=%';
    FOREACH s IN ARRAY secrets LOOP
      expected := extensions.sign(p::json, s);
      EXECUTE format('SELECT warehouse_security.%I($1::json, $2)', fn) INTO got USING p, s;
      IF got IS DISTINCT FROM expected THEN
        RAISE EXCEPTION 'jwt sign 108: differs for payload % secret %: pgjwt % new %', p, s, expected, got;
      END IF;
      IF expected ~ '[+/=\s]' THEN RAISE EXCEPTION 'jwt sign 108: token has +, /, = or whitespace: %', expected; END IF;
      compared := compared + 1;
    END LOOP;
  END LOOP;
  IF NOT (plus_seen AND slash_seen AND pad_seen) THEN
    RAISE EXCEPTION 'jwt sign 108: the payloads do not cover + (%), / (%) and = (%) in base64', plus_seen, slash_seen, pad_seen;
  END IF;
  -- the jwt.io token, written out
  EXECUTE format('SELECT warehouse_security.%I($1::json, $2)', fn) INTO got USING payloads[1], 'your-256-bit-secret';
  IF got <> 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9' || '.' || 'eyJzdWIiOiIxMjM0NTY3ODkwIiwibmFtZSI6IkpvaG4gRG9lIiwiaWF0IjoxNTE2MjM5MDIyfQ' || '.' || 'SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c' THEN
    RAISE EXCEPTION 'jwt sign 108: the jwt.io example gives %', got;
  END IF;
  RAISE NOTICE 'jwt_sign_108_before: % token pairs identical to pgjwt (% payloads x % secrets)', compared, array_length(payloads, 1), array_length(secrets, 1);
END $$;
