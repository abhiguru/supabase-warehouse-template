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
    // operator-otp and central-exchange wrap the lookup for their unit tests and read through deps.env('NAME').
    const source = readFileSync(file, 'utf8').replace('env: name => Deno.env.get(name)', '');
    assert.doesNotMatch(source, /Deno\.env\.(?:toObject|get\((?!['"][A-Z0-9_]+['"]\)))/, `${file} reads the environment by a computed name`);
    for (const match of source.matchAll(/(?:Deno\.env\.get|deps\.env)\(\s*['"]([A-Z0-9_]+)['"]\s*\)/g)) names.add(match[1]);
    for (const match of source.matchAll(/(?:from\s+|import\s*\(\s*|import\s+)['"](\.{1,2}\/[^'"]+)['"]/g)) visit(resolve(dirname(file), match[1]));
  };
  visit(entry);
  return [...names].sort();
}

const container = {
  JWT_SECRET: 'unit-test-signing-secret-0123456789abcdef', SUPABASE_URL: 'http://kong:8000', SUPABASE_REST_URL: 'http://rest:3000', SUPABASE_STORAGE_URL: 'http://storage:5000', SUPABASE_ANON_KEY: 'unit-anon',
  SUPABASE_SERVICE_ROLE_KEY: 'unit-service', SUPABASE_PUBLIC_URL: 'https://api.example.test', PDF_RENDERER_URL: 'http://pdf-renderer:3000',
  APP_ENV: 'production', AUTH_MODE: 'operator', VERIFY_JWT: 'true', INSTANCE_MANIFEST_PATH: '/etc/warehouse/instance.json',
  CENTRAL_ISSUER: 'https://login.example.test', CENTRAL_JWKS_URL: 'https://login.example.test/jwks.json',
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
  // Sign-in endpoints are reachable with the anon key only, and the sensor
  // bridge's endpoint with its own ingest key: they are in the router's public set.
  const publicSet = /const publicFunctions = new Set\(\[([^\]]+)\]\)/.exec(router)[1];
  assert.deepEqual([...publicSet.matchAll(/'([a-z-]+)'/g)].map(match => match[1]),
    ['hello', 'get-public-config', 'operator-otp', 'central-exchange', 'ingest-sensor-readings']);
  assert.match(router, /const allowed = new Set\(\[\.\.\.publicFunctions, /);
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
  for (const name of ['hello', 'get-public-config', 'operator-otp', 'central-exchange', 'ingest-sensor-readings']) {
    assert.ok(!workerEnv(name, container).some(([key]) => key === 'JWT_SECRET'), `${name} holds JWT_SECRET`);
  }
  // The sensor ingest worker gets the RPC address and the server key, nothing else.
  assert.deepEqual(Object.fromEntries(workerEnv('ingest-sensor-readings', container)), {
    SUPABASE_URL: 'http://kong:8000', SUPABASE_SERVICE_ROLE_KEY: 'unit-service', SUPABASE_REST_URL: 'http://rest:3000',
  });
  assert.deepEqual(Object.fromEntries(workerEnv('operator-otp', container)), {
    APP_ENV: 'production', AUTH_MODE: 'operator', SUPABASE_URL: 'http://kong:8000', SUPABASE_SERVICE_ROLE_KEY: 'unit-service', SUPABASE_REST_URL: 'http://rest:3000',
  });
  // The central settings reach the exchange and the public configuration, not the SMS sign-in or a signed-in function.
  assert.deepEqual(Object.fromEntries(workerEnv('central-exchange', container)), {
    APP_ENV: 'production', AUTH_MODE: 'operator', SUPABASE_URL: 'http://kong:8000', SUPABASE_SERVICE_ROLE_KEY: 'unit-service',
    SUPABASE_PUBLIC_URL: 'https://api.example.test', CENTRAL_ISSUER: 'https://login.example.test', CENTRAL_JWKS_URL: 'https://login.example.test/jwks.json',
    SUPABASE_REST_URL: 'http://rest:3000',
  });
  // The key file's text is passed by the router to the exchange only; its name also tells get-public-config that keys are configured.
  const withKeys = name => Object.fromEntries(workerEnv(name, { ...container, CENTRAL_JWKS_FILE: 'central-jwks.json', CENTRAL_JWKS_DIR: '/etc/warehouse/public' }, { CENTRAL_JWKS_JSON: '{"keys":[]}' }));
  assert.equal(withKeys('central-exchange').CENTRAL_JWKS_JSON, '{"keys":[]}');
  assert.equal(withKeys('central-exchange').CENTRAL_JWKS_FILE, 'central-jwks.json');
  assert.equal(withKeys('get-public-config').CENTRAL_JWKS_FILE, 'central-jwks.json');
  for (const name of Object.keys(workerEnvNames)) {
    if (name !== 'central-exchange') assert.ok(!('CENTRAL_JWKS_JSON' in withKeys(name)), `${name} received the key set`);
    assert.ok(!('CENTRAL_JWKS_DIR' in withKeys(name)), `${name} received the key directory`);
  }
  // The router reads the file only for the exchange, only by a plain file name, and survives a missing file.
  assert.match(router, /if \(name === 'central-exchange'\) \{\n      const file = Deno\.env\.get\('CENTRAL_JWKS_FILE'\);/);
  assert.match(router, /\/\^\[A-Za-z0-9\]\[A-Za-z0-9\._-\]\{0,99\}\$\/\.test\(file\)/);
  assert.match(router, /try \{\n          extra\.CENTRAL_JWKS_JSON = await Deno\.readTextFile\(`\$\{directory\}\/\$\{file\}`\);\n        \} catch \{/);
  assert.ok(workerEnv('get-public-config', container).some(([key]) => key === 'CENTRAL_ISSUER'));
  for (const name of ['operator-otp', 'get-config', 'generate-grn-pdf', 'ingest-sensor-readings']) {
    assert.ok(!workerEnv(name, container).some(([key]) => key.startsWith('CENTRAL_')), `${name} holds a central setting`);
  }
  for (const name of Object.keys(workerEnvNames)) {
    const pairs = workerEnv(name, container, { INSTANCE_MANIFEST_JSON: '{}' });
    for (const [key, value] of pairs) {
      assert.ok(workerEnvNames[name].includes(key), `${name} received ${key}`);
      assert.doesNotMatch(value, /unit-db-password/);
    }
    assert.ok(!pairs.some(([key]) => ['SUPABASE_DB_URL', 'PATH', 'HOME', 'HOSTNAME', 'VERIFY_JWT', 'INSTANCE_MANIFEST_PATH'].includes(key)), name);
  }
  // Functions that verify a user token need the secret (get-config, the PDFs).
  for (const name of ['get-config', 'generate-grn-pdf']) {
    assert.ok(workerEnv(name, container).some(([key]) => key === 'JWT_SECRET'), `${name} cannot verify tokens`);
  }
  // The manifest text reaches get-public-config only.
  assert.ok(workerEnv('get-public-config', container, { INSTANCE_MANIFEST_JSON: '{"a":1}' }).some(([key, value]) => key === 'INSTANCE_MANIFEST_JSON' && value === '{"a":1}'));
  assert.ok(!workerEnv('get-config', container, { INSTANCE_MANIFEST_JSON: '{"a":1}' }).some(([key]) => key === 'INSTANCE_MANIFEST_JSON'));
  // An unset variable is left out rather than passed as the text "undefined".
  assert.deepEqual(workerEnv('get-config', { JWT_SECRET: 'x' }), [['JWT_SECRET', 'x']]);
});

test('the functions container holds no database address', () => {
  const block = compose.slice(compose.indexOf('\n  functions:\n'), compose.indexOf('\n  db:\n'));
  assert.ok(block.includes('SUPABASE_SERVICE_ROLE_KEY'), 'functions block was read');
  // Central sign-in settings are optional: a state written before they existed must still render.
  assert.ok(block.includes('CENTRAL_ISSUER: ${CENTRAL_ISSUER:-}') && block.includes('CENTRAL_JWKS_URL: ${CENTRAL_JWKS_URL:-}'));
  assert.ok(block.includes('CENTRAL_JWKS_FILE: ${CENTRAL_JWKS_FILE:-}') && block.includes('CENTRAL_JWKS_DIR: /etc/warehouse/public'));
  assert.ok(block.includes('- ${WAREHOUSE_PUBLIC_PATH:?Run through scripts/compose.sh}:/etc/warehouse/public:ro'), 'the key file directory is mounted read-only');
  // The database container has no central setting: adding one would recreate it on upgrade.
  assert.doesNotMatch(compose.slice(compose.indexOf('\n  db:\n')), /CENTRAL_/);
  assert.doesNotMatch(block, /SUPABASE_DB_URL|POSTGRES_PASSWORD/);
  for (const dir of readdirSync(functions, { recursive: true })) {
    if (String(dir).endsWith('.ts')) assert.doesNotMatch(readFileSync(join(functions, String(dir)), 'utf8'), /SUPABASE_DB_URL/, String(dir));
  }
});

test('get-public-config runs with the anon key only, never the service-role key (migration 123: get_public_config)', () => {
  assert.ok(!workerEnvNames['get-public-config'].includes('SUPABASE_SERVICE_ROLE_KEY'));
  assert.ok(!workerEnv('get-public-config', container, { INSTANCE_MANIFEST_JSON: '{}' }).some(([key]) => key === 'SUPABASE_SERVICE_ROLE_KEY'));
  assert.ok(workerEnv('get-public-config', container).some(([key]) => key === 'SUPABASE_ANON_KEY'));
  const source = readFileSync(new URL('../functions/get-public-config/index.ts', import.meta.url), 'utf8');
  assert.match(source, /rpc\('get_public_config'/);
  assert.doesNotMatch(source, /SERVICE_ROLE/);
});
