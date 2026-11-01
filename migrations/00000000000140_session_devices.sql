-- Migration 140: signed-in devices (review finding M10). A person's sessions can be listed and one of them signed out, and a person keeps
-- at most the newest 10 sessions (owner decision).
--
--  * warehouse_security.refresh_sessions records where a session was made: last_refreshed_at, created_ip (the source address of the
--    sign-in), user_agent (cut to 300 characters) and label (reserved for a device name, at most 60 characters; nothing writes it yet).
--  * warehouse_security.issue_session takes the source address and user agent of a sign-in, stamps last_refreshed_at on every refresh
--    and, after a new session, deletes all but that person's newest 10 (consumed_refresh_tokens follow by ON DELETE CASCADE, so a token
--    of an evicted session is unknown afterwards and cannot be replayed). The old two-argument signature goes; every call with one or
--    two arguments binds to the new function through its defaults.
--  * The sign-in RPCs (operator_verify_otp, operator_central_exchange, operator_break_glass_sign_in) gain a last parameter p_user_agent and
--    pass it, with the source address they already take (p_ip_address), to issue_session. The signature each had before stays as a thin
--    wrapper that passes NULL, so an edge function that was not updated keeps working. The new signatures have no parameter defaults
--    (a default would make a call with the old argument list ambiguous). operator_verify_otp, which had a definition file, is written out
--    here in full with the user agent passed on, and its definition file is removed (a function whose signature changes has none).
--  * public.list_user_sessions(p_user_id) and public.revoke_session(p_session_id).
--
-- Nothing here creates, alters or drops a role.

SET LOCAL maintenance_work_mem = '256MB';

-- ===== 1. The columns =====
ALTER TABLE warehouse_security.refresh_sessions
  ADD COLUMN last_refreshed_at timestamptz,
  ADD COLUMN created_ip inet,
  ADD COLUMN user_agent text CONSTRAINT refresh_sessions_user_agent_len CHECK (char_length(user_agent) <= 300),
  ADD COLUMN label text CONSTRAINT refresh_sessions_label_len CHECK (char_length(label) <= 60);
COMMENT ON COLUMN warehouse_security.refresh_sessions.last_refreshed_at IS 'Migration 140: when the session was made or last refreshed.';
COMMENT ON COLUMN warehouse_security.refresh_sessions.created_ip IS 'Migration 140: source address of the sign-in (CF-Connecting-IP); shown masked (IPv4 /24, IPv6 /48); deleted with the session.';
COMMENT ON COLUMN warehouse_security.refresh_sessions.user_agent IS 'Migration 140: the app''s user agent at sign-in, at most 300 characters; deleted with the session.';
COMMENT ON COLUMN warehouse_security.refresh_sessions.label IS 'Migration 140: a device name, at most 60 characters (reserved; nothing writes it yet).';
CREATE INDEX refresh_sessions_user_created ON warehouse_security.refresh_sessions (user_id, created_at DESC);

-- ===== 2. issue_session: where it was made, last refresh, the newest 10 (otherwise as migration 132) =====
DROP FUNCTION warehouse_security.issue_session(uuid, uuid);
CREATE FUNCTION warehouse_security.issue_session(p_user uuid, p_session uuid DEFAULT NULL::uuid, p_ip inet DEFAULT NULL::inet, p_user_agent text DEFAULT NULL::text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'extensions'
    AS $$
DECLARE refresh text; session_id uuid; sliding boolean; idle_seconds integer := warehouse_security.session_idle_seconds(); max_seconds integer := warehouse_security.session_max_seconds();
BEGIN
  SELECT p.enrollment_status = 'approved' INTO sliding FROM public.user_profiles p WHERE p.auth_user_id = p_user AND p.active;
  IF NOT FOUND THEN RAISE EXCEPTION 'Active account required' USING ERRCODE = 'P0002'; END IF;
  refresh := encode(extensions.gen_random_bytes(32), 'hex');
  IF p_session IS NULL THEN
    INSERT INTO warehouse_security.refresh_sessions(user_id, token_hash, expires_at, last_refreshed_at, created_ip, user_agent)
    VALUES (p_user, encode(extensions.digest(refresh, 'sha256'), 'hex'),
      now() + CASE WHEN sliding THEN make_interval(secs => idle_seconds) ELSE interval '7 days' END, now(), p_ip, left(p_user_agent, 300))
    RETURNING id INTO session_id;
    -- Only the newest 10 sessions of the person stay (the new one always does). The tokens recorded for a deleted session go with it
    -- (consumed_refresh_tokens.session_id ON DELETE CASCADE), so none of them is accepted or recognised afterwards.
    DELETE FROM warehouse_security.refresh_sessions s
    WHERE s.user_id = p_user AND s.id <> session_id
      AND s.id NOT IN (SELECT k.id FROM warehouse_security.refresh_sessions k
        WHERE k.user_id = p_user AND k.id <> session_id ORDER BY k.created_at DESC, k.id LIMIT 9);
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
  RETURN warehouse_security.sign_access_token(p_user, session_id) || jsonb_build_object('refresh_token', refresh);
END $$;
ALTER FUNCTION warehouse_security.issue_session(uuid, uuid, inet, text) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION warehouse_security.issue_session(uuid, uuid, inet, text) FROM PUBLIC, anon, authenticated;

-- ===== 3. The sign-in RPCs take the user agent =====
-- 3a. operator_verify_otp: the function migrations 000 to 126 left with the break-glass change of migration 132 (until now the text of
-- migrations/definitions/operator_verify_otp.sql, which this migration removes: a function whose signature changes has no definition file),
-- with the user agent as a sixth parameter passed to issue_session. From here on it is changed by numbered migrations.
CREATE FUNCTION public.operator_verify_otp(p_phone_number text, p_otp_code text, p_name text, p_display_name text, p_ip_address inet, p_user_agent text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'extensions'
AS $function$
DECLARE phone text; challenge public.otp_verifications; profile public.user_profiles;
  secret text; token text; session_data jsonb; expires timestamptz;
  candidates uuid[]; clean_name text; clean_display text; created_now boolean := false;
  glass jsonb; glass_id uuid; glass_used boolean := false;
BEGIN
  IF COALESCE((SELECT value FROM warehouse_security.auth_config WHERE key='auth_mode'),'') <> 'operator' THEN
    RETURN jsonb_build_object('success',false,'code','unavailable');
  END IF;
  phone := warehouse_security.normalize_phone(p_phone_number);
  PERFORM pg_advisory_xact_lock(hashtextextended(phone,71044));
  IF p_ip_address IS NOT NULL AND EXISTS (SELECT 1 FROM public.ip_rate_limits i WHERE i.ip_address=p_ip_address
      AND i.verify_failures>=warehouse_security.otp_source_failure_cap() AND i.verify_window>=now()-interval '1 hour') THEN
    RETURN jsonb_build_object('success',false,'code','rate_limited');
  END IF;
  -- Every accepted, unexpired, unconsumed code for this phone with attempts
  -- left for this source is a live candidate; a wrong guess counts against all of them.
  SELECT array_agg(v.id) INTO candidates FROM public.otp_verifications v
    WHERE v.phone_number=phone AND NOT v.verified AND v.delivery_status='accepted' AND v.expires_at>now()
      AND v.attempts+v.source_attempts < 5
      AND (v.ip_address IS NOT DISTINCT FROM p_ip_address OR v.attempts < 2);
  IF candidates IS NOT NULL THEN
    UPDATE public.otp_verifications v SET
      source_attempts=v.source_attempts+CASE WHEN v.ip_address IS NOT DISTINCT FROM p_ip_address THEN 1 ELSE 0 END,
      attempts=v.attempts+CASE WHEN v.ip_address IS NOT DISTINCT FROM p_ip_address THEN 0 ELSE 1 END
      WHERE v.id=ANY(candidates);
    IF p_otp_code ~ '^[0-9]{6}$' THEN
      SELECT value INTO secret FROM warehouse_security.auth_config WHERE key='jwt_secret';
      SELECT c.* INTO challenge FROM public.otp_verifications c
        WHERE c.id=ANY(candidates)
          AND c.otp_code_hash=encode(extensions.hmac(phone||':'||p_otp_code||':'||c.id::text,secret,'sha256'),'hex')
        ORDER BY c.created_at DESC LIMIT 1;
    END IF;
  END IF;
  -- Migration 126, widened in 132: a break-glass code (warehouse_security.break_glass_code) is looked for only when no SMS code matched. It
  -- belongs to an active, approved administrator, supervisor or staff member (a person: not a service account, not deleted) with this
  -- number, works once, expires after 10 minutes and ends after five wrong tries from any address. A wrong try is also a failed
  -- verification of the source, below. warehouse_security.redeem_break_glass is the one place that checks and uses a code; the session
  -- of such a sign-in ends 24 hours later (limit_break_glass_session). The app's own sign-in for a code is operator_break_glass_sign_in.
  IF challenge.id IS NULL AND p_otp_code ~ '^[0-9]{6}$' THEN
    glass := warehouse_security.redeem_break_glass(phone,p_otp_code,p_ip_address);
    IF glass->>'result' = 'ok' THEN glass_id := (glass->>'id')::uuid; glass_used := true; END IF;
  END IF;
  IF challenge.id IS NULL AND NOT glass_used THEN
    IF p_ip_address IS NOT NULL THEN
      INSERT INTO public.ip_rate_limits AS i(ip_address,verify_failures,verify_window) VALUES (p_ip_address,1,now())
      ON CONFLICT(ip_address) DO UPDATE SET
        verify_failures=CASE WHEN i.verify_window<now()-interval '1 hour' THEN 1 ELSE i.verify_failures+1 END,
        verify_window=CASE WHEN i.verify_window<now()-interval '1 hour' THEN now() ELSE i.verify_window END,
        updated_at=now();
    END IF;
    RETURN jsonb_build_object('success',false,'code','invalid_otp');
  END IF;
  UPDATE public.otp_verifications SET verified=true,verified_at=now(),otp_code_hash=NULL
    WHERE phone_number=phone AND NOT verified AND delivery_status='accepted';
  SELECT * INTO profile FROM public.user_profiles WHERE mobile=phone FOR UPDATE;
  IF profile.id IS NULL THEN
    IF NOT warehouse_security.enrollment_allowed(p_ip_address) THEN
      RETURN jsonb_build_object('success',false,'code','enrollment_limited');
    END IF;
    clean_name := COALESCE(warehouse_security.clean_person_name(p_name),'New customer');
    clean_display := COALESCE(warehouse_security.clean_person_name(p_display_name),clean_name);
    INSERT INTO public.user_profiles(auth_user_id,mobile,name,display_name,role,active,mobile_verified,mobile_verified_at,enrollment_status)
    VALUES (gen_random_uuid(),phone,clean_name,clean_display,
      'customer',false,true,now(),'pending') RETURNING * INTO profile;
    DELETE FROM warehouse_security.enrollment_log WHERE created_at<now()-interval '2 days';
    INSERT INTO warehouse_security.enrollment_log(ip_address) VALUES (p_ip_address);
    created_now := true;
  END IF;
  IF profile.enrollment_status IN ('rejected','disabled') OR (NOT profile.active AND profile.enrollment_status<>'pending') THEN
    RETURN jsonb_build_object('success',false,'code','account_unavailable');
  END IF;
  IF NOT created_now AND NOT glass_used THEN
    -- Migration 96: the verified mark follows the refusal check.
    UPDATE public.user_profiles SET mobile_verified=true,mobile_verified_at=now() WHERE id=profile.id RETURNING * INTO profile;
  END IF;
  IF profile.enrollment_status='pending' THEN
    DELETE FROM warehouse_security.enrollment_tokens WHERE expires_at<=now();
    DELETE FROM warehouse_security.enrollment_tokens WHERE user_id=profile.auth_user_id;
    token := encode(extensions.gen_random_bytes(32),'hex'); expires:=now()+interval '7 days';
    INSERT INTO warehouse_security.enrollment_tokens(token_hash,user_id,expires_at)
      VALUES (encode(extensions.digest(token,'sha256'),'hex'),profile.auth_user_id,expires);
    RETURN jsonb_build_object('success',true,'data',jsonb_build_object('action','pending','enrollment_token',token,
      'expires_at',expires,'user',jsonb_build_object('id',profile.id,'name',profile.name,'display_name',profile.display_name,
      'mobile',profile.mobile,'role',profile.role,'active',false,'enrollment_status','pending')));
  END IF;
  IF p_ip_address IS NOT NULL AND NOT glass_used THEN
    INSERT INTO warehouse_security.otp_trusted_sources(phone_number,ip_address) VALUES (phone,p_ip_address)
    ON CONFLICT(phone_number,ip_address) DO UPDATE SET last_verified=now();
    -- Keep the five most recent addresses of this phone and drop stale ones.
    DELETE FROM warehouse_security.otp_trusted_sources t WHERE t.phone_number=phone
      AND (t.last_verified<now()-interval '90 days' OR t.ip_address NOT IN (
        SELECT k.ip_address FROM warehouse_security.otp_trusted_sources k WHERE k.phone_number=phone
        ORDER BY k.last_verified DESC, k.ip_address LIMIT 5));
  END IF;
  IF glass_used THEN
    INSERT INTO public.audit_log(table_name,action,user_id,new_data,ip_address)
    VALUES ('break_glass','SIGN_IN',profile.auth_user_id,
      jsonb_build_object('mobile',phone,'name',profile.name,'code_id',glass_id),p_ip_address);
  END IF;
  session_data := warehouse_security.issue_session(profile.auth_user_id, NULL, p_ip_address, p_user_agent);
  IF glass_used THEN session_data := warehouse_security.limit_break_glass_session(session_data); END IF;
  RETURN jsonb_build_object('success',true,'data',jsonb_build_object('action','login','user',to_jsonb(profile),'session',session_data));
END $function$;
ALTER FUNCTION public.operator_verify_otp(text, text, text, text, inet, text) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION public.operator_verify_otp(text, text, text, text, inet, text) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.operator_verify_otp(text, text, text, text, inet, text) TO service_role;
COMMENT ON FUNCTION public.operator_verify_otp(text, text, text, text, inet, text) IS 'Migration 140: the SMS code sign-in (and, for a worker, a break-glass code), as before, and records the source address and the user agent with the session.';

-- 3b. operator_central_exchange: the new ten-argument function is the old body with two calls that carry the user agent.
DO $do$
DECLARE v_body text; v_m1 constant text := 'otp_answer := public.operator_verify_otp(profile.mobile,p_otp_code,NULL,NULL,p_ip_address);';
  v_m2 constant text := 'session_data:=warehouse_security.issue_session(profile.auth_user_id);';
BEGIN
  SELECT p.prosrc INTO v_body FROM pg_proc p WHERE p.oid = 'public.operator_central_exchange(text,text,text,text,timestamptz,text,text,inet,text)'::regprocedure;
  IF v_body IS NULL OR position('$wh_body$' IN v_body) > 0
     OR (length(v_body) - length(replace(v_body, v_m1, ''))) <> length(v_m1)
     OR (length(v_body) - length(replace(v_body, v_m2, ''))) <> length(v_m2) THEN
    RAISE EXCEPTION 'operator_central_exchange: the two expected calls are not found exactly once';
  END IF;
  v_body := replace(v_body, v_m1, 'otp_answer := public.operator_verify_otp(profile.mobile,p_otp_code,NULL,NULL,p_ip_address,p_user_agent);');
  v_body := replace(v_body, v_m2, 'session_data:=warehouse_security.issue_session(profile.auth_user_id,NULL,p_ip_address,p_user_agent);');
  EXECUTE 'CREATE FUNCTION public.operator_central_exchange(p_issuer text, p_subject text, p_phone_number text, p_token_id text, p_token_expires_at timestamptz, '
    || 'p_name text, p_display_name text, p_ip_address inet, p_otp_code text, p_user_agent text) RETURNS jsonb '
    || 'LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''pg_catalog'', ''public'', ''extensions'' AS $wh_body$' || v_body || '$wh_body$';
END $do$;
ALTER FUNCTION public.operator_central_exchange(text, text, text, text, timestamptz, text, text, inet, text, text) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION public.operator_central_exchange(text, text, text, text, timestamptz, text, text, inet, text, text) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.operator_central_exchange(text, text, text, text, timestamptz, text, text, inet, text, text) TO service_role;

-- 3c. operator_break_glass_sign_in: the same for the one call in migration 132's function.
DO $do$
DECLARE v_body text; v_m1 constant text := 'warehouse_security.limit_break_glass_session(warehouse_security.issue_session(profile.auth_user_id));';
BEGIN
  SELECT p.prosrc INTO v_body FROM pg_proc p WHERE p.oid = 'public.operator_break_glass_sign_in(text,text,inet)'::regprocedure;
  IF v_body IS NULL OR position('$wh_body$' IN v_body) > 0 OR (length(v_body) - length(replace(v_body, v_m1, ''))) <> length(v_m1) THEN
    RAISE EXCEPTION 'operator_break_glass_sign_in: the expected call is not found exactly once';
  END IF;
  v_body := replace(v_body, v_m1, 'warehouse_security.limit_break_glass_session(warehouse_security.issue_session(profile.auth_user_id,NULL,p_ip_address,p_user_agent));');
  EXECUTE 'CREATE FUNCTION public.operator_break_glass_sign_in(p_phone_number text, p_code text, p_ip_address inet, p_user_agent text) RETURNS jsonb '
    || 'LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''pg_catalog'', ''public'', ''extensions'' AS $wh_body$' || v_body || '$wh_body$';
END $do$;
ALTER FUNCTION public.operator_break_glass_sign_in(text, text, inet, text) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION public.operator_break_glass_sign_in(text, text, inet, text) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.operator_break_glass_sign_in(text, text, inet, text) TO service_role;
COMMENT ON FUNCTION public.operator_break_glass_sign_in(text, text, inet, text) IS 'Migration 140: as the three-argument form, and records the source address and the user agent with the session.';

-- 3d. The previous signatures: thin wrappers (grants as before).
CREATE OR REPLACE FUNCTION public.operator_verify_otp(p_phone_number text, p_otp_code text, p_name text DEFAULT NULL::text, p_display_name text DEFAULT NULL::text, p_ip_address inet DEFAULT NULL::inet) RETURNS jsonb
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'extensions'
    AS $$ SELECT public.operator_verify_otp(p_phone_number, p_otp_code, p_name, p_display_name, p_ip_address, NULL::text) $$;
CREATE OR REPLACE FUNCTION public.operator_central_exchange(p_issuer text, p_subject text, p_phone_number text, p_token_id text, p_token_expires_at timestamptz, p_name text DEFAULT NULL::text, p_display_name text DEFAULT NULL::text, p_ip_address inet DEFAULT NULL::inet, p_otp_code text DEFAULT NULL::text) RETURNS jsonb
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'extensions'
    AS $$ SELECT public.operator_central_exchange(p_issuer, p_subject, p_phone_number, p_token_id, p_token_expires_at, p_name, p_display_name, p_ip_address, p_otp_code, NULL::text) $$;
CREATE OR REPLACE FUNCTION public.operator_break_glass_sign_in(p_phone_number text, p_code text, p_ip_address inet DEFAULT NULL::inet) RETURNS jsonb
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'extensions'
    AS $$ SELECT public.operator_break_glass_sign_in(p_phone_number, p_code, p_ip_address, NULL::text) $$;
REVOKE ALL ON FUNCTION public.operator_verify_otp(text, text, text, text, inet) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.operator_verify_otp(text, text, text, text, inet) TO service_role;
REVOKE ALL ON FUNCTION public.operator_central_exchange(text, text, text, text, timestamptz, text, text, inet, text) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.operator_central_exchange(text, text, text, text, timestamptz, text, text, inet, text) TO service_role;
REVOKE ALL ON FUNCTION public.operator_break_glass_sign_in(text, text, inet) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.operator_break_glass_sign_in(text, text, inet) TO service_role;
COMMENT ON FUNCTION public.operator_verify_otp(text, text, text, text, inet) IS 'Migration 140: the signature before the user agent was added; calls the six-argument form with NULL.';
COMMENT ON FUNCTION public.operator_central_exchange(text, text, text, text, timestamptz, text, text, inet, text) IS 'Migration 140: the signature before the user agent was added; calls the ten-argument form with NULL.';
COMMENT ON FUNCTION public.operator_break_glass_sign_in(text, text, inet) IS 'Migration 140: the signature before the user agent was added; calls the four-argument form with NULL.';

-- ===== 4. list_user_sessions =====
CREATE FUNCTION public.list_user_sessions(p_user_id uuid) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'extensions'
    AS $$
DECLARE v_target_auth uuid; v_target_role text; v_caller_role text := warehouse_security.active_role();
  v_service boolean := COALESCE(auth.jwt()->>'role', '') = 'service_role'; v_current text := auth.jwt()->>'session_id'; v_sessions jsonb;
BEGIN
  PERFORM warehouse_security.authorize_rpc('list_user_sessions', jsonb_build_object());
  IF p_user_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'INVALID_INPUT', 'message', 'User ID is required');
  END IF;
  SELECT p.auth_user_id, p.role::text INTO v_target_auth, v_target_role FROM public.user_profiles p WHERE p.id = p_user_id AND p.deleted_at IS NULL;
  IF v_target_auth IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'NOT_FOUND', 'message', 'User not found');
  END IF;
  -- Administrators see every person's sessions; a supervisor those of everyone but administrators (as for the other user management).
  IF NOT v_service AND v_caller_role = 'supervisor' AND v_target_role = 'admin' THEN
    RETURN jsonb_build_object('success', false, 'error', 'PERMISSION_DENIED', 'message', 'Supervisors cannot see the sessions of administrators');
  END IF;
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'id', s.id, 'label', s.label, 'user_agent', s.user_agent,
      -- Masked: IPv4 to its /24, IPv6 to its /48.
      'created_ip', CASE WHEN s.created_ip IS NULL THEN NULL
                         ELSE text(network(set_masklen(s.created_ip, CASE family(s.created_ip) WHEN 4 THEN 24 ELSE 48 END))) END,
      'created_at', s.created_at, 'last_refreshed_at', COALESCE(s.last_refreshed_at, s.created_at), 'expires_at', s.expires_at,
      'is_current', s.id::text = v_current) ORDER BY s.created_at DESC, s.id), '[]'::jsonb)
    INTO v_sessions
    FROM warehouse_security.refresh_sessions s WHERE s.user_id = v_target_auth AND s.expires_at > now();
  RETURN jsonb_build_object('success', true, 'data', jsonb_build_object('sessions', v_sessions));
END $$;
ALTER FUNCTION public.list_user_sessions(uuid) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION public.list_user_sessions(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.list_user_sessions(uuid) TO authenticated, service_role;
COMMENT ON FUNCTION public.list_user_sessions(uuid) IS 'Migration 140: the unexpired sessions of a person (user_profiles.id), newest first, with the source address masked. Administrators; supervisors except for administrators.';

-- ===== 5. revoke_session =====
CREATE FUNCTION public.revoke_session(p_session_id uuid) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'extensions'
    AS $$
DECLARE v_owner uuid; v_owner_role text; v_label text; v_caller_role text := warehouse_security.active_role(); v_caller uuid := auth.uid();
  v_service boolean := COALESCE(auth.jwt()->>'role', '') = 'service_role'; v_current boolean := p_session_id::text = auth.jwt()->>'session_id';
  v_admin boolean; v_allowed boolean;
BEGIN
  PERFORM warehouse_security.authorize_rpc('revoke_session', jsonb_build_object());
  IF p_session_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'INVALID_INPUT', 'message', 'Session ID is required');
  END IF;
  v_admin := v_service OR v_caller_role = 'admin';
  SELECT s.user_id, s.label, p.role::text INTO v_owner, v_label, v_owner_role
    FROM warehouse_security.refresh_sessions s JOIN public.user_profiles p ON p.auth_user_id = s.user_id
    WHERE s.id = p_session_id FOR UPDATE OF s;
  IF v_owner IS NULL THEN
    IF v_admin THEN RETURN jsonb_build_object('success', false, 'error', 'NOT_FOUND', 'message', 'Session not found'); END IF;
    RETURN jsonb_build_object('success', true, 'revoked_current', false);
  END IF;
  -- An administrator, the owner, or a supervisor for a session of anyone but an administrator. Any other caller gets the answer
  -- an unknown id gets, and nothing is deleted, so the answer does not tell whether the session exists.
  v_allowed := v_admin OR v_owner = v_caller OR (v_caller_role = 'supervisor' AND v_owner_role <> 'admin');
  IF NOT v_allowed THEN
    RETURN jsonb_build_object('success', true, 'revoked_current', false);
  END IF;
  -- The recorded tokens of the session go with it (ON DELETE CASCADE).
  DELETE FROM warehouse_security.refresh_sessions WHERE id = p_session_id;
  INSERT INTO public.audit_log(table_name, action, user_id, old_data)
  VALUES ('refresh_sessions', 'REVOKE', v_caller, jsonb_build_object('session_id', p_session_id, 'user_id', v_owner, 'label', v_label));
  RETURN jsonb_build_object('success', true, 'revoked_current', v_current);
END $$;
ALTER FUNCTION public.revoke_session(uuid) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION public.revoke_session(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.revoke_session(uuid) TO authenticated, service_role;
COMMENT ON FUNCTION public.revoke_session(uuid) IS 'Migration 140: signs one device out: deletes the session (and its recorded tokens). The owner, an administrator, or a supervisor for anyone but an administrator; an unknown or not permitted id answers success without a change, except NOT_FOUND to an administrator.';

NOTIFY pgrst, 'reload schema';
