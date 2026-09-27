import { existsSync, lstatSync, statfsSync, realpathSync, readFileSync } from 'node:fs';
import { resolve, sep } from 'node:path';
import { createConnection } from 'node:net';
import { createHmac, timingSafeEqual } from 'node:crypto';
import { probe, readEnv, root, supportedNode } from './doctor-common.mjs';
import { canonicalOrigin } from './configure.mjs';
import { isMain } from './is-main.mjs';

export const listening = port => new Promise(resolve => {
  const socket = createConnection({ host: '127.0.0.1', port });
  const done = value => { socket.destroy(); resolve(value); };
  socket.setTimeout(1000, () => done(false));
  socket.once('connect', () => done(true));
  socket.once('error', () => done(false));
});

export function validateOperatorEnv(env, stateDir) {
  const state = resolve(stateDir);
  if (env.AUTH_MODE !== 'operator' || env.APP_ENV !== 'production' || env.BIND_ADDRESS !== '127.0.0.1' || env.SMS_PROVIDER !== 'msg91' || env.SMS_PRODUCTION_MODE !== 'true') throw new Error('Operator configuration must use production mode, MSG91 and loopback gateway.');
  for (const key of ['MSG91_AUTH_KEY', 'MSG91_TEMPLATE_ID', 'MSG91_PE_ID', 'MSG91_SENDER_ID']) if (!env[key] || /^(your-|changeme|fake_)/i.test(env[key])) throw new Error(`Missing production MSG91 setting: ${key}.`);
  const origin = canonicalOrigin(env.SUPABASE_PUBLIC_URL, 'SUPABASE_PUBLIC_URL');
  if (canonicalOrigin(env.API_EXTERNAL_URL, 'API_EXTERNAL_URL') !== origin) throw new Error('Public API origins differ.');
  if (canonicalOrigin(env.CORS_ALLOWED_ORIGIN, 'CORS_ALLOWED_ORIGIN') !== canonicalOrigin(env.SITE_URL, 'SITE_URL')) throw new Error('Trusted browser origins differ.');
  const port = Number(env.KONG_HTTP_PORT);
  if (!Number.isInteger(port) || port < 1024 || port > 65535) throw new Error('Invalid KONG_HTTP_PORT.');
  if (!/^[0-9a-f]{96}$/.test(env.JWT_SECRET || '')) throw new Error('Invalid JWT_SECRET.');
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

export async function doctor({ hostPreflight = false, preflight = false, local = false } = {}) {
  if (process.platform !== 'linux' || process.arch !== 'x64') throw new Error('Linux x86-64 required.');
  if (!supportedNode()) throw new Error('Node.js 22.18+ required.');
  for (const [command, args] of [['npm', ['--version']], ['openssl', ['version']], ['flock', ['--version']], ['docker', ['compose', 'version']], ['docker', ['info', '--format', '{{.ServerVersion}}']]]) {
    if (!probe(command, args).ok) throw new Error(`Missing or unavailable prerequisite: ${command}${args[0] === 'compose' ? ' Compose v2' : ''}.`);
  }
  const state = process.env.WAREHOUSE_STATE_DIR;
  if (!state || !state.startsWith('/') || resolve(state) === realpathSync(root) || resolve(state).startsWith(realpathSync(root) + sep)) throw new Error('Set WAREHOUSE_STATE_DIR to an absolute path outside this checkout.');
  const parent = existsSync(state) ? state : resolve(state, '..');
  const st = lstatSync(parent, { throwIfNoEntry: false });
  if (!st?.isDirectory() || st.uid !== process.getuid()) throw new Error('State directory or parent must exist and be owned by this user.');
  if (realpathSync(parent) !== resolve(parent)) throw new Error('State path must not use a symlink.');
  if (existsSync(state) && (st.mode & 0o077)) throw new Error('State directory must be mode 0700.');
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
  // The script probes seven containers plus three HTTP endpoints. Its own
  // bounded readiness retries can exceed the short CLI-preflight deadline.
  if (!probe('bash', [resolve(root, 'health-check.sh')], 300000).ok) throw new Error('Local service health check failed.');
  if (local) return 'Local operator services and gateway are healthy.';
  const response = await fetch(`${origin}/functions/v1/get-public-config`, { signal: AbortSignal.timeout(15000), redirect: 'error' });
  if (!response.ok) throw new Error(`External public configuration returned HTTP ${response.status}.`);
  const json = await response.json();
  if (json.success !== true || json.data?.anonKey !== env.ANON_KEY || json.data?.instanceId !== manifest.instanceId || json.data?.canonicalOrigin !== origin) throw new Error('External public configuration does not match this instance.');
  return 'Local services and external HTTPS discovery are healthy.';
}

if (isMain(import.meta.url)) {
  try {
    const args = process.argv.slice(2);
    if (args.some(arg => !['--host-preflight', '--preflight', '--local'].includes(arg)) || args.length > 1) throw new Error('Usage: node scripts/doctor.mjs [--host-preflight|--preflight|--local]');
    console.log(await doctor({ hostPreflight: args.includes('--host-preflight'), preflight: args.includes('--preflight'), local: args.includes('--local') }));
  } catch (error) { console.error(`Doctor: ${error.message}`); process.exitCode = 1; }
}
