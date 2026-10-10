-- Order of receipt numbers in every accepted form (migration 31).
\set ON_ERROR_STOP on
DO $$
DECLARE
  expected text[] := ARRAY[
    -- one-letter prefixes: X, Y, Z first, then A onward; numbers compared as numbers
    'X0001', 'Y0001', 'Z0001',
    'A0001', 'A0002', 'A9999', 'A10000', 'A10001', 'A1234567', 'a0005',
    'B2', 'B9', 'B10', 'B20', 'B100', 'B1000',
    'C0001', 'C001', 'C01', 'C1',
    'M0500',
    -- every other form, by prefix, then number
    '7', '00077', '12345', ' A77', '2026/01', 'ABCD', 'DV0001', 'DV0010', 'DV0101', 'DV0200',
    'G 14', 'G-12', 'G/13', 'É0001', 'जी01'];
  ascending text[];
  descending text[];
  reversed text[];
BEGIN
  SELECT array_agg(n ORDER BY warehouse_security.document_number_sort_key(n) COLLATE "C" ASC),
         array_agg(n ORDER BY warehouse_security.document_number_sort_key(n) COLLATE "C" DESC)
    INTO ascending, descending FROM unnest(expected) AS n;
  SELECT array_agg(n ORDER BY ord DESC) INTO reversed FROM unnest(expected) WITH ORDINALITY AS x(n, ord);
  IF ascending IS DISTINCT FROM expected THEN RAISE EXCEPTION 'ascending order wrong: %', ascending; END IF;
  IF descending IS DISTINCT FROM reversed THEN RAISE EXCEPTION 'descending order wrong: %', descending; END IF;
  -- Every key is distinct, so paging by this order never repeats or skips a receipt.
  IF (SELECT count(DISTINCT warehouse_security.document_number_sort_key(n)) FROM unnest(expected) AS n) <> cardinality(expected) THEN
    RAISE EXCEPTION 'sort keys are not unique';
  END IF;
  IF warehouse_security.document_number_sort_key(NULL) IS NULL OR warehouse_security.document_number_sort_key('') IS NULL THEN
    RAISE EXCEPTION 'empty and missing numbers need a key';
  END IF;
  -- Both list functions use the key and no longer the letter * 10000 rule.
  IF EXISTS (SELECT 1 FROM pg_proc WHERE oid IN (
        'public.get_all_grn_items(timestamptz,timestamptz,jsonb,text,text,integer,integer)'::regprocedure,
        'public.get_grn_list(date,date,text,text,integer,integer,jsonb)'::regprocedure)
      AND (prosrc LIKE '%* 10000%' OR prosrc NOT LIKE '%document_number_sort_key%')) THEN
    RAISE EXCEPTION 'receipt list functions do not use the document number key';
  END IF;
  IF has_function_privilege('authenticated', 'warehouse_security.document_number_sort_key(text)', 'execute')
     OR has_function_privilege('anon', 'warehouse_security.document_number_sort_key(text)', 'execute') THEN
    RAISE EXCEPTION 'sort key helper must not be callable by API roles';
  END IF;
END $$;
