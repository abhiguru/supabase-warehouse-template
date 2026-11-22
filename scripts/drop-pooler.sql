-- Removes the optional pooler's database objects (get_auth, schema pgbouncer, role pgbouncer, database _supabase). Run in
-- database postgres as supabase_admin by scripts/pooler.sh (off, cleanup) and scripts/db-roles.sh apply (switch off).
-- Plain drops only (nothing is cascaded or forced). It refuses, before changing anything, when
--   - schema pgbouncer holds anything but get_auth,
--   - _supabase holds a schema besides public and _supavisor, or a relation that is not one of Supavisor's own tables,
--   - the database _supabase or the role pgbouncer has a connection,
--   - _supabase holds Supavisor's own tables and the psql variable drop_supavisor_metadata is not set.
-- Supavisor's own tables are the five its migrations create at every start (/app/bin/migrate) once the pooler has run:
-- _supavisor.tenants, users, clusters, cluster_tenants and schema_migrations. They hold its tenant and pool user (the
-- password encrypted with VAULT_ENC_KEY), which volumes/pooler/pooler.exs writes again at every start; they are not
-- in backups. Only `bash scripts/pooler.sh off --drop-metadata` sets the variable, after saving a dump of _supabase.
-- A refusal exits non-zero with the reason on standard error. Nothing is removed that does not exist.
-- With the psql variable check_only set it only runs the refusal checks and stops before the first DROP (pooler.sh off
-- runs it so before it stops supavisor); with ignore_connections also set it leaves connections out, because a running
-- supavisor is itself connected. The full run after the stop checks them again.
\set ON_ERROR_STOP on
SELECT EXISTS (SELECT 1 FROM pg_database WHERE datname = '_supabase') AS has_db \gset
SELECT count(*) AS other_objects FROM (
  SELECT c.oid FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname = 'pgbouncer'
  UNION ALL
  SELECT p.oid FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'pgbouncer' AND p.proname <> 'get_auth'
) x \gset
SELECT count(*) AS connections FROM pg_stat_activity WHERE datname = '_supabase' OR usename = 'pgbouncer' \gset
\if :{?ignore_connections}
SELECT 0 AS connections \gset
\endif
SELECT 0 AS db_relations, 0 AS supavisor_relations, '-' AS db_schemas \gset
\if :has_db
\c _supabase
SELECT count(*) FILTER (WHERE NOT supavisor) AS db_relations, count(*) FILTER (WHERE supavisor) AS supavisor_relations FROM (
  SELECT (n.nspname = '_supavisor' AND c.relkind = 'r' AND c.relname IN ('tenants','users','clusters','cluster_tenants','schema_migrations')) AS supavisor
  FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname NOT LIKE 'pg\_%' AND n.nspname <> 'information_schema' AND c.relkind IN ('r','p','v','m','S','f')
) r \gset
SELECT COALESCE((SELECT string_agg(nspname, ',' ORDER BY nspname) FROM pg_namespace WHERE nspname NOT LIKE 'pg\_%' AND nspname NOT IN ('information_schema','public','_supavisor')), '-') AS db_schemas \gset
\c postgres
\endif
SELECT (:other_objects > 0 OR :connections > 0 OR :db_relations > 0 OR :'db_schemas' <> '-') AS refuse \gset
\if :refuse
\if :{?ignore_connections}
\warn Pooler objects not removed, nothing was changed: schema pgbouncer holds :other_objects object(s) besides get_auth, and _supabase holds :db_relations relation(s) besides the tables of Supavisor and the schema(s) :db_schemas (a "-" means none).
\else
\warn Pooler objects not removed, nothing was changed: schema pgbouncer holds :other_objects object(s) besides get_auth, _supabase holds :db_relations relation(s) besides the tables of Supavisor and the schema(s) :db_schemas, and :connections connection(s) are open to _supabase or as pgbouncer (a "-" means none).
\endif
DO $refuse$ BEGIN RAISE EXCEPTION 'pooler objects are in use'; END $refuse$;
\endif
SELECT (:supavisor_relations > 0 AND NOT :{?drop_supavisor_metadata}) AS keep_metadata \gset
\if :keep_metadata
\warn Pooler objects not removed, nothing was changed: the pooler has been used, so _supabase holds :supavisor_relations table(s) of Supavisor (its tenant and pool user, written again at every start). To switch the pooler off and remove them, run: bash scripts/pooler.sh off --drop-metadata (it saves a dump of _supabase first). To keep using it, run: bash scripts/pooler.sh on
DO $refuse$ BEGIN RAISE EXCEPTION 'pooler metadata kept'; END $refuse$;
\endif
\if :{?check_only}
\quit
\endif
BEGIN;
DROP FUNCTION IF EXISTS pgbouncer.get_auth(text);
DROP SCHEMA IF EXISTS pgbouncer;
DROP ROLE IF EXISTS pgbouncer;
COMMIT;
DROP DATABASE IF EXISTS _supabase;
