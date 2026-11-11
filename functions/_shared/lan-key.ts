// The warehouse network key in the get-config answer (WH-133; docs/API_CONTRACT.md, "Signing on the LAN path"). The key signs every
// request and answer of the plain-http LAN path, so it is handed out only where nobody on the Wi-Fi can read it:
//  - the request came through the PUBLIC gateway: the gateway itself sets X-Warehouse-Path on every request it passes to the functions
//    (docker/nginx/api-locations.conf), `public` there and `lan` behind the LAN signer, whatever the client sent. A missing or other
//    value gives no key (fail closed);
//  - the facility's public address is https (the tunnel). A development install on plain http gets no key here.
// The key is read with the service role (public.lan_signing_key: the key of a live session, or null). A failure to read it leaves the key
// out and is logged without the session or the key: get-config still answers, and the phone simply does not use the LAN path yet.
import type { RestResult } from './supabase-rest.ts';

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const HEX_KEY = /^[0-9a-f]{64}$/;

export type LanKey = { id: string; key: string };
type RpcClient = { rpc(name: string, args: Record<string, unknown>): Promise<RestResult> };

export async function lanKeyFor(req: Request, publicBaseUrl: string, sessionId: unknown, client: RpcClient): Promise<LanKey | null> {
  if (req.headers.get('x-warehouse-path') !== 'public') return null;
  if (!publicBaseUrl.startsWith('https://')) return null;
  if (typeof sessionId !== 'string' || !UUID.test(sessionId)) return null;
  const { data, error } = await client.rpc('lan_signing_key', { p_key_id: sessionId });
  if (error) {
    console.error('get-config: the warehouse network key could not be read');
    return null;
  }
  return typeof data === 'string' && HEX_KEY.test(data) ? { id: sessionId, key: data } : null;
}
