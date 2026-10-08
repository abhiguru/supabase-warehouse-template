// MSG91 Flow submission accepts a request; handset delivery requires a separate
// physical check. Never include provider responses, keys or OTPs in errors.
export type DeliveryErrorCode =
  | 'provider_configuration'
  | 'provider_auth'
  | 'provider_validation'
  | 'provider_rate_limited'
  | 'provider_rejected'
  | 'provider_invalid_response'
  | 'provider_unavailable';

export class Msg91DeliveryError extends Error {
  readonly code: DeliveryErrorCode;
  constructor(code: DeliveryErrorCode) {
    super('MSG91 delivery unavailable');
    this.name = 'Msg91DeliveryError';
    this.code = code;
  }
}

const endpoint = 'https://control.msg91.com/api/v5/flow/';
const retryableStatuses = new Set([429, 502, 503, 504]);

function normalizedPhone(phone: string): string {
  const digits = phone.startsWith('+') ? phone.slice(1) : phone;
  if (/^[0-9]{10}$/.test(digits)) return `91${digits}`;
  if (/^91[0-9]{10}$/.test(digits)) return digits;
  throw new Msg91DeliveryError('provider_validation');
}

function responseError(status: number): DeliveryErrorCode {
  if (status === 401 || status === 403) return 'provider_auth';
  if (status === 400 || status === 404 || status === 422) return 'provider_validation';
  if (status === 429) return 'provider_rate_limited';
  return 'provider_unavailable';
}

export async function deliverOtp(
  phone: string,
  code: string,
  authKey: string | undefined,
  templateId: string | undefined,
  send: typeof fetch = fetch,
): Promise<string | null> {
  if (!authKey || !templateId || authKey.startsWith('your-') || templateId.startsWith('your-')) {
    throw new Msg91DeliveryError('provider_configuration');
  }
  if (!/^[0-9]{6}$/.test(code)) throw new Msg91DeliveryError('provider_validation');
  const recipient = normalizedPhone(phone);
  const body = JSON.stringify({
    template_id: templateId,
    short_url: '0',
    realTimeResponse: '1',
    recipients: [{ mobiles: recipient, OTP: code }],
  });
  for (let attempt = 0; attempt < 2; attempt++) {
    let response: Response;
    try {
      response = await send(endpoint, {
        method: 'POST',
        headers: { authkey: authKey, accept: 'application/json', 'Content-Type': 'application/json' },
        body,
        signal: AbortSignal.timeout(10000),
        redirect: 'error',
      });
    } catch {
      // A timeout can occur after MSG91 accepts a request. Do not risk a
      // duplicate OTP by retrying an ambiguous network failure.
      throw new Msg91DeliveryError('provider_unavailable');
    }
    const result = await response.json().catch(() => null);
    if (!response.ok) {
      // Retry only an explicit provider rejection. A contradictory success
      // body makes acceptance ambiguous even when the HTTP status is 5xx.
      if (attempt === 0 && retryableStatuses.has(response.status)
        && result && typeof result === 'object'
        && (result.type === 'error' || result.status === 'error')) {
        await new Promise(resolve => setTimeout(resolve, 250));
        continue;
      }
      throw new Msg91DeliveryError(responseError(response.status));
    }
    if (!result || typeof result !== 'object') throw new Msg91DeliveryError('provider_invalid_response');
    if (result.type !== 'success' && result.status !== 'success') {
      throw new Msg91DeliveryError('provider_rejected');
    }
    if (result.message == null) return null;
    if (typeof result.message !== 'string' || !result.message.trim()) {
      throw new Msg91DeliveryError('provider_invalid_response');
    }
    return result.message.trim().slice(0, 255);
  }
  throw new Msg91DeliveryError('provider_unavailable');
}
