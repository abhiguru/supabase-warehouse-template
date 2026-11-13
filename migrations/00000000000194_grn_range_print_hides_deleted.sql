-- Migration 194 (WH-186): a deleted GRN is never printed on the preprinted form.
--
-- get_grn_range_for_print had no deleted_at filter (the invoice range print has one), so a soft-deleted GRN (delete_grn_safe) in the
-- range was printed. It is now left out; a range holding only deleted GRNs answers an empty list, as an empty range always did.
-- Migration 191's exclusion of imported GRNs is kept. The single-GRN PDF (generate-grn-pdf) already filters deleted_at.
--
-- No role is created, altered or dropped. No table, column or grant changes.

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

SELECT pg_temp.patch_function('public.get_grn_range_for_print(text, text, integer)'::regprocedure, ARRAY[
$m$        WHERE gr.import_batch_id IS NULL$m$
], ARRAY[
$m$        WHERE gr.deleted_at IS NULL  -- Migration 194 (WH-186): a deleted GRN is never printed.
          AND gr.import_batch_id IS NULL$m$
]);

NOTIFY pgrst, 'reload schema';
