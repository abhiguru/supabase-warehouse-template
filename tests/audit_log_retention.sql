-- Migration 123, section 10: audit_log keeps 24 months. run_database_retention creates the monthly partitions of the current month (UTC) and
-- the next 3, moves the rows audit_log_default already holds for such a month into the new partition, drops whole partitions that ended
-- on or before p_now - 730 days and deletes the default partition's rows older than that; the preview reports the same and changes
-- nothing. Fictional data; runs only in migrations.sh's disposable, network-disabled database; every block rolls back.
\set ON_ERROR_STOP on

-- 0. The policy row and the function's answer shape.
BEGIN;
DO $$
DECLARE answer jsonb;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM warehouse_maintenance.retention_policy WHERE key = 'audit_log' AND days = 730) THEN
    RAISE EXCEPTION 'audit_log retention: the policy row audit_log with 730 days (24 months) is missing';
  END IF;
  answer := warehouse_maintenance.run_database_retention('2026-10-21T10:00:00Z', false);
  IF NOT (answer ?& ARRAY['applied', 'as_of', 'rows', 'audit_log'] AND (answer->'rows') ?& ARRAY['consumed_refresh_tokens', 'refresh_sessions',
      'central_token_use', 'otp_verifications', 'otp_rate_limits', 'ip_rate_limits', 'idempotency_keys', 'sensor_readings', 'audit_log']
     AND (answer->'audit_log') ?& ARRAY['partitions_created', 'partitions_dropped', 'default_rows_moved', 'default_rows_deleted']) THEN
    RAISE EXCEPTION 'audit_log retention: the answer lost or lacks a key: %', answer;
  END IF;
  -- The existing partitions end at 2026_12: today only January 2027 is missing, nothing is old enough to drop.
  IF answer->'audit_log'->'partitions_created' <> '["audit_log_2027_01"]'::jsonb OR answer->'audit_log'->'partitions_dropped' <> '[]'::jsonb THEN
    RAISE EXCEPTION 'audit_log retention: preview of 2026-10-21 is not "create 2027_01, drop nothing": %', answer->'audit_log';
  END IF;
END $$;
ROLLBACK;

-- 1. Creation ahead; a row of a coming month sitting in the default partition is moved; nothing older than 24 months survives.
BEGIN;
CREATE FUNCTION pg_temp.ar_assert(ok boolean, label text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF NOT COALESCE(ok, false) THEN RAISE EXCEPTION 'audit_log retention: %', label; END IF; END $$;
CREATE FUNCTION pg_temp.ar_parts() RETURNS text LANGUAGE sql AS $$
  SELECT string_agg(c.relname::text, ',' ORDER BY c.relname) FROM pg_inherits i JOIN pg_class c ON c.oid = i.inhrelid
  WHERE i.inhparent = 'public.audit_log'::regclass $$;
-- p_now 2029-03-15: cutoff 2027-03-15 (730 days earlier). Every existing partition (2025_12 .. 2026_12) ended before it: all 13 are dropped.
-- Rows in the partitions (3: one in 2025_12, two in 2026_06) are counted; the default partition holds
--   2 rows of 2029-03 and 1 of 2029-04 (partitions about to be created: moved), 1 row of 2025-05 (older than 24 months: deleted),
--   1 row of 2027-06 (inside the window, no partition made for it: stays).
INSERT INTO public.audit_log(id, table_name, action, created_at) VALUES
 ('00000000-0000-4000-8000-0000000000e1', 'ar_test', 'INSERT', '2025-12-10T00:00:00Z'),
 ('00000000-0000-4000-8000-0000000000e2', 'ar_test', 'INSERT', '2026-06-10T00:00:00Z'),
 ('00000000-0000-4000-8000-0000000000e3', 'ar_test', 'INSERT', '2026-06-11T00:00:00Z'),
 ('00000000-0000-4000-8000-0000000000d1', 'ar_test', 'INSERT', '2029-03-02T00:00:00Z'),
 ('00000000-0000-4000-8000-0000000000d2', 'ar_test', 'INSERT', '2029-03-31T23:59:59Z'),
 ('00000000-0000-4000-8000-0000000000d3', 'ar_test', 'INSERT', '2029-04-01T00:00:00Z'),
 ('00000000-0000-4000-8000-0000000000d4', 'ar_test', 'INSERT', '2025-05-05T00:00:00Z'),
 ('00000000-0000-4000-8000-0000000000d5', 'ar_test', 'INSERT', '2027-06-05T00:00:00Z');
SELECT pg_temp.ar_assert((SELECT count(*) = 5 FROM public.audit_log_default WHERE table_name = 'ar_test'), 'fixture: five rows sit in the default partition');
SELECT pg_temp.ar_assert(pg_temp.ar_parts() LIKE 'audit_log_2025_12,audit_log_2026_01,%audit_log_2026_12,audit_log_default', 'fixture: the partitions are 2025_12 to 2026_12 and the default: ' || pg_temp.ar_parts());

-- The preview reports and changes nothing.
SELECT warehouse_maintenance.run_database_retention('2029-03-15T10:00:00Z', false) AS preview \gset
SELECT pg_temp.ar_assert((:'preview'::jsonb->>'applied')::boolean = false
  AND :'preview'::jsonb#>'{audit_log,partitions_created}' = '["audit_log_2029_03","audit_log_2029_04","audit_log_2029_05","audit_log_2029_06"]'::jsonb
  AND jsonb_array_length(:'preview'::jsonb#>'{audit_log,partitions_dropped}') = 13
  AND :'preview'::jsonb#>>'{audit_log,partitions_dropped,0}' = 'audit_log_2025_12' AND :'preview'::jsonb#>>'{audit_log,partitions_dropped,12}' = 'audit_log_2026_12'
  AND (:'preview'::jsonb#>>'{audit_log,default_rows_moved}')::int = 3 AND (:'preview'::jsonb#>>'{audit_log,default_rows_deleted}')::int = 1
  AND (:'preview'::jsonb#>>'{rows,audit_log}')::int = 3 + 1,
 'preview: creates 4, drops 13, moves 3, deletes 1, counts 4 rows: ' || :'preview');
SELECT pg_temp.ar_assert(to_regclass('public.audit_log_2029_03') IS NULL AND to_regclass('public.audit_log_2026_12') IS NOT NULL
  AND (SELECT count(*) = 5 FROM public.audit_log_default WHERE table_name = 'ar_test')
  AND (SELECT count(*) = 4 FROM public.audit_log WHERE table_name = 'ar_test' AND created_at < '2027-01-01'), 'the preview changed nothing');

-- Apply.
SELECT warehouse_maintenance.run_database_retention('2029-03-15T10:00:00Z', true) AS applied \gset
SELECT pg_temp.ar_assert((:'applied'::jsonb->>'applied')::boolean
  AND :'applied'::jsonb#>'{audit_log,partitions_created}' = :'preview'::jsonb#>'{audit_log,partitions_created}'
  AND :'applied'::jsonb#>'{audit_log,partitions_dropped}' = :'preview'::jsonb#>'{audit_log,partitions_dropped}'
  AND (:'applied'::jsonb#>>'{audit_log,default_rows_moved}')::int = 3 AND (:'applied'::jsonb#>>'{audit_log,default_rows_deleted}')::int = 1
  AND (:'applied'::jsonb#>>'{rows,audit_log}')::int = 4, 'apply reports what the preview promised: ' || :'applied');
SELECT pg_temp.ar_assert(pg_temp.ar_parts() = 'audit_log_2029_03,audit_log_2029_04,audit_log_2029_05,audit_log_2029_06,audit_log_default',
  'the partitions are now 2029_03 to 2029_06 and the default: ' || pg_temp.ar_parts());
SELECT pg_temp.ar_assert((SELECT count(*) = 2 FROM public.audit_log_2029_03 WHERE id IN ('00000000-0000-4000-8000-0000000000d1', '00000000-0000-4000-8000-0000000000d2'))
  AND (SELECT count(*) = 1 FROM public.audit_log_2029_04 WHERE id = '00000000-0000-4000-8000-0000000000d3' AND created_at = '2029-04-01T00:00:00Z'),
 'the default rows of March and April 2029 are in their new partitions, unchanged');
SELECT pg_temp.ar_assert((SELECT array_agg(id::text) = ARRAY['00000000-0000-4000-8000-0000000000d5'] FROM public.audit_log_default WHERE table_name = 'ar_test'),
 'the default partition keeps only the 2027-06 row (inside the window): the 2025-05 row was deleted, the others were moved');
SELECT pg_temp.ar_assert((SELECT count(*) = 0 FROM public.audit_log WHERE id IN ('00000000-0000-4000-8000-0000000000e1', '00000000-0000-4000-8000-0000000000e2',
  '00000000-0000-4000-8000-0000000000e3', '00000000-0000-4000-8000-0000000000d4')), 'the rows of the dropped partitions and the old default row are gone');
SELECT pg_temp.ar_assert((SELECT count(*) = 4 FROM public.audit_log WHERE table_name = 'ar_test'), 'four test rows remain (3 moved, 1 in the window)');
-- The new partitions look like the older ones: row security on, service_role may write, an app role has nothing.
SELECT pg_temp.ar_assert((SELECT bool_and(c.relrowsecurity AND has_table_privilege('service_role', c.oid, 'SELECT,INSERT,UPDATE,DELETE')
    AND NOT has_table_privilege('authenticated', c.oid, 'SELECT,INSERT,UPDATE,DELETE') AND NOT has_table_privilege('anon', c.oid, 'SELECT'))
  FROM pg_class c WHERE c.relname IN ('audit_log_2029_03', 'audit_log_2029_04', 'audit_log_2029_05', 'audit_log_2029_06')), 'new partitions: row security, service_role, no app role');
SELECT pg_temp.ar_assert((SELECT bool_and(pg_get_expr(c.relpartbound, c.oid) ~ ('FOR VALUES FROM \(''' || to_char(m, 'YYYY-MM-DD') || ' 00:00:00\+00''\) TO \(''' || to_char(m + interval '1 month', 'YYYY-MM-DD') || ' 00:00:00\+00''\)'))
  FROM unnest(ARRAY['2029-03-01', '2029-04-01', '2029-05-01', '2029-06-01']::timestamp[]) m
  JOIN pg_class c ON c.relname = 'audit_log_' || to_char(m, 'YYYY_MM')), 'each new partition covers exactly its UTC month');
-- A row of the new month goes to its partition, not the default.
INSERT INTO public.audit_log(table_name, action, created_at) VALUES ('ar_test', 'INSERT', '2029-05-20T12:00:00Z');
SELECT pg_temp.ar_assert((SELECT count(*) = 1 FROM public.audit_log_2029_05 WHERE table_name = 'ar_test'), 'a row of May 2029 lands in audit_log_2029_05');
-- A second run changes nothing and reports nothing to do.
SELECT warehouse_maintenance.run_database_retention('2029-03-15T11:00:00Z', true) AS again \gset
SELECT pg_temp.ar_assert(:'again'::jsonb#>'{audit_log}' = '{"partitions_created": [], "partitions_dropped": [], "default_rows_moved": 0, "default_rows_deleted": 0}'::jsonb
  AND (:'again'::jsonb#>>'{rows,audit_log}')::int = 0, 'a second run is a no-op: ' || :'again');
ROLLBACK;

-- 2. Today's database (partitions to 2026_12): the preview of a later day creates what is missing; nothing recent is dropped; the month is UTC,
-- whatever the session's time zone is.
BEGIN;
CREATE FUNCTION pg_temp.ar_assert(ok boolean, label text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF NOT COALESCE(ok, false) THEN RAISE EXCEPTION 'audit_log retention: %', label; END IF; END $$;
SET LOCAL timezone = 'Asia/Kolkata';
-- 2029-03-31 20:00 UTC is already 1 April in India; the UTC month is March.
SELECT warehouse_maintenance.run_database_retention('2029-03-31T20:00:00Z', false)#>'{audit_log,partitions_created}' AS created_utc \gset
SELECT pg_temp.ar_assert(:'created_utc'::jsonb = '["audit_log_2029_03","audit_log_2029_04","audit_log_2029_05","audit_log_2029_06"]'::jsonb, 'the month is taken in UTC: ' || :'created_utc');
-- The 2026-12 partition ended on 2027-01-01: it is dropped only once p_now is past 2027-01-01 + 730 days = 2028-12-31.
SELECT warehouse_maintenance.run_database_retention('2028-12-30T00:00:00Z', false)#>'{audit_log,partitions_dropped}' AS drop_early \gset
SELECT warehouse_maintenance.run_database_retention('2029-01-01T00:00:00Z', false)#>'{audit_log,partitions_dropped}' AS drop_late \gset
SELECT pg_temp.ar_assert(:'drop_early'::jsonb ? 'audit_log_2026_11' AND NOT (:'drop_early'::jsonb ? 'audit_log_2026_12'), 'on 2028-12-30 2026_12 is kept, 2026_11 is dropped: ' || :'drop_early');
SELECT pg_temp.ar_assert(:'drop_late'::jsonb ? 'audit_log_2026_12', 'on 2029-01-01 2026_12 is dropped: ' || :'drop_late');
ROLLBACK;

-- 3. A row of a coming month in the default partition, today's date: moved into the new partition in the same transaction.
BEGIN;
CREATE FUNCTION pg_temp.ar_assert(ok boolean, label text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF NOT COALESCE(ok, false) THEN RAISE EXCEPTION 'audit_log retention: %', label; END IF; END $$;
INSERT INTO public.audit_log(id, table_name, action, created_at) VALUES ('00000000-0000-4000-8000-0000000000f1', 'ar_test', 'INSERT', '2027-01-05T00:00:00Z');
SELECT pg_temp.ar_assert((SELECT count(*) = 1 FROM public.audit_log_default WHERE id = '00000000-0000-4000-8000-0000000000f1'), 'fixture: the January 2027 row is in the default partition');
SELECT warehouse_maintenance.run_database_retention('2026-10-21T10:00:00Z', true) AS jan \gset
SELECT pg_temp.ar_assert(:'jan'::jsonb#>'{audit_log,partitions_created}' = '["audit_log_2027_01"]'::jsonb AND (:'jan'::jsonb#>>'{audit_log,default_rows_moved}')::int = 1
  AND (SELECT count(*) = 1 FROM public.audit_log_2027_01 WHERE id = '00000000-0000-4000-8000-0000000000f1')
  AND (SELECT count(*) = 0 FROM public.audit_log_default WHERE id = '00000000-0000-4000-8000-0000000000f1'), 'the January 2027 row moved into audit_log_2027_01: ' || :'jan');
ROLLBACK;

-- 4. An operator who removes the audit_log policy row keeps everything: nothing is created, dropped or reported.
BEGIN;
CREATE FUNCTION pg_temp.ar_assert(ok boolean, label text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF NOT COALESCE(ok, false) THEN RAISE EXCEPTION 'audit_log retention: %', label; END IF; END $$;
DELETE FROM warehouse_maintenance.retention_policy WHERE key = 'audit_log';
SELECT warehouse_maintenance.run_database_retention('2029-03-15T10:00:00Z', true) AS no_policy \gset
SELECT pg_temp.ar_assert(NOT (:'no_policy'::jsonb ? 'audit_log') AND NOT ((:'no_policy'::jsonb->'rows') ? 'audit_log') AND to_regclass('public.audit_log_2029_03') IS NULL
  AND to_regclass('public.audit_log_2025_12') IS NOT NULL, 'without the policy row nothing is created or dropped: ' || :'no_policy');
ROLLBACK;

-- 5. Busy table: when the lock on audit_log cannot be had within the timeout, the audit part reports skipped "busy" and changes nothing, while
-- the rest of the run still applies. The harness has one session (no dblink), so the timeout is simulated by replacing the lock helper with
-- one that raises lock_not_available (SQLSTATE 55P03), exactly what LOCK TABLE raises after lock_timeout. The helper's real body is checked by text.
BEGIN;
CREATE FUNCTION pg_temp.ar_assert(ok boolean, label text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF NOT COALESCE(ok, false) THEN RAISE EXCEPTION 'audit_log retention: %', label; END IF; END $$;
SELECT pg_temp.ar_assert((SELECT prosrc ~ 'SET LOCAL lock_timeout = ''5s''' AND prosrc ~ 'LOCK TABLE public\.audit_log IN ACCESS EXCLUSIVE MODE'
  FROM pg_proc WHERE oid = 'warehouse_maintenance.lock_audit_log()'::regprocedure), 'the helper sets a 5s lock_timeout and takes ACCESS EXCLUSIVE on audit_log');
INSERT INTO public.ip_rate_limits(ip_address, updated_at) VALUES ('203.0.113.77', '2020-01-01T00:00:00Z');
INSERT INTO public.audit_log(id, table_name, action, created_at) VALUES ('00000000-0000-4000-8000-0000000000b1', 'ar_test', 'INSERT', '2025-05-10T00:00:00Z');
CREATE OR REPLACE FUNCTION warehouse_maintenance.lock_audit_log() RETURNS void LANGUAGE plpgsql AS $$
BEGIN RAISE EXCEPTION 'canceling statement due to lock timeout' USING ERRCODE = 'lock_not_available'; END $$;
SELECT warehouse_maintenance.run_database_retention('2029-03-15T10:00:00Z', true) AS busy \gset
SELECT pg_temp.ar_assert(:'busy'::jsonb#>'{audit_log}' = '{"skipped": "busy", "partitions_created": [], "partitions_dropped": [], "default_rows_moved": 0, "default_rows_deleted": 0}'::jsonb
  AND (:'busy'::jsonb#>>'{rows,audit_log}')::int = 0, 'busy: the audit part is skipped: ' || :'busy');
SELECT pg_temp.ar_assert(to_regclass('public.audit_log_2029_03') IS NULL AND to_regclass('public.audit_log_2025_12') IS NOT NULL
  AND (SELECT count(*) = 1 FROM public.audit_log_default WHERE id = '00000000-0000-4000-8000-0000000000b1'), 'busy: no partition created or dropped, no default row deleted');
SELECT pg_temp.ar_assert((:'busy'::jsonb#>>'{rows,ip_rate_limits}')::int = 1 AND NOT EXISTS (SELECT 1 FROM public.ip_rate_limits WHERE ip_address = '203.0.113.77'),
  'busy: the rest of the run still applied (the old ip_rate_limits row is gone)');
ROLLBACK;
