import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, writeFileSync, existsSync, rmSync } from 'node:fs';
import { spawn, spawnSync } from 'node:child_process';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

const root = new URL('..', import.meta.url).pathname;
const pause = ms => Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);

function fakeState(scratch) {
  const state = join(scratch, 'state');
  for (const path of [state, join(state, 'config'), join(state, 'public'), join(state, 'data'), join(state, 'data/db'), join(state, 'data/storage')]) mkdirSync(path, { recursive: true, mode: 0o700 });
  writeFileSync(join(state, 'config/compose.env'), `WAREHOUSE_PROJECT_NAME=warehouse-lock-test\nWAREHOUSE_DB_PATH=${state}/data/db\nWAREHOUSE_STORAGE_PATH=${state}/data/storage\n`, { mode: 0o600 });
  writeFileSync(join(state, 'public/instance.json'), '{"schemaVersion":1}\n');
  return state;
}

function holdLock(lockfile) {
  const holder = spawn('flock', [lockfile, 'sleep', '30'], { stdio: 'ignore', detached: true });
  for (let attempt = 0; attempt < 100; attempt += 1) {
    if (spawnSync('flock', ['-n', lockfile, 'true']).status !== 0) return holder;
    pause(50);
  }
  throw new Error('Lock holder did not acquire the operator lock.');
}

test('every operator command refuses to run while another holds the state lock', () => {
  const scratch = mkdtempSync(join(tmpdir(), 'warehouse-lock-test-'));
  const state = fakeState(scratch);
  const bin = join(scratch, 'bin');
  const log = join(scratch, 'docker.log');
  mkdirSync(bin);
  writeFileSync(join(bin, 'docker'), '#!/bin/sh\nprintf \'%s\\n\' "$*" >> "$FAKE_DOCKER_LOG"\nexit 0\n', { mode: 0o700 });
  let holder;
  try {
    holder = holdLock(join(state, 'config/operator.lock'));
    const commands = [
      ['stop.sh', []],
      ['rotate-keys.sh', ['--yes']],
      ['scripts/recovery-check.sh', []],
      ['scripts/retention.sh', ['preview']],
      ['scripts/gateway-dns-check.sh', []],
    ];
    for (const [script, args] of commands) {
      const result = spawnSync('bash', [join(root, script), ...args], {
        encoding: 'utf8', env: { ...process.env, PATH: `${bin}:${process.env.PATH}`, WAREHOUSE_STATE_DIR: state, FAKE_DOCKER_LOG: log },
      });
      assert.notEqual(result.status, 0, `${script} must fail while locked`);
      assert.match(result.stderr, /Another operator/, `${script}: ${result.stderr}`);
    }
    assert.equal(existsSync(log), false, 'no docker invocation while the lock is held');
  } finally {
    if (holder) { try { process.kill(-holder.pid, 'SIGKILL'); } catch { /* already gone */ } }
    rmSync(scratch, { recursive: true, force: true });
  }
});

test('lock helper validates the state path before locking and refuses direct execution', () => {
  const scratch = mkdtempSync(join(tmpdir(), 'warehouse-lock-validate-'));
  try {
    const state = fakeState(scratch);
    const run = (envState, body = 'state="$(operator_state)"; operator_lock "$state"; echo "locked:$state"') => spawnSync('bash', ['-c', `set -euo pipefail; . "$1"; ${body}`, '_', join(root, 'scripts/operator-lock.sh')], {
      encoding: 'utf8', env: { ...process.env, WAREHOUSE_STATE_DIR: envState },
    });
    const ok = run(state);
    assert.equal(ok.status, 0, ok.stderr);
    assert.equal(ok.stdout.trim(), `locked:${state}`);
    assert.notEqual(run('').status, 0);
    assert.match(run('').stderr, /WAREHOUSE_STATE_DIR/);
    assert.notEqual(run('relative/state').status, 0);
    assert.notEqual(run(join(scratch, 'missing')).status, 0);
    const bare = join(scratch, 'bare');
    mkdirSync(bare, { mode: 0o700 });
    assert.match(run(bare).stderr, /configuration directory/);
    const direct = spawnSync('bash', [join(root, 'scripts/operator-lock.sh')], { encoding: 'utf8' });
    assert.notEqual(direct.status, 0);
    assert.match(direct.stderr, /sourced helper/);
  } finally { rmSync(scratch, { recursive: true, force: true }); }
});
