// The doctor's sensor check (`node scripts/doctor.mjs`, also --local): when the `sensors` capability is on, readings must reach the
// database. A bridge container can be "healthy" while it polls hub addresses that no longer exist (hubs get new DHCP addresses), so
// nothing but the data says whether sensors work. Every result is a WARNING, never a failure: a hub outage must not stop a setup,
// start, upgrade or restore (they end with `doctor --local`). docs/SENSORS.md ("Check that readings arrive") describes it.

// With the default SENSOR_BRIDGE_HEARTBEAT_SECONDS=300 every sensor gets a stored row (change or heartbeat) about every 5 minutes, and
// each hub row is refreshed by every post. The limit is three of those intervals plus one post interval (the queue is sent every
// SENSOR_BRIDGE_POST_SECONDS, default 60): 3 x 300 + 60 = 16 minutes with the defaults. A restart or a failed poll or two stays quiet.
// A larger heartbeat, poll or post setting in compose.env scales it: 3 x the larger of heartbeat and poll, plus the post interval.
const DEFAULTS = { SENSOR_BRIDGE_HEARTBEAT_SECONDS: 300, SENSOR_BRIDGE_POLL_SECONDS: 300, SENSOR_BRIDGE_POST_SECONDS: 60 };
export const DEFAULT_SENSOR_LIMIT_S = 3 * 300 + 60;
export function sensorLimitSeconds(env = {}) {
  const seconds = name => { const n = Number(env[name]); return Number.isFinite(n) && n > 0 ? n : DEFAULTS[name]; };
  return Math.max(DEFAULT_SENSOR_LIMIT_S, 3 * Math.max(seconds('SENSOR_BRIDGE_HEARTBEAT_SECONDS'), seconds('SENSOR_BRIDGE_POLL_SECONDS')) + seconds('SENSOR_BRIDGE_POST_SECONDS'));
}

// One answer from the database: each hub's online flag, the age of last_seen_at (its newest post) and of last_change_at (when the online
// flag last flipped), and the age of the newest stored reading. Ages are computed by the database, so a skewed host clock does not
// matter. The reading age is NULL when no reading exists (not 0: GREATEST would hide the NULL) and may be negative (the ingest
// function accepts times up to 5 minutes ahead), so it is clamped in JS. tests/sensors_doctor_query.sql runs this exact text.
export const SENSORS_SQL = "SELECT json_build_object('hubs', coalesce((SELECT json_agg(json_build_object('hub_id', hub_id, 'host', host, 'online', online, "
  + "'age_s', greatest(0, extract(epoch FROM now() - last_seen_at))::bigint, 'change_age_s', greatest(0, extract(epoch FROM now() - last_change_at))::bigint) "
  + "ORDER BY host, hub_id) FROM public.sensor_hubs), '[]'::json), "
  + "'newest_age_s', (SELECT extract(epoch FROM now() - max(measured_at))::bigint FROM public.sensor_readings))";

export function ageText(seconds) {
  const s = Math.max(0, Math.round(seconds));
  if (s < 90) return `${s} second${s === 1 ? '' : 's'}`;
  const plural = (n, unit) => `${n} ${unit}${n === 1 ? '' : 's'}`;
  if (s < 5400) return plural(Math.round(s / 60), 'minute');
  if (s < 129600) return plural(Math.round(s / 3600), 'hour');
  return plural(Math.round(s / 86400), 'day');
}

const SEE = 'See docs/SENSORS.md, Troubleshooting.';
const LOGS = 'bash scripts/compose.sh --profile sensors logs --tail 100 sensor-bridge';
const LOGS_HINT = `${LOGS} (a bridge run as its own Compose project: docker compose logs in its folder)`;
const START = 'bash scripts/compose.sh --profile sensors up -d --wait sensor-bridge';

// A hub is named by its host, and as `host (hub_id)` when the two differ.
const hubName = hub => (hub.host && hub.host !== hub.hub_id ? `${hub.host} (${hub.hub_id})` : (hub.host || hub.hub_id));

// `bridge` is the state of the sensor-bridge container, asked only when SENSOR_BRIDGE_HUBS is set in compose.env (the bridge is then
// meant to run in this Compose project): 'running' or another state, '' when no container exists, null when it was not asked or
// Compose could not be asked (then it is not judged). Only "does not exist" is judged here; an existing exited or unhealthy
// container is reported by the health check (scripts/watch.mjs, OPTIONAL_SERVICES). A bridge run as its own Compose project
// (docs/SENSORS.md) leaves SENSOR_BRIDGE_HUBS empty here and is judged by the data alone.
// `run` takes the psql arguments after `compose.sh exec -T db`. Returns the warnings (an empty list when all is well).
export function sensorProblems({ run, bridge = null, limitSeconds = DEFAULT_SENSOR_LIMIT_S }) {
  const limit = `limit ${ageText(limitSeconds)}`;
  const problems = [];
  if (bridge === '') {
    problems.push(`Sensors: SENSOR_BRIDGE_HUBS is set in config/compose.env but no sensor-bridge container exists, so no readings arrive. Start it with: ${START}. (A bridge run as its own Compose project needs SENSOR_BRIDGE_HUBS empty here.) ${SEE}`);
  }
  const answer = run(['psql', '-X', '-qAt', '-v', 'ON_ERROR_STOP=1', '-U', 'supabase_admin', '-d', 'postgres', '-c', SENSORS_SQL]);
  let found;
  try { found = answer.ok ? JSON.parse(answer.output.trim()) : null; } catch { found = null; }
  if (!found || !Array.isArray(found.hubs)) {
    problems.push(`Sensors: could not read sensor_hubs and sensor_readings from the database, so whether readings arrive is not known. Run node scripts/doctor.mjs --local again. ${SEE}`);
    return problems;
  }
  const newest = found.newest_age_s == null ? null : Math.max(0, Number(found.newest_age_s));
  const newestText = newest == null ? 'no reading stored yet' : `newest reading ${ageText(newest)} ago`;
  const readingStale = newest == null || newest > limitSeconds;
  if (!found.hubs.length) {
    problems.push(`Sensors: the capability is on but no hub has ever reported (sensor_hubs is empty); ${newestText} (${limit}). Check SENSOR_BRIDGE_HUBS and the key in config/compose.env, and the bridge log: ${LOGS_HINT}. ${SEE}`);
    return problems;
  }
  let hubFault = false;
  for (const hub of found.hubs) {
    const stale = Number(hub.age_s) > limitSeconds;
    if (hub.online && !stale) continue;
    hubFault = true;
    // An unreachable hub is re-sent offline with every heartbeat, so its last_seen_at stays fresh; how long it has been offline is
    // last_change_at. An online hub that is not refreshed has not been posted for at all.
    problems.push(hub.online
      ? `Sensors: hub ${hubName(hub)} silent, last report ${ageText(Number(hub.age_s))} ago; the bridge has not posted for it, check the bridge log: ${LOGS_HINT}; ${newestText} (${limit}). ${SEE}`
      : `Sensors: hub ${hubName(hub)} offline for ${ageText(Number(hub.change_age_s))}; ${newestText} (${limit}). ${SEE}`);
  }
  if (readingStale && !hubFault) {
    problems.push(`Sensors: hubs report, but ${newestText} (${limit}); just started? run the doctor again in 15 minutes. ${SEE}`);
  }
  return problems;
}

// The doctor's whole sensor check. `env` is config/compose.env; `db` runs a command in the db container; `compose` runs Compose
// with the given arguments. The container is asked about only when SENSOR_BRIDGE_HUBS is set.
export function sensorReport({ env, db, compose }) {
  const hubsSet = String(env.SENSOR_BRIDGE_HUBS ?? '').trim() !== '';
  return sensorProblems({ run: db, bridge: hubsSet ? bridgeState(compose) : null, limitSeconds: sensorLimitSeconds(env) });
}

// The state of the sensor-bridge container as Compose reports it ('' when none exists, null when Compose could not be asked).
// `docker compose ps --format json` prints one object per line, or an array, depending on the plugin version.
export function bridgeState(run) {
  const answer = run(['--profile', 'sensors', 'ps', '-a', '--format', 'json', 'sensor-bridge']);
  if (!answer.ok) return null;
  const text = answer.output.trim();
  if (!text) return '';
  try {
    const parsed = text.startsWith('[') ? JSON.parse(text) : text.split('\n').map(line => JSON.parse(line));
    return String(parsed[0]?.State ?? '') || '';
  } catch { return null; }
}
