-- Migration 133: the order history tells the right bag counts around a dispatch that is deleted (device re-test B13).
--
-- Found in a device test, 2026-11-01: an order line of 20 was taken whole by a dispatch (line removed), and the dispatch was then deleted.
-- The history said "0 bags given back" for the delete and "12 -> 0 / -12" for the dispatch's take. Two causes, both in
-- get_order_change_log:
--
--   * The entry of a deleted dispatch (change_details.action 'dispatch_deleted') carried the count only as
--     restoration_details.quantity_restored. The app reads change_details.total_quantity_restored (the key of the stored revision),
--     which the entry did not have, so it showed 0. The entry now carries total_quantity_restored: the bags given back to the
--     line that entry is about (one entry is listed per restored line).
--   * The "before" quantity of every entry was the quantity of the previous event of the line. A dispatch delete gives bags back
--     without writing a new quantity, so the next dispatch's take was measured from the quantity before the give-back (12, not 20).
--     (1) A dispatch take now uses the previous_quantity its own revision stored (the line's quantity the moment the dispatch took
--     from it); revisions that have none (old ones) keep the earlier rule. (2) The give-back of a dispatch delete now counts in the
--     chain of the line (its quantity afterwards is the quantity before it plus what was given back), so the next entry of the
--     line, for instance a plain quantity save, starts from the right number.
--
-- A line that comes back after it was removed (quantity 0 before) is now reported as change_type 'added' like a first add, so the
-- app does not have to guess (it already reads previous_quantity 0 the same way). previous_quantity stays 0 in both cases.
--
-- A give-back counts in the chain only when the same dispatch also has a reduction of that line written by the code of migration 121
-- (one that carries previous_quantity); it is capped at what that reduction took. The 'dispatch_deleted' entries written before 121 listed
-- every dispatch line with its dispatched quantity, not what really went back, so they do not change the chain (their text stays as it was).
-- Two cases stay at the numbers before 133 (never worse, only the "before" quantity of the next entry is affected): a dispatch made before 121
-- (its reduction has no previous_quantity) and deleted after it; and a give-back to a cart other than the order that holds the reduction
-- (restore_to_order). Do not "fix" them by counting a give-back without its matching reduction: pre-121 delete entries list the dispatched
-- quantity, not what went back.
-- Events of one time are ordered by the revision id (the order the rows were written). Malformed old entries (a quantity that is not a number,
-- an id that is not a uuid, a timestamp that is not a time, restored_items that is not an array) are treated as absent, never an error,
-- in both arms of 'dispatch_deleted'.
--
-- No column or key is removed. The new key is change_details.total_quantity_restored on 'dispatch_deleted' entries.
-- Patched with the marker-count pattern of migration 111: every marker must be found exactly once, or the migration stops.
-- A timestamp read from a stored revision entry: NULL for text that is not a timestamp, never an error (an old malformed entry must not
-- make every history call fail).
CREATE FUNCTION warehouse_security.try_timestamptz(p_text text) RETURNS timestamptz
    LANGUAGE plpgsql STABLE
    SET search_path TO 'pg_catalog'
    AS $$
BEGIN
  RETURN p_text::timestamptz;
EXCEPTION WHEN OTHERS THEN
  RETURN NULL;
END $$;
ALTER FUNCTION warehouse_security.try_timestamptz(text) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION warehouse_security.try_timestamptz(text) FROM PUBLIC, anon, authenticated;

DO $patch$
DECLARE
  v_def text;
  v_old text[] := ARRAY[
    -- 1  branch "Manual UPDATEs": the two new columns
    $m$                  ci.value as full_item_data
              FROM   orders o
              JOIN (SELECT order_id, entry AS value FROM public.order_revisions) r ON r.order_id = o.id
$m$,
    -- 2  branch "OLD-format auto_quantity_reduction"
    $m$                  ci.value
              FROM   orders o
              JOIN (SELECT order_id, entry AS value FROM public.order_revisions) r ON r.order_id = o.id
$m$,
    -- 3  branch "NEW-format auto_quantity_reduction": the quantity the dispatch found on the line
    $m$                      'package_mark', gt.package_mark
                  )
              FROM   orders o
              JOIN (SELECT order_id, entry AS value FROM public.order_revisions) r ON r.order_id = o.id
$m$,
    -- 4  the give-back of a dispatch delete joins the stream
    $m$                AND  r.value ? 'grn_item_id'
          ),
$m$,
    -- 5  the chain of the line
    $m$          item_events_with_prev AS (
              SELECT *,
                     lag(qty_after_event) OVER (
                         PARTITION BY order_id, item_key
                         ORDER BY ts
                     ) AS prev_qty
              FROM (
                  SELECT *,
                         (grn_no || '|' || COALESCE(package_mark,'') || '|' || item_name) AS item_key
                  FROM item_events
              ) x
          ),
$m$,
    -- 6  added also after a removal
    $m$WHEN prev_qty IS NULL THEN 'added'$m$,
    -- 7  the give-back is not an entry of this kind
    $m$              AND (prev_qty IS NULL OR prev_qty IS DISTINCT FROM qty_after_event)
$m$,
    -- 8  the count the app reads
    $m$                      'restoration_details', jsonb_build_object($m$,
    -- 9..13 the same guards on the rest of that arm
    $m$'quantity_restored', (ri.value->>'quantity_restored')::INT,$m$,
    $m$CROSS JOIN LATERAL jsonb_array_elements(r.value->'restored_items') ri$m$,
    $m$(r.value->>'timestamp')::TIMESTAMP WITH TIME ZONE as change_timestamp,$m$,
    $m$(r.value->>'timestamp')::TIMESTAMP WITH TIME ZONE >= p_date_from$m$,
    $m$(r.value->>'timestamp')::TIMESTAMP WITH TIME ZONE <= p_date_to$m$
  ];
  v_new text[] := ARRAY[
    $m$                  ci.value as full_item_data,
                  NULL::int as stored_prev_qty,
                  NULL::int as restored_qty,
                  r.rev_id
              FROM   orders o
              JOIN (SELECT id AS rev_id, order_id, entry AS value FROM public.order_revisions) r ON r.order_id = o.id
$m$,
    $m$                  ci.value,
                  NULL::int,
                  NULL::int,
                  r.rev_id
              FROM   orders o
              JOIN (SELECT id AS rev_id, order_id, entry AS value FROM public.order_revisions) r ON r.order_id = o.id
$m$,
    $m$                      'package_mark', gt.package_mark
                  ),
                  CASE WHEN r.value->>'previous_quantity' ~ '^[0-9]{1,9}$' THEN (r.value->>'previous_quantity')::int END,
                  NULL::int,
                  r.rev_id
              FROM   orders o
              JOIN (SELECT id AS rev_id, order_id, entry AS value FROM public.order_revisions) r ON r.order_id = o.id
$m$,
    $m$                AND  r.value ? 'grn_item_id'

              UNION ALL

              -- The give-back of a deleted dispatch (migration 133): not an entry of its own here, but the line has that many more
              SELECT
                  o.id,
                  o.order_no,
                  o.customer_id,
                  o.customer_name,
                  COALESCE(warehouse_security.try_timestamptz(r.value->>'timestamp'),
                           warehouse_security.try_timestamptz(r.value->>'at')),
                  'DISPATCH_RESTORE',
                  NULL::text,
                  ri.value->>'grn_no',
                  ri.value->>'item_name',
                  ri.value->>'package_mark',
                  NULL::int,
                  NULL::uuid,
                  CASE WHEN r.value->>'dispatch_id' ~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
                       THEN (r.value->>'dispatch_id')::uuid END,
                  r.value->>'dispatch_no',
                  NULL::jsonb,
                  NULL::int,
                  LEAST(rq.restored, rq.took),
                  r.rev_id
              FROM   orders o
              JOIN (SELECT id AS rev_id, order_id, entry AS value FROM public.order_revisions WHERE action = 'dispatch_deleted') r ON r.order_id = o.id
              CROSS  JOIN LATERAL jsonb_array_elements(
                         CASE WHEN jsonb_typeof(r.value->'restored_items') = 'array' THEN r.value->'restored_items' ELSE '[]'::jsonb END) ri
              CROSS  JOIN LATERAL (
                  SELECT CASE WHEN ri.value->>'quantity_restored' ~ '^[0-9]{1,9}$' THEN (ri.value->>'quantity_restored')::int END AS restored,
                         -- what the dispatch's own reduction (121 format, with previous_quantity) took from this line
                         (SELECT sum(GREATEST(0, (q.entry->>'previous_quantity')::int - (q.entry->>'new_quantity')::int))::int
                          FROM   public.order_revisions q
                          JOIN   goodsreceived_trl gt ON gt.id::text = q.entry->>'grn_item_id'
                          JOIN   goodsreceived gr ON gr.id = gt.gr_id
                          WHERE  q.order_id = o.id
                            AND  q.action = 'auto_quantity_reduction'
                            AND  q.entry->>'dispatch_id' = r.value->>'dispatch_id'
                            AND  q.entry->>'previous_quantity' ~ '^[0-9]{1,9}$'
                            AND  q.entry->>'new_quantity' ~ '^[0-9]{1,9}$'
                            AND  gr.gr_no = ri.value->>'grn_no'
                            AND  gt.item_name = ri.value->>'item_name'
                            AND  COALESCE(gt.package_mark, '') = COALESCE(ri.value->>'package_mark', '')) AS took
              ) rq
              WHERE  (ri.value->>'item_name') IS NOT NULL
                AND  (ri.value->>'grn_no') IS NOT NULL
                AND  rq.restored IS NOT NULL
                AND  rq.took IS NOT NULL
          ),
$m$,
    $m$          item_events_with_prev AS (
              SELECT y.*,
                     CASE
                         WHEN y.action = 'DISPATCH_REDUCTION' AND y.stored_prev_qty IS NOT NULL THEN y.stored_prev_qty
                         ELSE lag(y.eff_qty) OVER (
                                  PARTITION BY y.order_id, y.item_key
                                  ORDER BY y.ts, y.rev_id
                              )
                     END AS prev_qty
              FROM (
                  -- eff_qty: the line's quantity after the event. A give-back counts from the last known quantity of the line.
                  SELECT w.*,
                         CASE
                             WHEN w.action = 'DISPATCH_RESTORE'
                             THEN COALESCE(first_value(w.qty_after_event) OVER (PARTITION BY w.order_id, w.item_key, w.grp ORDER BY w.ts, w.rev_id), 0)
                                  + sum(w.restored_qty) OVER (PARTITION BY w.order_id, w.item_key, w.grp ORDER BY w.ts, w.rev_id)
                             ELSE w.qty_after_event
                         END AS eff_qty
                  FROM (
                      -- grp: how many events with a known quantity the line has had so far (a give-back joins the group before it)
                      SELECT x.*,
                             count(x.qty_after_event) OVER (PARTITION BY x.order_id, x.item_key ORDER BY x.ts, x.rev_id) AS grp
                      FROM (
                          SELECT *,
                                 (grn_no || '|' || COALESCE(package_mark,'') || '|' || item_name) AS item_key
                          FROM item_events
                      ) x
                  ) w
              ) y
          ),
$m$,
    $m$WHEN prev_qty IS NULL OR (prev_qty = 0 AND qty_after_event > 0) THEN 'added'$m$,
    $m$              AND (prev_qty IS NULL OR prev_qty IS DISTINCT FROM qty_after_event)
              AND action <> 'DISPATCH_RESTORE'
$m$,
    $m$                      'total_quantity_restored', CASE WHEN ri.value->>'quantity_restored' ~ '^[0-9]{1,9}$' THEN (ri.value->>'quantity_restored')::INT END,
                      'restoration_details', jsonb_build_object($m$,
    $m$'quantity_restored', CASE WHEN ri.value->>'quantity_restored' ~ '^[0-9]{1,9}$' THEN (ri.value->>'quantity_restored')::INT END,$m$,
    $m$CROSS JOIN LATERAL jsonb_array_elements(CASE WHEN jsonb_typeof(r.value->'restored_items') = 'array' THEN r.value->'restored_items' ELSE '[]'::jsonb END) ri$m$,
    $m$warehouse_security.try_timestamptz(r.value->>'timestamp') as change_timestamp,$m$,
    $m$warehouse_security.try_timestamptz(r.value->>'timestamp') >= p_date_from$m$,
    $m$warehouse_security.try_timestamptz(r.value->>'timestamp') <= p_date_to$m$
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

-- The order effect of a save also names the packaging of the line ('Bag', 'Box', 'Crate', as the order line / GRN item has it), so the app
-- can say "boxes" or "crates" where it said "bags". An additive key of every element of order_effects (the real saves and the four
-- preview_* functions share this builder). The snapshot keeps it for lines whose lot a GRN delete takes away.
CREATE OR REPLACE FUNCTION warehouse_security.order_lines_snapshot(p_lots uuid[]) RETURNS jsonb
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public'
    AS $$
  SELECT jsonb_build_object(
    'lines', COALESCE((SELECT jsonb_agg(jsonb_build_object(
        'order_id', oi.order_id, 'order_item_id', oi.id, 'grn_item_id', oi.grn_items_id,
        'item_name', oi.grn_items_item_name, 'packaging', oi.grn_items_packaging, 'package_mark', oi.grn_items_package_mark, 'grn_no', oi.grns_gr_no,
        'qty', oi.requested_quantity))
      FROM public.order_items oi WHERE oi.grn_items_id = ANY (p_lots)), '[]'::jsonb),
    'stock', COALESCE((SELECT jsonb_object_agg(t.id::text, t.stock) FROM public.goodsreceived_trl t WHERE t.id = ANY (p_lots)), '{}'::jsonb))
$$;

CREATE OR REPLACE FUNCTION warehouse_security.order_effects(p_lots uuid[], p_before jsonb, p_stock_check boolean DEFAULT false) RETURNS jsonb
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public'
    AS $$
  WITH before_lines AS (
    SELECT (l->>'order_id')::uuid AS order_id, (l->>'order_item_id')::uuid AS order_item_id, (l->>'grn_item_id')::uuid AS grn_item_id,
           l->>'item_name' AS item_name, l->>'package_mark' AS package_mark, l->>'packaging' AS packaging, l->>'grn_no' AS grn_no, (l->>'qty')::integer AS qty
    FROM jsonb_array_elements(COALESCE(p_before->'lines', '[]'::jsonb)) AS l
  ), after_lines AS (
    SELECT oi.order_id, oi.id AS order_item_id, oi.grn_items_id AS grn_item_id, oi.grn_items_item_name AS item_name,
           oi.grn_items_package_mark AS package_mark, oi.grn_items_packaging AS packaging, oi.grns_gr_no AS grn_no, oi.requested_quantity AS qty
    FROM public.order_items oi WHERE oi.grn_items_id = ANY (p_lots)
  ), changed AS (
    -- order_item_id is the line as it was before the save: null for a line the save made (a preview cannot know the id).
    SELECT COALESCE(a.order_id, b.order_id) AS order_id, b.order_item_id AS order_item_id,
           COALESCE(a.grn_item_id, b.grn_item_id) AS grn_item_id, COALESCE(a.item_name, b.item_name) AS item_name,
           COALESCE(a.package_mark, b.package_mark) AS package_mark, COALESCE(a.packaging, b.packaging) AS packaging, COALESCE(a.grn_no, b.grn_no) AS grn_no,
           COALESCE(b.qty, 0) AS old_qty, COALESCE(a.qty, 0) AS new_qty, NULL::integer AS available_stock
    FROM before_lines b FULL JOIN after_lines a ON a.order_id = b.order_id AND a.grn_item_id = b.grn_item_id
    WHERE COALESCE(b.qty, 0) <> COALESCE(a.qty, 0)
    UNION ALL
    -- A lot whose stock this save lowered below what an order line still asks for (a GRN edit only).
    SELECT a.order_id, a.order_item_id, a.grn_item_id, a.item_name, a.package_mark, a.packaging, a.grn_no, a.qty, a.qty, t.stock
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
      'packaging', COALESCE(ch.packaging, ''),
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

-- get_grn_prefixes_with_stock: the prefix is the whole run of non-digit characters at the start of the GRN number (DV0102 -> DV, X0001 -> X,
-- T-12 -> T-), not its first letter, so the keypad can offer the numbers of a two-letter series. The run is trimmed and upper-cased (G 14 -> G,
-- ' A77' -> A, dv01 and DV01 -> DV). A number that starts with a digit has no such run: its prefix is its first character (0001 -> 0,
-- 26-27/0001 -> 2, as before), so no GRN with stock is ever left without a button (the app shows the digit keys only when there is a button).
-- A prefix is always a real leading part of the number once trimmed, and the app's search is a case-insensitive "contains", so a button finds its GRNs.
-- Same arguments, same answer shape ({prefix, grn_count} per prefix), same access.
CREATE OR REPLACE FUNCTION public.get_grn_prefixes_with_stock(p_customer_id uuid DEFAULT NULL::uuid) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'extensions', 'utils', 'pg_temp'
    AS $$
DECLARE
    v_result jsonb;
BEGIN
  PERFORM warehouse_security.authorize_rpc('get_grn_prefixes_with_stock',jsonb_build_object('p_customer_id',p_customer_id));
    SELECT COALESCE(
        jsonb_agg(
            jsonb_build_object('prefix', prefix, 'grn_count', grn_count)
        ),
        '[]'::jsonb
    ) INTO v_result
    FROM (
        SELECT p.prefix, COUNT(DISTINCT p.id)::integer as grn_count
        FROM (
            SELECT gr.id,
                   COALESCE(NULLIF(upper(btrim(substring(gr.gr_no from '^[^0-9]*'))), ''), left(btrim(gr.gr_no), 1)) AS prefix
            FROM goodsreceived gr
            JOIN goodsreceived_trl gt ON gr.id = gt.gr_id
            WHERE gr.deleted_at IS NULL
              AND gt.stock > 0
              AND (p_customer_id IS NULL OR gr.customer_id = p_customer_id)
              AND btrim(COALESCE(gr.gr_no, '')) <> ''
        ) p
        GROUP BY p.prefix
        ORDER BY p.prefix
    ) sub;

    RETURN utils.success_response(v_result);
EXCEPTION
    WHEN OTHERS THEN
        RETURN utils.database_error_response('Failed to get GRN prefixes', SQLERRM, SQLSTATE);
END;
$$;

-- get_items_without_rate: which items of a GRN being entered have no default rate yet, so the Review step can tell staff (who cannot read
-- rates) before the save. It asks find_storage_price, the lookup of the "every line has a rate" check of apply_grn_rates (the customer's own
-- rate, else the item's, including the item's first rate for days before it began). No figure is returned. p_weights (optional) is the weight of
-- each line, in the order of p_item_ids (0 where missing, as the check does); p_pricing_mode is the GRN's mode ('ONE_TIME' or anything else = monthly).
-- p_on defaults to today's India business date (what the saves use). p_grn_id (optional, for a GRN being edited): that GRN's own GRN-only rates
-- count as a rate too, as in the check of apply_grn_rates.
-- Administrators, supervisors and staff; a customer is refused (authorize_rpc). At most 200 items (one dimension), and no more weights than items.
CREATE FUNCTION public.get_items_without_rate(p_customer_id uuid, p_item_ids uuid[], p_on date DEFAULT NULL,
                                              p_weights integer[] DEFAULT NULL, p_pricing_mode text DEFAULT 'monthly',
                                              p_grn_id uuid DEFAULT NULL) RETURNS jsonb
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'extensions', 'utils', 'pg_temp'
    AS $$
DECLARE
    v_type text := CASE WHEN upper(COALESCE(p_pricing_mode, '')) = 'ONE_TIME' THEN 'one_time' ELSE 'monthly' END;
    v_result jsonb;
BEGIN
  PERFORM warehouse_security.authorize_rpc('get_items_without_rate', jsonb_build_object('p_customer_id', p_customer_id));
  -- cardinality counts every element of a multi-dimensional array too; one dimension only, and no more weights than items.
  IF COALESCE(cardinality(p_item_ids), 0) > 200 OR COALESCE(array_ndims(p_item_ids), 1) > 1 OR COALESCE(array_ndims(p_weights), 1) > 1
     OR COALESCE(cardinality(p_weights), 0) > COALESCE(cardinality(p_item_ids), 0) THEN
    RETURN jsonb_build_object('success', false, 'message', 'At most 200 items at a time, and no more weights than items', 'data', null);
  END IF;
  SELECT COALESCE(jsonb_agg(jsonb_build_object('item_id', x.item_id, 'item_name', x.item_name) ORDER BY x.item_name, x.item_id), '[]'::jsonb)
    INTO v_result
    FROM (SELECT DISTINCT i.id AS item_id, i.name AS item_name
            FROM unnest(COALESCE(p_item_ids, ARRAY[]::uuid[])) WITH ORDINALITY AS u(item_id, n)
            JOIN public.items i ON i.id = u.item_id
           WHERE NOT EXISTS (SELECT 1 FROM public.grn_rates g WHERE g.gr_id = p_grn_id AND g.item_id = i.id AND g.price_type = v_type
                               AND COALESCE(p_weights[u.n::int], 0) BETWEEN g.weight_min AND g.weight_max)
             AND (public.find_storage_price(i.id, p_customer_id, COALESCE(p_weights[u.n::int], 0),
                                            COALESCE(p_on, warehouse_security.business_date(now())), v_type)).id IS NULL) x;
  RETURN utils.success_response(jsonb_build_object(
    'item_ids', COALESCE((SELECT jsonb_agg(e->'item_id') FROM jsonb_array_elements(v_result) e), '[]'::jsonb),
    'items', v_result));
EXCEPTION
    WHEN OTHERS THEN
        IF SQLSTATE = '42501' THEN RAISE; END IF;
        RETURN utils.database_error_response('Failed to check the rates', SQLERRM, SQLSTATE);
END;
$$;
ALTER FUNCTION public.get_items_without_rate(uuid, uuid[], date, integer[], text, uuid) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION public.get_items_without_rate(uuid, uuid[], date, integer[], text, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.get_items_without_rate(uuid, uuid[], date, integer[], text, uuid) TO authenticated, service_role;
-- authorize_rpc's staff entry for get_items_without_rate is in migrations/definitions/00_authorize_rpc.sql.

-- The packaging of each dispatch line ('Bag', 'Box', 'Crate', as the GRN item has it; '' when none) in the dispatch lists, so the app can say
-- "boxes" or "crates" where it said "bags": get_dispatch_list_with_items (with items) and get_recent_dispatched_orders add `packaging` to each
-- item object. Fields are only added; signatures, grants and the authorize_rpc calls stay. Marker-count patch: each marker must be found once.
DO $patch$
DECLARE
  v_def text;
  v_count integer;
BEGIN
  v_def := pg_get_functiondef('public.get_dispatch_list_with_items(uuid, jsonb, text, text, integer, integer, boolean)'::regprocedure);
  v_count := (length(v_def) - length(replace(v_def, $m$''grn_id'', gr.id, $m$, ''))) / length($m$''grn_id'', gr.id, $m$);
  IF v_count <> 1 THEN RAISE EXCEPTION 'get_dispatch_list_with_items: expected the item marker once, found % times', v_count; END IF;
  v_def := replace(v_def, $m$''grn_id'', gr.id, $m$, $m$''grn_id'', gr.id, ''packaging'', COALESCE(grt.packaging, ''''), $m$);
  EXECUTE v_def;

  v_def := pg_get_functiondef('public.get_recent_dispatched_orders(integer, integer)'::regprocedure);
  v_count := (length(v_def) - length(replace(v_def, $m$                    'grn_id', gr.id
$m$, ''))) / length($m$                    'grn_id', gr.id
$m$);
  IF v_count <> 1 THEN RAISE EXCEPTION 'get_recent_dispatched_orders: expected the item marker once, found % times', v_count; END IF;
  v_def := replace(v_def, $m$                    'grn_id', gr.id
$m$, $m$                    'grn_id', gr.id,
                    'packaging', COALESCE(grt.packaging, '')
$m$);
  EXECUTE v_def;
END
$patch$;
