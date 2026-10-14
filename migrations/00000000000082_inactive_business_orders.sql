-- Migration 82: a deactivated business can still order its own goods out (owner decision, 2026-10-15).
--
--   1. get_or_create_cart (migration 80 refused customers.active = false as well): now only a DELETED
--      business (deleted_at set) is refused, with 'Business is not active' (P0001), for every caller.
--      A business that an administrator or supervisor deactivated in Customers is handled exactly as an
--      active one: its existing cart is returned, a new cart is made, a DISPATCHED cart is reset to OPEN,
--      for its customer logins and for staff alike. What deactivation hides, exactly: the business is no
--      longer offered by the staff pickers that use search_customers (new GRN, dispatch, order, and the
--      list-filter customer search), by the all-customers branch of search_customer_items_for_order, and
--      assign_customer_to_user cannot give it a new customer login. Nothing else is hidden: the write RPCs
--      do not check customers.active (save_grn, update_grn and the dispatch RPCs refuse only a DELETED
--      business, item 4b), and the five readers of item 4c show it. Since item 4 only a business without
--      data can be deleted, a refused deleted business never holds an order that is stuck.
--   2. get_orders_list adds 'active' (boolean, customers.active) inside each row's 'customer' object, next
--      to 'name', so the app can mark an order of a deactivated business. Nothing else changes.
--
--   3. Customers -> Deactivate only switches a business off (owner decisions A and B, 2026-10-15).
--      New RPC set_customer_active(p_customer_id, p_active) (administrators and supervisors): false sets
--      active = false only (no stock check, never deleted_at); true sets active = true and clears
--      deleted_at / deleted_by, so an older soft-deleted row comes back.
--   4. Nothing with data is ever deleted. "Data" is any GRN, dispatch or invoice row (deleted ones too), any
--      payment, any customer-specific rate (item_storage_prices.customer_id), any ACTIVE user assignment, and
--      any order that has lines or is not OPEN. safe_delete_customer for such a business:
--        soft (p_permanent = false, what the released app's Deactivate sends): deactivates it instead
--          (active = false only, never deleted_at) and answers success with delete_type 'deactivated';
--        permanent: refuses with the friendly message (never a raw foreign-key error).
--      A business without data: soft delete as before (its empty OPEN carts stay); permanent delete also
--      removes its empty OPEN carts and its inactive assignments. restore_customer (the released app's
--      Activate) accepts a business that is deleted OR inactive and makes it active, deleted_at cleared.
--   4b. save_grn and create_dispatch_with_stock_check (both overloads) refuse a NEW document, and update_grn
--      a move of a GRN to another business, for a DELETED
--      business with 'Business is not active' (P0001); a deactivated business is not refused.
--   4c. get_invoices_list, get_all_stock_summary, get_item_wise_stock_list (all-customers branch),
--      get_all_customer_activity_summary and get_item_dispatch_records no longer hide a deactivated business (filter is deleted_at IS NULL),
--      so staff and administrators still see its stock, invoices and activity.
--   5. Data fix: a soft-deleted business that has such data gets deleted_at / deleted_by cleared and stays
--      active = false, i.e. it becomes "deactivated". The count is logged with RAISE NOTICE.
--
-- Method as in migration 80: the current definitions are patched; each replaced text must occur exactly
-- as often as stated, or the migration fails and applies nothing.

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

DO $patch$ BEGIN
  -- 1. Only a deleted business is refused.
  PERFORM pg_temp.patch_rpc('public.get_or_create_cart(uuid)',
  $m$      IF EXISTS (SELECT 1 FROM customers WHERE id = p_customer_id AND (active = false OR deleted_at IS NOT NULL))
         AND (warehouse_security.active_role() IS NULL
              OR warehouse_security.active_role() NOT IN ('admin', 'supervisor', 'staff')
              OR NOT EXISTS (SELECT 1 FROM orders WHERE customer_id = p_customer_id AND deleted_at IS NULL AND status = 'OPEN')) THEN
$m$,
  $r$      IF EXISTS (SELECT 1 FROM customers WHERE id = p_customer_id AND deleted_at IS NOT NULL) THEN
$r$);

  -- 4. safe_delete_customer: nothing with data is deleted; a soft delete of such a business deactivates it.
  PERFORM pg_temp.patch_rpc('public.safe_delete_customer(uuid,boolean)',
  $m$-- Check for active stock (items with stock > 0)$m$,
  $r$-- Nothing with data is ever deleted (migration 82).
    DECLARE
        v_rel jsonb;
    BEGIN
        SELECT jsonb_build_object(
            'grn_count', (SELECT COUNT(*) FROM goodsreceived WHERE customer_id = p_customer_id),
            'dispatch_count', (SELECT COUNT(*) FROM dispatch WHERE customer_id = p_customer_id),
            'invoice_count', (SELECT COUNT(*) FROM invoice WHERE customer_id = p_customer_id),
            'order_count', (SELECT COUNT(*) FROM orders o WHERE o.customer_id = p_customer_id
                            AND (o.status <> 'OPEN' OR EXISTS (SELECT 1 FROM order_items oi WHERE oi.order_id = o.id))),
            'payment_count', (SELECT COUNT(*) FROM payments WHERE customer_id = p_customer_id),
            'rate_count', (SELECT COUNT(*) FROM item_storage_prices WHERE customer_id = p_customer_id),
            'assignment_count', (SELECT COUNT(*) FROM users_customers_new WHERE customer_id = p_customer_id AND active)
        ) INTO v_rel;
        IF EXISTS (SELECT 1 FROM jsonb_each_text(v_rel) WHERE value::bigint > 0) THEN
            IF NOT p_permanent THEN
                UPDATE customers SET active = FALSE, updated_at = NOW(), updated_by = v_user_profile_id
                WHERE id = p_customer_id;
                RETURN jsonb_build_object(
                    'success', TRUE,
                    'message', format('"%s" has records, so it was deactivated instead of deleted.', v_customer_name),
                    'delete_type', 'deactivated',
                    'related_records', v_rel
                );
            END IF;
            RETURN jsonb_build_object(
                'success', FALSE,
                'message', format('Cannot delete "%s": it has GRNs, dispatches, invoices, payments, rates, linked users or orders. Deactivate it instead.', v_customer_name),
                'related_records', v_rel
            );
        END IF;
        IF p_permanent THEN
            -- Only empty OPEN carts and switched-off assignments are left: they go with a permanent delete.
            DELETE FROM orders WHERE customer_id = p_customer_id AND status = 'OPEN';
            DELETE FROM users_customers_new WHERE customer_id = p_customer_id;
        END IF;
    END;

    -- Check for active stock (items with stock > 0)$r$);

  -- 4a. restore_customer (the released app's Activate) takes a deactivated business too.
  PERFORM pg_temp.patch_rpc('public.restore_customer(uuid)',
  $m$AND deleted_at IS NOT NULL;$m$,
  $r$AND (deleted_at IS NOT NULL OR active = FALSE);$r$);

  -- 4b. No new document for a DELETED business.
  PERFORM pg_temp.patch_rpc('public.save_grn(varchar,timestamptz,uuid,varchar,uuid,varchar,uuid,varchar,varchar,varchar,boolean,varchar,jsonb,jsonb,text,varchar)',
  $m$PERFORM warehouse_security.require_person_supervisor(p_supervisor_id::text);$m$,
  $r$PERFORM warehouse_security.require_person_supervisor(p_supervisor_id::text);

      IF EXISTS (SELECT 1 FROM customers WHERE id = p_customer_id AND deleted_at IS NOT NULL) THEN
          RAISE EXCEPTION 'Business is not active' USING ERRCODE = 'P0001';
      END IF;$r$);
  PERFORM pg_temp.patch_rpc('public.update_grn(uuid,varchar,timestamptz,uuid,varchar,uuid,varchar,uuid,varchar,varchar,varchar,boolean,varchar,jsonb,jsonb,varchar,text)',
  $m$            WHERE id = p_grn_id AND customer_id IS DISTINCT FROM p_customer_id
        ) THEN
$m$,
  $r$            WHERE id = p_grn_id AND customer_id IS DISTINCT FROM p_customer_id
        ) THEN
            IF EXISTS (SELECT 1 FROM customers WHERE id = p_customer_id AND deleted_at IS NOT NULL) THEN
                RAISE EXCEPTION 'Business is not active' USING ERRCODE = 'P0001';
            END IF;
$r$);
  PERFORM pg_temp.patch_rpc('public.create_dispatch_with_stock_check(jsonb,jsonb[],integer,text)',
  $m$  PERFORM warehouse_security.require_person_supervisor(p_dispatch_data->>'supervisor_id');
$m$,
  $r$  PERFORM warehouse_security.require_person_supervisor(p_dispatch_data->>'supervisor_id');
  IF EXISTS (SELECT 1 FROM customers WHERE id::text = p_dispatch_data->>'customer_id' AND deleted_at IS NOT NULL) THEN
    RAISE EXCEPTION 'Business is not active' USING ERRCODE = 'P0001';
  END IF;
$r$);
  PERFORM pg_temp.patch_rpc('public.create_dispatch_with_stock_check(jsonb,jsonb[],boolean,integer,text)',
  $m$  PERFORM warehouse_security.require_person_supervisor(p_dispatch_data->>'supervisor_id');
$m$,
  $r$  PERFORM warehouse_security.require_person_supervisor(p_dispatch_data->>'supervisor_id');
  IF EXISTS (SELECT 1 FROM customers WHERE id::text = p_dispatch_data->>'customer_id' AND deleted_at IS NOT NULL) THEN
    RAISE EXCEPTION 'Business is not active' USING ERRCODE = 'P0001';
  END IF;
$r$);

  -- 4c. Five readers no longer hide a deactivated business.
  PERFORM pg_temp.patch_rpc('public.get_invoices_list(integer,integer,uuid,integer,text,text,text,text,integer,integer,text,timestamptz,timestamptz,uuid[])',
  $m$SELECT ARRAY(SELECT id FROM customers WHERE active = true) INTO v_accessible_customers;$m$,
  $r$SELECT ARRAY(SELECT id FROM customers WHERE deleted_at IS NULL) INTO v_accessible_customers;$r$);
  PERFORM pg_temp.patch_rpc('public.get_all_stock_summary()',
  $m$WHERE c.active = true
$m$,
  $r$WHERE c.deleted_at IS NULL
$r$);
  PERFORM pg_temp.patch_rpc('public.get_item_wise_stock_list(uuid,text,integer,integer,text,text)',
  $m$FROM customers WHERE active = true AND deleted_at IS NULL;$m$,
  $r$FROM customers WHERE deleted_at IS NULL;$r$);
  PERFORM pg_temp.patch_rpc('public.get_item_dispatch_records(uuid,jsonb,text,text,integer,integer,boolean)',
  $m$SELECT id FROM customers WHERE active = true);$m$,
  $r$SELECT id FROM customers WHERE deleted_at IS NULL);$r$);
  PERFORM pg_temp.patch_rpc('public.get_all_customer_activity_summary(date,date)',
  $m$        WHERE c.deleted_at IS NULL
            AND c.active = true
$m$,
  $r$        WHERE c.deleted_at IS NULL
$r$);

  -- 2. The business's active flag in each order row.
  -- 2b. Orders of a DELETED business are not listed for anyone (the count and the page).
  PERFORM pg_temp.patch_rpc('public.get_orders_list(uuid,text,boolean,uuid,integer,integer,text)',
  $m$m.customer_id = ANY(v_accessible_customers)$m$,
  $r$m.customer_id = ANY(v_accessible_customers)
      AND NOT EXISTS (SELECT 1 FROM customers dc WHERE dc.id = m.customer_id AND dc.deleted_at IS NOT NULL)$r$, 2);
  PERFORM pg_temp.patch_rpc('public.get_orders_list(uuid,text,boolean,uuid,integer,integer,text)',
  $m$'name', m.customer_name_detail,$m$,
  $r$'name', m.customer_name_detail,
                'active', (SELECT c.active FROM customers c WHERE c.id = m.customer_id),$r$);
END $patch$;

-- 3. Switching a business off or on. Not stock-checked, never marks it deleted.
CREATE FUNCTION public.set_customer_active(p_customer_id uuid, p_active boolean) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'pg_catalog', 'public', 'extensions', 'utils', 'pg_temp' AS $function$
DECLARE
  v_customer public.customers;
  v_profile_id uuid;
BEGIN
  PERFORM warehouse_security.authorize_rpc('set_customer_active', jsonb_build_object());
  -- The list-refresh lock comes before any row lock (migration 46).
  PERFORM pg_advisory_xact_lock(71040);
  IF p_customer_id IS NULL OR p_active IS NULL THEN
    RETURN jsonb_build_object('success', false, 'message', 'Customer and active flag are required');
  END IF;
  SELECT * INTO v_customer FROM public.customers WHERE id = p_customer_id FOR UPDATE;
  IF v_customer.id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'message', 'Customer not found');
  END IF;
  IF v_customer.active = p_active AND (NOT p_active OR v_customer.deleted_at IS NULL) THEN
    RETURN jsonb_build_object('success', true,
      'message', format('Customer "%s" is already %s', v_customer.name, CASE WHEN p_active THEN 'active' ELSE 'inactive' END),
      'data', jsonb_build_object('id', v_customer.id, 'active', v_customer.active));
  END IF;
  SELECT id INTO v_profile_id FROM public.user_profiles WHERE auth_user_id = auth.uid();
  IF p_active THEN
    UPDATE public.customers SET active = true, deleted_at = NULL, deleted_by = NULL, updated_at = now(), updated_by = v_profile_id
      WHERE id = p_customer_id;
  ELSE
    UPDATE public.customers SET active = false, updated_at = now(), updated_by = v_profile_id WHERE id = p_customer_id;
  END IF;
  RETURN jsonb_build_object('success', true,
    'message', format('Customer "%s" %s', v_customer.name, CASE WHEN p_active THEN 'activated' ELSE 'deactivated' END),
    'data', jsonb_build_object('id', p_customer_id, 'active', p_active));
END;
$function$;
REVOKE ALL ON FUNCTION public.set_customer_active(uuid, boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.set_customer_active(uuid, boolean) TO authenticated, service_role;

-- 5. Data fix: a soft-deleted business with data becomes "deactivated" (deleted_at cleared, active stays false).
DO $fix$
DECLARE v_count integer;
BEGIN
  UPDATE public.customers c SET deleted_at = NULL, deleted_by = NULL, active = false
  WHERE c.deleted_at IS NOT NULL
    AND (EXISTS (SELECT 1 FROM public.goodsreceived WHERE customer_id = c.id)
      OR EXISTS (SELECT 1 FROM public.dispatch WHERE customer_id = c.id)
      OR EXISTS (SELECT 1 FROM public.invoice WHERE customer_id = c.id)
      OR EXISTS (SELECT 1 FROM public.payments WHERE customer_id = c.id)
      OR EXISTS (SELECT 1 FROM public.item_storage_prices WHERE customer_id = c.id)
      OR EXISTS (SELECT 1 FROM public.users_customers_new WHERE customer_id = c.id AND active)
      OR EXISTS (SELECT 1 FROM public.orders o WHERE o.customer_id = c.id
                 AND (o.status <> 'OPEN' OR EXISTS (SELECT 1 FROM public.order_items oi WHERE oi.order_id = o.id))));
  GET DIAGNOSTICS v_count = ROW_COUNT;
  RAISE NOTICE 'Migration 82: % soft-deleted business(es) with data are now deactivated instead of deleted', v_count;
END $fix$;

DROP FUNCTION pg_temp.patch_rpc(regprocedure, text, text, integer);
NOTIFY pgrst, 'reload schema';
