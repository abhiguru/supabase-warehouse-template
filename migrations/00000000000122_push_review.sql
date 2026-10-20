-- Review of the whole backend diff (2026-10-20, push to main): four corrections on top of migration 121.
--  * D4, lower after raise (owner-cautious reading): an edit that lowers a line gives back only the bags that came from the
--    order and are no longer dispatched, GREATEST(consumed - new quantity, 0), and the line keeps LEAST(consumed, new quantity).
--    A line raised past its order and then lowered gives back nothing until it drops below what it took. Delete is unchanged.
--  * D4, source order that is not OPEN: the edit gives back into it as the dispatch delete does, whatever its status, and opens
--    it the way the delete opens it (status OPEN, deleted_at cleared), instead of dropping the bags.
--  * D4, legacy lines: what a line holds is capped at its old quantity (a held 99 on a 10-bag line gives back 6 when lowered to 4).
--  * D4, a direct dispatch gives back into its recorded order line's order only while that order is OPEN (as 121 did).
--  * D4, the source order is opened before the lines are walked whenever any line gives back to it, so lot order does not matter.
--  * D1, a save that sends lines but no header data moves the dispatch's updated_at too, so the answer's token is new.
--  * warehouse_security.restore_to_order: search_path ends with pg_temp, the repository's pin.

ALTER FUNCTION warehouse_security.restore_to_order(p_dispatch_id uuid, p_source_order_id uuid, p_source_item_id uuid, p_customer_id uuid, p_lot uuid, p_quantity integer, p_user uuid)
    SET search_path TO 'pg_catalog', 'public', 'pg_temp';

CREATE OR REPLACE FUNCTION public.update_dispatch_smart(p_dispatch_id uuid, p_dispatch_data jsonb, p_dispatch_items jsonb[]) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'extensions', 'utils', 'pg_temp'
    AS $$
DECLARE
    v_user_id uuid;
    v_invoiced_items text;
    v_insufficient_stock text;
    v_foreign_lots text;
    v_affected_gr_ids uuid[];
    v_dispatch_items_result jsonb[];
    v_locked_dispatch uuid;
    v_deleted_lots text;
    v_request_key text;
    v_cached_response jsonb;
    v_result jsonb;
    v_stored_updated_at timestamptz;
    v_expected_at timestamptz;
    v_stored_disp_no text;
    v_stored_disp_date timestamptz;
    v_sent_day date;
    v_day_changed boolean := false;
    v_no_changed boolean := false;
    v_inv_no integer;
    v_inv_year integer;
    v_changed_fields jsonb;
    v_late_gr_no text;
    v_late_grn_day date;
    v_old_lines jsonb;
    v_cust_id uuid;
    v_src_order_id uuid;
    v_disp_no_now text;
    v_sync record;
    v_back integer;
    v_take integer;
    v_gave integer;
    v_use_src uuid;
    v_use_item uuid;
    v_given_back integer := 0;
    v_taken integer := 0;
    v_cart uuid;
    v_given_carts uuid[] := ARRAY[]::uuid[];
    v_line_id uuid;
    v_line_qty integer;
    v_line_fulfilled integer;
    v_new_line_qty integer;
    v_new_updated_at timestamptz;
BEGIN
  PERFORM warehouse_security.authorize_rpc('update_dispatch_smart',jsonb_build_object('p_dispatch_id',p_dispatch_id));
    -- The list-refresh lock comes before any row lock (migration 46).
    PERFORM pg_advisory_xact_lock(71040);

    -- A request code (migration 120, owner decision D22): when the request carries one, this user's saved answer for
    -- it is returned as it was, before any other check, while the dispatch it saved still exists. A resend of a
    -- save whose answer was lost is therefore never refused for what its own first try changed, and
    -- get_submission_result gives the same answer.
    v_request_key := NULLIF(p_dispatch_data->>'request_key', '');
    IF v_request_key IS NOT NULL THEN
        SELECT k.response INTO v_cached_response
        FROM idempotency_keys k
        WHERE k.idempotency_key = v_request_key
          AND k.rpc_function = 'update_dispatch_smart'
          AND k.created_by = (SELECT id FROM user_profiles WHERE auth_user_id = auth.uid())
          AND k.response->>'dispatch_id' = p_dispatch_id::text
          AND k.expires_at > now();

        IF v_cached_response IS NOT NULL
           AND EXISTS (SELECT 1 FROM dispatch r WHERE r.id = p_dispatch_id AND r.deleted_at IS NULL) THEN
            RETURN v_cached_response;
        END IF;
    END IF;

  PERFORM warehouse_security.require_person_supervisor(p_dispatch_data->>'supervisor_id',
    (SELECT supervisor_id FROM dispatch WHERE id = p_dispatch_id));
    -- Check if user is admin or supervisor
    IF NOT warehouse_security.active_role() IN ('admin','supervisor','staff') THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'Only administrators and supervisors can update dispatches'
        );
    END IF;

    -- Get current user
    SELECT id INTO v_user_id FROM user_profiles WHERE auth_user_id = auth.uid();

    -- The dispatch row is locked, and a dispatch that is not there (deleted meanwhile) is not saved to
    -- (migration 120). Before this every sent line counted as new, the stock was taken, and the insert of
    -- the lines then failed on the foreign key.
    SELECT d.id, d.updated_at, d.disp_no, d.disp_date
    INTO v_locked_dispatch, v_stored_updated_at, v_stored_disp_no, v_stored_disp_date
    FROM dispatch d
    WHERE d.id = p_dispatch_id AND d.deleted_at IS NULL
    FOR UPDATE;

    IF v_locked_dispatch IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'Dispatch not found');
    END IF;

    -- D1 (migration 121): a dispatch that changed after the caller read it is not saved over; nothing is written. The
    -- token is the dispatch's updated_at, sent as expected_updated_at in p_dispatch_data. This runs after the saved-answer
    -- replay above, so a resend of this user's own lost save is never refused for what its first try changed. No token (an
    -- older app, fas-sync): no check.
    IF NULLIF(p_dispatch_data->>'expected_updated_at', '') IS NOT NULL THEN
        v_expected_at := (p_dispatch_data->>'expected_updated_at')::timestamptz;
        IF date_trunc('milliseconds', v_stored_updated_at) IS DISTINCT FROM date_trunc('milliseconds', v_expected_at) THEN
            RETURN warehouse_security.refuse('STALE_RECORD', 'Someone else changed this dispatch. Open it again.',
                jsonb_build_object('what', 'dispatch', 'id', p_dispatch_id,
                                   'expected_updated_at', v_expected_at, 'current_updated_at', v_stored_updated_at));
        END IF;
    END IF;

    IF p_dispatch_data->>'disp_no' IS NOT NULL AND warehouse_security.is_blank_text(p_dispatch_data->>'disp_no') THEN
        RAISE EXCEPTION 'disp_no is required' USING ERRCODE = 'WH409';
    END IF;

    -- A list that is sent is never empty: an edit cannot leave a dispatch without lines (migration 120).
    IF p_dispatch_items IS NOT NULL AND cardinality(p_dispatch_items) = 0 THEN
        RAISE EXCEPTION 'A dispatch needs at least one line' USING ERRCODE = 'WH409';
    END IF;

    -- A number another dispatch holds is refused by name, under the lock and before anything is written
    -- (migration 120). dispatch_disp_no_key covers every row, so the check does too.
    IF p_dispatch_data->>'disp_no' IS NOT NULL AND EXISTS (
        SELECT 1 FROM dispatch d
        WHERE d.disp_no = p_dispatch_data->>'disp_no' AND d.id <> p_dispatch_id
    ) THEN
        RETURN jsonb_build_object(
            'success', false,
            'error_code', 'WH409',
            'reason', 'NUMBER_TAKEN',
            'number', p_dispatch_data->>'disp_no',
            'error', format('Dispatch number %s is already used', p_dispatch_data->>'disp_no')
        );
    END IF;

    -- Every line names a lot that exists and a whole quantity above zero.
    IF EXISTS (
        SELECT 1 FROM unnest(p_dispatch_items) AS new_item
        WHERE NOT EXISTS (
            SELECT 1 FROM goodsreceived_trl gt WHERE gt.id = (new_item->>'gr_trl_id')::uuid
        )
    ) THEN
        RAISE EXCEPTION 'Dispatch item does not exist in inventory' USING ERRCODE = 'WH409';
    END IF;
    IF EXISTS (
        SELECT 1 FROM unnest(p_dispatch_items) AS new_item
        WHERE new_item->>'disp_qty' IS NULL
           OR (new_item->>'disp_qty')::numeric <= 0
           OR (new_item->>'disp_qty')::numeric <> floor((new_item->>'disp_qty')::numeric)
    ) THEN
        RAISE EXCEPTION 'Dispatch quantity must be a whole number greater than 0' USING ERRCODE = 'WH409';
    END IF;

    -- A lot appears once in the dispatch lines (migration 87).
    IF EXISTS (
        SELECT 1 FROM unnest(p_dispatch_items) AS d
        GROUP BY (d->>'gr_trl_id')::uuid HAVING count(*) > 1
    ) THEN
        RAISE EXCEPTION 'The same lot appears twice in the dispatch lines' USING ERRCODE = 'WH409';
    END IF;

    -- A dispatch carries only its own customer's lots: a line this edit adds
    -- must belong to the dispatch customer, and the customer may change only
    -- when every line the edit leaves belongs to the new one. The receipts are
    -- key-share locked so update_grn cannot move one to another customer meanwhile.
    PERFORM gr.id
    FROM goodsreceived gr
    WHERE gr.id IN (
        SELECT gt.gr_id
        FROM unnest(p_dispatch_items) AS new_item
        JOIN goodsreceived_trl gt ON gt.id = (new_item->>'gr_trl_id')::uuid
        UNION
        SELECT dt.gr_id FROM dispatch_trl dt WHERE dt.disp_id = p_dispatch_id
    )
    FOR KEY SHARE OF gr;

    SELECT string_agg(gt.item_name || ' (' || gr.gr_no || ')', ', ')
    INTO v_foreign_lots
    FROM dispatch d
    JOIN LATERAL (
        -- Lines the edit leaves: the new list, or the present lines when no list is sent
        SELECT (new_item->>'gr_trl_id')::uuid AS gr_trl_id
        FROM unnest(p_dispatch_items) AS new_item
        UNION
        SELECT dt.gr_trl_id FROM dispatch_trl dt
        WHERE dt.disp_id = d.id AND p_dispatch_items IS NULL
    ) AS kept ON true
    JOIN goodsreceived_trl gt ON gt.id = kept.gr_trl_id
    JOIN goodsreceived gr ON gr.id = gt.gr_id
    WHERE d.id = p_dispatch_id
    AND gr.customer_id IS DISTINCT FROM COALESCE((p_dispatch_data->>'customer_id')::uuid, d.customer_id)
    AND (
        -- The header customer is changing
        d.customer_id IS DISTINCT FROM COALESCE((p_dispatch_data->>'customer_id')::uuid, d.customer_id)
        OR
        -- The line is being added
        NOT EXISTS (
            SELECT 1 FROM dispatch_trl dt
            WHERE dt.disp_id = d.id AND dt.gr_trl_id = kept.gr_trl_id
        )
    );

    IF v_foreign_lots IS NOT NULL THEN
        IF EXISTS (
            SELECT 1 FROM dispatch d
            WHERE d.id = p_dispatch_id
            AND d.customer_id IS DISTINCT FROM COALESCE((p_dispatch_data->>'customer_id')::uuid, d.customer_id)
        ) THEN
            RAISE EXCEPTION 'Cannot change the dispatch customer: items belong to another customer: %', v_foreign_lots USING ERRCODE = 'WH409';
        END IF;
        RAISE EXCEPTION 'Item belongs to another customer: %', v_foreign_lots USING ERRCODE = 'WH409';
    END IF;

    -- A dispatch made from a cart stays with the cart's customer (migration 87).
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

    -- A supervisor that is changed to another person must be someone who may supervise; one that stays
    -- is not asked again (migration 120).
    IF p_dispatch_data->>'supervisor_id' IS NOT NULL
       AND (p_dispatch_data->>'supervisor_id')::uuid IS DISTINCT FROM (SELECT d.supervisor_id FROM dispatch d WHERE d.id = p_dispatch_id)
       AND NOT EXISTS (
           SELECT 1 FROM user_profiles p
           WHERE p.id = (p_dispatch_data->>'supervisor_id')::uuid
             AND p.role IN ('admin', 'supervisor', 'staff')
       ) THEN
        RAISE EXCEPTION 'The supervisor must be an administrator, supervisor or staff member' USING ERRCODE = 'WH409';
    END IF;

    -- D2, D3 (migration 121, IST days everywhere). The date sent is "changed" when its day differs from the IST day of the
    -- stored date; when it is not changed the stored date is kept as it is (the header update below), so a legacy row with an
    -- odd time of day is not rewritten by the app sending its own day back. The number is changed when it differs from the
    -- stored text. Nothing is written before these checks.
    v_sent_day := (p_dispatch_data->>'disp_date')::date;
    IF v_sent_day IS NOT NULL THEN
        v_day_changed := v_sent_day IS DISTINCT FROM warehouse_security.business_date(v_stored_disp_date);
    END IF;
    v_no_changed := p_dispatch_data->>'disp_no' IS NOT NULL AND (p_dispatch_data->>'disp_no') IS DISTINCT FROM v_stored_disp_no;

    -- D2: a dispatch with a line on a live invoice keeps its date and number (the invoice's days are counted from them).
    IF v_day_changed OR v_no_changed THEN
        SELECT i.inv_no, i.inv_fin_year INTO v_inv_no, v_inv_year
        FROM invoice_trl it
        JOIN invoice i ON i.id = it.invoice_id AND i.deleted_at IS NULL
        JOIN dispatch_trl dt ON dt.id = it.disp_trl_id
        WHERE dt.disp_id = p_dispatch_id
        ORDER BY i.inv_fin_year, i.inv_no, i.id
        LIMIT 1;

        IF v_inv_no IS NOT NULL THEN
            v_changed_fields := '[]'::jsonb;
            IF v_day_changed THEN v_changed_fields := v_changed_fields || to_jsonb('disp_date'::text); END IF;
            IF v_no_changed THEN v_changed_fields := v_changed_fields || to_jsonb('disp_no'::text); END IF;
            RETURN warehouse_security.refuse('DISPATCH_INVOICED',
                format('Dispatch %s is on invoice %s. Its date and number can''t be changed. Delete or edit the invoice first.',
                       v_stored_disp_no, v_inv_no),
                jsonb_build_object('dispatch_no', v_stored_disp_no, 'invoice_no', v_inv_no,
                                   'inv_fin_year', v_inv_year, 'fields', v_changed_fields));
        END IF;
    END IF;

    -- D3: the same two date rules as a create. A changed day is checked against every line after the edit; an unchanged
    -- day only against the lines this edit adds, so a legacy back-dated dispatch stays editable. A request without a
    -- date is not checked.
    IF v_sent_day IS NOT NULL THEN
        IF v_day_changed AND v_sent_day > warehouse_security.business_date(now()) THEN
            RETURN warehouse_security.refuse('DISPATCH_DATE_FUTURE',
                format('A dispatch can''t be dated in the future. Today is %s.', to_char(warehouse_security.business_date(now()), 'YYYY-MM-DD')),
                jsonb_build_object('date', to_char(v_sent_day, 'YYYY-MM-DD'),
                                   'today', to_char(warehouse_security.business_date(now()), 'YYYY-MM-DD')));
        END IF;

        SELECT gr.gr_no, warehouse_security.business_date(gr.date)
        INTO v_late_gr_no, v_late_grn_day
        FROM goodsreceived gr
        JOIN goodsreceived_trl gt ON gt.gr_id = gr.id
        WHERE gt.id IN (
            SELECT (ni->>'gr_trl_id')::uuid
            FROM unnest(p_dispatch_items) AS ni
            WHERE v_day_changed
               OR NOT EXISTS (SELECT 1 FROM dispatch_trl dt
                              WHERE dt.disp_id = p_dispatch_id AND dt.gr_trl_id = (ni->>'gr_trl_id')::uuid)
            UNION
            SELECT dt.gr_trl_id FROM dispatch_trl dt
            WHERE dt.disp_id = p_dispatch_id AND p_dispatch_items IS NULL AND v_day_changed
        )
          AND warehouse_security.business_date(gr.date) > v_sent_day
        ORDER BY warehouse_security.business_date(gr.date) DESC, gr.gr_no DESC
        LIMIT 1;

        IF v_late_gr_no IS NOT NULL THEN
            RETURN warehouse_security.refuse('DISPATCH_BEFORE_GRN',
                format('The dispatch date %s is before GRN %s (%s).', to_char(v_sent_day, 'YYYY-MM-DD'), v_late_gr_no,
                       to_char(v_late_grn_day, 'YYYY-MM-DD')),
                jsonb_build_object('date', to_char(v_sent_day, 'YYYY-MM-DD'), 'gr_no', v_late_gr_no,
                                   'grn_date', to_char(v_late_grn_day, 'YYYY-MM-DD')));
        END IF;
    END IF;

    -- Update dispatch header if data provided (single statement - OK)
    IF p_dispatch_data IS NOT NULL THEN
        UPDATE dispatch SET
            disp_no = COALESCE(p_dispatch_data->>'disp_no', disp_no),
            disp_date = CASE WHEN v_day_changed THEN (p_dispatch_data->>'disp_date')::date::timestamptz ELSE disp_date END,
            registration = COALESCE(p_dispatch_data->>'registration', registration),
            customer_id = COALESCE((p_dispatch_data->>'customer_id')::uuid, customer_id),
            -- The stored names stay unless the customer or the supervisor changes; then they are the master
            -- tables' names, never the client's and never the old person's (migration 120). The old values are
            -- read here.
            customer_name = CASE
                WHEN p_dispatch_data->>'customer_id' IS NOT NULL
                     AND (p_dispatch_data->>'customer_id')::uuid IS DISTINCT FROM customer_id
                THEN COALESCE((SELECT c.name FROM customers c WHERE c.id = (p_dispatch_data->>'customer_id')::uuid), customer_name)
                ELSE customer_name
            END,
            supervisor_id = COALESCE((p_dispatch_data->>'supervisor_id')::uuid, supervisor_id),
            supervisor_name = CASE
                WHEN p_dispatch_data->>'supervisor_id' IS NOT NULL
                     AND (p_dispatch_data->>'supervisor_id')::uuid IS DISTINCT FROM supervisor_id
                THEN (SELECT COALESCE(p.name, p.display_name) FROM user_profiles p WHERE p.id = (p_dispatch_data->>'supervisor_id')::uuid)
                ELSE supervisor_name
            END,
            note = COALESCE(p_dispatch_data->>'note', note),
            updated_by = v_user_id,
            updated_at = NOW()
        WHERE id = p_dispatch_id;
    ELSIF p_dispatch_items IS NOT NULL THEN
        -- A save of lines alone moves the version token too (migration 122): the answer carries it and a stale form is refused.
        UPDATE dispatch SET updated_by = v_user_id, updated_at = NOW() WHERE id = p_dispatch_id;
    END IF;

    -- Handle items if provided
    IF p_dispatch_items IS NOT NULL THEN
        -- ========== STEP 1: VALIDATION - Check invoiced items ==========
        -- Check if any items being modified or deleted are invoiced
        SELECT string_agg(gt.item_name, ', ')
        INTO v_invoiced_items
        FROM dispatch_trl dt
        JOIN goodsreceived_trl gt ON gt.id = dt.gr_trl_id
        WHERE dt.disp_id = p_dispatch_id
        AND EXISTS (
            -- Only a live invoice counts, the rule get_dispatch_details shows (migration 120).
            SELECT 1 FROM invoice_trl it
            JOIN invoice inv ON inv.id = it.invoice_id AND inv.deleted_at IS NULL
            WHERE it.disp_trl_id = dt.id
        )
        AND (
            -- Item is being deleted (not in new list)
            NOT EXISTS (
                SELECT 1 FROM unnest(p_dispatch_items) AS new_item
                WHERE (new_item->>'gr_trl_id')::uuid = dt.gr_trl_id
            )
            OR
            -- Item qty is being changed
            EXISTS (
                SELECT 1 FROM unnest(p_dispatch_items) AS new_item
                WHERE (new_item->>'gr_trl_id')::uuid = dt.gr_trl_id
                AND (new_item->>'disp_qty')::integer != dt.disp_qty
            )
        );

        IF v_invoiced_items IS NOT NULL THEN
            RAISE EXCEPTION 'Cannot modify invoiced items: %', v_invoiced_items USING ERRCODE = 'WH409';
        END IF;

        -- ========== STEP 2: LOCK all affected GRN items ==========
        PERFORM gt.id
        FROM goodsreceived_trl gt
        WHERE gt.id IN (
            -- Existing items in dispatch
            SELECT dt.gr_trl_id FROM dispatch_trl dt WHERE dt.disp_id = p_dispatch_id
            UNION
            -- New items being added
            SELECT (new_item->>'gr_trl_id')::uuid FROM unnest(p_dispatch_items) AS new_item
        )
        FOR UPDATE OF gt;

        -- The order lines this edit may change are locked next, in id order, before any dispatch line or order line is written
        -- (migration 121): the lines of these lots in the source order or in an open order, and the lines the dispatch's own
        -- lines recorded. A dispatch create or delete on the same lots and lines then waits instead of deadlocking.
        PERFORM oi.id
        FROM order_items oi
        WHERE oi.grn_items_id IN (SELECT dt.gr_trl_id FROM dispatch_trl dt WHERE dt.disp_id = p_dispatch_id AND dt.gr_trl_id IS NOT NULL
                                  UNION
                                  SELECT (new_item->>'gr_trl_id')::uuid FROM unnest(p_dispatch_items) AS new_item)
          AND (oi.order_id = (SELECT d.source_order_id FROM dispatch d WHERE d.id = p_dispatch_id)
               OR EXISTS (SELECT 1 FROM orders o WHERE o.id = oi.order_id AND o.status = 'OPEN' AND o.deleted_at IS NULL)
               OR oi.id IN (SELECT dt.source_order_item_id FROM dispatch_trl dt WHERE dt.disp_id = p_dispatch_id))
        ORDER BY oi.id
        FOR UPDATE OF oi;

        -- The lots of a deleted receipt are not taken from: a line this edit adds or raises is refused
        -- (migration 120). A line it leaves as it is stays.
        SELECT string_agg(gt.item_name || ' (' || gr.gr_no || ')', ', ')
        INTO v_deleted_lots
        FROM unnest(p_dispatch_items) AS new_item
        JOIN goodsreceived_trl gt ON gt.id = (new_item->>'gr_trl_id')::uuid
        JOIN goodsreceived gr ON gr.id = gt.gr_id
        LEFT JOIN dispatch_trl dt ON dt.disp_id = p_dispatch_id AND dt.gr_trl_id = gt.id
        WHERE gr.deleted_at IS NOT NULL
          AND (dt.id IS NULL OR (new_item->>'disp_qty')::integer > dt.disp_qty);

        IF v_deleted_lots IS NOT NULL THEN
            RAISE EXCEPTION 'Item belongs to a deleted GRN: %', v_deleted_lots USING ERRCODE = 'WH409';
        END IF;

        -- ========== STEP 3: VALIDATE stock for increases and new items ==========
        SELECT string_agg(
            gt.item_name || ' (Available: ' || gt.stock || ', Need: ' || needed.additional || ')',
            ', '
        )
        INTO v_insufficient_stock
        FROM (
            -- New items need full qty
            SELECT (new_item->>'gr_trl_id')::uuid AS gr_trl_id,
                   (new_item->>'disp_qty')::integer AS additional
            FROM unnest(p_dispatch_items) AS new_item
            WHERE NOT EXISTS (
                SELECT 1 FROM dispatch_trl dt
                WHERE dt.disp_id = p_dispatch_id
                AND dt.gr_trl_id = (new_item->>'gr_trl_id')::uuid
            )
            UNION ALL
            -- Existing items with qty increase need the difference
            SELECT dt.gr_trl_id,
                   (new_item->>'disp_qty')::integer - dt.disp_qty AS additional
            FROM dispatch_trl dt
            JOIN unnest(p_dispatch_items) AS new_item ON (new_item->>'gr_trl_id')::uuid = dt.gr_trl_id
            WHERE dt.disp_id = p_dispatch_id
            AND (new_item->>'disp_qty')::integer > dt.disp_qty
        ) AS needed
        JOIN goodsreceived_trl gt ON gt.id = needed.gr_trl_id
        WHERE gt.stock < needed.additional;

        IF v_insufficient_stock IS NOT NULL THEN
            RAISE EXCEPTION 'Insufficient stock: %', v_insufficient_stock USING ERRCODE = 'WH409';
        END IF;

        -- ========== STEP 4: Collect affected GR_IDs for out_of_stock update ==========
        SELECT ARRAY(
            SELECT DISTINCT gr_id FROM (
                SELECT dt.gr_id FROM dispatch_trl dt WHERE dt.disp_id = p_dispatch_id
                UNION
                SELECT gt.gr_id FROM unnest(p_dispatch_items) AS new_item
                JOIN goodsreceived_trl gt ON gt.id = (new_item->>'gr_trl_id')::uuid
            ) AS all_gr_ids
        ) INTO v_affected_gr_ids;

        -- ========== D4: the lines as they were before this edit (migration 121) ==========
        -- What each line took from an order (cart_quantity_consumed) is lost when the line is removed below, so it is read
        -- here, with the lots already locked (step 2). A line without a lot is never touched by an edit.
        SELECT COALESCE(jsonb_agg(jsonb_build_object(
                   'lot', dt.gr_trl_id, 'qty', dt.disp_qty,
                   'consumed', LEAST(COALESCE(dt.cart_quantity_consumed, 0), dt.disp_qty), 'item', dt.source_order_item_id)), '[]'::jsonb)
        INTO v_old_lines
        FROM dispatch_trl dt
        WHERE dt.disp_id = p_dispatch_id AND dt.gr_trl_id IS NOT NULL;

        -- ========== STEP 5: BULK restore stock for DELETED items ==========
        UPDATE goodsreceived_trl gt
        SET stock = gt.stock + dt.disp_qty
        FROM dispatch_trl dt
        WHERE dt.disp_id = p_dispatch_id
        AND gt.id = dt.gr_trl_id
        AND NOT EXISTS (
            SELECT 1 FROM unnest(p_dispatch_items) AS new_item
            WHERE (new_item->>'gr_trl_id')::uuid = dt.gr_trl_id
        );

        -- ========== STEP 6: BULK log movements for DELETED items ==========
        INSERT INTO stock_movements (gr_trl_id, movement_type, quantity, reference_id, reference_type, balance_before, balance_after, created_by, notes)
        SELECT
            dt.gr_trl_id,
            'return',
            dt.disp_qty,
            p_dispatch_id,
            'dispatch_item_delete',
            gt.stock - dt.disp_qty,  -- balance_before (stock was already restored)
            gt.stock,                 -- balance_after
            v_user_id,
            'Item removed from dispatch (line ' || dt.id::text || ')'
        FROM dispatch_trl dt
        JOIN goodsreceived_trl gt ON gt.id = dt.gr_trl_id
        WHERE dt.disp_id = p_dispatch_id
        AND NOT EXISTS (
            SELECT 1 FROM unnest(p_dispatch_items) AS new_item
            WHERE (new_item->>'gr_trl_id')::uuid = dt.gr_trl_id
        );

        -- ========== STEP 7: BULK delete removed items ==========
        -- A line without a lot (old data) is not in the list the app sends and is never removed by an edit
        -- (migration 120). The lines of a cancelled invoice, which the guard above does not count, are kept with
        -- their amounts when the dispatch line goes: invoice_trl.disp_trl_id is emptied by its foreign key
        -- (ON DELETE SET NULL, migration 120).
        DELETE FROM dispatch_trl dt
        WHERE dt.disp_id = p_dispatch_id
        AND dt.gr_trl_id IS NOT NULL
        AND NOT EXISTS (
            SELECT 1 FROM unnest(p_dispatch_items) AS new_item
            WHERE (new_item->>'gr_trl_id')::uuid = dt.gr_trl_id
        );

        -- ========== STEP 8: BULK update stock for QTY CHANGES ==========
        UPDATE goodsreceived_trl gt
        SET stock = gt.stock - ((new_item->>'disp_qty')::integer - dt.disp_qty)
        FROM dispatch_trl dt
        JOIN unnest(p_dispatch_items) AS new_item ON (new_item->>'gr_trl_id')::uuid = dt.gr_trl_id
        WHERE dt.disp_id = p_dispatch_id
        AND gt.id = dt.gr_trl_id
        AND (new_item->>'disp_qty')::integer != dt.disp_qty;

        -- ========== STEP 9: BULK log movements for QTY CHANGES ==========
        INSERT INTO stock_movements (gr_trl_id, movement_type, quantity, reference_id, reference_type, balance_before, balance_after, created_by, notes)
        SELECT
            dt.gr_trl_id,
            CASE WHEN (new_item->>'disp_qty')::integer > dt.disp_qty THEN 'dispatch' ELSE 'return' END,
            -((new_item->>'disp_qty')::integer - dt.disp_qty),
            p_dispatch_id,
            'dispatch_update',
            gt.stock + ((new_item->>'disp_qty')::integer - dt.disp_qty),  -- balance_before
            gt.stock,  -- balance_after (already updated)
            v_user_id,
            format('Qty changed from %s to %s (line %s)', dt.disp_qty, (new_item->>'disp_qty')::integer, dt.id)
        FROM dispatch_trl dt
        JOIN unnest(p_dispatch_items) AS new_item ON (new_item->>'gr_trl_id')::uuid = dt.gr_trl_id
        JOIN goodsreceived_trl gt ON gt.id = dt.gr_trl_id
        WHERE dt.disp_id = p_dispatch_id
        AND (new_item->>'disp_qty')::integer != dt.disp_qty;

        -- ========== STEP 10: BULK update dispatch_trl quantities ==========
        UPDATE dispatch_trl dt
        SET disp_qty = (new_item->>'disp_qty')::integer
        FROM unnest(p_dispatch_items) AS new_item
        WHERE dt.disp_id = p_dispatch_id
        AND dt.gr_trl_id = (new_item->>'gr_trl_id')::uuid
        AND dt.disp_qty != (new_item->>'disp_qty')::integer;

        -- ========== STEP 11: BULK deduct stock for NEW items ==========
        UPDATE goodsreceived_trl gt
        SET stock = gt.stock - (new_item->>'disp_qty')::integer
        FROM unnest(p_dispatch_items) AS new_item
        WHERE gt.id = (new_item->>'gr_trl_id')::uuid
        AND NOT EXISTS (
            SELECT 1 FROM dispatch_trl dt
            WHERE dt.disp_id = p_dispatch_id
            AND dt.gr_trl_id = (new_item->>'gr_trl_id')::uuid
        );

        -- ========== STEP 12: BULK insert NEW dispatch items, and log a
        -- movement for exactly the rows inserted (migration 67) ==========
        -- A line added to a dispatch from the cart is marked 'cart'. What it takes from the order's line is recorded on it
        -- by the D4 step below (migration 121), and a deletion gives that back.
        WITH inserted AS (
            INSERT INTO dispatch_trl (disp_id, gr_trl_id, gr_id, disp_qty, source_type)
            SELECT
                p_dispatch_id,
                (new_item->>'gr_trl_id')::uuid,
                gt.gr_id,
                (new_item->>'disp_qty')::integer,
                CASE WHEN EXISTS (SELECT 1 FROM dispatch d WHERE d.id = p_dispatch_id AND d.source_order_id IS NOT NULL)
                     THEN 'cart' ELSE 'direct' END
            FROM unnest(p_dispatch_items) WITH ORDINALITY AS t(new_item, ord)
            JOIN goodsreceived_trl gt ON gt.id = (new_item->>'gr_trl_id')::uuid
            WHERE NOT EXISTS (
                SELECT 1 FROM dispatch_trl dt
                WHERE dt.disp_id = p_dispatch_id
                AND dt.gr_trl_id = (new_item->>'gr_trl_id')::uuid
            )
            ORDER BY t.ord
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

        -- ========== D4: keep the order in step with the edited lines (migration 121) ==========
        -- A line lowered or removed gives back the bags it held from the order that are no longer dispatched, GREATEST(held -
        -- new quantity, 0) (migration 122; what a legacy line holds is capped at its old quantity). A source order that any
        -- line gives back to is opened before the lines are walked. A line raised or added takes the extra from the order's line for that lot (the dispatch's source order, else the
        -- customer's OPEN order), at most what that line still asks for; the stock is taken in full either way. The cart's
        -- lines are locked, the order itself is not (the lock order stays dispatch, lots, order lines, order). A source
        -- order that is still not OPEN (nothing was given back to it) is not taken from. Both are done by the dispatch whatever the state of the business (a
        -- deactivated business is dispatched too). What was taken goes into the order's change log as a dispatch reduction; what was given back as a
        -- quantity change, one entry per order after all give-backs.
        SELECT d.customer_id, d.source_order_id, d.disp_no
        INTO v_cust_id, v_src_order_id, v_disp_no_now
        FROM dispatch d
        WHERE d.id = p_dispatch_id;

        -- A source order that any line of this edit gives bags back to is opened (status OPEN, deleted_at cleared) the way the
        -- dispatch delete opens it, before the lines are walked: a raise later in the same edit then takes from it whatever
        -- the order of the lots.
        IF v_src_order_id IS NOT NULL AND EXISTS (
            SELECT 1
            FROM (SELECT (x.e->>'lot')::uuid AS lot, (x.e->>'qty')::integer AS qty, (x.e->>'consumed')::integer AS consumed
                  FROM jsonb_array_elements(v_old_lines) AS x(e)) AS o
            LEFT JOIN (SELECT (ni->>'gr_trl_id')::uuid AS lot, (ni->>'disp_qty')::integer AS qty
                       FROM unnest(p_dispatch_items) AS ni) AS n ON n.lot = o.lot
            WHERE COALESCE(n.qty, 0) < o.qty AND o.consumed > COALESCE(n.qty, 0)) THEN
            UPDATE orders
            SET status = 'OPEN',
                deleted_at = NULL,
                deleted_by = NULL,
                updated_by = v_user_id,
                updated_at = now()
            WHERE id = v_src_order_id
              AND (status IS DISTINCT FROM 'OPEN' OR deleted_at IS NOT NULL);
        END IF;

        FOR v_sync IN
            SELECT COALESCE(o.lot, n.lot) AS lot,
                   COALESCE(o.qty, 0) AS old_qty,
                   COALESCE(n.qty, 0) AS new_qty,
                   COALESCE(o.consumed, 0) AS consumed,
                   o.item AS old_item
            FROM (SELECT (x.e->>'lot')::uuid AS lot, (x.e->>'qty')::integer AS qty,
                         (x.e->>'consumed')::integer AS consumed, NULLIF(x.e->>'item', '')::uuid AS item
                  FROM jsonb_array_elements(v_old_lines) AS x(e)) AS o
            FULL JOIN (SELECT (ni->>'gr_trl_id')::uuid AS lot, (ni->>'disp_qty')::integer AS qty
                       FROM unnest(p_dispatch_items) AS ni) AS n ON n.lot = o.lot
            WHERE COALESCE(o.qty, 0) <> COALESCE(n.qty, 0)
            ORDER BY COALESCE(o.lot, n.lot)
        LOOP
            IF v_sync.new_qty < v_sync.old_qty THEN
                -- Lowered or removed (migration 122): give back only the bags that came from the order and are no longer
                -- dispatched, what the line held above its new quantity. A line raised past its order and then lowered
                -- gives back nothing until it drops below what it took from the order.
                v_back := GREATEST(v_sync.consumed - v_sync.new_qty, 0);
                v_gave := 0;
                IF v_back > 0 THEN
                    -- The give-back goes where the delete's goes (migration 122), whatever the order's status:
                    -- the dispatch's source order, else the order of the recorded order line, else the customer's OPEN order.
                    -- restore_to_order answers NULL when no order could be used: nothing was given.
                    v_use_src := v_src_order_id;
                    v_use_item := v_sync.old_item;
                    IF v_src_order_id IS NULL AND v_use_item IS NOT NULL THEN
                        -- A direct dispatch: only a recorded order line on an OPEN order is given back to (as migration 121 did).
                        IF NOT EXISTS (SELECT 1 FROM order_items oi JOIN orders o ON o.id = oi.order_id
                                       WHERE oi.id = v_use_item AND o.status = 'OPEN' AND o.deleted_at IS NULL) THEN
                            v_use_item := NULL;
                        END IF;
                    END IF;
                    v_cart := warehouse_security.restore_to_order(
                        p_dispatch_id, v_use_src, v_use_item, v_cust_id, v_sync.lot, v_back, v_user_id);
                    IF v_cart IS NOT NULL THEN
                        v_gave := v_back;
                        v_given_back := v_given_back + v_back;
                        IF NOT (v_cart = ANY (v_given_carts)) THEN
                            v_given_carts := v_given_carts || v_cart;
                        END IF;
                    END IF;
                END IF;
                -- A line that stays holds no more than its new quantity (cart_quantity_consumed <= disp_qty).
                IF v_sync.new_qty > 0 AND (v_gave > 0 OR v_sync.consumed > v_sync.new_qty) THEN
                    UPDATE dispatch_trl
                    SET cart_quantity_consumed = LEAST(v_sync.consumed, v_sync.new_qty)
                    WHERE disp_id = p_dispatch_id AND gr_trl_id = v_sync.lot;
                END IF;
            ELSE
                -- Raised or added: take the extra from the order's line for the lot, if there is one.
                v_take := 0;
                v_cart := NULL;
                v_line_id := NULL;
                IF v_src_order_id IS NOT NULL THEN
                    SELECT o.id INTO v_cart
                    FROM orders o
                    WHERE o.id = v_src_order_id AND o.status = 'OPEN' AND o.deleted_at IS NULL;
                ELSE
                    SELECT o.id INTO v_cart
                    FROM orders o
                    WHERE o.customer_id = v_cust_id AND o.status = 'OPEN' AND o.deleted_at IS NULL
                    ORDER BY o.created_at, o.id
                    LIMIT 1;
                END IF;

                IF v_cart IS NOT NULL THEN
                    SELECT oi.id, oi.requested_quantity, oi.fulfilled_quantity
                    INTO v_line_id, v_line_qty, v_line_fulfilled
                    FROM order_items oi
                    WHERE oi.order_id = v_cart AND oi.grn_items_id = v_sync.lot
                    LIMIT 1
                    FOR UPDATE;
                END IF;

                IF v_line_id IS NOT NULL THEN
                    v_take := LEAST(v_line_qty, v_sync.new_qty - v_sync.old_qty);
                    v_new_line_qty := v_line_qty - v_take;
                    -- The dispatch line records the order line before a used-up line is deleted (as the dispatch create does):
                    -- the foreign key then empties source_order_item_id with the line, and nothing points at a line that is
                    -- gone. At most the line's new quantity is held (cart_quantity_consumed <= disp_qty).
                    UPDATE dispatch_trl
                    SET cart_quantity_consumed = LEAST(LEAST(COALESCE(cart_quantity_consumed, 0), v_sync.old_qty) + v_take, v_sync.new_qty),
                        source_order_item_id = COALESCE(source_order_item_id, v_line_id)
                    WHERE disp_id = p_dispatch_id AND gr_trl_id = v_sync.lot;

                    IF v_new_line_qty = 0 THEN
                        DELETE FROM order_items WHERE id = v_line_id;
                    ELSIF v_src_order_id IS NOT NULL THEN
                        UPDATE order_items
                        SET requested_quantity = v_new_line_qty,
                            fulfilled_quantity = 0,
                            item_status = 'pending',
                            updated_at = NOW()
                        WHERE id = v_line_id;
                    ELSE
                        UPDATE order_items
                        SET requested_quantity = v_new_line_qty,
                            fulfilled_quantity = GREATEST(0, COALESCE(v_line_fulfilled, 0) - v_take)
                        WHERE id = v_line_id;
                    END IF;

                    INSERT INTO order_revisions (order_id, changed_at, changed_by, action, entry)
                    VALUES (v_cart, clock_timestamp(), v_user_id, 'auto_quantity_reduction', jsonb_build_object(
                        'action', 'auto_quantity_reduction',
                        'timestamp', NOW(),
                        'by', v_user_id,
                        'dispatch_id', p_dispatch_id,
                        'dispatch_no', v_disp_no_now,
                        'grn_item_id', v_sync.lot,
                        'previous_quantity', v_line_qty,
                        'new_quantity', v_new_line_qty));

                    v_taken := v_taken + v_take;
                END IF;
            END IF;
        END LOOP;

        FOREACH v_cart IN ARRAY v_given_carts
        LOOP
            PERFORM warehouse_security.record_order_revision(v_cart, v_user_id, 'UPDATE',
                jsonb_build_object('dispatch_id', p_dispatch_id, 'dispatch_no', v_disp_no_now, 'source', 'dispatch_edit'));
        END LOOP;

        -- ========== STEP 14: BULK update out_of_stock status ==========
        UPDATE goodsreceived gr
        SET out_of_stock = NOT EXISTS (
            SELECT 1 FROM goodsreceived_trl grt
            WHERE grt.gr_id = gr.id AND grt.stock > 0
        )
        WHERE gr.id = ANY(v_affected_gr_ids)
          -- Only a GRN whose flag really changes is touched (migration 121), so an unrelated dispatch does not move its
          -- version token and an open GRN edit is not made stale by it.
          AND gr.out_of_stock IS DISTINCT FROM (NOT EXISTS (
            SELECT 1 FROM goodsreceived_trl grt
            WHERE grt.gr_id = gr.id AND grt.stock > 0
        ));

    END IF;

    -- ========== Build response (single query) ==========
    SELECT ARRAY(
        SELECT jsonb_build_object(
            'id', dt.id,
            'gr_trl_id', dt.gr_trl_id,
            'gr_id', dt.gr_id,
            'disp_qty', dt.disp_qty,
            'item_id', grt.item_id,
            'item_name', grt.item_name,
            'packaging', grt.packaging,
            'weight', grt.weight,
            'rack', grt.rack
        )
        FROM dispatch_trl dt
        JOIN goodsreceived_trl grt ON grt.id = dt.gr_trl_id
        WHERE dt.disp_id = p_dispatch_id
    ) INTO v_dispatch_items_result;

    SELECT d.updated_at INTO v_new_updated_at FROM dispatch d WHERE d.id = p_dispatch_id;

    v_result := jsonb_build_object(
        'success', true,
        'dispatch_id', p_dispatch_id,
        'dispatch_items', v_dispatch_items_result,
        'updated_at', v_new_updated_at,
        'order_sync', jsonb_build_object('given_back', v_given_back, 'taken', v_taken)
    );

    -- The answer is kept for the 7 days a resend is answered from it, as the dispatch create answer is (migration
    -- 120). A code that another function or user holds is left alone unless it has expired.
    IF v_request_key IS NOT NULL THEN
        INSERT INTO idempotency_keys (idempotency_key, rpc_function, response, created_by, expires_at)
        VALUES (v_request_key, 'update_dispatch_smart', v_result, v_user_id, now() + interval '7 days')
        ON CONFLICT (idempotency_key) DO UPDATE SET
            rpc_function = EXCLUDED.rpc_function,
            response = EXCLUDED.response,
            created_by = EXCLUDED.created_by,
            created_at = now(),
            expires_at = EXCLUDED.expires_at
        WHERE idempotency_keys.expires_at <= now()
           OR (idempotency_keys.rpc_function = EXCLUDED.rpc_function
               AND idempotency_keys.created_by IS NOT DISTINCT FROM EXCLUDED.created_by);
    END IF;

    RETURN v_result;

EXCEPTION
    WHEN OTHERS THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', SQLERRM
        );
END;
$$;
