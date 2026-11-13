-- Migration 196 (WH-180, spec answer 4, criterion 20): a dispatch line taken as billed by an imported invoice is not billed again.
--
-- Migration 192 holds, in public.imported_billed_dispatches, each imported dispatch line that an imported invoice naming no dispatch takes
-- as billed. The reads that ask "is this dispatch line on a live invoice?" to decide what is still to bill now also ask "or is it taken as
-- billed by a live invoice?". Only that test changes in each function:
--   * public.build_invoice_form_lines: with Invoice as goods leave on, the form does not offer such a line (nor do the preview and the
--     rate check, which read the form);
--   * warehouse_security.claim_invoice_lines (the save check of save_invoice_internal and update_invoice): such a line is refused with
--     WH409 DISPATCH_LINE_INVOICED, as a line on another invoice is;
--   * warehouse_security.grn_has_free_dispatch_line: such a line is not free, so a GRN whose only open lines are taken as billed is not
--     offered for invoicing (grn_invoiceable) and reads as invoiced (grn_invoice_state, the GRN's invoiced cache).
-- not_invoiced_grns (Customer dues and the statement) and the import's own reads have the test in migrations 193 and 192.
-- Left alone: the edit and delete guards of dispatches and GRNs (a link is only on an imported dispatch, which migration 190 keeps
-- read-only), the invoice reads and prints (they read an invoice's own lines), and get_dispatch_details (it shows the invoice line of a
-- dispatch line; a taken-as-billed line has none).
--
-- No role is created, altered or dropped. No table, column or grant changes (CREATE OR REPLACE keeps each function's owner and grants).

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
$m$                  AND liv.id::text IS DISTINCT FROM NULLIF(current_setting('warehouse.form_invoice_id', true), '')))$m$
], ARRAY[
$m$                  AND liv.id::text IS DISTINCT FROM NULLIF(current_setting('warehouse.form_invoice_id', true), ''))
                -- Migration 196 (WH-180): nor a line taken as billed by a live imported invoice.
                AND NOT EXISTS (SELECT 1 FROM imported_billed_dispatches lb JOIN invoice lbi ON lbi.id = lb.invoice_id
                                 WHERE lb.disp_trl_id = dt.id AND lbi.deleted_at IS NULL AND lbi.cancelled_at IS NULL))$m$
]);

SELECT pg_temp.patch_function('warehouse_security.claim_invoice_lines(uuid, uuid, uuid[])'::regprocedure, ARRAY[
$m$                      WHERE mine.invoice_id=p_invoice_id AND mine.disp_trl_id=other.disp_trl_id)
  ) THEN$m$
], ARRAY[
$m$                      WHERE mine.invoice_id=p_invoice_id AND mine.disp_trl_id=other.disp_trl_id)
  ) OR EXISTS (
    -- Migration 196 (WH-180): a line taken as billed by a live imported invoice is on that invoice.
    SELECT 1 FROM public.imported_billed_dispatches b
    JOIN public.invoice bi ON bi.id=b.invoice_id
    WHERE b.disp_trl_id = ANY(p_lines)
      AND bi.deleted_at IS NULL
      AND bi.cancelled_at IS NULL
      AND b.invoice_id IS DISTINCT FROM p_invoice_id
  ) THEN$m$
]);

SELECT pg_temp.patch_function('warehouse_security.grn_has_free_dispatch_line(uuid)'::regprocedure, ARRAY[
$m$                      WHERE it.disp_trl_id = dt.id AND iv.deleted_at IS NULL AND iv.cancelled_at IS NULL))$m$
], ARRAY[
$m$                      WHERE it.disp_trl_id = dt.id AND iv.deleted_at IS NULL AND iv.cancelled_at IS NULL)
      -- Migration 196 (WH-180): nor taken as billed by a live imported invoice.
      AND NOT EXISTS (SELECT 1 FROM public.imported_billed_dispatches b JOIN public.invoice bi ON bi.id = b.invoice_id
                      WHERE b.disp_trl_id = dt.id AND bi.deleted_at IS NULL AND bi.cancelled_at IS NULL))$m$
]);

DROP FUNCTION pg_temp.patch_function(regprocedure, text[], text[]);

NOTIFY pgrst, 'reload schema';
