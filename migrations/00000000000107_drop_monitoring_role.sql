-- Migration 107: the database login warehouse_monitoring is dropped.
--
-- Why, in plain English. Migration 94 gave the Postgres exporter a login of its own, warehouse_monitoring, so that
-- monitoring no longer used the superuser password. The exporter is gone: the one monitoring check of an installation
-- (scripts/watch.mjs) reads the database through the superuser connection the backup scripts already use, and nothing
-- signs in as this role. A login nobody uses is a way in for anyone who learns its password, and setup used to
-- generate, store and rotate one (DB_PASSWORD_MONITORING) just for it.
--
-- What this does. The role is removed: its pg_monitor membership is revoked, whatever it was granted in this database
-- is revoked (DROP OWNED), and the role is dropped. Migration 94 stays unchanged as history (applied migrations are
-- checksum-locked). It is safe to drop: migration 94 created the role with no grant and no object, and
-- tests/security_baseline.sql used to prove it held nothing and owned nothing. Nothing else creates grants for it
-- (the init scripts under docker/volumes/db name no such role), so the repository never gave the role an entry that would
-- make DROP ROLE fail. DROP OWNED BY removes the entries of this database; an entry in another database of the cluster
-- (only an operator could have made one) stops the drop with a hint. Where the role does not exist
-- (a database that never ran migration 94, or one that ran this migration) nothing happens, so running it again changes
-- nothing. scripts/configure-db-roles.sql repeats the same drop on every setup run, which matters after a restore: the
-- restored ledger skips 107, and a backup made before this migration may bring the role back.
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'warehouse_monitoring') THEN
    IF EXISTS (SELECT 1 FROM pg_auth_members m JOIN pg_roles g ON g.oid = m.roleid JOIN pg_roles r ON r.oid = m.member
               WHERE r.rolname = 'warehouse_monitoring' AND g.rolname = 'pg_monitor') THEN
      REVOKE pg_monitor FROM warehouse_monitoring;
    END IF;
    DROP OWNED BY warehouse_monitoring;
    BEGIN
      DROP ROLE warehouse_monitoring;
    EXCEPTION WHEN dependent_objects_still_exist THEN
      RAISE EXCEPTION 'migration 107: warehouse_monitoring still has grants or objects: %', SQLERRM
        USING HINT = 'run DROP OWNED BY warehouse_monitoring in that database, then run the migration again';
    END;
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'warehouse_monitoring') THEN
      RAISE EXCEPTION 'migration 107: warehouse_monitoring still exists';
    END IF;
  END IF;
END
$$;
