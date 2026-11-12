-- Migration 180 (WH-163): the invoice form no longer offers a dispatch line whose dispatch is soft-deleted (dispatch.deleted_at set).
-- Before: build_invoice_form_lines joined every dispatch of the GRN, so a soft-deleted dispatch's lines were offered (and priced) on the
-- invoice form, in the review step (preview_invoice_documents) and in the rate check, while the customer statement's "goods that have
-- left" (warehouse_security.grn_not_invoiced, migration 176) and grn_has_free_dispatch_line (migration 165) already leave them out.
-- Nothing in the app soft-deletes a dispatch (delete_dispatch_with_order_cleanup deletes the rows; safe_delete_dispatch was dropped by
-- migration 123), so only rows soft-deleted before that, or by hand, are concerned.
--  1. build_invoice_form_lines: the dispatch join also requires deleted_at IS NULL. The statement's notional in-store branch (migration
--     176) has no dispatch and does not change.
--  2. The save needs no change: save_invoice_internal and update_invoice call warehouse_security.assert_invoice_lines after writing the
--     lines, and since the baseline it counts a line of a soft-deleted dispatch as unrelated ('Invoice contains a missing, duplicate or
--     unrelated dispatch line'; the save is rolled back and answers success false).
-- Written against the function as migrations 119, 141, 164, 165, 173 and 176 left it. Marker-count patch: the before-text is found once.

-- Migration 179 drops its helper; this guards against an earlier file that left one behind.
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

SELECT pg_temp.patch_function('public.build_invoice_form_lines(uuid, text)'::regprocedure, ARRAY[
$m$JOIN dispatch d ON d.id = dt.disp_id
        LEFT JOIN items i ON i.id = grt.item_id$m$
], ARRAY[
$m$JOIN dispatch d ON d.id = dt.disp_id
                       AND d.deleted_at IS NULL  -- Migration 180 (WH-163): a soft-deleted dispatch's lines are not offered.
        LEFT JOIN items i ON i.id = grt.item_id$m$
]);

DROP FUNCTION pg_temp.patch_function(regprocedure, text[], text[]);

NOTIFY pgrst, 'reload schema';
