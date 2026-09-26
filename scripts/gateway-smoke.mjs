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

console.log('Exact-origin CORS and request-size limit passed on the loopback gateway.');
