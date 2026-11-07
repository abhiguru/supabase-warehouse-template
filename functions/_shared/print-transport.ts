// One way for every print function to hand finished printer bytes to the printer, on a Linux host (CUPS) or a Windows host (print bridge).
//
//   submitRawJob({ bytes, docName, jobType }) -> RawJobResult
//
// PRINT_TRANSPORT (print-config.ts) picks the path; the result has one shape for both:
//   ok         the printer side accepted the job (CUPS answered with a job id, or the bridge answered 2xx with success true).
//   transport  'cups' | 'bridge'.
//   jobId      the CUPS job id; null on the bridge (it has none).
//   confirmed  ok AND a job id the status monitor can follow (print-status-monitor.ts). A bridge success is ok but not confirmed:
//              the job is recorded as sent, outcome unknown, never as completed.
//   unconfirmed  only on a failure: the job may be on paper anyway (no answer within the timeout, or an answer that does not
//              confirm it). The caller records it as 'unknown' and never resubmits on a guess.
//   error      a short text that is safe to show; host names, tokens and library messages stay in the server log.
//
// The bytes are sent as they are (binary-clean: ESC/P2 page-length parameters contain 0x0A and 0x0C). The caller's Authorization header
// is never forwarded: the bridge gets its own token (PRINTBRIDGE_TOKEN), which is required.

import { Buffer } from 'node:buffer';
import { ippPrinter } from './ipp-client.ts';
import { submittedJob } from './ipp-validate.ts';
import { SUBMIT_TIMEOUT_MS, submitWithTimeout } from './print-monitor-rule.ts';
import {
  DEFAULT_PRINTER_NAME, bridgeBaseUrl, cupsJobUser, cupsQueueUrl, printTransportName, printerName, safeDocName,
  type EnvGet, type PrintTransportName,
} from './print-config.ts';

export type PrintJobType = 'GRN' | 'Dispatch' | 'Invoice' | 'Raw';

export interface RawJobRequest {
  bytes: Uint8Array;
  docName: string;
  jobType: PrintJobType;
}

export interface RawJobResult {
  ok: boolean;
  transport: PrintTransportName;
  jobId: number | null;
  confirmed: boolean;
  jobUri?: string;
  unconfirmed?: boolean;
  error?: string;
}

/** What the transport talks to; tests pass their own. */
export interface TransportDeps {
  env: EnvGet;
  fetch: typeof fetch;
  /** One IPP Print-Job: the reply, or a rejection. */
  ippPrintJob: (queueUrl: string, message: Record<string, unknown>) => Promise<unknown>;
  timeoutMs: number;
  /** Opens a TCP connection to the bridge and closes it again; rejects when it cannot be made within the time. Defaults to Deno.connect. */
  probe?: (hostname: string, port: number, timeoutMs: number) => Promise<void>;
}

/** How long the bridge connection may take before the bridge counts as not reachable (a firewall that drops packets shows up as this). */
export const BRIDGE_CONNECT_TIMEOUT_MS = 3000;

const defaultProbe = async (hostname: string, port: number, timeoutMs: number): Promise<void> => {
  let timer: ReturnType<typeof setTimeout> | undefined;
  const attempt = Deno.connect({ hostname, port });
  const timeout = new Promise<never>((_, reject) => { timer = setTimeout(() => reject(new Error('connect timeout')), timeoutMs); });
  try {
    const conn = await Promise.race([attempt, timeout]);
    conn.close();
  } catch (error) {
    // A connection that completes after the time ran out is closed, not leaked.
    attempt.then(conn => conn.close(), () => {});
    throw error;
  } finally {
    if (timer !== undefined) clearTimeout(timer);
  }
};

/** Errors that mean nothing was sent: the connection was refused, the host or network is unreachable, or the name did not resolve. */
const PRE_SEND_ERROR = /connection refused|econnrefused|unreachable|enetunreach|ehostunreach|no route to host|dns error|failed to lookup|enotfound|name or service not known/i;

function errorText(error: unknown): string {
  const parts: string[] = [];
  let current: unknown = error;
  for (let depth = 0; depth < 4 && current; depth++) {
    const { message, cause } = current as { message?: unknown; cause?: unknown };
    if (typeof message === 'string') parts.push(message);
    current = cause;
  }
  return parts.join(' | ');
}

const defaultDeps = (): TransportDeps => ({
  env: name => Deno.env.get(name),
  fetch: (input, init) => fetch(input, init),
  ippPrintJob: async (queueUrl, message) => {
    const printer = ippPrinter(queueUrl);
    return await new Promise((resolve, reject) => {
      printer.execute('Print-Job', message, (err, res) => (err ? reject(err) : resolve(res)));
    });
  },
  timeoutMs: SUBMIT_TIMEOUT_MS,
});

const failed = (transport: PrintTransportName, error: string, unconfirmed = false): RawJobResult =>
  ({ ok: false, transport, jobId: null, confirmed: false, error, ...(unconfirmed ? { unconfirmed: true } : {}) });

export async function submitRawJob(request: RawJobRequest, deps: TransportDeps = defaultDeps()): Promise<RawJobResult> {
  const transport = printTransportName(deps.env);
  if (transport === null) return failed('cups', 'PRINT_TRANSPORT must be cups or bridge');
  if (!(request.bytes instanceof Uint8Array) || request.bytes.length === 0) return failed(transport, 'Nothing to print');
  const docName = safeDocName(request.docName);
  return transport === 'bridge' ? await submitToBridge(request, docName, deps) : await submitToCups(request, docName, deps);
}

async function submitToCups(request: RawJobRequest, docName: string, deps: TransportDeps): Promise<RawJobResult> {
  const queueUrl = cupsQueueUrl(deps.env);
  if (queueUrl === null) return failed('cups', 'PRINTER_NAME is not a valid CUPS queue name');
  const message = {
    'operation-attributes-tag': {
      'requesting-user-name': cupsJobUser(request.jobType),
      'job-name': docName,
      'document-format': 'application/vnd.cups-raw', // raw: CUPS runs no filter over the bytes
    },
    data: Buffer.from(request.bytes),
  };
  let reply: unknown;
  try {
    // Bounded so the submission and the status monitor fit the worker's lifetime (print-monitor-rule.ts).
    reply = await submitWithTimeout(() => deps.ippPrintJob(queueUrl, message), deps.timeoutMs);
  } catch (error) {
    console.error('print-transport: IPP error:', error instanceof Error ? error.name : 'unknown');
    return failed('cups', 'The print service could not be reached');
  }
  if (reply === null) {
    console.error(`print-transport: no IPP reply within ${deps.timeoutMs / 1000} s`);
    return failed('cups', 'The printer did not confirm the job', true);
  }
  const submitted = submittedJob(reply);
  if (!submitted.ok) return failed('cups', 'The printer did not confirm the job', true);
  return { ok: true, transport: 'cups', jobId: submitted.jobId, confirmed: true, jobUri: submitted.jobUri };
}

async function submitToBridge(request: RawJobRequest, docName: string, deps: TransportDeps): Promise<RawJobResult> {
  const base = bridgeBaseUrl(deps.env);
  if (base === null) return failed('bridge', 'PRINTBRIDGE_URL is not set to an http address');
  const token = (deps.env('PRINTBRIDGE_TOKEN') ?? '').trim();
  // The bridge prints for whoever holds the token: with none there is nothing to send, and nothing is sent without it.
  if (token === '') return failed('bridge', 'PRINTBRIDGE_TOKEN is not set');
  const printer = printerName(deps.env, 'bridge');
  if (printer === null) return failed('bridge', 'PRINTER_NAME is not a valid printer name');
  // First a bare connection: if it cannot be made (refused, dropped by a firewall, no route), nothing was sent and the job is plainly failed.
  const target = new URL(base);
  const port = Number(target.port) || (target.protocol === 'https:' ? 443 : 80);
  try {
    await (deps.probe ?? defaultProbe)(target.hostname.replace(/^\[|\]$/g, ''), port, Math.min(BRIDGE_CONNECT_TIMEOUT_MS, deps.timeoutMs));
  } catch (error) {
    console.error('print-transport: bridge connection failed:', error instanceof Error ? error.name : 'unknown');
    return failed('bridge', 'The print bridge could not be reached');
  }
  let response: Response;
  try {
    response = await deps.fetch(`${base}/print/raw`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/octet-stream',
        'X-Printer': printer,
        'X-Doc-Name': docName,
        'X-Print-Token': token,
      },
      body: request.bytes as BodyInit, // sent as is: no text encoding, no line-ending translation
      signal: AbortSignal.timeout(deps.timeoutMs),
      redirect: 'error',
    });
  } catch (error) {
    const name = String((error as { name?: unknown } | null)?.name ?? 'unknown');
    console.error('print-transport: bridge request failed:', name);
    // The connection was made, so the bytes may have been sent: only an error that clearly happened before any byte was sent
    // (refused, unreachable, DNS) is a plain failure. A timeout, a reset or anything unknown may still have printed.
    return PRE_SEND_ERROR.test(errorText(error))
      ? failed('bridge', 'The print bridge could not be reached')
      : failed('bridge', 'The print bridge did not confirm the job', true);
  }
  let body: unknown = null;
  try { body = await response.json(); } catch { /* not JSON: handled below */ }
  const success = typeof body === 'object' && body !== null && (body as { success?: unknown }).success === true;
  if (response.ok && success) return { ok: true, transport: 'bridge', jobId: null, confirmed: false };
  console.error(`print-transport: bridge answered ${response.status}`);
  if (response.status === 401) return failed('bridge', 'The print bridge refused the token');
  if (response.status === 403) return failed('bridge', 'The print bridge does not serve this printer queue (PRINTER_NAME must equal the bridge\'s -Printer)');
  if (response.status === 413) return failed('bridge', 'The print job is larger than the 2 MB the print bridge accepts');
  // A 2xx that does not say success, or a 5xx after the body was sent: the job may have reached the spooler.
  return response.ok
    ? failed('bridge', 'The print bridge did not confirm the job', true)
    : response.status >= 500
      ? failed('bridge', 'The Windows spooler refused the job')
      : failed('bridge', 'The print bridge could not print the job');
}

/**
 * How a print function records and answers a result (one place, so the three preprinted functions agree).
 *  tracked      CUPS job id known: row 'printing', status monitor started.
 *  sent         bridge accepted: row 'unknown' with a note (no job id to follow), the request still succeeded.
 *  unconfirmed  may be on paper: row 'unknown', answer 502 with unconfirmed true and code PRINT_UNCONFIRMED.
 *  failed       nothing was printed: no row, answer 502 with code PRINTER_FAILED.
 */
export type JobOutcome =
  | { kind: 'tracked'; row: { cups_job_id: number; status: 'printing' } }
  | { kind: 'sent'; row: { cups_job_id: null; status: 'unknown'; error_message: string } }
  | { kind: 'unconfirmed'; row: { cups_job_id: null; status: 'unknown'; error_message: string } }
  | { kind: 'failed'; error: string };

/** The note on a row whose send the printer side never confirmed (print-request.ts recognizes a repeated request by it). */
export const UNCONFIRMED_NOTE = 'The printer did not confirm the job';

export function jobOutcome(result: RawJobResult): JobOutcome {
  if (result.ok && result.confirmed && result.jobId !== null) return { kind: 'tracked', row: { cups_job_id: result.jobId, status: 'printing' } };
  if (result.ok) {
    return { kind: 'sent', row: { cups_job_id: null, status: 'unknown', error_message: 'Sent to the print bridge, which does not report when the job ends. Check the printer.' } };
  }
  if (result.unconfirmed) return { kind: 'unconfirmed', row: { cups_job_id: null, status: 'unknown', error_message: UNCONFIRMED_NOTE } };
  return { kind: 'failed', error: result.error ?? 'The printer could not print the job' };
}

/** The 502 answer for an outcome that is not a success (the caller adds print_job_id where a row exists). */
export function printFailureBody(outcome: Extract<JobOutcome, { kind: 'unconfirmed' | 'failed' }>, printJobId: string | null): Record<string, unknown> {
  const timestamp = new Date().toISOString();
  if (outcome.kind === 'unconfirmed') {
    // The job may be on paper: true even when it could not be logged (print_job_id null).
    return { success: false, error: 'The printer did not confirm the job', code: 'PRINT_UNCONFIRMED', unconfirmed: true, print_job_id: printJobId, timestamp };
  }
  return { success: false, error: outcome.error, code: 'PRINTER_FAILED', timestamp };
}

/** The configured queue name for rows and answers (print_jobs.printer_name); the default when the setting is invalid, which submitRawJob refuses anyway. */
export function configuredPrinterName(): string {
  const get: EnvGet = name => Deno.env.get(name);
  return printerName(get) ?? DEFAULT_PRINTER_NAME;
}
