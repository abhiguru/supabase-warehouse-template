-- Migration 207 (WH-198): the GRN list (get_grn_list) and the GRN item list (get_all_grn_items) filtered by invoice state work the state
-- out once per read, for every GRN with a live invoice in one set, instead of calling grn_invoice_state once per row of the whole
-- filtered set (once per GRN line in the item list). The rows, counts, totals and order are the same as before, setting on or off.
--
-- Before (migrations 165 and 202): p_filters.invoiced became `warehouse_security.grn_invoice_state(gr.id) = '<state>'` (setting on, or
-- 'partly_invoiced') or `(EXISTS (a live invoice)) = <true|false>` (setting off). Every row of the filtered set ran the function and its
-- subqueries, and the planner could not estimate it (it guessed 0.5 % of the rows); on a test set of 72,000 GRNs "not invoiced" took
-- about 1 second.
--
-- Now: warehouse_security.invoiced_grn_states() answers (gr_id, invoice_state) for every GRN with a live invoice: invoiced or
-- partly_invoiced, by grn_invoice_state's rule worked out with joins over the whole facility (a GRN not in it is not_invoiced). The
-- filter reads it as a semi or anti join:
--   'partly_invoiced'   -> the GRN is in the set as partly_invoiced (never, with the setting off)
--   true                -> the GRN is in the set as invoiced (setting off: every GRN with a live invoice, migration 160's rule)
--   false               -> the GRN is not in the set (no live invoice; the same with the setting on or off)
--   JSON null           -> setting on: not in the set (as before: the state not_invoiced); setting off: no GRN (as before: "= NULL")
--   any other value     -> (p_filters->>'invoiced')::boolean raises invalid_text_representation (22P02), as before
-- The invoice_state each row answers (one grn_invoice_state call per row shown on the page) is unchanged.
--
-- One rule, two forms: grn_invoice_state (one GRN; the triggers of the invoiced cache, the details and the page rows) and
-- invoiced_grn_states (every GRN, for the filters). A change to either, or to grn_has_free_dispatch_line, must be made in both: on every
-- GRN, COALESCE(invoiced_grn_states' state, 'not_invoiced') equals grn_invoice_state, with the setting on and off.
--
-- No index is added: the set is built with hash joins over invoice, goodsreceived_trl, dispatch_trl, dispatch, invoice_trl and
-- imported_billed_dispatches, which the existing indexes and sequential scans serve. No role, table, column or grant changes; owner,
-- grants, search_path and volatility of the two readers are unchanged (patched by text with the marker-count helper of migration 202).

-- Section 1: the state of every GRN with a live invoice. Not a reader by itself: the RPCs authorize first.
CREATE FUNCTION warehouse_security.invoiced_grn_states() RETURNS TABLE(gr_id uuid, invoice_state text)
    LANGUAGE sql STABLE
    SET search_path TO 'pg_catalog'
    -- The estimate of the joins below can pass the JIT threshold, and compiling takes longer than the query (as migration 193).
    SET jit TO 'off'
    AS $$
  WITH setting AS MATERIALIZED (
    SELECT warehouse_security.invoice_as_goods_leave() AS goods_leave
  ),
  live AS MATERIALIZED (
    -- grn_invoice_state's first test: a live invoice (not deleted, not cancelled, imported ones included). Every other GRN is not_invoiced.
    SELECT DISTINCT i.gr_id FROM public.invoice i
     WHERE i.gr_id IS NOT NULL AND i.deleted_at IS NULL AND i.cancelled_at IS NULL
  ),
  stocked AS MATERIALIZED (
    -- Setting on only: a lot of the GRN with stock (stock > 0).
    SELECT l.gr_id FROM live l
     WHERE (SELECT s.goods_leave FROM setting s)
       AND EXISTS (SELECT 1 FROM public.goodsreceived_trl t WHERE t.gr_id = l.gr_id AND t.stock > 0)
  ),
  free AS MATERIALIZED (
    -- Setting on only: grn_has_free_dispatch_line for every such GRN at once: a dispatch line (dispatch not deleted) on no live invoice
    -- and not taken as billed by a live imported invoice (migration 196).
    SELECT DISTINCT dt.gr_id FROM public.dispatch_trl dt
      JOIN public.dispatch d ON d.id = dt.disp_id AND d.deleted_at IS NULL
     WHERE (SELECT s.goods_leave FROM setting s)
       AND dt.gr_id IN (SELECT l.gr_id FROM live l)
       AND NOT EXISTS (SELECT 1 FROM public.invoice_trl it JOIN public.invoice iv ON iv.id = it.invoice_id
                        WHERE it.disp_trl_id = dt.id AND iv.deleted_at IS NULL AND iv.cancelled_at IS NULL)
       AND NOT EXISTS (SELECT 1 FROM public.imported_billed_dispatches b JOIN public.invoice bi ON bi.id = b.invoice_id
                        WHERE b.disp_trl_id = dt.id AND bi.deleted_at IS NULL AND bi.cancelled_at IS NULL)
  )
  -- Setting off: every GRN with a live invoice is invoiced (stocked and free are empty). Setting on: invoiced with no stock and no free
  -- dispatch line, else partly_invoiced.
  SELECT l.gr_id,
         CASE WHEN st.gr_id IS NULL AND f.gr_id IS NULL THEN 'invoiced' ELSE 'partly_invoiced' END
    FROM live l
    LEFT JOIN stocked st ON st.gr_id = l.gr_id
    LEFT JOIN free f ON f.gr_id = l.gr_id
$$;
ALTER FUNCTION warehouse_security.invoiced_grn_states() OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION warehouse_security.invoiced_grn_states() FROM PUBLIC;
COMMENT ON FUNCTION warehouse_security.invoiced_grn_states() IS
  'Migration 207 (WH-198): grn_invoice_state for every GRN with a live invoice at once (invoiced or partly_invoiced; a GRN not listed is not_invoiced). Keep the two in step.';
COMMENT ON FUNCTION warehouse_security.grn_invoice_state(uuid) IS
  'Migration 165: the invoice state of one GRN. warehouse_security.invoiced_grn_states (migration 207) is the same rule for every GRN at once; keep the two in step.';

-- Section 2: the filters.
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

SELECT pg_temp.patch_function('public.get_grn_list(date, date, text, text, integer, integer, jsonb)'::regprocedure, ARRAY[
$m$            WHEN p_filters->>'invoiced' = 'partly_invoiced'
              THEN 'warehouse_security.grn_invoice_state(gr.id) = ''partly_invoiced'''
            WHEN warehouse_security.invoice_as_goods_leave()
              THEN format('warehouse_security.grn_invoice_state(gr.id) = %L',
                          CASE WHEN (p_filters->>'invoiced')::boolean THEN 'invoiced' ELSE 'not_invoiced' END)
            ELSE format('(EXISTS (SELECT 1 FROM invoice li WHERE li.gr_id = gr.id AND li.deleted_at IS NULL AND li.cancelled_at IS NULL)) = %L', (p_filters->>'invoiced')::boolean)
            END$m$
], ARRAY[
$m$            -- Migration 207 (WH-198): the states come from one set (warehouse_security.invoiced_grn_states: every GRN with a live
            -- invoice, worked out once per read), not from grn_invoice_state once per row. The same GRNs as migrations 160, 165 and 202.
            WHEN p_filters->>'invoiced' = 'partly_invoiced'
              THEN 'EXISTS (SELECT 1 FROM warehouse_security.invoiced_grn_states() li WHERE li.gr_id = gr.id AND li.invoice_state = ''partly_invoiced'')'
            WHEN (p_filters->>'invoiced')::boolean
              THEN 'EXISTS (SELECT 1 FROM warehouse_security.invoiced_grn_states() li WHERE li.gr_id = gr.id AND li.invoice_state = ''invoiced'')'
            -- A JSON null: with the setting on it read as not_invoiced; with it off, "(a live invoice exists) = NULL" matched no GRN.
            WHEN (p_filters->>'invoiced')::boolean IS NULL AND NOT warehouse_security.invoice_as_goods_leave()
              THEN 'false'
            ELSE 'NOT EXISTS (SELECT 1 FROM warehouse_security.invoiced_grn_states() li WHERE li.gr_id = gr.id)'
            END$m$
]);

SELECT pg_temp.patch_function('public.get_all_grn_items(timestamp with time zone, timestamp with time zone, jsonb, text, text, integer, integer)'::regprocedure, ARRAY[
$m$            WHEN p_filters->>'invoiced' = 'partly_invoiced'
              THEN 'warehouse_security.grn_invoice_state(gr.id) = ''partly_invoiced'''
            WHEN warehouse_security.invoice_as_goods_leave()
              THEN format('warehouse_security.grn_invoice_state(gr.id) = %L',
                          CASE WHEN (p_filters->>'invoiced')::boolean THEN 'invoiced' ELSE 'not_invoiced' END)
            ELSE format('(EXISTS (SELECT 1 FROM invoice li WHERE li.gr_id = gr.id AND li.deleted_at IS NULL AND li.cancelled_at IS NULL)) = %L', (p_filters->>'invoiced')::boolean)
            END$m$
], ARRAY[
$m$            -- Migration 207 (WH-198): the states come from one set (warehouse_security.invoiced_grn_states: every GRN with a live
            -- invoice, worked out once per read), not from grn_invoice_state once per row. The same GRNs as migrations 160, 165 and 202.
            WHEN p_filters->>'invoiced' = 'partly_invoiced'
              THEN 'EXISTS (SELECT 1 FROM warehouse_security.invoiced_grn_states() li WHERE li.gr_id = gr.id AND li.invoice_state = ''partly_invoiced'')'
            WHEN (p_filters->>'invoiced')::boolean
              THEN 'EXISTS (SELECT 1 FROM warehouse_security.invoiced_grn_states() li WHERE li.gr_id = gr.id AND li.invoice_state = ''invoiced'')'
            -- A JSON null: with the setting on it read as not_invoiced; with it off, "(a live invoice exists) = NULL" matched no GRN.
            WHEN (p_filters->>'invoiced')::boolean IS NULL AND NOT warehouse_security.invoice_as_goods_leave()
              THEN 'false'
            ELSE 'NOT EXISTS (SELECT 1 FROM warehouse_security.invoiced_grn_states() li WHERE li.gr_id = gr.id)'
            END$m$
]);

DROP FUNCTION pg_temp.patch_function(regprocedure, text[], text[]);

NOTIFY pgrst, 'reload schema';
