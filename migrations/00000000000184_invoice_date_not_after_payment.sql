-- Migration 184 (WH-178): update_invoice refuses an invoice date later than a payment's date.
-- record_payment refuses a payment dated before its invoice (PAYMENT_BEFORE_INVOICE, migration 172), but nothing stopped the other order:
-- an invoice re-dated after a payment it already has. Since migration 182 the live other document of a GST pair takes the new date too,
-- so the same hole applied to it.
--  1. An edit that changes the invoice day (India day, as INVOICE_DATE_FUTURE does) to a day after the earliest payment day on this
--     invoice, or on the live other document of its pair, is refused before anything is written:
--     {success:false, error_code:'WH409', reason:'INVOICE_AFTER_PAYMENT', error and message: "This invoice has a payment dated
--     2026-05-01. The invoice date can't be after it.", date (the earliest payment day, YYYY-MM-DD), invoice_date (the day asked for),
--     invoice_id, payment_invoice_id (the document that holds that payment: the edited one or its pair partner)}.
--     A new reason, because PAYMENT_BEFORE_INVOICE reads from the payment's side ("A payment can't be dated before the invoice") and its
--     fields name the invoice day, not the payment day.
--  2. Payments with paid_on NULL (rows from the old accounting link, migration 172) are ignored: they never block an edit. Only rows
--     recorded in the app (paid_on set) count. An edit that does not change the invoice day is never refused by this rule, so an invoice
--     already stored with a day after a payment stays editable (as with INVOICE_DATE_FUTURE and INVOICE_BEFORE_DISPATCH).
--  3. A cancelled partner is not part of the pair (migration 182), so its payments do not count.
-- Written against update_invoice as migration 182 left it. Marker-count patch: each before-text is found once.

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
$m$    v_new_fin_year integer;
BEGIN$m$,
$m$    -- Migration 182 (WH-174): the other document of a pair takes the new date, so its own lines are checked against it.$m$
], ARRAY[
$m$    v_new_fin_year integer;
    v_pay_day date;
    v_pay_invoice_id uuid;
BEGIN$m$,
$m$    -- Migration 184 (WH-178): the new invoice day may not be after a payment on this invoice or on the live other document of its pair.
    -- Rows with paid_on NULL (old accounting link) are ignored. Checked only when the invoice day changes; nothing is written before this.
    IF v_new_inv_date IS NOT NULL
       AND warehouse_security.business_date(v_new_inv_date)
           IS DISTINCT FROM (SELECT warehouse_security.business_date(i.inv_date) FROM invoice i WHERE i.id = p_invoice_id) THEN
        SELECT p.paid_on, p.invoice_id INTO v_pay_day, v_pay_invoice_id
          FROM payments p
         WHERE p.paid_on IS NOT NULL AND (p.invoice_id = p_invoice_id OR p.invoice_id = v_pair_id)
         ORDER BY p.paid_on, p.payment_no LIMIT 1;
        IF v_pay_day IS NOT NULL AND warehouse_security.business_date(v_new_inv_date) > v_pay_day THEN
            RETURN warehouse_security.refuse('INVOICE_AFTER_PAYMENT',
                format('This invoice has a payment dated %s. The invoice date can''t be after it.', to_char(v_pay_day, 'YYYY-MM-DD')),
                jsonb_build_object('date', to_char(v_pay_day, 'YYYY-MM-DD'),
                                   'invoice_date', to_char(warehouse_security.business_date(v_new_inv_date), 'YYYY-MM-DD'),
                                   'invoice_id', p_invoice_id, 'payment_invoice_id', v_pay_invoice_id));
        END IF;
    END IF;
    -- Migration 182 (WH-174): the other document of a pair takes the new date; its own lines are checked against it.$m$
]);

DROP FUNCTION pg_temp.patch_function(regprocedure, text[], text[]);

NOTIFY pgrst, 'reload schema';
