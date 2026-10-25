import test from 'node:test';
import assert from 'node:assert/strict';
import { supportedNode } from '../scripts/doctor-common.mjs';
import { canonicalOrigin } from '../scripts/configure.mjs';

test('operator configuration requires canonical HTTPS origins and supported Node', () => {
  assert.equal(supportedNode('22.17.0'), false);
  assert.equal(supportedNode('22.18.0'), true);
  assert.equal(canonicalOrigin('https://api.example.com'), 'https://api.example.com');
  for (const value of ['http://api.example.com', 'https://api.example.com/path', 'https://user:pass@api.example.com', 'https://api.example.com:8443', 'https://api.example.com?q=1']) assert.throws(() => canonicalOrigin(value));
});

// testvm2 F1 / known issue 3: a pre-created state under a root-owned parent passed
// the preflight and then failed with EACCES when setup staged its files next to it.
import { mkdtempSync, mkdirSync, writeFileSync, chmodSync, rmSync, utimesSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { checkStatePlacement, checkerWarnings, CHECKER_MAX_AGE_MS, NO_WEBHOOK_WARNING, timerUnit, dailyTimerUnit, freeSpaceVerdict } from '../scripts/doctor.mjs';

test('a fresh install refuses a state whose parent is not writable, naming the fix', { skip: process.getuid() === 0 && 'root can write anywhere' }, () => {
  const base = mkdtempSync(join(tmpdir(), 'state-parent-'));
  const parent = join(base, 'srv-warehouse');
  const state = join(parent, 'acme');
  try {
    mkdirSync(state, { recursive: true, mode: 0o700 });
    chmodSync(state, 0o700);
    chmodSync(parent, 0o555);
    assert.throws(() => checkStatePlacement(state), err => err.message.includes(`${parent} must be writable`) && err.message.includes('sudo chown'));
    chmodSync(parent, 0o755);
    assert.equal(checkStatePlacement(state), state);
  } finally { chmodSync(parent, 0o755); rmSync(base, { recursive: true, force: true }); }
});

test('a rerun of an installed state needs no write access to the parent', { skip: process.getuid() === 0 && 'root can write anywhere' }, () => {
  const base = mkdtempSync(join(tmpdir(), 'state-parent-'));
  const parent = join(base, 'srv-warehouse');
  const state = join(parent, 'acme');
  try {
    mkdirSync(join(state, 'config'), { recursive: true });
    chmodSync(state, 0o700);
    writeFileSync(join(state, 'config', 'compose.env'), 'AUTH_MODE=operator\n', { mode: 0o600 });
    chmodSync(parent, 0o555);
    assert.equal(checkStatePlacement(state), state);
  } finally { chmodSync(parent, 0o755); rmSync(base, { recursive: true, force: true }); }
});

test('a state that does not exist yet is checked against its parent', () => {
  const base = mkdtempSync(join(tmpdir(), 'state-parent-'));
  try {
    assert.equal(checkStatePlacement(join(base, 'acme')), base);
    assert.throws(() => checkStatePlacement('relative/path'), /absolute path outside this checkout/);
  } finally { rmSync(base, { recursive: true, force: true }); }
});

// TW-BE-020: central sign-in from a key file. The functions container reads public/<CENTRAL_JWKS_FILE>;
// when it is missing the router only logs a line, every exchange fails and get-public-config still offers
// central sign-in. A lost-host restore from a backup without the file left exactly that, with doctor passing.
import { readFileSync, symlinkSync } from 'node:fs';
import { checkCentralKeyFile } from '../scripts/doctor.mjs';
import { centralKeySet } from './backup-test-helpers.mjs';

function keyState(file) {
  const state = mkdtempSync(join(tmpdir(), 'doctor-central-'));
  mkdirSync(join(state, 'public'));
  if (file !== undefined) writeFileSync(join(state, 'public/central-jwks.json'), file);
  return state;
}
const fileEnv = { CENTRAL_ISSUER: 'https://login.association.example.test', CENTRAL_JWKS_URL: '', CENTRAL_JWKS_FILE: 'central-jwks.json' };

test('doctor fails when the configured central key file is missing, naming the file and the setup rerun', () => {
  const state = keyState();
  try {
    assert.throws(() => checkCentralKeyFile(fileEnv, state, { pending: false }), error => {
      assert.match(error.message, new RegExp(`${state}/public/central-jwks\\.json`));
      assert.match(error.message, /missing/);
      assert.match(error.message, /setup\.sh --operator[^]*--central-issuer https:\/\/login\.association\.example\.test[^]*--central-jwks-file/);
      return true;
    });
  } finally { rmSync(state, { recursive: true, force: true }); }
});

test('doctor accepts a usable central key file, and needs none when the keys are fetched or central sign-in is off', () => {
  const state = keyState(centralKeySet);
  const empty = keyState();
  try {
    assert.equal(checkCentralKeyFile(fileEnv, state, { pending: false }), '');
    // Nothing configured: no file is needed, whether or not one lies around.
    for (const env of [{}, { CENTRAL_ISSUER: '', CENTRAL_JWKS_URL: '', CENTRAL_JWKS_FILE: '' },
      { CENTRAL_ISSUER: fileEnv.CENTRAL_ISSUER, CENTRAL_JWKS_URL: 'https://login.association.example.test/jwks.json', CENTRAL_JWKS_FILE: '' }]) {
      assert.equal(checkCentralKeyFile(env, empty, { pending: false }), '');
    }
  } finally { rmSync(state, { recursive: true, force: true }); rmSync(empty, { recursive: true, force: true }); }
});

test('doctor fails on a central key file that is not a usable key set, or not a plain file', () => {
  const bad = {
    'not JSON': ['<html>moved</html>', /not a JSON key set/],
    'empty': ['', /not a JSON key set/],
    'no keys member': [JSON.stringify({ jwks: [] }), /not usable: key set malformed/],
    'no usable key': [JSON.stringify({ keys: [] }), /not usable: key set holds no P-256 signature key/],
    'larger than 64 KB': [JSON.stringify({ keys: JSON.parse(centralKeySet).keys, padding: 'x'.repeat(64 * 1024) }), /larger than 64 KB/],
  };
  for (const [label, [text, message]] of Object.entries(bad)) {
    const state = keyState(text);
    try {
      assert.throws(() => checkCentralKeyFile(fileEnv, state, { pending: false }), message, label);
      assert.throws(() => checkCentralKeyFile(fileEnv, state, { pending: true }), message, `${label}: the restore allowance covers a missing file only`);
    } finally { rmSync(state, { recursive: true, force: true }); }
  }
  const state = keyState();
  try {
    symlinkSync(join(state, 'public'), join(state, 'public/central-jwks.json'));
    assert.throws(() => checkCentralKeyFile(fileEnv, state, { pending: false }), /must be a regular file/);
    for (const name of ['../config/compose.env', '/etc/passwd', '.hidden', 'a b.json']) {
      assert.throws(() => checkCentralKeyFile({ ...fileEnv, CENTRAL_JWKS_FILE: name }, state, { pending: false }), /plain file name/, name);
    }
  } finally { rmSync(state, { recursive: true, force: true }); }
});

test('while a lost-host restore waits for the key file, doctor warns instead of failing the restore', () => {
  const state = keyState();
  const before = process.env.WAREHOUSE_CENTRAL_KEY_PENDING;
  try {
    const warning = checkCentralKeyFile(fileEnv, state, { pending: true });
    assert.match(warning, /central-jwks\.json[^]*missing[^]*setup\.sh --operator/);
    // restore-host hands this to restore.sh, and so to its doctor --local, through the environment; anything else is not an allowance.
    delete process.env.WAREHOUSE_CENTRAL_KEY_PENDING;
    assert.throws(() => checkCentralKeyFile(fileEnv, state), /missing/);
    process.env.WAREHOUSE_CENTRAL_KEY_PENDING = 'no';
    assert.throws(() => checkCentralKeyFile(fileEnv, state), /missing/);
    process.env.WAREHOUSE_CENTRAL_KEY_PENDING = 'yes';
    assert.match(checkCentralKeyFile(fileEnv, state), /missing/);
  } finally {
    if (before === undefined) delete process.env.WAREHOUSE_CENTRAL_KEY_PENDING; else process.env.WAREHOUSE_CENTRAL_KEY_PENDING = before;
    rmSync(state, { recursive: true, force: true });
  }
});

test('doctor runs the central key file check for --local and the full run, after the preflight return and before the health check', () => {
  const source = readFileSync(new URL('../scripts/doctor.mjs', import.meta.url), 'utf8');
  const call = source.indexOf('checkCentralKeyFile(env, state)');
  const preflight = source.indexOf("return 'Operator configuration, private paths and gateway port preflight passed.'");
  const health = source.indexOf('const health = await runHealth(');
  assert.ok(preflight > 0 && health > preflight, 'the doctor still has the shape this test expects');
  assert.ok(call > preflight && call < health, 'checkCentralKeyFile(env, state) sits between them');
  assert.equal(source.split('checkCentralKeyFile(env, state)').length, 2, 'one call site');
});

// X-6: the Compose requirement is the `up --wait-timeout` flag, checked by running doctor against a fake docker.
import { spawnSync } from 'node:child_process';
import { statfsSync } from 'node:fs';

function doctorWithCompose(help) {
  const base = mkdtempSync(join(tmpdir(), 'doctor-compose-'));
  try {
    const bin = join(base, 'bin');
    mkdirSync(bin);
    writeFileSync(join(bin, 'docker'), `#!/bin/sh
case "$*" in
  'compose version') echo 'Docker Compose version v2.40.3' ;;
  'info --format {{.ServerVersion}}') echo 29.9.1 ;;
  'compose up --help') printf '%s\\n' ${JSON.stringify(help)} ;;
  *) exit 1 ;;
esac
`, { mode: 0o755 });
    const state = join(base, 'state');
    mkdirSync(state, { mode: 0o700 });
    return spawnSync(process.execPath, [new URL('../scripts/doctor.mjs', import.meta.url).pathname, '--host-preflight'], {
      encoding: 'utf8', env: { ...process.env, PATH: `${bin}:${process.env.PATH}`, WAREHOUSE_STATE_DIR: state, NODE_TEST_CONTEXT: '' } });
  } finally { rmSync(base, { recursive: true, force: true }); }
}

test('doctor passes the Compose check when `up --help` lists --wait-timeout', { skip: Number(statfsSync(tmpdir()).bavail) * Number(statfsSync(tmpdir()).bsize) < 10 * 1024 ** 3 && 'needs 10 GiB free in the temp directory' }, () => {
  const run = doctorWithCompose('      --wait-timeout int   Maximum duration in seconds to wait for the project to be running|healthy');
  assert.equal(run.status, 0, run.stderr);
  assert.match(run.stdout, /Host prerequisites and state filesystem preflight passed/);
});

test('doctor refuses a Compose plugin whose `up --help` lacks --wait-timeout, and says so', () => {
  const run = doctorWithCompose('      --wait   Wait for services to be running|healthy');
  assert.equal(run.status, 1);
  assert.match(run.stderr, /does not accept `up --wait-timeout`/);
});

// The monitoring checker (scripts/watch.mjs, a systemd timer) replaced the Alertmanager warning.
const HOOK = 'https://hooks.slack.com/services/' + 'T0000000/B0000000/fictionalfictionalfictional';
function checkerState({ webhook = true, ran = null, daily = null } = {}) {
  const base = mkdtempSync(join(tmpdir(), 'doctor-checker-'));
  const state = join(base, 'acme');
  mkdirSync(join(state, 'config'), { recursive: true });
  writeFileSync(join(state, 'config/compose.env'), 'WAREHOUSE_PROJECT_NAME=warehouse-acme\n', { mode: 0o600 });
  if (webhook) writeFileSync(join(state, 'config/slack-webhook-url'), `${HOOK}\n`, { mode: 0o600 });
  if (ran !== null) {
    const file = join(state, 'config/watch-state.json');
    writeFileSync(file, daily === null ? '{}\n' : `${JSON.stringify({ dailyRunning: { job: 'daily', startedAt: daily } })}\n`);
    utimesSync(file, new Date(ran), new Date(ran));
  }
  return { base, state };
}

test('doctor is silent when the timer is active, the checker ran 4 minutes ago and a webhook is stored', () => {
  const now = Date.now();
  const f = checkerState({ ran: now - 4 * 60 * 1000 });
  try { assert.deepEqual(checkerWarnings(f.state, { now, timerActive: () => true }), []); } finally { rmSync(f.base, { recursive: true, force: true }); }
});

test('doctor warns, naming the unit and the install command, when the timer is not installed or not active', () => {
  const now = Date.now();
  const f = checkerState({ ran: now - 60 * 1000 });
  try {
    const asked = [];
    const out = checkerWarnings(f.state, { now, timerActive: unit => { asked.push(unit); return false; } });
    assert.deepEqual(asked, ['warehouse-acme-watch.timer']);
    assert.equal(timerUnit(f.state), 'warehouse-acme-watch.timer');
    assert.equal(out.length, 1);
    assert.match(out[0], /warehouse-acme-watch\.timer is not installed or not active/);
    assert.ok(out[0].includes(`sudo bash scripts/watch-timer.sh install --state ${f.state}`));
  } finally { rmSync(f.base, { recursive: true, force: true }); }
});

test('the unit is named from the Compose project, so two states that both end in /state get different units', () => {
  const a = checkerState(); const b = checkerState();
  try {
    const one = join(a.base, 'state'); const two = join(b.base, 'state');
    mkdirSync(join(one, 'config'), { recursive: true }); mkdirSync(join(two, 'config'), { recursive: true });
    writeFileSync(join(one, 'config/compose.env'), 'WAREHOUSE_PROJECT_NAME=warehouse-aaaaaaaaaaaa\n');
    writeFileSync(join(two, 'config/compose.env'), 'WAREHOUSE_PROJECT_NAME=warehouse-bbbbbbbbbbbb\n');
    assert.equal(timerUnit(one), 'warehouse-aaaaaaaaaaaa-watch.timer');
    assert.equal(timerUnit(two), 'warehouse-bbbbbbbbbbbb-watch.timer');
    // No readable project: a hash of the whole path (watch-timer.sh computes the same with sha256sum).
    const gone = join(a.base, 'gone/state'); const other = join(b.base, 'gone/state');
    assert.match(timerUnit(gone), /^warehouse-h[0-9a-f]{12}-watch\.timer$/);
    assert.notEqual(timerUnit(gone), timerUnit(other));
  } finally { for (const f of [a, b]) rmSync(f.base, { recursive: true, force: true }); }
});

test('doctor warns when the installed service names another state, and stays silent when it names this one', () => {
  const now = Date.now();
  const f = checkerState({ ran: now - 60 * 1000 });
  try {
    const own = checkerWarnings(f.state, { now, timerActive: () => true, serviceText: () => `[Service]\nEnvironment=WAREHOUSE_STATE_DIR=${f.state}\n` });
    assert.deepEqual(own, []);
    const wrong = checkerWarnings(f.state, { now, timerActive: () => true, serviceText: () => '[Service]\nEnvironment=WAREHOUSE_STATE_DIR=/elsewhere/state\n' });
    assert.equal(wrong.length, 1);
    assert.match(wrong[0], /service does not name this state/);
    assert.ok(wrong[0].includes(`install --state ${f.state}`));
  } finally { rmSync(f.base, { recursive: true, force: true }); }
});

test('doctor reports a silent checker even while a daily backup is in progress: the backup is a separate unit now', () => {
  const now = Date.now();
  const silent = checkerState({ ran: now - 3 * 60 * 60 * 1000, daily: now - 3 * 60 * 60 * 1000 });
  try {
    const out = checkerWarnings(silent.state, { now, timerActive: () => true });
    assert.equal(out.length, 1);
    assert.match(out[0], /last ran 180 minutes ago/);
  } finally { rmSync(silent.base, { recursive: true, force: true }); }
});

test('doctor warns, naming the unit and the install command, when the daily backup timer is not active', () => {
  const now = Date.now();
  const f = checkerState({ ran: now - 60 * 1000 });
  try {
    const asked = [];
    const out = checkerWarnings(f.state, { now, timerActive: unit => { asked.push(unit); return unit.endsWith('-watch.timer'); } });
    assert.deepEqual(asked, ['warehouse-acme-watch.timer', 'warehouse-acme-daily.timer']);
    assert.equal(dailyTimerUnit(f.state), 'warehouse-acme-daily.timer');
    assert.equal(out.length, 1);
    assert.match(out[0], /daily backup timer warehouse-acme-daily\.timer is not installed or not active, so no backup, verification or retention runs/);
    assert.ok(out[0].includes(`sudo bash scripts/watch-timer.sh install --state ${f.state}`));
    // Without the checker's timer one warning is enough: its install command brings the daily timer too.
    assert.equal(checkerWarnings(f.state, { now, timerActive: () => false }).length, 1);
    // A hash-named unit (no readable project) gets the same sibling name.
    assert.match(dailyTimerUnit(join(f.base, 'gone/state')), /^warehouse-h[0-9a-f]{12}-daily\.timer$/);
  } finally { rmSync(f.base, { recursive: true, force: true }); }
});

test('doctor warns when an active timer has not produced a run for 15 minutes, or ever', () => {
  const now = Date.now();
  const stale = checkerState({ ran: now - CHECKER_MAX_AGE_MS - 60 * 1000 });
  const never = checkerState();
  const edge = checkerState({ ran: now - CHECKER_MAX_AGE_MS + 60 * 1000 });
  try {
    const old = checkerWarnings(stale.state, { now, timerActive: () => true });
    assert.equal(old.length, 1);
    assert.match(old[0], /last ran 16 minutes ago \(it should run every 5\)/);
    const none = checkerWarnings(never.state, { now, timerActive: () => true });
    assert.equal(none.length, 1);
    assert.match(none[0], /active but the monitoring checker has never run/);
    assert.deepEqual(checkerWarnings(edge.state, { now, timerActive: () => true }), [], '14 minutes is fine');
  } finally { for (const f of [stale, never, edge]) rmSync(f.base, { recursive: true, force: true }); }
});

test('doctor keeps the no-webhook warning, also with --alert-webhook-file off, and a stored webhook at the old path counts', () => {
  const now = Date.now();
  const off = checkerState({ webhook: false, ran: now - 60 * 1000 });
  const legacy = checkerState({ webhook: false, ran: now - 60 * 1000 });
  try {
    assert.deepEqual(checkerWarnings(off.state, { now, timerActive: () => true }), [NO_WEBHOOK_WARNING]);
    assert.match(NO_WEBHOOK_WARNING, /^No Slack webhook: alerts are recorded on this host but not delivered/);
    mkdirSync(join(legacy.state, 'config/monitoring/alertmanager'), { recursive: true });
    writeFileSync(join(legacy.state, 'config/monitoring/alertmanager/webhook-url'), `${HOOK}\n`, { mode: 0o600 });
    assert.deepEqual(checkerWarnings(legacy.state, { now, timerActive: () => true }), []);
    const all = checkerState({ webhook: false });
    try { assert.equal(checkerWarnings(all.state, { now, timerActive: () => false }).length, 2, 'timer and webhook'); } finally { rmSync(all.base, { recursive: true, force: true }); }
  } finally { for (const f of [off, legacy]) rmSync(f.base, { recursive: true, force: true }); }
});

test('free space: a new installation needs 10 GiB; a start only warns below 10 GiB and refuses below 2 GiB', () => {
  const GiB = 1024 ** 3;
  assert.deepEqual(freeSpaceVerdict(10 * GiB, { newInstall: true }), {});
  assert.match(freeSpaceVerdict(10 * GiB - 1, { newInstall: true }).error, /At least 10 GiB free space is required/);
  assert.deepEqual(freeSpaceVerdict(10 * GiB), {});
  const warn = freeSpaceVerdict(7.5 * GiB);
  assert.equal(warn.error, undefined);
  assert.match(warn.warning, /Only 7\.5 GiB is free[^]*less than 10 GiB[^]*Disk full/);
  assert.deepEqual(Object.keys(freeSpaceVerdict(2 * GiB)), ['warning'], '2 GiB exactly still starts');
  assert.match(freeSpaceVerdict(2 * GiB - 1).error, /At least 2 GiB free space is required[^]*\(2\.0 GiB is free\)/);
  // The scripts use the right mode: only setup's host preflight is strict.
  const doctor = readFileSync(new URL('../scripts/doctor.mjs', import.meta.url), 'utf8');
  assert.match(doctor, /freeSpaceVerdict\(Number\(fs\.bavail\) \* Number\(fs\.bsize\), \{ newInstall: hostPreflight \}\)/);
});
