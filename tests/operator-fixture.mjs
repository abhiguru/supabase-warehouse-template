// Refuse every fixture mutation unless private state, identity and Compose
// ownership prove this is the explicitly selected fictional installation.
import assert from 'node:assert/strict';
import { lstatSync, realpathSync, readFileSync } from 'node:fs';
import { basename, isAbsolute, resolve } from 'node:path';
import { spawnSync } from 'node:child_process';
import { readEnv, root } from '../scripts/doctor-common.mjs';

export function operatorFixture() {
  const state = process.env.WAREHOUSE_STATE_DIR;
  assert.ok(state && isAbsolute(state), 'An absolute fictional state path is required');
  assert.match(basename(state), /^core-backend-test-[0-9]+$/);
  assert.equal(realpathSync(state), resolve(state), 'Fixture state must not use symlinks');
  const st = lstatSync(state);
  assert.ok(st.isDirectory() && st.uid === process.getuid() && (st.mode & 0o777) === 0o700,
    'Fixture state must be private and owned');
  const config = resolve(state, 'config/compose.env');
  const cs = lstatSync(config);
  assert.ok(cs.isFile() && !cs.isSymbolicLink() && cs.uid === process.getuid() && (cs.mode & 0o077) === 0,
    'Fixture configuration must be a private regular file');
  const env = readEnv(config);
  assert.equal(env.AUTH_MODE, 'operator');
  assert.equal(env.BIND_ADDRESS, '127.0.0.1');
  assert.equal(env.SUPABASE_PUBLIC_URL, 'https://backend-core.example.test');
  assert.equal(env.MSG91_AUTH_KEY, 'isolated-no-delivery-key');
  assert.equal(env.WAREHOUSE_DB_PATH, resolve(state, 'data/db'));
  assert.equal(env.WAREHOUSE_STORAGE_PATH, resolve(state, 'data/storage'));
  const manifest = JSON.parse(readFileSync(resolve(state, 'public/instance.json'), 'utf8'));
  assert.equal(manifest.companyName, 'Fictional Core Warehouse');
  assert.equal(manifest.canonicalOrigin, env.SUPABASE_PUBLIC_URL);
  assert.equal(env.WAREHOUSE_PROJECT_NAME, `warehouse-${manifest.instanceId.slice(0, 12)}`);
  const port = Number(env.KONG_HTTP_PORT);
  assert.ok(Number.isInteger(port) && port >= 1024 && port <= 65535, 'Invalid fixture port');
  const owned = spawnSync('bash', [resolve(root, 'scripts/compose.sh'), 'ps', '-q', 'db'],
    { encoding: 'utf8', timeout: 30000 });
  assert.ok(owned.status === 0 && /^[a-f0-9]+\s*$/.test(owned.stdout), 'Running database must belong to this checkout and state');
  return { env, base: `http://127.0.0.1:${port}`, anon: env.ANON_KEY };
}
