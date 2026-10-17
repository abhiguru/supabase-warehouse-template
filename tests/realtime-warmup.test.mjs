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
  const result = await warmUp({ KONG_HTTP_PORT: '18460', ANON_KEY: 'a.b.c' }, { attempts: 3, WebSocketImpl: Socket });
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
