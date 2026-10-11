import { test } from 'node:test';
import assert from 'node:assert/strict';
import { handle } from '../functions/operator-otp/handler.ts';

// No network: every outbound call (PostgREST RPC and MSG91) goes to this stand-in.
const environment = {
  AUTH_MODE: 'operator', APP_ENV: 'production',
  SUPABASE_URL: 'http://rest.test', SUPABASE_SERVICE_ROLE_KEY: 'unit-test-service-key',
};
const requestId = '00000000-0000-4000-8000-0000000000aa';
const prepared = { success: true, data: { request_id: requestId, phone_number: '919888888801', otp_code: '123456', expires_at: '2026-10-10T10:05:00Z' } };
const smsConfig = { success: true, data: { auth_key: 'unit-test-auth-key', flow_id: 'unit-test-flow' } };

function harness(overrides = {}, env = environment) {
  const calls = [];
  const answers = {
    operator_prepare_otp: prepared, operator_sms_config: smsConfig, operator_finish_otp: { success: true },
    operator_verify_otp: { success: true, data: { action: 'login' } },
    operator_enrollment_status: { success: true, data: { status: 'pending' } },
    operator_enrollment_signout: { success: true },
    msg91: Response.json({ type: 'success', message: 'provider-request-id' }),
    ...overrides,
  };
  const fetchStub = async (url, init) => {
    const target = String(url);
    if (target === 'https://control.msg91.com/api/v5/flow/') {
      calls.push({ name: 'msg91', body: JSON.parse(init.body) });
      const answer = answers.msg91;
      if (answer instanceof Error) throw answer;
      return answer.clone();
    }
    const match = /^http:\/\/rest\.test\/rest\/v1\/rpc\/([a-z_0-9]+)$/.exec(target);
    assert.ok(match, `unexpected outbound request: ${target}`);
    calls.push({ name: match[1], body: JSON.parse(init.body), headers: init.headers, method: init.method, redirect: init.redirect });
    const answer = answers[match[1]];
    return answer instanceof Response ? answer.clone() : Response.json(answer);
  };
  const call = (operation, body, headers = {}, method = 'POST') => handle(
    new Request(`http://edge.test/operator-otp/${operation}`, {
      method, headers: { 'Content-Type': 'application/json', ...headers },
      body: method === 'POST' ? (typeof body === 'string' ? body : JSON.stringify(body)) : undefined,
    }),
    { env: name => env[name], fetch: fetchStub },
  );
  return { calls, call };
}
const bodyOf = async response => ({ status: response.status, body: await response.json() });
const phone = { phone_number: '9888888801' };
const token = 'a'.repeat(64);

test('is unavailable unless AUTH_MODE is operator and APP_ENV is production', async () => {
  for (const env of [{ ...environment, AUTH_MODE: undefined }, { ...environment, AUTH_MODE: 'demo' },
    { ...environment, APP_ENV: 'development' }, {}]) {
    const { calls, call } = harness({}, env);
    for (const operation of ['request', 'verify', 'status', 'signout']) {
      assert.deepEqual(await bodyOf(await call(operation, { ...phone, otp_code: '123456', enrollment_token: token })),
        { status: 503, body: { success: false, error: 'OTP service unavailable' } });
    }
    assert.equal(calls.length, 0, 'a closed gate makes no backend call');
  }
});

test('answers preflight, refuses other methods and unknown operations', async () => {
  const { calls, call } = harness();
  const preflight = await call('request', undefined, {}, 'OPTIONS');
  assert.equal(preflight.status, 200);
  assert.equal(preflight.headers.get('Access-Control-Allow-Origin'), '*');
  assert.deepEqual(await bodyOf(await call('request', undefined, {}, 'GET')), { status: 405, body: { success: false, error: 'Method not allowed' } });
  for (const operation of ['', 'prepare', 'request/extra', 'operator_verify_otp']) {
    assert.deepEqual(await bodyOf(await call(operation, phone)), { status: 404, body: { success: false, error: 'Not found' } });
  }
  assert.equal(calls.length, 0);
  const answered = await call('request', phone);
  assert.equal(answered.headers.get('Cache-Control'), 'no-store');
  assert.equal(answered.headers.get('Content-Type'), 'application/json');
});

test('routes each operation to its own RPC with the service credential', async () => {
  const { calls, call } = harness();
  assert.equal((await call('verify', { ...phone, otp_code: '123456' })).status, 200);
  assert.equal((await call('status', { enrollment_token: token })).status, 200);
  assert.equal((await call('signout', { enrollment_token: token })).status, 200);
  assert.deepEqual(calls.map(entry => entry.name), ['operator_verify_otp', 'operator_enrollment_status', 'operator_enrollment_signout']);
  assert.deepEqual(calls[1].body, { p_token: token });
  assert.deepEqual(calls[2].body, { p_token: token });
  for (const entry of calls) {
    assert.equal(entry.method, 'POST');
    assert.equal(entry.redirect, 'error');
    assert.equal(entry.headers.apikey, 'unit-test-service-key');
    assert.equal(entry.headers.Authorization, 'Bearer unit-test-service-key');
  }
});

test('passes only a well-formed CF-Connecting-IP to the database, for request and verify', async () => {
  const cases = [
    [{ 'CF-Connecting-IP': '203.0.113.10' }, '203.0.113.10'],
    [{ 'CF-Connecting-IP': '2001:db8::10' }, '2001:db8::10'],
    [{ 'X-Forwarded-For': '203.0.113.10' }, null],
    [{ 'X-Real-IP': '203.0.113.10', Forwarded: 'for=203.0.113.10' }, null],
    [{ 'CF-Connecting-IP': '203.0.113.10, 198.51.100.1' }, null],
    [{ 'CF-Connecting-IP': "203.0.113.10'; DROP" }, null],
    [{ 'CF-Connecting-IP': 'x'.repeat(46) }, null],
    [{}, null],
  ];
  for (const [headers, expected] of cases) {
    const { calls, call } = harness();
    await call('request', phone, headers);
    await call('verify', { ...phone, otp_code: '123456' }, headers);
    assert.equal(calls.find(entry => entry.name === 'operator_prepare_otp').body.p_ip_address, expected, JSON.stringify(headers));
    assert.equal(calls.find(entry => entry.name === 'operator_verify_otp').body.p_ip_address, expected, JSON.stringify(headers));
  }
});

test('checks phone, code and token formats before any backend call', async () => {
  const { calls, call } = harness();
  const invalid = { status: 400, body: { success: false, error: 'Invalid request' } };
  for (const body of [{}, { phone_number: 9888888801 }, { phone_number: '988888880' }, { phone_number: '98888888011' },
    { phone_number: '929888888801' }, { phone_number: '' }, 'not json', '[]', 'null']) {
    assert.deepEqual(await bodyOf(await call('request', body)), invalid, `request ${JSON.stringify(body)}`);
  }
  for (const body of [{ ...phone }, { ...phone, otp_code: 123456 }, { ...phone, otp_code: '12345' }, { ...phone, otp_code: '1234567' },
    { ...phone, otp_code: '12345a' }, { phone_number: '12345', otp_code: '123456' }, { otp_code: '123456' }]) {
    assert.deepEqual(await bodyOf(await call('verify', body)), invalid, `verify ${JSON.stringify(body)}`);
  }
  for (const body of [{}, { enrollment_token: 'A'.repeat(64) }, { enrollment_token: 'a'.repeat(63) }, { enrollment_token: 7 }]) {
    assert.deepEqual(await bodyOf(await call('status', body)), invalid);
    assert.deepEqual(await bodyOf(await call('signout', body)), invalid);
  }
  assert.deepEqual(await bodyOf(await call('request', JSON.stringify({ phone_number: '9888888801', pad: 'x'.repeat(2100) }))), invalid, 'oversized body');
  assert.equal(calls.length, 0);
});

test('normalises the phone and sends only strings as names', async () => {
  const { calls, call } = harness();
  await call('request', { phone_number: '+91 98888-88801' });
  await call('verify', { phone_number: '+91 98888 88801', otp_code: '123456', name: 'Asha Patel', display_name: { nested: true } });
  await call('verify', { ...phone, otp_code: '123456', name: 42 });
  assert.equal(calls[0].body.p_phone_number, '919888888801');
  const verifications = calls.filter(entry => entry.name === 'operator_verify_otp').map(entry => entry.body);
  assert.deepEqual(verifications[0], { p_phone_number: '919888888801', p_otp_code: '123456', p_name: 'Asha Patel', p_display_name: null, p_ip_address: null });
  assert.equal(verifications[1].p_name, null);
});

test('maps each database code to its HTTP status and text', async () => {
  const table = [
    ['rate_limited', 429, 'Too many OTP requests. Try again later.'],
    ['resend_cooldown', 429, 'Please wait before requesting another OTP.'],
    ['enrollment_limited', 429, 'Too many new access requests. Try again tomorrow.'],
    ['account_unavailable', 403, 'Account unavailable'],
    ['invalid_otp', 400, 'Invalid or expired OTP'],
    ['invalid_token', 400, 'Enrollment session expired. Sign in again.'],
    ['unavailable', 503, 'OTP service unavailable'],
    ['invalid_request', 400, 'Invalid request'],
    ['some_future_code', 400, 'Invalid request'],
    [undefined, 400, 'Invalid request'],
  ];
  for (const [code, status, error] of table) {
    const refusal = { success: false, code };
    const { call } = harness({ operator_prepare_otp: refusal, operator_verify_otp: refusal, operator_enrollment_status: refusal });
    for (const [operation, body] of [['request', phone], ['verify', { ...phone, otp_code: '123456' }], ['status', { enrollment_token: token }]]) {
      const answered = await bodyOf(await call(operation, body));
      assert.equal(answered.status, status, `${operation} ${code}`);
      assert.equal(answered.body.success, false);
      assert.equal(answered.body.error, error, `${operation} ${code}`);
    }
  }
});

test('a cooldown answer says how long to wait', async () => {
  const retryAt = new Date(Date.now() + 90_000).toISOString();
  const { calls, call } = harness({ operator_prepare_otp: { success: false, code: 'resend_cooldown', retry_at: retryAt } });
  const response = await call('request', phone);
  const body = await response.json();
  assert.equal(response.status, 429);
  assert.ok(body.retry_after_seconds >= 88 && body.retry_after_seconds <= 91, String(body.retry_after_seconds));
  assert.equal(response.headers.get('Retry-After'), String(body.retry_after_seconds));
  assert.deepEqual(calls.map(entry => entry.name), ['operator_prepare_otp'], 'a refused request sends no SMS');
  const plain = harness({ operator_prepare_otp: { success: false, code: 'rate_limited', retry_at: 'not a date' } });
  const limited = await plain.call('request', phone);
  assert.equal(limited.headers.get('Retry-After'), null);
  assert.deepEqual(await limited.json(), { success: false, error: 'Too many OTP requests. Try again later.' });
});

test('an accepted request prepares, sends, then records delivery, and never returns the code', async () => {
  const { calls, call } = harness();
  const response = await call('request', phone, { 'CF-Connecting-IP': '203.0.113.10' });
  const body = await response.json();
  assert.equal(response.status, 200);
  assert.deepEqual(body, { success: true, data: { request_id: `OTP_${requestId}`, expires_at: prepared.data.expires_at }, message: 'OTP sent successfully' });
  assert.ok(!JSON.stringify(body).includes('123456'));
  assert.deepEqual(calls.map(entry => entry.name), ['operator_prepare_otp', 'operator_sms_config', 'msg91', 'operator_finish_otp']);
  assert.deepEqual(calls[2].body.recipients, [{ mobiles: '919888888801', OTP: '123456' }]);
  assert.equal(calls[2].body.template_id, 'unit-test-flow');
  assert.deepEqual(calls[3].body, { p_request_id: requestId, p_delivered: true, p_provider_id: 'provider-request-id' });
});

test('a provider failure seals the challenge before the 503 is returned', async () => {
  const failures = [
    [{ msg91: Response.json({ type: 'error' }, { status: 401 }) }, 'provider_auth'],
    [{ msg91: Response.json({ type: 'error', message: 'rejected' }) }, 'provider_rejected'],
    [{ msg91: new TypeError('network down') }, 'provider_unavailable'],
    [{ operator_sms_config: { success: false, code: 'unavailable' } }, 'provider_configuration'],
    [{ operator_sms_config: { success: true, data: { auth_key: '', flow_id: '' } } }, 'provider_configuration'],
  ];
  for (const [overrides, expected] of failures) {
    const { calls, call } = harness(overrides);
    const pending = call('request', phone);
    const response = await pending;
    // The finish call is already recorded when the response exists.
    const finish = calls.at(-1);
    assert.equal(finish.name, 'operator_finish_otp', expected);
    assert.deepEqual(finish.body, { p_request_id: requestId, p_delivered: false, p_provider_id: expected });
    assert.deepEqual(await bodyOf(response), { status: 503, body: { success: false, error: 'SMS delivery unavailable. Try again later.' } });
  }
});

test('a delivery that cannot be recorded is not reported as sent', async () => {
  const { call } = harness({ operator_finish_otp: { success: false, code: 'invalid_request' } });
  assert.deepEqual(await bodyOf(await call('request', phone)), { status: 503, body: { success: false, error: 'SMS delivery unavailable. Try again later.' } });
});

test('a database failure or missing credentials answer 503 without detail', async () => {
  const unavailable = { status: 503, body: { success: false, error: 'Authentication service unavailable' } };
  const broken = Response.json({ message: 'relation "secret_table" does not exist' }, { status: 500 });
  for (const [operation, body, rpc] of [['request', phone, 'operator_prepare_otp'], ['verify', { ...phone, otp_code: '123456' }, 'operator_verify_otp'],
    ['status', { enrollment_token: token }, 'operator_enrollment_status'], ['signout', { enrollment_token: token }, 'operator_enrollment_signout']]) {
    assert.deepEqual(await bodyOf(await harness({ [rpc]: broken }).call(operation, body)), unavailable, operation);
  }
  const { calls, call } = harness({}, { AUTH_MODE: 'operator', APP_ENV: 'production' });
  assert.deepEqual(await bodyOf(await call('request', phone)), unavailable);
  assert.equal(calls.length, 0);
});

test('verification answers pass the database result through', async () => {
  const login = { success: true, data: { action: 'login', user: { id: 'u' }, session: { access_token: 'a', refresh_token: 'r' } } };
  const { call } = harness({ operator_verify_otp: login });
  assert.deepEqual(await bodyOf(await call('verify', { ...phone, otp_code: '123456' })), { status: 200, body: login });
});
