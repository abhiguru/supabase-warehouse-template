-- Quick search on the receipt lists, and receipt number ranges in document order.
--
-- 1. warehouse_security.search_terms turns what a user typed into ILIKE patterns: one per
--    word (at most eight), with %, _ and \ taken literally. Every list search uses it, so
--    "every word must match some column" means the same thing everywhere.
-- 2. get_all_grn_items and get_customer_grn_items accept p_filters.search and match each
--    word against the receipt number, customer, item, package, rack and vehicle number.
-- 3. gr_no_from / gr_no_to compared plain text, so B9..B10 found nothing although the list
--    sorts B9 before B10. They now compare the document number key (migration 31).
CREATE FUNCTION warehouse_security.search_terms(query text) RETURNS text[]
LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
  SELECT COALESCE(array_agg('%' || replace(replace(replace(word, '\', '\\'), '%', '\%'), '_', '\_') || '%'), '{}')
  FROM (SELECT word FROM regexp_split_to_table(btrim(left(COALESCE(query, ''), 120)), '\s+') AS word
        WHERE word <> '' LIMIT 8) words
$$;
REVOKE ALL ON FUNCTION warehouse_security.search_terms(text) FROM PUBLIC, anon, authenticated;

DO $migration$
DECLARE
  change record;
  definition text;
  key constant text := 'warehouse_security.document_number_sort_key';
BEGIN
  FOR change IN SELECT * FROM (VALUES
    -- Staff list: ranges by document key.
    ('public.get_all_grn_items(timestamptz,timestamptz,jsonb,text,text,integer,integer)',
     $b$format('gr.gr_no BETWEEN %L AND %L', v_grn_no_from, v_grn_no_to)$b$,
     format($a$format('(%1$s(gr.gr_no) COLLATE "C") BETWEEN (%1$s(%%L) COLLATE "C") AND (%1$s(%%L) COLLATE "C")', v_grn_no_from, v_grn_no_to)$a$, key)),
    ('public.get_all_grn_items(timestamptz,timestamptz,jsonb,text,text,integer,integer)',
     $b$format('gr.gr_no >= %L', v_grn_no_from)$b$,
     format($a$format('(%1$s(gr.gr_no) COLLATE "C") >= (%1$s(%%L) COLLATE "C")', v_grn_no_from)$a$, key)),
    ('public.get_all_grn_items(timestamptz,timestamptz,jsonb,text,text,integer,integer)',
     $b$format('gr.gr_no <= %L', v_grn_no_to)$b$,
     format($a$format('(%1$s(gr.gr_no) COLLATE "C") <= (%1$s(%%L) COLLATE "C")', v_grn_no_to)$a$, key)),
    -- Staff list: search, added as one more condition before the query is built.
    ('public.get_all_grn_items(timestamptz,timestamptz,jsonb,text,text,integer,integer)',
     $b$    -- Build and execute main query$b$,
     $a$    -- Quick search: every word must match some column of the receipt line
    IF btrim(COALESCE(p_filters->>'search', '')) <> '' THEN
        v_where_conditions := array_append(v_where_conditions, format(
            'NOT EXISTS (SELECT 1 FROM unnest(%L::text[]) AS term WHERE NOT (gr.gr_no ILIKE term OR COALESCE(gr.customer_name, '''') ILIKE term OR COALESCE(grt.item_name, '''') ILIKE term OR COALESCE(grt.package_mark, '''') ILIKE term OR COALESCE(grt.rack, '''') ILIKE term OR COALESCE(gr.registration, '''') ILIKE term))',
            warehouse_security.search_terms(p_filters->>'search')));
    END IF;

    -- Build and execute main query$a$),
    -- Customer list: ranges by document key, and search.
    ('public.get_customer_grn_items(uuid,timestamptz,timestamptz,jsonb,text,text,integer,integer)',
     $b$OR gr.gr_no >= v_filters->>'gr_no_from')$b$,
     format($a$OR (%1$s(gr.gr_no) COLLATE "C") >= (%1$s(v_filters->>'gr_no_from') COLLATE "C"))$a$, key)),
    ('public.get_customer_grn_items(uuid,timestamptz,timestamptz,jsonb,text,text,integer,integer)',
     $b$OR gr.gr_no <= v_filters->>'gr_no_to')$b$,
     format($a$OR (%1$s(gr.gr_no) COLLATE "C") <= (%1$s(v_filters->>'gr_no_to') COLLATE "C"))
      AND NOT EXISTS (SELECT 1 FROM unnest(warehouse_security.search_terms(v_filters->>'search')) AS term
        WHERE NOT (gr.gr_no ILIKE term OR COALESCE(gr.customer_name, '') ILIKE term OR COALESCE(grt.item_name, '') ILIKE term
          OR COALESCE(grt.package_mark, '') ILIKE term OR COALESCE(grt.rack, '') ILIKE term OR COALESCE(gr.registration, '') ILIKE term))$a$, key))
  ) AS changes(signature, before_text, after_text)
  LOOP
    definition := pg_get_functiondef(change.signature::regprocedure);
    IF (length(definition) - length(replace(definition, change.before_text, ''))) <> length(change.before_text) THEN
      RAISE EXCEPTION 'Unexpected text in %: %', change.signature, change.before_text;
    END IF;
    EXECUTE replace(definition, change.before_text, change.after_text);
  END LOOP;
END;
$migration$;
