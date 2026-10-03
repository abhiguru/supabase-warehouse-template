// Separate mock-delivery bridge for the strictly guarded switching fixture only.
// Never attach this harness to an installed warehouse or expose its listener.
import assert from 'node:assert/strict';
import { createServer as httpsServer } from 'node:https';
import { proxyFixtureRequest, proxyFixtureUpgrade } from './fixture-http-proxy.mjs';
import { createServer as socketServer } from 'node:net';
import { readFileSync, lstatSync, realpathSync, chmodSync, existsSync, unlinkSync } from 'node:fs';
import { dirname, resolve, isAbsolute } from 'node:path';
import { spawnSync } from 'node:child_process';
import { switchingFixture } from './switch-fixture-common.mjs';
import { X509Certificate,createHash } from 'node:crypto';
import {pathToFileURL} from 'node:url';

process.umask(0o077);
try {
const observeAuthenticationPresence=process.env.WAREHOUSE_FIXTURE_OBSERVE_AUTH_PRESENCE==='true';
const discoveryDelayMs=process.env.WAREHOUSE_SWITCH_FIXTURE_DISCOVERY_DELAY_MS===undefined?0:Number(process.env.WAREHOUSE_SWITCH_FIXTURE_DISCOVERY_DELAY_MS);
assert.ok(Number.isInteger(discoveryDelayMs)&&(discoveryDelayMs===0||discoveryDelayMs>=500&&discoveryDelayMs<=5000),'Bounded fictional discovery delay required');
let owningFixture=switchingFixture;
const owningCheckout=process.env.WAREHOUSE_FIXTURE_OWNING_CHECKOUT;
if(owningCheckout!==undefined){
  assert.ok(isAbsolute(owningCheckout)&&realpathSync(owningCheckout)===resolve(owningCheckout));
  const guard=resolve(owningCheckout,'scripts/switch-fixture-common.mjs');
  const st=lstatSync(guard);assert.ok(st.isFile()&&!st.isSymbolicLink()&&st.uid===process.getuid());
  assert.equal(createHash('sha256').update(readFileSync(guard)).digest('hex'),process.env.WAREHOUSE_FIXTURE_OWNER_GUARD_SHA256);
  owningFixture=(await import(pathToFileURL(guard).href)).switchingFixture;
}
const { env, base } = owningFixture(); // Original owning checkout/container/data guards remain unchanged.
const tlsDir = process.env.WAREHOUSE_SWITCH_FIXTURE_TLS_DIR;
const socketPath = process.env.WAREHOUSE_SWITCH_FIXTURE_SOCKET;
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
const allowedPhones = new Set(['919888888881', '919888888882', '919888888883', '919888888884']);
const certPath = resolve(tlsDir, 'fixture-ca.pem');
const certStat = lstatSync(certPath);
assert.ok(certStat.isFile() && !certStat.isSymbolicLink() && certStat.uid === process.getuid() && (certStat.mode & 0o077) === 0);
const cert = readFileSync(certPath), ca = new X509Certificate(cert);
assert.ok(ca.ca && ca.checkHost('backend-switch.example.test') === 'backend-switch.example.test');
assert.ok(Date.parse(ca.validFrom) <= Date.now() && Date.parse(ca.validTo) > Date.now());
const challenges = new Map(); // Plaintext exists only in harness memory, never logs/HTTP.
const upstreamOrigin = new URL(base).origin;
const fixtureTarget = path => {
  if (typeof path !== 'string' || !path.startsWith('/') || path.startsWith('//') || path.includes('\\')) return null;
  try {
    const url = new URL(path, base);
    return url.origin === upstreamOrigin ? url : null;
  } catch { return null; }
};
const query = expression => {
  const result = spawnSync('docker', ['exec', '-i', '-e', 'PGPASSWORD',
    `${env.WAREHOUSE_PROJECT_NAME}-db-1`, 'psql', '-X', '-qAt', '-U', 'supabase_admin',
    '-d', 'postgres', '-v', 'ON_ERROR_STOP=1'], {
    input: `SELECT (${expression})::text;\n`, env: { ...process.env, PGPASSWORD: env.POSTGRES_PASSWORD }, encoding: 'utf8', timeout: 30000,
  });
  assert.equal(result.status, 0, 'Private fixture SQL failed; payload not logged');
  return JSON.parse(result.stdout.trim());
};
const quote = value => `'${String(value).replaceAll("'", "''")}'`;
const json = (response, status, body) => {
  response.writeHead(status, { 'content-type': 'application/json', 'cache-control': 'no-store' });
  response.end(JSON.stringify(body));
};
const server = httpsServer({ key: readFileSync(keyPath), cert }, async (req, res) => {
  const target = fixtureTarget(req.url);
  if (!target) return json(res, 400, { success: false, message: 'Only owned fixture upstream allowed' });
  if (target.pathname === '/functions/v1/operator-otp/request') {
    if (req.method !== 'POST') return json(res, 405, { success: false, message: 'POST required for fixture mock delivery' });
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
  proxyFixtureRequest(req, res, target, { discoveryDelayMs, observeAuthenticationPresence, observe: event => console.log(JSON.stringify(event)) });
});
server.on('upgrade', (req, client, head) => {
  const target = fixtureTarget(req.url);
  if (!target) { client.end('HTTP/1.1 400 Bad Request\r\nConnection: close\r\n\r\n'); return; }
  proxyFixtureUpgrade(req, client, head, target, {observeAuthenticationPresence,observe:event=>console.log(JSON.stringify(event))});
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
server.on('error', () => { console.error('Switching fixture listener unavailable; no private input logged.'); stop(1); });
ipc.on('error', () => { console.error('Switching fixture IPC unavailable; no private input logged.'); stop(1); });
server.listen(18444, '127.0.0.1', () => console.log('Separate switching fixture HTTPS bridge ready on loopback; no SMS worker invoked.'));
ipc.listen(socketPath, () => chmodSync(socketPath, 0o600));
let socketInode;
ipc.on('listening', () => { socketInode = lstatSync(socketPath).ino; });
const stop = (code = 0) => {
  server.close(); ipc.close();
  if (socketInode && existsSync(socketPath) && lstatSync(socketPath).ino === socketInode) unlinkSync(socketPath);
  process.exit(code);
};
process.on('SIGINT', () => stop()); process.on('SIGTERM', () => stop());
} catch {
  console.error('Switching fixture guard refused startup; inspect protected state locally.');
  process.exitCode = 1;
}
