// scripts/db-roles.sh `check` (npm run test:db-roles) and `matches`: the script
// that normally runs inside the database container runs here, against a fake
// psql that accepts exactly the passwords the "database" has (FAKE_DB_<role>).
// The fake docker executes the `compose exec -T db …` command locally.
import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, rmSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { configure } from '../scripts/configure.mjs';
import { readEnv } from '../scripts/doctor-common.mjs';

const root = new URL('..', import.meta.url).pathname;

const fakeDocker = `#!/bin/sh
printf '%s\\n' "$*" >> "$FAKE_DOCKER_LOG"
case "$1" in
  ps) exit 0 ;;
  compose)
    if [ "\${FAKE_EXEC_FAIL:-}" = yes ]; then echo 'service "db" is not running' >&2; exit 1; fi
    while [ "$#" -gt 0 ] && [ "$1" != exec ]; do shift; done
    [ "$1" = exec ] || exit 0
    shift 3
    exec "$@" ;;
esac
`;
// -U role, -h host, -c query; PGPASSWORD is checked against FAKE_DB_<role>.
const fakePsql = `#!/bin/sh
user=''; host=''; query=''
while [ "$#" -gt 0 ]; do
  case "$1" in -U) user=$2; shift 2 ;; -h) host=$2; shift 2 ;; -c) query=$2; shift 2 ;; *) shift ;; esac
done
if [ "\${FAKE_DOWN:-}" = yes ]; then echo "psql: error: connection to server at \\"db\\", port 5432 failed: Connection refused" >&2; exit 2; fi
if [ "$host" = /var/run/postgresql ] && [ "\${FAKE_SOCKET_FAIL:-}" = yes ]; then echo 'psql: error: connection to server on socket failed' >&2; exit 2; fi
eval "want=\\\${FAKE_DB_$user:-}"
if [ -z "$want" ] || [ "$PGPASSWORD" != "$want" ]; then echo "psql: error: FATAL:  password authentication failed for user \\"$user\\"" >&2; exit 2; fi
case "$query" in
  *inet_client_addr*) echo "$user remote" ;;
  *pg_monitor*) echo "\${FAKE_MONITORING_RIGHTS:-true falsefalsefalsefalsefalse}" ;;
  *pg_authid*) echo "\${FAKE_FUNCTIONS_ADMIN:-false true}" ;;
  *) echo 1 ;;
esac
`;

function fixture(prefix) {
  const scratch = mkdtempSync(join(tmpdir(), prefix));
  const state = join(scratch, 'state');
  const bin = join(scratch, 'bin');
  const providerEnv = join(scratch, 'provider.env');
  mkdirSync(bin);
  // Setup refuses a your- placeholder as unconfigured; nothing here can send: Docker is a fake.
  writeFileSync(providerEnv, 'SMS_PROVIDER=msg91\nMSG91_AUTH_KEY=isolated-no-delivery-key\nMSG91_TEMPLATE_ID=000000000000000000000001\nMSG91_PE_ID=1\nMSG91_SENDER_ID=CHECK\n', { mode: 0o600 });
  configure(root, { stateDir: state, apiUrl: 'https://api.example.test', company: 'Acme', providerEnv });
  writeFileSync(join(bin, 'docker'), fakeDocker, { mode: 0o700 });
  writeFileSync(join(bin, 'psql'), fakePsql, { mode: 0o700 });
  const envPath = join(state, 'config/compose.env');
  const values = readEnv(envPath);
  // The database as setup leaves it: every login has its own value, the superuser POSTGRES_PASSWORD.
  const database = {
    FAKE_DB_supabase_admin: values.POSTGRES_PASSWORD, FAKE_DB_authenticator: values.DB_PASSWORD_AUTHENTICATOR,
    FAKE_DB_supabase_storage_admin: values.DB_PASSWORD_STORAGE, FAKE_DB_supabase_auth_admin: values.DB_PASSWORD_AUTH,
    FAKE_DB_pgbouncer: values.DB_PASSWORD_POOLER, FAKE_DB_warehouse_monitoring: values.DB_PASSWORD_MONITORING,
  };
  const env = { ...process.env, PATH: `${bin}:${process.env.PATH}`, WAREHOUSE_STATE_DIR: state, FAKE_DOCKER_LOG: join(scratch, 'docker.log'), ...database };
  const run = (args, extra = {}) => spawnSync('bash', [join(root, 'scripts/db-roles.sh'), ...args], { encoding: 'utf8', env: { ...env, ...extra }, timeout: 60000 });
  return { scratch, state, envPath, values, run };
}
const clean = f => rmSync(f.scratch, { recursive: true, force: true });

test('check passes when every login behaves and POSTGRES_PASSWORD is the live superuser password', () => {
  const f = fixture('warehouse-db-check-ok-');
  try {
    const result = f.run(['check']);
    assert.equal(result.status, 0, result.stdout + result.stderr);
    assert.match(result.stdout, /^ok   supabase_admin accepts POSTGRES_PASSWORD \(SCRAM, network connection\)/m);
    assert.equal((result.stdout.match(/^ok   /gm) ?? []).length, 13);
    assert.doesNotMatch(result.stdout, /^FAIL/m);
    assert.match(result.stdout, /Every database login refuses the superuser password and accepts only its own\.\n$/);
    const calls = readFileSync(join(f.scratch, 'docker.log'), 'utf8');
    for (const value of Object.values(f.values).filter(value => /^[0-9a-f]{64}$/.test(value))) assert.equal(calls.includes(value), false, 'no password in a docker argument');
  } finally { clean(f); }
});

test('check fails when compose.env does not hold the superuser password the database has', () => {
  const f = fixture('warehouse-db-check-superuser-');
  try {
    // The state a --superuser rotation interrupted before its commit could leave: the refusals prove nothing.
    const result = f.run(['check'], { FAKE_DB_supabase_admin: 'b'.repeat(64) });
    assert.notEqual(result.status, 0);
    assert.match(result.stdout, /^FAIL supabase_admin refuses POSTGRES_PASSWORD over the network/m);
    assert.doesNotMatch(result.stdout, /Every database login refuses the superuser password/);
  } finally { clean(f); }
});

test('a failed read of supabase_functions_admin fails the check instead of reporting the role absent', () => {
  const f = fixture('warehouse-db-check-authid-');
  try {
    const failed = f.run(['check'], { FAKE_SOCKET_FAIL: 'yes' });
    assert.notEqual(failed.status, 0);
    assert.match(failed.stdout, /^FAIL supabase_functions_admin: its login state could not be read/m);
    assert.doesNotMatch(failed.stdout, /does not exist/);
    const absent = f.run(['check'], { FAKE_FUNCTIONS_ADMIN: 'absent' });
    assert.equal(absent.status, 0, absent.stdout);
    assert.match(absent.stdout, /^ok   supabase_functions_admin does not exist$/m);
    const login = f.run(['check'], { FAKE_FUNCTIONS_ADMIN: 'true false' });
    assert.notEqual(login.status, 0);
    assert.match(login.stdout, /^FAIL supabase_functions_admin login state: true false$/m);
  } finally { clean(f); }
});

test('check fails for a login that still takes POSTGRES_PASSWORD or no longer takes its own value', () => {
  const f = fixture('warehouse-db-check-roles-');
  try {
    const shared = f.run(['check'], { FAKE_DB_pgbouncer: f.values.POSTGRES_PASSWORD });
    assert.notEqual(shared.status, 0);
    assert.match(shared.stdout, /^FAIL pgbouncer accepts POSTGRES_PASSWORD$/m);
    const stale = f.run(['check'], { FAKE_DB_supabase_storage_admin: 'c'.repeat(64) });
    assert.notEqual(stale.status, 0);
    assert.match(stale.stdout, /^FAIL supabase_storage_admin does not accept its own password over the network/m);
  } finally { clean(f); }
});

test('matches says whether the database takes a file\'s values, and says when it cannot tell', () => {
  const f = fixture('warehouse-db-check-matches-');
  try {
    assert.equal(f.run(['matches', f.envPath]).status, 0, 'the live file matches');
    const other = join(f.state, 'config/compose.env.rotating-db');
    const rotated = readFileSync(f.envPath, 'utf8').replace(/^DB_PASSWORD_AUTHENTICATOR=.*$/m, `DB_PASSWORD_AUTHENTICATOR=${'d'.repeat(64)}`);
    writeFileSync(other, rotated, { mode: 0o600 });
    assert.equal(f.run(['matches', other]).status, 1, 'another authenticator value does not');
    const superuser = readFileSync(f.envPath, 'utf8').replace(/^POSTGRES_PASSWORD=.*$/m, `POSTGRES_PASSWORD=${'e'.repeat(64)}`);
    writeFileSync(other, superuser, { mode: 0o600 });
    assert.equal(f.run(['matches', other]).status, 1, 'another superuser value does not');
    assert.equal(f.run(['matches', f.envPath], { FAKE_DOWN: 'yes' }).status, 2, 'no answer from the database: cannot tell');
    assert.equal(f.run(['matches', f.envPath], { FAKE_EXEC_FAIL: 'yes' }).status, 2, 'no database container: cannot tell');
    const calls = readFileSync(join(f.scratch, 'docker.log'), 'utf8');
    assert.equal(calls.includes(f.values.POSTGRES_PASSWORD) || calls.includes(f.values.DB_PASSWORD_AUTHENTICATOR), false, 'no password in a docker argument');
  } finally { clean(f); }
});
