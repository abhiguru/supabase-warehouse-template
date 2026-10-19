import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { parseLines, diffLines, parseAllowList, applyAllowList, formatReport, normaliseOwnerFacts } from '../scripts/baseline/catalog-diff.mjs';
import { editDump, splitBlocks, namesRemovedRole, DEFAULT_REMOVED_ROLES, chainCreatedRoles } from '../scripts/baseline/edit-dump.mjs';

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
  assert.ok(realEntries().length > 10);
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
  const bOnly = ['schema|vault|owner supabase_admin', 'extension|pg_net|version 0.8 schema extensions relocatable false owner x', 'publication|supabase_realtime|owner x all f ins t upd t del t trunc t',
    'eventtrigger|issue_pg_net_access|event ddl_command_end', 'acl|schema|graphql|supabase_admin -> anon USAGE'];
  assert.equal(check([], bOnly, 'supabase').unexpected.length, 0);
  assert.equal(check([], bOnly, 'pg17').unexpected.length, bOnly.length);
});

test('M1: an entry that applies to the run and matches nothing is unused; entries of the other image are not counted', () => {
  const r = check([], [], 'pg17');
  assert.ok(r.unused.length > 0 && r.unused.every(e => e.image !== 'supabase'));
  assert.ok(check([], [], 'supabase').unused.every(e => e.image !== 'pg17'));
});

test('L6: MAINTAIN is allowed for named roles on relations only, never PUBLIC or columns; a trailing-space regex is not relied on', () => {
  assert.equal(check([], ['acl|relation|public.t|supabase_admin -> anon MAINTAIN'], 'pg17').unexpected.length, 0);
  assert.equal(check([], ['acl|relation|public.t|supabase_admin -> PUBLIC MAINTAIN'], 'pg17').unexpected.length, 1);
  assert.equal(check([], ['acl|column|public.t.c|supabase_admin -> anon MAINTAIN'], 'pg17').unexpected.length, 1);
  assert.equal(check(['acl|relation|public.t|supabase_admin -> postgresql_x SELECT'], [], 'supabase').unexpected.length, 1, 'a role that merely starts with postgres');
  assert.equal(check(['acl|relation|public.t|supabase_admin -> postgres SELECT'], [], 'supabase').unexpected.length, 0);
  assert.equal(check(['acl|ext-member|function extensions.f()|supabase_admin -> dashboard_user EXECUTE'], [], 'supabase').unexpected.length, 0);
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
test('M8: the removed roles include warehouse_monitoring and warehouse_list_refresher; only warehouse_* are chain-created', () => {
  assert.ok(DEFAULT_REMOVED_ROLES.includes('warehouse_monitoring') && DEFAULT_REMOVED_ROLES.includes('warehouse_list_refresher'));
  assert.deepEqual(chainCreatedRoles(DEFAULT_REMOVED_ROLES).sort(), ['warehouse_list_refresher', 'warehouse_monitoring']);
});

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

test('L6: the db image pin of lib.sh is the one tests/migrations.sh uses', () => {
  const pin = read('lib.sh').match(/^DEFAULT_DB_IMAGE='([^']+)'/m)[1];
  assert.ok(readFileSync(new URL('../tests/migrations.sh', import.meta.url), 'utf8').includes(pin));
});
