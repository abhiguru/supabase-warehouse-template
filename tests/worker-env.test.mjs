import { test } from 'node:test';
import assert from 'node:assert/strict';
import { existsSync, readFileSync, readdirSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { workerEnv, workerEnvNames } from '../functions/main/worker-env.ts';

const functions = new URL('../functions/', import.meta.url).pathname;
const router = readFileSync(join(functions, 'main/index.ts'), 'utf8');
const compose = readFileSync(new URL('../docker/docker-compose.yml', import.meta.url), 'utf8');

// Every environment name a function can read: its own files and, transitively,
// each relative module they import (static or dynamic).
function namesRead(entry) {
  const seen = new Set();
  const names = new Set();
  const visit = file => {
    if (seen.has(file)) return;
    seen.add(file);
    // operator-otp wraps the lookup for its unit tests and reads through deps.env('NAME').
    const source = readFileSync(file, 'utf8').replace('env: name => Deno.env.get(name)', '');
    assert.doesNotMatch(source, /Deno\.env\.(?:toObject|get\((?!['"][A-Z0-9_]+['"]\)))/, `${file} reads the environment by a computed name`);
    for (const match of source.matchAll(/(?:Deno\.env\.get|deps\.env)\(\s*['"]([A-Z0-9_]+)['"]\s*\)/g)) names.add(match[1]);
    for (const match of source.matchAll(/(?:from\s+|import\s*\(\s*|import\s+)['"](\.{1,2}\/[^'"]+)['"]/g)) visit(resolve(dirname(file), match[1]));
  };
  visit(entry);
  return [...names].sort();
}

const container = {
  JWT_SECRET: 'unit-test-signing-secret-0123456789abcdef', SUPABASE_URL: 'http://kong:8000', SUPABASE_ANON_KEY: 'unit-anon',
  SUPABASE_SERVICE_ROLE_KEY: 'unit-service', SUPABASE_PUBLIC_URL: 'https://api.example.test', GOTENBERG_URL: 'http://gotenberg:3000',
  APP_ENV: 'production', AUTH_MODE: 'operator', VERIFY_JWT: 'true', INSTANCE_MANIFEST_PATH: '/etc/warehouse/instance.json',
  SUPABASE_DB_URL: 'postgresql://postgres:unit-db-password@db:5432/postgres', PATH: '/usr/bin', HOME: '/root', HOSTNAME: 'abc',
};

test('each worker list is exactly what the function and its shared modules read', () => {
  for (const [name, listed] of Object.entries(workerEnvNames)) {
    assert.deepEqual([...listed].sort(), namesRead(join(functions, name, 'index.ts')), name);
  }
});

test('every function the router can start has a list, and the router passes only that list', () => {
  const allowed = [...router.matchAll(/'([a-z][a-z-]+)'/g)].map(match => match[1]).filter(name => existsSync(join(functions, name, 'index.ts')));
  assert.ok(allowed.includes('hello') && allowed.includes('generate-invoice-pdf'), 'router names were read');
  for (const name of allowed) {
    if (/-preprinted$/.test(name)) continue; // refused with 503 and absent from `allowed`
    assert.ok(workerEnvNames[name], `${name} has no environment list`);
  }
  // The container environment is read once, as the source the list selects from.
  assert.equal(router.match(/Deno\.env\.toObject/g).length, 1, 'router must not copy the whole environment');
  assert.match(router, /envVars: workerEnv\(name, Deno\.env\.toObject\(\), extra\),/);
  assert.throws(() => workerEnv('not-a-function', container), /No environment list/);
});

test('public workers get no signing secret, and no worker gets a database address or an unlisted value', () => {
  assert.deepEqual(workerEnv('hello', container), []);
  for (const name of ['hello', 'get-public-config', 'operator-otp']) {
    assert.ok(!workerEnv(name, container).some(([key]) => key === 'JWT_SECRET'), `${name} holds JWT_SECRET`);
  }
  assert.deepEqual(Object.fromEntries(workerEnv('operator-otp', container)), {
    APP_ENV: 'production', AUTH_MODE: 'operator', SUPABASE_URL: 'http://kong:8000', SUPABASE_SERVICE_ROLE_KEY: 'unit-service',
  });
  for (const name of Object.keys(workerEnvNames)) {
    const pairs = workerEnv(name, container, { INSTANCE_MANIFEST_JSON: '{}' });
    for (const [key, value] of pairs) {
      assert.ok(workerEnvNames[name].includes(key), `${name} received ${key}`);
      assert.doesNotMatch(value, /unit-db-password/);
    }
    assert.ok(!pairs.some(([key]) => ['SUPABASE_DB_URL', 'PATH', 'HOME', 'HOSTNAME', 'VERIFY_JWT', 'INSTANCE_MANIFEST_PATH'].includes(key)), name);
  }
  // Functions that verify a user token need the secret (get-config, the PDFs).
  for (const name of ['get-config', 'generate-grn-pdf', 'generate-sample-pdf']) {
    assert.ok(workerEnv(name, container).some(([key]) => key === 'JWT_SECRET'), `${name} cannot verify tokens`);
  }
  // The manifest text reaches get-public-config only.
  assert.ok(workerEnv('get-public-config', container, { INSTANCE_MANIFEST_JSON: '{"a":1}' }).some(([key, value]) => key === 'INSTANCE_MANIFEST_JSON' && value === '{"a":1}'));
  assert.ok(!workerEnv('get-config', container, { INSTANCE_MANIFEST_JSON: '{"a":1}' }).some(([key]) => key === 'INSTANCE_MANIFEST_JSON'));
  // An unset variable is left out rather than passed as the text "undefined".
  assert.deepEqual(workerEnv('generate-sample-pdf', { JWT_SECRET: 'x' }), [['JWT_SECRET', 'x']]);
});

test('the functions container holds no database address', () => {
  const block = compose.slice(compose.indexOf('\n  functions:\n'), compose.indexOf('\n  db:\n'));
  assert.ok(block.includes('SUPABASE_SERVICE_ROLE_KEY'), 'functions block was read');
  assert.doesNotMatch(block, /SUPABASE_DB_URL|POSTGRES_PASSWORD/);
  for (const dir of readdirSync(functions, { recursive: true })) {
    if (String(dir).endsWith('.ts')) assert.doesNotMatch(readFileSync(join(functions, String(dir)), 'utf8'), /SUPABASE_DB_URL/, String(dir));
  }
});
