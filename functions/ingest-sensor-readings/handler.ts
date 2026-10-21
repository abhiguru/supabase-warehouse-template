import { securityHeaders } from '../_shared/security-headers.ts';
import { readBoundedJson } from '../operator-otp/body.ts';

// Sensor readings from the facility's sensor bridge (docker/sensor-bridge).
// The bridge holds an ingest key minted with scripts/sensor-ingest-key.sql and
// sends it as the bearer; public.record_sensor_batch checks it against the
// stored hash (the key table is not reachable through PostgREST), validates
// every reading and stores the batch. This function only checks the shape of
// the request, so a malformed key or body never reaches the database.
// The key and the body are never logged and never echoed.

// Everything the handler reaches outside itself, so tests can stand in for it.
export type HandlerDeps = {
  env: (name: string) => string | undefined;
  fetch: typeof fetch;
  log: (message: string) => void;
};
type RpcAnswer = { success?: unknown; code?: unknown; data?: unknown };

// One batch is at most 500 readings; 256 KiB is ample for that.
export const BODY_MAX_BYTES = 262144;
export const MAX_READINGS = 500;
const KEY_PATTERN = /^[0-9a-f]{64}$/;
const RPC_TIMEOUT_MS = 15000;

const headers = { ...securityHeaders, 'Content-Type': 'application/json', 'Cache-Control': 'no-store' };
function respond(body: unknown, status: number, extra: Record<string, string> = {}): Response {
  return new Response(JSON.stringify(body), { status, headers: { ...headers, ...extra } });
}

// The answer for each kind of refusal; the reason itself goes to the log only.
const unauthorized = () => respond({ success: false, error: 'Unauthorized' }, 401, { 'WWW-Authenticate': 'Bearer' });
const invalid = () => respond({ success: false, error: 'Invalid request' }, 400);
const unavailable = () => respond({ success: false, error: 'Ingestion unavailable' }, 503);
const invalidCodes = new Set(['invalid_hub', 'invalid_readings', 'too_many_readings']);

class Unavailable extends Error {}

function isObject(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}

function bearer(req: Request): string | null {
  const match = /^Bearer +(\S+)$/i.exec(req.headers.get('Authorization') || '');
  return match ? match[1] : null;
}

const count = (value: unknown) => (Number.isSafeInteger(value) && (value as number) >= 0 ? value as number : null);

async function recordBatch(deps: HandlerDeps, params: Record<string, unknown>): Promise<RpcAnswer> {
  const url = deps.env('SUPABASE_URL');
  const key = deps.env('SUPABASE_SERVICE_ROLE_KEY');
  if (!url || !key) throw new Unavailable('env_missing');
  let response: Response;
  try {
    response = await deps.fetch(`${url}/rest/v1/rpc/record_sensor_batch`, {
      method: 'POST',
      headers: { apikey: key, Authorization: `Bearer ${key}`, 'Content-Type': 'application/json' },
      body: JSON.stringify(params),
      signal: AbortSignal.timeout(RPC_TIMEOUT_MS),
      redirect: 'error',
    });
  } catch (error) {
    throw new Unavailable((error as { name?: unknown } | null)?.name === 'TimeoutError' ? 'rpc_timeout' : 'rpc_unreachable');
  }
  if (!response.ok) {
    // The error text is not needed; release the connection without waiting on it.
    response.body?.cancel().catch(() => {});
    throw new Unavailable(`rpc_status_${response.status}`);
  }
  let answer: unknown;
  try { answer = await response.json(); } catch { throw new Unavailable('rpc_answer_malformed'); }
  if (!isObject(answer)) throw new Unavailable('rpc_answer_malformed');
  return answer;
}

export async function handle(req: Request, overrides: Partial<HandlerDeps> = {}): Promise<Response> {
  const deps: HandlerDeps = {
    env: name => Deno.env.get(name), fetch: (input, init) => fetch(input, init), log: message => console.error(message), ...overrides,
  };
  const note = (reason: string, details = '') => deps.log(`ingest-sensor-readings: event=ingest reason=${reason}${details}`);
  if (req.method !== 'POST') return respond({ success: false, error: 'Method not allowed' }, 405, { Allow: 'POST' });

  // The key's shape is checked before anything else: no database call for a caller without one.
  const key = bearer(req);
  if (key === null) { note('missing_key'); return unauthorized(); }
  if (!KEY_PATTERN.test(key)) { note('malformed_key'); return unauthorized(); }

  let body: Record<string, unknown>;
  try {
    body = await readBoundedJson(req, BODY_MAX_BYTES);
  } catch (error) {
    note(error instanceof RangeError ? 'body_too_large' : 'body_not_json_object');
    return invalid();
  }
  const { bridge, hub, readings } = body;
  if (!isObject(hub)) { note('invalid_hub_shape'); return invalid(); }
  if (bridge !== undefined && !isObject(bridge)) { note('invalid_bridge_shape'); return invalid(); }
  if (!Array.isArray(readings)) { note('invalid_readings_shape'); return invalid(); }
  if (readings.length > MAX_READINGS) { note('too_many_readings'); return invalid(); }
  if (!readings.every(isObject)) { note('invalid_readings_shape'); return invalid(); }

  let answer: RpcAnswer;
  try {
    answer = await recordBatch(deps, {
      p_key: key,
      // The bridge's id and version travel with the hub: the hub row records which bridge reported it.
      p_hub: bridge === undefined ? hub : { ...hub, bridge },
      p_readings: readings,
    });
  } catch (error) {
    note(error instanceof Unavailable ? error.message : 'rpc_failed');
    return unavailable();
  }

  if (answer.success !== true) {
    const code = typeof answer.code === 'string' && /^[a-z_]{1,40}$/.test(answer.code) ? answer.code : 'unknown';
    if (code === 'invalid_key') { note('invalid_key'); return unauthorized(); }
    if (invalidCodes.has(code)) { note(code); return invalid(); }
    note('rpc_refused', ` code=${code}`);
    return unavailable();
  }
  const data = isObject(answer.data) ? answer.data : {};
  const [accepted, duplicates, rejected, devices] = [data.accepted, data.duplicates, data.rejected, data.devices_seen].map(count);
  if (accepted === null || duplicates === null || rejected === null || devices === null) {
    note('rpc_answer_malformed');
    return unavailable();
  }
  note('ok', ` accepted=${accepted} duplicates=${duplicates} rejected=${rejected} devices=${devices}`);
  return respond({ success: true, accepted, duplicates, rejected, devices }, 200);
}
