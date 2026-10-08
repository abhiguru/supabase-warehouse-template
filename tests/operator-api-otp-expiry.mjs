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
// Backend-only natural five-minute OTP expiry; not Android refresh-session expiry.
const phone='919888888879';
const quota=()=>sql(`COALESCE((SELECT jsonb_build_object('hourly',hourly_count,'daily',daily_count,'hourReset',last_reset_hour,'dayReset',last_reset_day) FROM public.otp_rate_limits WHERE phone_number=${quote(phone)}),'null'::jsonb)`);
const before=quota();assert.ok(before && before.daily<=15,'ordinary daily budget for at most five challenges');
const hourAge=Date.now()-Date.parse(before.hourReset);
assert.ok(hourAge>=3600000 || hourAge<=2700000,'at least fifteen minutes remain in current ordinary hourly window');
const prepared=sql(`public.operator_prepare_otp(${quote(phone)})`);assert.equal(prepared.success,true,'ordinary random challenge');
assert.equal(sql(`public.operator_finish_otp(${quote(prepared.data.request_id)}::uuid,true,'mock-provider-only')`).success,true);
const issued=quota();
const cooldown=sql(`public.operator_prepare_otp(${quote(phone)})`);assert.equal(cooldown.success,false);assert.equal(cooldown.code,'resend_cooldown');assert.deepEqual(quota(),issued,'cooldown consumes no new challenge');
const deadline=Date.parse(prepared.data.expires_at)+1000;
assert.ok(deadline>Date.now() && deadline-Date.now()<=305000,'actual normal five-minute expiry');
while(Date.now()<deadline) await new Promise(resolve=>setTimeout(resolve,Math.min(30000,deadline-Date.now())));
const expiredBeforeVerify=sql(`(SELECT jsonb_build_object('expired',expires_at<=now(),'verified',verified,'attempts',attempts) FROM public.otp_verifications WHERE id=${quote(prepared.data.request_id)}::uuid)`);
assert.equal(expiredBeforeVerify.expired,true);assert.equal(expiredBeforeVerify.verified,false);assert.equal(expiredBeforeVerify.attempts,0);
const verified=sql(`public.operator_verify_otp(${quote(phone)},${quote(prepared.data.otp_code)})`);
assert.equal(verified.success,false);assert.equal(verified.code,'invalid_otp');assert.ok(!verified.data?.session);
let challenges=1;
while(quota().hourly<5) {
 let c=sql(`public.operator_prepare_otp(${quote(phone)})`);
 if(c.code==='resend_cooldown') {
  const wait=Date.parse(c.retry_at)-Date.now()+1000;assert.ok(wait>0&&wait<=65000);
  await new Promise(resolve=>setTimeout(resolve,wait));c=sql(`public.operator_prepare_otp(${quote(phone)})`);
 }
 assert.equal(c.success,true);assert.equal(sql(`public.operator_finish_otp(${quote(c.data.request_id)}::uuid,true,'mock-provider-only')`).success,true);
 challenges++;assert.ok(challenges<=5,'finite normal challenge budget');
}
const beforeLimit=quota();assert.equal(beforeLimit.hourly,5);
const limit=sql(`public.operator_prepare_otp(${quote(phone)})`);assert.equal(limit.success,false);assert.equal(limit.code,'rate_limited');assert.deepEqual(quota(),beforeLimit,'rate rejection consumes no new challenge');
const proof={status:'PASS',scope:'backend-natural-OTP-expiry-cooldown-hourly-limit',actualServerExpiry:prepared.data.expires_at,expiredBeforeVerify,challengeCount:challenges,quotasBefore:before,quotasAfter:quota(),externalDeliveries:0,quotaResets:0,manualTimestampChanges:false,sessionsIssued:0,AndroidRefreshExpiryAcceptance:false};
writeFileSync(resolve(evidenceRoot,'otp-natural-expiry-proof01.json'),JSON.stringify(proof,null,2)+'\n',{flag:'wx',mode:0o400});console.log(JSON.stringify({status:proof.status,scope:proof.scope,challengeCount:challenges}));
