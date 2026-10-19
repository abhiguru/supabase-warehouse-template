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
  anon_columns text;
  invoice_columns text;
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
      AND table_name = 'feature_flags'
    );

  IF bad_grants IS NOT NULL THEN
    RAISE EXCEPTION 'Unexpected anonymous table grant: %', bad_grants;
  END IF;

  -- A grant on single columns is not in role_table_grants; it exposes a table
  -- all the same.
  SELECT string_agg(DISTINCT format('%I.%I', table_schema, table_name), ', ')
    INTO anon_columns
  FROM information_schema.column_privileges
  WHERE grantee = 'anon'
    AND table_schema = 'public'
    AND NOT (privilege_type = 'SELECT' AND table_name = 'feature_flags');

  IF anon_columns IS NOT NULL THEN
    RAISE EXCEPTION 'Unexpected anonymous column grant: %', anon_columns;
  END IF;

  SELECT string_agg(format('%I.%I', n.nspname, c.relname), ', ')
    INTO rls_disabled
  FROM pg_class c
  JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = 'public'
    AND c.relkind = 'r'
    AND NOT c.relrowsecurity
    AND (EXISTS (
      SELECT 1
      FROM information_schema.role_table_grants g
      WHERE g.table_schema = n.nspname
        AND g.table_name = c.relname
        AND g.grantee IN ('anon', 'authenticated')
    ) OR EXISTS (
      -- a table granted by column only (invoice, migration 48) is exposed too
      SELECT 1
      FROM information_schema.column_privileges g
      WHERE g.table_schema = n.nspname
        AND g.table_name = c.relname
        AND g.grantee IN ('anon', 'authenticated')
    ));

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
    AND (EXISTS (
      SELECT 1
      FROM information_schema.role_table_grants g
      WHERE g.table_schema = n.nspname
        AND g.table_name = c.relname
        AND g.grantee IN ('anon', 'authenticated')
    ) OR EXISTS (
      -- a table granted by column only (invoice, migration 48) is exposed too
      SELECT 1
      FROM information_schema.column_privileges g
      WHERE g.table_schema = n.nspname
        AND g.table_name = c.relname
        AND g.grantee IN ('anon', 'authenticated')
    ));

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

  -- invoice is granted to the app role column by column (migration 48): the
  -- discount record and the zero-charge record are internal, and a customer
  -- account reads its own invoice rows. Every column is either readable or on
  -- this list. A migration that adds a column must decide: GRANT SELECT (column)
  -- to authenticated, or add it here. Until it does, the column is not readable
  -- directly and this check fails.
  SELECT string_agg(a.attname, ', ' ORDER BY a.attnum)
    INTO invoice_columns
  FROM pg_attribute a
  WHERE a.attrelid = 'public.invoice'::regclass
    AND a.attnum > 0
    AND NOT a.attisdropped
    AND has_column_privilege('authenticated', a.attrelid, a.attnum, 'SELECT')
        = (a.attname IN ('discount_reason', 'discount_set_by', 'discount_set_at',
                         'zero_charge_reason', 'zero_charge_set_by', 'zero_charge_set_at'));

  IF invoice_columns IS NOT NULL THEN
    RAISE EXCEPTION 'invoice column readable by the app role although internal, or neither readable nor listed as internal: %', invoice_columns;
  END IF;

  IF has_any_column_privilege('anon', 'public.invoice', 'SELECT')
     OR has_table_privilege('authenticated', 'public.invoice', 'SELECT') THEN
    RAISE EXCEPTION 'invoice must have no anonymous read and no table-wide SELECT for the app role';
  END IF;
END
$$;

-- The monitoring role (migration 94) is dropped by migration 107 and by
-- scripts/configure-db-roles.sql after a restore. Nothing may bring it back, and
-- nothing may hold an entry that names it.
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'warehouse_monitoring') THEN
    RAISE EXCEPTION 'The monitoring login warehouse_monitoring must not exist (migration 107 drops it)';
  END IF;
END
$$;

-- supabase_functions_admin owns the webhook functions; nothing signs in as it
-- (migration 94). The role exists only where the Compose init scripts ran.
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_authid WHERE rolname = 'supabase_functions_admin' AND (rolcanlogin OR rolpassword IS NOT NULL)) THEN
    RAISE EXCEPTION 'supabase_functions_admin must have no login and no password';
  END IF;
END
$$;

-- supabase_auth_admin owns auth.uid(), auth.role(), auth.email() and 26 auth relations and holds default privileges
-- in schema auth (supabase_admin owns the schema and auth.jwt()); the row policies use these functions, so the role
-- stays. The Auth service is gone and nothing signs in as it (migration 104).
DO $$
DECLARE
  state record;
BEGIN
  SELECT rolcanlogin, rolpassword IS NOT NULL AS has_password INTO state FROM pg_authid WHERE rolname = 'supabase_auth_admin';
  IF NOT FOUND THEN
    RAISE EXCEPTION 'supabase_auth_admin must exist: it owns the auth schema objects';
  END IF;
  IF state.rolcanlogin OR state.has_password THEN
    RAISE EXCEPTION 'supabase_auth_admin must have no login and no password (login %, password %)', state.rolcanlogin, state.has_password;
  END IF;
END
$$;

-- Migration 104 drops every foreign key into schema auth (the official Postgres image has no GoTrue tables): no constraint
-- outside schema auth references a table in it.
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_constraint k JOIN pg_class r ON r.oid = k.conrelid JOIN pg_class t ON t.oid = k.confrelid
              WHERE k.contype = 'f' AND t.relnamespace = 'auth'::regnamespace AND r.relnamespace <> 'auth'::regnamespace) THEN
    RAISE EXCEPTION 'a foreign key outside schema auth still points into it';
  END IF;
END
$$;

SELECT 'security baseline passed' AS result;
