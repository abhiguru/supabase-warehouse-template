-- Report lists: a sort the server applies, and totals over the whole list.
--
-- The app's report screens get a sort control. Most report lists arrive whole
-- and are sorted in the app. Two things have to be right here:
--
-- 1. get_item_wise_stock_list is the only report list that is paged, so the app
--    can neither sort it nor total it: sorted in the app, page 2 would not
--    continue page 1, and its "Stock" figure summed only the pages loaded so far.
--    * New optional parameters p_sort_by (item_name, total_stock, total_qty,
--      grn_count; default item_name) and p_sort_order (asc, desc; default asc),
--      compared without regard to case. Any other value, NULL included, is the
--      default of that parameter, never an error. The two values only select
--      branches of a fixed ORDER BY: no SQL text is built from them.
--    * Equal rows are ordered by item name and then item id, both ascending in
--      either direction, so the order is total and pages neither repeat nor
--      skip a row.
--    * data.summary { total_stock, total_qty, item_count } is computed over the
--      whole filtered list (same customer and search filter as the rows), on
--      every page. data.items and data.total_count are unchanged.
--    A function with a longer parameter list is a different function, so the
--    old one is dropped in the same step (as migration 36 did); otherwise the
--    API would see two candidates for a call with the four old parameters.
--    A call with only those four keeps working and keeps the old order.
--
-- 2. get_all_dispatch_activity (by_customer), get_all_grn_activity (by_customer)
--    and get_all_stock_summary (customers) ordered by a jsonb value read as
--    TEXT, so 9 came above 100 and 100 above 10. They now order by the number,
--    largest first, a missing or non-numeric value last (as text, a missing
--    value came first), and equal totals by customer name, then customer id.
--    Nothing else in these three functions changes.
--
-- Method: the current definitions are patched, not rewritten. pg_get_functiondef
-- keeps the authorize_rpc guard, SECURITY DEFINER, the search_path and the role
-- filters of each body; every replaced text must occur exactly as often as
-- stated, or the migration fails.

-- The definition with one marker replaced; fails unless the marker occurs
-- exactly `expected` times. Dropped at the end of this migration.
CREATE FUNCTION pg_temp.replace_marker(fn text, definition text, marker text, replacement text, expected integer) RETURNS text
LANGUAGE plpgsql AS $$
DECLARE occurrences integer := (length(definition) - length(replace(definition, marker, ''))) / length(marker);
BEGIN
  IF occurrences <> expected THEN
    RAISE EXCEPTION 'Expected % occurrence(s) of the marker in %, found %: %', expected, fn, occurrences, left(marker, 80);
  END IF;
  RETURN replace(definition, marker, replacement);
END $$;

-- ---------------------------------------------------------------------------
-- 1. Item-wise stock list: sort parameters and a summary of the whole list
-- ---------------------------------------------------------------------------
DO $migration$
DECLARE
  old_signature constant text := 'public.get_item_wise_stock_list(uuid,text,integer,integer)';
  new_signature constant text := 'public.get_item_wise_stock_list(uuid,text,integer,integer,text,text)';
  definition text := pg_get_functiondef(old_signature::regprocedure);
  step record;
BEGIN
  FOR step IN SELECT * FROM (VALUES
    -- The parameter list.
    (1, $b$p_offset integer DEFAULT 0)$b$,
        $a$p_offset integer DEFAULT 0, p_sort_by text DEFAULT 'item_name'::text, p_sort_order text DEFAULT 'asc'::text)$a$, 1),
    (2, $b$    v_is_admin BOOLEAN;
$b$,    $a$    v_is_admin BOOLEAN;
    v_total_stock BIGINT := 0;
    v_total_qty BIGINT := 0;
    v_sort_by TEXT;
    v_sort_sign INTEGER;
$a$, 1),
    -- After the guard, which stays the first statement.
    (3, $b$    -- Determine accessible customers
$b$,    $a$    -- Sort: a fixed list of keys and two directions; any other value is the
    -- default. The two variables only select branches of the ORDER BY below.
    v_sort_by := lower(COALESCE(p_sort_by, ''));
    IF v_sort_by NOT IN ('item_name', 'total_stock', 'total_qty', 'grn_count') THEN
        v_sort_by := 'item_name';
    END IF;
    v_sort_sign := CASE WHEN lower(COALESCE(p_sort_order, '')) = 'desc' THEN -1 ELSE 1 END;

    -- Determine accessible customers
$a$, 1),
    -- The two answers for "no customer to list" carry the same keys as a full one.
    (4, $b$'total_count', 0$b$,
        $a$'total_count', 0, 'summary', jsonb_build_object('total_stock', 0, 'total_qty', 0, 'item_count', 0)$a$, 2),
    -- The count becomes count and totals, over the same rows.
    (5, $b$    -- Get total count of unique items with stock
    SELECT COUNT(*) INTO v_total_count
    FROM (
        SELECT grt.item_id
$b$,    $a$    -- Count and totals of the whole filtered list, whatever page is asked for
    SELECT COUNT(*), COALESCE(SUM(unique_items.item_stock), 0), COALESCE(SUM(unique_items.item_qty), 0)
    INTO v_total_count, v_total_stock, v_total_qty
    FROM (
        SELECT grt.item_id, SUM(grt.stock) AS item_stock, SUM(grt.qty) AS item_qty
$a$, 1),
    -- The page: one position per item decides both the page and the order within it.
    (6, $b$jsonb_agg(item_row ORDER BY item_row->>'item_name')$b$,
        $a$jsonb_agg(item_row ORDER BY item_position)$a$, 1),
    (7, $b$        ) AS item_row
        FROM goodsreceived_trl grt
$b$,    $a$        ) AS item_row,
        ROW_NUMBER() OVER (ORDER BY
            CASE v_sort_by WHEN 'total_stock' THEN SUM(grt.stock)
                           WHEN 'total_qty' THEN SUM(grt.qty)
                           WHEN 'grn_count' THEN COUNT(DISTINCT grt.gr_id) END * v_sort_sign,
            CASE WHEN v_sort_by = 'item_name' AND v_sort_sign < 0 THEN MAX(grt.item_name) END DESC,
            MAX(grt.item_name),
            grt.item_id
        ) AS item_position
        FROM goodsreceived_trl grt
$a$, 1),
    (8, $b$        ORDER BY MAX(grt.item_name) ASC
$b$,    $a$        ORDER BY item_position
$a$, 1),
    (9, $b$            'items', v_results,
            'total_count', v_total_count
$b$,    $a$            'items', v_results,
            'total_count', v_total_count,
            'summary', jsonb_build_object(
                'total_stock', v_total_stock,
                'total_qty', v_total_qty,
                'item_count', v_total_count
            )
$a$, 1)
  ) AS steps(step_no, before_text, after_text, times) ORDER BY step_no
  LOOP
    definition := pg_temp.replace_marker(old_signature, definition, step.before_text, step.after_text, step.times);
  END LOOP;
  EXECUTE format('DROP FUNCTION %s', old_signature::regprocedure);
  EXECUTE definition;
  -- A new function starts with the default grants: give it the ones the old function had.
  EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC, anon', new_signature::regprocedure);
  EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO authenticated, service_role', new_signature::regprocedure);
  IF (SELECT count(*) FROM pg_proc WHERE pronamespace = 'public'::regnamespace AND proname = 'get_item_wise_stock_list') <> 1 THEN
    RAISE EXCEPTION 'get_item_wise_stock_list must exist exactly once';
  END IF;
END;
$migration$;

-- ---------------------------------------------------------------------------
-- 2. Three all-customers lists: order by the number, not by its text
-- ---------------------------------------------------------------------------
DO $migration$
DECLARE
  change record;
  after_text constant text := $a$jsonb_agg(customer_data ORDER BY CASE WHEN jsonb_typeof(customer_data->'%1$s') = 'number' THEN (customer_data->>'%1$s')::numeric END DESC NULLS LAST, customer_data->>'customer_name', customer_data->>'customer_id')$a$;
BEGIN
  FOR change IN SELECT * FROM (VALUES
    ('public.get_all_dispatch_activity(date,date)', 'total_qty'),
    ('public.get_all_grn_activity(date,date)', 'total_qty'),
    ('public.get_all_stock_summary()', 'total_stock')
  ) AS changes(signature, total_key)
  LOOP
    EXECUTE pg_temp.replace_marker(change.signature, pg_get_functiondef(change.signature::regprocedure),
      format($b$jsonb_agg(customer_data ORDER BY customer_data->>'%s' DESC)$b$, change.total_key),
      format(after_text, change.total_key), 1);
  END LOOP;
END;
$migration$;

DROP FUNCTION pg_temp.replace_marker(text, text, text, text, integer);
NOTIFY pgrst, 'reload schema';
