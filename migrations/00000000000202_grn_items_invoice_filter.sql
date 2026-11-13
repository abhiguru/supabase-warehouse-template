-- Migration 202 (WH-138): the GRN item list takes the invoiced filter, with the meaning get_grn_list has.
--
-- get_all_grn_items (the app's GRN list: one row per GRN line) had no invoiced filter (migration 165's header says so);
-- get_grn_list took one. p_filters.invoiced now narrows get_all_grn_items the same way:
--   'partly_invoiced'  -> the GRN's state is partly_invoiced
--   true / false       -> setting invoice_as_goods_leave on:  state invoiced / not_invoiced
--                         setting off: migration 160's rule, a live invoice exists / does not exist
--   any other value    -> the same expression as get_grn_list: (p_filters->>'invoiced')::boolean raises invalid_text_representation (22P02)
-- The filter is on the GRN: every line of a matching GRN is listed. It joins the WHERE conditions, so the rows, pagination.total_count
-- and the aggregates all follow it. No key means no change. Role scoping, owner, grants and search_path are untouched (CREATE OR REPLACE).
--
-- Marker-count patch as in migrations 160 and 165: the helper fails loudly unless each marker is found exactly once.

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
    IF position(p_old[i] IN p_new[i]) > 0 THEN
      RAISE EXCEPTION '%: the replacement of marker % contains the marker', p_function, i;
    END IF;
    v_count := (length(v_def) - length(replace(v_def, p_old[i], ''))) / length(p_old[i]);
    IF v_count <> 1 THEN
      RAISE EXCEPTION '%: expected marker % once, found % times', p_function, i, v_count;
    END IF;
    v_def := replace(v_def, p_old[i], p_new[i]);
  END LOOP;
  EXECUTE v_def;
END $$;

SELECT pg_temp.patch_function('public.get_all_grn_items(timestamp with time zone, timestamp with time zone, jsonb, text, text, integer, integer)'::regprocedure, ARRAY[
$m$    -- Weight filters
$m$
], ARRAY[
$m$    -- Invoiced filter (migration 202, WH-138): the same meaning as get_grn_list.
    IF p_filters ? 'invoiced' THEN
        v_where_conditions := array_append(v_where_conditions, CASE
            WHEN p_filters->>'invoiced' = 'partly_invoiced'
              THEN 'warehouse_security.grn_invoice_state(gr.id) = ''partly_invoiced'''
            WHEN warehouse_security.invoice_as_goods_leave()
              THEN format('warehouse_security.grn_invoice_state(gr.id) = %L',
                          CASE WHEN (p_filters->>'invoiced')::boolean THEN 'invoiced' ELSE 'not_invoiced' END)
            ELSE format('(EXISTS (SELECT 1 FROM invoice li WHERE li.gr_id = gr.id AND li.deleted_at IS NULL AND li.cancelled_at IS NULL)) = %L', (p_filters->>'invoiced')::boolean)
            END
        );
    END IF;

    -- Weight filters (min and max)
$m$
]);

DROP FUNCTION pg_temp.patch_function(regprocedure, text[], text[]);

NOTIFY pgrst, 'reload schema';
