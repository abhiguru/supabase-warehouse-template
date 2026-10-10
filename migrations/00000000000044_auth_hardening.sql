-- Authentication hardening (review, 2026-10-10).
--
-- 1. Refresh tokens: a replayed, already rotated token now ends its session
--    (reuse detection). A client that lost the answer to a rotation may send
--    the same token again within a short grace period and receives the same
--    successor, so a slow network does not sign anyone out.

-- ---------------------------------------------------------------------------
-- 1. Refresh-token reuse detection with an idempotent retry window
-- ---------------------------------------------------------------------------
-- The table keeps hashes only. To hand the same successor to a retry, the
-- successor is stored encrypted under a key derived from the consumed token
-- itself (AES-256, key = HMAC-SHA256 keyed by that token). Only a caller who
-- presents the consumed token can recover it; the stored row alone cannot.
ALTER TABLE warehouse_security.consumed_refresh_tokens
  ADD COLUMN consumed_at timestamptz,
  ADD COLUMN successor_wrap text;
INSERT INTO warehouse_security.auth_config(key,value) VALUES ('refresh_grace_seconds','60') ON CONFLICT DO NOTHING;

-- Signs an access token for an existing session without touching its refresh token.
CREATE FUNCTION warehouse_security.sign_access_token(p_user uuid, p_session uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public, extensions AS $$
DECLARE profile public.user_profiles; secret text; expiry bigint; access_token text; access_lifetime integer := 3600;
BEGIN
  SELECT * INTO STRICT profile FROM public.user_profiles WHERE auth_user_id = p_user AND active;
  SELECT value INTO secret FROM warehouse_security.auth_config WHERE key = 'jwt_secret';
  IF length(COALESCE(secret, '')) < 32 THEN RAISE EXCEPTION 'Auth configuration missing'; END IF;
  SELECT COALESCE((SELECT value::integer FROM warehouse_security.auth_config WHERE key = 'access_seconds'), 3600) INTO access_lifetime;
  access_lifetime := greatest(60, least(access_lifetime, 86400));
  expiry := extract(epoch FROM now())::bigint + access_lifetime;
  access_token := extensions.sign(jsonb_build_object('iss', 'supabase', 'aud', 'authenticated',
    'role', 'authenticated', 'sub', p_user, 'iat', extract(epoch FROM now())::bigint, 'exp', expiry,
    'session_id', p_session, 'phone', profile.mobile, 'user_role', profile.role,
    'user_metadata', jsonb_build_object('name', profile.name, 'display_name', profile.display_name, 'role', profile.role))::json, secret, 'HS256');
  RETURN jsonb_build_object('access_token', access_token,
    'expires_at', to_timestamp(expiry), 'expires_in', access_lifetime, 'token_type', 'bearer');
END $$;
REVOKE ALL ON FUNCTION warehouse_security.sign_access_token(uuid,uuid) FROM PUBLIC, anon, authenticated, service_role;

-- Same contract as before; the signing step now lives in sign_access_token.
CREATE OR REPLACE FUNCTION warehouse_security.issue_session(p_user uuid, p_session uuid DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public, extensions AS $$
DECLARE refresh text; session_id uuid;
BEGIN
  PERFORM 1 FROM public.user_profiles WHERE auth_user_id = p_user AND active;
  IF NOT FOUND THEN RAISE EXCEPTION 'Active account required' USING ERRCODE = 'P0002'; END IF;
  refresh := encode(extensions.gen_random_bytes(32), 'hex');
  IF p_session IS NULL THEN
    INSERT INTO warehouse_security.refresh_sessions(user_id, token_hash, expires_at)
    VALUES (p_user, encode(extensions.digest(refresh, 'sha256'), 'hex'), now() + interval '7 days') RETURNING id INTO session_id;
  ELSE
    UPDATE warehouse_security.refresh_sessions SET token_hash = encode(extensions.digest(refresh, 'sha256'), 'hex')
    WHERE id = p_session AND user_id = p_user AND expires_at > now() RETURNING id INTO session_id;
    IF session_id IS NULL THEN RAISE EXCEPTION 'Session expired'; END IF;
  END IF;
  RETURN warehouse_security.sign_access_token(p_user, session_id) || jsonb_build_object('refresh_token', refresh);
END $$;

CREATE OR REPLACE FUNCTION public.refresh_jwt_token(p_refresh_token text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public, extensions AS $$
DECLARE session_row warehouse_security.refresh_sessions; consumed warehouse_security.consumed_refresh_tokens;
  result jsonb; supplied_hash text; successor text; grace_text text; grace integer;
  rejected constant jsonb := jsonb_build_object('success', false, 'message', 'Invalid refresh token');
BEGIN
  IF p_refresh_token IS NULL OR length(p_refresh_token) <> 64 THEN RETURN rejected; END IF;
  -- Shared lock with logout guarantees its next statement sees rotation history.
  PERFORM pg_advisory_xact_lock(hashtextextended(p_refresh_token, 71041));
  supplied_hash := encode(extensions.digest(p_refresh_token, 'sha256'), 'hex');
  SELECT * INTO session_row FROM warehouse_security.refresh_sessions
    WHERE token_hash = supplied_hash AND expires_at > now() FOR UPDATE;
  IF session_row.id IS NULL THEN
    SELECT * INTO consumed FROM warehouse_security.consumed_refresh_tokens
      WHERE token_hash = supplied_hash AND expires_at > now();
    IF consumed.token_hash IS NULL THEN RETURN rejected; END IF;
    SELECT * INTO session_row FROM warehouse_security.refresh_sessions
      WHERE id = consumed.session_id AND expires_at > now() FOR UPDATE;
    IF session_row.id IS NULL THEN RETURN rejected; END IF;
    SELECT value INTO grace_text FROM warehouse_security.auth_config WHERE key = 'refresh_grace_seconds';
    grace := CASE WHEN grace_text ~ '^[0-9]{1,3}$' THEN least(grace_text::integer, 300) ELSE 60 END;
    -- Retry of the rotation that produced the session's current token: answer
    -- with that same token. Anything else (grace over, or a token from an
    -- earlier generation) is reuse.
    IF consumed.successor_wrap IS NOT NULL AND consumed.consumed_at > now() - make_interval(secs => grace) THEN
      BEGIN
        successor := convert_from(extensions.decrypt(decode(consumed.successor_wrap, 'hex'),
          extensions.hmac('refresh-successor', p_refresh_token, 'sha256'), 'aes'), 'UTF8');
      EXCEPTION WHEN OTHERS THEN successor := NULL;
      END;
      IF successor IS NOT NULL AND encode(extensions.digest(successor, 'sha256'), 'hex') = session_row.token_hash
        AND EXISTS (SELECT 1 FROM public.user_profiles WHERE auth_user_id = session_row.user_id AND active) THEN
        RETURN warehouse_security.sign_access_token(session_row.user_id, session_row.id)
          || jsonb_build_object('refresh_token', successor, 'success', true);
      END IF;
    END IF;
    -- Two parties hold tokens of this session; neither can be told from the
    -- thief, so the whole session ends and the user signs in again.
    DELETE FROM warehouse_security.refresh_sessions WHERE id = session_row.id;
    RAISE LOG 'Refresh token reuse: session % of user % revoked', session_row.id, session_row.user_id;
    RETURN rejected;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.user_profiles WHERE auth_user_id = session_row.user_id AND active) THEN
    RETURN rejected;
  END IF;
  DELETE FROM warehouse_security.consumed_refresh_tokens WHERE expires_at <= now();
  INSERT INTO warehouse_security.consumed_refresh_tokens(token_hash, session_id, expires_at, consumed_at)
    VALUES (supplied_hash, session_row.id, session_row.expires_at, now());
  result := warehouse_security.issue_session(session_row.user_id, session_row.id);
  UPDATE warehouse_security.consumed_refresh_tokens
    SET successor_wrap = encode(extensions.encrypt(convert_to(result->>'refresh_token', 'UTF8'),
      extensions.hmac('refresh-successor', p_refresh_token, 'sha256'), 'aes'), 'hex')
    WHERE token_hash = supplied_hash;
  RETURN result || jsonb_build_object('success', true);
END $$;
NOTIFY pgrst, 'reload schema';
