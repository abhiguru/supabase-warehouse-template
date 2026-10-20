// The facility's Slack incoming-webhook URL during `setup.sh --operator` (docs/MONITORING.md, "Alert delivery").
//
//   node alert-webhook.mjs gate --state-dir STATE --company NAME --given VALUE --out FILE
//       decides where the URL comes from (setup.sh runs this after the host checks and the lock). VALUE is the
//       --alert-webhook-file argument, or empty. `off` prints a warning; a path or a stored URL needs nothing;
//       empty with no stored URL, or `ask`, on a terminal: asks for the URL (nothing is echoed; checked; 3 tries),
//       posts a test message BEFORE anything is stored, and only then writes the URL to FILE (mode 0600).
//       No terminal: refuses, exit 1.
//
// The URL is a secret. It is never an argument, never in an environment variable and never printed: the
// prompt reads it from the terminal, the test reads it from the state file, and every message says only
// "stored", "removed" or an HTTP status.
import { chmodSync, closeSync, constants, lstatSync, openSync, readFileSync, realpathSync, renameSync, rmSync, writeFileSync, writeSync } from 'node:fs';
import { randomBytes } from 'node:crypto';
import { request as httpsRequest } from 'node:https';
import { request as httpRequest } from 'node:http';
import { isAbsolute, join, resolve, sep } from 'node:path';
import { isMain } from './is-main.mjs';

// A Slack incoming-webhook URL, and nothing else: the only receiver this repository supports.
export const SLACK_WEBHOOK_PATTERN = /^https:\/\/hooks\.slack\.com\/services\/[A-Z0-9]+\/[A-Z0-9]+\/[A-Za-z0-9]+$/;
export const WEBHOOK_MAX_BYTES = 2048;
// Where the state keeps the URL (mode 0600). Installations made before the Slack checker (scripts/watch.mjs) kept it
// for Alertmanager under config/monitoring/alertmanager/; a setup rerun moves it (placeWebhook).
export const WEBHOOK_FILE = 'config/slack-webhook-url';
export const LEGACY_WEBHOOK_FILE = 'config/monitoring/alertmanager/webhook-url';

export const MAX_ATTEMPTS = 3;
export const PROMPT = company => `Slack incoming-webhook URL for ${company} alerts (create one in Slack: Apps → Incoming Webhooks):`;
export const REFUSAL = '--alert-webhook-file PATH is required (a file holding the facility\'s Slack webhook URL), or --alert-webhook-file off for a non-production install';
export const OFF_WARNING = 'Warning: --alert-webhook-file off: no Slack webhook, so alerts stay on this host only and nobody is told when a backup fails or the database stops. Not for a production install; add the webhook later by rerunning setup.sh --operator with your usual inputs, leaving out --alert-webhook-file off (it then asks for the URL on a terminal), or passing --alert-webhook-file <a private file holding the URL>.';

const NOT_SLACK = 'That is not a Slack incoming-webhook URL.';
const isNo = answer => answer === null || /^n(o)?$/i.test(String(answer).trim());
const isYes = answer => /^y(es)?$/i.test(String(answer).trim());

// Reads the URL and proves it before it is kept. `read(promptText)` returns the typed line (the terminal reader
// below does not echo it); `ask(text)` returns a visible answer, or null at end of input; `write(text)` prints.
// A wrong shape is asked again; the test message is posted before the URL is returned, and when Slack does not
// accept it (or cannot be reached) the operator either keeps it explicitly or types another, all within the
// tries. Returns the URL, or throws after the last miss.
export async function obtainWebhook({ company, read, ask, write, post = postSlackMessage, attempts = MAX_ATTEMPTS }) {
  for (let attempt = 1; attempt <= attempts; attempt++) {
    const value = String(await read(PROMPT(company))).trim();
    if (!SLACK_WEBHOOK_PATTERN.test(value)) {
      write(attempt < attempts ? `${NOT_SLACK} It looks like https://hooks.slack.com/services/T.../B.../... ; try again.\n` : `${NOT_SLACK}\n`);
      continue;
    }
    if (isNo(await ask('Send a test message to Slack now? [Y/n]'))) { write('Skipped the Slack test message.\n'); return value; }
    let failure;
    try {
      const status = await post(value, testMessage(company));
      if (status >= 200 && status < 300) { write(`Slack answered HTTP ${status}: check the channel for the test message.\n`); return value; }
      failure = `Slack answered HTTP ${status}: the URL was not accepted (revoked, mistyped or the wrong workspace).`;
    } catch (error) { failure = `The Slack test message failed: ${error.message}.`; }
    write(`${failure}\n`);
    if (isYes(await ask('Store this URL anyway? [y/N]'))) return value;
    if (attempt < attempts) write('Type the URL again, or create a new one in Slack.\n');
  }
  throw new Error(`No working Slack incoming-webhook URL after ${attempts} tries; nothing was stored.`);
}

// A line from the terminal without echo. Ctrl-C and Ctrl-D end the prompt with an error.
// With `keepRaw` the terminal stays in raw mode (no echo) after the line, so anything typed ahead before the next
// prompt is not echoed either; the caller then restores the terminal (see the gate below).
export function readHidden(promptText, { input = process.stdin, output = process.stderr, keepRaw = false } = {}) {
  return new Promise((resolve, reject) => {
    if (!input.isTTY || typeof input.setRawMode !== 'function') { reject(new Error('A terminal is required to type the Slack webhook URL.')); return; }
    // Raw mode first, then the prompt: whatever is typed once the prompt is visible is never echoed.
    input.setRawMode(true);
    output.write(`${promptText} `);
    let line = '';
    const finish = (error, value) => {
      input.removeListener('data', onData);
      if (!keepRaw) input.setRawMode(false);
      input.pause();
      output.write('\n');
      if (error) reject(error); else resolve(value);
    };
    const onData = chunk => {
      for (const char of chunk.toString('utf8')) {
        if (char === '\r' || char === '\n') return finish(null, line);
        if (char === '\u0003' || char === '\u0004') return finish(new Error('Cancelled.'));
        if (char === '\u007f' || char === '\b') line = line.slice(0, -1);
        else if (char >= ' ') line += char;
      }
    };
    input.resume();
    input.on('data', onData);
  });
}

// An ordinary visible line; null at end of input (nothing typed, the input closed).
export function readLine(promptText, { input = process.stdin, output = process.stderr } = {}) {
  return new Promise(resolve => {
    output.write(`${promptText} `);
    let line = '';
    const done = value => { input.removeListener('data', onData); input.removeListener('end', onEnd); input.pause(); output.write(value === null ? '\n' : ''); resolve(value); };
    const onData = chunk => {
      line += chunk.toString('utf8');
      if (line.includes('\n')) done(line.split('\n')[0]);
    };
    const onEnd = () => done(line.length ? line : null);
    input.on('data', onData);
    input.on('end', onEnd);
    input.resume();
  });
}

// Writes the URL to a private file (mode 0600; setup.sh creates the empty file with mktemp, so it is never shared).
export function writeWebhookFile(path, url) {
  const fd = openSync(path, constants.O_WRONLY | constants.O_CREAT | constants.O_TRUNC | constants.O_NOFOLLOW, 0o600);
  try { chmodSync(path, 0o600); writeSync(fd, `${url}\n`); } finally { closeSync(fd); }
}

const testOrigin = () => (/^http:\/\/127\.0\.0\.1:\d{2,5}$/.test(process.env.WAREHOUSE_SLACK_POST_ORIGIN ?? '') ? process.env.WAREHOUSE_SLACK_POST_ORIGIN : undefined);

// Posts one short message. `origin` (tests only: a local fake receiver, "http://127.0.0.1:PORT") replaces the
// scheme and host of the URL; the CLI never sets it. Resolves with the HTTP status; the answer body is not kept.
export function postSlackMessage(url, text, { origin = testOrigin(), timeoutMs = 10000 } = {}) {
  return new Promise((resolve, reject) => {
    const target = new URL(url);
    const base = origin ? new URL(origin) : target;
    const send = base.protocol === 'http:' ? httpRequest : httpsRequest;
    const body = JSON.stringify({ text });
    const req = send({ hostname: base.hostname, port: base.port || undefined, path: target.pathname, method: 'POST', timeout: timeoutMs,
      headers: { 'content-type': 'application/json', 'content-length': Buffer.byteLength(body) } }, res => { res.resume(); res.on('end', () => resolve(res.statusCode)); });
    req.on('timeout', () => req.destroy(new Error('timed out')));
    req.on('error', error => reject(new Error(`could not reach Slack (${error.code ?? error.message})`)));
    req.end(body);
  });
}

export const testMessage = company => `Test message from the ${company} warehouse server: Slack alerts are connected. You will get a "Monitoring is alive" message here once a day.`;

export function storedWebhook(state) {
  for (const file of [WEBHOOK_FILE, LEGACY_WEBHOOK_FILE]) {
    const path = join(state, file);
    if (!lstatSync(path, { throwIfNoEntry: false })?.isFile()) continue;
    const value = readFileSync(path, 'utf8').trim();
    return SLACK_WEBHOOK_PATTERN.test(value) ? value : null;
  }
  return null;
}

// The address in an --alert-webhook-file: one Slack incoming-webhook URL. The file is the operator's
// secret (the address carries a token), so no message here quotes its contents.
export function alertWebhookAddress(text) {
  const value = text.replace(/^\uFEFF/, '').trim();
  if (!SLACK_WEBHOOK_PATTERN.test(value)) throw new Error('--alert-webhook-file must hold one Slack incoming-webhook URL (https://hooks.slack.com/services/...).');
  return value;
}

// --alert-webhook-file PATH | off. Returns undefined (leave the state alone), null (remove the stored
// address) or the address. Everything is checked before anything is written.
export function readAlertWebhook(path, checkout) {
  if (path === undefined) return undefined;
  if (path === 'off') return null;
  if (!isAbsolute(path)) throw new Error('--alert-webhook-file must be an absolute path (or off).');
  const st = lstatSync(path, { throwIfNoEntry: false });
  if (!st?.isFile()) throw new Error('--alert-webhook-file must be a regular file.');
  if (resolve(path).startsWith(checkout + sep) || realpathSync(path).startsWith(checkout + sep)) throw new Error('--alert-webhook-file must be outside the checkout.');
  if (st.uid !== process.getuid() || (st.mode & 0o077)) throw new Error('--alert-webhook-file must be owned by this user and mode 0600 (it holds a secret address).');
  if (st.size > WEBHOOK_MAX_BYTES) throw new Error('--alert-webhook-file is larger than 2 KB.');
  return alertWebhookAddress(readFileSync(path, 'utf8'));
}

// Replaces a file through a same-directory temporary, so a reader sees the old or the new content.
function place(path, bytes, mode) {
  const st = lstatSync(path, { throwIfNoEntry: false });
  if (st && !st.isFile()) throw new Error(`${path} must be a regular file.`);
  if (st && (st.mode & 0o777) === mode && readFileSync(path).equals(bytes)) return false;
  const stage = `${path}.${randomBytes(8).toString('hex')}`;
  writeFileSync(stage, bytes, { mode, flag: 'wx' });
  try { chmodSync(stage, mode); renameSync(stage, path); } catch (error) { rmSync(stage, { force: true }); throw error; }
  return true;
}

// Writes the webhook into `state` (an installed state, or the staging directory of a fresh one). `webhook` is what
// readAlertWebhook returned: undefined keeps the stored address, null removes it, a string stores it. An address
// stored at the old Alertmanager path is moved to WEBHOOK_FILE (unless the new file exists), and the rendered
// Prometheus and Alertmanager files, which nothing reads any more, are removed.
// The old directories nothing reads any more (config/monitoring, metrics/, data/alertmanager/) are removed when they
// are real directories owned by this user; one owned by another user (a container wrote it) is left for the operator.
// Returns { moved, cleaned }: moved when the webhook file was written or removed, cleaned when old files were removed.
export const OLD_MONITORING_DIRS = ['config/monitoring', 'metrics', 'data/alertmanager'];
export function placeWebhook(state, webhook) {
  const path = join(state, WEBHOOK_FILE);
  const legacy = join(state, LEGACY_WEBHOOK_FILE);
  const hasLegacy = Boolean(lstatSync(legacy, { throwIfNoEntry: false })?.isFile());
  let moved = false;
  let cleaned = false;
  if (webhook === undefined && hasLegacy && !lstatSync(path, { throwIfNoEntry: false })) {
    const st = lstatSync(legacy);
    if (st.size > WEBHOOK_MAX_BYTES) throw new Error(`${legacy} is larger than 2 KB.`);
    moved = place(path, Buffer.from(`${alertWebhookAddress(readFileSync(legacy, 'utf8'))}\n`), 0o600);
  }
  if (typeof webhook === 'string') moved = place(path, Buffer.from(`${webhook}\n`), 0o600) || moved;
  if (webhook === null) {
    // Off removes the address at both paths: an old URL must never keep posting.
    if (lstatSync(path, { throwIfNoEntry: false })) { rmSync(path); moved = true; }
    if (hasLegacy) { rmSync(legacy, { force: true }); moved = true; }
    if (lstatSync(legacy, { throwIfNoEntry: false })) throw new Error(`${legacy} could not be removed; delete it so the old Slack webhook stops posting.`);
  }
  for (const old of OLD_MONITORING_DIRS) {
    const dir = lstatSync(join(state, old), { throwIfNoEntry: false });
    if (dir?.isDirectory() && dir.uid === process.getuid()) { rmSync(join(state, old), { recursive: true }); cleaned = true; }
  }
  return { moved, cleaned };
}

// What to do about the webhook: 'off' (given as off), 'file' (a path was given), 'stored' (the state has one),
// 'prompt' (ask on the terminal: nothing given and nothing stored, or `ask` to replace the stored one) or
// 'refuse' (it needs a terminal and there is none).
export function decideWebhookSource({ given, stored, isTTY }) {
  if (given === 'off') return 'off';
  if (given === 'ask') return isTTY ? 'prompt' : 'refuse';
  if (given) return 'file';
  if (stored) return 'stored';
  return isTTY ? 'prompt' : 'refuse';
}

function option(args, name) {
  const at = args.indexOf(name);
  return at >= 0 ? args[at + 1] : undefined;
}

if (isMain(import.meta.url)) {
  const [command, ...args] = process.argv.slice(2);
  const company = option(args, '--company') || 'this facility';
  const write = text => process.stderr.write(text);
  try {
    if (command === 'gate') {
      const state = option(args, '--state-dir');
      const out = option(args, '--out');
      if (!state || !out) throw new Error('Usage: alert-webhook.mjs gate --state-dir STATE --company NAME --given VALUE --out FILE');
      const decision = decideWebhookSource({ given: option(args, '--given'), stored: storedWebhook(state) !== null, isTTY: Boolean(process.stdin.isTTY) });
      if (decision === 'off') write(`${OFF_WARNING}\n`);
      else if (decision === 'refuse') { write(`${option(args, '--given') === 'ask' ? '--alert-webhook-file ask needs a terminal to type the URL into' : REFUSAL}\n`); process.exitCode = 1; }
      else if (decision === 'prompt') {
        // Echo stays off for the whole entry (all tries): it is switched on only while a visible Y/n question is
        // answered, and always restored at the end, on an error and on an exit.
        const tty = process.stdin;
        const cooked = () => { try { tty.setRawMode(false); } catch { /* not a terminal any more */ } };
        process.once('exit', cooked);
        try {
          const read = text => readHidden(text, { keepRaw: true });
          const ask = async text => { cooked(); try { return await readLine(text); } finally { tty.setRawMode(true); } };
          writeWebhookFile(out, await obtainWebhook({ company, read, ask, write }));
        } finally { cooked(); }
        write('Slack webhook accepted; setup stores it in the state (mode 0600).\n');
      }
    } else throw new Error('Usage: alert-webhook.mjs gate ...');
  } catch (error) { console.error(`Slack webhook: ${error.message}`); process.exitCode = 1; }
}
