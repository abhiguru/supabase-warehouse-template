-- Migration 93 (TW-BE-004): the pg_net HTTP functions are not executable by anon and authenticated, and
-- neither role (nor PUBLIC, which pg_net itself grants USAGE on net) has USAGE on the schema net. The
-- service roles keep their access, database webhooks (supabase_functions.http_request) still send, and
-- DROP EXTENSION pg_net followed by CREATE EXTENSION pg_net does not bring the grants back.
-- tests/migrations.sh applies docker/volumes/db/webhooks.sql and the publisher image's own pg_net migrations
-- before the migrations, as a database container leaves them, so net exists here; if it does not, this test
-- fails rather than passing on nothing. The functions are SECURITY INVOKER in that state and SECURITY DEFINER
-- after the event trigger has run, and the pg_net request tables are writable by PUBLIC: only the schema and
-- function privileges separate the roles, which is what is checked, and what the calls below prove.
-- Fictional host (hook.example.test). Runs in migrations.sh's disposable, network-disabled database inside a
-- transaction that is rolled back, so nothing is left queued and the extension is left as it was found.
\set ON_ERROR_STOP on
BEGIN;
CREATE FUNCTION pg_temp.pn_assert(ok boolean, label text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF NOT COALESCE(ok, false) THEN RAISE EXCEPTION 'pg_net grants: %', label; END IF; END $$;

-- Everything a role could use to reach net.http_get / net.http_post, checked by name so that a new overload
-- is covered too. Called at the start and again after the extension is dropped and created.
CREATE FUNCTION pg_temp.pn_check(stage text) RETURNS void LANGUAGE plpgsql AS $$
DECLARE
  fn record;
  who text;
BEGIN
  PERFORM pg_temp.pn_assert(to_regnamespace('net') IS NOT NULL, stage || ': the schema net does not exist (webhooks.sql not applied?)');
  FOREACH who IN ARRAY ARRAY['anon', 'authenticated'] LOOP
    PERFORM pg_temp.pn_assert(NOT has_schema_privilege(who, 'net', 'USAGE'), stage || ': ' || who || ' has USAGE on net');
  END LOOP;
  PERFORM pg_temp.pn_assert(NOT EXISTS (
    SELECT 1 FROM pg_namespace n, aclexplode(n.nspacl) a
    WHERE n.nspname = 'net' AND a.grantee = 0 AND a.privilege_type = 'USAGE'), stage || ': PUBLIC has USAGE on net');
  PERFORM pg_temp.pn_assert((SELECT count(*) FROM pg_proc WHERE pronamespace = 'net'::regnamespace AND proname IN ('http_get', 'http_post')) = 2,
    stage || ': expected exactly net.http_get and net.http_post');
  FOR fn IN SELECT p.oid, p.oid::regprocedure AS signature
            FROM pg_proc p WHERE p.pronamespace = 'net'::regnamespace AND p.proname IN ('http_get', 'http_post') LOOP
    FOREACH who IN ARRAY ARRAY['anon', 'authenticated'] LOOP
      PERFORM pg_temp.pn_assert(NOT has_function_privilege(who, fn.oid, 'EXECUTE'), stage || ': ' || who || ' can execute ' || fn.signature);
    END LOOP;
    -- A function with no ACL at all is executable by PUBLIC (the default), so a NULL ACL fails too.
    PERFORM pg_temp.pn_assert((SELECT p.proacl IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM aclexplode(p.proacl) a WHERE a.grantee = 0 AND a.privilege_type = 'EXECUTE')
      FROM pg_proc p WHERE p.oid = fn.oid), stage || ': PUBLIC can execute ' || fn.signature);
    -- Kept: the service roles and the webhook function's owner.
    FOREACH who IN ARRAY ARRAY['service_role', 'postgres', 'supabase_functions_admin'] LOOP
      PERFORM pg_temp.pn_assert(has_function_privilege(who, fn.oid, 'EXECUTE'), stage || ': ' || who || ' lost EXECUTE on ' || fn.signature);
    END LOOP;
  END LOOP;
  FOREACH who IN ARRAY ARRAY['service_role', 'postgres', 'supabase_functions_admin'] LOOP
    PERFORM pg_temp.pn_assert(has_schema_privilege(who, 'net', 'USAGE'), stage || ': ' || who || ' lost USAGE on net');
  END LOOP;
END $$;

-- The answer of a statement run as a role: 'ok' when it ran, or the SQLSTATE it raised.
CREATE FUNCTION pg_temp.pn_as(who text, statement text) RETURNS text LANGUAGE plpgsql AS $$
DECLARE answer text;
BEGIN
  EXECUTE format('SET LOCAL ROLE %I', who);
  BEGIN EXECUTE statement; answer := 'ok';
  EXCEPTION WHEN OTHERS THEN answer := SQLSTATE; END;
  RESET ROLE;
  RETURN answer;
END $$;

-- 1. The state migration 93 leaves.
SELECT pg_temp.pn_check('after the migrations');

-- 2. Calling the functions: anon and authenticated are refused with permission denied (42501) before the
--    function runs; a service role gets a request id back.
SELECT pg_temp.pn_assert(pg_temp.pn_as('anon', $q$SELECT net.http_get('http://hook.example.test/')$q$) = '42501', 'anon can call net.http_get');
SELECT pg_temp.pn_assert(pg_temp.pn_as('anon', $q$SELECT net.http_post('http://hook.example.test/', '{}'::jsonb)$q$) = '42501', 'anon can call net.http_post');
SELECT pg_temp.pn_assert(pg_temp.pn_as('authenticated', $q$SELECT net.http_get('http://hook.example.test/')$q$) = '42501', 'authenticated can call net.http_get');
SELECT pg_temp.pn_assert(pg_temp.pn_as('authenticated', $q$SELECT net.http_post('http://hook.example.test/', '{}'::jsonb)$q$) = '42501', 'authenticated can call net.http_post');
SELECT pg_temp.pn_assert(pg_temp.pn_as('service_role', $q$SELECT net.http_get('http://hook.example.test/')$q$) = 'ok', 'service_role cannot call net.http_get');
SELECT pg_temp.pn_assert(pg_temp.pn_as('service_role', $q$SELECT net.http_post('http://hook.example.test/', '{}'::jsonb)$q$) = 'ok', 'service_role cannot call net.http_post');
-- The other net functions are not reachable by name without USAGE on the schema.
SELECT pg_temp.pn_assert(pg_temp.pn_as('anon', $q$SELECT net.http_delete('http://hook.example.test/')$q$) = '42501', 'anon can reach net.http_delete');
-- The webhook function keeps its grants to anon and authenticated (it is a trigger function and cannot be
-- called directly; docs/CONTAINER_SECURITY.md). It must still refuse a direct call.
SELECT pg_temp.pn_assert(pg_temp.pn_as('anon', 'SELECT supabase_functions.http_request()') = '0A000', 'anon can call supabase_functions.http_request() directly');

-- 3. A database webhook still sends: an insert fires supabase_functions.http_request (SECURITY DEFINER,
--    supabase_functions_admin), which calls net.http_post and records the request in supabase_functions.hooks.
CREATE TEMP TABLE pn_hook_source(id integer);
CREATE TRIGGER pn_hook AFTER INSERT ON pn_hook_source FOR EACH ROW
  EXECUTE FUNCTION supabase_functions.http_request('http://hook.example.test/changed', 'POST', '{"Content-Type":"application/json"}', '{}', '1000');
SELECT count(*) AS hooks_before FROM supabase_functions.hooks \gset
INSERT INTO pn_hook_source VALUES (1);
SELECT pg_temp.pn_assert((SELECT count(*) FROM supabase_functions.hooks) = :hooks_before + 1, 'a database webhook no longer sends');

-- 4. The event trigger function keeps its owner and still exists with its trigger enabled.
SELECT pg_temp.pn_assert(
  (SELECT pg_get_userbyid(proowner) FROM pg_proc WHERE oid = 'extensions.grant_pg_net_access()'::regprocedure) = 'supabase_admin',
  'extensions.grant_pg_net_access() changed owner');
SELECT pg_temp.pn_assert(
  (SELECT evtenabled FROM pg_event_trigger WHERE evtname = 'issue_pg_net_access') = 'O',
  'the event trigger issue_pg_net_access is missing or disabled');

-- 5. The case the event trigger exists for: the extension is created again (a restore, an upgrade, a
--    manual DROP). pg_net grants USAGE on net to PUBLIC when it is created; the trigger takes it back and
--    must not grant anything to anon or authenticated.
DROP EXTENSION pg_net;
SELECT pg_temp.pn_assert(to_regnamespace('net') IS NULL, 'DROP EXTENSION pg_net left the schema net');
CREATE EXTENSION pg_net SCHEMA extensions;
SELECT pg_temp.pn_check('after DROP EXTENSION and CREATE EXTENSION pg_net');
SELECT pg_temp.pn_assert(pg_temp.pn_as('anon', $q$SELECT net.http_get('http://hook.example.test/')$q$) = '42501', 'anon can call net.http_get after CREATE EXTENSION');
SELECT pg_temp.pn_assert(pg_temp.pn_as('authenticated', $q$SELECT net.http_post('http://hook.example.test/', '{}'::jsonb)$q$) = '42501', 'authenticated can call net.http_post after CREATE EXTENSION');
ROLLBACK;
