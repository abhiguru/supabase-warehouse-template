// scripts/rotate-db-passwords.sh (npm run db:rotate-passwords) against a fake
// docker: the database side first, then the file, then the services; a service
// that does not come back puts the previous values back everywhere.
import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, readdirSync, statSync, existsSync, rmSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { configure } from '../scripts/configure.mjs';
import { readEnv } from '../scripts/doctor-common.mjs';
import { validateOperatorEnv } from '../scripts/doctor.mjs';
import { DB_ROLE_LOGINS, scramVerifier } from '../scripts/db-roles.mjs';

const root = new URL('..', import.meta.url).pathname;
const script = join(root, 'scripts/rotate-db-passwords.sh');
const roleNames = DB_ROLE_LOGINS.map(({ env }) => env);

// Records every invocation; the `apply` and `check` streams of scripts/db-roles.sh
// go to FAKE_APPLY_INPUT and FAKE_CHECK_INPUT, separated by a line of =. FAKE_FAIL
// names a step that fails: apply, check, or up (the first recreation only).
const fakeDocker = `#!/bin/sh
printf '%s\\n' "$*" >> "$FAKE_DOCKER_LOG"
case "$1" in
  ps) exit 0 ;;
  info) printf '28.0.0\\n' ;;
  inspect)
    case "$3" in
      *State.Status*) printf 'running healthy\\n' ;;
      *State.Health.Status*) printf 'healthy\\n' ;;
      *State.Running*) printf 'true\\n' ;;
    esac ;;
  compose)
    case "$*" in
      'compose version') printf 'Docker Compose version v2.39.0\\n' ;;
      *' ps -q supavisor'|*' ps -q grafana'|*' ps -q postgres-exporter'|*' ps -q auth') : ;;
      *' ps -q '*) printf 'cccccccccccc\\n' ;;
      *' exec -T db sh -c IFS= read -r pw;'*) cat >> "$FAKE_APPLY_INPUT"; echo ===== >> "$FAKE_APPLY_INPUT"; if [ "$FAKE_FAIL" = apply ]; then exit 3; fi ;;
      *' exec -T db sh -c '*'superuser_password'*) cat >> "$FAKE_CHECK_INPUT"; if [ "$FAKE_FAIL" = check ]; then exit 1; fi ;;
      *' up -d --force-recreate '*) if [ "$FAKE_FAIL" = up ] && [ ! -e "$FAKE_DOCKER_LOG.failed" ]; then : > "$FAKE_DOCKER_LOG.failed"; exit 1; fi ;;
      *'exec -T '*) cat >/dev/null ;;
    esac ;;
esac
`;

function fixture(prefix) {
  const scratch = mkdtempSync(join(tmpdir(), prefix));
  const state = join(scratch, 'state');
  const bin = join(scratch, 'bin');
  const providerEnv = join(scratch, 'provider.env');
  mkdirSync(bin);
  // Setup refuses a your- placeholder as unconfigured; nothing here can send: Docker is a fake.
  writeFileSync(providerEnv, 'SMS_PROVIDER=msg91\nMSG91_AUTH_KEY=isolated-no-delivery-key\nMSG91_TEMPLATE_ID=000000000000000000000001\nMSG91_PE_ID=1\nMSG91_SENDER_ID=ROTATE\n', { mode: 0o600 });
  configure(root, { stateDir: state, apiUrl: 'https://api.example.test', company: 'Acme', providerEnv });
  const envPath = join(state, 'config/compose.env');
  writeFileSync(join(bin, 'docker'), fakeDocker, { mode: 0o700 });
  const log = join(scratch, 'docker.log');
  const env = { ...process.env, PATH: `${bin}:${process.env.PATH}`, WAREHOUSE_STATE_DIR: state, FAKE_DOCKER_LOG: log,
    FAKE_APPLY_INPUT: join(scratch, 'apply.txt'), FAKE_CHECK_INPUT: join(scratch, 'check.txt') };
  delete env.NODE_TEST_CONTEXT;
  const run = (args, extra = {}) => spawnSync('bash', [script, ...args], { encoding: 'utf8', env: { ...env, ...extra }, timeout: 120000 });
  const applies = () => readFileSync(env.FAKE_APPLY_INPUT, 'utf8').split('=====\n').filter(Boolean);
  return { scratch, state, envPath, log, env, run, applies };
}
const changedLines = (before, after) => before.split('\n').filter((line, index) => line !== after.split('\n')[index]).map(line => line.split('=')[0]).sort();
// Every \set line of one apply stream is a verifier of the value in `env`; the first line signs in.
function assertApply(stream, env, signIn, extra = []) {
  const lines = stream.split('\n');
  assert.equal(lines[0], signIn, 'the sign-in password is the first line');
  const sets = Object.fromEntries([...stream.matchAll(/^\\set ([a-z_]+) '([^']+)'$/gm)].map(match => [match[1], match[2]]));
  const expected = [...DB_ROLE_LOGINS.map(({ env: name, variable }) => [variable, env[name]]), ...extra];
  assert.deepEqual(Object.keys(sets).sort(), expected.map(([variable]) => variable).sort());
  for (const [variable, password] of expected) {
    const salt = Buffer.from(sets[variable].split(':')[1].split('$')[0], 'base64');
    assert.equal(scramVerifier(password, salt), sets[variable], variable);
    assert.equal(stream.includes(password) && password !== signIn, false, `${variable}: no password beside the sign-in line`);
  }
  assert.ok(stream.includes(readFileSync(join(root, 'scripts/configure-db-roles.sql'), 'utf8')), 'configure-db-roles.sql follows the prelude');
}

test('rotation refuses without --yes and touches neither Docker nor the configuration', () => {
  const f = fixture('warehouse-rotate-db-refuse-');
  try {
    const before = readFileSync(f.envPath);
    for (const args of [[], ['--help'], ['--superuser'], ['--yes', 'extra']]) {
      const result = f.run(args);
      assert.notEqual(result.status, 0);
      assert.match(result.stderr, /Rerun with --yes/);
    }
    assert.deepEqual(readFileSync(f.envPath), before);
    assert.equal(existsSync(f.log), false, 'no docker invocation without confirmation');
  } finally { rmSync(f.scratch, { recursive: true, force: true }); }
});

test('rotation sets new verifiers first, then swaps compose.env, recreates the running consumers and checks every login', () => {
  const f = fixture('warehouse-rotate-db-flow-');
  try {
    const beforeText = readFileSync(f.envPath, 'utf8');
    const before = readEnv(f.envPath);
    const result = f.run(['--yes']);
    assert.equal(result.status, 0, `${result.stdout}\n${result.stderr}`);
    assert.match(result.stdout, /every service login has a new password\.\nTake a new backup now/);
    const afterText = readFileSync(f.envPath, 'utf8');
    const after = readEnv(f.envPath);
    assert.deepEqual(changedLines(beforeText, afterText), [...roleNames].sort());
    for (const name of roleNames) assert.match(after[name], /^[0-9a-f]{64}$/);
    assert.equal(after.POSTGRES_PASSWORD, before.POSTGRES_PASSWORD);
    assert.equal(after.REALTIME_DB_ENC_KEY, before.REALTIME_DB_ENC_KEY);
    assert.equal(validateOperatorEnv(after, f.state).origin, 'https://api.example.test');
    assert.equal(statSync(f.envPath).mode & 0o777, 0o600);
    assert.deepEqual(readdirSync(join(f.state, 'config')).sort(), ['backup.key', 'compose.env', 'operator.lock'], 'no staged or previous file is left');
    const [apply] = f.applies();
    assertApply(apply, after, before.POSTGRES_PASSWORD);
    assert.equal(readFileSync(f.env.FAKE_CHECK_INPUT, 'utf8').split('\n')[0], after.POSTGRES_PASSWORD, 'the check uses the new values');
    const calls = readFileSync(f.log, 'utf8');
    for (const value of [...roleNames.flatMap(name => [before[name], after[name]]), before.POSTGRES_PASSWORD]) assert.equal(calls.includes(value), false, 'no password in a docker argument');
    const at = needle => { const index = calls.indexOf(needle); assert.ok(index >= 0, needle); return index; };
    assert.ok(at('exec -T db sh -c IFS= read -r pw;') < at('--force-recreate'), 'the database is changed before anything is recreated');
    assert.match(calls, /--profile \* up -d --force-recreate --wait --wait-timeout 180 db rest storage realtime meta studio\n/, 'running consumers only');
    assert.ok(at('--force-recreate') < at('superuser_password') && at('superuser_password') < at('pg_isready'), 'then the login check, then the doctor');
  } finally { rmSync(f.scratch, { recursive: true, force: true }); }
});

test('--superuser also replaces POSTGRES_PASSWORD and the Realtime key, signing in with the old superuser password', () => {
  const f = fixture('warehouse-rotate-db-superuser-');
  try {
    const beforeText = readFileSync(f.envPath, 'utf8');
    const before = readEnv(f.envPath);
    const result = f.run(['--yes', '--superuser']);
    assert.equal(result.status, 0, `${result.stdout}\n${result.stderr}`);
    const after = readEnv(f.envPath);
    assert.deepEqual(changedLines(beforeText, readFileSync(f.envPath, 'utf8')), ['POSTGRES_PASSWORD', 'REALTIME_DB_ENC_KEY', ...roleNames].sort());
    assert.notEqual(after.POSTGRES_PASSWORD, before.POSTGRES_PASSWORD);
    assert.match(after.REALTIME_DB_ENC_KEY, /^[A-Za-z0-9_-]{16}$/);
    const [apply] = f.applies();
    assertApply(apply, after, before.POSTGRES_PASSWORD, [['postgres_verifier', after.POSTGRES_PASSWORD], ['supabase_admin_verifier', after.POSTGRES_PASSWORD]]);
    assert.equal(apply.includes(after.POSTGRES_PASSWORD), false, 'the new superuser password travels only as its verifiers');
  } finally { rmSync(f.scratch, { recursive: true, force: true }); }
});

test('a failing database step changes nothing and recreates nothing', () => {
  const f = fixture('warehouse-rotate-db-fail-');
  try {
    const before = readFileSync(f.envPath);
    const result = f.run(['--yes'], { FAKE_FAIL: 'apply' });
    assert.notEqual(result.status, 0);
    assert.deepEqual(readFileSync(f.envPath), before);
    assert.deepEqual(readdirSync(join(f.state, 'config')).sort(), ['backup.key', 'compose.env', 'operator.lock']);
    assert.equal(readFileSync(f.log, 'utf8').includes('--force-recreate'), false);
  } finally { rmSync(f.scratch, { recursive: true, force: true }); }
});

for (const [step, superuser] of [['up', false], ['check', false], ['up', true]]) {
  test(`a ${step === 'up' ? 'service that does not come back' : 'login check that fails'} puts the previous values back${superuser ? ' (--superuser)' : ''}`, () => {
    const f = fixture(`warehouse-rotate-db-rollback-${step}-`);
    try {
      const beforeText = readFileSync(f.envPath, 'utf8');
      const before = readEnv(f.envPath);
      const result = f.run(['--yes', ...(superuser ? ['--superuser'] : [])], { FAKE_FAIL: step });
      assert.equal(result.status, 1, result.stdout + result.stderr);
      assert.match(result.stderr, /putting the previous ones back[\s\S]*The previous database passwords are back in place/);
      assert.equal(readFileSync(f.envPath, 'utf8'), beforeText, 'compose.env holds the previous values again');
      assert.deepEqual(readdirSync(join(f.state, 'config')).sort(), ['backup.key', 'compose.env', 'operator.lock']);
      const [forward, back] = f.applies();
      assert.ok(forward && back, 'two database steps: the rotation and its reversal');
      const rotated = Object.fromEntries([...forward.matchAll(/^\\set ([a-z_]+) /gm)].map(match => [match[1], true]));
      assert.ok(Object.keys(rotated).length >= DB_ROLE_LOGINS.length);
      // The reversal sets the previous values, signed in with what the database holds now.
      const signIn = back.split('\n')[0];
      if (superuser) assert.notEqual(signIn, before.POSTGRES_PASSWORD, 'the new superuser password signs in for the reversal');
      else assert.equal(signIn, before.POSTGRES_PASSWORD);
      assertApply(back, before, signIn, superuser ? [['postgres_verifier', before.POSTGRES_PASSWORD], ['supabase_admin_verifier', before.POSTGRES_PASSWORD]] : []);
      const recreations = readFileSync(f.log, 'utf8').split('\n').filter(line => line.includes('--force-recreate'));
      assert.equal(recreations.length, 2, 'the services are recreated again with the previous values');
    } finally { rmSync(f.scratch, { recursive: true, force: true }); }
  });
}
