// The LAN fallback: what scripts/lan.sh asks of Node, the doctor checks, and the guard scripts/compose.sh runs.
//
//   node scripts/lan.mjs stage ENV STAGED on [<address>|auto] [--cidr RANGE] [--port N]
//       checks the address, range and port, writes the new compose.env text to STAGED (mode 0600) and prints what it chose
//   node scripts/lan.mjs stage ENV STAGED off
//   node scripts/lan.mjs status ENV [CONTAINER_STATE]       prints whether the fallback is on and the address for the app
//   node scripts/lan.mjs announce ENV                       the lines `on` ends with (address, firewall, reservation)
//   node scripts/lan.mjs guard ENV                          prints COMPOSE_PROFILES=<list> when the LAN address is gone or not private
//
// The fallback is a second nginx listener on plain http on the host's own private address (docs/OPERATOR_INSTALL.md, "LAN
// fallback"). Everything it needs to know about the host's interfaces comes from lan-common.mjs.
import { lstatSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { createServer } from 'node:net';
import { dirname, isAbsolute, resolve } from 'node:path';
import { isMain } from './is-main.mjs';
import { probe, projectPublishesPort, readEnv } from './doctor-common.mjs';
import {
  LAN_DEFAULT_PORT, autoInterface, describeAddresses, firewallNote, hostHasAddress, inCidr, isPrivateIPv4, lanAddressLine, lanAddressValue,
  lanCidrValue, lanOffText, lanOnText, lanOrigin, lanPortValue, lanSettings, profileList, readHostInterfaces,
} from './lan-common.mjs';

// ---------------------------------------------------------------- turning it on
// Whether address:port is free on this host (a connect-free test: try to bind it). Only "in use" and "not allowed" count as taken;
// another failure (the address is not on this host, which the caller has checked) is left to Docker to report.
export const addressFree = (address, port) => new Promise(done => {
  const server = createServer();
  server.once('error', error => done(!['EADDRINUSE', 'EACCES'].includes(error.code)));
  server.listen(Number(port), address, () => server.close(() => done(true)));
});

// What `lan.sh on` decides, from the compose.env values, the arguments and the host. Throws with a message the operator can act on.
// `free` and `publishes` are replaceable for tests. Returns { ip, port, cidr, interface }.
export async function planOn(env, args, { interfaces = readHostInterfaces(), free = addressFree, publishes = projectPublishesPort } = {}) {
  const usage = 'Usage: bash scripts/lan.sh on [<address>|auto] [--cidr <range>] [--port <n>]';
  let wanted;
  let cidrArg;
  let portArg;
  for (let i = 0; i < args.length; i += 1) {
    if (args[i] === '--cidr' || args[i] === '--port') {
      if (args[i + 1] === undefined || args[i + 1].startsWith('--')) throw new Error(`${args[i]} needs a value. ${usage}`);
      if (args[i] === '--cidr') cidrArg = args[i + 1]; else portArg = args[i + 1];
      i += 1;
    } else if (args[i].startsWith('--')) throw new Error(`Unknown option ${args[i]}. ${usage}`);
    else if (wanted === undefined) wanted = args[i];
    else throw new Error(`Give one address (or auto). ${usage}`);
  }
  wanted ??= 'auto';
  const found = wanted === 'auto' ? autoInterface(interfaces) : null;
  const ip = found ? found.address : lanAddressValue(wanted);
  const own = found ?? interfaces.find(item => item.address === ip);
  if (!own) throw new Error(`${ip} is not an address of this host (it has ${describeAddresses(interfaces)}). The container can only publish on an address the host has.`);
  // The range that may connect: given, or the network of the interface. It has to contain the host itself: the checks (and
  // phones on the same network) arrive from inside it.
  const cidr = cidrArg !== undefined ? lanCidrValue(cidrArg) : lanCidrValue(own.cidr);
  if (!inCidr(ip, cidr)) throw new Error(`The range ${cidr} does not contain the host's own address ${ip}; the host could not check its own LAN listener. Give the range of the warehouse network.`);
  // The port: given, else the one already set (a rerun keeps it), else 8080.
  const port = lanPortValue(portArg ?? (env.LAN_HTTP_PORT || LAN_DEFAULT_PORT));
  if (!(await free(ip, port)) && !publishes(env.WAREHOUSE_PROJECT_NAME, Number(port))) {
    throw new Error(`${ip}:${port} is already in use by another program on this host; choose another port with --port.`);
  }
  return { ip, port, cidr, interface: own.name };
}

function privateFile(path) {
  const st = lstatSync(path, { throwIfNoEntry: false });
  if (!st?.isFile() || st.uid !== process.getuid() || (st.mode & 0o077)) throw new Error('Private configuration must be an owned regular file with mode 0600.');
}
// A copy of compose.env with the switch applied, next to it; scripts/lan.sh renames it over compose.env when the service is up.
export function stageLanEnv(envPath, stagedPath, text) {
  if (!isAbsolute(envPath) || !isAbsolute(stagedPath)) throw new Error('Configuration paths must be absolute.');
  if (dirname(resolve(stagedPath)) !== dirname(resolve(envPath)) || resolve(stagedPath) === resolve(envPath)) throw new Error('Staged configuration must be a different file in the compose.env directory.');
  rmSync(stagedPath, { force: true });
  writeFileSync(stagedPath, text, { mode: 0o600, flag: 'wx' });
}

// ---------------------------------------------------------------- reading it back
// The lines `status` and `on` print. `container` is what the caller read from Compose ("running healthy"), or empty.
export function statusLines(env, { interfaces = readHostInterfaces(), container = '' } = {}) {
  const lan = lanSettings(env);
  if (!lan.enabled) return ['LAN fallback is off. Turn it on with: bash scripts/lan.sh on auto'];
  const lines = [lanAddressLine(lan), `Allowed clients: ${lan.cidr || '(none set)'}; published on ${lan.ip}:${lan.port} only.`];
  if (!hostHasAddress(interfaces, lan.ip)) {
    lines.push(`WARNING: this host no longer has ${lan.ip} (it has ${describeAddresses(interfaces)}). The router gave it another address, so phones cannot reach the fallback and the service is not started. Run: bash scripts/lan.sh on auto (then reserve the address in the router) and open the app once on the internet so it learns the new address.`);
  } else {
    const own = interfaces.find(item => item.address === lan.ip);
    lines.push(`Interface: ${own.name} has ${lan.ip}.`);
  }
  lines.push(`Container gateway-lan: ${container.trim() || 'not found (is the stack started?)'}`);
  return lines;
}
export const announceLines = env => {
  const lan = lanSettings(env);
  return [
    lanAddressLine(lan),
    `Allowed clients: ${lan.cidr}. Phones use this address only when the public address fails; sign-in still needs the internet. Plain http: tokens cross the Wi-Fi unencrypted while it is in use (docs/CONTAINER_SECURITY.md, "LAN fallback").`,
    ...firewallNote(lan),
    'Reserve this address for the host in the router (DHCP reservation). If it changes, run bash scripts/lan.sh on auto again and let the phones connect once over the internet to learn the new address.',
  ];
};

// ---------------------------------------------------------------- the guard of scripts/compose.sh
// COMPOSE_PROFILES=lan in compose.env makes every `compose up` start the gateway-lan service, which publishes LAN_BIND_IP. Two things
// keep the profile out of a command (compose.sh sets the replacement list for that one command and prints the reason on stderr):
// the host no longer has the address (the router gave it another; Docker cannot start the container, and one container that fails to
// start can stop `up` for the services beside it, which are the public ones), or the address is not a private one (a hand-edited
// 0.0.0.0 or a public address would put plain http on the internet). Loopback, the default while the fallback is off, is fine.
// Returns null (leave the profiles as they are) or { profiles, reason }.
export function guardProfiles(env, interfaces) {
  const profiles = profileList(env.COMPOSE_PROFILES);
  if (!profiles.includes('lan')) return null;
  const ip = env.LAN_BIND_IP || '127.0.0.1';
  const without = profiles.filter(item => item !== 'lan').join(',');
  if (ip === '127.0.0.1') return null;
  if (!isPrivateIPv4(ip)) return { profiles: without, reason: `LAN_BIND_IP is "${ip}", which is not a private IPv4 address, so the gateway-lan service is left out of this command (it would put plain http on that address). Run: bash scripts/lan.sh on auto` };
  if (!lanSettings(env).enabled || hostHasAddress(interfaces, ip)) return null;
  return { profiles: without, reason: `this host no longer has ${ip}, so the gateway-lan service is left out of this command (the public gateway is not affected). Run: bash scripts/lan.sh on auto` };
}

// ---------------------------------------------------------------- the doctor checks
// Published ports of the gateway-lan container, as `docker ps` prints them ("192.168.1.52:8080->8080/tcp, [::]:8080->8080/tcp").
export function lanPublishers(project, run = probe) {
  const listed = run('docker', ['ps', '--filter', `label=com.docker.compose.project=${project}`, '--filter', 'label=com.docker.compose.service=gateway-lan', '--format', '{{.Ports}}']);
  if (!listed.ok) return null;
  const published = [];
  for (const entry of listed.output.split(/[\r\n]+/).flatMap(line => line.split(','))) {
    const match = /^\s*(\[[0-9a-f:]*\]|[0-9.]+):(\d+)(?:-\d+)?->(\d+)/i.exec(entry);
    if (match) published.push({ host: match[1], port: Number(match[2]), target: Number(match[3]) });
  }
  return published;
}

// The checks of `doctor` while the fallback is on. Returns [{ level: 'fail' | 'warn' | 'info', text }]. `fetch`, `run` and
// `interfaces` are replaceable for tests; `instanceId` is the manifest's.
export async function lanChecks(env, { instanceId, interfaces = readHostInterfaces(), run = probe, fetchImpl = fetch } = {}) {
  const lan = lanSettings(env);
  if (!lan.enabled) return [];
  const out = [];
  const fail = text => out.push({ level: 'fail', text });
  const warn = text => out.push({ level: 'warn', text });
  const rerun = 'Run: bash scripts/lan.sh on auto';
  if (!isPrivateIPv4(lan.ip)) {
    fail(`LAN_BIND_IP is "${lan.ip}", not a private IPv4 address. ${rerun}`);
    return out;
  }
  if (!/^[0-9]{4,5}$/.test(lan.port) || Number(lan.port) < 1024 || Number(lan.port) > 65535) fail(`LAN_HTTP_PORT is "${lan.port}", not a port from 1024 to 65535. ${rerun}`);
  let cidrOk = false;
  try { lanCidrValue(lan.cidr); cidrOk = true; } catch { fail(`LAN_CIDR is "${lan.cidr}", not a private IPv4 range: the gateway-lan container refuses to start. ${rerun}`); }
  if (cidrOk && !inCidr(lan.ip, lan.cidr)) fail(`LAN_CIDR ${lan.cidr} does not contain LAN_BIND_IP ${lan.ip}. ${rerun}`);
  if (!hostHasAddress(interfaces, lan.ip)) {
    fail(`LAN_BIND_IP ${lan.ip} is not an address of this host (it has ${describeAddresses(interfaces)}): the router gave the host another address, so the LAN fallback cannot start and phones that saved ${lanOrigin(lan)} cannot use it. ${rerun}, reserve the address in the router, and let each phone connect once over the internet to learn the new one.`);
    return out;
  }
  if (cidrOk && !interfaces.some(item => inCidr(item.address, lan.cidr))) warn(`No address of this host is inside LAN_CIDR ${lan.cidr}: the host has no route to the warehouse network it allows.`);
  if (!profileList(env.COMPOSE_PROFILES).includes('lan')) {
    fail(`LAN_ENABLED is true but COMPOSE_PROFILES in config/compose.env does not include lan, so start.sh and the boot unit do not start the gateway-lan service. ${rerun}`);
  }
  const publishers = lanPublishers(env.WAREHOUSE_PROJECT_NAME, run);
  if (publishers === null) warn('The published port of gateway-lan could not be read (docker ps failed).');
  else if (!publishers.length) fail(`The gateway-lan container is not running (nothing publishes ${lan.ip}:${lan.port}). Check: bash scripts/lan.sh status`);
  else {
    const stray = publishers.filter(item => item.host !== lan.ip || item.port !== Number(lan.port));
    if (stray.length) fail(`gateway-lan is published on ${stray.map(item => `${item.host}:${item.port}`).join(', ')}, not only on ${lan.ip}:${lan.port}: it would be reachable from other networks. Run bash scripts/lan.sh off and then ${rerun}.`);
  }
  // The listener itself, from the host, the way a phone on the network reaches it: the plain-http address answers the public
  // configuration, as this installation, with the header that says the LAN path answered.
  try {
    const response = await fetchImpl(`${lanOrigin(lan)}/functions/v1/get-public-config`, { signal: AbortSignal.timeout(15000), redirect: 'error' });
    if (!response.ok) fail(`${lanOrigin(lan)} answered HTTP ${response.status} to get-public-config${response.status === 403 ? ' (refused by the allow-list: LAN_CIDR does not include the address the host connects from)' : ''}.`);
    else {
      const json = await response.json();
      if (json.success !== true || (instanceId && json.data?.instanceId !== instanceId)) fail(`${lanOrigin(lan)} answers, but not as this installation (instanceId differs).`);
      else if (response.headers.get('x-warehouse-path') !== 'lan') fail(`${lanOrigin(lan)} answers without the header X-Warehouse-Path: lan, so it is not the gateway-lan listener.`);
    }
  } catch (error) {
    fail(`${lanOrigin(lan)} does not answer from this host (${error.cause?.code ?? error.message}).`);
  }
  return out;
}

// ---------------------------------------------------------------- command line
const USAGE = `Usage: node scripts/lan.mjs stage ENV STAGED on [<address>|auto] [--cidr RANGE] [--port N]
       node scripts/lan.mjs stage ENV STAGED off
       node scripts/lan.mjs status ENV [CONTAINER_STATE]
       node scripts/lan.mjs announce ENV
       node scripts/lan.mjs guard ENV`;

if (isMain(import.meta.url)) {
  try {
    const [command, ...rest] = process.argv.slice(2);
    const envFile = path => { if (!path || !isAbsolute(path)) throw new Error(USAGE); privateFile(path); return path; };
    if (command === 'stage' && rest.length >= 3 && rest[2] === 'on') {
      const path = envFile(rest[0]);
      const env = readEnv(path);
      const plan = await planOn(env, rest.slice(3));
      stageLanEnv(path, rest[1], lanOnText(readFileSync(path, 'utf8'), plan, env));
      console.log(`LAN fallback: ${plan.ip}:${plan.port} on ${plan.interface}, allowing ${plan.cidr}`);
    } else if (command === 'stage' && rest.length === 3 && rest[2] === 'off') {
      const path = envFile(rest[0]);
      stageLanEnv(path, rest[1], lanOffText(readFileSync(path, 'utf8'), readEnv(path)));
    } else if (command === 'status' && rest.length >= 1 && rest.length <= 2) {
      console.log(statusLines(readEnv(envFile(rest[0])), { container: rest[1] ?? '' }).join('\n'));
    } else if (command === 'announce' && rest.length === 1) {
      console.log(announceLines(readEnv(envFile(rest[0]))).join('\n'));
    } else if (command === 'guard' && rest.length === 1) {
      const env = readEnv(envFile(rest[0]));
      const decision = guardProfiles(env, readHostInterfaces());
      if (decision !== null) {
        console.error(`LAN fallback: ${decision.reason}`);
        console.log(`COMPOSE_PROFILES=${decision.profiles}`);
      }
    } else throw new Error(USAGE);
  } catch (error) { console.error(`LAN: ${error.message}`); process.exitCode = 1; }
}
