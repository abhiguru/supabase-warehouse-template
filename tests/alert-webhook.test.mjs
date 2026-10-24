// The Slack webhook at install time (scripts/alert-webhook.mjs, setup.sh --operator): the prompt, the refusal
// without a terminal, `off`, an invalid URL, the 0600 file, the URL never in output, and the test message posted
// to a local fake receiver. Nothing here contacts Slack.
import test from 'node:test';
import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, statSync, writeFileSync } from 'node:fs';
import { spawn, spawnSync } from 'node:child_process';
import { PassThrough } from 'node:stream';
import { configure } from '../scripts/configure.mjs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { decideWebhookSource, LEGACY_WEBHOOK_FILE, MAX_ATTEMPTS, obtainWebhook, OFF_WARNING, placeWebhook, postSlackMessage, PROMPT, readAlertWebhook, readLine, REFUSAL, storedWebhook, testMessage, WEBHOOK_FILE, writeWebhookFile } from '../scripts/alert-webhook.mjs';

const script = new URL('../scripts/alert-webhook.mjs', import.meta.url).pathname;
const read = path => readFileSync(new URL(`../${path}`, import.meta.url), 'utf8');
const URL_A = 'https://hooks.slack.com/services/' + 'T0000000/B0000000/fictionalfictionalfictional';
const SECRET = /fictionalfictional|T0000000\/B0000000/;

function scratch() {
  const dir = mkdtempSync(join(tmpdir(), 'warehouse-alert-webhook-'));
  return { dir, cleanup: () => rmSync(dir, { recursive: true, force: true }) };
}
function stateWith(dir, url) {
  const state = join(dir, 'state');
  mkdirSync(join(state, 'config'), { recursive: true });
  if (url) writeFileSync(join(state, WEBHOOK_FILE), `${url}\n`, { mode: 0o600 });
  return state;
}
const typed = (...answers) => { const prompts = []; return { prompts, read: async text => { prompts.push(text); return answers.shift() ?? ''; } }; };

test('the prompt names the company and asks for the Slack URL', () => {
  assert.equal(PROMPT('Fictional Cold Storage'), 'Slack incoming-webhook URL for Fictional Cold Storage alerts (create one in Slack: Apps → Incoming Webhooks):');
});

const answers = (...list) => async () => list.shift() ?? null;
const accepted = status => async () => status;

test('a valid URL is tested before it is returned; a wrong shape is asked again, three tries in all', async () => {
  const out = [];
  const posted = [];
  const first = typed(`  ${URL_A}  `);
  assert.equal(await obtainWebhook({ company: 'Acme', read: first.read, ask: answers(''), write: text => out.push(text), post: async (url, text) => { posted.push([url, text]); return 200; } }), URL_A);
  assert.deepEqual(first.prompts, [PROMPT('Acme')]);
  assert.deepEqual(posted, [[URL_A, testMessage('Acme')]]);
  assert.deepEqual(out, ['Slack answered HTTP 200: check the channel for the test message.\n']);
  const second = typed('https://example.test/hook', 'http://hooks.slack.com/services/T0000000/B0000000/abc', URL_A);
  assert.equal(await obtainWebhook({ company: 'Acme', read: second.read, ask: answers('y'), write: text => out.push(text), post: accepted(200) }), URL_A);
  assert.equal(second.prompts.length, 3);
  const third = typed('nope', 'still nope', 'https://hooks.slack.com/services/T0000000');
  await assert.rejects(obtainWebhook({ company: 'Acme', read: third.read, ask: answers(), write: text => out.push(text), post: accepted(200) }), error => /after 3 tries; nothing was stored/.test(error.message));
  assert.equal(third.prompts.length, MAX_ATTEMPTS);
  assert.doesNotMatch(out.join(''), SECRET, 'messages never repeat what was typed');
});

test('Slack refusing the test message does not store the URL: ask again, or keep it only on an explicit yes', async () => {
  const out = [];
  const post = async url => (url.endsWith('/goodgoodgood') ? 200 : url.endsWith('/unreachable') ? Promise.reject(new Error('could not reach Slack (ENOTFOUND)')) : 404);
  const good = 'https://hooks.slack.com/services/T0000000/B0000000/goodgoodgood';
  // 404, then a corrected URL.
  const retry = typed(URL_A, good);
  assert.equal(await obtainWebhook({ company: 'Acme', read: retry.read, ask: answers('', 'n', ''), write: text => out.push(text), post }), good);
  assert.match(out.join(''), /Slack answered HTTP 404: the URL was not accepted/);
  assert.equal(retry.prompts.length, 2);
  // 404 and "store anyway? y" keeps it.
  out.length = 0;
  assert.equal(await obtainWebhook({ company: 'Acme', read: typed(URL_A).read, ask: answers('', 'y'), write: text => out.push(text), post }), URL_A);
  // Unreachable, store anyway answered with end of input: not kept; three failures end it with nothing stored.
  out.length = 0;
  const unreachable = 'https://hooks.slack.com/services/T0000000/B0000000/unreachable';
  await assert.rejects(obtainWebhook({ company: 'Acme', read: typed(unreachable, unreachable, unreachable).read, ask: answers('', null, '', null, '', null), write: text => out.push(text), post }), /nothing was stored/);
  assert.match(out.join(''), /The Slack test message failed: could not reach Slack/);
  assert.doesNotMatch(out.join(''), SECRET);
  // Declining the test (n, or end of input) keeps the URL without posting.
  let posts = 0;
  for (const answer of ['n', 'no', null]) {
    assert.equal(await obtainWebhook({ company: 'Acme', read: typed(URL_A).read, ask: answers(answer), write: () => {}, post: async () => { posts++; return 200; } }), URL_A);
  }
  assert.equal(posts, 0);
});

test('end of input at a Y/n question is an answer, not a hang', async () => {
  const input = new PassThrough();
  const output = new PassThrough();
  const pending = readLine('Send a test message to Slack now? [Y/n]', { input, output });
  input.end();
  assert.equal(await pending, null);
  const typedLine = new PassThrough();
  const answer = readLine('?', { input: typedLine, output: new PassThrough() });
  typedLine.write('y\n');
  assert.equal(await answer, 'y');
});

test('the URL file is mode 0600 and the install accepts it as --alert-webhook-file', () => {
  const s = scratch();
  try {
    const file = join(s.dir, 'webhook.tmp');
    writeFileSync(file, '', { mode: 0o644 }); // setup.sh makes the file with mktemp; a looser mode must be tightened
    writeWebhookFile(file, URL_A);
    assert.equal(statSync(file).mode & 0o777, 0o600);
    assert.equal(readFileSync(file, 'utf8'), `${URL_A}\n`);
    assert.equal(readAlertWebhook(file, '/nowhere/checkout'), URL_A);
  } finally { s.cleanup(); }
});

test('where the URL comes from: given file, off, stored, prompt on a terminal, refusal without one', () => {
  assert.equal(decideWebhookSource({ given: '/w', stored: false, isTTY: false }), 'file');
  assert.equal(decideWebhookSource({ given: '/w', stored: true, isTTY: true }), 'file');
  assert.equal(decideWebhookSource({ given: 'off', stored: true, isTTY: false }), 'off');
  assert.equal(decideWebhookSource({ given: '', stored: true, isTTY: false }), 'stored');
  assert.equal(decideWebhookSource({ given: '', stored: false, isTTY: true }), 'prompt');
  assert.equal(decideWebhookSource({ given: '', stored: false, isTTY: false }), 'refuse');
  assert.equal(decideWebhookSource({ given: 'ask', stored: true, isTTY: true }), 'prompt', 'ask replaces a stored URL');
  assert.equal(decideWebhookSource({ given: 'ask', stored: true, isTTY: false }), 'refuse');
});

test('gate without a terminal and without the option refuses with the exact message, and writes nothing', () => {
  const s = scratch();
  try {
    const out = join(s.dir, 'out');
    writeFileSync(out, '', { mode: 0o600 });
    const run = spawnSync(process.execPath, [script, 'gate', '--state-dir', stateWith(s.dir), '--company', 'Acme', '--given', '', '--out', out], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] });
    assert.equal(run.status, 1);
    assert.equal(run.stderr.trim(), '--alert-webhook-file PATH is required (a file holding the facility\'s Slack webhook URL), or --alert-webhook-file off for a non-production install');
    assert.equal(run.stderr.trim(), REFUSAL);
    assert.equal(readFileSync(out, 'utf8'), '');
  } finally { s.cleanup(); }
});

test('gate with `off` passes and warns that alerts stay on this host; with a stored URL it asks nothing and prints nothing', () => {
  const s = scratch();
  try {
    const out = join(s.dir, 'out');
    writeFileSync(out, '', { mode: 0o600 });
    const off = spawnSync(process.execPath, [script, 'gate', '--state-dir', stateWith(s.dir), '--company', 'Acme', '--given', 'off', '--out', out], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] });
    assert.equal(off.status, 0, off.stderr);
    assert.match(off.stderr, /alerts stay on this host only/);
    assert.equal(off.stderr.trim(), OFF_WARNING);
    assert.match(OFF_WARNING, /leaving out --alert-webhook-file off/);
    assert.equal(readFileSync(out, 'utf8'), '');
    const kept = spawnSync(process.execPath, [script, 'gate', '--state-dir', stateWith(mkdtempSync(join(s.dir, 'k-')), URL_A), '--company', 'Acme', '--given', '', '--out', out], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] });
    assert.equal(kept.status, 0, kept.stderr);
    assert.equal(kept.stderr + kept.stdout, '');
    const file = spawnSync(process.execPath, [script, 'gate', '--state-dir', stateWith(mkdtempSync(join(s.dir, 'f-'))), '--company', 'Acme', '--given', '/some/file', '--out', out], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] });
    assert.equal(file.status, 0, file.stderr);
    assert.equal(file.stderr + file.stdout, '');
  } finally { s.cleanup(); }
});

// A real pseudo-terminal: python3's pty module runs the script with a terminal as stdin and types into it, one line
// at a time, after the text it waits for has appeared. The fake Slack runs in this process, so the child is async.
// "Usable" is proved, not assumed: the probe forks a child on a pty, puts the terminal in raw mode there (as the gate does) and
// checks that a typed word is not echoed back. A runner with python3 but no working pty (or no raw mode) skips these tests.
const PROBE = `
import os, pty, sys, time, select
pid, fd = pty.fork()
if pid == 0:
    os.execv(sys.argv[1], [sys.argv[1], '-e', "process.stdin.setRawMode(true); process.stdin.resume(); console.log('READY'); setTimeout(() => process.exit(0), 3000)"])
seen = b''
end = time.time() + 10
while time.time() < end and b'READY' not in seen:
    r, _, _ = select.select([fd], [], [], 0.1)
    if r:
        try:
            seen += os.read(fd, 4096)
        except OSError:
            sys.exit(3)
if b'READY' not in seen:
    sys.exit(4)
os.write(fd, b'probeword')
seen = b''
end = time.time() + 0.6
while time.time() < end:
    r, _, _ = select.select([fd], [], [], 0.1)
    if r:
        try:
            seen += os.read(fd, 4096)
        except OSError:
            break
sys.exit(5 if b'probeword' in seen else 0)
`;
const python = spawnSync('python3', ['-I', '-c', PROBE, process.execPath], { stdio: 'ignore', timeout: 20000 }).status === 0;
// REQUIRE_PTY=1 (a runner known to have a pty) turns the silent skip into a failure.
test('a usable pty is there when REQUIRE_PTY=1', { skip: process.env.REQUIRE_PTY !== '1' && 'REQUIRE_PTY is not 1' }, () => {
  assert.ok(python, 'REQUIRE_PTY=1, but python3 has no usable pty with raw mode: the terminal tests below would be skipped');
});
const DRIVER = `
import os, pty, sys, time, select, json
node, script, state, out = sys.argv[1:5]
steps = json.loads(sys.argv[5])
pid, fd = pty.fork()
if pid == 0:
    os.execv(node, [node, script, 'gate', '--state-dir', state, '--company', 'Fictional Cold Storage', '--given', sys.argv[6], '--out', out])
captured = b''
window = b''
def pump_until(text, seconds=20):
    global captured, window
    end = time.time() + seconds
    while time.time() < end and text.encode() not in window:
        r, _, _ = select.select([fd], [], [], 0.1)
        if r:
            try:
                data = os.read(fd, 4096)
            except OSError:
                return
            if not data:
                return
            captured += data
            window += data
for wait_for, send in steps:
    pump_until(wait_for)
    window = b''
    os.write(fd, send.encode() + b'\\r')
status = 0
end = time.time() + 10
while time.time() < end:
    try:
        done, st = os.waitpid(pid, os.WNOHANG)
    except ChildProcessError:
        break
    if done:
        status = st
        break
    r, _, _ = select.select([fd], [], [], 0.1)
    if r:
        try:
            captured += os.read(fd, 4096)
        except OSError:
            pass
try:
    while True:
        r, _, _ = select.select([fd], [], [], 0.1)
        if not r:
            break
        captured += os.read(fd, 4096)
except OSError:
    pass
sys.stdout.write(captured.decode('utf8', 'replace'))
sys.exit(os.waitstatus_to_exitcode(status))
`;

function drive(args, steps, given, env = {}) {
  return new Promise(resolve => {
    const child = spawn('python3', ['-I', '-c', DRIVER, process.execPath, script, args.state, args.out, JSON.stringify(steps), given], { env: { ...process.env, ...env } });
    let stdout = '';
    let stderr = '';
    child.stdout.on('data', chunk => { stdout += chunk; });
    child.stderr.on('data', chunk => { stderr += chunk; });
    child.on('close', status => resolve({ status, stdout, stderr }));
  });
}

async function fakeSlack(statusFor = () => 200) {
  const received = [];
  const server = createServer((req, res) => {
    let body = '';
    req.on('data', chunk => { body += chunk; });
    req.on('end', () => { received.push({ method: req.method, path: req.url, type: req.headers['content-type'], body }); res.statusCode = statusFor(req.url); res.end('ok'); });
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  return { received, origin: `http://127.0.0.1:${server.address().port}`, close: () => new Promise(resolve => server.close(resolve)) };
}

test('on a terminal: the URL is not echoed, a wrong one is refused, the test message is posted before anything is stored, and the file is 0600', { skip: !python && 'no usable pty (python3 pty with raw mode)' }, async () => {
  const s = scratch();
  const slack = await fakeSlack();
  try {
    const out = join(s.dir, 'out');
    writeFileSync(out, '', { mode: 0o600 });
    const run = await drive({ state: stateWith(s.dir), out }, [
      ['alerts (create one in Slack: Apps', 'https://example.test/not-slack'],
      ['alerts (create one in Slack: Apps', URL_A], // the window is reset after each send: this waits for the second prompt
      ['Send a test message to Slack now? [Y/n]', ''],
    ], '', { WAREHOUSE_SLACK_POST_ORIGIN: slack.origin });
    assert.equal(run.status, 0, run.stdout + run.stderr);
    assert.ok(run.stdout.includes(PROMPT('Fictional Cold Storage')), run.stdout);
    assert.match(run.stdout, /That is not a Slack incoming-webhook URL/);
    assert.match(run.stdout, /Slack answered HTTP 200/);
    assert.doesNotMatch(run.stdout, SECRET, 'the typed URL is not echoed');
    assert.doesNotMatch(run.stdout, /example\.test/, 'the wrong URL is not echoed either');
    assert.equal(readFileSync(out, 'utf8'), `${URL_A}\n`);
    assert.equal(statSync(out).mode & 0o777, 0o600);
    assert.equal(slack.received.length, 1);
    assert.equal(slack.received[0].path, '/services/T0000000/B0000000/fictionalfictionalfictional');
    assert.match(JSON.parse(slack.received[0].body).text, /Fictional Cold Storage/);
  } finally { await slack.close(); s.cleanup(); }
});

test('on a terminal: a URL typed ahead, right after the refusal text and before the next prompt, is not echoed', { skip: !python && 'no usable pty (python3 pty with raw mode)' }, async () => {
  const s = scratch();
  const slack = await fakeSlack();
  try {
    const out = join(s.dir, 'out');
    writeFileSync(out, '', { mode: 0o600 });
    const run = await drive({ state: stateWith(s.dir), out }, [
      ['alerts (create one in Slack: Apps', 'https://example.test/not-slack'],
      ['try again', URL_A], // no wait for the second prompt: the race
      ['Send a test message to Slack now? [Y/n]', ''],
    ], '', { WAREHOUSE_SLACK_POST_ORIGIN: slack.origin });
    assert.equal(run.status, 0, run.stdout + run.stderr);
    assert.doesNotMatch(run.stdout, SECRET, 'the typed-ahead URL is not echoed');
    assert.doesNotMatch(run.stdout, /example\.test/);
    assert.equal(readFileSync(out, 'utf8'), `${URL_A}\n`);
  } finally { await slack.close(); s.cleanup(); }
});

test('on a terminal: a refused test message stores nothing until the operator says to store it anyway; `ask` replaces a stored URL', { skip: !python && 'no usable pty (python3 pty with raw mode)' }, async () => {
  const s = scratch();
  const slack = await fakeSlack(url => (url.endsWith('/fictionalfictionalfictional') ? 404 : 200));
  try {
    const out = join(s.dir, 'out');
    writeFileSync(out, '', { mode: 0o600 });
    const refused = await drive({ state: stateWith(s.dir), out }, [
      ['alerts (create one in Slack: Apps', URL_A],
      ['Send a test message to Slack now? [Y/n]', 'y'],
      ['Store this URL anyway? [y/N]', 'n'],
      ['Type the URL again', 'https://hooks.slack.com/services/T0000000/B0000000/replacementreplacement'],
      ['Send a test message to Slack now? [Y/n]', ''],
    ], '', { WAREHOUSE_SLACK_POST_ORIGIN: slack.origin });
    assert.equal(refused.status, 0, refused.stdout + refused.stderr);
    assert.match(refused.stdout, /Slack answered HTTP 404: the URL was not accepted/);
    assert.equal(readFileSync(out, 'utf8'), 'https://hooks.slack.com/services/T0000000/B0000000/replacementreplacement\n', 'the refused URL was not kept');
    // Store anyway.
    writeFileSync(out, '', { mode: 0o600 });
    const anyway = await drive({ state: stateWith(mkdtempSync(join(s.dir, 'a-'))), out }, [
      ['alerts (create one in Slack: Apps', URL_A],
      ['Send a test message to Slack now? [Y/n]', 'y'],
      ['Store this URL anyway? [y/N]', 'y'],
    ], '', { WAREHOUSE_SLACK_POST_ORIGIN: slack.origin });
    assert.equal(anyway.status, 0, anyway.stdout + anyway.stderr);
    assert.equal(readFileSync(out, 'utf8'), `${URL_A}\n`);
    // `ask` prompts although a URL is stored; without it nothing is asked.
    writeFileSync(out, '', { mode: 0o600 });
    const stored = stateWith(mkdtempSync(join(s.dir, 's-')), URL_A);
    const quiet = await drive({ state: stored, out }, [], '', { WAREHOUSE_SLACK_POST_ORIGIN: slack.origin });
    assert.equal(quiet.status, 0);
    assert.equal(readFileSync(out, 'utf8'), '', 'a stored URL is not asked for again');
    const ask = await drive({ state: stored, out }, [
      ['alerts (create one in Slack: Apps', 'https://hooks.slack.com/services/T0000000/B0000000/replacementreplacement'],
      ['Send a test message to Slack now? [Y/n]', 'n'],
    ], 'ask', { WAREHOUSE_SLACK_POST_ORIGIN: slack.origin });
    assert.equal(ask.status, 0, ask.stdout + ask.stderr);
    assert.equal(readFileSync(out, 'utf8'), 'https://hooks.slack.com/services/T0000000/B0000000/replacementreplacement\n');
  } finally { await slack.close(); s.cleanup(); }
});

test('gate, then configure.mjs, then the receiver: the answered URL ends up in the state at 0600 and the test message reached the fake Slack', { skip: !python && 'no usable pty (python3 pty with raw mode)' }, async () => {
  const s = scratch();
  const slack = await fakeSlack();
  try {
    const root = join(s.dir, 'checkout');
    mkdirSync(root);
    writeFileSync(join(root, '.env.example'), read('.env.example'));
    const providerEnv = join(s.dir, 'provider.env');
    writeFileSync(providerEnv, 'SMS_PROVIDER=msg91\nMSG91_AUTH_KEY=isolated-no-delivery-key\nMSG91_TEMPLATE_ID=000000000000000000000001\nMSG91_PE_ID=0000000000000000001\nMSG91_SENDER_ID=CITEST\n', { mode: 0o600 });
    const state = join(s.dir, 'install');
    const tmp = join(s.dir, 'warehouse-slack-webhook.tmp');
    writeFileSync(tmp, '', { mode: 0o600 });
    const run = await drive({ state, out: tmp }, [
      ['alerts (create one in Slack: Apps', URL_A],
      ['Send a test message to Slack now? [Y/n]', 'y'],
    ], '', { WAREHOUSE_SLACK_POST_ORIGIN: slack.origin });
    assert.equal(run.status, 0, run.stdout + run.stderr);
    assert.equal(slack.received.length, 1, 'the test message went out before the state existed');
    assert.equal(existsSync(state), false, 'nothing is stored by the prompt itself');
    const result = configure(root, { stateDir: state, apiUrl: 'https://gate.example.test', company: 'Fictional Cold Storage', providerEnv, alertWebhookFile: tmp });
    assert.equal(result.webhook, true);
    const stored = join(state, 'config/slack-webhook-url');
    assert.equal(readFileSync(stored, 'utf8'), `${URL_A}\n`);
    assert.equal(statSync(stored).mode & 0o777, 0o600);
    assert.equal(storedWebhook(state), URL_A);
    assert.equal(existsSync(join(state, 'config/monitoring')), false, 'no Prometheus or Alertmanager files are rendered any more');
  } finally { await slack.close(); s.cleanup(); }
});

test('the test message is posted to a receiver and names the facility; an unreachable receiver is reported without the URL', async () => {
  const slack = await fakeSlack();
  try {
    assert.equal(await postSlackMessage(URL_A, testMessage('Fictional Cold Storage'), { origin: slack.origin }), 200);
    assert.deepEqual({ method: slack.received[0].method, path: slack.received[0].path, type: slack.received[0].type }, { method: 'POST', path: '/services/T0000000/B0000000/fictionalfictionalfictional', type: 'application/json' });
    assert.equal(JSON.parse(slack.received[0].body).text, testMessage('Fictional Cold Storage'));
    assert.match(testMessage('Fictional Cold Storage'), /Fictional Cold Storage/);
    await slack.close();
    await assert.rejects(postSlackMessage(URL_A, 'x', { origin: slack.origin }), error => /^could not reach Slack \(/.test(error.message) && !SECRET.test(error.message));
  } finally { await slack.close().catch(() => {}); }
});

test('setup.sh asks after the host checks and the lock, hands the URL over through a temporary file, never an argument, and installs no monitoring services', () => {
  const setup = read('setup.sh');
  const gate = setup.indexOf('alert-webhook.mjs" gate');
  assert.ok(gate > setup.indexOf('doctor.mjs" --host-preflight'), 'the question comes after the host checks');
  assert.ok(gate > setup.indexOf('LOCKED=1'), 'and after the operator lock of an existing state is held');
  assert.ok(gate < setup.indexOf('scripts/configure.mjs'), 'and before configure.mjs');
  assert.match(setup, /mktemp "\$\{TMPDIR:-\/tmp\}\/warehouse-slack-webhook\.XXXXXX"/);
  assert.match(setup, /\(umask 077; mktemp/);
  assert.match(setup, /trap 'rm -f "\$WEBHOOK_TMP" "\$LETTERHEAD_TMP"' EXIT/);
  assert.match(setup, /CONFIG_ARGS\+=\(--alert-webhook-file "\$WEBHOOK_TMP"\)/);
  assert.match(setup, /\[\[ "\$2" != ask \]\]/, '`ask` is for the gate; configure.mjs never sees it');
  assert.doesNotMatch(setup, /curl|wget/, 'no URL on a shell command line');
  assert.doesNotMatch(setup, /start-monitoring/);
  assert.doesNotMatch(read('start.sh'), /start-monitoring/);
  // The timer needs sudo, which setup never runs: it prints the exact command (and start.sh a hint when the timer is missing).
  assert.match(setup, /watch-timer\.sh" hint/);
  assert.match(setup, /WAREHOUSE_STATE_DIR="\$STATE" bash "\$ROOT\/scripts\/watch-timer\.sh" hint/);
  assert.doesNotMatch(setup, /^\s*sudo /m);
  assert.match(read('start.sh'), /watch-timer\.sh" hint/);
  assert.match(read('.github/workflows/ci.yml'), /--admin-name 'Core Demo Administrator' \\\n\s+--alert-webhook-file off \\\n\s+--letterhead-file off\n/, 'CI installs with off');
});

// An installation made before the Slack checker kept the URL for Alertmanager; a rerun moves it (docs/MONITORING.md).
function legacyState(dir, url = URL_A) {
  const state = join(dir, 'legacy-state');
  mkdirSync(join(state, 'config/monitoring/alertmanager'), { recursive: true });
  writeFileSync(join(state, LEGACY_WEBHOOK_FILE), `${url}\n`, { mode: 0o600 });
  writeFileSync(join(state, 'config/monitoring/prometheus.yml'), 'global: {}\n');
  writeFileSync(join(state, 'config/monitoring/alertmanager/alertmanager.yml'), 'route: {}\n');
  return state;
}

test('a rerun moves a URL stored for Alertmanager to config/slack-webhook-url at 0600 and removes the rendered monitoring files', () => {
  const s = scratch();
  try {
    const state = legacyState(s.dir);
    assert.equal(storedWebhook(state), URL_A, 'the old path is still read until the rerun');
    mkdirSync(join(state, 'metrics'), { recursive: true }); writeFileSync(join(state, 'metrics/warehouse_backup.prom'), '# old\n');
    mkdirSync(join(state, 'data/alertmanager'), { recursive: true });
    assert.deepEqual(placeWebhook(state, undefined), { moved: true, cleaned: true });
    assert.equal(existsSync(join(state, 'metrics')), false); assert.equal(existsSync(join(state, 'data/alertmanager')), false);
    assert.equal(readFileSync(join(state, WEBHOOK_FILE), 'utf8'), `${URL_A}\n`);
    assert.equal(statSync(join(state, WEBHOOK_FILE)).mode & 0o777, 0o600);
    assert.equal(existsSync(join(state, 'config/monitoring')), false);
    assert.equal(storedWebhook(state), URL_A);
    assert.deepEqual(placeWebhook(state, undefined), { moved: false, cleaned: false }, 'a second rerun changes nothing');
  } finally { s.cleanup(); }
});

test('a new URL, or off, replaces or removes the stored one at both paths', () => {
  const s = scratch();
  try {
    const other = 'https://hooks.slack.com/services/T0000000/B0000000/replacementreplacement';
    const state = legacyState(s.dir);
    placeWebhook(state, other);
    assert.equal(storedWebhook(state), other);
    assert.equal(existsSync(join(state, LEGACY_WEBHOOK_FILE)), false);
    const old = legacyState(mkdtempSync(join(s.dir, 'o-')));
    placeWebhook(old, null);
    assert.equal(storedWebhook(old), null);
    assert.equal(existsSync(join(old, 'config/monitoring')), false);
    assert.deepEqual(placeWebhook(old, null), { moved: false, cleaned: false });
    // Off also removes an address that is only at the old path (no new file yet): it can never keep posting.
    const legacyOnly = legacyState(mkdtempSync(join(s.dir, 'l-')));
    assert.deepEqual(placeWebhook(legacyOnly, null), { moved: true, cleaned: true });
    assert.equal(storedWebhook(legacyOnly), null);
    assert.equal(existsSync(join(legacyOnly, LEGACY_WEBHOOK_FILE)), false);
  } finally { s.cleanup(); }
});

test('configure.mjs on an existing state with a URL at the old path moves it and says so', () => {
  const s = scratch();
  try {
    const root = join(s.dir, 'checkout');
    mkdirSync(root);
    writeFileSync(join(root, '.env.example'), read('.env.example'));
    const providerEnv = join(s.dir, 'provider.env');
    writeFileSync(providerEnv, 'SMS_PROVIDER=msg91\nMSG91_AUTH_KEY=isolated-no-delivery-key\nMSG91_TEMPLATE_ID=000000000000000000000001\nMSG91_PE_ID=0000000000000000001\nMSG91_SENDER_ID=CITEST\n', { mode: 0o600 });
    const state = join(s.dir, 'install');
    configure(root, { stateDir: state, apiUrl: 'https://move.example.test', company: 'Fictional Cold Storage', providerEnv });
    assert.equal(storedWebhook(state), null);
    mkdirSync(join(state, 'config/monitoring/alertmanager'), { recursive: true });
    writeFileSync(join(state, LEGACY_WEBHOOK_FILE), `${URL_A}\n`, { mode: 0o600 });
    const rerun = configure(root, { stateDir: state });
    assert.equal(rerun.monitoringUpdated, true);
    assert.equal(rerun.monitoringCleaned, true);
    assert.equal(rerun.webhook, undefined, 'the rerun was not given a URL');
    assert.equal(readFileSync(join(state, WEBHOOK_FILE), 'utf8'), `${URL_A}\n`);
    assert.equal(existsSync(join(state, 'config/monitoring')), false);
    const off = configure(root, { stateDir: state, alertWebhookFile: 'off' });
    assert.equal(off.webhook, null);
    assert.equal(storedWebhook(state), null);
  } finally { s.cleanup(); }
});
