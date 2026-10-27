-- public.refresh_jwt_token: the definition setup applies after the numbered migrations whenever this file's checksum changes
-- (scripts/migration-plan.mjs, table warehouse_migrations.definitions). Edit the function here, never in a new migration.
-- Starts as the function migrations 000 to 126 leave (the numbered files that patched it stay as they are, never edited).
CREATE OR REPLACE FUNCTION public.refresh_jwt_token(p_refresh_token text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'extensions'
AS $function$
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
    VALUES (supplied_hash, session_row.id,
      -- Migration 126: kept as long as the session can last (it slides), so a replaced token is still recognised as reuse.
      greatest(session_row.expires_at, session_row.created_at + make_interval(secs => warehouse_security.session_max_seconds())), now());
  result := warehouse_security.issue_session(session_row.user_id, session_row.id);
  UPDATE warehouse_security.consumed_refresh_tokens
    SET successor_wrap = encode(extensions.encrypt(convert_to(result->>'refresh_token', 'UTF8'),
      extensions.hmac('refresh-successor', p_refresh_token, 'sha256'), 'aes'), 'hex')
    WHERE token_hash = supplied_hash;
  RETURN result || jsonb_build_object('success', true);
END $function$;

REVOKE ALL ON FUNCTION public.refresh_jwt_token(text) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.refresh_jwt_token(text) TO service_role, authenticated, anon;
