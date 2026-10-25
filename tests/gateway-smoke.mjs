import { spawnSync } from 'node:child_process';
import { randomBytes } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { readEnv, operatorEnvPath } from '../scripts/doctor-common.mjs';

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
// CORS is Kong's alone (the edge functions set no Access-Control-* header): the preflight above is answered by
// Kong itself, and an ordinary response carries Kong's configured origin, never the wildcard a function used to add.
const ordinary = async origin => {
  const response = await fetch(`${httpBase}/functions/v1/get-public-config`, { headers: { Origin: origin }, redirect: 'error', signal: AbortSignal.timeout(15000) });
  await response.body?.cancel();
  return response;
};
const trustedReply = await ordinary(allowed);
if (trustedReply.headers.get('access-control-allow-origin') !== allowed) {
  throw new Error(`A response to the trusted origin carries access-control-allow-origin ${trustedReply.headers.get('access-control-allow-origin')} instead of ${allowed}.`);
}
if (trustedReply.headers.get('x-content-type-options') !== 'nosniff') throw new Error('A function response lost its X-Content-Type-Options header.');
const untrustedReply = await ordinary('https://untrusted.invalid');
if (['*', 'https://untrusted.invalid'].includes(untrustedReply.headers.get('access-control-allow-origin'))) throw new Error('A response to an untrusted origin carries CORS permission.');

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
// storage link carries ?token=. Send one with a
// fictional value the log can be searched for, then read the gateway container's log. The path line
// must be found, or an empty read would pass. The log is read with --tail and cut at the marker's own line, not with --since:
// `compose logs --since` returned no line for any window up to an hour on a Dev host (Docker 29.9.1) while --tail worked.
const marker = randomBytes(6).toString('hex');
for (const path of [`/storage/v1/object/sign/documents/smoke-${marker}.pdf?token=smoke-token-${marker}`]) {
  const response = await fetch(`${httpBase}${path}`, { headers: { 'CF-Connecting-IP': '198.51.100.12' }, redirect: 'error', signal: AbortSignal.timeout(15000) });
  await response.body?.cancel();
}
const gatewayLog = () => {
  const result = spawnSync('bash', [fileURLToPath(new URL('../scripts/compose.sh', import.meta.url)), 'logs', '--no-color', '--no-log-prefix', '--tail', '5000', 'kong'], { encoding: 'utf8', maxBuffer: 16 * 1024 * 1024 });
  if (result.status !== 0) throw new Error(`Could not read the gateway log: ${result.stderr.trim().split('\n').pop()}`);
  return `${result.stdout}\n${result.stderr}`;
};
// From the marker's line on: the lines before it belong to earlier requests and are not this check's business.
const sinceMarker = text => { const at = text.indexOf(`smoke-${marker}.pdf`); return at < 0 ? '' : text.slice(text.lastIndexOf('\n', at) + 1); };
let log = sinceMarker(gatewayLog());
for (let attempt = 0; attempt < 10 && !log; attempt += 1) {
  await new Promise(done => setTimeout(done, 500));
  log = sinceMarker(gatewayLog());
}
if (/token=|apikey=|smoke-token-/.test(log)) throw new Error('The gateway log keeps a query-string credential (token= or apikey=).');
if (!log.includes(`"GET /storage/v1/object/sign/documents/smoke-${marker}.pdf HTTP/`)) {
  throw new Error('The gateway access log has no line for the smoke requests (or it is not in the redacted format).');
}

// The storage schema is not exposed over REST (PGRST_DB_SCHEMAS=public) and the OpenAPI document is off. PostgREST v16.4
// (checked against the pinned image): a profile for an unexposed schema is 406 PGRST106, on a read and on a write, and the
// root endpoint is 404 PGRST126 "Root endpoint metadata is disabled".
const restCall = async (path, init = {}) => {
  const response = await fetch(`${httpBase}/rest/v1/${path}`, { ...init, headers: { apikey: env.ANON_KEY, ...init.headers }, redirect: 'error', signal: AbortSignal.timeout(15000) });
  const text = await response.text();
  let body = null;
  try { body = JSON.parse(text); } catch { /* not JSON */ }
  return { status: response.status, body, text };
};
for (const [label, call] of [
  ['read with Accept-Profile: storage', () => restCall('objects?select=id&limit=1', { headers: { 'Accept-Profile': 'storage' } })],
  ['write with Content-Profile: storage', () => restCall('objects', { method: 'POST', headers: { 'Content-Profile': 'storage', 'Content-Type': 'application/json', Prefer: 'return=minimal' }, body: JSON.stringify({ name: `smoke-${marker}` }) })],
]) {
  const r = await call();
  if (r.status !== 406 || r.body?.code !== 'PGRST106') throw new Error(`The storage schema is reachable over REST (${label}): HTTP ${r.status} ${r.text.slice(0, 120)}`);
}
const root = await restCall('');
if (root.status !== 404 || root.body?.code !== 'PGRST126' || /swagger|openapi|definitions/i.test(root.text)) throw new Error(`/rest/v1/ still serves an OpenAPI document: HTTP ${root.status} ${root.text.slice(0, 120)}`);

console.log('Exact-origin CORS, request-size limit, per-client rate limit, a query-free gateway log, the storage schema off REST and no OpenAPI document passed on the loopback gateway.');
