-- Return per-item dispatch history through the current assignment model.
--
-- The imported implementation still queried the removed `user_customers`
-- table for customer accounts. The starter authorization guard already proves
-- ownership using `users_customers_new`; keep that single authorization source
-- and build the response only after it succeeds.
CREATE OR REPLACE FUNCTION public.get_grn_item_dispatches(p_grn_item_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public, extensions, utils, pg_temp
AS $$
DECLARE
  v_dispatches jsonb;
  v_summary jsonb;
BEGIN
  IF p_grn_item_id IS NULL THEN
    RETURN jsonb_build_object(
      'success', false,
      'error', 'GRN item ID is required',
      'code', 'INVALID_PARAMETERS'
    );
  END IF;

  PERFORM warehouse_security.authorize_rpc(
    'get_grn_item_dispatches',
    jsonb_build_object('p_grn_item_id', p_grn_item_id)
  );

  IF NOT EXISTS (
    SELECT 1 FROM public.goodsreceived_trl WHERE id = p_grn_item_id
  ) THEN
    RETURN jsonb_build_object(
      'success', false,
      'error', 'GRN item not found or access denied',
      'code', 'ACCESS_DENIED'
    );
  END IF;

  SELECT jsonb_agg(
    jsonb_build_object(
      'id', dt.id,
      'dispatch_id', dt.disp_id,
      'disp_no', d.disp_no,
      'disp_quantity', dt.disp_qty,
      'disp_date', d.disp_date,
      'customer_name', d.customer_name,
      'registration', d.registration,
      'supervisor_name', d.supervisor_name,
      'note', d.note
    ) ORDER BY d.disp_date DESC, d.disp_no DESC, dt.id DESC
  )
  INTO v_dispatches
  FROM public.dispatch_trl dt
  JOIN public.dispatch d ON d.id = dt.disp_id
  WHERE dt.gr_trl_id = p_grn_item_id;

  SELECT jsonb_build_object(
    'total_dispatches', COUNT(dt.id),
    'total_dispatched_qty', COALESCE(SUM(dt.disp_qty), 0),
    'remaining_stock', item.stock
  )
  INTO v_summary
  FROM public.goodsreceived_trl item
  LEFT JOIN public.dispatch_trl dt ON dt.gr_trl_id = item.id
  WHERE item.id = p_grn_item_id
  GROUP BY item.stock;

  RETURN jsonb_build_object(
    'success', true,
    'data', jsonb_build_object(
      'dispatches', COALESCE(v_dispatches, '[]'::jsonb),
      'summary', v_summary
    ),
    'message', 'GRN item dispatches retrieved successfully'
  );
END;
$$;

REVOKE EXECUTE ON FUNCTION public.get_grn_item_dispatches(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_grn_item_dispatches(uuid) TO authenticated, service_role;
