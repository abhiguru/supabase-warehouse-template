import { readEnv, root } from './doctor-common.mjs';
import { request } from 'node:https';

const env = readEnv(`${root}/docker/.env`);
const httpBase = `http://127.0.0.1:${env.KONG_HTTP_PORT}`;
const httpsBase = `https://127.0.0.1:${env.KONG_HTTPS_PORT}`;
const allowed = env.CORS_ALLOWED_ORIGIN || 'http://localhost:5173';

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

// Kong's generated certificate is intentionally self-signed for this loopback-only probe.
const tlsStatus = await new Promise((resolve, reject) => {
  const req = request(`${httpsBase}/functions/v1/get-public-config`, {
    rejectUnauthorized: false,
    timeout: 15000,
  }, response => {
    response.resume();
    resolve(response.statusCode);
  });
  req.on('timeout', () => req.destroy(new Error('Local HTTPS gateway timed out.')));
  req.on('error', reject);
  req.end();
});
if (tlsStatus < 200 || tlsStatus >= 300) throw new Error(`Local HTTPS gateway failed: HTTP ${tlsStatus}`);
console.log('Exact-origin CORS, request-size limit, and loopback HTTPS gateway passed.');
