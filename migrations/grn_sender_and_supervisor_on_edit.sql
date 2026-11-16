-- Migration "GRN sender and supervisor on edit" (WH-248). Its number is taken when the work is assembled for main. Written against the
-- functions as migrations 190 (warehouse_security.update_imported_grn_rates) and 192 (public.import_history) left them; update_grn and
-- save_grn are definition files (migrations/definitions/) and change with this migration.
--  1. warehouse_security.grn_save_keeps_stored(...): whether an update_grn call changes nothing but the rates. It is the comparison that
--     migration 190 wrote inside update_imported_grn_rates (a field not sent is as stored, a field sent equals what is stored: text with blank
--     and NULL alike, the date on the same India day; every stored line once, unchanged; every photo sent is one the GRN has), moved here so
--     that update_grn uses the same one for an ordinary GRN: a save that changes only the rates may leave an empty sender name or supervisor
--     as stored (WH-248). Two photo conditions are added, which an imported GRN (it has no photos) always meets: a photo sent keeps its line
--     (update_grn moves a photo to the line it is sent with), and a photo list that is not empty names every confirmed photo of the GRN
--     (update_grn removes the ones it does not name). update_imported_grn_rates now calls it; what it accepts and refuses is unchanged.
--  2. import_history: a GRN whose sender is blank in grns.csv is imported with the customer's name as its sender name (WH-248: one business
--     per GRN, the sender is the customer). The supervisor stays empty (the file names none). The content hash is still made from the file as
--     staged (s.sender), so running the same file again finds the GRN already there, and a GRN imported earlier with no sender is left as it
--     is (no backfill).
-- Both functions are patched in place by marker count; a second run fails on the count. No role is created, altered or dropped.

-- ===== 1. the comparison =====
-- update_grn's arguments as it receives them, before its own trimming (a blank sent is '' here, an omitted value NULL). False when the GRN
-- is not found or an argument does not read as its type.
CREATE FUNCTION warehouse_security.grn_save_keeps_stored(
    p_grn_id uuid, p_gr_no character varying, p_date timestamp with time zone, p_customer_id uuid, p_customer_name character varying,
    p_sender_id uuid, p_sender_name character varying, p_supervisor_id uuid, p_supervisor_name character varying,
    p_registration character varying, p_note character varying, p_leon boolean, p_pricing_mode character varying, p_items jsonb,
    p_images jsonb, p_duration_mode character varying)
    RETURNS boolean
    LANGUAGE plpgsql
    SET search_path TO 'pg_catalog', 'public'
    AS $$
DECLARE
  g public.goodsreceived;
  v_same boolean;
  v_norm text;
BEGIN
  SELECT * INTO g FROM public.goodsreceived WHERE id = p_grn_id;
  IF NOT FOUND THEN
    RETURN false;
  END IF;
  v_norm := NULLIF(regexp_replace(regexp_replace(p_registration, '^[\s ]+|[\s ]+$', '', 'g'), '[\s ]+', ' ', 'g'), '');
  BEGIN
    v_same :=
          (p_gr_no IS NULL OR p_gr_no = g.gr_no)
      AND (p_date IS NULL OR warehouse_security.business_date(p_date) = warehouse_security.business_date(g.date))
      AND (p_customer_id IS NULL OR p_customer_id = g.customer_id)
      AND (p_customer_name IS NULL OR btrim(p_customer_name) IN (btrim(COALESCE(g.customer_name, '')),
                                                                (SELECT btrim(c.name) FROM public.customers c WHERE c.id = g.customer_id)))
      AND (p_sender_id IS NULL OR p_sender_id IS NOT DISTINCT FROM g.sender_id)
      AND (p_sender_name IS NULL OR COALESCE(NULLIF(btrim(p_sender_name), ''), '') = COALESCE(btrim(g.sender_name), ''))
      AND (p_supervisor_id IS NULL OR p_supervisor_id IS NOT DISTINCT FROM g.supervisor_id)
      AND (p_supervisor_name IS NULL OR COALESCE(NULLIF(btrim(p_supervisor_name), ''), '') = COALESCE(btrim(g.supervisor_name), ''))
      AND (p_registration IS NULL OR COALESCE(v_norm, '') = COALESCE(g.registration, ''))
      AND (p_note IS NULL OR COALESCE(NULLIF(btrim(p_note), ''), '') = COALESCE(btrim(g.note), ''))
      AND (p_leon IS NULL OR p_leon = COALESCE(g.leon, false))
      AND (p_pricing_mode IS NULL OR upper(p_pricing_mode) = upper(COALESCE(g.pricing_mode, '')))
      AND (p_duration_mode IS NULL OR p_duration_mode = g.duration_mode)
      -- Every stored line once, unchanged.
      AND jsonb_typeof(p_items) = 'array'
      AND jsonb_array_length(p_items) = (SELECT count(*) FROM public.goodsreceived_trl t WHERE t.gr_id = p_grn_id)
      AND (SELECT count(DISTINCT t.id) FROM jsonb_array_elements(p_items) e
             JOIN public.goodsreceived_trl t ON t.gr_id = p_grn_id AND t.id::text = e->>'id'
            WHERE COALESCE(e->>'item_id', e->>'itemId', t.item_id::text) = t.item_id::text
              AND btrim(COALESCE(e->>'item_name', e->>'itemName', t.item_name)) = btrim(t.item_name)
              AND COALESCE(NULLIF(btrim(e->>'packaging'), ''), '') = COALESCE(btrim(t.packaging), '')
              AND (e->>'qty')::integer = t.qty
              AND COALESCE((e->>'weight')::integer, 0) = COALESCE(t.weight, 0)
              AND COALESCE(NULLIF(warehouse_security.ascii_digits(btrim(e->>'rack')), ''), '') = COALESCE(t.rack, '')
              AND COALESCE(NULLIF(warehouse_security.ascii_digits(btrim(COALESCE(e->>'package_mark', e->>'packageMark'))), ''), '')
                  = COALESCE(t.package_mark, ''))
          = jsonb_array_length(p_items)
      -- Every photo sent is one of this GRN and keeps its line; a list that is not empty names every confirmed photo of the GRN.
      AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(COALESCE(p_images, '[]'::jsonb)) e
                       WHERE NOT EXISTS (SELECT 1 FROM public.grn_images i WHERE i.grn_id = p_grn_id AND i.id::text = e->>'id'
                                            AND i.grn_item_id IS NOT DISTINCT FROM
                                                CASE WHEN e->>'image_type' = 'item' THEN (e->>'grn_item_id')::uuid END))
      AND (jsonb_array_length(COALESCE(p_images, '[]'::jsonb)) = 0
           OR NOT EXISTS (SELECT 1 FROM public.grn_images i
                           WHERE i.grn_id = p_grn_id AND i.status = 'confirmed'
                             AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(p_images) e WHERE e->>'id' = i.id::text)));
  EXCEPTION WHEN invalid_text_representation OR numeric_value_out_of_range OR data_exception THEN
    v_same := false;
  END;
  RETURN COALESCE(v_same, false);
END $$;
ALTER FUNCTION warehouse_security.grn_save_keeps_stored(uuid, character varying, timestamp with time zone, uuid, character varying, uuid,
  character varying, uuid, character varying, character varying, character varying, boolean, character varying, jsonb, jsonb,
  character varying) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION warehouse_security.grn_save_keeps_stored(uuid, character varying, timestamp with time zone, uuid, character varying,
  uuid, character varying, uuid, character varying, character varying, character varying, boolean, character varying, jsonb, jsonb,
  character varying) FROM PUBLIC;

-- update_imported_grn_rates asks the function above instead of comparing for itself.
DO $patch$
DECLARE
  v_def text;
  v_count integer;
  v_before text;
  v_after text;
BEGIN
  v_def := pg_get_functiondef('warehouse_security.update_imported_grn_rates(uuid, character varying, timestamp with time zone, uuid, character varying, uuid, character varying, uuid, character varying, character varying, character varying, boolean, character varying, jsonb, jsonb, character varying, text, jsonb, timestamp with time zone)'::regprocedure);
  v_before := $m$  v_norm := NULLIF(regexp_replace(regexp_replace(p_registration, '^[\s ]+|[\s ]+$', '', 'g'), '[\s ]+', ' ', 'g'), '');
  BEGIN
    v_same :=
          (p_gr_no IS NULL OR p_gr_no = g.gr_no)
      AND (p_date IS NULL OR warehouse_security.business_date(p_date) = warehouse_security.business_date(g.date))
      AND (p_customer_id IS NULL OR p_customer_id = g.customer_id)
      AND (p_customer_name IS NULL OR btrim(p_customer_name) IN (btrim(COALESCE(g.customer_name, '')),
                                                                (SELECT btrim(c.name) FROM public.customers c WHERE c.id = g.customer_id)))
      AND (p_sender_id IS NULL OR p_sender_id IS NOT DISTINCT FROM g.sender_id)
      AND (p_sender_name IS NULL OR COALESCE(NULLIF(btrim(p_sender_name), ''), '') = COALESCE(btrim(g.sender_name), ''))
      AND (p_supervisor_id IS NULL OR p_supervisor_id IS NOT DISTINCT FROM g.supervisor_id)
      AND (p_supervisor_name IS NULL OR COALESCE(NULLIF(btrim(p_supervisor_name), ''), '') = COALESCE(btrim(g.supervisor_name), ''))
      AND (p_registration IS NULL OR COALESCE(v_norm, '') = COALESCE(g.registration, ''))
      AND (p_note IS NULL OR COALESCE(NULLIF(btrim(p_note), ''), '') = COALESCE(btrim(g.note), ''))
      AND (p_leon IS NULL OR p_leon = COALESCE(g.leon, false))
      AND (p_pricing_mode IS NULL OR upper(p_pricing_mode) = upper(COALESCE(g.pricing_mode, '')))
      AND (p_duration_mode IS NULL OR p_duration_mode = g.duration_mode)
      -- Every stored line once, unchanged.
      AND jsonb_typeof(p_items) = 'array'
      AND jsonb_array_length(p_items) = (SELECT count(*) FROM public.goodsreceived_trl t WHERE t.gr_id = p_grn_id)
      AND (SELECT count(DISTINCT t.id) FROM jsonb_array_elements(p_items) e
             JOIN public.goodsreceived_trl t ON t.gr_id = p_grn_id AND t.id::text = e->>'id'
            WHERE COALESCE(e->>'item_id', e->>'itemId', t.item_id::text) = t.item_id::text
              AND btrim(COALESCE(e->>'item_name', e->>'itemName', t.item_name)) = btrim(t.item_name)
              AND COALESCE(NULLIF(btrim(e->>'packaging'), ''), '') = COALESCE(btrim(t.packaging), '')
              AND (e->>'qty')::integer = t.qty
              AND COALESCE((e->>'weight')::integer, 0) = COALESCE(t.weight, 0)
              AND COALESCE(NULLIF(warehouse_security.ascii_digits(btrim(e->>'rack')), ''), '') = COALESCE(t.rack, '')
              AND COALESCE(NULLIF(warehouse_security.ascii_digits(btrim(COALESCE(e->>'package_mark', e->>'packageMark'))), ''), '')
                  = COALESCE(t.package_mark, ''))
          = jsonb_array_length(p_items)
      AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(COALESCE(p_images, '[]'::jsonb)) e
                       WHERE NOT EXISTS (SELECT 1 FROM public.grn_images i WHERE i.grn_id = p_grn_id AND i.id::text = e->>'id'));
  EXCEPTION WHEN invalid_text_representation OR numeric_value_out_of_range OR data_exception THEN
    v_same := false;
  END;
  IF NOT COALESCE(v_same, false) OR p_rates IS NULL THEN$m$;
  v_after := $m$  v_same := warehouse_security.grn_save_keeps_stored(p_grn_id, p_gr_no, p_date, p_customer_id, p_customer_name, p_sender_id,
    p_sender_name, p_supervisor_id, p_supervisor_name, p_registration, p_note, p_leon, p_pricing_mode, p_items, p_images, p_duration_mode);
  IF NOT COALESCE(v_same, false) OR p_rates IS NULL THEN$m$;
  v_count := (length(v_def) - length(replace(v_def, v_before, ''))) / length(v_before);
  IF v_count <> 1 THEN RAISE EXCEPTION 'update_imported_grn_rates: expected the comparison once, found % times', v_count; END IF;
  v_def := replace(v_def, v_before, v_after);
  v_before := $m$  v_detail text;
  v_norm text;
BEGIN$m$;
  v_after := $m$  v_detail text;
BEGIN$m$;
  v_count := (length(v_def) - length(replace(v_def, v_before, ''))) / length(v_before);
  IF v_count <> 1 THEN RAISE EXCEPTION 'update_imported_grn_rates: expected the v_norm declaration once, found % times', v_count; END IF;
  v_def := replace(v_def, v_before, v_after);
  EXECUTE v_def;
END
$patch$;

-- ===== 2. the import: a blank sender is the customer's name =====
DO $patch$
DECLARE
  v_def text;
  v_count integer;
  v_before text;
  v_after text;
BEGIN
  v_def := pg_get_functiondef('public.import_history(jsonb, boolean)'::regprocedure);
  v_before := $m$g.customer_id, g.customer_name, g.sender, g.vehicle, g.note,$m$;
  v_after := $m$g.customer_id, g.customer_name,
               CASE WHEN warehouse_security.is_blank_text(g.sender) THEN g.customer_name ELSE g.sender END, g.vehicle, g.note,$m$;
  v_count := (length(v_def) - length(replace(v_def, v_before, ''))) / length(v_before);
  IF v_count <> 1 THEN RAISE EXCEPTION 'import_history: expected the GRN sender marker once, found % times', v_count; END IF;
  v_def := replace(v_def, v_before, v_after);
  EXECUTE v_def;
END
$patch$;
