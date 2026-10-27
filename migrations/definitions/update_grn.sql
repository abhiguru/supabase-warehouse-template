-- public.update_grn: the definition setup applies after the numbered migrations whenever this file's checksum changes
-- (scripts/migration-plan.mjs, table warehouse_migrations.definitions). Edit the function here, never in a new migration.
-- Starts as the function migrations 000 to 126 leave (the numbered files that patched it stay as they are, never edited).
CREATE OR REPLACE FUNCTION public.update_grn(p_grn_id uuid, p_gr_no character varying DEFAULT NULL::character varying, p_date timestamp with time zone DEFAULT NULL::timestamp with time zone, p_customer_id uuid DEFAULT NULL::uuid, p_customer_name character varying DEFAULT NULL::character varying, p_sender_id uuid DEFAULT NULL::uuid, p_sender_name character varying DEFAULT NULL::character varying, p_supervisor_id uuid DEFAULT NULL::uuid, p_supervisor_name character varying DEFAULT NULL::character varying, p_registration character varying DEFAULT NULL::character varying, p_note character varying DEFAULT NULL::character varying, p_leon boolean DEFAULT NULL::boolean, p_pricing_mode character varying DEFAULT NULL::character varying, p_items jsonb DEFAULT '[]'::jsonb, p_images jsonb DEFAULT '[]'::jsonb, p_duration_mode character varying DEFAULT NULL::character varying, p_idempotency_key text DEFAULT NULL::text, p_rates jsonb DEFAULT NULL::jsonb, p_expected_updated_at timestamp with time zone DEFAULT NULL::timestamp with time zone)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'extensions', 'utils', 'pg_temp'
 SET jit TO 'off'
AS $function$
DECLARE
    v_user_id uuid;
    v_user_profile_id uuid;
    v_user_role text;
    v_item jsonb;
    v_image jsonb;
    v_grn_trl_item_id uuid;
    v_image_id uuid;
    v_current_qty int;
    v_current_stock int;
    v_item_name_from_db varchar;
    v_dispatched_qty int;
    v_items_updated int := 0;
    v_items_added int := 0;
    v_items_deleted int := 0;
    v_images_updated int := 0;
    v_images_added int := 0;
    v_images_deleted int := 0;
    v_items_skipped_stock jsonb := '[]'::jsonb;
    v_existing_grn_item_ids uuid[];
    v_provided_grn_item_ids uuid[];
    v_items_to_delete uuid[];
    v_item_index int;
    v_item_mapping jsonb := '[]'::jsonb;
    v_resolved_item_id uuid;
    v_existing_image_ids uuid[];
    v_kept_image_ids uuid[];
    v_final_grn_data jsonb;
    v_grn_items jsonb := '[]'::jsonb;
    v_grn_images jsonb;
    v_temp_item jsonb;
    v_grn_header jsonb;
    v_item_master_id uuid;
    v_item_name varchar;
    v_cached_response jsonb;
    v_result jsonb;
    v_line_rows integer;
    v_bad_line text;
    v_rate_failure jsonb;
    v_detail text;
    v_stored_updated_at timestamptz;
    v_stored_gr_no text;
    v_stored_date timestamptz;
    v_stored_invoiced boolean;
    v_stored_customer_name text;
    v_is_invoiced boolean;
    v_inv_no integer;
    v_inv_year integer;
    v_inv_no2 integer;
    v_inv_year2 integer;
    v_first_day date;
    v_first_disp_no text;
    v_chk record;
    v_changed_fields jsonb;
    v_lines_before jsonb;
    v_type_before text;
    v_type_after text;
    v_dropped_count integer := 0;
    v_dropped_items text[] := ARRAY[]::text[];
    v_dropped_rows jsonb := '[]'::jsonb;
    v_would_drop_count integer := 0;
    v_would_drop_items text[] := ARRAY[]::text[];
BEGIN
  PERFORM warehouse_security.authorize_rpc('update_grn',jsonb_build_object('p_grn_id',p_grn_id,'p_customer_id',p_customer_id));
  -- Migration 90: rates typed on the GRN sheet are an administrator's or a supervisor's.
  IF p_rates IS NOT NULL AND warehouse_security.active_role() = 'staff' THEN
    RETURN warehouse_security.rate_failure('RATES_MANAGER_ONLY', 'Only administrators and supervisors can set rates on a GRN');
  END IF;
  -- Migration 95: a line's name and packaging fit the receipt columns (80 and 40 characters, as the catalog).
  IF jsonb_typeof(p_items) = 'array' THEN
    v_item_index := 0;
    FOR v_item IN SELECT e FROM jsonb_array_elements(p_items) AS e LOOP
      IF jsonb_typeof(v_item->'item_name') = 'string' AND char_length(v_item->>'item_name') > 80 THEN
        RETURN warehouse_security.grn_rate_failure('item_name_too_long',
          'An item name can have at most 80 characters', jsonb_build_object('limit', 80, 'index', v_item_index));
      END IF;
      IF jsonb_typeof(v_item->'packaging') = 'string' AND char_length(v_item->>'packaging') > 40 THEN
        RETURN warehouse_security.grn_rate_failure('packaging_too_long',
          'Packaging can have at most 40 characters', jsonb_build_object('limit', 40, 'index', v_item_index));
      END IF;
      v_item_index := v_item_index + 1;
    END LOOP;
  END IF;
    -- Migration 121 (D13): the registration fits the column (20 characters), as the item name and packaging fit theirs.
    IF p_registration IS NOT NULL AND char_length(p_registration) > 20 THEN
        RETURN warehouse_security.grn_rate_failure('registration_too_long',
          'Registration can have at most 20 characters', jsonb_build_object('limit', 20));
    END IF;

    v_user_id := auth.uid();

    IF v_user_id IS NULL THEN
        RETURN jsonb_build_object(
            'success', false,
            'message', 'Authentication required'
        );
    END IF;

    SELECT id, role INTO v_user_profile_id, v_user_role
    FROM user_profiles
    WHERE auth_user_id = v_user_id;

    IF v_user_profile_id IS NULL THEN
        RETURN jsonb_build_object(
            'success', false,
            'message', 'User profile not found'
        );
    END IF;

    IF v_user_role NOT IN ('admin', 'supervisor', 'staff') THEN
        RETURN jsonb_build_object(
            'success', false,
            'message', 'Insufficient permissions. Only admin and supervisor can update GRNs'
        );
    END IF;

    -- IDEMPOTENCY CHECK: a repeated save answers with the stored result (migration 47)
    IF p_idempotency_key IS NOT NULL THEN
        PERFORM pg_advisory_xact_lock(71040);

        SELECT response INTO v_cached_response
        FROM idempotency_keys
        WHERE idempotency_key = p_idempotency_key
          AND rpc_function = 'update_grn'
          AND created_by = v_user_profile_id
          AND response #>> '{grn,id}' = p_grn_id::text
          AND expires_at > now();

        IF v_cached_response IS NOT NULL THEN
            RETURN v_cached_response || jsonb_build_object('idempotent', true);
        END IF;
    END IF;

    IF NOT EXISTS (SELECT 1 FROM goodsreceived WHERE id = p_grn_id) THEN
        RETURN jsonb_build_object(
            'success', false,
            'message', 'GRN not found'
        );
    END IF;

    PERFORM warehouse_security.require_person_supervisor(p_supervisor_id::text,
      (SELECT supervisor_id FROM goodsreceived WHERE id = p_grn_id));

    IF p_gr_no IS NOT NULL AND warehouse_security.is_blank_text(p_gr_no) THEN
        RETURN jsonb_build_object(
            'success', false,
            'message', 'GRN number is required'
        );
    END IF;

    -- Migration 121 (D6): the number of a GRN cannot be changed (to correct a wrong number, delete the GRN and enter it again).
    -- The stored number sent back, or no number, is fine.
    IF p_gr_no IS NOT NULL AND p_gr_no IS DISTINCT FROM (SELECT g.gr_no FROM goodsreceived g WHERE g.id = p_grn_id) THEN
        RETURN warehouse_security.refuse('GRN_NUMBER_LOCKED',
            'The GRN number can''t be changed. Delete the GRN and enter it again.',
            jsonb_build_object('gr_no', (SELECT g.gr_no FROM goodsreceived g WHERE g.id = p_grn_id), 'requested', p_gr_no));
    END IF;

    IF p_gr_no IS NOT NULL AND EXISTS (
        SELECT 1 FROM goodsreceived
        WHERE gr_no = p_gr_no AND id != p_grn_id
    ) THEN
        RETURN jsonb_build_object(
            'success', false,
            'message', 'GRN number already exists: ' || p_gr_no
        );
    END IF;

    BEGIN
        PERFORM pg_advisory_xact_lock(71040);

        -- The GRN row is locked and its version token compared (migration 121, D1): a GRN that changed after the caller read it
        -- is not saved over; nothing is written. This is after the saved-answer lookup above, so a retry of this user's own
        -- committed save is answered from it and never refused for what its first try changed. No token (an older app,
        -- fas-sync): no check.
        SELECT g.updated_at, g.gr_no, g.date, COALESCE(g.invoiced, false), g.customer_name
        INTO v_stored_updated_at, v_stored_gr_no, v_stored_date, v_stored_invoiced, v_stored_customer_name
        FROM goodsreceived g
        WHERE g.id = p_grn_id
        FOR UPDATE;

        IF NOT FOUND THEN
            RETURN jsonb_build_object(
                'success', false,
                'message', 'GRN not found'
            );
        END IF;

        IF p_expected_updated_at IS NOT NULL
           AND date_trunc('milliseconds', v_stored_updated_at) IS DISTINCT FROM date_trunc('milliseconds', p_expected_updated_at) THEN
            RETURN warehouse_security.refuse('STALE_RECORD', 'Someone else changed this GRN. Open it again.',
                jsonb_build_object('what', 'grn', 'id', p_grn_id,
                                   'expected_updated_at', p_expected_updated_at, 'current_updated_at', v_stored_updated_at));
        END IF;

        IF p_customer_id IS NOT NULL AND EXISTS (
            SELECT 1 FROM goodsreceived
            WHERE id = p_grn_id AND customer_id IS DISTINCT FROM p_customer_id
        ) THEN
            IF EXISTS (SELECT 1 FROM customers WHERE id = p_customer_id AND deleted_at IS NOT NULL) THEN
                RAISE EXCEPTION 'Business is not active' USING ERRCODE = 'P0001';
            END IF;
            IF EXISTS (SELECT 1 FROM customers WHERE id = p_customer_id AND active = false) THEN
                RAISE EXCEPTION 'This business is deactivated. Activate it in Customers to receive new goods.' USING ERRCODE = 'P0001';
            END IF;
            PERFORM 1 FROM goodsreceived WHERE id = p_grn_id FOR UPDATE;

            IF EXISTS (SELECT 1 FROM dispatch_trl WHERE gr_id = p_grn_id)
               OR EXISTS (SELECT 1 FROM invoice WHERE gr_id = p_grn_id)
               OR EXISTS (
                   SELECT 1 FROM order_items oi
                   JOIN orders o ON o.id = oi.order_id
                   JOIN goodsreceived_trl gt ON gt.id = oi.grn_items_id
                   WHERE gt.gr_id = p_grn_id AND o.deleted_at IS NULL
               ) THEN
                RAISE EXCEPTION 'Cannot change the customer of a GRN that has dispatches, invoices or order items';
            END IF;
        END IF;
        IF p_pricing_mode IS NOT NULL AND EXISTS (
            SELECT 1 FROM goodsreceived
            WHERE id = p_grn_id AND COALESCE(pricing_mode, 'MONTHLY') IS DISTINCT FROM p_pricing_mode
        ) THEN
            PERFORM 1 FROM goodsreceived WHERE id = p_grn_id FOR UPDATE;

            IF EXISTS (SELECT 1 FROM invoice WHERE gr_id = p_grn_id AND deleted_at IS NULL)
               OR EXISTS (
                   SELECT 1 FROM invoice_trl it
                   JOIN dispatch_trl dt ON dt.id = it.disp_trl_id
                   JOIN invoice inv ON inv.id = it.invoice_id
                   WHERE dt.gr_id = p_grn_id AND inv.deleted_at IS NULL
               ) THEN
                RAISE EXCEPTION 'Cannot change the pricing mode of a GRN that has invoices: delete invoices first, then change the pricing mode and invoice again';
            END IF;
        END IF;

        SELECT (e->>'id')::uuid::text INTO v_bad_line
        FROM jsonb_array_elements(p_items) AS e
        WHERE e->>'id' IS NOT NULL
        GROUP BY (e->>'id')::uuid
        HAVING count(*) > 1
        LIMIT 1;
        IF v_bad_line IS NOT NULL THEN
            RAISE EXCEPTION 'A GRN line is sent more than once in this edit; reload the GRN and edit again';
        END IF;

        SELECT x.e->>'id' INTO v_bad_line
        FROM jsonb_array_elements(p_items) WITH ORDINALITY AS x(e, n)
        WHERE x.e->>'id' IS NOT NULL
          AND NOT EXISTS (
              SELECT 1 FROM goodsreceived_trl t
              WHERE t.id = (x.e->>'id')::uuid AND t.gr_id = p_grn_id
          )
        ORDER BY x.n
        LIMIT 1;
        IF v_bad_line IS NOT NULL THEN
            RAISE EXCEPTION 'GRN line % is not a line of this GRN; reload the GRN and edit again', v_bad_line;
        END IF;

        -- ---- Migration 121 refusals. Each answers before the first write; nothing here changes a row. ----
        -- An invoiced GRN is one with a live invoice, or whose invoiced flag is set.
        SELECT i.inv_no, i.inv_fin_year INTO v_inv_no, v_inv_year
        FROM invoice i
        WHERE i.gr_id = p_grn_id AND i.deleted_at IS NULL
        ORDER BY i.inv_fin_year, i.inv_no, i.id
        LIMIT 1;
        v_is_invoiced := v_inv_no IS NOT NULL OR v_stored_invoiced;

        -- D23: the date of an invoiced GRN is locked (the invoice's days are counted from it). The same day sent back, at any
        -- time of day, is not a change.
        IF p_date IS NOT NULL AND v_is_invoiced
           AND warehouse_security.business_date(p_date) IS DISTINCT FROM warehouse_security.business_date(v_stored_date) THEN
            RETURN warehouse_security.refuse('GRN_DATE_LOCKED', 'This GRN is invoiced. Delete or edit the invoice first.',
                jsonb_build_object('gr_no', v_stored_gr_no, 'date', to_char(warehouse_security.business_date(p_date), 'YYYY-MM-DD'),
                                   'invoice_no', v_inv_no, 'inv_fin_year', v_inv_year));
        END IF;

        -- D3 (IST days): a GRN date that changes may not move after the first dispatch from the GRN.
        IF p_date IS NOT NULL
           AND warehouse_security.business_date(p_date) IS DISTINCT FROM warehouse_security.business_date(v_stored_date) THEN
            SELECT warehouse_security.business_date(d.disp_date), d.disp_no INTO v_first_day, v_first_disp_no
            FROM dispatch_trl dt
            JOIN dispatch d ON d.id = dt.disp_id AND d.deleted_at IS NULL
            WHERE dt.gr_id = p_grn_id AND d.disp_date IS NOT NULL
            ORDER BY warehouse_security.business_date(d.disp_date), d.disp_date, d.disp_no
            LIMIT 1;

            IF v_first_day IS NOT NULL AND warehouse_security.business_date(p_date) > v_first_day THEN
                RETURN warehouse_security.refuse('GRN_DATE_AFTER_DISPATCH',
                    format('GRN %s can''t be dated %s: dispatch %s took goods from it on %s.', v_stored_gr_no,
                           to_char(warehouse_security.business_date(p_date), 'YYYY-MM-DD'), v_first_disp_no,
                           to_char(v_first_day, 'YYYY-MM-DD')),
                    jsonb_build_object('gr_no', v_stored_gr_no, 'date', to_char(warehouse_security.business_date(p_date), 'YYYY-MM-DD'),
                                       'first_dispatch_date', to_char(v_first_day, 'YYYY-MM-DD'), 'dispatch_no', v_first_disp_no));
            END IF;
        END IF;

        -- D9: a line without an id is a new lot; an invoiced GRN takes none.
        IF v_is_invoiced AND EXISTS (SELECT 1 FROM jsonb_array_elements(p_items) AS x(e) WHERE x.e->>'id' IS NULL) THEN
            RETURN warehouse_security.refuse('GRN_INVOICED',
                CASE WHEN v_inv_no IS NULL
                     THEN format('GRN %s is invoiced. A line can''t be added. Delete the invoice first.', v_stored_gr_no)
                     ELSE format('GRN %s is on invoice %s. A line can''t be added. Delete the invoice first.', v_stored_gr_no, v_inv_no)
                END,
                jsonb_build_object('gr_no', v_stored_gr_no, 'invoice_no', v_inv_no, 'inv_fin_year', v_inv_year));
        END IF;

        -- D2: per listed line, only where a value really differs from the stored one. An invoiced lot keeps its item, packing
        -- and weight; a dispatched lot keeps its item and packing (its weight and the GRN date stay editable). The first
        -- offending line, in the order sent, is named.
        FOR v_chk IN
            SELECT x.n,
                   t.id AS line_id,
                   t.item_name AS stored_name,
                   (t.item_id IS DISTINCT FROM NULLIF(x.e->>'item_id', '')::uuid) AS item_changed,
                   (COALESCE(t.packaging, '') IS DISTINCT FROM COALESCE(x.e->>'packaging', '')) AS packaging_changed,
                   (COALESCE(t.weight, 0) IS DISTINCT FROM COALESCE((x.e->>'weight')::int, 0)) AS weight_changed,
                   EXISTS (SELECT 1 FROM dispatch_trl dt WHERE dt.gr_trl_id = t.id) AS dispatched
            FROM jsonb_array_elements(p_items) WITH ORDINALITY AS x(e, n)
            JOIN goodsreceived_trl t ON t.id = (x.e->>'id')::uuid AND t.gr_id = p_grn_id
            WHERE x.e->>'id' IS NOT NULL
            ORDER BY x.n
        LOOP
            IF v_chk.item_changed OR v_chk.packaging_changed OR v_chk.weight_changed THEN
                SELECT i.inv_no, i.inv_fin_year INTO v_inv_no2, v_inv_year2
                FROM invoice_trl it
                JOIN dispatch_trl dt ON dt.id = it.disp_trl_id
                JOIN invoice i ON i.id = it.invoice_id AND i.deleted_at IS NULL
                WHERE dt.gr_trl_id = v_chk.line_id
                ORDER BY i.inv_fin_year, i.inv_no, i.id
                LIMIT 1;

                IF v_inv_no2 IS NOT NULL THEN
                    v_changed_fields := '[]'::jsonb;
                    IF v_chk.item_changed THEN v_changed_fields := v_changed_fields || to_jsonb('item'::text); END IF;
                    IF v_chk.packaging_changed THEN v_changed_fields := v_changed_fields || to_jsonb('packaging'::text); END IF;
                    IF v_chk.weight_changed THEN v_changed_fields := v_changed_fields || to_jsonb('weight'::text); END IF;
                    RETURN warehouse_security.refuse('LOT_INVOICED',
                        format('%s is on invoice %s. Item, packing and weight can''t be changed. Delete or edit the invoice first.',
                               v_chk.stored_name, v_inv_no2),
                        jsonb_build_object('line_id', v_chk.line_id, 'item_name', v_chk.stored_name,
                                           'invoice_no', v_inv_no2, 'inv_fin_year', v_inv_year2, 'fields', v_changed_fields));
                END IF;

                IF v_chk.dispatched AND (v_chk.item_changed OR v_chk.packaging_changed) THEN
                    v_changed_fields := '[]'::jsonb;
                    IF v_chk.item_changed THEN v_changed_fields := v_changed_fields || to_jsonb('item'::text); END IF;
                    IF v_chk.packaging_changed THEN v_changed_fields := v_changed_fields || to_jsonb('packaging'::text); END IF;
                    RETURN warehouse_security.refuse('LOT_DISPATCHED',
                        format('%s has been dispatched. Its item and packing can''t be changed.', v_chk.stored_name),
                        jsonb_build_object('line_id', v_chk.line_id, 'item_name', v_chk.stored_name, 'fields', v_changed_fields));
                END IF;
            END IF;
        END LOOP;

        -- D11: a stored line that is missing from the list is a removal. One with dispatch or stock history, or on an order,
        -- is refused by name and reason (it used to fail on a foreign key). The in-loop 'Cannot delete item' below stays as
        -- a backstop.
        FOR v_chk IN
            SELECT t.id AS line_id,
                   t.item_name AS stored_name,
                   (EXISTS (SELECT 1 FROM dispatch_trl dt WHERE dt.gr_trl_id = t.id)
                    OR EXISTS (SELECT 1 FROM stock_movements m WHERE m.gr_trl_id = t.id)) AS had_history,
                   EXISTS (SELECT 1 FROM order_items oi
                           JOIN orders o ON o.id = oi.order_id AND o.deleted_at IS NULL
                           WHERE oi.grn_items_id = t.id) AS on_order
            FROM goodsreceived_trl t
            WHERE t.gr_id = p_grn_id
              AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(p_items) AS x(e)
                              WHERE x.e->>'id' IS NOT NULL AND (x.e->>'id')::uuid = t.id)
            ORDER BY uuid_extract_timestamp(t.id), t.id
        LOOP
            IF v_chk.had_history THEN
                RETURN warehouse_security.refuse('LINE_DISPATCHED_BEFORE',
                    format('%s was dispatched before, so this line can''t be removed.', v_chk.stored_name),
                    jsonb_build_object('line_id', v_chk.line_id, 'item_name', v_chk.stored_name));
            ELSIF v_chk.on_order THEN
                RETURN warehouse_security.refuse('LINE_ON_ORDER',
                    format('%s is on %s''s order. Remove it from the order first.', v_chk.stored_name, v_stored_customer_name),
                    jsonb_build_object('line_id', v_chk.line_id, 'item_name', v_chk.stored_name, 'customer_name', v_stored_customer_name));
            END IF;
        END LOOP;

        -- D10, D24: the lines and the pricing kind as they are before this edit, to tell afterwards which line lost its own
        -- rate because its weight or the pricing mode changed.
        SELECT COALESCE(jsonb_agg(jsonb_build_object('id', t.id, 'item_id', t.item_id, 'weight', COALESCE(t.weight, 0))), '[]'::jsonb)
        INTO v_lines_before
        FROM goodsreceived_trl t
        WHERE t.gr_id = p_grn_id;
        SELECT CASE WHEN upper(COALESCE(g.pricing_mode, '')) = 'ONE_TIME' THEN 'one_time' ELSE 'monthly' END
        INTO v_type_before
        FROM goodsreceived g
        WHERE g.id = p_grn_id;

        PERFORM safe_disable_grn_trl_triggers();

        UPDATE goodsreceived SET
            gr_no = COALESCE(p_gr_no, gr_no),
            date = COALESCE(p_date, date),
            customer_id = COALESCE(p_customer_id, customer_id),
            customer_name = CASE
                WHEN p_customer_id IS NOT NULL AND p_customer_id IS DISTINCT FROM customer_id
                THEN COALESCE((SELECT c.name FROM customers c WHERE c.id = p_customer_id), customer_name)
                ELSE customer_name END,
            sender_id = COALESCE(p_sender_id, sender_id),
            sender_name = COALESCE(p_sender_name, sender_name),
            supervisor_id = COALESCE(p_supervisor_id, supervisor_id),
            supervisor_name = COALESCE(p_supervisor_name, supervisor_name),
            registration = COALESCE(p_registration, registration),
            note = COALESCE(p_note, note),
            leon = COALESCE(p_leon, leon),
            pricing_mode = COALESCE(p_pricing_mode, pricing_mode),
            duration_mode = COALESCE(p_duration_mode, duration_mode),
            updated_by = v_user_profile_id,
            updated_at = now()
        WHERE id = p_grn_id;

        SELECT array_agg(id) INTO v_existing_grn_item_ids
        FROM goodsreceived_trl
        WHERE gr_id = p_grn_id;

        v_provided_grn_item_ids := ARRAY[]::uuid[];

        v_item_index := 0;
        FOR v_item IN SELECT * FROM jsonb_array_elements(p_items)
        LOOP
            v_item_master_id := (v_item->>'item_id')::uuid;
            v_item_name := v_item->>'item_name';

            IF v_item_master_id IS NULL THEN
                RAISE EXCEPTION 'itemId is required for all items';
            END IF;
            IF v_item_name IS NULL OR v_item_name = '' THEN
                RAISE EXCEPTION 'itemName is required for all items';
            END IF;
            IF (v_item->>'qty')::int <= 0 THEN
                RAISE EXCEPTION 'Quantity must be greater than 0 for item "%"', v_item_name;
            END IF;
            IF (v_item->>'weight')::int < 0 THEN
                RAISE EXCEPTION 'Weight cannot be negative for item "%"', v_item_name;
            END IF;

            IF v_item->>'id' IS NOT NULL THEN
                SELECT qty, stock, item_name
                INTO v_current_qty, v_current_stock, v_item_name_from_db
                FROM goodsreceived_trl
                WHERE id = (v_item->>'id')::uuid AND gr_id = p_grn_id
                FOR UPDATE;

                IF NOT FOUND THEN
                    RAISE EXCEPTION 'GRN line % is not a line of this GRN; reload the GRN and edit again', v_item->>'id';
                END IF;

                SELECT COALESCE(SUM(disp_qty), 0)
                INTO v_dispatched_qty
                FROM dispatch_trl
                WHERE gr_trl_id = (v_item->>'id')::uuid;

                IF v_dispatched_qty = 0 THEN
                    UPDATE goodsreceived_trl SET
                        item_id = v_item_master_id,
                        item_name = v_item_name,
                        packaging = v_item->>'packaging',
                        qty = (v_item->>'qty')::int,
                        stock = (v_item->>'qty')::int,
                        weight = COALESCE((v_item->>'weight')::int, 0),
                        rack = warehouse_security.ascii_digits(v_item->>'rack'),
                        package_mark = warehouse_security.ascii_digits(v_item->>'package_mark')
                    WHERE id = (v_item->>'id')::uuid AND gr_id = p_grn_id;

                    GET DIAGNOSTICS v_line_rows = ROW_COUNT;
                    IF v_line_rows <> 1 THEN
                        RAISE EXCEPTION 'GRN line % is not a line of this GRN; reload the GRN and edit again', v_item->>'id';
                    END IF;

                    v_items_updated := v_items_updated + 1;
                ELSE
                    UPDATE goodsreceived_trl SET
                        item_id = v_item_master_id,
                        packaging = v_item->>'packaging',
                        weight = COALESCE((v_item->>'weight')::int, 0),
                        rack = warehouse_security.ascii_digits(v_item->>'rack'),
                        package_mark = warehouse_security.ascii_digits(v_item->>'package_mark')
                    WHERE id = (v_item->>'id')::uuid AND gr_id = p_grn_id;

                    GET DIAGNOSTICS v_line_rows = ROW_COUNT;
                    IF v_line_rows <> 1 THEN
                        RAISE EXCEPTION 'GRN line % is not a line of this GRN; reload the GRN and edit again', v_item->>'id';
                    END IF;

                    v_items_updated := v_items_updated + 1;

                    v_items_skipped_stock := v_items_skipped_stock || jsonb_build_object(
                        'grn_trl_item_id', v_item->>'id',
                        'item_name', v_item_name_from_db,
                        'reason', format('Cannot update qty/stock - item has %s units dispatched', v_dispatched_qty),
                        'current_qty', v_current_qty,
                        'current_stock', v_current_stock,
                        'dispatched_qty', v_dispatched_qty
                    );
                END IF;

                v_provided_grn_item_ids := array_append(v_provided_grn_item_ids, (v_item->>'id')::uuid);
            ELSE
                INSERT INTO goodsreceived_trl (
                    gr_id, item_id, item_name, packaging, qty, stock, weight, rack, package_mark
                ) VALUES (
                    p_grn_id, v_item_master_id, v_item_name, v_item->>'packaging',
                    (v_item->>'qty')::int, (v_item->>'qty')::int,
                    COALESCE((v_item->>'weight')::int, 0), warehouse_security.ascii_digits(v_item->>'rack'),
                    warehouse_security.ascii_digits(v_item->>'package_mark')
                ) RETURNING id INTO v_grn_trl_item_id;

                v_items_added := v_items_added + 1;

                v_item_mapping := v_item_mapping || jsonb_build_object(
                    'index', v_item_index,
                    'grn_trl_item_id', v_grn_trl_item_id,
                    'item_name', v_item_name
                );
            END IF;

            v_item_index := v_item_index + 1;
        END LOOP;

        IF v_existing_grn_item_ids IS NOT NULL THEN
            v_items_to_delete := ARRAY(
                SELECT unnest(v_existing_grn_item_ids)
                EXCEPT
                SELECT unnest(v_provided_grn_item_ids)
            );

            IF v_items_to_delete IS NOT NULL THEN
                FOR v_grn_trl_item_id IN SELECT unnest(v_items_to_delete)
                LOOP
                    SELECT COUNT(*) INTO v_dispatched_qty
                    FROM dispatch_trl
                    WHERE gr_trl_id = v_grn_trl_item_id;

                    IF v_dispatched_qty > 0 THEN
                        SELECT item_name INTO v_item_name_from_db
                        FROM goodsreceived_trl
                        WHERE id = v_grn_trl_item_id;

                        RAISE EXCEPTION 'Cannot delete item "%" - has % existing dispatches',
                            v_item_name_from_db, v_dispatched_qty;
                    END IF;

                    DELETE FROM goodsreceived_trl WHERE id = v_grn_trl_item_id;
                    v_items_deleted := v_items_deleted + 1;
                END LOOP;
            END IF;
        END IF;

        IF jsonb_array_length(p_images) > 0 THEN
            v_kept_image_ids := ARRAY[]::uuid[];

            FOR v_image IN SELECT * FROM jsonb_array_elements(p_images)
            LOOP
                IF v_image->>'storage_path' IS NULL OR v_image->>'image_type' IS NULL THEN
                    RAISE EXCEPTION 'Invalid image data: storage_path and image_type are required';
                END IF;

                v_resolved_item_id := NULL;
                IF v_image->>'image_type' = 'item' THEN
                    IF v_image->>'grn_item_id' IS NOT NULL THEN
                        v_resolved_item_id := (v_image->>'grn_item_id')::uuid;
                    ELSIF v_image->>'item_index' IS NOT NULL THEN
                        SELECT (mapping->>'grn_trl_item_id')::uuid INTO v_resolved_item_id
                        FROM jsonb_array_elements(v_item_mapping) mapping
                        WHERE (mapping->>'index')::int = (v_image->>'item_index')::int;

                        IF v_resolved_item_id IS NULL THEN
                            RAISE EXCEPTION 'Invalid item_index % for image', v_image->>'item_index';
                        END IF;
                    ELSE
                        RAISE EXCEPTION 'Item images must have either grn_item_id or item_index';
                    END IF;
                END IF;

                IF v_resolved_item_id IS NOT NULL AND NOT EXISTS (
                    SELECT 1 FROM goodsreceived_trl WHERE id = v_resolved_item_id AND gr_id = p_grn_id) THEN
                    RAISE EXCEPTION 'Image line does not belong to this GRN';
                END IF;

                v_image_id := NULL;
                IF v_image->>'id' IS NOT NULL AND NOT (v_image->>'id' LIKE 'temp_%') THEN
                    SELECT id INTO v_image_id FROM grn_images
                    WHERE id = (v_image->>'id')::uuid AND grn_id = p_grn_id;
                END IF;
                IF v_image_id IS NULL THEN
                    SELECT id INTO v_image_id FROM grn_images
                    WHERE grn_id = p_grn_id AND storage_path = v_image->>'storage_path'
                    ORDER BY created_at, id LIMIT 1;
                END IF;

                IF v_image_id IS NOT NULL AND NOT EXISTS (
                    SELECT 1 FROM grn_images seen
                    WHERE seen.id = v_image_id
                    AND warehouse_security.grn_image_visible(seen.status, seen.uploaded_by)) THEN
                    -- Migration 69: another person's pending photo, named in the list, stays as it is.
                    v_kept_image_ids := array_append(v_kept_image_ids, v_image_id);
                ELSIF v_image_id IS NOT NULL THEN
                    UPDATE grn_images SET
                        grn_item_id = v_resolved_item_id,
                        updated_at = now()
                    WHERE id = v_image_id AND grn_id = p_grn_id;

                    v_images_updated := v_images_updated + 1;
                    v_kept_image_ids := array_append(v_kept_image_ids, v_image_id);
                ELSE
                    PERFORM warehouse_security.require_image_path('grn', p_grn_id, v_image->>'image_type', v_image->>'storage_path');

                    v_image_id := gen_random_uuid();

                    INSERT INTO grn_images (
                        id, grn_id, grn_item_id, image_type, storage_path,
                        original_filename, file_size, mime_type, uploaded_by, status
                    ) VALUES (
                        v_image_id, p_grn_id, v_resolved_item_id, v_image->>'image_type',
                        v_image->>'storage_path', COALESCE(v_image->>'original_filename', 'unknown'),
                        COALESCE((v_image->>'file_size')::int, 0),
                        COALESCE(v_image->>'mime_type', 'image/jpeg'), v_user_profile_id, 'confirmed'
                    );

                    v_images_added := v_images_added + 1;
                    v_kept_image_ids := array_append(v_kept_image_ids, v_image_id);
                END IF;
            END LOOP;

            DELETE FROM grn_images
            WHERE grn_id = p_grn_id
            AND id NOT IN (SELECT unnest(v_kept_image_ids))
            AND warehouse_security.grn_image_visible(grn_images.status, grn_images.uploaded_by);

            GET DIAGNOSTICS v_images_deleted = ROW_COUNT;
        ELSE
            v_images_deleted := 0;
        END IF;

        -- The GRN's own rates follow its lines, whether or not p_rates came: a rate of another pricing
        -- kind, or one whose band holds no weight of its item's lines any more, goes. An invoiced
        -- GRN keeps its (archived) rates.
        -- (Migration 121: the rates that go are collected, to refuse the edit below when it would drop a rate it may not.)
        WITH gone AS (
            DELETE FROM public.grn_rates gr WHERE gr.gr_id = p_grn_id
              AND NOT EXISTS (SELECT 1 FROM public.goodsreceived g WHERE g.id = p_grn_id AND g.invoiced IS TRUE)
              AND (gr.price_type <> (SELECT CASE WHEN upper(COALESCE(g.pricing_mode, '')) = 'ONE_TIME' THEN 'one_time' ELSE 'monthly' END
                                       FROM public.goodsreceived g WHERE g.id = p_grn_id)
                   OR NOT EXISTS (SELECT 1 FROM public.goodsreceived_trl t WHERE t.gr_id = p_grn_id AND t.item_id = gr.item_id
                                    AND COALESCE(t.weight, 0) BETWEEN gr.weight_min AND gr.weight_max))
            RETURNING gr.item_id, gr.weight_min, gr.weight_max
        )
        SELECT count(*)::integer,
               COALESCE(array_agg(DISTINCT i.name ORDER BY i.name) FILTER (WHERE i.name IS NOT NULL), ARRAY[]::text[]),
               COALESCE(jsonb_agg(jsonb_build_object('item_id', gone.item_id, 'weight_min', gone.weight_min, 'weight_max', gone.weight_max)), '[]'::jsonb)
        INTO v_dropped_count, v_dropped_items, v_dropped_rows
        FROM gone
        LEFT JOIN public.items i ON i.id = gone.item_id;

        -- Rates typed on the GRN sheet (migration 86), after the lines are written. A failure
        -- raises out of this block, which undoes the update, and the handler answers it.
        IF p_rates IS NOT NULL THEN
            v_rate_failure := warehouse_security.apply_grn_rates(p_grn_id, p_rates);
            IF v_rate_failure IS NOT NULL THEN
                RAISE EXCEPTION 'rate_fail' USING ERRCODE = 'P0001', DETAIL = v_rate_failure::text;
            END IF;
        END IF;

        -- D10, D24 (migration 121): a rate set for this GRN alone is not dropped by an edit that did not mean to.
        -- Staff: a rate the edit removes that fitted a line before the edit is refused (they cannot send rates; a manager makes the change).
        -- Administrators and supervisors: refused when a line whose weight, or the GRN's pricing mode, was changed by this save
        -- loses its GRN-only rate and is not priced again by this save (a rate of any scope for that item and weight in
        -- p_rates, or a GRN-only rate it still has). A rate they remove on purpose in the Rates step is not this case. The
        -- raise rolls the whole edit back and the handler answers it.
        IF v_dropped_count > 0 THEN
            IF warehouse_security.active_role() = 'staff' THEN
                -- Only a rate that fitted a line BEFORE this edit counts (as the D24 check below): a leftover GRN-only rate that
                -- fitted no line before is not a reason to refuse a staff edit.
                SELECT count(DISTINCT (d.item_id, d.weight_min, d.weight_max))::integer,
                       COALESCE(array_agg(DISTINCT i.name ORDER BY i.name) FILTER (WHERE i.name IS NOT NULL), ARRAY[]::text[])
                INTO v_would_drop_count, v_would_drop_items
                FROM jsonb_to_recordset(v_dropped_rows) AS d(item_id uuid, weight_min integer, weight_max integer)
                JOIN jsonb_to_recordset(v_lines_before) AS b(id uuid, item_id uuid, weight integer)
                  ON b.item_id = d.item_id AND b.weight BETWEEN d.weight_min AND d.weight_max
                LEFT JOIN items i ON i.id = d.item_id;

                IF v_would_drop_count > 0 THEN
                    RAISE EXCEPTION 'rate_fail' USING ERRCODE = 'P0001', DETAIL = warehouse_security.refuse('RATES_NEED_MANAGER',
                        'Ask a manager to make this change: it would remove a rate that was set for this GRN.',
                        jsonb_build_object('gr_no', v_stored_gr_no, 'rates', v_would_drop_count, 'items', to_jsonb(v_would_drop_items)))::text;
                END IF;
            ELSIF warehouse_security.active_role() IN ('admin', 'supervisor') THEN
                SELECT CASE WHEN upper(COALESCE(g.pricing_mode, '')) = 'ONE_TIME' THEN 'one_time' ELSE 'monthly' END
                INTO v_type_after
                FROM goodsreceived g
                WHERE g.id = p_grn_id;

                SELECT count(DISTINCT (d.item_id, d.weight_min, d.weight_max))::integer,
                       COALESCE(array_agg(DISTINCT i.name ORDER BY i.name) FILTER (WHERE i.name IS NOT NULL), ARRAY[]::text[])
                INTO v_would_drop_count, v_would_drop_items
                FROM jsonb_to_recordset(v_dropped_rows) AS d(item_id uuid, weight_min integer, weight_max integer)
                JOIN jsonb_to_recordset(v_lines_before) AS b(id uuid, item_id uuid, weight integer)
                  ON b.item_id = d.item_id AND b.weight BETWEEN d.weight_min AND d.weight_max
                JOIN goodsreceived_trl t ON t.id = b.id AND t.gr_id = p_grn_id AND t.item_id = b.item_id
                LEFT JOIN items i ON i.id = d.item_id
                WHERE (COALESCE(t.weight, 0) <> b.weight OR v_type_after <> v_type_before)
                  AND NOT EXISTS (SELECT 1 FROM grn_rates g
                                  WHERE g.gr_id = p_grn_id AND g.item_id = t.item_id AND g.price_type = v_type_after
                                    AND COALESCE(t.weight, 0) BETWEEN g.weight_min AND g.weight_max)
                  AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(COALESCE(p_rates, '[]'::jsonb)) AS x(e)
                                  WHERE lower(x.e->>'item_id') = t.item_id::text
                                    AND (x.e->>'weight_min')::numeric <= COALESCE(t.weight, 0)
                                    AND COALESCE(t.weight, 0) <= (x.e->>'weight_max')::numeric);

                IF v_would_drop_count > 0 THEN
                    RAISE EXCEPTION 'rate_fail' USING ERRCODE = 'P0001', DETAIL = warehouse_security.refuse('RATES_WOULD_DROP',
                        'This change removes the rate set for this GRN. Set a new rate in Rates.',
                        jsonb_build_object('gr_no', v_stored_gr_no, 'rates', v_would_drop_count, 'items', to_jsonb(v_would_drop_items)))::text;
                END IF;
            END IF;
        END IF;

        PERFORM safe_enable_grn_trl_triggers();

        PERFORM pg_advisory_xact_lock(71040);

        SELECT jsonb_agg(
            jsonb_build_object(
                'id', t.id,
                'item_id', t.item_id,
                'item_name', t.item_name,
                'packaging', t.packaging,
                'qty', t.qty,
                'stock', t.stock,
                'weight', t.weight,
                'rack', t.rack,
                'package_mark', t.package_mark
            )
        ) INTO v_grn_items
        FROM goodsreceived_trl t
        WHERE t.gr_id = p_grn_id;

        SELECT jsonb_agg(
            jsonb_build_object(
                'id', i.id,
                'image_type', i.image_type,
                'storage_path', i.storage_path,
                'grn_item_id', i.grn_item_id,
                'original_filename', i.original_filename
            )
        ) INTO v_grn_images
        FROM grn_images i
        WHERE i.grn_id = p_grn_id
        AND warehouse_security.grn_image_visible(i.status, i.uploaded_by);

        SELECT jsonb_build_object(
            'id', g.id,
            'gr_no', g.gr_no,
            'date', g.date,
            'customer_id', g.customer_id,
            'customer_name', g.customer_name,
            'sender_id', g.sender_id,
            'sender_name', g.sender_name,
            'supervisor_id', g.supervisor_id,
            'supervisor_name', g.supervisor_name,
            'registration', g.registration,
            'note', g.note,
            'leon', g.leon,
            'pricing_mode', g.pricing_mode,
            'duration_mode', g.duration_mode,
            'updated_at', g.updated_at
        ) INTO v_grn_header
        FROM goodsreceived g
        WHERE g.id = p_grn_id;

        v_final_grn_data := v_grn_header || jsonb_build_object(
            'items', COALESCE(v_grn_items, '[]'::jsonb),
            'images', COALESCE(v_grn_images, '[]'::jsonb)
        );

        v_result := jsonb_build_object(
            'success', true,
            'message', 'GRN updated successfully',
            'grn', v_final_grn_data,
            'stats', jsonb_build_object(
                'items_updated', v_items_updated,
                'items_added', v_items_added,
                'items_deleted', v_items_deleted,
                'images_updated', v_images_updated,
                'images_added', v_images_added,
                'images_deleted', v_images_deleted,
                'items_skipped_stock', v_items_skipped_stock
            ),
            'item_mapping', v_item_mapping
        );

        -- Kept for the 7 days a retry is answered from it (migration 120). A key another
        -- function or user holds is left alone unless it has expired.
        IF p_idempotency_key IS NOT NULL THEN
            INSERT INTO idempotency_keys (idempotency_key, rpc_function, response, created_by, expires_at)
            VALUES (p_idempotency_key, 'update_grn', v_result, v_user_profile_id, now() + interval '7 days')
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

    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM = 'rate_fail' THEN
            GET STACKED DIAGNOSTICS v_detail = PG_EXCEPTION_DETAIL;
            PERFORM safe_enable_grn_trl_triggers();
            RETURN v_detail::jsonb;
        END IF;
        PERFORM safe_enable_grn_trl_triggers();
        RAISE;
    END;
END;
$function$;

REVOKE ALL ON FUNCTION public.update_grn(uuid,character varying,timestamp with time zone,uuid,character varying,uuid,character varying,uuid,character varying,character varying,character varying,boolean,character varying,jsonb,jsonb,character varying,text,jsonb,timestamp with time zone) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.update_grn(uuid,character varying,timestamp with time zone,uuid,character varying,uuid,character varying,uuid,character varying,character varying,character varying,boolean,character varying,jsonb,jsonb,character varying,text,jsonb,timestamp with time zone) TO service_role, authenticated;
