-- Authentication hardening (review, 2026-10-10).
--
-- 1. Refresh tokens: a replayed, already rotated token now ends its session
--    (reuse detection). A client that lost the answer to a rotation may send
--    the same token again within a short grace period and receives the same
--    successor, so a slow network does not sign anyone out.
-- 2. OTP limits: counters that an unauthenticated caller drives can no longer
--    keep a chosen phone from signing in; unknown numbers get the smaller part
--    of the warehouse SMS budget; new access requests are bounded per source
--    and per day and their names are checked.
-- 3. Administrators: the last active administrator cannot be deleted,
--    deactivated or demoted, and the installer can restore one.
-- The limits are described in docs/OPERATOR_INSTALL.md.

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

-- ---------------------------------------------------------------------------
-- 2. OTP limits that an unauthenticated caller cannot turn against a user
-- ---------------------------------------------------------------------------
ALTER TABLE public.otp_verifications
  ADD COLUMN source_attempts integer NOT NULL DEFAULT 0,
  ADD COLUMN quota_lane text CHECK (quota_lane IN ('open','slow','trusted')),
  ADD COLUMN quota_known boolean,
  ADD COLUMN quota_refunded boolean NOT NULL DEFAULT false;
CREATE INDEX otp_verifications_phone_created ON public.otp_verifications(phone_number, created_at);
ALTER TABLE public.ip_rate_limits
  ADD COLUMN verify_failures integer NOT NULL DEFAULT 0,
  ADD COLUMN verify_window timestamptz NOT NULL DEFAULT now();
ALTER TABLE warehouse_security.operator_otp_global_limit ADD COLUMN unknown_count integer NOT NULL DEFAULT 0;
INSERT INTO warehouse_security.auth_config(key,value) VALUES
  ('otp_unknown_hourly_cap','60'),('enrollment_daily_cap','30') ON CONFLICT DO NOTHING;

-- Addresses from which a phone has completed a sign-in. Requests from such an
-- address have their own send allowance, which other addresses cannot use up.
CREATE TABLE warehouse_security.otp_trusted_sources (
  phone_number text NOT NULL,
  ip_address inet NOT NULL,
  last_verified timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (phone_number, ip_address)
);
ALTER TABLE warehouse_security.otp_trusted_sources ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON warehouse_security.otp_trusted_sources FROM PUBLIC, anon, authenticated, service_role;

-- One row per access request created by an OTP verification.
CREATE TABLE warehouse_security.enrollment_log (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  created_at timestamptz NOT NULL DEFAULT now(),
  ip_address inet
);
CREATE INDEX enrollment_log_created ON warehouse_security.enrollment_log(created_at);
ALTER TABLE warehouse_security.enrollment_log ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON warehouse_security.enrollment_log FROM PUBLIC, anon, authenticated, service_role;

-- New access requests: 3 per source address and enrollment_daily_cap (30) for
-- the warehouse, both per 24 hours.
CREATE FUNCTION warehouse_security.enrollment_allowed(p_ip_address inet) RETURNS boolean
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog AS $$
DECLARE cap_text text; daily_cap integer;
BEGIN
  SELECT value INTO cap_text FROM warehouse_security.auth_config WHERE key = 'enrollment_daily_cap';
  daily_cap := CASE WHEN cap_text ~ '^[0-9]{1,5}$' THEN cap_text::integer ELSE 30 END;
  RETURN (SELECT count(*) FROM warehouse_security.enrollment_log WHERE created_at > now() - interval '1 day') < daily_cap
    AND (p_ip_address IS NULL OR (SELECT count(*) FROM warehouse_security.enrollment_log
      WHERE created_at > now() - interval '1 day' AND ip_address = p_ip_address) < 3);
END $$;
REVOKE ALL ON FUNCTION warehouse_security.enrollment_allowed(inet) FROM PUBLIC, anon, authenticated, service_role;

-- A name typed before sign-in is shown to the administrator. Keep letters of
-- any script, digits, spaces and . , ' & ( ) / -; anything else (markup, links,
-- control or direction characters) gives NULL and the caller uses its default.
CREATE FUNCTION warehouse_security.clean_person_name(p_value text) RETURNS text
LANGUAGE plpgsql IMMUTABLE SET search_path = pg_catalog AS $$
DECLARE cleaned text := btrim(regexp_replace(COALESCE(p_value, ''), '\s+', ' ', 'g'));
BEGIN
  IF cleaned = '' OR cleaned !~ '^([A-Za-z0-9 .,''&()/-]|[^\u0001-\u007F])+$'
    OR cleaned ~ '[\u0080-\u009F‎‏‪-‮⁦-⁩]'
    OR cleaned !~ '[A-Za-z]|[^\u0001-\u007F]' THEN
    RETURN NULL;
  END IF;
  RETURN btrim(left(cleaned, 30));
END $$;
REVOKE ALL ON FUNCTION warehouse_security.clean_person_name(text) FROM PUBLIC, anon, authenticated, service_role;

-- Send limits. "Known" means the phone has an approved, active profile.
--   open lane    5 per hour and 20 per day per phone, any source (as before).
--   slow lane    known phones only, once the open lane is used up: one code
--                every 15 minutes instead of a refusal.
--   trusted lane known phones only, from an address that completed a sign-in
--                for this phone in the last 90 days: 5 per hour per address,
--                independent of the other two lanes.
-- The 60 s resend cooldown is per phone and source address. The warehouse cap
-- (otp_global_hourly_cap) stays; phones that are not known may use only
-- otp_unknown_hourly_cap of it. Per source address: 30 per hour.
CREATE OR REPLACE FUNCTION public.operator_prepare_otp(p_phone_number text, p_ip_address inet DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public,extensions AS $$
DECLARE phone text; limits public.otp_rate_limits; ip_limits public.ip_rate_limits;
  code text; request_id uuid; secret text; retry_at timestamptz; global_count integer; unknown_used integer;
  global_window timestamptz; cap_text text; global_cap integer; unknown_cap integer;
  known boolean; has_profile boolean; lane text;
BEGIN
  IF COALESCE((SELECT value FROM warehouse_security.auth_config WHERE key='auth_mode'),'') <> 'operator' THEN
    RETURN jsonb_build_object('success',false,'code','unavailable');
  END IF;
  phone := warehouse_security.normalize_phone(p_phone_number);
  PERFORM pg_advisory_xact_lock(hashtextextended(phone,71044));
  SELECT COALESCE(bool_or(active AND enrollment_status='approved'),false), count(*)>0 INTO known, has_profile
    FROM public.user_profiles WHERE mobile=phone;
  IF known AND p_ip_address IS NOT NULL AND EXISTS (SELECT 1 FROM warehouse_security.otp_trusted_sources t
      WHERE t.phone_number=phone AND t.ip_address=p_ip_address AND t.last_verified>now()-interval '90 days') THEN
    lane := 'trusted';
    IF (SELECT count(*) FROM public.otp_verifications v WHERE v.phone_number=phone AND v.quota_lane='trusted'
        AND v.ip_address=p_ip_address AND NOT v.quota_refunded AND v.created_at>now()-interval '1 hour') >= 5 THEN
      RETURN jsonb_build_object('success',false,'code','rate_limited');
    END IF;
  ELSE
    INSERT INTO public.otp_rate_limits(phone_number) VALUES (phone) ON CONFLICT DO NOTHING;
    SELECT * INTO limits FROM public.otp_rate_limits WHERE phone_number=phone FOR UPDATE;
    IF limits.last_reset_hour < now()-interval '1 hour' THEN limits.hourly_count:=0; limits.last_reset_hour:=now(); END IF;
    IF limits.last_reset_day < now()-interval '1 day' THEN limits.daily_count:=0; limits.last_reset_day:=now(); END IF;
    IF limits.hourly_count < 5 AND limits.daily_count < 20 THEN
      lane := 'open';
    ELSIF known THEN
      -- A used-up open lane slows a known phone down; it does not lock it out.
      lane := 'slow';
      SELECT v.created_at + interval '15 minutes' INTO retry_at FROM public.otp_verifications v
        WHERE v.phone_number=phone AND v.quota_lane='slow' AND NOT v.quota_refunded ORDER BY v.created_at DESC LIMIT 1;
      IF retry_at > now() THEN RETURN jsonb_build_object('success',false,'code','resend_cooldown','retry_at',retry_at); END IF;
    ELSE
      RETURN jsonb_build_object('success',false,'code','rate_limited');
    END IF;
  END IF;
  SELECT v.created_at + interval '60 seconds' INTO retry_at FROM public.otp_verifications v
    WHERE v.phone_number=phone AND v.delivery_status IN ('sending','accepted')
      AND v.ip_address IS NOT DISTINCT FROM p_ip_address ORDER BY v.created_at DESC LIMIT 1;
  IF retry_at > now() THEN RETURN jsonb_build_object('success',false,'code','resend_cooldown','retry_at',retry_at); END IF;
  -- A number with no profile would become a new access request: do not spend
  -- an SMS on one that verification would refuse.
  IF NOT has_profile AND NOT warehouse_security.enrollment_allowed(p_ip_address) THEN
    RETURN jsonb_build_object('success',false,'code','rate_limited');
  END IF;
  SELECT value INTO cap_text FROM warehouse_security.auth_config WHERE key='otp_global_hourly_cap';
  global_cap := CASE WHEN cap_text ~ '^[0-9]{1,6}$' THEN cap_text::integer ELSE 300 END;
  SELECT value INTO cap_text FROM warehouse_security.auth_config WHERE key='otp_unknown_hourly_cap';
  unknown_cap := least(CASE WHEN cap_text ~ '^[0-9]{1,6}$' THEN cap_text::integer ELSE 60 END, global_cap);
  SELECT g.hourly_count,g.unknown_count,g.window_started INTO global_count,unknown_used,global_window
    FROM warehouse_security.operator_otp_global_limit g WHERE g.id=true FOR UPDATE;
  IF global_window < now()-interval '1 hour' THEN global_count:=0; unknown_used:=0; global_window:=now(); END IF;
  IF global_count >= global_cap OR (NOT known AND unknown_used >= unknown_cap) THEN
    RETURN jsonb_build_object('success',false,'code','rate_limited');
  END IF;
  IF p_ip_address IS NOT NULL THEN
    INSERT INTO public.ip_rate_limits(ip_address) VALUES (p_ip_address) ON CONFLICT DO NOTHING;
    SELECT * INTO ip_limits FROM public.ip_rate_limits WHERE ip_address=p_ip_address FOR UPDATE;
    IF ip_limits.last_reset_hour < now()-interval '1 hour' THEN ip_limits.hourly_count:=0; ip_limits.last_reset_hour:=now(); END IF;
    IF ip_limits.hourly_count >= 30 THEN RETURN jsonb_build_object('success',false,'code','rate_limited'); END IF;
    UPDATE public.ip_rate_limits SET hourly_count=ip_limits.hourly_count+1,last_reset_hour=ip_limits.last_reset_hour,
      updated_at=now() WHERE ip_address=p_ip_address;
  END IF;
  IF lane = 'open' THEN
    UPDATE public.otp_rate_limits SET hourly_count=limits.hourly_count+1,daily_count=limits.daily_count+1,
      last_reset_hour=limits.last_reset_hour,last_reset_day=limits.last_reset_day,updated_at=now() WHERE phone_number=phone;
  END IF;
  UPDATE warehouse_security.operator_otp_global_limit SET hourly_count=global_count+1,
    unknown_count=unknown_used+CASE WHEN known THEN 0 ELSE 1 END,window_started=global_window WHERE id=true;
  -- Earlier live codes stay valid until their own expiry (no forced invalidation).
  SELECT value INTO secret FROM warehouse_security.auth_config WHERE key='jwt_secret';
  IF length(COALESCE(secret,''))<32 THEN RAISE EXCEPTION 'Auth configuration missing'; END IF;
  code := lpad((mod(('x'||encode(extensions.gen_random_bytes(8),'hex'))::bit(64)::bigint & 9223372036854775807,1000000))::text,6,'0');
  request_id := gen_random_uuid();
  INSERT INTO public.otp_verifications(id,phone_number,purpose,otp_code_hash,max_attempts,expires_at,delivery_status,ip_address,quota_lane,quota_known)
  VALUES (request_id,phone,'login',encode(extensions.hmac(phone||':'||code||':'||request_id::text,secret,'sha256'),'hex'),
    5,now()+interval '5 minutes','sending',p_ip_address,lane,known);
  RETURN jsonb_build_object('success',true,'data',jsonb_build_object('request_id',request_id,'phone_number',phone,
    'otp_code',code,'expires_at',now()+interval '5 minutes'));
END $$;

-- A send the provider did not accept gives its phone and warehouse allowance
-- back (not for provider_validation, which the caller's number caused). The
-- per-source charge is kept.
CREATE OR REPLACE FUNCTION public.operator_finish_otp(p_request_id uuid, p_delivered boolean, p_provider_id text DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE row_otp public.otp_verifications; safe_code text;
BEGIN
  SELECT * INTO row_otp FROM public.otp_verifications WHERE id=p_request_id FOR UPDATE;
  IF row_otp.id IS NULL OR row_otp.delivery_status<>'sending' THEN
    RETURN jsonb_build_object('success',false,'code','invalid_request');
  END IF;
  IF row_otp.expires_at<=now() THEN
    UPDATE public.otp_verifications SET delivery_status='failed',verified=true,
      otp_code_hash=NULL,msg91_status='expired' WHERE id=p_request_id;
    RETURN jsonb_build_object('success',false,'code','invalid_request');
  END IF;
  safe_code := CASE WHEN p_provider_id IN ('provider_configuration','provider_auth',
    'provider_validation','provider_rate_limited','provider_rejected',
    'provider_invalid_response','provider_unavailable') THEN p_provider_id
    ELSE 'provider_unavailable' END;
  UPDATE public.otp_verifications SET
    delivery_status=CASE WHEN p_delivered THEN 'accepted' ELSE 'failed' END,
    verified=NOT p_delivered,
    msg91_request_id=CASE WHEN p_delivered THEN left(p_provider_id,255) ELSE NULL END,
    msg91_status=CASE WHEN p_delivered THEN 'success' ELSE safe_code END,
    otp_code_hash=CASE WHEN p_delivered THEN otp_code_hash ELSE NULL END
    WHERE id=p_request_id;
  IF NOT p_delivered AND safe_code <> 'provider_validation' AND row_otp.quota_lane IS NOT NULL THEN
    UPDATE public.otp_verifications SET quota_refunded=true WHERE id=p_request_id;
    IF row_otp.quota_lane = 'open' THEN
      UPDATE public.otp_rate_limits SET
        hourly_count=CASE WHEN last_reset_hour<=row_otp.created_at THEN greatest(hourly_count-1,0) ELSE hourly_count END,
        daily_count=CASE WHEN last_reset_day<=row_otp.created_at THEN greatest(daily_count-1,0) ELSE daily_count END
        WHERE phone_number=row_otp.phone_number;
    END IF;
    UPDATE warehouse_security.operator_otp_global_limit SET hourly_count=greatest(hourly_count-1,0),
      unknown_count=greatest(unknown_count-CASE WHEN row_otp.quota_known THEN 0 ELSE 1 END,0)
      WHERE id=true AND window_started<=row_otp.created_at;
  END IF;
  RETURN jsonb_build_object('success',true);
END $$;

-- Wrong attempts are counted on each issued code, in two separate budgets of
-- five: one for the address that requested the code and one shared by every
-- other address. Guesses from elsewhere therefore cannot use up the attempts
-- of the person who asked for the code, and no code can be tried more than ten
-- times. Each source address is also limited to 20 failed verifications per
-- hour over all phones.
DROP FUNCTION public.operator_verify_otp(text,text,text,text);
CREATE FUNCTION public.operator_verify_otp(p_phone_number text,p_otp_code text,p_name text DEFAULT NULL,
  p_display_name text DEFAULT NULL,p_ip_address inet DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public,extensions AS $$
DECLARE phone text; challenge public.otp_verifications; profile public.user_profiles;
  secret text; token text; session_data jsonb; expires timestamptz;
  candidates uuid[]; clean_name text; clean_display text;
BEGIN
  IF COALESCE((SELECT value FROM warehouse_security.auth_config WHERE key='auth_mode'),'') <> 'operator' THEN
    RETURN jsonb_build_object('success',false,'code','unavailable');
  END IF;
  phone := warehouse_security.normalize_phone(p_phone_number);
  PERFORM pg_advisory_xact_lock(hashtextextended(phone,71044));
  IF p_ip_address IS NOT NULL AND EXISTS (SELECT 1 FROM public.ip_rate_limits i WHERE i.ip_address=p_ip_address
      AND i.verify_failures>=20 AND i.verify_window>=now()-interval '1 hour') THEN
    RETURN jsonb_build_object('success',false,'code','rate_limited');
  END IF;
  -- Every accepted, unexpired, unconsumed code for this phone with attempts
  -- left for this source is a live candidate; a wrong guess counts against all of them.
  SELECT array_agg(v.id) INTO candidates FROM public.otp_verifications v
    WHERE v.phone_number=phone AND NOT v.verified AND v.delivery_status='accepted' AND v.expires_at>now()
      AND CASE WHEN p_ip_address IS NOT NULL AND v.ip_address=p_ip_address THEN v.source_attempts ELSE v.attempts END < 5;
  IF candidates IS NOT NULL THEN
    UPDATE public.otp_verifications v SET
      source_attempts=v.source_attempts+CASE WHEN p_ip_address IS NOT NULL AND v.ip_address=p_ip_address THEN 1 ELSE 0 END,
      attempts=v.attempts+CASE WHEN p_ip_address IS NOT NULL AND v.ip_address=p_ip_address THEN 0 ELSE 1 END
      WHERE v.id=ANY(candidates);
    IF p_otp_code ~ '^[0-9]{6}$' THEN
      SELECT value INTO secret FROM warehouse_security.auth_config WHERE key='jwt_secret';
      SELECT c.* INTO challenge FROM public.otp_verifications c
        WHERE c.id=ANY(candidates)
          AND c.otp_code_hash=encode(extensions.hmac(phone||':'||p_otp_code||':'||c.id::text,secret,'sha256'),'hex')
        ORDER BY c.created_at DESC LIMIT 1;
    END IF;
  END IF;
  IF challenge.id IS NULL THEN
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
  ELSE
    UPDATE public.user_profiles SET mobile_verified=true,mobile_verified_at=now() WHERE id=profile.id RETURNING * INTO profile;
  END IF;
  IF profile.enrollment_status IN ('rejected','disabled') OR (NOT profile.active AND profile.enrollment_status<>'pending') THEN
    RETURN jsonb_build_object('success',false,'code','account_unavailable');
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
  IF p_ip_address IS NOT NULL THEN
    INSERT INTO warehouse_security.otp_trusted_sources(phone_number,ip_address) VALUES (phone,p_ip_address)
    ON CONFLICT(phone_number,ip_address) DO UPDATE SET last_verified=now();
    -- Keep the five most recent addresses of this phone and drop stale ones.
    DELETE FROM warehouse_security.otp_trusted_sources t WHERE t.phone_number=phone
      AND (t.last_verified<now()-interval '90 days' OR t.ip_address NOT IN (
        SELECT k.ip_address FROM warehouse_security.otp_trusted_sources k WHERE k.phone_number=phone
        ORDER BY k.last_verified DESC, k.ip_address LIMIT 5));
  END IF;
  session_data:=warehouse_security.issue_session(profile.auth_user_id);
  RETURN jsonb_build_object('success',true,'data',jsonb_build_object('action','login','user',to_jsonb(profile),'session',session_data));
END $$;
REVOKE EXECUTE ON FUNCTION public.operator_verify_otp(text,text,text,text,inet) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.operator_verify_otp(text,text,text,text,inet) TO service_role;

-- ---------------------------------------------------------------------------
-- 3. The last active administrator
-- ---------------------------------------------------------------------------
-- True when an approved, active administrator other than p_profile exists.
-- Serialized with bootstrap_first_admin so two concurrent changes cannot each
-- see the other administrator as still present.
CREATE FUNCTION warehouse_security.other_active_admin_exists(p_profile uuid) RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog AS $$
BEGIN
  PERFORM pg_advisory_xact_lock(71043);
  RETURN EXISTS (SELECT 1 FROM public.user_profiles WHERE role='admin' AND active
    AND enrollment_status='approved' AND id IS DISTINCT FROM p_profile);
END $$;
REVOKE ALL ON FUNCTION warehouse_security.other_active_admin_exists(uuid) FROM PUBLIC, anon, authenticated, service_role;

CREATE OR REPLACE FUNCTION public.delete_user_account() RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE profile_id uuid; profile_role text;
BEGIN
  PERFORM warehouse_security.authorize_rpc('delete_user_account','{}'::jsonb);
  SELECT id, role::text INTO STRICT profile_id, profile_role FROM public.user_profiles WHERE auth_user_id=auth.uid() AND active;
  IF profile_role='admin' AND NOT warehouse_security.other_active_admin_exists(profile_id) THEN
    RETURN jsonb_build_object('success',false,'code','LAST_ADMIN',
      'error','The only administrator cannot delete this account. Make another user an administrator first.',
      'message','The only administrator cannot delete this account. Make another user an administrator first.');
  END IF;
  DELETE FROM public.users_customers_new WHERE user_profile_id=profile_id;
  DELETE FROM public.user_session_activity WHERE user_id=profile_id;
  DELETE FROM warehouse_security.refresh_sessions WHERE user_id=auth.uid();
  UPDATE public.user_profiles SET name='Deleted User',display_name='Deleted User',active=false,
    mobile='DEL'||left(replace(profile_id::text,'-',''),12),mobile_verified=false,mobile_verified_at=NULL
    WHERE id=profile_id;
  RETURN jsonb_build_object('success',true,'message','Account deleted');
END $$;

DO $patch$
DECLARE fn regprocedure := 'public.update_user_status(uuid,boolean)'::regprocedure;
  definition text; marker text; replacement text; occurrences integer;
BEGIN
  definition := pg_get_functiondef(fn);
  marker := $m$    -- Update the status and keep the operator enrollment state consistent
$m$;
  replacement := $r$    -- The warehouse must keep one administrator who can sign in
    IF NOT p_active AND v_target_role = 'admin' AND NOT warehouse_security.other_active_admin_exists(v_target_id) THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'LAST_ADMIN',
            'message', 'The last active administrator cannot be deactivated'
        );
    END IF;

    -- Update the status and keep the operator enrollment state consistent
$r$;
  occurrences := (length(definition)-length(replace(definition,marker,'')))/length(marker);
  IF occurrences <> 1 THEN RAISE EXCEPTION 'Expected one status update in update_user_status, found %', occurrences; END IF;
  EXECUTE replace(definition,marker,replacement);
END $patch$;

DO $patch$
DECLARE fn regprocedure := 'public.update_user_role(uuid,public.user_role)'::regprocedure;
  definition text; marker text; replacement text; occurrences integer;
BEGIN
  definition := pg_get_functiondef(fn);
  marker := $m$    -- Update the role
$m$;
  replacement := $r$    -- The warehouse must keep one administrator who can sign in
    IF v_old_role = 'admin' AND NOT warehouse_security.other_active_admin_exists(v_target_id) THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'LAST_ADMIN',
            'message', 'The last active administrator cannot be given another role'
        );
    END IF;

    -- Update the role
$r$;
  occurrences := (length(definition)-length(replace(definition,marker,'')))/length(marker);
  IF occurrences <> 1 THEN RAISE EXCEPTION 'Expected one role update in update_user_role, found %', occurrences; END IF;
  EXECUTE replace(definition,marker,replacement);
END $patch$;

-- The installer's check counted any administrator row, so a warehouse whose
-- only administrator was deleted or disabled could never get another. Count
-- only one who can sign in, and restore the profile of the given phone when it
-- already exists.
CREATE OR REPLACE FUNCTION warehouse_security.bootstrap_first_admin(p_phone text, p_name text) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE result uuid; phone text;
BEGIN
  IF session_user <> 'supabase_admin' THEN RAISE EXCEPTION 'Installer only' USING ERRCODE='42501'; END IF;
  PERFORM pg_advisory_xact_lock(71043);
  IF EXISTS (SELECT 1 FROM public.user_profiles WHERE role='admin' AND active AND enrollment_status='approved') THEN
    RAISE EXCEPTION 'An administrator already exists';
  END IF;
  phone := warehouse_security.normalize_phone(p_phone);
  IF nullif(btrim(p_name),'') IS NULL THEN RAISE EXCEPTION 'Administrator name is required'; END IF;
  UPDATE public.user_profiles SET role='admin',active=true,enrollment_status='approved',updated_at=now()
    WHERE mobile=phone RETURNING auth_user_id INTO result;
  IF result IS NULL THEN
    INSERT INTO public.user_profiles(auth_user_id,mobile,name,display_name,role,active,mobile_verified,enrollment_status)
    VALUES (gen_random_uuid(),phone,left(btrim(p_name),30),left(btrim(p_name),30),'admin',true,false,'approved')
    RETURNING auth_user_id INTO result;
  END IF;
  RETURN result;
END $$;

-- What setup.sh needs to know before it creates or restores the administrator.
CREATE FUNCTION warehouse_security.installer_admin_state(p_phone text) RETURNS text
LANGUAGE sql STABLE SET search_path=pg_catalog AS $$
  SELECT CASE
    WHEN EXISTS (SELECT 1 FROM public.user_profiles WHERE role='admin' AND active AND enrollment_status='approved'
      AND mobile=warehouse_security.normalize_phone(p_phone)) THEN 'match'
    WHEN EXISTS (SELECT 1 FROM public.user_profiles WHERE role='admin' AND active AND enrollment_status='approved') THEN 'different'
    ELSE 'none' END;
$$;
REVOKE ALL ON FUNCTION warehouse_security.installer_admin_state(text) FROM PUBLIC,anon,authenticated,service_role;
GRANT EXECUTE ON FUNCTION warehouse_security.installer_admin_state(text) TO supabase_admin;

-- operator_review_enrollment: with no active role the old comparison was NULL
-- and did not refuse. IS DISTINCT FROM refuses it without relying on the
-- PostgREST session hook having run first.
DO $patch$
DECLARE fn regprocedure := 'public.operator_review_enrollment(uuid,text,uuid[])'::regprocedure;
  definition text; marker text; replacement text; occurrences integer;
BEGIN
  definition := pg_get_functiondef(fn);
  marker := $m$IF auth.jwt()->>'role'<>'authenticated' OR warehouse_security.active_role()<>'admin' THEN$m$;
  replacement := $r$IF auth.jwt()->>'role' IS DISTINCT FROM 'authenticated' OR warehouse_security.active_role() IS DISTINCT FROM 'admin' THEN$r$;
  occurrences := (length(definition)-length(replace(definition,marker,'')))/length(marker);
  IF occurrences <> 1 THEN RAISE EXCEPTION 'Expected one administrator check in operator_review_enrollment, found %', occurrences; END IF;
  EXECUTE replace(definition,marker,replacement);
END $patch$;
NOTIFY pgrst, 'reload schema';
