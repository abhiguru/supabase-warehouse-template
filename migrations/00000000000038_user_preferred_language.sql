-- The language a person chose in the app is kept on their profile, so a new phone or a
-- fresh install starts in it.
--
--   * user_profiles.preferred_language: 'en', 'gu' or NULL (no choice: the app follows the
--     phone). The server does not use it; all server text stays English.
--   * set_my_language(p_language) stores the caller's own choice; NULL clears it.
--   * get_my_language() returns it.
--
-- Both are new, so an app that does not know them is unaffected, and an app that calls them
-- on an older installation gets "function not found", which it ignores.
ALTER TABLE public.user_profiles ADD COLUMN preferred_language text;
ALTER TABLE public.user_profiles ADD CONSTRAINT user_profiles_preferred_language_known
  CHECK (preferred_language IS NULL OR preferred_language IN ('en', 'gu'));

-- The caller's own profile, for a session that is still valid. An account waiting for
-- approval may also keep a language.
CREATE FUNCTION warehouse_security.own_profile_id() RETURNS uuid
LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'pg_catalog' AS $function$
  SELECT p.id FROM public.user_profiles p WHERE p.auth_user_id = auth.uid() AND p.active
    AND EXISTS (SELECT 1 FROM warehouse_security.refresh_sessions s
      WHERE s.user_id = p.auth_user_id AND s.id::text = auth.jwt()->>'session_id' AND s.expires_at > now());
$function$;
REVOKE ALL ON FUNCTION warehouse_security.own_profile_id() FROM PUBLIC, anon, authenticated;

CREATE FUNCTION public.set_my_language(p_language text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'pg_catalog' AS $function$
DECLARE
  profile uuid := warehouse_security.own_profile_id();
BEGIN
  IF profile IS NULL THEN
    RAISE EXCEPTION 'Active account required' USING ERRCODE = '42501';
  END IF;
  IF p_language IS NOT NULL AND p_language NOT IN ('en', 'gu') THEN
    RETURN jsonb_build_object('success', false, 'error', 'Unknown language', 'code', 'UNKNOWN_LANGUAGE');
  END IF;
  UPDATE public.user_profiles SET preferred_language = p_language
    WHERE id = profile AND preferred_language IS DISTINCT FROM p_language;
  RETURN jsonb_build_object('success', true, 'language', p_language);
END;
$function$;

CREATE FUNCTION public.get_my_language() RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'pg_catalog' AS $function$
DECLARE
  profile uuid := warehouse_security.own_profile_id();
BEGIN
  IF profile IS NULL THEN
    RAISE EXCEPTION 'Active account required' USING ERRCODE = '42501';
  END IF;
  RETURN jsonb_build_object('success', true, 'language',
    (SELECT p.preferred_language FROM public.user_profiles p WHERE p.id = profile));
END;
$function$;

REVOKE ALL ON FUNCTION public.set_my_language(text), public.get_my_language() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.set_my_language(text), public.get_my_language() TO authenticated, service_role;
