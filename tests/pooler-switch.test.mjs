// scripts/pooler.sh (on, off, status, cleanup) against a fake docker and a fake psql: what it asks the database, what it
// changes in config/compose.env, and that it refuses to remove anything the pooler has used.
import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, existsSync, rmSync, readdirSync, statSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { configure } from '../scripts/configure.mjs';
import { readEnv } from '../scripts/doctor-common.mjs';
import { poolerEnvText } from '../scripts/db-roles.mjs';

const root = new URL('..', import.meta.url).pathname;
const SECRETS = ['DB_PASSWORD_POOLER', 'SECRET_KEY_BASE', 'VAULT_ENC_KEY'];

// Every docker call is logged. `docker compose ... exec -T db <cmd>` runs <cmd> locally (the fake psql below).
// `docker ps -aq --filter label=...service=supavisor` lists a container when FAKE_SUPAVISOR=yes.
const fakeDocker = `#!/bin/sh
printf '%s\\n' "$*" >> "$FAKE_DOCKER_LOG"
case "$1" in
  ps) case "$*" in *service=supavisor*) if [ "\${FAKE_SUPAVISOR:-}" = yes ]; then echo abcabcabcabc; fi ;; esac; exit 0 ;;
  inspect) echo healthy; exit 0 ;;
  compose)
    case "$*" in
      *' ps -q db') echo dbdbdbdbdbdb; exit 0 ;;
      *' up -d --no-deps'*supavisor) if [ "\${FAKE_FAIL_UP:-}" = yes ]; then exit 1; fi; exit 0 ;;
    esac
    while [ "$#" -gt 0 ] && [ "$1" != exec ]; do shift; done
    [ "$1" = exec ] || exit 0
    shift 3
    exec "$@" ;;
esac
`;
// FAKE_REFUSE=yes: the removal script (scripts/drop-pooler.sql) refuses, as the real one does when the pooler is in use.
// What the database answers: FAKE_FACTS for the facts query ("<role> <schema> <database>" counts), FAKE_HELD for the
// content of _supabase ("<relations> <other schemas or ->"). Standard input of every psql is kept in FAKE_SQL_LOG.
const fakePsql = `#!/bin/sh
db=''; query=''
while [ "$#" -gt 0 ]; do
  case "$1" in -d) db=$2; shift 2 ;; -c) query=$2; shift 2 ;; *) shift ;; esac
done
if [ -z "$query" ]; then
  { printf -- '--- psql -d %s\\n' "$db"; cat; } >> "$FAKE_SQL_LOG"
  if [ "\${FAKE_REFUSE:-}" = yes ] && grep -q 'pooler objects are in use' "$FAKE_SQL_LOG" && [ "$db" = postgres ]; then echo 'Pooler objects not removed, nothing was changed: (fake)' >&2; exit 3; fi
  exit 0
fi
case "$query" in
  *"rolname = 'pgbouncer'"*) echo "\${FAKE_FACTS:-0 0 0}" ;;
  *pg_class*) echo "\${FAKE_HELD:-0 -}" ;;
esac
`;

function fixture(prefix, { env } = {}) {
  const scratch = mkdtempSync(join(tmpdir(), prefix));
  const state = join(scratch, 'state');
  const bin = join(scratch, 'bin');
  const providerEnv = join(scratch, 'provider.env');
  mkdirSync(bin);
  writeFileSync(providerEnv, 'SMS_PROVIDER=msg91\nMSG91_AUTH_KEY=isolated-no-delivery-key\nMSG91_TEMPLATE_ID=000000000000000000000001\nMSG91_PE_ID=1\nMSG91_SENDER_ID=CHECK\n', { mode: 0o600 });
  configure(root, { stateDir: state, apiUrl: 'https://api.example.test', company: 'Acme', providerEnv });
  writeFileSync(join(bin, 'docker'), fakeDocker, { mode: 0o700 });
  writeFileSync(join(bin, 'psql'), fakePsql, { mode: 0o700 });
  const envPath = join(state, 'config/compose.env');
  if (env) writeFileSync(envPath, env(readFileSync(envPath, 'utf8')), { mode: 0o600 });
  const log = join(scratch, 'docker.log');
  const sql = join(scratch, 'sql.log');
  writeFileSync(log, '');
  writeFileSync(sql, '');
  const base = { ...process.env, PATH: `${bin}:${process.env.PATH}`, WAREHOUSE_STATE_DIR: state, FAKE_DOCKER_LOG: log, FAKE_SQL_LOG: sql };
  const run = (command, extra = {}) => spawnSync('bash', [join(root, 'scripts/pooler.sh'), command], { encoding: 'utf8', env: { ...base, ...extra }, timeout: 60000 });
  const calls = () => readFileSync(log, 'utf8');
  return { scratch, state, envPath, run, calls, sql: () => readFileSync(sql, 'utf8') };
}
const clean = f => rmSync(f.scratch, { recursive: true, force: true });
// An installation from before the switch: the pooler secrets exist, POOLER_ENABLED does not.
const legacy = text => `${text.replace(/^POOLER_ENABLED=.*\n/m, '')}DB_PASSWORD_POOLER=${'4'.repeat(64)}\nSECRET_KEY_BASE=${'6'.repeat(128)}\nVAULT_ENC_KEY=${'7'.repeat(32)}\n`;
const dropped = calls => calls.split('\n').filter(line => /DROP DATABASE/.test(line));
const copies = f => readdirSync(join(f.state, 'config')).filter(name => name.startsWith('compose.env.pre-pooler-cleanup-'));

test('status reports the switch: off for a new install, unset for one from before it', () => {
  const fresh = fixture('warehouse-pooler-status-');
  const old = fixture('warehouse-pooler-status-old-', { env: legacy });
  try {
    assert.equal(fresh.run('status').stdout.trim(), 'off');
    assert.equal(old.run('status').stdout.trim(), 'unset');
  } finally { clean(fresh); clean(old); }
});

test('on: secrets, role, schema and database first, then the service; repeating it replaces no secret', () => {
  const f = fixture('warehouse-pooler-on-');
  try {
    const before = readEnv(f.envPath);
    for (const name of SECRETS) assert.equal(name in before, false, `a new install has no ${name}`);
    const result = f.run('on');
    assert.equal(result.status, 0, result.stderr + result.stdout);
    const env = readEnv(f.envPath);
    assert.equal(env.POOLER_ENABLED, 'true');
    assert.match(env.DB_PASSWORD_POOLER, /^[0-9a-f]{64}$/);
    assert.match(env.SECRET_KEY_BASE, /^[0-9a-f]{128}$/);
    assert.match(env.VAULT_ENC_KEY, /^[0-9a-f]{32}$/);
    // The database step comes from db-roles.sh: pooler objects, then the password verifier; the password itself is never sent.
    const sql = f.sql();
    assert.ok(sql.indexOf('CREATE ROLE pgbouncer') >= 0 && sql.indexOf('CREATE ROLE pgbouncer') < sql.indexOf('ALTER ROLE pgbouncer WITH LOGIN PASSWORD'), 'role before password');
    assert.match(sql, /CREATE DATABASE _supabase WITH OWNER supabase_admin/);
    assert.match(sql, /^\\set pooler_verifier 'SCRAM-SHA-256\$4096:/m);
    for (const name of SECRETS) assert.equal(sql.includes(env[name]), false, `${name} is not sent to the database`);
    const calls = f.calls();
    assert.ok(calls.indexOf('exec -T db sh -c') < calls.indexOf('--profile pooler up -d --no-deps --wait --wait-timeout 180 supavisor'), 'the service starts after the database step');
    assert.deepEqual(dropped(calls), []);
    assert.equal(existsSync(`${f.envPath}.pooler`), false, 'no staged file is left');
    // Again: same secrets.
    const again = f.run('on');
    assert.equal(again.status, 0, again.stderr);
    assert.deepEqual(readEnv(f.envPath), env);
  } finally { clean(f); }
});

test('on: a service that does not become healthy leaves the objects and secrets in place and says how to retry', () => {
  const f = fixture('warehouse-pooler-on-fail-');
  try {
    const result = f.run('on', { FAKE_FAIL_UP: 'yes' });
    assert.equal(result.status, 1);
    assert.match(result.stderr, /did not become healthy.*Run bash scripts\/pooler\.sh on again/);
    assert.equal(readEnv(f.envPath).POOLER_ENABLED, 'true');
    assert.match(f.sql(), /CREATE DATABASE _supabase/);
  } finally { clean(f); }
});

test('off: stops and removes the container, drops role, schema and _supabase safely, removes the secrets, records off', () => {
  const f = fixture('warehouse-pooler-off-', { env: text => poolerEnvText(text, 'on').text });
  try {
    const result = f.run('off');
    assert.equal(result.status, 0, result.stderr);
    assert.match(f.calls(), /--profile pooler rm -sf supavisor/);
    const sql = f.sql();
    assert.match(sql, /DROP FUNCTION IF EXISTS pgbouncer\.get_auth\(text\);\nDROP SCHEMA IF EXISTS pgbouncer;\nDROP ROLE IF EXISTS pgbouncer;/);
    assert.match(sql, /DROP DATABASE IF EXISTS _supabase;/);
    assert.doesNotMatch(sql, /CASCADE|FORCE/);
    const env = readEnv(f.envPath);
    assert.equal(env.POOLER_ENABLED, 'false');
    for (const name of SECRETS) assert.equal(name in env, false, `${name} is removed`);
    assert.equal(f.run('status').stdout.trim(), 'off');
    // Turning it on again recreates everything.
    const on = f.run('on');
    assert.equal(on.status, 0, on.stderr);
    for (const name of SECRETS) assert.ok(readEnv(f.envPath)[name], `${name} is made again`);
    // Off is a decision: setup's clean-up leaves it alone.
    f.run('off');
    const before = f.calls();
    assert.equal(f.run('cleanup', { FAKE_FACTS: '1 1 1' }).status, 0);
    assert.equal(f.calls(), before);
  } finally { clean(f); }
});

test('off: when the removal refuses (objects in use) the container is stopped but compose.env keeps the secrets and the switch', () => {
  const f = fixture('warehouse-pooler-off-refuse-', { env: text => poolerEnvText(text, 'on').text });
  try {
    const before = readFileSync(f.envPath, 'utf8');
    const result = f.run('off', { FAKE_REFUSE: 'yes' });
    assert.equal(result.status, 1);
    assert.match(result.stderr, /not removed and compose\.env is unchanged/);
    assert.equal(readFileSync(f.envPath, 'utf8'), before);
  } finally { clean(f); }
});

test('cleanup of an unused pooler (no container, _supabase exists and holds nothing): saves compose.env first, drops without CASCADE or FORCE, removes secrets', () => {
  const f = fixture('warehouse-pooler-cleanup-', { env: legacy });
  try {
    const before = readFileSync(f.envPath, 'utf8');
    const result = f.run('cleanup', { FAKE_FACTS: '1 1 1' });
    assert.equal(result.status, 0, result.stderr);
    const [copy] = copies(f);
    assert.ok(copy, 'a copy of compose.env is saved');
    assert.equal(readFileSync(join(f.state, 'config', copy), 'utf8'), before, 'the copy is the compose.env from before');
    assert.equal(statSync(join(f.state, 'config', copy)).mode & 0o777, 0o600);
    assert.ok(result.stdout.includes(join(f.state, 'config', copy)), 'its path is printed');
    assert.match(result.stdout, /removed schema pgbouncer \(get_auth\), role pgbouncer, database _supabase \(empty\), DB_PASSWORD_POOLER from config\/compose\.env, SECRET_KEY_BASE from config\/compose\.env, VAULT_ENC_KEY from config\/compose\.env/);
    assert.match(f.sql(), /DROP SCHEMA IF EXISTS pgbouncer;\nDROP ROLE IF EXISTS pgbouncer;/);
    assert.doesNotMatch(f.sql(), /CASCADE|FORCE/);
    const env = readEnv(f.envPath);
    assert.equal(env.POOLER_ENABLED, 'false');
    for (const name of SECRETS) assert.equal(name in env, false, `${name} is removed`);
    assert.equal(f.run('status').stdout.trim(), 'off');
    // Done once: the next run does nothing.
    const callsBefore = f.calls();
    assert.equal(f.run('cleanup', { FAKE_FACTS: '1 1 1' }).status, 0);
    assert.equal(f.calls(), callsBefore);
  } finally { clean(f); }
});

test('cleanup with no _supabase database records off but keeps the secrets and says to run pooler.sh on if the pooler was used', () => {
  const f = fixture('warehouse-pooler-cleanup-none-', { env: legacy });
  try {
    const result = f.run('cleanup', { FAKE_FACTS: '1 1 0' });
    assert.equal(result.status, 0, result.stderr);
    assert.match(result.stdout, /If this installation used the pooler, run: bash scripts\/pooler\.sh on/);
    const env = readEnv(f.envPath);
    assert.equal(env.POOLER_ENABLED, 'false');
    for (const name of SECRETS) assert.ok(env[name], `${name} stays`);
    assert.equal(f.sql(), '', 'nothing dropped');
    assert.equal(copies(f).length, 1);
  } finally { clean(f); }
});

test('cleanup refuses, and changes nothing, when the removal script refuses (relations, other schemas, connections)', () => {
  const f = fixture('warehouse-pooler-cleanup-refuse-', { env: legacy });
  try {
    const before = readFileSync(f.envPath, 'utf8');
    const result = f.run('cleanup', { FAKE_FACTS: '1 1 1', FAKE_REFUSE: 'yes' });
    assert.equal(result.status, 1);
    assert.match(result.stderr, /not removed/);
    assert.equal(readFileSync(f.envPath, 'utf8'), before, 'compose.env is untouched');
  } finally { clean(f); }
});

test('drop-pooler.sql refuses before any DROP, and uses neither CASCADE nor FORCE', () => {
  const sql = readFileSync(join(root, 'scripts/drop-pooler.sql'), 'utf8');
  const code = sql.split('\n').filter(line => !line.startsWith('--')).join('\n');
  assert.doesNotMatch(code, /CASCADE|FORCE/);
  assert.ok(code.indexOf('pooler objects are in use') < code.indexOf('DROP FUNCTION'));
  assert.match(code, /p\.proname <> 'get_auth'/);
  assert.match(code, /pg_stat_activity/);
});

test('cleanup treats an existing supavisor container as a pooler in use: records on, removes nothing', () => {
  const f = fixture('warehouse-pooler-cleanup-container-', { env: legacy });
  try {
    const result = f.run('cleanup', { FAKE_SUPAVISOR: 'yes', FAKE_FACTS: '1 1 1' });
    assert.equal(result.status, 0, result.stderr);
    assert.match(result.stdout, /pooler is in use here\. Recorded POOLER_ENABLED=true/);
    const env = readEnv(f.envPath);
    assert.equal(env.POOLER_ENABLED, 'true');
    assert.equal(env.DB_PASSWORD_POOLER, '4'.repeat(64), 'its secrets stay');
    assert.equal(f.sql(), '');
    assert.deepEqual(dropped(f.calls()), []);
  } finally { clean(f); }
});

test('pooler.sh refuses an unknown command, and setup.sh runs the clean-up before the logins', () => {
  const f = fixture('warehouse-pooler-usage-');
  try {
    assert.equal(f.run('maybe').status, 1);
    assert.match(f.run('maybe').stderr, /Usage: bash scripts\/pooler\.sh on \| off \| status \| cleanup/);
  } finally { clean(f); }
  const setup = readFileSync(join(root, 'setup.sh'), 'utf8');
  assert.ok(setup.indexOf('scripts/pooler.sh" cleanup') > setup.indexOf('scripts/migrate.sh') && setup.indexOf('scripts/pooler.sh" cleanup') < setup.indexOf('scripts/db-roles.sh" apply'));
});
