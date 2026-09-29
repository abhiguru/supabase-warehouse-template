// Operator-mode Realtime probe for the isolated fictional backend only.
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import WebSocket from 'ws';
import { operatorFixture } from './operator-fixture.mjs';

const { env, base, anon } = operatorFixture();
const query = sql => {
  const p = spawnSync('docker', ['exec', '-i', '-e', `PGPASSWORD=${env.POSTGRES_PASSWORD}`,
    `${env.WAREHOUSE_PROJECT_NAME}-db-1`, 'psql', '-X', '-qAt', '-U', 'supabase_admin', '-d', 'postgres',
    '-v', 'ON_ERROR_STOP=1'], { input: `SELECT (${sql})::text;\n`, encoding: 'utf8', timeout: 30000 });
  assert.equal(p.status, 0, `fixture SQL failed: ${p.stderr?.slice(-300)}`);
  return JSON.parse(p.stdout.trim());
};
const quote = value => `'${String(value).replaceAll("'", "''")}'`;
async function login(phone) {
  let challenge = query(`public.operator_prepare_otp(${quote(phone)})`);
  if (challenge.code === 'resend_cooldown') {
    const remaining = Math.max(1000, Math.min(65000, Date.parse(challenge.retry_at) - Date.now() + 1000));
    await new Promise(resolve => setTimeout(resolve, remaining));
    challenge = query(`public.operator_prepare_otp(${quote(phone)})`);
  }
  assert.equal(challenge.success, true, 'fictional challenge prepared');
  assert.equal(query(`public.operator_finish_otp(${quote(challenge.data.request_id)}::uuid,true,'mock-provider-only')`).success, true);
  const verified = query(`public.operator_verify_otp(${quote(phone)},${quote(challenge.data.otp_code)})`);
  assert.equal(verified.success, true);
  return verified.data.session.access_token;
}
async function api(path, token, body, method = body === undefined ? 'GET' : 'POST') {
  const response = await fetch(base + path, { method, headers: {
    apikey: anon, Authorization: `Bearer ${token}`, 'Content-Type': 'application/json',
  }, body: body === undefined ? undefined : JSON.stringify(body), signal: AbortSignal.timeout(30000) });
  const raw = await response.text();
  let data; try { data = JSON.parse(raw); } catch { data = null; }
  return { ok: response.ok, status: response.status, data };
}
const socketUrl = `ws://127.0.0.1:${env.KONG_HTTP_PORT}/realtime/v1/websocket?apikey=${encodeURIComponent(anon)}&vsn=1.0.0`;
function join(token, ref) {
  return new Promise((resolve, reject) => {
    const socket = new WebSocket(socketUrl, { handshakeTimeout: 10000,
      headers: { apikey: anon, authorization: `Bearer ${token}` } });
    const messages = [];
    const timer = setTimeout(() => { socket.terminate(); reject(new Error('Realtime join timeout')); }, 15000);
    socket.once('error', error => { clearTimeout(timer); reject(error); });
    socket.on('message', raw => {
      const message = JSON.parse(raw.toString()); messages.push(message);
      if (message.ref === ref && message.event === 'phx_reply') {
        clearTimeout(timer); resolve({ socket, messages, status: message.payload?.status });
      }
    });
    socket.once('open', () => socket.send(JSON.stringify({ topic: 'realtime:public:orders',
      event: 'phx_join', ref, payload: { access_token: token,
        config: { broadcast: { ack: false, self: false }, presence: { key: '' },
          postgres_changes: [{ event: '*', schema: 'public', table: 'orders' }] } } })));
  });
}
async function joinReady(token, ref) {
  let last;
  for (let attempt = 0; attempt < 5; attempt += 1) {
    let channel;
    try {
      channel = await join(token, ref);
      assert.equal(channel.status, 'ok', 'authenticated Realtime join');
      await waitFor(() => channel.messages.some(m => m.event === 'system' && m.payload?.status === 'ok'),
        'database subscription ready');
      return channel;
    }
    catch (error) {
      channel?.socket.terminate();
      last = error;
      if (!/502|ECONNREFUSED|ECONNRESET|timeout|Timed out: database subscription ready/i.test(String(error?.message))) throw error;
      await new Promise(resolve => setTimeout(resolve, 1000));
    }
  }
  throw last;
}
async function waitFor(check, label, timeout = 15000) {
  const end = Date.now() + timeout;
  while (Date.now() < end) { if (check()) return; await new Promise(resolve => setTimeout(resolve, 100)); }
  throw new Error(`Timed out: ${label}`);
}
const admin = await login('919888888871');
const customerA = await login('919888888872');
const customerB = await login('919888888873');
const rows = await api('/rest/v1/customers?select=id,name', admin);
assert.ok(rows.ok && rows.data.filter(row => row.name.startsWith('Backend Test Customer ')).length === 2, 'fictional customers available');
const a = rows.data.find(row => row.name.endsWith('A')).id;
const b = rows.data.find(row => row.name.endsWith('B')).id;
const cartA = await api('/rest/v1/rpc/get_or_create_cart', customerA, { p_customer_id: a });
const cartB = await api('/rest/v1/rpc/get_or_create_cart', customerB, { p_customer_id: b });
assert.ok(cartA.ok && cartB.ok, 'fictional carts available');
const sockets = [];
try {
  console.log('Realtime: joining A');
  const chanA = await joinReady(customerA, 'A'); sockets.push(chanA.socket);
  console.log('Realtime: joining B');
  const chanB = await joinReady(customerB, 'B'); sockets.push(chanB.socket);
  console.log('Realtime: joining admin');
  const chanAdmin = await joinReady(admin, 'admin'); sockets.push(chanAdmin.socket);
  for (const channel of [chanA, chanB, chanAdmin]) {
    assert.equal(channel.status, 'ok', 'authenticated Realtime join');
    await waitFor(() => channel.messages.some(m => m.event === 'system' && m.payload?.status === 'ok'), 'database subscription ready');
  }
  console.log('Realtime: checking invalid token');
  try {
    const invalid = await join('invalid.jwt.value', 'invalid'); sockets.push(invalid.socket);
    assert.notEqual(invalid.status, 'ok', 'invalid JWT rejected');
  } catch (error) {
    assert.match(String(error?.message), /401|403/i, 'invalid JWT handshake rejected');
  }
  const marker = `Backend realtime ${Date.now()}`;
  for (const id of [cartA.data, cartB.data]) {
    const updated = await api(`/rest/v1/orders?id=eq.${id}`, admin, { note: marker }, 'PATCH');
    assert.ok(updated.ok, 'admin update emits event');
  }
  const received = (channel, id, note = marker) => channel.messages.some(m =>
    m.event === 'postgres_changes' && m.payload?.data?.record?.id === id && m.payload?.data?.record?.note === note);
  await waitFor(() => received(chanA, cartA.data) && received(chanB, cartB.data) &&
    received(chanAdmin, cartA.data) && received(chanAdmin, cartB.data), 'authorized delivery');
  await new Promise(resolve => setTimeout(resolve, 1000));
  assert.ok(!received(chanA, cartB.data) && !received(chanB, cartA.data), 'A/B events isolated');
  chanA.socket.terminate();
  const reconnect = await joinReady(customerA, 'reconnect'); sockets.push(reconnect.socket);
  assert.equal(reconnect.status, 'ok');
  await waitFor(() => reconnect.messages.some(m => m.event === 'system' && m.payload?.status === 'ok'), 'reconnected subscription ready');
  const next = `${marker} reconnect`;
  assert.ok((await api(`/rest/v1/orders?id=eq.${cartA.data}`, admin, { note: next }, 'PATCH')).ok);
  await waitFor(() => received(reconnect, cartA.data, next), 'delivery after reconnect');
  console.log('PASS isolated operator Realtime A/B delivery, invalid-token rejection, and reconnect');
} finally {
  for (const socket of sockets) socket.terminate();
}
