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
// retention under one operator lock; pruning and retention run whatever the backup and its verify said. A pass runs only
// when the database and the services the backup stops are up; a failed
// pass is tried again after an hour, at most 3 times a day. The daily timer fires at --daily-at and each of the 5 hours
// after it, and a trigger with nothing to do exits at once. `run` and `daily` write different keys of the state file (under
// a lock file: withStateLock). While the pass holds the operator lock `run` keeps the checks that do not need the stopped
// services going (PASS_SAFE_CHECKS) and calls the lock stuck only after the pass's own 4 hours (jobStaleMs).
// An installation whose checker unit is from before the split (it sets WAREHOUSE_WATCH_DAILY_AT) still has the backup inside
// `run`: `run` makes it as it always did, and raises daily_timer_legacy at once, naming the command that installs the daily timer.
// Pruning keeps the newest 7 backup directories of this installation in $STATE/backups; backups made by hand there
// (same name pattern, same instance) count towards those 7. It also always keeps the newest backup on record as verified
// ($STATE/config/backups-verified.list, written by `prune-backups --verified`), however old, so that nights whose verify
// fails (or whose backup is refused) cannot push the last good backup out, and the backup that an interrupted upgrade.sh
// recorded as its way back (config/upgrade-in-progress, read with readUpgradeRecord). It also keeps, for 60 days, the newest
// verified backup of each distinct migration state (the migration_fingerprint= of its integrity.txt): the last copy from before
// each release that changed the schema, which is what a late-found defect is compared against.
// The check restore_space_low warns when the free space of the state's data directory is below what an in-place restore of the
// newest verified backup needs (its stored files again, as scripts/restore.sh checks, plus the database dump that is replayed and
// 1 GiB), because that restore is the way back. It repeats daily, not every 4 hours.
// External heartbeat: if config/heartbeat-url holds an https URL (mode 0600), every successful run of `run` fetches it
// (5 s limit). A service such as healthchecks.io alerts when the pings stop; a failed ping is logged, never alerted.
// Self-healing: while no operator command holds the lock, an `exited` (or `created`) service of the default profile is started
// again and one `unhealthy` for 3 runs in a row is restarted, at most once an hour and 6 times in 24 hours each (selfHeal); a
// muted service is left alone, and nothing is done while config/stopped-by-operator exists (stop.sh writes it, start.sh removes it) or
// while config/upgrade-in-progress exists (a service restarted then could run the new release's code on a half-migrated schema).
// Mute before a deliberate stop.sh: a stopped service is an alert like any other.
// Upgrades: upgrade.sh holds the operator lock for a backup, its verification and the migrations, so while config/upgrade-in-progress exists the
// lock is called stuck only after max(2 hours, twice the time of the last backup plus the last verify) (upgradeStuckMs, at most a day); and
// once the lock is free again with the record still there, the upgrade did not finish: `upgrade_interrupted` is raised at once and is never muted.
import { spawn, spawnSync } from 'node:child_process';
import { closeSync, fsyncSync, lstatSync, openSync, readdirSync, readFileSync, renameSync, rmSync, statSync, statfsSync, unlinkSync, writeSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { join, resolve } from 'node:path';
import { isMain } from './is-main.mjs';
import { RECORD_FILE, interruptedUpgradeWarning, readUpgradeRecord } from './upgrade-record.mjs';
import { centralKeyFault, gatewayPortText, letterheadProblem, readEnv, root as checkoutRoot } from './doctor-common.mjs';
import { LAN_SERVICE, describeAddresses, hostHasAddress, lanOrigin, lanSettings, probeLanKeys, readHostInterfaces } from './lan-common.mjs';
import { redactServiceLog } from './service-diagnostics.mjs';
import { usbBackupWarning } from './usb-backup-status.mjs';
import { postSlackMessage, storedWebhook, testMessage } from './alert-webhook.mjs';

const MIN = 60 * 1000;
const HOUR = 60 * MIN;
const DAY = 24 * HOUR;
// Thresholds are those of the Prometheus alert rules this checker replaced (docs/MONITORING.md lists them).
export const LIMITS = {
  cpuPercent: 80, memoryPercent: 85, diskRootFreePercent: 20, diskOtherFreePercent: 10,
  dbConnections: 80, txSeconds: 300, cacheHitRatio: 0.9, cacheMinBlocks: 10000, deadTuples: 100000,
  containerMemoryRatio: 0.9, restartsPerHour: 3, oomHoldMs: HOUR,
  errorRate: 0.05, latencySeconds: 2, minRequests: 10, backupMaxAgeMs: 26 * HOUR,
  failingRuns: 2, repeatMs: 4 * HOUR, busyGiveUpMs: 2 * HOUR, keepBackups: 7,
  // Pruning also keeps the newest verified backup of each migration state this long (by the backup's own date); restore.sh needs the
  // stored files of the backup again plus this much free space.
  keepMigrationStateMs: 60 * DAY, restoreReserveBytes: 1024 ** 3,
  // A daily pass in progress older than this is taken as interrupted (the unit stops after 4 h).
  jobStaleMs: 4 * HOUR, dailyWindowMs: 6 * HOUR, dailyAttempts: 3,
  // "An hour" less 2 minutes: the daily timer fires on the hour, and a start a few seconds late must not push a retry
  // to the trigger after.
  dailyRetryMs: HOUR - 2 * MIN, dailyHardMs: 3 * HOUR + 45 * MIN,
  futureBackupMs: HOUR,
  // Rate limiting: more than 2% of the gateway's requests in 5 minutes answered 429 (judged from 50 requests up), or more
  // than 20 of them whatever the total. SMS, checked every hour: more than 20% of the last 24 hours' code requests (judged from
  // 10 requests up) or more than 10 of them were not accepted by the provider, or at least half of the last hour's (from 5
  // requests up). Clock: more than 10 s from the public address's own clock.
  rateLimitedShare: 0.02, rateLimitedMinRequests: 50, rateLimitedCount: 20,
  // The gateway log read: the last gatewayLogTail lines, cut to the last gatewayLogWindowMs by their time stamps.
  gatewayLogTail: 5000, gatewayLogWindowMs: 5 * MIN,
  smsFailedShare: 0.2, smsFailedCount: 10, smsMinSends: 10, smsHourShare: 0.5, smsHourMinSends: 5, smsEveryMs: HOUR - 2 * MIN,
  clockOffsetMs: 10000,
  // Self-healing: a service unhealthy in this many runs in a row is restarted; no service is acted on more than once per gap,
  // nor more than healMaxPerDay times in any 24 hours (after that the checker only alerts).
  healUnhealthyRuns: 3, healGapMs: HOUR, healMaxPerDay: 6,
  // The state file's lock: how long a save waits for the other process, and when a lock file left by a crash is taken over.
  stateLockWaitMs: 10000, stateLockStaleMs: MIN,
};
export const OPTIONAL_SERVICES = ['supavisor', 'cups', 'sensor-bridge'];
export const BACKUP_DIR_PATTERN = /^warehouse-\d{8}T\d{6}Z$/;
const TIME_OF_DAY = /^([01]\d|2[0-3]):([0-5]\d)$/;
const DEFAULT_DAILY_AT = '02:30';
const DEFAULT_HEARTBEAT_AT = '09:00';
const ALERT_ID = /^[a-z_]+(:[\w/. -]+)?$/;
// An installation updated from before the daily backup got its own timer still has a checker unit that sets
// WAREHOUSE_WATCH_DAILY_AT (the time of the pass that then ran inside `run`). Only such a unit sets it for `run`: the checker
// unit written now does not (the daily unit does, for `watch.mjs daily`). The text names the one command that ends this state.
export const LEGACY_DAILY_ALERT = 'daily_timer_legacy';
export const legacyDailyAdvice = (root, state) => `Run: sudo bash ${join(root, 'scripts/watch-timer.sh')} install --state ${state}`;

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
  memoryNote: null, heal: {}, lastSmsCheck: null,
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
  take('lastSmsCheck', numOrNull);
  take('heal', v => isObj(v) && Object.values(v).every(x => isObj(x) && isNum(x.unhealthyRuns) && numOrNull(x.lastAt) && typeof x.lastAction === 'string'
    && (x.actions === undefined || (Array.isArray(x.actions) && x.actions.every(isNum)))));
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
// The read, the merge and the rename (with its fsync, which can take seconds while a backup is writing) happen under a lock
// file, config/watch-state.lock, made with O_EXCL: without it a save that read the file just before the other process renamed
// its own would write the old values of the other's keys back (a lost `dailyRunning` clear blocks the next passes for 4 hours;
// a lost alert mark posts a message twice). The holder's pid is in the file; a lock whose process is gone, or that is older
// than stateLockStaleMs, is taken over. A save that cannot get the lock in stateLockWaitMs, or where no lock file can be made,
// goes ahead without it: monitoring must not stop because of a lock file.
export const stateLockPath = state => join(state, 'config/watch-state.lock');
const sleepSync = ms => Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);
function lockIsStale(path, staleMs) {
  try {
    if (Date.now() - lstatSync(path).mtimeMs > staleMs) return true;
    const pid = Number.parseInt(readFileSync(path, 'utf8'), 10);
    if (Number.isInteger(pid) && pid > 0) { try { process.kill(pid, 0); } catch (error) { return error.code === 'ESRCH'; } }
    return false;
  } catch { return false; }   // gone or unreadable: the next attempt takes it or waits
}
export function withStateLock(state, fn, { waitMs = LIMITS.stateLockWaitMs, staleMs = LIMITS.stateLockStaleMs, sleep = sleepSync } = {}) {
  const path = stateLockPath(state);
  const started = Date.now();
  let held = false;
  for (;;) {
    try {
      const fd = openSync(path, 'wx', 0o600);
      held = true;
      try { writeSync(fd, `${process.pid}\n`); } finally { closeSync(fd); }
      break;
    } catch (error) {
      if (held || error.code !== 'EEXIST') break;   // no lock file is possible here (read-only, no directory): go ahead without one
    }
    if (lockIsStale(path, staleMs)) { try { unlinkSync(path); } catch { /* the other process was quicker */ } continue; }
    if (Date.now() - started >= waitMs) break;
    sleep(25);
  }
  try { return fn(); } finally { if (held) { try { unlinkSync(path); } catch { /* already taken over */ } } }
}
export const DAILY_KEYS = ['lastDailyRun', 'dailyAttempt', 'dailyRunning', 'dailySkipped'];
export function saveState(state, data, api, { daily = false, readText = readFileOrNull, lock = {} } = {}) {
  const { muteUntil, mutes, ...persisted } = data;
  withStateLock(state, () => {
    const onDisk = readText(statePath(state));
    if (onDisk !== null) {
      try {
        const other = normalizeState(JSON.parse(onDisk), 0, () => {});
        for (const key of Object.keys(persisted)) if (DAILY_KEYS.includes(key) !== daily) persisted[key] = other[key];
      } catch { /* an unreadable file is replaced by ours */ }
    }
    writeFileAtomic(statePath(state), `${JSON.stringify(persisted, null, 2)}\n`, api);
  }, lock);
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
    // The host's IPv4 addresses (the LAN fallback check), replaceable for tests.
    interfaces: () => readHostInterfaces(env),
    usbEtc: env.WAREHOUSE_USB_BACKUP_ETC || '/etc',
    usbLibexec: env.WAREHOUSE_USB_BACKUP_LIBEXEC || '/usr/local/libexec',
    unitDir: env.WAREHOUSE_WATCH_UNIT_DIR || '/etc/systemd/system',
    tunnelUnitDir: env.WAREHOUSE_TUNNEL_UNIT_DIR || '/etc/systemd/system',
    nodeVersion: process.version,
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
    return result('services', `service_down:${name}`, ok, `Service ${name} is ${state}`, '', { running: c?.status === 'running' });
  });
}

// ---------------------------------------------------------------- API
async function getJson(ctx, url) {
  const response = await ctx.fetch(url, { signal: AbortSignal.timeout(15000), redirect: 'error' });
  if (!response.ok) throw new Error(`HTTP ${response.status}`);
  return response.json();
}
export async function checkApiLocal(ctx) {
  const port = gatewayPortText(ctx.env_());
  if (!/^\d+$/.test(port ?? '')) throw new Error('GATEWAY_HTTP_PORT is not set in compose.env');
  try { await getJson(ctx, `http://127.0.0.1:${port}/functions/v1/get-public-config`); return [result('api_local', 'api_down', true, 'API gateway answers')]; }
  catch (error) { return [result('api_local', 'api_down', false, 'API gateway is not answering on this host', error.message)]; }
}
const publicManifest = ctx => {
  const manifest = JSON.parse(ctx.readText(join(ctx.state, 'public/instance.json')) ?? 'null');
  if (!manifest?.canonicalOrigin) throw new Error('public/instance.json has no canonicalOrigin');
  return manifest;
};
export async function checkApiPublic(ctx) {
  const manifest = publicManifest(ctx);
  try {
    const json = await getJson(ctx, `${manifest.canonicalOrigin}/functions/v1/get-public-config`);
    if (json.success !== true || json.data?.instanceId !== manifest.instanceId) {
      return [result('api_public', 'public_https_down', false, 'The public address answers, but not as this installation', 'instanceId differs.')];
    }
    return [result('api_public', 'public_https_down', true, 'Public HTTPS address works')];
  } catch (error) { return [result('api_public', 'public_https_down', false, 'The public HTTPS address does not work (tunnel or DNS)', error.message)]; }
}
// The LAN fallback (scripts/lan.sh), only while it is on: the host must still have the address the container publishes on (the router
// may hand it another one: `lan_ip_changed`), and that address must answer the public configuration as this installation with the
// header that says the LAN listener answered, and must accept the installation's anon key on the REST route (probeLanKeys: get-public-config
// has no key check, and a container that was not recreated after a key rotation refuses every REST request of every phone while it is
// still green) (`lan_http_down`, after two failing runs like the other API checks). Silent while the fallback is off: nothing is returned,
// so an alert left over from before it was turned off is cleared.
export async function checkApiLan(ctx) {
  const lan = lanSettings(ctx.env_());
  if (!lan.enabled) return [];
  const interfaces = (ctx.interfaces ?? (() => readHostInterfaces()))();
  if (!hostHasAddress(interfaces, lan.ip)) {
    return [
      result('api_lan', 'lan_ip_changed', false, `The LAN address ${lan.ip} is no longer an address of this host`,
        `The host has ${describeAddresses(interfaces)}. Phones cannot reach ${lanOrigin(lan)} and the gateway-lan service is not started; the app keeps working over the internet. Run bash scripts/lan.sh on auto (docs/TROUBLESHOOTING.md, "The app says the LAN address is unreachable").`),
      result('api_lan', 'lan_http_down', true, 'The LAN listener is not probed (its address is gone)'),
    ];
  }
  const manifest = publicManifest(ctx);
  const down = (summary, detail) => [result('api_lan', 'lan_ip_changed', true, `The host still has ${lan.ip}`), result('api_lan', 'lan_http_down', false, summary, detail)];
  try {
    const response = await ctx.fetch(`${lanOrigin(lan)}/functions/v1/get-public-config`, { signal: AbortSignal.timeout(15000), redirect: 'error' });
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    const json = await response.json();
    if (json.success !== true || json.data?.instanceId !== manifest.instanceId) return down('The LAN address answers, but not as this installation', 'instanceId differs.');
    if (response.headers?.get('x-warehouse-path') !== 'lan') return down('The LAN address answers, but not from the gateway-lan listener', 'The header X-Warehouse-Path: lan is missing.');
    const keys = await probeLanKeys(lan, ctx.env_().ANON_KEY, (url, options) => ctx.fetch(url, options));
    if (!keys.ok) return down('The LAN listener does not accept this installation\'s API key', keys.text);
    return [result('api_lan', 'lan_ip_changed', true, `The host still has ${lan.ip}`), result('api_lan', 'lan_http_down', true, `LAN fallback answers on ${lanOrigin(lan)}`)];
  } catch (error) { return down(`The LAN fallback does not answer on ${lanOrigin(lan)}`, `${error.cause?.code ?? error.message} (bash scripts/lan.sh status)`); }
}
// `sinceMs` (an epoch time) keeps only the lines that `docker logs -t` stamped at or after it: each such line starts with an
// RFC 3339 time with nanoseconds ("2026-10-19T10:00:00.123456789Z "). A line with no readable stamp is kept (it cannot be placed).
export function parseGatewayLog(text, { sinceMs = null } = {}) {
  const rows = [];
  for (const line of text.split('\n')) {
    const m = line.match(/\[[^\]]+\] "[A-Z]+ \S+ [^"]*" (\d{3}) \d+ ([\d.]+)\s*$/);
    if (!m) continue;
    if (sinceMs !== null) {
      const stamp = Date.parse((/^(\d{4}-\d{2}-\d{2}T\S+) /.exec(line) ?? [])[1] ?? '');
      if (Number.isFinite(stamp) && stamp < sinceMs) continue;
    }
    rows.push({ status: Number(m[1]), seconds: Number(m[2]) });
  }
  return rows;
}
// The gateway's last 5 minutes. `docker logs --since` is not used: on a Dev host (Docker 29.9.1) it returned no line at all for
// any window up to an hour while `--tail` and `--since 24h` worked, which would have made every rate below read "too few requests"
// for good. The last gatewayLogTail lines are read with their time stamps (-t) and cut to the window here. A gateway busier than
// about 16 requests a second fills the tail with less than 5 minutes, and the rates are then those of the newest lines.
// The LAN fallback's container (gateway-lan) writes the same log format, and its requests count in the same rates: a phone that
// is refused on the warehouse network is as much a fault as one refused through the tunnel.
export function checkApiLogs(ctx) {
  const all = ctx.containers();
  const gateways = ['gateway', 'gateway-lan'].map(name => all.find(c => c.service === name)).filter(Boolean);
  if (!gateways.length) return [];
  const rows = [];
  for (const gateway of gateways) {
    const logs = ctx.run('docker', ['logs', '-t', '--tail', String(LIMITS.gatewayLogTail), gateway.id]);
    if (logs.status !== 0) throw new Error(`docker logs failed for the ${gateway.service}`);
    rows.push(...parseGatewayLog(`${logs.stdout}\n${logs.stderr}`, { sinceMs: ctx.now() - LIMITS.gatewayLogWindowMs }));
  }
  if (rows.length < LIMITS.minRequests) {
    return [result('api_logs', 'api_error_rate_high', true, `Too few requests (${rows.length}) to judge the error rate`), result('api_logs', 'api_latency_p95_high', true, 'Too few requests to judge latency'),
      result('api_logs', 'api_429_rate_high', true, 'Too few requests to judge the rate-limit answers')];
  }
  const errors = rows.filter(r => r.status >= 500).length / rows.length;
  // 429 is the gateway's rate limit (or the function's own, such as the OTP limit): a few are normal, a share of the
  // traffic means a client or a whole Wi-Fi is being refused.
  const limited = rows.filter(r => r.status === 429).length;
  const limitedShare = limited / rows.length;
  const limitedBad = limited > LIMITS.rateLimitedCount || (rows.length >= LIMITS.rateLimitedMinRequests && limitedShare > LIMITS.rateLimitedShare);
  const sorted = rows.map(r => r.seconds).sort((a, b) => a - b);
  const p95 = sorted[Math.min(sorted.length - 1, Math.ceil(sorted.length * 0.95) - 1)];
  return [
    result('api_logs', 'api_error_rate_high', !(errors > LIMITS.errorRate), `API 5xx rate ${(errors * 100).toFixed(1)}% over ${rows.length} requests (limit ${LIMITS.errorRate * 100}%)`),
    result('api_logs', 'api_latency_p95_high', !(p95 > LIMITS.latencySeconds), `API p95 latency ${p95.toFixed(2)} s over ${rows.length} requests (limit ${LIMITS.latencySeconds} s)`),
    result('api_logs', 'api_429_rate_high', !limitedBad, `API answered 429 (too many requests) to ${limited} of ${rows.length} requests, ${(limitedShare * 100).toFixed(1)}% (limit ${LIMITS.rateLimitedShare * 100}% or ${LIMITS.rateLimitedCount} in 5 minutes)`,
      'One client, or every phone on one Wi-Fi, is being refused: see "Too many requests" in docs/TROUBLESHOOTING.md.'),
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
// container that shares a network with the gateway: the intended project is probed, never an unrelated server on the host port). The
// gateway probe is a public-configuration call and the anon-callable RPC get_public_config (it reads the database, and answers 200 with
// null when the environment is not seeded; PostgREST's OpenAPI document at /rest/v1/ is off, PGRST_OPENAPI_MODE=disabled); a container can be healthy before the gateway answers after a recreate, so it retries for
// up to waitMs. Returns { ok, lines: [{ ok, text }] }.
const GATEWAY_PROBES = `
for (const [name, url, headers, init] of [
  ['REST', 'http://gateway:8000/rest/v1/rpc/get_public_config', { apikey: process.env.ANON_KEY, 'Content-Type': 'application/json' },
    { method: 'POST', body: JSON.stringify({ p_environment: 'production' }) }],
  ['configuration', 'http://gateway:8000/functions/v1/get-public-config', {}, {}],
]) {
  try { await waitForHttp(name, url, headers, { timeoutMs: WAIT_MS, init }); console.log('OK ' + name); }
  catch (error) { console.log('FAILED ' + error.message); process.exitCode = 1; }
}
`;
export function gatewayProbe(ctx, waitMs) {
  // Maintenance mode answers 503 "upgrading" to both of these on purpose (and setup of an upgrade ends with this check while it is on): they cannot be
  // probed, so it is said, as a warning that passes. scripts/maintenance.sh off runs this check again once the API is open.
  if (ctx.state && maintenanceMarked(ctx.state)) {
    return [{ ok: true, warn: true, text: 'Gateway: maintenance mode is on (config/maintenance), so the API answers 503 "upgrading" on purpose and REST and the public configuration were not probed through it. bash scripts/maintenance.sh off opens it and runs this check' }];
  }
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
  // The LAN fallback (gateway-lan, profile lan) is expected while compose.env turns it on, but it is the fallback: a fault of it is a warning
  // here like an optional service's, never a failure, so a start, a setup, an upgrade, a restore or a key rotation is not stopped by it.
  const expected = ctx.expectedServices();
  for (const r of checkServices(ctx)) {
    const name = r.id.replace(/^service_down:/, '');
    if (expected.includes(name) && (name !== LAN_SERVICE || r.ok)) add(r.ok, r.summary);
    else if (!r.ok) lines.push({ ok: true, warn: true, text: r.summary });
  }
  const databaseOk = databaseReady(ctx);
  add(databaseOk, databaseOk ? 'PostgreSQL accepts connections' : 'PostgreSQL is not accepting connections');
  for (const line of gatewayProbe(ctx, waitMs)) { if (line.warn) lines.push(line); else add(line.ok, line.text); }
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

// Room for the way back. The way back from an upgrade is `db:restore` of the backup the upgrade took: it keeps the data it replaces and
// copies the stored files in again, so scripts/restore.sh refuses unless the free space holds them plus 1 GiB, and only after it has been
// started; the database is then replayed from the dump, which takes room too. This says it in advance: below the sum of the three (the
// stored files, the size of database.dump as a stand-in for the replayed database, 1 GiB), the way back would not fit. It is a minimum:
// the photos added since that backup and the images a release builds come on top. Judged against the newest verified backup, on the
// filesystem of the state's data directory; no verified backup yet, nothing to compare. Not run while the daily pass holds the lock (the
// pass's own copy takes space for a while); a facility with room is never told anything. It repeats once a day (repeatHours), because
// a facility that cannot add disk at once has nothing to do about it every 4 hours.
export function checkRestoreSpace(ctx) {
  const newest = newestVerifiedBackup(ctx.state);
  if (!newest) return [];
  const stat = ctx.statfs(join(ctx.state, 'data'));
  const free = Number(stat.bavail) * Number(stat.bsize);
  if (!Number.isFinite(free)) throw new Error('could not read the free space of the data directory');
  const need = newest.bytes + newest.dumpBytes + LIMITS.restoreReserveBytes;
  const gib = bytes => (bytes / 1024 ** 3).toFixed(1);
  return [result('restore_space', 'restore_space_low', free >= need,
    `Free space in data/ is ${gib(free)} GiB, and an in-place restore of ${newest.name} needs ${gib(need)} GiB (its stored files, ${gib(newest.bytes)} GiB, ${newest.dumpBytes ? `its database dump, ${gib(newest.dumpBytes)} GiB, ` : ''}plus 1 GiB)`,
    'The way back from an upgrade is an in-place restore, which copies the stored files in again and replays the database while it keeps the replaced ones; this is a minimum (the photos added since that backup and any new images come on top). Free space (the data/*.pre-restore-* directories of restores you have accepted, backups you no longer need) or add disk: docs/OPERATOR_INSTALL.md, "Disk space".',
    { repeatHours: 24 })];
}

// ---------------------------------------------------------------- SMS delivery, break-glass, clock
// The sign-in codes of the last 24 hours (public.otp_verifications): `delivery_status` is 'accepted' when MSG91 took the
// request, 'failed' when it refused it (balance, DLT header, sender ID, template) or the request expired, and 'sending' until
// the function has an answer. A request still 'sending' after 5 minutes never got one and counts as not accepted; younger
// ones are in flight and are left out. Alerts when more than 20% of at least 10 requests of the last 24 hours, or more than 10
// of them, were not accepted, or when at least half of at least 5 requests of the last hour were not. This sees explicit
// refusals and lost answers; a code the provider accepted and then dropped (a DLT suspension after acceptance) is silent here
// and shows as users reporting that no code arrives.
// Once an hour (not once a day: a balance that lapsed during the Monday sign-in wave must be told in the hour, not the next
// morning), and the alert is immediate: its next judgement is an hour away.
const SMS_SQL = `SELECT count(*) FILTER (WHERE delivery_status IS DISTINCT FROM 'accepted'), count(*),
  count(*) FILTER (WHERE delivery_status IS DISTINCT FROM 'accepted' AND created_at > now() - interval '1 hour'),
  count(*) FILTER (WHERE created_at > now() - interval '1 hour')
  FROM public.otp_verifications
  WHERE created_at > now() - interval '24 hours' AND NOT (delivery_status = 'sending' AND created_at > now() - interval '5 minutes')`;
export function smsCheckDue(now, last) {
  return last === null || last === undefined || now < last || now - last >= LIMITS.smsEveryMs;
}
export function checkSmsDelivery(ctx) {
  const now = ctx.now();
  if (!smsCheckDue(now, ctx.data.lastSmsCheck)) return null;   // not due: its alert, if any, stays as it is
  if (!databaseReady(ctx)) return null;                       // postgres_down says so; try again next run
  const q = ctx.compose(['exec', '-T', '-e', 'PGOPTIONS=-c statement_timeout=10000', 'db', 'psql', '-X', '-qAt', '-F', '|',
    '-v', 'ON_ERROR_STOP=1', '-U', 'supabase_admin', '-d', 'postgres', '-c', SMS_SQL]);
  if (q.status !== 0) throw new Error(`SMS delivery query failed: ${clip(q.stderr.trim(), 200)}`);
  const [failed, sends, hourFailed, hourSends] = q.stdout.trim().split('\n').pop().split('|').map(Number);
  if (![failed, sends, hourFailed, hourSends].every(Number.isInteger)) throw new Error('unexpected SMS delivery query output');
  ctx.data.lastSmsCheck = now;
  const share = sends ? failed / sends : 0;
  const dayBad = failed > LIMITS.smsFailedCount || (sends >= LIMITS.smsMinSends && share > LIMITS.smsFailedShare);
  const hourBad = hourSends >= LIMITS.smsHourMinSends && hourFailed / hourSends >= LIMITS.smsHourShare;
  const summary = hourBad && !dayBad
    ? `${hourFailed} of ${hourSends} sign-in code requests in the last hour were not accepted by the SMS provider (limit ${LIMITS.smsHourShare * 100}% from ${LIMITS.smsHourMinSends} requests)`
    : `${failed} of ${sends} sign-in code requests in the last 24 hours were not accepted by the SMS provider (limit ${LIMITS.smsFailedShare * 100}% or ${LIMITS.smsFailedCount})`;
  return [result('sms_delivery', 'sms_delivery', !(dayBad || hourBad), summary,
    'Check the MSG91 balance, DLT template and sender ID: docs/TROUBLESHOOTING.md, "SMS codes not arriving".', { immediate: true })];
}

// The break-glass administrator sign-in (migration 126, scripts/break-glass-admin.sh): issuing a code and signing in with one
// each write a public.audit_log row with table_name 'break_glass' and the action CODE_ISSUED or SIGN_IN (the code is never
// written; new_data holds the number, which this check does not read). It is a way past the SMS code, so any use of it in the
// last 24 hours is told at once. A database without that migration has no such rows: the check passes.
const BREAK_GLASS_SQL = `SELECT count(*), COALESCE(string_agg(DISTINCT action, ',' ORDER BY action), ''),
  COALESCE(to_char(max(created_at) AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'), '')
  FROM public.audit_log
  WHERE table_name = 'break_glass' AND action IN ('CODE_ISSUED', 'SIGN_IN') AND created_at > now() - interval '24 hours'`;
export function checkBreakGlass(ctx) {
  if (!databaseReady(ctx)) return null;   // postgres_down says so
  const q = ctx.compose(['exec', '-T', '-e', 'PGOPTIONS=-c statement_timeout=10000', 'db', 'psql', '-X', '-qAt', '-F', '|',
    '-v', 'ON_ERROR_STOP=1', '-U', 'supabase_admin', '-d', 'postgres', '-c', BREAK_GLASS_SQL]);
  if (q.status !== 0) throw new Error(`break-glass query failed: ${clip(q.stderr.trim(), 200)}`);
  const [count, actions = '', latest = ''] = q.stdout.trim().split('\n').pop().split('|');
  if (!/^\d+$/.test(count ?? '')) throw new Error('unexpected break-glass query output');
  const rows = Number(count);
  return [result('break_glass', 'break_glass_used', rows === 0,
    rows ? `A break-glass administrator sign-in was used in the last 24 hours (${rows} audit row${rows === 1 ? '' : 's'}: ${actions.replaceAll(',', ', ')}; latest ${latest || 'unknown'})`
      : 'No break-glass sign-in in the last 24 hours',
    'Someone with shell access made a one-time administrator code (scripts/break-glass-admin.sh) or signed in with one. Check that it was you or your staff: docs/MONITORING.md, "Break-glass sign-in".', { immediate: true })];
}

// The host clock: systemd's own verdict (NTPSynchronized) and, when the public address answers, the difference from the
// clock of the address's edge. Central sign-in refuses a token when the clock is over 30 s off (docs/CENTRAL_LOGIN.md); backup
// names and the 26 h backup rule use it too. The reference is Cloudflare's own `ts=` line of <origin>/cdn-cgi/trace, which the
// edge answers itself (the request never reaches the gateway: no log line, no rate-limit budget, and the answer does not come from
// this host's clock). An address that is not behind Cloudflare has no such page: the Date header of a HEAD to the function
// route is the fallback (it may be passed through from the origin, so it can hide a wrong clock). An unreachable address or
// a host without timedatectl is not judged here (public_https_down says the first).
async function publicClockOffset(ctx, origin) {
  try {
    const before = ctx.now();
    const response = await ctx.fetch(`${origin}/cdn-cgi/trace`, { signal: AbortSignal.timeout(15000), redirect: 'error' });
    const after = ctx.now();
    if (response.ok) {
      const ts = Number(/^ts=(\d+(?:\.\d+)?)$/m.exec(String(await response.text?.() ?? ''))?.[1]);
      if (Number.isFinite(ts)) return (before + after) / 2 - ts * 1000;
    }
  } catch { /* not behind Cloudflare, or not reachable: the Date header is tried */ }
  try {
    const before = ctx.now();
    const response = await ctx.fetch(`${origin}/functions/v1/get-public-config`, { method: 'HEAD', signal: AbortSignal.timeout(15000), redirect: 'error' });
    const after = ctx.now();
    const served = Date.parse(response.headers?.get?.('date') ?? '');
    if (Number.isFinite(served)) return (before + after) / 2 - served;
  } catch { /* not reachable: the public check reports it */ }
  return null;
}
export async function checkClock(ctx) {
  const problems = [];
  const ntp = ctx.run('timedatectl', ['show', '-p', 'NTPSynchronized', '--value'], { timeoutMs: 10000 });
  if (ntp.status === 0 && ntp.stdout.trim() === 'no') problems.push('the system clock is not synchronised with a time server (timedatectl: NTPSynchronized=no)');
  let offset = null;
  try { offset = await publicClockOffset(ctx, publicManifest(ctx).canonicalOrigin); } catch { /* no manifest: the public check reports it */ }
  if (offset !== null && Math.abs(offset) > LIMITS.clockOffsetMs) {
    problems.push(`the host clock is ${Math.round(Math.abs(offset) / 1000)} s ${offset < 0 ? 'behind' : 'ahead of'} the public address's clock`);
  }
  const state = [ntp.status === 0 ? `NTPSynchronized=${ntp.stdout.trim()}` : 'NTP status unknown', offset === null ? 'no offset reading' : `offset ${(offset / 1000).toFixed(1)} s`].join(', ');
  return [result('clock', 'clock_unsynced', problems.length === 0,
    problems.length ? `The host clock may be wrong: ${problems.join('; ')}` : `Host clock fine (${state})`,
    'Central sign-in refuses tokens when the clock is over 30 s off. Fix: timedatectl set-ntp true (docs/TROUBLESHOOTING.md, "Monitoring and Slack alerts").')];
}

// ---------------------------------------------------------------- host drift: cloudflared, Node.js, root-installed copies
// Three things on the host that nothing in this repository updates by itself and that fail quietly. Weekly (repeatHours 168):
// nothing here is urgent on the day it is told, and none of it calls the network.
export const HOST_DRIFT_REPEAT_HOURS = 168;
// Cloudflare supports only versions within a year of its newest release (docs/OPERATOR_INSTALL.md, "Monthly host maintenance"); the
// alert comes one month before that.
export const CLOUDFLARED_MAX_AGE_MONTHS = 11;
// End of security support of each Node.js major the host may run (https://nodejs.org/en/about/previous-releases); docs/MAINTENANCE_CALENDAR.md
// cites this table. 22 is the oldest major scripts/doctor-common.mjs accepts.
export const NODE_END_OF_LIFE = { 22: '2027-04-30', 24: '2028-04-30', 26: '2029-04-30' };
export const NODE_WARN_DAYS = 60;

// "cloudflared version 2025.11.1 (built 2025-11-26-1412 UTC)" -> the build date; the version's year and month when there is no build date.
export function cloudflaredReleased(text) {
  const built = /\(built (\d{4})-(\d{2})-(\d{2})/.exec(text);
  if (built) return Date.UTC(+built[1], +built[2] - 1, +built[3]);
  const version = /version (\d{4})\.(\d{1,2})\./.exec(text);
  return version ? Date.UTC(+version[1], +version[2] - 1, 1) : null;
}
const addMonths = (ms, months) => { const d = new Date(ms); d.setUTCMonth(d.getUTCMonth() + months); return d.getTime(); };
const isoDay = ms => new Date(ms).toISOString().slice(0, 10);

// The tunnel's unit (scripts/tunnel.sh names it warehouse-<state directory name>-tunnel.service): when it runs, the process must be the
// binary on disk. A package upgrade replaces the file and leaves the running process on the old one ("(deleted)" on its /proc exe link; the
// file is also newer than the process start), and with --no-autoupdate nothing restarts it. Null when there is nothing to judge.
function cloudflaredRestartDue(ctx) {
  const unit = `warehouse-${ctx.state.split('/').filter(Boolean).pop()}-tunnel.service`;
  const shown = ctx.run('systemctl', ['show', unit, '--timestamp=unix', '-p', 'ActiveState', '-p', 'ActiveEnterTimestamp', '-p', 'MainPID'], { timeoutMs: 10000 });
  if (shown.status !== 0) return null;
  const f = fieldsOf(shown.stdout);
  const pid = Number(f.MainPID);
  const started = Number(/^@(\d+)$/.exec(f.ActiveEnterTimestamp ?? '')?.[1]) * 1000;
  if (f.ActiveState !== 'active' || !Number.isInteger(pid) || pid <= 0 || !Number.isFinite(started)) return null;
  const exe = ctx.run('readlink', [join(ctx.proc, String(pid), 'exe')], { timeoutMs: 5000 });
  if (exe.status === 0 && /\(deleted\)\s*$/.test(exe.stdout)) return `${unit} still runs the cloudflared that was replaced on disk`;
  const mtime = ctx.run('stat', ['-L', '-c', '%Y', ctx.cloudflared ?? '/usr/bin/cloudflared'], { timeoutMs: 5000 });
  const changed = Number(mtime.stdout.trim()) * 1000;
  if (mtime.status === 0 && Number.isFinite(changed) && changed > started) return `${unit} started before the cloudflared on disk was installed`;
  return null;
}
export function checkCloudflared(ctx) {
  const now = ctx.now();
  const version = ctx.run(ctx.cloudflared ?? '/usr/bin/cloudflared', ['--version'], { timeoutMs: 10000 });
  if (version.status !== 0) return [result('cloudflared', 'cloudflared_old', true, 'cloudflared is not installed here')];   // another host runs the tunnel, or none
  const text = `${version.stdout}\n${version.stderr}`;
  const released = cloudflaredReleased(text);
  if (released === null) throw new Error(`cloudflared --version said something this check does not know: ${clip(text.trim(), 120)}`);
  const problems = [];
  if (now >= addMonths(released, CLOUDFLARED_MAX_AGE_MONTHS)) problems.push(`this cloudflared was released on ${isoDay(released)}; Cloudflare supports only versions within a year of its newest, and the tunnel runs with --no-autoupdate`);
  const restart = cloudflaredRestartDue(ctx);
  if (restart) problems.push(`${restart}: restart it`);
  return [result('cloudflared', 'cloudflared_old', problems.length === 0,
    problems.length ? `cloudflared needs attention: ${problems.join('; ')}` : `cloudflared released ${isoDay(released)} and running`,
    'Monthly host maintenance (docs/OPERATOR_INSTALL.md): sudo apt update && sudo apt install --only-upgrade cloudflared, then sudo systemctl restart the tunnel unit.', { repeatHours: HOST_DRIFT_REPEAT_HOURS })];
}

export function checkHostNode(ctx) {
  const now = ctx.now();
  const major = Number(/^v?(\d+)\./.exec(ctx.nodeVersion ?? process.version)?.[1]);
  const end = NODE_END_OF_LIFE[major];
  if (!end) return [result('host_node', 'host_node_eol', true, `Node.js ${major} has no end date recorded here`)];
  const endMs = Date.parse(`${end}T00:00:00Z`);
  const days = Math.ceil((endMs - now) / DAY);
  return [result('host_node', 'host_node_eol', days > NODE_WARN_DAYS,
    days >= 0 ? `Node.js ${major} on this host reaches its end of life on ${end} (${days} days)` : `Node.js ${major} on this host reached its end of life on ${end}`,
    'Install the next even-numbered Node.js major and point the checker at it: sudo bash scripts/watch-timer.sh install --state <state> --node /absolute/path/to/node (docs/OPERATOR_INSTALL.md, "Monthly host maintenance"; docs/MAINTENANCE_CALENDAR.md).', { repeatHours: HOST_DRIFT_REPEAT_HOURS })];
}

// Copies that root runs and that setup writes: the USB backup helper, its udev rule and units (scripts/backup-usb.sh) and the
// monitoring units (scripts/watch-timer.sh). Each file records the sha256 of the script that rendered it ("# Recipe: sha256:..."); the
// helper is a byte copy of its script. A copy whose recipe is not this checkout's script (or is absent: written by an earlier release)
// is stale, and the repair is the command that wrote it. Files that are not installed for this state are not judged.
const RECIPE = /^# Recipe: sha256:([0-9a-f]{64})$/m;
const sha256 = text => createHash('sha256').update(text).digest('hex');
export function checkRootCopies(ctx) {
  const scriptHash = name => { const text = ctx.readText(join(ctx.root, 'scripts', name)); return text === null ? null : sha256(text); };
  const stale = [];
  const fixes = [];
  const judge = (path, wanted, kind, fix, byContent = false) => {
    const text = ctx.readText(path);
    if (text === null || wanted === null) return;
    const have = byContent ? sha256(text) : RECIPE.exec(text)?.[1];
    if (have !== wanted) { stale.push(path); if (!fixes.includes(fix)) fixes.push(fix); }
  };
  const usbEtc = ctx.usbEtc ?? '/etc';
  const conf = ctx.readText(join(usbEtc, 'warehouse-usb-backup.conf'));
  if (conf !== null && fieldsOf(conf).STATE === ctx.state) {
    const wanted = scriptHash('backup-usb.sh');
    const fix = `sudo bash ${join(ctx.root, 'scripts/backup-usb.sh')} setup --state ${ctx.state}`;
    judge(join(ctx.usbLibexec ?? '/usr/local/libexec', 'warehouse-usb-backup'), wanted, 'helper', fix, true);
    judge(join(usbEtc, 'udev/rules.d/90-warehouse-usb-backup.rules'), wanted, 'rule', fix);
    judge(join(usbEtc, 'systemd/system/warehouse-usb-backup@.service'), wanted, 'unit', fix);
  }
  const project = ctx.env_().WAREHOUSE_PROJECT_NAME;
  const unitDir = ctx.unitDir ?? '/etc/systemd/system';
  if (/^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$/.test(project ?? '')) {
    const checker = ctx.readText(join(unitDir, `${project}-watch.service`));
    if (checker !== null && checker.split('\n').includes(`Environment=WAREHOUSE_STATE_DIR=${ctx.state}`)) {
      const wanted = scriptHash('watch-timer.sh');
      const fix = `sudo bash ${join(ctx.root, 'scripts/watch-timer.sh')} install --state ${ctx.state}`;
      for (const name of ['watch', 'daily', 'stack']) judge(join(unitDir, `${project}-${name}.service`), wanted, 'unit', fix);
    }
  }
  return [result('root_copies', 'root_copy_stale', stale.length === 0,
    stale.length ? `Files installed with sudo are older than this checkout: ${stale.join(', ')}` : 'Root-installed copies match this checkout',
    `They run as root or at boot from an earlier release's recipe. Run: ${fixes.join(' ; ')}`, { repeatHours: HOST_DRIFT_REPEAT_HOURS })];
}

export const CHECKS = [
  ['cpu', checkCpu], ['memory', checkMemory], ['disk', checkDisks], ['database', checkDatabase],
  ['services', checkServices], ['container_oom', checkContainerOom], ['container_restarts', checkContainerRestarts],
  ['container_memory', checkContainerMemory], ['api_local', checkApiLocal], ['api_public', checkApiPublic], ['api_lan', checkApiLan],
  ['api_logs', checkApiLogs], ['pdf_renderer', checkPdfRenderer], ['central_key', checkCentralKey], ['letterhead', checkLetterhead], ['backups', checkBackups],
  ['restore_space', checkRestoreSpace], ['upgrade', checkUpgrade], ['sms_delivery', checkSmsDelivery], ['break_glass', checkBreakGlass], ['clock', checkClock],
  ['cloudflared', checkCloudflared], ['host_node', checkHostNode], ['root_copies', checkRootCopies],
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
      if (list === null) continue;   // not due this run (a daily check): it did not run, so its alerts are left as they are
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
// `exited` (or `created`: a power cut during `up`) is started again; one that stays `unhealthy` for 3 runs in a row is
// restarted; each at most once an hour and at most 6 times in any 24 hours (after that the checker only alerts: a service that
// never recovers needs a person). Only while no operator command holds the lock (those stop services on purpose), not while
// the service's alert is muted (a planned stop), not while config/stopped-by-operator exists (stop.sh wrote it: the operator
// stopped the stack and start.sh has not brought it back), and never the database for being unhealthy: a database in crash
// recovery reports unhealthy too, and a restart only begins the recovery again. The start touches that one container and
// nothing else: --no-recreate keeps it, --no-deps leaves its dependencies alone, --no-build and --pull never keep `up` from
// building or pulling anything. Applying a changed compose file or image is the operator's job (setup.sh), not the checker's.
// Nothing is done at all while config/upgrade-in-progress exists (see the first lines of selfHeal).
// Every action is reported as the alert service_healed:<name>, held for an hour like an OOM kill.
export const holdPath = state => join(state, 'config/stopped-by-operator');
export const stoppedByOperator = state => lstatSync(holdPath(state), { throwIfNoEntry: false }) !== undefined;
export function selfHeal(ctx) {
  const now = ctx.now();
  const out = [];
  const by = new Map();
  let expected;
  if (stoppedByOperator(ctx.state)) return out;
  // An upgrade that stopped half way (config/upgrade-in-progress, and the lock is free): a person decides. A service started or restarted now could be the
  // new release's code (the functions container reads its code at start) on a schema that is only part migrated.
  if (upgradeRecordExists(ctx.state)) return out;
  try {
    for (const c of ctx.containers()) if (!by.has(c.service) || c.status === 'running') by.set(c.service, c);
    expected = ctx.expectedServices();
  } catch { return out; }   // the services check reports why it cannot see them
  for (const name of expected) {
    const c = by.get(name);
    const h = ctx.data.heal[name] ??= { unhealthyRuns: 0, lastAt: null, lastAction: '', actions: [] };
    h.actions = (h.actions ?? []).filter(t => t <= now && now - t < DAY);   // a time in the future is a clock that went back
    const stopped = c?.status === 'exited' || c?.status === 'created';
    const unhealthy = c?.status === 'running' && c.health === 'unhealthy';
    if (unhealthy) h.unhealthyRuns += 1; else if (c?.health !== 'starting') h.unhealthyRuns = 0;
    const idle = h.lastAt === null || h.lastAt > now || now - h.lastAt >= LIMITS.healGapMs;
    let act = null;
    if (stopped) act = { args: ['up', '-d', '--no-build', '--no-recreate', '--no-deps', '--pull', 'never', name], what: `was ${c.status}`, did: 'started it again' };
    else if (unhealthy && name !== 'db' && h.unhealthyRuns >= LIMITS.healUnhealthyRuns) {
      act = { args: ['restart', name], what: `was unhealthy for ${h.unhealthyRuns} runs`, did: 'restarted it' };
    }
    const capped = Boolean(act) && h.actions.length >= LIMITS.healMaxPerDay;
    if (act && !isMuted(ctx.data, `service_down:${name}`, now) && !lockIsHeld(ctx)) {
      if (capped) {
        h.lastAction = `${act.what}; the checker has already tried ${h.actions.length} times in the last 24 hours and stops here: it needs a person (docs/MONITORING.md, "Self-healing")`;
      } else if (idle) {
        const r = ctx.compose(act.args, { timeoutMs: 180000 });
        h.lastAt = now; h.unhealthyRuns = 0; h.actions.push(now);
        h.lastAction = r.status === 0 ? `${act.what}; the checker ${act.did}`
          : `${act.what}; the checker could not do it: ${clip(redact(String(r.stderr ?? '').trim(), ctx.env_()), 200)}`;
      }
    }
    if ((h.lastAt !== null && h.lastAt <= now && now - h.lastAt < LIMITS.healGapMs) || (capped && h.lastAction)) {
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

// ---------------------------------------------------------------- upgrades and maintenance mode
// The record upgrade.sh leaves from before its backup until it succeeds (scripts/upgrade-record.mjs), and the marker of maintenance mode
// (scripts/maintenance.sh; scripts/compose.sh turns it into WAREHOUSE_MAINTENANCE=upgrading for the gateways). Both are looked for by name:
// whatever is there counts, even a file that cannot be read.
export const upgradeRecordExists = state => lstatSync(join(state, RECORD_FILE), { throwIfNoEntry: false }) !== undefined;
export const maintenancePath = state => join(state, 'config/maintenance');
export const maintenanceMarked = state => lstatSync(maintenancePath(state), { throwIfNoEntry: false }) !== undefined;

// How long the newest backup that says so took (duration_seconds= in its metadata.txt), or null.
function newestBackupSeconds(state) {
  let names;
  try { names = readdirSync(join(state, 'backups')); } catch { return null; }
  for (const name of names.filter(n => BACKUP_DIR_PATTERN.test(n)).sort().reverse()) {
    try {
      const meta = join(state, 'backups', name, 'metadata.txt');
      if (!lstatSync(meta, { throwIfNoEntry: false })?.isFile()) continue;
      const seconds = /^duration_seconds=(\d{1,7})$/m.exec(readFileSync(meta, 'utf8'))?.[1];
      if (seconds !== undefined) return Number(seconds);
    } catch { /* the next one */ }
  }
  return null;
}
// When the operator lock, held while config/upgrade-in-progress exists, is called stuck: twice the time of the last backup plus the last
// verify, but never under the 2 hours any other command gets and never over a day. An upgrade does what the daily pass does (a backup and the
// proof that it restores) and then the migrations, so a limit that is only 2 hours would be passed by a healthy upgrade of a large facility. The
// verify time is the newest one on config/backups-verified.list (upgrade.sh records the third field: how long its verify took); a backup
// verified by the daily pass has none, and the backup's own time stands in.
export function upgradeStuckMs(state) {
  const backup = newestBackupSeconds(state) ?? 0;
  const verify = readVerifiedList(state).filter(e => e.seconds !== undefined).at(-1)?.seconds ?? backup;
  return Math.min(DAY, Math.max(LIMITS.busyGiveUpMs, 2 * (backup + verify) * 1000));
}

// The upgrade that did not finish: the record exists and the operator lock is free, so upgrade.sh is not running. Raised at once and never
// muted (UPGRADE_ALERT is in NEVER_MUTED): the facility may be half upgraded and is closed to phones until a person finishes or undoes it. While
// the lock is held the check says nothing (null: the alert stays as it is); a run of upgrade.sh that is too slow is operator_lock_stuck.
export function checkUpgrade(ctx) {
  if (lockIsHeld(ctx)) return null;
  if (!upgradeRecordExists(ctx.state)) return [result('upgrade', UPGRADE_ALERT, true, 'No upgrade is left half done')];
  let record = null;
  try { record = readUpgradeRecord(ctx.state); } catch { record = { invalid: `${RECORD_FILE} cannot be read` }; }
  if (record?.invalid) {
    return [result('upgrade', UPGRADE_ALERT, false, 'The record of an upgrade cannot be read',
      `${record.invalid}. upgrade.sh left it: read it ('cat'), and remove it when no upgrade is pending. If the API answers "upgrading" to phones: bash scripts/maintenance.sh off.`, { immediate: true })];
  }
  // The detail is clipped to a few hundred characters in Slack: what matters comes first, and the full way forward and way back are one command away
  // (upgrade-record.mjs report, the text upgrade.sh printed when it stopped).
  const summary = `An upgrade from ${record.fromLabel} to ${record.toLabel} did not finish`;
  const closed = record.maintenance ? 'The API is closed to phones (maintenance mode) until then: bash scripts/maintenance.sh off opens it. '
    : record.apiOpen ? 'The API is open to phones (maintenance mode is off), but the health check after opening it failed: node scripts/watch.mjs health. ' : '';
  if (!record.verified) {
    return [result('upgrade', UPGRADE_ALERT, false, summary,
      `It stopped before the first backup was proved to restore, so the facility was not changed. ${closed}Run the same command again: bash upgrade.sh ${record.command || '<the same command as before>'}`, { immediate: true })];
  }
  return [result('upgrade', UPGRADE_ALERT, false, summary,
    `Stopped at step "${record.step}": the facility may be half upgraded. ${closed}On the server: node scripts/upgrade-record.mjs report (the way forward and the way back).`, { immediate: true })];
}

// What the gateways say about maintenance mode, for `status` and the health check: 'upgrading' when a gateway container was created with
// WAREHOUSE_MAINTENANCE=upgrading (so it answers 503 to every API request), 'off' when they were not, null when no gateway container can be read.
export function gatewayMaintenance(ctx) {
  let found = null;
  try {
    for (const c of ctx.containers().filter(item => item.service === 'gateway' || item.service === LAN_SERVICE)) {
      const inspected = ctx.run('docker', ['inspect', '--format', '{{range .Config.Env}}{{println .}}{{end}}', c.id]);
      if (inspected.status !== 0) continue;
      const word = /^WAREHOUSE_MAINTENANCE=(.*)$/m.exec(String(inspected.stdout ?? ''))?.[1];
      if (word === 'upgrading') return 'upgrading';
      found = 'off';
    }
  } catch { return null; }
  return found;
}

// ---------------------------------------------------------------- alerting
// A mute covers every alert but the ones that say no backup exists, that the backup depends on a unit that is out of date, or that an
// upgrade stopped half way: a facility that muted "everything" for a week while a service was being repaired would otherwise also silence
// the only warning that its data is not being saved, or that it is closed to phones and half upgraded.
export const UPGRADE_ALERT = 'upgrade_interrupted';
export const NEVER_MUTED = ['backup_missing', 'backup_failed', LEGACY_DAILY_ALERT, UPGRADE_ALERT];
const listIds = ids => (ids.length > 1 ? `${ids.slice(0, -1).join(', ')} and ${ids.at(-1)}` : ids.join(''));
export const isMuted = (data, id, now) => !NEVER_MUTED.includes(id) && Boolean((data.muteUntil && now < data.muteUntil) || (data.mutes?.[id] && now < data.mutes[id]));

// Updates the per-alert counters and returns what to tell Slack. Nothing is marked as sent here.
export function evaluate(data, results, ran, now) {
  const seen = new Set();
  for (const r of results) {
    seen.add(r.id);
    let a = data.alerts[r.id];
    if (!r.ok) {
      a ??= data.alerts[r.id] = { failingRuns: 0, firingSince: null, lastSent: null };
      a.failingRuns = (a.failingRuns || 0) + 1; a.check = r.check; a.summary = r.summary; a.detail = r.detail;
      if (r.repeatHours !== undefined) a.repeatHours = r.repeatHours;   // an alert that repeats less often than the 4 hours of every other one
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
    else if (now - a.lastSent >= (a.repeatHours > 0 ? a.repeatHours * HOUR : LIMITS.repeatMs)) repeat.push(line);
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
  const notes = [];
  if (data.muteUntil && now < data.muteUntil) notes.push(`Alerts are muted until ${new Date(data.muteUntil).toISOString()}.`);
  const mutedIds = Object.entries(data.mutes ?? {}).filter(([, until]) => now < until).map(([id]) => id);
  if (mutedIds.length) notes.push(`Muted: ${mutedIds.join(', ')}.`);
  if (notes.length) notes.push(`${listIds(NEVER_MUTED)} are never muted: they are posted anyway.`);
  const muted = notes.length ? ` ${notes.join(' ')}` : '';
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

// The backups the daily pass has verified: $STATE/config/backups-verified.list, one "NAME EPOCH [SECONDS]" line per backup (EPOCH: seconds
// since 1970 when its verify passed; SECONDS, when the writer knew it: how long that verify took), newest last. Outside any backup, written
// by `prune-backups --verified` and by `record-verified` (upgrade.sh records the backup it proved before an upgrade), read by
// the pruning below and by scripts/backup.sh (the newest backup verified within the last two days is the next night's link base). A name that no
// longer exists as a directory is dropped when the list is written; a line that is not a backup name is ignored; a reader that knows only
// "NAME EPOCH" (backup.sh, backup-usb.sh and the preflight take the first and second field with awk) is not disturbed by the third.
export const verifiedListPath = state => join(state, 'config/backups-verified.list');
export function readVerifiedList(state) {
  const path = verifiedListPath(state);
  const entry = lstatSync(path, { throwIfNoEntry: false });
  if (!entry?.isFile()) return [];   // absent, or a link / directory in its place: no list
  let text;
  try { text = readFileSync(path, 'utf8'); } catch { return []; }
  const byName = new Map();
  for (const line of text.split('\n')) {
    const [name, epoch, seconds] = line.trim().split(/\s+/);
    if (name && BACKUP_DIR_PATTERN.test(name)) { byName.delete(name); byName.set(name, { epoch: Number(epoch) || 0, seconds: /^\d{1,7}$/.test(seconds ?? '') ? Number(seconds) : null }); }
  }
  return [...byName].map(([name, { epoch, seconds }]) => (seconds === null ? { name, epoch } : { name, epoch, seconds }));
}
const writeVerifiedList = (state, entries) => writeFileAtomic(verifiedListPath(state), entries.map(e => `${e.name} ${e.epoch}${e.seconds === undefined ? '' : ` ${e.seconds}`}\n`).join(''));
const backupDirExists = (state, name) => Boolean(lstatSync(join(state, 'backups', name), { throwIfNoEntry: false })?.isDirectory());
// Records `name` (a backup directory in $STATE/backups) as verified now: its line goes last, any older line of the same name
// goes, and so do the lines of backups that no longer exist. Throws when `name` is not such a directory.
export function recordVerified(state, name, now = Date.now(), seconds = null) {
  if (typeof state !== 'string' || !state.startsWith('/')) throw new Error(`the state path must be absolute: ${state}`);
  if (!BACKUP_DIR_PATTERN.test(String(name))) throw new Error(`not a backup name: ${name}`);
  if (!backupDirExists(state, name)) throw new Error(`${name} is not a backup directory in ${join(state, 'backups')}`);
  if (seconds !== null && !(Number.isInteger(seconds) && seconds >= 0 && seconds <= 9999999)) throw new Error(`not a number of seconds: ${seconds}`);
  const kept = readVerifiedList(state).filter(e => e.name !== name && backupDirExists(state, e.name));
  writeVerifiedList(state, [...kept, seconds === null ? { name, epoch: Math.floor(now / 1000) } : { name, epoch: Math.floor(now / 1000), seconds }]);
}

// The size of the stored files a backup holds: storage_bytes= in metadata.txt (format v6, a tree), else the size of storage.tar.gz
// (format v5), the same two figures scripts/restore.sh checks the free space against. Null when the backup records neither.
export function backupStorageBytes(dir) {
  try {
    const meta = lstatSync(join(dir, 'metadata.txt'), { throwIfNoEntry: false });
    if (!meta?.isFile()) return null;
    const recorded = /^storage_bytes=(\d{1,15})$/m.exec(readFileSync(join(dir, 'metadata.txt'), 'utf8'))?.[1];
    if (recorded !== undefined) return Number(recorded);
    const tarball = lstatSync(join(dir, 'storage.tar.gz'), { throwIfNoEntry: false });
    return tarball?.isFile() ? tarball.size : null;
  } catch { return null; }
}
// The newest backup on the verified list that still exists and records a size: { name, bytes, dumpBytes }, or null.
export function newestVerifiedBackup(state) {
  const names = readVerifiedList(state).map(e => e.name).filter(name => backupDirExists(state, name)).sort().reverse();
  for (const name of names) {
    const bytes = backupStorageBytes(join(state, 'backups', name));
    if (bytes !== null) return { name, bytes, dumpBytes: backupDumpBytes(join(state, 'backups', name)) };
  }
  return null;
}
// The size of the database dump of a backup (what a restore replays), 0 when there is none to be read.
function backupDumpBytes(dir) {
  try {
    const dump = lstatSync(join(dir, 'database.dump'), { throwIfNoEntry: false });
    return dump?.isFile() ? dump.size : 0;
  } catch { return 0; }
}
// The migration state a backup was taken at: migration_fingerprint= of its integrity.txt (scripts/backup-integrity.sql), or null.
const migrationFingerprintOf = path => { try { return /^migration_fingerprint=([0-9a-f]{64})$/m.exec(readFileSync(path, 'utf8'))?.[1] ?? null; } catch { return null; } };

// A backup that is being removed is first renamed to this prefix (one atomic step): the name is then no longer a backup, so a
// pass cut short while it removes a large tree leaves a leftover that the next pass finds and finishes instead of an
// unrecognisable half-backup that nothing would ever prune.
const REMOVING_PREFIX = '.warehouse-backup-removing.';
// Directories get u+rwx first (rsync keeps the modes of the source tree, and a read-only folder cannot be emptied); files are never
// chmodded, they may be hard links shared with other backups.
function removeBackupTree(path) {
  spawnSync('find', [path, '-type', 'd', '-exec', 'chmod', 'u+rwx', '{}', '+'], { stdio: 'ignore' });
  rmSync(path, { recursive: true, force: true });
}
// The backup that an interrupted upgrade.sh recorded as the way back, or null (no record, an invalid one, or none that names a backup).
function upgradeBackupName(state) {
  try {
    const record = readUpgradeRecord(state);
    const name = record && !record.invalid && record.backup ? record.backup.split('/').filter(Boolean).pop() : '';
    return name && BACKUP_DIR_PATTERN.test(name) ? name : null;
  } catch { return null; }
}

// Keeps the newest `keep` backup directories of THIS installation in $STATE/backups and removes the older ones.
// A directory counts only when its name is one backup.sh gives, it is a real directory holding metadata.txt, and its
// instance.json names the same instanceId as $STATE/public/instance.json. Manual backups in that directory that meet
// these rules count towards `keep`. Never removed, on top of the newest `keep`: `protect` (the backup just made), the
// newest backup on the verified list that still exists, whatever its age, and the backup that an interrupted upgrade recorded
// as its way back (config/upgrade-in-progress). When nothing newer has been verified, the verified one is therefore kept
// through any number of nights whose verify failed. Removal order, in case the pass is cut short: backups that were never
// verified and are older than the newest verified one first, then the rest, each newest first. Nothing at all is removed when
// any warehouse-* name is dated more than an hour ahead of now (a clock that was wrong would otherwise make the newest-first
// order delete good backups). Names of removed backups leave the verified list. A folder that does not exist yet has nothing to prune.
// Also kept, for LIMITS.keepMigrationStateMs after the backup's own date: the newest verified backup of each distinct migration state
// (a changed set of applied migrations makes a new fingerprint), so that the copy from before a schema change outlives the nightly
// rotation for two months. A backup without a readable integrity.txt has no state to be the newest of.
// Returns { removed, note, verifiedKept } (verifiedKept: the name of the newest verified backup of this installation that exists, or '').
export function pruneBackups(state, { keep = LIMITS.keepBackups, protect = null, now = Date.now() } = {}) {
  if (typeof state !== 'string' || !state.startsWith('/')) throw new Error(`the state path must be absolute: ${state}`);
  const dir = join(state, 'backups');
  let names;
  try { names = readdirSync(dir); } catch (error) { if (error.code === 'ENOENT') return { removed: [], note: '', verifiedKept: '' }; throw error; }
  const mine = instanceIdOf(join(state, 'public/instance.json'));
  const ours = !mine ? [] : names.filter(name => {
    if (!BACKUP_DIR_PATTERN.test(name)) return false;
    const s = lstatSync(join(dir, name), { throwIfNoEntry: false });
    const meta = lstatSync(join(dir, name, 'metadata.txt'), { throwIfNoEntry: false });
    return Boolean(s?.isDirectory()) && !s.isSymbolicLink() && Boolean(meta?.isFile()) && instanceIdOf(join(dir, name, 'instance.json')) === mine;
  }).sort().reverse();
  const verified = new Set(readVerifiedList(state).map(e => e.name).filter(name => ours.includes(name)));
  const newestVerified = [...verified].sort().at(-1) ?? null;
  const future = names.find(name => { const t = stampMs(name); return t !== null && t > now + LIMITS.futureBackupMs; });
  if (future) return { removed: [], note: `pruning skipped: ${future} is dated in the future (check the clock)`, verifiedKept: newestVerified ?? '' };
  if (!mine) return { removed: [], note: 'pruning skipped: public/instance.json has no instanceId', verifiedKept: '' };
  const protectName = protect ? String(protect).split('/').pop() : null;
  const upgradeName = upgradeBackupName(state);
  const kept = new Set([...ours.slice(0, keep), protectName, newestVerified]);
  const newestOfState = new Map();   // fingerprint -> newest verified backup that has it (ours is newest first)
  for (const name of ours) {
    if (!verified.has(name)) continue;
    const fingerprint = migrationFingerprintOf(join(dir, name, 'integrity.txt'));
    if (fingerprint !== null && !newestOfState.has(fingerprint)) newestOfState.set(fingerprint, name);
  }
  const ofEarlierState = [...newestOfState.values()].filter(name => !kept.has(name) && now - stampMs(name) <= LIMITS.keepMigrationStateMs);
  for (const name of ofEarlierState) kept.add(name);
  const doomed = ours.filter(name => !kept.has(name));
  const notes = [];
  if (ofEarlierState.length) notes.push(`kept ${ofEarlierState.join(', ')}, the newest verified backup of an earlier migration state (60 days)`);
  if (upgradeName && doomed.includes(upgradeName)) { doomed.splice(doomed.indexOf(upgradeName), 1); notes.push(`kept ${upgradeName}, the backup of the interrupted upgrade (config/upgrade-in-progress)`); }
  const neverVerifiedOlder = name => newestVerified !== null && !verified.has(name) && name < newestVerified;
  const removed = [...doomed.filter(neverVerifiedOlder), ...doomed.filter(name => !neverVerifiedOlder(name))];
  for (const name of names) if (name.startsWith(REMOVING_PREFIX)) removeBackupTree(join(dir, name));   // finish a removal that was cut short
  for (const name of removed) {
    const doing = join(dir, `${REMOVING_PREFIX}${name}`);
    renameSync(join(dir, name), doing);
    removeBackupTree(doing);
  }
  if (removed.length) {
    const entries = readVerifiedList(state);
    if (entries.some(e => removed.includes(e.name))) { try { writeVerifiedList(state, entries.filter(e => !removed.includes(e.name))); } catch { /* names that do not exist are ignored on reading */ } }
  }
  return { removed, note: notes.join('; '), verifiedKept: newestVerified ?? '' };
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
    return { backup: { result: 'failed', message: why }, verify: step('verify'), prune: step('prune'), retention: fields.retention ? step('retention') : { result: 'skipped', message: 'retention not run: the daily run did not finish' } };
  }
  if (fields.backup === 'skipped') return { skipped: fields.backup_message || 'the database is not running or not healthy' };
  const backup = { ...step('backup', 'failed'), dir: fields.backup_dir ?? null, warning: fields.backup_warning ?? '' };
  const dir = backup.dir;
  if (backup.result === 'ok' && !(dir && BACKUP_DIR_PATTERN.test(dir.split('/').pop()) && resolve(dir, '..') === resolve(ctx.state, 'backups'))) {
    backup.result = 'failed'; backup.message = 'backup finished but its location could not be read';
  }
  return { backup, verify: step('verify'), prune: { ...step('prune'), pruned: Number(fields.pruned) || 0, verifiedKept: fields.verified_kept ?? '' }, retention: step('retention') };
}

export async function dailyRunner(ctx) {
  const resultFile = dailyResultPath(ctx.state);
  const env = { ...process.env, WAREHOUSE_STATE_DIR: ctx.state };
  delete env.WAREHOUSE_BACKUP_DIR;
  const launch = ctx.runGroup ?? ((command, args, options) => ctx.run(command, args, options));
  const r = await launch('bash', [join(ctx.root, 'scripts/watch-daily.sh'), resultFile], { timeoutMs: LIMITS.dailyHardMs, env });
  return interpretDaily(ctx, r, fieldsOf(ctx.readText(resultFile)));
}

// What the pass says about the verified backup that pruning keeps, when today's backup is not it.
// (Put before the reason of a failed verify, not after it: the status line cuts a message at 400 characters.)
function keptNote(prune) {
  if (prune.verifiedKept) return ` (the newest verified backup, ${prune.verifiedKept}, is kept)`;
  return prune.result === 'ok' ? ' (no backup is on record as verified yet)' : '';
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
  else if (verify.result !== 'ok') message = `backup ${name} was made but verification failed${keptNote(outcome.prune)}: ${verify.message}`;
  else message = `backup ${name} verified${outcome.prune.pruned ? `; removed ${outcome.prune.pruned} old` : ''}${outcome.prune.message ? `; ${outcome.prune.message}` : ''}${backup.warning ? `; ${backup.warning}` : ''}`;
  message = `${clean(message)}${backupOk ? '' : ` (attempt ${attempt} of ${LIMITS.dailyAttempts})`}`;
  data.lastDailyRun.backup = { date, at: now, result: backupOk ? 'ok' : 'failed', message };
  try { writeJobStatus(ctx, 'backup', backupOk, message, name && backup.result === 'ok' ? { backup: name } : {}); } catch { /* the state file carries the result */ }

  // Pruning belongs to the retention job: its failure is reported as a retention failure.
  const { retention, prune } = outcome;
  let retentionResult = retention.result;
  // Pruning and retention run whatever the backup and its verify said, so the retention line also tells what pruning did when
  // today's backup is not the news (a refused or unverified backup is when old backups matter most).
  const removedText = !backupOk && prune.result === 'ok' ? `${prune.pruned ? `; removed ${prune.pruned} old backup${prune.pruned === 1 ? '' : 's'}${keptNote(prune)}` : ''}${prune.message ? `; ${prune.message}` : ''}` : '';
  const defaultNote = { ok: `retention applied${removedText}`, skipped: 'retention not run' };
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
    outcome = { backup: { result: 'failed', message: `the daily run crashed: ${error.message}` }, verify: { result: 'skipped' }, prune: { result: 'skipped' }, retention: { result: 'skipped', message: 'retention not run: the daily run crashed' } };
  }
  data.dailyRunning = null;
  if (outcome.skipped) { data.dailySkipped = { at: now, reason: redact(outcome.skipped, ctx.env_(), webhook) }; saveState(ctx.state, data, ctx.fsApi, { daily: true }); return; }
  data.dailySkipped = null;
  attempt.count += 1; attempt.lastAt = now;
  attempt.done = recordDaily(ctx, data, outcome, attempt.count, webhook);
  saveState(ctx.state, data, ctx.fsApi, { daily: true });
}

// The daily jobs need the database and the services the backup stops (scripts/backup.sh stops the gateway, functions, rest and
// storage, and the pooler when it runs) in THIS run: right after a boot the first runs find them down. The pooler counts only
// while it is running (a running one that is unhealthy would make the backup fail when it restarts it with --wait; one that was
// stopped on purpose is left alone by the backup). Not the other optional services and not the PDF renderer: a renderer that
// turned unhealthy after a host update must not stop the backups.
export const BACKUP_SERVICES = ['gateway', 'functions', 'rest', 'storage'];
export const BACKUP_OPTIONAL_SERVICES = ['supavisor'];
export function dailyHealthy(results) {
  const pg = results.find(r => r.id === 'postgres_down');
  if (!pg || !pg.ok) return false;
  return !results.some(r => !r.ok && (BACKUP_SERVICES.some(name => r.id === `service_down:${name}`)
    || (r.running && BACKUP_OPTIONAL_SERVICES.some(name => r.id === `service_down:${name}`))
    || r.id === 'check_error:services' || r.id === 'check_error:database'));
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
// The checks that need none of the services the backup stops (the gateway, functions, rest, storage, the pooler): while the daily pass
// holds the operator lock these keep running. The others would only report the stop.
export const PASS_SAFE_CHECKS = ['cpu', 'memory', 'disk', 'database', 'backups', 'break_glass'];
// A pass the state calls running and younger than jobStaleMs (the daily unit's own limit): the holder of the lock, if it is held.
const dailyPassRunning = (data, now) => Boolean(data.dailyRunning) && data.dailyRunning.startedAt <= now && now - data.dailyRunning.startedAt < LIMITS.jobStaleMs;

export async function runOnce(deps, { checks = CHECKS, heal = selfHeal } = {}) {
  const now = deps.now();
  const data = loadState(deps.state, now, deps.readText, deps.log);
  Object.assign(data, loadMutes(deps.state, deps.readText));
  const ctx = makeContext(deps, data);
  const webhook = readWebhook(deps.state);
  // A checker unit from before the split still carries the daily time: the backup then runs below, inside this run.
  const legacy = Boolean(deps.env?.WAREHOUSE_WATCH_DAILY_AT);
  let stuck = false;
  let passHolds = false;
  if (lockIsHeld(ctx)) {
    // Backup, restore, setup and stop stop services on purpose: judge nothing while one runs, unless it hangs. The daily pass
    // is such a command that runs for hours by design: the checks that do not need the stopped services go on, and the lock
    // is called stuck only after the pass's own limit (jobStaleMs, 4 h, the daily unit's TimeoutStartSec) instead of 2 hours.
    // Any other command: after 2 hours, an upgrade after upgradeStuckMs (2 hours at least). Either way a lock cannot stay unnoticed for longer than a day.
    if (data.busySince === null || data.busySince > now) data.busySince = now;
    passHolds = dailyPassRunning(data, now);
    // An upgrade holds the lock for a backup, the proof that it restores and the migrations: its limit follows how long those took last time.
    const limit = passHolds ? LIMITS.jobStaleMs : upgradeRecordExists(deps.state) ? upgradeStuckMs(deps.state) : LIMITS.busyGiveUpMs;
    if (now - data.busySince >= limit) { stuck = true; passHolds = false; }
    else if (!passHolds) {
      saveState(deps.state, data, deps.fsApi);
      await pingExternalHeartbeat(ctx);   // the checker is alive; it is the operator command that is busy
      return { skipped: 'operator lock is held', data };
    }
  } else data.busySince = null;
  const { results, ran } = await runChecks(ctx, passHolds ? checks.filter(([name]) => PASS_SAFE_CHECKS.includes(name)) : checks);
  // Not while an operator command holds the lock (it stops services on purpose), nor while it is stuck.
  if (heal && !stuck && !passHolds) {
    const healed = await runChecks(ctx, [['self_heal', heal]]);
    results.push(...healed.results);
    for (const name of healed.ran) ran.add(name);
  }
  const heldHours = stuck ? Math.floor((now - data.busySince) / HOUR) : 0;
  results.push(result('operator_lock', 'operator_lock_stuck', !stuck, `An operator command has held the lock for ${heldHours} h or more`, 'Look for a hung setup, backup or restore: node scripts/watch.mjs status'));
  ran.add('operator_lock');
  // Immediate, and listed among NEVER_MUTED: the backup goes on, but a long pass now holds the 5-minute checks off, and an
  // installation that cannot run sudo (an agent-driven update) would otherwise never be told.
  if (legacy) {
    results.push(result('daily_timer', LEGACY_DAILY_ALERT, false, 'The daily backup still runs from the old checker unit',
      `Backups continue, but the checks wait while a backup runs. ${legacyDailyAdvice(deps.root ?? checkoutRoot, deps.state)}`, { immediate: true }));
  }
  ran.add('daily_timer');   // every run, so the alert clears once the unit is replaced
  data.lastRunAt = now;
  const plan = evaluate(data, results, ran, now);
  await notify(ctx, webhook, plan);
  await heartbeat(ctx, webhook);
  saveState(deps.state, data, deps.fsApi);
  await pingExternalHeartbeat(ctx);
  // The old unit's pass, as it always ran (the old unit allows it 4 hours): after the checks, the alert and the ping, so none
  // of them waits for it and a crash of the pass loses nothing already saved.
  if (legacy && !stuck && !passHolds) {
    await runDaily(ctx, data, dailyHealthy(results), dailyRunner, webhook);
    saveState(deps.state, data, deps.fsApi, { daily: true });
  }
  return { results, plan, data };
}

// `watch.mjs daily`: what the daily timer runs. The gate (the database and the services the backup stops) is judged by the
// same two checks the checker runs, and only when a pass is about to start.
export const DAILY_GATE_CHECKS = [['database', checkDatabase], ['services', checkServices]];
export async function runDailyCommand(deps, { checks = DAILY_GATE_CHECKS, daily = dailyRunner } = {}) {
  const data = loadState(deps.state, deps.now(), deps.readText, deps.log);
  const ctx = makeContext(deps, data);
  const webhook = readWebhook(deps.state);
  // This unit never runs twice at once (systemd does not start an active oneshot), so a pass the state calls running while
  // nothing holds the operator lock was cut off (a power cut, a killed unit): clear the mark now instead of after 4 hours,
  // or the day's backup waits for the next trigger after that.
  if (data.dailyRunning && !lockIsHeld(ctx)) data.dailyRunning = null;
  await runDaily(ctx, data, async () => dailyHealthy((await runChecks(ctx, checks)).results), daily, webhook);
  saveState(deps.state, data, deps.fsApi, { daily: true });
  return { data };
}

// ---------------------------------------------------------------- commands
const USAGE = `Usage: node scripts/watch.mjs run | daily | health [--wait SECONDS] | test-message | status | mute MINUTES ["ALERT ID"] | unmute ["ALERT ID"]
  run           one pass of the checks (the systemd timer runs this every 5 minutes); it makes no backup, except under an old checker unit that sets WAREHOUSE_WATCH_DAILY_AT (daily_timer_legacy)
  daily         the daily backup, verification, pruning and retention, inside the window after --daily-at (its own timer runs this)
  health        the operator health check now: services, database, gateway, get_public_config RPC probe, PDF renderer (exit 1 on a fault; --wait: seconds to wait for the gateway, default 90)
  test-message  post a test message to the facility's Slack webhook
  status        failing alerts, mutes, the daily jobs and the time zone
  mute          silence all alerts (or one alert id, quoted when it has spaces) for MINUTES; backup_missing and backup_failed are never muted
  unmute        end the mute (all, or one alert id)
Mute before a deliberate stop.sh (or any planned stop): a stopped service is an alert like any other.
The daily backup, verification, pruning and retention run once a day inside a 6-hour window after the time chosen
with: sudo bash scripts/watch-timer.sh install --daily-at HH:MM (host local time; shown by status). Pruning keeps the
newest 7 backups of this installation in $STATE/backups (backups made by hand there count towards the 7) and always the
newest one that passed its verify; pruning and retention run even when the day's backup or verify failed.
Needs WAREHOUSE_STATE_DIR. Install the timer with: sudo bash scripts/watch-timer.sh install`;

function statusLines(ctx, webhook, now) {
  const { data } = ctx;
  const lines = [`Installation: ${describe(ctx)}`, `Slack webhook: ${webhook ? 'configured' : 'none (alerts are recorded, not posted)'}`];
  let external;
  try { external = readHeartbeatUrl(ctx.state); } catch { external = { problem: 'cannot be read' }; }
  lines.push(`External heartbeat: ${external.problem ? `not sent (${external.problem})` : external.url ? 'configured (pinged at the end of each run)' : 'none (config/heartbeat-url)'}`);
  lines.push(`Time zone: ${Intl.DateTimeFormat().resolvedOptions().timeZone} (daily jobs start at ${ctx.dailyAt} in this zone)`);
  if (stoppedByOperator(ctx.state)) lines.push('Stack: stopped by the operator (config/stopped-by-operator); nothing restarts it at boot or by self-healing. Run start.sh to bring it back.');
  const interruptedUpgrade = interruptedUpgradeWarning(ctx.state);
  if (interruptedUpgrade) lines.push(`Upgrade: ${interruptedUpgrade}`);
  // Maintenance mode: what the gateway containers were started with (the fact: they answer 503 "upgrading" to every API request), and the marker
  // that makes the next start of one the same (the intention). Both are said when they differ.
  const gatewayWord = gatewayMaintenance(ctx);
  const marked = maintenanceMarked(ctx.state);
  if (gatewayWord === 'upgrading') lines.push('Maintenance mode: upgrading (the gateway answers 503 "upgrading" to every API request; phones are told the server is being updated). Open it with: bash scripts/maintenance.sh off');
  else if (marked) lines.push(`Maintenance mode: marked (${maintenancePath(ctx.state)} exists) but the gateway ${gatewayWord === 'off' ? 'runs without it; the next recreate closes it' : 'is not running; it starts closed'}. Open it with: bash scripts/maintenance.sh off`);
  if (data.alerts[LEGACY_DAILY_ALERT]) lines.push(`Daily backup: still run by the old checker unit, inside the 5-minute check. ${legacyDailyAdvice(ctx.root, ctx.state)}`);
  const firing = Object.entries(data.alerts).filter(([, a]) => a.firingSince);
  lines.push(firing.length ? `Firing: ${firing.map(([id]) => id).join(', ')}` : 'Firing: none');
  const failing = Object.entries(data.alerts).filter(([, a]) => !a.firingSince && a.failingRuns);
  if (failing.length) lines.push(`Failing once (not yet firing): ${failing.map(([id]) => id).join(', ')}`);
  if (data.muteUntil && now < data.muteUntil) lines.push(`All alerts muted until ${new Date(data.muteUntil).toISOString()}`);
  for (const [id, until] of Object.entries(data.mutes ?? {})) if (now < until) lines.push(`Muted until ${new Date(until).toISOString()}: ${id}`);
  for (const [job, run] of Object.entries(data.lastDailyRun)) lines.push(`Daily ${job}: ${run.result} on ${run.date} - ${run.message}`);
  if (data.dailyRunning) {
    const since = new Date(data.dailyRunning.startedAt).toISOString();
    lines.push(dailyPassRunning(data, now) ? `Daily pass: running since ${since} (it may take up to 4 hours; systemctl is-active <project>-daily.service says whether the unit is still working)`
      : `Daily pass: marked running since ${since} but cut short (the next daily trigger clears the mark)`);
  }
  const attempt = data.dailyAttempt;
  if (attempt) lines.push(`Daily pass ${attempt.date}: ${attempt.count} of ${LIMITS.dailyAttempts} attempts${attempt.done ? ', done' : ''}`);
  if (data.dailySkipped) lines.push(`Daily pass last skipped at ${new Date(data.dailySkipped.at).toISOString()}: ${data.dailySkipped.reason}`);
  if (data.memoryNote) lines.push(`Note: ${data.memoryNote}`);
  if (data.lastPostError) lines.push(`Last Slack post failed at ${new Date(data.lastPostError.at).toISOString()}: ${data.lastPostError.message}`);
  lines.push(`Last heartbeat: ${data.lastHeartbeat ? new Date(data.lastHeartbeat).toISOString() : 'never'}`);
  return lines;
}

export async function main(argv, deps = defaultDeps(), out = text => console.log(text), err = text => console.error(text)) {
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
    // prune-backups [PATH] [--verified NAME]. Used by scripts/watch-daily.sh under its lock: PATH is the backup just made (never
    // pruned; none when the backup failed), NAME the backup whose verify passed (recorded in config/backups-verified.list
    // first, so that pruning never takes it); NAME or a path to it. Prints removed=N, note=TEXT and verified_kept=NAME.
    // Wrong arguments are said on standard error (watch-daily.sh reads the reason from there) and nothing is touched; a NAME that
    // is not a backup of this installation is a note, and pruning goes on without recording it.
    let protect = null;
    let verifiedName = null;
    for (let i = 0; i < args.length; i += 1) {
      if (args[i] === '--verified' && verifiedName === null && i + 1 < args.length) { verifiedName = args[i + 1].split('/').filter(Boolean).pop() ?? ''; i += 1; }
      else if (protect === null && !args[i].startsWith('--')) protect = args[i];
      else { err('Usage: prune-backups [PATH_OF_THE_BACKUP_JUST_MADE] [--verified NAME]'); return 1; }
    }
    const notes = [];
    if (verifiedName !== null) {
      if (!BACKUP_DIR_PATTERN.test(verifiedName) || !backupDirExists(deps.state, verifiedName)) notes.push(`--verified needs the name of a backup directory in ${join(deps.state, 'backups')} (it was '${verifiedName}'); nothing was recorded as verified`);
      else { try { recordVerified(deps.state, verifiedName, now); } catch (error) { notes.push(`could not record ${verifiedName} as verified: ${error.message}`); } }
    }
    const { removed, note, verifiedKept } = pruneBackups(deps.state, { protect, now });
    if (note) notes.push(note);
    out(`removed=${removed.length}\nnote=${notes.join('; ')}\nverified_kept=${verifiedKept}`);
    return 0;
  }
  if (command === 'record-verified') {
    // record-verified NAME [SECONDS]. Used by upgrade.sh, which has just proved the backup it took before an upgrade with
    // scripts/verify-restore.sh (SECONDS: how long that took): the backup goes on config/backups-verified.list, so that the
    // keep-for-60-days rule of pruneBackups holds for it too, and is not pruned as an unverified one. Nothing is pruned here.
    // NAME is a backup directory of this installation (or a path to one). Exit 1, with the reason on standard error, when it is not.
    const name = String(args[0] ?? '').split('/').filter(Boolean).pop() ?? '';
    const seconds = args.length > 1 ? (/^\d{1,7}$/.test(args[1]) ? Number(args[1]) : NaN) : null;
    if (args.length < 1 || args.length > 2 || Number.isNaN(seconds)) { err('Usage: record-verified BACKUP_NAME [SECONDS_THE_VERIFY_TOOK]'); return 1; }
    try { recordVerified(deps.state, name, now, seconds); } catch (error) { err(`could not record ${name} as verified: ${error.message}`); return 1; }
    out(`recorded ${name} as verified`);
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
      if (NEVER_MUTED.includes(args[1])) {
        const why = { [LEGACY_DAILY_ALERT]: 'it says the daily backup is kept running by an out-of-date unit', [UPGRADE_ALERT]: 'it says an upgrade stopped half way, with the facility closed to phones' }[args[1]] ?? 'it says no backup exists';
        out(`${args[1]} cannot be muted: ${why}.`);
        return 1;
      }
      data.mutes[args[1]] = until;
    } else data.muteUntil = until;
    saveMutes(deps.state, data);
    out(`Muted ${args[1] ?? 'all alerts'} until ${new Date(until).toISOString()}.${args[1] ? '' : ` ${listIds(NEVER_MUTED)} are not muted.`}`);
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
