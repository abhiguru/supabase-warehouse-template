// Duplicate-print guard for the three preprinted print functions.
//
// The app sends an optional `request_id` (uuid) per user print action and reuses it for that action's retries. With one:
//   1. a print_jobs row for (user, request_id) that already exists is answered, never printed again (duplicate: true);
//   2. otherwise a `queued` row carrying the request_id is inserted BEFORE the bytes are sent (the unique index on
//      (user_id, request_id) makes a concurrent twin fail the insert: it gets the winner's row, and prints nothing);
//   3. after the send the same row is updated to printing / unknown / failed (finishPrintJob).
// Without a request_id (an older app), or on a database that has no print_jobs.request_id yet (migration 151 not applied: one
// warning is logged per worker), the old order applies: send first, then insert the row. A row of a failed send (status failed:
// nothing reached the printer) is claimed again by a retry with the same request_id, so a real failure can be retried.
//
// Needs only print-transport.ts (and what that imports).

import type { JobOutcome } from './print-transport.ts';
import { printFailureBody, UNCONFIRMED_NOTE } from './print-transport.ts';

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export type RequestIdResult = { ok: true; requestId: string | null } | { ok: false; response: Response };

/** The optional request_id of a body: absent or null = none; anything but a uuid is a 400 (never silently ignored). */
export function readRequestId(value: unknown): RequestIdResult {
  if (value === undefined || value === null) return { ok: true, requestId: null };
  if (typeof value === 'string' && UUID.test(value)) return { ok: true, requestId: value.toLowerCase() };
  return {
    ok: false,
    response: new Response(
      JSON.stringify({ success: false, error: 'request_id must be a uuid', code: 'INVALID_REQUEST_ID', timestamp: new Date().toISOString() }, null, 2),
      { headers: { 'Content-Type': 'application/json' }, status: 400 },
    ),
  };
}

/** The part of the REST client this module uses (supabase-rest.ts). */
interface Rest {
  from(table: string): any;
}

export interface JobMeta {
  job_type: 'GRN' | 'Dispatch' | 'Invoice';
  document_range_start: string;
  document_range_end: string;
  document_count: number;
  user_id: string;
  user_name: string | null;
  content_size: number;
  printer_name: string;
}

export interface ExistingJob {
  id: string;
  status: string;
  cups_job_id: number | null;
  error_message: string | null;
  document_count: number | null;
}

export type StartedJob =
  | { kind: 'duplicate'; row: ExistingJob }
  | { kind: 'row'; id: string }      // a queued row exists; finishPrintJob updates it
  | { kind: 'late' };                // no row yet; finishPrintJob inserts it after the send (old order)

// null = not known yet; false = the column is missing (migration 151 not applied).
let requestIdColumn: boolean | null = null;

/** Test hook: forget what was learnt about the column. */
export function resetRequestIdColumnCache(): void {
  requestIdColumn = null;
}

function isMissingColumn(error: { message?: string; code?: string } | null): boolean {
  if (!error) return false;
  // 42703 undefined_column (a filter or select), PGRST204 (an insert/update body names a column the schema cache lacks).
  return (error.code === '42703' || error.code === 'PGRST204') && /request_id/.test(error.message ?? '');
}

function noteMissingColumn(): void {
  if (requestIdColumn !== false) {
    console.warn('print-request: print_jobs.request_id does not exist (migration 151 is not applied); the duplicate-print guard is off and rows are written after the send');
  }
  requestIdColumn = false;
}

const COLUMNS = 'id,status,cups_job_id,error_message,document_count';

async function findExisting(supabase: Rest, userId: string, requestId: string): Promise<{ row: ExistingJob | null; missing: boolean }> {
  const { data, error } = await supabase
    .from('print_jobs')
    .select(COLUMNS)
    .eq('user_id', userId)
    .eq('request_id', requestId)
    .maybeSingle();
  if (isMissingColumn(error)) { noteMissingColumn(); return { row: null, missing: true }; }
  if (error) throw new Error(`print_jobs lookup failed: ${error.message}`);
  return { row: (data as ExistingJob | null) ?? null, missing: false };
}

/**
 * Call after the document is built and before anything is sent. A `duplicate` result means: answer it with
 * duplicateResponse and send nothing.
 * A failure of the lookup itself throws (the caller answers 500, nothing was printed): guessing "no duplicate" there could
 * print twice.
 */
export async function startPrintJob(supabase: Rest, meta: JobMeta, requestId: string | null): Promise<StartedJob> {
  if (requestId === null || requestIdColumn === false) return { kind: 'late' };

  const existing = await findExisting(supabase, meta.user_id, requestId);
  if (existing.missing) return { kind: 'late' };
  if (existing.row) return await claimIfFailed(supabase, existing.row, meta);

  const inserted = await supabase
    .from('print_jobs')
    .insert({ ...meta, request_id: requestId, status: 'queued' })
    .select(COLUMNS)
    .single();
  if (isMissingColumn(inserted.error)) { noteMissingColumn(); return { kind: 'late' }; }
  if (inserted.error) {
    if (inserted.error.code === '23505') {
      // A concurrent twin won the unique index: it prints, this one does not.
      const twin = await findExisting(supabase, meta.user_id, requestId);
      if (twin.row) return { kind: 'duplicate', row: twin.row };
    }
    // The log could not be written. Printing without a log row is what the functions always did when the log failed.
    console.error('print-request: could not insert the queued print_jobs row:', inserted.error);
    return { kind: 'late' };
  }
  return { kind: 'row', id: (inserted.data as ExistingJob).id };
}

async function claimIfFailed(supabase: Rest, row: ExistingJob, meta: JobMeta): Promise<StartedJob> {
  if (row.status !== 'failed') return { kind: 'duplicate', row };
  // Nothing reached the printer last time: this retry may print. Only one retry wins the status change.
  // created_at is reset too: sweep-print-jobs ages a row by it, and an old failed row re-queued now would otherwise be settled
  // as 'unknown' while this retry is still printing.
  const now = new Date().toISOString();
  const { data, error } = await supabase
    .from('print_jobs')
    .update({ status: 'queued', error_message: null, cups_job_id: null, completed_at: null, content_size: meta.content_size, printer_name: meta.printer_name, created_at: now, updated_at: now })
    .eq('id', row.id)
    .eq('status', 'failed')
    .select('id');
  if (!error && Array.isArray(data) && data.length === 1) return { kind: 'row', id: row.id };
  if (error) console.error('print-request: could not re-queue the failed print_jobs row:', error);
  return { kind: 'duplicate', row: { ...row, status: 'queued' } };
}

/** Records the outcome of the send. Returns the row id (null when there is no row). */
export async function finishPrintJob(supabase: Rest, started: StartedJob, meta: JobMeta, outcome: JobOutcome): Promise<string | null> {
  if (started.kind === 'row') {
    const patch = outcome.kind === 'failed'
      ? { status: 'failed', error_message: outcome.error.slice(0, 500), updated_at: new Date().toISOString() }
      : { ...outcome.row, updated_at: new Date().toISOString() };
    const { error } = await supabase.from('print_jobs').update(patch).eq('id', started.id);
    if (error) console.error('print-request: could not update the print_jobs row:', error);
    return started.id;
  }
  if (started.kind === 'late' && outcome.kind !== 'failed') {
    // The old order. request_id is not written: it was not accepted, or none was sent.
    const { data, error } = await supabase.from('print_jobs').insert({ ...meta, ...outcome.row }).select().single();
    if (error) console.error('print-request: Failed to log print job:', error);
    return (data as { id?: string } | null)?.id ?? null;
  }
  return null;
}

/** The answer for a request that was already handled (nothing is printed). `range` is echoed like the normal answer. */
export function duplicateResponse(row: ExistingJob, range: { start: string; end: string }): Response {
  const timestamp = new Date().toISOString();
  // Same answer as the first time for a job the printer never confirmed: it may be on paper. A row still 'queued' is another
  // attempt still sending (or one that died before it recorded anything): nothing says it printed, so it is answered the same
  // way (the app shows its "not confirmed, check the printer" text for PRINT_UNCONFIRMED), never as a success.
  if ((row.status === 'unknown' && row.error_message === UNCONFIRMED_NOTE) || row.status === 'queued') {
    return new Response(
      JSON.stringify({ ...printFailureBody({ kind: 'unconfirmed', row: { cups_job_id: null, status: 'unknown', error_message: UNCONFIRMED_NOTE } }, row.id), duplicate: true }, null, 2),
      { headers: { 'Content-Type': 'application/json' }, status: 502 },
    );
  }
  return new Response(
    JSON.stringify({
      success: true,
      duplicate: true,
      message: 'This print request was already handled; nothing was printed again',
      range: { start: range.start, end: range.end, count: row.document_count },
      print_job: { print_job_id: row.id, cups_job_id: row.cups_job_id, status: row.status },
      timestamp,
    }, null, 2),
    { headers: { 'Content-Type': 'application/json' }, status: 200 },
  );
}
