-- Quick search on the dispatch, invoice and order lists, and the filters those lists
-- showed but never applied.
--
-- 1. get_dispatch_list_with_items accepts p_filters.search (every word must match the
--    dispatch number, customer or vehicle number, or the item, package, rack or receipt
--    number of one of its lines) and p_filters.package_mark. disp_no_from / disp_no_to
--    compared plain text; they now compare the document number key (migration 31).
-- 2. get_invoices_list gains p_search (invoice number, also written 2026-12 or 2026-0012,
--    customer, receipt number), p_date_from, p_date_to and p_customer_ids.
-- 3. get_orders_list gains p_search (customer name or city, or the item, package or
--    receipt number of a pending line).
--
-- New parameters have defaults, so existing callers are unaffected. A function with a
-- longer parameter list is a different function, so the old one is dropped in the same
-- step; otherwise the API would see two candidates for one call.
DO $migration$
DECLARE
  change record;
  definition text;
  key constant text := 'warehouse_security.document_number_sort_key';
  dispatch constant text := 'public.get_dispatch_list_with_items(uuid,jsonb,text,text,integer,integer,boolean)';
BEGIN
  FOR change IN SELECT * FROM (VALUES
    (dispatch,
     $b$format(' AND d.disp_no BETWEEN %L AND %L', v_disp_no_from, v_disp_no_to)$b$,
     format($a$format(' AND (%1$s(d.disp_no) COLLATE "C") BETWEEN (%1$s(%%L) COLLATE "C") AND (%1$s(%%L) COLLATE "C")', v_disp_no_from, v_disp_no_to)$a$, key)),
    (dispatch,
     $b$format(' AND d.disp_no >= %L', v_disp_no_from)$b$,
     format($a$format(' AND (%1$s(d.disp_no) COLLATE "C") >= (%1$s(%%L) COLLATE "C")', v_disp_no_from)$a$, key)),
    (dispatch,
     $b$format(' AND d.disp_no <= %L', v_disp_no_to)$b$,
     format($a$format(' AND (%1$s(d.disp_no) COLLATE "C") <= (%1$s(%%L) COLLATE "C")', v_disp_no_to)$a$, key)),
    -- Package and search join the other line conditions, which are already part of the query.
    (dispatch,
     $b$    -- Check if disp_no filter is present$b$,
     $a$    -- Package: every word must be in the package of one line
    IF btrim(COALESCE(p_filters->>'package_mark', '')) <> '' THEN
        v_item_ids_filter := v_item_ids_filter || format(
            ' AND EXISTS (SELECT 1 FROM dispatch_trl dt_pkg JOIN goodsreceived_trl grt_pkg ON dt_pkg.gr_trl_id = grt_pkg.id WHERE dt_pkg.disp_id = d.id AND NOT EXISTS (SELECT 1 FROM unnest(%L::text[]) AS term WHERE NOT COALESCE(grt_pkg.package_mark, '''') ILIKE term))',
            warehouse_security.search_terms(p_filters->>'package_mark'));
    END IF;

    -- Quick search: every word must match the dispatch or one of its lines
    IF btrim(COALESCE(p_filters->>'search', '')) <> '' THEN
        v_item_ids_filter := v_item_ids_filter || format(
            ' AND NOT EXISTS (SELECT 1 FROM unnest(%L::text[]) AS term WHERE NOT (d.disp_no ILIKE term OR COALESCE(d.customer_name, '''') ILIKE term OR COALESCE(d.registration, '''') ILIKE term OR EXISTS (SELECT 1 FROM dispatch_trl dt_s JOIN goodsreceived_trl grt_s ON dt_s.gr_trl_id = grt_s.id JOIN goodsreceived gr_s ON grt_s.gr_id = gr_s.id WHERE dt_s.disp_id = d.id AND (COALESCE(grt_s.item_name, '''') ILIKE term OR COALESCE(grt_s.package_mark, '''') ILIKE term OR COALESCE(grt_s.rack, '''') ILIKE term OR gr_s.gr_no ILIKE term))))',
            warehouse_security.search_terms(p_filters->>'search'));
    END IF;

    -- Check if disp_no filter is present$a$)
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

DO $migration$
DECLARE
  change record;
  definition text;
  step record;
BEGIN
  FOR change IN SELECT * FROM (VALUES
    ('public.get_invoices_list(integer,integer,uuid,integer,text,text,text,text,integer,integer)',
     'public.get_invoices_list(integer,integer,uuid,integer,text,text,text,text,integer,integer,text,timestamptz,timestamptz,uuid[])',
     ARRAY[
       -- The parameter list (once).
       'p_inv_no_to integer DEFAULT NULL::integer)',
       'p_inv_no_to integer DEFAULT NULL::integer, p_search text DEFAULT NULL::text, p_date_from timestamp with time zone DEFAULT NULL::timestamp with time zone, p_date_to timestamp with time zone DEFAULT NULL::timestamp with time zone, p_customer_ids uuid[] DEFAULT NULL::uuid[])',
       '1',
       -- The conditions, in the count and in the page (twice).
       'AND (p_inv_no_to IS NULL OR m.inv_no <= p_inv_no_to)',
       $a$AND (p_inv_no_to IS NULL OR m.inv_no <= p_inv_no_to)
        AND (p_date_from IS NULL OR m.inv_date >= p_date_from)
        AND (p_date_to IS NULL OR m.inv_date <= p_date_to)
        AND (p_customer_ids IS NULL OR cardinality(p_customer_ids) = 0 OR m.customer_id = ANY(p_customer_ids))
        AND NOT EXISTS (SELECT 1 FROM unnest(warehouse_security.search_terms(p_search)) AS term
          WHERE NOT (m.inv_no::text ILIKE term OR COALESCE(m.customer_name, '') ILIKE term OR COALESCE(m.gr_no, '') ILIKE term
            OR (m.inv_fin_year::text || '-' || m.inv_no::text) ILIKE term
            OR (m.inv_fin_year::text || '-' || lpad(m.inv_no::text, 4, '0')) ILIKE term))$a$,
       '2']),
    ('public.get_orders_list(uuid,text,boolean,uuid,integer,integer)',
     'public.get_orders_list(uuid,text,boolean,uuid,integer,integer,text)',
     ARRAY[
       'p_offset integer DEFAULT 0)',
       'p_offset integer DEFAULT 0, p_search text DEFAULT NULL::text)',
       '1',
       $b$AND (p_customer_name IS NULL OR m.customer_name_detail ILIKE '%' || p_customer_name || '%')$b$,
       $a$AND (p_customer_name IS NULL OR m.customer_name_detail ILIKE '%' || p_customer_name || '%')
          AND NOT EXISTS (SELECT 1 FROM unnest(warehouse_security.search_terms(p_search)) AS term
            WHERE NOT (COALESCE(m.customer_name_detail, '') ILIKE term OR COALESCE(m.customer_city, '') ILIKE term
              OR EXISTS (SELECT 1 FROM jsonb_array_elements(m.items_jsonb) AS line
                WHERE line->>'item_status' = 'pending'
                  AND (COALESCE(line->>'grn_items_item_name', '') ILIKE term OR COALESCE(line->>'grn_items_package_mark', '') ILIKE term
                    OR COALESCE(line->>'grns_gr_no', '') ILIKE term))))$a$,
       '2'])
  ) AS changes(old_signature, new_signature, steps)
  LOOP
    definition := pg_get_functiondef(change.old_signature::regprocedure);
    FOR step IN
      SELECT change.steps[i] AS before_text, change.steps[i + 1] AS after_text, change.steps[i + 2]::integer AS times
      FROM generate_series(1, cardinality(change.steps), 3) AS i
    LOOP
      IF (length(definition) - length(replace(definition, step.before_text, ''))) <> length(step.before_text) * step.times THEN
        RAISE EXCEPTION 'Unexpected text in %: %', change.old_signature, step.before_text;
      END IF;
      definition := replace(definition, step.before_text, step.after_text);
    END LOOP;
    EXECUTE format('DROP FUNCTION %s', change.old_signature::regprocedure);
    EXECUTE definition;
    -- A new function starts with the default grants: give it the ones the old function had.
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC, anon', change.new_signature::regprocedure);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO authenticated, service_role', change.new_signature::regprocedure);
  END LOOP;
END;
$migration$;
