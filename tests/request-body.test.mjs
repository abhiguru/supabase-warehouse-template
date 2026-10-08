import test from 'node:test';
import assert from 'node:assert/strict';
import { documentRequestBody } from '../functions/_shared/request-body.ts';
test('document request rejects oversize streamed and declared bodies before parsing', async () => {
  await assert.rejects(documentRequestBody(new Request('http://localhost', { method: 'POST', headers: { 'Content-Length': '999999' }, body: '{}' })), error => error.status === 400);
  await assert.rejects(documentRequestBody(new Request('http://localhost', { method: 'POST', body: 'x'.repeat(4097) })), error => error.status === 400);
  await assert.rejects(documentRequestBody(new Request('http://localhost', { method: 'POST', body: '{' })), error => error.message === 'Invalid JSON');
  assert.deepEqual(await documentRequestBody(new Request('http://localhost', { method: 'POST', body: '{"gr_no":"DEMO"}' })), { gr_no: 'DEMO' });
});
