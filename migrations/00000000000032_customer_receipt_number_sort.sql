-- The customer receipt list sorts by number with the same key as the staff lists
-- (migration 31). It compared gr_no as plain text, so B10 came before B9 and the order
-- differed from what warehouse roles see for the same receipts.
DO $migration$
DECLARE
  signature constant text := 'public.get_customer_grn_items(uuid,timestamptz,timestamptz,jsonb,text,text,integer,integer)';
  definition text := pg_get_functiondef(signature::regprocedure);
  change record;
BEGIN
  FOR change IN SELECT * FROM (VALUES
    ($before$CASE WHEN p_sort_by = 'gr_no' AND p_sort_order = 'desc' THEN gr_no END DESC,$before$,
     $after$CASE WHEN p_sort_by = 'gr_no' AND p_sort_order = 'desc' THEN warehouse_security.document_number_sort_key(gr_no) COLLATE "C" END DESC,$after$),
    ($before$CASE WHEN p_sort_by = 'gr_no' AND p_sort_order = 'asc' THEN gr_no END ASC,$before$,
     $after$CASE WHEN p_sort_by = 'gr_no' AND p_sort_order = 'asc' THEN warehouse_security.document_number_sort_key(gr_no) COLLATE "C" END ASC,$after$)
  ) AS changes(before_text, after_text)
  LOOP
    IF (length(definition) - length(replace(definition, change.before_text, ''))) <> length(change.before_text) THEN
      RAISE EXCEPTION 'Unexpected receipt-number sort in %', signature;
    END IF;
    definition := replace(definition, change.before_text, change.after_text);
  END LOOP;
  EXECUTE definition;
END;
$migration$;
