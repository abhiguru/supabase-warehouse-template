-- The server admits what the app offers (owner decision, 2026-10-11).
--
-- The app showed several screens to a role whose RPCs the guard refused, so the
-- screen opened and then failed: the report set and Settings > Item pricing and
-- Sensors for staff, photo removal in the receipt and dispatch edit forms for
-- staff, and user management for supervisors. The owner decided to widen the
-- server allowlist rather than hide the screens. This supersedes the earlier
-- staff pricing refusal (migration 23) and the administrator-only user
-- management of migrations 3 to 28. docs/STAFF_GRN_POLICY.md, "The server
-- admits what the app offers", lists what was opened and to whom.
--
-- Not widened: a customer account is still refused every all-customers RPC,
-- pricing and sensors. The two stock reports that take a customer id are
-- admitted for a customer account only with the id of an assigned customer.
--
-- Also in this migration (review, 2026-10-10):
--   * staff read policy on orders, so the live order queue reaches staff;
--   * customer accounts no longer receive the supervisor's mobile number and
--     role in get_grn_details / get_dispatch_details;
--   * get_supervisors lists active profiles only;
--   * four report bodies read the caller's role from the database, not from
--     the token;
--   * printer_status is no longer readable without signing in.

-- Replaces one marker in a function body, failing unless it occurs exactly
-- `expected` times. Dropped at the end of this migration.
CREATE FUNCTION pg_temp.patch_rpc(fn regprocedure, marker text, replacement text, expected integer DEFAULT 1) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE definition text := pg_get_functiondef(fn); occurrences integer;
BEGIN
  occurrences := (length(definition)-length(replace(definition,marker,'')))/length(marker);
  IF occurrences <> expected THEN
    RAISE EXCEPTION 'Expected % occurrence(s) of the marker in %, found %: %', expected, fn, occurrences, left(marker,80);
  END IF;
  EXECUTE replace(definition,marker,replacement);
END $$;

-- ---------------------------------------------------------------------------
-- 1. RPC guard v6: migration 28 body plus the 2026-10-11 decision
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION warehouse_security.authorize_rpc(rpc text, args jsonb) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
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
    'get_customer_items_for_order_selection','get_order_change_log',
    -- Reports the app shows to staff (owner decision, 2026-10-11).
    'get_all_stock_summary','get_customer_stock_summary',
    'get_all_customer_activity_summary','get_customer_activity_detail',
    'get_customer_dispatch_activity','get_stock_aging_report','get_item_wise_stock_list',
    -- Item pricing, read and write (owner decision, 2026-10-11; supersedes
    -- the refusal of migration 23).
    'get_item_storage_prices','find_or_create_item_storage_price',
    'create_item_storage_price','update_item_storage_price','delete_item_storage_price',
    -- Sensors (owner decision, 2026-10-11).
    'get_sensor_polling_data','get_sensor_history'
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
-- 2. Photo removal: the guard needs the image id to scope the staff rule
-- ---------------------------------------------------------------------------
DO $patch$ BEGIN PERFORM pg_temp.patch_rpc('public.delete_grn_image(uuid)',
  $m$authorize_rpc('delete_grn_image',jsonb_build_object())$m$,
  $r$authorize_rpc('delete_grn_image',jsonb_build_object('p_image_id',p_image_id))$r$); END $patch$;
DO $patch$ BEGIN PERFORM pg_temp.patch_rpc('public.delete_dispatch_image(uuid)',
  $m$authorize_rpc('delete_dispatch_image',jsonb_build_object())$m$,
  $r$authorize_rpc('delete_dispatch_image',jsonb_build_object('p_image_id',p_image_id))$r$); END $patch$;

-- The app removes the stored file after the row. Staff could not: their
-- storage policies cover a file only while an image row names it. This tells
-- the storage policies (scripts/configure-storage.sql) that no image row names
-- a file any more, without giving staff a read of other people's pending rows.
-- The legacy header columns gr_image_url / disp_image_url are written by no
-- RPC and are not consulted.
CREATE FUNCTION warehouse_security.image_file_unreferenced(p_bucket text, p_name text) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog AS $$
  SELECT CASE p_bucket
    WHEN 'grn-images' THEN NOT EXISTS (SELECT 1 FROM public.grn_images i WHERE i.storage_path = p_name)
    WHEN 'dispatch-images' THEN NOT EXISTS (SELECT 1 FROM public.dispatch_images i WHERE i.storage_path = p_name)
    ELSE false END;
$$;
REVOKE ALL ON FUNCTION warehouse_security.image_file_unreferenced(text,text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION warehouse_security.image_file_unreferenced(text,text) TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 3. User management by supervisors
-- ---------------------------------------------------------------------------
-- update_user_role and update_user_status have carried the supervisor rules in
-- their bodies since the baseline (no administrator target, no administrator
-- grant, not the own profile) and the last-administrator rule since migration
-- 44. The two assignment RPCs had no such rule because only administrators
-- reached them.
DO $patch$ BEGIN PERFORM pg_temp.patch_rpc(fn, $m$      IF target_user_id IS NULL THEN
          RAISE EXCEPTION 'User with mobile % not found or inactive', target_user_mobile;
      END IF;
$m$, $r$      IF target_user_id IS NULL THEN
          RAISE EXCEPTION 'User with mobile % not found or inactive', target_user_mobile;
      END IF;

      -- A supervisor manages other people who are not administrators
      IF warehouse_security.active_role() = 'supervisor' AND (
          target_user_id = public.get_current_user_profile_id()
          OR EXISTS (SELECT 1 FROM user_profiles WHERE id = target_user_id AND role = 'admin')) THEN
          RAISE EXCEPTION 'Supervisors cannot change their own or an administrator''s customer assignments' USING ERRCODE = '42501';
      END IF;
$r$)
FROM unnest(ARRAY['public.assign_customer_to_user(character varying,uuid,text)',
  'public.remove_customer_assignment(character varying,uuid)']::regprocedure[]) AS fn; END $patch$;

-- ---------------------------------------------------------------------------
-- 4. Item pricing for staff
-- ---------------------------------------------------------------------------
-- The create and update bodies already admit staff; delete did not.
DO $patch$ BEGIN PERFORM pg_temp.patch_rpc('public.delete_item_storage_price(uuid)',
  $m$    IF v_user_role IS NULL OR v_user_role NOT IN ('admin', 'supervisor') THEN
        RETURN jsonb_build_object('success', false, 'error', 'Permission denied');$m$,
  $r$    IF v_user_role IS NULL OR v_user_role NOT IN ('admin', 'supervisor', 'staff') THEN
        RETURN jsonb_build_object('success', false, 'error', 'Permission denied');$r$); END $patch$;
-- find_or_create_item_storage_price looked the caller up in auth.users, which
-- has no row for an operator sign-in, so it refused every role.
DO $patch$ BEGIN PERFORM pg_temp.patch_rpc('public.find_or_create_item_storage_price(uuid,uuid,numeric,text,numeric,numeric,numeric,numeric,numeric)',
  $m$    SELECT phone INTO v_user_phone
    FROM auth.users
    WHERE id = v_user_id;

    SELECT id, role INTO v_profile_id, v_user_role
    FROM user_profiles
    WHERE mobile = v_user_phone;
$m$, $r$    SELECT id, role INTO v_profile_id, v_user_role
    FROM user_profiles
    WHERE auth_user_id = v_user_id AND active;
$r$); END $patch$;

-- ---------------------------------------------------------------------------
-- 5. Supervisor picker and supervisor contact details
-- ---------------------------------------------------------------------------
-- The picker listed deactivated and not yet approved profiles.
DO $patch$ BEGIN PERFORM pg_temp.patch_rpc('public.get_supervisors(text)',
  $m$        WHERE role IN ('admin', 'supervisor', 'staff')
$m$, $r$        WHERE role IN ('admin', 'supervisor', 'staff')
          AND active
$r$); END $patch$;
-- A customer account sees who handled its receipt or dispatch by name. The
-- mobile number (also that person's sign-in identifier) and the internal role
-- go to warehouse roles only. No owner decision was given; this is the
-- privacy-safe default and is reversed by removing the subtraction.
DO $patch$ BEGIN PERFORM pg_temp.patch_rpc(fn, $m$                            'mobile', u.mobile,
                            'role', u.role,
                            'display_name', u.display_name
                        )
$m$, $r$                            'mobile', u.mobile,
                            'role', u.role,
                            'display_name', u.display_name
                        ) - CASE WHEN v_role IN ('admin', 'supervisor', 'staff')
                                   OR auth.jwt() ->> 'role' = 'service_role'
                                 THEN ARRAY[]::text[] ELSE ARRAY['mobile', 'role'] END
$r$)
FROM unnest(ARRAY['public.get_grn_details(uuid)','public.get_dispatch_details(uuid)']::regprocedure[]) AS fn; END $patch$;

-- ---------------------------------------------------------------------------
-- 6. The caller's role comes from the database, not from the token
-- ---------------------------------------------------------------------------
-- Four bodies read the role from the `user_role` claim, which is minted at
-- sign-in and so outlives a role change (and is absent from a token without
-- that claim, which skipped the check). The guard already uses the live role;
-- the bodies now do too. A service-role call keeps passing.
DO $patch$ BEGIN PERFORM pg_temp.patch_rpc(fn, $m$    v_user_role := COALESCE(
        (current_setting('request.jwt.claims', true)::jsonb ->> 'user_role'),
        (current_setting('request.jwt.claims', true)::jsonb -> 'user_metadata' ->> 'role')
    );
$m$, $r$    v_user_role := COALESCE(warehouse_security.active_role(),
        CASE WHEN auth.jwt() ->> 'role' = 'service_role' THEN 'service_role' ELSE 'none' END);
$r$)
FROM unnest(ARRAY['public.get_customer_dispatch_activity(uuid,date,date)','public.get_customer_stock_summary(uuid)',
  'public.get_operations_dashboard(date,date)']::regprocedure[]) AS fn; END $patch$;
DO $patch$ BEGIN PERFORM pg_temp.patch_rpc('public.get_recent_dispatched_orders(integer,integer)', $m$    v_user_role := COALESCE(
        (current_setting('request.jwt.claims', true)::jsonb ->> 'user_role'),
        (SELECT role::text FROM user_profiles WHERE auth_user_id = auth.uid())
    );
$m$, $r$    v_user_role := COALESCE(warehouse_security.active_role(),
        CASE WHEN auth.jwt() ->> 'role' = 'service_role' THEN 'admin' ELSE 'none' END);
$r$); END $patch$;
-- Staff read these two reports for every customer, an inactive one included.
DO $patch$ BEGIN PERFORM pg_temp.patch_rpc(fn, $m$    IF v_user_role NOT IN ('admin', 'supervisor', 'service_role') THEN
        IF NOT EXISTS ($m$, $r$    IF v_user_role NOT IN ('admin', 'supervisor', 'staff', 'service_role') THEN
        IF NOT EXISTS ($r$)
FROM unnest(ARRAY['public.get_customer_dispatch_activity(uuid,date,date)',
  'public.get_customer_stock_summary(uuid)']::regprocedure[]) AS fn; END $patch$;

COMMENT ON FUNCTION public.is_admin_or_supervisor() IS
  'Returns true for admin, supervisor AND staff, despite its name. It does not keep staff out of anything: warehouse_security.authorize_rpc does. tests/role_allowlist.sql lists every granted function that calls it.';

-- ---------------------------------------------------------------------------
-- 7. Table policies
-- ---------------------------------------------------------------------------
-- Staff have had the order RPCs since migration 28 but no row policy on
-- orders, so Realtime delivered no order change to a staff session and the
-- queue refreshed only on reconnect. Read only; orders are written through the
-- cart RPCs (migration 42).
CREATE POLICY starter_order_staff_read ON public.orders FOR SELECT TO authenticated
  USING (warehouse_security.active_role() = 'staff');

-- printer_status (printer name, last error text, last job) was readable with
-- the public anon key. The app does not read it before sign-in; the print
-- path writes it with the service key. feature_flags stays public: the
-- pre-login configuration and the backup integrity check rely on it and it
-- holds seeded, non-sensitive rows.
REVOKE ALL ON public.printer_status FROM PUBLIC, anon;
DROP POLICY starter_public ON public.printer_status;
CREATE POLICY starter_warehouse_read ON public.printer_status FOR SELECT TO authenticated
  USING (warehouse_security.active_role() IN ('admin','supervisor','staff'));

DROP FUNCTION pg_temp.patch_rpc(regprocedure, text, text, integer);
NOTIFY pgrst, 'reload schema';
