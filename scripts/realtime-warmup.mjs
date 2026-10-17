// One authenticated Realtime channel join through the local gateway, after `up --wait`.
// Realtime connects its tenant to the database on the first join; doing that here, once,
// means the first person to open the app does not pay for it (TW-BE-015). Best effort:
// a failure prints a warning and exits 0, because the services themselves are healthy.
// Uses only the built-in WebSocket (Node 22) and the gateway on 127.0.0.1; it reads the
// port and the public anon key from the state's compose.env and sends nothing else.
import { resolve } from 'node:path';
import { readEnv } from './doctor-common.mjs';
import { isMain } from './is-main.mjs';

export function joinOnce({ port, anonKey, timeoutMs = 30000, WebSocketImpl = globalThis.WebSocket }) {
  return new Promise(resolve => {
    const started = Date.now();
    const url = `ws://127.0.0.1:${port}/realtime/v1/websocket?apikey=${encodeURIComponent(anonKey)}&vsn=1.0.0`;
    let socket;
    const finish = result => { clearTimeout(timer); try { socket?.close(); } catch { /* already closed */ } resolve({ ...result, ms: Date.now() - started }); };
    const timer = setTimeout(() => finish({ ok: false, reason: 'timeout' }), timeoutMs);
    try { socket = new WebSocketImpl(url); } catch { finish({ ok: false, reason: 'connect' }); return; }
    socket.addEventListener('error', () => finish({ ok: false, reason: 'connect' }));
    socket.addEventListener('open', () => socket.send(JSON.stringify({ topic: 'realtime:warmup', event: 'phx_join', ref: '1',
      payload: { access_token: anonKey, config: { broadcast: { ack: false, self: false }, presence: { key: '' } } } })));
    socket.addEventListener('message', event => {
      let message; try { message = JSON.parse(String(event.data)); } catch { return; }
      if (message.ref === '1' && message.event === 'phx_reply') finish({ ok: message.payload?.status === 'ok', reason: message.payload?.status });
    });
  });
}

export async function warmUp(env, { attempts = 3, ...options } = {}) {
  let last;
  for (let attempt = 1; attempt <= attempts; attempt += 1) {
    last = await joinOnce({ port: Number(env.KONG_HTTP_PORT), anonKey: env.ANON_KEY, ...options });
    if (last.ok) return { ...last, attempt };
  }
  return { ...last, attempt: attempts };
}

if (isMain(import.meta.url)) {
  const state = process.env.WAREHOUSE_STATE_DIR;
  if (!state) { console.error('Set WAREHOUSE_STATE_DIR to the installed operator state.'); process.exit(0); }
  const result = await warmUp(readEnv(resolve(state, 'config/compose.env')));
  if (result.ok) console.log(`Realtime warm-up: channel joined on attempt ${result.attempt} (${result.ms} ms).`);
  else console.error(`Warning: the Realtime warm-up join failed (${result.reason}). The services are up; the first app connection may need a retry (docs/TROUBLESHOOTING.md, "Realtime is slow to connect after a start").`);
}
