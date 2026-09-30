import test from 'node:test';
import assert from 'node:assert/strict';
import { validateSwitchingConfig, switchingOrigin, switchingCompany } from '../scripts/switch-fixture-common.mjs';

const state = '/private/cross-instance-test-123';
const manifest = { instanceId: '01234567-89ab-4cde-8fab-0123456789ab', companyName: switchingCompany, canonicalOrigin: switchingOrigin };
const env = { AUTH_MODE: 'operator', BIND_ADDRESS: '127.0.0.1', SUPABASE_PUBLIC_URL: switchingOrigin,
  MSG91_AUTH_KEY: 'isolated-no-delivery-key', WAREHOUSE_DB_PATH: state+'/data/db', WAREHOUSE_STORAGE_PATH: state+'/data/storage',
  WAREHOUSE_PROJECT_NAME: 'warehouse-01234567-89a', KONG_HTTP_PORT: '18590' };
test('switching guard accepts only its separately named fictional instance', () => {
  assert.equal(validateSwitchingConfig(state, env, manifest), 18590);
  for (const wrong of ['/private/test1-install2', '/private/core-backend-test-123', 'cross-instance-test-123']) {
    assert.throws(() => validateSwitchingConfig(wrong, env, manifest));
  }
});
test('switching guard rejects real provider, shared state, external binding and primary identity', () => {
  for (const patch of [{ MSG91_AUTH_KEY: 'real-provider' }, { BIND_ADDRESS: '0.0.0.0' },
    { SUPABASE_PUBLIC_URL: 'https://backend-core.example.test' }, { WAREHOUSE_DB_PATH: '/private/another/data/db' },
    { WAREHOUSE_STORAGE_PATH: '/private/another/data/storage' }, { WAREHOUSE_PROJECT_NAME: 'warehouse-another' },
    { AUTH_MODE: 'legacy' }, { KONG_HTTP_PORT: 'NaN' }, { KONG_HTTP_PORT: '80' }]) {
    assert.throws(() => validateSwitchingConfig(state, {...env, ...patch}, manifest));
  }
  for (const patch of [{ companyName: 'Fictional Core Warehouse' }, { canonicalOrigin: 'https://backend-core.example.test' }, { instanceId: 'unknown' }]) {
    assert.throws(() => validateSwitchingConfig(state, env, {...manifest, ...patch}));
  }
});
