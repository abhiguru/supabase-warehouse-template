-- GRN lists can page by receipt, and filter low stock.
--
-- get_all_grn_items (staff) and get_customer_grn_items (customer) page ITEM LINES, so one receipt
-- can be split across two pages and show partial stock. Both functions now accept an OPT-IN
-- p_filters key  page_by = 'receipt'.  In that mode p_limit and p_offset count receipts, every
-- filtered line of each receipt on the page is returned, pagination.total_count counts receipts, and
-- pagination.unit is 'receipt' ('line' otherwise). Without the key both functions behave as before,
-- so older app builds keep working; only pagination.unit is a new field.
--
-- Receipt mode accepts only the receipt-level sorts date, gr_no and customer_name (a NULL sort keeps
-- the default, date); a line-level sort answers success false, 'Invalid list parameters'. A receipt
-- page is not bounded in lines (accepted).
--
-- Staff list: the line numbering becomes DENSE_RANK() over (sort, gr_no, gr.id) in receipt mode (gr_no is
-- unique, so that fully orders receipts); the data array is now explicitly ordered by (row_num,
-- grn_item_id), which line mode returned only incidentally; stock_status 'low_stock' is new (it was
-- ignored): 0 < stock < 20% of the line's qty.
--
-- Customer list: the ORDER BY list is not repeated (tests/document_number_sort.sql counts the
-- document_number_sort_key calls). In receipt mode a receipt's lines are made contiguous by one more
-- ordering term (gr_no) before the id tiebreak, a receipts CTE numbers the receipts by their first line,
-- and the page selects on that number. stock_status 'low_stock' matches the same lines; other unknown
-- values still match nothing.
--
-- Only the listed expressions of the current definitions are replaced, so SECURITY DEFINER, search_path,
-- the authorization guards and the grants stay as they are. Each marker must occur exactly once.

CREATE FUNCTION pg_temp.replace_marker(fn text, definition text, marker text, replacement text, expected integer) RETURNS text
LANGUAGE plpgsql AS $$
DECLARE occurrences integer := (length(definition) - length(replace(definition, marker, ''))) / length(marker);
BEGIN
  IF occurrences <> expected THEN
    RAISE EXCEPTION 'Expected % occurrence(s) of the marker in %, found %: %', expected, fn, occurrences, left(marker, 80);
  END IF;
  RETURN replace(definition, marker, replacement);
END $$;

DO $migration$
DECLARE
  staff constant text := 'public.get_all_grn_items(timestamptz,timestamptz,jsonb,text,text,integer,integer)';
  customer constant text := 'public.get_customer_grn_items(uuid,timestamptz,timestamptz,jsonb,text,text,integer,integer)';
  fn text;
  definition text;
  change record;
BEGIN
  FOREACH fn IN ARRAY ARRAY[staff, customer] LOOP
    definition := pg_get_functiondef(fn::regprocedure);
    FOR change IN SELECT * FROM (VALUES
      -- Staff list.
      (staff, 1, $b$    v_sql text;$b$,
       $a$    v_sql text;
    v_receipt boolean := COALESCE(p_filters->>'page_by', '') = 'receipt';$a$),
      (staff, 2, $b$    -- Validate and set sort parameters$b$,
       $a$    -- Receipt paging accepts receipt-level sorts only
    IF v_receipt AND p_sort_by IS NOT NULL AND p_sort_by NOT IN ('date', 'gr_no', 'customer_name') THEN
        RETURN jsonb_build_object('success', false, 'message', 'Invalid list parameters', 'data', NULL);
    END IF;

    -- Validate and set sort parameters$a$),
      (staff, 3, $b$ROW_NUMBER() OVER (ORDER BY %s %s, gr.gr_no, grt.id) as row_num$b$,
       $a$%s OVER (ORDER BY %s %s, gr.gr_no, %s) as row_num$a$),
      (staff, 4, $b$COUNT(*) as total_count,$b$, $a$%s as total_count,$a$),
      (staff, 5, $b$                ) FROM paginated_items),$b$,
       $a$                ORDER BY row_num, grn_item_id
                ) FROM paginated_items),$a$),
      (staff, 6, $b$''offset'', %s$b$, $a$''offset'', %s,
                ''unit'', %L::text$a$),
      (staff, 7, $b$    v_sort_column,
    v_order_direction,
    array_to_string(v_where_conditions, ' AND '),
    p_offset + 1,
    p_offset + p_limit,
    p_limit,
    p_offset
    );$b$,
       $a$    CASE WHEN v_receipt THEN 'DENSE_RANK()' ELSE 'ROW_NUMBER()' END,
    v_sort_column,
    v_order_direction,
    CASE WHEN v_receipt THEN 'gr.id' ELSE 'grt.id' END,
    array_to_string(v_where_conditions, ' AND '),
    p_offset + 1,
    p_offset + p_limit,
    CASE WHEN v_receipt THEN 'COUNT(DISTINCT id)' ELSE 'COUNT(*)' END,
    p_limit,
    p_offset,
    CASE WHEN v_receipt THEN 'receipt' ELSE 'line' END
    );$a$),
      (staff, 8, $b$'grt.stock > 0');$b$,
       $a$'grt.stock > 0');
    ELSIF v_stock_status = 'low_stock' THEN
        v_where_conditions := array_append(v_where_conditions, 'grt.stock > 0 AND grt.stock < 0.2 * grt.qty');$a$),
      -- Customer list.
      (customer, 1, $b$  v_filters jsonb := COALESCE(p_filters, '{}'::jsonb);$b$,
       $a$  v_filters jsonb := COALESCE(p_filters, '{}'::jsonb);
  v_receipt boolean := COALESCE(v_filters->>'page_by', '') = 'receipt';$a$),
      (customer, 2, $b$     OR p_sort_by NOT IN ('date', 'gr_no', 'customer_name', 'item_name', 'qty', 'stock')$b$,
       $a$     OR p_sort_by NOT IN ('date', 'gr_no', 'customer_name', 'item_name', 'qty', 'stock')
     OR (v_receipt AND p_sort_by NOT IN ('date', 'gr_no', 'customer_name'))$a$),
      (customer, 3, $b$        id
      ) AS row_num$b$,
       $a$        CASE WHEN v_receipt THEN gr_no END,
        id
      ) AS row_num$a$),
      (customer, 4, $b$  ), page AS (
    SELECT * FROM ordered
    WHERE row_num > p_offset AND row_num <= p_offset + p_limit$b$,
       $a$  ), receipts AS (
    SELECT gr_id, row_number() OVER (ORDER BY min(row_num)) AS receipt_no
    FROM ordered
    GROUP BY gr_id
  ), page AS (
    SELECT ordered.* FROM ordered
    JOIN receipts ON receipts.gr_id = ordered.gr_id
    WHERE (CASE WHEN v_receipt THEN receipts.receipt_no ELSE ordered.row_num END) > p_offset
      AND (CASE WHEN v_receipt THEN receipts.receipt_no ELSE ordered.row_num END) <= p_offset + p_limit$a$),
      (customer, 5, $b$SELECT count(*)::integer AS total_count,$b$,
       $a$SELECT (CASE WHEN v_receipt THEN count(DISTINCT gr_id) ELSE count(*) END)::integer AS total_count,$a$),
      (customer, 6, $b$        'has_more', (p_offset + p_limit) < v_total_count$b$,
       $a$        'has_more', (p_offset + p_limit) < v_total_count,
        'unit', CASE WHEN v_receipt THEN 'receipt' ELSE 'line' END$a$),
      (customer, 7, $b$OR (v_filters->>'stock_status' = 'out_of_stock' AND grt.stock = 0)$b$,
       $a$OR (v_filters->>'stock_status' = 'out_of_stock' AND grt.stock = 0)
        OR (v_filters->>'stock_status' = 'low_stock' AND grt.stock > 0 AND grt.stock < 0.2 * grt.qty)$a$)
    ) AS changes(signature, n, before_text, after_text) WHERE signature = fn ORDER BY n
    LOOP
      definition := pg_temp.replace_marker(fn, definition, change.before_text, change.after_text, 1);
    END LOOP;
    EXECUTE definition;
  END LOOP;
END;
$migration$;

DROP FUNCTION pg_temp.replace_marker(text, text, text, text, integer);
NOTIFY pgrst, 'reload schema';
