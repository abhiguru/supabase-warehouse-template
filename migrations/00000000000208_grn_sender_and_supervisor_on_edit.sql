-- Migration 208 (WH-248): GRN sender and supervisor on edit. Written against the
-- functions as migrations 190 (warehouse_security.update_imported_grn_rates) and 192 (public.import_history) left them; update_grn and
-- save_grn are definition files (migrations/definitions/) and change with this migration.
--  1. warehouse_security.grn_save_keeps_stored(..., p_strict): whether an update_grn call changes nothing but the rates. A save that changes
--     only the rates may leave an empty sender name or supervisor as stored (WH-248). Two ways to compare, one function:
--     - p_strict false: the comparison that migration 190 wrote inside update_imported_grn_rates (a field not sent is as stored, a field sent
--       equals what is stored: text with blank and NULL alike, the date on the same India day; every stored line once, unchanged, with the
--       camelCase keys as fallbacks; every photo sent is one the GRN has). update_imported_grn_rates now calls it with false; that path writes
--       nothing but the rates, and what it accepts and refuses is unchanged.
--     - p_strict true, for update_grn (WH-250, WH-251): what update_grn would write against what is stored. A value counts as the same only
--       where the server stores or reads the two alike: sender and supervisor names by WH-237's test on both sides (trimmed_reason, so a name of
--       only tabs, non-breaking or zero-width spaces is empty); the registration normalised on both sides as update_grn stores it (migration
--       130); '' and NULL alike in the note and a line's packaging, rack and package mark; rack and mark with the digits 0-9 on both sides;
--       the same India day for the date; an empty pricing mode as MONTHLY (find_storage_price, apply_grn_rates, update_grn and the invoices
--       charge it as monthly); an empty leon as false (no server code calculates with it; update_grn then stores false). Everything else is
--       compared as written: an item name, packaging or rack with spaces at an end is a change; only the snake_case keys count (update_grn
--       reads no other), so a line sent with packageMark alone clears a stored mark and is a change; a stored empty line weight is a change
--       whatever is sent, 0 or nothing (update_grn writes 0 for both, and find_storage_price finds no rate band for an empty weight). The
--       customer name sent is not compared (update_grn does not write it). On a dispatched line only what update_grn writes there is
--       compared (item, packaging, weight, rack, mark); on any other line also the name and quantity, and its stock must equal its quantity
--       (update_grn sets it so).
--     Both: two photo conditions, which an imported GRN (it has no photos) always meets: a photo sent keeps its line (update_grn moves a photo
--     to the line it is sent with), and a photo list that is not empty names every confirmed photo of the GRN (update_grn removes the ones it
--     does not name).
--  2. import_history: a GRN whose sender is blank in grns.csv is imported with the customer's name as its sender name (WH-248: one business
--     per GRN, the sender is the customer). The supervisor stays empty (the file names none). The content hash is still made from the file as
--     staged (s.sender), so running the same file again finds the GRN already there, and a GRN imported earlier with no sender is left as it
--     is (no backfill).
-- Both functions are patched in place by marker count; a second run fails on the count. No role is created, altered or dropped.

-- ===== 1. the comparison =====
-- update_grn's arguments as it receives them, before its own trimming (a blank sent is '' here, an omitted value NULL). False when the GRN
-- is not found or an argument does not read as its type. p_strict: see the header (true for update_grn, false for an imported GRN).
CREATE FUNCTION warehouse_security.grn_save_keeps_stored(
    p_grn_id uuid, p_gr_no character varying, p_date timestamp with time zone, p_customer_id uuid, p_customer_name character varying,
    p_sender_id uuid, p_sender_name character varying, p_supervisor_id uuid, p_supervisor_name character varying,
    p_registration character varying, p_note character varying, p_leon boolean, p_pricing_mode character varying, p_items jsonb,
    p_images jsonb, p_duration_mode character varying, p_strict boolean)
    RETURNS boolean
    LANGUAGE plpgsql
    SET search_path TO 'pg_catalog', 'public'
    AS $$
DECLARE
  g public.goodsreceived;
  v_same boolean;
  v_norm text;
  v_photos boolean;
BEGIN
  SELECT * INTO g FROM public.goodsreceived WHERE id = p_grn_id;
  IF NOT FOUND THEN
    RETURN false;
  END IF;
  -- Both ways: every photo sent is one of this GRN and keeps its line; a list that is not empty names every confirmed photo of the GRN.
  BEGIN
    v_photos :=
          NOT EXISTS (SELECT 1 FROM jsonb_array_elements(COALESCE(p_images, '[]'::jsonb)) e
                       WHERE NOT EXISTS (SELECT 1 FROM public.grn_images i WHERE i.grn_id = p_grn_id AND i.id::text = e->>'id'
                                            AND i.grn_item_id IS NOT DISTINCT FROM
                                                CASE WHEN e->>'image_type' = 'item' THEN (e->>'grn_item_id')::uuid END))
      AND (jsonb_array_length(COALESCE(p_images, '[]'::jsonb)) = 0
           OR NOT EXISTS (SELECT 1 FROM public.grn_images i
                           WHERE i.grn_id = p_grn_id AND i.status = 'confirmed'
                             AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(p_images) e WHERE e->>'id' = i.id::text)));
  EXCEPTION WHEN invalid_text_representation OR numeric_value_out_of_range OR data_exception THEN
    v_photos := false;
  END;
  IF NOT COALESCE(v_photos, false) THEN
    RETURN false;
  END IF;

  IF p_strict THEN
    -- WH-250, WH-251: what update_grn would write against what is stored (the header says which values count as the same, and why).
    BEGIN
      v_same :=
            (p_gr_no IS NULL OR p_gr_no = g.gr_no)
        AND (p_date IS NULL OR warehouse_security.business_date(p_date) = warehouse_security.business_date(g.date))
        AND (p_customer_id IS NULL OR p_customer_id = g.customer_id)
        AND (p_sender_id IS NULL OR p_sender_id = g.sender_id)
        AND (p_sender_name IS NULL
             OR warehouse_security.trimmed_reason(p_sender_name) IS NOT DISTINCT FROM warehouse_security.trimmed_reason(g.sender_name))
        AND (p_supervisor_id IS NULL OR p_supervisor_id = g.supervisor_id)
        AND (p_supervisor_name IS NULL
             OR warehouse_security.trimmed_reason(p_supervisor_name) IS NOT DISTINCT FROM warehouse_security.trimmed_reason(g.supervisor_name))
        AND (p_registration IS NULL
             OR NULLIF(regexp_replace(regexp_replace(p_registration, '^[\s ]+|[\s ]+$', '', 'g'), '[\s ]+', ' ', 'g'), '')
                IS NOT DISTINCT FROM
                NULLIF(regexp_replace(regexp_replace(g.registration, '^[\s ]+|[\s ]+$', '', 'g'), '[\s ]+', ' ', 'g'), ''))
        AND (p_note IS NULL OR NULLIF(p_note, '') IS NOT DISTINCT FROM NULLIF(g.note, ''))
        -- leon: an empty stored leon is the same as false (Product, WH-250; no server code calculates with it), so a sent false over an
        -- empty one is not a change (update_grn then stores false). This is the only place that decides it.
        AND (p_leon IS NULL OR p_leon = COALESCE(g.leon, false))
        AND (p_pricing_mode IS NULL OR p_pricing_mode = COALESCE(g.pricing_mode, 'MONTHLY'))
        AND (p_duration_mode IS NULL OR p_duration_mode = g.duration_mode)
        -- Every stored line once, by id, with what update_grn writes on it equal to what is stored (only the snake_case keys).
        AND jsonb_typeof(p_items) = 'array'
        AND jsonb_array_length(p_items) = (SELECT count(*) FROM public.goodsreceived_trl t WHERE t.gr_id = p_grn_id)
        AND (SELECT count(DISTINCT t.id) FROM jsonb_array_elements(p_items) e
               JOIN public.goodsreceived_trl t ON t.gr_id = p_grn_id AND t.id::text = e->>'id'
               CROSS JOIN LATERAL (SELECT COALESCE(sum(d.disp_qty), 0) = 0 AS undispatched
                                     FROM public.dispatch_trl d WHERE d.gr_trl_id = t.id) x
              WHERE (e->>'item_id')::uuid = t.item_id
                AND (NOT x.undispatched OR (e->>'item_name' = t.item_name AND (e->>'qty')::integer = t.qty AND t.stock = t.qty))
                AND NULLIF(e->>'packaging', '') IS NOT DISTINCT FROM NULLIF(t.packaging, '')
                -- An empty weight is not the same as 0: find_storage_price finds no rate band for it.
                AND COALESCE((e->>'weight')::integer, 0) IS NOT DISTINCT FROM t.weight
                AND NULLIF(warehouse_security.ascii_digits(e->>'rack'), '')
                    IS NOT DISTINCT FROM NULLIF(warehouse_security.ascii_digits(t.rack), '')
                AND NULLIF(warehouse_security.ascii_digits(e->>'package_mark'), '')
                    IS NOT DISTINCT FROM NULLIF(warehouse_security.ascii_digits(t.package_mark), ''))
            = jsonb_array_length(p_items);
    EXCEPTION WHEN invalid_text_representation OR numeric_value_out_of_range OR data_exception THEN
      v_same := false;
    END;
    RETURN COALESCE(v_same, false);
  END IF;

  -- Not strict: migration 190's comparison, for an imported GRN, whose rates save writes nothing else.
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
          = jsonb_array_length(p_items);
  EXCEPTION WHEN invalid_text_representation OR numeric_value_out_of_range OR data_exception THEN
    v_same := false;
  END;
  RETURN COALESCE(v_same, false);
END $$;
ALTER FUNCTION warehouse_security.grn_save_keeps_stored(uuid, character varying, timestamp with time zone, uuid, character varying, uuid,
  character varying, uuid, character varying, character varying, character varying, boolean, character varying, jsonb, jsonb,
  character varying, boolean) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION warehouse_security.grn_save_keeps_stored(uuid, character varying, timestamp with time zone, uuid, character varying,
  uuid, character varying, uuid, character varying, character varying, character varying, boolean, character varying, jsonb, jsonb,
  character varying, boolean) FROM PUBLIC;

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
    p_sender_name, p_supervisor_id, p_supervisor_name, p_registration, p_note, p_leon, p_pricing_mode, p_items, p_images, p_duration_mode,
    false);
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
