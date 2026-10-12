-- The answer of a central-login link names the link it made.
--
-- operator_central_exchange (migration 49) links an existing profile that has no central
-- identity yet only together with a correct SMS code of this facility. It asks
-- operator_verify_otp to check the code, and on success it writes central_issuer and
-- central_subject to the profile and returns operator_verify_otp's answer. That answer was
-- built before the link was written, so its data.user still had central_issuer and
-- central_subject empty (login answer) or did not have them at all (pending answer), while
-- the stored profile was already linked. A client that kept the first answer's user had stale
-- link fields until it read the profile again (external review 2026-10-12, finding R8).
--
-- After the link is written, the two fields are now set in data.user of the answer:
-- - login answer: data.user is to_jsonb of the profile, whose two link keys were null; they
--   take the linked values, so data.user equals the stored profile (the updated_at trigger
--   uses the transaction's time, which operator_verify_otp's own update already wrote);
-- - pending answer: data.user is the short pending shape; the two keys are added and nothing
--   else, so it does not become a full profile.
-- The rest of the answer (success, action, session or enrollment token) is unchanged, and a
-- refusal is still returned before anything is linked. Migration 49 is applied on running
-- installations and is not edited; the function is patched in place, with its owner, grants,
-- SECURITY DEFINER and search_path kept, and checked below.
DO $patch$
DECLARE fn regprocedure; definition text; marker text; replacement text; occurrences integer;
  before_secdef boolean; before_acl aclitem[]; before_config text[];
  after_secdef boolean; after_acl aclitem[]; after_config text[];
BEGIN
  fn := 'public.operator_central_exchange(text,text,text,text,timestamptz,text,text,inet,text)'::regprocedure;
  SELECT prosecdef, proacl, proconfig INTO STRICT before_secdef, before_acl, before_config
    FROM pg_proc WHERE oid=fn;
  definition := pg_get_functiondef(fn);
  marker := $m$    UPDATE public.user_profiles SET central_issuer=p_issuer,central_subject=p_subject WHERE id=by_phone.id;
    RETURN otp_answer;$m$;
  replacement := $r$    UPDATE public.user_profiles SET central_issuer=p_issuer,central_subject=p_subject WHERE id=by_phone.id;
    IF jsonb_typeof(otp_answer #> '{data,user}') = 'object' THEN
      otp_answer := jsonb_set(otp_answer, '{data,user}',
        (otp_answer #> '{data,user}') || jsonb_build_object('central_issuer', p_issuer, 'central_subject', p_subject));
    END IF;
    RETURN otp_answer;$r$;
  occurrences := (length(definition)-length(replace(definition,marker,'')))/length(marker);
  IF occurrences <> 1 THEN
    RAISE EXCEPTION 'Expected one link marker in operator_central_exchange, found %', occurrences;
  END IF;
  EXECUTE replace(definition,marker,replacement);

  SELECT prosecdef, proacl, proconfig INTO STRICT after_secdef, after_acl, after_config
    FROM pg_proc WHERE oid=fn;
  IF NOT after_secdef OR after_secdef IS DISTINCT FROM before_secdef THEN
    RAISE EXCEPTION 'operator_central_exchange is no longer SECURITY DEFINER';
  END IF;
  IF after_acl IS DISTINCT FROM before_acl THEN
    RAISE EXCEPTION 'operator_central_exchange grants changed: % became %', before_acl, after_acl;
  END IF;
  IF after_config IS DISTINCT FROM before_config THEN
    RAISE EXCEPTION 'operator_central_exchange settings changed: % became %', before_config, after_config;
  END IF;
  IF position('jsonb_build_object(''central_issuer'', p_issuer' IN pg_get_functiondef(fn)) = 0 THEN
    RAISE EXCEPTION 'operator_central_exchange was not patched';
  END IF;
END $patch$;
NOTIFY pgrst, 'reload schema';
