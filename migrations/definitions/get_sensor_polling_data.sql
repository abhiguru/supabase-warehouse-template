-- public.get_sensor_polling_data: the definition setup applies after the numbered migrations whenever this file's checksum changes
-- (scripts/migration-plan.mjs, table warehouse_migrations.definitions). Edit the function here, never in a new migration.
-- Starts as the function migrations 000 to 126 leave (the numbered files that patched it stay as they are, never edited).
CREATE OR REPLACE FUNCTION public.get_sensor_polling_data(p_since_timestamp timestamp with time zone DEFAULT NULL::timestamp with time zone)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'extensions', 'utils', 'pg_temp'
AS $function$
DECLARE
    v_devices JSONB;
    v_new_readings JSONB;
    v_dashboard JSONB;
    v_poll_timestamp TIMESTAMPTZ;
BEGIN
  PERFORM warehouse_security.authorize_rpc('get_sensor_polling_data',jsonb_build_object());
    v_poll_timestamp := NOW();

    SELECT COALESCE(jsonb_agg(jsonb_build_object(
        'id', s.device_id,
        'device_name', s.device_name,
        'mac_address', s.mac_address,
        'location', s.location,
        'active', s.active,
        'health_status', s.health_status,
        'battery_status', s.battery_status,
        'connectivity_status', s.connectivity_status,
        'is_stale', s.stale,
        'last_reading_at', s.measured_at,
        'staleness_threshold_minutes', s.staleness_threshold_minutes,
        'consecutive_failures', s.consecutive_failures,
        'latest_temperature', s.temperature,
        'latest_humidity', s.humidity,
        'latest_reading_timestamp', s.measured_at,
        'earliest_reading_at', (SELECT min(r.measured_at) FROM public.sensor_readings r WHERE r.device_id = s.device_id),
        'measured_at', s.measured_at,
        'temperature_at', s.temperature_at,
        'humidity_at', s.humidity_at,
        'external_id', s.external_id,
        'model', s.model,
        'hub_id', s.hub_id,
        'hub_online', s.hub_online,
        'battery_low', s.battery_low,
        'battery_percent', s.battery_percent,
        'signal_level', s.signal_level,
        'report_interval_s', s.report_interval_s,
        'last_seen_at', s.last_seen_at,
        'values_stale', s.values_stale,
        'alert_config', s.alert_config,
        'temperature_alert', s.temperature_alert
      ) ORDER BY s.device_name, s.device_id), '[]'::jsonb)
    INTO v_devices
    FROM public.sensor_status s
    WHERE s.active;

    IF p_since_timestamp IS NOT NULL THEN
        SELECT COALESCE(jsonb_agg(jsonb_build_object(
            'device_id', q.device_id,
            'device_name', q.device_name,
            'mac_address', q.mac_address,
            'temperature', q.temperature,
            'humidity', q.humidity,
            'recorded_at', q.measured_at,
            'measured_at', q.measured_at
          ) ORDER BY q.measured_at DESC, q.device_id), '[]'::jsonb)
        INTO v_new_readings
        FROM (
            SELECT r.device_id, d.device_name, d.mac_address, r.temperature, r.humidity, r.measured_at
            FROM public.sensor_readings r
            JOIN public.sensor_devices d ON d.id = r.device_id
            WHERE r.measured_at > p_since_timestamp AND d.active
            ORDER BY r.measured_at DESC
            LIMIT 1000
        ) q;
    ELSE
        v_new_readings := '[]'::jsonb;
    END IF;

    SELECT jsonb_build_object(
        'total_active_sensors', count(*),
        'online_sensors', count(*) FILTER (WHERE s.connectivity_status = 'ONLINE'),
        'offline_sensors', count(*) FILTER (WHERE s.connectivity_status = 'OFFLINE'),
        'stale_sensors', count(*) FILTER (WHERE s.connectivity_status = 'STALE'),
        'low_battery_count', count(*) FILTER (WHERE s.battery_status = 'LOW'),
        'critical_battery_count', count(*) FILTER (WHERE s.battery_status = 'CRITICAL'),
        'sensors_with_failures', count(*) FILTER (WHERE s.consecutive_failures > 0),
        'most_recent_sync', max(s.last_seen_at)
    ) INTO v_dashboard
    FROM public.sensor_status s
    WHERE s.active;

    RETURN jsonb_build_object(
        'success', true,
        'poll_timestamp', v_poll_timestamp,
        'devices', v_devices,
        'new_readings', v_new_readings,
        'dashboard', v_dashboard
    );
END;
$function$;

REVOKE ALL ON FUNCTION public.get_sensor_polling_data(timestamp with time zone) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.get_sensor_polling_data(timestamp with time zone) TO service_role, authenticated;
