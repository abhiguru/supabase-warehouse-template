-- Migration 87: fixes from the outside backend review of 2026-10-15 (findings in this order).
--
-- 1. BR-01  update_user_role and update_user_status take the user lock (advisory 71043) after the
--           caller check and read the target row FOR UPDATE, so a supervisor cannot act on a user
--           that an administrator promoted in a concurrent transaction.
-- 2. BR-07  create_dispatch_with_stock_check_internal takes the document lock (71040) before the
--           idempotency lookup, so an overlapping retry waits and then answers from the cache.
-- 3. BR-06  A dispatch created from a cart belongs to the cart's customer: create refuses another
--           customer's cart ('The order belongs to another customer', WH409), update_dispatch_smart
--           refuses moving a cart-sourced dispatch to another customer, get_cart_dispatches lists
--           only the cart customer's dispatches.
-- 4. BR-03  The same lot twice in the dispatch lines is refused in create and in update_dispatch_smart.
-- 5. BR-02  The cart line is read FOR UPDATE when a dispatch consumes it (both cart reads).
-- 6. BR-04  The item rate writers take the per-scope advisory lock of replace_item_rates before their
--           first read of the scope; find_storage_price gets a final tie-break on the row id.
-- 7. BR-08  Weight totals are summed as numeric (get_grn_list, get_customer_dispatch_items).
-- 8. cancel_grn_image_upload and cancel_dispatch_image_upload answer ALREADY_CONFIRMED for a
--    confirmed upload instead of NOT_FOUND, and change nothing.

-- Replaces one marker in a function body, failing unless it occurs exactly
-- `expected` times. Dropped at the end of this migration. A second direct run of the
-- file fails at the first patch; the ledger skips an applied file, so it never runs twice.
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
-- 1. BR-01: role and status changes lock the target
-- ---------------------------------------------------------------------------
DO $patch$
BEGIN
  PERFORM pg_temp.patch_rpc('public.update_user_role(uuid,public.user_role)',
  $m$    -- Validate user_id
    IF p_user_id IS NULL THEN$m$,
  $r$    -- One user change at a time, and the target row is read under lock: a role another
    -- transaction committed is seen (migration 87). A refused caller never reaches the lock.
    PERFORM pg_advisory_xact_lock(71043);

    -- Validate user_id
    IF p_user_id IS NULL THEN$r$);
  PERFORM pg_temp.patch_rpc('public.update_user_role(uuid,public.user_role)',
  $m$    SELECT id, role INTO v_target_id, v_old_role
    FROM user_profiles
    WHERE id = p_user_id;$m$,
  $r$    SELECT id, role INTO v_target_id, v_old_role
    FROM user_profiles
    WHERE id = p_user_id
    FOR UPDATE;$r$);

  PERFORM pg_temp.patch_rpc('public.update_user_status(uuid,boolean)',
  $m$    -- Validate user_id
    IF p_user_id IS NULL THEN$m$,
  $r$    -- One user change at a time, and the target row is read under lock: a role another
    -- transaction committed is seen (migration 87). A refused caller never reaches the lock.
    PERFORM pg_advisory_xact_lock(71043);

    -- Validate user_id
    IF p_user_id IS NULL THEN$r$);
  PERFORM pg_temp.patch_rpc('public.update_user_status(uuid,boolean)',
  $m$    SELECT id, role, active INTO v_target_id, v_target_role, v_old_active
    FROM user_profiles
    WHERE id = p_user_id;$m$,
  $r$    SELECT id, role, active INTO v_target_id, v_target_role, v_old_active
    FROM user_profiles
    WHERE id = p_user_id
    FOR UPDATE;$r$);
END $patch$;

-- ---------------------------------------------------------------------------
-- 2. BR-07: the document lock before the idempotency lookup
-- ---------------------------------------------------------------------------
DO $patch$
BEGIN
  PERFORM pg_temp.patch_rpc('public.create_dispatch_with_stock_check_internal(jsonb,jsonb[],boolean,text)',
  $m$    -- Check idempotency key first
$m$,
  $r$    -- The document lock comes before the idempotency lookup, as in save_grn (migration 87):
    -- an overlapping retry waits here and then finds the first call's cached answer.
    PERFORM pg_advisory_xact_lock(71040);

    -- Check idempotency key first
$r$);
  PERFORM pg_temp.patch_rpc('public.create_dispatch_with_stock_check_internal(jsonb,jsonb[],boolean,text)',
  $m$    -- The list-refresh lock comes before any row lock (migration 46).
    PERFORM pg_advisory_xact_lock(71040);

$m$,
  $r$$r$);
END $patch$;

-- ---------------------------------------------------------------------------
-- 3. BR-06: a cart-sourced dispatch belongs to the cart's customer
-- ---------------------------------------------------------------------------
DO $patch$
BEGIN
  PERFORM pg_temp.patch_rpc('public.create_dispatch_with_stock_check_internal(jsonb,jsonb[],boolean,text)',
  $m$    v_cached_response jsonb;
BEGIN
$m$,
  $r$    v_cached_response jsonb;
    v_order_customer_id uuid;
BEGIN
$r$);
  PERFORM pg_temp.patch_rpc('public.create_dispatch_with_stock_check_internal(jsonb,jsonb[],boolean,text)',
  $m$    IF v_source_order_id IS NOT NULL THEN
        v_source_order_no := COALESCE($m$,
  $r$    IF v_source_order_id IS NOT NULL THEN
        -- The cart must be the dispatch customer's (a plain read: the cart writers lock the cart first).
        SELECT customer_id INTO v_order_customer_id
        FROM orders
        WHERE id = v_source_order_id AND deleted_at IS NULL;
        IF v_order_customer_id IS NULL
           OR v_order_customer_id IS DISTINCT FROM (p_dispatch_data->>'customer_id')::uuid THEN
            RAISE EXCEPTION 'The order belongs to another customer' USING ERRCODE = 'WH409';
        END IF;

        v_source_order_no := COALESCE($r$);

  PERFORM pg_temp.patch_rpc('public.update_dispatch_smart(uuid,jsonb,jsonb[])',
  $m$    -- Update dispatch header if data provided (single statement - OK)
$m$,
  $r$    -- A dispatch made from a cart stays with the cart's customer (migration 87).
    IF EXISTS (
        SELECT 1 FROM dispatch d
        WHERE d.id = p_dispatch_id
        AND d.source_order_id IS NOT NULL
        AND COALESCE((p_dispatch_data->>'customer_id')::uuid, d.customer_id) IS DISTINCT FROM d.customer_id
        AND COALESCE((p_dispatch_data->>'customer_id')::uuid, d.customer_id)
            IS DISTINCT FROM (SELECT o.customer_id FROM orders o WHERE o.id = d.source_order_id)
    ) THEN
        RAISE EXCEPTION 'The order belongs to another customer' USING ERRCODE = 'WH409';
    END IF;

    -- Update dispatch header if data provided (single statement - OK)
$r$);

  PERFORM pg_temp.patch_rpc('public.get_cart_dispatches(uuid)',
  $m$        WHERE d.source_order_id = p_cart_id
$m$,
  $r$        WHERE d.source_order_id = p_cart_id
          AND d.customer_id = (SELECT o.customer_id FROM orders o WHERE o.id = p_cart_id)
$r$);
END $patch$;

-- ---------------------------------------------------------------------------
-- 4. BR-03: one lot once per dispatch
-- ---------------------------------------------------------------------------
DO $patch$
BEGIN
  PERFORM pg_temp.patch_rpc('public.update_dispatch_smart(uuid,jsonb,jsonb[])',
  $m$    -- A dispatch carries only its own customer's lots: a line this edit adds$m$,
  $r$    -- A lot appears once in the dispatch lines (migration 87).
    IF EXISTS (
        SELECT 1 FROM unnest(p_dispatch_items) AS d
        GROUP BY (d->>'gr_trl_id') HAVING count(*) > 1
    ) THEN
        RAISE EXCEPTION 'The same lot appears twice in the dispatch lines' USING ERRCODE = 'WH409';
    END IF;

    -- A dispatch carries only its own customer's lots: a line this edit adds$r$);
  PERFORM pg_temp.patch_rpc('public.create_dispatch_with_stock_check_internal(jsonb,jsonb[],boolean,text)',
  $m$    -- STEP 1: Lock all relevant GRN items first (no aggregation)$m$,
  $r$    -- A lot appears once in the dispatch lines (migration 87).
    IF EXISTS (
        SELECT 1 FROM unnest(p_dispatch_items) AS d
        GROUP BY (d->>'gr_trl_id') HAVING count(*) > 1
    ) THEN
        RAISE EXCEPTION 'The same lot appears twice in the dispatch lines' USING ERRCODE = 'WH409';
    END IF;

    -- STEP 1: Lock all relevant GRN items first (no aggregation)$r$);
END $patch$;

-- ---------------------------------------------------------------------------
-- 5. BR-02: the cart line is locked when a dispatch consumes it
-- ---------------------------------------------------------------------------
DO $patch$
BEGIN
  PERFORM pg_temp.patch_rpc('public.create_dispatch_with_stock_check_internal(jsonb,jsonb[],boolean,text)',
  $m$            WHERE order_id = v_source_order_id AND grn_items_id = v_gr_trl_id
            LIMIT 1;
$m$,
  $r$            WHERE order_id = v_source_order_id AND grn_items_id = v_gr_trl_id
            LIMIT 1
            FOR UPDATE;
$r$);
  PERFORM pg_temp.patch_rpc('public.create_dispatch_with_stock_check_internal(jsonb,jsonb[],boolean,text)',
  $m$                    WHERE order_id = v_cart_id AND grn_items_id = v_gr_trl_id
                    LIMIT 1;
$m$,
  $r$                    WHERE order_id = v_cart_id AND grn_items_id = v_gr_trl_id
                    LIMIT 1
                    FOR UPDATE;
$r$);
END $patch$;

-- ---------------------------------------------------------------------------
-- 6. BR-04: one rate writer per scope at a time
-- ---------------------------------------------------------------------------
DO $patch$
BEGIN
  -- create (with price type)
  PERFORM pg_temp.patch_rpc('public.create_item_storage_price(uuid,text,numeric,numeric,numeric,numeric,date,uuid,numeric,date)',
  $m$    -- No other row of this item, customer and price type may share a weight and a day (migration 76).
$m$,
  $r$    -- One change of this scope at a time, as in replace_item_rates (migration 87).
    PERFORM pg_advisory_xact_lock(hashtextextended('item_rates:' || p_item_id || ':' || COALESCE(p_customer_id::text, 'default') || ':' || p_price_type, 0));

    -- No other row of this item, customer and price type may share a weight and a day (migration 76).
$r$);

  -- update (price type kept): lock, then read the row under lock
  PERFORM pg_temp.patch_rpc('public.update_item_storage_price(uuid,numeric,numeric,numeric,numeric,numeric,date,date)',
  $m$    -- A rate that is already in force is changed by administrators and supervisors (migration 76).
$m$,
  $r$    -- One change of this scope at a time, as in replace_item_rates; the row is read again under lock (migration 87).
    PERFORM pg_advisory_xact_lock(hashtextextended('item_rates:' || v_existing.item_id || ':' || COALESCE(v_existing.customer_id::text, 'default') || ':' || v_existing.price_type, 0));
    SELECT id, price_type, item_id, customer_id, effective_from INTO v_existing FROM item_storage_prices WHERE id = p_id FOR UPDATE;
    IF v_existing.id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'Price record not found');
    END IF;

    -- A rate that is already in force is changed by administrators and supervisors (migration 76).
$r$);

  -- update (legacy, two prices)
  PERFORM pg_temp.patch_rpc('public.update_item_storage_price(uuid,numeric,numeric,numeric,numeric,numeric,numeric,date,date)',
  $m$    -- A rate that is already in force is changed by administrators and supervisors (migration 76).
$m$,
  $r$    -- One change of this scope at a time, as in replace_item_rates; the row is read again under lock (migration 87).
    PERFORM pg_advisory_xact_lock(hashtextextended('item_rates:' || v_existing.item_id || ':' || COALESCE(v_existing.customer_id::text, 'default') || ':' || v_existing.price_type, 0));
    SELECT * INTO v_existing FROM item_storage_prices WHERE id = p_id FOR UPDATE;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'error', 'Price record not found');
    END IF;

    -- A rate that is already in force is changed by administrators and supervisors (migration 76).
$r$);

  -- find or create
  PERFORM pg_temp.patch_rpc('public.find_or_create_item_storage_price(uuid,uuid,numeric,text,numeric,numeric,numeric,numeric,numeric)',
  $m$    -- Try to find existing pricing
$m$,
  $r$    -- One change of this scope at a time, as in replace_item_rates (migration 87).
    PERFORM pg_advisory_xact_lock(hashtextextended('item_rates:' || p_item_id || ':' || COALESCE(p_customer_id::text, 'default') || ':' || lower(p_price_type), 0));

    -- Try to find existing pricing
$r$);

  -- delete: the row names the scope
  PERFORM pg_temp.patch_rpc('public.delete_item_storage_price(uuid)',
  $m$    SELECT isp.id, isp.effective_from, i.name as item_name, c.name as customer_name
    INTO v_existing$m$,
  $r$    SELECT isp.id, isp.effective_from, isp.item_id, isp.customer_id, isp.price_type,
           i.name as item_name, c.name as customer_name
    INTO v_existing$r$);
  PERFORM pg_temp.patch_rpc('public.delete_item_storage_price(uuid)',
  $m$    -- A rate that is already in force is removed by administrators and supervisors (migration 76).
$m$,
  $r$    -- One change of this scope at a time, as in replace_item_rates; the row is locked before it is removed (migration 87).
    PERFORM pg_advisory_xact_lock(hashtextextended('item_rates:' || v_existing.item_id || ':' || COALESCE(v_existing.customer_id::text, 'default') || ':' || v_existing.price_type, 0));
    PERFORM 1 FROM item_storage_prices WHERE id = p_id FOR UPDATE;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'error', 'Price record not found');
    END IF;

    -- A rate that is already in force is removed by administrators and supervisors (migration 76).
$r$);

  -- find_storage_price: a final tie-break
  PERFORM pg_temp.patch_rpc('public.find_storage_price(uuid,uuid,integer,date,text)',
  $m$        isp.effective_from DESC               -- 3. Most recent effective date first
$m$,
  $r$        isp.effective_from DESC,              -- 3. Most recent effective date first
        isp.id ASC                            -- 4. Same figures: the row that was entered first (migration 87)
$r$);
END $patch$;

-- ---------------------------------------------------------------------------
-- 7. BR-08: weight totals as numeric
-- ---------------------------------------------------------------------------
DO $patch$
BEGIN
  PERFORM pg_temp.patch_rpc('public.get_grn_list(date,date,text,text,integer,integer,jsonb)',
  $m$SUM(trl.weight * trl.stock)$m$,
  $r$SUM(trl.weight::numeric * trl.stock)$r$);
  PERFORM pg_temp.patch_rpc('public.get_customer_dispatch_items(uuid,timestamptz,timestamptz,jsonb,text,text,integer,integer)',
  $m$SUM(grt.weight * dt.disp_qty)$m$,
  $r$SUM(grt.weight::numeric * dt.disp_qty)$r$);
END $patch$;

-- ---------------------------------------------------------------------------
-- 8. A confirmed upload cannot be cancelled: say so
-- ---------------------------------------------------------------------------
DO $patch$
BEGIN
  PERFORM pg_temp.patch_rpc('public.cancel_grn_image_upload(uuid)',
  $m$    IF v_storage_path IS NULL THEN
$m$,
  $r$    IF v_storage_path IS NULL THEN
        -- A confirmed upload stays; the caller must keep its file (migration 87).
        SELECT storage_path INTO v_storage_path
        FROM grn_images
        WHERE id = p_image_id
        AND status = 'confirmed'
        AND (uploaded_by = public.get_current_user_profile_id()
             OR warehouse_security.active_role() IN ('admin','supervisor'));
        IF FOUND THEN
            RETURN jsonb_build_object(
                'success', false,
                'code', 'ALREADY_CONFIRMED',
                'error', 'Upload already confirmed',
                'image_id', p_image_id,
                'storage_path', v_storage_path
            );
        END IF;

$r$);
  PERFORM pg_temp.patch_rpc('public.cancel_dispatch_image_upload(uuid)',
  $m$    IF v_storage_path IS NULL THEN
$m$,
  $r$    IF v_storage_path IS NULL THEN
        -- A confirmed upload stays; the caller must keep its file (migration 87).
        SELECT storage_path INTO v_storage_path
        FROM dispatch_images
        WHERE id = p_image_id
        AND status = 'confirmed'
        AND (uploaded_by = public.get_current_user_profile_id()
             OR warehouse_security.active_role() IN ('admin','supervisor'));
        IF FOUND THEN
            RETURN jsonb_build_object(
                'success', false,
                'code', 'ALREADY_CONFIRMED',
                'error', 'Upload already confirmed',
                'image_id', p_image_id,
                'storage_path', v_storage_path
            );
        END IF;

$r$);
END $patch$;

DROP FUNCTION pg_temp.patch_rpc(regprocedure, text, text, integer);

-- ---------------------------------------------------------------------------
-- 9. Closing checks: every patch is in the stored function
-- ---------------------------------------------------------------------------
DO $check$
DECLARE
  d text;
  lock_key text := 'item_rates:';
BEGIN
  FOR d IN SELECT pg_get_functiondef(f) FROM unnest(ARRAY[
      'public.update_user_role(uuid,public.user_role)'::regprocedure,
      'public.update_user_status(uuid,boolean)'::regprocedure]) f LOOP
    IF position('pg_advisory_xact_lock(71043)' IN d) = 0 OR position('FOR UPDATE;' IN d) = 0 THEN
      RAISE EXCEPTION 'Migration 87: a user change function lacks the user lock or the target row lock';
    END IF;
  END LOOP;

  d := pg_get_functiondef('public.create_dispatch_with_stock_check_internal(jsonb,jsonb[],boolean,text)'::regprocedure);
  IF (length(d) - length(replace(d, 'pg_advisory_xact_lock(71040)', ''))) / length('pg_advisory_xact_lock(71040)') <> 1
     OR position('pg_advisory_xact_lock(71040)' IN d) > position('Check idempotency key first' IN d) THEN
    RAISE EXCEPTION 'Migration 87: create_dispatch must take lock 71040 exactly once, before the idempotency lookup';
  END IF;
  IF position('The order belongs to another customer' IN d) = 0
     OR position('The same lot appears twice in the dispatch lines' IN d) = 0
     OR (length(d) - length(replace(d, 'FOR UPDATE;', ''))) / length('FOR UPDATE;') <> 2 THEN
    RAISE EXCEPTION 'Migration 87: create_dispatch lacks the cart owner check, the duplicate lot check or the cart line locks';
  END IF;

  d := pg_get_functiondef('public.update_dispatch_smart(uuid,jsonb,jsonb[])'::regprocedure);
  IF position('The order belongs to another customer' IN d) = 0
     OR position('The same lot appears twice in the dispatch lines' IN d) = 0 THEN
    RAISE EXCEPTION 'Migration 87: update_dispatch_smart lacks the cart owner check or the duplicate lot check';
  END IF;

  IF position('d.customer_id = (SELECT o.customer_id FROM orders o WHERE o.id = p_cart_id)'
      IN pg_get_functiondef('public.get_cart_dispatches(uuid)'::regprocedure)) = 0 THEN
    RAISE EXCEPTION 'Migration 87: get_cart_dispatches does not filter by the cart customer';
  END IF;

  FOR d IN SELECT pg_get_functiondef(f) FROM unnest(ARRAY[
      'public.create_item_storage_price(uuid,text,numeric,numeric,numeric,numeric,date,uuid,numeric,date)'::regprocedure,
      'public.update_item_storage_price(uuid,numeric,numeric,numeric,numeric,numeric,date,date)'::regprocedure,
      'public.update_item_storage_price(uuid,numeric,numeric,numeric,numeric,numeric,numeric,date,date)'::regprocedure,
      'public.find_or_create_item_storage_price(uuid,uuid,numeric,text,numeric,numeric,numeric,numeric,numeric)'::regprocedure,
      'public.delete_item_storage_price(uuid)'::regprocedure]) f LOOP
    IF position(lock_key IN d) = 0 OR position('pg_advisory_xact_lock(hashtextextended(' IN d) = 0 THEN
      RAISE EXCEPTION 'Migration 87: a rate writer lacks the scope lock';
    END IF;
  END LOOP;
  IF position('isp.id ASC' IN pg_get_functiondef('public.find_storage_price(uuid,uuid,integer,date,text)'::regprocedure)) = 0 THEN
    RAISE EXCEPTION 'Migration 87: find_storage_price lacks the final tie-break';
  END IF;

  IF position('SUM(trl.weight::numeric * trl.stock)' IN pg_get_functiondef('public.get_grn_list(date,date,text,text,integer,integer,jsonb)'::regprocedure)) = 0
     OR position('SUM(grt.weight::numeric * dt.disp_qty)' IN pg_get_functiondef('public.get_customer_dispatch_items(uuid,timestamptz,timestamptz,jsonb,text,text,integer,integer)'::regprocedure)) = 0 THEN
    RAISE EXCEPTION 'Migration 87: a weight total is still summed as an integer product';
  END IF;

  FOR d IN SELECT pg_get_functiondef(f) FROM unnest(ARRAY[
      'public.cancel_grn_image_upload(uuid)'::regprocedure,
      'public.cancel_dispatch_image_upload(uuid)'::regprocedure]) f LOOP
    IF position('ALREADY_CONFIRMED' IN d) = 0 THEN
      RAISE EXCEPTION 'Migration 87: a cancel function lacks ALREADY_CONFIRMED';
    END IF;
  END LOOP;
END $check$;

NOTIFY pgrst, 'reload schema';
