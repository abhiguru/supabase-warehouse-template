-- Migration 128: the order history, the order effect of a save, and no empty orders.
--
-- Section 1  get_order_change_log looks up the GRN quantity, rack, weight and packaging of a "Quantity changed" or "Dispatch reduced
--            quantity" entry by the entry's own GRN number, item name and package mark. The unqualified names of the old lookups
--            resolved to the lot's own columns, so both tests were always true and any line of the GRN was returned.
--
-- Section 2  get_order_change_log leaves out the entries whose previous and new quantity are equal. Every order save writes the whole
--            cart, so an unchanged line came back as "30 -> 30" on every save. The first appearance of a line (its addition, with no
--            previous quantity) stays; the count and the paging follow the filter.
--
-- Section 3  The order effect of a save (see the section).
--
-- Section 4  No empty orders (owner decision: an order is made by its first line and gone when its last line goes).
--            A customer has one order row for good (one_cart_per_customer; dispatches, the order history and the order number point
--            at it), so "no empty order" is a rule about what the API shows and makes, not a delete:
--            * get_orders_list leaves out an order that has no line, whatever p_has_items says (the "Empty orders" of the queue, and the
--              empty cart of a deactivated business, are gone). Every way a last line goes (remove, a dispatch that takes all of it, a
--              GRN delete) therefore removes the order from the lists, and every way a line comes back (add_item_to_order, the give-back
--              of a dispatch edit or delete: warehouse_security.restore_to_order, unchanged) makes it appear again, with its number and
--              history.
--            * get_customer_order(p_customer_id) reads the customer's order without making one: exists false for a customer with no
--              order or no line.
--            * add_item_to_order takes p_customer_id instead of p_order_id and makes the order when there is none (or none with a
--              line): the first line makes the order. Its answer names the order.
--            * get_or_create_cart is left as it is for the released app: it still makes the row, but the row is invisible until a line
--              is added, so opening an order no longer shows an "empty order".
--            Orders that are empty today are left as they are (no row is deleted: some carry history, and a delete is not needed to
--            hide them); they come back with their first line. See the note at the end of the section.
--
-- Sections 1 and 2 patch the function with the marker-count pattern of migration 111: every marker must be found exactly
-- the expected number of times, or the migration stops.

-- Section 1: the lookups of the quantity entries name the entry's columns
DO $patch$
DECLARE
  v_def text;
  v_old text[] := ARRAY[
    $m$FROM   item_events_with_prev$m$,
    $m$AND gt.item_name = item_name$m$,
    $m$AND COALESCE(gt.package_mark, '') = COALESCE(package_mark, '')$m$,
    $m$WHERE g.gr_no = grn_no$m$
  ];
  v_new text[] := ARRAY[
    $m$FROM   item_events_with_prev e$m$,
    $m$AND gt.item_name = e.item_name$m$,
    $m$AND COALESCE(gt.package_mark, '') = COALESCE(e.package_mark, '')$m$,
    $m$WHERE g.gr_no = e.grn_no$m$
  ];
  v_expected integer[] := ARRAY[1, 5, 5, 5];
  v_count integer;
  i integer;
BEGIN
  v_def := pg_get_functiondef('public.get_order_change_log(uuid, uuid, timestamp with time zone, timestamp with time zone, uuid, text, integer, integer)'::regprocedure);
  FOR i IN 1 .. array_length(v_old, 1) LOOP
    v_count := (length(v_def) - length(replace(v_def, v_old[i], ''))) / length(v_old[i]);
    IF v_count <> v_expected[i] THEN
      RAISE EXCEPTION 'get_order_change_log: expected marker % % times, found % times', i, v_expected[i], v_count;
    END IF;
    v_def := replace(v_def, v_old[i], v_new[i]);
  END LOOP;
  EXECUTE v_def;
END
$patch$;

-- Section 2: a line whose quantity did not change is not an entry
DO $patch$
DECLARE
  v_def text;
  v_old text[] := ARRAY[
    $m$AND (v_user_role IN ('admin', 'supervisor', 'staff') OR customer_id = ANY(v_accessible_customers))$m$
  ];
  v_new text[] := ARRAY[
    $m$AND (v_user_role IN ('admin', 'supervisor', 'staff') OR customer_id = ANY(v_accessible_customers))
              AND (prev_qty IS NULL OR prev_qty IS DISTINCT FROM qty_after_event)$m$
  ];
  v_count integer;
  i integer;
BEGIN
  v_def := pg_get_functiondef('public.get_order_change_log(uuid, uuid, timestamp with time zone, timestamp with time zone, uuid, text, integer, integer)'::regprocedure);
  FOR i IN 1 .. array_length(v_old, 1) LOOP
    v_count := (length(v_def) - length(replace(v_def, v_old[i], ''))) / length(v_old[i]);
    IF v_count <> 1 THEN
      RAISE EXCEPTION 'get_order_change_log: expected marker % once, found % times', i, v_count;
    END IF;
    v_def := replace(v_def, v_old[i], v_new[i]);
  END LOOP;
  EXECUTE v_def;
END
$patch$;

-- Section 3  The order effect of a save, told before and after (owner decision: "tell, then save").
--
--   A save of a dispatch, a GRN edit or a GRN delete can change the customer's order: a dispatch takes its quantity off the order line
--   of the same lot (or removes the line when it takes all), a dispatch edit or delete gives bags back, a GRN delete removes the
--   lines on its lots, and a GRN edit that lowers a lot's stock can leave an order line asking for more than is left. The app must be
--   able to name those lines before the person saves, and again after.
--
--   * warehouse_security.order_lines_snapshot(lots) and order_effects(lots, snapshot, stock_check): the snapshot is taken after the
--     order lines are locked and before anything is written; the effect is the difference to the lines afterwards, one element per
--     changed line:
--       {customer_id, customer_name, order_id, order_no, order_item_id, grn_item_id, item_name, package_mark, grn_no,
--        old_quantity, new_quantity, removed, change, available_stock, order_lines_left}
--     change: 'reduced', 'increased', 'added' (the line is new), 'removed' (new_quantity 0, removed true) or, for a GRN edit only,
--     'exceeds_stock' (the line is unchanged but asks for more than the lot now holds; old_quantity = new_quantity = the ordered
--     quantity, available_stock the lot's stock). available_stock is null for the other changes. order_item_id is the line as it was
--     before the save, so it is null for an 'added' line. order_lines_left is how many lines
--     the order has afterwards (0: the order is empty).
--   * The real saves carry the list as "order_effects" in their answer: create_dispatch_with_stock_check (through its internal
--     function), update_dispatch_smart, update_grn and delete_grn_safe. Their bodies are in migrations/definitions/ (the snapshot and
--     the answer key are added there). An answer with no effect carries [].
--   * Four new RPCs run the real save and undo it: preview_create_dispatch, preview_update_dispatch, preview_update_grn and
--     preview_delete_grn take the arguments of the real call (a request key is ignored) and answer {success:true, preview:true,
--     order_effects:[...]} or, when the real save would be refused, the real refusal with preview:true added (a refusal the real save
--     raises, such as WH409 "A dispatch needs at least one line", comes back as {success:false, error_code, error, message, preview:true};
--     privilege errors (42501) and faults that are not refusals are raised as the real call raises them). The save runs inside a
--     block that always ends in an error, so nothing it wrote is kept (rows, locks and notifications are rolled back with it); the
--     checks are therefore the real ones, by construction. Unlike a plain read, the preview takes the real save's row locks for the
--     length of the statement (update_grn also takes its table-level trigger lock), and the rolled-back writes leave dead rows for
--     autovacuum.

CREATE FUNCTION warehouse_security.order_lines_snapshot(p_lots uuid[]) RETURNS jsonb
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public'
    AS $$
  SELECT jsonb_build_object(
    'lines', COALESCE((SELECT jsonb_agg(jsonb_build_object(
        'order_id', oi.order_id, 'order_item_id', oi.id, 'grn_item_id', oi.grn_items_id,
        'item_name', oi.grn_items_item_name, 'package_mark', oi.grn_items_package_mark, 'grn_no', oi.grns_gr_no,
        'qty', oi.requested_quantity))
      FROM public.order_items oi WHERE oi.grn_items_id = ANY (p_lots)), '[]'::jsonb),
    'stock', COALESCE((SELECT jsonb_object_agg(t.id::text, t.stock) FROM public.goodsreceived_trl t WHERE t.id = ANY (p_lots)), '{}'::jsonb))
$$;
ALTER FUNCTION warehouse_security.order_lines_snapshot(uuid[]) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION warehouse_security.order_lines_snapshot(uuid[]) FROM PUBLIC;

CREATE FUNCTION warehouse_security.order_effects(p_lots uuid[], p_before jsonb, p_stock_check boolean DEFAULT false) RETURNS jsonb
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public'
    AS $$
  WITH before_lines AS (
    SELECT (l->>'order_id')::uuid AS order_id, (l->>'order_item_id')::uuid AS order_item_id, (l->>'grn_item_id')::uuid AS grn_item_id,
           l->>'item_name' AS item_name, l->>'package_mark' AS package_mark, l->>'grn_no' AS grn_no, (l->>'qty')::integer AS qty
    FROM jsonb_array_elements(COALESCE(p_before->'lines', '[]'::jsonb)) AS l
  ), after_lines AS (
    SELECT oi.order_id, oi.id AS order_item_id, oi.grn_items_id AS grn_item_id, oi.grn_items_item_name AS item_name,
           oi.grn_items_package_mark AS package_mark, oi.grns_gr_no AS grn_no, oi.requested_quantity AS qty
    FROM public.order_items oi WHERE oi.grn_items_id = ANY (p_lots)
  ), changed AS (
    -- order_item_id is the line as it was before the save: null for a line the save made (a preview cannot know the id).
    SELECT COALESCE(a.order_id, b.order_id) AS order_id, b.order_item_id AS order_item_id,
           COALESCE(a.grn_item_id, b.grn_item_id) AS grn_item_id, COALESCE(a.item_name, b.item_name) AS item_name,
           COALESCE(a.package_mark, b.package_mark) AS package_mark, COALESCE(a.grn_no, b.grn_no) AS grn_no,
           COALESCE(b.qty, 0) AS old_qty, COALESCE(a.qty, 0) AS new_qty, NULL::integer AS available_stock
    FROM before_lines b FULL JOIN after_lines a ON a.order_id = b.order_id AND a.grn_item_id = b.grn_item_id
    WHERE COALESCE(b.qty, 0) <> COALESCE(a.qty, 0)
    UNION ALL
    -- A lot whose stock this save lowered below what an order line still asks for (a GRN edit only).
    SELECT a.order_id, a.order_item_id, a.grn_item_id, a.item_name, a.package_mark, a.grn_no, a.qty, a.qty, t.stock
    FROM after_lines a JOIN public.goodsreceived_trl t ON t.id = a.grn_item_id
    WHERE p_stock_check AND a.qty > t.stock AND t.stock < COALESCE((p_before->'stock'->>(a.grn_item_id::text))::integer, t.stock)
  )
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'customer_id', o.customer_id,
      'customer_name', c.name,
      'order_id', ch.order_id,
      'order_no', o.order_no,
      'order_item_id', ch.order_item_id,
      'grn_item_id', ch.grn_item_id,
      'item_name', ch.item_name,
      'package_mark', ch.package_mark,
      'grn_no', ch.grn_no,
      'old_quantity', ch.old_qty,
      'new_quantity', ch.new_qty,
      'removed', ch.new_qty = 0,
      'change', CASE WHEN ch.available_stock IS NOT NULL THEN 'exceeds_stock'
                     WHEN ch.new_qty = 0 THEN 'removed'
                     WHEN ch.old_qty = 0 THEN 'added'
                     WHEN ch.new_qty < ch.old_qty THEN 'reduced'
                     ELSE 'increased' END,
      'available_stock', ch.available_stock,
      'order_lines_left', (SELECT count(*) FROM public.order_items x WHERE x.order_id = ch.order_id)
    ) ORDER BY c.name, ch.item_name, ch.grn_no, ch.package_mark, ch.order_item_id), '[]'::jsonb)
  FROM changed ch
  JOIN public.orders o ON o.id = ch.order_id
  JOIN public.customers c ON c.id = o.customer_id
$$;
ALTER FUNCTION warehouse_security.order_effects(uuid[], jsonb, boolean) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION warehouse_security.order_effects(uuid[], jsonb, boolean) FROM PUBLIC;

-- What a preview answers: the effect of a save that would succeed, or the refusal of one that would not. The ids and numbers of a
-- save that was undone are not returned.
CREATE FUNCTION warehouse_security.preview_answer(p_answer jsonb) RETURNS jsonb
    LANGUAGE sql IMMUTABLE
    SET search_path TO 'pg_catalog'
    AS $$
  SELECT CASE WHEN p_answer->>'success' = 'true'
              THEN jsonb_build_object('success', true, 'preview', true, 'order_effects', COALESCE(p_answer->'order_effects', '[]'::jsonb))
              ELSE COALESCE(p_answer, '{}'::jsonb) || jsonb_build_object('preview', true) END
$$;
ALTER FUNCTION warehouse_security.preview_answer(jsonb) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION warehouse_security.preview_answer(jsonb) FROM PUBLIC;

-- A refusal that the real save raises instead of returning: the same shape as warehouse_security.refuse (success false, error_code = the
-- SQLSTATE, error and message = the text), with preview:true. preview_reraises says which errors are not refusals and are raised as they are.
CREATE FUNCTION warehouse_security.preview_raised(p_sqlstate text, p_message text) RETURNS jsonb
    LANGUAGE sql IMMUTABLE
    SET search_path TO 'pg_catalog'
    AS $$
  SELECT jsonb_build_object('success', false, 'error_code', p_sqlstate, 'error', p_message, 'message', p_message, 'preview', true)
$$;
ALTER FUNCTION warehouse_security.preview_raised(text, text) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION warehouse_security.preview_raised(text, text) FROM PUBLIC;

CREATE FUNCTION warehouse_security.preview_reraises(p_sqlstate text) RETURNS boolean
    LANGUAGE sql IMMUTABLE
    SET search_path TO 'pg_catalog'
    AS $$
  SELECT p_sqlstate = '42501' OR p_sqlstate ~ '^(40|53|54|55|57|58|XX)'
$$;
ALTER FUNCTION warehouse_security.preview_reraises(text) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION warehouse_security.preview_reraises(text) FROM PUBLIC;

CREATE FUNCTION public.preview_create_dispatch(p_dispatch_data jsonb, p_dispatch_items jsonb[]) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'extensions', 'utils', 'pg_temp'
    AS $$
DECLARE
  v_answer jsonb;
  v_detail text;
BEGIN
  PERFORM warehouse_security.authorize_rpc('preview_create_dispatch', jsonb_build_object());
  BEGIN
    v_answer := public.create_dispatch_with_stock_check(p_dispatch_data, p_dispatch_items, false, 0, NULL::text);
    RAISE EXCEPTION 'order_preview' USING ERRCODE = 'WHPRV', DETAIL = COALESCE(v_answer, '{}'::jsonb)::text;
  EXCEPTION WHEN SQLSTATE 'WHPRV' THEN
    GET STACKED DIAGNOSTICS v_detail = PG_EXCEPTION_DETAIL;
    RETURN warehouse_security.preview_answer(v_detail::jsonb);
  WHEN OTHERS THEN
    -- A refusal the real save RAISES (a named error such as WH409) comes back as the refusal, with preview:true. Privilege errors, and
    -- faults that are not refusals (a lock or serialization failure, a full disk, a shut-down server), are raised as the real call raises them.
    IF warehouse_security.preview_reraises(SQLSTATE) THEN RAISE; END IF;
    RETURN warehouse_security.preview_raised(SQLSTATE, SQLERRM);
  END;
END $$;
ALTER FUNCTION public.preview_create_dispatch(jsonb, jsonb[]) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION public.preview_create_dispatch(jsonb, jsonb[]) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.preview_create_dispatch(jsonb, jsonb[]) TO authenticated, service_role;

CREATE FUNCTION public.preview_update_dispatch(p_dispatch_id uuid, p_dispatch_data jsonb, p_dispatch_items jsonb[]) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'extensions', 'utils', 'pg_temp'
    AS $$
DECLARE
  v_answer jsonb;
  v_detail text;
BEGIN
  PERFORM warehouse_security.authorize_rpc('preview_update_dispatch', jsonb_build_object('p_dispatch_id', p_dispatch_id));
  BEGIN
    -- A request key would answer from a saved answer: the preview never uses one.
    v_answer := public.update_dispatch_smart(p_dispatch_id, COALESCE(p_dispatch_data, '{}'::jsonb) - 'request_key', p_dispatch_items);
    RAISE EXCEPTION 'order_preview' USING ERRCODE = 'WHPRV', DETAIL = COALESCE(v_answer, '{}'::jsonb)::text;
  EXCEPTION WHEN SQLSTATE 'WHPRV' THEN
    GET STACKED DIAGNOSTICS v_detail = PG_EXCEPTION_DETAIL;
    RETURN warehouse_security.preview_answer(v_detail::jsonb);
  WHEN OTHERS THEN
    -- A refusal the real save RAISES (a named error such as WH409) comes back as the refusal, with preview:true. Privilege errors, and
    -- faults that are not refusals (a lock or serialization failure, a full disk, a shut-down server), are raised as the real call raises them.
    IF warehouse_security.preview_reraises(SQLSTATE) THEN RAISE; END IF;
    RETURN warehouse_security.preview_raised(SQLSTATE, SQLERRM);
  END;
END $$;
ALTER FUNCTION public.preview_update_dispatch(uuid, jsonb, jsonb[]) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION public.preview_update_dispatch(uuid, jsonb, jsonb[]) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.preview_update_dispatch(uuid, jsonb, jsonb[]) TO authenticated, service_role;

CREATE FUNCTION public.preview_update_grn(p_grn_id uuid,
    p_gr_no character varying DEFAULT NULL::character varying,
    p_date timestamp with time zone DEFAULT NULL::timestamp with time zone,
    p_customer_id uuid DEFAULT NULL::uuid,
    p_customer_name character varying DEFAULT NULL::character varying,
    p_sender_id uuid DEFAULT NULL::uuid,
    p_sender_name character varying DEFAULT NULL::character varying,
    p_supervisor_id uuid DEFAULT NULL::uuid,
    p_supervisor_name character varying DEFAULT NULL::character varying,
    p_registration character varying DEFAULT NULL::character varying,
    p_note character varying DEFAULT NULL::character varying,
    p_leon boolean DEFAULT NULL::boolean,
    p_pricing_mode character varying DEFAULT NULL::character varying,
    p_items jsonb DEFAULT '[]'::jsonb,
    p_images jsonb DEFAULT '[]'::jsonb,
    p_duration_mode character varying DEFAULT NULL::character varying,
    p_idempotency_key text DEFAULT NULL::text,
    p_rates jsonb DEFAULT NULL::jsonb,
    p_expected_updated_at timestamp with time zone DEFAULT NULL::timestamp with time zone) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'extensions', 'utils', 'pg_temp'
    SET jit TO 'off'
    AS $$
DECLARE
  v_answer jsonb;
  v_detail text;
BEGIN
  PERFORM warehouse_security.authorize_rpc('preview_update_grn', jsonb_build_object('p_grn_id', p_grn_id, 'p_customer_id', p_customer_id));
  BEGIN
    -- The request key is not passed: the preview never answers from, or stores, a saved answer.
    v_answer := public.update_grn(
        p_grn_id => p_grn_id,
        p_gr_no => p_gr_no,
        p_date => p_date,
        p_customer_id => p_customer_id,
        p_customer_name => p_customer_name,
        p_sender_id => p_sender_id,
        p_sender_name => p_sender_name,
        p_supervisor_id => p_supervisor_id,
        p_supervisor_name => p_supervisor_name,
        p_registration => p_registration,
        p_note => p_note,
        p_leon => p_leon,
        p_pricing_mode => p_pricing_mode,
        p_items => p_items,
        p_images => p_images,
        p_duration_mode => p_duration_mode,
        p_idempotency_key => NULL::text,
        p_rates => p_rates,
        p_expected_updated_at => p_expected_updated_at);
    RAISE EXCEPTION 'order_preview' USING ERRCODE = 'WHPRV', DETAIL = COALESCE(v_answer, '{}'::jsonb)::text;
  EXCEPTION WHEN SQLSTATE 'WHPRV' THEN
    GET STACKED DIAGNOSTICS v_detail = PG_EXCEPTION_DETAIL;
    RETURN warehouse_security.preview_answer(v_detail::jsonb);
  WHEN OTHERS THEN
    -- A refusal the real save RAISES (a named error such as WH409) comes back as the refusal, with preview:true. Privilege errors, and
    -- faults that are not refusals (a lock or serialization failure, a full disk, a shut-down server), are raised as the real call raises them.
    IF warehouse_security.preview_reraises(SQLSTATE) THEN RAISE; END IF;
    RETURN warehouse_security.preview_raised(SQLSTATE, SQLERRM);
  END;
END $$;
ALTER FUNCTION public.preview_update_grn(uuid,character varying,timestamp with time zone,uuid,character varying,uuid,character varying,uuid,character varying,character varying,character varying,boolean,character varying,jsonb,jsonb,character varying,text,jsonb,timestamp with time zone) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION public.preview_update_grn(uuid,character varying,timestamp with time zone,uuid,character varying,uuid,character varying,uuid,character varying,character varying,character varying,boolean,character varying,jsonb,jsonb,character varying,text,jsonb,timestamp with time zone) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.preview_update_grn(uuid,character varying,timestamp with time zone,uuid,character varying,uuid,character varying,uuid,character varying,character varying,character varying,boolean,character varying,jsonb,jsonb,character varying,text,jsonb,timestamp with time zone) TO authenticated, service_role;

CREATE FUNCTION public.preview_delete_grn(p_grn_id uuid) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'extensions', 'utils', 'pg_temp'
    AS $$
DECLARE
  v_answer jsonb;
  v_detail text;
BEGIN
  PERFORM warehouse_security.authorize_rpc('preview_delete_grn', jsonb_build_object('p_grn_id', p_grn_id));
  BEGIN
    v_answer := public.delete_grn_safe(p_grn_id);
    RAISE EXCEPTION 'order_preview' USING ERRCODE = 'WHPRV', DETAIL = COALESCE(v_answer, '{}'::jsonb)::text;
  EXCEPTION WHEN SQLSTATE 'WHPRV' THEN
    GET STACKED DIAGNOSTICS v_detail = PG_EXCEPTION_DETAIL;
    RETURN warehouse_security.preview_answer(v_detail::jsonb);
  WHEN OTHERS THEN
    -- A refusal the real save RAISES (a named error such as WH409) comes back as the refusal, with preview:true. Privilege errors, and
    -- faults that are not refusals (a lock or serialization failure, a full disk, a shut-down server), are raised as the real call raises them.
    IF warehouse_security.preview_reraises(SQLSTATE) THEN RAISE; END IF;
    RETURN warehouse_security.preview_raised(SQLSTATE, SQLERRM);
  END;
END $$;
ALTER FUNCTION public.preview_delete_grn(uuid) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION public.preview_delete_grn(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.preview_delete_grn(uuid) TO authenticated, service_role;

-- Section 4: no empty orders

-- 4a. The list leaves out an order without a line (the count and the page).
DO $patch$
DECLARE
  v_def text;
  v_old text[] := ARRAY[
    $m$AND (p_has_items IS NULL OR$m$
  ];
  v_new text[] := ARRAY[
    $m$AND jsonb_array_length(m.items_jsonb) > 0
      AND (p_has_items IS NULL OR$m$
  ];
  v_count integer;
  i integer;
BEGIN
  v_def := pg_get_functiondef('public.get_orders_list(uuid, text, boolean, uuid, integer, integer, text)'::regprocedure);
  FOR i IN 1 .. array_length(v_old, 1) LOOP
    v_count := (length(v_def) - length(replace(v_def, v_old[i], ''))) / length(v_old[i]);
    IF v_count <> 2 THEN
      RAISE EXCEPTION 'get_orders_list: expected marker % twice, found % times', i, v_count;
    END IF;
    v_def := replace(v_def, v_old[i], v_new[i]);
  END LOOP;
  EXECUTE v_def;
END
$patch$;

-- 4b. A read that never makes an order. The guard treats a get_customer_* call as the customer's own (p_customer_id).
CREATE FUNCTION public.get_customer_order(p_customer_id uuid) RETURNS jsonb
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'extensions', 'utils', 'pg_temp'
    AS $$
DECLARE
  v_order record;
BEGIN
  PERFORM warehouse_security.authorize_rpc('get_customer_order', jsonb_build_object('p_customer_id', p_customer_id));
  SELECT o.id, o.order_no, o.status, o.updated_at, (SELECT count(*) FROM public.order_items oi WHERE oi.order_id = o.id) AS lines
  INTO v_order
  FROM public.orders o
  WHERE o.customer_id = p_customer_id AND o.deleted_at IS NULL;
  IF NOT FOUND OR v_order.lines = 0 THEN
    RETURN jsonb_build_object('success', true, 'data', jsonb_build_object(
      'exists', false, 'order_id', NULL, 'order_no', NULL, 'status', NULL, 'item_count', 0, 'updated_at', NULL));
  END IF;
  RETURN jsonb_build_object('success', true, 'data', jsonb_build_object(
    'exists', true, 'order_id', v_order.id, 'order_no', v_order.order_no, 'status', v_order.status,
    'item_count', v_order.lines, 'updated_at', v_order.updated_at));
END $$;
ALTER FUNCTION public.get_customer_order(uuid) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION public.get_customer_order(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.get_customer_order(uuid) TO authenticated, service_role;

-- 4c. add_item_to_order makes the order. The three arguments of the released app keep their names and positions; p_customer_id is new
-- and p_order_id may now be left out (a new signature, so the old one is dropped and PostgREST sees one function). With p_order_id the
-- function is the one of migration 121 (the order must exist and be OPEN). With only p_customer_id it finds the customer's order or
-- makes it (as get_or_create_cart makes it); an order that has no line yet starts again as a new one (note, priority and dates reset,
-- the name and contact refreshed); a DISPATCHED order is opened, as get_or_create_cart opens it. The answer names the order
-- (data.order_id) and says whether this line made it (data.order_created).
DROP FUNCTION public.add_item_to_order(uuid, uuid, integer);
CREATE FUNCTION public.add_item_to_order(p_order_id uuid DEFAULT NULL::uuid, p_grn_item_id uuid DEFAULT NULL::uuid, p_quantity integer DEFAULT NULL::integer, p_customer_id uuid DEFAULT NULL::uuid) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'extensions', 'warehouse_security', 'pg_temp'
    AS $$
DECLARE
  v_user_id uuid;
  v_order record;
  v_item record;
  v_new_item_id uuid;
  v_new_item_updated_at timestamptz;
  v_order_no text;
  v_order_id uuid := p_order_id;
  v_created boolean := false;
  v_customer record;
  v_pre record;
  v_pre_order record;
  v_pre_lines boolean;
BEGIN
  PERFORM warehouse_security.authorize_rpc(
    'add_item_to_order',
    jsonb_build_object('p_order_id', p_order_id, 'p_grn_item_id', p_grn_item_id, 'p_customer_id', p_customer_id)
  );

  IF p_quantity IS NULL OR p_quantity <= 0 THEN
    RETURN jsonb_build_object('success', false, 'message', 'Quantity must be greater than zero');
  END IF;
  IF p_order_id IS NULL AND p_customer_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'message', 'Order not found');
  END IF;

  SELECT id INTO v_user_id
  FROM public.user_profiles
  WHERE auth_user_id = auth.uid() AND active;

  IF v_order_id IS NULL THEN
    -- The first line makes the order (the customer's one order row: one_cart_per_customer).
    SELECT c.id, c.name, c.email, c.mobile, c.deleted_at INTO v_customer FROM public.customers c WHERE c.id = p_customer_id;
    IF NOT FOUND THEN
      RETURN jsonb_build_object('success', false, 'message', 'Customer not found');
    END IF;
    IF v_customer.deleted_at IS NOT NULL THEN
      RETURN jsonb_build_object('success', false, 'message', 'Business is not active', 'error', jsonb_build_object('code', 'BUSINESS_NOT_ACTIVE'));
    END IF;

    -- Every refusal that is returned (not raised) comes before the order is made or reset, so a refused call writes nothing.
    SELECT gt.stock, g.customer_id, g.deleted_at AS gr_deleted_at INTO v_pre
    FROM public.goodsreceived_trl gt JOIN public.goodsreceived g ON g.id = gt.gr_id WHERE gt.id = p_grn_item_id;
    IF NOT FOUND OR v_pre.gr_deleted_at IS NOT NULL THEN
      RETURN jsonb_build_object('success', false, 'message', 'GRN item not found');
    END IF;
    IF v_pre.customer_id IS DISTINCT FROM p_customer_id THEN
      RAISE EXCEPTION 'Item belongs to another customer' USING ERRCODE = '42501';
    END IF;
    SELECT o.id, o.status INTO v_pre_order FROM public.orders o WHERE o.customer_id = p_customer_id AND o.deleted_at IS NULL;
    IF FOUND THEN
      SELECT EXISTS (SELECT 1 FROM public.order_items oi WHERE oi.order_id = v_pre_order.id) INTO v_pre_lines;
      IF v_pre_lines THEN
        IF v_pre_order.status NOT IN ('OPEN', 'DISPATCHED') THEN
          RETURN jsonb_build_object('success', false, 'message', 'Cannot add items to ' || v_pre_order.status || ' orders',
                                    'error', jsonb_build_object('code', 'ORDER_NOT_OPEN'));
        END IF;
        IF EXISTS (SELECT 1 FROM public.order_items oi WHERE oi.order_id = v_pre_order.id AND oi.grn_items_id = p_grn_item_id) THEN
          RETURN jsonb_build_object('success', false, 'message', 'Item already exists in order');
        END IF;
      END IF;
    END IF;
    IF v_pre.stock < p_quantity THEN
      RETURN jsonb_build_object('success', false, 'message', format('Insufficient stock. Available: %s, Requested: %s', v_pre.stock, p_quantity));
    END IF;

    SELECT o.id INTO v_order_id FROM public.orders o WHERE o.customer_id = p_customer_id AND o.deleted_at IS NULL;
    IF v_order_id IS NULL THEN
      IF EXISTS (SELECT 1 FROM public.orders o WHERE o.customer_id = p_customer_id) THEN
        -- A soft-deleted order of this customer holds the one row; it is not reopened here.
        RETURN jsonb_build_object('success', false, 'message', 'Order not found');
      END IF;
      INSERT INTO public.orders (customer_id, customer_name, customer_email, customer_phone, order_date, requested_dispatch_date,
                                 status, priority, created_by, updated_by)
      VALUES (p_customer_id, v_customer.name, v_customer.email, v_customer.mobile, now(), now() + interval '7 days',
              'OPEN', 'normal', v_user_id, v_user_id)
      ON CONFLICT DO NOTHING
      RETURNING id INTO v_order_id;
      IF v_order_id IS NOT NULL THEN
        v_created := true;
      ELSE
        -- Another phone made it between the read and the insert.
        SELECT o.id INTO v_order_id FROM public.orders o WHERE o.customer_id = p_customer_id AND o.deleted_at IS NULL;
        IF v_order_id IS NULL THEN
          RETURN jsonb_build_object('success', false, 'message', 'Order not found');
        END IF;
      END IF;
    END IF;

    IF NOT v_created AND NOT EXISTS (SELECT 1 FROM public.order_items oi WHERE oi.order_id = v_order_id) THEN
      -- An order whose last line went starts again with this line: a new order in everything but its number and history.
      UPDATE public.orders
      SET status = 'OPEN', customer_name = v_customer.name, customer_email = v_customer.email, customer_phone = v_customer.mobile,
          order_date = now(), requested_dispatch_date = now() + interval '7 days', note = NULL, priority = 'normal',
          updated_at = now(), updated_by = v_user_id
      WHERE id = v_order_id;
      v_created := true;
    ELSE
      UPDATE public.orders SET status = 'OPEN', updated_at = now(), updated_by = v_user_id
      WHERE id = v_order_id AND status = 'DISPATCHED';
    END IF;
  END IF;

  SELECT o.*, c.name AS current_customer_name
  INTO v_order
  FROM public.orders o
  JOIN public.customers c ON c.id = o.customer_id
  WHERE o.id = v_order_id AND o.deleted_at IS NULL;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'message', 'Order not found');
  END IF;
  IF v_order.status <> 'OPEN' THEN
    RETURN jsonb_build_object(
      'success', false,
      'message', 'Cannot add items to ' || v_order.status || ' orders',
      'error', jsonb_build_object('code', 'ORDER_NOT_OPEN')
    );
  END IF;

  SELECT
    gt.*,
    g.gr_no,
    g.date AS gr_date,
    g.customer_id,
    g.customer_name,
    g.gr_image_url,
    g.deleted_at AS gr_deleted_at
  INTO v_item
  FROM public.goodsreceived_trl gt
  JOIN public.goodsreceived g ON g.id = gt.gr_id
  WHERE gt.id = p_grn_item_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'message', 'GRN item not found');
  END IF;
  -- The lots of a deleted receipt are not in any list and cannot be ordered (migration 120).
  IF v_item.gr_deleted_at IS NOT NULL THEN
    RETURN jsonb_build_object('success', false, 'message', 'GRN item not found');
  END IF;
  IF v_item.customer_id IS DISTINCT FROM v_order.customer_id THEN
    RAISE EXCEPTION 'Item belongs to another customer' USING ERRCODE = '42501';
  END IF;
  IF EXISTS (
    SELECT 1 FROM public.order_items
    WHERE order_id = v_order_id AND grn_items_id = p_grn_item_id
  ) THEN
    RETURN jsonb_build_object('success', false, 'message', 'Item already exists in order');
  END IF;
  IF v_item.stock < p_quantity THEN
    RETURN jsonb_build_object(
      'success', false,
      'message', format('Insufficient stock. Available: %s, Requested: %s', v_item.stock, p_quantity)
    );
  END IF;

  v_order_no := NULLIF(v_order.order_no, '');
  IF v_order_no IS NULL THEN
    v_order_no := 'ORD-' || to_char(current_date, 'YYYYMMDD') || '-' || substring(v_order_id::text FROM 1 FOR 8);
    UPDATE public.orders SET order_no = v_order_no WHERE id = v_order_id;
  END IF;

  INSERT INTO public.order_items (
    order_id, order_no, requested_quantity,
    grn_items_id, grn_items_item_id, grn_items_item_name,
    grn_items_package_mark, grn_items_packaging, grn_items_rack,
    grn_items_weight, grn_items_image_url,
    grns_id, grns_gr_no, grns_date, grns_customer_id, grns_customer_name,
    available_stock_at_order, current_stock, item_status, sort_order
  ) VALUES (
    v_order_id, v_order_no, p_quantity,
    p_grn_item_id, v_item.item_id, v_item.item_name,
    COALESCE(v_item.package_mark, ''), COALESCE(v_item.packaging, ''), COALESCE(v_item.rack, ''),
    COALESCE(v_item.weight, 0), v_item.trl_img_url,
    v_item.gr_id, v_item.gr_no, v_item.gr_date, v_item.customer_id,
    COALESCE(v_item.customer_name, v_order.current_customer_name, ''),
    v_item.stock, v_item.stock, 'pending',
    COALESCE((SELECT max(sort_order) + 1 FROM public.order_items WHERE order_id = v_order_id), 1)
  ) RETURNING id, updated_at INTO v_new_item_id, v_new_item_updated_at;

  PERFORM warehouse_security.record_order_revision(v_order_id, v_user_id);
  UPDATE public.orders SET updated_at = now(), updated_by = v_user_id WHERE id = v_order_id;

  RETURN jsonb_build_object(
    'success', true,
    'message', 'Item added to order successfully',
    'data', jsonb_build_object(
      'order_item_id', v_new_item_id,
      'item_name', v_item.item_name,
      'quantity', p_quantity,
      'order_no', v_order_no,
      'order_id', v_order_id,
      'order_created', v_created,
      'updated_at', v_new_item_updated_at
    )
  );
EXCEPTION
  WHEN insufficient_privilege THEN RAISE;
  -- A concurrent add of the same lot loses the race on the unique constraint.
  WHEN unique_violation THEN
    RETURN jsonb_build_object('success', false, 'message', 'Item already exists in order');
  WHEN OTHERS THEN
    RETURN jsonb_build_object('success', false, 'message', 'Error adding item: ' || SQLERRM);
END;
$$;
ALTER FUNCTION public.add_item_to_order(uuid, uuid, integer, uuid) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION public.add_item_to_order(uuid, uuid, integer, uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.add_item_to_order(uuid, uuid, integer, uuid) TO service_role;
GRANT ALL ON FUNCTION public.add_item_to_order(uuid, uuid, integer, uuid) TO authenticated;

-- Orders that are empty today are left as they are. The one order row of a customer is referenced by dispatches (source_order_id, no
-- cascade), by the order history (order_revisions, cascade) and by its order number (unique), so deleting a row would either fail or
-- lose history; and the new list already leaves every empty order out, so nothing is needed to hide them. An empty order comes back
-- with its first line (add_item_to_order), or with the lines a dispatch edit or delete gives back, under the same number.
