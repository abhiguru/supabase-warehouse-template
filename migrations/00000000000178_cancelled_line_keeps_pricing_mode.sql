-- Migration 178 (WH-98): a cancelled invoice's lines no longer change when the GRN's pricing mode is changed afterwards.
-- Before: migration 143 kept the line's details but worked the amounts out with the GRN's CURRENT pricing_mode, and update_grn allows a mode
-- change once the only invoice is cancelled. A monthly GRN invoiced at 3,200 (charge 10, 3 months, labour 2, 100 bags), cancelled and then
-- switched to one-time, listed 1,000 for the line.
--  1. invoice_trl.kept_pricing_mode: the GRN's mode (a missing mode is MONTHLY, as update_grn reads it) copied by cancel_invoice with the
--     other kept_* columns. It is the only figure a line's amount reads from outside the line and its invoice, so keeping it reproduces the
--     live amounts exactly (rates, duration, no_of_days, quantity, tax and the charging rule are already the line's or the invoice's own).
--     The amounts themselves are not stored: they stay worked out by the one rule (invoice_storage_amount, migration 164).
--  2. Readers: get_invoice_items_detailed (here), get_invoice_data and get_invoice_detail (definition files, which the PDF and the screen
--     read) use the line's kept mode when it has one, otherwise the GRN's mode as before. A live line has none, so no live amount changes.
--  Still read live for a cancelled invoice: nothing that feeds an amount. Not kept and not an amount input: the header key
--  get_invoice_data.items[].grn_item.pricing_mode / header grn.pricing_mode still show the GRN's current mode (informational).
--  3. Lines kept by migration 143: kept_pricing_mode is filled only where the GRN has not been updated since the cancel
--     (goodsreceived.updated_at <= invoice.cancelled_at; a trigger sets updated_at on every UPDATE of the GRN, and the mode cannot change
--     while a live invoice exists, so the GRN's mode now is the mode at the cancel). A GRN updated since the cancel is left: its mode at the
--     cancel is not recorded, so those lines keep reading the GRN's current mode, as before. Count them (read-only):
--       SELECT count(*) FROM public.invoice_trl it JOIN public.invoice i ON i.id = it.invoice_id
--         WHERE it.details_kept_at IS NOT NULL AND it.kept_pricing_mode IS NULL;
--       (and, of those, the ones that can still differ:)  ... JOIN public.goodsreceived g ON g.id = i.gr_id AND g.pricing_mode IS DISTINCT FROM 'MONTHLY'
-- Written against the functions as migrations 143, 164, 177 left them. Marker-count patches: each before-text is found once.

ALTER TABLE public.invoice_trl ADD COLUMN kept_pricing_mode character varying(20);
ALTER TABLE public.invoice_trl ADD CONSTRAINT invoice_trl_kept_pricing_mode_check
  CHECK (kept_pricing_mode IS NULL OR kept_pricing_mode IN ('ONE_TIME', 'MONTHLY'));
COMMENT ON COLUMN public.invoice_trl.kept_pricing_mode IS 'Migration 178: the GRN pricing mode when cancel_invoice kept the line (or, for a line kept by migration 143, the mode proved unchanged since the cancel). NULL: read the GRN''s mode.';

UPDATE public.invoice_trl it
SET kept_pricing_mode = COALESCE(g.pricing_mode, 'MONTHLY')
FROM public.invoice i, public.goodsreceived g
WHERE i.id = it.invoice_id AND i.cancelled_at IS NOT NULL AND it.details_kept_at IS NOT NULL
  AND g.id = i.gr_id AND g.updated_at <= i.cancelled_at;

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
$m$kept_catalog_word_set = true$m$
], ARRAY[
$m$kept_catalog_word_set = true, kept_pricing_mode = COALESCE(gr.pricing_mode, 'MONTHLY')$m$
]);

SELECT pg_temp.patch_function('public.get_invoice_items_detailed(uuid)'::regprocedure, ARRAY[
$m$CASE WHEN it.details_kept_at IS NOT NULL THEN igr.pricing_mode ELSE gr.pricing_mode END AS mode$m$
], ARRAY[
$m$CASE WHEN it.details_kept_at IS NOT NULL THEN COALESCE(it.kept_pricing_mode, igr.pricing_mode) ELSE gr.pricing_mode END AS mode$m$
]);

DROP FUNCTION pg_temp.patch_function(regprocedure, text[], text[]);

NOTIFY pgrst, 'reload schema';
