// The doctor's sensor check (scripts/sensors-check.mjs): a fake psql answer stands in for the database, a fake Compose answer for the container.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { DEFAULT_SENSOR_LIMIT_S, SENSORS_SQL, ageText, bridgeState, sensorLimitSeconds, sensorProblems, sensorReport } from '../scripts/sensors-check.mjs';

const DAY = 86400;
const db = answer => args => { db.last = args; return { ok: true, output: `${JSON.stringify(answer)}\n` }; };
const hub = (host, online, age_s, change_age_s = age_s) => ({ hub_id: host, host, online, age_s, change_age_s });

test('sensors: healthy hubs and a recent reading give no warning', () => {
  assert.deepEqual(sensorProblems({ run: db({ hubs: [hub('192.0.2.10', true, 40), hub('192.0.2.11', true, 200)], newest_age_s: 120 }), bridge: 'running' }), []);
});

test('sensors: an offline hub is named with how long it has been offline (last_change_at), not when the bridge last reported it', () => {
  const [text, ...rest] = sensorProblems({ run: db({ hubs: [hub('192.0.2.10', false, 180, 5 * DAY)], newest_age_s: 5 * DAY }), bridge: 'running' });
  assert.equal(rest.length, 0);
  assert.equal(text, 'Sensors: hub 192.0.2.10 offline for 5 days; newest reading 5 days ago (limit 16 minutes). See docs/SENSORS.md, Troubleshooting.');
});

test('sensors: an online hub that is not refreshed is silent, with the log commands; only the faulty hub is named', () => {
  const problems = sensorProblems({ run: db({ hubs: [hub('192.0.2.10', true, 7200), hub('192.0.2.11', true, 30)], newest_age_s: 30 }), bridge: 'running' });
  assert.equal(problems.length, 1);
  assert.match(problems[0], /hub 192\.0\.2\.10 silent, last report 2 hours ago; the bridge has not posted for it/);
  assert.match(problems[0], /logs --tail 100 sensor-bridge/);
  assert.match(problems[0], /own Compose project: docker compose logs/);
});

test('sensors: a hub is named host (hub_id) when they differ, by its id without a host', () => {
  const named = sensorProblems({ run: db({ hubs: [{ hub_id: 'ABC123', host: '192.0.2.12', online: false, age_s: 10, change_age_s: 7200 }], newest_age_s: 10 }), bridge: 'running' });
  assert.match(named[0], /hub 192\.0\.2\.12 \(ABC123\) offline for 2 hours/);
  const [text] = sensorProblems({ run: db({ hubs: [{ hub_id: 'ABC123', host: null, online: false, age_s: 10, change_age_s: 7200 }], newest_age_s: 10 }), bridge: 'running' });
  assert.match(text, /hub ABC123 offline/);
});

test('sensors: hubs that report but an old reading is a warning that says to wait after a start', () => {
  const [text] = sensorProblems({ run: db({ hubs: [hub('192.0.2.10', true, 30)], newest_age_s: 3 * 3600 }), bridge: 'running' });
  assert.match(text, /hubs report, but newest reading 3 hours ago \(limit 16 minutes\); just started\? run the doctor again in 15 minutes/);
});

test('sensors: no reading stored yet warns (a null age is not 0); a future-dated reading is not an error', () => {
  const [text] = sensorProblems({ run: db({ hubs: [hub('192.0.2.10', true, 30)], newest_age_s: null }), bridge: 'running' });
  assert.match(text, /no reading stored yet/);
  assert.deepEqual(sensorProblems({ run: db({ hubs: [hub('192.0.2.10', true, 30)], newest_age_s: -240 }), bridge: 'running' }), []);
});

test('sensors: no hub row at all warns and points at SENSOR_BRIDGE_HUBS and the log', () => {
  const [text] = sensorProblems({ run: db({ hubs: [], newest_age_s: null }), bridge: 'running' });
  assert.match(text, /no hub has ever reported/);
  assert.match(text, /SENSOR_BRIDGE_HUBS/);
  assert.match(text, /logs --tail 100 sensor-bridge/);
});

test('sensors: a missing container warns only when asked about (SENSOR_BRIDGE_HUBS set); an existing or unknown one is not judged here', () => {
  const ok = db({ hubs: [hub('192.0.2.10', true, 10)], newest_age_s: 10 });
  const [text] = sensorProblems({ run: ok, bridge: '' });
  assert.equal(text, 'Sensors: SENSOR_BRIDGE_HUBS is set in config/compose.env but no sensor-bridge container exists, so no readings arrive. Start it with: bash scripts/compose.sh --profile sensors up -d --wait sensor-bridge. (A bridge run as its own Compose project needs SENSOR_BRIDGE_HUBS empty here.) See docs/SENSORS.md, Troubleshooting.');
  assert.deepEqual(sensorProblems({ run: ok, bridge: 'exited' }), []);
  assert.deepEqual(sensorProblems({ run: ok, bridge: null }), []);
});

test('sensors: sensorReport asks Compose only when SENSOR_BRIDGE_HUBS is set; with it empty the data alone is judged', () => {
  const ok = db({ hubs: [hub('192.0.2.10', true, 10)], newest_age_s: 10 });
  const asked = [];
  const compose = args => { asked.push(args); return { ok: true, output: '' }; };
  const standalone = sensorReport({ env: { SENSOR_BRIDGE_HUBS: '' }, db: ok, compose });
  assert.deepEqual(standalone, []);
  assert.equal(asked.length, 0);
  const profile = sensorReport({ env: { SENSOR_BRIDGE_HUBS: '192.0.2.10' }, db: ok, compose });
  assert.equal(asked.length, 1);
  assert.deepEqual(asked[0], ['--profile', 'sensors', 'ps', '-a', '--format', 'json', 'sensor-bridge']);
  assert.match(profile[0], /no sensor-bridge container exists/);
  // the environment's settings reach the limit: a reading 20 minutes old is fine under a raised heartbeat
  const old = db({ hubs: [hub('192.0.2.10', true, 10)], newest_age_s: 1200 });
  assert.equal(sensorReport({ env: {}, db: old, compose }).length, 1);
  assert.equal(sensorReport({ env: { SENSOR_BRIDGE_HEARTBEAT_SECONDS: '900' }, db: old, compose }).length, 0);
});

test('sensors: an unreadable database answer is a warning that says so, not a pass', () => {
  for (const run of [() => ({ ok: false, output: '' }), () => ({ ok: true, output: 'garbage' }), () => ({ ok: true, output: '{}' })]) {
    const problems = sensorProblems({ run, bridge: 'running' });
    assert.equal(problems.length, 1);
    assert.match(problems[0], /could not read sensor_hubs/);
  }
});

test('sensors: the limit is 3 x the larger of heartbeat and poll, plus the post interval, and never below the 16 minute default', () => {
  assert.equal(DEFAULT_SENSOR_LIMIT_S, 960);
  assert.equal(sensorLimitSeconds({}), 960);
  assert.equal(sensorLimitSeconds({ SENSOR_BRIDGE_HEARTBEAT_SECONDS: '300', SENSOR_BRIDGE_POLL_SECONDS: '300', SENSOR_BRIDGE_POST_SECONDS: '60' }), 960);
  assert.equal(sensorLimitSeconds({ SENSOR_BRIDGE_HEARTBEAT_SECONDS: '900' }), 2760);
  assert.equal(sensorLimitSeconds({ SENSOR_BRIDGE_POLL_SECONDS: '600', SENSOR_BRIDGE_POST_SECONDS: '120' }), 1920);
  assert.equal(sensorLimitSeconds({ SENSOR_BRIDGE_HEARTBEAT_SECONDS: 'x' }), 960);
  assert.equal(sensorLimitSeconds({ SENSOR_BRIDGE_HEARTBEAT_SECONDS: '60', SENSOR_BRIDGE_POLL_SECONDS: '60', SENSOR_BRIDGE_POST_SECONDS: '10' }), 960);
});

test('sensors: ages read as minutes, hours and days', () => {
  assert.equal(ageText(30), '30 seconds');
  assert.equal(ageText(960), '16 minutes');
  assert.equal(ageText(7200), '2 hours');
  assert.equal(ageText(5 * DAY), '5 days');
  assert.equal(ageText(DAY), '24 hours');
});

test('sensors: the query reads sensor_hubs and sensor_readings through the db container as supabase_admin; the reading age is not wrapped in greatest()', () => {
  sensorProblems({ run: db({ hubs: [], newest_age_s: null }), bridge: 'running' });
  assert.ok(db.last.includes('supabase_admin') && db.last.includes(SENSORS_SQL));
  assert.match(SENSORS_SQL, /public\.sensor_hubs/);
  assert.match(SENSORS_SQL, /max\(measured_at\)/);
  assert.match(SENSORS_SQL, /last_seen_at/);
  assert.match(SENSORS_SQL, /last_change_at/);
  assert.doesNotMatch(SENSORS_SQL, /greatest\(0, extract\(epoch FROM now\(\) - max/);
});

test('sensors: tests/sensors_doctor_query.sql runs the exact SENSORS_SQL text and is registered in migrations.sh', () => {
  const sql = readFileSync(new URL('./sensors_doctor_query.sql', import.meta.url), 'utf8');
  assert.ok(sql.includes(`${SENSORS_SQL} AS `), 'the SQL test must hold SENSORS_SQL verbatim');
  assert.match(readFileSync(new URL('./migrations.sh', import.meta.url), 'utf8'), /tests\/sensors_doctor_query\.sql/);
});

test('sensors: the bridge state is read from either Compose json shape; no container is an empty state', () => {
  const out = output => () => ({ ok: true, output });
  assert.equal(bridgeState(out('{"Name":"x-sensor-bridge-1","State":"running"}\n')), 'running');
  assert.equal(bridgeState(out('[{"State":"exited"}]')), 'exited');
  assert.equal(bridgeState(out('')), '');
  assert.equal(bridgeState(() => ({ ok: false, output: '' })), null);
  assert.equal(bridgeState(out('not json')), null);
});

// doctor() reads the real host (Docker, state directory), so it has no injection point; the wiring is read from its text.
test('doctor runs the sensor check only while the sensors capability is on, with compose.env, as a warning', () => {
  const doctor = readFileSync(new URL('../scripts/doctor.mjs', import.meta.url), 'utf8');
  assert.match(doctor, /manifest\?\.capabilities\?\.sensors === true\s*\?\s*sensorReport\(\{ env, db: inDb, compose: /);
  assert.match(doctor, /sensorReport\([^\n]*\.map\(text => `\\nWarning: \$\{text\}`\)/);
  assert.match(doctor, /numberingWarnings \+ sensorWarnings/);
});
