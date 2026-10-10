\set ON_ERROR_STOP on

DO $$
DECLARE
  bad_policies text;
  bad_grants text;
  rls_disabled text;
  unpinned_callable text;
  unpinned_total integer;
  rls_without_policy text;
  private_reachable text;
BEGIN
  SELECT string_agg(format('%I.%I (%I)', schemaname, tablename, policyname), ', ')
    INTO bad_policies
  FROM pg_policies
  WHERE schemaname = 'public'
    AND tablename IN ('goodsreceived', 'payments', 'user_profiles')
    AND roles && ARRAY['public', 'anon', 'authenticated']::name[]
    AND (qual = 'true' OR with_check = 'true');

  IF bad_policies IS NOT NULL THEN
    RAISE EXCEPTION 'Unrestricted policy on a sensitive table: %', bad_policies;
  END IF;

  SELECT string_agg(format('%I.%I %s', table_schema, table_name, privilege_type), ', ')
    INTO bad_grants
  FROM information_schema.role_table_grants
  WHERE grantee = 'anon'
    AND table_schema = 'public'
    AND NOT (
      privilege_type = 'SELECT'
      AND table_name IN ('feature_flags', 'printer_status')
    );

  IF bad_grants IS NOT NULL THEN
    RAISE EXCEPTION 'Unexpected anonymous table grant: %', bad_grants;
  END IF;

  SELECT string_agg(format('%I.%I', n.nspname, c.relname), ', ')
    INTO rls_disabled
  FROM pg_class c
  JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = 'public'
    AND c.relkind = 'r'
    AND NOT c.relrowsecurity
    AND EXISTS (
      SELECT 1
      FROM information_schema.role_table_grants g
      WHERE g.table_schema = n.nspname
        AND g.table_name = c.relname
        AND g.grantee IN ('anon', 'authenticated')
    );

  IF rls_disabled IS NOT NULL THEN
    RAISE EXCEPTION 'RLS is disabled on an exposed table: %', rls_disabled;
  END IF;

  -- A SECURITY DEFINER function runs with its owner's rights; without a pinned
  -- search_path the caller chooses which objects its unqualified names reach.
  SELECT string_agg(p.oid::regprocedure::text, ', ')
    INTO unpinned_callable
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE p.prosecdef
    AND n.nspname IN ('public', 'warehouse_security', 'warehouse_maintenance')
    AND NOT EXISTS (SELECT 1 FROM unnest(COALESCE(p.proconfig, '{}')) c WHERE c LIKE 'search_path=%')
    AND (has_function_privilege('anon', p.oid, 'EXECUTE') OR has_function_privilege('authenticated', p.oid, 'EXECUTE'));

  IF unpinned_callable IS NOT NULL THEN
    RAISE EXCEPTION 'SECURITY DEFINER function callable by an app role has no search_path: %', unpinned_callable;
  END IF;

  -- The baseline schema carries 48 such helpers that no app role can call.
  -- The number may only go down: a new function must SET search_path.
  SELECT count(*)
    INTO unpinned_total
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE p.prosecdef
    AND n.nspname IN ('public', 'warehouse_security', 'warehouse_maintenance')
    AND NOT EXISTS (SELECT 1 FROM unnest(COALESCE(p.proconfig, '{}')) c WHERE c LIKE 'search_path=%');

  IF unpinned_total > 48 THEN
    RAISE EXCEPTION 'A new SECURITY DEFINER function has no search_path (% found, baseline 48)', unpinned_total;
  END IF;

  -- RLS with no policy denies everything: an exposed table in that state is a
  -- forgotten policy, not a decision.
  SELECT string_agg(format('%I.%I', n.nspname, c.relname), ', ')
    INTO rls_without_policy
  FROM pg_class c
  JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = 'public'
    AND c.relkind IN ('r', 'p')
    AND c.relrowsecurity
    AND NOT EXISTS (SELECT 1 FROM pg_policy pol WHERE pol.polrelid = c.oid)
    AND EXISTS (
      SELECT 1
      FROM information_schema.role_table_grants g
      WHERE g.table_schema = n.nspname
        AND g.table_name = c.relname
        AND g.grantee IN ('anon', 'authenticated')
    );

  IF rls_without_policy IS NOT NULL THEN
    RAISE EXCEPTION 'Exposed table has RLS but no policy: %', rls_without_policy;
  END IF;

  -- Nothing in the private schemas is reachable by an app role.
  SELECT string_agg(found.name, ', ')
    INTO private_reachable
  FROM (
    SELECT format('%I.%I', g.table_schema, g.table_name) AS name
    FROM information_schema.role_table_grants g
    WHERE g.table_schema IN ('warehouse_security', 'warehouse_maintenance')
      AND g.grantee IN ('PUBLIC', 'anon', 'authenticated')
    UNION
    SELECT p.oid::regprocedure::text
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'warehouse_security'
      AND has_function_privilege('anon', p.oid, 'EXECUTE')
  ) found;

  IF private_reachable IS NOT NULL THEN
    RAISE EXCEPTION 'Private schema object reachable by an app role: %', private_reachable;
  END IF;
END
$$;

SELECT 'security baseline passed' AS result;
