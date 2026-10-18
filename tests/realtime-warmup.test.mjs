import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { joinOnce, warmUp } from '../scripts/realtime-warmup.mjs';

const read = path => readFileSync(new URL(`../${path}`, import.meta.url), 'utf8');

// A WebSocket stand-in: records what is sent and answers the join as scripted.
function fakeSocket(script) {
  return class {
    static urls = []; static sent = [];
    constructor(url) { this.listeners = {}; this.constructor.urls.push(url); queueMicrotask(() => script(this)); }
    addEventListener(name, fn) { (this.listeners[name] ??= []).push(fn); }
    emit(name, event = {}) { for (const fn of this.listeners[name] ?? []) fn(event); }
    send(text) { this.constructor.sent.push(JSON.parse(text)); }
    close() {}
  };
}

test('the warm-up joins one channel through the loopback gateway with the anon key and reports ok', async () => {
  const Socket = fakeSocket(socket => { socket.emit('open'); socket.emit('message', { data: JSON.stringify({ ref: '1', event: 'phx_reply', payload: { status: 'ok' } }) }); });
  const result = await joinOnce({ port: 18460, anonKey: 'anon.key.value', WebSocketImpl: Socket });
  assert.equal(result.ok, true);
  assert.match(Socket.urls[0], /^ws:\/\/127\.0\.0\.1:18460\/realtime\/v1\/websocket\?apikey=anon\.key\.value&vsn=1\.0\.0$/);
  assert.equal(Socket.sent.length, 1);
  assert.equal(Socket.sent[0].event, 'phx_join');
  assert.equal(Socket.sent[0].payload.access_token, 'anon.key.value');
});

test('the warm-up retries and reports a failure without throwing', async () => {
  let calls = 0;
  const Socket = fakeSocket(socket => { calls += 1; socket.emit('error'); });
  const result = await warmUp({ KONG_HTTP_PORT: '18460', ANON_KEY: 'a.b.c' }, { attempts: 3, pauseMs: 1, WebSocketImpl: Socket });
  assert.equal(result.ok, false);
  assert.equal(result.reason, 'connect');
  assert.equal(calls, 3);
  const timedOut = await joinOnce({ port: 18460, anonKey: 'a.b.c', timeoutMs: 20, WebSocketImpl: fakeSocket(() => {}) });
  assert.deepEqual([timedOut.ok, timedOut.reason], [false, 'timeout']);
});

test('setup.sh and start.sh run the warm-up after the services are up and before the local doctor', () => {
  for (const file of ['setup.sh', 'start.sh']) {
    const text = read(file);
    const up = text.lastIndexOf('compose.sh" up -d --wait --wait-timeout 180\n');
    const warm = text.indexOf('node "$ROOT/scripts/realtime-warmup.mjs"');
    const doctor = text.indexOf('node "$ROOT/scripts/doctor.mjs" --local');
    assert.ok(up > 0 && warm > up && doctor > warm, `${file}: order up -> warm-up -> doctor`);
  }
});

// The real Node WebSocket dispatches `error` synchronously from close() while still connecting, so a
// stand-in socket cannot show re-entry. These use the real one (review of 80bfea3, finding 1).
import { createServer as createHttp } from 'node:http';
import { createServer as createTcp } from 'node:net';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, mkdirSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

const listen = server => new Promise(resolve => server.listen(0, '127.0.0.1', () => resolve(server.address().port)));
const closedPort = async () => { const s = createTcp(); const p = await listen(s); await new Promise(r => s.close(r)); return p; };

test('a refused port gives one resolution with reason connect, no recursion', async () => {
  const port = await closedPort();
  const result = await joinOnce({ port, anonKey: 'a.b.c', timeoutMs: 3000 });
  assert.deepEqual([result.ok, result.reason], [false, 'connect']);
});

test('an HTTP 401 answer to the upgrade gives reason connect, and a silent server gives reason timeout', async () => {
  const http = createHttp((req, res) => { res.writeHead(401); res.end(); });
  http.on('upgrade', (req, socket) => { socket.end('HTTP/1.1 401 Unauthorized\r\nContent-Length: 0\r\n\r\n'); });
  const httpPort = await listen(http);
  const silent = createTcp(() => {});
  const silentPort = await listen(silent);
  try {
    const refused = await joinOnce({ port: httpPort, anonKey: 'a.b.c', timeoutMs: 3000 });
    assert.deepEqual([refused.ok, refused.reason], [false, 'connect']);
    const timedOut = await joinOnce({ port: silentPort, anonKey: 'a.b.c', timeoutMs: 300 });
    assert.deepEqual([timedOut.ok, timedOut.reason], [false, 'timeout']);
  } finally { http.close(); silent.close(); silent.closeAllConnections?.(); http.closeAllConnections?.(); }
});

test('the script run against a closed port exits 0 with one warning and no stack overflow or key in its output', async () => {
  const port = await closedPort();
  const scratch = mkdtempSync(join(tmpdir(), 'warehouse-warmup-'));
  try {
    mkdirSync(join(scratch, 'config'));
    writeFileSync(join(scratch, 'config/compose.env'), `KONG_HTTP_PORT=${port}\nANON_KEY=secret.anon.keyvalue\n`, { mode: 0o600 });
    const run = spawnSync(process.execPath, [new URL('../scripts/realtime-warmup.mjs', import.meta.url).pathname],
      { encoding: 'utf8', env: { ...process.env, WAREHOUSE_STATE_DIR: scratch, WAREHOUSE_WARMUP_PAUSE_MS: '10' }, timeout: 60000 });
    assert.equal(run.status, 0, run.stderr);
    const output = run.stdout + run.stderr;
    assert.doesNotMatch(output, /Maximum call stack|RangeError/);
    assert.doesNotMatch(output, /secret\.anon\.keyvalue/);
    assert.equal(run.stderr.trim().split('\n').length, 1, run.stderr);
    assert.match(run.stderr, /^Warning: the Realtime warm-up join failed \(connect\)/);
    // A missing configuration also ends in the warning and exit 0.
    const missing = spawnSync(process.execPath, [new URL('../scripts/realtime-warmup.mjs', import.meta.url).pathname],
      { encoding: 'utf8', env: { ...process.env, WAREHOUSE_STATE_DIR: join(scratch, 'none') } });
    assert.equal(missing.status, 0);
    assert.match(missing.stderr, /^Warning: the Realtime warm-up/);
  } finally { rmSync(scratch, { recursive: true, force: true }); }
});
