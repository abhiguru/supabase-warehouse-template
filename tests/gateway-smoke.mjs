import { spawnSync } from 'node:child_process';
import { randomBytes } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { gatewayPortText, readEnv, operatorEnvPath } from '../scripts/doctor-common.mjs';

const env = readEnv(operatorEnvPath());
const httpBase = `http://127.0.0.1:${gatewayPortText(env)}`;
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
// The preflight of the functions route lists its methods and headers and is cached for a day.
if (accepted.headers.get('access-control-allow-methods') !== 'GET,POST,PUT,DELETE,OPTIONS' || accepted.headers.get('access-control-max-age') !== '86400') {
  throw new Error(`The CORS preflight lacks the route's methods or its cache time: ${accepted.headers.get('access-control-allow-methods')} / ${accepted.headers.get('access-control-max-age')}.`);
}
const denied = await preflight('https://untrusted.invalid');
// The configured origin is sent whatever the request says; an untrusted origin is never named.
if (denied.headers.get('access-control-allow-origin') === 'https://untrusted.invalid' || denied.headers.get('access-control-allow-origin') === '*') throw new Error('Untrusted browser origin received CORS permission.');
// CORS is the gateway's alone (the edge functions set no Access-Control-* header): the preflight above is answered by
// the gateway itself, and an ordinary response carries its configured origin, never the wildcard a function used to add.
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

// The limits are a leaky bucket per client address, and the address is CF-Connecting-IP (this request comes from the loopback
// hop, which the gateway trusts). Each check uses an address of its own, drawn at random from the documentation range
// 2001:db8::/32, so a rerun a moment later meets an empty bucket and no real client's budget is touched.
const address = () => `2001:db8:5eed::${randomBytes(2).toString('hex')}`;
const status = async (path, ip, init = {}) => {
  const response = await fetch(`${httpBase}${path}`, { redirect: 'error', signal: AbortSignal.timeout(30000), ...init, headers: { 'CF-Connecting-IP': ip, ...init.headers } });
  const text = await response.text();
  return { status: response.status, headers: response.headers, text };
};
// The functions route: a bucket of 100 that empties at 100 a minute. Requests one after the other from one address: the first
// 429 comes after about 100 answers (101 with the request that opens the bucket, and the 1 per 0.6 s that drained meanwhile),
// the JSON body and Retry-After are the documented ones, and another address is not affected.
{
  const ip = address();
  const started = Date.now();
  let passed = 0;
  let refused = null;
  while (!refused && passed < 160) {
    const answer = await status('/functions/v1/get-public-config', ip);
    if (answer.status === 429) refused = answer; else if (answer.status === 200) passed += 1; else throw new Error(`Functions route answered HTTP ${answer.status} before its limit.`);
  }
  const seconds = (Date.now() - started) / 1000;
  if (!refused) throw new Error(`The functions route passed ${passed} requests from one address in ${seconds.toFixed(1)} s without a 429.`);
  const most = 101 + Math.ceil(seconds * 100 / 60) + 2;
  if (passed < 100 || passed > most) throw new Error(`The functions bucket passed ${passed} requests in ${seconds.toFixed(1)} s (expected 100 to ${most}).`);
  if (refused.text !== '{"message":"API rate limit exceeded"}' || refused.headers.get('retry-after') !== '1' || !/^application\/json/.test(refused.headers.get('content-type') ?? '')) {
    throw new Error(`The 429 answer is not the documented one: ${refused.text.slice(0, 80)} / retry-after ${refused.headers.get('retry-after')}.`);
  }
  const other = await status('/functions/v1/get-public-config', address());
  if (other.status !== 200) throw new Error(`Another client address was refused (HTTP ${other.status}) after ${ip} used its bucket: the limit is not keyed by client address.`);
}

// The REST route: a bucket of 1800 that empties at 30 a second. The root endpoint is the cheapest call (PostgREST answers 404
// PGRST126 for it, below). Batches of 100 at once from one address until a 429; the number answered otherwise is what the
// gateway let in: the burst of 1800 (1801 with the request that opens the bucket) plus what drained at 30 a second meanwhile.
{
  const ip = address();
  const started = Date.now();
  let admitted = 0;
  let limited = 0;
  let sent = 0;
  while (!limited && sent < 6000 && Date.now() - started < 60000) {
    const batch = await Promise.all(Array.from({ length: 100 }, () => status('/rest/v1/', ip, { headers: { apikey: env.ANON_KEY } })));
    sent += batch.length;
    for (const answer of batch) { if (answer.status === 429) limited += 1; else admitted += 1; }
  }
  const seconds = (Date.now() - started) / 1000;
  if (!limited) throw new Error(`The REST route passed ${admitted} requests from one address in ${seconds.toFixed(1)} s without a 429.`);
  const most = 1801 + Math.ceil(seconds * 30) + 10;
  if (admitted < 1800 || admitted > most) throw new Error(`The REST bucket passed ${admitted} requests in ${seconds.toFixed(1)} s (expected 1800 to ${most}).`);
  const other = await status('/rest/v1/', address(), { headers: { apikey: env.ANON_KEY } });
  if (other.status === 429) throw new Error('Another client address was refused on the REST route after one used its bucket: the limit is not keyed by client address.');
}

// The key check of the REST route (and of it alone): the two answers the mobile app reads, and the right key goes through. These
// are refused before the rate limit, so they use no budget.
{
  const ip = address();
  const missing = await status('/rest/v1/rpc/get_public_config', ip, { method: 'POST', headers: { 'content-type': 'application/json' }, body: '{}' });
  if (missing.status !== 401 || missing.text !== '{"message":"No API key found in request"}') throw new Error(`No apikey: HTTP ${missing.status} ${missing.text.slice(0, 80)}.`);
  const wrong = await status('/rest/v1/rpc/get_public_config', ip, { method: 'POST', headers: { 'content-type': 'application/json', apikey: 'not-a-key' }, body: '{}' });
  if (wrong.status !== 401 || wrong.text !== '{"message":"Unauthorized"}') throw new Error(`Wrong apikey: HTTP ${wrong.status} ${wrong.text.slice(0, 80)}.`);
  const good = await status('/rest/v1/rpc/get_public_config', ip, { method: 'POST', headers: { 'content-type': 'application/json', apikey: env.ANON_KEY }, body: JSON.stringify({ p_environment: 'production' }) });
  if (good.status === 401) throw new Error('The anon key was refused by the key check.');
  const open = await status('/functions/v1/get-public-config', ip);
  if (open.status !== 200) throw new Error(`The functions route needs no key but answered HTTP ${open.status}.`);
  // nginx names itself and no version.
  if (open.headers.get('server') !== 'nginx') throw new Error(`The Server header is "${open.headers.get('server')}", not "nginx".`);
}

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
  const result = spawnSync('bash', [fileURLToPath(new URL('../scripts/compose.sh', import.meta.url)), 'logs', '--no-color', '--no-log-prefix', '--tail', '5000', 'gateway'], { encoding: 'utf8', maxBuffer: 16 * 1024 * 1024 });
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

console.log('Exact-origin CORS, request-size limit, per-client rate limits (functions and REST), the key check, a query-free gateway log, the storage schema off REST and no OpenAPI document passed on the loopback gateway.');
