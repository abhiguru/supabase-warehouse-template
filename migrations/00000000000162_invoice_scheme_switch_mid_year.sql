-- Migration 162 (WH-131): the invoice numbering scheme (year <-> sequence) can not be switched while an invoice row exists in the current
-- financial year. Any row of public.invoice counts: live, cancelled, or soft-deleted. The financial year is the one the year scheme uses
-- (warehouse_security.financial_year of the facility's business date; it starts on 1 April). With no invoice in it, the switch works as before.
-- Refused with warehouse_security.refuse: {success:false, error_code:'WH409', reason:'NUMBERING_SWITCH_MID_YEAR', error and message: the sentence
-- below}, and nothing changes (the check is before the UPDATE). Only a change of scheme is refused: the same scheme with another start works,
-- GRN and dispatch rules are untouched, and a new install (no invoice) can choose either scheme at setup.
-- Patched in place by marker count (the function has no definition file); a second run fails on the count.

DO $patch$
DECLARE
  v_def text := pg_get_functiondef('warehouse_security.apply_document_numbering(text, jsonb, uuid)'::regprocedure);
  v_old text := $m$  UPDATE warehouse_security.document_numbering
     SET scheme = r_new.scheme,$m$;
  v_new text := $m$  -- Migration 162 (WH-131): no scheme switch for invoices while an invoice exists in the current financial year.
  IF p_type = 'invoice' AND r_new.scheme IS DISTINCT FROM r_old.scheme
     AND EXISTS (SELECT 1 FROM public.invoice i
                 WHERE i.inv_fin_year = warehouse_security.financial_year(warehouse_security.business_date(now()))) THEN
    RETURN warehouse_security.refuse('NUMBERING_SWITCH_MID_YEAR',
      'Invoices already exist this financial year. The numbering can be changed from 1 April.');
  END IF;

  UPDATE warehouse_security.document_numbering
     SET scheme = r_new.scheme,$m$;
  v_count integer;
BEGIN
  v_count := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'apply_document_numbering: expected the marker once, found % times', v_count;
  END IF;
  EXECUTE replace(v_def, v_old, v_new);
END
$patch$;
