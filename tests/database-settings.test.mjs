// The database and PostgREST settings of docker/docker-compose.yml that diagnosis and the API roles' limits depend on
// (docs/MONITORING.md, "Finding a slow query"; docs/CONTAINER_SECURITY.md, "Logs" and "Database roles"). Text assertions on the
// shipped file, plus the rendered project when Compose is installed.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { composeAvailable, renderCompose, renderedCompose } from './compose-render.mjs';

const read = path => readFileSync(new URL(`../${path}`, import.meta.url), 'utf8');
const compose = read('docker/docker-compose.yml');
const dbBlock = compose.slice(compose.indexOf('\n  db:\n'), compose.indexOf('\n  # Connection pooler'));
const flags = Object.fromEntries([...dbBlock.matchAll(/^\s+-c ([a-z_.]+)=(\S+)$/gm)].map(m => [m[1], m[2]]));

test('PostgREST reads the API roles\' own settings, so anon\'s 3 s and authenticated\'s 8 s statement timeouts apply', () => {
  // With PGRST_DB_CONFIG=false PostgREST never reads them: ALTER ROLE ... SET reaches only the login role (authenticator, 8 s).
  // Checked against PostgREST v16.4 and PostgreSQL 18: an anon call of pg_sleep(5) took 5.0 s with "false" and was cut at 3.0 s
  // with SQLSTATE 57014 "canceling statement due to statement timeout" with "true"; authenticated stayed at 8 s either way.
  assert.match(compose, /\n\s+PGRST_DB_CONFIG: "true"\n/);
  assert.doesNotMatch(compose, /PGRST_DB_CONFIG: "false"/);
  const bootstrap = read('docker/volumes/db/00-bootstrap.sql');
  assert.match(bootstrap, /ALTER ROLE anon\s+SET statement_timeout = '3s';/);
  assert.match(bootstrap, /ALTER ROLE authenticated SET statement_timeout = '8s';/);
  assert.match(read('docs/CONTAINER_SECURITY.md'), /statement timeouts 3 s and 8 s/);
  // No pgrst.* setting is kept in the database, so turning the option on cannot change any other PostgREST setting.
  assert.doesNotMatch(bootstrap + read('scripts/configure-db-roles.sql'), /pgrst\./);
  // The behaviour itself is proved on a live installation by the operator-install drill (needs Docker, so not here).
  assert.match(read('.github/workflows/ci.yml'), /run: npm run test:anon-timeout/);
  assert.match(read('package.json'), /"test:anon-timeout": "node tests\/anon-timeout-check\.mjs"/);
  const live = read('tests/anon-timeout-check.mjs');
  assert.match(live, /ci_timeout_probe/); assert.match(live, /57014/); assert.match(live, /DROP FUNCTION IF EXISTS public\.ci_timeout_probe/);
});

test('PostgREST cuts a direct table read at 2,000 rows (the app asks for at most 500), and the contract says so', () => {
  assert.match(compose, /\n\s+PGRST_DB_MAX_ROWS: "2000"\n/);
  assert.match(read('docs/API_CONTRACT.md'), /Direct table reads return at most 2,000 rows; page with `Range`/);
});

test('the database container has 256 MB of shared memory and logs slow statements, not connections', () => {
  assert.match(dbBlock, /\n    shm_size: 256m\n/);
  assert.equal(flags.log_min_duration_statement, '1000', 'statements slower than 1 s are logged');
  assert.equal(flags.log_connections, 'off');
  assert.equal(flags.log_disconnections, 'off');
  assert.equal(flags.log_temp_files, '10240', 'kB: temporary files of 10 MB or more');
  assert.equal(flags.log_statement, 'none');
  // The slow-statement log must not carry parameter values: PostgREST passes the request body as a parameter, and the body of
  // a sign-in request holds the code (the Logs rule in docs/CONTAINER_SECURITY.md).
  assert.equal(flags.log_parameter_max_length, '0');
  assert.equal(flags.log_lock_waits, 'on');
});

test('the database memory is set by setup.sh --db-memory through three compose.env keys whose defaults are the old fixed values', () => {
  assert.equal(flags.shared_buffers, '${DB_SHARED_BUFFERS:-128MB}');
  assert.equal(flags.effective_cache_size, '${DB_EFFECTIVE_CACHE_SIZE:-512MB}');
  assert.match(dbBlock, /\n          memory: \$\{DB_MEMORY_LIMIT:-1G\}\n/);
  const example = read('.env.example');
  assert.match(example, /^DB_MEMORY_LIMIT=1G$/m);
  assert.match(example, /^DB_SHARED_BUFFERS=128MB$/m);
  assert.match(example, /^DB_EFFECTIVE_CACHE_SIZE=512MB$/m);
  assert.match(read('setup.sh'), /--gateway-port\|--db-memory\)/);
});

test('the rendered project carries the same settings', { skip: !composeAvailable() && !process.env.CI ? 'docker compose is not installed' : false }, () => {
  const { services } = renderedCompose();
  assert.equal(services.rest.environment.PGRST_DB_CONFIG, 'true');
  assert.equal(services.rest.environment.PGRST_DB_MAX_ROWS, '2000');
  assert.equal(Number(services.db.shm_size), 256 * 1024 * 1024);
  const command = [].concat(services.db.command).join(' ');
  for (const setting of ['log_min_duration_statement=1000', 'log_connections=off', 'log_disconnections=off', 'log_temp_files=10240', 'log_parameter_max_length=0']) {
    assert.ok(command.includes(`-c ${setting}`), setting);
  }
  // Defaults identical to the earlier fixed values.
  assert.ok(command.includes('-c shared_buffers=128MB') && command.includes('-c effective_cache_size=512MB'));
  assert.equal(Number(services.db.deploy.resources.limits.memory), 1024 ** 3);
});

test('the rendered database follows DB_MEMORY_LIMIT, DB_SHARED_BUFFERS and DB_EFFECTIVE_CACHE_SIZE from compose.env', { skip: !composeAvailable() && !process.env.CI ? 'docker compose is not installed' : false }, () => {
  const result = renderCompose(text => text.replace('DB_MEMORY_LIMIT=1G', 'DB_MEMORY_LIMIT=8G').replace('DB_SHARED_BUFFERS=128MB', 'DB_SHARED_BUFFERS=2048MB').replace('DB_EFFECTIVE_CACHE_SIZE=512MB', 'DB_EFFECTIVE_CACHE_SIZE=4096MB'));
  assert.equal(result.status, 0, result.stderr);
  const db = JSON.parse(result.stdout).services.db;
  const command = [].concat(db.command).join(' ');
  assert.ok(command.includes('-c shared_buffers=2048MB') && command.includes('-c effective_cache_size=4096MB'));
  assert.equal(Number(db.deploy.resources.limits.memory), 8 * 1024 ** 3);
});

test('docs say what each value does and where to look', () => {
  const monitoring = read('docs/MONITORING.md');
  assert.match(monitoring, /## Finding a slow query/);
  assert.match(monitoring, /every statement slower than 1 second/);
  const security = read('docs/CONTAINER_SECURITY.md');
  assert.match(security, /log_parameter_max_length=0/);
  assert.match(security, /PGRST_DB_CONFIG/);
});
