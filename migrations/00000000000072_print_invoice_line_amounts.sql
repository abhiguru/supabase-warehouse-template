-- Migration 72: the invoice print data carries each line's amounts (external review 2026-10-13,
-- PRINT2 and PRINT3; the printing routes still answer 503).
--
-- get_invoice_range_for_print (service role; read by functions/print-invoice-preprinted) gave each
-- line its charge, dispatched quantity and duration but not the receipt's pricing mode, so the
-- print code computed duration * quantity * rate for every line, a ONE_TIME receipt included, whose
-- storage is charged once. Each line now also carries:
--   pricing_mode    the receipt's (goodsreceived.pricing_mode), as the invoice header rule reads it;
--   storage_amount  ONE_TIME: round(charge * qty, 2); otherwise round(charge * qty * COALESCE(duration, 1), 2);
--   labour_amount   ONE_TIME: 0; otherwise round(labour_rate * qty, 2)
-- the rule warehouse_security.recalculate_invoice_header applies (migration 48), so the printed
-- line amounts are the saved invoice's. The print code prints these numbers and refuses a line
-- without them; it no longer computes an amount. The function is patched in place (one marker,
-- counted); its other keys, grants, SECURITY DEFINER and search_path are unchanged.
--
-- print_jobs.status also accepts 'unknown': the outcome of a job the printer accepted but whose
-- end CUPS never confirmed (it no longer lists the job, or the monitor's time ran out). Such a
-- job is neither completed nor failed; staff check it at the printer.
-- tests/print_invoice_range.sql checks both.
DO $patch$
DECLARE fn regprocedure; definition text; marker text; replacement text; occurrences integer;
BEGIN
  fn := 'public.get_invoice_range_for_print(text,text,integer,integer)'::regprocedure;
  definition := pg_get_functiondef(fn);
  marker := $m$'inv_item_charge', COALESCE(it.charge, 0)
                ) ORDER BY it.id$m$;
  replacement := $r$'inv_item_charge', COALESCE(it.charge, 0),
                    'pricing_mode', gr.pricing_mode,
                    'storage_amount', CASE WHEN gr.pricing_mode = 'ONE_TIME'
                        THEN round(COALESCE(it.charge, 0) * dt.disp_qty, 2)
                        ELSE round(COALESCE(it.charge, 0) * dt.disp_qty * COALESCE(it.duration, 1), 2) END,
                    'labour_amount', CASE WHEN gr.pricing_mode = 'ONE_TIME'
                        THEN 0::numeric
                        ELSE round(COALESCE(it.labour_rate, 0) * dt.disp_qty, 2) END
                ) ORDER BY it.id$r$;
  occurrences := (length(definition)-length(replace(definition,marker,'')))/length(marker);
  IF occurrences <> 1 THEN RAISE EXCEPTION 'Expected one line-object end in get_invoice_range_for_print, found %', occurrences; END IF;
  EXECUTE replace(definition,marker,replacement);
END $patch$;

ALTER TABLE public.print_jobs DROP CONSTRAINT print_jobs_status_check;
ALTER TABLE public.print_jobs ADD CONSTRAINT print_jobs_status_check CHECK ((status)::text = ANY (ARRAY[
  'queued'::text, 'printing'::text, 'completed'::text, 'cancelled'::text, 'failed'::text, 'unknown'::text]));
NOTIFY pgrst, 'reload schema';
