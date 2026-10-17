import { spawnSync } from 'node:child_process';
import { randomBytes } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { readEnv, operatorEnvPath } from './doctor-common.mjs';

const env = readEnv(operatorEnvPath());
const httpBase = `http://127.0.0.1:${env.KONG_HTTP_PORT}`;
const allowed = env.CORS_ALLOWED_ORIGIN;

const preflight = async origin => fetch(`${httpBase}/functions/v1/get-public-config`, {
  method: 'OPTIONS',
  headers: { Origin: origin, 'Access-Control-Request-Method': 'GET' },
  redirect: 'error',
  signal: AbortSignal.timeout(15000),
});

const accepted = await preflight(allowed);
if (!accepted.ok || accepted.headers.get('access-control-allow-origin') !== allowed || accepted.headers.get('access-control-allow-credentials') !== 'true') {
  throw new Error(`Trusted CORS preflight failed: HTTP ${accepted.status}`);
}
const denied = await preflight('https://untrusted.invalid');
if (denied.headers.get('access-control-allow-origin') === 'https://untrusted.invalid') throw new Error('Untrusted browser origin received CORS permission.');

const oversized = await fetch(`${httpBase}/functions/v1/get-public-config`, {
  method: 'POST',
  headers: { 'content-type': 'application/json' },
  body: JSON.stringify({ value: 'x'.repeat(11 * 1024 * 1024) }),
  signal: AbortSignal.timeout(30000),
});
if (oversized.status !== 413) throw new Error(`Oversized request was not rejected: HTTP ${oversized.status}`);

// Kong keys the functions rate limit on CF-Connecting-IP (KONG_REAL_IP_HEADER):
// two requests from one client address consume one budget and a second address
// starts its own. The sequence is retried once if the minute window rolls over
// between the first two requests.
const remainingFor = async ip => {
  const response = await fetch(`${httpBase}/functions/v1/get-public-config`, {
    headers: { 'CF-Connecting-IP': ip },
    redirect: 'error',
    signal: AbortSignal.timeout(15000),
  });
  await response.body?.cancel();
  const remaining = Number(response.headers.get('x-ratelimit-remaining-minute'));
  if (!response.ok || !Number.isInteger(remaining)) throw new Error(`Functions route did not report a per-minute rate limit: HTTP ${response.status}`);
  return remaining;
};
let counts = [];
for (let attempt = 0; attempt < 2 && counts[1] !== counts[0] - 1; attempt += 1) {
  counts = [await remainingFor('198.51.100.10'), await remainingFor('198.51.100.10'), await remainingFor('198.51.100.11')];
}
const [first, second, third] = counts;
if (second !== first - 1 || third !== first) throw new Error(`Rate limit is not keyed by client IP (remaining-minute ${first}, ${second}, ${third}).`);

// The access log keeps the path, not the query string (docs/CONTAINER_SECURITY.md, "Logs"): a signed
// storage link carries ?token= and the Realtime socket address carries ?apikey=. Send both with
// fictional values the log can be searched for, then read the gateway container's log. The path line
// must be found, or an empty read would pass.
const marker = randomBytes(6).toString('hex');
const startedAt = new Date(Date.now() - 2000).toISOString();
for (const path of [`/storage/v1/object/sign/documents/smoke-${marker}.pdf?token=smoke-token-${marker}`, `/realtime/v1/websocket?apikey=smoke-apikey-${marker}&vsn=1.0.0`]) {
  const response = await fetch(`${httpBase}${path}`, { headers: { 'CF-Connecting-IP': '198.51.100.12' }, redirect: 'error', signal: AbortSignal.timeout(15000) });
  await response.body?.cancel();
}
const gatewayLog = () => {
  const result = spawnSync('bash', [fileURLToPath(new URL('./compose.sh', import.meta.url)), 'logs', '--no-color', '--no-log-prefix', '--since', startedAt, 'kong'], { encoding: 'utf8', maxBuffer: 16 * 1024 * 1024 });
  if (result.status !== 0) throw new Error(`Could not read the gateway log: ${result.stderr.trim().split('\n').pop()}`);
  return `${result.stdout}\n${result.stderr}`;
};
let log = gatewayLog();
for (let attempt = 0; attempt < 10 && !log.includes(`smoke-${marker}.pdf`); attempt += 1) {
  await new Promise(done => setTimeout(done, 500));
  log = gatewayLog();
}
if (!log.includes(`"GET /storage/v1/object/sign/documents/smoke-${marker}.pdf HTTP/`) || !log.includes('"GET /realtime/v1/websocket HTTP/')) {
  throw new Error('The gateway access log has no line for the smoke requests (or it is not in the redacted format).');
}
if (/token=|apikey=|smoke-token-|smoke-apikey-/.test(log)) throw new Error('The gateway log keeps a query-string credential (token= or apikey=).');

console.log('Exact-origin CORS, request-size limit, per-client rate limit and a query-free gateway log passed on the loopback gateway.');
