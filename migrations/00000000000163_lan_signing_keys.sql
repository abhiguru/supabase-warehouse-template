-- Migration 163: the warehouse network key (WH-133). Every session gets its own secret, which the phone uses to sign each request it
-- sends over the LAN fallback and to check each answer (docs/API_CONTRACT.md, "Signing on the LAN path"; docs/CONTAINER_SECURITY.md,
-- "LAN fallback (gateway-lan)").
--
--  * warehouse_security.refresh_sessions.lan_key: 32 random bytes, made with the session. Existing sessions get one now (a volatile
--    default is computed per row), so a phone that is already signed in receives its key at its next get-config over the internet.
--    The key stays the same when the session refreshes, and it goes with the row: sign-out, revocation (update_user_status(false),
--    revoke_session), expiry clean-up, the newest-10 rule and rotate-keys.sh all delete the row. No app role has a grant on the table.
--  * warehouse_security.issue_session hands the key out only when it makes a NEW session (a sign-in): the answer gains lan_key_id (the
--    session id) and lan_key (64 lowercase hex characters). A refresh (p_session given) never carries it, because a refresh may travel
--    over the plain-http LAN path. Otherwise the function is the one migration 140 left, word for word.
--  * public.lan_signing_key(p_key_id): the key of a live session (unexpired, not past its hard end, profile active) or NULL. Service role
--    only: the LAN signer (docker/lan-signer) and get-config call it. It is not an RPC of the app, so it does not go through
--    authorize_rpc, like operator_break_glass_open.
--
-- Nothing here creates, alters or drops a role.

-- ===== 1. The key =====
ALTER TABLE warehouse_security.refresh_sessions
  ADD COLUMN lan_key bytea NOT NULL DEFAULT extensions.gen_random_bytes(32)
    CONSTRAINT refresh_sessions_lan_key_len CHECK (octet_length(lan_key) = 32);
COMMENT ON COLUMN warehouse_security.refresh_sessions.lan_key IS 'Migration 163: the warehouse network key of this session (HMAC-SHA256 key of the LAN path); handed out only at sign-in and by get-config over https; deleted with the session; never logged.';

-- ===== 2. issue_session: the key in the answer of a new session (otherwise as migration 140) =====
CREATE OR REPLACE FUNCTION warehouse_security.issue_session(p_user uuid, p_session uuid DEFAULT NULL::uuid, p_ip inet DEFAULT NULL::inet, p_user_agent text DEFAULT NULL::text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'extensions'
    AS $$
DECLARE refresh text; session_id uuid; sliding boolean; idle_seconds integer := warehouse_security.session_idle_seconds(); max_seconds integer := warehouse_security.session_max_seconds();
  new_key bytea;
BEGIN
  SELECT p.enrollment_status = 'approved' INTO sliding FROM public.user_profiles p WHERE p.auth_user_id = p_user AND p.active;
  IF NOT FOUND THEN RAISE EXCEPTION 'Active account required' USING ERRCODE = 'P0002'; END IF;
  refresh := encode(extensions.gen_random_bytes(32), 'hex');
  IF p_session IS NULL THEN
    INSERT INTO warehouse_security.refresh_sessions(user_id, token_hash, expires_at, last_refreshed_at, created_ip, user_agent)
    VALUES (p_user, encode(extensions.digest(refresh, 'sha256'), 'hex'),
      now() + CASE WHEN sliding THEN make_interval(secs => idle_seconds) ELSE interval '7 days' END, now(), p_ip, left(p_user_agent, 300))
    RETURNING id, lan_key INTO session_id, new_key;
    -- The person's expired sessions go first; then only the newest 10 stay (the new one always does), ranked by last use, so a live
    -- session is never given up for an expired one. The tokens recorded for a deleted session go with it
    -- (consumed_refresh_tokens.session_id ON DELETE CASCADE), so none of them is accepted or recognised afterwards.
    DELETE FROM warehouse_security.refresh_sessions s
    WHERE s.user_id = p_user AND s.id <> session_id
      AND (s.expires_at <= now() OR s.hard_expires_at <= now()
        OR s.id NOT IN (SELECT k.id FROM warehouse_security.refresh_sessions k
          WHERE k.user_id = p_user AND k.id <> session_id AND k.expires_at > now() AND (k.hard_expires_at IS NULL OR k.hard_expires_at > now())
          ORDER BY COALESCE(k.last_refreshed_at, k.created_at) DESC, k.id LIMIT 9));
  ELSE
    -- A sliding session ends at the earlier of the idle time after this refresh and the absolute limit after sign-in; one already
    -- past the absolute limit (the operator lowered it) is not renewed. A session with a hard end (break-glass) never passes it.
    UPDATE warehouse_security.refresh_sessions s SET token_hash = encode(extensions.digest(refresh, 'sha256'), 'hex'),
      last_refreshed_at = now(),
      expires_at = least(
        CASE WHEN sliding THEN least(now() + make_interval(secs => idle_seconds), s.created_at + make_interval(secs => max_seconds))
             ELSE s.expires_at END,
        COALESCE(s.hard_expires_at, 'infinity'::timestamptz))
    WHERE s.id = p_session AND s.user_id = p_user AND s.expires_at > now()
      AND (s.hard_expires_at IS NULL OR s.hard_expires_at > now())
      AND (NOT sliding OR s.created_at + make_interval(secs => max_seconds) > now())
    RETURNING s.id INTO session_id;
    IF session_id IS NULL THEN RAISE EXCEPTION 'Session expired'; END IF;
  END IF;
  -- Migration 163: a sign-in (new session) carries the session's warehouse network key; a refresh never does.
  IF new_key IS NOT NULL THEN
    RETURN warehouse_security.sign_access_token(p_user, session_id) || jsonb_build_object('refresh_token', refresh,
      'lan_key_id', session_id, 'lan_key', encode(new_key, 'hex'));
  END IF;
  RETURN warehouse_security.sign_access_token(p_user, session_id) || jsonb_build_object('refresh_token', refresh);
END $$;
ALTER FUNCTION warehouse_security.issue_session(uuid, uuid, inet, text) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION warehouse_security.issue_session(uuid, uuid, inet, text) FROM PUBLIC, anon, authenticated;

-- ===== 3. The key of a live session, for the LAN signer and get-config =====
CREATE FUNCTION public.lan_signing_key(p_key_id uuid) RETURNS text
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public'
    AS $$
  SELECT encode(s.lan_key, 'hex')
  FROM warehouse_security.refresh_sessions s
  JOIN public.user_profiles p ON p.auth_user_id = s.user_id AND p.active
  WHERE s.id = p_key_id AND s.expires_at > now() AND (s.hard_expires_at IS NULL OR s.hard_expires_at > now());
$$;
ALTER FUNCTION public.lan_signing_key(uuid) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION public.lan_signing_key(uuid) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.lan_signing_key(uuid) TO service_role;
COMMENT ON FUNCTION public.lan_signing_key(uuid) IS 'Migration 163: the warehouse network key (hex) of a live session, or NULL. Service role only (docker/lan-signer, get-config).';

NOTIFY pgrst, 'reload schema';
