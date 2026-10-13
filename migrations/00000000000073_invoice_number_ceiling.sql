-- Migration 73: a ceiling on invoice numbers (2026-10-13 performance review).
--
-- get_next_invoice_number (migration 48) suggests the year's highest number plus 1 and refuses
-- the year with WH409 when that highest number is 2147483647. Nothing stopped a user from typing
-- such a number: the app's invoice form accepts any digits when no number is suggested, and the
-- save RPCs stored it. One invoice numbered 2147483647 (typed by hand while testing) then made
-- every further invoice of its financial year fail.
--
-- INVOICE_NUMBER_MAX = 99999999 (eight digits, owner's choice, so year-prefixed numbers such as
-- 20260929 stay valid), the largest invoice number the save RPCs accept from now on;
-- 1 to 99999999 is allowed. warehouse_security.invoice_number_max() holds it, so the save check and
-- the suggestion use one value.
--
-- 1. The three granted write paths check the number before they write anything:
--      save_invoice(jsonb)                      the number it stores (inv_no, or the digits after
--                                               the last "-" of header.invoice_number)
--      save_invoice(uuid,jsonb,jsonb[])         p_invoice_data->>'inv_no' (the app's create path)
--      update_invoice(uuid,jsonb,jsonb[])       p_invoice_data->>'inv_no' (the app's edit path)
--    A number outside 1..99999999 is refused with "Invoice number must be between 1 and 99999999"
--    (SQLSTATE WH422). The number is compared as written, so 10 digits get this message, not
--    "integer out of range". save_invoice(jsonb) and update_invoice return their usual
--    {"success": false, "error": ...} answer with it (their exception handlers turn every error
--    into one, the code included); the three-argument save_invoice has no handler, so the
--    refusal reaches the client as an error with code WH422. An edit that keeps the invoice's
--    own stored number is not refused, so an invoice saved before this migration with a larger
--    number can still be edited; changing it to another number outside the range is refused.
--    A missing or non-numeric number is left to the checks that were there before (the NOT NULL
--    column and the integer cast); the unique (inv_fin_year, inv_no) constraint is unchanged.
--    save_invoice_internal and get_next_invoice_number_with_year are not granted to any app role
--    and are not changed.
-- 2. get_next_invoice_number takes the maximum over the year's numbers from 1 to 99999999 only, so
--    a row above the ceiling (legacy data, or written with the service key) no longer blocks its
--    year. Its WH409 refusal now comes when the year's highest number in the range is 99999999,
--    because the number after it would be refused by the save. Guard, signature, security and
--    grants are unchanged (CREATE OR REPLACE keeps the grants).
--
-- tests/invoice_number_ceiling.sql checks both; tests/invoice_number_per_year.sql follows the new
-- suggestion rule.

CREATE FUNCTION warehouse_security.invoice_number_max() RETURNS integer
LANGUAGE sql IMMUTABLE SET search_path = pg_catalog AS $$
  SELECT 99999999  -- INVOICE_NUMBER_MAX
$$;
REVOKE ALL ON FUNCTION warehouse_security.invoice_number_max() FROM PUBLIC, anon, authenticated, service_role;

-- p_number is the number as the request wrote it; p_invoice_id the invoice being edited (NULL
-- when one is created).
CREATE FUNCTION warehouse_security.check_invoice_number(p_number text, p_invoice_id uuid) RETURNS void
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE
  written text := btrim(p_number);
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
REVOKE ALL ON FUNCTION warehouse_security.check_invoice_number(text, uuid) FROM PUBLIC, anon, authenticated, service_role;

DO $patch$
DECLARE target record; definition text; occurrences integer;
BEGIN
  FOR target IN SELECT * FROM (VALUES
    -- After the number's text is read and before it is cast to integer.
    ('public.save_invoice(jsonb)'::regprocedure,
     $m$v_invoice_number_text := COALESCE(v_invoice_header->>'invoice_number', p_invoice_data->>'inv_no');$m$,
     $r$
    PERFORM warehouse_security.check_invoice_number(COALESCE(NULLIF(p_invoice_data->>'inv_no', ''),
        NULLIF(REGEXP_REPLACE(COALESCE(v_invoice_number_text, ''), '^.*-([0-9]+)$', '\1'), '')), NULL);$r$),
    -- Right after the guard and the request notes of migrations 30 and 48, before any write.
    ('public.save_invoice(uuid,jsonb,jsonb[])'::regprocedure,
     $m$PERFORM warehouse_security.note_zero_charge_request(p_invoice_id, p_invoice_data);$m$,
     $r$
  PERFORM warehouse_security.check_invoice_number(p_invoice_data->>'inv_no', NULL);$r$),
    ('public.update_invoice(uuid,jsonb,jsonb[])'::regprocedure,
     $m$PERFORM warehouse_security.note_zero_charge_request(p_invoice_id, p_invoice_data);$m$,
     $r$
  PERFORM warehouse_security.check_invoice_number(p_invoice_data->>'inv_no', p_invoice_id);$r$)
  ) AS t(fn, marker, addition) LOOP
    definition := pg_get_functiondef(target.fn);
    occurrences := (length(definition) - length(replace(definition, target.marker, ''))) / length(target.marker);
    IF occurrences <> 1 THEN
      RAISE EXCEPTION 'Expected one invoice-number marker in %, found %', target.fn, occurrences;
    END IF;
    EXECUTE replace(definition, target.marker, target.marker || target.addition);
  END LOOP;
END $patch$;

CREATE OR REPLACE FUNCTION public.get_next_invoice_number(p_fin_year integer DEFAULT NULL) RETURNS text
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, public, extensions, utils, pg_temp AS $$
DECLARE
    v_fin_year integer;
    v_max_no integer;
BEGIN
    PERFORM warehouse_security.authorize_rpc('get_next_invoice_number', jsonb_build_object());
    v_fin_year := COALESCE(p_fin_year, warehouse_security.financial_year(warehouse_security.business_date(now())));

    -- Numbers above INVOICE_NUMBER_MAX (migration 73) do not count.
    SELECT MAX(inv_no) INTO v_max_no
    FROM invoice
    WHERE inv_fin_year = v_fin_year AND inv_no >= 1 AND inv_no <= warehouse_security.invoice_number_max();

    IF v_max_no >= warehouse_security.invoice_number_max() THEN
        RAISE EXCEPTION 'No invoice number is left in financial year %', v_fin_year USING ERRCODE = 'WH409';
    END IF;

    RETURN (COALESCE(v_max_no, 0) + 1)::TEXT;
END;
$$;

NOTIFY pgrst, 'reload schema';
