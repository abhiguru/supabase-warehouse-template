// What the app may match in an answer of the REST service (PostgREST, the pinned image of docker/docker-compose.yml): status, `code`
// and `message` for every refusal the app reacts to, asserted against the real service. tests/migrations.sh starts the pinned image
// against its disposable, migrated database and sets the four variables below; without them (npm test) only the table's own checks
// run. A PostgREST or migration change that moves a code the app keys on fails here before it reaches a facility.
//
// The table is also in docs/API_CONTRACT.md, "What the app may match: codes, not texts". `match` says what the app may rely on:
// 'code' (the app matches the code; the text is for people) or 'text' (the app still matches the English words; WS-3-app removes that).
import { after, before, test } from 'node:test';
import assert from 'node:assert/strict';
import { createHmac, randomUUID } from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { readFileSync } from 'node:fs';

const URL_BASE = process.env.POSTGREST_CONTRACT_URL;
const SECRET = process.env.POSTGREST_CONTRACT_SECRET;
const DB = process.env.POSTGREST_CONTRACT_DB_CONTAINER;
const DB_PASSWORD = process.env.POSTGREST_CONTRACT_DB_PASSWORD;
const live = Boolean(URL_BASE && SECRET && DB && DB_PASSWORD);

// ---- the table ---------------------------------------------------------------------------------------------------------------
// who: admin | staff | customer | anon | expired | forged | garbage | revoked | inactive (the token the request carries)
// request: [method, path, body]; status, code and message are what comes back (message: exact string, or a RegExp for PostgREST's own wording).
export const CASES = [
  { id: 'unknown-function', who: 'admin', request: ['POST', '/rpc/no_such_function', {}], status: 404, code: 'PGRST202', message: /^Could not find the function public\.no_such_function without parameters in the schema cache$/, match: 'code' },
  { id: 'unknown-parameter', who: 'admin', request: ['POST', '/rpc/get_next_grn_number', { p_not_a_parameter: 1 }], status: 404, code: 'PGRST202', message: /^Could not find the function public\.get_next_grn_number\(p_not_a_parameter\) in the schema cache$/, match: 'code' },
  { id: 'unknown-table', who: 'admin', request: ['GET', '/no_such_table?select=*'], status: 404, code: 'PGRST205', message: /^Could not find the table 'public\.no_such_table' in the schema cache$/, match: 'code' },
  { id: 'unknown-column', who: 'admin', request: ['GET', '/items?select=no_such_column'], status: 400, code: '42703', message: 'column items.no_such_column does not exist', match: 'code' },
  { id: 'bad-uuid', who: 'admin', request: ['POST', '/rpc/get_grn_details', { p_grn_id: 'not-a-uuid' }], status: 400, code: '22P02', message: 'invalid input syntax for type uuid: "not-a-uuid"', match: 'code' },
  { id: 'jwt-expired', who: 'expired', request: ['POST', '/rpc/get_next_grn_number', {}], status: 401, code: 'PGRST303', message: 'JWT expired', match: 'text' },
  { id: 'jwt-wrong-key', who: 'forged', request: ['POST', '/rpc/get_next_grn_number', {}], status: 401, code: 'PGRST301', message: 'No suitable key or wrong key type', match: 'code' },
  { id: 'jwt-garbage', who: 'garbage', request: ['POST', '/rpc/get_next_grn_number', {}], status: 401, code: 'PGRST301', message: 'JWT cryptographic operation failed', match: 'code' },
  { id: 'anon-denied', who: 'anon', request: ['POST', '/rpc/get_next_grn_number', {}], status: 401, code: '42501', message: 'permission denied for function get_next_grn_number', match: 'code' },
  { id: 'session-revoked', who: 'revoked', request: ['POST', '/rpc/get_next_grn_number', {}], status: 403, code: '42501', message: 'Session expired or revoked', match: 'text' },
  { id: 'account-inactive', who: 'inactive', request: ['POST', '/rpc/get_next_grn_number', {}], status: 403, code: '42501', message: 'Session expired or revoked', match: 'text' },
  { id: 'staff-required', who: 'customer', request: ['POST', '/rpc/get_next_grn_number', {}], status: 403, code: '42501', message: 'Staff access required', match: 'text' },
  { id: 'administrator-required', who: 'staff', request: ['POST', '/rpc/clear_user_central_identity', { p_user_id: randomUUID() }], status: 403, code: '42501', message: 'Administrator required', match: 'text' },
  { id: 'customer-denied', who: 'customer', request: ['POST', '/rpc/get_customer_stock_summary', { p_customer_uuid: randomUUID() }], status: 403, code: '42501', message: 'Customer access denied', match: 'text' },
  { id: 'read-only-get', who: 'admin', request: ['GET', '/rpc/create_item?p_name=x'], status: 405, code: '25006', message: 'cannot execute INSERT in a read-only transaction', match: 'code' },
];

// Answers that are a 200 with an envelope the app reads (`success: false` and a code or message inside), not an HTTP error. `body` is the
// part of the answer that is asserted; a RegExp is matched, anything else is compared exactly.
export const ENVELOPES = [
  { id: 'wrapped-refusal', who: 'staff', request: ['POST', '/rpc/update_user_role', { p_user_id: randomUUID(), p_new_role: 'staff' }],
    body: { success: false, error_code: 'INTERNAL_ERROR', message: /Administrator required$/ }, match: 'text' },
  { id: 'report-refusal', who: 'customer', request: ['POST', '/rpc/get_customer_grn_activity', { p_customer_uuid: randomUUID() }],
    body: { success: false, error_code: '42501', error: /Customer access denied$/ }, match: 'code' },
];
// create_item and create_customer answer a duplicate name in a 200 envelope (the creating calls are in the test below).
export const DUPLICATES = ['duplicate-item-name', 'duplicate-customer-name'];

// The words of the guard (tests/role_allowlist.sql, ra_outcome) are all in authorize_rpc; 'Active account required' is reached over HTTP
// only as 'Session expired or revoked' (the pre-request session check answers first), so it is asserted in the function's source.
export const GUARD_TEXTS = ['Staff access required', 'Administrator required', 'Customer access denied', 'Active account required'];

test('the table is complete: unique ids, a status and a code on each, and every case is in docs/API_CONTRACT.md', () => {
  const ids = [...CASES.map(c => c.id), ...ENVELOPES.map(c => c.id), ...DUPLICATES];
  assert.equal(new Set(ids).size, ids.length);
  const docs = readFileSync(new URL('../docs/API_CONTRACT.md', import.meta.url), 'utf8');
  const section = docs.slice(docs.indexOf('What the app may match: codes, not texts'));
  assert.ok(section.length < docs.length, 'docs/API_CONTRACT.md has the section "What the app may match: codes, not texts"');
  for (const c of CASES) {
    assert.ok(Number.isInteger(c.status) && c.code && c.message && ['code', 'text'].includes(c.match), c.id);
    assert.ok(section.includes(`\`${c.id}\``), `${c.id} is not in the table of docs/API_CONTRACT.md`);
    assert.ok(section.includes(`| ${c.status} | \`${c.code}\``), `${c.id}: the table of docs/API_CONTRACT.md lacks ${c.status} ${c.code}`);
  }
  for (const id of [...ENVELOPES.map(c => c.id), ...DUPLICATES]) assert.ok(section.includes(`\`${id}\``), `${id} is not in the table of docs/API_CONTRACT.md`);
  for (const text of GUARD_TEXTS) assert.ok(section.includes(text), `${text} is not in the table of docs/API_CONTRACT.md`);
});

test('the gateway answers a missing or wrong API key with the two messages the app recognises', () => {
  const map = readFileSync(new URL('../docker/nginx/templates/http.conf.template', import.meta.url), 'utf8');
  assert.match(map, /map \$http_apikey \$apikey_error \{\n\s+default\s+"Unauthorized";\n\s+""\s+"No API key found in request";/);
  assert.match(readFileSync(new URL('../docker/nginx/api-locations.conf', import.meta.url), 'utf8'), /return 401 '\{"message":"\$apikey_error"\}';/);
});

test('tests/migrations.sh runs this file with the TAP reporter its summary check reads, and with timeouts; the docker exec calls have one too', () => {
  const script = readFileSync(new URL('./migrations.sh', import.meta.url), 'utf8');
  assert.match(script, /node --test --test-reporter=tap --test-timeout=60000 "\$ROOT\/tests\/postgrest-contract\.test\.mjs"/);
  assert.match(readFileSync(new URL(import.meta.url), 'utf8'), /encoding: 'utf8', timeout: 30000 \}\);/);
});

// ---- against the service -----------------------------------------------------------------------------------------------------
const skip = live ? false : 'POSTGREST_CONTRACT_URL, _SECRET, _DB_CONTAINER and _DB_PASSWORD are set by tests/migrations.sh';
const b64 = value => Buffer.from(value).toString('base64url');
const sign = (claims, key = SECRET) => {
  const head = `${b64(JSON.stringify({ alg: 'HS256', typ: 'JWT' }))}.${b64(JSON.stringify(claims))}`;
  return `${head}.${createHmac('sha256', key).update(head).digest('base64url')}`;
};
function sql(statement) {
  const run = spawnSync('docker', ['exec', '-i', '-e', `PGPASSWORD=${DB_PASSWORD}`, DB, 'psql', '-X', '-qAt', '-U', 'supabase_admin', '-d', 'postgres', '-v', 'ON_ERROR_STOP=1'], { input: statement, encoding: 'utf8', timeout: 30000 });
  assert.equal(run.status, 0, `fixture SQL failed: ${run.stderr}`);
  return run.stdout.trim();
}
const people = {};
const created = { phones: [], customers: [] };
function person(role, phone) {
  created.phones.push(phone);
  const [sub, session] = sql(`WITH p AS (INSERT INTO public.user_profiles(auth_user_id,mobile,name,role,active,enrollment_status)
      VALUES (gen_random_uuid(),'${phone}','Contract ${role}','${role}',true,'approved') RETURNING auth_user_id),
    s AS (INSERT INTO warehouse_security.refresh_sessions(user_id,token_hash,expires_at)
      SELECT auth_user_id, encode(extensions.gen_random_bytes(32),'hex'), now()+interval '1 hour' FROM p RETURNING id,user_id)
    SELECT user_id || ' ' || id FROM s;`).split(' ');
  return { sub, session };
}
const claims = (who, extra = {}) => ({ role: 'authenticated', sub: who.sub, session_id: who.session, iat: Math.floor(Date.now() / 1000), exp: Math.floor(Date.now() / 1000) + 300, ...extra });
const tokenFor = who => {
  const now = Math.floor(Date.now() / 1000);
  switch (who) {
    case 'anon': return null;
    case 'expired': return sign(claims(people.admin, { exp: now - 60 }));
    case 'forged': return sign(claims(people.admin), `${SECRET}-another-key`);
    case 'garbage': return 'not.a.jwt';
    default: return sign(claims(people[who]));
  }
};
async function call([method, path, body], token) {
  const response = await fetch(`${URL_BASE}${path}`, { method, headers: { 'content-type': 'application/json', ...(token ? { authorization: `Bearer ${token}` } : {}) },
    body: body === undefined ? undefined : JSON.stringify(body), signal: AbortSignal.timeout(30000) });
  const text = await response.text();
  let json = null;
  try { json = JSON.parse(text); } catch { /* not JSON */ }
  return { status: response.status, json, text };
}

before(() => {
  if (!live) return;
  // One person of each role the cases need. `revoked` loses its session and `inactive` is switched off after the others are made.
  Object.assign(people, { admin: person('admin', '919000000101'), staff: person('staff', '919000000102'), customer: person('customer', '919000000103'),
    revoked: person('staff', '919000000104'), inactive: person('staff', '919000000105') });
  sql(`DELETE FROM warehouse_security.refresh_sessions WHERE id = '${people.revoked.session}'`);
  sql(`UPDATE public.user_profiles SET active = false WHERE mobile = '919000000105'`);
});
after(() => {
  if (!live) return;
  // The disposable database is thrown away, but the later drills of tests/migrations.sh run on it: leave nothing of ours.
  const phones = created.phones.map(phone => `'${phone}'`).join(',');
  sql(`DELETE FROM warehouse_security.refresh_sessions WHERE user_id IN (SELECT auth_user_id FROM public.user_profiles WHERE mobile IN (${phones}));
       DELETE FROM public.customers WHERE name LIKE 'Contract %';
       DELETE FROM public.items WHERE name LIKE 'Contract %';
       DELETE FROM public.user_profiles WHERE mobile IN (${phones});`);
});

for (const c of CASES) {
  test(`${c.id}: ${c.status} ${c.code}`, { skip }, async () => {
    const answer = await call(c.request, tokenFor(c.who));
    assert.equal(answer.status, c.status, answer.text);
    assert.equal(answer.json?.code, c.code, answer.text);
    if (typeof c.message === 'string') assert.equal(answer.json?.message, c.message, answer.text);
    else assert.match(answer.json?.message ?? '', c.message, answer.text);
  });
}

for (const c of ENVELOPES) {
  test(`${c.id}: a 200 envelope`, { skip }, async () => {
    const answer = await call(c.request, tokenFor(c.who));
    assert.equal(answer.status, 200, answer.text);
    for (const [key, expected] of Object.entries(c.body)) {
      if (expected instanceof RegExp) assert.match(String(answer.json?.[key]), expected, answer.text);
      else assert.equal(answer.json?.[key], expected, answer.text);
    }
  });
}

test('duplicate-item-name and duplicate-customer-name: a 200 envelope that carries DUPLICATE_NAME', { skip }, async () => {
  const token = tokenFor('admin');
  const item = ['POST', '/rpc/create_item', { p_name: 'Contract Potatoes', p_packaging: 'Bag' }];
  const first = await call(item, token);
  assert.equal(first.status, 200, first.text);
  assert.equal(first.json?.success, true, first.text);
  const second = await call(['POST', '/rpc/create_item', { p_name: 'contract potatoes', p_packaging: 'Bag' }], token);
  assert.equal(second.status, 200, second.text);
  assert.deepEqual({ success: second.json?.success, error_code: second.json?.error_code }, { success: false, error_code: 'DUPLICATE_NAME' }, second.text);
  const customer = n => ['POST', '/rpc/create_customer', { p_name: 'Contract Customer', p_mobile: `98888888${n}` }];
  const one = await call(customer(41), token);
  assert.equal(one.json?.success, true, one.text);
  const two = await call(customer(42), token);
  assert.equal(two.status, 200, two.text);
  assert.deepEqual({ success: two.json?.success, code: two.json?.error?.code, field: two.json?.error?.field }, { success: false, code: 'DUPLICATE_NAME', field: 'name' }, two.text);
});

test('a staff account is let in where the allowlist says so, and the same call by a customer is refused with 42501', { skip }, async () => {
  const allowed = await call(['POST', '/rpc/get_next_grn_number', {}], tokenFor('staff'));
  assert.equal(allowed.status, 200, allowed.text);
  const refused = await call(['POST', '/rpc/get_next_grn_number', {}], tokenFor('customer'));
  assert.deepEqual([refused.status, refused.json?.code], [403, '42501']);
});

test('every word of the guard is in authorize_rpc, and the wording of the two session answers is in check_session and active_role', { skip }, () => {
  const source = sql(`SELECT prosrc FROM pg_proc WHERE oid = 'warehouse_security.authorize_rpc(text,jsonb)'::regprocedure`);
  for (const text of GUARD_TEXTS) assert.ok(source.includes(text), `authorize_rpc no longer says "${text}"`);
  assert.ok(sql(`SELECT prosrc FROM pg_proc WHERE oid = 'public.check_session()'::regprocedure`).includes('Session expired or revoked'));
});
