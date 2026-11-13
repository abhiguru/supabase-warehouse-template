-- Migration 199 (WH-140): the facility's legal settings, served to the app with the public configuration.
--
-- The app's terms and privacy pages are a template in which the facility is the only party (docs/PRIVACY_FOR_OPERATORS.md). They need six
-- values of the facility: the legal name (defaults to the company name), the city and state of its seat for disputes, and a grievance
-- officer (name, email, phone). They are keys of ONE settings row, public.system_settings key 'facility_legal', a JSON object that
-- migration 173 (WH-151) made for the GST details; a key that is missing or empty means "not given". Keys: legalName, city, state,
-- grievanceName, grievanceEmail, grievancePhone. legalName is the same key set_gst_details writes; every other key of the row (the GST
-- details) is kept as it is. (This migration was numbered 167 when written; it ships as 199, after 198.)
--  * warehouse_security.facility_legal() reads the row as one object with all six keys as text (legalName falls back to the app_name
--    setting, which setup.sh sets to the company).
--  * warehouse_security.apply_facility_legal(jsonb, uuid) checks and stores the keys given (a key not given is left alone, an empty
--    string clears it) and, when something changed, writes an audit_log row (table_name 'facility_legal', action 'UPDATED', old and
--    new values, the profile that changed it; NULL for setup.sh). setup.sh --legal-name, --legal-city, --legal-state, --grievance-name,
--    --grievance-email and --grievance-phone use it.
--  * public.set_facility_legal(jsonb) is the same for an administrator in the app (administrators only; the check is in the body, and
--    authorize_rpc names the RPC in migrations/definitions/00_authorize_rpc.sql).
--  * get_public_config(text) gains a "legal" object (the same six values), so the app reads them without signing in. They are public by
--    purpose: they are printed in the terms and the privacy notice. get-public-config passes the object on as "legal". The function is
--    re-created from its latest definition (migration 172, which added record_payments) with only the "legal" key added.
--
-- No role is created, altered or dropped. No table, column or grant change on an existing object (CREATE OR REPLACE keeps
-- get_public_config's owner and grants); no pg_temp helper.

INSERT INTO public.system_settings (key, value, description) VALUES
  ('facility_legal', '{}', 'The facility''s legal and GST details (JSON; migrations 173 and 199)')
ON CONFLICT (key) DO NOTHING;

CREATE FUNCTION warehouse_security.facility_legal() RETURNS jsonb
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'pg_temp'
    AS $$
  WITH s AS (
    SELECT COALESCE((SELECT CASE WHEN value ~ '^\s*\{' THEN value::jsonb END FROM public.system_settings WHERE key = 'facility_legal'), '{}'::jsonb) AS j,
           COALESCE((SELECT btrim(value) FROM public.system_settings WHERE key = 'app_name'), '') AS company)
  SELECT jsonb_build_object(
    'legalName', COALESCE(NULLIF(btrim(j->>'legalName'), ''), company),
    'city', COALESCE(btrim(j->>'city'), ''),
    'state', COALESCE(btrim(j->>'state'), ''),
    'grievanceName', COALESCE(btrim(j->>'grievanceName'), ''),
    'grievanceEmail', COALESCE(btrim(j->>'grievanceEmail'), ''),
    'grievancePhone', COALESCE(btrim(j->>'grievancePhone'), ''))
  FROM s
$$;
ALTER FUNCTION warehouse_security.facility_legal() OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION warehouse_security.facility_legal() FROM PUBLIC, anon, authenticated, service_role;

CREATE FUNCTION warehouse_security.apply_facility_legal(p_values jsonb, p_profile uuid DEFAULT NULL) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'pg_temp'
    AS $$
DECLARE
  v_names constant text[] := ARRAY['legalName', 'city', 'state', 'grievanceName', 'grievanceEmail', 'grievancePhone'];
  v_label constant text[] := ARRAY['Legal name', 'City', 'State', 'Grievance officer''s name', 'Grievance email', 'Grievance phone'];
  v_name text;
  v_value text;
  v_old jsonb;
  v_new jsonb;
  v_stored jsonb;
  i integer;
BEGIN
  IF p_values IS NULL OR jsonb_typeof(p_values) <> 'object' THEN
    RAISE EXCEPTION 'Legal settings must be an object' USING ERRCODE = '22023';
  END IF;
  FOR v_name IN SELECT jsonb_object_keys(p_values) LOOP
    IF v_name <> ALL (v_names) THEN
      RAISE EXCEPTION 'Unknown legal setting: %', left(v_name, 40) USING ERRCODE = '22023';
    END IF;
  END LOOP;
  SELECT COALESCE((SELECT CASE WHEN value ~ '^\s*\{' THEN value::jsonb END FROM public.system_settings WHERE key = 'facility_legal' FOR UPDATE), '{}'::jsonb) INTO v_stored;
  v_old := warehouse_security.facility_legal();
  v_new := v_stored;
  -- Check every value first, so a refused value changes nothing.
  FOR i IN 1 .. cardinality(v_names) LOOP
    CONTINUE WHEN NOT p_values ? v_names[i];
    IF jsonb_typeof(p_values -> v_names[i]) <> 'string' THEN
      RAISE EXCEPTION '% must be text', v_label[i] USING ERRCODE = '22023';
    END IF;
    v_value := btrim(p_values ->> v_names[i]);
    IF char_length(v_value) > 120 OR v_value ~ '[\x01-\x1f\x7f-\x9f\u2028\u2029]' THEN
      RAISE EXCEPTION '% must be printable text of at most 120 characters', v_label[i] USING ERRCODE = '22023';
    END IF;
    IF v_names[i] = 'grievanceEmail' AND v_value <> '' AND v_value !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' THEN
      RAISE EXCEPTION 'Grievance email must be an email address' USING ERRCODE = '22023';
    END IF;
    IF v_names[i] = 'grievancePhone' AND v_value <> '' AND v_value !~ '^[0-9+() -]{5,20}$' THEN
      RAISE EXCEPTION 'Grievance phone must be 5 to 20 digits, spaces, + ( ) or -' USING ERRCODE = '22023';
    END IF;
    IF v_value = '' THEN v_new := v_new - v_names[i]; ELSE v_new := v_new || jsonb_build_object(v_names[i], v_value); END IF;
  END LOOP;
  IF v_new IS DISTINCT FROM v_stored THEN
    INSERT INTO public.system_settings (key, value) VALUES ('facility_legal', v_new::text)
    ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = now();
    INSERT INTO public.audit_log (table_name, action, user_id, old_data, new_data)
    VALUES ('facility_legal', 'UPDATED', p_profile, v_old, warehouse_security.facility_legal());
  END IF;
  RETURN warehouse_security.facility_legal();
END $$;
ALTER FUNCTION warehouse_security.apply_facility_legal(jsonb, uuid) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION warehouse_security.apply_facility_legal(jsonb, uuid) FROM PUBLIC, anon, authenticated, service_role;

CREATE FUNCTION public.set_facility_legal(p_values jsonb) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'pg_temp'
    AS $$
BEGIN
  PERFORM warehouse_security.authorize_rpc('set_facility_legal', jsonb_build_object());
  -- Like set_document_numbering: the body does not depend on the definition file having been applied yet.
  IF warehouse_security.active_role() IS DISTINCT FROM 'admin' AND auth.jwt()->>'role' IS DISTINCT FROM 'service_role' THEN
    RAISE EXCEPTION 'Administrator required' USING ERRCODE = '42501';
  END IF;
  RETURN warehouse_security.apply_facility_legal(p_values, public.get_current_user_profile_id());
END $$;
ALTER FUNCTION public.set_facility_legal(jsonb) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION public.set_facility_legal(jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.set_facility_legal(jsonb) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.get_public_config(p_environment text) RETURNS json
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'pg_temp'
    AS $$
  SELECT json_build_object(
    'app_version', c.app_version,
    'maintenance_mode', c.maintenance_mode,
    'feature_flags', COALESCE((SELECT json_object_agg(f.name, f.enabled) FROM public.feature_flags f), '{}'::json),
    'record_payments', COALESCE((SELECT r.record_payments FROM warehouse_security.charging_rule r WHERE r.id), false),
    'legal', warehouse_security.facility_legal())
  FROM public.api_configurations c
  WHERE c.environment = p_environment AND c.is_active
$$;
