-- Explicit API allowlist and uniform authorization before imported business logic.
-- No broad execute grants are inherited from the production installation.
CREATE FUNCTION warehouse_security.active_role() RETURNS text LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog AS $$
  SELECT role::text FROM public.user_profiles WHERE auth_user_id = auth.uid() AND active;
$$;
CREATE FUNCTION warehouse_security.owns_customer(customer uuid) RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog AS $$
  SELECT COALESCE(warehouse_security.active_role() IN ('admin','supervisor'), false) OR
    EXISTS (SELECT 1 FROM public.users_customers_new a JOIN public.user_profiles p ON p.id = a.user_profile_id
      WHERE a.customer_id = customer AND a.active AND p.active AND p.auth_user_id = auth.uid());
$$;
CREATE FUNCTION warehouse_security.authorize_rpc(rpc text, args jsonb) RETURNS void
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

-- Remove EVERY imported permissive policy; rebuild only the documented app surface.
DO $$
DECLARE r record;
BEGIN
  FOR r IN SELECT schemaname, tablename, policyname FROM pg_policies WHERE schemaname='public' LOOP
    EXECUTE format('DROP POLICY %I ON %I.%I', r.policyname, r.schemaname, r.tablename);
  END LOOP;
  FOR r IN SELECT c.relname FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='public' AND c.relkind IN ('r','p') LOOP
    EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', r.relname);
  END LOOP;
END $$;
REVOKE CREATE ON SCHEMA public FROM PUBLIC, anon, authenticated;
REVOKE ALL ON ALL TABLES IN SCHEMA public FROM anon, authenticated;
REVOKE ALL ON ALL SEQUENCES IN SCHEMA public FROM anon, authenticated;
REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA public, utils FROM PUBLIC, anon, authenticated;
GRANT USAGE ON SCHEMA public TO anon, authenticated, service_role;
GRANT USAGE ON SCHEMA warehouse_security TO authenticated;
GRANT EXECUTE ON FUNCTION warehouse_security.active_role(), warehouse_security.owns_customer(uuid) TO authenticated;

-- Staff can manage business tables, not signing/SMS secrets, roles, or assignments.
DO $$
DECLARE table_name text;
BEGIN
  FOREACH table_name IN ARRAY ARRAY['customers','items','item_storage_prices','goodsreceived','goodsreceived_trl',
    'dispatch','dispatch_trl','invoice','invoice_trl','payments','orders','order_items','grn_images','dispatch_images',
    'stock_movements','print_jobs','sensor_devices','sensor_readings','sensor_health_events'] LOOP
    EXECUTE format('GRANT SELECT,INSERT,UPDATE,DELETE ON public.%I TO authenticated',table_name);
    EXECUTE format('CREATE POLICY starter_staff ON public.%I FOR ALL TO authenticated USING (warehouse_security.active_role() IN (''admin'',''supervisor'')) WITH CHECK (warehouse_security.active_role() IN (''admin'',''supervisor''))',table_name);
  END LOOP;
END $$;
CREATE POLICY starter_customer ON public.customers FOR SELECT TO authenticated USING (warehouse_security.owns_customer(id));
CREATE POLICY starter_customer ON public.goodsreceived FOR SELECT TO authenticated USING (warehouse_security.owns_customer(customer_id));
CREATE POLICY starter_customer ON public.dispatch FOR SELECT TO authenticated USING (warehouse_security.owns_customer(customer_id));
CREATE POLICY starter_customer ON public.invoice FOR SELECT TO authenticated USING (warehouse_security.owns_customer(customer_id));
CREATE POLICY starter_customer ON public.payments FOR SELECT TO authenticated USING (warehouse_security.owns_customer(customer_id));
CREATE POLICY starter_catalog ON public.items FOR SELECT TO authenticated USING (warehouse_security.active_role() IS NOT NULL);
CREATE POLICY starter_customer ON public.goodsreceived_trl FOR SELECT TO authenticated USING (EXISTS (SELECT 1 FROM public.goodsreceived g WHERE g.id=gr_id AND warehouse_security.owns_customer(g.customer_id)));
CREATE POLICY starter_customer ON public.dispatch_trl FOR SELECT TO authenticated USING (EXISTS (SELECT 1 FROM public.dispatch d WHERE d.id=disp_id AND warehouse_security.owns_customer(d.customer_id)));
CREATE POLICY starter_customer ON public.invoice_trl FOR SELECT TO authenticated USING (EXISTS (SELECT 1 FROM public.invoice i WHERE i.id=invoice_id AND warehouse_security.owns_customer(i.customer_id)));
CREATE POLICY starter_customer ON public.grn_images FOR SELECT TO authenticated USING (EXISTS (SELECT 1 FROM public.goodsreceived g WHERE g.id=grn_id AND warehouse_security.owns_customer(g.customer_id)));
CREATE POLICY starter_customer ON public.dispatch_images FOR SELECT TO authenticated USING (EXISTS (SELECT 1 FROM public.dispatch d WHERE d.id=dispatch_id AND warehouse_security.owns_customer(d.customer_id)));
CREATE POLICY starter_customer ON public.orders FOR SELECT TO authenticated USING (warehouse_security.owns_customer(customer_id));
-- New/updated order items must remain tied to their order's customer, even for multiply assigned users.
CREATE POLICY starter_customer_read ON public.order_items FOR SELECT TO authenticated USING (EXISTS (SELECT 1 FROM public.orders o WHERE o.id=order_id AND warehouse_security.owns_customer(o.customer_id)));
CREATE POLICY starter_customer_delete ON public.order_items FOR DELETE TO authenticated USING (EXISTS (SELECT 1 FROM public.orders o WHERE o.id=order_id AND warehouse_security.owns_customer(o.customer_id)));
-- Creation/quantity updates use guarded RPCs, not arbitrary direct customer writes.

GRANT SELECT ON public.user_profiles, public.users_customers_new TO authenticated;
GRANT UPDATE(name,display_name) ON public.user_profiles TO authenticated;
CREATE POLICY starter_profile_read ON public.user_profiles FOR SELECT TO authenticated USING (warehouse_security.active_role() IN ('admin','supervisor') OR (auth_user_id=auth.uid() AND active));
CREATE POLICY starter_profile_update ON public.user_profiles FOR UPDATE TO authenticated USING (auth_user_id=auth.uid() AND active) WITH CHECK (auth_user_id=auth.uid() AND active);
CREATE POLICY starter_assignments ON public.users_customers_new FOR SELECT TO authenticated USING (warehouse_security.active_role() IN ('admin','supervisor') OR user_profile_id=public.get_current_user_profile_id());
GRANT EXECUTE ON FUNCTION public.get_current_user_profile_id(), public.get_current_user_role(), public.user_accessible_customers() TO authenticated;
GRANT SELECT ON public.feature_flags, public.printer_status TO anon, authenticated;
CREATE POLICY starter_public ON public.feature_flags FOR SELECT TO anon,authenticated USING (true);
CREATE POLICY starter_public ON public.printer_status FOR SELECT TO anon,authenticated USING (true);

-- Fresh data has no cron jobs. Default partition prevents calendar-based audit failures.
CREATE TABLE IF NOT EXISTS public.audit_log_default PARTITION OF public.audit_log DEFAULT;
ALTER TABLE public.audit_log_default ENABLE ROW LEVEL SECURITY;

DO $guard$
DECLARE r record; definition text; guarded text; arg_name text; pairs text; guard text;
  api_names text[] := ARRAY['add_item_to_order','assign_customer_to_user','cancel_dispatch_image_upload','cancel_grn_image_upload','check_dispatch_exists','check_grn_exists','confirm_dispatch_image_upload','confirm_grn_image_upload','convert_order_to_dispatch','create_customer','create_dispatch_with_stock_check','create_item','create_item_storage_price','delete_dispatch_image','delete_dispatch_with_order_cleanup','delete_grn_image','delete_grn_safe','delete_invoice','delete_item_safe','delete_item_storage_price','delete_user_account','find_or_create_item_storage_price','generate_invoice_data_for_grn_with_pricing','get_all_customer_activity_summary','get_all_dispatch_activity','get_all_dispatch_items','get_all_grn_activity','get_all_grn_items','get_all_stock_summary','get_available_stock','get_cart_dispatches','get_customer_activity_detail','get_customer_dispatch_activity','get_customer_dispatch_items','get_customer_grn_activity','get_customer_grn_items','get_customer_grns_with_stock_dispatch_sorted','get_customer_invoice_summary','get_customer_items_for_order_selection','get_customer_stock_analysis_v2','get_customer_stock_summary','get_dispatch_autocomplete','get_dispatch_details','get_dispatch_list','get_dispatch_list_with_items','get_grn_autocomplete','get_grn_details','get_grn_item_dispatches','get_grn_list','get_grn_prefixes_with_stock','get_invoice_data','get_invoice_detail','get_invoice_items_detailed','get_invoiceable_grns','get_invoices_list','get_item','get_item_storage_prices','get_item_wise_stock_list','get_items','get_next_dispatch_number','get_next_grn_number','get_next_invoice_number','get_operations_dashboard','get_or_create_cart','get_order_change_log','get_order_with_items','get_orders_list','get_recent_dispatched_orders','get_sensor_history','get_sensor_polling_data','get_stock_aging_report','get_supervisors','get_user_details','get_users_list','get_vehicle_suggestions','register_dispatch_image_upload','register_grn_image_upload','remove_customer_assignment','restore_customer','safe_delete_customer','save_grn','save_invoice','search_customer_items_for_order','search_customers','search_items_autocomplete','update_customer','update_dispatch_smart','update_grn','update_invoice','update_item','update_item_storage_price','update_order_item_quantity','update_user_role','update_user_status','upload_grn_image'];
BEGIN
  FOR r IN SELECT p.*, l.lanname FROM pg_proc p JOIN pg_language l ON l.oid=p.prolang
    WHERE p.pronamespace='public'::regnamespace AND p.proname=ANY(api_names)
  LOOP
    -- SQL stock lookup is invoker-mode and reads the RLS-protected table.
    IF r.proname = 'get_available_stock' THEN
      EXECUTE format('ALTER FUNCTION %s SET search_path=pg_catalog,public,extensions,pg_temp',r.oid::regprocedure);
    ELSE
      IF r.lanname <> 'plpgsql' THEN RAISE EXCEPTION 'Unreviewed RPC language: %',r.proname; END IF;
      pairs := '';
      FOREACH arg_name IN ARRAY COALESCE(r.proargnames,ARRAY[]::text[]) LOOP
        IF arg_name=ANY(ARRAY['p_customer_id','p_customer_uuid','p_grn_id','p_grn_item_id','p_dispatch_id','p_invoice_id','p_order_id','p_cart_id','p_order_item_id']) THEN
          pairs := pairs || CASE WHEN pairs='' THEN '' ELSE ',' END || format('%L,%I',arg_name,arg_name);
        END IF;
      END LOOP;
      definition := pg_get_functiondef(r.oid);
      guard := format(E'\nBEGIN\n  PERFORM warehouse_security.authorize_rpc(%L,jsonb_build_object(%s));\n', r.proname,pairs);
      guarded := regexp_replace(definition,E'\n[ \\t]*BEGIN[ \\t]*\n',guard,'i');
      IF guarded = definition THEN RAISE EXCEPTION 'Cannot guard RPC %',r.proname; END IF;
      EXECUTE guarded;
      EXECUTE format('ALTER FUNCTION %s SECURITY DEFINER',r.oid::regprocedure);
      EXECUTE format('ALTER FUNCTION %s SET search_path=pg_catalog,public,extensions,utils,pg_temp',r.oid::regprocedure);
    END IF;
    EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO authenticated',r.oid::regprocedure);
  END LOOP;
END $guard$;

GRANT EXECUTE ON FUNCTION public.send_otp(varchar,varchar,text,inet,text),public.verify_otp_or_register(varchar,varchar,varchar,varchar),
  public.refresh_jwt_token(text),public.logout_session(text) TO anon,authenticated;
GRANT ALL ON ALL TABLES IN SCHEMA public TO service_role;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA public, utils TO service_role;
GRANT USAGE ON ALL SEQUENCES IN SCHEMA public TO service_role;
REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA warehouse_security FROM PUBLIC,anon;
-- Restrict extensions capable of network calls; they are never an anonymous API.
REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA public FROM anon;
GRANT EXECUTE ON FUNCTION public.send_otp(varchar,varchar,text,inet,text),public.verify_otp_or_register(varchar,varchar,varchar,varchar),
  public.refresh_jwt_token(text),public.logout_session(text) TO anon;
