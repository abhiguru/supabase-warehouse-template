// Final backend-only checks against the disposable fictional operator stack.
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { readEnv } from '../scripts/doctor-common.mjs';

const state = process.env.WAREHOUSE_STATE_DIR;
assert.match(state || '', /^\/home\/testvm\/warehouse-pilot\/state\/core-backend-test-[0-9]+$/);
const env = readEnv(`${state}/config/compose.env`);
assert.equal(env.KONG_HTTP_PORT, '18080');
const anon = env.ANON_KEY, base = 'http://127.0.0.1:18080';
const quote = value => `'${String(value).replaceAll("'", "''")}'`;
function sql(expression) {
  const p = spawnSync('docker', ['exec', '-i', '-e', `PGPASSWORD=${env.POSTGRES_PASSWORD}`,
    `${env.WAREHOUSE_PROJECT_NAME}-db-1`, 'psql', '-X', '-qAt', '-U', 'supabase_admin', '-d', 'postgres',
    '-v', 'ON_ERROR_STOP=1'], { input: `SELECT (${expression})::text;\n`, encoding: 'utf8', timeout: 30000 });
  assert.equal(p.status, 0, `fixture SQL failed: ${p.stderr?.slice(-300)}`);
  return JSON.parse(p.stdout.trim());
}
function sessionFor(phone) {
  // Existing internal issuer in the disposable database only. OTP validation
  // and rate limits are exercised by the earlier suites; these sessions avoid
  // consuming further fictional challenges during image/queue verification.
  const result = sql(`warehouse_security.issue_session((SELECT auth_user_id FROM public.user_profiles WHERE mobile=${quote(phone)}))`);
  assert.ok(result.access_token && result.refresh_token, 'fictional test session issued');
  return result;
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
const adminSession = sessionFor('919888888871');
const sessionA = sessionFor('919888888872');
const sessionB = sessionFor('919888888873');
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
console.log('PASS isolated staff queue, GRN/dispatch image lifecycle and A/B privacy, oversize upload rejection, disabled account REST/Edge/refresh revocation');
