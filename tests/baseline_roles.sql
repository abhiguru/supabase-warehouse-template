-- The database as the shipped bootstrap and the baseline leave it (run first in tests/migrations.sh, after the real Storage):
-- the exact set of roles and their flags, memberships and settings, the extensions, no publication, no event trigger, no
-- role of the old image, no ACL naming one, and the signer. Nothing is written.
\set ON_ERROR_STOP on
BEGIN;
CREATE FUNCTION pg_temp.br_assert(ok boolean, label text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF NOT COALESCE(ok, false) THEN RAISE EXCEPTION 'baseline roles: %', label; END IF; END $$;

-- 1. The roles (every role outside pg_*): name, then super/inherit/login/createrole/createdb/replication/bypassrls.
SELECT pg_temp.br_assert((SELECT string_agg(rolname || ' ' || concat_ws('/', rolsuper::int, rolinherit::int, rolcanlogin::int, rolcreaterole::int, rolcreatedb::int, rolreplication::int, rolbypassrls::int), E'\n' ORDER BY rolname COLLATE "C")
    FROM pg_roles WHERE rolname !~ '^pg_') = $r$anon 0/1/0/0/0/0/0
authenticated 0/1/0/0/0/0/0
authenticator 0/0/1/0/0/0/0
service_role 0/1/0/0/0/0/1
supabase_admin 1/1/1/1/1/1/1
supabase_storage_admin 0/0/1/0/0/0/0$r$,
  'the roles or their flags differ: ' || (SELECT string_agg(rolname || ' ' || concat_ws('/', rolsuper::int, rolinherit::int, rolcanlogin::int, rolcreaterole::int, rolcreatedb::int, rolreplication::int, rolbypassrls::int), '; ' ORDER BY rolname COLLATE "C") FROM pg_roles WHERE rolname !~ '^pg_'));
-- supabase_storage_admin and authenticator do not inherit the privileges of the roles they belong to.
SELECT pg_temp.br_assert(NOT rolinherit AND NOT rolcreaterole, 'supabase_storage_admin must be NOINHERIT and NOCREATEROLE') FROM pg_roles WHERE rolname = 'supabase_storage_admin';
SELECT pg_temp.br_assert(NOT rolinherit, 'authenticator must be NOINHERIT') FROM pg_roles WHERE rolname = 'authenticator';

-- 2. The memberships of those roles (in pg_* roles too: a grant of pg_read_all_data to authenticator must fail here), with the options of each grant (PostgreSQL 16 and later keep them per membership). The
--    members authenticator and supabase_storage_admin are NOINHERIT, so the grants made to them inherit nothing; SET ROLE works.
SELECT pg_temp.br_assert((SELECT string_agg(r.rolname || ' in ' || g.rolname || ' admin=' || m.admin_option || ' inherit=' || COALESCE((to_jsonb(m)->>'inherit_option')::boolean, r.rolinherit) || ' set=' || COALESCE((to_jsonb(m)->>'set_option')::boolean, true), E'\n' ORDER BY r.rolname, g.rolname)
    FROM pg_auth_members m JOIN pg_roles r ON r.oid = m.member JOIN pg_roles g ON g.oid = m.roleid WHERE r.rolname !~ '^pg_')
  = $r$authenticator in anon admin=false inherit=false set=true
authenticator in authenticated admin=false inherit=false set=true
authenticator in service_role admin=false inherit=false set=true
supabase_storage_admin in authenticator admin=false inherit=false set=true$r$,
  'the memberships differ');

-- 3. The settings of the roles.
SELECT pg_temp.br_assert((SELECT string_agg(r.rolname || ': ' || array_to_string(ARRAY(SELECT c FROM unnest(r.rolconfig) c ORDER BY c COLLATE "C"), ', '), E'\n' ORDER BY r.rolname COLLATE "C")
    FROM pg_roles r WHERE r.rolconfig IS NOT NULL AND r.rolname !~ '^pg_')
  = $r$anon: statement_timeout=3s
authenticated: statement_timeout=8s
authenticator: lock_timeout=8s, statement_timeout=8s
supabase_admin: log_statement=none, search_path="$user", public, auth, extensions
supabase_storage_admin: log_statement=none, search_path=storage$r$,
  'the role settings differ: ' || (SELECT string_agg(r.rolname || ': ' || array_to_string(r.rolconfig, ', '), '; ') FROM pg_roles r WHERE r.rolconfig IS NOT NULL));

-- 3b. The per-database and per-role-in-database settings (pg_db_role_setting), one fact per row. The harness of
--     tests/migrations.sh sets storage.allow_delete_query on the database for the suites that follow; that one is not counted.
CREATE FUNCTION pg_temp.br_settings(sep text) RETURNS text LANGUAGE sql AS $f$
  SELECT string_agg(COALESCE(d.datname, '-') || ' / ' || COALESCE(r.rolname, '-') || ': ' || s.items, sep ORDER BY COALESCE(d.datname, '') COLLATE "C", COALESCE(r.rolname, '') COLLATE "C")
  FROM (SELECT setdatabase, setrole, array_to_string(ARRAY(SELECT c FROM unnest(setconfig) c WHERE c NOT LIKE 'storage.allow\_delete\_query=%' ORDER BY c COLLATE "C"), ', ') AS items FROM pg_db_role_setting) s
  LEFT JOIN pg_database d ON d.oid = s.setdatabase LEFT JOIN pg_roles r ON r.oid = s.setrole
  WHERE s.items <> ''
$f$;
SELECT pg_temp.br_assert(pg_temp.br_settings(E'\n') = $r$- / anon: statement_timeout=3s
- / authenticated: statement_timeout=8s
- / authenticator: lock_timeout=8s, statement_timeout=8s
- / supabase_admin: log_statement=none, search_path="$user", public, auth, extensions
- / supabase_storage_admin: log_statement=none, search_path=storage$r$, 'the pg_db_role_setting rows differ: ' || pg_temp.br_settings('; '));

-- 4. No role of the old image, and none of the removed warehouse roles.
SELECT pg_temp.br_assert(NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname IN ('postgres', 'dashboard_user', 'supabase_auth_admin', 'supabase_realtime_admin', 'supabase_functions_admin',
  'supabase_read_only_user', 'supabase_replication_admin', 'supabase_etl_admin', 'warehouse_monitoring', 'warehouse_list_refresher')), 'a role of the old image or a removed role exists');

-- 5. No ACL of any object names one of them (a grant to a missing role cannot exist, but a stale name in a text ACL would show a bug in the dump).
SELECT pg_temp.br_assert(NOT EXISTS (
  SELECT 1 FROM (
    SELECT 'relation ' || oid::regclass::text AS what, relacl::text AS acl FROM pg_class WHERE relacl IS NOT NULL
    UNION ALL SELECT 'function ' || oid::regprocedure::text, proacl::text FROM pg_proc WHERE proacl IS NOT NULL
    UNION ALL SELECT 'schema ' || nspname, nspacl::text FROM pg_namespace WHERE nspacl IS NOT NULL
    UNION ALL SELECT 'default ' || defaclobjtype::text, defaclacl::text FROM pg_default_acl
    UNION ALL SELECT 'type ' || typname, typacl::text FROM pg_type WHERE typacl IS NOT NULL
    UNION ALL SELECT 'column ' || attrelid::regclass::text || '.' || attname, attacl::text FROM pg_attribute WHERE attacl IS NOT NULL
    UNION ALL SELECT 'database ' || datname, datacl::text FROM pg_database WHERE datacl IS NOT NULL
  ) x WHERE acl ~ '(^|[{,"])(postgres|dashboard_user|supabase_auth_admin|supabase_realtime_admin|supabase_functions_admin|supabase_read_only_user|supabase_replication_admin|supabase_etl_admin|warehouse_monitoring|warehouse_list_refresher)='),
  'an ACL names a role of the old image: ' || COALESCE((SELECT string_agg(what, ', ') FROM (
    SELECT 'relation ' || oid::regclass::text AS what, relacl::text AS acl FROM pg_class WHERE relacl IS NOT NULL
    UNION ALL SELECT 'function ' || oid::regprocedure::text, proacl::text FROM pg_proc WHERE proacl IS NOT NULL) y
    WHERE acl ~ '(^|[{,"])(postgres|dashboard_user|supabase_auth_admin|supabase_functions_admin|warehouse_monitoring)='), ''));

-- 6. State that the old transition probes (migrations 103, 105, 106, 107, 108) used to prove: extensions exactly these,
--    no publication, no event trigger, no replication slot, and the signer gives the jwt.io token.
SELECT pg_temp.br_assert((SELECT string_agg(extname, ', ' ORDER BY extname COLLATE "C") FROM pg_extension) = 'pg_stat_statements, pg_trgm, pgcrypto, plpgsql, uuid-ossp',
  'extensions: ' || (SELECT string_agg(extname, ', ' ORDER BY extname) FROM pg_extension));
SELECT pg_temp.br_assert(NOT EXISTS (SELECT 1 FROM pg_publication), 'a publication exists');
SELECT pg_temp.br_assert(NOT EXISTS (SELECT 1 FROM pg_event_trigger), 'an event trigger exists: ' || COALESCE((SELECT string_agg(evtname, ', ') FROM pg_event_trigger), ''));
SELECT pg_temp.br_assert(NOT EXISTS (SELECT 1 FROM pg_replication_slots), 'a replication slot exists');
SELECT pg_temp.br_assert(NOT EXISTS (SELECT 1 FROM pg_namespace WHERE nspname IN ('graphql', 'graphql_public', 'realtime', '_realtime', 'vault', 'net', 'cron', 'supabase_functions', 'warehouse_monitoring')), 'a schema of a removed component exists');
SELECT pg_temp.br_assert(NOT EXISTS (SELECT 1 FROM pg_database WHERE datname IN ('_realtime')), 'the database _realtime exists');
SELECT pg_temp.br_assert(warehouse_security.jwt_sign_hs256('{"sub":"1234567890","name":"John Doe","iat":1516239022}'::json, 'your-256-bit-secret')
  = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9' || '.' || 'eyJzdWIiOiIxMjM0NTY3ODkwIiwibmFtZSI6IkpvaG4gRG9lIiwiaWF0IjoxNTE2MjM5MDIyfQ' || '.' || 'SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c',
  'jwt_sign_hs256 does not give the jwt.io HS256 test token');

-- 7. The database: UTF8, en_US.UTF-8, owned by the bootstrap superuser.
SELECT pg_temp.br_assert((SELECT pg_encoding_to_char(encoding) = 'UTF8' AND datcollate = 'en_US.UTF-8' AND datctype = 'en_US.UTF-8' AND pg_get_userbyid(datdba) = 'supabase_admin'
  FROM pg_database WHERE datname = 'postgres'), 'the database postgres is not UTF8 / en_US.UTF-8 / owned by supabase_admin');
ROLLBACK;
