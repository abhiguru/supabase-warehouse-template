-- Migration 144: each item's own packaging word, as entered (WH-41; includes WH-1, WH-24, WH-9).
--
-- The word comes from the item. Bag, Box and Crate keep their text; any other word (Katta, Trey, Unit, Sack, Carton ...) is shown as typed. The app
-- (src/utils/packagingWord.ts) and the server follow the same rule:
--   * outer spaces and the invisible characters U+00A0, U+2007, U+202F and U+FEFF never change a word (WH-9: a pasted "Box" with a hidden character is Box);
--   * matching ignores case; bag/bags and a blank word are one word (Bag), box/boxes is Box, crate/crates is Crate;
--   * every other word is its own word, shown as typed (the lexicographically smallest spelling when lots spell it differently).
--
-- Section 1  warehouse_security.clean_packaging, packaging_key and packaging_word (the rule), and shared_packaging rewritten on them. Its answer is
--            still null when the lots differ, Bag, Box or Crate for those words, and now the typed word for any other word when every lot agrees.
-- Section 2  An item is its name and its word. items_name_key UNIQUE (name) becomes a unique key on (name, packaging key): "Egg" + "Box" and
--            "Egg" + "Trey" are two items; "Egg" with no word and "Egg" + "Bag" are the same item. No blank word is rewritten.
-- Section 3  create_item and update_item: packaging is required (INVALID_INPUT, "Packaging is required"), the duplicate check and the advisory lock
--            cover name and word (DUPLICATE_NAME as before), and the stored word has its outer spaces and invisible characters removed.
--            update_item keeps old items editable: a call that changes only p_active (the app's activate / deactivate) does not need a word, so an item
--            with no word can still be switched off and on; any save that changes the name, word or description needs one.
-- Section 4  Anything that matched or grouped by item name alone now uses the item id:
--            * get_customer_activity_detail: top_stock_items groups by item id (two "Egg" items were one row);
--            * get_stock_aging_report: each line also carries item_id (the app groups the lines by item);
--            * get_item_wise_stock_list: the row's word is the shared word of the item's lots (null when they differ), not an arbitrary MAX();
--            * build_invoice_recalculation_rows: the missing-price check lists an item once by id (two "Egg" items both without a rate were one name);
--            * get_order_change_log: the lookups of a line's GRN quantity, rack, weight and packaging and the line's chain of quantities also use
--              the catalog item when the entry knows it; delete_dispatch_with_order_cleanup now stores the lot id on each restored item, so the
--              history of a dispatch deleted from now on is exact. History written before this migration holds names only and still matches by
--              name (the same GRN, item name and package mark).
--            Not changed because they already use the item id: order effects (migration 128: warehouse_security.order_effects joins the lots by
--            id; the name is only printed), get_customer_stock_summary and get_all_stock_summary.
-- Marker-count patches: each before-text is found exactly the expected number of times, or the migration stops.

-- ---------------------------------------------------------------------------------------------
-- Section 1: the rule
-- ---------------------------------------------------------------------------------------------
CREATE FUNCTION warehouse_security.clean_packaging(p_word text) RETURNS text
    LANGUAGE sql IMMUTABLE
    SET search_path TO 'pg_catalog'
    AS $fn$
  SELECT regexp_replace(COALESCE(p_word, ''), '^([[:space:]]| | | |﻿)+|([[:space:]]| | | |﻿)+$', '', 'g')
$fn$;

-- The word without its spelling: 'bag' (also blank), 'box', 'crate', else the typed word in lower case.
CREATE FUNCTION warehouse_security.packaging_key(p_word text) RETURNS text
    LANGUAGE sql IMMUTABLE
    SET search_path TO 'pg_catalog'
    AS $fn$
  SELECT CASE
           WHEN k ~ '^(bags?)?$' THEN 'bag'
           WHEN k ~ '^box(es)?$' THEN 'box'
           WHEN k ~ '^crates?$' THEN 'crate'
           ELSE k
         END
  FROM (SELECT lower(regexp_replace(COALESCE(p_word, ''), '^([[:space:]]| | | |﻿)+|([[:space:]]| | | |﻿)+$', '', 'g')) AS k) x
$fn$;

-- The word to show: Bag, Box or Crate for those words (blank is Bag), else the typed word without its outer spaces.
CREATE FUNCTION warehouse_security.packaging_word(p_word text) RETURNS text
    LANGUAGE sql IMMUTABLE
    SET search_path TO 'pg_catalog'
    AS $fn$
  SELECT CASE warehouse_security.packaging_key(p_word)
           WHEN 'bag' THEN 'Bag'
           WHEN 'box' THEN 'Box'
           WHEN 'crate' THEN 'Crate'
           ELSE warehouse_security.clean_packaging(p_word)
         END
$fn$;

ALTER FUNCTION warehouse_security.clean_packaging(text) OWNER TO supabase_admin;
ALTER FUNCTION warehouse_security.packaging_key(text) OWNER TO supabase_admin;
ALTER FUNCTION warehouse_security.packaging_word(text) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION warehouse_security.clean_packaging(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION warehouse_security.packaging_key(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION warehouse_security.packaging_word(text) FROM PUBLIC;

-- The one word every lot agrees on (null for no lots, or when the lots differ). Same signature and owner as migration 142.
CREATE OR REPLACE FUNCTION warehouse_security.shared_packaging(p_words text[]) RETURNS text
    LANGUAGE plpgsql IMMUTABLE
    SET search_path TO 'pg_catalog'
    AS $fn$
DECLARE
  v_word text;
  v_key text;
  v_first_key text;
  v_best text;
  v_shown text;
BEGIN
  IF p_words IS NULL OR cardinality(p_words) = 0 THEN
    RETURN NULL;
  END IF;
  FOREACH v_word IN ARRAY p_words LOOP
    v_key := warehouse_security.packaging_key(v_word);
    v_shown := warehouse_security.packaging_word(v_word);
    IF v_first_key IS NULL THEN
      v_first_key := v_key;
      v_best := v_shown;
    ELSIF v_key <> v_first_key THEN
      RETURN NULL;
    ELSIF v_shown < v_best THEN
      v_best := v_shown;
    END IF;
  END LOOP;
  RETURN v_best;
END
$fn$;

-- ---------------------------------------------------------------------------------------------
-- Section 2: an item is its name and its word
-- ---------------------------------------------------------------------------------------------
ALTER TABLE public.items DROP CONSTRAINT items_name_key;
CREATE UNIQUE INDEX items_name_packaging_key ON public.items (name, warehouse_security.packaging_key(packaging));

-- ---------------------------------------------------------------------------------------------
-- Section 3: create_item and update_item
-- ---------------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.create_item(p_name character varying, p_packaging character varying DEFAULT NULL::character varying, p_description character varying DEFAULT NULL::character varying, p_active boolean DEFAULT true, p_rate_from_item uuid DEFAULT NULL::uuid) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'extensions', 'utils', 'pg_temp'
    AS $$
DECLARE
    v_new_id uuid;
    v_result jsonb;
    v_source text := 'none';
    v_today date := warehouse_security.business_date(now());
    v_name text := TRIM(p_name);
    v_packaging text := NULLIF(warehouse_security.clean_packaging(p_packaging), '');
    v_description text := NULLIF(TRIM(p_description), '');
    v_constraint text;
BEGIN
  PERFORM warehouse_security.authorize_rpc('create_item',jsonb_build_object());
    -- Security check
    IF NOT is_admin_or_supervisor() THEN
        RETURN jsonb_build_object(
            'success', false,
            'error_code', 'PERMISSION_DENIED',
            'error', 'Access denied: Admin or supervisor role required',
            'message', 'Access denied: Admin or supervisor role required'
        );
    END IF;

    -- Validate name
    IF v_name IS NULL OR v_name = '' THEN
        RETURN jsonb_build_object(
            'success', false,
            'error_code', 'INVALID_INPUT',
            'error', 'Item name is required',
            'message', 'Item name is required'
        );
    END IF;
    -- The packaging word is required (migration 144).
    IF v_packaging IS NULL THEN
        RETURN jsonb_build_object(
            'success', false,
            'error_code', 'INVALID_INPUT',
            'error', 'Packaging is required',
            'message', 'Packaging is required'
        );
    END IF;
    IF length(v_name) > 80 OR length(v_packaging) > 40 OR length(v_description) > 40 THEN
        RETURN jsonb_build_object(
            'success', false,
            'error_code', 'INVALID_INPUT',
            'error', 'Name is at most 80 characters, packaging and description at most 40',
            'message', 'Name is at most 80 characters, packaging and description at most 40'
        );
    END IF;

    -- Check for a duplicate: the same name and the same packaging word (any item, active or not; upper and lower case are the same,
    -- and a blank word is Bag).
    PERFORM pg_advisory_xact_lock(hashtextextended('item_name:' || LOWER(v_name) || '|' || warehouse_security.packaging_key(v_packaging), 0));
    IF EXISTS (SELECT 1 FROM items
               WHERE LOWER(TRIM(name)) = LOWER(v_name)
                 AND warehouse_security.packaging_key(packaging) = warehouse_security.packaging_key(v_packaging)) THEN
        RETURN jsonb_build_object(
            'success', false,
            'error_code', 'DUPLICATE_NAME',
            'error', 'An item with this name and packaging already exists',
            'message', 'An item with this name and packaging already exists'
        );
    END IF;

    -- Insert new item. Two saves of the same name and word at once: the unique key answers the second one.
    BEGIN
        INSERT INTO items (name, packaging, description, active)
        VALUES (v_name, v_packaging, v_description, COALESCE(p_active, true))
        RETURNING id INTO v_new_id;
    EXCEPTION WHEN unique_violation THEN
        GET STACKED DIAGNOSTICS v_constraint = CONSTRAINT_NAME;
        IF v_constraint IS DISTINCT FROM 'items_name_packaging_key' THEN RAISE; END IF;
        RETURN jsonb_build_object(
            'success', false,
            'error_code', 'DUPLICATE_NAME',
            'error', 'An item with this name and packaging already exists',
            'message', 'An item with this name and packaging already exists'
        );
    END;

    -- The item's rate (migration 85): a copy of another item's default rows in force today, else
    -- the standard tiers from today, else none. A save of the standard rate in progress is waited
    -- for (it holds the same lock exclusively), so the tiers read below are the committed ones.
    PERFORM pg_advisory_xact_lock_shared(hashtextextended('standard_rate', 0));
    IF p_rate_from_item IS NOT NULL
       AND warehouse_security.copy_default_rates(p_rate_from_item, v_new_id, v_today) > 0 THEN
        v_source := 'copied';
    ELSIF warehouse_security.give_standard_rate(v_new_id, v_today) > 0 THEN
        v_source := 'standard';
    END IF;

    -- Return created item
    SELECT jsonb_build_object(
        'id', id,
        'name', name,
        'packaging', packaging,
        'description', description,
        'active', active,
        'rate_source', v_source
    ) INTO v_result
    FROM items
    WHERE id = v_new_id;

    RETURN jsonb_build_object(
        'success', true,
        'message', 'Item created successfully',
        'data', v_result
    );
END;
$$;

CREATE OR REPLACE FUNCTION public.update_item(p_item_id uuid, p_name character varying, p_packaging character varying DEFAULT NULL::character varying, p_description character varying DEFAULT NULL::character varying, p_active boolean DEFAULT NULL::boolean) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'extensions', 'utils', 'pg_temp'
    AS $$
DECLARE
    v_result jsonb;
    v_was_active boolean;
    v_current_name text;
    v_current_packaging text;
    v_current_description text;
    v_found boolean;
    v_new_active boolean;
    v_name text := TRIM(p_name);
    v_packaging text := NULLIF(warehouse_security.clean_packaging(p_packaging), '');
    v_description text := NULLIF(TRIM(p_description), '');
    v_constraint text;
    v_added integer := 0;
BEGIN
  PERFORM warehouse_security.authorize_rpc('update_item',jsonb_build_object());
    -- Security check
    IF NOT is_admin_or_supervisor() THEN
        RETURN jsonb_build_object(
            'success', false,
            'error_code', 'PERMISSION_DENIED',
            'error', 'Access denied: Admin or supervisor role required',
            'message', 'Access denied: Admin or supervisor role required'
        );
    END IF;

    -- Check if item exists (and hold its row, so a delete in between cannot slip past)
    SELECT true, active, name, packaging, description
      INTO v_found, v_was_active, v_current_name, v_current_packaging, v_current_description
      FROM items WHERE id = p_item_id FOR NO KEY UPDATE;
    IF v_found IS NOT TRUE THEN
        RETURN jsonb_build_object(
            'success', false,
            'error_code', 'NOT_FOUND',
            'error', 'Item not found',
            'message', 'Item not found'
        );
    END IF;

    -- Validate name
    IF v_name IS NULL OR v_name = '' THEN
        RETURN jsonb_build_object(
            'success', false,
            'error_code', 'INVALID_INPUT',
            'error', 'Item name is required',
            'message', 'Item name is required'
        );
    END IF;
    -- The packaging word is required (migration 144), except for a call that changes only the active flag: an item saved before this
    -- migration with no word can still be switched off and on, and its word is asked for the next time it is edited.
    IF v_packaging IS NULL
       AND NOT (v_name IS NOT DISTINCT FROM TRIM(v_current_name)
                AND NULLIF(warehouse_security.clean_packaging(v_current_packaging), '') IS NULL
                AND v_description IS NOT DISTINCT FROM NULLIF(TRIM(v_current_description), '')) THEN
        RETURN jsonb_build_object(
            'success', false,
            'error_code', 'INVALID_INPUT',
            'error', 'Packaging is required',
            'message', 'Packaging is required'
        );
    END IF;
    IF length(v_name) > 80 OR length(v_packaging) > 40 OR length(v_description) > 40 THEN
        RETURN jsonb_build_object(
            'success', false,
            'error_code', 'INVALID_INPUT',
            'error', 'Name is at most 80 characters, packaging and description at most 40',
            'message', 'Name is at most 80 characters, packaging and description at most 40'
        );
    END IF;

    -- Check for a duplicate (excluding self; any item, active or not; upper and lower case are the same, a blank word is Bag).
    -- A name and word left as stored are not checked, so older items that differ only in case stay editable.
    IF v_name IS DISTINCT FROM TRIM(v_current_name)
       OR warehouse_security.packaging_key(v_packaging) IS DISTINCT FROM warehouse_security.packaging_key(v_current_packaging) THEN
      PERFORM pg_advisory_xact_lock(hashtextextended('item_name:' || LOWER(v_name) || '|' || warehouse_security.packaging_key(v_packaging), 0));
      IF EXISTS (SELECT 1 FROM items
                 WHERE LOWER(TRIM(name)) = LOWER(v_name)
                   AND warehouse_security.packaging_key(packaging) = warehouse_security.packaging_key(v_packaging)
                   AND id != p_item_id) THEN
        RETURN jsonb_build_object(
            'success', false,
            'error_code', 'DUPLICATE_NAME',
            'error', 'An item with this name and packaging already exists',
            'message', 'An item with this name and packaging already exists'
        );
      END IF;
    END IF;

    -- Not sent (NULL) = keep the current value.
    v_new_active := COALESCE(p_active, v_was_active);

    -- Update item
    BEGIN
        UPDATE items
        SET name = v_name,
            packaging = v_packaging,
            description = v_description,
            active = v_new_active
        WHERE id = p_item_id;
    EXCEPTION WHEN unique_violation THEN
        GET STACKED DIAGNOSTICS v_constraint = CONSTRAINT_NAME;
        IF v_constraint IS DISTINCT FROM 'items_name_packaging_key' THEN RAISE; END IF;
        RETURN jsonb_build_object(
            'success', false,
            'error_code', 'DUPLICATE_NAME',
            'error', 'An item with this name and packaging already exists',
            'message', 'An item with this name and packaging already exists'
        );
    END;

    -- An item that turns active and has no default rate gets the standard tiers from today (migration 85).
    IF COALESCE(v_was_active, false) = false AND v_new_active IS TRUE THEN
        PERFORM pg_advisory_xact_lock_shared(hashtextextended('standard_rate', 0));
        v_added := warehouse_security.give_standard_rate(p_item_id, warehouse_security.business_date(now()));
    END IF;

    -- Return updated item
    SELECT jsonb_build_object(
        'id', id,
        'name', name,
        'packaging', packaging,
        'description', description,
        'active', active
    ) INTO v_result
    FROM items
    WHERE id = p_item_id;

    RETURN jsonb_build_object(
        'success', true,
        'message', 'Item updated successfully',
        'data', CASE WHEN v_added > 0 THEN v_result || jsonb_build_object('rate_source', 'standard') ELSE v_result END
    );
END;
$$;

-- ---------------------------------------------------------------------------------------------
-- Section 4: by item id, not by item name
-- ---------------------------------------------------------------------------------------------
-- Migration 142 leaves its pg_temp helper behind; the files of one run share a session.
DROP FUNCTION IF EXISTS pg_temp.patch_function(regprocedure, text[], text[]);
CREATE FUNCTION pg_temp.patch_function(p_function regprocedure, p_old text[], p_new text[], p_expected integer[]) RETURNS void
    LANGUAGE plpgsql AS $$
DECLARE
  v_def text := pg_get_functiondef(p_function);
  v_count integer;
  i integer;
BEGIN
  IF array_length(p_old, 1) IS DISTINCT FROM array_length(p_new, 1) OR array_length(p_old, 1) IS DISTINCT FROM array_length(p_expected, 1) THEN
    RAISE EXCEPTION '%: the marker, replacement and count lists differ in length', p_function;
  END IF;
  FOR i IN 1 .. array_length(p_old, 1) LOOP
    v_count := (length(v_def) - length(replace(v_def, p_old[i], ''))) / length(p_old[i]);
    IF v_count <> p_expected[i] THEN
      RAISE EXCEPTION '%: expected marker % % times, found % times', p_function, i, p_expected[i], v_count;
    END IF;
    v_def := replace(v_def, p_old[i], p_new[i]);
  END LOOP;
  EXECUTE v_def;
END $$;

-- get_customer_activity_detail: the top stock items are one row per item, not per item name.
SELECT pg_temp.patch_function('public.get_customer_activity_detail(uuid, date, date)'::regprocedure, ARRAY[
$m$            grt.item_name,
            warehouse_security.shared_packaging(array_agg(grt.packaging)) AS packaging,
            SUM(grt.stock) as total_stock,$m$,
$m$        GROUP BY grt.item_name
        ORDER BY total_stock DESC$m$
], ARRAY[
$m$            (array_agg(grt.item_name ORDER BY gr.date DESC NULLS LAST, grt.id DESC))[1] AS item_name,
            warehouse_security.shared_packaging(array_agg(grt.packaging)) AS packaging,
            SUM(grt.stock) as total_stock,$m$,
$m$        GROUP BY grt.item_id
        ORDER BY total_stock DESC$m$
], ARRAY[1, 1]);

-- get_item_wise_stock_list: one row per item (already by item id); its word is the word its lots agree on, null when they differ.
SELECT pg_temp.patch_function('public.get_item_wise_stock_list(uuid, text, integer, integer, text, text)'::regprocedure, ARRAY[
$m$'packaging', MAX(grt.packaging),$m$
], ARRAY[
$m$'packaging', warehouse_security.shared_packaging(array_agg(grt.packaging)),$m$
], ARRAY[1]);

-- build_invoice_recalculation_rows: an item without a rate is listed once by its id (the list still holds names).
SELECT pg_temp.patch_function('public.build_invoice_recalculation_rows(uuid, text, uuid)'::regprocedure, ARRAY[
$m$    v_missing_prices text[] := ARRAY[]::text[];$m$,
$m$            IF NOT (v_dispatch_record.grn_items_item_name = ANY(v_missing_prices)) THEN
                v_missing_prices := v_missing_prices || v_dispatch_record.grn_items_item_name;
            END IF;$m$
], ARRAY[
$m$    v_missing_prices text[] := ARRAY[]::text[];
    v_missing_item_ids uuid[] := ARRAY[]::uuid[];$m$,
$m$            IF NOT (v_dispatch_record.grn_items_item_id = ANY(v_missing_item_ids)) THEN
                v_missing_item_ids := v_missing_item_ids || v_dispatch_record.grn_items_item_id;
                v_missing_prices := v_missing_prices || v_dispatch_record.grn_items_item_name;
            END IF;$m$
], ARRAY[1, 1]);

-- delete_dispatch_with_order_cleanup: each restored item also names its lot, so the order history can find the lot by id.
SELECT pg_temp.patch_function('public.delete_dispatch_with_order_cleanup(uuid, uuid)'::regprocedure, ARRAY[
$m$            'grn_no', v_cart_line.gr_no,
            'quantity_restored', v_cart_line.give_back
        );$m$
], ARRAY[
$m$            'grn_no', v_cart_line.gr_no,
            'grn_item_id', v_cart_line.gr_trl_id,
            'quantity_restored', v_cart_line.give_back
        );$m$
], ARRAY[1]);

-- get_order_change_log: every event of a line carries the catalog item (item_catalog_id, null when the entry does not know it), the chain of
-- quantities of a line is per catalog item, and the lookups of the GRN line add the catalog item (or the lot id of a restored item) to the name.
SELECT pg_temp.patch_function('public.get_order_change_log(uuid, uuid, timestamp with time zone, timestamp with time zone, uuid, text, integer, integer)'::regprocedure, ARRAY[
-- 1 manual UPDATE branch
$m$                  NULL::int as restored_qty,
                  r.rev_id
$m$,
-- 2 old-format reduction branch
$m$                  ci.value,
                  NULL::int,
                  NULL::int,
                  r.rev_id
$m$,
-- 3 new-format reduction branch
$m$THEN (r.value->>'previous_quantity')::int END,
                  NULL::int,
                  r.rev_id
$m$,
-- 4 give-back branch
$m$                  LEAST(rq.restored, rq.took),
                  r.rev_id
$m$,
-- 5 the chain of a line
$m$(grn_no || '|' || COALESCE(package_mark,'') || '|' || item_name) AS item_key$m$,
-- 6 lookups of the event stream
$m$AND gt.item_name = e.item_name$m$,
-- 7 lookups of a restored item
$m$AND gt.item_name = ri.value->>'item_name'$m$,
-- 8 the give-back's own lookup of what the dispatch took
$m$AND  gt.item_name = ri.value->>'item_name'$m$
], ARRAY[
$m$                  NULL::int as restored_qty,
                  r.rev_id,
                  (SELECT i.id FROM public.items i WHERE i.id::text = ci.value->>'item_id') AS item_catalog_id
$m$,
$m$                  ci.value,
                  NULL::int,
                  NULL::int,
                  r.rev_id,
                  (SELECT i.id FROM public.items i WHERE i.id::text = ci.value->>'item_id')
$m$,
$m$THEN (r.value->>'previous_quantity')::int END,
                  NULL::int,
                  r.rev_id,
                  gt.item_id
$m$,
$m$                  LEAST(rq.restored, rq.took),
                  r.rev_id,
                  COALESCE(
                      (SELECT gt0.item_id FROM public.goodsreceived_trl gt0 WHERE gt0.id::text = ri.value->>'grn_item_id'),
                      (SELECT CASE WHEN count(DISTINCT gt0.item_id) = 1 THEN (array_agg(gt0.item_id))[1] END
                       FROM public.goodsreceived_trl gt0 JOIN public.goodsreceived g0 ON g0.id = gt0.gr_id
                       WHERE g0.gr_no = ri.value->>'grn_no'
                         AND gt0.item_name = ri.value->>'item_name'
                         AND COALESCE(gt0.package_mark, '') = COALESCE(ri.value->>'package_mark', '')))
$m$,
$m$(grn_no || '|' || COALESCE(package_mark,'') || '|' || item_name || '|' || COALESCE(item_catalog_id::text, '')) AS item_key$m$,
$m$AND gt.item_name = e.item_name AND (e.item_catalog_id IS NULL OR gt.item_id = e.item_catalog_id)$m$,
$m$AND gt.item_name = ri.value->>'item_name' AND (ri.value->>'grn_item_id' IS NULL OR gt.id::text = ri.value->>'grn_item_id')$m$,
$m$AND  gt.item_name = ri.value->>'item_name' AND (ri.value->>'grn_item_id' IS NULL OR gt.id::text = ri.value->>'grn_item_id')$m$
], ARRAY[1, 1, 1, 1, 1, 5, 5, 1]);

-- get_stock_aging_report: each line also names its item (item_id), so two items with one name are two groups in the app's list.
SELECT pg_temp.patch_function('public.get_stock_aging_report(uuid, integer[])'::regprocedure, ARRAY[
$m$                grt.item_name,
                grt.packaging,
                grt.stock as current_stock,$m$,
$m$                    'item_name', item_name,
                    'packaging', packaging,$m$
], ARRAY[
$m$                grt.item_id,
                grt.item_name,
                grt.packaging,
                grt.stock as current_stock,$m$,
$m$                    'item_id', item_id,
                    'item_name', item_name,
                    'packaging', packaging,$m$
], ARRAY[1, 1]);

-- get_item_storage_prices and get_item_price_history: each row also carries the item's packaging word (item_packaging, additive), so the rate screens
-- can show "Egg \u00B7 Trey" beside the name. The word is '' for an item with no word (read as Bag) and, in the history, null once the item is deleted (the app then shows the name alone). The history keeps no copy of the word: it is the item's word now.
SELECT pg_temp.patch_function('public.get_item_storage_prices(jsonb, text, text, integer, integer)'::regprocedure, ARRAY[
$m$                 ''item_name'', i.name,$m$
], ARRAY[
$m$                 ''item_name'', i.name,
                 ''item_packaging'', COALESCE(i.packaging, ''''),$m$
], ARRAY[1]);

SELECT pg_temp.patch_function('public.get_item_price_history(uuid, uuid, integer, integer)'::regprocedure, ARRAY[
$m$            'item_name', h.item_name,$m$
], ARRAY[
$m$            'item_name', h.item_name,
            'item_packaging', (SELECT COALESCE(i.packaging, '') FROM items i WHERE i.id = h.item_id),$m$
], ARRAY[1]);

-- get_customer_stock_analysis_v2: already one row per item id; its name search also finds the packaging word, and rows of two items with one name keep a fixed order.
SELECT pg_temp.patch_function('public.get_customer_stock_analysis_v2(uuid, timestamp with time zone, jsonb, boolean)'::regprocedure, ARRAY[
$m$OR i.name ILIKE '%' || (p_item_filter->>'item_name') || '%')$m$,
$m$) ORDER BY sc.item_name$m$
], ARRAY[
$m$OR i.name ILIKE '%' || (p_item_filter->>'item_name') || '%'
             OR i.packaging ILIKE '%' || (p_item_filter->>'item_name') || '%')$m$,
$m$) ORDER BY sc.item_name, sc.item_id$m$
], ARRAY[1, 1]);

DROP FUNCTION pg_temp.patch_function(regprocedure, text[], text[], integer[]);

NOTIFY pgrst, 'reload schema';
