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

-- The monitoring login (migration 94; docs/CONTAINER_SECURITY.md, "Database
-- passwords"): the Postgres exporter signs in as warehouse_monitoring.
-- It is a member of pg_monitor and of nothing else, has no role attribute beyond
-- inheriting that membership, holds no grant on any object, owns nothing, and no
-- role can take its identity. Its LOGIN and password come from
-- scripts/configure-db-roles.sql, never from a migration.
DO $$
DECLARE
  memberships text;
  members text;
  grants text;
  readable text;
  monitoring oid := (SELECT oid FROM pg_roles WHERE rolname = 'warehouse_monitoring');
BEGIN
  IF monitoring IS NULL THEN
    RAISE EXCEPTION 'The monitoring login warehouse_monitoring does not exist';
  END IF;
  SELECT string_agg(granted.rolname, ', ' ORDER BY granted.rolname) INTO memberships
  FROM pg_auth_members m JOIN pg_roles granted ON granted.oid = m.roleid
  WHERE m.member = monitoring;
  IF memberships IS DISTINCT FROM 'pg_monitor' THEN
    RAISE EXCEPTION 'warehouse_monitoring must be a member of pg_monitor only, not: %', COALESCE(memberships, 'nothing');
  END IF;
  SELECT string_agg(member.rolname, ', ') INTO members
  FROM pg_auth_members m JOIN pg_roles member ON member.oid = m.member
  WHERE m.roleid = monitoring;
  IF members IS NOT NULL THEN
    RAISE EXCEPTION 'No role may be a member of warehouse_monitoring: %', members;
  END IF;
  IF EXISTS (SELECT 1 FROM pg_roles WHERE oid = monitoring
             AND (rolsuper OR rolcreaterole OR rolcreatedb OR rolreplication OR rolbypassrls OR NOT rolinherit)) THEN
    RAISE EXCEPTION 'warehouse_monitoring has a superuser, role, database, replication or RLS-bypass right, or does not inherit pg_monitor';
  END IF;
  -- Every grant to the role and every object it owns, in this database or shared, is a
  -- dependency entry: ACL ('a'), owner ('o') or default privileges.
  SELECT string_agg(COALESCE(pg_describe_object(d.classid, d.objid, d.objsubid), d.classid::regclass::text) || ' (' || d.deptype::text || ')', ', ')
    INTO grants
  FROM pg_shdepend d
  WHERE d.refclassid = 'pg_authid'::regclass AND d.refobjid = monitoring
    AND d.dbid IN (0, (SELECT oid FROM pg_database WHERE datname = current_database()));
  IF grants IS NOT NULL THEN
    RAISE EXCEPTION 'warehouse_monitoring must hold no grant and own nothing: %', grants;
  END IF;
  -- Nor can it read a table of the application, the private schemas, Storage or the
  -- migration ledger by any other path (a grant to PUBLIC included). Reaching a table
  -- needs USAGE on its schema as well as a table right, so both count. The one exception
  -- is pg_cron's own: it grants its job tables to PUBLIC and lets each role see only the
  -- rows of its own jobs through row security (username = current_user); this role owns
  -- no job, so it reads no row there.
  SELECT string_agg(format('%I.%I', n.nspname, c.relname), ', ' ORDER BY n.nspname, c.relname) INTO readable
  FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE c.relkind IN ('r', 'p', 'v', 'm', 'f')
    AND n.nspname IN ('public', 'warehouse_security', 'warehouse_maintenance', 'warehouse_migrations', 'storage', 'auth', 'vault', 'pgsodium', '_realtime', 'realtime', 'cron', 'net', 'supabase_functions')
    AND has_schema_privilege(monitoring, n.oid, 'USAGE')
    AND has_table_privilege(monitoring, c.oid, 'SELECT, INSERT, UPDATE, DELETE, TRUNCATE')
    AND NOT (n.nspname = 'cron' AND c.relname IN ('job', 'job_run_details') AND c.relrowsecurity
             AND EXISTS (SELECT 1 FROM pg_policy pol WHERE pol.polrelid = c.oid
                         AND pg_get_expr(pol.polqual, pol.polrelid) = '(username = CURRENT_USER)'));
  IF readable IS NOT NULL THEN
    RAISE EXCEPTION 'warehouse_monitoring can read or write: %', readable;
  END IF;
  -- pg_stat_statements keeps utility statements verbatim (track = all), the JWT secret of a
  -- signing-key rotation among them; its views live in `extensions`, which the role must not use.
  IF to_regnamespace('extensions') IS NOT NULL AND has_schema_privilege(monitoring, 'extensions', 'USAGE') THEN
    RAISE EXCEPTION 'warehouse_monitoring may use schema extensions (pg_stat_statements history)';
  END IF;
  IF to_regclass('cron.job') IS NOT NULL THEN
    EXECUTE 'SELECT string_agg(jobname, '', '') FROM cron.job WHERE username = $1' INTO readable USING 'warehouse_monitoring';
    IF readable IS NOT NULL THEN
      RAISE EXCEPTION 'warehouse_monitoring owns pg_cron jobs: %', readable;
    END IF;
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

SELECT 'security baseline passed' AS result;
