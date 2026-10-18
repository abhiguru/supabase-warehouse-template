// The Slack webhook at install time (scripts/alert-webhook.mjs, setup.sh --operator): the prompt, the refusal
// without a terminal, `off`, an invalid URL, the 0600 file, the URL never in output, and the test message posted
// to a local fake receiver. Nothing here contacts Slack.
import test from 'node:test';
import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, statSync, writeFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { askWebhook, decideWebhookSource, MAX_ATTEMPTS, offerTest, OFF_WARNING, postSlackMessage, PROMPT, REFUSAL, storedWebhook, testMessage, writeWebhookFile } from '../scripts/alert-webhook.mjs';
import { readAlertWebhook } from '../scripts/monitoring-config.mjs';

const script = new URL('../scripts/alert-webhook.mjs', import.meta.url).pathname;
const read = path => readFileSync(new URL(`../${path}`, import.meta.url), 'utf8');
const URL_A = 'https://hooks.slack.com/services/T0000000/B0000000/fictionalfictionalfictional';
const SECRET = /fictionalfictional|T0000000\/B0000000/;

function scratch() {
  const dir = mkdtempSync(join(tmpdir(), 'warehouse-alert-webhook-'));
  return { dir, cleanup: () => rmSync(dir, { recursive: true, force: true }) };
}
function stateWith(dir, url) {
  const state = join(dir, 'state');
  mkdirSync(join(state, 'config/monitoring/alertmanager'), { recursive: true });
  if (url) writeFileSync(join(state, 'config/monitoring/alertmanager/webhook-url'), `${url}\n`, { mode: 0o600 });
  return state;
}
const typed = (...answers) => { const prompts = []; return { prompts, read: async text => { prompts.push(text); return answers.shift() ?? ''; } }; };

test('the prompt names the company and asks for the Slack URL', () => {
  assert.equal(PROMPT('Fictional Cold Storage'), 'Slack incoming-webhook URL for Fictional Cold Storage alerts (create one in Slack: Apps → Incoming Webhooks):');
});

test('a valid URL is taken at once; a wrong one is asked again, three tries in all', async () => {
  const out = [];
  const first = typed(`  ${URL_A}  `);
  assert.equal(await askWebhook({ company: 'Acme', read: first.read, write: text => out.push(text) }), URL_A);
  assert.deepEqual(first.prompts, [PROMPT('Acme')]);
  const second = typed('https://example.test/hook', 'http://hooks.slack.com/services/T0000000/B0000000/abc', URL_A);
  assert.equal(await askWebhook({ company: 'Acme', read: second.read, write: text => out.push(text) }), URL_A);
  assert.equal(second.prompts.length, 3);
  const third = typed('nope', 'still nope', 'https://hooks.slack.com/services/T0000000');
  await assert.rejects(askWebhook({ company: 'Acme', read: third.read, write: text => out.push(text) }), error => /after 3 tries/.test(error.message));
  assert.equal(third.prompts.length, MAX_ATTEMPTS);
  assert.doesNotMatch(out.join(''), SECRET, 'messages never repeat what was typed');
  assert.equal(out.filter(text => /not a Slack incoming-webhook URL/.test(text)).length, 2 + 3);
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
    assert.equal(readFileSync(out, 'utf8'), '');
    const kept = spawnSync(process.execPath, [script, 'gate', '--state-dir', stateWith(mkdtempSync(join(s.dir, 'k-')), URL_A), '--company', 'Acme', '--given', '', '--out', out], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] });
    assert.equal(kept.status, 0, kept.stderr);
    assert.equal(kept.stderr + kept.stdout, '');
    const file = spawnSync(process.execPath, [script, 'gate', '--state-dir', stateWith(mkdtempSync(join(s.dir, 'f-'))), '--company', 'Acme', '--given', '/some/file', '--out', out], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] });
    assert.equal(file.status, 0, file.stderr);
    assert.equal(file.stderr + file.stdout, '');
  } finally { s.cleanup(); }
});

// A real pseudo-terminal: python3's pty module runs the script with a terminal as stdin and types into it.
const python = spawnSync('python3', ['-c', 'import pty'], { stdio: 'ignore' }).status === 0;
test('on a terminal the prompt does not echo the URL, refuses a wrong one, and leaves a 0600 file', { skip: !python && 'python3 pty is not available' }, () => {
  const s = scratch();
  try {
    const out = join(s.dir, 'out');
    writeFileSync(out, '', { mode: 0o600 });
    const driver = `
import os, pty, sys, time, select
node, script, state, out = sys.argv[1:5]
good = ${JSON.stringify(URL_A)}
pid, fd = pty.fork()
if pid == 0:
    os.execv(node, [node, script, 'gate', '--state-dir', state, '--company', 'Fictional Cold Storage', '--given', '', '--out', out])
captured = b''
def pump(seconds):
    global captured
    end = time.time() + seconds
    while time.time() < end:
        r, _, _ = select.select([fd], [], [], 0.1)
        if r:
            try:
                data = os.read(fd, 4096)
            except OSError:
                return
            if not data:
                return
            captured += data
pump(1.5)
os.write(fd, b'https://example.test/not-slack\\r')
pump(1.0)
os.write(fd, good.encode() + b'\\r')
pump(1.5)
_, status = os.waitpid(pid, 0)
sys.stdout.write(captured.decode('utf8', 'replace'))
sys.exit(os.waitstatus_to_exitcode(status))
`;
    const run = spawnSync('python3', ['-I', '-c', driver, process.execPath, script, stateWith(s.dir), out], { encoding: 'utf8', timeout: 30000 });
    assert.equal(run.status, 0, run.stdout + run.stderr);
    assert.ok(run.stdout.includes(PROMPT('Fictional Cold Storage')), run.stdout);
    assert.match(run.stdout, /That is not a Slack incoming-webhook URL/);
    assert.doesNotMatch(run.stdout, SECRET, 'the typed URL is not echoed');
    assert.doesNotMatch(run.stdout, /example\.test/, 'the wrong URL is not echoed either');
    assert.equal(readFileSync(out, 'utf8'), `${URL_A}\n`);
    assert.equal(statSync(out).mode & 0o777, 0o600);
  } finally { s.cleanup(); }
});

test('the test message is posted to a receiver, names the facility, and its status is reported without the URL', async () => {
  const s = scratch();
  const received = [];
  const server = createServer((req, res) => {
    let body = '';
    req.on('data', chunk => { body += chunk; });
    req.on('end', () => { received.push({ method: req.method, path: req.url, type: req.headers['content-type'], body }); res.statusCode = req.url.endsWith('/refused') ? 404 : 200; res.end('ok'); });
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  const origin = `http://127.0.0.1:${server.address().port}`;
  try {
    const state = stateWith(s.dir, URL_A);
    assert.equal(storedWebhook(state), URL_A);
    const out = [];
    const post = (url, text) => postSlackMessage(url, text, { origin });
    assert.equal(await offerTest({ state, company: 'Fictional Cold Storage', ask: async () => '', write: text => out.push(text), post }), true, 'Enter means yes');
    assert.equal(received.length, 1);
    assert.deepEqual({ method: received[0].method, path: received[0].path, type: received[0].type }, { method: 'POST', path: '/services/T0000000/B0000000/fictionalfictionalfictional', type: 'application/json' });
    assert.equal(JSON.parse(received[0].body).text, testMessage('Fictional Cold Storage'));
    assert.match(JSON.parse(received[0].body).text, /Fictional Cold Storage/);
    assert.deepEqual(out, ['Slack answered HTTP 200: check the channel for the test message.\n']);
    // "n" posts nothing.
    out.length = 0;
    assert.equal(await offerTest({ state, company: 'x', ask: async () => 'n', write: text => out.push(text), post }), false);
    assert.equal(received.length, 1);
    assert.deepEqual(out, ['Skipped the Slack test message.\n']);
    // A refusing receiver is reported with its status.
    const refusing = stateWith(mkdtempSync(join(s.dir, 'r-')), 'https://hooks.slack.com/services/T0000000/B0000000/refused');
    out.length = 0;
    assert.equal(await offerTest({ state: refusing, company: 'x', ask: async () => 'Y', write: text => out.push(text), post }), false);
    assert.match(out.join(''), /^Slack answered HTTP 404: the URL was not accepted\./);
    // An unreachable receiver is reported without the URL.
    out.length = 0;
    await new Promise(resolve => server.close(resolve));
    assert.equal(await offerTest({ state, company: 'x', ask: async () => 'y', write: text => out.push(text), post }), false);
    assert.match(out.join(''), /^The Slack test message failed: could not reach Slack \(/);
    assert.doesNotMatch(out.join(''), SECRET);
  } finally { server.close(); s.cleanup(); }
});

test('setup.sh asks before it does anything else and hands the URL over through a temporary file, never an argument', () => {
  const setup = read('setup.sh');
  assert.ok(setup.indexOf('alert-webhook.mjs" gate') > 0);
  assert.ok(setup.indexOf('alert-webhook.mjs" gate') < setup.indexOf('doctor.mjs" --host-preflight'), 'the question comes before the host checks');
  assert.ok(setup.indexOf('alert-webhook.mjs" gate') < setup.indexOf('scripts/configure.mjs'), 'and before configure.mjs');
  assert.match(setup, /mktemp "\$\{TMPDIR:-\/tmp\}\/warehouse-slack-webhook\.XXXXXX"/);
  assert.match(setup, /\(umask 077; mktemp/);
  assert.match(setup, /trap 'rm -f "\$WEBHOOK_TMP"' EXIT/);
  assert.match(setup, /CONFIG_ARGS\+=\(--alert-webhook-file "\$WEBHOOK_TMP"\)/);
  assert.match(setup, /alert-webhook\.mjs" test --state-dir "\$STATE"/, 'the test message is offered after the URL is stored');
  assert.doesNotMatch(setup, /curl|wget/, 'no URL on a shell command line');
  assert.match(read('.github/workflows/ci.yml'), /--admin-name 'Core Demo Administrator' \\\n\s+--alert-webhook-file off\n/, 'CI installs with off');
});
