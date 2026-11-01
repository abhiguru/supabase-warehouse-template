-- Migration 141: the packaging word on the lines the app prints (owner decision D18, "packaging word everywhere"). Additive only: no existing key
-- changes, no value changes, no new function. The source is the same column the GRN and dispatch RPCs already expose, goodsreceived_trl.packaging.
--   build_invoice_form_lines (and so generate_invoice_data_for_grn_with_pricing, whose "items" it returns):  "grn_items_packaging" on every line.
--   get_customer_dispatch_activity:  "packaging" on every row of dispatches[].items[].
--   get_customer_activity_detail:    "packaging" on every row of top_stock_items[] (the packaging of the item's lots, or null when the lots differ).
-- get_invoice_detail (definition file) answers "packaging" on its items. get_invoice_data and get_customer_grn_activity already carried it.
-- The all-customers activity reports (get_all_customer_activity_summary, get_all_dispatch_activity, get_all_grn_activity) list customers, not items.
-- Marker-count patches: each before-text is found once and no after-text contains its before-text.

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

SELECT pg_temp.patch_function('public.build_invoice_form_lines(uuid, text)'::regprocedure, ARRAY[
$m$SELECT grt.id AS grn_items_id, grt.item_id, grt.item_name, grt.qty,$m$,
$m$'grn_items_item_name', l.item_name,
                   'grn_items_original_qty', l.qty,$m$
], ARRAY[
$m$SELECT grt.id AS grn_items_id, grt.item_id, grt.item_name, grt.packaging, grt.qty,$m$,
$m$'grn_items_item_name', l.item_name,
                   'grn_items_packaging', l.packaging,
                   'grn_items_original_qty', l.qty,$m$
]);

SELECT pg_temp.patch_function('public.get_customer_dispatch_activity(uuid, date, date)'::regprocedure, ARRAY[
$m$                                'weight', COALESCE(gt.weight::numeric * dt.disp_qty, 0)
                            ) ORDER BY gt.item_name$m$
], ARRAY[
$m$                                'weight', COALESCE(gt.weight::numeric * dt.disp_qty, 0),
                                'packaging', gt.packaging
                            ) ORDER BY gt.item_name$m$
]);

SELECT pg_temp.patch_function('public.get_customer_activity_detail(uuid, date, date)'::regprocedure, ARRAY[
$m$            'item_name', item_name,
            'total_stock', total_stock,$m$,
$m$            grt.item_name,
            SUM(grt.stock) as total_stock,$m$
], ARRAY[
$m$            'item_name', item_name,
            'packaging', packaging,
            'total_stock', total_stock,$m$,
$m$            grt.item_name,
            CASE WHEN COUNT(DISTINCT grt.packaging) = 1 THEN MIN(grt.packaging::text) END AS packaging,
            SUM(grt.stock) as total_stock,$m$
]);

NOTIFY pgrst, 'reload schema';
