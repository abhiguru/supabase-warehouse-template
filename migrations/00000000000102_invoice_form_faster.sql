-- Migration 102: the invoice form's GRN answer is built set-based, with only the keys it carries.
--
-- Invoice -> new invoice -> Details, picking a GRN, calls generate_invoice_data_for_grn_with_pricing. For a GRN of
-- 3,055 dispatched lines it took about 0.55 s inside the database. After migrations 100 and 101 the answer has 21
-- keys per line, but the inner function generate_invoice_data_for_grn still got there the long way: it asked
-- build_invoice_recalculation_rows for 70 keys per line (a loop of 3,055 rounds, each with its own duration call,
-- rate lookup, a 70-key jsonb, and an append to a growing jsonb[]), then took 49 keys off every line again. Measured on
-- Dev (HVD4, 3,055 lines, 10 items): the line query's correlated "total dispatched" sub-select alone costs about
-- 0.14 s (it is not one of the 21 keys); the rest is the per-line loop work, the 70-key objects and the strip.
--
-- This migration adds build_invoice_form_lines(uuid, text), an internal function that builds exactly what the inner
-- function used to keep: 'items' (the 21 keys, in the same order of lines) and 'totals', with the same figures.
--   * no "total dispatched" sub-select, no invoice_trl join (the form never has an invoice id: it was always NULL);
--   * the duration comes from calculate_invoice_duration itself (the one rule save_invoice also uses), called once per
--     distinct business date of the dispatches, not once per line;
--   * the rate of a line is looked up once per distinct (item, weight) of the GRN, not once per line, with the same
--     rule as build_invoice_recalculation_rows: the GRN's own grn_rates row (narrowest weight range), else
--     find_storage_price, with unit price, labour rate and tax taken from that one source;
--   * amounts and totals use the same expressions and the same numeric(12,2) / numeric(5,2) casts the loop variables had,
--     so every number prints with the same scale; a line with a NULL dispatched quantity makes the totals NULL, as the
--     loop's "v_subtotal + NULL" did;
--   * only the 21 keys are built, the lines are aggregated once.
-- generate_invoice_data_for_grn then calls it instead of build_invoice_recalculation_rows + the strip. Its error
-- answers, header, 'success' and 'message' are unchanged. build_invoice_recalculation_rows, recalculate_invoice_items
-- and save_invoice are not touched (they still need the full lines). The wrapper generate_invoice_data_for_grn_with_pricing
-- is not changed (signature, SECURITY DEFINER, search_path, authorize_rpc call and grants stay).
-- The new function is internal: it is not granted to anon, authenticated or service_role (the REVOKE below is stricter
-- than build_invoice_recalculation_rows, which migration 3's blanket grant leaves granted to service_role); it is
-- reached only through the SECURITY DEFINER functions.
-- The two edits to generate_invoice_data_for_grn use the marker-count pattern; each marker must occur exactly once.

CREATE FUNCTION public.build_invoice_form_lines(p_gr_id uuid, p_duration_mode text DEFAULT 'legacy')
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'public', 'pg_temp'
AS $function$
DECLARE
    v_duration_mode text;
    v_grn_date date;
    v_grn_customer_id uuid;
    v_grn_pricing_mode goodsreceived.pricing_mode%TYPE;
    v_price_type text;
    v_one_time boolean;
    v_result jsonb;
BEGIN
    v_duration_mode := public.validate_invoice_duration_mode(p_duration_mode);

    SELECT warehouse_security.business_date(date), customer_id, pricing_mode
    INTO v_grn_date, v_grn_customer_id, v_grn_pricing_mode
    FROM goodsreceived
    WHERE id = p_gr_id;

    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'error', 'GRN not found');
    END IF;

    v_price_type := CASE WHEN upper(COALESCE(v_grn_pricing_mode, '')) = 'ONE_TIME' THEN 'one_time' ELSE 'monthly' END;
    v_one_time := v_grn_pricing_mode = 'ONE_TIME';

    WITH raw AS (
        SELECT grt.id AS grn_items_id, grt.item_id, grt.item_name, grt.qty, grt.package_mark, grt.rack, grt.weight,
               dt.id AS dt_id, dt.disp_qty, d.id AS d_id, d.disp_no, d.disp_date,
               warehouse_security.business_date(d.disp_date) AS disp_bd, i.name AS catalog_name
        FROM goodsreceived_trl grt
        JOIN dispatch_trl dt ON dt.gr_trl_id = grt.id
        JOIN dispatch d ON d.id = dt.disp_id
        LEFT JOIN items i ON i.id = grt.item_id
        WHERE grt.gr_id = p_gr_id
    ),
    pairs AS (
        SELECT DISTINCT item_id, weight FROM raw
    ),
    rates AS (
        -- One source for the three figures: the GRN's own rate, else the item's (as in migration 86).
        -- This rule is also in build_invoice_recalculation_rows and get_grn_item_rates: change all three together.
        SELECT p.item_id, p.weight,
               CASE WHEN g.id IS NOT NULL THEN g.unit_price ELSE fp.unit_price END AS src_unit,
               CASE WHEN g.id IS NOT NULL THEN g.labour_rate ELSE fp.labour_rate END AS src_labour,
               CASE WHEN g.id IS NOT NULL THEN g.tax_percent ELSE fp.tax_percent END AS src_tax
        FROM pairs p
        LEFT JOIN LATERAL (
            SELECT g2.id, g2.unit_price, g2.labour_rate, g2.tax_percent
            FROM public.grn_rates g2
            WHERE g2.gr_id = p_gr_id AND g2.item_id = p.item_id
              AND g2.price_type = v_price_type
              AND COALESCE(p.weight, 0) BETWEEN g2.weight_min AND g2.weight_max
            ORDER BY (g2.weight_max - g2.weight_min), g2.weight_min
            LIMIT 1
        ) g ON true
        LEFT JOIN LATERAL (
            SELECT f.unit_price, f.labour_rate, f.tax_percent
            FROM find_storage_price(p.item_id, v_grn_customer_id, p.weight, v_grn_date, LOWER(v_grn_pricing_mode)) f
            WHERE g.id IS NULL
        ) fp ON true
    ),
    days AS (
        SELECT DISTINCT disp_bd FROM raw
    ),
    dur AS (
        -- The duration rule lives in calculate_invoice_duration only: once per distinct business date.
        SELECT dy.disp_bd, c.no_of_days, c.billable_days, c.duration
        FROM days dy
        CROSS JOIN LATERAL public.calculate_invoice_duration(v_grn_date, dy.disp_bd, v_duration_mode) c
    ),
    lines AS (
        SELECT r.*, dur.no_of_days, dur.billable_days, dur.duration,
               u.unit_price, u.labour_rate, u.tax_percent,
               CASE WHEN v_one_time THEN ROUND(COALESCE(u.unit_price, 0) * r.disp_qty, 2)::numeric(12,2)
                    ELSE ROUND(COALESCE(u.unit_price, 0) * r.disp_qty * dur.duration, 2)::numeric(12,2) END AS storage_amount,
               CASE WHEN v_one_time THEN 0::numeric(12,2)
                    ELSE ROUND(COALESCE(u.labour_rate, 0) * r.disp_qty, 2)::numeric(12,2) END AS labour_amount
        FROM raw r
        JOIN rates rt ON rt.item_id IS NOT DISTINCT FROM r.item_id AND rt.weight IS NOT DISTINCT FROM r.weight
        JOIN dur ON dur.disp_bd IS NOT DISTINCT FROM r.disp_bd
        CROSS JOIN LATERAL (
            SELECT rt.src_unit::numeric(12,2) AS unit_price,
                   COALESCE(rt.src_labour, 0)::numeric(12,2) AS labour_rate,
                   COALESCE(rt.src_tax, 0)::numeric(5,2) AS tax_percent
        ) u
    ),
    sums AS (
        SELECT COALESCE(sum(l.storage_amount + l.labour_amount), 0)::numeric(12,2) AS subtotal,
               COALESCE(sum((l.storage_amount + l.labour_amount) * COALESCE(l.tax_percent, 0) / 100.0), 0) AS tax_basis,
               count(*)::integer AS total_rows,
               -- A NULL amount (NULL dispatched quantity) makes the old loop's running totals NULL for good.
               COALESCE(bool_or(l.storage_amount IS NULL OR l.labour_amount IS NULL), false) AS has_null,
               COALESCE(jsonb_agg(jsonb_build_object(
                   'grn_items_id', l.grn_items_id,
                   'grn_items_item_id', l.item_id,
                   'grn_items_item_name', l.item_name,
                   'grn_items_original_qty', l.qty,
                   'grn_items_package_mark', l.package_mark,
                   'grn_items_rack', l.rack,
                   'grn_items_weight', l.weight,
                   'grn_items_pricing_mode', v_grn_pricing_mode,
                   'dispatches_items_id', l.dt_id,
                   'dispatches_items_disp_qty', l.disp_qty,
                   'dispatches_id', l.d_id,
                   'dispatches_no', l.disp_no,
                   'dispatches_date', l.disp_date,
                   'items_catalog_name', l.catalog_name,
                   'grn_date', v_grn_date,
                   'no_of_days', l.no_of_days,
                   'billable_days', l.billable_days,
                   'duration', l.duration,
                   'unit_price', l.unit_price,
                   'labour_rate', l.labour_rate,
                   'tax_percent', l.tax_percent
               ) ORDER BY l.item_name, l.disp_date, l.dt_id), '[]'::jsonb) AS items
        FROM lines l
    )
    SELECT jsonb_build_object(
        'success', true,
        'items', s.items,
        'totals', jsonb_build_object(
            'subtotal', CASE WHEN s.has_null THEN NULL ELSE s.subtotal END,
            'tax', CASE WHEN s.has_null THEN NULL ELSE CEIL(s.tax_basis)::numeric(12,2) END,
            'total_tax', CASE WHEN s.has_null THEN NULL ELSE CEIL(s.tax_basis)::numeric(12,2) END,
            'grand_total', CASE WHEN s.has_null THEN NULL ELSE CEIL(s.subtotal + CEIL(s.tax_basis)::numeric(12,2))::numeric(12,2) END,
            'total', CASE WHEN s.has_null THEN NULL ELSE CEIL(s.subtotal + CEIL(s.tax_basis)::numeric(12,2))::numeric(12,2) END,
            'total_rows', s.total_rows
        )
    ) INTO v_result
    FROM sums s;

    RETURN v_result;
END;
$function$;

REVOKE ALL ON FUNCTION public.build_invoice_form_lines(uuid, text) FROM PUBLIC, anon, authenticated, service_role;

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
  -- Build the lines and totals with the lean function instead of the 70-key builder.
  PERFORM pg_temp.patch_rpc('public.generate_invoice_data_for_grn(uuid,text)',
  $m$v_recalculation := public.build_invoice_recalculation_rows(p_gr_id, v_duration_mode, NULL);$m$,
  $r$v_recalculation := public.build_invoice_form_lines(p_gr_id, v_duration_mode);$r$);

  -- The lines arrive with the 21 keys already: no strip, no second aggregation.
  PERFORM pg_temp.patch_rpc('public.generate_invoice_data_for_grn(uuid,text)',
  $m$        'items', COALESCE((
            SELECT jsonb_agg(l.line - ARRAY[
                'amount','base_amount','calculated_days','calculated_duration','catalog_name','catalog_packaging',
                'current_stock','dispatch_customer_name','dispatches_customer_name','dispatches_vehicle',
                'dispatch_item_id','dispatch_qty','dispatch_vehicle','duration_calculation_note','duration_mode',
                'grn_items_current_stock','grn_items_packaging','grn_items_total_dispatched','id','invoice_item_id',
                'item_amount','item_description','item_packaging','items_description','items_packaging','item_tax',
                'item_total','labour_amount','missing_price','original_qty','row_number','rowNumber',
                'storage_amount','tax_amount','total_amount','total_dispatched',
                'grn_item_id','item_id','item_name','qty','package_mark','rack','weight','dispatch_id','dispatch_no',
                'dispatch_date','charge','tax','disp_trl_id'
              ] ORDER BY l.ord)
            FROM jsonb_array_elements(v_recalculation->'items') WITH ORDINALITY AS l(line, ord)
        ), '[]'::jsonb),$m$,
  $r$        'items', v_recalculation->'items',$r$);
END $patch$;

DROP FUNCTION pg_temp.patch_rpc(regprocedure, text, text, integer);
