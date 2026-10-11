-- A line can be added to an existing receipt (review, 2026-10-10).
--
-- update_grn inserted a new line with a pricing_mode column that
-- goodsreceived_trl does not have. PL/pgSQL plans the statement on first use,
-- so the function was created without complaint and every edit that added a
-- line failed with "column pricing_mode does not exist", rolling the whole
-- edit back. The pricing mode belongs to the receipt header
-- (goodsreceived.pricing_mode, which this function already updates from
-- p_pricing_mode); a line carries none, exactly as save_grn inserts it.
DO $patch$
DECLARE fn regprocedure; definition text; marker text; replacement text; occurrences integer;
BEGIN
  SELECT p.oid::regprocedure INTO STRICT fn FROM pg_proc p
    WHERE p.pronamespace='public'::regnamespace AND p.proname='update_grn';
  definition := pg_get_functiondef(fn);
  marker := $m$                    gr_id, item_id, item_name, packaging, qty, stock, weight, rack, package_mark, pricing_mode
                ) VALUES ($m$;
  replacement := $r$                    gr_id, item_id, item_name, packaging, qty, stock, weight, rack, package_mark
                ) VALUES ($r$;
  occurrences := (length(definition)-length(replace(definition,marker,'')))/length(marker);
  IF occurrences <> 1 THEN RAISE EXCEPTION 'Expected one new-line column list in update_grn, found %', occurrences; END IF;
  definition := replace(definition,marker,replacement);
  marker := $m$                    COALESCE((v_item->>'weight')::int, 0), v_item->>'rack', v_item->>'package_mark',
                    COALESCE(v_item->>'pricing_mode', 'MONTHLY')::pricing_mode
                ) RETURNING id INTO v_grn_trl_item_id;$m$;
  replacement := $r$                    COALESCE((v_item->>'weight')::int, 0), v_item->>'rack', v_item->>'package_mark'
                ) RETURNING id INTO v_grn_trl_item_id;$r$;
  occurrences := (length(definition)-length(replace(definition,marker,'')))/length(marker);
  IF occurrences <> 1 THEN RAISE EXCEPTION 'Expected one new-line value list in update_grn, found %', occurrences; END IF;
  EXECUTE replace(definition,marker,replacement);
END $patch$;
NOTIFY pgrst, 'reload schema';
