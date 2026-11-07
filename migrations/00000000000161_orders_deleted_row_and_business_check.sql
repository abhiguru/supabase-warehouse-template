-- Migration 161 (WH-113): two order fixes.
--
--  1. get_or_create_cart: a business has one order row for good (one_cart_per_customer). When that row is soft-deleted the function
--     inserted a second one and failed on the unique key. It now reuses the soft-deleted row: deleted_at and deleted_by are cleared and the
--     status is OPEN, and the row's id is returned. (Nothing in this release soft-deletes an order; only older rows can be in this state.)
--  2. add_item_to_order: called with p_order_id it did not check the business; called with p_customer_id it refuses a deleted business
--     ('Business is not active', BUSINESS_NOT_ACTIVE). The p_order_id path now refuses the same way. A deactivated (not deleted) business
--     still orders (DEC W16).
--  3. add_item_to_order with p_customer_id reuses a soft-deleted order row the same way (it answered 'Order not found').
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
$m$);

DROP FUNCTION pg_temp.patch_function(regprocedure, text, text);
