-- Migration 206 (WH-205): no new bill until the facility's GST details are saved with a GSTIN.
--
-- One shared rule, warehouse_security.bills_allowed(): true exactly when the GST details are saved, registered and hold a valid GSTIN. A
-- facility that never saved them, or saved them as not registered, may not make a bill. gst_settings()->'saved' keeps its meaning, so
-- every reader of it (documents, statements, dues, the accountant pack, apply_invoice_gst) and every edit of an existing bill is unchanged.
--
-- One gate, at the only place a new bill row is written: public.save_invoice_internal (called only by public.save_invoice; the second
-- document of a two-document save is written inside it by apply_invoice_gst). Its first statement after the INVOICE_CANCELLED check refuses
-- with GST_DETAILS_REQUIRED (the usual refusal shape, WH409). save_invoice answers a resend of a bill saved before from its request code
-- first, so that answer is unchanged; the refusal comes before the number check, NUMBER_TAKEN, claim_invoice_lines and every write, so
-- nothing is written and no number is used (numbers are never reserved). Not gated: update_invoice, cancel, delete, print and PDF reads,
-- preview_invoice_documents (read-only), and import_history (bills imported from an old system keep their figures as issued). A dispatch
-- still saves: only its bill is refused.
--
-- public.can_make_bills() (administrators, supervisors and staff; customers refused) answers {success, data: {allowed}}, nothing about
-- the details themselves; get_gst_details also answers data.bills_allowed.
--
-- set_gst_details: every bill needs a GSTIN, so "not registered" is gone. registered is optional and, when sent, must be true (an older
-- app that still offers "not registered" gets "Bills need a GSTIN: enter the warehouse's GSTIN.", 22023, nothing stored). The GSTIN is
-- required and checked on every save with the existing messages; the stored gstRegistered is always true. A facility saved as not
-- registered keeps its row until an administrator saves a GSTIN (no data change here); until then bills_allowed() is false for it.
--
-- No role is created, altered or dropped. No table or column changes. CREATE OR REPLACE (the text patches) keeps each function's owner
-- and grants. authorize_rpc's staff list gains can_make_bills (migrations/definitions/00_authorize_rpc.sql).

CREATE FUNCTION warehouse_security.bills_allowed() RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'pg_temp'
    AS $$
  SELECT COALESCE((s.g->>'saved')::boolean, false)
     AND COALESCE((s.g->>'registered')::boolean, false)
     AND warehouse_security.gstin_valid(s.g->>'gstin')
  FROM (SELECT warehouse_security.gst_settings() AS g) s
$$;
ALTER FUNCTION warehouse_security.bills_allowed() OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION warehouse_security.bills_allowed() FROM PUBLIC, anon, authenticated, service_role;

CREATE FUNCTION public.can_make_bills() RETURNS jsonb
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'pg_temp'
    AS $$
BEGIN
  PERFORM warehouse_security.authorize_rpc('can_make_bills', '{}'::jsonb);
  RETURN jsonb_build_object('success', true, 'data', jsonb_build_object('allowed', warehouse_security.bills_allowed()));
END $$;
ALTER FUNCTION public.can_make_bills() OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION public.can_make_bills() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.can_make_bills() TO authenticated, service_role;

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
  FOR i IN 1 .. array_length(p_old, 1) LOOP
    IF position(p_old[i] IN p_new[i]) > 0 THEN
      RAISE EXCEPTION '%: the replacement of marker % contains the marker', p_function, i;
    END IF;
    v_count := (length(v_def) - length(replace(v_def, p_old[i], ''))) / length(p_old[i]);
    IF v_count <> 1 THEN
      RAISE EXCEPTION '%: expected marker % once, found % times', p_function, i, v_count;
    END IF;
    v_def := replace(v_def, p_old[i], p_new[i]);
  END LOOP;
  EXECUTE v_def;
END $$;

-- The gate: right after the INVOICE_CANCELLED check, before any read of the request's number and before anything is written.
SELECT pg_temp.patch_function('public.save_invoice_internal(uuid, jsonb, jsonb[])'::regprocedure, ARRAY[
$m$            jsonb_build_object('invoice_id', p_invoice_id)) || jsonb_build_object('function_version', v_function_version);
    END IF;
    SELECT id INTO v_user_id FROM user_profiles WHERE auth_user_id = auth.uid();$m$
], ARRAY[
$m$            jsonb_build_object('invoice_id', p_invoice_id)) || jsonb_build_object('function_version', v_function_version);
    END IF;
    -- Migration 206 (WH-205): no new bill until the GST details are saved with a GSTIN (warehouse_security.bills_allowed). Nothing is
    -- written and no number is used; save_invoice has already answered a resend of a bill saved before.
    IF NOT warehouse_security.bills_allowed() THEN
        RETURN warehouse_security.refuse('GST_DETAILS_REQUIRED',
            'Save the GST details first (Settings, Warehouse tools, GST details). Bills can''t be made until then.',
            '{}'::jsonb) || jsonb_build_object('function_version', v_function_version);
    END IF;
    SELECT id INTO v_user_id FROM user_profiles WHERE auth_user_id = auth.uid();$m$
]);

SELECT pg_temp.patch_function('public.get_gst_details()'::regprocedure, ARRAY[
$m$    || jsonb_build_object('saved_by_name',$m$
], ARRAY[
$m$    -- Migration 206 (WH-205): whether a bill can be made (the rule save_invoice applies).
    || jsonb_build_object('bills_allowed', warehouse_security.bills_allowed(),
                          'saved_by_name',$m$
]);

SELECT pg_temp.patch_function('public.set_gst_details(jsonb)'::regprocedure, ARRAY[
$m$  IF jsonb_typeof(p_details->'registered') IS DISTINCT FROM 'boolean' THEN
    RAISE EXCEPTION 'Registered for GST must be true or false' USING ERRCODE = '22023';
  END IF;$m$,
$m$  v_registered := (p_details->>'registered')::boolean;$m$,
$m$  IF v_registered THEN
    IF v_gstin IS NULL THEN
      RAISE EXCEPTION 'Enter the GSTIN: it is required when the facility is registered for GST' USING ERRCODE = '22023';
    END IF;
    IF NOT warehouse_security.gstin_valid(v_gstin) THEN
      RAISE EXCEPTION 'The GSTIN must be 15 characters: a state code, the PAN, an entity number, Z and a check character' USING ERRCODE = '22023';
    END IF;
  ELSE
    -- An unregistered facility issues bills with no GSTIN; a GSTIN sent with registered false is not kept.
    v_gstin := NULL;
  END IF;$m$
], ARRAY[
$m$  -- Migration 206 (WH-205): every bill needs a GSTIN. registered is optional; when sent it must be true.
  IF p_details ? 'registered' AND p_details->'registered' IS DISTINCT FROM 'true'::jsonb THEN
    RAISE EXCEPTION 'Bills need a GSTIN: enter the warehouse''s GSTIN.' USING ERRCODE = '22023';
  END IF;$m$,
$m$  v_registered := true;$m$,
$m$  -- Migration 206 (WH-205): the GSTIN is required and checked on every save.
  IF v_gstin IS NULL THEN
    RAISE EXCEPTION 'Enter the GSTIN: it is required when the facility is registered for GST' USING ERRCODE = '22023';
  END IF;
  IF NOT warehouse_security.gstin_valid(v_gstin) THEN
    RAISE EXCEPTION 'The GSTIN must be 15 characters: a state code, the PAN, an entity number, Z and a check character' USING ERRCODE = '22023';
  END IF;$m$
]);

DROP FUNCTION pg_temp.patch_function(regprocedure, text[], text[]);

NOTIFY pgrst, 'reload schema';
