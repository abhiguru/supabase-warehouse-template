// The variables each function's worker receives. A worker gets the names
// listed for it and nothing else from the container environment, so a public
// function never holds the token-signing secret and no worker holds a value
// it does not read. tests/worker-env.test.mjs compares every list with the
// Deno.env.get() calls the function and its _shared imports actually make;
// add a name here when a function starts reading one.
const signedIn = ['JWT_SECRET', 'SUPABASE_URL', 'SUPABASE_SERVICE_ROLE_KEY'];
const documentPdf = [...signedIn, 'SUPABASE_ANON_KEY', 'SUPABASE_PUBLIC_URL', 'GOTENBERG_URL'];

export const workerEnvNames: Record<string, readonly string[]> = {
  'hello': [],
  // INSTANCE_MANIFEST_JSON is not in the container environment: the router
  // reads the manifest file and passes its text.
  'get-public-config': ['APP_ENV', 'SUPABASE_URL', 'SUPABASE_ANON_KEY', 'SUPABASE_SERVICE_ROLE_KEY', 'SUPABASE_PUBLIC_URL', 'INSTANCE_MANIFEST_JSON'],
  'operator-otp': ['APP_ENV', 'AUTH_MODE', 'SUPABASE_URL', 'SUPABASE_SERVICE_ROLE_KEY'],
  'get-config': [...signedIn, 'APP_ENV', 'SUPABASE_ANON_KEY', 'SUPABASE_PUBLIC_URL'],
  'generate-sample-pdf': [...signedIn, 'GOTENBERG_URL'],
  'generate-grn-pdf': documentPdf,
  'generate-dispatch-pdf': documentPdf,
  'generate-invoice-pdf': documentPdf,
  'generate-customer-stock-pdf': documentPdf,
  // Refused with 503 by the router today; listed so that enabling printing
  // does not fall back to the whole environment.
  'get-printer-status': [...signedIn, 'SUPABASE_ANON_KEY'],
  'print-via-ipp': [...signedIn, 'SUPABASE_ANON_KEY'],
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
