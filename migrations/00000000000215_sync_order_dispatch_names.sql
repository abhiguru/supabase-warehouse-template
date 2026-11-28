-- Sync feed, order dispatch names (WH-328, offline work step 4): topic "sync order dispatch names". Named by topic; its number is taken when
-- the work is assembled for main. Follows "sync orders"; one feed format 3 with the rest of the set, set by the last of them
-- ("sync GST details"). Contract: product/tech/app-offline-orders-payments.md section 3, topic 3.
--
--  1. The 'dispatch' feed row of a dispatch made from an order (source_order_id set) gains created_by_name, the name of the profile that
--     created it (what get_recent_dispatched_orders answers as created_by_name), for administrators, supervisors and staff. A dispatch
--     not made from an order has no such key; a customer account never receives it.
--  2. A user_profiles entry re-sends those dispatches (a renamed profile changes their created_by_name). The orders it last updated are
--     re-sent by "sync orders".
--
-- entity_rows takes one more piece of its select: v_extra, appended to to_jsonb(x), empty for every other entity.
-- Patched by text with marker counts; no role, table, column, grant, owner, search_path or volatility changes.

DROP FUNCTION IF EXISTS pg_temp.patch_function(regprocedure, text[], text[]);
CREATE FUNCTION pg_temp.patch_function(p_function regprocedure, p_old text[], p_new text[]) RETURNS void
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
    v_count := (length(v_def) - length(replace(v_def, p_old[i], ''))) / length(p_old[i]);
    IF v_count <> 1 THEN
      RAISE EXCEPTION '%: expected marker % once, found % times', p_function, i, v_count;
    END IF;
    v_def := replace(v_def, p_old[i], p_new[i]);
  END LOOP;
  EXECUTE v_def;
END $$;

SELECT pg_temp.patch_function('warehouse_sync.entity_rows(text, uuid, uuid[], text, text[], text, integer)'::regprocedure, ARRAY[
$m$v_limit text := COALESCE(p_limit::text, 'ALL');$m$,
$m$-- The one column of a lot that is not the table's: when it was last emptied (get_customer_stock_summary's time).$m$,
$m$'SELECT t.id::text, to_jsonb(x) FROM %s t CROSS JOIN LATERAL (SELECT %s) x WHERE (%s)%s%s ORDER BY t.id LIMIT %s',$m$,
$m$v_tbl, v_cols, v_where,$m$
], ARRAY[
$m$v_limit text := COALESCE(p_limit::text, 'ALL'); v_extra text := '';$m$,
$m$-- The one key a dispatch made from an order has beyond its columns: who created it (get_recent_dispatched_orders' created_by_name).
  IF p_entity = 'dispatch' AND NOT v_cust THEN
    v_extra := ' || CASE WHEN t.source_order_id IS NOT NULL THEN jsonb_build_object(''created_by_name'', '
            || '(SELECT u.name FROM public.user_profiles u WHERE u.id = t.created_by)) ELSE ''{}''::jsonb END';
  END IF;
  -- The one column of a lot that is not the table's: when it was last emptied (get_customer_stock_summary's time).$m$,
$m$'SELECT t.id::text, to_jsonb(x)%s FROM %s t CROSS JOIN LATERAL (SELECT %s) x WHERE (%s)%s%s ORDER BY t.id LIMIT %s',$m$,
$m$v_extra, v_tbl, v_cols, v_where,$m$
]);

SELECT pg_temp.patch_function('warehouse_sync.expand(text, warehouse_sync.change_log[])'::regprocedure, ARRAY[
$m$ELSE l.tbl END AS e, l.row_key AS id FROM l$m$
], ARRAY[
$m$ELSE l.tbl END AS e, l.row_key AS id FROM l
    UNION ALL SELECT l.xid, 'dispatch', d.id::text FROM l JOIN public.dispatch d ON d.created_by = l.row_key::uuid AND d.source_order_id IS NOT NULL
      WHERE l.tbl = 'user_profiles'$m$
]);

SELECT pg_temp.patch_function('warehouse_sync.affected(text)'::regprocedure, ARRAY[
$m$ARRAY['user_profiles', 'people', 'orders']$m$
], ARRAY[
$m$ARRAY['user_profiles', 'people', 'orders', 'dispatch']$m$
]);

DROP FUNCTION pg_temp.patch_function(regprocedure, text[], text[]);
