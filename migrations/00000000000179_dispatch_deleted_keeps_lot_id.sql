-- Migration 179 (WH-100): the order history of a deleted dispatch names the lot (GRN line) that was given back, not just an item with the same name.
-- Before: migration 144 made get_order_change_log look a restored item's lot up by its id (restored_items[].grn_item_id) when the entry has one,
-- and added grn_item_id to the working list v_restored_items of delete_dispatch_with_order_cleanup. But the stored dispatch_deleted entry is rebuilt
-- with four fixed keys (item_name, package_mark, grn_no, quantity_restored; migration 121), so grn_item_id was never saved and the lookup always
-- fell back to the name. A GRN holding two items with one name (possible since 144, with different packaging words) could show the wrong one.
--  1. delete_dispatch_with_order_cleanup: the stored restored_items entry also keeps grn_item_id (the lot's id, as text; null if the working
--     list has none).
--  2. get_order_change_log needs no change: since 144 it matches by grn_item_id when the entry has one and by name only when it has none
--     (entries written before this migration, or before 144, keep matching by name as they always did; nothing is rewritten).
-- Written against the function as migrations 121, 130, 134, 144 and 156 left it. Marker-count patch: the before-text is found once.

-- Migration 178 drops its helper; this guards against an earlier file that left one behind.
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

-- The marker spans the line break after 'grn_no', so the replacement (which adds a line there) does not contain it.
SELECT pg_temp.patch_function('public.delete_dispatch_with_order_cleanup(uuid, uuid)'::regprocedure, ARRAY[
$m$'grn_no', r.e->>'grn_no',
                                   'quantity_restored'$m$
], ARRAY[
$m$'grn_no', r.e->>'grn_no',
                                   'grn_item_id', r.e->>'grn_item_id',
                                   'quantity_restored'$m$
]);

DROP FUNCTION pg_temp.patch_function(regprocedure, text[], text[]);

NOTIFY pgrst, 'reload schema';
