-- Migration 197 (WH-181): moving a GST-pair document to another financial year answers the pair's refusal.
--
-- update_invoice checked the financial year of the new date against the inv_fin_year sent (WH422, "The invoice date belongs to financial
-- year 2025, not 2026", migration 120) before migration 182's pair check. The app always sends inv_fin_year, so an app edit moving a
-- document of a pair (migration 173) to another financial year read the generic refusal and never INVOICE_PAIR_OTHER_YEAR ("This invoice
-- has two documents, ... Delete both and make the invoice again."). The pair check now comes first; nothing else changes: the two checks
-- are as they were, both run before anything is written, and an unpaired invoice is refused (WH422) exactly as before.
-- Written against update_invoice as migrations 182, 184 and 190 left it. Marker-count patch: the before-text (the two checks, in their old
-- order) is found once.
--
-- No role is created, altered or dropped. No table, column or grant changes (CREATE OR REPLACE keeps the function's owner and grants).

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
$m$    -- The financial year is the one of the invoice date (migration 120). It is checked when the edit changes the
    -- invoice date or the year; an edit that leaves both as stored is not refused for an old invoice's year.
    IF p_invoice_data->>'inv_fin_year' IS NOT NULL
       AND ((p_invoice_data->>'inv_date')::TIMESTAMPTZ IS DISTINCT FROM v_stored_inv_date
            OR (p_invoice_data->>'inv_fin_year')::integer IS DISTINCT FROM v_stored_fin_year)
       AND (p_invoice_data->>'inv_fin_year')::integer
           <> warehouse_security.financial_year(warehouse_security.business_date((p_invoice_data->>'inv_date')::TIMESTAMPTZ)) THEN
        RAISE EXCEPTION 'The invoice date belongs to financial year %, not %',
            warehouse_security.financial_year(warehouse_security.business_date((p_invoice_data->>'inv_date')::TIMESTAMPTZ)),
            (p_invoice_data->>'inv_fin_year')::integer
            USING ERRCODE = 'WH422';
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
                                     -- WH-183: a partner in another year was split before 182; refusing would block every later edit (the app always sends inv_date), so skip.
                                     AND l.inv_fin_year = own.inv_fin_year
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
    END IF;$m$
], ARRAY[
$m$    -- Migration 182 (WH-174): the other, live document of a GST pair (migration 173; a cancelled partner is not a pair here), locked (lock 71040 is held, so this order is safe).
    -- A paired document's date may not leave its financial year; nothing is written before this.
    SELECT l.id,
           CASE WHEN own.inv_no <= l.inv_no THEN warehouse_security.invoice_label(own.inv_prefix, own.inv_no)
                ELSE warehouse_security.invoice_label(l.inv_prefix, l.inv_no) END,
           CASE WHEN own.inv_no <= l.inv_no THEN warehouse_security.invoice_label(l.inv_prefix, l.inv_no)
                ELSE warehouse_security.invoice_label(own.inv_prefix, own.inv_no) END
      INTO v_pair_id, v_pair_first, v_pair_second
      FROM invoice own JOIN invoice l ON l.id = own.linked_invoice_id AND l.deleted_at IS NULL AND l.cancelled_at IS NULL
                                     -- WH-183: a partner in another year was split before 182; refusing would block every later edit (the app always sends inv_date), so skip.
                                     AND l.inv_fin_year = own.inv_fin_year
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

    -- Migration 197 (WH-181): after the pair check, so a paired document moved to another financial year reads the pair's refusal.
    -- The financial year is the one of the invoice date (migration 120). It is checked when the edit changes the
    -- invoice date or the year; an edit that leaves both as stored is not refused for an old invoice's year.
    IF p_invoice_data->>'inv_fin_year' IS NOT NULL
       AND ((p_invoice_data->>'inv_date')::TIMESTAMPTZ IS DISTINCT FROM v_stored_inv_date
            OR (p_invoice_data->>'inv_fin_year')::integer IS DISTINCT FROM v_stored_fin_year)
       AND (p_invoice_data->>'inv_fin_year')::integer
           <> warehouse_security.financial_year(warehouse_security.business_date((p_invoice_data->>'inv_date')::TIMESTAMPTZ)) THEN
        RAISE EXCEPTION 'The invoice date belongs to financial year %, not %',
            warehouse_security.financial_year(warehouse_security.business_date((p_invoice_data->>'inv_date')::TIMESTAMPTZ)),
            (p_invoice_data->>'inv_fin_year')::integer
            USING ERRCODE = 'WH422';
    END IF;$m$
]);

DROP FUNCTION pg_temp.patch_function(regprocedure, text[], text[]);

NOTIFY pgrst, 'reload schema';
