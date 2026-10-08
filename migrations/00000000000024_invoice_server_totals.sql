-- Server-authoritative invoice totals (user decision, 2026-10-08). Header
-- labour, tax and total derive from the saved lines and the stored discount for
-- every role; client-supplied header totals are ignored. Line rates, discount,
-- notes, numbers and dates remain inputs. Arithmetic matches the preview in
-- build_invoice_recalculation_rows and docs/INVOICE_RULES.md, with the stored
-- discount subtracted from the final total exactly as the mobile client does.
CREATE FUNCTION warehouse_security.recalculate_invoice_header(p_invoice_id uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE line_count integer; subtotal numeric(12,2); labour_total numeric(12,2); tax_basis numeric;
  tax_total numeric(12,2); grand numeric(12,2); discount_value numeric(12,2);
BEGIN
  SELECT count(*), COALESCE(sum(l.base),0), COALESCE(sum(l.labour),0), COALESCE(sum(l.base*l.tax_percent/100.0),0)
    INTO line_count, subtotal, labour_total, tax_basis
  FROM (
    SELECT
      CASE WHEN gr.pricing_mode='ONE_TIME'
        THEN round(COALESCE(it.charge,0)*dt.disp_qty,2)
        ELSE round(COALESCE(it.charge,0)*dt.disp_qty*COALESCE(it.duration,1),2)
             + round(COALESCE(it.labour_rate,0)*dt.disp_qty,2) END AS base,
      CASE WHEN gr.pricing_mode='ONE_TIME' THEN 0::numeric
        ELSE round(COALESCE(it.labour_rate,0)*dt.disp_qty,2) END AS labour,
      COALESCE(it.tax,0) AS tax_percent
    FROM public.invoice_trl it
    JOIN public.dispatch_trl dt ON dt.id=it.disp_trl_id
    JOIN public.goodsreceived gr ON gr.id=dt.gr_id
    WHERE it.invoice_id=p_invoice_id) l;
  IF line_count=0 THEN RAISE EXCEPTION 'Invoice requires at least one dispatch line'; END IF;
  SELECT COALESCE(discount,0) INTO discount_value FROM public.invoice WHERE id=p_invoice_id;
  tax_total := ceil(tax_basis);
  grand := ceil(subtotal + tax_total - discount_value);
  IF grand < 0 THEN RAISE EXCEPTION 'Discount exceeds the invoice amount'; END IF;
  UPDATE public.invoice SET labour=labour_total, tax_amount=tax_total, total=grand WHERE id=p_invoice_id;
  RETURN jsonb_build_object('subtotal',subtotal,'labour',labour_total,'tax',tax_total,'total_tax',tax_total,
    'discount',discount_value,'grand_total',grand,'total',grand,'total_rows',line_count);
END $$;
REVOKE ALL ON FUNCTION warehouse_security.recalculate_invoice_header(uuid) FROM PUBLIC,anon,authenticated,service_role;

-- A header must never commit when a JOIN silently dropped, duplicated or
-- mis-attributed a line. Shared by every save/update path.
CREATE FUNCTION warehouse_security.assert_invoice_lines(p_invoice_id uuid, p_gr_id uuid, p_customer_id uuid, p_expected integer) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE saved integer; distinct_lines integer; unrelated integer;
BEGIN
  IF COALESCE(p_expected,0) < 1 THEN RAISE EXCEPTION 'Invoice requires at least one dispatch line'; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.goodsreceived g WHERE g.id=p_gr_id AND g.customer_id=p_customer_id AND g.deleted_at IS NULL) THEN
    RAISE EXCEPTION 'Invoice customer and GRN must match';
  END IF;
  SELECT count(*), count(DISTINCT it.disp_trl_id),
    count(*) FILTER (WHERE dt.gr_id IS DISTINCT FROM p_gr_id OR d.customer_id IS DISTINCT FROM p_customer_id OR d.deleted_at IS NOT NULL)
    INTO saved, distinct_lines, unrelated
  FROM public.invoice_trl it
  JOIN public.dispatch_trl dt ON dt.id=it.disp_trl_id
  JOIN public.dispatch d ON d.id=dt.disp_id
  WHERE it.invoice_id=p_invoice_id;
  IF saved <> p_expected OR distinct_lines <> saved OR unrelated > 0 THEN
    RAISE EXCEPTION 'Invoice contains a missing, duplicate or unrelated dispatch line';
  END IF;
END $$;
REVOKE ALL ON FUNCTION warehouse_security.assert_invoice_lines(uuid,uuid,uuid,integer) FROM PUBLIC,anon,authenticated,service_role;

-- save_invoice(jsonb): the reviewed migration-06 body with computed header totals.
CREATE OR REPLACE FUNCTION public.save_invoice(p_invoice_data jsonb) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path = pg_catalog, public, extensions, utils, pg_temp
    AS $_$
DECLARE
    v_invoice_id UUID;
    v_invoice_header JSONB;
    v_invoice_items JSONB;
    v_totals JSONB;
    v_user_id UUID;
    v_created_at TIMESTAMPTZ := NOW();
    v_is_auto_generated BOOLEAN;
    v_items_count INTEGER;
    v_duration_mode text;
    v_invoice_number_text text;
    v_invoice_number_int integer;
    v_fin_year integer;
BEGIN
    PERFORM warehouse_security.authorize_rpc('save_invoice', '{}'::jsonb);
    SELECT id INTO v_user_id FROM user_profiles WHERE auth_user_id = auth.uid();

    v_invoice_header := COALESCE(p_invoice_data->'data'->'header', p_invoice_data->'header', '{}'::jsonb);
    v_invoice_items := COALESCE(p_invoice_data->'data'->'items', p_invoice_data->'data'->'rows', p_invoice_data->'items', p_invoice_data->'rows', '[]'::jsonb);
    v_duration_mode := public.validate_invoice_duration_mode(COALESCE(p_invoice_data->>'duration_mode', v_invoice_header->>'duration_mode'));

    v_invoice_number_text := COALESCE(v_invoice_header->>'invoice_number', p_invoice_data->>'inv_no');
    v_invoice_number_int := COALESCE(
        NULLIF(p_invoice_data->>'inv_no', '')::integer,
        NULLIF(REGEXP_REPLACE(COALESCE(v_invoice_number_text, ''), '^.*-([0-9]+)$', '\1'), '')::integer
    );
    v_fin_year := COALESCE(
        NULLIF(p_invoice_data->>'inv_fin_year', '')::integer,
        NULLIF(SPLIT_PART(COALESCE(v_invoice_header->>'financial_year', ''), '-', 1), '')::integer,
        CASE WHEN EXTRACT(MONTH FROM CURRENT_DATE) >= 4 THEN EXTRACT(YEAR FROM CURRENT_DATE)::integer ELSE EXTRACT(YEAR FROM CURRENT_DATE)::integer - 1 END
    );

    v_is_auto_generated := COALESCE(
        (p_invoice_data->>'is_auto_generated')::boolean,
        (v_invoice_header->>'is_auto_generated')::boolean,
        false
    );

    IF jsonb_typeof(v_invoice_items) <> 'array' OR jsonb_array_length(v_invoice_items) = 0 THEN
        RAISE EXCEPTION 'Invoice requires at least one dispatch line';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM goodsreceived g
        WHERE g.id = COALESCE(v_invoice_header->>'grn_id', p_invoice_data->>'gr_id')::uuid
          AND g.customer_id = COALESCE(v_invoice_header->>'customer_id', p_invoice_data->>'customer_id')::uuid
          AND g.deleted_at IS NULL
    ) THEN RAISE EXCEPTION 'Invoice customer and GRN must match'; END IF;
    IF (SELECT count(DISTINCT dt.id)
        FROM jsonb_array_elements(v_invoice_items) item
        JOIN dispatch_trl dt ON dt.id = COALESCE(item->>'disp_trl_id', item->>'dispatches_items_id', item->>'dispatch_item_id')::uuid
        JOIN dispatch d ON d.id = dt.disp_id
        WHERE dt.gr_id = COALESCE(v_invoice_header->>'grn_id', p_invoice_data->>'gr_id')::uuid
          AND d.customer_id = COALESCE(v_invoice_header->>'customer_id', p_invoice_data->>'customer_id')::uuid
          AND d.deleted_at IS NULL) <> jsonb_array_length(v_invoice_items)
    THEN RAISE EXCEPTION 'Invoice contains a missing, duplicate or unrelated dispatch line'; END IF;

    -- Header money columns are placeholders until the lines are saved below.
    INSERT INTO invoice (
        inv_fin_year, inv_no, gr_id, gr_no,
        customer_id, customer_name, inv_date,
        labour, tax_amount, total, discount,
        one_time_charge, notes, created_by, is_auto_generated, duration_mode
    ) VALUES (
        v_fin_year,
        v_invoice_number_int,
        COALESCE(v_invoice_header->>'grn_id', p_invoice_data->>'gr_id')::UUID,
        COALESCE(v_invoice_header->>'grn_no', p_invoice_data->>'gr_no'),
        COALESCE(v_invoice_header->>'customer_id', p_invoice_data->>'customer_id')::UUID,
        COALESCE(v_invoice_header->>'customer_name', p_invoice_data->>'customer_name'),
        COALESCE((v_invoice_header->>'invoice_date')::TIMESTAMPTZ, (p_invoice_data->>'inv_date')::TIMESTAMPTZ, v_created_at),
        0::NUMERIC(12,2),
        0::NUMERIC(12,2),
        0::NUMERIC(12,2),
        COALESCE(NULLIF(p_invoice_data->>'discount', '')::NUMERIC(12,2), 0),
        COALESCE((p_invoice_data->>'one_time_charge')::boolean, false),
        CASE WHEN v_is_auto_generated THEN 'Auto-generated invoice' ELSE COALESCE(p_invoice_data->>'notes', 'Manual invoice') END,
        v_user_id,
        v_is_auto_generated,
        v_duration_mode
    ) RETURNING id INTO v_invoice_id;

    INSERT INTO invoice_trl (invoice_id, disp_trl_id, duration, no_of_days, charge, tax, labour_rate)
    SELECT
        v_invoice_id,
        COALESCE(item->>'disp_trl_id', item->>'dispatches_items_id', item->>'dispatch_item_id')::UUID,
        d.duration,
        d.no_of_days,
        COALESCE(NULLIF(item->>'charge', '')::NUMERIC(12,2), NULLIF(item->>'unit_price', '')::NUMERIC(12,2)),
        COALESCE(NULLIF(item->>'tax', '')::NUMERIC(12,2), NULLIF(item->>'tax_percent', '')::NUMERIC(12,2)),
        (item->>'labour_rate')::NUMERIC
    FROM jsonb_array_elements(v_invoice_items) AS item
    JOIN dispatch_trl dt ON dt.id = COALESCE(item->>'disp_trl_id', item->>'dispatches_items_id', item->>'dispatch_item_id')::UUID
    JOIN dispatch disp ON disp.id = dt.disp_id
    JOIN goodsreceived gr ON gr.id = dt.gr_id
    CROSS JOIN LATERAL public.calculate_invoice_duration(gr.date::date, disp.disp_date::date, v_duration_mode) d;

    GET DIAGNOSTICS v_items_count = ROW_COUNT;
    v_totals := warehouse_security.recalculate_invoice_header(v_invoice_id);

    UPDATE goodsreceived
    SET invoiced = true
    WHERE id = COALESCE(v_invoice_header->>'grn_id', p_invoice_data->>'gr_id')::UUID;

    RETURN jsonb_build_object(
        'success', true,
        'invoice_id', v_invoice_id,
        'invoice_no', v_invoice_number_text,
        'duration_mode', v_duration_mode,
        'is_auto_generated', v_is_auto_generated,
        'items_count', v_items_count,
        'totals', v_totals,
        'message', 'Invoice saved successfully'
    );
EXCEPTION
    WHEN insufficient_privilege THEN RAISE;
    WHEN OTHERS THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'Database error: ' || SQLERRM || ' (SQLState: ' || SQLSTATE || ')'
        );
END;
$_$;

-- save_invoice_internal and update_invoice keep their injected authorization
-- guard, so they are text-patched rather than re-created from source.
DO $patch$
DECLARE fn regprocedure; definition text; marker text; replacement text; occurrences integer;
BEGIN
  fn := 'public.save_invoice_internal(uuid,jsonb,jsonb[])'::regprocedure;
  definition := pg_get_functiondef(fn);
  marker := $m$            (p_invoice_data->>'labour')::NUMERIC(12,2),
            CEIL((p_invoice_data->>'tax_amount')::NUMERIC(12,2)),
            CEIL((p_invoice_data->>'total')::NUMERIC(12,2)),$m$;
  replacement := $r$            0::NUMERIC(12,2),
            0::NUMERIC(12,2),
            0::NUMERIC(12,2),$r$;
  occurrences := (length(definition)-length(replace(definition,marker,'')))/length(marker);
  IF occurrences <> 2 THEN RAISE EXCEPTION 'Expected two header total expressions in save_invoice_internal, found %', occurrences; END IF;
  definition := replace(definition,marker,replacement);
  marker := $m$    GET DIAGNOSTICS v_new_items_count = ROW_COUNT;$m$;
  occurrences := (length(definition)-length(replace(definition,marker,'')))/length(marker);
  IF occurrences <> 1 THEN RAISE EXCEPTION 'Expected one line-count marker in save_invoice_internal, found %', occurrences; END IF;
  replacement := marker || $r$
    PERFORM warehouse_security.assert_invoice_lines(v_final_invoice_id, v_new_gr_id,
        (p_invoice_data->>'customer_id')::uuid, COALESCE(array_length(p_invoice_items, 1), 0));
    PERFORM warehouse_security.recalculate_invoice_header(v_final_invoice_id);$r$;
  EXECUTE replace(definition,marker,replacement);

  fn := 'public.update_invoice(uuid,jsonb,jsonb[])'::regprocedure;
  definition := pg_get_functiondef(fn);
  marker := $m$        labour = (p_invoice_data->>'labour')::NUMERIC(12,2),
        tax_amount = CEIL((p_invoice_data->>'tax_amount')::NUMERIC(12,2)),
        total = CEIL((p_invoice_data->>'total')::NUMERIC(12,2)),$m$;
  replacement := $r$        labour = 0,
        tax_amount = 0,
        total = 0,$r$;
  occurrences := (length(definition)-length(replace(definition,marker,'')))/length(marker);
  IF occurrences <> 1 THEN RAISE EXCEPTION 'Expected one header total expression in update_invoice, found %', occurrences; END IF;
  definition := replace(definition,marker,replacement);
  marker := $m$    GET DIAGNOSTICS v_items_count = ROW_COUNT;$m$;
  occurrences := (length(definition)-length(replace(definition,marker,'')))/length(marker);
  IF occurrences <> 1 THEN RAISE EXCEPTION 'Expected one line-count marker in update_invoice, found %', occurrences; END IF;
  replacement := marker || $r$
    PERFORM warehouse_security.assert_invoice_lines(p_invoice_id, v_new_gr_id,
        (p_invoice_data->>'customer_id')::uuid, COALESCE(array_length(p_invoice_items, 1), 0));
    PERFORM warehouse_security.recalculate_invoice_header(p_invoice_id);$r$;
  definition := replace(definition,marker,replacement);
  marker := $m$EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('success', false, 'error', SQLERRM, 'error_code', SQLSTATE);$m$;
  replacement := $r$EXCEPTION WHEN insufficient_privilege THEN RAISE;
WHEN OTHERS THEN
    RETURN jsonb_build_object('success', false, 'error', SQLERRM, 'error_code', SQLSTATE);$r$;
  occurrences := (length(definition)-length(replace(definition,marker,'')))/length(marker);
  IF occurrences <> 1 THEN RAISE EXCEPTION 'Expected one exception handler in update_invoice, found %', occurrences; END IF;
  EXECUTE replace(definition,marker,replacement);
END $patch$;
NOTIFY pgrst, 'reload schema';
