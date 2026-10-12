-- One row per receipt in the GRN activity of one customer.
--
-- get_customer_grn_activity (one customer) listed a goods receipt (GRN) once for EACH of its
-- non-deleted invoices. Its CTE invoice_status held one row per invoice and was joined straight
-- to the receipts (LEFT JOIN invoice_status inv ON gd.grn_id = inv.gr_id), so a receipt with two
-- invoices came out as two rows, and everything added up over those rows was inflated with it:
-- total_grns, total_items, total_quantity, total_weight_kg, total_invoiced_grns and
-- total_images of the summary, and the receipt itself, twice, in grns[].
--
-- How a receipt gets two invoices: before migration 41 a second save for the same receipt
-- succeeded under a new invoice number, and migration 41 enforces the rule "a receipt is
-- invoiced once" only when an invoice is written ("No existing row is validated or changed").
-- Old data can therefore hold such receipts; the current save paths do not create them.
--
-- Worked example. A customer has three receipts in the period:
--
--   receipt  bags  kg per bag  kg    invoices
--   GA        1       10       10    two (2026-7102 on 10 Mar, 2026-7101 on 11 Mar)
--   GB        3       10       30    one (2026-7104)
--   GC        3       10       30    none
--
--                              total_grns  total_quantity  total_weight_kg  total_invoiced_grns  GA listed
--   before this migration           4             8               80                 3             twice
--   after                           3             7               70                 2             once
--
-- Now invoice_status is one row per receipt: DISTINCT ON (gr_id) keeps the invoice that is the
-- latest by invoice date, then financial year, then number, then id (GA: 2026-7101, the 11 Mar
-- one, although 7102 is the higher number), and the new key invoice_count says how many
-- non-deleted invoices the receipt has (a window function, which is evaluated before DISTINCT ON
-- picks its row, as in migration 61). A receipt with no invoice has invoice_count 0.
--
--   get_customer_grn_activity(p_customer_uuid, p_from_date, p_to_date), one customer:
--     grns[].invoice_status.invoice_count   NEW, a number: the non-deleted invoices of the
--                                           receipt (1 for an ordinary receipt, 0 for one that
--                                           is not invoiced, 2 or more for old doubled data)
--     grns[].invoice_status.invoice_id and .invoice_number
--                                           the LATEST invoice's (they were the invoice's, one
--                                           row per invoice)
--     summary.total_grns, total_items, total_quantity, total_weight_kg, total_invoiced_grns,
--     total_images: count each receipt once
--     unchanged: grns[].invoice_status.is_invoiced, every other key
--
-- Every key keeps its name and its JSON type; invoice_count is the only addition.
--
-- Nothing else changes: the authorize_rpc guard (not redefined), SECURITY DEFINER, the
-- search_path and jit setting, the grants, the India day cuts of migration 56, the weight
-- expressions of migration 59, the key order of the existing keys and the order of the rows
-- (grn_date, newest first). The all-customers branch of this function and get_all_grn_activity
-- have no invoice join and are not touched.
--
-- Method: the current definition is patched, not rewritten. pg_get_functiondef keeps the guard,
-- SECURITY DEFINER, the search_path, the grants and every other line (including migrations 56
-- and 59); each replaced text must occur exactly as often as stated, or the migration fails and
-- nothing is applied. Steps 1 and 2 replace the CTE and the default of a receipt without an
-- invoice; steps 3 to 6 replace nothing: they fail the migration unless the join, the receipt
-- count and the invoiced count are still written the way the fix relies on, and unless the
-- invoice status is still taken whole. Every replacement is written so that its before-text is
-- NOT contained in its after-text: run directly a second time (outside the ledger), step 1
-- finds no marker and fails with the count error instead of patching the new text again.

-- The definition with one marker replaced; fails unless the marker occurs
-- exactly `expected` times. Dropped at the end of this migration.
CREATE FUNCTION pg_temp.replace_marker(fn text, definition text, marker text, replacement text, expected integer) RETURNS text
LANGUAGE plpgsql AS $$
DECLARE occurrences integer := (length(definition) - length(replace(definition, marker, ''))) / length(marker);
BEGIN
  IF occurrences <> expected THEN
    RAISE EXCEPTION 'Expected % occurrence(s) of the marker in %, found %: %', expected, fn, occurrences, left(marker, 80);
  END IF;
  RETURN replace(definition, marker, replacement);
END $$;

DO $migration$
DECLARE
  change record;
  current_fn text := '';
  definition text;
BEGIN
  FOR change IN SELECT * FROM (VALUES
    -- One row per receipt: the latest non-deleted invoice, and how many there are.
    (1, 'public.get_customer_grn_activity(uuid,date,date)',
     $b$invoice_status AS (
            SELECT
                i.gr_id,
                jsonb_build_object(
                    'is_invoiced', true,
                    'invoice_id', i.id,
                    'invoice_number', i.inv_fin_year::text || '-' || i.inv_no::text
                ) as status
            FROM invoice i
            WHERE i.deleted_at IS NULL
        ),$b$,
     $a$invoice_status AS (
            SELECT DISTINCT ON (i.gr_id)
                i.gr_id,
                jsonb_build_object(
                    'is_invoiced', true,
                    'invoice_id', i.id,
                    'invoice_number', i.inv_fin_year::text || '-' || i.inv_no::text,
                    'invoice_count', COUNT(*) OVER (PARTITION BY i.gr_id)
                ) as status
            FROM invoice i
            WHERE i.deleted_at IS NULL
            ORDER BY i.gr_id, i.inv_date DESC, i.inv_fin_year DESC, i.inv_no DESC, i.id DESC
        ),$a$, 1),
    -- A receipt without an invoice has no invoice: count 0.
    (2, 'public.get_customer_grn_activity(uuid,date,date)',
     $b$COALESCE(inv.status, jsonb_build_object('is_invoiced', false, 'invoice_id', null, 'invoice_number', null)) as invoice_status,$b$,
     $a$COALESCE(inv.status, jsonb_build_object('is_invoiced', false, 'invoice_id', null, 'invoice_number', null, 'invoice_count', 0)) as invoice_status,$a$, 1),
    -- The next four entries change nothing; the migration fails unless the text they name is
    -- still there, once: the join the fix relies on (one row per receipt on its right side) ...
    (3, 'public.get_customer_grn_activity(uuid,date,date)',
     $b$LEFT JOIN invoice_status inv ON gd.grn_id = inv.gr_id$b$,
     $a$LEFT JOIN invoice_status inv ON gd.grn_id = inv.gr_id$a$, 1),
    -- ... the receipt count of the summary (rows of the one-row-per-receipt set) ...
    (4, 'public.get_customer_grn_activity(uuid,date,date)',
     $b$'total_grns', COUNT(*),$b$,
     $a$'total_grns', COUNT(*),$a$, 1),
    -- ... the invoiced receipts (rows whose status says invoiced) ...
    (5, 'public.get_customer_grn_activity(uuid,date,date)',
     $b$'total_invoiced_grns', COUNT(*) FILTER (WHERE (invoice_status->>'is_invoiced')::boolean = true),$b$,
     $a$'total_invoiced_grns', COUNT(*) FILTER (WHERE (invoice_status->>'is_invoiced')::boolean = true),$a$, 1),
    -- ... and the status handed out whole, so that invoice_count reaches the answer.
    (6, 'public.get_customer_grn_activity(uuid,date,date)',
     $b$'invoice_status', invoice_status,$b$,
     $a$'invoice_status', invoice_status,$a$, 1)
  ) AS changes(step, signature, before_text, after_text, times)
  ORDER BY step
  LOOP
    IF change.signature <> current_fn THEN
      IF current_fn <> '' THEN EXECUTE definition; END IF;
      current_fn := change.signature;
      definition := pg_get_functiondef(current_fn::regprocedure);
    END IF;
    definition := pg_temp.replace_marker(current_fn, definition, change.before_text, change.after_text, change.times);
  END LOOP;
  EXECUTE definition;
END;
$migration$;

DROP FUNCTION pg_temp.replace_marker(text, text, text, text, integer);
NOTIFY pgrst, 'reload schema';
