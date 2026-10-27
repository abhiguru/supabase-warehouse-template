-- public.operator_prepare_otp: the definition setup applies after the numbered migrations whenever this file's checksum changes
-- (scripts/migration-plan.mjs, table warehouse_migrations.definitions). Edit the function here, never in a new migration.
-- Starts as the function migrations 000 to 126 leave (the numbered files that patched it stay as they are, never edited).
CREATE OR REPLACE FUNCTION public.operator_prepare_otp(p_phone_number text, p_ip_address inet DEFAULT NULL::inet)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'extensions'
AS $function$
DECLARE phone text; limits public.otp_rate_limits; ip_limits public.ip_rate_limits;
  code text; request_id uuid; secret text; retry_at timestamptz; global_count integer; unknown_used integer;
  global_window timestamptz; cap_text text; global_cap integer; unknown_cap integer;
  known boolean; has_profile boolean; lane text;
  phone_cap integer; trusted_reserve integer; day_total integer; day_open integer;
  provider_cap integer; provider_used integer;
BEGIN
  IF COALESCE((SELECT value FROM warehouse_security.auth_config WHERE key='auth_mode'),'') <> 'operator' THEN
    RETURN jsonb_build_object('success',false,'code','unavailable');
  END IF;
  phone := warehouse_security.normalize_phone(p_phone_number);
  PERFORM pg_advisory_xact_lock(hashtextextended(phone,71044));
  SELECT COALESCE(bool_or(active AND enrollment_status='approved'),false), count(*)>0 INTO known, has_profile
    FROM public.user_profiles WHERE mobile=phone;
  SELECT value INTO cap_text FROM warehouse_security.auth_config WHERE key='otp_phone_daily_cap';
  phone_cap := CASE WHEN cap_text ~ '^[0-9]{1,4}$' THEN greatest(cap_text::integer,1) ELSE 30 END;
  SELECT value INTO cap_text FROM warehouse_security.auth_config WHERE key='otp_trusted_daily_reserve';
  trusted_reserve := least(CASE WHEN cap_text ~ '^[0-9]{1,4}$' THEN cap_text::integer ELSE 10 END, phone_cap);
  SELECT count(*), count(*) FILTER (WHERE l.lane='open') INTO day_total, day_open
    FROM warehouse_security.otp_send_log l WHERE l.phone_number=phone AND l.created_at>now()-interval '24 hours';
  IF day_total >= phone_cap THEN RETURN jsonb_build_object('success',false,'code','rate_limited'); END IF;
  IF known AND p_ip_address IS NOT NULL AND EXISTS (SELECT 1 FROM warehouse_security.otp_trusted_sources t
      WHERE t.phone_number=phone AND t.ip_address=p_ip_address AND t.last_verified>now()-interval '90 days') THEN
    lane := 'trusted';
    IF (SELECT count(*) FROM warehouse_security.otp_send_log l WHERE l.phone_number=phone AND l.lane='trusted'
        AND l.ip_address=p_ip_address AND l.created_at>now()-interval '1 hour') >= 5 THEN
      RETURN jsonb_build_object('success',false,'code','rate_limited');
    END IF;
  ELSE
    lane := 'open';
    INSERT INTO public.otp_rate_limits(phone_number) VALUES (phone) ON CONFLICT DO NOTHING;
    SELECT * INTO limits FROM public.otp_rate_limits WHERE phone_number=phone FOR UPDATE;
    IF limits.last_reset_hour < now()-interval '1 hour' THEN limits.hourly_count:=0; limits.last_reset_hour:=now(); END IF;
    IF limits.last_reset_day < now()-interval '1 day' THEN limits.daily_count:=0; limits.last_reset_day:=now(); END IF;
    -- daily_count is still kept up to date but no longer decides: the 24 hour
    -- count above replaces the fixed day window.
    IF limits.hourly_count >= 5 OR day_open >= phone_cap - trusted_reserve THEN
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
  -- Migration 97: the operator's ceiling on provider requests in any 24 hours. Checked here, with
  -- the warehouse row locked, and before any counter is charged, so a refusal sends and counts nothing.
  SELECT value INTO cap_text FROM warehouse_security.auth_config WHERE key='otp_daily_provider_attempt_cap';
  provider_cap := CASE WHEN cap_text ~ '^[0-9]{1,7}$' THEN cap_text::integer END;
  IF provider_cap IS NOT NULL THEN
    SELECT COALESCE(sum(a.attempts),0) INTO provider_used FROM warehouse_security.otp_provider_attempts a
      WHERE a.created_at>now()-interval '24 hours';
    IF provider_used >= provider_cap THEN RETURN jsonb_build_object('success',false,'code','rate_limited'); END IF;
  END IF;
  IF p_ip_address IS NOT NULL THEN
    INSERT INTO public.ip_rate_limits(ip_address) VALUES (p_ip_address) ON CONFLICT DO NOTHING;
    SELECT * INTO ip_limits FROM public.ip_rate_limits WHERE ip_address=p_ip_address FOR UPDATE;
    IF ip_limits.last_reset_hour < now()-interval '1 hour' THEN ip_limits.hourly_count:=0; ip_limits.last_reset_hour:=now(); END IF;
    IF ip_limits.hourly_count >= warehouse_security.otp_source_send_cap(p_ip_address) THEN RETURN jsonb_build_object('success',false,'code','rate_limited'); END IF;
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
  DELETE FROM warehouse_security.otp_send_log WHERE created_at<now()-interval '2 days';
  INSERT INTO warehouse_security.otp_send_log(request_id,phone_number,lane,ip_address) VALUES (request_id,phone,lane,p_ip_address);
  -- Migration 97: one provider attempt is reserved now; operator_finish_otp records the real number.
  DELETE FROM warehouse_security.otp_provider_attempts WHERE created_at<now()-interval '2 days';
  INSERT INTO warehouse_security.otp_provider_attempts(request_id,attempts) VALUES (request_id,1);
  RETURN jsonb_build_object('success',true,'data',jsonb_build_object('request_id',request_id,'phone_number',phone,
    'otp_code',code,'expires_at',now()+interval '5 minutes'));
END $function$;

REVOKE ALL ON FUNCTION public.operator_prepare_otp(text,inet) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.operator_prepare_otp(text,inet) TO service_role;
