-- Number issued at save (WH-161, offline work step 5): topic "number issued at save". Named by topic; its number is taken when the work is
-- assembled for main. One of four topics of WH-161 that are assembled together, in this order: "number issued at save", "recorded time on
-- offline records", "permanent request ID on offline records", "refusal codes for offline sends" (the first two change the signature of
-- save_grn one after the other; the definition files save_grn.sql and create_dispatch_with_stock_check_internal.sql carry the behaviour of all
-- four and are applied after every numbered file). Contract: product/tech/app-offline-new-records.md section 2.1, cases B1 to B4, B12, B13.
--
-- What it does:
--  1. save_grn gains the trailing parameter p_issue_number boolean DEFAULT false (the old 18-argument function is dropped). The dispatch
--     reads issue_number in p_dispatch_data, so create_dispatch_with_stock_check keeps its signature.
--  2. With the flag true and the number blank, the server gives the number inside the document lock (71040): the one
--     warehouse_security.document_number_suggestion gives for the day of the document, after the request-key lookup and the role and
--     customer checks. Nothing is reserved; a save that is refused or rolled back uses no number; two sends in a burst get consecutive
--     numbers in the order they arrive. A number sent beside the flag is refused NUMBER_NOT_EXPECTED, free numbering NUMBER_REQUIRED, a
--     series with no number left SERIES_FULL. With the flag false (or absent) the number sent is used as before.
--  3. validate_dispatch_input (the wrapper's first check) no longer requires disp_no when issue_number is true.
--  4. The dispatch answer gains disp_no (definition file).
-- The function bodies are in migrations/definitions; this file only gives save_grn its new signature (a stub the definition file replaces) and
-- lets a blank dispatch number through the wrapper's validation.

DROP FUNCTION public.save_grn(character varying, timestamp with time zone, uuid, character varying, uuid, character varying, uuid, character varying, character varying, character varying, boolean, character varying, jsonb, jsonb, text, character varying, jsonb, boolean);

-- The new signature. The body is the definition file's (migrations/definitions/save_grn.sql, applied after the numbered files, as for every
-- function that has one, with its grants); this one only exists so that the signature does.
CREATE FUNCTION public.save_grn(p_gr_no character varying, p_date timestamp with time zone, p_customer_id uuid, p_customer_name character varying, p_sender_id uuid DEFAULT NULL::uuid, p_sender_name character varying DEFAULT NULL::character varying, p_supervisor_id uuid DEFAULT NULL::uuid, p_supervisor_name character varying DEFAULT NULL::character varying, p_registration character varying DEFAULT NULL::character varying, p_note character varying DEFAULT NULL::character varying, p_leon boolean DEFAULT false, p_pricing_mode character varying DEFAULT NULL::character varying, p_items jsonb DEFAULT '[]'::jsonb, p_images jsonb DEFAULT '[]'::jsonb, p_idempotency_key text DEFAULT NULL::text, p_duration_mode character varying DEFAULT 'legacy'::character varying, p_rates jsonb DEFAULT NULL::jsonb, p_warn_duplicate boolean DEFAULT false, p_issue_number boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'extensions', 'utils', 'pg_temp'
 SET jit TO 'off'
AS $function$
BEGIN
  RAISE EXCEPTION 'save_grn: the definition of migrations/definitions/save_grn.sql has not been applied';
END
$function$;

REVOKE ALL ON FUNCTION public.save_grn(character varying, timestamp with time zone, uuid, character varying, uuid, character varying, uuid, character varying, character varying, character varying, boolean, character varying, jsonb, jsonb, text, character varying, jsonb, boolean, boolean) FROM PUBLIC, anon, authenticated, service_role;

-- The wrapper's validation: a blank dispatch number is allowed when the server gives it.
DO $patch$
DECLARE
  v_def text;
  v_old constant text[] := ARRAY[
    $m$    IF warehouse_security.is_blank_text(v_disp_no) THEN$m$
  ];
  v_new constant text[] := ARRAY[
    $m$    -- Migration for WH-161: a dispatch that asks the server for its number (issue_number) has none yet.
    IF warehouse_security.is_blank_text(v_disp_no) AND COALESCE(p_dispatch_data->>'issue_number', '') <> 'true' THEN$m$
  ];
  v_count integer;
  i integer;
BEGIN
  v_def := pg_get_functiondef('public.validate_dispatch_input(jsonb)'::regprocedure);
  FOR i IN 1 .. array_length(v_old, 1) LOOP
    v_count := (length(v_def) - length(replace(v_def, v_old[i], ''))) / length(v_old[i]);
    IF v_count <> 1 THEN
      RAISE EXCEPTION 'validate_dispatch_input: expected marker % once, found % times', i, v_count;
    END IF;
    v_def := replace(v_def, v_old[i], v_new[i]);
  END LOOP;
  EXECUTE v_def;
END
$patch$;

NOTIFY pgrst, 'reload schema';
