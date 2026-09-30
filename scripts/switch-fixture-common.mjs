// Separate optional guard for cross-origin emulator acceptance. The original
// core fixture validator and every installed-warehouse path remain unchanged.
import assert from 'node:assert/strict';
import { lstatSync, realpathSync, readFileSync } from 'node:fs';
import { basename, isAbsolute, resolve } from 'node:path';
import { spawnSync } from 'node:child_process';
import { readEnv, root } from './doctor-common.mjs';

export const switchingOrigin = 'https://backend-switch.example.test';
export const switchingCompany = 'Fictional Switching Warehouse';
export function validateSwitchingConfig(state, env, manifest) {
  assert.ok(state && isAbsolute(state));
  assert.match(basename(state), /^cross-instance-test-[0-9]+$/);
  assert.equal(env.AUTH_MODE, 'operator');
  assert.equal(env.BIND_ADDRESS, '127.0.0.1');
  assert.equal(env.SUPABASE_PUBLIC_URL, switchingOrigin);
  assert.ok(env.MSG91_AUTH_KEY === 'isolated-no-delivery-key', 'Dummy fixture provider required');
  assert.equal(env.WAREHOUSE_DB_PATH, resolve(state, 'data/db'));
  assert.equal(env.WAREHOUSE_STORAGE_PATH, resolve(state, 'data/storage'));
  assert.match(manifest.instanceId, /^[a-f0-9]{8}(-[a-f0-9]{4}){3}-[a-f0-9]{12}$/);
  assert.equal(manifest.companyName, switchingCompany);
  assert.equal(manifest.canonicalOrigin, switchingOrigin);
  assert.equal(env.WAREHOUSE_PROJECT_NAME, `warehouse-${manifest.instanceId.slice(0, 12)}`);
  const port = Number(env.KONG_HTTP_PORT);
  assert.ok(Number.isInteger(port) && port >= 1024 && port <= 65535);
  return port;
}
export function switchingFixture() {
  const state = process.env.WAREHOUSE_STATE_DIR;
  assert.ok(state && isAbsolute(state));
  const directory = lstatSync(state);
  assert.ok(directory.isDirectory() && directory.uid === process.getuid() && (directory.mode & 0o777) === 0o700);
  assert.equal(realpathSync(state), resolve(state));
  const paths = ['config/compose.env', 'public/instance.json'].map(p => resolve(state, p));
  for (const [index, path] of paths.entries()) {
    const file = lstatSync(path);
    assert.ok(file.isFile() && !file.isSymbolicLink() && file.uid === process.getuid());
    assert.equal(realpathSync(path), path);
    if (index === 0) assert.equal(file.mode & 0o077, 0);
  }
  const env = readEnv(paths[0]);
  const manifest = JSON.parse(readFileSync(paths[1], 'utf8'));
  const port = validateSwitchingConfig(state, env, manifest);
  const owned = spawnSync('bash', [resolve(root, 'scripts/compose.sh'), 'ps', '-q', 'db'], { encoding: 'utf8', timeout: 30000 });
  assert.ok(owned.status === 0 && /^[a-f0-9]+\s*$/.test(owned.stdout), 'Running database must belong to this checkout/state');
  return { env, manifest, base: `http://127.0.0.1:${port}`, anon: env.ANON_KEY };
}
