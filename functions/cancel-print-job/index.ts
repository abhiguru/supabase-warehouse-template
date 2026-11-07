// Edge Function: cancel-print-job
// Stops a print job for real. Who may cancel: administrators, supervisors and staff, any job (owner decision, migration 123).
// Body: { "print_job_id": "<uuid>" }. The CUPS job is cancelled first (IPP Cancel-Job); only when CUPS cancelled it is the row
// marked 'cancelled'. Jobs the print service cannot stop answer 409 CANNOT_CANCEL (see functions/_shared/print-cancel.ts).
// The cancel_print_job database function only marks a row; the app calls this function instead.

import { securityHeaders } from '../_shared/security-headers.ts'
import { validatePrintAccess, createAuthErrorResponse } from '../_shared/auth-helpers.ts'
import { restClient } from '../_shared/supabase-rest.ts'
import { CANCELLABLE_STATUSES, cancelCupsJob, cancelDecision, type PrintJobRow } from '../_shared/print-cancel.ts'
import { printTransportName } from '../_shared/print-config.ts'

const json = { ...securityHeaders, 'Content-Type': 'application/json', 'Cache-Control': 'no-store' };
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

const reply = (status: number, body: Record<string, unknown>) =>
  new Response(JSON.stringify({ ...body, timestamp: new Date().toISOString() }), { headers: json, status });

Deno.serve(async (req) => {
  try {
    await validatePrintAccess(req);

    const body = await req.json().catch(() => ({}));
    const id = body?.print_job_id;
    if (typeof id !== 'string' || !UUID.test(id)) {
      return reply(400, { success: false, code: 'INVALID_REQUEST', error: 'Missing or invalid "print_job_id"' });
    }

    const url = Deno.env.get('SUPABASE_URL') ?? '';
    const key = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '';
    if (!url || !key) return reply(500, { success: false, error: 'Server configuration missing' });
    const db = restClient(url, key);

    const { data: row, error: readError } = await db.from('print_jobs').select('id,status,cups_job_id,job_type').eq('id', id).maybeSingle();
    if (readError) {
      console.error('cancel-print-job: read failed:', readError.code);
      return reply(503, { success: false, error: 'The print job could not be read' });
    }
    if (!row) return reply(404, { success: false, code: 'NOT_FOUND', error: 'Print job not found' });

    const decision = cancelDecision(row as PrintJobRow, printTransportName(name => Deno.env.get(name)));
    if (decision.kind === 'refuse') {
      return reply(decision.status, { success: false, code: decision.code, error: decision.error, print_job_id: id });
    }

    const outcome = await cancelCupsJob(decision.cupsJobId, (row as PrintJobRow).job_type, name => Deno.env.get(name));
    if (outcome === 'unreachable') {
      console.error('cancel-print-job: CUPS did not answer the cancel');
      return reply(502, { success: false, code: 'CANCEL_FAILED', error: 'The print service did not confirm the cancel. The job may still print.', print_job_id: id });
    }
    if (outcome === 'refused') {
      // CUPS no longer lists the job, or it cannot be stopped any more: it is finishing or finished. The status monitor settles the row.
      return reply(409, {
        success: false, code: 'CANNOT_CANCEL', print_job_id: id,
        error: 'The printer would not cancel this job: it may already be printing. Check the printer.',
      });
    }

    // Only a job still open is marked, so a final state the monitor recorded in the meantime is not overwritten.
    const now = new Date().toISOString();
    const { error: updateError } = await db.from('print_jobs')
      .update({ status: 'cancelled', completed_at: now, updated_at: now })
      .eq('id', id)
      .in('status', [...CANCELLABLE_STATUSES]);
    if (updateError) {
      console.error('cancel-print-job: the job was cancelled in CUPS but the row was not updated:', updateError.code);
      return reply(500, { success: false, code: 'RECORD_FAILED', error: 'The job was cancelled, but it could not be recorded.', print_job_id: id });
    }
    return reply(200, { success: true, message: 'Print job cancelled', print_job_id: id, cups_job_id: decision.cupsJobId });
  } catch (error) {
    console.error('cancel-print-job ERROR:', error);
    if (error.status && error.message) {
      return createAuthErrorResponse(error, securityHeaders, req);
    }
    return reply(500, { success: false, error: 'Cancel failed' });
  }
});
