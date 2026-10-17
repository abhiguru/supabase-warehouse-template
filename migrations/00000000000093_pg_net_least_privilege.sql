-- Migration 93: pg_net is for the service roles only; anon and authenticated lose it (TW-BE-004, operations
-- review of 2026-10-17).
--
-- The Supabase template's init script (docker/volumes/db/webhooks.sql), the publisher image's own migrations
-- (20220713082019 and 20250220051611, which run after it at the first start) and an event trigger
-- (extensions.grant_pg_net_access, fired by CREATE EXTENSION) give USAGE on the schema net and EXECUTE on
-- net.http_get / net.http_post to anon and authenticated, and pg_net itself gives USAGE on net and ALL on its
-- request tables (net.http_request_queue, net._http_response) to PUBLIC. On an installed database the two
-- functions are SECURITY INVOKER and executable by PUBLIC, so any future SQL path as anon or authenticated
-- would have had an outbound HTTP request primitive from the database host (server-side request forgery): the
-- function, or a plain INSERT into the queue table. Nothing in this backend calls net.http_*; database webhooks
-- go through supabase_functions.http_request, a SECURITY DEFINER function of supabase_functions_admin.
--
-- 1. Where the schema net exists: PUBLIC, anon and authenticated lose USAGE on net (without it none of the
--    objects in net can be named, the request tables included) and EXECUTE on net.http_get and
--    net.http_post. Revoking only from anon and authenticated would change nothing, because PUBLIC holds both.
--    Then the three roles that need pg_net get what they need explicitly, since until now they had it
--    through PUBLIC: supabase_functions_admin (the owner of the webhook function), postgres and service_role
--    get USAGE on net and EXECUTE on the two functions. Roles that do not exist are skipped.
--    net.http_delete and net.http_collect_response keep pg_net's own PUBLIC EXECUTE; they are not reachable
--    without USAGE on net.
-- 2. Where extensions.grant_pg_net_access() exists (the publisher image ships it, installed or not): replace
--    its body with the one in webhooks.sql minus anon and authenticated, plus the PUBLIC revoke on net, so
--    DROP EXTENSION pg_net followed by CREATE EXTENSION pg_net does not bring the grants back. The owner and
--    the grants of the function are kept (CREATE OR REPLACE) and checked.
-- 3. Where supabase_functions.http_request() exists: EXECUTE is revoked from PUBLIC, anon and authenticated.
-- Where net does not exist (the plain migration-test image before webhooks.sql, an install without pg_net)
-- part 1 does nothing. Idempotent.

DO $net$
DECLARE
  fn record;
  keeper record;
  trigger_fn regprocedure := to_regprocedure('extensions.grant_pg_net_access()');
  owner_before oid;
  acl_before aclitem[];
  owner_after oid;
  acl_after aclitem[];
BEGIN
  IF to_regnamespace('net') IS NOT NULL THEN
    REVOKE USAGE ON SCHEMA net FROM PUBLIC, anon, authenticated;
    FOR keeper IN SELECT name FROM unnest(ARRAY['supabase_functions_admin', 'postgres', 'service_role']) AS name WHERE to_regrole(name) IS NOT NULL LOOP
      EXECUTE format('GRANT USAGE ON SCHEMA net TO %I', keeper.name);
    END LOOP;
    FOR fn IN
      SELECT p.oid::regprocedure AS signature
      FROM pg_proc p
      WHERE p.pronamespace = to_regnamespace('net') AND p.proname IN ('http_get', 'http_post')
    LOOP
      EXECUTE format('REVOKE EXECUTE ON FUNCTION %s FROM PUBLIC, anon, authenticated', fn.signature);
      FOR keeper IN SELECT name FROM unnest(ARRAY['supabase_functions_admin', 'postgres', 'service_role']) AS name WHERE to_regrole(name) IS NOT NULL LOOP
        EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO %I', fn.signature, keeper.name);
      END LOOP;
    END LOOP;
  END IF;

  -- The webhook trigger function is SECURITY DEFINER with the right to call net.http_post, and takes the
  -- destination from the arguments of whoever creates the trigger (EXECUTE on a trigger function is checked
  -- when the trigger is created, and PUBLIC may create temporary tables). Anon and authenticated could have
  -- authored a request. Webhooks made by postgres (Studio) keep working: the function runs as its owner.
  IF to_regprocedure('supabase_functions.http_request()') IS NOT NULL THEN
    REVOKE EXECUTE ON FUNCTION supabase_functions.http_request() FROM PUBLIC, anon, authenticated;
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
