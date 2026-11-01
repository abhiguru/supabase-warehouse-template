-- Migration 142: the packaging word of an item's or receipt's lots is read the way the app reads it (review follow-up to migration 141). Additive only: no key
-- is removed or renamed, and null still means "the lots differ".
--   Migration 141 answered null for an item whose lots carry NULL packaging (the column is nullable) and compared the raw text, so an item with no
--   packaging read "units" instead of bags, "Bag" next to "bags" read as different, and "Box" next to a NULL lot read as boxes.
--   warehouse_security.shared_packaging(words) is the one rule: NULL or blank is the default word Bag; words are compared after trim and case
--   folding (tabs, line breaks and no-break spaces count as spaces), exactly as the app does (owner decision D18): Box/Boxes is Box, Crate/Crates is Crate,
--   everything else (Bag, Unit, Sack, Carton, NULL, blank) is Bag; it answers Bag, Box or Crate when every lot agrees, and null when they differ (Box and NULL differ).
--   get_customer_activity_detail:  top_stock_items[].packaging uses the rule (was migration 141's COUNT(DISTINCT)).
--   get_customer_activity_detail:  "packaging" on every row of recent_grns[] (the rule over the receipt's lots) and recent_dispatches[] (the rule over
--                                  the receipt lots the dispatch took from), which the app's GRN and dispatch preview rows print.
--   get_customer_activity_detail:  summary.current_stock_packaging beside summary.current_stock: the rule over every lot the customer still holds
--                                  (the same lots as current_stock), so the head of the report needs no row list. Zero stock reads Bag.
-- Marker-count patches: each before-text is found once and no after-text contains its before-text.

CREATE FUNCTION warehouse_security.shared_packaging(p_words text[]) RETURNS text
    LANGUAGE plpgsql IMMUTABLE
    SET search_path TO 'pg_catalog'
    AS $fn$
DECLARE
  v_word text;
  v_key text;
  v_first_key text;
BEGIN
  IF p_words IS NULL OR cardinality(p_words) = 0 THEN
    RETURN NULL;
  END IF;
  FOREACH v_word IN ARRAY p_words LOOP
    -- As the app reads it (packagingWord): Box/Boxes and Crate/Crates are their own words, everything else, NULL and blank included, is Bag.
    v_key := lower(regexp_replace(COALESCE(v_word, ''), '^([[:space:]]|\u00a0)+|([[:space:]]|\u00a0)+$', '', 'g'));
    IF v_key ~ '^box(es)?$' THEN
      v_key := 'Box';
    ELSIF v_key ~ '^crates?$' THEN
      v_key := 'Crate';
    ELSE
      v_key := 'Bag';
    END IF;
    IF v_first_key IS NULL THEN
      v_first_key := v_key;
    ELSIF v_key <> v_first_key THEN
      RETURN NULL;
    END IF;
  END LOOP;
  RETURN v_first_key;
END
$fn$;

ALTER FUNCTION warehouse_security.shared_packaging(text[]) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION warehouse_security.shared_packaging(text[]) FROM PUBLIC;

-- Migration 141 leaves its pg_temp helper behind; the files of one run share a session.
DROP FUNCTION IF EXISTS pg_temp.patch_function(regprocedure, text[], text[]);
CREATE FUNCTION pg_temp.patch_function(p_function regprocedure, p_old text[], p_new text[]) RETURNS void
    LANGUAGE plpgsql AS $$
DECLARE
  v_def text := pg_get_functiondef(p_function);
  v_count integer;
  i integer;
BEGIN
  IF array_length(p_old, 1) IS DISTINCT FROM array_length(p_new, 1) THEN
    RAISE EXCEPTION '%: the marker list and the replacement list differ in length', p_function;
  END IF;
  FOR i IN 1 .. array_length(p_old, 1) LOOP
    IF position(p_old[i] IN p_new[i]) > 0 THEN
      RAISE EXCEPTION '%: the replacement of marker % contains the marker', p_function, i;
    END IF;
    v_count := (length(v_def) - length(replace(v_def, p_old[i], ''))) / length(p_old[i]);
    IF v_count <> 1 THEN
      RAISE EXCEPTION '%: expected marker % once, found % times', p_function, i, v_count;
    END IF;
    v_def := replace(v_def, p_old[i], p_new[i]);
  END LOOP;
  EXECUTE v_def;
END $$;

SELECT pg_temp.patch_function('public.get_customer_activity_detail(uuid, date, date)'::regprocedure, ARRAY[
$m$CASE WHEN COUNT(DISTINCT grt.packaging) = 1 THEN MIN(grt.packaging::text) END AS packaging,$m$,
$m$'is_invoiced', is_invoiced
        ) ORDER BY grn_date DESC$m$,
$m$as current_stock,
            EXISTS$m$,
$m$'supervisor_name', supervisor_name
        ) ORDER BY dispatch_date DESC$m$,
$m$d.supervisor_name
        FROM dispatch d
        LEFT JOIN dispatch_trl dt ON dt.disp_id = d.id$m$,
$m$SUM(grt.stock) as current_stock,
            --$m$,
$m$'current_stock', COALESCE(cs.current_stock, 0),
        'total_grns'$m$
], ARRAY[
$m$warehouse_security.shared_packaging(array_agg(grt.packaging)) AS packaging,$m$,
$m$'is_invoiced', is_invoiced,
            'packaging', packaging
        ) ORDER BY grn_date DESC$m$,
$m$as current_stock,
            warehouse_security.shared_packaging(array_agg(grt.packaging)) as packaging,
            EXISTS$m$,
$m$'supervisor_name', supervisor_name,
            'packaging', packaging
        ) ORDER BY dispatch_date DESC$m$,
$m$d.supervisor_name,
            warehouse_security.shared_packaging(array_agg(gt.packaging)) as packaging
        FROM dispatch d
        LEFT JOIN dispatch_trl dt ON dt.disp_id = d.id
        LEFT JOIN goodsreceived_trl gt ON gt.id = dt.gr_trl_id$m$,
$m$SUM(grt.stock) as current_stock,
            warehouse_security.shared_packaging(array_agg(grt.packaging)) as current_stock_packaging,
            --$m$,
$m$'current_stock', COALESCE(cs.current_stock, 0),
        'current_stock_packaging', CASE WHEN cs.current_stock IS NULL THEN 'Bag' ELSE cs.current_stock_packaging END,
        'total_grns'$m$
]);

DROP FUNCTION pg_temp.patch_function(regprocedure, text[], text[]);

NOTIFY pgrst, 'reload schema';
