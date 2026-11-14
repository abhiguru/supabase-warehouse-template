// generate-accountant-pack: one zip of a period's accountant pack (WH-158; contract product/tech/accountant-pack.md section 4).
//
// The figures are get_accountant_pack's, called with the caller's own token, so warehouse_security.authorize_rpc and the function's own
// check decide access (administrators and supervisors) and the database records the pack made. Nothing is worked out here: the pure
// builders (accountant-pack-files.ts, tally-xml.ts) only format, and zip.ts stores the files. The zip is the response body; no copy is kept.
// No server-key call: the server key is used only by validateUserAccess for the profile lookup, as in every signed-in function.
// Nothing of the payload (names, GSTINs, amounts) is ever logged: a log line carries a code and the request id only.
import { validateUserAccess, createAuthErrorResponse, requestId } from './auth-helpers.ts';
import { securityHeaders } from './security-headers.ts';
import { documentRequestBody } from './request-body.ts';
import { restBaseUrl } from './rest-url.ts';
import { accountantPackFiles, packFileName } from './accountant-pack-files.ts';
import type { AccountantPackData } from './accountant-pack-files.ts';
import { zipStored } from './zip.ts';

export interface AccountantPackDeps {
  /** Throws { status, message } (401, 403, 503) when the caller may not go on. */
  authorize(req: Request): Promise<unknown>;
  /** get_accountant_pack(p_from, p_to) as the caller: the RPC's answer, or a PostgREST error with its SQLSTATE code. */
  read(req: Request, from: string, to: string): Promise<{ data: unknown; error: { code?: string } | null }>;
  /** Most CSV data rows a pack may hold (documents' rows, payments and stock added up). */
  maxRows: number;
  /** Largest zip answered (the app's download cap). */
  maxZipBytes: number;
}

const JSON_HEADERS = { ...securityHeaders, 'Content-Type': 'application/json', 'Cache-Control': 'no-store' };
const UNAVAILABLE = 'The accountant pack could not be made now. Try again later.';
const TOO_LONG = 'The accountant pack is too large. Choose a shorter period.';

function refusal(status: number, code: string, error: string, req: Request): Response {
  if (status >= 500) console.error(`generate-accountant-pack status=${status} code=${code} request_id=${requestId(req)}`);
  return new Response(JSON.stringify({ success: false, error, code }), { status, headers: JSON_HEADERS });
}

const ISO_DAY = /^(\d{4})-(\d{2})-(\d{2})$/;
/** A real calendar day written YYYY-MM-DD. */
function isDay(value: unknown): value is string {
  if (typeof value !== 'string') return false;
  const m = ISO_DAY.exec(value);
  if (!m) return false;
  const d = new Date(Date.UTC(Number(m[1]), Number(m[2]) - 1, Number(m[3])));
  return d.getUTCFullYear() === Number(m[1]) && d.getUTCMonth() === Number(m[2]) - 1 && d.getUTCDate() === Number(m[3]);
}

const READ_REFUSALS: Record<string, number> = { INVALID_PERIOD: 400, PERIOD_ACROSS_YEARS: 400, NOTHING_IN_PERIOD: 404 };

function rowCount(data: AccountantPackData): number {
  let rows = 0;
  for (const document of data.documents ?? []) rows += Array.isArray(document.rows) ? document.rows.length : 0;
  return rows + (Array.isArray(data.payments) ? data.payments.length : 0) + (Array.isArray(data.stock) ? data.stock.length : 0);
}

export function makeAccountantPackHandler(deps: AccountantPackDeps): (req: Request) => Promise<Response> {
  return async (req: Request): Promise<Response> => {
    if (req.method !== 'POST') return createAuthErrorResponse({ status: 405, message: 'POST required' }, securityHeaders, req);
    try {
      await deps.authorize(req);
    } catch (error) {
      return createAuthErrorResponse(error, securityHeaders, req);
    }

    let body: unknown;
    try {
      body = await documentRequestBody(req);
    } catch {
      return refusal(400, 'INVALID_REQUEST', 'Send from_date and to_date as YYYY-MM-DD.', req);
    }
    if (!body || typeof body !== 'object' || Array.isArray(body)) {
      return refusal(400, 'INVALID_REQUEST', 'Send from_date and to_date as YYYY-MM-DD.', req);
    }
    const { from_date: from, to_date: to } = body as Record<string, unknown>;
    if (!isDay(from) || !isDay(to)) return refusal(400, 'INVALID_REQUEST', 'Send from_date and to_date as YYYY-MM-DD.', req);

    let answer: { data: unknown; error: { code?: string } | null };
    try {
      answer = await deps.read(req, from, to);
    } catch {
      return refusal(503, 'PACK_UNAVAILABLE', UNAVAILABLE, req);
    }
    if (answer.error) {
      if (answer.error.code === '42501') return refusal(403, 'PACK_FORBIDDEN', 'Only administrators and supervisors can make the accountant pack.', req);
      if (answer.error.code === '57014') return refusal(400, 'PACK_TOO_LONG', TOO_LONG, req);
      return refusal(503, 'PACK_UNAVAILABLE', UNAVAILABLE, req);
    }
    const result = answer.data as { success?: unknown; reason?: unknown; error?: unknown; data?: unknown } | null;
    if (!result || typeof result !== 'object') return refusal(503, 'PACK_UNAVAILABLE', UNAVAILABLE, req);
    if (result.success !== true) {
      const reason = typeof result.reason === 'string' ? result.reason : '';
      const status = READ_REFUSALS[reason];
      if (!status) return refusal(503, 'PACK_UNAVAILABLE', UNAVAILABLE, req);
      return refusal(status, reason, typeof result.error === 'string' ? result.error : 'Choose another period.', req);
    }
    const data = result.data as AccountantPackData;
    if (!data || typeof data !== 'object' || !Array.isArray(data.documents)) return refusal(503, 'PACK_UNAVAILABLE', UNAVAILABLE, req);
    if (rowCount(data) > deps.maxRows) return refusal(400, 'PACK_TOO_LONG', TOO_LONG, req);

    let zip: Uint8Array;
    let name: string;
    try {
      const encoder = new TextEncoder();
      const files = accountantPackFiles(data);
      // The entry times are the read's made_at: the same read gives the same bytes.
      const made = new Date(data.made_at);
      if (Number.isNaN(made.getTime())) throw new Error('made_at is not a time');
      zip = zipStored(files.map(f => ({ name: f.name, bytes: encoder.encode(f.text) })), made);
      name = packFileName(data);
    } catch {
      // A bad amount, date or ledger name in the read: never answered with the builder's text, which can quote a value.
      return refusal(503, 'PACK_UNAVAILABLE', UNAVAILABLE, req);
    }
    if (zip.byteLength > deps.maxZipBytes) return refusal(400, 'PACK_TOO_LONG', TOO_LONG, req);

    return new Response(zip, {
      status: 200,
      headers: {
        ...securityHeaders,
        'Content-Type': 'application/zip',
        'Content-Disposition': `attachment; filename*=UTF-8''${encodeURIComponent(name)}`,
        'Cache-Control': 'no-store',
      },
    });
  };
}

/** get_accountant_pack with the caller's own token, straight to PostgREST (as validateUserAccess reads the profile). */
async function readPack(req: Request, from: string, to: string): Promise<{ data: unknown; error: { code?: string } | null }> {
  const url = Deno.env.get('SUPABASE_URL');
  const key = Deno.env.get('SUPABASE_ANON_KEY');
  if (!url || !key) throw new Error('Server configuration missing');
  const response = await fetch(`${restBaseUrl(url, Deno.env.get('SUPABASE_REST_URL'))}/rpc/get_accountant_pack`, {
    method: 'POST',
    headers: { apikey: key, Authorization: req.headers.get('Authorization') ?? '', 'Content-Type': 'application/json', Accept: 'application/json' },
    body: JSON.stringify({ p_from: from, p_to: to }),
    redirect: 'error',
    // The read's own limit is the authenticated role's 8 s statement timeout; this only bounds a stalled connection.
    signal: AbortSignal.timeout(30000),
  });
  const text = await response.text();
  let parsed: unknown = null;
  try { parsed = text ? JSON.parse(text) : null; } catch { parsed = null; }
  if (!response.ok) {
    const code = parsed && typeof parsed === 'object' && 'code' in parsed ? String((parsed as { code: unknown }).code ?? '') : '';
    return { data: null, error: { code } };
  }
  return { data: parsed, error: null };
}

export const accountantPack = makeAccountantPackHandler({
  authorize: req => validateUserAccess(req),
  read: readPack,
  maxRows: 50_000,
  maxZipBytes: 25 * 1024 * 1024,
});
