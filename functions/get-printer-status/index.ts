import { serve } from "https://deno.land/std@0.192.0/http/server.ts"
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.39.3'
import { validatePrintAccess, createAuthErrorResponse } from '../_shared/auth-helpers.ts'
import { IPPPrinterState, mapPrinterStateToStatus } from '../_shared/ipp-types.ts'
import type { IPPPrinterAttributes } from '../_shared/ipp-types.ts'

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
}

const PRINTER_STATE_MESSAGES: Record<number, string> = {
  3: 'idle',
  4: 'processing',
  5: 'stopped'
}

serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders })
  }

  try {
    const authHeader = req.headers.get('Authorization');
    const supabaseUrl = Deno.env.get('SUPABASE_URL') ?? '';
    const supabaseAnonKey = Deno.env.get('SUPABASE_ANON_KEY') ?? '';
    const supabase = createClient(supabaseUrl, supabaseAnonKey, {
      global: { headers: { Authorization: authHeader } }
    });

    const userProfile = await validatePrintAccess(req, supabase);

    const { printer_name = 'default' } = await req.json().catch(() => ({}));

    console.log(`get-printer-status: User ${userProfile.name} checking printer: ${printer_name}`);

    const ipp = await import("npm:ipp");
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

    const printerAttrs: IPPPrinterAttributes = result?.["printer-attributes-tag"] || {};
    const printerState = printerAttrs["printer-state"] as number;
    const stateReasons = printerAttrs["printer-state-reasons"] || ["none"];
    const isAcceptingJobs = printerAttrs["printer-is-accepting-jobs"] ?? true;

    const { status, message } = mapPrinterStateToStatus(printerState, stateReasons, isAcceptingJobs);

    return new Response(
      JSON.stringify({
        success: true,
        status,
        message,
        printer_name,
        printer_state: printerState,
        printer_state_message: PRINTER_STATE_MESSAGES[printerState] || 'unknown',
        printer_state_reasons: stateReasons,
        printer_is_accepting_jobs: isAcceptingJobs,
        queued_job_count: printerAttrs["queued-job-count"] || 0,
        timestamp: new Date().toISOString()
      }, null, 2),
      { headers: { ...corsHeaders, 'Content-Type': 'application/json' }, status: 200 }
    );

  } catch (error) {
    console.error('get-printer-status ERROR:', error);

    if (error.status && error.message) {
      return createAuthErrorResponse(error, corsHeaders);
    }

    let errorMessage = error.message;
    let errorStatus = 500;

    if (error.message?.includes('ECONNREFUSED')) {
      errorMessage = 'Cannot connect to printer. Check if CUPS service is running.';
      errorStatus = 503;
    } else if (error.message?.includes('not found')) {
      errorMessage = 'Printer not found. Check printer name.';
      errorStatus = 404;
    }

    return new Response(
      JSON.stringify({ success: false, status: 'error', error: errorMessage, timestamp: new Date().toISOString() }, null, 2),
      { headers: { ...corsHeaders, 'Content-Type': 'application/json' }, status: errorStatus }
    )
  }
})
