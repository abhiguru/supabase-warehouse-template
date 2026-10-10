-- The dispatch list sorts by number with the key from migration 31.
--
-- It sorted by "first letter * 100000 + every digit in the number", which
--   * raised an error for numbers with more than nine digits in total and let unlike numbers
--     collide (D-1 and D1, I100000 and J0);
--   * had no fixed order for equal values, so paging could repeat or skip a dispatch;
--   * always put same-day dispatches highest number first, even when the list was oldest first.
-- One-letter prefixes keep their order; CLR numbers, which ranked just after I, now come after
-- the one-letter prefixes with every other longer prefix. Same-day dispatches follow the
-- requested direction, and the customer-name and default orders end in the key, so every
-- order is total.
DO $migration$
DECLARE
  signature constant text := 'public.get_dispatch_list_with_items(uuid,jsonb,text,text,integer,integer,boolean)';
  definition text := pg_get_functiondef(signature::regprocedure);
  key constant text := '(warehouse_security.document_number_sort_key(disp_no) COLLATE "C")';
  old_rule constant text := $re$\(CASE WHEN SUBSTRING\(disp_no FROM 1 FOR 3\) = ''CLR''.*?, 0\)\)$re$;
  change record;
BEGIN
  IF (SELECT count(*) FROM regexp_matches(definition, old_rule, 'g')) <> 3 THEN
    RAISE EXCEPTION 'Unexpected dispatch-number sort in %', signature;
  END IF;
  definition := regexp_replace(definition, old_rule, key, 'g');
  FOR change IN SELECT * FROM (VALUES
    -- Same-day dispatches follow the requested direction.
    (''' NULLS LAST, ' || key || ' DESC NULLS LAST''',
     ''' NULLS LAST, ' || key || ' '' || CASE WHEN LOWER(p_sort_order) = ''asc'' THEN ''ASC'' ELSE ''DESC'' END'),
    -- Customer-name and default orders end in the key.
    (''' NULLS LAST, disp_date DESC NULLS LAST''',
     ''' NULLS LAST, disp_date DESC NULLS LAST, ' || key || ' DESC'''),
    ('''disp_date DESC NULLS LAST''
        END;',
     '''disp_date DESC NULLS LAST, ' || key || ' DESC''
        END;')
  ) AS changes(before_text, after_text)
  LOOP
    IF (length(definition) - length(replace(definition, change.before_text, ''))) <> length(change.before_text) THEN
      RAISE EXCEPTION 'Unexpected dispatch order clause in %: %', signature, change.before_text;
    END IF;
    definition := replace(definition, change.before_text, change.after_text);
  END LOOP;
  IF definition LIKE '%* 100000%' THEN RAISE EXCEPTION 'Dispatch-number sort not replaced'; END IF;
  EXECUTE definition;
END;
$migration$;
