-- Order-item snapshots are deliberately non-null so later GRN edits cannot
-- erase the labels used to fulfil an order. Legacy and minimally entered GRNs
-- may leave optional package metadata null, so normalize those values at the
-- RPC boundary instead of rejecting an otherwise valid stock selection.
CREATE OR REPLACE FUNCTION public.add_item_to_order(
  p_order_id uuid,
  p_grn_item_id uuid,
  p_quantity integer
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, extensions, warehouse_security, pg_temp
AS $$
DECLARE
  v_user_id uuid;
  v_order record;
  v_item record;
  v_new_item_id uuid;
  v_cart_items jsonb;
  v_order_no text;
BEGIN
  PERFORM warehouse_security.authorize_rpc(
    'add_item_to_order',
    jsonb_build_object('p_order_id', p_order_id, 'p_grn_item_id', p_grn_item_id)
  );

  IF p_quantity IS NULL OR p_quantity <= 0 THEN
    RETURN jsonb_build_object('success', false, 'message', 'Quantity must be greater than zero');
  END IF;

  SELECT id INTO v_user_id
  FROM public.user_profiles
  WHERE auth_user_id = auth.uid() AND active;

  SELECT o.*, c.name AS current_customer_name
  INTO v_order
  FROM public.orders o
  JOIN public.customers c ON c.id = o.customer_id
  WHERE o.id = p_order_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'message', 'Order not found');
  END IF;
  IF v_order.status <> 'OPEN' THEN
    RETURN jsonb_build_object(
      'success', false,
      'message', 'Cannot add items to ' || v_order.status || ' orders',
      'error', jsonb_build_object('code', 'ORDER_NOT_OPEN')
    );
  END IF;

  SELECT
    gt.*,
    g.gr_no,
    g.date AS gr_date,
    g.customer_id,
    g.customer_name,
    g.gr_image_url
  INTO v_item
  FROM public.goodsreceived_trl gt
  JOIN public.goodsreceived g ON g.id = gt.gr_id
  WHERE gt.id = p_grn_item_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'message', 'GRN item not found');
  END IF;
  IF v_item.customer_id IS DISTINCT FROM v_order.customer_id THEN
    RAISE EXCEPTION 'Item belongs to another customer' USING ERRCODE = '42501';
  END IF;
  IF EXISTS (
    SELECT 1 FROM public.order_items
    WHERE order_id = p_order_id AND grn_items_id = p_grn_item_id
  ) THEN
    RETURN jsonb_build_object('success', false, 'message', 'Item already exists in order');
  END IF;
  IF v_item.stock < p_quantity THEN
    RETURN jsonb_build_object(
      'success', false,
      'message', format('Insufficient stock. Available: %s, Requested: %s', v_item.stock, p_quantity)
    );
  END IF;

  v_order_no := NULLIF(v_order.order_no, '');
  IF v_order_no IS NULL THEN
    v_order_no := 'ORD-' || to_char(current_date, 'YYYYMMDD') || '-' || substring(p_order_id::text FROM 1 FOR 8);
    UPDATE public.orders SET order_no = v_order_no WHERE id = p_order_id;
  END IF;

  INSERT INTO public.order_items (
    order_id, order_no, requested_quantity,
    grn_items_id, grn_items_item_id, grn_items_item_name,
    grn_items_package_mark, grn_items_packaging, grn_items_rack,
    grn_items_weight, grn_items_image_url,
    grns_id, grns_gr_no, grns_date, grns_customer_id, grns_customer_name,
    available_stock_at_order, current_stock, item_status, sort_order
  ) VALUES (
    p_order_id, v_order_no, p_quantity,
    p_grn_item_id, v_item.item_id, v_item.item_name,
    COALESCE(v_item.package_mark, ''), COALESCE(v_item.packaging, ''), COALESCE(v_item.rack, ''),
    COALESCE(v_item.weight, 0), v_item.trl_img_url,
    v_item.gr_id, v_item.gr_no, v_item.gr_date, v_item.customer_id,
    COALESCE(v_item.customer_name, v_order.current_customer_name, ''),
    v_item.stock, v_item.stock, 'pending',
    COALESCE((SELECT max(sort_order) + 1 FROM public.order_items WHERE order_id = p_order_id), 1)
  ) RETURNING id INTO v_new_item_id;

  SELECT jsonb_agg(
    jsonb_build_object(
      'item_id', grn_items_item_id,
      'item_name', grn_items_item_name,
      'quantity', requested_quantity,
      'grn_no', grns_gr_no,
      'package_mark', grn_items_package_mark
    ) ORDER BY sort_order
  )
  INTO v_cart_items
  FROM public.order_items
  WHERE order_id = p_order_id;

  UPDATE public.orders
  SET revisions = revisions || jsonb_build_array(
        jsonb_build_object(
          'at', now(),
          'by', v_user_id,
          'action', 'UPDATE',
          'cart_items', COALESCE(v_cart_items, '[]'::jsonb),
          'changes', jsonb_build_object(
            'note', note,
            'priority', priority,
            'requested_dispatch_date', requested_dispatch_date
          )
        )
      ),
      updated_at = now(),
      updated_by = v_user_id
  WHERE id = p_order_id;

  RETURN jsonb_build_object(
    'success', true,
    'message', 'Item added to order successfully',
    'data', jsonb_build_object(
      'order_item_id', v_new_item_id,
      'item_name', v_item.item_name,
      'quantity', p_quantity,
      'order_no', v_order_no
    )
  );
EXCEPTION
  WHEN insufficient_privilege THEN RAISE;
  WHEN OTHERS THEN
    RETURN jsonb_build_object('success', false, 'message', 'Error adding item: ' || SQLERRM);
END;
$$;

REVOKE ALL ON FUNCTION public.add_item_to_order(uuid, uuid, integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.add_item_to_order(uuid, uuid, integer) TO authenticated, service_role;
