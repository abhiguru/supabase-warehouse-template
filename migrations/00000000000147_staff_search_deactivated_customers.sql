-- Migration 147: staff may ask search_customers for deactivated customers (WH-26).
--
-- A deactivated customer's stock can still go out on orders and dispatches (W16); only a new GRN is refused. The dispatch "Choose customer" and
-- the order customer choice list deactivated customers with the "Deactivated" tag, so staff need the same reach as administrators and
-- supervisors: p_include_inactive now applies to the role 'staff' too. One change from the migration 112 text: the role list. Staff already
-- see every active customer (user_accessible_customers()), so this adds no customer they could not name before; a customer account stays refused by
-- authorize_rpc and in the function never sees a deactivated customer. Soft-deleted customers are never listed. The app asks for deactivated customers only on the
-- dispatch and order customer pickers; the GRN picker does not, and save_grn still refuses a new GRN for a deactivated customer.
-- Same signature as migration 112, so CREATE OR REPLACE keeps the grants.

CREATE OR REPLACE FUNCTION public.search_customers(p_search_query text, p_limit integer DEFAULT 20, p_include_inactive boolean DEFAULT false) RETURNS jsonb
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
    -- Deactivated customers are listed only for administrators, supervisors and staff (user_accessible_customers()
    -- returns active customers only); never customers. Soft-deleted customers are never listed.
    v_inactive boolean := COALESCE(p_include_inactive, false)
                          AND warehouse_security.active_role() IN ('admin', 'supervisor', 'staff');
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
