-- Migration 135: the order list reads the page first (review finding M5, same shape as get_dispatch_list_with_items in 125).
--  * get_orders_list no longer reads the view v_orders_list, whose CTEs aggregate the lines of EVERY order and pick the latest
--    dispatch of EVERY order, twice per call (count and page). The candidates now come from orders (filters, search, count),
--    the page is cut on the same sort, and the item list, the pending totals and the latest dispatch fields are built only for
--    the orders of the page. The latest dispatch of an order with no pending line (the only sort that needs it) is one index probe.
--    Same output: {success, data:{orders:[...], pagination:{total_count, has_more, limit, offset}}}, same keys, same order.
--  * The page size is clamped to 1..200 and the offset to 0 or more (an out-of-range value used to give an error or the whole list).
--  * p_user_id (the profile that must exist) is honoured only for service_role; any other caller is checked as the session user.
--  * One index: dispatch (source_order_id, created_at DESC), the probe for the latest dispatch of an order. (An index on
--    orders (deleted_at, updated_at DESC, created_at DESC, id) was measured with 5,000 orders and is not used: the page sort is a CASE
--    over a dispatch time, which no orders index serves, and the planner reads the small table in one pass.)
--  * The view v_orders_list is unchanged (service_role reads it).
-- CREATE OR REPLACE keeps the function's owner and its REVOKE/GRANT (same signature).

SET LOCAL maintenance_work_mem = '256MB';

CREATE INDEX IF NOT EXISTS idx_dispatch_source_order_latest ON public.dispatch (source_order_id, created_at DESC);
ANALYZE public.dispatch;

CREATE OR REPLACE FUNCTION public.get_orders_list(p_customer_id uuid DEFAULT NULL::uuid, p_customer_name text DEFAULT NULL::text, p_has_items boolean DEFAULT NULL::boolean, p_user_id uuid DEFAULT NULL::uuid, p_limit integer DEFAULT 50, p_offset integer DEFAULT 0, p_search text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'extensions', 'utils', 'pg_temp'
AS $function$
DECLARE
    v_user_id UUID;
    v_user_profile RECORD;
    v_all_customers BOOLEAN;
    v_accessible_customers UUID[];
    v_terms TEXT[];
    v_limit INTEGER;
    v_offset INTEGER;
    v_orders JSONB;
    v_total_count INTEGER;
    v_has_more BOOLEAN;
BEGIN
  PERFORM warehouse_security.authorize_rpc('get_orders_list',jsonb_build_object('p_customer_id',p_customer_id));
    -- The profile to check: p_user_id only for service_role, the session user for everyone else.
    IF COALESCE(auth.jwt()->>'role', '') = 'service_role' THEN
        v_user_id := COALESCE(p_user_id, auth.uid());
    ELSE
        v_user_id := auth.uid();
    END IF;

    IF v_user_id IS NULL THEN
        RAISE EXCEPTION 'Authentication required';
    END IF;

    SELECT * INTO v_user_profile
    FROM user_profiles WHERE auth_user_id = v_user_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'User profile not found';
    END IF;

    v_limit := LEAST(GREATEST(COALESCE(p_limit, 50), 1), 200);
    v_offset := GREATEST(COALESCE(p_offset, 0), 0);
    v_terms := warehouse_security.search_terms(p_search);

    -- Roles that see every business read all of them; the others only their assigned customers.
    v_all_customers := is_admin_or_supervisor();
    IF NOT v_all_customers THEN
        SELECT user_accessible_customers() INTO v_accessible_customers;
    END IF;

    WITH cand AS MATERIALIZED (
        -- Every order that passes the filters, with the figures the sort and the count need: no line list is built here.
        SELECT o.id AS order_id, o.created_at, o.updated_at,
               CASE WHEN l.pending THEN o.updated_at ELSE ld.created_at END AS sort_key
        FROM public.orders o
        JOIN public.customers c ON c.id = o.customer_id AND c.deleted_at IS NULL
        CROSS JOIN LATERAL (
            SELECT count(*) > 0 AS any_line, COALESCE(bool_or(oi.item_status = 'pending'), false) AS pending
            FROM public.order_items oi WHERE oi.order_id = o.id
        ) l
        LEFT JOIN LATERAL (
            -- The latest dispatch of the order (its own customer's), needed only to sort an order without a pending line.
            SELECT d.created_at FROM public.dispatch d
            WHERE d.source_order_id = o.id AND d.customer_id = o.customer_id AND NOT l.pending
            ORDER BY d.created_at DESC, d.id LIMIT 1
        ) ld ON true
        WHERE o.deleted_at IS NULL
          AND (v_all_customers OR o.customer_id = ANY(v_accessible_customers))
          AND (p_customer_id IS NULL OR o.customer_id = p_customer_id)
          AND (p_customer_name IS NULL OR c.name ILIKE '%' || p_customer_name || '%')
          AND l.any_line
          AND (p_has_items IS NULL OR
               (p_has_items = true AND l.pending) OR
               (p_has_items = false AND NOT l.pending))
          AND NOT EXISTS (SELECT 1 FROM unnest(v_terms) AS term
            WHERE NOT (COALESCE(c.name, '') ILIKE term OR COALESCE(c.city, '') ILIKE term
              OR EXISTS (SELECT 1 FROM public.order_items oi
                WHERE oi.order_id = o.id AND oi.item_status = 'pending'
                  AND (COALESCE(oi.grn_items_item_name, '') ILIKE term OR COALESCE(oi.grn_items_package_mark, '') ILIKE term
                    OR COALESCE(oi.grns_gr_no, '') ILIKE term))))
    ),
    total AS (SELECT count(*)::integer AS n FROM cand),
    page AS (
        SELECT cand.order_id, row_number() OVER (ORDER BY cand.sort_key DESC NULLS LAST, cand.created_at DESC, cand.order_id) AS rn
        FROM cand
        ORDER BY cand.sort_key DESC NULLS LAST, cand.created_at DESC, cand.order_id
        LIMIT v_limit OFFSET v_offset
    )
    SELECT (SELECT n FROM total),
           jsonb_agg(
            jsonb_build_object(
                'id', o.id,
                'customer_id', o.customer_id,
                'customer', jsonb_build_object(
                    'id', o.customer_id,
                    'name', c.name,
                    'active', c.active,
                    'city', c.city,
                    'mobile', c.mobile
                ),
                'status', o.status,
                'updated_by', o.updated_by,
                'updated_by_name', COALESCE(up.display_name, up.name),
                'item_count', li.total_items,
                'quantity_sum', li.total_quantity,
                'items', li.items,
                'created_at', o.created_at,
                'updated_at', o.updated_at,
                'dispatch_id', ld.id,
                'dispatch_no', ld.disp_no,
                'dispatch_created_at', ld.created_at
            ) ORDER BY page.rn)
    INTO v_total_count, v_orders
    FROM page
    JOIN public.orders o ON o.id = page.order_id
    JOIN public.customers c ON c.id = o.customer_id
    LEFT JOIN public.user_profiles up ON up.id = o.updated_by
    CROSS JOIN LATERAL (
        SELECT (count(*) FILTER (WHERE oi.item_status = 'pending'))::integer AS total_items,
               (COALESCE(sum(oi.requested_quantity) FILTER (WHERE oi.item_status = 'pending'), 0))::numeric AS total_quantity,
               COALESCE(jsonb_agg(jsonb_build_object('id', oi.id, 'order_id', oi.order_id, 'requested_quantity', oi.requested_quantity, 'fulfilled_quantity', oi.fulfilled_quantity, 'grn_items_id', oi.grn_items_id, 'grn_items_item_id', oi.grn_items_item_id, 'grn_items_item_name', oi.grn_items_item_name, 'grn_items_package_mark', oi.grn_items_package_mark, 'grn_items_packaging', oi.grn_items_packaging, 'grn_items_rack', oi.grn_items_rack, 'grn_items_weight', oi.grn_items_weight, 'grn_items_image_url', oi.grn_items_image_url, 'grns_id', oi.grns_id, 'grns_gr_no', oi.grns_gr_no, 'grns_date', oi.grns_date, 'grns_customer_id', oi.grns_customer_id, 'grns_customer_name', oi.grns_customer_name, 'available_stock_at_order', oi.available_stock_at_order, 'current_stock', oi.current_stock, 'item_status', oi.item_status, 'sort_order', oi.sort_order, 'created_at', oi.created_at, 'updated_at', oi.updated_at) ORDER BY oi.sort_order, oi.created_at), '[]'::jsonb) AS items
        FROM public.order_items oi WHERE oi.order_id = o.id
    ) li
    LEFT JOIN LATERAL (
        SELECT d.id, d.disp_no, d.created_at FROM public.dispatch d
        WHERE d.source_order_id = o.id AND d.customer_id = o.customer_id
        ORDER BY d.created_at DESC, d.id LIMIT 1
    ) ld ON true;

    v_total_count := COALESCE(v_total_count, 0);
    v_has_more := v_total_count > (v_offset + v_limit);

    RETURN jsonb_build_object(
        'success', true,
        'data', jsonb_build_object(
            'orders', COALESCE(v_orders, '[]'::jsonb),
            'pagination', jsonb_build_object(
                'total_count', v_total_count,
                'has_more', v_has_more,
                'limit', v_limit,
                'offset', v_offset
            )
        )
    );
END;
$function$;

NOTIFY pgrst, 'reload schema';
