import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { supportedNode } from '../scripts/doctor-common.mjs';
import { validateDemoEnv } from '../scripts/doctor.mjs';
const env = { AUTH_MODE: 'demo', APP_ENV: 'development', BIND_ADDRESS: '127.0.0.1', KONG_HTTP_PORT: '28000', KONG_HTTPS_PORT: '28443', STUDIO_PORT: '55325', DATABASE_HOST_PORT: '25433', GOTENBERG_HOST_PORT: '23100', SUPABASE_PUBLIC_URL: 'http://localhost:28000', API_EXTERNAL_URL: 'http://localhost:28000' };
test('doctor validates supported runtime and distinct, matching loopback ports', () => {
  assert.equal(supportedNode('22.17.0'), false);
  assert.equal(supportedNode('22.18.0'), true);
  assert.deepEqual(validateDemoEnv(env), [28000, 28443, 55325, 25433, 23100]);
  for (const change of [{ BIND_ADDRESS: '0.0.0.0' }, { AUTH_MODE: 'production' }, { KONG_HTTP_PORT: 'invalid' }, { STUDIO_PORT: '28000' }, { SUPABASE_PUBLIC_URL: 'http://example.com:28000' }, { SUPABASE_PUBLIC_URL: 'http://localhost:18000' }]) assert.throws(() => validateDemoEnv({ ...env, ...change }));
});
test('documented contributor commands use ownership wrappers and disposable databases', () => {
  const text = readFileSync(new URL('../CONTRIBUTING.md', import.meta.url), 'utf8');
  assert.ok(!text.includes('docker exec -i supabase-db'));
  assert.ok(text.includes('test:migrations'));
  assert.ok(text.includes('setup.sh --demo'));
});
