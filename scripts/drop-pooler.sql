-- Removes the optional pooler's database objects (get_auth, schema pgbouncer, role pgbouncer, database _supabase). Run in
-- database postgres as supabase_admin by scripts/pooler.sh (off, cleanup) and scripts/db-roles.sh apply (switch off).
-- Plain drops only (nothing is cascaded or forced). It refuses, before changing anything, when
--   - schema pgbouncer holds anything but get_auth,
--   - _supabase holds a relation or a schema besides public and _supavisor,
--   - the database _supabase or the role pgbouncer has a connection.
-- A refusal exits non-zero with the reason on standard error. Nothing is removed that does not exist.
\set ON_ERROR_STOP on
SELECT EXISTS (SELECT 1 FROM pg_database WHERE datname = '_supabase') AS has_db \gset
SELECT count(*) AS other_objects FROM (
  SELECT c.oid FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname = 'pgbouncer'
  UNION ALL
  SELECT p.oid FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'pgbouncer' AND p.proname <> 'get_auth'
) x \gset
SELECT count(*) AS connections FROM pg_stat_activity WHERE datname = '_supabase' OR usename = 'pgbouncer' \gset
SELECT 0 AS db_relations, '-' AS db_schemas \gset
\if :has_db
\c _supabase
SELECT (SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname NOT LIKE 'pg\_%' AND n.nspname <> 'information_schema' AND c.relkind IN ('r','p','v','m','S','f')) AS db_relations,
  COALESCE((SELECT string_agg(nspname, ',' ORDER BY nspname) FROM pg_namespace WHERE nspname NOT LIKE 'pg\_%' AND nspname NOT IN ('information_schema','public','_supavisor')), '-') AS db_schemas \gset
\c postgres
\endif
SELECT (:other_objects > 0 OR :connections > 0 OR :db_relations > 0 OR :'db_schemas' <> '-') AS refuse \gset
\if :refuse
\warn Pooler objects not removed, nothing was changed: schema pgbouncer holds :other_objects object(s) besides get_auth, _supabase holds :db_relations relation(s) and the schema(s) :db_schemas, and :connections connection(s) are open to _supabase or as pgbouncer (a "-" means none).
DO $refuse$ BEGIN RAISE EXCEPTION 'pooler objects are in use'; END $refuse$;
\endif
BEGIN;
DROP FUNCTION IF EXISTS pgbouncer.get_auth(text);
DROP SCHEMA IF EXISTS pgbouncer;
DROP ROLE IF EXISTS pgbouncer;
COMMIT;
DROP DATABASE IF EXISTS _supabase;
