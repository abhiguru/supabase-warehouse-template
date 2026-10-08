import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, readdirSync, statSync, existsSync, rmSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createHmac } from 'node:crypto';
import { configure } from '../scripts/configure.mjs';
import { readEnv } from '../scripts/doctor-common.mjs';
import { validateOperatorEnv } from '../scripts/doctor.mjs';
import { stageRotatedEnv } from '../scripts/rotate-keys.mjs';

const root = new URL('..', import.meta.url).pathname;
const script = join(root, 'rotate-keys.sh');

// Fake Docker: records every invocation, answers the health and ownership
// probes, captures the psql standard input and can fail the SQL step.
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
      *' ps -q supavisor') : ;;
      *' ps -q '*) printf 'cccccccccccc\\n' ;;
      *'exec -T db psql'*) cat >> "$FAKE_PSQL_INPUT"; if [ "$FAKE_DOCKER_FAIL" = psql ]; then exit 3; fi ;;
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
  writeFileSync(providerEnv, 'SMS_PROVIDER=msg91\nMSG91_AUTH_KEY=rotation-test-key\nMSG91_TEMPLATE_ID=000000000000000000000001\nMSG91_PE_ID=1\nMSG91_SENDER_ID=ROTATE\n', { mode: 0o600 });
  configure(root, { stateDir: state, apiUrl: 'https://api.example.com', company: 'Acme', providerEnv });
  writeFileSync(join(bin, 'docker'), fakeDocker, { mode: 0o700 });
  const log = join(scratch, 'docker.log');
  const psqlInput = join(scratch, 'psql-input.sql');
  const env = { ...process.env, PATH: `${bin}:${process.env.PATH}`, WAREHOUSE_STATE_DIR: state, FAKE_DOCKER_LOG: log, FAKE_PSQL_INPUT: psqlInput };
  delete env.NODE_TEST_CONTEXT;
  return { scratch, state, envPath: join(state, 'config/compose.env'), log, psqlInput, env };
}

const verifies = (token, secret) => {
  const [header, payload, signature] = token.split('.');
  return signature === createHmac('sha256', secret).update(`${header}.${payload}`).digest('base64url');
};

test('rotation refuses without --yes and touches neither Docker nor the configuration', () => {
  const f = fixture('warehouse-rotate-refuse-');
  try {
    const before = readFileSync(f.envPath);
    for (const args of [[], ['--help'], ['--yes', 'extra'], ['yes']]) {
      const result = spawnSync('bash', [script, ...args], { encoding: 'utf8', env: f.env });
      assert.notEqual(result.status, 0);
      assert.match(result.stderr, /--yes/);
      assert.match(result.stderr, /sign in again/);
    }
    assert.deepEqual(readFileSync(f.envPath), before);
    assert.equal(existsSync(f.log), false, 'no docker invocation without confirmation');
    const unset = spawnSync('bash', [script, '--yes'], { encoding: 'utf8', env: { ...f.env, WAREHOUSE_STATE_DIR: '' } });
    assert.notEqual(unset.status, 0);
    assert.match(unset.stderr, /WAREHOUSE_STATE_DIR/);
    assert.equal(existsSync(f.log), false);
  } finally { rmSync(f.scratch, { recursive: true, force: true }); }
});

test('rotation stages new keys, applies SQL over stdin, swaps the file and recreates running consumers', () => {
  const f = fixture('warehouse-rotate-flow-');
  try {
    const before = readEnv(f.envPath);
    const beforeText = readFileSync(f.envPath, 'utf8');
    const result = spawnSync('bash', [script, '--yes'], { encoding: 'utf8', env: f.env, timeout: 120000 });
    assert.equal(result.status, 0, `${result.stdout}\n${result.stderr}`);
    assert.match(result.stdout, /sign in again/);
    const after = readEnv(f.envPath);
    assert.equal(statSync(f.envPath).mode & 0o777, 0o600);
    assert.deepEqual(readdirSync(join(f.state, 'config')).sort(), ['compose.env', 'operator.lock']);
    assert.match(after.JWT_SECRET, /^[0-9a-f]{96}$/);
    assert.notEqual(after.JWT_SECRET, before.JWT_SECRET);
    assert.notEqual(after.ANON_KEY, before.ANON_KEY);
    assert.notEqual(after.SERVICE_ROLE_KEY, before.SERVICE_ROLE_KEY);
    assert.ok(verifies(after.ANON_KEY, after.JWT_SECRET) && verifies(after.SERVICE_ROLE_KEY, after.JWT_SECRET));
    assert.equal(validateOperatorEnv(after, f.state).origin, 'https://api.example.com');
    for (const key of Object.keys(before)) if (!['JWT_SECRET', 'ANON_KEY', 'SERVICE_ROLE_KEY'].includes(key)) assert.equal(after[key], before[key], key);
    const afterText = readFileSync(f.envPath, 'utf8');
    const changed = beforeText.split('\n').filter((line, index) => line !== afterText.split('\n')[index]).map(line => line.split('=')[0]);
    assert.deepEqual(changed.sort(), ['ANON_KEY', 'JWT_SECRET', 'SERVICE_ROLE_KEY']);

    // The SQL script arrived on psql's standard input with the staged secret set first.
    const sql = readFileSync(f.psqlInput, 'utf8');
    assert.ok(sql.startsWith(`\\set new_secret ${after.JWT_SECRET}\n\\set ON_ERROR_STOP on\n`), 'secret precedes the rotation script');
    assert.equal(sql.slice(sql.indexOf('\n') + 1), readFileSync(join(root, 'scripts/rotate-auth.sql'), 'utf8'));
    const calls = readFileSync(f.log, 'utf8');
    assert.equal(calls.includes(after.JWT_SECRET), false, 'secret never appears in Docker arguments');
    assert.equal(calls.includes(before.JWT_SECRET), false);
    assert.ok(calls.indexOf('exec -T db psql') < calls.indexOf('--force-recreate'), 'SQL before recreation');
    assert.match(calls, /--profile \* up -d --force-recreate --wait --wait-timeout 180 db kong rest realtime storage functions studio\n/);
    assert.equal(/--force-recreate[^\n]*supavisor/.test(calls), false, 'stopped optional consumer is not started');
    assert.ok(calls.indexOf('--force-recreate') < calls.indexOf('pg_isready'), 'doctor runs after recreation');
  } finally { rmSync(f.scratch, { recursive: true, force: true }); }
});

test('a failing SQL step leaves the configuration untouched and recreates nothing', () => {
  const f = fixture('warehouse-rotate-fail-');
  try {
    const before = readFileSync(f.envPath);
    const result = spawnSync('bash', [script, '--yes'], { encoding: 'utf8', env: { ...f.env, FAKE_DOCKER_FAIL: 'psql' }, timeout: 120000 });
    assert.notEqual(result.status, 0);
    assert.deepEqual(readFileSync(f.envPath), before);
    assert.deepEqual(readdirSync(join(f.state, 'config')).sort(), ['compose.env', 'operator.lock']);
    const calls = readFileSync(f.log, 'utf8');
    assert.match(calls, /exec -T db psql/);
    assert.equal(calls.includes('--force-recreate'), false);
    assert.equal(calls.includes('pg_isready'), false);
  } finally { rmSync(f.scratch, { recursive: true, force: true }); }
});

test('stageRotatedEnv rewrites only the three signing lines into a private sibling file', () => {
  const f = fixture('warehouse-rotate-stage-');
  try {
    const staged = join(f.state, 'config/compose.env.rotating');
    const original = readFileSync(f.envPath, 'utf8');
    const result = stageRotatedEnv(f.envPath, staged);
    assert.deepEqual(result, { staged, replaced: ['JWT_SECRET', 'ANON_KEY', 'SERVICE_ROLE_KEY'] });
    assert.equal(readFileSync(f.envPath, 'utf8'), original, 'live file untouched');
    assert.equal(statSync(staged).mode & 0o777, 0o600);
    const stagedEnv = readEnv(staged);
    assert.notEqual(stagedEnv.JWT_SECRET, readEnv(f.envPath).JWT_SECRET);
    assert.ok(verifies(stagedEnv.ANON_KEY, stagedEnv.JWT_SECRET));
    stageRotatedEnv(f.envPath, staged); // a leftover staged file is replaced
    assert.throws(() => stageRotatedEnv(f.envPath, join(f.scratch, 'elsewhere')), /same|compose\.env directory/);
    assert.throws(() => stageRotatedEnv(f.envPath, f.envPath), /different file/);
    assert.throws(() => stageRotatedEnv('config/compose.env', staged), /absolute/);
    assert.throws(() => stageRotatedEnv(join(f.scratch, 'missing.env'), join(f.scratch, 'missing.rotating')), /owned regular file/);
  } finally { rmSync(f.scratch, { recursive: true, force: true }); }
});
