-- public.operator_verify_otp: the definition setup applies after the numbered migrations whenever this file's checksum changes
-- (scripts/migration-plan.mjs, table warehouse_migrations.definitions). Edit the function here, never in a new migration.
-- Starts as the function migrations 000 to 126 leave (the numbered files that patched it stay as they are, never edited).
CREATE OR REPLACE FUNCTION public.operator_verify_otp(p_phone_number text, p_otp_code text, p_name text DEFAULT NULL::text, p_display_name text DEFAULT NULL::text, p_ip_address inet DEFAULT NULL::inet)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'extensions'
AS $function$
DECLARE phone text; challenge public.otp_verifications; profile public.user_profiles;
  secret text; token text; session_data jsonb; expires timestamptz;
  candidates uuid[]; clean_name text; clean_display text; created_now boolean := false;
  glass_id uuid; glass_hash text; glass_used boolean := false;
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
  -- Migration 126: a break-glass code (warehouse_security.break_glass_code) is looked for only when no SMS code matched. It belongs
  -- to an active, approved administrator (a person: not a service account, not deleted) with this number, works once, expires after 10
  -- minutes and ends after five wrong tries from any address. A wrong try is also a failed verification of the source, below.
  IF challenge.id IS NULL AND p_otp_code ~ '^[0-9]{6}$' THEN
    SELECT b.id, b.code_hash INTO glass_id, glass_hash FROM warehouse_security.break_glass_codes b
      JOIN public.user_profiles a ON a.auth_user_id=b.user_id AND a.mobile=phone AND a.role='admin' AND a.active AND a.enrollment_status='approved'
        AND NOT a.is_service_account AND a.deleted_at IS NULL
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
  session_data := warehouse_security.issue_session(profile.auth_user_id);
  RETURN jsonb_build_object('success',true,'data',jsonb_build_object('action','login','user',to_jsonb(profile),'session',session_data));
END $function$;

REVOKE ALL ON FUNCTION public.operator_verify_otp(text,text,text,text,inet) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.operator_verify_otp(text,text,text,text,inet) TO service_role;
