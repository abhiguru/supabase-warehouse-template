import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, rmSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

// scripts/db-version-preflight.sh against a fake docker: a running PostgreSQL 15 database, or a data directory whose
// PG_VERSION is not 17, is refused with the pointer to the baseline reload, before anything is built or recreated.
function run({ running = false, serverNum = '170011', dataDir = 'empty' }) {
  const scratch = mkdtempSync(join(tmpdir(), 'warehouse-db-preflight-'));
  try {
    const state = join(scratch, 'state');
    const bin = join(scratch, 'bin');
    const log = join(scratch, 'docker.log');
    for (const path of [state, join(state, 'config'), join(state, 'data/db'), join(state, 'data/storage'), bin]) mkdirSync(path, { recursive: true, mode: 0o700 });
    writeFileSync(join(state, 'config/compose.env'), `WAREHOUSE_PROJECT_NAME=warehouse-preflight-test\nWAREHOUSE_DB_PATH=${state}/data/db\nWAREHOUSE_STORAGE_PATH=${state}/data/storage\n`, { mode: 0o600 });
    writeFileSync(join(bin, 'docker'), `#!/bin/sh
printf '%s\\n' "$*" >> "$FAKE_DOCKER_LOG"
case "$1" in
  ps) exit 0 ;;
  run) printf '%s\\n' "$FAKE_DATA_DIR" ;;
  compose)
    case "$*" in
      *' ps --status running -q db') if [ "$FAKE_RUNNING" = yes ]; then printf 'bbbbbbbbbbbb\\n'; fi ;;
      *'exec -T db psql'*) printf '%s\\n' "$FAKE_SERVER_NUM" ;;
    esac ;;
esac
`, { mode: 0o700 });
    const result = spawnSync('bash', [new URL('../scripts/db-version-preflight.sh', import.meta.url).pathname], {
      encoding: 'utf8', env: { ...process.env, PATH: `${bin}:${process.env.PATH}`, WAREHOUSE_STATE_DIR: state, FAKE_DOCKER_LOG: log,
        FAKE_RUNNING: running ? 'yes' : 'no', FAKE_SERVER_NUM: serverNum, FAKE_DATA_DIR: dataDir },
    });
    return { ...result, calls: readFileSync(log, 'utf8') };
  } finally { rmSync(scratch, { recursive: true, force: true }); }
}

const REFUSAL = /Refusing: .*PostgreSQL 17.*migrations-pre-baseline.*Baseline reload/s;

test('a running PostgreSQL 15 database is refused, naming the baseline reload', () => {
  const r = run({ running: true, serverNum: '150008', dataDir: '15' });
  assert.equal(r.status, 1);
  assert.match(r.stderr, REFUSAL);
  assert.match(r.stderr, /server_version_num 150008 \(PostgreSQL 15\)/);
});

test('a data directory whose PG_VERSION is 15 is refused when no database runs, and the pinned image reads it read-only', () => {
  const r = run({ dataDir: '15' });
  assert.equal(r.status, 1);
  assert.match(r.stderr, REFUSAL);
  assert.match(r.stderr, /holds a PostgreSQL 15 database/);
  const dockerRun = r.calls.split('\n').find(line => line.startsWith('run '));
  assert.match(dockerRun, /-v .*\/data\/db:\/d:ro postgres:17\.\S+@sha256:[0-9a-f]{64} /);
  assert.match(dockerRun, /--network none/);
});

test('a running PostgreSQL 17, an empty data directory and a PG_VERSION of 17 pass (a facility moved to a new PostgreSQL 17 data directory)', () => {
  for (const [label, options] of [
    ['running 17', { running: true, serverNum: '170011', dataDir: '17' }],
    ['empty directory, first install', { dataDir: 'empty' }],
    ['fresh PG17 directory, no database running', { dataDir: '17' }],
  ]) {
    const r = run(options);
    assert.equal(r.status, 0, `${label}: ${r.stderr}`);
  }
});

test('setup.sh and start.sh run the preflight before anything is built or recreated', () => {
  for (const [script, first] of [['setup.sh', 'scripts/build-images.sh'], ['start.sh', 'scripts/drop-logical-slots.sh']]) {
    const text = readFileSync(new URL(`../${script}`, import.meta.url), 'utf8');
    const preflight = text.indexOf('scripts/db-version-preflight.sh');
    assert.ok(preflight > 0, `${script} runs the preflight`);
    assert.ok(preflight < text.indexOf(first), `${script}: before ${first}`);
  }
});

test('setup.sh checks an existing installation before configure.mjs rewrites its state', () => {
  const text = readFileSync(new URL('../setup.sh', import.meta.url), 'utf8');
  assert.ok(text.indexOf('scripts/db-version-preflight.sh') < text.indexOf('node "$ROOT/scripts/configure.mjs"'));
});

test('the commands that recreate db (key and password rotation, the pooler check) run the preflight first', () => {
  for (const [script, first] of [['rotate-keys.sh', '--force-recreate'], ['scripts/rotate-db-passwords.sh', '--force-recreate'], ['scripts/pooler-check.sh', 'up -d --wait']]) {
    const text = readFileSync(new URL(`../${script}`, import.meta.url), 'utf8');
    const preflight = text.indexOf('scripts/db-version-preflight.sh');
    assert.ok(preflight > 0, `${script} runs the preflight`);
    assert.ok(preflight < text.indexOf(first), `${script}: before ${first}`);
  }
});
