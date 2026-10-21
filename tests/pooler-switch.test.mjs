// scripts/pooler.sh (on, off, status, cleanup) against a fake docker and a fake psql: what it asks the database, what it
// changes in config/compose.env, and that it refuses to remove anything the pooler has used.
import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, existsSync, rmSync } from 'node:fs';
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
// What the database answers: FAKE_FACTS for the facts query ("<role> <schema> <database>" counts), FAKE_HELD for the
// content of _supabase ("<relations> <other schemas or ->"). Standard input of every psql is kept in FAKE_SQL_LOG.
const fakePsql = `#!/bin/sh
db=''; query=''
while [ "$#" -gt 0 ]; do
  case "$1" in -d) db=$2; shift 2 ;; -c) query=$2; shift 2 ;; *) shift ;; esac
done
if [ -z "$query" ]; then { printf -- '--- psql -d %s\\n' "$db"; cat; } >> "$FAKE_SQL_LOG"; exit 0; fi
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

test('off: stops and removes the container, records off, deletes nothing', () => {
  const f = fixture('warehouse-pooler-off-', { env: text => poolerEnvText(text, 'on').text });
  try {
    const before = readEnv(f.envPath);
    const result = f.run('off');
    assert.equal(result.status, 0, result.stderr);
    assert.match(result.stdout, /Nothing was deleted/);
    assert.match(f.calls(), /--profile pooler rm -sf supavisor/);
    const env = readEnv(f.envPath);
    assert.equal(env.POOLER_ENABLED, 'false');
    for (const name of SECRETS) assert.equal(env[name], before[name], `${name} stays`);
    assert.deepEqual(dropped(f.calls()), []);
    assert.equal(f.sql(), '', 'no SQL at all');
    // Off is a decision: setup's clean-up leaves it alone.
    assert.equal(f.run('cleanup', { FAKE_FACTS: '1 1 1' }).status, 0);
    assert.deepEqual(dropped(f.calls()), []);
  } finally { clean(f); }
});

test('cleanup of an unused pooler (no container, _supabase holds nothing): removes role, schema, database and secrets, and says so', () => {
  const f = fixture('warehouse-pooler-cleanup-', { env: legacy });
  try {
    const result = f.run('cleanup', { FAKE_FACTS: '1 1 1', FAKE_HELD: '0 -' });
    assert.equal(result.status, 0, result.stderr);
    assert.match(result.stdout, /removed schema pgbouncer \(get_auth\), role pgbouncer, database _supabase \(empty\), DB_PASSWORD_POOLER from config\/compose\.env, SECRET_KEY_BASE from config\/compose\.env, VAULT_ENC_KEY from config\/compose\.env/);
    assert.match(f.sql(), /BEGIN;\nDROP SCHEMA IF EXISTS pgbouncer CASCADE;\nDROP ROLE IF EXISTS pgbouncer;\nCOMMIT;/);
    assert.equal(dropped(f.calls()).length, 1);
    assert.match(dropped(f.calls())[0], /DROP DATABASE IF EXISTS _supabase WITH \(FORCE\)/);
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

test('cleanup with nothing to remove still records the switch and takes the stale secrets out', () => {
  const f = fixture('warehouse-pooler-cleanup-none-', { env: legacy });
  try {
    const result = f.run('cleanup', { FAKE_FACTS: '0 0 0' });
    assert.equal(result.status, 0, result.stderr);
    assert.match(result.stdout, /removed DB_PASSWORD_POOLER from config\/compose\.env, SECRET_KEY_BASE from config\/compose\.env, VAULT_ENC_KEY from config\/compose\.env/);
    assert.equal(f.sql(), '');
    assert.deepEqual(dropped(f.calls()), []);
  } finally { clean(f); }
});

test('cleanup refuses, and changes nothing, when _supabase holds a relation or another schema (the pooler was used)', () => {
  for (const [held, shown] of [['4 -', /holds 4 relation\(s\)/], ['0 analytics', /holds 0 relation\(s\) and the schema\(s\) analytics/]]) {
    const f = fixture('warehouse-pooler-cleanup-refuse-', { env: legacy });
    try {
      const before = readFileSync(f.envPath, 'utf8');
      const result = f.run('cleanup', { FAKE_FACTS: '1 1 1', FAKE_HELD: held });
      assert.equal(result.status, 1);
      assert.match(result.stderr, /Pooler clean-up refused/);
      assert.match(result.stderr, shown);
      assert.match(result.stderr, /nothing was changed/);
      assert.equal(readFileSync(f.envPath, 'utf8'), before, 'compose.env is untouched');
      assert.equal(f.sql(), '', 'nothing was dropped');
      assert.deepEqual(dropped(f.calls()), []);
    } finally { clean(f); }
  }
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
