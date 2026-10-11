-- Owner decisions of 2026-10-11.
--
-- 2. The suggested next invoice number is per financial year: the highest
--    number of that year plus 1, starting at 1.
--
-- (Decision 6, the request limit of the REST route, is docker/kong.yml.)

-- ---------------------------------------------------------------------------
-- 2. Next invoice number per financial year
-- ---------------------------------------------------------------------------
-- The financial year a calendar date falls in: 1 April to 31 March, named by
-- the calendar year it starts in, as invoice.inv_fin_year stores it.
CREATE FUNCTION warehouse_security.financial_year(day date) RETURNS integer
LANGUAGE sql IMMUTABLE SET search_path = pg_catalog AS $$
  SELECT EXTRACT(YEAR FROM day)::integer - CASE WHEN EXTRACT(MONTH FROM day) >= 4 THEN 0 ELSE 1 END
$$;
REVOKE ALL ON FUNCTION warehouse_security.financial_year(date) FROM PUBLIC, anon, authenticated, service_role;

-- get_next_invoice_number() took the highest number over every invoice of
-- every year, so a new financial year continued the old year's numbers, and
-- one invoice numbered 2147483647 made it fail with "integer out of range"
-- for all of them. The no-argument function is dropped, not kept beside the
-- new one: two candidates would make a call without an argument ambiguous.
-- Guard name, security and grants are those of the function it replaces, so
-- the allowlists of warehouse_security.authorize_rpc need no change.
--
-- A soft-deleted invoice (deleted_at set; no granted RPC does that,
-- delete_invoice removes the row) is not counted, as decided, although the
-- unique constraint unique_inv_no_per_year still holds its number.
--
-- get_next_invoice_number_with_year() is left as it is: no app role may
-- execute it, and its own handler already turns the overflow into an error
-- answer. It still takes the year from the session's clock, not India's.
DROP FUNCTION public.get_next_invoice_number();
CREATE FUNCTION public.get_next_invoice_number(p_fin_year integer DEFAULT NULL) RETURNS text
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, public, extensions, utils, pg_temp AS $$
DECLARE
    v_fin_year integer;
    v_max_no integer;
BEGIN
    PERFORM warehouse_security.authorize_rpc('get_next_invoice_number', jsonb_build_object());
    v_fin_year := COALESCE(p_fin_year, warehouse_security.financial_year(warehouse_security.business_date(now())));

    SELECT MAX(inv_no) INTO v_max_no
    FROM invoice
    WHERE inv_fin_year = v_fin_year AND deleted_at IS NULL AND inv_no >= 1;

    IF v_max_no = 2147483647 THEN
        RAISE EXCEPTION 'No invoice number is left in financial year %', v_fin_year USING ERRCODE = 'WH409';
    END IF;

    RETURN (COALESCE(v_max_no, 0) + 1)::TEXT;
END;
$$;
REVOKE ALL ON FUNCTION public.get_next_invoice_number(integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_next_invoice_number(integer) TO authenticated, service_role;

NOTIFY pgrst, 'reload schema';
