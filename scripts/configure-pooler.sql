\set ON_ERROR_STOP on
-- The database objects of the optional pooler (Supavisor). scripts/pooler.sh on runs this, and scripts/db-roles.sh
-- apply runs it on every setup and after both restore paths while the pooler is on (POOLER_ENABLED=true in
-- compose.env). An installation with the pooler off has none of these objects. Idempotent; run in database
-- postgres as supabase_admin. The role's password is set afterwards by configure-db-roles.sql.
-- It is not a migration: roles stay out of migrations (tests/migration-roles.test.mjs).
--   1. role pgbouncer, the pool user (no superuser, no createdb, no createrole, no replication, no bypassrls)
--   2. schema pgbouncer and its auth lookup, which never returns a superuser's verifier
--   3. database _supabase with schema _supavisor: the pooler's own metadata (its tenant is written again at every start,
--      volumes/pooler/pooler.exs), so it is not part of a backup
SELECT NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'pgbouncer') AS make_role \gset
\if :make_role
CREATE ROLE pgbouncer LOGIN INHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS;
\endif

CREATE SCHEMA IF NOT EXISTS pgbouncer AUTHORIZATION pgbouncer;
CREATE OR REPLACE FUNCTION pgbouncer.get_auth(p_usename text) RETURNS TABLE(username text, password text)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog AS $fn$
BEGIN
  RETURN QUERY SELECT usename::text, passwd::text FROM pg_catalog.pg_shadow
  WHERE usename = p_usename AND NOT usesuper;
END $fn$;
REVOKE ALL ON FUNCTION pgbouncer.get_auth(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION pgbouncer.get_auth(text) TO pgbouncer;

SELECT NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = '_supabase') AS make_database \gset
\if :make_database
CREATE DATABASE _supabase WITH OWNER supabase_admin;
\endif
\c _supabase
CREATE SCHEMA IF NOT EXISTS _supavisor AUTHORIZATION supabase_admin;
\c postgres
