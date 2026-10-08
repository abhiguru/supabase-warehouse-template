// Final backend-only checks against the disposable fictional operator stack.
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { readFileSync, writeFileSync, lstatSync, realpathSync } from 'node:fs';
import { resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { createHash } from 'node:crypto';
import { operatorFixture } from './operator-fixture.mjs';

let selectedFixture = operatorFixture;
let evidenceRoot;
if (process.argv[2]) {
  const path = resolve(process.argv[2]), stat = lstatSync(path);
  assert.ok(stat.isFile() && !stat.isSymbolicLink() && stat.uid === process.getuid() && (stat.mode & 0o077) === 0);
  const c = JSON.parse(readFileSync(path));
  assert.equal(c.mode, 'ordinary-final-backend-fixture');
  assert.equal(realpathSync(c.backendCheckout), resolve(c.backendCheckout));
  assert.equal(process.env.WAREHOUSE_STATE_DIR, c.backendState);
  const guard = resolve(c.backendCheckout, 'tests/operator-fixture.mjs');
  assert.equal(createHash('sha256').update(readFileSync(guard)).digest('hex'), c.fixtureGuardSHA256);
  assert.equal(JSON.parse(readFileSync(resolve(c.backendState, 'public/instance.json'))).instanceId, c.instanceId);
  selectedFixture = (await import(pathToFileURL(guard))).operatorFixture;
  evidenceRoot = resolve(c.evidenceRoot);
  assert.equal(realpathSync(evidenceRoot), evidenceRoot);
  const es = lstatSync(evidenceRoot);
  assert.ok(es.isDirectory() && !es.isSymbolicLink() && es.uid === process.getuid() && (es.mode & 0o077) === 0);
}
const { env, base, anon } = selectedFixture();
const quote = value => `'${String(value).replaceAll("'", "''")}'`;
function sql(expression) {
  const p = spawnSync('docker', ['exec', '-i', '-e', `PGPASSWORD=${env.POSTGRES_PASSWORD}`,
    `${env.WAREHOUSE_PROJECT_NAME}-db-1`, 'psql', '-X', '-qAt', '-U', 'supabase_admin', '-d', 'postgres',
    '-v', 'ON_ERROR_STOP=1'], { input: `SELECT (${expression})::text;\n`, encoding: 'utf8', timeout: 30000 });
  assert.equal(p.status, 0, 'fixture SQL failed; sensitive SQL stderr is not serialized');
  return JSON.parse(p.stdout.trim());
}
async function sessionFor(phone) {
  let challenge = sql(`public.operator_prepare_otp(${quote(phone)})`);
  if (challenge.code === 'resend_cooldown') {
    const wait = Date.parse(challenge.retry_at) - Date.now() + 1000;
    assert.ok(Number.isFinite(wait) && wait > 0 && wait <= 65000, 'bounded natural cooldown');
    await new Promise(resolve => setTimeout(resolve, wait));
    challenge = sql(`public.operator_prepare_otp(${quote(phone)})`);
  }
  assert.equal(challenge.success, true, 'ordinary fictional challenge prepared');
  assert.equal(sql(`public.operator_finish_otp(${quote(challenge.data.request_id)}::uuid,true,'mock-provider-only')`).success, true);
  const verified = sql(`public.operator_verify_otp(${quote(phone)},${quote(challenge.data.otp_code)})`);
  assert.equal(verified.success, true, 'ordinary fictional login verified');
  assert.ok(verified.data.session.access_token && verified.data.session.refresh_token);
  return verified.data.session;
}

async function api(path, token, body, method = body === undefined ? 'GET' : 'POST') {
  const response = await fetch(base + path, { method, headers: {
    apikey: anon, Authorization: `Bearer ${token}`, 'Content-Type': 'application/json',
  }, body: body === undefined ? undefined : JSON.stringify(body), signal: AbortSignal.timeout(30000) });
  const raw = await response.text();
  let data; try { data = JSON.parse(raw); } catch { data = null; }
  return { ok: response.ok, status: response.status, data };
}
async function rpc(name, token, body) { return api(`/rest/v1/rpc/${name}`, token, body); }
function success(response, label) {
  assert.ok(response.ok && response.data?.success === true, `${label}: HTTP ${response.status}`);
  return response.data;
}
const adminSession = await sessionFor('919888888871');
const sessionA = await sessionFor('919888888872');
const sessionB = await sessionFor('919888888873');
const admin = adminSession.access_token, tokenA = sessionA.access_token, tokenB = sessionB.access_token;
const customers = await api('/rest/v1/customers?select=id,name', admin);
assert.ok(customers.ok);
const a = customers.data.find(row => row.name === 'Backend Test Customer A').id;
const b = customers.data.find(row => row.name === 'Backend Test Customer B').id;
const orders = await api('/rest/v1/orders?select=id,customer_id', admin);
assert.ok(orders.ok && orders.data.some(row => row.customer_id === a) && orders.data.some(row => row.customer_id === b),
  'staff queue sees both fictional customers');
const staffOrders = success(await rpc('get_orders_list', admin, { p_customer_id: a }), 'staff order queue');
assert.ok(staffOrders.data.orders.length >= 1, 'staff queue includes A order after dispatch');
const grn = (await api('/rest/v1/goodsreceived?gr_no=eq.BAA01&select=id', admin)).data[0].id;
const dispatch = (await api('/rest/v1/dispatch?disp_no=eq.BAD01&select=id', admin)).data[0].id;

for (const [kind, args] of [
  ['grn', { p_grn_id: grn, p_image_type: 'header' }],
  ['dispatch', { p_dispatch_id: dispatch }],
]) {
  const registration = success(await rpc(`register_${kind}_image_upload`, admin, { ...args,
    p_file_name: 'backend-test.jpg', p_file_size: 1024, p_mime_type: 'image/jpeg' }), `${kind} image registration`);
  const path = `/storage/v1/object/${kind}-images/${registration.storage_path}`;
  const uploaded = await fetch(base + path, { method: 'POST', headers: {
    apikey: anon, Authorization: `Bearer ${admin}`, 'Content-Type': 'image/jpeg',
  }, body: Buffer.alloc(1024), signal: AbortSignal.timeout(30000) });
  assert.equal(uploaded.status, 200, `${kind} image uploaded`);
  assert.ok(!(await api(path, tokenA)).ok, 'pending image hidden from A');
  success(await rpc(`confirm_${kind}_image_upload`, admin, { p_image_id: registration.image_id,
    p_upload_token: registration.upload_token }), `${kind} image confirmed`);
  assert.equal((await api(path, tokenA)).status, 200, 'A reads confirmed image');
  if (evidenceRoot) {
    const response = await fetch(base + path, { headers: { apikey: anon, Authorization: `Bearer ${admin}` }, signal: AbortSignal.timeout(30000) });
    assert.equal(response.status, 200, 'preserve bytes before intentional image lifecycle deletion');
    const bytes = Buffer.from(await response.arrayBuffer());
    assert.equal(bytes.length, 1024);
    assert.deepEqual(bytes, Buffer.alloc(1024), 'downloaded bytes match the actual fixture upload');
    writeFileSync(resolve(evidenceRoot, kind + '-image-before-delete.bin'), bytes, { flag: 'wx', mode: 0o400 });
    writeFileSync(resolve(evidenceRoot, kind + '-image-preservation.json'), JSON.stringify({ imageId: registration.image_id, storagePath: registration.storage_path, size: bytes.length, sha256: createHash('sha256').update(bytes).digest('hex') }) + '\n', { flag: 'wx', mode: 0o400 });
  }
  assert.ok(!(await api(path, tokenB)).ok, 'B cannot read A image');
  assert.ok(!(await api(path, anon)).ok, 'anonymous image read denied');
  success(await rpc(`delete_${kind}_image`, admin, { p_image_id: registration.image_id }), `${kind} image deleted`);
  assert.ok(!(await api(path, tokenA)).ok, 'deleted metadata revokes A image read');
  assert.ok((await api(`/storage/v1/object/${kind}-images`, admin,
    { prefixes: [registration.storage_path] }, 'DELETE')).ok, 'stored image bytes removed');
  const large = await rpc(`register_${kind}_image_upload`, admin, { ...args,
    p_file_name: 'large.jpg', p_file_size: 10485761, p_mime_type: 'image/jpeg' });
  assert.ok(!large.ok || large.data?.success === false, 'oversize image rejected');
}

const profileB = (await api('/rest/v1/user_profiles?mobile=eq.919888888873&select=id', admin)).data[0].id;
success(await rpc('operator_review_enrollment', admin,
  { p_user_id: profileB, p_decision: 'disabled', p_customer_ids: [] }), 'disable B');
assert.ok(!(await api('/rest/v1/customers?select=id', tokenB)).ok, 'disabled B REST session revoked');
const revoked = await rpc('refresh_jwt_token', anon, { p_refresh_token: sessionB.refresh_token });
assert.ok(!revoked.ok || revoked.data?.success === false, 'disabled B refresh denied');
assert.equal((await api('/functions/v1/get-config', tokenB)).status, 403, 'disabled B Edge session revoked');
for (const session of [adminSession, sessionA]) assert.equal((await rpc('logout_session', anon, { p_refresh_token: session.refresh_token })).data, true, 'new ordinary final-test session logout');
console.log('PASS isolated staff queue, GRN/dispatch image lifecycle and A/B privacy, oversize upload rejection, disabled account REST/Edge/refresh revocation');
