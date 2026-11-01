-- Migration 136: the hourly sensor summary (sensor_hourly), its roll-up, the retention changes and get_sensor_hourly.
-- Fictional data; runs only in migrations.sh's disposable, network-disabled database; every block rolls back.
\set ON_ERROR_STOP on

-- 0. Structure, policy row and grants.
BEGIN;
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM warehouse_maintenance.retention_policy WHERE key = 'sensor_hourly' AND days = 730
       AND description = 'Hourly sensor summary (min, max and average per device), kept 24 months') THEN
    RAISE EXCEPTION 'sensor hourly: the policy row sensor_hourly with 730 days is missing';
  END IF;
  IF NOT (SELECT relrowsecurity FROM pg_class WHERE oid = 'public.sensor_hourly'::regclass) THEN
    RAISE EXCEPTION 'sensor hourly: row security is not enabled';
  END IF;
  IF has_table_privilege('anon', 'public.sensor_hourly', 'SELECT') OR has_table_privilege('authenticated', 'public.sensor_hourly', 'SELECT')
     OR has_table_privilege('authenticated', 'public.sensor_hourly', 'INSERT') OR NOT has_table_privilege('service_role', 'public.sensor_hourly', 'SELECT') THEN
    RAISE EXCEPTION 'sensor hourly: table grants are not service_role only';
  END IF;
  IF has_function_privilege('anon', 'public.get_sensor_hourly(uuid,timestamptz,timestamptz)', 'EXECUTE')
     OR NOT has_function_privilege('authenticated', 'public.get_sensor_hourly(uuid,timestamptz,timestamptz)', 'EXECUTE')
     OR NOT has_function_privilege('service_role', 'public.get_sensor_hourly(uuid,timestamptz,timestamptz)', 'EXECUTE')
     OR has_function_privilege('authenticated', 'warehouse_maintenance.rollup_sensor_hourly(timestamptz,boolean)', 'EXECUTE')
     OR NOT has_function_privilege('service_role', 'warehouse_maintenance.rollup_sensor_hourly(timestamptz,boolean)', 'EXECUTE') THEN
    RAISE EXCEPTION 'sensor hourly: function grants are wrong';
  END IF;
  IF NOT (SELECT prosrc ~ 'authorize_rpc\(''get_sensor_hourly''' FROM pg_proc WHERE oid = 'public.get_sensor_hourly(uuid,timestamptz,timestamptz)'::regprocedure) THEN
    RAISE EXCEPTION 'sensor hourly: get_sensor_hourly does not call authorize_rpc first';
  END IF;
END $$;
ROLLBACK;

-- 1. The roll-up.
BEGIN;
CREATE FUNCTION pg_temp.sh_assert(ok boolean, label text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF NOT COALESCE(ok, false) THEN RAISE EXCEPTION 'sensor hourly: %', label; END IF; END $$;
DELETE FROM public.sensor_readings;
DELETE FROM public.sensor_hourly;
INSERT INTO public.sensor_devices(id, device_name, location) VALUES
 ('00000000-0000-4000-8000-0000000136d1', 'Hourly Chamber One', 'Chamber 1'),
 ('00000000-0000-4000-8000-0000000136d2', 'Hourly Chamber Two', 'Chamber 2');
INSERT INTO public.sensor_readings(device_id, temperature, humidity, measured_at) VALUES
 ('00000000-0000-4000-8000-0000000136d1', 3.00, 60.00, '2026-10-31T08:05:00Z'),
 ('00000000-0000-4000-8000-0000000136d1', 5.00, 70.00, '2026-10-31T08:25:00Z'),
 ('00000000-0000-4000-8000-0000000136d1', 4.00, 65.50, '2026-10-31T08:55:00Z'),
 ('00000000-0000-4000-8000-0000000136d1', 2.50, NULL,  '2026-10-31T09:10:00Z'),
 ('00000000-0000-4000-8000-0000000136d1', 6.00, 55.00, '2026-11-01T09:59:00Z'),
 ('00000000-0000-4000-8000-0000000136d1', 7.00, 56.00, '2026-11-01T10:05:00Z'),
 ('00000000-0000-4000-8000-0000000136d2', 10.00, NULL, '2026-10-31T08:30:00Z'),
 ('00000000-0000-4000-8000-0000000136d2', 12.00, NULL, '2026-10-31T08:40:00Z');

-- The preview counts and writes nothing: 3 hours of device one and 1 of device two; 10:30 is inside the hour 10:00, which is not over.
SELECT pg_temp.sh_assert(warehouse_maintenance.rollup_sensor_hourly('2026-11-01T10:30:00Z', false) = 4
  AND (SELECT count(*) FROM public.sensor_hourly) = 0, 'preview counts 4 hours and writes nothing');
SELECT pg_temp.sh_assert(warehouse_maintenance.rollup_sensor_hourly('2026-11-01T10:30:00Z') = 4, 'apply rolls 4 hours');
SELECT pg_temp.sh_assert((SELECT count(*) FROM public.sensor_hourly) = 4, 'four rows');
-- Values per device and hour.
SELECT pg_temp.sh_assert(EXISTS (SELECT 1 FROM public.sensor_hourly WHERE device_id = '00000000-0000-4000-8000-0000000136d1'
    AND hour = '2026-10-31T08:00:00Z' AND n = 3 AND t_min = 3.00 AND t_max = 5.00 AND t_avg = 4.00
    AND h_min = 60.00 AND h_max = 70.00 AND h_avg = 65.17), 'device one 08:00: n, min, max, avg of both values');
SELECT pg_temp.sh_assert(EXISTS (SELECT 1 FROM public.sensor_hourly WHERE device_id = '00000000-0000-4000-8000-0000000136d1'
    AND hour = '2026-10-31T09:00:00Z' AND n = 1 AND t_min = 2.50 AND t_max = 2.50 AND t_avg = 2.50
    AND h_min IS NULL AND h_max IS NULL AND h_avg IS NULL), 'device one 09:00: no humidity gives NULLs');
SELECT pg_temp.sh_assert(EXISTS (SELECT 1 FROM public.sensor_hourly WHERE device_id = '00000000-0000-4000-8000-0000000136d1'
    AND hour = '2026-11-01T09:00:00Z' AND n = 1 AND t_avg = 6.00 AND h_avg = 55.00), 'device one on 1 Nov 09:00');
SELECT pg_temp.sh_assert(EXISTS (SELECT 1 FROM public.sensor_hourly WHERE device_id = '00000000-0000-4000-8000-0000000136d2'
    AND hour = '2026-10-31T08:00:00Z' AND n = 2 AND t_min = 10.00 AND t_max = 12.00 AND t_avg = 11.00), 'device two has its own row');
-- The hour in progress is not rolled, at 10:59:59 as at 10:30.
SELECT pg_temp.sh_assert(NOT EXISTS (SELECT 1 FROM public.sensor_hourly WHERE hour = '2026-11-01T10:00:00Z'), 'the current partial hour is not rolled');
SELECT warehouse_maintenance.rollup_sensor_hourly('2026-11-01T10:59:59Z');
SELECT pg_temp.sh_assert(NOT EXISTS (SELECT 1 FROM public.sensor_hourly WHERE hour = '2026-11-01T10:00:00Z'), 'still not rolled at 10:59:59');
-- Idempotent: the next run changes no value (it only reads the last rolled hour again).
SELECT md5(string_agg(h::text, '|' ORDER BY device_id, hour)) AS before_hash FROM public.sensor_hourly h \gset
SELECT warehouse_maintenance.rollup_sensor_hourly('2026-11-01T10:30:00Z') AS again \gset
SELECT pg_temp.sh_assert(:again <= 2 AND (SELECT md5(string_agg(h::text, '|' ORDER BY device_id, hour)) FROM public.sensor_hourly h) = :'before_hash'
  AND (SELECT count(*) FROM public.sensor_hourly) = 4, 'a second run changes nothing');
-- A late reading in the last rolled hour is folded in.
INSERT INTO public.sensor_readings(device_id, temperature, humidity, measured_at)
 VALUES ('00000000-0000-4000-8000-0000000136d1', 1.00, 50.00, '2026-11-01T09:30:00Z');
SELECT warehouse_maintenance.rollup_sensor_hourly('2026-11-01T10:30:00Z');
SELECT pg_temp.sh_assert(EXISTS (SELECT 1 FROM public.sensor_hourly WHERE device_id = '00000000-0000-4000-8000-0000000136d1'
    AND hour = '2026-11-01T09:00:00Z' AND n = 2 AND t_min = 1.00 AND t_max = 6.00 AND t_avg = 3.50 AND h_min = 50.00 AND h_max = 55.00 AND h_avg = 52.50),
  'a late reading in the last rolled hour is folded in');
-- The hour that has just ended is rolled at its end (boundary).
SELECT warehouse_maintenance.rollup_sensor_hourly('2026-11-01T11:00:00Z');
SELECT pg_temp.sh_assert(EXISTS (SELECT 1 FROM public.sensor_hourly WHERE device_id = '00000000-0000-4000-8000-0000000136d1'
    AND hour = '2026-11-01T10:00:00Z' AND n = 1 AND t_avg = 7.00), 'at 11:00:00 the hour 10:00 is rolled');
-- An hour whose raw rows were partly removed never replaces a larger count.
DELETE FROM public.sensor_readings WHERE measured_at = '2026-11-01T09:30:00Z';
UPDATE public.sensor_hourly SET n = 2, t_min = 1.00 WHERE device_id = '00000000-0000-4000-8000-0000000136d1' AND hour = '2026-11-01T10:00:00Z';
SELECT warehouse_maintenance.rollup_sensor_hourly('2026-11-01T11:00:00Z');
SELECT pg_temp.sh_assert(EXISTS (SELECT 1 FROM public.sensor_hourly WHERE device_id = '00000000-0000-4000-8000-0000000136d1'
    AND hour = '2026-11-01T10:00:00Z' AND n = 2 AND t_min = 1.00), 'a smaller recount does not replace a larger row');
ROLLBACK;

-- 2. At most 2,000 hours per call, and a long gap does not stop the roll-up.
BEGIN;
CREATE FUNCTION pg_temp.sh_assert(ok boolean, label text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF NOT COALESCE(ok, false) THEN RAISE EXCEPTION 'sensor hourly: %', label; END IF; END $$;
DELETE FROM public.sensor_readings;
DELETE FROM public.sensor_hourly;
INSERT INTO public.sensor_devices(id, device_name) VALUES ('00000000-0000-4000-8000-0000000136d3', 'Hourly Backlog');
INSERT INTO public.sensor_readings(device_id, temperature, measured_at)
  SELECT '00000000-0000-4000-8000-0000000136d3', 4.00, timestamptz '2026-01-01T00:10:00Z' + g * interval '1 hour' FROM generate_series(0, 2004) g;
-- a gap of 4,000 hours, then one more hour
INSERT INTO public.sensor_readings(device_id, temperature, measured_at)
  VALUES ('00000000-0000-4000-8000-0000000136d3', 4.00, '2027-01-01T00:10:00Z');
SELECT warehouse_maintenance.rollup_sensor_hourly('2027-02-01T00:00:00Z') AS first_call \gset
SELECT pg_temp.sh_assert(:first_call = 2000 AND (SELECT count(*) FROM public.sensor_hourly) = 2000, 'the first call rolls 2,000 hours: ' || :first_call);
SELECT warehouse_maintenance.rollup_sensor_hourly('2027-02-01T00:00:00Z') AS second_call \gset
SELECT pg_temp.sh_assert(:second_call >= 1 AND (SELECT count(*) FROM public.sensor_hourly) = 2006, 'the second call rolls the other 6 hours, gap included: ' || :second_call);
ROLLBACK;

-- 3. Retention: roll up first, then delete the raw readings older than 90 days; the summary survives; the old summary goes.
BEGIN;
CREATE FUNCTION pg_temp.sh_assert(ok boolean, label text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF NOT COALESCE(ok, false) THEN RAISE EXCEPTION 'sensor hourly: %', label; END IF; END $$;
DELETE FROM public.sensor_readings;
DELETE FROM public.sensor_hourly;
INSERT INTO public.sensor_devices(id, device_name) VALUES ('00000000-0000-4000-8000-0000000136d1', 'Hourly Chamber One');
-- p_now 2026-11-01T10:30Z: the raw cutoff is 2026-08-03T10:30Z, the summary cutoff 2024-11-01T10:30Z.
INSERT INTO public.sensor_readings(device_id, temperature, humidity, measured_at) VALUES
 ('00000000-0000-4000-8000-0000000136d1', 8.00, 40.00, '2026-07-01T12:10:00Z'),
 ('00000000-0000-4000-8000-0000000136d1', 10.00, 44.00, '2026-07-01T12:40:00Z'),
 ('00000000-0000-4000-8000-0000000136d1', 3.00, 61.00, '2026-10-31T08:05:00Z');
INSERT INTO public.sensor_hourly(device_id, hour, n, t_min, t_max, t_avg) VALUES
 ('00000000-0000-4000-8000-0000000136d1', '2024-06-01T00:00:00Z', 5, 1, 2, 1.5),
 ('00000000-0000-4000-8000-0000000136d1', '2024-12-01T00:00:00Z', 5, 1, 2, 1.5);
-- Preview: counts, writes nothing.
SELECT warehouse_maintenance.run_database_retention('2026-11-01T10:30:00Z', false) AS preview \gset
SELECT pg_temp.sh_assert((:'preview'::jsonb->>'applied')::boolean = false
  AND (:'preview'::jsonb#>>'{rows,sensor_hourly_rolled}')::int = 2   -- 2026-07-01 12:00 and 2026-10-31 08:00
  AND (:'preview'::jsonb#>>'{rows,sensor_hourly}')::int = 1 AND (:'preview'::jsonb#>>'{rows,sensor_readings}')::int = 2,
  'preview reports 2 to roll, 1 old summary row, 2 raw rows: ' || :'preview');
SELECT pg_temp.sh_assert((SELECT count(*) FROM public.sensor_readings) = 3 AND (SELECT count(*) FROM public.sensor_hourly) = 2,
  'preview changed nothing');
-- Apply.
SELECT warehouse_maintenance.run_database_retention('2026-11-01T10:30:00Z', true) AS applied \gset
SELECT pg_temp.sh_assert((:'applied'::jsonb#>>'{rows,sensor_hourly_rolled}')::int = 2 AND (:'applied'::jsonb#>>'{rows,sensor_hourly}')::int = 1
  AND (:'applied'::jsonb#>>'{rows,sensor_readings}')::int = 2, 'apply reports 2 rolled, 1 old summary row, 2 raw rows: ' || :'applied');
SELECT pg_temp.sh_assert((SELECT count(*) FROM public.sensor_readings) = 1
  AND EXISTS (SELECT 1 FROM public.sensor_readings WHERE measured_at = '2026-10-31T08:05:00Z'), 'raw readings older than 90 days are gone, the recent one stays');
SELECT pg_temp.sh_assert(EXISTS (SELECT 1 FROM public.sensor_hourly WHERE device_id = '00000000-0000-4000-8000-0000000136d1'
    AND hour = '2026-07-01T12:00:00Z' AND n = 2 AND t_min = 8.00 AND t_max = 10.00 AND t_avg = 9.00 AND h_min = 40.00 AND h_max = 44.00 AND h_avg = 42.00),
  'the summary of the deleted raw hour survives');
SELECT pg_temp.sh_assert(NOT EXISTS (SELECT 1 FROM public.sensor_hourly WHERE hour = '2024-06-01T00:00:00Z')
  AND EXISTS (SELECT 1 FROM public.sensor_hourly WHERE hour = '2024-12-01T00:00:00Z'), 'summary rows older than 730 days are deleted, newer stay');
ROLLBACK;

-- 4. Retention never removes a raw reading that is not summarized yet (more than 2,000 hours of backlog older than the cutoff).
BEGIN;
CREATE FUNCTION pg_temp.sh_assert(ok boolean, label text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF NOT COALESCE(ok, false) THEN RAISE EXCEPTION 'sensor hourly: %', label; END IF; END $$;
DELETE FROM public.sensor_readings;
DELETE FROM public.sensor_hourly;
INSERT INTO public.sensor_devices(id, device_name) VALUES ('00000000-0000-4000-8000-0000000136d3', 'Hourly Backlog');
INSERT INTO public.sensor_readings(device_id, temperature, measured_at)
  SELECT '00000000-0000-4000-8000-0000000136d3', 4.00, timestamptz '2026-04-01T00:10:00Z' + g * interval '1 hour' FROM generate_series(0, 2004) g;
-- The preview names what the apply run does: 2,000 hours to roll and 2,000 raw rows to delete, not all 2,005.
SELECT warehouse_maintenance.run_database_retention('2026-11-01T10:30:00Z', false) AS preview \gset
SELECT pg_temp.sh_assert((:'preview'::jsonb#>>'{rows,sensor_hourly_rolled}')::int = 2000 AND (:'preview'::jsonb#>>'{rows,sensor_readings}')::int = 2000,
  'preview: 2,000 to roll and 2,000 raw rows to delete: ' || :'preview');
SELECT warehouse_maintenance.run_database_retention('2026-11-01T10:30:00Z', true) AS applied \gset
SELECT pg_temp.sh_assert((:'applied'::jsonb#>>'{rows,sensor_hourly_rolled}')::int = 2000 AND (:'applied'::jsonb#>>'{rows,sensor_readings}')::int = 2000,
  'apply agrees with the preview: ' || :'applied');
SELECT pg_temp.sh_assert((SELECT count(*) FROM public.sensor_hourly) = 2000 AND (SELECT count(*) FROM public.sensor_readings) = 5,
  'the first run summarizes 2,000 hours and keeps the 5 raw rows not summarized yet');
SELECT warehouse_maintenance.run_database_retention('2026-11-01T10:30:00Z', false) AS preview \gset
SELECT pg_temp.sh_assert((:'preview'::jsonb#>>'{rows,sensor_hourly_rolled}')::int = 5 AND (:'preview'::jsonb#>>'{rows,sensor_readings}')::int = 5,
  'preview of the next run: 5 to roll and 5 raw rows to delete: ' || :'preview');
SELECT warehouse_maintenance.run_database_retention('2026-11-01T10:30:00Z', true);
SELECT pg_temp.sh_assert((SELECT count(*) FROM public.sensor_hourly) = 2005 AND (SELECT count(*) FROM public.sensor_readings) = 0,
  'the next run summarizes the rest and removes the raw rows');
ROLLBACK;

-- 5. get_sensor_hourly: grants, roles, range errors, order.
BEGIN;
CREATE FUNCTION pg_temp.sh_assert(ok boolean, label text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF NOT COALESCE(ok, false) THEN RAISE EXCEPTION 'sensor hourly: %', label; END IF; END $$;
CREATE FUNCTION pg_temp.sh_call(statement text) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE answer jsonb;
BEGIN
  BEGIN EXECUTE statement INTO answer;
  EXCEPTION WHEN OTHERS THEN RETURN jsonb_build_object('raised', SQLERRM, 'state', SQLSTATE); END;
  RETURN answer;
END $$;
CREATE FUNCTION pg_temp.sh_login(phone text) RETURNS jsonb LANGUAGE plpgsql AS $$
 DECLARE c jsonb; l jsonb; claims jsonb;
 BEGIN
  c:=public.operator_prepare_otp(phone);
  PERFORM pg_temp.sh_assert(c->>'success'='true','challenge prepared for '||phone);
  PERFORM public.operator_finish_otp((c#>>'{data,request_id}')::uuid,true,'mock-provider-only');
  l:=public.operator_verify_otp(phone,c#>>'{data,otp_code}');
  PERFORM pg_temp.sh_assert(l#>>'{data,action}'='login','login for '||phone);
  SELECT jsonb_build_object('role','authenticated','sub',p.auth_user_id,'session_id',r.id) INTO claims
   FROM public.user_profiles p JOIN warehouse_security.refresh_sessions r ON r.user_id=p.auth_user_id
   WHERE p.mobile=warehouse_security.normalize_phone(phone) ORDER BY r.created_at DESC LIMIT 1;
  RETURN claims;
 END $$;
INSERT INTO warehouse_security.auth_config(key,value) VALUES
 ('jwt_secret','isolated-test-secret-not-for-any-deployment-12345'),
 ('auth_mode','operator'),('demo_auth_enabled','false')
 ON CONFLICT(key) DO UPDATE SET value=excluded.value;
UPDATE public.sms_config SET provider='msg91',production_mode=true,msg91_auth_key='isolated-test-key',
 msg91_template_id='000000000000000000000001',msg91_pe_id='0000000000000000001',msg91_sender_id='CITEST'
 WHERE id=(SELECT id FROM public.sms_config ORDER BY id DESC LIMIT 1);
SELECT warehouse_security.bootstrap_first_admin('9888888961','Sensor Hourly Administrator') AS admin_user \gset
INSERT INTO public.user_profiles(auth_user_id,mobile,name,role,active,enrollment_status) VALUES
 (gen_random_uuid(),'919888888962','Sensor Hourly Supervisor','supervisor',true,'approved'),
 (gen_random_uuid(),'919888888963','Sensor Hourly Staff','staff',true,'approved'),
 (gen_random_uuid(),'919888888964','Sensor Hourly Customer','customer',true,'approved');
SELECT pg_temp.sh_login('9888888961') AS admin_claims \gset
SELECT pg_temp.sh_login('9888888962') AS supervisor_claims \gset
SELECT pg_temp.sh_login('9888888963') AS staff_claims \gset
SELECT pg_temp.sh_login('9888888964') AS customer_claims \gset
DELETE FROM public.sensor_hourly;
INSERT INTO public.sensor_devices(id, device_name, location) VALUES
 ('00000000-0000-4000-8000-0000000136d4', 'Hourly Reader', 'Chamber 4');
-- inserted out of order on purpose
INSERT INTO public.sensor_hourly(device_id, hour, n, t_min, t_max, t_avg, h_min, h_max, h_avg) VALUES
 ('00000000-0000-4000-8000-0000000136d4', '2026-10-02T05:00:00Z', 12, 3.5, 4.5, 4.0, 60, 70, 65),
 ('00000000-0000-4000-8000-0000000136d4', '2026-10-02T03:00:00Z', 12, 2.5, 3.5, 3.0, NULL, NULL, NULL),
 ('00000000-0000-4000-8000-0000000136d4', '2026-10-02T04:00:00Z', 11, 3.0, 4.0, 3.5, 61, 62, 61.5),
 ('00000000-0000-4000-8000-0000000136d4', '2026-10-02T06:00:00Z', 1, 9, 9, 9, 90, 90, 90);

SELECT set_config('request.jwt.claims',:'staff_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.sh_call($q$SELECT public.get_sensor_hourly('00000000-0000-4000-8000-0000000136d4','2026-10-02T03:00:00Z','2026-10-02T06:00:00Z')$q$) AS answer \gset
SELECT pg_temp.sh_assert(:'answer'::jsonb->>'success'='true'
  AND :'answer'::jsonb#>>'{data,device_id}'='00000000-0000-4000-8000-0000000136d4' AND :'answer'::jsonb#>>'{data,device_name}'='Hourly Reader'
  AND :'answer'::jsonb#>>'{data,location}'='Chamber 4'
  AND jsonb_array_length(:'answer'::jsonb#>'{data,hours}')=3
  AND :'answer'::jsonb#>>'{metadata,row_count}'='3' AND :'answer'::jsonb#>>'{metadata,bucket}'='hour' AND :'answer'::jsonb#>>'{metadata,timezone}'='UTC',
  'staff read the range (from included, to excluded): '||:'answer');
SELECT pg_temp.sh_assert(:'answer'::jsonb#>>'{data,hours,0,hour}'='2026-10-02T03:00:00+00:00'
  AND :'answer'::jsonb#>>'{data,hours,1,hour}'='2026-10-02T04:00:00+00:00' AND :'answer'::jsonb#>>'{data,hours,2,hour}'='2026-10-02T05:00:00+00:00',
  'rows are ordered by hour: '||:'answer');
SELECT pg_temp.sh_assert((:'answer'::jsonb#>>'{data,hours,0,sample_count}')::int=12 AND (:'answer'::jsonb#>>'{data,hours,0,temperature_min}')::numeric=2.5
  AND (:'answer'::jsonb#>>'{data,hours,0,temperature_max}')::numeric=3.5 AND (:'answer'::jsonb#>>'{data,hours,0,temperature_avg}')::numeric=3.0
  AND (:'answer'::jsonb#>'{data,hours,0}')->'humidity_min'='null'::jsonb AND (:'answer'::jsonb#>'{data,hours,0}')->'humidity_avg'='null'::jsonb
  AND (:'answer'::jsonb#>>'{data,hours,2,humidity_min}')::numeric=60 AND (:'answer'::jsonb#>>'{data,hours,2,humidity_max}')::numeric=70
  AND (:'answer'::jsonb#>>'{data,hours,2,humidity_avg}')::numeric=65,
  'row fields: '||:'answer');
-- An empty range gives an empty list, an unknown device is answered.
SELECT pg_temp.sh_call($q$SELECT public.get_sensor_hourly('00000000-0000-4000-8000-0000000136d4','2026-09-01T00:00:00Z','2026-09-02T00:00:00Z')$q$) AS answer \gset
SELECT pg_temp.sh_assert(:'answer'::jsonb->>'success'='true' AND :'answer'::jsonb#>'{data,hours}'='[]'::jsonb, 'an empty range gives an empty list: '||:'answer');
SELECT pg_temp.sh_call($q$SELECT public.get_sensor_hourly(gen_random_uuid(),'2026-09-01T00:00:00Z','2026-09-02T00:00:00Z')$q$) AS answer \gset
SELECT pg_temp.sh_assert(:'answer'::jsonb->>'success'='false' AND :'answer'::jsonb->>'error_code'='DEVICE_NOT_FOUND', 'unknown device: '||:'answer');
-- Range errors.
SELECT pg_temp.sh_call($q$SELECT public.get_sensor_hourly('00000000-0000-4000-8000-0000000136d4','2026-10-02T00:00:00Z','2026-10-02T00:00:00Z')$q$) AS answer \gset
SELECT pg_temp.sh_assert(:'answer'::jsonb->>'success'='false' AND :'answer'::jsonb->>'error_code'='INVALID_RANGE', 'to = from: '||:'answer');
SELECT pg_temp.sh_call($q$SELECT public.get_sensor_hourly('00000000-0000-4000-8000-0000000136d4','2026-10-03T00:00:00Z','2026-10-02T00:00:00Z')$q$) AS answer \gset
SELECT pg_temp.sh_assert(:'answer'::jsonb->>'error_code'='INVALID_RANGE', 'to before from: '||:'answer');
SELECT pg_temp.sh_call($q$SELECT public.get_sensor_hourly('00000000-0000-4000-8000-0000000136d4',NULL,'2026-10-02T00:00:00Z')$q$) AS answer \gset
SELECT pg_temp.sh_assert(:'answer'::jsonb->>'error_code'='INVALID_RANGE', 'null from: '||:'answer');
SELECT pg_temp.sh_call($q$SELECT public.get_sensor_hourly('00000000-0000-4000-8000-0000000136d4','2025-01-01T00:00:00Z','2026-02-05T00:00:01Z')$q$) AS answer \gset
SELECT pg_temp.sh_assert(:'answer'::jsonb->>'success'='false' AND :'answer'::jsonb->>'error_code'='RANGE_TOO_LARGE', 'more than 400 days: '||:'answer');
SELECT pg_temp.sh_call($q$SELECT public.get_sensor_hourly('00000000-0000-4000-8000-0000000136d4','2025-01-01T00:00:00Z','2026-02-05T00:00:00Z')$q$) AS answer \gset
SELECT pg_temp.sh_assert(:'answer'::jsonb->>'success'='true', 'exactly 400 days is allowed: '||:'answer');
-- Administrator and supervisor read it too.
RESET ROLE;
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.sh_call($q$SELECT public.get_sensor_hourly('00000000-0000-4000-8000-0000000136d4','2026-10-02T03:00:00Z','2026-10-02T07:00:00Z')$q$) AS answer \gset
SELECT pg_temp.sh_assert(:'answer'::jsonb->>'success'='true' AND jsonb_array_length(:'answer'::jsonb#>'{data,hours}')=4, 'administrator reads: '||:'answer');
RESET ROLE;
SELECT set_config('request.jwt.claims',:'supervisor_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.sh_call($q$SELECT public.get_sensor_hourly('00000000-0000-4000-8000-0000000136d4','2026-10-02T03:00:00Z','2026-10-02T07:00:00Z')$q$) AS answer \gset
SELECT pg_temp.sh_assert(:'answer'::jsonb->>'success'='true' AND jsonb_array_length(:'answer'::jsonb#>'{data,hours}')=4, 'supervisor reads: '||:'answer');
-- A customer is refused, also before the range is looked at; the table itself is not readable.
RESET ROLE;
SELECT set_config('request.jwt.claims',:'customer_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.sh_call($q$SELECT public.get_sensor_hourly('00000000-0000-4000-8000-0000000136d4','2026-10-02T03:00:00Z','2026-10-02T07:00:00Z')$q$) AS answer \gset
SELECT pg_temp.sh_assert(:'answer'::jsonb->>'state'='42501' AND :'answer'::jsonb->>'raised'='Staff access required', 'a customer is refused: '||:'answer');
SELECT pg_temp.sh_call($q$SELECT public.get_sensor_hourly('00000000-0000-4000-8000-0000000136d4','2026-10-03T00:00:00Z','2026-10-02T00:00:00Z')$q$) AS answer \gset
SELECT pg_temp.sh_assert(:'answer'::jsonb->>'state'='42501', 'a customer is refused before the range check: '||:'answer');
SELECT pg_temp.sh_call($q$SELECT count(*) FROM public.sensor_hourly$q$) AS answer \gset
SELECT pg_temp.sh_assert(:'answer'::jsonb->>'state'='42501', 'the table is not readable by an app role: '||:'answer');
RESET ROLE;
-- anon cannot run it.
SET LOCAL ROLE anon;
SELECT pg_temp.sh_call($q$SELECT public.get_sensor_hourly('00000000-0000-4000-8000-0000000136d4','2026-10-02T03:00:00Z','2026-10-02T07:00:00Z')$q$) AS answer \gset
SELECT pg_temp.sh_assert(:'answer'::jsonb->>'state'='42501', 'anon is refused: '||:'answer');
RESET ROLE;
ROLLBACK;
