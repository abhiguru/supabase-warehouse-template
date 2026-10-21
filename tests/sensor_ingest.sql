-- Migration 74: sensor ingestion, the newest state per sensor, the status view, the readers.
--
-- The bridge posts one batch per hub to functions/ingest-sensor-readings, which calls
-- public.record_sensor_batch with the service key. Fixture (all times relative to the
-- transaction's now(), which does not move inside it):
--
--   hub HUBTEST01 (online); key K1 valid, K2 revoked, K3 never minted
--   E1 'Egg Chamber 1'  50 min ago 2.50 / 81      first batch
--                       40 min ago 2.75 / -       temperature only
--                       35 min ago heartbeat      no values: last_seen_at only
--                       45 min ago 1.00 / 60      late batch: older than the temperature,
--                                                 newer than the humidity
--                        5 min ago 3.00 / -       newest, temperature only
--   E2 'Gur Store'      20 min ago -    / 70      humidity only
--                       10 min ago 5.00 / -       battery low
--                       30 min ago 9.00 / 9       late batch, older than both values
--   E3                  ten readings, each rejected for one reason
--   'Legacy Probe'      registered by MAC before migration 74, never observed
--
-- What a wrong implementation would show on this data: an upsert without the "newer only"
-- condition leaves E1 at 1.00 / 60 or E2 at 9.00 / 9 and touches the rows on a re-send; a
-- reading without a value counted as 0 gives an average humidity of 35.25 instead of 70.50
-- and a lowest humidity of 0; a heartbeat stored as a reading gives five rows for E1; a
-- device name taken from every batch undoes the rename.
-- Each answer is read as the role under test and compared after the role is reset.
-- Runs ONLY in migrations.sh's fresh, network-disabled database. All fixture rows roll back.
\set ON_ERROR_STOP on
BEGIN;
CREATE FUNCTION pg_temp.si_assert(ok boolean, label text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF NOT COALESCE(ok, false) THEN RAISE EXCEPTION 'sensor ingest: %', label; END IF; END $$;
CREATE FUNCTION pg_temp.si_login(phone text) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE challenge jsonb; login jsonb; claims jsonb;
BEGIN
  challenge := public.operator_prepare_otp(phone);
  PERFORM public.operator_finish_otp((challenge#>>'{data,request_id}')::uuid, true, 'mock-provider-only');
  login := public.operator_verify_otp(phone, challenge#>>'{data,otp_code}');
  PERFORM pg_temp.si_assert(login#>>'{data,action}' = 'login', 'login ' || phone);
  SELECT jsonb_build_object('role', 'authenticated', 'sub', p.auth_user_id, 'session_id', s.id)
    INTO claims FROM public.user_profiles p JOIN warehouse_security.refresh_sessions s ON s.user_id = p.auth_user_id
    WHERE p.mobile = warehouse_security.normalize_phone(phone) ORDER BY s.created_at DESC LIMIT 1;
  RETURN claims;
END $$;
-- One reading: external id, how long ago, the two values, and any other fields.
CREATE FUNCTION pg_temp.si_r(ext text, ago interval, t numeric, h numeric, extra jsonb DEFAULT '{}') RETURNS jsonb
LANGUAGE sql AS $$
  SELECT jsonb_build_object('external_id', ext, 'measured_at', now() - ago, 'temperature', t, 'humidity', h) || extra $$;
-- The answer of a statement, or {"raised": message, "state": sqlstate}.
CREATE FUNCTION pg_temp.si_call(statement text) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE answer jsonb;
BEGIN
  BEGIN EXECUTE statement INTO answer;
  EXCEPTION WHEN OTHERS THEN RETURN jsonb_build_object('raised', SQLERRM, 'state', SQLSTATE); END;
  RETURN answer;
END $$;
-- The element of an array whose key has that value.
CREATE FUNCTION pg_temp.si_row(arr jsonb, key_name text, key_value text) RETURNS jsonb LANGUAGE sql AS $$
  SELECT x FROM jsonb_array_elements(arr) AS t(x) WHERE x->>key_name = key_value $$;
CREATE FUNCTION pg_temp.si_keys(o jsonb) RETURNS text LANGUAGE sql AS $$
  SELECT string_agg(k, ',' ORDER BY k COLLATE "C") FROM jsonb_object_keys(o) AS t(k) $$;

SELECT pg_temp.si_assert(current_setting('TimeZone') = 'UTC', 'the session time zone is UTC');

-- ---------------------------------------------------------------------------
-- 1. Objects, grants and the guard
-- ---------------------------------------------------------------------------
SELECT pg_temp.si_assert(p.prosecdef
    AND p.proconfig = ARRAY['search_path=pg_catalog, public, extensions, pg_temp']
    AND has_function_privilege('service_role', p.oid, 'EXECUTE')
    AND NOT has_function_privilege('authenticated', p.oid, 'EXECUTE')
    AND NOT has_function_privilege('anon', p.oid, 'EXECUTE')
    AND NOT EXISTS (SELECT 1 FROM aclexplode(p.proacl) a WHERE a.grantee = 0)
    AND pg_get_functiondef(p.oid) !~* 'WHEN\s+OTHERS',
  'record_sensor_batch: SECURITY DEFINER, pinned search_path, the service role only, no catch-all handler')
FROM pg_proc p WHERE p.oid = 'public.record_sensor_batch(text,jsonb,jsonb)'::regprocedure;
SELECT pg_temp.si_assert(count(*) = 4 AND bool_and(p.prosecdef
    AND pg_get_functiondef(p.oid) ~ ('BEGIN\s+PERFORM warehouse_security\.authorize_rpc\(''' || p.proname || ''',')
    AND p.proconfig = ARRAY['search_path=pg_catalog, public, extensions, utils, pg_temp']
    AND has_function_privilege('authenticated', p.oid, 'EXECUTE') AND NOT has_function_privilege('anon', p.oid, 'EXECUTE')
    AND pg_get_functiondef(p.oid) !~* 'WHEN\s+OTHERS'),
  'the four sensor RPCs of the app: guard first, SECURITY DEFINER, pinned search_path, the app role may execute')
FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace
  AND p.proname IN ('get_sensor_polling_data', 'get_sensor_history', 'get_sensor_device', 'update_sensor_device');
SELECT pg_temp.si_assert(to_regprocedure('public.get_sensor_polling_data(timestamptz)') IS NOT NULL
    AND to_regprocedure('public.get_sensor_history(uuid,integer)') IS NOT NULL
    AND (SELECT count(*) FROM pg_proc WHERE proname IN ('get_sensor_polling_data', 'get_sensor_history')) = 2,
  'the two readers keep their signatures and have no overload');
-- No app or service role reaches the key table; only the SECURITY DEFINER body reads it.
SELECT pg_temp.si_assert(NOT has_table_privilege(r.rolname, 'warehouse_security.sensor_ingest_keys', 'SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER'),
  r.rolname || ' holds a privilege on the ingest key table')
FROM pg_roles r WHERE r.rolname IN ('anon', 'authenticated', 'service_role');
-- sensor_latest and sensor_hubs: no app-role read since migration 123 (the app reads sensors through the RPCs); the service role reads only;
-- nothing for anon; row security on, no policy.
SELECT pg_temp.si_assert(c.relrowsecurity
    AND NOT has_table_privilege('authenticated', c.oid, 'SELECT,INSERT,UPDATE,DELETE,TRUNCATE') AND has_table_privilege('service_role', c.oid, 'SELECT')
    AND NOT has_table_privilege('service_role', c.oid, 'INSERT,UPDATE,DELETE,TRUNCATE')
    AND NOT has_table_privilege('anon', c.oid, 'SELECT,INSERT,UPDATE,DELETE')
    AND NOT EXISTS (SELECT 1 FROM pg_policy WHERE polrelid = c.oid),
  c.relname || ': no app-role privilege, SELECT only for the service role, nothing for anon, row security on, no policy')
FROM pg_class c WHERE c.oid IN ('public.sensor_latest'::regclass, 'public.sensor_hubs'::regclass);
SELECT pg_temp.si_assert(NOT has_table_privilege('authenticated', 'public.sensor_status', 'SELECT')
    AND NOT has_table_privilege('anon', 'public.sensor_status', 'SELECT')
    AND (SELECT reloptions FROM pg_class WHERE oid = 'public.sensor_status'::regclass) = ARRAY['security_invoker=true'],
  'sensor_status is read by the RPCs, not by the app role, and applies the readers'' row policies');
-- Live updates are a timed re-read now (migration 105): no publication, no whole-row replica identity.
SELECT pg_temp.si_assert(NOT EXISTS (SELECT 1 FROM pg_publication_tables WHERE tablename = 'sensor_latest')
    AND (SELECT relreplident FROM pg_class WHERE oid = 'public.sensor_latest'::regclass) = 'd',
  'sensor_latest is in no publication and has REPLICA IDENTITY DEFAULT');
SELECT pg_temp.si_assert((SELECT days FROM warehouse_maintenance.retention_policy WHERE key = 'sensor_readings') = 90,
  'sensor readings are kept 90 days by default (migration 75)');
SELECT pg_temp.si_assert(to_regprocedure('public.record_sensor_reading(character varying,numeric,numeric,character varying,character varying)') IS NULL
    AND to_regprocedure('public.update_sensor(character varying,text,text,integer,jsonb)') IS NULL,
  'the MAC-based writers are gone');

-- ---------------------------------------------------------------------------
-- 2. Fixture: people, keys, a legacy device
-- ---------------------------------------------------------------------------
INSERT INTO warehouse_security.auth_config(key, value) VALUES
 ('jwt_secret', 'isolated-test-secret-not-for-any-deployment-12345'), ('auth_mode', 'operator'), ('demo_auth_enabled', 'false')
 ON CONFLICT(key) DO UPDATE SET value = excluded.value;
UPDATE public.sms_config SET provider = 'msg91', production_mode = true, msg91_auth_key = 'isolated-test-key',
 msg91_template_id = '000000000000000000000001', msg91_pe_id = '0000000000000000001', msg91_sender_id = 'CITEST';
SELECT warehouse_security.bootstrap_first_admin('9888887401', 'Sensor Ingest Administrator');
INSERT INTO public.user_profiles(auth_user_id, mobile, name, role, active, enrollment_status) VALUES
 (gen_random_uuid(), '919888887402', 'Sensor Ingest Supervisor', 'supervisor', true, 'approved'),
 (gen_random_uuid(), '919888887403', 'Sensor Ingest Staff', 'staff', true, 'approved'),
 (gen_random_uuid(), '919888887404', 'Sensor Ingest Customer', 'customer', true, 'approved');
SELECT pg_temp.si_login('9888887401') AS admin_claims \gset
SELECT pg_temp.si_login('9888887402') AS supervisor_claims \gset
SELECT pg_temp.si_login('9888887403') AS staff_claims \gset
SELECT pg_temp.si_login('9888887404') AS customer_claims \gset
SELECT pg_temp.si_assert((SELECT count(*) FROM public.sensor_devices) = 0 AND (SELECT count(*) FROM public.sensor_readings) = 0
  AND (SELECT count(*) FROM public.sensor_hubs) = 0 AND (SELECT count(*) FROM public.sensor_latest) = 0,
  'the database holds no sensor data before the fixture');

SELECT repeat('5e', 32) AS k1, repeat('7d', 32) AS k2, repeat('9c', 32) AS k3,
       repeat('A1', 20) AS e1, repeat('B2', 20) AS e2, repeat('C3', 20) AS e3 \gset
INSERT INTO warehouse_security.sensor_ingest_keys(key_hash, label, revoked_at) VALUES
  (encode(extensions.digest(:'k1', 'sha256'), 'hex'), 'sensor test bridge', NULL),
  (encode(extensions.digest(:'k2', 'sha256'), 'hex'), 'sensor test revoked', now() - interval '1 day');
INSERT INTO public.sensor_devices(device_name, mac_address, location) VALUES ('Legacy Probe', 'AA:BB:CC:00:00:74', 'Old wing')
RETURNING id AS legacy_id \gset
SELECT '{"id":"HUBTEST01","host":"192.0.2.74","online":true,"firmware":"1.2.3","bridge":{"id":"bridge-test","version":"0.1.0"}}' AS hub_on,
       '{"id":"HUBTEST01","host":"192.0.2.74","online":false,"bridge":{"id":"bridge-test","version":"0.1.0"}}' AS hub_off \gset

-- ---------------------------------------------------------------------------
-- 3. Refusals: nothing is written
-- ---------------------------------------------------------------------------
SELECT jsonb_build_array(pg_temp.si_r(:'e1', '1 minute', 1, 50)) AS one_reading \gset
SELECT (SELECT jsonb_agg(pg_temp.si_r(:'e1', make_interval(secs => g), 1, 50)) FROM generate_series(1, 501) g) AS too_many \gset
SET LOCAL ROLE service_role;
SELECT public.record_sensor_batch(NULL, :'hub_on', :'one_reading') AS key_null \gset
SELECT public.record_sensor_batch('abc', :'hub_on', :'one_reading') AS key_short \gset
SELECT public.record_sensor_batch(upper(:'k1'), :'hub_on', :'one_reading') AS key_upper \gset
SELECT public.record_sensor_batch(:'k3', :'hub_on', :'one_reading') AS key_unknown \gset
SELECT public.record_sensor_batch(:'k2', :'hub_on', :'one_reading') AS key_revoked \gset
RESET ROLE;
SELECT pg_temp.si_assert((SELECT bool_and(a = '{"success": false, "code": "invalid_key"}'::jsonb)
    FROM unnest(ARRAY[:'key_null', :'key_short', :'key_upper', :'key_unknown', :'key_revoked']::jsonb[]) a),
  'a missing, malformed, upper-case, unknown or revoked key is refused as invalid_key: ' || :'key_null' || :'key_short' || :'key_upper' || :'key_unknown' || :'key_revoked');
SELECT pg_temp.si_assert((SELECT bool_and(last_used_at IS NULL) FROM warehouse_security.sensor_ingest_keys),
  'a refused key marks no key as used');
SET LOCAL ROLE service_role;
SELECT public.record_sensor_batch(:'k1', NULL, :'one_reading') AS hub_null \gset
SELECT public.record_sensor_batch(:'k1', '[]', :'one_reading') AS hub_array \gset
SELECT public.record_sensor_batch(:'k1', '{"online":true}', :'one_reading') AS hub_no_id \gset
SELECT public.record_sensor_batch(:'k1', '{"id":"HUBTEST01","online":"yes"}', :'one_reading') AS hub_online_text \gset
SELECT public.record_sensor_batch(:'k1', '{"id":"HUBTEST01"}', :'one_reading') AS hub_no_online \gset
SELECT public.record_sensor_batch(:'k1', '{"id":"bad id!","online":true}', :'one_reading') AS hub_bad_id \gset
SELECT public.record_sensor_batch(:'k1', '{"id":"HUBTEST01","online":true,"host":"192.0.2.74; rm"}', :'one_reading') AS hub_bad_host \gset
SELECT public.record_sensor_batch(:'k1', '{"id":"HUBTEST01","online":true,"host":74}', :'one_reading') AS hub_host_number \gset
SELECT public.record_sensor_batch(:'k1', '{"id":"HUBTEST01","online":true,"bridge":"bridge-test"}', :'one_reading') AS hub_bridge_text \gset
SELECT public.record_sensor_batch(:'k1', '{"id":"HUBTEST01","online":true,"bridge":{"id":"bridge test"}}', :'one_reading') AS hub_bridge_id \gset
SELECT public.record_sensor_batch(:'k1', :'hub_on', '{"readings":[]}') AS readings_object \gset
SELECT public.record_sensor_batch(:'k1', :'hub_on', NULL) AS readings_null \gset
SELECT public.record_sensor_batch(:'k1', :'hub_on', :'too_many') AS readings_501 \gset
RESET ROLE;
SELECT pg_temp.si_assert((SELECT bool_and(a = '{"success": false, "code": "invalid_hub"}'::jsonb)
    FROM unnest(ARRAY[:'hub_null', :'hub_array', :'hub_no_id', :'hub_online_text', :'hub_no_online', :'hub_bad_id',
                      :'hub_bad_host', :'hub_host_number', :'hub_bridge_text', :'hub_bridge_id']::jsonb[]) a),
  'a hub without id or online flag, or with an ill-formed id, host or bridge, is refused as invalid_hub');
SELECT pg_temp.si_assert(:'readings_object'::jsonb = '{"success": false, "code": "invalid_readings"}'
    AND :'readings_null'::jsonb = '{"success": false, "code": "invalid_readings"}'
    AND :'readings_501'::jsonb = '{"success": false, "code": "too_many_readings"}',
  'readings that are not an array, or more than 500, are refused: ' || :'readings_object' || :'readings_501');
SELECT pg_temp.si_assert((SELECT count(*) FROM public.sensor_hubs) = 0 AND (SELECT count(*) FROM public.sensor_readings) = 0
    AND (SELECT count(*) FROM public.sensor_latest) = 0 AND (SELECT count(*) FROM public.sensor_devices) = 1,
  'a refused batch writes no hub, device, reading or latest row');
-- The valid key was used (refused bodies included), at most once a minute.
SELECT pg_temp.si_assert((SELECT last_used_at = now() FROM warehouse_security.sensor_ingest_keys WHERE label = 'sensor test bridge')
    AND (SELECT last_used_at IS NULL FROM warehouse_security.sensor_ingest_keys WHERE label = 'sensor test revoked'),
  'the valid key is marked used, the revoked one is not');
UPDATE warehouse_security.sensor_ingest_keys SET last_used_at = now() - interval '30 seconds' WHERE label = 'sensor test bridge';
SET LOCAL ROLE service_role;
SELECT public.record_sensor_batch(:'k1', NULL, '[]') IS NOT NULL AS used_again \gset
RESET ROLE;
SELECT pg_temp.si_assert((SELECT last_used_at = now() - interval '30 seconds' FROM warehouse_security.sensor_ingest_keys WHERE label = 'sensor test bridge'),
  'last_used_at is not written again within a minute');
UPDATE warehouse_security.sensor_ingest_keys SET last_used_at = now() - interval '2 minutes' WHERE label = 'sensor test bridge';
SET LOCAL ROLE service_role;
SELECT public.record_sensor_batch(:'k1', NULL, '[]') IS NOT NULL AS used_again \gset
RESET ROLE;
SELECT pg_temp.si_assert((SELECT last_used_at = now() FROM warehouse_security.sensor_ingest_keys WHERE label = 'sensor test bridge'),
  'last_used_at is written again after a minute');

-- ---------------------------------------------------------------------------
-- 4. The first batch: accepted, heartbeat, rejected by reason
-- ---------------------------------------------------------------------------
SELECT jsonb_build_array(
  pg_temp.si_r(:'e1', '50 minutes', 2.5, 81, '{"name":"Egg Chamber 1","model":"T310","battery_low":false,"battery_percent":90,"signal_level":3,"report_interval_s":16,"kind":"change"}'),
  pg_temp.si_r(:'e1', '40 minutes', 2.75, NULL, '{"name":"Egg Chamber 1","kind":"change"}'),
  pg_temp.si_r(:'e1', '35 minutes', NULL, NULL, '{"kind":"heartbeat","signal_level":2}'),
  pg_temp.si_r(:'e2', '20 minutes', NULL, 70, '{"name":"Gur Store","model":"T310","battery_low":false,"kind":"change"}'),
  pg_temp.si_r(:'e2', '10 minutes', 5, NULL, '{"battery_low":true,"battery_percent":"low","signal_level":7.5,"kind":"change"}'),
  -- E3: one reason each
  pg_temp.si_r(:'e3', '9 minutes', NULL, NULL, '{"kind":"change"}'),
  pg_temp.si_r(:'e3', '8 minutes', 81, 50),
  pg_temp.si_r(:'e3', '7 minutes', 5, -1),
  pg_temp.si_r(:'e3', '-10 minutes', 5, 50),
  pg_temp.si_r(:'e3', '31 days', 5, 50),
  jsonb_build_object('external_id', :'e3', 'measured_at', '2026-10-13T10:00:00', 'temperature', 5),
  jsonb_build_object('external_id', :'e3', 'measured_at', '2026-13-40T10:00:00Z', 'temperature', 5),
  pg_temp.si_r('XYZ', '6 minutes', 5, 50),
  '"not an object"'::jsonb,
  pg_temp.si_r(:'e3', '5 minutes', NULL, 50, '{"temperature":"2.5"}')
) AS batch1 \gset
SET LOCAL ROLE service_role;
SELECT public.record_sensor_batch(:'k1', :'hub_on', :'batch1') AS answer1 \gset
RESET ROLE;
SELECT pg_temp.si_assert(:'answer1'::jsonb = jsonb_build_object('success', true, 'data', jsonb_build_object(
    'accepted', 4, 'duplicates', 0, 'rejected', 10, 'heartbeats', 1, 'devices_seen', 2, 'devices_created', 2,
    'hub_id', 'HUBTEST01', 'hub_online', true,
    'rejected_reasons', '{"no_values":1,"out_of_range":2,"out_of_window":2,"bad_time":2,"bad_external_id":1,"malformed":1,"bad_value":1}'::jsonb)),
  'first batch: 4 accepted, 1 heartbeat, 10 rejected by reason, 2 devices created: ' || :'answer1');
SELECT id AS d1 FROM public.sensor_devices WHERE external_id = :'e1' \gset
SELECT id AS d2 FROM public.sensor_devices WHERE external_id = :'e2' \gset
SELECT pg_temp.si_assert((SELECT count(*) FROM public.sensor_devices WHERE external_id = :'e3') = 0,
  'a sensor whose every reading was rejected is not created');
SELECT pg_temp.si_assert((SELECT string_agg(to_char(now() - measured_at, 'MI') || ':' || COALESCE(temperature::text, '-') || '/' || COALESCE(humidity::text, '-'), ' ' ORDER BY measured_at)
      FROM public.sensor_readings WHERE device_id = :'d1'::uuid) = '50:2.50/81.00 40:2.75/-',
  'E1 stores two readings, the temperature-only one with no humidity, and no row for the heartbeat');
SELECT pg_temp.si_assert((SELECT string_agg(to_char(now() - measured_at, 'MI') || ':' || COALESCE(temperature::text, '-') || '/' || COALESCE(humidity::text, '-'), ' ' ORDER BY measured_at)
      FROM public.sensor_readings WHERE device_id = :'d2'::uuid) = '20:-/70.00 10:5.00/-',
  'E2 stores a humidity-only and a temperature-only reading');
SELECT pg_temp.si_assert(d.device_name = 'Egg Chamber 1' AND d.model = 'T310' AND d.hub_id = 'HUBTEST01'
    AND d.battery_low IS FALSE AND d.battery_percent = 90 AND d.signal_level = 2 AND d.report_interval_s = 16
    AND d.last_seen_at = now() - interval '35 minutes' AND d.last_reading_at = now() - interval '40 minutes'
    AND d.mac_address IS NULL,
  'E1: named by the hub, its fields from the newest observation (the heartbeat''s signal 2)')
FROM public.sensor_devices d WHERE d.id = :'d1'::uuid;
SELECT pg_temp.si_assert(d.device_name = 'Gur Store' AND d.battery_low IS TRUE AND d.battery_percent IS NULL AND d.signal_level IS NULL,
  'E2: an ill-typed battery percent and a fractional signal level are ignored, not the reading')
FROM public.sensor_devices d WHERE d.id = :'d2'::uuid;
SELECT pg_temp.si_assert(l.temperature = 2.75 AND l.temperature_at = now() - interval '40 minutes'
    AND l.humidity = 81 AND l.humidity_at = now() - interval '50 minutes'
    AND l.measured_at = now() - interval '40 minutes' AND l.last_seen_at = now() - interval '35 minutes'
    AND l.device_name = 'Egg Chamber 1' AND l.hub_id = 'HUBTEST01' AND l.battery_low IS FALSE AND l.signal_level = 2
    AND l.report_interval_s = 16,
  'E1 latest: 2.75 from 40 min, humidity 81 keeps its own age (50 min), seen 35 min ago')
FROM public.sensor_latest l WHERE l.device_id = :'d1'::uuid;
SELECT pg_temp.si_assert(l.temperature = 5 AND l.temperature_at = now() - interval '10 minutes'
    AND l.humidity = 70 AND l.humidity_at = now() - interval '20 minutes' AND l.measured_at = now() - interval '10 minutes'
    AND l.battery_low IS TRUE,
  'E2 latest: temperature 5 from 10 min, humidity 70 from 20 min, battery low')
FROM public.sensor_latest l WHERE l.device_id = :'d2'::uuid;
SELECT pg_temp.si_assert(h.online AND h.host = '192.0.2.74' AND h.firmware = '1.2.3' AND h.bridge_id = 'bridge-test'
    AND h.bridge_version = '0.1.0' AND h.last_seen_at = now() AND h.last_change_at = now(),
  'the hub is recorded online with its host, firmware and bridge')
FROM public.sensor_hubs h WHERE h.hub_id = 'HUBTEST01';

-- ---------------------------------------------------------------------------
-- 5. A re-sent batch changes nothing
-- ---------------------------------------------------------------------------
SELECT string_agg(device_id || '=' || ctid::text, ';' ORDER BY device_id) AS latest_rows FROM public.sensor_latest \gset
SET LOCAL ROLE service_role;
SELECT public.record_sensor_batch(:'k1', :'hub_on', :'batch1') AS answer1_again \gset
RESET ROLE;
SELECT pg_temp.si_assert((:'answer1_again'::jsonb->'data') - 'rejected_reasons' = '{"accepted":0,"duplicates":4,"rejected":10,"heartbeats":1,"devices_seen":2,"devices_created":0,"hub_id":"HUBTEST01","hub_online":true}'::jsonb,
  'the same batch again: 0 accepted, 4 duplicates, no device created: ' || :'answer1_again');
SELECT pg_temp.si_assert((SELECT count(*) FROM public.sensor_readings) = 4 AND (SELECT count(*) FROM public.sensor_devices) = 3,
  'a re-sent batch stores no reading and no device');
SELECT pg_temp.si_assert((SELECT string_agg(device_id || '=' || ctid::text, ';' ORDER BY device_id) FROM public.sensor_latest) = :'latest_rows',
  'a re-sent batch does not touch sensor_latest (no row is rewritten)');

-- ---------------------------------------------------------------------------
-- 6. Late batches: each value stays at its newest
-- ---------------------------------------------------------------------------
SELECT ctid::text AS e2_row FROM public.sensor_latest WHERE device_id = :'d2'::uuid \gset
SELECT jsonb_build_array(
  pg_temp.si_r(:'e1', '45 minutes', 1, 60, '{"battery_low":true,"signal_level":1}'),
  pg_temp.si_r(:'e2', '30 minutes', 9, 9, '{"battery_low":false,"signal_level":9}')) AS late \gset
SET LOCAL ROLE service_role;
SELECT public.record_sensor_batch(:'k1', :'hub_on', :'late') AS answer_late \gset
RESET ROLE;
SELECT pg_temp.si_assert((:'answer_late'::jsonb#>>'{data,accepted}')::int = 2 AND (:'answer_late'::jsonb#>>'{data,rejected}')::int = 0,
  'the late readings are stored: ' || :'answer_late');
SELECT pg_temp.si_assert(l.temperature = 2.75 AND l.temperature_at = now() - interval '40 minutes'
    AND l.humidity = 60 AND l.humidity_at = now() - interval '45 minutes'
    AND l.measured_at = now() - interval '40 minutes' AND l.last_seen_at = now() - interval '35 minutes'
    AND l.battery_low IS FALSE AND l.signal_level = 2,
  'E1 after a reading from 45 min: the temperature of 40 min stays, the humidity of 50 min is replaced, the older battery and signal are not taken: '
    || to_jsonb(l)::text)
FROM public.sensor_latest l WHERE l.device_id = :'d1'::uuid;
SELECT pg_temp.si_assert(l.temperature = 5 AND l.humidity = 70 AND l.measured_at = now() - interval '10 minutes'
    AND l.battery_low IS TRUE AND l.ctid::text = :'e2_row',
  'E2 after a reading older than both values: the row is not touched: ' || to_jsonb(l)::text)
FROM public.sensor_latest l WHERE l.device_id = :'d2'::uuid;
SELECT pg_temp.si_assert(d.battery_low IS TRUE AND d.signal_level IS NULL AND d.last_seen_at = now() - interval '10 minutes',
  'E2''s device fields are not taken from an older observation')
FROM public.sensor_devices d WHERE d.id = :'d2'::uuid;
-- The newest reading of E1 carries temperature only; the humidity keeps its age. The id comes in lower case.
SELECT jsonb_build_array(pg_temp.si_r(lower(:'e1'), '5 minutes', 3, NULL, '{"name":"Some Other Name"}')) AS newest \gset
SET LOCAL ROLE service_role;
SELECT public.record_sensor_batch(:'k1', :'hub_on', :'newest') AS answer_newest \gset
RESET ROLE;
SELECT pg_temp.si_assert((:'answer_newest'::jsonb#>>'{data,devices_created}')::int = 0 AND (:'answer_newest'::jsonb#>>'{data,accepted}')::int = 1,
  'a lower-case external id names the same sensor: ' || :'answer_newest');
SELECT pg_temp.si_assert(l.temperature = 3 AND l.temperature_at = now() - interval '5 minutes'
    AND l.humidity = 60 AND l.humidity_at = now() - interval '45 minutes'
    AND l.measured_at = now() - interval '5 minutes' AND l.last_seen_at = now() - interval '5 minutes',
  'E1 newest: temperature 3 from 5 min, humidity 60 still dated 45 min')
FROM public.sensor_latest l WHERE l.device_id = :'d1'::uuid;
SELECT pg_temp.si_assert((SELECT device_name FROM public.sensor_devices WHERE id = :'d1'::uuid) = 'Egg Chamber 1',
  'a name sent later does not replace the first one');

-- ---------------------------------------------------------------------------
-- 7. Readers: the snapshot, the history, one device
-- ---------------------------------------------------------------------------
SELECT set_config('request.jwt.claims', :'staff_claims', true);
SET LOCAL ROLE authenticated;
SELECT public.get_sensor_polling_data(now() - interval '15 minutes') AS staff_poll \gset
SELECT public.get_sensor_history(:'d1'::uuid, 1) AS staff_day \gset
SELECT public.get_sensor_history(:'d1'::uuid, 7) AS staff_week \gset
SELECT public.get_sensor_history(:'d1'::uuid, 2) AS staff_bad_period \gset
SELECT public.get_sensor_history(gen_random_uuid(), 7) AS staff_no_device \gset
SELECT public.get_sensor_device(:'d1'::uuid) AS staff_device \gset
SELECT public.get_sensor_device(gen_random_uuid()) AS staff_device_missing \gset
SELECT pg_temp.si_call('SELECT count(*)::text::jsonb FROM public.sensor_latest') AS staff_latest_read \gset
SELECT pg_temp.si_call('SELECT count(*)::text::jsonb FROM public.sensor_hubs') AS staff_hub_read \gset
SELECT pg_temp.si_call('INSERT INTO public.sensor_latest(device_id, device_name) VALUES (gen_random_uuid(), ''x'')') AS staff_write \gset
SELECT pg_temp.si_call(format('SELECT public.record_sensor_batch(%L, %L::jsonb, ''[]''::jsonb)', :'k1', :'hub_on')) AS staff_ingest \gset
SELECT pg_temp.si_call('SELECT count(*)::text::jsonb FROM warehouse_security.sensor_ingest_keys') AS staff_keys \gset
SELECT pg_temp.si_call(format('SELECT public.update_sensor_device(%L::uuid, ''Staff Name'')', :'d1')) AS staff_update \gset
RESET ROLE;
SELECT pg_temp.si_assert(:'staff_poll'::jsonb->>'success' = 'true'
    AND pg_temp.si_keys(:'staff_poll'::jsonb) = 'dashboard,devices,new_readings,poll_timestamp,success'
    AND jsonb_array_length(:'staff_poll'::jsonb->'devices') = 3,
  'staff: the snapshot keeps its envelope and lists the three active devices: ' || left(:'staff_poll', 300));
SELECT pg_temp.si_assert((SELECT bool_and(x ? k)
    FROM jsonb_array_elements(:'staff_poll'::jsonb->'devices') x,
         unnest(ARRAY['active','battery_status','connectivity_status','consecutive_failures','device_name','earliest_reading_at',
           'health_status','id','is_stale','last_reading_at','latest_humidity','latest_reading_timestamp','latest_temperature',
           'location','mac_address','staleness_threshold_minutes','measured_at','temperature_at','humidity_at','hub_online',
           'battery_low','signal_level','last_seen_at','alert_config']) k),
  'every device carries the keys the app reads, the old ones and the new ones');
SELECT pg_temp.si_row(:'staff_poll'::jsonb->'devices', 'id', :'d1') AS poll_e1 \gset
SELECT pg_temp.si_row(:'staff_poll'::jsonb->'devices', 'id', :'d2') AS poll_e2 \gset
SELECT pg_temp.si_row(:'staff_poll'::jsonb->'devices', 'id', :'legacy_id') AS poll_legacy \gset
SELECT pg_temp.si_assert((:'poll_e1'::jsonb->>'latest_temperature')::numeric = 3 AND (:'poll_e1'::jsonb->>'latest_humidity')::numeric = 60
    AND (:'poll_e1'::jsonb->>'humidity_at')::timestamptz = now() - interval '45 minutes'
    AND (:'poll_e1'::jsonb->>'latest_reading_timestamp')::timestamptz = now() - interval '5 minutes'
    AND (:'poll_e1'::jsonb->>'last_reading_at')::timestamptz = now() - interval '5 minutes'
    AND (:'poll_e1'::jsonb->>'earliest_reading_at')::timestamptz = now() - interval '50 minutes'
    AND :'poll_e1'::jsonb->>'connectivity_status' = 'ONLINE' AND :'poll_e1'::jsonb->>'is_stale' = 'false'
    AND :'poll_e1'::jsonb->>'battery_status' = 'OK' AND :'poll_e1'::jsonb->>'health_status' = 'healthy'
    AND :'poll_e1'::jsonb->>'hub_online' = 'true' AND :'poll_e1'::jsonb->>'external_id' = :'e1',
  'E1 in the snapshot: 3 / 60 (no zero placeholder), ONLINE, battery OK, healthy: ' || :'poll_e1');
SELECT pg_temp.si_assert((:'poll_e2'::jsonb->>'latest_temperature')::numeric = 5 AND (:'poll_e2'::jsonb->>'latest_humidity')::numeric = 70
    AND :'poll_e2'::jsonb->>'battery_status' = 'LOW' AND :'poll_e2'::jsonb->>'health_status' = 'warning'
    AND :'poll_e2'::jsonb->>'connectivity_status' = 'ONLINE',
  'E2 in the snapshot: 5 / 70, battery LOW, so a warning: ' || :'poll_e2');
SELECT pg_temp.si_assert(:'poll_legacy'::jsonb->>'connectivity_status' = 'UNKNOWN' AND :'poll_legacy'::jsonb->>'battery_status' = 'UNKNOWN'
    AND :'poll_legacy'::jsonb->>'health_status' = 'unknown' AND :'poll_legacy'::jsonb->>'is_stale' = 'true'
    AND :'poll_legacy'::jsonb->'latest_temperature' = 'null' AND :'poll_legacy'::jsonb->>'mac_address' = 'AA:BB:CC:00:00:74',
  'a device never observed is listed as UNKNOWN with no values: ' || :'poll_legacy');
SELECT pg_temp.si_assert(:'staff_poll'::jsonb->'dashboard' = '{"total_active_sensors":3,"online_sensors":2,"offline_sensors":0,"stale_sensors":0,"low_battery_count":1,"critical_battery_count":0,"sensors_with_failures":0}'::jsonb
      || jsonb_build_object('most_recent_sync', now() - interval '5 minutes'),
  'the dashboard counts from the computed status: ' || (:'staff_poll'::jsonb->'dashboard')::text);
SELECT pg_temp.si_assert(jsonb_array_length(:'staff_poll'::jsonb->'new_readings') = 2
    AND :'staff_poll'::jsonb#>>'{new_readings,0,device_id}' = :'d1' AND :'staff_poll'::jsonb#>>'{new_readings,1,device_id}' = :'d2'
    AND (:'staff_poll'::jsonb#>>'{new_readings,0,recorded_at}')::timestamptz = now() - interval '5 minutes'
    AND :'staff_poll'::jsonb#>'{new_readings,0,humidity}' = 'null',
  'new readings are those measured in the last 15 minutes, newest first, NULL kept as null: ' || (:'staff_poll'::jsonb->'new_readings')::text);
-- History: averages ignore a missing value; the per-bucket counts say how many values each holds.
SELECT pg_temp.si_assert(:'staff_day'::jsonb#>>'{data,aggregation_interval}' = '5 minutes'
    AND (:'staff_day'::jsonb#>>'{data,period_days}')::int = 1
    AND jsonb_array_length(:'staff_day'::jsonb#>'{data,readings}') = 4
    AND (:'staff_day'::jsonb#>>'{data,summary,avg_temperature}')::numeric = 2.31
    AND (:'staff_day'::jsonb#>>'{data,summary,avg_humidity}')::numeric = 70.50
    AND (:'staff_day'::jsonb#>>'{data,summary,min_humidity}')::numeric = 60
    AND (:'staff_day'::jsonb#>>'{data,summary,total_readings}')::int = 4
    AND (:'staff_day'::jsonb#>>'{metadata,raw_reading_count}')::int = 4
    AND (SELECT string_agg(x->>'sample_count' || ':' || (x->>'temperature_count') || ':' || (x->>'humidity_count') || ':' || COALESCE(x->>'humidity', '-'), ' ' ORDER BY x->>'timestamp')
         FROM jsonb_array_elements(:'staff_day'::jsonb#>'{data,readings}') x) = '1:1:1:81.00 1:1:1:60.00 1:1:0:- 1:1:0:-',
  'one day in 5-minute buckets: average temperature 2.31 and humidity 70.50 over the values present: ' || :'staff_day');
SELECT pg_temp.si_assert(:'staff_week'::jsonb#>>'{data,aggregation_interval}' = '1 hour'
    AND (SELECT sum((x->>'sample_count')::int) = 4 AND sum((x->>'humidity_count')::int) = 2
         FROM jsonb_array_elements(:'staff_week'::jsonb#>'{data,readings}') x)
    AND (:'staff_week'::jsonb#>>'{data,summary,avg_humidity}')::numeric = 70.50,
  'seven days in hourly buckets with the same counts: ' || :'staff_week');
SELECT pg_temp.si_assert(:'staff_bad_period'::jsonb->>'error_code' = 'INVALID_PERIOD' AND :'staff_no_device'::jsonb->>'error_code' = 'DEVICE_NOT_FOUND',
  'an unknown period or device is answered as before: ' || :'staff_bad_period' || :'staff_no_device');
-- One device.
SELECT pg_temp.si_assert(:'staff_device'::jsonb->>'success' = 'true'
    AND :'staff_device'::jsonb#>>'{data,id}' = :'d1' AND :'staff_device'::jsonb#>>'{data,device_id}' = :'d1'
    AND :'staff_device'::jsonb#>>'{data,device_name}' = 'Egg Chamber 1'
    AND (:'staff_device'::jsonb#>>'{data,first_reading_at}')::timestamptz = now() - interval '50 minutes'
    AND (:'staff_device'::jsonb#>>'{data,temperature}')::numeric = 3
    AND :'staff_device'::jsonb#>>'{data,connectivity_status}' = 'ONLINE'
    AND :'staff_device'::jsonb#>'{data,hub}' = jsonb_build_object('id', 'HUBTEST01', 'host', '192.0.2.74', 'firmware', '1.2.3', 'online', true, 'last_seen_at', now()),
  'staff open one sensor with its first reading and its hub: ' || :'staff_device');
SELECT pg_temp.si_assert((SELECT bool_and(:'staff_device'::jsonb->'data' ? k)
      FROM unnest(ARRAY['latest_temperature','latest_humidity','latest_reading_timestamp','is_stale','earliest_reading_at']) k)
    AND :'staff_device'::jsonb#>'{data,latest_temperature}' = :'staff_device'::jsonb#>'{data,temperature}'
    AND (:'staff_device'::jsonb#>>'{data,latest_temperature}')::numeric = 3
    AND :'staff_device'::jsonb#>'{data,is_stale}' = :'staff_device'::jsonb#>'{data,stale}'
    AND jsonb_typeof(:'staff_device'::jsonb#>'{data,is_stale}') = 'boolean'
    AND :'staff_device'::jsonb#>'{data,latest_humidity}' = :'staff_device'::jsonb#>'{data,humidity}'
    AND :'staff_device'::jsonb#>'{data,latest_reading_timestamp}' = :'staff_device'::jsonb#>'{data,measured_at}'
    AND :'staff_device'::jsonb#>'{data,earliest_reading_at}' = :'staff_device'::jsonb#>'{data,first_reading_at}',
  'one sensor carries the polling entry keys with the same values: ' || :'staff_device');
SELECT pg_temp.si_assert(:'staff_device_missing'::jsonb = '{"success":false,"error":"Device not found","error_code":"DEVICE_NOT_FOUND"}'::jsonb,
  'an unknown device: ' || :'staff_device_missing');
-- Staff read neither table directly (migration 123: the RPCs above are the way in), and write nothing.
SELECT pg_temp.si_assert(:'staff_latest_read'::jsonb->>'state' = '42501' AND :'staff_hub_read'::jsonb->>'state' = '42501'
    AND :'staff_write'::jsonb->>'state' = '42501' AND :'staff_ingest'::jsonb->>'state' = '42501'
    AND :'staff_keys'::jsonb->>'state' = '42501' AND :'staff_update'::jsonb->>'state' = '42501',
  'staff cannot read or write sensor_latest and sensor_hubs, ingest, read the keys or change a sensor: '
    || :'staff_write' || :'staff_ingest' || :'staff_keys' || :'staff_update');

-- A customer account and the anonymous role read nothing.
SELECT set_config('request.jwt.claims', :'customer_claims', true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.si_call('SELECT count(*)::text::jsonb FROM public.sensor_latest') AS customer_latest_read \gset
SELECT pg_temp.si_call('SELECT count(*)::text::jsonb FROM public.sensor_hubs') AS customer_hub_read \gset
SELECT pg_temp.si_call(format('SELECT public.get_sensor_device(%L::uuid)', :'d1')) AS customer_device \gset
SELECT pg_temp.si_call('SELECT public.get_sensor_polling_data()') AS customer_poll \gset
RESET ROLE;
SELECT set_config('request.jwt.claims', '{"role":"anon"}', true);
SET LOCAL ROLE anon;
SELECT pg_temp.si_call('SELECT count(*)::text::jsonb FROM public.sensor_latest') AS anon_latest \gset
SELECT pg_temp.si_call(format('SELECT public.get_sensor_device(%L::uuid)', :'d1')) AS anon_device \gset
RESET ROLE;
SELECT pg_temp.si_assert(:'customer_latest_read'::jsonb->>'state' = '42501' AND :'customer_hub_read'::jsonb->>'state' = '42501'
    AND :'customer_device'::jsonb->>'state' = '42501' AND :'customer_poll'::jsonb->>'state' = '42501'
    AND :'anon_latest'::jsonb->>'state' = '42501' AND :'anon_device'::jsonb->>'state' = '42501',
  'a customer account sees no sensor row and is refused the RPCs; anon is refused: '
    || :'customer_device' || :'customer_poll' || :'anon_latest' || :'anon_device');

-- ---------------------------------------------------------------------------
-- 8. Settings: administrators only; a rename survives ingestion
-- ---------------------------------------------------------------------------
SELECT set_config('request.jwt.claims', :'supervisor_claims', true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.si_call(format('SELECT public.update_sensor_device(%L::uuid, ''Supervisor Name'')', :'d1')) AS supervisor_update \gset
SELECT public.get_sensor_device(:'d1'::uuid)->>'success' AS supervisor_reads \gset
RESET ROLE;
SELECT pg_temp.si_assert(:'supervisor_update'::jsonb->>'state' = '42501' AND :'supervisor_update'::jsonb->>'raised' = 'Administrator required'
    AND :'supervisor_reads' = 'true',
  'a supervisor reads a sensor but may not change it: ' || :'supervisor_update');
SELECT ctid::text AS e1_row FROM public.sensor_latest WHERE device_id = :'d1'::uuid \gset
SELECT set_config('request.jwt.claims', :'admin_claims', true);
SET LOCAL ROLE authenticated;
SELECT public.update_sensor_device(:'d1'::uuid, '  Egg Chamber North  ', 'Block A') AS admin_rename \gset
SELECT public.update_sensor_device(:'d2'::uuid, NULL, NULL, 5) AS admin_threshold \gset
SELECT public.update_sensor_device(:'d1'::uuid, '') AS admin_empty_name \gset
SELECT public.update_sensor_device(:'d1'::uuid, NULL, NULL, 2) AS admin_bad_threshold \gset
SELECT public.update_sensor_device(:'d1'::uuid, NULL, repeat('x', 201)) AS admin_long_location \gset
SELECT public.update_sensor_device(gen_random_uuid(), 'Nobody') AS admin_missing \gset
RESET ROLE;
SELECT pg_temp.si_assert(:'admin_rename'::jsonb = jsonb_build_object('success', true, 'data', jsonb_build_object(
      'device_id', :'d1', 'device_name', 'Egg Chamber North', 'location', 'Block A', 'staleness_threshold_minutes', 30))
    AND :'admin_threshold'::jsonb#>>'{data,staleness_threshold_minutes}' = '5'
    AND :'admin_empty_name'::jsonb->>'error_code' = 'INVALID_NAME'
    AND :'admin_bad_threshold'::jsonb->>'error_code' = 'INVALID_THRESHOLD'
    AND :'admin_long_location'::jsonb->>'error_code' = 'INVALID_LOCATION'
    AND :'admin_missing'::jsonb->>'error_code' = 'DEVICE_NOT_FOUND',
  'administrator renames and sets a threshold; bad values and an unknown device are refused: '
    || :'admin_rename' || :'admin_empty_name' || :'admin_bad_threshold' || :'admin_missing');
SELECT pg_temp.si_assert(l.device_name = 'Egg Chamber North' AND l.location = 'Block A' AND l.ctid::text <> :'e1_row',
  'the rename is copied to sensor_latest, which publishes it')
FROM public.sensor_latest l WHERE l.device_id = :'d1'::uuid;
SELECT jsonb_build_array(pg_temp.si_r(:'e1', '2 minutes', 3.25, 61, '{"name":"Egg Chamber 1"}')) AS after_rename \gset
SET LOCAL ROLE service_role;
SELECT public.record_sensor_batch(:'k1', :'hub_on', :'after_rename') AS answer_after_rename \gset
RESET ROLE;
SELECT pg_temp.si_assert((SELECT device_name FROM public.sensor_devices WHERE id = :'d1'::uuid) = 'Egg Chamber North'
    AND (SELECT device_name || '|' || location FROM public.sensor_latest WHERE device_id = :'d1'::uuid) = 'Egg Chamber North|Block A'
    AND (SELECT temperature FROM public.sensor_latest WHERE device_id = :'d1'::uuid) = 3.25,
  'a batch carrying the hub''s old name keeps the rename: ' || :'answer_after_rename');

-- ---------------------------------------------------------------------------
-- 9. Stale, and the hub going offline and back
-- ---------------------------------------------------------------------------
-- E2 was last seen 10 minutes ago and its threshold is now 5 minutes: stale. E1 (2 minutes, 30) is not.
SELECT set_config('request.jwt.claims', :'staff_claims', true);
SET LOCAL ROLE authenticated;
SELECT public.get_sensor_polling_data() AS poll_stale \gset
RESET ROLE;
SELECT pg_temp.si_assert(pg_temp.si_row(:'poll_stale'::jsonb->'devices', 'id', :'d2')->>'connectivity_status' = 'STALE'
    AND pg_temp.si_row(:'poll_stale'::jsonb->'devices', 'id', :'d2')->>'is_stale' = 'true'
    AND pg_temp.si_row(:'poll_stale'::jsonb->'devices', 'id', :'d2')->>'values_stale' = 'true'
    AND pg_temp.si_row(:'poll_stale'::jsonb->'devices', 'id', :'d2')->>'health_status' = 'offline'
    AND pg_temp.si_row(:'poll_stale'::jsonb->'devices', 'id', :'d1')->>'connectivity_status' = 'ONLINE'
    AND pg_temp.si_row(:'poll_stale'::jsonb->'devices', 'id', :'d1')->>'device_name' = 'Egg Chamber North'
    AND (:'poll_stale'::jsonb#>>'{dashboard,stale_sensors}')::int = 1
    AND :'poll_stale'::jsonb->'new_readings' = '[]',
  'E2, silent for longer than its threshold, is STALE; E1 is ONLINE under its new name: ' || (:'poll_stale'::jsonb->'dashboard')::text);
-- An offline report of the hub: no readings, every sensor of the hub is OFFLINE and its row is touched.
SELECT string_agg(device_id || '=' || ctid::text, ';' ORDER BY device_id) AS rows_before_offline FROM public.sensor_latest \gset
SET LOCAL ROLE service_role;
SELECT public.record_sensor_batch(:'k1', :'hub_off', '[]') AS answer_offline \gset
RESET ROLE;
SELECT pg_temp.si_assert(:'answer_offline'::jsonb = '{"success":true,"data":{"accepted":0,"duplicates":0,"rejected":0,"rejected_reasons":{},"heartbeats":0,"devices_seen":0,"devices_created":0,"hub_id":"HUBTEST01","hub_online":false}}'::jsonb,
  'an offline heartbeat of the hub is accepted: ' || :'answer_offline');
SELECT pg_temp.si_assert(NOT online AND firmware = '1.2.3' AND last_change_at = now(),
  'the hub is offline and keeps the firmware it last reported') FROM public.sensor_hubs WHERE hub_id = 'HUBTEST01';
SELECT pg_temp.si_assert((SELECT bool_and(l.ctid::text <> split_part(r, '=', 2))
    FROM public.sensor_latest l JOIN unnest(string_to_array(:'rows_before_offline', ';')) r ON split_part(r, '=', 1) = l.device_id::text),
  'each sensor of the hub has its row rewritten when the hub goes offline');
SELECT set_config('request.jwt.claims', :'staff_claims', true);
SET LOCAL ROLE authenticated;
SELECT public.get_sensor_polling_data() AS poll_offline \gset
RESET ROLE;
SELECT pg_temp.si_assert(pg_temp.si_row(:'poll_offline'::jsonb->'devices', 'id', :'d1')->>'connectivity_status' = 'OFFLINE'
    AND pg_temp.si_row(:'poll_offline'::jsonb->'devices', 'id', :'d1')->>'hub_online' = 'false'
    AND pg_temp.si_row(:'poll_offline'::jsonb->'devices', 'id', :'d1')->>'health_status' = 'offline'
    AND pg_temp.si_row(:'poll_offline'::jsonb->'devices', 'id', :'d2')->>'connectivity_status' = 'OFFLINE'
    AND pg_temp.si_row(:'poll_offline'::jsonb->'devices', 'id', :'legacy_id')->>'connectivity_status' = 'UNKNOWN'
    AND (:'poll_offline'::jsonb#>>'{dashboard,offline_sensors}')::int = 2
    AND (:'poll_offline'::jsonb#>>'{dashboard,online_sensors}')::int = 0,
  'with the hub offline both of its sensors are OFFLINE, the legacy one stays UNKNOWN: ' || (:'poll_offline'::jsonb->'dashboard')::text);
SELECT string_agg(device_id || '=' || ctid::text, ';' ORDER BY device_id) AS rows_offline FROM public.sensor_latest \gset
SET LOCAL ROLE service_role;
SELECT public.record_sensor_batch(:'k1', :'hub_off', '[]') AS answer_offline_again \gset
SELECT public.record_sensor_batch(:'k1', :'hub_on', '[]') AS answer_online \gset
RESET ROLE;
SELECT pg_temp.si_assert((SELECT string_agg(device_id || '=' || ctid::text, ';' ORDER BY device_id) FROM public.sensor_latest) <> :'rows_offline'
    AND :'answer_online'::jsonb#>>'{data,hub_online}' = 'true'
    AND (SELECT online FROM public.sensor_hubs WHERE hub_id = 'HUBTEST01'),
  'the hub is back online');
SELECT set_config('request.jwt.claims', :'staff_claims', true);
SET LOCAL ROLE authenticated;
SELECT public.get_sensor_polling_data() AS poll_back \gset
RESET ROLE;
SELECT pg_temp.si_assert(pg_temp.si_row(:'poll_back'::jsonb->'devices', 'id', :'d1')->>'connectivity_status' = 'ONLINE',
  'E1 is ONLINE again with its hub');

-- ---------------------------------------------------------------------------
-- 10. Retention: 90 days (migration 75)
-- ---------------------------------------------------------------------------
INSERT INTO public.sensor_readings(device_id, temperature, humidity, measured_at) VALUES
  (:'d1'::uuid, 4, 70, now() - interval '91 days'), (:'d1'::uuid, 4, 70, now() - interval '89 days');
SELECT warehouse_maintenance.run_database_retention(now(), false) AS retention_preview \gset
SELECT pg_temp.si_assert((:'retention_preview'::jsonb#>>'{rows,sensor_readings}')::int = 1
    AND (SELECT count(*) FROM public.sensor_readings WHERE device_id = :'d1'::uuid) = 7,
  'the preview counts the reading of 91 days only and deletes nothing: ' || (:'retention_preview'::jsonb->'rows')::text);
SELECT warehouse_maintenance.run_database_retention(now(), true) AS retention_applied \gset
SELECT pg_temp.si_assert((:'retention_applied'::jsonb#>>'{rows,sensor_readings}')::int = 1
    AND NOT EXISTS (SELECT 1 FROM public.sensor_readings WHERE measured_at = now() - interval '91 days')
    AND EXISTS (SELECT 1 FROM public.sensor_readings WHERE measured_at = now() - interval '89 days')
    AND (SELECT count(*) FROM public.sensor_readings) = 9,
  'retention deletes the reading of 91 days and keeps the one of 89 days and the recent ones');

-- ---------------------------------------------------------------------------
-- 11. A batch exactly as docker/sensor-bridge builds it
-- ---------------------------------------------------------------------------
-- poster.py posts {bridge, hub, readings}; the function folds bridge into p_hub. The hub id is
-- the hub's device_id (40 hex) once reached, its host before that; firmware may be null. A
-- child id arrives as the hub reports it, here in lower case; a heartbeat repeats the
-- unchanged values with kind 'heartbeat'. Times are whole seconds with Z (scheduler.iso).
SELECT repeat('d4', 20) AS e4, repeat('E5', 20) AS hub5,
  to_char(date_trunc('second', now()) - interval '3 minutes', 'YYYY-MM-DD"T"HH24:MI:SS"Z"') AS t_change,
  to_char(date_trunc('second', now()) - interval '1 minute', 'YYYY-MM-DD"T"HH24:MI:SS"Z"') AS t_beat \gset
SELECT jsonb_build_object('id', :'hub5', 'host', '192.0.2.79', 'online', true, 'firmware', NULL,
         'bridge', jsonb_build_object('id', 'sensor-bridge', 'version', '1.0.0')) AS bridge_hub,
       '{"id":"192.0.2.80","host":"192.0.2.80","online":false,"firmware":null,"bridge":{"id":"sensor-bridge","version":"1.0.0"}}' AS bridge_hub_unreached \gset
SELECT jsonb_build_array(
  jsonb_build_object('external_id', :'e4', 'name', 'Bridge Probe', 'model', 'T310', 'temperature', 4.1, 'humidity', 82.0,
    'measured_at', :'t_change', 'battery_low', false, 'battery_percent', 100, 'signal_level', 3, 'report_interval_s', 16, 'kind', 'change'),
  jsonb_build_object('external_id', :'e4', 'name', 'Bridge Probe', 'model', 'T310', 'temperature', 4.1, 'humidity', 82.0,
    'measured_at', :'t_beat', 'battery_low', false, 'battery_percent', 100, 'signal_level', 3, 'report_interval_s', 16, 'kind', 'heartbeat')
) AS bridge_batch \gset
SET LOCAL ROLE service_role;
SELECT public.record_sensor_batch(:'k1', :'bridge_hub', :'bridge_batch') AS answer_bridge \gset
SELECT public.record_sensor_batch(:'k1', :'bridge_hub_unreached', '[]') AS answer_unreached \gset
RESET ROLE;
SELECT pg_temp.si_assert(:'answer_bridge'::jsonb = jsonb_build_object('success', true, 'data', jsonb_build_object(
    'accepted', 2, 'duplicates', 0, 'rejected', 0, 'rejected_reasons', '{}'::jsonb, 'heartbeats', 1,
    'devices_seen', 1, 'devices_created', 1, 'hub_id', :'hub5', 'hub_online', true)),
  'the bridge''s batch: a change and a heartbeat with values, both stored, the heartbeat counted by its kind: ' || :'answer_bridge');
SELECT pg_temp.si_assert(d.external_id = upper(:'e4') AND d.device_name = 'Bridge Probe' AND d.model = 'T310'
    AND d.hub_id = :'hub5' AND d.battery_percent = 100
    AND (SELECT count(*) FROM public.sensor_readings r WHERE r.device_id = d.id) = 2
    AND (SELECT l.temperature_at = :'t_beat'::timestamptz AND l.humidity = 82 FROM public.sensor_latest l WHERE l.device_id = d.id),
  'a lower-case child id is stored upper case; the heartbeat dates the unchanged values')
FROM public.sensor_devices d WHERE d.device_name = 'Bridge Probe';
SELECT pg_temp.si_assert((SELECT count(*) FROM public.sensor_devices WHERE device_name = 'Bridge Probe') = 1, 'the bridge''s sensor exists once');
SELECT pg_temp.si_assert(:'answer_unreached'::jsonb#>>'{data,hub_id}' = '192.0.2.80'
    AND (SELECT NOT online AND firmware IS NULL AND bridge_id = 'sensor-bridge' FROM public.sensor_hubs WHERE hub_id = '192.0.2.80'),
  'a hub never reached is reported under its host: ' || :'answer_unreached');

ROLLBACK;
SELECT 'sensor ingest: keys, hub and readings checked; idempotent re-send; each value newest-only with its own age; heartbeats, stale and hub-offline status; readers ignore missing values; staff read, administrators change, customers and anon refused; rename survives; 90-day retention' AS result;
