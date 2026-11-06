// Edge Function: sweep-print-jobs
// Settles print jobs nothing follows any more. A row still 'queued' or 'printing' more than 5 minutes after it was created is
// recorded as 'unknown' with a note, never as 'completed' (nobody saw it finish). The status monitor ends within 35 s; a row older
// than that lost its monitor (the worker was stopped, or its last update failed).
// Callable only with the service-role key. scripts/watch.mjs (the 5-minute checker, check print_sweep) calls it; it is not a user route.

import { securityHeaders } from '../_shared/security-headers.ts'
import { verifyRequest } from '../_shared/jwt.ts'
import { restClient } from '../_shared/supabase-rest.ts'
import { STUCK_AFTER_MS } from '../_shared/print-cancel.ts'

const json = { ...securityHeaders, 'Content-Type': 'application/json', 'Cache-Control': 'no-store' };
const NOTE = 'The job did not report an end. Check the printer.';

Deno.serve(async (req) => {
  try {
    const payload = await verifyRequest(req);
    if (payload.role !== 'service_role') {
      return new Response(JSON.stringify({ success: false, error: 'Service access required' }), { headers: json, status: 403 });
    }
    const url = Deno.env.get('SUPABASE_URL') ?? '';
    const key = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '';
    if (!url || !key) return new Response(JSON.stringify({ success: false, error: 'Server configuration missing' }), { headers: json, status: 500 });

    const now = Date.now();
    const cutoff = new Date(now - STUCK_AFTER_MS).toISOString();
    // The status filter is repeated in the update's own condition, so a row the monitor or a cancel settled in between is left alone.
    const { data, error } = await restClient(url, key).from('print_jobs')
      .update({ status: 'unknown', error_message: NOTE, updated_at: new Date(now).toISOString() })
      .in('status', ['queued', 'printing'])
      .lt('created_at', cutoff)
      .select('id');
    if (error) {
      console.error('sweep-print-jobs: update failed:', error.code);
      return new Response(JSON.stringify({ success: false, error: 'The sweep failed' }), { headers: json, status: 503 });
    }
    const settled = Array.isArray(data) ? data.length : 0;
    if (settled > 0) console.error(`sweep-print-jobs: ${settled} job(s) recorded as unknown`);
    return new Response(JSON.stringify({ success: true, settled }), { headers: json, status: 200 });
  } catch (error) {
    if (error?.status && error?.message) {
      return new Response(JSON.stringify({ success: false, error: error.message }), { headers: json, status: error.status });
    }
    console.error('sweep-print-jobs ERROR:', error);
    return new Response(JSON.stringify({ success: false, error: 'The sweep failed' }), { headers: json, status: 500 });
  }
});
