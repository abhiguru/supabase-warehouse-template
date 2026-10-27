-- public.get_invoice_data: the definition setup applies after the numbered migrations whenever this file's checksum changes
-- (scripts/migration-plan.mjs, table warehouse_migrations.definitions). Edit the function here, never in a new migration.
-- Starts as the function migrations 000 to 126 leave (the numbered files that patched it stay as they are, never edited).
CREATE OR REPLACE FUNCTION public.get_invoice_data(p_invoice_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'extensions', 'utils', 'pg_temp'
AS $function$
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
            i.updated_at as invoice_updated_at,

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
                    'updated_at', v_invoice_header.invoice_updated_at,

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
    $function$;

REVOKE ALL ON FUNCTION public.get_invoice_data(uuid) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.get_invoice_data(uuid) TO service_role, authenticated;
