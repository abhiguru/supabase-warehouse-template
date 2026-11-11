-- Migration 187 (WH-157): the temperature report read (criteria 8, 9, the period refusals, the JSON shape). Fictional data; every block rolls back.
\set ON_ERROR_STOP on
BEGIN;
CREATE FUNCTION pg_temp.tr_assert(ok boolean, label text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF NOT COALESCE(ok, false) THEN RAISE EXCEPTION 'temperature report 187: %', label; END IF; END $$;
SELECT pg_temp.tr_assert(has_function_privilege('authenticated', 'public.get_temperature_report(uuid,date,date)', 'EXECUTE')
  AND NOT has_function_privilege('anon', 'public.get_temperature_report(uuid,date,date)', 'EXECUTE')
  AND has_function_privilege('authenticated', 'public.get_sensor_report_devices()', 'EXECUTE')
  AND (SELECT prosrc ~ 'authorize_rpc\(''get_temperature_report''' FROM pg_proc WHERE oid = 'public.get_temperature_report(uuid,date,date)'::regprocedure)
  AND (SELECT prosrc ~ 'authorize_rpc\(''get_sensor_report_devices''' FROM pg_proc WHERE oid = 'public.get_sensor_report_devices()'::regprocedure), 'grants and guard');
-- The upgrade was 10 days ago; the sensor has hourly rows 120 days back and raw readings for the last 5 days.
DELETE FROM warehouse_security.sensor_stretches;
UPDATE warehouse_security.sensor_record_settings SET recorded_through = NULL, record_started_at = now() - interval '10 days';
INSERT INTO public.sensor_devices(id, device_name, location, alert_config) VALUES
 ('00000000-0000-4000-8000-0000000187d1', 'Report Chamber One', 'Chamber 1', '{"temperature_min": 2, "temperature_max": 8}');
SET LOCAL session_replication_role = replica;
UPDATE warehouse_security.sensor_limit_changes SET changed_at = now() - interval '10 days', source = 'since_before' WHERE device_id = '00000000-0000-4000-8000-0000000187d1';
SET LOCAL session_replication_role = origin;
INSERT INTO public.sensor_hourly(device_id, hour, n, t_min, t_max, t_avg, h_min, h_max, h_avg)
SELECT '00000000-0000-4000-8000-0000000187d1', date_trunc('hour', now() - interval '120 days') + make_interval(hours => i), 12, 4, 6, 5, 50, 60, 55
  FROM generate_series(0, 23) i;
INSERT INTO public.sensor_readings(device_id, temperature, humidity, measured_at)
SELECT '00000000-0000-4000-8000-0000000187d1', 5, 55, now() - make_interval(mins => 5 * i) FROM generate_series(1, 1400) i;
SELECT warehouse_maintenance.refresh_sensor_stretches(now(), 30, 15);
-- Period refusals.
SELECT pg_temp.tr_assert(public.get_temperature_report('00000000-0000-4000-8000-0000000187d1', current_date, current_date - 1)->>'error_code' = 'INVALID_PERIOD', 'To before From');
SELECT pg_temp.tr_assert(public.get_temperature_report('00000000-0000-4000-8000-0000000187d1', current_date + 2, current_date + 3)->>'error_code' = 'INVALID_PERIOD', 'To after today');
SELECT pg_temp.tr_assert(public.get_temperature_report('00000000-0000-4000-8000-0000000187d1', (current_date - interval '13 months')::date, current_date - 1)->>'error_code' = 'PERIOD_TOO_LONG', '13 months');
SELECT pg_temp.tr_assert(public.get_temperature_report('00000000-0000-4000-8000-0000000187d1', (current_date - interval '12 months')::date, current_date - 1)->>'error_code' IS DISTINCT FROM 'PERIOD_TOO_LONG', 'exactly 12 months is allowed');
SELECT pg_temp.tr_assert(public.get_temperature_report('00000000-0000-4000-8000-0000000187d1', (current_date - interval '12 months')::date, current_date)->>'error_code' = 'PERIOD_TOO_LONG', '12 months and a day');
SELECT pg_temp.tr_assert(public.get_temperature_report('00000000-0000-4000-8000-0000000187d1', (current_date - interval '25 months')::date, (current_date - interval '24 months' - interval '20 days')::date)->>'error_code' = 'PERIOD_TOO_OLD', 'more than 2 years back');
SELECT pg_temp.tr_assert(public.get_temperature_report('00000000-0000-4000-8000-0000000187d9', current_date - 1, current_date)->>'error_code' = 'DEVICE_NOT_FOUND', 'unknown sensor');
SELECT pg_temp.tr_assert(public.get_temperature_report('00000000-0000-4000-8000-0000000187d1', current_date - 60, current_date - 50)->>'error_code' = 'NO_READINGS', 'no readings in the period');
-- JSON shape and criterion 8: a period reaching back before the upgrade carries both "not recorded" dates; the hourly part is stated.
SELECT public.get_temperature_report('00000000-0000-4000-8000-0000000187d1', ((now() - interval '121 days') AT TIME ZONE 'Asia/Kolkata')::date,
  (now() AT TIME ZONE 'Asia/Kolkata')::date) AS r \gset
SELECT pg_temp.tr_assert((:'r'::jsonb->>'success')::boolean AND (:'r'::jsonb->'data') ?& ARRAY['made_at', 'made_by', 'record_started_at', 'silent_minutes', 'device',
  'period', 'hourly_part', 'limits', 'summary', 'chart', 'stretches', 'changes', 'changes_not_recorded_before'], 'top-level keys: ' || :'r');
SELECT pg_temp.tr_assert(:'r'::jsonb #>> '{data,limits,not_recorded_before}' = to_char((now() - interval '10 days') AT TIME ZONE 'Asia/Kolkata', 'YYYY-MM-DD')
  AND :'r'::jsonb #>> '{data,changes_not_recorded_before}' = :'r'::jsonb #>> '{data,limits,not_recorded_before}', 'criterion 8: both not-recorded dates');
SELECT pg_temp.tr_assert(jsonb_typeof(:'r'::jsonb #> '{data,limits,at_start,since_before}') = 'boolean'
  AND (:'r'::jsonb #> '{data,limits,at_start,since_before}')::boolean AND (:'r'::jsonb #>> '{data,limits,at_start,max}')::numeric = 8, 'at_start since_before');
SELECT pg_temp.tr_assert(jsonb_typeof(:'r'::jsonb #> '{data,hourly_part}') = 'object' AND (:'r'::jsonb #>> '{data,period,timezone}') = 'Asia/Kolkata'
  AND (:'r'::jsonb #>> '{data,period,to_is_now}')::boolean AND (:'r'::jsonb #>> '{data,summary,readings}')::int = 1400 + 24 * 12
  AND EXISTS (SELECT 1 FROM jsonb_array_elements(:'r'::jsonb #> '{data,chart,points}') p WHERE p->>'source' = 'hourly')
  AND EXISTS (SELECT 1 FROM jsonb_array_elements(:'r'::jsonb #> '{data,chart,points}') p WHERE p->>'source' = 'raw')
  AND jsonb_array_length(:'r'::jsonb #> '{data,chart,points}') <= 1600, 'hourly part, summary and chart');
SELECT pg_temp.tr_assert(EXISTS (SELECT 1 FROM jsonb_array_elements(:'r'::jsonb #> '{data,stretches}') s WHERE s->>'kind' = 'no_readings'
  AND (s->>'before_upgrade')::boolean AND s->'alert'->>'reason' = 'not_recorded'), 'the gap before the raw readings is a not-recorded stretch');
-- A limit change inside the period is listed with its author's name and is a limit step.
UPDATE public.sensor_devices SET alert_config = '{"temperature_min": 2, "temperature_max": 6}' WHERE id = '00000000-0000-4000-8000-0000000187d1';
SELECT public.get_temperature_report('00000000-0000-4000-8000-0000000187d1', current_date - 3, current_date) AS r \gset
SELECT pg_temp.tr_assert(jsonb_array_length(:'r'::jsonb #> '{data,limits,changes}') = 1 AND jsonb_array_length(:'r'::jsonb #> '{data,chart,limit_steps}') = 2
  AND :'r'::jsonb #> '{data,limits,not_recorded_before}' = 'null'::jsonb, 'a change in the period; no not-recorded line after the upgrade');
-- The chooser.
SELECT pg_temp.tr_assert(EXISTS (SELECT 1 FROM jsonb_array_elements(public.get_sensor_report_devices()->'data') d
  WHERE d->>'id' = '00000000-0000-4000-8000-0000000187d1' AND d ?& ARRAY['name', 'location', 'active', 'first_reading_at', 'last_reading_at']
    AND NOT d ? 'alert_config'), 'the chooser row');
ROLLBACK;
-- Criterion 9 (with the backlog_80 login helper): for staff, supervisor, administrator and customer claims, under SET LOCAL ROLE authenticated,
-- get_temperature_report(<sensor>, current_date - 1, current_date) answers success true and get_sensor_report_devices() lists the sensor;
-- for the customer claims get_sensor_polling_data(NULL), get_sensor_history(<sensor>, ...), get_sensor_hourly(<sensor>, now() - interval '1 day', now())
-- and get_sensor_device(<sensor>) each raise SQLSTATE 42501. The sensors-off refusal is the PDF route's 503 SENSORS_OFF (B4, router), not this read.
