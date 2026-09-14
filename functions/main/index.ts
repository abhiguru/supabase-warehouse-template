import { serve } from 'https://deno.land/std@0.192.0/http/server.ts';
import { verifyRequest } from '../_shared/jwt.ts';
import { createAuthErrorResponse } from '../_shared/auth-helpers.ts';
import { corsHeaders, handleCors } from '../_shared/cors.ts';

const publicFunctions = new Set(['hello', 'get-public-config']);
const allowed = new Set([...publicFunctions, 'get-config', 'generate-sample-pdf', 'get-printer-status', 'print-via-ipp',
  'generate-grn-pdf', 'generate-dispatch-pdf', 'generate-invoice-pdf', 'generate-customer-stock-pdf']);

serve(async (req: Request) => {
  const cors = handleCors(req);
  if (cors) return cors;
  const name = new URL(req.url).pathname.split('/')[1];
  if (['print-grn-preprinted', 'print-dispatch-preprinted', 'print-invoice-preprinted', 'print-via-ipp', 'get-printer-status'].includes(name)) {
    return new Response(JSON.stringify({ success: false, error: 'Printing is unavailable in the local demo' }), { status: 503, headers: { ...corsHeaders, 'Content-Type': 'application/json' } });
  }
  if (!allowed.has(name)) return new Response('Function not found', { status: 404, headers: corsHeaders });
  try {
    if (!publicFunctions.has(name)) await verifyRequest(req);
    const worker = await EdgeRuntime.userWorkers.create({
      servicePath: `/home/deno/functions/${name}`,
      memoryLimitMb: 150,
      workerTimeoutMs: 60000,
      noModuleCache: false,
      importMapPath: '/home/deno/functions/import_map.json',
      envVars: Object.entries(Deno.env.toObject()),
    });
    return await worker.fetch(req);
  } catch (error) {
    return createAuthErrorResponse(error, corsHeaders);
  }
});
