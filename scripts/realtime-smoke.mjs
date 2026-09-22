import assert from 'node:assert/strict';
import WebSocket from 'ws';
import { readEnv, root } from './doctor-common.mjs';

const env = readEnv(`${root}/docker/.env`);
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
    const timer = setTimeout(() => { socket.terminate(); reject(new Error('Realtime join timed out')); }, 15000);
    socket.once('error', error => { clearTimeout(timer); reject(error); });
    socket.on('message', raw => {
      const message = JSON.parse(raw.toString());
      if (message.ref !== ref || message.event !== 'phx_reply') return;
      clearTimeout(timer);
      resolve({ socket, status: message.payload?.status, response: message.payload?.response });
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

// Dedicated impossible demo number keeps this probe independent of API acceptance fixtures.
const customerToken = await login('0000000009');
const accepted = await join(customerToken, 'valid');
assert.equal(accepted.status, 'ok', `Authenticated Realtime join rejected: ${JSON.stringify(accepted.response)}`);
accepted.socket.close();

const rejected = await join('invalid.jwt.value', 'invalid');
assert.notEqual(rejected.status, 'ok', 'Invalid JWT was accepted for a database-change subscription');
rejected.socket.close();
console.log('Realtime startup, authenticated database-change join, and invalid-token rejection passed.');
