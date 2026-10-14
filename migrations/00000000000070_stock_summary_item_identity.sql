-- The customer stock report lists an item once, whatever names its lots were received under
-- (external review 2026-10-13, EDGE-RENDER-1).
--
-- A receipt line keeps the item name it was saved with, and update_item renames the catalog item
-- only, so after a rename an item has lots under two names. get_customer_stock_summary grouped its
-- rows (items, and out_of_stock_items) by item id AND name, while each row's grns list matched the
-- item id alone: every name got a row listing every lot of the item. With lots of 10 and 20 bags
-- under two names the rows held 60 bags against the summary's 30, and the report PDF, which prints
-- every lot of every row, printed each lot twice.
--
-- The rows are now grouped by item id only and labelled with the name of the item's latest receipt
-- among the row's lots (receipt date, then creation time, then line id; a receipt with no date sorts
-- after every dated one, so it names the row only when no lot has a date). The row keys, their types,
-- the summary (whose total_items already counted item ids), the lots of a row and the order of the
-- rows (by name) are as before; the only differences are one row per item and its name.
--
-- Method: the current definition (as migration 60 leaves it) is patched; each replaced text must occur
-- exactly as often as stated (twice: items and out_of_stock_items). SECURITY DEFINER, the settings,
-- the grants and the owner are checked unchanged.
DO $patch$
DECLARE
  fn CONSTANT regprocedure := 'public.get_customer_stock_summary(uuid)'::regprocedure;
  definition text; step record; occurrences integer;
  before_state jsonb; after_state jsonb;
BEGIN
  SELECT jsonb_build_array(prosecdef, proconfig, proacl::text[], proowner) INTO STRICT before_state FROM pg_proc WHERE oid = fn;
  definition := pg_get_functiondef(fn);
  FOR step IN SELECT * FROM (VALUES
    (1, 2, $m$'item_name', gt.item_name,$m$,
     $r$'item_name', (array_agg(gt.item_name ORDER BY g.date DESC NULLS LAST, g.created_at DESC, gt.id DESC))[1],$r$),
    (2, 2, $m$GROUP BY gt.item_id, gt.item_name  -- Removed packaging from GROUP BY$m$,
     $r$GROUP BY gt.item_id  -- one row per item, named as its latest receipt (migration 70)$r$)
  ) AS s(step_no, expected, marker, replacement) ORDER BY step_no
  LOOP
    occurrences := (length(definition) - length(replace(definition, step.marker, ''))) / length(step.marker);
    IF occurrences <> step.expected THEN
      RAISE EXCEPTION 'Stock summary item identity patch %: expected % marker(s) in get_customer_stock_summary, found %',
        step.step_no, step.expected, occurrences;
    END IF;
    definition := replace(definition, step.marker, step.replacement);
  END LOOP;
  EXECUTE definition;

  SELECT jsonb_build_array(prosecdef, proconfig, proacl::text[], proowner) INTO STRICT after_state FROM pg_proc WHERE oid = fn;
  IF after_state IS DISTINCT FROM before_state THEN
    RAISE EXCEPTION 'get_customer_stock_summary changed its SECURITY DEFINER, settings, grants or owner: % became %', before_state, after_state;
  END IF;
END $patch$;
NOTIFY pgrst, 'reload schema';
