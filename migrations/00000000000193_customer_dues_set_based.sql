-- Migration 193 (WH-187): Customer dues and the customer statement work out their figures in one pass over the facility instead of
-- one invoice form per GRN. Every figure is the same, to the paisa, as migration 176's (and 191's): only how they are worked out changes.
--
-- Before: get_customer_dues called warehouse_security.customer_dues_figures once per customer, which called
-- warehouse_security.grn_not_invoiced once per GRN with stock or a dispatch line on no live invoice, which ran the whole invoice form
-- (build_invoice_form_lines, form_document_lines, form_documents) up to twice for that GRN. The time grew with every open GRN of every
-- customer (on a test set of 32,000 GRNs and 3,200 customers, about 4,700 forms and 9 seconds a read).
--
-- Now: warehouse_security.not_invoiced_grns(customer or NULL for all, day) answers, for every such GRN at once, the two figures
-- grn_not_invoiced answered: the goods that have left (every dispatch line on no live invoice and not taken as billed by a live imported
-- invoice (migration 192's imported_billed_dispatches), dispatch not deleted) and the goods in
-- store (each lot's stock as one notional dispatch on the day), with the lots and the lots without a rate. It is the invoice form of a
-- new invoice (no invoice being edited, warehouse.form_invoice_id unset) written as one query over many GRNs:
--   * rows, rate source and rate (the GRN's own rate, else find_storage_price on the GRN date), duration (charge_duration, once per GRN
--     day and dispatch day), storage (storage_amount), labour, and the tax % (0 when gst_zero_tax would answer true: GST details saved and
--     the facility not registered, or registered and the item exempt) as build_invoice_form_lines works them out;
--   * each line's base and tax %, and the lot's figure, as form_document_lines and grn_not_invoiced work them out;
--   * the document(s) the lines make (gst_document_kind with the facility's GST details and the customer's GSTIN) and each document's
--     subtotal, tax and total (round_invoice_total with the facility's rounding), as form_documents works them out.
--   The shared rules stay in their functions (find_storage_price, charge_duration, storage_amount, round_invoice_total,
--   gst_document_kind, gst_settings, gst_customer, current_charging_rule); what this function repeats is how the form puts them together
--   for a new invoice. A change to build_invoice_form_lines, form_document_lines or form_documents that changes a new invoice's figures
--   must be made here too.
-- customer_dues_figures (the statement) and get_customer_dues read it; get_customer_dues also works out the invoices figure for every
-- customer in one query (invoice_payment_state's due, total less paid and never below 0, for all live invoices at once) instead of once
-- per customer. JIT is off for both reads: the plans' estimates would start a compilation slower than the read. Nothing is stored; every read
-- works every figure out again from today's rates, dispatches and payments.
-- grn_not_invoiced has no caller left and is dropped. preview_invoice_documents, form_document_lines and form_documents are unchanged.
--
-- No role is created, altered or dropped. No table, column or grant of an existing function changes.

-- Section 1: the not-invoiced figures of every GRN of one customer (or of every live customer), one row per GRN with stock or a
-- dispatch line on no live invoice. Not a reader by itself: the RPCs authorize first.
CREATE FUNCTION warehouse_security.not_invoiced_grns(p_customer_id uuid, p_today date)
    RETURNS TABLE(customer_id uuid, gr_id uuid, gr_no character varying, gr_moment timestamp with time zone, grn_date date,
                  left_bags numeric, left_amount numeric, store_bags numeric, store_amount numeric, store_lots jsonb, no_rate_lot_ids text[])
    LANGUAGE sql STABLE
    SET search_path TO 'pg_catalog', 'public', 'pg_temp'
    -- The planner's estimate for this query is far above its real cost (the duration function is costed as 1,000 rows a call), which
    -- would start JIT compilation that takes longer than the query itself.
    SET jit TO 'off'
    AS $$
  WITH ctx AS MATERIALIZED (
    -- The form of a new invoice: the facility's charging rule (days counted as the rule says) and GST details.
    SELECT r.step_days, r.minimum_days, r.rounding, public.validate_invoice_duration_mode(r.days_counted) AS days_mode,
           (s.gst->>'saved')::boolean AS gst_saved, (s.gst->>'registered')::boolean AS gst_registered
      FROM warehouse_security.current_charging_rule() r
     CROSS JOIN (SELECT warehouse_security.gst_settings() AS gst) s
  ),
  grns AS MATERIALIZED (
    -- Live GRNs of live customers with a lot in stock or a dispatch line on no live invoice (grn_has_free_dispatch_line's lines).
    SELECT g.id, g.gr_no, g.date, g.customer_id, g.pricing_mode,
           warehouse_security.business_date(g.date) AS grn_date,
           CASE WHEN upper(COALESCE(g.pricing_mode, '')) = 'ONE_TIME' THEN 'one_time' ELSE 'monthly' END AS price_type,
           g.pricing_mode = 'ONE_TIME' AS one_time
      FROM public.goodsreceived g
      JOIN public.customers c ON c.id = g.customer_id AND c.deleted_at IS NULL
     WHERE g.deleted_at IS NULL
       AND (p_customer_id IS NULL OR g.customer_id = p_customer_id)
       AND (EXISTS (SELECT 1 FROM public.goodsreceived_trl t WHERE t.gr_id = g.id AND t.stock > 0)
            OR EXISTS (SELECT 1 FROM public.dispatch_trl dt
                        JOIN public.dispatch d ON d.id = dt.disp_id AND d.deleted_at IS NULL
                       WHERE dt.gr_id = g.id
                         AND NOT EXISTS (SELECT 1 FROM public.invoice_trl it JOIN public.invoice iv ON iv.id = it.invoice_id
                                          WHERE it.disp_trl_id = dt.id AND iv.deleted_at IS NULL AND iv.cancelled_at IS NULL)
                         AND NOT EXISTS (SELECT 1 FROM public.imported_billed_dispatches b JOIN public.invoice bi ON bi.id = b.invoice_id
                                          WHERE b.disp_trl_id = dt.id AND bi.deleted_at IS NULL AND bi.cancelled_at IS NULL)))
  ),
  raw AS MATERIALIZED (
    -- Goods that have left: every dispatch line of the GRN's lots on no live invoice, dispatch not deleted.
    SELECT gr.id AS gr_id, false AS in_store, grt.id AS lot_id, grt.item_id, grt.item_name, grt.packaging, grt.weight,
           dt.disp_qty AS qty, warehouse_security.business_date(d.disp_date) AS day
      FROM grns gr
      JOIN public.goodsreceived_trl grt ON grt.gr_id = gr.id
      JOIN public.dispatch_trl dt ON dt.gr_trl_id = grt.id
      JOIN public.dispatch d ON d.id = dt.disp_id AND d.deleted_at IS NULL
     WHERE NOT EXISTS (SELECT 1 FROM public.invoice_trl it JOIN public.invoice iv ON iv.id = it.invoice_id
                        WHERE it.disp_trl_id = dt.id AND iv.deleted_at IS NULL AND iv.cancelled_at IS NULL)
       -- Migration 192 (WH-180): nor taken as billed by a live imported invoice.
       AND NOT EXISTS (SELECT 1 FROM public.imported_billed_dispatches b JOIN public.invoice bi ON bi.id = b.invoice_id
                        WHERE b.disp_trl_id = dt.id AND bi.deleted_at IS NULL AND bi.cancelled_at IS NULL)
    UNION ALL
    -- Goods in store: every lot with stock, its whole stock as one dispatch on p_today.
    SELECT gr.id, true, grt.id, grt.item_id, grt.item_name, grt.packaging, grt.weight, grt.stock, p_today
      FROM grns gr
      JOIN public.goodsreceived_trl grt ON grt.gr_id = gr.id
     WHERE grt.stock > 0
  ),
  rates AS MATERIALIZED (
    -- One rate per GRN, item and weight: the GRN's own rate, else the item's (build_invoice_form_lines' rates).
    SELECT p.gr_id, p.item_id, p.weight,
           CASE WHEN o.id IS NOT NULL THEN o.unit_price ELSE fp.unit_price END AS src_unit,
           CASE WHEN o.id IS NOT NULL THEN o.labour_rate ELSE fp.labour_rate END AS src_labour,
           CASE WHEN o.id IS NOT NULL THEN o.tax_percent ELSE fp.tax_percent END AS src_tax
      FROM (SELECT DISTINCT r.gr_id, r.item_id, r.weight FROM raw r) p
      JOIN grns gr ON gr.id = p.gr_id
      LEFT JOIN LATERAL (
          SELECT g2.id, g2.unit_price, g2.labour_rate, g2.tax_percent
            FROM public.grn_rates g2
           WHERE g2.gr_id = p.gr_id AND g2.item_id = p.item_id
             AND g2.price_type = gr.price_type
             AND COALESCE(p.weight, 0) BETWEEN g2.weight_min AND g2.weight_max
           ORDER BY (g2.weight_max - g2.weight_min), g2.weight_min
           LIMIT 1
      ) o ON true
      LEFT JOIN LATERAL (
          SELECT f.unit_price, f.labour_rate, f.tax_percent
            FROM public.find_storage_price(p.item_id, gr.customer_id, p.weight, gr.grn_date, lower(gr.pricing_mode)) f
           WHERE o.id IS NULL
      ) fp ON true
  ),
  dur AS MATERIALIZED (
    -- The duration, once per GRN day and dispatch day.
    SELECT x.grn_date, x.day, c.no_of_days, c.duration
      FROM (SELECT DISTINCT gr.grn_date, r.day FROM raw r JOIN grns gr ON gr.id = r.gr_id) x
     CROSS JOIN ctx
     CROSS JOIN LATERAL warehouse_security.charge_duration(x.grn_date, x.day, ctx.days_mode, ctx.step_days, ctx.minimum_days) c
  ),
  priced AS MATERIALIZED (
    -- Each line as the form prices it, then its base (storage + labour) and tax % as the review step reads them.
    SELECT r.gr_id, r.in_store, r.lot_id, r.item_name, r.packaging,
           COALESCE(r.qty::numeric, 0) AS qty,
           COALESCE(i.gst_treatment, 'taxable') AS treatment,
           u.unit_price IS NOT NULL AS has_rate,
           COALESCE(u.tax_percent, 0) AS tax_percent,
           COALESCE(CASE WHEN gr.one_time THEN ROUND(COALESCE(u.unit_price, 0) * r.qty, 2)::numeric(12,2)
                         ELSE warehouse_security.storage_amount(COALESCE(u.unit_price, 0), r.qty, dur.duration, dur.no_of_days,
                                                                ctx.step_days, ctx.minimum_days)::numeric(12,2) END, 0)
             + CASE WHEN gr.pricing_mode = 'ONE_TIME' THEN 0
                    ELSE round(COALESCE(u.labour_rate, 0) * COALESCE(r.qty::numeric, 0), 2) END AS base
      FROM raw r
      JOIN grns gr ON gr.id = r.gr_id
      CROSS JOIN ctx
      JOIN rates rt ON rt.gr_id = r.gr_id AND rt.item_id = r.item_id AND rt.weight IS NOT DISTINCT FROM r.weight
      -- NULL-safe on the GRN date too (WH-190): a GRN saved with no date (goodsreceived.date allows none; no save path leaves it empty
      -- today) is priced as the form prices it, with the duration charge_duration gives for no GRN date, not dropped.
      JOIN dur ON dur.grn_date IS NOT DISTINCT FROM gr.grn_date AND dur.day IS NOT DISTINCT FROM r.day
      LEFT JOIN public.items i ON i.id = r.item_id
      CROSS JOIN LATERAL (
          SELECT rt.src_unit::numeric(12,2) AS unit_price,
                 COALESCE(rt.src_labour, 0)::numeric(12,2) AS labour_rate,
                 -- gst_zero_tax for a new invoice: no tax before GST details are saved; none for a facility not registered; else none
                 -- on an exempt item.
                 CASE WHEN CASE WHEN NOT ctx.gst_saved THEN false
                                WHEN NOT ctx.gst_registered THEN true
                                ELSE COALESCE(i.gst_treatment, 'taxable') = 'exempt_agri' END
                      THEN 0::numeric(5,2)
                      ELSE COALESCE(rt.src_tax, 0)::numeric(5,2) END AS tax_percent
      ) u
  ),
  customer_gst AS MATERIALIZED (
    SELECT x.customer_id, warehouse_security.gst_customer(x.customer_id)->>'gstin' IS NOT NULL AS registered
      FROM (SELECT DISTINCT gr.customer_id FROM grns gr) x
  ),
  kinds AS (
    -- The document kind of each part (left, in store) of each GRN, as form_documents decides it for a new invoice.
    SELECT p.gr_id, p.in_store,
           warehouse_security.gst_document_kind(ctx.gst_saved, ctx.gst_registered, cg.registered,
             (count(*) FILTER (WHERE p.treatment = 'exempt_agri'))::integer,
             (count(*) FILTER (WHERE p.treatment IS DISTINCT FROM 'exempt_agri'))::integer) AS kind
      FROM priced p
      JOIN grns gr ON gr.id = p.gr_id
      JOIN customer_gst cg ON cg.customer_id = gr.customer_id
     CROSS JOIN ctx
     GROUP BY p.gr_id, p.in_store, ctx.gst_saved, ctx.gst_registered, cg.registered
  ),
  docs AS (
    -- Each document's total: subtotal + tax, each rounded as an invoice is.
    SELECT d.gr_id, d.in_store,
           warehouse_security.round_invoice_total(d.subtotal + d.tax, ctx.rounding)::numeric(12,2) AS total
      FROM (SELECT p.gr_id, p.in_store,
                   sum(p.base)::numeric(12,2) AS subtotal,
                   warehouse_security.round_invoice_total(sum(p.base * p.tax_percent / 100.0), min(ctx.rounding))::numeric(12,2) AS tax
              FROM priced p
              JOIN kinds k ON k.gr_id = p.gr_id AND k.in_store = p.in_store
             CROSS JOIN ctx
             GROUP BY p.gr_id, p.in_store,
                      CASE WHEN k.kind = 'split' THEN CASE WHEN p.treatment = 'exempt_agri' THEN 'bill_of_supply' ELSE 'tax_invoice' END
                           ELSE k.kind END) d
     CROSS JOIN ctx
  ),
  parts AS (
    SELECT dc.gr_id, dc.in_store, COALESCE(sum(dc.total), 0)::numeric(14,2) AS amount FROM docs dc GROUP BY dc.gr_id, dc.in_store
  ),
  per_grn AS (
    SELECT p.gr_id,
           sum(p.qty) FILTER (WHERE NOT p.in_store) AS left_bags,
           sum(p.qty) FILTER (WHERE p.in_store) AS store_bags,
           -- Each lot: its line before the total's rounding, its base and its tax at the line's tax %, taken down to the paisa; no amount
           -- without a rate (grn_not_invoiced's lots).
           jsonb_agg(jsonb_build_object(
               'grn_item_id', p.lot_id::text, 'item_name', p.item_name::text, 'packaging', p.packaging::text, 'bags', p.qty,
               'has_rate', p.has_rate,
               'amount', CASE WHEN p.has_rate THEN (p.base + floor(p.base * p.tax_percent) / 100.0)::numeric(14,2) END)
             ORDER BY p.item_name::text, p.lot_id::text) FILTER (WHERE p.in_store) AS store_lots,
           array_agg(DISTINCT p.lot_id::text) FILTER (WHERE NOT p.has_rate) AS no_rate_lot_ids
      FROM priced p
     GROUP BY p.gr_id
  )
  SELECT gr.customer_id, gr.id, gr.gr_no, gr.date, gr.grn_date,
         pg.left_bags, pl.amount, pg.store_bags, ps.amount, pg.store_lots, COALESCE(pg.no_rate_lot_ids, '{}'::text[])
    FROM grns gr
    JOIN per_grn pg ON pg.gr_id = gr.id
    LEFT JOIN parts pl ON pl.gr_id = gr.id AND NOT pl.in_store
    LEFT JOIN parts ps ON ps.gr_id = gr.id AND ps.in_store
$$;
ALTER FUNCTION warehouse_security.not_invoiced_grns(uuid, date) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION warehouse_security.not_invoiced_grns(uuid, date) FROM PUBLIC;

-- Section 2: one customer's three figures, with the GRN rows when p_rows (the statement). Same answer as migration 176's.
CREATE OR REPLACE FUNCTION warehouse_security.customer_dues_figures(p_customer_id uuid, p_today date, p_rows boolean) RETURNS jsonb
    LANGUAGE plpgsql
    SET search_path TO 'pg_catalog', 'public', 'pg_temp'
    AS $$
DECLARE
  v_left numeric(14,2);
  v_store numeric(14,2);
  v_left_rows jsonb;
  v_store_rows jsonb;
  v_no_rate jsonb;
  v_invoices numeric(14,2);
BEGIN
  WITH n AS MATERIALIZED (SELECT * FROM warehouse_security.not_invoiced_grns(p_customer_id, p_today))
  SELECT COALESCE(sum(n.left_amount), 0), COALESCE(sum(n.store_amount), 0),
         COALESCE(jsonb_agg(jsonb_build_object('gr_id', n.gr_id, 'gr_no', n.gr_no, 'bags', n.left_bags, 'amount', n.left_amount)
                            ORDER BY n.gr_moment, n.gr_no, n.gr_id) FILTER (WHERE n.left_amount IS NOT NULL), '[]'::jsonb),
         COALESCE(jsonb_agg(jsonb_build_object('gr_id', n.gr_id, 'gr_no', n.gr_no, 'grn_date', n.grn_date,
                              'days_in_store', p_today - n.grn_date, 'bags', n.store_bags, 'amount', n.store_amount, 'lots', n.store_lots)
                            ORDER BY n.gr_moment, n.gr_no, n.gr_id) FILTER (WHERE n.store_amount IS NOT NULL), '[]'::jsonb),
         (SELECT COALESCE(jsonb_agg(DISTINCT to_jsonb(x)), '[]'::jsonb) FROM n n2 CROSS JOIN LATERAL unnest(n2.no_rate_lot_ids) x)
    INTO v_left, v_store, v_left_rows, v_store_rows, v_no_rate
    FROM n;

  IF warehouse_security.payments_enabled() THEN
    SELECT COALESCE(sum((warehouse_security.invoice_payment_state(i.id)->>'due_amount')::numeric), 0) INTO v_invoices
      FROM public.invoice i WHERE i.customer_id = p_customer_id AND i.deleted_at IS NULL AND i.cancelled_at IS NULL;
  ELSE
    SELECT COALESCE(sum(i.total), 0) INTO v_invoices
      FROM public.invoice i WHERE i.customer_id = p_customer_id AND i.deleted_at IS NULL AND i.cancelled_at IS NULL
       AND i.inv_fin_year = warehouse_security.financial_year(p_today);
  END IF;

  RETURN jsonb_build_object('invoices_amount', v_invoices, 'not_invoiced_left', v_left, 'not_invoiced_in_store', v_store,
    'no_rate_lot_ids', v_no_rate,
    'left_rows', CASE WHEN p_rows THEN v_left_rows END, 'in_store_rows', CASE WHEN p_rows THEN v_store_rows END);
END $$;
ALTER FUNCTION warehouse_security.customer_dues_figures(uuid, date, boolean) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION warehouse_security.customer_dues_figures(uuid, date, boolean) FROM PUBLIC;

-- Section 3: the dues list, every customer in one pass. Same answer as migration 176's.
CREATE OR REPLACE FUNCTION public.get_customer_dues() RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'extensions', 'utils', 'pg_temp'
    SET jit TO 'off'  -- as for not_invoiced_grns: JIT compilation would take longer than the read.
    AS $$
DECLARE
  v_today date := warehouse_security.business_date(now());
  v_payments boolean := warehouse_security.payments_enabled();
  v_fin_year integer := warehouse_security.financial_year(warehouse_security.business_date(now()));
  v_rows jsonb;
  v_no_rate bigint;
BEGIN
  PERFORM warehouse_security.authorize_rpc('get_customer_dues', jsonb_build_object());
  IF warehouse_security.active_role() IS DISTINCT FROM 'admin' AND warehouse_security.active_role() IS DISTINCT FROM 'supervisor'
     AND auth.jwt()->>'role' IS DISTINCT FROM 'service_role' THEN
    RAISE EXCEPTION 'Administrator or supervisor required' USING ERRCODE = '42501';
  END IF;

  -- Every customer that may owe: a live invoice, stock in store, or a dispatch line on no live invoice; listed when a figure is above 0.
  WITH n AS MATERIALIZED (
    SELECT * FROM warehouse_security.not_invoiced_grns(NULL, v_today)
  ), goods AS (
    SELECT n.customer_id, COALESCE(sum(n.left_amount), 0)::numeric(14,2) AS left_amount,
           COALESCE(sum(n.store_amount), 0)::numeric(14,2) AS store_amount
      FROM n GROUP BY n.customer_id
  ), no_rate AS (
    SELECT n.customer_id, count(DISTINCT x) AS lots FROM n CROSS JOIN LATERAL unnest(n.no_rate_lot_ids) x GROUP BY n.customer_id
  ), paid AS (
    SELECT p.invoice_id, sum(p.amount) AS amount FROM public.payments p WHERE v_payments AND p.invoice_id IS NOT NULL GROUP BY p.invoice_id
  ), invoices AS (
    -- Payments on: due on every live invoice, invoice_payment_state's due_amount (the total less what is paid, never below 0) worked
    -- out for all invoices at once. Payments off: the live invoices of the current financial year.
    SELECT i.customer_id,
           COALESCE(sum(CASE WHEN v_payments THEN GREATEST(COALESCE(i.total, 0)::numeric(12,2) - COALESCE(pd.amount, 0)::numeric(14,2), 0)
                             WHEN i.inv_fin_year = v_fin_year THEN i.total END), 0)::numeric(14,2) AS amount
      FROM public.invoice i
      LEFT JOIN paid pd ON pd.invoice_id = i.id
     WHERE i.deleted_at IS NULL AND i.cancelled_at IS NULL
     GROUP BY i.customer_id
  ), figures AS (
    SELECT c.id, c.name, c.active, COALESCE(iv.amount, 0)::numeric(14,2) AS invoices_amount,
           COALESCE(g.left_amount, 0)::numeric(14,2) AS left_amount, COALESCE(g.store_amount, 0)::numeric(14,2) AS store_amount,
           COALESCE(nr.lots, 0) AS lots
      FROM public.customers c
      LEFT JOIN invoices iv ON iv.customer_id = c.id
      LEFT JOIN goods g ON g.customer_id = c.id
      LEFT JOIN no_rate nr ON nr.customer_id = c.id
     WHERE c.deleted_at IS NULL AND (iv.customer_id IS NOT NULL OR g.customer_id IS NOT NULL)
  )
  SELECT COALESCE(jsonb_agg(jsonb_build_object('customer_id', f.id, 'name', f.name, 'active', f.active,
           'invoices_amount', f.invoices_amount, 'not_invoiced_left', f.left_amount,
           'not_invoiced_in_store', f.store_amount, 'lots_without_rate', f.lots,
           -- Shown beside the three figures; it changes no order and is added to nothing.
           'unlinked_paid_amount', CASE WHEN v_payments THEN warehouse_security.unlinked_payments_total(f.id, NULL, NULL)::numeric(14,2) END))
           FILTER (WHERE f.invoices_amount > 0 OR f.left_amount > 0 OR f.store_amount > 0), '[]'::jsonb),
         (SELECT count(DISTINCT x) FROM n CROSS JOIN LATERAL unnest(n.no_rate_lot_ids) x)
    INTO v_rows, v_no_rate
    FROM figures f;

  RETURN jsonb_build_object('success', true, 'as_of', now(), 'today', v_today, 'record_payments', v_payments,
    'invoices_basis', CASE WHEN v_payments THEN 'due' ELSE 'invoiced' END,
    'totals', jsonb_build_object(
      'invoices_amount', (SELECT COALESCE(sum((r->>'invoices_amount')::numeric), 0)::numeric(14,2) FROM jsonb_array_elements(v_rows) r),
      'not_invoiced_left', (SELECT COALESCE(sum((r->>'not_invoiced_left')::numeric), 0)::numeric(14,2) FROM jsonb_array_elements(v_rows) r),
      'not_invoiced_in_store', (SELECT COALESCE(sum((r->>'not_invoiced_in_store')::numeric), 0)::numeric(14,2) FROM jsonb_array_elements(v_rows) r)),
    'lots_without_rate', v_no_rate,
    'customers', (SELECT COALESCE(jsonb_agg(r ORDER BY (r->>'invoices_amount')::numeric + (r->>'not_invoiced_left')::numeric DESC,
                                              (r->>'not_invoiced_in_store')::numeric DESC, lower(r->>'name'), r->>'name', r->>'customer_id'),
                                    '[]'::jsonb)
                    FROM jsonb_array_elements(v_rows) r));
END $$;

-- Section 4: grn_not_invoiced (migration 176) has no caller left.
DROP FUNCTION warehouse_security.grn_not_invoiced(uuid, date);

NOTIFY pgrst, 'reload schema';
