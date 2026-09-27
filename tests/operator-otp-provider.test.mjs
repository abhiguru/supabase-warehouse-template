import { test } from 'node:test';
import assert from 'node:assert/strict';
import { deliverOtp } from '../functions/operator-otp/provider.ts';

const phone = '919888888801';
const code = '123456';
const authKey = 'unit-test-auth-key';
const templateId = 'unit-test-template';

test('submits the current MSG91 Flow payload and requires a request ID', async () => {
  let request;
  const id = await deliverOtp(phone, code, authKey, templateId, async (url, init) => {
    request = { url, init };
    return Response.json({ type: 'success', message: 'request-id' });
  });
  assert.equal(id, 'request-id');
  assert.equal(request.url, 'https://control.msg91.com/api/v5/flow');
  assert.equal(request.init.method, 'POST');
  assert.equal(request.init.redirect, 'error');
  assert.equal(request.init.headers.authkey, authKey);
  assert.deepEqual(JSON.parse(request.init.body), {
    template_id: templateId, recipients: [{ mobiles: phone, VAR1: code }],
  });
  assert.ok(request.init.signal instanceof AbortSignal);
});

test('refuses missing configuration, provider rejections and non-2xx responses', async () => {
  let called = false;
  const send = async () => { called = true; return Response.json({ type: 'success', message: 'id' }); };
  await assert.rejects(deliverOtp(phone, code, undefined, templateId, send));
  await assert.rejects(deliverOtp(phone, code, authKey, 'your-template', send));
  assert.equal(called, false);
  for (const response of [
    Response.json({ type: 'error', message: 'invalid template' }),
    Response.json({ type: 'success' }),
    Response.json({ type: 'success', message: '' }),
    Response.json({ type: 'success', message: 'error' }, { status: 400 }),
  ]) {
    await assert.rejects(deliverOtp(phone, code, authKey, templateId, async () => response));
  }
});

test('propagates network timeout so the challenge is sealed by the caller', async () => {
  await assert.rejects(deliverOtp(phone, code, authKey, templateId, async (_url, init) => {
    assert.ok(init.signal instanceof AbortSignal);
    throw new DOMException('timed out', 'TimeoutError');
  }), { name: 'TimeoutError' });
});
