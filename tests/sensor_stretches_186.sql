-- Migration 186 (WH-157): stretches (criteria 1-5 and 7). Fictional data; every block rolls back.
\set ON_ERROR_STOP on
BEGIN;
CREATE FUNCTION pg_temp.st_assert(ok boolean, label text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF NOT COALESCE(ok, false) THEN RAISE EXCEPTION 'stretches 186: %', label; END IF; END $$;
SELECT pg_temp.st_assert(NOT has_function_privilege('service_role', 'warehouse_maintenance.refresh_sensor_stretches(timestamptz,integer,integer)', 'EXECUTE')
  AND NOT has_table_privilege('authenticated', 'warehouse_security.sensor_stretches', 'SELECT')
  AND EXISTS (SELECT 1 FROM warehouse_maintenance.retention_policy WHERE key = 'sensor_stretches' AND days = 730), 'grants and policy row');
DELETE FROM warehouse_security.sensor_stretches;
UPDATE warehouse_security.sensor_record_settings SET recorded_through = NULL;
INSERT INTO public.sensor_devices(id, device_name, alert_config) VALUES
 ('00000000-0000-4000-8000-0000000186d1', 'Stretch Chamber One', '{"temperature_min": 2, "temperature_max": 8}'),
 ('00000000-0000-4000-8000-0000000186d2', 'Stretch Chamber Two', '{"temperature_min": 2, "temperature_max": 8}');
-- The creation rows are dated now(); date them back so they judge the readings below.
SET LOCAL session_replication_role = replica;
UPDATE warehouse_security.sensor_limit_changes SET changed_at = now() - interval '200 days'
 WHERE device_id IN ('00000000-0000-4000-8000-0000000186d1', '00000000-0000-4000-8000-0000000186d2');
SET LOCAL session_replication_role = origin;
-- 1: 7, 9, 10, 9, 7 at 5-minute steps (3 hours ago). 4: a 70-minute gap after it. 2: a 10-minute and a 40-minute too-warm stretch.
INSERT INTO public.sensor_readings(device_id, temperature, measured_at)
SELECT '00000000-0000-4000-8000-0000000186d1', t, date_trunc('minute', now()) - interval '3 hours' + make_interval(mins => 5 * i)
  FROM (VALUES (0, 7), (1, 9), (2, 10), (3, 9), (4, 7)) v(i, t);
INSERT INTO public.sensor_readings(device_id, temperature, measured_at)
SELECT '00000000-0000-4000-8000-0000000186d1', t, date_trunc('minute', now()) - interval '3 hours' + make_interval(mins => m)
  FROM (VALUES (90, 7), (100, 9), (105, 9), (110, 7), (115, 9), (125, 9), (135, 9), (145, 9), (155, 7), (160, 5)) v(m, t);
SELECT warehouse_maintenance.refresh_sensor_stretches(now(), 30, 15);
SELECT pg_temp.st_assert(EXISTS (SELECT 1 FROM warehouse_security.sensor_stretches WHERE device_id = '00000000-0000-4000-8000-0000000186d1'
  AND kind = 'too_warm' AND started_at = date_trunc('minute', now()) - interval '3 hours' + interval '5 minutes'
  AND ended_at = date_trunc('minute', now()) - interval '3 hours' + interval '20 minutes' AND worst = 10 AND limit_value = 8 AND beyond = 2 AND readings = 3),
  'criterion 1: one too-warm stretch from the first 9 to the 7, worst 10, 2 beyond');
SELECT pg_temp.st_assert(EXISTS (SELECT 1 FROM warehouse_security.sensor_stretches WHERE device_id = '00000000-0000-4000-8000-0000000186d1'
  AND kind = 'no_readings' AND ended_at - started_at = interval '70 minutes'), 'criterion 4: one 70-minute no-readings stretch');
SELECT pg_temp.st_assert((SELECT count(*) FROM warehouse_security.sensor_stretches WHERE device_id = '00000000-0000-4000-8000-0000000186d1'
  AND kind = 'too_warm' AND ended_at - started_at IN (interval '10 minutes', interval '40 minutes') AND threshold_minutes = 15) = 2,
  'criterion 2: the 10- and 40-minute stretches are both kept');
-- 2 and 3: the checker posted the 40-minute stretch's alert 16 minutes in; device two had no channel.
SELECT warehouse_maintenance.record_sensor_alert_posts(jsonb_build_array(jsonb_build_object('device_id', '00000000-0000-4000-8000-0000000186d1',
  'alert', 'range', 'since', date_trunc('minute', now()) - interval '3 hours' + interval '130 minutes',
  'at', date_trunc('minute', now()) - interval '3 hours' + interval '131 minutes', 'via', 'sensors', 'state', 'posted')));
SELECT pg_temp.st_assert((SELECT alert_posted_at FROM warehouse_security.sensor_stretches WHERE device_id = '00000000-0000-4000-8000-0000000186d1'
  AND kind = 'too_warm' AND ended_at - started_at = interval '40 minutes') = date_trunc('minute', now()) - interval '3 hours' + interval '131 minutes'
  AND (SELECT alert_state IS NULL FROM warehouse_security.sensor_stretches WHERE device_id = '00000000-0000-4000-8000-0000000186d1'
  AND kind = 'too_warm' AND ended_at - started_at = interval '10 minutes'), 'criterion 2: the posting time lands on the 40-minute stretch only');
INSERT INTO public.sensor_readings(device_id, temperature, measured_at)
SELECT '00000000-0000-4000-8000-0000000186d2', t, date_trunc('minute', now()) - interval '2 hours' + make_interval(mins => m)
  FROM (VALUES (0, 7), (5, 9), (25, 9), (45, 7)) v(m, t);
SELECT warehouse_maintenance.refresh_sensor_stretches(now(), 30, 15);
SELECT warehouse_maintenance.record_sensor_alert_posts(jsonb_build_array(jsonb_build_object('device_id', '00000000-0000-4000-8000-0000000186d2',
  'alert', 'range', 'since', date_trunc('minute', now()) - interval '2 hours' + interval '20 minutes',
  'at', date_trunc('minute', now()) - interval '2 hours' + interval '20 minutes', 'via', NULL, 'state', 'no_channel')));
SELECT pg_temp.st_assert((SELECT alert_state = 'no_channel' AND alert_posted_at IS NULL FROM warehouse_security.sensor_stretches
  WHERE device_id = '00000000-0000-4000-8000-0000000186d2' AND kind = 'too_warm'), 'criterion 3: no alert channel set up');
-- A late reading inside a stretch keeps its alert; a failed post never replaces a posted one.
INSERT INTO public.sensor_readings(device_id, temperature, measured_at)
VALUES ('00000000-0000-4000-8000-0000000186d2', 9.5, date_trunc('minute', now()) - interval '2 hours' + interval '15 minutes');
SELECT warehouse_maintenance.refresh_sensor_stretches(now(), 30, 15);
SELECT pg_temp.st_assert((SELECT alert_state FROM warehouse_security.sensor_stretches WHERE device_id = '00000000-0000-4000-8000-0000000186d2'
  AND kind = 'too_warm' AND worst = 9.5) = 'no_channel', 'a re-derived stretch keeps its alert');
ROLLBACK;

-- 5: the limit goes from 8 to 6 °C; a reading of 7 is too warm only after the change.
BEGIN;
CREATE FUNCTION pg_temp.st_assert(ok boolean, label text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF NOT COALESCE(ok, false) THEN RAISE EXCEPTION 'stretches 186: %', label; END IF; END $$;
DELETE FROM warehouse_security.sensor_stretches;
UPDATE warehouse_security.sensor_record_settings SET recorded_through = NULL;
INSERT INTO public.sensor_devices(id, device_name, alert_config) VALUES ('00000000-0000-4000-8000-0000000186d3', 'Stretch Chamber Three', '{"temperature_min": 2, "temperature_max": 8}');
SET LOCAL session_replication_role = replica;
UPDATE warehouse_security.sensor_limit_changes SET changed_at = now() - interval '200 days' WHERE device_id = '00000000-0000-4000-8000-0000000186d3';
SET LOCAL session_replication_role = origin;
INSERT INTO warehouse_security.sensor_limit_changes(device_id, changed_at, temperature_min, temperature_max, source)
VALUES ('00000000-0000-4000-8000-0000000186d3', date_trunc('minute', now()) - interval '30 minutes', 2, 6, 'change');
INSERT INTO public.sensor_readings(device_id, temperature, measured_at)
SELECT '00000000-0000-4000-8000-0000000186d3', t, date_trunc('minute', now()) - make_interval(mins => m)
  FROM (VALUES (60, 7), (50, 7), (40, 7), (20, 7), (10, 5)) v(m, t);
SELECT warehouse_maintenance.refresh_sensor_stretches(now(), 30, 15);
SELECT pg_temp.st_assert((SELECT count(*) FROM warehouse_security.sensor_stretches WHERE device_id = '00000000-0000-4000-8000-0000000186d3' AND kind = 'too_warm') = 1
  AND EXISTS (SELECT 1 FROM warehouse_security.sensor_stretches WHERE device_id = '00000000-0000-4000-8000-0000000186d3' AND kind = 'too_warm'
    AND started_at = date_trunc('minute', now()) - interval '20 minutes' AND limit_value = 6 AND beyond = 1),
  'criterion 5: 7 counts as too warm only after the change to 6');
SELECT pg_temp.st_assert((SELECT temperature_max FROM warehouse_security.sensor_limit_at('00000000-0000-4000-8000-0000000186d3', now() - interval '45 minutes')) = 8
  AND (SELECT temperature_max FROM warehouse_security.sensor_limit_at('00000000-0000-4000-8000-0000000186d3', now() - interval '300 days')) = 8,
  'sensor_limit_at: before the change 8, and before the first row the oldest row');
ROLLBACK;

-- 7: a stretch from 100 days ago outlives its raw readings.
BEGIN;
CREATE FUNCTION pg_temp.st_assert(ok boolean, label text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF NOT COALESCE(ok, false) THEN RAISE EXCEPTION 'stretches 186: %', label; END IF; END $$;
DELETE FROM warehouse_security.sensor_stretches;
UPDATE warehouse_security.sensor_record_settings SET recorded_through = NULL;
INSERT INTO public.sensor_devices(id, device_name, alert_config) VALUES ('00000000-0000-4000-8000-0000000186d4', 'Stretch Chamber Four', '{"temperature_min": 2, "temperature_max": 8}');
SET LOCAL session_replication_role = replica;
UPDATE warehouse_security.sensor_limit_changes SET changed_at = now() - interval '200 days' WHERE device_id = '00000000-0000-4000-8000-0000000186d4';
SET LOCAL session_replication_role = origin;
INSERT INTO public.sensor_readings(device_id, temperature, measured_at)
SELECT '00000000-0000-4000-8000-0000000186d4', t, date_trunc('hour', now()) - interval '100 days' + make_interval(mins => m)
  FROM (VALUES (0, 7), (7, 9.5), (13, 7)) v(m, t);
SELECT warehouse_maintenance.run_database_retention(now(), true) AS applied \gset
SELECT pg_temp.st_assert(NOT EXISTS (SELECT 1 FROM public.sensor_readings WHERE device_id = '00000000-0000-4000-8000-0000000186d4'), 'the raw readings are gone: ' || :'applied');
SELECT pg_temp.st_assert(EXISTS (SELECT 1 FROM warehouse_security.sensor_stretches WHERE device_id = '00000000-0000-4000-8000-0000000186d4'
  AND kind = 'too_warm' AND source = 'raw' AND started_at = date_trunc('hour', now()) - interval '100 days' + interval '7 minutes'
  AND ended_at = date_trunc('hour', now()) - interval '100 days' + interval '13 minutes' AND worst = 9.5),
  'criterion 7: the stretch keeps its exact times after the raw delete');
ROLLBACK;
-- Covered: out 40 min (alert posted 16 min in), back inside 5 min (< 15, the alert is not cleared), out again 10 min.
BEGIN;
CREATE FUNCTION pg_temp.st_assert(ok boolean, label text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF NOT COALESCE(ok, false) THEN RAISE EXCEPTION 'stretches 186: %', label; END IF; END $$;
DELETE FROM warehouse_security.sensor_stretches;
UPDATE warehouse_security.sensor_record_settings SET recorded_through = NULL, record_started_at = now() - interval '1 day';
INSERT INTO public.sensor_devices(id, device_name, alert_config) VALUES ('00000000-0000-4000-8000-0000000186d5', 'Stretch Chamber Five', '{"temperature_min": 2, "temperature_max": 8}');
SET LOCAL session_replication_role = replica;
UPDATE warehouse_security.sensor_limit_changes SET changed_at = now() - interval '200 days' WHERE device_id = '00000000-0000-4000-8000-0000000186d5';
SET LOCAL session_replication_role = origin;
INSERT INTO public.sensor_readings(device_id, temperature, measured_at)
SELECT '00000000-0000-4000-8000-0000000186d5', t, date_trunc('minute', now()) - interval '2 hours' + make_interval(mins => m)
  FROM (VALUES (0, 7), (5, 9), (15, 9), (25, 9), (35, 9), (45, 7), (50, 9), (55, 9), (60, 7), (65, 7)) v(m, t);
SELECT warehouse_maintenance.refresh_sensor_stretches(now(), 30, 15);
SELECT warehouse_maintenance.record_sensor_alert_posts(jsonb_build_array(jsonb_build_object('device_id', '00000000-0000-4000-8000-0000000186d5',
  'alert', 'range', 'since', date_trunc('minute', now()) - interval '2 hours' + interval '20 minutes',
  'at', date_trunc('minute', now()) - interval '2 hours' + interval '21 minutes', 'via', 'sensors', 'state', 'posted')));
SELECT pg_temp.st_assert((SELECT count(*) FROM warehouse_security.sensor_stretches WHERE device_id = '00000000-0000-4000-8000-0000000186d5'
  AND kind = 'too_warm' AND alert_posted_at IS NULL AND alert_state IS NULL) = 1, 'the second stretch has no posting time of its own');
SELECT public.get_temperature_report('00000000-0000-4000-8000-0000000186d5', (now() AT TIME ZONE 'Asia/Kolkata')::date - 1,
  (now() AT TIME ZONE 'Asia/Kolkata')::date) AS report \gset
SELECT pg_temp.st_assert((SELECT count(*) FROM jsonb_array_elements(:'report'::jsonb #> '{data,stretches}') s
  WHERE s->>'kind' = 'too_warm' AND s->'alert'->>'posted_at' IS NULL
    AND (s->>'covering_alert_posted_at')::timestamptz = date_trunc('minute', now()) - interval '2 hours' + interval '21 minutes') = 1,
  'the second line shows the first one''s posting time: ' || (:'report'::jsonb #> '{data,stretches}')::text);
-- The same with the first alert failed: the second stretch reads 'failed', not covered.
UPDATE warehouse_security.sensor_stretches SET alert_posted_at = NULL, alert_state = 'failed' WHERE device_id = '00000000-0000-4000-8000-0000000186d5' AND alert_state = 'posted';
SELECT public.get_temperature_report('00000000-0000-4000-8000-0000000186d5', (now() AT TIME ZONE 'Asia/Kolkata')::date - 1,
  (now() AT TIME ZONE 'Asia/Kolkata')::date) AS report \gset
SELECT pg_temp.st_assert((SELECT bool_and(s->'alert'->>'reason' = 'failed' AND s->'covering_alert_posted_at' = 'null'::jsonb)
  FROM jsonb_array_elements(:'report'::jsonb #> '{data,stretches}') s WHERE s->>'kind' = 'too_warm'), 'a failed alert is not "covered"');
ROLLBACK;
