-- Operator auth is separate from the opt-in local demo. Only the Edge worker's
-- service credential can prepare/deliver/verify production OTP challenges.
INSERT INTO public.api_configurations(environment,app_version,maintenance_mode,is_active)
VALUES ('production','0.2.0',false,true) ON CONFLICT(environment,is_active) DO NOTHING;
UPDATE public.sms_config SET provider='msg91',production_mode=true,updated_at=now() WHERE id=1;
INSERT INTO warehouse_security.auth_config(key,value) VALUES ('demo_auth_enabled','false')
ON CONFLICT(key) DO UPDATE SET value='false';
-- Historical demo RPCs stay in the immutable migrations but have no executable
-- production implementation or anonymous PostgREST route.
CREATE OR REPLACE FUNCTION public.send_otp(p_phone_number varchar,p_purpose varchar DEFAULT 'login',
  p_user_agent text DEFAULT NULL,p_ip_address inet DEFAULT NULL,p_captcha_token text DEFAULT NULL) RETURNS jsonb
LANGUAGE sql SECURITY DEFINER SET search_path=pg_catalog AS $$
  SELECT jsonb_build_object('success',false,'message','Use the operator OTP endpoint');
$$;
CREATE OR REPLACE FUNCTION public.verify_otp_or_register(p_phone_number varchar,p_otp_code varchar,
  p_name varchar DEFAULT NULL,p_display_name varchar DEFAULT NULL) RETURNS jsonb
LANGUAGE sql SECURITY DEFINER SET search_path=pg_catalog AS $$
  SELECT jsonb_build_object('success',false,'message','Use the operator OTP endpoint');
$$;
REVOKE EXECUTE ON FUNCTION public.send_otp(varchar,varchar,text,inet,text),
  public.verify_otp_or_register(varchar,varchar,varchar,varchar) FROM PUBLIC,anon,authenticated;
ALTER TABLE public.user_profiles ADD COLUMN enrollment_status text NOT NULL DEFAULT 'approved'
  CHECK (enrollment_status IN ('pending','approved','rejected','disabled'));
UPDATE public.user_profiles SET enrollment_status='disabled' WHERE NOT active;
CREATE INDEX operator_pending_profiles ON public.user_profiles(created_at) WHERE enrollment_status='pending';

CREATE TABLE warehouse_security.enrollment_tokens (
  token_hash text PRIMARY KEY,
  user_id uuid NOT NULL REFERENCES public.user_profiles(auth_user_id) ON DELETE CASCADE,
  expires_at timestamptz NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX enrollment_tokens_user ON warehouse_security.enrollment_tokens(user_id);
REVOKE ALL ON warehouse_security.enrollment_tokens FROM PUBLIC, anon, authenticated, service_role;
CREATE TABLE warehouse_security.operator_otp_global_limit (
  id boolean PRIMARY KEY DEFAULT true CHECK (id),
  hourly_count integer NOT NULL DEFAULT 0,
  window_started timestamptz NOT NULL DEFAULT now()
);
INSERT INTO warehouse_security.operator_otp_global_limit(id) VALUES (true);
REVOKE ALL ON warehouse_security.operator_otp_global_limit FROM PUBLIC,anon,authenticated,service_role;

CREATE OR REPLACE FUNCTION warehouse_security.bootstrap_first_admin(p_phone text, p_name text) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE result uuid; phone text;
BEGIN
  IF session_user <> 'supabase_admin' THEN RAISE EXCEPTION 'Installer only' USING ERRCODE='42501'; END IF;
  PERFORM pg_advisory_xact_lock(71043);
  IF EXISTS (SELECT 1 FROM public.user_profiles WHERE role='admin') THEN
    RAISE EXCEPTION 'An administrator already exists';
  END IF;
  phone := warehouse_security.normalize_phone(p_phone);
  IF nullif(btrim(p_name),'') IS NULL THEN RAISE EXCEPTION 'Administrator name is required'; END IF;
  INSERT INTO public.user_profiles(auth_user_id,mobile,name,display_name,role,active,mobile_verified,enrollment_status)
  VALUES (gen_random_uuid(),phone,left(btrim(p_name),30),left(btrim(p_name),30),'admin',true,false,'approved')
  RETURNING auth_user_id INTO result;
  RETURN result;
END $$;
REVOKE ALL ON FUNCTION warehouse_security.bootstrap_first_admin(text,text) FROM PUBLIC,anon,authenticated,service_role;
GRANT USAGE ON SCHEMA warehouse_security TO supabase_admin;
GRANT EXECUTE ON FUNCTION warehouse_security.bootstrap_first_admin(text,text) TO supabase_admin;

CREATE FUNCTION public.operator_prepare_otp(p_phone_number text, p_ip_address inet DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public,extensions AS $$
DECLARE phone text; limits public.otp_rate_limits; ip_limits public.ip_rate_limits;
  code text; request_id uuid; secret text; retry_at timestamptz; global_count integer; global_window timestamptz;
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
  SELECT hourly_count,window_started INTO global_count,global_window
    FROM warehouse_security.operator_otp_global_limit WHERE id=true FOR UPDATE;
  IF global_window < now()-interval '1 hour' THEN global_count:=0; global_window:=now(); END IF;
  IF global_count >= 300 THEN RETURN jsonb_build_object('success',false,'code','rate_limited'); END IF;
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
  UPDATE public.otp_verifications SET verified=true WHERE phone_number=phone AND NOT verified;
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

CREATE FUNCTION public.operator_finish_otp(p_request_id uuid, p_delivered boolean, p_provider_id text DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE row_otp public.otp_verifications;
BEGIN
  SELECT * INTO row_otp FROM public.otp_verifications WHERE id=p_request_id FOR UPDATE;
  IF row_otp.id IS NULL OR row_otp.delivery_status<>'sending' THEN
    RETURN jsonb_build_object('success',false,'code','invalid_request');
  END IF;
  UPDATE public.otp_verifications SET delivery_status=CASE WHEN p_delivered THEN 'accepted' ELSE 'failed' END,
    verified=NOT p_delivered, msg91_request_id=left(p_provider_id,255),
    otp_code_hash=CASE WHEN p_delivered THEN otp_code_hash ELSE NULL END WHERE id=p_request_id;
  RETURN jsonb_build_object('success',true);
END $$;

CREATE FUNCTION public.operator_verify_otp(p_phone_number text,p_otp_code text,p_name text DEFAULT NULL,p_display_name text DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public,extensions AS $$
DECLARE phone text; challenge public.otp_verifications; profile public.user_profiles;
  secret text; token text; session_data jsonb; expires timestamptz;
BEGIN
  IF COALESCE((SELECT value FROM warehouse_security.auth_config WHERE key='auth_mode'),'') <> 'operator' THEN
    RETURN jsonb_build_object('success',false,'code','unavailable');
  END IF;
  phone := warehouse_security.normalize_phone(p_phone_number);
  PERFORM pg_advisory_xact_lock(hashtextextended(phone,71044));
  SELECT * INTO challenge FROM public.otp_verifications WHERE phone_number=phone AND NOT verified
    ORDER BY created_at DESC LIMIT 1 FOR UPDATE;
  IF challenge.id IS NULL OR challenge.delivery_status<>'accepted' OR challenge.expires_at<=now()
    OR challenge.attempts>=challenge.max_attempts THEN
    RETURN jsonb_build_object('success',false,'code','invalid_otp');
  END IF;
  UPDATE public.otp_verifications SET attempts=attempts+1 WHERE id=challenge.id;
  SELECT value INTO secret FROM warehouse_security.auth_config WHERE key='jwt_secret';
  IF p_otp_code !~ '^[0-9]{6}$' OR challenge.otp_code_hash IS DISTINCT FROM
    encode(extensions.hmac(phone||':'||p_otp_code||':'||challenge.id::text,secret,'sha256'),'hex') THEN
    RETURN jsonb_build_object('success',false,'code','invalid_otp');
  END IF;
  UPDATE public.otp_verifications SET verified=true,verified_at=now(),otp_code_hash=NULL WHERE id=challenge.id;
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

CREATE FUNCTION public.operator_enrollment_status(p_token text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public,extensions AS $$
DECLARE state text;
BEGIN
  IF p_token IS NULL OR p_token !~ '^[0-9a-f]{64}$' THEN RETURN jsonb_build_object('success',false,'code','invalid_token'); END IF;
  SELECT p.enrollment_status INTO state FROM warehouse_security.enrollment_tokens t
    JOIN public.user_profiles p ON p.auth_user_id=t.user_id
    WHERE t.token_hash=encode(extensions.digest(p_token,'sha256'),'hex') AND t.expires_at>now();
  IF state IS NULL THEN RETURN jsonb_build_object('success',false,'code','invalid_token'); END IF;
  RETURN jsonb_build_object('success',true,'data',jsonb_build_object('status',state));
END $$;

CREATE FUNCTION public.operator_enrollment_signout(p_token text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public,extensions AS $$
BEGIN
  IF p_token ~ '^[0-9a-f]{64}$' THEN
    DELETE FROM warehouse_security.enrollment_tokens WHERE token_hash=encode(extensions.digest(p_token,'sha256'),'hex');
  END IF;
  RETURN jsonb_build_object('success',true);
END $$;

CREATE FUNCTION public.operator_review_enrollment(p_user_id uuid,p_decision text,p_customer_ids uuid[] DEFAULT '{}'::uuid[]) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE profile public.user_profiles; assigned_customer uuid; admin_id uuid;
BEGIN
  IF auth.jwt()->>'role'<>'authenticated' OR warehouse_security.active_role()<>'admin' THEN
    RAISE EXCEPTION 'Administrator required' USING ERRCODE='42501';
  END IF;
  SELECT id INTO admin_id FROM public.user_profiles WHERE auth_user_id=auth.uid();
  SELECT * INTO profile FROM public.user_profiles WHERE id=p_user_id FOR UPDATE;
  IF profile.id IS NULL OR profile.role<>'customer' THEN RETURN jsonb_build_object('success',false,'code','unknown_user'); END IF;
  IF p_decision NOT IN ('approved','rejected','disabled') THEN RAISE EXCEPTION 'Invalid decision' USING ERRCODE='22023'; END IF;
  IF p_decision='approved' THEN
    IF COALESCE(cardinality(p_customer_ids),0)<1 OR EXISTS (SELECT 1 FROM unnest(p_customer_ids) AS requested(id)
      WHERE NOT EXISTS (SELECT 1 FROM public.customers c WHERE c.id=requested.id)) THEN
      RAISE EXCEPTION 'At least one valid customer assignment is required' USING ERRCODE='22023';
    END IF;
    UPDATE public.user_profiles SET enrollment_status='approved',active=true,updated_at=now() WHERE id=p_user_id;
    UPDATE public.users_customers_new SET active=false WHERE user_profile_id=p_user_id;
    FOREACH assigned_customer IN ARRAY p_customer_ids LOOP
      INSERT INTO public.users_customers_new(user_profile_id,customer_id,assigned_by,active)
      VALUES (p_user_id,assigned_customer,admin_id,true)
      ON CONFLICT(user_profile_id,customer_id) DO UPDATE SET active=true,assigned_by=excluded.assigned_by,assigned_at=now();
    END LOOP;
  ELSE
    UPDATE public.user_profiles SET enrollment_status=p_decision,active=false,updated_at=now() WHERE id=p_user_id;
    UPDATE public.users_customers_new SET active=false WHERE user_profile_id=p_user_id;
    DELETE FROM warehouse_security.refresh_sessions WHERE user_id=profile.auth_user_id;
  END IF;
  RETURN jsonb_build_object('success',true,'data',jsonb_build_object('status',p_decision));
END $$;

-- Every token consumer consults the current account state; old JWT claims never
-- override a rejected or disabled decision.
CREATE OR REPLACE FUNCTION warehouse_security.active_role() RETURNS text LANGUAGE sql STABLE SECURITY DEFINER
SET search_path=pg_catalog AS $$
  SELECT p.role::text FROM public.user_profiles p WHERE p.auth_user_id=auth.uid() AND p.active
    AND p.enrollment_status='approved' AND EXISTS (SELECT 1 FROM warehouse_security.refresh_sessions s
      WHERE s.user_id=p.auth_user_id AND s.id::text=auth.jwt()->>'session_id' AND s.expires_at>now());
$$;
CREATE OR REPLACE FUNCTION public.check_session() RETURNS void LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=pg_catalog AS $$
BEGIN
  IF auth.jwt()->>'role'='authenticated' AND NOT EXISTS (
    SELECT 1 FROM warehouse_security.refresh_sessions s JOIN public.user_profiles p ON p.auth_user_id=s.user_id
    WHERE s.id::text=auth.jwt()->>'session_id' AND s.user_id=auth.uid() AND s.expires_at>now()
      AND p.active AND p.enrollment_status='approved')
  THEN RAISE EXCEPTION 'Session expired or revoked' USING ERRCODE='42501'; END IF;
END $$;

REVOKE EXECUTE ON FUNCTION public.operator_prepare_otp(text,inet),public.operator_finish_otp(uuid,boolean,text),
  public.operator_verify_otp(text,text,text,text),public.operator_enrollment_status(text),
  public.operator_enrollment_signout(text),public.operator_review_enrollment(uuid,text,uuid[]) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.operator_prepare_otp(text,inet),public.operator_finish_otp(uuid,boolean,text),
  public.operator_verify_otp(text,text,text,text),public.operator_enrollment_status(text),
  public.operator_enrollment_signout(text) TO service_role;
GRANT EXECUTE ON FUNCTION public.operator_review_enrollment(uuid,text,uuid[]) TO authenticated;
NOTIFY pgrst,'reload schema';
