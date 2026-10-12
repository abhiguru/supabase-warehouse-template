-- Migration 53: report PDFs (generate-report-pdf) are named for removal like
-- the document PDFs. A report path report/<report>/<customer id or all>/<uuid>.pdf
-- older than the generated_documents policy is listed; the document paths of
-- migration 43 are listed as before; any other name in the bucket, a report
-- name the function does not produce, or a file in another bucket is not.
-- Fictional data; runs only in migrations.sh's disposable, network-disabled
-- database (storage.objects rows stand in for stored files).
\set ON_ERROR_STOP on
BEGIN;
DO $$
DECLARE
  customer_report text := 'report/stock-summary/11111111-1111-4111-8111-111111111111/22222222-2222-4222-8222-222222222222.pdf';
  all_report text := 'report/customer-activity/all/33333333-3333-4333-8333-333333333333.pdf';
  fresh_report text := 'report/grn-activity/all/44444444-4444-4444-8444-444444444444.pdf';
  old_grn text := 'grn/11111111-1111-4111-8111-111111111111/55555555-5555-4555-8555-555555555555.pdf';
  old_stock text := 'stock/11111111-1111-4111-8111-111111111111/66666666-6666-4666-8666-666666666666.pdf';
  unmatched text[] := ARRAY[
    'report/2025-annual-summary.pdf',                                                         -- an operator's own file
    'report/sales-report/all/77777777-7777-4777-8777-777777777777.pdf',                      -- not a report the function makes
    'report/stock-summary/ALL/77777777-7777-4777-8777-777777777778.pdf',                     -- "all" is lower case only
    'report/stock-summary/everyone/77777777-7777-4777-8777-777777777779.pdf',                -- neither a customer id nor all
    'report/stock-summary/all/77777777-7777-4777-8777-77777777777a.pdf.bak',                 -- not a .pdf name
    'report/stock-summary/all/extra/77777777-7777-4777-8777-77777777777b.pdf',               -- one level too deep
    'reports/stock-summary/all/77777777-7777-4777-8777-77777777777c.pdf',                    -- another folder
    'archive/2025-price-list.pdf'                                                            -- unmatched before, unmatched now
  ];
  listed text[];
  other text;
BEGIN
  IF (SELECT days FROM warehouse_maintenance.retention_policy WHERE key = 'generated_documents') <> 7 THEN
    RAISE EXCEPTION 'Generated documents are kept for 7 days by default';
  END IF;
  INSERT INTO storage.objects(bucket_id, name, created_at) VALUES
    ('documents', customer_report, now() - interval '30 days'),
    ('documents', all_report, now() - interval '8 days'),
    ('documents', fresh_report, now() - interval '5 minutes'),
    ('documents', old_grn, now() - interval '20 days'),
    ('documents', old_stock, now() - interval '10 days'),
    -- a report-looking name in another bucket is never this list's business
    ('grn-images', 'report/stock-summary/all/88888888-8888-4888-8888-888888888888.pdf', now() - interval '300 days');
  FOREACH other IN ARRAY unmatched LOOP
    INSERT INTO storage.objects(bucket_id, name, created_at) VALUES ('documents', other, now() - interval '300 days');
  END LOOP;

  SELECT array_agg(n ORDER BY n) INTO listed FROM warehouse_maintenance.expired_generated_documents(now()) AS n;
  IF listed IS DISTINCT FROM (SELECT array_agg(x ORDER BY x) FROM unnest(ARRAY[customer_report, all_report, old_grn, old_stock]) AS x) THEN
    RAISE EXCEPTION 'Expected the two old report PDFs and the two old document PDFs, got %', listed;
  END IF;
  -- Oldest first, as before.
  SELECT array_agg(n) INTO listed FROM warehouse_maintenance.expired_generated_documents(now()) AS n;
  IF listed IS DISTINCT FROM ARRAY[customer_report, old_grn, old_stock, all_report] THEN
    RAISE EXCEPTION 'Expected the expired names oldest first, got %', listed;
  END IF;
  -- A report PDF follows the policy's days like the others.
  UPDATE warehouse_maintenance.retention_policy SET days = 9 WHERE key = 'generated_documents';
  SELECT array_agg(n) INTO listed FROM warehouse_maintenance.expired_generated_documents(now()) AS n;
  IF listed IS DISTINCT FROM ARRAY[customer_report, old_grn, old_stock] THEN
    RAISE EXCEPTION 'Under a 9-day policy the 8-day-old report PDF must stay, got %', listed;
  END IF;
  IF has_function_privilege('authenticated', 'warehouse_maintenance.expired_generated_documents(timestamptz)', 'EXECUTE')
     OR has_function_privilege('anon', 'warehouse_maintenance.expired_generated_documents(timestamptz)', 'EXECUTE') THEN
    RAISE EXCEPTION 'The expired-document list is not for the app roles';
  END IF;
  IF NOT has_function_privilege('service_role', 'warehouse_maintenance.expired_generated_documents(timestamptz)', 'EXECUTE') THEN
    RAISE EXCEPTION 'The service role must still list expired documents';
  END IF;
  -- Listing never deletes: the Storage API removes file and row together.
  IF (SELECT count(*) FROM storage.objects WHERE bucket_id = 'documents') <> 5 + array_length(unmatched, 1) THEN
    RAISE EXCEPTION 'Listing changed stored objects';
  END IF;
END $$;
ROLLBACK;
SELECT 'report PDF paths are listed for retention; other names are not' AS result;
