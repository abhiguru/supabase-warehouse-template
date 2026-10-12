-- The customer dispatch activity report returns each dispatch's id.
--
-- public.get_customer_dispatch_activity(p_customer_uuid, p_from_date, p_to_date) answers with
-- a summary and a list, dispatches[], one object per dispatch with disp_no, disp_date,
-- supervisor_name, total_qty and items. It never said WHICH dispatch an object is: the
-- dispatch's id (public.dispatch.id, a uuid) was not in it. The app's dispatch activity report
-- (app/reports/dispatch-activity.tsx, mapped in
-- src/services/reporting/dispatch-activity-service.ts as disp_id: disp.disp_id) shows an
-- "Open dispatch" control on a dispatch only when disp_id is present, and opens
-- /dispatch-details/<disp_id>. That screen calls get_dispatch_details(p_dispatch_id) with the
-- dispatch's id, so the value to return is exactly public.dispatch.id. Because the field was
-- missing, the control never appeared.
--
-- This migration adds 'disp_id', d.id as the first key written of each dispatch object.
-- (jsonb sorts the keys of an object itself, so "first" is only the place in the function text;
-- a client reads the key by name.) Nothing else in the answer changes: the other keys, their
-- values, the summary, the ordering, and the IST day cut of migration 56 are as they were.
--
-- No new exposure. The id is only ever that of a dispatch the caller is already given: the
-- function runs warehouse_security.authorize_rpc first (a customer account is refused another
-- customer's id there), then returns that customer's own, not deleted, dispatches for the
-- period. get_dispatch_details checks the customer again when the app opens the dispatch. The
-- guard, SECURITY DEFINER, the search_path and the grants are not touched.
--
-- Method: the current definition is patched, not rewritten. pg_get_functiondef keeps the
-- authorize_rpc guard, SECURITY DEFINER, the search_path, the grants and every other line
-- (including migrations 45, 54 and 56); the replaced text must occur exactly once, or the
-- migration fails and nothing is applied.

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
    -- The dispatch object of the list: disp_no is its first key and occurs nowhere else.
    ('public.get_customer_dispatch_activity(uuid,date,date)',
     $b$'disp_no', d.disp_no,$b$,
     $a$'disp_id', d.id,
                    'disp_no', d.disp_no,$a$, 1)
  ) AS changes(signature, before_text, after_text, times)
  LOOP
    EXECUTE pg_temp.replace_marker(change.signature, pg_get_functiondef(change.signature::regprocedure),
      change.before_text, change.after_text, change.times);
  END LOOP;
END;
$migration$;

DROP FUNCTION pg_temp.replace_marker(text, text, text, text, integer);
NOTIFY pgrst, 'reload schema';
