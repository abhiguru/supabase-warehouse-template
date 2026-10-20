-- Customer name rule (tweak 2026-10-20): names that differ only in capitals or spaces are the same name.
-- "Acme Foods", "ACME Foods" and " Acme  Foods " have one key (utils.customer_name_key: lower case, every run of white space
-- incl. tab, newline, no-break and other Unicode spaces made one space, trimmed; the same fold as the app's). create_customer and update_customer refuse a second customer with a key already used by ANY
-- customer (active, deactivated or deleted, the same population as customers_name_key) with DUPLICATE_NAME and the holder in
-- error.details. update_customer checks only when p_name is sent and its key differs from the customer's own.
-- The unique index customers_name_norm_key makes two concurrent saves unable to both pass; a violation of it is answered as
-- DUPLICATE_NAME like customers_name_key. The index fails to build if two rows already share a key (no production installs;
-- check Dev first). Grants of both functions are kept (CREATE OR REPLACE). The bodies are copied from 112 (create_customer)
-- and 116 (update_customer); only the name check and the constraint list in the handler are new.

CREATE FUNCTION utils.customer_name_key(p_name text) RETURNS text
    LANGUAGE sql IMMUTABLE
    SET search_path TO ''
    AS $$
    SELECT pg_catalog.btrim(pg_catalog.regexp_replace(pg_catalog.lower(p_name),
        '[\s\u00A0\u1680\u2000-\u200A\u2028\u2029\u202F\u205F\u3000\uFEFF]+', ' ', 'g'), ' ');
$$;

ALTER FUNCTION utils.customer_name_key(text) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION utils.customer_name_key(text) FROM PUBLIC;
-- Postgres checks EXECUTE on an index expression's function as the writing role, so service_role (GRANT ALL on customers)
-- must be able to run it or every INSERT and non-HOT UPDATE of customers would fail.
GRANT EXECUTE ON FUNCTION utils.customer_name_key(text) TO service_role;

CREATE UNIQUE INDEX customers_name_norm_key ON public.customers (utils.customer_name_key(name));

CREATE OR REPLACE FUNCTION public.create_customer(p_name character varying, p_mobile character varying, p_email character varying DEFAULT NULL::character varying, p_address text DEFAULT NULL::text, p_city character varying DEFAULT NULL::character varying, p_state character varying DEFAULT NULL::character varying, p_pincode character varying DEFAULT NULL::character varying, p_gst_number character varying DEFAULT NULL::character varying, p_pan_number character varying DEFAULT NULL::character varying, p_contact_person character varying DEFAULT NULL::character varying, p_contact_mobile character varying DEFAULT NULL::character varying, p_contact_email character varying DEFAULT NULL::character varying, p_image_urls text[] DEFAULT NULL::text[], p_document_urls text[] DEFAULT NULL::text[]) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'extensions', 'utils', 'pg_temp'
    AS $_$
DECLARE
    v_customer_id UUID;
    v_image_count INTEGER;
    v_document_count INTEGER;
    v_mobile text;
    v_key text;
    v_other RECORD;
    v_constraint text;
    v_nkey text;
BEGIN
  PERFORM warehouse_security.authorize_rpc('create_customer',jsonb_build_object());
    -- The list-refresh lock comes before any row lock (migration 46).
    PERFORM pg_advisory_xact_lock(71040);
    IF NOT is_admin_or_supervisor() THEN
        RETURN utils.permission_denied_response('admins and supervisors');
    END IF;

    IF p_name IS NULL OR TRIM(p_name) = '' THEN
        RETURN utils.validation_error_response('name', 'Customer name is required');
    END IF;

    v_mobile := regexp_replace(COALESCE(p_mobile, ''), '[\s+()\-.]', '', 'g');
    IF v_mobile !~ '^[0-9]{10,15}$' THEN
        RETURN utils.validation_error_response('mobile', 'Mobile number must be 10-15 digits');
    END IF;
    v_key := utils.mobile_key(v_mobile);

    -- R2-01: another ACTIVE customer with this number refuses the Add. A deactivated one does not.
    SELECT c.id, c.name INTO v_other
    FROM customers c
    WHERE c.active = true AND c.deleted_at IS NULL
      AND utils.mobile_key(c.mobile) = v_key
    ORDER BY c.name, c.id LIMIT 1;
    IF v_other.id IS NOT NULL THEN
        RETURN jsonb_set(utils.error_response('DUPLICATE_MOBILE', 'A customer with this mobile number already exists', NULL, 'mobile'),
            '{error,details}', jsonb_build_object('customer_id', v_other.id, 'name', v_other.name, 'active', true));
    END IF;

    -- Names that differ only in capitals or spaces are the same name (owner decision 2026-10-20). All customers count:
    -- active, deactivated and deleted, as customers_name_key does.
    v_nkey := utils.customer_name_key(p_name);
    SELECT c.id, c.name, c.active INTO v_other
    FROM customers c
    WHERE utils.customer_name_key(c.name) = v_nkey
    ORDER BY c.name, c.id LIMIT 1;
    IF v_other.id IS NOT NULL THEN
        RETURN jsonb_set(utils.error_response('DUPLICATE_NAME', 'A customer with this name already exists', NULL, 'name'),
            '{error,details}', jsonb_build_object('customer_id', v_other.id, 'name', v_other.name, 'active', v_other.active));
    END IF;

    v_image_count := COALESCE(array_length(p_image_urls, 1), 0);
    v_document_count := COALESCE(array_length(p_document_urls, 1), 0);

    INSERT INTO customers (
        name, mobile, email, address, city, state, pincode,
        gst, pan, contact_person, contact_mobile, contact_email,
        image_urls, document_urls
    )
    VALUES (
        TRIM(p_name), v_mobile, p_email, p_address, p_city, p_state, p_pincode,
        p_gst_number, p_pan_number, p_contact_person, p_contact_mobile, p_contact_email,
        p_image_urls, p_document_urls
    )
    RETURNING id INTO v_customer_id;

    RETURN utils.success_response(
        jsonb_build_object(
            'customer_id', v_customer_id,
            'images_saved', v_image_count,
            'documents_saved', v_document_count
        ),
        'Customer created successfully'
    );

EXCEPTION
    WHEN unique_violation THEN
        GET STACKED DIAGNOSTICS v_constraint = CONSTRAINT_NAME;
        IF v_constraint IN ('customers_name_key', 'customers_name_norm_key') THEN
            SELECT c.id, c.name, c.active INTO v_other FROM customers c WHERE utils.customer_name_key(c.name) = utils.customer_name_key(p_name) ORDER BY c.name, c.id LIMIT 1;
            RETURN CASE WHEN v_other.id IS NULL
                        THEN utils.error_response('DUPLICATE_NAME', 'A customer with this name already exists', NULL, 'name')
                        ELSE jsonb_set(utils.error_response('DUPLICATE_NAME', 'A customer with this name already exists', NULL, 'name'),
                            '{error,details}', jsonb_build_object('customer_id', v_other.id, 'name', v_other.name, 'active', v_other.active)) END;
        END IF;
        RETURN utils.database_error_response('Failed to create customer', SQLERRM, SQLSTATE);
    WHEN OTHERS THEN
        RETURN utils.database_error_response('Failed to create customer', SQLERRM, SQLSTATE);
END;
$_$;

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
    v_nkey text;
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

    -- Names that differ only in capitals or spaces are the same name (owner decision 2026-10-20). Checked only when the name is
    -- sent and its key differs from the customer's own, so an unchanged name never refuses. All other customers count.
    IF p_name IS NOT NULL THEN
        v_nkey := utils.customer_name_key(p_name);
        IF v_nkey IS DISTINCT FROM utils.customer_name_key(v_existing.name) THEN
            SELECT c.id, c.name, c.active INTO v_other
            FROM customers c
            WHERE c.id <> p_customer_id AND utils.customer_name_key(c.name) = v_nkey
            ORDER BY c.name, c.id LIMIT 1;
            IF v_other.id IS NOT NULL THEN
                RETURN jsonb_set(utils.error_response('DUPLICATE_NAME', 'A customer with this name already exists', NULL, 'name'),
                    '{error,details}', jsonb_build_object('customer_id', v_other.id, 'name', v_other.name, 'active', v_other.active));
            END IF;
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
        IF v_constraint IN ('customers_name_key', 'customers_name_norm_key') THEN
            SELECT c.id, c.name, c.active INTO v_other FROM customers c WHERE c.id <> p_customer_id AND utils.customer_name_key(c.name) = utils.customer_name_key(p_name) ORDER BY c.name, c.id LIMIT 1;
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
