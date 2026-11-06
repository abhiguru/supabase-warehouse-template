import { validatePrintAccess, createAuthErrorResponse } from '../_shared/auth-helpers.ts'
import { printerStatusFromReply } from '../_shared/ipp-validate.ts'
import { printerStatusFailure } from '../_shared/printer-name.ts'
import { ippPrinter } from '../_shared/ipp-client.ts'
import { configuredPrinterName } from '../_shared/print-transport.ts'
import { bridgeBaseUrl, cupsQueueUrl, printTransportName } from '../_shared/print-config.ts'

const json = { 'Content-Type': 'application/json' };

// Bridge mode: the bridge is a Windows service that reports no queue state of the CUPS kind. What can be asked is
// GET ${PRINTBRIDGE_URL}/health with X-Print-Token. The bridge answers JSON {success: true, printer_found?: boolean}
// (printer_found false = the Windows printer named in PRINTER_NAME is not installed). Only reachability and that
// flag are reported; there is no queue length or paper state.
async function bridgeStatus(printer_name: string): Promise<Response> {
  const timestamp = new Date().toISOString();
  const base = bridgeBaseUrl(name => Deno.env.get(name));
  const token = (Deno.env.get('PRINTBRIDGE_TOKEN') ?? '').trim();
  if (base === null || token === '') {
    return new Response(JSON.stringify({ success: false, status: 'error', transport: 'bridge', error: 'The print bridge is not configured', printer_name, timestamp }, null, 2), { headers: json, status: 503 });
  }
  let body: { success?: unknown; printer_found?: unknown } | null = null;
  let reachable = false;
  try {
    const response = await fetch(`${base}/health`, {
      headers: { 'X-Print-Token': token, 'X-Printer': printer_name },
      signal: AbortSignal.timeout(5000),
      redirect: 'error',
    });
    reachable = response.ok;
    body = await response.json().catch(() => null);
  } catch {
    reachable = false;
  }
  if (!reachable || body?.success !== true) {
    return new Response(JSON.stringify({ success: false, status: 'offline', transport: 'bridge', error: 'The print bridge did not answer', printer_name, timestamp }, null, 2), { headers: json, status: 503 });
  }
  const found = body.printer_found !== false;
  return new Response(JSON.stringify({
    success: true,
    status: found ? 'online' : 'error',
    transport: 'bridge',
    message: found ? 'Print bridge reachable' : 'Print bridge reachable, but the Windows printer is not installed',
    printer_name,
    timestamp,
  }, null, 2), { headers: json, status: 200 });
}

Deno.serve(async (req) => {
  try {
    const userProfile = await validatePrintAccess(req);

    // The printer is the facility's one configured printer; a printer_name in the request is ignored.
    const printer_name = configuredPrinterName();
    const transport = printTransportName(name => Deno.env.get(name));
    if (transport === null) {
      throw { status: 503, message: 'PRINT_TRANSPORT must be cups or bridge' };
    }

    console.log(`get-printer-status: User ${userProfile.name} checking printer (${transport})`);

    if (transport === 'bridge') return await bridgeStatus(printer_name);

    const queueUrl = cupsQueueUrl(name => Deno.env.get(name));
    if (queueUrl === null) throw { status: 503, message: 'PRINTER_NAME is not a valid CUPS queue name' };
    const printer = ippPrinter(queueUrl);

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
        { headers: { 'Content-Type': 'application/json' }, status: 502 }
      );
    }

    return new Response(
      JSON.stringify({
        success: true,
        status: reading.status,
        message: reading.message,
        printer_name,
        transport,
        printer_state: reading.printerState,
        printer_state_message: reading.stateName,
        printer_state_reasons: reading.stateReasons,
        printer_is_accepting_jobs: reading.isAcceptingJobs,
        queued_job_count: reading.queuedJobCount,
        timestamp: new Date().toISOString()
      }, null, 2),
      { headers: { 'Content-Type': 'application/json' }, status: 200 }
    );

  } catch (error) {
    console.error('get-printer-status ERROR:', error);

    if (error.status && error.message) {
      return createAuthErrorResponse(error, {}, req);
    }

    const { status: errorStatus, message: errorMessage } = printerStatusFailure(error);

    return new Response(
      JSON.stringify({ success: false, status: 'error', error: errorMessage, timestamp: new Date().toISOString() }, null, 2),
      { headers: { 'Content-Type': 'application/json' }, status: errorStatus }
    )
  }
})
