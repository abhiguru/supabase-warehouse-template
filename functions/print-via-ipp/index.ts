// Edge Function: print-via-ipp
// Generic IPP print function — sends raw data to CUPS printer

import { serve } from "https://deno.land/std@0.192.0/http/server.ts"
import { corsHeaders, handleCors } from '../_shared/cors.ts'
import { validatePrintAccess, createAuthErrorResponse } from '../_shared/auth-helpers.ts'
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.39.3'

serve(async (req) => {
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

    const printerUrl = `http://cups:631/printers/${printer_name}`;
    console.log(`print-via-ipp: Printing to ${printerUrl} for user ${userProfile.name}`);

    const ipp = await import("npm:ipp");
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

    const jobId = result?.["job-attributes-tag"]?.["job-id"];

    return new Response(
      JSON.stringify({
        success: true,
        message: 'Print job submitted successfully',
        job_id: jobId,
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
