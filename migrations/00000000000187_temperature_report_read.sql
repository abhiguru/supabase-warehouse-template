-- Migration 187 (WH-157, part 3 of 3): the temperature report's read and its sensor chooser.
--
--  1. public.get_temperature_report(p_device_id uuid, p_from date, p_to date): everything generate-temperature-report-pdf prints, for
--     administrators, supervisors, staff and customer accounts, for every sensor (authorize_rpc, definition 00_authorize_rpc.sql).
--     Dates are India dates: the period is [p_from 00:00, p_to + 1 00:00) India time, cut at now() when p_to is today (to_is_now).
--     A 200 {success:false, error, error_code} for INVALID_PERIOD (a missing date, To before From, To after today), PERIOD_TOO_LONG (To
--     on or after From + 12 months), PERIOD_TOO_OLD (From more than 2 years before today), DEVICE_NOT_FOUND, and NO_READINGS (no raw
--     reading and no hourly row in the period).
--     data: made_at, made_by (the caller's name; 'Server' for the server key), record_started_at, silent_minutes, device {id, name,
--     location, active}, period {from_date, to_date, from, to, timezone 'Asia/Kolkata', to_is_now}, hourly_part (null, or {from, to}: the
--     whole UTC hours of the period before the sensor's oldest kept raw hour, served by hourly rows), limits {at_start {min, max, since,
--     since_before (boolean)} or null, changes [{at, min, max, by (a name or null)}], not_recorded_before (the upgrade's India date
--     'YYYY-MM-DD' when the period starts before it, else null)}, summary {temperature {min, max, avg}, humidity {min, max, avg},
--     readings, too_warm_s, too_cold_s, no_readings_s, covered_share}, chart {bucket_s, points [{t, min, max, source raw|hourly}],
--     limit_steps [{from, min, max}]}, stretches (every stretch overlapping the period, oldest first, with its true start and end:
--     {kind, started_at, ended_at, began_before_period, worst, limit, beyond, source, before_upgrade, alert {posted_at, reason, minutes},
--     covering_alert_posted_at}), changes [{at, op, count}] (recorded changes whose readings fall in the period) and
--     changes_not_recorded_before. Times are UTC ISO texts.
--     alert.reason is null when posted_at is set, else, in this order: 'failed' (a post was tried and failed), 'no_channel', the reason of
--     the alert that covered it (below), 'not_recorded' (began before the upgrade), 'shorter' (ended within threshold_minutes; minutes
--     carries them), 'not_posted'. Covered: an out-of-range stretch with no alert of its own that began while the checker still held the
--     alert of an earlier out-of-range stretch (the stretches in between were never back inside for out_minutes, so the alert was not
--     cleared). When that alert was posted, covering_alert_posted_at is its posting time (reason 'not_posted'); when it failed or had no
--     channel, the reason is 'failed' or 'no_channel'. covering_alert_posted_at is null otherwise.
--     Summary: raw readings in the raw part, hourly rows (averages weighted by their counts) in the hourly part; the times out of range
--     and without readings are the stretches cut to the period, covered_share = 1 - no_readings_s / the period's length. Chart buckets:
--     the period / 1,500 rounded up to 5 min, 15 min, 1 h, 3 h, 6 h or 12 h, aligned to India midnight; in the hourly part at least 1 h,
--     from the first hour.
--  2. public.get_sensor_report_devices(): {success:true, data:[{id, name, location, active, first_reading_at, last_reading_at}]}, the
--     sensors with a raw reading or an hourly row, by name; nothing else of a sensor. Same four roles.
-- Customer accounts stay refused on get_sensor_polling_data, get_sensor_history, get_sensor_hourly and get_sensor_device.

-- A UTC ISO text, whatever the session's time zone.
CREATE FUNCTION warehouse_security.report_time(p_at timestamptz) RETURNS text
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'pg_catalog'
AS $function$
  SELECT to_char(p_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
$function$;
ALTER FUNCTION warehouse_security.report_time(timestamptz) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION warehouse_security.report_time(timestamptz) FROM PUBLIC;

CREATE FUNCTION public.get_temperature_report(p_device_id uuid, p_from date, p_to date) RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'warehouse_security'
AS $function$
DECLARE
  v_tz constant text := 'Asia/Kolkata';
  v_today date := (now() AT TIME ZONE 'Asia/Kolkata')::date;
  v_from timestamptz;
  v_to timestamptz;
  v_to_is_now boolean;
  v_period_s numeric;
  v_set warehouse_security.sensor_record_settings;
  v_device record;
  v_oldest_raw timestamptz;
  v_b timestamptz;
  v_h_from timestamptz;
  v_h_to timestamptz;
  v_raw_from timestamptz;
  v_bucket integer;
  v_hbucket integer;
  v_raw record;
  v_hour record;
  v_at_start record;
  v_limits jsonb;
  v_steps jsonb;
  v_stretches jsonb;
  v_times record;
  v_points jsonb;
  v_changes jsonb;
  v_made_by text;
  v_not_recorded text;
BEGIN
  PERFORM warehouse_security.authorize_rpc('get_temperature_report', jsonb_build_object());
  IF p_device_id IS NULL OR p_from IS NULL OR p_to IS NULL OR p_to < p_from OR p_to > v_today THEN
    RETURN jsonb_build_object('success', false, 'error', 'Choose a period that ends today or earlier', 'error_code', 'INVALID_PERIOD');
  END IF;
  IF p_to >= (p_from + interval '12 months')::date THEN
    RETURN jsonb_build_object('success', false, 'error', 'Choose a period of 12 months or less', 'error_code', 'PERIOD_TOO_LONG');
  END IF;
  IF p_from < (v_today - interval '2 years')::date THEN
    RETURN jsonb_build_object('success', false, 'error', 'Readings are kept for 2 years; choose a later start date', 'error_code', 'PERIOD_TOO_OLD');
  END IF;
  SELECT d.id, d.device_name, d.location, d.active INTO v_device FROM public.sensor_devices d WHERE d.id = p_device_id;
  IF v_device.id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'Device not found', 'error_code', 'DEVICE_NOT_FOUND');
  END IF;
  v_from := p_from::timestamp AT TIME ZONE v_tz;
  v_to := (p_to + 1)::timestamp AT TIME ZONE v_tz;
  v_to_is_now := p_to = v_today;
  IF v_to_is_now THEN v_to := LEAST(v_to, now()); END IF;
  IF NOT EXISTS (SELECT 1 FROM public.sensor_readings x WHERE x.device_id = p_device_id AND x.measured_at >= v_from AND x.measured_at < v_to)
     AND NOT EXISTS (SELECT 1 FROM public.sensor_hourly h WHERE h.device_id = p_device_id AND h.hour >= v_from AND h.hour < v_to) THEN
    RETURN jsonb_build_object('success', false, 'error', 'This sensor has no readings in this period', 'error_code', 'NO_READINGS');
  END IF;
  SELECT * INTO v_set FROM warehouse_security.sensor_record_settings s WHERE s.id;
  v_period_s := GREATEST(extract(epoch FROM v_to - v_from), 1);

  -- The parts: whole UTC hours before the sensor's oldest kept raw hour come from hourly rows, the rest from raw readings.
  SELECT min(x.measured_at) INTO v_oldest_raw FROM public.sensor_readings x WHERE x.device_id = p_device_id;
  v_b := COALESCE(date_trunc('hour', v_oldest_raw, 'UTC') + interval '1 hour', 'infinity'::timestamptz);
  SELECT min(h.hour), max(h.hour) + interval '1 hour' INTO v_h_from, v_h_to
    FROM public.sensor_hourly h
   WHERE h.device_id = p_device_id AND h.hour >= v_from AND h.hour + interval '1 hour' <= LEAST(v_b, v_to);
  v_raw_from := COALESCE(v_h_to, v_from);

  -- Summary.
  SELECT count(*) AS n, min(x.temperature) AS t_min, max(x.temperature) AS t_max, sum(x.temperature) AS t_sum, count(x.temperature) AS t_n,
         min(x.humidity) AS h_min, max(x.humidity) AS h_max, sum(x.humidity) AS h_sum, count(x.humidity) AS h_n
    INTO v_raw
    FROM public.sensor_readings x WHERE x.device_id = p_device_id AND x.measured_at >= v_raw_from AND x.measured_at < v_to;
  SELECT COALESCE(sum(h.n), 0) AS n, min(h.t_min) AS t_min, max(h.t_max) AS t_max,
         sum(h.t_avg * h.n) FILTER (WHERE h.t_avg IS NOT NULL) AS t_sum, COALESCE(sum(h.n) FILTER (WHERE h.t_avg IS NOT NULL), 0) AS t_n,
         min(h.h_min) AS h_min, max(h.h_max) AS h_max,
         sum(h.h_avg * h.n) FILTER (WHERE h.h_avg IS NOT NULL) AS h_sum, COALESCE(sum(h.n) FILTER (WHERE h.h_avg IS NOT NULL), 0) AS h_n
    INTO v_hour
    FROM public.sensor_hourly h WHERE h.device_id = p_device_id AND h.hour >= v_h_from AND h.hour < v_h_to;

  -- Stretches overlapping the period, with the alert that covered them.
  WITH range_s AS (
    SELECT s.*, lag(s.ended_at) OVER (ORDER BY s.started_at, s.id) AS prev_end
      FROM warehouse_security.sensor_stretches s
     WHERE s.device_id = p_device_id AND s.kind IN ('too_warm', 'too_cold')
       AND s.started_at < v_to AND s.started_at >= v_from - interval '30 days'
  ), episodes AS (
    SELECT r.id, r.started_at, r.alert_state, r.alert_posted_at,
           sum(CASE WHEN r.prev_end IS NULL OR r.started_at - r.prev_end >= make_interval(mins => r.threshold_minutes) THEN 1 ELSE 0 END)
             OVER (ORDER BY r.started_at, r.id) AS episode
      FROM range_s r
  ), covering AS (
    SELECT e.id, c.alert_state AS c_state, c.alert_posted_at AS c_posted
      FROM episodes e
      LEFT JOIN LATERAL (
        SELECT p.alert_state, p.alert_posted_at FROM episodes p
         WHERE p.episode = e.episode AND p.started_at < e.started_at AND p.alert_state IS NOT NULL
           AND (p.alert_state <> 'posted' OR p.alert_posted_at <= e.started_at)
         ORDER BY p.started_at DESC LIMIT 1) c ON true
  ), listed AS (
    SELECT s.*, cv.c_state, cv.c_posted,
           s.started_at < v_set.record_started_at AS before_upgrade
      FROM warehouse_security.sensor_stretches s
      LEFT JOIN covering cv ON cv.id = s.id
     WHERE s.device_id = p_device_id AND s.started_at < v_to AND (s.ended_at IS NULL OR s.ended_at > v_from)
  )
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'kind', r.kind, 'started_at', warehouse_security.report_time(r.started_at),
           'ended_at', warehouse_security.report_time(r.ended_at), 'began_before_period', r.started_at < v_from,
           'worst', r.worst, 'limit', r.limit_value, 'beyond', r.beyond, 'source', r.source, 'before_upgrade', r.before_upgrade,
           'alert', jsonb_build_object(
             'posted_at', warehouse_security.report_time(r.alert_posted_at),
             'reason', CASE
               WHEN r.alert_posted_at IS NOT NULL THEN NULL
               WHEN r.alert_state = 'failed' THEN 'failed'
               WHEN r.alert_state = 'no_channel' THEN 'no_channel'
               WHEN r.c_state = 'posted' THEN 'not_posted'
               WHEN r.c_state = 'failed' THEN 'failed'
               WHEN r.c_state = 'no_channel' THEN 'no_channel'
               WHEN r.before_upgrade THEN 'not_recorded'
               WHEN r.ended_at IS NOT NULL AND r.ended_at - r.started_at < make_interval(mins => r.threshold_minutes) THEN 'shorter'
               ELSE 'not_posted' END,
             'minutes', r.threshold_minutes),
           'covering_alert_posted_at', CASE WHEN r.alert_posted_at IS NULL AND r.alert_state IS NULL AND r.c_state = 'posted'
                                            THEN warehouse_security.report_time(r.c_posted) END
         ) ORDER BY r.started_at, r.id), '[]'::jsonb)
    INTO v_stretches
    FROM listed r;

  SELECT COALESCE(sum(CASE WHEN s.kind = 'too_warm' THEN d END), 0) AS warm, COALESCE(sum(CASE WHEN s.kind = 'too_cold' THEN d END), 0) AS cold,
         COALESCE(sum(CASE WHEN s.kind = 'no_readings' THEN d END), 0) AS gap
    INTO v_times
    FROM warehouse_security.sensor_stretches s
    CROSS JOIN LATERAL (SELECT GREATEST(extract(epoch FROM LEAST(COALESCE(s.ended_at, v_to), v_to) - GREATEST(s.started_at, v_from)), 0) AS d) c
   WHERE s.device_id = p_device_id AND s.started_at < v_to AND (s.ended_at IS NULL OR s.ended_at > v_from);

  -- Limits in force.
  SELECT c.id, c.temperature_min, c.temperature_max, c.changed_at, c.source INTO v_at_start
    FROM warehouse_security.sensor_limit_changes c
   WHERE c.device_id = p_device_id
   ORDER BY (c.changed_at <= v_from) DESC,
            CASE WHEN c.changed_at <= v_from THEN c.changed_at END DESC NULLS LAST,
            CASE WHEN c.changed_at <= v_from THEN c.id END DESC NULLS LAST,
            c.changed_at, c.id
   LIMIT 1;
  SELECT COALESCE(jsonb_agg(jsonb_build_object('at', warehouse_security.report_time(c.changed_at), 'min', c.temperature_min,
           'max', c.temperature_max, 'by', c.changed_by_name) ORDER BY c.changed_at, c.id), '[]'::jsonb),
         COALESCE(jsonb_agg(jsonb_build_object('from', warehouse_security.report_time(c.changed_at), 'min', c.temperature_min,
           'max', c.temperature_max) ORDER BY c.changed_at, c.id), '[]'::jsonb)
    INTO v_limits, v_steps
    FROM warehouse_security.sensor_limit_changes c
   WHERE c.device_id = p_device_id AND c.changed_at > v_from AND c.changed_at < v_to AND c.id IS DISTINCT FROM v_at_start.id;
  IF v_at_start.id IS NOT NULL THEN
    v_steps := jsonb_build_array(jsonb_build_object('from', warehouse_security.report_time(v_from), 'min', v_at_start.temperature_min,
      'max', v_at_start.temperature_max)) || v_steps;
  END IF;
  v_not_recorded := CASE WHEN v_from < v_set.record_started_at
                         THEN to_char(v_set.record_started_at AT TIME ZONE v_tz, 'YYYY-MM-DD') END;

  -- Chart.
  v_bucket := COALESCE((SELECT b FROM unnest(ARRAY[300, 900, 3600, 10800, 21600, 43200]) b WHERE b >= v_period_s / 1500 ORDER BY b LIMIT 1), 43200);
  v_hbucket := GREATEST(v_bucket, 3600);
  SELECT COALESCE(jsonb_agg(jsonb_build_object('t', warehouse_security.report_time(p.t), 'min', p.lo, 'max', p.hi, 'source', p.source)
           ORDER BY p.t), '[]'::jsonb)
    INTO v_points
    FROM (
      SELECT v_h_from + make_interval(secs => floor(extract(epoch FROM h.hour - v_h_from) / v_hbucket) * v_hbucket) AS t,
             min(h.t_min) AS lo, max(h.t_max) AS hi, 'hourly' AS source
        FROM public.sensor_hourly h
       WHERE h.device_id = p_device_id AND h.hour >= v_h_from AND h.hour < v_h_to AND h.t_min IS NOT NULL
       GROUP BY 1
      UNION ALL
      SELECT v_from + make_interval(secs => floor(extract(epoch FROM x.measured_at - v_from) / v_bucket) * v_bucket),
             min(x.temperature), max(x.temperature), 'raw'
        FROM public.sensor_readings x
       WHERE x.device_id = p_device_id AND x.measured_at >= v_raw_from AND x.measured_at < v_to AND x.temperature IS NOT NULL
       GROUP BY 1
    ) p;

  -- Recorded changes to readings of the period.
  SELECT COALESCE(jsonb_agg(jsonb_build_object('at', warehouse_security.report_time(c.at), 'op', c.op, 'count', c.row_count)
           ORDER BY c.at, c.id), '[]'::jsonb)
    INTO v_changes
    FROM warehouse_security.sensor_reading_changes c
   WHERE c.device_id = p_device_id AND COALESCE(c.first_measured, c.at) < v_to AND COALESCE(c.last_measured, c.at) >= v_from;

  SELECT COALESCE(p.display_name, p.name) INTO v_made_by FROM public.user_profiles p WHERE p.id = public.get_current_user_profile_id();

  RETURN jsonb_build_object('success', true, 'data', jsonb_build_object(
    'made_at', warehouse_security.report_time(now()),
    'made_by', COALESCE(v_made_by, 'Server'),
    'record_started_at', warehouse_security.report_time(v_set.record_started_at),
    'silent_minutes', v_set.silent_minutes,
    'device', jsonb_build_object('id', v_device.id, 'name', v_device.device_name, 'location', v_device.location, 'active', v_device.active),
    'period', jsonb_build_object('from_date', to_char(p_from, 'YYYY-MM-DD'), 'to_date', to_char(p_to, 'YYYY-MM-DD'),
      'from', warehouse_security.report_time(v_from), 'to', warehouse_security.report_time(v_to), 'timezone', v_tz, 'to_is_now', v_to_is_now),
    'hourly_part', CASE WHEN v_h_from IS NULL THEN NULL
                        ELSE jsonb_build_object('from', warehouse_security.report_time(v_h_from), 'to', warehouse_security.report_time(v_h_to)) END,
    'limits', jsonb_build_object(
      'at_start', CASE WHEN v_at_start.id IS NULL THEN NULL ELSE jsonb_build_object('min', v_at_start.temperature_min,
        'max', v_at_start.temperature_max, 'since', warehouse_security.report_time(v_at_start.changed_at),
        'since_before', v_at_start.source = 'since_before') END,
      'changes', v_limits,
      'not_recorded_before', v_not_recorded),
    'summary', jsonb_build_object(
      'temperature', jsonb_build_object('min', LEAST(v_raw.t_min, v_hour.t_min), 'max', GREATEST(v_raw.t_max, v_hour.t_max),
        'avg', round((COALESCE(v_raw.t_sum, 0) + COALESCE(v_hour.t_sum, 0)) / NULLIF(v_raw.t_n + v_hour.t_n, 0), 2)),
      'humidity', jsonb_build_object('min', LEAST(v_raw.h_min, v_hour.h_min), 'max', GREATEST(v_raw.h_max, v_hour.h_max),
        'avg', round((COALESCE(v_raw.h_sum, 0) + COALESCE(v_hour.h_sum, 0)) / NULLIF(v_raw.h_n + v_hour.h_n, 0), 2)),
      'readings', v_raw.n + v_hour.n,
      'too_warm_s', round(v_times.warm), 'too_cold_s', round(v_times.cold), 'no_readings_s', round(v_times.gap),
      'covered_share', round(GREATEST(0, 1 - v_times.gap / v_period_s), 4)),
    'chart', jsonb_build_object('bucket_s', v_bucket, 'points', v_points, 'limit_steps', v_steps),
    'stretches', v_stretches,
    'changes', v_changes,
    'changes_not_recorded_before', v_not_recorded));
END $function$;
ALTER FUNCTION public.get_temperature_report(uuid, date, date) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION public.get_temperature_report(uuid, date, date) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.get_temperature_report(uuid, date, date) TO authenticated, service_role;

CREATE FUNCTION public.get_sensor_report_devices() RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public'
AS $function$
DECLARE
  v_rows jsonb;
BEGIN
  PERFORM warehouse_security.authorize_rpc('get_sensor_report_devices', jsonb_build_object());
  SELECT COALESCE(jsonb_agg(jsonb_build_object('id', s.id, 'name', s.device_name, 'location', s.location, 'active', s.active,
           'first_reading_at', warehouse_security.report_time(s.first_at), 'last_reading_at', warehouse_security.report_time(s.last_at))
           ORDER BY s.device_name, s.id), '[]'::jsonb)
    INTO v_rows
    FROM (
      SELECT d.id, d.device_name, d.location, d.active,
             LEAST((SELECT min(h.hour) FROM public.sensor_hourly h WHERE h.device_id = d.id),
                   (SELECT min(x.measured_at) FROM public.sensor_readings x WHERE x.device_id = d.id)) AS first_at,
             GREATEST((SELECT max(h.hour) + interval '1 hour' FROM public.sensor_hourly h WHERE h.device_id = d.id),
                      (SELECT max(x.measured_at) FROM public.sensor_readings x WHERE x.device_id = d.id)) AS last_at
        FROM public.sensor_devices d
    ) s
   WHERE s.first_at IS NOT NULL;
  RETURN jsonb_build_object('success', true, 'data', v_rows);
END $function$;
ALTER FUNCTION public.get_sensor_report_devices() OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION public.get_sensor_report_devices() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.get_sensor_report_devices() TO authenticated, service_role;
