-- public.create_dispatch_with_stock_check_internal: the definition setup applies after the numbered migrations whenever this file's checksum changes
-- (scripts/migration-plan.mjs, table warehouse_migrations.definitions). Edit the function here, never in a new migration.
-- Starts as the function migrations 000 to 126 leave (the numbered files that patched it stay as they are, never edited).
CREATE OR REPLACE FUNCTION public.create_dispatch_with_stock_check_internal(p_dispatch_data jsonb, p_dispatch_items jsonb[], p_generate_invoice boolean DEFAULT false, p_idempotency_key text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'extensions', 'utils', 'pg_temp'
AS $function$
DECLARE
    v_dispatch_id uuid;
    v_user_id uuid;
    v_affected_gr_ids uuid[];
    v_all_gr_ids uuid[];
    v_insufficient_stock text;
    v_foreign_lots text;
    v_dispatch_items_result jsonb[];
    v_invoice_data jsonb;
    v_gr_id uuid;
    v_grn_customer_id uuid;
    v_is_invoiceable boolean;
    v_single_invoice_data jsonb;
    v_source_order_id uuid;
    v_source_order_no text;  -- Added for auto-lookup
    v_item jsonb;
    v_gr_trl_id uuid;
    v_dispatched_qty integer;
    v_cart_id uuid;
    v_cart_item_id uuid;
    v_cart_current_qty integer;
    v_cart_fulfilled_qty integer;
    v_cart_new_qty integer;
    v_cached_response jsonb;
    v_order_customer_id uuid;
    v_locked_lots integer;
    v_deleted_lots text;
    v_customer_name text;
    v_supervisor_name text;
    v_order_lines_left integer;
    v_order_lines_changed boolean;
    v_order_updated_at timestamptz;
    v_expected_order_at timestamptz;
    v_disp_day date;
    v_today date;
    v_late_gr_no text;
    v_late_grn_day date;
    v_duplicate jsonb;
    v_detail text;
    v_number_failure jsonb;
BEGIN
    -- The document lock comes before the idempotency lookup, as in save_grn (migration 87):
    -- an overlapping retry waits here and then finds the first call's cached answer.
    PERFORM pg_advisory_xact_lock(71040);

    -- Check idempotency key first
    IF p_idempotency_key IS NOT NULL THEN
        SELECT response INTO v_cached_response
        FROM idempotency_keys
        WHERE idempotency_key = p_idempotency_key
          AND rpc_function = 'create_dispatch_with_stock_check'
          AND created_by = (SELECT id FROM user_profiles WHERE auth_user_id = auth.uid())
          AND expires_at > NOW();

        -- The answer is replayed only while the dispatch it created still exists. The answer of a deleted
        -- dispatch is dropped (migration 120) and the call goes on as a new create: the same body can be
        -- entered again once its number is free again.
        IF v_cached_response IS NOT NULL THEN
            IF EXISTS (
                SELECT 1 FROM dispatch d
                WHERE d.id = (v_cached_response->>'dispatch_id')::uuid AND d.deleted_at IS NULL
            ) THEN
                RETURN v_cached_response || jsonb_build_object('from_cache', true);
            END IF;
            DELETE FROM idempotency_keys
            WHERE idempotency_key = p_idempotency_key
              AND rpc_function = 'create_dispatch_with_stock_check'
              AND created_by = (SELECT id FROM user_profiles WHERE auth_user_id = auth.uid());
            v_cached_response := NULL;
        END IF;
    END IF;

    -- Check if user is admin or supervisor
    IF NOT warehouse_security.active_role() IN ('admin','supervisor','staff') THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'Only administrators and supervisors can create dispatches'
        );
    END IF;

    -- Get current user
    SELECT id INTO v_user_id FROM user_profiles WHERE auth_user_id = auth.uid();

    -- Extract source_order_id if provided
    v_source_order_id := (p_dispatch_data->>'source_order_id')::uuid;

    -- Auto-lookup source_order_no from orders table if not provided
    IF v_source_order_id IS NOT NULL THEN
        -- The cart must be the dispatch customer's (a plain read: the cart writers lock the cart first).
        SELECT customer_id, updated_at INTO v_order_customer_id, v_order_updated_at
        FROM orders
        WHERE id = v_source_order_id AND deleted_at IS NULL;
        IF v_order_customer_id IS NULL
           OR v_order_customer_id IS DISTINCT FROM (p_dispatch_data->>'customer_id')::uuid THEN
            RAISE EXCEPTION 'The order belongs to another customer' USING ERRCODE = 'WH409';
        END IF;

        -- D5 (migration 121): the form was made from the order as it was at source_order_updated_at (the order's updated_at
        -- when the form was opened). An order whose LINES changed since (a line added, changed, removed, or taken by another
        -- dispatch) is not dispatched from a stale form; a changed note, priority or requested date is not a reason. The
        -- lines are told apart from the order's own fields by their own updated_at (greater than the value sent), and a
        -- removed line by its change-log entry, written more than 2 seconds after the sent value (an entry is written a few
        -- milliseconds after the updated_at it goes with). The order is read without a lock. No key (an older app, a direct
        -- dispatch): no check. A retry of this user's own committed create was answered from the saved answer above, so it
        -- is not refused for what its first try changed. The app sends the same value as before (the order's updated_at).
        IF NULLIF(p_dispatch_data->>'source_order_updated_at', '') IS NOT NULL THEN
            v_expected_order_at := (p_dispatch_data->>'source_order_updated_at')::timestamptz;
            v_order_lines_changed :=
                EXISTS (SELECT 1 FROM order_items oi
                        WHERE oi.order_id = v_source_order_id
                          AND date_trunc('milliseconds', oi.updated_at) > date_trunc('milliseconds', v_expected_order_at))
                OR EXISTS (SELECT 1 FROM order_revisions r
                           WHERE r.order_id = v_source_order_id
                             AND r.changed_at > v_expected_order_at + interval '2 seconds'
                             AND (r.action IN ('auto_quantity_reduction', 'dispatch_deleted')
                                  OR r.entry->'changes'->'removed_item' IS NOT NULL));
            IF v_order_lines_changed THEN
                RETURN warehouse_security.refuse('ORDER_CHANGED', 'This order changed after you opened it.',
                    jsonb_build_object('source_order_id', v_source_order_id,
                                       'expected_updated_at', v_expected_order_at,
                                       'current_updated_at', v_order_updated_at));
            END IF;
        END IF;

        -- The order number is the order's own, never the client's (migration 120); a dispatch without a source
        -- order has none.
        v_source_order_no := (SELECT order_no FROM orders WHERE id = v_source_order_id);
    ELSE
        v_source_order_no := NULL;
    END IF;

    -- A lot appears once in the dispatch lines (migration 87).
    IF EXISTS (
        SELECT 1 FROM unnest(p_dispatch_items) AS d
        GROUP BY (d->>'gr_trl_id')::uuid HAVING count(*) > 1
    ) THEN
        RAISE EXCEPTION 'The same lot appears twice in the dispatch lines' USING ERRCODE = 'WH409';
    END IF;

    -- Migration 127: the number follows this facility's numbering (warehouse_security.document_numbering).
    v_number_failure := warehouse_security.document_number_failure('dispatch', p_dispatch_data->>'disp_no', warehouse_security.business_date((p_dispatch_data->>'disp_date')::timestamptz));
    IF v_number_failure IS NOT NULL THEN
        RETURN v_number_failure;
    END IF;

    -- A number another dispatch holds is refused by name, under the lock and before anything is written
    -- (migration 120). dispatch_disp_no_key covers every row, so the check does too.
    IF EXISTS (SELECT 1 FROM dispatch d WHERE d.disp_no = p_dispatch_data->>'disp_no') THEN
        RETURN jsonb_build_object(
            'success', false,
            'error_code', 'WH409',
            'reason', 'NUMBER_TAKEN',
            'number', p_dispatch_data->>'disp_no',
            'error', format('Dispatch number %s is already used', p_dispatch_data->>'disp_no')
        );
    END IF;

    -- The stored names are the master tables' names, whatever the client sent, and the supervisor is a
    -- person who may supervise (migration 120).
    IF p_dispatch_data->>'supervisor_id' IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM user_profiles p
        WHERE p.id = (p_dispatch_data->>'supervisor_id')::uuid
          AND p.role IN ('admin', 'supervisor', 'staff')
    ) THEN
        RAISE EXCEPTION 'The supervisor must be an administrator, supervisor or staff member' USING ERRCODE = 'WH409';
    END IF;
    v_customer_name := (SELECT c.name FROM customers c WHERE c.id = (p_dispatch_data->>'customer_id')::uuid);
    v_supervisor_name := (SELECT COALESCE(p.name, p.display_name) FROM user_profiles p WHERE p.id = (p_dispatch_data->>'supervisor_id')::uuid);

    -- STEP 1: Lock all relevant GRN items first (no aggregation)
    SELECT count(*) INTO v_locked_lots
    FROM (
        SELECT gt.id
        FROM unnest(p_dispatch_items) AS item
        JOIN goodsreceived_trl gt ON gt.id = (item->>'gr_trl_id')::uuid
        FOR UPDATE OF gt
    ) AS locked;

    -- A lot that was deleted after the wrapper checked the list is refused, not dropped (migration 120).
    -- A lot appears once (checked above), so the lines sent are the distinct lots sent.
    IF v_locked_lots <> cardinality(p_dispatch_items) THEN
        RAISE EXCEPTION 'A lot of this dispatch was removed meanwhile; reload and try again' USING ERRCODE = 'WH409';
    END IF;

    -- The order lines this create may change are locked next, in id order, before any dispatch or order line is written
    -- (migration 121), so a dispatch edit or delete on the same lots and lines waits instead of deadlocking.
    PERFORM oi.id
    FROM order_items oi
    WHERE oi.grn_items_id IN (SELECT (item->>'gr_trl_id')::uuid FROM unnest(p_dispatch_items) AS item)
      AND (oi.order_id = v_source_order_id
           OR EXISTS (SELECT 1 FROM orders o WHERE o.id = oi.order_id AND o.status = 'OPEN' AND o.deleted_at IS NULL))
    ORDER BY oi.id
    FOR UPDATE OF oi;

    -- A dispatch carries only its own customer's lots. The receipts are
    -- key-share locked so update_grn cannot move one to another customer meanwhile.
    PERFORM gr.id
    FROM unnest(p_dispatch_items) AS item
    JOIN goodsreceived_trl gt ON gt.id = (item->>'gr_trl_id')::uuid
    JOIN goodsreceived gr ON gr.id = gt.gr_id
    FOR KEY SHARE OF gr;

    SELECT string_agg(gt.item_name || ' (' || gr.gr_no || ')', ', ')
    INTO v_foreign_lots
    FROM unnest(p_dispatch_items) AS item
    JOIN goodsreceived_trl gt ON gt.id = (item->>'gr_trl_id')::uuid
    JOIN goodsreceived gr ON gr.id = gt.gr_id
    WHERE gr.customer_id IS DISTINCT FROM (p_dispatch_data->>'customer_id')::uuid;

    IF v_foreign_lots IS NOT NULL THEN
        RAISE EXCEPTION 'Item belongs to another customer: %', v_foreign_lots USING ERRCODE = 'WH409';
    END IF;

    -- The lots of a deleted receipt are not dispatched (migration 120).
    SELECT string_agg(gt.item_name || ' (' || gr.gr_no || ')', ', ')
    INTO v_deleted_lots
    FROM unnest(p_dispatch_items) AS item
    JOIN goodsreceived_trl gt ON gt.id = (item->>'gr_trl_id')::uuid
    JOIN goodsreceived gr ON gr.id = gt.gr_id
    WHERE gr.deleted_at IS NOT NULL;

    IF v_deleted_lots IS NOT NULL THEN
        RAISE EXCEPTION 'Item belongs to a deleted GRN: %', v_deleted_lots USING ERRCODE = 'WH409';
    END IF;

    -- D3 (migration 121, IST days): a dispatch is not dated in the future, and not before the GRN day of any of its lots.
    -- The day is the one the insert below stores (the same cast). The GRN named is the latest one among the lots.
    v_disp_day := (p_dispatch_data->>'disp_date')::date;
    IF v_disp_day IS NOT NULL THEN
        v_today := warehouse_security.business_date(now());
        IF v_disp_day > v_today THEN
            RETURN warehouse_security.refuse('DISPATCH_DATE_FUTURE',
                format('A dispatch can''t be dated in the future. Today is %s.', to_char(v_today, 'YYYY-MM-DD')),
                jsonb_build_object('date', to_char(v_disp_day, 'YYYY-MM-DD'), 'today', to_char(v_today, 'YYYY-MM-DD')));
        END IF;

        SELECT gr.gr_no, warehouse_security.business_date(gr.date)
        INTO v_late_gr_no, v_late_grn_day
        FROM unnest(p_dispatch_items) AS item
        JOIN goodsreceived_trl gt ON gt.id = (item->>'gr_trl_id')::uuid
        JOIN goodsreceived gr ON gr.id = gt.gr_id
        WHERE warehouse_security.business_date(gr.date) > v_disp_day
        ORDER BY warehouse_security.business_date(gr.date) DESC, gr.gr_no DESC
        LIMIT 1;

        IF v_late_gr_no IS NOT NULL THEN
            RETURN warehouse_security.refuse('DISPATCH_BEFORE_GRN',
                format('The dispatch date %s is before GRN %s (%s).', to_char(v_disp_day, 'YYYY-MM-DD'), v_late_gr_no,
                       to_char(v_late_grn_day, 'YYYY-MM-DD')),
                jsonb_build_object('date', to_char(v_disp_day, 'YYYY-MM-DD'), 'gr_no', v_late_gr_no,
                                   'grn_date', to_char(v_late_grn_day, 'YYYY-MM-DD')));
        END IF;
    END IF;

    -- STEP 2: Check stock availability (separate query, no FOR UPDATE)
    SELECT string_agg(
        gt.item_name || ' (Available: ' || gt.stock || ', Requested: ' || (item->>'disp_qty')::integer || ')',
        ', '
    )
    INTO v_insufficient_stock
    FROM unnest(p_dispatch_items) AS item
    JOIN goodsreceived_trl gt ON gt.id = (item->>'gr_trl_id')::uuid
    WHERE gt.stock < (item->>'disp_qty')::integer;

    IF v_insufficient_stock IS NOT NULL THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'Insufficient stock: ' || v_insufficient_stock
        );
    END IF;

    -- CREATE DISPATCH RECORD
    INSERT INTO dispatch (
        disp_no, disp_date, registration, customer_id,
        customer_name, supervisor_id, supervisor_name, note,
        created_by, source_order_id, source_order_no
    ) VALUES (
        p_dispatch_data->>'disp_no',
        (p_dispatch_data->>'disp_date')::date::timestamptz,
        p_dispatch_data->>'registration',
        (p_dispatch_data->>'customer_id')::uuid,
        v_customer_name,
        (p_dispatch_data->>'supervisor_id')::uuid,
        v_supervisor_name,
        p_dispatch_data->>'note',
        v_user_id,
        v_source_order_id,
        v_source_order_no  -- Now uses auto-looked-up value
    ) RETURNING id INTO v_dispatch_id;

    -- BULK UPDATE STOCK
    UPDATE goodsreceived_trl gt
    SET stock = gt.stock - (item->>'disp_qty')::integer
    FROM unnest(p_dispatch_items) AS item
    WHERE gt.id = (item->>'gr_trl_id')::uuid;

    -- BULK INSERT DISPATCH ITEMS
    INSERT INTO dispatch_trl (gr_id, gr_trl_id, disp_id, disp_qty)
    SELECT
        gt.gr_id,
        (item->>'gr_trl_id')::uuid,
        v_dispatch_id,
        (item->>'disp_qty')::integer
    FROM unnest(p_dispatch_items) WITH ORDINALITY AS t(item, ord)
    JOIN goodsreceived_trl gt ON gt.id = (item->>'gr_trl_id')::uuid
    ORDER BY t.ord;

    -- GET UNIQUE GR_IDS
    SELECT ARRAY(
        SELECT DISTINCT gt.gr_id
        FROM unnest(p_dispatch_items) AS item
        JOIN goodsreceived_trl gt ON gt.id = (item->>'gr_trl_id')::uuid
    ) INTO v_affected_gr_ids;

    -- BULK INSERT STOCK MOVEMENTS
    INSERT INTO stock_movements (
        gr_trl_id, movement_type, quantity,
        reference_id, reference_type,
        balance_before, balance_after, created_by
    )
    SELECT
        (item->>'gr_trl_id')::uuid,
        'dispatch',
        -(item->>'disp_qty')::integer,
        v_dispatch_id,
        'dispatch',
        gt.stock + (item->>'disp_qty')::integer,
        gt.stock,
        v_user_id
    FROM unnest(p_dispatch_items) AS item
    JOIN goodsreceived_trl gt ON gt.id = (item->>'gr_trl_id')::uuid;

    -- BULK UPDATE OUT_OF_STOCK STATUS
    UPDATE goodsreceived gr
    SET out_of_stock = NOT EXISTS (
        SELECT 1 FROM goodsreceived_trl grt
        WHERE grt.gr_id = gr.id AND grt.stock > 0
    )
    WHERE gr.id = ANY(v_affected_gr_ids)
      -- Only a GRN whose flag really changes is touched (migration 121): an unrelated dispatch does not move its version
      -- token, so an open GRN edit is not made stale by it.
      AND gr.out_of_stock IS DISTINCT FROM (NOT EXISTS (
        SELECT 1 FROM goodsreceived_trl grt
        WHERE grt.gr_id = gr.id AND grt.stock > 0
    ));

    -- BUILD DISPATCH ITEMS RESPONSE
    SELECT ARRAY(
        SELECT jsonb_build_object(
            'id', dt.id,
            'gr_id', dt.gr_id,
            'gr_trl_id', dt.gr_trl_id,
            'disp_id', dt.disp_id,
            'disp_qty', dt.disp_qty,
            'item_name', COALESCE(i.name, grt.item_name),
            'packaging', grt.packaging,
            'rack', grt.rack,
            'package_mark', grt.package_mark,
            'weight', grt.weight,
            'remaining_stock', grt.stock
        )
        FROM dispatch_trl dt
        JOIN goodsreceived_trl grt ON grt.id = dt.gr_trl_id
        LEFT JOIN items i ON i.id = grt.item_id
        WHERE dt.disp_id = v_dispatch_id
    ) INTO v_dispatch_items_result;

    -- INVOICE GENERATION (if requested)
    IF p_generate_invoice THEN
        v_invoice_data := '{}'::jsonb;
        v_all_gr_ids := v_affected_gr_ids;

        FOREACH v_gr_id IN ARRAY v_all_gr_ids
        LOOP
            SELECT gr.customer_id, c.auto_invoice_generation
            INTO v_grn_customer_id, v_is_invoiceable
            FROM goodsreceived gr
            JOIN customers c ON c.id = gr.customer_id
            WHERE gr.id = v_gr_id;

            IF v_is_invoiceable THEN
                v_single_invoice_data := generate_invoice_data_for_grn_with_pricing(v_gr_id);
                IF (v_single_invoice_data->>'success')::boolean = true THEN
                    v_invoice_data := v_invoice_data || jsonb_build_object(v_gr_id::text, v_single_invoice_data);
                END IF;
            END IF;
        END LOOP;
    END IF;

    -- ORDER/CART HANDLING (PERSISTENT CART MODEL)
    IF v_source_order_id IS NOT NULL THEN
        -- FROM ORDER dispatch: Delete or reduce cart items, keep order OPEN
        FOREACH v_item IN ARRAY p_dispatch_items
        LOOP
            v_gr_trl_id := (v_item->>'gr_trl_id')::uuid;
            v_dispatched_qty := (v_item->>'disp_qty')::integer;

            SELECT id, requested_quantity
            INTO v_cart_item_id, v_cart_current_qty
            FROM order_items
            WHERE order_id = v_source_order_id AND grn_items_id = v_gr_trl_id
            LIMIT 1
            FOR UPDATE;

            -- Record on the dispatch line what it takes from the cart line (migration 67).
            UPDATE dispatch_trl
            SET source_type = 'cart',
                source_order_item_id = v_cart_item_id,
                cart_quantity_consumed = CASE WHEN v_cart_item_id IS NULL THEN 0
                                              ELSE LEAST(v_cart_current_qty, v_dispatched_qty) END
            WHERE disp_id = v_dispatch_id AND gr_trl_id = v_gr_trl_id;

            IF v_cart_item_id IS NOT NULL THEN
                v_cart_new_qty := GREATEST(0, v_cart_current_qty - v_dispatched_qty);
                IF v_cart_new_qty = 0 THEN
                    DELETE FROM order_items WHERE id = v_cart_item_id;
                ELSE
                    UPDATE order_items
                    SET requested_quantity = v_cart_new_qty,
                        fulfilled_quantity = 0,
                        item_status = 'pending',
                        updated_at = NOW()
                    WHERE id = v_cart_item_id;
                END IF;
                -- D4 (migration 121): what the dispatch took from the order line goes into the order's change log.
                INSERT INTO order_revisions (order_id, changed_at, changed_by, action, entry)
                VALUES (v_source_order_id, clock_timestamp(), v_user_id, 'auto_quantity_reduction', jsonb_build_object(
                    'action', 'auto_quantity_reduction',
                    'timestamp', NOW(),
                    'by', v_user_id,
                    'dispatch_id', v_dispatch_id,
                    'dispatch_no', p_dispatch_data->>'disp_no',
                    'grn_item_id', v_gr_trl_id,
                    'previous_quantity', v_cart_current_qty,
                    'new_quantity', v_cart_new_qty));
            END IF;
        END LOOP;

        UPDATE orders
        SET status = 'OPEN',
            updated_at = NOW(),
            updated_by = v_user_id
        WHERE id = v_source_order_id;
    ELSE
        -- DIRECT DISPATCH: Reduce cart quantities
        FOREACH v_item IN ARRAY p_dispatch_items
        LOOP
            v_gr_trl_id := (v_item->>'gr_trl_id')::uuid;
            v_dispatched_qty := (v_item->>'disp_qty')::integer;

            SELECT gr.customer_id INTO v_grn_customer_id
            FROM goodsreceived_trl grt
            JOIN goodsreceived gr ON gr.id = grt.gr_id
            WHERE grt.id = v_gr_trl_id;

            IF v_grn_customer_id IS NOT NULL THEN
                SELECT id INTO v_cart_id
                FROM orders
                WHERE customer_id = v_grn_customer_id AND status = 'OPEN' AND deleted_at IS NULL
                ORDER BY created_at, id
                LIMIT 1;

                IF v_cart_id IS NOT NULL THEN
                    SELECT id, requested_quantity, fulfilled_quantity
                    INTO v_cart_item_id, v_cart_current_qty, v_cart_fulfilled_qty
                    FROM order_items
                    WHERE order_id = v_cart_id AND grn_items_id = v_gr_trl_id
                    LIMIT 1
                    FOR UPDATE;

                    -- Record on the dispatch line what it takes from the cart line (migration 67).
                    UPDATE dispatch_trl
                    SET source_order_item_id = v_cart_item_id,
                        cart_quantity_consumed = CASE WHEN v_cart_item_id IS NULL THEN 0
                                                      ELSE LEAST(v_cart_current_qty, v_dispatched_qty) END
                    WHERE disp_id = v_dispatch_id AND gr_trl_id = v_gr_trl_id;

                    IF v_cart_item_id IS NOT NULL THEN
                        v_cart_new_qty := GREATEST(0, v_cart_current_qty - v_dispatched_qty);
                        IF v_cart_new_qty = 0 THEN
                            DELETE FROM order_items WHERE id = v_cart_item_id;
                        ELSE
                            UPDATE order_items
                            SET requested_quantity = v_cart_new_qty,
                                fulfilled_quantity = GREATEST(0, COALESCE(v_cart_fulfilled_qty, 0) - v_dispatched_qty)
                            WHERE id = v_cart_item_id;
                        END IF;
                        -- D4 (migration 121): what the dispatch took from the order line goes into the order's change log.
                        INSERT INTO order_revisions (order_id, changed_at, changed_by, action, entry)
                        VALUES (v_cart_id, clock_timestamp(), v_user_id, 'auto_quantity_reduction', jsonb_build_object(
                            'action', 'auto_quantity_reduction',
                            'timestamp', NOW(),
                            'by', v_user_id,
                            'dispatch_id', v_dispatch_id,
                            'dispatch_no', p_dispatch_data->>'disp_no',
                            'grn_item_id', v_gr_trl_id,
                            'previous_quantity', v_cart_current_qty,
                            'new_quantity', v_cart_new_qty));
                    END IF;
                END IF;
            END IF;
        END LOOP;
    END IF;

    -- The lines of the source order still open after this dispatch (migration 120): the pending ones, the rule of
    -- the order queue (v_orders_list counts total_items the same way); NULL for a dispatch that has no source order.
    IF v_source_order_id IS NOT NULL THEN
        SELECT count(*)::integer INTO v_order_lines_left
        FROM order_items
        WHERE order_id = v_source_order_id
          AND item_status = 'pending';
    END IF;

    -- Migration 124 (opt-in): when the data carries warn_duplicate = true and a request key is sent, a direct dispatch (no source
    -- order) with the same customer, set of lots and vehicle as another live dispatch made in the last 30 minutes is a possible
    -- duplicate. A dispatch from an order is never warned about (its order line is used up). This is the last step before the
    -- answer is built, after every write and every refusal above: the answer is raised as 'dup_warn' (the handler returns the
    -- DETAIL), the function's block is rolled back, and the answer is never stored under the key.
    IF v_source_order_id IS NULL AND COALESCE(p_dispatch_data->>'warn_duplicate', '') = 'true' AND p_idempotency_key IS NOT NULL THEN
        v_duplicate := warehouse_security.possible_duplicate_dispatch(
            (p_dispatch_data->>'customer_id')::uuid,
            p_dispatch_data->>'registration',
            ARRAY(SELECT (item->>'gr_trl_id')::uuid FROM unnest(p_dispatch_items) AS item),
            v_dispatch_id);
        IF v_duplicate IS NOT NULL THEN
            RAISE EXCEPTION 'dup_warn' USING ERRCODE = 'P0001', DETAIL = v_duplicate::text;
        END IF;
    END IF;

    -- Build result
    v_cached_response := jsonb_build_object(
        'success', true,
        'dispatch_id', v_dispatch_id,
        'dispatch_items', to_jsonb(v_dispatch_items_result),
        'invoice_data', COALESCE(v_invoice_data, '{}'::jsonb),
        'message', 'Dispatch created successfully',
        'source_order_cleared', v_source_order_id IS NOT NULL,
        'order_lines_left', v_order_lines_left
    );

    -- Cache the response if idempotency key provided
    IF p_idempotency_key IS NOT NULL THEN
        -- Kept for the 7 days a retry is answered from it. A key another
        -- function or user holds is left alone unless it has expired.
        INSERT INTO idempotency_keys (idempotency_key, rpc_function, response, created_by, expires_at)
        VALUES (p_idempotency_key, 'create_dispatch_with_stock_check', v_cached_response, v_user_id, NOW() + INTERVAL '7 days')
        ON CONFLICT (idempotency_key) DO UPDATE SET
            rpc_function = EXCLUDED.rpc_function,
            response = EXCLUDED.response,
            created_by = EXCLUDED.created_by,
            created_at = NOW(),
            expires_at = EXCLUDED.expires_at
        WHERE idempotency_keys.expires_at <= NOW()
           OR (idempotency_keys.rpc_function = EXCLUDED.rpc_function
               AND idempotency_keys.created_by IS NOT DISTINCT FROM EXCLUDED.created_by);
    END IF;

    RETURN v_cached_response;

EXCEPTION
    WHEN OTHERS THEN
        IF SQLERRM = 'dup_warn' THEN
            GET STACKED DIAGNOSTICS v_detail = PG_EXCEPTION_DETAIL;
            RETURN v_detail::jsonb;
        END IF;
        RETURN jsonb_build_object(
            'success', false,
            'error', SQLERRM,
            'error_code', SQLSTATE
        );
END;
$function$;

REVOKE ALL ON FUNCTION public.create_dispatch_with_stock_check_internal(jsonb,jsonb[],boolean,text) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.create_dispatch_with_stock_check_internal(jsonb,jsonb[],boolean,text) TO service_role;
