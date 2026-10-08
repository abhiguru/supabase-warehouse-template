// Final backend-only checks against the disposable fictional operator stack.
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { readFileSync, writeFileSync, lstatSync, realpathSync } from 'node:fs';
import { resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { createHash } from 'node:crypto';


assert.ok(process.argv[2], 'explicit private fixture binding required');
let selectedFixture;
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
const phones = ['919888888871','919888888873','919888888879'];
const quotas = sql(`COALESCE((SELECT jsonb_agg(jsonb_build_object('phone',phone_number,'hourly',hourly_count,'daily',daily_count,'hourReset',last_reset_hour,'dayReset',last_reset_day)) FROM public.otp_rate_limits WHERE phone_number IN (${phones.map(quote).join(',')})), '[]'::jsonb)`);
for (const row of quotas) {
  const needed = row.phone.endsWith('879') ? 2 : 1;
  assert.ok(row.daily + needed <= 20, 'ordinary daily quota available');
  assert.ok(Date.parse(row.hourReset) < Date.now()-3600000 || row.hourly + needed <= 5, 'ordinary hourly quota available');
}
assert.equal(sql("(SELECT to_jsonb(enrollment_status) FROM public.user_profiles WHERE mobile='919888888873')"), 'disabled');
assert.equal(sql("(SELECT count(*) FROM public.user_profiles WHERE mobile='919888888879')"), 0, 'reserved new account unused');
async function verify(phone) {
  let c = sql(`public.operator_prepare_otp(${quote(phone)})`);
  if (c.code === 'resend_cooldown') {
    const wait = Date.parse(c.retry_at)-Date.now()+1000;
    assert.ok(wait>0 && wait<=65000);
    await new Promise(resolve=>setTimeout(resolve,wait));
    c=sql(`public.operator_prepare_otp(${quote(phone)})`);
  }
  assert.equal(c.success,true,'normal challenge');
  assert.equal(sql(`public.operator_finish_otp(${quote(c.data.request_id)}::uuid,true,'mock-provider-only')`).success,true);
  const v=sql(`public.operator_verify_otp(${quote(phone)},${quote(c.data.otp_code)},'Fictional rejection acceptance')`);
  const replay=sql(`public.operator_verify_otp(${quote(phone)},${quote(c.data.otp_code)})`);
  assert.equal(replay.success,false);assert.equal(replay.code,'invalid_otp');
  return v;
}
const adminSession = await sessionFor(phones[0]);
const pending=await verify(phones[2]);
assert.equal(pending.success,true);assert.equal(pending.data.action,'pending');assert.ok(!pending.data.session);
const profile=sql("(SELECT to_jsonb(id) FROM public.user_profiles WHERE mobile='919888888879')");
success(await rpc('operator_review_enrollment',adminSession.access_token,{p_user_id:profile,p_decision:'rejected',p_customer_ids:[]}),'normal administrator rejection');
const disabled=await verify(phones[1]);
assert.equal(disabled.success,false);assert.equal(disabled.code,'account_unavailable');assert.ok(!disabled.data?.session);
const rejected=await verify(phones[2]);
assert.equal(rejected.success,false);assert.equal(rejected.code,'account_unavailable');assert.ok(!rejected.data?.session);
assert.equal((await rpc('logout_session',anon,{p_refresh_token:adminSession.refresh_token})).data,true);
const result={status:'PASS',scope:'fresh-backend-normal-pending-rejected-disabled-and-otp-replay',quotasBefore:quotas,normalLogout:true,otpChallenges:4,providerDeliveries:0,quotaResets:0,timestampChanges:0};
writeFileSync(resolve(evidenceRoot,'auth-states-proof01.json'),JSON.stringify(result,null,2)+'\n',{flag:'wx',mode:0o400});
console.log(JSON.stringify({status:result.status,scope:result.scope,otpChallenges:4}));
