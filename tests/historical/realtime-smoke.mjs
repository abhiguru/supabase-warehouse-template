// Historical fixed-OTP realtime fixture. Not part of operator acceptance.
import assert from 'node:assert/strict';
import WebSocket from 'ws';
import { randomUUID } from 'node:crypto';
import { readEnv, root, probe } from '../../scripts/doctor-common.mjs';

const env = readEnv(`${root}/docker/.env`);
assert.equal(env.AUTH_MODE, 'demo');
assert.equal(env.BIND_ADDRESS, '127.0.0.1');
assert.ok(probe('bash', [root + '/scripts/compose.sh', 'ps', '-q']).ok, 'Checkout ownership required');
const base = `http://127.0.0.1:${env.KONG_HTTP_PORT}`;
const socketBase = `ws://127.0.0.1:${env.KONG_HTTP_PORT}/realtime/v1/websocket?apikey=${encodeURIComponent(env.ANON_KEY)}&vsn=1.0.0`;

async function rpc(name, token, body) {
  const response = await fetch(`${base}/rest/v1/rpc/${name}`, {
    method: 'POST',
    headers: { apikey: env.ANON_KEY, authorization: `Bearer ${token}`, 'content-type': 'application/json' },
    body: JSON.stringify(body),
    signal: AbortSignal.timeout(15000),
  });
  const value = await response.json();
  if (!response.ok || value?.success === false) throw new Error(`${name} failed with HTTP ${response.status}`);
  return value;
}

async function login(phone) {
  await rpc('send_otp', env.ANON_KEY, { p_phone_number: phone });
  const result = await rpc('verify_otp_or_register', env.ANON_KEY, { p_phone_number: phone, p_otp_code: '123456' });
  return result.data.session.access_token;
}

function joinOnce(token, ref) {
  return new Promise((resolve, reject) => {
    const socket = new WebSocket(socketBase, {
      handshakeTimeout: 10000,
      headers: { apikey: env.ANON_KEY, authorization: `Bearer ${token}` },
    });
    const messages = [];
    const timer = setTimeout(() => { socket.terminate(); reject(new Error('Realtime join timed out')); }, 15000);
    socket.once('error', error => { clearTimeout(timer); reject(error); });
    socket.on('message', raw => {
      const message = JSON.parse(raw.toString());
      messages.push(message);
      if (message.ref !== ref || message.event !== 'phx_reply') return;
      clearTimeout(timer);
      resolve({ socket, messages, status: message.payload?.status, response: message.payload?.response });
    });
    socket.once('open', () => socket.send(JSON.stringify({
      topic: 'realtime:public:orders', event: 'phx_join', ref,
      payload: {
        config: { broadcast: { ack: false, self: false }, presence: { key: '' }, postgres_changes: [{ event: '*', schema: 'public', table: 'orders' }] },
        access_token: token,
      },
    })));
  });
}

async function join(token, ref) {
  let lastError;
  for (let attempt = 1; attempt <= 15; attempt += 1) {
    try {
      return await joinOnce(token, ref);
    } catch (error) {
      lastError = error;
      const message = String(error?.message || error);
      if (!/Unexpected server response: 502|ECONNREFUSED|ECONNRESET/.test(message)) throw error;
      if (attempt < 15) await new Promise(resolve => setTimeout(resolve, 1000));
    }
  }
  throw new Error(`Realtime gateway did not become ready: ${lastError?.message || lastError}`);
}

async function waitFor(check, label, timeout = 15000) {
  const deadline = Date.now() + timeout;
  while (Date.now() < deadline) {
    if (check()) return;
    await new Promise(resolve => setTimeout(resolve, 100));
  }
  throw new Error(`Timed out: ${label}`);
}

async function rest(path, token, body, method = body ? 'POST' : 'GET') {
  const response = await fetch(`${base}/rest/v1/${path}`, {
    method, headers: { apikey: env.ANON_KEY, authorization: `Bearer ${token}`, 'content-type': 'application/json' },
    body: body ? JSON.stringify(body) : undefined, signal: AbortSignal.timeout(15000),
  });
  if (!response.ok) { const error = await response.json(); throw new Error(`Fixture ${method}: HTTP ${response.status}, ${error.code}, ${error.message}`); }
  const text = await response.text();
  return text ? JSON.parse(text) : null;
}

const adminToken = await login('0000000001');
const customerToken = await login('0000000002');
const sockets = [];
const fixtures = [];
let marker = `Realtime smoke ${randomUUID()}`;
try {
  const customer = await join(customerToken, 'customer'); sockets.push(customer.socket);
  const admin = await join(adminToken, 'admin'); sockets.push(admin.socket);
  for (const channel of [customer, admin]) {
    assert.equal(channel.status, 'ok', 'Authenticated join rejected');
    await waitFor(() => channel.messages.some(m => m.event === 'system' && m.payload?.status === 'ok'), 'database subscription ready');
  }
  const rejected = await join('invalid.jwt.value', 'invalid'); sockets.push(rejected.socket);
  assert.notEqual(rejected.status, 'ok', 'Invalid JWT accepted');
  for (let i = 0; i < 2; i++) {
    const customerId = `22222222-0000-4000-8000-00000000000${i + 1}`;
    const previous = await rest(`orders?select=id,note&customer_id=eq.${customerId}`, adminToken);
    const id = previous[0]?.id || await rpc('get_or_create_cart', adminToken, { p_customer_id: customerId });
    fixtures.push({ id, previous: previous[0] });
    await rest(`orders?id=eq.${id}`, adminToken, { note: marker }, 'PATCH');
  }
  const ids = fixtures.map(f => f.id);
  const received = (channel, id) => channel.messages.some(m => m.event === 'postgres_changes' && m.payload?.data?.record?.id === id && m.payload?.data?.record?.note === marker);
  await waitFor(() => ids.every(id => received(admin, id)) && received(customer, ids[0]), 'admin and assigned customer delivery');
  await new Promise(resolve => setTimeout(resolve, 2000));
  assert.ok(!received(customer, ids[1]), 'Customer received another customer order');
  customer.socket.terminate();
  const reconnected = await join(customerToken, 'reconnected'); sockets.push(reconnected.socket);
  assert.equal(reconnected.status, 'ok');
  await waitFor(() => reconnected.messages.some(m => m.event === 'system' && m.payload?.status === 'ok'), 'reconnected subscription ready');
  marker = `Realtime reconnect ${randomUUID()}`;
  await rest(`orders?id=eq.${ids[0]}`, adminToken, { note: marker }, 'PATCH');
  await waitFor(() => received(reconnected, ids[0]), 'event delivery after reconnect');
  console.log('Realtime event delivery, customer isolation, reconnect, and invalid-token rejection passed.');
} finally {
  for (const socket of sockets) socket.terminate();
  for (const fixture of fixtures) {
    await rest(`orders?id=eq.${fixture.id}`, adminToken, fixture.previous ? { note: fixture.previous.note } : undefined, fixture.previous ? 'PATCH' : 'DELETE');
  }
}
