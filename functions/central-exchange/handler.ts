import { createLocalJWKSet, decodeProtectedHeader, jwtVerify } from '../vendor/jose.mjs';
import { corsHeaders, handleCors } from '../_shared/cors.ts';
import { httpsAddress } from '../_shared/https-address.ts';
import { publicBaseUrl } from '../_shared/public-url.ts';
import { readBoundedJson } from '../operator-otp/body.ts';
import { KEY_SET_MAX_BYTES, usableKeys } from './key-set.mjs';

// Central sign-in, facility side (docs/CENTRAL_LOGIN.md). The association's
// service signs a short-lived identity token for this facility; this function
// verifies it and hands the identity to public.operator_central_exchange,
// which answers as a correct SMS code does (pending request, session, or
// refusal). The association's sign-in alone opens an existing person profile
// of this facility (owner decision 2026-10-15). Only where the facility has
// switched on its own extra code does it ask for a correct SMS code of this
// facility (otp_code) at every sign-in; link_required then means "send the code".
// The token itself is never logged and never echoed.

type Jwk = Record<string, unknown>;
type RpcResult = { success: boolean; code?: string; data?: Record<string, unknown> };
// The fetched verification keys of the issuer, kept in this worker's memory:
// they live no longer than the worker does.
export type KeyCache = { keys: Jwk[]; fetchedAt: number; attemptedAt: number; failedAt: number; pending: Promise<void> | null };
// Everything the handler reaches outside itself, so tests can stand in for it.
export type HandlerDeps = {
  env: (name: string) => string | undefined;
  fetch: typeof fetch;
  now: () => number;
  log: (message: string) => void;
  keys: KeyCache;
};

export const TOKEN_TYPE = 'facility-identity+jwt';
const MAX_LIFETIME_SECONDS = 600;
const CLOCK_TOLERANCE_SECONDS = 30;
const KEYS_FRESH_MS = 10 * 60 * 1000;
const KEYS_REFETCH_MS = 60 * 1000;
// After a fetch that failed no new one is started for this long.
const KEYS_FAILURE_BACKOFF_MS = 30 * 1000;
const KEYS_TIMEOUT_MS = 5000;
// An ES256 token with these claims is well under 2 KB; the body also carries two names.
const BODY_MAX_BYTES = 8192;

export function createKeyCache(): KeyCache {
  return { keys: [], fetchedAt: -Infinity, attemptedAt: -Infinity, failedAt: -Infinity, pending: null };
}
const workerKeys = createKeyCache();

const headers = { ...corsHeaders, 'Content-Type': 'application/json', 'Cache-Control': 'no-store' };
function respond(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers });
}

class KeysUnavailable extends Error {}
class TokenRefused extends Error {}

const answers: Record<string, [number, string]> = {
  invalid_request: [400, 'Invalid request'],
  central_unavailable: [503, 'Central sign-in is not available at this facility'],
  central_keys_unavailable: [503, 'Sign-in is temporarily unavailable. Try again.'],
  // One message for every reason a token is refused; the reason is logged.
  invalid_identity_token: [401, 'Sign-in could not be verified'],
  identity_token_used: [401, 'Sign-in could not be verified'],
  account_unavailable: [403, 'Account unavailable'],
  identity_conflict: [409, 'This phone number is linked to another sign-in. Ask the facility administrator.'],
  enrollment_limited: [429, 'Too many new access requests. Try again tomorrow.'],
  // This facility asks for its own code at every sign-in (the setting is off by default).
  link_required: [409, 'This facility asks for its own code each time you sign in.'],
  // What the SMS check answers, with the texts operator-otp uses.
  invalid_otp: [400, 'Invalid or expired OTP'],
  rate_limited: [429, 'Too many OTP requests. Try again later.'],
  unavailable: [503, 'Authentication service unavailable'],
};
function failure(code: string): Response {
  const known = Object.hasOwn(answers, code) ? code : 'unavailable';
  const [status, error] = answers[known];
  return respond({ success: false, error, code: known }, status);
}

async function rpc(deps: HandlerDeps, name: string, params: Record<string, unknown>): Promise<RpcResult> {
  const url = deps.env('SUPABASE_URL');
  const key = deps.env('SUPABASE_SERVICE_ROLE_KEY');
  if (!url || !key) throw new Error('Backend credentials missing');
  const response = await deps.fetch(`${url}/rest/v1/rpc/${name}`, {
    method: 'POST',
    headers: { apikey: key, Authorization: `Bearer ${key}`, 'Content-Type': 'application/json' },
    body: JSON.stringify(params),
    signal: AbortSignal.timeout(15000),
    redirect: 'error',
  });
  if (!response.ok) throw new Error(`Auth database unavailable (${response.status})`);
  return await response.json();
}

// Same trust boundary as operator-otp: Cloudflare writes CF-Connecting-IP and
// the gateway forwards it. It only feeds the new-access-request limit.
function clientAddress(req: Request): string | null {
  const clientIp = req.headers.get('CF-Connecting-IP');
  return clientIp && /^[0-9a-fA-F:.]{3,45}$/.test(clientIp) ? clientIp : null;
}

async function readBounded(response: Response, maxBytes: number): Promise<string> {
  const declared = Number(response.headers.get('content-length'));
  if (Number.isFinite(declared) && declared > maxBytes) throw new KeysUnavailable('key set too large');
  const reader = response.body?.getReader();
  if (!reader) throw new KeysUnavailable('key set empty');
  const chunks: Uint8Array[] = [];
  let received = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    received += value.byteLength;
    if (received > maxBytes) {
      await reader.cancel();
      throw new KeysUnavailable('key set too large');
    }
    chunks.push(value);
  }
  const bytes = new Uint8Array(received);
  let offset = 0;
  for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.byteLength; }
  return new TextDecoder('utf-8', { fatal: true }).decode(bytes);
}

function keySet(text: string): Jwk[] {
  let document: unknown;
  try { document = JSON.parse(text); } catch { throw new KeysUnavailable('key set is not JSON'); }
  try { return usableKeys(document) as Jwk[]; } catch (error) {
    throw new KeysUnavailable(error instanceof Error ? error.message : 'key set malformed');
  }
}

async function fetchKeys(deps: HandlerDeps, address: string): Promise<void> {
  const cache = deps.keys;
  cache.attemptedAt = deps.now();
  try {
    cache.keys = keySet(await fetchKeyText(deps, address));
    cache.fetchedAt = deps.now();
  } catch (error) {
    cache.failedAt = deps.now();
    throw error;
  }
}

async function fetchKeyText(deps: HandlerDeps, address: string): Promise<string> {
  try {
    const response = await deps.fetch(address, {
      headers: { Accept: 'application/json' },
      signal: AbortSignal.timeout(KEYS_TIMEOUT_MS),
      redirect: 'error',
    });
    if (response.status !== 200) throw new KeysUnavailable(`key set answered ${response.status}`);
    return await readBounded(response, KEY_SET_MAX_BYTES);
  } catch (error) {
    throw error instanceof KeysUnavailable ? error : new KeysUnavailable('key set could not be fetched');
  }
}

// The fetched keys to verify a token that names `kid`. Keys are kept for at
// most ten minutes (and no longer than this worker lives). A key id that is
// not among them causes a new fetch, at most once a minute, so a rotated key
// is picked up without letting callers drive the fetches. After a fetch that
// failed, none is started for 30 seconds: callers get "keys unavailable".
async function keysFor(deps: HandlerDeps, address: string, kid: string): Promise<Jwk[]> {
  const cache = deps.keys;
  const fresh = deps.now() - cache.fetchedAt < KEYS_FRESH_MS;
  const known = cache.keys.some(key => key.kid === kid);
  if (fresh && (known || deps.now() - cache.attemptedAt < KEYS_REFETCH_MS)) return cache.keys;
  // One fetch at a time; requests that arrive meanwhile wait for it.
  if (!cache.pending && deps.now() - cache.failedAt < KEYS_FAILURE_BACKOFF_MS) throw new KeysUnavailable('waiting after a failed fetch');
  if (!cache.pending) cache.pending = fetchKeys(deps, address).finally(() => { cache.pending = null; });
  await cache.pending;
  return cache.keys;
}

type Identity = { subject: string; phone: string; tokenId: string; expiresAt: string; name: string | null };

async function verifyIdentity(token: string, issuer: string, audience: string, now: number, keysFor: (kid: string) => Promise<Jwk[]>): Promise<Identity> {
  // The header is read first so that a token of another kind, or one that
  // names no key, never causes a key fetch. Nothing in it is trusted yet.
  let header: Record<string, unknown>;
  try { header = decodeProtectedHeader(token) as Record<string, unknown>; } catch { throw new TokenRefused('malformed'); }
  if (header.alg !== 'ES256') throw new TokenRefused('algorithm');
  if (header.typ !== TOKEN_TYPE) throw new TokenRefused('type');
  if (typeof header.kid !== 'string' || !header.kid || header.kid.length > 200) throw new TokenRefused('key id');
  const keys = await keysFor(header.kid);
  let payload: Record<string, unknown>;
  try {
    ({ payload } = await jwtVerify(token, createLocalJWKSet({ keys }), {
      algorithms: ['ES256'], issuer, audience, typ: TOKEN_TYPE,
      clockTolerance: CLOCK_TOLERANCE_SECONDS, currentDate: new Date(now),
      requiredClaims: ['iss', 'aud', 'sub', 'iat', 'exp', 'jti', 'phone_number', 'phone_number_verified'],
    }));
  } catch (error) {
    // jose's codes name the failed check (ERR_JWT_EXPIRED, ERR_JWS_SIGNATURE_VERIFICATION_FAILED, ...) and hold no token text.
    const code = (error as { code?: unknown } | null)?.code;
    throw new TokenRefused(typeof code === 'string' && /^ERR_[A-Z_]+$/.test(code) ? code : 'verification');
  }
  const { aud, sub, jti, iat, exp, phone_number: phone, phone_number_verified: verified, name } = payload;
  // For this facility and no other: a token that also names another audience is refused.
  if (aud !== audience && !(Array.isArray(aud) && aud.length === 1 && aud[0] === audience)) throw new TokenRefused('audience');
  if (typeof iat !== 'number' || typeof exp !== 'number' || !Number.isFinite(iat) || !Number.isFinite(exp)) throw new TokenRefused('time claims');
  if (exp - iat > MAX_LIFETIME_SECONDS || exp <= iat) throw new TokenRefused('lifetime');
  if (iat > now / 1000 + CLOCK_TOLERANCE_SECONDS) throw new TokenRefused('issued in the future');
  if (typeof sub !== 'string' || !/^[A-Za-z0-9_-]{1,64}$/.test(sub)) throw new TokenRefused('subject');
  if (typeof jti !== 'string' || !/^[A-Za-z0-9_-]{16,128}$/.test(jti)) throw new TokenRefused('token id');
  if (typeof phone !== 'string' || !/^91[0-9]{10}$/.test(phone)) throw new TokenRefused('phone number');
  if (verified !== true) throw new TokenRefused('phone number not verified');
  if (name !== undefined && typeof name !== 'string') throw new TokenRefused('name');
  return {
    subject: sub, phone, tokenId: jti, name: typeof name === 'string' ? name : null,
    // The token is acceptable until exp plus the tolerance, so its single-use record must last that long.
    expiresAt: new Date((exp + CLOCK_TOLERANCE_SECONDS) * 1000).toISOString(),
  };
}

export async function handle(req: Request, overrides: Partial<HandlerDeps> = {}): Promise<Response> {
  const deps: HandlerDeps = {
    env: name => Deno.env.get(name), fetch: (input, init) => fetch(input, init),
    now: () => Date.now(), log: message => console.error(message), keys: workerKeys, ...overrides,
  };
  const cors = handleCors(req);
  if (cors) return cors;
  if (req.method !== 'POST') return respond({ success: false, error: 'Method not allowed' }, 405);
  const issuer = deps.env('CENTRAL_ISSUER') || '';
  // The keys come from a file of the installation (its text arrives from the
  // router) or from an address; with a file nothing is ever fetched.
  const jwksFile = deps.env('CENTRAL_JWKS_FILE') || '';
  const jwksAddress = deps.env('CENTRAL_JWKS_URL') || '';
  if (deps.env('AUTH_MODE') !== 'operator' || deps.env('APP_ENV') !== 'production' || !issuer || !(jwksFile || jwksAddress)) {
    return failure('central_unavailable');
  }
  let body: Record<string, unknown>;
  try {
    body = await readBoundedJson(req, BODY_MAX_BYTES);
  } catch { return failure('invalid_request'); }
  if (typeof body.identity_token !== 'string' || !body.identity_token) return failure('invalid_request');
  if (body.otp_code !== undefined && (typeof body.otp_code !== 'string' || !/^[0-9]{6}$/.test(body.otp_code))) return failure('invalid_request');

  let identity: Identity;
  try {
    if (!httpsAddress(issuer) || (!jwksFile && !httpsAddress(jwksAddress))) throw new KeysUnavailable('issuer and key address must be https');
    const audience = publicBaseUrl(deps.env('SUPABASE_PUBLIC_URL'));
    const keysOf = jwksFile
      ? (_kid: string) => {
        const text = deps.env('CENTRAL_JWKS_JSON') || '';
        if (!text) throw new KeysUnavailable('key file missing or empty');
        if (text.length > KEY_SET_MAX_BYTES) throw new KeysUnavailable('key set too large');
        return Promise.resolve(keySet(text));
      }
      : (kid: string) => keysFor(deps, jwksAddress, kid);
    identity = await verifyIdentity(body.identity_token, issuer, audience, deps.now(), keysOf);
  } catch (error) {
    if (error instanceof TokenRefused) {
      deps.log(`central-exchange: identity token refused (${error.message})`);
      return failure('invalid_identity_token');
    }
    if (error instanceof KeysUnavailable) {
      deps.log(`central-exchange: keys unavailable (${error.message})`);
      return failure('central_keys_unavailable');
    }
    deps.log('central-exchange: facility origin is not configured');
    return failure('unavailable');
  }

  try {
    const result = await rpc(deps, 'operator_central_exchange', {
      p_issuer: issuer, p_subject: identity.subject, p_phone_number: identity.phone,
      p_token_id: identity.tokenId, p_token_expires_at: identity.expiresAt,
      // What the person typed in the app wins; the name the central service holds is the fallback.
      p_name: typeof body.name === 'string' ? body.name : identity.name,
      p_display_name: typeof body.display_name === 'string' ? body.display_name : null,
      p_ip_address: clientAddress(req),
      p_otp_code: typeof body.otp_code === 'string' ? body.otp_code : null,
    });
    if (result.success) return respond(result);
    deps.log(`central-exchange: refused by the facility (${typeof result.code === 'string' && /^[a-z_]{1,40}$/.test(result.code) ? result.code : 'unknown'})`);
    return failure(result.code || 'unavailable');
  } catch {
    return failure('unavailable');
  }
}
