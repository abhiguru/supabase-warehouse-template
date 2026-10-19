-- Migration 105: Supabase Realtime is removed, and the database stops preparing changes for it.
--
-- Why, in plain English. Realtime pushed order changes and sensor readings to the app over a websocket. The owner
-- decided that the app re-reads those screens on a timer instead (order screens every 15 seconds, sensor screens
-- every 60 seconds), and the app no longer opens the socket. The Realtime service, its key, its gateway route and
-- its start-up warm-up are removed from the stack in the same release. This migration removes what Realtime left in the database.
--
-- What changes, in this order (every step is skipped where the object is already gone, so the migration runs on a
-- new install, on an existing one, after a restore of an older backup, and again):
--  1. Before anything is changed, the migration STOPS, and changes nothing, if any object OUTSIDE the schemas realtime
--     and _realtime depends on an object inside them (a view, function default, trigger or foreign key of your own):
--     nothing in this repository does, and the check is there so that CASCADE (step 5) can only remove Realtime's own
--     objects. An object counts as inside when its own schema, or the schema of the table it belongs to, is realtime
--     or _realtime. The check runs first because dropping a replication slot cannot be rolled back.
--  2. Both publications are dropped: supabase_realtime (it held public.orders and public.sensor_latest, added by
--     migrations 14 and 74) and supabase_realtime_messages_publication (created by the Realtime service for the
--     partitions of realtime.messages). Nothing else reads them.
--  3. public.orders and public.sensor_latest return to REPLICA IDENTITY DEFAULT. FULL made every update and delete
--     write the whole old row to the WAL, for Realtime only. The step waits at most 30 seconds for its table lock
--     (lock_timeout), so it cannot hold up the app's reads of orders for long; the migration then fails and can be rerun.
--  4. Leftover logical replication slots named supabase_realtime* or realtime* are dropped when they are idle. This is
--     only a guard: PostgreSQL 15 refuses to start the db with wal_level=replica while ANY logical slot exists, so
--     setup.sh and start.sh run scripts/drop-logical-slots.sh while the db still runs with its old settings, before
--     it is recreated. A slot that is in use is kept here with a notice.
--  5. The schemas realtime and _realtime are dropped with CASCADE. CASCADE is used because the schemas hold tables,
--     indexes, a sequence, types and functions that the Realtime service created and no migration of this
--     repository knows.
--     On the development facility checked on 2026-10-19 the schemas held: realtime, 10 tables (the messages
--     partition parent, 7 daily partitions, subscription and schema_migrations), 20 indexes, 1 sequence, 3
--     composite types, 2 other types and 18 functions, with no rows in messages or subscription; _realtime, 4
--     tables and 8 indexes, with the single tenant row realtime-dev. Both were owned by supabase_admin.
--  6. Roles are NOT dropped. supabase_realtime_admin is created by the database image, not by this repository,
--     and holds grants on the schema that goes with the schema; the image's role stays for a later cleanup.
--     (This repository created no Realtime-only role.)
-- The database parameter wal_level goes from logical to replica in docker/docker-compose.override.yml; that needs
-- a restart of the db service. setup.sh restarts the db first (after dropping idle logical slots), then applies this
-- migration.
--
-- A backup made before this migration holds the objects above. They restore cleanly onto a current install (the
-- database is recreated from template0, the roles come from roles.txt, and nothing in the dump needs the Realtime
-- service), and this migration removes them right after the restore.
--
-- A self-check at the end fails the migration if a publication, a REPLICA IDENTITY other than DEFAULT on the two
-- tables, or either schema remains. A slot is not part of it: one that is in use is only reported (step 4).

DO $$
DECLARE
  inside oid[] := array_remove(ARRAY[to_regnamespace('realtime')::oid, to_regnamespace('_realtime')::oid], NULL);
  dependent text;
  slot record;
  table_name regclass;
BEGIN
  PERFORM set_config('lock_timeout', '30s', true);

  -- 1. Refuse first, before anything is dropped.
  IF cardinality(inside) > 0 THEN
    SELECT string_agg(DISTINCT pg_describe_object(d.classid, d.objid, d.objsubid), '; ') INTO dependent
    FROM pg_depend d
    WHERE d.deptype IN ('n', 'a')
      AND ((d.refclassid = 'pg_class'::regclass AND d.refobjid IN (SELECT oid FROM pg_class WHERE relnamespace = ANY (inside)))
        OR (d.refclassid = 'pg_proc'::regclass AND d.refobjid IN (SELECT oid FROM pg_proc WHERE pronamespace = ANY (inside)))
        OR (d.refclassid = 'pg_type'::regclass AND d.refobjid IN (SELECT oid FROM pg_type WHERE typnamespace = ANY (inside))))
      AND NOT coalesce(CASE d.classid
        WHEN 'pg_class'::regclass THEN (SELECT x.relnamespace = ANY (inside) FROM pg_class x WHERE x.oid = d.objid)
        WHEN 'pg_proc'::regclass THEN (SELECT x.pronamespace = ANY (inside) FROM pg_proc x WHERE x.oid = d.objid)
        WHEN 'pg_type'::regclass THEN (SELECT x.typnamespace = ANY (inside) FROM pg_type x WHERE x.oid = d.objid)
        WHEN 'pg_statistic_ext'::regclass THEN (SELECT x.stxnamespace = ANY (inside) FROM pg_statistic_ext x WHERE x.oid = d.objid)
        WHEN 'pg_attrdef'::regclass THEN (SELECT c.relnamespace = ANY (inside) FROM pg_attrdef x JOIN pg_class c ON c.oid = x.adrelid WHERE x.oid = d.objid)
        WHEN 'pg_trigger'::regclass THEN (SELECT c.relnamespace = ANY (inside) FROM pg_trigger x JOIN pg_class c ON c.oid = x.tgrelid WHERE x.oid = d.objid)
        WHEN 'pg_rewrite'::regclass THEN (SELECT c.relnamespace = ANY (inside) FROM pg_rewrite x JOIN pg_class c ON c.oid = x.ev_class WHERE x.oid = d.objid)
        WHEN 'pg_policy'::regclass THEN (SELECT c.relnamespace = ANY (inside) FROM pg_policy x JOIN pg_class c ON c.oid = x.polrelid WHERE x.oid = d.objid)
        WHEN 'pg_constraint'::regclass THEN (SELECT coalesce(c.relnamespace, x.connamespace) = ANY (inside) FROM pg_constraint x LEFT JOIN pg_class c ON c.oid = x.conrelid WHERE x.oid = d.objid)
        -- A table's membership of a publication; step 2 drops the two Realtime publications.
        WHEN 'pg_publication_rel'::regclass THEN (SELECT p.pubname IN ('supabase_realtime', 'supabase_realtime_messages_publication') FROM pg_publication_rel x JOIN pg_publication p ON p.oid = x.prpubid WHERE x.oid = d.objid)
      END, false);
    IF dependent IS NOT NULL THEN
      RAISE EXCEPTION 'An object outside the schemas realtime and _realtime depends on an object inside them, so they are not dropped: %. Remove that dependency, then run setup again.', left(dependent, 500);
    END IF;
  END IF;

  -- 2. Publications.
  DROP PUBLICATION IF EXISTS supabase_realtime;
  DROP PUBLICATION IF EXISTS supabase_realtime_messages_publication;

  -- 3. REPLICA IDENTITY.
  FOREACH table_name IN ARRAY ARRAY[to_regclass('public.orders'), to_regclass('public.sensor_latest')] LOOP
    IF table_name IS NOT NULL THEN
      EXECUTE format('ALTER TABLE %s REPLICA IDENTITY DEFAULT', table_name);
    END IF;
  END LOOP;

  -- 4. Idle logical slots of Realtime (a guard; see the header).
  FOR slot IN
    SELECT slot_name, active FROM pg_replication_slots
    WHERE slot_type = 'logical' AND database = current_database()
      AND (slot_name LIKE 'supabase\_realtime%' OR slot_name LIKE 'realtime%')
  LOOP
    IF slot.active THEN
      RAISE NOTICE 'The replication slot % is in use and is kept; stop the old Realtime container and drop it with pg_drop_replication_slot.', slot.slot_name;
    ELSE
      PERFORM pg_drop_replication_slot(slot.slot_name);
    END IF;
  END LOOP;

  -- 5. The schemas.
  DROP SCHEMA IF EXISTS realtime CASCADE;
  DROP SCHEMA IF EXISTS _realtime CASCADE;

  -- Self-check.
  IF EXISTS (SELECT 1 FROM pg_publication WHERE pubname IN ('supabase_realtime', 'supabase_realtime_messages_publication')) THEN
    RAISE EXCEPTION 'Migration 105 self-check: a Realtime publication remains';
  END IF;
  IF EXISTS (SELECT 1 FROM pg_class WHERE oid IN (to_regclass('public.orders'), to_regclass('public.sensor_latest')) AND relreplident <> 'd') THEN
    RAISE EXCEPTION 'Migration 105 self-check: orders or sensor_latest is not REPLICA IDENTITY DEFAULT';
  END IF;
  IF to_regnamespace('realtime') IS NOT NULL OR to_regnamespace('_realtime') IS NOT NULL THEN
    RAISE EXCEPTION 'Migration 105 self-check: the schema realtime or _realtime remains';
  END IF;
END
$$;
