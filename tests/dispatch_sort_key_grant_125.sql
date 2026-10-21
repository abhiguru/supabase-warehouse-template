-- Migration 125: service_role writes to public.dispatch (the index expression runs as the writing role).
\set ON_ERROR_STOP on
BEGIN;
DO $$
BEGIN
  IF NOT has_function_privilege('service_role','warehouse_security.document_number_sort_key(text)','EXECUTE') THEN RAISE EXCEPTION 'service_role lacks EXECUTE on document_number_sort_key'; END IF;
  IF has_function_privilege('anon','warehouse_security.document_number_sort_key(text)','EXECUTE') THEN RAISE EXCEPTION 'anon must not have EXECUTE on document_number_sort_key'; END IF;
END $$;
INSERT INTO public.customers(name,mobile,active) VALUES ('Sort Key Grant Co','9766600197',true);
SET LOCAL ROLE service_role;
INSERT INTO public.dispatch(disp_no, customer_id, customer_name, disp_date)
  SELECT 'SKG0001', c.id, c.name, now() FROM public.customers c WHERE c.name='Sort Key Grant Co';
UPDATE public.dispatch SET disp_no = disp_no WHERE disp_no = 'SKG0001';
UPDATE public.dispatch SET disp_no = 'SKG0002' WHERE disp_no = 'SKG0001';
DO $$
BEGIN
  IF (SELECT count(*) FROM public.dispatch WHERE disp_no = 'SKG0002') <> 1 THEN RAISE EXCEPTION 'service_role insert/update on dispatch failed'; END IF;
END $$;
RESET ROLE;
ROLLBACK;
\echo 'Dispatch sort key grant checks passed.'
