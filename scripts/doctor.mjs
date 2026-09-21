import { existsSync } from 'node:fs';
import { resolve } from 'node:path';
import { createConnection } from 'node:net';
import { probe, readEnv, root, supportedNode } from './doctor-common.mjs';
import { isMain } from './is-main.mjs';

export function validateDemoEnv(env) {
  if (env.AUTH_MODE !== 'demo' || env.APP_ENV !== 'development' || env.BIND_ADDRESS !== '127.0.0.1') {
    throw new Error('Demo requires AUTH_MODE=demo, APP_ENV=development and BIND_ADDRESS=127.0.0.1.');
  }
  const ports = ['KONG_HTTP_PORT', 'KONG_HTTPS_PORT', 'STUDIO_PORT', 'DATABASE_HOST_PORT', 'GOTENBERG_HOST_PORT'].map(key => {
    if (!/^\d+$/.test(env[key] || '') || Number(env[key]) < 1024 || Number(env[key]) > 65535) throw new Error(`Invalid ${key}; use an unused port from 1024 to 65535.`);
    return Number(env[key]);
  });
  if (new Set(ports).size !== ports.length) throw new Error('Demo host ports must be distinct.');
  for (const key of ['SUPABASE_PUBLIC_URL', 'API_EXTERNAL_URL']) {
    let url;
    try { url = new URL(env[key]); } catch { throw new Error(`Invalid ${key}.`); }
    if (url.protocol !== 'http:' || !['localhost', '127.0.0.1'].includes(url.hostname) || Number(url.port) !== ports[0] || url.username || url.password || url.pathname !== '/' || url.search || url.hash) {
      throw new Error(`${key} must be a loopback HTTP origin matching KONG_HTTP_PORT.`);
    }
  }
  if (new URL(env.SUPABASE_PUBLIC_URL).origin !== new URL(env.API_EXTERNAL_URL).origin) throw new Error('Public API origins must match.');
  return ports;
}

export const listening = port => new Promise(resolve => {
  const socket = createConnection({ host: '127.0.0.1', port });
  const done = value => { socket.destroy(); resolve(value); };
  socket.setTimeout(1000, () => done(false));
  socket.once('connect', () => done(true));
  socket.once('error', () => done(false));
});

export async function doctor({ preflight = false } = {}) {
  if (!supportedNode()) throw new Error('Node.js 22.18+ required.');
  for (const [command, args] of [['npm', ['--version']], ['openssl', ['version']], ['docker', ['compose', 'version']], ['docker', ['info', '--format', '{{.ServerVersion}}']]]) {
    if (!probe(command, args).ok) throw new Error(`Missing or unavailable prerequisite: ${command}${args[0] === 'compose' ? ' Compose v2' : ''}.`);
  }
  const envPath = resolve(root, 'docker/.env');
  if (preflight && !existsSync(envPath)) return 'Prerequisites available; setup can create fresh configuration.';
  const env = readEnv(envPath);
  const ports = validateDemoEnv(env);
  // The wrapper checks project ownership before even a read-only Compose call.
  const owned = probe('bash', [resolve(root, 'scripts/compose.sh'), 'ps', '-q']);
  if (!owned.ok) throw new Error('Compose ownership/configuration check failed; choose a unique WAREHOUSE_PROJECT_NAME for this checkout.');
  if (preflight) {
    if (!owned.output.trim()) for (const port of ports) {
      if (await listening(port)) throw new Error(`Loopback port ${port} is already in use; select unused ports before setup.`);
    }
    return 'Demo configuration and ownership preflight passed.';
  }
  if (!probe('bash', [resolve(root, 'health-check.sh')]).ok) throw new Error('Demo services are unavailable; run bash health-check.sh for service status.');
  const response = await fetch(`${env.SUPABASE_PUBLIC_URL}/functions/v1/get-public-config`, { signal: AbortSignal.timeout(15000), redirect: 'error' });
  if (!response.ok) throw new Error(`Public bootstrap returned HTTP ${response.status}.`);
  const json = await response.json();
  if (json.success !== true || json.data?.anonKey !== env.ANON_KEY || json.data?.supabaseUrl !== new URL(env.SUPABASE_PUBLIC_URL).origin) throw new Error('Bootstrap does not match this checkout.');
  return 'Demo prerequisites, ownership, service health and public bootstrap passed. No configuration or services changed.';
}

if (isMain(import.meta.url)) {
  try { console.log(await doctor({ preflight: process.argv.includes('--preflight') })); }
  catch (error) { console.error(`Doctor: ${error.message}`); process.exitCode = 1; }
}
