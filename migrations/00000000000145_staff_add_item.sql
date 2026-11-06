-- Migration 145: staff add an item from the GRN "Items" step (WH-42).
--
-- Section 1  create_item (the migration 144 text, one change): a staff account may call it. Staff create an active item with a name and a packaging
--            word and no rate, even when the facility has a standard rate: p_rate_from_item and p_active = false are refused for staff
--            (PERMISSION_DENIED), and the standard rate is not given. Administrators and supervisors behave as before; customers are refused by
--            authorize_rpc. The role decides inside the function, never the app.
-- authorize_rpc's staff entry for create_item is in migrations/definitions/00_authorize_rpc.sql (a definition file, not a migration).
-- Rates are rows in item_storage_prices copied at creation (give_standard_rate); no lookup reads standard_rate_tiers later, so an item without
-- rows has no rate at the invoice until a manager sets one.

CREATE OR REPLACE FUNCTION public.create_item(p_name character varying, p_packaging character varying DEFAULT NULL::character varying, p_description character varying DEFAULT NULL::character varying, p_active boolean DEFAULT true, p_rate_from_item uuid DEFAULT NULL::uuid) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'extensions', 'utils', 'pg_temp'
    AS $$
DECLARE
    v_new_id uuid;
    v_result jsonb;
    v_source text := 'none';
    v_today date := warehouse_security.business_date(now());
    v_name text := TRIM(p_name);
    v_packaging text := NULLIF(warehouse_security.clean_packaging(p_packaging), '');
    v_description text := NULLIF(TRIM(p_description), '');
    v_constraint text;
    v_staff boolean := false;
BEGIN
  PERFORM warehouse_security.authorize_rpc('create_item',jsonb_build_object());
    -- Security check. Staff may add an item with a name and a packaging word only (migration 145, WH-42): authorize_rpc lets staff in
    -- (customers are refused there), and the role decides here, on the server, never the app.
    IF warehouse_security.active_role() = 'staff' THEN
        v_staff := true;
        IF p_rate_from_item IS NOT NULL OR p_active IS NOT DISTINCT FROM false THEN
            RETURN jsonb_build_object(
                'success', false,
                'error_code', 'PERMISSION_DENIED',
                'error', 'Access denied: staff add an active item without a rate',
                'message', 'Access denied: staff add an active item without a rate'
            );
        END IF;
    ELSIF NOT is_admin_or_supervisor() THEN
        RETURN jsonb_build_object(
            'success', false,
            'error_code', 'PERMISSION_DENIED',
            'error', 'Access denied: Admin or supervisor role required',
            'message', 'Access denied: Admin or supervisor role required'
        );
    END IF;

    -- Validate name
    IF v_name IS NULL OR v_name = '' THEN
        RETURN jsonb_build_object(
            'success', false,
            'error_code', 'INVALID_INPUT',
            'error', 'Item name is required',
            'message', 'Item name is required'
        );
    END IF;
    -- The packaging word is required (migration 144).
    IF v_packaging IS NULL THEN
        RETURN jsonb_build_object(
            'success', false,
            'error_code', 'INVALID_INPUT',
            'error', 'Packaging is required',
            'message', 'Packaging is required'
        );
    END IF;
    IF length(v_name) > 80 OR length(v_packaging) > 40 OR length(v_description) > 40 THEN
        RETURN jsonb_build_object(
            'success', false,
            'error_code', 'INVALID_INPUT',
            'error', 'Name is at most 80 characters, packaging and description at most 40',
            'message', 'Name is at most 80 characters, packaging and description at most 40'
        );
    END IF;

    -- Check for a duplicate: the same name and the same packaging word (any item, active or not; upper and lower case are the same,
    -- and a blank word is Bag).
    PERFORM pg_advisory_xact_lock(hashtextextended('item_name:' || LOWER(v_name) || '|' || warehouse_security.packaging_key(v_packaging), 0));
    IF EXISTS (SELECT 1 FROM items
               WHERE LOWER(TRIM(name)) = LOWER(v_name)
                 AND warehouse_security.packaging_key(packaging) = warehouse_security.packaging_key(v_packaging)) THEN
        RETURN jsonb_build_object(
            'success', false,
            'error_code', 'DUPLICATE_NAME',
            'error', 'An item with this name and packaging already exists',
            'message', 'An item with this name and packaging already exists'
        );
    END IF;

    -- Insert new item. Two saves of the same name and word at once: the unique key answers the second one.
    BEGIN
        INSERT INTO items (name, packaging, description, active)
        VALUES (v_name, v_packaging, v_description, COALESCE(p_active, true))
        RETURNING id INTO v_new_id;
    EXCEPTION WHEN unique_violation THEN
        GET STACKED DIAGNOSTICS v_constraint = CONSTRAINT_NAME;
        IF v_constraint IS DISTINCT FROM 'items_name_packaging_key' THEN RAISE; END IF;
        RETURN jsonb_build_object(
            'success', false,
            'error_code', 'DUPLICATE_NAME',
            'error', 'An item with this name and packaging already exists',
            'message', 'An item with this name and packaging already exists'
        );
    END;

    -- The item's rate (migration 85): a copy of another item's default rows in force today, else
    -- the standard tiers from today, else none. A save of the standard rate in progress is waited
    -- for (it holds the same lock exclusively), so the tiers read below are the committed ones.
    -- Staff never give an item a rate (migration 145): it has no rate rows until a manager sets one, and nothing falls back to the standard rate.
    IF NOT v_staff THEN
      PERFORM pg_advisory_xact_lock_shared(hashtextextended('standard_rate', 0));
    END IF;
    IF v_staff THEN
        NULL;
    ELSIF p_rate_from_item IS NOT NULL
       AND warehouse_security.copy_default_rates(p_rate_from_item, v_new_id, v_today) > 0 THEN
        v_source := 'copied';
    ELSIF warehouse_security.give_standard_rate(v_new_id, v_today) > 0 THEN
        v_source := 'standard';
    END IF;

    -- Return created item
    SELECT jsonb_build_object(
        'id', id,
        'name', name,
        'packaging', packaging,
        'description', description,
        'active', active,
        'rate_source', v_source
    ) INTO v_result
    FROM items
    WHERE id = v_new_id;

    RETURN jsonb_build_object(
        'success', true,
        'message', 'Item created successfully',
        'data', v_result
    );
END;
$$;

