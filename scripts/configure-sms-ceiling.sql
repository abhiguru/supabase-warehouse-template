\set ON_ERROR_STOP on
-- The facility-wide spending ceilings on SMS sign-in codes (WH-119; docs/OPERATOR_INSTALL.md, "SMS spending ceiling").
-- setup.sh passes the psql variables sms_hourly (--sms-hourly-ceiling) and sms_daily (--sms-daily-ceiling); empty = not given.
--   * auth_config `otp_global_hourly_cap`: codes an hour for the whole facility (operator_prepare_otp: 300 when the key is absent).
--   * auth_config `otp_daily_provider_attempt_cap`: MSG91 requests in any 24 hours (migration 97; none when the key is absent). A code
--     costs one request, two when the function repeats a request after a 429, 502, 503 or 504.
-- A value that is given is stored. A value that is not given is stored as the default (60 an hour, 300 a day) only when the key is
-- absent AND this database has never made a sign-in code: a new install gets the defaults, and an existing facility keeps the figure it
-- has (or the absence of one; the upgrade notes say how to set it). A rerun with the same values changes nothing.
\if :{?sms_hourly}
\else
  \set sms_hourly ''
\endif
\if :{?sms_daily}
\else
  \set sms_daily ''
\endif
SELECT :'sms_hourly' = '' OR :'sms_hourly' ~ '^[1-9][0-9]{0,5}$' AS hourly_valid,
  :'sms_daily' = '' OR :'sms_daily' ~ '^[1-9][0-9]{0,6}$' AS daily_valid \gset
\if :hourly_valid
\else
  DO $$ BEGIN RAISE EXCEPTION 'The hourly SMS ceiling must be a whole number from 1 to 999999'; END $$;
\endif
\if :daily_valid
\else
  DO $$ BEGIN RAISE EXCEPTION 'The daily SMS ceiling must be a whole number from 1 to 9999999'; END $$;
\endif
BEGIN;
SELECT pg_advisory_xact_lock(71046);
SELECT NOT EXISTS (SELECT 1 FROM public.otp_verifications) AS never_sent \gset
-- Hourly
SELECT (:'sms_hourly' <> '') AS hourly_given \gset
\if :hourly_given
  INSERT INTO warehouse_security.auth_config(key,value) VALUES ('otp_global_hourly_cap',:'sms_hourly')
  ON CONFLICT(key) DO UPDATE SET value=excluded.value WHERE warehouse_security.auth_config.value IS DISTINCT FROM excluded.value;
\elif :never_sent
  INSERT INTO warehouse_security.auth_config(key,value) VALUES ('otp_global_hourly_cap','60') ON CONFLICT(key) DO NOTHING;
\endif
-- Daily
SELECT (:'sms_daily' <> '') AS daily_given \gset
\if :daily_given
  INSERT INTO warehouse_security.auth_config(key,value) VALUES ('otp_daily_provider_attempt_cap',:'sms_daily')
  ON CONFLICT(key) DO UPDATE SET value=excluded.value WHERE warehouse_security.auth_config.value IS DISTINCT FROM excluded.value;
\elif :never_sent
  INSERT INTO warehouse_security.auth_config(key,value) VALUES ('otp_daily_provider_attempt_cap','300') ON CONFLICT(key) DO NOTHING;
\endif
COMMIT;
