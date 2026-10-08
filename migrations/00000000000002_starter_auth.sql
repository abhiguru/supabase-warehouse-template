-- New-installation custom auth. Demo OTP is opt-in and NEVER a production fallback.
CREATE SCHEMA warehouse_security;
REVOKE ALL ON SCHEMA warehouse_security FROM PUBLIC, anon, authenticated;
CREATE TABLE warehouse_security.auth_config (key text PRIMARY KEY, value text NOT NULL);
CREATE TABLE warehouse_security.refresh_sessions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES public.user_profiles(auth_user_id) ON DELETE CASCADE,
  token_hash text UNIQUE NOT NULL,
  expires_at timestamptz NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE FUNCTION warehouse_security.normalize_phone(value text) RETURNS text
LANGUAGE plpgsql IMMUTABLE SET search_path = pg_catalog AS $$
DECLARE result text := regexp_replace(value, '[^0-9]', '', 'g');
BEGIN
  IF length(result) = 10 THEN result := '91' || result; END IF;
  IF result IS NULL OR result !~ '^91[0-9]{10}$' THEN RAISE EXCEPTION 'Expected a 10-digit Indian mobile number' USING ERRCODE = '22023'; END IF;
  RETURN result;
END $$;

CREATE FUNCTION warehouse_security.issue_session(p_user uuid, p_session uuid DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public, extensions AS $$
DECLARE profile public.user_profiles; secret text; refresh text; session_id uuid; expiry bigint;
  access_token text; access_lifetime integer := 3600;
BEGIN
  SELECT * INTO STRICT profile FROM public.user_profiles WHERE auth_user_id = p_user AND active;
  SELECT value INTO secret FROM warehouse_security.auth_config WHERE key = 'jwt_secret';
  IF length(COALESCE(secret, '')) < 32 THEN RAISE EXCEPTION 'Auth configuration missing'; END IF;
  SELECT COALESCE((SELECT value::integer FROM warehouse_security.auth_config WHERE key = 'access_seconds'), 3600) INTO access_lifetime;
  access_lifetime := greatest(60, least(access_lifetime, 86400));
  expiry := extract(epoch FROM now())::bigint + access_lifetime;
  refresh := encode(extensions.gen_random_bytes(32), 'hex');
  IF p_session IS NULL THEN
    INSERT INTO warehouse_security.refresh_sessions(user_id, token_hash, expires_at)
    VALUES (p_user, encode(extensions.digest(refresh, 'sha256'), 'hex'), now() + interval '7 days') RETURNING id INTO session_id;
  ELSE
    UPDATE warehouse_security.refresh_sessions SET token_hash = encode(extensions.digest(refresh, 'sha256'), 'hex')
    WHERE id = p_session AND user_id = p_user AND expires_at > now() RETURNING id INTO session_id;
    IF session_id IS NULL THEN RAISE EXCEPTION 'Session expired'; END IF;
  END IF;
  access_token := extensions.sign(jsonb_build_object('iss', 'supabase', 'aud', 'authenticated',
    'role', 'authenticated', 'sub', p_user, 'iat', extract(epoch FROM now())::bigint, 'exp', expiry,
    'session_id', session_id, 'phone', profile.mobile, 'user_role', profile.role,
    'user_metadata', jsonb_build_object('name', profile.name, 'display_name', profile.display_name, 'role', profile.role))::json, secret, 'HS256');
  RETURN jsonb_build_object('access_token', access_token, 'refresh_token', refresh,
    'expires_at', to_timestamp(expiry), 'expires_in', access_lifetime, 'token_type', 'bearer');
END $$;

CREATE OR REPLACE FUNCTION public.send_otp(p_phone_number varchar, p_purpose varchar DEFAULT 'login',
  p_user_agent text DEFAULT NULL, p_ip_address inet DEFAULT NULL, p_captcha_token text DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public, extensions AS $$
DECLARE phone text; limits public.otp_rate_limits; secret text; demo boolean; request_id uuid;
BEGIN
  phone := warehouse_security.normalize_phone(p_phone_number);
  SELECT value = 'true' INTO demo FROM warehouse_security.auth_config WHERE key = 'demo_auth_enabled';
  IF NOT COALESCE(demo, false) THEN
    RETURN jsonb_build_object('success', false, 'message', 'SMS authentication is not configured. Demo mode must be explicitly enabled for local use.');
  END IF;
  IF phone !~ '^91000000000[1-9]$' THEN
    RETURN jsonb_build_object('success',false,'message','Demo mode accepts only 0000000001 through 0000000009; no SMS is sent');
  END IF;
  IF p_purpose NOT IN ('login', 'registration') THEN RETURN jsonb_build_object('success', false, 'message', 'Unsupported OTP purpose'); END IF;
  SELECT value INTO secret FROM warehouse_security.auth_config WHERE key = 'jwt_secret';
  IF secret IS NULL THEN RETURN jsonb_build_object('success', false, 'message', 'Auth configuration missing'); END IF;
  INSERT INTO public.otp_rate_limits(phone_number) VALUES (phone) ON CONFLICT DO NOTHING;
  SELECT * INTO limits FROM public.otp_rate_limits WHERE phone_number = phone FOR UPDATE;
  IF limits.last_reset_hour < now() - interval '1 hour' THEN limits.hourly_count := 0; limits.last_reset_hour := now(); END IF;
  IF limits.last_reset_day < now() - interval '1 day' THEN limits.daily_count := 0; limits.last_reset_day := now(); END IF;
  IF limits.hourly_count >= 5 OR limits.daily_count >= 20 THEN RETURN jsonb_build_object('success', false, 'message', 'OTP rate limit exceeded'); END IF;
  UPDATE public.otp_rate_limits SET hourly_count = limits.hourly_count + 1, daily_count = limits.daily_count + 1,
    last_reset_hour = limits.last_reset_hour, last_reset_day = limits.last_reset_day WHERE phone_number = phone;
  UPDATE public.otp_verifications SET verified = true WHERE phone_number = phone AND NOT verified;
  INSERT INTO public.otp_verifications(phone_number, purpose, otp_code_hash, max_attempts, expires_at, delivery_status)
  VALUES (phone, p_purpose, encode(extensions.hmac(phone || ':123456', secret, 'sha256'), 'hex'), 5, now() + interval '5 minutes', 'demo') RETURNING id INTO request_id;
  RETURN jsonb_build_object('success', true, 'message', 'Local demo OTP: 123456 (no SMS sent)',
    'data', jsonb_build_object('request_id', request_id, 'expires_at', now() + interval '5 minutes', 'test_mode', true));
END $$;

CREATE OR REPLACE FUNCTION public.verify_otp_or_register(p_phone_number varchar, p_otp_code varchar,
  p_name varchar DEFAULT NULL, p_display_name varchar DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public, extensions AS $$
DECLARE phone text; otp public.otp_verifications; profile public.user_profiles; secret text; session_data jsonb;
BEGIN
  IF NOT COALESCE((SELECT value='true' FROM warehouse_security.auth_config WHERE key='demo_auth_enabled'),false) THEN
    RETURN jsonb_build_object('success',false,'message','SMS authentication is not configured');
  END IF;
  phone := warehouse_security.normalize_phone(p_phone_number);
  -- Serialize attempts for the phone, including concurrent registration and replay.
  PERFORM pg_advisory_xact_lock(hashtextextended(phone, 71039));
  SELECT * INTO otp FROM public.otp_verifications WHERE phone_number = phone AND NOT verified
    ORDER BY created_at DESC LIMIT 1 FOR UPDATE;
  IF otp.id IS NULL OR otp.expires_at <= now() OR otp.attempts >= otp.max_attempts THEN
    RETURN jsonb_build_object('success', false, 'message', 'Invalid or expired OTP');
  END IF;
  SELECT value INTO secret FROM warehouse_security.auth_config WHERE key = 'jwt_secret';
  UPDATE public.otp_verifications SET attempts = attempts + 1 WHERE id = otp.id;
  IF p_otp_code !~ '^[0-9]{6}$' OR otp.otp_code_hash IS DISTINCT FROM encode(extensions.hmac(phone || ':' || p_otp_code, secret, 'sha256'), 'hex') THEN
    RETURN jsonb_build_object('success', false, 'message', 'Invalid or expired OTP');
  END IF;
  UPDATE public.otp_verifications SET verified = true, verified_at = now() WHERE id = otp.id;
  SELECT * INTO profile FROM public.user_profiles WHERE mobile = phone;
  IF profile.id IS NOT NULL AND NOT profile.active THEN RETURN jsonb_build_object('success', false, 'message', 'Account inactive'); END IF;
  IF profile.id IS NULL THEN
    INSERT INTO public.user_profiles(auth_user_id, mobile, name, display_name, role, mobile_verified, active)
    VALUES (gen_random_uuid(), phone, left(COALESCE(p_name, 'Demo customer'), 30), left(COALESCE(p_display_name, p_name, 'Demo customer'), 30), 'customer', true, true)
    RETURNING * INTO profile;
  END IF;
  session_data := warehouse_security.issue_session(profile.auth_user_id);
  RETURN jsonb_build_object('success', true, 'message', 'Signed in', 'data', jsonb_build_object(
    'user', to_jsonb(profile), 'session', session_data, 'action', 'login'));
END $$;

CREATE OR REPLACE FUNCTION public.refresh_jwt_token(p_refresh_token text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public, extensions AS $$
DECLARE session_row warehouse_security.refresh_sessions; result jsonb;
BEGIN
  IF p_refresh_token IS NULL OR length(p_refresh_token) <> 64 THEN RETURN jsonb_build_object('success', false, 'message', 'Invalid refresh token'); END IF;
  SELECT * INTO session_row FROM warehouse_security.refresh_sessions
    WHERE token_hash = encode(extensions.digest(p_refresh_token, 'sha256'), 'hex') AND expires_at > now() FOR UPDATE;
  IF session_row.id IS NULL OR NOT EXISTS (SELECT 1 FROM public.user_profiles WHERE auth_user_id = session_row.user_id AND active) THEN
    RETURN jsonb_build_object('success', false, 'message', 'Invalid refresh token');
  END IF;
  result := warehouse_security.issue_session(session_row.user_id, session_row.id);
  RETURN result || jsonb_build_object('success', true);
END $$;

CREATE FUNCTION public.logout_session(p_refresh_token text) RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, extensions AS $$
BEGIN
  DELETE FROM warehouse_security.refresh_sessions WHERE token_hash = encode(extensions.digest(p_refresh_token, 'sha256'), 'hex');
  RETURN true;
END $$;

REVOKE ALL ON ALL TABLES IN SCHEMA warehouse_security FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA warehouse_security FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.logout_session(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.send_otp(varchar,varchar,text,inet,text), public.verify_otp_or_register(varchar,varchar,varchar,varchar), public.refresh_jwt_token(text), public.logout_session(text) TO anon, authenticated;
