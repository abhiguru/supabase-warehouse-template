// Cancelling a print job for real, and settling jobs nothing will follow any more.
//
// A job can be cancelled only while the print service can still stop it: queued or printing, on the CUPS path, with the CUPS job id
// the submission returned. IPP Cancel-Job goes to CUPS first; the row becomes 'cancelled' only when CUPS says it cancelled the job.
// Everything else (a bridge job, which is synchronous and has no id; an 'unknown' job; a row without an id) answers CANNOT_CANCEL:
// the paper may already be printing, and marking the row cancelled would only say something false.

import { ippPrinter } from './ipp-client.ts';
import { ippSucceeded } from './ipp-validate.ts';
import { submitWithTimeout } from './print-monitor-rule.ts';
import { cupsQueueUrl, type EnvGet } from './print-config.ts';

export const CANCEL_TIMEOUT_MS = 10_000;
/** A row still 'queued' or 'printing' after this long is settled as 'unknown' (the status monitor ends within 35 s). */
export const STUCK_AFTER_MS = 5 * 60 * 1000;
export const CANCELLABLE_STATUSES = ['queued', 'printing'] as const;

export interface PrintJobRow { id: string; status: string; cups_job_id: number | null }

export type CancelDecision =
  | { kind: 'cancel'; cupsJobId: number }
  | { kind: 'refuse'; status: number; code: 'INVALID_STATUS' | 'CANNOT_CANCEL'; error: string };

/** What may be done with a job, from its row and the installation's transport. Pure. */
export function cancelDecision(row: PrintJobRow, transport: 'cups' | 'bridge' | null): CancelDecision {
  if (['completed', 'cancelled', 'failed'].includes(row.status)) {
    return { kind: 'refuse', status: 409, code: 'INVALID_STATUS', error: `Cannot cancel a job with status: ${row.status}` };
  }
  const hasId = typeof row.cups_job_id === 'number' && Number.isInteger(row.cups_job_id) && row.cups_job_id > 0;
  if (transport === 'cups' && hasId && (row.status === 'queued' || row.status === 'printing')) {
    return { kind: 'cancel', cupsJobId: row.cups_job_id as number };
  }
  return {
    kind: 'refuse', status: 409, code: 'CANNOT_CANCEL',
    error: 'This job cannot be stopped from here: the printer may already be printing it. Check the printer and take the paper out if needed.',
  };
}

export type CancelOutcome = 'cancelled' | 'refused' | 'unreachable';

/** IPP Cancel-Job on the configured queue. 'refused': CUPS answered but did not cancel (finished, not found, not possible). */
export async function cancelCupsJob(
  cupsJobId: number,
  env: EnvGet,
  send: (queueUrl: string, message: Record<string, unknown>) => Promise<unknown> = defaultSend,
  timeoutMs = CANCEL_TIMEOUT_MS,
): Promise<CancelOutcome> {
  const queueUrl = cupsQueueUrl(env);
  if (queueUrl === null) return 'unreachable';
  const message = { 'operation-attributes-tag': { 'requesting-user-name': 'warehouse-cancel', 'job-id': cupsJobId } };
  let reply: unknown;
  try {
    reply = await submitWithTimeout(() => send(queueUrl, message), timeoutMs);
  } catch {
    return 'unreachable';
  }
  if (reply === null) return 'unreachable';
  return ippSucceeded(reply) ? 'cancelled' : 'refused';
}

const defaultSend = (queueUrl: string, message: Record<string, unknown>): Promise<unknown> =>
  new Promise((resolve, reject) => {
    ippPrinter(queueUrl).execute('Cancel-Job', message, (err, res) => (err ? reject(err) : resolve(res)));
  });

