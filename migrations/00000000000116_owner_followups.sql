-- Owner follow-ups (2026-10-20), two decisions:
--  1. Activate is refused while another ACTIVE, undeleted customer has the same mobile (utils.mobile_key). Add and Edit already
--     refuse (the customers review migration); this closes the activation paths: set_customer_active(id, true),
--     update_customer(..., p_active => true) on a deactivated or deleted customer, and the legacy restore_customer.
--     Answer: DUPLICATE_MOBILE, field 'mobile', details {customer_id, name, active:true} of the OTHER customer; nothing changes.
--     A customer with no mobile is never refused. A normal edit of an already active customer is not re-checked.
--  2. assign_customer_to_user refuses a person whose role is not Customer: ROLE_NOT_CUSTOMER. remove_customer_assignment is unchanged
--     (a stale assignment of a non-customer can still be removed).
-- Items (asked for by the Items review): update_item compares the name with the TRIM of the stored one and answers rate_source 'standard'
--  when switching an item on gave it the standard tiers; delete_item_safe answers error_code NOT_FOUND for an unknown item.
-- Function bodies are those of the customers review (update_customer) and users review (assign_customer_to_user) migrations plus
-- the checks marked below (utils.mobile_key answers '' for no number, never NULL, so the checks test <> ''; a customer with no number is never refused); set_customer_active and restore_customer are the baseline bodies plus the check. Owners and grants stay.


CREATE OR REPLACE FUNCTION public.set_customer_active(p_customer_id uuid, p_active boolean) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'extensions', 'utils', 'pg_temp'
    AS $$
DECLARE
  v_customer public.customers;
  v_profile_id uuid;
  v_other RECORD;
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
  -- Owner decision 2026-10-20: not while another active customer uses this mobile.
  IF p_active AND utils.mobile_key(v_customer.mobile) <> '' THEN
    SELECT c.id, c.name INTO v_other
    FROM public.customers c
    WHERE c.id <> p_customer_id AND c.active = true AND c.deleted_at IS NULL
      AND utils.mobile_key(c.mobile) = utils.mobile_key(v_customer.mobile)
    ORDER BY c.name, c.id LIMIT 1;
    IF v_other.id IS NOT NULL THEN
      RETURN jsonb_set(utils.error_response('DUPLICATE_MOBILE', v_other.name || ' already uses this mobile number. Change one of the numbers first.', NULL, 'mobile'),
        '{error,details}', jsonb_build_object('customer_id', v_other.id, 'name', v_other.name, 'active', true));
    END IF;
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
$$;

-- Legacy: still activates a deleted or inactive customer, so it gets the same refusal.
CREATE OR REPLACE FUNCTION public.restore_customer(p_customer_id uuid) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'extensions', 'utils', 'pg_temp'
    AS $$
DECLARE
    v_customer_name VARCHAR(100);
    v_mobile text;
    v_other RECORD;
BEGIN
  PERFORM warehouse_security.authorize_rpc('restore_customer',jsonb_build_object('p_customer_id',p_customer_id));
    -- The list-refresh lock comes before any row lock (migration 46).
    PERFORM pg_advisory_xact_lock(71040);
    SELECT name, mobile INTO v_customer_name, v_mobile
    FROM customers
    WHERE id = p_customer_id AND (deleted_at IS NOT NULL OR active = FALSE);

    IF v_customer_name IS NULL THEN
        RETURN jsonb_build_object('success', FALSE, 'message', 'Customer not found or not deleted');
    END IF;

    -- Owner decision 2026-10-20: not while another active customer uses this mobile.
    IF utils.mobile_key(v_mobile) <> '' THEN
        SELECT c.id, c.name INTO v_other
        FROM customers c
        WHERE c.id <> p_customer_id AND c.active = true AND c.deleted_at IS NULL
          AND utils.mobile_key(c.mobile) = utils.mobile_key(v_mobile)
        ORDER BY c.name, c.id LIMIT 1;
        IF v_other.id IS NOT NULL THEN
            RETURN jsonb_set(utils.error_response('DUPLICATE_MOBILE', v_other.name || ' already uses this mobile number. Change one of the numbers first.', NULL, 'mobile'),
                '{error,details}', jsonb_build_object('customer_id', v_other.id, 'name', v_other.name, 'active', true));
        END IF;
    END IF;

    UPDATE customers
    SET deleted_at = NULL, deleted_by = NULL, active = TRUE
    WHERE id = p_customer_id;

    RETURN jsonb_build_object(
        'success', TRUE,
        'message', format('Customer "%s" restored successfully', v_customer_name),
        'restored_at', NOW()
    );
END;
$$;


CREATE OR REPLACE FUNCTION public.update_customer(p_customer_id uuid, p_name character varying DEFAULT NULL::character varying, p_mobile character varying DEFAULT NULL::character varying, p_email character varying DEFAULT NULL::character varying, p_address text DEFAULT NULL::text, p_city character varying DEFAULT NULL::character varying, p_state character varying DEFAULT NULL::character varying, p_pincode character varying DEFAULT NULL::character varying, p_gst character varying DEFAULT NULL::character varying, p_pan character varying DEFAULT NULL::character varying, p_active boolean DEFAULT NULL::boolean, p_contact_person character varying DEFAULT NULL::character varying, p_contact_mobile character varying DEFAULT NULL::character varying, p_contact_email character varying DEFAULT NULL::character varying, p_image_urls text[] DEFAULT NULL::text[], p_expected_updated_at timestamp with time zone DEFAULT NULL::timestamp with time zone) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'extensions', 'utils', 'pg_temp'
    AS $_$
DECLARE
    v_existing RECORD;
    v_mobile text;
    v_key text;
    v_own_key text;
    v_other RECORD;
    v_constraint text;
BEGIN
    PERFORM warehouse_security.authorize_rpc('update_customer', jsonb_build_object('p_customer_id', p_customer_id));
    -- The list-refresh lock comes before any row lock (migration 46).
    PERFORM pg_advisory_xact_lock(71040);
    IF NOT is_admin_or_supervisor() THEN
        RETURN utils.permission_denied_response('admins and supervisors');
    END IF;

    SELECT * INTO v_existing FROM customers WHERE id = p_customer_id FOR UPDATE;
    IF v_existing IS NULL THEN
        RETURN utils.not_found_response('Customer', p_customer_id::text);
    END IF;

    -- R2-09: the caller read the row at p_expected_updated_at; someone changed it since.
    IF p_expected_updated_at IS NOT NULL AND v_existing.updated_at IS DISTINCT FROM p_expected_updated_at THEN
        RETURN utils.error_response('STALE_CUSTOMER', 'This customer was changed by someone else. Reload it and try again.', NULL, NULL);
    END IF;

    IF p_name IS NOT NULL AND TRIM(p_name) = '' THEN
        RETURN utils.validation_error_response('name', 'Customer name is required');
    END IF;

    IF p_mobile IS NOT NULL THEN
        v_mobile := regexp_replace(p_mobile, '[\s+()\-.]', '', 'g');
        IF v_mobile !~ '^[0-9]{10,15}$' THEN
            RETURN utils.validation_error_response('mobile', 'Mobile number must be 10-15 digits');
        END IF;
        v_key := utils.mobile_key(v_mobile);
        v_own_key := utils.mobile_key(v_existing.mobile);
        -- R2-01: checked only when the number is sent and differs from the customer's own;
        -- customers that already share a number stay editable.
        IF v_key IS DISTINCT FROM v_own_key THEN
            SELECT c.id, c.name INTO v_other
            FROM customers c
            WHERE c.id <> p_customer_id AND c.active = true AND c.deleted_at IS NULL
              AND utils.mobile_key(c.mobile) = v_key
            ORDER BY c.name, c.id LIMIT 1;
            IF v_other.id IS NOT NULL THEN
                -- The same call also switches the customer on: use the Activate sentence (owner decision 2026-10-20).
                RETURN jsonb_set(utils.error_response('DUPLICATE_MOBILE',
                        CASE WHEN p_active IS TRUE AND (v_existing.active = false OR v_existing.deleted_at IS NOT NULL)
                             THEN v_other.name || ' already uses this mobile number. Change one of the numbers first.'
                             ELSE 'A customer with this mobile number already exists' END, NULL, 'mobile'),
                    '{error,details}', jsonb_build_object('customer_id', v_other.id, 'name', v_other.name, 'active', true));
            END IF;
        ELSE
            v_mobile := NULL; -- same number as now: keep the stored text
        END IF;
    END IF;

    -- Owner decision 2026-10-20: turning a deactivated (or deleted) customer on is refused while another ACTIVE, undeleted
    -- customer has the same mobile key. A customer that is already active and undeleted is not re-checked on a normal edit.
    IF p_active IS TRUE AND (v_existing.active = false OR v_existing.deleted_at IS NOT NULL) AND COALESCE(v_key, utils.mobile_key(v_existing.mobile)) <> '' THEN
        SELECT c.id, c.name INTO v_other
        FROM customers c
        WHERE c.id <> p_customer_id AND c.active = true AND c.deleted_at IS NULL
          AND utils.mobile_key(c.mobile) = COALESCE(v_key, utils.mobile_key(v_existing.mobile))
        ORDER BY c.name, c.id LIMIT 1;
        IF v_other.id IS NOT NULL THEN
            RETURN jsonb_set(utils.error_response('DUPLICATE_MOBILE', v_other.name || ' already uses this mobile number. Change one of the numbers first.', NULL, 'mobile'),
                '{error,details}', jsonb_build_object('customer_id', v_other.id, 'name', v_other.name, 'active', true));
        END IF;
    END IF;

    UPDATE customers SET
        name = COALESCE(TRIM(p_name), name),
        mobile = COALESCE(v_mobile, mobile),
        email = COALESCE(p_email, email),
        address = COALESCE(p_address, address),
        city = COALESCE(p_city, city),
        state = COALESCE(p_state, state),
        pincode = COALESCE(p_pincode, pincode),
        gst = COALESCE(p_gst, gst),
        pan = COALESCE(p_pan, pan),
        active = COALESCE(p_active, active),
        deleted_at = CASE WHEN p_active IS TRUE THEN NULL ELSE deleted_at END,
        deleted_by = CASE WHEN p_active IS TRUE THEN NULL ELSE deleted_by END,
        contact_person = COALESCE(p_contact_person, contact_person),
        contact_mobile = COALESCE(p_contact_mobile, contact_mobile),
        contact_email = COALESCE(p_contact_email, contact_email),
        updated_at = NOW()
    WHERE id = p_customer_id;

    IF p_image_urls IS NOT NULL THEN
        UPDATE customers SET image_urls = p_image_urls WHERE id = p_customer_id;
    END IF;

    RETURN utils.success_response(
        jsonb_build_object('customer_id', p_customer_id),
        'Customer updated successfully'
    );

EXCEPTION
    WHEN unique_violation THEN
        GET STACKED DIAGNOSTICS v_constraint = CONSTRAINT_NAME;
        IF v_constraint = 'customers_name_key' THEN
            SELECT c.id, c.name, c.active INTO v_other FROM customers c WHERE c.name = TRIM(p_name);
            RETURN CASE WHEN v_other.id IS NULL
                        THEN utils.error_response('DUPLICATE_NAME', 'A customer with this name already exists', NULL, 'name')
                        ELSE jsonb_set(utils.error_response('DUPLICATE_NAME', 'A customer with this name already exists', NULL, 'name'),
                            '{error,details}', jsonb_build_object('customer_id', v_other.id, 'name', v_other.name, 'active', v_other.active)) END;
        END IF;
        RETURN utils.database_error_response('Failed to update customer', SQLERRM, SQLSTATE);
    WHEN OTHERS THEN
        RETURN utils.database_error_response('Failed to update customer', SQLERRM, SQLSTATE);
END;
$_$;

CREATE OR REPLACE FUNCTION public.assign_customer_to_user(target_user_mobile character varying, target_customer_id uuid, assigner_comment text DEFAULT NULL::text) RETURNS boolean
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'extensions', 'utils', 'pg_temp'
    AS $$
  DECLARE
      target_user_id uuid;
      customer_name_val varchar(80);
      customer_active_val boolean;
      customer_deleted_val timestamptz;
      assigner_id uuid;
BEGIN
  PERFORM warehouse_security.authorize_rpc('assign_customer_to_user',jsonb_build_object());
      IF NOT is_admin_or_supervisor() THEN
          RAISE EXCEPTION 'PERMISSION_DENIED: Only admins and supervisors can assign customers to users' USING ERRCODE = '42501';
      END IF;

      SELECT id INTO target_user_id
      FROM user_profiles
      WHERE mobile = target_user_mobile AND active = true AND deleted_at IS NULL
      FOR SHARE;  -- waits for a concurrent role change (update_user_role holds the row FOR UPDATE)

      IF target_user_id IS NULL THEN
          RAISE EXCEPTION 'NOT_FOUND: User with mobile % not found or inactive', target_user_mobile;
      END IF;

      IF warehouse_security.active_role() = 'supervisor' THEN
          IF target_user_id = public.get_current_user_profile_id() THEN
              RAISE EXCEPTION 'SELF_EDIT_FORBIDDEN: Supervisors cannot change their own or an administrator''s customer assignments' USING ERRCODE = '42501';
          ELSIF EXISTS (SELECT 1 FROM user_profiles WHERE id = target_user_id AND role = 'admin') THEN
              RAISE EXCEPTION 'CANNOT_MODIFY_ADMIN: Supervisors cannot change their own or an administrator''s customer assignments' USING ERRCODE = '42501';
          END IF;
      END IF;

      IF EXISTS (SELECT 1 FROM user_profiles WHERE id = target_user_id AND is_service_account) THEN
          RAISE EXCEPTION 'SERVICE_ACCOUNT_READ_ONLY: A service account cannot be changed here';
      END IF;

      IF NOT EXISTS (SELECT 1 FROM user_profiles WHERE id = target_user_id AND role = 'customer') THEN
          RAISE EXCEPTION 'ROLE_NOT_CUSTOMER: Customer assignments apply only to the Customer role.';
      END IF;

      SELECT name, active, deleted_at INTO customer_name_val, customer_active_val, customer_deleted_val
      FROM customers
      WHERE id = target_customer_id;

      IF customer_name_val IS NULL OR customer_deleted_val IS NOT NULL THEN
          RAISE EXCEPTION 'NOT_FOUND: Customer with ID % not found', target_customer_id;
      END IF;
      IF NOT customer_active_val THEN
          RAISE EXCEPTION 'CUSTOMER_INACTIVE: Customer % is deactivated', customer_name_val;
      END IF;

      SELECT id INTO assigner_id
      FROM user_profiles
      WHERE auth_user_id = auth.uid();

      INSERT INTO users_customers_new (
          user_profile_id,
          customer_id,
          customer_name,
          assigned_by,
          active
      ) VALUES (
          target_user_id,
          target_customer_id,
          customer_name_val,
          assigner_id,
          true
      )
      ON CONFLICT (user_profile_id, customer_id)
      DO UPDATE SET
          active = true,
          assigned_at = now(),
          assigned_by = assigner_id,
          customer_name = customer_name_val;

      RETURN true;
  END;
$$;

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
    v_added integer := 0;
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
    IF v_name IS DISTINCT FROM TRIM(v_current_name) THEN
      PERFORM pg_advisory_xact_lock(hashtextextended('item_name:' || LOWER(v_name), 0));
    END IF;
    IF v_name IS DISTINCT FROM TRIM(v_current_name)
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
        v_added := warehouse_security.give_standard_rate(p_item_id, warehouse_security.business_date(now()));
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
        'data', CASE WHEN v_added > 0 THEN v_result || jsonb_build_object('rate_source', 'standard') ELSE v_result END
    );
END;
$$;

CREATE OR REPLACE FUNCTION public.delete_item_safe(p_item_id uuid) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'extensions', 'utils', 'pg_temp'
    AS $$
DECLARE
    v_item_name text;
    v_grn_count integer;
    v_order_count integer;
    v_pricing_count integer;
BEGIN
  PERFORM warehouse_security.authorize_rpc('delete_item_safe',jsonb_build_object());
    -- Security check
    IF NOT is_admin_or_supervisor() THEN
        RETURN jsonb_build_object(
            'success', false,
            'message', 'Access denied: Admin or supervisor role required'
        );
    END IF;

    -- Check if item exists
    SELECT name INTO v_item_name FROM items WHERE id = p_item_id;

    IF v_item_name IS NULL THEN
        RETURN jsonb_build_object(
            'success', false,
            'error_code', 'NOT_FOUND',
            'message', 'Item not found'
        );
    END IF;

    -- Check for references in GRN items
    SELECT COUNT(*) INTO v_grn_count
    FROM goodsreceived_trl
    WHERE item_id = p_item_id;

    -- Check for references in order items
    SELECT COUNT(*) INTO v_order_count
    FROM order_items
    WHERE grn_items_item_id = p_item_id;

    -- Check for pricing records (these can be auto-deleted)
    SELECT COUNT(*) INTO v_pricing_count
    FROM item_storage_prices
    WHERE item_id = p_item_id;

    -- If referenced in GRN or Orders, cannot delete
    IF v_grn_count > 0 OR v_order_count > 0 OR EXISTS (SELECT 1 FROM public.grn_rates WHERE item_id = p_item_id) THEN
        RETURN jsonb_build_object(
            'success', false,
            'message', format('Cannot delete item "%s": It is referenced in existing records', v_item_name),
            'references', jsonb_build_object(
                'grn_items_count', v_grn_count,
                'order_items_count', v_order_count,
                'grn_rates_count', (SELECT count(*) FROM public.grn_rates WHERE item_id = p_item_id),
                'pricing_count', v_pricing_count
            )
        );
    END IF;

    -- Delete pricing records first (if any)
    IF v_pricing_count > 0 THEN
        DELETE FROM item_storage_prices WHERE item_id = p_item_id;
    END IF;

    -- Delete the item
    DELETE FROM items WHERE id = p_item_id;

    RETURN jsonb_build_object(
        'success', true,
        'message', format('Item "%s" deleted successfully', v_item_name),
        'deleted_pricing_records', v_pricing_count
    );
END;
$$;
