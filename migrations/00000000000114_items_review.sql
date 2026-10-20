-- This migration (tweak 2026-10-20, Items screens): create_item, update_item, get_items and a new
-- read-only get_item_usage.
--   * create_item / update_item answer error_code DUPLICATE_NAME for a name already in use (also when the
--     unique constraint items_name_key catches a concurrent save), and the other refusals carry an error_code
--     too: PERMISSION_DENIED, INVALID_INPUT, NOT_FOUND. The English message text is unchanged.
--   * update_item: p_active now defaults to NULL = keep the item's current value (it defaulted to true, so a
--     call without it re-activated the item). A call that sends p_active behaves as before.
--   * get_items: the search also matches the packaging text.
--   * get_item_usage(p_item_id): where an item is used, so the app can refuse "Delete" before asking.
-- The signatures of create_item, update_item and get_items are unchanged (update_item only gets another default),
-- so grants, owner and old callers stay as they are; the grants are restated below anyway.

-- ---------------------------------------------------------------------------------------------
-- create_item
-- ---------------------------------------------------------------------------------------------
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
    v_packaging text := NULLIF(TRIM(p_packaging), '');
    v_description text := NULLIF(TRIM(p_description), '');
    v_constraint text;
BEGIN
  PERFORM warehouse_security.authorize_rpc('create_item',jsonb_build_object());
    -- Security check
    IF NOT is_admin_or_supervisor() THEN
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
    IF length(v_name) > 80 OR length(v_packaging) > 40 OR length(v_description) > 40 THEN
        RETURN jsonb_build_object(
            'success', false,
            'error_code', 'INVALID_INPUT',
            'error', 'Name is at most 80 characters, packaging and description at most 40',
            'message', 'Name is at most 80 characters, packaging and description at most 40'
        );
    END IF;

    -- Check for duplicate name (any item, active or not; upper and lower case are the same)
    PERFORM pg_advisory_xact_lock(hashtextextended('item_name:' || LOWER(v_name), 0));
    IF EXISTS (SELECT 1 FROM items WHERE LOWER(TRIM(name)) = LOWER(v_name)) THEN
        RETURN jsonb_build_object(
            'success', false,
            'error_code', 'DUPLICATE_NAME',
            'error', 'An item with this name already exists',
            'message', 'An item with this name already exists'
        );
    END IF;

    -- Insert new item. Two saves of the same name at once: the unique constraint answers the second one.
    BEGIN
        INSERT INTO items (name, packaging, description, active)
        VALUES (v_name, v_packaging, v_description, COALESCE(p_active, true))
        RETURNING id INTO v_new_id;
    EXCEPTION WHEN unique_violation THEN
        GET STACKED DIAGNOSTICS v_constraint = CONSTRAINT_NAME;
        IF v_constraint IS DISTINCT FROM 'items_name_key' THEN RAISE; END IF;
        RETURN jsonb_build_object(
            'success', false,
            'error_code', 'DUPLICATE_NAME',
            'error', 'An item with this name already exists',
            'message', 'An item with this name already exists'
        );
    END;

    -- The item's rate (migration 85): a copy of another item's default rows in force today, else
    -- the standard tiers from today, else none. A save of the standard rate in progress is waited
    -- for (it holds the same lock exclusively), so the tiers read below are the committed ones.
    PERFORM pg_advisory_xact_lock_shared(hashtextextended('standard_rate', 0));
    IF p_rate_from_item IS NOT NULL
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

ALTER FUNCTION public.create_item(p_name character varying, p_packaging character varying, p_description character varying, p_active boolean, p_rate_from_item uuid) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION public.create_item(p_name character varying, p_packaging character varying, p_description character varying, p_active boolean, p_rate_from_item uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.create_item(p_name character varying, p_packaging character varying, p_description character varying, p_active boolean, p_rate_from_item uuid) TO service_role;
GRANT ALL ON FUNCTION public.create_item(p_name character varying, p_packaging character varying, p_description character varying, p_active boolean, p_rate_from_item uuid) TO authenticated;

-- ---------------------------------------------------------------------------------------------
-- update_item (p_active DEFAULT NULL: not sent = keep the current value)
-- ---------------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.update_item(p_item_id uuid, p_name character varying, p_packaging character varying DEFAULT NULL::character varying, p_description character varying DEFAULT NULL::character varying, p_active boolean DEFAULT NULL::boolean) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'extensions', 'utils', 'pg_temp'
    AS $$
DECLARE
    v_result jsonb;
    v_was_active boolean;
    v_current_name text;
    v_found boolean;
    v_new_active boolean;
    v_name text := TRIM(p_name);
    v_packaging text := NULLIF(TRIM(p_packaging), '');
    v_description text := NULLIF(TRIM(p_description), '');
    v_constraint text;
BEGIN
  PERFORM warehouse_security.authorize_rpc('update_item',jsonb_build_object());
    -- Security check
    IF NOT is_admin_or_supervisor() THEN
        RETURN jsonb_build_object(
            'success', false,
            'error_code', 'PERMISSION_DENIED',
            'error', 'Access denied: Admin or supervisor role required',
            'message', 'Access denied: Admin or supervisor role required'
        );
    END IF;

    -- Check if item exists (and hold its row, so a delete in between cannot slip past)
    SELECT true, active, name INTO v_found, v_was_active, v_current_name FROM items WHERE id = p_item_id FOR NO KEY UPDATE;
    IF v_found IS NOT TRUE THEN
        RETURN jsonb_build_object(
            'success', false,
            'error_code', 'NOT_FOUND',
            'error', 'Item not found',
            'message', 'Item not found'
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
    IF length(v_name) > 80 OR length(v_packaging) > 40 OR length(v_description) > 40 THEN
        RETURN jsonb_build_object(
            'success', false,
            'error_code', 'INVALID_INPUT',
            'error', 'Name is at most 80 characters, packaging and description at most 40',
            'message', 'Name is at most 80 characters, packaging and description at most 40'
        );
    END IF;

    -- Check for duplicate name (excluding self; any item, active or not; upper and lower case are the same)
    -- A name left exactly as stored is not checked, so older items that differ only in case stay editable.
    IF v_name IS DISTINCT FROM v_current_name THEN
      PERFORM pg_advisory_xact_lock(hashtextextended('item_name:' || LOWER(v_name), 0));
    END IF;
    IF v_name IS DISTINCT FROM v_current_name
       AND EXISTS (SELECT 1 FROM items WHERE LOWER(TRIM(name)) = LOWER(v_name) AND id != p_item_id) THEN
        RETURN jsonb_build_object(
            'success', false,
            'error_code', 'DUPLICATE_NAME',
            'error', 'An item with this name already exists',
            'message', 'An item with this name already exists'
        );
    END IF;

    -- Not sent (NULL) = keep the current value.
    v_new_active := COALESCE(p_active, v_was_active);

    -- Update item
    BEGIN
        UPDATE items
        SET name = v_name,
            packaging = v_packaging,
            description = v_description,
            active = v_new_active
        WHERE id = p_item_id;
    EXCEPTION WHEN unique_violation THEN
        GET STACKED DIAGNOSTICS v_constraint = CONSTRAINT_NAME;
        IF v_constraint IS DISTINCT FROM 'items_name_key' THEN RAISE; END IF;
        RETURN jsonb_build_object(
            'success', false,
            'error_code', 'DUPLICATE_NAME',
            'error', 'An item with this name already exists',
            'message', 'An item with this name already exists'
        );
    END;

    -- An item that turns active and has no default rate gets the standard tiers from today (migration 85).
    IF COALESCE(v_was_active, false) = false AND v_new_active IS TRUE THEN
        PERFORM pg_advisory_xact_lock_shared(hashtextextended('standard_rate', 0));
        PERFORM warehouse_security.give_standard_rate(p_item_id, warehouse_security.business_date(now()));
    END IF;

    -- Return updated item
    SELECT jsonb_build_object(
        'id', id,
        'name', name,
        'packaging', packaging,
        'description', description,
        'active', active
    ) INTO v_result
    FROM items
    WHERE id = p_item_id;

    RETURN jsonb_build_object(
        'success', true,
        'message', 'Item updated successfully',
        'data', v_result
    );
END;
$$;

ALTER FUNCTION public.update_item(p_item_id uuid, p_name character varying, p_packaging character varying, p_description character varying, p_active boolean) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION public.update_item(p_item_id uuid, p_name character varying, p_packaging character varying, p_description character varying, p_active boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION public.update_item(p_item_id uuid, p_name character varying, p_packaging character varying, p_description character varying, p_active boolean) TO service_role;
GRANT ALL ON FUNCTION public.update_item(p_item_id uuid, p_name character varying, p_packaging character varying, p_description character varying, p_active boolean) TO authenticated;

-- ---------------------------------------------------------------------------------------------
-- get_items: the search also matches the packaging text
-- ---------------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_items(p_search_query text DEFAULT NULL::text, p_active_only boolean DEFAULT true, p_limit integer DEFAULT 50, p_offset integer DEFAULT 0) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'extensions', 'utils', 'pg_temp'
    AS $$
DECLARE
    v_result jsonb;
    v_total_count integer;
BEGIN
  PERFORM warehouse_security.authorize_rpc('get_items',jsonb_build_object());
    -- Get total count
    SELECT COUNT(*) INTO v_total_count
    FROM items
    WHERE (p_active_only = false OR active = true)
      AND (p_search_query IS NULL OR
           name ILIKE '%' || p_search_query || '%' OR
           description ILIKE '%' || p_search_query || '%' OR
           packaging ILIKE '%' || p_search_query || '%');

    -- Get items
    SELECT jsonb_agg(
        jsonb_build_object(
            'id', id,
            'name', name,
            'packaging', packaging,
            'description', description,
            'active', active
        ) ORDER BY name
    ) INTO v_result
    FROM (
        SELECT id, name, packaging, description, active
        FROM items
        WHERE (p_active_only = false OR active = true)
          AND (p_search_query IS NULL OR
               name ILIKE '%' || p_search_query || '%' OR
               description ILIKE '%' || p_search_query || '%' OR
               packaging ILIKE '%' || p_search_query || '%')
        ORDER BY name
        LIMIT p_limit OFFSET p_offset
    ) sub;

    RETURN jsonb_build_object(
        'success', true,
        'data', jsonb_build_object(
            'items', COALESCE(v_result, '[]'::jsonb),
            'total_count', v_total_count,
            'limit', p_limit,
            'offset', p_offset
        )
    );
END;
$$;

ALTER FUNCTION public.get_items(p_search_query text, p_active_only boolean, p_limit integer, p_offset integer) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION public.get_items(p_search_query text, p_active_only boolean, p_limit integer, p_offset integer) FROM PUBLIC;
GRANT ALL ON FUNCTION public.get_items(p_search_query text, p_active_only boolean, p_limit integer, p_offset integer) TO service_role;
GRANT ALL ON FUNCTION public.get_items(p_search_query text, p_active_only boolean, p_limit integer, p_offset integer) TO authenticated;

-- ---------------------------------------------------------------------------------------------
-- get_item_usage: read-only. The same three places delete_item_safe refuses on (GRN lines, order lines,
-- GRN rates) plus the item's storage prices, which delete_item_safe deletes with the item.
-- Administrators and supervisors only (authorize_rpc refuses staff and customers: 42501).
-- ---------------------------------------------------------------------------------------------
CREATE FUNCTION public.get_item_usage(p_item_id uuid) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'extensions', 'utils', 'pg_temp'
    AS $$
DECLARE
    v_name text;
    v_active boolean;
    v_grn_lines integer;
    v_order_lines integer;
    v_grn_rates integer;
    v_prices integer;
    v_rates integer;
BEGIN
  PERFORM warehouse_security.authorize_rpc('get_item_usage',jsonb_build_object());
    SELECT name, active INTO v_name, v_active FROM items WHERE id = p_item_id;
    IF v_name IS NULL THEN
        RETURN jsonb_build_object(
            'success', false,
            'error_code', 'NOT_FOUND',
            'error', 'Item not found',
            'message', 'Item not found'
        );
    END IF;

    SELECT COUNT(*) INTO v_grn_lines FROM goodsreceived_trl WHERE item_id = p_item_id;
    SELECT COUNT(*) INTO v_order_lines FROM order_items WHERE grn_items_item_id = p_item_id;
    SELECT COUNT(*) INTO v_grn_rates FROM grn_rates WHERE item_id = p_item_id;
    SELECT COUNT(*), COUNT(DISTINCT (COALESCE(customer_id::text, 'default'), price_type, effective_from))
      INTO v_prices, v_rates FROM item_storage_prices WHERE item_id = p_item_id;

    RETURN jsonb_build_object(
        'success', true,
        'data', jsonb_build_object(
            'item_id', p_item_id,
            'name', v_name,
            'active', v_active,
            'grn_lines', v_grn_lines,
            'order_lines', v_order_lines,
            'grn_rates', v_grn_rates,
            'price_rows', v_prices,
            'rate_count', v_rates,
            'in_use', (v_grn_lines + v_order_lines + v_grn_rates) > 0,
            'can_delete', (v_grn_lines + v_order_lines + v_grn_rates) = 0
        )
    );
END;
$$;

ALTER FUNCTION public.get_item_usage(p_item_id uuid) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION public.get_item_usage(p_item_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.get_item_usage(p_item_id uuid) TO service_role;
GRANT ALL ON FUNCTION public.get_item_usage(p_item_id uuid) TO authenticated;

-- The delete check and get_item_usage count grn_rates by item.
CREATE INDEX IF NOT EXISTS grn_rates_item_id_idx ON public.grn_rates USING btree (item_id);
