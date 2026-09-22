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
SELECT 'retention preview/apply boundary passed' AS result;
