-- Custom document numbers are varchar(8), not necessarily a letter plus digits.
-- Patch only reviewed expressions in the current, already-authorized definitions.
-- pg_get_functiondef preserves the injected authorization guards, SECURITY
-- DEFINER settings and search_path; CREATE OR REPLACE preserves existing grants.
DO $migration$
DECLARE
  change record;
  definition text;
BEGIN
  FOR change IN SELECT * FROM (VALUES
    ('public.get_all_grn_items(timestamptz,timestamptz,jsonb,text,text,integer,integer)',
     $before$COALESCE(CAST(NULLIF(SUBSTRING(gr.gr_no FROM 2), '''') AS INTEGER), 0)$before$,
     $after$CASE WHEN SUBSTRING(gr.gr_no FROM 2) ~ ''^[0-9]+$'' THEN CAST(SUBSTRING(gr.gr_no FROM 2) AS INTEGER) ELSE 0 END$after$),
    ('public.get_all_grn_items(timestamptz,timestamptz,jsonb,text,text,integer,integer)',
     $before$ROW_NUMBER() OVER (ORDER BY %s %s)$before$,
     $after$ROW_NUMBER() OVER (ORDER BY %s %s, gr.gr_no, grt.id)$after$),
    ('public.get_grn_list(date,date,text,text,integer,integer,jsonb)',
     $before$COALESCE(CAST(NULLIF(SUBSTRING(ga.gr_no FROM 2), '''') AS INTEGER), 0)$before$,
     $after$CASE WHEN SUBSTRING(ga.gr_no FROM 2) ~ ''^[0-9]+$'' THEN CAST(SUBSTRING(ga.gr_no FROM 2) AS INTEGER) ELSE 0 END$after$),
    ('public.get_grn_list(date,date,text,text,integer,integer,jsonb)',
     $before$ORDER BY %s
                        LIMIT$before$,
     $after$ORDER BY %s, ga.gr_no, ga.id
                        LIMIT$after$),
    ('public.get_next_grn_number()',
     $before$FROM goodsreceived
    ORDER BY created_at$before$,
     $after$FROM goodsreceived
    WHERE gr_no ~ '^[A-Z][0-9]{1,7}$'
    ORDER BY created_at$after$),
    ('public.get_next_grn_number()',
     $before$WHERE LEFT(gr_no, 1) = v_prefix;$before$,
     $after$WHERE LEFT(gr_no, 1) = v_prefix AND gr_no ~ '^[A-Z][0-9]{1,7}$';$after$),
    ('public.get_next_dispatch_number()',
     $before$FROM dispatch
    ORDER BY disp_no DESC$before$,
     $after$FROM dispatch
    WHERE disp_no ~ '^I[0-9]{1,7}$'
    ORDER BY CAST(SUBSTRING(disp_no FROM 2) AS INTEGER) DESC$after$)
  ) AS changes(signature, before_text, after_text)
  LOOP
    definition := pg_get_functiondef(change.signature::regprocedure);
    IF (length(definition) - length(replace(definition, change.before_text, '')))
       <> length(change.before_text) THEN
      RAISE EXCEPTION 'Unexpected document-number implementation: %', change.signature;
    END IF;
    EXECUTE replace(definition, change.before_text, change.after_text);
  END LOOP;
END;
$migration$;
