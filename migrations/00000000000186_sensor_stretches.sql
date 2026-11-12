-- Migration 186 (WH-157, part 2 of 3): out-of-range and no-reading stretches, kept 2 years, with the time their alert was posted.
--
--  1. warehouse_security.sensor_stretches: per sensor, every stretch of kind too_warm, too_cold or no_readings, with started_at,
--     ended_at (NULL = still continuing), worst (the reading furthest beyond its limit), limit_value (the limit that reading broke),
--     beyond (how far), readings (how many readings, or for hourly rows the readings they summarize), threshold_minutes (the alert wait
--     in force when derived: out_minutes for out of range, silent_minutes for no readings), source ('raw', or 'hourly' when derived from
--     hourly rows: its times are whole UTC hours), and the alert: alert_posted_at, alert_state ('posted', 'no_channel': the audience had
--     no target, 'failed': a post was tried and no target took it) and alert_via (the audience). derived_at is the last derivation.
--     Stretches outlive the raw readings (90 days) and do not depend on the checker's 2-day, 500-reading window.
--  2. The rules (spec step 2). Readings with a temperature, in measured_at order, each judged under the limit in force at its own time
--     (warehouse_security.sensor_limit_at: the newest limit row at or before the time, else the sensor's oldest row; migration 185):
--     a run of consecutive readings above the highest limit is one too_warm stretch from its first reading to the first reading that is
--     not above it (inside, or too cold); NULL end while there is none yet. too_cold likewise. Every stretch is kept, however short.
--     no_readings: two consecutive readings (temperature or humidity) more than silent_minutes apart, from the earlier to the later; an
--     open one from an active sensor's last reading when that is older than silent_minutes. For hours older than a sensor's oldest raw
--     reading (the first refresh only), the hourly rows: an hour whose highest is above the limit is too warm (lowest below: too cold),
--     consecutive hours join, and missing hours longer than silent_minutes are no readings.
--  3. warehouse_maintenance.refresh_sensor_stretches(p_now, p_silent_minutes, p_out_minutes): incremental. The first call (no
--     recorded_through) derives every stretch from all stored readings and hourly rows (the backfill: before the upgrade). Later calls
--     take each sensor with readings stored since recorded_through less 10 minutes (slack for slow commits); from the earlier of their
--     oldest measured_at and the start of any stretch open or ending after it, the stretches are derived again, with the reading before as
--     the start of a gap, and replace the old ones. A re-derived stretch keeps the alert of the old one with the same start, else of the
--     first old one of the same kind it overlaps, so a late reading that splits or shortens a stretch keeps its alert. Late readings
--     (the feed takes them up to 30 days late) fill gaps and shorten no_readings stretches. Minutes outside 1-1440 or NULL mean the stored
--     ones; given ones are stored in sensor_record_settings. Called by scripts/watch.mjs every 5-minute run and by run_database_retention
--     before it deletes raw readings, so no raw reading is deleted unscanned.
--  4. warehouse_maintenance.record_sensor_alert_posts(p_posts): [{device_id, alert 'range'|'silent'|'hub', since, at, via, state
--     'posted'|'failed'|'no_channel'}], written by scripts/watch.mjs after it posted (or could not post) a sensor alert's start.
--     range: the sensor's too_warm and too_cold stretches open at since (the alert's firingSince) or started after it up to at.
--     silent: the sensor's no_readings stretch open at at. hub (sensors_stale: the hub or bridge is down, so the sensors' own silence
--     alerts are held back): every no_readings stretch open at at. 'posted' fills alert_posted_at where it is empty (it replaces an
--     earlier 'failed' or 'no_channel'); 'failed' and 'no_channel' fill only a stretch with no alert yet. Safe to repeat.
--  5. run_database_retention refreshes the stretches first (stored minutes), then, after its other deletes, removes stretches that ended
--     more than the policy row sensor_stretches (730 days) ago; an open stretch is never removed. The preview counts them.
-- No API role can read or write the new table or call the functions (the checker and retention run as supabase_admin).

-- ===== 1. the table =====
CREATE TABLE warehouse_security.sensor_stretches (
  id                bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  device_id         uuid NOT NULL REFERENCES public.sensor_devices(id) ON DELETE CASCADE,
  kind              text NOT NULL CHECK (kind IN ('too_warm', 'too_cold', 'no_readings')),
  started_at        timestamptz NOT NULL,
  ended_at          timestamptz CHECK (ended_at IS NULL OR ended_at >= started_at),
  worst             numeric,
  limit_value       numeric,
  beyond            numeric,
  readings          integer NOT NULL DEFAULT 0 CHECK (readings >= 0),
  threshold_minutes integer NOT NULL CHECK (threshold_minutes BETWEEN 1 AND 1440),
  source            text NOT NULL CHECK (source IN ('raw', 'hourly')),
  alert_posted_at   timestamptz,
  alert_state       text CHECK (alert_state IN ('posted', 'no_channel', 'failed')),
  alert_via         text,
  derived_at        timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT sensor_stretches_one_start UNIQUE (device_id, kind, started_at)
);
ALTER TABLE warehouse_security.sensor_stretches OWNER TO supabase_admin;
ALTER TABLE warehouse_security.sensor_stretches ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE warehouse_security.sensor_stretches FROM PUBLIC, anon, authenticated, service_role;
CREATE INDEX sensor_stretches_device_start_idx ON warehouse_security.sensor_stretches (device_id, started_at);
CREATE INDEX sensor_stretches_ended_idx ON warehouse_security.sensor_stretches (ended_at);
COMMENT ON TABLE warehouse_security.sensor_stretches IS
  'Out-of-range (too_warm, too_cold) and no_readings stretches per sensor (WH-157, migration 186), derived by warehouse_maintenance.refresh_sensor_stretches; ended_at NULL = still continuing; source hourly = from hourly rows (whole UTC hours). alert_state posted (alert_posted_at set), no_channel or failed; NULL = no alert recorded. Kept 2 years after they end (retention key sensor_stretches).';

INSERT INTO warehouse_maintenance.retention_policy(key, days, description)
VALUES ('sensor_stretches', 730, 'Out-of-range and no-reading stretches per sensor, kept 2 years after they end')
ON CONFLICT (key) DO NOTHING;

-- ===== 2. the limit in force at a time =====
-- The newest limit row at or before p_at, else the sensor's oldest row (its 'since_before' row, or the row of its creation: today's
-- limits judge what came before the record). No row: nothing (no limits known).
CREATE FUNCTION warehouse_security.sensor_limit_at(p_device_id uuid, p_at timestamptz,
  OUT temperature_min numeric, OUT temperature_max numeric, OUT since timestamptz, OUT since_before boolean)
 LANGUAGE sql
 STABLE
 SET search_path TO 'pg_catalog'
AS $function$
  SELECT c.temperature_min, c.temperature_max, c.changed_at, c.source = 'since_before'
    FROM warehouse_security.sensor_limit_changes c
   WHERE c.device_id = p_device_id
   ORDER BY (c.changed_at <= p_at) DESC,
            CASE WHEN c.changed_at <= p_at THEN c.changed_at END DESC NULLS LAST,
            CASE WHEN c.changed_at <= p_at THEN c.id END DESC NULLS LAST,
            c.changed_at, c.id
   LIMIT 1
$function$;
ALTER FUNCTION warehouse_security.sensor_limit_at(uuid, timestamptz) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION warehouse_security.sensor_limit_at(uuid, timestamptz) FROM PUBLIC;

-- ===== 3. deriving one sensor's stretches =====
-- From p_from on (p_full: everything, hourly rows first), into pg_temp.sensor_stretch_new, then replacing the old stretches of the same
-- range and carrying their alerts over. Returns the stretches written. Called only by refresh_sensor_stretches, under its lock.
CREATE FUNCTION warehouse_maintenance.derive_sensor_stretches(p_device_id uuid, p_from timestamptz, p_full boolean, p_now timestamptz,
  p_silent_minutes integer, p_out_minutes integer) RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'warehouse_security', 'warehouse_maintenance'
AS $function$
DECLARE
  v_gap interval := make_interval(mins => p_silent_minutes);
  v_active boolean;
  v_w timestamptz;
  v_prev timestamptz;           -- the previous reading's time, or the end of the previous hourly row
  v_prev_hourly boolean := false;
  v_first_raw timestamptz;
  lim_at timestamptz[];
  lim_min numeric[];
  lim_max numeric[];
  lim_n integer;
  lim_i integer := 0;
  v_lo numeric;
  v_hi numeric;
  r record;
  v_k text;
  v_ex numeric;
  -- the raw run
  c_kind text; c_start timestamptz; c_n integer; c_best numeric; c_worst numeric; c_limit numeric;
  -- the hourly runs, warm and cold apart (one hour can be both)
  w_start timestamptz; w_end timestamptz; w_n integer; w_best numeric; w_worst numeric; w_limit numeric;
  k_start timestamptz; k_end timestamptz; k_n integer; k_best numeric; k_worst numeric; k_limit numeric;
  v_written bigint;
BEGIN
  SELECT d.active INTO v_active FROM public.sensor_devices d WHERE d.id = p_device_id;
  IF NOT FOUND THEN RETURN 0; END IF;
  SELECT array_agg(c.changed_at ORDER BY c.changed_at, c.id), array_agg(c.temperature_min ORDER BY c.changed_at, c.id),
         array_agg(c.temperature_max ORDER BY c.changed_at, c.id)
    INTO lim_at, lim_min, lim_max
    FROM warehouse_security.sensor_limit_changes c WHERE c.device_id = p_device_id;
  lim_n := COALESCE(cardinality(lim_at), 0);

  -- Work tables for this transaction (made once, without the notice IF NOT EXISTS would print for every sensor).
  IF to_regclass('pg_temp.sensor_stretch_new') IS NULL THEN
    CREATE TEMP TABLE sensor_stretch_new (
      kind text, started_at timestamptz, ended_at timestamptz, worst numeric, limit_value numeric, beyond numeric,
      readings integer, threshold_minutes integer, source text) ON COMMIT DROP;
    CREATE TEMP TABLE sensor_stretch_old (
      kind text, started_at timestamptz, ended_at timestamptz, alert_posted_at timestamptz, alert_state text, alert_via text) ON COMMIT DROP;
  END IF;
  TRUNCATE pg_temp.sensor_stretch_new;

  IF p_full THEN
    v_w := '-infinity';
  ELSE
    v_w := LEAST(p_from, (SELECT min(s.started_at) FROM warehouse_security.sensor_stretches s
                           WHERE s.device_id = p_device_id AND s.source = 'raw' AND (s.ended_at IS NULL OR s.ended_at >= p_from)));
    SELECT max(x.measured_at) INTO v_prev FROM public.sensor_readings x WHERE x.device_id = p_device_id AND x.measured_at < v_w;
  END IF;

  -- The hourly rows older than the oldest raw reading (first refresh only).
  IF p_full THEN
    SELECT min(x.measured_at) INTO v_first_raw FROM public.sensor_readings x WHERE x.device_id = p_device_id;
    FOR r IN SELECT h.hour, h.n, h.t_min, h.t_max FROM public.sensor_hourly h
              WHERE h.device_id = p_device_id AND (v_first_raw IS NULL OR h.hour < date_trunc('hour', v_first_raw, 'UTC'))
              ORDER BY h.hour LOOP
      IF v_prev IS NOT NULL AND r.hour - v_prev > v_gap THEN
        INSERT INTO pg_temp.sensor_stretch_new VALUES ('no_readings', v_prev, r.hour, NULL, NULL, NULL, 0, p_silent_minutes, 'hourly');
      END IF;
      WHILE lim_i < lim_n AND lim_at[lim_i + 1] <= r.hour LOOP lim_i := lim_i + 1; END LOOP;
      IF lim_n > 0 THEN v_lo := lim_min[GREATEST(lim_i, 1)]; v_hi := lim_max[GREATEST(lim_i, 1)]; END IF;
      -- too warm: a run goes on only through the next whole hour
      IF w_start IS NOT NULL AND (w_end <> r.hour OR NOT COALESCE(r.t_max > v_hi, false)) THEN
        INSERT INTO pg_temp.sensor_stretch_new VALUES ('too_warm', w_start, w_end, w_worst, w_limit, w_best, w_n, p_out_minutes, 'hourly');
        w_start := NULL;
      END IF;
      IF COALESCE(r.t_max > v_hi, false) THEN
        IF w_start IS NULL THEN w_start := r.hour; w_n := 0; w_best := NULL; END IF;
        w_n := w_n + r.n;
        v_ex := r.t_max - v_hi;
        IF w_best IS NULL OR v_ex > w_best THEN w_best := v_ex; w_worst := r.t_max; w_limit := v_hi; END IF;
        w_end := r.hour + interval '1 hour';
      END IF;
      -- too cold
      IF k_start IS NOT NULL AND (k_end <> r.hour OR NOT COALESCE(r.t_min < v_lo, false)) THEN
        INSERT INTO pg_temp.sensor_stretch_new VALUES ('too_cold', k_start, k_end, k_worst, k_limit, k_best, k_n, p_out_minutes, 'hourly');
        k_start := NULL;
      END IF;
      IF COALESCE(r.t_min < v_lo, false) THEN
        IF k_start IS NULL THEN k_start := r.hour; k_n := 0; k_best := NULL; END IF;
        k_n := k_n + r.n;
        v_ex := v_lo - r.t_min;
        IF k_best IS NULL OR v_ex > k_best THEN k_best := v_ex; k_worst := r.t_min; k_limit := v_lo; END IF;
        k_end := r.hour + interval '1 hour';
      END IF;
      v_prev := r.hour + interval '1 hour';
      v_prev_hourly := true;
    END LOOP;
    IF w_start IS NOT NULL THEN
      INSERT INTO pg_temp.sensor_stretch_new VALUES ('too_warm', w_start, w_end, w_worst, w_limit, w_best, w_n, p_out_minutes, 'hourly');
    END IF;
    IF k_start IS NOT NULL THEN
      INSERT INTO pg_temp.sensor_stretch_new VALUES ('too_cold', k_start, k_end, k_worst, k_limit, k_best, k_n, p_out_minutes, 'hourly');
    END IF;
  END IF;

  -- The raw readings from v_w on.
  FOR r IN SELECT x.measured_at, x.temperature FROM public.sensor_readings x
            WHERE x.device_id = p_device_id AND x.measured_at >= v_w ORDER BY x.measured_at LOOP
    IF v_prev IS NOT NULL AND r.measured_at - v_prev > v_gap THEN
      INSERT INTO pg_temp.sensor_stretch_new VALUES ('no_readings', v_prev, r.measured_at, NULL, NULL, NULL, 0, p_silent_minutes,
        CASE WHEN v_prev_hourly THEN 'hourly' ELSE 'raw' END);
    END IF;
    v_prev := r.measured_at;
    v_prev_hourly := false;
    CONTINUE WHEN r.temperature IS NULL;
    WHILE lim_i < lim_n AND lim_at[lim_i + 1] <= r.measured_at LOOP lim_i := lim_i + 1; END LOOP;
    IF lim_n > 0 THEN v_lo := lim_min[GREATEST(lim_i, 1)]; v_hi := lim_max[GREATEST(lim_i, 1)]; END IF;
    v_k := CASE WHEN r.temperature > v_hi THEN 'too_warm' WHEN r.temperature < v_lo THEN 'too_cold' END;
    IF c_kind IS NOT NULL AND v_k IS DISTINCT FROM c_kind THEN
      INSERT INTO pg_temp.sensor_stretch_new VALUES (c_kind, c_start, r.measured_at, c_worst, c_limit, c_best, c_n, p_out_minutes, 'raw');
      c_kind := NULL;
    END IF;
    IF v_k IS NOT NULL THEN
      IF c_kind IS NULL THEN c_kind := v_k; c_start := r.measured_at; c_n := 0; c_best := NULL; END IF;
      c_n := c_n + 1;
      v_ex := CASE WHEN v_k = 'too_warm' THEN r.temperature - v_hi ELSE v_lo - r.temperature END;
      IF c_best IS NULL OR v_ex > c_best THEN
        c_best := v_ex; c_worst := r.temperature; c_limit := CASE WHEN v_k = 'too_warm' THEN v_hi ELSE v_lo END;
      END IF;
    END IF;
  END LOOP;
  IF c_kind IS NOT NULL THEN
    INSERT INTO pg_temp.sensor_stretch_new VALUES (c_kind, c_start, NULL, c_worst, c_limit, c_best, c_n, p_out_minutes, 'raw');
  END IF;
  -- Silent now: an open gap from the last reading of an active sensor.
  IF v_active AND v_prev IS NOT NULL AND v_prev < p_now - v_gap THEN
    INSERT INTO pg_temp.sensor_stretch_new VALUES ('no_readings', v_prev, NULL, NULL, NULL, NULL, 0, p_silent_minutes,
      CASE WHEN v_prev_hourly THEN 'hourly' ELSE 'raw' END);
  END IF;

  -- Replace: the old stretches of the range (and any with a start written again), their alerts carried over.
  TRUNCATE pg_temp.sensor_stretch_old;
  WITH gone AS (
    DELETE FROM warehouse_security.sensor_stretches s
     WHERE s.device_id = p_device_id
       AND (p_full OR (s.source = 'raw' AND s.started_at >= v_w)
            OR EXISTS (SELECT 1 FROM pg_temp.sensor_stretch_new n WHERE n.kind = s.kind AND n.started_at = s.started_at))
    RETURNING s.kind, s.started_at, s.ended_at, s.alert_posted_at, s.alert_state, s.alert_via
  )
  INSERT INTO pg_temp.sensor_stretch_old SELECT * FROM gone;
  INSERT INTO warehouse_security.sensor_stretches (device_id, kind, started_at, ended_at, worst, limit_value, beyond, readings,
    threshold_minutes, source, alert_posted_at, alert_state, alert_via, derived_at)
  SELECT p_device_id, n.kind, n.started_at, n.ended_at, n.worst, n.limit_value, n.beyond, n.readings, n.threshold_minutes, n.source,
         a.alert_posted_at, a.alert_state, a.alert_via, now()
    FROM pg_temp.sensor_stretch_new n
    LEFT JOIN LATERAL (
      SELECT o.alert_posted_at, o.alert_state, o.alert_via FROM pg_temp.sensor_stretch_old o
       WHERE o.kind = n.kind AND o.alert_state IS NOT NULL
         AND (o.started_at = n.started_at
              OR (o.started_at < COALESCE(n.ended_at, 'infinity') AND COALESCE(o.ended_at, 'infinity') > n.started_at))
       ORDER BY (o.started_at = n.started_at) DESC, (o.alert_posted_at IS NOT NULL) DESC, o.started_at
       LIMIT 1) a ON true;
  GET DIAGNOSTICS v_written = ROW_COUNT;
  RETURN v_written;
END $function$;
ALTER FUNCTION warehouse_maintenance.derive_sensor_stretches(uuid, timestamptz, boolean, timestamptz, integer, integer) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION warehouse_maintenance.derive_sensor_stretches(uuid, timestamptz, boolean, timestamptz, integer, integer) FROM PUBLIC;

-- ===== 4. the refresh =====
CREATE FUNCTION warehouse_maintenance.refresh_sensor_stretches(p_now timestamptz DEFAULT now(), p_silent_minutes integer DEFAULT NULL,
  p_out_minutes integer DEFAULT NULL) RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'warehouse_security', 'warehouse_maintenance'
AS $function$
DECLARE
  v_now timestamptz := COALESCE(p_now, now());
  v_set warehouse_security.sensor_record_settings;
  v_silent integer;
  v_out integer;
  v_full boolean;
  v_since timestamptz;
  v_dev record;
  v_devices integer := 0;
  v_written bigint := 0;
  v_open bigint := 0;
  v_n bigint;
BEGIN
  -- One refresh at a time (the 5-minute checker and the daily retention); alert posts wait for it too.
  PERFORM pg_advisory_xact_lock(71047);
  SELECT * INTO v_set FROM warehouse_security.sensor_record_settings s WHERE s.id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'refresh_sensor_stretches: warehouse_security.sensor_record_settings has no row (migration 185)';
  END IF;
  v_silent := COALESCE(CASE WHEN p_silent_minutes BETWEEN 1 AND 1440 THEN p_silent_minutes END, v_set.silent_minutes);
  v_out := COALESCE(CASE WHEN p_out_minutes BETWEEN 1 AND 1440 THEN p_out_minutes END, v_set.out_minutes);
  v_full := v_set.recorded_through IS NULL;
  v_since := CASE WHEN v_full THEN '-infinity'::timestamptz ELSE v_set.recorded_through - interval '10 minutes' END;

  FOR v_dev IN
    SELECT x.device_id, min(x.measured_at) AS first_new FROM public.sensor_readings x WHERE x.recorded_at > v_since GROUP BY x.device_id
    UNION ALL
    -- the backfill: sensors with hourly rows only
    SELECT h.device_id, NULL FROM public.sensor_hourly h
     WHERE v_full AND NOT EXISTS (SELECT 1 FROM public.sensor_readings x WHERE x.device_id = h.device_id)
     GROUP BY h.device_id
  LOOP
    v_written := v_written + warehouse_maintenance.derive_sensor_stretches(v_dev.device_id, v_dev.first_new, v_full, v_now, v_silent, v_out);
    v_devices := v_devices + 1;
  END LOOP;

  -- Every active sensor silent for longer than silent_minutes has an open no_readings stretch from its last reading.
  FOR v_dev IN
    SELECT d.id, (SELECT max(x.measured_at) FROM public.sensor_readings x WHERE x.device_id = d.id) AS last_at
      FROM public.sensor_devices d WHERE d.active
  LOOP
    CONTINUE WHEN v_dev.last_at IS NULL OR v_dev.last_at >= v_now - make_interval(mins => v_silent);
    INSERT INTO warehouse_security.sensor_stretches (device_id, kind, started_at, ended_at, readings, threshold_minutes, source)
    VALUES (v_dev.id, 'no_readings', v_dev.last_at, NULL, 0, v_silent, 'raw')
    ON CONFLICT (device_id, kind, started_at) DO NOTHING;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    v_open := v_open + v_n;
  END LOOP;

  UPDATE warehouse_security.sensor_record_settings s
     SET recorded_through = now(), silent_minutes = v_silent, out_minutes = v_out, updated_at = now()
   WHERE s.id;
  RETURN jsonb_build_object('full', v_full, 'devices', v_devices, 'stretches', v_written + v_open,
                            'silent_minutes', v_silent, 'out_minutes', v_out);
END $function$;
ALTER FUNCTION warehouse_maintenance.refresh_sensor_stretches(timestamptz, integer, integer) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION warehouse_maintenance.refresh_sensor_stretches(timestamptz, integer, integer) FROM PUBLIC, anon, authenticated, service_role;

-- ===== 5. alert posting times =====
CREATE FUNCTION warehouse_maintenance.record_sensor_alert_posts(p_posts jsonb) RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'warehouse_security', 'warehouse_maintenance'
AS $function$
DECLARE
  v_post jsonb;
  v_alert text;
  v_state text;
  v_device uuid;
  v_at timestamptz;
  v_since timestamptz;
  v_via text;
  v_n integer;
  v_total integer := 0;
BEGIN
  IF p_posts IS NULL OR jsonb_typeof(p_posts) <> 'array' THEN
    RAISE EXCEPTION 'record_sensor_alert_posts: p_posts must be a JSON array';
  END IF;
  PERFORM pg_advisory_xact_lock(71047);
  FOR v_post IN SELECT e.value FROM jsonb_array_elements(p_posts) AS e LOOP
    v_alert := v_post ->> 'alert';
    v_state := v_post ->> 'state';
    v_device := NULLIF(v_post ->> 'device_id', '')::uuid;
    v_at := (v_post ->> 'at')::timestamptz;
    v_since := COALESCE(NULLIF(v_post ->> 'since', '')::timestamptz, v_at);
    v_via := CASE WHEN v_state = 'no_channel' THEN NULL ELSE left(NULLIF(v_post ->> 'via', ''), 40) END;
    IF v_alert IS NULL OR v_alert NOT IN ('range', 'silent', 'hub') OR v_state IS NULL OR v_state NOT IN ('posted', 'failed', 'no_channel')
       OR v_at IS NULL OR (v_alert <> 'hub' AND v_device IS NULL) THEN
      RAISE EXCEPTION 'record_sensor_alert_posts: an entry is not valid: %', left(v_post::text, 300);
    END IF;
    UPDATE warehouse_security.sensor_stretches s
       SET alert_posted_at = CASE WHEN v_state = 'posted' THEN v_at END, alert_state = v_state, alert_via = v_via
     WHERE s.alert_posted_at IS NULL
       AND (v_state = 'posted' OR s.alert_state IS NULL)
       AND CASE v_alert
             WHEN 'range' THEN s.device_id = v_device AND s.kind IN ('too_warm', 'too_cold')
                  AND ((s.started_at <= v_since AND (s.ended_at IS NULL OR s.ended_at > v_since))
                       OR (s.started_at > v_since AND s.started_at <= v_at))
             WHEN 'silent' THEN s.device_id = v_device AND s.kind = 'no_readings'
                  AND s.started_at <= v_at AND (s.ended_at IS NULL OR s.ended_at > v_at)
             ELSE s.kind = 'no_readings' AND s.started_at <= v_at AND (s.ended_at IS NULL OR s.ended_at > v_at)
           END;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    v_total := v_total + v_n;
  END LOOP;
  RETURN v_total;
END $function$;
ALTER FUNCTION warehouse_maintenance.record_sensor_alert_posts(jsonb) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION warehouse_maintenance.record_sensor_alert_posts(jsonb) FROM PUBLIC, anon, authenticated, service_role;

-- ===== 6. retention: refresh first, then remove old stretches =====
-- Written against run_database_retention as migrations 123, 136, 155 and 185 left it. Marker-count patch.
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

SELECT pg_temp.patch_function('warehouse_maintenance.run_database_retention(timestamptz, boolean)'::regprocedure, ARRAY[
$m$    GET DIAGNOSTICS affected = ROW_COUNT; result := result || jsonb_build_object('idempotency_keys', affected);
    rolled := warehouse_maintenance.rollup_sensor_hourly(p_now, true);$m$,
$m$    GET DIAGNOSTICS affected = ROW_COUNT; result := result || jsonb_build_object('sensor_limit_changes', affected);
    PERFORM set_config('warehouse.sensor_job', '', true);$m$,
$m$                        FROM warehouse_maintenance.retention_policy WHERE key = 'sensor_reading_changes')),
      'sensor_limit_changes', (SELECT count(*)$m$
], ARRAY[
$m$    GET DIAGNOSTICS affected = ROW_COUNT; result := result || jsonb_build_object('idempotency_keys', affected);
    -- Migration 186 (WH-157): the stretches are brought up to date before any raw reading is deleted (stored alert minutes).
    result := result || jsonb_build_object('sensor_stretches_refreshed',
      (warehouse_maintenance.refresh_sensor_stretches(p_now, NULL, NULL) ->> 'stretches')::bigint);
    rolled := warehouse_maintenance.rollup_sensor_hourly(p_now, true);$m$,
$m$    GET DIAGNOSTICS affected = ROW_COUNT; result := result || jsonb_build_object('sensor_limit_changes', affected);
    DELETE FROM warehouse_security.sensor_stretches s
     WHERE s.ended_at < (SELECT p_now - make_interval(days => days) FROM warehouse_maintenance.retention_policy WHERE key = 'sensor_stretches');
    GET DIAGNOSTICS affected = ROW_COUNT; result := result || jsonb_build_object('sensor_stretches', affected);
    PERFORM set_config('warehouse.sensor_job', '', true);$m$,
$m$                        FROM warehouse_maintenance.retention_policy WHERE key = 'sensor_reading_changes')),
      'sensor_stretches', (SELECT count(*) FROM warehouse_security.sensor_stretches s
        WHERE s.ended_at < (SELECT p_now - make_interval(days => days) FROM warehouse_maintenance.retention_policy WHERE key = 'sensor_stretches')),
      'sensor_limit_changes', (SELECT count(*)$m$
]);

DROP FUNCTION pg_temp.patch_function(regprocedure, text[], text[]);
