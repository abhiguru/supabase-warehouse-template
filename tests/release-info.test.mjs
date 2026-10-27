// What the backend tells the app about itself: get-public-config and get-config answer backendRelease and schemaHead from the
// release.json setup.sh writes, and the minimum app build from app-compat.json, never from instance.json (the owner decision:
// a backend release supports the newest app release; older builds are told to update). Runs the two functions' own code with a
// stand-in Deno and PostgREST, and scripts/release-info.mjs against a throwaway git checkout and state.
import { after, before, test } from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { chmodSync, mkdirSync, mkdtempSync, readFileSync, rmSync, statSync, symlinkSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { SignJWT } from 'jose';
import { parseMinimumClientVersion, parseRelease } from '../functions/_shared/release-info.ts';
import { appCompat, releaseRecord, writeReleaseFiles } from '../scripts/release-info.mjs';

const read = path => readFileSync(new URL(`../${path}`, import.meta.url), 'utf8');
const secret = 'release-info-unit-test-signing-secret-0123456789';
const SUB = '11111111-2222-3333-4444-555555555555';
// The manifest still carries a minimum for old readers; the functions must not use it.
const MANIFEST = { schemaVersion: 1, instanceId: '99999999-aaaa-bbbb-cccc-dddddddddddd', displayName: 'Acme', companyName: 'Acme Cold', canonicalOrigin: 'https://api.example.test',
  capabilities: { sensors: false, printing: false }, supportedApiVersions: ['1'], minimumClientVersion: '0.1.0' };
const RELEASE = { backendRelease: 'v0.7.0', backendCommit: 'a'.repeat(40), schemaHead: '00000000000127_example.sql', writtenAt: '2026-10-27T00:00:00.000Z' };
const BASE_ENV = {
  JWT_SECRET: secret, SUPABASE_URL: 'http://gateway:8000', SUPABASE_REST_URL: 'http://rest:3000', SUPABASE_SERVICE_ROLE_KEY: 'unit-service', SUPABASE_ANON_KEY: 'unit-anon',
  SUPABASE_PUBLIC_URL: 'https://api.example.test', APP_ENV: 'production', AUTH_MODE: 'operator', INSTANCE_MANIFEST_JSON: JSON.stringify(MANIFEST),
  APP_COMPAT_JSON: JSON.stringify({ minimumClientVersion: '1.4.0' }), RELEASE_JSON: JSON.stringify(RELEASE),
};
const handlers = {};
let env = {};
const realDeno = globalThis.Deno;
const realFetch = globalThis.fetch;
const json = (body, status = 200) => new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json' } });
const quiet = console.error;

before(async () => {
  let current;
  globalThis.Deno = { serve: handler => { handlers[current] = handler; }, env: { get: name => env[name] } };
  globalThis.fetch = async url => {
    const path = new URL(url).pathname;
    if (path.endsWith('/user_profiles')) return json([{ id: 'p1', auth_user_id: SUB, name: 'A', display_name: 'A', mobile: '9000000000', role: 'admin', active: true }]);
    if (path.endsWith('/api_configurations')) return json({ app_version: '0.2.0', build_date: '2026-10-01', maintenance_mode: false });
    if (path.endsWith('/feature_flags') || path.endsWith('/system_settings')) return json([]);
    if (path.endsWith('/sms_config')) return json({ production_mode: true, provider: 'msg91' });
    if (path.endsWith('/rpc/get_public_config')) return json({ app_version: '0.2.0', maintenance_mode: false, feature_flags: {} });
    return json({ message: `unexpected ${path}` }, 404);
  };
  current = 'get-config';
  await import('../functions/get-config/index.ts');
  current = 'get-public-config';
  await import('../functions/get-public-config/index.ts');
});
after(() => { globalThis.Deno = realDeno; globalThis.fetch = realFetch; console.error = quiet; });

async function publicConfig(extra, drop = []) {
  env = { ...BASE_ENV, ...extra };
  for (const name of drop) delete env[name];
  console.error = () => {};
  try {
    const response = await handlers['get-public-config'](new Request('http://example.test/get-public-config'));
    return { status: response.status, body: await response.json() };
  } finally { console.error = quiet; }
}
async function fullConfig(extra, drop = []) {
  env = { ...BASE_ENV, ...extra };
  for (const name of drop) delete env[name];
  const token = await new SignJWT({ role: 'authenticated', sub: SUB }).setProtectedHeader({ alg: 'HS256' }).setIssuer('supabase').setExpirationTime('5m').sign(new TextEncoder().encode(secret));
  const response = await handlers['get-config'](new Request('http://example.test/get-config', { headers: { Authorization: `Bearer ${token}` } }));
  return { status: response.status, body: await response.json() };
}

test('get-public-config: backendRelease and schemaHead come from release.json; the minimum from app-compat.json, not instance.json', async () => {
  const { status, body } = await publicConfig({});
  assert.equal(status, 200);
  assert.equal(body.data.backendRelease, 'v0.7.0');
  assert.equal(body.data.schemaHead, '00000000000127_example.sql');
  assert.equal(body.data.minimumClientVersion, '1.4.0', 'the manifest says 0.1.0 and is ignored');
  assert.notEqual(body.data.minimumClientVersion, MANIFEST.minimumClientVersion);
});

test('get-public-config: without release.json the release is null and the answer is still 200; without app-compat.json it is a 503', async () => {
  for (const missing of [undefined, '', 'not json', '{}', JSON.stringify({ backendRelease: 7, schemaHead: 'bad name/with slash' })]) {
    const { status, body } = await publicConfig({ RELEASE_JSON: missing }, missing === undefined ? ['RELEASE_JSON'] : []);
    assert.equal(status, 200, String(missing));
    assert.equal(body.data.backendRelease, null, String(missing));
    assert.equal(body.data.schemaHead, null, String(missing));
  }
  for (const bad of [undefined, '', 'not json', '{}', JSON.stringify({ minimumClientVersion: '1.4' }), JSON.stringify({ minimumClientVersion: 14 })]) {
    const { status, body } = await publicConfig({ APP_COMPAT_JSON: bad }, bad === undefined ? ['APP_COMPAT_JSON'] : []);
    assert.equal(status, 503, String(bad));
    assert.equal(body.success, false);
    // The cause is named (the file, and to run setup.sh), not the unrelated "finish migrations and seed first".
    assert.match(body.error, /app-compat\.json is missing or invalid.*run setup\.sh again/, String(bad));
    assert.doesNotMatch(body.error, /migrations/, String(bad));
  }
});

test('get-public-config: a manifest without minimumClientVersion is valid (the field is kept only for old readers)', async () => {
  const { minimumClientVersion: _kept, ...without } = MANIFEST;
  const { status, body } = await publicConfig({ INSTANCE_MANIFEST_JSON: JSON.stringify(without) });
  assert.equal(status, 200);
  assert.equal(body.data.minimumClientVersion, '1.4.0');
});

test('get-config: reports backendRelease', async () => {
  const { status, body } = await fullConfig({});
  assert.equal(status, 200);
  assert.equal(body.data.environment.backendRelease, 'v0.7.0');
  assert.equal((await fullConfig({}, ['RELEASE_JSON'])).body.data.environment.backendRelease, null);
});

// urls.realtime stays until a release raises the minimum app version past the builds that still require it
// (app v0.5.0 and builds before app PR #72 fail their configuration check without it).
test('get-config: urls.realtime is still published, as a websocket URL on the backend origin', async () => {
  const { status, body } = await fullConfig({});
  assert.equal(status, 200);
  assert.equal(body.data.urls.realtime, 'wss://api.example.test/realtime/v1');
});

test('the parsers', () => {
  assert.deepEqual(parseRelease(JSON.stringify(RELEASE)), { backendRelease: 'v0.7.0', schemaHead: RELEASE.schemaHead });
  assert.deepEqual(parseRelease(undefined), { backendRelease: null, schemaHead: null });
  assert.equal(parseMinimumClientVersion('{"minimumClientVersion":"2.0.1"}'), '2.0.1');
  assert.throws(() => parseMinimumClientVersion('{"minimumClientVersion":"2.0"}'));
});

test('the router hands the two files to get-public-config and the release to get-config; the container names the directory', () => {
  const router = read('functions/main/index.ts');
  assert.match(router, /name === 'get-public-config' \|\| name === 'get-config'/);
  assert.match(router, /\['RELEASE_JSON', 'release\.json'\], \['APP_COMPAT_JSON', 'app-compat\.json'\]/);
  assert.match(read('docker/docker-compose.yml'), /\n      PUBLIC_DIR: \/etc\/warehouse\/public\n/);
});

// ---- scripts/release-info.mjs ------------------------------------------------------------------------------------------
function checkout() {
  const root = mkdtempSync(join(tmpdir(), 'release-info-root-'));
  const git = (...args) => execFileSync('git', ['-C', root, '-c', 'user.name=t', '-c', 'user.email=t@example.test', ...args], { stdio: 'pipe' });
  git('init', '-q');
  writeFileSync(join(root, 'app-compat.json'), JSON.stringify({ minimumClientVersion: '0.3.0', note: 'x' }));
  git('add', 'app-compat.json');
  git('commit', '-q', '-m', 'one');
  git('tag', 'v9.9.9');
  return { root, commit: execFileSync('git', ['-C', root, 'rev-parse', 'HEAD'], { encoding: 'utf8' }).trim() };
}
function state() {
  const dir = mkdtempSync(join(tmpdir(), 'release-info-state-'));
  chmodSync(dir, 0o700);
  mkdirSync(join(dir, 'public'), { mode: 0o700 });
  return dir;
}

test('release-info.mjs writes release.json with the checkout\'s tag and commit and copies app-compat.json', () => {
  const { root, commit } = checkout();
  const dir = state();
  try {
    const now = new Date('2026-10-27T01:02:03Z');
    // A private umask (an operator's shell) must not make the files unreadable for the functions container.
    const umask = process.umask(0o077);
    try { writeReleaseFiles({ state: dir, root, schemaHead: '00000000000126_x.sql', now }); } finally { process.umask(umask); }
    const release = JSON.parse(readFileSync(join(dir, 'public/release.json'), 'utf8'));
    assert.deepEqual(release, { backendRelease: 'v9.9.9', backendCommit: commit, schemaHead: '00000000000126_x.sql', writtenAt: '2026-10-27T01:02:03.000Z' });
    assert.equal(JSON.parse(readFileSync(join(dir, 'public/app-compat.json'), 'utf8')).minimumClientVersion, '0.3.0');
    assert.equal(statSync(join(dir, 'public/release.json')).mode & 0o777, 0o644, 'the functions container reads it');
    // Written again on every run: a later schema head replaces the file.
    writeReleaseFiles({ state: dir, root, schemaHead: '00000000000127_y.sql', now });
    assert.equal(JSON.parse(readFileSync(join(dir, 'public/release.json'), 'utf8')).schemaHead, '00000000000127_y.sql');
  } finally { rmSync(root, { recursive: true, force: true }); rmSync(dir, { recursive: true, force: true }); }
});

test('release-info.mjs: no git history is "unknown", a malformed app-compat.json or schema head stops it, a symlink is not followed', () => {
  const root = mkdtempSync(join(tmpdir(), 'release-info-nogit-'));
  const dir = state();
  try {
    writeFileSync(join(root, 'app-compat.json'), '{"minimumClientVersion":"0.1.0"}');
    assert.deepEqual({ ...releaseRecord({ root, schemaHead: 'a.sql' }), writtenAt: 0 }, { backendRelease: 'unknown', backendCommit: 'unknown', schemaHead: 'a.sql', writtenAt: 0 });
    assert.throws(() => releaseRecord({ root, schemaHead: '' }), /migration name/);
    assert.throws(() => releaseRecord({ root, schemaHead: '../x' }), /migration name/);
    writeFileSync(join(root, 'app-compat.json'), '{"minimumClientVersion":"latest"}');
    assert.throws(() => appCompat(root), /MAJOR\.MINOR\.PATCH/);
    assert.throws(() => writeReleaseFiles({ state: dir, root, schemaHead: 'a.sql' }), /MAJOR\.MINOR\.PATCH/);
    assert.throws(() => statSync(join(dir, 'public/release.json')), 'nothing was written');
    writeFileSync(join(root, 'app-compat.json'), '{"minimumClientVersion":"0.1.0"}');
    symlinkSync('/etc/hostname', join(dir, 'public/release.json'));
    assert.throws(() => writeReleaseFiles({ state: dir, root, schemaHead: 'a.sql' }), /regular file/);
  } finally { rmSync(root, { recursive: true, force: true }); rmSync(dir, { recursive: true, force: true }); }
});

test('the repository\'s own app-compat.json is valid, and setup.sh and restore.sh write the files after the migrations through one helper', () => {
  appCompat();
  for (const [file, migrate] of [['setup.sh', 'scripts/migrate.sh" --operator'], ['scripts/restore.sh', 'scripts/migrate.sh" --operator']]) {
    const text = read(file);
    const at = text.indexOf(migrate);
    const write = text.indexOf('scripts/release-info.sh"');
    assert.ok(at > 0 && write > at, `${file}: release-info.sh runs after migrate.sh`);
    assert.doesNotMatch(text, /release-info\.mjs/, `${file}: the helper is the only caller of release-info.mjs`);
  }
  const helper = read('scripts/release-info.sh');
  assert.match(helper, /SELECT name FROM warehouse_migrations\.applied ORDER BY name COLLATE "C" DESC LIMIT 1/);
  assert.match(helper, /release-info\.mjs" write "\$schema_head"/);
});
