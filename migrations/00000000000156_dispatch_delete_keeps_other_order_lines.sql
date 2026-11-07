-- Migration 156 (WH-129): deleting a dispatch no longer resets every line of its source order.
--
-- trg_restore_stock_on_dispatch_delete (public.restore_stock_on_dispatch_delete, BEFORE DELETE ON public.dispatch) set EVERY line of the
-- dispatch's source order to fulfilled 0 / pending, so lines served by another dispatch of the same order showed as pending again. The
-- only delete path, delete_dispatch_with_order_cleanup, already gives back exactly what the dispatch took from each order line
-- (warehouse_security.restore_to_order, migrations 121 and 128), and it writes the order's dispatch_deleted change-log entry listing it.
-- Owner, 2026-11-07: the blanket reset was not intended. The trigger now only reopens the order (status OPEN, as before) and leaves the
-- lines alone, so a line keeps its fulfilled quantity and status unless restore_to_order lowered it. A direct dispatch (no source
-- order) is unchanged. The stock half of the trigger is unchanged.
--
-- Known gap, not decided here: a source-order dispatch line made before migration 67 has no record of what it took from the order
-- (source_type is not 'cart'); the delete function gives nothing back for it (it counts it in lines_not_restored), and the blanket reset
-- was the only thing that put such a line back. Such a line is now left as it is. Check a facility with:
--   SELECT count(*) FROM dispatch_trl dt JOIN dispatch d ON d.id = dt.disp_id
--    WHERE d.source_order_id IS NOT NULL AND dt.source_type IS DISTINCT FROM 'cart';
-- Patched in place (the text of the baseline as migration 130 left it): the marker must be found exactly once.
DO $patch$
DECLARE
  v_def text := pg_get_functiondef('public.restore_stock_on_dispatch_delete()'::regprocedure);
  v_old text := $m$
        -- Reset order items to pending
        UPDATE order_items
        SET
            fulfilled_quantity = 0,
            item_status = 'pending',
            updated_at = NOW()
        WHERE order_id = OLD.source_order_id;
$m$;
  v_new text := $m$
        -- Migration 156 (WH-129): the order's lines are not reset here. delete_dispatch_with_order_cleanup gives back, through
        -- warehouse_security.restore_to_order, exactly what this dispatch took from each line; lines served by other dispatches keep
        -- their fulfilled quantity and status.
$m$;
  v_count integer;
BEGIN
  v_count := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'restore_stock_on_dispatch_delete: expected the order-line reset once, found % times', v_count;
  END IF;
  EXECUTE replace(v_def, v_old, v_new);
END
$patch$;
