-- Migration 125: load-test fixes (scale check of 2026-10-21, 300 ms bar).
--  * get_dispatch_list_with_items: the page is cut first and the item list is built only for those rows; search and package
--    filters are semi joins; three expression indexes serve the date and the disp_no sorts and the number range. Same output.
--  * get_invoices_list: the main statement runs through EXECUTE ... USING, so it never switches to a generic plan on a reused
--    connection. Same output.
--  * get_customer_invoice_summary: the invoice_items CTE and the payment_status aggregate read only the requested customer's
--    invoices (were: every invoice line and payment of the facility). Same output.
-- CREATE OR REPLACE keeps each function's owner and its REVOKE/GRANT (same signatures).

-- The index expressions are evaluated on every write to public.dispatch; service_role (GRANT ALL on the table) writes directly,
-- and the function is REVOKEd from PUBLIC, so it needs EXECUTE or its INSERT/UPDATE fails.
GRANT EXECUTE ON FUNCTION warehouse_security.document_number_sort_key(text) TO service_role;
CREATE INDEX IF NOT EXISTS idx_dispatch_list_date_desc ON public.dispatch (disp_date DESC NULLS LAST, (warehouse_security.document_number_sort_key(disp_no) COLLATE "C") DESC);
CREATE INDEX IF NOT EXISTS idx_dispatch_list_no_desc ON public.dispatch ((warehouse_security.document_number_sort_key(disp_no) COLLATE "C") DESC NULLS LAST);
CREATE INDEX IF NOT EXISTS idx_dispatch_list_no_asc ON public.dispatch ((warehouse_security.document_number_sort_key(disp_no) COLLATE "C") ASC NULLS LAST);

CREATE OR REPLACE FUNCTION public.get_dispatch_list_with_items(p_customer_id uuid DEFAULT NULL::uuid, p_filters jsonb DEFAULT '{}'::jsonb, p_sort_by text DEFAULT 'dispatch_date'::text, p_sort_order text DEFAULT 'desc'::text, p_page integer DEFAULT 1, p_limit integer DEFAULT 10, p_include_items boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'extensions', 'utils', 'pg_temp'
AS $function$
DECLARE
    v_offset integer;
    v_total_count bigint;
    v_query text;
    v_data jsonb;
    v_disp_no_filter text;
    v_order_by text;
    v_qty_min integer;
    v_qty_max integer;
    v_disp_qty_min integer;
    v_disp_qty_max integer;
    v_user_role text;
    v_user_customer_ids uuid[];
    v_customer_filter text;
    v_disp_no_from text;
    v_disp_no_to text;
    v_disp_no_range_filter text;
    v_filter_customer_ids uuid[];
    v_filter_item_ids uuid[];
    v_item_ids_filter text;
    v_where text;
    v_term text;
BEGIN
  PERFORM warehouse_security.authorize_rpc('get_dispatch_list_with_items',jsonb_build_object('p_customer_id',p_customer_id));
    SELECT role INTO v_user_role FROM user_profiles WHERE auth_user_id = auth.uid();

    IF v_user_role NOT IN ('admin', 'supervisor', 'staff') THEN
        v_user_customer_ids := user_accessible_customers();
        IF v_user_customer_ids IS NULL OR array_length(v_user_customer_ids, 1) IS NULL THEN
            RETURN jsonb_build_object(
                'success', false,
                'message', 'Access denied: No accessible customers found',
                'data', jsonb_build_object(
                    'dispatches', '[]'::jsonb,
                    'total_count', 0,
                    'current_page', p_page,
                    'total_pages', 0,
                    'limit', p_limit
                )
            );
        END IF;
    END IF;

    v_offset := (p_page - 1) * p_limit;

    -- Extract quantity filters (snake_case)
    v_qty_min := (p_filters->>'qty_min')::integer;
    v_qty_max := (p_filters->>'qty_max')::integer;
    v_disp_qty_min := (p_filters->>'disp_qty_min')::integer;
    v_disp_qty_max := (p_filters->>'disp_qty_max')::integer;

    -- Extract customer_ids array filter
    IF p_filters ? 'customer_ids' AND jsonb_typeof(p_filters->'customer_ids') = 'array'
       AND jsonb_array_length(p_filters->'customer_ids') > 0 THEN
        SELECT array_agg(elem::text::uuid)
        INTO v_filter_customer_ids
        FROM jsonb_array_elements_text(p_filters->'customer_ids') AS elem;
    END IF;

    -- Extract item_ids array filter
    IF p_filters ? 'item_ids' AND jsonb_typeof(p_filters->'item_ids') = 'array'
       AND jsonb_array_length(p_filters->'item_ids') > 0 THEN
        SELECT array_agg(elem::text::uuid)
        INTO v_filter_item_ids
        FROM jsonb_array_elements_text(p_filters->'item_ids') AS elem;
    END IF;

    -- Extract dispatch number range filters (snake_case only)
    IF p_filters ? 'disp_no_from' THEN
        v_disp_no_from := p_filters->>'disp_no_from';
        v_disp_no_from := LTRIM(TRIM(v_disp_no_from), '#');
    END IF;

    IF p_filters ? 'disp_no_to' THEN
        v_disp_no_to := p_filters->>'disp_no_to';
        v_disp_no_to := LTRIM(TRIM(v_disp_no_to), '#');
    END IF;

    -- Build customer filter based on role and parameters
    IF v_user_role IN ('admin', 'supervisor', 'staff') THEN
        -- Admin/supervisor: use customer_ids array if provided, else single p_customer_id
        IF v_filter_customer_ids IS NOT NULL AND array_length(v_filter_customer_ids, 1) > 0 THEN
            v_customer_filter := format(' AND d.customer_id = ANY(%L::uuid[])', v_filter_customer_ids);
        ELSIF p_customer_id IS NOT NULL THEN
            v_customer_filter := format(' AND d.customer_id = %L', p_customer_id);
        ELSE
            v_customer_filter := '';
        END IF;
    ELSE
        -- Non-admin: filter by customer_ids intersected with accessible customers
        IF v_filter_customer_ids IS NOT NULL AND array_length(v_filter_customer_ids, 1) > 0 THEN
            -- Intersect requested customer_ids with user's accessible customers
            SELECT array_agg(cid)
            INTO v_filter_customer_ids
            FROM unnest(v_filter_customer_ids) AS cid
            WHERE cid = ANY(v_user_customer_ids);

            IF v_filter_customer_ids IS NULL OR array_length(v_filter_customer_ids, 1) IS NULL THEN
                RETURN jsonb_build_object(
                    'success', false,
                    'message', 'Access denied: None of the requested customers are accessible',
                    'data', jsonb_build_object(
                        'dispatches', '[]'::jsonb,
                        'total_count', 0,
                        'current_page', p_page,
                        'total_pages', 0,
                        'limit', p_limit
                    )
                );
            END IF;
            v_customer_filter := format(' AND d.customer_id = ANY(%L::uuid[])', v_filter_customer_ids);
        ELSIF p_customer_id IS NOT NULL THEN
            IF p_customer_id = ANY(v_user_customer_ids) THEN
                v_customer_filter := format(' AND d.customer_id = %L', p_customer_id);
            ELSE
                RETURN jsonb_build_object(
                    'success', false,
                    'message', 'Access denied: Customer not accessible',
                    'data', jsonb_build_object(
                        'dispatches', '[]'::jsonb,
                        'total_count', 0,
                        'current_page', p_page,
                        'total_pages', 0,
                        'limit', p_limit
                    )
                );
            END IF;
        ELSE
            v_customer_filter := format(' AND d.customer_id = ANY(%L::uuid[])', v_user_customer_ids);
        END IF;
    END IF;

    -- Build item_ids filter
    IF v_filter_item_ids IS NOT NULL AND array_length(v_filter_item_ids, 1) > 0 THEN
        v_item_ids_filter := format(' AND EXISTS (SELECT 1 FROM dispatch_trl dt_item JOIN goodsreceived_trl grt_item ON dt_item.gr_trl_id = grt_item.id WHERE dt_item.disp_id = d.id AND grt_item.item_id = ANY(%L::uuid[]))', v_filter_item_ids);
    ELSE
        v_item_ids_filter := '';
    END IF;

    -- Package: every word must be in the package of one line
    IF btrim(COALESCE(p_filters->>'package_mark', '')) <> '' THEN
        v_item_ids_filter := v_item_ids_filter || format(
            ' AND d.id IN (SELECT dt_pkg.disp_id FROM dispatch_trl dt_pkg JOIN goodsreceived_trl grt_pkg ON dt_pkg.gr_trl_id = grt_pkg.id WHERE NOT EXISTS (SELECT 1 FROM unnest(%L::text[]) AS term WHERE NOT COALESCE(grt_pkg.package_mark, '''') ILIKE term))',
            warehouse_security.search_terms(p_filters->>'package_mark'));
    END IF;

    -- Quick search: every word must match the dispatch or one of its lines (one semi-join per word)
    IF btrim(COALESCE(p_filters->>'search', '')) <> '' THEN
        FOREACH v_term IN ARRAY warehouse_security.search_terms(p_filters->>'search') LOOP
            v_item_ids_filter := v_item_ids_filter || format(
                ' AND d.id IN (SELECT d2.id FROM dispatch d2 WHERE d2.disp_no ILIKE %1$L OR COALESCE(d2.customer_name, '''') ILIKE %1$L OR COALESCE(d2.registration, '''') ILIKE %1$L UNION SELECT dt_s.disp_id FROM dispatch_trl dt_s JOIN goodsreceived_trl grt_s ON dt_s.gr_trl_id = grt_s.id JOIN goodsreceived gr_s ON grt_s.gr_id = gr_s.id WHERE COALESCE(grt_s.item_name, '''') ILIKE %1$L OR COALESCE(grt_s.package_mark, '''') ILIKE %1$L OR COALESCE(grt_s.rack, '''') ILIKE %1$L OR gr_s.gr_no ILIKE %1$L)',
                v_term);
        END LOOP;
    END IF;

    -- Check if disp_no filter is present
    IF p_filters ? 'disp_no' AND p_filters->>'disp_no' IS NOT NULL AND p_filters->>'disp_no' != '' THEN
        v_disp_no_filter := format(' AND d.disp_no ILIKE %L', p_filters->>'disp_no' || '%');
        v_order_by := '(warehouse_security.document_number_sort_key(disp_no) COLLATE "C") DESC NULLS LAST';
    ELSE
        v_disp_no_filter := '';
        v_order_by := CASE
            WHEN p_sort_by = 'dispatch_date' THEN
                'disp_date ' || CASE WHEN LOWER(p_sort_order) = 'asc' THEN 'ASC' ELSE 'DESC' END ||
                ' NULLS LAST, (warehouse_security.document_number_sort_key(disp_no) COLLATE "C") ' || CASE WHEN LOWER(p_sort_order) = 'asc' THEN 'ASC' ELSE 'DESC' END
            WHEN p_sort_by = 'disp_no' THEN
                '(warehouse_security.document_number_sort_key(disp_no) COLLATE "C") ' ||
                CASE WHEN LOWER(p_sort_order) = 'asc' THEN 'ASC' ELSE 'DESC' END || ' NULLS LAST'
            WHEN p_sort_by = 'customer_name' THEN
                'customer_name ' || CASE WHEN LOWER(p_sort_order) = 'asc' THEN 'ASC' ELSE 'DESC' END ||
                ' NULLS LAST, disp_date DESC NULLS LAST, (warehouse_security.document_number_sort_key(disp_no) COLLATE "C") DESC'
            ELSE
                'disp_date DESC NULLS LAST, (warehouse_security.document_number_sort_key(disp_no) COLLATE "C") DESC'
        END;
    END IF;

    -- Build dispatch number range filter
    IF v_disp_no_from IS NOT NULL AND LENGTH(v_disp_no_from) > 0 AND
       v_disp_no_to IS NOT NULL AND LENGTH(v_disp_no_to) > 0 THEN
        v_disp_no_range_filter := format(' AND (warehouse_security.document_number_sort_key(d.disp_no) COLLATE "C") BETWEEN (warehouse_security.document_number_sort_key(%L) COLLATE "C") AND (warehouse_security.document_number_sort_key(%L) COLLATE "C")', v_disp_no_from, v_disp_no_to);
    ELSIF v_disp_no_from IS NOT NULL AND LENGTH(v_disp_no_from) > 0 THEN
        v_disp_no_range_filter := format(' AND (warehouse_security.document_number_sort_key(d.disp_no) COLLATE "C") >= (warehouse_security.document_number_sort_key(%L) COLLATE "C")', v_disp_no_from);
    ELSIF v_disp_no_to IS NOT NULL AND LENGTH(v_disp_no_to) > 0 THEN
        v_disp_no_range_filter := format(' AND (warehouse_security.document_number_sort_key(d.disp_no) COLLATE "C") <= (warehouse_security.document_number_sort_key(%L) COLLATE "C")', v_disp_no_to);
    ELSE
        v_disp_no_range_filter := '';
    END IF;

    v_where := format(' %s %s %s %s %s %s %s %s %s %s',
        v_customer_filter, v_disp_no_filter, v_disp_no_range_filter,
        CASE WHEN p_filters ? 'date_from' AND p_filters->>'date_from' IS NOT NULL
            THEN format(' AND d.disp_date >= %L::timestamptz', p_filters->>'date_from') ELSE '' END,
        CASE WHEN p_filters ? 'date_to' AND p_filters->>'date_to' IS NOT NULL
            THEN format(' AND d.disp_date <= %L::timestamptz', p_filters->>'date_to') ELSE '' END,
        CASE WHEN p_filters ? 'created_date_from' AND p_filters->>'created_date_from' IS NOT NULL
            THEN format(' AND d.created_at >= %L::timestamptz', p_filters->>'created_date_from') ELSE '' END,
        CASE WHEN p_filters ? 'created_date_to' AND p_filters->>'created_date_to' IS NOT NULL
            THEN format(' AND d.created_at <= %L::timestamptz', p_filters->>'created_date_to') ELSE '' END,
        CASE WHEN v_qty_min IS NOT NULL OR v_qty_max IS NOT NULL THEN
            format(' AND EXISTS (SELECT 1 FROM dispatch_trl dt2 JOIN goodsreceived_trl grt2 ON dt2.gr_trl_id = grt2.id WHERE dt2.disp_id = d.id AND grt2.qty >= %s AND grt2.qty <= %s)',
            COALESCE(v_qty_min, 0), COALESCE(v_qty_max, 999999999)) ELSE '' END,
        CASE WHEN v_disp_qty_min IS NOT NULL OR v_disp_qty_max IS NOT NULL THEN
            format(' AND EXISTS (SELECT 1 FROM dispatch_trl dt3 WHERE dt3.disp_id = d.id AND dt3.disp_qty >= %s AND dt3.disp_qty <= %s)',
            COALESCE(v_disp_qty_min, 0), COALESCE(v_disp_qty_max, 999999999)) ELSE '' END,
        v_item_ids_filter);

    -- Build the main query (snake_case response keys)
    v_query := format($query$
        WITH paged AS (
            SELECT d.id, d.disp_no, d.disp_date, d.customer_id, d.customer_name,
                d.registration, d.created_at, d.updated_at, d.created_by, d.updated_by, d.note
            FROM dispatch d
            WHERE 1=1 %s
            ORDER BY %s LIMIT %s OFFSET %s
        ),
        total AS (
            SELECT COUNT(*) AS n FROM dispatch d WHERE 1=1 %s
        ),
        dispatch_items AS (
            SELECT dt.disp_id, %s as items,
                SUM(dt.disp_qty) as total_qty,
                SUM(dt.disp_qty * grt.weight::numeric) as total_weight,
                COUNT(DISTINCT grt.item_id) as item_count
            FROM dispatch_trl dt
            JOIN goodsreceived_trl grt ON dt.gr_trl_id = grt.id
            JOIN goodsreceived gr ON grt.gr_id = gr.id
            WHERE dt.disp_id IN (SELECT id FROM paged)
            GROUP BY dt.disp_id
        ),
        dispatch_aggregates AS (
            SELECT fd.*, COALESCE(di.total_qty, 0) as total_qty,
                COALESCE(di.total_weight, 0) as total_weight,
                COALESCE(di.item_count, 0) as item_count, di.items
            FROM paged fd
            LEFT JOIN dispatch_items di ON fd.id = di.disp_id
        ),
        paginated_results AS (
            SELECT * FROM dispatch_aggregates ORDER BY %s
        )
        SELECT jsonb_build_object(
            'success', true,
            'data', jsonb_build_object(
                'dispatches', COALESCE(jsonb_agg(
                    jsonb_build_object(
                        'id', pr.id,
                        'disp_no', pr.disp_no,
                        'dispatch_date', pr.disp_date,
                        'customer_id', pr.customer_id,
                        'customer_name', pr.customer_name,
                        'registration', pr.registration,
                        'total_qty', pr.total_qty,
                        'total_weight', pr.total_weight,
                        'item_count', pr.item_count,
                        'items', pr.items,
                        'notes', pr.note,
                        'created_at', pr.created_at,
                        'updated_at', pr.updated_at,
                        'created_by', pr.created_by,
                        'updated_by', pr.updated_by
                    ) ORDER BY %s
                ), '[]'::jsonb),
                'total_count', (SELECT n FROM total),
                'current_page', %s,
                'total_pages', CEIL((SELECT n::numeric FROM total) / %s::numeric),
                'limit', %s
            )
        ) as result
        FROM paginated_results pr
    $query$,
        v_where, v_order_by, p_limit, v_offset, v_where,
        CASE WHEN p_include_items THEN
            'jsonb_agg(jsonb_build_object(
                ''item_id'', grt.item_id, ''item_name'', grt.item_name, ''disp_qty'', dt.disp_qty,
                ''weight'', grt.weight, ''gr_no'', gr.gr_no, ''grn_qty'', grt.qty,
                ''grn_item_id'', grt.id, ''package_mark'', grt.package_mark, ''rack'', grt.rack
            ) ORDER BY grt.item_name, grt.id)'
        ELSE 'NULL::jsonb' END,
        v_order_by, v_order_by, p_page, p_limit, p_limit
    );

    EXECUTE v_query INTO v_data;
    RETURN v_data;
EXCEPTION
    WHEN OTHERS THEN
        RETURN jsonb_build_object(
            'success', false,
            'message', 'An error occurred: ' || SQLERRM,
            'data', jsonb_build_object(
                'dispatches', '[]'::jsonb,
                'total_count', 0,
                'current_page', p_page,
                'total_pages', 0,
                'limit', p_limit
            )
        );
END;
$function$;

CREATE OR REPLACE FUNCTION public.get_invoices_list(p_limit integer DEFAULT 50, p_offset integer DEFAULT 0, p_customer_id uuid DEFAULT NULL::uuid, p_financial_year integer DEFAULT NULL::integer, p_search_invoice_no text DEFAULT NULL::text, p_search_grn_no text DEFAULT NULL::text, p_sort_field text DEFAULT 'inv_date'::text, p_sort_direction text DEFAULT 'desc'::text, p_inv_no_from integer DEFAULT NULL::integer, p_inv_no_to integer DEFAULT NULL::integer, p_search text DEFAULT NULL::text, p_date_from timestamp with time zone DEFAULT NULL::timestamp with time zone, p_date_to timestamp with time zone DEFAULT NULL::timestamp with time zone, p_customer_ids uuid[] DEFAULT NULL::uuid[])
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'extensions', 'utils', 'pg_temp'
AS $function$
DECLARE
    v_user_role text;
    v_all_customers boolean := false;
    v_accessible_customers uuid[] := ARRAY[]::uuid[];
    v_total_count integer;
    v_data jsonb;
BEGIN
  PERFORM warehouse_security.authorize_rpc('get_invoices_list',jsonb_build_object('p_customer_id',p_customer_id));
    -- Which customers the caller may see: administrators, supervisors and staff see every customer that is
    -- not deleted; other roles see the customers assigned to them; nobody signed in sees nothing.
    IF auth.uid() IS NOT NULL THEN
        SELECT role INTO v_user_role
        FROM public.user_profiles
        WHERE auth_user_id = auth.uid();

        IF v_user_role IN ('admin', 'supervisor', 'staff') THEN
            v_all_customers := true;
        ELSE
            SELECT public.user_accessible_customers() INTO v_accessible_customers;
        END IF;
    END IF;

    EXECUTE $tmpl$WITH f AS MATERIALIZED (
        -- The filtered set: once, for the page and for the count.
        SELECT i.id AS invoice_id, i.inv_no, i.inv_fin_year, i.inv_date, i.total,
               c.name AS customer_name, gr.gr_no
        FROM public.invoice i
        JOIN public.customers c ON c.id = i.customer_id
        JOIN public.goodsreceived gr ON gr.id = i.gr_id
        WHERE i.deleted_at IS NULL
            AND (CASE WHEN $13 THEN c.deleted_at IS NULL ELSE c.id = ANY($14) END)
            AND ($7 IS NULL OR c.id = $7)
            AND ($5 IS NULL OR i.inv_fin_year = $5)
            AND ($3 IS NULL OR $3 = '' OR i.inv_no::text ILIKE '%' || $3 || '%')
            AND ($4 IS NULL OR $4 = '' OR gr.gr_no ILIKE '%' || $4 || '%')
            AND ($8 IS NULL OR i.inv_no >= $8)
            AND ($9 IS NULL OR i.inv_no <= $9)
            AND ($10 IS NULL OR i.inv_date >= $10)
            AND ($11 IS NULL OR i.inv_date <= $11)
            AND ($6 IS NULL OR cardinality($6) = 0 OR c.id = ANY($6))
            AND NOT EXISTS (SELECT 1 FROM unnest(warehouse_security.search_terms($12)) AS term
              WHERE NOT (i.inv_no::text ILIKE term OR COALESCE(c.name, '') ILIKE term OR COALESCE(gr.gr_no, '') ILIKE term
                OR (i.inv_fin_year::text || '-' || i.inv_no::text) ILIKE term
                OR (i.inv_fin_year::text || '-' || lpad(i.inv_no::text, GREATEST(4, LENGTH(i.inv_no::text)), '0')) ILIKE term))
    ), pg AS MATERIALIZED (
        -- The rows of the page, in the requested order; ord keeps that order for the answer.
        SELECT s.invoice_id, row_number() OVER () AS ord
        FROM (
            SELECT m.invoice_id
            FROM f m
            ORDER BY
                -- inv_date sorting with secondary sort by inv_no DESC
                CASE WHEN $15 = 'inv_date' AND $16 = 'desc' THEN m.inv_date END DESC,
                CASE WHEN $15 = 'inv_date' AND $16 = 'asc' THEN m.inv_date END ASC,
                CASE WHEN $15 = 'inv_date' THEN m.inv_no END DESC,
                -- inv_no sorting (invoice number)
                CASE WHEN $15 = 'inv_no' AND $16 = 'desc' THEN m.inv_no END DESC,
                CASE WHEN $15 = 'inv_no' AND $16 = 'asc' THEN m.inv_no END ASC,
                -- invoice_number alias (same as inv_no)
                CASE WHEN $15 = 'invoice_number' AND $16 = 'desc' THEN m.inv_no END DESC,
                CASE WHEN $15 = 'invoice_number' AND $16 = 'asc' THEN m.inv_no END ASC,
                -- customer_name sorting with secondary sort by inv_date DESC, inv_no DESC
                CASE WHEN $15 = 'customer_name' AND $16 = 'desc' THEN m.customer_name END DESC,
                CASE WHEN $15 = 'customer_name' AND $16 = 'asc' THEN m.customer_name END ASC,
                CASE WHEN $15 = 'customer_name' THEN m.inv_date END DESC,
                CASE WHEN $15 = 'customer_name' THEN m.inv_no END DESC,
                -- grn_number / gr_no sorting
                CASE WHEN $15 IN ('grn_number', 'gr_no') AND $16 = 'desc' THEN m.gr_no END DESC,
                CASE WHEN $15 IN ('grn_number', 'gr_no') AND $16 = 'asc' THEN m.gr_no END ASC,
                -- total sorting
                CASE WHEN $15 = 'total' AND $16 = 'desc' THEN m.total END DESC,
                CASE WHEN $15 = 'total' AND $16 = 'asc' THEN m.total END ASC,
                -- financial_year sorting with secondary sort by inv_no DESC
                CASE WHEN $15 = 'financial_year' AND $16 = 'desc' THEN m.inv_fin_year END DESC,
                CASE WHEN $15 = 'financial_year' AND $16 = 'asc' THEN m.inv_fin_year END ASC,
                CASE WHEN $15 = 'financial_year' THEN m.inv_no END DESC,
                -- Default fallback: inv_date DESC, inv_no DESC
                m.inv_date DESC,
                m.inv_no DESC,
                -- Migration 106: rows that tie on every key above keep one fixed order.
                m.invoice_id
            LIMIT $1 OFFSET $2
        ) s
    )
    SELECT (SELECT count(*) FROM f)::integer,
           COALESCE((
               SELECT jsonb_agg(
                   jsonb_build_object(
                       'invoice_id', i.id,
                       'invoice_number', i.inv_no,
                       'invoice_date', i.inv_date,
                       'inv_fin_year', i.inv_fin_year,
                       'financial_year', (i.inv_fin_year || '-'::text) || (i.inv_fin_year + 1),
                       'inv_name', i.inv_name,
                       'invoice_pricing_mode', i.pricing_mode,
                       'notes', i.notes,
                       'is_auto_generated', i.is_auto_generated,
                       'total', i.total,
                       'discount', i.discount,
                       'labour', i.labour,
                       'tax_amount', i.tax_amount,
                       'one_time_charge', i.one_time_charge,
                       'created_by', i.created_by,
                       'total_qty', q.total_qty,
                       'customer', jsonb_build_object(
                           'id', c.id,
                           'name', c.name,
                           'city', c.city,
                           'address', c.address,
                           'phone', c.mobile,
                           'email', c.email,
                           'gst', c.gst,
                           'active', c.active
                       ),
                       'grn', jsonb_build_object(
                           'id', gr.id,
                           'gr_no', gr.gr_no,
                           'registration', gr.registration,
                           'date', gr.date,
                           'sender_id', gr.sender_id,
                           'sender_name', gr.sender_name,
                           'supervisor_id', gr.supervisor_id,
                           'supervisor_name', gr.supervisor_name,
                           'customer_id', gr.customer_id,
                           'customer_name', gr.customer_name
                       )
                   ) ORDER BY pg.ord)
               FROM pg
               JOIN public.invoice i ON i.id = pg.invoice_id
               JOIN public.customers c ON c.id = i.customer_id
               JOIN public.goodsreceived gr ON gr.id = i.gr_id
               -- The line total of the invoice, for the rows of the page only. The inner joins are the ones the
               -- old list view used: a line whose dispatch line or receipt line is missing does not count.
               CROSS JOIN LATERAL (
                   SELECT COALESCE(sum(dt.disp_qty), 0::bigint)::numeric AS total_qty
                   FROM public.invoice_trl it
                   JOIN public.dispatch_trl dt ON dt.id = it.disp_trl_id
                   JOIN public.goodsreceived_trl grt ON grt.id = dt.gr_trl_id
                   WHERE it.invoice_id = i.id
               ) q
           ), '[]'::jsonb)$tmpl$ INTO v_total_count, v_data
      USING p_limit, p_offset, p_search_invoice_no, p_search_grn_no, p_financial_year, p_customer_ids, p_customer_id, p_inv_no_from, p_inv_no_to, p_date_from, p_date_to, p_search, v_all_customers, v_accessible_customers, p_sort_field, p_sort_direction;

    RETURN jsonb_build_object(
        'success', true,
        'data', v_data,
        'pagination', jsonb_build_object(
            'total_count', v_total_count,
            'has_more', (p_offset + p_limit) < v_total_count
        )
    );
END;
$function$;

CREATE OR REPLACE FUNCTION public.get_customer_invoice_summary(p_customer_uuid uuid DEFAULT NULL::uuid, p_from_date date DEFAULT NULL::date, p_to_date date DEFAULT NULL::date, p_financial_year integer DEFAULT NULL::integer) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'extensions', 'utils', 'pg_temp'
    SET jit TO 'off'
    AS $$
DECLARE
    v_user_id uuid;
    v_user_role text;
    v_user_customer_ids uuid[];
    v_from_date date;
    v_to_date date;
    v_result jsonb;
    v_summary jsonb;
    v_invoices jsonb;
    v_by_month jsonb;
    v_by_customer jsonb;
BEGIN
  PERFORM warehouse_security.authorize_rpc('get_customer_invoice_summary',jsonb_build_object('p_customer_uuid',p_customer_uuid));
    -- Get caller's role
    IF auth.uid() IS NOT NULL THEN
        SELECT id, role INTO v_user_id, v_user_role
        FROM user_profiles
        WHERE auth_user_id = auth.uid();
    END IF;

    -- Access control
    IF v_user_role IS NULL THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'Authentication required'
        );
    END IF;

    -- Non-admin/supervisor: get accessible customers
    IF v_user_role NOT IN ('admin', 'supervisor', 'staff') THEN
        SELECT ARRAY_AGG(customer_id) INTO v_user_customer_ids
        FROM users_customers_new
        WHERE user_profile_id = v_user_id;

        -- If no customers assigned, return empty
        IF v_user_customer_ids IS NULL OR array_length(v_user_customer_ids, 1) IS NULL THEN
            RETURN jsonb_build_object(
                'success', true,
                'data', jsonb_build_object(
                    'summary', jsonb_build_object(
                        'total_invoices', 0,
                        'total_amount', 0,
                        'net_amount', 0
                    ),
                    'invoices', '[]'::jsonb,
                    'by_month', '[]'::jsonb
                ),
                'metadata', jsonb_build_object('retrieved_at', NOW())
            );
        END IF;

        -- If specific customer requested, verify access
        IF p_customer_uuid IS NOT NULL AND NOT (p_customer_uuid = ANY(v_user_customer_ids)) THEN
            RETURN jsonb_build_object(
                'success', false,
                'error', 'Access denied: You do not have permission to view this customer''s data'
            );
        END IF;
    END IF;

    -- Set date defaults
    v_from_date := COALESCE(p_from_date, warehouse_security.business_date(now()) - INTERVAL '30 days');
    v_to_date := COALESCE(p_to_date, warehouse_security.business_date(now()));

    -- Single customer view
    IF p_customer_uuid IS NOT NULL THEN
        WITH invoice_data AS (
            SELECT
                i.id as invoice_id,
                i.inv_fin_year::text || '-' || LPAD(i.inv_no::text, GREATEST(4, LENGTH(i.inv_no::text)), '0') as invoice_number,
                i.inv_fin_year,
                i.inv_no,
                i.inv_date,
                i.gr_id,
                gr.gr_no as grn_ref,
                i.total,
                i.labour,
                i.discount,
                i.tax_amount,
                COALESCE(i.total, 0) as net_total,
                i.notes
            FROM invoice i
            LEFT JOIN goodsreceived gr ON i.gr_id = gr.id
            WHERE i.customer_id = p_customer_uuid
                AND i.deleted_at IS NULL
                AND (p_financial_year IS NULL OR i.inv_fin_year = p_financial_year)
                AND i.inv_date >= warehouse_security.business_day_start(v_from_date) AND i.inv_date < warehouse_security.business_day_start(v_to_date + 1)
        ),
        invoice_items AS (
            SELECT
                it.invoice_id,
                COUNT(*) as item_count,
                SUM(dt.disp_qty) as total_quantity,
                jsonb_agg(
                    jsonb_build_object(
                        'item_id', grt.item_id,
                        'item_name', grt.item_name,
                        'packaging', grt.packaging,
                        'quantity', dt.disp_qty,
                        'rate', it.charge,
                        'no_of_days', it.no_of_days,
                        'charge', it.charge,
                        'labour_rate', it.labour_rate,
                        'labour_amount', amount.labour,
                        'tax_percent', it.tax,
                        'tax_amount', ROUND(amount.base * COALESCE(it.tax, 0)::numeric / 100, 2),
                        'line_total', amount.base + ROUND(amount.base * COALESCE(it.tax, 0)::numeric / 100, 2),
                        'grn_item_ref', jsonb_build_object(
                            'gr_no', gr.gr_no,
                            'rack', grt.rack,
                            'package_mark', grt.package_mark
                        )
                    ) ORDER BY grt.item_name, it.id
                ) as line_items
            FROM invoice_trl it
            JOIN dispatch_trl dt ON it.disp_trl_id = dt.id
            JOIN goodsreceived_trl grt ON dt.gr_trl_id = grt.id
            JOIN goodsreceived gr ON grt.gr_id = gr.id
            -- The line amount of get_invoice_items_detailed; labour is 0 for a ONE_TIME receipt.
            CROSS JOIN LATERAL (
                SELECT CASE WHEN gr.pricing_mode = 'ONE_TIME'
                            THEN ROUND(COALESCE(it.charge, 0)::numeric * COALESCE(dt.disp_qty, 0)::numeric, 2)
                            ELSE ROUND(COALESCE(it.charge, 0)::numeric * COALESCE(dt.disp_qty, 0)::numeric * COALESCE(it.duration, 1)::numeric, 2)
                                 + ROUND(COALESCE(it.labour_rate, 0)::numeric * COALESCE(dt.disp_qty, 0)::numeric, 2)
                            END AS base,
                       CASE WHEN gr.pricing_mode = 'ONE_TIME' THEN 0::numeric
                            ELSE ROUND(COALESCE(it.labour_rate, 0)::numeric * COALESCE(dt.disp_qty, 0)::numeric, 2) END AS labour
            ) AS amount
            WHERE it.invoice_id IN (SELECT invoice_id FROM invoice_data)
            GROUP BY it.invoice_id
        ),
        payment_status AS (
            SELECT DISTINCT ON (p.invoice_id)
                p.invoice_id,
                jsonb_build_object(
                    'status', 'paid',
                    'paid_date', p.payment_date,
                    'payment_ref', COALESCE(p.cheque_no, p.online_ref, p.payment_no),
                    'amount', SUM(p.amount) OVER (PARTITION BY p.invoice_id),
                    'payment_mode', p.payment_mode
                ) as status,
                SUM(p.amount) OVER (PARTITION BY p.invoice_id) as paid_sum
            FROM payments p
            WHERE p.invoice_id IS NOT NULL
              AND p.invoice_id IN (SELECT invoice_id FROM invoice_data)
            ORDER BY p.invoice_id, p.payment_date DESC, p.payment_no DESC
        ),
        invoices_full AS (
            SELECT
                id.invoice_id,
                id.invoice_number,
                id.inv_fin_year::text || '-' || (id.inv_fin_year + 1)::text as financial_year,
                id.inv_date as invoice_date,
                id.gr_id as grn_id,
                id.grn_ref,
                id.total,
                id.labour,
                id.discount,
                id.tax_amount,
                id.net_total,
                COALESCE(ii.item_count, 0) as item_count,
                COALESCE(ii.total_quantity, 0) as total_quantity,
                id.notes,
                jsonb_set(
                    COALESCE(ps.status, jsonb_build_object('status', 'pending', 'paid_date', null, 'payment_ref', null)),
                    '{status}',
                    CASE WHEN bal.balance <= 0.50 THEN to_jsonb('paid'::text) ELSE to_jsonb('pending'::text) END
                ) as payment_status,
                rcv.received as received_amount,
                bal.balance as balance_amount,
                COALESCE(ii.line_items, '[]'::jsonb) as line_items
            FROM invoice_data id
            LEFT JOIN invoice_items ii ON id.invoice_id = ii.invoice_id
            LEFT JOIN payment_status ps ON id.invoice_id = ps.invoice_id
            CROSS JOIN LATERAL (SELECT GREATEST(0, LEAST(COALESCE(ps.paid_sum, 0), COALESCE(id.total, 0))) AS received) rcv
            CROSS JOIN LATERAL (SELECT COALESCE(id.total, 0) - rcv.received AS balance) bal
        ),
        monthly_breakdown AS (
            SELECT
                TO_CHAR(warehouse_security.business_date(invoice_date), 'YYYY-MM') as month,
                COUNT(*) as invoice_count,
                SUM(total) as total_amount,
                SUM(received_amount) as paid_amount,
                SUM(balance_amount) as pending_amount
            FROM invoices_full
            GROUP BY TO_CHAR(warehouse_security.business_date(invoice_date), 'YYYY-MM')
            ORDER BY month DESC
        )
        SELECT
            jsonb_build_object(
                'total_invoices', (SELECT COUNT(*) FROM invoices_full),
                'total_amount', COALESCE((SELECT SUM(total) FROM invoices_full), 0),
                'total_labour', COALESCE((SELECT SUM(labour) FROM invoices_full), 0),
                'total_tax', COALESCE((SELECT SUM(tax_amount) FROM invoices_full), 0),
                'total_discount', COALESCE((SELECT SUM(discount) FROM invoices_full), 0),
                'net_amount', COALESCE((SELECT SUM(net_total) FROM invoices_full), 0),
                'paid_count', (SELECT COUNT(*) FROM invoices_full WHERE (payment_status->>'status') = 'paid'),
                'pending_count', (SELECT COUNT(*) FROM invoices_full WHERE (payment_status->>'status') = 'pending'),
                'paid_amount', COALESCE((SELECT SUM(received_amount) FROM invoices_full), 0),
                'pending_amount', COALESCE((SELECT SUM(balance_amount) FROM invoices_full), 0)
            ),
            COALESCE((
                SELECT jsonb_agg(
                    jsonb_build_object(
                        'invoice_id', invoice_id,
                        'invoice_number', invoice_number,
                        'invoice_date', invoice_date,
                        'financial_year', financial_year,
                        'grn_ref', grn_ref,
                        'grn_id', grn_id,
                        'total', total,
                        'labour', labour,
                        'discount', discount,
                        'tax_amount', tax_amount,
                        'net_total', net_total,
                        'item_count', item_count,
                        'total_quantity', total_quantity,
                        'notes', notes,
                        'payment_status', payment_status,
                        'paid_amount', received_amount,
                        'balance_amount', balance_amount,
                        'line_items', line_items
                    ) ORDER BY invoice_date DESC, invoice_number DESC
                )
                FROM invoices_full
            ), '[]'::jsonb),
            COALESCE((
                SELECT jsonb_agg(
                    jsonb_build_object(
                        'month', month,
                        'invoice_count', invoice_count,
                        'total_amount', total_amount,
                        'paid_amount', paid_amount,
                        'pending_amount', pending_amount
                    )
                )
                FROM monthly_breakdown
            ), '[]'::jsonb)
        INTO v_summary, v_invoices, v_by_month;

        v_result := jsonb_build_object(
            'success', true,
            'data', jsonb_build_object(
                'summary', v_summary,
                'invoices', v_invoices,
                'by_month', v_by_month
            ),
            'metadata', jsonb_build_object(
                'retrieved_at', NOW(),
                'customer_id', p_customer_uuid,
                'from_date', v_from_date,
                'to_date', v_to_date,
                'financial_year', p_financial_year
            )
        );

    -- All customers view (filtered by accessible customers for non-staff)
    ELSE
        WITH invoice_data AS (
            SELECT
                i.id as invoice_id,
                i.customer_id,
                c.name as customer_name,
                i.inv_date,
                i.total,
                i.labour,
                i.discount,
                i.tax_amount,
                COALESCE(i.total, 0) as net_total
            FROM invoice i
            JOIN customers c ON i.customer_id = c.id
            WHERE i.deleted_at IS NULL
                AND (p_financial_year IS NULL OR i.inv_fin_year = p_financial_year)
                AND i.inv_date >= warehouse_security.business_day_start(v_from_date) AND i.inv_date < warehouse_security.business_day_start(v_to_date + 1)
                AND (v_user_role IN ('admin', 'supervisor', 'staff') OR i.customer_id = ANY(v_user_customer_ids))
        ),
        customer_aggregates AS (
            SELECT
                customer_id,
                customer_name,
                COUNT(*) as invoice_count,
                SUM(total) as total_amount,
                SUM(net_total) as net_amount,
                MAX(inv_date) as latest_invoice_date
            FROM invoice_data
            GROUP BY customer_id, customer_name
        ),
        monthly_breakdown AS (
            SELECT
                TO_CHAR(warehouse_security.business_date(inv_date), 'YYYY-MM') as month,
                COUNT(*) as invoice_count,
                SUM(total) as total_amount
            FROM invoice_data
            GROUP BY TO_CHAR(warehouse_security.business_date(inv_date), 'YYYY-MM')
            ORDER BY month DESC
        )
        SELECT
            jsonb_build_object(
                'total_invoices', (SELECT COUNT(*) FROM invoice_data),
                'total_customers', (SELECT COUNT(DISTINCT customer_id) FROM invoice_data),
                'total_amount', COALESCE((SELECT SUM(total) FROM invoice_data), 0),
                'total_tax', COALESCE((SELECT SUM(tax_amount) FROM invoice_data), 0),
                'net_amount', COALESCE((SELECT SUM(net_total) FROM invoice_data), 0)
            ),
            COALESCE((
                SELECT jsonb_agg(
                    jsonb_build_object(
                        'customer_id', customer_id,
                        'customer_name', customer_name,
                        'invoice_count', invoice_count,
                        'total_amount', total_amount,
                        'net_amount', net_amount,
                        'latest_invoice_date', latest_invoice_date
                    ) ORDER BY total_amount DESC
                )
                FROM customer_aggregates
            ), '[]'::jsonb),
            COALESCE((
                SELECT jsonb_agg(
                    jsonb_build_object(
                        'month', month,
                        'invoice_count', invoice_count,
                        'total_amount', total_amount
                    )
                )
                FROM monthly_breakdown
            ), '[]'::jsonb)
        INTO v_summary, v_by_customer, v_by_month;

        v_result := jsonb_build_object(
            'success', true,
            'data', jsonb_build_object(
                'summary', v_summary,
                'by_customer', v_by_customer,
                'by_month', v_by_month
            ),
            'metadata', jsonb_build_object(
                'retrieved_at', NOW(),
                'from_date', v_from_date,
                'to_date', v_to_date,
                'financial_year', p_financial_year
            )
        );
    END IF;

    RETURN v_result;

EXCEPTION
    WHEN OTHERS THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'Failed to retrieve invoice summary: ' || SQLERRM,
            'error_code', SQLSTATE
        );
END;
$$;
