import { test } from 'node:test';
import assert from 'node:assert/strict';
import { deliverOtp, Msg91DeliveryError } from '../functions/operator-otp/provider.ts';

const phone = '919888888801';
const code = '123456';
const authKey = 'unit-test-auth-key';
const templateId = 'unit-test-template';

test('submits the approved MSG91 Flow payload and records its request ID', async () => {
  let request;
  const delivery = await deliverOtp(phone, code, authKey, templateId, async (url, init) => {
    request = { url, init };
    return Response.json({ type: 'success', message: 'request-id' });
  });
  assert.deepEqual(delivery, { providerId: 'request-id', attempts: 1 });
  assert.equal(request.url, 'https://control.msg91.com/api/v5/flow/');
  assert.equal(request.init.method, 'POST');
  assert.equal(request.init.redirect, 'error');
  assert.equal(request.init.headers.authkey, authKey);
  assert.deepEqual(JSON.parse(request.init.body), {
    template_id: templateId, short_url: '0', realTimeResponse: '1',
    recipients: [{ mobiles: phone, OTP: code }],
  });
  assert.ok(request.init.signal instanceof AbortSignal);
});

test('normalizes ten-digit numbers and accepts a success without provider request ID', async () => {
  let recipient;
  const delivery = await deliverOtp('9888888801', code, authKey, templateId, async (_url, init) => {
    recipient = JSON.parse(init.body).recipients[0].mobiles;
    return Response.json({ type: 'success' });
  });
  assert.equal(recipient, phone);
  // TW-CFG-003: a success without an ID is a success (the code is treated as sent) with no ID,
  // which the handler passes on as NULL and the database records as success_no_id.
  assert.deepEqual(delivery, { providerId: null, attempts: 1 });
});

test('refuses missing configuration, invalid input and provider rejections', async () => {
  let called = false;
  const send = async () => { called = true; return Response.json({ type: 'success', message: 'id' }); };
  await assert.rejects(deliverOtp(phone, code, undefined, templateId, send), { code: 'provider_configuration' });
  await assert.rejects(deliverOtp(phone, code, authKey, 'your-template', send), { code: 'provider_configuration' });
  await assert.rejects(deliverOtp('19888888801', code, authKey, templateId, send), { code: 'provider_validation' });
  await assert.rejects(deliverOtp(phone, '12345', authKey, templateId, send), { code: 'provider_validation' });
  assert.equal(called, false);
  await assert.rejects(deliverOtp(phone, code, authKey, templateId,
    async () => Response.json({ type: 'error', message: 'invalid template' })), { code: 'provider_rejected' });
  await assert.rejects(deliverOtp(phone, code, authKey, templateId,
    async () => Response.json({ type: 'success', message: '' })), { code: 'provider_invalid_response' });
  await assert.rejects(deliverOtp(phone, code, authKey, templateId,
    async () => Response.json({ type: 'error' }, { status: 401 })), { code: 'provider_auth' });
  await assert.rejects(deliverOtp(phone, code, authKey, templateId,
    async () => Response.json({ type: 'error' }, { status: 400 })), { code: 'provider_validation' });
});

test('does not retry ambiguous timeouts and exposes only a safe code', async () => {
  let calls = 0;
  // TW-CFG-005: a timeout (or an abort) may follow an accepted, billed request: provider_ambiguous, which
  // the database does not refund, after exactly one request.
  await assert.rejects(deliverOtp(phone, code, authKey, templateId, async (_url, init) => {
    calls++;
    assert.ok(init.signal instanceof AbortSignal);
    throw new DOMException('timed out', 'TimeoutError');
  }), error => error instanceof Msg91DeliveryError && error.code === 'provider_ambiguous' && error.attempts === 1
    && error.message === 'MSG91 delivery unavailable');
  assert.equal(calls, 1);
  await assert.rejects(deliverOtp(phone, code, authKey, templateId, async () => {
    throw new DOMException('aborted', 'AbortError');
  }), { code: 'provider_ambiguous', attempts: 1 });
  // Any other network failure keeps the old code: it is refunded.
  await assert.rejects(deliverOtp(phone, code, authKey, templateId, async () => {
    throw new TypeError('fetch failed');
  }), { code: 'provider_unavailable', attempts: 1 });
  calls = 0;
  await assert.rejects(deliverOtp(phone, code, authKey, templateId, async () => {
    calls++;
    return Response.json({ type: 'success', message: 'accepted-but-gateway-error' }, { status: 503 });
  }), { code: 'provider_unavailable', attempts: 1 });
  assert.equal(calls, 1);
});

test('retries one explicit transient HTTP rejection, never an auth rejection', async () => {
  let calls = 0;
  const delivery = await deliverOtp(phone, code, authKey, templateId, async () => {
    calls++;
    return calls === 1 ? Response.json({ type: 'error' }, { status: 503 })
      : Response.json({ type: 'success', message: 'accepted-id' });
  });
  // TW-CFG-005: one logical request, two billed attempts; the count goes to the database.
  assert.deepEqual(delivery, { providerId: 'accepted-id', attempts: 2 });
  assert.equal(calls, 2);
  calls = 0;
  await assert.rejects(deliverOtp(phone, code, authKey, templateId, async () => {
    calls++;
    return Response.json({ type: 'error' }, { status: 403 });
  }), error => error instanceof Msg91DeliveryError && error.code === 'provider_auth');
  assert.equal(calls, 1);
});

// Every send function below is injected; none can contact the provider.
test('rejects malformed success responses without retrying or exposing response text', async () => {
  for (const body of ['not-json', 'null', '42', JSON.stringify({type:'success',message:42}), JSON.stringify({type:'success',message:'   '})]) {
    let calls=0;
    await assert.rejects(deliverOtp(phone,code,authKey,templateId,async()=>{calls++;return new Response(body,{status:200});}), error=>error instanceof Msg91DeliveryError && error.code==='provider_invalid_response' && error.message==='MSG91 delivery unavailable');
    assert.equal(calls,1);
  }
});

test('preserves absent request IDs and bounds accepted request-ID text', async () => {
  const idOf = async message => (await deliverOtp(phone,code,authKey,templateId,async()=>Response.json({status:'success',message}))).providerId;
  assert.equal(await idOf(null),null);
  assert.equal(await idOf('  accepted-id  '),'accepted-id');
  assert.equal((await idOf('x'.repeat(300))).length,255);
  // X-3: an ID is [A-Za-z0-9._:-]; other text is a success with no ID, not a refusal and not stored.
  assert.equal(await idOf('3566.a1:B2_c3-d4'),'3566.a1:B2_c3-d4');
  for (const text of ['Request queued successfully','id with space','<script>','id\nnext']) assert.equal(await idOf(text),null,text);
});

test('limits explicit rate-limit retries and never retries malformed gateway responses', async () => {
  let calls=0;
  await assert.rejects(deliverOtp(phone,code,authKey,templateId,async()=>{calls++;return Response.json({type:'error'},{status:429});}),{code:'provider_rate_limited'});
  assert.equal(calls,2);
  calls=0;
  await assert.rejects(deliverOtp(phone,code,authKey,templateId,async()=>{calls++;return new Response('malformed gateway response',{status:503});}),{code:'provider_unavailable'});
  assert.equal(calls,1);
});

// TW-CFG-004 (X-8): the answer counts only when its two fields do not disagree. Every send is injected.
test('a success that an error field contradicts is an invalid answer, not an acceptance', async () => {
  for (const body of [{ type: 'success', status: 'error' }, { type: 'error', status: 'success' }]) {
    let calls = 0;
    await assert.rejects(deliverOtp(phone, code, authKey, templateId, async () => { calls++; return Response.json({ ...body, message: 'id' }); }),
      error => error instanceof Msg91DeliveryError && error.code === 'provider_invalid_response' && error.attempts === 1
        && error.message === 'MSG91 delivery unavailable', JSON.stringify(body));
    assert.equal(calls, 1, 'a contradictory answer is not retried');
  }
  // One field is enough, and a field that says nothing does not contradict.
  assert.equal((await deliverOtp(phone, code, authKey, templateId, async () => Response.json({ type: 'success', status: 'ok', message: 'a' }))).providerId, 'a');
  assert.equal((await deliverOtp(phone, code, authKey, templateId, async () => Response.json({ status: 'success', message: 'b' }))).providerId, 'b');
  // An explicit error stays a refusal, and an answer with neither field stays refused.
  await assert.rejects(deliverOtp(phone, code, authKey, templateId, async () => Response.json({ type: 'error', status: 'error' })), { code: 'provider_rejected' });
  await assert.rejects(deliverOtp(phone, code, authKey, templateId, async () => Response.json({ message: 'id' })), { code: 'provider_rejected' });
});

test('a failing status with a contradictory body is not retried; an explicit error is retried exactly once', async () => {
  let calls = 0;
  await assert.rejects(deliverOtp(phone, code, authKey, templateId, async () => {
    calls++;
    return Response.json({ type: 'error', status: 'success' }, { status: 503 });
  }), { code: 'provider_unavailable', attempts: 1 });
  assert.equal(calls, 1, 'one call, no retry');
  calls = 0;
  await assert.rejects(deliverOtp(phone, code, authKey, templateId, async () => {
    calls++;
    return Response.json({ type: 'error' }, { status: 503 });
  }), { code: 'provider_unavailable', attempts: 2 });
  assert.equal(calls, 2, 'exactly one retry');
  calls = 0;
  await assert.rejects(deliverOtp(phone, code, authKey, templateId, async () => {
    calls++;
    return Response.json({ status: 'error' }, { status: 502 });
  }), { code: 'provider_unavailable', attempts: 2 });
  assert.equal(calls, 2, 'either field may carry the error');
});

// TW-CFG-005: the attempts that the database counts and never refunds.
test('every failure reports how many provider requests it made', async () => {
  const attemptsOf = async send => {
    try { await deliverOtp(phone, code, authKey, templateId, send); } catch (error) { return error.attempts; }
    return 'delivered';
  };
  assert.equal(await attemptsOf(async () => Response.json({ type: 'error' }, { status: 401 })), 1);
  assert.equal(await attemptsOf(async () => Response.json({ type: 'error' }, { status: 400 })), 1);
  assert.equal(await attemptsOf(async () => new Response('not json', { status: 200 })), 1);
  assert.equal(await attemptsOf(async () => Response.json({ type: 'error' }, { status: 429 })), 2);
  // Nothing is sent, so nothing is counted, before the request is built.
  let called = false;
  const send = async () => { called = true; return Response.json({ type: 'success', message: 'x' }); };
  for (const attempt of [() => deliverOtp(phone, code, undefined, templateId, send), () => deliverOtp('19888888801', code, authKey, templateId, send),
    () => deliverOtp(phone, '12345', authKey, templateId, send)]) {
    await assert.rejects(attempt(), error => error instanceof Msg91DeliveryError && error.attempts === 0);
  }
  assert.equal(called, false);
});

// X-7 (incident TW-ENV-008): a placeholder or a fixture sentinel never reaches the provider.
test('no placeholder, template text or fixture sentinel is ever sent to the provider', async () => {
  let called = false;
  const send = async () => { called = true; return Response.json({ type: 'success', message: 'x' }); };
  for (const value of ['', '   ', 'your-msg91-auth-key', 'YOUR-key', 'changeme', 'ChangeMe-now', 'fake_key', 'isolated-no-delivery-key', 'isolated-test-key', 'Isolated-x']) {
    await assert.rejects(deliverOtp(phone, code, value, templateId, send), { code: 'provider_configuration', attempts: 0 }, `auth key ${JSON.stringify(value)}`);
    await assert.rejects(deliverOtp(phone, code, authKey, value, send), { code: 'provider_configuration', attempts: 0 }, `template ${JSON.stringify(value)}`);
  }
  assert.equal(called, false, 'the injected provider was never called');
  // A real-looking value still goes through.
  assert.equal((await deliverOtp(phone, code, 'a1b2c3d4e5', '694a8ea0cd30ae1f432f445a', send)).providerId, 'x');
  assert.equal(called, true);
});
