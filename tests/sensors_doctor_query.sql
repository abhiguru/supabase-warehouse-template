-- The doctor's sensor query (scripts/sensors-check.mjs, SENSORS_SQL; tests/sensors-check.test.mjs asserts the line below is the same text):
-- with no reading stored 'newest_age_s' is null (not 0), a future-dated reading gives a negative age (the doctor clamps it), and a hub row
-- gives both ages. Runs ONLY in migrations.sh's fresh, network-disabled database. All fixture rows roll back.
\set ON_ERROR_STOP on
BEGIN;
CREATE FUNCTION pg_temp.sd_assert(ok boolean, label text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF NOT COALESCE(ok, false) THEN RAISE EXCEPTION 'sensors doctor query: %', label; END IF; END $$;
DELETE FROM public.sensor_readings;
DELETE FROM public.sensor_hubs;
SELECT json_build_object('hubs', coalesce((SELECT json_agg(json_build_object('hub_id', hub_id, 'host', host, 'online', online, 'age_s', greatest(0, extract(epoch FROM now() - last_seen_at))::bigint, 'change_age_s', greatest(0, extract(epoch FROM now() - last_change_at))::bigint) ORDER BY host, hub_id) FROM public.sensor_hubs), '[]'::json), 'newest_age_s', (SELECT extract(epoch FROM now() - max(measured_at))::bigint FROM public.sensor_readings)) AS empty_answer \gset
SELECT pg_temp.sd_assert(:'empty_answer'::jsonb = '{"hubs": [], "newest_age_s": null}'::jsonb, 'empty tables: no hubs and a null reading age: ' || :'empty_answer');
INSERT INTO public.sensor_hubs (hub_id, host, online, last_seen_at, last_change_at)
VALUES ('HUBDOC01', '192.0.2.10', false, now() - interval '3 minutes', now() - interval '5 days');
INSERT INTO public.sensor_devices (id, external_id, device_name) VALUES ('00000000-0000-0000-0000-00000000d0c1', 'D0C1D0C1D0C1D0C1D0C1D0C1D0C1D0C1D0C1D0C1', 'Doctor Probe');
INSERT INTO public.sensor_readings (device_id, temperature, measured_at) VALUES ('00000000-0000-0000-0000-00000000d0c1', 3.5, now() - interval '2 hours');
SELECT json_build_object('hubs', coalesce((SELECT json_agg(json_build_object('hub_id', hub_id, 'host', host, 'online', online, 'age_s', greatest(0, extract(epoch FROM now() - last_seen_at))::bigint, 'change_age_s', greatest(0, extract(epoch FROM now() - last_change_at))::bigint) ORDER BY host, hub_id) FROM public.sensor_hubs), '[]'::json), 'newest_age_s', (SELECT extract(epoch FROM now() - max(measured_at))::bigint FROM public.sensor_readings)) AS filled_answer \gset
SELECT pg_temp.sd_assert((:'filled_answer'::jsonb#>>'{hubs,0,hub_id}') = 'HUBDOC01'
    AND (:'filled_answer'::jsonb#>>'{hubs,0,online}') = 'false'
    AND (:'filled_answer'::jsonb#>>'{hubs,0,age_s}')::bigint = 180
    AND (:'filled_answer'::jsonb#>>'{hubs,0,change_age_s}')::bigint = 5 * 86400
    AND (:'filled_answer'::jsonb->>'newest_age_s')::bigint = 7200,
  'filled tables: the hub and reading ages: ' || :'filled_answer');
ROLLBACK;
SELECT 'sensors doctor query: empty tables give a null reading age; a hub and a reading give their ages' AS result;
