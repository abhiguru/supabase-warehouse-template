\set ON_ERROR_STOP on

DO $$
DECLARE
  bad_policies text;
  bad_grants text;
  rls_disabled text;
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
END
$$;

SELECT 'security baseline passed' AS result;
