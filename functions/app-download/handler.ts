// The facility's own download page for the neutral Android app (WH-146; docs/OPERATOR_INSTALL.md, "Local-only facility"). The gateway serves it
// only on the warehouse network listener (docker/nginx/api-locations.conf: GET /app and GET /app/warehouse.apk, 404 on the public address). The
// APK and its checksum come from the offline bundle: setup.sh --from-bundle copies them to <state>/public/app/. GET only, no sign-in: the
// page and the file are not secret, and the phone has nothing to sign with before it has the app. Only a local-only facility answers.
import { securityHeaders } from '../_shared/security-headers.ts';

const APK = 'neutral.apk';
const SUMS = 'neutral.apk.sha256';
const page = (sha: string | null) => `<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>Warehouse app</title></head>
<body style="font-family:sans-serif;max-width:32rem;margin:2rem auto;padding:0 1rem">
<h1>Install the warehouse app<br><small>વેરહાઉસ એપ ઇન્સ્ટોલ કરો</small></h1>
${sha ? `<p><a href="/app/warehouse.apk" style="display:inline-block;padding:.8rem 1.2rem;background:#1a56db;color:#fff;border-radius:.4rem;text-decoration:none">Download the app (Android)<br>એપ ડાઉનલોડ કરો (Android)</a></p>
<p>SHA-256: <code style="word-break:break-all">${sha}</code></p>` : `<p>The app file is not on this server yet. Ask the person who installed it.<br>એપ ફાઇલ હજુ આ સર્વર પર નથી. સર્વર ઇન્સ્ટોલ કરનારને પૂછો.</p>`}
<p>Android only. After installing, open the app and tap "Scan facility code".<br>ફક્ત Android. ઇન્સ્ટોલ કર્યા પછી એપ ખોલો અને "ફેસિલિટીનો કોડ સ્કેન કરો" દબાવો.</p></body></html>`;

export async function handle(req: Request, env: (name: string) => string | undefined = name => Deno.env.get(name)): Promise<Response> {
  if (env('INGRESS') !== 'local-only') return new Response('Not found', { status: 404, headers: securityHeaders });
  if (req.method !== 'GET') return new Response('Method not allowed', { status: 405, headers: securityHeaders });
  const directory = env('PUBLIC_DIR');
  if (!directory) return new Response('Not found', { status: 404, headers: securityHeaders });
  const apkRoute = new URL(req.url).pathname.endsWith('/apk');
  let sha: string | null = null;
  try {
    const first = (await Deno.readTextFile(`${directory}/app/${SUMS}`)).trim().split(/\s+/)[0] ?? '';
    if (/^[0-9a-f]{64}$/.test(first)) sha = first;
  } catch { /* no app file */ }
  if (!apkRoute) {
    return new Response(page(sha), { headers: { ...securityHeaders, 'Content-Type': 'text/html; charset=utf-8', 'Cache-Control': 'no-store' } });
  }
  if (!sha) return new Response('Not found', { status: 404, headers: securityHeaders });
  try {
    const path = `${directory}/app/${APK}`;
    const info = await Deno.stat(path);
    if (!info.isFile) throw new Error('not a file');
    const file = await Deno.open(path, { read: true });
    return new Response(file.readable, { headers: { ...securityHeaders, 'Content-Type': 'application/vnd.android.package-archive',
      'Content-Length': String(info.size), 'Content-Disposition': 'attachment; filename="warehouse.apk"', 'Cache-Control': 'no-store', 'X-Apk-Sha256': sha } });
  } catch { return new Response('Not found', { status: 404, headers: securityHeaders }); }
}

