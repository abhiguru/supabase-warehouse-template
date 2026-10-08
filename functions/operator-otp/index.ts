import { serve } from 'https://deno.land/std@0.192.0/http/server.ts';
import { corsHeaders, handleCors } from '../_shared/cors.ts';
import { readBoundedJson } from './body.ts';
import { deliverOtp, Msg91DeliveryError } from './provider.ts';

type RpcResult = { success: boolean; code?: string; data?: Record<string, unknown> };
const headers = { ...corsHeaders, 'Content-Type': 'application/json', 'Cache-Control': 'no-store' };

function respond(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers });
}

async function rpc(name: string, params: Record<string, unknown>): Promise<RpcResult> {
  const url = Deno.env.get('SUPABASE_URL');
  const key = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
  if (!url || !key) throw new Error('Backend credentials missing');
  const response = await fetch(`${url}/rest/v1/rpc/${name}`, {
    method: 'POST',
    headers: { apikey: key, Authorization: `Bearer ${key}`, 'Content-Type': 'application/json' },
    body: JSON.stringify(params),
    signal: AbortSignal.timeout(15000),
    redirect: 'error',
  });
  if (!response.ok) throw new Error(`Auth database unavailable (${response.status})`);
  return await response.json();
}

function failure(code: string): Response {
  const status = code === 'rate_limited' || code === 'resend_cooldown' ? 429
    : code === 'account_unavailable' ? 403
    : code === 'unavailable' ? 503 : 400;
  const error = code === 'rate_limited' ? 'Too many OTP requests. Try again later.'
    : code === 'resend_cooldown' ? 'Please wait before requesting another OTP.'
    : code === 'account_unavailable' ? 'Account unavailable'
    : code === 'invalid_otp' ? 'Invalid or expired OTP'
    : code === 'invalid_token' ? 'Enrollment session expired. Sign in again.'
    : code === 'unavailable' ? 'OTP service unavailable' : 'Invalid request';
  return respond({ success: false, error }, status);
}

serve(async (req: Request) => {
  const cors = handleCors(req);
  if (cors) return cors;
  if (req.method !== 'POST') return respond({ success: false, error: 'Method not allowed' }, 405);
  if (Deno.env.get('AUTH_MODE') !== 'operator' || Deno.env.get('APP_ENV') !== 'production') {
    return failure('unavailable');
  }
  const operation = new URL(req.url).pathname.split('/').filter(Boolean).at(-1);
  if (!['request', 'verify', 'status', 'signout'].includes(operation || '')) return respond({ success: false, error: 'Not found' }, 404);
  let body: Record<string, unknown>;
  try {
    body = await readBoundedJson(req);
  } catch { return failure('invalid_request'); }

  try {
    if (operation === 'request') {
      if (typeof body.phone_number !== 'string') return failure('invalid_request');
      const phone = body.phone_number.replace(/\D/g, '');
      if (!/^(?:91)?[0-9]{10}$/.test(phone)) return failure('invalid_request');
      // Trust boundary: Cloudflare Tunnel is the only ingress and the gateway is
      // published on loopback only, so every external request carries a
      // CF-Connecting-IP written by Cloudflare's edge. Kong trusts that header
      // from the tunnel hop (KONG_REAL_IP_HEADER in docker/docker-compose.yml),
      // keys its per-client rate limits on it, and forwards it unchanged, so it
      // is read here instead of X-Forwarded-For. A direct loopback caller could
      // set it, but such a caller is already inside the host trust boundary.
      // Phone and global limits still apply if it is absent.
      const clientIp = req.headers.get('CF-Connecting-IP');
      const prepared = await rpc('operator_prepare_otp', {
        p_phone_number: phone,
        p_ip_address: clientIp && /^[0-9a-fA-F:.]{3,45}$/.test(clientIp) ? clientIp : null,
      });
      if (!prepared.success) return failure(prepared.code || 'invalid_request');
      const data = prepared.data!;
      let providerId: string | null;
      try {
        const config = await rpc('operator_sms_config', {});
        if (!config.success || !config.data) throw new Msg91DeliveryError('provider_configuration');
        providerId = await deliverOtp(String(data.phone_number), String(data.otp_code),
          String(config.data.auth_key || ''), String(config.data.flow_id || ''));
      } catch (error) {
        await rpc('operator_finish_otp', {
          p_request_id: data.request_id,
          p_delivered: false,
          p_provider_id: error instanceof Msg91DeliveryError ? error.code : 'provider_unavailable',
        });
        return respond({ success: false, error: 'SMS delivery unavailable. Try again later.' }, 503);
      }
      const finalized = await rpc('operator_finish_otp', {
        p_request_id: data.request_id, p_delivered: true, p_provider_id: providerId,
      });
      if (!finalized.success) return respond({ success: false, error: 'SMS delivery unavailable. Try again later.' }, 503);
      return respond({ success: true, data: { request_id: `OTP_${data.request_id}`, expires_at: data.expires_at },
        message: 'OTP sent successfully' });
    }
    if (operation === 'verify') {
      if (typeof body.phone_number !== 'string' || typeof body.otp_code !== 'string') return failure('invalid_request');
      const phone = body.phone_number.replace(/\D/g, '');
      if (!/^(?:91)?[0-9]{10}$/.test(phone) || !/^[0-9]{6}$/.test(body.otp_code)) return failure('invalid_request');
      const result = await rpc('operator_verify_otp', {
        p_phone_number: phone, p_otp_code: body.otp_code,
        p_name: typeof body.name === 'string' ? body.name : null,
        p_display_name: typeof body.display_name === 'string' ? body.display_name : null,
      });
      return result.success ? respond(result) : failure(result.code || 'invalid_request');
    }
    if (typeof body.enrollment_token !== 'string' || !/^[0-9a-f]{64}$/.test(body.enrollment_token)) return failure('invalid_request');
    const result = operation === 'status'
      ? await rpc('operator_enrollment_status', { p_token: body.enrollment_token })
      : await rpc('operator_enrollment_signout', { p_token: body.enrollment_token });
    return result.success ? respond(result) : failure(result.code || 'invalid_request');
  } catch {
    return respond({ success: false, error: 'Authentication service unavailable' }, 503);
  }
});
