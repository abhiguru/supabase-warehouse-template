-- Follow-ups to the independent review of migrations 39 to 46 (2026-10-11).
--
--  1. OTP limits. Migration 44 kept a known phone from being locked out, but
--     its "slow lane" was one slot per phone that any single address could
--     hold, it let a known phone be sent about 116 SMS a day (20 before), and
--     it let one code be tried ten times (5 before). Rebalanced, in this
--     order of priority:
--       a. a code can be tried wrongly 5 times in all, from every source
--          together;
--       b. one phone is sent at most otp_phone_daily_cap (30) codes in any 24
--          hours, all lanes together;
--       c. inside those two bounds, sources that have signed in for the phone
--          keep otp_trusted_daily_reserve (10) of the 30 for themselves.
--     The slow lane is gone. The installer can clear one phone's counters.
--  2. get_supervisors returns the mobile number to administrators and
--     supervisors only.
--  3. A supervisor changes the status or role only of a profile whose access
--     request is approved; a pending request is reviewed before its role changes.
--  4. Staff may read and delete an unreferenced photo file only in the folder
--     of a receipt or dispatch that is not deleted.
--  5. update_grn takes an optional idempotency key.
-- docs/OPERATOR_INSTALL.md has the limits table and the recovery step.

-- Replaces one marker in a function body, failing unless it occurs exactly
-- `expected` times. Dropped at the end of this migration.
CREATE FUNCTION pg_temp.patch_rpc(fn regprocedure, marker text, replacement text, expected integer DEFAULT 1) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE definition text := pg_get_functiondef(fn); occurrences integer;
BEGIN
  occurrences := (length(definition)-length(replace(definition,marker,'')))/length(marker);
  IF occurrences <> expected THEN
    RAISE EXCEPTION 'Expected % occurrence(s) of the marker in %, found %: %', expected, fn, occurrences, left(marker,80);
  END IF;
  EXECUTE replace(definition,marker,replacement);
END $$;

-- ---------------------------------------------------------------------------
-- 1. OTP limits
-- ---------------------------------------------------------------------------
-- One row per code that counts against its phone. otp_verifications cannot
-- carry a 24 hour count: its rows are removed about an hour after they expire.
-- A send the provider did not accept is deleted again (operator_finish_otp).
CREATE TABLE warehouse_security.otp_send_log (
  request_id uuid PRIMARY KEY,
  phone_number text NOT NULL,
  lane text NOT NULL CHECK (lane IN ('open','trusted')),
  ip_address inet,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX otp_send_log_phone_created ON warehouse_security.otp_send_log(phone_number, created_at);
CREATE INDEX otp_send_log_created ON warehouse_security.otp_send_log(created_at);
ALTER TABLE warehouse_security.otp_send_log ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON warehouse_security.otp_send_log FROM PUBLIC, anon, authenticated, service_role;
INSERT INTO warehouse_security.auth_config(key,value) VALUES
  ('otp_phone_daily_cap','30'),('otp_trusted_daily_reserve','10') ON CONFLICT DO NOTHING;
-- Codes of the last hour that migration 44 counted stay counted.
INSERT INTO warehouse_security.otp_send_log(request_id,phone_number,lane,ip_address,created_at)
SELECT v.id, v.phone_number, CASE v.quota_lane WHEN 'trusted' THEN 'trusted' ELSE 'open' END, v.ip_address, v.created_at
FROM public.otp_verifications v
WHERE v.quota_lane IS NOT NULL AND NOT v.quota_refunded AND v.created_at > now() - interval '24 hours';

-- Send limits. "Known" means the phone has an approved, active profile; a
-- "trusted" source is an address that completed a sign-in for this phone in
-- the last 90 days (known phones only).
--   per phone    otp_phone_daily_cap (30) codes in any 24 hours, every source
--                and lane together.
--   open lane    every source that is not trusted, together: 5 per hour and
--                the daily cap less otp_trusted_daily_reserve (30 - 10 = 20)
--                in any 24 hours.
--   trusted lane 5 per hour per trusted address, up to the daily cap. Sources
--                that are not trusted cannot use the reserve, so trusted
--                sources always have at least 10 codes a day between them.
-- A used-up limit answers rate_limited; there is no slow lane. The 60 s resend
-- cooldown is per phone and source address and answers resend_cooldown with
-- retry_at. The warehouse cap (otp_global_hourly_cap) stays; phones that are
-- not known may use only otp_unknown_hourly_cap of it. Per source address: 30
-- per hour.
CREATE OR REPLACE FUNCTION public.operator_prepare_otp(p_phone_number text, p_ip_address inet DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public,extensions AS $$
DECLARE phone text; limits public.otp_rate_limits; ip_limits public.ip_rate_limits;
  code text; request_id uuid; secret text; retry_at timestamptz; global_count integer; unknown_used integer;
  global_window timestamptz; cap_text text; global_cap integer; unknown_cap integer;
  known boolean; has_profile boolean; lane text;
  phone_cap integer; trusted_reserve integer; day_total integer; day_open integer;
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
  DELETE FROM warehouse_security.otp_send_log WHERE created_at<now()-interval '2 days';
  INSERT INTO warehouse_security.otp_send_log(request_id,phone_number,lane,ip_address) VALUES (request_id,phone,lane,p_ip_address);
  RETURN jsonb_build_object('success',true,'data',jsonb_build_object('request_id',request_id,'phone_number',phone,
    'otp_code',code,'expires_at',now()+interval '5 minutes'));
END $$;

-- A send the provider did not accept gives its phone and warehouse allowance
-- back (not for provider_validation, which the caller's number caused). The
-- per-source charge is kept.
DO $patch$ BEGIN PERFORM pg_temp.patch_rpc('public.operator_finish_otp(uuid,boolean,text)',
  $m$    UPDATE public.otp_verifications SET quota_refunded=true WHERE id=p_request_id;
$m$, $r$    UPDATE public.otp_verifications SET quota_refunded=true WHERE id=p_request_id;
    DELETE FROM warehouse_security.otp_send_log WHERE request_id=p_request_id;
$r$); END $patch$;

-- Wrong attempts: five per issued code in all, as before migration 44. So that
-- a stranger cannot use up all five, sources other than the one that asked for
-- the code share two of them; the requester therefore keeps at least three.
-- `attempts` counts the guesses of other sources, `source_attempts` those of
-- the requester. A request and a verification that both carry no source
-- address count as the same source. Each source address is also limited to 20
-- failed verifications per hour over all phones.
CREATE OR REPLACE FUNCTION public.operator_verify_otp(p_phone_number text,p_otp_code text,p_name text DEFAULT NULL,
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

-- Recovery while a phone's send limits are used up by someone else: the
-- installer clears that phone's counters (docs/OPERATOR_INSTALL.md,
-- "Authentication and OTP limits"). Codes already sent stay valid; addresses
-- the phone has signed in from stay trusted. Returns the number of counted
-- codes it cleared.
CREATE FUNCTION warehouse_security.reset_otp_limits(p_phone text) RETURNS integer
LANGUAGE plpgsql SET search_path = pg_catalog AS $$
DECLARE phone text := warehouse_security.normalize_phone(p_phone); cleared integer;
BEGIN
  IF session_user <> 'supabase_admin' THEN RAISE EXCEPTION 'Installer only' USING ERRCODE='42501'; END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended(phone,71044));
  DELETE FROM warehouse_security.otp_send_log WHERE phone_number=phone;
  GET DIAGNOSTICS cleared = ROW_COUNT;
  UPDATE public.otp_rate_limits SET hourly_count=0,daily_count=0,last_reset_hour=now(),last_reset_day=now(),updated_at=now()
    WHERE phone_number=phone;
  RETURN cleared;
END $$;
REVOKE ALL ON FUNCTION warehouse_security.reset_otp_limits(text) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION warehouse_security.reset_otp_limits(text) TO supabase_admin;

-- ---------------------------------------------------------------------------
-- 2. Supervisor picker
-- ---------------------------------------------------------------------------
-- Migration 45 left the mobile number (also the sign-in identifier) of every
-- colleague in the answer for staff. The app picks by name and no longer shows
-- it. Every caller gets id, name, display_name and role; administrators and
-- supervisors, who see it in user management anyway, also get phone.
DO $patch$ BEGIN PERFORM pg_temp.patch_rpc('public.get_supervisors(text)',
  $m$        SELECT jsonb_build_object('id', id, 'name', name, 'phone', mobile) as supervisor, name
$m$, $r$        SELECT jsonb_build_object('id', id, 'name', name, 'display_name', display_name, 'role', role)
               || CASE WHEN warehouse_security.active_role() IN ('admin', 'supervisor')
                         OR auth.jwt() ->> 'role' = 'service_role'
                       THEN jsonb_build_object('phone', mobile) ELSE '{}'::jsonb END as supervisor, name
$r$); END $patch$;

-- ---------------------------------------------------------------------------
-- 3. Supervisors and access requests
-- ---------------------------------------------------------------------------
-- Migration 45 opened update_user_status and update_user_role to supervisors.
-- update_user_status(true) sets enrollment_status to 'approved', so a
-- supervisor could re-approve a request an administrator had rejected or an
-- access an administrator had disabled, although enrollment review is an
-- administrator's decision. A supervisor now acts only on a profile whose
-- access request is approved: deactivation still works, and giving access back
-- is done by an administrator.
DO $patch$ BEGIN PERFORM pg_temp.patch_rpc('public.update_user_status(uuid,boolean)',
  $m$    -- No change needed
    IF v_old_active = p_active THEN
$m$, $r$    -- Enrollment review is an administrator's decision (migration 47)
    IF v_caller_role = 'supervisor' AND EXISTS (
        SELECT 1 FROM user_profiles WHERE id = p_user_id AND enrollment_status IS DISTINCT FROM 'approved'
    ) THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'ENROLLMENT_NOT_APPROVED',
            'message', 'Only an administrator can change a user whose access is not approved'
        );
    END IF;

    -- No change needed
    IF v_old_active = p_active THEN
$r$); END $patch$;
-- A role other than 'customer' on a pending request made it unreviewable:
-- operator_review_enrollment answers unknown_user and update_user_status
-- refuses a pending profile.
DO $patch$ BEGIN PERFORM pg_temp.patch_rpc('public.update_user_role(uuid,public.user_role)',
  $m$    -- No change needed
    IF v_old_role = p_new_role THEN
$m$, $r$    -- A pending access request is reviewed before its role changes (migration 47)
    IF EXISTS (SELECT 1 FROM user_profiles WHERE id = p_user_id AND enrollment_status = 'pending') THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'ENROLLMENT_PENDING',
            'message', 'Review the access request before changing the role'
        );
    END IF;

    -- Enrollment review is an administrator's decision (migration 47)
    IF v_caller_role = 'supervisor' AND EXISTS (
        SELECT 1 FROM user_profiles WHERE id = p_user_id AND enrollment_status IS DISTINCT FROM 'approved'
    ) THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'ENROLLMENT_NOT_APPROVED',
            'message', 'Only an administrator can change a user whose access is not approved'
        );
    END IF;

    -- No change needed
    IF v_old_role = p_new_role THEN
$r$); END $patch$;

-- ---------------------------------------------------------------------------
-- 4. Photo files staff may remove
-- ---------------------------------------------------------------------------
-- The staff storage policies of migration 45 covered every file that no image
-- row names: also the photos of deleted receipts and dispatches, whose rows
-- are gone while the files stay. A file is now covered only when it lies in
-- the folder of a receipt or dispatch that is not deleted (the documents staff
-- can edit), no image row names it, and the legacy header column of that
-- document does not name it. That is the file of a photo just removed in an
-- edit form, or of an upload that was never registered. False for every role
-- but staff, so the function tells no one else which paths are in use.
CREATE FUNCTION warehouse_security.staff_may_remove_image_file(p_bucket text, p_name text) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog AS $$
  SELECT warehouse_security.active_role() = 'staff' AND CASE p_bucket
    WHEN 'grn-images' THEN
      NOT EXISTS (SELECT 1 FROM public.grn_images i WHERE i.storage_path = p_name)
      AND EXISTS (SELECT 1 FROM public.goodsreceived g
        WHERE g.id::text = substring(p_name from '^(?:headers|items)/([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})/[^/]')
          AND g.deleted_at IS NULL
          AND (g.gr_image_url IS NULL OR position(p_name IN g.gr_image_url) = 0))
    WHEN 'dispatch-images' THEN
      NOT EXISTS (SELECT 1 FROM public.dispatch_images i WHERE i.storage_path = p_name)
      AND EXISTS (SELECT 1 FROM public.dispatch d
        WHERE d.id::text = substring(p_name from '^([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})/[^/]')
          AND d.deleted_at IS NULL
          AND (d.disp_image_url IS NULL OR position(p_name IN d.disp_image_url) = 0))
    ELSE false END;
$$;
REVOKE ALL ON FUNCTION warehouse_security.staff_may_remove_image_file(text,text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION warehouse_security.staff_may_remove_image_file(text,text) TO authenticated, service_role;
-- scripts/configure-storage.sql now names the function above. The policies of
-- an installation that has applied this migration but not yet rerun that
-- script still call image_file_unreferenced, so it applies the same rule.
CREATE OR REPLACE FUNCTION warehouse_security.image_file_unreferenced(p_bucket text, p_name text) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog AS $$
  SELECT warehouse_security.staff_may_remove_image_file(p_bucket, p_name);
$$;

-- ---------------------------------------------------------------------------
-- 5. update_grn: optional idempotency key
-- ---------------------------------------------------------------------------
-- Since migration 40 an edit can add a line. When the answer to such an edit
-- was lost and the user saved again, the line was added twice. With
-- p_idempotency_key, the same key from the same user for the same receipt
-- within 24 hours returns the stored answer (plus "idempotent": true) and
-- changes nothing. Without the key the function behaves as before, so an app
-- build that does not send it keeps working.
-- A new parameter is a new signature: the old function is dropped and the new
-- one created in its place, so PostgREST still sees exactly one update_grn.
DO $patch$
DECLARE old_fn regprocedure; definition text; marker text; replacement text; occurrences integer;
BEGIN
  SELECT p.oid::regprocedure INTO STRICT old_fn FROM pg_proc p
    WHERE p.pronamespace='public'::regnamespace AND p.proname='update_grn';
  definition := pg_get_functiondef(old_fn);

  marker := $m$, p_duration_mode character varying DEFAULT NULL::character varying)$m$;
  replacement := $r$, p_duration_mode character varying DEFAULT NULL::character varying, p_idempotency_key text DEFAULT NULL::text)$r$;
  occurrences := (length(definition)-length(replace(definition,marker,'')))/length(marker);
  IF occurrences <> 1 THEN RAISE EXCEPTION 'Expected one parameter list end in update_grn, found %', occurrences; END IF;
  definition := replace(definition,marker,replacement);

  marker := $m$    v_item_name varchar;
BEGIN$m$;
  replacement := $r$    v_item_name varchar;
    v_cached_response jsonb;
    v_result jsonb;
BEGIN$r$;
  occurrences := (length(definition)-length(replace(definition,marker,'')))/length(marker);
  IF occurrences <> 1 THEN RAISE EXCEPTION 'Expected one declaration end in update_grn, found %', occurrences; END IF;
  definition := replace(definition,marker,replacement);

  -- The lookup waits behind a first call that is still running: both take the
  -- list-refresh lock, which is also the first lock of the edit itself.
  marker := $m$            'message', 'Insufficient permissions. Only admin and supervisor can update GRNs'
        );
    END IF;
$m$;
  replacement := $r$            'message', 'Insufficient permissions. Only admin and supervisor can update GRNs'
        );
    END IF;

    -- IDEMPOTENCY CHECK: a repeated save answers with the stored result (migration 47)
    IF p_idempotency_key IS NOT NULL THEN
        PERFORM pg_advisory_xact_lock(71040);

        SELECT response INTO v_cached_response
        FROM idempotency_keys
        WHERE idempotency_key = p_idempotency_key
          AND rpc_function = 'update_grn'
          AND created_by = v_user_profile_id
          AND response #>> '{grn,id}' = p_grn_id::text
          AND expires_at > now();

        IF v_cached_response IS NOT NULL THEN
            RETURN v_cached_response || jsonb_build_object('idempotent', true);
        END IF;
    END IF;
$r$;
  occurrences := (length(definition)-length(replace(definition,marker,'')))/length(marker);
  IF occurrences <> 1 THEN RAISE EXCEPTION 'Expected one permission check in update_grn, found %', occurrences; END IF;
  definition := replace(definition,marker,replacement);

  marker := $m$        RETURN jsonb_build_object(
            'success', true,
            'message', 'GRN updated successfully',$m$;
  replacement := $r$        v_result := jsonb_build_object(
            'success', true,
            'message', 'GRN updated successfully',$r$;
  occurrences := (length(definition)-length(replace(definition,marker,'')))/length(marker);
  IF occurrences <> 1 THEN RAISE EXCEPTION 'Expected one success answer in update_grn, found %', occurrences; END IF;
  definition := replace(definition,marker,replacement);

  marker := $m$            'item_mapping', v_item_mapping
        );
$m$;
  replacement := $r$            'item_mapping', v_item_mapping
        );

        -- Kept for the 24 hours a retry is answered from it. A key another
        -- function or user holds is left alone unless it has expired.
        IF p_idempotency_key IS NOT NULL THEN
            INSERT INTO idempotency_keys (idempotency_key, rpc_function, response, created_by, expires_at)
            VALUES (p_idempotency_key, 'update_grn', v_result, v_user_profile_id, now() + interval '24 hours')
            ON CONFLICT (idempotency_key) DO UPDATE SET
                rpc_function = EXCLUDED.rpc_function,
                response = EXCLUDED.response,
                created_by = EXCLUDED.created_by,
                created_at = now(),
                expires_at = EXCLUDED.expires_at
            WHERE idempotency_keys.expires_at <= now()
               OR (idempotency_keys.rpc_function = EXCLUDED.rpc_function
                   AND idempotency_keys.created_by IS NOT DISTINCT FROM EXCLUDED.created_by);
        END IF;

        RETURN v_result;
$r$;
  occurrences := (length(definition)-length(replace(definition,marker,'')))/length(marker);
  IF occurrences <> 1 THEN RAISE EXCEPTION 'Expected one answer end in update_grn, found %', occurrences; END IF;
  definition := replace(definition,marker,replacement);

  EXECUTE format('DROP FUNCTION %s', old_fn);
  EXECUTE definition;
END $patch$;
REVOKE ALL ON FUNCTION public.update_grn(uuid,varchar,timestamptz,uuid,varchar,uuid,varchar,uuid,varchar,varchar,varchar,boolean,varchar,jsonb,jsonb,varchar,text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.update_grn(uuid,varchar,timestamptz,uuid,varchar,uuid,varchar,uuid,varchar,varchar,varchar,boolean,varchar,jsonb,jsonb,varchar,text) TO authenticated, service_role;
DO $verify$ BEGIN
  IF (SELECT count(*) FROM pg_proc WHERE pronamespace='public'::regnamespace AND proname='update_grn') <> 1 THEN
    RAISE EXCEPTION 'Expected exactly one update_grn';
  END IF;
END $verify$;

DROP FUNCTION pg_temp.patch_rpc(regprocedure, text, text, integer);
NOTIFY pgrst, 'reload schema';
