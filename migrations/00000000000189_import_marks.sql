-- Migration 189 (WH-180, part 1 of the import of past years): the "Imported" mark, the import's own records, issued line amounts, and
-- number uniqueness that lets an old system's GRN and dispatch numbers repeat across years. Written against the tables and functions as
-- migrations 175 (invoice number prefix) and 188 left them. Nothing here writes a document; the import itself comes in a later migration.
--
--  1. Three operator-only tables in warehouse_security (owner supabase_admin, RLS on, no grants; only the import function writes them):
--     import_batches (one row per applied import: when it started and was applied, the files with their sha256 and row counts, the counts
--     it added), imported_documents (one row per imported document, keyed by kind + the document's key in the files: number|date for a GRN
--     or dispatch, fy|number for an invoice, customer|receipt|date for a payment; the hash of its content as imported, so a second run
--     can tell "already there" from "changed"), imported_grn_lines (the line number a GRN line had in the files, so a later file's dispatch
--     lines find it).
--  2. public.goodsreceived, public.dispatch, public.invoice and public.payments gain import_batch_id (uuid, NULL on every document made in
--     the app, else the import batch that wrote it), with a partial index on the imported rows. Lines take the mark of their header. On
--     invoice it is granted to authenticated like the other readable columns (column grants, migration 48); the other three tables are
--     readable as a whole already.
--  3. public.invoice_trl.issued_storage_amount (numeric(12,2)): the storage amount of an imported line as it was issued; NULL on every app
--     line (an app line's storage is worked out on read, as before).
--  4. GRN and dispatch numbers. An old system may start its numbers again each year, so one number can belong to several imported
--     documents of different dates. goodsreceived_gr_no_key UNIQUE (gr_no) and dispatch_disp_no_key UNIQUE (disp_no) are replaced by two
--     partial unique indexes each: the number alone among app documents (import_batch_id IS NULL), as before, and number + date among
--     imported ones (the date is stored as the India midnight of the day, so one day gives one value). The indexes do not stop an imported
--     document from holding a number an app document holds: the import refuses that clash in its own checks before it writes. The app's
--     saves keep checking "number already used" against every row, imported ones included (save_grn, update_grn,
--     create_dispatch_with_stock_check_internal, update_dispatch_smart), so a number the app gives stays unique for all time.
--     A plain index on dispatch.disp_no keeps those lookups by number an index read (the GRN number is the first column of
--     idx_goodsreceived_search already). No table check holds a number format (only the not-blank checks); the format rules are in the
--     save functions, which the import does not call.
--  5. Invoice prefix (migration 175): invoice_prefix_for_year counts only app invoices, so imported invoices of a year (whatever prefix
--     their old numbers carry) never decide the prefix the app gives that year; invoice_assign_prefix keeps the prefix an imported invoice
--     is inserted with instead of assigning the year's (this also spares the import a per-row count of the year's invoices).
--  6. Next numbers (document_number_suggestion, migration 127) are unchanged: for invoices they are the highest number of the year (of
--     every year under the sequence scheme) + 1 over every row, imported ones included, so importing invoices 1 to 310 of a year makes the
--     next 311; for GRNs and dispatches they are the highest number of the series + 1 over every row, so the suggestion never offers a
--     number an imported document holds (the save would refuse it).
--
-- No role is created, altered or dropped. No function with a definition file is changed.

-- ===== 1. the import's records =====
CREATE TABLE warehouse_security.import_batches (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  started_at timestamptz NOT NULL DEFAULT now(),
  applied_at timestamptz,
  files      jsonb NOT NULL DEFAULT '[]'::jsonb CHECK (jsonb_typeof(files) = 'array'),
  counts     jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(counts) = 'object')
);
ALTER TABLE warehouse_security.import_batches OWNER TO supabase_admin;
ALTER TABLE warehouse_security.import_batches ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE warehouse_security.import_batches FROM PUBLIC, anon, authenticated, service_role;
COMMENT ON TABLE warehouse_security.import_batches IS
  'Migration 189 (WH-180): one row per applied import of past years. files = [{name, sha256, rows}], counts = what it added. Written only by the import function; kept for good.';

CREATE TABLE warehouse_security.imported_documents (
  kind         text NOT NULL CHECK (kind IN ('grn', 'dispatch', 'invoice', 'payment')),
  doc_key      text NOT NULL CHECK (char_length(doc_key) BETWEEN 1 AND 300),
  doc_id       uuid NOT NULL,
  batch_id     uuid NOT NULL REFERENCES warehouse_security.import_batches(id),
  content_hash text NOT NULL CHECK (content_hash ~ '^[0-9a-f]{32}$'),
  PRIMARY KEY (kind, doc_key)
);
ALTER TABLE warehouse_security.imported_documents OWNER TO supabase_admin;
ALTER TABLE warehouse_security.imported_documents ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE warehouse_security.imported_documents FROM PUBLIC, anon, authenticated, service_role;
COMMENT ON TABLE warehouse_security.imported_documents IS
  'Migration 189 (WH-180): one row per imported document. doc_key = number|date (grn, dispatch), fy|number (invoice), customer|receipt|date (payment); content_hash = md5 of the document as imported, so a second run skips an equal document and refuses a changed one.';

CREATE TABLE warehouse_security.imported_grn_lines (
  grn_doc_key text NOT NULL CHECK (char_length(grn_doc_key) BETWEEN 1 AND 300),
  line_no     integer NOT NULL CHECK (line_no >= 1),
  grn_item_id uuid NOT NULL REFERENCES public.goodsreceived_trl(id),
  PRIMARY KEY (grn_doc_key, line_no)
);
ALTER TABLE warehouse_security.imported_grn_lines OWNER TO supabase_admin;
ALTER TABLE warehouse_security.imported_grn_lines ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE warehouse_security.imported_grn_lines FROM PUBLIC, anon, authenticated, service_role;
-- One GRN line has one line number; the index also serves the foreign key when a goodsreceived_trl row is removed.
CREATE UNIQUE INDEX imported_grn_lines_grn_item_id_key ON warehouse_security.imported_grn_lines (grn_item_id);
COMMENT ON TABLE warehouse_security.imported_grn_lines IS
  'Migration 189 (WH-180): the line number an imported GRN line had in the import files (grn_doc_key = number|date of its GRN), so dispatch lines imported later find it.';

-- ===== 2. the mark =====
ALTER TABLE public.goodsreceived ADD COLUMN import_batch_id uuid REFERENCES warehouse_security.import_batches(id);
ALTER TABLE public.dispatch      ADD COLUMN import_batch_id uuid REFERENCES warehouse_security.import_batches(id);
ALTER TABLE public.invoice       ADD COLUMN import_batch_id uuid REFERENCES warehouse_security.import_batches(id);
ALTER TABLE public.payments      ADD COLUMN import_batch_id uuid REFERENCES warehouse_security.import_batches(id);
CREATE INDEX idx_goodsreceived_import_batch_id ON public.goodsreceived (import_batch_id) WHERE import_batch_id IS NOT NULL;
CREATE INDEX idx_dispatch_import_batch_id ON public.dispatch (import_batch_id) WHERE import_batch_id IS NOT NULL;
CREATE INDEX idx_invoice_import_batch_id ON public.invoice (import_batch_id) WHERE import_batch_id IS NOT NULL;
CREATE INDEX idx_payments_import_batch_id ON public.payments (import_batch_id) WHERE import_batch_id IS NOT NULL;
GRANT SELECT (import_batch_id) ON TABLE public.invoice TO authenticated;
COMMENT ON COLUMN public.goodsreceived.import_batch_id IS 'Migration 189 (WH-180): the import batch that wrote this GRN from the previous system; NULL for a GRN made in the app.';
COMMENT ON COLUMN public.dispatch.import_batch_id IS 'Migration 189 (WH-180): the import batch that wrote this dispatch from the previous system; NULL for a dispatch made in the app.';
COMMENT ON COLUMN public.invoice.import_batch_id IS 'Migration 189 (WH-180): the import batch that wrote this invoice from the previous system; NULL for an invoice made in the app.';
COMMENT ON COLUMN public.payments.import_batch_id IS 'Migration 189 (WH-180): the import batch that wrote this payment from the previous system; NULL for a payment recorded in the app.';

-- ===== 3. amounts as issued =====
ALTER TABLE public.invoice_trl ADD COLUMN issued_storage_amount numeric(12,2);
COMMENT ON COLUMN public.invoice_trl.issued_storage_amount IS
  'Migration 189 (WH-180): the storage amount of an imported invoice line as the previous system issued it; NULL on every app line, whose storage is worked out on read.';

-- ===== 4. GRN and dispatch numbers =====
-- App documents: the number alone is unique, as before. Imported documents: number + date is unique, so an old system's numbers may
-- repeat across years. A clash between an imported number and an app number is not refused here: the import checks it before writing,
-- holding the app saves' lock 71040 to COMMIT when it applies (migration 192), and the app's saves check every row under that lock.
-- An imported row always has its date (the partial index treats NULL dates as distinct); NOT VALID because every existing row is an app row.
ALTER TABLE public.goodsreceived ADD CONSTRAINT goodsreceived_imported_has_date CHECK (import_batch_id IS NULL OR date IS NOT NULL) NOT VALID;
ALTER TABLE public.dispatch ADD CONSTRAINT dispatch_imported_has_date CHECK (import_batch_id IS NULL OR disp_date IS NOT NULL) NOT VALID;

ALTER TABLE public.goodsreceived DROP CONSTRAINT goodsreceived_gr_no_key;
CREATE UNIQUE INDEX goodsreceived_gr_no_app_key ON public.goodsreceived (gr_no) WHERE import_batch_id IS NULL;
CREATE UNIQUE INDEX goodsreceived_gr_no_date_imported_key ON public.goodsreceived (gr_no, date) WHERE import_batch_id IS NOT NULL;

ALTER TABLE public.dispatch DROP CONSTRAINT dispatch_disp_no_key;
CREATE UNIQUE INDEX dispatch_disp_no_app_key ON public.dispatch (disp_no) WHERE import_batch_id IS NULL;
CREATE UNIQUE INDEX dispatch_disp_no_date_imported_key ON public.dispatch (disp_no, disp_date) WHERE import_batch_id IS NOT NULL;
-- "Is this number taken" over every row (the saves, check_dispatch_exists, the PDF lookup) can't use the partial indexes.
CREATE INDEX idx_dispatch_disp_no ON public.dispatch (disp_no);

-- ===== 5. invoice prefix: app invoices only =====
-- As migration 175, counting only app invoices.
CREATE OR REPLACE FUNCTION warehouse_security.invoice_prefix_for_year(p_fin_year integer) RETURNS text
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public'
    AS $$
  SELECT COALESCE(
    (SELECT i.inv_prefix FROM public.invoice i WHERE i.inv_fin_year = p_fin_year AND i.import_batch_id IS NULL
      GROUP BY i.inv_prefix ORDER BY count(*) DESC, min(i.inv_no), i.inv_prefix LIMIT 1),
    (SELECT n.prefix FROM warehouse_security.document_numbering n WHERE n.document_type = 'invoice'),
    '')
$$;

-- As migration 175, except that an imported invoice keeps the prefix it is inserted with (the part of its old number before the digits).
CREATE OR REPLACE FUNCTION warehouse_security.invoice_assign_prefix() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public'
    AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    IF NEW.import_batch_id IS NULL THEN
      NEW.inv_prefix := warehouse_security.invoice_prefix_for_year(NEW.inv_fin_year);
    END IF;
  ELSIF NEW.inv_fin_year IS DISTINCT FROM OLD.inv_fin_year THEN
    -- Re-dated into another financial year (update_invoice, migration 121): the invoice carries that year's prefix, which update_invoice
    -- sets. The year's prefix is read before this row joins it (the row still holds its old year in the table).
    IF NEW.inv_prefix IS DISTINCT FROM warehouse_security.invoice_prefix_for_year(NEW.inv_fin_year) THEN
      RAISE EXCEPTION 'An invoice moved to financial year % takes that year''s prefix.', NEW.inv_fin_year USING ERRCODE = '22023';
    END IF;
  ELSIF NEW.inv_prefix IS DISTINCT FROM OLD.inv_prefix THEN
    RAISE EXCEPTION 'An invoice keeps the prefix it was saved with.' USING ERRCODE = '22023';
  END IF;
  RETURN NEW;
END $$;

NOTIFY pgrst, 'reload schema';
