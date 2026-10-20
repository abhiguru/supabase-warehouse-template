-- Sensor temperature limits (owner-approved review R4-01, 2026-10-20).
--
-- 1. update_sensor_device takes a lowest and a highest temperature. They are stored where the
--    app already reads them, in sensor_devices.alert_config (temperature_min, temperature_max;
--    the detail chart draws them as dashed lines). No new column.
--    The signature grows by three parameters with defaults, so a call with the four old
--    parameters, by name, behaves as before: the limits are touched only when
--    p_set_temperature_limits is true, and then both are set as given (NULL clears one).
--    The old four-parameter function is dropped: two overloads would make a call with fewer
--    arguments ambiguous. Grants are the old ones: the service role and the app role.
-- 2. sensor_status gets a last column, temperature_alert: 'HIGH' when the newest temperature is
--    above the sensor's highest limit, 'LOW' when below its lowest, else NULL. No flag for a
--    sensor whose hub is offline or whose temperature is older than its staleness threshold
--    (judged by the temperature's own time, temperature_at): its reading is not current.
--    get_sensor_device passes it through (to_jsonb of the view row); get_sensor_polling_data
--    lists its keys, so it is patched to send temperature_alert as well. An older app ignores
--    the extra key, and a newer app against a server without it treats a missing key as no alert.
--
-- Roles are not touched. Only update_sensor_device, sensor_status and get_sensor_polling_data
-- are redefined.

DROP FUNCTION public.update_sensor_device(uuid, text, text, integer);

CREATE FUNCTION public.update_sensor_device(
  p_device_id uuid,
  p_device_name text DEFAULT NULL::text,
  p_location text DEFAULT NULL::text,
  p_staleness_threshold_minutes integer DEFAULT NULL::integer,
  p_temperature_min numeric DEFAULT NULL::numeric,
  p_temperature_max numeric DEFAULT NULL::numeric,
  p_set_temperature_limits boolean DEFAULT false
) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'extensions', 'utils', 'pg_temp'
    AS $_$
DECLARE
  v_name text;
  v_location text;
  v_device public.sensor_devices;
BEGIN
  PERFORM warehouse_security.authorize_rpc('update_sensor_device', jsonb_build_object('p_device_id', p_device_id));
  v_name := btrim(p_device_name);
  v_location := btrim(p_location);
  IF p_device_name IS NOT NULL AND v_name !~ '^[^[:cntrl:]]{1,100}$' THEN
    RETURN jsonb_build_object('success', false, 'error', 'The name must have 1 to 100 characters', 'error_code', 'INVALID_NAME');
  END IF;
  IF p_location IS NOT NULL AND v_location !~ '^[^[:cntrl:]]{0,200}$' THEN
    RETURN jsonb_build_object('success', false, 'error', 'The location must have at most 200 characters', 'error_code', 'INVALID_LOCATION');
  END IF;
  IF p_staleness_threshold_minutes IS NOT NULL AND p_staleness_threshold_minutes NOT BETWEEN 5 AND 1440 THEN
    RETURN jsonb_build_object('success', false, 'error', 'The threshold must be 5 to 1440 minutes', 'error_code', 'INVALID_THRESHOLD');
  END IF;
  IF COALESCE(p_set_temperature_limits, false) THEN
    IF (p_temperature_min IS NOT NULL AND p_temperature_min NOT BETWEEN -100 AND 100)
       OR (p_temperature_max IS NOT NULL AND p_temperature_max NOT BETWEEN -100 AND 100) THEN
      RETURN jsonb_build_object('success', false, 'error', 'A temperature limit must be from -100 to 100 degrees C', 'error_code', 'INVALID_TEMPERATURE_LIMIT');
    END IF;
    IF p_temperature_min IS NOT NULL AND p_temperature_max IS NOT NULL AND p_temperature_min >= p_temperature_max THEN
      RETURN jsonb_build_object('success', false, 'error', 'The lowest temperature must be below the highest', 'error_code', 'INVALID_TEMPERATURE_LIMIT');
    END IF;
  END IF;
  UPDATE public.sensor_devices d SET
    device_name = COALESCE(v_name, d.device_name),
    location = CASE WHEN p_location IS NULL THEN d.location ELSE NULLIF(v_location, '') END,
    staleness_threshold_minutes = COALESCE(p_staleness_threshold_minutes, d.staleness_threshold_minutes),
    alert_config = CASE WHEN COALESCE(p_set_temperature_limits, false)
      THEN (CASE WHEN jsonb_typeof(d.alert_config) = 'object' THEN d.alert_config ELSE '{}'::jsonb END
              - 'temperature_min' - 'temperature_max')
           || jsonb_strip_nulls(jsonb_build_object('temperature_min', p_temperature_min, 'temperature_max', p_temperature_max))
      ELSE d.alert_config END,
    updated_at = now()
  WHERE d.id = p_device_id
  RETURNING d.* INTO v_device;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'Device not found', 'error_code', 'DEVICE_NOT_FOUND');
  END IF;
  UPDATE public.sensor_latest l SET device_name = v_device.device_name, location = v_device.location, updated_at = now()
  WHERE l.device_id = p_device_id;
  RETURN jsonb_build_object('success', true, 'data', jsonb_build_object(
    'device_id', v_device.id, 'device_name', v_device.device_name, 'location', v_device.location,
    'staleness_threshold_minutes', v_device.staleness_threshold_minutes));
END;
$_$;

ALTER FUNCTION public.update_sensor_device(p_device_id uuid, p_device_name text, p_location text, p_staleness_threshold_minutes integer, p_temperature_min numeric, p_temperature_max numeric, p_set_temperature_limits boolean) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION public.update_sensor_device(p_device_id uuid, p_device_name text, p_location text, p_staleness_threshold_minutes integer, p_temperature_min numeric, p_temperature_max numeric, p_set_temperature_limits boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION public.update_sensor_device(p_device_id uuid, p_device_name text, p_location text, p_staleness_threshold_minutes integer, p_temperature_min numeric, p_temperature_max numeric, p_set_temperature_limits boolean) TO service_role;
GRANT ALL ON FUNCTION public.update_sensor_device(p_device_id uuid, p_device_name text, p_location text, p_staleness_threshold_minutes integer, p_temperature_min numeric, p_temperature_max numeric, p_set_temperature_limits boolean) TO authenticated;

CREATE OR REPLACE VIEW public.sensor_status WITH (security_invoker='true') AS
 WITH base AS (
         SELECT d.id AS device_id,
            d.device_name,
            d.location,
            d.active,
            d.external_id,
            d.mac_address,
            d.model,
            d.hub_id,
            h.host AS hub_host,
            h.online AS hub_online,
            l.temperature,
            l.humidity,
            l.measured_at,
            l.temperature_at,
            l.humidity_at,
            COALESCE(l.battery_low, d.battery_low) AS battery_low,
            d.battery_percent,
            COALESCE(l.signal_level, d.signal_level) AS signal_level,
            COALESCE(l.report_interval_s, d.report_interval_s) AS report_interval_s,
            GREATEST(l.last_seen_at, d.last_seen_at) AS last_seen_at,
            COALESCE(d.staleness_threshold_minutes, 30) AS staleness_threshold_minutes,
            d.alert_config,
            d.consecutive_failures,
            l.updated_at
           FROM ((public.sensor_devices d
             LEFT JOIN public.sensor_latest l ON ((l.device_id = d.id)))
             LEFT JOIN public.sensor_hubs h ON ((h.hub_id = d.hub_id)))
        ), flagged AS (
         SELECT b.device_id,
            b.device_name,
            b.location,
            b.active,
            b.external_id,
            b.mac_address,
            b.model,
            b.hub_id,
            b.hub_host,
            b.hub_online,
            b.temperature,
            b.humidity,
            b.measured_at,
            b.temperature_at,
            b.humidity_at,
            b.battery_low,
            b.battery_percent,
            b.signal_level,
            b.report_interval_s,
            b.last_seen_at,
            b.staleness_threshold_minutes,
            b.alert_config,
            b.consecutive_failures,
            b.updated_at,
            ((b.last_seen_at IS NULL) OR (b.last_seen_at < (now() - make_interval(mins => b.staleness_threshold_minutes)))) AS stale,
            ((b.measured_at IS NULL) OR (b.measured_at < (now() - make_interval(mins => b.staleness_threshold_minutes)))) AS values_stale
           FROM base b
        ), status AS (
         SELECT f.device_id,
            f.device_name,
            f.location,
            f.active,
            f.external_id,
            f.mac_address,
            f.model,
            f.hub_id,
            f.hub_host,
            f.hub_online,
            f.temperature,
            f.humidity,
            f.measured_at,
            f.temperature_at,
            f.humidity_at,
            f.battery_low,
            f.battery_percent,
            f.signal_level,
            f.report_interval_s,
            f.last_seen_at,
            f.staleness_threshold_minutes,
            f.alert_config,
            f.consecutive_failures,
            f.updated_at,
            f.stale,
            f.values_stale,
                CASE
                    WHEN (f.hub_online IS FALSE) THEN 'OFFLINE'::text
                    WHEN (f.last_seen_at IS NULL) THEN 'UNKNOWN'::text
                    WHEN f.stale THEN 'STALE'::text
                    ELSE 'ONLINE'::text
                END AS connectivity_status,
                CASE
                    WHEN f.battery_low THEN 'LOW'::text
                    WHEN (NOT f.battery_low) THEN 'OK'::text
                    ELSE 'UNKNOWN'::text
                END AS battery_status
           FROM flagged f
        )
 SELECT s.device_id,
    s.device_name,
    s.location,
    s.active,
    s.external_id,
    s.mac_address,
    s.model,
    s.hub_id,
    s.hub_host,
    s.hub_online,
    s.temperature,
    s.humidity,
    s.measured_at,
    s.temperature_at,
    s.humidity_at,
    s.battery_low,
    s.battery_percent,
    s.signal_level,
    s.report_interval_s,
    s.last_seen_at,
    s.staleness_threshold_minutes,
    s.alert_config,
    s.consecutive_failures,
    s.updated_at,
    s.stale,
    s.values_stale,
    s.connectivity_status,
    s.battery_status,
        CASE
            WHEN (s.connectivity_status = 'UNKNOWN'::text) THEN 'unknown'::text
            WHEN (s.connectivity_status = ANY (ARRAY['OFFLINE'::text, 'STALE'::text])) THEN 'offline'::text
            WHEN (s.battery_low OR s.values_stale) THEN 'warning'::text
            ELSE 'healthy'::text
        END AS health_status,
        CASE
            WHEN (s.temperature IS NULL OR s.hub_online IS FALSE
                  OR s.temperature_at IS NULL
                  OR s.temperature_at < (now() - make_interval(mins => s.staleness_threshold_minutes))) THEN NULL::text
            WHEN (jsonb_typeof(s.alert_config -> 'temperature_max') = 'number'
                  AND s.temperature > ((s.alert_config ->> 'temperature_max')::numeric)) THEN 'HIGH'::text
            WHEN (jsonb_typeof(s.alert_config -> 'temperature_min') = 'number'
                  AND s.temperature < ((s.alert_config ->> 'temperature_min')::numeric)) THEN 'LOW'::text
            ELSE NULL::text
        END AS temperature_alert
   FROM status s;

COMMENT ON VIEW public.sensor_status IS 'Each sensor device with its newest values, its hub and the computed stale and status flags (migration 74); temperature_alert (HIGH or LOW) when the newest temperature is outside the sensor''s limits in alert_config. Read by the sensor RPCs.';

-- get_sensor_polling_data lists the keys it sends: add temperature_alert after alert_config.
DO $patch$
DECLARE
  v_def text;
  v_marker constant text := E'''alert_config'', s.alert_config\n';
  v_count integer;
BEGIN
  v_def := pg_get_functiondef('public.get_sensor_polling_data(timestamp with time zone)'::regprocedure);
  v_count := (length(v_def) - length(replace(v_def, v_marker, ''))) / length(v_marker);
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'get_sensor_polling_data: expected the alert_config line once, found %', v_count;
  END IF;
  v_def := replace(v_def, v_marker, E'''alert_config'', s.alert_config,\n        ''temperature_alert'', s.temperature_alert\n');
  EXECUTE v_def;
END
$patch$;
