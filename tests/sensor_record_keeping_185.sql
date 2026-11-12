-- Migration 185 (WH-157): limit history and the record of changed readings. Fictional data; every block rolls back.
\set ON_ERROR_STOP on
BEGIN;
CREATE FUNCTION pg_temp.rk_assert(ok boolean, label text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF NOT COALESCE(ok, false) THEN RAISE EXCEPTION 'record keeping 185: %', label; END IF; END $$;
-- Structure and grants.
SELECT pg_temp.rk_assert((SELECT count(*) FROM warehouse_security.sensor_record_settings) = 1, 'one settings row');
SELECT pg_temp.rk_assert(NOT EXISTS (SELECT 1 FROM public.sensor_devices d WHERE NOT EXISTS (SELECT 1 FROM warehouse_security.sensor_limit_changes c WHERE c.device_id = d.id)), 'every sensor has a limit row');
SELECT pg_temp.rk_assert(NOT has_table_privilege('service_role', 'public.sensor_readings', 'TRUNCATE') AND NOT has_table_privilege('service_role', 'public.sensor_hourly', 'TRUNCATE')
  AND NOT has_table_privilege('service_role', 'public.sensor_readings', 'TRIGGER') AND has_table_privilege('service_role', 'public.sensor_readings', 'DELETE'), 'service role grants');
SELECT pg_temp.rk_assert(NOT has_table_privilege('service_role', 'warehouse_security.sensor_reading_changes', 'INSERT')
  AND NOT has_table_privilege('authenticated', 'warehouse_security.sensor_reading_changes', 'SELECT'), 'change log grants');
SELECT pg_temp.rk_assert((SELECT count(*) FROM warehouse_maintenance.retention_policy WHERE key IN ('sensor_limit_changes', 'sensor_reading_changes') AND days = 730) = 2, 'policy rows');
-- A new sensor gets a first limit row; a limit change is recorded (criterion 5), a write that leaves the limits alone is not.
INSERT INTO public.sensor_devices(id, device_name, location, alert_config) VALUES
 ('00000000-0000-4000-8000-0000000185d1', 'Record Chamber One', 'Chamber 1', '{"temperature_min": 2, "temperature_max": 8}');
SELECT pg_temp.rk_assert((SELECT count(*) FROM warehouse_security.sensor_limit_changes WHERE device_id = '00000000-0000-4000-8000-0000000185d1'
  AND source = 'change' AND temperature_min = 2 AND temperature_max = 8) = 1, 'creation row');
UPDATE public.sensor_devices SET alert_config = '{"temperature_min": 2, "temperature_max": 6}' WHERE id = '00000000-0000-4000-8000-0000000185d1';
UPDATE public.sensor_devices SET alert_config = '{"temperature_min": 2.0, "temperature_max": 6, "note": "x"}' WHERE id = '00000000-0000-4000-8000-0000000185d1';
UPDATE public.sensor_devices SET location = 'Chamber 1A' WHERE id = '00000000-0000-4000-8000-0000000185d1';
SELECT pg_temp.rk_assert((SELECT count(*) FROM warehouse_security.sensor_limit_changes WHERE device_id = '00000000-0000-4000-8000-0000000185d1') = 2
  AND EXISTS (SELECT 1 FROM warehouse_security.sensor_limit_changes WHERE device_id = '00000000-0000-4000-8000-0000000185d1' AND temperature_max = 6), 'one change row for 8 -> 6, none for the rest');
-- The limit history refuses an update.
DO $$ BEGIN
  UPDATE warehouse_security.sensor_limit_changes SET temperature_max = 9 WHERE device_id = '00000000-0000-4000-8000-0000000185d1';
  RAISE EXCEPTION 'record keeping 185: a limit row was updated';
EXCEPTION WHEN insufficient_privilege THEN NULL; END $$;
-- With the server key: an added, a changed and a deleted reading are each recorded (criterion 6).
SET LOCAL ROLE service_role;
SELECT set_config('request.jwt.claims', '{"role":"service_role"}', true);
INSERT INTO public.sensor_readings(device_id, temperature, humidity, measured_at) VALUES
 ('00000000-0000-4000-8000-0000000185d1', 5.00, 60.00, now() - interval '2 hours'),
 ('00000000-0000-4000-8000-0000000185d1', 5.50, 61.00, now() - interval '1 hour');
UPDATE public.sensor_readings SET temperature = 4.00 WHERE device_id = '00000000-0000-4000-8000-0000000185d1' AND temperature = 5.50;
UPDATE public.sensor_readings SET temperature = temperature WHERE device_id = '00000000-0000-4000-8000-0000000185d1';
DELETE FROM public.sensor_readings WHERE device_id = '00000000-0000-4000-8000-0000000185d1' AND temperature = 5.00;
RESET ROLE;
SELECT pg_temp.rk_assert((SELECT string_agg(op || ':' || row_count || ':' || db_user, ',' ORDER BY id) FROM warehouse_security.sensor_reading_changes
  WHERE device_id = '00000000-0000-4000-8000-0000000185d1') = 'insert:2:service_role,update:1:service_role,delete:1:service_role',
  'server-key insert, update and delete recorded; the no-op update is not');
-- The change log is insert-only.
DO $$ BEGIN
  DELETE FROM warehouse_security.sensor_reading_changes WHERE device_id = '00000000-0000-4000-8000-0000000185d1';
  RAISE EXCEPTION 'record keeping 185: a change row was deleted';
EXCEPTION WHEN insufficient_privilege THEN NULL; END $$;
ROLLBACK;

-- The feed, the roll-up and retention are not recorded; a lowered policy's delete is (criterion 6).
BEGIN;
CREATE FUNCTION pg_temp.rk_assert(ok boolean, label text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF NOT COALESCE(ok, false) THEN RAISE EXCEPTION 'record keeping 185: %', label; END IF; END $$;
INSERT INTO warehouse_security.sensor_ingest_keys(key_hash, label) VALUES (encode(extensions.digest(repeat('a', 64), 'sha256'), 'hex'), 'rk185');
SELECT public.record_sensor_batch(repeat('a', 64), '{"id": "hub-rk185", "online": true}', jsonb_build_array(
  jsonb_build_object('external_id', repeat('B', 40), 'measured_at', to_char(now() - interval '3 hours', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'), 'temperature', 4, 'humidity', 50, 'kind', 'change'),
  jsonb_build_object('external_id', repeat('B', 40), 'measured_at', to_char(now() - interval '2 hours', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'), 'temperature', 5, 'humidity', 51, 'kind', 'change')));
SELECT pg_temp.rk_assert(NOT EXISTS (SELECT 1 FROM warehouse_security.sensor_reading_changes c JOIN public.sensor_devices d ON d.id = c.device_id
  WHERE d.external_id = repeat('B', 40)), 'the feed''s readings are not recorded');
SELECT pg_temp.rk_assert(current_setting('warehouse.sensor_job', true) = '', 'the feed clears its mark');
-- Old raw readings (as if fed long ago: inserted with the ingest mark), then retention rolls up and deletes them.
SELECT set_config('warehouse.sensor_job', 'ingest', true);
INSERT INTO public.sensor_readings(device_id, temperature, humidity, measured_at)
SELECT d.id, 3.00, 40.00, now() - interval '100 days' FROM public.sensor_devices d WHERE d.external_id = repeat('B', 40);
SELECT set_config('warehouse.sensor_job', '', true);
SELECT pg_temp.rk_assert((SELECT count(*) FROM warehouse_security.sensor_reading_changes WHERE op = 'insert') >= 1, 'an ingest mark outside the feed''s window is recorded');
CREATE TEMP TABLE rk_before AS SELECT max(id) AS id FROM warehouse_security.sensor_reading_changes;
SELECT warehouse_maintenance.run_database_retention(now(), true) AS applied \gset
SELECT pg_temp.rk_assert((:'applied'::jsonb#>>'{rows,sensor_readings}')::int >= 1 AND (:'applied'::jsonb#>>'{rows,sensor_hourly_rolled}')::int >= 1
  AND (:'applied'::jsonb->'rows') ?& ARRAY['sensor_reading_changes', 'sensor_limit_changes'], 'retention rolled and deleted: ' || :'applied');
SELECT pg_temp.rk_assert(NOT EXISTS (SELECT 1 FROM warehouse_security.sensor_reading_changes
  WHERE id > COALESCE((SELECT id FROM rk_before), 0)), 'retention and the roll-up left no record');
SELECT pg_temp.rk_assert(current_setting('warehouse.sensor_job', true) = '', 'retention clears its mark');
-- A lowered raw policy deletes readings younger than 90 days: recorded.
UPDATE warehouse_maintenance.retention_policy SET days = 1 WHERE key = 'sensor_readings';
SELECT warehouse_maintenance.rollup_sensor_hourly(now() + interval '1 day');
SELECT warehouse_maintenance.run_database_retention(now() + interval '2 days', true);
SELECT pg_temp.rk_assert(EXISTS (SELECT 1 FROM warehouse_security.sensor_reading_changes WHERE table_name = 'sensor_readings' AND op = 'delete'),
  'a delete under a lowered policy is recorded');
ROLLBACK;
