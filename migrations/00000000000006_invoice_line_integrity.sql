-- Reject invoices whose lines cannot be saved; never commit an empty header as success.
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
    v_totals := COALESCE(p_invoice_data->'data'->'totals', p_invoice_data->'totals', '{}'::jsonb);
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

    -- A header cannot be committed if a JOIN silently drops missing, duplicate,
    -- foreign-customer or foreign-GRN lines. Preserve the existing rounding rule.
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
        COALESCE(NULLIF(p_invoice_data->>'labour', '')::NUMERIC(12,2), 0),
        CEIL(COALESCE(NULLIF(v_totals->>'tax', '')::NUMERIC(12,2), NULLIF(v_totals->>'total_tax', '')::NUMERIC(12,2), NULLIF(p_invoice_data->>'tax_amount', '')::NUMERIC(12,2), 0)),
        CEIL(COALESCE(NULLIF(v_totals->>'grand_total', '')::NUMERIC(12,2), NULLIF(v_totals->>'total', '')::NUMERIC(12,2), NULLIF(p_invoice_data->>'total', '')::NUMERIC(12,2), 0)),
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
        'message', 'Invoice saved successfully'
    );
EXCEPTION
    WHEN OTHERS THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'Database error: ' || SQLERRM || ' (SQLState: ' || SQLSTATE || ')'
        );
END;
$_$;
NOTIFY pgrst, 'reload schema';
