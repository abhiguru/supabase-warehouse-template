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

console.log('Exact-origin CORS, request-size limit and per-client rate limit passed on the loopback gateway.');
