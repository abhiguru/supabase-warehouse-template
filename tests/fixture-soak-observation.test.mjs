import test from 'node:test';
import assert from 'node:assert/strict';
import { validateSince, summarizeRpcAccess } from '../scripts/fixture-soak-observation.mjs';

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

test('RPC observation refuses invalid, future and stale timestamps', () => {
  const now = Date.parse('2026-09-30T18:30:00Z');
  validateSince('2026-09-30T18:00:00Z', now);
  for (const date of ['invalid', '2026-09-30T18:30:01Z', '2026-09-30T17:00:00Z'])
    assert.throws(() => validateSince(date, now));
});
