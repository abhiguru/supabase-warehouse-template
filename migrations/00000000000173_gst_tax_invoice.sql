-- Migration 173 (WH-151): the right GST document for each invoice (tax invoice, bill of supply, invoice-cum-bill of supply or bill), with
-- the facility's GST details as settings, the item's GST treatment, and the CGST/SGST or IGST split worked out by the server.
--
-- NOTHING CHANGES UNTIL AN ADMINISTRATOR SAVES GST DETAILS. Until then every invoice is saved as today ('invoice'), every figure, read,
-- PDF and pre-printed print is what it was, and the item treatment is not used. Pinned fixture (made-up figures, docs/INVOICE_RULES.md
-- "Reproducible fixture"): receive 100 bags of 10 kg on 2026-04-01; dispatch 20 and 80 on 2026-05-02; 5 a bag a month, labour 2 a bag,
-- tax 5 %. Lines 20 -> 150 + 40 = 190, tax 9.50; 80 -> 600 + 160 = 760, tax 38.00; subtotal 950, header tax ceil(47.50) = 48, total 998.
-- With no GST details saved this invoice is doc_type 'invoice' with exactly these figures, the pre-printed form prints SGST 24.00 and
-- CGST 24.00 (tax / 2, as today) and the PDF is the one documentHtml made before.
--
--  1. Facility GST details: keys of WH-140's legal settings row (public.system_settings 'facility_legal', a JSON object; migration 167
--     reads and writes legalName, city, state and the grievance keys of the same row and keeps every other key). Keys added here:
--     gstRegistered (boolean), gstin, address ("address for documents"), sacStorage (default 996721), sacLabour (default 996719),
--     gstSavedAt and gstSavedBy (set by the first save: "details never saved" = no gstSavedAt). legalName is the shared legal name
--     (falls back to the app_name setting, as in migration 167). warehouse_security.gst_settings() reads them; get_gst_details() and
--     set_gst_details(p_details) are for administrators; each change writes one audit_log row (table_name 'facility_gst').
--  2. Indian states and union territories with their GST codes (warehouse_security.gst_state_list; 01-38 without 25 and 28, plus 97).
--     customers.state_code is generated from the customer's free-text state: the name of a state matched without case, spaces or
--     punctuation, a few unambiguous spellings (Orissa, Pondicherry, Uttaranchal, Gujrat, ...) or a two-digit code; anything else NULL,
--     for the administrator to pick. The app's state pick list writes the state's name, so the code follows it.
--  3. items.gst_treatment: 'taxable' (every existing and new item) or 'exempt_agri'. set_item_gst_treatment (administrators and
--     supervisors, like rates; one audit_log row per change, table_name 'items', action 'GST_TREATMENT').
--  4. invoice.doc_type ('invoice' for every row saved before GST details exist; 'bill', 'bill_of_supply', 'tax_invoice',
--     'invoice_cum_bos'), linked_invoice_id (the other document of a two-document save), and what the document was made with: the
--     supplier's legal name, address, GSTIN, state and SACs, the customer's GSTIN, state and address, the place of supply, the tax head
--     (cgst_sgst or igst) and the CGST, SGST and IGST amounts. invoice_trl gains gst_treatment, taxable_value, line_tax and the line's
--     CGST, SGST and IGST. All are readable by the app role (column grants of migration 48).
--  5. Which document (decided by the server at save, warehouse_security.apply_invoice_gst; stored on the invoice):
--       not registered -> 'bill' (no tax on any line); all lines exempt -> 'bill_of_supply'; all taxable -> 'tax_invoice';
--       mixed, customer without a valid GSTIN -> 'invoice_cum_bos'; mixed, customer with one -> two documents from one save, in the same
--       transaction: the tax invoice (the number sent, the taxable lines, the discount) and a bill of supply (number + 1, the exempt lines),
--       linked both ways. Both are saved or neither; the second number taken: NUMBER_TAKEN (number = the second), nothing saved.
--     An exempt line charges no tax whatever its rate's tax %: its stored tax % is 0 (also on a bill, every line). The invoice form
--     (build_invoice_form_lines) answers tax_percent 0 for those lines, so the form, the rate check (RATES_CHANGED) and the total check
--     (TOTAL_CHANGED, which adds the two documents of a two-document save) agree with the save.
--     An edit keeps the stored type, the supplier details and each line's treatment for the lines it had; a new line takes its item's
--     treatment, and the type follows the lines. An edit that would need two documents is refused: EDIT_NEEDS_TWO_DOCUMENTS (nothing
--     saved). A legacy 'invoice' stays 'invoice' under today's rules.
--  6. Tax split of a tax invoice and an invoice-cum-bill of supply. Customer state = the first two digits of a valid GSTIN, else
--     customers.state_code. Place of supply = the customer's state, else the facility's. Same state as the facility (or none): CGST + SGST;
--     otherwise IGST. Rounding (header and line alike): CGST = round(amount / 2, 2) (half away from zero), SGST = amount - CGST, so
--     CGST + SGST = the amount exactly and CGST is at most 1 paisa more. The header tax is first rounded per WH-137 (each document its
--     own), then split; line tax = round(taxable value x tax % / 100, 2), then split. IGST = the amount.
--  7. Reads: get_invoices_list answers doc_type on each row and takes p_doc_type (the signature grows by one defaulted parameter; the old
--     one is dropped, as in migration 172); get_invoice_detail and get_invoice_data (definition files) answer doc_type, linked_invoice and
--     a gst object; save_invoice answers doc_type, linked_invoice_id and documents; update_invoice answers doc_type;
--     get_invoice_range_for_print answers doc_type, gst_tax_head, cgst_amount and sgst_amount. A resend of a two-document save (request_key,
--     get_submission_result) is answered only while both documents exist. preview_invoice_documents (staff and above) tells the review
--     step which document(s) a set of dispatch lines makes, with each document's figures before any discount.
--  8. A pair is deleted together: delete_invoice refuses one document of a pair (INVOICE_PAIR, naming the other); delete_invoice_pair
--     (administrators and supervisors) deletes both in one transaction, or neither (the refusal of either, e.g. INVOICE_HAS_PAYMENTS or
--     STALE_RECORD, with deleted 0). get_invoice_range_for_print also answers supplier_state_name (the facility's state the invoice was
--     made with), which the pre-printed form prints instead of GUJARAT.
--
-- Worked by hand (made-up figures; facility GSTIN 24AAAAA0000A1Z5, Gujarat, registered; rule 'up'):
--   A. Tax invoice, same state: 10 bags of Jeera (taxable), 12.50 a month, labour 3.00, tax 5 %, 1.5 months: storage 187.50 + labour
--      30.00 = taxable 217.50; line tax round(10.875, 2) = 10.88 -> CGST 5.44, SGST 5.44; header tax ceil(10.875) = 11 -> CGST 5.50,
--      SGST 5.50; total ceil(228.50) = 229. Place of supply Gujarat (24).
--   B. The same, customer GSTIN 27BBBBB1111B1Z3 (Maharashtra): IGST 11.00 (line 10.88); place of supply Maharashtra (27).
--   C. Potatoes marked exempt, rate tax 5 %: 20 bags x 5 x 1.5 = 150 + labour 40 = 190, tax 0 -> bill of supply of 190.
--   D. Mixed C + A, customer without GSTIN: one invoice-cum-bill of supply: subtotal 407.50, tax ceil(10.875) = 11 (CGST 5.50, SGST 5.50),
--      total ceil(418.50) = 419. Customer with GSTIN 24CCCCC2222C1Z1: tax invoice n of 229 and bill of supply n + 1 of 190; the total check
--      compares the sum 419 with expected_total.
--   E. Odd paise (rule 'none'): tax 10.87 -> CGST round(5.435, 2) = 5.44, SGST 5.43.
--   F. Not registered: bill, every line tax 0: 217.50 -> total 218.
--
-- Patched in place by marker count (pattern of migrations 134-172; each marker found exactly once). The definition files changed in the
-- same commit are migrations/definitions/get_invoice_detail.sql, get_invoice_data.sql and 00_authorize_rpc.sql.

-- Section 1: states and union territories
CREATE FUNCTION warehouse_security.gst_state_list() RETURNS TABLE(code text, name text)
    LANGUAGE sql IMMUTABLE
    SET search_path TO 'pg_catalog'
    AS $$
  SELECT s.code, s.name FROM (VALUES
    ('01', 'Jammu and Kashmir'), ('02', 'Himachal Pradesh'), ('03', 'Punjab'), ('04', 'Chandigarh'), ('05', 'Uttarakhand'),
    ('06', 'Haryana'), ('07', 'Delhi'), ('08', 'Rajasthan'), ('09', 'Uttar Pradesh'), ('10', 'Bihar'), ('11', 'Sikkim'),
    ('12', 'Arunachal Pradesh'), ('13', 'Nagaland'), ('14', 'Manipur'), ('15', 'Mizoram'), ('16', 'Tripura'), ('17', 'Meghalaya'),
    ('18', 'Assam'), ('19', 'West Bengal'), ('20', 'Jharkhand'), ('21', 'Odisha'), ('22', 'Chhattisgarh'), ('23', 'Madhya Pradesh'),
    ('24', 'Gujarat'), ('26', 'Dadra and Nagar Haveli and Daman and Diu'), ('27', 'Maharashtra'), ('29', 'Karnataka'), ('30', 'Goa'),
    ('31', 'Lakshadweep'), ('32', 'Kerala'), ('33', 'Tamil Nadu'), ('34', 'Puducherry'), ('35', 'Andaman and Nicobar Islands'),
    ('36', 'Telangana'), ('37', 'Andhra Pradesh'), ('38', 'Ladakh'), ('97', 'Other Territory')
  ) AS s(code, name)
$$;
ALTER FUNCTION warehouse_security.gst_state_list() OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION warehouse_security.gst_state_list() FROM PUBLIC;

CREATE FUNCTION warehouse_security.gst_state_name(p_code text) RETURNS text
    LANGUAGE sql IMMUTABLE
    SET search_path TO 'pg_catalog'
    AS $$
  SELECT s.name FROM warehouse_security.gst_state_list() s WHERE s.code = p_code
$$;
ALTER FUNCTION warehouse_security.gst_state_name(text) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION warehouse_security.gst_state_name(text) FROM PUBLIC;

-- The code of a free-text state, or NULL when it is not one state for certain.
CREATE FUNCTION warehouse_security.gst_state_code(p_state text) RETURNS text
    LANGUAGE sql IMMUTABLE
    SET search_path TO 'pg_catalog'
    AS $$
  WITH k AS (
    SELECT btrim(COALESCE(p_state, '')) AS raw, regexp_replace(lower(COALESCE(p_state, '')), '[^a-z]', '', 'g') AS key
  ), names AS (
    SELECT s.code, regexp_replace(lower(s.name), '[^a-z]', '', 'g') AS key FROM warehouse_security.gst_state_list() s
    UNION ALL
    SELECT a.code, a.key FROM (VALUES
      ('01', 'jammukashmir'), ('05', 'uttaranchal'), ('07', 'newdelhi'), ('07', 'nctofdelhi'), ('07', 'nctdelhi'), ('21', 'orissa'),
      ('22', 'chattisgarh'), ('22', 'chhatisgarh'), ('24', 'gujrat'), ('26', 'dadranagarhaveli'), ('26', 'dadraandnagarhaveli'),
      ('26', 'damananddiu'), ('26', 'damandiu'), ('26', 'dadranagarhavelianddamananddiu'), ('27', 'maharastra'), ('34', 'pondicherry'),
      ('35', 'andamanandnicobar'), ('35', 'andamannicobar'), ('35', 'andamannicobarislands')
    ) AS a(code, key)
  )
  SELECT CASE
    WHEN k.raw ~ '^[0-9]{2}$' THEN (SELECT s.code FROM warehouse_security.gst_state_list() s WHERE s.code = k.raw)
    WHEN k.key = '' THEN NULL
    ELSE (SELECT min(n.code) FROM names n WHERE n.key = k.key HAVING count(DISTINCT n.code) = 1)
  END
  FROM k
$$;
ALTER FUNCTION warehouse_security.gst_state_code(text) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION warehouse_security.gst_state_code(text) FROM PUBLIC;
-- The generated column below is computed by whoever writes customers: the RPCs (owner) and the service key.
GRANT EXECUTE ON FUNCTION warehouse_security.gst_state_list() TO service_role;
GRANT EXECUTE ON FUNCTION warehouse_security.gst_state_code(text) TO service_role;

CREATE FUNCTION warehouse_security.gstin_normal(p_gstin text) RETURNS text
    LANGUAGE sql IMMUTABLE
    SET search_path TO 'pg_catalog'
    AS $$
  SELECT upper(regexp_replace(COALESCE(p_gstin, ''), '\s', '', 'g'))
$$;
ALTER FUNCTION warehouse_security.gstin_normal(text) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION warehouse_security.gstin_normal(text) FROM PUBLIC;

-- The shape of a GSTIN (no check-digit test): state code of the list, PAN (5 letters, 4 digits, 1 letter), entity 1-9 or A-Z, Z, check.
CREATE FUNCTION warehouse_security.gstin_valid(p_gstin text) RETURNS boolean
    LANGUAGE sql IMMUTABLE
    SET search_path TO 'pg_catalog'
    AS $$
  SELECT COALESCE(p_gstin ~ '^[0-9]{2}[A-Z]{5}[0-9]{4}[A-Z][1-9A-Z]Z[0-9A-Z]$'
                  AND warehouse_security.gst_state_name(left(p_gstin, 2)) IS NOT NULL, false)
$$;
ALTER FUNCTION warehouse_security.gstin_valid(text) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION warehouse_security.gstin_valid(text) FROM PUBLIC;

-- Half of an amount for CGST: rounded to the paisa (half away from zero). SGST is the amount minus this, so the two add up exactly.
CREATE FUNCTION warehouse_security.gst_half(p_amount numeric) RETURNS numeric
    LANGUAGE sql IMMUTABLE
    SET search_path TO 'pg_catalog'
    AS $$
  SELECT round(p_amount / 2.0, 2)
$$;
ALTER FUNCTION warehouse_security.gst_half(numeric) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION warehouse_security.gst_half(numeric) FROM PUBLIC;

ALTER TABLE public.customers ADD COLUMN state_code text GENERATED ALWAYS AS (warehouse_security.gst_state_code(state::text)) STORED;
COMMENT ON COLUMN public.customers.state_code IS 'Migration 173 (WH-151): the GST state code of the customer''s state, NULL when the free text is not one state for certain.';

-- Section 2: the facility's GST details (keys of the facility_legal row; see the header)
INSERT INTO public.system_settings (key, value, description) VALUES
  ('facility_legal', '{}', 'The facility''s legal and GST details (JSON; migrations 167 and 173)')
ON CONFLICT (key) DO NOTHING;

CREATE FUNCTION warehouse_security.gst_settings() RETURNS jsonb
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'pg_temp'
    AS $$
  WITH s AS (
    SELECT COALESCE((SELECT CASE WHEN value ~ '^\s*\{' THEN value::jsonb END FROM public.system_settings WHERE key = 'facility_legal'), '{}'::jsonb) AS j,
           COALESCE((SELECT btrim(value) FROM public.system_settings WHERE key = 'app_name'), '') AS company)
  SELECT jsonb_build_object(
    'saved', s.j ? 'gstSavedAt',
    'registered', COALESCE(s.j->>'gstRegistered' = 'true', false),
    'gstin', NULLIF(s.j->>'gstin', ''),
    'state_code', CASE WHEN COALESCE(s.j->>'gstin', '') <> '' THEN left(s.j->>'gstin', 2) END,
    'state_name', warehouse_security.gst_state_name(left(NULLIF(s.j->>'gstin', ''), 2)),
    'legal_name', COALESCE(NULLIF(btrim(s.j->>'legalName'), ''), s.company),
    'address', COALESCE(s.j->>'address', ''),
    'sac_storage', COALESCE(NULLIF(s.j->>'sacStorage', ''), '996721'),
    'sac_labour', COALESCE(NULLIF(s.j->>'sacLabour', ''), '996719'),
    'saved_at', s.j->>'gstSavedAt',
    'saved_by', s.j->>'gstSavedBy')
  FROM s
$$;
ALTER FUNCTION warehouse_security.gst_settings() OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION warehouse_security.gst_settings() FROM PUBLIC, anon, authenticated, service_role;

CREATE FUNCTION public.get_gst_details() RETURNS jsonb
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'pg_temp'
    AS $$
BEGIN
  PERFORM warehouse_security.authorize_rpc('get_gst_details', jsonb_build_object());
  -- Like set_document_numbering: the body does not depend on the definition file having been applied yet.
  IF warehouse_security.active_role() IS DISTINCT FROM 'admin' AND auth.jwt()->>'role' IS DISTINCT FROM 'service_role' THEN
    RAISE EXCEPTION 'Administrator required' USING ERRCODE = '42501';
  END IF;
  RETURN jsonb_build_object('success', true, 'data', warehouse_security.gst_settings()
    || jsonb_build_object('saved_by_name', (SELECT p.name FROM public.user_profiles p
                                             WHERE p.id::text = warehouse_security.gst_settings()->>'saved_by'),
                          'states', (SELECT jsonb_agg(jsonb_build_object('code', s.code, 'name', s.name) ORDER BY s.name)
                                       FROM warehouse_security.gst_state_list() s)));
END $$;
ALTER FUNCTION public.get_gst_details() OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION public.get_gst_details() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.get_gst_details() TO authenticated, service_role;

-- p_details: registered (true or false, required), gstin (required when registered), address (required), legal_name, sac_storage and
-- sac_labour (optional: legal_name left out keeps the stored one, an empty one falls back to the company name; a SAC left out or empty is
-- the default). Every value is checked before anything is stored, so a refused value changes nothing (SQLSTATE 22023).
CREATE FUNCTION public.set_gst_details(p_details jsonb) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'pg_temp'
    AS $$
DECLARE
  v_keys constant text[] := ARRAY['registered', 'gstin', 'address', 'legal_name', 'sac_storage', 'sac_labour'];
  v_key text;
  v_stored jsonb;
  v_new jsonb;
  v_old jsonb;
  v_registered boolean;
  v_gstin text;
  v_address text;
  v_legal text;
  v_sac_storage text;
  v_sac_labour text;
  v_profile uuid := public.get_current_user_profile_id();
BEGIN
  PERFORM warehouse_security.authorize_rpc('set_gst_details', jsonb_build_object());
  IF warehouse_security.active_role() IS DISTINCT FROM 'admin' AND auth.jwt()->>'role' IS DISTINCT FROM 'service_role' THEN
    RAISE EXCEPTION 'Administrator required' USING ERRCODE = '42501';
  END IF;
  IF p_details IS NULL OR jsonb_typeof(p_details) <> 'object' THEN
    RAISE EXCEPTION 'GST details must be an object' USING ERRCODE = '22023';
  END IF;
  FOR v_key IN SELECT jsonb_object_keys(p_details) LOOP
    IF v_key <> ALL (v_keys) THEN
      RAISE EXCEPTION 'Unknown GST detail: %', left(v_key, 40) USING ERRCODE = '22023';
    END IF;
  END LOOP;
  IF jsonb_typeof(p_details->'registered') IS DISTINCT FROM 'boolean' THEN
    RAISE EXCEPTION 'Registered for GST must be true or false' USING ERRCODE = '22023';
  END IF;
  FOREACH v_key IN ARRAY v_keys[2:6] LOOP
    IF p_details ? v_key AND jsonb_typeof(p_details->v_key) NOT IN ('string', 'null') THEN
      RAISE EXCEPTION '% must be text', v_key USING ERRCODE = '22023';
    END IF;
  END LOOP;
  v_registered := (p_details->>'registered')::boolean;

  v_gstin := NULLIF(warehouse_security.gstin_normal(p_details->>'gstin'), '');
  IF v_registered THEN
    IF v_gstin IS NULL THEN
      RAISE EXCEPTION 'Enter the GSTIN: it is required when the facility is registered for GST' USING ERRCODE = '22023';
    END IF;
    IF NOT warehouse_security.gstin_valid(v_gstin) THEN
      RAISE EXCEPTION 'The GSTIN must be 15 characters: a state code, the PAN, an entity number, Z and a check character' USING ERRCODE = '22023';
    END IF;
  ELSE
    -- An unregistered facility issues bills with no GSTIN; a GSTIN sent with registered false is not kept.
    v_gstin := NULL;
  END IF;

  v_address := btrim(COALESCE(p_details->>'address', ''));
  IF v_address = '' THEN
    RAISE EXCEPTION 'Enter the address for documents' USING ERRCODE = '22023';
  END IF;
  IF char_length(v_address) > 300 OR v_address ~ '[\x01-\x09\x0b-\x1f\x7f-\x9f  ]' THEN
    RAISE EXCEPTION 'The address must be printable text of at most 300 characters' USING ERRCODE = '22023';
  END IF;

  IF p_details ? 'legal_name' THEN
    v_legal := btrim(COALESCE(p_details->>'legal_name', ''));
    IF char_length(v_legal) > 120 OR v_legal ~ '[\x01-\x1f\x7f-\x9f  ]' THEN
      RAISE EXCEPTION 'Legal name must be printable text of at most 120 characters' USING ERRCODE = '22023';
    END IF;
  END IF;

  v_sac_storage := COALESCE(NULLIF(btrim(COALESCE(p_details->>'sac_storage', '')), ''), '996721');
  v_sac_labour := COALESCE(NULLIF(btrim(COALESCE(p_details->>'sac_labour', '')), ''), '996719');
  IF v_sac_storage !~ '^[0-9]{4,8}$' OR v_sac_labour !~ '^[0-9]{4,8}$' THEN
    RAISE EXCEPTION 'A SAC is 4 to 8 digits' USING ERRCODE = '22023';
  END IF;

  SELECT COALESCE((SELECT CASE WHEN value ~ '^\s*\{' THEN value::jsonb END FROM public.system_settings WHERE key = 'facility_legal' FOR UPDATE), '{}'::jsonb)
    INTO v_stored;
  v_old := warehouse_security.gst_settings();
  v_new := v_stored || jsonb_build_object('gstRegistered', v_registered, 'address', v_address,
                                          'sacStorage', v_sac_storage, 'sacLabour', v_sac_labour);
  v_new := CASE WHEN v_gstin IS NULL THEN v_new - 'gstin' ELSE v_new || jsonb_build_object('gstin', v_gstin) END;
  IF v_legal IS NOT NULL THEN
    v_new := CASE WHEN v_legal = '' THEN v_new - 'legalName' ELSE v_new || jsonb_build_object('legalName', v_legal) END;
  END IF;
  -- The first save, and every save that changes a value, is stored and audited; the same values again write nothing.
  IF NOT (v_stored ? 'gstSavedAt') OR (v_new - 'gstSavedAt' - 'gstSavedBy') IS DISTINCT FROM (v_stored - 'gstSavedAt' - 'gstSavedBy') THEN
    v_new := v_new || jsonb_build_object('gstSavedAt', now(), 'gstSavedBy', v_profile);
    INSERT INTO public.system_settings (key, value) VALUES ('facility_legal', v_new::text)
    ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = now();
    INSERT INTO public.audit_log (table_name, action, user_id, old_data, new_data)
    VALUES ('facility_gst', CASE WHEN v_stored ? 'gstSavedAt' THEN 'UPDATED' ELSE 'CREATED' END, v_profile, v_old,
            warehouse_security.gst_settings());
  END IF;
  RETURN jsonb_build_object('success', true, 'data', warehouse_security.gst_settings());
END $$;
ALTER FUNCTION public.set_gst_details(jsonb) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION public.set_gst_details(jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.set_gst_details(jsonb) TO authenticated, service_role;

-- Section 3: how each item is taxed
ALTER TABLE public.items ADD COLUMN gst_treatment text DEFAULT 'taxable' NOT NULL,
  ADD CONSTRAINT items_gst_treatment_check CHECK (gst_treatment IN ('taxable', 'exempt_agri'));
COMMENT ON COLUMN public.items.gst_treatment IS 'Migration 173 (WH-151): GST on storage: taxable, or exempt_agri (agricultural produce; no tax on its lines once GST details are saved).';

CREATE FUNCTION public.set_item_gst_treatment(p_item_id uuid, p_gst_treatment text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'pg_temp'
    AS $$
DECLARE
  v_old text;
  v_name text;
BEGIN
  PERFORM warehouse_security.authorize_rpc('set_item_gst_treatment', jsonb_build_object('p_item_id', p_item_id));
  IF warehouse_security.active_role() NOT IN ('admin', 'supervisor') AND auth.jwt()->>'role' IS DISTINCT FROM 'service_role' THEN
    RAISE EXCEPTION 'Administrator or supervisor required' USING ERRCODE = '42501';
  END IF;
  IF p_gst_treatment IS NULL OR p_gst_treatment NOT IN ('taxable', 'exempt_agri') THEN
    RAISE EXCEPTION 'GST on storage must be taxable or exempt_agri' USING ERRCODE = '22023';
  END IF;
  SELECT i.gst_treatment, i.name INTO v_old, v_name FROM public.items i WHERE i.id = p_item_id FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'Item not found');
  END IF;
  IF v_old IS DISTINCT FROM p_gst_treatment THEN
    UPDATE public.items SET gst_treatment = p_gst_treatment WHERE id = p_item_id;
    INSERT INTO public.audit_log (table_name, action, user_id, old_data, new_data)
    VALUES ('items', 'GST_TREATMENT', public.get_current_user_profile_id(),
            jsonb_build_object('id', p_item_id, 'name', v_name, 'gst_treatment', v_old),
            jsonb_build_object('id', p_item_id, 'name', v_name, 'gst_treatment', p_gst_treatment));
  END IF;
  RETURN jsonb_build_object('success', true, 'data', jsonb_build_object('item_id', p_item_id, 'gst_treatment', p_gst_treatment,
                                                                       'changed', v_old IS DISTINCT FROM p_gst_treatment));
END $$;
ALTER FUNCTION public.set_item_gst_treatment(uuid, text) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION public.set_item_gst_treatment(uuid, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.set_item_gst_treatment(uuid, text) TO authenticated, service_role;

-- Section 4: what each document was made with. Constant defaults: no table rewrite; every existing invoice reads 'invoice'.
ALTER TABLE public.invoice
  ADD COLUMN doc_type text DEFAULT 'invoice' NOT NULL,
  ADD COLUMN linked_invoice_id uuid,
  ADD COLUMN gst_supplier_legal_name text,
  ADD COLUMN gst_supplier_address text,
  ADD COLUMN gst_supplier_gstin text,
  ADD COLUMN gst_supplier_state text,
  ADD COLUMN gst_sac_storage text,
  ADD COLUMN gst_sac_labour text,
  ADD COLUMN gst_customer_gstin text,
  ADD COLUMN gst_customer_state text,
  ADD COLUMN gst_customer_address text,
  ADD COLUMN gst_place_of_supply text,
  ADD COLUMN gst_tax_head text,
  ADD COLUMN cgst_amount numeric(12,2),
  ADD COLUMN sgst_amount numeric(12,2),
  ADD COLUMN igst_amount numeric(12,2),
  ADD CONSTRAINT invoice_doc_type_check CHECK (doc_type IN ('invoice', 'bill', 'bill_of_supply', 'tax_invoice', 'invoice_cum_bos')),
  ADD CONSTRAINT invoice_gst_tax_head_check CHECK (gst_tax_head IN ('cgst_sgst', 'igst')),
  ADD CONSTRAINT invoice_gst_split_check CHECK (
    (gst_tax_head IS NULL AND cgst_amount IS NULL AND sgst_amount IS NULL AND igst_amount IS NULL)
    OR (gst_tax_head = 'igst' AND cgst_amount IS NULL AND sgst_amount IS NULL)
    OR (gst_tax_head = 'cgst_sgst' AND igst_amount IS NULL));
COMMENT ON COLUMN public.invoice.doc_type IS 'Migration 173 (WH-151): invoice (saved before GST details existed: today''s document), bill, bill_of_supply, tax_invoice or invoice_cum_bos.';
COMMENT ON COLUMN public.invoice.linked_invoice_id IS 'Migration 173: the other document of a two-document save (tax invoice and bill of supply); no foreign key, it may name a deleted invoice.';
COMMENT ON COLUMN public.invoice.gst_tax_head IS 'Migration 173: cgst_sgst or igst for a tax invoice or an invoice-cum-bill of supply; NULL otherwise.';
CREATE INDEX idx_invoice_linked_invoice_id ON public.invoice (linked_invoice_id) WHERE linked_invoice_id IS NOT NULL;
GRANT SELECT (doc_type, linked_invoice_id, gst_supplier_legal_name, gst_supplier_address, gst_supplier_gstin, gst_supplier_state,
              gst_sac_storage, gst_sac_labour, gst_customer_gstin, gst_customer_state, gst_customer_address, gst_place_of_supply,
              gst_tax_head, cgst_amount, sgst_amount, igst_amount) ON TABLE public.invoice TO authenticated;

ALTER TABLE public.invoice_trl
  ADD COLUMN gst_treatment text,
  ADD COLUMN taxable_value numeric(12,2),
  ADD COLUMN line_tax numeric(12,2),
  ADD COLUMN cgst_amount numeric(12,2),
  ADD COLUMN sgst_amount numeric(12,2),
  ADD COLUMN igst_amount numeric(12,2),
  ADD CONSTRAINT invoice_trl_gst_treatment_check CHECK (gst_treatment IN ('taxable', 'exempt_agri'));
COMMENT ON COLUMN public.invoice_trl.gst_treatment IS 'Migration 173: the item''s GST treatment when the line went on the invoice; NULL on an invoice of doc_type invoice.';

-- Section 5: the document of an invoice
-- What a set of lines makes: invoice (details never saved), bill, bill_of_supply, tax_invoice, invoice_cum_bos, or split (two documents).
CREATE FUNCTION warehouse_security.gst_document_kind(p_saved boolean, p_registered boolean, p_customer_registered boolean,
                                                     p_exempt integer, p_taxable integer) RETURNS text
    LANGUAGE sql IMMUTABLE
    SET search_path TO 'pg_catalog'
    AS $$
  SELECT CASE WHEN NOT p_saved THEN 'invoice'
              WHEN NOT p_registered THEN 'bill'
              WHEN p_taxable = 0 THEN 'bill_of_supply'
              WHEN p_exempt = 0 THEN 'tax_invoice'
              WHEN p_customer_registered THEN 'split'
              ELSE 'invoice_cum_bos' END
$$;
ALTER FUNCTION warehouse_security.gst_document_kind(boolean, boolean, boolean, integer, integer) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION warehouse_security.gst_document_kind(boolean, boolean, boolean, integer, integer) FROM PUBLIC;

-- The customer as a document shows it now: a valid GSTIN (else NULL), the state (from the GSTIN, else the picked state) and the address.
CREATE FUNCTION warehouse_security.gst_customer(p_customer_id uuid) RETURNS jsonb
    LANGUAGE sql STABLE
    SET search_path TO 'pg_catalog', 'public'
    AS $$
  SELECT jsonb_build_object(
    'gstin', CASE WHEN warehouse_security.gstin_valid(warehouse_security.gstin_normal(c.gst)) THEN warehouse_security.gstin_normal(c.gst) END,
    'state_code', CASE WHEN warehouse_security.gstin_valid(warehouse_security.gstin_normal(c.gst)) THEN left(warehouse_security.gstin_normal(c.gst), 2)
                       ELSE c.state_code END,
    'address', NULLIF(concat_ws(', ', NULLIF(btrim(c.address), ''), NULLIF(btrim(c.city), ''), NULLIF(btrim(c.pincode::text), '')), ''))
  FROM public.customers c WHERE c.id = p_customer_id
$$;
ALTER FUNCTION warehouse_security.gst_customer(uuid) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION warehouse_security.gst_customer(uuid) FROM PUBLIC;

-- The treatment of a line on the invoice form or at a save: the one it has on the invoice being edited (or on that invoice's other
-- document), else its item's.
CREATE FUNCTION warehouse_security.gst_line_treatment(p_item_id uuid, p_dt_id uuid) RETURNS text
    LANGUAGE sql STABLE
    SET search_path TO 'pg_catalog', 'public'
    AS $$
  SELECT COALESCE(
    (SELECT t.gst_treatment FROM public.invoice_trl t JOIN public.invoice f ON t.invoice_id IN (f.id, f.linked_invoice_id)
      WHERE f.id = NULLIF(current_setting('warehouse.form_invoice_id', true), '')::uuid AND t.disp_trl_id = p_dt_id
        AND t.gst_treatment IS NOT NULL LIMIT 1),
    (SELECT i.gst_treatment FROM public.items i WHERE i.id = p_item_id),
    'taxable')
$$;
ALTER FUNCTION warehouse_security.gst_line_treatment(uuid, uuid) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION warehouse_security.gst_line_treatment(uuid, uuid) FROM PUBLIC;

-- True when the line charges no tax: an exempt line of a registered facility, or any line of a bill. The invoice being edited
-- (warehouse.form_invoice_id) decides by its own type; a new invoice by the facility's details. No details, or an 'invoice': false.
CREATE FUNCTION warehouse_security.gst_zero_tax(p_item_id uuid, p_dt_id uuid) RETURNS boolean
    LANGUAGE plpgsql STABLE
    SET search_path TO 'pg_catalog', 'public'
    AS $$
DECLARE
  v_doc text;
  v_settings jsonb;
BEGIN
  SELECT f.doc_type INTO v_doc FROM public.invoice f
   WHERE f.id = NULLIF(current_setting('warehouse.form_invoice_id', true), '')::uuid;
  IF FOUND THEN
    IF v_doc = 'invoice' THEN RETURN false; END IF;
    IF v_doc = 'bill' THEN RETURN true; END IF;
  ELSE
    v_settings := warehouse_security.gst_settings();
    IF NOT (v_settings->>'saved')::boolean THEN RETURN false; END IF;
    IF NOT (v_settings->>'registered')::boolean THEN RETURN true; END IF;
  END IF;
  RETURN warehouse_security.gst_line_treatment(p_item_id, p_dt_id) = 'exempt_agri';
END $$;
ALTER FUNCTION warehouse_security.gst_zero_tax(uuid, uuid) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION warehouse_security.gst_zero_tax(uuid, uuid) FROM PUBLIC;

-- True when the line is on the live other document of the invoice being edited: the edit form does not offer it.
CREATE FUNCTION warehouse_security.gst_on_form_partner(p_dt_id uuid) RETURNS boolean
    LANGUAGE sql STABLE
    SET search_path TO 'pg_catalog', 'public'
    AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.invoice f
    JOIN public.invoice p ON p.id = f.linked_invoice_id AND p.deleted_at IS NULL AND p.cancelled_at IS NULL
    JOIN public.invoice_trl t ON t.invoice_id = p.id AND t.disp_trl_id = p_dt_id
    WHERE f.id = NULLIF(current_setting('warehouse.form_invoice_id', true), '')::uuid)
$$;
ALTER FUNCTION warehouse_security.gst_on_form_partner(uuid) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION warehouse_security.gst_on_form_partner(uuid) FROM PUBLIC;

-- update_invoice, before it writes: the customer and each line's treatment, kept for apply_invoice_gst.
CREATE FUNCTION warehouse_security.note_invoice_gst_before_edit(p_invoice_id uuid) RETURNS void
    LANGUAGE sql
    SET search_path TO 'pg_catalog', 'public'
    AS $$
  SELECT set_config('warehouse.gst_before_edit', COALESCE((
    SELECT jsonb_build_object('invoice_id', i.id, 'customer_id', i.customer_id,
             'lines', COALESCE((SELECT jsonb_object_agg(t.disp_trl_id::text, t.gst_treatment) FROM public.invoice_trl t
                                 WHERE t.invoice_id = i.id AND t.disp_trl_id IS NOT NULL AND t.gst_treatment IS NOT NULL), '{}'::jsonb))
      FROM public.invoice i WHERE i.id = p_invoice_id)::text, ''), true)
$$;
ALTER FUNCTION warehouse_security.note_invoice_gst_before_edit(uuid) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION warehouse_security.note_invoice_gst_before_edit(uuid) FROM PUBLIC;

-- After the header is recalculated: each line's taxable value, tax and split, and the header split (see the header for the rounding).
CREATE FUNCTION warehouse_security.invoice_gst_amounts(p_invoice_id uuid) RETURNS void
    LANGUAGE plpgsql
    SET search_path TO 'pg_catalog', 'public'
    AS $$
DECLARE
  v_doc text;
  v_head text;
  v_tax numeric(12,2);
BEGIN
  SELECT i.doc_type, i.gst_tax_head, COALESCE(i.tax_amount, 0) INTO v_doc, v_head, v_tax FROM public.invoice i WHERE i.id = p_invoice_id;
  IF NOT FOUND OR v_doc = 'invoice' THEN
    RETURN;
  END IF;
  UPDATE public.invoice_trl it SET
      taxable_value = l.base,
      line_tax = l.line_tax,
      cgst_amount = l.cgst,
      sgst_amount = l.sgst,
      igst_amount = l.igst
    FROM (
      SELECT y.id, y.base, y.line_tax,
             CASE WHEN v_head = 'cgst_sgst' THEN warehouse_security.gst_half(y.line_tax) END AS cgst,
             CASE WHEN v_head = 'cgst_sgst' THEN y.line_tax - warehouse_security.gst_half(y.line_tax) END AS sgst,
             CASE WHEN v_head = 'igst' THEN y.line_tax END AS igst
        FROM (
          SELECT x.id, x.base, round(x.base * x.tax_percent / 100.0, 2) AS line_tax
            FROM (
              -- The line base exactly as recalculate_invoice_header works it out.
              SELECT t.id,
                     CASE WHEN gr.pricing_mode = 'ONE_TIME'
                       THEN round(COALESCE(t.charge, 0) * dt.disp_qty, 2)
                       ELSE warehouse_security.invoice_storage_amount(p_invoice_id, COALESCE(t.charge, 0), dt.disp_qty, COALESCE(t.duration, 1), t.no_of_days)
                            + round(COALESCE(t.labour_rate, 0) * dt.disp_qty, 2) END AS base,
                     COALESCE(t.tax, 0) AS tax_percent
                FROM public.invoice_trl t
                JOIN public.dispatch_trl dt ON dt.id = t.disp_trl_id
                JOIN public.goodsreceived gr ON gr.id = dt.gr_id
               WHERE t.invoice_id = p_invoice_id) x) y) l
   WHERE it.id = l.id
     AND ROW(it.taxable_value, it.line_tax, it.cgst_amount, it.sgst_amount, it.igst_amount)
         IS DISTINCT FROM ROW(l.base, l.line_tax, l.cgst, l.sgst, l.igst);
  UPDATE public.invoice SET
      cgst_amount = CASE WHEN v_head = 'cgst_sgst' THEN warehouse_security.gst_half(v_tax) END,
      sgst_amount = CASE WHEN v_head = 'cgst_sgst' THEN v_tax - warehouse_security.gst_half(v_tax) END,
      igst_amount = CASE WHEN v_head = 'igst' THEN v_tax END
   WHERE id = p_invoice_id
     AND ROW(cgst_amount, sgst_amount, igst_amount) IS DISTINCT FROM ROW(
           CASE WHEN v_head = 'cgst_sgst' THEN warehouse_security.gst_half(v_tax) END,
           CASE WHEN v_head = 'cgst_sgst' THEN v_tax - warehouse_security.gst_half(v_tax) END,
           CASE WHEN v_head = 'igst' THEN v_tax END);
END $$;
ALTER FUNCTION warehouse_security.invoice_gst_amounts(uuid) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION warehouse_security.invoice_gst_amounts(uuid) FROM PUBLIC;

-- At a save (p_new) or an edit, after the lines are written and before the header is recalculated: the document type, what it is made
-- with, no tax on exempt lines (every line of a bill), and the second document of a two-document save. Refusals are raised as 'rate_fail'
-- with the answer in DETAIL, which save_invoice_internal and update_invoice return after rolling the save back.
CREATE FUNCTION warehouse_security.apply_invoice_gst(p_invoice_id uuid, p_new boolean) RETURNS void
    LANGUAGE plpgsql
    SET search_path TO 'pg_catalog', 'public'
    AS $$
DECLARE
  v_inv public.invoice;
  v_before jsonb := NULLIF(current_setting('warehouse.gst_before_edit', true), '')::jsonb;
  v_settings jsonb;
  v_registered boolean;
  v_customer jsonb;
  v_exempt integer;
  v_taxable integer;
  v_kind text;
  v_doc text;
  v_pos text;
  v_head text;
  v_second uuid;
  v_second_no integer;
BEGIN
  PERFORM set_config('warehouse.gst_before_edit', '', true);
  IF v_before IS NOT NULL AND v_before->>'invoice_id' IS DISTINCT FROM p_invoice_id::text THEN
    v_before := NULL;
  END IF;
  SELECT * INTO v_inv FROM public.invoice i WHERE i.id = p_invoice_id;
  IF NOT FOUND THEN
    RETURN;
  END IF;
  IF p_new THEN
    v_settings := warehouse_security.gst_settings();
    IF NOT (v_settings->>'saved')::boolean THEN
      RETURN;  -- GST details never saved: today's invoice, untouched.
    END IF;
    v_registered := (v_settings->>'registered')::boolean;
  ELSE
    IF v_inv.doc_type = 'invoice' THEN
      RETURN;  -- Saved before GST details existed: edited under today's rules.
    END IF;
    v_registered := v_inv.doc_type <> 'bill';
  END IF;

  -- Each line's treatment: the one it had on this invoice before the edit, else its item's.
  UPDATE public.invoice_trl it
     SET gst_treatment = COALESCE(v_before->'lines'->>(it.disp_trl_id::text), itm.gst_treatment, 'taxable')
    FROM public.dispatch_trl dt
    JOIN public.goodsreceived_trl grt ON grt.id = dt.gr_trl_id
    LEFT JOIN public.items itm ON itm.id = grt.item_id
   WHERE it.invoice_id = p_invoice_id AND dt.id = it.disp_trl_id
     AND it.gst_treatment IS DISTINCT FROM COALESCE(v_before->'lines'->>(it.disp_trl_id::text), itm.gst_treatment, 'taxable');

  -- The customer as the document shows it: taken now for a new document or another customer, else kept.
  IF p_new OR v_before IS NULL OR v_before->>'customer_id' IS DISTINCT FROM v_inv.customer_id::text THEN
    v_customer := COALESCE(warehouse_security.gst_customer(v_inv.customer_id), '{}'::jsonb);
  ELSE
    v_customer := jsonb_build_object('gstin', v_inv.gst_customer_gstin, 'state_code', v_inv.gst_customer_state,
                                     'address', v_inv.gst_customer_address);
  END IF;

  SELECT count(*) FILTER (WHERE t.gst_treatment = 'exempt_agri'), count(*) FILTER (WHERE t.gst_treatment IS DISTINCT FROM 'exempt_agri')
    INTO v_exempt, v_taxable
    FROM public.invoice_trl t WHERE t.invoice_id = p_invoice_id;
  v_kind := warehouse_security.gst_document_kind(true, v_registered, v_customer->>'gstin' IS NOT NULL, v_exempt, v_taxable);
  IF v_kind = 'split' AND NOT p_new THEN
    RAISE EXCEPTION 'rate_fail' USING ERRCODE = 'P0001', DETAIL = warehouse_security.refuse('EDIT_NEEDS_TWO_DOCUMENTS',
      'These lines need a tax invoice and a separate bill of supply. Keep only the taxable lines or only the exempt ones, or delete this invoice and make it again.',
      jsonb_build_object('invoice_id', p_invoice_id, 'exempt_lines', v_exempt, 'taxable_lines', v_taxable))::text;
  END IF;
  v_doc := CASE WHEN v_kind = 'split' THEN 'tax_invoice' ELSE v_kind END;

  IF p_new THEN
    UPDATE public.invoice SET
        gst_supplier_legal_name = v_settings->>'legal_name',
        gst_supplier_address = v_settings->>'address',
        gst_supplier_gstin = CASE WHEN v_registered THEN v_settings->>'gstin' END,
        gst_supplier_state = CASE WHEN v_registered THEN v_settings->>'state_code' END,
        gst_sac_storage = CASE WHEN v_registered THEN v_settings->>'sac_storage' END,
        gst_sac_labour = CASE WHEN v_registered THEN v_settings->>'sac_labour' END
     WHERE id = p_invoice_id
    RETURNING * INTO v_inv;
  END IF;

  v_pos := COALESCE(v_customer->>'state_code', v_inv.gst_supplier_state);
  v_head := CASE WHEN v_doc IN ('tax_invoice', 'invoice_cum_bos')
                 THEN CASE WHEN v_pos IS NOT DISTINCT FROM v_inv.gst_supplier_state THEN 'cgst_sgst' ELSE 'igst' END END;
  UPDATE public.invoice SET
      doc_type = v_doc,
      gst_customer_gstin = v_customer->>'gstin',
      gst_customer_state = v_customer->>'state_code',
      gst_customer_address = v_customer->>'address',
      gst_place_of_supply = CASE WHEN v_head IS NOT NULL THEN v_pos END,
      gst_tax_head = v_head,
      -- The split is worked out again after the header (invoice_gst_amounts); cleared here so the check constraint holds meanwhile.
      cgst_amount = NULL, sgst_amount = NULL, igst_amount = NULL
   WHERE id = p_invoice_id;

  -- No tax on an exempt line, nor on any line of a bill.
  UPDATE public.invoice_trl SET tax = 0
   WHERE invoice_id = p_invoice_id AND tax IS DISTINCT FROM 0
     AND (NOT v_registered OR gst_treatment = 'exempt_agri');

  IF v_kind = 'split' THEN
    v_second_no := v_inv.inv_no + 1;
    IF v_second_no > warehouse_security.invoice_number_max() THEN
      RAISE EXCEPTION 'rate_fail' USING ERRCODE = 'P0001', DETAIL = warehouse_security.refuse('NUMBER_OUT_OF_RANGE',
        format('This save makes 2 documents and needs invoice numbers %s and %s; invoice numbers end at %s.',
               v_inv.inv_no, v_second_no, warehouse_security.invoice_number_max()),
        jsonb_build_object('number', v_second_no::text, 'documents', 2))::text;
    END IF;
    IF EXISTS (SELECT 1 FROM public.invoice x WHERE x.inv_fin_year = v_inv.inv_fin_year AND x.inv_no = v_second_no) THEN
      RAISE EXCEPTION 'rate_fail' USING ERRCODE = 'P0001', DETAIL = warehouse_security.refuse('NUMBER_TAKEN',
        format('This save makes 2 documents and needs invoice numbers %s and %s, but %s is already used in financial year %s.',
               v_inv.inv_no, v_second_no, v_second_no, v_inv.inv_fin_year),
        jsonb_build_object('number', v_second_no::text, 'documents', 2))::text;
    END IF;
    INSERT INTO public.invoice (
        inv_fin_year, inv_no, gr_id, gr_no, customer_id, customer_name, inv_name, inv_date,
        labour, tax_amount, total, discount, one_time_charge, pricing_mode, notes, created_by, is_auto_generated, duration_mode,
        charge_step_days, charge_minimum_days, total_rounding,
        doc_type, linked_invoice_id, gst_supplier_legal_name, gst_supplier_address, gst_supplier_gstin, gst_supplier_state,
        gst_sac_storage, gst_sac_labour, gst_customer_gstin, gst_customer_state, gst_customer_address)
    SELECT i.inv_fin_year, v_second_no, i.gr_id, i.gr_no, i.customer_id, i.customer_name, i.inv_name, i.inv_date,
           0, 0, 0, 0, i.one_time_charge, i.pricing_mode, i.notes, i.created_by, i.is_auto_generated, i.duration_mode,
           i.charge_step_days, i.charge_minimum_days, i.total_rounding,
           'bill_of_supply', i.id, i.gst_supplier_legal_name, i.gst_supplier_address, i.gst_supplier_gstin, i.gst_supplier_state,
           i.gst_sac_storage, i.gst_sac_labour, i.gst_customer_gstin, i.gst_customer_state, i.gst_customer_address
      FROM public.invoice i WHERE i.id = p_invoice_id
    RETURNING id INTO v_second;
    UPDATE public.invoice_trl SET invoice_id = v_second WHERE invoice_id = p_invoice_id AND gst_treatment = 'exempt_agri';
    UPDATE public.invoice SET linked_invoice_id = v_second WHERE id = p_invoice_id;
    PERFORM warehouse_security.check_discount_total(warehouse_security.recalculate_invoice_header(v_second));
    PERFORM warehouse_security.invoice_gst_amounts(v_second);
  END IF;
END $$;
ALTER FUNCTION warehouse_security.apply_invoice_gst(uuid, boolean) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION warehouse_security.apply_invoice_gst(uuid, boolean) FROM PUBLIC;

-- The document's GST facts for the readers: doc_type and linked_invoice always; gst for every type but 'invoice'.
CREATE FUNCTION warehouse_security.invoice_gst_json(p_invoice_id uuid) RETURNS jsonb
    LANGUAGE sql STABLE
    SET search_path TO 'pg_catalog', 'public'
    AS $$
  SELECT jsonb_build_object(
    'doc_type', i.doc_type,
    'linked_invoice', (SELECT jsonb_build_object('id', l.id, 'inv_no', l.inv_no, 'inv_fin_year', l.inv_fin_year, 'doc_type', l.doc_type,
                                                 'total', l.total, 'cancelled', l.cancelled_at IS NOT NULL)
                         FROM public.invoice l WHERE l.id = i.linked_invoice_id AND l.deleted_at IS NULL),
    'gst', CASE WHEN i.doc_type = 'invoice' THEN NULL ELSE jsonb_build_object(
      'supplier', jsonb_build_object('legal_name', i.gst_supplier_legal_name, 'address', i.gst_supplier_address,
                                     'gstin', i.gst_supplier_gstin, 'state_code', i.gst_supplier_state,
                                     'state_name', warehouse_security.gst_state_name(i.gst_supplier_state)),
      'customer', jsonb_build_object('gstin', i.gst_customer_gstin, 'state_code', i.gst_customer_state,
                                     'state_name', warehouse_security.gst_state_name(i.gst_customer_state), 'address', i.gst_customer_address),
      'place_of_supply', CASE WHEN i.gst_place_of_supply IS NOT NULL THEN jsonb_build_object('code', i.gst_place_of_supply,
                                'name', warehouse_security.gst_state_name(i.gst_place_of_supply)) END,
      'tax_head', i.gst_tax_head,
      'sac_storage', i.gst_sac_storage,
      'sac_labour', i.gst_sac_labour,
      'cgst_amount', i.cgst_amount,
      'sgst_amount', i.sgst_amount,
      'igst_amount', i.igst_amount,
      'reverse_charge', CASE WHEN i.gst_tax_head IS NOT NULL THEN false END,
      'lines', COALESCE((SELECT jsonb_agg(jsonb_build_object('id', t.id, 'disp_trl_id', t.disp_trl_id, 'gst_treatment', t.gst_treatment,
                                                             'taxable_value', t.taxable_value, 'tax_amount', t.line_tax,
                                                             'cgst_amount', t.cgst_amount, 'sgst_amount', t.sgst_amount,
                                                             'igst_amount', t.igst_amount)
                                          ORDER BY uuid_extract_timestamp(t.id), t.id)
                           FROM public.invoice_trl t WHERE t.invoice_id = i.id), '[]'::jsonb)) END)
  FROM public.invoice i WHERE i.id = p_invoice_id
$$;
ALTER FUNCTION warehouse_security.invoice_gst_json(uuid) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION warehouse_security.invoice_gst_json(uuid) FROM PUBLIC;

-- The documents of a save: the invoice and its live other document, by number.
CREATE FUNCTION warehouse_security.invoice_documents_json(p_invoice_id uuid) RETURNS jsonb
    LANGUAGE sql STABLE
    SET search_path TO 'pg_catalog', 'public'
    AS $$
  SELECT COALESCE(jsonb_agg(jsonb_build_object('invoice_id', d.id, 'inv_no', d.inv_no, 'inv_fin_year', d.inv_fin_year,
                                               'doc_type', d.doc_type, 'total', d.total) ORDER BY d.inv_no), '[]'::jsonb)
    FROM public.invoice d
   WHERE d.deleted_at IS NULL
     AND (d.id = p_invoice_id OR d.id = (SELECT f.linked_invoice_id FROM public.invoice f WHERE f.id = p_invoice_id))
$$;
ALTER FUNCTION warehouse_security.invoice_documents_json(uuid) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION warehouse_security.invoice_documents_json(uuid) FROM PUBLIC;

-- The review step: which document(s) the chosen dispatch lines of a GRN make, with each document's figures before any discount (a
-- discount goes on the first document). p_invoice_id: the invoice being edited (its own type, details and line treatments decide).
CREATE FUNCTION public.preview_invoice_documents(p_gr_id uuid, p_disp_trl_ids uuid[], p_invoice_id uuid DEFAULT NULL::uuid,
                                                 p_duration_mode text DEFAULT NULL::text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'pg_temp'
    AS $$
DECLARE
  v_inv public.invoice;
  v_form jsonb;
  v_rounding text;
  v_saved boolean;
  v_registered boolean;
  v_customer jsonb;
  v_customer_id uuid;
  v_supplier_state text;
  v_exempt integer;
  v_taxable integer;
  v_kind text;
  v_pos text;
  v_docs jsonb;
  v_lines jsonb;
BEGIN
  PERFORM warehouse_security.authorize_rpc('preview_invoice_documents', jsonb_build_object('p_invoice_id', p_invoice_id));
  IF p_disp_trl_ids IS NULL OR cardinality(p_disp_trl_ids) = 0 THEN
    RETURN jsonb_build_object('success', false, 'error', 'Choose at least one dispatch line');
  END IF;
  IF p_invoice_id IS NOT NULL THEN
    SELECT * INTO v_inv FROM public.invoice i WHERE i.id = p_invoice_id AND i.deleted_at IS NULL AND i.cancelled_at IS NULL;
    IF NOT FOUND THEN
      RETURN jsonb_build_object('success', false, 'error', 'Invoice not found');
    END IF;
  END IF;
  SELECT g.customer_id INTO v_customer_id FROM public.goodsreceived g WHERE g.id = p_gr_id AND g.deleted_at IS NULL;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'GRN not found');
  END IF;

  PERFORM set_config('warehouse.form_invoice_id', COALESCE(p_invoice_id::text, ''), true);
  v_form := public.build_invoice_form_lines(p_gr_id, p_duration_mode);
  v_rounding := (warehouse_security.form_charging_rule()).rounding;
  -- The chosen lines with their treatment, read while the edited invoice is the form's.
  IF v_form->>'success' = 'true' THEN
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
             'dt_id', e->>'dispatches_items_id',
             'item_name', e->>'grn_items_item_name',
             'treatment', warehouse_security.gst_line_treatment((e->>'grn_items_item_id')::uuid, (e->>'dispatches_items_id')::uuid),
             'base', COALESCE((e->>'storage_amount')::numeric, 0)
                     + CASE WHEN e->>'grn_items_pricing_mode' = 'ONE_TIME' THEN 0
                            ELSE round(COALESCE((e->>'labour_rate')::numeric, 0) * COALESCE((e->>'dispatches_items_disp_qty')::numeric, 0), 2) END,
             'tax_percent', COALESCE((e->>'tax_percent')::numeric, 0))), '[]'::jsonb)
      INTO v_lines
      FROM jsonb_array_elements(v_form->'items') e
     WHERE (e->>'dispatches_items_id')::uuid = ANY (p_disp_trl_ids);
  END IF;
  PERFORM set_config('warehouse.form_invoice_id', '', true);
  IF v_form->>'success' IS DISTINCT FROM 'true' THEN
    RETURN v_form;
  END IF;
  IF jsonb_array_length(v_lines) <> (SELECT count(DISTINCT x) FROM unnest(p_disp_trl_ids) x) THEN
    RETURN warehouse_security.refuse('UNKNOWN_LINE', 'A dispatch line is not on this GRN''s invoice form.');
  END IF;

  IF p_invoice_id IS NOT NULL THEN
    v_saved := v_inv.doc_type <> 'invoice';
    v_registered := v_inv.doc_type <> 'bill';
    v_supplier_state := v_inv.gst_supplier_state;
    v_customer := CASE WHEN v_inv.customer_id = v_customer_id
                       THEN jsonb_build_object('gstin', v_inv.gst_customer_gstin, 'state_code', v_inv.gst_customer_state)
                       ELSE warehouse_security.gst_customer(v_customer_id) END;
  ELSE
    v_saved := (warehouse_security.gst_settings()->>'saved')::boolean;
    v_registered := (warehouse_security.gst_settings()->>'registered')::boolean;
    v_supplier_state := CASE WHEN v_registered THEN warehouse_security.gst_settings()->>'state_code' END;
    v_customer := warehouse_security.gst_customer(v_customer_id);
  END IF;
  SELECT count(*) FILTER (WHERE l.treatment = 'exempt_agri'), count(*) FILTER (WHERE l.treatment IS DISTINCT FROM 'exempt_agri')
    INTO v_exempt, v_taxable
    FROM jsonb_to_recordset(v_lines) AS l(dt_id uuid, item_name text, treatment text, base numeric, tax_percent numeric);
  v_kind := warehouse_security.gst_document_kind(v_saved, v_registered, v_customer->>'gstin' IS NOT NULL, v_exempt, v_taxable);
  IF v_kind = 'split' AND p_invoice_id IS NOT NULL THEN
    RETURN warehouse_security.refuse('EDIT_NEEDS_TWO_DOCUMENTS',
      'These lines need a tax invoice and a separate bill of supply. Keep only the taxable lines or only the exempt ones, or delete this invoice and make it again.',
      jsonb_build_object('invoice_id', p_invoice_id, 'exempt_lines', v_exempt, 'taxable_lines', v_taxable));
  END IF;
  v_pos := COALESCE(v_customer->>'state_code', v_supplier_state);

  WITH grouped AS (
    SELECT CASE WHEN v_kind = 'split' THEN CASE WHEN l.treatment = 'exempt_agri' THEN 'bill_of_supply' ELSE 'tax_invoice' END
                ELSE v_kind END AS doc_type,
           l.*
      FROM jsonb_to_recordset(v_lines) AS l(dt_id uuid, item_name text, treatment text, base numeric, tax_percent numeric)
  ), sums AS (
    SELECT g.doc_type,
           jsonb_agg(g.dt_id ORDER BY g.dt_id) AS lines,
           jsonb_agg(DISTINCT g.item_name) AS item_names,
           sum(g.base)::numeric(12,2) AS subtotal,
           warehouse_security.round_invoice_total(sum(g.base * g.tax_percent / 100.0), v_rounding)::numeric(12,2) AS tax
      FROM grouped g GROUP BY g.doc_type
  ), heads AS (
    SELECT s.*, CASE WHEN s.doc_type IN ('tax_invoice', 'invoice_cum_bos')
                     THEN CASE WHEN v_pos IS NOT DISTINCT FROM v_supplier_state THEN 'cgst_sgst' ELSE 'igst' END END AS head
      FROM sums s
  )
  SELECT jsonb_agg(jsonb_build_object(
           'doc_type', h.doc_type, 'disp_trl_ids', h.lines, 'item_names', h.item_names,
           'subtotal', h.subtotal, 'tax', h.tax,
           'total', warehouse_security.round_invoice_total(h.subtotal + h.tax, v_rounding)::numeric(12,2),
           'tax_head', h.head,
           'place_of_supply', CASE WHEN h.head IS NOT NULL THEN v_pos END,
           'cgst_amount', CASE WHEN h.head = 'cgst_sgst' THEN warehouse_security.gst_half(h.tax) END,
           'sgst_amount', CASE WHEN h.head = 'cgst_sgst' THEN h.tax - warehouse_security.gst_half(h.tax) END,
           'igst_amount', CASE WHEN h.head = 'igst' THEN h.tax END)
         ORDER BY CASE h.doc_type WHEN 'bill_of_supply' THEN 1 ELSE 0 END)
    INTO v_docs FROM heads h;

  RETURN jsonb_build_object('success', true, 'documents', v_docs, 'document_count', jsonb_array_length(v_docs),
    'current_doc_type', v_inv.doc_type,
    'type_changes', p_invoice_id IS NOT NULL AND v_kind IS DISTINCT FROM v_inv.doc_type);
END $$;
ALTER FUNCTION public.preview_invoice_documents(uuid, uuid[], uuid, text) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION public.preview_invoice_documents(uuid, uuid[], uuid, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.preview_invoice_documents(uuid, uuid[], uuid, text) TO authenticated, service_role;

-- Section 6: the invoice functions
CREATE FUNCTION pg_temp.patch_function(p_function regprocedure, p_old text[], p_new text[], p_drop_first boolean DEFAULT false) RETURNS void
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
  -- A signature change: the old function goes first, so no second overload remains for PostgREST.
  IF p_drop_first THEN
    EXECUTE format('DROP FUNCTION %s', p_function);
  END IF;
  EXECUTE v_def;
END $$;

-- 6.1 The invoice form: no tax on a line that charges none, and an edit does not offer the lines of the invoice's other document.
SELECT pg_temp.patch_function('public.build_invoice_form_lines(uuid, text)'::regprocedure, ARRAY[
$m$COALESCE(rt.src_tax, 0)::numeric(5,2) AS tax_percent$m$,
$m$IS DISTINCT FROM NULLIF(current_setting('warehouse.form_invoice_id', true), '')))
    ),$m$
], ARRAY[
$m$CASE WHEN warehouse_security.gst_zero_tax(r.item_id, r.dt_id) THEN 0::numeric(5,2)  -- Migration 173: exempt line, or a bill.
                        ELSE COALESCE(rt.src_tax, 0)::numeric(5,2) END AS tax_percent$m$,
$m$IS DISTINCT FROM NULLIF(current_setting('warehouse.form_invoice_id', true), '')))
          -- Migration 173: an edit does not offer the lines of the invoice's other document (tax invoice and bill of supply).
          AND NOT warehouse_security.gst_on_form_partner(dt.id)
    ),$m$
]);

-- 6.2 Save: the document after the lines are written; the total check adds a second document; the answer names the documents.
SELECT pg_temp.patch_function('public.save_invoice_internal(uuid, jsonb, jsonb[])'::regprocedure, ARRAY[
$m$    PERFORM warehouse_security.check_discount_total(warehouse_security.recalculate_invoice_header(v_final_invoice_id));$m$,
$m$SELECT i.total INTO v_total_now FROM invoice i WHERE i.id = v_final_invoice_id;$m$,
$m$v_new_items_count,
        'resolved_errors_count'$m$
], ARRAY[
$m$    -- Migration 173: the GST document (nothing changes until GST details are saved); a two-document save writes the second here.
    PERFORM warehouse_security.apply_invoice_gst(v_final_invoice_id, true);
    PERFORM warehouse_security.check_discount_total(
        warehouse_security.recalculate_invoice_header(v_final_invoice_id));
    PERFORM warehouse_security.invoice_gst_amounts(v_final_invoice_id);$m$,
$m$SELECT sum(i.total) INTO v_total_now FROM invoice i
         WHERE i.id = v_final_invoice_id OR i.linked_invoice_id = v_final_invoice_id;  -- Migration 173: both documents of a two-document save.$m$,
$m$v_new_items_count,
        'doc_type', (SELECT x.doc_type FROM invoice x WHERE x.id = v_final_invoice_id),
        'linked_invoice_id', (SELECT x.linked_invoice_id FROM invoice x WHERE x.id = v_final_invoice_id),
        'documents', warehouse_security.invoice_documents_json(v_final_invoice_id),
        'resolved_errors_count'$m$
]);

-- 6.3 A resend of a two-document save is answered from the kept answer only while both documents exist.
SELECT pg_temp.patch_function('public.save_invoice(uuid, jsonb, jsonb[])'::regprocedure, ARRAY[
$m$AND EXISTS (SELECT 1 FROM invoice i WHERE i.id::text = v_cached_response->>'invoice_id' AND i.deleted_at IS NULL) THEN$m$
], ARRAY[
$m$AND EXISTS (SELECT 1 FROM invoice i WHERE i.id::text = v_cached_response->>'invoice_id' AND i.deleted_at IS NULL)
           -- Migration 173: and the second document of a two-document save.
           AND (v_cached_response->>'linked_invoice_id' IS NULL
                OR EXISTS (SELECT 1 FROM invoice l WHERE l.id::text = v_cached_response->>'linked_invoice_id' AND l.deleted_at IS NULL)) THEN$m$
]);

SELECT pg_temp.patch_function('public.get_submission_result(text)'::regprocedure, ARRAY[
$m$WHEN 'save_invoice' THEN EXISTS ($m$
], ARRAY[
$m$WHEN 'save_invoice' THEN (k.response->>'linked_invoice_id' IS NULL  -- Migration 173: both documents of a two-document save.
                                 OR EXISTS (SELECT 1 FROM invoice l WHERE l.id::text = k.response->>'linked_invoice_id' AND l.deleted_at IS NULL))
                            AND EXISTS ($m$
]);

-- 6.4 Edit: what the invoice had before, then the document after the lines are written.
SELECT pg_temp.patch_function('public.update_invoice(uuid, jsonb, jsonb[])'::regprocedure, ARRAY[
$m$'Invoice not found');
    END IF;

    -- D1 (migration 121)$m$,
$m$    v_new_totals := warehouse_security.recalculate_invoice_header(p_invoice_id);$m$,
$m$'items_count', v_items_count,
        'duration_mode'$m$
], ARRAY[
$m$'Invoice not found');
    END IF;
    -- Migration 173: the customer and the lines' GST treatment before the edit (an edit keeps them for the lines it had).
    PERFORM warehouse_security.note_invoice_gst_before_edit(p_invoice_id);

    -- D1 (migration 121)$m$,
$m$    -- Migration 173: the GST document of the edited lines (an invoice saved before GST details existed is left as it is).
    PERFORM warehouse_security.apply_invoice_gst(p_invoice_id, false);
    v_new_totals := warehouse_security.recalculate_invoice_header(
        p_invoice_id);
    PERFORM warehouse_security.invoice_gst_amounts(p_invoice_id);$m$,
$m$'items_count', v_items_count,
        'doc_type', (SELECT x.doc_type FROM invoice x WHERE x.id = p_invoice_id),
        'duration_mode'$m$
]);

-- 6.5 The invoice list: doc_type on each row and the p_doc_type filter (signature change, the old function is dropped).
SELECT pg_temp.patch_function('public.get_invoices_list(integer, integer, uuid, integer, text, text, text, text, integer, integer, text, timestamp with time zone, timestamp with time zone, uuid[], text)'::regprocedure, ARRAY[
$m$p_payment_status text DEFAULT NULL::text)
 RETURNS jsonb$m$,
$m$USING ERRCODE = '42501';
    END IF;
    -- Which customers$m$,
$m$= $17)
            AND ($6 IS NULL$m$,
$m$'cancel_reason', i.cancel_reason,
                       'total_qty'$m$,
$m$p_sort_field, p_sort_direction, p_payment_status, COALESCE(v_show_payments, false);$m$
], ARRAY[
$m$p_payment_status text DEFAULT NULL::text, p_doc_type text DEFAULT NULL::text)
 RETURNS jsonb$m$,
$m$USING ERRCODE = '42501';
    END IF;
    -- Migration 173: the document type filter.
    IF p_doc_type IS NOT NULL AND p_doc_type NOT IN ('invoice', 'bill', 'bill_of_supply', 'tax_invoice', 'invoice_cum_bos') THEN
        RAISE EXCEPTION 'p_doc_type must be invoice, bill, bill_of_supply, tax_invoice or invoice_cum_bos' USING ERRCODE = '22023';
    END IF;
    -- Which customers$m$,
$m$= $17)
            AND ($19 IS NULL OR i.doc_type = $19)
            AND ($6 IS NULL$m$,
$m$'cancel_reason', i.cancel_reason,
                       'doc_type', i.doc_type,
                       'linked_invoice_id', i.linked_invoice_id,
                       'total_qty'$m$,
$m$p_sort_field, p_sort_direction, p_payment_status, COALESCE(v_show_payments, false), p_doc_type;$m$
], true);
ALTER FUNCTION public.get_invoices_list(integer, integer, uuid, integer, text, text, text, text, integer, integer, text, timestamp with time zone, timestamp with time zone, uuid[], text, text) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION public.get_invoices_list(integer, integer, uuid, integer, text, text, text, text, integer, integer, text, timestamp with time zone, timestamp with time zone, uuid[], text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.get_invoices_list(integer, integer, uuid, integer, text, text, text, text, integer, integer, text, timestamp with time zone, timestamp with time zone, uuid[], text, text) TO authenticated, service_role;

-- 6.6 The pre-printed print: the type, the tax head, the stored CGST and SGST and the facility's state the invoice was made with.
SELECT pg_temp.patch_function('public.get_invoice_range_for_print(text, text, integer, integer)'::regprocedure, ARRAY[
$m$as discount,
            i.created_by$m$,
$m$iwc.gstin, iwc.created_by
    ),$m$,
$m$'gstin', iwi.gstin,
                'trl'$m$
], ARRAY[
$m$as discount,
            i.doc_type, i.gst_tax_head, i.cgst_amount, i.sgst_amount, i.gst_supplier_state,  -- Migration 173
            i.created_by$m$,
$m$iwc.gstin, iwc.created_by,
            iwc.doc_type, iwc.gst_tax_head, iwc.cgst_amount, iwc.sgst_amount, iwc.gst_supplier_state
    ),$m$,
$m$'gstin', iwi.gstin,
                'doc_type', iwi.doc_type,
                'gst_tax_head', iwi.gst_tax_head,
                'cgst_amount', iwi.cgst_amount,
                'sgst_amount', iwi.sgst_amount,
                'supplier_state_name', warehouse_security.gst_state_name(iwi.gst_supplier_state),
                'trl'$m$
]);

-- 6.7 The two documents of a two-document save are deleted together (owner decision 2026-11-07): delete_invoice refuses one of a pair
-- (INVOICE_PAIR), delete_invoice_pair below deletes both in one transaction.
SELECT pg_temp.patch_function('public.delete_invoice(uuid, timestamp with time zone)'::regprocedure, ARRAY[
$m$  END IF;

  -- The lines first (invoice_trl.invoice_id$m$
], ARRAY[
$m$  END IF;
  -- Migration 173: one document of a pair is deleted only with the other (delete_invoice_pair names both in warehouse.invoice_pair_delete).
  IF EXISTS (SELECT 1 FROM invoice l JOIN invoice i ON i.linked_invoice_id = l.id
              WHERE i.id = p_invoice_id AND l.deleted_at IS NULL)
     AND position(p_invoice_id::text IN COALESCE(current_setting('warehouse.invoice_pair_delete', true), '')) = 0 THEN
    RETURN warehouse_security.refuse('INVOICE_PAIR', 'This invoice was saved together with another document. Delete both together.',
      jsonb_build_object('invoice_id', p_invoice_id, 'inv_no', v_inv_no, 'inv_fin_year', v_fin_year,
                         'linked_invoice', (SELECT jsonb_build_object('id', l.id, 'inv_no', l.inv_no, 'inv_fin_year', l.inv_fin_year, 'doc_type', l.doc_type)
                                              FROM invoice l JOIN invoice i ON i.linked_invoice_id = l.id WHERE i.id = p_invoice_id)));
  END IF;
  -- The lines first (invoice_trl.invoice_id$m$
]);

DROP FUNCTION pg_temp.patch_function(regprocedure, text[], text[], boolean);

-- Both documents of a pair, in one transaction: each through delete_invoice (its locks, version check, payment refusal and audit rows);
-- a refusal of either deletes neither and is the answer. p_expected_updated_at is the version of p_invoice_id the screen read,
-- p_linked_expected_updated_at that of the other document (either may be NULL: no check).
CREATE FUNCTION public.delete_invoice_pair(p_invoice_id uuid, p_expected_updated_at timestamptz DEFAULT NULL,
                                           p_linked_expected_updated_at timestamptz DEFAULT NULL) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'extensions', 'utils', 'pg_temp'
    AS $$
DECLARE
  v_linked uuid;
  v_first jsonb;
  v_second jsonb;
  v_detail text;
BEGIN
  PERFORM warehouse_security.authorize_rpc('delete_invoice_pair', jsonb_build_object('p_invoice_id', p_invoice_id));
  IF COALESCE(warehouse_security.active_role(), '') NOT IN ('admin', 'supervisor') AND auth.jwt()->>'role' IS DISTINCT FROM 'service_role' THEN
    RAISE EXCEPTION 'Administrator required' USING ERRCODE = '42501';
  END IF;
  PERFORM pg_advisory_xact_lock(71040);
  SELECT i.linked_invoice_id INTO v_linked FROM invoice i WHERE i.id = p_invoice_id AND i.deleted_at IS NULL FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'Invoice not found');
  END IF;
  IF v_linked IS NULL OR NOT EXISTS (SELECT 1 FROM invoice l WHERE l.id = v_linked AND l.deleted_at IS NULL) THEN
    RETURN warehouse_security.refuse('NOT_A_PAIR', 'This invoice has no other document. Delete it on its own.',
      jsonb_build_object('invoice_id', p_invoice_id));
  END IF;
  PERFORM 1 FROM invoice l WHERE l.id = v_linked FOR UPDATE;
  BEGIN
    PERFORM set_config('warehouse.invoice_pair_delete', p_invoice_id::text || ',' || v_linked::text, true);
    v_first := public.delete_invoice(p_invoice_id, p_expected_updated_at);
    IF v_first->>'success' IS DISTINCT FROM 'true' THEN
      RAISE EXCEPTION 'pair_fail' USING DETAIL = v_first::text;
    END IF;
    v_second := public.delete_invoice(v_linked, p_linked_expected_updated_at);
    IF v_second->>'success' IS DISTINCT FROM 'true' THEN
      RAISE EXCEPTION 'pair_fail' USING DETAIL = v_second::text;
    END IF;
    PERFORM set_config('warehouse.invoice_pair_delete', '', true);
  EXCEPTION WHEN OTHERS THEN
    -- The block is rolled back: neither document is deleted. The refusal of the one that failed is the answer.
    PERFORM set_config('warehouse.invoice_pair_delete', '', true);
    IF SQLERRM = 'pair_fail' THEN
      GET STACKED DIAGNOSTICS v_detail = PG_EXCEPTION_DETAIL;
      RETURN v_detail::jsonb || jsonb_build_object('deleted', 0);
    END IF;
    RAISE;
  END;
  RETURN jsonb_build_object('success', true, 'message', 'Both documents deleted', 'deleted', 2, 'invoices', jsonb_build_array(v_first, v_second));
END $$;
ALTER FUNCTION public.delete_invoice_pair(uuid, timestamptz, timestamptz) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION public.delete_invoice_pair(uuid, timestamptz, timestamptz) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.delete_invoice_pair(uuid, timestamptz, timestamptz) TO authenticated, service_role;

NOTIFY pgrst, 'reload schema';
