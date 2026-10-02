// Private mock-delivery bridge for the guarded fictional fixture only.
// Never attach this harness to an installed warehouse or expose its listener.
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { pathToFileURL } from 'node:url';
import { createServer as httpsServer } from 'node:https';
import { createServer as socketServer } from 'node:net';
import { readFileSync, lstatSync, realpathSync, chmodSync, existsSync, unlinkSync } from 'node:fs';
import { dirname, resolve, isAbsolute } from 'node:path';
import { spawnSync } from 'node:child_process';
import { operatorFixture } from '../tests/operator-fixture.mjs';
import { dispatchConcurrencyDelayMilliseconds } from './fixture-dispatch-concurrency-delay.mjs';
import { fixturePhones } from './fixture-phone-scope.mjs';
import { proxyFixtureRequest, proxyFixtureUpgrade } from './fixture-http-proxy.mjs';

let owningFixture = operatorFixture;
const owningCheckout = process.env.WAREHOUSE_FIXTURE_OWNING_CHECKOUT;
if (owningCheckout !== undefined) {
  assert.ok(isAbsolute(owningCheckout) && realpathSync(owningCheckout) === resolve(owningCheckout));
  const guard = resolve(owningCheckout,'tests/operator-fixture.mjs');
  const st = lstatSync(guard); assert.ok(st.isFile() && !st.isSymbolicLink() && st.uid === process.getuid());
  assert.equal(createHash('sha256').update(readFileSync(guard)).digest('hex'),process.env.WAREHOUSE_FIXTURE_OWNER_GUARD_SHA256);
  owningFixture = (await import(pathToFileURL(guard).href)).operatorFixture;
}
const { env, base } = owningFixture(); // Original owning checkout guard and Compose labels remain intact.
const ordersReadDelayMs=process.env.WAREHOUSE_FIXTURE_ORDERS_READ_DELAY_MS===undefined?0:Number(process.env.WAREHOUSE_FIXTURE_ORDERS_READ_DELAY_MS);
assert.ok(Number.isInteger(ordersReadDelayMs)&&(ordersReadDelayMs===0||ordersReadDelayMs>=500&&ordersReadDelayMs<=5000));
if(ordersReadDelayMs)assert.equal(base,'http://127.0.0.1:18080','Orders delay only on original fictional primary');
const dispatchConcurrency=process.env.WAREHOUSE_FIXTURE_DISPATCH_CONCURRENCY===undefined?{milliseconds:0}:JSON.parse(process.env.WAREHOUSE_FIXTURE_DISPATCH_CONCURRENCY);
dispatchConcurrencyDelayMilliseconds({},{},null,dispatchConcurrency);
if(dispatchConcurrency.milliseconds){assert.equal(base,'http://127.0.0.1:18080');assert.equal(ordersReadDelayMs,0);assert.notEqual(process.env.WAREHOUSE_FIXTURE_REPLACEMENT_AUTH,'true');}
const observeAuthenticationPresence = process.env.WAREHOUSE_FIXTURE_OBSERVE_AUTH_PRESENCE === 'true';
const tlsDir = process.env.WAREHOUSE_FIXTURE_TLS_DIR;
const socketPath = process.env.WAREHOUSE_FIXTURE_SOCKET;
assert.ok(tlsDir && socketPath && isAbsolute(tlsDir) && isAbsolute(socketPath));
for (const dir of [tlsDir, dirname(socketPath)]) {
  const st = lstatSync(dir);
  assert.ok(st.isDirectory() && st.uid === process.getuid() && (st.mode & 0o077) === 0);
  assert.equal(realpathSync(dir), resolve(dir));
}
assert.ok(!existsSync(socketPath), 'Refusing to replace an occupied fixture socket');
const keyPath = resolve(tlsDir, 'fixture-key.pem');
const st = lstatSync(keyPath);
assert.ok(st.isFile() && !st.isSymbolicLink() && st.uid === process.getuid() && (st.mode & 0o077) === 0);

const challenges = new Map(); // Plaintext exists only in harness memory, never logs/HTTP.
const upstreamOrigin = new URL(base).origin;
const fixtureTarget = path => {
  if (typeof path !== 'string' || !path.startsWith('/') || path.startsWith('//')) return null;
  try {
    const url = new URL(path, base);
    return url.origin === upstreamOrigin ? url : null;
  } catch { return null; }
};
const query = expression => {
  const result = spawnSync('docker', ['exec', '-i', '-e', `PGPASSWORD=${env.POSTGRES_PASSWORD}`,
    `${env.WAREHOUSE_PROJECT_NAME}-db-1`, 'psql', '-X', '-qAt', '-U', 'supabase_admin',
    '-d', 'postgres', '-v', 'ON_ERROR_STOP=1'], {
    input: `SELECT (${expression})::text;\n`, encoding: 'utf8', timeout: 30000,
  });
  assert.equal(result.status, 0, 'Private fixture SQL failed; payload not logged');
  return JSON.parse(result.stdout.trim());
};
const replacementAuthentication = process.env.WAREHOUSE_FIXTURE_REPLACEMENT_AUTH === 'true';
if (process.env.WAREHOUSE_FIXTURE_REPLACEMENT_AUTH !== undefined)
  assert.ok(['true','false'].includes(process.env.WAREHOUSE_FIXTURE_REPLACEMENT_AUTH));
const phoneProof = replacementAuthentication ? query(`json_build_object(
  'primaryAdminPresent',EXISTS(SELECT 1 FROM public.user_profiles WHERE mobile='919888888871'),
  'replacementAdminPresent',EXISTS(SELECT 1 FROM public.user_profiles WHERE mobile='919888888891' AND role='admin' AND active AND name='Replacement Demo Administrator'))`) : {};
const allowedPhones = fixturePhones(replacementAuthentication,phoneProof);
const quote = value => `'${String(value).replaceAll("'", "''")}'`;
const json = (response, status, body) => {
  response.writeHead(status, { 'content-type': 'application/json', 'cache-control': 'no-store' });
  response.end(JSON.stringify(body));
};
const server = httpsServer({ key: readFileSync(keyPath), cert: readFileSync(resolve(tlsDir, 'fixture-ca.pem')) }, async (req, res) => {
  const target = fixtureTarget(req.url);
  if (!target) return json(res, 400, { success: false, message: 'Only owned fixture upstream allowed' });
  if (req.method === 'POST' && req.url === '/functions/v1/operator-otp/request') {
    try {
      let body = '';
      for await (const part of req) { body += part; assert.ok(body.length <= 4096); }
      let phone = String(JSON.parse(body).phone_number || '');
      if (/^\d{10}$/.test(phone)) phone = `91${phone}`;
      assert.ok(allowedPhones.has(phone), 'Only fictional fixture phones allowed');
      const prepared = query(`public.operator_prepare_otp(${quote(phone)})`);
      if (!prepared.success) return json(res, 429, prepared);
      const finished = query(`public.operator_finish_otp(${quote(prepared.data.request_id)}::uuid,true,'mock-provider-only')`);
      assert.equal(finished.success, true);
      challenges.set(phone, { code: prepared.data.otp_code, expiresAt: Date.parse(prepared.data.expires_at) });
      return json(res, 200, { success: true, data: { request_id: prepared.data.request_id,
        expires_at: prepared.data.expires_at }, message: 'Fixture mock delivery accepted' });
    } catch { return json(res, 400, { success: false, message: 'Fixture challenge failed' }); }
  }
  proxyFixtureRequest(req, res, target, { ordersReadDelayMs, dispatchConcurrency, observeAuthenticationPresence, observe: event => console.log(JSON.stringify(event)) });
});
server.on('upgrade', (req, client, head) => {
  const target = fixtureTarget(req.url);
  if (!target) { client.end('HTTP/1.1 400 Bad Request\r\nConnection: close\r\n\r\n'); return; }
  proxyFixtureUpgrade(req, client, head, target, { observeAuthenticationPresence, observe: event => console.log(JSON.stringify(event)) });
});
const ipc = socketServer(client => {
  let buffer = ''; client.setTimeout(5000, () => client.destroy());
  client.on('error', () => {});
  client.on('data', part => {
    buffer += part; if (buffer.length > 256) return client.destroy();
    if (!buffer.includes('\n')) return;
    try {
      const phone = JSON.parse(buffer.trim()).phone;
      const item = allowedPhones.has(phone) && challenges.get(phone);
      assert.ok(item && item.expiresAt > Date.now());
      client.end(JSON.stringify({ code: item.code }) + '\n');
    } catch { client.end('{"error":"no pending fixture challenge"}\n'); }
  });
});
server.listen(18443, '127.0.0.1', () => console.log('Guarded fixture HTTPS bridge ready on loopback; no SMS worker invoked.'));
ipc.listen(socketPath, () => chmodSync(socketPath, 0o600));
let socketInode;
ipc.on('listening', () => { socketInode = lstatSync(socketPath).ino; });
const stop = () => {
  server.close(); ipc.close();
  if (socketInode && existsSync(socketPath) && lstatSync(socketPath).ino === socketInode) unlinkSync(socketPath);
  process.exit(0);
};
process.on('SIGINT', stop); process.on('SIGTERM', stop);
