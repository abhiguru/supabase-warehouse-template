-- Migration 136: an hourly summary of the sensor readings, kept 24 months (review finding M8).
--
-- sensor_readings keeps 90 days (retention key sensor_readings) and stays as it is. New:
--  * public.sensor_hourly: per device and UTC hour the number of readings and the minimum, maximum and average of temperature and
--    humidity. A value that no reading of the hour carries is NULL. Readable only through get_sensor_hourly (no app-role grant) and
--    service_role.
--  * warehouse_maintenance.rollup_sensor_hourly(p_now, p_apply): rolls up completed UTC hours only. It starts at each device's first
--    reading from its last rolled hour on (that hour is rolled again, so a reading that arrived late is folded in; an hour whose raw
--    rows have been partly removed never replaces a larger count), rolls at most 2,000 hours (that have readings) per call (sensor_hourly_window gives its end) and is safe to repeat. With
--    p_apply false it only counts the rows it would write.
--  * run_database_retention rolls up first, then removes the raw readings older than the sensor_readings policy, but only up to the
--    hour already rolled for that device, so a long backlog is never deleted before it is summarized. It also removes sensor_hourly
--    rows older than the new policy row sensor_hourly (730 days) and reports sensor_hourly_rolled and sensor_hourly. The preview
--    reports the same counts and writes nothing.
--  * public.get_sensor_hourly(p_device_id, p_from, p_to): the hourly rows of one device for a date range, for administrators,
--    supervisors and staff (authorize_rpc, definition file 00_authorize_rpc.sql); customers are refused.
SET LOCAL maintenance_work_mem = '256MB';

-- ===== 1. The table =====
CREATE TABLE public.sensor_hourly (
  device_id uuid NOT NULL REFERENCES public.sensor_devices(id) ON DELETE CASCADE,
  hour timestamptz NOT NULL,
  n integer NOT NULL CHECK (n > 0),
  t_min numeric(6,2),
  t_max numeric(6,2),
  t_avg numeric(6,2),
  h_min numeric(6,2),
  h_max numeric(6,2),
  h_avg numeric(6,2),
  PRIMARY KEY (device_id, hour)
);
ALTER TABLE public.sensor_hourly OWNER TO supabase_admin;
ALTER TABLE public.sensor_hourly ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.sensor_hourly FROM PUBLIC, anon, authenticated;
GRANT ALL ON TABLE public.sensor_hourly TO service_role;
COMMENT ON TABLE public.sensor_hourly IS 'Hourly minimum, maximum and average of sensor_readings per device (migration 136). hour is the start of a UTC hour; n counts the readings of that hour. Kept 24 months (retention key sensor_hourly).';

INSERT INTO warehouse_maintenance.retention_policy(key, days, description)
VALUES ('sensor_hourly', 730, 'Hourly sensor summary (min, max and average per device), kept 24 months')
ON CONFLICT (key) DO NOTHING;

-- ===== 2. The roll-up =====
-- The end (exclusive) of the hours the next roll-up would summarize, or NULL when there is nothing to roll. Per device the roll-up
-- starts at its first reading from its last rolled hour on (all readings for a device never rolled); a call does at most the first
-- 2,000 hours that have readings, oldest first, so it is bounded on a large backlog and a long gap without readings never stops it.
-- Only hours that are over count: the end is the start of the UTC hour that contains p_now.
CREATE FUNCTION warehouse_maintenance.sensor_hourly_window(p_now timestamptz DEFAULT now()) RETURNS timestamptz
 LANGUAGE sql
 STABLE
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'warehouse_maintenance'
AS $function$
  WITH last_rolled AS (
    SELECT device_id, max(hour) AS last_hour FROM public.sensor_hourly GROUP BY device_id
  ), starts AS (
    SELECT r.device_id, date_trunc('hour', min(r.measured_at), 'UTC') AS start_hour
      FROM public.sensor_readings r LEFT JOIN last_rolled l ON l.device_id = r.device_id
     WHERE l.last_hour IS NULL OR r.measured_at >= l.last_hour
     GROUP BY r.device_id
  ), hrs AS (
    SELECT DISTINCT date_trunc('hour', r.measured_at, 'UTC') AS hour
      FROM public.sensor_readings r JOIN starts s ON s.device_id = r.device_id
     WHERE r.measured_at >= s.start_hour AND r.measured_at < date_trunc('hour', COALESCE(p_now, now()), 'UTC')
     ORDER BY 1 LIMIT 2000
  )
  SELECT max(hour) + interval '1 hour' FROM hrs
$function$;
ALTER FUNCTION warehouse_maintenance.sensor_hourly_window(timestamptz) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION warehouse_maintenance.sensor_hourly_window(timestamptz) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION warehouse_maintenance.sensor_hourly_window(timestamptz) TO service_role;

-- Rolls the window up (INSERT ... ON CONFLICT DO UPDATE: safe to repeat; the last rolled hour is rolled again so a late reading is
-- folded in, and a recount that is smaller than the stored row, because raw rows were removed, never replaces it). Returns the rows
-- written, or with p_apply false the rows it would write, and changes nothing.
CREATE FUNCTION warehouse_maintenance.rollup_sensor_hourly(p_now timestamptz DEFAULT now(), p_apply boolean DEFAULT true)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'warehouse_maintenance'
AS $function$
DECLARE
  v_end timestamptz := warehouse_maintenance.sensor_hourly_window(p_now);
  v_n bigint;
BEGIN
  IF v_end IS NULL THEN RETURN 0; END IF;
  WITH last_rolled AS (
    SELECT device_id, max(hour) AS last_hour FROM public.sensor_hourly GROUP BY device_id
  ), starts AS (
    SELECT r.device_id, date_trunc('hour', min(r.measured_at), 'UTC') AS start_hour
      FROM public.sensor_readings r LEFT JOIN last_rolled l ON l.device_id = r.device_id
     WHERE l.last_hour IS NULL OR r.measured_at >= l.last_hour
     GROUP BY r.device_id
  ), agg AS (
    SELECT r.device_id, date_trunc('hour', r.measured_at, 'UTC') AS hour, count(*)::integer AS n,
           round(min(r.temperature), 2) AS t_min, round(max(r.temperature), 2) AS t_max, round(avg(r.temperature), 2) AS t_avg,
           round(min(r.humidity), 2) AS h_min, round(max(r.humidity), 2) AS h_max, round(avg(r.humidity), 2) AS h_avg
      FROM public.sensor_readings r
      JOIN starts s ON s.device_id = r.device_id
     WHERE r.measured_at >= s.start_hour AND r.measured_at < v_end
     GROUP BY r.device_id, date_trunc('hour', r.measured_at, 'UTC')
  ), written AS (
    INSERT INTO public.sensor_hourly AS h (device_id, hour, n, t_min, t_max, t_avg, h_min, h_max, h_avg)
    SELECT device_id, hour, n, t_min, t_max, t_avg, h_min, h_max, h_avg FROM agg WHERE p_apply
    ON CONFLICT (device_id, hour) DO UPDATE
      SET n = EXCLUDED.n, t_min = EXCLUDED.t_min, t_max = EXCLUDED.t_max, t_avg = EXCLUDED.t_avg,
          h_min = EXCLUDED.h_min, h_max = EXCLUDED.h_max, h_avg = EXCLUDED.h_avg
      WHERE EXCLUDED.n >= h.n
    RETURNING 1
  )
  SELECT CASE WHEN p_apply THEN (SELECT count(*) FROM written) ELSE (SELECT count(*) FROM agg) END INTO v_n;
  RETURN v_n;
END $function$;
ALTER FUNCTION warehouse_maintenance.rollup_sensor_hourly(timestamptz, boolean) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION warehouse_maintenance.rollup_sensor_hourly(timestamptz, boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION warehouse_maintenance.rollup_sensor_hourly(timestamptz, boolean) TO service_role;

-- ===== 3. run_database_retention: roll up before the raw readings go, delete the old summary rows =====
-- Patched in place (the text of migration 123, section 10): every before-text must be found exactly once, none of them is contained in
-- its replacement, so a second run of this file stops on the count.
DO $patch$
DECLARE
  def text := pg_get_functiondef('warehouse_maintenance.run_database_retention(timestamptz,boolean)'::regprocedure);
  pairs text[][] := ARRAY[
    -- 1. one more variable
    ARRAY[E'  sensor_cutoff timestamptz;\n  audit_cutoff timestamptz;',
          E'  sensor_cutoff timestamptz;\n  rolled bigint;\n  audit_cutoff timestamptz;'],
    -- 2. apply: roll up, delete the old summary rows, then delete the raw readings that are rolled up
    ARRAY[E'    DELETE FROM public.sensor_readings WHERE measured_at < sensor_cutoff;\n',
          E'    rolled := warehouse_maintenance.rollup_sensor_hourly(p_now, true);\n'
       || E'    result := result || jsonb_build_object(''sensor_hourly_rolled'', rolled);\n'
       || E'    DELETE FROM public.sensor_hourly WHERE hour < (SELECT p_now - make_interval(days => days)\n'
       || E'      FROM warehouse_maintenance.retention_policy WHERE key = ''sensor_hourly'');\n'
       || E'    GET DIAGNOSTICS affected = ROW_COUNT; result := result || jsonb_build_object(''sensor_hourly'', affected);\n'
       || E'    DELETE FROM public.sensor_readings r USING (SELECT device_id, max(hour) + interval ''1 hour'' AS rolled_to\n'
       || E'      FROM public.sensor_hourly GROUP BY device_id) m\n'
       || E'     WHERE m.device_id = r.device_id AND r.measured_at < LEAST(sensor_cutoff, m.rolled_to);\n'],
    -- 3. preview: the same counts, nothing written; the raw rows counted are the ones the apply run deletes (rolled by this run or before)
    ARRAY[E'\'sensor_readings\', (SELECT count(*) FROM public.sensor_readings WHERE measured_at < sensor_cutoff)\n    ) INTO result;',
          E'\'sensor_readings\', (SELECT count(*) FROM public.sensor_readings r WHERE r.measured_at < sensor_cutoff\n'
       || E'        AND (r.measured_at < (SELECT COALESCE(warehouse_maintenance.sensor_hourly_window(p_now), \'-infinity\'::timestamptz))\n'
       || E'          OR r.measured_at < COALESCE((SELECT max(h.hour) + interval \'1 hour\' FROM public.sensor_hourly h WHERE h.device_id = r.device_id),\n'
       || E'            \'-infinity\'::timestamptz))),\n'
       || E'      \'sensor_hourly_rolled\', warehouse_maintenance.rollup_sensor_hourly(p_now, false),\n'
       || E'      \'sensor_hourly\', (SELECT count(*) FROM public.sensor_hourly WHERE hour < (SELECT p_now - make_interval(days => days)\n'
       || E'        FROM warehouse_maintenance.retention_policy WHERE key = \'sensor_hourly\'))\n'
       || E'    ) INTO result;']
  ];
  i int;
  found int;
BEGIN
  FOR i IN 1 .. array_length(pairs, 1) LOOP
    found := (length(def) - length(replace(def, pairs[i][1], ''))) / length(pairs[i][1]);
    IF found <> 1 THEN
      RAISE EXCEPTION 'migration 136: run_database_retention patch % found its marker % times (expected 1)', i, found;
    END IF;
    def := replace(def, pairs[i][1], pairs[i][2]);
  END LOOP;
  EXECUTE def;
END $patch$;

-- ===== 4. get_sensor_hourly =====
CREATE FUNCTION public.get_sensor_hourly(p_device_id uuid, p_from timestamptz, p_to timestamptz) RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'extensions', 'utils', 'pg_temp'
AS $function$
DECLARE
  v_device RECORD;
  v_rows jsonb;
BEGIN
  PERFORM warehouse_security.authorize_rpc('get_sensor_hourly', jsonb_build_object());
  IF p_from IS NULL OR p_to IS NULL OR p_to <= p_from THEN
    RETURN jsonb_build_object('success', false, 'error', 'The end of the range must be after its start', 'error_code', 'INVALID_RANGE');
  END IF;
  IF p_to - p_from > interval '400 days' THEN
    RETURN jsonb_build_object('success', false, 'error', 'The range is longer than 400 days', 'error_code', 'RANGE_TOO_LARGE');
  END IF;
  SELECT d.id, d.device_name, d.location INTO v_device FROM public.sensor_devices d WHERE d.id = p_device_id;
  IF v_device.id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'Device not found', 'error_code', 'DEVICE_NOT_FOUND');
  END IF;
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'hour', h.hour, 'sample_count', h.n,
           'temperature_min', h.t_min, 'temperature_max', h.t_max, 'temperature_avg', h.t_avg,
           'humidity_min', h.h_min, 'humidity_max', h.h_max, 'humidity_avg', h.h_avg
         ) ORDER BY h.hour ASC), '[]'::jsonb)
    INTO v_rows
    FROM public.sensor_hourly h
   WHERE h.device_id = p_device_id AND h.hour >= p_from AND h.hour < p_to;
  RETURN jsonb_build_object(
    'success', true,
    'data', jsonb_build_object(
      'device_id', v_device.id, 'device_name', v_device.device_name, 'location', v_device.location,
      'from', p_from, 'to', p_to, 'hours', v_rows),
    'metadata', jsonb_build_object('row_count', jsonb_array_length(v_rows), 'bucket', 'hour', 'timezone', 'UTC'));
END $function$;
ALTER FUNCTION public.get_sensor_hourly(uuid, timestamptz, timestamptz) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION public.get_sensor_hourly(uuid, timestamptz, timestamptz) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.get_sensor_hourly(uuid, timestamptz, timestamptz) TO authenticated, service_role;

NOTIFY pgrst, 'reload schema';
