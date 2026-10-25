import { test } from 'node:test';
import assert from 'node:assert/strict';
import { randomBytes } from 'node:crypto';
import { BODY_MAX_BYTES, MAX_READINGS, handle } from '../functions/ingest-sensor-readings/handler.ts';

// No network: the only outbound call (the record_sensor_batch RPC) goes to this stand-in.
const environment = { SUPABASE_URL: 'http://rest.test', SUPABASE_SERVICE_ROLE_KEY: 'unit-test-service-key' };
// A fresh ingest key each run, so a leak cannot match by accident.
const key = randomBytes(32).toString('hex');
const rpcUrl = 'http://rest.test/rest/v1/rpc/record_sensor_batch';
const accepted = { success: true, data: {
  accepted: 2, duplicates: 1, rejected: 0, rejected_reasons: {}, devices_seen: 3, devices_created: 0, hub_id: 'hub-1', hub_online: true,
} };

const reading = n => ({
  external_id: String(n).padStart(40, '0'), name: `Fictional sensor ${n}`, model: 'T310', temperature: 4.5, humidity: 61,
  measured_at: '2026-10-13T10:00:00Z', battery_low: false, battery_percent: 90, signal_level: 3, report_interval_s: 16, kind: 'change',
});
const batch = (readings = [reading(1), reading(2), reading(3)]) => ({
  bridge: { id: 'unit-bridge', version: '0.1.0' },
  hub: { id: 'unit-hub-id', host: '192.0.2.10', online: true, firmware: '1.0.0' },
  readings,
});

function harness({ env = environment, answer = accepted } = {}) {
  const state = { calls: [], logs: [], answer };
  const fetchStub = async (url, init) => {
    state.calls.push({ url: String(url), method: init.method, headers: init.headers, body: JSON.parse(init.body), redirect: init.redirect, signal: init.signal });
    if (state.answer instanceof Error) throw state.answer;
    return state.answer instanceof Response ? state.answer.clone() : Response.json(state.answer);
  };
  state.call = (body, headers = { Authorization: `Bearer ${key}` }, method = 'POST') => handle(
    new Request('http://edge.test/ingest-sensor-readings', {
      method, headers: { 'Content-Type': 'application/json', ...headers },
      body: method === 'POST' || method === 'PUT' ? (typeof body === 'string' ? body : JSON.stringify(body)) : undefined,
    }),
    { env: name => env[name], fetch: fetchStub, log: message => state.logs.push(message) },
  );
  return state;
}
const bodyOf = async response => ({ status: response.status, body: await response.json() });
const UNAUTHORIZED = { status: 401, body: { success: false, error: 'Unauthorized' } };
const INVALID = { status: 400, body: { success: false, error: 'Invalid request' } };
const UNAVAILABLE = { status: 503, body: { success: false, error: 'Ingestion unavailable' } };

// True when any 8-character run of the key appears in the text.
function holdsKeyPart(text) {
  for (let i = 0; i + 8 <= key.length; i += 1) if (text.includes(key.slice(i, i + 8))) return true;
  return false;
}

test('with SUPABASE_REST_URL set the RPC goes to PostgREST directly, with only apikey, Authorization and Content-Type', async () => {
  const h = harness({ env: { ...environment, SUPABASE_REST_URL: 'http://rest:3000' } });
  const response = await h.call(batch());
  assert.equal(response.status, 200);
  assert.equal(h.calls.length, 1);
  assert.equal(h.calls[0].url, 'http://rest:3000/rpc/record_sensor_batch');
  assert.deepEqual(Object.keys(h.calls[0].headers).sort(), ['Authorization', 'Content-Type', 'apikey']);
});

test('refuses every method but POST, a preflight included, without a database call (the gateway answers the browser preflight)', async () => {
  const h = harness();
  const preflight = await h.call(undefined, {}, 'OPTIONS');
  assert.equal(preflight.status, 405);
  assert.equal(preflight.headers.get('Access-Control-Allow-Origin'), null, 'the function sets no CORS header');
  for (const method of ['GET', 'PUT', 'DELETE']) {
    const response = await h.call(batch(), undefined, method);
    assert.deepEqual(await bodyOf(response.clone()), { status: 405, body: { success: false, error: 'Method not allowed' } }, method);
    assert.equal(response.headers.get('Allow'), 'POST');
  }
  assert.equal(h.calls.length, 0);
});

test('a missing bearer is refused with 401 and no database call', async () => {
  const h = harness();
  for (const headers of [{}, { Authorization: '' }, { Authorization: 'Bearer' }, { Authorization: 'Bearer ' }, { Authorization: `Basic ${key}` }, { apikey: key }]) {
    const response = await h.call(batch(), headers);
    assert.deepEqual(await bodyOf(response.clone()), UNAUTHORIZED, JSON.stringify(headers));
    assert.equal(response.headers.get('WWW-Authenticate'), 'Bearer');
    assert.equal(response.headers.get('Cache-Control'), 'no-store');
  }
  assert.equal(h.calls.length, 0, 'no refused caller reached the RPC');
  for (const line of h.logs) assert.equal(line, 'ingest-sensor-readings: event=ingest reason=missing_key');
});

test('a malformed key is refused with 401 and no database call', async () => {
  const h = harness();
  const malformed = [key.slice(1), `${key}0`, key.toUpperCase(), `${key.slice(0, 63)}g`, `${key.slice(0, 32)}-${key.slice(33)}`, 'x'.repeat(64), `${key},${key}`];
  for (const bad of malformed) assert.deepEqual(await bodyOf(await h.call(batch(), { Authorization: `Bearer ${bad}` })), UNAUTHORIZED, bad);
  assert.equal(h.calls.length, 0, 'no malformed key reached the RPC');
  assert.equal(h.logs.length, malformed.length);
  for (const line of h.logs) assert.equal(line, 'ingest-sensor-readings: event=ingest reason=malformed_key');
});

test('a key the database refuses is 401, and neither the answer nor the log holds any part of the key', async () => {
  const h = harness({ answer: { success: false, code: 'invalid_key' } });
  const response = await h.call(batch());
  const text = await response.text();
  assert.equal(response.status, 401);
  assert.deepEqual(JSON.parse(text), UNAUTHORIZED.body);
  assert.equal(h.calls.length, 1, 'the well-formed key was checked by the database');
  assert.deepEqual(h.logs, ['ingest-sensor-readings: event=ingest reason=invalid_key']);
  assert.ok(!holdsKeyPart(text), 'the response echoes the key');
  assert.ok(!holdsKeyPart(h.logs.join('\n')), 'the log holds the key');
  assert.ok(!holdsKeyPart(JSON.stringify([...response.headers])), 'a response header holds the key');
});

test('no answer and no log line of any outcome holds the key or the body', async () => {
  const outcomes = [
    accepted, { success: false, code: 'invalid_key' }, { success: false, code: 'invalid_readings' }, { success: false, code: 'something_new' },
    new Response('{"message":"boom"}', { status: 500 }), new DOMException('timed out', 'TimeoutError'), new TypeError('fetch failed'),
  ];
  const texts = [];
  const logs = [];
  for (const answer of outcomes) {
    const h = harness({ answer });
    texts.push(await (await h.call(batch())).text());
    logs.push(...h.logs);
  }
  const h = harness({ env: {} });
  texts.push(await (await h.call(batch())).text());
  logs.push(...h.logs);
  assert.equal(logs.length, outcomes.length + 1, 'one log line per request');
  for (const text of [...texts, ...logs]) {
    assert.ok(!holdsKeyPart(text), `key part in: ${text}`);
    assert.doesNotMatch(text, /Fictional sensor|unit-hub-id|unit-bridge|192\.0\.2\.10|unit-test-service-key/, `body or server key in: ${text}`);
  }
  for (const line of logs) assert.match(line, /^ingest-sensor-readings: event=ingest reason=[a-z0-9_]+(?: [a-z_]+=[a-z0-9_]+)*$/);
});

test('a good batch reaches record_sensor_batch with the server key, the bearer as p_key and the bridge in p_hub', async () => {
  const h = harness();
  const sent = batch();
  const response = await h.call(sent);
  assert.deepEqual(await bodyOf(response.clone()), { status: 200, body: { success: true, accepted: 2, duplicates: 1, rejected: 0, devices: 3 } });
  assert.equal(response.headers.get('Cache-Control'), 'no-store');
  assert.equal(response.headers.get('Content-Type'), 'application/json');
  assert.equal(response.headers.get('Access-Control-Allow-Origin'), null, 'CORS is the gateway\'s: the function sets none');
  assert.equal(response.headers.get('X-Content-Type-Options'), 'nosniff');
  assert.equal(h.calls.length, 1);
  const [call] = h.calls;
  assert.equal(call.url, rpcUrl);
  assert.equal(call.method, 'POST');
  assert.equal(call.redirect, 'error');
  assert.ok(call.signal instanceof AbortSignal, 'the call has a timeout');
  assert.deepEqual(call.headers, { apikey: 'unit-test-service-key', Authorization: 'Bearer unit-test-service-key', 'Content-Type': 'application/json' });
  assert.deepEqual(call.body, { p_key: key, p_hub: { ...sent.hub, bridge: sent.bridge }, p_readings: sent.readings });
  assert.deepEqual(h.logs, ['ingest-sensor-readings: event=ingest reason=ok accepted=2 duplicates=1 rejected=0 devices=3']);
  // A batch without the bridge block is passed on without one; the database decides.
  await h.call({ hub: sent.hub, readings: [] });
  assert.deepEqual(h.calls[1].body, { p_key: key, p_hub: sent.hub, p_readings: [] });
  // The bearer scheme is matched without regard to case, as HTTP defines it.
  assert.equal((await h.call(sent, { Authorization: `bearer ${key}` })).status, 200);
});

test('a body over 256 KiB is refused with 400 and no call, by Content-Length and by stream', async () => {
  const h = harness();
  // Declared too large: refused before the body is read.
  const declared = new Request('http://edge.test/ingest-sensor-readings', {
    method: 'POST', headers: { Authorization: `Bearer ${key}`, 'Content-Type': 'application/json', 'Content-Length': String(BODY_MAX_BYTES + 1) },
    body: JSON.stringify(batch()),
  });
  assert.deepEqual(await bodyOf(await handle(declared, { env: name => environment[name], fetch: async () => { throw new Error('called'); }, log: () => {} })), INVALID);
  // Streamed with no length: refused once the bytes pass the limit.
  const chunk = new TextEncoder().encode(' '.repeat(65536));
  let sentChunks = 0;
  const stream = new ReadableStream({ pull(controller) {
    sentChunks += 1;
    if (sentChunks <= 5) controller.enqueue(chunk); else controller.close();
  } });
  const streamed = new Request('http://edge.test/ingest-sensor-readings', {
    method: 'POST', headers: { Authorization: `Bearer ${key}`, 'Content-Type': 'application/json' }, body: stream, duplex: 'half',
  });
  assert.equal(streamed.headers.get('content-length'), null);
  assert.deepEqual(await bodyOf(await handle(streamed, { env: name => environment[name], fetch: async () => { throw new Error('called'); }, log: () => {} })), INVALID);
  // Exactly at the limit is accepted, one byte more is not.
  const padded = extra => {
    const base = batch();
    const text = JSON.stringify({ ...base, hub: { ...base.hub, note: '' } });
    return JSON.stringify({ ...base, hub: { ...base.hub, note: 'x'.repeat(BODY_MAX_BYTES - text.length + extra) } });
  };
  assert.equal(Buffer.byteLength(padded(0)), BODY_MAX_BYTES);
  assert.equal((await h.call(padded(0))).status, 200);
  assert.deepEqual(await bodyOf(await h.call(padded(1))), INVALID);
  assert.equal(h.calls.length, 1, 'only the body within the limit reached the RPC');
  assert.deepEqual(h.logs.slice(1), ['ingest-sensor-readings: event=ingest reason=body_too_large']);
});

test('more than 500 readings is refused with 400 and no call; 500 are passed on', async () => {
  const h = harness();
  const many = Array.from({ length: MAX_READINGS + 1 }, (_, n) => reading(n));
  assert.deepEqual(await bodyOf(await h.call(batch(many))), INVALID);
  assert.equal(h.calls.length, 0);
  assert.deepEqual(h.logs, ['ingest-sensor-readings: event=ingest reason=too_many_readings']);
  assert.equal((await h.call(batch(many.slice(0, MAX_READINGS)))).status, 200);
  assert.equal(h.calls[0].body.p_readings.length, 500);
});

test('a body that is not the batch shape is refused with 400 and no call', async () => {
  const h = harness();
  const good = batch();
  const bodies = [
    '', '{', '[]', 'null', '7', '"text"', '[{"hub":{},"readings":[]}]', {},
    { readings: good.readings }, { hub: good.hub }, { hub: null, readings: [] }, { hub: [], readings: [] }, { hub: 'hub', readings: [] },
    { hub: good.hub, readings: {} }, { hub: good.hub, readings: 'none' }, { hub: good.hub, readings: [reading(1), null] },
    { hub: good.hub, readings: [[reading(1)]] }, { hub: good.hub, readings: [7] },
    { ...good, bridge: 'unit-bridge' }, { ...good, bridge: null }, { ...good, bridge: [good.bridge] },
  ];
  for (const body of bodies) assert.deepEqual(await bodyOf(await h.call(body)), INVALID, JSON.stringify(body));
  // Bytes that are not UTF-8 are refused too.
  const raw = new Request('http://edge.test/ingest-sensor-readings', {
    method: 'POST', headers: { Authorization: `Bearer ${key}` }, body: new Uint8Array([0x7b, 0xff, 0x7d]),
  });
  assert.deepEqual(await bodyOf(await handle(raw, { env: name => environment[name], fetch: async () => { throw new Error('called'); }, log: () => {} })), INVALID);
  assert.equal(h.calls.length, 0, 'no malformed body reached the RPC');
  assert.equal(h.logs.length, bodies.length);
});

test('the database refusing the hub or the readings is 400', async () => {
  for (const code of ['invalid_hub', 'invalid_readings', 'too_many_readings']) {
    const h = harness({ answer: { success: false, code } });
    assert.deepEqual(await bodyOf(await h.call(batch())), INVALID, code);
    assert.equal(h.calls.length, 1);
    assert.deepEqual(h.logs, [`ingest-sensor-readings: event=ingest reason=${code}`]);
  }
});

test('a PostgREST error, a timeout, an unreachable database or an odd answer is 503', async () => {
  const cases = {
    rpc_status_500: new Response('{"message":"internal"}', { status: 500 }),
    rpc_status_404: new Response('{"message":"function not found"}', { status: 404 }),
    rpc_status_401: new Response('{"message":"JWT invalid"}', { status: 401 }),
    rpc_timeout: new DOMException('The operation timed out.', 'TimeoutError'),
    rpc_unreachable: new TypeError('fetch failed'),
    rpc_answer_malformed: new Response('not json', { status: 200 }),
    'rpc_refused code=unknown': { success: false },
    'rpc_refused code=something_new': { success: false, code: 'something_new' },
  };
  for (const [reason, answer] of Object.entries(cases)) {
    const h = harness({ answer });
    assert.deepEqual(await bodyOf(await h.call(batch())), UNAVAILABLE, reason);
    assert.deepEqual(h.logs, [`ingest-sensor-readings: event=ingest reason=${reason}`]);
  }
  // A success without its counts is not passed on as a success.
  for (const data of [undefined, {}, { ...accepted.data, accepted: -1 }, { ...accepted.data, devices_seen: '3' }, { ...accepted.data, rejected: 1.5 }]) {
    const h = harness({ answer: { success: true, data } });
    assert.deepEqual(await bodyOf(await h.call(batch())), UNAVAILABLE, JSON.stringify(data));
    assert.deepEqual(h.logs, ['ingest-sensor-readings: event=ingest reason=rpc_answer_malformed']);
  }
});

test('without the database address or the server key the answer is 503 and nothing is called', async () => {
  for (const env of [{}, { SUPABASE_URL: environment.SUPABASE_URL }, { SUPABASE_SERVICE_ROLE_KEY: environment.SUPABASE_SERVICE_ROLE_KEY },
    { ...environment, SUPABASE_URL: '' }]) {
    const h = harness({ env });
    assert.deepEqual(await bodyOf(await h.call(batch())), UNAVAILABLE, JSON.stringify(env));
    assert.equal(h.calls.length, 0);
    assert.deepEqual(h.logs, ['ingest-sensor-readings: event=ingest reason=env_missing']);
  }
  // A caller without a well-formed key still gets 401, not a hint about the configuration.
  assert.deepEqual(await bodyOf(await harness({ env: {} }).call(batch(), {})), UNAUTHORIZED);
});
