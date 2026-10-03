-- Approved policy: active staff may view/create/edit warehouse GRNs.
-- All destructive document RPCs and unrelated business/admin bypasses remain
-- admin/supervisor-only. Mutations use existing guarded business RPCs; direct
-- table writes stay denied, including deleted_at/stock manipulation.
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
  -- Approved staff GRN workflow; do not grant the general staff-wide bypass.
  IF role_name = 'staff' AND rpc IN (
    'save_grn','update_grn','check_grn_exists','get_next_grn_number',
    'get_all_grn_items','get_grn_list','get_grn_details','get_grn_item_dispatches',
    'get_grn_autocomplete','get_grn_prefixes_with_stock','get_all_grn_activity',
    'get_customer_grn_activity','get_customer_grn_items',
    'search_customers','get_supervisors','get_vehicle_suggestions',
    'register_grn_image_upload','confirm_grn_image_upload',
    'cancel_grn_image_upload','upload_grn_image'
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


DO $$
DECLARE table_name text;
BEGIN
  FOREACH table_name IN ARRAY ARRAY['customers','goodsreceived','goodsreceived_trl'] LOOP
    EXECUTE format('CREATE POLICY starter_grn_staff_read ON public.%I FOR SELECT TO authenticated USING (warehouse_security.active_role() = ''staff'')', table_name);
  END LOOP;
END $$;
CREATE POLICY starter_grn_staff_read ON public.grn_images FOR SELECT TO authenticated
USING (warehouse_security.active_role() = 'staff' AND
  (status = 'confirmed' OR uploaded_by = public.get_current_user_profile_id()));

-- Only these GRN read functions retain older internal role filters. Do not
-- widen shared role helpers, customer ownership, or non-GRN RPCs.
DO $$
DECLARE fn regprocedure; definition text; changed text;
BEGIN
  fn := 'public.get_all_grn_items(uuid,uuid,boolean,text,integer,integer)'::regprocedure;
  definition := pg_get_functiondef(fn);
  changed := replace(definition, 'IF is_admin_or_supervisor() THEN',
    'IF warehouse_security.active_role() IN (''admin'',''supervisor'',''staff'') THEN');
  IF changed = definition THEN RAISE EXCEPTION 'Expected GRN item role filter missing'; END IF;
  EXECUTE changed;
  fn := 'public.get_all_grn_activity(date,date)'::regprocedure;
  definition := pg_get_functiondef(fn);
  changed := replace(definition, '(''admin'', ''supervisor'', ''service_role'')',
    '(''admin'', ''supervisor'', ''staff'', ''service_role'')');
  IF changed = definition THEN RAISE EXCEPTION 'Expected GRN activity role filter missing'; END IF;
  EXECUTE changed;
END $$;
-- A denied delete must preserve the authorization error. The imported
-- catch-all otherwise reads an unassigned GRN record before the lookup runs.
DO $$
DECLARE definition text; changed text;
BEGIN
  definition := pg_get_functiondef('public.delete_grn_safe(uuid)'::regprocedure);
  changed := replace(definition, E'EXCEPTION\n          WHEN OTHERS THEN',
    E'EXCEPTION\n          WHEN insufficient_privilege THEN RAISE;\n          WHEN OTHERS THEN');
  IF changed = definition THEN RAISE EXCEPTION 'Expected GRN delete exception handler missing'; END IF;
  EXECUTE changed;
END $$;
NOTIFY pgrst, 'reload schema';
