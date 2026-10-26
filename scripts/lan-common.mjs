// The LAN fallback, the parts every tool shares (scripts/lan.sh, doctor.mjs, watch.mjs, compose.sh through lan.mjs, configure.mjs):
// what an address, a range and a port must look like, what the host's interfaces are, and the lines an operator reads. Nothing
// here touches Docker, the network or a file except the two reads in readHostInterfaces.
//
// The LAN fallback is a second nginx listener on plain http on the host's own private address (docs/OPERATOR_INSTALL.md, "LAN
// fallback"). Owner decision of 2026-10-26: no certificate, so an address that is not private is refused everywhere: a phone would
// send its tokens to it in clear text.
import { readFileSync } from 'node:fs';
import { networkInterfaces } from 'node:os';

export const LAN_DEFAULT_PORT = '8080';

// 'a.b.c.d' -> [a, b, c, d], or null. No leading zeros ("010" would be read as octal by some tools) and no octet over 255.
export function parseIPv4(text) {
  const match = /^(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})$/.exec(String(text ?? ''));
  if (!match) return null;
  const parts = match.slice(1).map(Number);
  return parts.every(part => part <= 255) ? parts : null;
}
const asNumber = parts => ((parts[0] * 256 + parts[1]) * 256 + parts[2]) * 256 + parts[3];
const fromNumber = value => [Math.floor(value / 2 ** 24) % 256, Math.floor(value / 2 ** 16) % 256, Math.floor(value / 2 ** 8) % 256, value % 256];

// RFC 1918: 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16. The shortest prefix a range may have inside each block.
function privateBlockPrefix(parts) {
  if (parts[0] === 10) return 8;
  if (parts[0] === 172 && parts[1] >= 16 && parts[1] <= 31) return 12;
  if (parts[0] === 192 && parts[1] === 168) return 16;
  return null;
}
export const isPrivateIPv4 = text => {
  const parts = parseIPv4(text);
  return parts !== null && privateBlockPrefix(parts) !== null;
};

// 'a.b.c.d/n' with the host bits cleared ('192.168.1.5/24' -> '192.168.1.0/24'), or null when the text is not a range.
export function normalizeCidr(text) {
  const match = /^([0-9.]+)\/(0|[1-9][0-9]?)$/.exec(String(text ?? ''));
  const parts = match && parseIPv4(match[1]);
  const prefix = match ? Number(match[2]) : NaN;
  if (!parts || prefix > 32) return null;
  const size = 2 ** (32 - prefix);
  return `${fromNumber(Math.floor(asNumber(parts) / size) * size).join('.')}/${prefix}`;
}
export function inCidr(address, cidr) {
  const parts = parseIPv4(address);
  const range = normalizeCidr(cidr);
  if (!parts || !range) return false;
  const [network, prefix] = range.split('/');
  const size = 2 ** (32 - Number(prefix));
  return Math.floor(asNumber(parts) / size) === Math.floor(asNumber(parseIPv4(network)) / size);
}

// The validators of the values lan.sh writes (the pattern of gatewayPortValue in configure.mjs, which re-exports them).
export function lanAddressValue(value) {
  if (!isPrivateIPv4(value)) {
    throw new Error(`${value === undefined || value === '' ? 'No address' : `"${value}"`} is not a private IPv4 address. The LAN address must be one of this host's own addresses in 10.x.x.x, 172.16-31.x.x or 192.168.x.x: phones send their access tokens to it in clear text, so a public address is never accepted.`);
  }
  return String(value);
}
export function lanCidrValue(value) {
  const cidr = normalizeCidr(value);
  const parts = cidr && parseIPv4(cidr.split('/')[0]);
  const shortest = parts && privateBlockPrefix(parts);
  if (!cidr || shortest === null || Number(cidr.split('/')[1]) < shortest) {
    throw new Error(`"${value ?? ''}" is not a private IPv4 range. Give the warehouse network such as 192.168.1.0/24, inside 10.0.0.0/8, 172.16.0.0/12 or 192.168.0.0/16.`);
  }
  return cidr;
}
export function lanPortValue(value) {
  if (!/^[0-9]{4,5}$/.test(String(value)) || Number(value) < 1024 || Number(value) > 65535) throw new Error('The LAN port must be a whole number from 1024 to 65535.');
  return String(Number(value));
}

// What compose.env says: on only when LAN_ENABLED is exactly true. An empty port is the default.
export function lanSettings(env) {
  return { enabled: env.LAN_ENABLED === 'true', ip: env.LAN_BIND_IP || '', port: env.LAN_HTTP_PORT || LAN_DEFAULT_PORT, cidr: env.LAN_CIDR || '' };
}
export const lanOrigin = settings => `http://${settings.ip}:${settings.port}`;
export const lanAddressLine = settings => `LAN address for the app: ${lanOrigin(settings)}`;
// The one host firewall line an operator may need. ufw does not filter Docker-published ports (they are forwarded, and Docker's
// own rules accept them before ufw's), so on a default install nothing is needed; with `ufw default deny routed` this allows it.
export const ufwLine = settings => `sudo ufw route allow proto tcp from ${settings.cidr} to ${settings.ip} port ${settings.port}`;
export function firewallNote(settings) {
  return [
    `Host firewall: if this host runs ufw with routed traffic denied (ufw default deny routed), phones are refused until you run: ${ufwLine(settings)}`,
    'ufw does not filter Docker-published ports by default, so most hosts need nothing. The real controls are the bind address (the container is published on that one address only) and the allow-list of the LAN server (that one network only).',
  ];
}

// ---------------------------------------------------------------- the host's interfaces
// Each item: { name, address, prefix, cidr, defaultRoute }. `networks` has the shape of os.networkInterfaces(); `routeText` is
// /proc/net/route. IPv4 only, loopback left out.
function prefixOf(netmask) {
  const parts = parseIPv4(netmask);
  if (!parts) return null;
  return asNumber(parts).toString(2).replace(/0/g, '').length;
}
// The interface of the default route: the lowest metric among the routes that are up and have a gateway.
export function defaultRouteInterface(routeText) {
  let best = null;
  for (const line of String(routeText ?? '').split('\n').slice(1)) {
    const [name, destination, , flags, , , metric, mask] = line.trim().split(/\s+/);
    if (!name || destination !== '00000000' || mask !== '00000000') continue;
    if ((parseInt(flags, 16) & 0x3) !== 0x3) continue;
    if (best === null || Number(metric) < best.metric) best = { name, metric: Number(metric) };
  }
  return best?.name ?? null;
}
export function ipv4Addresses(networks, routeText = '') {
  const defaultName = defaultRouteInterface(routeText);
  const found = [];
  for (const [name, list] of Object.entries(networks ?? {})) {
    for (const entry of list ?? []) {
      if (entry.family !== 'IPv4' && entry.family !== 4) continue;
      if (entry.internal || !parseIPv4(entry.address)) continue;
      const prefix = prefixOf(entry.netmask);
      if (prefix === null) continue;
      found.push({ name, address: entry.address, prefix, cidr: normalizeCidr(`${entry.address}/${prefix}`), defaultRoute: name === defaultName });
    }
  }
  return found;
}
// The host's addresses. WAREHOUSE_LAN_INTERFACES (JSON, a list of { name, address, prefix, defaultRoute }) replaces the real ones for
// tests, as WAREHOUSE_IMAGE_SAVE_RESERVE does for the image reserve; it has no other use.
export function readHostInterfaces(env = process.env) {
  if (env.WAREHOUSE_LAN_INTERFACES) {
    return JSON.parse(env.WAREHOUSE_LAN_INTERFACES).map(item => ({ cidr: normalizeCidr(`${item.address}/${item.prefix}`), defaultRoute: false, ...item }));
  }
  let routes = '';
  try { routes = readFileSync('/proc/net/route', 'utf8'); } catch { /* not Linux, or not readable: no default route is known */ }
  return ipv4Addresses(networkInterfaces(), routes);
}
export const hostHasAddress = (interfaces, address) => interfaces.some(item => item.address === address);
export const describeAddresses = interfaces => (interfaces.length ? interfaces.map(item => `${item.address} on ${item.name}`).join(', ') : 'no IPv4 address');

// `auto`: the private address of the default-route interface. Returns the interface item, or throws with what to do.
export function autoInterface(interfaces) {
  const onDefault = interfaces.filter(item => item.defaultRoute);
  if (!onDefault.length) throw new Error(`There is no default route, so "auto" cannot pick the host's LAN address. This host has ${describeAddresses(interfaces)}; give the one on the warehouse network: bash scripts/lan.sh on <address>`);
  const usable = onDefault.find(item => isPrivateIPv4(item.address));
  if (!usable) throw new Error(`The interface of the default route (${onDefault[0].name}) has ${onDefault[0].address}, which is not a private address, so "auto" refuses it. Give the host's address on the warehouse network: bash scripts/lan.sh on <address>`);
  return usable;
}

// ---------------------------------------------------------------- COMPOSE_PROFILES and compose.env lines
export const profileList = text => String(text ?? '').split(',').map(item => item.trim()).filter(Boolean);
export function setEnvLine(text, key, value) {
  const line = new RegExp(`^${key}=.*$`, 'm');
  if (line.test(text)) return text.replace(line, () => `${key}=${value}`);
  return `${text}${text === '' || text.endsWith('\n') ? '' : '\n'}${key}=${value}\n`;
}
const removeEnvLine = (text, key) => text.replace(new RegExp(`^${key}=.*\\n?`, 'm'), '');
// The compose.env text with the LAN turned on: the four values, and `lan` added to COMPOSE_PROFILES beside whatever is there.
export function lanOnText(text, { ip, port, cidr }, current = {}) {
  let result = text;
  for (const [key, value] of Object.entries({ LAN_ENABLED: 'true', LAN_BIND_IP: ip, LAN_HTTP_PORT: port, LAN_CIDR: cidr })) result = setEnvLine(result, key, value);
  const profiles = profileList(current.COMPOSE_PROFILES);
  return setEnvLine(result, 'COMPOSE_PROFILES', (profiles.includes('lan') ? profiles : [...profiles, 'lan']).join(','));
}
// Turned off: the values go back to the defaults of .env.example (a line the file does not have is not added, but LAN_ENABLED is
// always written, so the state is explicit), and `lan` leaves COMPOSE_PROFILES, which is removed when nothing else is in it.
export function lanOffText(text, current = {}) {
  let result = setEnvLine(text, 'LAN_ENABLED', 'false');
  for (const [key, value] of Object.entries({ LAN_BIND_IP: '127.0.0.1', LAN_HTTP_PORT: LAN_DEFAULT_PORT, LAN_CIDR: '' })) {
    if (new RegExp(`^${key}=`, 'm').test(result)) result = setEnvLine(result, key, value);
  }
  const rest = profileList(current.COMPOSE_PROFILES).filter(item => item !== 'lan');
  return rest.length ? setEnvLine(result, 'COMPOSE_PROFILES', rest.join(',')) : removeEnvLine(result, 'COMPOSE_PROFILES');
}
