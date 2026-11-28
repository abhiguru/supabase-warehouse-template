-- Refusal codes for offline sends (WH-161, offline work step 5): topic "refusal codes for offline sends". Named by topic; its number is taken
-- when the work is assembled for main. Contract: product/tech/app-offline-new-records.md section 2.4, cases B3, B10, C1 to C5 of
-- tests/offline_refusal_codes_161.sql.
--
-- Every refusal an offline send can meet answers success false with a reason and the figures the phone prints, online and offline alike,
-- with today's text beside the code:
--   GRN number taken        NUMBER_TAKEN + number (the dispatch had it)
--   stock short             STOCK_SHORT + lines [{lot_id, item_name, available, requested}], only the short lots; error keeps "Insufficient stock: ..."
--   customer inactive       CUSTOMER_INACTIVE: save_grn answers it instead of raising P0001, with today's words (the dispatch is not changed)
--   a lot removed meanwhile LOT_NOT_FOUND + lot_ids
-- The other codes (the dates, the numbers, the rates, POSSIBLE_DUPLICATE) are unchanged. The refusals are written in the two definition files
-- (save_grn.sql, create_dispatch_with_stock_check_internal.sql); this file adds the helper that names the short lots and lets the
-- dispatch wrapper answer LOT_NOT_FOUND for a lot that is no longer there (its item validation refused it as "Invalid dispatch items").

CREATE FUNCTION warehouse_security.stock_short_lines(p_items jsonb[]) RETURNS jsonb
  LANGUAGE sql STABLE SET search_path TO 'pg_catalog', 'public', 'pg_temp'
AS $$
  SELECT COALESCE(jsonb_agg(jsonb_build_object('lot_id', gt.id, 'item_name', gt.item_name, 'available', gt.stock,
                                               'requested', (t.item->>'disp_qty')::integer) ORDER BY t.ord), '[]'::jsonb)
    FROM unnest(p_items) WITH ORDINALITY AS t(item, ord)
    JOIN goodsreceived_trl gt ON gt.id = (t.item->>'gr_trl_id')::uuid
   WHERE gt.stock < (t.item->>'disp_qty')::integer
$$;
ALTER FUNCTION warehouse_security.stock_short_lines(jsonb[]) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION warehouse_security.stock_short_lines(jsonb[]) FROM PUBLIC, anon, authenticated, service_role;

DO $patch$
DECLARE
  v_def text;
  v_old constant text[] := ARRAY[
    $m$    v_validation_result := validate_dispatch_items(p_dispatch_items);
$m$
  ];
  v_new constant text[] := ARRAY[
    $m$    v_validation_result := validate_dispatch_items(p_dispatch_items);

    -- WH-161: a lot that is gone is LOT_NOT_FOUND (today's words in error), not a validation error.
    IF NOT (v_validation_result->>'valid')::BOOLEAN AND EXISTS (
        SELECT 1 FROM unnest(p_dispatch_items) AS item
        WHERE NOT EXISTS (SELECT 1 FROM goodsreceived_trl gt WHERE gt.id::text = item->>'gr_trl_id')
    ) THEN
        RETURN warehouse_security.refuse('LOT_NOT_FOUND', 'A lot of this dispatch was removed meanwhile; reload and try again',
            jsonb_build_object('lot_ids', to_jsonb(ARRAY(
                SELECT item->>'gr_trl_id' FROM unnest(p_dispatch_items) AS item
                WHERE NOT EXISTS (SELECT 1 FROM goodsreceived_trl gt WHERE gt.id::text = item->>'gr_trl_id')))));
    END IF;
$m$
  ];
  v_count integer;
  i integer;
BEGIN
  v_def := pg_get_functiondef('public.create_dispatch_with_stock_check(jsonb, jsonb[], boolean, integer, text)'::regprocedure);
  FOR i IN 1 .. array_length(v_old, 1) LOOP
    v_count := (length(v_def) - length(replace(v_def, v_old[i], ''))) / length(v_old[i]);
    IF v_count <> 1 THEN
      RAISE EXCEPTION 'create_dispatch_with_stock_check: expected marker % once, found % times', i, v_count;
    END IF;
    v_def := replace(v_def, v_old[i], v_new[i]);
  END LOOP;
  EXECUTE v_def;
END
$patch$;

NOTIFY pgrst, 'reload schema';
