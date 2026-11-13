-- Migration 192 (WH-180, part 4 of the import of past years): public.import_history, the call behind `bash scripts/import.sh --folder`.
-- Written against the tables and functions as migrations 171 (import_batch), 172 (payments), 176 (dues), 189 (the Imported mark), 190 (the
-- read-only guard and its warehouse.import bypass) and 191 left them. Operator tool only: granted to service_role, refused for every app account.
--
--  1. Staging. Schema warehouse_import, seven UNLOGGED tables, one per file (grns.csv, grn-lines.csv, dispatches.csv, dispatch-lines.csv,
--     invoices.csv, invoice-lines.csv, payments.csv), typed columns plus `line` (the file line the row came from). Owner supabase_admin, no
--     grants, RLS on: scripts/import.mjs fills them with COPY as supabase_admin in the same transaction, before it switches to service_role, and
--     empties them before COMMIT. The script has already checked every format (dates, numbers, lengths, required cells, in-file repeats).
--  2. public.import_history(p_masters jsonb, p_apply boolean). One transaction (the caller's), all or nothing:
--     - the same gate as import_batch (migration 171): authorize_rpc, then the call must carry the service role; the same advisory lock;
--     - p_masters, when it holds customers, items or rates, goes through public.import_batch(p_masters, true) first, so customers and items
--       of this run are there for the checks below (its report is returned as `masters`; an error there is an error of the run);
--       p_masters.history_files = [{name, sha256, rows}] is recorded on the batch;
--     - the writes run as the "Import" actor of migration 171 with warehouse.import = 'on' (transaction-local): the guard of migration 190
--       lets the import write imported rows, and the per-row audit, invoiced sync and discount audit skip its inserts;
--     - set-based checks into a temporary problems table: errors and notes, each with the file, line and column;
--     - when there is no error: set-based INSERT ... SELECT in the order GRN, GRN lines, dispatch, dispatch lines, invoice, invoice lines,
--       payments, then one UPDATE of the GRN lines' stock (lines imported by an earlier run that gain dispatches now) and one of the GRNs'
--       out_of_stock and invoiced, the import's own records (import_batches, imported_documents, imported_grn_lines) and one audit_log row;
--     - the sign-off totals, read back from the tables inside the transaction, so they are what the app shows after an apply;
--     - a dry run (p_apply false), or any error, rolls everything back (masters included) and still returns the report.
--  3. Documents are written directly, not through the app's save functions: an imported document keeps its number, date and amounts as issued,
--     and the app's numbering, date-order and rate rules do not apply to it (WH-180 spec, steps 4, 10, 11). created_by is the Import actor,
--     import_batch_id the batch. A document is known by its key (imported_documents, migration 189): number|date for a GRN or dispatch,
--     fy|number for an invoice, customer id|receipt|date for a payment; its content hash is the md5 of its normalised header and sorted lines as
--     staged. A key imported before with the same hash is skipped ("already there"); with another hash it is an error. A document made in the
--     app is never touched.
--  4. Receipt numbers. payments_payment_no_key UNIQUE (payment_no) is replaced by a unique index over the rows that are not imported: an old
--     system may use a receipt number again in another year or for another customer; an imported payment is unique by its key above. App
--     payments are numbered APP-<n> from a sequence and stay unique, as do the rows of the old accounting link.
--  5. Dispatches taken as billed (WH-180 spec, answer 4, criterion 20). public.imported_billed_dispatches (disp_trl_id, invoice_id):
--     where a live imported invoice names no dispatch on some line (invoice_trl.disp_trl_id NULL) or has no lines at all (its GRN is the
--     GRN of its invoices.csv row, invoice.gr_id), each imported dispatch line of that invoice's GRN dated on or before the invoice
--     (business dates), on no live invoice line and not linked yet, is held as billed by it. Two such invoices: the earliest one dated on
--     or after the dispatch, then the invoice number. By date only, never by quantity. Worked out at the end of the writes of every run
--     over all imported invoices and dispatches (this run's and earlier ones); an existing link is never moved or removed, so a repeat run
--     adds nothing. A link counts only while its invoice is live. Every "dispatch line on no live invoice" read also requires no link to a
--     live invoice: the never-billed list and notes here, not_invoiced_grns (migration 193), and the invoice form, the save check and
--     grn_has_free_dispatch_line (migration 196). App-made dispatches are never linked. Only this function writes the table: RLS on, no
--     policy, no grant to any app role.
--
-- Errors (nothing is saved): an unknown customer or item; a line whose document is not in its header file; a GRN or dispatch with no lines;
-- a GRN or dispatch number that a document made in the app holds; an invoice number that an app invoice of that financial year holds,
-- or an invoice number that two invoices of the file share in one year, or above invoice_number_max(); an
-- invoice whose GRN is in neither grns.csv nor an earlier import, or whose GRN belongs to another customer; an invoice line whose dispatch
-- is not found or has no line of the invoice's GRN (an invoice covers one GRN); a dispatch line on two invoices; a dispatch line of another
-- customer's GRN, or of a GRN line that is not found; dispatches above what a GRN line received; "Stock now" that differs from received
-- less dispatched; a payment whose invoice is not found among the imported ones, or belongs to another customer; payments.csv while Record
-- payments is off; a date after today (India); a document that differs from what an earlier import saved under the same key.
-- Notes (saved as issued, listed): a dispatch dated before its GRN; an invoice dated before its last named dispatch; a payment dated before
-- its invoice; payments above what is left on an invoice; lines + tax - discount that differ from the invoice's Total; invoices.csv while
-- Record payments is off; and, once there is no error, an imported dispatch line on no invoice whose GRN has an imported invoice of the
-- same day or later where every such invoice names a dispatch on each of its lines (when this run adds the dispatch or such an invoice; a
-- dispatch of an earlier run that is not in dispatch-lines.csv is listed on the invoice's row; a dispatch taken as billed is not listed), a
-- lot with goods to bill and no rate, an invoiced GRN with dispatches on no invoice while Invoice as goods leave is off, and an invoice
-- line naming a dispatch line that an earlier run took as billed by another invoice (both invoices are kept as issued).
-- Report: {"success", "applied", "dry_run", "batch_id", "masters": import_batch's report or null,
--   "files": {name: {read, add, skip, errors, notes}}, "problems": the first 200 per file [{kind, file, line, column, reason}],
--   "problem_counts": {name: n}, "totals": the sign-off totals or null while there is an error}. totals.taken_as_billed:
--   [{customer, dispatches: [{disp_no, disp_date, invoice}]}], every link of the facility after this run, per customer.
--
-- No role is created, altered or dropped.

-- ===== 1. staging =====
CREATE SCHEMA warehouse_import;
ALTER SCHEMA warehouse_import OWNER TO supabase_admin;
REVOKE ALL ON SCHEMA warehouse_import FROM PUBLIC;

CREATE UNLOGGED TABLE warehouse_import.stage_grns (
  line integer NOT NULL, gr_no text NOT NULL, gr_date date NOT NULL, customer text NOT NULL, pricing text NOT NULL,
  vehicle text, sender text, note text);
CREATE UNLOGGED TABLE warehouse_import.stage_grn_lines (
  line integer NOT NULL, gr_no text NOT NULL, gr_date date NOT NULL, line_no integer NOT NULL, item text NOT NULL, packaging text NOT NULL,
  qty integer NOT NULL, weight integer, rack text, mark text, stock_now integer);
CREATE UNLOGGED TABLE warehouse_import.stage_dispatches (
  line integer NOT NULL, disp_no text NOT NULL, disp_date date NOT NULL, customer text NOT NULL, vehicle text, note text);
CREATE UNLOGGED TABLE warehouse_import.stage_dispatch_lines (
  line integer NOT NULL, disp_no text NOT NULL, disp_date date NOT NULL, gr_no text NOT NULL, gr_date date NOT NULL, grn_line integer NOT NULL,
  qty integer NOT NULL);
CREATE UNLOGGED TABLE warehouse_import.stage_invoices (
  line integer NOT NULL, inv_label text NOT NULL, inv_no integer NOT NULL, inv_prefix text NOT NULL, inv_date date NOT NULL,
  customer text NOT NULL, gr_no text NOT NULL, gr_date date NOT NULL, inv_name text, labour numeric(12,2) NOT NULL,
  tax numeric(12,2) NOT NULL, discount numeric(12,2), total numeric(12,2) NOT NULL, note text);
CREATE UNLOGGED TABLE warehouse_import.stage_invoice_lines (
  line integer NOT NULL, inv_label text NOT NULL, inv_no integer NOT NULL, inv_date date NOT NULL, item text NOT NULL, packaging text NOT NULL,
  qty integer NOT NULL, disp_no text, disp_date date, grn_line integer, months numeric(8,2), days integer, rate numeric(12,2) NOT NULL,
  labour_rate numeric(12,2), tax_pct numeric(5,2), storage numeric(12,2) NOT NULL, labour numeric(12,2), tax_amount numeric(12,2) NOT NULL);
CREATE UNLOGGED TABLE warehouse_import.stage_payments (
  line integer NOT NULL, receipt text NOT NULL, pay_date date NOT NULL, customer text NOT NULL, inv_label text, inv_no integer, inv_date date,
  amount numeric(12,2) NOT NULL, mode text, note text);

DO $own$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['stage_grns', 'stage_grn_lines', 'stage_dispatches', 'stage_dispatch_lines', 'stage_invoices', 'stage_invoice_lines',
                           'stage_payments'] LOOP
    EXECUTE format('ALTER TABLE warehouse_import.%I OWNER TO supabase_admin', t);
    EXECUTE format('ALTER TABLE warehouse_import.%I ENABLE ROW LEVEL SECURITY', t);
    EXECUTE format('REVOKE ALL ON TABLE warehouse_import.%I FROM PUBLIC, anon, authenticated, service_role', t);
  END LOOP;
END
$own$;

-- ===== 4. receipt numbers =====
ALTER TABLE public.payments DROP CONSTRAINT payments_payment_no_key;
CREATE UNIQUE INDEX payments_payment_no_app_key ON public.payments (payment_no) WHERE import_batch_id IS NULL;

-- ===== 5. dispatches taken as billed =====
CREATE TABLE public.imported_billed_dispatches (
  disp_trl_id uuid PRIMARY KEY REFERENCES public.dispatch_trl(id),
  invoice_id  uuid NOT NULL REFERENCES public.invoice(id)
);
ALTER TABLE public.imported_billed_dispatches OWNER TO supabase_admin;
ALTER TABLE public.imported_billed_dispatches ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.imported_billed_dispatches FROM PUBLIC, anon, authenticated, service_role;
-- The foreign key's index, for the reads that start from an invoice.
CREATE INDEX imported_billed_dispatches_invoice_id_idx ON public.imported_billed_dispatches (invoice_id);
COMMENT ON TABLE public.imported_billed_dispatches IS
  'Migration 192 (WH-180, spec answer 4): an imported dispatch line held as billed by an imported invoice with a line naming no dispatch or with no lines. Written only by import_history, never moved or removed; counts while the invoice is live.';

-- ===== 2. the import =====
CREATE FUNCTION public.import_history(p_masters jsonb, p_apply boolean DEFAULT false) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'extensions', 'utils', 'pg_temp'
    AS $$
DECLARE
  c_sub constant uuid := '00000000-0000-4000-8000-696d706f7274';   -- the "Import" actor of migration 171
  c_files constant text[] := ARRAY['grns', 'grn-lines', 'dispatches', 'dispatch-lines', 'invoices', 'invoice-lines', 'payments'];
  v_prev_claims text := current_setting('request.jwt.claims', true);
  v_prev_sub text := current_setting('request.jwt.claim.sub', true);
  v_prev_role text := current_setting('request.jwt.claim.role', true);
  v_today date := warehouse_security.business_date(now());
  v_payments_on boolean := warehouse_security.payments_enabled();
  v_goods_leave boolean := warehouse_security.invoice_as_goods_leave();
  v_batch uuid := gen_random_uuid();
  v_masters jsonb;
  v_profile uuid;
  v_errors integer := 0;
  v_applied boolean := false;
  v_state text;
  v_files jsonb;
  v_problems jsonb;
  v_problem_counts jsonb;
  v_totals jsonb;
  v_counts jsonb;
  v_next jsonb;
  v_fy integer;
  v_n integer;
BEGIN
  PERFORM warehouse_security.authorize_rpc('import_history', jsonb_build_object());
  -- The operator command only: authorize_rpc lets administrators in, so the call must carry the service role (scripts/import.sh sets it).
  IF auth.jwt()->>'role' IS DISTINCT FROM 'service_role' THEN
    RAISE EXCEPTION 'The import runs from the operator command only' USING ERRCODE = '42501';
  END IF;
  IF p_masters IS NOT NULL AND jsonb_typeof(p_masters) <> 'object' THEN
    RAISE EXCEPTION 'The masters payload must be a JSON object' USING ERRCODE = '22023';
  END IF;
  -- The lock of import_batch: one import at a time, masters or history.
  PERFORM pg_advisory_xact_lock(hashtextextended('import_batch', 0));

  BEGIN  -- the work: rolled back as a whole when this block raises 'import_rollback'
    -- (1) Customers, items and rates first, through WH-142's import, kept within this transaction.
    IF p_masters IS NOT NULL AND p_masters ?| ARRAY['customers', 'items', 'rates'] THEN
      v_masters := public.import_batch(p_masters - 'history_files', true);
      IF NOT COALESCE((v_masters->>'success')::boolean, false) THEN v_errors := v_errors + 1; END IF;
    END IF;

    -- The import actor (as migration 171) and the guard's bypass, for this transaction only.
    SELECT id INTO v_profile FROM public.user_profiles WHERE auth_user_id = c_sub;
    IF v_profile IS NULL THEN
      INSERT INTO public.user_profiles (auth_user_id, name, display_name, role, active, mobile, mobile_verified, enrollment_status, is_service_account)
      VALUES (c_sub, 'Import', 'Import', 'admin', true, '0000000171', false, 'approved', true)
      RETURNING id INTO v_profile;
    ELSE
      UPDATE public.user_profiles SET active = true, role = 'admin', enrollment_status = 'approved', is_service_account = true, deleted_at = NULL
       WHERE id = v_profile;
    END IF;
    PERFORM set_config('request.jwt.claims', jsonb_build_object('role', 'service_role', 'sub', c_sub)::text, true);
    PERFORM set_config('request.jwt.claim.sub', c_sub::text, true);
    PERFORM set_config('request.jwt.claim.role', 'service_role', true);
    PERFORM set_config('warehouse.import', 'on', true);

    -- (2) Work tables. They live until COMMIT; a second call in one transaction starts from empty ones.
    DROP TABLE IF EXISTS pg_temp.imp_problems, pg_temp.imp_cust, pg_temp.imp_item, pg_temp.imp_grn, pg_temp.imp_grn_line, pg_temp.imp_grn_map,
      pg_temp.imp_line_map, pg_temp.imp_disp, pg_temp.imp_disp_line, pg_temp.imp_dline_map, pg_temp.imp_inv, pg_temp.imp_inv_map,
      pg_temp.imp_inv_line, pg_temp.imp_pay, pg_temp.imp_billed;
    CREATE TEMP TABLE imp_problems (file text NOT NULL, line integer NOT NULL, col text, kind text NOT NULL, reason text NOT NULL) ON COMMIT DROP;

    -- Customers and items by the names WH-142 matches (customer: the server's name key; item: name + packaging word).
    CREATE TEMP TABLE imp_cust ON COMMIT DROP AS
      SELECT DISTINCT ON (k.key) k.key, c.id, c.name
        FROM (SELECT DISTINCT utils.customer_name_key(x.customer) AS key
                FROM (SELECT customer FROM warehouse_import.stage_grns UNION SELECT customer FROM warehouse_import.stage_dispatches
                      UNION SELECT customer FROM warehouse_import.stage_invoices UNION SELECT customer FROM warehouse_import.stage_payments) x) k
        JOIN public.customers c ON utils.customer_name_key(c.name) = k.key AND c.deleted_at IS NULL
       ORDER BY k.key, c.id;
    CREATE TEMP TABLE imp_item ON COMMIT DROP AS
      SELECT DISTINCT ON (k.key) k.key, i.id, i.name, COALESCE(i.packaging, 'Bag') AS packaging
        FROM (SELECT DISTINCT lower(btrim(x.item)) || '|' || warehouse_security.packaging_key(x.packaging) AS key
                FROM (SELECT item, packaging FROM warehouse_import.stage_grn_lines
                      UNION SELECT item, packaging FROM warehouse_import.stage_invoice_lines) x) k
        JOIN public.items i ON lower(btrim(i.name)) || '|' || warehouse_security.packaging_key(i.packaging) = k.key
       ORDER BY k.key, i.id;

    -- GRNs.
    CREATE TEMP TABLE imp_grn ON COMMIT DROP AS
      WITH l AS (
        SELECT gr_no, gr_date, string_agg(concat_ws(chr(31), line_no, lower(btrim(item)), warehouse_security.packaging_key(packaging), qty,
                                                    weight, rack, mark, stock_now), chr(30) ORDER BY line_no) AS body, count(*) AS n
          FROM warehouse_import.stage_grn_lines GROUP BY gr_no, gr_date)
      SELECT s.line, s.gr_no, s.gr_date, s.gr_no || '|' || s.gr_date AS doc_key, s.customer, c.id AS customer_id, c.name AS customer_name,
             s.pricing, s.vehicle, s.sender, s.note, COALESCE(l.n, 0) AS n_lines,
             md5(concat_ws(chr(31), s.gr_no, s.gr_date, utils.customer_name_key(s.customer), s.pricing, s.vehicle, s.sender, s.note)
                 || chr(30) || COALESCE(l.body, '')) AS hash,
             d.doc_id AS prior_id, d.content_hash AS prior_hash, d.batch_id AS prior_batch,
             gen_random_uuid() AS new_id, 'add'::text AS status
        FROM warehouse_import.stage_grns s
        LEFT JOIN l ON l.gr_no = s.gr_no AND l.gr_date = s.gr_date
        LEFT JOIN imp_cust c ON c.key = utils.customer_name_key(s.customer)
        LEFT JOIN warehouse_security.imported_documents d ON d.kind = 'grn' AND d.doc_key = s.gr_no || '|' || s.gr_date;
    CREATE INDEX ON imp_grn (doc_key);
    UPDATE imp_grn SET status = 'skip' WHERE prior_hash = hash;
    UPDATE imp_grn SET status = 'changed' WHERE prior_hash IS DISTINCT FROM hash AND prior_id IS NOT NULL;

    -- Every GRN this run can reach: the ones it adds, and the ones an earlier import added (the already-there ones among them).
    CREATE TEMP TABLE imp_grn_map ON COMMIT DROP AS
      SELECT g.doc_key, g.new_id AS gr_id, g.customer_id, g.gr_no, g.gr_date, g.pricing, true AS is_new
        FROM imp_grn g WHERE g.status = 'add'
      UNION ALL
      SELECT d.doc_key, gr.id, gr.customer_id, gr.gr_no::text, warehouse_security.business_date(gr.date), gr.pricing_mode::text, false
        FROM warehouse_security.imported_documents d JOIN public.goodsreceived gr ON gr.id = d.doc_id
       WHERE d.kind = 'grn'
         AND d.doc_key IN (SELECT gr_no || '|' || gr_date FROM warehouse_import.stage_dispatch_lines
                           UNION SELECT gr_no || '|' || gr_date FROM warehouse_import.stage_invoices
                           UNION SELECT gr_no || '|' || gr_date FROM warehouse_import.stage_grn_lines);
    CREATE INDEX ON imp_grn_map (doc_key);

    -- GRN lines.
    CREATE TEMP TABLE imp_grn_line ON COMMIT DROP AS
      SELECT l.line, l.gr_no, l.gr_date, l.gr_no || '|' || l.gr_date AS grn_key, l.line_no, l.item, l.packaging, i.id AS item_id,
             i.name AS item_name, i.packaging AS item_packaging, l.qty, COALESCE(l.weight, 0) AS weight, l.rack, l.mark, l.stock_now,
             g.status AS grn_status, g.new_id AS gr_id, gen_random_uuid() AS new_id
        FROM warehouse_import.stage_grn_lines l
        LEFT JOIN imp_item i ON i.key = lower(btrim(l.item)) || '|' || warehouse_security.packaging_key(l.packaging)
        LEFT JOIN imp_grn g ON g.doc_key = l.gr_no || '|' || l.gr_date;

    -- Every GRN line this run can reach, with its stock before this run's dispatches.
    CREATE TEMP TABLE imp_line_map ON COMMIT DROP AS
      SELECT l.grn_key, l.line_no, l.new_id AS trl_id, l.gr_id, l.qty, l.qty AS stock_before, true AS is_new
        FROM imp_grn_line l WHERE l.grn_status = 'add'
      UNION ALL
      SELECT m.doc_key, igl.line_no, t.id, t.gr_id, t.qty, t.stock, false
        FROM imp_grn_map m
        JOIN warehouse_security.imported_grn_lines igl ON igl.grn_doc_key = m.doc_key
        JOIN public.goodsreceived_trl t ON t.id = igl.grn_item_id
       WHERE NOT m.is_new;
    CREATE INDEX ON imp_line_map (grn_key, line_no);

    -- Dispatches.
    CREATE TEMP TABLE imp_disp ON COMMIT DROP AS
      WITH l AS (
        SELECT disp_no, disp_date, string_agg(concat_ws(chr(31), gr_no, gr_date, grn_line, qty), chr(30) ORDER BY gr_no, gr_date, grn_line) AS body,
               count(*) AS n
          FROM warehouse_import.stage_dispatch_lines GROUP BY disp_no, disp_date)
      SELECT s.line, s.disp_no, s.disp_date, s.disp_no || '|' || s.disp_date AS doc_key, s.customer, c.id AS customer_id, c.name AS customer_name,
             s.vehicle, s.note, COALESCE(l.n, 0) AS n_lines,
             md5(concat_ws(chr(31), s.disp_no, s.disp_date, utils.customer_name_key(s.customer), s.vehicle, s.note) || chr(30) || COALESCE(l.body, '')) AS hash,
             d.doc_id AS prior_id, d.content_hash AS prior_hash, d.batch_id AS prior_batch,
             gen_random_uuid() AS new_id, 'add'::text AS status
        FROM warehouse_import.stage_dispatches s
        LEFT JOIN l ON l.disp_no = s.disp_no AND l.disp_date = s.disp_date
        LEFT JOIN imp_cust c ON c.key = utils.customer_name_key(s.customer)
        LEFT JOIN warehouse_security.imported_documents d ON d.kind = 'dispatch' AND d.doc_key = s.disp_no || '|' || s.disp_date;
    CREATE INDEX ON imp_disp (doc_key);
    UPDATE imp_disp SET status = 'skip' WHERE prior_hash = hash;
    UPDATE imp_disp SET status = 'changed' WHERE prior_hash IS DISTINCT FROM hash AND prior_id IS NOT NULL;

    CREATE TEMP TABLE imp_disp_line ON COMMIT DROP AS
      SELECT l.line, l.disp_no, l.disp_date, l.disp_no || '|' || l.disp_date AS disp_key, l.gr_no, l.gr_date, l.gr_no || '|' || l.gr_date AS grn_key,
             l.grn_line, l.qty, d.status AS disp_status, d.new_id AS disp_id, d.customer_id AS disp_customer,
             m.trl_id, m.gr_id, g.customer_id AS grn_customer, g.gr_date AS grn_day, (g.doc_key IS NOT NULL) AS grn_found,
             gen_random_uuid() AS new_id
        FROM warehouse_import.stage_dispatch_lines l
        LEFT JOIN imp_disp d ON d.doc_key = l.disp_no || '|' || l.disp_date
        LEFT JOIN imp_grn_map g ON g.doc_key = l.gr_no || '|' || l.gr_date
        LEFT JOIN imp_line_map m ON m.grn_key = l.gr_no || '|' || l.gr_date AND m.line_no = l.grn_line;
    CREATE INDEX ON imp_disp_line (disp_key, grn_key, grn_line);

    -- Every dispatch line an invoice line can name: this run's, and the ones an earlier import added.
    CREATE TEMP TABLE imp_dline_map ON COMMIT DROP AS
      SELECT dl.disp_key, dl.grn_key, dl.grn_line, dl.new_id AS dt_id, dl.disp_date, dl.qty, true AS is_new
        FROM imp_disp_line dl WHERE dl.disp_status = 'add'
      UNION ALL
      SELECT d.doc_key, igl.grn_doc_key, igl.line_no, dt.id, warehouse_security.business_date(dp.disp_date), dt.disp_qty, false
        FROM warehouse_security.imported_documents d
        JOIN public.dispatch dp ON dp.id = d.doc_id
        JOIN public.dispatch_trl dt ON dt.disp_id = dp.id
        JOIN warehouse_security.imported_grn_lines igl ON igl.grn_item_id = dt.gr_trl_id
       WHERE d.kind = 'dispatch'
         AND d.doc_key IN (SELECT disp_no || '|' || disp_date FROM warehouse_import.stage_invoice_lines WHERE disp_no IS NOT NULL)
         AND d.doc_key NOT IN (SELECT doc_key FROM imp_disp WHERE status = 'add');
    CREATE INDEX ON imp_dline_map (disp_key, grn_key, grn_line);

    -- Invoices.
    CREATE TEMP TABLE imp_inv ON COMMIT DROP AS
      WITH l AS (
        SELECT inv_no, warehouse_security.financial_year(inv_date) AS fy,
               string_agg(concat_ws(chr(31), inv_date, lower(btrim(item)), warehouse_security.packaging_key(packaging), qty, disp_no, disp_date,
                                    grn_line, months, days, rate, labour_rate, tax_pct, storage, labour, tax_amount), chr(30)
                          ORDER BY line) AS body,
               count(*) AS n,
               sum(storage + COALESCE(labour, 0) + tax_amount) AS line_sum
          FROM warehouse_import.stage_invoice_lines GROUP BY inv_no, warehouse_security.financial_year(inv_date))
      SELECT s.line, s.inv_label, s.inv_no, s.inv_prefix, s.inv_date, warehouse_security.financial_year(s.inv_date) AS fy,
             warehouse_security.financial_year(s.inv_date) || '|' || s.inv_no AS doc_key, s.customer, c.id AS customer_id, c.name AS customer_name,
             s.gr_no, s.gr_date, s.gr_no || '|' || s.gr_date AS grn_key, s.inv_name, s.labour, s.tax, s.discount, s.total, s.note,
             COALESCE(l.n, 0) AS n_lines, l.line_sum,
             md5(concat_ws(chr(31), s.inv_label, s.inv_date, utils.customer_name_key(s.customer), s.gr_no, s.gr_date, s.inv_name, s.labour, s.tax,
                           s.discount, s.total, s.note) || chr(30) || COALESCE(l.body, '')) AS hash,
             d.doc_id AS prior_id, d.content_hash AS prior_hash, d.batch_id AS prior_batch,
             gen_random_uuid() AS new_id, 'add'::text AS status,
             row_number() OVER (PARTITION BY warehouse_security.financial_year(s.inv_date), s.inv_no ORDER BY s.line) AS nth
        FROM warehouse_import.stage_invoices s
        LEFT JOIN l ON l.inv_no = s.inv_no AND l.fy = warehouse_security.financial_year(s.inv_date)
        LEFT JOIN imp_cust c ON c.key = utils.customer_name_key(s.customer)
        LEFT JOIN warehouse_security.imported_documents d
               ON d.kind = 'invoice' AND d.doc_key = warehouse_security.financial_year(s.inv_date) || '|' || s.inv_no;
    CREATE INDEX ON imp_inv (doc_key);
    UPDATE imp_inv SET status = 'skip' WHERE prior_hash = hash AND nth = 1;
    UPDATE imp_inv SET status = 'changed' WHERE prior_hash IS DISTINCT FROM hash AND prior_id IS NOT NULL;

    -- Every invoice a payment can name: this run's (added or already there), and the ones an earlier import added.
    CREATE TEMP TABLE imp_inv_map ON COMMIT DROP AS
      SELECT i.doc_key, CASE WHEN i.status = 'add' THEN i.new_id ELSE i.prior_id END AS invoice_id, i.customer_id, i.inv_date, i.total,
             i.status = 'add' AS is_new
        FROM imp_inv i WHERE i.nth = 1
      UNION ALL
      SELECT d.doc_key, iv.id, iv.customer_id, warehouse_security.business_date(iv.inv_date), iv.total, false
        FROM warehouse_security.imported_documents d JOIN public.invoice iv ON iv.id = d.doc_id
       WHERE d.kind = 'invoice'
         AND d.doc_key IN (SELECT warehouse_security.financial_year(inv_date) || '|' || inv_no FROM warehouse_import.stage_payments WHERE inv_no IS NOT NULL)
         AND d.doc_key NOT IN (SELECT doc_key FROM imp_inv);
    CREATE INDEX ON imp_inv_map (doc_key);

    CREATE TEMP TABLE imp_inv_line ON COMMIT DROP AS
      SELECT l.line, l.inv_label, l.inv_date, warehouse_security.financial_year(l.inv_date) || '|' || l.inv_no AS inv_key, l.item, l.packaging,
             it.id AS item_id, it.name AS item_name, it.packaging AS item_packaging, l.qty, l.disp_no, l.disp_date, l.grn_line, l.months, l.days,
             l.rate, l.labour_rate, l.tax_pct, l.storage, l.labour, l.tax_amount,
             i.status AS inv_status, i.new_id AS invoice_id, i.grn_key, i.inv_date AS header_date,
             NULL::uuid AS dt_id, NULL::date AS dt_date, NULL::text AS dt_problem
        FROM warehouse_import.stage_invoice_lines l
        LEFT JOIN imp_item it ON it.key = lower(btrim(l.item)) || '|' || warehouse_security.packaging_key(l.packaging)
        LEFT JOIN imp_inv i ON i.doc_key = warehouse_security.financial_year(l.inv_date) || '|' || l.inv_no AND i.nth = 1;
    -- The dispatch line an invoice line names: by dispatch and the invoice's GRN (and the GRN line when the dispatch has several of that GRN).
    UPDATE imp_inv_line x SET dt_id = m.dt_id, dt_date = m.disp_date
      FROM (SELECT x2.line, (array_agg(dm.dt_id ORDER BY dm.grn_line))[1] AS dt_id, min(dm.disp_date) AS disp_date, count(*) AS n
              FROM imp_inv_line x2
              JOIN imp_dline_map dm ON dm.disp_key = x2.disp_no || '|' || x2.disp_date AND dm.grn_key = x2.grn_key
                                   AND (x2.grn_line IS NULL OR dm.grn_line = x2.grn_line)
             WHERE x2.disp_no IS NOT NULL
             GROUP BY x2.line) m
     WHERE x.line = m.line AND m.n = 1;
    UPDATE imp_inv_line x SET dt_problem = CASE
        WHEN NOT EXISTS (SELECT 1 FROM imp_dline_map dm WHERE dm.disp_key = x.disp_no || '|' || x.disp_date)
          THEN format('dispatch %s of %s is not in dispatches.csv or an earlier import', x.disp_no, to_char(x.disp_date, 'DD/MM/YYYY'))
        WHEN NOT EXISTS (SELECT 1 FROM imp_dline_map dm WHERE dm.disp_key = x.disp_no || '|' || x.disp_date AND dm.grn_key = x.grn_key)
          THEN format('dispatch %s of %s has no line of this invoice''s GRN %s; an invoice covers one GRN', x.disp_no,
                      to_char(x.disp_date, 'DD/MM/YYYY'), split_part(x.grn_key, '|', 1) || ' of ' || to_char(split_part(x.grn_key, '|', 2)::date, 'DD/MM/YYYY'))
        WHEN x.grn_line IS NULL THEN format('dispatch %s of %s has several lines of this GRN; name the GRN line', x.disp_no, to_char(x.disp_date, 'DD/MM/YYYY'))
        ELSE format('dispatch %s of %s has no line of GRN line %s', x.disp_no, to_char(x.disp_date, 'DD/MM/YYYY'), x.grn_line) END
     WHERE x.disp_no IS NOT NULL AND x.dt_id IS NULL AND x.grn_key IS NOT NULL;

    -- Payments.
    CREATE TEMP TABLE imp_pay ON COMMIT DROP AS
      SELECT s.line, s.receipt, s.pay_date, s.customer, c.id AS customer_id, c.name AS customer_name,
             c.id || '|' || s.receipt || '|' || s.pay_date AS doc_key, s.inv_label, s.inv_no, s.inv_date,
             warehouse_security.financial_year(s.inv_date) || '|' || s.inv_no AS inv_key, m.invoice_id, m.customer_id AS inv_customer,
             m.inv_date AS inv_day, m.total AS inv_total, s.amount, s.mode, s.note,
             md5(concat_ws(chr(31), s.receipt, s.pay_date, utils.customer_name_key(s.customer), s.inv_label, s.inv_date, s.amount, s.mode, s.note)) AS hash,
             d.doc_id AS prior_id, d.content_hash AS prior_hash, d.batch_id AS prior_batch,
             gen_random_uuid() AS new_id, 'add'::text AS status
        FROM warehouse_import.stage_payments s
        LEFT JOIN imp_cust c ON c.key = utils.customer_name_key(s.customer)
        LEFT JOIN imp_inv_map m ON m.doc_key = warehouse_security.financial_year(s.inv_date) || '|' || s.inv_no
        LEFT JOIN warehouse_security.imported_documents d ON d.kind = 'payment' AND d.doc_key = c.id || '|' || s.receipt || '|' || s.pay_date;
    UPDATE imp_pay SET status = 'skip' WHERE prior_hash = hash;
    UPDATE imp_pay SET status = 'changed' WHERE prior_hash IS DISTINCT FROM hash AND prior_id IS NOT NULL;

    ANALYZE imp_cust; ANALYZE imp_item; ANALYZE imp_grn; ANALYZE imp_grn_map; ANALYZE imp_grn_line; ANALYZE imp_line_map; ANALYZE imp_disp;
    ANALYZE imp_disp_line; ANALYZE imp_dline_map; ANALYZE imp_inv; ANALYZE imp_inv_map; ANALYZE imp_inv_line; ANALYZE imp_pay;

    -- (3) The checks.
    -- grns.csv
    INSERT INTO imp_problems
    SELECT 'grns', g.line, 'Customer name', 'error', format('no customer named "%s" in the app (add it through customers.csv or in the app first)', g.customer)
      FROM imp_grn g WHERE g.customer_id IS NULL
    UNION ALL
    SELECT 'grns', g.line, 'GRN date', 'error', format('the date %s is after today', to_char(g.gr_date, 'DD/MM/YYYY'))
      FROM imp_grn g WHERE g.gr_date > v_today
    UNION ALL
    SELECT 'grns', g.line, 'GRN number', 'error', format('GRN number %s is used by a GRN made in the app; nothing made in the app is changed', g.gr_no)
      FROM imp_grn g WHERE g.status = 'add' AND EXISTS (SELECT 1 FROM public.goodsreceived x WHERE x.gr_no = g.gr_no AND x.import_batch_id IS NULL)
    UNION ALL
    SELECT 'grns', g.line, 'GRN number', 'error', format('GRN %s of %s has no lines in grn-lines.csv', g.gr_no, to_char(g.gr_date, 'DD/MM/YYYY'))
      FROM imp_grn g WHERE g.status = 'add' AND g.n_lines = 0
    UNION ALL
    SELECT 'grns', g.line, 'GRN number', 'error',
           format('GRN %s of %s differs from what the import of %s saved; an imported document is never changed', g.gr_no,
                  to_char(g.gr_date, 'DD/MM/YYYY'), (SELECT to_char(b.started_at AT TIME ZONE 'Asia/Kolkata', 'DD/MM/YYYY HH24:MI') FROM warehouse_security.import_batches b WHERE b.id = g.prior_batch))
      FROM imp_grn g WHERE g.status = 'changed';

    -- grn-lines.csv
    INSERT INTO imp_problems
    SELECT 'grn-lines', l.line, 'GRN number', 'error', format('GRN %s of %s is not in grns.csv', l.gr_no, to_char(l.gr_date, 'DD/MM/YYYY'))
      FROM imp_grn_line l WHERE l.grn_status IS NULL
    UNION ALL
    SELECT 'grn-lines', l.line, 'Item name', 'error', format('no item "%s" with the packaging "%s" in the app (add it through items.csv or in the app first)', l.item, l.packaging)
      FROM imp_grn_line l WHERE l.item_id IS NULL;

    -- dispatches.csv
    INSERT INTO imp_problems
    SELECT 'dispatches', d.line, 'Customer name', 'error', format('no customer named "%s" in the app (add it through customers.csv or in the app first)', d.customer)
      FROM imp_disp d WHERE d.customer_id IS NULL
    UNION ALL
    SELECT 'dispatches', d.line, 'Dispatch date', 'error', format('the date %s is after today', to_char(d.disp_date, 'DD/MM/YYYY'))
      FROM imp_disp d WHERE d.disp_date > v_today
    UNION ALL
    SELECT 'dispatches', d.line, 'Dispatch number', 'error', format('dispatch number %s is used by a dispatch made in the app; nothing made in the app is changed', d.disp_no)
      FROM imp_disp d WHERE d.status = 'add' AND EXISTS (SELECT 1 FROM public.dispatch x WHERE x.disp_no = d.disp_no AND x.import_batch_id IS NULL)
    UNION ALL
    SELECT 'dispatches', d.line, 'Dispatch number', 'error', format('dispatch %s of %s has no lines in dispatch-lines.csv', d.disp_no, to_char(d.disp_date, 'DD/MM/YYYY'))
      FROM imp_disp d WHERE d.status = 'add' AND d.n_lines = 0
    UNION ALL
    SELECT 'dispatches', d.line, 'Dispatch number', 'error',
           format('dispatch %s of %s differs from what the import of %s saved; an imported document is never changed', d.disp_no,
                  to_char(d.disp_date, 'DD/MM/YYYY'), (SELECT to_char(b.started_at AT TIME ZONE 'Asia/Kolkata', 'DD/MM/YYYY HH24:MI') FROM warehouse_security.import_batches b WHERE b.id = d.prior_batch))
      FROM imp_disp d WHERE d.status = 'changed';

    -- dispatch-lines.csv
    INSERT INTO imp_problems
    SELECT 'dispatch-lines', l.line, 'Dispatch number', 'error', format('dispatch %s of %s is not in dispatches.csv', l.disp_no, to_char(l.disp_date, 'DD/MM/YYYY'))
      FROM imp_disp_line l WHERE l.disp_status IS NULL
    UNION ALL
    SELECT 'dispatch-lines', l.line, 'GRN number', 'error', format('GRN %s of %s is not in grns.csv or an earlier import', l.gr_no, to_char(l.gr_date, 'DD/MM/YYYY'))
      FROM imp_disp_line l WHERE l.disp_status = 'add' AND NOT l.grn_found
    UNION ALL
    SELECT 'dispatch-lines', l.line, 'GRN line', 'error', format('GRN %s of %s has no line %s', l.gr_no, to_char(l.gr_date, 'DD/MM/YYYY'), l.grn_line)
      FROM imp_disp_line l WHERE l.disp_status = 'add' AND l.grn_found AND l.trl_id IS NULL
    UNION ALL
    SELECT 'dispatch-lines', l.line, 'GRN number', 'error',
           format('GRN %s of %s belongs to another customer than dispatch %s', l.gr_no, to_char(l.gr_date, 'DD/MM/YYYY'), l.disp_no)
      FROM imp_disp_line l WHERE l.disp_status = 'add' AND l.grn_found AND l.disp_customer IS NOT NULL AND l.grn_customer IS DISTINCT FROM l.disp_customer
    UNION ALL
    SELECT 'dispatch-lines', l.line, 'Dispatch date', 'note',
           format('dispatch %s is dated %s, before its GRN %s of %s', l.disp_no, to_char(l.disp_date, 'DD/MM/YYYY'), l.gr_no, to_char(l.gr_date, 'DD/MM/YYYY'))
      FROM imp_disp_line l WHERE l.disp_status = 'add' AND l.grn_found AND l.disp_date < l.gr_date;

    -- Stock: received (or left from an earlier run) less this run's dispatches; never below 0, and equal to "Stock now" where it is given.
    INSERT INTO imp_problems
    SELECT 'dispatch-lines', min(l.line), 'Quantity', 'error',
           format('GRN %s line %s: dispatched %s, but %s %s', split_part(m.grn_key, '|', 1) || ' of ' || to_char(split_part(m.grn_key, '|', 2)::date, 'DD/MM/YYYY'), m.line_no, sum(l.qty),
                  CASE WHEN m.is_new THEN 'it received' ELSE 'it has left' END, m.stock_before)
      FROM imp_disp_line l JOIN imp_line_map m ON m.trl_id = l.trl_id
     WHERE l.disp_status = 'add'
     GROUP BY m.grn_key, m.line_no, m.is_new, m.stock_before
    HAVING sum(l.qty) > m.stock_before;
    INSERT INTO imp_problems
    SELECT 'grn-lines', g.line, 'Stock now', 'error',
           format('Stock now is %s, but received %s less dispatched %s leaves %s', g.stock_now, m.qty, m.qty - s.after, s.after)
      FROM imp_grn_line g
      JOIN imp_line_map m ON m.grn_key = g.grn_key AND m.line_no = g.line_no
      CROSS JOIN LATERAL (SELECT m.stock_before - COALESCE((SELECT sum(l.qty) FROM imp_disp_line l WHERE l.trl_id = m.trl_id AND l.disp_status = 'add'), 0) AS after) s
     WHERE g.stock_now IS NOT NULL AND g.stock_now <> s.after;

    -- invoices.csv
    INSERT INTO imp_problems
    SELECT 'invoices', i.line, 'Customer name', 'error', format('no customer named "%s" in the app (add it through customers.csv or in the app first)', i.customer)
      FROM imp_inv i WHERE i.customer_id IS NULL
    UNION ALL
    SELECT 'invoices', i.line, 'Invoice date', 'error', format('the date %s is after today', to_char(i.inv_date, 'DD/MM/YYYY'))
      FROM imp_inv i WHERE i.inv_date > v_today
    UNION ALL
    SELECT 'invoices', i.line, 'Invoice number', 'error', format('invoice number %s is above %s, the highest the app allows', i.inv_no, warehouse_security.invoice_number_max())
      FROM imp_inv i WHERE i.inv_no > warehouse_security.invoice_number_max()
    UNION ALL
    SELECT 'invoices', i.line, 'Invoice number', 'error',
           format('invoice %s of %s-%s: number %s is already on line %s for that financial year', i.inv_label, i.fy, right((i.fy + 1)::text, 2), i.inv_no,
                  (SELECT min(x.line) FROM imp_inv x WHERE x.doc_key = i.doc_key))
      FROM imp_inv i WHERE i.nth > 1
    UNION ALL
    SELECT 'invoices', i.line, 'Invoice number', 'error',
           format('invoice number %s of %s-%s is used by an invoice made in the app; nothing made in the app is changed', i.inv_no, i.fy, right((i.fy + 1)::text, 2))
      FROM imp_inv i WHERE i.nth = 1 AND i.status = 'add'
       AND EXISTS (SELECT 1 FROM public.invoice x WHERE x.inv_fin_year = i.fy AND x.inv_no = i.inv_no AND x.import_batch_id IS NULL)
    UNION ALL
    SELECT 'invoices', i.line, 'GRN number', 'error', format('GRN %s of %s is not in grns.csv or an earlier import', i.gr_no, to_char(i.gr_date, 'DD/MM/YYYY'))
      FROM imp_inv i WHERE i.nth = 1 AND i.status = 'add' AND NOT EXISTS (SELECT 1 FROM imp_grn_map m WHERE m.doc_key = i.grn_key)
    UNION ALL
    SELECT 'invoices', i.line, 'GRN number', 'error', format('GRN %s of %s belongs to another customer than invoice %s', i.gr_no, to_char(i.gr_date, 'DD/MM/YYYY'), i.inv_label)
      FROM imp_inv i JOIN imp_grn_map m ON m.doc_key = i.grn_key
     WHERE i.nth = 1 AND i.status = 'add' AND i.customer_id IS NOT NULL AND m.customer_id IS DISTINCT FROM i.customer_id
    UNION ALL
    SELECT 'invoices', i.line, 'Invoice number', 'error',
           format('invoice %s of %s-%s differs from what the import of %s saved; an imported document is never changed', i.inv_label, i.fy,
                  right((i.fy + 1)::text, 2), (SELECT to_char(b.started_at AT TIME ZONE 'Asia/Kolkata', 'DD/MM/YYYY HH24:MI') FROM warehouse_security.import_batches b WHERE b.id = i.prior_batch))
      FROM imp_inv i WHERE i.nth = 1 AND i.status = 'changed'
    UNION ALL
    SELECT 'invoices', i.line, 'Invoice date', 'note',
           format('invoice %s is dated before its last dispatch (%s)', i.inv_label, to_char(max(l.dt_date), 'DD/MM/YYYY'))
      FROM imp_inv i JOIN imp_inv_line l ON l.inv_key = i.doc_key AND l.dt_date IS NOT NULL
     WHERE i.nth = 1 AND i.status = 'add'
     GROUP BY i.line, i.inv_label, i.inv_date HAVING max(l.dt_date) > i.inv_date
    UNION ALL
    SELECT 'invoices', i.line, 'Total', 'note',
           format('the lines (storage, labour and tax) less the discount come to %s, not the Total %s; the Total is kept as issued',
                  to_char(i.line_sum - COALESCE(i.discount, 0), 'FM9999999990.00'), to_char(i.total, 'FM9999999990.00'))
      FROM imp_inv i WHERE i.nth = 1 AND i.status = 'add' AND i.n_lines > 0 AND i.line_sum - COALESCE(i.discount, 0) <> i.total
    UNION ALL
    SELECT 'invoices', i.line, 'Invoice number', 'note', format('invoice %s has no lines in invoice-lines.csv', i.inv_label)
      FROM imp_inv i WHERE i.nth = 1 AND i.status = 'add' AND i.n_lines = 0
    UNION ALL
    SELECT 'invoices', 1, NULL, 'note',
           'Record payments is off, so Customer dues counts only this financial year''s invoices; turn it on (Charging screen) for old unpaid invoices to count'
     WHERE NOT v_payments_on AND EXISTS (SELECT 1 FROM imp_inv);

    -- invoice-lines.csv
    INSERT INTO imp_problems
    SELECT 'invoice-lines', l.line, 'Invoice number', 'error', format('invoice %s of %s is not in invoices.csv', l.inv_label, to_char(l.inv_date, 'DD/MM/YYYY'))
      FROM imp_inv_line l WHERE l.inv_status IS NULL
    UNION ALL
    SELECT 'invoice-lines', l.line, 'Item name', 'error', format('no item "%s" with the packaging "%s" in the app (add it through items.csv or in the app first)', l.item, l.packaging)
      FROM imp_inv_line l WHERE l.item_id IS NULL
    UNION ALL
    SELECT 'invoice-lines', l.line, 'Dispatch number', 'error', l.dt_problem
      FROM imp_inv_line l WHERE l.inv_status = 'add' AND l.dt_problem IS NOT NULL
    UNION ALL
    SELECT 'invoice-lines', l.line, 'Dispatch number', 'error',
           format('this dispatch line is already on line %s of this file; a dispatch line is on one invoice', (SELECT min(y.line) FROM imp_inv_line y WHERE y.dt_id = l.dt_id AND y.inv_status = 'add'))
      FROM imp_inv_line l WHERE l.inv_status = 'add' AND l.dt_id IS NOT NULL
       AND EXISTS (SELECT 1 FROM imp_inv_line y WHERE y.dt_id = l.dt_id AND y.inv_status = 'add' AND y.line < l.line)
    UNION ALL
    SELECT 'invoice-lines', l.line, 'Dispatch number', 'error', format('this dispatch line is already on invoice %s', iv.inv_prefix || iv.inv_no)
      FROM imp_inv_line l
      JOIN public.invoice_trl t ON t.disp_trl_id = l.dt_id
      JOIN public.invoice iv ON iv.id = t.invoice_id AND iv.deleted_at IS NULL AND iv.cancelled_at IS NULL
     WHERE l.inv_status = 'add'
    UNION ALL
    -- A link of an earlier run is never moved: the dispatch line stays taken as billed by that invoice, and this invoice is kept as issued.
    SELECT 'invoice-lines', l.line, 'Dispatch number', 'note',
           format('this dispatch line was taken as billed by invoice %s in an earlier import (that invoice names no dispatch); both invoices are kept as issued',
                  warehouse_security.invoice_label(iv.inv_prefix, iv.inv_no))
      FROM imp_inv_line l
      JOIN public.imported_billed_dispatches b ON b.disp_trl_id = l.dt_id
      JOIN public.invoice iv ON iv.id = b.invoice_id AND iv.deleted_at IS NULL AND iv.cancelled_at IS NULL
     WHERE l.inv_status = 'add';

    -- payments.csv
    INSERT INTO imp_problems
    SELECT 'payments', 1, NULL, 'error', 'Record payments is off, so imported payments could not be seen; turn it on (Charging screen) first'
     WHERE NOT v_payments_on AND EXISTS (SELECT 1 FROM imp_pay)
    UNION ALL
    SELECT 'payments', p.line, 'Customer name', 'error', format('no customer named "%s" in the app (add it through customers.csv or in the app first)', p.customer)
      FROM imp_pay p WHERE p.customer_id IS NULL
    UNION ALL
    SELECT 'payments', p.line, 'Payment date', 'error', format('the date %s is after today', to_char(p.pay_date, 'DD/MM/YYYY'))
      FROM imp_pay p WHERE p.pay_date > v_today
    UNION ALL
    SELECT 'payments', p.line, 'Invoice number', 'error',
           format('invoice %s of %s-%s is not in invoices.csv or an earlier import', p.inv_label, warehouse_security.financial_year(p.inv_date),
                  right((warehouse_security.financial_year(p.inv_date) + 1)::text, 2))
      FROM imp_pay p WHERE p.status = 'add' AND p.inv_no IS NOT NULL AND p.invoice_id IS NULL
    UNION ALL
    SELECT 'payments', p.line, 'Invoice number', 'error', format('invoice %s belongs to another customer than this payment', p.inv_label)
      FROM imp_pay p WHERE p.status = 'add' AND p.invoice_id IS NOT NULL AND p.customer_id IS NOT NULL AND p.inv_customer IS DISTINCT FROM p.customer_id
    UNION ALL
    SELECT 'payments', p.line, 'Receipt number', 'error',
           format('receipt %s of %s differs from what the import of %s saved; an imported document is never changed', p.receipt,
                  to_char(p.pay_date, 'DD/MM/YYYY'), (SELECT to_char(b.started_at AT TIME ZONE 'Asia/Kolkata', 'DD/MM/YYYY HH24:MI') FROM warehouse_security.import_batches b WHERE b.id = p.prior_batch))
      FROM imp_pay p WHERE p.status = 'changed'
    UNION ALL
    SELECT 'payments', p.line, 'Payment date', 'note', format('the payment is dated before its invoice %s (%s)', p.inv_label, to_char(p.inv_day, 'DD/MM/YYYY'))
      FROM imp_pay p WHERE p.status = 'add' AND p.invoice_id IS NOT NULL AND p.pay_date < p.inv_day
    UNION ALL
    -- Above what is left: the payments already on the invoice, then this run's in date order; the invoice's due never goes below 0.
    SELECT 'payments', q.line, 'Amount', 'note', format('the payments on invoice %s come to %s, above its total %s; the amount is kept as issued', q.inv_label,
           to_char(q.running, 'FM9999999990.00'), to_char(q.inv_total, 'FM9999999990.00'))
      FROM (SELECT p.line, p.inv_label, p.inv_total,
                   COALESCE((SELECT sum(x.amount) FROM public.payments x WHERE x.invoice_id = p.invoice_id), 0)
                   + sum(p.amount) OVER (PARTITION BY p.invoice_id ORDER BY p.pay_date, p.line) AS running,
                   COALESCE((SELECT sum(x.amount) FROM public.payments x WHERE x.invoice_id = p.invoice_id), 0)
                   + sum(p.amount) OVER (PARTITION BY p.invoice_id ORDER BY p.pay_date, p.line) - p.amount AS before
              FROM imp_pay p WHERE p.status = 'add' AND p.invoice_id IS NOT NULL) q
     WHERE q.running > q.inv_total AND q.before <= q.inv_total;

    SELECT count(*) INTO v_n FROM imp_problems WHERE kind = 'error';
    v_errors := v_errors + v_n;

    -- (4)-(5) The writes, only when there is no error. A refusal of the database here (a constraint the checks did not foresee) is an error
    -- of the run and leaves nothing behind.
    IF v_errors = 0 THEN
      BEGIN
        INSERT INTO warehouse_security.import_batches (id, started_at, applied_at, files)
        VALUES (v_batch, now(), now(), COALESCE(p_masters->'history_files', '[]'::jsonb));

        INSERT INTO public.goodsreceived (id, gr_no, date, customer_id, customer_name, sender_name, registration, note, leon, pricing_mode,
                                          out_of_stock, invoiced, import_batch_id)
        SELECT g.new_id, g.gr_no, warehouse_security.business_day_start(g.gr_date), g.customer_id, g.customer_name, g.sender, g.vehicle, g.note,
               false, g.pricing, false, false, v_batch
          FROM imp_grn g WHERE g.status = 'add';

        INSERT INTO public.goodsreceived_trl (id, gr_id, item_id, item_name, packaging, qty, stock, weight, rack, package_mark)
        SELECT l.new_id, l.gr_id, l.item_id, l.item_name, l.item_packaging, l.qty,
               l.qty - COALESCE((SELECT sum(d.qty) FROM imp_disp_line d WHERE d.trl_id = l.new_id AND d.disp_status = 'add'), 0),
               l.weight, l.rack, l.mark
          FROM imp_grn_line l WHERE l.grn_status = 'add';
        INSERT INTO warehouse_security.imported_grn_lines (grn_doc_key, line_no, grn_item_id)
        SELECT l.grn_key, l.line_no, l.new_id FROM imp_grn_line l WHERE l.grn_status = 'add';

        INSERT INTO public.dispatch (id, disp_no, disp_date, customer_id, customer_name, registration, note, import_batch_id)
        SELECT d.new_id, d.disp_no, warehouse_security.business_day_start(d.disp_date), d.customer_id, d.customer_name, d.vehicle, d.note, v_batch
          FROM imp_disp d WHERE d.status = 'add';
        INSERT INTO public.dispatch_trl (id, gr_id, gr_trl_id, disp_id, disp_qty, source_type)
        SELECT l.new_id, l.gr_id, l.trl_id, l.disp_id, l.qty, 'direct' FROM imp_disp_line l WHERE l.disp_status = 'add';
        -- Lines of GRNs imported by an earlier run that this run dispatches from.
        UPDATE public.goodsreceived_trl t SET stock = t.stock - x.qty
          FROM (SELECT l.trl_id, sum(l.qty) AS qty FROM imp_disp_line l JOIN imp_line_map m ON m.trl_id = l.trl_id AND NOT m.is_new
                 WHERE l.disp_status = 'add' GROUP BY l.trl_id) x
         WHERE t.id = x.trl_id;

        INSERT INTO public.invoice (id, inv_fin_year, inv_no, inv_prefix, gr_id, gr_no, customer_id, customer_name, inv_name, inv_date,
                                    one_time_charge, pricing_mode, notes, created_by, labour, tax_amount, discount, total, total_rounding,
                                    doc_type, import_batch_id)
        SELECT i.new_id, i.fy, i.inv_no, i.inv_prefix, m.gr_id, m.gr_no, i.customer_id, i.customer_name, COALESCE(i.inv_name, i.customer_name),
               warehouse_security.business_day_start(i.inv_date), m.pricing = 'ONE_TIME', m.pricing, i.note, v_profile, i.labour, i.tax,
               i.discount, i.total, 'none', 'invoice', v_batch
          FROM imp_inv i JOIN imp_grn_map m ON m.doc_key = i.grn_key
         WHERE i.nth = 1 AND i.status = 'add';
        INSERT INTO public.invoice_trl (invoice_id, disp_trl_id, duration, no_of_days, labour_rate, charge, tax, issued_storage_amount,
                                        taxable_value, line_tax, kept_item_name, kept_packaging, kept_weight, kept_rack, kept_package_mark,
                                        kept_disp_qty, kept_disp_no, kept_disp_date, kept_grn_no, kept_grn_date, kept_pricing_mode, details_kept_at)
        SELECT l.invoice_id, l.dt_id, l.months, l.days, l.labour_rate, l.rate, l.tax_pct, l.storage, l.storage + COALESCE(l.labour, 0), l.tax_amount,
               l.item_name, l.item_packaging, gt.weight, gt.rack, gt.package_mark, l.qty, l.disp_no,
               CASE WHEN l.disp_no IS NOT NULL THEN warehouse_security.business_day_start(l.disp_date) END,
               m.gr_no, warehouse_security.business_day_start(m.gr_date), m.pricing, now()
          FROM imp_inv_line l
          JOIN imp_grn_map m ON m.doc_key = l.grn_key
          LEFT JOIN public.dispatch_trl dt ON dt.id = l.dt_id
          LEFT JOIN public.goodsreceived_trl gt ON gt.id = dt.gr_trl_id
         WHERE l.inv_status = 'add';

        INSERT INTO public.payments (id, payment_no, payment_date, paid_on, customer_id, customer_name, note, payment_mode, amount, invoice_id,
                                     updated_at, updated_by, import_batch_id)
        SELECT p.new_id, p.receipt, warehouse_security.business_day_start(p.pay_date), NULL, p.customer_id, p.customer_name, p.note, p.mode,
               p.amount, p.invoice_id, now(), v_profile, v_batch
          FROM imp_pay p WHERE p.status = 'add';

        INSERT INTO warehouse_security.imported_documents (kind, doc_key, doc_id, batch_id, content_hash)
        SELECT 'grn', doc_key, new_id, v_batch, hash FROM imp_grn WHERE status = 'add'
        UNION ALL SELECT 'dispatch', doc_key, new_id, v_batch, hash FROM imp_disp WHERE status = 'add'
        UNION ALL SELECT 'invoice', doc_key, new_id, v_batch, hash FROM imp_inv WHERE nth = 1 AND status = 'add'
        UNION ALL SELECT 'payment', doc_key, new_id, v_batch, hash FROM imp_pay WHERE status = 'add';

        -- Dispatches taken as billed (section 5 above), over every imported invoice and dispatch line, this run's and earlier ones. A
        -- dispatch line already linked keeps its link; one on a live invoice line is never linked.
        CREATE TEMP TABLE imp_billed ON COMMIT DROP AS
          WITH inv AS (
            SELECT iv.id, iv.gr_id, iv.inv_fin_year, iv.inv_no, warehouse_security.business_date(iv.inv_date) AS inv_day
              FROM public.invoice iv
             WHERE iv.import_batch_id IS NOT NULL AND iv.deleted_at IS NULL AND iv.cancelled_at IS NULL
               AND (EXISTS (SELECT 1 FROM public.invoice_trl x WHERE x.invoice_id = iv.id AND x.disp_trl_id IS NULL)
                    OR NOT EXISTS (SELECT 1 FROM public.invoice_trl x WHERE x.invoice_id = iv.id)))
          SELECT DISTINCT ON (dt.id) dt.id AS disp_trl_id, inv.id AS invoice_id, inv.gr_id
            FROM inv
            JOIN public.dispatch_trl dt ON dt.gr_id = inv.gr_id
            JOIN public.dispatch dp ON dp.id = dt.disp_id AND dp.import_batch_id IS NOT NULL AND dp.deleted_at IS NULL
           WHERE warehouse_security.business_date(dp.disp_date) <= inv.inv_day
             AND NOT EXISTS (SELECT 1 FROM public.invoice_trl it JOIN public.invoice iv ON iv.id = it.invoice_id
                              WHERE it.disp_trl_id = dt.id AND iv.deleted_at IS NULL AND iv.cancelled_at IS NULL)
             AND NOT EXISTS (SELECT 1 FROM public.imported_billed_dispatches b WHERE b.disp_trl_id = dt.id)
           ORDER BY dt.id, inv.inv_day, inv.inv_fin_year, inv.inv_no, inv.id;
        INSERT INTO public.imported_billed_dispatches (disp_trl_id, invoice_id) SELECT disp_trl_id, invoice_id FROM imp_billed;

        -- The GRNs this run touched: their stock flag and invoiced cache (one statement; the per-row sync skipped the inserts). A GRN that
        -- gained a link counts too (its dispatch lines taken as billed are no longer free).
        UPDATE public.goodsreceived g
           SET out_of_stock = NOT EXISTS (SELECT 1 FROM public.goodsreceived_trl t WHERE t.gr_id = g.id AND t.stock > 0),
               invoiced = (warehouse_security.grn_invoice_state(g.id) = 'invoiced')
         WHERE g.id IN (SELECT new_id FROM imp_grn WHERE status = 'add'
                        UNION SELECT gr_id FROM imp_disp_line WHERE disp_status = 'add'
                        UNION SELECT m.gr_id FROM imp_inv i JOIN imp_grn_map m ON m.doc_key = i.grn_key WHERE i.nth = 1 AND i.status = 'add'
                        UNION SELECT gr_id FROM imp_billed);
      EXCEPTION WHEN OTHERS THEN
        v_errors := v_errors + 1;
        INSERT INTO imp_problems VALUES ('database', 1, NULL, 'error', 'the database refused the import: ' || SQLERRM);
      END;
    END IF;

    -- Notes that read the written rows (only when there is no error).
    IF v_errors = 0 THEN
      -- An imported dispatch line on no live invoice and not taken as billed whose GRN has a live imported invoice of the same day or later:
      -- left only where every such invoice names a dispatch on each of its lines, since an invoice with a line naming no dispatch, or with
      -- no lines, takes it as billed (section 5). The app counts and bills it. Raised when this run adds the dispatch or such an invoice,
      -- so an earlier run's dispatch is caught when its invoice comes now, and a run that adds nothing raises nothing. One note per
      -- dispatch line: on its dispatch-lines.csv row when the line is in this run's file, else on the row of the first such invoice.
      INSERT INTO imp_problems
      SELECT CASE WHEN f.line IS NOT NULL THEN 'dispatch-lines' ELSE 'invoices' END,
             COALESCE(f.line, c.inv_line), CASE WHEN f.line IS NOT NULL THEN 'Dispatch date' ELSE 'GRN number' END, 'note',
             CASE WHEN f.line IS NOT NULL
               THEN format('dispatch %s of %s is on no invoice, but its GRN has an imported invoice of the same day or later; the app bills it '
                           'at today''s rates', c.disp_no, to_char(c.disp_day, 'DD/MM/YYYY'))
               ELSE format('dispatch %s of %s (imported earlier, not in dispatch-lines.csv) is on no invoice, but its GRN has this imported '
                           'invoice of the same day or later; the app bills it at today''s rates', c.disp_no, to_char(c.disp_day, 'DD/MM/YYYY'))
             END
        FROM (SELECT dt.id AS dt_id, dt.gr_trl_id, dp.disp_no, warehouse_security.business_date(dp.disp_date) AS disp_day, d.doc_key AS disp_key,
                     dp.import_batch_id = v_batch AS disp_new,
                     (SELECT min(i.line) FROM imp_inv i JOIN public.invoice iv ON iv.id = i.new_id
                       WHERE i.nth = 1 AND i.status = 'add' AND iv.gr_id = dt.gr_id AND iv.deleted_at IS NULL AND iv.cancelled_at IS NULL
                         AND warehouse_security.business_date(iv.inv_date) >= warehouse_security.business_date(dp.disp_date)) AS inv_line
                FROM public.dispatch_trl dt
                JOIN public.dispatch dp ON dp.id = dt.disp_id AND dp.import_batch_id IS NOT NULL AND dp.deleted_at IS NULL
                JOIN warehouse_security.imported_documents d ON d.kind = 'dispatch' AND d.doc_id = dp.id
               WHERE dt.gr_id IN (SELECT l.gr_id FROM imp_disp_line l WHERE l.disp_status = 'add'
                                  UNION SELECT m.gr_id FROM imp_inv i JOIN imp_grn_map m ON m.doc_key = i.grn_key WHERE i.nth = 1 AND i.status = 'add')
                 AND NOT EXISTS (SELECT 1 FROM public.invoice_trl it JOIN public.invoice iv ON iv.id = it.invoice_id
                                  WHERE it.disp_trl_id = dt.id AND iv.deleted_at IS NULL AND iv.cancelled_at IS NULL)
                 AND NOT EXISTS (SELECT 1 FROM public.imported_billed_dispatches b JOIN public.invoice bi ON bi.id = b.invoice_id
                                  WHERE b.disp_trl_id = dt.id AND bi.deleted_at IS NULL AND bi.cancelled_at IS NULL)
                 AND EXISTS (SELECT 1 FROM public.invoice iv WHERE iv.gr_id = dt.gr_id AND iv.import_batch_id IS NOT NULL AND iv.deleted_at IS NULL
                                AND iv.cancelled_at IS NULL
                                AND warehouse_security.business_date(iv.inv_date) >= warehouse_security.business_date(dp.disp_date))) c
        LEFT JOIN LATERAL (SELECT min(l.line) AS line FROM imp_disp_line l WHERE l.disp_key = c.disp_key AND l.trl_id = c.gr_trl_id) f ON true
       WHERE c.disp_new OR c.inv_line IS NOT NULL
      UNION ALL
      SELECT 'grn-lines', l.line, 'Item name', 'note',
             'no rate for this lot from its GRN date: Customer dues can''t price its goods left to bill, and an app invoice needs one (set a rate in the app)'
        FROM imp_grn_line l
        JOIN public.goodsreceived g ON g.id = l.gr_id
        JOIN public.goodsreceived_trl t ON t.id = l.new_id
       WHERE l.grn_status = 'add'
         AND (t.stock > 0 OR EXISTS (SELECT 1 FROM public.dispatch_trl dt WHERE dt.gr_trl_id = t.id
                                       AND NOT EXISTS (SELECT 1 FROM public.invoice_trl it JOIN public.invoice iv ON iv.id = it.invoice_id
                                                        WHERE it.disp_trl_id = dt.id AND iv.deleted_at IS NULL AND iv.cancelled_at IS NULL)
                                       AND NOT EXISTS (SELECT 1 FROM public.imported_billed_dispatches b JOIN public.invoice bi ON bi.id = b.invoice_id
                                                        WHERE b.disp_trl_id = dt.id AND bi.deleted_at IS NULL AND bi.cancelled_at IS NULL)))
         AND NOT EXISTS (SELECT 1 FROM public.grn_rates r WHERE r.gr_id = g.id AND r.item_id = t.item_id)
         AND (public.find_storage_price(t.item_id, g.customer_id, COALESCE(t.weight, 0), l.gr_date,
                                        CASE WHEN g.pricing_mode = 'ONE_TIME' THEN 'one_time' ELSE 'monthly' END)).id IS NULL
      UNION ALL
      SELECT 'grns', g.line, 'GRN number', 'note',
             format('GRN %s has an invoice and dispatches on no invoice; with Invoice as goods leave off the app will not bill them (GRN is already invoiced)', g.gr_no)
        FROM imp_grn g
       WHERE NOT v_goods_leave AND g.status = 'add'
         AND EXISTS (SELECT 1 FROM public.invoice iv WHERE iv.gr_id = g.new_id AND iv.deleted_at IS NULL AND iv.cancelled_at IS NULL)
         AND warehouse_security.grn_has_free_dispatch_line(g.new_id);
    END IF;

    -- The answer: counts per file, the first 200 problems of each file, the sign-off totals.
    SELECT jsonb_object_agg(f.name, jsonb_build_object(
             'read', f.n_read, 'add', f.n_add, 'skip', f.n_skip,
             'errors', (SELECT count(*) FROM imp_problems p WHERE p.file = f.name AND p.kind = 'error'),
             'notes', (SELECT count(*) FROM imp_problems p WHERE p.file = f.name AND p.kind = 'note')))
      INTO v_files
      FROM (SELECT 'grns' AS name, count(*) AS n_read, count(*) FILTER (WHERE status = 'add') AS n_add, count(*) FILTER (WHERE status = 'skip') AS n_skip FROM imp_grn
            UNION ALL SELECT 'grn-lines', count(*), count(*) FILTER (WHERE grn_status = 'add'), count(*) FILTER (WHERE grn_status = 'skip') FROM imp_grn_line
            UNION ALL SELECT 'dispatches', count(*), count(*) FILTER (WHERE status = 'add'), count(*) FILTER (WHERE status = 'skip') FROM imp_disp
            UNION ALL SELECT 'dispatch-lines', count(*), count(*) FILTER (WHERE disp_status = 'add'), count(*) FILTER (WHERE disp_status = 'skip') FROM imp_disp_line
            UNION ALL SELECT 'invoices', count(*), count(*) FILTER (WHERE status = 'add' AND nth = 1), count(*) FILTER (WHERE status = 'skip') FROM imp_inv
            UNION ALL SELECT 'invoice-lines', count(*), count(*) FILTER (WHERE inv_status = 'add'), count(*) FILTER (WHERE inv_status = 'skip') FROM imp_inv_line
            UNION ALL SELECT 'payments', count(*), count(*) FILTER (WHERE status = 'add'), count(*) FILTER (WHERE status = 'skip') FROM imp_pay) f;
    SELECT COALESCE(jsonb_agg(jsonb_build_object('kind', p.kind, 'file', p.file, 'line', p.line, 'column', p.col, 'reason', p.reason)
                              ORDER BY p.file, p.line, p.kind, p.reason), '[]'::jsonb)
      INTO v_problems
      FROM (SELECT x.*, row_number() OVER (PARTITION BY x.file ORDER BY x.line, x.kind, x.reason) AS n FROM imp_problems x) p WHERE p.n <= 200;
    SELECT COALESCE(jsonb_object_agg(file, n), '{}'::jsonb) INTO v_problem_counts
      FROM (SELECT file, count(*) AS n FROM imp_problems GROUP BY file) c;

    IF v_errors = 0 THEN
      v_fy := warehouse_security.financial_year(v_today);
      v_next := warehouse_security.document_number_suggestion('invoice', v_today);
      v_totals := jsonb_build_object(
        -- (a0) Dispatches taken as billed (section 5), per customer: each dispatch with its invoice, one entry per dispatch and invoice.
        'taken_as_billed', (
          SELECT COALESCE(jsonb_agg(jsonb_build_object('customer', x.name, 'dispatches', x.list) ORDER BY x.name), '[]'::jsonb)
            FROM (SELECT y.name, jsonb_agg(jsonb_build_object('disp_no', y.disp_no, 'disp_date', y.disp_day, 'invoice', y.invoice)
                                           ORDER BY y.disp_day, y.disp_no, y.inv_day, y.invoice) AS list
                    FROM (SELECT DISTINCT c.name, d.disp_no, warehouse_security.business_date(d.disp_date) AS disp_day,
                                 warehouse_security.business_date(iv.inv_date) AS inv_day,
                                 warehouse_security.invoice_label(iv.inv_prefix, iv.inv_no) AS invoice
                            FROM public.imported_billed_dispatches b
                            JOIN public.invoice iv ON iv.id = b.invoice_id AND iv.deleted_at IS NULL AND iv.cancelled_at IS NULL
                            JOIN public.dispatch_trl dt ON dt.id = b.disp_trl_id
                            JOIN public.dispatch d ON d.id = dt.disp_id AND d.deleted_at IS NULL
                            JOIN public.customers c ON c.id = d.customer_id) y
                   GROUP BY y.name) x),
        -- (a) Dispatches on no live invoice and not taken as billed (the never-billed list), per customer.
        'uninvoiced_dispatches', (
          SELECT COALESCE(jsonb_agg(jsonb_build_object('customer', x.name, 'dispatches', x.n, 'bags', x.bags) ORDER BY x.name), '[]'::jsonb)
            FROM (SELECT c.name, count(DISTINCT d.id) AS n, sum(dt.disp_qty) AS bags
                    FROM public.dispatch_trl dt
                    JOIN public.dispatch d ON d.id = dt.disp_id AND d.deleted_at IS NULL
                    JOIN public.customers c ON c.id = d.customer_id
                   WHERE NOT EXISTS (SELECT 1 FROM public.invoice_trl it JOIN public.invoice iv ON iv.id = it.invoice_id
                                      WHERE it.disp_trl_id = dt.id AND iv.deleted_at IS NULL AND iv.cancelled_at IS NULL)
                     AND NOT EXISTS (SELECT 1 FROM public.imported_billed_dispatches b JOIN public.invoice bi ON bi.id = b.invoice_id
                                      WHERE b.disp_trl_id = dt.id AND bi.deleted_at IS NULL AND bi.cancelled_at IS NULL)
                   GROUP BY c.name) x),
        -- (b) Stock in store per item and packaging.
        'stock', (
          SELECT COALESCE(jsonb_agg(jsonb_build_object('item', x.item_name, 'packaging', x.packaging, 'bags', x.bags) ORDER BY x.item_name, x.packaging), '[]'::jsonb)
            FROM (SELECT t.item_name, COALESCE(t.packaging, '') AS packaging, sum(t.stock) AS bags
                    FROM public.goodsreceived_trl t JOIN public.goodsreceived g ON g.id = t.gr_id AND g.deleted_at IS NULL
                   WHERE t.stock > 0 GROUP BY t.item_name, COALESCE(t.packaging, '')) x),
        -- (c) Owed per customer: due on live invoices (total less payments, never below 0, as invoice_payment_state), and payments on account.
        'owed', (
          SELECT COALESCE(jsonb_agg(jsonb_build_object('customer', c.name, 'due', x.due, 'on_account', x.on_account) ORDER BY c.name), '[]'::jsonb)
            FROM (SELECT customer_id, sum(due) AS due, sum(on_account) AS on_account
                    FROM (SELECT i.customer_id, GREATEST(COALESCE(i.total, 0)::numeric(12,2) - COALESCE(p.paid, 0), 0) AS due, 0::numeric AS on_account
                            FROM public.invoice i
                            LEFT JOIN (SELECT invoice_id, sum(amount) AS paid FROM public.payments WHERE invoice_id IS NOT NULL GROUP BY invoice_id) p
                                   ON p.invoice_id = i.id
                           WHERE i.deleted_at IS NULL AND i.cancelled_at IS NULL
                          UNION ALL
                          SELECT p.customer_id, 0, p.amount FROM public.payments p WHERE p.invoice_id IS NULL AND p.customer_id IS NOT NULL) u
                   GROUP BY customer_id HAVING sum(due) > 0 OR sum(on_account) > 0) x
            JOIN public.customers c ON c.id = x.customer_id),
        -- (d) Live invoices per financial year, imported and made in the app.
        'invoices_by_year', (
          SELECT COALESCE(jsonb_agg(jsonb_build_object('fin_year', x.fy, 'imported_count', x.ic, 'imported_total', x.it, 'app_count', x.ac, 'app_total', x.at)
                                    ORDER BY x.fy), '[]'::jsonb)
            FROM (SELECT inv_fin_year AS fy,
                         count(*) FILTER (WHERE import_batch_id IS NOT NULL) AS ic, COALESCE(sum(total) FILTER (WHERE import_batch_id IS NOT NULL), 0) AS it,
                         count(*) FILTER (WHERE import_batch_id IS NULL) AS ac, COALESCE(sum(total) FILTER (WHERE import_batch_id IS NULL), 0) AS at
                    FROM public.invoice WHERE deleted_at IS NULL AND cancelled_at IS NULL GROUP BY inv_fin_year) x),
        -- (e) The next invoice number the app gives this financial year (highest of the year + 1, imported invoices included).
        'next_invoice', jsonb_build_object('fin_year', v_fy, 'number', v_next->>'number', 'prefix', v_next->>'prefix', 'message', v_next->>'message'));
    END IF;

    v_counts := (SELECT jsonb_object_agg(k, v->'add') FROM jsonb_each(v_files) AS e(k, v));
    IF v_errors = 0 AND NOT EXISTS (SELECT 1 FROM jsonb_each(v_counts) e WHERE (e.value)::text::integer > 0) THEN
      -- Nothing new (every document already there): no batch is recorded.
      DELETE FROM warehouse_security.import_batches WHERE id = v_batch;
    ELSIF v_errors = 0 THEN
      UPDATE warehouse_security.import_batches SET counts = v_counts WHERE id = v_batch;
      -- The batch is the audit record of every row it wrote (the per-row audit skipped them).
      INSERT INTO public.audit_log (table_name, action, user_id, old_data, new_data)
      VALUES ('import_batches', 'INSERT', c_sub, NULL,
              jsonb_build_object('id', v_batch, 'files', COALESCE(p_masters->'history_files', '[]'::jsonb), 'counts', v_counts));
    END IF;

    -- Leave the actor switched off (a kept service account never opens a session), then decide.
    UPDATE public.user_profiles SET active = false WHERE auth_user_id = c_sub;
    PERFORM set_config('warehouse.import', '', true);
    IF p_apply AND v_errors = 0 THEN
      v_applied := true;
    ELSE
      RAISE EXCEPTION 'import_rollback' USING ERRCODE = 'P0001';
    END IF;
  EXCEPTION WHEN SQLSTATE 'P0001' THEN
    GET STACKED DIAGNOSTICS v_state = MESSAGE_TEXT;
    IF v_state IS DISTINCT FROM 'import_rollback' THEN RAISE; END IF;
    v_applied := false;
  END;

  -- The caller's own claims again (they were set for this transaction only).
  PERFORM set_config('request.jwt.claims', COALESCE(v_prev_claims, ''), true);
  PERFORM set_config('request.jwt.claim.sub', COALESCE(v_prev_sub, ''), true);
  PERFORM set_config('request.jwt.claim.role', COALESCE(v_prev_role, ''), true);

  RETURN jsonb_build_object('success', v_errors = 0, 'applied', v_applied, 'dry_run', NOT COALESCE(p_apply, false),
    'batch_id', CASE WHEN v_applied AND EXISTS (SELECT 1 FROM warehouse_security.import_batches b WHERE b.id = v_batch) THEN v_batch END, 'masters', v_masters, 'files', v_files, 'problems', v_problems,
    'problem_counts', v_problem_counts, 'totals', v_totals);
END;
$$;

ALTER FUNCTION public.import_history(jsonb, boolean) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION public.import_history(jsonb, boolean) FROM PUBLIC, anon, authenticated;
GRANT ALL ON FUNCTION public.import_history(jsonb, boolean) TO service_role;

NOTIFY pgrst, 'reload schema';
