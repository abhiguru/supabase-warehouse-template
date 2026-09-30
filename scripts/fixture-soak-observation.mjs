// Pure parsing helpers: never return raw access lines, query values or credentials.
import assert from 'node:assert/strict';
export function validateSince(since, now = Date.now()) {
  const when = Date.parse(since);
  assert.ok(Number.isFinite(when) && when <= now && now - when < 4000000,
    'Observation requires a recent past timestamp');
}
export function summarizeRpcAccess(text) {
  const records = [];
  for (const line of text.split('\n')) {
    const m = line.match(/"(GET|POST) (\/rest\/v1\/rpc\/(get_orders_list|refresh_jwt_token))(?:\?[^ ]*)? HTTP\/[\d.]+" (\d{3})\b/);
    if (m) records.push({ path: m[2], status: Number(m[4]) });
  }
  return {
    successfulOrdersRequests: records.filter(x => x.path.endsWith('get_orders_list') && x.status === 200).length,
    refreshRPCs: records.filter(x => x.path.endsWith('refresh_jwt_token') && x.status === 200).length,
    failedObservedRequests: records.filter(x => x.status >= 400),
  };
}
