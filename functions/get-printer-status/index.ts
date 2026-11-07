import { validatePrintAccess, createAuthErrorResponse } from '../_shared/auth-helpers.ts'
import { printerStatusFromReply } from '../_shared/ipp-validate.ts'
import { printerStatusFailure } from '../_shared/printer-name.ts'
import { ippPrinter } from '../_shared/ipp-client.ts'
import { bridgeBaseUrl, cupsQueueUrl, printTransportName, printerName } from '../_shared/print-config.ts'

const json = { 'Content-Type': 'application/json' };

// A configuration error is answered here, not thrown: createAuthErrorResponse replaces the text of every 5xx, and the app should show
// this one (an administrator can act on it). Same shape as the bridge's "not configured" answer: status 'error', the text in `error`.
const configError = (message: string, printer_name?: string): Response =>
  new Response(JSON.stringify({ success: false, status: 'error', code: 'PRINT_CONFIG', error: message, ...(printer_name ? { printer_name } : {}), timestamp: new Date().toISOString() }, null, 2), { headers: json, status: 503 });

// Bridge mode: the bridge is a Windows service that reports no queue state of the CUPS kind. What can be asked is
// GET ${PRINTBRIDGE_URL}/health with X-Print-Token and X-Printer (scripts/windows/print-bridge.ps1). It answers
// 200 {success: true, printer, printer_found: true, status: <Windows spooler PrinterStatus>} or, when the queue is missing,
// 503 {success: false, printer, printer_found: false, error}. 401/403 = token refused. Only reachability, the queue being
// found and the spooler status text are reported; there is no queue length or paper state.
const BRIDGE_PROBLEM_STATUS = /offline|paused|error|jam|paper|toner|door|intervention|not available|no ?toner|pending deletion/i;

async function bridgeStatus(printer_name: string): Promise<Response> {
  const timestamp = new Date().toISOString();
  const base = bridgeBaseUrl(name => Deno.env.get(name));
  const token = (Deno.env.get('PRINTBRIDGE_TOKEN') ?? '').trim();
  if (base === null || token === '') {
    return new Response(JSON.stringify({ success: false, status: 'error', transport: 'bridge', error: 'The print bridge is not configured', printer_name, timestamp }, null, 2), { headers: json, status: 503 });
  }
  let body: { success?: unknown; printer_found?: unknown; status?: unknown } | null = null;
  let httpStatus = 0;
  try {
    const response = await fetch(`${base}/health`, {
      headers: { 'X-Print-Token': token, 'X-Printer': printer_name },
      signal: AbortSignal.timeout(5000),
      redirect: 'error',
    });
    httpStatus = response.status;
    body = await response.json().catch(() => null);
  } catch {
    httpStatus = 0;
  }
  if (httpStatus === 401 || httpStatus === 403) {
    return new Response(JSON.stringify({ success: false, status: 'error', transport: 'bridge', error: 'The print bridge refused the token', printer_name, timestamp }, null, 2), { headers: json, status: 502 });
  }
  // A missing Windows queue: the bridge is reachable and says so with printer_found false (503).
  if (body !== null && body.printer_found === false) {
    return new Response(JSON.stringify({ success: true, status: 'error', transport: 'bridge', message: 'Print bridge reachable, but the Windows printer is not installed', printer_name, timestamp }, null, 2), { headers: json, status: 200 });
  }
  if (httpStatus !== 200 || body?.success !== true || body.printer_found !== true) {
    return new Response(JSON.stringify({ success: false, status: 'offline', transport: 'bridge', error: 'The print bridge did not answer', printer_name, timestamp }, null, 2), { headers: json, status: 503 });
  }
  const spooler = typeof body.status === 'string' ? body.status.slice(0, 60) : '';
  const problem = spooler !== '' && BRIDGE_PROBLEM_STATUS.test(spooler);
  return new Response(JSON.stringify({
    success: true,
    status: problem ? 'error' : 'online',
    transport: 'bridge',
    message: problem ? `Print bridge reachable, the printer reports: ${spooler}` : 'Print bridge reachable',
    printer_name,
    printer_status: spooler || undefined,
    timestamp,
  }, null, 2), { headers: json, status: 200 });
}

Deno.serve(async (req) => {
  try {
    const userProfile = await validatePrintAccess(req);

    // The printer is the facility's one configured printer; a printer_name in the request is ignored.
    const transport = printTransportName(name => Deno.env.get(name));
    if (transport === null) return configError('PRINT_TRANSPORT must be cups or bridge');
    // A set but invalid PRINTER_NAME is reported, never replaced by the default queue (which would report another printer's state).
    const printer_name = printerName(name => Deno.env.get(name), transport);
    if (printer_name === null) {
      return configError(transport === 'bridge' ? 'PRINTER_NAME is not a valid printer name' : 'PRINTER_NAME is not a valid CUPS queue name');
    }

    console.log(`get-printer-status: User ${userProfile.name} checking printer (${transport})`);

    if (transport === 'bridge') return await bridgeStatus(printer_name);

    const queueUrl = cupsQueueUrl(name => Deno.env.get(name));
    if (queueUrl === null) return configError('PRINTER_NAME is not a valid CUPS queue name', printer_name);
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
