// The one place that sends an alert (docs/MONITORING.md, "Alert delivery"). The checker (scripts/watch.mjs) builds a
// channel-neutral message and hands it to deliver(); an adapter turns it into what one kind of channel accepts and sends
// it. Slack is the only adapter today. Delivery stays on this host on purpose: an alert must go out exactly when the
// database and the functions are down.
//
//   message  { audience: 'facility' | 'sensors', kind: 'alerts' | 'heartbeat' | 'test' | 'warning', name,
//              sections?: [{ heading, lines, items: [{ id, summary }] }], text? }
//   target   { id, audience, type, url }      id is stable ('facility-slack', 'sensors-slack'): the checker state is keyed by it
//   adapter  { label, validate(target), secrets(target) -> string[], render(message) -> body,
//              send(target, body, { post }) -> Promise<{ ok, status?, error? }> }  (send never throws)
//
// A new channel is one adapter in ADAPTERS, its own option/file in setup, and a line in loadTargets(). Nothing else
// in the checker names a channel.
//
// Every delivery attempt is also written to <state>/logs/alerts.jsonl (createAlertLog): Slack is the feed, this is the
// record. A line never holds a URL; a write failure never breaks a delivery or a checker run.
import { chmodSync, closeSync, constants, fchmodSync, fstatSync, fsyncSync, lstatSync, mkdirSync, openSync, readFileSync, readSync, readdirSync, renameSync, statSync, unlinkSync, writeSync } from 'node:fs';
import { join } from 'node:path';
import { SLACK_WEBHOOK_PATTERN, postSlackMessage, storedSensorWebhook, storedWebhook } from './alert-webhook.mjs';

export const AUDIENCES = ['facility', 'sensors'];
// Stable target ids: the state's per-target records (delivery) survive restarts under them.
export const TARGET_IDS = { facility: 'facility-slack', sensors: 'sensors-slack' };
// An alert's `via` in a state file written before audiences had names.
export const audienceOf = value => (value === 'sensor' ? 'sensors' : AUDIENCES.includes(value) ? value : undefined);

// ---------------------------------------------------------------- the message as plain text
const plainText = message => message.text ?? (message.sections ?? []).map(s => `[${s.heading}] ${message.name}\n${s.lines.join('\n')}`).join('\n\n');

// ---------------------------------------------------------------- adapters
export const ADAPTERS = {
  slack: {
    label: 'Slack',
    validate: target => SLACK_WEBHOOK_PATTERN.test(String(target?.url ?? '')),
    secrets: target => [target.url],
    render: message => plainText(message),
    // `post(url, text)` resolves with the HTTP status whatever it is: only a 2xx counts as delivered.
    async send(target, text, { post = postSlackMessage } = {}) {
      let status;
      try { status = await post(target.url, text); } catch (error) { return { ok: false, error: String(error?.message ?? error) }; }
      if (typeof status === 'number' && !(status >= 200 && status < 300)) return { ok: false, status, error: `Slack answered HTTP ${status}` };
      return { ok: true, status };
    },
  },
};

// ---------------------------------------------------------------- targets
// The channels of this installation, from the files setup keeps (config/slack-webhook-url, config/sensor-webhook-url).
export function loadTargets(state) {
  const list = [];
  const add = (audience, read) => {
    let url = null;
    try { url = read(state); } catch { /* unreadable: no target */ }
    const target = { id: TARGET_IDS[audience], audience, type: 'slack', url };
    if (url && ADAPTERS[target.type].validate(target)) list.push(target);
  };
  add('facility', storedWebhook);
  add('sensors', storedSensorWebhook);
  return list;
}
export const targetsOf = (targets, audience) => targets.filter(t => t.audience === audience);
// Where a message wanted for `wanted` goes when a side has no target: sensor alerts go to the facility's channel. The facility's
// alerts never go to the sensor channel (configure refuses a sensor webhook with no facility webhook).
export function pickAudience(targets, wanted) {
  const has = audience => targets.some(t => t.audience === audience);
  let audience = wanted;
  if (audience === 'sensors' && !has('sensors')) audience = 'facility';
  return audience;
}
export const secretsOf = targets => targets.flatMap(t => ADAPTERS[t.type]?.secrets(t) ?? []).filter(Boolean);

// ---------------------------------------------------------------- delivery
// Sends `message` to each of `list` (targets), one after the other; one failing never blocks another. Resolves with one
// result per target: { target, label, ok, status?, error? } (error is not redacted: the caller does that). Never throws.
export async function deliver({ post }, list, message) {
  const results = [];
  for (const target of list) {
    const adapter = ADAPTERS[target.type];
    let result;
    try { result = await adapter.send(target, adapter.render(message), { post }); } catch (error) { result = { ok: false, error: String(error?.message ?? error) }; }
    results.push({ target: target.id, label: adapter.label, ...result });
  }
  return results;
}

// ---------------------------------------------------------------- the alert record
export const ALERT_LOG = 'logs/alerts.jsonl';
export const LOG_MAX_BYTES = 2 * 1024 * 1024;
export const LOG_MAX_AGE_MS = 365 * 24 * 60 * 60 * 1000;

// The time of the file's first line (read up to the first newline, 64 KB at most), or NaN.
function firstLineTime(path) {
  const fd = openSync(path, constants.O_RDONLY | constants.O_NOFOLLOW);
  try {
    const buffer = Buffer.alloc(64 * 1024);
    const text = buffer.subarray(0, readSync(fd, buffer, 0, buffer.length, 0)).toString('utf8');
    const end = text.indexOf('\n');
    return end < 0 ? NaN : Date.parse(JSON.parse(text.slice(0, end)).t);
  } catch { return NaN; } finally { closeSync(fd); }
}
const keptLines = (text, cutoff) => text.split('\n').filter(line => {
  if (!line) return false;
  try { return Date.parse(JSON.parse(line).t) >= cutoff; } catch { return false; }
});
const STALE_TMP = /^alerts\.jsonl\.\d+\.tmp$/;
const STALE_TMP_MS = 60 * 60 * 1000;

// Appends one JSON line per delivery attempt, then, when the file is over LOG_MAX_BYTES (about 2 MiB) or its oldest line is
// older than 12 months, rewrites it without the lines older than 12 months (and, if it is still over the cap, without the
// oldest ones) through a temporary file and a rename, so a crash leaves the old or the new file. The rewrite happens after the
// append, so the file stays at or under the cap. Two processes pruning at once can lose the lines the slower one appended
// between the other's read and rename; that is accepted for a record (the checker and the daily pass rarely deliver at the
// same moment). Every failure is warned about once (`warn`) and swallowed.
export function createAlertLog(state, { now = Date.now, warn = () => {}, maxBytes = LOG_MAX_BYTES } = {}) {
  const dir = join(state, 'logs');
  const path = join(state, ALERT_LOG);
  let warned = false;
  const fail = error => {
    if (warned) return;
    warned = true;
    try { warn(`the alert record ${path} could not be written (${error?.code ?? 'error'}); alerts are still delivered`); } catch { /* nothing more to do */ }
  };
  const open = () => {
    mkdirSync(dir, { recursive: true, mode: 0o700 });
    // A directory made wider earlier (or by hand) is narrowed when it is ours.
    const info = statSync(dir);
    if ((info.mode & 0o077) !== 0 && info.uid === process.getuid?.()) chmodSync(dir, 0o700);
    const fd = openSync(path, constants.O_RDWR | constants.O_APPEND | constants.O_CREAT | constants.O_NOFOLLOW, 0o600);
    try { fchmodSync(fd, 0o600); } catch (error) { closeSync(fd); throw error; }
    return fd;
  };
  // A line that was cut short (a crash mid-write) would glue itself to the next one: end it first.
  const endLastLine = fd => {
    const size = fstatSync(fd).size;
    if (size === 0) return;
    const last = Buffer.alloc(1);
    readSync(fd, last, 0, 1, size - 1);
    if (last[0] !== 0x0a) writeSync(fd, '\n');
  };
  const removeStaleTemporaries = () => {
    for (const name of readdirSync(dir)) {
      if (!STALE_TMP.test(name)) continue;
      try { if (now() - lstatSync(join(dir, name)).mtimeMs > STALE_TMP_MS) unlinkSync(join(dir, name)); } catch { /* gone already */ }
    }
  };
  const prune = () => {
    removeStaleTemporaries();
    const size = statSync(path, { throwIfNoEntry: false })?.size;
    if (size === undefined) return;
    const cutoff = now() - LOG_MAX_AGE_MS;
    const oldest = firstLineTime(path);
    if (size <= maxBytes && !(oldest < cutoff)) return;
    let lines = keptLines(readFileSync(path, 'utf8'), cutoff);
    let bytes = lines.reduce((sum, line) => sum + Buffer.byteLength(line) + 1, 0);
    while (lines.length && bytes > maxBytes * 0.75) bytes -= Buffer.byteLength(lines.shift()) + 1;
    const tmp = `${path}.${process.pid}.tmp`;
    let fd;
    try {
      try { unlinkSync(tmp); } catch { /* none left over */ }
      fd = openSync(tmp, constants.O_WRONLY | constants.O_CREAT | constants.O_EXCL | constants.O_NOFOLLOW, 0o600);
      writeSync(fd, lines.length ? `${lines.join('\n')}\n` : '');
      fsyncSync(fd);
      closeSync(fd); fd = undefined;
      renameSync(tmp, path);
    } catch (error) {
      if (fd !== undefined) { try { closeSync(fd); } catch { /* already closed */ } }
      try { unlinkSync(tmp); } catch { /* nothing to remove */ }
      throw error;
    }
  };
  return {
    path,
    // Creates the (empty) file so an operator finds it after the first run.
    ensure() { try { closeSync(open()); } catch (error) { fail(error); } },
    append(entry) {
      try {
        const fd = open();
        try { endLastLine(fd); writeSync(fd, `${JSON.stringify(entry)}\n`); } finally { closeSync(fd); }
        prune();
      } catch (error) { fail(error); }
    },
  };
}

// The entries of the last `days` days, oldest first. A missing file (ENOENT) is no entries; any other read error is thrown
// (the caller says it: an unreadable record is not an empty one); a damaged line is skipped.
export function readAlertLog(state, { days = 30, now = Date.now() } = {}) {
  let text;
  try { text = readFileSync(join(state, ALERT_LOG), 'utf8'); } catch (error) { if (error?.code === 'ENOENT') return []; throw error; }
  const since = now - days * 24 * 60 * 60 * 1000;
  const entries = [];
  for (const line of text.split('\n')) {
    if (!line) continue;
    try { const entry = JSON.parse(line); if (Date.parse(entry.t) >= since) entries.push(entry); } catch { /* damaged line */ }
  }
  return entries;
}

const oneLine = value => String(value ?? '').replace(/\s+/g, ' ').trim();
export function historyLine(entry) {
  const objects = value => (Array.isArray(value) ? value.filter(item => item !== null && typeof item === 'object') : []);   // a tampered line may hold anything
  const alertList = objects(entry.alerts);
  const resultList = objects(entry.results);
  const alerts = alertList.length ? `  ${alertList.map(a => `${oneLine(a.change)} ${oneLine(a.id)}${a.summary ? ` (${oneLine(a.summary)})` : ''}`).join('; ')}` : '';
  const results = resultList.length
    ? resultList.map(r => (r.ok ? `${oneLine(r.target)} delivered${r.status ? ` (HTTP ${r.status})` : ''}` : `${oneLine(r.target)} FAILED${r.error ? ` (${oneLine(r.error)})` : ''}`)).join(', ')
    : 'not delivered (no channel)';
  return `${oneLine(entry.t)}  ${oneLine(entry.audience)}  ${oneLine(entry.kind)}${alerts}  ->  ${results}`;
}
