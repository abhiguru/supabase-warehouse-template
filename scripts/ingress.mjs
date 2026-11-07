// How requests reach this installation (WH-146): `setup.sh --ingress cloudflare-tunnel|trusted-proxy|local-only`.
//   cloudflare-tunnel  the default and the only mode before WH-146: the Cloudflare Tunnel connector on this host reaches the loopback
//                      gateway, and the client address is the CF-Connecting-IP the tunnel sets.
//   trusted-proxy      your own reverse proxy on this host reaches the loopback gateway. The client address is taken from one named
//                      header, and only from one named address (--proxy-address, --proxy-header), as the identity service does.
//   local-only         no public address and no internet: the warehouse network listener (gateway-lan) is the facility's only address,
//                      and WH-133 signing is required on every request. No SMS, central sign-in, tunnel or Slack.
// The three values are stored in config/compose.env (INGRESS, TRUSTED_PROXY_ADDRESS, TRUSTED_PROXY_HEADER); a state without INGRESS is a
// cloudflare-tunnel one. The mode is chosen at the first setup; converting an installation later is not supported.
export const INGRESS_MODES = ['cloudflare-tunnel', 'trusted-proxy', 'local-only'];
export const DEFAULT_INGRESS = 'cloudflare-tunnel';

// A header that carries something else on this API must never be read as the client address.
const FORBIDDEN_HEADERS = new Set(['host', 'authorization', 'apikey', 'cookie', 'content-length', 'content-type', 'connection', 'upgrade',
  'transfer-encoding', 'te', 'expect', 'origin', 'referer', 'user-agent', 'x-request-id', 'x-warehouse-path']);
const OCTET = '(?:25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])';

export function ingressValue(value) {
  if (value === undefined) return undefined;
  if (!INGRESS_MODES.includes(value)) throw new Error(`--ingress must be one of ${INGRESS_MODES.join(', ')}.`);
  return value;
}

// One IPv4 address, or a range of at least 256 addresses' worth of mask (/16 to /32): a proxy address must name a proxy, not a network.
export function proxyAddressValue(value) {
  if (!new RegExp(`^${OCTET}\\.${OCTET}\\.${OCTET}\\.${OCTET}(?:/(?:1[6-9]|2[0-9]|3[0-2]))?$`).test(value ?? '')) {
    throw new Error('--proxy-address must be one IPv4 address such as 172.18.0.1 (or a range /16 to /32 of one). For a proxy on this host it is the address the gateway sees the connection from: the Compose network\'s gateway address (docs/OPERATOR_INSTALL.md, "Ingress").');
  }
  if (/^0\./.test(value)) throw new Error('--proxy-address must not start with 0.');
  return value;
}

export function proxyHeaderValue(value) {
  if (!/^[A-Za-z][A-Za-z0-9-]{1,62}$/.test(value ?? '')) throw new Error('--proxy-header must be a header name of letters, digits and dashes, such as X-Forwarded-For or X-Real-IP.');
  if (FORBIDDEN_HEADERS.has(value.toLowerCase())) throw new Error(`--proxy-header ${value} carries something else on this API and must not be read as the client address.`);
  return value;
}

// The compose.env lines for a choice, or null when --ingress was not given. `trusted-proxy` needs both proxy options; the others refuse them.
export function ingressLines({ ingress, proxyAddress, proxyHeader }) {
  const mode = ingressValue(ingress);
  if (mode === undefined) {
    if (proxyAddress !== undefined || proxyHeader !== undefined) throw new Error('--proxy-address and --proxy-header go with --ingress trusted-proxy.');
    return null;
  }
  if (mode === 'trusted-proxy') {
    if (proxyAddress === undefined || proxyHeader === undefined) throw new Error('--ingress trusted-proxy needs --proxy-address and --proxy-header.');
    return { INGRESS: mode, TRUSTED_PROXY_ADDRESS: proxyAddressValue(proxyAddress), TRUSTED_PROXY_HEADER: proxyHeaderValue(proxyHeader) };
  }
  if (proxyAddress !== undefined || proxyHeader !== undefined) throw new Error('--proxy-address and --proxy-header go with --ingress trusted-proxy.');
  return { INGRESS: mode, TRUSTED_PROXY_ADDRESS: '', TRUSTED_PROXY_HEADER: '' };
}

// The mode a compose.env text holds (no INGRESS line = the default).
export function storedIngress(text) {
  const mode = /^INGRESS=(.*)$/m.exec(text ?? '')?.[1]?.trim();
  return mode ? mode : DEFAULT_INGRESS;
}

// The placeholder public origin of a local-only installation. The manifest and the compose files name an https origin; this one can never
// resolve (`.invalid`, RFC 2606), so it cannot clash with a real domain. The installation is told apart by its instanceId.
export const localOnlyOrigin = instanceId => `https://wh-${instanceId.replace(/-/g, '').slice(0, 12)}.local-only.invalid`;
export const isLocalOnlyOrigin = origin => /^https:\/\/wh-[0-9a-f]{12}\.local-only\.invalid$/.test(origin ?? '');
