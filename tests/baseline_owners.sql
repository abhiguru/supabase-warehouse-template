-- Every object the baseline created is owned by supabase_admin: relations and functions in public, warehouse_*, auth and utils,
-- and the schemas auth, utils and warehouse_* (public belongs to pg_database_owner). Nothing is written.
\set ON_ERROR_STOP on
DO $$
DECLARE
  wrong text;
  checked bigint;
BEGIN
  SELECT string_agg(what || ' is owned by ' || owner, '; ' ORDER BY what), count(*) INTO wrong, checked FROM (
    SELECT 'relation ' || c.oid::regclass::text AS what, pg_get_userbyid(c.relowner) AS owner
      FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE (n.nspname IN ('public', 'auth', 'utils') OR n.nspname LIKE 'warehouse\_%') AND c.relkind IN ('r', 'p', 'v', 'm', 'S', 'f', 'c')
       AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.classid = 'pg_class'::regclass AND d.objid = c.oid AND d.deptype = 'e')
    UNION ALL
    SELECT 'function ' || p.oid::regprocedure::text, pg_get_userbyid(p.proowner)
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE (n.nspname IN ('public', 'auth', 'utils') OR n.nspname LIKE 'warehouse\_%')
       AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.classid = 'pg_proc'::regclass AND d.objid = p.oid AND d.deptype = 'e')
    UNION ALL
    SELECT 'type ' || t.oid::regtype::text, pg_get_userbyid(t.typowner)
      FROM pg_type t JOIN pg_namespace n ON n.oid = t.typnamespace
     WHERE (n.nspname IN ('public', 'auth', 'utils') OR n.nspname LIKE 'warehouse\_%') AND t.typrelid = 0 AND t.typcategory <> 'A'
       AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.classid = 'pg_type'::regclass AND d.objid = t.oid AND d.deptype = 'e')
    UNION ALL
    SELECT 'extension ' || e.extname, pg_get_userbyid(e.extowner) FROM pg_extension e
    UNION ALL
    SELECT 'schema ' || n.nspname, pg_get_userbyid(n.nspowner)
      FROM pg_namespace n WHERE n.nspname IN ('auth', 'utils') OR n.nspname LIKE 'warehouse\_%'
  ) x WHERE owner <> 'supabase_admin';
  IF wrong IS NOT NULL THEN RAISE EXCEPTION 'baseline owners: %', left(wrong, 1000); END IF;
  SELECT count(*) INTO checked FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname = 'public' AND c.relkind IN ('r', 'p');
  IF checked < 50 THEN RAISE EXCEPTION 'baseline owners: only % tables in public; the check did not look at the baseline', checked; END IF;
END $$;
