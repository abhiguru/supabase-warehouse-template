-- Migration 93: pg_net HTTP functions are not executable by anon and authenticated (TW-BE-004, operations
-- review of 2026-10-17).
--
-- The Supabase template's init script (docker/volumes/db/webhooks.sql) made net.http_get and net.http_post
-- SECURITY DEFINER and granted them, and USAGE on the schema net, to anon and authenticated; an event
-- trigger (extensions.grant_pg_net_access, fired by CREATE EXTENSION) granted them again. Any future SQL
-- path as one of those roles would have had an outbound HTTP request primitive from the database host
-- (server-side request forgery). Nothing in this backend calls net.http_*; database webhooks go through
-- supabase_functions.http_request, a SECURITY DEFINER function of supabase_functions_admin.
--
-- 1. Where the schema net exists: revoke EXECUTE on net.http_get and net.http_post, and USAGE on net, from
--    anon and authenticated. pg_net itself grants USAGE on net to PUBLIC (verified on 0.19.5), which would
--    leave both roles the schema through PUBLIC, so PUBLIC loses it too, and loses EXECUTE on the two
--    functions where it still has it. service_role, postgres and supabase_functions_admin keep their grants.
-- 2. Where extensions.grant_pg_net_access() exists (the publisher image ships it, installs or not):
--    replace its body with the one in webhooks.sql minus anon and authenticated, plus the PUBLIC revoke on
--    net, so DROP EXTENSION pg_net followed by CREATE EXTENSION pg_net does not bring the grants back. The
--    owner and the grants of the function are kept (CREATE OR REPLACE) and checked.
-- Where net does not exist (the plain migration-test image before webhooks.sql, an install without pg_net)
-- part 1 does nothing. Idempotent.

DO $net$
DECLARE
  fn record;
  trigger_fn regprocedure := to_regprocedure('extensions.grant_pg_net_access()');
  owner_before oid;
  acl_before aclitem[];
  owner_after oid;
  acl_after aclitem[];
BEGIN
  IF to_regnamespace('net') IS NOT NULL THEN
    REVOKE USAGE ON SCHEMA net FROM PUBLIC, anon, authenticated;
    FOR fn IN
      SELECT p.oid::regprocedure AS signature
      FROM pg_proc p
      WHERE p.pronamespace = to_regnamespace('net') AND p.proname IN ('http_get', 'http_post')
    LOOP
      EXECUTE format('REVOKE EXECUTE ON FUNCTION %s FROM PUBLIC, anon, authenticated', fn.signature);
    END LOOP;
  END IF;

  IF trigger_fn IS NOT NULL THEN
    SELECT proowner, proacl INTO owner_before, acl_before FROM pg_proc WHERE oid = trigger_fn;
    EXECUTE $fn$
CREATE OR REPLACE FUNCTION extensions.grant_pg_net_access()
RETURNS event_trigger
LANGUAGE plpgsql
AS $body$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM pg_event_trigger_ddl_commands() AS ev
    JOIN pg_extension AS ext
    ON ev.objid = ext.oid
    WHERE ext.extname = 'pg_net'
  )
  THEN
    IF NOT EXISTS (
      SELECT 1
      FROM pg_roles
      WHERE rolname = 'supabase_functions_admin'
    )
    THEN
      CREATE USER supabase_functions_admin NOINHERIT CREATEROLE LOGIN NOREPLICATION;
    END IF;
    GRANT USAGE ON SCHEMA net TO supabase_functions_admin, postgres, service_role;
    REVOKE USAGE ON SCHEMA net FROM PUBLIC, anon, authenticated;
    ALTER function net.http_get(url text, params jsonb, headers jsonb, timeout_milliseconds integer) SECURITY DEFINER;
    ALTER function net.http_post(url text, body jsonb, params jsonb, headers jsonb, timeout_milliseconds integer) SECURITY DEFINER;
    ALTER function net.http_get(url text, params jsonb, headers jsonb, timeout_milliseconds integer) SET search_path = net;
    ALTER function net.http_post(url text, body jsonb, params jsonb, headers jsonb, timeout_milliseconds integer) SET search_path = net;
    REVOKE ALL ON FUNCTION net.http_get(url text, params jsonb, headers jsonb, timeout_milliseconds integer) FROM PUBLIC, anon, authenticated;
    REVOKE ALL ON FUNCTION net.http_post(url text, body jsonb, params jsonb, headers jsonb, timeout_milliseconds integer) FROM PUBLIC, anon, authenticated;
    GRANT EXECUTE ON FUNCTION net.http_get(url text, params jsonb, headers jsonb, timeout_milliseconds integer) TO supabase_functions_admin, postgres, service_role;
    GRANT EXECUTE ON FUNCTION net.http_post(url text, body jsonb, params jsonb, headers jsonb, timeout_milliseconds integer) TO supabase_functions_admin, postgres, service_role;
  END IF;
END;
$body$
$fn$;
    SELECT proowner, proacl INTO owner_after, acl_after FROM pg_proc WHERE oid = trigger_fn;
    IF owner_after IS DISTINCT FROM owner_before OR acl_after IS DISTINCT FROM acl_before THEN
      RAISE EXCEPTION 'extensions.grant_pg_net_access() changed owner or grants';
    END IF;
  END IF;
END
$net$;
