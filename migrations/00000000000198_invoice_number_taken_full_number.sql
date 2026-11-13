-- Migration 198 (WH-190 item 3): an app invoice save whose full number an imported invoice holds is refused as NUMBER_TAKEN.
--
-- unique_inv_label_per_year (migration 175) makes the full number (prefix and number) unique in a financial year. The app's "number taken"
-- checks compared the number only, which was the same set while one year held one prefix. An imported invoice keeps the prefix it was
-- issued with (migration 192), so with an app prefix ending in a digit (INV2) and an imported INV + 25 in the same year, an app save of
-- INV2 + 5 passed the check and failed on the index with a raw 23505. Each check now also compares the full number the new document will
-- have, in the form of the index (inv_prefix || inv_no), so it answers NUMBER_TAKEN as for any number in use; nothing else changes:
--   * public.save_invoice_internal: the full number is the year's prefix (invoice_prefix_for_year, which the insert trigger gives) and the
--     number sent;
--   * warehouse_security.apply_invoice_gst: the second document of a two-document save takes the first one's prefix and number + 1.
-- update_invoice has the same change in migration 197.
--
-- No role is created, altered or dropped. No table, column or grant changes (CREATE OR REPLACE keeps each function's owner and grants).

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

SELECT pg_temp.patch_function('public.save_invoice_internal(uuid, jsonb, jsonb[])'::regprocedure, ARRAY[
$m$          AND i.inv_no = (p_invoice_data->>'inv_no')::integer
          AND i.id IS DISTINCT FROM p_invoice_id$m$
], ARRAY[
$m$          AND (i.inv_no = (p_invoice_data->>'inv_no')::integer
               -- Migration 198 (WH-190): or the full number it will have (unique_inv_label_per_year): an imported INV + 25 holds INV25.
               OR (i.inv_prefix::text || i.inv_no::text)
                  = warehouse_security.invoice_label(warehouse_security.invoice_prefix_for_year((p_invoice_data->>'inv_fin_year')::integer),
                                                     (p_invoice_data->>'inv_no')::bigint))
          AND i.id IS DISTINCT FROM p_invoice_id$m$
]);

SELECT pg_temp.patch_function('warehouse_security.apply_invoice_gst(uuid, boolean)'::regprocedure, ARRAY[
$m$    IF EXISTS (SELECT 1 FROM public.invoice x WHERE x.inv_fin_year = v_inv.inv_fin_year AND x.inv_no = v_second_no) THEN$m$
], ARRAY[
$m$    -- Migration 198 (WH-190): the number, or the full number (unique_inv_label_per_year) the second document will have.
    IF EXISTS (SELECT 1 FROM public.invoice x WHERE x.inv_fin_year = v_inv.inv_fin_year
                AND (x.inv_no = v_second_no
                     OR (x.inv_prefix::text || x.inv_no::text) = warehouse_security.invoice_label(v_inv.inv_prefix, v_second_no))) THEN$m$
]);

DROP FUNCTION pg_temp.patch_function(regprocedure, text[], text[]);

NOTIFY pgrst, 'reload schema';
