import { test } from 'node:test';
import assert from 'node:assert/strict';
import { SignJWT, exportJWK, exportSPKI, generateKeyPair } from 'jose';
import { TOKEN_TYPE, createKeyCache, handle } from '../functions/central-exchange/handler.ts';
import { advertisedCentralIssuer, advertisedCentralLogin, httpsAddress } from '../functions/_shared/https-address.ts';

// No network and no central service: the tests make their own ES256 keys, serve
// the key set through the injected fetch, and stand in for the PostgREST RPC.
const ISSUER = 'https://login.association.example.test';
const JWKS = 'https://login.association.example.test/.well-known/jwks.json';
const FACILITY = 'https://facility-one.example.test';
const environment = {
  AUTH_MODE: 'operator', APP_ENV: 'production', SUPABASE_URL: 'http://rest.test', SUPABASE_SERVICE_ROLE_KEY: 'unit-test-service-key',
  SUPABASE_PUBLIC_URL: FACILITY, CENTRAL_ISSUER: ISSUER, CENTRAL_JWKS_URL: JWKS,
};
const START = Date.parse('2026-10-12T10:00:00Z');
const seconds = ms => Math.floor(ms / 1000);

async function signingKey(kid) {
  const { publicKey, privateKey } = await generateKeyPair('ES256', { extractable: true });
  return { kid, publicKey, privateKey, jwk: { ...(await exportJWK(publicKey)), kid, alg: 'ES256', use: 'sig' } };
}
const first = await signingKey('key-2026-10');
const second = await signingKey('key-2026-11');
const stranger = await signingKey('key-2026-10'); // same key id, another key pair

const claims = (at, changes = {}) => {
  const all = {
    iss: ISSUER, aud: FACILITY, sub: 'central-user-0001', phone_number: '919000000101', phone_number_verified: true,
    iat: seconds(at), exp: seconds(at) + 300, jti: 'token-id-0000000000000001', ...changes,
  };
  for (const [name, value] of Object.entries(all)) if (value === undefined) delete all[name];
  return all;
};
const sign = (payload, key = first, header = {}) => {
  const protectedHeader = { alg: 'ES256', typ: TOKEN_TYPE, kid: key.kid, ...header };
  for (const [name, value] of Object.entries(protectedHeader)) if (value === undefined) delete protectedHeader[name];
  return new SignJWT(payload).setProtectedHeader(protectedHeader).sign(key.privateKey);
};
const encode = value => Buffer.from(JSON.stringify(value)).toString('base64url');

const loginAnswer = { success: true, data: { action: 'login', user: { id: 'u', mobile: '919000000101' }, session: { access_token: 'a', refresh_token: 'r' } } };
const pendingAnswer = { success: true, data: { action: 'pending', enrollment_token: 'e'.repeat(64), expires_at: '2026-10-19T10:00:00Z',
  user: { id: 'u', name: 'New customer', enrollment_status: 'pending' } } };

function harness({ env = environment, rpcAnswer = loginAnswer, keySet = { keys: [first.jwk] } } = {}) {
  const state = { now: START, keySet, rpcAnswer, jwksFetches: [], rpcCalls: [], logs: [], responses: [] };
  const fetchStub = async (url, init) => {
    const target = String(url);
    if (target === env.CENTRAL_JWKS_URL) {
      state.jwksFetches.push(init);
      const answer = typeof state.keySet === 'function' ? state.keySet() : state.keySet;
      if (answer instanceof Error) throw answer;
      return answer instanceof Response ? answer.clone() : Response.json(answer);
    }
    assert.equal(target, env.SUPABASE_REST_URL ? 'http://rest:3000/rpc/operator_central_exchange' : 'http://rest.test/rest/v1/rpc/operator_central_exchange', `unexpected outbound request: ${target}`);
    state.rpcCalls.push({ body: JSON.parse(init.body), headers: init.headers, method: init.method, redirect: init.redirect });
    if (state.rpcAnswer instanceof Error) throw state.rpcAnswer;
    return state.rpcAnswer instanceof Response ? state.rpcAnswer.clone() : Response.json(state.rpcAnswer);
  };
  const deps = { env: name => env[name], fetch: fetchStub, now: () => state.now, log: message => state.logs.push(message), keys: createKeyCache() };
  state.call = async (body, headers = {}, method = 'POST') => {
    const response = await handle(new Request('http://edge.test/central-exchange', {
      method, headers: { 'Content-Type': 'application/json', ...headers },
      body: method === 'POST' ? (typeof body === 'string' ? body : JSON.stringify(body)) : undefined,
    }), deps);
    const text = await response.text();
    state.responses.push(text);
    return { status: response.status, body: JSON.parse(text), headers: response.headers };
  };
  state.exchange = async (token, extra = {}, headers = {}) => {
    const { status, body } = await state.call({ identity_token: token, ...extra }, headers);
    return { status, body };
  };
  return state;
}
const invalid = { status: 401, body: { success: false, error: 'Sign-in could not be verified', code: 'invalid_identity_token' } };
const keysUnavailable = { status: 503, body: { success: false, error: 'Sign-in is temporarily unavailable. Try again.', code: 'central_keys_unavailable' } };
const notConfigured = { status: 503, body: { success: false, error: 'Central sign-in is not available at this facility', code: 'central_unavailable' } };

test('a good token reaches the RPC with the verified identity and its login answer comes back', async () => {
  const h = harness();
  const token = await sign(claims(START, { name: 'Asha Central' }));
  const answered = await h.call({ identity_token: token, display_name: 'Asha' }, { 'CF-Connecting-IP': '203.0.113.9' });
  assert.equal(answered.status, 200);
  assert.deepEqual(answered.body, loginAnswer);
  assert.equal(answered.headers.get('Cache-Control'), 'no-store');
  assert.equal(answered.headers.get('Content-Type'), 'application/json');
  assert.equal(h.rpcCalls.length, 1);
  const [call] = h.rpcCalls;
  assert.deepEqual(call.body, {
    p_issuer: ISSUER, p_subject: 'central-user-0001', p_phone_number: '919000000101', p_token_id: 'token-id-0000000000000001',
    // exp plus the 30 s tolerance: the single-use record lasts as long as the token is acceptable.
    p_token_expires_at: new Date(START + 330_000).toISOString(),
    p_name: 'Asha Central', p_display_name: 'Asha', p_ip_address: '203.0.113.9', p_otp_code: null,
  });
  assert.equal(call.method, 'POST');
  assert.equal(call.redirect, 'error');
  assert.equal(call.headers.apikey, 'unit-test-service-key');
  assert.equal(call.headers.Authorization, 'Bearer unit-test-service-key');
  // The key set was fetched once, without following redirects.
  assert.equal(h.jwksFetches.length, 1);
  assert.equal(h.jwksFetches[0].redirect, 'error');
  assert.ok(h.jwksFetches[0].signal instanceof AbortSignal);
});

test('with SUPABASE_REST_URL set the RPC goes to PostgREST directly, with the same two headers and no client address header', async () => {
  const h = harness({ env: { ...environment, SUPABASE_REST_URL: 'http://rest:3000/' } });
  const answered = await h.call({ identity_token: await sign(claims(START)) }, { 'CF-Connecting-IP': '203.0.113.9' });
  assert.equal(answered.status, 200);
  assert.equal(h.rpcCalls.length, 1);
  assert.deepEqual(Object.keys(h.rpcCalls[0].headers).sort(), ['Authorization', 'Content-Type', 'apikey']);
  assert.equal(h.rpcCalls[0].body.p_ip_address, '203.0.113.9');
});

test('names: the body wins over the token, and a missing or malformed address is not passed on', async () => {
  const h = harness();
  await h.exchange(await sign(claims(START, { name: 'Asha Central' })), { name: 'Asha Typed' }, { 'CF-Connecting-IP': 'not an address' });
  assert.equal(h.rpcCalls[0].body.p_name, 'Asha Typed');
  assert.equal(h.rpcCalls[0].body.p_display_name, null);
  assert.equal(h.rpcCalls[0].body.p_ip_address, null);
  await h.exchange(await sign(claims(START, { jti: 'token-id-0000000000000002' })), { name: 7, display_name: {} });
  assert.equal(h.rpcCalls[1].body.p_name, null);
  assert.equal(h.rpcCalls[1].body.p_display_name, null);
});

test('otp_code is passed on for the facility\'s own code, and only when it is six digits', async () => {
  const h = harness();
  assert.equal((await h.exchange(await sign(claims(START)), { otp_code: '012345' })).status, 200);
  assert.equal(h.rpcCalls[0].body.p_otp_code, '012345');
  // The two-step flow where the facility asks for its own code: link_required first, then a fresh token with the code.
  h.rpcAnswer = { success: false, code: 'link_required' };
  const asked = await h.exchange(await sign(claims(START, { jti: 'token-id-0000000000000002' })));
  assert.equal(asked.status, 409);
  assert.equal(asked.body.code, 'link_required');
  assert.equal(h.rpcCalls[1].body.p_otp_code, null);
  h.rpcAnswer = loginAnswer;
  assert.deepEqual(await h.exchange(await sign(claims(START, { jti: 'token-id-0000000000000003' })), { otp_code: '654321' }), { status: 200, body: loginAnswer });
  assert.equal(h.rpcCalls[2].body.p_otp_code, '654321');
  assert.equal(h.rpcCalls[2].body.p_token_id, 'token-id-0000000000000003');
  // The code is not logged.
  h.rpcAnswer = { success: false, code: 'invalid_otp' };
  await h.exchange(await sign(claims(START, { jti: 'token-id-0000000000000004' })), { otp_code: '654321' });
  assert.ok(!h.logs.join('\n').includes('654321'));
});

test('the pending answer comes back unchanged, and an audience list of this facility alone is accepted', async () => {
  const h = harness({ rpcAnswer: pendingAnswer });
  const token = await sign(claims(START, { aud: [FACILITY] }));
  assert.deepEqual(await h.exchange(token), { status: 200, body: pendingAnswer });
});

test('not configured: either setting empty, or not an operator production instance, gives 503 without any fetch', async () => {
  const token = await sign(claims(START));
  for (const changes of [{ CENTRAL_ISSUER: '' }, { CENTRAL_JWKS_URL: '' }, { CENTRAL_JWKS_URL: '', CENTRAL_JWKS_FILE: '' },
    { CENTRAL_JWKS_URL: undefined, CENTRAL_JWKS_JSON: JSON.stringify({ keys: [first.jwk] }) },
    { CENTRAL_ISSUER: undefined, CENTRAL_JWKS_URL: undefined },
    { AUTH_MODE: 'demo' }, { APP_ENV: 'development' }]) {
    const h = harness({ env: { ...environment, ...changes } });
    assert.deepEqual(await h.exchange(token), notConfigured, JSON.stringify(changes));
    assert.equal(h.jwksFetches.length + h.rpcCalls.length, 0, 'a closed gate makes no outbound call');
  }
});

test('refuses other methods (a preflight too: the gateway answers it) and bodies without a token', async () => {
  const h = harness();
  const preflight = await handle(new Request('http://edge.test/central-exchange', { method: 'OPTIONS' }), { env: () => undefined });
  assert.equal(preflight.status, 405);
  assert.equal(preflight.headers.get('Access-Control-Allow-Origin'), null, 'the function sets no CORS header');
  assert.deepEqual((({ status, body }) => ({ status, body }))(await h.call(undefined, {}, 'GET')), { status: 405, body: { success: false, error: 'Method not allowed' } });
  const badRequest = { status: 400, body: { success: false, error: 'Invalid request', code: 'invalid_request' } };
  for (const body of ['{', '[]', {}, { identity_token: 7 }, { identity_token: '' }, { identity_token: 'x'.repeat(9000) },
    // otp_code, when present, is exactly six digits.
    ...['12345', '1234567', 'abcdef', ' 123456', '', 123456, null, ['123456']].map(otp_code => ({ identity_token: 'a.b.c', otp_code }))]) {
    assert.deepEqual((({ status, body: answer }) => ({ status, body: answer }))(await h.call(body)), badRequest, JSON.stringify(body).slice(0, 40));
  }
  assert.equal(h.jwksFetches.length + h.rpcCalls.length, 0);
});

test('every invalid token gets the same 401 and never reaches the database', async () => {
  const h = harness();
  const hs256Secret = new TextEncoder().encode(await exportSPKI(first.publicKey));
  const cases = {
    'not a token': 'not-a-token',
    'wrong iss': await sign(claims(START, { iss: 'https://other-issuer.example.test' })),
    'iss with a trailing slash': await sign(claims(START, { iss: `${ISSUER}/` })),
    'wrong aud': await sign(claims(START, { aud: 'https://another-facility.example.test' })),
    'aud list without this facility': await sign(claims(START, { aud: ['https://another-facility.example.test'] })),
    // A token is for ONE facility: this origin next to another audience is refused.
    'aud list with this facility and another': await sign(claims(START, { aud: ['https://another-facility.example.test', FACILITY] })),
    'aud list with this facility first and another': await sign(claims(START, { aud: [FACILITY, 'https://another-facility.example.test'] })),
    'aud list naming this facility twice': await sign(claims(START, { aud: [FACILITY, FACILITY] })),
    'aud with a trailing slash': await sign(claims(START, { aud: `${FACILITY}/` })),
    'missing aud': await sign(claims(START, { aud: undefined })),
    'expired beyond the tolerance': await sign(claims(START - 400_000, { exp: seconds(START) - 31 })),
    'issued in the future': await sign(claims(START + 120_000)),
    'lifetime over 600 s': await sign(claims(START, { exp: seconds(START) + 601 })),
    'missing exp': await sign(claims(START, { exp: undefined })),
    'missing iat': await sign(claims(START, { iat: undefined })),
    'alg HS256 signed with the public key bytes': await new SignJWT(claims(START))
      .setProtectedHeader({ alg: 'HS256', typ: TOKEN_TYPE, kid: first.kid }).sign(hs256Secret),
    'alg none': `${encode({ alg: 'none', typ: TOKEN_TYPE, kid: first.kid })}.${encode(claims(START))}.`,
    'wrong typ': await sign(claims(START), first, { typ: 'JWT' }),
    'typ with the application/ prefix': await sign(claims(START), first, { typ: `application/${TOKEN_TYPE}` }),
    'missing typ': await sign(claims(START), first, { typ: undefined }),
    'missing kid': await sign(claims(START), first, { kid: undefined }),
    'missing phone_number_verified': await sign(claims(START, { phone_number_verified: undefined })),
    'false phone_number_verified': await sign(claims(START, { phone_number_verified: false })),
    'phone_number_verified as text': await sign(claims(START, { phone_number_verified: 'true' })),
    'bad sub': await sign(claims(START, { sub: 'has spaces' })),
    'long sub': await sign(claims(START, { sub: 'a'.repeat(65) })),
    'missing sub': await sign(claims(START, { sub: undefined })),
    'short jti': await sign(claims(START, { jti: 'short' })),
    'bad jti': await sign(claims(START, { jti: 'token id 0000000000000001' })),
    'missing jti': await sign(claims(START, { jti: undefined })),
    'ten-digit phone': await sign(claims(START, { phone_number: '9000000101' })),
    'phone with a plus': await sign(claims(START, { phone_number: '+919000000101' })),
    'missing phone': await sign(claims(START, { phone_number: undefined })),
    'name that is not text': await sign(claims(START, { name: { first: 'Asha' } })),
    'signed by another key with the same key id': await sign(claims(START), stranger),
  };
  for (const [label, token] of Object.entries(cases)) {
    assert.deepEqual(await h.exchange(token), invalid, label);
  }
  assert.equal(h.rpcCalls.length, 0, 'no refused token reached the RPC');
  // The reason is logged for the operator, one line per refusal.
  assert.equal(h.logs.length, Object.keys(cases).length);
  for (const line of h.logs) assert.match(line, /^central-exchange: identity token refused \([A-Za-z_ ]+\)$/);
  // A changed payload under a good signature is refused as well.
  const [head, , signature] = (await sign(claims(START))).split('.');
  assert.deepEqual(await h.exchange(`${head}.${encode(claims(START, { sub: 'someone-else' }))}.${signature}`), invalid);
});

test('the clock tolerance is 30 seconds on both ends and the lifetime limit is exact', async () => {
  const h = harness();
  const justExpired = await sign(claims(START - 300_000, { exp: seconds(START) - 29, jti: 'token-id-000000000000000a' }));
  assert.equal((await h.exchange(justExpired)).status, 200);
  const slightlyAhead = await sign(claims(START + 29_000, { jti: 'token-id-000000000000000b' }));
  assert.equal((await h.exchange(slightlyAhead)).status, 200);
  const tenMinutes = await sign(claims(START, { exp: seconds(START) + 600, jti: 'token-id-000000000000000c' }));
  assert.equal((await h.exchange(tenMinutes)).status, 200);
  assert.equal(h.rpcCalls.length, 3);
});

test('an unknown key id triggers one refetch, succeeds when the new key set has it, and is not refetched again within a minute', async () => {
  const h = harness();
  assert.equal((await h.exchange(await sign(claims(START)))).status, 200);
  assert.equal(h.jwksFetches.length, 1);
  // Keys are kept: a second token of the same key causes no fetch.
  h.now = START + 3 * 60_000;
  assert.equal((await h.exchange(await sign(claims(h.now, { jti: 'token-id-0000000000000002' })))).status, 200);
  assert.equal(h.jwksFetches.length, 1);
  // The issuer rotates; a token names the new key id.
  h.keySet = { keys: [first.jwk, second.jwk] };
  assert.equal((await h.exchange(await sign(claims(h.now, { jti: 'token-id-0000000000000003' }), second))).status, 200);
  assert.equal(h.jwksFetches.length, 2, 'the unknown key id caused one refetch');
  // A key id nobody published: no further fetch within the minute, and the token is refused.
  const unpublished = await signingKey('key-nobody-published');
  h.now += 30_000;
  assert.deepEqual(await h.exchange(await sign(claims(h.now), unpublished)), invalid);
  assert.deepEqual(await h.exchange(await sign(claims(h.now), unpublished)), invalid);
  assert.equal(h.jwksFetches.length, 2, 'no refetch within a minute of the last one');
  // After the minute one more fetch is allowed; the key is still not there.
  h.now += 31_000;
  assert.deepEqual(await h.exchange(await sign(claims(h.now), unpublished)), invalid);
  assert.equal(h.jwksFetches.length, 3);
  assert.deepEqual(await h.exchange(await sign(claims(h.now), unpublished)), invalid);
  assert.equal(h.jwksFetches.length, 3);
  // Four minutes after the last fetch the keys are fetched again even for a known key id.
  h.now += 4 * 60_000;
  assert.equal((await h.exchange(await sign(claims(h.now, { jti: 'token-id-0000000000000004' })))).status, 200);
  assert.equal(h.jwksFetches.length, 4);
  // A key the issuer withdrew is no longer accepted after that refetch.
  h.keySet = { keys: [second.jwk] };
  h.now += 4 * 60_000;
  assert.deepEqual(await h.exchange(await sign(claims(h.now, { jti: 'token-id-0000000000000005' }))), invalid);
  assert.equal(h.rpcCalls.length, 4);
});

const FOUR_MINUTES = 4 * 60_000;

test('a key the issuer withdrew is refused four minutes after the fetch that held it: one ms earlier it still verifies, with no fetch', async () => {
  const h = harness();
  assert.equal((await h.exchange(await sign(claims(START)))).status, 200);
  assert.equal(h.jwksFetches.length, 1);
  // The issuer now serves a set without the first key; this facility has not asked yet.
  h.keySet = { keys: [second.jwk] };
  h.now = START + FOUR_MINUTES - 1;
  assert.equal((await h.exchange(await sign(claims(h.now, { jti: 'token-id-0000000000000002' })))).status, 200);
  assert.equal(h.jwksFetches.length, 1, 'one ms before the bound the cached keys are used and nothing is fetched');
  h.now = START + FOUR_MINUTES;
  assert.deepEqual(await h.exchange(await sign(claims(h.now, { jti: 'token-id-0000000000000003' }))), invalid);
  assert.equal(h.jwksFetches.length, 2, 'at the bound exactly one refetch');
  assert.equal(h.rpcCalls.length, 2);
  // The next refusal comes from the new set; no further fetch for the same known-key-id miss within the minute.
  assert.deepEqual(await h.exchange(await sign(claims(h.now, { jti: 'token-id-0000000000000004' }))), invalid);
  assert.equal(h.jwksFetches.length, 2);
});

test('the key set is fetched without any cache on the way: no-store, and a no-cache request header', async () => {
  const h = harness();
  assert.equal((await h.exchange(await sign(claims(START)))).status, 200);
  const [init] = h.jwksFetches;
  assert.equal(init.cache, 'no-store');
  assert.equal(init.headers['Cache-Control'], 'no-cache');
  assert.equal(init.headers.Accept, 'application/json');
  assert.equal(init.redirect, 'error');
  // The refetch after the bound asks the same way.
  h.now = START + FOUR_MINUTES;
  assert.equal((await h.exchange(await sign(claims(h.now, { jti: 'token-id-0000000000000002' })))).status, 200);
  assert.equal(h.jwksFetches.length, 2);
  assert.equal(h.jwksFetches[1].cache, 'no-store');
  assert.equal(h.jwksFetches[1].headers['Cache-Control'], 'no-cache');
});

test('the issuer\'s max-age less the Age of the answer shortens the window and never lengthens it', async () => {
  const set = headers => () => new Response(JSON.stringify({ keys: [first.jwk] }), { headers: { 'Content-Type': 'application/json', ...headers } });
  const cases = [
    { label: 'max-age 300 alone: the 4 minute limit', headers: { 'Cache-Control': 'public, max-age=300, s-maxage=0' }, window: FOUR_MINUTES },
    { label: 'max-age 300, Age 100: 200 s left', headers: { 'Cache-Control': 'public, max-age=300', Age: '100' }, window: 200_000 },
    { label: 'max-age 120, Age 30: 90 s left', headers: { 'Cache-Control': 'max-age=120', Age: '30' }, window: 90_000 },
    { label: 'max-age 120 without Age', headers: { 'Cache-Control': 'max-age=120' }, window: 120_000 },
    { label: 'max-age 3600: still the 4 minute limit', headers: { 'Cache-Control': 'max-age=3600' }, window: FOUR_MINUTES },
    { label: 'Age without max-age is ignored', headers: { Age: '100' }, window: FOUR_MINUTES },
    { label: 'no Cache-Control at all', headers: {}, window: FOUR_MINUTES },
    { label: 'a max-age that is not a number is ignored', headers: { 'Cache-Control': 'max-age=abc' }, window: FOUR_MINUTES },
    { label: 'an Age that is not a number is ignored', headers: { 'Cache-Control': 'max-age=100', Age: 'x' }, window: 100_000 },
    { label: 'Age as long as max-age: no reuse', headers: { 'Cache-Control': 'max-age=60', Age: '60' }, window: 0 },
    { label: 'Age longer than max-age: no reuse', headers: { 'Cache-Control': 'max-age=60', Age: '500' }, window: 0 },
    { label: 'max-age 0: no reuse', headers: { 'Cache-Control': 'max-age=0' }, window: 0 },
  ];
  for (const { label, headers, window } of cases) {
    const h = harness({ keySet: set(headers) });
    assert.equal((await h.exchange(await sign(claims(START)))).status, 200, label);
    assert.equal(h.jwksFetches.length, 1, label);
    if (window > 0) {
      h.now = START + window - 1;
      assert.equal((await h.exchange(await sign(claims(h.now, { jti: 'token-id-0000000000000002' })))).status, 200, label);
      assert.equal(h.jwksFetches.length, 1, `${label}: one ms before the bound, no fetch`);
    }
    h.now = START + window;
    assert.equal((await h.exchange(await sign(claims(h.now, { jti: 'token-id-0000000000000003' })))).status, 200, label);
    assert.equal(h.jwksFetches.length, 2, `${label}: at the bound, one refetch`);
  }
});

test('requests that arrive together share one key fetch', async () => {
  const h = harness();
  const tokens = await Promise.all([1, 2, 3].map(n => sign(claims(START, { jti: `token-id-000000000000001${n}` }))));
  const answered = await Promise.all(tokens.map(token => h.exchange(token)));
  assert.deepEqual(answered.map(({ status }) => status), [200, 200, 200]);
  assert.equal(h.jwksFetches.length, 1);
});

test('only public P-256 signature keys of the set are used', async () => {
  const { publicKey: rsaPublic } = await generateKeyPair('RS256', { extractable: true });
  const p384 = await generateKeyPair('ES384', { extractable: true });
  const privateJwk = { ...(await exportJWK(second.privateKey)), kid: second.kid };
  const encryption = { ...first.jwk, kid: 'enc-key', use: 'enc' };
  const h = harness({ keySet: { keys: [
    { ...(await exportJWK(rsaPublic)), kid: 'rsa' }, { ...(await exportJWK(p384.publicKey)), kid: 'p384' },
    privateJwk, encryption, { ...first.jwk, kid: undefined }, null, 'text', first.jwk,
  ] } });
  assert.equal((await h.exchange(await sign(claims(START)))).status, 200);
  // A key published with its private part is not trusted.
  assert.deepEqual(await h.exchange(await sign(claims(START, { jti: 'token-id-0000000000000002' }), second)), invalid);
  // A set with no usable key at all is a key failure, not a token failure.
  const none = harness({ keySet: { keys: [encryption, privateJwk] } });
  assert.deepEqual(await none.exchange(await sign(claims(START))), keysUnavailable);
});

test('keys that cannot be fetched give central_keys_unavailable and nothing reaches the database', async () => {
  const token = await sign(claims(START));
  const big = JSON.stringify({ keys: [first.jwk], padding: 'x'.repeat(64 * 1024) });
  const keySets = {
    'over 64 KB, declared': new Response(big, { headers: { 'Content-Type': 'application/json', 'Content-Length': String(big.length) } }),
    'over 64 KB, streamed': () => new Response(new ReadableStream({
      start(controller) { controller.enqueue(new TextEncoder().encode(big)); controller.close(); },
    })),
    'non-200': Response.json({ keys: [first.jwk] }, { status: 404 }),
    '204 without a body': new Response(null, { status: 204 }),
    'a fetch that throws': new TypeError('fetch failed'),
    'not JSON': new Response('<html>'),
    'no keys member': { jwks: [first.jwk] },
  };
  for (const [label, keySet] of Object.entries(keySets)) {
    const h = harness({ keySet });
    assert.deepEqual(await h.exchange(token), keysUnavailable, label);
    assert.equal(h.jwksFetches.length, 1, label);
    assert.equal(h.rpcCalls.length, 0, label);
    assert.match(h.logs[0], /^central-exchange: keys unavailable \(/, label);
    // After a failed fetch none is started for 30 seconds, so callers cannot drive requests to the issuer while it is down.
    h.keySet = { keys: [first.jwk] };
    h.now += 29_000;
    assert.deepEqual(await h.exchange(token), keysUnavailable, `${label}: within the back-off`);
    assert.deepEqual(await h.exchange(token), keysUnavailable, `${label}: within the back-off`);
    assert.equal(h.jwksFetches.length, 1, `${label}: no fetch during the back-off`);
    assert.match(h.logs.at(-1), /keys unavailable \(waiting after a failed fetch\)/, label);
    h.now += 2_000;
    assert.equal((await h.exchange(token)).status, 200, `${label}: recovery`);
    assert.equal(h.jwksFetches.length, 2, label);
  }
  // A key address or issuer that is not https is never fetched.
  for (const changes of [{ CENTRAL_JWKS_URL: 'http://login.association.example.test/jwks.json' }, { CENTRAL_JWKS_URL: 'file:///etc/passwd' },
    { CENTRAL_JWKS_URL: 'https://user:secret@login.association.example.test/jwks.json' }, { CENTRAL_ISSUER: 'http://login.association.example.test' }]) {
    const h = harness({ env: { ...environment, ...changes } });
    assert.deepEqual(await h.exchange(token), keysUnavailable, JSON.stringify(changes));
    assert.equal(h.jwksFetches.length + h.rpcCalls.length, 0, JSON.stringify(changes));
  }
  // A refetch for an unknown key id that fails says "try again"; the keys already held stay in use.
  const h = harness();
  assert.equal((await h.exchange(token)).status, 200);
  h.now += 61_000;
  h.keySet = new TypeError('fetch failed');
  assert.deepEqual(await h.exchange(await sign(claims(h.now), second)), keysUnavailable);
  h.now += 1_000;
  assert.equal((await h.exchange(await sign(claims(h.now, { jti: 'token-id-0000000000000002' })))).status, 200);
  assert.equal(h.jwksFetches.length, 2, 'a key already held needs no fetch during the back-off');
  // Stale keys (older than ten minutes) are not used while the refetch is failing or waiting.
  const stale = harness();
  assert.equal((await stale.exchange(token)).status, 200);
  stale.now += 10 * 60_000;
  stale.keySet = new TypeError('fetch failed');
  assert.deepEqual(await stale.exchange(await sign(claims(stale.now, { jti: 'token-id-0000000000000003' }))), keysUnavailable);
  stale.now += 10_000;
  assert.deepEqual(await stale.exchange(await sign(claims(stale.now, { jti: 'token-id-0000000000000004' }))), keysUnavailable);
  assert.equal(stale.jwksFetches.length, 2);
  assert.equal(stale.rpcCalls.length, 1);
});

test('a key set that names one key id twice is unusable', async () => {
  // Which of the two keys signs would be ambiguous (jose refuses such a set at verification);
  // the fault is the issuer's key set, not the caller's token.
  const twin = { ...stranger.jwk };
  for (const keys of [[first.jwk, twin], [twin, first.jwk], [first.jwk, { ...first.jwk }], [first.jwk, second.jwk, { ...second.jwk }]]) {
    const h = harness({ keySet: { keys } });
    assert.deepEqual(await h.exchange(await sign(claims(START))), keysUnavailable);
    assert.match(h.logs[0], /keys unavailable \(key set names a key id twice\)/);
    assert.equal(h.rpcCalls.length, 0);
  }
  // A duplicate among keys that are not used anyway does not matter.
  const h = harness({ keySet: { keys: [first.jwk, { ...second.jwk, use: 'enc' }, { ...second.jwk, use: 'enc' }] } });
  assert.equal((await h.exchange(await sign(claims(START)))).status, 200);
});

test('keys from a file of the installation: no fetch at all, the same filtering, an unknown key id is an invalid token', async () => {
  const fileEnv = (text, extra = {}) => ({ ...environment, CENTRAL_JWKS_URL: '', CENTRAL_JWKS_FILE: 'central-jwks.json', CENTRAL_JWKS_JSON: text, ...extra });
  const text = JSON.stringify({ keys: [first.jwk] });
  const h = harness({ env: fileEnv(text) });
  assert.deepEqual(await h.exchange(await sign(claims(START))), { status: 200, body: loginAnswer });
  assert.equal(h.rpcCalls[0].body.p_subject, 'central-user-0001');
  // A key id the file does not hold is simply an invalid token; nothing is fetched, ever.
  assert.deepEqual(await h.exchange(await sign(claims(START), second)), invalid);
  h.now += 61_000;
  assert.deepEqual(await h.exchange(await sign(claims(h.now), second)), invalid);
  assert.deepEqual(await h.exchange(await sign(claims(h.now), stranger)), invalid);
  h.now += 20 * 60_000;
  assert.equal((await h.exchange(await sign(claims(h.now, { jti: 'token-id-0000000000000002' })))).status, 200, 'file keys do not expire');
  assert.equal(h.jwksFetches.length, 0);
  // The file wins when an address is configured as well: still no fetch.
  const both = harness({ env: fileEnv(text, { CENTRAL_JWKS_URL: JWKS }), keySet: { keys: [second.jwk] } });
  assert.equal((await both.exchange(await sign(claims(START)))).status, 200);
  assert.deepEqual(await both.exchange(await sign(claims(START), second)), invalid);
  assert.equal(both.jwksFetches.length, 0);
  // A file that is missing (the router passed no text) or unusable: keys unavailable, no fetch, nothing reaches the database.
  const privateJwk = { ...(await exportJWK(first.privateKey)), kid: first.kid };
  const unusable = {
    'missing': undefined, 'empty': '', 'not JSON': '<html>', 'no keys member': '{"jwks":[]}',
    'only a private key': JSON.stringify({ keys: [privateJwk] }),
    'a key id twice': JSON.stringify({ keys: [first.jwk, { ...stranger.jwk }] }),
    'over 64 KB': JSON.stringify({ keys: [first.jwk], padding: 'x'.repeat(64 * 1024) }),
  };
  for (const [label, value] of Object.entries(unusable)) {
    const broken = harness({ env: fileEnv(value) });
    assert.deepEqual(await broken.exchange(await sign(claims(START))), keysUnavailable, label);
    assert.equal(broken.jwksFetches.length + broken.rpcCalls.length, 0, label);
    assert.match(broken.logs[0], /^central-exchange: keys unavailable \(/, label);
  }
  // The issuer must be https with a file as well; and a file name without an issuer is not a configuration.
  const plain = harness({ env: fileEnv(text, { CENTRAL_ISSUER: 'http://login.association.example.test' }) });
  assert.deepEqual(await plain.exchange(await sign(claims(START))), keysUnavailable);
  const noIssuer = harness({ env: fileEnv(text, { CENTRAL_ISSUER: '' }) });
  assert.deepEqual(await noIssuer.exchange(await sign(claims(START))), notConfigured);
});

test('each failure code of the RPC maps to its status and message', async () => {
  const expected = {
    central_unavailable: notConfigured,
    invalid_identity_token: invalid,
    identity_token_used: { status: 401, body: { success: false, error: 'Sign-in could not be verified', code: 'identity_token_used' } },
    account_unavailable: { status: 403, body: { success: false, error: 'Account unavailable', code: 'account_unavailable' } },
    identity_conflict: { status: 409, body: { success: false,
      error: 'This phone number is linked to another sign-in. Ask the facility administrator.', code: 'identity_conflict' } },
    enrollment_limited: { status: 429, body: { success: false, error: 'Too many new access requests. Try again tomorrow.', code: 'enrollment_limited' } },
    link_required: { status: 409, body: { success: false,
      error: 'This facility asks for its own code each time you sign in.', code: 'link_required' } },
    // What the SMS check answered for otp_code, with operator-otp's texts.
    invalid_otp: { status: 400, body: { success: false, error: 'Invalid or expired OTP', code: 'invalid_otp' } },
    rate_limited: { status: 429, body: { success: false, error: 'Too many OTP requests. Try again later.', code: 'rate_limited' } },
  };
  const unavailable = { status: 503, body: { success: false, error: 'Authentication service unavailable', code: 'unavailable' } };
  const token = await sign(claims(START));
  for (const [code, answer] of Object.entries(expected)) {
    const h = harness({ rpcAnswer: { success: false, code } });
    assert.deepEqual(await h.exchange(token), answer, code);
  }
  for (const rpcAnswer of [{ success: false }, { success: false, code: 'something_new' }, { success: false, code: 'constructor' },
    new Response('upstream error', { status: 500 }), new TypeError('fetch failed')]) {
    const h = harness({ rpcAnswer });
    assert.deepEqual(await h.exchange(token), unavailable);
  }
  // Without the database credential nothing is sent.
  const h = harness({ env: { ...environment, SUPABASE_SERVICE_ROLE_KEY: undefined } });
  assert.deepEqual(await h.exchange(token), unavailable);
  assert.equal(h.rpcCalls.length, 0);
});

test('the token text never appears in a response or in what the handler logs', async () => {
  const good = await sign(claims(START));
  const wrongAudience = await sign(claims(START, { aud: 'https://another-facility.example.test' }));
  const expired = await sign(claims(START - 900_000));
  const otherKey = await sign(claims(START), stranger);
  const unknownKid = await sign(claims(START), second);
  const tokens = [good, wrongAudience, expired, otherKey, unknownKid];
  const runs = [
    harness(), harness({ rpcAnswer: pendingAnswer }), harness({ rpcAnswer: { success: false, code: 'identity_token_used' } }),
    harness({ rpcAnswer: { success: false, code: 'identity_conflict' } }), harness({ rpcAnswer: new TypeError('fetch failed') }),
    harness({ keySet: new TypeError('fetch failed') }), harness({ env: { ...environment, CENTRAL_ISSUER: '' } }),
  ];
  let logged = 0;
  for (const h of runs) {
    for (const token of tokens) await h.exchange(token);
    const written = [...h.responses, ...h.logs].join('\n');
    logged += h.logs.length;
    for (const token of tokens) {
      for (const part of [token, ...token.split('.')]) assert.ok(!written.includes(part), 'a token part was written out');
    }
    // Nor the identity the token carried, beyond what the database itself answered.
    assert.ok(!h.logs.join('\n').includes('919000000101') && !h.logs.join('\n').includes('central-user-0001'));
  }
  assert.ok(logged > 10, 'the refusals were logged');
});

test('get-public-config advertises central sign-in only where a token could be accepted', () => {
  const on = { authMode: 'operator', appEnv: 'production', issuer: ISSUER, jwksUrl: JWKS, jwksFile: '' };
  assert.equal(advertisedCentralIssuer(on), ISSUER);
  assert.equal(advertisedCentralIssuer({ ...on, jwksUrl: '', jwksFile: 'central-jwks.json' }), ISSUER);
  assert.equal(advertisedCentralIssuer({ ...on, jwksUrl: undefined, jwksFile: 'central-jwks.json' }), ISSUER);
  for (const changes of [{ issuer: '' }, { issuer: undefined }, { jwksUrl: '' }, { jwksUrl: undefined, jwksFile: undefined },
    { authMode: 'demo' }, { appEnv: 'development' }, { appEnv: undefined },
    // A value that is not https is not advertised: the exchange would answer "keys unavailable".
    { issuer: 'http://login.association.example.test' }, { issuer: 'login.association.example.test' },
    { issuer: 'http://login.association.example.test', jwksUrl: '', jwksFile: 'central-jwks.json' },
    { jwksUrl: 'http://login.association.example.test/jwks.json' }, { jwksUrl: 'file:///etc/passwd' },
    { jwksUrl: 'https://user:secret@login.association.example.test/jwks.json' }]) {
    assert.equal(advertisedCentralIssuer({ ...on, ...changes }), null, JSON.stringify(changes));
  }
  // centralLogin.localCode (migration 81): only 'on' is true, and only next to an advertised issuer.
  assert.deepEqual(advertisedCentralLogin(on), { issuer: ISSUER, localCode: false });
  assert.deepEqual(advertisedCentralLogin({ ...on, localCode: '' }), { issuer: ISSUER, localCode: false });
  assert.deepEqual(advertisedCentralLogin({ ...on, localCode: 'off' }), { issuer: ISSUER, localCode: false });
  assert.deepEqual(advertisedCentralLogin({ ...on, localCode: 'ON' }), { issuer: ISSUER, localCode: false });
  assert.deepEqual(advertisedCentralLogin({ ...on, localCode: 'on' }), { issuer: ISSUER, localCode: true });
  assert.equal(advertisedCentralLogin({ ...on, localCode: 'on', issuer: '' }), null);
  assert.equal(advertisedCentralLogin({ ...on, localCode: 'on', authMode: 'demo' }), null);
  for (const value of [undefined, '', 'https://', 'HTTPS://login.example.test', ' https://login.example.test', 'https://user@login.example.test']) {
    assert.equal(httpsAddress(value), false, String(value));
  }
  assert.equal(httpsAddress('https://login.example.test/path?x=1'), true);
});
