-- User-approved staff dispatch/invoice RPC access.
-- No table/storage policies or pricing mutations are changed.
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
    'search_customers','get_supervisors','get_vehicle_suggestions',
    'register_grn_image_upload','confirm_grn_image_upload',
    'cancel_grn_image_upload','upload_grn_image',
    'create_dispatch_with_stock_check','update_dispatch_smart',
    'check_dispatch_exists','get_next_dispatch_number','get_dispatch_autocomplete',
    'get_dispatch_details','get_dispatch_list','get_dispatch_list_with_items',
    'get_all_dispatch_items','get_all_dispatch_activity','get_customer_dispatch_list',
    'get_customer_dispatch_items',
    'save_invoice','update_invoice','get_next_invoice_number',
    'get_invoiceable_grns','get_invoices_list','get_invoice_data','get_invoice_detail',
    'get_invoice_items_detailed','get_customer_invoice_summary',
    'generate_invoice_data_for_grn_with_pricing','get_item_storage_prices'
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
  ELSIF rpc IN ('get_order_with_items','get_cart_dispatches','add_item_to_order','update_order_item_quantity') THEN
    document := COALESCE(args->>'p_order_id', args->>'p_cart_id')::uuid;
    IF rpc = 'update_order_item_quantity' THEN SELECT order_id INTO document FROM public.order_items WHERE id=(args->>'p_order_item_id')::uuid; END IF;
    SELECT customer_id INTO customer FROM public.orders WHERE id=document;
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

-- The dispatcher implementations have their own legacy role check. Change only
-- the existing document creation/edit functions, never a shared role helper.
DO $$ DECLARE fn record; definition text; changed text; BEGIN
  FOR fn IN SELECT p.oid FROM pg_proc p WHERE p.pronamespace='public'::regnamespace
    AND p.proname IN ('create_dispatch_with_stock_check_2arg_internal',
      'create_dispatch_with_stock_check_internal','create_dispatch_with_stock_check_internal_3param',
      'create_dispatch_with_stock_check_internal_4param','update_dispatch_smart','get_invoiceable_grns') LOOP
    definition := pg_get_functiondef(fn.oid);
    changed := replace(definition,'is_admin_or_supervisor()',
      'warehouse_security.active_role() IN (''admin'',''supervisor'',''staff'')');
    IF changed <> definition THEN EXECUTE changed; END IF;
  END LOOP;
END $$;
-- Match the imported materialized view's varchar[] GRN numbers to the
-- existing text filter. PostgreSQL resolves this operator even for NULL filters.
DO $$ DECLARE definition text; changed text; BEGIN
  definition := pg_get_functiondef('public.get_dispatch_list(timestamptz,timestamptz,jsonb,text,text,integer,integer)'::regprocedure);
  changed := replace(definition,'m.grn_numbers && ARRAY[v_grn_filter]',
    'm.grn_numbers::text[] && ARRAY[v_grn_filter]');
  IF changed=definition THEN RAISE EXCEPTION 'Expected dispatch GRN array predicate missing'; END IF;
  EXECUTE changed;
END $$;
NOTIFY pgrst, 'reload schema';
