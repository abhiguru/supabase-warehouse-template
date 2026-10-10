import { corsHeaders, handleCors } from '../_shared/cors.ts';
import { readBoundedJson } from './body.ts';
import { deliverOtp, Msg91DeliveryError } from './provider.ts';

type RpcResult = { success: boolean; code?: string; retry_at?: string; data?: Record<string, unknown> };
// Everything the handler reaches outside itself, so tests can stand in for it.
export type HandlerDeps = { env: (name: string) => string | undefined; fetch: typeof fetch };
const headers = { ...corsHeaders, 'Content-Type': 'application/json', 'Cache-Control': 'no-store' };

function respond(body: unknown, status = 200, extra: Record<string, string> = {}): Response {
  return new Response(JSON.stringify(body), { status, headers: { ...headers, ...extra } });
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

function failure(result: { code?: string; retry_at?: string }): Response {
  const code = result.code || 'invalid_request';
  const status = code === 'rate_limited' || code === 'resend_cooldown' || code === 'enrollment_limited' ? 429
    : code === 'account_unavailable' ? 403
    : code === 'unavailable' ? 503 : 400;
  const error = code === 'rate_limited' ? 'Too many OTP requests. Try again later.'
    : code === 'resend_cooldown' ? 'Please wait before requesting another OTP.'
    : code === 'enrollment_limited' ? 'Too many new access requests. Try again tomorrow.'
    : code === 'account_unavailable' ? 'Account unavailable'
    : code === 'invalid_otp' ? 'Invalid or expired OTP'
    : code === 'invalid_token' ? 'Enrollment session expired. Sign in again.'
    : code === 'unavailable' ? 'OTP service unavailable' : 'Invalid request';
  // The cooldown can be the 60 s resend wait or the 15 minute slow lane; say which.
  const retryAt = code === 'resend_cooldown' && typeof result.retry_at === 'string' ? Date.parse(result.retry_at) : NaN;
  if (Number.isFinite(retryAt)) {
    const seconds = Math.max(1, Math.ceil((retryAt - Date.now()) / 1000));
    return respond({ success: false, error, retry_after_seconds: seconds }, status, { 'Retry-After': String(seconds) });
  }
  return respond({ success: false, error }, status);
}

// Trust boundary: Cloudflare Tunnel is the only ingress and the gateway is
// published on loopback only, so every external request carries a
// CF-Connecting-IP written by Cloudflare's edge. Kong trusts that header
// from the tunnel hop (KONG_REAL_IP_HEADER in docker/docker-compose.yml),
// keys its per-client rate limits on it, and forwards it unchanged, so it
// is read here instead of X-Forwarded-For. A direct loopback caller could
// set it, but such a caller is already inside the host trust boundary.
// Phone and warehouse limits still apply if it is absent.
function clientAddress(req: Request): string | null {
  const clientIp = req.headers.get('CF-Connecting-IP');
  return clientIp && /^[0-9a-fA-F:.]{3,45}$/.test(clientIp) ? clientIp : null;
}

export async function handle(req: Request, overrides: Partial<HandlerDeps> = {}): Promise<Response> {
  const deps: HandlerDeps = { env: name => Deno.env.get(name), fetch: (input, init) => fetch(input, init), ...overrides };
  const cors = handleCors(req);
  if (cors) return cors;
  if (req.method !== 'POST') return respond({ success: false, error: 'Method not allowed' }, 405);
  if (deps.env('AUTH_MODE') !== 'operator' || deps.env('APP_ENV') !== 'production') {
    return failure({ code: 'unavailable' });
  }
  const operation = new URL(req.url).pathname.split('/').filter(Boolean).at(-1);
  if (!['request', 'verify', 'status', 'signout'].includes(operation || '')) return respond({ success: false, error: 'Not found' }, 404);
  let body: Record<string, unknown>;
  try {
    body = await readBoundedJson(req);
  } catch { return failure({ code: 'invalid_request' }); }

  try {
    if (operation === 'request') {
      if (typeof body.phone_number !== 'string') return failure({ code: 'invalid_request' });
      const phone = body.phone_number.replace(/\D/g, '');
      if (!/^(?:91)?[0-9]{10}$/.test(phone)) return failure({ code: 'invalid_request' });
      const prepared = await rpc(deps, 'operator_prepare_otp', { p_phone_number: phone, p_ip_address: clientAddress(req) });
      if (!prepared.success) return failure(prepared);
      const data = prepared.data!;
      let providerId: string | null;
      try {
        const config = await rpc(deps, 'operator_sms_config', {});
        if (!config.success || !config.data) throw new Msg91DeliveryError('provider_configuration');
        providerId = await deliverOtp(String(data.phone_number), String(data.otp_code),
          String(config.data.auth_key || ''), String(config.data.flow_id || ''), deps.fetch);
      } catch (error) {
        await rpc(deps, 'operator_finish_otp', {
          p_request_id: data.request_id,
          p_delivered: false,
          p_provider_id: error instanceof Msg91DeliveryError ? error.code : 'provider_unavailable',
        });
        return respond({ success: false, error: 'SMS delivery unavailable. Try again later.' }, 503);
      }
      const finalized = await rpc(deps, 'operator_finish_otp', {
        p_request_id: data.request_id, p_delivered: true, p_provider_id: providerId,
      });
      if (!finalized.success) return respond({ success: false, error: 'SMS delivery unavailable. Try again later.' }, 503);
      return respond({ success: true, data: { request_id: `OTP_${data.request_id}`, expires_at: data.expires_at },
        message: 'OTP sent successfully' });
    }
    if (operation === 'verify') {
      if (typeof body.phone_number !== 'string' || typeof body.otp_code !== 'string') return failure({ code: 'invalid_request' });
      const phone = body.phone_number.replace(/\D/g, '');
      if (!/^(?:91)?[0-9]{10}$/.test(phone) || !/^[0-9]{6}$/.test(body.otp_code)) return failure({ code: 'invalid_request' });
      const result = await rpc(deps, 'operator_verify_otp', {
        p_phone_number: phone, p_otp_code: body.otp_code,
        p_name: typeof body.name === 'string' ? body.name : null,
        p_display_name: typeof body.display_name === 'string' ? body.display_name : null,
        // The source address separates the requester's wrong-attempt budget from everyone else's.
        p_ip_address: clientAddress(req),
      });
      return result.success ? respond(result) : failure(result);
    }
    if (typeof body.enrollment_token !== 'string' || !/^[0-9a-f]{64}$/.test(body.enrollment_token)) return failure({ code: 'invalid_request' });
    const result = operation === 'status'
      ? await rpc(deps, 'operator_enrollment_status', { p_token: body.enrollment_token })
      : await rpc(deps, 'operator_enrollment_signout', { p_token: body.enrollment_token });
    return result.success ? respond(result) : failure(result);
  } catch {
    return respond({ success: false, error: 'Authentication service unavailable' }, 503);
  }
}
