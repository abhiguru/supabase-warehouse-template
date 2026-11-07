-- Migration 154 (WH-114): four sign-in access gaps.
--
--  1. operator_central_exchange (ten-argument form): with the facility's own code on (auth_config key central_local_code), a central
--     sign-in that finds an UNLINKED profile by phone number no longer links it first. The profile stays unlinked until a correct
--     facility code is given: without otp_code the answer is link_required (as for a linked profile), with one the code is checked by
--     operator_verify_otp, and the central identity is written to the profile only when that answer is a success (a session or a
--     pending-enrollment answer). A profile found by central subject, and a facility with the setting off, behave as before.
--  2. operator_verify_otp (six-argument form): a correct SMS code is marked used only once the account is known to be answerable. The
--     refusals (enrollment_limited for a new number when enrolment is limited, account_unavailable for a rejected, disabled or
--     deactivated profile) are now given before the code is spent, so the same code can be used again until it expires or its attempt
--     limit is reached. A code is spent when a session or an access-request (pending) answer is given. The wrong-guess counters and the
--     answers are unchanged.
--  3. operator_finish_otp, operator_sms_config, operator_enrollment_status, operator_enrollment_signout, operator_break_glass_open and
--     operator_review_enrollment answer like their siblings (operator_verify_otp, operator_prepare_otp) when the facility's auth_mode
--     is not 'operator': {success:false, code:'unavailable'} (operator_break_glass_open: false). Each refusal comes before anything is
--     read or written; operator_review_enrollment keeps its administrator check first.
--  4. clear_user_central_identity: the service role can call it (operator scripts). The function refused the service key in its body, so
--     the body lets the service role past the administrator check as authorize_rpc already does, and the grant is added. The
--     grant of authenticated stays; a signed-in caller still has to be an administrator.
--
-- Every change patches the function as stored: each marker must occur exactly once, and a function that already carries the WH-114 tag
-- is refused, so a second run fails instead of patching again. CREATE OR REPLACE keeps owner, search_path and grants.

CREATE FUNCTION pg_temp.patch_function(p_function regprocedure, p_old text[], p_new text[]) RETURNS void
    LANGUAGE plpgsql AS $$
DECLARE
  v_def text := pg_get_functiondef(p_function);
  v_count integer;
  i integer;
BEGIN
  IF array_length(p_old, 1) IS DISTINCT FROM array_length(p_new, 1) THEN
    RAISE EXCEPTION '%: the marker list and the replacement list differ in length', p_function;
  END IF;
  IF position('WH-114' IN v_def) > 0 THEN
    RAISE EXCEPTION '%: already patched by migration 154', p_function;
  END IF;
  FOR i IN 1 .. array_length(p_old, 1) LOOP
    v_count := (length(v_def) - length(replace(v_def, p_old[i], ''))) / length(p_old[i]);
    IF v_count <> 1 THEN
      RAISE EXCEPTION '%: expected marker % once, found % times', p_function, i, v_count;
    END IF;
    v_def := replace(v_def, p_old[i], p_new[i]);
  END LOOP;
  EXECUTE v_def;
END $$;

-- 1. operator_central_exchange: link only after the facility's code
SELECT pg_temp.patch_function('public.operator_central_exchange(text,text,text,text,timestamptz,text,text,inet,text,text)'::regprocedure,
ARRAY[
$m$  IF by_phone.id IS NOT NULL THEN
    UPDATE public.user_profiles SET central_issuer=p_issuer,central_subject=p_subject,$m$
],
ARRAY[
$m$  -- WH-114 (migration 154): with the facility's own code on, a profile found by phone number is not linked, and no pending answer
  -- is given, until a correct code of this facility is checked; the identity is written only on a success.
  IF by_phone.id IS NOT NULL
     AND COALESCE((SELECT value FROM warehouse_security.auth_config WHERE key='central_local_code'),'off') = 'on' THEN
    IF p_otp_code IS NULL THEN
      RETURN jsonb_build_object('success',false,'code','link_required');
    END IF;
    otp_answer := public.operator_verify_otp(by_phone.mobile,p_otp_code,NULL,NULL,p_ip_address,p_user_agent);
    IF (otp_answer->>'success') = 'true' AND jsonb_typeof(otp_answer #> '{data,user}') = 'object' THEN
      UPDATE public.user_profiles SET central_issuer=p_issuer,central_subject=p_subject,
        mobile_verified=true,mobile_verified_at=now(),updated_at=now()
        WHERE id=by_phone.id RETURNING * INTO profile;
      otp_answer := jsonb_set(otp_answer, '{data,user}',
        (otp_answer #> '{data,user}') || jsonb_build_object('central_issuer', profile.central_issuer, 'central_subject', profile.central_subject));
    END IF;
    RETURN otp_answer;
  END IF;
  IF by_phone.id IS NOT NULL THEN
    UPDATE public.user_profiles SET central_issuer=p_issuer,central_subject=p_subject,$m$
]);

-- 2. operator_verify_otp: the code is spent after the refusals
SELECT pg_temp.patch_function('public.operator_verify_otp(text,text,text,text,inet,text)'::regprocedure,
ARRAY[
$m$  UPDATE public.otp_verifications SET verified=true,verified_at=now(),otp_code_hash=NULL
    WHERE phone_number=phone AND NOT verified AND delivery_status='accepted';
  SELECT * INTO profile FROM public.user_profiles WHERE mobile=phone FOR UPDATE;
  IF profile.id IS NULL THEN
    IF NOT warehouse_security.enrollment_allowed(p_ip_address) THEN
      RETURN jsonb_build_object('success',false,'code','enrollment_limited');
    END IF;$m$
],
ARRAY[
$m$  -- WH-114 (migration 154): the account is looked at, and refused, before the code is spent.
  SELECT * INTO profile FROM public.user_profiles WHERE mobile=phone FOR UPDATE;
  IF profile.id IS NULL THEN
    IF NOT warehouse_security.enrollment_allowed(p_ip_address) THEN
      RETURN jsonb_build_object('success',false,'code','enrollment_limited');
    END IF;
  ELSIF profile.enrollment_status IN ('rejected','disabled') OR (NOT profile.active AND profile.enrollment_status<>'pending') THEN
    RETURN jsonb_build_object('success',false,'code','account_unavailable');
  END IF;
  UPDATE public.otp_verifications SET verified=true,verified_at=now(),otp_code_hash=NULL
    WHERE phone_number=phone AND NOT verified AND delivery_status='accepted';
  IF profile.id IS NULL THEN$m$
]);

-- 3. auth_mode checks
SELECT pg_temp.patch_function('public.operator_finish_otp(uuid,boolean,text,integer)'::regprocedure,
ARRAY[$m$  SELECT * INTO row_otp FROM public.otp_verifications WHERE id=p_request_id FOR UPDATE;$m$],
ARRAY[$m$  -- WH-114 (migration 154): SMS delivery belongs to the operator mode.
  IF COALESCE((SELECT value FROM warehouse_security.auth_config WHERE key='auth_mode'),'') <> 'operator' THEN
    RETURN jsonb_build_object('success',false,'code','unavailable');
  END IF;
  SELECT * INTO row_otp FROM public.otp_verifications WHERE id=p_request_id FOR UPDATE;$m$]);

SELECT pg_temp.patch_function('public.operator_sms_config()'::regprocedure,
ARRAY[$m$  SELECT * INTO config FROM public.sms_config ORDER BY id DESC LIMIT 1;$m$],
ARRAY[$m$  -- WH-114 (migration 154): the SMS provider settings are handed out in the operator mode only.
  IF COALESCE((SELECT value FROM warehouse_security.auth_config WHERE key='auth_mode'),'') <> 'operator' THEN
    RETURN jsonb_build_object('success',false,'code','unavailable');
  END IF;
  SELECT * INTO config FROM public.sms_config ORDER BY id DESC LIMIT 1;$m$]);

SELECT pg_temp.patch_function('public.operator_enrollment_status(text)'::regprocedure,
ARRAY[$m$  IF p_token IS NULL OR p_token !~ '^[0-9a-f]{64}$' THEN RETURN jsonb_build_object('success',false,'code','invalid_token'); END IF;$m$],
ARRAY[$m$  -- WH-114 (migration 154): enrolment tokens belong to the operator mode.
  IF COALESCE((SELECT value FROM warehouse_security.auth_config WHERE key='auth_mode'),'') <> 'operator' THEN
    RETURN jsonb_build_object('success',false,'code','unavailable');
  END IF;
  IF p_token IS NULL OR p_token !~ '^[0-9a-f]{64}$' THEN RETURN jsonb_build_object('success',false,'code','invalid_token'); END IF;$m$]);

SELECT pg_temp.patch_function('public.operator_enrollment_signout(text)'::regprocedure,
ARRAY[$m$  IF p_token ~ '^[0-9a-f]{64}$' THEN$m$],
ARRAY[$m$  -- WH-114 (migration 154): enrolment tokens belong to the operator mode.
  IF COALESCE((SELECT value FROM warehouse_security.auth_config WHERE key='auth_mode'),'') <> 'operator' THEN
    RETURN jsonb_build_object('success',false,'code','unavailable');
  END IF;
  IF p_token ~ '^[0-9a-f]{64}$' THEN$m$]);

SELECT pg_temp.patch_function('public.operator_break_glass_open(text)'::regprocedure,
ARRAY[$m$WHERE b.phone_number=warehouse_security.normalize_phone(p_phone_number)$m$],
ARRAY[$m$WHERE COALESCE((SELECT c.value FROM warehouse_security.auth_config c WHERE c.key='auth_mode'),'') = 'operator' /* WH-114 (migration 154) */
      AND b.phone_number=warehouse_security.normalize_phone(p_phone_number)$m$]);

SELECT pg_temp.patch_function('public.operator_review_enrollment(uuid,text,uuid[],text)'::regprocedure,
ARRAY[$m$  SELECT id INTO admin_id FROM public.user_profiles WHERE auth_user_id=auth.uid();$m$],
ARRAY[$m$  -- WH-114 (migration 154): enrolment review belongs to the operator mode (the administrator check above comes first).
  IF COALESCE((SELECT value FROM warehouse_security.auth_config WHERE key='auth_mode'),'') <> 'operator' THEN
    RETURN jsonb_build_object('success',false,'code','unavailable');
  END IF;
  SELECT id INTO admin_id FROM public.user_profiles WHERE auth_user_id=auth.uid();$m$]);

-- 4. clear_user_central_identity for the service role
SELECT pg_temp.patch_function('public.clear_user_central_identity(uuid)'::regprocedure,
ARRAY[$m$  IF auth.jwt()->>'role' IS DISTINCT FROM 'authenticated' OR warehouse_security.active_role() IS DISTINCT FROM 'admin' THEN$m$],
ARRAY[$m$  -- WH-114 (migration 154): the service role (an operator script) may clear a link; a signed-in caller must be an administrator.
  IF auth.jwt()->>'role' IS DISTINCT FROM 'service_role'
     AND (auth.jwt()->>'role' IS DISTINCT FROM 'authenticated' OR warehouse_security.active_role() IS DISTINCT FROM 'admin') THEN$m$]);
GRANT EXECUTE ON FUNCTION public.clear_user_central_identity(uuid) TO service_role;
