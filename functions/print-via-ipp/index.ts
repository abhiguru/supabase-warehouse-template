// Edge Function: print-via-ipp
// Generic IPP print function — sends raw data to CUPS printer

import { corsHeaders, handleCors } from '../_shared/cors.ts'
import { validatePrintAccess, createAuthErrorResponse } from '../_shared/auth-helpers.ts'
import { createClient } from '../vendor/supabase-js.mjs'
import { submittedJob } from '../_shared/ipp-validate.ts'
import { Buffer } from 'node:buffer'

Deno.serve(async (req) => {
  const corsResponse = handleCors(req);
  if (corsResponse) return corsResponse;

  try {
    const supabaseUrl = Deno.env.get('SUPABASE_URL') ?? '';
    const supabaseAnonKey = Deno.env.get('SUPABASE_ANON_KEY') ?? '';
    const authHeader = req.headers.get('Authorization');
    const supabase = createClient(supabaseUrl, supabaseAnonKey, {
      global: { headers: { Authorization: authHeader } }
    });

    const userProfile = await validatePrintAccess(req, supabase);

    const { content, printer_name = 'default', title = 'Print Job' } = await req.json();

    if (!content) {
      return new Response(
        JSON.stringify({ success: false, error: 'Missing "content" field (raw print data)' }),
        { headers: { ...corsHeaders, 'Content-Type': 'application/json' }, status: 400 }
      );
    }

    if (typeof printer_name !== 'string' || !/^[a-zA-Z0-9_-]{1,127}$/.test(printer_name)) {
      throw { status: 400, message: 'Invalid printer name' };
    }
    const printerUrl = `http://cups:631/printers/${printer_name}`;
    console.log(`print-via-ipp: Printing to ${printerUrl} for user ${userProfile.name}`);

    const ipp = await import("npm:ipp@2.0.1");
    const printer = ipp.Printer(printerUrl);

    const buffer = new TextEncoder().encode(content);

    const msg = {
      "operation-attributes-tag": {
        "requesting-user-name": userProfile.name || "print-user",
        "job-name": title,
        "document-format": "application/octet-stream"
      },
      data: Buffer.from(buffer)
    };

    const result: any = await new Promise((resolve, reject) => {
      printer.execute("Print-Job", msg, (err: any, res: any) => {
        if (err) reject(err);
        else resolve(res);
      });
    });

    // Success only with a reply that confirms the job and names its id.
    const submitted = submittedJob(result);
    if (!submitted.ok) {
      console.error('print-via-ipp: the printer reply did not confirm the job');
      return new Response(
        JSON.stringify({ success: false, error: 'The printer did not confirm the job', unconfirmed: true }),
        { headers: { ...corsHeaders, 'Content-Type': 'application/json' }, status: 502 }
      );
    }

    return new Response(
      JSON.stringify({
        success: true,
        message: 'Print job submitted successfully',
        job_id: submitted.jobId,
        printer: printer_name,
        timestamp: new Date().toISOString()
      }),
      { headers: { ...corsHeaders, 'Content-Type': 'application/json' }, status: 200 }
    );

  } catch (error) {
    console.error('print-via-ipp ERROR:', error);

    if (error.status && error.message) {
      return createAuthErrorResponse(error, corsHeaders);
    }

    return new Response(
      JSON.stringify({ success: false, error: error.message }),
      { headers: { ...corsHeaders, 'Content-Type': 'application/json' }, status: 500 }
    );
  }
});
