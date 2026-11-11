-- Migration 182 (WH-174 item 1): the two documents of a GST pair keep one date.
-- A pair (migration 173) is the tax invoice and the bill of supply of one save: two invoice rows linked both ways by
-- invoice.linked_invoice_id (the tax invoice names the bill of supply and the bill of supply names the tax invoice), numbers n and n + 1 of
-- one financial year. For a date change a document is "of a pair" when its linked_invoice_id names an invoice that is neither deleted nor
-- cancelled. A cancelled document is never re-dated (WH-174, Product): it keeps showing what it showed when it was live. So when the other
-- document is cancelled, the live one is treated as unpaired: the cancelled partner gets no copy of the date, no INVOICE_PAIR_OTHER_YEAR
-- refusal is raised on its account, and the prefix rule of migration 175 applies as for any single invoice. (delete_invoice's INVOICE_PAIR
-- rule differs: it counts a cancelled partner, because delete removes both.)
-- Before: update_invoice re-dated only the document it was given, so the two documents could hold different dates, and a date in another
-- financial year moved one document into another year's number series.
--  1. An edit of one document of a pair that sends a different inv_date gives the other document the same inv_date in the same
--     transaction (both or neither: a refusal of the edit, e.g. TOTAL_CHANGED after the write, rolls both back). Numbers, prefixes and
--     everything else of the other document stay as they are. The other document's own date rules are checked as for the edited one
--     (check_invoice_dates, migration 129: INVOICE_BEFORE_DISPATCH names the other document's latest dispatch).
--  2. A paired document whose new date (or inv_fin_year) is in another financial year is refused before anything is written:
--     {success:false, error_code:'WH409', reason:'INVOICE_PAIR_OTHER_YEAR', error and message: "This invoice has two documents, SRT/12 and
--     SRT/13. Their date can't move to another financial year. Delete both and make the invoice again.", first, second (the two full
--     numbers, lower number first), invoice_id, linked_invoice_id, fin_year (the pair's), new_fin_year}. Nothing changes.
--  3. An unpaired invoice is edited exactly as before, including the prefix rule of migration 175 (WH-172 item 3: an invoice moved to
--     another financial year takes that year's prefix).
-- Written against update_invoice as migrations 121, 129, 134, 160, 164, 165, 172, 173 and 175 left it. Marker-count patch: each
-- before-text is found once.

-- Migration 181 drops its helper; this guards against an earlier file that left one behind.
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

SELECT pg_temp.patch_function('public.update_invoice(uuid, jsonb, jsonb[])'::regprocedure, ARRAY[
$m$    v_new_totals jsonb;
BEGIN$m$,
$m$            USING ERRCODE = 'WH422';
    END IF;

    -- A number the financial year already holds$m$,
$m$PERFORM warehouse_security.check_invoice_dates(p_invoice_id, (p_invoice_data->>'inv_date')::timestamptz, ARRAY(SELECT (item->>'disp_trl_id')::uuid FROM unnest(p_invoice_items) AS item));
    -- Migration 129: lines that carry$m$,
$m$    RETURNING inv_no INTO v_invoice_no;

    DELETE FROM invoice_trl WHERE invoice_id = p_invoice_id;$m$
], ARRAY[
$m$    v_new_totals jsonb;
    v_pair_id uuid;
    v_pair_first text;
    v_pair_second text;
    v_new_inv_date timestamptz;
    v_new_fin_year integer;
BEGIN$m$,
$m$            USING ERRCODE = 'WH422';
    END IF;

    -- Migration 182 (WH-174): the other, live document of a GST pair (migration 173; a cancelled partner is not a pair here), locked (lock 71040 is held, so this order is safe).
    -- A paired document's date may not leave its financial year; nothing is written before this.
    SELECT l.id,
           CASE WHEN own.inv_no <= l.inv_no THEN warehouse_security.invoice_label(own.inv_prefix, own.inv_no)
                ELSE warehouse_security.invoice_label(l.inv_prefix, l.inv_no) END,
           CASE WHEN own.inv_no <= l.inv_no THEN warehouse_security.invoice_label(l.inv_prefix, l.inv_no)
                ELSE warehouse_security.invoice_label(own.inv_prefix, own.inv_no) END
      INTO v_pair_id, v_pair_first, v_pair_second
      FROM invoice own JOIN invoice l ON l.id = own.linked_invoice_id AND l.deleted_at IS NULL AND l.cancelled_at IS NULL
     WHERE own.id = p_invoice_id
       FOR UPDATE OF l;
    v_new_inv_date := NULLIF(p_invoice_data->>'inv_date', '')::timestamptz;
    IF v_pair_id IS NOT NULL THEN
        v_new_fin_year := COALESCE(warehouse_security.financial_year(warehouse_security.business_date(v_new_inv_date)), v_stored_fin_year);
        IF v_new_fin_year IS DISTINCT FROM v_stored_fin_year
           OR COALESCE((p_invoice_data->>'inv_fin_year')::integer, v_stored_fin_year) IS DISTINCT FROM v_stored_fin_year THEN
            RETURN warehouse_security.refuse('INVOICE_PAIR_OTHER_YEAR',
                format('This invoice has two documents, %s and %s. Their date can''t move to another financial year. Delete both and make the invoice again.',
                       v_pair_first, v_pair_second),
                jsonb_build_object('first', v_pair_first, 'second', v_pair_second, 'invoice_id', p_invoice_id,
                                   'linked_invoice_id', v_pair_id, 'fin_year', v_stored_fin_year,
                                   'new_fin_year', COALESCE((p_invoice_data->>'inv_fin_year')::integer, v_new_fin_year)));
        END IF;
    END IF;

    -- A number the financial year already holds$m$,
$m$PERFORM warehouse_security.check_invoice_dates(p_invoice_id, (p_invoice_data->>'inv_date')::timestamptz, ARRAY(SELECT (item->>'disp_trl_id')::uuid FROM unnest(p_invoice_items) AS item));
    -- Migration 182 (WH-174): the other document of a pair takes the new date, so its own lines are checked against it.
    IF v_pair_id IS NOT NULL AND v_new_inv_date IS NOT NULL THEN
        PERFORM warehouse_security.check_invoice_dates(v_pair_id, v_new_inv_date,
            ARRAY(SELECT t.disp_trl_id FROM invoice_trl t WHERE t.invoice_id = v_pair_id));
    END IF;
    -- Migration 129: lines that carry$m$,
$m$    RETURNING inv_no INTO v_invoice_no;
    -- Migration 182 (WH-174): the other document of a pair gets the same date (its number and everything else stay).
    IF v_pair_id IS NOT NULL AND v_new_inv_date IS NOT NULL THEN
        UPDATE invoice SET inv_date = v_new_inv_date WHERE id = v_pair_id AND inv_date IS DISTINCT FROM v_new_inv_date;
    END IF;

    DELETE FROM invoice_trl WHERE invoice_id = p_invoice_id;$m$
]);

DROP FUNCTION pg_temp.patch_function(regprocedure, text[], text[]);

NOTIFY pgrst, 'reload schema';
