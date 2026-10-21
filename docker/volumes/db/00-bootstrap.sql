\set ON_ERROR_STOP on
-- First-start bootstrap on the official PostgreSQL image (docker/postgres/Dockerfile). Runs once, as
-- supabase_admin (POSTGRES_USER, the bootstrap superuser), in database postgres, before roles.sql sets
-- the passwords. There is no role named postgres. No passwords here.
--
-- Deliberately absent: ALTER DEFAULT PRIVILEGES (the baseline's own ACLs are written relative to the
-- built-in defaults, so a default here would widen them) and ALTER ROLE ... SET storage.* (Storage
-- gets DB_SUPER_USER and DB_INSTALL_ROLES=false from its service environment).

-- Roles of PostgREST, Storage and the app. The pooler's role, schema and auth lookup are not made here: scripts/pooler.sh on
-- creates them (scripts/configure-pooler.sql), so an installation without the pooler has none of them.
CREATE ROLE anon          NOLOGIN INHERIT   NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS;
CREATE ROLE authenticated NOLOGIN INHERIT   NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS;
CREATE ROLE service_role  NOLOGIN INHERIT   NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION BYPASSRLS;
CREATE ROLE authenticator LOGIN   NOINHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS;
CREATE ROLE supabase_storage_admin LOGIN NOINHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS;
GRANT anon, authenticated, service_role TO authenticator;
GRANT authenticator TO supabase_storage_admin;

ALTER ROLE anon          SET statement_timeout = '3s';
ALTER ROLE authenticated SET statement_timeout = '8s';
ALTER ROLE authenticator SET statement_timeout = '8s';
ALTER ROLE authenticator SET lock_timeout = '8s';
ALTER ROLE supabase_admin SET search_path = "$user", public, auth, extensions;
ALTER ROLE supabase_admin SET log_statement = 'none';
ALTER ROLE supabase_storage_admin SET search_path = storage;
ALTER ROLE supabase_storage_admin SET log_statement = 'none';

-- Schemas the migrations and Storage expect to exist.
CREATE SCHEMA auth;
GRANT USAGE ON SCHEMA auth TO anon, authenticated, service_role;
CREATE SCHEMA extensions;
GRANT USAGE ON SCHEMA extensions TO anon, authenticated, service_role;
-- Owned by Storage's login so its migrator can build everything in it. With DB_INSTALL_ROLES=false
-- Storage skips the grant below, so it is made here.
CREATE SCHEMA storage AUTHORIZATION supabase_storage_admin;
GRANT USAGE ON SCHEMA storage TO anon, authenticated, service_role;
GRANT USAGE ON SCHEMA public TO anon, authenticated, service_role;
