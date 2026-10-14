-- Migration 74: sensor ingestion through the template (2026-10-13).
--
-- Until now no template backend ingested sensor data. The only collector (a Home Assistant
-- stack) posted to a legacy server, sent temperature and humidity as two rows with 0 in the
-- other column, carried no source time and could not mark a sensor stale. This migration gives
-- the template its own path: a bridge container polls the Tapo hubs, the edge function
-- functions/ingest-sensor-readings checks the request and calls public.record_sensor_batch with
-- the service key, and the app reads the readers below and listens to public.sensor_latest over
-- Realtime.
--
--  1. sensor_readings: measured_at (the time the bridge observed the value; backfilled from
--     recorded_at, which stays the arrival time), temperature and humidity nullable with range
--     checks and at least one present, legacy zero placeholders cleared, one row per device and
--     measured_at.
--  2. sensor_devices: external_id (the hub's child id, 40 hex), hub_id, model, battery_low,
--     battery_percent, signal_level, report_interval_s, last_seen_at. mac_address stays
--     nullable for the legacy rows.
--  3. sensor_hubs: one row per hub, with its online flag as the bridge last reported it.
--  4. sensor_latest: one row per device with the newest value of each kind and when it was
--     measured. Realtime publishes it (staff and above may read it); the app refetches on an
--     event.
--  5. sensor_status: a view over the three with the computed stale and status flags. Nothing is
--     stored that nothing updates: the legacy health_status, battery_status,
--     connectivity_status and is_stale columns of sensor_devices are no longer read.
--  6. warehouse_security.sensor_ingest_keys: SHA-256 hashes of the bridge keys. No role may
--     touch the table; only record_sensor_batch (SECURITY DEFINER) reads it, because the edge
--     function cannot reach warehouse_security through PostgREST. scripts/sensor-ingest-key.sql
--     mints a key.
--  7. record_sensor_batch(p_key, p_hub, p_readings): the ingestion RPC, service role only.
--  8. Readers: get_sensor_polling_data and get_sensor_history rewritten over sensor_status and
--     measured_at with their signatures and envelopes kept; new get_sensor_device and
--     update_sensor_device (administrators only).
--  9. authorize_rpc: staff may call get_sensor_device; update_sensor_device is an
--     administrator's call.
-- 10. Retention: sensor_readings older than 400 days (policy key 'sensor_readings').
-- 11. Dropped: record_sensor_reading and update_sensor (service role only, called by nothing).
--
-- Contract of record_sensor_batch (the edge function is its only caller):
--   p_key       the bearer key, 64 lower-case hex characters
--   p_hub       {id, host, online, firmware, bridge:{id, version}}; id and online required
--   p_readings  array of at most 500 objects {external_id (40 hex, any case), name, model, temperature,
--               humidity, measured_at (ISO 8601 with an offset), battery_low, battery_percent,
--               signal_level, report_interval_s, kind ('change'|'heartbeat')}
--   refusals    {success:false, code:'invalid_key'|'invalid_hub'|'invalid_readings'|
--               'too_many_readings'}; nothing is written
--   success     {success:true, data:{accepted, duplicates, rejected, rejected_reasons:{reason:n},
--               heartbeats, devices_seen, devices_created, hub_id, hub_online}}
-- A reading is rejected (counted by reason, the rest of the batch is kept) when it is not an
-- object ('malformed'), its external_id is not 40 hex ('bad_external_id'), measured_at is not
-- an ISO time with an offset ('bad_time') or lies outside [now - 30 days, now + 5 minutes]
-- ('out_of_window'), a value is not a number ('bad_value') or out of range (-50..80 degrees,
-- 0..100 percent: 'out_of_range'), or both values are missing on a reading that is not a
-- heartbeat ('no_values'). A heartbeat without values refreshes last_seen_at, battery and
-- signal only; one with values (what the bridge sends) is stored like any reading. heartbeats
-- counts the readings of kind 'heartbeat' that were not rejected, so one with values is also
-- in accepted or duplicates. external_id is accepted in either case and stored upper case. A
-- re-sent reading (same device and measured_at) is a duplicate and changes nothing.

-- Replaces one marker in a function body, failing unless it occurs exactly
-- `expected` times. Dropped at the end of this migration. Every before-text below
-- is absent from its after-text, so a second direct run fails on the count.
CREATE FUNCTION pg_temp.patch_rpc(fn regprocedure, marker text, replacement text, expected integer DEFAULT 1) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE definition text := pg_get_functiondef(fn); occurrences integer;
BEGIN
  occurrences := (length(definition)-length(replace(definition,marker,'')))/length(marker);
  IF occurrences <> expected THEN
    RAISE EXCEPTION 'Expected % occurrence(s) of the marker in %, found %: %', expected, fn, occurrences, left(marker,80);
  END IF;
  EXECUTE replace(definition,marker,replacement);
END $$;

-- ---------------------------------------------------------------------------
-- 1. sensor_readings
-- ---------------------------------------------------------------------------
ALTER TABLE public.sensor_readings ADD COLUMN measured_at timestamptz;
UPDATE public.sensor_readings SET measured_at = recorded_at;
ALTER TABLE public.sensor_readings
  ALTER COLUMN measured_at SET NOT NULL,
  ALTER COLUMN temperature DROP NOT NULL,
  ALTER COLUMN humidity DROP NOT NULL;
COMMENT ON COLUMN public.sensor_readings.measured_at IS
  'When the value was observed (migration 74). For rows written before migration 74, recorded_at.';
COMMENT ON COLUMN public.sensor_readings.recorded_at IS
  'When the row was stored.';

-- The legacy collector sent each value as its own row with 0 in the other column. A
-- temperature of 0 beside a real humidity is such a placeholder, and so is a relative humidity
-- of 0, which a cold store does not have. Values outside the sensor's range are read errors.
-- A row left with no value is removed. Then rows of one device and one moment are merged
-- (the newest stored value of each kind is kept), so that the unique key can be added.
DO $clean$
DECLARE affected bigint;
BEGIN
  UPDATE public.sensor_readings SET temperature = NULL WHERE temperature = 0 AND humidity > 0;
  GET DIAGNOSTICS affected = ROW_COUNT;
  IF affected > 0 THEN RAISE NOTICE 'Migration 74: % zero temperature placeholder(s) cleared', affected; END IF;
  UPDATE public.sensor_readings SET humidity = NULL WHERE humidity = 0;
  GET DIAGNOSTICS affected = ROW_COUNT;
  IF affected > 0 THEN RAISE NOTICE 'Migration 74: % zero humidity placeholder(s) cleared', affected; END IF;
  UPDATE public.sensor_readings SET temperature = NULL WHERE temperature < -50 OR temperature > 80;
  GET DIAGNOSTICS affected = ROW_COUNT;
  IF affected > 0 THEN RAISE NOTICE 'Migration 74: % temperature(s) outside -50..80 cleared', affected; END IF;
  UPDATE public.sensor_readings SET humidity = NULL WHERE humidity < 0 OR humidity > 100;
  GET DIAGNOSTICS affected = ROW_COUNT;
  IF affected > 0 THEN RAISE NOTICE 'Migration 74: % humidity value(s) outside 0..100 cleared', affected; END IF;
  DELETE FROM public.sensor_readings WHERE temperature IS NULL AND humidity IS NULL;
  GET DIAGNOSTICS affected = ROW_COUNT;
  IF affected > 0 THEN RAISE NOTICE 'Migration 74: % reading(s) without any value removed', affected; END IF;
  WITH groups AS (
    SELECT device_id, measured_at,
      (array_agg(id ORDER BY recorded_at, id))[1] AS keep_id,
      (array_agg(temperature ORDER BY recorded_at DESC, id DESC) FILTER (WHERE temperature IS NOT NULL))[1] AS temperature,
      (array_agg(humidity ORDER BY recorded_at DESC, id DESC) FILTER (WHERE humidity IS NOT NULL))[1] AS humidity
    FROM public.sensor_readings
    GROUP BY device_id, measured_at
    HAVING count(*) > 1
  ), kept AS (
    -- A data-modifying WITH runs whether or not it is referenced.
    UPDATE public.sensor_readings r SET temperature = g.temperature, humidity = g.humidity
    FROM groups g WHERE r.id = g.keep_id
  )
  DELETE FROM public.sensor_readings r USING groups g
  WHERE r.device_id = g.device_id AND r.measured_at = g.measured_at AND r.id <> g.keep_id;
  GET DIAGNOSTICS affected = ROW_COUNT;
  IF affected > 0 THEN RAISE NOTICE 'Migration 74: % reading(s) of the same device and moment merged', affected; END IF;
END $clean$;

ALTER TABLE public.sensor_readings
  ADD CONSTRAINT sensor_readings_has_value CHECK (temperature IS NOT NULL OR humidity IS NOT NULL),
  ADD CONSTRAINT sensor_readings_temperature_range CHECK (temperature BETWEEN -50 AND 80),
  ADD CONSTRAINT sensor_readings_humidity_range CHECK (humidity BETWEEN 0 AND 100),
  ADD CONSTRAINT sensor_readings_device_measured_key UNIQUE (device_id, measured_at);
CREATE INDEX sensor_readings_measured_at_idx ON public.sensor_readings (measured_at);

-- ---------------------------------------------------------------------------
-- 2 and 3. sensor_hubs, sensor_devices
-- ---------------------------------------------------------------------------
CREATE TABLE public.sensor_hubs (
  hub_id          text PRIMARY KEY CHECK (hub_id ~ '^[A-Za-z0-9._:-]{1,64}$'),
  host            text CHECK (length(host) <= 255),
  firmware        text CHECK (length(firmware) <= 100),
  bridge_id       text CHECK (length(bridge_id) <= 64),
  bridge_version  text CHECK (length(bridge_version) <= 32),
  online          boolean NOT NULL,
  last_seen_at    timestamptz NOT NULL,
  last_change_at  timestamptz NOT NULL,
  updated_at      timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE public.sensor_hubs IS
  'One row per sensor hub, as the bridge last reported it (migration 74). Written only by record_sensor_batch.';
COMMENT ON COLUMN public.sensor_hubs.online IS 'Whether the bridge reached the hub at its last report.';
COMMENT ON COLUMN public.sensor_hubs.last_seen_at IS 'When the last batch for this hub arrived.';
COMMENT ON COLUMN public.sensor_hubs.last_change_at IS 'When online last changed.';
ALTER TABLE public.sensor_hubs ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.sensor_hubs FROM PUBLIC, anon, authenticated, service_role;
GRANT SELECT ON public.sensor_hubs TO authenticated, service_role;
CREATE POLICY starter_staff ON public.sensor_hubs FOR SELECT TO authenticated
  USING (warehouse_security.active_role() IN ('admin','supervisor','staff'));

ALTER TABLE public.sensor_devices
  ADD COLUMN external_id text CONSTRAINT sensor_devices_external_id_format CHECK (external_id ~ '^[0-9A-F]{40}$'),
  ADD COLUMN hub_id text REFERENCES public.sensor_hubs(hub_id) ON DELETE SET NULL,
  ADD COLUMN model text CHECK (length(model) <= 64),
  ADD COLUMN battery_low boolean,
  ADD COLUMN battery_percent smallint CHECK (battery_percent BETWEEN 0 AND 100),
  ADD COLUMN signal_level smallint CHECK (signal_level BETWEEN 0 AND 100),
  ADD COLUMN report_interval_s integer CHECK (report_interval_s BETWEEN 1 AND 86400),
  ADD COLUMN last_seen_at timestamptz;
CREATE UNIQUE INDEX sensor_devices_external_id_key ON public.sensor_devices (external_id) WHERE external_id IS NOT NULL;
COMMENT ON COLUMN public.sensor_devices.external_id IS
  'The hub''s id of this sensor (40 hex, upper case); NULL for a device registered by MAC before migration 74.';
COMMENT ON COLUMN public.sensor_devices.last_seen_at IS
  'The newest moment the bridge observed this sensor, with or without a value.';
COMMENT ON COLUMN public.sensor_devices.device_name IS
  'Set from the hub''s name when the bridge first reports the sensor; never overwritten by ingestion, so a rename stays.';

-- ---------------------------------------------------------------------------
-- 4. sensor_latest
-- ---------------------------------------------------------------------------
CREATE TABLE public.sensor_latest (
  device_id          uuid PRIMARY KEY REFERENCES public.sensor_devices(id) ON DELETE CASCADE,
  device_name        text NOT NULL,
  location           text,
  hub_id             text REFERENCES public.sensor_hubs(hub_id) ON DELETE SET NULL,
  temperature        numeric(5,2),
  humidity           numeric(5,2),
  measured_at        timestamptz,
  temperature_at     timestamptz,
  humidity_at        timestamptz,
  battery_low        boolean,
  signal_level       smallint,
  report_interval_s  integer,
  last_seen_at       timestamptz,
  updated_at         timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE public.sensor_latest IS
  'The newest state of each sensor (migration 74), written by record_sensor_batch and update_sensor_device. Published to Realtime; a row changes only when something in it is newer.';
COMMENT ON COLUMN public.sensor_latest.measured_at IS 'The newest measured_at of a reading with a value.';
COMMENT ON COLUMN public.sensor_latest.temperature_at IS 'When temperature was measured; it may be older than measured_at.';
COMMENT ON COLUMN public.sensor_latest.humidity_at IS 'When humidity was measured; it may be older than measured_at.';
COMMENT ON COLUMN public.sensor_latest.last_seen_at IS 'The newest observation of the sensor, a heartbeat without values included.';
ALTER TABLE public.sensor_latest ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.sensor_latest FROM PUBLIC, anon, authenticated, service_role;
GRANT SELECT ON public.sensor_latest TO authenticated, service_role;
CREATE POLICY starter_staff ON public.sensor_latest FOR SELECT TO authenticated
  USING (warehouse_security.active_role() IN ('admin','supervisor','staff'));
ALTER TABLE public.sensor_latest REPLICA IDENTITY FULL;
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_publication WHERE pubname = 'supabase_realtime') THEN
    CREATE PUBLICATION supabase_realtime;
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM pg_publication_tables
    WHERE pubname = 'supabase_realtime' AND schemaname = 'public' AND tablename = 'sensor_latest'
  ) THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.sensor_latest;
  END IF;
END $$;

-- Backfill from the readings kept above.
INSERT INTO public.sensor_latest(device_id, device_name, location, hub_id, temperature, humidity,
  measured_at, temperature_at, humidity_at, last_seen_at, updated_at)
SELECT d.id, d.device_name, d.location, d.hub_id, t.temperature, h.humidity,
  m.measured_at, t.measured_at, h.measured_at, m.measured_at, now()
FROM public.sensor_devices d
JOIN LATERAL (SELECT max(r.measured_at) AS measured_at FROM public.sensor_readings r WHERE r.device_id = d.id) m
  ON m.measured_at IS NOT NULL
LEFT JOIN LATERAL (SELECT r.temperature, r.measured_at FROM public.sensor_readings r
  WHERE r.device_id = d.id AND r.temperature IS NOT NULL ORDER BY r.measured_at DESC LIMIT 1) t ON true
LEFT JOIN LATERAL (SELECT r.humidity, r.measured_at FROM public.sensor_readings r
  WHERE r.device_id = d.id AND r.humidity IS NOT NULL ORDER BY r.measured_at DESC LIMIT 1) h ON true;
UPDATE public.sensor_devices d SET last_seen_at = l.last_seen_at
FROM public.sensor_latest l WHERE l.device_id = d.id;

-- ---------------------------------------------------------------------------
-- 5. sensor_status
-- ---------------------------------------------------------------------------
-- Every device, registered or reported, with its newest values and its hub.
--   stale         nothing observed within staleness_threshold_minutes (30 by default)
--   values_stale  no value measured within that time
--   connectivity_status  OFFLINE when the hub is reported offline, UNKNOWN when the sensor was
--                 never observed, STALE when stale, otherwise ONLINE
--   battery_status       LOW / OK from battery_low, UNKNOWN when not reported
--   health_status        unknown, offline (OFFLINE or STALE), warning (battery low or values
--                 stale), healthy
-- security_invoker: a reader sees only the rows the table policies give it.
CREATE VIEW public.sensor_status WITH (security_invoker = true) AS
WITH base AS (
  SELECT d.id AS device_id, d.device_name, d.location, d.active, d.external_id, d.mac_address, d.model,
    d.hub_id, h.host AS hub_host, h.online AS hub_online,
    l.temperature, l.humidity, l.measured_at, l.temperature_at, l.humidity_at,
    COALESCE(l.battery_low, d.battery_low) AS battery_low, d.battery_percent,
    COALESCE(l.signal_level, d.signal_level) AS signal_level,
    COALESCE(l.report_interval_s, d.report_interval_s) AS report_interval_s,
    GREATEST(l.last_seen_at, d.last_seen_at) AS last_seen_at,
    COALESCE(d.staleness_threshold_minutes, 30) AS staleness_threshold_minutes,
    d.alert_config, d.consecutive_failures, l.updated_at
  FROM public.sensor_devices d
  LEFT JOIN public.sensor_latest l ON l.device_id = d.id
  LEFT JOIN public.sensor_hubs h ON h.hub_id = d.hub_id
), flagged AS (
  SELECT b.*,
    (b.last_seen_at IS NULL OR b.last_seen_at < now() - make_interval(mins => b.staleness_threshold_minutes)) AS stale,
    (b.measured_at IS NULL OR b.measured_at < now() - make_interval(mins => b.staleness_threshold_minutes)) AS values_stale
  FROM base b
), status AS (
  SELECT f.*,
    CASE WHEN f.hub_online IS FALSE THEN 'OFFLINE'
         WHEN f.last_seen_at IS NULL THEN 'UNKNOWN'
         WHEN f.stale THEN 'STALE'
         ELSE 'ONLINE' END AS connectivity_status,
    CASE WHEN f.battery_low THEN 'LOW' WHEN NOT f.battery_low THEN 'OK' ELSE 'UNKNOWN' END AS battery_status
  FROM flagged f
)
SELECT s.*,
  CASE WHEN s.connectivity_status = 'UNKNOWN' THEN 'unknown'
       WHEN s.connectivity_status IN ('OFFLINE','STALE') THEN 'offline'
       WHEN s.battery_low OR s.values_stale THEN 'warning'
       ELSE 'healthy' END AS health_status
FROM status s;
COMMENT ON VIEW public.sensor_status IS
  'Each sensor device with its newest values, its hub and the computed stale and status flags (migration 74). Read by the sensor RPCs.';
REVOKE ALL ON public.sensor_status FROM PUBLIC, anon, authenticated, service_role;
GRANT SELECT ON public.sensor_status TO service_role;

-- ---------------------------------------------------------------------------
-- 6. Ingest keys
-- ---------------------------------------------------------------------------
-- key_hash is the SHA-256 (hex) of the key. scripts/sensor-ingest-key.sql mints a key and
-- prints it once; a key is revoked by setting revoked_at.
CREATE TABLE warehouse_security.sensor_ingest_keys (
  key_hash      text PRIMARY KEY CHECK (key_hash ~ '^[0-9a-f]{64}$'),
  label         text NOT NULL CHECK (length(label) BETWEEN 1 AND 64),
  created_at    timestamptz NOT NULL DEFAULT now(),
  revoked_at    timestamptz,
  last_used_at  timestamptz
);
ALTER TABLE warehouse_security.sensor_ingest_keys ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON warehouse_security.sensor_ingest_keys FROM PUBLIC, anon, authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 7. record_sensor_batch
-- ---------------------------------------------------------------------------
CREATE FUNCTION public.record_sensor_batch(p_key text, p_hub jsonb, p_readings jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public, extensions, pg_temp AS $$
DECLARE
  v_key_hash text;
  v_hub_id text; v_host text; v_firmware text; v_bridge_id text; v_bridge_version text;
  v_online boolean; v_previous_online boolean;
  v_item jsonb; v_reason text;
  v_ext text; v_name text; v_model text; v_at timestamptz; v_t numeric; v_h numeric; v_no_values boolean;
  v_battery_low boolean; v_battery_percent smallint; v_signal smallint; v_interval integer;
  v_device uuid; v_created boolean; v_inserted integer;
  v_accepted integer := 0; v_duplicates integer := 0; v_rejected integer := 0; v_heartbeats integer := 0;
  v_devices_created integer := 0; v_reasons jsonb := '{}'::jsonb; v_seen text[] := '{}';
BEGIN
  -- The key: 64 lower-case hex, its hash known and not revoked.
  IF p_key IS NULL OR p_key !~ '^[0-9a-f]{64}$' THEN
    RETURN jsonb_build_object('success', false, 'code', 'invalid_key');
  END IF;
  v_key_hash := encode(extensions.digest(p_key, 'sha256'), 'hex');
  IF NOT EXISTS (SELECT 1 FROM warehouse_security.sensor_ingest_keys k
                 WHERE k.key_hash = v_key_hash AND k.revoked_at IS NULL) THEN
    RETURN jsonb_build_object('success', false, 'code', 'invalid_key');
  END IF;
  UPDATE warehouse_security.sensor_ingest_keys k SET last_used_at = now()
  WHERE k.key_hash = v_key_hash AND (k.last_used_at IS NULL OR k.last_used_at < now() - interval '1 minute');

  -- The hub: id and online required; host, firmware and bridge optional, each checked.
  IF p_hub IS NULL OR jsonb_typeof(p_hub) <> 'object' THEN
    RETURN jsonb_build_object('success', false, 'code', 'invalid_hub');
  END IF;
  v_hub_id := CASE WHEN jsonb_typeof(p_hub->'id') = 'string' THEN p_hub->>'id' END;
  v_online := CASE WHEN jsonb_typeof(p_hub->'online') = 'boolean' THEN (p_hub->>'online')::boolean END;
  v_host := CASE WHEN jsonb_typeof(p_hub->'host') = 'string' THEN p_hub->>'host' END;
  v_firmware := CASE WHEN jsonb_typeof(p_hub->'firmware') = 'string' THEN p_hub->>'firmware' END;
  v_bridge_id := CASE WHEN jsonb_typeof(p_hub#>'{bridge,id}') = 'string' THEN p_hub#>>'{bridge,id}' END;
  v_bridge_version := CASE WHEN jsonb_typeof(p_hub#>'{bridge,version}') = 'string' THEN p_hub#>>'{bridge,version}' END;
  IF v_hub_id IS NULL OR v_hub_id !~ '^[A-Za-z0-9._:-]{1,64}$' OR v_online IS NULL
     OR COALESCE(jsonb_typeof(p_hub->'host'), 'null') NOT IN ('string', 'null')
     OR v_host !~ '^[A-Za-z0-9._:\[\]-]{1,255}$'
     OR COALESCE(jsonb_typeof(p_hub->'firmware'), 'null') NOT IN ('string', 'null')
     OR v_firmware !~ '^[^[:cntrl:]]{0,100}$'
     OR COALESCE(jsonb_typeof(p_hub->'bridge'), 'null') NOT IN ('object', 'null')
     OR COALESCE(jsonb_typeof(p_hub#>'{bridge,id}'), 'null') NOT IN ('string', 'null')
     OR v_bridge_id !~ '^[A-Za-z0-9._-]{1,64}$'
     OR COALESCE(jsonb_typeof(p_hub#>'{bridge,version}'), 'null') NOT IN ('string', 'null')
     OR v_bridge_version !~ '^[A-Za-z0-9.+_-]{1,32}$' THEN
    RETURN jsonb_build_object('success', false, 'code', 'invalid_hub');
  END IF;

  IF p_readings IS NULL OR jsonb_typeof(p_readings) <> 'array' THEN
    RETURN jsonb_build_object('success', false, 'code', 'invalid_readings');
  END IF;
  IF jsonb_array_length(p_readings) > 500 THEN
    RETURN jsonb_build_object('success', false, 'code', 'too_many_readings');
  END IF;

  SELECT h.online INTO v_previous_online FROM public.sensor_hubs h WHERE h.hub_id = v_hub_id FOR UPDATE;
  INSERT INTO public.sensor_hubs AS h (hub_id, host, firmware, bridge_id, bridge_version, online, last_seen_at, last_change_at, updated_at)
  VALUES (v_hub_id, v_host, v_firmware, v_bridge_id, v_bridge_version, v_online, now(), now(), now())
  ON CONFLICT (hub_id) DO UPDATE SET
    host = COALESCE(excluded.host, h.host),
    firmware = COALESCE(excluded.firmware, h.firmware),
    bridge_id = COALESCE(excluded.bridge_id, h.bridge_id),
    bridge_version = COALESCE(excluded.bridge_version, h.bridge_version),
    online = excluded.online,
    last_seen_at = now(),
    last_change_at = CASE WHEN h.online IS DISTINCT FROM excluded.online THEN now() ELSE h.last_change_at END,
    updated_at = now();

  FOR v_item IN SELECT e.value FROM jsonb_array_elements(p_readings) AS e LOOP
    v_reason := NULL; v_ext := NULL; v_at := NULL; v_t := NULL; v_h := NULL;
    IF jsonb_typeof(v_item) <> 'object' THEN
      v_reason := 'malformed';
    ELSE
      v_ext := CASE WHEN jsonb_typeof(v_item->'external_id') = 'string' THEN upper(v_item->>'external_id') END;
      IF v_ext IS NULL OR v_ext !~ '^[0-9A-F]{40}$' THEN v_reason := 'bad_external_id'; END IF;
    END IF;
    IF v_reason IS NULL THEN
      -- An explicit offset is required: a time without one would be read in the session's zone.
      IF jsonb_typeof(v_item->'measured_at') = 'string'
         AND v_item->>'measured_at' ~ '^\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}:\d{2}(\.\d{1,6})?(Z|[+-]\d{2}(:?\d{2})?)$' THEN
        BEGIN
          v_at := (v_item->>'measured_at')::timestamptz;
        EXCEPTION WHEN datetime_field_overflow OR invalid_datetime_format THEN
          v_at := NULL;
        END;
      END IF;
      IF v_at IS NULL THEN
        v_reason := 'bad_time';
      ELSIF v_at < now() - interval '30 days' OR v_at > now() + interval '5 minutes' THEN
        v_reason := 'out_of_window';
      END IF;
    END IF;
    IF v_reason IS NULL THEN
      IF jsonb_typeof(v_item->'temperature') = 'number' THEN
        v_t := (v_item->>'temperature')::numeric;
      ELSIF COALESCE(jsonb_typeof(v_item->'temperature'), 'null') <> 'null' THEN
        v_reason := 'bad_value';
      END IF;
      IF jsonb_typeof(v_item->'humidity') = 'number' THEN
        v_h := (v_item->>'humidity')::numeric;
      ELSIF COALESCE(jsonb_typeof(v_item->'humidity'), 'null') <> 'null' THEN
        v_reason := 'bad_value';
      END IF;
    END IF;
    IF v_reason IS NULL AND (v_t < -50 OR v_t > 80 OR v_h < 0 OR v_h > 100) THEN
      v_reason := 'out_of_range';
    END IF;
    v_no_values := v_t IS NULL AND v_h IS NULL;
    IF v_reason IS NULL AND v_no_values AND v_item->>'kind' IS DISTINCT FROM 'heartbeat' THEN
      v_reason := 'no_values';
    END IF;

    IF v_reason IS NOT NULL THEN
      v_rejected := v_rejected + 1;
      v_reasons := jsonb_set(v_reasons, ARRAY[v_reason], to_jsonb(COALESCE((v_reasons->>v_reason)::integer, 0) + 1));
      CONTINUE;
    END IF;

    v_t := round(v_t, 2);
    v_h := round(v_h, 2);
    -- Informational fields: a value of the wrong type or range is ignored, not the reading.
    v_name := CASE WHEN jsonb_typeof(v_item->'name') = 'string' AND btrim(v_item->>'name') ~ '^[^[:cntrl:]]{1,100}$'
                   THEN btrim(v_item->>'name') END;
    v_model := CASE WHEN jsonb_typeof(v_item->'model') = 'string' AND btrim(v_item->>'model') ~ '^[^[:cntrl:]]{1,64}$'
                    THEN btrim(v_item->>'model') END;
    v_battery_low := CASE WHEN jsonb_typeof(v_item->'battery_low') = 'boolean' THEN (v_item->>'battery_low')::boolean END;
    v_battery_percent := CASE WHEN jsonb_typeof(v_item->'battery_percent') = 'number' THEN
      CASE WHEN (v_item->>'battery_percent')::numeric BETWEEN 0 AND 100
            AND (v_item->>'battery_percent')::numeric = trunc((v_item->>'battery_percent')::numeric)
           THEN (v_item->>'battery_percent')::numeric::smallint END END;
    v_signal := CASE WHEN jsonb_typeof(v_item->'signal_level') = 'number' THEN
      CASE WHEN (v_item->>'signal_level')::numeric BETWEEN 0 AND 100
            AND (v_item->>'signal_level')::numeric = trunc((v_item->>'signal_level')::numeric)
           THEN (v_item->>'signal_level')::numeric::smallint END END;
    v_interval := CASE WHEN jsonb_typeof(v_item->'report_interval_s') = 'number' THEN
      CASE WHEN (v_item->>'report_interval_s')::numeric BETWEEN 1 AND 86400
            AND (v_item->>'report_interval_s')::numeric = trunc((v_item->>'report_interval_s')::numeric)
           THEN (v_item->>'report_interval_s')::numeric::integer END END;

    -- The device: created on first sight with the hub's name; afterwards the name is never
    -- touched, and the other fields follow the newest observation only.
    INSERT INTO public.sensor_devices AS d (device_name, external_id, hub_id, model, battery_low, battery_percent,
      signal_level, report_interval_s, last_seen_at, last_reading_at)
    VALUES (COALESCE(v_name, 'Sensor ' || left(v_ext, 8)), v_ext, v_hub_id, v_model, v_battery_low, v_battery_percent,
      v_signal, v_interval, v_at, CASE WHEN NOT v_no_values THEN v_at END)
    ON CONFLICT (external_id) WHERE external_id IS NOT NULL DO UPDATE SET
      hub_id = CASE WHEN excluded.last_seen_at >= COALESCE(d.last_seen_at, '-infinity') THEN excluded.hub_id ELSE d.hub_id END,
      model = CASE WHEN excluded.last_seen_at >= COALESCE(d.last_seen_at, '-infinity') THEN COALESCE(excluded.model, d.model) ELSE d.model END,
      battery_low = CASE WHEN excluded.last_seen_at >= COALESCE(d.last_seen_at, '-infinity') THEN COALESCE(excluded.battery_low, d.battery_low) ELSE d.battery_low END,
      battery_percent = CASE WHEN excluded.last_seen_at >= COALESCE(d.last_seen_at, '-infinity') THEN COALESCE(excluded.battery_percent, d.battery_percent) ELSE d.battery_percent END,
      signal_level = CASE WHEN excluded.last_seen_at >= COALESCE(d.last_seen_at, '-infinity') THEN COALESCE(excluded.signal_level, d.signal_level) ELSE d.signal_level END,
      report_interval_s = CASE WHEN excluded.last_seen_at >= COALESCE(d.last_seen_at, '-infinity') THEN COALESCE(excluded.report_interval_s, d.report_interval_s) ELSE d.report_interval_s END,
      last_seen_at = GREATEST(d.last_seen_at, excluded.last_seen_at),
      last_reading_at = GREATEST(d.last_reading_at, excluded.last_reading_at)
    RETURNING d.id, (d.xmax = 0) INTO v_device, v_created;
    IF v_created THEN v_devices_created := v_devices_created + 1; END IF;
    IF NOT v_ext = ANY (v_seen) THEN v_seen := v_seen || v_ext; END IF;

    -- The bridge marks each reading 'change' or 'heartbeat'; a heartbeat repeats unchanged values
    -- (stored as a reading, so the history has no gap) or, without values, only says the sensor
    -- is there.
    IF v_item->>'kind' = 'heartbeat' THEN
      v_heartbeats := v_heartbeats + 1;
    END IF;
    IF NOT v_no_values THEN
      INSERT INTO public.sensor_readings(device_id, temperature, humidity, measured_at)
      VALUES (v_device, v_t, v_h, v_at)
      ON CONFLICT (device_id, measured_at) DO NOTHING;
      GET DIAGNOSTICS v_inserted = ROW_COUNT;
      IF v_inserted = 1 THEN v_accepted := v_accepted + 1; ELSE v_duplicates := v_duplicates + 1; END IF;
    END IF;

    -- The newest state: each value only when it is newer than the one held, the device fields
    -- only from the newest observation. A row with nothing newer is not touched at all, so a
    -- re-sent or late batch publishes no Realtime event.
    INSERT INTO public.sensor_latest AS l (device_id, device_name, location, hub_id, temperature, humidity,
      measured_at, temperature_at, humidity_at, battery_low, signal_level, report_interval_s, last_seen_at, updated_at)
    SELECT d.id, d.device_name, d.location, v_hub_id, v_t, v_h,
      CASE WHEN NOT v_no_values THEN v_at END, CASE WHEN v_t IS NOT NULL THEN v_at END, CASE WHEN v_h IS NOT NULL THEN v_at END,
      v_battery_low, v_signal, v_interval, v_at, now()
    FROM public.sensor_devices d WHERE d.id = v_device
    ON CONFLICT (device_id) DO UPDATE SET
      temperature = CASE WHEN excluded.temperature_at > COALESCE(l.temperature_at, '-infinity') THEN excluded.temperature ELSE l.temperature END,
      temperature_at = GREATEST(l.temperature_at, excluded.temperature_at),
      humidity = CASE WHEN excluded.humidity_at > COALESCE(l.humidity_at, '-infinity') THEN excluded.humidity ELSE l.humidity END,
      humidity_at = GREATEST(l.humidity_at, excluded.humidity_at),
      measured_at = GREATEST(l.measured_at, excluded.measured_at),
      hub_id = CASE WHEN excluded.last_seen_at >= COALESCE(l.last_seen_at, '-infinity') THEN excluded.hub_id ELSE l.hub_id END,
      battery_low = CASE WHEN excluded.last_seen_at >= COALESCE(l.last_seen_at, '-infinity') THEN COALESCE(excluded.battery_low, l.battery_low) ELSE l.battery_low END,
      signal_level = CASE WHEN excluded.last_seen_at >= COALESCE(l.last_seen_at, '-infinity') THEN COALESCE(excluded.signal_level, l.signal_level) ELSE l.signal_level END,
      report_interval_s = CASE WHEN excluded.last_seen_at >= COALESCE(l.last_seen_at, '-infinity') THEN COALESCE(excluded.report_interval_s, l.report_interval_s) ELSE l.report_interval_s END,
      last_seen_at = GREATEST(l.last_seen_at, excluded.last_seen_at),
      updated_at = now()
    WHERE excluded.last_seen_at > COALESCE(l.last_seen_at, '-infinity')
       OR excluded.temperature_at > COALESCE(l.temperature_at, '-infinity')
       OR excluded.humidity_at > COALESCE(l.humidity_at, '-infinity');
  END LOOP;

  -- A hub that went offline or came back changes the status of its sensors: one event each.
  IF v_previous_online IS DISTINCT FROM v_online AND v_previous_online IS NOT NULL THEN
    UPDATE public.sensor_latest l SET updated_at = now() WHERE l.hub_id = v_hub_id;
  END IF;

  RETURN jsonb_build_object('success', true, 'data', jsonb_build_object(
    'accepted', v_accepted,
    'duplicates', v_duplicates,
    'rejected', v_rejected,
    'rejected_reasons', v_reasons,
    'heartbeats', v_heartbeats,
    'devices_seen', cardinality(v_seen),
    'devices_created', v_devices_created,
    'hub_id', v_hub_id,
    'hub_online', v_online));
END $$;
COMMENT ON FUNCTION public.record_sensor_batch(text, jsonb, jsonb) IS
  'Sensor ingestion (migration 74): one batch of one hub from the bridge, called by functions/ingest-sensor-readings with the service key. The contract is in the header of migration 74.';
REVOKE ALL ON FUNCTION public.record_sensor_batch(text, jsonb, jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.record_sensor_batch(text, jsonb, jsonb) TO service_role;

-- ---------------------------------------------------------------------------
-- 8. Readers
-- ---------------------------------------------------------------------------
-- get_sensor_polling_data: same signature and envelope {success, poll_timestamp, devices[],
-- new_readings[], dashboard}. Each device keeps its keys, now computed from sensor_status
-- (is_stale, connectivity_status, battery_status, health_status; latest_temperature and
-- latest_humidity are the newest value of each kind, latest_reading_timestamp and
-- last_reading_at the newest measured_at), and gains measured_at, temperature_at, humidity_at,
-- external_id, model, hub_id, hub_online, battery_low, battery_percent, signal_level,
-- report_interval_s, last_seen_at, values_stale and alert_config. new_readings are the readings
-- measured after p_since_timestamp (newest first, at most 1000; recorded_at is their
-- measured_at). The guard comes first, as migration 3 put it.
CREATE OR REPLACE FUNCTION public.get_sensor_polling_data(p_since_timestamp timestamp with time zone DEFAULT NULL::timestamp with time zone) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public, extensions, utils, pg_temp AS $$
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
        'alert_config', s.alert_config
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
$$;

-- get_sensor_history: same signature and envelope. Buckets on measured_at; an average ignores
-- the readings without that value; each bucket carries sample_count, temperature_count and
-- humidity_count. Period 1 (the last 24 hours, 5-minute buckets) is added.
CREATE OR REPLACE FUNCTION public.get_sensor_history(p_device_id uuid, p_days_back integer) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public, extensions, utils, pg_temp AS $$
DECLARE
    v_device RECORD;
    v_from_date TIMESTAMPTZ;
    v_to_date TIMESTAMPTZ;
    v_interval TEXT;
    v_interval_seconds INTEGER;
    v_readings JSONB;
    v_summary JSONB;
    v_raw_count INTEGER;
BEGIN
  PERFORM warehouse_security.authorize_rpc('get_sensor_history',jsonb_build_object());
    IF p_days_back IS NULL OR p_days_back NOT IN (1, 7, 14, 30, 90, 365) THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'Invalid period. Must be one of: 1, 7, 14, 30, 90, 365 days',
            'error_code', 'INVALID_PERIOD'
        );
    END IF;

    SELECT d.id, d.device_name, d.location INTO v_device
    FROM public.sensor_devices d WHERE d.id = p_device_id;
    IF v_device.id IS NULL THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'Device not found',
            'error_code', 'DEVICE_NOT_FOUND'
        );
    END IF;

    v_to_date := NOW();
    v_from_date := v_to_date - make_interval(days => p_days_back);
    v_interval := CASE p_days_back
        WHEN 1 THEN '5 minutes'
        WHEN 7 THEN '1 hour'
        WHEN 14 THEN '2 hours'
        WHEN 30 THEN '4 hours'
        WHEN 90 THEN '1 day'
        WHEN 365 THEN '1 week'
    END;
    v_interval_seconds := CASE p_days_back
        WHEN 1 THEN 300
        WHEN 7 THEN 3600
        WHEN 14 THEN 7200
        WHEN 30 THEN 14400
        WHEN 90 THEN 86400
        WHEN 365 THEN 604800
    END;

    SELECT COALESCE(jsonb_agg(jsonb_build_object(
            'timestamp', b.bucket,
            'temperature', ROUND(b.avg_temp, 2),
            'humidity', ROUND(b.avg_hum, 2),
            'sample_count', b.samples,
            'temperature_count', b.temperature_samples,
            'humidity_count', b.humidity_samples
        ) ORDER BY b.bucket ASC), '[]'::jsonb)
    INTO v_readings
    FROM (
        SELECT to_timestamp(floor(extract(epoch FROM r.measured_at) / v_interval_seconds) * v_interval_seconds) AS bucket,
            AVG(r.temperature) AS avg_temp,
            AVG(r.humidity) AS avg_hum,
            COUNT(*) AS samples,
            COUNT(r.temperature) AS temperature_samples,
            COUNT(r.humidity) AS humidity_samples
        FROM public.sensor_readings r
        WHERE r.device_id = p_device_id
          AND r.measured_at >= v_from_date
          AND r.measured_at <= v_to_date
        GROUP BY 1
    ) b;

    SELECT jsonb_build_object(
            'avg_temperature', ROUND(AVG(r.temperature), 2),
            'min_temperature', ROUND(MIN(r.temperature), 2),
            'max_temperature', ROUND(MAX(r.temperature), 2),
            'avg_humidity', ROUND(AVG(r.humidity), 2),
            'min_humidity', ROUND(MIN(r.humidity), 2),
            'max_humidity', ROUND(MAX(r.humidity), 2),
            'total_readings', jsonb_array_length(v_readings)
        ),
        COUNT(*)::INTEGER
    INTO v_summary, v_raw_count
    FROM public.sensor_readings r
    WHERE r.device_id = p_device_id
      AND r.measured_at >= v_from_date
      AND r.measured_at <= v_to_date;

    IF v_raw_count = 0 THEN
        v_summary := jsonb_build_object(
            'avg_temperature', null,
            'min_temperature', null,
            'max_temperature', null,
            'avg_humidity', null,
            'min_humidity', null,
            'max_humidity', null,
            'total_readings', 0
        );
    END IF;

    RETURN jsonb_build_object(
        'success', true,
        'data', jsonb_build_object(
            'device_id', p_device_id,
            'device_name', v_device.device_name,
            'location', v_device.location,
            'period_days', p_days_back,
            'aggregation_interval', v_interval,
            'readings', v_readings,
            'summary', v_summary
        ),
        'metadata', jsonb_build_object(
            'from_date', v_from_date::DATE,
            'to_date', v_to_date::DATE,
            'raw_reading_count', v_raw_count
        )
    );
END;
$$;

-- One sensor: its sensor_status row (and id, the same as device_id), the time of its first
-- reading and its hub. Staff and above. It also carries the keys of one devices[] entry of
-- get_sensor_polling_data (latest_temperature, latest_humidity, latest_reading_timestamp,
-- is_stale, earliest_reading_at), so the app reads both answers as the same device shape;
-- they repeat temperature, humidity, measured_at, stale and first_reading_at.
CREATE FUNCTION public.get_sensor_device(p_device_id uuid) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, public, extensions, utils, pg_temp AS $$
DECLARE
  v_row public.sensor_status;
  v_hub public.sensor_hubs;
  v_first timestamptz;
BEGIN
  PERFORM warehouse_security.authorize_rpc('get_sensor_device', jsonb_build_object('p_device_id', p_device_id));
  SELECT * INTO v_row FROM public.sensor_status s WHERE s.device_id = p_device_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'Device not found', 'error_code', 'DEVICE_NOT_FOUND');
  END IF;
  SELECT * INTO v_hub FROM public.sensor_hubs h WHERE h.hub_id = v_row.hub_id;
  SELECT min(r.measured_at) INTO v_first FROM public.sensor_readings r WHERE r.device_id = p_device_id;
  RETURN jsonb_build_object('success', true, 'data', to_jsonb(v_row) || jsonb_build_object(
    'id', v_row.device_id,
    'first_reading_at', v_first,
    'latest_temperature', v_row.temperature,
    'latest_humidity', v_row.humidity,
    'latest_reading_timestamp', v_row.measured_at,
    'is_stale', v_row.stale,
    'earliest_reading_at', v_first,
    'hub', CASE WHEN v_hub.hub_id IS NULL THEN NULL ELSE jsonb_build_object(
      'id', v_hub.hub_id, 'host', v_hub.host, 'firmware', v_hub.firmware,
      'online', v_hub.online, 'last_seen_at', v_hub.last_seen_at) END));
END;
$$;
REVOKE ALL ON FUNCTION public.get_sensor_device(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_sensor_device(uuid) TO authenticated, service_role;

-- An administrator's settings of one sensor. NULL leaves a field as it is; an empty location
-- clears it. The name and location are copied to sensor_latest, which tells the app.
-- A rename by SQL as the database owner goes through this function too, with the service
-- role's claims:
--   SELECT set_config('request.jwt.claims', '{"role":"service_role"}', true);
--   SELECT public.update_sensor_device('<device id>', 'Chamber 3');
CREATE FUNCTION public.update_sensor_device(p_device_id uuid, p_device_name text DEFAULT NULL,
  p_location text DEFAULT NULL, p_staleness_threshold_minutes integer DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public, extensions, utils, pg_temp AS $$
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
  UPDATE public.sensor_devices d SET
    device_name = COALESCE(v_name, d.device_name),
    location = CASE WHEN p_location IS NULL THEN d.location ELSE NULLIF(v_location, '') END,
    staleness_threshold_minutes = COALESCE(p_staleness_threshold_minutes, d.staleness_threshold_minutes),
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
$$;
REVOKE ALL ON FUNCTION public.update_sensor_device(uuid, text, text, integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.update_sensor_device(uuid, text, text, integer) TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 9. The guard: staff read one sensor; its settings are an administrator's
-- ---------------------------------------------------------------------------
DO $patch$ BEGIN
  PERFORM pg_temp.patch_rpc('warehouse_security.authorize_rpc(text,jsonb)',
  $m$  -- Central identity (migration 49): administrators only.
  IF rpc = 'clear_user_central_identity' THEN
$m$, $r$  -- Central identity (migration 49) and sensor settings (migration 74): administrators only.
  IF rpc IN ('clear_user_central_identity','update_sensor_device') THEN
$r$);
  PERFORM pg_temp.patch_rpc('warehouse_security.authorize_rpc(text,jsonb)',
  $m$    'get_sensor_polling_data','get_sensor_history'
  ) THEN RETURN; END IF;
$m$, $r$    'get_sensor_polling_data','get_sensor_history',
    -- One sensor (migration 74).
    'get_sensor_device'
  ) THEN RETURN; END IF;
$r$);
END $patch$;

-- ---------------------------------------------------------------------------
-- 10. Retention: readings older than 400 days
-- ---------------------------------------------------------------------------
INSERT INTO warehouse_maintenance.retention_policy(key, days, description) VALUES
  ('sensor_readings', 400, 'Sensor readings (temperature and humidity history)');
DO $patch$ BEGIN
  PERFORM pg_temp.patch_rpc('warehouse_maintenance.run_database_retention(timestamptz,boolean)',
  $m$  log_cutoff timestamptz;
  result jsonb$m$, $r$  log_cutoff timestamptz;
  sensor_cutoff timestamptz;
  result jsonb$r$);
  PERFORM pg_temp.patch_rpc('warehouse_maintenance.run_database_retention(timestamptz,boolean)',
  $m$    FROM warehouse_maintenance.retention_policy WHERE key = 'security_logs';

  IF p_apply THEN
$m$, $r$    FROM warehouse_maintenance.retention_policy WHERE key = 'security_logs';
  SELECT p_now - make_interval(days => days) INTO sensor_cutoff
    FROM warehouse_maintenance.retention_policy WHERE key = 'sensor_readings';

  IF p_apply THEN
$r$);
  PERFORM pg_temp.patch_rpc('warehouse_maintenance.run_database_retention(timestamptz,boolean)',
  $m$jsonb_build_object('intrusion_events', affected);
  ELSE
$m$, $r$jsonb_build_object('intrusion_events', affected);
    DELETE FROM public.sensor_readings WHERE measured_at < sensor_cutoff;
    GET DIAGNOSTICS affected = ROW_COUNT; result := result || jsonb_build_object('sensor_readings', affected);
  ELSE
$r$);
  PERFORM pg_temp.patch_rpc('warehouse_maintenance.run_database_retention(timestamptz,boolean)',
  $m$      'intrusion_events', (SELECT count(*) FROM public.intrusion_events WHERE recorded_at < log_cutoff)
    ) INTO result;$m$, $r$      'intrusion_events', (SELECT count(*) FROM public.intrusion_events WHERE recorded_at < log_cutoff),
      'sensor_readings', (SELECT count(*) FROM public.sensor_readings WHERE measured_at < sensor_cutoff)
    ) INTO result;$r$);
END $patch$;

-- ---------------------------------------------------------------------------
-- 11. Retired: the MAC-based writers, granted to the service role only and called by nothing
-- ---------------------------------------------------------------------------
DROP FUNCTION public.record_sensor_reading(character varying, numeric, numeric, character varying, character varying);
DROP FUNCTION public.update_sensor(character varying, text, text, integer, jsonb);

DROP FUNCTION pg_temp.patch_rpc(regprocedure, text, text, integer);
NOTIFY pgrst, 'reload schema';
