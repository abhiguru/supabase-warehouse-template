-- public.get_invoice_detail: the definition setup applies after the numbered migrations whenever this file's checksum changes
-- (scripts/migration-plan.mjs, table warehouse_migrations.definitions). Edit the function here, never in a new migration.
-- Starts as the function migrations 000 to 126 leave (the numbered files that patched it stay as they are, never edited).
CREATE OR REPLACE FUNCTION public.get_invoice_detail(p_invoice_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'extensions', 'utils', 'pg_temp'
AS $function$
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
        'updated_at', i.updated_at,
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
$function$;

REVOKE ALL ON FUNCTION public.get_invoice_detail(uuid) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.get_invoice_detail(uuid) TO service_role, authenticated;
