-- Central login, facility side (2026-10-12). docs/CENTRAL_LOGIN.md has the
-- contract.
--
-- The association's central service proves who a person is and signs a
-- short-lived identity token for ONE facility. functions/central-exchange
-- verifies that token (signature, issuer, audience, time, type) and then calls
-- operator_central_exchange with the service key. From there the facility does
-- what a correct SMS code does today: a pending access request for an unknown
-- person, a session for an approved one, a refusal for a disabled one.
--
--  1. user_profiles carries the central identity (issuer, subject) a profile
--     is linked to. An existing profile is linked only together with a
--     correct SMS code of this facility.
--  2. A token is accepted once: warehouse_security.central_token_use.
--  3. operator_central_exchange: the exchange itself. Service key only.
--  4. clear_user_central_identity: an administrator unlinks a profile (how an
--     identity_conflict is resolved). Administrators only.
--  5. delete_user_account also drops the central identity of the deleted
--     profile, as it already gives up the phone number.
-- Central login is off until scripts/configure-central.sql writes the trusted
-- issuer to auth_config (setup.sh --central-issuer). Local SMS sign-in is
-- unchanged.

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
-- 1. The central identity of a profile
-- ---------------------------------------------------------------------------
ALTER TABLE public.user_profiles
  ADD COLUMN central_issuer text,
  ADD COLUMN central_subject text,
  ADD CONSTRAINT user_profiles_central_identity_whole
    CHECK ((central_issuer IS NULL) = (central_subject IS NULL));
CREATE UNIQUE INDEX user_profiles_central_identity ON public.user_profiles(central_issuer, central_subject)
  WHERE central_issuer IS NOT NULL AND central_subject IS NOT NULL;
COMMENT ON COLUMN public.user_profiles.central_issuer IS
  'Issuer of the central identity this profile is linked to (migration 49); NULL for a profile that has only signed in with a local SMS code.';
COMMENT ON COLUMN public.user_profiles.central_subject IS
  'The central service''s user id (token claim sub) for this profile; set together with central_issuer.';

-- ---------------------------------------------------------------------------
-- 2. Single use
-- ---------------------------------------------------------------------------
-- token_hash is the SHA-256 of issuer || ' ' || jti. expires_at is the moment
-- after which the edge function refuses the token anyway (its exp plus the
-- clock tolerance), so a row is needed no longer than that.
CREATE TABLE warehouse_security.central_token_use (
  token_hash text PRIMARY KEY,
  expires_at timestamptz NOT NULL
);
CREATE INDEX central_token_use_expires ON warehouse_security.central_token_use(expires_at);
ALTER TABLE warehouse_security.central_token_use ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON warehouse_security.central_token_use FROM PUBLIC, anon, authenticated, service_role;

-- Rows past expiry go when the next token is recorded; retention removes them
-- on an installation where central sign-in has stopped being used.
DO $patch$ BEGIN
  PERFORM pg_temp.patch_rpc('warehouse_maintenance.run_database_retention(timestamptz,boolean)',
  $m$    DELETE FROM public.otp_verifications WHERE expires_at < auth_cutoff;
$m$, $r$    DELETE FROM warehouse_security.central_token_use WHERE expires_at < p_now;
    GET DIAGNOSTICS affected = ROW_COUNT; result := result || jsonb_build_object('central_token_use', affected);
    DELETE FROM public.otp_verifications WHERE expires_at < auth_cutoff;
$r$);
  PERFORM pg_temp.patch_rpc('warehouse_maintenance.run_database_retention(timestamptz,boolean)',
  $m$      'otp_verifications', (SELECT count(*) FROM public.otp_verifications WHERE expires_at < auth_cutoff),
$m$, $r$      'central_token_use', (SELECT count(*) FROM warehouse_security.central_token_use WHERE expires_at < p_now),
      'otp_verifications', (SELECT count(*) FROM public.otp_verifications WHERE expires_at < auth_cutoff),
$r$);
END $patch$;

-- ---------------------------------------------------------------------------
-- 3. The exchange
-- ---------------------------------------------------------------------------
-- Called by functions/central-exchange after it has verified the token. The
-- arguments are checked again here, so a caller that holds the service key but
-- skipped a check still cannot store a malformed identity.
--   p_issuer            the token's iss; must equal auth_config.central_issuer
--   p_subject           the token's sub
--   p_phone_number      the token's phone_number (91 and ten digits)
--   p_token_id          the token's jti
--   p_token_expires_at  the token's exp plus the clock tolerance
--   p_otp_code          optional: a code this facility sent to that phone
-- Answers, in this order:
--   central_unavailable     not operator mode, no trusted issuer, or another issuer
--   invalid_identity_token  an argument is malformed
--   identity_token_used     this jti was accepted before
--   identity_conflict       the phone's profile is linked to another central identity
--   link_required           the phone has a profile that is not linked yet and no
--                           SMS code came with the token; nothing is written to it
--   invalid_otp, rate_limited, account_unavailable
--                           what operator_verify_otp answered to p_otp_code for
--                           such a profile; it is then not linked
--   enrollment_limited      too many new access requests (as for an SMS code)
--   account_unavailable     rejected, disabled or deactivated profile
--   pending / login         as operator_verify_otp
-- The profile is found by (issuer, subject) first and is then used even when
-- its mobile differs from the token's phone: the facility's record of the
-- number is not changed, and the mobile is marked verified only when the two
-- are equal.
-- An EXISTING profile found by phone that has no central identity is linked
-- only with one local proof, a correct SMS code of this facility for that
-- number (p_otp_code, checked by operator_verify_otp, whose answer is then
-- returned as it is). Without that rule, whoever controls the central service
-- could sign in as any profile here that has not signed in centrally yet,
-- administrators included. With it, the central service's word is relied on
-- for two things only: a new access request (which an administrator of this
-- facility approves or not) and later sign-ins of a profile already linked.
-- A token that reaches the single-use step is spent whatever the answer.
CREATE FUNCTION public.operator_central_exchange(p_issuer text, p_subject text, p_phone_number text,
  p_token_id text, p_token_expires_at timestamptz, p_name text DEFAULT NULL,
  p_display_name text DEFAULT NULL, p_ip_address inet DEFAULT NULL, p_otp_code text DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public,extensions AS $$
DECLARE phone text; trusted_issuer text; profile public.user_profiles; by_phone public.user_profiles;
  token text; session_data jsonb; expires timestamptz; otp_answer jsonb;
  clean_name text; clean_display text;
BEGIN
  SELECT value INTO trusted_issuer FROM warehouse_security.auth_config WHERE key='central_issuer';
  IF COALESCE((SELECT value FROM warehouse_security.auth_config WHERE key='auth_mode'),'') <> 'operator'
     OR COALESCE(trusted_issuer,'') = '' OR p_issuer IS DISTINCT FROM trusted_issuer THEN
    RETURN jsonb_build_object('success',false,'code','central_unavailable');
  END IF;
  IF p_subject IS NULL OR p_subject !~ '^[A-Za-z0-9_-]{1,64}$'
     OR p_token_id IS NULL OR p_token_id !~ '^[A-Za-z0-9_-]{16,128}$'
     OR p_phone_number IS NULL OR p_phone_number !~ '^91[0-9]{10}$'
     OR p_token_expires_at IS NULL OR p_token_expires_at <= now()
     OR p_token_expires_at > now() + interval '11 minutes' THEN
    RETURN jsonb_build_object('success',false,'code','invalid_identity_token');
  END IF;
  phone := warehouse_security.normalize_phone(p_phone_number);
  -- The phone lock is the one operator_verify_otp takes, so an SMS sign-in and
  -- an exchange for the same number do not both create the profile. The second
  -- lock does the same for two tokens of one person that name different phones.
  PERFORM pg_advisory_xact_lock(hashtextextended(phone,71044));
  PERFORM pg_advisory_xact_lock(hashtextextended(p_issuer||' '||p_subject,71049));
  DELETE FROM warehouse_security.central_token_use WHERE expires_at < now();
  INSERT INTO warehouse_security.central_token_use(token_hash,expires_at)
    VALUES (encode(extensions.digest(p_issuer||' '||p_token_id,'sha256'),'hex'),p_token_expires_at)
    ON CONFLICT(token_hash) DO NOTHING;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('success',false,'code','identity_token_used');
  END IF;

  SELECT * INTO profile FROM public.user_profiles
    WHERE central_issuer=p_issuer AND central_subject=p_subject FOR UPDATE;
  IF profile.id IS NULL THEN
    SELECT * INTO by_phone FROM public.user_profiles WHERE mobile=phone FOR UPDATE;
  END IF;
  IF by_phone.id IS NOT NULL THEN
    -- An existing profile of this phone number that the identity is not linked
    -- to. The central service's word alone never opens it.
    IF by_phone.central_issuer IS NOT NULL OR by_phone.central_subject IS NOT NULL THEN
      RETURN jsonb_build_object('success',false,'code','identity_conflict');
    END IF;
    IF p_otp_code IS NULL THEN
      RETURN jsonb_build_object('success',false,'code','link_required');
    END IF;
    -- The local proof: a code this facility sent to that number, checked by
    -- the SMS sign-in itself with all its limits. Its answer is the answer:
    -- it has refused a rejected or disabled profile before issuing anything,
    -- and a success already carries the session (or the pending request).
    otp_answer := public.operator_verify_otp(phone,p_otp_code,NULL,NULL,p_ip_address);
    IF (otp_answer->>'success') IS DISTINCT FROM 'true' THEN
      RETURN otp_answer;
    END IF;
    UPDATE public.user_profiles SET central_issuer=p_issuer,central_subject=p_subject WHERE id=by_phone.id;
    RETURN otp_answer;
  END IF;
  IF profile.id IS NULL THEN
    IF NOT warehouse_security.enrollment_allowed(p_ip_address) THEN
      RETURN jsonb_build_object('success',false,'code','enrollment_limited');
    END IF;
    clean_name := COALESCE(warehouse_security.clean_person_name(p_name),'New customer');
    clean_display := COALESCE(warehouse_security.clean_person_name(p_display_name),clean_name);
    INSERT INTO public.user_profiles(auth_user_id,mobile,name,display_name,role,active,mobile_verified,mobile_verified_at,
      enrollment_status,central_issuer,central_subject)
    VALUES (gen_random_uuid(),phone,clean_name,clean_display,
      'customer',false,true,now(),'pending',p_issuer,p_subject) RETURNING * INTO profile;
    DELETE FROM warehouse_security.enrollment_log WHERE created_at<now()-interval '2 days';
    INSERT INTO warehouse_security.enrollment_log(ip_address) VALUES (p_ip_address);
  ELSIF profile.mobile = phone THEN
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
REVOKE ALL ON FUNCTION public.operator_central_exchange(text,text,text,text,timestamptz,text,text,inet,text) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.operator_central_exchange(text,text,text,text,timestamptz,text,text,inet,text) TO service_role;

-- ---------------------------------------------------------------------------
-- 4. Unlinking a profile
-- ---------------------------------------------------------------------------
-- The guard admits administrators and supervisors to everything it does not
-- name. Unlinking decides who may sign in as a profile, like enrollment
-- review, so it is an administrator's call.
DO $patch$ BEGIN PERFORM pg_temp.patch_rpc('warehouse_security.authorize_rpc(text,jsonb)',
  $m$  IF role_name IN ('admin','supervisor') THEN RETURN; END IF;
$m$, $r$  -- Central identity (migration 49): administrators only.
  IF rpc = 'clear_user_central_identity' THEN
    IF role_name <> 'admin' THEN RAISE EXCEPTION 'Administrator required' USING ERRCODE = '42501'; END IF;
    RETURN;
  END IF;
  IF role_name IN ('admin','supervisor') THEN RETURN; END IF;
$r$); END $patch$;

-- Clears the central identity of one profile and signs it out everywhere, as
-- update_user_status(false) does, without changing `active` or the enrollment
-- state. Linking the profile again, to this or another identity, needs a
-- correct SMS code of this facility like any first link. The identity that
-- was removed is unknown here afterwards: a token of it for another phone
-- number creates a new pending request for an administrator to judge.
CREATE FUNCTION public.clear_user_central_identity(p_user_id uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE target public.user_profiles;
BEGIN
  PERFORM warehouse_security.authorize_rpc('clear_user_central_identity', jsonb_build_object('p_user_id', p_user_id));
  -- The guard lets the service key through; this is a signed-in administrator's action.
  IF auth.jwt()->>'role' IS DISTINCT FROM 'authenticated' OR warehouse_security.active_role() IS DISTINCT FROM 'admin' THEN
    RAISE EXCEPTION 'Administrator required' USING ERRCODE='42501';
  END IF;
  IF p_user_id IS NULL THEN
    RETURN jsonb_build_object('success',false,'error','INVALID_INPUT','message','User ID is required');
  END IF;
  SELECT * INTO target FROM public.user_profiles WHERE id=p_user_id FOR UPDATE;
  IF target.id IS NULL THEN
    RETURN jsonb_build_object('success',false,'error','NOT_FOUND','message','User not found');
  END IF;
  UPDATE public.user_profiles SET central_issuer=NULL,central_subject=NULL,updated_at=now() WHERE id=p_user_id;
  DELETE FROM warehouse_security.refresh_sessions WHERE user_id=target.auth_user_id;
  RETURN jsonb_build_object('success',true,'user_id',p_user_id,
    'was_linked',target.central_subject IS NOT NULL,
    'message','Central sign-in link cleared; the user is signed out');
END $$;
-- The schema's default privileges would also give it to anon and service_role.
REVOKE ALL ON FUNCTION public.clear_user_central_identity(uuid) FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.clear_user_central_identity(uuid) TO authenticated;

-- ---------------------------------------------------------------------------
-- 5. Deleting the own account
-- ---------------------------------------------------------------------------
-- delete_user_account frees the phone number, so that the person can ask for
-- access again later. Without this the deleted profile would still be found
-- by its central identity and every later central sign-in refused.
DO $patch$ BEGIN PERFORM pg_temp.patch_rpc('public.delete_user_account()',
  $m$mobile_verified=false,mobile_verified_at=NULL
$m$, $r$mobile_verified=false,mobile_verified_at=NULL,
    central_issuer=NULL,central_subject=NULL
$r$); END $patch$;

DROP FUNCTION pg_temp.patch_rpc(regprocedure, text, text, integer);
NOTIFY pgrst, 'reload schema';
