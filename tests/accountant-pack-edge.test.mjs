// WH-158 criterion 9 (contract section 4): the edge function generate-accountant-pack is wired like the other signed-in functions.
// Written BEFORE the build: fails today because the function, its router entry and its worker-env list do not exist.
// tests/worker-env.test.mjs already compares every list with the Deno.env.get() calls of the function and its imports; this file pins the new entry.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { existsSync, readFileSync } from 'node:fs';
import { workerEnvNames } from '../functions/main/worker-env.ts';

const functions = new URL('../functions/', import.meta.url).pathname;

test('[crit 9] generate-accountant-pack: the worker gets the signed-in names and the anon key, nothing else (no server-key call is needed beyond the signed-in set)', () => {
  assert.deepEqual([...workerEnvNames['generate-accountant-pack']].sort(),
    ['JWT_SECRET', 'SUPABASE_ANON_KEY', 'SUPABASE_REST_URL', 'SUPABASE_SERVICE_ROLE_KEY', 'SUPABASE_URL']);
});

test('[crit 9] generate-accountant-pack: the router allows it, and index.ts serves accountantPack from _shared/accountant-pack.ts', () => {
  const router = readFileSync(`${functions}main/index.ts`, 'utf8');
  assert.match(router, /'generate-accountant-pack'/);
  assert.ok(existsSync(`${functions}generate-accountant-pack/index.ts`));
  const index = readFileSync(`${functions}generate-accountant-pack/index.ts`, 'utf8');
  assert.match(index, /from\s+['"]\.\.\/_shared\/accountant-pack\.ts['"]/);
  assert.match(index, /Deno\.serve\(\s*accountantPack\s*\)/);
});

test('[crit 9] accountantPack refuses a GET with 405 (POST required) before it reads anything', async () => {
  const { accountantPack } = await import('../functions/_shared/accountant-pack.ts');
  const response = await accountantPack(new Request('http://localhost/generate-accountant-pack', { method: 'GET' }));
  assert.equal(response.status, 405);
  const body = await response.json();
  assert.equal(body.success, false);
});

// ---------- the handler's answers (contract section 4, Q8: makeAccountantPackHandler with injected deps) ----------
// makeAccountantPackHandler({ authorize, read, maxRows, maxZipBytes }) answers every status without a database or a token. Order: method (405) -> authorize
// (its own 401/403) -> body (400) -> read -> error code and reason mapping -> rows over maxRows -> build -> zip over maxZipBytes -> 200. A thrown read is 503.
// Fixed fixture, no clock injected: the zip times come from the read's made_at, so the same read gives the same bytes. Fictional names only.
const { makeAccountantPackHandler } = await import('../functions/_shared/accountant-pack.ts');

const LEDGER_KEYS = ['storage_taxable', 'storage_exempt', 'labour', 'cgst', 'sgst', 'igst', 'discount', 'round_off',
  'receipt_cash', 'receipt_upi', 'receipt_bank_transfer', 'receipt_cheque', 'receipt_other'];
const packData = ({ facility = 'Demo Cold Storage', from = '2026-10-01', to = '2026-10-31', whole = true, extraPayments = 0 } = {}) => ({
  made_at: '2026-11-01T05:30:00+00:00', made_by: 'Demo Administrator',
  facility: { name: facility, legal_name: facility, gstin: '24AAAAA0000A1Z5', state_code: '24', state_name: 'Gujarat', registered: true, gst_saved: true },
  period: { from_date: from, to_date: to, fin_year: 2026, whole_month: whole },
  record_payments: true,
  ledgers: Object.fromEntries(LEDGER_KEYS.map(k => [k, `L ${k}`])),
  documents: [{
    id: '10000000-0000-4000-8000-000000000001', doc_type: 'tax_invoice', number: 'SRT/12', date: '2026-10-15',
    customer_id: '00000000-0000-4000-8000-0000000000c1', customer_name: 'Demo Traders', customer_gstin: '24BBBBB1111B1Z3', customer_state: 'Gujarat (24)',
    place_of_supply: 'Gujarat (24)', sac_storage: '996721', sac_labour: '996719', tax_head: 'cgst_sgst', gr_no: 'G1001', linked_number: null,
    status: 'live', cancelled_on: null, imported: false, before_gst: false, discount: 0, round_off: 0, total: 105,
    rows: [{ kind: 'storage', exempt: false, rate: 5, taxable_value: 100, exempt_value: 0, cgst: 2.5, sgst: 2.5, igst: null, tax: 5 }],
  }],
  cancellations: [], changed_earlier: [],
  payments: Array.from({ length: extraPayments }, (_, n) => ({
    id: `20000000-0000-4000-8000-${String(n).padStart(12, '0')}`, payment_no: `APP-${n}`, paid_on: '2026-10-20', customer_id: null, customer_name: 'Walk-in Payer',
    invoice_id: null, invoice_number: null, amount: 1, mode: 'cash', bank: null, reference: null, note: null, cash_large: false, imported: false })),
  stock: [], issued: [{ doc_type: 'tax_invoice', first_number: 'SRT/12', last_number: 'SRT/12', count: 1, cancelled: 0 }], missing_numbers: [],
  customers: [{ id: '00000000-0000-4000-8000-0000000000c1', name: 'Demo Traders', gstin: '24BBBBB1111B1Z3', state_name: 'Gujarat (24)' }],
  renamed_customers: [],
});
const okRead = (data = packData()) => async () => ({ data: { success: true, data }, error: null });
const post = body => new Request('http://localhost/generate-accountant-pack', {
  method: 'POST', headers: { 'Content-Type': 'application/json' }, body: typeof body === 'string' ? body : JSON.stringify(body) });
const goodBody = { from_date: '2026-10-01', to_date: '2026-10-31' };
function handler(over = {}) {
  assert.equal(typeof makeAccountantPackHandler, 'function', 'functions/_shared/accountant-pack.ts exports makeAccountantPackHandler');
  const calls = { authorize: 0, read: 0, args: [] };
  const deps = {
    authorize: async () => { calls.authorize++; return {}; },
    read: async (...a) => { calls.read++; calls.args.push(a.slice(1)); return okRead()(); },
    maxRows: 50_000, maxZipBytes: 25 * 1024 * 1024, ...over,
  };
  return { calls, run: makeAccountantPackHandler(deps) };
}
const refused = async (response, status, code) => {
  assert.equal(response.status, status);
  assert.match(response.headers.get('Content-Type') ?? '', /application\/json/);
  assert.equal(response.headers.get('Cache-Control'), 'no-store');
  const body = await response.json();
  assert.equal(body.success, false);
  assert.equal(typeof body.error, 'string');
  if (code) assert.equal(body.code, code);
  else assert.equal('code' in body, false);
  return body;
};

test('[crit 9] handler: a GET is 405 before authorize or read is called', async () => {
  const { calls, run } = handler();
  await refused(await run(new Request('http://localhost/generate-accountant-pack', { method: 'GET' })), 405);
  assert.deepEqual([calls.authorize, calls.read], [0, 0]);
});

test('[crit 9] handler: authorize refuses first with its own 401 and 403, and read is never called', async () => {
  for (const [status, message] of [[401, 'Authentication required'], [403, 'Access denied']]) {
    const { calls, run } = handler({ authorize: async () => { throw Object.assign(new Error(message), { status }); } });
    await refused(await run(post(goodBody)), status);
    assert.equal(calls.read, 0, `${status}: nothing is read`);
  }
});

test('[crit 9] handler: a bad body is 400 INVALID_REQUEST (after authorize, before read)', async () => {
  for (const body of ['not json', '[]', {}, { from_date: '2026-10-01' }, { to_date: '2026-10-31' }, { from_date: 'yesterday', to_date: '2026-10-31' },
    { from_date: '2026-10-1', to_date: '2026-10-31' }, { from_date: 20261001, to_date: 20261031 }, { from_date: '2026-13-45', to_date: '2026-10-31' }]) {
    const { calls, run } = handler();
    await refused(await run(post(body)), 400, 'INVALID_REQUEST');
    assert.equal(calls.authorize, 1, 'authorize ran first');
    assert.equal(calls.read, 0, `nothing is read for ${JSON.stringify(body)}`);
  }
});

test('[crit 9] handler: read gets the request and the two dates, and a good answer is the zip (200, application/zip, no-store, attachment with a filename*)', async () => {
  const { calls, run } = handler();
  const response = await run(post(goodBody));
  assert.equal(response.status, 200);
  assert.equal(response.headers.get('Content-Type'), 'application/zip');
  assert.equal(response.headers.get('Cache-Control'), 'no-store');
  assert.equal(response.headers.get('Content-Disposition'), "attachment; filename*=UTF-8''demo-cold-storage-accountant-pack-2026-10.zip");
  assert.deepEqual(calls.args[0], ['2026-10-01', '2026-10-31']);
  const bytes = new Uint8Array(await response.arrayBuffer());
  assert.equal(String.fromCharCode(bytes[0], bytes[1], bytes[2], bytes[3]), 'PK\x03\x04', 'a zip starts with its local header');
  const text = Buffer.from(bytes).toString('latin1');
  for (const name of ['README.txt', 'sales-register.csv', 'receipts-register.csv', 'gstr1-working.csv', 'stock-statement.csv', 'tally-masters.xml', 'tally-vouchers.xml']) {
    assert.ok(text.includes(name), `${name} is in the zip`);
  }
});

test('[crit 9] handler: the same read gives the same bytes (the zip time is the read\'s made_at, no clock)', async () => {
  const first = new Uint8Array(await (await handler().run(post(goodBody))).arrayBuffer());
  const second = new Uint8Array(await (await handler().run(post(goodBody))).arrayBuffer());
  assert.deepEqual(first, second);
});

test('[crit 9] handler: the file name is the whole-month form or the range form, the slug is at most 40 characters and "facility" when nothing is left', async () => {
  const name = async data => (await handler({ read: okRead(data) }).run(post(goodBody))).headers.get('Content-Disposition');
  assert.equal(await name(packData({ from: '2026-10-05', to: '2026-10-20', whole: false })),
    "attachment; filename*=UTF-8''demo-cold-storage-accountant-pack-2026-10-05-to-2026-10-20.zip");
  assert.equal(await name(packData({ facility: '  Ram & Sons -- Cold (Store)  ' })), "attachment; filename*=UTF-8''ram-sons-cold-store-accountant-pack-2026-10.zip");
  assert.equal(await name(packData({ facility: 'a'.repeat(60) })), `attachment; filename*=UTF-8''${'a'.repeat(40)}-accountant-pack-2026-10.zip`);
  assert.equal(await name(packData({ facility: 'ગુરુ કોલ્ડ સ્ટોરેજ' })), "attachment; filename*=UTF-8''facility-accountant-pack-2026-10.zip");
});

test('[crit 9] handler: the RPC refusals map to 400 INVALID_PERIOD, 400 PERIOD_ACROSS_YEARS and 404 NOTHING_IN_PERIOD', async () => {
  for (const [reason, status] of [['INVALID_PERIOD', 400], ['PERIOD_ACROSS_YEARS', 400], ['NOTHING_IN_PERIOD', 404]]) {
    const { run } = handler({ read: async () => ({ data: { success: false, error_code: 'WH409', reason, error: 'Choose another period.' }, error: null }) });
    const body = await refused(await run(post(goodBody)), status, reason);
    assert.equal(body.error, 'Choose another period.');
  }
});

test('[crit 9] handler: the RPC error 42501 is 403 PACK_FORBIDDEN; 57014 (statement timeout) is 400 PACK_TOO_LONG; anything else is 503 PACK_UNAVAILABLE', async () => {
  const withError = error => handler({ read: async () => ({ data: null, error }) }).run(post(goodBody));
  await refused(await withError({ code: '42501' }), 403, 'PACK_FORBIDDEN');
  await refused(await withError({ code: '57014' }), 400, 'PACK_TOO_LONG');
  await refused(await withError({ code: 'XX000' }), 503, 'PACK_UNAVAILABLE');
  await refused(await withError({}), 503, 'PACK_UNAVAILABLE');
});

test('[crit 9] handler: a read that throws is 503 PACK_UNAVAILABLE and the message of the error is not in the answer', async () => {
  const { run } = handler({ read: async () => { throw new Error('connect ECONNREFUSED 10.9.8.7:3000 secret-token-xyz'); } });
  const response = await run(post(goodBody));
  const body = await refused(response, 503, 'PACK_UNAVAILABLE');
  assert.ok(!JSON.stringify(body).includes('ECONNREFUSED') && !JSON.stringify(body).includes('secret-token-xyz'));
});

test('[crit 9] handler: rows over maxRows (documents rows, payments and stock added up) are 400 PACK_TOO_LONG; exactly maxRows is built', async () => {
  // packData() has one document row; payments add the rest.
  const exactly = handler({ maxRows: 6, read: okRead(packData({ extraPayments: 5 })) });
  assert.equal((await exactly.run(post(goodBody))).status, 200, '1 document row + 5 payments = 6 = maxRows');
  const over = handler({ maxRows: 6, read: okRead(packData({ extraPayments: 6 })) });
  await refused(await over.run(post(goodBody)), 400, 'PACK_TOO_LONG');
  // The shipped limit is 50,000 data rows: 49,999 payments + 1 document row is accepted by the count, 50,000 + 1 is not. The big case is the refusal only (it is
  // answered before anything is built); the production default is pinned here by sending one row over.
  const production = handler({ read: okRead(packData({ extraPayments: 50_000 })) });
  await refused(await production.run(post(goodBody)), 400, 'PACK_TOO_LONG');
});

test('[crit 9] handler: a zip over maxZipBytes is 400 PACK_TOO_LONG, one that fits is 200', async () => {
  const size = (await (await handler().run(post(goodBody))).arrayBuffer()).byteLength;
  assert.ok(size > 100 && size < 25 * 1024 * 1024);
  assert.equal((await handler({ maxZipBytes: size }).run(post(goodBody))).status, 200, 'exactly the limit is allowed');
  await refused(await handler({ maxZipBytes: size - 1 }).run(post(goodBody)), 400, 'PACK_TOO_LONG');
});
