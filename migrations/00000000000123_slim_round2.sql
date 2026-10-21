-- Slimming round 2 (2026-10-21): dead SQL objects are dropped (the arch review of 2026-10-21, reader A). Nothing the app, central
-- identity, fas-sync, an edge function or an operator script calls is touched; the caller check was run again for every name
-- (the table is in the slimming notes, w1-droplist.md).
--  * 1. Five live functions are re-defined without a dead reference: generate_invoice_data_for_grn (the user_customers branch,
--       a table that does not exist), delete_grn_safe and save_invoice_internal (auto_invoice_errors; the answers keep their keys,
--       auto_invoice_errors and resolved_errors_count, as 0), delete_user_account and run_database_retention (user_session_activity,
--       auth_logs, config_access_logs, intrusion_events; the retention answer no longer lists those four counts).
--  * 2. The retention_policy rows session_activity and security_logs go with their tables.
--  * 3. R6: the OTP cleanup trigger and its two functions go; the 7-day ephemeral_auth retention_policy row (run_database_retention)
--       is the only OTP retention rule.
--  * 4. Functions: 90 in public and 2 in auth that nothing calls, and 19 that only tests called (the second invoice-create path
--       save_invoice(jsonb), the item_storage_price helpers the app never uses: create, update, delete and find_or_create, the
--       unused get_invoiceable_grns overload and the others listed in the notes). create_dispatch_with_stock_check(jsonb, jsonb[], integer,
--       text) and its _internal_3param stay: fas-sync calls the four-argument form.
--  * 5. 8 views, 16 tables (empty on Dev), 12 columns (NULL on Dev) and 13 duplicate or covered indexes go. Every foreign key stays
--       covered by an index. A guard at the very top (0.) refuses to run while any of those tables holds a row or any of those columns
--       a value: the operator then decides, nothing is dropped silently.
--  * 6. uuid defaults: the 17 uuid_generate_v1() defaults of ordinary tables become gen_random_uuid() (version 4); orders.id was and
--       stays random. dispatch_trl, goodsreceived_trl and invoice_trl keep extensions.uuid_generate_v1(), so the uuid-ossp extension
--       STAYS: the app validates disp_trl_id with yup string().uuid(), which accepts versions 1 to 5 only, so a version-7 id would break
--       invoicing in every released app build. (uuid_extract_timestamp() of those ids orders the lines.) Switch to uuidv7() and drop the
--       extension in a later migration, once released builds carry a version-agnostic check.
--  * 7. get_public_config(text): the edge function get-public-config reads its two tables through this narrow function with the
--       anon key instead of holding the service-role key.
-- trg_restore_stock_on_dispatch_delete stays: it is not redundant (tests/dispatch_delete_trigger.sql).

-- 0. Guard: refuse to drop anything that holds data. Dev held none; a database with real data (the production box) must be decided
-- on by the operator. Each object is checked only if it exists. Empty database: passes silently. (GUARD-BEGIN: tests/migrations.sh runs this block.)
-- GUARD-BEGIN
DO $guard$
DECLARE
  v_obj text;
  v_n bigint;
  v_found text[] := '{}';
  v_tables text[] := ARRAY['auth_logs','config_access_logs','intrusion_events','intrusion_metrics','contact_submissions','captcha_config',
    'jwt_config','order_number_counter','secrets_vault','test_otp_records','user_session_activity','sensor_health_events',
    'auto_invoice_errors','v_jwt_secret','v_access_token_expiry','v_refresh_token_expiry'];
  v_columns text[] := ARRAY['api_configurations.custom_config','api_configurations.google_maps_key','api_configurations.mapbox_token',
    'api_configurations.sentry_dsn','sms_config.account_sid','sms_config.auth_token','sms_config.from_phone','payments.bank',
    'feature_flags.rollout_percentage','otp_verifications.msg91_response','otp_verifications.otp_hash','sensor_devices.last_alert_at'];
BEGIN
  FOREACH v_obj IN ARRAY v_tables LOOP
    IF to_regclass('public.' || quote_ident(v_obj)) IS NOT NULL THEN
      EXECUTE format('SELECT count(*) FROM public.%I', v_obj) INTO v_n;
      IF v_n > 0 THEN v_found := v_found || format('table public.%s: %s rows', v_obj, v_n); END IF;
    END IF;
  END LOOP;
  FOREACH v_obj IN ARRAY v_columns LOOP
    IF EXISTS (SELECT 1 FROM information_schema.columns c
               WHERE c.table_schema = 'public' AND c.table_name = split_part(v_obj, '.', 1) AND c.column_name = split_part(v_obj, '.', 2)) THEN
      EXECUTE format('SELECT count(*) FROM public.%I WHERE %I IS NOT NULL', split_part(v_obj, '.', 1), split_part(v_obj, '.', 2)) INTO v_n;
      IF v_n > 0 THEN v_found := v_found || format('column public.%s: %s non-NULL values', v_obj, v_n); END IF;
    END IF;
  END LOOP;
  IF cardinality(v_found) > 0 THEN
    RAISE EXCEPTION 'Migration 123 would drop data: %. Nothing was changed. Check that this data is not needed (export it if it is), empty these objects, then run the migration again.',
      array_to_string(v_found, '; ');
  END IF;
END
$guard$;
-- GUARD-END

-- 1. Live functions without their dead references

CREATE OR REPLACE FUNCTION public.generate_invoice_data_for_grn(p_gr_id uuid, p_duration_mode text DEFAULT 'legacy'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
    v_duration_mode text;
    v_grn_exists boolean;
    v_is_invoiceable boolean;
    v_user_role text;
    v_current_year text;
    v_fin_year integer;
    v_next_invoice_no text;
    v_header_data jsonb;
    v_recalculation jsonb;
BEGIN
    v_duration_mode := public.validate_invoice_duration_mode(p_duration_mode);

    SELECT role INTO v_user_role FROM user_profiles
    WHERE auth_user_id = auth.uid();

    IF v_user_role NOT IN ('admin', 'supervisor', 'staff') AND auth.uid() IS NOT NULL THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'Only administrators and supervisors can generate invoice data'
        );
    END IF;

    SELECT
        EXISTS(SELECT 1 FROM goodsreceived WHERE id = p_gr_id),
        EXISTS(
            SELECT 1 FROM goodsreceived
            WHERE id = p_gr_id
            AND invoiced = false
            AND NOT EXISTS(SELECT 1 FROM goodsreceived_trl WHERE gr_id = p_gr_id AND stock > 0)
        )
    INTO v_grn_exists, v_is_invoiceable;

    IF NOT v_grn_exists THEN
        RETURN jsonb_build_object('success', false, 'error', 'GRN not found');
    END IF;

    IF NOT v_is_invoiceable THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'GRN is not ready for invoicing (must be completely dispatched and not already invoiced)'
        );
    END IF;

    IF EXTRACT(MONTH FROM CURRENT_DATE) >= 4 THEN
        v_current_year := EXTRACT(YEAR FROM CURRENT_DATE)::text || '-' ||
                         (EXTRACT(YEAR FROM CURRENT_DATE) + 1)::text;
    ELSE
        v_current_year := (EXTRACT(YEAR FROM CURRENT_DATE) - 1)::text || '-' ||
                         EXTRACT(YEAR FROM CURRENT_DATE)::text;
    END IF;

    v_fin_year := SPLIT_PART(v_current_year, '-', 1)::integer;

    SELECT 'INV-' || v_current_year || '-' ||
           LPAD((COUNT(*) + 1)::text, 4, '0')
    INTO v_next_invoice_no
    FROM invoice
    WHERE inv_fin_year = v_fin_year;

    SELECT jsonb_build_object(
        'invoice_number', v_next_invoice_no,
        'invoice_date', CURRENT_DATE,
        'financial_year', v_current_year,
        'duration_mode', v_duration_mode,
        'grn_id', gr.id,
        'grn_no', gr.gr_no,
        'grn_date', gr.date,
        'grn_registration', gr.registration,
        'grn_note', gr.note,
        'grn_leon', gr.leon,
        'grn_image_url', gr.gr_image_url,
        'grn_gr_image_url', gr.gr_image_url,
        'customer_id', gr.customer_id,
        'customer_name', c.name,
        'customer_address', c.address,
        'customer_city', c.city,
        'customer_state', c.state,
        'customer_pincode', c.pincode,
        'customer_phone', c.mobile,
        'customer_email', c.email,
        'customer_gstin', c.gst,
        'grn_customer_id', gr.customer_id,
        'grn_customer_name', c.name,
        'supervisor_id', gr.supervisor_id,
        'supervisor_name', COALESCE(sp.name, ''),
        'supervisor_phone', CAST(NULL AS text),
        'sender_id', gr.sender_id,
        'sender_name', COALESCE(se.name, ''),
        'sender_phone', CAST(NULL AS text),
        'total_items', (SELECT COUNT(*) FROM goodsreceived_trl grt WHERE grt.gr_id = gr.id),
        'total_original_quantity', (SELECT COALESCE(SUM(grt.qty), 0) FROM goodsreceived_trl grt WHERE grt.gr_id = gr.id),
        'total_dispatched_quantity', (
            SELECT COALESCE(SUM(dt.disp_qty), 0)
            FROM goodsreceived_trl grt
            JOIN dispatch_trl dt ON dt.gr_trl_id = grt.id
            WHERE grt.gr_id = gr.id
        ),
        'grn_created_by', gr.created_by,
        'grn_updated_by', gr.updated_by,
        'grn_created_at', gr.created_at,
        'grn_updated_at', gr.updated_at
    ) INTO v_header_data
    FROM goodsreceived gr
    JOIN customers c ON c.id = gr.customer_id
    LEFT JOIN user_profiles sp ON sp.id = gr.supervisor_id
    LEFT JOIN user_profiles se ON se.id = gr.sender_id
    WHERE gr.id = p_gr_id;

    v_recalculation := public.build_invoice_form_lines(p_gr_id, v_duration_mode);

    IF NOT COALESCE((v_recalculation->>'success')::boolean, false) THEN
        RETURN v_recalculation;
    END IF;

    RETURN jsonb_build_object(
        'success', true,
        'header', v_header_data,
        'items', v_recalculation->'items',
        'totals', v_recalculation->'totals',
        'message', 'Invoice data generated successfully'
    );
EXCEPTION
    WHEN OTHERS THEN
        RETURN jsonb_build_object(
            'success', false,
            'data', null,
            'message', 'Error generating invoice data: ' || SQLERRM
        );
END;
$function$;


CREATE OR REPLACE FUNCTION public.delete_grn_safe(p_grn_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'extensions', 'utils', 'pg_temp'
AS $function$
      DECLARE
          v_user_id uuid;
          v_user_role text;
          v_grn_record RECORD;
          v_dependency_check RECORD;
          v_items_deleted int := 0;
          v_movements_deleted int := 0;
          v_images_deleted int := 0;
          v_order_items_deleted int := 0;
          v_removed_order_lines jsonb;
BEGIN
  PERFORM warehouse_security.authorize_rpc('delete_grn_safe',jsonb_build_object('p_grn_id',p_grn_id));
    -- The list-refresh lock comes before any row lock (migration 46).
    PERFORM pg_advisory_xact_lock(71040);
          -- Authentication and authorization
          v_user_id := auth.uid();
          IF v_user_id IS NULL THEN
              RETURN jsonb_build_object(
                  'success', false,
                  'error', 'Authentication required'
              );
          END IF;

          -- Get user role
          SELECT role INTO v_user_role
          FROM user_profiles
          WHERE auth_user_id = v_user_id;

          -- Only admin and supervisor can delete GRNs
          IF v_user_role NOT IN ('admin', 'supervisor') THEN
              RETURN jsonb_build_object(
                  'success', false,
                  'error', 'Only administrators and supervisors can delete GRNs'
              );
          END IF;

          -- Check if GRN exists and get info
          SELECT gr.*, c.name as customer_name
          INTO v_grn_record
          FROM goodsreceived gr
          LEFT JOIN customers c ON c.id = gr.customer_id
          WHERE gr.id = p_grn_id;

          IF NOT FOUND THEN
              RETURN jsonb_build_object(
                  'success', false,
                  'error', 'GRN not found'
              );
          END IF;

          -- ❌ STRICT DEPENDENCY CHECKS - Block deletion if dispatches or invoices exist
          SELECT
              COUNT(DISTINCT dt.id) as dispatches,
              COUNT(DISTINCT it.id) as invoiced_dispatches,
              COUNT(DISTINCT sm.id) as stock_movements,
              COUNT(DISTINCT gi.id) as images,
              COUNT(DISTINCT oi.id) as order_items
          INTO v_dependency_check
          FROM goodsreceived gr
          LEFT JOIN goodsreceived_trl grt ON grt.gr_id = gr.id
          LEFT JOIN dispatch_trl dt ON dt.gr_id = gr.id
          LEFT JOIN invoice_trl it ON it.disp_trl_id = dt.id
          LEFT JOIN stock_movements sm ON sm.gr_trl_id = grt.id
          LEFT JOIN grn_images gi ON gi.grn_id = gr.id
          LEFT JOIN order_items oi ON (oi.grns_id = gr.id OR oi.grn_items_id = grt.id)
          WHERE gr.id = p_grn_id;

          -- ❌ Block if ANY invoices exist
          IF v_dependency_check.invoiced_dispatches > 0 THEN
              RETURN jsonb_build_object(
                  'success', false,
                  'error', format('Cannot delete GRN %s: %s dispatch items have been invoiced. Delete invoices first.',
                                v_grn_record.gr_no, v_dependency_check.invoiced_dispatches),
                  'blocking_dependencies', jsonb_build_object(
                      'invoiced_dispatches', v_dependency_check.invoiced_dispatches,
                      'total_dispatches', v_dependency_check.dispatches
                  ),
                  'grn_info', jsonb_build_object(
                      'gr_no', v_grn_record.gr_no,
                      'customer_name', COALESCE(v_grn_record.customer_name, 'Unknown'),
                      'date', v_grn_record.date
                  ),
                  'instructions', 'Delete all invoices and dispatches manually before deleting this GRN'
              );
          END IF;

          -- ❌ Block if ANY dispatches exist
          IF v_dependency_check.dispatches > 0 THEN
              RETURN jsonb_build_object(
                  'success', false,
                  'error', format('Cannot delete GRN %s: %s dispatch items exist. Delete dispatches first.',
                                v_grn_record.gr_no, v_dependency_check.dispatches),
                  'blocking_dependencies', jsonb_build_object(
                      'dispatches', v_dependency_check.dispatches
                  ),
                  'grn_info', jsonb_build_object(
                      'gr_no', v_grn_record.gr_no,
                      'customer_name', COALESCE(v_grn_record.customer_name, 'Unknown'),
                      'date', v_grn_record.date
                  ),
                  'instructions', 'Delete all dispatches manually before deleting this GRN'
              );
          END IF;

          -- ✅ SAFE DELETION PROCESS - Handle dependencies in correct order

          -- 1. Delete order_items that reference this GRN (FIXES YOUR FK CONSTRAINT ERROR)
          SELECT jsonb_object_agg(removed.order_id::text, removed.lines)
          INTO v_removed_order_lines
          FROM (
              SELECT oi.order_id, jsonb_agg(jsonb_build_object(
                         'item_id', oi.grn_items_item_id,
                         'item_name', oi.grn_items_item_name,
                         'quantity', 0,
                         'grn_no', oi.grns_gr_no,
                         'package_mark', oi.grn_items_package_mark
                     ) ORDER BY oi.sort_order, oi.created_at) AS lines
              FROM order_items oi
              WHERE oi.grns_id = p_grn_id
              OR oi.grn_items_id IN (
                  SELECT id FROM goodsreceived_trl WHERE gr_id = p_grn_id
              )
              GROUP BY oi.order_id
          ) AS removed;

          DELETE FROM order_items
          WHERE grns_id = p_grn_id
          OR grn_items_id IN (
              SELECT id FROM goodsreceived_trl WHERE gr_id = p_grn_id
          );
          GET DIAGNOSTICS v_order_items_deleted = ROW_COUNT;

          PERFORM warehouse_security.record_order_revision(
              removed.key::uuid,
              (SELECT id FROM user_profiles WHERE auth_user_id = v_user_id),
              'grn_deleted', '{}'::jsonb, removed.value)
          FROM jsonb_each(COALESCE(v_removed_order_lines, '{}'::jsonb)) AS removed;

          -- 2. Delete stock movements
          DELETE FROM stock_movements
          WHERE gr_trl_id IN (
              SELECT id FROM goodsreceived_trl WHERE gr_id = p_grn_id
          );
          GET DIAGNOSTICS v_movements_deleted = ROW_COUNT;

          -- 4. Delete GRN images (safe dependency)
          DELETE FROM grn_images
          WHERE grn_id = p_grn_id;
          GET DIAGNOSTICS v_images_deleted = ROW_COUNT;

          -- 5. Delete GRN items (goodsreceived_trl)
          DELETE FROM goodsreceived_trl
          WHERE gr_id = p_grn_id;
          GET DIAGNOSTICS v_items_deleted = ROW_COUNT;

          -- 6. Finally, delete the main GRN record
          DELETE FROM goodsreceived
          WHERE id = p_grn_id;

          -- 7. A saved create or edit answer that points at this GRN is not replayed any more: entering the
          -- same GRN again saves it (migration 120).
          DELETE FROM idempotency_keys
          WHERE (rpc_function = 'save_grn' AND response #>> '{data,grn_id}' = p_grn_id::text)
             OR (rpc_function = 'update_grn' AND response #>> '{grn,id}' = p_grn_id::text);

          RETURN jsonb_build_object(
              'success', true,
              'message', format('GRN %s deleted successfully', v_grn_record.gr_no),
              'grn_info', jsonb_build_object(
                  'gr_no', v_grn_record.gr_no,
                  'customer_name', COALESCE(v_grn_record.customer_name, 'Unknown'),
                  'date', v_grn_record.date
              ),
              'deleted_counts', jsonb_build_object(
                  'grn_items', v_items_deleted,
                  'order_items', v_order_items_deleted,
                  'stock_movements', v_movements_deleted,
                  'images', v_images_deleted,
                  'auto_invoice_errors', 0
              ),
              'deletion_type', 'safe_with_order_cleanup',
              'note', CASE
                  WHEN v_order_items_deleted > 0 THEN
                      format('Removed %s order items that referenced this GRN', v_order_items_deleted)
                  ELSE
                      'No order items were referencing this GRN'
              END
          );

      EXCEPTION
          WHEN insufficient_privilege THEN RAISE;
          WHEN OTHERS THEN
              RETURN jsonb_build_object(
                  'success', false,
                  'error', 'Deletion failed: ' || SQLERRM,
                  'grn_info', jsonb_build_object(
                      'gr_no', COALESCE(v_grn_record.gr_no, 'unknown'),
                      'customer_name', COALESCE(v_grn_record.customer_name, 'unknown')
                  )
              );
      END;
  $function$;


CREATE OR REPLACE FUNCTION public.save_invoice_internal(p_invoice_id uuid, p_invoice_data jsonb, p_invoice_items jsonb[])
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'extensions', 'utils', 'pg_temp'
AS $function$
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
    v_stock_left bigint;
    v_lots_left integer;
    v_stock_gr_no text;
    v_total_now numeric;
    v_lines jsonb;
    v_detail text;
BEGIN
    SELECT id INTO v_user_id FROM user_profiles WHERE auth_user_id = auth.uid();
    v_new_gr_id := (p_invoice_data->>'gr_id')::uuid;
    v_invoice_creation_time := NOW();
    v_invoice_date := COALESCE((p_invoice_data->>'inv_date')::TIMESTAMPTZ, NOW());
    v_invoice_number_for_resolution := (p_invoice_data->>'inv_no');
    v_is_auto_generated := COALESCE((p_invoice_data->>'is_auto_generated')::boolean, false);
    v_duration_mode := public.validate_invoice_duration_mode(p_invoice_data->>'duration_mode');
    -- The financial year is the one of the invoice date (migration 120).
    IF p_invoice_data->>'inv_fin_year' IS NOT NULL
       AND (p_invoice_data->>'inv_fin_year')::integer
           <> warehouse_security.financial_year(warehouse_security.business_date(v_invoice_date)) THEN
        RAISE EXCEPTION 'The invoice date belongs to financial year %, not %',
            warehouse_security.financial_year(warehouse_security.business_date(v_invoice_date)),
            (p_invoice_data->>'inv_fin_year')::integer
            USING ERRCODE = 'WH422';
    END IF;

    -- D9 (migration 121): an invoice is made when the GRN's goods are out. A GRN with stock in any lot is refused, before
    -- anything is written; the stock is dispatched first. (An invoice that already exists on a GRN that now holds stock is
    -- refused on its next edit too.)
    SELECT COALESCE(SUM(t.stock), 0), count(*) FILTER (WHERE t.stock > 0),
           (SELECT g.gr_no FROM goodsreceived g WHERE g.id = v_new_gr_id)
    INTO v_stock_left, v_lots_left, v_stock_gr_no
    FROM goodsreceived_trl t
    WHERE t.gr_id = v_new_gr_id;
    IF v_stock_left > 0 THEN
        RETURN warehouse_security.refuse('GRN_HAS_STOCK',
            format('GRN %s still has %s in stock. Dispatch it first, then make the invoice.', v_stock_gr_no, v_stock_left),
            jsonb_build_object('gr_no', v_stock_gr_no, 'stock', v_stock_left, 'lots', v_lots_left)) || jsonb_build_object('function_version', v_function_version);
    END IF;

    -- A number the financial year already holds is refused by name, under the lock and before anything is
    -- written (migration 120). unique_inv_no_per_year covers every row, so the check does too.
    IF EXISTS (
        SELECT 1 FROM invoice i
        WHERE i.inv_fin_year = (p_invoice_data->>'inv_fin_year')::integer
          AND i.inv_no = (p_invoice_data->>'inv_no')::integer
          AND i.id IS DISTINCT FROM p_invoice_id
    ) THEN
        RETURN jsonb_build_object(
            'success', false,
            'error_code', 'WH409',
            'reason', 'NUMBER_TAKEN',
            'number', p_invoice_data->>'inv_no',
            'error', format('Invoice number %s is already used in financial year %s',
                            p_invoice_data->>'inv_no', p_invoice_data->>'inv_fin_year'),
            'function_version', v_function_version
        );
    END IF;

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

    -- D18 (migration 121): the total the phone showed and the user confirmed is checked against the total the server has just
    -- worked out from the dates. A difference of more than 1.00 rolls the whole save back (the raise leaves the block, whose
    -- writes are undone, and the handler answers it) and names the days the server used, so the form can show the figures
    -- again. No expected_total (an older app): no check; the old total key stays an estimate.
    IF jsonb_typeof(p_invoice_data->'expected_total') = 'number' THEN
        SELECT i.total INTO v_total_now FROM invoice i WHERE i.id = v_final_invoice_id;
        IF abs(COALESCE(v_total_now, 0) - (p_invoice_data->>'expected_total')::numeric) > 1.00 THEN
            SELECT COALESCE(jsonb_agg(jsonb_build_object(
                       'disp_trl_id', it.disp_trl_id, 'duration', it.duration, 'no_of_days', it.no_of_days
                   ) ORDER BY uuid_extract_timestamp(it.id), it.id), '[]'::jsonb)
            INTO v_lines
            FROM invoice_trl it
            WHERE it.invoice_id = v_final_invoice_id;
            RAISE EXCEPTION 'rate_fail' USING ERRCODE = 'P0001', DETAIL = warehouse_security.refuse('TOTAL_CHANGED',
                format('The total is now %s, not %s. Review the figures and save again.',
                       COALESCE(v_total_now, 0), (p_invoice_data->>'expected_total')::numeric),
                jsonb_build_object('current_total', COALESCE(v_total_now, 0),
                                   'expected_total', p_invoice_data->'expected_total',
                                   'lines', v_lines))::text;
        END IF;
    END IF;

    UPDATE goodsreceived SET invoiced = true WHERE id = v_new_gr_id AND invoiced IS NOT TRUE;

    -- The table auto_invoice_errors is gone (migration 123); the answer keeps its count, always 0.

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
    -- A refusal raised after the write (the total check): the block is rolled back and the refusal is the answer.
    IF SQLERRM = 'rate_fail' THEN
        GET STACKED DIAGNOSTICS v_detail = PG_EXCEPTION_DETAIL;
        RETURN v_detail::jsonb || jsonb_build_object('function_version', v_function_version);
    END IF;
    RETURN jsonb_build_object(
        'success', false,
        'error', SQLERRM,
        'error_code', SQLSTATE,
        'function_version', v_function_version
    );
END;
$function$;


CREATE OR REPLACE FUNCTION public.delete_user_account()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public'
AS $function$
DECLARE profile_id uuid; profile_role text;
BEGIN
  -- A retry after a timed-out delete: the account is already deleted, which is what was asked.
  -- Read before the guard (a deleted account is inactive, so the guard would refuse it); it says
  -- nothing about anyone but the caller.
  IF auth.uid() IS NOT NULL AND EXISTS (SELECT 1 FROM public.user_profiles WHERE auth_user_id=auth.uid() AND deleted_at IS NOT NULL) THEN
    RETURN jsonb_build_object('success',true,'message','Account deleted','already_deleted',true);
  END IF;
  PERFORM warehouse_security.authorize_rpc('delete_user_account','{}'::jsonb);
  SELECT id, role::text INTO STRICT profile_id, profile_role FROM public.user_profiles WHERE auth_user_id=auth.uid() AND active;
  IF EXISTS (SELECT 1 FROM public.user_profiles WHERE id=profile_id AND is_service_account) THEN
    RETURN jsonb_build_object('success',false,'code','SERVICE_ACCOUNT_READ_ONLY','error_code','SERVICE_ACCOUNT_READ_ONLY',
      'error','A service account cannot be deleted','message','A service account cannot be deleted');
  END IF;
  IF profile_role='admin' AND NOT warehouse_security.other_active_admin_exists(profile_id) THEN
    RETURN jsonb_build_object('success',false,'code','LAST_ADMIN','error_code','LAST_ADMIN',
      'error','The only administrator cannot delete this account. Make another user an administrator first.',
      'message','The only administrator cannot delete this account. Make another user an administrator first.');
  END IF;
  DELETE FROM public.users_customers_new WHERE user_profile_id=profile_id;
  DELETE FROM warehouse_security.refresh_sessions WHERE user_id=auth.uid();
  UPDATE public.user_profiles SET name='Deleted User',display_name='Deleted User',active=false,
    mobile='DEL'||left(replace(profile_id::text,'-',''),12),mobile_verified=false,mobile_verified_at=NULL,
    central_issuer=NULL,central_subject=NULL,deleted_at=now(),enrollment_status='disabled'
    WHERE id=profile_id;
  RETURN jsonb_build_object('success',true,'message','Account deleted');
END $function$;


CREATE OR REPLACE FUNCTION warehouse_maintenance.run_database_retention(p_now timestamp with time zone DEFAULT now(), p_apply boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'warehouse_security', 'warehouse_maintenance'
AS $function$
DECLARE
  auth_cutoff timestamptz;
  sensor_cutoff timestamptz;
  result jsonb := '{}'::jsonb;
  affected bigint;
BEGIN
  SELECT p_now - make_interval(days => days) INTO auth_cutoff
    FROM warehouse_maintenance.retention_policy WHERE key = 'ephemeral_auth';
  SELECT p_now - make_interval(days => days) INTO sensor_cutoff
    FROM warehouse_maintenance.retention_policy WHERE key = 'sensor_readings';

  IF p_apply THEN
    DELETE FROM warehouse_security.consumed_refresh_tokens WHERE expires_at < p_now;
    GET DIAGNOSTICS affected = ROW_COUNT; result := result || jsonb_build_object('consumed_refresh_tokens', affected);
    DELETE FROM warehouse_security.refresh_sessions WHERE expires_at < p_now;
    GET DIAGNOSTICS affected = ROW_COUNT; result := result || jsonb_build_object('refresh_sessions', affected);
    DELETE FROM warehouse_security.central_token_use WHERE expires_at < p_now;
    GET DIAGNOSTICS affected = ROW_COUNT; result := result || jsonb_build_object('central_token_use', affected);
    DELETE FROM public.otp_verifications WHERE expires_at < auth_cutoff;
    GET DIAGNOSTICS affected = ROW_COUNT; result := result || jsonb_build_object('otp_verifications', affected);
    DELETE FROM public.otp_rate_limits WHERE updated_at < auth_cutoff;
    GET DIAGNOSTICS affected = ROW_COUNT; result := result || jsonb_build_object('otp_rate_limits', affected);
    DELETE FROM public.ip_rate_limits WHERE updated_at < auth_cutoff;
    GET DIAGNOSTICS affected = ROW_COUNT; result := result || jsonb_build_object('ip_rate_limits', affected);
    DELETE FROM public.idempotency_keys WHERE COALESCE(expires_at, created_at) < p_now;
    GET DIAGNOSTICS affected = ROW_COUNT; result := result || jsonb_build_object('idempotency_keys', affected);
    DELETE FROM public.sensor_readings WHERE measured_at < sensor_cutoff;
    GET DIAGNOSTICS affected = ROW_COUNT; result := result || jsonb_build_object('sensor_readings', affected);
  ELSE
    SELECT result || jsonb_build_object(
      'consumed_refresh_tokens', (SELECT count(*) FROM warehouse_security.consumed_refresh_tokens WHERE expires_at < p_now),
      'refresh_sessions', (SELECT count(*) FROM warehouse_security.refresh_sessions WHERE expires_at < p_now),
      'central_token_use', (SELECT count(*) FROM warehouse_security.central_token_use WHERE expires_at < p_now),
      'otp_verifications', (SELECT count(*) FROM public.otp_verifications WHERE expires_at < auth_cutoff),
      'otp_rate_limits', (SELECT count(*) FROM public.otp_rate_limits WHERE updated_at < auth_cutoff),
      'ip_rate_limits', (SELECT count(*) FROM public.ip_rate_limits WHERE updated_at < auth_cutoff),
      'idempotency_keys', (SELECT count(*) FROM public.idempotency_keys WHERE COALESCE(expires_at, created_at) < p_now),
      'sensor_readings', (SELECT count(*) FROM public.sensor_readings WHERE measured_at < sensor_cutoff)
    ) INTO result;
  END IF;
  RETURN jsonb_build_object('applied', p_apply, 'as_of', p_now, 'rows', result);
END $function$;


-- 2. The retention rules of the dropped tables
DELETE FROM warehouse_maintenance.retention_policy WHERE key IN ('session_activity', 'security_logs');

-- 3. R6: the OTP cleanup trigger on otp_verifications and its two functions
DROP TRIGGER trigger_auto_cleanup_otps ON public.otp_verifications;
DROP FUNCTION public.auto_cleanup_expired_otps();
DROP FUNCTION public.cleanup_expired_otps();

-- 4. Functions that nothing calls (callers first)
DROP FUNCTION public.debug_search_customer_items_for_order(text,uuid,text,integer,integer,integer,uuid,numeric,numeric);
DROP FUNCTION public.send_otp_with_config(character varying,character varying,text,inet);
DROP FUNCTION public.send_otp_with_hash(character varying,character varying,text,inet);
DROP FUNCTION public.update_customer_contact_with_priority(uuid);
DROP FUNCTION public.check_invoice_exists(integer,integer);
DROP FUNCTION public.check_ip_rate_limit(inet);
DROP FUNCTION public.check_otp_rate_limit(character varying);
DROP FUNCTION public.check_session_validity();
DROP FUNCTION public.check_stock_availability(uuid);
DROP FUNCTION public.cleanup_intrusion_events();
DROP FUNCTION public.cleanup_old_audit_logs();
DROP FUNCTION public.cleanup_orphaned_grn_images(integer);
DROP FUNCTION public.constant_time_compare(text,text);
DROP FUNCTION public.create_first_admin(character varying,character varying,character varying);
DROP FUNCTION public.deactivate_sensor(character varying,text);
DROP FUNCTION public.debug_auth_context();
DROP FUNCTION public.debug_current_user_grn_access();
DROP FUNCTION public.debug_jwt_claims();
DROP FUNCTION public.debug_otp_verification(character varying,character varying);
DROP FUNCTION public.debug_user_access(character varying);
DROP FUNCTION public.delete_resolved_auto_invoice_errors(uuid[]);
DROP FUNCTION public.ensure_default_pricing_for_all_items(numeric,numeric,numeric);
DROP FUNCTION public.find_storage_price_table(uuid,integer,date,uuid);
DROP FUNCTION public.fix_orphaned_invoice_flags();
DROP FUNCTION public.generate_secure_otp();
DROP FUNCTION public.generate_sequential_uuid();
DROP FUNCTION public.get_active_sessions(uuid);
DROP FUNCTION public.get_auto_invoice_error_stats(date,date);
DROP FUNCTION public.get_current_user_profile();
DROP FUNCTION public.get_customer_invoices(uuid,timestamp with time zone,timestamp with time zone,jsonb);
DROP FUNCTION public.get_customer_stock_analysis(uuid,timestamp with time zone,jsonb,boolean);
DROP FUNCTION public.get_customer_stock_analysis(uuid,timestamp with time zone,jsonb);
DROP FUNCTION public.get_customer_stock_movements(uuid,timestamp with time zone,timestamp with time zone);
DROP FUNCTION public.get_customer_with_priority_contact(uuid);
DROP FUNCTION public.get_dispatch_cart_linkage_summary(uuid);
DROP FUNCTION public.get_financial_year_dates(integer);
DROP FUNCTION public.get_grn_by_number(text,integer);
DROP FUNCTION public.get_grn_items_by_id(uuid);
DROP FUNCTION public.get_grn_items(uuid);
DROP FUNCTION public.get_grn_summary(text,integer);
DROP FUNCTION public.get_invoice_form_data(uuid,text);
DROP FUNCTION public.get_item_grn_records(uuid,jsonb,text,text,integer,integer);
DROP FUNCTION public.get_item_pricing_config(uuid,uuid);
DROP FUNCTION public.get_item_stock_analysis(timestamp with time zone,jsonb,jsonb);
DROP FUNCTION public.get_jwt_secret();
DROP FUNCTION public.get_order_item_change_summary(uuid);
DROP FUNCTION public.get_order_list(jsonb,text,text,integer,integer);
DROP FUNCTION public.get_order_stats(uuid);
DROP FUNCTION public.get_recent_auto_invoice_errors(integer,boolean);
DROP FUNCTION public.get_sensor_devices(boolean);
DROP FUNCTION public.get_sensor_latest();
DROP FUNCTION public.get_sensor_readings(uuid,timestamp with time zone,timestamp with time zone,integer,integer);
DROP FUNCTION public.get_sensor_statistics(uuid,character varying);
DROP FUNCTION public.get_service_credentials(character varying);
DROP FUNCTION public.get_unresolved_auto_invoice_error_count();
DROP FUNCTION public.get_user_profile_id(uuid);
DROP FUNCTION public.has_role(user_role);
DROP FUNCTION public.is_admin_or_supervisor_v2();
DROP FUNCTION public.is_admin_supervisor_or_staff();
DROP FUNCTION public.is_admin();
DROP FUNCTION public.is_dispatch_item_invoiced(uuid);
DROP FUNCTION public.is_supervisor_bypass();
DROP FUNCTION public.link_supabase_auth_user(character varying,uuid);
DROP FUNCTION public.log_authentication_attempt(text,uuid,boolean,text,text,jsonb);
DROP FUNCTION public.log_auto_invoice_error(uuid,text,uuid,text,timestamp with time zone,text,text,jsonb);
DROP FUNCTION public.monitor_print_jobs();
DROP FUNCTION public.recalculate_invoice_items(uuid,text);
DROP FUNCTION public.refresh_auth_token(text);
DROP FUNCTION public.resolve_auto_invoice_errors_by_grn(uuid,uuid);
DROP FUNCTION public.resolve_auto_invoice_error(uuid,text);
DROP FUNCTION public.restore_cart_quantities_from_dispatch(uuid);
DROP FUNCTION public.restore_dispatch(uuid);
DROP FUNCTION public.restore_grn(uuid);
DROP FUNCTION public.restore_invoice(uuid);
DROP FUNCTION public.safe_delete_dispatch(uuid,boolean);
DROP FUNCTION public.safe_delete_grn(uuid,boolean);
DROP FUNCTION public.search_grns(text,integer);
DROP FUNCTION public.send_otp_simple(character varying,character varying);
DROP FUNCTION public.set_msg91_mode(boolean);
DROP FUNCTION public.set_sms_mode(boolean);
DROP FUNCTION public.submit_contact_form(text,text,text,text);
DROP FUNCTION public.update_grn_out_of_stock_status(uuid);
DROP FUNCTION public.update_order_items_batch(uuid,jsonb);
DROP FUNCTION public.update_order(uuid,jsonb,jsonb,uuid);
DROP FUNCTION public.update_service_credentials(character varying,jsonb);
DROP FUNCTION public.validate_date_range(timestamp with time zone,text,timestamp with time zone,timestamp with time zone,boolean);
DROP FUNCTION public.validate_invoice_data_structure(jsonb);
DROP FUNCTION public.validate_price_configuration(uuid,integer,integer,date,uuid,date);
DROP FUNCTION public.validate_string_length(text,text,integer,integer,boolean);
DROP FUNCTION public.verify_captcha(text);
DROP FUNCTION auth.email();
DROP FUNCTION auth.role();

-- 4b. Functions that only tests called
DROP FUNCTION public.save_invoice(jsonb);
DROP FUNCTION public.get_invoiceable_grns(integer,integer);
DROP FUNCTION public.cancel_invoice(uuid,text);
DROP FUNCTION public.cancel_invoice(uuid);
DROP FUNCTION public.get_cart_dispatches(uuid);
DROP FUNCTION public.get_grn_invoices(uuid);
DROP FUNCTION public.get_item_dispatch_records(uuid,jsonb,text,text,integer,integer,boolean);
DROP FUNCTION public.get_item_grn_rates(uuid);
DROP FUNCTION public.get_next_invoice_number_with_year();
DROP FUNCTION public.get_otp_stats(character varying);
DROP FUNCTION public.send_otp(character varying,character varying,text,inet,text);
DROP FUNCTION public.update_order_metadata(uuid,text,text,timestamp without time zone);
DROP FUNCTION public.verify_otp_or_register(character varying,character varying,character varying,character varying);
DROP FUNCTION public.create_item_storage_price(uuid,text,numeric,numeric,numeric,numeric,date,uuid,numeric,date);
DROP FUNCTION public.delete_item_storage_price(uuid);
DROP FUNCTION public.find_or_create_item_storage_price(uuid,uuid,numeric,text,numeric,numeric,numeric,numeric,numeric);
DROP FUNCTION public.update_item_storage_price(uuid,numeric,numeric,numeric,numeric,numeric,date,date);
DROP FUNCTION public.update_item_storage_price(uuid,numeric,numeric,numeric,numeric,numeric,numeric,date,date);
DROP FUNCTION warehouse_security.image_file_unreferenced(text,text);

-- 5. Views, tables, columns and indexes

DROP VIEW public.foreign_key_status;
DROP VIEW public.high_cpu_analysis;
DROP VIEW public.low_stock_alerts;
DROP VIEW public.rls_policies_summary;
DROP VIEW public.security_metrics;
DROP VIEW public.sensor_health_dashboard;
DROP VIEW public.stock_summary;
DROP VIEW public.user_customer_assignments;
DROP TABLE public.auth_logs;
DROP TABLE public.config_access_logs;
DROP TABLE public.intrusion_events;
DROP TABLE public.intrusion_metrics;
DROP TABLE public.contact_submissions;
DROP TABLE public.captcha_config;
DROP TABLE public.jwt_config;
DROP TABLE public.order_number_counter;
DROP TABLE public.secrets_vault;
DROP TABLE public.test_otp_records;
DROP TABLE public.user_session_activity;
DROP TABLE public.sensor_health_events;
DROP TABLE public.auto_invoice_errors;
DROP TABLE public.v_jwt_secret;
DROP TABLE public.v_access_token_expiry;
DROP TABLE public.v_refresh_token_expiry;
ALTER TABLE public.api_configurations DROP COLUMN custom_config, DROP COLUMN google_maps_key, DROP COLUMN mapbox_token, DROP COLUMN sentry_dsn;
ALTER TABLE public.sms_config DROP COLUMN account_sid, DROP COLUMN auth_token, DROP COLUMN from_phone;
ALTER TABLE public.payments DROP COLUMN bank;
ALTER TABLE public.feature_flags DROP COLUMN rollout_percentage;
ALTER TABLE public.otp_verifications DROP COLUMN msg91_response, DROP COLUMN otp_hash;
ALTER TABLE public.sensor_devices DROP COLUMN last_alert_at;
DROP INDEX public.idx_idempotency_key_lookup;
DROP INDEX public.idx_api_config_env;
DROP INDEX public.idx_printer_status_name;
DROP INDEX public.idx_dispatch_trl_disp_id;
DROP INDEX public.idx_goodsreceived_trl_gr_id;
DROP INDEX public.idx_grn_images_grn_id;
DROP INDEX public.grn_rates_gr_id_idx;
DROP INDEX public.idx_invoice_inv_fin_year;
DROP INDEX public.idx_invoice_customer_id;
DROP INDEX public.idx_invoice_trl_invoice_id;
DROP INDEX public.idx_invoice_trl_disp_trl_id;
DROP INDEX public.idx_order_items_order_id;
DROP INDEX public.idx_users_customers_user_profile;

-- 6. uuid defaults (17 to gen_random_uuid(); the three line tables keep uuid_generate_v1(), see the header)
ALTER TABLE public.api_configurations ALTER COLUMN id SET DEFAULT gen_random_uuid();
ALTER TABLE public.customers ALTER COLUMN id SET DEFAULT gen_random_uuid();
ALTER TABLE public.dispatch_images ALTER COLUMN id SET DEFAULT gen_random_uuid();
ALTER TABLE public.dispatch ALTER COLUMN id SET DEFAULT gen_random_uuid();
ALTER TABLE public.feature_flags ALTER COLUMN id SET DEFAULT gen_random_uuid();
ALTER TABLE public.goodsreceived ALTER COLUMN id SET DEFAULT gen_random_uuid();
ALTER TABLE public.grn_images ALTER COLUMN id SET DEFAULT gen_random_uuid();
ALTER TABLE public.invoice ALTER COLUMN id SET DEFAULT gen_random_uuid();
ALTER TABLE public.item_storage_prices ALTER COLUMN id SET DEFAULT gen_random_uuid();
ALTER TABLE public.items ALTER COLUMN id SET DEFAULT gen_random_uuid();
ALTER TABLE public.order_items ALTER COLUMN id SET DEFAULT gen_random_uuid();
ALTER TABLE public.orders ALTER COLUMN id SET DEFAULT gen_random_uuid();
ALTER TABLE public.otp_verifications ALTER COLUMN id SET DEFAULT gen_random_uuid();
ALTER TABLE public.print_jobs ALTER COLUMN id SET DEFAULT gen_random_uuid();
ALTER TABLE public.sensor_devices ALTER COLUMN id SET DEFAULT gen_random_uuid();
ALTER TABLE public.sensor_readings ALTER COLUMN id SET DEFAULT gen_random_uuid();
ALTER TABLE public.stock_movements ALTER COLUMN id SET DEFAULT gen_random_uuid();
-- uuid-ossp stays: dispatch_trl, goodsreceived_trl and invoice_trl still default to extensions.uuid_generate_v1().

-- 7. get_public_config: what the public configuration shows, read without the service-role key. The answer is NULL when the
-- environment has no active row (the edge function then answers 503 "not seeded", as before). json, not jsonb, keeps the order of the flags.
CREATE FUNCTION public.get_public_config(p_environment text) RETURNS json
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'pg_temp'
    AS $$
  SELECT json_build_object(
    'app_version', c.app_version,
    'maintenance_mode', c.maintenance_mode,
    'feature_flags', COALESCE((SELECT json_object_agg(f.name, f.enabled) FROM public.feature_flags f), '{}'::json))
  FROM public.api_configurations c
  WHERE c.environment = p_environment AND c.is_active
$$;
REVOKE ALL ON FUNCTION public.get_public_config(p_environment text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_public_config(p_environment text) TO anon;
GRANT EXECUTE ON FUNCTION public.get_public_config(p_environment text) TO service_role;


-- ===== 8. The print "View jobs" sheet works for the people who can print (owner decision, 2026-10-21) =====
-- The app (GRNs list, printer icon on a GRN row, "Print GRNs", View jobs) calls get_print_jobs and cancel_print_job with the user's
-- session, but both were EXECUTE for service_role only, so the sheet always failed. Only View jobs is fixed: the print routes stay off
-- by design (docs/PRINTING.md) and the Print buttons are unchanged.
--  * Who: administrators, supervisors and staff, the roles that can print in the app (canCreate or canUpdate). Customers and anon are
--    refused. authorize_rpc admits administrators and supervisors to every name; the two names are added to its staff list, and a
--    customer reaches the final ELSE ("Staff access required").
--  * What each role sees and cancels: the rule the two bodies already had. The printer and its queue are shared by the whole
--    facility, so administrators, supervisors and staff list every job and may cancel any job that is not finished. A customer
--    never reaches the bodies, so no customer sees another customer's data (a job holds a document range, the user's name and
--    a printer name, no customer data).
--  * get_print_jobs: calls authorize_rpc first; otherwise unchanged.
--  * cancel_print_job: calls authorize_rpc first; its role lookup compared user_profiles.id with auth.uid() (a profile id against a
--    login id), so it answered "not authenticated" to everyone; it now compares auth_user_id, as get_print_jobs does.
--  * authorize_rpc: the stale name get_cart_dispatches (dropped above) leaves both lists.

CREATE OR REPLACE FUNCTION public.get_print_jobs(p_limit integer DEFAULT 50, p_job_type text DEFAULT NULL::text, p_status text DEFAULT NULL::text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE
    v_user_role VARCHAR(20);
    v_user_profile_id UUID;
    v_auth_uid UUID;
    v_result jsonb;
BEGIN
    PERFORM warehouse_security.authorize_rpc('get_print_jobs', jsonb_build_object());
    v_auth_uid := auth.uid();

    SELECT up.id, up.role
    INTO v_user_profile_id, v_user_role
    FROM public.user_profiles up
    WHERE up.auth_user_id = v_auth_uid;

    IF v_user_role IS NULL THEN
        RETURN jsonb_build_object(
            'success', false,
            'data', null,
            'message', 'User not authenticated',
            'error', jsonb_build_object('code', 'NOT_AUTHENTICATED')
        );
    END IF;

    SELECT jsonb_build_object(
        'success', true,
        'data', COALESCE(jsonb_agg(jsonb_build_object(
            'id', pj.id,
            'cups_job_id', pj.cups_job_id,
            'job_type', pj.job_type,
            'document_range_start', pj.document_range_start,
            'document_range_end', pj.document_range_end,
            'document_count', pj.document_count,
            'user_id', pj.user_id,
            'user_name', pj.user_name,
            'status', pj.status,
            'error_message', pj.error_message,
            'content_size', pj.content_size,
            'printer_name', pj.printer_name,
            'submitted_at', pj.submitted_at,
            'completed_at', pj.completed_at,
            'created_at', pj.created_at,
            'updated_at', pj.updated_at
        ) ORDER BY pj.submitted_at DESC), '[]'::jsonb),
        'message', null
    ) INTO v_result
    FROM public.print_jobs pj
    WHERE
        (v_user_role IN ('admin', 'supervisor', 'staff') OR pj.user_id = v_auth_uid)
        AND (p_job_type IS NULL OR pj.job_type = p_job_type)
        AND (p_status IS NULL OR pj.status = p_status)
    LIMIT p_limit;

    RETURN v_result;
END;
$$;

CREATE OR REPLACE FUNCTION public.cancel_print_job(p_print_job_id uuid) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE
    v_user_role VARCHAR(20);
    v_job_user_id UUID;
    v_cups_job_id INTEGER;
    v_job_status VARCHAR(20);
BEGIN
    PERFORM warehouse_security.authorize_rpc('cancel_print_job', jsonb_build_object('p_print_job_id', p_print_job_id));
    SELECT role INTO v_user_role FROM public.user_profiles WHERE auth_user_id = auth.uid();

    IF v_user_role IS NULL THEN
        RETURN utils.not_authenticated_response();
    END IF;

    SELECT user_id, cups_job_id, status INTO v_job_user_id, v_cups_job_id, v_job_status
    FROM public.print_jobs WHERE id = p_print_job_id;

    IF v_job_user_id IS NULL THEN
        RETURN utils.not_found_response('Print job', p_print_job_id::text);
    END IF;

    IF v_job_user_id != auth.uid() AND v_user_role NOT IN ('admin', 'supervisor', 'staff') THEN
        RETURN utils.error_response('PERMISSION_DENIED', 'Permission denied. You can only cancel your own print jobs.');
    END IF;

    IF v_job_status IN ('completed', 'cancelled', 'failed') THEN
        RETURN utils.error_response('INVALID_STATUS', 'Cannot cancel job with status: ' || v_job_status);
    END IF;

    UPDATE public.print_jobs SET status = 'cancelled', completed_at = NOW(), updated_at = NOW() WHERE id = p_print_job_id;

    RETURN utils.success_response(
        jsonb_build_object(
            'print_job_id', p_print_job_id,
            'cups_job_id', v_cups_job_id,
            'note', 'Call manage-print-jobs Edge Function to cancel CUPS job: ' || v_cups_job_id
        ),
        'Print job marked as cancelled'
    );
END;
$$;

REVOKE ALL ON FUNCTION public.get_print_jobs(p_limit integer, p_job_type text, p_status text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.get_print_jobs(p_limit integer, p_job_type text, p_status text) TO service_role;
GRANT ALL ON FUNCTION public.get_print_jobs(p_limit integer, p_job_type text, p_status text) TO authenticated;
REVOKE ALL ON FUNCTION public.cancel_print_job(p_print_job_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.cancel_print_job(p_print_job_id uuid) TO service_role;
GRANT ALL ON FUNCTION public.cancel_print_job(p_print_job_id uuid) TO authenticated;

-- authorize_rpc: the two print names for staff; get_cart_dispatches (dropped above) removed from both lists.
DO $patch$
DECLARE
  v_def text;
  v_old constant text[] := ARRAY[
    $m$    'get_cart_dispatches','search_customer_items_for_order',
$m$,
    $m$    'get_sensor_device'
  ) THEN RETURN; END IF;
$m$,
    $m$  ELSIF rpc IN ('get_order_with_items','get_cart_dispatches','add_item_to_order',
$m$
  ];
  v_new constant text[] := ARRAY[
    $m$    'search_customer_items_for_order',
$m$,
    $m$    'get_sensor_device',
    -- The print "View jobs" sheet (migration 123); customers stay refused by the final ELSE.
    'get_print_jobs','cancel_print_job'
  ) THEN RETURN; END IF;
$m$,
    $m$  ELSIF rpc IN ('get_order_with_items','add_item_to_order',
$m$
  ];
  v_count integer;
  i integer;
BEGIN
  v_def := pg_get_functiondef('warehouse_security.authorize_rpc(text, jsonb)'::regprocedure);
  FOR i IN 1 .. array_length(v_old, 1) LOOP
    v_count := (length(v_def) - length(replace(v_def, v_old[i], ''))) / length(v_old[i]);
    IF v_count <> 1 THEN
      RAISE EXCEPTION 'authorize_rpc: expected marker % once, found % times', i, v_count;
    END IF;
    v_def := replace(v_def, v_old[i], v_new[i]);
  END LOOP;
  EXECUTE v_def;
END
$patch$;
