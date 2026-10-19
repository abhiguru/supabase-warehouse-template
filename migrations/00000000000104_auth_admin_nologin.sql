-- Migration 104: the database login supabase_auth_admin can no longer sign in, and no table points at GoTrue's users.
--
-- Why, in plain English. The Supabase image creates supabase_auth_admin for GoTrue, its login service, and this
-- repository once carried a disabled copy of that service. It never ran: sessions here come from SQL
-- (warehouse_security.issue_session, public.refresh_jwt_token, public.check_session), reached through the Edge
-- Functions operator-otp and central-exchange. The service and its source recipe are now removed, so nothing signs
-- in as this role. A login nobody uses is a way in for anyone who learns its password, and setup used to generate,
-- store and rotate one (DB_PASSWORD_AUTH) just for it.
--
-- What this does. The role is kept, not dropped: it owns auth.uid(), auth.role(), auth.email() and 26 other auth
-- relations, and holds default privileges in schema auth. (The auth schema and auth.jwt() belong to supabase_admin.)
-- The row policies use the auth functions. The role only loses its login and its password.
-- Where the role does not exist (a database that never had the image's role) nothing happens. Running it again
-- changes nothing. scripts/configure-db-roles.sql repeats the same statement on every setup run. That matters after
-- a restore: a backup holds only role names, every restore starts a fresh cluster where the image creates the role
-- with LOGIN, and the restored ledger skips 104, so db-roles.sh apply (called from restore.sh) is what corrects it.
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'supabase_auth_admin') THEN
    ALTER ROLE supabase_auth_admin WITH NOLOGIN PASSWORD NULL;
  END IF;
END
$$;

-- Foreign keys to GoTrue's tables. Columns such as secrets_vault.created_by, bank_statements.uploaded_by and
-- bank_statement_lines.confirmed_by were declared as REFERENCES auth.users(id), a table that only the image's GoTrue tables
-- provided; the image's own Storage tables carry two more (storage.buckets.owner, storage.objects.owner). The official
-- Postgres image has no auth.users, and GoTrue is gone, so the constraints would stop a fresh database from being built.
-- auth.users holds 0 rows on every facility, so those columns are NULL and the constraints protect nothing; the columns stay.
-- Every foreign key whose referenced table is in schema auth and whose own table is not, is dropped, found in the catalog.
-- Where schema auth has no such reference nothing happens, and a second run finds nothing to drop. A check at the end
-- stops the migration if one is left.
DO $$
DECLARE
  c record;
BEGIN
  FOR c IN
    SELECT n.nspname, r.relname, k.conname
      FROM pg_constraint k
      JOIN pg_class r ON r.oid = k.conrelid
      JOIN pg_namespace n ON n.oid = r.relnamespace
      JOIN pg_class t ON t.oid = k.confrelid
     WHERE k.contype = 'f' AND t.relnamespace = 'auth'::regnamespace AND n.nspname <> 'auth'
     ORDER BY n.nspname, r.relname, k.conname
  LOOP
    EXECUTE format('ALTER TABLE %I.%I DROP CONSTRAINT %I', c.nspname, c.relname, c.conname);
    RAISE NOTICE 'migration 104: dropped foreign key % on %.% (it pointed into schema auth)', c.conname, c.nspname, c.relname;
  END LOOP;
  IF EXISTS (SELECT 1 FROM pg_constraint k JOIN pg_class r ON r.oid = k.conrelid JOIN pg_class t ON t.oid = k.confrelid
              WHERE k.contype = 'f' AND t.relnamespace = 'auth'::regnamespace AND r.relnamespace <> 'auth'::regnamespace) THEN
    RAISE EXCEPTION 'migration 104: a foreign key into schema auth is still there';
  END IF;
END
$$;
