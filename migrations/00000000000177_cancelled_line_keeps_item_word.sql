-- Migration 177 (WH-88): a cancelled invoice's line shows the same catalog packaging word the live invoice showed for it.
-- Before: migration 143 kept only the lot's word (goodsreceived_trl.packaging) and answered it as catalog.packaging too, while a live invoice
-- answers the item's own word (items.packaging) there. An item whose word is Katta with a lot whose word is blank read Katta live and Bag
-- (the app's default for a blank word) after the cancel.
--  1. warehouse_security.line_catalog_packaging(item id) is the one rule: the item's own word, as stored (NULL stays NULL; the app turns a
--     blank or NULL word into its default Bag, as it does for a live invoice). The live branch of get_invoice_data (definition file) and
--     get_invoice_items_detailed, and the copy cancel_invoice makes, all call it, so they cannot drift.
--  2. invoice_trl.kept_catalog_packaging holds that word as it was when the invoice was cancelled; kept_catalog_word_set says the line was kept
--     by this rule (a NULL word is a valid kept word, so NULL alone cannot say it).
--  3. A cancelled line with kept_catalog_word_set reads kept_catalog_packaging as catalog.packaging; any other kept line reads kept_packaging as
--     before. grn_item.packaging (the lot's word) is unchanged on every path. No amount, quantity or other key changes.
--  4. Lines kept by migration 143 (and its backfill) are NOT changed: the item's word at the time of the cancel is not recorded anywhere
--     (items has no history or update time), and its word now may have been edited since, so any backfill would be a guess. They keep reading
--     the lot's word as catalog.packaging. Only invoices cancelled after this migration carry the item's word.
-- Written against the functions as migrations 143, 164, 172 and 175 left them. Marker-count patches: each before-text is found once.

CREATE FUNCTION warehouse_security.line_catalog_packaging(p_item_id uuid) RETURNS character varying
    LANGUAGE sql STABLE
    SET search_path TO 'pg_catalog'
    AS $$
  SELECT i.packaging FROM public.items i WHERE i.id = p_item_id
$$;
ALTER FUNCTION warehouse_security.line_catalog_packaging(uuid) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION warehouse_security.line_catalog_packaging(uuid) FROM PUBLIC;

ALTER TABLE public.invoice_trl
  ADD COLUMN kept_catalog_packaging character varying(40),
  ADD COLUMN kept_catalog_word_set boolean NOT NULL DEFAULT false;
COMMENT ON COLUMN public.invoice_trl.kept_catalog_word_set IS 'Migration 177: true when cancel_invoice copied the item''s own packaging word (warehouse_security.line_catalog_packaging) into kept_catalog_packaging; false on lines kept by migration 143, which read kept_packaging instead.';

-- Migration 175 leaves its pg_temp helper behind; the files of one run share a session.
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

SELECT pg_temp.patch_function('public.cancel_invoice(uuid, text, timestamp with time zone)'::regprocedure, ARRAY[
$m$kept_grn_no = gr.gr_no, kept_grn_date = gr.date, details_kept_at = v_cancelled_at$m$
], ARRAY[
$m$kept_grn_no = gr.gr_no, kept_grn_date = gr.date, details_kept_at = v_cancelled_at,
      kept_catalog_packaging = warehouse_security.line_catalog_packaging(gt.item_id), kept_catalog_word_set = true$m$
]);

SELECT pg_temp.patch_function('public.get_invoice_items_detailed(uuid)'::regprocedure, ARRAY[
$m$CASE WHEN it.details_kept_at IS NOT NULL THEN it.kept_packaging ELSE catalog.packaging END AS catalog_packaging$m$
], ARRAY[
$m$CASE WHEN it.details_kept_at IS NOT NULL
           THEN CASE WHEN it.kept_catalog_word_set THEN it.kept_catalog_packaging ELSE it.kept_packaging END
           ELSE warehouse_security.line_catalog_packaging(grt.item_id) END AS catalog_packaging$m$
]);

DROP FUNCTION pg_temp.patch_function(regprocedure, text[], text[]);

NOTIFY pgrst, 'reload schema';
