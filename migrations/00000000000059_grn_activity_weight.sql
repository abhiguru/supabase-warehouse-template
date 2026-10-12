-- The GRN activity reports count the weight of a receipt as bags times kilograms per bag.
--
-- Where a weight comes from: public.goodsreceived_trl.weight, an integer, nullable, kg PER BAG
-- (per unit of qty) as the receipt line was typed in. A received line that holds 100 bags of
-- 50 kg stores qty 100 and weight 50, not 5000. The stock reports multiply it by the bags that
-- are still in storage (get_customer_stock_summary and get_all_stock_summary: weight x stock;
-- get_operations_dashboard: total_stock_weight), the dispatch activity report by the bags
-- dispatched (migration 58: weight x disp_qty). Each is the per-bag weight times the quantity
-- the report counts.
--
-- The fault: public.get_customer_grn_activity built "the weight of a receipt" as
-- SUM(grt.weight) over its lines, the per-bag weights added up WITHOUT the bags. A receipt with
-- Cumin 100 bags of 25 kg and Fennel 40 bags of 50 kg came out as 75, not as 4500 kg. Every
-- other weight of the function is built from that figure, so all of them were wrong the same
-- way. The mobile app reads them (src/services/reporting/grn-activity-service.ts: total_weight
-- on a receipt and total_weight_kg in the summary) but shows neither on a screen today. The
-- GRN activity PDF (functions/_shared/report-definitions.ts) works around it for one customer
-- by multiplying the lines itself.
--
-- The rule, for every weight TOTAL of the two GRN activity functions: kg of the received lines
-- = the sum, over the lines, of the RECEIVED quantity of the line (goodsreceived_trl.qty, not
-- the stock left: a receipt that is fully dispatched was still received) times the per-bag
-- weight of the line. A line whose per-bag weight (or quantity) is null counts as 0 (the SUM
-- ignores the null product); a receipt without lines, or with only such lines, is 0, a number.
-- The key names and their JSON type (a number) do not change.
--
-- The keys, and what this migration does with each:
--
--   get_customer_grn_activity(p_customer_uuid, p_from_date, p_to_date)
--     one customer (p_customer_uuid given), answer data.grns[] and data.summary:
--       grns[].items[].weight        kg PER BAG of that line, as typed in. Stays; not a total.
--       grns[].total_weight          CHANGED. Was the sum of the per-bag weights of the receipt's
--                                    lines. Now the kg of the receipt (qty x per-bag weight,
--                                    summed over its lines).
--       summary.total_weight_kg      CHANGED, through the figure above: it is the sum of the
--                                    listed receipts' total_weight, so it is now the kg of
--                                    the receipts of the period.
--     all customers (p_customer_uuid null), answer data.summary and data.by_customer[]:
--       by_customer[].total_weight   CHANGED. Was the sum over the customer's receipts of the
--                                    per-bag weights. Now the customer's kg.
--       summary.total_weight_kg      CHANGED. Same, over all receipts of the period.
--     In both branches the totals come from one CTE (grn_items.total_weight, the same text in
--     both), so one replacement, expected twice, changes them all; the entries that follow it
--     only check that the expressions built on top of it are the ones this migration relies on.
--
--   get_all_grn_activity(p_from_date, p_to_date)   (the all-customers report the app calls)
--       summary.total_weight         NOT changed. Already COALESCE(SUM(weight::numeric * qty), 0)
--                                    since the first schema: kg of the received lines.
--       by_customer[].total_weight   NOT changed. Already SUM(weight::numeric * qty). (A customer
--                                    whose lines ALL have a null per-bag weight gets a JSON null
--                                    here, as before: there is no number to add. Left as it is.)
--     Both are guarded below the way migration 58 guards the dispatch summary: a replacement by
--     the same text with an expected count of 1, so the migration fails, and applies nothing,
--     if the function does not hold the expression this comment says it holds.
--
-- Nothing else changes: the authorize_rpc guard first, SECURITY DEFINER, the search_path (and
-- jit setting) and the grants, the India day cut of migration 56, the end-day rule of
-- migration 54, the sort of migration 52, every other key and the order of the receipts and
-- of the customers. Not touched either: get_stock_aging_report adds per-bag weights in the
-- same way (summary.total_weight_kg and the bucket totals); it belongs to the stock reports
-- and is for a decision of its own.
--
-- Method: the current definitions are patched, not rewritten. pg_get_functiondef keeps the
-- guard, SECURITY DEFINER, the search_path, the grants and every other line (including
-- migrations 45, 52, 54 and 56); each replaced text must occur exactly as often as stated, or
-- the migration fails and nothing is applied.

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
BEGIN
  FOR change IN SELECT * FROM (VALUES
    -- The weight of a receipt (single-customer view) and of a customer (all-customers view):
    -- the CTE grn_items adds up the lines of each receipt, twice in this function with the same
    -- text. The bags are now part of the sum.
    ('public.get_customer_grn_activity(uuid,date,date)',
     $b$SUM(grt.weight) as total_weight$b$,
     $a$COALESCE(SUM(grt.weight::numeric * grt.qty), 0) as total_weight$a$, 2),
    -- Guards: the line's own weight stays the per-bag weight, and the figures built on the CTE
    -- still read it (receipt, summary of one customer, customer row, summary of all customers).
    ('public.get_customer_grn_activity(uuid,date,date)',
     $b$'weight', grt.weight,$b$,
     $a$'weight', grt.weight,$a$, 1),
    ('public.get_customer_grn_activity(uuid,date,date)',
     $b$COALESCE(gi.total_weight, 0) as total_weight,$b$,
     $a$COALESCE(gi.total_weight, 0) as total_weight,$a$, 1),
    ('public.get_customer_grn_activity(uuid,date,date)',
     $b$'total_weight_kg', COALESCE(SUM(total_weight), 0),$b$,
     $a$'total_weight_kg', COALESCE(SUM(total_weight), 0),$a$, 1),
    ('public.get_customer_grn_activity(uuid,date,date)',
     $b$COALESCE(SUM(gi.total_weight), 0) as total_weight,$b$,
     $a$COALESCE(SUM(gi.total_weight), 0) as total_weight,$a$, 1),
    ('public.get_customer_grn_activity(uuid,date,date)',
     $b$'total_weight_kg', COALESCE((SELECT SUM(gi.total_weight) FROM grn_data gd LEFT JOIN grn_items gi ON gd.grn_id = gi.gr_id), 0)$b$,
     $a$'total_weight_kg', COALESCE((SELECT SUM(gi.total_weight) FROM grn_data gd LEFT JOIN grn_items gi ON gd.grn_id = gi.gr_id), 0)$a$, 1),
    -- The all-customers report already multiplies: these two entries change nothing and fail
    -- the migration unless both totals are still the sum of qty x per-bag weight (once each).
    ('public.get_all_grn_activity(date,date)',
     $b$'total_weight', COALESCE(SUM(gt.weight::numeric * gt.qty), 0)$b$,
     $a$'total_weight', COALESCE(SUM(gt.weight::numeric * gt.qty), 0)$a$, 1),
    ('public.get_all_grn_activity(date,date)',
     $b$'total_weight', SUM(gt.weight::numeric * gt.qty)$b$,
     $a$'total_weight', SUM(gt.weight::numeric * gt.qty)$a$, 1)
  ) AS changes(signature, before_text, after_text, times)
  LOOP
    EXECUTE pg_temp.replace_marker(change.signature, pg_get_functiondef(change.signature::regprocedure),
      change.before_text, change.after_text, change.times);
  END LOOP;
END;
$migration$;

DROP FUNCTION pg_temp.replace_marker(text, text, text, text, integer);
NOTIFY pgrst, 'reload schema';
