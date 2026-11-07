// The LAN signer (WH-133): the step of the LAN fallback that checks every request a phone sends over the plain-http warehouse network
// and signs every answer it gets back. The wire contract is docs/API_CONTRACT.md, "Signing on the LAN path"; the app mirrors it.
//
// Where it sits (docs/CONTAINER_SECURITY.md, "LAN fallback (gateway-lan)"):
//   phone -> gateway-lan :8080 (Host pin, allow list, body limit; nothing else) -> this service (lan-signer :9000)
//         -> gateway-lan's inner server (gateway-lan-back :8081, reachable on the lan-hop network only: the routes, the key check, the
//            limits of docker/nginx/api-locations.conf) -> PostgREST, Storage, the functions.
// A request is refused here, before the inner server and so before the database, the functions or Storage, when its signature is
// missing or wrong, its key is unknown or ended, its time is more than 5 minutes from this server's clock, or its request id was used in
// the last 10 minutes. The refusal is HTTP 403; gateway-lan adds `X-Warehouse-Path: lan` to every answer.
//
// What is never written anywhere: the key, a signature, a token, a body, a query string. A log line names the refusal code, the method
// and the client address only.
//
// Plain TypeScript with no Deno API, so the module also loads in Node (type stripping); index.ts is the Deno entry of the edge runtime.

// ---------------------------------------------------------------- the contract
export const REQUEST_LABEL = 'WH-LAN-REQ-1';
export const ANSWER_LABEL = 'WH-LAN-ANS-1';
export const PROOF_LABEL = 'WH-LAN-PROOF-1';
/** Signed request headers, in this order, lower-case; an absent one is signed as an empty value. Only these reach the inner server. */
export const SIGNED_REQUEST_HEADERS = ['accept', 'accept-profile', 'apikey', 'authorization', 'cache-control', 'content-profile',
  'content-type', 'prefer', 'range', 'x-upsert'];
/** Signed answer headers, in this order; only these (and the X-Lan-* headers) are passed on to the phone. */
export const SIGNED_ANSWER_HEADERS = ['content-disposition', 'content-range', 'content-type', 'location', 'preference-applied',
  'retry-after', 'www-authenticate', 'x-request-id'];

/** The request time may differ from this server's clock by at most this much. */
export const TIME_WINDOW_MS = 5 * 60 * 1000;
/** A request id is remembered this long: twice the window, and a second more, so a replay is caught by its id or by its time. */
export const REMEMBER_MS = 2 * TIME_WINDOW_MS + 1000;
/** At most this many ids are remembered; when full, new requests are refused (503) rather than an id forgotten early. */
export const MAX_REMEMBERED = 200_000;
/** The largest request body (the 50 MB photo limit of the Storage route; gateway-lan refuses more first). */
export const MAX_REQUEST_BYTES = 50 * 1024 * 1024;
/** The largest answer body (a 50 MB file plus room). A larger answer is refused, signed, with 502. */
export const MAX_ANSWER_BYTES = 52 * 1024 * 1024;
/** All bodies held in memory at once, requests and answers together; over this, 503. The container has 512 MB. */
export const MAX_HELD_BYTES = 192 * 1024 * 1024;
/** How long the inner server may take to answer (a PDF takes up to 60 s in the functions). */
export const UPSTREAM_TIMEOUT_MS = 180_000;
/** How long a key lookup may take. */
export const LOOKUP_TIMEOUT_MS = 5000;

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const HEX32 = /^[0-9a-f]{32}$/;
const HEX64 = /^[0-9a-f]{64}$/;
const SECONDS = /^[1-9][0-9]{0,11}$/;
const VISIBLE = /^[\x20-\x7e]*$/;
const TARGET = /^\/[\x21-\x7e]*$/;
const NIL_UUID = '00000000-0000-0000-0000-000000000000';

// Requests that need no signature: they carry no credential and get nothing a stranger on the internet could not get from the public
// address. Matched on the method and the raw request target exactly (no query, no other spelling). `forward` lists the only headers
// passed on; `body` is the largest body accepted. The answers are not signed (there is no key to sign with), except the proof of
// get-public-config when the phone sends a challenge.
type Exempt = { forward: string[]; body: number; proof: boolean };
const EXEMPT = new Map<string, Exempt>([
  // The phone's liveness probe, and the check of doctor and watch that the listener reaches the functions.
  ['GET /functions/v1/hello', { forward: ['accept'], body: 0, proof: false }],
  // The public configuration. With X-Lan-Key-Id and X-Lan-Challenge it is the phone's identity check: the answer carries a proof
  // keyed with that session's key. Without them it is what doctor and watch read (the public address answers it to anyone).
  ['GET /functions/v1/get-public-config', { forward: ['accept'], body: 0, proof: true }],
  // The key check of doctor and watch (scripts/lan-common.mjs, probeLanKeys): the anon key, no token, PostgREST's root.
  ['GET /rest/v1/', { forward: ['accept', 'apikey'], body: 0, proof: false }],
  // Break-glass sign-in during an outage: the phone has no session and so no key yet. Its answer (and so that session's key) crosses
  // the Wi-Fi in plain text; that session lasts 24 hours at most (migration 132). docs/CONTAINER_SECURITY.md says so.
  ['POST /functions/v1/operator-otp/break-glass', { forward: ['accept', 'content-type', 'user-agent'], body: 4096, proof: false }],
]);

export type SignerDeps = {
  env: (name: string) => string | undefined;
  fetch: (input: string, init: RequestInit) => Promise<Response>;
  /** Milliseconds since the epoch. */
  now: () => number;
  log: (line: string) => void;
};

// ---------------------------------------------------------------- helpers
/** Bytes held in an ordinary ArrayBuffer (what WebCrypto and Response take). */
type Bytes = Uint8Array<ArrayBuffer>;
const encoder = new TextEncoder();

export function toHex(bytes: ArrayBuffer | Uint8Array): string {
  const view = bytes instanceof Uint8Array ? bytes : new Uint8Array(bytes);
  let out = '';
  for (const byte of view) out += byte.toString(16).padStart(2, '0');
  return out;
}

function fromHex(hex: string): Bytes {
  const out = new Uint8Array(hex.length / 2);
  for (let i = 0; i < out.length; i += 1) out[i] = parseInt(hex.slice(i * 2, i * 2 + 2), 16);
  return out;
}

export async function sha256Hex(bytes: Bytes): Promise<string> {
  return toHex(await crypto.subtle.digest('SHA-256', bytes));
}

function importKey(hex: string, usage: 'sign' | 'verify'): Promise<CryptoKey> {
  return crypto.subtle.importKey('raw', fromHex(hex), { name: 'HMAC', hash: 'SHA-256' }, false, [usage]);
}

/** A header value as it is signed: leading and trailing spaces and tabs removed; absent is empty. */
function signedValue(value: string | null): string {
  return (value ?? '').replace(/^[ \t]+|[ \t]+$/g, '');
}

export type RequestParts = { method: string; target: string; keyId: string; time: string; requestId: string; bodyHash: string;
  header: (name: string) => string | null };

/** The string a request signature covers (UTF-8, lines joined with \n, no newline at the end). */
export function canonicalRequest(parts: RequestParts): string {
  return [REQUEST_LABEL, parts.method, parts.target, parts.keyId, parts.time, parts.requestId, parts.bodyHash,
    ...SIGNED_REQUEST_HEADERS.map(name => `${name}:${signedValue(parts.header(name))}`)].join('\n');
}

export type AnswerParts = { keyId: string; requestId: string; serverTime: string; status: number; bodyHash: string;
  header: (name: string) => string | null };

/** The string an answer signature covers. */
export function canonicalAnswer(parts: AnswerParts): string {
  return [ANSWER_LABEL, parts.keyId, parts.requestId, parts.serverTime, String(parts.status), parts.bodyHash,
    ...SIGNED_ANSWER_HEADERS.map(name => `${name}:${signedValue(parts.header(name))}`)].join('\n');
}

/** The string the identity proof covers. */
export function canonicalProof(parts: { keyId: string; challenge: string; serverTime: string; status: number; bodyHash: string }): string {
  return [PROOF_LABEL, parts.keyId, parts.challenge, parts.serverTime, String(parts.status), parts.bodyHash].join('\n');
}

class BodyLimit extends Error {
  reason: 'too_large' | 'busy';
  constructor(reason: 'too_large' | 'busy') { super(reason); this.reason = reason; }
}

/** The session id a bearer token names, or null when there is none or it cannot be read (the inner server checks the token itself). */
function tokenSession(authorization: string): string | null {
  const match = /^Bearer\s+([A-Za-z0-9_-]+)\.([A-Za-z0-9_-]+)\.([A-Za-z0-9_-]+)$/i.exec(authorization);
  if (!match) return null;
  try {
    const text = atob(match[2].replace(/-/g, '+').replace(/_/g, '/').padEnd(Math.ceil(match[2].length / 4) * 4, '='));
    const payload = JSON.parse(text);
    return payload && typeof payload === 'object' && typeof payload.session_id === 'string' ? payload.session_id : null;
  } catch {
    return null;
  }
}

// ---------------------------------------------------------------- the service
export function createSigner(deps: SignerDeps): (req: Request) => Promise<Response> {
  const restUrl = deps.env('LAN_SIGNER_REST_URL');
  const serviceKey = deps.env('SUPABASE_SERVICE_ROLE_KEY');
  const upstream = deps.env('LAN_SIGNER_UPSTREAM');
  if (!restUrl || !serviceKey || !upstream) throw new Error('lan-signer: LAN_SIGNER_REST_URL, SUPABASE_SERVICE_ROLE_KEY and LAN_SIGNER_UPSTREAM are required');
  // Ids remembered before a restart are gone, so a request stamped before this service started is refused: a request captured earlier
  // cannot be sent again after a restart. The phone's time follows the server's (the proof and every signed answer carry it).
  const startedSeconds = Math.floor(deps.now() / 1000);
  const remembered = new Map<string, number>();
  const lookups = new Map<string, Promise<string | null>>();
  let held = 0;

  const reserve = (bytes: number): boolean => {
    if (held + bytes > MAX_HELD_BYTES) return false;
    held += bytes;
    return true;
  };

  async function readBody(stream: ReadableStream<Uint8Array> | null, declared: string | null, max: number, hold: { bytes: number }): Promise<Bytes> {
    if (declared !== null && /^[0-9]+$/.test(declared) && Number(declared) > max) {
      await stream?.cancel().catch(() => {});
      throw new BodyLimit('too_large');
    }
    if (!stream) return new Uint8Array(0);
    const chunks: Uint8Array[] = [];
    let size = 0;
    const reader = stream.getReader();
    try {
      for (;;) {
        const { done, value } = await reader.read();
        if (done) break;
        size += value.byteLength;
        if (size > max) throw new BodyLimit('too_large');
        if (!reserve(value.byteLength)) throw new BodyLimit('busy');
        hold.bytes += value.byteLength;
        chunks.push(value);
      }
    } catch (error) {
      await reader.cancel().catch(() => {});
      throw error;
    } finally {
      reader.releaseLock();
    }
    const bytes = new Uint8Array(size);
    let offset = 0;
    for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.byteLength; }
    return bytes;
  }

  async function fetchKey(keyId: string): Promise<string | null> {
    const response = await deps.fetch(`${restUrl}/rpc/lan_signing_key`, {
      method: 'POST',
      headers: { apikey: serviceKey!, authorization: `Bearer ${serviceKey}`, 'content-type': 'application/json', accept: 'application/json' },
      body: JSON.stringify({ p_key_id: keyId }),
      redirect: 'error',
      signal: AbortSignal.timeout(LOOKUP_TIMEOUT_MS),
    });
    if (!response.ok) {
      await response.body?.cancel().catch(() => {});
      throw new Error(`HTTP ${response.status}`);
    }
    const value = await response.json();
    if (value === null) return null;
    if (typeof value === 'string' && HEX64.test(value)) return value;
    throw new Error('unexpected answer');
  }

  // No cache: a key ended by a sign-out or a revocation is refused from the next request on. Requests for the same key that arrive
  // while a lookup runs share it.
  function lookup(keyId: string): Promise<string | null> {
    let pending = lookups.get(keyId);
    if (!pending) {
      pending = fetchKey(keyId).finally(() => lookups.delete(keyId));
      lookups.set(keyId, pending);
    }
    return pending;
  }

  const json = (status: number, code: string, message: string) =>
    ({ status, body: encoder.encode(JSON.stringify({ message, code })), contentType: 'application/json; charset=utf-8' });

  // An answer without a signature: a refusal before the key is known and checked, and the answers of the exempt requests.
  function plain(status: number, code: string, message: string, method: string, client: string): Response {
    deps.log(`lan-signer: refused ${status} ${code} (${method} from ${client})`);
    const answer = json(status, code, message);
    return new Response(answer.body, { status, headers: { 'content-type': answer.contentType, 'cache-control': 'no-store' } });
  }

  function passedHeaders(source: Headers): Headers {
    const out = new Headers();
    for (const name of SIGNED_ANSWER_HEADERS) {
      const value = source.get(name);
      if (value !== null && VISIBLE.test(value)) out.set(name, signedValue(value));
    }
    return out;
  }

  const emptyBodyStatus = (status: number) => status === 204 || status === 205 || status === 304;

  async function signedAnswer(key: CryptoKey, keyId: string, requestId: string, status: number, headers: Headers, body: Bytes): Promise<Response> {
    const bytes = emptyBodyStatus(status) ? new Uint8Array(0) : body;
    const serverTime = String(Math.floor(deps.now() / 1000));
    const text = canonicalAnswer({ keyId, requestId, serverTime, status, bodyHash: await sha256Hex(bytes), header: name => headers.get(name) });
    const signature = toHex(await crypto.subtle.sign('HMAC', key, encoder.encode(text)));
    headers.set('x-lan-request-id', requestId);
    headers.set('x-lan-server-time', serverTime);
    headers.set('x-lan-signature', signature);
    return new Response(emptyBodyStatus(status) ? null : bytes, { status, headers });
  }

  async function signedRefusal(key: CryptoKey, keyId: string, requestId: string, status: number, code: string, message: string,
    method: string, client: string): Promise<Response> {
    deps.log(`lan-signer: refused ${status} ${code} (${method} from ${client}, signed)`);
    const answer = json(status, code, message);
    const headers = new Headers({ 'content-type': answer.contentType });
    return signedAnswer(key, keyId, requestId, status, headers, answer.body);
  }

  async function forward(method: string, target: string, headers: Headers, body: Bytes | null, hold: { bytes: number }) {
    const response = await deps.fetch(`${upstream}${target}`, {
      method, headers, body: body && body.byteLength ? body : (method === 'GET' || method === 'HEAD' ? undefined : new Uint8Array(0)),
      redirect: 'manual', signal: AbortSignal.timeout(UPSTREAM_TIMEOUT_MS),
    });
    const answer = await readBody(response.body, response.headers.get('content-length'), MAX_ANSWER_BYTES, hold);
    return { status: response.status, headers: response.headers, body: answer };
  }

  // ------------------------------------------------------------ exempt requests
  async function exempt(req: Request, target: string, client: string, rule: Exempt): Promise<Response> {
    const keyId = req.headers.get('x-lan-key-id');
    const challenge = req.headers.get('x-lan-challenge');
    const proving = keyId !== null || challenge !== null;
    if (proving && (!rule.proof || keyId === null || challenge === null || !UUID.test(keyId) || !HEX64.test(challenge))) {
      return plain(403, 'lan_malformed', 'The identity check is malformed', req.method, client);
    }
    let key: CryptoKey | null = null;
    if (proving) {
      let hex: string | null;
      try { hex = await lookup(keyId!); } catch (error) {
        deps.log(`lan-signer: key lookup failed (${error instanceof Error ? error.message : 'error'})`);
        return plain(503, 'lan_key_lookup', 'The warehouse network key could not be checked', req.method, client);
      }
      if (hex === null) return plain(403, 'lan_key_unknown', 'This warehouse network key is not known here', req.method, client);
      key = await importKey(hex, 'sign');
    }
    const hold = { bytes: 0 };
    try {
      let body: Bytes;
      try { body = await readBody(req.body, req.headers.get('content-length'), rule.body, hold); } catch (error) {
        if (error instanceof BodyLimit && error.reason === 'busy') return plain(503, 'lan_busy', 'The warehouse network listener is busy', req.method, client);
        return plain(413, 'lan_body_too_large', 'Request size limit exceeded', req.method, client);
      }
      const headers = new Headers({ 'x-lan-client-addr': client, 'accept-encoding': 'identity' });
      for (const name of rule.forward) {
        const value = req.headers.get(name);
        if (value !== null) headers.set(name, value);
      }
      let answer;
      try { answer = await forward(req.method, target, headers, rule.body ? body : null, hold); } catch (error) {
        return upstreamFailure(error, req.method, client, null);
      }
      const out = passedHeaders(answer.headers);
      const bytes = emptyBodyStatus(answer.status) ? new Uint8Array(0) : answer.body;
      if (key) {
        const serverTime = String(Math.floor(deps.now() / 1000));
        const text = canonicalProof({ keyId: keyId!, challenge: challenge!, serverTime, status: answer.status, bodyHash: await sha256Hex(bytes) });
        out.set('x-lan-server-time', serverTime);
        out.set('x-lan-proof', toHex(await crypto.subtle.sign('HMAC', key, encoder.encode(text))));
      }
      return new Response(emptyBodyStatus(answer.status) ? null : bytes, { status: answer.status, headers: out });
    } finally {
      held -= hold.bytes;
    }
  }

  async function upstreamFailure(error: unknown, method: string, client: string,
    signer: { key: CryptoKey; keyId: string; requestId: string } | null): Promise<Response> {
    const timedOut = error instanceof Error && (error.name === 'TimeoutError' || error.name === 'AbortError');
    const tooLarge = error instanceof BodyLimit && error.reason === 'too_large';
    const busy = error instanceof BodyLimit && error.reason === 'busy';
    const [status, code, message] = busy ? [503, 'lan_busy', 'The warehouse network listener is busy']
      : tooLarge ? [502, 'lan_answer_too_large', 'The answer is too large for the warehouse network']
        : timedOut ? [504, 'lan_timeout', 'The upstream server is timing out']
          : [502, 'lan_upstream', 'An invalid response was received from the upstream server'];
    if (!signer) return plain(status as number, code as string, message as string, method, client);
    return signedRefusal(signer.key, signer.keyId, signer.requestId, status as number, code as string, message as string, method, client);
  }

  // ------------------------------------------------------------ signed requests
  async function signed(req: Request, target: string, client: string): Promise<Response> {
    const method = req.method;
    const keyId = req.headers.get('x-lan-key-id') ?? '';
    const time = req.headers.get('x-lan-time') ?? '';
    const requestId = req.headers.get('x-lan-request-id') ?? '';
    const signature = req.headers.get('x-lan-signature') ?? '';
    if (!UUID.test(keyId) || !SECONDS.test(time) || !HEX32.test(requestId) || !HEX64.test(signature) || !/^[A-Z]{1,10}$/.test(method)
      || SIGNED_REQUEST_HEADERS.some(name => !VISIBLE.test(req.headers.get(name) ?? ''))) {
      return plain(403, 'lan_malformed', 'The request signature headers are malformed', method, client);
    }
    const hold = { bytes: 0 };
    try {
      let body: Bytes;
      try { body = await readBody(req.body, req.headers.get('content-length'), MAX_REQUEST_BYTES, hold); } catch (error) {
        if (error instanceof BodyLimit && error.reason === 'busy') return plain(503, 'lan_busy', 'The warehouse network listener is busy', method, client);
        return plain(413, 'lan_body_too_large', 'Request size limit exceeded', method, client);
      }
      let hex: string | null;
      try { hex = await lookup(keyId); } catch (error) {
        deps.log(`lan-signer: key lookup failed (${error instanceof Error ? error.message : 'error'})`);
        return plain(503, 'lan_key_lookup', 'The warehouse network key could not be checked', method, client);
      }
      if (hex === null) return plain(403, 'lan_key_unknown', 'This warehouse network key is not known here', method, client);
      const text = canonicalRequest({ method, target, keyId, time, requestId, bodyHash: await sha256Hex(body), header: name => req.headers.get(name) });
      // WebCrypto's verify compares in constant time.
      const valid = await crypto.subtle.verify('HMAC', await importKey(hex, 'verify'), fromHex(signature), encoder.encode(text));
      if (!valid) return plain(403, 'lan_signature', 'The request signature is not valid', method, client);

      // From here the request is the key holder's own: every answer, a refusal included, is signed.
      const key = await importKey(hex, 'sign');
      const refuse = (status: number, code: string, message: string) => signedRefusal(key, keyId, requestId, status, code, message, method, client);
      const now = deps.now();
      const seconds = Number(time);
      if (Math.abs(now - seconds * 1000) > TIME_WINDOW_MS || seconds < startedSeconds) {
        return refuse(403, 'lan_time', 'The request time is outside the accepted window');
      }
      // The inner server must get exactly the target that was signed: one the URL parser would rewrite is refused.
      const parsed = new URL(target, 'http://lan.invalid');
      if (parsed.pathname + parsed.search !== target) return refuse(403, 'lan_request_target', 'The request target is not in canonical form');
      for (const [id, expires] of remembered) {
        if (expires > now) break;
        remembered.delete(id);
      }
      const seen = `${keyId}:${requestId}`;
      if (remembered.has(seen)) return refuse(403, 'lan_replayed', 'This request was already received');
      if (remembered.size >= MAX_REMEMBERED) return refuse(503, 'lan_busy', 'The warehouse network listener is busy');
      remembered.set(seen, now + REMEMBER_MS);
      // A token of another session must not ride on this session's signature.
      const authorization = req.headers.get('authorization');
      const session = authorization ? tokenSession(signedValue(authorization)) : null;
      if (session !== null && session !== keyId) return refuse(403, 'lan_session_mismatch', 'The token belongs to another session');

      const headers = new Headers({ 'x-lan-client-addr': client, 'accept-encoding': 'identity' });
      for (const name of SIGNED_REQUEST_HEADERS) {
        const value = signedValue(req.headers.get(name));
        if (value !== '') headers.set(name, value);
      }
      let answer;
      try { answer = await forward(method, target, headers, body, hold); } catch (error) {
        return upstreamFailure(error, method, client, { key, keyId, requestId });
      }
      return signedAnswer(key, keyId, requestId, answer.status, passedHeaders(answer.headers), answer.body);
    } finally {
      held -= hold.bytes;
    }
  }

  // ------------------------------------------------------------ entry
  return async function handle(req: Request): Promise<Response> {
    const client = req.headers.get('x-lan-client-addr');
    if (client === null) {
      // Not through gateway-lan: only the container's own health check, which also proves the key lookup works (it fails with old keys
      // after a rotation, and while PostgREST is down).
      if (req.method === 'GET' && new URL(req.url).pathname === '/__health') {
        try {
          await fetchKey(NIL_UUID);
          return new Response('ok\n', { status: 200, headers: { 'content-type': 'text/plain' } });
        } catch (error) {
          deps.log(`lan-signer: health check: key lookup failed (${error instanceof Error ? error.message : 'error'})`);
          return new Response('key lookup failed\n', { status: 503, headers: { 'content-type': 'text/plain' } });
        }
      }
      return plain(403, 'lan_not_signed', 'Not through the warehouse network listener', req.method, '-');
    }
    if (!VISIBLE.test(client) || client.length > 45) return plain(403, 'lan_malformed', 'Bad client address', req.method, '-');
    const target = req.headers.get('x-lan-request-uri') ?? '';
    if (target.length > 8192 || !TARGET.test(target)) return plain(403, 'lan_malformed', 'The request target is malformed', req.method, client);
    try {
      if (req.headers.has('x-lan-signature')) {
        if (req.headers.has('x-lan-challenge')) return plain(403, 'lan_malformed', 'A request is either signed or a challenge', req.method, client);
        return await signed(req, target, client);
      }
      const rule = EXEMPT.get(`${req.method} ${target}`);
      if (!rule) return plain(403, 'lan_not_signed', 'This request was not signed with the warehouse network key', req.method, client);
      return await exempt(req, target, client, rule);
    } catch (error) {
      deps.log(`lan-signer: internal error (${error instanceof Error ? error.name : 'error'})`);
      return plain(500, 'lan_internal', 'The warehouse network listener failed', req.method, client);
    }
  };
}
