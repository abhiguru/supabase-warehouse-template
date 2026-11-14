-- Migration 204 (WH-158): the accountant pack's read, and the record of packs made.
--
-- The generate-accountant-pack function builds one zip for a period (README, sales register, receipts register, GSTR-1 working, stock
-- statement, two Tally XML files) from ONE read, public.get_accountant_pack(p_from, p_to). The read answers every figure already split
-- and every amount as stored; the function only formats, sums totals rows in paise and writes files. Nothing is worked out again on the
-- phone or in the function.
--
--  * warehouse_security.accountant_packs: one row per pack made (period, made_at, the caller and the name). Insert-only: only
--    get_accountant_pack writes it; no app role reads it (service_role may read); a trigger refuses UPDATE, DELETE and TRUNCATE (the one
--    UPDATE let through is the foreign key's own ON DELETE SET NULL of made_by when a profile is removed).
--  * warehouse_security.accountant_split(amount, weights): an amount shared over weights to the paisa, the leftover paise one each to the
--    largest fractions (ties: order); all weights 0 gives the whole amount to the first.
--  * warehouse_security.accountant_pack_documents(from, to): the documents dated in the period (India business days, deleted ones left
--    out), cancelled ones included with their kept lines, each with its rows: document x tax rate x kind (storage or labour) x exempt.
--    Per line: labour = round(labour_rate x quantity, 2) for monthly pricing, 0 for one-time (as invoice_gst_amounts, migration 173);
--    storage = taxable_value - labour. An imported line: storage = issued_storage_amount, labour = taxable_value - storage (migration
--    189). A document made before GST details (doc_type 'invoice', not imported): storage as get_invoice_detail reads it, labour as
--    above, rate = the line's tax %. The stored header tax (CGST, SGST, IGST; tax_amount for 'invoice') is shared over the rows in
--    proportion to taxable x rate (accountant_split). Round-off = total - (taxable + exempt + tax - discount).
--  * warehouse_security.accountant_pack_cancellations(from, to, now): the cancellations a pack carries (contract D6): a cancelled app
--    document (not imported) (a) dated in the period: in_period; (b) dated before From and cancelled in the period: cancelled_in_period;
--    (c) dated before From, when a recorded pack covering its date was made before the cancel and no pack of a period between its date and
--    From was made after the cancel: exported. "Before" and "after" allow 10 minutes in the direction that carries more. No grant.
--  * public.get_accountant_pack(p_from, p_to): administrators and supervisors (authorize_rpc's line for it, and the body), refusals
--    INVALID_PERIOD, PERIOD_ACROSS_YEARS, NOTHING_IN_PERIOD in that order; after them one accountant_packs row with the read's made_at.
--
-- No role is created, altered or dropped. No change to an existing table, column or function; no pg_temp helper.

CREATE TABLE warehouse_security.accountant_packs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  period_from date,
  period_to date,
  made_at timestamptz NOT NULL,
  made_by uuid REFERENCES public.user_profiles(id) ON DELETE SET NULL,
  made_by_name text
);
ALTER TABLE warehouse_security.accountant_packs OWNER TO supabase_admin;
CREATE INDEX accountant_packs_period_idx ON warehouse_security.accountant_packs (period_from, period_to);
CREATE INDEX accountant_packs_made_at_idx ON warehouse_security.accountant_packs (made_at);
CREATE INDEX accountant_packs_made_by_idx ON warehouse_security.accountant_packs (made_by) WHERE made_by IS NOT NULL;
ALTER TABLE warehouse_security.accountant_packs ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE warehouse_security.accountant_packs FROM PUBLIC, anon, authenticated, service_role;
GRANT SELECT ON TABLE warehouse_security.accountant_packs TO service_role;

CREATE FUNCTION warehouse_security.accountant_packs_guard() RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'pg_catalog'
AS $function$
BEGIN
  -- The foreign key's ON DELETE SET NULL when a profile is removed: only made_by changes, to NULL.
  IF TG_OP = 'UPDATE' AND NEW.made_by IS NULL AND OLD.made_by IS NOT NULL
     AND ROW(NEW.id, NEW.period_from, NEW.period_to, NEW.made_at, NEW.made_by_name)
         IS NOT DISTINCT FROM ROW(OLD.id, OLD.period_from, OLD.period_to, OLD.made_at, OLD.made_by_name) THEN
    RETURN NEW;
  END IF;
  RAISE EXCEPTION 'accountant_packs keeps the record of packs made: % is refused', TG_OP USING ERRCODE = 'insufficient_privilege';
END $function$;
ALTER FUNCTION warehouse_security.accountant_packs_guard() OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION warehouse_security.accountant_packs_guard() FROM PUBLIC, anon, authenticated, service_role;
CREATE TRIGGER accountant_packs_keep BEFORE UPDATE OR DELETE ON warehouse_security.accountant_packs
  FOR EACH ROW EXECUTE FUNCTION warehouse_security.accountant_packs_guard();
CREATE TRIGGER accountant_packs_no_truncate BEFORE TRUNCATE ON warehouse_security.accountant_packs
  FOR EACH STATEMENT EXECUTE FUNCTION warehouse_security.accountant_packs_guard();

-- An amount shared over weights to the paisa; the parts add back to the amount exactly.
CREATE FUNCTION warehouse_security.accountant_split(p_amount numeric, p_weights numeric[]) RETURNS numeric[]
    LANGUAGE sql IMMUTABLE
    SET search_path TO 'pg_catalog'
    AS $$
  WITH w AS (SELECT u.ord, COALESCE(u.x, 0) AS x FROM unnest(p_weights) WITH ORDINALITY u(x, ord)),
  t AS (SELECT round(COALESCE(p_amount, 0) * 100) AS paise, sum(w.x) AS total FROM w),
  f AS (SELECT w.ord,
               CASE WHEN t.total = 0 THEN CASE WHEN w.ord = 1 THEN t.paise ELSE 0 END
                    ELSE t.paise * w.x / t.total END AS exact
          FROM w CROSS JOIN t),
  g AS (SELECT f.ord, floor(f.exact) AS whole, f.exact - floor(f.exact) AS fraction FROM f),
  h AS (SELECT g.ord, g.whole,
               row_number() OVER (ORDER BY g.fraction DESC, g.ord) AS rank_no,
               (SELECT t.paise FROM t) - sum(g.whole) OVER () AS leftover
          FROM g)
  SELECT array_agg(((h.whole + CASE WHEN h.rank_no <= h.leftover THEN 1 ELSE 0 END) / 100.0)::numeric(12,2) ORDER BY h.ord) FROM h
$$;
ALTER FUNCTION warehouse_security.accountant_split(numeric, numeric[]) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION warehouse_security.accountant_split(numeric, numeric[]) FROM PUBLIC, anon, authenticated, service_role;

-- A stored state code as the pack writes it: "Gujarat (24)"; a value that is not a known code is passed on; empty is null.
CREATE FUNCTION warehouse_security.accountant_state(p_code text) RETURNS text
    LANGUAGE sql IMMUTABLE
    SET search_path TO 'pg_catalog'
    AS $$
  SELECT CASE WHEN NULLIF(btrim(p_code), '') IS NULL THEN NULL
              WHEN warehouse_security.gst_state_name(btrim(p_code)) IS NOT NULL
                THEN warehouse_security.gst_state_name(btrim(p_code)) || ' (' || btrim(p_code) || ')'
              ELSE btrim(p_code) END
$$;
ALTER FUNCTION warehouse_security.accountant_state(text) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION warehouse_security.accountant_state(text) FROM PUBLIC, anon, authenticated, service_role;

CREATE FUNCTION warehouse_security.accountant_pack_documents(p_from date, p_to date) RETURNS jsonb
    LANGUAGE sql STABLE
    SET search_path TO 'pg_catalog', 'public'
    AS $$
  WITH d AS (
    SELECT i.id, i.doc_type, i.inv_prefix, i.inv_no, warehouse_security.business_date(i.inv_date) AS doc_date, i.customer_id,
           COALESCE(c.name, i.customer_name) AS customer_name, i.gr_no, i.linked_invoice_id, i.cancelled_at,
           i.import_batch_id IS NOT NULL AS imported, (i.doc_type = 'invoice' AND i.import_batch_id IS NULL) AS before_gst,
           i.gst_customer_gstin, i.gst_customer_state, i.gst_place_of_supply, i.gst_sac_storage, i.gst_sac_labour, i.gst_tax_head,
           i.cgst_amount, i.sgst_amount, i.igst_amount, i.tax_amount,
           COALESCE(i.discount, 0)::numeric(12,2) AS discount, COALESCE(i.total, 0)::numeric(12,2) AS total,
           i.pricing_mode, (SELECT g.pricing_mode FROM public.goodsreceived g WHERE g.id = i.gr_id) AS grn_mode
      FROM public.invoice i
      LEFT JOIN public.customers c ON c.id = i.customer_id
     WHERE i.deleted_at IS NULL
       AND i.inv_date >= (p_from::timestamp AT TIME ZONE 'Asia/Kolkata')
       AND i.inv_date < ((p_to + 1)::timestamp AT TIME ZONE 'Asia/Kolkata')),
  -- Each line's storage and labour (contract D3).
  l AS (
    SELECT t.invoice_id, COALESCE(t.tax, 0)::numeric(12,2) AS rate, COALESCE(t.gst_treatment = 'exempt_agri', false) AS exempt,
           a.storage, a.labour
      FROM d
      JOIN public.invoice_trl t ON t.invoice_id = d.id
      LEFT JOIN public.dispatch_trl dt ON dt.id = t.disp_trl_id
      CROSS JOIN LATERAL (SELECT CASE WHEN t.details_kept_at IS NOT NULL THEN t.kept_disp_qty ELSE dt.disp_qty END AS qty,
                                 COALESCE(t.kept_pricing_mode, d.grn_mode, d.pricing_mode) AS mode) q
      CROSS JOIN LATERAL (SELECT CASE WHEN q.mode = 'ONE_TIME' THEN 0::numeric
                                      ELSE round(COALESCE(t.labour_rate, 0) * COALESCE(q.qty, 0), 2) END AS labour) k
      CROSS JOIN LATERAL (SELECT
          CASE WHEN t.issued_storage_amount IS NOT NULL THEN t.issued_storage_amount
               WHEN d.before_gst THEN
                 CASE WHEN q.qty IS NULL THEN 0
                      WHEN q.mode = 'ONE_TIME' THEN round(COALESCE(t.charge, 0) * q.qty, 2)
                      ELSE warehouse_security.invoice_storage_amount(d.id, COALESCE(t.charge, 0), q.qty, COALESCE(t.duration, 1), t.no_of_days) END
               ELSE COALESCE(t.taxable_value, 0) - k.labour END AS storage,
          CASE WHEN t.issued_storage_amount IS NOT NULL THEN COALESCE(t.taxable_value, 0) - t.issued_storage_amount
               ELSE k.labour END AS labour) a),
  g AS (
    SELECT x.invoice_id, x.exempt, x.rate, x.kind, sum(x.v)::numeric(12,2) AS v
      FROM (SELECT l.invoice_id, l.exempt, l.rate, 'storage' AS kind, l.storage AS v FROM l
            UNION ALL
            SELECT l.invoice_id, l.exempt, l.rate, 'labour', l.labour FROM l) x
     GROUP BY x.invoice_id, x.exempt, x.rate, x.kind),
  o AS (
    SELECT g.*, row_number() OVER (PARTITION BY g.invoice_id ORDER BY g.rate, CASE g.kind WHEN 'storage' THEN 0 ELSE 1 END, g.exempt) AS rn
      FROM g),
  -- Rows with no value are not shared any tax (the first row stays, so a document whose rows are all 0 keeps its header tax).
  s AS (
    SELECT o.invoice_id,
           array_agg(o.exempt ORDER BY o.rn) AS exempts, array_agg(o.rate ORDER BY o.rn) AS rates, array_agg(o.kind ORDER BY o.rn) AS kinds,
           array_agg(o.v ORDER BY o.rn) AS vals,
           array_agg(CASE WHEN o.exempt THEN 0 ELSE o.v * o.rate END ORDER BY o.rn) AS weights
      FROM o
     WHERE o.v <> 0 OR o.rn = 1
     GROUP BY o.invoice_id),
  sp AS (
    SELECT s.*, d.doc_type,
           warehouse_security.accountant_split(d.cgst_amount, s.weights) AS cgst,
           warehouse_security.accountant_split(d.sgst_amount, s.weights) AS sgst,
           warehouse_security.accountant_split(d.igst_amount, s.weights) AS igst,
           warehouse_security.accountant_split(d.tax_amount, s.weights) AS tax
      FROM s JOIN d ON d.id = s.invoice_id),
  r AS (
    SELECT sp.invoice_id, n,
           sp.kinds[n] AS kind, sp.exempts[n] AS exempt, sp.rates[n] AS rate, sp.vals[n] AS v,
           CASE WHEN sp.doc_type = 'invoice' THEN NULL ELSE sp.cgst[n] END AS cgst,
           CASE WHEN sp.doc_type = 'invoice' THEN NULL ELSE sp.sgst[n] END AS sgst,
           CASE WHEN sp.doc_type = 'invoice' THEN NULL ELSE sp.igst[n] END AS igst,
           CASE WHEN sp.doc_type = 'invoice' THEN sp.tax[n] ELSE (sp.cgst[n] + sp.sgst[n] + sp.igst[n])::numeric(12,2) END AS tax
      FROM sp CROSS JOIN LATERAL generate_subscripts(sp.vals, 1) n),
  rj AS (
    SELECT r.invoice_id, sum(r.v) AS v_sum, sum(r.tax) AS tax_sum,
           jsonb_agg(jsonb_build_object(
             'kind', r.kind, 'exempt', r.exempt, 'rate', r.rate,
             'taxable_value', CASE WHEN r.exempt THEN 0.00 ELSE r.v END,
             'exempt_value', CASE WHEN r.exempt THEN r.v ELSE 0.00 END,
             'cgst', r.cgst, 'sgst', r.sgst, 'igst', r.igst, 'tax', r.tax) ORDER BY r.n)
             FILTER (WHERE r.v <> 0 OR r.tax <> 0) AS rows
      FROM r GROUP BY r.invoice_id)
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'id', d.id, 'doc_type', d.doc_type,
           'number', warehouse_security.invoice_label(d.inv_prefix, d.inv_no),
           'date', to_char(d.doc_date, 'YYYY-MM-DD'),
           'customer_id', d.customer_id, 'customer_name', d.customer_name,
           'customer_gstin', NULLIF(btrim(d.gst_customer_gstin), ''),
           'customer_state', warehouse_security.accountant_state(d.gst_customer_state),
           'place_of_supply', warehouse_security.accountant_state(d.gst_place_of_supply),
           'sac_storage', d.gst_sac_storage, 'sac_labour', d.gst_sac_labour, 'tax_head', d.gst_tax_head,
           'gr_no', d.gr_no,
           'linked_number', (SELECT warehouse_security.invoice_label(li.inv_prefix, li.inv_no) FROM public.invoice li WHERE li.id = d.linked_invoice_id),
           'status', CASE WHEN d.cancelled_at IS NULL THEN 'live' ELSE 'cancelled' END,
           'cancelled_on', to_char(warehouse_security.business_date(d.cancelled_at), 'YYYY-MM-DD'),
           'imported', d.imported, 'before_gst', d.before_gst,
           'discount', d.discount,
           'round_off', (d.total - (COALESCE(rj.v_sum, 0) + COALESCE(rj.tax_sum, 0) - d.discount))::numeric(12,2),
           'total', d.total,
           'rows', COALESCE(rj.rows, '[]'::jsonb))
         ORDER BY d.doc_date, d.inv_prefix, d.inv_no), '[]'::jsonb)
    FROM d LEFT JOIN rj ON rj.invoice_id = d.id
$$;
ALTER FUNCTION warehouse_security.accountant_pack_documents(date, date) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION warehouse_security.accountant_pack_documents(date, date) FROM PUBLIC, anon, authenticated, service_role;

-- The cancellations a pack of p_from..p_to carries, as of p_now (contract D6; Q11). The read calls it with now().
CREATE FUNCTION warehouse_security.accountant_pack_cancellations(p_from date, p_to date, p_now timestamptz) RETURNS jsonb
    LANGUAGE sql STABLE
    SET search_path TO 'pg_catalog', 'public'
    AS $$
  WITH k AS (SELECT interval '10 minutes' AS slack),
  c AS (
    SELECT i.id, i.doc_type, i.inv_prefix, i.inv_no, warehouse_security.business_date(i.inv_date) AS doc_date,
           i.cancelled_at, warehouse_security.business_date(i.cancelled_at) AS cancelled_on,
           i.customer_id, COALESCE(cu.name, i.customer_name) AS customer_name
      FROM public.invoice i
      LEFT JOIN public.customers cu ON cu.id = i.customer_id
     WHERE i.cancelled_at IS NOT NULL AND i.cancelled_at <= p_now
       AND i.deleted_at IS NULL AND i.import_batch_id IS NULL
       AND i.inv_date < ((p_to + 1)::timestamp AT TIME ZONE 'Asia/Kolkata')),
  r AS (
    SELECT c.*,
           CASE WHEN c.doc_date BETWEEN p_from AND p_to THEN 'in_period'
                WHEN c.doc_date < p_from AND c.cancelled_on BETWEEN p_from AND p_to THEN 'cancelled_in_period'
                WHEN c.doc_date < p_from
                 -- A recorded pack covering its date, made before the cancel (10 minutes' slack: a pack made while the cancel was
                 -- committing still counts as before it).
                 AND EXISTS (SELECT 1 FROM warehouse_security.accountant_packs a, k
                              WHERE a.period_from <= c.doc_date AND a.period_to >= c.doc_date
                                AND a.made_at < c.cancelled_at + k.slack AND a.made_at <= p_now)
                 -- No pack of a period between its date and From made after the cancel (with the same slack): that pack carried it.
                 AND NOT EXISTS (SELECT 1 FROM warehouse_security.accountant_packs b, k
                                  WHERE b.period_from > c.doc_date AND b.period_to < p_from
                                    AND b.made_at > c.cancelled_at + k.slack AND b.made_at <= p_now)
                THEN 'exported' END AS reason
      FROM c)
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'id', r.id, 'doc_type', r.doc_type, 'number', warehouse_security.invoice_label(r.inv_prefix, r.inv_no),
           'date', to_char(r.doc_date, 'YYYY-MM-DD'), 'cancelled_on', to_char(r.cancelled_on, 'YYYY-MM-DD'),
           'customer_id', r.customer_id, 'customer_name', r.customer_name, 'reason', r.reason)
         ORDER BY r.doc_date, r.inv_prefix, r.inv_no), '[]'::jsonb)
    FROM r WHERE r.reason IS NOT NULL
$$;
ALTER FUNCTION warehouse_security.accountant_pack_cancellations(date, date, timestamptz) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION warehouse_security.accountant_pack_cancellations(date, date, timestamptz) FROM PUBLIC, anon, authenticated, service_role;

CREATE FUNCTION public.get_accountant_pack(p_from date, p_to date) RETURNS jsonb
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'pg_temp'
    AS $$
DECLARE
  v_now timestamptz := now();
  v_today date := warehouse_security.business_date(now());
  v_start timestamptz;
  v_end timestamptz;
  v_profile uuid;
  v_name text;
  v_record boolean;
  v_gst jsonb;
  v_documents jsonb;
  v_cancellations jsonb;
  v_payments jsonb;
  v_stock jsonb;
  v_issued jsonb;
  v_missing jsonb;
  v_changed jsonb;
  v_customers jsonb;
  v_renamed jsonb;
  v_customer_ids uuid[];
BEGIN
  PERFORM warehouse_security.authorize_rpc('get_accountant_pack', jsonb_build_object('p_from', p_from, 'p_to', p_to));
  -- Like get_gst_details: the body does not depend on the definition file having been applied yet.
  IF COALESCE(warehouse_security.active_role() NOT IN ('admin', 'supervisor'), true) AND auth.jwt()->>'role' IS DISTINCT FROM 'service_role' THEN
    RAISE EXCEPTION 'Administrator or supervisor required' USING ERRCODE = '42501';
  END IF;

  IF p_from IS NULL OR p_to IS NULL OR p_to < p_from OR p_to > v_today THEN
    RETURN warehouse_security.refuse('INVALID_PERIOD', 'Choose a period that ends today or earlier.');
  END IF;
  IF warehouse_security.financial_year(p_from) <> warehouse_security.financial_year(p_to) THEN
    RETURN warehouse_security.refuse('PERIOD_ACROSS_YEARS', 'Choose dates inside one financial year.');
  END IF;

  v_start := p_from::timestamp AT TIME ZONE 'Asia/Kolkata';
  v_end := (p_to + 1)::timestamp AT TIME ZONE 'Asia/Kolkata';
  v_record := COALESCE((SELECT r.record_payments FROM warehouse_security.charging_rule r WHERE r.id), false);

  v_documents := warehouse_security.accountant_pack_documents(p_from, p_to);
  v_cancellations := warehouse_security.accountant_pack_cancellations(p_from, p_to, v_now);

  -- Payments by their day: paid_on, else the India date of payment_date (older rows, as payment_json). Null when Record payments is off.
  IF v_record THEN
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
             'id', x.id, 'payment_no', x.payment_no, 'paid_on', to_char(x.day, 'YYYY-MM-DD'),
             'customer_id', x.customer_id, 'customer_name', x.customer_name,
             'invoice_id', x.invoice_id, 'invoice_number', x.invoice_number,
             'amount', x.amount, 'mode', x.payment_mode,
             -- payments.bank was dropped (migration 123); the column of the register stays, empty.
             'bank', NULL::text,
             'reference', COALESCE(NULLIF(btrim(x.cheque_no), ''), NULLIF(btrim(x.online_ref), '')),
             'note', x.note,
             'cash_large', x.payment_mode = 'cash' AND x.amount >= 200000.00,
             'imported', x.import_batch_id IS NOT NULL)
           ORDER BY x.day, x.payment_no, x.id), '[]'::jsonb)
      INTO v_payments
      FROM (SELECT p.id, p.payment_no, COALESCE(p.paid_on, warehouse_security.business_date(p.payment_date)) AS day,
                   COALESCE(i.customer_id, p.customer_id) AS customer_id,
                   COALESCE(ic.name, pc.name, p.customer_name) AS customer_name,
                   p.invoice_id, warehouse_security.invoice_label(i.inv_prefix, i.inv_no) AS invoice_number,
                   p.amount, p.payment_mode, p.cheque_no, p.online_ref, p.note, p.import_batch_id
              FROM public.payments p
              LEFT JOIN public.invoice i ON i.id = p.invoice_id
              LEFT JOIN public.customers ic ON ic.id = i.customer_id
              LEFT JOIN public.customers pc ON pc.id = p.customer_id
             WHERE COALESCE(p.paid_on, warehouse_security.business_date(p.payment_date)) BETWEEN p_from AND p_to
               -- The day is the paid_on, else the India date of payment_date; the range below only narrows the scan.
               AND (p.paid_on IS NOT NULL OR (p.payment_date >= v_start AND p.payment_date < v_end))) x;
  END IF;

  IF jsonb_array_length(v_documents) = 0 AND jsonb_array_length(v_cancellations) = 0
     AND (v_payments IS NULL OR jsonb_array_length(v_payments) = 0) THEN
    RETURN warehouse_security.refuse('NOTHING_IN_PERIOD', 'No invoices or receipts in this period.');
  END IF;

  -- Stock by GRN line: start (received before From, less dispatches before From), received and sent in the period, end.
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'customer_name', y.customer_name, 'gr_no', y.gr_no, 'grn_date', to_char(y.grn_day, 'YYYY-MM-DD'),
           'item_name', y.item_name, 'packaging', y.packaging, 'mark', y.package_mark, 'kg_per_bag', y.weight,
           'start_bags', y.start_bags, 'received_bags', y.received_bags, 'sent_bags', y.sent_bags,
           'end_bags', y.start_bags + y.received_bags - y.sent_bags, 'imported', y.imported)
         ORDER BY y.customer_name, y.grn_day, y.gr_no, y.item_name, y.id), '[]'::jsonb)
    INTO v_stock
    FROM (SELECT gt.id, COALESCE(c.name, g.customer_name) AS customer_name, g.gr_no, z.grn_day, gt.item_name, gt.packaging,
                 gt.package_mark, gt.weight, g.import_batch_id IS NOT NULL AS imported,
                 CASE WHEN z.grn_day < p_from THEN gt.qty - s.before_from ELSE 0 END AS start_bags,
                 CASE WHEN z.grn_day >= p_from THEN gt.qty ELSE 0 END AS received_bags,
                 s.in_period AS sent_bags
            FROM public.goodsreceived_trl gt
            JOIN public.goodsreceived g ON g.id = gt.gr_id
            LEFT JOIN public.customers c ON c.id = g.customer_id
            CROSS JOIN LATERAL (SELECT warehouse_security.business_date(g.date) AS grn_day) z
            CROSS JOIN LATERAL (
              SELECT COALESCE(sum(dt.disp_qty) FILTER (WHERE warehouse_security.business_date(d.disp_date) < p_from), 0)::integer AS before_from,
                     COALESCE(sum(dt.disp_qty) FILTER (WHERE warehouse_security.business_date(d.disp_date) BETWEEN p_from AND p_to), 0)::integer AS in_period
                FROM public.dispatch_trl dt
                JOIN public.dispatch d ON d.id = dt.disp_id
               WHERE dt.gr_trl_id = gt.id AND d.deleted_at IS NULL AND d.disp_date < v_end) s
           WHERE g.deleted_at IS NULL AND g.date < v_end) y
   WHERE y.start_bags <> 0 OR y.received_bags <> 0 OR y.sent_bags <> 0;

  -- Documents issued in the period, per type (cancelled and imported ones counted).
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'doc_type', q.doc_type, 'first_number', q.first_number, 'last_number', q.last_number,
           'count', q.n, 'cancelled', q.cancelled) ORDER BY q.doc_type), '[]'::jsonb)
    INTO v_issued
    FROM (SELECT e->>'doc_type' AS doc_type, count(*) AS n, count(*) FILTER (WHERE e->>'status' = 'cancelled') AS cancelled,
                 (array_agg(e->>'number' ORDER BY i.inv_prefix, i.inv_no))[1] AS first_number,
                 (array_agg(e->>'number' ORDER BY i.inv_prefix DESC, i.inv_no DESC))[1] AS last_number
            FROM jsonb_array_elements(v_documents) e
            JOIN public.invoice i ON i.id = (e->>'id')::uuid
           GROUP BY e->>'doc_type') q;

  -- Missing numbers: per year and prefix, each number between the period's lowest and highest that no invoice of that year holds.
  SELECT COALESCE(jsonb_agg(warehouse_security.invoice_label(m.inv_prefix, m.n) ORDER BY m.inv_fin_year, m.inv_prefix, m.n), '[]'::jsonb)
    INTO v_missing
    FROM (SELECT b.inv_fin_year, b.inv_prefix, gs.n
            FROM (SELECT i.inv_fin_year, i.inv_prefix, min(i.inv_no) AS lo, max(i.inv_no) AS hi
                    FROM jsonb_array_elements(v_documents) e
                    JOIN public.invoice i ON i.id = (e->>'id')::uuid
                   GROUP BY i.inv_fin_year, i.inv_prefix) b
            CROSS JOIN LATERAL generate_series(b.lo, b.hi) gs(n)
           WHERE NOT EXISTS (SELECT 1 FROM public.invoice h
                              WHERE h.inv_fin_year = b.inv_fin_year AND h.inv_no = gs.n AND h.deleted_at IS NULL)) m;

  -- Documents dated before From that were changed in the period (audit_log), other than those carried as cancellations.
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'number', warehouse_security.invoice_label(w.inv_prefix, w.inv_no), 'date', to_char(w.doc_date, 'YYYY-MM-DD'),
           'changed_on', to_char(w.changed_on, 'YYYY-MM-DD')) ORDER BY w.inv_prefix, w.inv_no), '[]'::jsonb)
    INTO v_changed
    FROM (SELECT i.inv_prefix, i.inv_no, warehouse_security.business_date(i.inv_date) AS doc_date,
                 max(warehouse_security.business_date(a.created_at)) AS changed_on
            FROM public.audit_log a
            JOIN public.invoice i ON i.id = CASE WHEN a.table_name = 'invoice'
                                                 THEN COALESCE(a.new_data->>'id', a.old_data->>'id')
                                                 ELSE COALESCE(a.new_data->>'invoice_id', a.old_data->>'invoice_id') END::uuid
           WHERE a.table_name IN ('invoice', 'invoice_trl') AND a.action IN ('UPDATE', 'INSERT', 'DELETE')
             AND a.created_at >= v_start AND a.created_at < v_end
             AND i.deleted_at IS NULL AND i.inv_date < v_start
             AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_cancellations) ce WHERE (ce->>'id')::uuid = i.id)
           GROUP BY i.id, i.inv_prefix, i.inv_no, i.inv_date) w;

  -- The customers named on a voucher: of the documents, the cancellations and the payments.
  SELECT array_agg(DISTINCT u.id) INTO v_customer_ids
    FROM (SELECT (e->>'customer_id')::uuid AS id FROM jsonb_array_elements(v_documents) e
          UNION SELECT (e->>'customer_id')::uuid FROM jsonb_array_elements(v_cancellations) e
          UNION SELECT (e->>'customer_id')::uuid FROM jsonb_array_elements(COALESCE(v_payments, '[]'::jsonb)) e) u
   WHERE u.id IS NOT NULL;
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'id', c.id, 'name', c.name, 'gstin', NULLIF(btrim(c.gst), ''),
           'state_name', warehouse_security.accountant_state(c.state_code)) ORDER BY c.name, c.id), '[]'::jsonb)
    INTO v_customers
    FROM public.customers c WHERE c.id = ANY (COALESCE(v_customer_ids, '{}'::uuid[]));

  -- Customers renamed from From to now, for the customers in the pack.
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'old_name', a.old_data->>'name', 'new_name', a.new_data->>'name',
           'changed_on', to_char(warehouse_security.business_date(a.created_at), 'YYYY-MM-DD')) ORDER BY a.created_at, a.id), '[]'::jsonb)
    INTO v_renamed
    FROM public.audit_log a
   WHERE a.table_name = 'customers' AND a.action = 'UPDATE'
     AND a.created_at >= v_start AND a.created_at <= v_now
     AND (a.old_data->>'name') IS DISTINCT FROM (a.new_data->>'name')
     AND (a.new_data->>'id')::uuid = ANY (COALESCE(v_customer_ids, '{}'::uuid[]));

  v_gst := warehouse_security.gst_settings();
  v_profile := public.get_current_user_profile_id();
  v_name := (SELECT p.name FROM public.user_profiles p WHERE p.id = v_profile);

  -- The record of this pack (contract D6a), in the same transaction and with the read's made_at.
  INSERT INTO warehouse_security.accountant_packs (period_from, period_to, made_at, made_by, made_by_name)
  VALUES (p_from, p_to, v_now, v_profile, v_name);

  RETURN jsonb_build_object('success', true, 'data', jsonb_build_object(
    'made_at', v_now,
    'made_by', v_name,
    'facility', jsonb_build_object(
      'name', COALESCE((SELECT btrim(s.value) FROM public.system_settings s WHERE s.key = 'app_name'), ''),
      'legal_name', v_gst->>'legal_name', 'gstin', v_gst->>'gstin',
      'state_code', v_gst->>'state_code', 'state_name', v_gst->>'state_name',
      'registered', (v_gst->>'registered')::boolean, 'gst_saved', (v_gst->>'saved')::boolean),
    'period', jsonb_build_object(
      'from_date', to_char(p_from, 'YYYY-MM-DD'), 'to_date', to_char(p_to, 'YYYY-MM-DD'),
      'fin_year', warehouse_security.financial_year(p_from),
      'whole_month', p_from = date_trunc('month', p_from)::date
                     AND p_to = (date_trunc('month', p_from) + interval '1 month' - interval '1 day')::date),
    'record_payments', v_record,
    'ledgers', warehouse_security.accountant_ledgers(),
    'documents', v_documents,
    'cancellations', v_cancellations,
    'changed_earlier', v_changed,
    'payments', v_payments,
    'stock', v_stock,
    'issued', v_issued,
    'missing_numbers', v_missing,
    'customers', v_customers,
    'renamed_customers', v_renamed));
END $$;
ALTER FUNCTION public.get_accountant_pack(date, date) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION public.get_accountant_pack(date, date) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.get_accountant_pack(date, date) TO authenticated, service_role;
