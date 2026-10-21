import { test } from 'node:test';
import assert from 'node:assert/strict';
import { SignJWT } from 'jose';
import { validateUserAccess, validatePrintAccess } from '../functions/_shared/auth-helpers.ts';

const secret = 'isolated-profile-test-secret-never-used-in-a-deployment';
const userId = '00000000-0000-4000-8000-000000000001';
const sign = (role = 'authenticated') => new SignJWT({ role, sub: userId })
  .setProtectedHeader({ alg: 'HS256' }).setIssuer('supabase').setExpirationTime('5m').sign(new TextEncoder().encode(secret));
const request = async (role) => new Request('http://example.test', { headers: { Authorization: `Bearer ${await sign(role)}` } });

test('the profile lookup goes to PostgREST directly when SUPABASE_REST_URL is set, and through the gateway otherwise', async () => {
  const oldDeno = globalThis.Deno, oldFetch = globalThis.fetch;
  const urls = [];
  globalThis.fetch = async (url, init) => { urls.push([String(url), Object.keys(init.headers).sort().join()]); return new Response(JSON.stringify([{ id: userId, auth_user_id: userId, role: 'admin', active: true }])); };
  try {
    for (const direct of [undefined, 'http://rest:3000/']) {
      globalThis.Deno = { env: { get: key => ({ JWT_SECRET: secret, SUPABASE_URL: 'http://kong:8000', SUPABASE_SERVICE_ROLE_KEY: 'unit-test-only', SUPABASE_REST_URL: direct })[key] } };
      await validateUserAccess(await request());
    }
    const query = `/user_profiles?auth_user_id=eq.${userId}&select=id,auth_user_id,name,display_name,mobile,role,active`;
    assert.deepEqual(urls, [[`http://kong:8000/rest/v1${query}`, 'Authorization,apikey'], [`http://rest:3000${query}`, 'Authorization,apikey']]);
  } finally { globalThis.fetch = oldFetch; globalThis.Deno = oldDeno; }
});

test('profile lookup requires signed user token; inactive/customer roles cannot print', async () => {
  const oldDeno = globalThis.Deno, oldFetch = globalThis.fetch;
  globalThis.Deno = { env: { get: key => ({ JWT_SECRET: secret, SUPABASE_URL: 'http://example.test', SUPABASE_SERVICE_ROLE_KEY: 'unit-test-only' })[key] } };
  let profile = { id: userId, auth_user_id: userId, role: 'customer', active: true };
  let calls = 0;
  globalThis.fetch = async () => { calls++; return new Response(JSON.stringify([profile])); };
  try {
    await assert.rejects(validateUserAccess(new Request('http://example.test')), { status: 401 });
    await assert.rejects(validateUserAccess(await request('anon')), { status: 401 });
    // The service key is not a user: no synthetic administrator profile, and no profile lookup.
    await assert.rejects(validateUserAccess(await request('service_role')), { status: 401, message: 'User access token required' });
    await assert.rejects(validatePrintAccess(await request('service_role')), { status: 401 });
    assert.equal(calls, 0);
    await assert.rejects(validatePrintAccess(await request()), { status: 403 });
    profile = { ...profile, role: 'admin', active: false };
    await assert.rejects(validatePrintAccess(await request()), { status: 403 });
    profile = { ...profile, role: 'supervisor', active: true };
    assert.equal((await validatePrintAccess(await request())).role, 'supervisor');
  } finally { globalThis.fetch = oldFetch; globalThis.Deno = oldDeno; }
});
