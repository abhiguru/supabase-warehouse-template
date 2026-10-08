-- Customer-facing history lists use dedicated contracts whose authorization is
-- anchored to the requested customer. This keeps staff list RPCs staff-only.
CREATE OR REPLACE FUNCTION public.get_customer_grn_items(
  p_customer_id uuid,
  p_date_from timestamp with time zone DEFAULT NULL,
  p_date_to timestamp with time zone DEFAULT NULL,
  p_filters jsonb DEFAULT '{}'::jsonb,
  p_sort_by text DEFAULT 'date',
  p_sort_order text DEFAULT 'desc',
  p_limit integer DEFAULT 20,
  p_offset integer DEFAULT 0
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, extensions, warehouse_security, pg_temp
AS $$
DECLARE
  v_filters jsonb := COALESCE(p_filters, '{}'::jsonb);
  v_total_count integer;
  v_total_qty bigint;
  v_total_stock bigint;
  v_items jsonb;
BEGIN
  IF p_customer_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'message', 'Customer ID is required', 'data', NULL);
  END IF;

  IF p_limit < 1 OR p_limit > 100 OR p_offset < 0
     OR p_sort_by NOT IN ('date', 'gr_no', 'customer_name', 'item_name', 'qty', 'stock')
     OR p_sort_order NOT IN ('asc', 'desc') THEN
    RETURN jsonb_build_object('success', false, 'message', 'Invalid list parameters', 'data', NULL);
  END IF;

  PERFORM warehouse_security.authorize_rpc(
    'get_customer_grn_items',
    jsonb_build_object('p_customer_id', p_customer_id)
  );

  WITH filtered AS (
    SELECT
      grt.id,
      grt.gr_id,
      grt.item_id,
      grt.item_name,
      grt.qty,
      grt.stock,
      grt.weight,
      grt.rack,
      grt.package_mark,
      grt.packaging,
      gr.gr_no,
      gr.date,
      gr.customer_name,
      gr.customer_id,
      gr.registration,
      gr.supervisor_name,
      gr.sender_name,
      gr.invoiced,
      gr.leon,
      gr.out_of_stock,
      gr.note,
      gr.gr_image_url
    FROM public.goodsreceived_trl grt
    JOIN public.goodsreceived gr ON gr.id = grt.gr_id
    WHERE gr.customer_id = p_customer_id
      AND gr.deleted_at IS NULL
      AND (p_date_from IS NULL OR gr.date >= p_date_from)
      AND (p_date_to IS NULL OR gr.date <= p_date_to)
      AND (NOT (v_filters ? 'item_name') OR v_filters->>'item_name' = '' OR grt.item_name ILIKE '%' || (v_filters->>'item_name') || '%')
      AND (NOT (v_filters ? 'customer_name') OR v_filters->>'customer_name' = '' OR gr.customer_name ILIKE '%' || (v_filters->>'customer_name') || '%')
      AND (NOT (v_filters ? 'gr_no') OR v_filters->>'gr_no' = '' OR gr.gr_no ILIKE '%' || (v_filters->>'gr_no') || '%')
      AND (NOT (v_filters ? 'package_mark') OR v_filters->>'package_mark' = '' OR grt.package_mark ILIKE '%' || (v_filters->>'package_mark') || '%')
      AND (NOT (v_filters ? 'rack') OR v_filters->>'rack' = '' OR grt.rack ILIKE '%' || (v_filters->>'rack') || '%')
      AND (NOT (v_filters ? 'gr_no_from') OR v_filters->>'gr_no_from' = '' OR gr.gr_no >= v_filters->>'gr_no_from')
      AND (NOT (v_filters ? 'gr_no_to') OR v_filters->>'gr_no_to' = '' OR gr.gr_no <= v_filters->>'gr_no_to')
      AND (
        jsonb_typeof(v_filters->'item_ids') IS DISTINCT FROM 'array'
        OR jsonb_array_length(v_filters->'item_ids') = 0
        OR grt.item_id::text IN (SELECT jsonb_array_elements_text(v_filters->'item_ids'))
      )
      AND (
        jsonb_typeof(v_filters->'grn_ids') IS DISTINCT FROM 'array'
        OR jsonb_array_length(v_filters->'grn_ids') = 0
        OR gr.id::text IN (SELECT jsonb_array_elements_text(v_filters->'grn_ids'))
      )
      AND (
        NOT (v_filters ? 'stock_status')
        OR v_filters->>'stock_status' = 'all'
        OR (v_filters->>'stock_status' = 'in_stock' AND grt.stock > 0)
        OR (v_filters->>'stock_status' = 'out_of_stock' AND grt.stock = 0)
      )
      AND (
        NOT (v_filters ? 'weight_min')
        OR (jsonb_typeof(v_filters->'weight_min') = 'number' AND grt.weight >= (v_filters->>'weight_min')::numeric)
      )
      AND (
        NOT (v_filters ? 'weight_max')
        OR (jsonb_typeof(v_filters->'weight_max') = 'number' AND grt.weight <= (v_filters->>'weight_max')::numeric)
      )
  ), ordered AS (
    SELECT filtered.*,
      row_number() OVER (ORDER BY
        CASE WHEN p_sort_by = 'date' AND p_sort_order = 'desc' THEN date END DESC NULLS LAST,
        CASE WHEN p_sort_by = 'date' AND p_sort_order = 'asc' THEN date END ASC NULLS LAST,
        CASE WHEN p_sort_by = 'gr_no' AND p_sort_order = 'desc' THEN gr_no END DESC,
        CASE WHEN p_sort_by = 'gr_no' AND p_sort_order = 'asc' THEN gr_no END ASC,
        CASE WHEN p_sort_by = 'customer_name' AND p_sort_order = 'desc' THEN customer_name END DESC,
        CASE WHEN p_sort_by = 'customer_name' AND p_sort_order = 'asc' THEN customer_name END ASC,
        CASE WHEN p_sort_by = 'item_name' AND p_sort_order = 'desc' THEN item_name END DESC,
        CASE WHEN p_sort_by = 'item_name' AND p_sort_order = 'asc' THEN item_name END ASC,
        CASE WHEN p_sort_by = 'qty' AND p_sort_order = 'desc' THEN qty END DESC,
        CASE WHEN p_sort_by = 'qty' AND p_sort_order = 'asc' THEN qty END ASC,
        CASE WHEN p_sort_by = 'stock' AND p_sort_order = 'desc' THEN stock END DESC,
        CASE WHEN p_sort_by = 'stock' AND p_sort_order = 'asc' THEN stock END ASC,
        id
      ) AS row_num
    FROM filtered
  ), stats AS (
    SELECT count(*)::integer AS total_count,
      COALESCE(sum(qty), 0)::bigint AS total_qty,
      COALESCE(sum(stock), 0)::bigint AS total_stock
    FROM filtered
  ), page AS (
    SELECT * FROM ordered
    WHERE row_num > p_offset AND row_num <= p_offset + p_limit
  )
  SELECT
    stats.total_count,
    stats.total_qty,
    stats.total_stock,
    COALESCE(
      jsonb_agg(
        jsonb_build_object(
          'id', page.id,
          'grn_item_id', page.id,
          'grn_id', page.gr_id,
          'gr_no', page.gr_no,
          'item_id', page.item_id,
          'item_name', page.item_name,
          'qty', page.qty,
          'stock', page.stock,
          'weight', page.weight,
          'rack', page.rack,
          'package_mark', page.package_mark,
          'packaging', page.packaging,
          'date', page.date,
          'grns_id', page.gr_id,
          'grns_gr_no', page.gr_no,
          'grns_date', page.date,
          'customer_name', page.customer_name,
          'customer_id', page.customer_id,
          'registration', page.registration,
          'supervisor_name', page.supervisor_name,
          'sender_name', page.sender_name,
          'invoiced', page.invoiced,
          'leon', page.leon,
          'out_of_stock', page.out_of_stock,
          'note', page.note,
          'image_url', page.gr_image_url
        ) ORDER BY page.row_num
      ) FILTER (WHERE page.id IS NOT NULL),
      '[]'::jsonb
    )
  INTO v_total_count, v_total_qty, v_total_stock, v_items
  FROM stats
  LEFT JOIN page ON true
  GROUP BY stats.total_count, stats.total_qty, stats.total_stock;

  RETURN jsonb_build_object(
    'success', true,
    'message', 'Customer GRN items retrieved successfully',
    'data', jsonb_build_object(
      'items', v_items,
      'pagination', jsonb_build_object(
        'total', v_total_count,
        'total_count', v_total_count,
        'limit', p_limit,
        'offset', p_offset,
        'has_more', (p_offset + p_limit) < v_total_count
      ),
      'aggregations', jsonb_build_object(
        'total_qty', v_total_qty,
        'total_stock', v_total_stock,
        'total_count', v_total_count
      )
    )
  );
END;
$$;

REVOKE ALL ON FUNCTION public.get_customer_grn_items(uuid, timestamptz, timestamptz, jsonb, text, text, integer, integer)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_customer_grn_items(uuid, timestamptz, timestamptz, jsonb, text, text, integer, integer)
  TO authenticated, service_role;

CREATE FUNCTION public.get_customer_dispatch_list(
  p_customer_id uuid,
  p_limit integer DEFAULT 10,
  p_offset integer DEFAULT 0,
  p_include_items boolean DEFAULT true
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, extensions, warehouse_security, pg_temp
AS $$
DECLARE
  v_total_count integer;
  v_dispatches jsonb;
BEGIN
  IF p_customer_id IS NULL THEN
    RETURN jsonb_build_object(
      'success', false,
      'message', 'Customer ID is required',
      'data', NULL
    );
  END IF;

  IF p_limit < 1 OR p_limit > 100 OR p_offset < 0 THEN
    RETURN jsonb_build_object(
      'success', false,
      'message', 'Invalid pagination',
      'data', NULL
    );
  END IF;

  PERFORM warehouse_security.authorize_rpc(
    'get_customer_dispatch_list',
    jsonb_build_object('p_customer_id', p_customer_id)
  );

  SELECT count(*)
  INTO v_total_count
  FROM public.dispatch d
  WHERE d.customer_id = p_customer_id
    AND d.deleted_at IS NULL;

  WITH paged_dispatches AS (
    SELECT d.*
    FROM public.dispatch d
    WHERE d.customer_id = p_customer_id
      AND d.deleted_at IS NULL
    ORDER BY d.disp_date DESC NULLS LAST, d.created_at DESC, d.id DESC
    LIMIT p_limit OFFSET p_offset
  )
  SELECT COALESCE(
    jsonb_agg(
      jsonb_build_object(
        'id', d.id,
        'disp_no', d.disp_no,
        'disp_date', d.disp_date,
        'customer_id', d.customer_id,
        'customer_name', d.customer_name,
        'supervisor_id', d.supervisor_id,
        'supervisor_name', d.supervisor_name,
        'registration', d.registration,
        'note', d.note,
        'total_items', COALESCE(lines.total_items, 0),
        'total_qty', COALESCE(lines.total_qty, 0),
        'total_weight', COALESCE(lines.total_weight, 0),
        'items', CASE WHEN p_include_items THEN COALESCE(lines.items, '[]'::jsonb) ELSE NULL END,
        'created_at', d.created_at,
        'updated_at', d.updated_at
      )
      ORDER BY d.disp_date DESC NULLS LAST, d.created_at DESC, d.id DESC
    ),
    '[]'::jsonb
  )
  INTO v_dispatches
  FROM paged_dispatches d
  LEFT JOIN LATERAL (
    SELECT
      count(*)::integer AS total_items,
      COALESCE(sum(dt.disp_qty), 0)::bigint AS total_qty,
      COALESCE(sum(dt.disp_qty * COALESCE(grt.weight, 0)), 0)::bigint AS total_weight,
      jsonb_agg(
        jsonb_build_object(
          'item_id', grt.item_id,
          'item_name', grt.item_name,
          'disp_qty', dt.disp_qty,
          'weight', grt.weight,
          'gr_no', gr.gr_no,
          'grn_qty', grt.qty,
          'grn_item_id', grt.id,
          'package_mark', grt.package_mark,
          'rack', grt.rack
        )
        ORDER BY grt.item_name, grt.id
      ) AS items
    FROM public.dispatch_trl dt
    JOIN public.goodsreceived_trl grt ON grt.id = dt.gr_trl_id
    JOIN public.goodsreceived gr ON gr.id = grt.gr_id
    WHERE dt.disp_id = d.id
  ) lines ON true;

  RETURN jsonb_build_object(
    'success', true,
    'message', 'Customer dispatches retrieved successfully',
    'data', jsonb_build_object(
      'dispatches', v_dispatches,
      'pagination', jsonb_build_object(
        'total_count', v_total_count,
        'limit', p_limit,
        'offset', p_offset,
        'has_more', (p_offset + p_limit) < v_total_count
      )
    )
  );
END;
$$;

REVOKE ALL ON FUNCTION public.get_customer_dispatch_list(uuid, integer, integer, boolean)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_customer_dispatch_list(uuid, integer, integer, boolean)
  TO authenticated, service_role;
