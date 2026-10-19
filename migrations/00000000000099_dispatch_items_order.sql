-- Migration 99: get_customer_dispatch_items chooses the rows of a page after sorting.
--
-- The function applied LIMIT p_limit OFFSET p_offset in a subquery with no ORDER BY. The requested sort
-- ran only inside jsonb_agg(... ORDER BY ...), so it ordered the rows of a page but did not decide which
-- rows made the page: a customer with more lines than the page size got an arbitrary page (the app's
-- recent-items quick-add asks for the newest 100 lines), and paging across calls could repeat or skip lines.
--
-- The subquery now orders by the same sort key and direction as the aggregate, followed by the dispatch
-- line id (dt.id, unique) as the tie-breaker, before LIMIT/OFFSET. The aggregate ends with the same
-- tie-breaker, so the order inside a page matches the global order. The sort keys are unchanged: grn_gr_no
-- (the default), grn_date, item_name, disp_no, disp_date, qty, disp_qty; an unknown sort key now pages in
-- dispatch line id order instead of an arbitrary one. Signature, SECURITY DEFINER, search_path, the
-- authorization guard, the filters, the counts, the aggregations and the grants stay as they are: only the
-- listed expressions of the current definition are replaced, and each marker must occur exactly once.

CREATE FUNCTION pg_temp.patch_rpc(fn regprocedure, marker text, replacement text, expected integer DEFAULT 1) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE definition text := pg_get_functiondef(fn); occurrences integer;
BEGIN
  occurrences := (length(definition)-length(replace(definition,marker,'')))/length(marker);
  IF occurrences <> expected THEN
    RAISE EXCEPTION 'Expected % occurrence(s) of the marker in %, found %: %', expected, fn, occurrences, left(marker,80);
  END IF;
  EXECUTE replace(definition,marker,replacement);
END $$;

DO $patch$
BEGIN
  -- The aggregate's order ends with the unique line id.
  PERFORM pg_temp.patch_rpc('public.get_customer_dispatch_items(uuid,timestamptz,timestamptz,jsonb,text,text,integer,integer)',
  $m$        CASE WHEN p_sort_by = 'disp_qty' AND v_order_direction = 'DESC' THEN disp_qty END DESC
    ), '[]'::jsonb)$m$,
  $r$        CASE WHEN p_sort_by = 'disp_qty' AND v_order_direction = 'DESC' THEN disp_qty END DESC,
        dispatch_line_id
    ), '[]'::jsonb)$r$);
  -- The subquery exposes the line id.
  PERFORM pg_temp.patch_rpc('public.get_customer_dispatch_items(uuid,timestamptz,timestamptz,jsonb,text,text,integer,integer)',
  $m$            dt.disp_qty as disp_qty
        FROM dispatch_trl dt$m$,
  $r$            dt.disp_qty as disp_qty,
            dt.id as dispatch_line_id
        FROM dispatch_trl dt$r$);
  -- The page is chosen after sorting, with the same key and direction and the same tie-breaker.
  PERFORM pg_temp.patch_rpc('public.get_customer_dispatch_items(uuid,timestamptz,timestamptz,jsonb,text,text,integer,integer)',
  $m$        LIMIT p_limit OFFSET p_offset
    ) sub;$m$,
  $r$        ORDER BY
            CASE WHEN p_sort_by = 'grn_gr_no' AND v_order_direction = 'ASC' THEN gr.gr_no END ASC,
            CASE WHEN p_sort_by = 'grn_gr_no' AND v_order_direction = 'DESC' THEN gr.gr_no END DESC,
            CASE WHEN p_sort_by = 'grn_date' AND v_order_direction = 'ASC' THEN gr.date END ASC,
            CASE WHEN p_sort_by = 'grn_date' AND v_order_direction = 'DESC' THEN gr.date END DESC,
            CASE WHEN p_sort_by = 'item_name' AND v_order_direction = 'ASC' THEN grt.item_name END ASC,
            CASE WHEN p_sort_by = 'item_name' AND v_order_direction = 'DESC' THEN grt.item_name END DESC,
            CASE WHEN p_sort_by = 'disp_no' AND v_order_direction = 'ASC' THEN d.disp_no END ASC,
            CASE WHEN p_sort_by = 'disp_no' AND v_order_direction = 'DESC' THEN d.disp_no END DESC,
            CASE WHEN p_sort_by = 'disp_date' AND v_order_direction = 'ASC' THEN d.disp_date END ASC,
            CASE WHEN p_sort_by = 'disp_date' AND v_order_direction = 'DESC' THEN d.disp_date END DESC,
            CASE WHEN p_sort_by = 'qty' AND v_order_direction = 'ASC' THEN grt.qty END ASC,
            CASE WHEN p_sort_by = 'qty' AND v_order_direction = 'DESC' THEN grt.qty END DESC,
            CASE WHEN p_sort_by = 'disp_qty' AND v_order_direction = 'ASC' THEN dt.disp_qty END ASC,
            CASE WHEN p_sort_by = 'disp_qty' AND v_order_direction = 'DESC' THEN dt.disp_qty END DESC,
            dt.id
        LIMIT p_limit OFFSET p_offset
    ) sub;$r$);
END $patch$;

DROP FUNCTION pg_temp.patch_rpc(regprocedure, text, text, integer);
