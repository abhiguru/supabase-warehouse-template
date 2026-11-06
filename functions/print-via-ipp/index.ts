// Edge Function: print-via-ipp
// Generic raw print function: sends the given bytes to the facility's printer (PRINT_TRANSPORT: CUPS or the Windows print bridge).
// The printer is the facility's one configured printer (PRINTER_NAME); a request cannot choose another queue.

import { securityHeaders } from '../_shared/security-headers.ts'
import { validatePrintAccess, createAuthErrorResponse } from '../_shared/auth-helpers.ts'
import { submitRawJob, jobOutcome, printFailureBody, configuredPrinterName } from '../_shared/print-transport.ts'

const json = { ...securityHeaders, 'Content-Type': 'application/json' };

// The raw bytes: `content_base64` (any bytes), or `content` as text whose characters are all below U+0100 (sent one byte each, latin1).
function requestBytes(body: { content?: unknown; content_base64?: unknown }): Uint8Array | null {
  if (typeof body.content_base64 === 'string' && body.content_base64 !== '') {
    try {
      return Uint8Array.from(atob(body.content_base64), char => char.charCodeAt(0));
    } catch {
      return null;
    }
  }
  if (typeof body.content === 'string' && body.content !== '') {
    const bytes = new Uint8Array(body.content.length);
    for (let i = 0; i < body.content.length; i++) {
      const code = body.content.charCodeAt(i);
      if (code > 0xff) return null;
      bytes[i] = code;
    }
    return bytes;
  }
  return null;
}

Deno.serve(async (req) => {
  try {
    await validatePrintAccess(req);

    const body = await req.json().catch(() => ({}));
    const bytes = requestBytes(body);
    if (!bytes) {
      return new Response(
        JSON.stringify({ success: false, error: 'Missing or invalid "content" (text below U+0100) or "content_base64"' }),
        { headers: json, status: 400 }
      );
    }
    const title = typeof body.title === 'string' ? body.title : 'Print Job';

    const result = await submitRawJob({ bytes, docName: title, jobType: 'Raw' });
    const outcome = jobOutcome(result);
    if (outcome.kind === 'failed' || outcome.kind === 'unconfirmed') {
      console.error('print-via-ipp: not printed, transport', result.transport);
      return new Response(JSON.stringify(printFailureBody(outcome, null)), { headers: json, status: 502 });
    }

    return new Response(
      JSON.stringify({
        success: true,
        message: 'Print job submitted successfully',
        job_id: result.jobId,
        transport: result.transport,
        printer: configuredPrinterName(),
        timestamp: new Date().toISOString()
      }),
      { headers: json, status: 200 }
    );

  } catch (error) {
    console.error('print-via-ipp ERROR:', error);

    if (error.status && error.message) {
      return createAuthErrorResponse(error, securityHeaders, req);
    }

    return new Response(
      JSON.stringify({ success: false, error: error.message }),
      { headers: json, status: 500 }
    );
  }
});
