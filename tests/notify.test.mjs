// scripts/notify.mjs, the one place that sends an alert: the adapter registry, the targets and where a message goes,
// delivery to several targets, and the local alert record (logs/alerts.jsonl). No network: the sender is a function.
import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, readdirSync, rmSync, statSync, existsSync, symlinkSync, chmodSync, utimesSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import {
  ADAPTERS, ALERT_LOG, LOG_MAX_AGE_MS, TARGET_IDS, audienceOf, createAlertLog, deliver, historyLine, loadTargets, pickAudience, readAlertLog, secretsOf, targetsOf,
} from '../scripts/notify.mjs';

const URL_A = 'https://hooks.slack.com/services/T0AAAA/B0FACI/facilityFAC123';
const URL_B = 'https://hooks.slack.com/services/T0AAAA/B0SENS/sensorSENS456';
const DAY = 24 * 60 * 60 * 1000;
const T0 = Date.parse('2026-10-30T10:00:00Z');

function scratch() {
  const dir = mkdtempSync(join(tmpdir(), 'warehouse-notify-'));
  mkdirSync(join(dir, 'config'), { recursive: true });
  return dir;
}
const withFiles = (dir, { facility, sensors } = {}) => {
  if (facility) writeFileSync(join(dir, 'config/slack-webhook-url'), `${facility}\n`, { mode: 0o600 });
  if (sensors) writeFileSync(join(dir, 'config/sensor-webhook-url'), `${sensors}\n`, { mode: 0o600 });
  return dir;
};
const message = (audience = 'facility') => ({
  audience, kind: 'alerts', name: 'Acme (wh)',
  sections: [{ heading: 'FIRING', lines: ['- disk is full: 95%'], items: [{ id: 'disk_low', summary: 'disk is full' }] }, { heading: 'CLEARED', lines: ['- db is back'], items: [{ id: 'postgres_down', summary: 'db is back' }] }],
});

test('the Slack adapter renders today\'s text exactly and validates only a Slack incoming-webhook URL', () => {
  const slack = ADAPTERS.slack;
  assert.equal(slack.label, 'Slack');
  assert.equal(slack.render(message()), '[FIRING] Acme (wh)\n- disk is full: 95%\n\n[CLEARED] Acme (wh)\n- db is back');
  assert.equal(slack.render({ kind: 'heartbeat', text: 'Monitoring is alive - Acme' }), 'Monitoring is alive - Acme');
  assert.equal(slack.validate({ url: URL_A }), true);
  assert.equal(slack.validate({ url: 'https://example.com/hook' }), false);
  assert.equal(slack.validate({}), false);
  assert.deepEqual(slack.secrets({ url: URL_A }), [URL_A]);
});

test('the Slack adapter counts only a 2xx as delivered, never throws, and its errors carry no URL', async () => {
  const send = post => ADAPTERS.slack.send({ url: URL_A }, 'hello', { post });
  assert.deepEqual(await send(async () => 200), { ok: true, status: 200 });
  assert.deepEqual(await send(async () => 204), { ok: true, status: 204 });
  assert.deepEqual(await send(async () => 404), { ok: false, status: 404, error: 'Slack answered HTTP 404' });
  assert.deepEqual(await send(async () => 302), { ok: false, status: 302, error: 'Slack answered HTTP 302' });
  assert.deepEqual(await send(async () => { throw new Error('could not reach Slack (ECONNREFUSED)'); }), { ok: false, error: 'could not reach Slack (ECONNREFUSED)' });
  let seen;
  await send(async (url, text) => { seen = [url, text]; return 200; });
  assert.deepEqual(seen, [URL_A, 'hello']);
});

test('loadTargets builds stable target ids from the existing files; an invalid or missing file is no target', () => {
  const dir = scratch();
  try {
    assert.deepEqual(loadTargets(dir), []);
    withFiles(dir, { facility: URL_A });
    assert.deepEqual(loadTargets(dir), [{ id: 'facility-slack', audience: 'facility', type: 'slack', url: URL_A }]);
    withFiles(dir, { sensors: URL_B });
    assert.deepEqual(loadTargets(dir).map(t => [t.id, t.audience]), [['facility-slack', 'facility'], ['sensors-slack', 'sensors']]);
    assert.deepEqual(TARGET_IDS, { facility: 'facility-slack', sensors: 'sensors-slack' });
    writeFileSync(join(dir, 'config/sensor-webhook-url'), 'not a webhook\n', { mode: 0o600 });
    assert.deepEqual(loadTargets(dir).map(t => t.id), ['facility-slack']);
    assert.deepEqual(secretsOf(loadTargets(dir)), [URL_A]);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('pickAudience: sensors fall back to the facility; the facility never falls back to sensors; old via values map', () => {
  const f = { audience: 'facility' };
  const s = { audience: 'sensors' };
  assert.equal(pickAudience([f, s], 'sensors'), 'sensors');
  assert.equal(pickAudience([f, s], 'facility'), 'facility');
  assert.equal(pickAudience([f], 'sensors'), 'facility');
  assert.equal(pickAudience([s], 'facility'), 'facility');
  assert.equal(pickAudience([], 'sensors'), 'facility');
  assert.deepEqual(targetsOf([f, s, f], 'facility').length, 2);
  assert.deepEqual([audienceOf('sensor'), audienceOf('sensors'), audienceOf('facility'), audienceOf('moon')], ['sensors', 'sensors', 'facility', undefined]);
});

test('deliver sends to every target, in order, and one failing target never blocks another', async () => {
  const calls = [];
  const post = async (url, text) => { calls.push([url, text]); return url === URL_A ? 500 : 200; };
  const list = [{ id: 'facility-slack', type: 'slack', url: URL_A }, { id: 'sensors-slack', type: 'slack', url: URL_B }];
  const results = await deliver({ post }, list, message());
  assert.deepEqual(results.map(r => [r.target, r.label, r.ok, r.status]), [['facility-slack', 'Slack', false, 500], ['sensors-slack', 'Slack', true, 200]]);
  assert.equal(results[0].error, 'Slack answered HTTP 500');
  assert.deepEqual(calls.map(c => c[0]), [URL_A, URL_B]);
  assert.equal(calls[1][1], ADAPTERS.slack.render(message()));
});

test('an adapter that throws becomes a failed result, and the others are still tried', async () => {
  const original = ADAPTERS.slack.send;
  try {
    ADAPTERS.slack.send = async (target, body) => { if (target.id === 'bad') throw new Error('boom'); return { ok: true, status: 201, body }; };
    const results = await deliver({}, [{ id: 'good', type: 'slack' }, { id: 'bad', type: 'slack' }, { id: 'good2', type: 'slack' }], { text: 'hi' });
    assert.deepEqual(results.map(r => r.ok), [true, false, true]);
    assert.equal(results[0].body, 'hi');
    assert.deepEqual([results[1].error, results[1].label], ['boom', 'Slack']);
  } finally { ADAPTERS.slack.send = original; }
});

const entry = (t, extra = {}) => ({ t: new Date(t).toISOString(), audience: 'facility', kind: 'alerts', results: [{ target: 'facility-slack', ok: true, status: 200 }], ...extra });

test('the alert record: one JSON line per attempt, directory 0700, file 0600 even when it existed wider, nothing but what is given', () => {
  const dir = scratch();
  try {
    const log = createAlertLog(dir, { now: () => T0 });
    log.append(entry(T0, { alerts: [{ id: 'disk_low', change: 'FIRING', summary: 'disk is full' }] }));
    log.append(entry(T0 + 1000, { results: [{ target: 'facility-slack', ok: false, status: 500, error: 'Slack answered HTTP 500' }] }));
    const lines = readFileSync(join(dir, ALERT_LOG), 'utf8').trim().split('\n').map(l => JSON.parse(l));
    assert.equal(lines.length, 2);
    assert.equal(lines[0].alerts[0].id, 'disk_low');
    assert.equal(lines[1].results[0].error, 'Slack answered HTTP 500');
    assert.equal(statSync(join(dir, ALERT_LOG)).mode & 0o777, 0o600);
    assert.equal(statSync(join(dir, 'logs')).mode & 0o777, 0o700);
    rmSync(join(dir, ALERT_LOG)); writeFileSync(join(dir, ALERT_LOG), '', { mode: 0o644 });
    log.append(entry(T0));
    assert.equal(statSync(join(dir, ALERT_LOG)).mode & 0o777, 0o600, 'an existing wider file is narrowed');
    assert.ok(!readFileSync(join(dir, ALERT_LOG), 'utf8').includes('hooks.slack.com'));
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('ensure creates the empty record so it exists after the first run', () => {
  const dir = scratch();
  try {
    createAlertLog(dir).ensure();
    assert.equal(existsSync(join(dir, ALERT_LOG)), true);
    assert.equal(readFileSync(join(dir, ALERT_LOG), 'utf8'), '');
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('a failing record write is warned about once and never throws', () => {
  const dir = scratch();
  try {
    writeFileSync(join(dir, 'logs'), 'a file where the directory should be');
    const warnings = [];
    const log = createAlertLog(dir, { now: () => T0, warn: m => warnings.push(m) });
    log.append(entry(T0)); log.append(entry(T0)); log.ensure();
    assert.equal(warnings.length, 1, 'warned once');
    assert.match(warnings[0], /alert record .* could not be written/);
    assert.ok(!/hooks\.slack/.test(warnings[0]));
    const throwing = createAlertLog(dir, { warn: () => { throw new Error('warn broke'); } });
    assert.doesNotThrow(() => throwing.append(entry(T0)));
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('a symlinked record file is not followed', () => {
  const dir = scratch();
  try {
    mkdirSync(join(dir, 'logs'));
    const elsewhere = join(dir, 'elsewhere.txt');
    writeFileSync(elsewhere, 'keep');
    symlinkSync(elsewhere, join(dir, ALERT_LOG));
    const warnings = [];
    createAlertLog(dir, { now: () => T0, warn: m => warnings.push(m) }).append(entry(T0));
    assert.equal(readFileSync(elsewhere, 'utf8'), 'keep');
    assert.equal(warnings.length, 1);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('rotation: lines older than 12 months are dropped when the oldest one ages out; the size cap drops the oldest lines; the file stays 0600 and no temporary is left', () => {
  const dir = scratch();
  try {
    mkdirSync(join(dir, 'logs'), { mode: 0o700 });
    const old = entry(T0 - LOG_MAX_AGE_MS - 3 * DAY, { alerts: [{ id: 'ancient', change: 'FIRING', summary: 's' }] });
    const fresh = entry(T0 - 5 * DAY, { alerts: [{ id: 'recent', change: 'FIRING', summary: 's' }] });
    writeFileSync(join(dir, ALERT_LOG), `${JSON.stringify(old)}\n${JSON.stringify(fresh)}\nnot json\n`, { mode: 0o600 });
    createAlertLog(dir, { now: () => T0 }).append(entry(T0, { alerts: [{ id: 'now', change: 'FIRING', summary: 's' }] }));
    const ids = readFileSync(join(dir, ALERT_LOG), 'utf8').trim().split('\n').map(l => JSON.parse(l).alerts[0].id);
    assert.deepEqual(ids, ['recent', 'now'], 'the 12-month-old line and the damaged one are gone');
    assert.equal(statSync(join(dir, ALERT_LOG)).mode & 0o777, 0o600);
    assert.deepEqual(readdirNames(join(dir, 'logs')), ['alerts.jsonl']);
    // Size cap: a tiny cap makes the oldest lines go until the file is under 75% of it.
    const log = createAlertLog(dir, { now: () => T0, maxBytes: 1000 });
    for (let i = 0; i < 30; i++) log.append(entry(T0 + i, { alerts: [{ id: `a${i}`, change: 'FIRING', summary: 'x' }] }));
    const after = readFileSync(join(dir, ALERT_LOG), 'utf8');
    assert.ok(Buffer.byteLength(after) <= 1000, `size ${Buffer.byteLength(after)}`);
    const last = after.trim().split('\n').map(l => JSON.parse(l).alerts[0].id).at(-1);
    assert.equal(last, 'a29', 'the newest line is kept');
    assert.ok(!after.includes('"a0"') && !after.includes('"recent"'), 'the oldest are dropped');
    assert.deepEqual(readdirNames(join(dir, 'logs')), ['alerts.jsonl']);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});
const readdirNames = dir => readdirSync(dir).sort();

test('readAlertLog returns the entries of the last N days in order and skips damaged lines; a missing file is empty', () => {
  const dir = scratch();
  try {
    assert.deepEqual(readAlertLog(dir, { now: T0 }), []);
    mkdirSync(join(dir, 'logs'));
    writeFileSync(join(dir, ALERT_LOG), [entry(T0 - 40 * DAY), 'garbage', entry(T0 - 2 * DAY), entry(T0 - DAY - 1), entry(T0 - DAY)].map(l => (typeof l === 'string' ? l : JSON.stringify(l))).join('\n') + '\n');
    assert.equal(readAlertLog(dir, { days: 30, now: T0 }).length, 3);
    assert.equal(readAlertLog(dir, { days: 365, now: T0 }).length, 4);
    assert.equal(readAlertLog(dir, { days: 1, now: T0 }).length, 1, 'an entry exactly N days old is inside the window; one millisecond older is outside');
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('historyLine is one readable line: time, audience, kind, the alerts, and each target delivered or FAILED', () => {
  const line = historyLine(entry(T0, { alerts: [{ id: 'disk_low', change: 'STILL FIRING', summary: 'disk\nis full' }], results: [{ target: 'facility-slack', ok: true, status: 200 }, { target: 'sensors-slack', ok: false, error: 'Slack answered HTTP 404' }] }));
  assert.equal(line, '2026-10-30T10:00:00.000Z  facility  alerts  STILL FIRING disk_low (disk is full)  ->  facility-slack delivered (HTTP 200), sensors-slack FAILED (Slack answered HTTP 404)');
  assert.match(historyLine(entry(T0, { kind: 'heartbeat', results: [] })), /heartbeat {2}-> {2}not delivered \(no channel\)$/);
  assert.ok(!historyLine(entry(T0, { alerts: [{ id: 'x\ny', change: 'FIRING', summary: 's' }] })).includes('\n'));
});

test('readAlertLog: only a missing file is empty; any other read error is thrown', () => {
  const dir = scratch();
  try {
    mkdirSync(join(dir, 'logs'));
    assert.deepEqual(readAlertLog(dir, { now: T0 }), []);
    mkdirSync(join(dir, ALERT_LOG));   // a directory where the file should be
    assert.throws(() => readAlertLog(dir, { now: T0 }), { code: 'EISDIR' });
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('rotation reads a first line longer than 1 KB: the age rule still prunes', () => {
  const dir = scratch();
  try {
    mkdirSync(join(dir, 'logs'), { mode: 0o700 });
    const longOld = entry(T0 - LOG_MAX_AGE_MS - DAY, { alerts: [{ id: 'ancient', change: 'FIRING', summary: 'x'.repeat(3000) }] });
    writeFileSync(join(dir, ALERT_LOG), `${JSON.stringify(longOld)}\n${JSON.stringify(entry(T0 - DAY, { alerts: [{ id: 'recent', change: 'FIRING', summary: 's' }] }))}\n`, { mode: 0o600 });
    createAlertLog(dir, { now: () => T0 }).append(entry(T0, { alerts: [{ id: 'now', change: 'FIRING', summary: 's' }] }));
    const ids = readFileSync(join(dir, ALERT_LOG), 'utf8').trim().split('\n').map(l => JSON.parse(l).alerts[0].id);
    assert.deepEqual(ids, ['recent', 'now']);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('the file never stays over the cap after an append (the line is appended, then the file is pruned)', () => {
  const dir = scratch();
  try {
    const log = createAlertLog(dir, { now: () => T0, maxBytes: 600 });
    for (let i = 0; i < 40; i++) {
      log.append(entry(T0 + i, { alerts: [{ id: `a${i}`, change: 'FIRING', summary: 'x' }] }));
      assert.ok(statSync(join(dir, ALERT_LOG)).size <= 600, `after ${i + 1} appends`);
    }
    const ids = readFileSync(join(dir, ALERT_LOG), 'utf8').trim().split('\n').map(l => JSON.parse(l).alerts[0].id);
    assert.equal(ids.at(-1), 'a39', 'the line just appended survives its own prune');
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('a file whose last line was cut short gets a newline first, so the next entry is not glued to it', () => {
  const dir = scratch();
  try {
    mkdirSync(join(dir, 'logs'), { mode: 0o700 });
    writeFileSync(join(dir, ALERT_LOG), `${JSON.stringify(entry(T0 - 1000))}\n{"t":"2026-10-30T09:`, { mode: 0o600 });
    createAlertLog(dir, { now: () => T0 }).append(entry(T0));
    const lines = readFileSync(join(dir, ALERT_LOG), 'utf8').split('\n');
    assert.equal(lines.length, 4);   // good, cut-short, new, and the empty piece after the final newline
    assert.equal(lines[1], '{"t":"2026-10-30T09:');
    assert.equal(JSON.parse(lines[2]).t, new Date(T0).toISOString());
    assert.equal(readAlertLog(dir, { days: 1, now: T0 }).length, 2, 'the damaged line is skipped, both good ones are read');
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('a logs directory made wider is narrowed to 0700; a stale temporary older than an hour is removed on prune, a fresh one is kept', () => {
  const dir = scratch();
  try {
    mkdirSync(join(dir, 'logs'), { mode: 0o755 });
    chmodSync(join(dir, 'logs'), 0o755);
    const stale = join(dir, 'logs/alerts.jsonl.4242.tmp');
    const fresh = join(dir, 'logs/alerts.jsonl.4343.tmp');
    const other = join(dir, 'logs/notes.tmp');
    for (const f of [stale, fresh, other]) writeFileSync(f, 'x');
    utimesSync(stale, new Date(T0 - 2 * 60 * 60 * 1000), new Date(T0 - 2 * 60 * 60 * 1000));
    utimesSync(other, new Date(T0 - 2 * 60 * 60 * 1000), new Date(T0 - 2 * 60 * 60 * 1000));
    utimesSync(fresh, new Date(T0 - 60 * 1000), new Date(T0 - 60 * 1000));
    createAlertLog(dir, { now: () => T0 }).append(entry(T0));
    assert.equal(statSync(join(dir, 'logs')).mode & 0o777, 0o700);
    assert.deepEqual(readdirSync(join(dir, 'logs')).sort(), ['alerts.jsonl', 'alerts.jsonl.4343.tmp', 'notes.tmp']);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('a temporary left by the same pid does not stop a rewrite', () => {
  const dir = scratch();
  try {
    mkdirSync(join(dir, 'logs'), { mode: 0o700 });
    writeFileSync(join(dir, `${ALERT_LOG}.${process.pid}.tmp`), 'left over');
    const log = createAlertLog(dir, { now: () => T0, maxBytes: 300 });
    for (let i = 0; i < 10; i++) log.append(entry(T0 + i));
    assert.ok(statSync(join(dir, ALERT_LOG)).size <= 300);
    assert.deepEqual(readdirSync(join(dir, 'logs')), ['alerts.jsonl']);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('historyLine ignores entries in alerts and results that are not objects (a tampered line)', () => {
  const line = historyLine({ t: '2026-10-30T10:00:00.000Z', audience: 'facility', kind: 'alerts', alerts: [null, 5, 'x', { id: 'disk_low', change: 'FIRING' }], results: [null, 'y', { target: 'facility-slack', ok: true }] });
  assert.equal(line, '2026-10-30T10:00:00.000Z  facility  alerts  FIRING disk_low  ->  facility-slack delivered');
  assert.equal(historyLine({ t: 'x', alerts: [null], results: [7] }), 'x      ->  not delivered (no channel)');
});
