-- Migration 124: a "possible duplicate" WARNING on GRN create and on direct dispatch create (owner decision of 2026-10-21).
--
-- A warning, never a block, and OPT-IN: the check runs only when the caller asks for it (save_grn: p_warn_duplicate = true; the
-- dispatch: warn_duplicate = true in p_dispatch_data) AND sends a request key (p_idempotency_key). A call that does not ask, such
-- as an older app build or fas-sync's bulk push, behaves exactly as before and never gets POSSIBLE_DUPLICATE; a call without a key
-- is not checked either, so a resend that has no key cannot be warned about its own first try. When the caller asked, the call
-- answers POSSIBLE_DUPLICATE and writes nothing, and the same call sent again with the flag false (or absent) saves. The rules:
--   * GRN (save_grn): a LIVE GRN of the same customer, with the same GRN day (the business day, Asia/Kolkata), created in the last
--     30 minutes by anyone, whose lines are the same SET of (item, packaging). Quantity, weight, rack and mark are ignored; line
--     order and repeated lines do not matter. The item is the item id; the packaging is compared trimmed, in one case, with runs of
--     white space (tabs and new lines too) as one space.
--   * Direct dispatch (create_dispatch_with_stock_check, both signatures, through create_dispatch_with_stock_check_internal): only
--     when the dispatch has NO source order. A LIVE dispatch of the same customer, created in the last 30 minutes (from an order or
--     not), with the same SET of lots (goodsreceived_trl ids) and the same vehicle registration (upper-cased, spaces and hyphens
--     removed). Quantity is ignored. A dispatch made from an order is never warned about: its order line is used up.
--   * With several matches the newest is reported.
--
-- Where the check runs: after the saved-answer lookup (a resend of a saved request still gets its stored answer) and AFTER every other
-- validation and refusal of the function, so a person who confirms "Save anyway" is not refused for another reason afterwards. The
-- refusals that can only be known while writing (a quantity or weight, an image path, every rate refusal of apply_grn_rates, a
-- foreign-key or unique violation; for the dispatch the stock, cart and trigger errors) come first, so the check is the LAST step of
-- the write block, after the writes: it RAISEs 'dup_warn' with the answer in DETAIL, the handler that already answers 'rate_fail'
-- returns it, and the rollback of the block leaves nothing written (no GRN, no line, no rate, no stock movement, no cart change).
-- The check runs before the saved answer is stored, so the warning is never stored under the request key.
-- The answer is warehouse_security.refuse('POSSIBLE_DUPLICATE', <sentence>, <fields>) (migration 121): success:false,
-- error_code:'WH409', reason, error, message, and kind ('grn' | 'dispatch'), existing_id, existing_number, existing_created_at,
-- existing_created_by (the person's name, or null), customer_name, items (GRN: [{item_name, packaging}]; dispatch: [{gr_no,
-- item_name, packaging}]), vehicle (dispatch only: as stored), window_minutes (30). The sentence is English; the app words its own.
--
-- The flag: save_grn gains the trailing parameter p_warn_duplicate boolean DEFAULT false (the old 17-argument function is dropped
-- and made again, so PostgREST sees one function; every existing argument keeps its name and position, and a caller that does not
-- send it, an older app or fas-sync, keeps working unchanged). The dispatch takes warn_duplicate = true in p_dispatch_data (no
-- signature change). The app sends true on a normal create and false when the person confirms "Save anyway".
--
-- The lookups are fail-open helpers: any error inside one (a malformed line, say) is reported as a WARNING in the log and means "no
-- warning", so the save then fails or succeeds exactly as it did before this migration. They take the id of the record being
-- written and skip it.
--
-- Both functions are the latest definition (save_grn: the baseline with the patches of migrations 120 and 121; the dispatch
-- internal: migration 121) with only the changes above, patched with the marker-count pattern of migration 111. The new helpers are
-- in warehouse_security and are not granted to any API role. No data and no index is changed. The GRN lookup is bounded by customer and
-- by the business day of p_date, written as a range of goodsreceived.date, and the planner serves it from
-- idx_goodsreceived_customer_deleted_active (customer_id, ..., date); the created_at filter then looks at the few rows of that day. The
-- dispatch lookup starts from idx_dispatch_customer_id and filters by created_at: no existing index leads with it, and the dispatch
-- date cannot bound it (a dispatch can be dated any day). Measured on 30,000 GRNs and 30,000 dispatches with 3,000 of each for one
-- customer: 0.16 ms for the GRN rows, 0.5 ms for the dispatch rows, about 1 ms for a whole helper call.

-- Section 1: the two lookups

-- The GRN lookup: returns the POSSIBLE_DUPLICATE answer for the newest matching GRN, or NULL. p_exclude_id is the GRN being written
-- (it is already in the table when the check runs) and is skipped.
CREATE FUNCTION warehouse_security.possible_duplicate_grn(p_customer_id uuid, p_date timestamp with time zone, p_items jsonb, p_exclude_id uuid DEFAULT NULL)
    RETURNS jsonb
    LANGUAGE plpgsql STABLE
    SET search_path TO 'pg_catalog', 'public', 'pg_temp'
    AS $$
DECLARE
    v_keys text[];
    v_found record;
    v_items jsonb;
    v_minutes integer;
BEGIN
    IF p_customer_id IS NULL OR p_date IS NULL OR jsonb_typeof(p_items) IS DISTINCT FROM 'array' OR jsonb_array_length(p_items) = 0 THEN
        RETURN NULL;
    END IF;

    -- The request's set of (item, packaging) as sorted distinct keys: the item id, then the packaging compared trimmed, in one case,
    -- with runs of white space (tabs and new lines too) as one space.
    SELECT array_agg(DISTINCT k ORDER BY k) INTO v_keys
    FROM (
        SELECT ((e->>'item_id')::uuid)::text || '|' || btrim(regexp_replace(lower(COALESCE(e->>'packaging', '')), '\s+', ' ', 'g')) AS k
        FROM jsonb_array_elements(p_items) AS e
    ) AS request_lines;

    SELECT g.id, g.gr_no, g.created_at,
           COALESCE((SELECT c.name FROM customers c WHERE c.id = g.customer_id), g.customer_name) AS customer_name,
           (SELECT COALESCE(NULLIF(btrim(p.name), ''), NULLIF(btrim(p.display_name), ''))
            FROM user_profiles p WHERE p.id = g.created_by) AS created_by_name
    INTO v_found
    FROM goodsreceived g
    WHERE g.customer_id = p_customer_id
      AND g.deleted_at IS NULL
      AND g.created_at >= now() - interval '30 minutes'
      -- The same business day, written as a range of the date column so that idx_goodsreceived_date_active can serve it.
      AND g.date >= warehouse_security.business_day_start(warehouse_security.business_date(p_date))
      AND g.date < warehouse_security.business_day_start(warehouse_security.business_date(p_date) + 1)
      AND (p_exclude_id IS NULL OR g.id <> p_exclude_id)
      AND (SELECT array_agg(DISTINCT t.item_id::text || '|' || btrim(regexp_replace(lower(COALESCE(t.packaging, '')), '\s+', ' ', 'g'))
                            ORDER BY t.item_id::text || '|' || btrim(regexp_replace(lower(COALESCE(t.packaging, '')), '\s+', ' ', 'g')))
           FROM goodsreceived_trl t WHERE t.gr_id = g.id) = v_keys
    ORDER BY g.created_at DESC, g.id DESC
    LIMIT 1;

    IF NOT FOUND THEN
        RETURN NULL;
    END IF;

    SELECT COALESCE(jsonb_agg(jsonb_build_object('item_name', s.item_name, 'packaging', s.packaging)
                              ORDER BY s.item_name, s.packaging), '[]'::jsonb)
    INTO v_items
    FROM (
        SELECT DISTINCT ON (t.item_id, btrim(regexp_replace(lower(COALESCE(t.packaging, '')), '\s+', ' ', 'g')))
               COALESCE(i.name, t.item_name) AS item_name, t.packaging
        FROM goodsreceived_trl t
        LEFT JOIN items i ON i.id = t.item_id
        WHERE t.gr_id = v_found.id
        ORDER BY t.item_id, btrim(regexp_replace(lower(COALESCE(t.packaging, '')), '\s+', ' ', 'g')), t.id
    ) AS s;

    v_minutes := GREATEST(0, floor(extract(epoch FROM (now() - v_found.created_at)) / 60))::integer;

    RETURN warehouse_security.refuse('POSSIBLE_DUPLICATE',
        format('GRN %s for %s was created %s with the same items.', v_found.gr_no, v_found.customer_name,
               CASE WHEN v_minutes < 1 THEN 'just now'
                    WHEN v_minutes = 1 THEN '1 minute ago'
                    ELSE v_minutes || ' minutes ago' END),
        jsonb_build_object('kind', 'grn',
                           'existing_id', v_found.id,
                           'existing_number', v_found.gr_no,
                           'existing_created_at', v_found.created_at,
                           'existing_created_by', v_found.created_by_name,
                           'customer_name', v_found.customer_name,
                           'items', v_items,
                           'window_minutes', 30));
EXCEPTION
    WHEN OTHERS THEN
        -- A warning is never worth a failed save: on any error there is no warning (the log keeps the reason).
        RAISE WARNING 'possible_duplicate_grn failed: % %', SQLSTATE, SQLERRM;
        RETURN NULL;
END
$$;
ALTER FUNCTION warehouse_security.possible_duplicate_grn(p_customer_id uuid, p_date timestamp with time zone, p_items jsonb, p_exclude_id uuid) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION warehouse_security.possible_duplicate_grn(p_customer_id uuid, p_date timestamp with time zone, p_items jsonb, p_exclude_id uuid) FROM PUBLIC;

-- The dispatch lookup: returns the POSSIBLE_DUPLICATE answer for the newest matching dispatch, or NULL. p_lot_ids are the lots of
-- the request (goodsreceived_trl ids), p_registration the vehicle as sent, p_exclude_id the dispatch being written (skipped).
CREATE FUNCTION warehouse_security.possible_duplicate_dispatch(p_customer_id uuid, p_registration text, p_lot_ids uuid[], p_exclude_id uuid DEFAULT NULL)
    RETURNS jsonb
    LANGUAGE plpgsql STABLE
    SET search_path TO 'pg_catalog', 'public', 'pg_temp'
    AS $$
DECLARE
    v_lots uuid[];
    v_vehicle text;
    v_found record;
    v_items jsonb;
    v_minutes integer;
BEGIN
    IF p_customer_id IS NULL OR p_lot_ids IS NULL OR cardinality(p_lot_ids) = 0 THEN
        RETURN NULL;
    END IF;

    SELECT array_agg(DISTINCT l ORDER BY l) INTO v_lots FROM unnest(p_lot_ids) AS l;
    v_vehicle := upper(regexp_replace(COALESCE(p_registration, ''), '[\s-]+', '', 'g'));

    SELECT d.id, d.disp_no, d.created_at, d.registration,
           COALESCE((SELECT c.name FROM customers c WHERE c.id = d.customer_id), d.customer_name) AS customer_name,
           (SELECT COALESCE(NULLIF(btrim(p.name), ''), NULLIF(btrim(p.display_name), ''))
            FROM user_profiles p WHERE p.id = d.created_by) AS created_by_name
    INTO v_found
    FROM dispatch d
    WHERE d.customer_id = p_customer_id
      AND d.deleted_at IS NULL
      AND d.created_at >= now() - interval '30 minutes'
      AND (p_exclude_id IS NULL OR d.id <> p_exclude_id)
      AND upper(regexp_replace(COALESCE(d.registration, ''), '[\s-]+', '', 'g')) = v_vehicle
      AND (SELECT array_agg(DISTINCT dt.gr_trl_id ORDER BY dt.gr_trl_id) FROM dispatch_trl dt WHERE dt.disp_id = d.id) = v_lots
    ORDER BY d.created_at DESC, d.id DESC
    LIMIT 1;

    IF NOT FOUND THEN
        RETURN NULL;
    END IF;

    SELECT COALESCE(jsonb_agg(jsonb_build_object('gr_no', s.gr_no, 'item_name', s.item_name, 'packaging', s.packaging)
                              ORDER BY s.gr_no, s.item_name, s.packaging), '[]'::jsonb)
    INTO v_items
    FROM (
        SELECT gr.gr_no, COALESCE(i.name, t.item_name) AS item_name, t.packaging
        FROM dispatch_trl dt
        JOIN goodsreceived_trl t ON t.id = dt.gr_trl_id
        JOIN goodsreceived gr ON gr.id = t.gr_id
        LEFT JOIN items i ON i.id = t.item_id
        WHERE dt.disp_id = v_found.id
    ) AS s;

    v_minutes := GREATEST(0, floor(extract(epoch FROM (now() - v_found.created_at)) / 60))::integer;

    RETURN warehouse_security.refuse('POSSIBLE_DUPLICATE',
        format('Dispatch %s for %s was created %s with the same lots and vehicle.', v_found.disp_no, v_found.customer_name,
               CASE WHEN v_minutes < 1 THEN 'just now'
                    WHEN v_minutes = 1 THEN '1 minute ago'
                    ELSE v_minutes || ' minutes ago' END),
        jsonb_build_object('kind', 'dispatch',
                           'existing_id', v_found.id,
                           'existing_number', v_found.disp_no,
                           'existing_created_at', v_found.created_at,
                           'existing_created_by', v_found.created_by_name,
                           'customer_name', v_found.customer_name,
                           'items', v_items,
                           'vehicle', v_found.registration,
                           'window_minutes', 30));
EXCEPTION
    WHEN OTHERS THEN
        -- A warning is never worth a failed save: on any error there is no warning (the log keeps the reason).
        RAISE WARNING 'possible_duplicate_dispatch failed: % %', SQLSTATE, SQLERRM;
        RETURN NULL;
END
$$;
ALTER FUNCTION warehouse_security.possible_duplicate_dispatch(p_customer_id uuid, p_registration text, p_lot_ids uuid[], p_exclude_id uuid) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION warehouse_security.possible_duplicate_dispatch(p_customer_id uuid, p_registration text, p_lot_ids uuid[], p_exclude_id uuid) FROM PUBLIC;

-- Section 2: save_grn gains p_warn_duplicate and, when it is true and a request key is sent, asks the lookup as the last step of its
-- write block, after the lines, images and rates are written; a match raises 'dup_warn' with the answer in DETAIL, which the handler
-- that answers 'rate_fail' returns, and the rollback of the block leaves nothing behind.
-- The new trailing parameter changes the signature, so the old 17-argument function is dropped and the patched definition is
-- created under the new one (an overload would make a call by name ambiguous). Owner, search_path, jit and the grants are the old
-- function's: the definition carries the first two, the statements below the grants.
DO $patch$
DECLARE
  v_def text;
  v_old constant text[] := ARRAY[
    $m$p_rates jsonb DEFAULT NULL::jsonb)
 RETURNS jsonb
$m$,
    $m$      v_rate_failure jsonb;
      v_detail text;
BEGIN
$m$,
    $m$          v_result := jsonb_build_object(
              'success', true,
              'message', 'GRN created successfully',$m$,
    $m$IF SQLERRM = 'rate_fail' THEN$m$
  ];
  v_new constant text[] := ARRAY[
    $m$p_rates jsonb DEFAULT NULL::jsonb, p_warn_duplicate boolean DEFAULT false)
 RETURNS jsonb
$m$,
    $m$      v_rate_failure jsonb;
      v_detail text;
      v_duplicate jsonb;
BEGIN
$m$,
    $m$          -- Migration 124 (opt-in): when the caller asks (p_warn_duplicate) and sends a request key, the same customer, GRN day and
          -- set of items as another live GRN made in the last 30 minutes (by anyone) is a possible duplicate. This is the last step
          -- of the block, after every write and every refusal above: the answer is raised as 'dup_warn' (the handler returns the
          -- DETAIL), the block is rolled back, and the answer is never stored under the key.
          IF COALESCE(p_warn_duplicate, false) AND p_idempotency_key IS NOT NULL THEN
              v_duplicate := warehouse_security.possible_duplicate_grn(p_customer_id, p_date, p_items, v_grn_id);
              IF v_duplicate IS NOT NULL THEN
                  RAISE EXCEPTION 'dup_warn' USING ERRCODE = 'P0001', DETAIL = v_duplicate::text;
              END IF;
          END IF;

          v_result := jsonb_build_object(
              'success', true,
              'message', 'GRN created successfully',$m$,
    $m$IF SQLERRM IN ('rate_fail', 'dup_warn') THEN$m$
  ];
  v_count integer;
  i integer;
BEGIN
  v_def := pg_get_functiondef('public.save_grn(character varying, timestamp with time zone, uuid, character varying, uuid, character varying, uuid, character varying, character varying, character varying, boolean, character varying, jsonb, jsonb, text, character varying, jsonb)'::regprocedure);
  FOR i IN 1 .. array_length(v_old, 1) LOOP
    v_count := (length(v_def) - length(replace(v_def, v_old[i], ''))) / length(v_old[i]);
    IF v_count <> 1 THEN
      RAISE EXCEPTION 'save_grn: expected marker % once, found % times', i, v_count;
    END IF;
    v_def := replace(v_def, v_old[i], v_new[i]);
  END LOOP;
  DROP FUNCTION public.save_grn(character varying, timestamp with time zone, uuid, character varying, uuid, character varying, uuid, character varying, character varying, character varying, boolean, character varying, jsonb, jsonb, text, character varying, jsonb);
  EXECUTE v_def;
END
$patch$;

ALTER FUNCTION public.save_grn(character varying, timestamp with time zone, uuid, character varying, uuid, character varying, uuid, character varying, character varying, character varying, boolean, character varying, jsonb, jsonb, text, character varying, jsonb, boolean) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION public.save_grn(character varying, timestamp with time zone, uuid, character varying, uuid, character varying, uuid, character varying, character varying, character varying, boolean, character varying, jsonb, jsonb, text, character varying, jsonb, boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION public.save_grn(character varying, timestamp with time zone, uuid, character varying, uuid, character varying, uuid, character varying, character varying, character varying, boolean, character varying, jsonb, jsonb, text, character varying, jsonb, boolean) TO service_role;
GRANT ALL ON FUNCTION public.save_grn(character varying, timestamp with time zone, uuid, character varying, uuid, character varying, uuid, character varying, character varying, character varying, boolean, character varying, jsonb, jsonb, text, character varying, jsonb, boolean) TO authenticated;

-- Section 3: the dispatch create asks the lookup for a direct dispatch, when the data says warn_duplicate and a request key is sent, as
-- the last step before it builds its answer, after the dispatch, its lines, the stock, the movements and the cart handling are
-- written; a match raises 'dup_warn' with the answer in DETAIL, the handler of the function returns it, and the rollback of the
-- function's block leaves nothing behind (no signature change).
DO $patch$
DECLARE
  v_def text;
  v_old constant text[] := ARRAY[
    $m$    v_late_grn_day date;
BEGIN
$m$,
    $m$    -- Build result
    v_cached_response := jsonb_build_object($m$,
    $m$    WHEN OTHERS THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', SQLERRM,
$m$
  ];
  v_new constant text[] := ARRAY[
    $m$    v_late_grn_day date;
    v_duplicate jsonb;
    v_detail text;
BEGIN
$m$,
    $m$    -- Migration 124 (opt-in): when the data carries warn_duplicate = true and a request key is sent, a direct dispatch (no source
    -- order) with the same customer, set of lots and vehicle as another live dispatch made in the last 30 minutes is a possible
    -- duplicate. A dispatch from an order is never warned about (its order line is used up). This is the last step before the
    -- answer is built, after every write and every refusal above: the answer is raised as 'dup_warn' (the handler returns the
    -- DETAIL), the function's block is rolled back, and the answer is never stored under the key.
    IF v_source_order_id IS NULL AND COALESCE(p_dispatch_data->>'warn_duplicate', '') = 'true' AND p_idempotency_key IS NOT NULL THEN
        v_duplicate := warehouse_security.possible_duplicate_dispatch(
            (p_dispatch_data->>'customer_id')::uuid,
            p_dispatch_data->>'registration',
            ARRAY(SELECT (item->>'gr_trl_id')::uuid FROM unnest(p_dispatch_items) AS item),
            v_dispatch_id);
        IF v_duplicate IS NOT NULL THEN
            RAISE EXCEPTION 'dup_warn' USING ERRCODE = 'P0001', DETAIL = v_duplicate::text;
        END IF;
    END IF;

    -- Build result
    v_cached_response := jsonb_build_object($m$,
    $m$    WHEN OTHERS THEN
        IF SQLERRM = 'dup_warn' THEN
            GET STACKED DIAGNOSTICS v_detail = PG_EXCEPTION_DETAIL;
            RETURN v_detail::jsonb;
        END IF;
        RETURN jsonb_build_object(
            'success', false,
            'error', SQLERRM,
$m$
  ];
  v_count integer;
  i integer;
BEGIN
  v_def := pg_get_functiondef('public.create_dispatch_with_stock_check_internal(jsonb, jsonb[], boolean, text)'::regprocedure);
  FOR i IN 1 .. array_length(v_old, 1) LOOP
    v_count := (length(v_def) - length(replace(v_def, v_old[i], ''))) / length(v_old[i]);
    IF v_count <> 1 THEN
      RAISE EXCEPTION 'create_dispatch_with_stock_check_internal: expected marker % once, found % times', i, v_count;
    END IF;
    v_def := replace(v_def, v_old[i], v_new[i]);
  END LOOP;
  EXECUTE v_def;
END
$patch$;
