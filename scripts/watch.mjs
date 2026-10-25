// The one monitoring check of an installation (replaces Prometheus, Alertmanager and the exporters).
//
//   node scripts/watch.mjs run                      one pass: checks, alerts, heartbeat (the systemd timer runs this every 5 minutes)
//   node scripts/watch.mjs daily                    the daily backup, verification, pruning and retention (its own systemd timer runs this)
//   node scripts/watch.mjs test-message             post a test message to the facility's Slack webhook
//   node scripts/watch.mjs status                   what is failing, muted, and when the daily jobs last ran
//   node scripts/watch.mjs mute MINUTES ["ALERT"]   silence all alerts, or one alert id, for MINUTES
//   node scripts/watch.mjs unmute ["ALERT"]
//   node scripts/watch.mjs health [--wait SECONDS]  the operator health check (health-check.sh, doctor --local, recovery-check.sh)
//
// Reads WAREHOUSE_STATE_DIR. scripts/watch-timer.sh installs the timer. docs/MONITORING.md describes the alerts.
//
// Rules: an alert fires after two failing runs in a row (some event alerts at once); it is posted once when it
// starts, again every 4 hours while it keeps firing, and once when it clears. One "monitoring is alive" message a
// calendar day, after 09:00 local time. A run's new alerts go out as one message. A check that throws counts as
// failing. The run exits 0 unless the state file cannot be written. Nothing here prints or posts a secret: all text
// goes through redact().
//
// Daily jobs (`daily`, not `run`: a backup must not hold the 5-minute checks off): once a day, between --daily-at and 6
// hours later (local time), scripts/watch-daily.sh makes a backup, verifies it, prunes older backups and applies
// retention under one operator lock. They run only when the database and the services the backup stops are up; a failed
// pass is tried again after an hour, at most 3 times a day. The daily timer fires at --daily-at and each of the 5 hours
// after it, and a trigger with nothing to do exits at once. `run` and `daily` write different keys of the state file.
// Pruning keeps the newest 7 backup directories of this installation in $STATE/backups; backups made by hand there
// (same name pattern, same instance) count towards those 7.
// External heartbeat: if config/heartbeat-url holds an https URL (mode 0600), every successful run of `run` fetches it
// (5 s limit). A service such as healthchecks.io alerts when the pings stop; a failed ping is logged, never alerted.
// Self-healing: while no operator command holds the lock, an `exited` service of the default profile is started again and
// one `unhealthy` for 3 runs in a row is restarted, at most once an hour each (selfHeal); a muted service is left alone.
// Mute before a deliberate stop.sh: a stopped service is an alert like any other.
import { spawn, spawnSync } from 'node:child_process';
import { closeSync, fsyncSync, lstatSync, openSync, readdirSync, readFileSync, renameSync, rmSync, statSync, statfsSync, unlinkSync, writeSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { isMain } from './is-main.mjs';
import { centralKeyFault, letterheadProblem, readEnv, root as checkoutRoot } from './doctor-common.mjs';
import { redactServiceLog } from './service-diagnostics.mjs';
import { usbBackupWarning } from './usb-backup-status.mjs';
import { postSlackMessage, storedWebhook, testMessage } from './alert-webhook.mjs';

const MIN = 60 * 1000;
const HOUR = 60 * MIN;
// Thresholds are those of the Prometheus alert rules this checker replaced (docs/MONITORING.md lists them).
export const LIMITS = {
  cpuPercent: 80, memoryPercent: 85, diskRootFreePercent: 20, diskOtherFreePercent: 10,
  dbConnections: 80, txSeconds: 300, cacheHitRatio: 0.9, cacheMinBlocks: 10000, deadTuples: 100000,
  containerMemoryRatio: 0.9, restartsPerHour: 3, oomHoldMs: HOUR,
  errorRate: 0.05, latencySeconds: 2, minRequests: 10, backupMaxAgeMs: 26 * HOUR,
  failingRuns: 2, repeatMs: 4 * HOUR, busyGiveUpMs: 2 * HOUR, keepBackups: 7,
  // A daily pass in progress older than this is taken as interrupted (the unit stops after 4 h).
  jobStaleMs: 4 * HOUR, dailyWindowMs: 6 * HOUR, dailyAttempts: 3,
  // "An hour" less 2 minutes: the daily timer fires on the hour, and a start a few seconds late must not push a retry
  // to the trigger after.
  dailyRetryMs: HOUR - 2 * MIN, dailyHardMs: 3 * HOUR + 45 * MIN,
  futureBackupMs: HOUR,
  // Self-healing: a service unhealthy in this many runs in a row is restarted; no service is acted on more than once per gap.
  healUnhealthyRuns: 3, healGapMs: HOUR,
};
export const OPTIONAL_SERVICES = ['supavisor', 'cups', 'sensor-bridge'];
export const BACKUP_DIR_PATTERN = /^warehouse-\d{8}T\d{6}Z$/;
const TIME_OF_DAY = /^([01]\d|2[0-3]):([0-5]\d)$/;
const DEFAULT_DAILY_AT = '02:30';
const DEFAULT_HEARTBEAT_AT = '09:00';
const ALERT_ID = /^[a-z_]+(:[\w/. -]+)?$/;

// ---------------------------------------------------------------- redaction
export function redact(text, env = {}, webhook = null) {
  let out = redactServiceLog(String(text ?? ''), env);
  if (webhook) out = out.split(webhook).join('[REDACTED]');
  return out.replace(/https:\/\/hooks\.slack\.com\/services\/[A-Za-z0-9/]+/g, '[REDACTED]');
}
const clip = (text, n = 300) => (text.length > n ? `${text.slice(0, n)}...` : text);

// ---------------------------------------------------------------- state
const isNum = v => typeof v === 'number' && Number.isFinite(v);
const isObj = v => v !== null && typeof v === 'object' && !Array.isArray(v);
const numOrNull = v => v === null || isNum(v);
export const statePath = state => join(state, 'config/watch-state.json');
export const mutesPath = state => join(state, 'config/watch-mutes.json');
export const freshState = now => ({
  version: 1, firstRun: now, alerts: {}, containers: {}, cpu: null, lastRunAt: null, lastHeartbeat: null,
  lastDailyRun: {}, dailyAttempt: null, dailyRunning: null, dailySkipped: null, busySince: null, lastPostError: null,
  memoryNote: null, heal: {},
  // Mutes live in their own file (loadMutes) and are filled in from it; they are never part of the run state.
  muteUntil: null, mutes: {},
});

function normalizeAlert(id, raw, log) {
  const a = isObj(raw) ? raw : {};
  const fix = (key, ok, fallback) => {
    if (ok(a[key])) return a[key];
    if (key in a) log(`alert "${id}": field "${key}" had the wrong type and was reset`);
    return fallback;
  };
  const text = v => typeof v === 'string';
  const out = {
    failingRuns: fix('failingRuns', isNum, 0), firingSince: fix('firingSince', numOrNull, null), lastSent: fix('lastSent', numOrNull, null),
    clearPending: fix('clearPending', v => typeof v === 'boolean', false),
    check: fix('check', text, ''), summary: fix('summary', text, ''), detail: fix('detail', text, ''),
  };
  if (!isObj(raw)) log(`alert "${id}" was not an object and was reset`);
  return out;
}
function normalizeContainer(service, raw, log) {
  const ok = isObj(raw) && isNum(raw.restartCount) && typeof raw.startedAt === 'string' && Array.isArray(raw.events) && raw.events.every(isNum)
    && numOrNull(raw.oomKill ?? null) && numOrNull(raw.lastOom ?? null) && numOrNull(raw.lastOomEvent ?? null);
  if (!ok) log(`container "${service}": history had the wrong shape and was reset`);
  return ok ? raw : null;
}

// Keeps every field that has the right type and resets the others (logging each reset through log).
export function normalizeState(raw, now, log = () => {}) {
  const out = freshState(now);
  if (!isObj(raw)) { log('the state file is not a JSON object; starting fresh'); return out; }
  const take = (key, ok) => {
    if (!(key in raw)) return;
    if (ok(raw[key])) out[key] = raw[key]; else log(`state field "${key}" had the wrong type and was reset`);
  };
  take('firstRun', isNum);
  for (const key of ['lastRunAt', 'lastHeartbeat', 'busySince']) take(key, numOrNull);
  take('cpu', v => v === null || (isObj(v) && isNum(v.total) && isNum(v.idle) && isNum(v.at)));
  take('dailyRunning', v => v === null || (isObj(v) && isNum(v.startedAt)));
  take('dailySkipped', v => v === null || (isObj(v) && isNum(v.at)));
  take('dailyAttempt', v => v === null || (isObj(v) && typeof v.date === 'string' && isNum(v.count) && numOrNull(v.lastAt) && typeof v.done === 'boolean'));
  take('lastPostError', v => v === null || (isObj(v) && isNum(v.at) && typeof v.message === 'string'));
  take('memoryNote', v => v === null || typeof v === 'string');
  take('heal', v => isObj(v) && Object.values(v).every(x => isObj(x) && isNum(x.unhealthyRuns) && numOrNull(x.lastAt) && typeof x.lastAction === 'string'));
  take('lastDailyRun', v => isObj(v) && Object.values(v).every(x => isObj(x) && typeof x.date === 'string' && typeof x.result === 'string'));
  if (isObj(raw.alerts)) for (const [id, a] of Object.entries(raw.alerts)) out.alerts[id] = normalizeAlert(id, a, log);
  else if ('alerts' in raw) log('state field "alerts" had the wrong type and was reset');
  if (isObj(raw.containers)) {
    for (const [service, c] of Object.entries(raw.containers)) { const fixed = normalizeContainer(service, c, log); if (fixed) out.containers[service] = fixed; }
  } else if ('containers' in raw) log('state field "containers" had the wrong type and was reset');
  return out;
}

const readFileOrNull = path => { try { return readFileSync(path, 'utf8'); } catch { return null; } };
const stderrLog = message => process.stderr.write(`Watch: ${message}\n`);
export function loadState(state, now, readText = readFileOrNull, log = stderrLog) {
  const text = readText(statePath(state));
  if (text === null) return freshState(now);
  try { return normalizeState(JSON.parse(text), now, log); } catch { log('the state file is not valid JSON; starting fresh'); return freshState(now); }
}

// Temporary file in the same directory, mode 0600, flushed, then renamed over the old file.
export function writeFileAtomic(path, text, api = { openSync, writeSync, fsyncSync, closeSync, renameSync, unlinkSync }) {
  const tmp = `${path}.${process.pid}.tmp`;
  let fd;
  try {
    fd = api.openSync(tmp, 'w', 0o600);
    api.writeSync(fd, text);
    api.fsyncSync(fd);
    api.closeSync(fd); fd = undefined;
    api.renameSync(tmp, path);
  } catch (error) {
    if (fd !== undefined) { try { api.closeSync(fd); } catch { /* already closed */ } }
    try { api.unlinkSync(tmp); } catch { /* nothing to remove */ }
    throw error;
  }
}
// Two processes write this file: the 5-minute checker (`run`) and the daily pass (`daily`, hours long). Each owns its keys
// and, when it saves, takes the other's from the file as it is then, so neither undoes what the other wrote meanwhile.
export const DAILY_KEYS = ['lastDailyRun', 'dailyAttempt', 'dailyRunning', 'dailySkipped'];
export function saveState(state, data, api, { daily = false, readText = readFileOrNull } = {}) {
  const { muteUntil, mutes, ...persisted } = data;
  const onDisk = readText(statePath(state));
  if (onDisk !== null) {
    try {
      const other = normalizeState(JSON.parse(onDisk), 0, () => {});
      for (const key of Object.keys(persisted)) if (DAILY_KEYS.includes(key) !== daily) persisted[key] = other[key];
    } catch { /* an unreadable file is replaced by ours */ }
  }
  writeFileAtomic(statePath(state), `${JSON.stringify(persisted, null, 2)}\n`, api);
}

// Mutes are changed by the mute command while a run is going, so they have a file of their own: a mute never
// rolls back the run state, and a run never overwrites a mute.
export function loadMutes(state, readText = readFileOrNull) {
  const empty = { muteUntil: null, mutes: {} };
  try {
    const json = JSON.parse(readText(mutesPath(state)) ?? 'null');
    if (!isObj(json)) return empty;
    const ids = isObj(json.ids) ? Object.fromEntries(Object.entries(json.ids).filter(([, until]) => isNum(until))) : {};
    return { muteUntil: isNum(json.all) ? json.all : null, mutes: ids };
  } catch { return empty; }
}
export function saveMutes(state, { muteUntil, mutes }, api) {
  writeFileAtomic(mutesPath(state), `${JSON.stringify({ all: muteUntil, ids: mutes }, null, 2)}\n`, api);
}

// ---------------------------------------------------------------- dependencies
// Runs a command in its own process group and, on a timeout, ends the whole group (TERM, then KILL after 2 minutes).
export function runGroup(command, args, { timeoutMs = 30000, env, killGraceMs = 2 * MIN } = {}) {
  return new Promise(done => {
    const child = spawn(command, args, { detached: true, stdio: ['ignore', 'pipe', 'pipe'], env: env ?? process.env });
    let stdout = '';
    let stderr = '';
    let timedOut = false;
    const tail = (text, chunk) => (text + chunk).slice(-65536);
    const signalGroup = signal => { try { process.kill(-child.pid, signal); } catch { /* already gone */ } };
    child.stdout.on('data', chunk => { stdout = tail(stdout, chunk); });
    child.stderr.on('data', chunk => { stderr = tail(stderr, chunk); });
    const kill = setTimeout(() => {
      timedOut = true;
      signalGroup('SIGTERM');
      setTimeout(() => signalGroup('SIGKILL'), killGraceMs).unref();
    }, timeoutMs);
    child.on('error', error => { clearTimeout(kill); done({ status: 127, stdout, stderr: String(error.message), timedOut }); });
    child.on('close', code => { clearTimeout(kill); done({ status: code ?? 1, stdout, stderr, timedOut }); });
  });
}

export function defaultDeps(env = process.env) {
  const state = env.WAREHOUSE_STATE_DIR;
  if (!state || !state.startsWith('/')) throw new Error('Set WAREHOUSE_STATE_DIR to the absolute installed operator state path.');
  return {
    state, root: checkoutRoot, env,
    now: () => Date.now(),
    run: (command, args, { timeoutMs = 30000, env: runEnv, input } = {}) => {
      const r = spawnSync(command, args, { encoding: 'utf8', timeout: timeoutMs, maxBuffer: 64 * 1024 * 1024, input, stdio: [input === undefined ? 'ignore' : 'pipe', 'pipe', 'pipe'], env: runEnv ?? process.env });
      return { status: r.status ?? (r.error ? 127 : 1), stdout: r.stdout ?? '', stderr: r.stderr ?? (r.error ? String(r.error.message) : '') };
    },
    runGroup,
    readText: readFileOrNull,
    statfs: path => statfsSync(path),
    fetch: (url, options) => fetch(url, options),
    post: (url, text) => postSlackMessage(url, text),
    proc: '/proc', cgroup: '/sys/fs/cgroup',
    usbEtc: env.WAREHOUSE_USB_BACKUP_ETC || '/etc',
    dailyAt: env.WAREHOUSE_WATCH_DAILY_AT || DEFAULT_DAILY_AT,
    heartbeatAt: env.WAREHOUSE_WATCH_HEARTBEAT_AT || DEFAULT_HEARTBEAT_AT,
  };
}

// The facility's Slack webhook, kept by setup.sh as config/slack-webhook-url (mode 0600); an install that setup has
// not rerun since the Alertmanager stack was removed still has it at the old path, which storedWebhook also reads.
// Null when none is stored (--alert-webhook-file off).
export function readWebhook(state) {
  try { return storedWebhook(state); } catch { return null; }
}

// ---------------------------------------------------------------- context
// `index` and not `.State.Health`: some docker CLIs run the template on the decoded JSON map and stop with
// "map has no entry for key Health" for a container without a healthcheck (seen on the CI runner).
const INSPECT_FORMAT = [
  '{{.Id}}', '{{index .Config.Labels "com.docker.compose.service"}}', '{{.State.Status}}',
  '{{with index .State "Health"}}{{index . "Status"}}{{end}}', '{{.RestartCount}}', '{{.State.OOMKilled}}', '{{.State.StartedAt}}',
  '{{index .Config.Labels "com.docker.compose.oneoff"}}',
].join('|');

export function makeContext(deps, data) {
  const ctx = { ...deps, data, memo: {} };
  ctx.env_ = () => (ctx.memo.env ??= (() => { try { return readEnv(join(deps.state, 'config/compose.env')); } catch { return {}; } })());
  ctx.compose = (args, opts) => deps.run('bash', [join(deps.root, 'scripts/compose.sh'), ...args], opts);
  // The services this installation's compose file runs by default (profile services are not expected).
  ctx.expectedServices = () => {
    if (ctx.memo.expected) return ctx.memo.expected;
    const r = ctx.compose(['config', '--services']);
    const names = r.stdout.split('\n').map(s => s.trim()).filter(s => /^[a-z0-9][a-z0-9_-]*$/.test(s));
    if (r.status !== 0 || !names.length) throw new Error(`compose config --services failed: ${clip(r.stderr.trim(), 200)}`);
    return (ctx.memo.expected = names);
  };
  // Every container of the project, profile services included; one-off containers (compose run) are left out.
  ctx.containers = () => {
    if (ctx.memo.containers) return ctx.memo.containers;
    const ps = ctx.compose(['--profile', '*', 'ps', '-a', '-q']);
    if (ps.status !== 0) throw new Error(`compose ps failed: ${clip(String(ps.stderr ?? '').trim(), 200)}`);
    const ids = ps.stdout.split('\n').map(s => s.trim()).filter(s => /^[a-f0-9]{12,64}$/.test(s));
    const list = [];
    if (ids.length) {
      const inspected = deps.run('docker', ['inspect', '--format', INSPECT_FORMAT, ...ids]);
      // A container removed between `ps` and `inspect` (a finished `compose run --rm`) only makes inspect
      // report "No such object" for that id; any other error fails the check.
      const stderr = String(inspected.stderr ?? '').trim();
      const otherErrors = stderr.split('\n').filter(l => l.trim() && !/No such (object|container)/i.test(l));
      if (inspected.status !== 0 && (otherErrors.length || !stderr)) {
        throw new Error(`docker inspect failed: ${clip(stderr, 200)}`);
      }
      for (const line of inspected.stdout.split('\n')) {
        const [id, service, status, health, restarts, oom, startedAt, oneoff] = line.trim().split('|');
        if (!id || !service || oneoff === 'True') continue;
        list.push({ id, service, status, health, restartCount: Number(restarts) || 0, oomKilled: oom === 'true', startedAt });
      }
    }
    return (ctx.memo.containers = list);
  };
  return ctx;
}
const result = (check, id, ok, summary, detail = '', extra = {}) => ({ check, id, ok, summary, detail, ...extra });

// ---------------------------------------------------------------- host
function parseCpu(text) {
  const line = String(text).split('\n').find(l => l.startsWith('cpu '));
  if (!line) throw new Error('no cpu line in /proc/stat');
  const n = line.trim().split(/\s+/).slice(1).map(Number);
  const total = n.slice(0, 8).reduce((a, b) => a + (b || 0), 0);
  return { total, idle: (n[3] || 0) + (n[4] || 0) };
}
export function checkCpu(ctx) {
  const sample = { ...parseCpu(ctx.readText(join(ctx.proc, 'stat'))), at: ctx.now() };
  const prev = ctx.data.cpu;
  ctx.data.cpu = sample;
  if (!prev || sample.at - prev.at > 30 * MIN || sample.at < prev.at || sample.total <= prev.total) {
    return [result('cpu', 'cpu_high', true, 'CPU usage normal')];
  }
  const busy = 100 * (1 - (sample.idle - prev.idle) / (sample.total - prev.total));
  return [result('cpu', 'cpu_high', !(busy > LIMITS.cpuPercent), `CPU usage ${busy.toFixed(0)}% (limit ${LIMITS.cpuPercent}%)`, 'Averaged since the previous run.')];
}
export function checkMemory(ctx) {
  const lines = String(ctx.readText(join(ctx.proc, 'meminfo'))).split('\n');
  const m = Object.fromEntries(lines.map(l => l.match(/^(\w+):\s+(\d+)/)).filter(Boolean).map(x => [x[1], Number(x[2])]));
  if (!m.MemTotal || m.MemAvailable === undefined) throw new Error('no MemTotal/MemAvailable in /proc/meminfo');
  const used = 100 * (1 - m.MemAvailable / m.MemTotal);
  return [result('memory', 'memory_high', !(used > LIMITS.memoryPercent), `Memory usage ${used.toFixed(0)}% (limit ${LIMITS.memoryPercent}%)`)];
}
const unescapeMount = s => s.replace(/\\([0-7]{3})/g, (_, o) => String.fromCharCode(parseInt(o, 8)));
export function checkDisks(ctx) {
  const free = path => { const s = ctx.statfs(path); return 100 * Number(s.bavail) / Number(s.blocks); };
  const out = [];
  const root = free('/');
  out.push(result('disk', 'disk_root_low', !(root < LIMITS.diskRootFreePercent), `Disk space on / ${root.toFixed(0)}% free (limit ${LIMITS.diskRootFreePercent}%)`));
  const mounts = String(ctx.readText(join(ctx.proc, 'mounts')) ?? '').split('\n').map(l => l.split(' ')).filter(p => p.length >= 3);
  const seen = new Set(mounts.filter(p => unescapeMount(p[1]) === '/').map(p => p[0]));
  for (const [dev, mp, type] of mounts) {
    const path = unescapeMount(mp);
    if (path === '/' || !['ext4', 'xfs', 'btrfs'].includes(type) || seen.has(dev) || path.startsWith('/var/lib/docker/')) continue;
    seen.add(dev);
    let pct;
    try { pct = free(path); } catch { continue; }   // a mount that vanished or cannot be read must not stop the other checks
    out.push(result('disk', `disk_low:${path}`, !(pct < LIMITS.diskOtherFreePercent), `Disk space on ${path} ${pct.toFixed(0)}% free (limit ${LIMITS.diskOtherFreePercent}%)`));
  }
  return out;
}

// ---------------------------------------------------------------- database
const DB_SQL = `SELECT (SELECT count(*) FROM pg_stat_activity WHERE backend_type='client backend'),
  COALESCE((SELECT floor(max(extract(epoch FROM now()-xact_start))) FROM pg_stat_activity WHERE xact_start IS NOT NULL AND backend_type='client backend' AND pid<>pg_backend_pid()),0),
  COALESCE((SELECT blks_hit FROM pg_stat_database WHERE datname='postgres'),0),
  COALESCE((SELECT blks_read FROM pg_stat_database WHERE datname='postgres'),0),
  COALESCE((SELECT sum(n_dead_tup) FROM pg_stat_user_tables),0)`;
export const databaseReady = ctx => ctx.compose(['exec', '-T', 'db', 'pg_isready', '-U', 'supabase_admin', '-d', 'postgres']).status === 0;
export function checkDatabase(ctx) {
  if (!databaseReady(ctx)) return [result('database', 'postgres_down', false, 'PostgreSQL is not responding', 'pg_isready failed.')];
  const q = ctx.compose(['exec', '-T', '-e', 'PGOPTIONS=-c statement_timeout=10000', 'db', 'psql', '-X', '-qAt', '-F', '|',
    '-v', 'ON_ERROR_STOP=1', '-U', 'supabase_admin', '-d', 'postgres', '-c', DB_SQL]);
  if (q.status !== 0) throw new Error(`database query failed: ${clip(q.stderr.trim(), 200)}`);
  const v = q.stdout.trim().split('\n').pop().split('|').map(Number);
  if (v.length !== 5 || v.some(Number.isNaN)) throw new Error('unexpected database query output');
  const [conns, txAge, hit, read, dead] = v;
  const ratio = hit / (hit + read + 0.001);
  const cacheBad = hit + read >= LIMITS.cacheMinBlocks && ratio < LIMITS.cacheHitRatio;
  return [
    result('database', 'postgres_down', true, 'PostgreSQL responds'),
    result('database', 'db_connections_high', !(conns > LIMITS.dbConnections), `${conns} client connections (limit ${LIMITS.dbConnections})`),
    // The old stack had a 60 s "slow query" rule and a 300 s "long transaction" rule on the same number. 60 s is
    // normal for a report or a restore tool, so only the 300 s rule is kept: it is the one worth waking someone for.
    result('database', 'db_long_transaction', !(txAge > LIMITS.txSeconds), `Oldest transaction ${txAge} s (limit ${LIMITS.txSeconds} s)`),
    // Counters start at zero after a restart, so a handful of cold reads would read as a bad ratio: a minimum sample.
    result('database', 'db_cache_hit_low', !cacheBad, `Cache hit ratio ${(ratio * 100).toFixed(1)}% (limit ${LIMITS.cacheHitRatio * 100}%)`),
    result('database', 'db_dead_tuples_high', !(dead > LIMITS.deadTuples), `${dead} dead tuples (limit ${LIMITS.deadTuples}); consider VACUUM`),
  ];
}

// ---------------------------------------------------------------- containers
function cgroupDir(ctx, id) {
  for (const dir of [join(ctx.cgroup, 'system.slice', `docker-${id}.scope`), join(ctx.cgroup, 'docker', id)]) {
    if (ctx.readText(join(dir, 'memory.current')) !== null) return dir;
  }
  return null;
}

// OOM events Docker recorded since the previous run, per compose service: a restart or a recreate starts a new
// cgroup whose counter begins again at zero, but the event stream does not lose them.
function oomEvents(ctx) {
  if (ctx.memo.oom) return ctx.memo.oom;
  const now = ctx.now();
  const found = [];
  const project = ctx.env_().WAREHOUSE_PROJECT_NAME;
  const since = Math.floor(Math.max(ctx.data.lastRunAt ?? now, now - 6 * HOUR) / 1000);
  const until = Math.floor(now / 1000);
  if (project && since < until) {
    const r = ctx.run('docker', ['events', '--since', String(since), '--until', String(until), '--filter', 'event=oom',
      '--filter', `label=com.docker.compose.project=${project}`, '--format', '{{json .}}'], { timeoutMs: 20000 });
    if (r.status === 0) {
      for (const line of r.stdout.split('\n')) {
        try {
          const e = JSON.parse(line);
          const service = e.Actor?.Attributes?.['com.docker.compose.service'];
          if (service && isNum(e.time)) found.push({ service, time: e.time });
        } catch { /* not an event line */ }
      }
    }
  }
  return (ctx.memo.oom = found);
}

function memoryFromStats(ctx, containers) {
  if (ctx.memo.stats) return ctx.memo.stats;
  const stats = new Map();
  const r = ctx.run('docker', ['stats', '--no-stream', '--format', '{{.ID}}|{{.MemPerc}}', ...containers.map(c => c.id)], { timeoutMs: 30000 });
  if (r.status === 0) {
    for (const line of r.stdout.split('\n')) {
      const [id, pct] = line.trim().split('|');
      const value = Number.parseFloat(pct);
      if (id && Number.isFinite(value)) stats.set(id, value / 100);
    }
  }
  ctx.memo.stats = { ok: r.status === 0, stats };
  return ctx.memo.stats;
}

function trackOne(ctx, c, now) {
  const prev = ctx.data.containers[c.service];
  const st = prev ?? { restartCount: c.restartCount, startedAt: c.startedAt, events: [], oomKill: null, lastOom: null, oomStart: null, lastOomEvent: null };
  st.events = (st.events ?? []).filter(t => now - t < HOUR);
  // A new container id or start time means a new cgroup: its counters start again, so the baseline is dropped.
  const renewed = Boolean(prev) && (prev.id !== c.id || prev.startedAt !== c.startedAt);
  if (prev) {
    if (c.restartCount > prev.restartCount) for (let i = 0; i < c.restartCount - prev.restartCount; i++) st.events.push(now);
    else if (c.startedAt !== prev.startedAt) st.events.push(now);
  }
  if (renewed) st.oomKill = null;
  st.id = c.id; st.restartCount = c.restartCount; st.startedAt = c.startedAt;
  for (const e of oomEvents(ctx)) {
    if (e.service !== c.service || e.time <= (st.lastOomEvent ?? 0)) continue;
    st.lastOomEvent = e.time;
    st.lastOom = now;
  }
  const dir = cgroupDir(ctx, c.id);
  let memoryRatio = null;
  if (dir) {
    const events = ctx.readText(join(dir, 'memory.events')) ?? '';
    const kills = Number((events.match(/^oom_kill\s+(\d+)/m) ?? [])[1]);
    if (Number.isFinite(kills)) {
      if (st.oomKill !== null && kills > st.oomKill) st.lastOom = now;
      st.oomKill = kills;
    }
    const max = (ctx.readText(join(dir, 'memory.max')) ?? 'max').trim();
    const current = Number((ctx.readText(join(dir, 'memory.current')) ?? '').trim());
    const inactive = Number(((ctx.readText(join(dir, 'memory.stat')) ?? '').match(/^inactive_file\s+(\d+)/m) ?? [])[1]) || 0;
    if (max !== 'max' && Number(max) > 0 && Number.isFinite(current)) memoryRatio = (current - inactive) / Number(max);
  }
  // Docker's own OOMKilled flag (kept until the container is recreated) is a third signal.
  if (prev && c.oomKilled && st.oomStart !== c.startedAt) st.lastOom = st.lastOom ?? now;
  if (c.oomKilled) st.oomStart = c.startedAt;
  ctx.data.containers[c.service] = st;
  return { c, st, memoryRatio, noCgroup: dir === null };
}

// One pass over the containers shared by the three container checks; keeps per-service history in the state.
function track(ctx) {
  if (ctx.memo.tracked) return ctx.memo.tracked;
  const now = ctx.now();
  const out = ctx.containers().map(c => trackOne(ctx, c, now));
  // cgroup v1 or rootless Docker: the cgroup files cannot be read, so ask Docker for the memory share.
  const blind = out.filter(t => t.noCgroup);
  ctx.memo.memoryUnavailable = false;
  if (blind.length) {
    const { ok, stats } = memoryFromStats(ctx, blind.map(t => t.c));
    if (!ok) ctx.memo.memoryUnavailable = true;
    for (const t of blind) t.memoryRatio = stats.get(t.c.id) ?? stats.get(t.c.id.slice(0, 12)) ?? null;
  }
  return (ctx.memo.tracked = out);
}
export const checkContainerOom = ctx => track(ctx).map(({ c, st }) => {
  const recent = st.lastOom !== null && ctx.now() - st.lastOom < LIMITS.oomHoldMs;
  const detail = recent ? `OOM event at ${new Date(st.lastOom).toISOString()}.` : '';
  return result('container_oom', `container_oom:${c.service}`, !recent, `Container ${c.service} was killed for lack of memory`, detail, { immediate: true });
});
export const checkContainerRestarts = ctx => track(ctx).map(({ c, st }) => result('container_restarts', `container_restarts:${c.service}`,
  !(st.events.length > LIMITS.restartsPerHour), `Container ${c.service} restarted ${st.events.length} times in the last hour (limit ${LIMITS.restartsPerHour})`));
export function checkContainerMemory(ctx) {
  const tracked = track(ctx);
  const out = tracked.filter(t => t.memoryRatio !== null).map(({ c, memoryRatio }) => result('container_memory', `container_memory:${c.service}`,
    !(memoryRatio > LIMITS.containerMemoryRatio), `Container ${c.service} uses ${(memoryRatio * 100).toFixed(0)}% of its memory limit (limit ${LIMITS.containerMemoryRatio * 100}%)`));
  if (ctx.memo.memoryUnavailable) {
    // One result that never alerts: the host does not allow this check, which `status` shows.
    ctx.data.memoryNote = 'container memory check unavailable (no readable cgroup and docker stats failed)';
    out.push(result('container_memory', 'container_memory_check', true, 'Container memory check unavailable', ctx.data.memoryNote));
  } else ctx.data.memoryNote = null;
  return out;
}
export function checkServices(ctx) {
  const by = new Map();
  for (const c of ctx.containers()) if (!by.has(c.service) || c.status === 'running') by.set(c.service, c);
  // Only the default-profile services are expected: a profile service (supavisor, cups, sensor-bridge) that is not
  // running is not missing; one that runs but is unhealthy is reported through the container checks and below.
  const wanted = [...ctx.expectedServices(), ...OPTIONAL_SERVICES.filter(name => by.has(name) && !ctx.expectedServices().includes(name))];
  return wanted.map(name => {
    const c = by.get(name);
    const state = c ? `${c.status}${c.health ? ` ${c.health}` : ''}` : 'missing';
    const ok = Boolean(c) && c.status === 'running' && !['unhealthy', 'starting'].includes(c.health);
    return result('services', `service_down:${name}`, ok, `Service ${name} is ${state}`);
  });
}

// ---------------------------------------------------------------- API
async function getJson(ctx, url) {
  const response = await ctx.fetch(url, { signal: AbortSignal.timeout(15000), redirect: 'error' });
  if (!response.ok) throw new Error(`HTTP ${response.status}`);
  return response.json();
}
export async function checkApiLocal(ctx) {
  const port = ctx.env_().KONG_HTTP_PORT;
  if (!/^\d+$/.test(port ?? '')) throw new Error('KONG_HTTP_PORT is not set in compose.env');
  try { await getJson(ctx, `http://127.0.0.1:${port}/functions/v1/get-public-config`); return [result('api_local', 'api_down', true, 'API gateway answers')]; }
  catch (error) { return [result('api_local', 'api_down', false, 'API gateway is not answering on this host', error.message)]; }
}
export async function checkApiPublic(ctx) {
  const manifest = JSON.parse(ctx.readText(join(ctx.state, 'public/instance.json')) ?? 'null');
  if (!manifest?.canonicalOrigin) throw new Error('public/instance.json has no canonicalOrigin');
  try {
    const json = await getJson(ctx, `${manifest.canonicalOrigin}/functions/v1/get-public-config`);
    if (json.success !== true || json.data?.instanceId !== manifest.instanceId) {
      return [result('api_public', 'public_https_down', false, 'The public address answers, but not as this installation', 'instanceId differs.')];
    }
    return [result('api_public', 'public_https_down', true, 'Public HTTPS address works')];
  } catch (error) { return [result('api_public', 'public_https_down', false, 'The public HTTPS address does not work (tunnel or DNS)', error.message)]; }
}
export function parseKongLog(text) {
  const rows = [];
  for (const line of text.split('\n')) {
    const m = line.match(/\[[^\]]+\] "[A-Z]+ \S+ [^"]*" (\d{3}) \d+ ([\d.]+)\s*$/);
    if (m) rows.push({ status: Number(m[1]), seconds: Number(m[2]) });
  }
  return rows;
}
export function checkApiLogs(ctx) {
  const kong = ctx.containers().find(c => c.service === 'kong');
  if (!kong) return [];
  const logs = ctx.run('docker', ['logs', '--since', '5m', kong.id]);
  if (logs.status !== 0) throw new Error('docker logs failed for the gateway');
  const rows = parseKongLog(`${logs.stdout}\n${logs.stderr}`);
  if (rows.length < LIMITS.minRequests) {
    return [result('api_logs', 'api_error_rate_high', true, `Too few requests (${rows.length}) to judge the error rate`), result('api_logs', 'api_latency_p95_high', true, 'Too few requests to judge latency')];
  }
  const errors = rows.filter(r => r.status >= 500).length / rows.length;
  const sorted = rows.map(r => r.seconds).sort((a, b) => a - b);
  const p95 = sorted[Math.min(sorted.length - 1, Math.ceil(sorted.length * 0.95) - 1)];
  return [
    result('api_logs', 'api_error_rate_high', !(errors > LIMITS.errorRate), `API 5xx rate ${(errors * 100).toFixed(1)}% over ${rows.length} requests (limit ${LIMITS.errorRate * 100}%)`),
    result('api_logs', 'api_latency_p95_high', !(p95 > LIMITS.latencySeconds), `API p95 latency ${p95.toFixed(2)} s over ${rows.length} requests (limit ${LIMITS.latencySeconds} s)`),
  ];
}
// The same probe health-check.sh runs: the PDF functions reach the renderer from the function runtime. The read
// has its own 10 s limit so a renderer that accepts the connection and never answers cannot hang the run.
const PDF_PROBE = 'exec 3<>/dev/tcp/pdf-renderer/3000 && printf "GET /health HTTP/1.1\\r\\nHost: pdf-renderer\\r\\nConnection: close\\r\\n\\r\\n" >&3 && read -t 10 -r line <&3 && [[ "$line" == *" 200 "* ]]';
export function checkPdfRenderer(ctx) {
  const probe = ctx.compose(['exec', '-T', 'functions', 'bash', '-c', PDF_PROBE]);
  const ok = probe.status === 0;
  return [result('pdf_renderer', 'pdf_renderer_down', ok, ok ? 'PDF renderer reachable from functions' : 'PDF renderer is not reachable from functions', ok ? '' : 'docker/docker-compose.yml, network renderer')];
}

// The operator health check, one source for health-check.sh, doctor --local and recovery-check.sh: the services, the database and
// the PDF renderer with the check functions the 5-minute checker also runs, and the gateway probed from inside the project (a
// container that shares a network with Kong: the intended project is probed, never an unrelated server on the host port). The
// gateway probe is a public-configuration call and the anon-callable RPC get_public_config (it reads the database, and answers 200 with
// null when the environment is not seeded; PostgREST's OpenAPI document at /rest/v1/ is off, PGRST_OPENAPI_MODE=disabled); a container can be healthy before the gateway answers after a recreate, so it retries for
// up to waitMs. Returns { ok, lines: [{ ok, text }] }.
const GATEWAY_PROBES = `
for (const [name, url, headers, init] of [
  ['REST', 'http://kong:8000/rest/v1/rpc/get_public_config', { apikey: process.env.ANON_KEY, 'Content-Type': 'application/json' },
    { method: 'POST', body: JSON.stringify({ p_environment: 'production' }) }],
  ['configuration', 'http://kong:8000/functions/v1/get-public-config', {}, {}],
]) {
  try { await waitForHttp(name, url, headers, { timeoutMs: WAIT_MS, init }); console.log('OK ' + name); }
  catch (error) { console.log('FAILED ' + error.message); process.exitCode = 1; }
}
`;
export function gatewayProbe(ctx, waitMs) {
  const readiness = ctx.readText(join(ctx.root, 'scripts/http-readiness.mjs'));
  if (readiness === null) throw new Error('scripts/http-readiness.mjs is missing');
  const input = `${readiness}\nconst WAIT_MS = ${Number(waitMs)};${GATEWAY_PROBES}`;
  const probe = ctx.compose(['exec', '-T', 'storage', 'node', '--input-type=module'], { input, timeoutMs: waitMs + 120000 });
  const answered = String(probe.stdout ?? '').split('\n').filter(line => /^(OK|FAILED) /.test(line));
  if (answered.length) {
    const out = answered.map(line => (line.startsWith('OK ') ? { ok: true, text: `${line.slice(3)}: answers through the gateway` } : { ok: false, text: `Gateway: ${line.slice(7)}` }));
    // Both probes must have answered: an exec cut short after "OK REST" must not pass without the configuration check.
    const seen = new Set(answered.map(line => line.replace(/^(OK|FAILED) /, '').split(':')[0]));
    for (const name of ['REST', 'configuration']) if (!seen.has(name)) out.push({ ok: false, text: `Gateway: ${name} was not probed (the probe stopped early)` });
    return out;
  }
  return [{ ok: false, text: `Gateway probe could not run in the storage container (${clip(String(probe.stderr ?? '').trim(), 200) || `status ${probe.status}`})` }];
}
export async function runHealth(deps, { waitMs = 90000 } = {}) {
  const ctx = makeContext(deps, {});
  const lines = [];
  const add = (ok, text) => lines.push({ ok, text });
  // Only the default-profile services can fail the health check. A profile service (supavisor, cups, sensor-bridge) that has
  // a container but is not healthy is a warning: an unconfigured sensor bridge exits and restarts, and a stopped pooler is a choice.
  const expected = ctx.expectedServices();
  for (const r of checkServices(ctx)) {
    if (expected.includes(r.id.replace(/^service_down:/, ''))) add(r.ok, r.summary);
    else if (!r.ok) lines.push({ ok: true, warn: true, text: r.summary });
  }
  const databaseOk = databaseReady(ctx);
  add(databaseOk, databaseOk ? 'PostgreSQL accepts connections' : 'PostgreSQL is not accepting connections');
  for (const line of gatewayProbe(ctx, waitMs)) add(line.ok, line.text);
  for (const r of checkPdfRenderer(ctx)) add(r.ok, r.ok ? r.summary : `${r.summary} (${r.detail})`);
  return { ok: lines.every(line => line.ok), lines };
}
// The rule is centralKeyFault (doctor-common.mjs), the same one doctor.mjs applies: the file the router reads must be a usable key set.
export function centralKeyProblem(env, state) {
  const fault = centralKeyFault(env.CENTRAL_JWKS_FILE, state);
  if (!fault) return '';
  return {
    name: `CENTRAL_JWKS_FILE must be a plain file name, not ${fault.path}.`,
    missing: `Central sign-in reads its keys from ${fault.path}, but that file is missing: every central sign-in fails while the app still offers it.`,
    'not-file': `${fault.path} must be a regular file.`,
    'too-large': `${fault.path} is larger than 64 KB; central sign-in refuses it.`,
    'not-json': `${fault.path} is not a usable key set: ${fault.detail}`,
    unusable: `${fault.path} is not a usable key set: ${fault.detail}`,
  }[fault.code];
}
export function checkCentralKey(ctx) {
  const problem = centralKeyProblem(ctx.env_(), ctx.state);
  return [problem ? result('central_key', 'central_key_file', false, 'Central sign-in key file is missing or unusable', problem)
    : result('central_key', 'central_key_file', true, 'Central sign-in key file fine or not used')];
}
// The optional letterhead image of the document PDFs (LETTERHEAD_FILE): a missing or unusable file does not stop a PDF, which is
// made plain, so the detail says what to rerun; the rule is letterheadFault (doctor-common.mjs), as in doctor.mjs.
export function checkLetterhead(ctx) {
  const problem = letterheadProblem(ctx.env_(), ctx.state);
  return [problem ? result('letterhead', 'letterhead_file', false, 'Letterhead image is missing or unusable (PDFs are plain)', problem)
    : result('letterhead', 'letterhead_file', true, 'Letterhead image fine or not used')];
}

// ---------------------------------------------------------------- backups
const fieldsOf = text => Object.fromEntries(String(text ?? '').split('\n').filter(l => l.includes('='))
  .map(l => [l.slice(0, l.indexOf('=')), l.slice(l.indexOf('=') + 1)]));
export const backupStatusPath = (state, job) => join(state, `config/watch-${job}.last`);
export function newestBackupMs(state) {
  let newest = 0;
  let names = [];
  try { names = readdirSync(join(state, 'backups')); } catch { return 0; }
  for (const name of names) {
    if (!BACKUP_DIR_PATTERN.test(name)) continue;
    const meta = lstatSync(join(state, 'backups', name, 'metadata.txt'), { throwIfNoEntry: false });
    if (meta?.isFile()) newest = Math.max(newest, meta.mtimeMs);
  }
  return newest;
}
export function checkBackups(ctx) {
  const now = ctx.now();
  const last = fieldsOf(ctx.readText(backupStatusPath(ctx.state, 'backup')));
  const success = Math.max((Number(last.last_success_epoch) || 0) * 1000, newestBackupMs(ctx.state));
  const age = now - success;
  const graceOver = now - ctx.data.firstRun > LIMITS.backupMaxAgeMs;
  const missing = success === 0 ? graceOver : age > LIMITS.backupMaxAgeMs;
  const failed = last.result === 'failed' && (Number(last.finished_epoch) || 0) * 1000 > success;
  const agoText = success === 0 ? 'No backup has been made yet' : `Last good backup is ${Math.floor(age / HOUR)} h old (limit 26 h)`;
  const out = [
    result('backups', 'backup_missing', !missing, agoText, 'Check the backup schedule: node scripts/watch.mjs status'),
    // The failed daily backup is reported only here (after two failing runs), with the job's own message.
    result('backups', 'backup_failed', !failed, `The last backup failed${last.message ? `: ${last.message}` : ''}`, last.message ?? ''),
  ];
  const usb = usbBackupWarning(ctx.state, { now, etc: ctx.usbEtc });
  out.push(result('backups', 'usb_backup', usb === null, usb ?? 'USB backup fine or not set up', usb ?? ''));
  const ret = fieldsOf(ctx.readText(backupStatusPath(ctx.state, 'retention')));
  out.push(result('backups', 'retention_failed', ret.result !== 'failed', `The last retention clean-up failed${ret.message ? `: ${ret.message}` : ''}`, ret.message ?? ''));
  return out;
}

export const CHECKS = [
  ['cpu', checkCpu], ['memory', checkMemory], ['disk', checkDisks], ['database', checkDatabase],
  ['services', checkServices], ['container_oom', checkContainerOom], ['container_restarts', checkContainerRestarts],
  ['container_memory', checkContainerMemory], ['api_local', checkApiLocal], ['api_public', checkApiPublic],
  ['api_logs', checkApiLogs], ['pdf_renderer', checkPdfRenderer], ['central_key', checkCentralKey], ['letterhead', checkLetterhead], ['backups', checkBackups],
];

// Runs every check; a throwing check becomes one failing result carrying its (redacted) error text.
export async function runChecks(ctx, checks = CHECKS) {
  const results = [];
  const ran = new Set();
  const env = ctx.env_();
  const webhook = readWebhook(ctx.state);
  for (const [name, fn] of checks) {
    try {
      const list = await fn(ctx);
      for (const r of list) { r.check = r.check ?? name; results.push(r); ran.add(r.check); }
      ran.add(name);
      results.push({ check: `error:${name}`, id: `check_error:${name}`, ok: true, summary: '', detail: '' });
    } catch (error) {
      const detail = clip(redact(error?.message ?? String(error), env, webhook));
      results.push({ check: `error:${name}`, id: `check_error:${name}`, ok: false, summary: `Check "${name}" could not run`, detail });
    }
  }
  return { results, ran };
}

// ---------------------------------------------------------------- self-healing
// Docker restarts a container that exited, but not one that was stopped, and the backup stops four services for a while: a
// power cut then leaves them stopped, and the daemon does not start them again. A service of the default profile that is
// `exited` is started again; one that stays `unhealthy` for 3 runs in a row is restarted; each at most once an hour. Only
// while no operator command holds the lock (those stop services on purpose), not while the service's alert is muted (a planned
// stop), and never the database for being unhealthy: a database in crash recovery reports unhealthy too, and a restart only
// begins the recovery again. The start keeps the existing container (--no-recreate): applying a changed compose file or image
// is the operator's job (setup.sh), not the checker's. Every action is reported as the alert service_healed:<name>, held for
// an hour like an OOM kill.
export function selfHeal(ctx) {
  const now = ctx.now();
  const out = [];
  const by = new Map();
  let expected;
  try {
    for (const c of ctx.containers()) if (!by.has(c.service) || c.status === 'running') by.set(c.service, c);
    expected = ctx.expectedServices();
  } catch { return out; }   // the services check reports why it cannot see them
  for (const name of expected) {
    const c = by.get(name);
    const h = ctx.data.heal[name] ??= { unhealthyRuns: 0, lastAt: null, lastAction: '' };
    const exited = c?.status === 'exited';
    const unhealthy = c?.status === 'running' && c.health === 'unhealthy';
    if (unhealthy) h.unhealthyRuns += 1; else if (c?.health !== 'starting') h.unhealthyRuns = 0;
    const idle = h.lastAt === null || h.lastAt > now || now - h.lastAt >= LIMITS.healGapMs;
    let act = null;
    if (exited) act = { args: ['up', '-d', '--no-recreate', name], what: `was ${c.status}`, did: 'started it again' };
    else if (unhealthy && name !== 'db' && h.unhealthyRuns >= LIMITS.healUnhealthyRuns) {
      act = { args: ['restart', name], what: `was unhealthy for ${h.unhealthyRuns} runs`, did: 'restarted it' };
    }
    if (act && idle && !isMuted(ctx.data, `service_down:${name}`, now) && !lockIsHeld(ctx)) {
      const r = ctx.compose(act.args, { timeoutMs: 180000 });
      h.lastAt = now; h.unhealthyRuns = 0;
      h.lastAction = r.status === 0 ? `${act.what}; the checker ${act.did}`
        : `${act.what}; the checker could not do it: ${clip(redact(String(r.stderr ?? '').trim(), ctx.env_()), 200)}`;
    }
    if (h.lastAt !== null && h.lastAt <= now && now - h.lastAt < LIMITS.healGapMs) {
      out.push(result('self_heal', `service_healed:${name}`, false, `Service ${name} ${h.lastAction}`, 'See docs/MONITORING.md, "Self-healing".', { immediate: true }));
    }
  }
  return out;
}

// ---------------------------------------------------------------- the operator lock
// True while another process holds the flock on config/operator.lock. /proc/locks is read instead of trying the
// lock: taking it, even for an instant, could make a real operator command fail.
export function lockIsHeld(ctx) {
  let inode;
  try { inode = statSync(join(ctx.state, 'config/operator.lock')).ino; } catch { return false; }
  const locks = ctx.readText(join(ctx.proc, 'locks'));
  if (locks === null) return false;
  return locks.split('\n').some(line => {
    if (line.includes('->') || !/\bFLOCK\b/.test(line)) return false;
    const m = line.match(/\s[0-9a-f]+:[0-9a-f]+:(\d+)\s/);
    return Boolean(m) && Number(m[1]) === inode;
  });
}

// ---------------------------------------------------------------- alerting
export const isMuted = (data, id, now) => Boolean((data.muteUntil && now < data.muteUntil) || (data.mutes?.[id] && now < data.mutes[id]));

// Updates the per-alert counters and returns what to tell Slack. Nothing is marked as sent here.
export function evaluate(data, results, ran, now) {
  const seen = new Set();
  for (const r of results) {
    seen.add(r.id);
    let a = data.alerts[r.id];
    if (!r.ok) {
      a ??= data.alerts[r.id] = { failingRuns: 0, firingSince: null, lastSent: null };
      a.failingRuns = (a.failingRuns || 0) + 1; a.check = r.check; a.summary = r.summary; a.detail = r.detail;
      if (!a.firingSince && (a.failingRuns >= LIMITS.failingRuns || r.immediate)) a.firingSince = now;
      a.clearPending = false;
    } else if (a) recover(data, r.id, a);
  }
  for (const [id, a] of Object.entries(data.alerts)) if (!seen.has(id) && ran.has(a.check)) recover(data, id, a);
  const start = [];
  const repeat = [];
  const clear = [];
  for (const [id, a] of Object.entries(data.alerts)) {
    const line = { id, summary: a.summary, detail: a.detail };
    if (a.clearPending) { if (isMuted(data, id, now)) delete data.alerts[id]; else clear.push(line); continue; }
    if (!a.firingSince || isMuted(data, id, now)) continue;
    // A clock that went backwards must not silence an alert for good.
    if (a.lastSent === null || a.lastSent > now) start.push(line);
    else if (now - a.lastSent >= LIMITS.repeatMs) repeat.push(line);
  }
  return { start, repeat, clear };
}
function recover(data, id, a) {
  if (a.firingSince && a.lastSent !== null) { a.clearPending = true; a.failingRuns = 0; a.firingSince = null; }
  else delete data.alerts[id];
}

export function describe(ctx) {
  let company = '';
  const project = ctx.env_().WAREHOUSE_PROJECT_NAME ?? '';
  try { company = JSON.parse(ctx.readText(join(ctx.state, 'public/instance.json')) ?? '{}').companyName ?? ''; } catch { /* no manifest */ }
  return company ? `${company} (${project})` : project || ctx.state;
}
export function formatAlerts({ start, repeat, clear }, name, env, webhook) {
  const text = (value, n) => clip(redact(value, env, webhook), n);
  const line = a => `- ${text(a.summary, 200)}${a.detail ? `: ${text(a.detail, 300)}` : ''}`;
  const parts = [];
  if (start.length) parts.push(`[FIRING] ${name}\n${start.map(line).join('\n')}`);
  if (repeat.length) parts.push(`[STILL FIRING] ${name}\n${repeat.map(line).join('\n')}`);
  if (clear.length) parts.push(`[CLEARED] ${name}\n${clear.map(a => `- ${text(a.summary, 200)}`).join('\n')}`);
  return parts.join('\n\n');
}

// ---------------------------------------------------------------- posting
// postSlackMessage resolves with the HTTP status whatever it is: only a 2xx counts as delivered.
export async function postOk(ctx, webhook, text) {
  const status = await ctx.post(webhook, text);
  if (typeof status === 'number' && !(status >= 200 && status < 300)) throw new Error(`Slack answered HTTP ${status}`);
}

// If the state cannot be saved, say so once an hour (a stateless rule: only the run that starts in the first 5
// minutes of an hour), then stop the run.
async function saveOrWarn(ctx, webhook) {
  try { saveState(ctx.state, ctx.data, ctx.fsApi); } catch (error) {
    if (webhook && new Date(ctx.now()).getMinutes() < 5) {
      try { await postOk(ctx, webhook, redact(`[WATCH] cannot save its state: ${error.message}`, ctx.env_(), webhook)); } catch { /* nowhere left to report */ }
    }
    throw error;
  }
}

// Marks the message as sent and saves BEFORE posting, so a crash or a second process cannot post it twice; when the
// post fails the marks are undone and saved again, and the failure is recorded for `status`.
async function postThenKeep(ctx, webhook, text, apply, undo) {
  const now = ctx.now();
  apply();
  await saveOrWarn(ctx, webhook);
  try {
    await postOk(ctx, webhook, text);
    ctx.data.lastPostError = null;
  } catch (error) {
    undo();
    ctx.data.lastPostError = { at: now, message: clip(redact(error.message, ctx.env_(), webhook), 200) };
    await saveOrWarn(ctx, webhook);
  }
}

async function notify(ctx, webhook, plan) {
  const { start, repeat, clear } = plan;
  if ((!start.length && !repeat.length && !clear.length) || !webhook) return;
  const { data } = ctx;
  const now = ctx.now();
  const text = formatAlerts(plan, describe(ctx), ctx.env_(), webhook);
  const sent = [...start, ...repeat].map(a => [a.id, data.alerts[a.id].lastSent]);
  const cleared = clear.map(a => [a.id, data.alerts[a.id]]);
  await postThenKeep(ctx, webhook, text, () => {
    for (const [id] of sent) data.alerts[id].lastSent = now;
    for (const [id] of cleared) delete data.alerts[id];
  }, () => {
    for (const [id, before] of sent) if (data.alerts[id]) data.alerts[id].lastSent = before;
    for (const [id, entry] of cleared) data.alerts[id] = entry;
  });
}

// ---------------------------------------------------------------- calendar rules
const pad = n => String(n).padStart(2, '0');
export const localDate = ms => { const d = new Date(ms); return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`; };
const parseTime = (text, fallback) => TIME_OF_DAY.exec(text) ?? TIME_OF_DAY.exec(fallback);
const minutesOfDay = ms => { const d = new Date(ms); return d.getHours() * 60 + d.getMinutes(); };

// One heartbeat per local calendar day, after heartbeatAt. A clock that went backwards (last in the future) is due.
export function heartbeatDue(now, last, heartbeatAt = DEFAULT_HEARTBEAT_AT) {
  if (last === null || last === undefined || now < last) return true;
  const m = parseTime(heartbeatAt, DEFAULT_HEARTBEAT_AT);
  return localDate(now) !== localDate(last) && minutesOfDay(now) >= Number(m[1]) * 60 + Number(m[2]);
}
async function heartbeat(ctx, webhook) {
  const { data } = ctx;
  const now = ctx.now();
  if (!webhook || !heartbeatDue(now, data.lastHeartbeat, ctx.heartbeatAt)) return;
  const firing = Object.values(data.alerts).filter(a => a.firingSince).length;
  const muted = data.muteUntil && now < data.muteUntil ? ` Alerts are muted until ${new Date(data.muteUntil).toISOString()}.` : '';
  const text = redact(`Monitoring is alive - ${describe(ctx)}\n${firing ? `${firing} alert(s) firing.` : 'No alerts firing.'}${muted}`, ctx.env_(), webhook);
  const before = data.lastHeartbeat;
  await postThenKeep(ctx, webhook, text, () => { data.lastHeartbeat = now; }, () => { data.lastHeartbeat = before; });
}

// The daily window starts at the latest local occurrence of dailyAt that is not after now and lasts 6 hours. Its
// local calendar date names the day: it is the same rule across a clock change or midnight.
export function dailyWindow(now, dailyAt) {
  const m = parseTime(dailyAt, DEFAULT_DAILY_AT);
  const d = new Date(now);
  let start = new Date(d.getFullYear(), d.getMonth(), d.getDate(), Number(m[1]), Number(m[2]), 0, 0).getTime();
  if (start > now) { const y = new Date(d.getFullYear(), d.getMonth(), d.getDate() - 1, Number(m[1]), Number(m[2]), 0, 0); start = y.getTime(); }
  return { start, date: localDate(start), open: now - start < LIMITS.dailyWindowMs };
}

// ---------------------------------------------------------------- backups pruning
const BACKUP_STAMP = /^warehouse-(\d{4})(\d{2})(\d{2})T(\d{2})(\d{2})(\d{2})Z/;
const stampMs = name => { const m = BACKUP_STAMP.exec(name); return m ? Date.UTC(+m[1], +m[2] - 1, +m[3], +m[4], +m[5], +m[6]) : null; };
const instanceIdOf = path => { try { return JSON.parse(readFileSync(path, 'utf8')).instanceId ?? null; } catch { return null; } };

// Keeps the newest `keep` backup directories of THIS installation in $STATE/backups and removes the older ones.
// A directory counts only when its name is one backup.sh gives, it is a real directory holding metadata.txt, and its
// instance.json names the same instanceId as $STATE/public/instance.json. Manual backups in that directory that meet
// these rules count towards `keep`. `protect` (the backup just made) is never removed. Nothing at all is removed when
// any warehouse-* name is dated more than an hour ahead of now (a clock that was wrong would otherwise make the
// newest-first order delete good backups). Returns { removed, note }.
export function pruneBackups(state, { keep = LIMITS.keepBackups, protect = null, now = Date.now() } = {}) {
  if (typeof state !== 'string' || !state.startsWith('/')) throw new Error(`the state path must be absolute: ${state}`);
  const dir = join(state, 'backups');
  const names = readdirSync(dir);
  const future = names.find(name => { const t = stampMs(name); return t !== null && t > now + LIMITS.futureBackupMs; });
  if (future) return { removed: [], note: `pruning skipped: ${future} is dated in the future (check the clock)` };
  const mine = instanceIdOf(join(state, 'public/instance.json'));
  if (!mine) return { removed: [], note: 'pruning skipped: public/instance.json has no instanceId' };
  const ours = names.filter(name => {
    if (!BACKUP_DIR_PATTERN.test(name)) return false;
    const s = lstatSync(join(dir, name), { throwIfNoEntry: false });
    const meta = lstatSync(join(dir, name, 'metadata.txt'), { throwIfNoEntry: false });
    return Boolean(s?.isDirectory()) && !s.isSymbolicLink() && Boolean(meta?.isFile()) && instanceIdOf(join(dir, name, 'instance.json')) === mine;
  }).sort().reverse();
  const protectName = protect ? String(protect).split('/').pop() : null;
  const removed = ours.slice(keep).filter(name => name !== protectName);
  for (const name of removed) rmSync(join(dir, name), { recursive: true, force: true });
  return { removed, note: '' };
}

// ---------------------------------------------------------------- daily jobs
function writeJobStatus(ctx, job, ok, message, extra = {}) {
  const now = ctx.now();
  const previous = fieldsOf(ctx.readText(backupStatusPath(ctx.state, job)));
  const success = ok ? Math.floor(now / 1000) : Number(previous.last_success_epoch) || 0;
  const clean = String(message).replace(/[\r\n]+/g, ' ').slice(0, 400);
  const lines = [`result=${ok ? 'ok' : 'failed'}`, `finished_utc=${new Date(now).toISOString()}`, `finished_epoch=${Math.floor(now / 1000)}`,
    `last_success_epoch=${success}`, `message=${clean}`, ...Object.entries(extra).map(([k, v]) => `${k}=${v}`)];
  writeFileAtomic(backupStatusPath(ctx.state, job), `${lines.join('\n')}\n`);
}
const lastLine = text => String(text).trim().split('\n').filter(Boolean).pop() ?? '';
export const dailyResultPath = state => join(state, 'config/watch-daily.result');

// Turns watch-daily.sh's result file into { skipped } or { backup, verify, prune, retention } steps.
export function interpretDaily(ctx, run, fields) {
  const step = (key, fallback = 'skipped') => ({ result: fields[key] ?? fallback, message: fields[`${key}_message`] ?? '' });
  if (fields.lock === 'held' || run.status === 75) return { skipped: 'operator lock is held' };
  if (fields.done !== '1') {
    const why = run.timedOut ? 'the daily run timed out' : `the daily run did not finish${lastLine(run.stderr) ? `: ${lastLine(run.stderr)}` : ''}`;
    return { backup: { result: 'failed', message: why }, verify: step('verify'), prune: step('prune'), retention: { result: 'skipped', message: "retention not run: today's backup failed" } };
  }
  if (fields.backup === 'skipped') return { skipped: fields.backup_message || 'the database is not running or not healthy' };
  const backup = { ...step('backup', 'failed'), dir: fields.backup_dir ?? null };
  const dir = backup.dir;
  if (backup.result === 'ok' && !(dir && BACKUP_DIR_PATTERN.test(dir.split('/').pop()) && resolve(dir, '..') === resolve(ctx.state, 'backups'))) {
    backup.result = 'failed'; backup.message = 'backup finished but its location could not be read';
  }
  return { backup, verify: step('verify'), prune: { ...step('prune'), pruned: Number(fields.pruned) || 0 }, retention: step('retention') };
}

export async function dailyRunner(ctx) {
  const resultFile = dailyResultPath(ctx.state);
  const env = { ...process.env, WAREHOUSE_STATE_DIR: ctx.state };
  delete env.WAREHOUSE_BACKUP_DIR;
  const launch = ctx.runGroup ?? ((command, args, options) => ctx.run(command, args, options));
  const r = await launch('bash', [join(ctx.root, 'scripts/watch-daily.sh'), resultFile], { timeoutMs: LIMITS.dailyHardMs, env });
  return interpretDaily(ctx, r, fieldsOf(ctx.readText(resultFile)));
}

// Records one finished pass; returns whether today's backup is done (made and verified).
function recordDaily(ctx, data, outcome, attempt, webhook) {
  const now = ctx.now();
  const env = ctx.env_();
  const clean = text => redact(text, env, webhook);
  const date = localDate(now);
  const { backup, verify } = outcome;
  const name = backup.dir ? backup.dir.split('/').pop() : '';
  const backupOk = backup.result === 'ok' && verify.result === 'ok';
  let message;
  if (backup.result !== 'ok') message = backup.message.startsWith('backup') || backup.message.startsWith('the daily') ? backup.message : `backup failed: ${backup.message}`;
  else if (verify.result !== 'ok') message = `backup ${name} was made but verification failed: ${verify.message}`;
  else message = `backup ${name} verified${outcome.prune.pruned ? `; removed ${outcome.prune.pruned} old` : ''}${outcome.prune.message ? `; ${outcome.prune.message}` : ''}`;
  message = `${clean(message)}${backupOk ? '' : ` (attempt ${attempt} of ${LIMITS.dailyAttempts})`}`;
  data.lastDailyRun.backup = { date, at: now, result: backupOk ? 'ok' : 'failed', message };
  try { writeJobStatus(ctx, 'backup', backupOk, message, name && backup.result === 'ok' ? { backup: name } : {}); } catch { /* the state file carries the result */ }

  // Pruning belongs to the retention job: its failure is reported as a retention failure.
  const { retention, prune } = outcome;
  let retentionResult = retention.result;
  const defaultNote = { ok: 'retention applied', skipped: "retention not run: today's backup failed" };
  let retentionMessage = retention.message || defaultNote[retention.result] || '';
  if (prune.result === 'failed') { retentionResult = 'failed'; retentionMessage = `removing old backups failed: ${prune.message}`; }
  retentionMessage = clean(retentionMessage);
  data.lastDailyRun.retention = { date, at: now, result: retentionResult, message: retentionMessage };
  if (retentionResult !== 'skipped') {
    try { writeJobStatus(ctx, 'retention', retentionResult === 'ok', retentionMessage); } catch { /* the state file carries the result */ }
  }
  return backupOk;
}

export async function runDaily(ctx, data, healthy, runner = dailyRunner, webhook = null) {
  const now = ctx.now();
  if (data.dailyRunning) {
    if (now >= data.dailyRunning.startedAt && now - data.dailyRunning.startedAt < LIMITS.jobStaleMs) return;
    data.dailyRunning = null;   // an interrupted pass (killed unit, power loss): stale
  }
  const win = dailyWindow(now, ctx.dailyAt);
  if (!win.open) return;
  // A new state file (or a reset one) waits for the next window instead of backing up at once.
  if (win.start < data.firstRun && !data.lastDailyRun.backup) return;
  if (!data.dailyAttempt || data.dailyAttempt.date !== win.date) data.dailyAttempt = { date: win.date, count: 0, lastAt: null, done: false };
  const attempt = data.dailyAttempt;
  if (attempt.done || attempt.count >= LIMITS.dailyAttempts) return;
  if (attempt.lastAt !== null && now >= attempt.lastAt && now - attempt.lastAt < LIMITS.dailyRetryMs) return;
  // The gate is a function for `daily` (its checks run only when a pass would start) and a value in tests.
  if (!(typeof healthy === 'function' ? await healthy() : healthy)) { data.dailySkipped = { at: now, reason: 'the database or a service is not up in this run' }; return; }

  data.dailyRunning = { job: 'daily', startedAt: now };
  saveState(ctx.state, data, ctx.fsApi, { daily: true });
  let outcome;
  try { outcome = await runner(ctx); } catch (error) {
    outcome = { backup: { result: 'failed', message: `the daily run crashed: ${error.message}` }, verify: { result: 'skipped' }, prune: { result: 'skipped' }, retention: { result: 'skipped', message: "retention not run: today's backup failed" } };
  }
  data.dailyRunning = null;
  if (outcome.skipped) { data.dailySkipped = { at: now, reason: redact(outcome.skipped, ctx.env_(), webhook) }; saveState(ctx.state, data, ctx.fsApi, { daily: true }); return; }
  data.dailySkipped = null;
  attempt.count += 1; attempt.lastAt = now;
  attempt.done = recordDaily(ctx, data, outcome, attempt.count, webhook);
  saveState(ctx.state, data, ctx.fsApi, { daily: true });
}

// The daily jobs need a running database and services in THIS run: right after a boot the first runs find them down.
export function dailyHealthy(results) {
  const pg = results.find(r => r.id === 'postgres_down');
  if (!pg || !pg.ok) return false;
  return !results.some(r => !r.ok && (r.id.startsWith('service_down:') || r.id === 'check_error:services' || r.id === 'check_error:database'));
}

// ---------------------------------------------------------------- external heartbeat
// config/heartbeat-url: one https URL (blank lines and # comments are skipped) of a dead-man switch (healthchecks.io, or any address that alerts when its pings
// stop), written by the operator, mode 0600 because whoever knows the URL can fake the ping. Returns { url } (empty when
// there is no file) or { problem }.
export const heartbeatUrlPath = state => join(state, 'config/heartbeat-url');
export const HEARTBEAT_TIMEOUT_MS = 5000;
export function readHeartbeatUrl(state) {
  const path = heartbeatUrlPath(state);
  const stat = lstatSync(path, { throwIfNoEntry: false });
  if (!stat) return { url: '' };
  if (!stat.isFile() || stat.uid !== process.getuid() || (stat.mode & 0o077)) return { problem: 'config/heartbeat-url must be a regular file owned by the installation user with mode 0600' };
  const url = (readFileOrNull(path) ?? '').split('\n').map(l => l.trim()).find(l => l && !l.startsWith('#')) ?? '';
  if (!/^https:\/\/[^\s/]+\/?\S*$/.test(url)) return { problem: 'config/heartbeat-url must hold one https URL' };
  return { url };
}
// The end of every successful run: a GET with a 5 s limit. A failure is logged (never the URL, which is a secret) and
// never alerted: if the ping cannot leave, the dead-man switch is the thing that tells the operator.
export async function pingExternalHeartbeat(ctx) {
  const log = ctx.log ?? stderrLog;
  let found;
  try { found = readHeartbeatUrl(ctx.state); } catch (error) { log(`external heartbeat not sent: ${error.message}`); return; }
  if (found.problem) { log(`external heartbeat not sent: ${found.problem}`); return; }
  if (!found.url) return;
  const timeout = ctx.heartbeatTimeoutMs ?? HEARTBEAT_TIMEOUT_MS;
  try {
    const response = await ctx.fetch(found.url, { signal: AbortSignal.timeout(timeout), redirect: 'error' });
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
  } catch (error) {
    log(`external heartbeat ping failed: ${redact(String(error?.cause?.code ?? error?.message ?? error), ctx.env_()).split(found.url).join('[REDACTED]')}`);
  }
}

// ---------------------------------------------------------------- the run
export async function runOnce(deps, { checks = CHECKS, heal = selfHeal } = {}) {
  const now = deps.now();
  const data = loadState(deps.state, now, deps.readText, deps.log);
  Object.assign(data, loadMutes(deps.state, deps.readText));
  const ctx = makeContext(deps, data);
  const webhook = readWebhook(deps.state);
  let stuck = false;
  if (lockIsHeld(ctx)) {
    // Backup, restore, setup and stop stop services on purpose: judge nothing while one runs, unless it hangs.
    if (data.busySince === null || data.busySince > now) data.busySince = now;
    if (now - data.busySince < LIMITS.busyGiveUpMs) {
      saveState(deps.state, data, deps.fsApi);
      await pingExternalHeartbeat(ctx);   // the checker is alive; it is the operator command that is busy
      return { skipped: 'operator lock is held', data };
    }
    stuck = true;
  } else data.busySince = null;
  const { results, ran } = await runChecks(ctx, checks);
  // Not while the lock is stuck (an operator command is still running, stopping services on purpose).
  if (heal && !stuck) {
    const healed = await runChecks(ctx, [['self_heal', heal]]);
    results.push(...healed.results);
    for (const name of healed.ran) ran.add(name);
  }
  const heldHours = stuck ? Math.floor((now - data.busySince) / HOUR) : 0;
  results.push(result('operator_lock', 'operator_lock_stuck', !stuck, `An operator command has held the lock for ${heldHours} h or more`, 'Look for a hung setup, backup or restore: node scripts/watch.mjs status'));
  ran.add('operator_lock');
  data.lastRunAt = now;
  const plan = evaluate(data, results, ran, now);
  await notify(ctx, webhook, plan);
  await heartbeat(ctx, webhook);
  saveState(deps.state, data, deps.fsApi);
  await pingExternalHeartbeat(ctx);
  return { results, plan, data };
}

// `watch.mjs daily`: what the daily timer runs. The gate (the database and the services the backup stops) is judged by the
// same two checks the checker runs, and only when a pass is about to start.
export const DAILY_GATE_CHECKS = [['database', checkDatabase], ['services', checkServices]];
export async function runDailyCommand(deps, { checks = DAILY_GATE_CHECKS, daily = dailyRunner } = {}) {
  const data = loadState(deps.state, deps.now(), deps.readText, deps.log);
  const ctx = makeContext(deps, data);
  const webhook = readWebhook(deps.state);
  await runDaily(ctx, data, async () => dailyHealthy((await runChecks(ctx, checks)).results), daily, webhook);
  saveState(deps.state, data, deps.fsApi, { daily: true });
  return { data };
}

// ---------------------------------------------------------------- commands
const USAGE = `Usage: node scripts/watch.mjs run | daily | health [--wait SECONDS] | test-message | status | mute MINUTES ["ALERT ID"] | unmute ["ALERT ID"]
  run           one pass of the checks (the systemd timer runs this every 5 minutes); it never makes a backup
  daily         the daily backup, verification, pruning and retention, inside the window after --daily-at (its own timer runs this)
  health        the operator health check now: services, database, gateway, get_public_config RPC probe, PDF renderer (exit 1 on a fault; --wait: seconds to wait for the gateway, default 90)
  test-message  post a test message to the facility's Slack webhook
  status        failing alerts, mutes, the daily jobs and the time zone
  mute          silence all alerts (or one alert id, quoted when it has spaces) for MINUTES
  unmute        end the mute (all, or one alert id)
Mute before a deliberate stop.sh (or any planned stop): a stopped service is an alert like any other.
The daily backup, verification, pruning and retention run once a day inside a 6-hour window after the time chosen
with: sudo bash scripts/watch-timer.sh install --daily-at HH:MM (host local time; shown by status). Pruning keeps the
newest 7 backups of this installation in $STATE/backups; backups made by hand there count towards the 7.
Needs WAREHOUSE_STATE_DIR. Install the timer with: sudo bash scripts/watch-timer.sh install`;

function statusLines(ctx, webhook, now) {
  const { data } = ctx;
  const lines = [`Installation: ${describe(ctx)}`, `Slack webhook: ${webhook ? 'configured' : 'none (alerts are recorded, not posted)'}`];
  let external;
  try { external = readHeartbeatUrl(ctx.state); } catch { external = { problem: 'cannot be read' }; }
  lines.push(`External heartbeat: ${external.problem ? `not sent (${external.problem})` : external.url ? 'configured (pinged at the end of each run)' : 'none (config/heartbeat-url)'}`);
  lines.push(`Time zone: ${Intl.DateTimeFormat().resolvedOptions().timeZone} (daily jobs start at ${ctx.dailyAt} in this zone)`);
  const firing = Object.entries(data.alerts).filter(([, a]) => a.firingSince);
  lines.push(firing.length ? `Firing: ${firing.map(([id]) => id).join(', ')}` : 'Firing: none');
  const failing = Object.entries(data.alerts).filter(([, a]) => !a.firingSince && a.failingRuns);
  if (failing.length) lines.push(`Failing once (not yet firing): ${failing.map(([id]) => id).join(', ')}`);
  if (data.muteUntil && now < data.muteUntil) lines.push(`All alerts muted until ${new Date(data.muteUntil).toISOString()}`);
  for (const [id, until] of Object.entries(data.mutes ?? {})) if (now < until) lines.push(`Muted until ${new Date(until).toISOString()}: ${id}`);
  for (const [job, run] of Object.entries(data.lastDailyRun)) lines.push(`Daily ${job}: ${run.result} on ${run.date} - ${run.message}`);
  const attempt = data.dailyAttempt;
  if (attempt) lines.push(`Daily pass ${attempt.date}: ${attempt.count} of ${LIMITS.dailyAttempts} attempts${attempt.done ? ', done' : ''}`);
  if (data.dailySkipped) lines.push(`Daily pass last skipped at ${new Date(data.dailySkipped.at).toISOString()}: ${data.dailySkipped.reason}`);
  if (data.memoryNote) lines.push(`Note: ${data.memoryNote}`);
  if (data.lastPostError) lines.push(`Last Slack post failed at ${new Date(data.lastPostError.at).toISOString()}: ${data.lastPostError.message}`);
  lines.push(`Last heartbeat: ${data.lastHeartbeat ? new Date(data.lastHeartbeat).toISOString() : 'never'}`);
  return lines;
}

export async function main(argv, deps = defaultDeps(), out = text => console.log(text)) {
  const [command, ...args] = argv;
  if (!command || ['--help', '-h', 'help'].includes(command)) { out(USAGE); return command ? 0 : 1; }
  const now = deps.now();
  if (command === 'run') { await runOnce(deps); return 0; }
  if (command === 'daily') { await runDailyCommand(deps); return 0; }
  if (command === 'health') {
    if (args.length && !(args.length === 2 && args[0] === '--wait' && /^\d{1,4}$/.test(args[1]))) { out('health takes only --wait SECONDS.'); return 1; }
    const report = await runHealth(deps, { waitMs: args.length ? Number(args[1]) * 1000 : undefined });
    for (const line of report.lines) out(`${line.warn ? 'warn   ' : line.ok ? 'ok     ' : 'FAILED '}${line.text}`);
    return report.ok ? 0 : 1;
  }
  if (command === 'prune-backups') {
    // Used by scripts/watch-daily.sh under its lock: prints removed=N and note=TEXT.
    if (args.length !== 1) { out('prune-backups needs the path of the backup just made.'); return 1; }
    const { removed, note } = pruneBackups(deps.state, { protect: args[0], now });
    out(`removed=${removed.length}\nnote=${note}`);
    return 0;
  }
  const ctx = makeContext(deps, Object.assign(loadState(deps.state, now, deps.readText), loadMutes(deps.state, deps.readText)));
  const webhook = readWebhook(deps.state);
  if (command === 'test-message') {
    if (!webhook) { out('No Slack webhook is configured for this installation; nothing was sent.'); return 1; }
    const status = await ctx.post(webhook, testMessage(describe(ctx)));
    out(`Slack answered HTTP ${status}.`);
    return status >= 200 && status < 300 ? 0 : 1;
  }
  const data = ctx.data;
  if (command === 'status') { out(statusLines(ctx, webhook, now).join('\n')); return 0; }
  if (command === 'mute') {
    const minutes = Number(args[0]);
    if (!Number.isFinite(minutes) || minutes <= 0 || minutes > 60 * 24 * 14) { out('mute needs MINUTES (1 to 20160).'); return 1; }
    const until = now + minutes * MIN;
    if (args[1]) {
      if (!ALERT_ID.test(args[1])) { out('Not an alert id.'); return 1; }
      data.mutes[args[1]] = until;
    } else data.muteUntil = until;
    saveMutes(deps.state, data);
    out(`Muted ${args[1] ?? 'all alerts'} until ${new Date(until).toISOString()}.`);
    return 0;
  }
  if (command === 'unmute') {
    if (args[0]) delete data.mutes[args[0]]; else { data.muteUntil = null; data.mutes = {}; }
    saveMutes(deps.state, data);
    out(`Unmuted ${args[0] ?? 'all alerts'}.`);
    return 0;
  }
  out(USAGE);
  return 1;
}

if (isMain(import.meta.url)) {
  const argv = process.argv.slice(2);
  try {
    const helpOnly = !argv[0] || ['--help', '-h', 'help'].includes(argv[0]);
    process.exitCode = await main(argv, helpOnly ? { now: () => Date.now() } : defaultDeps());
  } catch (error) {
    let env = {};
    try { env = readEnv(join(process.env.WAREHOUSE_STATE_DIR ?? '', 'config/compose.env')); } catch { /* no environment */ }
    console.error(`Watch: ${redact(error.message, env)}`);
    process.exitCode = 1;
  }
}
