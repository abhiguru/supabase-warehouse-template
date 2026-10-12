-- The customer dispatch activity report returns the weight of each dispatch and of each line.
--
-- public.get_customer_dispatch_activity(p_customer_uuid, p_from_date, p_to_date) answers with a
-- summary and a list, dispatches[], one object per dispatch with disp_id, disp_no, disp_date,
-- supervisor_name, total_qty and items[]; each item has item_name, qty, source_grn,
-- source_grn_id, orig_qty, package_mark and rack. It gave the weight only once, for the whole
-- period (summary.total_weight): not per dispatch, not per line. The app's dispatch activity
-- report (src/services/reporting/dispatch-activity-service.ts) reads total_weight on a dispatch
-- and weight on an item and defaults each to 0, so it could show neither.
--
-- Where a weight comes from: public.goodsreceived_trl.weight, an integer, nullable, kg PER BAG
-- (per unit of qty) as the receipt line was typed in. A received line that holds 100 bags of
-- 50 kg stores 50, not 5000. Stock figures multiply it by the bags (get_customer_stock_summary
-- and get_all_stock_summary: weight x stock; get_dispatch_list_with_items: disp_qty x weight).
-- get_customer_grn_activity adds the per-bag weights of a receipt WITHOUT the bags; that is not
-- what is wanted for a dispatch.
--
-- This migration adds two keys to the dispatch objects and keeps the summary as it is:
--
--   items[].weight    kg of that line: the dispatched quantity of the line (dispatch_trl.disp_qty)
--                     times the per-bag weight of the received line it was taken from
--                     (goodsreceived_trl.weight). 0 when the per-bag weight (or the quantity) is
--                     null. A number, e.g. 5 bags of 50 kg -> 250.
--   total_weight      kg of the dispatch: the sum of the weight of its items. 0 for a dispatch
--                     without lines. Computed over the same lines the items list is.
--   summary.total_weight (already returned, NOT changed): the sum, over the same not-deleted
--                     dispatches of the customer in the period, of disp_qty x per-bag weight,
--                     in kg. That is exactly the sum of the returned dispatches' total_weight.
--                     It was not wrong, it was the only weight there was; a null per-bag weight
--                     counts as 0 in it too (SUM ignores the null product). The migration checks
--                     that this expression is still there (once) and fails if it is not, so the
--                     equality cannot drift unnoticed.
--
-- Nothing else changes: the authorize_rpc guard, SECURITY DEFINER, the search_path and the
-- grants, the India day cut of migration 56, disp_id of migration 57, the other keys and their
-- values, and the order of the dispatches and of the lines. get_all_dispatch_activity (the
-- all-customers report) returns no weight at all and is not touched.
--
-- Method: the current definition is patched, not rewritten. pg_get_functiondef keeps the guard,
-- SECURITY DEFINER, the search_path, the grants and every other line (including migrations 45,
-- 54, 56 and 57); each replaced text must occur exactly as often as stated, or the migration
-- fails and nothing is applied.

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
    -- A line of the list: rack is its last key and occurs nowhere else (gt.rack is read once).
    ('public.get_customer_dispatch_activity(uuid,date,date)',
     $b$'rack', gt.rack$b$,
     $a$'rack', gt.rack,
                                'weight', COALESCE(gt.weight::numeric * dt.disp_qty, 0)$a$, 1),
    -- The dispatch object: 'items' opens the list of lines and occurs once. The sum runs over
    -- the very lines (and joins) the list below it is built from.
    ('public.get_customer_dispatch_activity(uuid,date,date)',
     $b$'items', ($b$,
     $a$'total_weight', (
                        SELECT COALESCE(SUM(gt3.weight::numeric * dt3.disp_qty), 0)
                        FROM dispatch_trl dt3
                        JOIN goodsreceived_trl gt3 ON gt3.id = dt3.gr_trl_id
                        JOIN goodsreceived g3 ON g3.id = dt3.gr_id
                        WHERE dt3.disp_id = d.id
                    ),
                    'items', ($a$, 1),
    -- The summary stays: this entry changes nothing, it only fails the migration unless the
    -- summary's total is still the sum of disp_qty x per-bag weight (once, in this function).
    ('public.get_customer_dispatch_activity(uuid,date,date)',
     $b$'total_weight', COALESCE(SUM(gt.weight::numeric * dt.disp_qty), 0)$b$,
     $a$'total_weight', COALESCE(SUM(gt.weight::numeric * dt.disp_qty), 0)$a$, 1)
  ) AS changes(signature, before_text, after_text, times)
  LOOP
    EXECUTE pg_temp.replace_marker(change.signature, pg_get_functiondef(change.signature::regprocedure),
      change.before_text, change.after_text, change.times);
  END LOOP;
END;
$migration$;

DROP FUNCTION pg_temp.replace_marker(text, text, text, text, integer);
NOTIFY pgrst, 'reload schema';
