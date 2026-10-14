-- Migration 79: invoice number check also strips tab, newline, carriage return, vertical tab and
-- form feed (bundle review 2026-10-14, F10).
--
-- Migration 73's check_invoice_number trimmed only spaces and let every text that is not plain
-- digits through, leaving the decision to the later ::integer cast. PostgreSQL's integer input
-- accepts surrounding tabs, newlines, CR, VT and FF, so '\t0', '\n-5' or '100000000\n' passed the
-- check and were stored. The check now trims the same characters the cast does. Signature,
-- security and grants are unchanged (CREATE OR REPLACE keeps them).
CREATE OR REPLACE FUNCTION warehouse_security.check_invoice_number(p_number text, p_invoice_id uuid) RETURNS void
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE
  written text := btrim(p_number, E' \t\n\r\v\f');
  number numeric;
BEGIN
  IF written IS NULL OR written !~ '^[+-]?[0-9]+$' THEN RETURN; END IF;
  number := written::numeric;
  IF number BETWEEN 1 AND warehouse_security.invoice_number_max() THEN RETURN; END IF;
  IF p_invoice_id IS NOT NULL
     AND EXISTS (SELECT 1 FROM public.invoice i WHERE i.id = p_invoice_id AND i.inv_no::numeric = number) THEN
    RETURN;
  END IF;
  RAISE EXCEPTION 'Invoice number must be between 1 and %', warehouse_security.invoice_number_max()
    USING ERRCODE = 'WH422';
END $$;
