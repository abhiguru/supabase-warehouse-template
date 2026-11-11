-- Migration 188 (WH-177, Part A of the offline capture spec): the connection history.
--
-- A phone notes each stretch in which, while the app was open and signed in, it could reach the store's server neither over the
-- internet nor over the store's network, and hands the notes to the server when it can reach it again. Administrators read one row
-- per day for the last 30 days.
--
--  1. warehouse_security.connection_gap_notes: one row per note. A note holds when the stretch began, how long it lasted, the saves
--     tried and answers lost during it, and the device (the user agent of the caller's session, the text "Signed-in devices" describes).
--     No customer, document, amount, address or location. The day of a note is the server's India day at hand-over minus the note's age.
--  2. public.submit_connection_notes(p_notes jsonb): any signed-in account, for its own device. p_notes is an array of at most 500
--     {id uuid (the phone's note id), age_s (seconds since the stretch began, by the phone's monotonic clock), length_s,
--     saves_tried, lost_answers}. Idempotent per (caller, id): a note handed over again adds nothing. Answers
--     {success:true, data:{done:[ids]}}: every id the server holds or has refused as malformed, so the phone drops them all.
--     A note with length_s = 0 is a save that ended as an offline failure with no gap open: it counts as a save tried, not as a gap.
--  3. public.get_connection_history(): administrators only. {success:true, data:{days:[{day 'YYYY-MM-DD', gaps, longest_s, total_s,
--     phones, saves_tried, lost_answers}]}}: 30 rows, today first, a day without notes has zeros. phones = distinct people-and-devices
--     with a gap (length_s > 0) that day.
--  4. retention_policy 'connection_gap_notes': 90 days, applied by run_database_retention (marker-count patch on migration 186's text).
--
-- No role is created, altered or dropped. authorize_rpc is changed in definitions/00_authorize_rpc.sql.

-- ===== 1. the table =====
CREATE TABLE warehouse_security.connection_gap_notes (
  user_id      uuid NOT NULL,
  note_id      uuid NOT NULL,
  started_at   timestamptz NOT NULL,
  day          date NOT NULL,
  length_s     integer NOT NULL CHECK (length_s BETWEEN 0 AND 2678400),
  saves_tried  integer NOT NULL DEFAULT 0 CHECK (saves_tried BETWEEN 0 AND 1000),
  lost_answers integer NOT NULL DEFAULT 0 CHECK (lost_answers BETWEEN 0 AND 1000),
  device       text CHECK (char_length(device) <= 300),
  received_at  timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, note_id)
);
ALTER TABLE warehouse_security.connection_gap_notes OWNER TO supabase_admin;
ALTER TABLE warehouse_security.connection_gap_notes ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE warehouse_security.connection_gap_notes FROM PUBLIC, anon, authenticated, service_role;
CREATE INDEX connection_gap_notes_day_idx ON warehouse_security.connection_gap_notes (day);
COMMENT ON TABLE warehouse_security.connection_gap_notes IS
  'Stretches in which a phone reached neither the internet path nor the store network path (WH-177, migration 188), handed over by the phone. No customer, document, amount or location. Kept 90 days (retention key connection_gap_notes).';

INSERT INTO warehouse_maintenance.retention_policy(key, days, description)
VALUES ('connection_gap_notes', 90, 'Connection gap notes handed over by phones (times, counts and the device only)')
ON CONFLICT (key) DO NOTHING;

-- ===== 2. the hand-over =====
CREATE FUNCTION public.submit_connection_notes(p_notes jsonb) RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'warehouse_security'
AS $function$
DECLARE
  v_user uuid := auth.uid();
  v_now timestamptz := now();
  v_device text;
  v_note jsonb;
  v_id uuid;
  v_age bigint;
  v_len bigint;
  v_saves bigint;
  v_lost bigint;
  v_done jsonb := '[]'::jsonb;
BEGIN
  PERFORM warehouse_security.authorize_rpc('submit_connection_notes', jsonb_build_object());
  IF v_user IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'Sign in required', 'error_code', 'AUTH_REQUIRED');
  END IF;
  IF p_notes IS NULL OR jsonb_typeof(p_notes) <> 'array' OR jsonb_array_length(p_notes) > 500 THEN
    RETURN jsonb_build_object('success', false, 'error', 'p_notes must be an array of at most 500 notes', 'error_code', 'INVALID_INPUT');
  END IF;
  -- The device is read from the caller's own session, never taken from the phone.
  SELECT left(s.user_agent, 300) INTO v_device
    FROM warehouse_security.refresh_sessions s
   WHERE s.id::text = auth.jwt()->>'session_id' AND s.user_id = v_user;

  FOR v_note IN SELECT value FROM jsonb_array_elements(p_notes) LOOP
    v_id := NULL;
    BEGIN
      IF jsonb_typeof(v_note) <> 'object' THEN CONTINUE; END IF;
      v_id := (v_note->>'id')::uuid;
      v_age := (v_note->>'age_s')::bigint;
      v_len := (v_note->>'length_s')::bigint;
      v_saves := COALESCE((v_note->>'saves_tried')::bigint, 0);
      v_lost := COALESCE((v_note->>'lost_answers')::bigint, 0);
    EXCEPTION WHEN others THEN
      -- Malformed (a bad id or number): a valid id is answered as done so the phone drops it; nothing is stored.
      IF v_id IS NOT NULL THEN v_done := v_done || to_jsonb(v_id::text); END IF;
      CONTINUE;
    END;
    IF v_id IS NULL THEN CONTINUE; END IF;
    IF v_age BETWEEN 0 AND 3456000 AND v_len BETWEEN 0 AND 2678400 AND v_saves BETWEEN 0 AND 1000 AND v_lost BETWEEN 0 AND 1000 THEN
      INSERT INTO warehouse_security.connection_gap_notes(user_id, note_id, started_at, day, length_s, saves_tried, lost_answers, device, received_at)
      VALUES (v_user, v_id, v_now - make_interval(secs => v_age),
              ((v_now - make_interval(secs => v_age)) AT TIME ZONE 'Asia/Kolkata')::date,
              v_len, v_saves, v_lost, v_device, v_now)
      ON CONFLICT (user_id, note_id) DO NOTHING;
    END IF;
    v_done := v_done || to_jsonb(v_id::text);
  END LOOP;
  RETURN jsonb_build_object('success', true, 'data', jsonb_build_object('done', v_done));
END $function$;
ALTER FUNCTION public.submit_connection_notes(jsonb) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION public.submit_connection_notes(jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.submit_connection_notes(jsonb) TO authenticated, service_role;
COMMENT ON FUNCTION public.submit_connection_notes(jsonb) IS 'Migration 188 (WH-177): a phone hands over its connection gap notes; idempotent per note id; the device is the caller''s session user agent.';

-- ===== 3. the administrators'' read =====
CREATE FUNCTION public.get_connection_history() RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'warehouse_security'
AS $function$
DECLARE
  v_today date := (now() AT TIME ZONE 'Asia/Kolkata')::date;
  v_days jsonb;
BEGIN
  PERFORM warehouse_security.authorize_rpc('get_connection_history', jsonb_build_object());
  SELECT jsonb_agg(jsonb_build_object(
           'day', to_char(d.day, 'YYYY-MM-DD'),
           'gaps', COALESCE(n.gaps, 0), 'longest_s', COALESCE(n.longest_s, 0), 'total_s', COALESCE(n.total_s, 0),
           'phones', COALESCE(n.phones, 0), 'saves_tried', COALESCE(n.saves_tried, 0), 'lost_answers', COALESCE(n.lost_answers, 0))
         ORDER BY d.day DESC)
    INTO v_days
    FROM generate_series(0, 29) AS g(i)
    CROSS JOIN LATERAL (SELECT v_today - g.i AS day) d
    LEFT JOIN (
      SELECT c.day,
             count(*) FILTER (WHERE c.length_s > 0) AS gaps,
             COALESCE(max(c.length_s), 0) AS longest_s,
             COALESCE(sum(c.length_s), 0) AS total_s,
             count(DISTINCT (c.user_id::text || '|' || COALESCE(c.device, ''))) FILTER (WHERE c.length_s > 0) AS phones,
             COALESCE(sum(c.saves_tried), 0) AS saves_tried,
             COALESCE(sum(c.lost_answers), 0) AS lost_answers
        FROM warehouse_security.connection_gap_notes c
       WHERE c.day BETWEEN v_today - 29 AND v_today
       GROUP BY c.day
    ) n ON n.day = d.day;
  RETURN jsonb_build_object('success', true, 'data', jsonb_build_object('days', v_days));
END $function$;
ALTER FUNCTION public.get_connection_history() OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION public.get_connection_history() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.get_connection_history() TO authenticated, service_role;
COMMENT ON FUNCTION public.get_connection_history() IS 'Migration 188 (WH-177): 30 per-day rows of the phones'' connection gap notes, today first. Administrators only.';

-- ===== 4. retention =====
-- Written against run_database_retention as migration 186 left it. Marker-count patch.
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
    IF position(p_old[i] IN p_new[i]) = 0 THEN
      RAISE EXCEPTION '%: the replacement of marker % does not keep the marker', p_function, i;
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
$m$    GET DIAGNOSTICS affected = ROW_COUNT; result := result || jsonb_build_object('sensor_stretches', affected);
    PERFORM set_config('warehouse.sensor_job', '', true);$m$,
$m$key = 'sensor_reading_changes')),
      'sensor_stretches', (SELECT count(*) FROM warehouse_security.sensor_stretches s$m$
], ARRAY[
$m$    GET DIAGNOSTICS affected = ROW_COUNT; result := result || jsonb_build_object('sensor_stretches', affected);
    -- Migration 188 (WH-177): connection gap notes past their retention.
    DELETE FROM warehouse_security.connection_gap_notes c
     WHERE c.received_at < (SELECT p_now - make_interval(days => days) FROM warehouse_maintenance.retention_policy WHERE key = 'connection_gap_notes');
    GET DIAGNOSTICS affected = ROW_COUNT; result := result || jsonb_build_object('connection_gap_notes', affected);
    PERFORM set_config('warehouse.sensor_job', '', true);$m$,
$m$key = 'sensor_reading_changes')),
      'connection_gap_notes', (SELECT count(*) FROM warehouse_security.connection_gap_notes c
        WHERE c.received_at < (SELECT p_now - make_interval(days => days) FROM warehouse_maintenance.retention_policy WHERE key = 'connection_gap_notes')),
      'sensor_stretches', (SELECT count(*) FROM warehouse_security.sensor_stretches s$m$
]);

DROP FUNCTION pg_temp.patch_function(regprocedure, text[], text[]);
