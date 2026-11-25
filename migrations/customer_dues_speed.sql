-- Customer dues speed (WH-311): "Customer dues" answers in about 3 s instead of 84 s on the five-year test set
-- (tests/seed/make-seed.mjs --years 5: 60,000 GRNs, 180,000 lots, 45,000 dispatches, 12,000 invoices, 200 customers), and one customer's
-- dues can be read alone (get_customer_dues_for). Every figure is the same, to the paisa, as migration 193's: only how they are worked out
-- changes. Nothing is stored; every read works every figure out again, as before.
--
-- Why it was slow (EXPLAIN ANALYZE of not_invoiced_grns on that set, 138 s with timing): the step that prices each line joined the
-- durations (3,652 GRN-day and dispatch-day pairs) with IS NOT DISTINCT FROM, which cannot be hashed, so every line (279,000: 180,000
-- lots in store and 99,000 dispatch lines on no invoice) was compared with every pair: 1,018,629,000 comparisons, spilled to disk. The
-- time grows with (GRN days with open goods) x (open lots + open dispatch lines), so with the square of a store's unbilled history.
-- Fixing that join leaves about 7.5 s, spent in:
--   * nested loops chosen from wrong row guesses (the planner expects 2 rows where 279,000 come): hash and merge joins only now;
--   * find_storage_price called 180,000 times (one per GRN, item and weight; about 3 s, and 37 s once the items have rates): the
--     same pick made for every GRN, item and weight at once now, and the GRN's own rate likewise;
--   * storage_amount, round_invoice_total and gst_document_kind, one-line SQL functions called up to 279,000 times each but never
--     inlined because each carried SET search_path (about 1.5 s): the setting is reset so the planner inlines them (below);
--   * each lot's detail for the statement, built and then dropped by the dues list (about 0.6 s): only when asked for now.
--
-- Section 1: storage_amount, round_invoice_total and gst_document_kind (migrations 164 and 173) lose their SET search_path, the one
-- thing that stopped the planner from inlining them; their bodies are unchanged. They stay executable by supabase_admin only, are not
-- SECURITY DEFINER, and use only pg_catalog functions and operators; an inlined call is parsed under its caller's fixed search_path,
-- and pg_catalog is always searched first.
ALTER FUNCTION warehouse_security.storage_amount(numeric, numeric, numeric, integer, integer, integer) RESET search_path;
ALTER FUNCTION warehouse_security.round_invoice_total(numeric, text) RESET search_path;
ALTER FUNCTION warehouse_security.gst_document_kind(boolean, boolean, boolean, integer, integer) RESET search_path;

-- Section 2: not_invoiced_grns (migration 193) takes p_lots (each in-store lot's detail, for the statement only), joins the durations by
-- a hashable key, joins without nested loops, and picks the GRN's own rate and the item's rate (as find_storage_price does) for every
-- GRN, item and weight at once instead of one lookup each.
DROP FUNCTION warehouse_security.not_invoiced_grns(uuid, date);
CREATE FUNCTION warehouse_security.not_invoiced_grns(p_customer_id uuid, p_today date, p_lots boolean)
    RETURNS TABLE(customer_id uuid, gr_id uuid, gr_no character varying, gr_moment timestamp with time zone, grn_date date,
                  left_bags numeric, left_amount numeric, store_bags numeric, store_amount numeric, store_lots jsonb, no_rate_lot_ids text[])
    LANGUAGE sql STABLE
    SET search_path TO 'pg_catalog', 'public', 'pg_temp'
    -- The planner's estimate for this query is far above its real cost (the duration function is costed as 1,000 rows a call), which
    -- would start JIT compilation that takes longer than the query itself.
    SET jit TO 'off'
    -- WH-311: the planner cannot see how many rows each step gives (it guessed 2 where 279,000 came on the five-year test set) and
    -- joined them in nested loops, whose time grows with the square of the open lines. Hash and merge joins only; the per-row lookups
    -- (the GRN's own rate, the item's rate, the duration) stay as they are.
    SET enable_nestloop TO 'off'
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
           g.pricing_mode = 'ONE_TIME' AS one_time,
           -- The price type find_storage_price works out from lower(pricing_mode).
           CASE WHEN lower(COALESCE(lower(g.pricing_mode), 'monthly')) IN ('one_time', 'one-time') THEN 'one_time' ELSE 'monthly' END
             AS item_price_type
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
  keys AS MATERIALIZED (
    SELECT DISTINCT r.gr_id, r.item_id, r.weight FROM raw r
  ),
  first_default AS MATERIALIZED (
    -- Migration 129: each item's first default rate day (earliest start day of its rates for every customer, all bands), per price type.
    SELECT f.item_id, f.price_type, min(f.effective_from) AS first_from
      FROM public.item_storage_prices f WHERE f.customer_id IS NULL GROUP BY f.item_id, f.price_type
  ),
  item_rates AS MATERIALIZED (
    -- WH-311: public.find_storage_price(item, customer, weight, GRN date, lower(pricing_mode)) for every GRN, item and weight at once
    -- (it was called once each: 180,000 calls on the five-year test set). The same rows and the same order, the first one kept:
    --   * the customer's own rates in force on the GRN date, and the item's default rates in force on it, or starting after it when
    --     they are the item's first default rates (migration 129); band containing the weight, price type as find_storage_price's;
    --   * ordered: the customer's own first, the narrowest band, the latest start day, then the row id.
    -- find_storage_price takes a default rate only when the customer has no own rate for the item, band and day; such an own rate
    -- always sorts first, so keeping the first row gives the same answer without that test. A change to find_storage_price must be
    -- made here too.
    SELECT DISTINCT ON (c.gr_id, c.item_id, c.weight) c.gr_id, c.item_id, c.weight, c.unit_price, c.labour_rate, c.tax_percent
      FROM (
        SELECT k.gr_id, k.item_id, k.weight, f.id, f.customer_id, f.weight_min, f.weight_max, f.effective_from,
               f.unit_price, f.labour_rate, f.tax_percent
          FROM keys k
          JOIN grns gr ON gr.id = k.gr_id
          JOIN public.item_storage_prices f ON f.item_id = k.item_id AND f.price_type = gr.item_price_type AND f.customer_id = gr.customer_id
         WHERE f.weight_min <= k.weight AND k.weight <= f.weight_max
           AND f.effective_from <= gr.grn_date AND (f.effective_to IS NULL OR gr.grn_date <= f.effective_to)
        UNION ALL
        SELECT k.gr_id, k.item_id, k.weight, f.id, f.customer_id, f.weight_min, f.weight_max, f.effective_from,
               f.unit_price, f.labour_rate, f.tax_percent
          FROM keys k
          JOIN grns gr ON gr.id = k.gr_id
          JOIN public.item_storage_prices f ON f.item_id = k.item_id AND f.price_type = gr.item_price_type AND f.customer_id IS NULL
          JOIN first_default fd ON fd.item_id = f.item_id AND fd.price_type = f.price_type
         WHERE f.weight_min <= k.weight AND k.weight <= f.weight_max
           AND ((f.effective_from <= gr.grn_date AND (f.effective_to IS NULL OR gr.grn_date <= f.effective_to))
                OR (gr.grn_date < f.effective_from AND f.effective_from = fd.first_from))
      ) c
     ORDER BY c.gr_id, c.item_id, c.weight, (c.customer_id IS NULL), (c.weight_max - c.weight_min), c.effective_from DESC, c.id
  ),
  grn_own AS MATERIALIZED (
    -- The GRN's own rate for each item and weight, as build_invoice_form_lines picks it (the narrowest band, then the lowest; a GRN's
    -- bands of an item are unique, so the pick is the same), for every GRN at once instead of one lookup per GRN, item and weight.
    SELECT DISTINCT ON (k.gr_id, k.item_id, k.weight) k.gr_id, k.item_id, k.weight, g2.id, g2.unit_price, g2.labour_rate, g2.tax_percent
      FROM keys k
      JOIN grns gr ON gr.id = k.gr_id
      JOIN public.grn_rates g2 ON g2.gr_id = k.gr_id AND g2.item_id = k.item_id AND g2.price_type = gr.price_type
     WHERE COALESCE(k.weight, 0) BETWEEN g2.weight_min AND g2.weight_max
     ORDER BY k.gr_id, k.item_id, k.weight, (g2.weight_max - g2.weight_min), g2.weight_min
  ),
  rates AS MATERIALIZED (
    -- One rate per GRN, item and weight: the GRN's own rate, else the item's (build_invoice_form_lines' rates).
    SELECT p.gr_id, p.item_id, p.weight,
           CASE WHEN o.id IS NOT NULL THEN o.unit_price ELSE fp.unit_price END AS src_unit,
           CASE WHEN o.id IS NOT NULL THEN o.labour_rate ELSE fp.labour_rate END AS src_labour,
           CASE WHEN o.id IS NOT NULL THEN o.tax_percent ELSE fp.tax_percent END AS src_tax
      FROM keys p
      JOIN grns gr ON gr.id = p.gr_id
      LEFT JOIN grn_own o ON o.gr_id = p.gr_id AND o.item_id = p.item_id
                         AND COALESCE(o.weight, -1) = COALESCE(p.weight, -1) AND o.weight IS NOT DISTINCT FROM p.weight
      -- No weight or no GRN date: find_storage_price finds no rate, and no item_rates row matches.
      LEFT JOIN item_rates fp ON fp.gr_id = p.gr_id AND fp.item_id = p.item_id AND fp.weight = p.weight
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
      -- WH-311: the COALESCE pair is a key a hash join can use (IS NOT DISTINCT FROM alone cannot be hashed, and this join compared
      -- 3,652 durations with 279,000 lines one by one); the IS NOT DISTINCT FROM pair keeps the match exact.
      JOIN dur ON COALESCE(dur.grn_date, '-infinity'::date) = COALESCE(gr.grn_date, '-infinity'::date)
              AND COALESCE(dur.day, '-infinity'::date) = COALESCE(r.day, '-infinity'::date)
              AND dur.grn_date IS NOT DISTINCT FROM gr.grn_date AND dur.day IS NOT DISTINCT FROM r.day
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
           -- without a rate (grn_not_invoiced's lots). Only when p_lots: the dues list does not show them (WH-311).
           jsonb_agg(jsonb_build_object(
               'grn_item_id', p.lot_id::text, 'item_name', p.item_name::text, 'packaging', p.packaging::text, 'bags', p.qty,
               'has_rate', p.has_rate,
               'amount', CASE WHEN p.has_rate THEN (p.base + floor(p.base * p.tax_percent) / 100.0)::numeric(14,2) END)
             ORDER BY p.item_name::text, p.lot_id::text) FILTER (WHERE p.in_store AND p_lots) AS store_lots,
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
ALTER FUNCTION warehouse_security.not_invoiced_grns(uuid, date, boolean) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION warehouse_security.not_invoiced_grns(uuid, date, boolean) FROM PUBLIC;

-- Section 3: the statement's figures (migration 193) ask for the lots' detail only with the rows. Otherwise unchanged.
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
  WITH n AS MATERIALIZED (SELECT * FROM warehouse_security.not_invoiced_grns(p_customer_id, p_today, p_rows))
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

-- Section 4: one row of "Customer dues" per customer, for every customer (p_customer_id NULL) or one. get_customer_dues and
-- get_customer_dues_for both read it, so the list and one customer's answer are worked out by the same query and always agree.
-- The rows are migration 193's: every live customer with a live invoice, stock in store or a dispatch line on no live invoice (and the
-- asked-for customer even with none, all figures 0); listed is what the list shows (a figure above 0). Not a reader by itself: the RPCs
-- authorize first.
CREATE FUNCTION warehouse_security.customer_dues_rows(p_customer_id uuid, p_today date, p_payments boolean, p_fin_year integer)
    RETURNS TABLE(customer_id uuid, listed boolean, lots bigint, figures jsonb)
    LANGUAGE sql STABLE
    SET search_path TO 'pg_catalog', 'public', 'pg_temp'
    SET jit TO 'off'  -- as for not_invoiced_grns: JIT compilation would take longer than the read.
    AS $$
  WITH n AS MATERIALIZED (
    SELECT * FROM warehouse_security.not_invoiced_grns(p_customer_id, p_today, false)
  ), goods AS (
    SELECT n.customer_id, COALESCE(sum(n.left_amount), 0)::numeric(14,2) AS left_amount,
           COALESCE(sum(n.store_amount), 0)::numeric(14,2) AS store_amount
      FROM n GROUP BY n.customer_id
  ), no_rate AS (
    SELECT n.customer_id, count(DISTINCT x) AS lots FROM n CROSS JOIN LATERAL unnest(n.no_rate_lot_ids) x GROUP BY n.customer_id
  ), paid AS (
    SELECT p.invoice_id, sum(p.amount) AS amount FROM public.payments p WHERE p_payments AND p.invoice_id IS NOT NULL GROUP BY p.invoice_id
  ), invoices AS (
    -- Payments on: due on every live invoice, invoice_payment_state's due_amount (the total less what is paid, never below 0) worked
    -- out for all invoices at once. Payments off: the live invoices of the current financial year.
    SELECT i.customer_id,
           COALESCE(sum(CASE WHEN p_payments THEN GREATEST(COALESCE(i.total, 0)::numeric(12,2) - COALESCE(pd.amount, 0)::numeric(14,2), 0)
                             WHEN i.inv_fin_year = p_fin_year THEN i.total END), 0)::numeric(14,2) AS amount
      FROM public.invoice i
      LEFT JOIN paid pd ON pd.invoice_id = i.id
     WHERE i.deleted_at IS NULL AND i.cancelled_at IS NULL
       AND (p_customer_id IS NULL OR i.customer_id = p_customer_id)
     GROUP BY i.customer_id
  ), figures AS (
    SELECT c.id, c.name, c.active, COALESCE(iv.amount, 0)::numeric(14,2) AS invoices_amount,
           COALESCE(g.left_amount, 0)::numeric(14,2) AS left_amount, COALESCE(g.store_amount, 0)::numeric(14,2) AS store_amount,
           COALESCE(nr.lots, 0) AS lots
      FROM public.customers c
      LEFT JOIN invoices iv ON iv.customer_id = c.id
      LEFT JOIN goods g ON g.customer_id = c.id
      LEFT JOIN no_rate nr ON nr.customer_id = c.id
     WHERE c.deleted_at IS NULL
       AND (p_customer_id IS NULL OR c.id = p_customer_id)
       AND (iv.customer_id IS NOT NULL OR g.customer_id IS NOT NULL OR c.id = p_customer_id)
  )
  SELECT f.id, f.invoices_amount > 0 OR f.left_amount > 0 OR f.store_amount > 0, f.lots,
         jsonb_build_object('customer_id', f.id, 'name', f.name, 'active', f.active,
           'invoices_amount', f.invoices_amount, 'not_invoiced_left', f.left_amount,
           'not_invoiced_in_store', f.store_amount, 'lots_without_rate', f.lots,
           -- Shown beside the three figures; it changes no order and is added to nothing.
           'unlinked_paid_amount', CASE WHEN p_payments THEN warehouse_security.unlinked_payments_total(f.id, NULL, NULL)::numeric(14,2) END)
    FROM figures f
$$;
ALTER FUNCTION warehouse_security.customer_dues_rows(uuid, date, boolean, integer) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION warehouse_security.customer_dues_rows(uuid, date, boolean, integer) FROM PUBLIC;

-- Section 5: the dues list (migration 193), from customer_dues_rows. Same answer.
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

  -- Listed when a figure is above 0. The lots without a rate are counted over every customer row, listed or not, as before: a lot
  -- belongs to one GRN of one customer, so the sum of the customers' counts is the count of distinct lots.
  SELECT COALESCE(jsonb_agg(r.figures) FILTER (WHERE r.listed), '[]'::jsonb), COALESCE(sum(r.lots), 0)::bigint
    INTO v_rows, v_no_rate
    FROM warehouse_security.customer_dues_rows(NULL, v_today, v_payments, v_fin_year) r;

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

-- Section 6: one customer's dues (WH-311, for refreshing one customer on the phone): the same row as that customer's entry in
-- get_customer_dues, worked out by the same query, with listed (whether the list shows it: a figure above 0). A customer with
-- nothing owed gets the row with 0s. Administrators and supervisors only, as the list.
CREATE FUNCTION public.get_customer_dues_for(p_customer_id uuid) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'extensions', 'utils', 'pg_temp'
    SET jit TO 'off'
    AS $$
DECLARE
  v_today date := warehouse_security.business_date(now());
  v_payments boolean := warehouse_security.payments_enabled();
  v_fin_year integer := warehouse_security.financial_year(warehouse_security.business_date(now()));
  v_row record;
BEGIN
  PERFORM warehouse_security.authorize_rpc('get_customer_dues_for', jsonb_build_object('p_customer_id', p_customer_id));
  IF warehouse_security.active_role() IS DISTINCT FROM 'admin' AND warehouse_security.active_role() IS DISTINCT FROM 'supervisor'
     AND auth.jwt()->>'role' IS DISTINCT FROM 'service_role' THEN
    RAISE EXCEPTION 'Administrator or supervisor required' USING ERRCODE = '42501';
  END IF;

  SELECT r.listed, r.figures INTO v_row
    FROM warehouse_security.customer_dues_rows(p_customer_id, v_today, v_payments, v_fin_year) r;
  IF p_customer_id IS NULL OR NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'Customer not found');
  END IF;

  RETURN jsonb_build_object('success', true, 'as_of', now(), 'today', v_today, 'record_payments', v_payments,
    'invoices_basis', CASE WHEN v_payments THEN 'due' ELSE 'invoiced' END,
    'listed', v_row.listed, 'customer', v_row.figures);
END $$;
ALTER FUNCTION public.get_customer_dues_for(uuid) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION public.get_customer_dues_for(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.get_customer_dues_for(uuid) TO authenticated, service_role;

NOTIFY pgrst, 'reload schema';
