-- Sync feed without the request bookkeeping columns (WH-373): topic "sync feed without request columns". Named by topic; its number is
-- taken when the work is assembled for main, after the four WH-161 topics ("number issued at save", "recorded time on offline records",
-- "permanent request ID on offline records", "refusal codes for offline sends") and after the sync topics that patch entity_rows.
--
-- The change feed's goodsreceived and dispatch rows no longer carry request_key, request_digest or request_item_mapping (WH-161's
-- bookkeeping, which only the server uses to answer a repeated send), for any role, a customer account included. recorded_at stays: a
-- screen may show the recorder's time. The columns stay readable to the app's own select('*') on goodsreceived (no revoke); only the
-- feed's row builder, warehouse_sync.entity_rows, leaves them out.
-- Patched by text with a marker count; no role, table, column, grant, owner, search_path or volatility changes.

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
$m$AND NOT (v_cust AND a.attname::text = ANY (warehouse_sync.customer_hidden_columns()))$m$
], ARRAY[
$m$AND NOT (v_cust AND a.attname::text = ANY (warehouse_sync.customer_hidden_columns()))
      AND NOT (p_entity IN ('goodsreceived', 'dispatch')
               AND a.attname::text IN ('request_key', 'request_digest', 'request_item_mapping'))$m$
]);

DROP FUNCTION pg_temp.patch_function(regprocedure, text[], text[]);
