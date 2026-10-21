import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { parseLines, diffLines, parseAllowList, applyAllowList, formatReport, normaliseOwnerFacts, expandAlternatives } from '../scripts/baseline/catalog-diff.mjs';
import { editDump, splitBlocks, namesRemovedRole, DEFAULT_REMOVED_ROLES } from '../scripts/baseline/edit-dump.mjs';

test('parseLines drops blank lines, strips CR and sorts', () => {
  assert.deepEqual(parseLines('b|2\r\n\na|1\n'), ['a|1', 'b|2']);
});

test('diffLines is a multiset difference: a repeated line counts', () => {
  const d = diffLines(['a', 'b', 'b', 'c'], ['b', 'c', 'c', 'd']);
  assert.deepEqual(d.onlyA, ['a', 'b']);
  assert.deepEqual(d.onlyB, ['c', 'd']);
  assert.deepEqual(diffLines(['x'], ['x']), { onlyA: [], onlyB: [] });
});

test('parseAllowList reads side and regex, skips comments and blanks, rejects malformed lines', () => {
  const entries = parseAllowList('# why\n\nA ^acl\\|.* -> postgres \nB ^schema\\|vault\\|\n');
  assert.equal(entries.length, 2);
  assert.deepEqual(entries.map(e => e.side), ['A', 'B']);
  assert.equal(entries[1].regex.test('schema|vault|owner x'), true);
  assert.throws(() => parseAllowList('C foo'), /line 1/);
  assert.throws(() => parseAllowList('# c\nA ([unclosed'), /line 2: bad regex/);
});

test('applyAllowList: a covered line is allowed only on its own side; the rest is unexpected', () => {
  const entries = parseAllowList('A ^acl\\|function\\|public\\.f\\(\\)\\|.* -> postgres \nB ^schema\\|vault\\|');
  const diff = {
    onlyA: ['acl|function|public.f()|supabase_admin -> postgres EXECUTE', 'acl|function|public.f()|supabase_admin -> anon EXECUTE'],
    onlyB: ['schema|vault|owner supabase_admin', 'acl|function|public.f()|supabase_admin -> postgres EXECUTE'],
  };
  const r = applyAllowList(diff, entries);
  assert.equal(r.allowed, 2);
  assert.deepEqual(r.unexpected.map(u => u.side), ['A', 'B']);
  assert.equal(r.unexpected[0].line.endsWith('anon EXECUTE'), true);
  assert.deepEqual(r.unused, []);
});

test('applyAllowList reports an entry that matched nothing as unused, and recounts on each call', () => {
  const entries = parseAllowList('A ^never$');
  assert.equal(applyAllowList({ onlyA: [], onlyB: [] }, entries).unused.length, 1);
  assert.equal(applyAllowList({ onlyA: ['never'], onlyB: [] }, entries).unused.length, 0);
  assert.equal(applyAllowList({ onlyA: [], onlyB: [] }, entries).unused.length, 1);
});

test('formatReport cuts long lines unless full is asked for', () => {
  const long = 'function|x|' + 'y'.repeat(500);
  const result = { unexpected: [{ side: 'B', line: long }], allowed: 0, unused: [] };
  assert.match(formatReport(result), /\.\.\. \[\d+ chars\]/);
  assert.equal(formatReport(result, { full: true }).endsWith('y'.repeat(500)), true);
});

const BLOCK = (name, type, schema, body) => `--\n-- Name: ${name}; Type: ${type}; Schema: ${schema}; Owner: x\n--\n\n${body}\n\n`;

test('splitBlocks cuts a dump at its Name/Type headers', () => {
  const text = `SET a = 1;\n\n${BLOCK('f()', 'FUNCTION', 'public', 'CREATE FUNCTION public.f();')}${BLOCK('FUNCTION f()', 'ACL', 'public', 'GRANT ALL ON FUNCTION public.f() TO postgres;')}`;
  assert.deepEqual(splitBlocks(text).map(b => b.type), ['', 'FUNCTION', 'ACL']);
});

test('namesRemovedRole matches grants and default privileges to removed roles only', () => {
  const roles = ['postgres', 'dashboard_user'];
  assert.equal(namesRemovedRole('GRANT ALL ON FUNCTION public.f(a integer) TO postgres;', roles), true);
  assert.equal(namesRemovedRole('REVOKE ALL ON FUNCTION public.f() FROM postgres;', roles), true);
  assert.equal(namesRemovedRole('GRANT ALL ON FUNCTION public.f() TO service_role;', roles), false);
  assert.equal(namesRemovedRole('ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON TABLES  TO anon;', roles), true);
  assert.equal(namesRemovedRole('ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin IN SCHEMA public GRANT ALL ON TABLES  TO dashboard_user;', roles), true);
  assert.equal(namesRemovedRole('ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin IN SCHEMA public GRANT ALL ON TABLES  TO anon;', roles), false);
});

test('editDump applies each documented edit and leaves function bodies alone', () => {
  const raw = [
    'SET statement_timeout = 0;', "SELECT pg_catalog.set_config('search_path', '', false);", '',
    BLOCK('auth', 'SCHEMA', '-', 'CREATE SCHEMA auth;\n\nALTER SCHEMA auth OWNER TO supabase_admin;'),
    BLOCK('public', 'SCHEMA', '-', 'CREATE SCHEMA public;'),
    BLOCK('email()', 'FUNCTION', 'auth', 'CREATE FUNCTION auth.email() RETURNS text\n    LANGUAGE sql\n    AS $$ select 1 $$;\n\nALTER FUNCTION auth.email() OWNER TO supabase_auth_admin;'),
    BLOCK('g()', 'FUNCTION', 'public', "CREATE FUNCTION public.g() RETURNS void\n    LANGUAGE plpgsql\n    AS $$ BEGIN\nGRANT ALL ON TABLE t TO postgres;\nEND $$;"),
    BLOCK('pgrst_ddl_watch', 'EVENT TRIGGER', '-', 'CREATE EVENT TRIGGER pgrst_ddl_watch ON ddl_command_end\n   EXECUTE FUNCTION public.pgrst_ddl_watch();'),
    BLOCK('FUNCTION g()', 'ACL', 'public', 'GRANT ALL ON FUNCTION public.g() TO postgres;\nGRANT ALL ON FUNCTION public.g() TO dashboard_user;\nGRANT ALL ON FUNCTION public.g() TO service_role;'),
    BLOCK('DEFAULT PRIVILEGES FOR TABLES', 'DEFAULT ACL', 'public', 'ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON TABLES  TO anon;\nALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin IN SCHEMA public GRANT ALL ON TABLES  TO anon;'),
  ].join('\n');
  const out = editDump(raw);
  assert.doesNotMatch(out, /^SET statement_timeout/m);
  assert.doesNotMatch(out, /set_config\('search_path'/);
  assert.match(out, /^CREATE SCHEMA IF NOT EXISTS auth;$/m);
  assert.doesNotMatch(out, /^CREATE SCHEMA public;$/m);
  assert.match(out, /^CREATE OR REPLACE FUNCTION auth\.email\(\)/m);
  assert.match(out, /^ALTER FUNCTION auth\.email\(\) OWNER TO supabase_admin;$/m);
  assert.doesNotMatch(out, /pgrst_ddl_watch/);
  assert.match(out, /GRANT ALL ON TABLE t TO postgres;/, 'a GRANT inside a function body is not an ACL statement');
  assert.doesNotMatch(out, /GRANT ALL ON FUNCTION public\.g\(\) TO (postgres|dashboard_user)/);
  assert.match(out, /GRANT ALL ON FUNCTION public\.g\(\) TO service_role;/);
  assert.doesNotMatch(out, /FOR ROLE postgres/);
  assert.match(out, /FOR ROLE supabase_admin IN SCHEMA public GRANT ALL ON TABLES  TO anon;/);
});

test('editDump refuses when a removed role is still owner of an object', () => {
  const raw = BLOCK('t', 'TABLE', 'public', 'CREATE TABLE public.t (id integer);\n\nALTER TABLE public.t OWNER TO postgres;');
  assert.throws(() => editDump(raw), /removed role or a session-level setting/);
});

// ---- review fixes: the REAL allow-list against lines it must not allow ------------------------------------------------
const read = f => readFileSync(new URL(`../scripts/baseline/${f}`, import.meta.url), 'utf8');
const realEntries = () => parseAllowList(read('allowed-differences.txt'));
const check = (onlyA, onlyB, image) => applyAllowList({ onlyA: onlyA.sort(), onlyB: onlyB.sort() }, realEntries(), { image });
const checkFacts = (a, b, image) => applyAllowList(diffLines([...a].sort(), [...b].sort()), realEntries(), { image });
const AUTH_FN = 'function|auth.uid()|kind f owner supabase_auth_admin secdef false volatility s strict false parallel s leakproof false cost 100 rows 0 config  language sql def BODY';

test('every entry of the real allow-list has a comment above it and parses', () => {
  let commented = false;
  for (const raw of read('allowed-differences.txt').split('\n')) {
    const line = raw.trim();
    if (line === '') commented = false;
    else if (line.startsWith('#')) commented = true;
    else assert.equal(commented, true, `entry without a comment: ${line}`);
  }
  const lines = read('allowed-differences.txt').split('\n').map(l => l.trim()).filter(l => l && !l.startsWith('#'));
  assert.ok(lines.length >= 60 && realEntries().length >= lines.length, 'every entry line parsed (alternatives make more entries, never fewer)');
});

test('H1: only the owner change of auth.email/role/uid is absorbed; a changed body, lost search_path or lost grant is reported', () => {
  const a = [AUTH_FN, 'acl|function|auth.uid()|supabase_auth_admin -> supabase_auth_admin EXECUTE', 'acl|function|auth.uid()|supabase_auth_admin -> anon EXECUTE'];
  const b = [AUTH_FN.replace('supabase_auth_admin', 'supabase_admin'), 'acl|function|auth.uid()|supabase_admin -> supabase_admin EXECUTE', 'acl|function|auth.uid()|supabase_admin -> anon EXECUTE'];
  for (const image of ['supabase', 'pg17']) {
    assert.deepEqual(checkFacts(normaliseOwnerFacts(a), b, image).unexpected, [], 'the pure owner change is absorbed');
    assert.equal(checkFacts(normaliseOwnerFacts(a), b.map(l => l.replace('BODY', 'OTHER')), image).unexpected.length, 2, 'changed body');
    assert.equal(checkFacts(normaliseOwnerFacts(a), b.map(l => l.replace('config  language', 'config search_path=pg_catalog language')), image).unexpected.length, 2, 'search_path differs');
    assert.equal(checkFacts(normaliseOwnerFacts(a), b.filter(l => !l.endsWith('-> anon EXECUTE')), image).unexpected.length, 1, 'lost grant');
  }
  assert.deepEqual(check(['acl|function|auth.uid()|supabase_admin -> authenticated EXECUTE'], [], 'supabase').unexpected.map(u => u.side), ['A']);
  assert.equal(checkFacts(normaliseOwnerFacts(['acl|function|auth.uid()|supabase_auth_admin -> authenticated EXECUTE']), [], 'pg17').unexpected.length, 1);
});

test('M1: the old-image entries do not hide a baseline that creates the image schemas on postgres:17', () => {
  const bOnly = ['schema|vault|owner supabase_admin', 'extension|pg_graphql|version 1.5 schema extensions relocatable false owner x', 'publication|supabase_realtime|owner x all f ins t upd t del t trunc t',
    'eventtrigger|issue_pg_cron_access|event ddl_command_end', 'acl|schema|graphql|supabase_admin -> anon USAGE', 'acl|ext-member|supabase_vault:table vault.secrets|supabase_admin -> service_role SELECT'];
  assert.equal(check([], bOnly, 'supabase').unexpected.length, 0);
  assert.equal(check([], bOnly, 'pg17').unexpected.length, bOnly.length);
  // The kept extensions are not absorbed on the old image: a changed ACL of a pgcrypto member is reported (review L-3).
  assert.equal(check([], ['acl|ext-member|pgcrypto:function extensions.digest(bytea,text)|supabase_admin -> PUBLIC EXECUTE'], 'supabase').unexpected.length, 1);
});

test('M1: an entry that applies to the run and matches nothing is unused; entries of the other image are not counted', () => {
  const r = check([], [], 'pg17');
  assert.ok(r.unused.length > 0 && r.unused.every(e => e.image !== 'supabase'));
  assert.ok(check([], [], 'supabase').unused.every(e => e.image !== 'pg17'));
});

test('L6: MAINTAIN is allowed for named roles on relations only, never PUBLIC or columns; a trailing-space regex is not relied on', () => {
  assert.equal(check([], ['acl|relation|public.t|supabase_admin -> service_role MAINTAIN'], 'pg17').unexpected.length, 0);
  assert.equal(check([], ['acl|relation|public.t|supabase_admin -> PUBLIC MAINTAIN'], 'pg17').unexpected.length, 1);
  assert.equal(check([], ['acl|column|public.t.c|supabase_admin -> anon MAINTAIN'], 'pg17').unexpected.length, 1);
  assert.equal(check(['acl|relation|public.t|supabase_admin -> postgresql_x SELECT'], [], 'supabase').unexpected.length, 1, 'a role that merely starts with postgres');
  assert.equal(check(['acl|relation|public.t|supabase_admin -> postgres SELECT'], [], 'supabase').unexpected.length, 0);
  assert.equal(check(['acl|ext-member|function extensions.f()|supabase_admin -> dashboard_user EXECUTE'], [], 'pg17').unexpected.length, 0);
  assert.equal(check(['acl|ext-member|function extensions.f()|supabase_admin -> dashboard_user EXECUTE'], [], 'supabase').unexpected.length, 1, 'on the old image both sides carry it, so a one-sided line is a real difference');
});

test('five mutation checks: each damaged baseline line is reported on both images', () => {
  const mutations = {
    'function body changed': [['function|public.f()|kind f def X'], ['function|public.f()|kind f def Y']],
    'index dropped': [['index|public.t|CREATE INDEX i ON public.t (a) valid true replident false clustered false'], []],
    'grant to PUBLIC lost': [['acl|function|public.f()|supabase_admin -> PUBLIC EXECUTE'], []],
    'seed row lost': [['seed|public.items|rows 3 hash aaa masked '], ['seed|public.items|rows 2 hash bbb masked ']],
    'sequence position lost': [['seqstate|public.s|last_value 7'], ['seqstate|public.s|last_value NULL']],
  };
  for (const [name, [a, b]] of Object.entries(mutations)) {
    for (const image of ['supabase', 'pg17']) assert.ok(check(a, b, image).unexpected.length > 0, `${name} (${image})`);
  }
});

test('parseAllowList reads the optional image tag and rejects an unknown one', () => {
  const e = parseAllowList('B@pg17 ^x\nA ^y\nB@supabase ^z');
  assert.deepEqual(e.map(x => [x.side, x.image]), [['B', 'pg17'], ['A', ''], ['B', 'supabase']]);
  assert.throws(() => parseAllowList('B@foo ^x'), /line 1/);
});

// ---- edit-dump ------------------------------------------------------------------------------------------------------
test('L1: default privileges WITH GRANT OPTION to a removed role are removed; SET SESSION AUTHORIZATION of one fails the edit', () => {
  assert.equal(namesRemovedRole('ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin IN SCHEMA public GRANT ALL ON TABLES  TO postgres WITH GRANT OPTION;', ['postgres']), true);
  const dacl = BLOCK('DEFAULT PRIVILEGES FOR TABLES', 'DEFAULT ACL', 'public', 'ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin IN SCHEMA public GRANT ALL ON TABLES  TO postgres WITH GRANT OPTION;');
  assert.doesNotMatch(editDump(dacl), /postgres/);
  const ssa = BLOCK('FUNCTION f()', 'ACL', 'public', "SET SESSION AUTHORIZATION 'postgres';\nGRANT ALL ON FUNCTION public.f() TO anon;\nRESET SESSION AUTHORIZATION;");
  assert.throws(() => editDump(ssa), /removed role or a session-level setting/);
  assert.doesNotThrow(() => editDump(BLOCK('FUNCTION f()', 'ACL', 'public', "SET SESSION AUTHORIZATION 'supabase_admin';\nGRANT ALL ON FUNCTION public.f() TO anon;\nRESET SESSION AUTHORIZATION;")));
});

test('L2: schema and function edits stay inside their own block; a leftover session SET fails; E6 turns tablespace SETs into SET LOCAL', () => {
  const other = BLOCK('f()', 'FUNCTION', 'public', 'CREATE FUNCTION public.f() RETURNS text LANGUAGE sql AS $$ select 1 $$;\n-- CREATE SCHEMA public;\nCREATE SCHEMA public;');
  assert.match(editDump(other), /^CREATE SCHEMA public;$/m, 'only the public SCHEMA block loses it');
  const wrongFn = BLOCK('email()', 'FUNCTION', 'public', 'CREATE FUNCTION auth.email() RETURNS text LANGUAGE sql AS $$ select 1 $$;');
  assert.match(editDump(wrongFn), /^CREATE FUNCTION auth\.email\(\)/m, 'a function of another schema is not rewritten');
  assert.throws(() => editDump(`${BLOCK('t', 'TABLE', 'public', 'SET statement_timeout = 1;\nCREATE TABLE public.t (id int);')}`), /session-level/);
  assert.throws(() => editDump(`${BLOCK('t', 'TABLE', 'public', "SELECT pg_catalog.set_config('search_path', '', false);")}`), /session-level/);
  assert.match(editDump(`${BLOCK('t', 'TABLE', 'public', "SET default_tablespace = '';\nSET default_table_access_method = heap;\nCREATE TABLE public.t (id int);")}`), /^SET LOCAL default_tablespace = '';\nSET LOCAL default_table_access_method = heap;/m);
});

// ---- dump-baseline.sh and seed-dump.sql, read as text (no database) ------------------------------------------------
test('the baseline header holds only transaction-local settings', () => {
  const script = read('dump-baseline.sh');
  const header = script.slice(script.indexOf('cat <<HEADER'), script.indexOf('\nHEADER\n'));
  const settings = header.split('\n').filter(l => /^(SET |SELECT pg_catalog\.set_config)/.test(l));
  assert.ok(settings.length >= 8);
  for (const l of settings) assert.match(l, /^SET LOCAL |^SELECT pg_catalog\.set_config\('search_path', '', true\);$/, l);
});

test('role settings are written with %I and %L quoting; list settings keep their stored form', () => {
  const script = read('dump-baseline.sh');
  assert.match(script, /ALTER ROLE %I SET %I TO %s;/);
  assert.match(script, /quote_literal\(substr\(c, position/);
  assert.match(script, /'search_path', 'temp_tablespaces'/);
  assert.match(script, /rolname <> ALL\(\$removed_sql\)/, 'removed roles are not created');
  assert.match(script, /--strict-names/);
  assert.match(script, /pg_partition_tree/);
  assert.match(script, /--expect-last N is required/);
});

test('M6: only clock-defaulted timestamps and v1/v4 random-uuid values are masked; the sequence state is compared', () => {
  const sql = read('seed-dump.sql');
  assert.match(sql, /now\\\(\\\)\|CURRENT_TIMESTAMP\|clock_timestamp\|statement_timestamp\|transaction_timestamp/);
  assert.match(sql, /gen_random_uuid\|uuid_generate_v1\|uuid_generate_v4/);
  assert.doesNotMatch(sql, /uuid_generate\||\|random/, 'v3/v5 and other defaults are not masked');
  assert.match(sql, /substr\(t\.%I::text, 15, 1\) IN \(''1'', ''4''\)/);
  assert.match(sql, /baseline\.unmasked/);
  assert.match(sql, /seqstate\|/);
  assert.match(sql, /SET search_path = pg_catalog;/);
  assert.match(read('catalog-dump.sql'), /SET search_path = pg_catalog;/);
});

const FROZEN_AT = 'migrations-pre-baseline'; // the last tree with the chain; the tag exists locally and after release, not in a shallow CI clone
// The values of that commit, frozen as literals: a shallow clone (CI) has no such tag.
const FROZEN_IMAGE = 'supabase/postgres:15.8.1.135@sha256:ee680a0afebe1a5e95614fdea671c01a264e58f52de6c429c17a394f46dec2c6';
const FROZEN_FLAGS = ['shared_preload_libraries=pg_stat_statements,pg_cron', 'pg_stat_statements.track=all', 'cron.database_name=postgres', 'cron.log_statement=off', 'wal_level=replica'];
const repoDir = new URL('..', import.meta.url).pathname;
const frozenCommitPresent = () => spawnSync('git', ['cat-file', '-e', `${FROZEN_AT}^{commit}`], { cwd: repoDir }).status === 0;
const atFrozen = path => spawnSync('git', ['show', `${FROZEN_AT}:${path}`], { cwd: repoDir, encoding: 'utf8' });
test('the tooling reads the shipped image from scripts/db-image.sh; the old image and its flags are frozen', () => {
  const lib = read('lib.sh');
  assert.match(lib, /^NEW_DB_IMAGE="\$\(bash "\$BASELINE_ROOT\/scripts\/db-image\.sh"\)"/m);
  const old = lib.match(/^OLD_DB_IMAGE='(supabase\/postgres:[^']+@sha256:[0-9a-f]{64})'/m)?.[1];
  assert.equal(old, FROZEN_IMAGE, 'the old image is pinned in lib.sh');
  assert.equal(lib.match(/@sha256:/g).length, 1, 'only the old image is pinned here');
  assert.match(read('verify-baseline.sh'), /b_image="\$NEW_DB_IMAGE"/);
  assert.doesNotMatch(read('verify-baseline.sh') + read('build-chain-db.sh'), /DEFAULT_DB_IMAGE/);
  const mine = lib.match(/OLD_DB_FLAGS=\(\n([^)]*)\)/)[1].split('\n').map(l => l.trim()).filter(Boolean);
  assert.deepEqual(mine, FROZEN_FLAGS, 'OLD_DB_FLAGS are the frozen -c flags');
  // Where the tag exists, the literals are checked against it too.
  if (frozenCommitPresent()) {
    const migrationsSh = atFrozen('tests/migrations.sh');
    assert.equal(migrationsSh.status, 0, `git show ${FROZEN_AT}:tests/migrations.sh failed`);
    assert.ok(migrationsSh.stdout.includes(FROZEN_IMAGE), 'the frozen image is the one tests/migrations.sh used');
    const override = atFrozen('docker/docker-compose.override.yml');
    assert.equal(override.status, 0);
    const frozen = [...override.stdout.matchAll(/^ *-c ((?:shared_preload_libraries|wal_level|pg_stat_statements\.[a-z_]+|cron\.[a-z_]+)=.*)$/gm)].map(m => m[1]);
    assert.deepEqual(FROZEN_FLAGS, frozen, 'the literals equal the -c flags of the frozen override file');
  }
  // The checkout's Compose file no longer has them: only the postgres:17 side reads it.
  assert.doesNotMatch(readFileSync(new URL('../docker/docker-compose.yml', import.meta.url), 'utf8'), /pg_cron|cron\./);
});

test('pg_trgm: the baseline replays the chain ACL of extension members, so the allow-list holds no entry for them', () => {
  const dump = read('dump-baseline.sh');
  assert.match(dump, /Part 2b: the privileges of extension members/);
  assert.match(dump, /'REVOKE ALL ON ' \|\| target \|\| ' FROM PUBLIC;'/, 'PUBLIC is revoked first');
  assert.match(dump, /'GRANT ' \|\| e\.privs \|\| ' ON ' \|\| e\.target/, 'then each entry of the chain ACL is granted');
  assert.match(dump, /pg_depend d ON d\.classid = 'pg_proc'::regclass[^\n]*d\.deptype = 'e'/, 'functions that belong to an extension');
  assert.ok(dump.indexOf('cat "$work/ext.sql"') < dump.indexOf('cat "$work/extacl.sql"'), 'after the CREATE EXTENSION lines');
  assert.ok(dump.indexOf('cat "$work/extacl.sql"') < dump.indexOf('cat "$work/schema.sql"'), 'before the schema');
  // The two entries that absorbed the difference are gone: a pg_trgm function with PUBLIC EXECUTE on one side only is reported.
  const publicTrgm = 'acl|ext-member|function public.similarity(text,text)|supabase_admin -> PUBLIC EXECUTE';
  assert.equal(check([], [publicTrgm], 'pg17').unexpected.length, 1);
  assert.equal(check([], [publicTrgm], 'supabase').unexpected.length, 1, 'on the old image too');
  assert.equal(check([], ['acl|ext-member|function public.set_limit(real)|supabase_admin -> PUBLIC EXECUTE'], 'pg17').unexpected.length, 1);
  assert.equal(check([], ['acl|ext-member|function public.set_limit(real)|supabase_admin -> PUBLIC EXECUTE'], 'supabase').unexpected.length, 1);
  assert.equal(check(['acl|ext-member|function public.similarity(text,text)|supabase_admin -> service_role EXECUTE'], [], 'pg17').unexpected.length, 1);
  assert.equal((dump.match(/n\.nspname <> 'extensions'/g) || []).length, 2, 'members in schema extensions are not replayed (functions and relations)');
  // Grants to the roles the new image does not have are not replayed.
  assert.match(dump, /rolname IN \('anon', 'authenticated', 'service_role', 'authenticator', 'supabase_storage_admin', 'pgbouncer', 'supabase_admin'\)/);
  assert.doesNotMatch(dump, /'postgres'|'dashboard_user'/);
});

test('migration 104 drops every foreign key to auth.users: only the two Storage owner keys are absorbed, only on the old image', () => {
  const buckets = 'constraint|storage.buckets|buckets_owner_fkey FOREIGN KEY (owner) REFERENCES auth.users(id) validated t deferrable f initially f';
  assert.equal(check([], [buckets], 'supabase').unexpected.length, 0);
  assert.equal(check([], [buckets], 'pg17').unexpected.length, 1);
  assert.equal(check([], [buckets.replace('storage.buckets|buckets_owner', 'public.customers|customers_owner')], 'supabase').unexpected.length, 1, 'a warehouse table is never absorbed');
  assert.equal(check([], [buckets.replace('REFERENCES auth.users(id)', 'REFERENCES public.user_profiles(id)')], 'supabase').unexpected.length, 1);
});

test('M-1: the pinned bootstrap entries absorb the exact property and nothing wider', () => {
  const ok = (a, b) => assert.equal(check(a, b, 'pg17').unexpected.length, 0, JSON.stringify([a, b]));
  const bad = (a, b, n = 1) => assert.equal(check(a, b, 'pg17').unexpected.length, n, JSON.stringify([a, b]));
  // supabase_storage_admin: NOINHERIT and NOCREATEROLE; INHERIT or CREATEROLE on the new side is reported.
  ok(['role|supabase_storage_admin|rolcreaterole true'], ['role|supabase_storage_admin|rolcreaterole false']);
  bad([], ['role|supabase_storage_admin|rolinherit true']);
  bad([], ['role|supabase_storage_admin|rolcreaterole true']);
  // authenticator: a flipped attribute (bypassrls) or an extra setting is reported; the lost safeupdate is absorbed.
  ok(['setting|role authenticator db *|session_preload_libraries=safeupdate'], []);
  bad([], ['role|authenticator|rolbypassrls true']);
  bad([], ['setting|role authenticator db *|session_preload_libraries=safeupdate']);
  bad([], ['role|supabase_admin|rolsuper false']);
  // memberships: the grantor is absorbed, a changed option is not.
  ok(['member|authenticator in anon|admin f inherit f set t grantor postgres'], ['member|authenticator in anon|admin f inherit f set t grantor supabase_admin']);
  bad([], ['member|authenticator in anon|admin f inherit t set t grantor supabase_admin']);
  bad([], ['member|authenticator in anon|admin f inherit f set f grantor supabase_admin']);
  // the database: the owner is absorbed, the collation is not.
  ok(['database|postgres|owner postgres'], ['database|postgres|owner supabase_admin']);
  bad([], ['database|postgres|collate C']);
  bad([], ['database|postgres|encoding SQL_ASCII']);
  // schema ACLs: the bootstrap's exact grants are absorbed; anything else on the new side is reported.
  ok(['acl|schema|storage|supabase_admin -> authenticated USAGE'], ['acl|schema|storage|supabase_storage_admin -> authenticated USAGE']);
  bad([], ['acl|schema|storage|supabase_storage_admin -> PUBLIC USAGE']);
  bad([], ['acl|schema|storage|supabase_storage_admin -> authenticated CREATE']);
  // pg_stat_statements and its reset ACL: pinned versions and signatures.
  ok(['extension|pg_stat_statements|version 1.10 schema extensions relocatable t owner supabase_admin'], ['extension|pg_stat_statements|version 1.11 schema extensions relocatable t owner supabase_admin']);
  bad([], ['extension|pg_stat_statements|version 1.11 schema public relocatable t owner supabase_admin']);
  bad([], ['acl|ext-member|pg_stat_statements:function extensions.pg_stat_statements_reset(oid,oid,bigint,boolean)|supabase_admin -> PUBLIC EXECUTE']);
  // get_auth: only a definition with NOT usesuper and the pinned search_path.
  const getAuth = def => `function|pgbouncer.get_auth(p_usename text)|kind f owner supabase_admin secdef t volatility v strict f parallel u leakproof f cost 100 rows 1000 config {search_path=pg_catalog} language plpgsql def ${def}`;
  ok([getAuth('A')], [getAuth('BEGIN RETURN QUERY SELECT 1 WHERE usename = p_usename AND NOT usesuper; END')]);
  bad([], [getAuth('BEGIN RETURN QUERY SELECT 1 WHERE usename = p_usename; END')]);
});

test('L-9: an alternative that matches nothing is reported as unused, also when the others still match', () => {
  assert.deepEqual(expandAlternatives('^x\\|(a|b|c)\\|y$'), ['^x\\|a\\|y$', '^x\\|b\\|y$', '^x\\|c\\|y$']);
  assert.deepEqual(expandAlternatives('^x\\|(a|b)?'), ['^x\\|(a|b)?'], 'an optional group is left alone');
  const entries = parseAllowList('# why\nA ^role\\|(alpha|beta)\\|');
  const r = applyAllowList({ onlyA: ['role|alpha|x'], onlyB: [] }, entries, { image: 'pg17' });
  assert.equal(r.unexpected.length, 0);
  assert.deepEqual(r.unused.map(e => e.pattern), ['^role\\|beta\\|']);
});

test('L-4: catalog-diff.mjs refuses to run without --image', () => {
  const r = spawnSync('node', [new URL('../scripts/baseline/catalog-diff.mjs', import.meta.url).pathname, 'a', 'b'], { encoding: 'utf8' });
  assert.equal(r.status, 2);
  assert.match(r.stderr, /--image supabase\|pg17 is required/);
});

test('L-5: the ledger check accepts 0..N with the known gap at 50 and names a gap, a missing tail and a wrong end', () => {
  const run = (numbers, last) => spawnSync('awk', ['-v', `last=${last}`, '-f', new URL('../scripts/baseline/check-ledger.awk', import.meta.url).pathname], { input: numbers.join('\n') + '\n', encoding: 'utf8' });
  const upTo = (n, skip = []) => Array.from({ length: n + 1 }, (_, i) => i).filter(i => !skip.includes(i));
  assert.equal(run(upTo(110, [50]), 110).status, 0);
  assert.match(run(upTo(110, [50, 101]), 110).stdout, /Gap in the migration chain: 100 is followed by 102/);
  assert.match(run(upTo(110, [50]), 111).stdout, /The chain ends at 110, expected --expect-last 111/);
  assert.match(run(upTo(110, [50, 109, 110]), 110).stdout, /The chain ends at 108/);
  assert.equal(run(upTo(110, [49, 50]), 110).status, 1, 'only the single gap at 50 is known');
});

test('L-1/L-5: a sequence set with is_called false differs from one that stays at its start; the dump writes the real state', () => {
  assert.equal(check(['seqstate|public.s|last_value 1 is_called false'], ['seqstate|public.s|last_value 5 is_called false'], 'pg17').unexpected.length, 2);
  assert.equal(check(['seqstate|public.s|last_value 7 is_called true'], ['seqstate|public.s|last_value 7 is_called false'], 'supabase').unexpected.length, 2);
  const dump = read('dump-baseline.sh');
  assert.match(dump, /setval\(%L, %s, %s\)/);
  assert.match(dump, /\(xpath\('\/row\/is_called\/text\(\)', st\.x\)\)\[1\]::text/);
  assert.match(read('seed-dump.sql'), /is_called %s/);
});

test('L-5: damage in an allow-listed family is still reported on both images (a widened grant, RLS, a disabled trigger, a bootstrap attribute)', () => {
  for (const image of ['supabase', 'pg17']) {
    const trgm = 'acl|ext-member|pg_trgm:function public.similarity(text,text)|supabase_admin ->';
    assert.equal(check([`${trgm} service_role EXECUTE`], [`${trgm} PUBLIC EXECUTE`], image).unexpected.length, 2, 'a deleted REVOKE ALL ... FROM PUBLIC widens the function');
    assert.equal(check(['relation|public.t|kind r owner supabase_admin persistence p rls true forced false'], ['relation|public.t|kind r owner supabase_admin persistence p rls false forced false'], image).unexpected.length, 2);
    assert.equal(check(['policy|public.t|p1 permissive'], [], image).unexpected.length, 1);
    assert.equal(check(['trigger|public.t|trg tgenabled O'], ['trigger|public.t|trg tgenabled D'], image).unexpected.length, 2);
  }
  assert.equal(check(['role|authenticator|rolbypassrls false'], ['role|authenticator|rolbypassrls true'], 'pg17').unexpected.length, 2);
});

test('L-8: container names have a random suffix also without openssl, and never an empty one', () => {
  const r = spawnSync('/usr/bin/env', ['-i', 'PATH=/nonexistent', '/bin/bash', '-c', `source ${new URL('../scripts/baseline/lib.sh', import.meta.url).pathname}; new_name chain`], { encoding: 'utf8' });
  assert.match(r.stdout.trim(), /^slim-tool-chain-[0-9a-f]{8}$/, r.stderr);
});

test('L-6/L-7: the dump script writes through files (a failed query stops it), cleans its temporary file and makes the seed part transaction-local', () => {
  const dump = read('dump-baseline.sh');
  assert.doesNotMatch(dump, /< <\(/, 'no process substitution hides a failed query');
  assert.match(dump, /trap 'rm -rf "\$work" "\$out\.tmp"' EXIT/);
  assert.match(dump, /SET LOCAL session_replication_role = origin;/);
  assert.doesNotMatch(dump, /RESET session_replication_role/);
  assert.match(dump, /The seed rows hold a psql meta command or a session setting/);
});
