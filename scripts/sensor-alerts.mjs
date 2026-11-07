// Per-sensor alerts for the 5-minute checker (scripts/watch.mjs, checkSensorAlerts and checkSensorDrops): a sensor outside its
// temperature limits for a set time, a sensor that stopped reporting while its hub is up, and readings the sensor bridge dropped.
// Pure functions plus the one query; docs/SENSORS.md ("Alerts") and docs/MONITORING.md describe the rules.
//
// Settings (config/compose.env, the facility's settings): WAREHOUSE_SENSOR_OUT_OF_RANGE_MINUTES (default 15) and
// WAREHOUSE_SENSOR_SILENT_MINUTES (default 30), whole minutes from 1 to 1440; anything else means the default.

export const DEFAULT_OUT_OF_RANGE_MINUTES = 15;
export const DEFAULT_SILENT_MINUTES = 30;

export function sensorAlertMinutes(env = {}) {
  const read = (name, fallback) => {
    const text = String(env[name] ?? '').trim();
    const n = /^\d{1,4}$/.test(text) ? Number(text) : NaN;
    return n >= 1 && n <= 1440 ? n : fallback;
  };
  return {
    outMinutes: read('WAREHOUSE_SENSOR_OUT_OF_RANGE_MINUTES', DEFAULT_OUT_OF_RANGE_MINUTES),
    silentMinutes: read('WAREHOUSE_SENSOR_SILENT_MINUTES', DEFAULT_SILENT_MINUTES),
  };
}

// One answer from the database: each active sensor that has reported, with its limits (null when not set), the age of its last
// reading, its hub's state, and (only for a sensor with a limit) its newest 500 temperatures of the last 2 days, newest first.
// Ages are computed by the database, so a skewed host clock does not matter.
export const SENSOR_ALERTS_SQL = "SELECT coalesce(json_agg(json_build_object('id', d.id, 'name', d.device_name, 'location', d.location, "
  + "'lo', CASE WHEN jsonb_typeof(d.alert_config -> 'temperature_min') = 'number' THEN (d.alert_config ->> 'temperature_min')::numeric END, "
  + "'hi', CASE WHEN jsonb_typeof(d.alert_config -> 'temperature_max') = 'number' THEN (d.alert_config ->> 'temperature_max')::numeric END, "
  + "'reading_age_s', greatest(0, extract(epoch FROM now() - d.last_reading_at))::bigint, "
  + "'hub_online', h.online, 'hub_age_s', greatest(0, extract(epoch FROM now() - h.last_seen_at))::bigint, "
  + "'readings', CASE WHEN jsonb_typeof(d.alert_config -> 'temperature_min') = 'number' OR jsonb_typeof(d.alert_config -> 'temperature_max') = 'number' "
  + "THEN coalesce((SELECT json_agg(json_build_object('t', x.temperature, 'age_s', greatest(0, extract(epoch FROM now() - x.measured_at))::bigint) ORDER BY x.measured_at DESC) "
  + "FROM (SELECT r.temperature, r.measured_at FROM public.sensor_readings r WHERE r.device_id = d.id AND r.temperature IS NOT NULL "
  + "AND r.recorded_at > now() - interval '2 days' ORDER BY r.recorded_at DESC LIMIT 500) x), '[]'::json) ELSE '[]'::json END) "
  + "ORDER BY d.device_name, d.id), '[]'::json) FROM public.sensor_devices d LEFT JOIN public.sensor_hubs h ON h.hub_id = d.hub_id "
  + "WHERE d.active AND d.last_reading_at IS NOT NULL";

// Replays the readings (oldest first) as a state machine. Out of range for outS seconds raises the alert; back inside for outS
// seconds clears it; a short stretch inside does not clear it, and a short one outside does not raise it.
// `readings` is newest first, [{ t, age_s }]. Returns { raised, outSinceAge, newest } where outSinceAge is the age of the first
// reading of the current stretch outside the limits (null when none).
export function rangeState(readings, lo, hi, outS) {
  const isOut = t => (lo != null && t < lo) || (hi != null && t > hi);
  let raised = false;
  let outSince = null;   // age of the first out-of-range reading of the stretch
  let inSince = null;    // age of the first in-range reading after a raised stretch
  for (let i = readings.length - 1; i >= 0; i--) {
    const { t, age_s: age } = readings[i];
    if (isOut(Number(t))) {
      inSince = null;
      outSince ??= age;
      if (outSince - age >= outS) raised = true;
    } else if (raised) {
      inSince ??= age;
      if (inSince - age >= outS) { raised = false; outSince = null; inSince = null; }
    } else outSince = null;
  }
  // The stretch still running at this moment counts up to now.
  if (outSince !== null && !raised && inSince === null && readings.length && isOut(Number(readings[0].t)) && outSince >= outS) raised = true;
  if (raised && inSince !== null && inSince >= outS) { raised = false; outSince = null; }
  return { raised, outSinceAge: outSince, newest: readings[0] ?? null };
}

const stamp = (nowMs, ageS) => `${new Date(nowMs - ageS * 1000).toISOString().slice(0, 16).replace('T', ' ')} UTC`;
const label = d => `${d.name}${d.location ? ` (${d.location})` : ''}`;

// The failing alerts for the sensors: [{ id, summary, detail, repeatHours }]. A sensor not listed is fine (its alert, if any,
// clears). `limitSeconds` is the checker's reading limit (scripts/sensors-check.mjs): a hub not heard from within it is down, and the
// existing sensors_stale alert says so, so its sensors raise no silence alert of their own.
export function sensorAlerts({ devices, nowMs, outMinutes, silentMinutes, limitSeconds }) {
  const out = [];
  const once = 24 * 365;   // "posts once": a repeat a year later is the practical meaning
  for (const d of devices) {
    const lo = d.lo ?? null, hi = d.hi ?? null;
    if (lo !== null || hi !== null) {
      const s = rangeState(d.readings ?? [], lo === null ? null : Number(lo), hi === null ? null : Number(hi), outMinutes * 60);
      if (s.raised && s.newest) {
        const t = Number(s.newest.t);
        const where = hi !== null && t > Number(hi) ? `above its highest limit ${hi} C` : lo !== null && t < Number(lo) ? `below its lowest limit ${lo} C`
          : `back inside its limits (${lo ?? 'none'} to ${hi ?? 'none'} C) for less than ${outMinutes} minutes`;
        out.push({ id: `sensor_range:${d.id}`, repeatHours: once,
          summary: `Temperature alarm: ${label(d)} reads ${t} C, ${where}`,
          detail: `Outside its limits since ${stamp(nowMs, s.outSinceAge ?? s.newest.age_s)}; newest reading ${t} C at ${stamp(nowMs, s.newest.age_s)}. Limits ${lo ?? 'none'} to ${hi ?? 'none'} C; alerts after ${outMinutes} minutes outside, clears after ${outMinutes} minutes inside.` });
      }
    }
    const hubUp = d.hub_online === true && Number(d.hub_age_s) <= limitSeconds;
    if (hubUp && Number(d.reading_age_s) >= silentMinutes * 60) {
      out.push({ id: `sensor_silent:${d.id}`, repeatHours: once,
        summary: `Sensor silent: ${label(d)} sent no reading for ${Math.round(Number(d.reading_age_s) / 60)} minutes`,
        detail: `Last reading at ${stamp(nowMs, Number(d.reading_age_s))}; its hub is online. Alerts after ${silentMinutes} minutes; check the sensor's battery and distance from the hub, or set it inactive in the app if it was removed.` });
    }
  }
  return out;
}

// The bridge logs `event=readings_dropped reason=<reason> hub=<id> dropped=<n>` for each batch it drops (docker/sensor-bridge).
// Returns { total, byReason } over the given log text.
export function droppedFromLog(text) {
  const byReason = {};
  let total = 0;
  for (const m of String(text ?? '').matchAll(/event=readings_dropped reason=(\S+) hub=\S+ dropped=(\d+)/g)) {
    const n = Number(m[2]);
    byReason[m[1]] = (byReason[m[1]] ?? 0) + n;
    total += n;
  }
  return { total, byReason };
}

export function droppedSummary({ total, byReason }) {
  const parts = Object.entries(byReason).map(([reason, n]) => `${n} ${reason.replace(/_/g, ' ')}`);
  return `Sensor bridge dropped ${total} reading${total === 1 ? '' : 's'} in the last 24 hours (${parts.join('; ')})`;
}
