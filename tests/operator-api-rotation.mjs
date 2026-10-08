// Signing-key rotation against the disposable fictional operator installation.
// CI-only: runs rotate-keys.sh for real and proves old keys and sessions are
// dead while the rotated instance stays healthy. Not part of `npm test`.
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { resolve } from 'node:path';
import { operatorFixture } from './operator-fixture.mjs';
import { root } from '../scripts/doctor-common.mjs';

const before = operatorFixture();
const quote = value => `'${String(value).replaceAll("'", "''")}'`;
const sqlWith = env => query => {
  const result = spawnSync('docker', ['exec', '-i', '-e', `PGPASSWORD=${env.POSTGRES_PASSWORD}`,
    `${env.WAREHOUSE_PROJECT_NAME}-db-1`, 'psql', '-X', '-qAt', '-U', 'supabase_admin', '-d', 'postgres',
    '-v', 'ON_ERROR_STOP=1'], { input: query + '\n', encoding: 'utf8', timeout: 30000 });
  assert.equal(result.status, 0, 'fixture SQL failed; sensitive SQL stderr is not serialized');
  return result.stdout.trim();
};
const sleep = ms => new Promise(done => setTimeout(done, ms));
async function api(base, anon, path, token, body, method = body === undefined ? 'GET' : 'POST') {
  const response = await fetch(base + path, { method, headers: {
    apikey: anon, Authorization: `Bearer ${token}`, 'Content-Type': 'application/json',
  }, body: body === undefined ? undefined : JSON.stringify(body), signal: AbortSignal.timeout(30000) });
  const raw = await response.text();
  let data; try { data = JSON.parse(raw); } catch { data = null; }
  return { ok: response.ok, status: response.status, data };
}
async function login(sql, phone) {
  const json = expression => JSON.parse(sql(`SELECT (${expression})::text;`));
  let challenge = json(`public.operator_prepare_otp(${quote(phone)})`);
  if (challenge.code === 'resend_cooldown') {
    const wait = Date.parse(challenge.retry_at) - Date.now() + 1000;
    assert.ok(Number.isFinite(wait) && wait > 0 && wait <= 65000, 'bounded natural cooldown');
    await sleep(wait);
    challenge = json(`public.operator_prepare_otp(${quote(phone)})`);
  }
  assert.equal(challenge.success, true, 'fictional challenge prepared');
  assert.equal(json(`public.operator_finish_otp(${quote(challenge.data.request_id)}::uuid,true,'mock-provider-only')`).success, true);
  const verified = json(`public.operator_verify_otp(${quote(phone)},${quote(challenge.data.otp_code)})`);
  assert.equal(verified.success, true, 'fictional login verified');
  return verified.data.session;
}

// A live session on the old keys proves the API path before rotation.
const sqlBefore = sqlWith(before.env);
const challengedAt = Date.now();
const session = await login(sqlBefore, '919888888871');
const live = await api(before.base, before.anon, '/rest/v1/customers?select=id', session.access_token);
assert.ok(live.ok, `pre-rotation admin read: HTTP ${live.status}`);
assert.notEqual(sqlBefore('SELECT count(*) FROM warehouse_security.refresh_sessions'), '0', 'session recorded');
assert.equal(sqlBefore(`SELECT (value = ${quote(before.env.JWT_SECRET)})::text FROM warehouse_security.auth_config WHERE key='jwt_secret'`), 'true');

const rotation = spawnSync('bash', [resolve(root, 'rotate-keys.sh'), '--yes'], { encoding: 'utf8', timeout: 900000 });
assert.equal(rotation.status, 0, `rotate-keys.sh failed:\n${rotation.stdout.slice(-1500)}\n${rotation.stderr.slice(-1500)}`);
assert.match(rotation.stdout, /every device must sign in again/i);

const after = operatorFixture();
const sql = sqlWith(after.env);
assert.notEqual(after.env.JWT_SECRET, before.env.JWT_SECRET, 'new secret');
assert.notEqual(after.anon, before.anon, 'new anon key');
assert.notEqual(after.env.SERVICE_ROLE_KEY, before.env.SERVICE_ROLE_KEY, 'new service key');
for (const key of Object.keys(before.env)) {
  if (!['JWT_SECRET', 'ANON_KEY', 'SERVICE_ROLE_KEY'].includes(key)) assert.equal(after.env[key], before.env[key], `${key} preserved`);
}
assert.equal(after.base, before.base);

// Database side: secret stored, sessions and pending challenges gone, tenant re-seeded.
assert.equal(sql(`SELECT (value = ${quote(after.env.JWT_SECRET)})::text FROM warehouse_security.auth_config WHERE key='jwt_secret'`), 'true', 'auth_config holds the new secret');
assert.equal(sql(`SELECT (current_setting('app.settings.jwt_secret') = ${quote(after.env.JWT_SECRET)})::text`), 'true', 'database setting holds the new secret');
assert.equal(sql('SELECT count(*) FROM warehouse_security.refresh_sessions'), '0', 'every session revoked');
assert.equal(sql('SELECT count(*) FROM public.otp_verifications WHERE NOT verified'), '0', 'pending challenges voided');
assert.equal(sql("SELECT count(*) FROM _realtime.tenants WHERE external_id='realtime-dev'"), '1', 'realtime tenant re-seeded');

// Gateway and API side: old key and old token are rejected, replay is denied.
const staleKey = await api(after.base, before.anon, '/rest/v1/customers?select=id', before.anon);
assert.equal(staleKey.status, 401, `old apikey must be rejected by the gateway: HTTP ${staleKey.status}`);
const staleToken = await api(after.base, after.anon, '/rest/v1/customers?select=id', session.access_token);
assert.equal(staleToken.status, 401, `old access token must fail signature verification: HTTP ${staleToken.status}`);
// The anon role may execute refresh_jwt_token, so HTTP 200 here proves the new
// apikey passes Kong's key-auth and the new anon JWT verifies under the new
// secret; the payload proves the old refresh token is refused.
const replay = await api(after.base, after.anon, '/rest/v1/rpc/refresh_jwt_token', after.anon, { p_refresh_token: session.refresh_token });
assert.equal(replay.status, 200, `new apikey and anon token must pass the gateway and PostgREST: HTTP ${replay.status} ${JSON.stringify(replay.data).slice(0, 200)}`);
assert.equal(replay.data?.success, false, 'old refresh token cannot mint a session');
assert.equal(sql('SELECT count(*) FROM warehouse_security.refresh_sessions'), '0', 'replay created no session');

// Public discovery advertises the new anon key and the stack is healthy.
const identity = await fetch(`${after.base}/functions/v1/get-public-config`, { signal: AbortSignal.timeout(30000) });
assert.equal(identity.status, 200, 'public configuration after rotation');
const publicConfig = await identity.json();
assert.equal(publicConfig.data?.anonKey, after.anon, 'public config shows the new anon key');
assert.equal(publicConfig.data?.companyName, 'Fictional Core Warehouse');
const health = spawnSync('bash', [resolve(root, 'health-check.sh')], { encoding: 'utf8', timeout: 300000 });
assert.equal(health.status, 0, `health check after rotation:\n${health.stdout.slice(-1500)}`);
// PostgREST answers 401 (not 403) when the anonymous role lacks a table
// privilege, so only the denial itself is asserted here; gateway passage was
// proven by the RPC call above.
const anonymous = await api(after.base, after.anon, '/rest/v1/customers?select=id', after.anon);
assert.ok(!anonymous.ok, `anonymous table read must be denied: HTTP ${anonymous.status}`);

// Leave the admin phone outside its resend cooldown for the suites that follow.
const remaining = 61000 - (Date.now() - challengedAt);
if (remaining > 0) await sleep(remaining);
console.log('PASS signing-key rotation: new secret in auth_config and database setting, sessions and pending OTPs revoked, Realtime tenant re-seeded, old apikey 401, old token 401, replay denied, public config shows the new anon key, health passes');
