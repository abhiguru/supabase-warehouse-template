import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, rmSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

// scripts/db-version-preflight.sh against a fake docker: a running database, or a data directory whose PG_VERSION is not the
// major of the pin (18), is refused before anything is built or recreated: 17 with the pointer to the major upgrade, an earlier one
// with the pointer to the baseline reload.
function run({ running = false, serverNum = '180006', dataDir = 'empty' }) {
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

const REFUSAL = /Refusing: .*PostgreSQL 18.*migrations-pre-baseline.*Baseline reload/s;
const UPGRADE = /Refusing: .*PostgreSQL 18 and cannot start on PostgreSQL 17 data.*Major PostgreSQL upgrade/s;

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
  assert.match(dockerRun, /-v .*\/data\/db:\/d:ro postgres:18\.\S+@sha256:[0-9a-f]{64} /);
  assert.match(dockerRun, /--network none/);
});

test('a running PostgreSQL 17 and a data directory of 17 are refused with the pointer to the major upgrade, not the baseline reload', () => {
  const running = run({ running: true, serverNum: '170011', dataDir: '17' });
  assert.equal(running.status, 1);
  assert.match(running.stderr, UPGRADE);
  assert.doesNotMatch(running.stderr, /Baseline reload/);
  const dir = run({ dataDir: '17' });
  assert.equal(dir.status, 1);
  assert.match(dir.stderr, UPGRADE);
  assert.match(dir.stderr, /holds a PostgreSQL 17 database/);
});

test('data of a newer major than the pin is refused, naming a newer release', () => {
  const r = run({ dataDir: '19' });
  assert.equal(r.status, 1);
  assert.match(r.stderr, /cannot start on newer data.*Check out the release that runs PostgreSQL 19/s);
});

test('a running PostgreSQL 18, an empty data directory and a PG_VERSION of 18 pass', () => {
  for (const [label, options] of [
    ['running 18', { running: true, serverNum: '180006', dataDir: '18' }],
    ['empty directory, first install', { dataDir: 'empty' }],
    ['PG18 directory, no database running', { dataDir: '18' }],
  ]) {
    const r = run(options);
    assert.equal(r.status, 0, `${label}: ${r.stderr}`);
  }
});

test('setup.sh and start.sh run the preflight before anything is built or recreated', () => {
  for (const [script, first] of [['setup.sh', 'scripts/build-images.sh'], ['start.sh', 'scripts/compose.sh" up -d']]) {
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
  for (const [script, first] of [['rotate-keys.sh', '--force-recreate'], ['scripts/rotate-db-passwords.sh', '--force-recreate'], ['tests/pooler-check.sh', 'up -d --wait']]) {
    const text = readFileSync(new URL(`../${script}`, import.meta.url), 'utf8');
    const preflight = text.indexOf('scripts/db-version-preflight.sh');
    assert.ok(preflight > 0, `${script} runs the preflight`);
    assert.ok(preflight < text.indexOf(first), `${script}: before ${first}`);
  }
});

test('every place that mounts the data directory also sets PGDATA to it (the official 18 image defaults elsewhere)', () => {
  const read = file => readFileSync(new URL(`../${file}`, import.meta.url), 'utf8');
  assert.match(read('docker/docker-compose.yml'), /PGDATA: \/var\/lib\/postgresql\/data\n/);
  assert.match(read('docker/docker-compose.yml'), /:\/var\/lib\/postgresql\/data:Z/);
  for (const file of ['tests/migrations.sh', 'scripts/baseline/lib.sh']) assert.match(read(file), /--tmpfs \/var\/lib\/postgresql\/data:rw,size=768m -e PGDATA=\/var\/lib\/postgresql\/data/, file);
  const verify = read('scripts/verify-restore.sh');
  assert.equal(verify.match(/-e PGDATA=\/var\/lib\/postgresql\/data/g)?.length, 2, 'tmpfs and disk runs');
  assert.match(read('scripts/compose.sh'), /destination='\/var\/lib\/postgresql\/data'/);
});

test('a running PostgreSQL 19 server is refused, naming a newer release', () => {
  const r = run({ running: true, serverNum: '190001', dataDir: '18' });
  assert.equal(r.status, 1);
  assert.match(r.stderr, /server_version_num 190001 \(PostgreSQL 19\).*cannot start on newer data.*PostgreSQL 19/s);
});

test('an unknown data directory passes silently, an unreadable one only warns', () => {
  const unknown = run({ dataDir: 'unknown' });
  assert.equal(unknown.status, 0, unknown.stderr);
  assert.equal(unknown.stderr, '');
  const unreadable = run({ dataDir: 'unreadable' });
  assert.equal(unreadable.status, 0, unreadable.stderr);
  assert.match(unreadable.stderr, /Warning: could not read the data directory .* its PostgreSQL version was not checked/);
});
