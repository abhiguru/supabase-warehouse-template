-- OTP resend hardening (review, 2026-10-08). A new request no longer voids the
-- outstanding code, so an unauthenticated caller cannot invalidate a victim's
-- code by requesting another one; every live code for a phone stays valid until
-- its own expiry, the five wrong-attempt cap is shared across them, and a
-- successful verification consumes all of them. The warehouse-wide hourly cap
-- is configurable through warehouse_security.auth_config
-- ('otp_global_hourly_cap', default 300). Per-phone 5/hour and 20/day, the 60 s
-- resend cooldown and the 30/hour per-IP cap are unchanged.
INSERT INTO warehouse_security.auth_config(key,value) VALUES ('otp_global_hourly_cap','300') ON CONFLICT DO NOTHING;

CREATE OR REPLACE FUNCTION public.operator_prepare_otp(p_phone_number text, p_ip_address inet DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public,extensions AS $$
DECLARE phone text; limits public.otp_rate_limits; ip_limits public.ip_rate_limits;
  code text; request_id uuid; secret text; retry_at timestamptz; global_count integer; global_window timestamptz;
  cap_text text; global_cap integer;
BEGIN
  IF COALESCE((SELECT value FROM warehouse_security.auth_config WHERE key='auth_mode'),'') <> 'operator' THEN
    RETURN jsonb_build_object('success',false,'code','unavailable');
  END IF;
  phone := warehouse_security.normalize_phone(p_phone_number);
  PERFORM pg_advisory_xact_lock(hashtextextended(phone,71044));
  INSERT INTO public.otp_rate_limits(phone_number) VALUES (phone) ON CONFLICT DO NOTHING;
  SELECT * INTO limits FROM public.otp_rate_limits WHERE phone_number=phone FOR UPDATE;
  IF limits.last_reset_hour < now()-interval '1 hour' THEN limits.hourly_count:=0; limits.last_reset_hour:=now(); END IF;
  IF limits.last_reset_day < now()-interval '1 day' THEN limits.daily_count:=0; limits.last_reset_day:=now(); END IF;
  IF limits.hourly_count >= 5 OR limits.daily_count >= 20 THEN
    RETURN jsonb_build_object('success',false,'code','rate_limited');
  END IF;
  SELECT created_at + interval '60 seconds' INTO retry_at FROM public.otp_verifications
    WHERE phone_number=phone AND delivery_status IN ('sending','accepted') ORDER BY created_at DESC LIMIT 1;
  IF retry_at > now() THEN RETURN jsonb_build_object('success',false,'code','resend_cooldown','retry_at',retry_at); END IF;
  SELECT value INTO cap_text FROM warehouse_security.auth_config WHERE key='otp_global_hourly_cap';
  global_cap := CASE WHEN cap_text ~ '^[0-9]{1,6}$' THEN cap_text::integer ELSE 300 END;
  SELECT hourly_count,window_started INTO global_count,global_window
    FROM warehouse_security.operator_otp_global_limit WHERE id=true FOR UPDATE;
  IF global_window < now()-interval '1 hour' THEN global_count:=0; global_window:=now(); END IF;
  IF global_count >= global_cap THEN RETURN jsonb_build_object('success',false,'code','rate_limited'); END IF;
  IF p_ip_address IS NOT NULL THEN
    INSERT INTO public.ip_rate_limits(ip_address) VALUES (p_ip_address) ON CONFLICT DO NOTHING;
    SELECT * INTO ip_limits FROM public.ip_rate_limits WHERE ip_address=p_ip_address FOR UPDATE;
    IF ip_limits.last_reset_hour < now()-interval '1 hour' THEN ip_limits.hourly_count:=0; ip_limits.last_reset_hour:=now(); END IF;
    IF ip_limits.hourly_count >= 30 THEN RETURN jsonb_build_object('success',false,'code','rate_limited'); END IF;
    UPDATE public.ip_rate_limits SET hourly_count=ip_limits.hourly_count+1,last_reset_hour=ip_limits.last_reset_hour,
      updated_at=now() WHERE ip_address=p_ip_address;
  END IF;
  UPDATE public.otp_rate_limits SET hourly_count=limits.hourly_count+1,daily_count=limits.daily_count+1,
    last_reset_hour=limits.last_reset_hour,last_reset_day=limits.last_reset_day,updated_at=now() WHERE phone_number=phone;
  UPDATE warehouse_security.operator_otp_global_limit SET hourly_count=global_count+1,window_started=global_window WHERE id=true;
  -- Earlier live codes stay valid until their own expiry (no forced invalidation).
  SELECT value INTO secret FROM warehouse_security.auth_config WHERE key='jwt_secret';
  IF length(COALESCE(secret,''))<32 THEN RAISE EXCEPTION 'Auth configuration missing'; END IF;
  code := lpad((mod(('x'||encode(extensions.gen_random_bytes(8),'hex'))::bit(64)::bigint & 9223372036854775807,1000000))::text,6,'0');
  request_id := gen_random_uuid();
  INSERT INTO public.otp_verifications(id,phone_number,purpose,otp_code_hash,max_attempts,expires_at,delivery_status,ip_address)
  VALUES (request_id,phone,'login',encode(extensions.hmac(phone||':'||code||':'||request_id::text,secret,'sha256'),'hex'),
    5,now()+interval '5 minutes','sending',p_ip_address);
  RETURN jsonb_build_object('success',true,'data',jsonb_build_object('request_id',request_id,'phone_number',phone,
    'otp_code',code,'expires_at',now()+interval '5 minutes'));
END $$;

CREATE OR REPLACE FUNCTION public.operator_verify_otp(p_phone_number text,p_otp_code text,p_name text DEFAULT NULL,p_display_name text DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public,extensions AS $$
DECLARE phone text; challenge public.otp_verifications; profile public.user_profiles;
  secret text; token text; session_data jsonb; expires timestamptz;
  live_codes integer; total_attempts integer; newest uuid;
BEGIN
  IF COALESCE((SELECT value FROM warehouse_security.auth_config WHERE key='auth_mode'),'') <> 'operator' THEN
    RETURN jsonb_build_object('success',false,'code','unavailable');
  END IF;
  phone := warehouse_security.normalize_phone(p_phone_number);
  PERFORM pg_advisory_xact_lock(hashtextextended(phone,71044));
  -- Every accepted, unexpired, unconsumed code for this phone is a live candidate;
  -- wrong attempts count against all of them together.
  SELECT count(*), COALESCE(sum(attempts),0), (array_agg(id ORDER BY created_at DESC))[1]
    INTO live_codes, total_attempts, newest
    FROM public.otp_verifications
    WHERE phone_number=phone AND NOT verified AND delivery_status='accepted' AND expires_at>now();
  IF live_codes=0 OR total_attempts>=5 THEN
    RETURN jsonb_build_object('success',false,'code','invalid_otp');
  END IF;
  UPDATE public.otp_verifications SET attempts=attempts+1 WHERE id=newest;
  SELECT value INTO secret FROM warehouse_security.auth_config WHERE key='jwt_secret';
  IF p_otp_code !~ '^[0-9]{6}$' THEN RETURN jsonb_build_object('success',false,'code','invalid_otp'); END IF;
  SELECT c.* INTO challenge FROM public.otp_verifications c
    WHERE c.phone_number=phone AND NOT c.verified AND c.delivery_status='accepted' AND c.expires_at>now()
      AND c.otp_code_hash=encode(extensions.hmac(phone||':'||p_otp_code||':'||c.id::text,secret,'sha256'),'hex')
    ORDER BY c.created_at DESC LIMIT 1;
  IF challenge.id IS NULL THEN RETURN jsonb_build_object('success',false,'code','invalid_otp'); END IF;
  UPDATE public.otp_verifications SET verified=true,verified_at=now(),otp_code_hash=NULL
    WHERE phone_number=phone AND NOT verified AND delivery_status='accepted';
  SELECT * INTO profile FROM public.user_profiles WHERE mobile=phone FOR UPDATE;
  IF profile.id IS NULL THEN
    INSERT INTO public.user_profiles(auth_user_id,mobile,name,display_name,role,active,mobile_verified,mobile_verified_at,enrollment_status)
    VALUES (gen_random_uuid(),phone,left(COALESCE(NULLIF(btrim(p_name),''),'New customer'),30),
      left(COALESCE(NULLIF(btrim(p_display_name),''),NULLIF(btrim(p_name),''),'New customer'),30),
      'customer',false,true,now(),'pending') RETURNING * INTO profile;
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
  session_data:=warehouse_security.issue_session(profile.auth_user_id);
  RETURN jsonb_build_object('success',true,'data',jsonb_build_object('action','login','user',to_jsonb(profile),'session',session_data));
END $$;
NOTIFY pgrst,'reload schema';
