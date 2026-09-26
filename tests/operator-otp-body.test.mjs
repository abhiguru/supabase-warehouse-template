import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readBoundedJson } from '../functions/operator-otp/body.ts';

test('parses a small JSON object', async () => {
  const request = new Request('https://example.test', { method: 'POST', body: JSON.stringify({ phone_number: '9888888801' }) });
  assert.deepEqual(await readBoundedJson(request), { phone_number: '9888888801' });
});

test('rejects a chunked request after the byte limit, including multibyte text', async () => {
  const encoder = new TextEncoder();
  let secondChunkRead = false;
  const stream = new ReadableStream({
    start(controller) { controller.enqueue(encoder.encode('{"x":"')); },
    pull(controller) {
      secondChunkRead = true;
      controller.enqueue(encoder.encode('é'.repeat(1100)));
      controller.close();
    },
  });
  const request = new Request('https://example.test', { method: 'POST', body: stream, duplex: 'half' });
  await assert.rejects(readBoundedJson(request), RangeError);
  assert.equal(secondChunkRead, true);
});

test('rejects oversized declared length before reading body', async () => {
  const request = new Request('https://example.test', {
    method: 'POST', headers: { 'content-length': '2049' }, body: '{}',
  });
  await assert.rejects(readBoundedJson(request), RangeError);
});
