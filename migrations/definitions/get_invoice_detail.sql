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
    v_cancelled boolean;
BEGIN
  PERFORM warehouse_security.authorize_rpc('get_invoice_detail',jsonb_build_object('p_invoice_id',p_invoice_id));
    SELECT jsonb_build_object(
        'id', i.id, 'inv_fin_year', i.inv_fin_year, 'inv_no', i.inv_no,
        'inv_prefix', i.inv_prefix, 'invoice_label', warehouse_security.invoice_label(i.inv_prefix, i.inv_no),
        'gr_id', i.gr_id, 'gr_no', i.gr_no, 'customer_id', i.customer_id,
        'customer_name', i.customer_name, 'inv_date', i.inv_date,
        'labour', i.labour, 'tax_amount', i.tax_amount, 'total', i.total,
        'discount', i.discount, 'one_time_charge', i.one_time_charge,
        'is_auto_generated', i.is_auto_generated, 'pricing_mode', i.pricing_mode,
        'duration_mode', COALESCE(i.duration_mode, 'legacy'),
        -- Migration 164: the charging rule the invoice was made with (before 164: half-month steps, 1 month minimum, rounded up).
        'charging', jsonb_build_object('step_days', i.charge_step_days, 'minimum_days', i.charge_minimum_days,
                                       'days_counted', COALESCE(i.duration_mode, 'legacy'), 'rounding', i.total_rounding),
        'notes', i.notes, 'created_by', i.created_by,
        'updated_at', i.updated_at,
        'cancelled_at', i.cancelled_at, 'cancel_reason', i.cancel_reason,
        -- WH-183: the effective mode. A cancelled invoice's lines keep the GRN's mode at the cancel (kept_pricing_mode, migration 178);
        -- when kept, that mode is returned instead of the GRN's current one, so the GST PDF and the app label the lines as charged.
        'grn_pricing_mode', COALESCE((SELECT k.kept_pricing_mode FROM invoice_trl k
                                       WHERE k.invoice_id = i.id AND k.kept_pricing_mode IS NOT NULL LIMIT 1),
                                     (SELECT gr.pricing_mode FROM goodsreceived gr WHERE gr.id = i.gr_id))
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
            'zero_charge_set_at', i.zero_charge_set_at,
            'cancelled_by', i.cancelled_by,
            'cancelled_by_name', (SELECT p.name FROM user_profiles p WHERE p.id = i.cancelled_by))
        ELSE '{}'::jsonb END
    INTO v_invoice_header FROM invoice i WHERE i.id = p_invoice_id AND i.deleted_at IS NULL;

    IF v_invoice_header IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'Invoice not found');
    END IF;

    v_cancelled := (v_invoice_header->>'cancelled_at') IS NOT NULL;

    -- Migration 172: what is paid and due, and the payments, for administrators, supervisors and the invoice's customer (authorize_rpc
    -- let the customer through for this invoice only); staff see nothing new.
    IF auth.jwt()->>'role' = 'service_role' OR COALESCE(warehouse_security.active_role(), '') <> 'staff' THEN
        v_invoice_header := v_invoice_header || warehouse_security.invoice_payment_state(p_invoice_id)
            || jsonb_build_object('payments', COALESCE((
                SELECT jsonb_agg(warehouse_security.payment_json(p)
                                 ORDER BY COALESCE(p.paid_on, warehouse_security.business_date(p.payment_date)), p.payment_date, p.payment_no)
                FROM payments p WHERE p.invoice_id = p_invoice_id), '[]'::jsonb));
    END IF;

    -- Migration 173: doc_type, linked_invoice (the other document of a two-document save) and, for every type but 'invoice', the gst
    -- object (what the document was made with, the tax split and each line's treatment and amounts).
    v_invoice_header := v_invoice_header || COALESCE(warehouse_security.invoice_gst_json(p_invoice_id), '{}'::jsonb);

    -- Migration 143: a cancelled invoice reads the details its lines kept at cancel (details_kept_at set); the copy wins over the current
    -- dispatch line, GRN and item. A line whose dispatch went before the copy existed is listed with its amounts and details_available false.
    -- A live invoice reads exactly as before: its lines still need every join to match, as the inner joins demanded.
    SELECT jsonb_agg(
        jsonb_build_object(
            'id', x.id,
            'invoice_id', x.invoice_id,
            'disp_trl_id', x.disp_trl_id,
            'duration', x.duration,
            'no_of_days', x.no_of_days,
            'charge', x.charge,
            'tax', x.tax,
            'labour_rate', x.labour_rate,
            -- Migration 164: the line's storage under the invoice's rule (null when the line has no quantity left to read).
            'storage_amount', CASE WHEN x.qty IS NULL THEN NULL
                                   WHEN COALESCE(x.kept_pricing_mode, v_invoice_header->>'grn_pricing_mode') = 'ONE_TIME' THEN round(COALESCE(x.charge, 0) * x.qty, 2)
                                   ELSE warehouse_security.invoice_storage_amount(x.invoice_id, COALESCE(x.charge, 0), x.qty,
                                                                                  COALESCE(x.duration, 1), x.no_of_days) END,
            'item_name', x.item_name,
            'packaging', x.packaging,
            'grn_item_id', x.grn_item_id,
            'grn_date', x.grn_date,
            'grn_no', x.grn_no,
            'qty', x.qty,
            'dispatch_no', x.dispatch_no,
            'dispatch_date', x.dispatch_date,
            'weight', x.weight,
            'grn_original_qty', x.grn_original_qty,
            'package_mark', x.package_mark,
            'item_id', x.item_id,
            'dispatch_id', x.dispatch_id,
            'rack', x.rack,
            'details_available', x.details_available
        ) ORDER BY x.item_name, x.dispatch_date, uuid_extract_timestamp(x.dt_id), x.dt_id, x.id
    ) INTO v_invoice_items
    FROM (
        SELECT it.id, it.invoice_id, it.disp_trl_id, it.duration, it.no_of_days, it.charge, it.tax, it.labour_rate,
               dt.id AS dt_id,
               CASE WHEN it.details_kept_at IS NOT NULL THEN it.kept_item_name ELSE gt.item_name END AS item_name,
               CASE WHEN it.details_kept_at IS NOT NULL THEN it.kept_packaging ELSE gt.packaging END AS packaging,
               gt.id AS grn_item_id,
               CASE WHEN it.details_kept_at IS NOT NULL THEN it.kept_grn_date ELSE gr.date END AS grn_date,
               CASE WHEN it.details_kept_at IS NOT NULL THEN it.kept_grn_no ELSE gr.gr_no END AS grn_no,
               CASE WHEN it.details_kept_at IS NOT NULL THEN it.kept_disp_qty ELSE dt.disp_qty END AS qty,
               CASE WHEN it.details_kept_at IS NOT NULL THEN it.kept_disp_no ELSE d.disp_no END AS dispatch_no,
               CASE WHEN it.details_kept_at IS NOT NULL THEN it.kept_disp_date ELSE d.disp_date END AS dispatch_date,
               it.kept_pricing_mode, -- WH-98 (migration 178): the GRN's mode when the invoice was cancelled
               CASE WHEN it.details_kept_at IS NOT NULL THEN it.kept_weight ELSE gt.weight END AS weight,
               gt.qty AS grn_original_qty,
               CASE WHEN it.details_kept_at IS NOT NULL THEN it.kept_package_mark ELSE gt.package_mark END AS package_mark,
               gt.item_id,
               d.id AS dispatch_id,
               CASE WHEN it.details_kept_at IS NOT NULL THEN it.kept_rack ELSE gt.rack END AS rack,
               (it.details_kept_at IS NOT NULL OR dt.id IS NOT NULL) AS details_available
        FROM invoice_trl it
        LEFT JOIN dispatch_trl dt ON it.disp_trl_id = dt.id
        LEFT JOIN dispatch d ON dt.disp_id = d.id
        LEFT JOIN goodsreceived_trl gt ON dt.gr_trl_id = gt.id
        LEFT JOIN goodsreceived gr ON gr.id = gt.gr_id
        WHERE it.invoice_id = p_invoice_id
          AND (v_cancelled OR (dt.id IS NOT NULL AND d.id IS NOT NULL AND gt.id IS NOT NULL AND gr.id IS NOT NULL))
    ) x;

    RETURN jsonb_build_object('success', true, 'invoice', v_invoice_header, 'items', COALESCE(v_invoice_items, '[]'::jsonb));
EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('success', false, 'error', SQLERRM);
END;
$function$;

REVOKE ALL ON FUNCTION public.get_invoice_detail(uuid) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.get_invoice_detail(uuid) TO service_role, authenticated;
