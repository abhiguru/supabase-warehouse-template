import { test } from 'node:test';
import assert from 'node:assert/strict';
import { SignJWT } from 'jose';
import { verifyToken } from '../functions/_shared/jwt.ts';
import { publicBaseUrl } from '../functions/_shared/public-url.ts';

const secret = 'fresh-unit-test-secret-not-used-by-any-deployment';
const sign = (payload = {}, key = secret, alg = 'HS256') => new SignJWT({ role: 'authenticated', ...payload })
  .setProtectedHeader({ alg }).setIssuer('supabase').setExpirationTime('5m').sign(new TextEncoder().encode(key));

test('accepts a correctly signed access token', async () => {
  assert.equal((await verifyToken(await sign(), secret)).role, 'authenticated');
});
test('rejects forged service role and wrong signing key', async () => {
  await assert.rejects(verifyToken(await sign({ role: 'service_role' }, 'attacker-controlled-key'), secret));
  const token = await sign();
  const parts = token.split('.');
  parts[1] = Buffer.from(JSON.stringify({ role: 'service_role', iss: 'supabase', exp: 9999999999 })).toString('base64url');
  await assert.rejects(verifyToken(parts.join('.'), secret));
});
test('rejects expired, non-expiring, refresh, and wrong-algorithm tokens', async () => {
  for (const payload of [{ exp: 1, role: 'authenticated' }, { role: 'authenticated' }]) {
    const token = await new SignJWT(payload).setProtectedHeader({ alg: 'HS256' }).setIssuer('supabase').sign(new TextEncoder().encode(secret));
    await assert.rejects(verifyToken(token, secret));
  }
  await assert.rejects(verifyToken(await sign({ type: 'refresh' }), secret));
  await assert.rejects(verifyToken(await sign({}, secret, 'HS384'), secret));
  await assert.rejects(verifyToken(await sign(), ''));
});
test('public URL preserves device-reachable address, rejects credentials and absent config', () => {
  assert.equal(publicBaseUrl('http://192.0.2.10:18000/'), 'http://192.0.2.10:18000');
  assert.throws(() => publicBaseUrl(undefined));
  assert.throws(() => publicBaseUrl('http://user:password@example.com'));
  assert.throws(() => publicBaseUrl('file:///tmp/test'));
});
test('functions behind sign-in refuse the public anon key and the service key at the router', async () => {
  const { verifySignedInRequest } = await import('../functions/_shared/jwt.ts');
  const oldDeno = globalThis.Deno;
  globalThis.Deno = { env: { get: key => ({ JWT_SECRET: secret })[key] } };
  const request = async payload => new Request('http://example.test/get-config', { headers: { Authorization: `Bearer ${await sign(payload)}` } });
  try {
    await assert.rejects(verifySignedInRequest(await request({ role: 'anon' })), { status: 401, message: 'User access token required' });
    await assert.rejects(verifySignedInRequest(new Request('http://example.test/get-config')), { status: 401 });
    assert.equal((await verifySignedInRequest(await request({ role: 'authenticated' }))).role, 'authenticated');
    // The service key is for calls between containers, never a user of a function.
    await assert.rejects(verifySignedInRequest(await request({ role: 'service_role' })), { status: 401, message: 'User access token required' });
  } finally { globalThis.Deno = oldDeno; }
});
