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
import { mkdtempSync, mkdirSync, writeFileSync, chmodSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { checkStatePlacement } from '../scripts/doctor.mjs';

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
  const health = source.indexOf("probe('bash', [resolve(root, 'health-check.sh')]");
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
