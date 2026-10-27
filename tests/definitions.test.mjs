import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, readdirSync, rmSync, statSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { migrationPlan, definitionProblems } from '../scripts/migration-plan.mjs';

// migrations/definitions/: functions that setup applies again after the numbered files whenever a file's checksum changes
// (scripts/migration-plan.mjs). tests/migrations.sh proves the database side (the same catalog as the chain alone, a changed file applied, an
// unchanged one skipped); these tests prove the plan and the rules for a file.
const root = new URL('..', import.meta.url).pathname;
const directory = join(root, 'migrations', 'definitions');
const files = readdirSync(directory).sort();

function copyRoot(definitions) {
  const dir = mkdtempSync(join(tmpdir(), 'warehouse-definitions-'));
  mkdirSync(join(dir, 'migrations', 'definitions'), { recursive: true });
  writeFileSync(join(dir, 'migrations', '00000000000001_one.sql'), 'SELECT 1;\n');
  for (const [name, sql] of Object.entries(definitions)) writeFileSync(join(dir, 'migrations', 'definitions', name), sql);
  return dir;
}
const FUNCTION = 'CREATE OR REPLACE FUNCTION public.probe() RETURNS integer LANGUAGE sql AS $$ SELECT 1 $$;\nREVOKE ALL ON FUNCTION public.probe() FROM PUBLIC;\n';

test('the definition files are plain .sql files, authorize_rpc first, and every one passes the content rule', () => {
  assert.ok(statSync(directory).isDirectory());
  assert.ok(files.length >= 12);
  assert.equal(files[0], '00_authorize_rpc.sql', 'authorize_rpc is applied before every function that calls it');
  for (const name of files) {
    assert.match(name, /^[a-z0-9_]+\.sql$/);
    const sql = readFileSync(join(directory, name), 'utf8');
    assert.deepEqual(definitionProblems(sql), [], name);
    assert.match(sql, /^-- .*\n/, `${name}: starts with the comment that says where it is applied`);
    assert.equal((sql.match(/^CREATE OR REPLACE FUNCTION /gm) ?? []).length, 1, `${name}: one function per file`);
    assert.match(sql, /\n SET search_path TO /, `${name}: the function carries its search_path`);
    assert.match(sql, /\nREVOKE ALL ON FUNCTION /, `${name}: states its grants (revoke first)`);
  }
});

test('the plan applies the definitions after the last numbered file, in name order, each in its own transaction', () => {
  const plan = migrationPlan(root);
  const lastNumbered = plan.lastIndexOf('\\echo Applying: ');
  const table = plan.indexOf('CREATE TABLE IF NOT EXISTS warehouse_migrations.definitions');
  const order = [...plan.matchAll(/\\echo Applying definition: (\S+)/g)].map(match => match[1]);
  assert.deepEqual(order, files);
  assert.ok(lastNumbered < table && table < plan.indexOf('\\echo Applying definition: '));
  for (const block of plan.split('\\echo Applying definition: ').slice(1)) {
    const name = block.split('\n')[0];
    const sql = readFileSync(join(directory, name), 'utf8');
    const checksum = createHash('sha256').update(sql).digest('hex');
    assert.ok(block.startsWith(`${name}\n  BEGIN;\n  SET LOCAL lock_timeout = '10s';\n${sql}`), `${name}: inside the transaction, after the lock timeout`);
    assert.match(block, new RegExp(`INSERT INTO warehouse_migrations\\.definitions\\(name,checksum\\) VALUES \\('${name}','${checksum}'\\)\\n    ON CONFLICT \\(name\\) DO UPDATE SET checksum=EXCLUDED\\.checksum, applied_at=now\\(\\);\\n  COMMIT;\\n  NOTIFY pgrst, 'reload schema';\\n\\\\endif`), `${name}: the row and the schema reload`);
  }
  assert.equal(plan.split('\\echo Definition unchanged: ').length - 1, files.length, 'a file with the stored checksum is skipped with a line');
  assert.ok(plan.trimEnd().endsWith("NOTIFY pgrst, 'reload schema';\nSELECT pg_advisory_unlock(71041);"), 'the final reload and the unlock stay at the end');
});

test('the checksum in the plan follows the file: a changed definition is a different plan', () => {
  const a = copyRoot({ 'probe.sql': FUNCTION });
  const b = copyRoot({ 'probe.sql': FUNCTION.replace('SELECT 1', 'SELECT 2') });
  try {
    const sum = text => createHash('sha256').update(text).digest('hex');
    assert.ok(migrationPlan(a).includes(`checksum='${sum(FUNCTION)}'`));
    assert.ok(migrationPlan(b).includes(`checksum='${sum(FUNCTION.replace('SELECT 1', 'SELECT 2'))}'`));
    assert.ok(!migrationPlan(b).includes(sum(FUNCTION)));
  } finally { rmSync(a, { recursive: true, force: true }); rmSync(b, { recursive: true, force: true }); }
});

test('--through stops before the definitions, and a directory without definitions has no definition step', () => {
  const through = migrationPlan(root, { through: '00000000000000_baseline.sql' });
  assert.ok(!through.includes('warehouse_migrations.definitions') && !through.includes('Applying definition'));
  const bare = mkdtempSync(join(tmpdir(), 'warehouse-definitions-'));
  try {
    mkdirSync(join(bare, 'migrations'));
    writeFileSync(join(bare, 'migrations', '00000000000001_one.sql'), 'SELECT 1;\n');
    assert.ok(!migrationPlan(bare).includes('definitions'));
  } finally { rmSync(bare, { recursive: true, force: true }); }
});

test('a definition file that holds anything but function statements is refused before a plan exists', () => {
  const cases = {
    table: 'CREATE TABLE public.sneaky (id int);\n',
    'table after a function': `${FUNCTION}CREATE TABLE public.sneaky (id int);\n`,
    insert: `${FUNCTION}INSERT INTO public.items VALUES (1);\n`,
    do_block: "DO $x$ BEGIN DROP TABLE public.items; END $x$;\n",
    drop_function: 'DROP FUNCTION public.probe();\n',
    alter_table: 'ALTER TABLE public.items ADD COLUMN x int;\n',
    set_schema: 'ALTER FUNCTION public.probe() SET SCHEMA other;\n',
    owner: 'ALTER FUNCTION public.probe() OWNER TO postgres;\n',
    grant_table: 'GRANT SELECT ON TABLE public.items TO anon;\n',
    psql_command: `${FUNCTION}\\! id\n`,
    psql_command_after_a_grant: 'GRANT EXECUTE ON FUNCTION public.probe() TO anon\n\\! id\n',
    unterminated: "CREATE OR REPLACE FUNCTION public.probe() RETURNS integer LANGUAGE sql AS $$ SELECT 1;\n",
  };
  for (const [label, sql] of Object.entries(cases)) {
    const dir = copyRoot({ 'probe.sql': sql });
    try {
      assert.throws(() => migrationPlan(dir), /migrations\/definitions\/probe\.sql holds more than function definitions/, label);
    } finally { rmSync(dir, { recursive: true, force: true }); }
  }
  const dir = copyRoot({ 'Bad-Name.sql': FUNCTION });
  try { assert.throws(() => migrationPlan(dir), /Invalid definition filename: Bad-Name\.sql/); } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('what a definition file may hold passes, also text that only looks like another statement', () => {
  const allowed = [
    FUNCTION,
    "CREATE OR REPLACE FUNCTION public.probe() RETURNS text LANGUAGE sql AS $f$ SELECT 'a; CREATE TABLE x (id int); b' $f$;\n",
    "CREATE OR REPLACE FUNCTION public.probe() RETURNS text LANGUAGE sql AS $$ SELECT E'it''s; \\' DROP TABLE x;' $$;\n",
    "-- CREATE TABLE in a comment; DROP TABLE x;\n/* DO $$ x $$; /* nested */ */\nCOMMENT ON FUNCTION public.probe() IS 'a; DROP TABLE t';\n",
    'GRANT EXECUTE ON FUNCTION public.probe() TO authenticated;\nREVOKE ALL ON FUNCTION public.probe() FROM PUBLIC, anon;\n',
    "ALTER FUNCTION public.probe() SET search_path TO 'pg_catalog', 'public';\nALTER FUNCTION public.probe() SET jit = off;\n",
    '',
  ];
  for (const sql of allowed) assert.deepEqual(definitionProblems(sql), [], sql);
});

const refusal = (sql, pattern, label) => {
  const dir = copyRoot({ 'probe.sql': sql });
  try { assert.throws(() => migrationPlan(dir), pattern, label); } finally { rmSync(dir, { recursive: true, force: true }); }
};

test('every statement of a definition file names the function of its REVOKE ALL line; a file without that line is refused', () => {
  const head = 'CREATE OR REPLACE FUNCTION public.probe() RETURNS integer LANGUAGE sql AS $$ SELECT 1 $$;\n';
  const revoke = 'REVOKE ALL ON FUNCTION public.probe() FROM PUBLIC;\n';
  const other = {
    'another function created': `${head}${revoke}CREATE OR REPLACE FUNCTION public.other() RETURNS integer LANGUAGE sql AS $$ SELECT 2 $$;\n`,
    'another function granted': `${head}${revoke}GRANT EXECUTE ON FUNCTION public.other() TO anon;\n`,
    'another function revoked': `${head}${revoke}REVOKE ALL ON FUNCTION public.other() FROM PUBLIC;\n`,
    'another schema': `${head}${revoke}GRANT EXECUTE ON FUNCTION warehouse_security.probe() TO anon;\n`,
    'another signature granted': `${head}${revoke}GRANT EXECUTE ON FUNCTION public.probe(text) TO anon;\n`,
    'another function commented': `${head}${revoke}COMMENT ON FUNCTION public.other() IS 'x';\n`,
    'another function altered': `${head}${revoke}ALTER FUNCTION public.other() SET jit = off;\n`,
    'a second function created before the line': `${head}CREATE OR REPLACE FUNCTION public.other() RETURNS integer LANGUAGE sql AS $$ SELECT 2 $$;\n${revoke}`,
    'two statements for two functions, no REVOKE ALL': `${head}CREATE OR REPLACE FUNCTION public.other() RETURNS integer LANGUAGE sql AS $$ SELECT 2 $$;\n`,
    'a list of functions in one GRANT': `${head}${revoke}GRANT EXECUTE ON FUNCTION public.probe(), public.other() TO anon;\n`,
  };
  for (const [label, sql] of Object.entries(other)) refusal(sql, /migrations\/definitions\/probe\.sql holds more than function definitions, or a statement about another function/, label);
  refusal(head, /migrations\/definitions\/probe\.sql needs a line REVOKE ALL ON FUNCTION/, 'no REVOKE ALL line');
  refusal('CREATE OR REPLACE FUNCTION probe() RETURNS integer LANGUAGE sql AS $$ SELECT 1 $$;\nREVOKE ALL ON FUNCTION probe() FROM PUBLIC;\n', /holds more than function definitions/, 'a name without a schema');
  refusal('CREATE OR REPLACE FUNCTION public."Probe"() RETURNS integer LANGUAGE sql AS $$ SELECT 1 $$;\nREVOKE ALL ON FUNCTION public."Probe"() FROM PUBLIC;\n', /holds more than function definitions/, 'a quoted name');
  // The same function, spelled differently, is the same function.
  assert.deepEqual(definitionProblems(`${head}${revoke}GRANT EXECUTE ON FUNCTION PUBLIC.Probe(  ) TO service_role;\nCOMMENT ON FUNCTION public.probe() IS 'ok';\n`), []);
  assert.deepEqual(definitionProblems('REVOKE ALL ON FUNCTION public.f(character  varying, timestamp with time zone) FROM PUBLIC;\nGRANT EXECUTE ON FUNCTION public.f(character varying,timestamp with time zone) TO anon;\n'), []);
});

test('ALTER FUNCTION passes only as SET/RESET of a parameter: an argument named set, OWNER, RENAME, SET SCHEMA, SECURITY and DEPENDS are refused', () => {
  const refused = [
    'ALTER FUNCTION public.probe(x int, set text) OWNER TO evil;',
    'ALTER FUNCTION public.probe(set int) RENAME TO other;',
    'ALTER FUNCTION public.probe() SET SCHEMA evil;',
    'ALTER FUNCTION public.probe() RENAME TO g;',
    'ALTER FUNCTION public.probe() OWNER TO postgres;',
    'ALTER FUNCTION public.probe() DEPENDS ON EXTENSION plpgsql;',
    'ALTER FUNCTION public.probe() SECURITY INVOKER;',
    'ALTER FUNCTION public.probe() SECURITY DEFINER SET search_path TO public;',
    'ALTER FUNCTION public.probe() SET search_path TO public SECURITY DEFINER;',
    'ALTER FUNCTION public.probe() SET search_path TO public OWNER TO evil;',
    'ALTER FUNCTION public.probe() STRICT;',
    'ALTER FUNCTION public.probe(',
    'ALTER FUNCTION public.probe() SET',
  ];
  for (const sql of refused) assert.notDeepEqual(definitionProblems(`${sql}\n`), [], sql);
  for (const sql of ['ALTER FUNCTION public.probe(set text) SET jit = off;', 'ALTER FUNCTION public.probe() SET search_path TO pg_catalog, public SET jit TO off;', 'ALTER FUNCTION public.probe() RESET ALL;', 'ALTER FUNCTION public.probe() RESET jit;']) {
    assert.deepEqual(definitionProblems(`${sql}\n`), [], sql);
  }
});

test('the SECURITY DEFINER or INVOKER of every definition is pinned here: changing it takes an edit of this list in the same commit', () => {
  const invokers = ['apply_grn_rates.sql'];
  for (const name of files) {
    const sql = readFileSync(join(directory, name), 'utf8');
    const header = sql.slice(sql.indexOf('CREATE OR REPLACE FUNCTION'), sql.indexOf('AS $'));
    const invoker = invokers.includes(name);
    assert.equal(/\bSECURITY\s+DEFINER\b/i.test(header), !invoker, `${name}: SECURITY DEFINER as pinned`);
    if (!invoker) assert.equal(/\bSECURITY\s+INVOKER\b/i.test(header), false, `${name}: not also SECURITY INVOKER`);
  }
});

test('the plan stops at a definition whose function is gone, and rolls back one that would add an overload; each message names the file', () => {
  const plan = migrationPlan(root);
  for (const name of files) {
    const sql = readFileSync(join(directory, name), 'utf8');
    const identity = /\nREVOKE ALL ON FUNCTION (.+?) FROM /.exec(sql)[1];
    const block = plan.slice(plan.indexOf(`to_regprocedure('${identity}')`));
    assert.match(block.split('\\echo Applying definition: ')[0], new RegExp(`defn_exists[^]*RAISE EXCEPTION 'migrations/definitions/${name}: ${identity.replace(/[()[\].]/g, '\\$&')} does not exist`), name);
    assert.ok(plan.indexOf(`to_regprocedure('${identity}')`) < plan.indexOf(`\\echo Applying definition: ${name}`), `${name}: checked before it is applied`);
    assert.ok(plan.indexOf(`\\echo Applying definition: ${name}`) < plan.indexOf(`RAISE EXCEPTION 'migrations/definitions/${name}: the file would add another`), `${name}: overloads counted after the file ran`);
  }
});

test('a migration forgets the recorded definitions in its own transaction; a plan with no definitions, and --through, have no such step; rows of removed files are deleted', () => {
  const plan = migrationPlan(root);
  const forget = "DO $$ BEGIN IF to_regclass('warehouse_migrations.definitions') IS NOT NULL THEN DELETE FROM warehouse_migrations.definitions; END IF; END $$;";
  const applyingNumbered = plan.split('\\echo Applying: ').slice(1);
  assert.ok(applyingNumbered.length > 0);
  for (const block of applyingNumbered) {
    const body = block.slice(0, block.indexOf('\\endif'));
    assert.ok(body.indexOf(forget) > 0 && body.indexOf(forget) < body.indexOf('INSERT INTO warehouse_migrations.applied') && body.indexOf('COMMIT;') > body.indexOf(forget), 'inside the migration\'s transaction, before its ledger row');
  }
  assert.ok(!migrationPlan(root, { through: '00000000000000_baseline.sql' }).includes("to_regclass('warehouse_migrations.definitions')"));
  const dir = copyRoot({});
  try { assert.ok(!migrationPlan(dir).includes('warehouse_migrations.definitions')); } finally { rmSync(dir, { recursive: true, force: true }); }
  const cleanup = plan.slice(plan.lastIndexOf('DELETE FROM warehouse_migrations.definitions WHERE'));
  assert.match(cleanup, new RegExp(`name <> ALL \\(ARRAY\\[${files.map(name => `'${name}'`).join(', ')}\\]::text\\[\\]\\);\\nNOTIFY pgrst`));
  assert.ok(plan.lastIndexOf('DELETE FROM warehouse_migrations.definitions WHERE') > plan.lastIndexOf('\\echo Applying definition: '), 'after the last definition');
});

// A function that has a definition file is changed in that file. A numbered migration above 126 that creates or replaces it, alters it, comments
// it, or patches its text with pg_get_functiondef would be overwritten on a new install and kept on a facility; one that drops the signature
// the file holds would leave the file bringing the function back. DROP of another signature, and CREATE FUNCTION (no OR REPLACE) of a new one
// followed by a REVOKE on it (a new function is executable by PUBLIC until then), are how a signature changes, and the plan checks the file against the database.
function definitionConflicts(migrations, definitions) {
  const found = [];
  const identities = Object.entries(definitions).map(([file, sql]) => {
    const identity = /\nREVOKE ALL ON FUNCTION (.+?) FROM /.exec(sql)[1];
    return { file, identity, name: identity.slice(0, identity.indexOf('(')), bare: identity.slice(identity.indexOf('.') + 1, identity.indexOf('(')) };
  });
  for (const [migration, text] of Object.entries(migrations)) {
    if (!(Number(migration.split('_')[0]) > 126)) continue;
    const sql = text.replace(/\/\*[^]*?\*\//g, ' ').replace(/--.*$/gm, ' ').replace(/\s+/g, ' ');
    for (const { file, identity, name, bare } of identities) {
      const ref = `(?:${name.replace('.', '\\.')}|${bare})`;
      const types = identity.slice(identity.indexOf('(')).replace(/[()[\]]/g, '\\$&').replace(/,/g, '\\s*,\\s*');
      for (const [what, pattern] of [
        ['creates or replaces it', `CREATE OR REPLACE FUNCTION ${ref}\\s*\\(`],
        ['alters it', `ALTER FUNCTION ${ref}\\s*\\(`],
        ['comments on it', `COMMENT ON FUNCTION ${ref}\\s*\\(`],
        ['patches its text', `pg_get_functiondef\\([^;]*${ref}\\s*\\(`],
        ['changes its grants', `GRANT [^;]*? ON FUNCTION ${ref}${types}`],
        [`drops it (remove ${file} in the same commit)`, `DROP FUNCTION (?:IF EXISTS )?${ref}${types}`],
      ]) {
        if (new RegExp(pattern, 'i').test(sql)) found.push(`${migration} ${what}: ${identity} is defined in migrations/definitions/${file}`);
      }
    }
  }
  return found;
}

test('no numbered migration above 126 changes or drops a function that has a definition file', () => {
  const migrations = Object.fromEntries(readdirSync(join(root, 'migrations')).filter(name => name.endsWith('.sql')).map(name => [name, readFileSync(join(root, 'migrations', name), 'utf8')]));
  const definitions = Object.fromEntries(files.map(name => [name, readFileSync(join(directory, name), 'utf8')]));
  assert.deepEqual(definitionConflicts(migrations, definitions), []);
});

test('the check for a migration that changes a defined function finds each kind, and lets a new signature and old migrations through', () => {
  const definitions = { 'save_grn.sql': 'CREATE OR REPLACE FUNCTION public.save_grn(p_a uuid, p_b text) RETURNS void LANGUAGE sql AS $$ SELECT 1 $$;\nREVOKE ALL ON FUNCTION public.save_grn(uuid,text) FROM PUBLIC;\n' };
  const at = (n, text) => ({ [`${String(n).padStart(14, '0')}_x.sql`]: text });
  for (const text of [
    'CREATE OR REPLACE FUNCTION public.save_grn(p_a uuid, p_b text) RETURNS void LANGUAGE sql AS $$ SELECT 2 $$;',
    'create or replace function save_grn(a int) returns void language sql as $$ select 2 $$;',
    'ALTER FUNCTION public.save_grn(uuid, text) SET jit = off;',
    "COMMENT ON FUNCTION public.save_grn(uuid,text) IS 'x';",
    "DO $patch$ DECLARE d text := pg_get_functiondef('public.save_grn(uuid,text)'::regprocedure); BEGIN NULL; END $patch$;",
    'GRANT EXECUTE ON FUNCTION public.save_grn(uuid, text) TO anon;',
    'DROP FUNCTION public.save_grn(uuid, text);',
    'DROP FUNCTION IF EXISTS save_grn(uuid,text);',
  ]) assert.equal(definitionConflicts(at(127, text), definitions).length, 1, text);
  for (const text of [
    'DROP FUNCTION public.save_grn(uuid);\nCREATE FUNCTION public.save_grn(p_a uuid, p_c integer) RETURNS void LANGUAGE sql AS $$ SELECT 3 $$;\nGRANT EXECUTE ON FUNCTION public.save_grn(uuid,integer) TO service_role;',
    'DROP FUNCTION public.save_grn(uuid);\nCREATE FUNCTION public.save_grn(p_a uuid, p_text text) RETURNS void LANGUAGE sql AS $$ SELECT 3 $$;\nREVOKE ALL ON FUNCTION public.save_grn(uuid,text) FROM PUBLIC, anon, authenticated;',
    '-- CREATE OR REPLACE FUNCTION public.save_grn( is only named here\nSELECT 1;',
    'CREATE OR REPLACE FUNCTION public.save_grn_other(p_a uuid) RETURNS void LANGUAGE sql AS $$ SELECT 3 $$;',
  ]) assert.deepEqual(definitionConflicts(at(127, text), definitions), [], text);
  assert.deepEqual(definitionConflicts(at(126, 'ALTER FUNCTION public.save_grn(uuid, text) SET jit = off;'), definitions), [], 'the history up to 126 is as it is');
});
