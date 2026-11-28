-- Stable order reads (WH-328, offline work step 4): topic "stable order reads". Named by topic; its number is taken when the work is
-- assembled for main. Contract: product/tech/app-offline-orders-payments.md section 3, topic 4 (Product PQ5: an order names its latest
-- dispatch). A phone answering these reads from its copy must give the one answer the server gives for the same call, so every tie is broken:
--
--  1. get_order_with_items names the latest dispatch of the order: ORDER BY d.created_at DESC, d.id (it was LIMIT 1 with no order).
--  2. The lines of get_order_with_items and of get_orders_list end their order with oi.id (sort_order, created_at, id).
--  3. get_recent_dispatched_orders sorts d.created_at DESC, d.id, and lists the items of each dispatch in the order get_dispatch_details
--     lists its lines (uuid_extract_timestamp(dt.id), dt.id).
--
-- Written against the functions as migrations 133 and 148 left them. Patched by text with marker counts (the migration 130 pattern); no
-- signature, owner, grant, search_path or volatility changes.

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

SELECT pg_temp.patch_function('public.get_order_with_items(uuid)'::regprocedure, ARRAY[
$m$AND d.customer_id = (SELECT o.customer_id FROM orders o WHERE o.id = p_order_id)
    LIMIT 1;$m$,
$m$ORDER BY oi.sort_order, oi.created_at$m$
], ARRAY[
$m$AND d.customer_id = (SELECT o.customer_id FROM orders o WHERE o.id = p_order_id)
    ORDER BY d.created_at DESC, d.id
    LIMIT 1;$m$,
$m$ORDER BY oi.sort_order, oi.created_at, oi.id$m$
]);

SELECT pg_temp.patch_function('public.get_orders_list(uuid, text, boolean, uuid, integer, integer, text)'::regprocedure, ARRAY[
$m$ORDER BY oi.sort_order, oi.created_at), '[]'::jsonb) AS items$m$
], ARRAY[
$m$ORDER BY oi.sort_order, oi.created_at, oi.id), '[]'::jsonb) AS items$m$
]);

SELECT pg_temp.patch_function('public.get_recent_dispatched_orders(integer, integer)'::regprocedure, ARRAY[
$m$ORDER BY d.created_at DESC
        LIMIT p_limit OFFSET p_offset$m$,
$m$)), '[]'::jsonb)$m$
], ARRAY[
$m$ORDER BY d.created_at DESC, d.id
        LIMIT p_limit OFFSET p_offset$m$,
$m$) ORDER BY uuid_extract_timestamp(dt.id), dt.id), '[]'::jsonb)$m$
]);

DROP FUNCTION pg_temp.patch_function(regprocedure, text[], text[]);
