-- warehouse_security.authorize_rpc: the definition setup applies after the numbered migrations whenever this file's checksum changes
-- (scripts/migration-plan.mjs, table warehouse_migrations.definitions). Edit the function here, never in a new migration.
-- Starts as the function migrations 000 to 126 leave (the numbered files that patched it stay as they are, never edited).
CREATE OR REPLACE FUNCTION warehouse_security.authorize_rpc(rpc text, args jsonb)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public'
AS $function$
DECLARE role_name text := warehouse_security.active_role(); customer uuid; other_customer uuid; document uuid;
  removable boolean;
BEGIN
  IF auth.jwt()->>'role' = 'service_role' THEN RETURN; END IF;
  IF role_name IS NULL THEN RAISE EXCEPTION 'Active account required' USING ERRCODE = '42501'; END IF;
  -- User management: administrators, and supervisors for other people who are
  -- not administrators. The four bodies refuse a supervisor who targets an
  -- administrator or the own profile, or who grants the administrator role.
  IF rpc IN ('update_user_role','update_user_status','assign_customer_to_user','remove_customer_assignment') THEN
    IF role_name NOT IN ('admin','supervisor') THEN RAISE EXCEPTION 'Administrator required' USING ERRCODE = '42501'; END IF;
    RETURN;
  END IF;
  -- Central identity (migration 49), sensor settings (migration 74), service accounts
  -- (migration 78) and the numbering rules (migration 127): administrators only.
  IF rpc IN ('clear_user_central_identity','update_sensor_device','set_service_account','set_document_numbering') THEN
    IF role_name <> 'admin' THEN RAISE EXCEPTION 'Administrator required' USING ERRCODE = '42501'; END IF;
    RETURN;
  END IF;
  IF role_name IN ('admin','supervisor') THEN RETURN; END IF;
  -- Approved document RPCs only; no shared ownership or table-policy change.
  IF role_name = 'staff' AND rpc IN (
    'save_grn','update_grn','check_grn_exists','get_next_grn_number',
    'get_all_grn_items','get_grn_list','get_grn_details',
    -- The next GRN, dispatch or invoice number under the facility's rule (migration 127); the rules are read by supervisors and above.
    'suggest_document_number',
    -- The GRN edit form's version and locks (migration 121); customers stay refused by the final ELSE.
    'get_grn_edit_state','get_grn_item_dispatches',
    'get_grn_prefixes_with_stock','get_all_grn_activity',
    'get_customer_grn_activity','get_customer_grn_items',
    'get_customer_grns_with_stock_dispatch_sorted',
    'search_customers','get_supervisors','get_vehicle_suggestions',
    'register_grn_image_upload','confirm_grn_image_upload',
    'cancel_grn_image_upload','upload_grn_image',
    'register_dispatch_image_upload','confirm_dispatch_image_upload',
    'cancel_dispatch_image_upload',
    'create_dispatch_with_stock_check','update_dispatch_smart',
    'check_dispatch_exists','get_next_dispatch_number','get_dispatch_autocomplete',
    'get_dispatch_details','get_dispatch_list_with_items',
    'get_all_dispatch_items','get_all_dispatch_activity','get_customer_dispatch_list',
    'get_customer_dispatch_items','get_recent_dispatched_orders',
    -- What became of a save whose answer was lost (migration 120).
    'get_submission_result',
    'save_invoice','update_invoice','get_next_invoice_number',
    'get_invoiceable_grns','get_invoices_list','get_invoice_data','get_invoice_detail',
    'get_invoice_items_detailed','get_customer_invoice_summary',
    'generate_invoice_data_for_grn_with_pricing',
    -- Orders and queue (user decision, 2026-10-09).
    'get_orders_list','get_order_with_items','get_or_create_cart',
    'add_item_to_order','update_order_item_quantity','remove_item_from_order',
    'search_customer_items_for_order',
    'get_customer_items_for_order_selection','get_order_change_log',
    -- Reports the app shows to staff (owner decision, 2026-10-11).
    'get_all_stock_summary','get_customer_stock_summary',
    'get_all_customer_activity_summary','get_customer_activity_detail',
    'get_customer_dispatch_activity','get_stock_aging_report','get_item_wise_stock_list',
    -- Item pricing is for administrators and supervisors (migration 90); staff keep
    -- only the rates a GRN is invoiced at (migration 88, below).
    -- The rate of each line of a GRN (migration 88).
    'get_grn_item_rates',
    -- Sensors (owner decision, 2026-10-11).
    'get_sensor_polling_data','get_sensor_history',
    -- One sensor (migration 74).
    'get_sensor_device',
    -- The print "View jobs" sheet (migration 123); customers stay refused by the final ELSE.
    'get_print_jobs','cancel_print_job'
  ) THEN RETURN; END IF;
  -- Photo removal in the edit forms (owner decision, 2026-10-11): a photo of a
  -- receipt or dispatch that staff can open for editing, and that is confirmed
  -- or was registered by the caller. Another person's pending upload stays
  -- with that person, as for cancel_*_image_upload (migration 23).
  IF role_name = 'staff' AND rpc IN ('delete_grn_image','delete_dispatch_image') THEN
    IF rpc = 'delete_grn_image' THEN
      SELECT COALESCE(g.deleted_at IS NULL AND (i.status = 'confirmed' OR i.uploaded_by = public.get_current_user_profile_id()), false)
        INTO removable FROM public.grn_images i JOIN public.goodsreceived g ON g.id = i.grn_id
        WHERE i.id = (args->>'p_image_id')::uuid;
    ELSE
      SELECT COALESCE(d.deleted_at IS NULL AND (i.status = 'confirmed' OR i.uploaded_by = public.get_current_user_profile_id()), false)
        INTO removable FROM public.dispatch_images i JOIN public.dispatch d ON d.id = i.dispatch_id
        WHERE i.id = (args->>'p_image_id')::uuid;
    END IF;
    -- An unknown id is answered by the function itself ("not found").
    IF removable IS FALSE THEN RAISE EXCEPTION 'Staff access required' USING ERRCODE = '42501'; END IF;
    RETURN;
  END IF;

  IF rpc IN ('get_items','get_item','search_items_autocomplete','get_orders_list','delete_user_account') THEN RETURN; END IF;
  -- get_stock_aging_report and get_item_wise_stock_list: with a customer id
  -- they are that customer's report; without one they are the all-customers
  -- report, which no customer account may run.
  IF rpc LIKE 'get_customer_%' OR rpc IN ('search_customer_items_for_order','get_or_create_cart',
      'get_stock_aging_report','get_item_wise_stock_list') THEN
    customer := COALESCE(args->>'p_customer_id', args->>'p_customer_uuid')::uuid;
  ELSIF rpc IN ('get_grn_details','get_grn_item_dispatches','get_grn_item_rates') THEN
    IF args ? 'p_grn_item_id' THEN
      SELECT g.customer_id INTO customer FROM public.goodsreceived_trl t JOIN public.goodsreceived g ON g.id=t.gr_id WHERE t.id=(args->>'p_grn_item_id')::uuid;
    ELSE SELECT customer_id INTO customer FROM public.goodsreceived WHERE id=(args->>'p_grn_id')::uuid; END IF;
  ELSIF rpc = 'get_dispatch_details' THEN
    SELECT customer_id INTO customer FROM public.dispatch WHERE id=(args->>'p_dispatch_id')::uuid;
  ELSIF rpc IN ('get_invoice_data','get_invoice_detail','get_invoice_items_detailed') THEN
    SELECT customer_id INTO customer FROM public.invoice WHERE id=(args->>'p_invoice_id')::uuid;
  ELSIF rpc IN ('get_order_with_items','add_item_to_order',
                'update_order_item_quantity','remove_item_from_order','get_order_change_log') THEN
    document := COALESCE(args->>'p_order_id', args->>'p_cart_id')::uuid;
    IF rpc IN ('update_order_item_quantity','remove_item_from_order') THEN
      SELECT order_id INTO document FROM public.order_items WHERE id=(args->>'p_order_item_id')::uuid;
      -- A line that no longer exists (used up by a dispatch, removed on another phone) acts on nothing: the
      -- function answers "Order item not found" instead of "Customer access denied" (migration 120). A line
      -- that exists is still checked against its customer below.
      IF NOT FOUND THEN RETURN; END IF;
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
END $function$;

REVOKE ALL ON FUNCTION warehouse_security.authorize_rpc(text,jsonb) FROM PUBLIC, anon, authenticated, service_role;
