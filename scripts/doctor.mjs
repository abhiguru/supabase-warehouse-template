import { accessSync, constants, existsSync, lstatSync, statfsSync, realpathSync, readFileSync } from 'node:fs';
import { userInfo } from 'node:os';
import { join, resolve, sep } from 'node:path';
import { createConnection } from 'node:net';
import { spawnSync } from 'node:child_process';
import { createHash, createHmac, timingSafeEqual } from 'node:crypto';
import { centralKeyFault, probe, readEnv, root, supportedNode } from './doctor-common.mjs';
import { canonicalOrigin } from './configure.mjs';
import { validateDbValues } from './db-roles.mjs';
import { isFixtureAddress, isProviderPlaceholder } from './provider-placeholder.mjs';
import { isMain } from './is-main.mjs';
import { usbBackupWarning } from './usb-backup-status.mjs';
import { storedWebhook } from './alert-webhook.mjs';
import { defaultDeps, runHealth, statePath } from './watch.mjs';

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
const unitDir = () => process.env.WAREHOUSE_WATCH_UNIT_DIR || '/etc/systemd/system';
export const NO_WEBHOOK_WARNING = 'No Slack webhook: alerts are recorded on this host but not delivered, so nobody is told when a backup fails or the database stops. That is acceptable only for a test install. For a real facility, rerun setup.sh --operator with your usual inputs, leaving out --alert-webhook-file off (it then asks for the URL on a terminal), or pass --alert-webhook-file <a private file holding the URL> (docs/MONITORING.md, "Alert delivery").';

// The daily pass (backup, verification, retention) holds the checker for up to 4 hours (the unit's TimeoutStartSec),
// and the state file is not written meanwhile: a pass that started less than 4 hours ago explains the silence.
export const DAILY_PASS_MAX_MS = 4 * 60 * 60 * 1000;
function dailyPassRunning(state, now) {
  try {
    const started = JSON.parse(readFileSync(statePath(state), 'utf8'))?.dailyRunning?.startedAt;
    return Number.isFinite(started) && now >= started && now - started < DAILY_PASS_MAX_MS;
  } catch { return false; }
}

// Warnings about the checker: its timer is not active, it has not run in the last 15 minutes (the mtime of its
// state file), no Slack webhook is stored. `timerActive(unit)` and `now` are injectable for tests.
export function checkerWarnings(state, {
  now = Date.now(),
  timerActive = unit => spawnSync('systemctl', ['is-active', '--quiet', unit], { timeout: 10000 }).status === 0,
  serviceText = unit => { try { return readFileSync(join(unitDir(), unit.replace(/\.timer$/, '.service')), 'utf8'); } catch { return null; } },
} = {}) {
  const out = [];
  const unit = timerUnit(state);
  if (!timerActive(unit)) {
    out.push(`The monitoring checker is not running: ${unit} is not installed or not active, so no check, alert, daily backup or retention runs for this facility. Install it with: sudo bash scripts/watch-timer.sh install --state ${state} (docs/MONITORING.md).`);
  } else if (serviceText(unit) !== null && !serviceText(unit).split('\n').includes(`Environment=WAREHOUSE_STATE_DIR=${state}`)) {
    out.push(`${unit} is active but its service does not name this state (${state}), so this facility is not being checked. Install it for this state with: sudo bash scripts/watch-timer.sh install --state ${state} (docs/MONITORING.md).`);
  } else {
    const modified = lstatSync(statePath(state), { throwIfNoEntry: false })?.mtimeMs;
    if (modified === undefined) out.push(`${unit} is active but the monitoring checker has never run (no ${statePath(state)}): check journalctl -u ${unit.replace(/\.timer$/, '.service')}.`);
    else if (now - modified > CHECKER_MAX_AGE_MS && !dailyPassRunning(state, now)) out.push(`The monitoring checker last ran ${Math.round((now - modified) / 60000)} minutes ago (it should run every 5): check journalctl -u ${unit.replace(/\.timer$/, '.service')} and node scripts/watch.mjs status.`);
  }
  if (!storedWebhook(state)) out.push(NO_WEBHOOK_WARNING);
  return out;
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
  if (Number(fs.bavail) * Number(fs.bsize) < 10 * 1024 ** 3) throw new Error('At least 10 GiB free space is required for database and storage.');
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
  // The same check health-check.sh runs (scripts/watch.mjs, runHealth): the 6 default services, the database, the gateway's
  // public configuration, a REST read and the PDF renderer, waiting up to 90 s for the gateway after a recreate.
  const health = await runHealth(defaultDeps(process.env));
  if (!health.ok) throw new Error(`Local service health check failed: ${health.lines.filter(line => !line.ok).map(line => line.text).join('; ')}.`);
  for (const line of health.lines.filter(l => l.warn)) console.error(`Warning: ${line.text}`);
  const usb = usbBackupWarning(state);
  // The monitoring checker (scripts/watch.mjs) is run by a systemd timer that an operator installs with sudo
  // (scripts/watch-timer.sh); doctor warns when it is missing, silent, or has nowhere to post.
  const checker = checkerWarnings(state);
  const note = [usb, ...checker].filter(Boolean).map(text => `\nWarning: ${text}`).join('');
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

if (isMain(import.meta.url)) {
  try {
    const args = process.argv.slice(2);
    if (args.some(arg => !['--host-preflight', '--preflight', '--local'].includes(arg)) || args.length > 1) throw new Error('Usage: node scripts/doctor.mjs [--host-preflight|--preflight|--local]');
    console.log(await doctor({ hostPreflight: args.includes('--host-preflight'), preflight: args.includes('--preflight'), local: args.includes('--local') }));
  } catch (error) { console.error(`Doctor: ${error.message}`); process.exitCode = 1; }
}
