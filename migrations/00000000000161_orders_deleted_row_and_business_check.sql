-- Migration 161 (WH-113): two order fixes.
--
--  1. get_or_create_cart: a business has one order row for good (one_cart_per_customer). When that row is soft-deleted the function
--     inserted a second one and failed on the unique key. It now reuses the soft-deleted row: deleted_at and deleted_by are cleared and the
--     status is OPEN, and the row's id is returned. (Nothing in this release soft-deletes an order; only older rows can be in this state.)
--  2. add_item_to_order: called with p_order_id it did not check the business; called with p_customer_id it refuses a deleted business
--     ('Business is not active', BUSINESS_NOT_ACTIVE). The p_order_id path now refuses the same way. A deactivated (not deleted) business
--     still orders (DEC W16).
--  3. add_item_to_order with p_customer_id reuses a soft-deleted order row the same way (it answered 'Order not found').
--  4. In both, the reused row restarts empty: its old lines are removed and one order revision records them (clear_reused_order_lines).
-- Each patch counts its marker (it must occur exactly once), replaces it and re-creates the function; a second run fails on the count.

CREATE FUNCTION pg_temp.patch_function(p_function regprocedure, p_old text, p_new text) RETURNS void
    LANGUAGE plpgsql AS $$
DECLARE
  v_def text := pg_get_functiondef(p_function);
  v_count integer := (length(v_def) - length(replace(v_def, p_old, ''))) / length(p_old);
BEGIN
  IF v_count <> 1 THEN
    RAISE EXCEPTION '%: expected the marker once, found % times', p_function, v_count;
  END IF;
  EXECUTE replace(v_def, p_old, p_new);
END;
$$;

-- A reused soft-deleted order restarts empty (Product, WH-113): its old lines are removed and ONE order revision records the removal the way
-- remove_item_from_order does (action UPDATE, changes.removed_item per line, a quantity-0 entry per line in cart_items; the order history and
-- change log read order_revisions). An order with no lines writes nothing.
CREATE FUNCTION warehouse_security.clear_reused_order_lines(p_order_id uuid, p_user_id uuid) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public'
    AS $$
DECLARE
  v_removed jsonb;
  v_items jsonb;
BEGIN
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'item_id', oi.grn_items_item_id, 'item_name', oi.grn_items_item_name, 'grn_no', oi.grns_gr_no,
           'package_mark', oi.grn_items_package_mark, 'requested_quantity', oi.requested_quantity,
           'fulfilled_quantity', oi.fulfilled_quantity) ORDER BY oi.sort_order, oi.created_at), '[]'::jsonb),
         COALESCE(jsonb_agg(jsonb_build_object(
           'item_id', oi.grn_items_item_id, 'item_name', oi.grn_items_item_name, 'quantity', 0, 'grn_no', oi.grns_gr_no,
           'package_mark', oi.grn_items_package_mark) ORDER BY oi.sort_order, oi.created_at), '[]'::jsonb)
    INTO v_removed, v_items
    FROM public.order_items oi WHERE oi.order_id = p_order_id;
  IF jsonb_array_length(v_removed) = 0 THEN
    RETURN;
  END IF;
  DELETE FROM public.order_items WHERE order_id = p_order_id;
  PERFORM warehouse_security.record_order_revision(p_order_id, p_user_id, 'UPDATE',
    jsonb_build_object('removed_items', v_removed), v_items);
END $$;
ALTER FUNCTION warehouse_security.clear_reused_order_lines(uuid, uuid) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION warehouse_security.clear_reused_order_lines(uuid, uuid) FROM PUBLIC;

-- 1. get_or_create_cart reuses the soft-deleted row.
SELECT pg_temp.patch_function('public.get_or_create_cart(uuid)'::regprocedure,
$m$      IF FOUND THEN
          -- Cart exists - ensure it's OPEN (reset if DISPATCHED)$m$,
$m$      IF NOT FOUND THEN
          -- Migration 161: the customer's one order row may be soft-deleted; it is reused, not inserted again.
          UPDATE orders
          SET deleted_at = NULL,
              deleted_by = NULL,
              status = 'OPEN',
              updated_at = NOW(),
              updated_by = v_user_id
          WHERE customer_id = p_customer_id
            AND deleted_at IS NOT NULL
          RETURNING id INTO v_cart_id;
          IF v_cart_id IS NOT NULL THEN
              PERFORM warehouse_security.clear_reused_order_lines(v_cart_id, v_user_id);
          END IF;
      END IF;

      IF FOUND THEN
          -- Cart exists - ensure it's OPEN (reset if DISPATCHED)$m$);

-- 2. add_item_to_order refuses a deleted business on the p_order_id path too.
SELECT pg_temp.patch_function('public.add_item_to_order(uuid, uuid, integer, uuid)'::regprocedure,
$m$SELECT o.*, c.name AS current_customer_name
  INTO v_order$m$,
$m$SELECT o.*, c.deleted_at AS customer_deleted_at, c.name AS current_customer_name
  INTO v_order$m$);

SELECT pg_temp.patch_function('public.add_item_to_order(uuid, uuid, integer, uuid)'::regprocedure,
$m$  IF v_order.status <> 'OPEN' THEN$m$,
$m$  IF v_order.customer_deleted_at IS NOT NULL THEN
    RETURN jsonb_build_object('success', false, 'message', 'Business is not active', 'error', jsonb_build_object('code', 'BUSINESS_NOT_ACTIVE'));
  END IF;
  IF v_order.status IS DISTINCT FROM 'OPEN' THEN$m$);

-- 3. add_item_to_order (p_customer_id path) reuses the soft-deleted row instead of answering "Order not found".
SELECT pg_temp.patch_function('public.add_item_to_order(uuid, uuid, integer, uuid)'::regprocedure,
$m$      IF EXISTS (SELECT 1 FROM public.orders o WHERE o.customer_id = p_customer_id) THEN
        -- A soft-deleted order of this customer holds the one row; it is not reopened here.
        RETURN jsonb_build_object('success', false, 'message', 'Order not found');
      END IF;
$m$,
$m$      -- Migration 161: a soft-deleted order of this customer holds the one row; it is reused (as get_or_create_cart does), not refused.
      UPDATE public.orders o
      SET deleted_at = NULL, deleted_by = NULL, status = 'OPEN', updated_at = now(), updated_by = v_user_id
      WHERE o.customer_id = p_customer_id AND o.deleted_at IS NOT NULL
      RETURNING o.id INTO v_order_id;
      IF v_order_id IS NOT NULL THEN
        PERFORM warehouse_security.clear_reused_order_lines(v_order_id, v_user_id);
      END IF;
$m$);

DROP FUNCTION pg_temp.patch_function(regprocedure, text, text);
