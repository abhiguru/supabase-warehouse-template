-- Retain consumed hashes solely for revocation, never for refresh acceptance.
-- Rows inherit the session's fixed expiry and are removed when that session ends.
CREATE TABLE warehouse_security.consumed_refresh_tokens (
  token_hash text PRIMARY KEY,
  session_id uuid NOT NULL REFERENCES warehouse_security.refresh_sessions(id) ON DELETE CASCADE,
  expires_at timestamptz NOT NULL
);
CREATE INDEX consumed_refresh_tokens_expiry ON warehouse_security.consumed_refresh_tokens(expires_at);
REVOKE ALL ON warehouse_security.consumed_refresh_tokens FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.refresh_jwt_token(p_refresh_token text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public, extensions AS $$
DECLARE session_row warehouse_security.refresh_sessions; result jsonb; supplied_hash text;
BEGIN
  IF p_refresh_token IS NULL OR length(p_refresh_token) <> 64 THEN RETURN jsonb_build_object('success', false, 'message', 'Invalid refresh token'); END IF;
  -- Shared lock with logout guarantees its next statement sees rotation history.
  PERFORM pg_advisory_xact_lock(hashtextextended(p_refresh_token, 71041));
  supplied_hash := encode(extensions.digest(p_refresh_token, 'sha256'), 'hex');
  SELECT * INTO session_row FROM warehouse_security.refresh_sessions
    WHERE token_hash = supplied_hash AND expires_at > now() FOR UPDATE;
  IF session_row.id IS NULL OR NOT EXISTS (SELECT 1 FROM public.user_profiles WHERE auth_user_id = session_row.user_id AND active) THEN
    RETURN jsonb_build_object('success', false, 'message', 'Invalid refresh token');
  END IF;
  DELETE FROM warehouse_security.consumed_refresh_tokens WHERE expires_at <= now();
  INSERT INTO warehouse_security.consumed_refresh_tokens(token_hash, session_id, expires_at)
    VALUES (supplied_hash, session_row.id, session_row.expires_at);
  result := warehouse_security.issue_session(session_row.user_id, session_row.id);
  RETURN result || jsonb_build_object('success', true);
END $$;

CREATE OR REPLACE FUNCTION public.logout_session(p_refresh_token text) RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, extensions AS $$
DECLARE supplied_hash text; target uuid;
BEGIN
  IF p_refresh_token IS NULL OR length(p_refresh_token) <> 64 THEN RETURN true; END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended(p_refresh_token, 71041));
  supplied_hash := encode(extensions.digest(p_refresh_token, 'sha256'), 'hex');
  SELECT id INTO target FROM warehouse_security.refresh_sessions WHERE token_hash = supplied_hash;
  IF target IS NULL THEN
    SELECT session_id INTO target FROM warehouse_security.consumed_refresh_tokens WHERE token_hash = supplied_hash AND expires_at > now();
  END IF;
  DELETE FROM warehouse_security.refresh_sessions WHERE id = target;
  RETURN true;
END $$;
NOTIFY pgrst, 'reload schema';
