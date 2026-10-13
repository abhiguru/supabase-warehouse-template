// Checks of IPP replies (npm:ipp decodes a reply into an object with a
// statusCode and attribute groups such as 'job-attributes-tag').
//
// PRINT4 (review 2026-10-13): printer status took a missing attribute block as
// {}, a missing accepting flag as true and any unrecognised state as "online";
// the print handlers answered success with a job id of undefined or 'unknown'.
// Nothing is reported from a reply until it is checked here. The job and
// printer state constants and their mappings moved here from ipp-types.ts
// (which re-exports them) as plain objects: Node strips TypeScript types but
// cannot load an enum, and this module imports nothing so that the node tests
// can load it directly.

export const IPPJobState = {
  PENDING: 3,
  PENDING_HELD: 4,
  PROCESSING: 5,
  PROCESSING_STOPPED: 6,
  CANCELED: 7,
  ABORTED: 8,
  COMPLETED: 9,
} as const;

export const IPPPrinterState = {
  IDLE: 3,
  PROCESSING: 4,
  STOPPED: 5,
} as const;

const PRINTER_STATE_NAMES: Record<number, string> = { 3: 'idle', 4: 'processing', 5: 'stopped' };
const PRINTER_STATE_NUMBERS: Record<string, number> = { idle: 3, processing: 4, stopped: 5 };

// 'unknown': CUPS accepted the job but never confirmed how it ended (it no longer
// lists it, or the monitor's time ran out), or the printer's reply did not
// confirm the job at all. Staff check such a job at the printer.
export type PrintJobStatus = 'queued' | 'printing' | 'completed' | 'cancelled' | 'failed' | 'unknown';
export type PrinterStatus = 'online' | 'offline' | 'error' | 'busy';

export function mapIPPStateToStatus(ippState: unknown): PrintJobStatus | null {
  if (typeof ippState === 'string') {
    const stateLower = ippState.toLowerCase();
    if (stateLower === 'pending' || stateLower === 'pending-held') return 'queued';
    if (stateLower === 'processing' || stateLower === 'processing-stopped') return 'printing';
    if (stateLower === 'completed') return 'completed';
    if (stateLower === 'canceled' || stateLower === 'cancelled') return 'cancelled';
    if (stateLower === 'aborted') return 'failed';
    return null;
  }
  switch (ippState) {
    case IPPJobState.PENDING:
    case IPPJobState.PENDING_HELD:
      return 'queued';
    case IPPJobState.PROCESSING:
    case IPPJobState.PROCESSING_STOPPED:
      return 'printing';
    case IPPJobState.COMPLETED:
      return 'completed';
    case IPPJobState.CANCELED:
      return 'cancelled';
    case IPPJobState.ABORTED:
      return 'failed';
    default:
      return null;
  }
}

export function isTerminalState(ippState: unknown): boolean {
  if (typeof ippState === 'string') {
    return ['completed', 'canceled', 'cancelled', 'aborted'].includes(ippState.toLowerCase());
  }
  return ippState === IPPJobState.COMPLETED || ippState === IPPJobState.CANCELED || ippState === IPPJobState.ABORTED;
}

// Only an idle printer that accepts jobs is online; a state this code does not
// know is an error, never "ready".
export function mapPrinterStateToStatus(
  printerState: unknown,
  stateReasons: string[],
  isAcceptingJobs: boolean,
): { status: PrinterStatus; message: string } {
  if (printerState === IPPPrinterState.STOPPED) {
    if (stateReasons.includes('media-needed')) return { status: 'error', message: 'Out of paper' };
    if (stateReasons.includes('media-jam')) return { status: 'error', message: 'Paper jam' };
    if (stateReasons.includes('door-open')) return { status: 'error', message: 'Printer door/cover is open' };
    if (stateReasons.includes('marker-supply-empty')) return { status: 'error', message: 'Out of ink/ribbon' };
    if (stateReasons.includes('marker-supply-low')) return { status: 'error', message: 'Low on ink/ribbon' };
    if (stateReasons.includes('offline')) return { status: 'offline', message: 'Printer is offline' };
    if (stateReasons.includes('paused')) return { status: 'offline', message: 'Printer is paused' };
    return { status: 'offline', message: 'Printer is stopped' };
  }
  if (printerState === IPPPrinterState.PROCESSING) {
    return { status: 'busy', message: 'Printer is currently printing' };
  }
  if (printerState !== IPPPrinterState.IDLE) {
    return { status: 'error', message: 'Printer status unknown: unrecognised printer state' };
  }
  if (!isAcceptingJobs) {
    const disconnected = stateReasons.some(reason => typeof reason === 'string' && /disconnect|unplugged|usb/i.test(reason));
    if (disconnected) return { status: 'offline', message: 'Printer is not connected (USB disconnected)' };
    return { status: 'offline', message: 'Printer is not accepting jobs' };
  }
  return { status: 'online', message: 'Printer is ready' };
}

type Reply = Record<string, unknown> | null | undefined;
const group = (reply: unknown, name: string): Record<string, unknown> | null => {
  const value = (reply as Record<string, unknown> | null | undefined)?.[name];
  return value && typeof value === 'object' && !Array.isArray(value) ? value as Record<string, unknown> : null;
};

// The reply carries a successful status: a 'successful-ok…' keyword, or a
// status code from 0x0000 to 0x00FF (RFC 8011, 4.1.6).
export function ippSucceeded(reply: unknown): boolean {
  const code = (reply as Reply)?.statusCode;
  if (typeof code === 'string') return code.startsWith('successful-ok');
  return typeof code === 'number' && Number.isInteger(code) && code >= 0 && code <= 0x00ff;
}

// A Print-Job reply that confirms the job: success and a positive integer job id.
export function submittedJob(reply: unknown): { ok: true; jobId: number; jobUri: string } | { ok: false; jobId?: undefined; message: string } {
  const job = group(reply, 'job-attributes-tag');
  const jobId = job?.['job-id'];
  if (!ippSucceeded(reply) || typeof jobId !== 'number' || !Number.isInteger(jobId) || jobId <= 0) {
    return { ok: false, message: 'The printer did not confirm the job' };
  }
  const jobUri = typeof job?.['job-uri'] === 'string' ? job['job-uri'] as string : '';
  return { ok: true, jobId, jobUri };
}

export interface PrinterStatusReading {
  status: PrinterStatus;
  message: string;
  printerState?: number;
  stateName?: string;
  stateReasons?: string[];
  isAcceptingJobs?: boolean;
  queuedJobCount?: number;
}

// A Get-Printer-Attributes reply read into a status. The attribute block, a
// state of 3, 4 or 5 (or idle, processing, stopped) and a boolean
// printer-is-accepting-jobs are required; otherwise the status is unknown.
export function printerStatusFromReply(reply: unknown): PrinterStatusReading {
  const incomplete = { status: 'error' as const, message: 'Printer status unknown: incomplete reply' };
  const attributes = group(reply, 'printer-attributes-tag');
  if (!ippSucceeded(reply) || !attributes) return incomplete;
  const rawState = attributes['printer-state'];
  const printerState = typeof rawState === 'string' ? PRINTER_STATE_NUMBERS[rawState.toLowerCase()] : rawState;
  if (typeof printerState !== 'number' || !(printerState in PRINTER_STATE_NAMES)) return incomplete;
  const accepting = attributes['printer-is-accepting-jobs'];
  if (typeof accepting !== 'boolean') return incomplete;
  const rawReasons = attributes['printer-state-reasons'];
  const stateReasons = (Array.isArray(rawReasons) ? rawReasons : rawReasons === undefined ? ['none'] : [rawReasons])
    .filter((reason): reason is string => typeof reason === 'string');
  const queued = attributes['queued-job-count'];
  return {
    ...mapPrinterStateToStatus(printerState, stateReasons, accepting),
    printerState,
    stateName: PRINTER_STATE_NAMES[printerState],
    stateReasons,
    isAcceptingJobs: accepting,
    queuedJobCount: typeof queued === 'number' && Number.isInteger(queued) && queued >= 0 ? queued : 0,
  };
}

// What a Get-Job-Attributes reply tells the print monitor: CUPS no longer lists
// the job (client-error-not-found, 0x0406), its state, or nothing usable.
export type JobObservation = { kind: 'state'; state: unknown } | { kind: 'missing' } | { kind: 'error' };
export function jobObservation(reply: unknown): JobObservation {
  const code = (reply as Reply)?.statusCode;
  if (code === 'client-error-not-found' || code === 0x0406) return { kind: 'missing' };
  const job = group(reply, 'job-attributes-tag');
  if (!ippSucceeded(reply) || !job || !('job-state' in job)) return { kind: 'error' };
  return { kind: 'state', state: job['job-state'] };
}
