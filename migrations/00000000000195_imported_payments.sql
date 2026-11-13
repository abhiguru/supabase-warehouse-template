-- Migration 195 (WH-180, part 5 of the import of past years): a payment says whether it was imported.
-- Written against warehouse_security.payment_json as migration 172 left it (no later migration changes it). Marker-count patch: the
-- before-text is found exactly once.
--
-- payment_json is the one place a payment row is built for the app. Its callers are get_invoice_detail (invoice.payments[], the only
-- list of individual payments the app reads), and record_payment, update_payment and delete_payment (payment, previous, deleted). Each
-- payment object now carries "imported" (boolean, import_batch_id IS NOT NULL, migration 189), placed after payment_no as migration 191
-- placed it in the GRN, dispatch and invoice reads. An imported payment is read-only (migration 190); a payment recorded in the app on an
-- imported invoice has no batch and reads false. An added key breaks no older caller; no amount, filter or row count changes.
--
-- No role is created, altered or dropped. No table, column or grant changes (CREATE OR REPLACE keeps the function's owner and ACL).

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

SELECT pg_temp.patch_function('warehouse_security.payment_json(public.payments)'::regprocedure, ARRAY[
$m$'id', p.id, 'payment_no', p.payment_no, 'invoice_id', p.invoice_id,$m$
], ARRAY[
$m$'id', p.id, 'payment_no', p.payment_no,
    'imported', p.import_batch_id IS NOT NULL,  -- Migration 195 (WH-180)
    'invoice_id', p.invoice_id,$m$
]);

NOTIFY pgrst, 'reload schema';
