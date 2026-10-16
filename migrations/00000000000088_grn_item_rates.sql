-- Migration 88: the rate each line of a GRN is invoiced at (owner decision of 2026-10-16).
--
-- 1. public.get_grn_item_rates(p_grn_id): one row per lot of the GRN (same order as get_grn_details:
--    by lot id) with the rate that invoicing would use and where it comes from, chosen exactly as
--    build_invoice_recalculation_rows does: (1) the stored invoice figure ('invoice': first invoice
--    line of the lot by dispatch date then id; invoices with deleted_at set or cancelled through
--    cancel_invoice, which appends "[CANCELLED: ...]" to invoice.notes, are skipped; 'varies' is true
--    when the lot's lines carry more than one distinct charge / labour / tax), (2) the GRN's own rate
--    from grn_rates ('grn', narrowest band first), (3) find_storage_price ('customer' when the
--    row has a customer_id, else 'item'). No rate: source and figures are null.
--    Answers {success:false, error:'GRN not found', error_code:'GRN_NOT_FOUND', data:null} for a
--    missing or deleted GRN (after the guard, as get_grn_details does).
-- 2. The guard admits get_grn_item_rates for staff, and for a customer account to the GRNs of a
--    customer it owns (same branch as get_grn_details). Customer accounts may therefore now read the
--    rates of their own GRNs through this function (owner, 2026-10-16), while get_grn_details still
--    answers grn.rates = [] to them.
--
-- Errors follow migration 74: {success, error, error_code, data}.

-- Replaces one marker in a function body, failing unless it occurs exactly
-- `expected` times. Dropped at the end of this migration.
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

DO $patch$ BEGIN
  -- Staff list: after get_item_grn_rates (migration 86).
  PERFORM pg_temp.patch_rpc('warehouse_security.authorize_rpc(text,jsonb)',
  $m$    'get_item_grn_rates',
$m$, $r$    'get_item_grn_rates',
    -- The rate of each line of a GRN (migration 88).
    'get_grn_item_rates',
$r$);
  -- Ownership: a customer account reaches it for the GRNs of a customer it owns.
  PERFORM pg_temp.patch_rpc('warehouse_security.authorize_rpc(text,jsonb)',
  $m$ELSIF rpc IN ('get_grn_details','get_grn_item_dispatches') THEN$m$,
  $r$ELSIF rpc IN ('get_grn_details','get_grn_item_dispatches','get_grn_item_rates') THEN$r$);
END $patch$;

CREATE FUNCTION public.get_grn_item_rates(p_grn_id uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, public, extensions, utils, pg_temp
AS $function$
DECLARE
  v_grn_date date; v_customer_id uuid; v_pricing_mode text; v_invoiced boolean; v_gr_id uuid;
  v_price_type text;
  v_lot record; v_rates jsonb := '[]'::jsonb;
  v_source text; v_unit numeric(12,2); v_labour numeric(12,2); v_tax numeric(5,2);
  v_min integer; v_max integer; v_varies boolean;
  v_price item_storage_prices;
BEGIN
  PERFORM warehouse_security.authorize_rpc('get_grn_item_rates', jsonb_build_object('p_grn_id', p_grn_id));

  SELECT g.id, warehouse_security.business_date(g.date), g.customer_id, g.pricing_mode, COALESCE(g.invoiced, false)
    INTO v_gr_id, v_grn_date, v_customer_id, v_pricing_mode, v_invoiced
    FROM public.goodsreceived g
   WHERE g.id = p_grn_id AND g.deleted_at IS NULL;
  IF v_gr_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'GRN not found', 'error_code', 'GRN_NOT_FOUND', 'data', NULL);
  END IF;
  v_price_type := CASE WHEN upper(COALESCE(v_pricing_mode, '')) = 'ONE_TIME' THEN 'one_time' ELSE 'monthly' END;

  FOR v_lot IN
    SELECT grt.id, grt.item_id, grt.item_name, grt.weight
      FROM public.goodsreceived_trl grt
     WHERE grt.gr_id = p_grn_id
     ORDER BY grt.id
  LOOP
    v_source := NULL; v_unit := NULL; v_labour := NULL; v_tax := NULL; v_min := NULL; v_max := NULL; v_varies := false;

    -- 1. The stored invoice figure: first line of the lot by dispatch date, then id.
    SELECT it.charge, it.labour_rate, it.tax INTO v_unit, v_labour, v_tax
      FROM public.invoice_trl it
      JOIN public.invoice inv ON inv.id = it.invoice_id
      JOIN public.dispatch_trl dt ON dt.id = it.disp_trl_id
      JOIN public.dispatch d ON d.id = dt.disp_id
     WHERE dt.gr_trl_id = v_lot.id
       AND inv.deleted_at IS NULL AND COALESCE(inv.notes, '') NOT LIKE '%[CANCELLED:%'
     ORDER BY d.disp_date, it.id
     LIMIT 1;
    IF FOUND THEN
      v_source := 'invoice';
      SELECT count(DISTINCT (it.charge, it.labour_rate, it.tax)) > 1 INTO v_varies
        FROM public.invoice_trl it
        JOIN public.invoice inv ON inv.id = it.invoice_id
        JOIN public.dispatch_trl dt ON dt.id = it.disp_trl_id
       WHERE dt.gr_trl_id = v_lot.id
         AND inv.deleted_at IS NULL AND COALESCE(inv.notes, '') NOT LIKE '%[CANCELLED:%';
    ELSE
      -- 2. The GRN's own rate (same query as build_invoice_recalculation_rows).
      SELECT g.unit_price, g.labour_rate, g.tax_percent, g.weight_min, g.weight_max
        INTO v_unit, v_labour, v_tax, v_min, v_max
        FROM public.grn_rates g
       WHERE g.gr_id = p_grn_id AND g.item_id = v_lot.item_id
         AND g.price_type = v_price_type
         AND COALESCE(v_lot.weight, 0) BETWEEN g.weight_min AND g.weight_max
       ORDER BY (g.weight_max - g.weight_min), g.weight_min
       LIMIT 1;
      IF FOUND THEN
        v_source := 'grn';
      ELSE
        -- 3. The customer's rate, else the item's default rate.
        v_price := find_storage_price(v_lot.item_id, v_customer_id, v_lot.weight, v_grn_date, lower(v_pricing_mode));
        IF v_price.id IS NOT NULL THEN
          v_source := CASE WHEN v_price.customer_id IS NOT NULL THEN 'customer' ELSE 'item' END;
          v_unit := v_price.unit_price; v_labour := v_price.labour_rate; v_tax := v_price.tax_percent;
          v_min := v_price.weight_min; v_max := v_price.weight_max;
        ELSE
          v_unit := NULL; v_labour := NULL; v_tax := NULL; v_min := NULL; v_max := NULL;
        END IF;
      END IF;
    END IF;

    v_rates := v_rates || jsonb_build_array(jsonb_build_object(
      'grn_item_id', v_lot.id, 'item_id', v_lot.item_id, 'item_name', v_lot.item_name, 'weight', v_lot.weight,
      'source', v_source, 'unit_price', v_unit, 'labour_rate', v_labour, 'tax_percent', v_tax,
      'weight_min', v_min, 'weight_max', v_max, 'varies', COALESCE(v_varies, false)));
  END LOOP;

  RETURN jsonb_build_object('success', true, 'data', jsonb_build_object(
    'gr_id', p_grn_id, 'grn_date', v_grn_date, 'price_type', v_price_type, 'invoiced', v_invoiced, 'rates', v_rates));
END;
$function$;
REVOKE ALL ON FUNCTION public.get_grn_item_rates(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_grn_item_rates(uuid) TO authenticated, service_role;

DROP FUNCTION pg_temp.patch_rpc(regprocedure, text, text, integer);
NOTIFY pgrst, 'reload schema';
