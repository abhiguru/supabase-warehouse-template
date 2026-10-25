import { accessSync, constants, existsSync, lstatSync, statfsSync, realpathSync, readFileSync } from 'node:fs';
import { userInfo } from 'node:os';
import { join, resolve, sep } from 'node:path';
import { createConnection } from 'node:net';
import { spawnSync } from 'node:child_process';
import { createHash, createHmac, timingSafeEqual } from 'node:crypto';
import { centralKeyFault, letterheadProblem, probe, readEnv, root, supportedNode } from './doctor-common.mjs';
import { canonicalOrigin } from './configure.mjs';
import { validateDbValues } from './db-roles.mjs';
import { isFixtureAddress, isProviderPlaceholder } from './provider-placeholder.mjs';
import { isMain } from './is-main.mjs';
import { usbBackupWarning } from './usb-backup-status.mjs';
import { interruptedUpgradeWarning } from './upgrade-record.mjs';
import { storedWebhook } from './alert-webhook.mjs';
import { defaultDeps, legacyDailyAdvice, runHealth, statePath, stoppedByOperator } from './watch.mjs';

export const CHECKER_MAX_AGE_MS = 15 * 60 * 1000;
// The unit is named from the facility's Compose project (WAREHOUSE_PROJECT_NAME in config/compose.env), not from the
// state directory's name: two installs on one host may both end in /state. Without a readable project it is a hash of
// the state path. scripts/watch-timer.sh (unit_base) builds the same name.
export function timerBase(state) {
  let project = '';
  try { project = readEnv(join(state, 'config/compose.env')).WAREHOUSE_PROJECT_NAME ?? ''; } catch { /* no readable configuration */ }
  if (/^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$/.test(project)) return `${project}-watch`;
  return `warehouse-h${createHash('sha256').update(state).digest('hex').slice(0, 12)}-watch`;
}
export const timerUnit = state => `${timerBase(state)}.timer`;
// The daily backup has its own timer next to the checker's (scripts/watch-timer.sh, unit_sibling).
export const dailyTimerUnit = state => `${timerBase(state).replace(/-watch$/, '-daily')}.timer`;
const unitDir = () => process.env.WAREHOUSE_WATCH_UNIT_DIR || '/etc/systemd/system';
export const stoppedWarning = `The stack was stopped by the operator (config/stopped-by-operator, written by stop.sh): the boot unit and self-healing leave it down, also after a reboot. Run start.sh to bring it back.`;
export const NO_WEBHOOK_WARNING = 'No Slack webhook: alerts are recorded on this host but not delivered, so nobody is told when a backup fails or the database stops. That is acceptable only for a test install. For a real facility, rerun setup.sh --operator with your usual inputs, leaving out --alert-webhook-file off (it then asks for the URL on a terminal), or pass --alert-webhook-file <a private file holding the URL> (docs/MONITORING.md, "Alert delivery").';

// Warnings about the checker: its timer is not active, it has not run in the last 15 minutes (the mtime of its
// state file; the daily backup is a separate unit, so a backup in progress does not explain a silent checker), the daily
// backup timer is not active (or the checker unit is the old one that still makes the backup inside its own run), no Slack
// webhook is stored, the operator stopped the stack (stop.sh) and has not started it again. `timerActive(unit)` and `now` are
// injectable for tests.
export function checkerWarnings(state, {
  now = Date.now(),
  timerActive = unit => spawnSync('systemctl', ['is-active', '--quiet', unit], { timeout: 10000 }).status === 0,
  serviceText = unit => { try { return readFileSync(join(unitDir(), unit.replace(/\.timer$/, '.service')), 'utf8'); } catch { return null; } },
} = {}) {
  const out = [];
  const unit = timerUnit(state);
  const checkerActive = timerActive(unit);
  // A checker unit from before the daily timer sets WAREHOUSE_WATCH_DAILY_AT: its run still makes the backup.
  const legacy = checkerActive && /^Environment=WAREHOUSE_WATCH_DAILY_AT=/m.test(serviceText(unit) ?? '');
  if (stoppedByOperator(state)) out.push(stoppedWarning);
  if (!checkerActive) {
    out.push(`The monitoring checker is not running: ${unit} is not installed or not active, so no check, alert, daily backup or retention runs for this facility. Install it with: sudo bash scripts/watch-timer.sh install --state ${state} (docs/MONITORING.md).`);
  } else if (serviceText(unit) !== null && !serviceText(unit).split('\n').includes(`Environment=WAREHOUSE_STATE_DIR=${state}`)) {
    out.push(`${unit} is active but its service does not name this state (${state}), so this facility is not being checked. Install it for this state with: sudo bash scripts/watch-timer.sh install --state ${state} (docs/MONITORING.md).`);
  } else {
    const modified = lstatSync(statePath(state), { throwIfNoEntry: false })?.mtimeMs;
    if (modified === undefined) out.push(`${unit} is active but the monitoring checker has never run (no ${statePath(state)}): check journalctl -u ${unit.replace(/\.timer$/, '.service')}.`);
    else if (now - modified > CHECKER_MAX_AGE_MS) out.push(`The monitoring checker last ran ${Math.round((now - modified) / 60000)} minutes ago (it should run every 5): check journalctl -u ${unit.replace(/\.timer$/, '.service')} and node scripts/watch.mjs status.`);
  }
  // The checker no longer makes the backup itself: without the daily timer (and with no old unit that still makes it) none is made.
  // (When the checker's timer is missing, the install command it names brings the daily one too.)
  if (legacy) {
    out.push(`The daily backup still runs from the old monitoring checker unit ${unit.replace(/\.timer$/, '.service')}, inside its 5-minute run: backups continue, but a long backup holds the checks off and the services do not start at boot. ${legacyDailyAdvice(root, state)} (docs/MONITORING.md).`);
  } else if (checkerActive && !timerActive(dailyTimerUnit(state))) {
    out.push(`The daily backup timer ${dailyTimerUnit(state)} is not installed or not active, so no backup, verification or retention runs for this facility. Install it with: sudo bash scripts/watch-timer.sh install --state ${state} (docs/MONITORING.md).`);
  }
  if (!storedWebhook(state)) out.push(NO_WEBHOOK_WARNING);
  return out;
}

// Free space on the state's filesystem. A new installation (--host-preflight) needs 10 GiB. A start after a power cut does
// not: refusing it on a disk that has filled up past that point only keeps the facility down, so below 10 GiB every
// other mode prints a warning and refuses only below 2 GiB (PostgreSQL stops on a full disk).
export const MIN_FREE_NEW_BYTES = 10 * 1024 ** 3;
export const MIN_FREE_RUNNING_BYTES = 2 * 1024 ** 3;
export function freeSpaceVerdict(freeBytes, { newInstall = false } = {}) {
  const gib = (freeBytes / 1024 ** 3).toFixed(1);
  if (freeBytes < (newInstall ? MIN_FREE_NEW_BYTES : MIN_FREE_RUNNING_BYTES)) {
    return { error: `At least ${newInstall ? 10 : 2} GiB free space is required for database and storage (${gib} GiB is free).` };
  }
  if (!newInstall && freeBytes < MIN_FREE_NEW_BYTES) {
    return { warning: `Only ${gib} GiB is free on the state's disk (less than 10 GiB): the next backup, image build or upgrade may not fit. Free space or add disk soon (docs/TROUBLESHOOTING.md, "Disk full").` };
  }
  return {};
}

export const listening = port => new Promise(resolve => {
  const socket = createConnection({ host: '127.0.0.1', port });
  const done = value => { socket.destroy(); resolve(value); };
  socket.setTimeout(1000, () => done(false));
  socket.once('connect', () => done(true));
  socket.once('error', () => done(false));
});

export function validateOperatorEnv(env, stateDir) {
  const state = resolve(stateDir);
  if (env.AUTH_MODE !== 'operator' || env.APP_ENV !== 'production' || env.SMS_PROVIDER !== 'msg91' || env.SMS_PRODUCTION_MODE !== 'true') throw new Error('Operator configuration must use production mode and MSG91.');
  // One rule with the edge function (scripts/provider-placeholder.mjs): template text is never accepted,
  // the fixture sentinel `isolated-` only for a reserved .test address (CI and fixtures).
  const fixture = isFixtureAddress(env.SUPABASE_PUBLIC_URL);
  for (const key of ['MSG91_AUTH_KEY', 'MSG91_TEMPLATE_ID', 'MSG91_PE_ID', 'MSG91_SENDER_ID']) if (isProviderPlaceholder(env[key], { allowFixtureSentinel: fixture })) throw new Error(`Missing production MSG91 setting: ${key}.`);
  const origin = canonicalOrigin(env.SUPABASE_PUBLIC_URL, 'SUPABASE_PUBLIC_URL');
  if (canonicalOrigin(env.API_EXTERNAL_URL, 'API_EXTERNAL_URL') !== origin) throw new Error('Public API origins differ.');
  if (canonicalOrigin(env.CORS_ALLOWED_ORIGIN, 'CORS_ALLOWED_ORIGIN') !== canonicalOrigin(env.SITE_URL, 'SITE_URL')) throw new Error('Trusted browser origins differ.');
  const port = Number(env.KONG_HTTP_PORT);
  if (!Number.isInteger(port) || port < 1024 || port > 65535) throw new Error('Invalid KONG_HTTP_PORT.');
  if (!/^[0-9a-f]{96}$/.test(env.JWT_SECRET || '')) throw new Error('Invalid JWT_SECRET.');
  // One password per database login (docs/CONTAINER_SECURITY.md, "Database passwords").
  validateDbValues(env);
  for (const [key, role] of [['ANON_KEY', 'anon'], ['SERVICE_ROLE_KEY', 'service_role']]) {
    const parts = (env[key] || '').split('.');
    if (parts.length !== 3) throw new Error(`Invalid ${key}.`);
    const expected = createHmac('sha256', env.JWT_SECRET).update(`${parts[0]}.${parts[1]}`).digest();
    const signature = Buffer.from(parts[2], 'base64url');
    let header, payload;
    try { header = JSON.parse(Buffer.from(parts[0], 'base64url')); payload = JSON.parse(Buffer.from(parts[1], 'base64url')); } catch { throw new Error(`Invalid ${key}.`); }
    if (signature.length !== expected.length || !timingSafeEqual(signature, expected) || header.alg !== 'HS256' || payload.iss !== 'supabase' || payload.role !== role || !Number.isInteger(payload.exp) || payload.exp <= Date.now() / 1000) throw new Error(`Invalid ${key}.`);
  }
  for (const path of ['config', 'public', 'data']) {
    const part = lstatSync(resolve(state, path), { throwIfNoEntry: false });
    if (!part?.isDirectory() || part.uid !== process.getuid() || (part.mode & 0o077)) throw new Error(`State directory ${path} must be owned by this user and private.`);
  }
  for (const path of ['data/db', 'data/storage']) {
    if (!lstatSync(resolve(state, path), { throwIfNoEntry: false })?.isDirectory()) throw new Error(`State directory ${path} must be a regular directory.`);
  }
  for (const [key, path] of [['WAREHOUSE_DB_PATH', 'data/db'], ['WAREHOUSE_STORAGE_PATH', 'data/storage']]) {
    if (env[key] !== resolve(state, path)) throw new Error(`${key} must be an existing directory within selected state.`);
  }
  if (env.WAREHOUSE_MANIFEST_PATH !== resolve(state, 'public/instance.json')) throw new Error('Manifest path differs from selected state.');
  const manifestStat = lstatSync(env.WAREHOUSE_MANIFEST_PATH, { throwIfNoEntry: false });
  if (!manifestStat?.isFile() || manifestStat.uid !== process.getuid()) throw new Error('Public manifest must be an owned regular file.');
  const manifest = JSON.parse(readFileSync(env.WAREHOUSE_MANIFEST_PATH, 'utf8'));
  if (manifest.schemaVersion !== 1 || !/^[0-9a-f-]{36}$/.test(manifest.instanceId) || manifest.canonicalOrigin !== origin || !manifest.companyName || !Array.isArray(manifest.supportedApiVersions) || !manifest.supportedApiVersions.includes('1')) throw new Error('Invalid public instance manifest.');
  if (JSON.stringify(manifest).includes(env.MSG91_AUTH_KEY)) throw new Error('Public manifest contains a provider secret.');
  if (env.WAREHOUSE_PROJECT_NAME !== `warehouse-${manifest.instanceId.slice(0, 12)}`) throw new Error('Compose project differs from instance identity.');
  return { port, origin, manifest };
}

// Where the operator state may live. Returns the existing directory to measure
// free space on. A fresh install stages <state>.installing-* next to the state
// and renames it into place, so the parent must be writable even when the
// operator pre-created the (empty) state directory; a rerun of an installed
// state never stages and needs no parent write access.
export function checkStatePlacement(state, checkoutRoot = root) {
  if (!state || !state.startsWith('/') || resolve(state) === realpathSync(checkoutRoot) || resolve(state).startsWith(realpathSync(checkoutRoot) + sep)) throw new Error('Set WAREHOUSE_STATE_DIR to an absolute path outside this checkout.');
  const parent = existsSync(state) ? state : resolve(state, '..');
  const st = lstatSync(parent, { throwIfNoEntry: false });
  if (!st?.isDirectory() || st.uid !== process.getuid()) throw new Error('State directory or parent must exist and be owned by this user.');
  if (realpathSync(parent) !== resolve(parent)) throw new Error('State path must not use a symlink.');
  if (existsSync(state) && (st.mode & 0o077)) throw new Error('State directory must be mode 0700.');
  if (!existsSync(resolve(state, 'config/compose.env'))) {
    const container = resolve(state, '..');
    try {
      accessSync(container, constants.W_OK | constants.X_OK);
    } catch {
      throw new Error(`A fresh install creates its files next to the state directory, so ${container} must be writable by ${userInfo().username}. Run: sudo chown ${userInfo().username} ${container} (or choose a state path inside a directory you own), then run setup again.`);
    }
  }
  return parent;
}

export async function doctor({ hostPreflight = false, preflight = false, local = false } = {}) {
  if (process.platform !== 'linux' || process.arch !== 'x64') throw new Error('Linux x86-64 required.');
  if (!supportedNode()) throw new Error('Node.js 22.18+ required.');
  for (const [command, args] of [['npm', ['--version']], ['openssl', ['version']], ['flock', ['--version']], ['docker', ['compose', 'version']], ['docker', ['info', '--format', '{{.ServerVersion}}']]]) {
    if (!probe(command, args).ok) throw new Error(`Missing or unavailable prerequisite: ${command}${args[0] === 'compose' ? ' Compose' : ''}.`);
  }
  // The requirement is a capability, not a version: the scripts wait with `up --wait --wait-timeout`.
  if (!/--wait-timeout/.test(probe('docker', ['compose', 'up', '--help']).output)) throw new Error('This Docker Compose plugin does not accept `up --wait-timeout`; install a Compose plugin that does (see the host prerequisites).');
  const state = process.env.WAREHOUSE_STATE_DIR;
  const parent = checkStatePlacement(state);
  const fs = statfsSync(parent);
  const space = freeSpaceVerdict(Number(fs.bavail) * Number(fs.bsize), { newInstall: hostPreflight });
  if (space.error) throw new Error(space.error);
  if (space.warning) console.error(`Warning: ${space.warning}`);
  if (hostPreflight) return 'Host prerequisites and state filesystem preflight passed.';
  const envPath = resolve(state, 'config/compose.env');
  const env = readEnv(envPath);
  const envStat = lstatSync(envPath);
  if (envStat.uid !== process.getuid() || (envStat.mode & 0o077)) throw new Error('Private configuration must be owned by this user and mode 0600.');
  const { port, origin, manifest } = validateOperatorEnv(env, state);
  const owned = probe('bash', [resolve(root, 'scripts/compose.sh'), 'ps', '-q', 'kong']);
  if (!owned.ok) throw new Error('Compose configuration or project ownership check failed.');
  if (preflight) {
    if (!owned.output.trim() && await listening(port)) throw new Error(`Loopback gateway port ${port} is already in use.`);
    return 'Operator configuration, private paths and gateway port preflight passed.';
  }
  // Central sign-in from a key file: the file must be there, or every sign-in fails while the app still offers it.
  const keyFileWarning = checkCentralKeyFile(env, state);
  if (keyFileWarning) console.error(`Warning: ${keyFileWarning}`);
  // The optional letterhead image: a fault is a warning only, because the PDFs are then made without it.
  const letterheadWarning = checkLetterhead(env, state);
  if (letterheadWarning) console.error(`Warning: ${letterheadWarning}`);
  // The same check health-check.sh runs (scripts/watch.mjs, runHealth): the default-profile services (an unhealthy optional
  // service only warns), the database, the gateway's public configuration, the get_public_config RPC probe and the PDF renderer, waiting up to 90 s for the gateway after a recreate.
  const health = await runHealth(defaultDeps(process.env));
  // An upgrade that stopped half way (scripts/upgrade.sh leaves config/upgrade-in-progress): said here, healthy or not, because a
  // facility that fails its health check after one is most likely that.
  const upgradeWarning = interruptedUpgradeWarning(state);
  if (!health.ok) throw new Error(`Local service health check failed: ${health.lines.filter(line => !line.ok).map(line => line.text).join('; ')}.${stoppedByOperator(state) ? ` ${stoppedWarning}` : ''}${upgradeWarning ? ` ${upgradeWarning}` : ''}`);
  for (const line of health.lines.filter(l => l.warn)) console.error(`Warning: ${line.text}`);
  const usb = usbBackupWarning(state);
  // The monitoring checker (scripts/watch.mjs) is run by a systemd timer that an operator installs with sudo
  // (scripts/watch-timer.sh); doctor warns when it is missing, silent, or has nowhere to post.
  const checker = checkerWarnings(state);
  const note = [upgradeWarning, usb, ...checker].filter(Boolean).map(text => `\nWarning: ${text}`).join('');
  if (local) return `Local operator services and gateway are healthy.${note}`;
  const response = await fetch(`${origin}/functions/v1/get-public-config`, { signal: AbortSignal.timeout(15000), redirect: 'error' });
  if (!response.ok) throw new Error(`External public configuration returned HTTP ${response.status}.`);
  const json = await response.json();
  if (json.success !== true || json.data?.anonKey !== env.ANON_KEY || json.data?.instanceId !== manifest.instanceId || json.data?.canonicalOrigin !== origin) throw new Error('External public configuration does not match this instance.');
  return `Local services and external HTTPS discovery are healthy.${note}`;
}

// Central sign-in with keys from a file (CENTRAL_JWKS_FILE, set by setup.sh --central-jwks-file): the
// functions container reads <state>/public/<file>. compose.env comes back with a backup but the file
// does not unless the backup carries it, and an unreadable file only produces a log line in the router
// while get-public-config keeps offering central sign-in. Nothing to check when the keys are fetched
// from an address or central sign-in is off. Returns '' when the file is fine or none is configured;
// throws when it is missing or not a usable key set. Only while db:restore-host is waiting for the
// operator to put a missing file back (WAREHOUSE_CENTRAL_KEY_PENDING=yes, set by restore-host for
// restore.sh and so for this doctor) is a missing file a returned warning instead of a failure.
export function checkCentralKeyFile(env, stateDir, { pending = process.env.WAREHOUSE_CENTRAL_KEY_PENDING === 'yes' } = {}) {
  // The rule itself (plain name, regular file, 64 KB, usable key set) is centralKeyFault in doctor-common.mjs, shared with watch.mjs.
  const fault = centralKeyFault(env.CENTRAL_JWKS_FILE, stateDir);
  if (!fault) return '';
  const replace = 'Replace it with setup.sh --central-jwks-file.';
  const message = {
    name: `CENTRAL_JWKS_FILE must be a plain file name (such as central-jwks.json), not ${fault.path}.`,
    missing: `Central sign-in reads its keys from ${fault.path}, but that file is missing: every central sign-in fails while the app still offers it. `
      + `Put it back by rerunning setup.sh --operator with your usual inputs plus --central-issuer ${env.CENTRAL_ISSUER || '<issuer>'} --central-jwks-file <the key set the association sent you> (docs/OPERATOR_INSTALL.md, "Central sign-in").`,
    'not-file': `${fault.path} must be a regular file.`,
    'too-large': `${fault.path} is larger than 64 KB; central sign-in refuses it. ${replace}`,
    'not-json': `${fault.path} is not a JSON key set; central sign-in cannot verify a token. ${replace}`,
    unusable: `${fault.path} is not usable: ${fault.detail}. ${replace}`,
  }[fault.code];
  if (fault.code === 'missing' && pending) return message;
  throw new Error(message);
}

// The optional letterhead image (LETTERHEAD_FILE, set by setup.sh --letterhead-file). Returns '' when it is fine or none is
// configured, else the warning with the rerun command. Never throws: a PDF is made without an unusable letterhead, and a
// restore from an older backup (which carries none) must not fail here.
export function checkLetterhead(env, stateDir) {
  return letterheadProblem(env, stateDir);
}

if (isMain(import.meta.url)) {
  try {
    const args = process.argv.slice(2);
    if (args.some(arg => !['--host-preflight', '--preflight', '--local'].includes(arg)) || args.length > 1) throw new Error('Usage: node scripts/doctor.mjs [--host-preflight|--preflight|--local]');
    console.log(await doctor({ hostPreflight: args.includes('--host-preflight'), preflight: args.includes('--preflight'), local: args.includes('--local') }));
  } catch (error) {
    // Node's fetch reports only "fetch failed"; the reason (DNS, refused, unreachable) is in error.cause.
    const cause = error.cause ? ` (${error.cause.code ?? ''} ${error.cause.message ?? error.cause})`.replace('( ', '(') : '';
    console.error(`Doctor: ${error.message}${cause}`); process.exitCode = 1;
  }
}
