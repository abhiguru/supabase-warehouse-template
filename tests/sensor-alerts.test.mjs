import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, writeFileSync, rmSync } from 'node:fs';
import { readFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import * as W from '../scripts/watch.mjs';
import { DEFAULT_OUT_OF_RANGE_MINUTES, DEFAULT_SILENT_MINUTES, droppedFromLog, droppedSummary, rangeState, sensorAlertMinutes, sensorAlerts } from '../scripts/sensor-alerts.mjs';

// WH-118: per-sensor alerts (outside its limits for 15 minutes, silent for 30 minutes while its hub is up) and the daily alert for readings
// the sensor bridge dropped. Pure functions first, then the two checks of scripts/watch.mjs against a fake compose.
const NOW = Date.parse('2026-11-07T10:00:00Z');
// Readings every 5 minutes, newest first, from a list of temperatures oldest first: the newest is age 0.
const series = temps => temps.map((t, i) => ({ t, age_s: (temps.length - 1 - i) * 300 })).reverse();
const MIN = 60;

test('the settings: 15 and 30 minutes unless a whole number from 1 to 1440 is set', () => {
  assert.deepEqual([DEFAULT_OUT_OF_RANGE_MINUTES, DEFAULT_SILENT_MINUTES], [15, 30]);
  assert.deepEqual(sensorAlertMinutes({}), { outMinutes: 15, silentMinutes: 30 });
  assert.deepEqual(sensorAlertMinutes({ WAREHOUSE_SENSOR_OUT_OF_RANGE_MINUTES: '10', WAREHOUSE_SENSOR_SILENT_MINUTES: ' 45 ' }), { outMinutes: 10, silentMinutes: 45 });
  for (const bad of ['0', '1441', '-5', '1.5', 'abc', '', '99999', '1e2']) {
    assert.deepEqual(sensorAlertMinutes({ WAREHOUSE_SENSOR_OUT_OF_RANGE_MINUTES: bad, WAREHOUSE_SENSOR_SILENT_MINUTES: bad }), { outMinutes: 15, silentMinutes: 30 }, bad);
  }
  assert.equal(sensorAlertMinutes({ WAREHOUSE_SENSOR_OUT_OF_RANGE_MINUTES: '1440' }).outMinutes, 1440);
});

test('rangeState: raised after 15 minutes outside, not before; a short stretch outside never raises', () => {
  const inside = Array(6).fill(4);
  assert.equal(rangeState(series(inside), 2, 8, 900).raised, false);
  // 4 readings outside (15 minutes from first to last): raised
  assert.equal(rangeState(series([4, 4, 9, 9, 9, 9]), 2, 8, 900).raised, true);
  // 3 readings outside (10 minutes): not yet
  assert.equal(rangeState(series([4, 4, 4, 9, 9, 9]), 2, 8, 900).raised, false);
  // a spike that ends: never raised
  assert.equal(rangeState(series([4, 9, 9, 4, 4, 4]), 2, 8, 900).raised, false);
  const raised = rangeState(series([4, 4, 9, 9, 9, 9, 9]), 2, 8, 900);
  assert.equal(raised.raised, true);
  assert.equal(raised.outSinceAge, 1200, 'the stretch started at the first reading outside');
  assert.equal(raised.newest.t, 9);
});

test('rangeState: clears after 15 minutes inside again; a short return inside does not clear it; either limit alone works', () => {
  assert.equal(rangeState(series([9, 9, 9, 9, 4, 4]), 2, 8, 900).raised, true, '5 minutes back inside: still raised');
  assert.equal(rangeState(series([9, 9, 9, 9, 4, 4, 4, 4]), 2, 8, 900).raised, false, '15 minutes back inside: cleared');
  assert.equal(rangeState(series([4, 4, 1, 1, 1, 1]), 2, null, 900).raised, true, 'only a lowest limit');
  assert.equal(rangeState(series([4, 4, 1, 1, 1, 1]), null, 8, 900).raised, false, 'only a highest limit: 1 is inside');
  assert.deepEqual(rangeState([], 2, 8, 900), { raised: false, outSinceAge: null, newest: null });
});

const device = (extra = {}) => ({ id: 'd1', name: 'Chamber 1 sensor', location: 'Chamber 1', lo: 2, hi: 8, reading_age_s: 60, hub_online: true, hub_age_s: 30, readings: series([4, 4, 4, 4]), ...extra });
const alertsOf = (devices, extra = {}) => sensorAlerts({ devices, nowMs: NOW, outMinutes: 15, silentMinutes: 30, limitSeconds: 600, ...extra });

test('sensorAlerts: a sensor that is fine raises nothing; one outside its limits for 15 minutes raises sensor_range:<id> naming the limit', () => {
  assert.deepEqual(alertsOf([device()]), []);
  const [alert] = alertsOf([device({ readings: series([4, 4, 9.5, 9.5, 9.5, 9.5]) })]);
  assert.equal(alert.id, 'sensor_range:d1');
  assert.match(alert.summary, /^Temperature alarm: Chamber 1 sensor \(Chamber 1\) reads 9\.5 C, above its highest limit 8 C$/);
  assert.match(alert.detail, /Outside its limits since 2026-11-07 09:45 UTC; newest reading 9\.5 C at 2026-11-07 10:00 UTC\. Limits 2 to 8 C; alerts after 15 minutes outside, clears after 15 minutes inside\./);
  assert.equal(alert.repeatHours, 24 * 365, 'posted once');
  const [low] = alertsOf([device({ lo: 2, hi: null, readings: series([4, 4, 1, 1, 1, 1]) })]);
  assert.match(low.summary, /below its lowest limit 2 C/);
  assert.equal(alertsOf([device({ lo: null, hi: null, readings: series([99, 99, 99, 99, 99, 99]) })]).length, 0, 'a sensor with no limits has no range alert');
  assert.equal(alertsOf([device({ readings: series([4, 4, 9, 9, 9, 9]) })], { outMinutes: 20 }).length, 0, 'the setting moves the threshold');
});

test('sensorAlerts: silent for 30 minutes while its hub is up; a down hub is the sensors_stale alert\'s business', () => {
  assert.equal(alertsOf([device({ reading_age_s: 29 * MIN + 59 })]).length, 0);
  const [alert] = alertsOf([device({ reading_age_s: 30 * MIN })]);
  assert.equal(alert.id, 'sensor_silent:d1');
  assert.match(alert.summary, /^Sensor silent: Chamber 1 sensor \(Chamber 1\) sent no reading for 30 minutes$/);
  assert.match(alert.detail, /Last reading at 2026-11-07 09:30 UTC; its hub is online\./);
  assert.equal(alertsOf([device({ reading_age_s: 3600, hub_online: false })]).length, 0, 'hub offline');
  assert.equal(alertsOf([device({ reading_age_s: 3600, hub_age_s: 601 })]).length, 0, 'hub not heard from within the limit');
  assert.equal(alertsOf([device({ reading_age_s: 3600, hub_online: null })]).length, 0, 'unknown hub state');
  assert.equal(alertsOf([device({ reading_age_s: 20 * MIN })], { silentMinutes: 10 }).length, 1, 'the setting moves the threshold');
});

test('sensorAlerts: one alert id per sensor and kind', () => {
  const alerts = alertsOf([device({ id: 'a', reading_age_s: 4000 }), device({ id: 'b', reading_age_s: 4000, readings: series([9, 9, 9, 9, 9, 9]) }), device({ id: 'c' })]);
  assert.deepEqual(alerts.map(a => a.id).sort(), ['sensor_range:b', 'sensor_silent:a', 'sensor_silent:b']);
});

test('droppedFromLog and droppedSummary read the bridge\'s readings_dropped lines', () => {
  assert.deepEqual(droppedFromLog(''), { total: 0, byReason: {} });
  assert.deepEqual(droppedFromLog(undefined), { total: 0, byReason: {} });
  const log = ['event=started', 'event=readings_dropped reason=queue_full hub=h1 dropped=3', 'x event=readings_dropped reason=too_old hub=h2 dropped=2',
    'event=readings_dropped reason=queue_full hub=h1 dropped=4', 'event=readings_dropped reason=bad hub=h1 dropped=abc'].join('\n');
  const found = droppedFromLog(log);
  assert.deepEqual(found, { total: 9, byReason: { queue_full: 7, too_old: 2 } });
  assert.equal(droppedSummary(found), 'Sensor bridge dropped 9 readings in the last 24 hours (7 queue full; 2 too old)');
  assert.equal(droppedSummary({ total: 1, byReason: { too_old: 1 } }), 'Sensor bridge dropped 1 reading in the last 24 hours (1 too old)');
});

// ---- the checks of watch.mjs ----
function world({ sensors = true, hubs = 'h1', db = 0, query = { status: 0, stdout: '[]' }, logs = { status: 0, stdout: '' } } = {}) {
  const dir = mkdtempSync(join(tmpdir(), 'warehouse-sensor-alerts-'));
  const state = join(dir, 'state');
  mkdirSync(join(state, 'public'), { recursive: true });
  mkdirSync(join(state, 'config'), { recursive: true });
  writeFileSync(join(state, 'public/instance.json'), JSON.stringify({ capabilities: { sensors, printing: false, payments: false } }));
  writeFileSync(join(state, 'config/compose.env'), `GATEWAY_HTTP_PORT=18000\nSENSOR_BRIDGE_HUBS=${hubs}\n`);
  const calls = [];
  const deps = {
    state, root: dir, env: {}, now: () => NOW,
    readText: path => { try { return readFileSync(path, 'utf8'); } catch { return null; } },
    run: (command, args) => {
      const line = `${command} ${args.join(' ')}`;
      calls.push(line);
      if (line.includes('pg_isready')) return { status: db, stdout: '', stderr: '' };
      if (line.includes('psql')) return { stderr: '', ...query };
      if (line.includes('logs')) return { stderr: '', ...logs };
      return { status: 1, stdout: '', stderr: 'unexpected' };
    },
  };
  return { calls, ctx: W.makeContext(deps, W.freshState(NOW)), clean: () => rmSync(dir, { recursive: true, force: true }) };
}

test('checkSensorAlerts: off without the sensors capability; not judged when the database is down or unreadable; failing alerts are immediate', () => {
  for (const options of [{ sensors: false }]) {
    const w = world(options);
    try { assert.deepEqual(W.checkSensorAlerts(w.ctx), []); assert.equal(w.calls.length, 0); } finally { w.clean(); }
  }
  for (const options of [{ db: 1 }, { query: { status: 1, stdout: '' } }, { query: { status: 0, stdout: 'not json' } }, { query: { status: 0, stdout: '{"a":1}' } }]) {
    const w = world(options);
    try { assert.equal(W.checkSensorAlerts(w.ctx), null, JSON.stringify(options)); } finally { w.clean(); }
  }
  const w = world({ query: { status: 0, stdout: JSON.stringify([device({ reading_age_s: 4000 })]) } });
  try {
    const results = W.checkSensorAlerts(w.ctx);
    assert.deepEqual(results.map(r => [r.check, r.id, r.ok, r.immediate, r.repeatHours]), [['sensor_alerts', 'sensor_silent:d1', false, true, 24 * 365]]);
    const none = world({ query: { status: 0, stdout: '[]' } });
    try { assert.deepEqual(W.checkSensorAlerts(none.ctx), []); } finally { none.clean(); }
  } finally { w.clean(); }
});

test('checkSensorDrops: only with sensors on and a bridge of this project; the last 24 hours of its log; a daily immediate alert', () => {
  for (const options of [{ sensors: false }, { hubs: '' }, { hubs: '   ' }]) {
    const w = world(options);
    try { assert.deepEqual(W.checkSensorDrops(w.ctx), [], JSON.stringify(options)); assert.equal(w.calls.length, 0); } finally { w.clean(); }
  }
  const unreadable = world({ logs: { status: 1, stdout: '' } });
  try { assert.equal(W.checkSensorDrops(unreadable.ctx), null); } finally { unreadable.clean(); }
  const clean = world({ logs: { status: 0, stdout: 'event=posted ok\n' } });
  try {
    assert.deepEqual(W.checkSensorDrops(clean.ctx).map(r => [r.id, r.ok]), [['sensor_dropped', true]]);
    assert.match(clean.calls.at(-1), /--profile sensors logs --since 24h --no-color --no-log-prefix sensor-bridge$/);
  } finally { clean.clean(); }
  const dropped = world({ logs: { status: 0, stdout: 'event=readings_dropped reason=queue_full hub=h1 dropped=5\n' } });
  try {
    const [r] = W.checkSensorDrops(dropped.ctx);
    assert.deepEqual([r.id, r.ok, r.immediate, r.repeatHours], ['sensor_dropped', false, true, 24]);
    assert.equal(r.summary, 'Sensor bridge dropped 5 readings in the last 24 hours (5 queue full)');
  } finally { dropped.clean(); }
});

test('both checks are registered, and their alerts go to the sensor webhook', () => {
  assert.ok(W.CHECKS.some(([name, fn]) => name === 'sensor_alerts' && fn === W.checkSensorAlerts));
  assert.ok(W.CHECKS.some(([name, fn]) => name === 'sensor_dropped' && fn === W.checkSensorDrops));
  for (const id of ['sensor_range:d1', 'sensor_silent:abc', 'sensor_dropped', 'check_error:sensor_alerts', 'check_error:sensor_dropped']) assert.equal(W.isSensorAlert(id), true, id);
  for (const id of ['sensor_range', 'sensor_silent', 'sensor_dropped_x', 'service_down:db']) assert.equal(W.isSensorAlert(id), false, id);
});

test('a new episode after a recovery whose clear was never posted starts at once (the old repeat time does not hold it back)', () => {
  const data = W.freshState(NOW);
  const failing = [{ check: 'c', id: 'x_bad', ok: false, summary: 'bad', detail: '', immediate: true, repeatHours: 8760 }];
  const ran = new Set(['c']);
  assert.deepEqual(W.evaluate(data, failing, ran, NOW).start.map(l => l.id), ['x_bad']);
  data.alerts.x_bad.lastSent = NOW;                        // posted
  assert.deepEqual(W.evaluate(data, failing, ran, NOW + 60000).start, [], 'not posted again within its repeat time');
  W.evaluate(data, [{ ...failing[0], ok: true }], ran, NOW + 120000);   // recovered; the clear is pending (not yet posted)
  assert.equal(data.alerts.x_bad.clearPending, true);
  const again = W.evaluate(data, failing, ran, NOW + 180000);           // fails again before the clear was posted
  assert.deepEqual(again.start.map(l => l.id), ['x_bad'], 'a new episode posts at once');
  assert.equal(data.alerts.x_bad.clearPending, false);
});
