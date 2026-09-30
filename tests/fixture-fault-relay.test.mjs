import test from 'node:test';
import assert from 'node:assert/strict';
import { createServer, request } from 'node:http';
import { once } from 'node:events';
import { faultController, fixtureTarget, relayHandler } from '../scripts/fixture-fault-relay.mjs';

const path = '/rest/v1/rpc/save_grn';
const key = 'fixture-fault-regression';
const arm = phase => ({ action: 'arm', phase, path, key });
async function listen(server) {
  server.listen(0, '127.0.0.1'); await once(server, 'listening');
  return `http://127.0.0.1:${server.address().port}`;
}
async function servers(t, handler, timeoutMs = 1000) {
  const upstream = createServer(handler), base = await listen(upstream);
  const controller = faultController();
  const relay = createServer(relayHandler({ base, controller, request, timeoutMs }));
  const origin = await listen(relay);
  t.after(async () => { for (const s of [relay, upstream]) { s.closeAllConnections(); await new Promise(resolve => s.close(resolve)); } });
  return { controller, origin };
}
const post = (origin, body = { p_idempotency_key: key }, target = path) => fetch(origin + target,
  { method: 'POST', body: JSON.stringify(body), headers: { 'content-type': 'application/json' }, signal: AbortSignal.timeout(3000) });

test('relative target guard refuses external and backslash origins', () => {
  const base = 'http://127.0.0.1:18443';
  for (const p of ['https://example.com/', '//example.com/', '/\\example.com/', 'relative', null]) assert.equal(fixtureTarget(p, base), null);
  assert.equal(fixtureTarget('/rest/v1/rpc/save_grn', base).origin, base);
});
test('fault arms require a supported RPC, explicit phase and fictional key prefix', () => {
  for (const command of [{ ...arm('before-upstream'), path: '/functions/v1/operator-otp/request' },
    { ...arm('before-upstream'), key: 'production-key' }, arm('after-unknown'), { action: 'unknown' }]) {
    assert.throws(() => faultController().control(command));
  }
});
test('pending and in-flight controls cannot be overwritten or silently cancelled', () => {
  const c = faultController(); c.control(arm('before-upstream')); assert.throws(() => c.control(arm('before-upstream')));
  const f = c.take('POST', path, JSON.stringify({ p_idempotency_key: key }));
  assert.throws(() => c.control(arm('before-upstream'))); assert.throws(() => c.control({ action: 'disarm' }));
  c.finish(f, 'DROPPED_BEFORE_UPSTREAM'); assert.equal(c.control(arm('before-upstream')).state, 'ARMED');
});
test('native controls match only the reserved fictional document and a real client operation key', () => {
  const c = faultController(); const digest = 'warehouse-grn-' + 'a'.repeat(64);
  c.control({ action: 'arm', phase: 'before-upstream', path, record: 'FXF01' });
  assert.equal(c.take('POST', path, JSON.stringify({ p_gr_no: 'REAL01', p_idempotency_key: digest })), null);
  assert.equal(c.take('POST', path, JSON.stringify({ p_gr_no: 'FXF01', p_idempotency_key: 'missing-real-key' })), null);
  assert.equal(c.take('POST', path, JSON.stringify({ p_gr_no: 'FXF01', p_idempotency_key: digest })).key, digest);
  assert.throws(() => faultController().control({ action: 'arm', phase: 'before-upstream', path, record: 'REAL01' }));
});
test('before-upstream loss sends no write; retry forwards exactly once', async t => {
  let writes = 0;
  const { controller, origin } = await servers(t, (req, res) => { req.resume(); writes++; res.end('{"success":true}'); });
  controller.control(arm('before-upstream'));
  await assert.rejects(post(origin)); assert.equal(writes, 0);
  assert.equal(controller.control({ action: 'status' }).state, 'DROPPED_BEFORE_UPSTREAM');
  const retry = await post(origin); assert.equal((await retry.json()).success, true); assert.equal(writes, 1);
});
test('after-success loss withholds complete reply; one-shot retry reaches upstream', async t => {
  let calls = 0;
  const { controller, origin } = await servers(t, (req, res) => { req.resume(); calls++; res.end('{"success":true}'); });
  controller.control(arm('after-upstream-success'));
  await assert.rejects(post(origin)); assert.equal(calls, 1);
  assert.equal(controller.control({ action: 'status' }).state, 'DROPPED_AFTER_UPSTREAM_SUCCESS');
  assert.equal((await (await post(origin)).json()).success, true); assert.equal(calls, 2);
  // This is a transport regression, not a database idempotency assertion.
});
test('a different idempotency key does not consume the armed fault', async t => {
  let calls = 0;
  const { controller, origin } = await servers(t, (req, res) => { req.resume(); calls++; res.end('{"success":true}'); });
  controller.control(arm('before-upstream'));
  assert.equal((await post(origin, { p_idempotency_key: 'fixture-fault-other' })).status, 200);
  assert.equal(controller.control({ action: 'status' }).state, 'ARMED');
  await assert.rejects(post(origin)); assert.equal(calls, 1);
});
test('upstream rejected writes remain visible and are never labelled after-success loss', async t => {
  const { controller, origin } = await servers(t, (req, res) => { req.resume(); res.writeHead(400); res.end('{"success":false}'); });
  controller.control(arm('after-upstream-success'));
  const r = await post(origin); assert.equal(r.status, 400); assert.equal((await r.json()).success, false);
  assert.equal(controller.control({ action: 'status' }).state, 'NOT_TRIGGERED_UPSTREAM_REJECTED');
});
test('bounded upstream timeout reports failure without a false successful fault', async t => {
  const { controller, origin } = await servers(t, req => req.resume(), 50);
  controller.control(arm('after-upstream-success'));
  assert.equal((await post(origin)).status, 502);
  assert.equal(controller.control({ action: 'status' }).state, 'UPSTREAM_OR_REQUEST_FAILED');
});
test('continuous response chunks cannot extend the absolute fault deadline', async t => {
  const { controller, origin } = await servers(t, (req, res) => {
    req.resume(); const timer = setInterval(() => res.write(' '), 10);
    res.on('close', () => clearInterval(timer));
  }, 70);
  controller.control(arm('after-upstream-success'));
  assert.equal((await post(origin)).status, 502);
  assert.equal(controller.control({ action: 'status' }).state, 'UPSTREAM_OR_REQUEST_FAILED');
});
test('HTTP200 without success true does not establish an after-success fault', async t => {
  const { controller, origin } = await servers(t, (req, res) => { req.resume(); res.end('{"success":false}'); });
  controller.control(arm('after-upstream-success'));
  const r = await post(origin); assert.equal(r.status, 200); assert.equal((await r.json()).success, false);
  assert.equal(controller.control({ action: 'status' }).state, 'NOT_TRIGGERED_UPSTREAM_REJECTED');
});
test('oversized requests fail before any upstream mutation', async t => {
  let calls = 0;
  const { origin } = await servers(t, (_req, res) => { calls++; res.end('{}'); });
  const r = await post(origin, { padding: 'x'.repeat(1024 * 1024 + 1) });
  assert.equal(r.status, 502); assert.equal(calls, 0);
});
