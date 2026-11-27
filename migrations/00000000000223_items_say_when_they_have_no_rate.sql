-- Sync feed, items say when they have no rate (WH-348, offline work step 6): topic "items say when they have no rate". Named by topic; its
-- number is taken when the work is assembled for main. Follows "sync lot item rate"; no format step (format 3 is set by "sync GST details"
-- and is not on main yet). Contract: product/tech/app-offline-read-more.md section 17 (17.2, 17.3).
--
--  1. An items feed row gains rate_cover {monthly, one_time} for administrators, supervisors and staff (customer accounts get none): per price
--     type, "none" when the item has no item_storage_prices row of that type for anyone (find_storage_price is NULL for every customer, weight and
--     day), {"up_to": N} when the item's default rows of that type give a rate for every weight 0..N on every day, else null (the server answers
--     null whenever it cannot prove one of the two). Built by warehouse_security.item_rate_cover.
--     {"up_to": N} is proved only when every default row of the type is open-ended (no end date) and the bands of the item's FIRST start day
--     (which find_storage_price's reach-back, migration 129, also applies to every earlier day) join from weight 0 to N without a gap; a later start
--     day can only add bands, and a customer row only wins where it matches, so find_storage_price is never NULL for those weights. Nothing
--     depends on today's date, so the passing of a day changes no answer.
--  2. Every item_storage_prices insert, update or delete logs that item's items row (the row is re-sent once per transaction), through
--     log_change(); affected() says an item_storage_prices change reaches items.
--
-- Patched by text with marker counts; no role, table, column, grant, owner, search_path or volatility changes of an existing function.

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

-- ===== 1. the helper =====
CREATE FUNCTION warehouse_security.item_rate_cover(p_item_id uuid) RETURNS jsonb
 LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE
  v_out jsonb := '{}'::jsonb; v_type text; v_state jsonb; v_first date; v_reach integer; v_row record;
BEGIN
  FOREACH v_type IN ARRAY ARRAY['monthly', 'one_time'] LOOP
    IF NOT EXISTS (SELECT 1 FROM public.item_storage_prices p WHERE p.item_id = p_item_id AND p.price_type = v_type) THEN
      v_state := to_jsonb('none'::text);
    ELSIF EXISTS (SELECT 1 FROM public.item_storage_prices p WHERE p.item_id = p_item_id AND p.price_type = v_type
                     AND p.customer_id IS NULL AND p.effective_to IS NOT NULL)
       OR NOT EXISTS (SELECT 1 FROM public.item_storage_prices p WHERE p.item_id = p_item_id AND p.price_type = v_type AND p.customer_id IS NULL) THEN
      v_state := 'null'::jsonb;
    ELSE
      SELECT min(p.effective_from) INTO v_first FROM public.item_storage_prices p
       WHERE p.item_id = p_item_id AND p.price_type = v_type AND p.customer_id IS NULL;
      v_reach := -1;
      FOR v_row IN SELECT p.weight_min, p.weight_max FROM public.item_storage_prices p
                    WHERE p.item_id = p_item_id AND p.price_type = v_type AND p.customer_id IS NULL AND p.effective_from = v_first
                    ORDER BY p.weight_min, p.weight_max LOOP
        EXIT WHEN v_row.weight_min > v_reach + 1;
        v_reach := GREATEST(v_reach, v_row.weight_max);
      END LOOP;
      v_state := CASE WHEN v_reach >= 0 THEN jsonb_build_object('up_to', v_reach) ELSE 'null'::jsonb END;
    END IF;
    v_out := v_out || jsonb_build_object(v_type, v_state);
  END LOOP;
  RETURN v_out;
END $$;
ALTER FUNCTION warehouse_security.item_rate_cover(uuid) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION warehouse_security.item_rate_cover(uuid) FROM PUBLIC, anon, authenticated, service_role;

-- ===== 2. the feed's functions =====
SELECT pg_temp.patch_function('warehouse_sync.entity_rows(text, uuid, uuid[], text, text[], text, integer)'::regprocedure, ARRAY[
$m$-- The one column of a lot that is not the table's: when it was last emptied (get_customer_stock_summary's time).$m$
], ARRAY[
$m$-- Which price types an item has no rate for (WH-348 section 17): the server's proof, never a rule a phone copies.
  IF p_entity = 'items' AND p_role IN ('admin', 'supervisor', 'staff') THEN
    v_cols := v_cols || ', warehouse_security.item_rate_cover(t.id) AS rate_cover';
  END IF;
  -- The one column of a lot that is not the table's: when it was last emptied (get_customer_stock_summary's time).$m$
]);

SELECT pg_temp.patch_function('warehouse_sync.affected(text)'::regprocedure, ARRAY[
$m$WHEN 'item_storage_prices' THEN ARRAY['item_storage_prices', 'goodsreceived_trl']$m$
], ARRAY[
$m$WHEN 'item_storage_prices' THEN ARRAY['item_storage_prices', 'goodsreceived_trl', 'items']$m$
]);

SELECT pg_temp.patch_function('warehouse_sync.log_change()'::regprocedure, ARRAY[
$m$-- Feed format 3: the lots whose item_rate this change can move (WH-348 section 16.2).$m$
], ARRAY[
$m$-- Feed format 3: a rate change re-sends its item's row (rate_cover).
  IF t = 'item_storage_prices' THEN
    FOREACH g IN ARRAY ARRAY(SELECT DISTINCT x FROM unnest(ARRAY[(o->>'item_id')::uuid, (n->>'item_id')::uuid]) x WHERE x IS NOT NULL) LOOP
      PERFORM warehouse_sync.log_entry('items', g::text, 'U', NULL, NULL, NULL, NULL);
    END LOOP;
  END IF;
  -- Feed format 3: the lots whose item_rate this change can move (WH-348 section 16.2).$m$
]);

DROP FUNCTION pg_temp.patch_function(regprocedure, text[], text[]);
