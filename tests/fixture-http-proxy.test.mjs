import test from 'node:test';
import assert from 'node:assert/strict';
import { createServer, request } from 'node:http';
import { proxyFixtureRequest, proxyFixtureUpgrade } from '../scripts/fixture-http-proxy.mjs';
import { WebSocket, WebSocketServer } from 'ws';

async function listen(server) {
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  return `http://127.0.0.1:${server.address().port}`;
}
async function close(server) { server.closeAllConnections(); await new Promise(resolve => server.close(resolve)); }
function fetchResult(url) {
  return new Promise((resolve, reject) => {
    const q = request(url, response => {
      const parts = [];
      response.on('data', part => parts.push(part));
      response.on('end', () => resolve({ status: response.statusCode, body: Buffer.concat(parts).toString() }));
      response.on('error', reject); response.on('aborted', () => reject(new Error('aborted response')));
    });
    q.on('error', reject); q.end();
  });
}
test('forwarding remains bounded for a stalled response and records no private query values', async () => {
  const upstream = createServer((_q, _s) => {}), observed = [];
  const base = await listen(upstream);
  const bridge = createServer((req, res) => proxyFixtureRequest(req, res, new URL('/rest/v1/rpc/get_orders_list?apikey=private-token', base),
    { timeoutMs: 80, observe: x => observed.push(x) }));
  const url = await listen(bridge);
  try {
    const response = await fetchResult(url);
    assert.equal(response.status, 504);
    assert.equal(observed.length, 1);
    assert.equal(observed[0].event, 'upstream-timeout');
    assert.ok(!JSON.stringify(observed).includes('private-token'));
  } finally { await close(bridge); await close(upstream); }
});
test('connection refusal returns an explicit unavailable response and bridge stays alive', async () => {
  const upstream = createServer(); const base = await listen(upstream); await close(upstream);
  const bridge = createServer((req, res) => proxyFixtureRequest(req, res, new URL('/private-document', base)));
  const url = await listen(bridge);
  try { for (let n = 0; n < 2; n++) assert.equal((await fetchResult(url)).status, 502); }
  finally { await close(bridge); }
});
test('a truncated upstream response fails without an unhandled process error; later request succeeds', async () => {
  let broken = true; const observed = [];
  const upstream = createServer((_q, res) => {
    if (broken) { res.writeHead(200, { 'content-length': 99 }); res.write('partial'); setTimeout(() => res.destroy(), 10); }
    else res.end('complete');
  });
  const base = await listen(upstream);
  const bridge = createServer((req, res) => proxyFixtureRequest(req, res, new URL('/rest/v1/rpc/get_orders_list', base), { observe: x => observed.push(x) }));
  const url = await listen(bridge);
  try {
    await assert.rejects(fetchResult(url));
    broken = false;
    assert.equal((await fetchResult(url)).body, 'complete');
    assert.ok(observed.some(x => x.event === 'upstream-response-aborted' || x.event === 'upstream-response-error'));
  } finally { await close(bridge); await close(upstream); }
});
test('client cancellation releases a stalled upstream without killing the bridge', async () => {
  const upstream = createServer((_q, _s) => {}); const base = await listen(upstream); const observed = [];
  const bridge = createServer((req, res) => proxyFixtureRequest(req, res, new URL('/rest/v1/rpc/get_orders_list', base), { timeoutMs: 200, observe: x => observed.push(x) }));
  const url = await listen(bridge);
  try {
    await new Promise(resolve => {
      const q = request(url); q.on('error', resolve); q.end(); setTimeout(() => q.destroy(), 40);
    });
    await new Promise(resolve => setTimeout(resolve, 30));
    assert.ok(observed.some(x => x.event === 'client-response-closed' || x.event === 'client-request-aborted'));
    assert.equal(bridge.listening, true);
  } finally { await close(bridge); await close(upstream); }
});

test('WebSocket forwarding survives client disconnect and carries a genuine upstream reply', async () => {
  const upstream = createServer(); const ws = new WebSocketServer({ server: upstream });
  ws.on('connection', socket => socket.on('message', data => socket.send(data)));
  const base = await listen(upstream); const bridge = createServer();
  bridge.on('upgrade', (req, client, head) => proxyFixtureUpgrade(req, client, head, new URL('/realtime/v1/websocket', base)));
  const url = (await listen(bridge)).replace('http:', 'ws:');
  try {
    for (let n = 0; n < 2; n++) {
      const client = new WebSocket(url);
      await new Promise((resolve, reject) => { client.once('open', resolve); client.once('error', reject); });
      const reply = new Promise((resolve, reject) => { client.once('message', data => resolve(data.toString())); client.once('error', reject); });
      client.send('fictional-message'); assert.equal(await reply, 'fictional-message');
      const closed = new Promise(resolve => client.once('close', resolve)); client.close(); await closed;
    }
  } finally { await new Promise(resolve => ws.close(resolve)); await close(bridge); await close(upstream); }
});
test('rejected and stalled upgrades fail instead of hanging or fabricating 101', async () => {
  for (const stalled of [false, true]) {
    const upstream = createServer((_q, res) => { if (!stalled) { res.writeHead(401); res.end(); } });
    const base = await listen(upstream); const bridge = createServer();
    bridge.on('upgrade', (req, client, head) => proxyFixtureUpgrade(req, client, head, new URL('/realtime/v1/websocket', base), { timeoutMs: 80 }));
    const url = (await listen(bridge)).replace('http:', 'ws:');
    try {
      const client = new WebSocket(url); let opened = false; client.on('open', () => { opened = true; });
      await new Promise(resolve => { client.once('error', resolve); });
      assert.equal(opened, false); assert.equal(bridge.listening, true);
    } finally { await close(bridge); await close(upstream); }
  }
});
