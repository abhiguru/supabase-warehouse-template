import test from 'node:test';
import assert from 'node:assert/strict';
import { supportedNode, waitForDocker, DOCKER_WAIT_MS } from '../scripts/doctor-common.mjs';
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
import { checkStatePlacement, checkerWarnings, CHECKER_MAX_AGE_MS, NO_WEBHOOK_WARNING, stoppedWarning, timerUnit, dailyTimerUnit, freeSpaceVerdict } from '../scripts/doctor.mjs';

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
import { checkAppCompatFile, checkCentralKeyFile } from '../scripts/doctor.mjs';
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

function doctorWithCompose(help, extraBin = {}, mode = '--host-preflight') {
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
    for (const [name, body] of Object.entries(extraBin)) writeFileSync(join(bin, name), `#!/bin/sh\n${body}\n`, { mode: 0o755 });
    const state = join(base, 'state');
    mkdirSync(state, { mode: 0o700 });
    return spawnSync(process.execPath, [new URL('../scripts/doctor.mjs', import.meta.url).pathname, mode], {
      encoding: 'utf8', env: { ...process.env, PATH: `${bin}:${process.env.PATH}`, WAREHOUSE_STATE_DIR: state, NODE_TEST_CONTEXT: '' } });
  } finally { rmSync(base, { recursive: true, force: true }); }
}

test('doctor passes the Compose check when `up --help` lists --wait-timeout', { skip: Number(statfsSync(tmpdir()).bavail) * Number(statfsSync(tmpdir()).bsize) < 10 * 1024 ** 3 && 'needs 10 GiB free in the temp directory' }, () => {
  const run = doctorWithCompose('      --wait-timeout int   Maximum duration in seconds to wait for the project to be running|healthy');
  assert.equal(run.status, 0, run.stderr);
  assert.match(run.stdout, /Host prerequisites and state filesystem preflight passed/);
});

// Backups copy the stored files with rsync and unpack archives with GNU tar --xattrs (scripts/backup.sh, restore-host.sh).
// Setup and restore-host (--host-preflight) refuse a host without them and name the install command; start.sh (--preflight) and
// the other runs only warn, so a host that pulled this release without installing rsync can still start its services.
const WAIT = '      --wait-timeout int   Maximum duration in seconds to wait for the project to be running|healthy';
const SPACE = { skip: Number(statfsSync(tmpdir()).bavail) * Number(statfsSync(tmpdir()).bsize) < 10 * 1024 ** 3 && 'needs 10 GiB free in the temp directory' };
const NO_XATTRS = 'echo "rsync  version 3.2.7  protocol version 31"; printf "Capabilities:\\n    64-bit files, socketpairs, symlinks, hardlinks, ACLs,\\n    no xattrs, iconv\\nOptimizations:\\n    SIMD-roll, no asm-roll\\n"';
const WITH_XATTRS = 'echo "rsync  version 3.2.7  protocol version 31"; printf "Capabilities:\\n    64-bit files, socketpairs, symlinks, hardlinks, ACLs,\\n    xattrs, optional secluded-args, iconv\\nOptimizations:\\n    SIMD-roll, no asm-roll\\n"';
const BSD_TAR = 'case "$*" in *--xattrs*) echo "tar: unrecognized option --xattrs" >&2; exit 1 ;; esac; echo "bsdtar 3.7.2"';

test('doctor --host-preflight refuses a host without rsync, and names the install command', SPACE, () => {
  const run = doctorWithCompose(WAIT, { rsync: 'exit 127' });
  assert.equal(run.status, 1);
  assert.match(run.stderr, /Doctor: Missing or unavailable prerequisite: rsync \(the package rsync\) is missing; .*Install it: sudo apt-get install rsync/);
});

test('doctor --host-preflight refuses an rsync built without extended attributes, and a tar that is not GNU tar with --xattrs', SPACE, () => {
  let run = doctorWithCompose(WAIT, { rsync: NO_XATTRS });
  assert.equal(run.status, 1);
  assert.match(run.stderr, /Missing or unavailable prerequisite: this rsync was built without extended-attribute support .*Install the distribution's rsync: sudo apt-get install rsync/);
  run = doctorWithCompose(WAIT, { rsync: WITH_XATTRS });
  assert.equal(run.status, 0, run.stderr);
  assert.match(run.stdout, /Host prerequisites and state filesystem preflight passed/);
  run = doctorWithCompose(WAIT, { tar: BSD_TAR });
  assert.equal(run.status, 1);
  assert.match(run.stderr, /Missing or unavailable prerequisite: GNU tar with --xattrs support is missing; .*Install it: sudo apt-get install tar/);
  // Both missing: both are named in the one refusal.
  run = doctorWithCompose(WAIT, { rsync: 'exit 127', tar: BSD_TAR });
  assert.equal(run.status, 1);
  assert.match(run.stderr, /rsync \(the package rsync\) is missing[\s\S]*GNU tar with --xattrs support is missing/);
});

test('doctor --preflight and --local only warn about a missing rsync or tar: start.sh must still start the services', SPACE, () => {
  // The run goes on past the prerequisites and stops at the state, which this fixture does not have: that is the error, not rsync.
  for (const mode of ['--preflight', '--local']) {
    const run = doctorWithCompose(WAIT, { rsync: 'exit 127', tar: BSD_TAR }, mode);
    assert.match(run.stderr, /Warning: rsync \(the package rsync\) is missing; .*Install it: sudo apt-get install rsync\. The services start without it, but backups and restores need it\./, mode);
    assert.match(run.stderr, /Warning: GNU tar with --xattrs support is missing; .*Install it: sudo apt-get install tar\./, mode);
    assert.doesNotMatch(run.stderr, /Missing or unavailable prerequisite/, `${mode}: not a refusal`);
    assert.match(run.stderr, /Doctor: Configuration is missing; run the documented setup first\./, `${mode}: it got as far as the configuration`);
    const clean = doctorWithCompose(WAIT, {}, mode);
    assert.doesNotMatch(clean.stderr, /Warning: (rsync|GNU tar)/, `${mode}: nothing to warn about on a host that has both`);
  }
});

test('doctor refuses a Compose plugin whose `up --help` lacks --wait-timeout, and says so', () => {
  const run = doctorWithCompose('      --wait   Wait for services to be running|healthy');
  assert.equal(run.status, 1);
  assert.match(run.stderr, /does not accept `up --wait-timeout`/);
});

// H1 (review of the nginx gateway): the port preflight of setup.sh and start.sh must accept a port that the installation's own `kong`
// container (the release before the nginx gateway) still holds, or the documented upgrade stops before `up --remove-orphans` can
// replace it; and it must still refuse a port that a stranger holds. A real operator state (scripts/configure.mjs) and a real
// listener, with a fake docker that answers as the Docker of a host whose project has the containers the test names.
import { createServer } from 'node:net';
import { spawn } from 'node:child_process';
import { copyFileSync } from 'node:fs';
import { configure } from '../scripts/configure.mjs';
import { projectPublishesPort } from '../scripts/doctor.mjs';

const FAKE_DOCKER = `#!/bin/sh
case "$*" in
  'compose version') echo 'Docker Compose version v2.40.3' ;;
  'info --format {{.ServerVersion}}') echo 29.9.1 ;;
  'compose up --help') echo '      --wait-timeout int   Maximum duration in seconds to wait for the project to be running|healthy' ;;
  'ps -aq --filter label=com.docker.compose.project='*) ;;
  "ps --filter label=com.docker.compose.project=$FAKE_PROJECT --format {{.Ports}}") printf '%s\\n' "$FAKE_PORTS" ;;
  'ps --filter label=com.docker.compose.project='*' --format {{.Ports}}') ;;
  *' ps -q gateway') printf '%s' "$FAKE_GATEWAY" ;;
  *) exit 1 ;;
esac
`;

async function gatewayPreflight({ holdPort, ports = '', gateway = '', project = null }) {
  const scratch = mkdtempSync(join(tmpdir(), 'doctor-port-'));
  const server = createServer();
  try {
    const checkout = join(scratch, 'checkout');
    mkdirSync(checkout);
    copyFileSync(new URL('../.env.example', import.meta.url), join(checkout, '.env.example'));
    const providerEnv = join(scratch, 'provider.env');
    writeFileSync(providerEnv, 'SMS_PROVIDER=msg91\nMSG91_AUTH_KEY=real-provider-key\nMSG91_TEMPLATE_ID=flow-id\nMSG91_PE_ID=pe-id\nMSG91_SENDER_ID=WHOUSE\n', { mode: 0o600 });
    const state = join(scratch, 'state');
    configure(checkout, { stateDir: state, apiUrl: 'https://api.example.com', appUrl: 'https://app.example.com', company: 'Acme Stores', providerEnv });
    // A free port, which a listener takes when the case has a process holding it.
    await new Promise(done => server.listen(0, '127.0.0.1', done));
    const port = server.address().port;
    if (!holdPort) await new Promise(done => server.close(done));
    const envPath = join(state, 'config/compose.env');
    // The installation made before the nginx gateway: its port line has the old name.
    writeFileSync(envPath, readFileSync(envPath, 'utf8').replace(/^GATEWAY_HTTP_PORT=.*$/m, `KONG_HTTP_PORT=${port}`), { mode: 0o600 });
    const projectName = /^WAREHOUSE_PROJECT_NAME=(.*)$/m.exec(readFileSync(envPath, 'utf8'))[1];
    const bin = join(scratch, 'bin');
    mkdirSync(bin);
    writeFileSync(join(bin, 'docker'), FAKE_DOCKER, { mode: 0o755 });
    const env = { ...process.env, PATH: `${bin}:${process.env.PATH}`, WAREHOUSE_STATE_DIR: state, NODE_TEST_CONTEXT: '',
      FAKE_PROJECT: project ?? projectName, FAKE_PORTS: ports.replaceAll('{port}', String(port)), FAKE_GATEWAY: gateway };
    const child = spawn(process.execPath, [new URL('../scripts/doctor.mjs', import.meta.url).pathname, '--preflight'], { env });
    let stdout = '';
    let stderr = '';
    child.stdout.on('data', chunk => { stdout += chunk; });
    child.stderr.on('data', chunk => { stderr += chunk; });
    const status = await new Promise(done => child.on('close', done));
    return { status, stdout, stderr, port };
  } finally { server.close(); rmSync(scratch, { recursive: true, force: true }); }
}
const enoughSpace = Number(statfsSync(tmpdir()).bavail) * Number(statfsSync(tmpdir()).bsize) >= 3 * 1024 ** 3;
const portSkip = !enoughSpace && 'needs 3 GiB free in the temp directory (doctor refuses below 2 GiB)';

test('port preflight: the old kong container of this project holds the gateway port, and the upgrade is let through', { skip: portSkip }, async () => {
  const run = await gatewayPreflight({ holdPort: true, ports: '127.0.0.1:{port}->8000/tcp' });
  assert.equal(run.status, 0, run.stderr);
  assert.match(run.stdout, /gateway port preflight passed/);
});

test('port preflight: the nginx gateway container of this project holds the port, and a free port passes', { skip: portSkip }, async () => {
  const running = await gatewayPreflight({ holdPort: true, ports: '127.0.0.1:{port}->8000/tcp', gateway: 'abc123' });
  assert.equal(running.status, 0, running.stderr);
  const free = await gatewayPreflight({ holdPort: false });
  assert.equal(free.status, 0, free.stderr);
});

test('port preflight: a process or a container of another project on the port is still refused', { skip: portSkip }, async () => {
  // Nothing of the project publishes the port: a stranger holds it.
  const foreign = await gatewayPreflight({ holdPort: true });
  assert.equal(foreign.status, 1);
  assert.match(foreign.stderr, new RegExp(`Loopback gateway port ${foreign.port} is already in use`));
  // A container of another Compose project publishes it (the fake answers the question for that project only).
  const other = await gatewayPreflight({ holdPort: true, ports: '127.0.0.1:{port}->8000/tcp', project: 'warehouse-someoneelse' });
  assert.equal(other.status, 1);
  assert.match(other.stderr, /is already in use/);
  // A container of this project that publishes some other port does not make this one its own.
  const elsewhere = await gatewayPreflight({ holdPort: true, ports: '127.0.0.1:1->5432/tcp' });
  assert.equal(elsewhere.status, 1);
  assert.match(elsewhere.stderr, /is already in use/);
});

test('port preflight: the way docker prints published ports is read in each form', () => {
  const answer = ports => (_command, _args) => ({ ok: true, output: `${ports}\n` });
  assert.equal(projectPublishesPort('warehouse-x', 18000, answer('127.0.0.1:18000->8000/tcp')), true);
  assert.equal(projectPublishesPort('warehouse-x', 18000, answer('5432/tcp, 127.0.0.1:18000->8000/tcp, [::1]:18000->8000/tcp')), true);
  assert.equal(projectPublishesPort('warehouse-x', 18000, answer('[::1]:18000->8000/tcp')), true);
  assert.equal(projectPublishesPort('warehouse-x', 18001, answer('127.0.0.1:18000-18002->8000-8002/tcp')), true);
  assert.equal(projectPublishesPort('warehouse-x', 18000, answer('5432/tcp\n3000/tcp')), false, 'exposed but not published');
  assert.equal(projectPublishesPort('warehouse-x', 18000, answer('127.0.0.1:118000->8000/tcp')), false);
  assert.equal(projectPublishesPort('warehouse-x', 18000, answer('127.0.0.1:1800->8000/tcp')), false);
  assert.equal(projectPublishesPort('warehouse-x', 18000, answer('')), false);
  assert.equal(projectPublishesPort('warehouse-x', 18000, () => ({ ok: false, output: '' })), false, 'docker could not answer');
  // The question is asked of this project's containers only.
  let asked;
  projectPublishesPort('warehouse-x', 18000, (command, args) => { asked = [command, ...args]; return { ok: true, output: '' }; });
  assert.deepEqual(asked.slice(0, 4), ['docker', 'ps', '--filter', 'label=com.docker.compose.project=warehouse-x']);
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

test('doctor says that the backup still runs from an old checker unit (one that carries the daily time), with the command, and not that no backup runs', () => {
  const now = Date.now();
  const f = checkerState({ ran: now - 60 * 1000 });
  try {
    const old = `[Service]\nEnvironment=WAREHOUSE_STATE_DIR=${f.state}\nEnvironment=WAREHOUSE_WATCH_DAILY_AT=02:30\nExecStart=/n/node /r/scripts/watch.mjs run\n`;
    const out = checkerWarnings(f.state, { now, timerActive: unit => unit.endsWith('-watch.timer'), serviceText: () => old });
    assert.equal(out.length, 1, 'one warning: the daily timer is missing because the old unit still does the work');
    assert.match(out[0], /The daily backup still runs from the old monitoring checker unit warehouse-acme-watch\.service, inside its 5-minute run: backups continue, but a long backup holds the checks off and the services do not start at boot\./);
    assert.match(out[0], /Run: sudo bash \S+\/scripts\/watch-timer\.sh install --state /);
    assert.ok(out[0].includes(`--state ${f.state}`));
    assert.doesNotMatch(out[0], /no backup, verification or retention runs/);
    // The unit written now carries no daily time: a missing daily timer then does mean no backup.
    const fresh = checkerWarnings(f.state, { now, timerActive: unit => unit.endsWith('-watch.timer'), serviceText: () => `[Service]\nEnvironment=WAREHOUSE_STATE_DIR=${f.state}\n` });
    assert.match(fresh[0], /so no backup, verification or retention runs/);
  } finally { rmSync(f.base, { recursive: true, force: true }); }
});

test('doctor says the stack was stopped by the operator while config/stopped-by-operator exists, and adds it to a failing health check', () => {
  const now = Date.now();
  const f = checkerState({ ran: now - 60 * 1000 });
  try {
    assert.deepEqual(checkerWarnings(f.state, { now, timerActive: () => true }), []);
    writeFileSync(join(f.state, 'config/stopped-by-operator'), 'stopped by stop.sh\n');
    const out = checkerWarnings(f.state, { now, timerActive: () => true });
    assert.equal(out.length, 1);
    assert.equal(out[0], stoppedWarning);
    assert.match(out[0], /stopped by the operator \(config\/stopped-by-operator, written by stop\.sh\): the boot unit and self-healing leave it down, also after a reboot\. Run start\.sh to bring it back\./);
    // doctor.mjs adds the same sentence to the failure of a local health check.
    assert.match(readFileSync(new URL('../scripts/doctor.mjs', import.meta.url), 'utf8'), /Local service health check failed: .*\$\{stoppedByOperator\(state\) \? ` \$\{stoppedWarning\}` : ''\}/);
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

// ---- the LAN fallback checks (scripts/lan.mjs, lanChecks), as doctor reports them ---------------------------------------------------
import { lanDoctor, lanReport } from '../scripts/doctor.mjs';

const LAN_HOST = [{ name: 'ens33', address: '192.168.1.52', prefix: 24, cidr: '192.168.1.0/24', defaultRoute: true }];
const LAN_ENV = { LAN_ENABLED: 'true', LAN_BIND_IP: '192.168.1.52', LAN_HTTP_PORT: '8080', LAN_CIDR: '192.168.1.0/24', COMPOSE_PROFILES: 'lan', WAREHOUSE_PROJECT_NAME: 'warehouse-test', ANON_KEY: 'unit.anon.key' };
const LAN_ANSWER = { ok: true, status: 200, headers: new Headers({ 'x-warehouse-path': 'lan' }), json: async () => ({ success: true, data: { instanceId: 'iid-1' } }) };
const lanOptions = (over = {}) => ({ interfaces: LAN_HOST, run: () => ({ ok: true, output: '192.168.1.52:8080->8080/tcp\n' }), fetchImpl: async () => LAN_ANSWER, readText: () => '', ...over });

test('doctor LAN report: nothing while off; the address line while it works; the failures and warnings when it does not', async () => {
  assert.deepEqual(await lanReport({ ...LAN_ENV, LAN_ENABLED: 'false' }, 'iid-1', lanOptions()), { failures: [], warnings: [], address: '' });
  assert.deepEqual(await lanReport({}, 'iid-1', lanOptions()), { failures: [], warnings: [], address: '' });
  assert.deepEqual(await lanReport(LAN_ENV, 'iid-1', lanOptions()), { failures: [], warnings: [], address: 'LAN address for the app: http://192.168.1.52:8080' });
  const gone = await lanReport(LAN_ENV, 'iid-1', lanOptions({ interfaces: [] }));
  assert.equal(gone.address, 'LAN address for the app: http://192.168.1.52:8080', 'the address is still printed, so the operator sees what the phones have saved');
  assert.match(gone.failures[0], /LAN_BIND_IP 192\.168\.1\.52 is not an address of this host \(it has no IPv4 address\)/);
  const silent = await lanReport(LAN_ENV, 'iid-1', lanOptions({ fetchImpl: async () => { throw new Error('boom'); } }));
  assert.match(silent.failures[0], /does not answer from this host \(boom\)/);
  const wrongPublisher = await lanReport(LAN_ENV, 'iid-1', lanOptions({ run: () => ({ ok: true, output: '0.0.0.0:8080->8080/tcp\n' }) }));
  assert.match(wrongPublisher.failures[0], /not only on 192\.168\.1\.52:8080/);
  const noDocker = await lanReport(LAN_ENV, 'iid-1', lanOptions({ run: () => ({ ok: false, output: '' }) }));
  assert.deepEqual([noDocker.failures.length, noDocker.warnings.length], [0, 1]);
});

test('doctor --lan: the address and a closing line when it works; an error naming each failure when it does not; a hint while it is off', async () => {
  const scratch = mkdtempSync(join(tmpdir(), 'doctor-lan-'));
  const saved = process.env.WAREHOUSE_STATE_DIR;
  try {
    const state = join(scratch, 'state');
    const provider = join(scratch, 'provider.env');
    writeFileSync(provider, 'SMS_PROVIDER=msg91\nMSG91_AUTH_KEY=isolated-no-delivery-key\nMSG91_TEMPLATE_ID=000000000000000000000001\nMSG91_PE_ID=1\nMSG91_SENDER_ID=CHECK\n', { mode: 0o600 });
    configure(new URL('..', import.meta.url).pathname, { stateDir: state, apiUrl: 'https://api.example.test', company: 'Acme', providerEnv: provider });
    process.env.WAREHOUSE_STATE_DIR = state;
    const manifest = JSON.parse(readFileSync(join(state, 'public/instance.json'), 'utf8'));
    const answer = { ...LAN_ANSWER, json: async () => ({ success: true, data: { instanceId: manifest.instanceId } }) };
    assert.match(await lanDoctor(lanOptions()), /^The LAN fallback is off \(LAN_ENABLED is not true in config\/compose\.env\)\. Turn it on with: bash scripts\/lan\.sh on auto$/);
    const envPath = join(state, 'config/compose.env');
    const base = readFileSync(envPath, 'utf8');
    writeFileSync(envPath, `${base.replace(/^LAN_ENABLED=.*$/m, 'LAN_ENABLED=true').replace(/^LAN_BIND_IP=.*$/m, 'LAN_BIND_IP=192.168.1.52').replace(/^LAN_CIDR=.*$/m, 'LAN_CIDR=192.168.1.0/24')}COMPOSE_PROFILES=lan\n`, { mode: 0o600 });
    assert.equal(await lanDoctor(lanOptions({ fetchImpl: async () => answer })), 'LAN address for the app: http://192.168.1.52:8080\nThe LAN fallback answers from this host as this installation.');
    // The instance id of the manifest is the one compared.
    await assert.rejects(lanDoctor(lanOptions()), /LAN fallback: http:\/\/192\.168\.1\.52:8080 answers, but not as this installation \(instanceId differs\)\./);
    await assert.rejects(lanDoctor(lanOptions({ interfaces: [], fetchImpl: async () => answer })), /LAN fallback: LAN_BIND_IP 192\.168\.1\.52 is not an address of this host/);
  } finally {
    if (saved === undefined) delete process.env.WAREHOUSE_STATE_DIR; else process.env.WAREHOUSE_STATE_DIR = saved;
    rmSync(scratch, { recursive: true, force: true });
  }
});

test('doctor: the LAN report is made after the health check and before the local return; --local shows its faults as warnings, the full run and --lan fail on them', () => {
  // That a service of the fallback never fails the health check itself is tested on the report that check makes (tests/watch.test.mjs, "health: the LAN
  // fallback ... is a warning"); the order of the steps is what this test pins.
  const source = readFileSync(new URL('../scripts/doctor.mjs', import.meta.url), 'utf8');
  const health = source.indexOf('const health = await runHealth(');
  const report = source.indexOf('await lanReport(env, manifest.instanceId)');
  const local = source.indexOf('if (local) return `Local operator services and gateway are healthy.${note}`;');
  const external = source.indexOf("if (lan.failures.length) throw new Error(`The public address works, but the LAN fallback does not:");
  assert.ok(health > 0 && report > health && local > report && external > local, 'the LAN report is made after the health check and before the local return; the full run throws after the public check');
  assert.match(source, /\.\.\.\(local \? lan\.failures : \[\]\)/);
  assert.equal(source.split('await lanReport(env, manifest.instanceId)').length, 2, 'one call site in doctor()');
  assert.match(source, /'--lan'/);
  // The preflight (start.sh, before anything starts) does not look at the fallback at all.
  assert.ok(source.indexOf("return 'Operator configuration, private paths and gateway port preflight passed.'") < report);
});

test('doctor: while maintenance mode is on the LAN listener is not probed (it answers 503 on purpose), and the full run says why it cannot pass, after the local return and before the public check', () => {
  const source = readFileSync(new URL('../scripts/doctor.mjs', import.meta.url), 'utf8');
  const health = source.indexOf('const health = await runHealth(');
  const marked = source.indexOf('const maintenance = maintenanceMarked(state);');
  const report = source.indexOf('await lanReport(env, manifest.instanceId)');
  const local = source.indexOf('if (local) return `Local operator services and gateway are healthy.${note}`;');
  const refusal = source.indexOf("if (maintenance) throw new Error('Maintenance mode is on (config/maintenance)");
  const external = source.indexOf('await fetch(`${origin}/functions/v1/get-public-config`');
  assert.ok(health > 0 && marked > health && report > marked && local > report && refusal > local && external > refusal, 'the steps are in this order');
  assert.match(source, /const lan = maintenance \? \{ failures: \[\], warnings: \[\], address: '' \} : await lanReport\(env, manifest\.instanceId\);/);
  assert.match(source, /the external check cannot pass\. Open it with: bash scripts\/maintenance\.sh off'\);/);
  assert.match(source, /import \{[^}]*\bmaintenanceMarked\b[^}]*\} from '\.\/watch\.mjs';/);
});

// get-public-config answers 503 without a valid public/app-compat.json: doctor names the file and the fix.
test('doctor names public/app-compat.json when it is missing or invalid, and passes with a valid one', () => {
  for (const [label, file] of [['missing', undefined], ['empty', ''], ['not json', 'nope'], ['no minimum', '{}'], ['bad version', '{"minimumClientVersion":"1.4"}']]) {
    const state = keyState();
    try {
      if (file !== undefined) writeFileSync(join(state, 'public/app-compat.json'), file);
      assert.throws(() => checkAppCompatFile(state), error => {
        assert.match(error.message, new RegExp(`${state}/public/app-compat\\.json is missing or invalid`), label);
        assert.match(error.message, /Run setup\.sh again/, label);
        return true;
      }, label);
    } finally { rmSync(state, { recursive: true, force: true }); }
  }
  const state = keyState();
  try {
    writeFileSync(join(state, 'public/app-compat.json'), '{"minimumClientVersion":"0.1.0"}');
    assert.doesNotThrow(() => checkAppCompatFile(state));
  } finally { rmSync(state, { recursive: true, force: true }); }
});

test('a missing app-compat.json after an interrupted upgrade still says so, and so does a maintenance marker', () => {
  const state = keyState();
  try {
    mkdirSync(join(state, 'config'));
    const sha = char => char.repeat(40);
    writeFileSync(join(state, 'config/upgrade-in-progress'), `format=1\nfrom_sha=${sha('a')}\nto_sha=${sha('b')}\nfrom_label=v0.1.0\nto_label=v0.2.0\nverified=yes\nbackup=/x/warehouse-20260101T000000Z\nstep=Setup\ncommand=v0.2.0\nmaintenance=on\n`);
    writeFileSync(join(state, 'config/maintenance'), 'upgrading\n');
    assert.throws(() => checkAppCompatFile(state), error => {
      assert.match(error.message, /is missing or invalid[^]*Run setup\.sh again/);
      assert.match(error.message, /An upgrade from v0\.1\.0 to v0\.2\.0 was interrupted at step "Setup"[^]*Continue: bash upgrade\.sh v0\.2\.0/);
      assert.match(error.message, /Maintenance mode is on \(config\/maintenance\)[^]*bash scripts\/maintenance\.sh off/);
      return true;
    });
    // Without either, the message is what it was.
    rmSync(join(state, 'config'), { recursive: true });
    assert.throws(() => checkAppCompatFile(state), error => { assert.doesNotMatch(error.message, /interrupted|Maintenance mode/); return true; });
  } finally { rmSync(state, { recursive: true, force: true }); }
});

test('the full doctor checks app-compat.json before the health check, so its own message is the one an operator reads', () => {
  const source = readFileSync(new URL('../scripts/doctor.mjs', import.meta.url), 'utf8');
  const check = source.indexOf('  checkAppCompatFile(state);');
  assert.ok(check > 0 && check < source.indexOf('await runHealth('), 'checkAppCompatFile(state) runs before runHealth');
});

// Right after a cold start the Docker daemon does not answer yet: setup waits for it (up to 60 s, 2 s apart) before refusing.
test('waitForDocker: a daemon that answers on the 3rd try passes, after two pauses and one line', () => {
  let calls = 0; const pauses = []; const said = [];
  assert.equal(waitForDocker(() => ({ ok: ++calls === 3, output: '' }), ms => pauses.push(ms), line => said.push(line)), true);
  assert.equal(calls, 3);
  assert.deepEqual(pauses, [2000, 2000]);
  assert.equal(said.length, 1);
});

test('waitForDocker: a daemon that never answers is given up after 60 s of pauses', () => {
  let calls = 0; let paused = 0;
  assert.equal(waitForDocker(() => { calls++; return { ok: false, output: '' }; }, ms => { paused += ms; }, () => {}), false);
  assert.equal(paused, DOCKER_WAIT_MS);
  assert.equal(calls, 31);
});

test('waitForDocker: a daemon that answers at once is neither waited for nor announced', () => {
  const said = [];
  assert.equal(waitForDocker(() => ({ ok: true, output: '' }), () => assert.fail('paused'), line => said.push(line)), true);
  assert.deepEqual(said, []);
});

test('doctor refuses at once, without waiting, when the docker CLI is missing', () => {
  const started = Date.now();
  const run = doctorWithCompose(WAIT, { docker: 'exit 127' });
  assert.equal(run.status, 1);
  assert.match(run.stderr, /Missing or unavailable prerequisite: docker Compose\./);
  assert.doesNotMatch(run.stderr, /Waiting for the Docker daemon/);
  assert.ok(Date.now() - started < 20000, 'it waited');
});
