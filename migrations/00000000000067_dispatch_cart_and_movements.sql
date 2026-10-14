-- Deleting a dispatch gives back the cart quantity it took, and stock movements
-- are logged once and with one sign rule (backend review 2026-10-13, I4 and I5).
--
-- I4. Under the persistent cart, a dispatch lowers the customer's cart line for
-- each lot it carries (requested_quantity - dispatched; the line is deleted at
-- 0), both for a dispatch made from the cart and for a direct one. The dispatch
-- line recorded none of it (source_type, source_order_item_id and
-- cart_quantity_consumed stayed at their defaults), so
-- delete_dispatch_with_order_cleanup only lowered fulfilled_quantity (already 0)
-- and recreated a used-up line as fulfilled with the dispatched quantity: a cart
-- of 10 that a dispatch of 4 lowered to 6 stayed at 6 after the dispatch was
-- deleted. Now:
-- - create_dispatch_with_stock_check_internal records on each dispatch line the
--   cart line it lowered and by how much (the smaller of the line's quantity and
--   the dispatched quantity); a dispatch from the cart marks its lines 'cart';
-- - delete_dispatch_with_order_cleanup adds that quantity back to the cart's
--   line for the lot (pending, nothing fulfilled), or makes a pending line of
--   that quantity again when the dispatch used it up. The old restoration
--   (restore_cart_quantities_from_dispatch, which never ran) and the old per-line
--   loop are removed. A line of a dispatch from the cart saved before this
--   migration has no record: nothing is given back for it, the answer counts it
--   (cart_lines_not_restored, cart_restoration.lines_not_restored) and its
--   message says so. A direct dispatch saved before this migration gives
--   nothing back, as before (its lines cannot be told from ones that took
--   nothing).
-- - a direct dispatch lowers, and its deletion gives back to, only the
--   customer's OPEN cart (the oldest, then the lowest id, should there ever be
--   more than one). When the dispatch used the line up and the customer has no
--   OPEN cart, one is made as get_or_create_cart makes it; the unique index
--   one_cart_per_customer allows one order per customer, so when the customer's
--   order exists but is not OPEN (or is deleted) it is left untouched, nothing is
--   given back for the line, and the answer counts it
--   (cart_lines_without_open_cart, cart_restoration.lines_without_open_cart)
--   and its message says so.
-- Known limits, unchanged: an edit that removes a line or lowers a quantity does
-- not give anything back to the cart; a deletion gives back what the line
-- recorded when the dispatch was made.
--
-- I5. update_dispatch_smart logged a 'dispatch' movement for every line sent,
-- added or not, so saving a dispatch unchanged logged a movement that never
-- happened (and a lot emptied long ago looked emptied today in
-- get_customer_stock_summary, which reads the latest movement). It now logs only
-- the rows its INSERT returns. Movement signs were mixed (creation +qty, an edit
-- -qty, a lowered quantity a 'dispatch' of +qty). The rule is now: 'dispatch' is
-- negative, 'return' positive, and quantity = balance_after - balance_before
-- (creation, a lowered quantity in an edit, the deletion, and the trigger
-- restore_stock_on_dispatch_delete, whose 'dispatch_deleted' type broke the
-- movement check, so a database owner's DELETE FROM dispatch with lines failed;
-- the trigger now logs what each lot really got back, which is less than the
-- dispatched quantity when the restore is capped at the received quantity).
-- delete_dispatch_with_order_cleanup now logs the stock it restores.
-- delete_dispatch_with_stock_restore is left alone: migration 71 drops it.
--
-- Existing movements are corrected where their balances show the meaning: a
-- 'dispatch' of +q whose balance fell by q becomes -q; a 'dispatch' of +q whose
-- balance rose by q becomes a 'return'. Probable duplicates left by unchanged
-- resaves are counted in a NOTICE and kept.
--
-- The four functions are patched in place, each with its owner, grants,
-- SECURITY DEFINER and settings kept and checked below.
DO $patch$
DECLARE
  fn_name text; fn regprocedure; definition text; step record; occurrences integer;
  before_secdef boolean; before_acl aclitem[]; before_config text[];
  after_secdef boolean; after_acl aclitem[]; after_config text[];
BEGIN
  CREATE TEMP TABLE migration_67_steps (step_no integer, signature text, expected integer, marker text, replacement text) ON COMMIT DROP;
  INSERT INTO migration_67_steps VALUES
    -- C1: a dispatch from the cart records the cart line and the quantity it takes.
    (1, 'public.create_dispatch_with_stock_check_internal(jsonb,jsonb[],boolean,text)', 1,
     $m$            WHERE order_id = v_source_order_id AND grn_items_id = v_gr_trl_id
            LIMIT 1;
$m$,
     $r$            WHERE order_id = v_source_order_id AND grn_items_id = v_gr_trl_id
            LIMIT 1;

            -- Record on the dispatch line what it takes from the cart line (migration 67).
            UPDATE dispatch_trl
            SET source_type = 'cart',
                source_order_item_id = v_cart_item_id,
                cart_quantity_consumed = CASE WHEN v_cart_item_id IS NULL THEN 0
                                              ELSE LEAST(v_cart_current_qty, v_dispatched_qty) END
            WHERE disp_id = v_dispatch_id AND gr_trl_id = v_gr_trl_id;
$r$),
    -- C2: a direct dispatch that lowers the customer's cart records the same; it stays 'direct'.
    (2, 'public.create_dispatch_with_stock_check_internal(jsonb,jsonb[],boolean,text)', 1,
     $m$                    WHERE order_id = v_cart_id AND grn_items_id = v_gr_trl_id
                    LIMIT 1;
$m$,
     $r$                    WHERE order_id = v_cart_id AND grn_items_id = v_gr_trl_id
                    LIMIT 1;

                    -- Record on the dispatch line what it takes from the cart line (migration 67).
                    UPDATE dispatch_trl
                    SET source_order_item_id = v_cart_item_id,
                        cart_quantity_consumed = CASE WHEN v_cart_item_id IS NULL THEN 0
                                                      ELSE LEAST(v_cart_current_qty, v_dispatched_qty) END
                    WHERE disp_id = v_dispatch_id AND gr_trl_id = v_gr_trl_id;
$r$),
    -- C3: the creation movement is negative.
    (3, 'public.create_dispatch_with_stock_check_internal(jsonb,jsonb[],boolean,text)', 1,
     $m$        'dispatch',
        (item->>'disp_qty')::integer,
        v_dispatch_id,$m$,
     $r$        'dispatch',
        -(item->>'disp_qty')::integer,
        v_dispatch_id,$r$),
    -- X1: variables.
    (4, 'public.delete_dispatch_with_order_cleanup(uuid,uuid)', 1,
     $m$    v_invoice_count INTEGER := 0;  -- NEW: For invoice safeguard$m$,
     $r$    v_invoice_count INTEGER := 0;  -- NEW: For invoice safeguard
    v_cart_line record;
    v_restore_cart_id uuid;
    v_cart_lines_not_restored integer := 0;
    v_cart_lines_no_open_cart integer := 0;
    v_cart_details jsonb := '[]'::jsonb;$r$),
    -- X2: the old restoration, which never ran (no line recorded a cart quantity).
    (5, 'public.delete_dispatch_with_order_cleanup(uuid,uuid)', 1,
     $m$    -- IMPROVED: Check if this dispatch has any cart-related items before attempting cart restoration
    IF v_dispatch_record.source_order_id IS NOT NULL THEN
        -- Check if there are any cart items to restore
        SELECT EXISTS (
            SELECT 1
            FROM dispatch_trl dt
            WHERE dt.disp_id = p_dispatch_id
            AND dt.source_type = 'cart'
            AND dt.source_order_item_id IS NOT NULL
            AND dt.cart_quantity_consumed > 0
        ) INTO v_has_cart_items;

        IF v_has_cart_items THEN
            BEGIN
                -- Try cart restoration for cart items
                v_cart_restoration := restore_cart_quantities_from_dispatch(p_dispatch_id);

                -- Check if cart restoration failed with an actual error
                IF v_cart_restoration IS NULL THEN
                    v_cart_restoration := jsonb_build_object(
                        'success', false,
                        'message', 'Cart restoration returned null - possible data integrity issue',
                        'updates_made', 0
                    );
                    v_cart_restoration_error := 'Cart restoration returned null';
                END IF;

            EXCEPTION
                WHEN others THEN
                    -- Capture the error but don't fail the entire operation
                    v_cart_restoration_error := SQLERRM;
                    v_cart_restoration := jsonb_build_object(
                        'success', false,
                        'error', SQLERRM,
                        'message', 'Cart restoration failed but continuing with dispatch deletion',
                        'updates_made', 0
                    );

                    -- Log the error for debugging but continue
                    v_debug_info := v_debug_info || jsonb_build_object(
                        'cart_restoration_error', SQLERRM,
                        'timestamp', NOW(),
                        'action', 'cart_restoration_failed_but_continuing'
                    );
            END;
        ELSE
            -- No cart items in this dispatch
            v_cart_restoration := jsonb_build_object(
                'success', true,
                'message', 'No cart items to restore - dispatch was created directly from order items',
                'updates_made', 0,
                'restoration_details', '[]'::jsonb
            );
        END IF;
    ELSE
        -- No source order, set default cart restoration result
        v_cart_restoration := jsonb_build_object(
            'success', true,
            'message', 'No cart quantities to restore - dispatch was not from an order',
            'updates_made', 0,
            'restoration_details', '[]'::jsonb
        );
    END IF;

$m$,
     $r$    -- Cart quantities are given back below, from what each dispatch line
    -- recorded when it was saved (migration 67).

$r$),
    -- X3: a 'return' movement for the stock restored.
    (6, 'public.delete_dispatch_with_order_cleanup(uuid,uuid)', 1,
     $m$        UPDATE goodsreceived_trl
        SET
            stock = v_new_stock
        WHERE id = v_item.gr_trl_id;
$m$,
     $r$        UPDATE goodsreceived_trl
        SET
            stock = v_new_stock
        WHERE id = v_item.gr_trl_id;

        -- The stock coming back is logged (migration 67).
        IF v_old_stock IS NOT NULL AND v_new_stock <> v_old_stock THEN
            INSERT INTO stock_movements (gr_trl_id, movement_type, quantity, reference_id, reference_type,
                                         balance_before, balance_after, created_by, notes)
            VALUES (v_item.gr_trl_id,
                    CASE WHEN v_new_stock > v_old_stock THEN 'return' ELSE 'adjustment' END,
                    v_new_stock - v_old_stock, p_dispatch_id, 'dispatch_delete',
                    v_old_stock, v_new_stock, v_user_profile_id, 'Dispatch deleted');
        END IF;
$r$),
    -- X4: the cart restoration.
    (7, 'public.delete_dispatch_with_order_cleanup(uuid,uuid)', 1,
     $m$    -- Check if there are linked orders - now just check source_order_id$m$,
     $r$    -- Give back to the customer's cart what this dispatch took from it
    -- (migration 67). When a dispatch is saved, each line records the cart line
    -- it lowered (source_order_item_id) and by how much (cart_quantity_consumed).
    -- That quantity is added back to the cart's line for the lot, pending and
    -- with nothing fulfilled, or a pending line of that quantity is made again
    -- when the dispatch used the line up. The cart is the order the dispatch was
    -- made from; for a direct dispatch, the order of the recorded cart line, else
    -- the customer's OPEN cart (the rule the direct dispatch used to find it),
    -- else a new OPEN cart made as get_or_create_cart makes it. A customer has
    -- one order at most (one_cart_per_customer): when it exists but is not OPEN
    -- or is deleted, no cart can be made, the order is left as it is and the
    -- line is counted (cart_lines_without_open_cart).
    FOR v_cart_line IN
        SELECT
            dt.id,
            dt.gr_trl_id,
            dt.cart_quantity_consumed,
            dt.source_order_item_id,
            gt.item_name,
            gt.item_id,
            gt.package_mark,
            gt.packaging,
            gt.rack,
            gt.weight,
            gt.stock,
            gt.gr_id,
            gr.gr_no,
            gr.date as gr_date,
            gr.customer_id,
            gr.customer_name,
            gr.gr_image_url
        FROM dispatch_trl dt
        JOIN goodsreceived_trl gt ON gt.id = dt.gr_trl_id
        JOIN goodsreceived gr ON gr.id = gt.gr_id
        WHERE dt.disp_id = p_dispatch_id
          AND COALESCE(dt.cart_quantity_consumed, 0) > 0
        ORDER BY dt.id
    LOOP
        v_restore_cart_id := COALESCE(
            v_dispatch_record.source_order_id,
            (SELECT oi.order_id FROM order_items oi WHERE oi.id = v_cart_line.source_order_item_id),
            (SELECT o.id FROM orders o
             WHERE o.customer_id = v_dispatch_record.customer_id AND o.status = 'OPEN' AND o.deleted_at IS NULL
             ORDER BY o.created_at, o.id
             LIMIT 1));

        IF v_restore_cart_id IS NULL THEN
            -- No OPEN cart: make one, with get_or_create_cart's columns. The
            -- unique index lets this succeed only when the customer has no order.
            INSERT INTO orders (
                customer_id, customer_name, customer_email, customer_phone,
                order_date, requested_dispatch_date, status, priority,
                created_by, updated_by
            )
            SELECT c.id, c.name, c.email, c.mobile,
                   NOW(), NOW() + INTERVAL '7 days', 'OPEN', 'normal',
                   v_user_profile_id, v_user_profile_id
            FROM customers c
            WHERE c.id = v_dispatch_record.customer_id
            ON CONFLICT DO NOTHING
            RETURNING id INTO v_restore_cart_id;
        END IF;

        IF v_restore_cart_id IS NULL THEN
            v_cart_lines_no_open_cart := v_cart_lines_no_open_cart + 1;
            CONTINUE;
        END IF;

        UPDATE order_items
        SET
            requested_quantity = requested_quantity + v_cart_line.cart_quantity_consumed,
            fulfilled_quantity = 0,
            item_status = 'pending',
            current_stock = v_cart_line.stock,
            updated_at = now()
        WHERE order_id = v_restore_cart_id
          AND grn_items_id = v_cart_line.gr_trl_id;

        IF FOUND THEN
            v_order_items_restored := v_order_items_restored + 1;
        ELSE
            INSERT INTO order_items (
                order_id, order_no, requested_quantity, fulfilled_quantity,
                grn_items_id, grn_items_item_id, grn_items_item_name,
                grn_items_package_mark, grn_items_packaging, grn_items_rack,
                grn_items_weight, grn_items_image_url,
                grns_id, grns_gr_no, grns_date, grns_customer_id, grns_customer_name,
                available_stock_at_order, current_stock, item_status, sort_order
            ) VALUES (
                v_restore_cart_id,
                (SELECT o.order_no FROM orders o WHERE o.id = v_restore_cart_id),
                v_cart_line.cart_quantity_consumed,
                0,
                v_cart_line.gr_trl_id,
                v_cart_line.item_id,
                v_cart_line.item_name,
                COALESCE(v_cart_line.package_mark, ''),
                COALESCE(v_cart_line.packaging, ''),
                COALESCE(v_cart_line.rack, ''),
                COALESCE(v_cart_line.weight, 0),
                v_cart_line.gr_image_url,
                v_cart_line.gr_id,
                v_cart_line.gr_no,
                v_cart_line.gr_date,
                v_cart_line.customer_id,
                COALESCE(v_cart_line.customer_name, v_dispatch_record.customer_name, ''),
                v_cart_line.stock,
                v_cart_line.stock,
                'pending',
                COALESCE((SELECT max(oi.sort_order) + 1 FROM order_items oi WHERE oi.order_id = v_restore_cart_id), 1)
            );

            v_order_items_recreated := v_order_items_recreated + 1;
        END IF;

        v_cart_details := v_cart_details || jsonb_build_object(
            'order_id', v_restore_cart_id,
            'gr_trl_id', v_cart_line.gr_trl_id,
            'item_name', v_cart_line.item_name,
            'quantity_restored', v_cart_line.cart_quantity_consumed
        );
    END LOOP;

    -- A line of a dispatch from the cart saved before migration 67 has no record
    -- of what it took from the cart: nothing is given back for it, and the
    -- answer says how many such lines there were.
    IF v_dispatch_record.source_order_id IS NOT NULL THEN
        v_cart_lines_not_restored := v_cart_lines_not_restored + (
            SELECT count(*)::integer FROM dispatch_trl
            WHERE disp_id = p_dispatch_id AND source_type IS DISTINCT FROM 'cart'
        );
    END IF;

    v_has_cart_items := jsonb_array_length(v_cart_details) > 0;
    v_cart_restoration := jsonb_build_object(
        'success', true,
        'message', CASE WHEN v_has_cart_items THEN 'Cart quantities restored'
                        ELSE 'No cart quantities to restore' END,
        'updates_made', v_order_items_restored + v_order_items_recreated,
        'restoration_details', v_cart_details,
        'lines_not_restored', v_cart_lines_not_restored,
        'lines_without_open_cart', v_cart_lines_no_open_cart
    );

    -- Check if there are linked orders - now just check source_order_id$r$),
    -- X5: the old per-line loop (it lowered fulfilled_quantity, already 0, and recreated used-up lines as fulfilled).
    (8, 'public.delete_dispatch_with_order_cleanup(uuid,uuid)', 1,
     $m$        -- For each dispatch item, restore or recreate order items
        FOR v_item IN
            SELECT
                dt.id as dispatch_trl_id,
                dt.gr_trl_id,
                dt.disp_qty,
                dt.source_type,
                dt.source_order_item_id,
                dt.cart_quantity_consumed,
                gt.item_name,
                gt.item_id,
                gt.package_mark,
                gt.packaging,
                gt.rack,
                gt.weight,
                gt.gr_id,
                gr.gr_no,
                gr.date as gr_date,
                gr.customer_id,
                gr.customer_name,
                gr.gr_image_url
            FROM dispatch_trl dt
            JOIN goodsreceived_trl gt ON gt.id = dt.gr_trl_id
            JOIN goodsreceived gr ON gr.id = gt.gr_id
            WHERE dt.disp_id = p_dispatch_id
        LOOP
            -- Check if order item exists
            IF EXISTS (
                SELECT 1 FROM order_items
                WHERE order_id = v_dispatch_record.source_order_id
                AND grn_items_id = v_item.gr_trl_id
            ) THEN
                -- FIXED: Update existing order item with proper constraint checking
                UPDATE order_items
                SET
                    fulfilled_quantity = LEAST(
                        requested_quantity,
                        GREATEST(0, fulfilled_quantity - v_item.disp_qty)
                    ),
                    item_status = CASE
                        WHEN GREATEST(0, fulfilled_quantity - v_item.disp_qty) = 0 THEN 'pending'
                        WHEN GREATEST(0, fulfilled_quantity - v_item.disp_qty) < requested_quantity THEN 'partially_fulfilled'
                        ELSE 'fulfilled'
                    END,
                    current_stock = (SELECT stock FROM goodsreceived_trl WHERE id = grn_items_id),
                    updated_at = now()
                WHERE order_id = v_dispatch_record.source_order_id
                AND grn_items_id = v_item.gr_trl_id;

                v_order_items_restored := v_order_items_restored + 1;
            ELSE
                -- Recreate the order item that was deleted during dispatch
                INSERT INTO order_items (
                    order_id,
                    order_no,
                    requested_quantity,
                    fulfilled_quantity,
                    grn_items_id,
                    grn_items_item_id,
                    grn_items_item_name,
                    grn_items_package_mark,
                    grn_items_packaging,
                    grn_items_rack,
                    grn_items_weight,
                    grn_items_image_url,
                    grns_id,
                    grns_gr_no,
                    grns_date,
                    grns_customer_id,
                    grns_customer_name,
                    available_stock_at_order,
                    current_stock,
                    item_status,
                    created_at,
                    updated_at
                ) VALUES (
                    v_dispatch_record.source_order_id,
                    v_source_order_no,
                    v_item.disp_qty,
                    v_item.disp_qty,
                    v_item.gr_trl_id,
                    v_item.item_id,
                    v_item.item_name,
                    v_item.package_mark,
                    v_item.packaging,
                    v_item.rack,
                    v_item.weight,
                    v_item.gr_image_url,
                    v_item.gr_id,
                    v_item.gr_no,
                    v_item.gr_date,
                    v_item.customer_id,
                    v_item.customer_name,
                    (SELECT stock FROM goodsreceived_trl WHERE id = v_item.gr_trl_id),
                    (SELECT stock FROM goodsreceived_trl WHERE id = v_item.gr_trl_id),
                    'fulfilled',
                    now(),
                    now()
                );

                v_order_items_recreated := v_order_items_recreated + 1;
            END IF;
        END LOOP;

$m$,
     $r$        -- Cart lines were given back above (migration 67).

$r$),
    -- X6: the answer's message names lines not given back.
    (9, 'public.delete_dispatch_with_order_cleanup(uuid,uuid)', 1,
     $m$                         v_out_of_stock_reset),$m$,
     $r$                         v_out_of_stock_reset)
            || CASE WHEN v_cart_lines_not_restored > 0
                    THEN format(' %s cart line(s) were saved before cart quantities were recorded; their quantities were not returned to the order.',
                                v_cart_lines_not_restored)
                    ELSE '' END
            || CASE WHEN v_cart_lines_no_open_cart > 0
                    THEN format(' %s cart line(s) were not returned: the customer has no open cart and one could not be made.',
                                v_cart_lines_no_open_cart)
                    ELSE '' END,$r$),
    -- X7: and the answer counts them.
    (10, 'public.delete_dispatch_with_order_cleanup(uuid,uuid)', 1,
     $m$        'cart_restoration', v_cart_restoration,$m$,
     $r$        'cart_restoration', v_cart_restoration,
        'cart_lines_not_restored', v_cart_lines_not_restored,
        'cart_lines_without_open_cart', v_cart_lines_no_open_cart,$r$),
    -- X8: the restored lines are counted once (cart_restoration.updates_made is now the same number).
    (11, 'public.delete_dispatch_with_order_cleanup(uuid,uuid)', 3,
     $m$v_order_items_restored + v_order_items_recreated + COALESCE((v_cart_restoration->>'updates_made')::integer, 0)$m$,
     $r$v_order_items_restored + v_order_items_recreated$r$),
    -- E1: a lowered quantity is a 'return'.
    (12, 'public.update_dispatch_smart(uuid,jsonb,jsonb[])', 1,
     $m$            'dispatch',
            -((new_item->>'disp_qty')::integer - dt.disp_qty),$m$,
     $r$            CASE WHEN (new_item->>'disp_qty')::integer > dt.disp_qty THEN 'dispatch' ELSE 'return' END,
            -((new_item->>'disp_qty')::integer - dt.disp_qty),$r$),
    -- E2: steps 12 and 13 (step 13 logged every line sent, added or not).
    (13, 'public.update_dispatch_smart(uuid,jsonb,jsonb[])', 1,
     $m$        -- ========== STEP 12: BULK insert NEW dispatch items ==========
        INSERT INTO dispatch_trl (disp_id, gr_trl_id, gr_id, disp_qty)
        SELECT
            p_dispatch_id,
            (new_item->>'gr_trl_id')::uuid,
            gt.gr_id,
            (new_item->>'disp_qty')::integer
        FROM unnest(p_dispatch_items) AS new_item
        JOIN goodsreceived_trl gt ON gt.id = (new_item->>'gr_trl_id')::uuid
        WHERE NOT EXISTS (
            SELECT 1 FROM dispatch_trl dt
            WHERE dt.disp_id = p_dispatch_id
            AND dt.gr_trl_id = (new_item->>'gr_trl_id')::uuid
        );

        -- ========== STEP 13: BULK log movements for NEW items ==========
        INSERT INTO stock_movements (gr_trl_id, movement_type, quantity, reference_id, reference_type, balance_before, balance_after, created_by)
        SELECT
            (new_item->>'gr_trl_id')::uuid,
            'dispatch',
            -(new_item->>'disp_qty')::integer,
            p_dispatch_id,
            'dispatch',
            gt.stock + (new_item->>'disp_qty')::integer,  -- balance_before
            gt.stock,  -- balance_after (already updated)
            v_user_id
        FROM unnest(p_dispatch_items) AS new_item
        JOIN goodsreceived_trl gt ON gt.id = (new_item->>'gr_trl_id')::uuid
        JOIN dispatch_trl dt ON dt.disp_id = p_dispatch_id AND dt.gr_trl_id = gt.id
        WHERE dt.id = (SELECT id FROM dispatch_trl WHERE disp_id = p_dispatch_id AND gr_trl_id = gt.id ORDER BY id DESC LIMIT 1);

$m$,
     $r$        -- ========== STEP 12: BULK insert NEW dispatch items, and log a
        -- movement for exactly the rows inserted (migration 67) ==========
        -- A line added to a dispatch from the cart is marked 'cart' (it takes
        -- nothing from the cart, so nothing is given back for it on deletion).
        WITH inserted AS (
            INSERT INTO dispatch_trl (disp_id, gr_trl_id, gr_id, disp_qty, source_type)
            SELECT
                p_dispatch_id,
                (new_item->>'gr_trl_id')::uuid,
                gt.gr_id,
                (new_item->>'disp_qty')::integer,
                CASE WHEN EXISTS (SELECT 1 FROM dispatch d WHERE d.id = p_dispatch_id AND d.source_order_id IS NOT NULL)
                     THEN 'cart' ELSE 'direct' END
            FROM unnest(p_dispatch_items) AS new_item
            JOIN goodsreceived_trl gt ON gt.id = (new_item->>'gr_trl_id')::uuid
            WHERE NOT EXISTS (
                SELECT 1 FROM dispatch_trl dt
                WHERE dt.disp_id = p_dispatch_id
                AND dt.gr_trl_id = (new_item->>'gr_trl_id')::uuid
            )
            RETURNING gr_trl_id, disp_qty
        )
        INSERT INTO stock_movements (gr_trl_id, movement_type, quantity, reference_id, reference_type, balance_before, balance_after, created_by)
        SELECT
            ins.gr_trl_id,
            'dispatch',
            -ins.disp_qty,
            p_dispatch_id,
            'dispatch',
            gt.stock + ins.disp_qty,  -- balance_before
            gt.stock,  -- balance_after (already updated in step 11)
            v_user_id
        FROM inserted ins
        JOIN goodsreceived_trl gt ON gt.id = ins.gr_trl_id;

$r$),
    -- T1: the trigger's movement is a 'return' the movement check accepts, and it
    -- records what the lot really got back: balance_before the stock before,
    -- balance_after the stock after (capped at the received quantity), quantity
    -- the difference. (The old INSERT ran after the UPDATE and logged the
    -- dispatched quantity with a balance_before derived from it.)
    (14, 'public.restore_stock_on_dispatch_delete()', 1,
     $m$    -- Restore stock for all items in this dispatch (capped at qty)
    UPDATE goodsreceived_trl gt
    SET stock = LEAST(gt.qty, gt.stock + dt.disp_qty)  -- Cap at qty
    FROM dispatch_trl dt
    WHERE dt.disp_id = OLD.id
    AND gt.id = dt.gr_trl_id;

    -- Record stock movements for the reversal
    INSERT INTO stock_movements (
        gr_trl_id, movement_type, quantity,
        reference_id, reference_type,
        balance_before, balance_after, notes
    )
    SELECT
        dt.gr_trl_id,
        'dispatch_deleted',
        dt.disp_qty,
        OLD.id,
        'dispatch',
        gt.stock - LEAST(dt.disp_qty, gt.qty - gt.stock + dt.disp_qty),
        gt.stock,
        'Stock restored due to dispatch deletion'
    FROM dispatch_trl dt
    JOIN goodsreceived_trl gt ON gt.id = dt.gr_trl_id
    WHERE dt.disp_id = OLD.id;
$m$,
     $r$    -- Restore stock for all items in this dispatch (capped at qty), and log
    -- what each lot really got back (migration 67): the stock before and after
    -- the restore, and their difference, which is less than the dispatched
    -- quantity when the cap applies. before_gt is read before the UPDATE.
    WITH restored AS (
        UPDATE goodsreceived_trl gt
        SET stock = LEAST(gt.qty, gt.stock + dt.disp_qty)  -- Cap at qty
        FROM dispatch_trl dt
        JOIN goodsreceived_trl before_gt ON before_gt.id = dt.gr_trl_id
        WHERE dt.disp_id = OLD.id
        AND gt.id = dt.gr_trl_id
        RETURNING gt.id AS gr_trl_id, before_gt.stock AS old_stock, gt.stock AS new_stock
    )
    INSERT INTO stock_movements (
        gr_trl_id, movement_type, quantity,
        reference_id, reference_type,
        balance_before, balance_after, notes
    )
    SELECT
        r.gr_trl_id,
        'return',
        r.new_stock - r.old_stock,
        OLD.id,
        'dispatch_delete',
        r.old_stock,
        r.new_stock,
        'Stock restored due to dispatch deletion'
    FROM restored r
    WHERE r.new_stock > r.old_stock;
$r$),
    -- C4: a direct dispatch lowers the customer's OPEN cart, chosen in a fixed
    -- order (the oldest, then the lowest id), as its deletion finds it again.
    (15, 'public.create_dispatch_with_stock_check_internal(jsonb,jsonb[],boolean,text)', 1,
     $m$                WHERE customer_id = v_grn_customer_id AND status = 'OPEN' AND deleted_at IS NULL
                LIMIT 1;
$m$,
     $r$                WHERE customer_id = v_grn_customer_id AND status = 'OPEN' AND deleted_at IS NULL
                ORDER BY created_at, id
                LIMIT 1;
$r$);

  FOR fn_name IN SELECT signature FROM migration_67_steps GROUP BY signature ORDER BY min(step_no)
  LOOP
    fn := fn_name::regprocedure;
    SELECT prosecdef, proacl, proconfig INTO STRICT before_secdef, before_acl, before_config
      FROM pg_proc WHERE oid=fn;
    definition := pg_get_functiondef(fn);
    FOR step IN SELECT * FROM migration_67_steps WHERE signature = fn_name ORDER BY step_no
    LOOP
      occurrences := (length(definition)-length(replace(definition,step.marker,'')))/length(step.marker);
      IF occurrences <> step.expected THEN
        RAISE EXCEPTION 'Dispatch cart and movements patch %: expected % marker(s) in %, found %',
          step.step_no, step.expected, fn_name, occurrences;
      END IF;
      definition := replace(definition, step.marker, step.replacement);
    END LOOP;
    EXECUTE definition;

    SELECT prosecdef, proacl, proconfig INTO STRICT after_secdef, after_acl, after_config
      FROM pg_proc WHERE oid=fn;
    IF after_secdef IS DISTINCT FROM before_secdef THEN
      RAISE EXCEPTION '% SECURITY DEFINER changed', fn_name;
    END IF;
    IF after_acl IS DISTINCT FROM before_acl THEN
      RAISE EXCEPTION '% grants changed: % became %', fn_name, before_acl, after_acl;
    END IF;
    IF after_config IS DISTINCT FROM before_config THEN
      RAISE EXCEPTION '% settings changed: % became %', fn_name, before_config, after_config;
    END IF;
  END LOOP;

  IF position('cart_quantity_consumed = CASE' IN pg_get_functiondef('public.create_dispatch_with_stock_check_internal(jsonb,jsonb[],boolean,text)'::regprocedure)) = 0
     OR position('v_cart_lines_not_restored' IN pg_get_functiondef('public.delete_dispatch_with_order_cleanup(uuid,uuid)'::regprocedure)) = 0
     OR position('restore_cart_quantities_from_dispatch' IN pg_get_functiondef('public.delete_dispatch_with_order_cleanup(uuid,uuid)'::regprocedure)) > 0
     OR position('WITH inserted AS (' IN pg_get_functiondef('public.update_dispatch_smart(uuid,jsonb,jsonb[])'::regprocedure)) = 0
     OR position('dispatch_deleted' IN pg_get_functiondef('public.restore_stock_on_dispatch_delete()'::regprocedure)) > 0
     OR position('WITH restored AS (' IN pg_get_functiondef('public.restore_stock_on_dispatch_delete()'::regprocedure)) = 0
     OR position('ORDER BY created_at, id' IN pg_get_functiondef('public.create_dispatch_with_stock_check_internal(jsonb,jsonb[],boolean,text)'::regprocedure)) = 0 THEN
    RAISE EXCEPTION 'Migration 67 did not patch every function';
  END IF;
END $patch$;

-- Existing movements: signs corrected where the balances show the meaning.
DO $data$
DECLARE signs_fixed integer; returns_fixed integer; duplicates integer; still_off integer;
BEGIN
  -- Creation logged a dispatch as +q while the balance fell by q.
  UPDATE public.stock_movements SET quantity = -quantity
  WHERE movement_type = 'dispatch' AND quantity > 0 AND balance_after = balance_before - quantity;
  GET DIAGNOSTICS signs_fixed = ROW_COUNT;
  -- An edit that lowered a quantity logged a 'dispatch' of +q while the balance rose by q.
  UPDATE public.stock_movements SET movement_type = 'return'
  WHERE movement_type = 'dispatch' AND quantity > 0 AND balance_after = balance_before + quantity;
  GET DIAGNOSTICS returns_fixed = ROW_COUNT;
  -- A dispatch logged more than once for the same lot (unchanged resaves): kept, counted.
  SELECT COALESCE(sum(n - 1), 0) INTO duplicates FROM (
    SELECT count(*) AS n FROM public.stock_movements
    WHERE movement_type = 'dispatch' AND reference_type = 'dispatch'
    GROUP BY gr_trl_id, reference_id HAVING count(*) > 1) d;
  SELECT count(*) INTO still_off FROM public.stock_movements
  WHERE NOT (quantity = balance_after - balance_before
             AND ((movement_type = 'dispatch' AND quantity < 0) OR (movement_type = 'return' AND quantity > 0)
                  OR movement_type = 'adjustment'));
  RAISE NOTICE 'Migration 67: % dispatch movement(s) given a negative sign, % changed to return; % probable duplicate dispatch movement(s) from unchanged resaves kept (this count also includes a line that was legitimately removed and added again); % movement(s) still outside the sign rule (kept)',
    signs_fixed, returns_fixed, duplicates, still_off;
  IF duplicates > 0 OR still_off > 0 THEN
    RAISE WARNING 'Migration 67: % probable duplicate dispatch movement(s) (the count also includes a line legitimately removed and added again) and % movement(s) outside the sign rule are left as they are; review them in stock_movements.', duplicates, still_off;
  END IF;
END $data$;
NOTIFY pgrst, 'reload schema';
