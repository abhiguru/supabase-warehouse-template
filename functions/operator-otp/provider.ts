import { isProviderPlaceholder } from './provider-placeholder.mjs';

// MSG91 Flow submission accepts a request; handset delivery requires a separate
// physical check. Never include provider responses, keys or OTPs in errors.
export type DeliveryErrorCode =
  | 'provider_configuration'
  | 'provider_auth'
  | 'provider_validation'
  | 'provider_rate_limited'
  | 'provider_rejected'
  | 'provider_invalid_response'
  | 'provider_unavailable'
  // A timeout or an abort: MSG91 may have accepted, and billed, the request.
  | 'provider_ambiguous';

export class Msg91DeliveryError extends Error {
  readonly code: DeliveryErrorCode;
  // The HTTP requests made to the provider before this failure (0 when none was sent).
  readonly attempts: number;
  constructor(code: DeliveryErrorCode, attempts = 0) {
    super('MSG91 delivery unavailable');
    this.name = 'Msg91DeliveryError';
    this.code = code;
    this.attempts = attempts;
  }
}

// providerId is MSG91's request ID, or null when the answer was a success without one.
export type Delivery = { providerId: string | null; attempts: number };

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

// A name of the error a fetch rejects with when the request timed out or was aborted.
function timedOut(error: unknown): boolean {
  const name = typeof error === 'object' && error !== null ? (error as { name?: unknown }).name : undefined;
  return name === 'TimeoutError' || name === 'AbortError';
}

// MSG91's request ID: the `message` of a success answer, trimmed, at most 255 characters of
// [A-Za-z0-9._:-]. Text that is not such an ID (spaces, symbols) counts as no ID (null): the
// answer is still a success and the caller records `success_no_id`.
function requestId(message: string): string | null {
  const id = message.trim().slice(0, 255);
  return /^[A-Za-z0-9._:-]+$/.test(id) ? id : null;
}

export async function deliverOtp(
  phone: string,
  code: string,
  authKey: string | undefined,
  templateId: string | undefined,
  send: typeof fetch = fetch,
): Promise<Delivery> {
  // One rule for "not a provider value" (provider-placeholder.mjs, shared with setup and the
  // doctor): nothing is sent with a placeholder or a fixture sentinel, whatever the network.
  if (isProviderPlaceholder(authKey) || isProviderPlaceholder(templateId)) {
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
  let attempts = 0;
  for (let attempt = 0; attempt < 2; attempt++) {
    let response: Response;
    attempts++;
    try {
      response = await send(endpoint, {
        method: 'POST',
        headers: { authkey: authKey!, accept: 'application/json', 'Content-Type': 'application/json' },
        body,
        signal: AbortSignal.timeout(10000),
        redirect: 'error',
      });
    } catch (error) {
      // A timeout can occur after MSG91 accepts a request. Do not risk a
      // duplicate OTP by retrying an ambiguous network failure, and report a
      // timeout or abort as ambiguous: it may have been billed, so the caller
      // does not give the quota back.
      throw new Msg91DeliveryError(timedOut(error) ? 'provider_ambiguous' : 'provider_unavailable', attempts);
    }
    const result = await response.json().catch(() => null);
    // The answer says `success` or `error` in `type`, `status` or both. Only an answer
    // that is unambiguous counts: a success that no field contradicts, or an error
    // that no field contradicts. Two fields that disagree are neither.
    const fields = result && typeof result === 'object' ? [result.type, result.status] : [];
    const success = fields.includes('success');
    const refused = fields.includes('error');
    if (!response.ok) {
      // Retry only an explicit provider rejection. A contradictory success
      // body makes acceptance ambiguous even when the HTTP status is 5xx.
      if (attempt === 0 && retryableStatuses.has(response.status) && refused && !success) {
        await new Promise(resolve => setTimeout(resolve, 250));
        continue;
      }
      throw new Msg91DeliveryError(responseError(response.status), attempts);
    }
    if (!result || typeof result !== 'object') throw new Msg91DeliveryError('provider_invalid_response', attempts);
    if (success && refused) throw new Msg91DeliveryError('provider_invalid_response', attempts);
    if (!success) throw new Msg91DeliveryError('provider_rejected', attempts);
    if (result.message == null) return { providerId: null, attempts };
    if (typeof result.message !== 'string' || !result.message.trim()) {
      throw new Msg91DeliveryError('provider_invalid_response', attempts);
    }
    return { providerId: requestId(result.message), attempts };
  }
  throw new Msg91DeliveryError('provider_unavailable', attempts);
}
