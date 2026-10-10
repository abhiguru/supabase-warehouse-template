-- The dispatch list's date filter compared whole days in the database's time zone:
-- date_to stopped at the start of its day there, so a list "up to 7 Oct" asked from
-- India lost most of 7 Oct. date_from and date_to are now read as moments in time, so
-- the app can send the start and end of the user's own day. A plain date still works
-- and means the start of that day, as before.
DO $migration$
DECLARE
  change record;
  definition text;
  signature constant text := 'public.get_dispatch_list_with_items(uuid,jsonb,text,text,integer,integer,boolean)';
BEGIN
  FOR change IN SELECT * FROM (VALUES
    ($b$format(' AND d.disp_date >= %L::date', p_filters->>'date_from')$b$,
     $a$format(' AND d.disp_date >= %L::timestamptz', p_filters->>'date_from')$a$),
    ($b$format(' AND d.disp_date <= %L::date', p_filters->>'date_to')$b$,
     $a$format(' AND d.disp_date <= %L::timestamptz', p_filters->>'date_to')$a$)
  ) AS changes(before_text, after_text)
  LOOP
    definition := pg_get_functiondef(signature::regprocedure);
    IF (length(definition) - length(replace(definition, change.before_text, ''))) <> length(change.before_text) THEN
      RAISE EXCEPTION 'Unexpected text in %: %', signature, change.before_text;
    END IF;
    EXECUTE replace(definition, change.before_text, change.after_text);
  END LOOP;
END;
$migration$;
