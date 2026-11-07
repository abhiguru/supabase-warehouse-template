// A person's phone redeems the pairing code of a local-only facility (WH-146; docs/API_CONTRACT.md, "Pairing a phone"). The request is
// unsigned (the phone has no warehouse network key yet) and carries the code and a nonce of its own. The answer proves that this server knows
// the secret behind the code (the phone checks `proof` first) and carries the new session, with its warehouse network key, encrypted under a
// key derived from that secret, so neither crosses the Wi-Fi readable:
//   proof = HMAC-SHA256(secret, "WH-PAIR-PROOF-1\n" + code + "\n" + nonce)                      (hex)
//   key   = HKDF-SHA256(ikm = secret, salt = the 32 nonce bytes, info = "WH-PAIR-KEY-1", 32 bytes)
//   ciphertext = AES-256-GCM(key, iv, JSON of the session, additional data = "WH-PAIR-1\n" + code + "\n" + nonce)   (hex, tag at the end)
// A code is spent by its first good redeem (public.redeem_pairing_code, migration 170): a second use, an expired or replaced code and an
// unknown one all answer 409 PAIRING_CODE_INVALID. Only a local-only facility answers at all.
import { restBaseUrl } from '../_shared/rest-url.ts';
import { securityHeaders } from '../_shared/security-headers.ts';
import { clientAddress, clientUserAgent } from '../_shared/client-info.ts';

const headers = { ...securityHeaders, 'Content-Type': 'application/json', 'Cache-Control': 'no-store' };
const respond = (body: unknown, status = 200, extra: Record<string, string> = {}) => new Response(JSON.stringify(body), { status, headers: { ...headers, ...extra } });
const encoder = new TextEncoder();
const toHex = (bytes: ArrayBuffer | Uint8Array) => [...new Uint8Array(bytes)].map(b => b.toString(16).padStart(2, '0')).join('');
const fromHex = (hex: string) => Uint8Array.from(hex.match(/../g) ?? [], pair => parseInt(pair, 16));

export async function seal(secretHex: string, code: string, nonceHex: string, session: unknown) {
  const secret = fromHex(secretHex);
  const nonce = fromHex(nonceHex);
  const hmacKey = await crypto.subtle.importKey('raw', secret, { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
  const proof = toHex(await crypto.subtle.sign('HMAC', hmacKey, encoder.encode(`WH-PAIR-PROOF-1\n${code}\n${nonceHex}`)));
  const ikm = await crypto.subtle.importKey('raw', secret, 'HKDF', false, ['deriveKey']);
  const aesKey = await crypto.subtle.deriveKey({ name: 'HKDF', hash: 'SHA-256', salt: nonce, info: encoder.encode('WH-PAIR-KEY-1') }, ikm, { name: 'AES-GCM', length: 256 }, false, ['encrypt']);
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const sealed = await crypto.subtle.encrypt({ name: 'AES-GCM', iv, additionalData: encoder.encode(`WH-PAIR-1\n${code}\n${nonceHex}`) }, aesKey, encoder.encode(JSON.stringify(session)));
  return { proof, iv: toHex(iv), ciphertext: toHex(sealed) };
}

export async function handle(req: Request, env: (name: string) => string | undefined = name => Deno.env.get(name), doFetch: typeof fetch = fetch): Promise<Response> {
  if (env('INGRESS') !== 'local-only') return respond({ success: false, error: 'Not found' }, 404);
  if (req.method !== 'POST') return respond({ success: false, error: 'Method not allowed' }, 405);
  let body: Record<string, unknown>;
  try {
    const text = await req.text();
    if (text.length > 1024) throw new Error('too large');
    body = JSON.parse(text);
  } catch { return respond({ success: false, error: 'Invalid request' }, 400); }
  const code = typeof body.code === 'string' ? body.code.trim().toUpperCase() : '';
  const nonce = typeof body.nonce === 'string' ? body.nonce.trim().toLowerCase() : '';
  if (!/^[2-9A-HJKMNP-TV-Z]{8}$/.test(code) || !/^[0-9a-f]{64}$/.test(nonce)) return respond({ success: false, error: 'Invalid request' }, 400);
  const url = env('SUPABASE_URL');
  const key = env('SUPABASE_SERVICE_ROLE_KEY');
  if (!url || !key) return respond({ success: false, error: 'Unavailable' }, 503);
  let result: { ok: boolean; code?: string; secret?: string; session?: unknown };
  try {
    const response = await doFetch(`${restBaseUrl(url, env('SUPABASE_REST_URL'))}/rpc/redeem_pairing_code`, {
      method: 'POST', headers: { apikey: key, Authorization: `Bearer ${key}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({ p_code: code, p_ip: clientAddress(req), p_user_agent: clientUserAgent(req) }),
      signal: AbortSignal.timeout(15000), redirect: 'error',
    });
    if (!response.ok) throw new Error(`status ${response.status}`);
    result = await response.json();
  } catch { return respond({ success: false, error: 'Unavailable' }, 503); }
  if (!result.ok) {
    if (result.code === 'rate_limited') return respond({ success: false, code: 'rate_limited', error: 'Too many tries. Wait a few minutes.' }, 429, { 'Retry-After': '600' });
    return respond({ success: false, code: 'PAIRING_CODE_INVALID', error: 'This code was used or has expired. Ask for a new one.' }, 409);
  }
  try {
    return respond({ success: true, data: await seal(String(result.secret), code, nonce, result.session) });
  } catch {
    // The code is spent and the session exists but cannot be delivered: the person asks for a new code.
    return respond({ success: false, error: 'Unavailable' }, 503);
  }
}

