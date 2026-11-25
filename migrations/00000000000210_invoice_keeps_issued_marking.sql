-- Migration (topic: invoice keeps issued marking; number not taken) (WH-308): an issued invoice keeps the package marking and rack its lot
-- had when the invoice was issued. Owner, 2026-11-25: "As issued, AB-12". The lot itself can still be changed (update_grn), and the lot's own
-- screens and the stock reports keep showing its current value.
--  1. invoice_trl gets issued_package_mark, issued_rack and marking_kept_at (set together; the flag tells "copied, may be empty" from "not copied").
--  2. A BEFORE INSERT trigger copies them from the lot (dispatch line -> goodsreceived_trl) when a line is created, so every function that issues
--     an invoice keeps it without being edited; amounts, tax and numbering are not touched.
--  3. Every line of an invoice already issued is filled once from the lot's present values (lines that already hold the cancel copy of
--     migration 143 are left alone; imported invoices are read-only and are not touched).
--  4. cancel_invoice copies the issued marking and rack into the cancel copy (kept_rack, kept_package_mark) instead of the lot's value at cancel.
--  5. Reads of an issued line: the cancel copy wins (migration 143), then the issued copy, then the lot (a line with no copy, e.g. no dispatch line).
--     Patched here: get_invoice_range_for_print, get_invoice_items_detailed, get_customer_invoice_summary. get_invoice_detail and get_invoice_data
--     are definition files and carry the same read.
-- Run twice, the column step fails on the existing columns and the patch fails on its count check. The pg_temp helper is dropped at the end.

ALTER TABLE public.invoice_trl
  ADD COLUMN issued_package_mark character varying(60),
  ADD COLUMN issued_rack character varying(30),
  ADD COLUMN marking_kept_at timestamp with time zone;
COMMENT ON COLUMN public.invoice_trl.marking_kept_at IS 'WH-308: set when the line copied the lot''s package mark and rack (issued_package_mark, issued_rack) at issue. An invoice reads them instead of the lot, so a later change of the lot does not change the invoice.';

CREATE FUNCTION warehouse_security.invoice_trl_keep_issued_marking() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'pg_temp'
AS $$
BEGIN
  IF NEW.marking_kept_at IS NULL AND NEW.disp_trl_id IS NOT NULL THEN
    SELECT gt.package_mark, gt.rack, now() INTO NEW.issued_package_mark, NEW.issued_rack, NEW.marking_kept_at
    FROM public.dispatch_trl dt JOIN public.goodsreceived_trl gt ON gt.id = dt.gr_trl_id
    WHERE dt.id = NEW.disp_trl_id;
  END IF;
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION warehouse_security.invoice_trl_keep_issued_marking() FROM PUBLIC, anon, authenticated, service_role;
CREATE TRIGGER invoice_trl_keep_issued_marking BEFORE INSERT ON public.invoice_trl
  FOR EACH ROW EXECUTE FUNCTION warehouse_security.invoice_trl_keep_issued_marking();

UPDATE public.invoice_trl it
SET issued_package_mark = gt.package_mark, issued_rack = gt.rack, marking_kept_at = now()
FROM public.invoice i, public.dispatch_trl dt, public.goodsreceived_trl gt
WHERE i.id = it.invoice_id AND i.import_batch_id IS NULL AND it.details_kept_at IS NULL
  AND dt.id = it.disp_trl_id AND gt.id = dt.gr_trl_id;

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

SELECT pg_temp.patch_function('public.cancel_invoice(uuid, text, timestamptz)'::regprocedure, ARRAY[
$m$kept_rack = gt.rack,
      kept_package_mark = gt.package_mark,$m$
], ARRAY[
$m$kept_rack = CASE WHEN it.marking_kept_at IS NOT NULL THEN it.issued_rack ELSE gt.rack END,
      kept_package_mark = CASE WHEN it.marking_kept_at IS NOT NULL THEN it.issued_package_mark ELSE gt.package_mark END,$m$
]);

SELECT pg_temp.patch_function('public.get_invoice_range_for_print(text, text, integer, integer)'::regprocedure, ARRAY[
$m$'grn_items_package_mark', grt.package_mark,$m$,
$m$'grn_items_rack', grt.rack,$m$
], ARRAY[
$m$'grn_items_package_mark', CASE WHEN it.marking_kept_at IS NOT NULL THEN it.issued_package_mark ELSE grt.package_mark END,$m$,
$m$'grn_items_rack', CASE WHEN it.marking_kept_at IS NOT NULL THEN it.issued_rack ELSE grt.rack END,$m$
]);

SELECT pg_temp.patch_function('public.get_invoice_items_detailed(uuid)'::regprocedure, ARRAY[
$m$CASE WHEN it.details_kept_at IS NOT NULL THEN it.kept_package_mark ELSE grt.package_mark END AS package_mark,$m$,
$m$CASE WHEN it.details_kept_at IS NOT NULL THEN it.kept_rack ELSE grt.rack END AS rack,$m$
], ARRAY[
$m$CASE WHEN it.details_kept_at IS NOT NULL THEN it.kept_package_mark WHEN it.marking_kept_at IS NOT NULL THEN it.issued_package_mark ELSE grt.package_mark END AS package_mark,$m$,
$m$CASE WHEN it.details_kept_at IS NOT NULL THEN it.kept_rack WHEN it.marking_kept_at IS NOT NULL THEN it.issued_rack ELSE grt.rack END AS rack,$m$
]);

SELECT pg_temp.patch_function('public.get_customer_invoice_summary(uuid, date, date, integer)'::regprocedure, ARRAY[
$m$'rack', grt.rack,
                            'package_mark', grt.package_mark$m$
], ARRAY[
$m$'rack', CASE WHEN it.marking_kept_at IS NOT NULL THEN it.issued_rack ELSE grt.rack END,
                            'package_mark', CASE WHEN it.marking_kept_at IS NOT NULL THEN it.issued_package_mark ELSE grt.package_mark END$m$
]);

DROP FUNCTION pg_temp.patch_function(regprocedure, text[], text[]);
