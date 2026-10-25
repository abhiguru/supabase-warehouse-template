-- Migration 126: sliding sessions, per-source OTP limits in auth_config, and a break-glass administrator sign-in (owner decision of
-- 2026-10-25; production-readiness review items 2 and 20, records in the review folder of 2026-10-25).
--
--  * 1. Sliding sessions (item 2). Until now a session ended 7 days after sign-in, absolutely: a refresh only replaced the token, so an
--       MSG91 lapse (balance, DLT header, KYC) locked every user out within a week. Now, for a profile that is ACTIVE and APPROVED, each
--       refresh moves the end of the session to the earlier of
--           now() + session_idle_seconds        (default 2592000 = 30 days since the last refresh) and
--           sign-in + session_max_seconds       (default 7776000 = 90 days since sign-in, refresh_sessions.created_at),
--       so a person who uses the app within the idle time is not asked for an SMS code again before the absolute limit, and no session
--       lives longer than the limit. Both values are auth_config keys, clamped: idle 1 hour .. 365 days, max idle .. 1095 days (a value
--       that is not a whole number means the default). Any other active profile keeps the fixed 7 days and is never extended (check_session
--       admits only approved profiles anyway). A refresh of a session already past the absolute limit raises 'Session expired' (P0001),
--       which the app already treats as a definitive end (src/config/supabaseConfig.ts, isDefinitiveRefreshException). Disabling a user
--       (update_user_status(false)) and every other place that deletes sessions are unchanged. refresh_jwt_token is unchanged; its
--       consumed-token rows keep the session's end at the time of the refresh, so reuse detection works as before.
--  * 2. Per-source OTP limits (item 20) are auth_config keys with the old literals as defaults: otp_source_hourly_sends (30 SMS requests
--       an hour from one address, was `hourly_count >= 30` in operator_prepare_otp) and otp_source_hourly_failures (20 failed
--       verifications an hour from one address, was `verify_failures>=20` in operator_verify_otp). An optional otp_trusted_sources
--       (comma separated addresses or CIDR ranges, for example the facility's public Wi-Fi address) gets the higher
--       otp_trusted_source_hourly_sends (default 120); the effective send limit of such an address is the larger of the two. Entries that
--       are not an address are ignored. reset_otp_limits is unchanged (it clears the per-phone counts only).
--  * 3. Break-glass sign-in for an administrator while SMS does not work. warehouse_security.break_glass_code(phone) is executable by
--       supabase_admin only (session_user is checked as well, like bootstrap_first_admin). For an existing active, approved administrator
--       with that number it stores a one-time six-digit code valid for 10 minutes (HMAC-SHA256 keyed with the JWT secret, as the SMS codes
--       are: warehouse_security.break_glass_codes), ends any earlier open code of that number and returns the code once. The normal
--       operator_verify_otp accepts it, after an SMS code has been looked for and not found, so the app and the edge function's verify path
--       need no change. It works once, ends after five wrong tries (from any address), and counts against the source's failure limit like
--       any wrong code. A break-glass sign-in does not mark the number as verified and does not add the address to the phone's trusted
--       sources. Issuing and using a code each write a row to public.audit_log (table_name 'break_glass', action CODE_ISSUED or SIGN_IN,
--       user_id the administrator, ip_address the source of the sign-in; the code is never written). scripts/break-glass-admin.sh is the
--       operator command. public.operator_break_glass_open(phone) (service_role only) tells the edge function whether a code is open, so
--       that function can let the app reach its code screen while the SMS provider refuses the request (functions/operator-otp).
--
-- operator_prepare_otp, operator_verify_otp are patched by markers (each before-text is not contained in its after-text, so running the
-- file's blocks again raises the count error); issue_session, small and rewritten in its core, is replaced as a whole. Nothing here
-- creates, alters or drops a role.

-- ===== 1. Helpers for the per-source limits =====
CREATE FUNCTION warehouse_security.address_in_list(p_ip inet, p_list text) RETURNS boolean
    LANGUAGE plpgsql IMMUTABLE
    SET search_path TO 'pg_catalog'
    AS $$
DECLARE entry text; n integer := 0;
BEGIN
  IF p_ip IS NULL OR p_list IS NULL THEN RETURN false; END IF;
  FOREACH entry IN ARRAY string_to_array(p_list, ',') LOOP
    n := n + 1;
    EXIT WHEN n > 100;
    entry := btrim(entry, E' \t\r\n');
    CONTINUE WHEN entry = '';
    BEGIN
      IF p_ip <<= entry::inet THEN RETURN true; END IF;
    EXCEPTION WHEN invalid_text_representation THEN NULL;
    END;
  END LOOP;
  RETURN false;
END $$;
ALTER FUNCTION warehouse_security.address_in_list(p_ip inet, p_list text) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION warehouse_security.address_in_list(p_ip inet, p_list text) FROM PUBLIC;
COMMENT ON FUNCTION warehouse_security.address_in_list(p_ip inet, p_list text) IS 'Migration 126: true when the address lies inside one of the comma separated addresses or CIDR ranges of the list (at most 100 entries; an entry that is not an address is ignored).';

CREATE FUNCTION warehouse_security.otp_source_send_cap(p_ip inet) RETURNS integer
    LANGUAGE plpgsql STABLE
    SET search_path TO 'pg_catalog'
    AS $$
DECLARE cap_text text; cap integer; listed text;
BEGIN
  SELECT value INTO cap_text FROM warehouse_security.auth_config WHERE key='otp_source_hourly_sends';
  cap := CASE WHEN cap_text ~ '^[0-9]{1,6}$' THEN greatest(cap_text::integer,1) ELSE 30 END;
  SELECT value INTO listed FROM warehouse_security.auth_config WHERE key='otp_trusted_sources';
  IF p_ip IS NOT NULL AND listed IS NOT NULL AND warehouse_security.address_in_list(p_ip,listed) THEN
    SELECT value INTO cap_text FROM warehouse_security.auth_config WHERE key='otp_trusted_source_hourly_sends';
    cap := greatest(cap, CASE WHEN cap_text ~ '^[0-9]{1,6}$' THEN cap_text::integer ELSE 120 END);
  END IF;
  RETURN cap;
END $$;
ALTER FUNCTION warehouse_security.otp_source_send_cap(p_ip inet) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION warehouse_security.otp_source_send_cap(p_ip inet) FROM PUBLIC;
COMMENT ON FUNCTION warehouse_security.otp_source_send_cap(p_ip inet) IS 'Migration 126: SMS requests an hour allowed from one address: otp_source_hourly_sends (default 30), or the larger otp_trusted_source_hourly_sends (default 120) for an address in otp_trusted_sources.';

CREATE FUNCTION warehouse_security.otp_source_failure_cap() RETURNS integer
    LANGUAGE plpgsql STABLE
    SET search_path TO 'pg_catalog'
    AS $$
DECLARE cap_text text;
BEGIN
  SELECT value INTO cap_text FROM warehouse_security.auth_config WHERE key='otp_source_hourly_failures';
  RETURN CASE WHEN cap_text ~ '^[0-9]{1,6}$' THEN greatest(cap_text::integer,1) ELSE 20 END;
END $$;
ALTER FUNCTION warehouse_security.otp_source_failure_cap() OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION warehouse_security.otp_source_failure_cap() FROM PUBLIC;
COMMENT ON FUNCTION warehouse_security.otp_source_failure_cap() IS 'Migration 126: failed verifications an hour allowed from one address: otp_source_hourly_failures (default 20).';

-- Seeds: the defaults of the code, so the values can be seen and changed. Existing values are kept. otp_trusted_sources is not seeded:
-- it does not exist until the operator sets it.
INSERT INTO warehouse_security.auth_config(key,value) VALUES
  ('session_idle_seconds','2592000'),('session_max_seconds','7776000'),
  ('otp_source_hourly_sends','30'),('otp_source_hourly_failures','20'),('otp_trusted_source_hourly_sends','120')
ON CONFLICT(key) DO NOTHING;

-- ===== 2. Sliding sessions =====
CREATE OR REPLACE FUNCTION warehouse_security.issue_session(p_user uuid, p_session uuid DEFAULT NULL::uuid) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'extensions'
    AS $$
DECLARE refresh text; session_id uuid; sliding boolean; cfg text; idle_seconds integer; max_seconds integer;
BEGIN
  -- An active account is required, as before. Only an approved one slides (migration 126); any other active profile keeps the fixed
  -- 7 days of a new session and is never extended.
  SELECT p.enrollment_status = 'approved' INTO sliding FROM public.user_profiles p WHERE p.auth_user_id = p_user AND p.active;
  IF NOT FOUND THEN RAISE EXCEPTION 'Active account required' USING ERRCODE = 'P0002'; END IF;
  SELECT value INTO cfg FROM warehouse_security.auth_config WHERE key = 'session_idle_seconds';
  idle_seconds := least(greatest(CASE WHEN cfg ~ '^[0-9]{1,9}$' THEN cfg::integer ELSE 2592000 END, 3600), 31536000);
  SELECT value INTO cfg FROM warehouse_security.auth_config WHERE key = 'session_max_seconds';
  max_seconds := least(greatest(CASE WHEN cfg ~ '^[0-9]{1,9}$' THEN cfg::integer ELSE 7776000 END, idle_seconds), 94608000);
  refresh := encode(extensions.gen_random_bytes(32), 'hex');
  IF p_session IS NULL THEN
    INSERT INTO warehouse_security.refresh_sessions(user_id, token_hash, expires_at)
    VALUES (p_user, encode(extensions.digest(refresh, 'sha256'), 'hex'),
      now() + CASE WHEN sliding THEN make_interval(secs => idle_seconds) ELSE interval '7 days' END) RETURNING id INTO session_id;
  ELSE
    -- A sliding session ends at the earlier of the idle time after this refresh and the absolute limit after sign-in; one already
    -- past the absolute limit (the operator lowered it) is not renewed.
    UPDATE warehouse_security.refresh_sessions s SET token_hash = encode(extensions.digest(refresh, 'sha256'), 'hex'),
      expires_at = CASE WHEN sliding THEN least(now() + make_interval(secs => idle_seconds), s.created_at + make_interval(secs => max_seconds))
                        ELSE s.expires_at END
    WHERE s.id = p_session AND s.user_id = p_user AND s.expires_at > now()
      AND (NOT sliding OR s.created_at + make_interval(secs => max_seconds) > now())
    RETURNING s.id INTO session_id;
    IF session_id IS NULL THEN RAISE EXCEPTION 'Session expired'; END IF;
  END IF;
  RETURN warehouse_security.sign_access_token(p_user, session_id) || jsonb_build_object('refresh_token', refresh);
END $$;

-- ===== 3. Break-glass codes =====
CREATE TABLE warehouse_security.break_glass_codes (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid NOT NULL,
    phone_number text NOT NULL,
    code_hash text,
    attempts integer DEFAULT 0 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    expires_at timestamp with time zone NOT NULL,
    used_at timestamp with time zone,
    used_from inet,
    CONSTRAINT break_glass_codes_pkey PRIMARY KEY (id),
    CONSTRAINT break_glass_codes_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.user_profiles(auth_user_id) ON DELETE CASCADE
);
ALTER TABLE warehouse_security.break_glass_codes OWNER TO supabase_admin;
CREATE INDEX break_glass_codes_phone_created ON warehouse_security.break_glass_codes USING btree (phone_number, created_at);
CREATE INDEX break_glass_codes_user ON warehouse_security.break_glass_codes USING btree (user_id);
ALTER TABLE warehouse_security.break_glass_codes ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE warehouse_security.break_glass_codes FROM PUBLIC, anon, authenticated, service_role;
COMMENT ON TABLE warehouse_security.break_glass_codes IS 'Migration 126: one-time administrator sign-in codes made by warehouse_security.break_glass_code (HMAC of phone:code:id keyed with the JWT secret; the hash is cleared when the code is used or ended). Rows older than 2 days are removed when a new code is made.';

CREATE FUNCTION warehouse_security.break_glass_code(p_phone text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'extensions'
    AS $$
DECLARE phone text; target public.user_profiles; secret text; new_code text; new_id uuid := gen_random_uuid();
  valid_until timestamptz := now() + interval '10 minutes';
BEGIN
  IF session_user <> 'supabase_admin' THEN RAISE EXCEPTION 'Installer only' USING ERRCODE='42501'; END IF;
  IF COALESCE((SELECT value FROM warehouse_security.auth_config WHERE key='auth_mode'),'') <> 'operator' THEN
    RAISE EXCEPTION 'Operator sign-in is not configured on this installation';
  END IF;
  phone := warehouse_security.normalize_phone(p_phone);
  -- The lock operator_verify_otp takes for this phone.
  PERFORM pg_advisory_xact_lock(hashtextextended(phone,71044));
  SELECT * INTO target FROM public.user_profiles
    WHERE mobile=phone AND role='admin' AND active AND enrollment_status='approved' AND NOT is_service_account AND deleted_at IS NULL;
  IF target.id IS NULL THEN RAISE EXCEPTION 'No active, approved administrator has this phone number'; END IF;
  SELECT value INTO secret FROM warehouse_security.auth_config WHERE key='jwt_secret';
  IF length(COALESCE(secret,''))<32 THEN RAISE EXCEPTION 'Auth configuration missing'; END IF;
  new_code := lpad((mod(('x'||encode(extensions.gen_random_bytes(8),'hex'))::bit(64)::bigint & 9223372036854775807,1000000))::text,6,'0');
  DELETE FROM warehouse_security.break_glass_codes WHERE created_at < now() - interval '2 days';
  -- An earlier code of this number that is still open stops working.
  UPDATE warehouse_security.break_glass_codes SET expires_at=now(), code_hash=NULL
    WHERE phone_number=phone AND used_at IS NULL AND expires_at>now();
  INSERT INTO warehouse_security.break_glass_codes(id,user_id,phone_number,code_hash,expires_at)
  VALUES (new_id,target.auth_user_id,phone,encode(extensions.hmac(phone||':'||new_code||':'||new_id::text,secret,'sha256'),'hex'),valid_until);
  INSERT INTO public.audit_log(table_name,action,user_id,new_data)
  VALUES ('break_glass','CODE_ISSUED',target.auth_user_id,
    jsonb_build_object('mobile',phone,'name',target.name,'code_id',new_id,'expires_at',valid_until));
  RETURN jsonb_build_object('code',new_code,'name',target.name,'expires_at',valid_until,'valid_minutes',10);
END $$;
ALTER FUNCTION warehouse_security.break_glass_code(p_phone text) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION warehouse_security.break_glass_code(p_phone text) FROM PUBLIC, anon, authenticated, service_role;
COMMENT ON FUNCTION warehouse_security.break_glass_code(p_phone text) IS 'Migration 126: for an active, approved administrator, makes a one-time six-digit sign-in code valid for 10 minutes and returns it once (jsonb: code, name, expires_at, valid_minutes). Executable by supabase_admin only; run it with scripts/break-glass-admin.sh.';

CREATE FUNCTION public.operator_break_glass_open(p_phone_number text) RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public'
    AS $$
  SELECT EXISTS (
    SELECT 1 FROM warehouse_security.break_glass_codes b
    JOIN public.user_profiles a ON a.auth_user_id=b.user_id AND a.mobile=b.phone_number AND a.role='admin' AND a.active AND a.enrollment_status='approved'
    WHERE b.phone_number=warehouse_security.normalize_phone(p_phone_number) AND b.used_at IS NULL AND b.expires_at>now() AND b.attempts<5);
$$;
ALTER FUNCTION public.operator_break_glass_open(p_phone_number text) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION public.operator_break_glass_open(p_phone_number text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.operator_break_glass_open(p_phone_number text) TO service_role;
COMMENT ON FUNCTION public.operator_break_glass_open(p_phone_number text) IS 'Migration 126: true while an unused, unexpired break-glass code exists for an active administrator with this number. Called by the operator-otp edge function (service_role) when the SMS provider refuses a request, so the app can still reach its code screen.';

-- ===== 4. operator_prepare_otp: the per-source send limit comes from auth_config =====
DO $patch$
DECLARE
  v_def text;
  v_old constant text[] := ARRAY[
    $m$IF ip_limits.hourly_count >= 30 THEN RETURN$m$
  ];
  v_new constant text[] := ARRAY[
    $m$IF ip_limits.hourly_count >= warehouse_security.otp_source_send_cap(p_ip_address) THEN RETURN$m$
  ];
  v_count integer;
  i integer;
BEGIN
  v_def := pg_get_functiondef('public.operator_prepare_otp(text, inet)'::regprocedure);
  FOR i IN 1 .. array_length(v_old, 1) LOOP
    v_count := (length(v_def) - length(replace(v_def, v_old[i], ''))) / length(v_old[i]);
    IF v_count <> 1 THEN
      RAISE EXCEPTION 'operator_prepare_otp: expected marker % once, found % times', i, v_count;
    END IF;
    v_def := replace(v_def, v_old[i], v_new[i]);
  END LOOP;
  EXECUTE v_def;
END
$patch$;

-- ===== 5. operator_verify_otp: the per-source failure limit from auth_config, and the break-glass code =====
DO $patch$
DECLARE
  v_def text;
  v_old constant text[] := ARRAY[
    $m$i.verify_failures>=20 AND$m$,
    $m$  candidates uuid[]; clean_name text; clean_display text; created_now boolean := false;
BEGIN
$m$,
    $m$  IF challenge.id IS NULL THEN
    IF p_ip_address IS NOT NULL THEN
      INSERT INTO public.ip_rate_limits AS i$m$,
    $m$  IF NOT created_now THEN
$m$,
    $m$  IF p_ip_address IS NOT NULL THEN
    INSERT INTO warehouse_security.otp_trusted_sources$m$,
    $m$  session_data:=warehouse_security.issue_session(profile.auth_user_id);$m$
  ];
  v_new constant text[] := ARRAY[
    $m$i.verify_failures>=warehouse_security.otp_source_failure_cap() AND$m$,
    $m$  candidates uuid[]; clean_name text; clean_display text; created_now boolean := false;
  glass_id uuid; glass_hash text; glass_used boolean := false;
BEGIN
$m$,
    $m$  -- Migration 126: a break-glass code (warehouse_security.break_glass_code) is looked for only when no SMS code matched. It belongs
  -- to an active, approved administrator with this number, works once, expires after 10 minutes and ends after five wrong tries from
  -- any address. A wrong try is also a failed verification of the source, below.
  IF challenge.id IS NULL AND p_otp_code ~ '^[0-9]{6}$' THEN
    SELECT b.id, b.code_hash INTO glass_id, glass_hash FROM warehouse_security.break_glass_codes b
      JOIN public.user_profiles a ON a.auth_user_id=b.user_id AND a.mobile=phone AND a.role='admin' AND a.active AND a.enrollment_status='approved'
      WHERE b.phone_number=phone AND b.used_at IS NULL AND b.expires_at>now() AND b.attempts<5
      ORDER BY b.created_at DESC LIMIT 1 FOR UPDATE OF b;
    IF glass_id IS NOT NULL THEN
      SELECT value INTO secret FROM warehouse_security.auth_config WHERE key='jwt_secret';
      IF glass_hash = encode(extensions.hmac(phone||':'||p_otp_code||':'||glass_id::text,secret,'sha256'),'hex') THEN
        UPDATE warehouse_security.break_glass_codes SET used_at=now(), used_from=p_ip_address, code_hash=NULL WHERE id=glass_id;
        glass_used := true;
      ELSE
        UPDATE warehouse_security.break_glass_codes SET attempts=attempts+1 WHERE id=glass_id;
      END IF;
    END IF;
  END IF;
  IF challenge.id IS NULL AND NOT glass_used THEN
    IF p_ip_address IS NOT NULL THEN
      INSERT INTO public.ip_rate_limits AS i$m$,
    $m$  IF NOT created_now AND NOT glass_used THEN
$m$,
    $m$  IF p_ip_address IS NOT NULL AND NOT glass_used THEN
    INSERT INTO warehouse_security.otp_trusted_sources$m$,
    $m$  IF glass_used THEN
    INSERT INTO public.audit_log(table_name,action,user_id,new_data,ip_address)
    VALUES ('break_glass','SIGN_IN',profile.auth_user_id,
      jsonb_build_object('mobile',phone,'name',profile.name,'code_id',glass_id),p_ip_address);
  END IF;
  session_data := warehouse_security.issue_session(profile.auth_user_id);$m$
  ];
  v_count integer;
  i integer;
BEGIN
  v_def := pg_get_functiondef('public.operator_verify_otp(text, text, text, text, inet)'::regprocedure);
  FOR i IN 1 .. array_length(v_old, 1) LOOP
    v_count := (length(v_def) - length(replace(v_def, v_old[i], ''))) / length(v_old[i]);
    IF v_count <> 1 THEN
      RAISE EXCEPTION 'operator_verify_otp: expected marker % once, found % times', i, v_count;
    END IF;
    v_def := replace(v_def, v_old[i], v_new[i]);
  END LOOP;
  EXECUTE v_def;
END
$patch$;

NOTIFY pgrst, 'reload schema';
