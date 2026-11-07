// The variables each function's worker receives. A worker gets the names
// listed for it and nothing else from the container environment, so a public
// function never holds the token-signing secret and no worker holds a value
// it does not read. tests/worker-env.test.mjs compares every list with the
// Deno.env.get() calls the function and its _shared imports actually make;
// add a name here when a function starts reading one.
const signedIn = ['JWT_SECRET', 'SUPABASE_URL', 'SUPABASE_SERVICE_ROLE_KEY', 'SUPABASE_REST_URL'];
// Where _shared/supabase-rest.ts sends its calls: PostgREST and Storage directly (docker-compose.yml), not through the gateway.
// _shared/auth-helpers.ts (the profile lookup of every signed-in function) and the sign-in and sensor functions use only the REST address, so it is in `signedIn`.
const storageApi = ['SUPABASE_STORAGE_URL'];
const printing = ['PRINT_TRANSPORT', 'PRINTER_NAME', 'PRINTBRIDGE_URL', 'PRINTBRIDGE_TOKEN'];
const documentPdf = [...signedIn, ...storageApi, 'SUPABASE_ANON_KEY', 'SUPABASE_PUBLIC_URL', 'PDF_RENDERER_URL'];
// The four document PDFs also receive the letterhead image as a finished data URI: the router reads the file
// (LETTERHEAD_FILE, in the public directory) and passes the text, as it does the central key set. It is not in the container environment.
const documentLetterhead = [...documentPdf, 'LETTERHEAD_DATA_URI'];

export const workerEnvNames: Record<string, readonly string[]> = {
  'hello': [],
  // INSTANCE_MANIFEST_JSON, RELEASE_JSON and APP_COMPAT_JSON are not in the container environment: the router
  // reads the files and passes their text.
  'get-public-config': ['APP_ENV', 'AUTH_MODE', 'SUPABASE_URL', 'SUPABASE_ANON_KEY', 'SUPABASE_PUBLIC_URL', 'INSTANCE_MANIFEST_JSON',
    'RELEASE_JSON', 'APP_COMPAT_JSON',
    'CENTRAL_ISSUER', 'CENTRAL_JWKS_URL', 'CENTRAL_JWKS_FILE', 'CENTRAL_LOCAL_CODE', 'SUPABASE_REST_URL', ...storageApi],
  'operator-otp': ['APP_ENV', 'AUTH_MODE', 'INGRESS', 'SUPABASE_URL', 'SUPABASE_SERVICE_ROLE_KEY', 'SUPABASE_REST_URL'],
  // WH-146: a local-only facility signs in with pairing codes; only these two functions know INGRESS. app-download reads the APK from the public directory.
  'pairing-redeem': ['INGRESS', 'SUPABASE_URL', 'SUPABASE_SERVICE_ROLE_KEY', 'SUPABASE_REST_URL'],
  'app-download': ['INGRESS', 'PUBLIC_DIR'],
  // Central sign-in: the trusted issuer, its public keys (an address, or a
  // file whose text the router passes as CENTRAL_JWKS_JSON, which is not in
  // the container environment), and this facility's origin (the audience a
  // token must name).
  'central-exchange': ['APP_ENV', 'AUTH_MODE', 'INGRESS', 'SUPABASE_URL', 'SUPABASE_SERVICE_ROLE_KEY', 'SUPABASE_PUBLIC_URL', 'CENTRAL_ISSUER', 'CENTRAL_JWKS_URL',
    'CENTRAL_JWKS_FILE', 'CENTRAL_JWKS_JSON', 'SUPABASE_REST_URL'],
  // Sensor bridge batches: the RPC is called with the server key; the bridge's
  // ingest key is checked by the database, not here.
  'ingest-sensor-readings': ['SUPABASE_URL', 'SUPABASE_SERVICE_ROLE_KEY', 'SUPABASE_REST_URL'],
  // The LAN fallback address (scripts/lan.sh) is offered in urls.lan to signed-in phones only: get-public-config has no LAN name.
  'get-config': [...signedIn, ...storageApi, 'APP_ENV', 'SUPABASE_ANON_KEY', 'SUPABASE_PUBLIC_URL', 'LAN_ENABLED', 'LAN_BIND_IP', 'LAN_HTTP_PORT', 'RELEASE_JSON'],
  'generate-grn-pdf': documentLetterhead,
  'generate-dispatch-pdf': documentLetterhead,
  'generate-invoice-pdf': documentLetterhead,
  'generate-customer-stock-pdf': documentLetterhead,
  // Report PDFs read like the document PDFs: caller token for the data, the
  // server key for the warehouse name and the upload.
  'generate-report-pdf': documentPdf,
  // The print functions: the signed-in set, and where the bytes go (functions/_shared/print-config.ts). PRINTBRIDGE_TOKEN is the
  // bridge's shared secret; it reaches only these workers. The three preprinted functions also use the REST client (storageApi).
  'get-printer-status': [...signedIn, ...printing],
  'print-via-ipp': [...signedIn, ...printing],
  // Cancel-Job goes to CUPS (PRINTER_NAME, PRINT_TRANSPORT; never the bridge, so no PRINTBRIDGE_*); the row is read and updated with the
  // server key, through the REST client (storageApi: direct, not through the gateway's rate limit and maintenance answer).
  'cancel-print-job': [...signedIn, ...storageApi, 'PRINT_TRANSPORT', 'PRINTER_NAME'],
  // Called by scripts/watch.mjs with the service-role key; it only updates print_jobs (REST client, as above).
  'sweep-print-jobs': [...signedIn, ...storageApi],
  'print-grn-preprinted': [...signedIn, ...storageApi, ...printing],
  'print-dispatch-preprinted': [...signedIn, ...storageApi, ...printing],
  'print-invoice-preprinted': [...signedIn, ...storageApi, ...printing],
};

export function workerEnv(name: string, env: Record<string, string | undefined>, extra: Record<string, string> = {}): [string, string][] {
  const names = workerEnvNames[name];
  if (!names) throw new Error(`No environment list for function ${name}`);
  const source = { ...env, ...extra };
  const pairs: [string, string][] = [];
  for (const key of names) {
    const value = source[key];
    if (typeof value === 'string') pairs.push([key, value]);
  }
  return pairs;
}
