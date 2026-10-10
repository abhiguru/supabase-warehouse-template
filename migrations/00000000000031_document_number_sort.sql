-- Sort receipts by number for every number the system accepts.
--
-- gr_no is varchar(8) and need not be a letter plus digits (migration 8). The list functions
-- sorted by "letter rank * 10000 + digits", which
--   * treated every other form (two-letter prefixes, digits only, separators) as number 0, so
--     those receipts came back in ascending text order whichever direction was asked for;
--   * let five-digit numbers collide with the next letter (A10000 = B0000).
-- A single text key now defines the order, compared bytewise:
--   1. prefix rank: one letter A-Z keeps the existing rule (X, Y, Z before A, then B ...),
--      upper and lower case together; every other prefix ranks after them;
--   2. the prefix itself (everything before the trailing digits);
--   3. the trailing digits as a number of any length;
--   4. the number as written, so C1, C01 and C001 have a fixed order.
CREATE FUNCTION warehouse_security.document_number_sort_key(doc_no text) RETURNS text
LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
  SELECT to_char(
           CASE WHEN p.up COLLATE "C" ~ '^[A-Z]$'
                THEN CASE WHEN p.up COLLATE "C" >= 'X' THEN ascii(p.up) - ascii('X') ELSE ascii(p.up) - ascii('A') + 3 END
                ELSE 100 END, 'FM000')
         || chr(1) || p.prefix || chr(1) || lpad(p.digits, 20, '0') || chr(1) || p.whole
  FROM (SELECT COALESCE(doc_no, '') AS whole,
               regexp_replace(COALESCE(doc_no, ''), '[0-9]+$', '') AS prefix,
               upper(regexp_replace(COALESCE(doc_no, ''), '[0-9]+$', '')) AS up,
               COALESCE(substring(COALESCE(doc_no, '') FROM '[0-9]+$'), '') AS digits) p
$$;
REVOKE ALL ON FUNCTION warehouse_security.document_number_sort_key(text) FROM PUBLIC, anon, authenticated;

-- Patch only the reviewed sort expression in the current, already-authorized definitions.
-- pg_get_functiondef keeps the authorization guards, SECURITY DEFINER settings and
-- search_path; CREATE OR REPLACE keeps the grants.
DO $migration$
DECLARE
  change record;
  definition text;
  patched text;
BEGIN
  FOR change IN SELECT * FROM (VALUES
    ('public.get_all_grn_items(timestamptz,timestamptz,jsonb,text,text,integer,integer)',
     $re$'\(CASE WHEN SUBSTRING\(gr\.gr_no FROM 1 FOR 1\).*?ELSE 0 END\)'$re$,
     $new$'(warehouse_security.document_number_sort_key(gr.gr_no) COLLATE "C")'$new$),
    ('public.get_grn_list(date,date,text,text,integer,integer,jsonb)',
     $re$'\(CASE WHEN SUBSTRING\(ga\.gr_no FROM 1 FOR 1\).*?ELSE 0 END\) %s'$re$,
     $new$'(warehouse_security.document_number_sort_key(ga.gr_no) COLLATE "C") %s'$new$)
  ) AS changes(signature, pattern, replacement)
  LOOP
    definition := pg_get_functiondef(change.signature::regprocedure);
    IF (SELECT count(*) FROM regexp_matches(definition, change.pattern, 'g')) <> 1 THEN
      RAISE EXCEPTION 'Unexpected document-number sort in %', change.signature;
    END IF;
    patched := regexp_replace(definition, change.pattern, change.replacement);
    IF patched LIKE '%* 10000%' OR patched NOT LIKE '%document_number_sort_key%' THEN
      RAISE EXCEPTION 'Document-number sort not replaced in %', change.signature;
    END IF;
    EXECUTE patched;
  END LOOP;
END;
$migration$;
