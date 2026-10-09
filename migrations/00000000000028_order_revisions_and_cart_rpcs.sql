-- Orders screen corrections (review, 2026-10-09).
-- 1. Cart history moves from the ever-growing orders.revisions array to an
--    append-only order_revisions table. Every cart edit used to append a full
--    cart snapshot to the orders row, which the row audit trigger and the
--    REPLICA IDENTITY FULL realtime publication then copied in full, so storage
--    and realtime payloads grew quadratically. The column is kept for
--    compatibility but pinned to '[]' so a missed writer fails loudly.
-- 2. Staff get full order access (user decision, 2026-10-09): list, open and
--    edit carts, read their history, and use the queue.
-- 3. Customers may read the history of their own orders.
-- 4. Quantity changes check order state and stock; removals go through a
--    recorded RPC instead of a direct table delete; a lot can appear in a cart
--    only once. The previous ownership checks used `<> ANY(...)`, which denied
--    every account assigned to more than one customer.
-- 5. convert_order_to_dispatch and update_order_after_dispatch_creation are
--    dropped: both wrote columns that do not exist on orders, and the first
--    was on the public API allowlist. Orders become dispatches through
--    create_dispatch_with_stock_check with a source_order_id.

-- ---------------------------------------------------------------------------
-- Append-only history table
-- ---------------------------------------------------------------------------
CREATE TABLE public.order_revisions (
  id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  order_id    uuid NOT NULL REFERENCES public.orders(id) ON DELETE CASCADE,
  changed_at  timestamptz NOT NULL,
  changed_by  uuid REFERENCES public.user_profiles(id) ON DELETE SET NULL,
  action      text NOT NULL,
  entry       jsonb NOT NULL CHECK (jsonb_typeof(entry) = 'object'),
  created_at  timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE public.order_revisions IS
  'One row per cart change. entry keeps the legacy orders.revisions element shape read by get_order_change_log.';
CREATE INDEX order_revisions_order_changed_at_idx ON public.order_revisions (order_id, changed_at);
ALTER TABLE public.order_revisions ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.order_revisions FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.order_revisions TO authenticated;
GRANT ALL ON public.order_revisions TO service_role;
CREATE POLICY starter_staff ON public.order_revisions FOR SELECT TO authenticated
  USING (warehouse_security.active_role() IN ('admin','supervisor','staff'));
CREATE POLICY starter_customer_read ON public.order_revisions FOR SELECT TO authenticated
  USING (EXISTS (SELECT 1 FROM public.orders o
                 WHERE o.id = order_id AND warehouse_security.owns_customer(o.customer_id)));

-- One helper records every cart change with the snapshot shape the change log reads.
-- clock_timestamp() keeps several edits in one transaction in order.
CREATE FUNCTION warehouse_security.record_order_revision(
  p_order_id uuid,
  p_user_id uuid,
  p_action text DEFAULT 'UPDATE',
  p_extra_changes jsonb DEFAULT '{}'::jsonb,
  p_extra_items jsonb DEFAULT '[]'::jsonb
) RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE v_order record; v_cart_items jsonb; v_at timestamptz := clock_timestamp(); v_id bigint;
BEGIN
  SELECT note, priority, requested_dispatch_date INTO v_order FROM public.orders WHERE id = p_order_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Order % not found', p_order_id; END IF;
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'item_id', grn_items_item_id,
      'item_name', grn_items_item_name,
      'quantity', requested_quantity,
      'grn_no', grns_gr_no,
      'package_mark', grn_items_package_mark
    ) ORDER BY sort_order, created_at), '[]'::jsonb)
  INTO v_cart_items FROM public.order_items WHERE order_id = p_order_id;
  INSERT INTO public.order_revisions (order_id, changed_at, changed_by, action, entry)
  VALUES (p_order_id, v_at, p_user_id, p_action, jsonb_build_object(
    'at', v_at,
    'by', p_user_id,
    'action', p_action,
    'cart_items', v_cart_items || COALESCE(p_extra_items, '[]'::jsonb),
    'changes', jsonb_build_object(
        'note', v_order.note,
        'priority', v_order.priority,
        'requested_dispatch_date', v_order.requested_dispatch_date
      ) || COALESCE(p_extra_changes, '{}'::jsonb)))
  RETURNING id INTO v_id;
  RETURN v_id;
END $$;
REVOKE ALL ON FUNCTION warehouse_security.record_order_revision(uuid,uuid,text,jsonb,jsonb)
  FROM PUBLIC, anon, authenticated, service_role;

-- ---------------------------------------------------------------------------
-- Backfill, then pin the legacy column
-- ---------------------------------------------------------------------------
INSERT INTO public.order_revisions (order_id, changed_at, changed_by, action, entry)
SELECT o.id,
  COALESCE(
    CASE WHEN e.value->>'at' ~ '^\d{4}-\d{2}-\d{2}' THEN (e.value->>'at')::timestamptz END,
    CASE WHEN e.value->>'timestamp' ~ '^\d{4}-\d{2}-\d{2}' THEN (e.value->>'timestamp')::timestamptz END,
    o.updated_at),
  CASE WHEN e.value->>'by' ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
        AND EXISTS (SELECT 1 FROM public.user_profiles p WHERE p.id = (e.value->>'by')::uuid)
       THEN (e.value->>'by')::uuid END,
  COALESCE(NULLIF(e.value->>'action', ''), 'unknown'),
  e.value
FROM public.orders o
CROSS JOIN LATERAL jsonb_array_elements(
  CASE WHEN jsonb_typeof(o.revisions) = 'array' THEN o.revisions ELSE '[]'::jsonb END
) WITH ORDINALITY AS e(value, ord)
WHERE jsonb_typeof(e.value) = 'object'
ORDER BY o.id, e.ord;

-- Emptying the column is housekeeping: it must not write one more full-history
-- audit row per order or reorder the orders list by touching updated_at.
ALTER TABLE public.orders DISABLE TRIGGER audit_orders;
ALTER TABLE public.orders DISABLE TRIGGER update_orders_updated_at;
UPDATE public.orders SET revisions = '[]'::jsonb WHERE revisions IS DISTINCT FROM '[]'::jsonb;
ALTER TABLE public.orders ENABLE TRIGGER update_orders_updated_at;
ALTER TABLE public.orders ENABLE TRIGGER audit_orders;
ALTER TABLE public.orders
  ALTER COLUMN revisions SET DEFAULT '[]'::jsonb,
  ALTER COLUMN revisions SET NOT NULL,
  ADD CONSTRAINT orders_revisions_moved CHECK (revisions = '[]'::jsonb);

-- ---------------------------------------------------------------------------
-- RPC guard v5: migration 23 body plus order access for staff and history
-- access for customers.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION warehouse_security.authorize_rpc(rpc text, args jsonb) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE role_name text := warehouse_security.active_role(); customer uuid; other_customer uuid; document uuid;
BEGIN
  IF auth.jwt()->>'role' = 'service_role' THEN RETURN; END IF;
  IF role_name IS NULL THEN RAISE EXCEPTION 'Active account required' USING ERRCODE = '42501'; END IF;
  IF rpc IN ('update_user_role','update_user_status','assign_customer_to_user','remove_customer_assignment') THEN
    IF role_name <> 'admin' THEN RAISE EXCEPTION 'Administrator required' USING ERRCODE = '42501'; END IF;
    RETURN;
  END IF;
  IF role_name IN ('admin','supervisor') THEN RETURN; END IF;
  -- Approved document RPCs only; no shared ownership or table-policy change.
  IF role_name = 'staff' AND rpc IN (
    'save_grn','update_grn','check_grn_exists','get_next_grn_number',
    'get_all_grn_items','get_grn_list','get_grn_details','get_grn_item_dispatches',
    'get_grn_autocomplete','get_grn_prefixes_with_stock','get_all_grn_activity',
    'get_customer_grn_activity','get_customer_grn_items',
    'get_customer_grns_with_stock_dispatch_sorted',
    'search_customers','get_supervisors','get_vehicle_suggestions',
    'register_grn_image_upload','confirm_grn_image_upload',
    'cancel_grn_image_upload','upload_grn_image',
    'register_dispatch_image_upload','confirm_dispatch_image_upload',
    'cancel_dispatch_image_upload',
    'create_dispatch_with_stock_check','update_dispatch_smart',
    'check_dispatch_exists','get_next_dispatch_number','get_dispatch_autocomplete',
    'get_dispatch_details','get_dispatch_list','get_dispatch_list_with_items',
    'get_all_dispatch_items','get_all_dispatch_activity','get_customer_dispatch_list',
    'get_customer_dispatch_items','get_recent_dispatched_orders',
    'save_invoice','update_invoice','get_next_invoice_number',
    'get_invoiceable_grns','get_invoices_list','get_invoice_data','get_invoice_detail',
    'get_invoice_items_detailed','get_customer_invoice_summary',
    'generate_invoice_data_for_grn_with_pricing',
    -- Orders and queue (user decision, 2026-10-09).
    'get_orders_list','get_order_with_items','get_or_create_cart',
    'add_item_to_order','update_order_item_quantity','remove_item_from_order',
    'get_cart_dispatches','search_customer_items_for_order',
    'get_customer_items_for_order_selection','get_order_change_log'
  ) THEN RETURN; END IF;

  IF rpc IN ('get_items','get_item','search_items_autocomplete','get_orders_list','delete_user_account') THEN RETURN; END IF;
  IF rpc LIKE 'get_customer_%' OR rpc IN ('search_customer_items_for_order','get_or_create_cart') THEN
    customer := COALESCE(args->>'p_customer_id', args->>'p_customer_uuid')::uuid;
  ELSIF rpc IN ('get_grn_details','get_grn_item_dispatches') THEN
    IF args ? 'p_grn_item_id' THEN
      SELECT g.customer_id INTO customer FROM public.goodsreceived_trl t JOIN public.goodsreceived g ON g.id=t.gr_id WHERE t.id=(args->>'p_grn_item_id')::uuid;
    ELSE SELECT customer_id INTO customer FROM public.goodsreceived WHERE id=(args->>'p_grn_id')::uuid; END IF;
  ELSIF rpc = 'get_dispatch_details' THEN
    SELECT customer_id INTO customer FROM public.dispatch WHERE id=(args->>'p_dispatch_id')::uuid;
  ELSIF rpc IN ('get_invoice_data','get_invoice_detail','get_invoice_items_detailed') THEN
    SELECT customer_id INTO customer FROM public.invoice WHERE id=(args->>'p_invoice_id')::uuid;
  ELSIF rpc IN ('get_order_with_items','get_cart_dispatches','add_item_to_order',
                'update_order_item_quantity','remove_item_from_order','get_order_change_log') THEN
    document := COALESCE(args->>'p_order_id', args->>'p_cart_id')::uuid;
    IF rpc IN ('update_order_item_quantity','remove_item_from_order') THEN
      SELECT order_id INTO document FROM public.order_items WHERE id=(args->>'p_order_item_id')::uuid;
    END IF;
    SELECT customer_id INTO customer FROM public.orders WHERE id=document;
    -- History may be requested for one customer instead of one order.
    IF rpc = 'get_order_change_log' AND document IS NULL THEN
      customer := (args->>'p_customer_id')::uuid;
    END IF;
    IF rpc = 'add_item_to_order' THEN
      SELECT g.customer_id INTO other_customer FROM public.goodsreceived_trl t JOIN public.goodsreceived g ON g.id=t.gr_id WHERE t.id=(args->>'p_grn_item_id')::uuid;
      IF other_customer IS DISTINCT FROM customer THEN RAISE EXCEPTION 'Item belongs to another customer' USING ERRCODE = '42501'; END IF;
    END IF;
  ELSE
    RAISE EXCEPTION 'Staff access required' USING ERRCODE = '42501';
  END IF;
  IF customer IS NULL OR NOT warehouse_security.owns_customer(customer) THEN
    RAISE EXCEPTION 'Customer access denied' USING ERRCODE = '42501';
  END IF;
END $$;

-- ---------------------------------------------------------------------------
-- A lot appears in a cart once. Merge any duplicates first, keeping the
-- earliest line with the largest requested quantity. dispatch_trl references
-- order_items ON DELETE SET NULL, so removed duplicates do not break history.
-- ---------------------------------------------------------------------------
WITH ranked AS (
  SELECT id,
         row_number() OVER (PARTITION BY order_id, grn_items_id ORDER BY created_at, id) AS rn,
         max(requested_quantity) OVER (PARTITION BY order_id, grn_items_id) AS max_qty
  FROM public.order_items
)
UPDATE public.order_items oi SET requested_quantity = r.max_qty
FROM ranked r WHERE oi.id = r.id AND r.rn = 1 AND oi.requested_quantity <> r.max_qty;
WITH ranked AS (
  SELECT id, row_number() OVER (PARTITION BY order_id, grn_items_id ORDER BY created_at, id) AS rn
  FROM public.order_items
)
DELETE FROM public.order_items oi USING ranked r WHERE oi.id = r.id AND r.rn > 1;
ALTER TABLE public.order_items
  ADD CONSTRAINT order_items_order_grn_item_key UNIQUE (order_id, grn_items_id);

-- ---------------------------------------------------------------------------
-- Cart writers
-- ---------------------------------------------------------------------------
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
  WHERE o.id = p_order_id AND o.deleted_at IS NULL;

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

  PERFORM warehouse_security.record_order_revision(p_order_id, v_user_id);
  UPDATE public.orders SET updated_at = now(), updated_by = v_user_id WHERE id = p_order_id;

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
  -- A concurrent add of the same lot loses the race on the unique constraint.
  WHEN unique_violation THEN
    RETURN jsonb_build_object('success', false, 'message', 'Item already exists in order');
  WHEN OTHERS THEN
    RETURN jsonb_build_object('success', false, 'message', 'Error adding item: ' || SQLERRM);
END;
$$;
REVOKE ALL ON FUNCTION public.add_item_to_order(uuid, uuid, integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.add_item_to_order(uuid, uuid, integer) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.update_order_item_quantity(p_order_item_id uuid, p_new_quantity integer)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, extensions, warehouse_security, pg_temp
AS $$
DECLARE
  v_user_id uuid;
  v_item record;
  v_stock integer;
BEGIN
  PERFORM warehouse_security.authorize_rpc(
    'update_order_item_quantity',
    jsonb_build_object('p_order_item_id', p_order_item_id)
  );

  IF p_new_quantity IS NULL OR p_new_quantity <= 0 THEN
    RETURN jsonb_build_object('success', false, 'message', 'Quantity must be greater than zero');
  END IF;

  SELECT id INTO v_user_id
  FROM public.user_profiles
  WHERE auth_user_id = auth.uid() AND active;

  SELECT oi.id, oi.order_id, oi.requested_quantity, oi.fulfilled_quantity,
         oi.grn_items_id, oi.grn_items_item_name, o.status, o.deleted_at
  INTO v_item
  FROM public.order_items oi
  JOIN public.orders o ON o.id = oi.order_id
  WHERE oi.id = p_order_item_id
  FOR UPDATE OF oi;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'message', 'Order item not found');
  END IF;
  IF v_item.status <> 'OPEN' OR v_item.deleted_at IS NOT NULL THEN
    RETURN jsonb_build_object(
      'success', false,
      'message', 'Cannot change items on ' || COALESCE(v_item.status, 'closed') || ' orders',
      'error', jsonb_build_object('code', 'ORDER_NOT_OPEN')
    );
  END IF;
  IF p_new_quantity < v_item.fulfilled_quantity THEN
    RETURN jsonb_build_object(
      'success', false,
      'message', format('Quantity cannot be below the %s already dispatched', v_item.fulfilled_quantity)
    );
  END IF;

  SELECT stock INTO v_stock FROM public.goodsreceived_trl WHERE id = v_item.grn_items_id;
  IF COALESCE(v_stock, 0) < p_new_quantity THEN
    RETURN jsonb_build_object(
      'success', false,
      'message', format('Insufficient stock. Available: %s, Requested: %s', COALESCE(v_stock, 0), p_new_quantity)
    );
  END IF;

  UPDATE public.order_items
  SET requested_quantity = p_new_quantity,
      current_stock = v_stock,
      updated_at = now()
  WHERE id = p_order_item_id;

  PERFORM warehouse_security.record_order_revision(v_item.order_id, v_user_id);
  UPDATE public.orders SET updated_at = now(), updated_by = v_user_id WHERE id = v_item.order_id;

  RETURN jsonb_build_object(
    'success', true,
    'message', 'Quantity updated successfully',
    'data', jsonb_build_object(
      'order_item_id', p_order_item_id,
      'old_quantity', v_item.requested_quantity,
      'new_quantity', p_new_quantity,
      'item_name', v_item.grn_items_item_name
    )
  );
EXCEPTION
  WHEN insufficient_privilege THEN RAISE;
  WHEN OTHERS THEN
    RETURN jsonb_build_object('success', false, 'message', 'Error updating quantity: ' || SQLERRM);
END;
$$;
REVOKE ALL ON FUNCTION public.update_order_item_quantity(uuid, integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.update_order_item_quantity(uuid, integer) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.remove_item_from_order(p_order_item_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, extensions, warehouse_security, pg_temp
AS $$
DECLARE
  v_user_id uuid;
  v_item record;
BEGIN
  PERFORM warehouse_security.authorize_rpc(
    'remove_item_from_order',
    jsonb_build_object('p_order_item_id', p_order_item_id)
  );

  SELECT id INTO v_user_id
  FROM public.user_profiles
  WHERE auth_user_id = auth.uid() AND active;

  SELECT oi.*, o.status AS order_status, o.deleted_at AS order_deleted_at
  INTO v_item
  FROM public.order_items oi
  JOIN public.orders o ON o.id = oi.order_id
  WHERE oi.id = p_order_item_id
  FOR UPDATE OF oi;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'message', 'Order item not found');
  END IF;
  IF v_item.order_status <> 'OPEN' OR v_item.order_deleted_at IS NOT NULL THEN
    RETURN jsonb_build_object(
      'success', false,
      'message', 'Cannot remove items from ' || COALESCE(v_item.order_status, 'closed') || ' orders',
      'error', jsonb_build_object('code', 'ORDER_NOT_OPEN')
    );
  END IF;

  DELETE FROM public.order_items WHERE id = p_order_item_id;

  -- The removed lot is recorded at quantity 0 so the change log reports a removal.
  PERFORM warehouse_security.record_order_revision(
    v_item.order_id, v_user_id, 'UPDATE',
    jsonb_build_object('removed_item', jsonb_build_object(
      'item_id', v_item.grn_items_item_id,
      'item_name', v_item.grn_items_item_name,
      'grn_no', v_item.grns_gr_no,
      'package_mark', v_item.grn_items_package_mark,
      'requested_quantity', v_item.requested_quantity,
      'fulfilled_quantity', v_item.fulfilled_quantity)),
    jsonb_build_array(jsonb_build_object(
      'item_id', v_item.grn_items_item_id,
      'item_name', v_item.grn_items_item_name,
      'quantity', 0,
      'grn_no', v_item.grns_gr_no,
      'package_mark', v_item.grn_items_package_mark))
  );
  UPDATE public.orders SET updated_at = now(), updated_by = v_user_id WHERE id = v_item.order_id;

  RETURN jsonb_build_object(
    'success', true,
    'message', 'Item removed from order successfully',
    'data', jsonb_build_object(
      'order_item_id', p_order_item_id,
      'removed_item', v_item.grn_items_item_name,
      'removed_quantity', v_item.requested_quantity
    )
  );
EXCEPTION
  WHEN insufficient_privilege THEN RAISE;
  WHEN OTHERS THEN
    RETURN jsonb_build_object('success', false, 'message', 'Error removing item: ' || SQLERRM);
END;
$$;
REVOKE ALL ON FUNCTION public.remove_item_from_order(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.remove_item_from_order(uuid) TO authenticated, service_role;

-- Not part of the API surface (no authenticated grant). Redefined so that they
-- write history through the helper and keep working under the column CHECK.
CREATE OR REPLACE FUNCTION public.update_order_items_batch(p_order_id uuid, p_items jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, extensions, warehouse_security, pg_temp
AS $$
DECLARE
  v_user_id uuid;
  v_item jsonb;
  v_update_count integer := 0;
  v_rows integer;
BEGIN
  PERFORM warehouse_security.authorize_rpc('update_order_items_batch', jsonb_build_object('p_order_id', p_order_id));

  SELECT id INTO v_user_id FROM public.user_profiles WHERE auth_user_id = auth.uid() AND active;
  IF NOT EXISTS (SELECT 1 FROM public.orders WHERE id = p_order_id) THEN
    RETURN jsonb_build_object('success', false, 'message', 'Order not found');
  END IF;

  FOR v_item IN SELECT * FROM jsonb_array_elements(COALESCE(p_items, '[]'::jsonb)) LOOP
    UPDATE public.order_items
    SET requested_quantity = (v_item->>'quantity')::integer,
        updated_at = now()
    WHERE id = (v_item->>'order_item_id')::uuid AND order_id = p_order_id;
    GET DIAGNOSTICS v_rows = ROW_COUNT;
    v_update_count := v_update_count + v_rows;
  END LOOP;

  PERFORM warehouse_security.record_order_revision(
    p_order_id, v_user_id, 'UPDATE',
    jsonb_build_object('batch_update', true, 'items_updated', v_update_count));
  UPDATE public.orders SET updated_at = now(), updated_by = v_user_id WHERE id = p_order_id;

  RETURN jsonb_build_object(
    'success', true,
    'message', format('%s items updated successfully', v_update_count),
    'data', jsonb_build_object('items_updated', v_update_count)
  );
EXCEPTION
  WHEN insufficient_privilege THEN RAISE;
  WHEN OTHERS THEN
    RETURN jsonb_build_object('success', false, 'message', 'Error in batch update: ' || SQLERRM);
END;
$$;

CREATE OR REPLACE FUNCTION public.update_order_metadata(
  p_order_id uuid,
  p_note text DEFAULT NULL::text,
  p_priority text DEFAULT NULL::text,
  p_requested_dispatch_date timestamp without time zone DEFAULT NULL::timestamp without time zone
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, extensions, warehouse_security, pg_temp
AS $$
DECLARE
  v_user_id uuid;
BEGIN
  PERFORM warehouse_security.authorize_rpc('update_order_metadata', jsonb_build_object('p_order_id', p_order_id));

  SELECT id INTO v_user_id FROM public.user_profiles WHERE auth_user_id = auth.uid() AND active;

  UPDATE public.orders
  SET note = COALESCE(p_note, note),
      priority = COALESCE(p_priority, priority),
      requested_dispatch_date = COALESCE(p_requested_dispatch_date, requested_dispatch_date),
      updated_at = now(),
      updated_by = v_user_id
  WHERE id = p_order_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'message', 'Order not found');
  END IF;

  PERFORM warehouse_security.record_order_revision(p_order_id, v_user_id);

  RETURN jsonb_build_object('success', true, 'message', 'Order metadata updated successfully');
EXCEPTION
  WHEN insufficient_privilege THEN RAISE;
  WHEN OTHERS THEN
    RETURN jsonb_build_object('success', false, 'message', 'Error updating order metadata: ' || SQLERRM);
END;
$$;

-- ---------------------------------------------------------------------------
-- Dispatch deletion records its history row in order_revisions.
-- ---------------------------------------------------------------------------
DO $patch$
DECLARE definition text; marker_a text; replacement_a text; marker_b text; replacement_b text; occurrences integer;
BEGIN
  definition := pg_get_functiondef('public.delete_dispatch_with_order_cleanup(uuid,uuid)'::regprocedure);
  marker_a := $m$        UPDATE orders
        SET
            revisions = COALESCE(revisions, '[]'::jsonb) || jsonb_build_array(
                jsonb_build_object(
                    'action', 'dispatch_deleted',$m$;
  replacement_a := $r$        INSERT INTO public.order_revisions (order_id, changed_at, changed_by, action, entry)
        SELECT id, clock_timestamp(), v_user_profile_id, 'dispatch_deleted', (
                jsonb_build_object(
                    'action', 'dispatch_deleted',$r$;
  marker_b := $m$                )
            )
        WHERE id = v_dispatch_record.source_order_id;

        -- Update order status to OPEN and clear soft-delete$m$;
  replacement_b := $r$                )
            )
        FROM public.orders WHERE id = v_dispatch_record.source_order_id;

        -- Update order status to OPEN and clear soft-delete$r$;
  occurrences := (length(definition)-length(replace(definition,marker_a,'')))/length(marker_a);
  IF occurrences <> 1 THEN RAISE EXCEPTION 'Expected one revisions update in delete_dispatch_with_order_cleanup, found %', occurrences; END IF;
  occurrences := (length(definition)-length(replace(definition,marker_b,'')))/length(marker_b);
  IF occurrences <> 1 THEN RAISE EXCEPTION 'Expected one revisions update tail in delete_dispatch_with_order_cleanup, found %', occurrences; END IF;
  EXECUTE replace(replace(definition, marker_a, replacement_a), marker_b, replacement_b);
END $patch$;

-- ---------------------------------------------------------------------------
-- The change log reads order_revisions. The subquery exposes entry as `value`,
-- so every existing r.value reference is unchanged.
-- ---------------------------------------------------------------------------
DO $patch$
DECLARE definition text; two_space text; one_space text; replacement text; occurrences integer;
BEGIN
  definition := pg_get_functiondef('public.get_order_change_log(uuid,uuid,timestamp with time zone,timestamp with time zone,uuid,text,integer,integer)'::regprocedure);
  two_space := 'CROSS  JOIN LATERAL jsonb_array_elements(o.revisions) r';
  one_space := 'CROSS JOIN LATERAL jsonb_array_elements(o.revisions) r';
  replacement := 'JOIN (SELECT order_id, entry AS value FROM public.order_revisions) r ON r.order_id = o.id';
  IF position($g$authorize_rpc('get_order_change_log'$g$ IN definition) = 0 THEN
    RAISE EXCEPTION 'get_order_change_log lost its RPC guard';
  END IF;
  occurrences := (length(definition)-length(replace(definition,two_space,'')))/length(two_space);
  IF occurrences <> 3 THEN RAISE EXCEPTION 'Expected three revisions joins in get_order_change_log, found %', occurrences; END IF;
  definition := replace(definition, two_space, replacement);
  occurrences := (length(definition)-length(replace(definition,one_space,'')))/length(one_space);
  IF occurrences <> 1 THEN RAISE EXCEPTION 'Expected one dispatch revisions join in get_order_change_log, found %', occurrences; END IF;
  definition := replace(definition, one_space, replacement);
  IF position('o.revisions' IN definition) > 0 THEN
    RAISE EXCEPTION 'get_order_change_log still reads orders.revisions';
  END IF;
  EXECUTE definition;
END $patch$;

-- Customers remove cart lines only through remove_item_from_order, which records history.
DROP POLICY starter_customer_delete ON public.order_items;

DROP FUNCTION public.convert_order_to_dispatch(uuid, uuid);
DROP FUNCTION public.update_order_after_dispatch_creation(uuid, uuid, uuid);

NOTIFY pgrst, 'reload schema';
