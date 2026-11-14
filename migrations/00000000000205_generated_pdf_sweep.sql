-- Migration 205 (WH-195): the clean-up also lists the statement and temperature report PDFs.
--
-- warehouse_maintenance.expired_generated_documents names the generated PDFs in the documents bucket that are older than the
-- generated_documents policy; scripts/retention.sh deletes them through the Storage API. It listed the grn, dispatch, invoice and stock
-- PDFs and the report/ folder, but not generate-statement-pdf (statement/<customer id>/<uuid>.pdf) or generate-temperature-report-pdf
-- (temperature-report/<sensor id>/<uuid>.pdf), so those files were never removed. Both now follow the rule of the other document PDFs:
-- same bucket, same age predicate, same path shape (<folder>/<uuid>/<uuid>.pdf, anchored at both ends). Nothing else is listed:
-- no other folder, no other extension, no other bucket. Nothing stores a path to these PDFs (the answer carries only a one-hour signed link),
-- so removing an expired file breaks no row; a removed PDF is made again on the next request.
--
-- A plain CREATE OR REPLACE (the function is small): owner, grants, language, volatility and search_path are unchanged and kept.
-- The report/ alternative is byte for byte as before (tests/report-pdf.test.mjs reads it from the last definition).

CREATE OR REPLACE FUNCTION warehouse_maintenance.expired_generated_documents(p_now timestamp with time zone DEFAULT now()) RETURNS SETOF text
    LANGUAGE sql STABLE
    SET search_path TO 'pg_catalog', 'public', 'warehouse_maintenance'
    AS $$
  SELECT o.name FROM storage.objects o
  WHERE o.bucket_id = 'documents'
    AND o.created_at < p_now - make_interval(days => (SELECT days FROM warehouse_maintenance.retention_policy WHERE key = 'generated_documents'))
    AND (o.name ~ '^(grn|dispatch|invoice|stock|statement|temperature-report)/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.pdf$'
      OR o.name ~ '^report/(grn-activity|dispatch-activity|invoice-history|stock-summary|stock-aging|item-stock-summary|customer-activity)/([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}|all)/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.pdf$')
  ORDER BY o.created_at, o.name
$$;
