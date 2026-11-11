-- Migration 185 (WH-157, part 1 of 3): the server starts keeping what the temperature report needs as evidence.
-- From the upgrade on, the database records:
--  1. warehouse_security.sensor_record_settings, one row: record_started_at (the upgrade moment the report names as the day recording
--     began), silent_minutes and out_minutes (the monitor's alert waits, 30 and 15 until the monitor stores its own values) and
--     recorded_through (the watermark of the stretch refresh; empty until it runs).
--  2. warehouse_security.sensor_limit_changes: every change of a sensor's temperature_min or temperature_max (sensor_devices.alert_config),
--     with its time and who made it. A table trigger, not update_sensor_device, so every path is recorded (the app's RPC, the server key,
--     psql). A sensor created later gets a first row ('change') with the limits it was created with. This migration writes one
--     'since_before' row per existing sensor with its limits at the upgrade. The limit in force at a time t is the newest row with
--     changed_at <= t, else the sensor's oldest row (its 'since_before' row, or the row of its creation). Rows are never updated; a row
--     goes only with its sensor (ON DELETE CASCADE) or by the retention job after 2 years (never the newest row of a sensor at or before
--     the cutoff: it is still in force).
--  3. warehouse_security.sensor_reading_changes: every reading added, changed or deleted in sensor_readings or sensor_hourly other than
--     by the sensor's own feed, the hourly roll-up and the retention job: when, which table, insert/update/delete/truncate, which sensor,
--     how many rows and their first and last time, and who (db_user: the API role of the request, or the login role outside the API;
--     login_user: session_user; app_profile: the signed-in profile, if any). Statement-level triggers with transition tables, one row per sensor and
--     statement. Insert-only: an update, a truncate or a delete is refused, except the retention job's delete of rows older than 2 years.
--
-- How the jobs are told apart: each job sets the transaction-local setting warehouse.sensor_job around its own statement and clears it
-- after; a row is left out of the record only when the setting AND the row fit what that job does:
--  * record_sensor_batch (the feed) sets 'ingest' around its INSERT into sensor_readings: an added reading is left out when its
--    measured_at is within the feed's window (30 days back to 5 minutes ahead).
--  * rollup_sensor_hourly sets 'rollup' around its INSERT ... ON CONFLICT DO UPDATE into sensor_hourly: an added hour is left out when it
--    has begun (hour < now); an updated hour when the key is the same, the new count is not smaller and the hour is within the last 32
--    days (readings arrive up to 30 days late).
--  * run_database_retention sets 'retention' around its deletes: a deleted raw reading is left out when it is older than 90 days, a
--    fixed bound (a lowered sensor_readings policy would delete readings the report says are kept, so those are recorded); a deleted
--    hourly row when older than 730 days.
--  An update that changes no value of the row is not a change and is never recorded. Everything else is recorded: any update of a raw
--  reading, any other delete (including the cascade of a deleted sensor), an insert by the server key or psql. The service role loses
--  TRUNCATE and TRIGGER on both tables; it keeps UPDATE and DELETE, so a change with the server's key is possible and recorded.
--  Still unrecorded for a superuser: turning the triggers off (session_replication_role, DISABLE TRIGGER, DROP TRIGGER), setting the
--  job setting by hand to do only what the jobs do anyway, editing the files or restoring an edited backup.
-- run_database_retention also removes rows of the two record tables older than their policy rows (730 days, never less than 730) and
-- reports sensor_reading_changes and sensor_limit_changes. Written against run_database_retention as migrations 123, 136 and 155 left
-- it, rollup_sensor_hourly as migration 136 left it and record_sensor_batch as the baseline has it. Marker-count patches.

-- ===== 1. the settings row =====
CREATE TABLE warehouse_security.sensor_record_settings (
  id                boolean PRIMARY KEY DEFAULT true CHECK (id),
  record_started_at timestamptz NOT NULL DEFAULT now(),
  silent_minutes    integer NOT NULL DEFAULT 30 CHECK (silent_minutes BETWEEN 1 AND 1440),
  out_minutes       integer NOT NULL DEFAULT 15 CHECK (out_minutes BETWEEN 1 AND 1440),
  recorded_through  timestamptz,
  updated_at        timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE warehouse_security.sensor_record_settings OWNER TO supabase_admin;
ALTER TABLE warehouse_security.sensor_record_settings ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE warehouse_security.sensor_record_settings FROM PUBLIC, anon, authenticated, service_role;
GRANT SELECT ON TABLE warehouse_security.sensor_record_settings TO service_role;
COMMENT ON TABLE warehouse_security.sensor_record_settings IS
  'One row (WH-157, migration 185): record_started_at is when the server began keeping limit changes, stretches and reading changes; silent_minutes and out_minutes are the monitor''s alert waits as last stored; recorded_through is the stretch refresh watermark.';
INSERT INTO warehouse_security.sensor_record_settings (id, record_started_at) VALUES (true, now());

-- ===== 2. the limit history =====
CREATE TABLE warehouse_security.sensor_limit_changes (
  id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  device_id       uuid NOT NULL REFERENCES public.sensor_devices(id) ON DELETE CASCADE,
  changed_at      timestamptz NOT NULL DEFAULT now(),
  temperature_min numeric,
  temperature_max numeric,
  source          text NOT NULL CHECK (source IN ('since_before', 'change')),
  changed_by      uuid,
  changed_by_name text,
  db_user         text
);
ALTER TABLE warehouse_security.sensor_limit_changes OWNER TO supabase_admin;
ALTER TABLE warehouse_security.sensor_limit_changes ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE warehouse_security.sensor_limit_changes FROM PUBLIC, anon, authenticated, service_role;
GRANT SELECT ON TABLE warehouse_security.sensor_limit_changes TO service_role;
CREATE INDEX sensor_limit_changes_device_idx ON warehouse_security.sensor_limit_changes (device_id, changed_at DESC);
COMMENT ON TABLE warehouse_security.sensor_limit_changes IS
  'Each sensor''s temperature limits over time (WH-157, migration 185). NULL = not set. source since_before: the limits at the upgrade, in force since before record_started_at; change: a change, or the limits a sensor was created with. changed_by is the user profile (NULL for the server), changed_by_name its name then, db_user the API role or login role. The limit in force at t is the newest row with changed_at <= t, else the oldest row.';

-- The number stored under a key of alert_config, or NULL when the key is missing or not a number (as sensor_status reads it).
CREATE FUNCTION warehouse_security.sensor_limit_number(p_config jsonb, p_key text) RETURNS numeric
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'pg_catalog'
AS $function$
  SELECT CASE WHEN jsonb_typeof(p_config -> p_key) = 'number' THEN (p_config ->> p_key)::numeric END
$function$;
ALTER FUNCTION warehouse_security.sensor_limit_number(jsonb, text) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION warehouse_security.sensor_limit_number(jsonb, text) FROM PUBLIC;

-- Who made a write, for the record tables: the role of the API request (PostgREST's request.jwt.claims), or NULL outside the API.
CREATE FUNCTION warehouse_security.sensor_record_api_role() RETURNS text
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'pg_catalog'
AS $function$
BEGIN
  RETURN NULLIF(current_setting('request.jwt.claims', true), '')::jsonb ->> 'role';
EXCEPTION WHEN OTHERS THEN
  RETURN NULL;
END $function$;
ALTER FUNCTION warehouse_security.sensor_record_api_role() OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION warehouse_security.sensor_record_api_role() FROM PUBLIC;

CREATE FUNCTION warehouse_security.record_sensor_limit_change() RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'warehouse_security'
AS $function$
DECLARE
  v_min numeric := warehouse_security.sensor_limit_number(NEW.alert_config, 'temperature_min');
  v_max numeric := warehouse_security.sensor_limit_number(NEW.alert_config, 'temperature_max');
  v_profile uuid;
BEGIN
  IF TG_OP = 'UPDATE'
     AND v_min IS NOT DISTINCT FROM warehouse_security.sensor_limit_number(OLD.alert_config, 'temperature_min')
     AND v_max IS NOT DISTINCT FROM warehouse_security.sensor_limit_number(OLD.alert_config, 'temperature_max') THEN
    RETURN NULL;
  END IF;
  v_profile := public.get_current_user_profile_id();
  INSERT INTO warehouse_security.sensor_limit_changes (device_id, temperature_min, temperature_max, source, changed_by, changed_by_name, db_user)
  VALUES (NEW.id, v_min, v_max, 'change', v_profile,
          (SELECT COALESCE(p.display_name, p.name) FROM public.user_profiles p WHERE p.id = v_profile),
          COALESCE(warehouse_security.sensor_record_api_role(), session_user::text));
  RETURN NULL;
END $function$;
ALTER FUNCTION warehouse_security.record_sensor_limit_change() OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION warehouse_security.record_sensor_limit_change() FROM PUBLIC;

CREATE TRIGGER sensor_limits_history AFTER UPDATE OF alert_config ON public.sensor_devices
  FOR EACH ROW WHEN (OLD.alert_config IS DISTINCT FROM NEW.alert_config)
  EXECUTE FUNCTION warehouse_security.record_sensor_limit_change();
CREATE TRIGGER sensor_limits_first AFTER INSERT ON public.sensor_devices
  FOR EACH ROW EXECUTE FUNCTION warehouse_security.record_sensor_limit_change();

-- No row is updated; a row is deleted only with its sensor (the cascade: the sensor row is already gone) or by the retention job when
-- older than 2 years.
CREATE FUNCTION warehouse_security.sensor_limit_changes_guard() RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'pg_catalog'
AS $function$
BEGIN
  IF TG_OP = 'DELETE' AND (NOT EXISTS (SELECT 1 FROM public.sensor_devices d WHERE d.id = OLD.device_id)
     OR (current_setting('warehouse.sensor_job', true) = 'retention' AND OLD.changed_at < now() - interval '730 days')) THEN
    RETURN OLD;
  END IF;
  RAISE EXCEPTION 'sensor_limit_changes keeps the limit history: % is refused', TG_OP USING ERRCODE = 'insufficient_privilege';
END $function$;
ALTER FUNCTION warehouse_security.sensor_limit_changes_guard() OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION warehouse_security.sensor_limit_changes_guard() FROM PUBLIC;
CREATE TRIGGER sensor_limit_changes_keep BEFORE UPDATE OR DELETE ON warehouse_security.sensor_limit_changes
  FOR EACH ROW EXECUTE FUNCTION warehouse_security.sensor_limit_changes_guard();

-- The limits at the upgrade, one row per existing sensor (active or not).
INSERT INTO warehouse_security.sensor_limit_changes (device_id, changed_at, temperature_min, temperature_max, source, db_user)
SELECT d.id, (SELECT s.record_started_at FROM warehouse_security.sensor_record_settings s),
       warehouse_security.sensor_limit_number(d.alert_config, 'temperature_min'),
       warehouse_security.sensor_limit_number(d.alert_config, 'temperature_max'),
       'since_before', session_user::text
  FROM public.sensor_devices d;

-- ===== 3. the record of changed readings =====
CREATE TABLE warehouse_security.sensor_reading_changes (
  id             bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  at             timestamptz NOT NULL DEFAULT now(),
  table_name     text NOT NULL CHECK (table_name IN ('sensor_readings', 'sensor_hourly')),
  op             text NOT NULL CHECK (op IN ('insert', 'update', 'delete', 'truncate')),
  device_id      uuid NOT NULL,
  device_name    text,
  row_count      bigint NOT NULL CHECK (row_count > 0),
  first_measured timestamptz,
  last_measured  timestamptz,
  db_user        text,
  login_user     text,
  app_profile    uuid
);
ALTER TABLE warehouse_security.sensor_reading_changes OWNER TO supabase_admin;
ALTER TABLE warehouse_security.sensor_reading_changes ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE warehouse_security.sensor_reading_changes FROM PUBLIC, anon, authenticated, service_role;
GRANT SELECT ON TABLE warehouse_security.sensor_reading_changes TO service_role;
CREATE INDEX sensor_reading_changes_device_idx ON warehouse_security.sensor_reading_changes (device_id, at);
CREATE INDEX sensor_reading_changes_at_idx ON warehouse_security.sensor_reading_changes (at);
COMMENT ON TABLE warehouse_security.sensor_reading_changes IS
  'Readings added, changed or deleted in sensor_readings or sensor_hourly other than by the feed (record_sensor_batch), the hourly roll-up and the retention job (WH-157, migration 185). One row per sensor and statement; first_measured and last_measured span the rows (measured_at, or hour). device_id has no foreign key, so a record outlives its sensor. Insert-only; kept 2 years.';

CREATE FUNCTION warehouse_security.record_sensor_reading_change() RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'warehouse_security'
AS $function$
DECLARE
  v_job text := COALESCE(current_setting('warehouse.sensor_job', true), '');
BEGIN
  -- Each branch names only the transition tables its trigger declares (PL/pgSQL plans a statement when it first runs).
  IF TG_TABLE_NAME = 'sensor_readings' AND TG_OP = 'INSERT' THEN
    INSERT INTO warehouse_security.sensor_reading_changes
      (table_name, op, device_id, device_name, row_count, first_measured, last_measured, db_user, login_user, app_profile)
    SELECT 'sensor_readings', 'insert', c.device_id, d.device_name, c.n, c.first_at, c.last_at,
           COALESCE(warehouse_security.sensor_record_api_role(), session_user::text), session_user::text, public.get_current_user_profile_id()
      FROM (SELECT r.device_id, count(*) AS n, min(r.measured_at) AS first_at, max(r.measured_at) AS last_at
              FROM new_rows r
             WHERE NOT (v_job = 'ingest' AND r.measured_at >= now() - interval '30 days' AND r.measured_at <= now() + interval '5 minutes')
             GROUP BY r.device_id) c
      LEFT JOIN public.sensor_devices d ON d.id = c.device_id;
  ELSIF TG_TABLE_NAME = 'sensor_readings' AND TG_OP = 'UPDATE' THEN
    INSERT INTO warehouse_security.sensor_reading_changes
      (table_name, op, device_id, device_name, row_count, first_measured, last_measured, db_user, login_user, app_profile)
    SELECT 'sensor_readings', 'update', c.device_id, d.device_name, c.n, c.first_at, c.last_at,
           COALESCE(warehouse_security.sensor_record_api_role(), session_user::text), session_user::text, public.get_current_user_profile_id()
      FROM (SELECT r.device_id, count(*) AS n, min(LEAST(r.measured_at, o.measured_at)) AS first_at,
                   max(GREATEST(r.measured_at, o.measured_at)) AS last_at
              FROM new_rows r LEFT JOIN old_rows o ON o.id = r.id
             WHERE ROW(o.*) IS DISTINCT FROM ROW(r.*)
             GROUP BY r.device_id) c
      LEFT JOIN public.sensor_devices d ON d.id = c.device_id;
  ELSIF TG_TABLE_NAME = 'sensor_readings' AND TG_OP = 'DELETE' THEN
    INSERT INTO warehouse_security.sensor_reading_changes
      (table_name, op, device_id, device_name, row_count, first_measured, last_measured, db_user, login_user, app_profile)
    SELECT 'sensor_readings', 'delete', c.device_id, d.device_name, c.n, c.first_at, c.last_at,
           COALESCE(warehouse_security.sensor_record_api_role(), session_user::text), session_user::text, public.get_current_user_profile_id()
      FROM (SELECT o.device_id, count(*) AS n, min(o.measured_at) AS first_at, max(o.measured_at) AS last_at
              FROM old_rows o
             WHERE NOT (v_job = 'retention' AND o.measured_at < now() - interval '90 days')
             GROUP BY o.device_id) c
      LEFT JOIN public.sensor_devices d ON d.id = c.device_id;
  ELSIF TG_TABLE_NAME = 'sensor_hourly' AND TG_OP = 'INSERT' THEN
    INSERT INTO warehouse_security.sensor_reading_changes
      (table_name, op, device_id, device_name, row_count, first_measured, last_measured, db_user, login_user, app_profile)
    SELECT 'sensor_hourly', 'insert', c.device_id, d.device_name, c.n, c.first_at, c.last_at,
           COALESCE(warehouse_security.sensor_record_api_role(), session_user::text), session_user::text, public.get_current_user_profile_id()
      FROM (SELECT h.device_id, count(*) AS n, min(h.hour) AS first_at, max(h.hour) AS last_at
              FROM new_rows h
             WHERE NOT (v_job = 'rollup' AND h.hour < now())
             GROUP BY h.device_id) c
      LEFT JOIN public.sensor_devices d ON d.id = c.device_id;
  ELSIF TG_TABLE_NAME = 'sensor_hourly' AND TG_OP = 'UPDATE' THEN
    INSERT INTO warehouse_security.sensor_reading_changes
      (table_name, op, device_id, device_name, row_count, first_measured, last_measured, db_user, login_user, app_profile)
    SELECT 'sensor_hourly', 'update', c.device_id, d.device_name, c.n, c.first_at, c.last_at,
           COALESCE(warehouse_security.sensor_record_api_role(), session_user::text), session_user::text, public.get_current_user_profile_id()
      FROM (SELECT h.device_id, count(*) AS n, min(h.hour) AS first_at, max(h.hour) AS last_at
              FROM new_rows h LEFT JOIN old_rows o ON o.device_id = h.device_id AND o.hour = h.hour
             WHERE ROW(o.*) IS DISTINCT FROM ROW(h.*)
               AND NOT (v_job = 'rollup' AND o.device_id IS NOT NULL AND h.n >= o.n AND h.hour >= now() - interval '32 days')
             GROUP BY h.device_id) c
      LEFT JOIN public.sensor_devices d ON d.id = c.device_id;
  ELSIF TG_TABLE_NAME = 'sensor_hourly' AND TG_OP = 'DELETE' THEN
    INSERT INTO warehouse_security.sensor_reading_changes
      (table_name, op, device_id, device_name, row_count, first_measured, last_measured, db_user, login_user, app_profile)
    SELECT 'sensor_hourly', 'delete', c.device_id, d.device_name, c.n, c.first_at, c.last_at,
           COALESCE(warehouse_security.sensor_record_api_role(), session_user::text), session_user::text, public.get_current_user_profile_id()
      FROM (SELECT o.device_id, count(*) AS n, min(o.hour) AS first_at, max(o.hour) AS last_at
              FROM old_rows o
             WHERE NOT (v_job = 'retention' AND o.hour < now() - interval '730 days')
             GROUP BY o.device_id) c
      LEFT JOIN public.sensor_devices d ON d.id = c.device_id;
  END IF;
  RETURN NULL;
END $function$;
ALTER FUNCTION warehouse_security.record_sensor_reading_change() OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION warehouse_security.record_sensor_reading_change() FROM PUBLIC;

-- A TRUNCATE (open only to the table owner and superusers after section 4) is recorded with the rows it removes, per sensor.
CREATE FUNCTION warehouse_security.record_sensor_reading_truncate() RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'warehouse_security'
AS $function$
BEGIN
  IF TG_TABLE_NAME = 'sensor_readings' THEN
    INSERT INTO warehouse_security.sensor_reading_changes
      (table_name, op, device_id, device_name, row_count, first_measured, last_measured, db_user, login_user, app_profile)
    SELECT 'sensor_readings', 'truncate', c.device_id, d.device_name, c.n, c.first_at, c.last_at,
           COALESCE(warehouse_security.sensor_record_api_role(), session_user::text), session_user::text, public.get_current_user_profile_id()
      FROM (SELECT r.device_id, count(*) AS n, min(r.measured_at) AS first_at, max(r.measured_at) AS last_at
              FROM public.sensor_readings r GROUP BY r.device_id) c
      LEFT JOIN public.sensor_devices d ON d.id = c.device_id;
  ELSE
    INSERT INTO warehouse_security.sensor_reading_changes
      (table_name, op, device_id, device_name, row_count, first_measured, last_measured, db_user, login_user, app_profile)
    SELECT 'sensor_hourly', 'truncate', c.device_id, d.device_name, c.n, c.first_at, c.last_at,
           COALESCE(warehouse_security.sensor_record_api_role(), session_user::text), session_user::text, public.get_current_user_profile_id()
      FROM (SELECT h.device_id, count(*) AS n, min(h.hour) AS first_at, max(h.hour) AS last_at
              FROM public.sensor_hourly h GROUP BY h.device_id) c
      LEFT JOIN public.sensor_devices d ON d.id = c.device_id;
  END IF;
  RETURN NULL;
END $function$;
ALTER FUNCTION warehouse_security.record_sensor_reading_truncate() OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION warehouse_security.record_sensor_reading_truncate() FROM PUBLIC;

CREATE TRIGGER sensor_readings_changes_insert AFTER INSERT ON public.sensor_readings
  REFERENCING NEW TABLE AS new_rows FOR EACH STATEMENT EXECUTE FUNCTION warehouse_security.record_sensor_reading_change();
CREATE TRIGGER sensor_readings_changes_update AFTER UPDATE ON public.sensor_readings
  REFERENCING OLD TABLE AS old_rows NEW TABLE AS new_rows FOR EACH STATEMENT EXECUTE FUNCTION warehouse_security.record_sensor_reading_change();
CREATE TRIGGER sensor_readings_changes_delete AFTER DELETE ON public.sensor_readings
  REFERENCING OLD TABLE AS old_rows FOR EACH STATEMENT EXECUTE FUNCTION warehouse_security.record_sensor_reading_change();
CREATE TRIGGER sensor_readings_changes_truncate BEFORE TRUNCATE ON public.sensor_readings
  FOR EACH STATEMENT EXECUTE FUNCTION warehouse_security.record_sensor_reading_truncate();
CREATE TRIGGER sensor_hourly_changes_insert AFTER INSERT ON public.sensor_hourly
  REFERENCING NEW TABLE AS new_rows FOR EACH STATEMENT EXECUTE FUNCTION warehouse_security.record_sensor_reading_change();
CREATE TRIGGER sensor_hourly_changes_update AFTER UPDATE ON public.sensor_hourly
  REFERENCING OLD TABLE AS old_rows NEW TABLE AS new_rows FOR EACH STATEMENT EXECUTE FUNCTION warehouse_security.record_sensor_reading_change();
CREATE TRIGGER sensor_hourly_changes_delete AFTER DELETE ON public.sensor_hourly
  REFERENCING OLD TABLE AS old_rows FOR EACH STATEMENT EXECUTE FUNCTION warehouse_security.record_sensor_reading_change();
CREATE TRIGGER sensor_hourly_changes_truncate BEFORE TRUNCATE ON public.sensor_hourly
  FOR EACH STATEMENT EXECUTE FUNCTION warehouse_security.record_sensor_reading_truncate();

-- Insert-only: an update or truncate is refused; a delete only by the retention job, of rows older than 2 years. (Also refuses a
-- TRUNCATE of sensor_limit_changes.)
CREATE FUNCTION warehouse_security.sensor_reading_changes_guard() RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'pg_catalog'
AS $function$
BEGIN
  IF TG_OP = 'DELETE' AND current_setting('warehouse.sensor_job', true) = 'retention' AND OLD.at < now() - interval '730 days' THEN
    RETURN OLD;
  END IF;
  RAISE EXCEPTION '% is insert-only: % is refused', TG_TABLE_NAME, TG_OP USING ERRCODE = 'insufficient_privilege';
END $function$;
ALTER FUNCTION warehouse_security.sensor_reading_changes_guard() OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION warehouse_security.sensor_reading_changes_guard() FROM PUBLIC;
CREATE TRIGGER sensor_reading_changes_keep BEFORE UPDATE OR DELETE ON warehouse_security.sensor_reading_changes
  FOR EACH ROW EXECUTE FUNCTION warehouse_security.sensor_reading_changes_guard();
CREATE TRIGGER sensor_reading_changes_no_truncate BEFORE TRUNCATE ON warehouse_security.sensor_reading_changes
  FOR EACH STATEMENT EXECUTE FUNCTION warehouse_security.sensor_reading_changes_guard();
CREATE TRIGGER sensor_limit_changes_no_truncate BEFORE TRUNCATE ON warehouse_security.sensor_limit_changes
  FOR EACH STATEMENT EXECUTE FUNCTION warehouse_security.sensor_reading_changes_guard();

-- ===== 4. grants on the reading tables =====
-- The service role keeps SELECT, INSERT, UPDATE and DELETE (a change with the server's key is possible, and recorded); it can no longer
-- empty the tables without a trace or add triggers.
REVOKE TRUNCATE, TRIGGER ON TABLE public.sensor_readings FROM service_role;
REVOKE TRUNCATE, TRIGGER ON TABLE public.sensor_hourly FROM service_role;

-- ===== 5. the jobs mark their own statements =====
DROP FUNCTION IF EXISTS pg_temp.patch_function(regprocedure, text[], text[]);
CREATE FUNCTION pg_temp.patch_function(p_function regprocedure, p_old text[], p_new text[]) RETURNS void
    LANGUAGE plpgsql AS $$
DECLARE
  v_def text := pg_get_functiondef(p_function);
  v_count integer;
  i integer;
BEGIN
  IF array_length(p_old, 1) IS DISTINCT FROM array_length(p_new, 1) THEN
    RAISE EXCEPTION '%: the marker list and the replacement list differ in length', p_function;
  END IF;
  FOR i IN 1 .. array_length(p_old, 1) LOOP
    IF position(p_old[i] IN p_new[i]) > 0 THEN
      RAISE EXCEPTION '%: the replacement of marker % contains the marker', p_function, i;
    END IF;
    v_count := (length(v_def) - length(replace(v_def, p_old[i], ''))) / length(p_old[i]);
    IF v_count <> 1 THEN
      RAISE EXCEPTION '%: expected marker % once, found % times', p_function, i, v_count;
    END IF;
    v_def := replace(v_def, p_old[i], p_new[i]);
  END LOOP;
  EXECUTE v_def;
END $$;

-- The feed: 'ingest' around its one INSERT into sensor_readings.
SELECT pg_temp.patch_function('public.record_sensor_batch(text, jsonb, jsonb)'::regprocedure, ARRAY[
$m$    IF NOT v_no_values THEN
      INSERT INTO public.sensor_readings(device_id, temperature, humidity, measured_at)$m$,
$m$      GET DIAGNOSTICS v_inserted = ROW_COUNT;
      IF v_inserted = 1 THEN v_accepted$m$
], ARRAY[
$m$    IF NOT v_no_values THEN
      -- Migration 185 (WH-157): the record of changed readings leaves out what the feed adds (warehouse.sensor_job 'ingest').
      PERFORM set_config('warehouse.sensor_job', 'ingest', true);
      INSERT INTO public.sensor_readings(device_id, temperature, humidity, measured_at)$m$,
$m$      GET DIAGNOSTICS v_inserted = ROW_COUNT;
      PERFORM set_config('warehouse.sensor_job', '', true);
      IF v_inserted = 1 THEN v_accepted$m$
]);

-- The roll-up: 'rollup' around its INSERT ... ON CONFLICT DO UPDATE.
SELECT pg_temp.patch_function('warehouse_maintenance.rollup_sensor_hourly(timestamptz, boolean)'::regprocedure, ARRAY[
$m$    RETURN v_n;
  END IF;
  WITH written AS ($m$,
$m$  SELECT count(*) INTO v_n FROM written;
  RETURN v_n;$m$
], ARRAY[
$m$    RETURN v_n;
  END IF;
  -- Migration 185 (WH-157): the record of changed readings leaves out what the roll-up writes (warehouse.sensor_job 'rollup').
  PERFORM set_config('warehouse.sensor_job', 'rollup', true);
  WITH written AS ($m$,
$m$  SELECT count(*) INTO v_n FROM written;
  PERFORM set_config('warehouse.sensor_job', '', true);
  RETURN v_n;$m$
]);

-- Retention: 'retention' around its sensor deletes (after the roll-up, which clears the setting); the two record tables lose rows older
-- than their policy, never younger than 730 days (their guards refuse a younger delete); the preview counts the same.
SELECT pg_temp.patch_function('warehouse_maintenance.run_database_retention(timestamptz, boolean)'::regprocedure, ARRAY[
$m$    result := result || jsonb_build_object('sensor_hourly_rolled', rolled);
    DELETE FROM public.sensor_readings r USING$m$,
$m$    GET DIAGNOSTICS affected = ROW_COUNT; result := result || jsonb_build_object('sensor_hourly', affected);
  ELSE$m$,
$m$        FROM warehouse_maintenance.retention_policy WHERE key = 'sensor_hourly'))
    ) INTO result;$m$
], ARRAY[
$m$    result := result || jsonb_build_object('sensor_hourly_rolled', rolled);
    -- Migration 185 (WH-157): the record of changed readings leaves out what retention deletes (warehouse.sensor_job 'retention').
    PERFORM set_config('warehouse.sensor_job', 'retention', true);
    DELETE FROM public.sensor_readings r USING$m$,
$m$    GET DIAGNOSTICS affected = ROW_COUNT; result := result || jsonb_build_object('sensor_hourly', affected);
    DELETE FROM warehouse_security.sensor_reading_changes c
     WHERE c.at < (SELECT LEAST(p_now - make_interval(days => days), now() - interval '730 days')
                     FROM warehouse_maintenance.retention_policy WHERE key = 'sensor_reading_changes');
    GET DIAGNOSTICS affected = ROW_COUNT; result := result || jsonb_build_object('sensor_reading_changes', affected);
    DELETE FROM warehouse_security.sensor_limit_changes c
     USING (SELECT LEAST(p_now - make_interval(days => days), now() - interval '730 days') AS cutoff
              FROM warehouse_maintenance.retention_policy WHERE key = 'sensor_limit_changes') k
     WHERE c.changed_at < k.cutoff
       AND EXISTS (SELECT 1 FROM warehouse_security.sensor_limit_changes n WHERE n.device_id = c.device_id
                     AND n.changed_at <= k.cutoff AND (n.changed_at, n.id) > (c.changed_at, c.id));
    GET DIAGNOSTICS affected = ROW_COUNT; result := result || jsonb_build_object('sensor_limit_changes', affected);
    PERFORM set_config('warehouse.sensor_job', '', true);
  ELSE$m$,
$m$        FROM warehouse_maintenance.retention_policy WHERE key = 'sensor_hourly')),
      'sensor_reading_changes', (SELECT count(*) FROM warehouse_security.sensor_reading_changes c
        WHERE c.at < (SELECT LEAST(p_now - make_interval(days => days), now() - interval '730 days')
                        FROM warehouse_maintenance.retention_policy WHERE key = 'sensor_reading_changes')),
      'sensor_limit_changes', (SELECT count(*) FROM warehouse_security.sensor_limit_changes c,
          (SELECT LEAST(p_now - make_interval(days => days), now() - interval '730 days') AS cutoff
             FROM warehouse_maintenance.retention_policy WHERE key = 'sensor_limit_changes') k
        WHERE c.changed_at < k.cutoff
          AND EXISTS (SELECT 1 FROM warehouse_security.sensor_limit_changes n WHERE n.device_id = c.device_id
                        AND n.changed_at <= k.cutoff AND (n.changed_at, n.id) > (c.changed_at, c.id)))
    ) INTO result;$m$
]);

DROP FUNCTION pg_temp.patch_function(regprocedure, text[], text[]);

-- ===== 6. retention policy rows =====
INSERT INTO warehouse_maintenance.retention_policy(key, days, description) VALUES
  ('sensor_limit_changes', 730, 'Sensor temperature limit history, kept 2 years (never the limits still in force)'),
  ('sensor_reading_changes', 730, 'Record of sensor readings added, changed or deleted other than by the feed, roll-up and retention, kept 2 years')
ON CONFLICT (key) DO NOTHING;
