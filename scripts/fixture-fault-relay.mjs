// Optional transport-failure control for the owned fictional fixture only.
// Normal installation/startup never loads this module.
import assert from 'node:assert/strict';
import { createServer as httpsServer, request as httpsRequest } from 'node:https';
import { createServer as socketServer } from 'node:net';
import { X509Certificate } from 'node:crypto';
import { readFileSync, lstatSync, realpathSync, existsSync, chmodSync, unlinkSync } from 'node:fs';
import { resolve, dirname, isAbsolute } from 'node:path';
import { operatorFixture } from '../tests/operator-fixture.mjs';
import { isMain } from './is-main.mjs';

const paths = new Set(['/rest/v1/rpc/save_grn', '/rest/v1/rpc/create_dispatch_with_stock_check']);
export function fixtureTarget(path, base) {
  if (typeof path !== 'string' || !path.startsWith('/') || path.startsWith('//') || path.includes('\\')) return null;
  try { const u = new URL(path, base); return u.origin === new URL(base).origin ? u : null; }
  catch { return null; }
}

export function faultController() {
  let armed = null, result = { state: 'IDLE' };
  let observed = [], overflow = false;
  const resetObservations = () => { observed = []; overflow = false; };
  return {
    control(command) {
      assert.ok(command && typeof command === 'object');
      if (command.action === 'status') return { ...result };
      // Separate from retained first-fault status: these are subsequent requests.
      if (command.action === 'observations') return { observations: observed.map(o => ({ ...o })), overflow };
      if (command.action === 'disarm') {
        assert.notEqual(result.state, 'MATCHED', 'An in-flight fault cannot be cancelled');
        armed = null; resetObservations(); result = { state: 'DISARMED' }; return { ...result };
      }
      assert.equal(command.action, 'arm');
      assert.ok(!armed && result.state !== 'MATCHED', 'A pending fault must not be overwritten');
      assert.ok(['before-upstream', 'after-upstream-success'].includes(command.phase));
      assert.ok(paths.has(command.path));
      assert.ok(Boolean(command.key) !== Boolean(command.record), 'Choose an exact fixture key or reserved fictional document');
      if (command.key) assert.match(command.key, /^(fixture-fault-[a-z0-9-]{1,60}|warehouse-(grn|dispatch)-[a-f0-9]{64})$/);
      else assert.match(command.record, /^FXF[0-9]{2,5}$/);
      armed = { phase: command.phase, path: command.path, ...(command.key ? { key: command.key } : { record: command.record }) };
      resetObservations(); result = { state: 'ARMED', ...armed }; return { ...result };
    },
    take(method, path, body) {
      if (method !== 'POST' || !paths.has(path)) return null;
      let payload; try { payload = JSON.parse(body); } catch { return null; }
      if (!payload || typeof payload !== 'object') return null;
      // Observe only the reserved document selected by this native fault case.
      // No body, headers, phone numbers or arbitrary keys enter the control reply.
      const document = path === '/rest/v1/rpc/save_grn' ? payload.p_gr_no : payload.p_dispatch_data?.disp_no;
      if (!armed && result.record && path === result.path && document === result.record) {
        if (observed.length >= 8) overflow = true;
        else {
          const validKey = new RegExp(`^warehouse-${path === '/rest/v1/rpc/save_grn' ? 'grn' : 'dispatch'}-[a-f0-9]{64}$`).test(payload.p_idempotency_key ?? '');
          observed.push({ sequence: observed.length + 1, path, record: result.record,
            stateWhenObserved: result.state, key: validKey ? payload.p_idempotency_key : null,
            sameKey: validKey && payload.p_idempotency_key === result.key });
        }
      }
      if (!armed || path !== armed.path) return null;
      if (armed.key && payload.p_idempotency_key !== armed.key) return null;
      if (armed.record) {
        const document = path === '/rest/v1/rpc/save_grn' ? payload.p_gr_no : payload.p_dispatch_data?.disp_no;
        if (document !== armed.record || !/^(warehouse-(grn|dispatch)-[a-f0-9]{64}|[a-f0-9]{8}(-[a-f0-9]{4}){3}-[a-f0-9]{12})$/.test(payload.p_idempotency_key ?? '')) return null;
      }
      const fault = { ...armed, key: payload.p_idempotency_key }; armed = null;
      result = { state: 'MATCHED', ...fault }; return fault;
    },
    finish(fault, state) { result = { state, ...fault }; },
  };
}

// Injectable request implementation lets regressions exercise real socket loss
// against a local test HTTP server without bypassing the guarded CLI entrypoint.
export function relayHandler({ base, controller, request = httpsRequest, requestOptions = {}, timeoutMs = 15000 }) {
  return async (req, res) => {
    const target = fixtureTarget(req.url, base);
    if (!target) { res.writeHead(400); res.end('Invalid fixture target'); return; }
    let fault = null;
    try {
      let size = 0; const chunks = [];
      for await (const part of req) {
        size += part.length; assert.ok(size <= 1024 * 1024, 'Fixture request exceeds limit'); chunks.push(part);
      }
      const body = Buffer.concat(chunks);
      fault = controller.take(req.method, req.url, body.toString('utf8'));
      if (fault?.phase === 'before-upstream') {
        controller.finish(fault, 'DROPPED_BEFORE_UPSTREAM'); res.destroy(); return;
      }
      const headers = { ...req.headers, host: 'backend-core.example.test', 'content-length': body.length };
      delete headers['transfer-encoding'];
      const reply = await new Promise((resolveReply, reject) => {
        let upstream;
        const timer = setTimeout(() => upstream?.destroy(new Error('Fixture upstream deadline')), timeoutMs);
        const fail = error => { clearTimeout(timer); reject(error); };
        upstream = request(target, { ...requestOptions, method: req.method, headers }, response => {
          const parts = []; let length = 0;
          response.on('data', part => {
            length += part.length;
            if (length > 2 * 1024 * 1024) { upstream.destroy(new Error('Fixture response exceeds limit')); return; }
            parts.push(part);
          });
          response.on('error', fail);
          response.on('end', () => { clearTimeout(timer); resolveReply({ status: response.statusCode, headers: response.headers, body: Buffer.concat(parts) }); });
        });
        upstream.setTimeout(timeoutMs, () => upstream.destroy(new Error('Fixture upstream timeout')));
        upstream.on('error', fail); upstream.end(body);
      });
      if (fault?.phase === 'after-upstream-success') {
        let success = false; try { success = JSON.parse(reply.body.toString('utf8')).success === true; } catch { /* Not a successful RPC. */ }
        if (reply.status >= 200 && reply.status < 300 && success) {
          // Success is a transport observation. A separate read-only database
          // postcondition must prove commit before an operator calls this PASS.
          controller.finish(fault, 'DROPPED_AFTER_UPSTREAM_SUCCESS'); res.destroy(); return;
        }
        controller.finish(fault, 'NOT_TRIGGERED_UPSTREAM_REJECTED');
      }
      res.writeHead(reply.status, reply.headers); res.end(reply.body);
    } catch {
      if (fault) controller.finish(fault, 'UPSTREAM_OR_REQUEST_FAILED');
      if (!res.headersSent) { res.writeHead(502); res.end('Fixture relay unavailable'); } else res.destroy();
    }
  };
}

function privateDirectory(path) {
  assert.ok(path && isAbsolute(path)); const s = lstatSync(path);
  assert.ok(s.isDirectory() && s.uid === process.getuid() && (s.mode & 0o077) === 0);
  assert.equal(realpathSync(path), resolve(path));
}
function privateFile(path) {
  const s = lstatSync(path);
  assert.ok(s.isFile() && !s.isSymbolicLink() && s.uid === process.getuid() && (s.mode & 0o077) === 0);
  return readFileSync(path);
}
function main() {
  process.umask(0o077);
  operatorFixture(); // Unmodified original identity/provider/Compose guard.
  const tls = process.env.WAREHOUSE_FIXTURE_TLS_DIR;
  const socketPath = process.env.WAREHOUSE_FIXTURE_FAULT_SOCKET;
  privateDirectory(tls); assert.ok(socketPath && isAbsolute(socketPath)); privateDirectory(dirname(socketPath));
  assert.ok(!existsSync(socketPath), 'Refusing to replace an occupied control socket');
  const cert = privateFile(resolve(tls, 'fixture-ca.pem')), key = privateFile(resolve(tls, 'fixture-key.pem'));
  const ca = new X509Certificate(cert);
  assert.equal(ca.checkHost('backend-core.example.test'), 'backend-core.example.test');
  assert.ok(ca.ca && Date.parse(ca.validFrom) <= Date.now() && Date.parse(ca.validTo) > Date.now());
  const controller = faultController();
  const server = httpsServer({ key, cert }, relayHandler({ base: 'https://127.0.0.1:18443', controller,
    requestOptions: { ca: cert, servername: 'backend-core.example.test' } }));
  // Upgrade connections are intentionally excluded from this mutation-only
  // diagnostic. Restore the normal bridge route for Realtime/image/PDF cases.
  server.on('upgrade', (_req, client) => client.end('HTTP/1.1 503 Service Unavailable\r\nConnection: close\r\n\r\n'));
  const ipc = socketServer(client => {
    let buffer = '', handled = false;
    client.setTimeout(5000, () => client.destroy()); client.on('error', () => {});
    client.on('data', part => {
      if (handled) return; buffer += part;
      if (buffer.length > 1024) { client.destroy(); return; }
      if (!buffer.includes('\n')) return; handled = true;
      try { client.end(JSON.stringify(controller.control(JSON.parse(buffer.trim()))) + '\n'); }
      catch { client.end('{"error":"invalid fixture control"}\n'); }
    });
  });
  let inode;
  ipc.on('listening', () => { chmodSync(socketPath, 0o600); inode = lstatSync(socketPath).ino; });
  server.requestTimeout = 15000;
  const stop = (exitCode = 0) => {
    server.close(); ipc.close();
    if (inode && existsSync(socketPath) && lstatSync(socketPath).ino === inode) unlinkSync(socketPath);
    process.exit(exitCode);
  };
  for (const listener of [server, ipc]) listener.on('error', () => { console.error('Fixture fault relay listener failed; no private input logged.'); stop(1); });
  process.on('SIGINT', () => stop()); process.on('SIGTERM', () => stop());
  server.listen(18643, '127.0.0.1', () => {
    ipc.listen(socketPath);
    console.log('Owned fictional fault relay ready on loopback; no provider calls or database writes by relay.');
  });
}
if (isMain(import.meta.url)) main();
