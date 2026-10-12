import { verifySignedInRequest } from '../_shared/jwt.ts';
import { createAuthErrorResponse } from '../_shared/auth-helpers.ts';
import { corsHeaders, handleCors } from '../_shared/cors.ts';
import { workerEnv } from './worker-env.ts';

const publicFunctions = new Set(['hello', 'get-public-config', 'operator-otp', 'central-exchange']);
const allowed = new Set([...publicFunctions, 'get-config', 'generate-sample-pdf', 'get-printer-status', 'print-via-ipp',
  'generate-grn-pdf', 'generate-dispatch-pdf', 'generate-invoice-pdf', 'generate-customer-stock-pdf']);

Deno.serve(async (req: Request) => {
  const cors = handleCors(req);
  if (cors) return cors;
  const name = new URL(req.url).pathname.split('/')[1];
  if (['print-grn-preprinted', 'print-dispatch-preprinted', 'print-invoice-preprinted', 'print-via-ipp', 'get-printer-status'].includes(name)) {
    return new Response(JSON.stringify({ success: false, error: 'Printing is not configured for this operator instance' }), { status: 503, headers: { ...corsHeaders, 'Content-Type': 'application/json' } });
  }
  if (!allowed.has(name)) return new Response('Function not found', { status: 404, headers: corsHeaders });
  try {
    // Each function still checks its caller itself; this keeps the anon key out
    // of any function added later without that check.
    if (!publicFunctions.has(name)) await verifySignedInRequest(req);
    // A worker receives only the variables listed for it in worker-env.ts.
    const extra: Record<string, string> = {};
    if (name === 'get-public-config') {
      const path = Deno.env.get('INSTANCE_MANIFEST_PATH');
      if (!path) throw new Error('Instance manifest path missing');
      extra.INSTANCE_MANIFEST_JSON = await Deno.readTextFile(path);
    }
    // Central sign-in with keys from a file of the installation instead of a
    // fetch: the worker gets the file's text. A file that cannot be read is
    // left out, and the function then answers "keys unavailable".
    if (name === 'central-exchange') {
      const file = Deno.env.get('CENTRAL_JWKS_FILE');
      const directory = Deno.env.get('CENTRAL_JWKS_DIR');
      if (file && directory && /^[A-Za-z0-9][A-Za-z0-9._-]{0,99}$/.test(file)) {
        try {
          extra.CENTRAL_JWKS_JSON = await Deno.readTextFile(`${directory}/${file}`);
        } catch {
          console.error('central-exchange: the key file could not be read');
        }
      }
    }
    const worker = await EdgeRuntime.userWorkers.create({
      servicePath: `/home/deno/functions/${name}`,
      memoryLimitMb: 150,
      workerTimeoutMs: 60000,
      noModuleCache: false,
      envVars: workerEnv(name, Deno.env.toObject(), extra),
    });
    return await worker.fetch(req);
  } catch (error) {
    return createAuthErrorResponse(error, corsHeaders);
  }
});
