-- Migration 100: the invoice form's GRN answer carries each line once, with only the keys the app reads.
--
-- Invoice -> new invoice, step 2 (Items) loads the whole GRN through generate_invoice_data_for_grn_with_pricing
-- (a thin wrapper over generate_invoice_data_for_grn). The answer carried every line four times (top-level
-- 'rows' and 'items', and the same two again under 'data'), and every line carried 70 keys, 36 of which no
-- reader uses (most of them a second name for the same value). A GRN of 3,055 lines came to 27 MB, downloaded
-- twice per save (the second time to re-check that the GRN is still invoiceable).
--
-- 1. generate_invoice_data_for_grn: the successful answer now has the lines once, under top-level 'items',
--    and each line has the 36 unread keys removed with jsonb - text[]. 'rows' and the whole 'data' object are
--    no longer built. 'success', 'header', 'totals' and 'message' stay as they are, the error answers stay as
--    they are, and the line order (the order of build_invoice_recalculation_rows) and every remaining value
--    stay as they are. build_invoice_recalculation_rows is not touched: recalculate_invoice_items still needs
--    its full lines. The wrapper generate_invoice_data_for_grn_with_pricing needs no change (signature,
--    SECURITY DEFINER, search_path, the authorize_rpc call and the grants stay). The edit is made in the inner
--    function, where the answer is built, so that the duplicate copies are never made; get_invoice_form_data
--    (no caller in the repository) calls the same function and gets the same lean answer.
--    The keys that stay are every key the app reads, fallbacks included:
--    grn_items_id, grn_item_id, grn_items_item_id, item_id, grn_items_item_name, items_catalog_name, item_name,
--    dispatches_items_disp_qty, qty, grn_items_original_qty, grn_original_qty, grn_items_package_mark,
--    package_mark, grn_items_rack, rack, grn_items_weight, weight, dispatches_id, dispatch_id, dispatches_no,
--    dispatch_no, dispatches_date, dispatch_date, grn_id, grn_no, grn_date, duration, no_of_days, billable_days,
--    unit_price, charge, labour_rate, tax_percent, tax, grn_items_pricing_mode, grnItems_pricing_mode,
--    pricing_mode, dispatches_items_id, disp_trl_id (those the function does not emit today are not added).
--    A key removed here is removed from the lines of the answer only; the figures of a line (rent, labour, tax)
--    are still computed by build_invoice_recalculation_rows and the totals still come from it.
--    create_dispatch_with_stock_check_internal passes this answer on as 'invoice_data' for customers with
--    automatic invoices; that answer gets the same shape.
--
-- 2. get_invoice_detail: the 'invoice' object also returns 'grn_pricing_mode', the same value get_invoice_data
--    returns as header.grn.pricing_mode (goodsreceived.pricing_mode of the invoice's GRN), so that the edit
--    path no longer needs get_invoice_data (a second, much larger answer) only to read it.
--
-- Only the listed expressions of the current definitions are replaced, and each marker must occur exactly once.

CREATE FUNCTION pg_temp.patch_rpc(fn regprocedure, marker text, replacement text, expected integer DEFAULT 1) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE definition text := pg_get_functiondef(fn); occurrences integer;
BEGIN
  occurrences := (length(definition)-length(replace(definition,marker,'')))/length(marker);
  IF occurrences <> expected THEN
    RAISE EXCEPTION 'Expected % occurrence(s) of the marker in %, found %: %', expected, fn, occurrences, left(marker,80);
  END IF;
  EXECUTE replace(definition,marker,replacement);
END $$;

DO $patch$
BEGIN
  -- The lines once, under 'items', without the unread keys; no 'rows', no 'data'.
  PERFORM pg_temp.patch_rpc('public.generate_invoice_data_for_grn(uuid,text)',
  $m$        'rows', v_recalculation->'rows',
        'items', v_recalculation->'items',
        'totals', v_recalculation->'totals',
        'data', jsonb_build_object(
            'header', v_header_data,
            'rows', v_recalculation->'rows',
            'items', v_recalculation->'items',
            'total_rows', COALESCE((v_recalculation->'totals'->>'total_rows')::integer, 0),
            'totals', v_recalculation->'totals'
        ),
        'message', 'Invoice data generated successfully'$m$,
  $r$        'items', COALESCE((
            SELECT jsonb_agg(l.line - ARRAY[
                'amount','base_amount','calculated_days','calculated_duration','catalog_name','catalog_packaging',
                'current_stock','dispatch_customer_name','dispatches_customer_name','dispatches_vehicle',
                'dispatch_item_id','dispatch_qty','dispatch_vehicle','duration_calculation_note','duration_mode',
                'grn_items_current_stock','grn_items_packaging','grn_items_total_dispatched','id','invoice_item_id',
                'item_amount','item_description','item_packaging','items_description','items_packaging','item_tax',
                'item_total','labour_amount','missing_price','original_qty','row_number','rowNumber',
                'storage_amount','tax_amount','total_amount','total_dispatched'
              ] ORDER BY l.ord)
            FROM jsonb_array_elements(v_recalculation->'items') WITH ORDINALITY AS l(line, ord)
        ), '[]'::jsonb),
        'totals', v_recalculation->'totals',
        'message', 'Invoice data generated successfully'$r$);

  -- The invoice carries its GRN's pricing mode, as get_invoice_data returns it in header.grn.pricing_mode.
  PERFORM pg_temp.patch_rpc('public.get_invoice_detail(uuid)',
  $m$        'notes', i.notes, 'created_by', i.created_by
    )$m$,
  $r$        'notes', i.notes, 'created_by', i.created_by,
        'grn_pricing_mode', (SELECT gr.pricing_mode FROM goodsreceived gr WHERE gr.id = i.gr_id)
    )$r$);
END $patch$;

DROP FUNCTION pg_temp.patch_rpc(regprocedure, text, text, integer);
