-- Sensor temperature limits (migration 111): update_sensor_device sets and clears them in
-- alert_config, sensor_status says HIGH or LOW, and the two readers send temperature_alert.
--
-- Fixture, all times relative to the transaction's now():
--   L1 'Limit Chamber'  hub online, values 5 minutes old, threshold 30; 4.00 degrees C
--   L2 'Quiet Chamber'  values 3 hours old, threshold 30; 40.00 degrees C (above any limit set below)
--
-- What a wrong implementation would show: limits stored by the four-argument call alone (the
-- old call must leave them untouched); a lowest limit equal to the highest accepted; a quiet
-- sensor flagged "HIGH" from a reading that is hours old; a clear that keeps one limit.
-- Runs ONLY in migrations.sh's fresh, network-disabled database. All fixture rows roll back.
\set ON_ERROR_STOP on
BEGIN;
CREATE FUNCTION pg_temp.sl_assert(ok boolean, label text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF NOT COALESCE(ok, false) THEN RAISE EXCEPTION 'sensor limits: %', label; END IF; END $$;
CREATE FUNCTION pg_temp.sl_login(phone text) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE challenge jsonb; login jsonb; claims jsonb;
BEGIN
  challenge := public.operator_prepare_otp(phone);
  PERFORM public.operator_finish_otp((challenge#>>'{data,request_id}')::uuid, true, 'mock-provider-only');
  login := public.operator_verify_otp(phone, challenge#>>'{data,otp_code}');
  PERFORM pg_temp.sl_assert(login#>>'{data,action}' = 'login', 'login ' || phone);
  SELECT jsonb_build_object('role', 'authenticated', 'sub', p.auth_user_id, 'session_id', s.id)
    INTO claims FROM public.user_profiles p JOIN warehouse_security.refresh_sessions s ON s.user_id = p.auth_user_id
    WHERE p.mobile = warehouse_security.normalize_phone(phone) ORDER BY s.created_at DESC LIMIT 1;
  RETURN claims;
END $$;
CREATE FUNCTION pg_temp.sl_call(statement text) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE answer jsonb;
BEGIN
  BEGIN EXECUTE statement INTO answer;
  EXCEPTION WHEN OTHERS THEN RETURN jsonb_build_object('raised', SQLERRM, 'state', SQLSTATE); END;
  RETURN answer;
END $$;
CREATE FUNCTION pg_temp.sl_row(arr jsonb, key_value text) RETURNS jsonb LANGUAGE sql AS $$
  SELECT x FROM jsonb_array_elements(arr) AS t(x) WHERE x->>'id' = key_value $$;

-- Objects: one function of that name, the new signature, the old grants, the guard first.
SELECT pg_temp.sl_assert((SELECT count(*) FROM pg_proc WHERE proname = 'update_sensor_device') = 1
    AND to_regprocedure('public.update_sensor_device(uuid,text,text,integer)') IS NULL
    AND to_regprocedure('public.update_sensor_device(uuid,text,text,integer,numeric,numeric,boolean)') IS NOT NULL,
  'update_sensor_device has one signature, the seven-parameter one');
SELECT pg_temp.sl_assert(p.prosecdef
    AND p.proconfig = ARRAY['search_path=pg_catalog, public, extensions, utils, pg_temp']
    AND pg_get_functiondef(p.oid) ~ 'BEGIN\s+PERFORM warehouse_security\.authorize_rpc\(''update_sensor_device'','
    AND pg_get_functiondef(p.oid) !~* 'WHEN\s+OTHERS'
    AND has_function_privilege('authenticated', p.oid, 'EXECUTE') AND has_function_privilege('service_role', p.oid, 'EXECUTE')
    AND NOT has_function_privilege('anon', p.oid, 'EXECUTE')
    AND NOT EXISTS (SELECT 1 FROM aclexplode(p.proacl) a WHERE a.grantee = 0),
  'update_sensor_device: SECURITY DEFINER, pinned search_path, guard first, granted as before')
FROM pg_proc p WHERE p.proname = 'update_sensor_device';
SELECT pg_temp.sl_assert((SELECT column_name FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'sensor_status' ORDER BY ordinal_position DESC LIMIT 1) = 'temperature_alert',
  'sensor_status ends with temperature_alert');

-- People and sensors.
INSERT INTO warehouse_security.auth_config(key, value) VALUES
 ('jwt_secret', 'isolated-test-secret-not-for-any-deployment-12345'), ('auth_mode', 'operator'), ('demo_auth_enabled', 'false')
 ON CONFLICT(key) DO UPDATE SET value = excluded.value;
UPDATE public.sms_config SET provider = 'msg91', production_mode = true, msg91_auth_key = 'isolated-test-key',
 msg91_template_id = '000000000000000000000001', msg91_pe_id = '0000000000000000001', msg91_sender_id = 'CITEST';
SELECT warehouse_security.bootstrap_first_admin('9888887501', 'Sensor Limits Administrator');
INSERT INTO public.user_profiles(auth_user_id, mobile, name, role, active, enrollment_status) VALUES
 (gen_random_uuid(), '919888887502', 'Sensor Limits Supervisor', 'supervisor', true, 'approved');
SELECT pg_temp.sl_login('9888887501') AS admin_claims \gset
SELECT pg_temp.sl_login('9888887502') AS supervisor_claims \gset
INSERT INTO public.sensor_hubs(hub_id, online, last_seen_at, last_change_at) VALUES ('HUBLIMIT01', true, now(), now());
INSERT INTO public.sensor_devices(device_name, hub_id, external_id, staleness_threshold_minutes, last_seen_at)
VALUES ('Limit Chamber', 'HUBLIMIT01', repeat('A', 40), 30, now() - interval '5 minutes'),
       ('Quiet Chamber', 'HUBLIMIT01', repeat('B', 40), 30, now() - interval '3 hours');
SELECT id AS d1 FROM public.sensor_devices WHERE device_name = 'Limit Chamber' \gset
SELECT id AS d2 FROM public.sensor_devices WHERE device_name = 'Quiet Chamber' \gset
INSERT INTO public.sensor_latest(device_id, device_name, hub_id, temperature, humidity, measured_at, temperature_at, humidity_at, last_seen_at)
VALUES (:'d1'::uuid, 'Limit Chamber', 'HUBLIMIT01', 4.00, 60, now() - interval '5 minutes', now() - interval '5 minutes', now() - interval '5 minutes', now() - interval '5 minutes'),
       (:'d2'::uuid, 'Quiet Chamber', 'HUBLIMIT01', 40.00, 60, now() - interval '3 hours', now() - interval '3 hours', now() - interval '3 hours', now() - interval '3 hours');

-- No limits yet: no alert for either.
SELECT set_config('request.jwt.claims', :'admin_claims', true);
SET LOCAL ROLE authenticated;
SELECT public.get_sensor_polling_data() AS poll_none \gset
RESET ROLE;
SELECT pg_temp.sl_assert((SELECT bool_and(x ? 'temperature_alert' AND x->'temperature_alert' = 'null'::jsonb)
    FROM jsonb_array_elements(:'poll_none'::jsonb->'devices') x),
  'before any limit, every sensor sends temperature_alert null: ' || :'poll_none');

-- The quiet sensor gets limits its 40 degrees would break, so only its age keeps it unflagged.
SET LOCAL ROLE authenticated;
SELECT public.update_sensor_device(:'d2'::uuid, NULL, NULL, NULL, 5, 8, true) AS quiet_limits \gset
RESET ROLE;
SELECT pg_temp.sl_assert(:'quiet_limits'::jsonb->>'success' = 'true', 'limits set on the quiet sensor: ' || :'quiet_limits');

-- Setting limits.
SET LOCAL ROLE authenticated;
SELECT public.update_sensor_device(:'d1'::uuid, NULL, NULL, NULL, 5, 8, true) AS set_above \gset
SELECT public.update_sensor_device(:'d1'::uuid, NULL, NULL, NULL, 5, 5, true) AS equal_limits \gset
SELECT public.update_sensor_device(:'d1'::uuid, NULL, NULL, NULL, 9, 3, true) AS swapped_limits \gset
SELECT public.update_sensor_device(:'d1'::uuid, NULL, NULL, NULL, -200, 3, true) AS far_limit \gset
SELECT public.get_sensor_polling_data() AS poll_low \gset
SELECT public.get_sensor_device(:'d1'::uuid) AS device_low \gset
RESET ROLE;
SELECT pg_temp.sl_assert(:'set_above'::jsonb->>'success' = 'true'
    AND :'equal_limits'::jsonb->>'error_code' = 'INVALID_TEMPERATURE_LIMIT'
    AND :'swapped_limits'::jsonb->>'error_code' = 'INVALID_TEMPERATURE_LIMIT'
    AND :'far_limit'::jsonb->>'error_code' = 'INVALID_TEMPERATURE_LIMIT',
  'limits 5 to 8 are set; equal, swapped and out-of-range limits are refused: ' || :'set_above' || :'equal_limits');
SELECT pg_temp.sl_assert((SELECT alert_config FROM public.sensor_devices WHERE id = :'d1'::uuid) = '{"temperature_min":5,"temperature_max":8}'::jsonb,
  'the limits are stored in alert_config');
SELECT pg_temp.sl_assert(pg_temp.sl_row(:'poll_low'::jsonb->'devices', :'d1')->>'temperature_alert' = 'LOW'
    AND :'device_low'::jsonb#>>'{data,temperature_alert}' = 'LOW',
  '4 degrees under a lowest of 5 is LOW, in the list and for the one sensor: ' || :'device_low');
SELECT pg_temp.sl_assert(pg_temp.sl_row(:'poll_low'::jsonb->'devices', :'d2')->>'temperature_alert' IS NULL,
  'the quiet sensor sends no alert: ' || pg_temp.sl_row(:'poll_low'::jsonb->'devices', :'d2')::text);

-- A sensor whose hub is offline sends no alert either, however far out its temperature is.
UPDATE public.sensor_latest SET temperature = 9.50, temperature_at = now() - interval '1 minute' WHERE device_id = :'d1'::uuid;
UPDATE public.sensor_hubs SET online = false WHERE hub_id = 'HUBLIMIT01';
SET LOCAL ROLE authenticated;
SELECT public.get_sensor_polling_data() AS poll_hub_off \gset
RESET ROLE;
UPDATE public.sensor_hubs SET online = true WHERE hub_id = 'HUBLIMIT01';
UPDATE public.sensor_latest SET temperature = 4.00 WHERE device_id = :'d1'::uuid;
SELECT pg_temp.sl_assert(pg_temp.sl_row(:'poll_hub_off'::jsonb->'devices', :'d1')->>'temperature_alert' IS NULL,
  'a sensor whose hub is offline sends no alert: ' || pg_temp.sl_row(:'poll_hub_off'::jsonb->'devices', :'d1')::text);

-- The old four-argument call leaves the limits alone; a new reading above the highest limit is HIGH.
SET LOCAL ROLE authenticated;
SELECT public.update_sensor_device(:'d1'::uuid, 'Limit Chamber 1', NULL, 45) AS old_call \gset
RESET ROLE;
UPDATE public.sensor_latest SET temperature = 9.50 WHERE device_id = :'d1'::uuid;
SET LOCAL ROLE authenticated;
SELECT public.get_sensor_polling_data() AS poll_high \gset
RESET ROLE;
SELECT pg_temp.sl_assert((SELECT alert_config FROM public.sensor_devices WHERE id = :'d1'::uuid) = '{"temperature_min":5,"temperature_max":8}'::jsonb
    AND pg_temp.sl_row(:'poll_high'::jsonb->'devices', :'d1')->>'temperature_alert' = 'HIGH'
    AND pg_temp.sl_row(:'poll_high'::jsonb->'devices', :'d1')->>'device_name' = 'Limit Chamber 1',
  '9.5 over a highest of 8 is HIGH, and a call without limits kept them: ' || :'old_call');

-- Clearing one limit and then both; other keys of alert_config stay.
UPDATE public.sensor_devices SET alert_config = alert_config || '{"note":"kept"}' WHERE id = :'d1'::uuid;
SET LOCAL ROLE authenticated;
SELECT public.update_sensor_device(:'d1'::uuid, NULL, NULL, NULL, 5, NULL, true) AS only_min \gset
SELECT public.get_sensor_polling_data() AS poll_only_min \gset
SELECT public.update_sensor_device(:'d1'::uuid, NULL, NULL, NULL, NULL, NULL, true) AS no_limits \gset
SELECT public.get_sensor_polling_data() AS poll_cleared \gset
RESET ROLE;
SELECT pg_temp.sl_assert(pg_temp.sl_row(:'poll_only_min'::jsonb->'devices', :'d1')->>'temperature_alert' IS NULL
    AND pg_temp.sl_row(:'poll_cleared'::jsonb->'devices', :'d1')->>'temperature_alert' IS NULL
    AND (SELECT alert_config FROM public.sensor_devices WHERE id = :'d1'::uuid) = '{"note":"kept"}'::jsonb,
  'a cleared highest sends no HIGH at 9.5; clearing both leaves only the other keys: '
    || (SELECT alert_config::text FROM public.sensor_devices WHERE id = :'d1'::uuid));

-- A supervisor still may not change a sensor.
SELECT set_config('request.jwt.claims', :'supervisor_claims', true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.sl_call(format('SELECT public.update_sensor_device(%L::uuid, NULL, NULL, NULL, 1, 2, true)', :'d1')) AS supervisor_set \gset
RESET ROLE;
SELECT pg_temp.sl_assert(:'supervisor_set'::jsonb->>'state' = '42501' AND :'supervisor_set'::jsonb->>'raised' = 'Administrator required',
  'a supervisor may not set limits: ' || :'supervisor_set');

ROLLBACK;
