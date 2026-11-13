// The support link (WH-159): one small health report, sent outward after every checker run to the support address the store chose at setup.
//
//   node scripts/support-link.mjs gate --state-dir STATE --given VALUE --out FILE     (setup.sh: asks the store, or passes the option on)
//
// Health signals only. The report is built from a fixed list of fields (buildReport) and nothing else: no customer, user or item names, no
// counts or amounts, no phone numbers, no sensor names or readings, no alert detail text, no addresses of the store's network. An alert is named
// by its kind only (everything after the first ':' is cut). docs/MONITORING.md, "The support link", lists the fields for the store.
//
// Files (all mode 0600, in the state, none in a backup):
//   config/support-link-url          one or two https lines: the receiving service's "success" address, and optionally its "fail" address
//                                    (without the second line, "/fail" is added to the first, the convention of healthchecks.io)
//   config/support-link-url.closing  what setup `off` leaves so that the next run can send the last report ("switched off by the store")
//   config/support-link-answer       the store's recorded answer: answer=on|off, at=<time>
//   config/support-link.last         the last attempt and the last good send (JSON)
//   logs/support-link.jsonl          every report sent, for 12 months (the body is written when it differs from the one before)
import { chmodSync, closeSync, constants, fstatSync, fsyncSync, lstatSync, mkdirSync, openSync, readFileSync, readSync, renameSync, rmSync, statSync, writeFileSync, writeSync } from 'node:fs';
import { createHash, randomBytes } from 'node:crypto';
import { join } from 'node:path';
import { isMain } from './is-main.mjs';
import { readHidden, readLine, readSecretFile } from './alert-webhook.mjs';

export const URL_FILE = 'config/support-link-url';
export const CLOSING_FILE = 'config/support-link-url.closing';
export const ANSWER_FILE = 'config/support-link-answer';
export const LAST_FILE = 'config/support-link.last';
export const LOG_FILE = 'logs/support-link.jsonl';
export const REPORT_FORMAT = 'warehouse-support-report-1';
// The size the report is designed for: a typical body is under 1 KiB and the hard cap is 8 KiB (the open-alert list is cut to fit), far
// under the 100 KB that healthchecks.io keeps of a ping body.
export const BODY_LIMIT_BYTES = 8192;
export const SEND_TIMEOUT_MS = 3000;
export const CLOSING_TRIES_MS = 24 * 60 * 60 * 1000;
const LOG_MAX_BYTES = 16 * 1024 * 1024;
const LOG_MAX_AGE_MS = 365 * 24 * 60 * 60 * 1000;

// Spec step 6: these open alerts make the state "needs attention". Any other alert is listed and changes nothing.
export const ATTENTION_KINDS = new Set(['backup_missing', 'backup_failed', 'offhost_copy_missing', 'disk_root_low', 'disk_low', 'disk_vhdx_drive_low',
  'postgres_down', 'service_down', 'api_down', 'rest_down', 'public_https_down', 'upgrade_interrupted']);
// During a planned stop (the nightly backup, an upgrade, another operator command) the services are stopped on purpose.
export const PLANNED_STOP_KINDS = new Set(['service_down', 'api_down', 'rest_down', 'public_https_down', 'check_error']);
export const STATES = ['ok', 'attention', 'planned_stop', 'switched_off'];

// The kind of an alert id: what stands before the first ':' and only when it looks like a kind (never a name, a path or a value).
export const alertKind = id => { const kind = String(id ?? '').split(':')[0]; return /^[a-z][a-z0-9_]{0,39}$/.test(kind) ? kind : 'other'; };

const iso = ms => (Number.isFinite(ms) && ms > 0 ? new Date(ms).toISOString() : null);
const percent = value => (Number.isFinite(value) ? Math.round(value * 10) / 10 : null);
const text = (value, pattern) => (typeof value === 'string' && pattern.test(value) ? value : null);

// `facts` is what the checker already knows (scripts/watch.mjs supportFacts). The result has exactly the fields below, in this order.
export function buildReport(facts) {
  const seen = new Map();
  for (const alert of facts.alerts ?? []) {
    const kind = alertKind(alert.id);
    if (facts.planned && PLANNED_STOP_KINDS.has(kind)) continue;   // stopped on purpose: not listed, not counted
    const since = Number.isFinite(alert.since) ? alert.since : null;
    const had = seen.get(kind);
    if (!had || (since !== null && (had.since === null || since < had.since))) seen.set(kind, { kind, since });
  }
  const open = [...seen.values()].sort((a, b) => a.kind.localeCompare(b.kind));
  const attention = open.some(a => ATTENTION_KINDS.has(a.kind)) || facts.alertChannelSet === false;
  const state = facts.switchedOff ? 'switched_off' : attention ? 'attention' : facts.planned ? 'planned_stop' : 'ok';
  return {
    format: REPORT_FORMAT,
    state,
    note: facts.switchedOff ? 'switched off by the store' : null,
    plannedStop: facts.planned ?? null,
    instanceId: text(facts.instanceId, /^[A-Za-z0-9_-]{1,64}$/),
    facility: typeof facts.facility === 'string' ? facts.facility.slice(0, 100) : null,
    release: text(facts.release, /^[A-Za-z0-9_.+-]{1,100}$/),
    schemaHead: Number.isInteger(facts.schemaHead) ? facts.schemaHead : null,
    reportedAt: new Date(facts.now).toISOString(),
    hostRestartedSinceLastReport: Boolean(facts.hostRestarted),
    lastBackupAt: iso(facts.lastBackupMs),
    lastVerifiedBackupAt: iso(facts.lastVerifiedMs),
    offBoxCopyAt: iso(facts.offBoxMs),
    diskFreePercent: { system: percent(facts.diskSystem), data: percent(facts.diskData) },
    openAlerts: open.map(a => ({ kind: a.kind, since: iso(a.since) })),
    alertChannelSet: Boolean(facts.alertChannelSet),
    minAppVersion: text(facts.minAppVersion, /^\d{1,4}\.\d{1,4}\.\d{1,4}$/),
  };
}
// The body: JSON, two-space indent, at most BODY_LIMIT_BYTES (the alert list is cut from the end and openAlertsCut says so).
export function serialize(report) {
  let body = `${JSON.stringify(report, null, 2)}\n`;
  if (Buffer.byteLength(body) <= BODY_LIMIT_BYTES) return body;
  const cut = { ...report, openAlertsCut: true, openAlerts: [...report.openAlerts] };
  while (cut.openAlerts.length && Buffer.byteLength(body = `${JSON.stringify(cut, null, 2)}\n`) > BODY_LIMIT_BYTES) cut.openAlerts.pop();
  return body;
}
// The body without the time, to tell whether anything changed since the report before.
const fingerprint = body => createHash('sha256').update(body.replace(/"reportedAt": "[^"]*",?\n/, '')).digest('hex').slice(0, 16);

// ---------------------------------------------------------------- the stored address and the answer
const URL_PATTERN = /^https:\/\/[^\s/]+\/?\S*$/;
const FILE_PATTERN = /^https:\/\/[^\s/]+\/?\S*(?:\r?\n\s*https:\/\/[^\s/]+\/?\S*)?$/;
// The text of `--support-link-file`: one or two https lines. Returns the lines joined by "\n".
export const readSupportLinkFile = (path, checkout) =>
  readSecretFile(path, checkout, '--support-link-file', FILE_PATTERN, 'one https address (the "success" address of the support service), and optionally a second line with its "fail" address');
const addressesOf = value => {
  const lines = String(value).split('\n').map(l => l.trim()).filter(l => l && !l.startsWith('#'));
  if (!lines.length || !lines.every(l => URL_PATTERN.test(l)) || lines.length > 2) return null;
  const success = lines[0];
  return { success, fail: lines[1] ?? `${success.replace(/\/+$/, '')}/fail` };
};
const privateFile = path => {
  const stat = lstatSync(path, { throwIfNoEntry: false });
  if (!stat) return null;
  if (!stat.isFile() || stat.uid !== process.getuid() || (stat.mode & 0o077)) return false;
  return stat;
};
// { on: false } (no file), { on: true, urls: { success, fail } } or { problem }.
export function readSupportLink(state) {
  const path = join(state, URL_FILE);
  const stat = privateFile(path);
  if (stat === null) return { on: false };
  if (stat === false) return { problem: 'config/support-link-url must be a regular file owned by the installation user with mode 0600' };
  const urls = addressesOf(readFileSync(path, 'utf8'));
  return urls ? { on: true, urls } : { problem: 'config/support-link-url must hold one or two https addresses' };
}
export function closingLink(state, now) {
  const path = join(state, CLOSING_FILE);
  const stat = privateFile(path);
  if (!stat) return null;
  const urls = addressesOf(readFileSync(path, 'utf8'));
  return urls ? { urls, since: stat.ctimeMs, expired: now - stat.ctimeMs > CLOSING_TRIES_MS } : null;
}
export function removeClosing(state) { rmSync(join(state, CLOSING_FILE), { force: true }); }
export function readAnswer(state) {
  const stat = privateFile(join(state, ANSWER_FILE));
  if (!stat) return null;
  const answer = /^answer=(on|off)$/m.exec(readFileSync(join(state, ANSWER_FILE), 'utf8'))?.[1];
  return answer ?? null;
}
function place(path, content) {
  const stat = lstatSync(path, { throwIfNoEntry: false });
  if (stat && !stat.isFile()) throw new Error(`${path} must be a regular file.`);
  const stage = `${path}.${randomBytes(8).toString('hex')}`;
  writeFileSync(stage, content, { mode: 0o600, flag: 'wx' });
  try { chmodSync(stage, 0o600); renameSync(stage, path); } catch (error) { rmSync(stage, { force: true }); throw error; }
}
// setup (scripts/configure.mjs): `value` undefined keeps everything, null switches the link off, a string (what readSupportLinkFile returned) switches it
// on. The answer is recorded either way. Switching off keeps the address as config/support-link-url.closing for the one last report. Returns
// true when the link was switched on, null when it was switched off, undefined when nothing was given.
export function placeSupportLink(state, value, now = Date.now()) {
  if (value === undefined) return undefined;
  const record = answer => place(join(state, ANSWER_FILE), `answer=${answer}\nat=${new Date(now).toISOString()}\n`);
  const path = join(state, URL_FILE);
  if (typeof value === 'string') {
    place(path, `${value.trim()}\n`);
    rmSync(join(state, CLOSING_FILE), { force: true });
    record('on');
    return true;
  }
  if (lstatSync(path, { throwIfNoEntry: false })) { renameSync(path, join(state, CLOSING_FILE)); }
  record('off');
  return null;
}

// ---------------------------------------------------------------- the record of what was sent
export function readLast(state) {
  try { const value = JSON.parse(readFileSync(join(state, LAST_FILE), 'utf8')); return value && typeof value === 'object' ? value : {}; } catch { return {}; }
}
const writeLast = (state, value) => place(join(state, LAST_FILE), `${JSON.stringify(value)}\n`);
function firstLineTime(path) {
  const fd = openSync(path, constants.O_RDONLY | constants.O_NOFOLLOW);
  try {
    const buffer = Buffer.alloc(64 * 1024);
    const head = buffer.subarray(0, readSync(fd, buffer, 0, buffer.length, 0)).toString('utf8');
    const end = head.indexOf('\n');
    return end < 0 ? NaN : Date.parse(JSON.parse(head.slice(0, end)).t);
  } catch { return NaN; } finally { closeSync(fd); }
}
// One JSON line per report sent. Pruned (through a temporary file and a rename) when its oldest line is over 12 months old or the file is over 16 MiB.
export function appendLog(state, entry, now) {
  const dir = join(state, 'logs');
  const path = join(state, LOG_FILE);
  mkdirSync(dir, { recursive: true, mode: 0o700 });
  const fd = openSync(path, constants.O_RDWR | constants.O_APPEND | constants.O_CREAT | constants.O_NOFOLLOW, 0o600);
  let size;
  try { chmodSync(path, 0o600); writeSync(fd, `${JSON.stringify(entry)}\n`); size = fstatSync(fd).size; } finally { closeSync(fd); }
  const oldest = size > 0 ? firstLineTime(path) : NaN;
  if (size > LOG_MAX_BYTES || oldest < now - LOG_MAX_AGE_MS) {
    const cutoff = now - LOG_MAX_AGE_MS;
    let lines = readFileSync(path, 'utf8').split('\n').filter(line => { try { return Date.parse(JSON.parse(line).t) >= cutoff; } catch { return false; } });
    while (lines.length > 1 && lines.join('\n').length > LOG_MAX_BYTES) lines = lines.slice(Math.ceil(lines.length / 10));
    place(path, `${lines.join('\n')}\n`);
  }
}
export function readLog(state, { days = 30, now = Date.now() } = {}) {
  let body;
  try { body = readFileSync(join(state, LOG_FILE), 'utf8'); } catch (error) { if (error?.code === 'ENOENT') return []; throw error; }
  const since = now - days * 86400000;
  return body.split('\n').filter(Boolean).map(line => { try { return JSON.parse(line); } catch { return null; } }).filter(e => e && Date.parse(e.t) >= since);
}

// ---------------------------------------------------------------- sending
// One POST to the success or the fail address (the fail one only for "attention"). Never throws, never blocks longer than the timeout, never
// alerts: a failure is recorded in config/support-link.last and the log, and said by `watch status`. `urls` are the stored addresses.
export async function sendReport({ state, urls, report, fetch: fetchFn, now, log = () => {}, timeoutMs = SEND_TIMEOUT_MS }) {
  const body = serialize(report);
  const url = report.state === 'attention' ? urls.fail : urls.success;
  const last = readLast(state);
  const entry = { t: new Date(now).toISOString(), state: report.state, bytes: Buffer.byteLength(body), address: url === urls.fail && url !== urls.success ? 'fail' : 'success' };
  let ok = false;
  let timer;
  try {
    const request = fetchFn(url, { method: 'POST', body, headers: { 'content-type': 'application/json' }, signal: AbortSignal.timeout(timeoutMs), redirect: 'error' });
    const response = await Promise.race([request, new Promise((_, reject) => { timer = setTimeout(() => reject(new Error('timeout')), timeoutMs + 500); })]);
    entry.status = response.status;
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    ok = true;
  } catch (error) {
    const why = String(error?.cause?.code ?? error?.message ?? error).split(urls.success).join('[REDACTED]').split(urls.fail).join('[REDACTED]');
    entry.error = why.slice(0, 80);
  } finally { clearTimeout(timer); }
  entry.ok = ok;
  const print = fingerprint(body);
  if (print !== last.logged) entry.report = JSON.parse(body);
  try {
    appendLog(state, entry, now);
    writeLast(state, { attemptAt: entry.t, ok, state: report.state, sentAt: ok ? entry.t : (last.sentAt ?? null), logged: print, error: ok ? null : entry.error });
  } catch (error) { log(`support link record could not be written (${error?.code ?? 'error'})`); }
  if (!ok) log(`support link report not sent: ${entry.error}`);
  return ok;
}

// The line for `watch status`.
export function statusLine(state, now) {
  let link;
  try { link = readSupportLink(state); } catch { link = { problem: 'cannot be read' }; }
  if (link.problem) return `Support link: not sent (${link.problem})`;
  if (!link.on) {
    return closingLink(state, now) ? 'Support link: off (the last report, "switched off by the store", goes out at the next run)' : 'Support link: off';
  }
  const last = readLast(state);
  if (!last.attemptAt) return 'Support link: on, nothing sent yet';
  if (last.ok) return `Support link: on, last sent ${last.sentAt}`;
  return `Support link: on, not sent since ${last.sentAt ?? 'ever'} (the last try at ${last.attemptAt} failed: ${last.error})`;
}

// ---------------------------------------------------------------- setup: the question
export const SENT_LIST = [
  'the facility name and its server identity number',
  'the server release and database version',
  'the time of the report, and whether the machine restarted since the last report',
  'the time of the last backup, of the last backup proved by a restore check, and of the last copy kept away from the machine',
  'how much disk space is free (percent)',
  'the kind and start time of each open alert (for example "backup_missing, since 04:00"), never its details',
  'whether the facility\'s own Slack alert channel is set up',
  'the oldest app version this server accepts',
];
export const NEVER_LIST = 'customer, user or item names; any number or amount of receipts, dispatches, invoices, payments or stock; phone numbers; sensor names or readings; the details of an alert; addresses on your network';
export function explanation() {
  return [
    '',
    'Support link (optional)',
    'The GCSA support desk can watch whether this facility is healthy, so that it can call you before a problem grows.',
    'If you say yes, every 5 minutes this server sends one small health report, outward over https to the address you give. Nothing is opened on your side.',
    'The report holds only:',
    ...SENT_LIST.map(item => `  - ${item}`),
    `It never holds ${NEVER_LIST}.`,
    'You can see exactly what is sent with: node scripts/watch.mjs support-report. You can switch it off at any time (setup.sh --support-link-file off), and your alerts and heartbeat do not depend on it.',
    '',
  ].join('\n');
}

function option(args, name) { const at = args.indexOf(name); return at >= 0 ? args[at + 1] : undefined; }

if (isMain(import.meta.url)) {
  const [command, ...args] = process.argv.slice(2);
  const write = message => process.stderr.write(message);
  try {
    if (command !== 'gate') throw new Error('Usage: support-link.mjs gate --state-dir STATE --given VALUE --out FILE');
    const state = option(args, '--state-dir');
    const out = option(args, '--out');
    const given = option(args, '--given') ?? '';
    if (!state || !out) throw new Error('Usage: support-link.mjs gate --state-dir STATE --given VALUE --out FILE');
    // Prints one word on standard output for setup.sh: given (use the option's value), file (the answer is in --out), off, or none (leave as it is).
    const tty = Boolean(process.stdin.isTTY);
    let result = 'none';
    if (given === 'off') result = 'off';
    else if (given && given !== 'ask') result = 'given';
    else if (given === 'ask' && !tty) throw new Error('--support-link-file ask needs a terminal to ask the question and to type the address into.');
    else if (given === 'ask' || (!readAnswer(state) && tty)) {
      write(explanation());
      const cooked = () => { try { process.stdin.setRawMode(false); } catch { /* not a terminal any more */ } };
      process.once('exit', cooked);
      try {
        const answer = String(await readLine('Turn the support link on? [y/N]') ?? '').trim().toLowerCase();
        if (answer === 'y' || answer === 'yes') {
          const first = (await readHidden('Paste the "success" address the support desk gave you (typed without echo):', { keepRaw: false })).trim();
          if (!URL_PATTERN.test(first)) throw new Error('That is not an https address; nothing was stored.');
          const second = (await readHidden('The "fail" address, if the desk gave one (Enter to skip):', { keepRaw: false })).trim();
          if (second && !URL_PATTERN.test(second)) throw new Error('That is not an https address; nothing was stored.');
          writeFileSync(out, `${first}\n${second ? `${second}\n` : ''}`, { mode: 0o600 });
          result = 'file';
          write('Support link: on. The answer is recorded in the state.\n');
        } else { result = 'off'; write('Support link: off. The answer is recorded in the state.\n'); }
      } finally { cooked(); }
    } else if (!readAnswer(state)) write('Support link: not asked (no terminal), so it stays off. Give --support-link-file <file with the address> or off to answer (docs/MONITORING.md, "The support link").\n');
    process.stdout.write(`${result}\n`);
  } catch (error) { console.error(`Support link: ${error.message}`); process.exitCode = 1; }
}
