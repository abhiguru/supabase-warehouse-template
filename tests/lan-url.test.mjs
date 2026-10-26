// The LAN fallback address in the configuration answers: get-config (signed-in users) offers it as urls.lan while the operator has the
// fallback on; get-public-config (readable by anyone on the internet) never does. Runs the two functions' own code with a stand-in
// Deno and a stand-in PostgREST; nothing is started.
import { after, before, test } from 'node:test';
import assert from 'node:assert/strict';
import { SignJWT } from 'jose';
import { lanOrigin } from '../functions/_shared/lan-url.ts';
import { workerEnv, workerEnvNames } from '../functions/main/worker-env.ts';
import { readFileSync } from 'node:fs';

const read = path => readFileSync(new URL(`../${path}`, import.meta.url), 'utf8');

test('lanOrigin: only an enabled fallback with a private IPv4 address and a valid port is offered', () => {
  const origin = (enabled, address, port) => lanOrigin({ enabled, address, port });
  assert.equal(origin('true', '192.168.1.52', '8080'), 'http://192.168.1.52:8080');
  assert.equal(origin('true', '10.0.0.7', '8181'), 'http://10.0.0.7:8181');
  assert.equal(origin('true', '172.16.0.9', undefined), 'http://172.16.0.9:8080', 'no port: the default');
  assert.equal(origin('true', '172.31.255.254', ''), 'http://172.31.255.254:8080');
  // Off, or anything but the exact word.
  for (const enabled of [undefined, '', 'false', 'TRUE', 'yes', '1', 'true ']) assert.equal(origin(enabled, '192.168.1.52', '8080'), null, String(enabled));
  // An address that is not private, not an address, or written oddly is left out, not offered to every phone.
  for (const address of [undefined, '', '8.8.8.8', '127.0.0.1', '0.0.0.0', '172.15.0.1', '172.32.0.1', '192.167.1.1', '100.64.0.1', '192.168.1.256', '192.168.1', '192.168.01.1', 'localhost', '192.168.1.1/24', 'http://192.168.1.1', '192.168.1.1:8080', '::1']) {
    assert.equal(origin('true', address, '8080'), null, String(address));
  }
  for (const port of ['80', '1023', '65536', '0', 'abc', '8080 ', '-1', '08080x']) assert.equal(origin('true', '192.168.1.52', port), null, port);
});

test('worker environments: get-config reads the three LAN names and no other function does', () => {
  assert.deepEqual(workerEnvNames['get-config'].filter(name => name.startsWith('LAN_')).sort(), ['LAN_BIND_IP', 'LAN_ENABLED', 'LAN_HTTP_PORT']);
  for (const [name, list] of Object.entries(workerEnvNames)) {
    if (name !== 'get-config') assert.deepEqual(list.filter(item => item.startsWith('LAN_')), [], `${name} gets a LAN name`);
  }
  const container = { LAN_ENABLED: 'true', LAN_BIND_IP: '192.168.1.52', LAN_HTTP_PORT: '8080', JWT_SECRET: 'x'.repeat(40), PATH: '/usr/bin' };
  assert.deepEqual(Object.fromEntries(workerEnv('get-config', container)), { JWT_SECRET: container.JWT_SECRET, LAN_ENABLED: 'true', LAN_BIND_IP: '192.168.1.52', LAN_HTTP_PORT: '8080' });
  assert.deepEqual(workerEnv('get-public-config', container), []);
  // The function runtime is given the three names (docker/docker-compose.yml) and get-public-config's code does not mention them.
  assert.match(read('docker/docker-compose.yml'), /\n      LAN_ENABLED: \$\{LAN_ENABLED:-\}\n      LAN_BIND_IP: \$\{LAN_BIND_IP:-\}\n      LAN_HTTP_PORT: \$\{LAN_HTTP_PORT:-\}\n/);
  assert.doesNotMatch(read('functions/get-public-config/index.ts'), /LAN_|lan-url|lanOrigin|\blan\b/);
});

// ---- the two functions, run ---------------------------------------------------------------------------------------------------------
const secret = 'lan-url-unit-test-signing-secret-0123456789';
const SUB = '11111111-2222-3333-4444-555555555555';
const MANIFEST = { schemaVersion: 1, instanceId: '99999999-aaaa-bbbb-cccc-dddddddddddd', displayName: 'Acme', companyName: 'Acme Cold', canonicalOrigin: 'https://api.example.test',
  capabilities: { sensors: false, printing: false }, supportedApiVersions: ['1'], minimumClientVersion: '0.1.0' };
const BASE_ENV = {
  JWT_SECRET: secret, SUPABASE_URL: 'http://gateway:8000', SUPABASE_REST_URL: 'http://rest:3000', SUPABASE_SERVICE_ROLE_KEY: 'unit-service', SUPABASE_ANON_KEY: 'unit-anon',
  SUPABASE_PUBLIC_URL: 'https://api.example.test', APP_ENV: 'production', AUTH_MODE: 'operator', INSTANCE_MANIFEST_JSON: JSON.stringify(MANIFEST),
};
const handlers = {};
let env = {};
const realDeno = globalThis.Deno;
const realFetch = globalThis.fetch;
const json = (body, status = 200) => new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json' } });

before(async () => {
  let current;
  globalThis.Deno = { serve: handler => { handlers[current] = handler; }, env: { get: name => env[name] } };
  // PostgREST, as the two functions read it.
  globalThis.fetch = async url => {
    const path = new URL(url).pathname;
    if (path.endsWith('/user_profiles')) return json([{ id: 'p1', auth_user_id: SUB, name: 'A', display_name: 'A', mobile: '9000000000', role: 'admin', active: true }]);
    if (path.endsWith('/api_configurations')) return json({ app_version: '1.2.3', build_date: '2026-10-01', maintenance_mode: false });
    if (path.endsWith('/feature_flags') || path.endsWith('/system_settings')) return json([]);
    if (path.endsWith('/sms_config')) return json({ production_mode: true, provider: 'msg91' });
    if (path.endsWith('/rpc/get_public_config')) return json({ app_version: '1.2.3', maintenance_mode: false, feature_flags: {} });
    return json({ message: `unexpected ${path}` }, 404);
  };
  current = 'get-config';
  await import('../functions/get-config/index.ts');
  current = 'get-public-config';
  await import('../functions/get-public-config/index.ts');
});
after(() => { globalThis.Deno = realDeno; globalThis.fetch = realFetch; });

async function getConfig(extra) {
  env = { ...BASE_ENV, ...extra };
  const token = await new SignJWT({ role: 'authenticated', sub: SUB }).setProtectedHeader({ alg: 'HS256' }).setIssuer('supabase').setExpirationTime('5m').sign(new TextEncoder().encode(secret));
  const response = await handlers['get-config'](new Request('http://example.test/get-config', { headers: { Authorization: `Bearer ${token}` } }));
  assert.equal(response.status, 200, await response.clone().text());
  return response.json();
}
async function getPublicConfig(extra) {
  env = { ...BASE_ENV, ...extra };
  const response = await handlers['get-public-config'](new Request('http://example.test/get-public-config'));
  assert.equal(response.status, 200, await response.clone().text());
  const body = await response.json();
  return { body, text: JSON.stringify(body) };
}
const ON = { LAN_ENABLED: 'true', LAN_BIND_IP: '192.168.1.52', LAN_HTTP_PORT: '8080' };

test('get-config: urls.lan is present only while the fallback is on, and is the plain-http address', async () => {
  const off = await getConfig({});
  assert.deepEqual(Object.keys(off.data.urls), ['api', 'storage', 'realtime', 'auth'], 'absent while off: the answer is as it was before the fallback existed');
  assert.deepEqual(Object.keys((await getConfig({ ...ON, LAN_ENABLED: 'false' })).data.urls), ['api', 'storage', 'realtime', 'auth']);
  assert.deepEqual(Object.keys((await getConfig({ LAN_BIND_IP: '192.168.1.52', LAN_HTTP_PORT: '8080' })).data.urls), ['api', 'storage', 'realtime', 'auth'], 'an address without the switch is not offered');
  const on = await getConfig(ON);
  assert.equal(on.success, true);
  assert.equal(on.data.urls.lan, 'http://192.168.1.52:8080');
  assert.equal(on.data.urls.api, 'https://api.example.test/rest/v1', 'the other urls are unchanged');
  assert.equal((await getConfig({ ...ON, LAN_HTTP_PORT: '8181', LAN_BIND_IP: '10.0.0.7' })).data.urls.lan, 'http://10.0.0.7:8181');
  // A damaged value is left out rather than offered to every phone.
  for (const bad of [{ LAN_BIND_IP: '8.8.8.8' }, { LAN_BIND_IP: '' }, { LAN_HTTP_PORT: '80' }, { LAN_BIND_IP: '192.168.1.52/24' }]) {
    assert.equal((await getConfig({ ...ON, ...bad })).data.urls.lan, undefined, JSON.stringify(bad));
  }
});

test('get-public-config never carries the LAN address, whatever the environment says', async () => {
  const off = await getPublicConfig({});
  const on = await getPublicConfig(ON);
  assert.equal(on.body.success, true);
  assert.deepEqual(on.body.data.urls, { publicConfig: 'https://api.example.test/functions/v1/get-public-config', fullConfig: 'https://api.example.test/functions/v1/get-config' });
  assert.equal(on.text.includes('192.168.1.52'), false);
  assert.equal(/"lan"|lan/i.test(JSON.stringify(on.body.data.urls)), false);
  // Apart from the time stamp, the answer is the same with the fallback on and off.
  assert.deepEqual({ ...on.body, timestamp: 0 }, { ...off.body, timestamp: 0 });
});
