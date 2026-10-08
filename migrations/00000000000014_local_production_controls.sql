-- Local retention and Realtime controls. Operators must explicitly run retention.
CREATE SCHEMA warehouse_maintenance;
REVOKE ALL ON SCHEMA warehouse_maintenance FROM PUBLIC, anon, authenticated;

CREATE TABLE warehouse_maintenance.retention_policy (
  key text PRIMARY KEY,
  days integer NOT NULL CHECK (days BETWEEN 1 AND 3650),
  description text NOT NULL
);
INSERT INTO warehouse_maintenance.retention_policy(key, days, description) VALUES
  ('ephemeral_auth', 7, 'Expired OTP, rate-limit, idempotency, and refresh-token records'),
  ('session_activity', 30, 'Inactive session activity'),
  ('security_logs', 90, 'Authentication, configuration-access, and intrusion events');

CREATE FUNCTION warehouse_maintenance.run_database_retention(
  p_now timestamptz DEFAULT now(), p_apply boolean DEFAULT false
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, public, warehouse_security, warehouse_maintenance
AS $$
DECLARE
  auth_cutoff timestamptz;
  activity_cutoff timestamptz;
  log_cutoff timestamptz;
  result jsonb := '{}'::jsonb;
  affected bigint;
BEGIN
  SELECT p_now - make_interval(days => days) INTO auth_cutoff
    FROM warehouse_maintenance.retention_policy WHERE key = 'ephemeral_auth';
  SELECT p_now - make_interval(days => days) INTO activity_cutoff
    FROM warehouse_maintenance.retention_policy WHERE key = 'session_activity';
  SELECT p_now - make_interval(days => days) INTO log_cutoff
    FROM warehouse_maintenance.retention_policy WHERE key = 'security_logs';

  IF p_apply THEN
    DELETE FROM warehouse_security.consumed_refresh_tokens WHERE expires_at < p_now;
    GET DIAGNOSTICS affected = ROW_COUNT; result := result || jsonb_build_object('consumed_refresh_tokens', affected);
    DELETE FROM warehouse_security.refresh_sessions WHERE expires_at < p_now;
    GET DIAGNOSTICS affected = ROW_COUNT; result := result || jsonb_build_object('refresh_sessions', affected);
    DELETE FROM public.otp_verifications WHERE expires_at < auth_cutoff;
    GET DIAGNOSTICS affected = ROW_COUNT; result := result || jsonb_build_object('otp_verifications', affected);
    DELETE FROM public.otp_rate_limits WHERE updated_at < auth_cutoff;
    GET DIAGNOSTICS affected = ROW_COUNT; result := result || jsonb_build_object('otp_rate_limits', affected);
    DELETE FROM public.ip_rate_limits WHERE updated_at < auth_cutoff;
    GET DIAGNOSTICS affected = ROW_COUNT; result := result || jsonb_build_object('ip_rate_limits', affected);
    DELETE FROM public.idempotency_keys WHERE COALESCE(expires_at, created_at) < p_now;
    GET DIAGNOSTICS affected = ROW_COUNT; result := result || jsonb_build_object('idempotency_keys', affected);
    DELETE FROM public.user_session_activity WHERE last_activity_at < activity_cutoff;
    GET DIAGNOSTICS affected = ROW_COUNT; result := result || jsonb_build_object('user_session_activity', affected);
    DELETE FROM public.auth_logs WHERE created_at < log_cutoff;
    GET DIAGNOSTICS affected = ROW_COUNT; result := result || jsonb_build_object('auth_logs', affected);
    DELETE FROM public.config_access_logs WHERE accessed_at < log_cutoff;
    GET DIAGNOSTICS affected = ROW_COUNT; result := result || jsonb_build_object('config_access_logs', affected);
    DELETE FROM public.intrusion_events WHERE recorded_at < log_cutoff;
    GET DIAGNOSTICS affected = ROW_COUNT; result := result || jsonb_build_object('intrusion_events', affected);
  ELSE
    SELECT result || jsonb_build_object(
      'consumed_refresh_tokens', (SELECT count(*) FROM warehouse_security.consumed_refresh_tokens WHERE expires_at < p_now),
      'refresh_sessions', (SELECT count(*) FROM warehouse_security.refresh_sessions WHERE expires_at < p_now),
      'otp_verifications', (SELECT count(*) FROM public.otp_verifications WHERE expires_at < auth_cutoff),
      'otp_rate_limits', (SELECT count(*) FROM public.otp_rate_limits WHERE updated_at < auth_cutoff),
      'ip_rate_limits', (SELECT count(*) FROM public.ip_rate_limits WHERE updated_at < auth_cutoff),
      'idempotency_keys', (SELECT count(*) FROM public.idempotency_keys WHERE COALESCE(expires_at, created_at) < p_now),
      'user_session_activity', (SELECT count(*) FROM public.user_session_activity WHERE last_activity_at < activity_cutoff),
      'auth_logs', (SELECT count(*) FROM public.auth_logs WHERE created_at < log_cutoff),
      'config_access_logs', (SELECT count(*) FROM public.config_access_logs WHERE accessed_at < log_cutoff),
      'intrusion_events', (SELECT count(*) FROM public.intrusion_events WHERE recorded_at < log_cutoff)
    ) INTO result;
  END IF;
  RETURN jsonb_build_object('applied', p_apply, 'as_of', p_now, 'rows', result);
END $$;

REVOKE ALL ON ALL TABLES IN SCHEMA warehouse_maintenance FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION warehouse_maintenance.run_database_retention(timestamptz, boolean) FROM PUBLIC, anon, authenticated;
GRANT USAGE ON SCHEMA warehouse_maintenance TO service_role;
GRANT SELECT ON warehouse_maintenance.retention_policy TO service_role;
GRANT EXECUTE ON FUNCTION warehouse_maintenance.run_database_retention(timestamptz, boolean) TO service_role;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_publication WHERE pubname = 'supabase_realtime') THEN
    CREATE PUBLICATION supabase_realtime;
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM pg_publication_tables
    WHERE pubname = 'supabase_realtime' AND schemaname = 'public' AND tablename = 'orders'
  ) THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.orders;
  END IF;
END $$;
ALTER TABLE public.orders REPLICA IDENTITY FULL;
