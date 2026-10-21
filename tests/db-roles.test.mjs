import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, readFileSync, readdirSync, rmSync, statSync, writeFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  DB_ROLE_LOGINS, GENERATED_DB_NAMES, SUPERUSER_ROLES, addMissingDbValues, checkInput,
  addMissingDbValuesToFile, normalizeRestoredEnvFile, generatedDbValues, psqlPrelude, scramVerifier, stageRotatedDbEnv, validateDbValues,
} from '../scripts/db-roles.mjs';

const read = path => readFileSync(new URL(`../${path}`, import.meta.url), 'utf8');
const superuser = 'f'.repeat(64);
const env = () => ({ POSTGRES_PASSWORD: superuser, ...generatedDbValues() });

test('a SCRAM verifier is the one PostgreSQL stores for the same password and salt', () => {
  // Made by PostgreSQL 15 (the pinned database image) with
  // CREATE ROLE ... PASSWORD 'pencil-warehouse-fictional-1' under password_encryption = scram-sha-256.
  const fromPostgres = 'SCRAM-SHA-256$4096:8WBDgsReGTftlFR6b23vgw==$LfwZYSYOJpHqPEaagAIhB5EJnD8comM+zIKsGqOlkYI=:bivU0djzsH34HH4TQZSoXiU859N2tc0D2R3R92fwZ0w=';
  const salt = Buffer.from(fromPostgres.split(':')[1].split('$')[0], 'base64');
  assert.equal(scramVerifier('pencil-warehouse-fictional-1', salt), fromPostgres);
  assert.notEqual(scramVerifier('pencil-warehouse-fictional-2', salt), fromPostgres);
  // A new salt every time: two verifiers of one password differ, and neither contains it.
  const [a, b] = [scramVerifier('pencil-warehouse-fictional-1'), scramVerifier('pencil-warehouse-fictional-1')];
  assert.notEqual(a, b);
  assert.doesNotMatch(a, /pencil/);
});

test('generated values: one 64-hex password per login, all distinct', () => {
  const values = generatedDbValues();
  assert.deepEqual(Object.keys(values).sort(), [...GENERATED_DB_NAMES].sort());
  for (const { env: name } of DB_ROLE_LOGINS) assert.match(values[name], /^[0-9a-f]{64}$/, name);
  assert.equal(new Set(Object.values(values)).size, GENERATED_DB_NAMES.length);
  assert.notDeepEqual(generatedDbValues(), values);
});

test('validation refuses a missing, malformed or shared password', () => {
  const good = env();
  validateDbValues(good);
  const name = DB_ROLE_LOGINS[0].env;
  assert.throws(() => validateDbValues({ ...good, [name]: undefined }), new RegExp(`Invalid ${name}: run setup.sh`));
  assert.throws(() => validateDbValues({ ...good, [name]: 'generated-by-setup' }), new RegExp(`Invalid ${name}`));
  assert.throws(() => validateDbValues({ ...good, [name]: 'p@ss/word'.repeat(5) }), new RegExp(`Invalid ${name}`));
  assert.throws(() => validateDbValues({ ...good, [name]: superuser }), /repeats POSTGRES_PASSWORD/);
  assert.throws(() => validateDbValues({ ...good, [DB_ROLE_LOGINS[1].env]: good[name] }), new RegExp(`repeats ${name}`));
});

test('missing values are added, present ones never replaced, an empty line is filled in place', () => {
  const values = env();
  const full = Object.entries(values).map(([key, value]) => `${key}=${value}`).join('\n') + '\n';
  assert.deepEqual(addMissingDbValues(full), { text: full, added: [] });
  // A state written by the previous release: only POSTGRES_PASSWORD and other lines.
  const older = `POSTGRES_PASSWORD=${superuser}\nKONG_HTTP_PORT=18000\n`;
  const upgraded = addMissingDbValues(older);
  assert.deepEqual(upgraded.added, GENERATED_DB_NAMES);
  assert.ok(upgraded.text.startsWith(older), 'existing lines stay where they were');
  const lines = upgraded.text.slice(older.length).trimEnd().split('\n');
  assert.deepEqual(lines.map(line => line.split('=')[0]), GENERATED_DB_NAMES);
  // No final newline in the old file: the first added line still starts on its own.
  assert.ok(addMissingDbValues(older.trimEnd()).text.startsWith(`${older}${GENERATED_DB_NAMES[0]}=`));
  const blank = full.replace(new RegExp(`^${DB_ROLE_LOGINS[2].env}=.*$`, 'm'), `${DB_ROLE_LOGINS[2].env}=`);
  const filled = addMissingDbValues(blank);
  assert.deepEqual(filled.added, [DB_ROLE_LOGINS[2].env]);
  assert.equal(filled.text.split('\n').length, full.split('\n').length);
  assert.match(filled.text, new RegExp(`^${DB_ROLE_LOGINS[2].env}=[0-9a-f]{64}$`, 'm'));
});

test('the psql prelude carries verifiers only, one per login, and the superuser pair only on request', () => {
  const values = env();
  const prelude = psqlPrelude(values);
  for (const value of Object.values(values)) assert.equal(prelude.includes(value), false, 'no password in the prelude');
  const variables = [...prelude.matchAll(/^\\set ([a-z_]+) 'SCRAM-SHA-256\$4096:[A-Za-z0-9+/]{22}==\$[A-Za-z0-9+/]{43}=:[A-Za-z0-9+/]{43}='$/gm)].map(match => match[1]);
  assert.deepEqual(variables, DB_ROLE_LOGINS.map(({ variable }) => variable));
  assert.equal(prelude.split('\n').filter(Boolean).length, DB_ROLE_LOGINS.length);
  const withSuperuser = psqlPrelude(values, { superuser: true });
  assert.deepEqual([...withSuperuser.matchAll(/^\\set ([a-z_]+) /gm)].map(match => match[1]),
    [...DB_ROLE_LOGINS.map(({ variable }) => variable), ...SUPERUSER_ROLES.map(({ variable }) => variable)]);
  assert.throws(() => psqlPrelude({ ...values, [DB_ROLE_LOGINS[0].env]: superuser }), /repeats POSTGRES_PASSWORD/);
  assert.equal(checkInput(values).split('\n')[0], superuser);
  assert.deepEqual(checkInput(values).trimEnd().split('\n').slice(1).map(line => line.split('\t')[0]), DB_ROLE_LOGINS.map(({ role }) => role));
});

test('configure-db-roles.sql, roles.sql and Compose name the same logins as scripts/db-roles.mjs', () => {
  const sql = read('scripts/configure-db-roles.sql');
  const altered = [...sql.matchAll(/^ALTER ROLE ([a-z_]+) WITH LOGIN PASSWORD :'([a-z_]+)';$/gm)].map(match => [match[1], match[2]]);
  assert.deepEqual(altered, DB_ROLE_LOGINS.map(({ role, variable }) => [role, variable]));
  for (const { variable } of [...DB_ROLE_LOGINS, ...SUPERUSER_ROLES]) assert.match(sql, new RegExp(`:\\{\\?${variable}\\}`), `${variable} is checked before use`);
  assert.deepEqual([...sql.matchAll(/^ALTER ROLE ([a-z_]+) WITH PASSWORD :'([a-z_]+)';$/gm)].map(match => [match[1], match[2]]),
    SUPERUSER_ROLES.map(({ role, variable }) => [role, variable]));
  // Every statement that carries a verifier is in the one transaction, after tracking is switched off.
  const body = sql.slice(sql.indexOf('\nBEGIN;'), sql.indexOf('\nCOMMIT;'));
  assert.ok(body.indexOf("SET LOCAL pg_stat_statements.track = 'none'") < body.indexOf('ALTER ROLE'));
  assert.equal((sql.match(/ALTER ROLE [a-z_]+ WITH (?:LOGIN )?PASSWORD :'/g) ?? []).length, (body.match(/ALTER ROLE [a-z_]+ WITH (?:LOGIN )?PASSWORD :'/g) ?? []).length);
  // Only the roles of the agreed set exist: nothing is altered or dropped for a role of the earlier image.
  assert.doesNotMatch(sql, /supabase_functions_admin|supabase_auth_admin|warehouse_monitoring|DROP ROLE|ALTER ROLE postgres|postgres_verifier/);
  assert.deepEqual(SUPERUSER_ROLES, [{ role: 'supabase_admin', variable: 'supabase_admin_verifier' }], 'supabase_admin is the only superuser login');
  assert.deepEqual(DB_ROLE_LOGINS.map(({ role }) => role).sort(), ['authenticator', 'pgbouncer', 'supabase_storage_admin']);
  assert.doesNotMatch(sql, /monitoring_verifier|LOGIN PASSWORD :'monitoring/, 'the monitoring login has no password any more (migration 107)');
  // roles.sql (first start) takes the three logins that exist before the migrations from the db environment.
  const roles = read('docker/volumes/db/roles.sql');
  const compose = read('docker/docker-compose.yml');
  const db = compose.slice(compose.indexOf('\n  db:\n'), compose.indexOf('\n  # Connection pooler'));
  for (const { env: name, role } of DB_ROLE_LOGINS) {
    assert.match(roles, new RegExp(`\`echo "\\$${name}"\``), `roles.sql reads ${name}`);
    assert.match(roles, new RegExp(`^ALTER USER ${role} WITH PASSWORD :'`, 'm'), `roles.sql sets ${role}`);
    assert.match(db, new RegExp(`\\n      ${name}: \\$\\{${name}:\\?[^}]+\\}\\n`), `the db service passes ${name}`);
  }
  assert.doesNotMatch(roles, /WITH PASSWORD :'superuser_password'/, 'no login is given the superuser password');
  // Each service names its own value, with :? so a state without it fails at `compose config`.
  const uses = { DB_PASSWORD_AUTHENTICATOR: 'PGRST_DB_URI: postgres://authenticator:', DB_PASSWORD_STORAGE: 'DATABASE_URL: postgres://supabase_storage_admin:' };
  for (const [name, prefix] of Object.entries(uses)) assert.ok(compose.includes(`${prefix}\${${name}:?`), `${name} is required where it is used`);
  assert.doesNotMatch(compose, /warehouse_monitoring|DB_PASSWORD_MONITORING/, 'no service signs in as the monitoring login');
  assert.deepEqual(DB_ROLE_LOGINS.map(({ role }) => role), ['authenticator', 'supabase_storage_admin', 'pgbouncer']);
  assert.match(read('docker/volumes/pooler/pooler.exs'), /"db_password" => System\.fetch_env!\("DB_PASSWORD_POOLER"\)/);
  assert.match(read('docker/volumes/pooler/pooler.exs'), /update_manager_user_credentials\(tenant, Map\.take\(pool_user, \["db_user", "db_password"\]\)\)/);
});

test('staging a rotation replaces only the role lines (and the superuser pair on request) in a private sibling file', () => {
  const scratch = mkdtempSync(join(tmpdir(), 'warehouse-db-roles-stage-'));
  try {
    const live = join(scratch, 'compose.env');
    const staged = join(scratch, 'compose.env.rotating-db');
    const values = env();
    const text = `JWT_SECRET=${'a'.repeat(96)}\n${Object.entries(values).map(([key, value]) => `${key}=${value}`).join('\n')}\nKONG_HTTP_PORT=18000\n`;
    writeFileSync(live, text, { mode: 0o600 });
    const changed = path => {
      const before = text.split('\n');
      return readFileSync(path, 'utf8').split('\n').flatMap((line, index) => line === before[index] ? [] : [line.split('=')[0]]);
    };
    assert.deepEqual(stageRotatedDbEnv(live, staged).replaced, DB_ROLE_LOGINS.map(({ env: name }) => name));
    assert.deepEqual(changed(staged), DB_ROLE_LOGINS.map(({ env: name }) => name));
    assert.equal(statSync(staged).mode & 0o777, 0o600);
    assert.equal(readFileSync(live, 'utf8'), text, 'the live file is untouched');
    stageRotatedDbEnv(live, staged, { superuser: true });
    assert.deepEqual(changed(staged).sort(), ['POSTGRES_PASSWORD', ...GENERATED_DB_NAMES].sort());
    assert.throws(() => stageRotatedDbEnv(live, join(tmpdir(), 'elsewhere.env')), /different file in the compose.env directory/);
    writeFileSync(live, text.replace(/^DB_PASSWORD_STORAGE=.*$/m, 'DB_PASSWORD_STORAGE='), { mode: 0o600 });
    assert.throws(() => stageRotatedDbEnv(live, staged), /Invalid DB_PASSWORD_STORAGE: run setup\.sh/);
    assert.deepEqual(readdirSync(scratch).sort(), ['compose.env', 'compose.env.rotating-db']);
    const cli = spawnSync(process.execPath, [new URL('../scripts/db-roles.mjs', import.meta.url).pathname, 'names'], { encoding: 'utf8' });
    assert.equal(cli.status, 0, cli.stderr);
    assert.deepEqual(cli.stdout.trimEnd().split('\n'), GENERATED_DB_NAMES);
  } finally { rmSync(scratch, { recursive: true, force: true }); }
});

test('add-missing adds missing values only and leaves PGRST_DB_SCHEMAS and an unchanged file alone, byte for byte', () => {
  const scratch = mkdtempSync(join(tmpdir(), 'warehouse-db-roles-schemas-'));
  try {
    const file = join(scratch, 'compose.env');
    const complete = Object.entries(env()).map(([name, value]) => `${name}=${value}\n`).join('');
    const write = text => writeFileSync(file, text, { mode: 0o600 });
    // Whatever the list is, it is not touched here (a backup of this release names no GraphQL schema; setup keeps its own rewrite).
    for (const list of ['public,storage', 'public,storage,graphql_public', 'public,storage,extra']) {
      const text = `A=1\nPGRST_DB_SCHEMAS=${list}\n${complete}B=2\n`;
      write(text);
      const before = statSync(file).ino;
      assert.deepEqual(addMissingDbValuesToFile(file), []);
      assert.equal(readFileSync(file, 'utf8'), text, list);
      assert.equal(statSync(file).ino, before, 'nothing to change: the file was not rewritten');
      assert.equal(statSync(file).mode & 0o777, 0o600);
    }
    // Missing values are added.
    write('PGRST_DB_SCHEMAS=public,storage\nPOSTGRES_PASSWORD=' + superuser + '\n');
    const added = addMissingDbValuesToFile(file);
    assert.deepEqual(added, GENERATED_DB_NAMES);
    assert.match(readFileSync(file, 'utf8'), /^PGRST_DB_SCHEMAS=public,storage$/m);
  } finally { rmSync(scratch, { recursive: true, force: true }); }
});

test('a restored compose.env gets the old PGRST_DB_SCHEMAS defaults rewritten to public; an operator-edited list and an unchanged file are left alone', () => {
  const scratch = mkdtempSync(join(tmpdir(), 'warehouse-db-roles-restore-'));
  try {
    const file = join(scratch, 'compose.env');
    const complete = Object.entries(env()).map(([name, value]) => `${name}=${value}\n`).join('');
    const write = text => writeFileSync(file, text, { mode: 0o600 });
    for (const list of ['public,storage', 'public,storage,graphql_public']) {
      write(`A=1\nPGRST_DB_SCHEMAS=${list}\n${complete}B=2\n`);
      assert.deepEqual(normalizeRestoredEnvFile(file), { added: [], schemasRewritten: true }, list);
      assert.equal(readFileSync(file, 'utf8'), `A=1\nPGRST_DB_SCHEMAS=public\n${complete}B=2\n`);
      assert.equal(statSync(file).mode & 0o777, 0o600);
    }
    for (const list of ['public,storage,extra', 'public', 'public,reports']) {
      const text = `PGRST_DB_SCHEMAS=${list}\n${complete}`;
      write(text);
      const inode = statSync(file).ino;
      assert.deepEqual(normalizeRestoredEnvFile(file), { added: [], schemasRewritten: false });
      assert.equal(readFileSync(file, 'utf8'), text, list);
      assert.equal(statSync(file).ino, inode, 'not rewritten');
    }
    write('PGRST_DB_SCHEMAS=public,storage\nPOSTGRES_PASSWORD=' + superuser + '\n');
    const result = normalizeRestoredEnvFile(file);
    assert.deepEqual(result.added, GENERATED_DB_NAMES);
    assert.equal(result.schemasRewritten, true);
    assert.match(readFileSync(file, 'utf8'), /^PGRST_DB_SCHEMAS=public$/m);
  } finally { rmSync(scratch, { recursive: true, force: true }); }
});

test('the add-missing command (run by restore.sh and restore-host.sh) rewrites the old PGRST_DB_SCHEMAS default and says so', () => {
  const scratch = mkdtempSync(join(tmpdir(), 'warehouse-db-roles-cli-'));
  try {
    const file = join(scratch, 'compose.env');
    const complete = Object.entries(env()).map(([name, value]) => `${name}=${value}\n`).join('');
    writeFileSync(file, `PGRST_DB_SCHEMAS=public,storage,graphql_public\n${complete}`, { mode: 0o600 });
    const run = spawnSync(process.execPath, [fileURLToPath(new URL('../scripts/db-roles.mjs', import.meta.url)), 'add-missing', file], { encoding: 'utf8' });
    assert.equal(run.status, 0, run.stderr);
    assert.match(run.stdout, /PGRST_DB_SCHEMAS is now public/);
    assert.match(readFileSync(file, 'utf8'), /^PGRST_DB_SCHEMAS=public$/m);
  } finally { rmSync(scratch, { recursive: true, force: true }); }
});
