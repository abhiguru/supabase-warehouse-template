-- Migration 96: a refused central exchange writes nothing to the profile (TW-BE-017).
--
-- Migration 81 decided that a refusal writes nothing: a rejected, disabled or deactivated profile is answered
-- account_unavailable and is neither linked nor marked verified. It moved the link (step 5) behind the refusal, but a
-- profile found by (issuer, subject) whose mobile equals the token's phone still got the verified mark
-- (mobile_verified, mobile_verified_at, hence updated_at and an audit_user_profiles row) BEFORE the refusal check.
-- So a refused sign-in changed the row it refused.
--
-- operator_central_exchange: the early `ELSIF profile.mobile = phone AND by_phone.id IS NULL THEN UPDATE ...` branch is
-- removed. A boolean created_now (set where the pending profile is inserted, which is already inserted verified) keeps
-- a profile created by this very call from being updated again. The verified mark runs after the refusal checks, as
-- the ELSIF of the link of step 5: found by phone -> link and mark; found by subject with the same mobile and not
-- created now -> mark. Nothing else moves: who is opened, linking, the service-account guard, identity_conflict, the
-- single-use token row (replay protection, deliberately written before any decision) and every answer stay as
-- migration 81 made them.
--
-- operator_verify_otp (the SMS path, which docs/CLAUDE.md say must answer like the central one) had the same order:
-- its ELSE branch marked the found profile verified before the refusal. It gets the same move: the mark follows the
-- refusal check and skips a profile created by the call. Its answers are unchanged. (A correct code is still consumed,
-- as before: that row is replay protection.)
--
-- Each function keeps owner, SECURITY DEFINER, search_path and grants, checked below.

CREATE FUNCTION pg_temp.patch_once_96(fn regprocedure, marker text, replacement text) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE definition text := pg_get_functiondef(fn); n integer;
BEGIN
  n := (length(definition)-length(replace(definition,marker,'')))/length(marker);
  IF n <> 1 THEN RAISE EXCEPTION 'Expected one marker in %, found %: %', fn, n, left(marker,80); END IF;
  EXECUTE replace(definition,marker,replacement);
END $$;

DO $patch$
DECLARE
  ex regprocedure := 'public.operator_central_exchange(text,text,text,text,timestamptz,text,text,inet,text)'::regprocedure;
  vo regprocedure := 'public.operator_verify_otp(text,text,text,text,inet)'::regprocedure;
  b record; a record; d text;
BEGIN
  CREATE TEMP TABLE m96_before ON COMMIT DROP AS
    SELECT p.oid AS fn, p.proowner, p.prosecdef, p.proconfig, p.proacl FROM pg_proc p WHERE p.oid IN (ex, vo);

  -- operator_central_exchange
  PERFORM pg_temp.patch_once_96(ex,
    $m$  clean_name text; clean_display text;
BEGIN$m$,
    $r$  clean_name text; clean_display text; created_now boolean := false;
BEGIN$r$);
  PERFORM pg_temp.patch_once_96(ex,
    $m$    INSERT INTO warehouse_security.enrollment_log(ip_address) VALUES (p_ip_address);
  ELSIF profile.mobile = phone AND by_phone.id IS NULL THEN
    UPDATE public.user_profiles SET mobile_verified=true,mobile_verified_at=now() WHERE id=profile.id RETURNING * INTO profile;
  END IF;$m$,
    $r$    INSERT INTO warehouse_security.enrollment_log(ip_address) VALUES (p_ip_address);
    created_now := true;
  END IF;$r$);
  PERFORM pg_temp.patch_once_96(ex,
    $m$      WHERE id=by_phone.id RETURNING * INTO profile;
  END IF;$m$,
    $r$      WHERE id=by_phone.id RETURNING * INTO profile;
  ELSIF profile.mobile = phone AND NOT created_now THEN
    -- Migration 96: the verified mark of a profile found by subject follows the refusal checks above.
    UPDATE public.user_profiles SET mobile_verified=true,mobile_verified_at=now() WHERE id=profile.id RETURNING * INTO profile;
  END IF;$r$);

  -- operator_verify_otp
  PERFORM pg_temp.patch_once_96(vo,
    $m$  candidates uuid[]; clean_name text; clean_display text;
BEGIN$m$,
    $r$  candidates uuid[]; clean_name text; clean_display text; created_now boolean := false;
BEGIN$r$);
  PERFORM pg_temp.patch_once_96(vo,
    $m$    INSERT INTO warehouse_security.enrollment_log(ip_address) VALUES (p_ip_address);
  ELSE
    UPDATE public.user_profiles SET mobile_verified=true,mobile_verified_at=now() WHERE id=profile.id RETURNING * INTO profile;
  END IF;
  IF profile.enrollment_status IN ('rejected','disabled') OR (NOT profile.active AND profile.enrollment_status<>'pending') THEN
    RETURN jsonb_build_object('success',false,'code','account_unavailable');
  END IF;$m$,
    $r$    INSERT INTO warehouse_security.enrollment_log(ip_address) VALUES (p_ip_address);
    created_now := true;
  END IF;
  IF profile.enrollment_status IN ('rejected','disabled') OR (NOT profile.active AND profile.enrollment_status<>'pending') THEN
    RETURN jsonb_build_object('success',false,'code','account_unavailable');
  END IF;
  IF NOT created_now THEN
    -- Migration 96: the verified mark follows the refusal check.
    UPDATE public.user_profiles SET mobile_verified=true,mobile_verified_at=now() WHERE id=profile.id RETURNING * INTO profile;
  END IF;$r$);

  FOR b IN SELECT * FROM m96_before LOOP
    SELECT p.proowner, p.prosecdef, p.proconfig, p.proacl INTO STRICT a FROM pg_proc p WHERE p.oid = b.fn;
    IF NOT a.prosecdef OR a.proowner IS DISTINCT FROM b.proowner OR a.proconfig IS DISTINCT FROM b.proconfig
       OR a.proacl IS DISTINCT FROM b.proacl THEN
      RAISE EXCEPTION '% lost its owner, SECURITY DEFINER, search_path or grants', b.fn::regprocedure;
    END IF;
  END LOOP;
  d := pg_get_functiondef(ex);
  IF position('central_local_code' IN d) = 0 OR position('by_phone.is_service_account' IN d) = 0
     OR position('created_now := true' IN d) = 0 OR position('AND by_phone.id IS NULL THEN' IN d) > 0 THEN
    RAISE EXCEPTION 'operator_central_exchange was not patched as expected';
  END IF;
END $patch$;

DROP FUNCTION pg_temp.patch_once_96(regprocedure, text, text);
NOTIFY pgrst, 'reload schema';
