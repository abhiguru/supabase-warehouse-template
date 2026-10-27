-- public.delete_grn_safe: the definition setup applies after the numbered migrations whenever this file's checksum changes
-- (scripts/migration-plan.mjs, table warehouse_migrations.definitions). Edit the function here, never in a new migration.
-- Starts as the function migrations 000 to 126 leave (the numbered files that patched it stay as they are, never edited).
CREATE OR REPLACE FUNCTION public.delete_grn_safe(p_grn_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'extensions', 'utils', 'pg_temp'
AS $function$
      DECLARE
          v_user_id uuid;
          v_user_role text;
          v_grn_record RECORD;
          v_dependency_check RECORD;
          v_items_deleted int := 0;
          v_movements_deleted int := 0;
          v_images_deleted int := 0;
          v_order_items_deleted int := 0;
          v_removed_order_lines jsonb;
BEGIN
  PERFORM warehouse_security.authorize_rpc('delete_grn_safe',jsonb_build_object('p_grn_id',p_grn_id));
    -- The list-refresh lock comes before any row lock (migration 46).
    PERFORM pg_advisory_xact_lock(71040);
          -- Authentication and authorization
          v_user_id := auth.uid();
          IF v_user_id IS NULL THEN
              RETURN jsonb_build_object(
                  'success', false,
                  'error', 'Authentication required'
              );
          END IF;

          -- Get user role
          SELECT role INTO v_user_role
          FROM user_profiles
          WHERE auth_user_id = v_user_id;

          -- Only admin and supervisor can delete GRNs
          IF v_user_role NOT IN ('admin', 'supervisor') THEN
              RETURN jsonb_build_object(
                  'success', false,
                  'error', 'Only administrators and supervisors can delete GRNs'
              );
          END IF;

          -- Check if GRN exists and get info
          SELECT gr.*, c.name as customer_name
          INTO v_grn_record
          FROM goodsreceived gr
          LEFT JOIN customers c ON c.id = gr.customer_id
          WHERE gr.id = p_grn_id;

          IF NOT FOUND THEN
              RETURN jsonb_build_object(
                  'success', false,
                  'error', 'GRN not found'
              );
          END IF;

          -- ❌ STRICT DEPENDENCY CHECKS - Block deletion if dispatches or invoices exist
          SELECT
              COUNT(DISTINCT dt.id) as dispatches,
              COUNT(DISTINCT it.id) as invoiced_dispatches,
              COUNT(DISTINCT sm.id) as stock_movements,
              COUNT(DISTINCT gi.id) as images,
              COUNT(DISTINCT oi.id) as order_items
          INTO v_dependency_check
          FROM goodsreceived gr
          LEFT JOIN goodsreceived_trl grt ON grt.gr_id = gr.id
          LEFT JOIN dispatch_trl dt ON dt.gr_id = gr.id
          LEFT JOIN invoice_trl it ON it.disp_trl_id = dt.id
          LEFT JOIN stock_movements sm ON sm.gr_trl_id = grt.id
          LEFT JOIN grn_images gi ON gi.grn_id = gr.id
          LEFT JOIN order_items oi ON (oi.grns_id = gr.id OR oi.grn_items_id = grt.id)
          WHERE gr.id = p_grn_id;

          -- ❌ Block if ANY invoices exist
          IF v_dependency_check.invoiced_dispatches > 0 THEN
              RETURN jsonb_build_object(
                  'success', false,
                  'error', format('Cannot delete GRN %s: %s dispatch items have been invoiced. Delete invoices first.',
                                v_grn_record.gr_no, v_dependency_check.invoiced_dispatches),
                  'blocking_dependencies', jsonb_build_object(
                      'invoiced_dispatches', v_dependency_check.invoiced_dispatches,
                      'total_dispatches', v_dependency_check.dispatches
                  ),
                  'grn_info', jsonb_build_object(
                      'gr_no', v_grn_record.gr_no,
                      'customer_name', COALESCE(v_grn_record.customer_name, 'Unknown'),
                      'date', v_grn_record.date
                  ),
                  'instructions', 'Delete all invoices and dispatches manually before deleting this GRN'
              );
          END IF;

          -- ❌ Block if ANY dispatches exist
          IF v_dependency_check.dispatches > 0 THEN
              RETURN jsonb_build_object(
                  'success', false,
                  'error', format('Cannot delete GRN %s: %s dispatch items exist. Delete dispatches first.',
                                v_grn_record.gr_no, v_dependency_check.dispatches),
                  'blocking_dependencies', jsonb_build_object(
                      'dispatches', v_dependency_check.dispatches
                  ),
                  'grn_info', jsonb_build_object(
                      'gr_no', v_grn_record.gr_no,
                      'customer_name', COALESCE(v_grn_record.customer_name, 'Unknown'),
                      'date', v_grn_record.date
                  ),
                  'instructions', 'Delete all dispatches manually before deleting this GRN'
              );
          END IF;

          -- ✅ SAFE DELETION PROCESS - Handle dependencies in correct order

          -- 1. Delete order_items that reference this GRN (FIXES YOUR FK CONSTRAINT ERROR)
          SELECT jsonb_object_agg(removed.order_id::text, removed.lines)
          INTO v_removed_order_lines
          FROM (
              SELECT oi.order_id, jsonb_agg(jsonb_build_object(
                         'item_id', oi.grn_items_item_id,
                         'item_name', oi.grn_items_item_name,
                         'quantity', 0,
                         'grn_no', oi.grns_gr_no,
                         'package_mark', oi.grn_items_package_mark
                     ) ORDER BY oi.sort_order, oi.created_at) AS lines
              FROM order_items oi
              WHERE oi.grns_id = p_grn_id
              OR oi.grn_items_id IN (
                  SELECT id FROM goodsreceived_trl WHERE gr_id = p_grn_id
              )
              GROUP BY oi.order_id
          ) AS removed;

          DELETE FROM order_items
          WHERE grns_id = p_grn_id
          OR grn_items_id IN (
              SELECT id FROM goodsreceived_trl WHERE gr_id = p_grn_id
          );
          GET DIAGNOSTICS v_order_items_deleted = ROW_COUNT;

          PERFORM warehouse_security.record_order_revision(
              removed.key::uuid,
              (SELECT id FROM user_profiles WHERE auth_user_id = v_user_id),
              'grn_deleted', '{}'::jsonb, removed.value)
          FROM jsonb_each(COALESCE(v_removed_order_lines, '{}'::jsonb)) AS removed;

          -- 2. Delete stock movements
          DELETE FROM stock_movements
          WHERE gr_trl_id IN (
              SELECT id FROM goodsreceived_trl WHERE gr_id = p_grn_id
          );
          GET DIAGNOSTICS v_movements_deleted = ROW_COUNT;

          -- 4. Delete GRN images (safe dependency)
          DELETE FROM grn_images
          WHERE grn_id = p_grn_id;
          GET DIAGNOSTICS v_images_deleted = ROW_COUNT;

          -- 5. Delete GRN items (goodsreceived_trl)
          DELETE FROM goodsreceived_trl
          WHERE gr_id = p_grn_id;
          GET DIAGNOSTICS v_items_deleted = ROW_COUNT;

          -- 6. Finally, delete the main GRN record
          DELETE FROM goodsreceived
          WHERE id = p_grn_id;

          -- 7. A saved create or edit answer that points at this GRN is not replayed any more: entering the
          -- same GRN again saves it (migration 120).
          DELETE FROM idempotency_keys
          WHERE (rpc_function = 'save_grn' AND response #>> '{data,grn_id}' = p_grn_id::text)
             OR (rpc_function = 'update_grn' AND response #>> '{grn,id}' = p_grn_id::text);

          RETURN jsonb_build_object(
              'success', true,
              'message', format('GRN %s deleted successfully', v_grn_record.gr_no),
              'grn_info', jsonb_build_object(
                  'gr_no', v_grn_record.gr_no,
                  'customer_name', COALESCE(v_grn_record.customer_name, 'Unknown'),
                  'date', v_grn_record.date
              ),
              'deleted_counts', jsonb_build_object(
                  'grn_items', v_items_deleted,
                  'order_items', v_order_items_deleted,
                  'stock_movements', v_movements_deleted,
                  'images', v_images_deleted,
                  'auto_invoice_errors', 0
              ),
              'deletion_type', 'safe_with_order_cleanup',
              'note', CASE
                  WHEN v_order_items_deleted > 0 THEN
                      format('Removed %s order items that referenced this GRN', v_order_items_deleted)
                  ELSE
                      'No order items were referencing this GRN'
              END
          );

      EXCEPTION
          WHEN insufficient_privilege THEN RAISE;
          WHEN OTHERS THEN
              RETURN jsonb_build_object(
                  'success', false,
                  'error', 'Deletion failed: ' || SQLERRM,
                  'grn_info', jsonb_build_object(
                      'gr_no', COALESCE(v_grn_record.gr_no, 'unknown'),
                      'customer_name', COALESCE(v_grn_record.customer_name, 'unknown')
                  )
              );
      END;
  $function$;

REVOKE ALL ON FUNCTION public.delete_grn_safe(uuid) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.delete_grn_safe(uuid) TO service_role, authenticated;
