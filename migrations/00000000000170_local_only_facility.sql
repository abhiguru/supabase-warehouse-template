-- Migration 170 (WH-146): a facility with no domain and no internet, on its local network only.
--
--  1. Pairing codes, which replace the SMS code in a local-only facility. An administrator (or, for the first administrator, the operator on
--     the host: scripts/pairing-code.sh) makes a code for one person: 8 characters and a 32-byte secret, valid for 10 minutes, usable once.
--     The phone redeems it over the warehouse network (functions/pairing-redeem): the server proves it knows the secret first
--     (HMAC over the phone's nonce) and sends the new session, with its warehouse network key (WH-133, migration 163), encrypted under a
--     key derived from the secret. The secret is stored (the proof needs it) and is erased when the code is used, replaced or expired.
--     No API role has a grant on the table. Making and redeeming a code each write one audit row (no secret in it).
--  2. Server alerts: the monitoring checker (scripts/watch.mjs) of a local-only facility has no Slack; it writes the alerts that are firing to
--     warehouse_security.server_alerts, and administrators read them with get_server_alerts() (the banner at the top of the app's Home).
--     An alert that is no longer in the list the checker writes is cleared.
--  3. warehouse_security.auth_config 'ingress_mode': set by setup.sh (scripts/configure-ingress.sql) from compose.env. Pairing codes can be
--     made only while it is 'local-only'; an online facility cannot make one.
--
-- Needs migration 163 (the warehouse network key of a session, WH-133): the pairing session's key is the session's own.
-- Nothing here creates, alters or drops a role.

DO $guard$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'warehouse_security' AND table_name = 'refresh_sessions' AND column_name = 'lan_key') THEN
    RAISE EXCEPTION 'migration 170 needs migration 163 (WH-133, the warehouse network key of a session): apply the release that carries both';
  END IF;
END $guard$;

-- ===== 1. Pairing codes =====
CREATE TABLE warehouse_security.pairing_codes (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id       uuid NOT NULL REFERENCES public.user_profiles(id) ON DELETE CASCADE,
  code          text NOT NULL CONSTRAINT pairing_codes_code_shape CHECK (code ~ '^[2-9A-HJKMNP-TV-Z]{8}$'),
  secret        bytea CONSTRAINT pairing_codes_secret_len CHECK (secret IS NULL OR octet_length(secret) = 32),
  made_by       uuid REFERENCES public.user_profiles(id) ON DELETE SET NULL,   -- NULL: the operator on the host
  created_at    timestamptz NOT NULL DEFAULT now(),
  expires_at    timestamptz NOT NULL DEFAULT now() + interval '10 minutes',
  used_at       timestamptz,
  revoked_at    timestamptz
);
ALTER TABLE warehouse_security.pairing_codes OWNER TO supabase_admin;
ALTER TABLE warehouse_security.pairing_codes ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE warehouse_security.pairing_codes FROM PUBLIC, anon, authenticated, service_role;
-- A live code is unique: two people can never hold the same 8 characters at once.
CREATE UNIQUE INDEX pairing_codes_live_code ON warehouse_security.pairing_codes (code) WHERE used_at IS NULL AND revoked_at IS NULL;
CREATE INDEX pairing_codes_user_idx ON warehouse_security.pairing_codes (user_id, created_at DESC);
COMMENT ON TABLE warehouse_security.pairing_codes IS 'WH-146: sign-in codes of a local-only facility. secret is erased when the code is used, replaced or expired. No API role has a grant.';

CREATE TABLE warehouse_security.pairing_attempts (
  id  bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  ip  text NOT NULL,
  at  timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE warehouse_security.pairing_attempts OWNER TO supabase_admin;
ALTER TABLE warehouse_security.pairing_attempts ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE warehouse_security.pairing_attempts FROM PUBLIC, anon, authenticated, service_role;
CREATE INDEX pairing_attempts_ip_at ON warehouse_security.pairing_attempts (ip, at DESC);

-- The core: makes a code for one profile. p_by is the administrator's profile, or NULL for the operator on the host.
CREATE FUNCTION warehouse_security.make_pairing_code(p_user_id uuid, p_by uuid) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'extensions'
    AS $$
DECLARE
  alphabet constant text := '23456789ABCDEFGHJKMNPQRSTVWXYZ';   -- 30 characters; no 0 O 1 I L U
  v_profile record; v_code text; v_secret bytea; v_row uuid; v_tries int := 0; b int; i int; v_expires timestamptz;
BEGIN
  IF coalesce((SELECT value FROM warehouse_security.auth_config WHERE key = 'ingress_mode'), '') <> 'local-only' THEN
    RAISE EXCEPTION 'Pairing codes exist only in a local-only facility' USING ERRCODE = '42501';
  END IF;
  SELECT p.id, p.auth_user_id, p.name, p.role::text AS role, p.active, p.enrollment_status, p.is_service_account, p.deleted_at INTO v_profile
  FROM public.user_profiles p WHERE p.id = p_user_id;
  IF NOT FOUND OR v_profile.deleted_at IS NOT NULL THEN RAISE EXCEPTION 'User not found' USING ERRCODE = 'P0002'; END IF;
  IF NOT v_profile.active OR v_profile.is_service_account OR v_profile.enrollment_status <> 'approved' OR v_profile.auth_user_id IS NULL THEN
    RAISE EXCEPTION 'This person cannot be given a sign-in code' USING ERRCODE = '42501';
  END IF;
  -- An earlier unused code of the same person is replaced.
  UPDATE warehouse_security.pairing_codes SET revoked_at = now(), secret = NULL WHERE user_id = p_user_id AND used_at IS NULL AND revoked_at IS NULL;
  LOOP
    v_code := '';
    FOR i IN 1..8 LOOP
      LOOP b := get_byte(extensions.gen_random_bytes(1), 0); EXIT WHEN b < 240; END LOOP;   -- 240 = 8 x 30: no modulo bias
      v_code := v_code || substr(alphabet, (b % 30) + 1, 1);
    END LOOP;
    v_secret := extensions.gen_random_bytes(32);
    BEGIN
      INSERT INTO warehouse_security.pairing_codes (user_id, code, secret, made_by) VALUES (p_user_id, v_code, v_secret, p_by)
      RETURNING id, expires_at INTO v_row, v_expires;
      EXIT;
    EXCEPTION WHEN unique_violation THEN
      v_tries := v_tries + 1;
      IF v_tries > 20 THEN RAISE EXCEPTION 'Could not make a sign-in code; try again'; END IF;
    END;
  END LOOP;
  INSERT INTO public.audit_log (table_name, action, user_id, old_data, new_data)
  VALUES ('pairing_codes', 'PAIRING_CODE_MADE', (SELECT auth_user_id FROM public.user_profiles WHERE id = p_by),
    NULL, jsonb_build_object('pairing_id', v_row, 'for_user', p_user_id, 'expires_at', v_expires, 'by_operator', p_by IS NULL));
  RETURN jsonb_build_object('pairing_id', v_row, 'code', v_code, 'secret', encode(v_secret, 'hex'), 'expires_at', v_expires,
    'user', jsonb_build_object('id', p_user_id, 'name', v_profile.name, 'role', v_profile.role));
END $$;
ALTER FUNCTION warehouse_security.make_pairing_code(uuid, uuid) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION warehouse_security.make_pairing_code(uuid, uuid) FROM PUBLIC, anon, authenticated, service_role;

-- The RPC of the app: administrators only (authorize_rpc), from the signed-in session.
CREATE FUNCTION public.make_pairing_code(p_profile_id uuid) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public'
    AS $$
DECLARE v_caller uuid;
BEGIN
  PERFORM warehouse_security.authorize_rpc('make_pairing_code', jsonb_build_object());
  SELECT id INTO v_caller FROM public.user_profiles WHERE auth_user_id = auth.uid() AND active;
  RETURN jsonb_build_object('success', true, 'data', warehouse_security.make_pairing_code(p_profile_id, v_caller));
END $$;
ALTER FUNCTION public.make_pairing_code(uuid) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION public.make_pairing_code(uuid) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.make_pairing_code(uuid) TO authenticated, service_role;

-- The operator's door (scripts/pairing-code.sh, as supabase_admin on the host): a code for the profile with this mobile number.
CREATE FUNCTION warehouse_security.make_pairing_code_for_phone(p_phone text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public'
    AS $$
DECLARE v_id uuid;
BEGIN
  SELECT p.id INTO v_id FROM public.user_profiles p WHERE p.mobile = p_phone AND p.deleted_at IS NULL ORDER BY p.created_at LIMIT 1;
  IF v_id IS NULL THEN RAISE EXCEPTION 'No user with this mobile number'; END IF;
  RETURN warehouse_security.make_pairing_code(v_id, NULL);
END $$;
ALTER FUNCTION warehouse_security.make_pairing_code_for_phone(text) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION warehouse_security.make_pairing_code_for_phone(text) FROM PUBLIC, anon, authenticated, service_role;

-- Redeeming (service role, called by functions/pairing-redeem). Answers:
--   {ok:true, secret:<hex>, session:<issue_session answer>, pairing_id}   the code was good; it is spent now (secret erased)
--   {ok:false, code:'PAIRING_CODE_INVALID'}                               unknown, used, replaced or expired
--   {ok:false, code:'rate_limited'}                                        more than 10 tries from this address in 10 minutes
CREATE FUNCTION public.redeem_pairing_code(p_code text, p_ip text, p_user_agent text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'extensions'
    AS $$
DECLARE v_ip text := left(coalesce(p_ip, 'unknown'), 64); v_row record; v_secret bytea; v_session jsonb; v_auth uuid;
BEGIN
  IF coalesce((SELECT value FROM warehouse_security.auth_config WHERE key = 'ingress_mode'), '') <> 'local-only' THEN
    RETURN jsonb_build_object('ok', false, 'code', 'PAIRING_CODE_INVALID');
  END IF;
  DELETE FROM warehouse_security.pairing_attempts WHERE at < now() - interval '1 day';
  IF (SELECT count(*) FROM warehouse_security.pairing_attempts WHERE ip = v_ip AND at > now() - interval '10 minutes') >= 10 THEN
    RETURN jsonb_build_object('ok', false, 'code', 'rate_limited');
  END IF;
  INSERT INTO warehouse_security.pairing_attempts (ip) VALUES (v_ip);
  -- Expired codes lose their secret whenever anyone asks.
  UPDATE warehouse_security.pairing_codes SET secret = NULL WHERE secret IS NOT NULL AND (expires_at <= now() OR used_at IS NOT NULL OR revoked_at IS NOT NULL);
  IF p_code IS NULL OR p_code !~ '^[2-9A-HJKMNP-TV-Z]{8}$' THEN RETURN jsonb_build_object('ok', false, 'code', 'PAIRING_CODE_INVALID'); END IF;
  SELECT c.id, c.user_id, c.secret INTO v_row FROM warehouse_security.pairing_codes c
  WHERE c.code = p_code AND c.used_at IS NULL AND c.revoked_at IS NULL AND c.expires_at > now() AND c.secret IS NOT NULL
  FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'code', 'PAIRING_CODE_INVALID'); END IF;
  SELECT p.auth_user_id INTO v_auth FROM public.user_profiles p
  WHERE p.id = v_row.user_id AND p.active AND NOT p.is_service_account AND p.enrollment_status = 'approved' AND p.deleted_at IS NULL;
  v_secret := v_row.secret;
  UPDATE warehouse_security.pairing_codes SET used_at = now(), secret = NULL WHERE id = v_row.id;
  IF v_auth IS NULL THEN RETURN jsonb_build_object('ok', false, 'code', 'PAIRING_CODE_INVALID'); END IF;
  -- The same session a correct SMS code makes (migration 163 adds the warehouse network key to a new session's answer).
  v_session := warehouse_security.issue_session(v_auth, NULL, CASE WHEN v_ip ~ '^[0-9.]+$' THEN v_ip::inet END, p_user_agent);
  INSERT INTO public.audit_log (table_name, action, user_id, old_data, new_data)
  VALUES ('pairing_codes', 'PAIRING_CODE_REDEEMED', v_auth, NULL, jsonb_build_object('pairing_id', v_row.id, 'for_user', v_row.user_id, 'ip', v_ip));
  RETURN jsonb_build_object('ok', true, 'secret', encode(v_secret, 'hex'), 'session', v_session, 'pairing_id', v_row.id);
END $$;
ALTER FUNCTION public.redeem_pairing_code(text, text, text) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION public.redeem_pairing_code(text, text, text) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.redeem_pairing_code(text, text, text) TO service_role;

-- ===== 2. Server alerts =====
CREATE TABLE warehouse_security.server_alerts (
  id          text PRIMARY KEY CONSTRAINT server_alerts_id_len CHECK (char_length(id) BETWEEN 1 AND 100),
  summary     text NOT NULL,
  detail      text NOT NULL DEFAULT '',
  since       timestamptz NOT NULL,
  updated_at  timestamptz NOT NULL DEFAULT now(),
  cleared_at  timestamptz
);
ALTER TABLE warehouse_security.server_alerts OWNER TO supabase_admin;
ALTER TABLE warehouse_security.server_alerts ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE warehouse_security.server_alerts FROM PUBLIC, anon, authenticated, service_role;
COMMENT ON TABLE warehouse_security.server_alerts IS 'WH-146: the alerts the checker of a local-only facility has firing now (cleared_at IS NULL). Written by sync_server_alerts, read by get_server_alerts.';

-- p_alerts: [{id, summary, detail, since}] = everything firing now. Others that were active are cleared; cleared ones that fire again reopen.
CREATE FUNCTION warehouse_security.sync_server_alerts(p_alerts jsonb) RETURNS integer
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public'
    AS $$
DECLARE n integer;
BEGIN
  IF jsonb_typeof(p_alerts) <> 'array' THEN RAISE EXCEPTION 'p_alerts must be an array'; END IF;
  INSERT INTO warehouse_security.server_alerts (id, summary, detail, since, updated_at, cleared_at)
  SELECT a.id, left(a.summary, 200), left(coalesce(a.detail, ''), 300), a.since, now(), NULL
  FROM jsonb_to_recordset(p_alerts) AS a(id text, summary text, detail text, since timestamptz)
  WHERE a.id IS NOT NULL AND a.summary IS NOT NULL AND a.since IS NOT NULL
  ON CONFLICT (id) DO UPDATE SET summary = excluded.summary, detail = excluded.detail, updated_at = now(),
    since = CASE WHEN warehouse_security.server_alerts.cleared_at IS NULL THEN warehouse_security.server_alerts.since ELSE excluded.since END,
    cleared_at = NULL;
  GET DIAGNOSTICS n = ROW_COUNT;
  UPDATE warehouse_security.server_alerts SET cleared_at = now()
  WHERE cleared_at IS NULL AND id NOT IN (SELECT a.id FROM jsonb_to_recordset(p_alerts) AS a(id text) WHERE a.id IS NOT NULL);
  DELETE FROM warehouse_security.server_alerts WHERE cleared_at < now() - interval '30 days';
  RETURN n;
END $$;
ALTER FUNCTION warehouse_security.sync_server_alerts(jsonb) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION warehouse_security.sync_server_alerts(jsonb) FROM PUBLIC, anon, authenticated, service_role;

-- Administrators only (authorize_rpc). Answers the alerts firing now, oldest first: the banner lists them; "Details" shows since and detail.
CREATE FUNCTION public.get_server_alerts() RETURNS jsonb
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public'
    AS $$
BEGIN
  PERFORM warehouse_security.authorize_rpc('get_server_alerts', jsonb_build_object());
  RETURN jsonb_build_object('success', true, 'data', coalesce((
    SELECT jsonb_agg(jsonb_build_object('id', a.id, 'summary', a.summary, 'detail', a.detail, 'since', a.since) ORDER BY a.since, a.id)
    FROM warehouse_security.server_alerts a WHERE a.cleared_at IS NULL), '[]'::jsonb));
END $$;
ALTER FUNCTION public.get_server_alerts() OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION public.get_server_alerts() FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.get_server_alerts() TO authenticated, service_role;

NOTIFY pgrst, 'reload schema';
