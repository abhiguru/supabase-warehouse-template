import { isIP } from 'node:net';

// Trust boundary: Cloudflare Tunnel is the only ingress and the gateway is published on loopback only, so every external request carries a
// CF-Connecting-IP written by Cloudflare's edge (docker/nginx/templates/gateway.conf.template trusts it from the tunnel hop and sets it again
// from the address it settled on). It is read here instead of X-Forwarded-For. A direct loopback caller could set it, but such a caller is
// already inside the host trust boundary. Anything that is not exactly one IPv4 or IPv6 address is dropped (null); the limits that key on the
// address then do not apply to that request, and the session records none.
export function clientAddress(req: Request): string | null {
  const clientIp = req.headers.get('CF-Connecting-IP');
  return clientIp && clientIp.length <= 45 && !clientIp.includes('%') && isIP(clientIp) !== 0 ? clientIp : null;
}

// The caller's user agent as shown beside a signed-in device, cut to the 300 characters the session table keeps; null when absent or empty.
export function clientUserAgent(req: Request): string | null {
  const agent = req.headers.get('user-agent');
  return agent ? agent.slice(0, 300) : null;
}
