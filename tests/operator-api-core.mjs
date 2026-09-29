// Backend-only acceptance against a disposable operator installation.
// Run with WAREHOUSE_STATE_DIR pointing to the dedicated core-backend-test state.
// No SMS worker is invoked: challenges are completed through the existing
// service-only database functions and their one-time codes never enter logs.
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { readEnv } from '../scripts/doctor-common.mjs';

const state = process.env.WAREHOUSE_STATE_DIR;
assert.match(state || '', /^\/home\/testvm\/warehouse-pilot\/state\/core-backend-test-[0-9]+$/);
const env = readEnv(`${state}/config/compose.env`);
assert.equal(env.KONG_HTTP_PORT, '18080');
assert.match(env.WAREHOUSE_PROJECT_NAME, /^warehouse-[a-f0-9-]+$/);
assert.equal(env.AUTH_MODE, 'operator');
const base = 'http://127.0.0.1:18080';
const anon = env.ANON_KEY;
const sql = query => {
  const result = spawnSync('docker', ['exec', '-i', '-e', `PGPASSWORD=${env.POSTGRES_PASSWORD}`,
    `${env.WAREHOUSE_PROJECT_NAME}-db-1`, 'psql', '-X', '-qAt', '-U', 'supabase_admin', '-d', 'postgres',
    '-v', 'ON_ERROR_STOP=1'], { input: query + '\n', encoding: 'utf8', timeout: 30000 });
  assert.equal(result.status, 0, `private fixture SQL failed: ${result.stderr?.slice(-400)}`);
  return result.stdout.trim();
};
const quote = value => `'${String(value).replaceAll("'", "''")}'`;
const queryJson = query => JSON.parse(sql(`SELECT (${query})::text;`));
async function api(path, token = anon, body, method = body === undefined ? 'GET' : 'POST') {
  const response = await fetch(base + path, { method, headers: {
    apikey: anon, Authorization: `Bearer ${token}`, 'Content-Type': 'application/json',
  }, body: body === undefined ? undefined : JSON.stringify(body), signal: AbortSignal.timeout(30000) });
  const raw = await response.text();
  let data; try { data = JSON.parse(raw); } catch { data = null; }
  return { status: response.status, ok: response.ok, data };
}
async function rpc(name, token, body = {}) {
  return api(`/rest/v1/rpc/${name}`, token, body);
}
function good(result, label) {
  assert.ok(result.ok, `${label}: HTTP ${result.status}`);
  assert.equal(result.data?.success, true, `${label}: ${result.data?.code || result.data?.message || 'failed'}`);
  return result.data;
}
function challenge(phone) {
  const prepared = queryJson(`public.operator_prepare_otp(${quote(phone)})`);
  assert.equal(prepared.success, true, 'fictional challenge prepared');
  const finished = queryJson(`public.operator_finish_otp(${quote(prepared.data.request_id)}::uuid,true,'mock-provider-only')`);
  assert.equal(finished.success, true, 'mock provider accepted');
  return prepared.data.otp_code;
}
function login(phone, name) {
  const code = challenge(phone);
  const verified = queryJson(`public.operator_verify_otp(${quote(phone)},${quote(code)},${quote(name)})`);
  assert.equal(verified.success, true, 'fictional login verified');
  return verified.data;
}
function mustUuid(value) { assert.match(value, /^[0-9a-f-]{36}$/); return value; }

const identity = await fetch(`${base}/functions/v1/get-public-config`, { signal: AbortSignal.timeout(30000) });
assert.equal(identity.status, 200, 'isolated public identity');
const publicConfig = await identity.json();
assert.equal(publicConfig.data?.companyName, 'Fictional Core Warehouse');
assert.equal(publicConfig.data?.canonicalOrigin, 'https://backend-core.example.test');
assert.ok(!(await api('/rest/v1/customers?select=id')).ok, 'anonymous customer read denied');

const admin = login('919888888871', 'Core Demo Administrator');
assert.equal(admin.action, 'login');
const adminToken = admin.session.access_token;
const createdA = good(await rpc('create_customer', adminToken, { p_name: 'Backend Test Customer A', p_mobile: '9888888872' }), 'create A');
const createdB = good(await rpc('create_customer', adminToken, { p_name: 'Backend Test Customer B', p_mobile: '9888888873' }), 'create B');
const a = mustUuid(createdA.data.customer_id), b = mustUuid(createdB.data.customer_id);
const catalog = good(await rpc('create_item', adminToken, { p_name: 'Backend Test Potatoes', p_packaging: 'Bag' }), 'catalog');
const item = mustUuid(catalog.data.id);
good(await rpc('create_item_storage_price', adminToken, { p_item_id: item, p_price_type: 'monthly',
  p_unit_price: 5, p_weight_min: 0, p_weight_max: 100, p_labour_rate: 2,
  p_tax_percent: 5, p_effective_from: '2026-01-01', p_customer_id: a }), 'fictional price');

for (const [phone, name] of [['919888888872', 'Customer A'], ['919888888873', 'Customer B']]) {
  const pending = login(phone, name);
  assert.equal(pending.action, 'pending');
  assert.ok(!pending.session, 'pending customer has no session');
}
const profileA = mustUuid(sql("SELECT id FROM public.user_profiles WHERE mobile='919888888872'"));
const profileB = mustUuid(sql("SELECT id FROM public.user_profiles WHERE mobile='919888888873'"));
good(await rpc('operator_review_enrollment', adminToken,
  { p_user_id: profileA, p_decision: 'approved', p_customer_ids: [a] }), 'approve A');
good(await rpc('operator_review_enrollment', adminToken,
  { p_user_id: profileB, p_decision: 'approved', p_customer_ids: [b] }), 'approve B');
// The first accepted fictional challenge has a one-minute resend cooldown.
await new Promise(resolve => setTimeout(resolve, 61000));
const sessionA = login('919888888872', 'Customer A').session;
const sessionB = login('919888888873', 'Customer B').session;
const tokenA = sessionA.access_token, tokenB = sessionB.access_token;
const listA = await api('/rest/v1/customers?select=id', tokenA);
const listB = await api('/rest/v1/customers?select=id', tokenB);
assert.deepEqual(listA.data.map(row => row.id), [a], 'A only sees A');
assert.deepEqual(listB.data.map(row => row.id), [b], 'B only sees B');
assert.equal((await api(`/rest/v1/customers?id=eq.${b}&select=id`, tokenA)).data.length, 0, 'A cannot read B');
const deniedUpdate = await api(`/rest/v1/customers?id=eq.${b}`, tokenA, { name: 'Unauthorized edit' }, 'PATCH');
assert.ok(!deniedUpdate.ok || (await api(`/rest/v1/customers?id=eq.${b}&select=name`, adminToken)).data[0].name === 'Backend Test Customer B', 'A cannot mutate B');

const receipt = good(await rpc('save_grn', adminToken, { p_gr_no: 'BAA01', p_date: '2026-04-01T12:00:00Z',
  p_customer_id: a, p_customer_name: 'Backend Test Customer A', p_pricing_mode: 'MONTHLY',
  p_idempotency_key: 'backend-test-receipt-a',
  p_items: [{ item_id: item, item_name: 'Backend Test Potatoes', packaging: 'Bag', qty: 100, weight: 10, rack: 'TEST' }] }), 'receipt');
assert.ok(receipt.success);
const grn = mustUuid((await api('/rest/v1/goodsreceived?gr_no=eq.BAA01&select=id', adminToken)).data[0].id);
const stock = mustUuid((await api(`/rest/v1/goodsreceived_trl?gr_id=eq.${grn}&select=id`, adminToken)).data[0].id);
assert.equal((await api(`/rest/v1/goodsreceived?id=eq.${grn}&select=id`, tokenB)).data.length, 0, 'B cannot read A receipt');
const attachment = `${a}/backend-core.jpg`;
const attachmentPath = `/storage/v1/object/customer-images/${attachment}`;
async function upload(token, body = Buffer.alloc(256)) {
  return fetch(base + attachmentPath, { method: 'POST', headers: {
    apikey: anon, Authorization: `Bearer ${token}`, 'Content-Type': 'image/jpeg',
  }, body, signal: AbortSignal.timeout(30000) });
}
for (const token of [anon, tokenA, tokenB])
  assert.ok([400, 401, 403].includes((await upload(token)).status), 'non-staff attachment upload denied');
assert.equal((await upload(adminToken)).status, 200, 'admin attachment upload');
assert.equal((await api(attachmentPath, adminToken)).status, 200, 'admin attachment read');
for (const token of [anon, tokenA, tokenB])
  assert.ok(!(await api(attachmentPath, token)).ok, 'non-staff attachment read denied');
assert.ok(!(await upload(adminToken)).ok, 'duplicate attachment upload rejected');
assert.equal((await api(attachmentPath, adminToken)).status, 200, 'failed retry preserves first upload');
const cartA = await rpc('get_or_create_cart', tokenA, { p_customer_id: a });
assert.ok(cartA.ok && typeof cartA.data === 'string', 'A cart created');
const foreignCart = await rpc('get_or_create_cart', tokenB, { p_customer_id: a });
assert.ok(!foreignCart.ok || foreignCart.data?.success === false, 'B cannot create A cart');
good(await rpc('add_item_to_order', tokenA, { p_order_id: cartA.data, p_grn_item_id: stock, p_quantity: 7 }), 'A cart add');
const orderA = good(await rpc('get_orders_list', tokenA, { p_customer_id: a, p_has_items: true }), 'A orders');
assert.equal(orderA.data.orders.find(row => row.id === cartA.data)?.quantity_sum, 7);
const orderB = good(await rpc('get_orders_list', tokenB, { p_customer_id: b }), 'B orders');
assert.ok(!orderB.data.orders.some(row => row.id === cartA.data), 'B cannot list A cart');

const dispatchData = { disp_no: 'BAD01', disp_date: '2026-05-02T12:00:00Z', customer_id: a,
  customer_name: 'Backend Test Customer A', supervisor_id: admin.user.id,
  supervisor_name: 'Core Demo Administrator' };
const partial = { p_dispatch_data: dispatchData, p_dispatch_items: [{ gr_trl_id: stock, disp_qty: 20 }],
  p_generate_invoice: false, p_idempotency_key: 'backend-test-dispatch-partial' };
good(await rpc('create_dispatch_with_stock_check', adminToken, partial), 'partial dispatch');
good(await rpc('create_dispatch_with_stock_check', adminToken, partial), 'dispatch retry');
assert.equal((await api(`/rest/v1/goodsreceived_trl?id=eq.${stock}&select=stock`, adminToken)).data[0].stock, 80);
const invalid = await rpc('create_dispatch_with_stock_check', adminToken, { ...partial,
  p_idempotency_key: 'backend-test-invalid', p_dispatch_items: [{ gr_trl_id: stock, disp_qty: -1 }] });
assert.ok(!invalid.ok || invalid.data?.success === false, 'negative dispatch rejected');
const oversell = await rpc('create_dispatch_with_stock_check', adminToken, { ...partial,
  p_idempotency_key: 'backend-test-oversell', p_dispatch_items: [{ gr_trl_id: stock, disp_qty: 81 }] });
assert.ok(!oversell.ok || oversell.data?.success === false, 'oversell rejected');
assert.equal((await api(`/rest/v1/goodsreceived_trl?id=eq.${stock}&select=stock`, adminToken)).data[0].stock, 80);
good(await rpc('create_dispatch_with_stock_check', adminToken, { ...partial,
  p_dispatch_data: { ...dispatchData, disp_no: 'BAD02' },
  p_dispatch_items: [{ gr_trl_id: stock, disp_qty: 80 }], p_idempotency_key: 'backend-test-dispatch-final' }), 'final dispatch');
assert.equal((await api(`/rest/v1/goodsreceived_trl?id=eq.${stock}&select=stock`, adminToken)).data[0].stock, 0);
const preview = good(await rpc('generate_invoice_data_for_grn_with_pricing', adminToken,
  { p_gr_id: grn, p_duration_mode: 'legacy' }), 'invoice preview');
assert.deepEqual(preview.totals, { subtotal: 950, tax: 48, total_tax: 48, grand_total: 998, total: 998, total_rows: 2 });
const dispatchHeaders = await api('/rest/v1/dispatch?disp_no=in.(BAD01,BAD02)&select=id', adminToken);
assert.ok(dispatchHeaders.ok && dispatchHeaders.data.length === 2, 'two dispatch headers available for invoice');
const dispatchLines = [];
for (const header of dispatchHeaders.data) {
  const lines = await api(`/rest/v1/dispatch_trl?disp_id=eq.${header.id}&select=id`, adminToken);
  assert.ok(lines.ok && lines.data.length === 1, 'one line per fictional dispatch');
  dispatchLines.push(lines.data[0]);
}
const saved = good(await rpc('save_invoice', adminToken, { p_invoice_data: {
  inv_no: 20260929, inv_fin_year: 2026, gr_id: grn, gr_no: 'BAA01', customer_id: a,
  customer_name: 'Backend Test Customer A', inv_date: '2026-05-02T12:00:00Z',
  total: 998, tax_amount: 48, discount: 0, duration_mode: 'legacy',
  items: dispatchLines.map(line => ({ disp_trl_id: line.id, charge: 5, tax: 5, labour_rate: 2 })),
} }), 'save invoice');
assert.equal((await api(`/rest/v1/invoice?id=eq.${saved.invoice_id}&select=total`, adminToken)).data[0].total, 998);
async function document(name, body) {
  const response = await api(`/functions/v1/${name}`, tokenA, body);
  const data = good(response, name);
  const signed = new URL(data.pdf_url);
  assert.equal(signed.origin, 'https://backend-core.example.test', 'document uses configured origin');
  const download = await fetch(base + signed.pathname + signed.search, { signal: AbortSignal.timeout(30000) });
  assert.equal(download.status, 200, 'signed document download');
  const bytes = new Uint8Array(await download.arrayBuffer());
  assert.equal(new TextDecoder().decode(bytes.slice(0, 5)), '%PDF-', 'valid PDF bytes');
  const object = `/storage/v1/object/documents/${decodeURIComponent(signed.pathname.split('/documents/')[1])}`;
  for (const token of [anon, tokenA, tokenB])
    assert.ok(!(await api(object, token)).ok, 'private PDF bucket denies direct reads');
  assert.equal((await api(`/functions/v1/${name}`, tokenB, body)).status, 404, 'B cannot generate A document');
}
await document('generate-grn-pdf', { gr_no: 'BAA01' });
await document('generate-dispatch-pdf', { disp_no: 'BAD01' });
await document('generate-invoice-pdf', { inv_no: 20260929, fin_year: 2026 });
await document('generate-customer-stock-pdf', { customer_id: a });
good(await rpc('save_grn', adminToken, { p_gr_no: 'BAC01', p_date: '2026-04-01T12:00:00Z',
  p_customer_id: a, p_customer_name: 'Backend Test Customer A', p_pricing_mode: 'MONTHLY',
  p_items: [{ item_id: item, item_name: 'Backend Test Potatoes', packaging: 'Bag', qty: 10, weight: 10, rack: 'RACE' }] }), 'concurrency receipt');
const raceGrn = mustUuid((await api('/rest/v1/goodsreceived?gr_no=eq.BAC01&select=id', adminToken)).data[0].id);
const raceStock = mustUuid((await api(`/rest/v1/goodsreceived_trl?gr_id=eq.${raceGrn}&select=id`, adminToken)).data[0].id);
const raceArgs = [1, 2].map(n => ({ p_dispatch_data: { ...dispatchData, disp_no: `BAC0${n}` },
  p_dispatch_items: [{ gr_trl_id: raceStock, disp_qty: 7 }], p_generate_invoice: false,
  p_idempotency_key: `backend-test-race-${n}` }));
const raceResults = await Promise.all(raceArgs.map(args => rpc('create_dispatch_with_stock_check', adminToken, args)));
assert.equal(raceResults.filter(result => result.ok && result.data?.success === true).length, 1,
  'only one conflicting dispatch succeeds');
assert.equal((await api(`/rest/v1/goodsreceived_trl?id=eq.${raceStock}&select=stock`, adminToken)).data[0].stock, 3,
  'concurrent stock balance is 3');
const refreshed = good(await rpc('refresh_jwt_token', anon, { p_refresh_token: sessionA.refresh_token }), 'refresh');
assert.equal((await rpc('refresh_jwt_token', anon, { p_refresh_token: sessionA.refresh_token })).data?.success, false, 'old refresh cannot replay');
assert.equal((await rpc('logout_session', anon, { p_refresh_token: refreshed.refresh_token })).data, true, 'logout');
assert.ok(!(await api('/rest/v1/customers?select=id', refreshed.access_token)).ok, 'logged-out access rejected');
console.log('PASS isolated HTTP identity, roles, A/B lists and mutations, Storage upload privacy/retry, catalog, pricing, cart, receipt, stock, dispatch retry/concurrency, invalid quantities, invoice, signed PDFs, refresh/replay, and logout');
