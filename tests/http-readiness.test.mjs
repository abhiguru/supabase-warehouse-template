import assert from 'node:assert/strict';
import test from 'node:test';
import { waitForHttp } from '../scripts/http-readiness.mjs';

function fixture(statuses) {
  let time = 0;
  const calls = [];
  const options = {
    now: () => time, sleep: async ms => { time += ms; },
    timeoutMs: 30, intervalMs: 10,
    fetchImpl: async (url, options) => {
      calls.push({ url, options });
      const status = statuses.shift() ?? 503;
      if (status instanceof Error) throw status;
      return new Response('', { status });
    },
  };
  return { options, calls };
}

test('gateway restart responses and transport failure recover within the deadline', async () => {
  for (const failure of [502, 503, 504, new TypeError('private transport details')]) {
    const { options, calls } = fixture([failure, 200]);
    await waitForHttp('configuration', 'http://owned/config', { apikey: 'test' }, options);
    assert.equal(calls.length, 2);
    assert.equal(calls[1].options.headers.apikey, 'test');
    assert.equal(calls[1].options.redirect, 'error');
  }
});

test('authentication, route and application errors fail immediately', async () => {
  for (const status of [401, 403, 404, 500]) {
    const { options, calls } = fixture([status, 200]);
    await assert.rejects(waitForHttp('configuration', 'http://owned/config', {}, options), new RegExp(`HTTP ${status}`));
    assert.equal(calls.length, 1);
  }
});

test('persistent transient errors exhaust the fixed deadline', async () => {
  const { options, calls } = fixture([502, 503, 504, 200]);
  await assert.rejects(waitForHttp('configuration', 'http://owned/config', {}, options), /readiness timed out \(HTTP 504\)/);
  assert.equal(calls.length, 3);
});

test('transport failure diagnostics exclude private URL and exception details', async () => {
  const { options } = fixture(Array(3).fill(new Error('private-token')));
  await assert.rejects(waitForHttp('configuration', 'http://user:private-token@owned', {}, options), error => {
    assert.equal(error.message, 'configuration: readiness timed out (connection unavailable)');
    return true;
  });
});
