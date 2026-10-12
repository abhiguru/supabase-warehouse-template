-- Report PDFs expire like the document PDFs (2026-10-12).
--
-- The new edge function generate-report-pdf (functions/_shared/report-pdf.ts)
-- stores every report it renders as a new object in the private documents
-- bucket, under
--     report/<report>/<customer id or all>/<random uuid>.pdf
-- where <report> is one of the seven report names the function accepts.
-- warehouse_maintenance.expired_generated_documents (migration 43) names only
-- <kind>/<document id>/<uuid>.pdf for grn, dispatch, invoice and stock, so a
-- report PDF would never be listed and scripts/retention.sh would never remove
-- it. This migration widens the match to the report paths as well.
--
-- Method: the function is a one-statement SQL function, so it is redefined
-- whole with CREATE OR REPLACE (same name, argument, return type, volatility
-- and search_path). The four document patterns are kept exactly as they were;
-- the report pattern is an added alternative that names each report and
-- accepts only a UUID or the word "all" as the second part. A file an operator
-- put in the bucket under any other name is still never listed. The grants of
-- migration 43 are restated so the function stays for the service role only.
-- tests/report_pdf_retention.sql proves both patterns.

CREATE OR REPLACE FUNCTION warehouse_maintenance.expired_generated_documents(p_now timestamptz DEFAULT now())
RETURNS SETOF text
LANGUAGE sql STABLE
SET search_path = pg_catalog, public, warehouse_maintenance
AS $$
  SELECT o.name FROM storage.objects o
  WHERE o.bucket_id = 'documents'
    AND o.created_at < p_now - make_interval(days => (SELECT days FROM warehouse_maintenance.retention_policy WHERE key = 'generated_documents'))
    AND (o.name ~ '^(grn|dispatch|invoice|stock)/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.pdf$'
      OR o.name ~ '^report/(grn-activity|dispatch-activity|invoice-history|stock-summary|stock-aging|item-stock-summary|customer-activity)/([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}|all)/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.pdf$')
  ORDER BY o.created_at, o.name
$$;
REVOKE ALL ON FUNCTION warehouse_maintenance.expired_generated_documents(timestamptz) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION warehouse_maintenance.expired_generated_documents(timestamptz) TO service_role;

NOTIFY pgrst, 'reload schema';
