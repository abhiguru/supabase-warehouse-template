import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { build } from '/usr/src/app/dist/server/app.js';
const root = '/usr/src/app';
const pkg = JSON.parse(readFileSync(root + '/package.json'));
const lock = JSON.parse(readFileSync(root + '/package-lock.json'));
assert.equal(pkg.name, '@supabase/postgres-meta');
assert.equal(pkg.devDependencies['cpy-cli'], undefined);
assert.equal(pkg.devDependencies.nodemon, undefined);
assert.equal(lock.packages['node_modules/braces'], undefined);
const app = build({ logger: false });
try {
  const response = await app.inject({ method: 'GET', url: '/' });
  assert.equal(response.statusCode, 200);
  assert.equal(response.json().name, pkg.name);
  const health = await app.inject({ method: 'GET', url: '/health' });
  assert.equal(health.statusCode, 200);
  assert.ok(Number.isFinite(Date.parse(health.json().date)));
  const absent = await app.inject({ method: 'GET', url: '/fixture-nonexistent-route' });
  assert.equal(absent.statusCode, 404);
  console.log(JSON.stringify({ status: 'PASS', node: process.version,
    rootStatus: response.statusCode, healthStatus: health.statusCode,
    absentStatus: absent.statusCode, lockSha256: createHash('sha256').update(readFileSync(root + '/package-lock.json')).digest('hex'),
    workerSha256: createHash('sha256').update(readFileSync(root + '/dist/server/format-worker.js')).digest('hex') }));
} finally { await app.close(); }
