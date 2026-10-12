-- The receipt list includes the last day of its date filter.
--
-- get_grn_list takes the filter as two calendar days, p_date_from and p_date_to (type date),
-- and builds its WHERE clause as text. The end day was added as
--   format('gr.date <= %L', p_date_to)
-- which becomes `gr.date <= '2026-10-09'`. The column goodsreceived.date is a timestamptz, and
-- a bare date compared with it is read as midnight at the START of that day, so every receipt
-- on the last day of the filter was left out (except one stored exactly at midnight). Migration
-- 54 fixed the same fault in four report functions; this is the receipt list.
--
-- The end of the filter is now `gr.date < '<p_date_to + 1>'`: before the start of the day
-- after the last day, so the whole last day is in. It is the same set of rows as
-- `gr.date::date <= p_date_to`, but it compares the column itself, so the index on
-- goodsreceived.date stays usable (the form migration 54 chose). The start of the filter
-- (`gr.date >= p_date_from`) was already right and is not changed.
--
-- Time zone: not changed here. A day in this filter is a day in the database session's time
-- zone, which is UTC on this image, not in India (the same open question as migration 54).
--
-- Only that one expression of the current definition is replaced, so the authorization guard,
-- SECURITY DEFINER, search_path, the grants and every other line (including the migration 8
-- and 31 ordering) stay exactly as they are. The marker must occur exactly once, or the
-- migration fails.

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
    -- One end-day filter, added only when p_date_to is given.
    ('public.get_grn_list(date,date,text,text,integer,integer,jsonb)',
     $b$format('gr.date <= %L', p_date_to)$b$, $a$format('gr.date < %L', p_date_to + 1)$a$, 1)
  ) AS changes(signature, before_text, after_text, times)
  LOOP
    EXECUTE pg_temp.replace_marker(change.signature, pg_get_functiondef(change.signature::regprocedure),
      change.before_text, change.after_text, change.times);
  END LOOP;
END;
$migration$;

DROP FUNCTION pg_temp.replace_marker(text, text, text, text, integer);
NOTIFY pgrst, 'reload schema';
