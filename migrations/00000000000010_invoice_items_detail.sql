-- Repair the protected detailed-invoice endpoint imported in migration 00000.
-- The original body references columns that do not exist in invoice_trl and
-- returns a shape the mobile client cannot consume.
CREATE OR REPLACE FUNCTION public.get_invoice_items_detailed(p_invoice_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, extensions, utils, pg_temp
AS $$
DECLARE
  v_items jsonb;
  v_summary jsonb;
BEGIN
  PERFORM warehouse_security.authorize_rpc(
    'get_invoice_items_detailed',
    jsonb_build_object('p_invoice_id', p_invoice_id)
  );

  IF NOT EXISTS (
    SELECT 1
    FROM public.invoice i
    WHERE i.id = p_invoice_id
      AND i.deleted_at IS NULL
  ) THEN
    RETURN utils.not_found_response('Invoice', p_invoice_id::text);
  END IF;

  SELECT COALESCE(
    jsonb_agg(
      jsonb_build_object(
        'id', line.id,
        'item_id', line.catalog_item_id,
        'duration', line.duration,
        'no_of_days', line.no_of_days,
        'charge', line.charge_rate,
        'labour_rate', line.labour_rate,
        'tax', line.tax_rate,
        'tax_amount', line.tax_amount,
        'total_amount', line.total_amount,
        'dispatch_qty', line.dispatch_qty,
        'grn_quantity', line.grn_quantity,
        'item_name', line.item_name,
        'gr_no', line.gr_no,
        'dispatch_id', line.dispatch_id,
        'dispatch_no', line.dispatch_no,
        'dispatch_date', line.dispatch_date,
        'package_mark', line.package_mark,
        'rack', line.rack,
        'weight', line.weight,
        'packaging', line.catalog_packaging,
        'catalog', jsonb_build_object(
          'id', line.catalog_item_id,
          'name', line.catalog_name,
          'packaging', line.catalog_packaging
        ),
        'grn_item', jsonb_build_object(
          'id', line.grn_item_id,
          'name', line.item_name,
          'original_quantity', line.grn_quantity,
          'package_mark', line.package_mark,
          'rack', line.rack,
          'weight', line.weight,
          'packaging', line.grn_packaging
        ),
        'dispatch', jsonb_build_object(
          'id', line.dispatch_item_id,
          'disp_id', line.dispatch_id,
          'dispatch_no', line.dispatch_no,
          'dispatch_date', line.dispatch_date,
          'quantity', line.dispatch_qty
        )
      )
      ORDER BY line.dispatch_no, line.id
    ),
    '[]'::jsonb
  ),
  jsonb_build_object(
    'total_items', COUNT(*),
    'total_quantity', COALESCE(SUM(line.dispatch_qty), 0),
    'total_amount', COALESCE(ROUND(SUM(line.total_amount), 2), 0)
  )
  INTO v_items, v_summary
  FROM (
    SELECT
      it.id,
      it.duration,
      it.no_of_days,
      COALESCE(it.charge, 0)::numeric AS charge_rate,
      COALESCE(it.labour_rate, 0)::numeric AS labour_rate,
      COALESCE(it.tax, 0)::numeric AS tax_rate,
      COALESCE(dt.disp_qty, 0)::numeric AS dispatch_qty,
      ROUND(
        COALESCE(dt.disp_qty, 0)::numeric
        * (
          COALESCE(it.charge, 0)::numeric * COALESCE(it.duration, 1)::numeric
          + COALESCE(it.labour_rate, 0)::numeric
        )
        * COALESCE(it.tax, 0)::numeric / 100,
        2
      ) AS tax_amount,
      ROUND(
        COALESCE(dt.disp_qty, 0)::numeric
        * (
          COALESCE(it.charge, 0)::numeric * COALESCE(it.duration, 1)::numeric
          + COALESCE(it.labour_rate, 0)::numeric
        )
        * (1 + COALESCE(it.tax, 0)::numeric / 100),
        2
      ) AS total_amount,
      dt.id AS dispatch_item_id,
      d.id AS dispatch_id,
      d.disp_no AS dispatch_no,
      d.disp_date AS dispatch_date,
      gr.id AS grn_id,
      gr.gr_no,
      grt.id AS grn_item_id,
      grt.item_id AS catalog_item_id,
      grt.item_name,
      grt.qty AS grn_quantity,
      grt.package_mark,
      grt.rack,
      grt.weight,
      grt.packaging AS grn_packaging,
      catalog.name AS catalog_name,
      catalog.packaging AS catalog_packaging
    FROM public.invoice_trl it
    JOIN public.dispatch_trl dt ON dt.id = it.disp_trl_id
    JOIN public.dispatch d ON d.id = dt.disp_id
    JOIN public.goodsreceived gr ON gr.id = dt.gr_id
    JOIN public.goodsreceived_trl grt ON grt.id = dt.gr_trl_id
    JOIN public.items catalog ON catalog.id = grt.item_id
    WHERE it.invoice_id = p_invoice_id
  ) AS line;

  RETURN utils.success_response(
    jsonb_build_object('items', v_items, 'summary', v_summary),
    'Invoice items retrieved successfully'
  );
END;
$$;

ALTER FUNCTION public.get_invoice_items_detailed(uuid) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION public.get_invoice_items_detailed(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_invoice_items_detailed(uuid) TO authenticated, service_role;
