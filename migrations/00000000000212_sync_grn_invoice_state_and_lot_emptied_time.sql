-- Sync feed format 2 (WH-299, offline work step 3): "sync GRN invoice state" and "sync lot emptied time", one change of the feed's
-- payload. Named by topic; its number is taken when the work is assembled for main. The contract is the "Sync" section of
-- docs/API_CONTRACT.md.
--
--  1. A grn_lock row of the feed gains invoice_state: warehouse_security.grn_invoice_state of the GRN (not_invoiced, invoiced or
--     partly_invoiced). get_grn_edit_state, built by the same function, answers as before.
--  2. A goodsreceived_trl row gains emptied_at: the latest stock movement that left the lot at zero (what
--     get_customer_stock_summary dates an emptied lot by), null when there is none. Every role that receives the lot receives it.
--     No new trigger: every writer of stock_movements (create_dispatch_with_stock_check_internal, update_dispatch_smart,
--     delete_dispatch_with_order_cleanup and the dispatch delete trigger restore_stock_on_dispatch_delete) changes the lot's stock
--     in the same transaction, which logs the lot; delete_grn_safe removes movements with their lots.
--  3. Every change of what grn_invoice_state reads logs the GRN's grn_lock. Invoices, invoice lines, dispatches, dispatch lines
--     and lots do already; added here: imported_billed_dispatches (trigger zz_change_feed, ENABLE ALWAYS). A change of an imported
--     invoice logs its own GRN, the only GRN whose dispatch lines import_history holds as billed by it.
--  4. A change of charging_rule.invoice_as_goods_leave changes the state of any number of GRNs without touching them: the log
--     takes one row (tbl 'reload', row_key 'grn_lock') and get_sync_changes answers reload ['grn_lock'] to the roles that hold it.
--  5. The payload format becomes 2: every phone's copy of format 1 answers reload_all FORMAT_CHANGED.
--
-- The functions of migration "sync change log" are patched by text with marker counts. No role, table, column, grant, owner,
-- search_path or volatility changes.

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
    IF position(p_old[i] IN p_new[i]) = 0 THEN
      RAISE EXCEPTION '%: the replacement of marker % does not keep the marker', p_function, i;
    END IF;
    v_count := (length(v_def) - length(replace(v_def, p_old[i], ''))) / length(p_old[i]);
    IF v_count <> 1 THEN
      RAISE EXCEPTION '%: expected marker % once, found % times', p_function, i, v_count;
    END IF;
    v_def := replace(v_def, p_old[i], p_new[i]);
  END LOOP;
  EXECUTE v_def;
END $$;

-- ===== 1. invoice_state on grn_lock =====
SELECT pg_temp.patch_function('warehouse_sync.grn_lock_build(uuid[])'::regprocedure, ARRAY[
$m$      'rated_item_ids', COALESCE(ra.j, '[]'::jsonb)$m$
], ARRAY[
$m$      'rated_item_ids', COALESCE(ra.j, '[]'::jsonb),
      'invoice_state', warehouse_security.grn_invoice_state(g.id)$m$
]);

SELECT pg_temp.patch_function('public.get_grn_edit_state(uuid)'::regprocedure, ARRAY[
$m$v_row - 'imported' - 'rated_item_ids'$m$
], ARRAY[
$m$v_row - 'imported' - 'rated_item_ids' - 'invoice_state'$m$
]);

-- ===== 2. emptied_at on goodsreceived_trl =====
SELECT pg_temp.patch_function('warehouse_sync.entity_rows(text, uuid, uuid[], text, text[], text, integer)'::regprocedure, ARRAY[
$m$  v_where := CASE
$m$
], ARRAY[
$m$  -- The one column of a lot that is not the table's: when it was last emptied (get_customer_stock_summary's time).
  IF p_entity = 'goodsreceived_trl' THEN
    v_cols := v_cols || ', (SELECT max(m.created_at) FROM public.stock_movements m'
                     || ' WHERE m.gr_trl_id = t.id AND m.balance_after = 0) AS emptied_at';
  END IF;
  v_where := CASE
$m$
]);

-- ===== 3. every change of a GRN's invoice state logs its grn_lock =====
SELECT pg_temp.patch_function('warehouse_sync.log_change()'::regprocedure, ARRAY[
-- The setting that changes the state of GRNs nobody writes.
$m$    PERFORM warehouse_sync.log_entry('settings', 'charging_rule', 'U', NULL, NULL, NULL, NULL);
$m$,
$m$  ELSE
    RAISE EXCEPTION 'warehouse_sync.log_change: table % is not a logged table', TG_TABLE_NAME;$m$
], ARRAY[
$m$    PERFORM warehouse_sync.log_entry('settings', 'charging_rule', 'U', NULL, NULL, NULL, NULL);
    IF (o->>'invoice_as_goods_leave') IS DISTINCT FROM (n->>'invoice_as_goods_leave') THEN
      PERFORM warehouse_sync.log_entry('reload', 'grn_lock', 'U', NULL, NULL, NULL, NULL);
    END IF;
$m$,
$m$  WHEN 'imported_billed_dispatches' THEN
    -- Lock facts only: the GRN of a dispatch line taken as billed, or no longer.
    FOR g IN SELECT DISTINCT dt.gr_id FROM public.dispatch_trl dt
        WHERE dt.id IN ((o->>'disp_trl_id')::uuid, (n->>'disp_trl_id')::uuid) AND dt.gr_id IS NOT NULL LOOP
      PERFORM warehouse_sync.log_entry('grn_lock', g::text, 'U', NULL, NULL, g, NULL);
    END LOOP;
  ELSE
    RAISE EXCEPTION 'warehouse_sync.log_change: table % is not a logged table', TG_TABLE_NAME;$m$
]);

CREATE TRIGGER zz_change_feed AFTER INSERT OR UPDATE OR DELETE ON public.imported_billed_dispatches
  FOR EACH ROW EXECUTE FUNCTION warehouse_sync.log_change();
ALTER TABLE public.imported_billed_dispatches ENABLE ALWAYS TRIGGER zz_change_feed;
CREATE TRIGGER zz_change_feed_truncate AFTER TRUNCATE ON public.imported_billed_dispatches
  FOR EACH STATEMENT EXECUTE FUNCTION warehouse_sync.log_truncate();
ALTER TABLE public.imported_billed_dispatches ENABLE ALWAYS TRIGGER zz_change_feed_truncate;

-- ===== 4. the setting switched: reload grn_lock =====
SELECT pg_temp.patch_function('warehouse_sync.affected(text)'::regprocedure, ARRAY[
$m$    WHEN 'money' THEN '{}'::text[]
$m$
], ARRAY[
$m$    WHEN 'money' THEN '{}'::text[]
    WHEN 'reload' THEN ARRAY['grn_lock']
$m$
]);

SELECT pg_temp.patch_function('public.get_sync_changes(text, text, integer)'::regprocedure, ARRAY[
$m$  RETURN jsonb_build_object('success', true, 'format', (SELECT s.format FROM warehouse_sync.state s), 'position', v_end::text,$m$
], ARRAY[
$m$  -- A reload the log orders itself (tbl 'reload'), for the positions this answer passes.
  IF 'grn_lock' = ANY (warehouse_sync.entities(c.role)) AND NOT 'grn_lock' = ANY (v_reload) AND EXISTS (
      SELECT 1 FROM warehouse_sync.change_log l
      WHERE l.tbl = 'reload' AND l.row_key = 'grn_lock' AND l.xid >= v_pos AND l.xid < v_end) THEN
    v_reload := v_reload || 'grn_lock'::text;
  END IF;

  RETURN jsonb_build_object('success', true, 'format', (SELECT s.format FROM warehouse_sync.state s), 'position', v_end::text,$m$
]);

DROP FUNCTION pg_temp.patch_function(regprocedure, text[], text[]);

-- ===== 5. format 2 =====
ALTER TABLE warehouse_sync.state ALTER COLUMN format SET DEFAULT 2;
UPDATE warehouse_sync.state SET format = 2;
