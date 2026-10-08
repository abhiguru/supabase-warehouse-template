import { test } from 'node:test';
import assert from 'node:assert/strict';
import { deliverOtp, Msg91DeliveryError } from '../functions/operator-otp/provider.ts';

const phone = '919888888801';
const code = '123456';
const authKey = 'unit-test-auth-key';
const templateId = 'unit-test-template';

test('submits the approved MSG91 Flow payload and records its request ID', async () => {
  let request;
  const id = await deliverOtp(phone, code, authKey, templateId, async (url, init) => {
    request = { url, init };
    return Response.json({ type: 'success', message: 'request-id' });
  });
  assert.equal(id, 'request-id');
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
  const id = await deliverOtp('9888888801', code, authKey, templateId, async (_url, init) => {
    recipient = JSON.parse(init.body).recipients[0].mobiles;
    return Response.json({ type: 'success' });
  });
  assert.equal(recipient, phone);
  assert.equal(id, null);
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
  await assert.rejects(deliverOtp(phone, code, authKey, templateId, async (_url, init) => {
    calls++;
    assert.ok(init.signal instanceof AbortSignal);
    throw new DOMException('timed out', 'TimeoutError');
  }), { code: 'provider_unavailable', message: 'MSG91 delivery unavailable' });
  assert.equal(calls, 1);
  calls = 0;
  await assert.rejects(deliverOtp(phone, code, authKey, templateId, async () => {
    calls++;
    return Response.json({ type: 'success', message: 'accepted-but-gateway-error' }, { status: 503 });
  }), { code: 'provider_unavailable' });
  assert.equal(calls, 1);
});

test('retries one explicit transient HTTP rejection, never an auth rejection', async () => {
  let calls = 0;
  const id = await deliverOtp(phone, code, authKey, templateId, async () => {
    calls++;
    return calls === 1 ? Response.json({ type: 'error' }, { status: 503 })
      : Response.json({ type: 'success', message: 'accepted-id' });
  });
  assert.equal(id, 'accepted-id');
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
  assert.equal(await deliverOtp(phone,code,authKey,templateId,async()=>Response.json({status:'success',message:null})),null);
  assert.equal(await deliverOtp(phone,code,authKey,templateId,async()=>Response.json({status:'success',message:'  accepted-id  '})),'accepted-id');
  const id=await deliverOtp(phone,code,authKey,templateId,async()=>Response.json({type:'success',message:'x'.repeat(300)}));
  assert.equal(id.length,255);
});

test('limits explicit rate-limit retries and never retries malformed gateway responses', async () => {
  let calls=0;
  await assert.rejects(deliverOtp(phone,code,authKey,templateId,async()=>{calls++;return Response.json({type:'error'},{status:429});}),{code:'provider_rate_limited'});
  assert.equal(calls,2);
  calls=0;
  await assert.rejects(deliverOtp(phone,code,authKey,templateId,async()=>{calls++;return new Response('malformed gateway response',{status:503});}),{code:'provider_unavailable'});
  assert.equal(calls,1);
});
