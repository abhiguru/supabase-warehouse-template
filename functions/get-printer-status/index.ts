import { validatePrintAccess, createAuthErrorResponse } from '../_shared/auth-helpers.ts'
import { printerStatusFromReply } from '../_shared/ipp-validate.ts'
import { validPrinterName, printerStatusFailure } from '../_shared/printer-name.ts'

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders })
  }

  try {
    const userProfile = await validatePrintAccess(req);

    const { printer_name = 'default' } = await req.json().catch(() => ({}));
    if (!validPrinterName(printer_name)) {
      throw { status: 400, message: 'Invalid printer name' };
    }

    console.log(`get-printer-status: User ${userProfile.name} checking printer: ${printer_name}`);

    const ipp = await import("npm:ipp@2.0.1");
    const printer = ipp.Printer(`http://cups:631/printers/${printer_name}`);

    const msg = {
      "operation-attributes-tag": {
        "requesting-user-name": userProfile.name || "status-check",
        "requested-attributes": [
          "printer-state",
          "printer-state-reasons",
          "printer-state-message",
          "printer-is-accepting-jobs",
          "queued-job-count",
          "printer-uri-supported",
          "printer-up-time"
        ]
      }
    };

    const result: any = await new Promise((resolve, reject) => {
      printer.execute("Get-Printer-Attributes", msg, (err: any, res: any) => {
        if (err) reject(err);
        else resolve(res);
      });
    });

    // A reply without the attribute block, a known state or the accepting flag
    // is not read as "ready": the status is unknown.
    const reading = printerStatusFromReply(result);
    if (reading.printerState === undefined) {
      return new Response(
        JSON.stringify({ success: false, status: 'error', error: reading.message, printer_name, timestamp: new Date().toISOString() }, null, 2),
        { headers: { ...corsHeaders, 'Content-Type': 'application/json' }, status: 502 }
      );
    }

    return new Response(
      JSON.stringify({
        success: true,
        status: reading.status,
        message: reading.message,
        printer_name,
        printer_state: reading.printerState,
        printer_state_message: reading.stateName,
        printer_state_reasons: reading.stateReasons,
        printer_is_accepting_jobs: reading.isAcceptingJobs,
        queued_job_count: reading.queuedJobCount,
        timestamp: new Date().toISOString()
      }, null, 2),
      { headers: { ...corsHeaders, 'Content-Type': 'application/json' }, status: 200 }
    );

  } catch (error) {
    console.error('get-printer-status ERROR:', error);

    if (error.status && error.message) {
      return createAuthErrorResponse(error, corsHeaders);
    }

    const { status: errorStatus, message: errorMessage } = printerStatusFailure(error);

    return new Response(
      JSON.stringify({ success: false, status: 'error', error: errorMessage, timestamp: new Date().toISOString() }, null, 2),
      { headers: { ...corsHeaders, 'Content-Type': 'application/json' }, status: errorStatus }
    )
  }
})
