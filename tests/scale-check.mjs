// A repeatable scale check (the scale-check job of .github/workflows/ci.yml): the list and polled RPCs the app calls, at the volume
// of tests/seed/make-seed.mjs --years 5, for SCALE_SECONDS (60) with SCALE_WORKERS (20) concurrent workers, as signed-in users of
// each role. It writes scale-check.json (p50, p95 and max in milliseconds per RPC) and fails when an RPC call fails or times out;
// it fails on a p95 above SCALE_P95_MS (300, the bar of migration 125) only with SCALE_ENFORCE=1, else it prints a warning.
// Needs the fictional installation of tests/operator-fixture.mjs (WAREHOUSE_STATE_DIR) with the seed loaded:
//   node tests/seed/make-seed.mjs --years 5 | bash scripts/compose.sh exec -T db psql -X -q -v ON_ERROR_STOP=1 -U supabase_admin -d postgres
//   SCALE_ENFORCE=0 node tests/scale-check.mjs
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { writeFileSync } from 'node:fs';
import { performance } from 'node:perf_hooks';
import { isMain } from '../scripts/is-main.mjs';

// The statement timeout of the authenticated role is 8 s (docker/volumes/db/00-bootstrap.sql); the client gives up a little later.
export const REQUEST_TIMEOUT_MS = 10000;

export function percentile(sorted, fraction) {
  if (!sorted.length) return null;
  return sorted[Math.min(sorted.length - 1, Math.max(0, Math.ceil(sorted.length * fraction) - 1))];
}

const round = value => Math.round(value * 10) / 10;

// samples: { rpcName: { durations: [ms], errors: n } } -> { rpcName: { calls, errors, p50, p95, max } }
export function summarise(samples) {
  const result = {};
  for (const [name, { durations, errors }] of Object.entries(samples)) {
    const sorted = [...durations].sort((a, b) => a - b);
    result[name] = { calls: sorted.length + errors, errors, p50: sorted.length ? round(percentile(sorted, 0.5)) : null,
      p95: sorted.length ? round(percentile(sorted, 0.95)) : null, max: sorted.length ? round(sorted.at(-1)) : null };
  }
  return result;
}

// The verdict: an RPC with errors (or no answer at all) always fails; a p95 above the limit fails only when enforced, else it is a warning.
export function evaluate(summary, { limitMs, enforce }) {
  const failures = [];
  const warnings = [];
  for (const [name, row] of Object.entries(summary)) {
    if (row.errors > 0 || row.p95 === null) failures.push(`${name}: ${row.errors} of ${row.calls} calls failed or timed out`);
    else if (row.p95 > limitMs) (enforce ? failures : warnings).push(`${name}: p95 ${row.p95} ms is above ${limitMs} ms`);
  }
  return { failures, warnings };
}

export function settings(environment = process.env) {
  const number = (key, fallback) => {
    const text = environment[key];
    if (text === undefined || text === '') return fallback;
    const value = Number(text);
    if (!Number.isFinite(value) || value <= 0) throw new RangeError(`${key} must be a positive number`);
    return value;
  };
  const enforce = environment.SCALE_ENFORCE ?? '0';
  if (!['0', '1'].includes(enforce)) throw new RangeError('SCALE_ENFORCE must be 0 or 1');
  return { seconds: number('SCALE_SECONDS', 60), workers: Math.floor(number('SCALE_WORKERS', 20)), limitMs: number('SCALE_P95_MS', 300),
    enforce: enforce === '1', adminPhone: environment.SCALE_ADMIN_PHONE || '919888888871', output: environment.SCALE_OUTPUT || 'scale-check.json' };
}

// What each role may call (warehouse_security.authorize_rpc): staff and administrators the lists and sensors; a customer its own
// orders and invoice summary. `big` is the customer with the most receipts (customer 1 of the seed: it is among the 20% that hold 80%).
export function workload(role, { big, sinceIso }) {
  const orders = ['get_orders_list', { p_limit: 20, p_offset: 0 }];
  const summary = ['get_customer_invoice_summary', { p_customer_uuid: big, p_from_date: null, p_to_date: null, p_financial_year: null }];
  if (role === 'customer') return [['get_orders_list', { p_customer_id: big, p_limit: 20, p_offset: 0 }], summary];
  return [
    orders,
    ['get_dispatch_list_with_items', { p_page: 1, p_limit: 20 }],
    ['get_grn_list', { p_limit: 20, p_offset: 0 }],
    ['get_invoices_list', { p_limit: 20, p_offset: 0 }],
    ['get_sensor_polling_data', { p_since_timestamp: sinceIso }],
    summary,
  ];
}

async function main() {
  const { operatorFixture } = await import('./operator-fixture.mjs');
  const config = settings();
  const { env, base, anon } = operatorFixture();
  const sql = query => {
    const result = spawnSync('docker', ['exec', '-i', '-e', `PGPASSWORD=${env.POSTGRES_PASSWORD}`, `${env.WAREHOUSE_PROJECT_NAME}-db-1`,
      'psql', '-X', '-qAt', '-U', 'supabase_admin', '-d', 'postgres', '-v', 'ON_ERROR_STOP=1'], { input: query + '\n', encoding: 'utf8', timeout: 60000 });
    assert.equal(result.status, 0, `fixture SQL failed: ${result.stderr?.slice(-400)}`);
    return result.stdout.trim();
  };
  const quote = value => `'${String(value).replaceAll("'", "''")}'`;
  const queryJson = query => JSON.parse(sql(`SELECT (${query})::text;`));
  async function rpc(name, token, body) {
    const response = await fetch(`${base}/rest/v1/rpc/${name}`, { method: 'POST', body: JSON.stringify(body),
      headers: { apikey: anon, Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' }, signal: AbortSignal.timeout(REQUEST_TIMEOUT_MS) });
    const data = await response.json().catch(() => null);
    return { ok: response.ok && data?.success !== false, status: response.status, data };
  }
  async function login(phone, name) {
    let prepared = queryJson(`public.operator_prepare_otp(${quote(phone)})`);
    if (prepared.code === 'resend_cooldown') {
      await new Promise(resolve => setTimeout(resolve, Math.max(0, Date.parse(prepared.retry_at) - Date.now()) + 1000));
      prepared = queryJson(`public.operator_prepare_otp(${quote(phone)})`);
    }
    assert.equal(prepared.success, true, 'fictional challenge prepared');
    assert.equal(queryJson(`public.operator_finish_otp(${quote(prepared.data.request_id)}::uuid,true,'mock-provider-only')`).success, true);
    const verified = queryJson(`public.operator_verify_otp(${quote(phone)},${quote(prepared.data.otp_code)},${quote(name)})`);
    assert.equal(verified.success, true, 'fictional login verified');
    return verified.data;
  }

  const big = sql("SELECT id FROM public.customers WHERE name = 'Seed Customer 1'");
  assert.match(big, /^[0-9a-f-]{36}$/, 'the scale seed is loaded (tests/seed/make-seed.mjs --years N)');
  // One signed-in user of each role. The administrator exists since the install; a staff member and a customer sign in as a pending
  // request and the administrator approves them (the way the operator-api tests do it).
  const admin = await login(config.adminPhone, 'Core Demo Administrator');
  assert.equal(admin.action, 'login', 'the installation administrator signs in');
  const adminToken = admin.session.access_token;
  const people = [['staff', '919888888881', 'Scale Staff'], ['customer', '919888888882', 'Scale Customer']];
  const users = [{ role: 'admin', token: adminToken }];
  for (const [role, phone, name] of people) {
    const pending = await login(phone, name);
    if (pending.action === 'pending') {
      const profile = sql(`SELECT id FROM public.user_profiles WHERE mobile = ${quote(phone)}`);
      const decision = await rpc('operator_review_enrollment', adminToken, { p_user_id: profile, p_decision: 'approved', p_role: role, p_customer_ids: role === 'customer' ? [big] : [] });
      assert.equal(decision.data?.success, true, `${role} approved`);
    }
  }
  // The second sign-in of a number waits out the one-minute resend cooldown of the first (login() does).
  for (const [role, phone, name] of people) users.push({ role, token: (await login(phone, name)).session.access_token });

  const sinceIso = () => new Date(Date.now() - 3600 * 1000).toISOString();
  const samples = {};
  const note = name => (samples[name] ??= { durations: [], errors: 0 });
  // Warm-up: one call of every RPC per role (plans, caches), not measured; a refusal here is a setup fault.
  for (const user of users) for (const [name, body] of workload(user.role, { big, sinceIso: sinceIso() })) {
    const answer = await rpc(name, user.token, body);
    assert.ok(answer.ok, `${user.role} ${name} answered HTTP ${answer.status}: ${JSON.stringify(answer.data)?.slice(0, 200)}`);
  }

  const deadline = performance.now() + config.seconds * 1000;
  async function worker(index) {
    const user = users[index % users.length];
    for (let turn = index; performance.now() < deadline; turn += 1) {
      const calls = workload(user.role, { big, sinceIso: sinceIso() });
      const [name, body] = calls[turn % calls.length];
      const start = performance.now();
      let good = false;
      try { good = (await rpc(name, user.token, body)).ok; } catch { good = false; }
      const took = performance.now() - start;
      if (good) note(name).durations.push(took); else note(name).errors += 1;
    }
  }
  await Promise.all(Array.from({ length: config.workers }, (_, i) => worker(i)));

  const summary = summarise(samples);
  writeFileSync(config.output, JSON.stringify({ seconds: config.seconds, workers: config.workers, p95LimitMs: config.limitMs, enforced: config.enforce, rpcs: summary }, null, 2) + '\n');
  for (const [name, row] of Object.entries(summary)) console.log(`${name}: ${row.calls} calls, p50 ${row.p50} ms, p95 ${row.p95} ms, max ${row.max} ms, errors ${row.errors}`);
  const verdict = evaluate(summary, config);
  for (const line of verdict.warnings) console.log(`::warning title=Scale check::${line}`);
  if (verdict.failures.length) throw new Error(`Scale check failed:\n${verdict.failures.join('\n')}`);
  console.log(`Scale check done${verdict.warnings.length ? ' with warnings' : ''}.`);
}

if (isMain(import.meta.url)) await main();
