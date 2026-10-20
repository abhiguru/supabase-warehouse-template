-- Customers review (tweak 2026-10-20): R2-01 duplicate mobile on Add and Edit, R2-02 DUPLICATE_NAME vs
-- DUPLICATE_MOBILE, R2-03 search that can include deactivated customers, R2-09 stale-edit check.
--
-- Mobile numbers are compared by utils.mobile_key: the digits of the number; a 12-digit number that starts with
-- 91 is read as its 10-digit national number and an 11-digit number with a leading trunk 0 loses that 0 (the
-- app's nationalMobileDigits). "+91 98765 43210", "919876543210" and "9876543210" are the same key.
-- On input only spaces, "+", "(", ")", "-" and "." are removed; anything else (letters) is refused, never turned
-- into other digits. The stored text is the digits as sent; it is not shortened.
-- customers_name_key is a plain UNIQUE (name): case-sensitive, and it covers deactivated and deleted rows.
--
-- Old callers keep working: every new parameter has a default, every old key stays, and the old
-- signatures of update_customer and search_customers are dropped so no overload is ambiguous.

CREATE FUNCTION utils.mobile_key(p_mobile text) RETURNS text
    LANGUAGE sql IMMUTABLE
    SET search_path TO ''
    AS $$
    SELECT CASE WHEN length(d) = 12 AND d LIKE '91%' THEN substr(d, 3)
                WHEN length(d) = 11 AND d LIKE '0%' THEN substr(d, 2)
                ELSE d END
    FROM (SELECT pg_catalog.regexp_replace(COALESCE(p_mobile, ''), '\D', '', 'g') AS d) x;
$$;

ALTER FUNCTION utils.mobile_key(text) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION utils.mobile_key(text) FROM PUBLIC;

DROP FUNCTION IF EXISTS public.update_customer(uuid, character varying, character varying, character varying, text, character varying, character varying, character varying, character varying, character varying, boolean, character varying, character varying, character varying, text[]);
DROP FUNCTION IF EXISTS public.search_customers(text, integer);

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
        IF v_constraint = 'customers_name_key' THEN
            SELECT c.id, c.name, c.active INTO v_other FROM customers c WHERE c.name = TRIM(p_name);
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

CREATE FUNCTION public.update_customer(p_customer_id uuid, p_name character varying DEFAULT NULL::character varying, p_mobile character varying DEFAULT NULL::character varying, p_email character varying DEFAULT NULL::character varying, p_address text DEFAULT NULL::text, p_city character varying DEFAULT NULL::character varying, p_state character varying DEFAULT NULL::character varying, p_pincode character varying DEFAULT NULL::character varying, p_gst character varying DEFAULT NULL::character varying, p_pan character varying DEFAULT NULL::character varying, p_active boolean DEFAULT NULL::boolean, p_contact_person character varying DEFAULT NULL::character varying, p_contact_mobile character varying DEFAULT NULL::character varying, p_contact_email character varying DEFAULT NULL::character varying, p_image_urls text[] DEFAULT NULL::text[], p_expected_updated_at timestamp with time zone DEFAULT NULL::timestamp with time zone) RETURNS jsonb
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
                RETURN jsonb_set(utils.error_response('DUPLICATE_MOBILE', 'A customer with this mobile number already exists', NULL, 'mobile'),
                    '{error,details}', jsonb_build_object('customer_id', v_other.id, 'name', v_other.name, 'active', true));
            END IF;
        ELSE
            v_mobile := NULL; -- same number as now: keep the stored text
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

CREATE FUNCTION public.search_customers(p_search_query text, p_limit integer DEFAULT 20, p_include_inactive boolean DEFAULT false) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'extensions', 'utils', 'pg_temp'
    AS $$
DECLARE
    v_result jsonb;
    v_query text := btrim(COALESCE(p_search_query, ''));
    v_prefix text := replace(replace(replace(btrim(COALESCE(p_search_query, '')), '\', '\\'), '%', '\%'), '_', '\_');
    -- A query made only of digits and number punctuation also matches by the digits of the mobile number
    -- ("+91 98765 43210" finds 9876543210 and 919876543210).
    v_digits text := CASE WHEN btrim(COALESCE(p_search_query, '')) ~ '^[0-9+()\-. ]+$'
                          THEN regexp_replace(p_search_query, '\D', '', 'g') ELSE '' END;
    v_dkey text;
    -- Deactivated customers are listed only for administrators and supervisors (user_accessible_customers()
    -- returns active customers only); soft-deleted customers are never listed.
    v_inactive boolean := COALESCE(p_include_inactive, false)
                          AND warehouse_security.active_role() IN ('admin', 'supervisor');
BEGIN
  PERFORM warehouse_security.authorize_rpc('search_customers',jsonb_build_object());
    v_dkey := utils.mobile_key(v_digits);
    SELECT COALESCE(
        jsonb_agg(sub.customer_row ORDER BY sub.rank, sub.name, sub.id),
        '[]'::jsonb
    ) INTO v_result
    FROM (
        SELECT jsonb_build_object(
            'id', c.id,
            'name', c.name,
            'mobile', c.mobile,
            'city', c.city,
            'email', c.email,
            'address', c.address,
            'active', c.active,
            'deleted', c.deleted_at IS NOT NULL
        ) as customer_row,
        c.name, c.id,
        CASE WHEN v_query = '' OR c.name ILIKE v_prefix || '%' OR c.mobile ILIKE v_prefix || '%' OR s.hit THEN 0 ELSE 1 END AS rank
        FROM customers c,
        LATERAL (SELECT v_digits <> '' AND (
                     s0.d LIKE v_digits || '%'
                     OR s0.k LIKE v_dkey || '%'
                     OR (v_digits LIKE '91%' AND length(v_digits) > 2 AND s0.k LIKE substr(v_digits, 3) || '%')
                 ) AS hit
                 FROM (SELECT regexp_replace(COALESCE(c.mobile, ''), '\D', '', 'g') AS d, utils.mobile_key(c.mobile) AS k) s0) s
        WHERE (CASE WHEN v_inactive THEN c.deleted_at IS NULL
                    ELSE c.active = true AND c.deleted_at IS NULL AND c.id = ANY(user_accessible_customers()) END)
          AND (
              v_query = ''
              OR c.mobile ILIKE v_prefix || '%'
              OR s.hit
              OR NOT EXISTS (
                  SELECT 1 FROM regexp_split_to_table(v_query, '\s+') AS w(word)
                  WHERE c.name NOT ILIKE '%' || replace(replace(replace(w.word, '\', '\\'), '%', '\%'), '_', '\_') || '%'
              )
          )
        ORDER BY rank, c.name, c.id
        LIMIT p_limit
    ) sub;

    RETURN utils.success_response(v_result);
END;
$$;

REVOKE ALL ON FUNCTION public.update_customer(uuid, character varying, character varying, character varying, text, character varying, character varying, character varying, character varying, character varying, boolean, character varying, character varying, character varying, text[], timestamp with time zone) FROM PUBLIC;
GRANT ALL ON FUNCTION public.update_customer(uuid, character varying, character varying, character varying, text, character varying, character varying, character varying, character varying, character varying, boolean, character varying, character varying, character varying, text[], timestamp with time zone) TO service_role;
GRANT ALL ON FUNCTION public.update_customer(uuid, character varying, character varying, character varying, text, character varying, character varying, character varying, character varying, character varying, boolean, character varying, character varying, character varying, text[], timestamp with time zone) TO authenticated;
REVOKE ALL ON FUNCTION public.search_customers(text, integer, boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION public.search_customers(text, integer, boolean) TO service_role;
GRANT ALL ON FUNCTION public.search_customers(text, integer, boolean) TO authenticated;
