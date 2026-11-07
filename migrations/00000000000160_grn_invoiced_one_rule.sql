-- Migration 160 (WH-112): "invoiced" means one thing everywhere: the GRN has a live invoice (neither deleted nor cancelled).
-- goodsreceived.invoiced is a cache the invoice functions keep in step; a decision reads the invoices.
--
--  1. update_invoice: moving an invoice to another GRN cleared the old GRN's flag only when no other invoice that is not deleted held it, so
--     a cancelled invoice left on the old GRN kept it flagged. It now counts only invoices that are neither deleted nor cancelled (as
--     cancel_invoice and delete_invoice do).
--  2. get_grn_list: the "invoiced" filter asks whether a live invoice exists instead of reading the flag.
--  3. Flags that disagree with the rule are corrected once; the number changed is reported as a NOTICE.
-- apply_grn_rates reads the rule in its definition file (migrations/definitions/apply_grn_rates.sql). update_grn (its own-rates step and its
-- other checks) is not changed here; see the hand-back of WH-112.
-- Each patch counts its marker (it must occur exactly once), replaces it and re-creates the function; a second run fails on the count.

CREATE FUNCTION pg_temp.patch_function(p_function regprocedure, p_old text, p_new text) RETURNS void
    LANGUAGE plpgsql AS $$
DECLARE
  v_def text := pg_get_functiondef(p_function);
  v_count integer := (length(v_def) - length(replace(v_def, p_old, ''))) / length(p_old);
BEGIN
  IF v_count <> 1 THEN
    RAISE EXCEPTION '%: expected the marker once, found % times', p_function, v_count;
  END IF;
  EXECUTE replace(v_def, p_old, p_new);
END;
$$;

-- 1. update_invoice
SELECT pg_temp.patch_function('public.update_invoice(uuid, jsonb, jsonb[])'::regprocedure,
$m$AND NOT EXISTS (SELECT 1 FROM invoice i WHERE i.gr_id = v_old_gr_id AND i.deleted_at IS NULL AND i.id <> p_invoice_id);$m$,
$m$AND NOT EXISTS (SELECT 1 FROM invoice i WHERE i.gr_id = v_old_gr_id AND i.deleted_at IS NULL AND i.cancelled_at IS NULL AND i.id <> p_invoice_id);$m$);

-- 2. get_grn_list
SELECT pg_temp.patch_function('public.get_grn_list(date, date, text, text, integer, integer, jsonb)'::regprocedure,
$m$format('gr.invoiced = %L', (p_filters->>'invoiced')::boolean)$m$,
$m$format('(EXISTS (SELECT 1 FROM invoice li WHERE li.gr_id = gr.id AND li.deleted_at IS NULL AND li.cancelled_at IS NULL)) = %L', (p_filters->>'invoiced')::boolean)$m$);

DROP FUNCTION pg_temp.patch_function(regprocedure, text, text);

-- 3. Bring the flags in line with the rule.
DO $fix$
DECLARE
  v_set integer;
  v_cleared integer;
BEGIN
  UPDATE public.goodsreceived g SET invoiced = true
  WHERE g.invoiced IS DISTINCT FROM true
    AND EXISTS (SELECT 1 FROM public.invoice i WHERE i.gr_id = g.id AND i.deleted_at IS NULL AND i.cancelled_at IS NULL);
  GET DIAGNOSTICS v_set = ROW_COUNT;
  UPDATE public.goodsreceived g SET invoiced = false
  WHERE g.invoiced IS TRUE
    AND NOT EXISTS (SELECT 1 FROM public.invoice i WHERE i.gr_id = g.id AND i.deleted_at IS NULL AND i.cancelled_at IS NULL);
  GET DIAGNOSTICS v_cleared = ROW_COUNT;
  RAISE NOTICE 'Migration 160: invoiced flag set on % GRN(s) with a live invoice, cleared on % GRN(s) with none', v_set, v_cleared;
END;
$fix$;
