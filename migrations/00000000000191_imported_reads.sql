-- Migration 191 (WH-180, part 3 of the import of past years): reads of imported documents. Written against the functions as migrations
-- 143, 164, 165, 172, 173, 175, 176, 178, 181 and 189 left them. Marker-count patches: each before-text is found exactly once.
--
--  1. Amounts as issued. An imported invoice line (invoice_trl.issued_storage_amount set, migration 189) also holds taxable_value = storage
--     + labour as issued and line_tax = tax as issued. Every reader that works a line's amount out answers those stored figures for such a
--     line instead, and works nothing out again: get_invoice_items_detailed (base, tax_amount, total_amount), get_customer_invoice_summary
--     (labour_amount, tax_amount, line_total), get_dispatch_details (statistics.total_invoice_amount) and get_invoice_range_for_print
--     (storage_amount; imported invoices are left out of it, see 3). get_invoice_detail and get_invoice_data (storage_amount) are changed in
--     their definition files. The check is the line's own issued_storage_amount, not a wrapper around invoice_storage_amount: that function
--     is given the invoice and the rates, not the line, and every caller already sits in a CASE that picks the amount.
--     An app line has issued_storage_amount NULL and reads exactly as before. The writes that work amounts out (recalculate_invoice_header,
--     invoice_gst_amounts through apply_invoice_gst, update_invoice) are not changed: an imported invoice is inserted with its stored
--     figures and never goes through them (invoice_gst_amounts also returns at once for doc_type 'invoice', the only type an import writes),
--     and migration 190 refuses every edit of an imported invoice.
--     get_invoice_items_detailed lists a live invoice's line that has kept details (details_kept_at, set only by cancel_invoice and by the
--     import) even when it names no dispatch line, as get_invoice_detail does: an imported charge line has no dispatch.
--  2. "imported" (boolean, import_batch_id IS NOT NULL) in get_grn_list (grns[]), get_all_grn_items (data[], the app's GRN list),
--     get_grn_details (grn), get_dispatch_list_with_items (dispatches[]), get_customer_dispatch_list (dispatches[]), get_dispatch_details (dispatch), get_invoices_list (invoices[]),
--     get_customer_statement (invoices[]); get_invoice_detail (invoice) and get_invoice_data (header) in their definition files.
--  3. Preprinted range prints leave imported documents out: get_grn_range_for_print, get_dispatch_range_for_print and
--     get_invoice_range_for_print print slips for current work; an imported document prints through its own PDF.
--
-- No role is created, altered or dropped. No table, column or grant changes.

CREATE FUNCTION pg_temp.patch_function(p_function regprocedure, p_old text[], p_new text[]) RETURNS void
    LANGUAGE plpgsql AS $$
DECLARE
  v_def text := pg_get_functiondef(p_function);
  v_count integer;
  i integer;
BEGIN
  IF array_length(p_old, 1) IS DISTINCT FROM array_length(p_new, 1) THEN
    RAISE EXCEPTION '%: the marker list and the replacement list differ in length', p_function;
  END IF;
  FOR i IN 1 .. array_length(p_old, 1) LOOP
    IF position(p_old[i] IN p_new[i]) > 0 THEN
      RAISE EXCEPTION '%: the replacement of marker % contains the marker', p_function, i;
    END IF;
    v_count := (length(v_def) - length(replace(v_def, p_old[i], ''))) / length(p_old[i]);
    IF v_count <> 1 THEN
      RAISE EXCEPTION '%: expected marker % once, found % times', p_function, i, v_count;
    END IF;
    v_def := replace(v_def, p_old[i], p_new[i]);
  END LOOP;
  EXECUTE v_def;
END $$;

-- ===== 1. amounts as issued =====

SELECT pg_temp.patch_function('public.get_invoice_items_detailed(uuid)'::regprocedure, ARRAY[
$m$      SELECT CASE WHEN NOT avail.ok THEN NULL
        WHEN avail.mode = 'ONE_TIME'$m$,
$m$        END AS base
    ) AS amount$m$,
$m$      ROUND(amount.base * COALESCE(it.tax, 0)::numeric / 100, 2) AS tax_amount,
      amount.base + ROUND(amount.base * COALESCE(it.tax, 0)::numeric / 100, 2) AS total_amount,$m$,
$m$      AND (inv.cancelled_at IS NOT NULL
           OR (dt.id IS NOT NULL$m$
], ARRAY[
$m$      SELECT CASE WHEN NOT avail.ok THEN NULL
        -- Migration 191 (WH-180): an imported line's amount before tax as issued (storage + labour), never worked out again.
        WHEN it.issued_storage_amount IS NOT NULL THEN COALESCE(it.taxable_value, it.issued_storage_amount)
        WHEN avail.mode = 'ONE_TIME'$m$,
$m$        END AS base,
        CASE WHEN it.issued_storage_amount IS NOT NULL THEN it.line_tax END AS issued_tax
    ) AS amount$m$,
$m$      COALESCE(amount.issued_tax, ROUND(amount.base * COALESCE(it.tax, 0)::numeric / 100, 2)) AS tax_amount,
      amount.base + COALESCE(amount.issued_tax, ROUND(amount.base * COALESCE(it.tax, 0)::numeric / 100, 2)) AS total_amount,$m$,
$m$      -- Migration 191: a line with kept details (a cancelled invoice's, or an imported one, which may name no dispatch) is listed too.
      AND (inv.cancelled_at IS NOT NULL OR it.details_kept_at IS NOT NULL
           OR (dt.id IS NOT NULL$m$
]);

SELECT pg_temp.patch_function('public.get_customer_invoice_summary(uuid, date, date, integer)'::regprocedure, ARRAY[
$m$                        'tax_amount', ROUND(amount.base * COALESCE(it.tax, 0)::numeric / 100, 2),
                        'line_total', amount.base + ROUND(amount.base * COALESCE(it.tax, 0)::numeric / 100, 2),$m$,
$m$                SELECT CASE WHEN gr.pricing_mode = 'ONE_TIME'
                            THEN ROUND(COALESCE(it.charge, 0)::numeric * COALESCE(dt.disp_qty, 0)::numeric, 2)$m$,
$m$                       CASE WHEN gr.pricing_mode = 'ONE_TIME' THEN 0::numeric
                            ELSE ROUND(COALESCE(it.labour_rate, 0)::numeric * COALESCE(dt.disp_qty, 0)::numeric, 2) END AS labour$m$
], ARRAY[
$m$                        'tax_amount', COALESCE(amount.issued_tax, ROUND(amount.base * COALESCE(it.tax, 0)::numeric / 100, 2)),
                        'line_total', amount.base + COALESCE(amount.issued_tax, ROUND(amount.base * COALESCE(it.tax, 0)::numeric / 100, 2)),$m$,
$m$                -- Migration 191 (WH-180): an imported line reads its amounts as issued.
                SELECT CASE WHEN it.issued_storage_amount IS NOT NULL THEN COALESCE(it.taxable_value, it.issued_storage_amount)
                            WHEN gr.pricing_mode = 'ONE_TIME'
                            THEN ROUND(COALESCE(it.charge, 0)::numeric * COALESCE(dt.disp_qty, 0)::numeric, 2)$m$,
$m$                       CASE WHEN it.issued_storage_amount IS NOT NULL
                            THEN COALESCE(it.taxable_value, it.issued_storage_amount) - it.issued_storage_amount
                            WHEN gr.pricing_mode = 'ONE_TIME' THEN 0::numeric
                            ELSE ROUND(COALESCE(it.labour_rate, 0)::numeric * COALESCE(dt.disp_qty, 0)::numeric, 2) END AS labour,
                       CASE WHEN it.issued_storage_amount IS NOT NULL THEN it.line_tax END AS issued_tax$m$
]);

SELECT pg_temp.patch_function('public.get_dispatch_details(uuid)'::regprocedure, ARRAY[
$m$'total_invoice_amount', COALESCE(SUM(amount.base + ROUND(amount.base * COALESCE(it.tax, 0)::numeric / 100, 2))$m$,
$m$                            SELECT CASE WHEN gr_line.pricing_mode = 'ONE_TIME'$m$,
$m$                    'disp_no', d.disp_no,
                    'disp_date', d.disp_date,$m$
], ARRAY[
$m$'total_invoice_amount', COALESCE(SUM(amount.base + COALESCE(CASE WHEN it.issued_storage_amount IS NOT NULL THEN it.line_tax END,
                                                                                       ROUND(amount.base * COALESCE(it.tax, 0)::numeric / 100, 2)))$m$,
$m$                            -- Migration 191 (WH-180): an imported line's amount before tax as issued.
                            SELECT CASE WHEN it.issued_storage_amount IS NOT NULL THEN COALESCE(it.taxable_value, it.issued_storage_amount)
                            WHEN gr_line.pricing_mode = 'ONE_TIME'$m$,
$m$                    'disp_no', d.disp_no,
                    'imported', d.import_batch_id IS NOT NULL,  -- Migration 191 (WH-180)
                    'disp_date', d.disp_date,$m$
]);

-- ===== 1 and 3. the invoice range print =====
SELECT pg_temp.patch_function('public.get_invoice_range_for_print(text, text, integer, integer)'::regprocedure, ARRAY[
$m$                    'storage_amount', CASE WHEN gr.pricing_mode = 'ONE_TIME'$m$,
$m$          AND i.deleted_at IS NULL AND i.cancelled_at IS NULL
        ORDER BY i.inv_fin_year, i.inv_no$m$,
$m$          AND i.deleted_at IS NULL AND i.cancelled_at IS NOT NULL), '[]'::jsonb));$m$
], ARRAY[
$m$                    'storage_amount', CASE WHEN it.issued_storage_amount IS NOT NULL THEN it.issued_storage_amount  -- Migration 191
                        WHEN gr.pricing_mode = 'ONE_TIME'$m$,
$m$          AND i.deleted_at IS NULL AND i.cancelled_at IS NULL
          AND i.import_batch_id IS NULL  -- Migration 191 (WH-180): an imported invoice prints through its own PDF, not on a preprinted slip.
        ORDER BY i.inv_fin_year, i.inv_no$m$,
$m$          AND i.deleted_at IS NULL AND i.cancelled_at IS NOT NULL
          AND i.import_batch_id IS NULL), '[]'::jsonb));$m$
]);

-- ===== 3. the GRN and dispatch range prints =====
SELECT pg_temp.patch_function('public.get_grn_range_for_print(text, text, integer)'::regprocedure, ARRAY[
$m$        WHERE gr.gr_no >= start_gr_no$m$
], ARRAY[
$m$        WHERE gr.import_batch_id IS NULL  -- Migration 191 (WH-180): an imported GRN prints through its own PDF.
          AND gr.gr_no >= start_gr_no$m$
]);

SELECT pg_temp.patch_function('public.get_dispatch_range_for_print(text, text, integer)'::regprocedure, ARRAY[
$m$        FROM dispatch d
    ),$m$
], ARRAY[
$m$        FROM dispatch d
        WHERE d.import_batch_id IS NULL  -- Migration 191 (WH-180): an imported dispatch prints through its own PDF.
    ),$m$
]);

-- ===== 2. "imported" in the lists and details =====
SELECT pg_temp.patch_function('public.get_grn_list(date, date, text, text, integer, integer, jsonb)'::regprocedure, ARRAY[
$m$                fg.invoiced,
                COALESCE(SUM(trl.qty), 0) AS total_qty,$m$,
$m$                     fg.supervisor_name, fg.supervisor_id, fg.invoiced
$m$,
$m$''invoiced'', ga.invoiced,
                                ''invoice_state'', warehouse_security.grn_invoice_state(ga.id),$m$
], ARRAY[
$m$                fg.invoiced,
                fg.import_batch_id,
                COALESCE(SUM(trl.qty), 0) AS total_qty,$m$,
$m$                     fg.supervisor_name, fg.supervisor_id, fg.invoiced, fg.import_batch_id
$m$,
$m$''invoiced'', ga.invoiced,
                                ''imported'', ga.import_batch_id IS NOT NULL,
                                ''invoice_state'', warehouse_security.grn_invoice_state(ga.id),$m$
]);

-- The app's GRN list reads get_all_grn_items (one row per GRN line), so each row says whether its GRN is imported too.
SELECT pg_temp.patch_function('public.get_all_grn_items(timestamp with time zone, timestamp with time zone, jsonb, text, text, integer, integer)'::regprocedure, ARRAY[
$m$                gr.invoiced,
                gr.note,$m$,
$m$''invoiced'', invoiced,
                        ''invoice_state'', warehouse_security.grn_invoice_state(id),$m$
], ARRAY[
$m$                gr.invoiced,
                gr.import_batch_id,
                gr.note,$m$,
$m$''invoiced'', invoiced,
                        ''imported'', import_batch_id IS NOT NULL,
                        ''invoice_state'', warehouse_security.grn_invoice_state(id),$m$
]);

SELECT pg_temp.patch_function('public.get_grn_details(uuid)'::regprocedure, ARRAY[
$m$                    'invoiced', COALESCE(gr.invoiced, false),
                    'leon', COALESCE(gr.leon, false),$m$
], ARRAY[
$m$                    'invoiced', COALESCE(gr.invoiced, false),
                    'imported', gr.import_batch_id IS NOT NULL,  -- Migration 191 (WH-180)
                    'leon', COALESCE(gr.leon, false),$m$
]);

SELECT pg_temp.patch_function('public.get_dispatch_list_with_items(uuid, jsonb, text, text, integer, integer, boolean)'::regprocedure, ARRAY[
$m$d.created_by, d.updated_by, d.note
                      FROM dispatch d WHERE d.id IN$m$,
$m$                    d.registration, d.created_at, d.updated_at, d.created_by, d.updated_by, d.note
                FROM dispatch d$m$,
$m$                        'disp_no', pr.disp_no,
                        'dispatch_date', pr.disp_date,$m$
], ARRAY[
$m$d.created_by, d.updated_by, d.note, d.import_batch_id
                      FROM dispatch d WHERE d.id IN$m$,
$m$                    d.registration, d.created_at, d.updated_at, d.created_by, d.updated_by, d.note, d.import_batch_id
                FROM dispatch d$m$,
$m$                        'disp_no', pr.disp_no,
                        'imported', pr.import_batch_id IS NOT NULL,
                        'dispatch_date', pr.disp_date,$m$
]);

SELECT pg_temp.patch_function('public.get_customer_dispatch_list(uuid, integer, integer, boolean)'::regprocedure, ARRAY[
$m$        'disp_no', d.disp_no,
        'disp_date', d.disp_date,$m$
], ARRAY[
$m$        'disp_no', d.disp_no,
        'imported', d.import_batch_id IS NOT NULL,  -- Migration 191 (WH-180)
        'disp_date', d.disp_date,$m$
]);

SELECT pg_temp.patch_function((SELECT p.oid FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
                                WHERE n.nspname = 'public' AND p.proname = 'get_invoices_list')::regprocedure, ARRAY[
$m$                       'linked_invoice_id', i.linked_invoice_id,
                       'total_qty', q.total_qty,$m$
], ARRAY[
$m$                       'linked_invoice_id', i.linked_invoice_id,
                       'imported', i.import_batch_id IS NOT NULL,  -- Migration 191 (WH-180)
                       'total_qty', q.total_qty,$m$
]);

SELECT pg_temp.patch_function('public.get_customer_statement(uuid)'::regprocedure, ARRAY[
$m$           'doc_type', i.doc_type, 'total', i.total,
           'payment_status', CASE WHEN v_payments THEN s.state->'payment_status' END,$m$
], ARRAY[
$m$           'doc_type', i.doc_type, 'total', i.total,
           'imported', i.import_batch_id IS NOT NULL,  -- Migration 191 (WH-180)
           'payment_status', CASE WHEN v_payments THEN s.state->'payment_status' END,$m$
]);

DROP FUNCTION pg_temp.patch_function(regprocedure, text[], text[]);

NOTIFY pgrst, 'reload schema';
