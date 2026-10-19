-- Migration 105: Realtime is gone from the database. Runs after all migrations in migrations.sh's disposable,
-- network-disabled database; it writes nothing.
\set ON_ERROR_STOP on
BEGIN;
CREATE FUNCTION pg_temp.rt_assert(ok boolean, label text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF NOT COALESCE(ok, false) THEN RAISE EXCEPTION 'realtime removed: %', label; END IF; END $$;

SELECT pg_temp.rt_assert(NOT EXISTS (SELECT 1 FROM pg_publication), 'a publication remains: ' || coalesce((SELECT string_agg(pubname, ', ') FROM pg_publication), ''));
SELECT pg_temp.rt_assert((SELECT count(*) = 2 AND bool_and(relreplident = 'd') FROM pg_class
  WHERE oid IN ('public.orders'::regclass, 'public.sensor_latest'::regclass)), 'orders and sensor_latest are REPLICA IDENTITY DEFAULT');
SELECT pg_temp.rt_assert(NOT EXISTS (SELECT 1 FROM pg_class WHERE relreplident = 'f' AND relnamespace = 'public'::regnamespace), 'a public table is still REPLICA IDENTITY FULL');
SELECT pg_temp.rt_assert(to_regnamespace('realtime') IS NULL AND to_regnamespace('_realtime') IS NULL, 'the schema realtime or _realtime remains');
SELECT pg_temp.rt_assert(NOT EXISTS (SELECT 1 FROM pg_replication_slots WHERE slot_name LIKE 'supabase\_realtime%' OR slot_name LIKE 'realtime%'), 'a Realtime replication slot remains');
SELECT pg_temp.rt_assert(EXISTS (SELECT 1 FROM warehouse_migrations.applied WHERE name = '00000000000000_baseline.sql'), 'the ledger does not hold the baseline');
-- The tables still work for the app: the policies and grants of migrations 14 and 74 are untouched.
SELECT pg_temp.rt_assert(EXISTS (SELECT 1 FROM pg_policy WHERE polrelid = 'public.sensor_latest'::regclass AND polname = 'starter_staff'), 'the sensor_latest policy remains');
ROLLBACK;
