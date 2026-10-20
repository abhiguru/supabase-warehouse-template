-- Open items 2026-10-20: the GRN picker pages after it sorts; a deleted invoice is not found; lists and the lines of
-- invoices and dispatches have a total, stable order; dead functions and one dead view are dropped.

-- Fix 1: the GRN picker sorts before it pages
CREATE OR REPLACE FUNCTION public.get_customer_grns_with_stock_dispatch_sorted(p_customer_id uuid, p_limit integer DEFAULT 20, p_offset integer DEFAULT 0) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'extensions', 'utils', 'pg_temp'
    AS $$
DECLARE
    v_user_role text;
    v_user_customer_ids uuid[];
    v_is_superuser boolean;
    v_result jsonb;
BEGIN
  PERFORM warehouse_security.authorize_rpc('get_customer_grns_with_stock_dispatch_sorted',jsonb_build_object('p_customer_id',p_customer_id));
    -- Validate required parameter
    IF p_customer_id IS NULL THEN
        RETURN jsonb_build_object(
            'success', false,
            'data', null,
            'message', 'p_customer_id is required'
        );
    END IF;

    -- Normalize pagination
    IF p_limit IS NULL OR p_limit < 1 THEN
        p_limit := 20;
    ELSIF p_limit > 100 THEN
        p_limit := 100;
    END IF;

    IF p_offset IS NULL OR p_offset < 0 THEN
        p_offset := 0;
    END IF;

    -- Check if running as superuser (for testing)
    SELECT current_user = 'postgres' INTO v_is_superuser;

    -- Security: Get user role (skip if superuser)
    IF NOT v_is_superuser THEN
        SELECT role INTO v_user_role FROM user_profiles
        WHERE auth_user_id = auth.uid();

        -- If user is not admin/supervisor, verify customer access
        IF v_user_role NOT IN ('admin', 'supervisor', 'staff') THEN
            v_user_customer_ids := user_accessible_customers();

            -- Check if user has access to this customer
            IF NOT (p_customer_id = ANY(v_user_customer_ids)) THEN
                RETURN jsonb_build_object(
                    'success', false,
                    'data', null,
                    'message', 'Access denied'
                );
            END IF;
        END IF;
    END IF;

    -- Sort first, then page: the page is the p_limit most recently dispatched GRNs after p_offset, not an arbitrary
    -- slice that is sorted afterwards. The last key (gr.id) makes the order total, so paging never repeats or skips a GRN.
    SELECT jsonb_agg(row_data ORDER BY last_dispatch DESC NULLS LAST, grn_date DESC, gr_no, grn_id)
    INTO v_result
    FROM (
        SELECT jsonb_build_object(
            'grn_id', gs.id,
            'gr_no', gs.gr_no,
            'grn_date', gs.date,
            'customer_name', gs.customer_name,
            'total_stock', gs.total_stock,
            'item_count', gs.item_count,
            'last_dispatch_date', ld.last_dispatch
        ) as row_data,
        ld.last_dispatch,
        gs.date AS grn_date,
        gs.gr_no,
        gs.id AS grn_id
        FROM (
            SELECT
                gr.id,
                gr.gr_no,
                gr.date,
                gr.customer_name,
                SUM(grt.stock)::INTEGER as total_stock,
                COUNT(grt.id)::INTEGER as item_count
            FROM goodsreceived gr
            JOIN goodsreceived_trl grt ON gr.id = grt.gr_id AND grt.stock > 0
            WHERE gr.customer_id = p_customer_id
              AND gr.deleted_at IS NULL
            GROUP BY gr.id, gr.gr_no, gr.date, gr.customer_name
        ) gs
        CROSS JOIN LATERAL (
            SELECT MAX(d.disp_date) AS last_dispatch
            FROM dispatch_trl dt
            JOIN dispatch d ON dt.disp_id = d.id AND d.deleted_at IS NULL
            WHERE dt.gr_id = gs.id
        ) ld
        ORDER BY ld.last_dispatch DESC NULLS LAST, gs.date DESC, gs.gr_no, gs.id
        LIMIT p_limit
        OFFSET p_offset
    ) sub;

    RETURN jsonb_build_object(
        'success', true,
        'data', COALESCE(v_result, '[]'::jsonb)
    );
END;
$$;

-- Fix 2 and 3: invoice details: a deleted invoice is not found; lines in the order they were saved
CREATE OR REPLACE FUNCTION public.get_invoice_data(p_invoice_id uuid) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'extensions', 'utils', 'pg_temp'
    AS $$
    DECLARE
        v_user_role text;
        v_user_id uuid;
        v_invoice_header record;
        v_invoice_items jsonb[];
        v_item_record record;
        v_result jsonb;
BEGIN
  PERFORM warehouse_security.authorize_rpc('get_invoice_data',jsonb_build_object('p_invoice_id',p_invoice_id));
        SELECT id, role INTO v_user_id, v_user_role
        FROM user_profiles
        WHERE auth_user_id = auth.uid();

        IF v_user_role NOT IN ('admin', 'supervisor', 'staff') AND auth.uid() IS NOT NULL THEN
            IF NOT EXISTS (
                SELECT 1 FROM invoice i
                JOIN users_customers_new ucn ON ucn.customer_id = i.customer_id
                WHERE i.id = p_invoice_id
                AND ucn.user_profile_id = v_user_id
            ) THEN
                RETURN jsonb_build_object(
                    'success', false,
                    'error', 'Access denied to this invoice'
                );
            END IF;
        END IF;

        SELECT
            i.id as invoice_id,
            i.inv_no as invoice_number,
            i.inv_date as invoice_date,
            i.inv_fin_year,
            i.inv_fin_year || '-' || (i.inv_fin_year + 1) as financial_year,
            i.gr_id,
            i.gr_no,
            i.customer_id,
            i.customer_name as invoice_customer_name,
            i.inv_name,
            i.one_time_charge,
            i.labour,
            i.tax_amount,
            i.total,
            i.discount,
            i.is_auto_generated,
            i.pricing_mode,
            COALESCE(i.duration_mode, 'legacy') as duration_mode,
            i.notes,
            i.created_by,

            c.address as customer_address,
            c.city as customer_city,
            c."firstName" as customer_firstName,
            c."lastName" as customer_lastName,
            c.mobile as customer_mobile,
            c.name as customer_name,
            c.pincode as customer_pincode,
            c.state as customer_state,
            c.telephone1 as customer_telephone1,
            c.telephone2 as customer_telephone2,
            c.gst as customer_gst,
            c.email as customer_email,
            c.active as customer_active,
            c.contact as customer_contact,
            c.pan as customer_pan,
            c.auto_invoice_generation as customer_auto_invoice_generation,
            c.created_at as customer_created_at,
            c.updated_at as customer_updated_at,

            gr.id as grn_id,
            gr.gr_no as grn_number,
            gr.registration as grn_registration,
            gr.date as grn_date,
            gr.sender_id as grn_sender_id,
            gr.sender_name as grn_sender_name,
            gr.customer_id as grn_customer_id,
            gr.customer_name as grn_customer_name,
            gr.supervisor_id as grn_supervisor_id,
            gr.supervisor_name as grn_supervisor_name,
            gr.note as grn_note,
            gr.leon as grn_leon,
            gr.out_of_stock as grn_out_of_stock,
            gr.invoiced as grn_invoiced,
            gr.gr_image_url,
            gr.created_by as grn_created_by,
            gr.updated_by as grn_updated_by,
            gr.created_at as grn_created_at,
            gr.updated_at as grn_updated_at,
            gr.pricing_mode as grn_pricing_mode,

            cb.name as created_by_name,
            cb.display_name as created_by_display_name,
            cb.role as created_by_role

        INTO v_invoice_header
        FROM invoice i
        JOIN customers c ON c.id = i.customer_id
        JOIN goodsreceived gr ON gr.id = i.gr_id
        LEFT JOIN user_profiles cb ON cb.id = i.created_by
        WHERE i.id = p_invoice_id
          AND i.deleted_at IS NULL;

        IF NOT FOUND THEN
            RETURN jsonb_build_object(
                'success', false,
                'error', 'Invoice not found'
            );
        END IF;

        v_invoice_items := ARRAY[]::jsonb[];

        FOR v_item_record IN
            SELECT
                it.id as item_id,
                it.invoice_id,
                it.disp_trl_id,
                it.duration,
                it.no_of_days,
                it.charge,
                it.tax,
                it.labour_rate,

                dt.id as dispatch_item_id,
                dt.gr_id as dispatch_gr_id,
                dt.gr_trl_id as dispatch_gr_trl_id,
                dt.disp_id as dispatch_disp_id,
                dt.disp_qty as dispatch_quantity,

                d.disp_no as dispatch_no,
                d.disp_date as dispatch_date,

                grt.id as grn_item_id,
                grt.gr_id as grn_item_gr_id,
                grt.item_id as grn_item_item_id,
                grt.item_name as grn_item_name,
                grt.packaging as grn_item_packaging,
                grt.qty as grn_original_quantity,
                grt.stock as grn_current_stock,
                grt.weight as grn_weight,
                grt.rack as grn_rack,
                grt.package_mark as grn_package_mark,
                grt.trl_img_url as grn_item_image_url,
                gr.pricing_mode as grn_item_pricing_mode,

                items.id as catalog_id,
                items.name as catalog_name,
                items.packaging as catalog_packaging,
                items.description as catalog_description,
                items.active as catalog_active

            FROM invoice_trl it
            LEFT JOIN dispatch_trl dt ON dt.id = it.disp_trl_id
            LEFT JOIN dispatch d ON d.id = dt.disp_id
            LEFT JOIN goodsreceived_trl grt ON grt.id = dt.gr_trl_id
            LEFT JOIN goodsreceived gr ON gr.id = grt.gr_id
            LEFT JOIN items ON items.id = grt.item_id
            WHERE it.invoice_id = p_invoice_id
            ORDER BY uuid_extract_timestamp(it.id), it.id
        LOOP
            v_invoice_items := v_invoice_items || jsonb_build_object(
                'item_id', v_item_record.item_id,
                'invoice_id', v_item_record.invoice_id,
                'disp_trl_id', v_item_record.disp_trl_id,
                'duration', v_item_record.duration,
                'no_of_days', v_item_record.no_of_days,
                'charge', v_item_record.charge,
                'tax', v_item_record.tax,
                'labour_rate', v_item_record.labour_rate,

                'dispatch', jsonb_build_object(
                    'id', v_item_record.dispatch_item_id,
                    'gr_id', v_item_record.dispatch_gr_id,
                    'gr_trl_id', v_item_record.dispatch_gr_trl_id,
                    'disp_id', v_item_record.dispatch_disp_id,
                    'quantity', v_item_record.dispatch_quantity,
                    'disp_no', v_item_record.dispatch_no,
                    'disp_date', v_item_record.dispatch_date
                ),

                'grn_item', jsonb_build_object(
                    'id', v_item_record.grn_item_id,
                    'gr_id', v_item_record.grn_item_gr_id,
                    'item_id', v_item_record.grn_item_item_id,
                    'name', v_item_record.grn_item_name,
                    'packaging', v_item_record.grn_item_packaging,
                    'original_quantity', v_item_record.grn_original_quantity,
                    'current_stock', v_item_record.grn_current_stock,
                    'weight', v_item_record.grn_weight,
                    'rack', v_item_record.grn_rack,
                    'package_mark', v_item_record.grn_package_mark,
                    'image_url', v_item_record.grn_item_image_url,
                    'pricing_mode', v_item_record.grn_item_pricing_mode
                ),

                'catalog', jsonb_build_object(
                    'id', v_item_record.catalog_id,
                    'name', v_item_record.catalog_name,
                    'packaging', v_item_record.catalog_packaging,
                    'description', v_item_record.catalog_description,
                    'active', v_item_record.catalog_active
                )
            );
        END LOOP;

        v_result := jsonb_build_object(
            'success', true,
            'data', jsonb_build_object(
                'header', jsonb_build_object(
                    'invoice_id', v_invoice_header.invoice_id,
                    'invoice_number', v_invoice_header.invoice_number,
                    'invoice_date', v_invoice_header.invoice_date,
                    'inv_fin_year', v_invoice_header.inv_fin_year,
                    'financial_year', v_invoice_header.financial_year,
                    'gr_id', v_invoice_header.gr_id,
                    'gr_no', v_invoice_header.gr_no,
                    'customer_id', v_invoice_header.customer_id,
                    'invoice_customer_name', v_invoice_header.invoice_customer_name,
                    'inv_name', v_invoice_header.inv_name,
                    'one_time_charge', v_invoice_header.one_time_charge,
                    'labour', v_invoice_header.labour,
                    'tax_amount', v_invoice_header.tax_amount,
                    'total', v_invoice_header.total,
                    'discount', v_invoice_header.discount,
                    'is_auto_generated', v_invoice_header.is_auto_generated,
                    'pricing_mode', v_invoice_header.pricing_mode,
                    'duration_mode', v_invoice_header.duration_mode,
                    'notes', v_invoice_header.notes,
                    'created_by', v_invoice_header.created_by,

                    'customer', jsonb_build_object(
                        'id', v_invoice_header.customer_id,
                        'name', v_invoice_header.customer_name,
                        'first_name', v_invoice_header.customer_firstName,
                        'last_name', v_invoice_header.customer_lastName,
                        'address', v_invoice_header.customer_address,
                        'city', v_invoice_header.customer_city,
                        'mobile', v_invoice_header.customer_mobile,
                        'pincode', v_invoice_header.customer_pincode,
                        'state', v_invoice_header.customer_state,
                        'telephone1', v_invoice_header.customer_telephone1,
                        'telephone2', v_invoice_header.customer_telephone2,
                        'gst', v_invoice_header.customer_gst,
                        'email', v_invoice_header.customer_email,
                        'active', v_invoice_header.customer_active,
                        'contact', v_invoice_header.customer_contact,
                        'pan', v_invoice_header.customer_pan,
                        'auto_invoice_generation', v_invoice_header.customer_auto_invoice_generation,
                        'created_at', v_invoice_header.customer_created_at,
                        'updated_at', v_invoice_header.customer_updated_at
                    ),

                    'grn', jsonb_build_object(
                        'id', v_invoice_header.grn_id,
                        'gr_no', v_invoice_header.grn_number,
                        'registration', v_invoice_header.grn_registration,
                        'date', v_invoice_header.grn_date,
                        'sender_id', v_invoice_header.grn_sender_id,
                        'sender_name', v_invoice_header.grn_sender_name,
                        'customer_id', v_invoice_header.grn_customer_id,
                        'customer_name', v_invoice_header.grn_customer_name,
                        'supervisor_id', v_invoice_header.grn_supervisor_id,
                        'supervisor_name', v_invoice_header.grn_supervisor_name,
                        'note', v_invoice_header.grn_note,
                        'leon', v_invoice_header.grn_leon,
                        'out_of_stock', v_invoice_header.grn_out_of_stock,
                        'invoiced', v_invoice_header.grn_invoiced,
                        'image_url', v_invoice_header.gr_image_url,
                        'created_by', v_invoice_header.grn_created_by,
                        'updated_by', v_invoice_header.grn_updated_by,
                        'created_at', v_invoice_header.grn_created_at,
                        'updated_at', v_invoice_header.grn_updated_at,
                        'pricing_mode', v_invoice_header.grn_pricing_mode
                    ),

                    'created_by_info', jsonb_build_object(
                        'id', v_invoice_header.created_by,
                        'name', v_invoice_header.created_by_name,
                        'display_name', v_invoice_header.created_by_display_name,
                        'role', v_invoice_header.created_by_role
                    )
                ),
                'items', v_invoice_items
            )
        );

        RETURN v_result;

    EXCEPTION
        WHEN OTHERS THEN
            RETURN jsonb_build_object(
                'success', false,
                'error', 'Error retrieving invoice data: ' || SQLERRM
            );
    END;
    $$;

CREATE OR REPLACE FUNCTION public.get_invoice_detail(p_invoice_id uuid) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'extensions', 'utils', 'pg_temp'
    AS $$
DECLARE
    v_invoice_header jsonb;
    v_invoice_items jsonb;
BEGIN
  PERFORM warehouse_security.authorize_rpc('get_invoice_detail',jsonb_build_object('p_invoice_id',p_invoice_id));
    SELECT jsonb_build_object(
        'id', i.id, 'inv_fin_year', i.inv_fin_year, 'inv_no', i.inv_no,
        'gr_id', i.gr_id, 'gr_no', i.gr_no, 'customer_id', i.customer_id,
        'customer_name', i.customer_name, 'inv_date', i.inv_date,
        'labour', i.labour, 'tax_amount', i.tax_amount, 'total', i.total,
        'discount', i.discount, 'one_time_charge', i.one_time_charge,
        'is_auto_generated', i.is_auto_generated, 'pricing_mode', i.pricing_mode,
        'duration_mode', COALESCE(i.duration_mode, 'legacy'),
        'notes', i.notes, 'created_by', i.created_by,
        'grn_pricing_mode', (SELECT gr.pricing_mode FROM goodsreceived gr WHERE gr.id = i.gr_id)
    ) || CASE WHEN auth.jwt()->>'role' = 'service_role'
                OR warehouse_security.active_role() IN ('admin','supervisor','staff')
        THEN jsonb_build_object(
            'discount_reason', i.discount_reason,
            'discount_set_by', i.discount_set_by,
            'discount_set_by_name', COALESCE(
                (SELECT h.changed_by_name FROM invoice_discount_history h
                  WHERE h.invoice_id = i.id AND h.changed_at = i.discount_set_at ORDER BY h.id DESC LIMIT 1),
                (SELECT p.name FROM user_profiles p WHERE p.id = i.discount_set_by)),
            'discount_set_at', i.discount_set_at,
            'zero_charge_reason', i.zero_charge_reason,
            'zero_charge_set_by', i.zero_charge_set_by,
            'zero_charge_set_by_name', COALESCE(
                (SELECT h.changed_by_name FROM invoice_zero_charge_history h
                  WHERE h.invoice_id = i.id AND h.changed_at = i.zero_charge_set_at ORDER BY h.id DESC LIMIT 1),
                (SELECT p.name FROM user_profiles p WHERE p.id = i.zero_charge_set_by)),
            'zero_charge_set_at', i.zero_charge_set_at)
        ELSE '{}'::jsonb END
    INTO v_invoice_header FROM invoice i WHERE i.id = p_invoice_id AND i.deleted_at IS NULL;

    IF v_invoice_header IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'Invoice not found');
    END IF;

    SELECT jsonb_agg(
        jsonb_build_object(
            'id', it.id,
            'invoice_id', it.invoice_id,
            'disp_trl_id', it.disp_trl_id,
            'duration', it.duration,
            'no_of_days', it.no_of_days,
            'charge', it.charge,
            'tax', it.tax,
            'labour_rate', it.labour_rate,
            'item_name', gt.item_name,
            'grn_item_id', gt.id,
            'grn_date', gr.date,
            'qty', dt.disp_qty,
            'dispatch_no', d.disp_no,
            'dispatch_date', d.disp_date,
            'weight', gt.weight,
            'grn_original_qty', gt.qty,
            'package_mark', gt.package_mark,
            'item_id', gt.item_id,
            'dispatch_id', d.id,
            'rack', gt.rack
        ) ORDER BY gt.item_name, d.disp_date, uuid_extract_timestamp(dt.id), dt.id
    ) INTO v_invoice_items
    FROM invoice_trl it
    JOIN dispatch_trl dt ON it.disp_trl_id = dt.id
    JOIN dispatch d ON dt.disp_id = d.id
    JOIN goodsreceived_trl gt ON dt.gr_trl_id = gt.id
    JOIN goodsreceived gr ON gr.id = gt.gr_id
    WHERE it.invoice_id = p_invoice_id;

    RETURN jsonb_build_object('success', true, 'invoice', v_invoice_header, 'items', COALESCE(v_invoice_items, '[]'::jsonb));
EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('success', false, 'error', SQLERRM);
END;
$$;

CREATE OR REPLACE FUNCTION public.get_invoice_range_for_print(start_inv_no_str text, end_inv_no_str text, inv_fin_year integer DEFAULT NULL::integer, limit_count integer DEFAULT 100) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $_$
DECLARE
    v_result jsonb;
    start_inv_no integer;
    end_inv_no integer;
    target_fin_year integer;
BEGIN
    start_inv_no := CASE
        WHEN start_inv_no_str ~ '^[0-9]+$' THEN start_inv_no_str::integer
        ELSE REGEXP_REPLACE(start_inv_no_str, '[^0-9]', '', 'g')::integer
    END;

    end_inv_no := CASE
        WHEN end_inv_no_str ~ '^[0-9]+$' THEN end_inv_no_str::integer
        ELSE REGEXP_REPLACE(end_inv_no_str, '[^0-9]', '', 'g')::integer
    END;

    target_fin_year := COALESCE(get_invoice_range_for_print.inv_fin_year, EXTRACT(YEAR FROM CURRENT_DATE)::integer);

    WITH invoice_data AS (
        SELECT
            i.id as invoice_id,
            i.inv_fin_year,
            i.inv_no,
            'INV' || LPAD(i.inv_no::text, 3, '0') as inv_no_str,
            i.gr_id,
            i.gr_no,
            i.customer_id,
            i.customer_name,
            i.inv_name,
            TO_CHAR(i.inv_date, 'YYYY-MM-DD') as formatted_inv_date,
            COALESCE(i.one_time_charge, false) as one_time_charge,
            COALESCE(i.duration_mode, 'legacy') as duration_mode,
            COALESCE(i.labour, 0)::double precision as labour,
            COALESCE(i.tax_amount, 0)::double precision as tax_amount,
            COALESCE(i.total, 0)::double precision as total,
            COALESCE(i.discount, 0)::double precision as discount,
            i.created_by
        FROM invoice i
        WHERE i.inv_no >= start_inv_no
          AND i.inv_no <= end_inv_no
          AND (get_invoice_range_for_print.inv_fin_year IS NULL OR i.inv_fin_year = target_fin_year)
          AND i.deleted_at IS NULL
        ORDER BY i.inv_fin_year, i.inv_no
        LIMIT get_invoice_range_for_print.limit_count
    ),
    invoice_with_customer AS (
        SELECT id.*, c.address, c.city, c.mobile, c.gst as gstin
        FROM invoice_data id
        LEFT JOIN customers c ON c.id = id.customer_id::uuid
    ),
    invoice_with_items AS (
        SELECT
            iwc.*,
            jsonb_agg(
                jsonb_build_object(
                    'id', it.id::text,
                    'invoice_id', it.invoice_id::text,
                    'duration_mode', iwc.duration_mode,
                    'charge', COALESCE(it.charge, 0),
                    'dispatches_items_disp_qty', COALESCE(dt.disp_qty, 0),
                    'dispatches_items_id', dt.id::text,
                    'dispatches_customer_id', d.customer_id::text,
                    'dispatches_customer_name', d.customer_name,
                    'dispatches_date', TO_CHAR(d.disp_date, 'YYYY-MM-DD'),
                    'dispatches_id', d.id::text,
                    'dispatches_image_url', d.disp_image_url,
                    'dispatches_no', d.disp_no,
                    'dispatches_note', d.note,
                    'dispatches_registration', d.registration,
                    'dispatches_supervisor_id', d.supervisor_id::text,
                    'dispatches_supervisor_name', d.supervisor_name,
                    'duration', COALESCE(it.duration, 0),
                    'grn_items_id', grt.id::text,
                    'grn_items_image_url', grt.trl_img_url,
                    'grn_items_item_id', grt.item_id::text,
                    'grn_items_item_name', grt.item_name,
                    'grn_items_package_mark', grt.package_mark,
                    'grn_items_packaging', grt.packaging,
                    'grn_items_quantity', COALESCE(grt.qty, 0),
                    'grn_items_rack', grt.rack,
                    'grn_items_stock', COALESCE(grt.stock, 0),
                    'grn_items_weight', COALESCE(grt.weight, 0),
                    'grns_customer_id', gr.customer_id::text,
                    'grns_customer_name', gr.customer_name,
                    'grns_date', TO_CHAR(gr.date, 'YYYY-MM-DD'),
                    'grns_gr_no', gr.gr_no,
                    'grns_id', gr.id::text,
                    'grns_image_url', gr.gr_image_url,
                    'grns_invoiced', COALESCE(gr.invoiced, false),
                    'grns_leon', COALESCE(gr.leon, false),
                    'grns_note', gr.note,
                    'grns_out_of_stock', COALESCE(gr.out_of_stock, false),
                    'grns_registration', gr.registration,
                    'grns_sender_id', gr.sender_id::text,
                    'grns_sender_name', gr.sender_name,
                    'grns_supervisor_id', gr.supervisor_id::text,
                    'grns_supervisor_name', gr.supervisor_name,
                    'inv_fin_year', iwc.inv_fin_year,
                    'inv_no', iwc.inv_no,
                    'no_of_days', COALESCE(it.no_of_days, 0),
                    'tax', COALESCE(it.tax, 0),
                    'inv_item_charge', COALESCE(it.charge, 0),
                    'pricing_mode', gr.pricing_mode,
                    'storage_amount', CASE WHEN gr.pricing_mode = 'ONE_TIME'
                        THEN round(COALESCE(it.charge, 0) * dt.disp_qty, 2)
                        ELSE round(COALESCE(it.charge, 0) * dt.disp_qty * COALESCE(it.duration, 1), 2) END,
                    'labour_amount', CASE WHEN gr.pricing_mode = 'ONE_TIME'
                        THEN 0::numeric
                        ELSE round(COALESCE(it.labour_rate, 0) * dt.disp_qty, 2) END
                ) ORDER BY uuid_extract_timestamp(it.id), it.id
            ) FILTER (WHERE it.id IS NOT NULL) as trl_data,
            SUM(COALESCE(it.charge, 0))::double precision as total_inv_item_charges,
            SUM(COALESCE(dt.disp_qty, 0))::integer as total_disp_qty,
            SUM(COALESCE(grt.qty, 0))::integer as total_gr_qty
        FROM invoice_with_customer iwc
        LEFT JOIN invoice_trl it ON it.invoice_id = iwc.invoice_id
        LEFT JOIN dispatch_trl dt ON dt.id = it.disp_trl_id
        LEFT JOIN dispatch d ON d.id = dt.disp_id
        LEFT JOIN goodsreceived_trl grt ON grt.id = dt.gr_trl_id
        LEFT JOIN goodsreceived gr ON gr.id = grt.gr_id
        GROUP BY
            iwc.invoice_id, iwc.inv_fin_year, iwc.inv_no, iwc.inv_no_str, iwc.gr_id, iwc.gr_no,
            iwc.customer_id, iwc.customer_name, iwc.inv_name, iwc.formatted_inv_date,
            iwc.one_time_charge, iwc.duration_mode, iwc.labour, iwc.tax_amount, iwc.total, iwc.discount,
            iwc.address, iwc.city, iwc.mobile, iwc.gstin, iwc.created_by
    ),
    final_result AS (
        SELECT jsonb_agg(
            jsonb_build_object(
                'id', iwi.invoice_id,
                'created_by', iwi.created_by,
                'customer_id', iwi.customer_id,
                'customer_name', iwi.customer_name,
                'gr_id', iwi.gr_id,
                'gr_no', iwi.gr_no,
                'inv_date', iwi.formatted_inv_date,
                'inv_fin_year', iwi.inv_fin_year,
                'inv_name', iwi.inv_name,
                'inv_no', iwi.inv_no,
                'inv_no_str', iwi.inv_no_str,
                'duration_mode', iwi.duration_mode,
                'labour', iwi.labour,
                'discount', iwi.discount,
                'one_time_charge', iwi.one_time_charge,
                'tax_amount', iwi.tax_amount,
                'total', iwi.total,
                'address', iwi.address,
                'city', iwi.city,
                'mobile', iwi.mobile,
                'gstin', iwi.gstin,
                'trl', COALESCE(iwi.trl_data, '[]'::jsonb),
                'inwords', convert_number_to_words(COALESCE(iwi.total, 0)::integer),
                'total_inv_item_charges', COALESCE(iwi.total_inv_item_charges, 0),
                'total_disp_qty', COALESCE(iwi.total_disp_qty, 0),
                'total_gr_qty', COALESCE(iwi.total_gr_qty, 0),
                'total_labour_amount', COALESCE(iwi.labour * iwi.total_disp_qty, 0)
            ) ORDER BY iwi.inv_fin_year, iwi.inv_no
        ) as data
        FROM invoice_with_items iwi
    )
    SELECT COALESCE(data, '[]'::jsonb) INTO v_result FROM final_result;

    RETURN utils.success_response(v_result, NULL);
END;
$_$;

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
      COALESCE(dt.disp_qty, 0)::numeric AS dispatch_qty,
      ROUND(amount.base * COALESCE(it.tax, 0)::numeric / 100, 2) AS tax_amount,
      amount.base + ROUND(amount.base * COALESCE(it.tax, 0)::numeric / 100, 2) AS total_amount,
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
    CROSS JOIN LATERAL (
      SELECT CASE WHEN gr.pricing_mode = 'ONE_TIME'
        THEN ROUND(COALESCE(it.charge, 0)::numeric * COALESCE(dt.disp_qty, 0)::numeric, 2)
        ELSE ROUND(COALESCE(it.charge, 0)::numeric * COALESCE(dt.disp_qty, 0)::numeric * COALESCE(it.duration, 1)::numeric, 2)
             + ROUND(COALESCE(it.labour_rate, 0)::numeric * COALESCE(dt.disp_qty, 0)::numeric, 2)
        END AS base
    ) AS amount
    WHERE it.invoice_id = p_invoice_id
  ) AS line;

  RETURN utils.success_response(
    jsonb_build_object('items', v_items, 'summary', v_summary),
    'Invoice items retrieved successfully'
  );
END;
$$;

-- Fix 3: a total order for paged and listed results
CREATE OR REPLACE FUNCTION public.search_customer_items_for_order(p_search_query text DEFAULT ''::text, p_customer_id uuid DEFAULT NULL::uuid, p_search_type text DEFAULT 'auto'::text, p_stock_filter_min integer DEFAULT 1, p_page_size integer DEFAULT 50, p_offset integer DEFAULT 0, p_catalog_id uuid DEFAULT NULL::uuid, p_weight_min numeric DEFAULT NULL::numeric, p_weight_max numeric DEFAULT NULL::numeric) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'extensions', 'utils', 'pg_temp'
    AS $_$
DECLARE
    v_search_type_final TEXT;
    v_weight_min_final INTEGER;
    v_weight_max_final INTEGER;
    v_accessible_customers UUID[];
    v_is_admin BOOLEAN;
    v_result JSONB;
BEGIN
  PERFORM warehouse_security.authorize_rpc('search_customer_items_for_order',jsonb_build_object('p_customer_id',p_customer_id));
    v_is_admin := is_admin_or_supervisor();

    IF v_is_admin THEN
        IF p_customer_id IS NOT NULL THEN
            v_accessible_customers := ARRAY[p_customer_id];
        ELSE
            SELECT ARRAY(SELECT id FROM customers WHERE active = true AND deleted_at IS NULL) INTO v_accessible_customers;
        END IF;
    ELSE
        SELECT user_accessible_customers() INTO v_accessible_customers;

        IF v_accessible_customers IS NULL OR array_length(v_accessible_customers, 1) IS NULL THEN
            RETURN jsonb_build_object('items', '[]'::jsonb, 'total_count', 0, 'success', false, 'error', 'No accessible customers');
        END IF;

        IF p_customer_id IS NOT NULL THEN
            IF NOT (p_customer_id = ANY(v_accessible_customers)) THEN
                RETURN jsonb_build_object('items', '[]'::jsonb, 'total_count', 0, 'success', false, 'error', 'Access denied to customer');
            END IF;
            v_accessible_customers := ARRAY[p_customer_id];
        END IF;
    END IF;

    IF p_search_type = 'weight_range' OR (p_weight_min IS NOT NULL AND p_weight_max IS NOT NULL) THEN
        v_search_type_final := 'weight_range';
        v_weight_min_final := COALESCE(p_weight_min, 0)::INTEGER;
        v_weight_max_final := COALESCE(p_weight_max, 999999)::INTEGER;
    ELSIF p_search_type = 'auto' AND p_search_query ~ '^[0-9]+\.?[0-9]*-[0-9]+\.?[0-9]*$' THEN
        v_search_type_final := 'weight_range';
        v_weight_min_final := round(split_part(p_search_query, '-', 1)::numeric)::INTEGER;
        v_weight_max_final := round(split_part(p_search_query, '-', 2)::numeric)::INTEGER;
    ELSIF p_search_type = 'weight' OR (p_search_type = 'auto' AND p_search_query ~ '^[0-9]+\.?[0-9]*$') THEN
        v_search_type_final := 'weight_exact';
        v_weight_min_final := round(COALESCE(p_weight_min, p_search_query::numeric))::INTEGER;
        v_weight_max_final := v_weight_min_final;
    ELSIF p_search_query IS NULL OR trim(p_search_query) = '' THEN
        v_search_type_final := 'all';
    ELSE
        v_search_type_final := 'text';
    END IF;

    SELECT jsonb_build_object(
        'items', COALESCE(
            (SELECT jsonb_agg(item_data)
            FROM (
                SELECT jsonb_build_object(
                    'id', grt.id,
                    'grn_id', grt.gr_id,
                    'item_id', grt.item_id,
                    'item_name', grt.item_name,
                    'package_mark', grt.package_mark,
                    'packaging', grt.packaging,
                    'rack', grt.rack,
                    'qty', grt.qty,
                    'stock', grt.stock,
                    'weight', grt.weight,
                    'trl_img_url', grt.trl_img_url,
                    'grn_date', gr.date,
                    'gr_no', gr.gr_no,
                    'customer_id', gr.customer_id,
                    'customer_name', c.name,
                    'master_item_id', i.id,
                    'master_item_name', i.name,
                    'match_type', CASE
                        WHEN v_search_type_final = 'weight_exact' AND grt.weight = v_weight_min_final THEN 'weight_exact'
                        WHEN v_search_type_final = 'weight_range' AND grt.weight >= v_weight_min_final AND grt.weight <= v_weight_max_final THEN 'weight_range'
                        WHEN grt.item_name ILIKE '%' || p_search_query || '%' THEN 'item_name'
                        WHEN grt.package_mark ILIKE '%' || p_search_query || '%' THEN 'package_mark'
                        WHEN grt.packaging ILIKE '%' || p_search_query || '%' THEN 'packaging'
                        WHEN gr.gr_no ILIKE '%' || p_search_query || '%' THEN 'gr_no'
                        WHEN i.name IS NOT NULL AND i.name ILIKE '%' || p_search_query || '%' THEN 'master_item_name'
                        ELSE 'match'
                    END
                ) as item_data
                FROM goodsreceived_trl grt
                JOIN goodsreceived gr ON grt.gr_id = gr.id
                JOIN customers c ON gr.customer_id = c.id
                LEFT JOIN items i ON grt.item_id = i.id
                WHERE gr.customer_id = ANY(v_accessible_customers)
                AND gr.deleted_at IS NULL
                AND grt.stock >= p_stock_filter_min
                AND (p_customer_id IS NULL OR gr.customer_id = p_customer_id)
                AND (p_catalog_id IS NULL OR i.id = p_catalog_id)
                AND (
                    v_search_type_final = 'all'
                    OR (v_search_type_final = 'weight_exact' AND grt.weight = v_weight_min_final)
                    OR (v_search_type_final = 'weight_range' AND grt.weight >= v_weight_min_final AND grt.weight <= v_weight_max_final)
                    OR (v_search_type_final = 'text' AND (
                        grt.item_name ILIKE '%' || p_search_query || '%'
                        OR grt.package_mark ILIKE '%' || p_search_query || '%'
                        OR grt.packaging ILIKE '%' || p_search_query || '%'
                        OR gr.gr_no ILIKE '%' || p_search_query || '%'
                        OR c.name ILIKE '%' || p_search_query || '%'
                        OR (i.name IS NOT NULL AND i.name ILIKE '%' || p_search_query || '%')
                    ))
                )
                ORDER BY
                    CASE
                        WHEN v_search_type_final = 'weight_exact' AND grt.weight = v_weight_min_final THEN 1
                        WHEN v_search_type_final = 'weight_range' AND grt.weight >= v_weight_min_final AND grt.weight <= v_weight_max_final THEN 2
                        WHEN grt.item_name ILIKE '%' || p_search_query || '%' THEN 3
                        WHEN grt.package_mark ILIKE '%' || p_search_query || '%' THEN 4
                        WHEN grt.packaging ILIKE '%' || p_search_query || '%' THEN 5
                        WHEN gr.gr_no ILIKE '%' || p_search_query || '%' THEN 6
                        WHEN i.name IS NOT NULL AND i.name ILIKE '%' || p_search_query || '%' THEN 7
                        ELSE 8
                    END,
                    grt.weight,
                    grt.item_name,
                    gr.gr_no,
                    grt.id
                LIMIT p_page_size
                OFFSET p_offset
            ) ordered_items),
            '[]'::jsonb
        ),
        'total_count', (
            SELECT COUNT(*)
            FROM goodsreceived_trl grt
            JOIN goodsreceived gr ON grt.gr_id = gr.id
            JOIN customers c ON gr.customer_id = c.id
            LEFT JOIN items i ON grt.item_id = i.id
            WHERE gr.customer_id = ANY(v_accessible_customers)
            AND gr.deleted_at IS NULL
            AND grt.stock >= p_stock_filter_min
            AND (p_customer_id IS NULL OR gr.customer_id = p_customer_id)
            AND (p_catalog_id IS NULL OR i.id = p_catalog_id)
            AND (
                v_search_type_final = 'all'
                OR (v_search_type_final = 'weight_exact' AND grt.weight = v_weight_min_final)
                OR (v_search_type_final = 'weight_range' AND grt.weight >= v_weight_min_final AND grt.weight <= v_weight_max_final)
                OR (v_search_type_final = 'text' AND (
                    grt.item_name ILIKE '%' || p_search_query || '%'
                    OR grt.package_mark ILIKE '%' || p_search_query || '%'
                    OR grt.packaging ILIKE '%' || p_search_query || '%'
                    OR gr.gr_no ILIKE '%' || p_search_query || '%'
                    OR c.name ILIKE '%' || p_search_query || '%'
                    OR (i.name IS NOT NULL AND i.name ILIKE '%' || p_search_query || '%')
                ))
            )
        )
    ) INTO v_result;

    RETURN v_result;
END;
$_$;

CREATE OR REPLACE FUNCTION public.get_stock_aging_report(p_customer_uuid uuid DEFAULT NULL::uuid, p_aging_buckets integer[] DEFAULT ARRAY[120, 240, 364]) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'extensions', 'utils', 'pg_temp'
    SET jit TO 'off'
    AS $$
DECLARE
    v_user_id uuid;
    v_user_role text;
    v_user_customer_ids uuid[];
    v_bucket_1 integer;
    v_bucket_2 integer;
    v_bucket_3 integer;
    v_result jsonb;
    v_summary jsonb;
    v_by_bucket jsonb;
    v_items jsonb;
    v_by_customer jsonb;
BEGIN
  PERFORM warehouse_security.authorize_rpc('get_stock_aging_report',jsonb_build_object('p_customer_uuid',p_customer_uuid));
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
                        'total_items', 0,
                        'total_quantity', 0,
                        'oldest_stock_days', 0
                    ),
                    'by_bucket', '{}'::jsonb,
                    'items', '[]'::jsonb
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

    -- Set aging bucket thresholds
    v_bucket_1 := COALESCE(p_aging_buckets[1], 120);
    v_bucket_2 := COALESCE(p_aging_buckets[2], 240);
    v_bucket_3 := COALESCE(p_aging_buckets[3], 364);

    -- Single customer view
    IF p_customer_uuid IS NOT NULL THEN
        WITH stock_items AS (
            SELECT
                grt.id as grn_item_id,
                gr.id as grn_id,
                gr.gr_no,
                gr.customer_id,
                gr.date as grn_date,
                grt.item_name,
                grt.packaging,
                grt.stock as current_stock,
                grt.qty as original_qty,
                grt.weight,
                grt.rack,
                grt.package_mark,
                (warehouse_security.business_date(now()) - warehouse_security.business_date(gr.date)) as aging_days,
                CASE
                    WHEN (warehouse_security.business_date(now()) - warehouse_security.business_date(gr.date)) <= v_bucket_1 THEN '0-' || v_bucket_1::text
                    WHEN (warehouse_security.business_date(now()) - warehouse_security.business_date(gr.date)) <= v_bucket_2 THEN (v_bucket_1 + 1)::text || '-' || v_bucket_2::text
                    WHEN (warehouse_security.business_date(now()) - warehouse_security.business_date(gr.date)) <= v_bucket_3 THEN (v_bucket_2 + 1)::text || '-' || v_bucket_3::text
                    ELSE v_bucket_3::text || '+'
                END as aging_bucket
            FROM goodsreceived_trl grt
            JOIN goodsreceived gr ON grt.gr_id = gr.id
            WHERE gr.customer_id = p_customer_uuid
                AND gr.deleted_at IS NULL
                AND grt.stock > 0
        ),
        dispatch_info AS (
            SELECT
                dt.gr_trl_id,
                SUM(dt.disp_qty) as total_dispatched,
                COUNT(DISTINCT d.id) as dispatch_count,
                MAX(d.disp_date) as last_dispatch_date
            FROM dispatch_trl dt
            JOIN dispatch d ON dt.disp_id = d.id
            WHERE d.deleted_at IS NULL
            GROUP BY dt.gr_trl_id
        ),
        items_with_dispatch AS (
            SELECT
                si.*,
                COALESCE(di.total_dispatched, 0) as total_dispatched,
                COALESCE(di.dispatch_count, 0) as dispatch_count,
                di.last_dispatch_date,
                CASE WHEN di.last_dispatch_date IS NOT NULL
                    THEN (warehouse_security.business_date(now()) - warehouse_security.business_date(di.last_dispatch_date))
                    ELSE NULL
                END as days_since_last_dispatch,
                CASE WHEN COALESCE(di.dispatch_count, 0) > 0
                    THEN ((warehouse_security.business_date(di.last_dispatch_date) - warehouse_security.business_date(si.grn_date)) / di.dispatch_count)
                    ELSE NULL
                END as avg_days_between_dispatches
            FROM stock_items si
            LEFT JOIN dispatch_info di ON si.grn_item_id = di.gr_trl_id
        )
        SELECT
            jsonb_build_object(
                'total_items', COUNT(*),
                'total_quantity', COALESCE(SUM(current_stock), 0),
                'total_weight_kg', COALESCE(SUM(weight::numeric * current_stock), 0),
                'oldest_stock_days', COALESCE(MAX(aging_days), 0),
                'average_age_days', COALESCE(ROUND(AVG(aging_days)), 0),
                'items_over_365_days', COUNT(*) FILTER (WHERE aging_days > 365),
                'qty_over_365_days', COALESCE(SUM(current_stock) FILTER (WHERE aging_days > 365), 0),
                'avg_dispatch_velocity_days', COALESCE(ROUND(AVG(avg_days_between_dispatches)), NULL),
                'items_no_recent_dispatch', COUNT(*) FILTER (WHERE days_since_last_dispatch > 30 OR dispatch_count = 0)
            ),
            jsonb_build_object(
                '0-' || v_bucket_1::text, jsonb_build_object(
                    'item_count', COUNT(*) FILTER (WHERE aging_bucket = '0-' || v_bucket_1::text),
                    'total_quantity', COALESCE(SUM(current_stock) FILTER (WHERE aging_bucket = '0-' || v_bucket_1::text), 0),
                    'total_weight', COALESCE(SUM(weight::numeric * current_stock) FILTER (WHERE aging_bucket = '0-' || v_bucket_1::text), 0),
                    'percentage', CASE WHEN COUNT(*) > 0
                        THEN ROUND(COUNT(*) FILTER (WHERE aging_bucket = '0-' || v_bucket_1::text) * 100.0 / COUNT(*), 1)
                        ELSE 0
                    END
                ),
                (v_bucket_1 + 1)::text || '-' || v_bucket_2::text, jsonb_build_object(
                    'item_count', COUNT(*) FILTER (WHERE aging_bucket = (v_bucket_1 + 1)::text || '-' || v_bucket_2::text),
                    'total_quantity', COALESCE(SUM(current_stock) FILTER (WHERE aging_bucket = (v_bucket_1 + 1)::text || '-' || v_bucket_2::text), 0),
                    'total_weight', COALESCE(SUM(weight::numeric * current_stock) FILTER (WHERE aging_bucket = (v_bucket_1 + 1)::text || '-' || v_bucket_2::text), 0),
                    'percentage', CASE WHEN COUNT(*) > 0
                        THEN ROUND(COUNT(*) FILTER (WHERE aging_bucket = (v_bucket_1 + 1)::text || '-' || v_bucket_2::text) * 100.0 / COUNT(*), 1)
                        ELSE 0
                    END
                ),
                (v_bucket_2 + 1)::text || '-' || v_bucket_3::text, jsonb_build_object(
                    'item_count', COUNT(*) FILTER (WHERE aging_bucket = (v_bucket_2 + 1)::text || '-' || v_bucket_3::text),
                    'total_quantity', COALESCE(SUM(current_stock) FILTER (WHERE aging_bucket = (v_bucket_2 + 1)::text || '-' || v_bucket_3::text), 0),
                    'total_weight', COALESCE(SUM(weight::numeric * current_stock) FILTER (WHERE aging_bucket = (v_bucket_2 + 1)::text || '-' || v_bucket_3::text), 0),
                    'percentage', CASE WHEN COUNT(*) > 0
                        THEN ROUND(COUNT(*) FILTER (WHERE aging_bucket = (v_bucket_2 + 1)::text || '-' || v_bucket_3::text) * 100.0 / COUNT(*), 1)
                        ELSE 0
                    END
                ),
                v_bucket_3::text || '+', jsonb_build_object(
                    'item_count', COUNT(*) FILTER (WHERE aging_bucket = v_bucket_3::text || '+'),
                    'total_quantity', COALESCE(SUM(current_stock) FILTER (WHERE aging_bucket = v_bucket_3::text || '+'), 0),
                    'total_weight', COALESCE(SUM(weight::numeric * current_stock) FILTER (WHERE aging_bucket = v_bucket_3::text || '+'), 0),
                    'percentage', CASE WHEN COUNT(*) > 0
                        THEN ROUND(COUNT(*) FILTER (WHERE aging_bucket = v_bucket_3::text || '+') * 100.0 / COUNT(*), 1)
                        ELSE 0
                    END
                )
            ),
            COALESCE(jsonb_agg(
                jsonb_build_object(
                    'grn_id', grn_id,
                    'gr_no', gr_no,
                    'item_name', item_name,
                    'packaging', packaging,
                    'current_stock', current_stock,
                    'original_qty', original_qty,
                    'weight', weight,
                    'rack', rack,
                    'package_mark', package_mark,
                    'grn_date', grn_date,
                    'aging_days', aging_days,
                    'aging_bucket', aging_bucket,
                    'dispatch_info', jsonb_build_object(
                        'total_dispatched', total_dispatched,
                        'dispatch_count', dispatch_count,
                        'last_dispatch_date', last_dispatch_date,
                        'days_since_last_dispatch', days_since_last_dispatch,
                        'avg_days_between_dispatches', avg_days_between_dispatches
                    )
                ) ORDER BY aging_days DESC, gr_no, grn_item_id
            ), '[]'::jsonb)
        INTO v_summary, v_by_bucket, v_items
        FROM items_with_dispatch;

        v_result := jsonb_build_object(
            'success', true,
            'data', jsonb_build_object(
                'summary', v_summary,
                'by_bucket', v_by_bucket,
                'items', v_items
            ),
            'metadata', jsonb_build_object(
                'retrieved_at', NOW(),
                'customer_id', p_customer_uuid,
                'aging_buckets', p_aging_buckets
            )
        );

    -- All customers view (filtered by accessible customers for non-staff)
    ELSE
        WITH stock_items AS (
            SELECT
                grt.id as grn_item_id,
                gr.id as grn_id,
                gr.customer_id,
                c.name as customer_name,
                gr.date as grn_date,
                grt.stock as current_stock,
                grt.weight,
                (warehouse_security.business_date(now()) - warehouse_security.business_date(gr.date)) as aging_days,
                CASE
                    WHEN (warehouse_security.business_date(now()) - warehouse_security.business_date(gr.date)) <= v_bucket_1 THEN '0-' || v_bucket_1::text
                    WHEN (warehouse_security.business_date(now()) - warehouse_security.business_date(gr.date)) <= v_bucket_2 THEN (v_bucket_1 + 1)::text || '-' || v_bucket_2::text
                    WHEN (warehouse_security.business_date(now()) - warehouse_security.business_date(gr.date)) <= v_bucket_3 THEN (v_bucket_2 + 1)::text || '-' || v_bucket_3::text
                    ELSE v_bucket_3::text || '+'
                END as aging_bucket
            FROM goodsreceived_trl grt
            JOIN goodsreceived gr ON grt.gr_id = gr.id
            JOIN customers c ON gr.customer_id = c.id
            WHERE gr.deleted_at IS NULL
                AND grt.stock > 0
                AND (v_user_role IN ('admin', 'supervisor', 'staff') OR gr.customer_id = ANY(v_user_customer_ids))
        ),
        customer_aggregates AS (
            SELECT
                customer_id,
                customer_name,
                SUM(current_stock) as total_stock,
                ROUND(AVG(aging_days)) as average_age_days,
                MAX(aging_days) as oldest_stock_days,
                COUNT(*) FILTER (WHERE aging_days > 365) as items_over_365_days,
                SUM(current_stock) FILTER (WHERE aging_bucket = '0-' || v_bucket_1::text) as bucket_1_qty,
                SUM(current_stock) FILTER (WHERE aging_bucket = (v_bucket_1 + 1)::text || '-' || v_bucket_2::text) as bucket_2_qty,
                SUM(current_stock) FILTER (WHERE aging_bucket = (v_bucket_2 + 1)::text || '-' || v_bucket_3::text) as bucket_3_qty,
                SUM(current_stock) FILTER (WHERE aging_bucket = v_bucket_3::text || '+') as bucket_4_qty
            FROM stock_items
            GROUP BY customer_id, customer_name
        )
        SELECT
            jsonb_build_object(
                'total_customers', (SELECT COUNT(DISTINCT customer_id) FROM stock_items),
                'total_items', (SELECT COUNT(*) FROM stock_items),
                'total_quantity', COALESCE((SELECT SUM(current_stock) FROM stock_items), 0),
                'oldest_stock_days', COALESCE((SELECT MAX(aging_days) FROM stock_items), 0),
                'average_age_days', COALESCE((SELECT ROUND(AVG(aging_days)) FROM stock_items), 0),
                'items_over_365_days', (SELECT COUNT(*) FROM stock_items WHERE aging_days > 365),
                'qty_over_365_days', COALESCE((SELECT SUM(current_stock) FROM stock_items WHERE aging_days > 365), 0)
            ),
            jsonb_build_object(
                '0-' || v_bucket_1::text, jsonb_build_object(
                    'item_count', (SELECT COUNT(*) FROM stock_items WHERE aging_bucket = '0-' || v_bucket_1::text),
                    'total_quantity', COALESCE((SELECT SUM(current_stock) FROM stock_items WHERE aging_bucket = '0-' || v_bucket_1::text), 0),
                    'percentage', CASE WHEN (SELECT COUNT(*) FROM stock_items) > 0
                        THEN ROUND((SELECT COUNT(*) FROM stock_items WHERE aging_bucket = '0-' || v_bucket_1::text) * 100.0 / (SELECT COUNT(*) FROM stock_items), 1)
                        ELSE 0
                    END
                ),
                (v_bucket_1 + 1)::text || '-' || v_bucket_2::text, jsonb_build_object(
                    'item_count', (SELECT COUNT(*) FROM stock_items WHERE aging_bucket = (v_bucket_1 + 1)::text || '-' || v_bucket_2::text),
                    'total_quantity', COALESCE((SELECT SUM(current_stock) FROM stock_items WHERE aging_bucket = (v_bucket_1 + 1)::text || '-' || v_bucket_2::text), 0),
                    'percentage', CASE WHEN (SELECT COUNT(*) FROM stock_items) > 0
                        THEN ROUND((SELECT COUNT(*) FROM stock_items WHERE aging_bucket = (v_bucket_1 + 1)::text || '-' || v_bucket_2::text) * 100.0 / (SELECT COUNT(*) FROM stock_items), 1)
                        ELSE 0
                    END
                ),
                (v_bucket_2 + 1)::text || '-' || v_bucket_3::text, jsonb_build_object(
                    'item_count', (SELECT COUNT(*) FROM stock_items WHERE aging_bucket = (v_bucket_2 + 1)::text || '-' || v_bucket_3::text),
                    'total_quantity', COALESCE((SELECT SUM(current_stock) FROM stock_items WHERE aging_bucket = (v_bucket_2 + 1)::text || '-' || v_bucket_3::text), 0),
                    'percentage', CASE WHEN (SELECT COUNT(*) FROM stock_items) > 0
                        THEN ROUND((SELECT COUNT(*) FROM stock_items WHERE aging_bucket = (v_bucket_2 + 1)::text || '-' || v_bucket_3::text) * 100.0 / (SELECT COUNT(*) FROM stock_items), 1)
                        ELSE 0
                    END
                ),
                v_bucket_3::text || '+', jsonb_build_object(
                    'item_count', (SELECT COUNT(*) FROM stock_items WHERE aging_bucket = v_bucket_3::text || '+'),
                    'total_quantity', COALESCE((SELECT SUM(current_stock) FROM stock_items WHERE aging_bucket = v_bucket_3::text || '+'), 0),
                    'percentage', CASE WHEN (SELECT COUNT(*) FROM stock_items) > 0
                        THEN ROUND((SELECT COUNT(*) FROM stock_items WHERE aging_bucket = v_bucket_3::text || '+') * 100.0 / (SELECT COUNT(*) FROM stock_items), 1)
                        ELSE 0
                    END
                )
            ),
            COALESCE((
                SELECT jsonb_agg(
                    jsonb_build_object(
                        'customer_id', customer_id,
                        'customer_name', customer_name,
                        'total_stock', total_stock,
                        'average_age_days', average_age_days,
                        'oldest_stock_days', oldest_stock_days,
                        'items_over_365_days', items_over_365_days,
                        'aging_distribution', jsonb_build_object(
                            '0-' || v_bucket_1::text, COALESCE(bucket_1_qty, 0),
                            (v_bucket_1 + 1)::text || '-' || v_bucket_2::text, COALESCE(bucket_2_qty, 0),
                            (v_bucket_2 + 1)::text || '-' || v_bucket_3::text, COALESCE(bucket_3_qty, 0),
                            v_bucket_3::text || '+', COALESCE(bucket_4_qty, 0)
                        )
                    ) ORDER BY average_age_days DESC, customer_name, customer_id
                )
                FROM customer_aggregates
            ), '[]'::jsonb)
        INTO v_summary, v_by_bucket, v_by_customer;

        v_result := jsonb_build_object(
            'success', true,
            'data', jsonb_build_object(
                'summary', v_summary,
                'by_bucket', v_by_bucket,
                'by_customer', v_by_customer
            ),
            'metadata', jsonb_build_object(
                'retrieved_at', NOW(),
                'aging_buckets', p_aging_buckets
            )
        );
    END IF;

    RETURN v_result;

EXCEPTION
    WHEN OTHERS THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'Failed to retrieve stock aging report: ' || SQLERRM,
            'error_code', SQLSTATE
        );
END;
$$;

CREATE OR REPLACE FUNCTION public.user_accessible_customers() RETURNS uuid[]
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE
    v_auth_uid uuid;
    v_user_profile_id uuid;
    v_role user_role;
BEGIN
    -- Cache auth.uid() ONCE at the start
    v_auth_uid := (SELECT auth.uid());

    -- Get the user profile ID and role for the current authenticated user
    SELECT id, role INTO v_user_profile_id, v_role
    FROM user_profiles
    WHERE auth_user_id = v_auth_uid AND active = true;

    -- If user not found, return empty array
    IF v_user_profile_id IS NULL THEN
        RETURN ARRAY[]::uuid[];
    END IF;

    -- If admin, supervisor, or staff, return all active customers (inline check, no function call)
    IF v_role IN ('admin', 'supervisor', 'staff') THEN
        RETURN ARRAY(
            SELECT id FROM customers WHERE active = true ORDER BY id
        );
    END IF;

    -- Otherwise return only assigned customers (using new table structure)
    RETURN ARRAY(
        SELECT uc.customer_id
        FROM users_customers_new uc
        LEFT JOIN customers c ON c.id = uc.customer_id
        WHERE uc.user_profile_id = v_user_profile_id AND uc.active = true
        ORDER BY c.name, uc.customer_id
    );
END;
$$;

-- Fix 3: lines of invoices and dispatches come back in the order they were saved
CREATE OR REPLACE FUNCTION public.build_invoice_form_lines(p_gr_id uuid, p_duration_mode text DEFAULT 'legacy'::text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'pg_temp'
    AS $$
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
    pairs AS MATERIALIZED (
        SELECT DISTINCT item_id, weight FROM raw
    ),
    rates AS MATERIALIZED (
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
    days AS MATERIALIZED (
        SELECT DISTINCT disp_bd FROM raw
    ),
    dur AS MATERIALIZED (
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
        JOIN rates rt ON rt.item_id = r.item_id
                     AND COALESCE(rt.weight, -2147483648) = COALESCE(r.weight, -2147483648)
                     AND (rt.weight IS NULL) = (r.weight IS NULL)
        JOIN dur ON COALESCE(dur.disp_bd, '-infinity'::date) = COALESCE(r.disp_bd, '-infinity'::date)
                AND (dur.disp_bd IS NULL) = (r.disp_bd IS NULL)
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
               ) ORDER BY l.item_name, l.disp_date, uuid_extract_timestamp(l.dt_id), l.dt_id), '[]'::jsonb) AS items
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
$$;

CREATE OR REPLACE FUNCTION public.build_invoice_recalculation_rows(p_gr_id uuid, p_duration_mode text DEFAULT 'legacy'::text, p_invoice_id uuid DEFAULT NULL::uuid) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE
    v_duration_mode text;
    v_grn_date date;
    v_grn_customer_id uuid;
    v_grn_pricing_mode text;
    v_dispatch_rows jsonb[] := ARRAY[]::jsonb[];
    v_dispatch_record record;
    v_duration_record record;
    v_price_record item_storage_prices;
    v_src_unit numeric(12,2);
    v_src_labour numeric(12,2);
    v_src_tax numeric(5,2);
    v_unit_price numeric(12,2);
    v_labour_rate numeric(12,2);
    v_tax_percent numeric(5,2);
    v_storage_amount numeric(12,2);
    v_labour_amount numeric(12,2);
    v_base_amount numeric(12,2);
    v_tax_amount numeric(12,2);
    v_tax_total_basis numeric := 0;
    v_total_amount numeric(12,2);
    v_missing_prices text[] := ARRAY[]::text[];
    v_subtotal numeric(12,2) := 0;
    v_total_tax numeric(12,2) := 0;
    v_grand_total numeric(12,2) := 0;
    v_row_counter integer := 0;
BEGIN
    v_duration_mode := public.validate_invoice_duration_mode(p_duration_mode);

    SELECT warehouse_security.business_date(date), customer_id, pricing_mode
    INTO v_grn_date, v_grn_customer_id, v_grn_pricing_mode
    FROM goodsreceived
    WHERE id = p_gr_id;

    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'error', 'GRN not found');
    END IF;

    FOR v_dispatch_record IN
        SELECT
            it.id as invoice_item_id,
            grt.id as grn_items_id,
            grt.item_id as grn_items_item_id,
            grt.item_name as grn_items_item_name,
            grt.qty as grn_items_original_qty,
            grt.stock as grn_items_current_stock,
            grt.packaging as grn_items_packaging,
            grt.package_mark as grn_items_package_mark,
            grt.rack as grn_items_rack,
            grt.weight as grn_items_weight,
            gr.pricing_mode as grn_items_pricing_mode,
            dt.id as dispatches_items_id,
            dt.disp_qty as dispatches_items_disp_qty,
            d.id as dispatches_id,
            d.disp_no as dispatches_no,
            d.disp_date as dispatches_date,
            d.registration as dispatches_vehicle,
            d.customer_name as dispatches_customer_name,
            i.name as items_catalog_name,
            i.description as items_description,
            i.packaging as items_packaging,
            (SELECT COALESCE(SUM(dt2.disp_qty), 0) FROM dispatch_trl dt2 WHERE dt2.gr_trl_id = grt.id) as grn_items_total_dispatched,
            it.charge as existing_charge,
            it.labour_rate as existing_labour_rate,
            it.tax as existing_tax
        FROM goodsreceived_trl grt
        JOIN dispatch_trl dt ON dt.gr_trl_id = grt.id
        JOIN dispatch d ON d.id = dt.disp_id
        JOIN goodsreceived gr ON gr.id = grt.gr_id
        LEFT JOIN items i ON i.id = grt.item_id
        LEFT JOIN invoice_trl it ON it.disp_trl_id = dt.id AND it.invoice_id = p_invoice_id
        WHERE grt.gr_id = p_gr_id
        ORDER BY grt.item_name, d.disp_date, uuid_extract_timestamp(dt.id), dt.id
    LOOP
        v_row_counter := v_row_counter + 1;

        SELECT * INTO v_duration_record
        FROM public.calculate_invoice_duration(v_grn_date, warehouse_security.business_date(v_dispatch_record.dispatches_date), v_duration_mode);

        -- One source for all three figures (migration 86): the GRN's own rate, else the item's.
        v_src_unit := NULL; v_src_labour := NULL; v_src_tax := NULL;
        SELECT g.unit_price, g.labour_rate, g.tax_percent INTO v_src_unit, v_src_labour, v_src_tax
          FROM public.grn_rates g
         WHERE g.gr_id = p_gr_id AND g.item_id = v_dispatch_record.grn_items_item_id
           AND g.price_type = CASE WHEN upper(COALESCE(v_grn_pricing_mode, '')) = 'ONE_TIME' THEN 'one_time' ELSE 'monthly' END
           AND COALESCE(v_dispatch_record.grn_items_weight, 0) BETWEEN g.weight_min AND g.weight_max
         ORDER BY (g.weight_max - g.weight_min), g.weight_min
         LIMIT 1;
        IF NOT FOUND THEN
            v_price_record := find_storage_price(
                v_dispatch_record.grn_items_item_id,
                v_grn_customer_id,
                v_dispatch_record.grn_items_weight,
                v_grn_date,
                LOWER(v_grn_pricing_mode)
            );
            v_src_unit := v_price_record.unit_price;
            v_src_labour := v_price_record.labour_rate;
            v_src_tax := v_price_record.tax_percent;
        END IF;

        -- A saved invoice's own figures win over both.
        v_unit_price := COALESCE(v_dispatch_record.existing_charge, v_src_unit);
        v_labour_rate := COALESCE(v_dispatch_record.existing_labour_rate, v_src_labour, 0);
        v_tax_percent := COALESCE(v_dispatch_record.existing_tax, v_src_tax, 0);

        IF v_unit_price IS NULL THEN
            IF NOT (v_dispatch_record.grn_items_item_name = ANY(v_missing_prices)) THEN
                v_missing_prices := v_missing_prices || v_dispatch_record.grn_items_item_name;
            END IF;
        END IF;

        IF v_dispatch_record.grn_items_pricing_mode = 'ONE_TIME' THEN
            v_storage_amount := ROUND(COALESCE(v_unit_price, 0) * v_dispatch_record.dispatches_items_disp_qty, 2);
            v_labour_amount := 0;
        ELSE
            v_storage_amount := ROUND(COALESCE(v_unit_price, 0) * v_dispatch_record.dispatches_items_disp_qty * v_duration_record.duration, 2);
            v_labour_amount := ROUND(COALESCE(v_labour_rate, 0) * v_dispatch_record.dispatches_items_disp_qty, 2);
        END IF;

        v_base_amount := v_storage_amount + v_labour_amount;
        v_tax_amount := ROUND(v_base_amount * COALESCE(v_tax_percent, 0) / 100.0, 2);
        v_total_amount := v_base_amount + v_tax_amount;

        v_subtotal := v_subtotal + v_base_amount;
        v_tax_total_basis := v_tax_total_basis + (v_base_amount * COALESCE(v_tax_percent, 0) / 100.0);

        v_dispatch_rows := v_dispatch_rows || (
            jsonb_build_object(
                'id', v_dispatch_record.invoice_item_id,
                'invoice_item_id', v_dispatch_record.invoice_item_id,
                'row_number', v_row_counter,
                'rowNumber', v_row_counter,
                'disp_trl_id', v_dispatch_record.dispatches_items_id,
                'dispatch_item_id', v_dispatch_record.dispatches_items_id,
                'dispatches_items_id', v_dispatch_record.dispatches_items_id,
                'grn_item_id', v_dispatch_record.grn_items_id,
                'grn_items_id', v_dispatch_record.grn_items_id,
                'grn_items_item_id', v_dispatch_record.grn_items_item_id,
                'grn_items_item_name', v_dispatch_record.grn_items_item_name,
                'item_id', v_dispatch_record.grn_items_item_id,
                'item_name', v_dispatch_record.grn_items_item_name,
                'grn_items_original_qty', v_dispatch_record.grn_items_original_qty,
                'original_qty', v_dispatch_record.grn_items_original_qty,
                'grn_items_current_stock', v_dispatch_record.grn_items_current_stock,
                'current_stock', v_dispatch_record.grn_items_current_stock,
                'grn_items_packaging', v_dispatch_record.grn_items_packaging,
                'item_packaging', v_dispatch_record.grn_items_packaging,
                'grn_items_package_mark', v_dispatch_record.grn_items_package_mark,
                'package_mark', v_dispatch_record.grn_items_package_mark,
                'grn_items_rack', v_dispatch_record.grn_items_rack,
                'rack', v_dispatch_record.grn_items_rack,
                'grn_items_weight', v_dispatch_record.grn_items_weight,
                'weight', v_dispatch_record.grn_items_weight
            )
            ||
            jsonb_build_object(
                'grn_items_total_dispatched', v_dispatch_record.grn_items_total_dispatched,
                'total_dispatched', v_dispatch_record.grn_items_total_dispatched,
                'grn_items_pricing_mode', v_dispatch_record.grn_items_pricing_mode,
                'dispatches_items_disp_qty', v_dispatch_record.dispatches_items_disp_qty,
                'dispatch_qty', v_dispatch_record.dispatches_items_disp_qty,
                'qty', v_dispatch_record.dispatches_items_disp_qty,
                'dispatches_id', v_dispatch_record.dispatches_id,
                'dispatch_id', v_dispatch_record.dispatches_id,
                'dispatches_no', v_dispatch_record.dispatches_no,
                'dispatch_no', v_dispatch_record.dispatches_no,
                'dispatches_date', v_dispatch_record.dispatches_date,
                'dispatch_date', v_dispatch_record.dispatches_date,
                'dispatches_vehicle', v_dispatch_record.dispatches_vehicle,
                'dispatch_vehicle', v_dispatch_record.dispatches_vehicle,
                'dispatches_customer_name', v_dispatch_record.dispatches_customer_name,
                'dispatch_customer_name', v_dispatch_record.dispatches_customer_name,
                'items_catalog_name', v_dispatch_record.items_catalog_name,
                'catalog_name', v_dispatch_record.items_catalog_name,
                'items_description', v_dispatch_record.items_description,
                'item_description', v_dispatch_record.items_description,
                'items_packaging', v_dispatch_record.items_packaging,
                'catalog_packaging', v_dispatch_record.items_packaging,
                'grn_date', v_grn_date,
                'no_of_days', v_duration_record.no_of_days,
                'calculated_days', v_duration_record.no_of_days
            )
            ||
            jsonb_build_object(
                'billable_days', v_duration_record.billable_days,
                'duration', v_duration_record.duration,
                'calculated_duration', v_duration_record.duration,
                'duration_mode', v_duration_mode,
                'unit_price', v_unit_price,
                'charge', v_unit_price,
                'labour_rate', v_labour_rate,
                'tax_percent', v_tax_percent,
                'tax', v_tax_percent,
                'storage_amount', v_storage_amount,
                'labour_amount', v_labour_amount,
                'base_amount', v_base_amount,
                'amount', v_base_amount,
                'item_amount', v_base_amount,
                'tax_amount', v_tax_amount,
                'item_tax', v_tax_amount,
                'total_amount', v_total_amount,
                'item_total', v_total_amount,
                'missing_price', v_unit_price IS NULL,
                'duration_calculation_note', format('Duration calculated from GRN date (%s) to dispatch date (%s) using %s mode',
                    v_grn_date, warehouse_security.business_date(v_dispatch_record.dispatches_date), v_duration_mode)
            )
        );
    END LOOP;

    v_total_tax := CEIL(v_tax_total_basis);
    v_grand_total := CEIL(v_subtotal + v_total_tax);

    RETURN jsonb_build_object(
        'success', true,
        'rows', v_dispatch_rows,
        'items', v_dispatch_rows,
        'duration_mode', v_duration_mode,
        'missing_items', v_missing_prices,
        'totals', jsonb_build_object(
            'subtotal', v_subtotal,
            'tax', v_total_tax,
            'total_tax', v_total_tax,
            'grand_total', v_grand_total,
            'total', v_grand_total,
            'total_rows', v_row_counter
        )
    );
END;
$$;

CREATE OR REPLACE FUNCTION public.delete_dispatch_with_order_cleanup(p_dispatch_id uuid, p_user_id uuid) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'extensions', 'utils', 'pg_temp'
    AS $$
DECLARE
    v_user_profile_id UUID;
    v_dispatch_record dispatch%ROWTYPE;
    v_accessible_customers UUID[];
    v_linked_orders_count INTEGER;
    v_order_record RECORD;
    v_stock_updates jsonb := '[]'::jsonb;
    v_cart_restoration jsonb;
    v_item record;
    v_old_stock integer;
    v_new_stock integer;
    v_grn_items_restored INTEGER := 0;
    v_orders_updated INTEGER := 0;
    v_out_of_stock_reset INTEGER := 0;
    v_order_items_restored INTEGER := 0;
    v_order_items_recreated INTEGER := 0;
    v_debug_info jsonb := '[]'::jsonb;
    v_source_order_no TEXT;
    v_restored_items jsonb := '[]'::jsonb;
    v_cart_restoration_error TEXT := NULL;
    v_has_cart_items BOOLEAN := FALSE;
    v_invoice_count INTEGER := 0;  -- NEW: For invoice safeguard
    v_cart_line record;
    v_restore_cart_id uuid;
    v_cart_lines_not_restored integer := 0;
    v_cart_lines_no_open_cart integer := 0;
    v_cart_details jsonb := '[]'::jsonb;
BEGIN
  PERFORM warehouse_security.authorize_rpc('delete_dispatch_with_order_cleanup',jsonb_build_object('p_dispatch_id',p_dispatch_id));
    -- The list-refresh lock comes before any row lock (migration 46).
    PERFORM pg_advisory_xact_lock(71040);
    -- Get user profile ID
    SELECT id INTO v_user_profile_id
    FROM user_profiles
    WHERE auth_user_id = auth.uid();

    IF v_user_profile_id IS NULL THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'User not found',
            'message', 'User not found'
        );
    END IF;

    -- Get dispatch details
    SELECT * INTO v_dispatch_record FROM dispatch WHERE id = p_dispatch_id;

    IF v_dispatch_record.id IS NULL THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'Dispatch not found',
            'message', 'Dispatch not found'
        );
    END IF;

    -- Check access permissions
    IF NOT is_admin_or_supervisor_strict() THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'Only administrators and supervisors can delete dispatches',
            'message', 'Only administrators and supervisors can delete dispatches'
        );
    END IF;

    -- ⚠️ NEW: CRITICAL INVOICE SAFEGUARD
    -- Check if dispatch has any invoiced items
    SELECT COUNT(*) INTO v_invoice_count
    FROM invoice_trl it
    WHERE it.disp_trl_id IN (
        SELECT id FROM dispatch_trl WHERE disp_id = p_dispatch_id
    );

    IF v_invoice_count > 0 THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', format('Cannot delete dispatch %s: %s invoice items exist',
                           v_dispatch_record.disp_no, v_invoice_count),
            'message', 'Delete invoices first before deleting this dispatch',
            'dispatch_no', v_dispatch_record.disp_no,
            'dispatch_id', p_dispatch_id,
            'invoice_items_count', v_invoice_count,
            'instructions', 'You must delete all related invoices before this dispatch can be deleted',
            'blocking_reason', 'invoices_exist'
        );
    END IF;
    -- END NEW SAFEGUARD

    -- Collect information about items being restored BEFORE deletion
    FOR v_item IN
        SELECT
            dt.disp_qty,
            gt.item_name,
            gt.package_mark,
            gr.gr_no
        FROM dispatch_trl dt
        JOIN goodsreceived_trl gt ON gt.id = dt.gr_trl_id
        JOIN goodsreceived gr ON gr.id = gt.gr_id
        WHERE dt.disp_id = p_dispatch_id
    LOOP
        v_restored_items := v_restored_items || jsonb_build_object(
            'item_name', v_item.item_name,
            'package_mark', v_item.package_mark,
            'grn_no', v_item.gr_no,
            'quantity_restored', v_item.disp_qty
        );
    END LOOP;

    -- Get the source order number if we have a source order
    IF v_dispatch_record.source_order_id IS NOT NULL THEN
        -- Get order_no, or generate one if it's null/empty
        SELECT
            CASE
                WHEN order_no IS NULL OR order_no = '' THEN
                    'ORD-' || TO_CHAR(CURRENT_DATE, 'YYYYMMDD') || '-' || SUBSTRING(id::text FROM 1 FOR 8)
                ELSE
                    order_no
            END INTO v_source_order_no
        FROM orders
        WHERE id = v_dispatch_record.source_order_id;

        -- If we generated an order_no, update the order record
        UPDATE orders
        SET order_no = v_source_order_no
        WHERE id = v_dispatch_record.source_order_id
        AND (order_no IS NULL OR order_no = '');
    END IF;

    -- Cart quantities are given back below, from what each dispatch line
    -- recorded when it was saved (migration 67).

    -- Restore stock for each dispatch item
    FOR v_item IN
        SELECT
            dt.*,
            gt.item_name,
            gt.packaging,
            gt.weight,
            gt.gr_id
        FROM dispatch_trl dt
        LEFT JOIN goodsreceived_trl gt ON gt.id = dt.gr_trl_id
        WHERE dt.disp_id = p_dispatch_id
    LOOP
        -- Get current stock from goodsreceived_trl
        SELECT stock INTO v_old_stock
        FROM goodsreceived_trl
        WHERE id = v_item.gr_trl_id;

        v_new_stock := LEAST((SELECT qty FROM goodsreceived_trl WHERE id = v_item.gr_trl_id), COALESCE(v_old_stock, 0) + v_item.disp_qty);

        -- Update stock in goodsreceived_trl
        UPDATE goodsreceived_trl
        SET
            stock = v_new_stock
        WHERE id = v_item.gr_trl_id;

        -- The stock coming back is logged (migration 67).
        IF v_old_stock IS NOT NULL AND v_new_stock <> v_old_stock THEN
            INSERT INTO stock_movements (gr_trl_id, movement_type, quantity, reference_id, reference_type,
                                         balance_before, balance_after, created_by, notes)
            VALUES (v_item.gr_trl_id,
                    CASE WHEN v_new_stock > v_old_stock THEN 'return' ELSE 'adjustment' END,
                    v_new_stock - v_old_stock, p_dispatch_id, 'dispatch_delete',
                    v_old_stock, v_new_stock, v_user_profile_id, 'Dispatch deleted');
        END IF;

        v_grn_items_restored := v_grn_items_restored + 1;

        -- Record the update
        v_stock_updates := v_stock_updates || jsonb_build_object(
            'gr_trl_id', v_item.gr_trl_id,
            'gr_id', v_item.gr_id,
            'item_name', v_item.item_name,
            'packaging', v_item.packaging,
            'weight', v_item.weight,
            'quantity_restored', v_item.disp_qty,
            'old_stock', v_old_stock,
            'new_stock', v_new_stock
        );
    END LOOP;

    -- Reset out_of_stock flag for GRNs that now have stock
    WITH grn_stock_status AS (
        SELECT
            gr.id,
            gr.out_of_stock as current_status,
            COALESCE(SUM(grt.stock), 0) as total_stock
        FROM goodsreceived gr
        INNER JOIN goodsreceived_trl grt ON grt.gr_id = gr.id
        WHERE gr.id IN (
            SELECT DISTINCT gt.gr_id
            FROM dispatch_trl dt
            JOIN goodsreceived_trl gt ON gt.id = dt.gr_trl_id
            WHERE dt.disp_id = p_dispatch_id
        )
        GROUP BY gr.id, gr.out_of_stock
    )
    UPDATE goodsreceived
    SET out_of_stock = FALSE
    FROM grn_stock_status
    WHERE goodsreceived.id = grn_stock_status.id
    AND grn_stock_status.current_status = TRUE
    AND grn_stock_status.total_stock > 0;

    -- Get count of rows affected
    GET DIAGNOSTICS v_out_of_stock_reset = ROW_COUNT;

    -- Give back to the customer's cart what this dispatch took from it
    -- (migration 67). When a dispatch is saved, each line records the cart line
    -- it lowered (source_order_item_id) and by how much (cart_quantity_consumed).
    -- That quantity is added back to the cart's line for the lot, pending and
    -- with nothing fulfilled, or a pending line of that quantity is made again
    -- when the dispatch used the line up. The cart is the order the dispatch was
    -- made from; for a direct dispatch, the order of the recorded cart line, else
    -- the customer's OPEN cart (the rule the direct dispatch used to find it),
    -- else a new OPEN cart made as get_or_create_cart makes it. A customer has
    -- one order at most (one_cart_per_customer): when it exists but is not OPEN
    -- or is deleted, no cart can be made, the order is left as it is and the
    -- line is counted (cart_lines_without_open_cart).
    FOR v_cart_line IN
        SELECT
            dt.id,
            dt.gr_trl_id,
            dt.cart_quantity_consumed,
            dt.source_order_item_id,
            gt.item_name,
            gt.item_id,
            gt.package_mark,
            gt.packaging,
            gt.rack,
            gt.weight,
            gt.stock,
            gt.gr_id,
            gr.gr_no,
            gr.date as gr_date,
            gr.customer_id,
            gr.customer_name,
            gr.gr_image_url
        FROM dispatch_trl dt
        JOIN goodsreceived_trl gt ON gt.id = dt.gr_trl_id
        JOIN goodsreceived gr ON gr.id = gt.gr_id
        WHERE dt.disp_id = p_dispatch_id
          AND COALESCE(dt.cart_quantity_consumed, 0) > 0
        ORDER BY uuid_extract_timestamp(dt.id), dt.id
    LOOP
        v_restore_cart_id := COALESCE(
            v_dispatch_record.source_order_id,
            (SELECT oi.order_id FROM order_items oi WHERE oi.id = v_cart_line.source_order_item_id),
            (SELECT o.id FROM orders o
             WHERE o.customer_id = v_dispatch_record.customer_id AND o.status = 'OPEN' AND o.deleted_at IS NULL
             ORDER BY o.created_at, o.id
             LIMIT 1));

        IF v_restore_cart_id IS NULL THEN
            -- No OPEN cart: make one, with get_or_create_cart's columns. The
            -- unique index lets this succeed only when the customer has no order.
            INSERT INTO orders (
                customer_id, customer_name, customer_email, customer_phone,
                order_date, requested_dispatch_date, status, priority,
                created_by, updated_by
            )
            SELECT c.id, c.name, c.email, c.mobile,
                   NOW(), NOW() + INTERVAL '7 days', 'OPEN', 'normal',
                   v_user_profile_id, v_user_profile_id
            FROM customers c
            WHERE c.id = v_dispatch_record.customer_id
            ON CONFLICT DO NOTHING
            RETURNING id INTO v_restore_cart_id;
        END IF;

        IF v_restore_cart_id IS NULL THEN
            v_cart_lines_no_open_cart := v_cart_lines_no_open_cart + 1;
            CONTINUE;
        END IF;

        UPDATE order_items
        SET
            requested_quantity = requested_quantity + v_cart_line.cart_quantity_consumed,
            fulfilled_quantity = 0,
            item_status = 'pending',
            current_stock = v_cart_line.stock,
            updated_at = now()
        WHERE order_id = v_restore_cart_id
          AND grn_items_id = v_cart_line.gr_trl_id;

        IF FOUND THEN
            v_order_items_restored := v_order_items_restored + 1;
        ELSE
            INSERT INTO order_items (
                order_id, order_no, requested_quantity, fulfilled_quantity,
                grn_items_id, grn_items_item_id, grn_items_item_name,
                grn_items_package_mark, grn_items_packaging, grn_items_rack,
                grn_items_weight, grn_items_image_url,
                grns_id, grns_gr_no, grns_date, grns_customer_id, grns_customer_name,
                available_stock_at_order, current_stock, item_status, sort_order
            ) VALUES (
                v_restore_cart_id,
                (SELECT o.order_no FROM orders o WHERE o.id = v_restore_cart_id),
                v_cart_line.cart_quantity_consumed,
                0,
                v_cart_line.gr_trl_id,
                v_cart_line.item_id,
                v_cart_line.item_name,
                COALESCE(v_cart_line.package_mark, ''),
                COALESCE(v_cart_line.packaging, ''),
                COALESCE(v_cart_line.rack, ''),
                COALESCE(v_cart_line.weight, 0),
                v_cart_line.gr_image_url,
                v_cart_line.gr_id,
                v_cart_line.gr_no,
                v_cart_line.gr_date,
                v_cart_line.customer_id,
                COALESCE(v_cart_line.customer_name, v_dispatch_record.customer_name, ''),
                v_cart_line.stock,
                v_cart_line.stock,
                'pending',
                COALESCE((SELECT max(oi.sort_order) + 1 FROM order_items oi WHERE oi.order_id = v_restore_cart_id), 1)
            );

            v_order_items_recreated := v_order_items_recreated + 1;
        END IF;

        v_cart_details := v_cart_details || jsonb_build_object(
            'order_id', v_restore_cart_id,
            'gr_trl_id', v_cart_line.gr_trl_id,
            'item_name', v_cart_line.item_name,
            'quantity_restored', v_cart_line.cart_quantity_consumed
        );
    END LOOP;

    -- A line of a dispatch from the cart saved before migration 67 has no record
    -- of what it took from the cart: nothing is given back for it, and the
    -- answer says how many such lines there were.
    IF v_dispatch_record.source_order_id IS NOT NULL THEN
        v_cart_lines_not_restored := v_cart_lines_not_restored + (
            SELECT count(*)::integer FROM dispatch_trl
            WHERE disp_id = p_dispatch_id AND source_type IS DISTINCT FROM 'cart'
        );
    END IF;

    v_has_cart_items := jsonb_array_length(v_cart_details) > 0;
    v_cart_restoration := jsonb_build_object(
        'success', true,
        'message', CASE WHEN v_has_cart_items THEN 'Cart quantities restored'
                        ELSE 'No cart quantities to restore' END,
        'updates_made', v_order_items_restored + v_order_items_recreated,
        'restoration_details', v_cart_details,
        'lines_not_restored', v_cart_lines_not_restored,
        'lines_without_open_cart', v_cart_lines_no_open_cart
    );

    -- Check if there are linked orders - now just check source_order_id
    v_linked_orders_count := 0;
    IF v_dispatch_record.source_order_id IS NOT NULL THEN
        v_linked_orders_count := 1;

        -- Cart lines were given back above (migration 67).

        -- Add dispatch deletion to orders.revisions
        INSERT INTO public.order_revisions (order_id, changed_at, changed_by, action, entry)
        SELECT id, clock_timestamp(), v_user_profile_id, 'dispatch_deleted', (
                jsonb_build_object(
                    'action', 'dispatch_deleted',
                    'timestamp', NOW(),
                    'by', v_user_profile_id,
                    'dispatch_id', v_dispatch_record.id,
                    'dispatch_no', v_dispatch_record.disp_no,
                    'restored_items', v_restored_items,
                    'total_quantity_restored', (
                        SELECT COALESCE(SUM(disp_qty), 0)
                        FROM dispatch_trl
                        WHERE disp_id = p_dispatch_id
                    ),
                    'cart_restoration_status', CASE
                        WHEN v_cart_restoration_error IS NOT NULL THEN 'failed'
                        WHEN NOT v_has_cart_items THEN 'not_applicable'
                        ELSE 'success'
                    END
                )
            )
        FROM public.orders WHERE id = v_dispatch_record.source_order_id;

        -- Update order status to OPEN and clear soft-delete
        UPDATE orders
        SET
            status = 'OPEN',
            deleted_at = NULL,
            deleted_by = NULL,
            updated_by = v_user_profile_id,
            updated_at = now()
        WHERE id = v_dispatch_record.source_order_id;

        v_orders_updated := 1;
    END IF;

    -- Delete dispatch items
    DELETE FROM dispatch_trl WHERE disp_id = p_dispatch_id;

    -- Delete dispatch
    DELETE FROM dispatch WHERE id = p_dispatch_id;

    -- Return comprehensive result
    RETURN jsonb_build_object(
        'success', true,
        'message', format('Dispatch %s deleted successfully. %s linked order(s) reset, %s order items restored/recreated, %s GRN items restored, %s out_of_stock flags reset.',
                         v_dispatch_record.disp_no,
                         v_linked_orders_count,
                         v_order_items_restored + v_order_items_recreated,
                         v_grn_items_restored,
                         v_out_of_stock_reset)
            || CASE WHEN v_cart_lines_not_restored > 0
                    THEN format(' %s cart line(s) were saved before cart quantities were recorded; their quantities were not returned to the order.',
                                v_cart_lines_not_restored)
                    ELSE '' END
            || CASE WHEN v_cart_lines_no_open_cart > 0
                    THEN format(' %s cart line(s) were not returned: the customer has no open cart and one could not be made.',
                                v_cart_lines_no_open_cart)
                    ELSE '' END,
        'dispatch_id', p_dispatch_id,
        'dispatch_no', v_dispatch_record.disp_no,
        'customer_id', v_dispatch_record.customer_id,
        'customer_name', v_dispatch_record.customer_name,
        'stock_updates', v_stock_updates,
        'cart_restoration', v_cart_restoration,
        'cart_lines_not_restored', v_cart_lines_not_restored,
        'cart_lines_without_open_cart', v_cart_lines_no_open_cart,
        'order_restoration', jsonb_build_object(
            'items_updated', v_order_items_restored,
            'items_recreated', v_order_items_recreated,
            'cart_items_restored', COALESCE((v_cart_restoration->>'updates_made')::integer, 0),
            'total_items_restored', v_order_items_restored + v_order_items_recreated
        ),
        'statistics', jsonb_build_object(
            'orders_updated', v_orders_updated,
            'grn_items_restored', v_grn_items_restored,
            'out_of_stock_flags_reset', v_out_of_stock_reset,
            'linked_orders_count', v_linked_orders_count,
            'order_items_restored', v_order_items_restored + v_order_items_recreated,
            'dispatch_had_cart_items', v_has_cart_items
        ),
        'timestamp', CURRENT_TIMESTAMP,
        'deleted_by', v_user_profile_id
    );

EXCEPTION
    WHEN OTHERS THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', SQLERRM,
            'message', 'Database error occurred',
            'dispatch_id', p_dispatch_id,
            'debug_info', v_debug_info
        );
END;
$$;

CREATE OR REPLACE FUNCTION public.get_dispatch_details(p_dispatch_id uuid) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'extensions', 'utils', 'pg_temp'
    AS $$
    DECLARE
        v_user_id uuid;
        v_role text;
        v_result jsonb;
BEGIN
  PERFORM warehouse_security.authorize_rpc('get_dispatch_details',jsonb_build_object('p_dispatch_id',p_dispatch_id));
        v_user_id := auth.uid();

        SELECT role INTO v_role
        FROM user_profiles
        WHERE auth_user_id = v_user_id;

        SELECT jsonb_build_object(
            'success', true,
            'data', jsonb_build_object(
                'dispatch', jsonb_build_object(
                    'id', d.id,
                    'disp_no', d.disp_no,
                    'disp_date', d.disp_date,
                    'registration', d.registration,
                    'note', d.note,
                    'disp_image_url', d.disp_image_url,
                    'source_order_id', d.source_order_id,
                    'source_order_no', d.source_order_no,
                    'created_at', d.created_at,
                    'updated_at', d.updated_at,

                    'images', COALESCE(
                        (
                            SELECT jsonb_agg(
                                jsonb_build_object(
                                    'id', di.id,
                                    'storage_path', di.storage_path,
                                    'original_filename', di.original_filename,
                                    'file_size', di.file_size,
                                    'mime_type', di.mime_type,
                                    'display_order', di.display_order,
                                    'created_at', di.created_at
                                )
                                ORDER BY di.display_order, di.created_at
                            )
                            FROM dispatch_images di
                            WHERE di.dispatch_id = d.id
                            AND di.status = 'confirmed'
                        ),
                        '[]'::jsonb
                    ),

                    'customer_details', CASE
                        WHEN c.id IS NOT NULL THEN jsonb_build_object(
                            'id', c.id,
                            'name', c.name,
                            'first_name', c."firstName",
                            'last_name', c."lastName",
                            'gst', c.gst,
                            'mobile', c.mobile,
                            'address', c.address,
                            'city', c.city,
                            'state', c.state,
                            'pincode', c.pincode,
                            'email', c.email,
                            'active', c.active,
                            'auto_invoice_generation', c.auto_invoice_generation
                        )
                        ELSE null
                    END,

                    'supervisor_details', CASE
                        WHEN u.id IS NOT NULL THEN jsonb_build_object(
                            'id', u.id,
                            'name', u.name,
                            'mobile', u.mobile,
                            'role', u.role,
                            'display_name', u.display_name
                        ) - CASE WHEN v_role IN ('admin', 'supervisor', 'staff')
                                   OR auth.jwt() ->> 'role' = 'service_role'
                                 THEN ARRAY[]::text[] ELSE ARRAY['mobile', 'role'] END
                        ELSE null
                    END,

                    'items', COALESCE(
                        (
                            SELECT jsonb_agg(
                                jsonb_build_object(
                                    'id', dt.id,
                                    'disp_qty', dt.disp_qty,
                                    'grn_id', dt.gr_id,
                                    'grn_item_id', dt.gr_trl_id,

                                    'grn_item_details', CASE
                                        WHEN grt.id IS NOT NULL THEN jsonb_build_object(
                                            'id', grt.id,
                                            'qty', grt.qty,
                                            'stock', grt.stock,
                                            'weight', grt.weight,
                                            'rack', grt.rack,
                                            'package_mark', grt.package_mark,
                                            'item_name', grt.item_name,
                                            'packaging', grt.packaging,
                                            'pricing_mode', gr.pricing_mode,
                                            'trl_img_url', grt.trl_img_url
                                        )
                                        ELSE null
                                    END,

                                    'grn_details', CASE
                                        WHEN gr.id IS NOT NULL THEN jsonb_build_object(
                                            'id', gr.id,
                                            'gr_no', gr.gr_no,
                                            'date', gr.date,
                                            'registration', gr.registration,
                                            'customer_name', gr.customer_name,
                                            'supervisor_name', gr.supervisor_name,
                                            'sender_name', gr.sender_name,
                                            'invoiced', gr.invoiced,
                                            'out_of_stock', gr.out_of_stock
                                        )
                                        ELSE null
                                    END,

                                    'item_details', CASE
                                        WHEN i.id IS NOT NULL THEN jsonb_build_object(
                                            'id', i.id,
                                            'name', i.name,
                                            'packaging', i.packaging,
                                            'description', i.description,
                                            'active', i.active
                                        )
                                        ELSE null
                                    END,

                                    'invoice_details', CASE
                                        WHEN it.id IS NOT NULL THEN jsonb_build_object(
                                            'invoice_trl_id', it.id,
                                            'invoice_id', it.invoice_id,
                                            'duration', it.duration,
                                            'no_of_days', it.no_of_days,
                                            'charge', it.charge,
                                            'tax', it.tax,
                                            'labour_rate', it.labour_rate,
                                            'invoice_no', inv.inv_no,
                                            'invoice_date', inv.inv_date,
                                            'total', inv.total
                                        )
                                        ELSE null
                                    END
                                )
                                ORDER BY uuid_extract_timestamp(dt.id), dt.id
                            )
                            FROM dispatch_trl dt
                            LEFT JOIN goodsreceived_trl grt ON dt.gr_trl_id = grt.id
                            LEFT JOIN goodsreceived gr ON dt.gr_id = gr.id
                            LEFT JOIN items i ON grt.item_id = i.id
                            -- A deleted invoice is shown as if the line had none.
                            LEFT JOIN (invoice_trl it JOIN invoice inv ON inv.id = it.invoice_id AND inv.deleted_at IS NULL)
                                   ON dt.id = it.disp_trl_id
                            WHERE dt.disp_id = d.id
                        ),
                        '[]'::jsonb
                    ),

                    'statistics', (
                        SELECT jsonb_build_object(
                            'total_items', COUNT(DISTINCT dt.gr_trl_id),
                            'total_dispatched_qty', COALESCE(SUM(dt.disp_qty), 0),
                            'unique_grns', COUNT(DISTINCT dt.gr_id),
                            'total_invoiced_items', COUNT(DISTINCT it.id),
                            'total_invoice_amount', COALESCE(SUM(amount.base + ROUND(amount.base * COALESCE(it.tax, 0)::numeric / 100, 2)) FILTER (WHERE it.id IS NOT NULL), 0),
                            'avg_duration', COALESCE(AVG(it.duration), 0),
                            'avg_no_of_days', COALESCE(AVG(it.no_of_days), 0)
                        )
                        FROM dispatch_trl dt
                        LEFT JOIN invoice_trl it ON dt.id = it.disp_trl_id
                                              AND EXISTS (SELECT 1 FROM invoice di WHERE di.id = it.invoice_id AND di.deleted_at IS NULL)
                        LEFT JOIN goodsreceived gr_line ON gr_line.id = dt.gr_id
                        -- The line amount of get_invoice_items_detailed (no header rounding, no discount).
                        CROSS JOIN LATERAL (
                            SELECT CASE WHEN gr_line.pricing_mode = 'ONE_TIME'
                            THEN ROUND(COALESCE(it.charge, 0)::numeric * COALESCE(dt.disp_qty, 0)::numeric, 2)
                            ELSE ROUND(COALESCE(it.charge, 0)::numeric * COALESCE(dt.disp_qty, 0)::numeric * COALESCE(it.duration, 1)::numeric, 2)
                                 + ROUND(COALESCE(it.labour_rate, 0)::numeric * COALESCE(dt.disp_qty, 0)::numeric, 2)
                            END AS base
                        ) AS amount
                        WHERE dt.disp_id = d.id
                    ),

                    'grns_summary', (
                        SELECT jsonb_build_object(
                            'total_grns', COUNT(DISTINCT gr.id),
                            'grn_numbers', COALESCE(
                                jsonb_agg(
                                    DISTINCT gr.gr_no
                                    ORDER BY gr.gr_no
                                ) FILTER (WHERE gr.gr_no IS NOT NULL),
                                '[]'::jsonb
                            )
                        )
                        FROM dispatch_trl dt
                        JOIN goodsreceived gr ON dt.gr_id = gr.id
                        WHERE dt.disp_id = d.id
                    ),

                    'invoices_summary', (
                        SELECT jsonb_build_object(
                            'total_invoices', COUNT(DISTINCT inv.id),
                            'total_amount', COALESCE(SUM(inv.total), 0),
                            'invoice_numbers', COALESCE(
                                jsonb_agg(
                                    DISTINCT inv.inv_no
                                    ORDER BY inv.inv_no
                                ) FILTER (WHERE inv.inv_no IS NOT NULL),
                                '[]'::jsonb
                            )
                        )
                        FROM invoice inv
                        WHERE inv.deleted_at IS NULL
                          AND inv.id IN (
                            SELECT it.invoice_id
                            FROM dispatch_trl dt
                            JOIN invoice_trl it ON dt.id = it.disp_trl_id
                            WHERE dt.disp_id = d.id
                        )
                    )
                )
            ),
            'message', 'Dispatch details retrieved successfully'
        ) INTO v_result
        FROM dispatch d
        LEFT JOIN customers c ON d.customer_id = c.id
        LEFT JOIN user_profiles u ON d.supervisor_id = u.id
        WHERE d.id = p_dispatch_id
        AND (
            v_role IN ('admin', 'supervisor', 'staff') OR
            d.customer_id IN (
                SELECT customer_id FROM users_customers_new
                WHERE user_profile_id = (SELECT id FROM user_profiles WHERE auth_user_id = v_user_id)
            )
        );

        IF v_result IS NULL THEN
            RETURN jsonb_build_object(
                'success', false,
                'data', null,
                'message', 'Dispatch not found or access denied'
            );
        END IF;

        RETURN v_result;

    EXCEPTION
        WHEN OTHERS THEN
            RETURN jsonb_build_object(
                'success', false,
                'data', null,
                'message', 'Error retrieving dispatch details: ' || SQLERRM
            );
    END;
    $$;

CREATE OR REPLACE FUNCTION public.get_dispatch_range_for_print(start_disp_no text, end_disp_no text, limit_count integer DEFAULT 100) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE
    v_result jsonb;
BEGIN
    WITH dispatch_data AS (
        SELECT
            d.id as dispatch_id,
            d.disp_no,
            TO_CHAR(d.disp_date, 'YYYY-MM-DD') as formatted_date,
            d.registration,
            d.customer_id::TEXT,
            d.customer_name,
            d.supervisor_id::TEXT,
            d.supervisor_name,
            d.note,
            d.disp_image_url,
            d.source_order_id,
            o.order_no as source_order_no
        FROM dispatch d
        LEFT JOIN orders o ON o.id = d.source_order_id
        WHERE d.disp_no >= start_disp_no
          AND d.disp_no <= end_disp_no
        ORDER BY d.disp_no
        LIMIT limit_count
    ),
    dispatch_with_customer AS (
        SELECT
            dd.*,
            CASE WHEN c.id IS NOT NULL THEN
                jsonb_build_object(
                    'id', c.id::TEXT,
                    'first_name', c."firstName",
                    'last_name', c."lastName",
                    'address', c.address,
                    'city', c.city,
                    'mobile', c.mobile
                )
            ELSE NULL
            END as customer_data
        FROM dispatch_data dd
        LEFT JOIN customers c ON c.id = dd.customer_id::UUID
    ),
    dispatch_items_with_grn AS (
        SELECT
            dwc.*,
            dt.id as dispatch_trl_id,
            dt.disp_qty,
            gr.id as gr_id,
            gr.gr_no,
            TO_CHAR(gr.date, 'YYYY-MM-DD') as gr_date,
            gr.customer_id as gr_customer_id,
            gr.customer_name as gr_customer_name,
            gr.registration as gr_registration,
            gr.gr_image_url as gr_image_url,
            COALESCE(gr.invoiced, FALSE) as gr_invoiced,
            COALESCE(gr.leon, FALSE) as gr_leon,
            gr.note as gr_note,
            COALESCE(gr.out_of_stock, FALSE) as gr_out_of_stock,
            gr.sender_id as gr_sender_id,
            gr.sender_name as gr_sender_name,
            gr.supervisor_id as gr_supervisor_id,
            gr.supervisor_name as gr_supervisor_name,
            grt.id as grt_id,
            grt.item_id as grt_item_id,
            grt.item_name as grt_item_name,
            grt.packaging as grt_packaging,
            grt.qty as grt_qty,
            grt.stock as grt_stock,
            grt.weight as grt_weight,
            grt.rack as grt_rack,
            grt.package_mark as grt_package_mark,
            grt.trl_img_url as grt_trl_img_url,
            ROW_NUMBER() OVER (PARTITION BY dwc.dispatch_id ORDER BY uuid_extract_timestamp(dt.id), dt.id) as sr_no
        FROM dispatch_with_customer dwc
        LEFT JOIN dispatch_trl dt ON dt.disp_id = dwc.dispatch_id
        LEFT JOIN goodsreceived gr ON gr.id = dt.gr_id
        LEFT JOIN goodsreceived_trl grt ON grt.id = dt.gr_trl_id
    ),
    dispatch_with_items AS (
        SELECT
            diwg.dispatch_id,
            diwg.disp_no,
            diwg.formatted_date,
            diwg.registration,
            diwg.customer_id,
            diwg.customer_name,
            diwg.supervisor_id,
            diwg.supervisor_name,
            diwg.note,
            diwg.disp_image_url,
            diwg.source_order_id,
            diwg.source_order_no,
            diwg.customer_data,
            jsonb_agg(
                CASE WHEN diwg.dispatch_trl_id IS NOT NULL THEN
                    jsonb_build_object(
                        'id', diwg.dispatch_trl_id::TEXT,
                        'dispatch_id', diwg.dispatch_id::TEXT,
                        'disp_no', diwg.disp_no,
                        'disp_quantity', COALESCE(diwg.disp_qty, 0),
                        'grn_items_id', diwg.grt_id::TEXT,
                        'grn_items_image_url', diwg.grt_trl_img_url,
                        'grn_items_item_id', diwg.grt_item_id::TEXT,
                        'grn_items_item_name', diwg.grt_item_name,
                        'grn_items_package_mark', diwg.grt_package_mark,
                        'grn_items_packaging', diwg.grt_packaging,
                        'grn_items_quantity', COALESCE(diwg.grt_qty, 0),
                        'grn_items_rack', diwg.grt_rack,
                        'grn_items_stock', COALESCE(diwg.grt_stock, 0),
                        'grn_items_weight', COALESCE(diwg.grt_weight, 0),
                        'grns_id', diwg.gr_id::TEXT,
                        'grns_gr_no', diwg.gr_no,
                        'grns_date', diwg.gr_date,
                        'grns_customer_id', diwg.gr_customer_id::TEXT,
                        'grns_customer_name', diwg.gr_customer_name,
                        'grns_registration', diwg.gr_registration,
                        'grns_image_url', diwg.gr_image_url,
                        'grns_invoiced', diwg.gr_invoiced,
                        'grns_leon', diwg.gr_leon,
                        'grns_note', diwg.gr_note,
                        'grns_out_of_stock', diwg.gr_out_of_stock,
                        'grns_sender_id', diwg.gr_sender_id::TEXT,
                        'grns_sender_name', diwg.gr_sender_name,
                        'grns_supervisor_id', diwg.gr_supervisor_id::TEXT,
                        'grns_supervisor_name', diwg.gr_supervisor_name,
                        'sr_no', diwg.sr_no
                    )
                ELSE NULL
                END
                ORDER BY diwg.sr_no
            ) FILTER (WHERE diwg.dispatch_trl_id IS NOT NULL) as items_data,
            SUM(COALESCE(diwg.disp_qty, 0)) as total_quantity
        FROM dispatch_items_with_grn diwg
        GROUP BY
            diwg.dispatch_id, diwg.disp_no, diwg.formatted_date, diwg.registration,
            diwg.customer_id, diwg.customer_name, diwg.supervisor_id, diwg.supervisor_name,
            diwg.note, diwg.disp_image_url, diwg.source_order_id, diwg.source_order_no, diwg.customer_data
    ),
    final_result AS (
        SELECT jsonb_agg(
            jsonb_build_object(
                'id', dwi.dispatch_id,
                'disp_no', dwi.disp_no,
                'disp_date', dwi.formatted_date,
                'registration', dwi.registration,
                'customer_id', dwi.customer_id,
                'customer_name', dwi.customer_name,
                'supervisor_id', dwi.supervisor_id,
                'supervisor_name', dwi.supervisor_name,
                'note', dwi.note,
                'image_url', dwi.disp_image_url,
                'source_order_id', dwi.source_order_id,
                'source_order_no', dwi.source_order_no,
                'customer', dwi.customer_data,
                'items', COALESCE(dwi.items_data, '[]'::jsonb),
                'total_qty', COALESCE(dwi.total_quantity, 0)::INTEGER,
                'total_qty_in_words', convert_number_to_words(COALESCE(dwi.total_quantity, 0)::INTEGER)
            ) ORDER BY dwi.disp_no
        ) as data
        FROM dispatch_with_items dwi
    )
    SELECT COALESCE(data, '[]'::jsonb) INTO v_result FROM final_result;

    RETURN utils.success_response(v_result, NULL);
END;
$$;

CREATE OR REPLACE FUNCTION public.create_dispatch_with_stock_check_internal(p_dispatch_data jsonb, p_dispatch_items jsonb[], p_generate_invoice boolean DEFAULT false, p_idempotency_key text DEFAULT NULL::text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE
    v_dispatch_id uuid;
    v_user_id uuid;
    v_affected_gr_ids uuid[];
    v_all_gr_ids uuid[];
    v_insufficient_stock text;
    v_foreign_lots text;
    v_dispatch_items_result jsonb[];
    v_invoice_data jsonb;
    v_gr_id uuid;
    v_grn_customer_id uuid;
    v_is_invoiceable boolean;
    v_single_invoice_data jsonb;
    v_source_order_id uuid;
    v_source_order_no text;  -- Added for auto-lookup
    v_item jsonb;
    v_gr_trl_id uuid;
    v_dispatched_qty integer;
    v_cart_id uuid;
    v_cart_item_id uuid;
    v_cart_current_qty integer;
    v_cart_fulfilled_qty integer;
    v_cart_new_qty integer;
    v_cached_response jsonb;
    v_order_customer_id uuid;
BEGIN
    -- The document lock comes before the idempotency lookup, as in save_grn (migration 87):
    -- an overlapping retry waits here and then finds the first call's cached answer.
    PERFORM pg_advisory_xact_lock(71040);

    -- Check idempotency key first
    IF p_idempotency_key IS NOT NULL THEN
        SELECT response INTO v_cached_response
        FROM idempotency_keys
        WHERE idempotency_key = p_idempotency_key
          AND rpc_function = 'create_dispatch_with_stock_check'
          AND created_by = (SELECT id FROM user_profiles WHERE auth_user_id = auth.uid())
          AND expires_at > NOW();

        IF v_cached_response IS NOT NULL THEN
            RETURN v_cached_response || jsonb_build_object('from_cache', true);
        END IF;
    END IF;

    -- Check if user is admin or supervisor
    IF NOT warehouse_security.active_role() IN ('admin','supervisor','staff') THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'Only administrators and supervisors can create dispatches'
        );
    END IF;

    -- Get current user
    SELECT id INTO v_user_id FROM user_profiles WHERE auth_user_id = auth.uid();

    -- Extract source_order_id if provided
    v_source_order_id := (p_dispatch_data->>'source_order_id')::uuid;

    -- Auto-lookup source_order_no from orders table if not provided
    IF v_source_order_id IS NOT NULL THEN
        -- The cart must be the dispatch customer's (a plain read: the cart writers lock the cart first).
        SELECT customer_id INTO v_order_customer_id
        FROM orders
        WHERE id = v_source_order_id AND deleted_at IS NULL;
        IF v_order_customer_id IS NULL
           OR v_order_customer_id IS DISTINCT FROM (p_dispatch_data->>'customer_id')::uuid THEN
            RAISE EXCEPTION 'The order belongs to another customer' USING ERRCODE = 'WH409';
        END IF;

        v_source_order_no := COALESCE(
            p_dispatch_data->>'source_order_no',
            (SELECT order_no FROM orders WHERE id = v_source_order_id)
        );
    ELSE
        v_source_order_no := p_dispatch_data->>'source_order_no';
    END IF;

    -- A lot appears once in the dispatch lines (migration 87).
    IF EXISTS (
        SELECT 1 FROM unnest(p_dispatch_items) AS d
        GROUP BY (d->>'gr_trl_id')::uuid HAVING count(*) > 1
    ) THEN
        RAISE EXCEPTION 'The same lot appears twice in the dispatch lines' USING ERRCODE = 'WH409';
    END IF;

    -- STEP 1: Lock all relevant GRN items first (no aggregation)
    PERFORM gt.id
    FROM unnest(p_dispatch_items) AS item
    JOIN goodsreceived_trl gt ON gt.id = (item->>'gr_trl_id')::uuid
    FOR UPDATE OF gt;

    -- A dispatch carries only its own customer's lots. The receipts are
    -- key-share locked so update_grn cannot move one to another customer meanwhile.
    PERFORM gr.id
    FROM unnest(p_dispatch_items) AS item
    JOIN goodsreceived_trl gt ON gt.id = (item->>'gr_trl_id')::uuid
    JOIN goodsreceived gr ON gr.id = gt.gr_id
    FOR KEY SHARE OF gr;

    SELECT string_agg(gt.item_name || ' (' || gr.gr_no || ')', ', ')
    INTO v_foreign_lots
    FROM unnest(p_dispatch_items) AS item
    JOIN goodsreceived_trl gt ON gt.id = (item->>'gr_trl_id')::uuid
    JOIN goodsreceived gr ON gr.id = gt.gr_id
    WHERE gr.customer_id IS DISTINCT FROM (p_dispatch_data->>'customer_id')::uuid;

    IF v_foreign_lots IS NOT NULL THEN
        RAISE EXCEPTION 'Item belongs to another customer: %', v_foreign_lots USING ERRCODE = 'WH409';
    END IF;

    -- STEP 2: Check stock availability (separate query, no FOR UPDATE)
    SELECT string_agg(
        gt.item_name || ' (Available: ' || gt.stock || ', Requested: ' || (item->>'disp_qty')::integer || ')',
        ', '
    )
    INTO v_insufficient_stock
    FROM unnest(p_dispatch_items) AS item
    JOIN goodsreceived_trl gt ON gt.id = (item->>'gr_trl_id')::uuid
    WHERE gt.stock < (item->>'disp_qty')::integer;

    IF v_insufficient_stock IS NOT NULL THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'Insufficient stock: ' || v_insufficient_stock
        );
    END IF;

    -- CREATE DISPATCH RECORD
    INSERT INTO dispatch (
        disp_no, disp_date, registration, customer_id,
        customer_name, supervisor_id, supervisor_name, note,
        created_by, source_order_id, source_order_no
    ) VALUES (
        p_dispatch_data->>'disp_no',
        (p_dispatch_data->>'disp_date')::date::timestamptz,
        p_dispatch_data->>'registration',
        (p_dispatch_data->>'customer_id')::uuid,
        p_dispatch_data->>'customer_name',
        (p_dispatch_data->>'supervisor_id')::uuid,
        p_dispatch_data->>'supervisor_name',
        p_dispatch_data->>'note',
        v_user_id,
        v_source_order_id,
        v_source_order_no  -- Now uses auto-looked-up value
    ) RETURNING id INTO v_dispatch_id;

    -- BULK UPDATE STOCK
    UPDATE goodsreceived_trl gt
    SET stock = gt.stock - (item->>'disp_qty')::integer
    FROM unnest(p_dispatch_items) AS item
    WHERE gt.id = (item->>'gr_trl_id')::uuid;

    -- BULK INSERT DISPATCH ITEMS
    INSERT INTO dispatch_trl (gr_id, gr_trl_id, disp_id, disp_qty)
    SELECT
        gt.gr_id,
        (item->>'gr_trl_id')::uuid,
        v_dispatch_id,
        (item->>'disp_qty')::integer
    FROM unnest(p_dispatch_items) WITH ORDINALITY AS t(item, ord)
    JOIN goodsreceived_trl gt ON gt.id = (item->>'gr_trl_id')::uuid
    ORDER BY t.ord;

    -- GET UNIQUE GR_IDS
    SELECT ARRAY(
        SELECT DISTINCT gt.gr_id
        FROM unnest(p_dispatch_items) AS item
        JOIN goodsreceived_trl gt ON gt.id = (item->>'gr_trl_id')::uuid
    ) INTO v_affected_gr_ids;

    -- BULK INSERT STOCK MOVEMENTS
    INSERT INTO stock_movements (
        gr_trl_id, movement_type, quantity,
        reference_id, reference_type,
        balance_before, balance_after, created_by
    )
    SELECT
        (item->>'gr_trl_id')::uuid,
        'dispatch',
        -(item->>'disp_qty')::integer,
        v_dispatch_id,
        'dispatch',
        gt.stock + (item->>'disp_qty')::integer,
        gt.stock,
        v_user_id
    FROM unnest(p_dispatch_items) AS item
    JOIN goodsreceived_trl gt ON gt.id = (item->>'gr_trl_id')::uuid;

    -- BULK UPDATE OUT_OF_STOCK STATUS
    UPDATE goodsreceived gr
    SET out_of_stock = NOT EXISTS (
        SELECT 1 FROM goodsreceived_trl grt
        WHERE grt.gr_id = gr.id AND grt.stock > 0
    )
    WHERE gr.id = ANY(v_affected_gr_ids);

    -- BUILD DISPATCH ITEMS RESPONSE
    SELECT ARRAY(
        SELECT jsonb_build_object(
            'id', dt.id,
            'gr_id', dt.gr_id,
            'gr_trl_id', dt.gr_trl_id,
            'disp_id', dt.disp_id,
            'disp_qty', dt.disp_qty,
            'item_name', COALESCE(i.name, grt.item_name),
            'packaging', grt.packaging,
            'rack', grt.rack,
            'package_mark', grt.package_mark,
            'weight', grt.weight,
            'remaining_stock', grt.stock
        )
        FROM dispatch_trl dt
        JOIN goodsreceived_trl grt ON grt.id = dt.gr_trl_id
        LEFT JOIN items i ON i.id = grt.item_id
        WHERE dt.disp_id = v_dispatch_id
    ) INTO v_dispatch_items_result;

    -- INVOICE GENERATION (if requested)
    IF p_generate_invoice THEN
        v_invoice_data := '{}'::jsonb;
        v_all_gr_ids := v_affected_gr_ids;

        FOREACH v_gr_id IN ARRAY v_all_gr_ids
        LOOP
            SELECT gr.customer_id, c.auto_invoice_generation
            INTO v_grn_customer_id, v_is_invoiceable
            FROM goodsreceived gr
            JOIN customers c ON c.id = gr.customer_id
            WHERE gr.id = v_gr_id;

            IF v_is_invoiceable THEN
                v_single_invoice_data := generate_invoice_data_for_grn_with_pricing(v_gr_id);
                IF (v_single_invoice_data->>'success')::boolean = true THEN
                    v_invoice_data := v_invoice_data || jsonb_build_object(v_gr_id::text, v_single_invoice_data);
                END IF;
            END IF;
        END LOOP;
    END IF;

    -- ORDER/CART HANDLING (PERSISTENT CART MODEL)
    IF v_source_order_id IS NOT NULL THEN
        -- FROM ORDER dispatch: Delete or reduce cart items, keep order OPEN
        FOREACH v_item IN ARRAY p_dispatch_items
        LOOP
            v_gr_trl_id := (v_item->>'gr_trl_id')::uuid;
            v_dispatched_qty := (v_item->>'disp_qty')::integer;

            SELECT id, requested_quantity
            INTO v_cart_item_id, v_cart_current_qty
            FROM order_items
            WHERE order_id = v_source_order_id AND grn_items_id = v_gr_trl_id
            LIMIT 1
            FOR UPDATE;

            -- Record on the dispatch line what it takes from the cart line (migration 67).
            UPDATE dispatch_trl
            SET source_type = 'cart',
                source_order_item_id = v_cart_item_id,
                cart_quantity_consumed = CASE WHEN v_cart_item_id IS NULL THEN 0
                                              ELSE LEAST(v_cart_current_qty, v_dispatched_qty) END
            WHERE disp_id = v_dispatch_id AND gr_trl_id = v_gr_trl_id;

            IF v_cart_item_id IS NOT NULL THEN
                v_cart_new_qty := GREATEST(0, v_cart_current_qty - v_dispatched_qty);
                IF v_cart_new_qty = 0 THEN
                    DELETE FROM order_items WHERE id = v_cart_item_id;
                ELSE
                    UPDATE order_items
                    SET requested_quantity = v_cart_new_qty,
                        fulfilled_quantity = 0,
                        item_status = 'pending',
                        updated_at = NOW()
                    WHERE id = v_cart_item_id;
                END IF;
            END IF;
        END LOOP;

        UPDATE orders
        SET status = 'OPEN',
            updated_at = NOW(),
            updated_by = v_user_id
        WHERE id = v_source_order_id;
    ELSE
        -- DIRECT DISPATCH: Reduce cart quantities
        FOREACH v_item IN ARRAY p_dispatch_items
        LOOP
            v_gr_trl_id := (v_item->>'gr_trl_id')::uuid;
            v_dispatched_qty := (v_item->>'disp_qty')::integer;

            SELECT gr.customer_id INTO v_grn_customer_id
            FROM goodsreceived_trl grt
            JOIN goodsreceived gr ON gr.id = grt.gr_id
            WHERE grt.id = v_gr_trl_id;

            IF v_grn_customer_id IS NOT NULL THEN
                SELECT id INTO v_cart_id
                FROM orders
                WHERE customer_id = v_grn_customer_id AND status = 'OPEN' AND deleted_at IS NULL
                ORDER BY created_at, id
                LIMIT 1;

                IF v_cart_id IS NOT NULL THEN
                    SELECT id, requested_quantity, fulfilled_quantity
                    INTO v_cart_item_id, v_cart_current_qty, v_cart_fulfilled_qty
                    FROM order_items
                    WHERE order_id = v_cart_id AND grn_items_id = v_gr_trl_id
                    LIMIT 1
                    FOR UPDATE;

                    -- Record on the dispatch line what it takes from the cart line (migration 67).
                    UPDATE dispatch_trl
                    SET source_order_item_id = v_cart_item_id,
                        cart_quantity_consumed = CASE WHEN v_cart_item_id IS NULL THEN 0
                                                      ELSE LEAST(v_cart_current_qty, v_dispatched_qty) END
                    WHERE disp_id = v_dispatch_id AND gr_trl_id = v_gr_trl_id;

                    IF v_cart_item_id IS NOT NULL THEN
                        v_cart_new_qty := GREATEST(0, v_cart_current_qty - v_dispatched_qty);
                        IF v_cart_new_qty = 0 THEN
                            DELETE FROM order_items WHERE id = v_cart_item_id;
                        ELSE
                            UPDATE order_items
                            SET requested_quantity = v_cart_new_qty,
                                fulfilled_quantity = GREATEST(0, COALESCE(v_cart_fulfilled_qty, 0) - v_dispatched_qty)
                            WHERE id = v_cart_item_id;
                        END IF;
                    END IF;
                END IF;
            END IF;
        END LOOP;
    END IF;

    -- Build result
    v_cached_response := jsonb_build_object(
        'success', true,
        'dispatch_id', v_dispatch_id,
        'dispatch_items', to_jsonb(v_dispatch_items_result),
        'invoice_data', COALESCE(v_invoice_data, '{}'::jsonb),
        'message', 'Dispatch created successfully',
        'source_order_cleared', v_source_order_id IS NOT NULL
    );

    -- Cache the response if idempotency key provided
    IF p_idempotency_key IS NOT NULL THEN
        -- Kept for the 24 hours a retry is answered from it. A key another
        -- function or user holds is left alone unless it has expired.
        INSERT INTO idempotency_keys (idempotency_key, rpc_function, response, created_by, expires_at)
        VALUES (p_idempotency_key, 'create_dispatch_with_stock_check', v_cached_response, v_user_id, NOW() + INTERVAL '24 hours')
        ON CONFLICT (idempotency_key) DO UPDATE SET
            rpc_function = EXCLUDED.rpc_function,
            response = EXCLUDED.response,
            created_by = EXCLUDED.created_by,
            created_at = NOW(),
            expires_at = EXCLUDED.expires_at
        WHERE idempotency_keys.expires_at <= NOW()
           OR (idempotency_keys.rpc_function = EXCLUDED.rpc_function
               AND idempotency_keys.created_by IS NOT DISTINCT FROM EXCLUDED.created_by);
    END IF;

    RETURN v_cached_response;

EXCEPTION
    WHEN OTHERS THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', SQLERRM,
            'error_code', SQLSTATE
        );
END;
$$;

CREATE OR REPLACE FUNCTION public.update_dispatch_smart(p_dispatch_id uuid, p_dispatch_data jsonb, p_dispatch_items jsonb[]) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'extensions', 'utils', 'pg_temp'
    AS $$
DECLARE
    v_user_id uuid;
    v_invoiced_items text;
    v_insufficient_stock text;
    v_foreign_lots text;
    v_affected_gr_ids uuid[];
    v_dispatch_items_result jsonb[];
BEGIN
  PERFORM warehouse_security.authorize_rpc('update_dispatch_smart',jsonb_build_object('p_dispatch_id',p_dispatch_id));
  PERFORM warehouse_security.require_person_supervisor(p_dispatch_data->>'supervisor_id',
    (SELECT supervisor_id FROM dispatch WHERE id = p_dispatch_id));
    -- The list-refresh lock comes before any row lock (migration 46).
    PERFORM pg_advisory_xact_lock(71040);
    -- Check if user is admin or supervisor
    IF NOT warehouse_security.active_role() IN ('admin','supervisor','staff') THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'Only administrators and supervisors can update dispatches'
        );
    END IF;

    -- Get current user
    SELECT id INTO v_user_id FROM user_profiles WHERE auth_user_id = auth.uid();

    IF p_dispatch_data->>'disp_no' IS NOT NULL AND warehouse_security.is_blank_text(p_dispatch_data->>'disp_no') THEN
        RAISE EXCEPTION 'disp_no is required' USING ERRCODE = 'WH409';
    END IF;

    -- Every line names a lot that exists and a whole quantity above zero.
    IF EXISTS (
        SELECT 1 FROM unnest(p_dispatch_items) AS new_item
        WHERE NOT EXISTS (
            SELECT 1 FROM goodsreceived_trl gt WHERE gt.id = (new_item->>'gr_trl_id')::uuid
        )
    ) THEN
        RAISE EXCEPTION 'Dispatch item does not exist in inventory' USING ERRCODE = 'WH409';
    END IF;
    IF EXISTS (
        SELECT 1 FROM unnest(p_dispatch_items) AS new_item
        WHERE new_item->>'disp_qty' IS NULL
           OR (new_item->>'disp_qty')::numeric <= 0
           OR (new_item->>'disp_qty')::numeric <> floor((new_item->>'disp_qty')::numeric)
    ) THEN
        RAISE EXCEPTION 'Dispatch quantity must be a whole number greater than 0' USING ERRCODE = 'WH409';
    END IF;

    -- A lot appears once in the dispatch lines (migration 87).
    IF EXISTS (
        SELECT 1 FROM unnest(p_dispatch_items) AS d
        GROUP BY (d->>'gr_trl_id')::uuid HAVING count(*) > 1
    ) THEN
        RAISE EXCEPTION 'The same lot appears twice in the dispatch lines' USING ERRCODE = 'WH409';
    END IF;

    -- A dispatch carries only its own customer's lots: a line this edit adds
    -- must belong to the dispatch customer, and the customer may change only
    -- when every line the edit leaves belongs to the new one. The receipts are
    -- key-share locked so update_grn cannot move one to another customer meanwhile.
    PERFORM gr.id
    FROM goodsreceived gr
    WHERE gr.id IN (
        SELECT gt.gr_id
        FROM unnest(p_dispatch_items) AS new_item
        JOIN goodsreceived_trl gt ON gt.id = (new_item->>'gr_trl_id')::uuid
        UNION
        SELECT dt.gr_id FROM dispatch_trl dt WHERE dt.disp_id = p_dispatch_id
    )
    FOR KEY SHARE OF gr;

    SELECT string_agg(gt.item_name || ' (' || gr.gr_no || ')', ', ')
    INTO v_foreign_lots
    FROM dispatch d
    JOIN LATERAL (
        -- Lines the edit leaves: the new list, or the present lines when no list is sent
        SELECT (new_item->>'gr_trl_id')::uuid AS gr_trl_id
        FROM unnest(p_dispatch_items) AS new_item
        UNION
        SELECT dt.gr_trl_id FROM dispatch_trl dt
        WHERE dt.disp_id = d.id AND p_dispatch_items IS NULL
    ) AS kept ON true
    JOIN goodsreceived_trl gt ON gt.id = kept.gr_trl_id
    JOIN goodsreceived gr ON gr.id = gt.gr_id
    WHERE d.id = p_dispatch_id
    AND gr.customer_id IS DISTINCT FROM COALESCE((p_dispatch_data->>'customer_id')::uuid, d.customer_id)
    AND (
        -- The header customer is changing
        d.customer_id IS DISTINCT FROM COALESCE((p_dispatch_data->>'customer_id')::uuid, d.customer_id)
        OR
        -- The line is being added
        NOT EXISTS (
            SELECT 1 FROM dispatch_trl dt
            WHERE dt.disp_id = d.id AND dt.gr_trl_id = kept.gr_trl_id
        )
    );

    IF v_foreign_lots IS NOT NULL THEN
        IF EXISTS (
            SELECT 1 FROM dispatch d
            WHERE d.id = p_dispatch_id
            AND d.customer_id IS DISTINCT FROM COALESCE((p_dispatch_data->>'customer_id')::uuid, d.customer_id)
        ) THEN
            RAISE EXCEPTION 'Cannot change the dispatch customer: items belong to another customer: %', v_foreign_lots USING ERRCODE = 'WH409';
        END IF;
        RAISE EXCEPTION 'Item belongs to another customer: %', v_foreign_lots USING ERRCODE = 'WH409';
    END IF;

    -- A dispatch made from a cart stays with the cart's customer (migration 87).
    IF EXISTS (
        SELECT 1 FROM dispatch d
        WHERE d.id = p_dispatch_id
        AND d.source_order_id IS NOT NULL
        AND COALESCE((p_dispatch_data->>'customer_id')::uuid, d.customer_id) IS DISTINCT FROM d.customer_id
        AND COALESCE((p_dispatch_data->>'customer_id')::uuid, d.customer_id)
            IS DISTINCT FROM (SELECT o.customer_id FROM orders o WHERE o.id = d.source_order_id)
    ) THEN
        RAISE EXCEPTION 'The order belongs to another customer' USING ERRCODE = 'WH409';
    END IF;

    -- Update dispatch header if data provided (single statement - OK)
    IF p_dispatch_data IS NOT NULL THEN
        UPDATE dispatch SET
            disp_no = COALESCE(p_dispatch_data->>'disp_no', disp_no),
            disp_date = COALESCE((p_dispatch_data->>'disp_date')::date::timestamptz, disp_date),
            registration = COALESCE(p_dispatch_data->>'registration', registration),
            customer_id = COALESCE((p_dispatch_data->>'customer_id')::uuid, customer_id),
            customer_name = COALESCE(p_dispatch_data->>'customer_name', customer_name),
            supervisor_id = COALESCE((p_dispatch_data->>'supervisor_id')::uuid, supervisor_id),
            supervisor_name = COALESCE(p_dispatch_data->>'supervisor_name', supervisor_name),
            note = COALESCE(p_dispatch_data->>'note', note),
            updated_by = v_user_id,
            updated_at = NOW()
        WHERE id = p_dispatch_id;
    END IF;

    -- Handle items if provided
    IF p_dispatch_items IS NOT NULL THEN
        -- ========== STEP 1: VALIDATION - Check invoiced items ==========
        -- Check if any items being modified or deleted are invoiced
        SELECT string_agg(gt.item_name, ', ')
        INTO v_invoiced_items
        FROM dispatch_trl dt
        JOIN goodsreceived_trl gt ON gt.id = dt.gr_trl_id
        WHERE dt.disp_id = p_dispatch_id
        AND EXISTS (SELECT 1 FROM invoice_trl WHERE disp_trl_id = dt.id)
        AND (
            -- Item is being deleted (not in new list)
            NOT EXISTS (
                SELECT 1 FROM unnest(p_dispatch_items) AS new_item
                WHERE (new_item->>'gr_trl_id')::uuid = dt.gr_trl_id
            )
            OR
            -- Item qty is being changed
            EXISTS (
                SELECT 1 FROM unnest(p_dispatch_items) AS new_item
                WHERE (new_item->>'gr_trl_id')::uuid = dt.gr_trl_id
                AND (new_item->>'disp_qty')::integer != dt.disp_qty
            )
        );

        IF v_invoiced_items IS NOT NULL THEN
            RAISE EXCEPTION 'Cannot modify invoiced items: %', v_invoiced_items USING ERRCODE = 'WH409';
        END IF;

        -- ========== STEP 2: LOCK all affected GRN items ==========
        PERFORM gt.id
        FROM goodsreceived_trl gt
        WHERE gt.id IN (
            -- Existing items in dispatch
            SELECT dt.gr_trl_id FROM dispatch_trl dt WHERE dt.disp_id = p_dispatch_id
            UNION
            -- New items being added
            SELECT (new_item->>'gr_trl_id')::uuid FROM unnest(p_dispatch_items) AS new_item
        )
        FOR UPDATE OF gt;

        -- ========== STEP 3: VALIDATE stock for increases and new items ==========
        SELECT string_agg(
            gt.item_name || ' (Available: ' || gt.stock || ', Need: ' || needed.additional || ')',
            ', '
        )
        INTO v_insufficient_stock
        FROM (
            -- New items need full qty
            SELECT (new_item->>'gr_trl_id')::uuid AS gr_trl_id,
                   (new_item->>'disp_qty')::integer AS additional
            FROM unnest(p_dispatch_items) AS new_item
            WHERE NOT EXISTS (
                SELECT 1 FROM dispatch_trl dt
                WHERE dt.disp_id = p_dispatch_id
                AND dt.gr_trl_id = (new_item->>'gr_trl_id')::uuid
            )
            UNION ALL
            -- Existing items with qty increase need the difference
            SELECT dt.gr_trl_id,
                   (new_item->>'disp_qty')::integer - dt.disp_qty AS additional
            FROM dispatch_trl dt
            JOIN unnest(p_dispatch_items) AS new_item ON (new_item->>'gr_trl_id')::uuid = dt.gr_trl_id
            WHERE dt.disp_id = p_dispatch_id
            AND (new_item->>'disp_qty')::integer > dt.disp_qty
        ) AS needed
        JOIN goodsreceived_trl gt ON gt.id = needed.gr_trl_id
        WHERE gt.stock < needed.additional;

        IF v_insufficient_stock IS NOT NULL THEN
            RAISE EXCEPTION 'Insufficient stock: %', v_insufficient_stock USING ERRCODE = 'WH409';
        END IF;

        -- ========== STEP 4: Collect affected GR_IDs for out_of_stock update ==========
        SELECT ARRAY(
            SELECT DISTINCT gr_id FROM (
                SELECT dt.gr_id FROM dispatch_trl dt WHERE dt.disp_id = p_dispatch_id
                UNION
                SELECT gt.gr_id FROM unnest(p_dispatch_items) AS new_item
                JOIN goodsreceived_trl gt ON gt.id = (new_item->>'gr_trl_id')::uuid
            ) AS all_gr_ids
        ) INTO v_affected_gr_ids;

        -- ========== STEP 5: BULK restore stock for DELETED items ==========
        UPDATE goodsreceived_trl gt
        SET stock = gt.stock + dt.disp_qty
        FROM dispatch_trl dt
        WHERE dt.disp_id = p_dispatch_id
        AND gt.id = dt.gr_trl_id
        AND NOT EXISTS (
            SELECT 1 FROM unnest(p_dispatch_items) AS new_item
            WHERE (new_item->>'gr_trl_id')::uuid = dt.gr_trl_id
        );

        -- ========== STEP 6: BULK log movements for DELETED items ==========
        INSERT INTO stock_movements (gr_trl_id, movement_type, quantity, reference_id, reference_type, balance_before, balance_after, created_by, notes)
        SELECT
            dt.gr_trl_id,
            'return',
            dt.disp_qty,
            dt.id,
            'dispatch_item_delete',
            gt.stock - dt.disp_qty,  -- balance_before (stock was already restored)
            gt.stock,                 -- balance_after
            v_user_id,
            'Item removed from dispatch'
        FROM dispatch_trl dt
        JOIN goodsreceived_trl gt ON gt.id = dt.gr_trl_id
        WHERE dt.disp_id = p_dispatch_id
        AND NOT EXISTS (
            SELECT 1 FROM unnest(p_dispatch_items) AS new_item
            WHERE (new_item->>'gr_trl_id')::uuid = dt.gr_trl_id
        );

        -- ========== STEP 7: BULK delete removed items ==========
        DELETE FROM dispatch_trl dt
        WHERE dt.disp_id = p_dispatch_id
        AND NOT EXISTS (
            SELECT 1 FROM unnest(p_dispatch_items) AS new_item
            WHERE (new_item->>'gr_trl_id')::uuid = dt.gr_trl_id
        );

        -- ========== STEP 8: BULK update stock for QTY CHANGES ==========
        UPDATE goodsreceived_trl gt
        SET stock = gt.stock - ((new_item->>'disp_qty')::integer - dt.disp_qty)
        FROM dispatch_trl dt
        JOIN unnest(p_dispatch_items) AS new_item ON (new_item->>'gr_trl_id')::uuid = dt.gr_trl_id
        WHERE dt.disp_id = p_dispatch_id
        AND gt.id = dt.gr_trl_id
        AND (new_item->>'disp_qty')::integer != dt.disp_qty;

        -- ========== STEP 9: BULK log movements for QTY CHANGES ==========
        INSERT INTO stock_movements (gr_trl_id, movement_type, quantity, reference_id, reference_type, balance_before, balance_after, created_by, notes)
        SELECT
            dt.gr_trl_id,
            CASE WHEN (new_item->>'disp_qty')::integer > dt.disp_qty THEN 'dispatch' ELSE 'return' END,
            -((new_item->>'disp_qty')::integer - dt.disp_qty),
            dt.id,
            'dispatch_update',
            gt.stock + ((new_item->>'disp_qty')::integer - dt.disp_qty),  -- balance_before
            gt.stock,  -- balance_after (already updated)
            v_user_id,
            format('Qty changed from %s to %s', dt.disp_qty, (new_item->>'disp_qty')::integer)
        FROM dispatch_trl dt
        JOIN unnest(p_dispatch_items) AS new_item ON (new_item->>'gr_trl_id')::uuid = dt.gr_trl_id
        JOIN goodsreceived_trl gt ON gt.id = dt.gr_trl_id
        WHERE dt.disp_id = p_dispatch_id
        AND (new_item->>'disp_qty')::integer != dt.disp_qty;

        -- ========== STEP 10: BULK update dispatch_trl quantities ==========
        UPDATE dispatch_trl dt
        SET disp_qty = (new_item->>'disp_qty')::integer
        FROM unnest(p_dispatch_items) AS new_item
        WHERE dt.disp_id = p_dispatch_id
        AND dt.gr_trl_id = (new_item->>'gr_trl_id')::uuid
        AND dt.disp_qty != (new_item->>'disp_qty')::integer;

        -- ========== STEP 11: BULK deduct stock for NEW items ==========
        UPDATE goodsreceived_trl gt
        SET stock = gt.stock - (new_item->>'disp_qty')::integer
        FROM unnest(p_dispatch_items) AS new_item
        WHERE gt.id = (new_item->>'gr_trl_id')::uuid
        AND NOT EXISTS (
            SELECT 1 FROM dispatch_trl dt
            WHERE dt.disp_id = p_dispatch_id
            AND dt.gr_trl_id = (new_item->>'gr_trl_id')::uuid
        );

        -- ========== STEP 12: BULK insert NEW dispatch items, and log a
        -- movement for exactly the rows inserted (migration 67) ==========
        -- A line added to a dispatch from the cart is marked 'cart' (it takes
        -- nothing from the cart, so nothing is given back for it on deletion).
        WITH inserted AS (
            INSERT INTO dispatch_trl (disp_id, gr_trl_id, gr_id, disp_qty, source_type)
            SELECT
                p_dispatch_id,
                (new_item->>'gr_trl_id')::uuid,
                gt.gr_id,
                (new_item->>'disp_qty')::integer,
                CASE WHEN EXISTS (SELECT 1 FROM dispatch d WHERE d.id = p_dispatch_id AND d.source_order_id IS NOT NULL)
                     THEN 'cart' ELSE 'direct' END
            FROM unnest(p_dispatch_items) WITH ORDINALITY AS t(new_item, ord)
            JOIN goodsreceived_trl gt ON gt.id = (new_item->>'gr_trl_id')::uuid
            WHERE NOT EXISTS (
                SELECT 1 FROM dispatch_trl dt
                WHERE dt.disp_id = p_dispatch_id
                AND dt.gr_trl_id = (new_item->>'gr_trl_id')::uuid
            )
            ORDER BY t.ord
            RETURNING gr_trl_id, disp_qty
        )
        INSERT INTO stock_movements (gr_trl_id, movement_type, quantity, reference_id, reference_type, balance_before, balance_after, created_by)
        SELECT
            ins.gr_trl_id,
            'dispatch',
            -ins.disp_qty,
            p_dispatch_id,
            'dispatch',
            gt.stock + ins.disp_qty,  -- balance_before
            gt.stock,  -- balance_after (already updated in step 11)
            v_user_id
        FROM inserted ins
        JOIN goodsreceived_trl gt ON gt.id = ins.gr_trl_id;

        -- ========== STEP 14: BULK update out_of_stock status ==========
        UPDATE goodsreceived gr
        SET out_of_stock = NOT EXISTS (
            SELECT 1 FROM goodsreceived_trl grt
            WHERE grt.gr_id = gr.id AND grt.stock > 0
        )
        WHERE gr.id = ANY(v_affected_gr_ids);

    END IF;

    -- ========== Build response (single query) ==========
    SELECT ARRAY(
        SELECT jsonb_build_object(
            'id', dt.id,
            'gr_trl_id', dt.gr_trl_id,
            'gr_id', dt.gr_id,
            'disp_qty', dt.disp_qty,
            'item_id', grt.item_id,
            'item_name', grt.item_name,
            'packaging', grt.packaging,
            'weight', grt.weight,
            'rack', grt.rack
        )
        FROM dispatch_trl dt
        JOIN goodsreceived_trl grt ON grt.id = dt.gr_trl_id
        WHERE dt.disp_id = p_dispatch_id
    ) INTO v_dispatch_items_result;

    RETURN jsonb_build_object(
        'success', true,
        'dispatch_id', p_dispatch_id,
        'dispatch_items', v_dispatch_items_result
    );

EXCEPTION
    WHEN OTHERS THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', SQLERRM
        );
END;
$$;

CREATE OR REPLACE FUNCTION public.save_invoice(p_invoice_data jsonb) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'extensions', 'utils', 'pg_temp'
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
    -- The list-refresh lock comes before any row lock (migration 46).
    PERFORM pg_advisory_xact_lock(71040);
  PERFORM set_config('warehouse.discount_reason', COALESCE(p_invoice_data->>'discount_reason', ''), true);
  PERFORM warehouse_security.note_zero_charge_request(NULL, p_invoice_data);
    SELECT id INTO v_user_id FROM user_profiles WHERE auth_user_id = auth.uid();

    v_invoice_header := COALESCE(p_invoice_data->'data'->'header', p_invoice_data->'header', '{}'::jsonb);
    v_invoice_items := COALESCE(p_invoice_data->'data'->'items', p_invoice_data->'data'->'rows', p_invoice_data->'items', p_invoice_data->'rows', '[]'::jsonb);
    v_duration_mode := public.validate_invoice_duration_mode(COALESCE(p_invoice_data->>'duration_mode', v_invoice_header->>'duration_mode'));

    v_invoice_number_text := COALESCE(v_invoice_header->>'invoice_number', p_invoice_data->>'inv_no');
    PERFORM warehouse_security.check_invoice_number(COALESCE(NULLIF(p_invoice_data->>'inv_no', ''),
        NULLIF(REGEXP_REPLACE(COALESCE(v_invoice_number_text, ''), '^.*-([0-9]+)$', '\1'), '')), NULL);
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

    PERFORM warehouse_security.claim_invoice_lines(NULL,
        COALESCE(v_invoice_header->>'grn_id', p_invoice_data->>'gr_id')::uuid,
        ARRAY(SELECT COALESCE(item->>'disp_trl_id', item->>'dispatches_items_id', item->>'dispatch_item_id')::uuid
              FROM jsonb_array_elements(v_invoice_items) AS item));

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
    FROM jsonb_array_elements(v_invoice_items) WITH ORDINALITY AS t(item, ord)
    JOIN dispatch_trl dt ON dt.id = COALESCE(item->>'disp_trl_id', item->>'dispatches_items_id', item->>'dispatch_item_id')::UUID
    JOIN dispatch disp ON disp.id = dt.disp_id
    JOIN goodsreceived gr ON gr.id = dt.gr_id
    CROSS JOIN LATERAL public.calculate_invoice_duration(warehouse_security.business_date(gr.date), warehouse_security.business_date(disp.disp_date), v_duration_mode) d
    ORDER BY t.ord;

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

CREATE OR REPLACE FUNCTION public.save_invoice_internal(p_invoice_id uuid, p_invoice_data jsonb, p_invoice_items jsonb[]) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE
    v_user_id UUID;
    v_new_gr_id UUID;
    v_invoice_number_for_resolution VARCHAR(20);
    v_invoice_creation_time TIMESTAMPTZ;
    v_invoice_date TIMESTAMPTZ;
    v_resolved_errors_count INTEGER := 0;
    v_new_items_count INTEGER := 0;
    v_final_invoice_id UUID;
    v_is_auto_generated BOOLEAN;
    v_duration_mode text;
    v_discount NUMERIC(12,2) := COALESCE(NULLIF(p_invoice_data->>'discount', '')::NUMERIC(12,2), 0::NUMERIC(12,2));
    v_function_version TEXT := 'save_invoice_v20260503_duration_mode';
BEGIN
    SELECT id INTO v_user_id FROM user_profiles WHERE auth_user_id = auth.uid();
    v_new_gr_id := (p_invoice_data->>'gr_id')::uuid;
    v_invoice_creation_time := NOW();
    v_invoice_date := COALESCE((p_invoice_data->>'inv_date')::TIMESTAMPTZ, NOW());
    v_invoice_number_for_resolution := (p_invoice_data->>'inv_no');
    v_is_auto_generated := COALESCE((p_invoice_data->>'is_auto_generated')::boolean, false);
    v_duration_mode := public.validate_invoice_duration_mode(p_invoice_data->>'duration_mode');
    PERFORM warehouse_security.claim_invoice_lines(NULL, v_new_gr_id,
        ARRAY(SELECT (item->>'disp_trl_id')::uuid FROM unnest(p_invoice_items) AS item));

    IF p_invoice_id IS NOT NULL THEN
        INSERT INTO invoice (
            id, inv_fin_year, inv_no, gr_id, gr_no,
            customer_id, customer_name, inv_date,
            labour, tax_amount, total, discount,
            one_time_charge, notes, created_by, is_auto_generated, duration_mode
        ) VALUES (
            p_invoice_id,
            (p_invoice_data->>'inv_fin_year')::integer,
            (p_invoice_data->>'inv_no')::integer,
            v_new_gr_id,
            p_invoice_data->>'gr_no',
            (p_invoice_data->>'customer_id')::uuid,
            p_invoice_data->>'customer_name',
            v_invoice_date,
            0::NUMERIC(12,2),
            0::NUMERIC(12,2),
            0::NUMERIC(12,2),
            v_discount,
            COALESCE((p_invoice_data->>'one_time_charge')::boolean, false),
            p_invoice_data->>'notes',
            v_user_id,
            v_is_auto_generated,
            v_duration_mode
        );
        v_final_invoice_id := p_invoice_id;
    ELSE
        INSERT INTO invoice (
            inv_fin_year, inv_no, gr_id, gr_no,
            customer_id, customer_name, inv_date,
            labour, tax_amount, total, discount,
            one_time_charge, notes, created_by, is_auto_generated, duration_mode
        ) VALUES (
            (p_invoice_data->>'inv_fin_year')::integer,
            (p_invoice_data->>'inv_no')::integer,
            v_new_gr_id,
            p_invoice_data->>'gr_no',
            (p_invoice_data->>'customer_id')::uuid,
            p_invoice_data->>'customer_name',
            v_invoice_date,
            0::NUMERIC(12,2),
            0::NUMERIC(12,2),
            0::NUMERIC(12,2),
            v_discount,
            COALESCE((p_invoice_data->>'one_time_charge')::boolean, false),
            p_invoice_data->>'notes',
            v_user_id,
            v_is_auto_generated,
            v_duration_mode
        ) RETURNING id INTO v_final_invoice_id;
    END IF;

    INSERT INTO invoice_trl (invoice_id, disp_trl_id, duration, no_of_days, charge, tax, labour_rate)
    SELECT
        v_final_invoice_id,
        (item->>'disp_trl_id')::uuid,
        d.duration,
        d.no_of_days,
        COALESCE(NULLIF(item->>'charge', '')::NUMERIC(12,2), NULLIF(item->>'unit_price', '')::NUMERIC(12,2)),
        COALESCE(NULLIF(item->>'tax', '')::NUMERIC(12,2), NULLIF(item->>'tax_percent', '')::NUMERIC(12,2)),
        (item->>'labour_rate')::numeric
    FROM unnest(p_invoice_items) WITH ORDINALITY AS t(item, ord)
    JOIN dispatch_trl dt ON dt.id = (item->>'disp_trl_id')::uuid
    JOIN dispatch disp ON disp.id = dt.disp_id
    JOIN goodsreceived gr ON gr.id = dt.gr_id
    CROSS JOIN LATERAL public.calculate_invoice_duration(warehouse_security.business_date(gr.date), warehouse_security.business_date(disp.disp_date), v_duration_mode) d
    ORDER BY t.ord;

    GET DIAGNOSTICS v_new_items_count = ROW_COUNT;
    PERFORM warehouse_security.assert_invoice_lines(v_final_invoice_id, v_new_gr_id,
        (p_invoice_data->>'customer_id')::uuid, COALESCE(array_length(p_invoice_items, 1), 0));
    PERFORM warehouse_security.recalculate_invoice_header(v_final_invoice_id);

    UPDATE goodsreceived SET invoiced = true WHERE id = v_new_gr_id;

    UPDATE auto_invoice_errors
    SET
        resolved_at = v_invoice_creation_time,
        resolved_invoice_id = v_final_invoice_id,
        error_details = COALESCE(error_details, '{}')::jsonb ||
                       jsonb_build_object(
                           'resolution_type', 'manual_invoice_created',
                           'resolution_notes', 'Invoice created manually through save_invoice',
                           'invoice_id', v_final_invoice_id,
                           'invoice_number', v_invoice_number_for_resolution,
                           'invoice_date', v_invoice_date,
                           'gr_id', v_new_gr_id
                       )
    WHERE gr_id = v_new_gr_id
    AND resolved_at IS NULL;

    GET DIAGNOSTICS v_resolved_errors_count = ROW_COUNT;

    RETURN jsonb_build_object(
        'success', true,
        'invoice_id', v_final_invoice_id,
        'invoice_number', v_invoice_number_for_resolution,
        'items_count', v_new_items_count,
        'resolved_errors_count', v_resolved_errors_count,
        'is_auto_generated', v_is_auto_generated,
        'duration_mode', v_duration_mode,
        'function_version', v_function_version
    );
EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object(
        'success', false,
        'error', SQLERRM,
        'error_code', SQLSTATE,
        'function_version', v_function_version
    );
END;
$$;

CREATE OR REPLACE FUNCTION public.update_invoice(p_invoice_id uuid, p_invoice_data jsonb, p_invoice_items jsonb[]) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'extensions', 'utils', 'pg_temp'
    AS $$
DECLARE
    v_user_id UUID;
    v_new_gr_id UUID;
    v_old_gr_id UUID;
    v_discount NUMERIC(12,2);
    v_items_count INTEGER;
    v_duration_mode text;
    v_invoice_no integer;
BEGIN
  PERFORM warehouse_security.authorize_rpc('update_invoice',jsonb_build_object('p_invoice_id',p_invoice_id));
    -- The list-refresh lock comes before any row lock (migration 46).
    PERFORM pg_advisory_xact_lock(71040);
  PERFORM set_config('warehouse.discount_reason', COALESCE(p_invoice_data->>'discount_reason', ''), true);
  PERFORM warehouse_security.note_zero_charge_request(p_invoice_id, p_invoice_data);
  PERFORM warehouse_security.check_invoice_number(p_invoice_data->>'inv_no', p_invoice_id);
    SELECT id INTO v_user_id FROM user_profiles WHERE auth_user_id = auth.uid();
    v_discount := COALESCE(NULLIF(p_invoice_data->>'discount', '')::NUMERIC(12,2), 0::NUMERIC(12,2));
    v_new_gr_id := (p_invoice_data->>'gr_id')::uuid;
    v_duration_mode := public.validate_invoice_duration_mode(p_invoice_data->>'duration_mode');

    SELECT gr_id INTO v_old_gr_id FROM invoice WHERE id = p_invoice_id AND deleted_at IS NULL;

    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'error', 'Invoice not found');
    END IF;

    PERFORM warehouse_security.claim_invoice_lines(p_invoice_id, v_new_gr_id,
        ARRAY(SELECT (item->>'disp_trl_id')::uuid FROM unnest(p_invoice_items) AS item));

    IF v_old_gr_id IS DISTINCT FROM v_new_gr_id THEN
        IF v_old_gr_id IS NOT NULL THEN
            UPDATE goodsreceived SET invoiced = false WHERE id = v_old_gr_id;
        END IF;

        IF v_new_gr_id IS NOT NULL THEN
            UPDATE goodsreceived SET invoiced = true WHERE id = v_new_gr_id;
        END IF;
    END IF;

    UPDATE invoice SET
        inv_fin_year = (p_invoice_data->>'inv_fin_year')::integer,
        inv_no = (p_invoice_data->>'inv_no')::integer,
        gr_id = v_new_gr_id,
        gr_no = p_invoice_data->>'gr_no',
        customer_id = (p_invoice_data->>'customer_id')::uuid,
        customer_name = p_invoice_data->>'customer_name',
        inv_date = (p_invoice_data->>'inv_date')::TIMESTAMPTZ,
        labour = 0,
        tax_amount = 0,
        total = 0,
        discount = v_discount,
        one_time_charge = COALESCE((p_invoice_data->>'one_time_charge')::boolean, false),
        notes = p_invoice_data->>'notes',
        duration_mode = v_duration_mode
    WHERE id = p_invoice_id
    RETURNING inv_no INTO v_invoice_no;

    DELETE FROM invoice_trl WHERE invoice_id = p_invoice_id;

    INSERT INTO invoice_trl (invoice_id, disp_trl_id, duration, no_of_days, charge, tax, labour_rate)
    SELECT
        p_invoice_id,
        (item->>'disp_trl_id')::uuid,
        d.duration,
        d.no_of_days,
        COALESCE(NULLIF(item->>'charge', '')::NUMERIC(12,2), NULLIF(item->>'unit_price', '')::NUMERIC(12,2)),
        COALESCE(NULLIF(item->>'tax', '')::NUMERIC(12,2), NULLIF(item->>'tax_percent', '')::NUMERIC(12,2)),
        (item->>'labour_rate')::numeric
    FROM unnest(p_invoice_items) WITH ORDINALITY AS t(item, ord)
    JOIN dispatch_trl dt ON dt.id = (item->>'disp_trl_id')::uuid
    JOIN dispatch disp ON disp.id = dt.disp_id
    JOIN goodsreceived gr ON gr.id = dt.gr_id
    CROSS JOIN LATERAL public.calculate_invoice_duration(warehouse_security.business_date(gr.date), warehouse_security.business_date(disp.disp_date), v_duration_mode) d
    ORDER BY t.ord;

    GET DIAGNOSTICS v_items_count = ROW_COUNT;
    PERFORM warehouse_security.assert_invoice_lines(p_invoice_id, v_new_gr_id,
        (p_invoice_data->>'customer_id')::uuid, COALESCE(array_length(p_invoice_items, 1), 0));
    PERFORM warehouse_security.recalculate_invoice_header(p_invoice_id);

    RETURN jsonb_build_object(
        'success', true,
        'invoice_id', p_invoice_id,
        'invoice_no', v_invoice_no,
        'invoice_number', v_invoice_no,
        'items_count', v_items_count,
        'duration_mode', v_duration_mode,
        'message', 'Invoice updated successfully'
    );
EXCEPTION WHEN insufficient_privilege THEN RAISE;
WHEN OTHERS THEN
    RETURN jsonb_build_object('success', false, 'error', SQLERRM, 'error_code', SQLSTATE);
END;
$$;

-- Fix 4: dead objects are dropped; the one name that the staff allowlist held goes with them
CREATE OR REPLACE FUNCTION warehouse_security.authorize_rpc(rpc text, args jsonb) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public'
    AS $$
DECLARE role_name text := warehouse_security.active_role(); customer uuid; other_customer uuid; document uuid;
  removable boolean;
BEGIN
  IF auth.jwt()->>'role' = 'service_role' THEN RETURN; END IF;
  IF role_name IS NULL THEN RAISE EXCEPTION 'Active account required' USING ERRCODE = '42501'; END IF;
  -- User management: administrators, and supervisors for other people who are
  -- not administrators. The four bodies refuse a supervisor who targets an
  -- administrator or the own profile, or who grants the administrator role.
  IF rpc IN ('update_user_role','update_user_status','assign_customer_to_user','remove_customer_assignment') THEN
    IF role_name NOT IN ('admin','supervisor') THEN RAISE EXCEPTION 'Administrator required' USING ERRCODE = '42501'; END IF;
    RETURN;
  END IF;
  -- Central identity (migration 49), sensor settings (migration 74) and service accounts
  -- (migration 78): administrators only.
  IF rpc IN ('clear_user_central_identity','update_sensor_device','set_service_account') THEN
    IF role_name <> 'admin' THEN RAISE EXCEPTION 'Administrator required' USING ERRCODE = '42501'; END IF;
    RETURN;
  END IF;
  IF role_name IN ('admin','supervisor') THEN RETURN; END IF;
  -- Approved document RPCs only; no shared ownership or table-policy change.
  IF role_name = 'staff' AND rpc IN (
    'save_grn','update_grn','check_grn_exists','get_next_grn_number',
    'get_all_grn_items','get_grn_list','get_grn_details','get_grn_item_dispatches',
    'get_grn_prefixes_with_stock','get_all_grn_activity',
    'get_customer_grn_activity','get_customer_grn_items',
    'get_customer_grns_with_stock_dispatch_sorted',
    'search_customers','get_supervisors','get_vehicle_suggestions',
    'register_grn_image_upload','confirm_grn_image_upload',
    'cancel_grn_image_upload','upload_grn_image',
    'register_dispatch_image_upload','confirm_dispatch_image_upload',
    'cancel_dispatch_image_upload',
    'create_dispatch_with_stock_check','update_dispatch_smart',
    'check_dispatch_exists','get_next_dispatch_number','get_dispatch_autocomplete',
    'get_dispatch_details','get_dispatch_list_with_items',
    'get_all_dispatch_items','get_all_dispatch_activity','get_customer_dispatch_list',
    'get_customer_dispatch_items','get_recent_dispatched_orders',
    'save_invoice','update_invoice','get_next_invoice_number',
    'get_invoiceable_grns','get_invoices_list','get_invoice_data','get_invoice_detail',
    'get_invoice_items_detailed','get_customer_invoice_summary',
    'generate_invoice_data_for_grn_with_pricing',
    -- Orders and queue (user decision, 2026-10-09).
    'get_orders_list','get_order_with_items','get_or_create_cart',
    'add_item_to_order','update_order_item_quantity','remove_item_from_order',
    'get_cart_dispatches','search_customer_items_for_order',
    'get_customer_items_for_order_selection','get_order_change_log',
    -- Reports the app shows to staff (owner decision, 2026-10-11).
    'get_all_stock_summary','get_customer_stock_summary',
    'get_all_customer_activity_summary','get_customer_activity_detail',
    'get_customer_dispatch_activity','get_stock_aging_report','get_item_wise_stock_list',
    -- Item pricing is for administrators and supervisors (migration 90); staff keep
    -- only the rates a GRN is invoiced at (migration 88, below).
    -- The rate of each line of a GRN (migration 88).
    'get_grn_item_rates',
    -- Sensors (owner decision, 2026-10-11).
    'get_sensor_polling_data','get_sensor_history',
    -- One sensor (migration 74).
    'get_sensor_device'
  ) THEN RETURN; END IF;
  -- Photo removal in the edit forms (owner decision, 2026-10-11): a photo of a
  -- receipt or dispatch that staff can open for editing, and that is confirmed
  -- or was registered by the caller. Another person's pending upload stays
  -- with that person, as for cancel_*_image_upload (migration 23).
  IF role_name = 'staff' AND rpc IN ('delete_grn_image','delete_dispatch_image') THEN
    IF rpc = 'delete_grn_image' THEN
      SELECT COALESCE(g.deleted_at IS NULL AND (i.status = 'confirmed' OR i.uploaded_by = public.get_current_user_profile_id()), false)
        INTO removable FROM public.grn_images i JOIN public.goodsreceived g ON g.id = i.grn_id
        WHERE i.id = (args->>'p_image_id')::uuid;
    ELSE
      SELECT COALESCE(d.deleted_at IS NULL AND (i.status = 'confirmed' OR i.uploaded_by = public.get_current_user_profile_id()), false)
        INTO removable FROM public.dispatch_images i JOIN public.dispatch d ON d.id = i.dispatch_id
        WHERE i.id = (args->>'p_image_id')::uuid;
    END IF;
    -- An unknown id is answered by the function itself ("not found").
    IF removable IS FALSE THEN RAISE EXCEPTION 'Staff access required' USING ERRCODE = '42501'; END IF;
    RETURN;
  END IF;

  IF rpc IN ('get_items','get_item','search_items_autocomplete','get_orders_list','delete_user_account') THEN RETURN; END IF;
  -- get_stock_aging_report and get_item_wise_stock_list: with a customer id
  -- they are that customer's report; without one they are the all-customers
  -- report, which no customer account may run.
  IF rpc LIKE 'get_customer_%' OR rpc IN ('search_customer_items_for_order','get_or_create_cart',
      'get_stock_aging_report','get_item_wise_stock_list') THEN
    customer := COALESCE(args->>'p_customer_id', args->>'p_customer_uuid')::uuid;
  ELSIF rpc IN ('get_grn_details','get_grn_item_dispatches','get_grn_item_rates') THEN
    IF args ? 'p_grn_item_id' THEN
      SELECT g.customer_id INTO customer FROM public.goodsreceived_trl t JOIN public.goodsreceived g ON g.id=t.gr_id WHERE t.id=(args->>'p_grn_item_id')::uuid;
    ELSE SELECT customer_id INTO customer FROM public.goodsreceived WHERE id=(args->>'p_grn_id')::uuid; END IF;
  ELSIF rpc = 'get_dispatch_details' THEN
    SELECT customer_id INTO customer FROM public.dispatch WHERE id=(args->>'p_dispatch_id')::uuid;
  ELSIF rpc IN ('get_invoice_data','get_invoice_detail','get_invoice_items_detailed') THEN
    SELECT customer_id INTO customer FROM public.invoice WHERE id=(args->>'p_invoice_id')::uuid;
  ELSIF rpc IN ('get_order_with_items','get_cart_dispatches','add_item_to_order',
                'update_order_item_quantity','remove_item_from_order','get_order_change_log') THEN
    document := COALESCE(args->>'p_order_id', args->>'p_cart_id')::uuid;
    IF rpc IN ('update_order_item_quantity','remove_item_from_order') THEN
      SELECT order_id INTO document FROM public.order_items WHERE id=(args->>'p_order_item_id')::uuid;
    END IF;
    SELECT customer_id INTO customer FROM public.orders WHERE id=document;
    -- History may be requested for one customer instead of one order.
    IF rpc = 'get_order_change_log' AND document IS NULL THEN
      customer := (args->>'p_customer_id')::uuid;
    END IF;
    IF rpc = 'add_item_to_order' THEN
      SELECT g.customer_id INTO other_customer FROM public.goodsreceived_trl t JOIN public.goodsreceived g ON g.id=t.gr_id WHERE t.id=(args->>'p_grn_item_id')::uuid;
      IF other_customer IS DISTINCT FROM customer THEN RAISE EXCEPTION 'Item belongs to another customer' USING ERRCODE = '42501'; END IF;
    END IF;
  ELSE
    RAISE EXCEPTION 'Staff access required' USING ERRCODE = '42501';
  END IF;
  IF customer IS NULL OR NOT warehouse_security.owns_customer(customer) THEN
    RAISE EXCEPTION 'Customer access denied' USING ERRCODE = '42501';
  END IF;
END $$;

DROP VIEW public.customers_with_priority_contact;
DROP FUNCTION public.bulk_update_customers_priority_contact();
DROP FUNCTION public.phone_auth_login(character varying, character varying);
DROP FUNCTION public.verify_otp_secure(character varying, character varying, inet, text);
DROP FUNCTION public.verify_otp(character varying, character varying, character varying);
DROP FUNCTION public.get_priority_contact_for_customer(uuid);
DROP FUNCTION public.track_user_activity(character varying, inet, text);
DROP FUNCTION public.update_customer_contact_with_auth_phone();
-- The overload that inserted no price_type and so always failed NOT NULL; the p_price_type overload stays.
DROP FUNCTION public.create_item_storage_price(uuid, numeric, numeric, numeric, date, uuid, numeric, numeric, numeric, date);
DROP FUNCTION public.get_grn_autocomplete(text, integer);
