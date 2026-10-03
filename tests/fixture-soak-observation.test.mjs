import test from 'node:test';
import assert from 'node:assert/strict';
import { validateSince, summarizeRpcAccess, observationResult } from '../scripts/fixture-soak-observation.mjs';

test('RPC observation requires actual successful Orders requests and strips query credentials', () => {
  const d = summarizeRpcAccess('ip "POST /rest/v1/rpc/get_orders_list?apikey=fictional-secret HTTP/1.1" 200 300\n' +
    'ip "POST /rest/v1/rpc/refresh_jwt_token HTTP/1.1" 200 220\n' +
    'ip "GET /realtime/v1/websocket?apikey=fictional-secret HTTP/1.1" 101 0\n' +
    'ip "POST /rest/v1/rpc/get_orders_list HTTP/1.1" 401 220\n' +
    'ip "POST /rest/v1/rpc/get_orders_list HTTP/1.1" 502 100\n');
  assert.deepEqual(d, { successfulOrdersRequests: 1, refreshRPCs: 1, failedObservedRequests: [
    { path: '/rest/v1/rpc/get_orders_list', status: 401 }, { path: '/rest/v1/rpc/get_orders_list', status: 502 },
  ] });
  assert.ok(!JSON.stringify(d).includes('fictional-secret'));
  assert.equal(summarizeRpcAccess('No requests\n"GET /functions/v1/get-public-config HTTP/1.1" 200').successfulOrdersRequests, 0);
});

test('observation distinguishes absent RPCs, log failure, auth rejection and upstream errors', () => {
  assert.equal(observationResult({ status: 0, stdout: '' }).category, 'NO_ORDERS_REQUEST');
  assert.deepEqual(observationResult({ status: null, stderr: 'private-token' }),
    { status: 'FAIL', category: 'OBSERVATION_UNAVAILABLE' });
  for (const [status, category] of [[401, 'RPC_AUTH_ERROR'], [403, 'RPC_AUTH_ERROR'], [502, 'RPC_SERVER_ERROR']])
    assert.equal(observationResult({ status: 0, stdout: `"POST /rest/v1/rpc/get_orders_list HTTP/1.1" ${status}` }).category, category);
  const success = observationResult({ status: 0, stdout: '"POST /rest/v1/rpc/get_orders_list?apikey=private-token HTTP/1.1" 200' });
  assert.equal(success.status, 'PASS');
  assert.ok(!JSON.stringify(success).includes('private-token'));
  const failed = observationResult({ status: 0, stdout: '"POST /rest/v1/rpc/get_orders_list HTTP/1.1" 200\n"POST /rest/v1/rpc/refresh_jwt_token HTTP/1.1" 500' });
  assert.equal(failed.category, 'RPC_SERVER_ERROR');
});

test('RPC observation refuses invalid, future and stale timestamps', () => {
  const now = Date.parse('2026-09-30T18:30:00Z');
  validateSince('2026-09-30T18:00:00Z', now);
  for (const date of ['invalid', '2026-09-30T18:30:01Z', '2026-09-30T17:00:00Z'])
    assert.throws(() => validateSince(date, now));
});
