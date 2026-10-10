\set ON_ERROR_STOP on
BEGIN;
DO $$
DECLARE
  old_otp uuid := gen_random_uuid();
  fresh_otp uuid := gen_random_uuid();
  preview jsonb;
  applied jsonb;
BEGIN
  INSERT INTO public.otp_verifications(id, phone_number, purpose, expires_at, created_at)
  VALUES
    (old_otp, '919999999991', 'login', now() - interval '10 days', now() - interval '10 days'),
    (fresh_otp, '919999999992', 'login', now() + interval '5 minutes', now());
  INSERT INTO public.otp_rate_limits(phone_number, updated_at)
  VALUES ('919999999991', now() - interval '10 days'), ('919999999992', now());
  INSERT INTO public.ip_rate_limits(ip_address, updated_at)
  VALUES ('192.0.2.1', now() - interval '10 days'), ('192.0.2.2', now());
  INSERT INTO public.idempotency_keys(idempotency_key, rpc_function, response, expires_at)
  VALUES ('retention-old', 'test', '{}', now() - interval '1 minute'),
         ('retention-fresh', 'test', '{}', now() + interval '1 hour');

  preview := warehouse_maintenance.run_database_retention(now(), false);
  IF (preview #>> '{rows,otp_verifications}')::int < 1 THEN RAISE EXCEPTION 'Dry-run did not find expired OTP'; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.otp_verifications WHERE id = old_otp) THEN RAISE EXCEPTION 'Dry-run changed data'; END IF;

  applied := warehouse_maintenance.run_database_retention(now(), true);
  IF (applied #>> '{rows,otp_verifications}')::int < 1 THEN RAISE EXCEPTION 'Apply did not delete expired OTP'; END IF;
  IF EXISTS (SELECT 1 FROM public.otp_verifications WHERE id = old_otp) THEN RAISE EXCEPTION 'Expired OTP remains'; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.otp_verifications WHERE id = fresh_otp) THEN RAISE EXCEPTION 'Fresh OTP was deleted'; END IF;
  IF EXISTS (SELECT 1 FROM public.otp_rate_limits WHERE phone_number = '919999999991') OR
     EXISTS (SELECT 1 FROM public.ip_rate_limits WHERE ip_address = '192.0.2.1') OR
     EXISTS (SELECT 1 FROM public.idempotency_keys WHERE idempotency_key = 'retention-old') THEN
    RAISE EXCEPTION 'Expired ephemeral record remains';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.otp_rate_limits WHERE phone_number = '919999999992') OR
     NOT EXISTS (SELECT 1 FROM public.ip_rate_limits WHERE ip_address = '192.0.2.2') OR
     NOT EXISTS (SELECT 1 FROM public.idempotency_keys WHERE idempotency_key = 'retention-fresh') THEN
    RAISE EXCEPTION 'Fresh ephemeral record was deleted';
  END IF;
END $$;
ROLLBACK;

-- Migration 43: generated PDFs older than the generated_documents policy are
-- named for scripts/retention.sh, which deletes them through the Storage API
-- (tests/retention-documents.test.mjs). Only names the PDF functions produce
-- are listed; the list follows the policy's days.
BEGIN;
DO $$
DECLARE
  old_pdf text := 'grn/11111111-1111-4111-8111-111111111111/22222222-2222-4222-8222-222222222222.pdf';
  week_old_pdf text := 'invoice/11111111-1111-4111-8111-111111111111/33333333-3333-4333-8333-333333333333.pdf';
  fresh_pdf text := 'dispatch/11111111-1111-4111-8111-111111111111/44444444-4444-4444-8444-444444444444.pdf';
  operator_file text := 'archive/2025-price-list.pdf';
  listed text[];
BEGIN
  IF (SELECT days FROM warehouse_maintenance.retention_policy WHERE key = 'generated_documents') <> 7 THEN
    RAISE EXCEPTION 'Generated documents are kept for 7 days by default';
  END IF;
  INSERT INTO storage.objects(bucket_id, name, created_at) VALUES
    ('documents', old_pdf, now() - interval '30 days'),
    ('documents', week_old_pdf, now() - interval '6 days 23 hours'),
    -- the link of this one is still valid for most of its hour
    ('documents', fresh_pdf, now() - interval '5 minutes'),
    ('documents', operator_file, now() - interval '300 days'),
    ('grn-images', 'headers/11111111-1111-4111-8111-111111111111/old.webp', now() - interval '300 days');
  SELECT array_agg(name) INTO listed FROM warehouse_maintenance.expired_generated_documents(now()) AS name;
  IF listed IS DISTINCT FROM ARRAY[old_pdf] THEN RAISE EXCEPTION 'Expected only the 30-day-old PDF, got %', listed; END IF;
  -- A link lives one hour, so even the shortest policy keeps a document far longer than its link.
  UPDATE warehouse_maintenance.retention_policy SET days = 1 WHERE key = 'generated_documents';
  SELECT array_agg(name) INTO listed FROM warehouse_maintenance.expired_generated_documents(now()) AS name;
  IF listed IS DISTINCT FROM ARRAY[old_pdf, week_old_pdf] THEN RAISE EXCEPTION 'Expected both old PDFs under a 1-day policy, got %', listed; END IF;
  IF has_function_privilege('authenticated', 'warehouse_maintenance.expired_generated_documents(timestamptz)', 'EXECUTE') THEN
    RAISE EXCEPTION 'The expired-document list is not for the app role';
  END IF;
  -- The database function never deletes: the Storage API removes file and row together.
  IF (SELECT count(*) FROM storage.objects WHERE bucket_id = 'documents') <> 4 THEN RAISE EXCEPTION 'Listing changed stored objects'; END IF;
END $$;
ROLLBACK;
SELECT 'retention preview/apply boundary and expired generated documents passed' AS result;
