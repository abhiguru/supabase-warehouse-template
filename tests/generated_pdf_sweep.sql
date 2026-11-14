-- WH-195 (migration generated_pdf_sweep): the clean-up of generated PDFs also lists the statement PDFs
-- (generate-statement-pdf: statement/<customer id>/<uuid>.pdf) and the temperature report PDFs
-- (generate-temperature-report-pdf: temperature-report/<sensor id>/<uuid>.pdf). Same bucket, same age rule, same
-- path shape as the other document PDFs; every other name stays unlisted. The report/ rule and the age rule are
-- unchanged (tests/report_pdf_retention.sql proves them too); the function keeps its owner, grants, search_path and volatility.
-- Fictional data; runs only in migrations.sh's disposable, network-disabled database.
\set ON_ERROR_STOP on
BEGIN;
DO $$
DECLARE
  old_statement text := 'statement/11111111-1111-4111-8111-111111111111/aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa.pdf';
  old_temperature text := 'temperature-report/22222222-2222-4222-8222-222222222222/bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb.pdf';
  fresh_statement text := 'statement/11111111-1111-4111-8111-111111111111/cccccccc-cccc-4ccc-8ccc-cccccccccccc.pdf';
  fresh_temperature text := 'temperature-report/22222222-2222-4222-8222-222222222222/dddddddd-dddd-4ddd-8ddd-dddddddddddd.pdf';
  old_grn text := 'grn/11111111-1111-4111-8111-111111111111/55555555-5555-4555-8555-555555555555.pdf';
  old_report text := 'report/stock-summary/all/33333333-3333-4333-8333-333333333333.pdf';
  unmatched text[] := ARRAY[
    'logos/gcsa-logo.pdf',                                                                                   -- another folder
    'statement/11111111-1111-4111-8111-111111111111/eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee.png',              -- not a .pdf
    'statement/11111111-1111-4111-8111-111111111111/eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeef.pdf.bak',          -- not a .pdf name
    'temperature-report/22222222-2222-4222-8222-222222222222/eeeeeeee-eeee-4eee-8eee-eeeeeeeeeee0.png',     -- not a .pdf
    'temperature-report/22222222-2222-4222-8222-222222222222/eeeeeeee-eeee-4eee-8eee-eeeeeeeeeee1.pdf.bak', -- not a .pdf name
    'backup/statement/11111111-1111-4111-8111-111111111111/eeeeeeee-eeee-4eee-8eee-eeeeeeeeeee2.pdf',      -- not anchored at the start
    'backup/temperature-report/22222222-2222-4222-8222-222222222222/eeeeeeee-eeee-4eee-8eee-eeeeeeeeeee3.pdf',
    'temperature-report/not-a-uuid/eeeeeeee-eeee-4eee-8eee-eeeeeeeeeee4.pdf',                                -- the sensor id is a uuid
    'statement/not-a-uuid/eeeeeeee-eeee-4eee-8eee-eeeeeeeeeee5.pdf',                                         -- the customer id is a uuid
    'statement/11111111-1111-4111-8111-111111111111/extra/eeeeeeee-eeee-4eee-8eee-eeeeeeeeeee6.pdf',       -- one level too deep
    'temperature-report/22222222-2222-4222-8222-222222222222/extra/eeeeeeee-eeee-4eee-8eee-eeeeeeeeeee7.pdf',
    'statements/11111111-1111-4111-8111-111111111111/eeeeeeee-eeee-4eee-8eee-eeeeeeeeeee8.pdf',            -- another folder
    'temperature-report-old/22222222-2222-4222-8222-222222222222/eeeeeeee-eeee-4eee-8eee-eeeeeeeeeee9.pdf', -- another folder
    'temperature-reports/22222222-2222-4222-8222-222222222222/eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeea.pdf'
  ];
  listed text[];
  other text;
  fn regprocedure := 'warehouse_maintenance.expired_generated_documents(timestamptz)'::regprocedure;
BEGIN
  IF (SELECT days FROM warehouse_maintenance.retention_policy WHERE key = 'generated_documents') <> 7 THEN
    RAISE EXCEPTION 'Generated documents are kept for 7 days by default';
  END IF;
  INSERT INTO storage.objects(bucket_id, name, created_at) VALUES
    ('documents', old_statement, now() - interval '30 days'),
    ('documents', old_temperature, now() - interval '8 days'),
    ('documents', fresh_statement, now() - interval '5 minutes'),
    ('documents', fresh_temperature, now() - interval '6 days'),
    ('documents', old_grn, now() - interval '20 days'),
    ('documents', old_report, now() - interval '10 days'),
    -- the same paths in another bucket are never this list's business
    ('grn-images', 'statement/11111111-1111-4111-8111-111111111111/99999999-9999-4999-8999-999999999991.pdf', now() - interval '300 days'),
    ('grn-images', 'temperature-report/22222222-2222-4222-8222-222222222222/99999999-9999-4999-8999-999999999992.pdf', now() - interval '300 days');
  FOREACH other IN ARRAY unmatched LOOP
    INSERT INTO storage.objects(bucket_id, name, created_at) VALUES ('documents', other, now() - interval '300 days');
  END LOOP;

  -- Expired statement and temperature report PDFs are listed with the controls (an expired GRN PDF and an expired report/ PDF);
  -- fresh ones and every unmatched name are not.
  SELECT array_agg(n ORDER BY n) INTO listed FROM warehouse_maintenance.expired_generated_documents(now()) AS n;
  IF listed IS DISTINCT FROM (SELECT array_agg(x ORDER BY x) FROM unnest(ARRAY[old_statement, old_temperature, old_grn, old_report]) AS x) THEN
    RAISE EXCEPTION 'Expected the expired statement, temperature report, GRN and report PDFs only, got %', listed;
  END IF;
  -- Oldest first, as before.
  SELECT array_agg(n) INTO listed FROM warehouse_maintenance.expired_generated_documents(now()) AS n;
  IF listed IS DISTINCT FROM ARRAY[old_statement, old_grn, old_report, old_temperature] THEN
    RAISE EXCEPTION 'Expected the expired names oldest first, got %', listed;
  END IF;
  -- The age rule follows the policy's days: under 9 days the 8-day-old temperature report stays, the 10-day-old report PDF is listed.
  UPDATE warehouse_maintenance.retention_policy SET days = 9 WHERE key = 'generated_documents';
  SELECT array_agg(n) INTO listed FROM warehouse_maintenance.expired_generated_documents(now()) AS n;
  IF listed IS DISTINCT FROM ARRAY[old_statement, old_grn, old_report] THEN
    RAISE EXCEPTION 'Under a 9-day policy the 8-day-old temperature report PDF must stay, got %', listed;
  END IF;
  -- p_now moves the cut-off: 4 days later the 6-day-old temperature report is past 9 days, the 5-minute-old statement is not.
  SELECT array_agg(n) INTO listed FROM warehouse_maintenance.expired_generated_documents(now() + interval '4 days') AS n;
  IF NOT (fresh_temperature = ANY (listed)) OR fresh_statement = ANY (listed) THEN
    RAISE EXCEPTION 'p_now must move the cut-off (6-day-old temperature report listed, 5-minute-old statement not), got %', listed;
  END IF;
  UPDATE warehouse_maintenance.retention_policy SET days = 7 WHERE key = 'generated_documents';

  -- Owner, grants, search_path and volatility are those of the earlier definition (the baseline's).
  IF (SELECT pg_get_userbyid(proowner) FROM pg_proc WHERE oid = fn) <> 'supabase_admin' THEN
    RAISE EXCEPTION 'The function must stay owned by supabase_admin';
  END IF;
  IF (SELECT provolatile FROM pg_proc WHERE oid = fn) <> 's' THEN
    RAISE EXCEPTION 'The function must stay STABLE';
  END IF;
  IF (SELECT proconfig FROM pg_proc WHERE oid = fn) IS DISTINCT FROM ARRAY['search_path=pg_catalog, public, warehouse_maintenance'] THEN
    RAISE EXCEPTION 'The function must keep its search_path, got %', (SELECT proconfig FROM pg_proc WHERE oid = fn);
  END IF;
  IF (SELECT prosecdef FROM pg_proc WHERE oid = fn) THEN
    RAISE EXCEPTION 'The function must stay SECURITY INVOKER';
  END IF;
  IF NOT has_function_privilege('service_role', fn, 'EXECUTE') THEN
    RAISE EXCEPTION 'The service role must still list expired documents';
  END IF;
  IF has_function_privilege('authenticated', fn, 'EXECUTE') OR has_function_privilege('anon', fn, 'EXECUTE')
     OR has_function_privilege('public', fn, 'EXECUTE') THEN
    RAISE EXCEPTION 'The expired-document list is for the service role only';
  END IF;
  -- Only the owner and the service role hold EXECUTE.
  IF (SELECT count(*) FROM pg_proc p, aclexplode(p.proacl) a WHERE p.oid = fn
        AND a.privilege_type = 'EXECUTE' AND pg_get_userbyid(a.grantee) NOT IN ('supabase_admin', 'service_role')) <> 0 THEN
    RAISE EXCEPTION 'No role but the owner and the service role may hold EXECUTE';
  END IF;
  -- Listing never deletes.
  IF (SELECT count(*) FROM storage.objects WHERE bucket_id = 'documents') <> 6 + array_length(unmatched, 1) THEN
    RAISE EXCEPTION 'Listing changed stored objects';
  END IF;
END $$;
ROLLBACK;
SELECT 'statement and temperature report PDFs are listed for retention; other names are not' AS result;
