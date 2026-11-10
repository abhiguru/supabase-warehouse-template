-- Migration 176 (WH-155): what each customer owes, worked out by the server: the customer statement and the customer dues list.
--
-- Three figures per customer, never added into one total:
--   * Due on invoices: with Record payments on (migration 172), the sum of due_amount (warehouse_security.invoice_payment_state) over the
--     customer's live invoices of every year. Payments that name no invoice (the old accounting link) are not taken off it, as migration
--     172 keeps them out of the invoice figures; the statement answers them as unlinked_paid_amount. With Record payments off, the figure
--     is the total of the customer's live invoices of the current financial year (invoices_basis 'invoiced'; the app reads "Invoiced").
--   * Not yet invoiced: goods that have left. For each GRN, the review step's total (preview_invoice_documents) for all its dispatch lines
--     that are on no live invoice and whose dispatch is not deleted (the lines warehouse_security.grn_has_free_dispatch_line counts).
--   * Not yet invoiced: goods in store (an estimate). For each GRN, the review step's total if every lot with stock left today (India) in
--     one dispatch: the same form, the same rate lookup, charging rule, labour, tax and GST treatment as an invoice.
--   A lot with no rate adds nothing (its line prices at 0, as on the invoice form) and is counted once in lots_without_rate.
--
-- One pricing path. Nothing here prices a line itself:
--   * build_invoice_form_lines (the invoice form) gains one input, the transaction-local setting warehouse.form_in_store_date. Unset (the
--     invoice form, the rate check, every caller before this migration) the function answers exactly as before. Set to a day, the form's
--     rows are the GRN's lots with stock instead of its dispatch lines, each lot's stock as one notional dispatch on that day; rates,
--     duration (warehouse_security.charge_duration), storage (warehouse_security.storage_amount), labour and the tax % (GST treatment) are
--     then worked out by the unchanged rest of the function.
--   * preview_invoice_documents (the review step) is split, with the same answers: warehouse_security.form_document_lines (the chosen lines
--     of a form with their base and tax %) and warehouse_security.form_documents (which document(s) they make, and each document's
--     subtotal, tax and total, rounded by warehouse_security.round_invoice_total). The statement calls the same two functions.
--   * warehouse_security.grn_not_invoiced(gr, day) gives one GRN's two figures; warehouse_security.customer_dues_figures(customer, day)
--     adds them up with the invoices figure.
--
-- Reads (both answer as_of, the moment of the read, and today, the India day the estimate used):
--   * get_customer_statement(p_customer_id): administrators, supervisors, and a customer account for its assigned customers only; staff
--     and other roles are refused (authorize_rpc, 42501). {success, as_of, today, customer {id, name, active}, record_payments,
--     invoices_basis ('due' | 'invoiced'), figures {invoices_amount, not_invoiced_left, not_invoiced_in_store}, lots_without_rate,
--     unlinked_paid_amount (payments on, else null), left [{gr_id, gr_no, bags, amount}], in_store [{gr_id, gr_no, grn_date, days_in_store,
--     bags, amount, lots [{grn_item_id, item_name, packaging, bags, has_rate, amount (null without a rate)}]}], invoices [{id, inv_no,
--     inv_fin_year, inv_prefix, invoice_label, inv_date, gr_no, doc_type, total, payment_status, paid_amount, due_amount}]}. A lot's amount
--     is the review step's total for that lot alone, so the lots of a GRN can add up to a little more than the GRN's figure when the rule
--     rounds totals up. Invoices: the live ones of the current financial year, and with payments on also any older one with an amount
--     due; newest first; the payment fields are null with payments off. An unknown or deleted customer: {success:false, error:'Customer not
--     found'}.
--   * get_customer_dues(): administrators and supervisors only. {success, as_of, today, record_payments, invoices_basis, totals
--     {invoices_amount, not_invoiced_left, not_invoiced_in_store}, lots_without_rate, customers [{customer_id, name, active,
--     invoices_amount, not_invoiced_left, not_invoiced_in_store, lots_without_rate}]}: every customer (deactivated included, deleted not)
--     with any of the three figures above 0, ordered by invoices_amount + not_invoiced_left (largest first), then not_invoiced_in_store
--     (largest first), then the name. The totals and lots_without_rate are the facility's.
-- Amounts are numeric with 2 decimals. Nothing is stored; every read works the figures out again.
--
-- Worked by hand (made-up figures; default charging rule: steps of 15 days, minimum 30, days counted legacy, rounding up):
--   A. One-time rate 135.00, no labour, no tax: GRN of 500 bags received 2026-04-01; 200 dispatched 2026-04-20, not invoiced.
--      Goods that have left: 200 x 135.00 = 27000.00. Goods in store: 300 x 135.00 = 40500.00, on 2026-04-01 and on any later day
--      (one-time storage does not depend on the days).
--   B. Monthly rate 12.50, labour 3.00, tax 5 %, 10 bags received 2026-04-01, all in store, today 2026-05-11 (40 days): 1.5 months,
--      storage 187.50 + labour 30.00 = 217.50, tax ceil(10.875) = 11, estimate 229.00, exactly migration 164's invoice of the same 10
--      bags dispatched 2026-05-11. Today 2026-04-01 (received today): 1 day, the minimum 1 month: 125.00 + 30.00 = 155.00, tax ceil(7.75)
--      = 8, estimate 163.00. Rule steps of a day, minimum one step, rounding none, today 2026-05-11: 10 x 12.50 x 40 / 30 = 166.67 +
--      30.00 = 196.67, tax 9.83, estimate 206.50.
--   C. A lot with no rate: its line is 0.00 in both figures and lots_without_rate is 1.
--   D. Payments on: invoice of 10000.00 with 4000.00 recorded: due 6000.00 (part_paid); Due on invoices 6000.00. Payments off: the label
--      is Invoiced and the figure is 10000.00 when the invoice is of this financial year.
--   E. Mixed GRN (migration 173 example D: Jeera taxable 217.50 + tax, potatoes exempt 190.00), GST details saved, customer with a GSTIN:
--      tax invoice 229.00 + bill of supply 190.00 = 419.00; customer without one: one invoice-cum-bill of supply of 419.00.
--   F. Dues order: P (due 1000.00, left 0, store 50.00), Q (due 0, left 1000.00, store 500.00), R (due 200.00, left 0, store 9000.00),
--      S (all 0): Q, P, R; S is not listed.
--
-- The build_invoice_form_lines change is a marker-count patch (migration 164's pattern; each marker found exactly once, no replacement
-- contains its marker). authorize_rpc's change is in its definition file.

-- Section 1: the invoice form prices lots in store on a given day when warehouse.form_in_store_date is set.
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

SELECT pg_temp.patch_function('public.build_invoice_form_lines(uuid, text)'::regprocedure, ARRAY[
$m$    v_charging warehouse_security.charging_rule;
    v_grn_date date;$m$,
$m$AND NOT warehouse_security.gst_on_form_partner(dt.id)
    ),$m$
], ARRAY[
$m$    v_charging warehouse_security.charging_rule;
    -- Migration 176 (WH-155): the day of the statement's notional dispatch (warehouse.form_in_store_date); NULL for the invoice form.
    v_in_store date := NULLIF(current_setting('warehouse.form_in_store_date', true), '')::date;
    v_grn_date date;$m$,
$m$AND NOT warehouse_security.gst_on_form_partner(dt.id)
          AND v_in_store IS NULL
        UNION ALL
        -- Migration 176 (WH-155): the statement's estimate. Every lot with stock, its whole stock as one notional dispatch on v_in_store
        -- (no dispatch line: dt_id, d_id, the number and the moment are NULL), priced below exactly as a dispatch line of that day.
        SELECT grt.id, grt.item_id, grt.item_name, grt.packaging, grt.qty, grt.package_mark, grt.rack, grt.weight,
               NULL::uuid, grt.stock, NULL::uuid, NULL::character varying, NULL::timestamp with time zone,
               v_in_store, i.name
        FROM goodsreceived_trl grt
        LEFT JOIN items i ON i.id = grt.item_id
        WHERE grt.gr_id = p_gr_id AND v_in_store IS NOT NULL AND grt.stock > 0
    ),$m$
]);

DROP FUNCTION pg_temp.patch_function(regprocedure, text[], text[]);

-- Section 2: the review step's maths, shared by preview_invoice_documents and the statement.
-- The lines of a form as the review step groups them: those named by p_disp_trl_ids, or every line when it is NULL. Read while the form's
-- invoice (warehouse.form_invoice_id) is set, as the treatment of an edited line depends on it.
CREATE FUNCTION warehouse_security.form_document_lines(p_form jsonb, p_disp_trl_ids uuid[]) RETURNS jsonb
    LANGUAGE sql STABLE
    SET search_path TO 'pg_catalog', 'public'
    AS $$
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'dt_id', e->>'dispatches_items_id',
           'item_name', e->>'grn_items_item_name',
           'treatment', warehouse_security.gst_line_treatment((e->>'grn_items_item_id')::uuid, (e->>'dispatches_items_id')::uuid),
           'base', COALESCE((e->>'storage_amount')::numeric, 0)
                   + CASE WHEN e->>'grn_items_pricing_mode' = 'ONE_TIME' THEN 0
                          ELSE round(COALESCE((e->>'labour_rate')::numeric, 0) * COALESCE((e->>'dispatches_items_disp_qty')::numeric, 0), 2) END,
           'tax_percent', COALESCE((e->>'tax_percent')::numeric, 0),
           -- For the statement (not read by the review step): the lot, its packaging, the bags and whether a rate was found.
           'lot_id', e->>'grn_items_id',
           'packaging', e->>'grn_items_packaging',
           'qty', COALESCE((e->>'dispatches_items_disp_qty')::numeric, 0),
           'has_rate', COALESCE(jsonb_typeof(e->'unit_price'), 'null') <> 'null')), '[]'::jsonb)
    FROM jsonb_array_elements(p_form->'items') e
   WHERE p_disp_trl_ids IS NULL OR (e->>'dispatches_items_id')::uuid = ANY (p_disp_trl_ids)
$$;
ALTER FUNCTION warehouse_security.form_document_lines(jsonb, uuid[]) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION warehouse_security.form_document_lines(jsonb, uuid[]) FROM PUBLIC;

-- Which document(s) the lines make for the GRN's customer, and each document's figures before any discount. p_inv: the invoice being
-- edited (its stored type, details and customer decide), or NULL for a new invoice (the facility's GST details and the customer now).
-- Answers {kind, exempt_lines, taxable_lines, documents}; documents is null for an edit that would need two documents (the review step
-- refuses it).
CREATE FUNCTION warehouse_security.form_documents(p_lines jsonb, p_customer_id uuid, p_inv public.invoice, p_rounding text) RETURNS jsonb
    LANGUAGE plpgsql STABLE
    SET search_path TO 'pg_catalog', 'public', 'pg_temp'
    AS $$
DECLARE
  v_saved boolean;
  v_registered boolean;
  v_customer jsonb;
  v_supplier_state text;
  v_exempt integer;
  v_taxable integer;
  v_kind text;
  v_pos text;
  v_docs jsonb;
BEGIN
  IF p_inv.id IS NOT NULL THEN
    v_saved := p_inv.doc_type <> 'invoice';
    v_registered := p_inv.doc_type <> 'bill';
    v_supplier_state := p_inv.gst_supplier_state;
    v_customer := CASE WHEN p_inv.customer_id = p_customer_id
                       THEN jsonb_build_object('gstin', p_inv.gst_customer_gstin, 'state_code', p_inv.gst_customer_state)
                       ELSE warehouse_security.gst_customer(p_customer_id) END;
  ELSE
    v_saved := (warehouse_security.gst_settings()->>'saved')::boolean;
    v_registered := (warehouse_security.gst_settings()->>'registered')::boolean;
    v_supplier_state := CASE WHEN v_registered THEN warehouse_security.gst_settings()->>'state_code' END;
    v_customer := warehouse_security.gst_customer(p_customer_id);
  END IF;
  SELECT count(*) FILTER (WHERE l.treatment = 'exempt_agri'), count(*) FILTER (WHERE l.treatment IS DISTINCT FROM 'exempt_agri')
    INTO v_exempt, v_taxable
    FROM jsonb_to_recordset(p_lines) AS l(dt_id uuid, item_name text, treatment text, base numeric, tax_percent numeric);
  v_kind := warehouse_security.gst_document_kind(v_saved, v_registered, v_customer->>'gstin' IS NOT NULL, v_exempt, v_taxable);
  IF v_kind = 'split' AND p_inv.id IS NOT NULL THEN
    RETURN jsonb_build_object('kind', v_kind, 'exempt_lines', v_exempt, 'taxable_lines', v_taxable, 'documents', NULL);
  END IF;
  v_pos := COALESCE(v_customer->>'state_code', v_supplier_state);

  WITH grouped AS (
    SELECT CASE WHEN v_kind = 'split' THEN CASE WHEN l.treatment = 'exempt_agri' THEN 'bill_of_supply' ELSE 'tax_invoice' END
                ELSE v_kind END AS doc_type,
           l.*
      FROM jsonb_to_recordset(p_lines) AS l(dt_id uuid, item_name text, treatment text, base numeric, tax_percent numeric)
  ), sums AS (
    SELECT g.doc_type,
           jsonb_agg(g.dt_id ORDER BY g.dt_id) AS lines,
           jsonb_agg(DISTINCT g.item_name) AS item_names,
           sum(g.base)::numeric(12,2) AS subtotal,
           warehouse_security.round_invoice_total(sum(g.base * g.tax_percent / 100.0), p_rounding)::numeric(12,2) AS tax
      FROM grouped g GROUP BY g.doc_type
  ), heads AS (
    SELECT s.*, CASE WHEN s.doc_type IN ('tax_invoice', 'invoice_cum_bos')
                     THEN CASE WHEN v_pos IS NOT DISTINCT FROM v_supplier_state THEN 'cgst_sgst' ELSE 'igst' END END AS head
      FROM sums s
  )
  SELECT jsonb_agg(jsonb_build_object(
           'doc_type', h.doc_type, 'disp_trl_ids', h.lines, 'item_names', h.item_names,
           'subtotal', h.subtotal, 'tax', h.tax,
           'total', warehouse_security.round_invoice_total(h.subtotal + h.tax, p_rounding)::numeric(12,2),
           'tax_head', h.head,
           'place_of_supply', CASE WHEN h.head IS NOT NULL THEN v_pos END,
           'cgst_amount', CASE WHEN h.head = 'cgst_sgst' THEN warehouse_security.gst_half(h.tax) END,
           'sgst_amount', CASE WHEN h.head = 'cgst_sgst' THEN h.tax - warehouse_security.gst_half(h.tax) END,
           'igst_amount', CASE WHEN h.head = 'igst' THEN h.tax END)
         ORDER BY CASE h.doc_type WHEN 'bill_of_supply' THEN 1 ELSE 0 END)
    INTO v_docs FROM heads h;

  RETURN jsonb_build_object('kind', v_kind, 'exempt_lines', v_exempt, 'taxable_lines', v_taxable, 'documents', v_docs);
END $$;
ALTER FUNCTION warehouse_security.form_documents(jsonb, uuid, public.invoice, text) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION warehouse_security.form_documents(jsonb, uuid, public.invoice, text) FROM PUBLIC;

-- The review step, answering exactly as migration 173's: its maths are now the two functions above.
CREATE OR REPLACE FUNCTION public.preview_invoice_documents(p_gr_id uuid, p_disp_trl_ids uuid[], p_invoice_id uuid DEFAULT NULL::uuid,
                                                            p_duration_mode text DEFAULT NULL::text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'pg_temp'
    AS $$
DECLARE
  v_inv public.invoice;
  v_form jsonb;
  v_rounding text;
  v_customer_id uuid;
  v_set jsonb;
  v_docs jsonb;
  v_lines jsonb;
BEGIN
  PERFORM warehouse_security.authorize_rpc('preview_invoice_documents', jsonb_build_object('p_invoice_id', p_invoice_id));
  IF p_disp_trl_ids IS NULL OR cardinality(p_disp_trl_ids) = 0 THEN
    RETURN jsonb_build_object('success', false, 'error', 'Choose at least one dispatch line');
  END IF;
  IF p_invoice_id IS NOT NULL THEN
    SELECT * INTO v_inv FROM public.invoice i WHERE i.id = p_invoice_id AND i.deleted_at IS NULL AND i.cancelled_at IS NULL;
    IF NOT FOUND THEN
      RETURN jsonb_build_object('success', false, 'error', 'Invoice not found');
    END IF;
  END IF;
  SELECT g.customer_id INTO v_customer_id FROM public.goodsreceived g WHERE g.id = p_gr_id AND g.deleted_at IS NULL;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'GRN not found');
  END IF;

  PERFORM set_config('warehouse.form_invoice_id', COALESCE(p_invoice_id::text, ''), true);
  v_form := public.build_invoice_form_lines(p_gr_id, p_duration_mode);
  v_rounding := (warehouse_security.form_charging_rule()).rounding;
  -- The chosen lines with their treatment, read while the edited invoice is the form's.
  IF v_form->>'success' = 'true' THEN
    v_lines := warehouse_security.form_document_lines(v_form, p_disp_trl_ids);
  END IF;
  PERFORM set_config('warehouse.form_invoice_id', '', true);
  IF v_form->>'success' IS DISTINCT FROM 'true' THEN
    RETURN v_form;
  END IF;
  IF jsonb_array_length(v_lines) <> (SELECT count(DISTINCT x) FROM unnest(p_disp_trl_ids) x) THEN
    RETURN warehouse_security.refuse('UNKNOWN_LINE', 'A dispatch line is not on this GRN''s invoice form.');
  END IF;

  v_set := warehouse_security.form_documents(v_lines, v_customer_id, v_inv, v_rounding);
  IF v_set->>'kind' = 'split' AND p_invoice_id IS NOT NULL THEN
    RETURN warehouse_security.refuse('EDIT_NEEDS_TWO_DOCUMENTS',
      'These lines need a tax invoice and a separate bill of supply. Keep only the taxable lines or only the exempt ones, or delete this invoice and make it again.',
      jsonb_build_object('invoice_id', p_invoice_id, 'exempt_lines', v_set->'exempt_lines', 'taxable_lines', v_set->'taxable_lines'));
  END IF;
  v_docs := NULLIF(v_set->'documents', 'null'::jsonb);

  RETURN jsonb_build_object('success', true, 'documents', v_docs, 'document_count', jsonb_array_length(v_docs),
    'current_doc_type', v_inv.doc_type,
    'type_changes', p_invoice_id IS NOT NULL AND (v_set->>'kind') IS DISTINCT FROM v_inv.doc_type);
END $$;

-- Section 3: one GRN's two figures. Not a reader by itself: the RPCs below authorize first.
CREATE FUNCTION warehouse_security.grn_not_invoiced(p_gr_id uuid, p_today date) RETURNS jsonb
    LANGUAGE plpgsql
    SET search_path TO 'pg_catalog', 'public', 'pg_temp'
    AS $$
DECLARE
  v_grn record;
  v_rounding text := (warehouse_security.current_charging_rule()).rounding;
  v_free uuid[];
  v_form jsonb;
  v_lines jsonb;
  v_docs jsonb;
  v_left jsonb;
  v_store jsonb;
  v_no_rate jsonb := '[]'::jsonb;
BEGIN
  SELECT g.gr_no, g.customer_id, warehouse_security.business_date(g.date) AS grn_date INTO v_grn
    FROM public.goodsreceived g WHERE g.id = p_gr_id AND g.deleted_at IS NULL;
  IF NOT FOUND THEN
    RETURN NULL;
  END IF;
  -- The form of a new invoice: no invoice being edited, so the facility's charging rule and GST details.
  PERFORM set_config('warehouse.form_invoice_id', '', true);
  PERFORM set_config('warehouse.form_in_store_date', '', true);

  -- Goods that have left: the review step for every dispatch line on no live invoice (dispatch not deleted).
  SELECT array_agg(dt.id) INTO v_free
    FROM public.dispatch_trl dt
    JOIN public.goodsreceived_trl grt ON grt.id = dt.gr_trl_id
    JOIN public.dispatch d ON d.id = dt.disp_id AND d.deleted_at IS NULL
   WHERE grt.gr_id = p_gr_id
     AND NOT EXISTS (SELECT 1 FROM public.invoice_trl it JOIN public.invoice iv ON iv.id = it.invoice_id
                     WHERE it.disp_trl_id = dt.id AND iv.deleted_at IS NULL AND iv.cancelled_at IS NULL);
  IF v_free IS NOT NULL THEN
    v_form := public.build_invoice_form_lines(p_gr_id, NULL);
    IF v_form->>'success' = 'true' THEN
      v_lines := warehouse_security.form_document_lines(v_form, v_free);
      IF jsonb_array_length(v_lines) > 0 THEN
        v_docs := COALESCE(NULLIF(warehouse_security.form_documents(v_lines, v_grn.customer_id, NULL::public.invoice, v_rounding)->'documents',
                                  'null'::jsonb), '[]'::jsonb);
        v_left := jsonb_build_object(
          'bags', (SELECT sum((l->>'qty')::numeric) FROM jsonb_array_elements(v_lines) l),
          'amount', (SELECT COALESCE(sum((d->>'total')::numeric), 0) FROM jsonb_array_elements(v_docs) d)::numeric(14,2));
        v_no_rate := v_no_rate || (SELECT COALESCE(jsonb_agg(DISTINCT l->'lot_id'), '[]'::jsonb)
                                     FROM jsonb_array_elements(v_lines) l WHERE NOT (l->>'has_rate')::boolean);
      END IF;
    END IF;
  END IF;

  -- Goods in store: the same form with every lot's stock as one dispatch today.
  IF EXISTS (SELECT 1 FROM public.goodsreceived_trl t WHERE t.gr_id = p_gr_id AND t.stock > 0) THEN
    PERFORM set_config('warehouse.form_in_store_date', to_char(p_today, 'YYYY-MM-DD'), true);
    v_form := public.build_invoice_form_lines(p_gr_id, NULL);
    PERFORM set_config('warehouse.form_in_store_date', '', true);
    IF v_form->>'success' = 'true' THEN
      v_lines := warehouse_security.form_document_lines(v_form, NULL);
      IF jsonb_array_length(v_lines) > 0 THEN
        v_docs := COALESCE(NULLIF(warehouse_security.form_documents(v_lines, v_grn.customer_id, NULL::public.invoice, v_rounding)->'documents',
                                  'null'::jsonb), '[]'::jsonb);
        v_store := jsonb_build_object(
          'bags', (SELECT sum((l->>'qty')::numeric) FROM jsonb_array_elements(v_lines) l),
          'amount', (SELECT COALESCE(sum((d->>'total')::numeric), 0) FROM jsonb_array_elements(v_docs) d)::numeric(14,2),
          -- Each lot: the review step's total for that lot alone; no amount without a rate.
          'lots', (SELECT jsonb_agg(jsonb_build_object(
                     'grn_item_id', l->'lot_id', 'item_name', l->'item_name', 'packaging', l->'packaging', 'bags', l->'qty',
                     'has_rate', l->'has_rate',
                     'amount', CASE WHEN (l->>'has_rate')::boolean THEN (
                       SELECT COALESCE(sum((d->>'total')::numeric), 0)::numeric(14,2)
                         FROM jsonb_array_elements(COALESCE(NULLIF(warehouse_security.form_documents(jsonb_build_array(l), v_grn.customer_id,
                                NULL::public.invoice, v_rounding)->'documents', 'null'::jsonb), '[]'::jsonb)) d) END)
                     ORDER BY l->>'item_name', l->>'lot_id')
                   FROM jsonb_array_elements(v_lines) l));
        v_no_rate := v_no_rate || (SELECT COALESCE(jsonb_agg(DISTINCT l->'lot_id'), '[]'::jsonb)
                                     FROM jsonb_array_elements(v_lines) l WHERE NOT (l->>'has_rate')::boolean);
      END IF;
    END IF;
  END IF;

  RETURN jsonb_build_object('gr_id', p_gr_id, 'gr_no', v_grn.gr_no, 'grn_date', v_grn.grn_date,
    'days_in_store', p_today - v_grn.grn_date, 'left', v_left, 'in_store', v_store, 'no_rate_lot_ids', v_no_rate);
END $$;
ALTER FUNCTION warehouse_security.grn_not_invoiced(uuid, date) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION warehouse_security.grn_not_invoiced(uuid, date) FROM PUBLIC;

-- Section 4: one customer's three figures, with the GRN rows when p_rows.
CREATE FUNCTION warehouse_security.customer_dues_figures(p_customer_id uuid, p_today date, p_rows boolean) RETURNS jsonb
    LANGUAGE plpgsql
    SET search_path TO 'pg_catalog', 'public', 'pg_temp'
    AS $$
DECLARE
  v_gr record;
  v_one jsonb;
  v_left numeric(14,2) := 0;
  v_store numeric(14,2) := 0;
  v_left_rows jsonb := '[]'::jsonb;
  v_store_rows jsonb := '[]'::jsonb;
  v_no_rate jsonb := '[]'::jsonb;
  v_invoices numeric(14,2);
BEGIN
  FOR v_gr IN
    SELECT g.id FROM public.goodsreceived g
     WHERE g.customer_id = p_customer_id AND g.deleted_at IS NULL
       AND (EXISTS (SELECT 1 FROM public.goodsreceived_trl t WHERE t.gr_id = g.id AND t.stock > 0)
            OR warehouse_security.grn_has_free_dispatch_line(g.id))
     ORDER BY g.date, g.gr_no, g.id
  LOOP
    v_one := warehouse_security.grn_not_invoiced(v_gr.id, p_today);
    CONTINUE WHEN v_one IS NULL;
    IF jsonb_typeof(v_one->'left') = 'object' THEN
      v_left := v_left + (v_one->'left'->>'amount')::numeric;
      IF p_rows THEN
        v_left_rows := v_left_rows || jsonb_build_array(jsonb_build_object('gr_id', v_one->'gr_id', 'gr_no', v_one->'gr_no',
          'bags', v_one->'left'->'bags', 'amount', v_one->'left'->'amount'));
      END IF;
    END IF;
    IF jsonb_typeof(v_one->'in_store') = 'object' THEN
      v_store := v_store + (v_one->'in_store'->>'amount')::numeric;
      IF p_rows THEN
        v_store_rows := v_store_rows || jsonb_build_array(jsonb_build_object('gr_id', v_one->'gr_id', 'gr_no', v_one->'gr_no',
          'grn_date', v_one->'grn_date', 'days_in_store', v_one->'days_in_store', 'bags', v_one->'in_store'->'bags',
          'amount', v_one->'in_store'->'amount', 'lots', v_one->'in_store'->'lots'));
      END IF;
    END IF;
    v_no_rate := v_no_rate || (v_one->'no_rate_lot_ids');
  END LOOP;

  IF warehouse_security.payments_enabled() THEN
    SELECT COALESCE(sum((warehouse_security.invoice_payment_state(i.id)->>'due_amount')::numeric), 0) INTO v_invoices
      FROM public.invoice i WHERE i.customer_id = p_customer_id AND i.deleted_at IS NULL AND i.cancelled_at IS NULL;
  ELSE
    SELECT COALESCE(sum(i.total), 0) INTO v_invoices
      FROM public.invoice i WHERE i.customer_id = p_customer_id AND i.deleted_at IS NULL AND i.cancelled_at IS NULL
       AND i.inv_fin_year = warehouse_security.financial_year(p_today);
  END IF;

  RETURN jsonb_build_object('invoices_amount', v_invoices, 'not_invoiced_left', v_left, 'not_invoiced_in_store', v_store,
    'no_rate_lot_ids', (SELECT COALESCE(jsonb_agg(DISTINCT x), '[]'::jsonb) FROM jsonb_array_elements(v_no_rate) x),
    'left_rows', CASE WHEN p_rows THEN v_left_rows END, 'in_store_rows', CASE WHEN p_rows THEN v_store_rows END);
END $$;
ALTER FUNCTION warehouse_security.customer_dues_figures(uuid, date, boolean) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION warehouse_security.customer_dues_figures(uuid, date, boolean) FROM PUBLIC;

-- Section 5: the reads.
CREATE FUNCTION public.get_customer_statement(p_customer_id uuid) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'extensions', 'utils', 'pg_temp'
    AS $$
DECLARE
  v_customer record;
  v_today date := warehouse_security.business_date(now());
  v_payments boolean := warehouse_security.payments_enabled();
  v_fig jsonb;
  v_invoices jsonb;
BEGIN
  PERFORM warehouse_security.authorize_rpc('get_customer_statement', jsonb_build_object('p_customer_id', p_customer_id));
  -- Administrators, supervisors and customer accounts (authorize_rpc checks that the customer is the account's own); never staff.
  IF warehouse_security.active_role() IS DISTINCT FROM 'admin' AND warehouse_security.active_role() IS DISTINCT FROM 'supervisor'
     AND warehouse_security.active_role() IS DISTINCT FROM 'customer' AND auth.jwt()->>'role' IS DISTINCT FROM 'service_role' THEN
    RAISE EXCEPTION 'Customer access denied' USING ERRCODE = '42501';
  END IF;
  SELECT c.id, c.name, c.active INTO v_customer FROM public.customers c WHERE c.id = p_customer_id AND c.deleted_at IS NULL;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'Customer not found');
  END IF;

  v_fig := warehouse_security.customer_dues_figures(p_customer_id, v_today, true);

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'id', i.id, 'inv_no', i.inv_no, 'inv_fin_year', i.inv_fin_year, 'inv_prefix', i.inv_prefix,
           'invoice_label', warehouse_security.invoice_label(i.inv_prefix, i.inv_no), 'inv_date', i.inv_date, 'gr_no', i.gr_no,
           'doc_type', i.doc_type, 'total', i.total,
           'payment_status', CASE WHEN v_payments THEN s.state->'payment_status' END,
           'paid_amount', CASE WHEN v_payments THEN s.state->'paid_amount' END,
           'due_amount', CASE WHEN v_payments THEN s.state->'due_amount' END)
         ORDER BY i.inv_date DESC, i.inv_fin_year DESC, i.inv_no DESC, i.id), '[]'::jsonb)
    INTO v_invoices
    FROM public.invoice i
    CROSS JOIN LATERAL (SELECT warehouse_security.invoice_payment_state(i.id) AS state) s
   WHERE i.customer_id = p_customer_id AND i.deleted_at IS NULL AND i.cancelled_at IS NULL
     AND (i.inv_fin_year = warehouse_security.financial_year(v_today)
          OR (v_payments AND (s.state->>'due_amount')::numeric > 0));

  RETURN jsonb_build_object('success', true, 'as_of', now(), 'today', v_today,
    'customer', jsonb_build_object('id', v_customer.id, 'name', v_customer.name, 'active', v_customer.active),
    'record_payments', v_payments,
    'invoices_basis', CASE WHEN v_payments THEN 'due' ELSE 'invoiced' END,
    'figures', jsonb_build_object('invoices_amount', v_fig->'invoices_amount', 'not_invoiced_left', v_fig->'not_invoiced_left',
                                  'not_invoiced_in_store', v_fig->'not_invoiced_in_store'),
    'lots_without_rate', jsonb_array_length(v_fig->'no_rate_lot_ids'),
    'unlinked_paid_amount', CASE WHEN v_payments THEN warehouse_security.unlinked_payments_total(p_customer_id, NULL, NULL)::numeric(14,2) END,
    'left', v_fig->'left_rows', 'in_store', v_fig->'in_store_rows', 'invoices', v_invoices);
END $$;
ALTER FUNCTION public.get_customer_statement(uuid) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION public.get_customer_statement(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.get_customer_statement(uuid) TO authenticated, service_role;

CREATE FUNCTION public.get_customer_dues() RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'extensions', 'utils', 'pg_temp'
    AS $$
DECLARE
  v_today date := warehouse_security.business_date(now());
  v_payments boolean := warehouse_security.payments_enabled();
  v_c record;
  v_fig jsonb;
  v_rows jsonb := '[]'::jsonb;
  v_no_rate jsonb := '[]'::jsonb;
BEGIN
  PERFORM warehouse_security.authorize_rpc('get_customer_dues', jsonb_build_object());
  IF warehouse_security.active_role() IS DISTINCT FROM 'admin' AND warehouse_security.active_role() IS DISTINCT FROM 'supervisor'
     AND auth.jwt()->>'role' IS DISTINCT FROM 'service_role' THEN
    RAISE EXCEPTION 'Administrator or supervisor required' USING ERRCODE = '42501';
  END IF;

  -- Every customer that may owe: a live invoice, stock in store, or a dispatch line on no live invoice.
  FOR v_c IN
    SELECT c.id, c.name, c.active FROM public.customers c
     WHERE c.deleted_at IS NULL
       AND (EXISTS (SELECT 1 FROM public.invoice i WHERE i.customer_id = c.id AND i.deleted_at IS NULL AND i.cancelled_at IS NULL)
            OR EXISTS (SELECT 1 FROM public.goodsreceived g WHERE g.customer_id = c.id AND g.deleted_at IS NULL
                         AND (EXISTS (SELECT 1 FROM public.goodsreceived_trl t WHERE t.gr_id = g.id AND t.stock > 0)
                              OR warehouse_security.grn_has_free_dispatch_line(g.id))))
  LOOP
    v_fig := warehouse_security.customer_dues_figures(v_c.id, v_today, false);
    v_no_rate := v_no_rate || (v_fig->'no_rate_lot_ids');
    IF (v_fig->>'invoices_amount')::numeric > 0 OR (v_fig->>'not_invoiced_left')::numeric > 0
       OR (v_fig->>'not_invoiced_in_store')::numeric > 0 THEN
      v_rows := v_rows || jsonb_build_array(jsonb_build_object('customer_id', v_c.id, 'name', v_c.name, 'active', v_c.active,
        'invoices_amount', v_fig->'invoices_amount', 'not_invoiced_left', v_fig->'not_invoiced_left',
        'not_invoiced_in_store', v_fig->'not_invoiced_in_store', 'lots_without_rate', jsonb_array_length(v_fig->'no_rate_lot_ids')));
    END IF;
  END LOOP;

  RETURN jsonb_build_object('success', true, 'as_of', now(), 'today', v_today, 'record_payments', v_payments,
    'invoices_basis', CASE WHEN v_payments THEN 'due' ELSE 'invoiced' END,
    'totals', jsonb_build_object(
      'invoices_amount', (SELECT COALESCE(sum((r->>'invoices_amount')::numeric), 0)::numeric(14,2) FROM jsonb_array_elements(v_rows) r),
      'not_invoiced_left', (SELECT COALESCE(sum((r->>'not_invoiced_left')::numeric), 0)::numeric(14,2) FROM jsonb_array_elements(v_rows) r),
      'not_invoiced_in_store', (SELECT COALESCE(sum((r->>'not_invoiced_in_store')::numeric), 0)::numeric(14,2) FROM jsonb_array_elements(v_rows) r)),
    'lots_without_rate', (SELECT count(DISTINCT x) FROM jsonb_array_elements(v_no_rate) x),
    'customers', (SELECT COALESCE(jsonb_agg(r ORDER BY (r->>'invoices_amount')::numeric + (r->>'not_invoiced_left')::numeric DESC,
                                              (r->>'not_invoiced_in_store')::numeric DESC, lower(r->>'name'), r->>'name', r->>'customer_id'),
                                    '[]'::jsonb)
                    FROM jsonb_array_elements(v_rows) r));
END $$;
ALTER FUNCTION public.get_customer_dues() OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION public.get_customer_dues() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.get_customer_dues() TO authenticated, service_role;

NOTIFY pgrst, 'reload schema';
