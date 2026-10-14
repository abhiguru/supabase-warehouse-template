-- Migration 81: one association sign-in for every facility; a facility's own code only when it asks.
--
-- Owner decision of 2026-10-15. Before this migration operator_central_exchange (migration 49,
-- link reply added by 64) opened an existing profile that had no central identity yet only
-- together with a correct SMS code of this facility, and answered link_required without one.
-- The association sends the only sign-in code now. The rule is:
--   * The central token opens an existing PERSON profile of this facility: matched by the
--     central-verified mobile the first time (the profile is then linked to the identity), by
--     central subject afterwards. Accepted consequence: whoever controls the central service
--     (or a number's SMS there) can open any profile with that number at a facility that leaves
--     the extra code off, administrators included.
--   * A profile marked is_service_account (migration 78) is never opened this way:
--     account_unavailable, and it is not linked.
--   * A facility may switch on its own extra code (warehouse_security.auth_config key
--     central_local_code = 'on', written by scripts/configure-central.sql, default off). Then
--     every exchange that would issue a facility session for an approved profile, linked or not,
--     answers link_required without p_otp_code, and with it calls operator_verify_otp (all its
--     limits) and returns its answer, which issues the session. It asks at every new sign-in.
--   * Unchanged: a new person files a pending access request that an administrator approves (no
--     code); an identity already linked to another profile of the number is identity_conflict;
--     rejected, disabled and deactivated profiles are account_unavailable; revocation stays local.
-- Decision order after the issuer, argument and single-use checks:
--   1. find the profile by (issuer, subject), else by mobile = phone
--   2. found by mobile and linked to another identity: identity_conflict
--   3. service account: account_unavailable
--   4. no profile: pending insert (enrollment token), no code
--   5. found by mobile, not linked: link it (central_issuer, central_subject) -- but only after
--      step 6 below has let it through; the order of the code is 1, 2, 3, 4, 6, 5, 7, 8
--   6. rejected, disabled or deactivated: account_unavailable; a refusal writes nothing, so such a
--      profile is not linked (and not marked verified)
--   7. pending: enrollment token
--   8. approved: central_local_code on -> link_required / operator_verify_otp; off -> session
-- The link of step 5 is written for every profile that is not refused; with the setting on, step 8's code still guards
-- every session. The code is checked for the profile's own mobile (the facility's record of the
-- number), so a token whose phone differs from a profile found by subject cannot create or open
-- another profile through operator_verify_otp.
-- Migrations 49 and 64 are applied and not edited; the function is patched in place, with its
-- owner, grants, SECURITY DEFINER and search_path kept, and checked below.

-- Replaces the text from one marker to another (both included, each exactly once).
CREATE FUNCTION pg_temp.patch_between(fn regprocedure, first_marker text, last_marker text, replacement text) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE definition text := pg_get_functiondef(fn); first_at integer; last_at integer; n integer;
BEGIN
  n := (length(definition)-length(replace(definition,first_marker,'')))/length(first_marker);
  IF n <> 1 THEN RAISE EXCEPTION 'Expected one start marker in %, found %', fn, n; END IF;
  n := (length(definition)-length(replace(definition,last_marker,'')))/length(last_marker);
  IF n <> 1 THEN RAISE EXCEPTION 'Expected one end marker in %, found %', fn, n; END IF;
  first_at := position(first_marker IN definition);
  last_at := position(last_marker IN definition);
  IF last_at < first_at THEN RAISE EXCEPTION 'Markers out of order in %', fn; END IF;
  EXECUTE substr(definition,1,first_at-1) || replacement || substr(definition,last_at+length(last_marker));
END $$;

CREATE FUNCTION pg_temp.patch_once(fn regprocedure, marker text, replacement text) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE definition text := pg_get_functiondef(fn); n integer;
BEGIN
  n := (length(definition)-length(replace(definition,marker,'')))/length(marker);
  IF n <> 1 THEN RAISE EXCEPTION 'Expected one marker in %, found %: %', fn, n, left(marker,80); END IF;
  EXECUTE replace(definition,marker,replacement);
END $$;

DO $patch$
DECLARE fn regprocedure;
  before_secdef boolean; before_acl aclitem[]; before_config text[];
  after_secdef boolean; after_acl aclitem[]; after_config text[];
  def text;
BEGIN
  fn := 'public.operator_central_exchange(text,text,text,text,timestamptz,text,text,inet,text)'::regprocedure;
  SELECT prosecdef, proacl, proconfig INTO STRICT before_secdef, before_acl, before_config FROM pg_proc WHERE oid=fn;

  -- Steps 2, 3 and 5: the phone's profile is linked by the token's word; the local-code and
  -- link_required handling that stood here moves to step 8.
  PERFORM pg_temp.patch_between(fn,
    $m$  IF by_phone.id IS NOT NULL THEN$m$,
    $m$    RETURN otp_answer;
  END IF;$m$,
    $r$  IF by_phone.id IS NOT NULL THEN
    -- 2. The phone's profile belongs to another central identity.
    IF by_phone.central_issuer IS NOT NULL OR by_phone.central_subject IS NOT NULL THEN
      RETURN jsonb_build_object('success',false,'code','identity_conflict');
    END IF;
    -- 3. A machine account is never opened by a central token, and is not linked.
    IF by_phone.is_service_account THEN
      RETURN jsonb_build_object('success',false,'code','account_unavailable');
    END IF;
    -- The profile is used as found; it is linked at step 5 below, only once it is known not to be
    -- refused (a refusal writes nothing).
    profile := by_phone;
  END IF;$r$);

  -- Step 1 of the tail: a profile found by phone is not touched here (no verified mark) until step 5.
  PERFORM pg_temp.patch_once(fn,
    $m$  ELSIF profile.mobile = phone THEN$m$,
    $r$  ELSIF profile.mobile = phone AND by_phone.id IS NULL THEN$r$);

  -- 3 for a profile found by subject (the new-profile and phone cases are decided above).
  PERFORM pg_temp.patch_once(fn,
    $m$  IF profile.enrollment_status IN ('rejected','disabled') OR (NOT profile.active AND profile.enrollment_status<>'pending') THEN$m$,
    $r$  IF profile.is_service_account THEN
    RETURN jsonb_build_object('success',false,'code','account_unavailable');
  END IF;
  IF profile.enrollment_status IN ('rejected','disabled') OR (NOT profile.active AND profile.enrollment_status<>'pending') THEN$r$);

  -- 5. After the refusals (service account, rejected, disabled, inactive): the central-verified
  -- mobile identifies the person, so the profile found by phone is linked and marked verified. Only a
  -- profile that answers pending or goes on to a session (or the own-code question) is written.
  PERFORM pg_temp.patch_once(fn,
    $m$  IF profile.enrollment_status='pending' THEN$m$,
    $r$  IF by_phone.id IS NOT NULL THEN
    UPDATE public.user_profiles SET central_issuer=p_issuer,central_subject=p_subject,
      mobile_verified=true,mobile_verified_at=now(),updated_at=now()
      WHERE id=by_phone.id RETURNING * INTO profile;
  END IF;
  IF profile.enrollment_status='pending' THEN$r$);

  -- 7. A pending answer names the link, as migration 64 made the link answer do: the profile may
  -- have been linked by this very exchange (step 5), and the two keys are the only addition.
  PERFORM pg_temp.patch_once(fn,
    $m$'mobile',profile.mobile,'role',profile.role,'active',false,'enrollment_status','pending')));$m$,
    $r$'mobile',profile.mobile,'role',profile.role,'active',false,'enrollment_status','pending',
      'central_issuer',profile.central_issuer,'central_subject',profile.central_subject)));$r$);

  -- 8. The facility's own code, when it asks for one.
  PERFORM pg_temp.patch_once(fn,
    $m$  session_data:=warehouse_security.issue_session(profile.auth_user_id);$m$,
    $r$  IF COALESCE((SELECT value FROM warehouse_security.auth_config WHERE key='central_local_code'),'off') = 'on' THEN
    IF p_otp_code IS NULL THEN
      RETURN jsonb_build_object('success',false,'code','link_required');
    END IF;
    -- A code this facility sent to the profile's number, checked by the SMS sign-in itself with
    -- all its limits. Its answer is the answer and, on success, already carries the session.
    otp_answer := public.operator_verify_otp(profile.mobile,p_otp_code,NULL,NULL,p_ip_address);
    IF (otp_answer->>'success') = 'true' AND jsonb_typeof(otp_answer #> '{data,user}') = 'object' THEN
      otp_answer := jsonb_set(otp_answer, '{data,user}',
        (otp_answer #> '{data,user}') || jsonb_build_object('central_issuer', profile.central_issuer, 'central_subject', profile.central_subject));
    END IF;
    RETURN otp_answer;
  END IF;
  session_data:=warehouse_security.issue_session(profile.auth_user_id);$r$);

  SELECT prosecdef, proacl, proconfig INTO STRICT after_secdef, after_acl, after_config FROM pg_proc WHERE oid=fn;
  IF NOT after_secdef OR after_secdef IS DISTINCT FROM before_secdef THEN
    RAISE EXCEPTION 'operator_central_exchange is no longer SECURITY DEFINER';
  END IF;
  IF after_acl IS DISTINCT FROM before_acl THEN
    RAISE EXCEPTION 'operator_central_exchange grants changed: % became %', before_acl, after_acl;
  END IF;
  IF after_config IS DISTINCT FROM before_config THEN
    RAISE EXCEPTION 'operator_central_exchange settings changed: % became %', before_config, after_config;
  END IF;
  def := pg_get_functiondef(fn);
  IF position('central_local_code' IN def) = 0 OR position('by_phone.is_service_account' IN def) = 0
     OR position('IF p_otp_code IS NULL THEN
      RETURN jsonb_build_object(''success'',false,''code'',''link_required'');
    END IF;
    -- The local proof' IN def) > 0 THEN
    RAISE EXCEPTION 'operator_central_exchange was not patched';
  END IF;
END $patch$;

COMMENT ON FUNCTION public.operator_central_exchange(text,text,text,text,timestamptz,text,text,inet,text) IS
  'Central sign-in (migration 81): the token opens an existing person profile (linked by the verified mobile the first time, by subject afterwards); a service account is account_unavailable; a new person files a pending request; with auth_config central_local_code=on an approved profile also needs this facility''s own SMS code at every sign-in (link_required without it, operator_verify_otp with it).';
NOTIFY pgrst, 'reload schema';
