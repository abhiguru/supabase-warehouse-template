-- Migration 143 (WH-13): a cancelled invoice keeps its line details on the line itself.
--
-- An invoice line stores only its amounts; the item, quantity, weight and numbers were read through disp_trl_id. Deleting a dispatch (or
-- one of its lines) after a cancel is allowed (migration 134) and empties disp_trl_id (migration 120), so the cancelled invoice, a GST
-- record, lost its details. Now:
--  1. invoice_trl gets ten kept_* columns (item name, packaging, weight, rack, package mark, dispatched quantity, dispatch number and date,
--     GRN number and date) and details_kept_at, set together.
--  2. cancel_invoice copies them for every line in its own transaction, right after the invoice row is marked cancelled. A refusal
--     (INVOICE_CANCELLED, STALE_RECORD, INVOICE_HAS_PAYMENTS, ...) returns before that point and writes nothing.
--  3. Every already-cancelled invoice (cancelled_at set) gets the copy for each line whose dispatch line still exists. A line already
--     emptied has nothing to copy and stays with details_kept_at empty. Invoices with "[CANCELLED:" notes and no cancelled_at are not touched.
--  4. get_invoice_detail and get_invoice_data (definition files) read the copy for a cancelled invoice and answer details_available;
--     get_invoice_detail no longer drops a line whose disp_trl_id is empty. Live invoices read as before.
-- The kept_* columns hold what the line's screens already show a customer; a customer's table read of invoice_trl is limited by the row
-- policy to the customer's own invoices (migration 137). Amounts, totals and cancelled_by are not touched.
--
-- Run twice, the column step fails on the existing columns and the patch fails on its count check.

ALTER TABLE public.invoice_trl
  ADD COLUMN kept_item_name character varying(80),
  ADD COLUMN kept_packaging character varying(40),
  ADD COLUMN kept_weight integer,
  ADD COLUMN kept_rack character varying(30),
  ADD COLUMN kept_package_mark character varying(60),
  ADD COLUMN kept_disp_qty integer,
  ADD COLUMN kept_disp_no character varying(8),
  ADD COLUMN kept_disp_date timestamp with time zone,
  ADD COLUMN kept_grn_no character varying(8),
  ADD COLUMN kept_grn_date timestamp with time zone,
  ADD COLUMN details_kept_at timestamp with time zone;
COMMENT ON COLUMN public.invoice_trl.details_kept_at IS 'Migration 143: set when cancel_invoice (or this migration, for an invoice cancelled earlier) copied the line details into the kept_* columns. A cancelled invoice reads them instead of the dispatch line, GRN and item.';

-- Backfill: every line of an already-cancelled invoice whose dispatch line still exists.
UPDATE public.invoice_trl it
SET kept_item_name = gt.item_name, kept_packaging = gt.packaging, kept_weight = gt.weight, kept_rack = gt.rack,
    kept_package_mark = gt.package_mark, kept_disp_qty = dt.disp_qty, kept_disp_no = d.disp_no, kept_disp_date = d.disp_date,
    kept_grn_no = gr.gr_no, kept_grn_date = gr.date, details_kept_at = now()
FROM public.invoice i, public.dispatch_trl dt, public.dispatch d, public.goodsreceived_trl gt, public.goodsreceived gr
WHERE i.id = it.invoice_id AND i.cancelled_at IS NOT NULL
  AND dt.id = it.disp_trl_id AND d.id = dt.disp_id AND gt.id = dt.gr_trl_id AND gr.id = gt.gr_id;

-- cancel_invoice: the copy, in the same transaction, after the invoice is marked cancelled and before anything is answered.
CREATE FUNCTION pg_temp.patch_function(p_function regprocedure, p_old text[], p_new text[]) RETURNS void
    LANGUAGE plpgsql AS $$
DECLARE
  v_def text := pg_get_functiondef(p_function);
  v_count integer;
  i integer;
BEGIN
  IF array_length(p_old, 1) IS DISTINCT FROM array_length(p_new, 1) THEN
    RAISE EXCEPTION '%: the marker list and the replacement list differ in length', p_function;
  END IF;
  FOR i IN 1 .. array_length(p_old, 1) LOOP
    IF position(p_old[i] IN p_new[i]) > 0 THEN
      RAISE EXCEPTION '%: the replacement of marker % contains the marker', p_function, i;
    END IF;
    v_count := (length(v_def) - length(replace(v_def, p_old[i], ''))) / length(p_old[i]);
    IF v_count <> 1 THEN
      RAISE EXCEPTION '%: expected marker % once, found % times', p_function, i, v_count;
    END IF;
    v_def := replace(v_def, p_old[i], p_new[i]);
  END LOOP;
  EXECUTE v_def;
END $$;

SELECT pg_temp.patch_function('public.cancel_invoice(uuid, text, timestamptz)'::regprocedure, ARRAY[
$m$  RETURNING cancelled_at, updated_at INTO v_cancelled_at, v_new_updated_at;$m$
], ARRAY[
$m$  RETURNING cancelled_at, updated_at
  INTO v_cancelled_at, v_new_updated_at;

  -- Migration 143: each line keeps its own copy of the details it shows, so a later dispatch delete or edit cannot change this invoice.
  UPDATE invoice_trl it
  SET kept_item_name = gt.item_name, kept_packaging = gt.packaging, kept_weight = gt.weight, kept_rack = gt.rack,
      kept_package_mark = gt.package_mark, kept_disp_qty = dt.disp_qty, kept_disp_no = d.disp_no, kept_disp_date = d.disp_date,
      kept_grn_no = gr.gr_no, kept_grn_date = gr.date, details_kept_at = v_cancelled_at
  FROM dispatch_trl dt, dispatch d, goodsreceived_trl gt, goodsreceived gr
  WHERE it.invoice_id = p_invoice_id
    AND dt.id = it.disp_trl_id AND d.id = dt.disp_id AND gt.id = dt.gr_trl_id AND gr.id = gt.gr_id;$m$
]);

-- WH-39: get_invoice_items_detailed (the text of migration 119 with these changes) lists every line of a cancelled invoice, reads the copy, and
-- answers details_available. Live invoices, keys and amounts read as before.
CREATE OR REPLACE FUNCTION public.get_invoice_items_detailed(p_invoice_id uuid) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'extensions', 'utils', 'pg_temp'
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
        'details_available', line.details_available,
        'dispatch', jsonb_build_object(
          'id', line.dispatch_item_id,
          'disp_id', line.dispatch_id,
          'dispatch_no', line.dispatch_no,
          'dispatch_date', line.dispatch_date,
          'quantity', line.dispatch_qty
        )
      )
      ORDER BY line.dispatch_no, uuid_extract_timestamp(line.id), line.id
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
      CASE WHEN avail.ok THEN COALESCE(avail.qty, 0)::numeric END AS dispatch_qty,
      ROUND(amount.base * COALESCE(it.tax, 0)::numeric / 100, 2) AS tax_amount,
      amount.base + ROUND(amount.base * COALESCE(it.tax, 0)::numeric / 100, 2) AS total_amount,
      avail.ok AS details_available,
      dt.id AS dispatch_item_id,
      d.id AS dispatch_id,
      CASE WHEN it.details_kept_at IS NOT NULL THEN it.kept_disp_no ELSE d.disp_no END AS dispatch_no,
      CASE WHEN it.details_kept_at IS NOT NULL THEN it.kept_disp_date ELSE d.disp_date END AS dispatch_date,
      gr.id AS grn_id,
      CASE WHEN it.details_kept_at IS NOT NULL THEN it.kept_grn_no ELSE gr.gr_no END AS gr_no,
      grt.id AS grn_item_id,
      grt.item_id AS catalog_item_id,
      CASE WHEN it.details_kept_at IS NOT NULL THEN it.kept_item_name ELSE grt.item_name END AS item_name,
      grt.qty AS grn_quantity,
      CASE WHEN it.details_kept_at IS NOT NULL THEN it.kept_package_mark ELSE grt.package_mark END AS package_mark,
      CASE WHEN it.details_kept_at IS NOT NULL THEN it.kept_rack ELSE grt.rack END AS rack,
      CASE WHEN it.details_kept_at IS NOT NULL THEN it.kept_weight ELSE grt.weight END AS weight,
      CASE WHEN it.details_kept_at IS NOT NULL THEN it.kept_packaging ELSE grt.packaging END AS grn_packaging,
      CASE WHEN it.details_kept_at IS NOT NULL THEN it.kept_item_name ELSE catalog.name END AS catalog_name,
      CASE WHEN it.details_kept_at IS NOT NULL THEN it.kept_packaging ELSE catalog.packaging END AS catalog_packaging
    FROM public.invoice_trl it
    JOIN public.invoice inv ON inv.id = it.invoice_id
    LEFT JOIN public.dispatch_trl dt ON dt.id = it.disp_trl_id
    LEFT JOIN public.dispatch d ON d.id = dt.disp_id
    LEFT JOIN public.goodsreceived gr ON gr.id = dt.gr_id
    LEFT JOIN public.goodsreceived_trl grt ON grt.id = dt.gr_trl_id
    LEFT JOIN public.items catalog ON catalog.id = grt.item_id
    LEFT JOIN public.goodsreceived igr ON igr.id = inv.gr_id
    -- Migration 143: a cancelled invoice's line that kept its details reads the copy (quantity from the copy, pricing mode of the invoice's GRN);
    -- a line emptied before the copy existed has no quantity, so it has no server amount and the app falls back to the line's own rates.
    CROSS JOIN LATERAL (
      SELECT (it.details_kept_at IS NOT NULL OR dt.id IS NOT NULL) AS ok,
             CASE WHEN it.details_kept_at IS NOT NULL THEN it.kept_disp_qty ELSE dt.disp_qty END AS qty,
             CASE WHEN it.details_kept_at IS NOT NULL THEN igr.pricing_mode ELSE gr.pricing_mode END AS mode
    ) AS avail
    CROSS JOIN LATERAL (
      SELECT CASE WHEN NOT avail.ok THEN NULL
        WHEN avail.mode = 'ONE_TIME'
        THEN ROUND(COALESCE(it.charge, 0)::numeric * COALESCE(avail.qty, 0)::numeric, 2)
        ELSE ROUND(COALESCE(it.charge, 0)::numeric * COALESCE(avail.qty, 0)::numeric * COALESCE(it.duration, 1)::numeric, 2)
             + ROUND(COALESCE(it.labour_rate, 0)::numeric * COALESCE(avail.qty, 0)::numeric, 2)
        END AS base
    ) AS amount
    WHERE it.invoice_id = p_invoice_id
      -- A live invoice lists a line only when every join matches, as the inner joins did.
      AND (inv.cancelled_at IS NOT NULL
           OR (dt.id IS NOT NULL AND d.id IS NOT NULL AND gr.id IS NOT NULL AND grt.id IS NOT NULL AND catalog.id IS NOT NULL))
  ) AS line;

  RETURN utils.success_response(
    jsonb_build_object('items', v_items, 'summary', v_summary),
    'Invoice items retrieved successfully'
  );
END;
$$;
