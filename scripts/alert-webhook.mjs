// The facility's Slack incoming-webhook URL during `setup.sh --operator` (docs/MONITORING.md, "Alert delivery").
//
//   node alert-webhook.mjs gate --state-dir STATE --company NAME --given VALUE --out FILE
//                                                             decides where the URL comes from (setup.sh runs this first):
//                                                             VALUE is the --alert-webhook-file argument, or empty. `off`
//                                                             prints a warning; a stored URL or a file needs nothing; a terminal is
//                                                             asked for the URL (nothing is echoed; checked; 3 tries) and FILE
//                                                             (mode 0600) receives it; no terminal: refuses, exit 1
//   node alert-webhook.mjs test --state-dir STATE --company NAME   asks "Send a test message to Slack now? [Y/n]" and
//                                                             posts one short message with the URL stored in STATE
//
// The URL is a secret. It is never an argument, never in an environment variable and never printed: the
// prompt reads it from the terminal, the test reads it from the state file, and every message says only
// "stored", "removed" or an HTTP status.
import { chmodSync, closeSync, constants, lstatSync, openSync, readFileSync, writeSync } from 'node:fs';
import { request as httpsRequest } from 'node:https';
import { request as httpRequest } from 'node:http';
import { join } from 'node:path';
import { isMain } from './is-main.mjs';
import { SLACK_WEBHOOK_PATTERN } from './monitoring-config.mjs';

export const MAX_ATTEMPTS = 3;
export const PROMPT = company => `Slack incoming-webhook URL for ${company} alerts (create one in Slack: Apps → Incoming Webhooks):`;
export const REFUSAL = '--alert-webhook-file PATH is required (a file holding the facility\'s Slack webhook URL), or --alert-webhook-file off for a non-production install';
export const OFF_WARNING = 'Warning: --alert-webhook-file off: no Slack webhook, so alerts stay on this host only and nobody is told when a backup fails or the database stops. Not for a production install; add the webhook later by rerunning setup.sh --operator.';

// Reads the URL, asking again after a wrong one. `read(promptText)` returns the typed line (the terminal
// reader below does not echo it); `write(text)` prints a message. Returns the URL, or throws after the third miss.
export async function askWebhook({ company, read, write, attempts = MAX_ATTEMPTS }) {
  for (let attempt = 1; attempt <= attempts; attempt++) {
    const value = String(await read(PROMPT(company))).trim();
    if (SLACK_WEBHOOK_PATTERN.test(value)) return value;
    write(attempt < attempts
      ? 'That is not a Slack incoming-webhook URL. It looks like https://hooks.slack.com/services/T.../B.../... ; try again.\n'
      : 'That is not a Slack incoming-webhook URL.\n');
  }
  throw new Error(`No valid Slack incoming-webhook URL after ${attempts} tries.`);
}

// A line from the terminal without echo. Ctrl-C and Ctrl-D end the prompt with an error.
export function readHidden(promptText, { input = process.stdin, output = process.stderr } = {}) {
  return new Promise((resolve, reject) => {
    if (!input.isTTY || typeof input.setRawMode !== 'function') { reject(new Error('A terminal is required to type the Slack webhook URL.')); return; }
    output.write(`${promptText} `);
    let line = '';
    const finish = (error, value) => {
      input.removeListener('data', onData);
      input.setRawMode(false);
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
    input.setRawMode(true);
    input.resume();
    input.on('data', onData);
  });
}

// An ordinary visible line (the Y/n question).
export function readLine(promptText, { input = process.stdin, output = process.stderr } = {}) {
  return new Promise(resolve => {
    output.write(`${promptText} `);
    let line = '';
    const onData = chunk => {
      line += chunk.toString('utf8');
      if (!line.includes('\n')) return;
      input.removeListener('data', onData);
      input.pause();
      resolve(line.split('\n')[0]);
    };
    input.on('data', onData);
    input.resume();
  });
}

// Writes the URL to a private file (mode 0600; setup.sh creates the empty file with mktemp, so it is never shared).
export function writeWebhookFile(path, url) {
  const fd = openSync(path, constants.O_WRONLY | constants.O_CREAT | constants.O_TRUNC | constants.O_NOFOLLOW, 0o600);
  try { chmodSync(path, 0o600); writeSync(fd, `${url}\n`); } finally { closeSync(fd); }
}

// Posts one short message. `origin` (tests only: a local fake receiver, "http://127.0.0.1:PORT") replaces the
// scheme and host of the URL; the CLI never sets it. Resolves with the HTTP status; the answer body is not kept.
export function postSlackMessage(url, text, { origin, timeoutMs = 10000 } = {}) {
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
  const path = join(state, 'config/monitoring/alertmanager/webhook-url');
  if (!lstatSync(path, { throwIfNoEntry: false })?.isFile()) return null;
  const value = readFileSync(path, 'utf8').trim();
  return SLACK_WEBHOOK_PATTERN.test(value) ? value : null;
}

// The Y/n question and the post. Returns what was printed (for tests); never the URL.
export async function offerTest({ state, company, ask, write, post = postSlackMessage }) {
  const url = storedWebhook(state);
  if (!url) { write('No Slack webhook is stored, so there is nothing to test.\n'); return false; }
  const answer = String(await ask('Send a test message to Slack now? [Y/n]')).trim().toLowerCase();
  if (answer !== '' && answer !== 'y' && answer !== 'yes') { write('Skipped the Slack test message.\n'); return false; }
  try {
    const status = await post(url, testMessage(company));
    write(status >= 200 && status < 300 ? `Slack answered HTTP ${status}: check the channel for the test message.\n`
      : `Slack answered HTTP ${status}: the URL was not accepted. Check it in Slack (Apps → Incoming Webhooks) and rerun setup.sh --operator with --alert-webhook-file.\n`);
    return status >= 200 && status < 300;
  } catch (error) {
    write(`The Slack test message failed: ${error.message}. Alerts will not be delivered until Slack is reachable.\n`);
    return false;
  }
}

// What to do about the webhook: 'off' (given as off), 'file' (a path was given), 'stored' (the state has one),
// 'prompt' (ask on the terminal) or 'refuse' (nothing given, nothing stored, no terminal).
export function decideWebhookSource({ given, stored, isTTY }) {
  if (given === 'off') return 'off';
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
      else if (decision === 'refuse') { write(`${REFUSAL}\n`); process.exitCode = 1; }
      else if (decision === 'prompt') writeWebhookFile(out, await askWebhook({ company, read: readHidden, write }));
    } else if (command === 'test') {
      const state = option(args, '--state-dir');
      if (!state) throw new Error('Usage: alert-webhook.mjs test --state-dir STATE --company NAME');
      await offerTest({ state, company, ask: readLine, write });
      process.stdin.pause();
    } else throw new Error('Usage: alert-webhook.mjs gate|test ...');
  } catch (error) { console.error(`Slack webhook: ${error.message}`); process.exitCode = 1; }
}
