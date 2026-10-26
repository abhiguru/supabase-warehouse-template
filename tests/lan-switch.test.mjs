// The LAN fallback's switch: scripts/lan.sh (on, off, status) against a fake docker and fake interfaces, what it writes to
// config/compose.env, what it refuses, the guard in scripts/compose.sh, and the pieces in scripts/lan-common.mjs and
// scripts/lan.mjs that decide them. No Docker, no network.
import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, rmSync, statSync, existsSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { configure } from '../scripts/configure.mjs';
import { readEnv } from '../scripts/doctor-common.mjs';
import {
  autoInterface, defaultRouteInterface, inCidr, ipv4Addresses, isPrivateIPv4, lanAddressLine, lanAddressValue, lanCidrValue, lanOffText, lanOnText,
  lanPortValue, normalizeCidr, parseIPv4, ufwLine,
} from '../scripts/lan-common.mjs';
import { addressFree, announceLines, guardProfiles, lanChecks, lanPublishers, planOn, statusLines } from '../scripts/lan.mjs';

const root = new URL('..', import.meta.url).pathname;

// ---------------------------------------------------------------- addresses, ranges, ports
test('only private IPv4 addresses are accepted, written plainly', () => {
  for (const address of ['10.0.0.1', '10.255.255.254', '172.16.0.1', '172.31.255.1', '192.168.0.1', '192.168.1.20']) assert.equal(lanAddressValue(address), address);
  for (const address of ['8.8.8.8', '1.1.1.1', '172.15.0.1', '172.32.0.1', '192.167.1.1', '192.169.1.1', '100.64.0.1', '169.254.1.1', '127.0.0.1', '0.0.0.0', '255.255.255.255',
    '192.168.1.256', '192.168.1', '192.168.1.1.1', '192.168.001.1', '010.0.0.1', '192.168.1.1/24', ' 192.168.1.1', '192.168.1.1\n', 'localhost', '::1', 'fe80::1', '', undefined]) {
    assert.throws(() => lanAddressValue(address), /not a private IPv4 address/, String(address));
  }
  assert.equal(isPrivateIPv4('192.168.1.20'), true);
  assert.equal(isPrivateIPv4('192.168.1.2000'), false);
  assert.equal(parseIPv4('1.2.3.4').join('.'), '1.2.3.4');
  assert.equal(parseIPv4('1.2.3.04'), null);
});

test('ranges are private, written with the host bits cleared, and tested by prefix', () => {
  assert.equal(normalizeCidr('192.168.1.77/24'), '192.168.1.0/24');
  assert.equal(normalizeCidr('10.9.8.7/8'), '10.0.0.0/8');
  assert.equal(normalizeCidr('172.20.5.4/12'), '172.16.0.0/12');
  assert.equal(normalizeCidr('192.168.1.5/32'), '192.168.1.5/32');
  assert.equal(normalizeCidr('192.168.1.5/33'), null);
  assert.equal(normalizeCidr('192.168.1.5'), null);
  assert.equal(normalizeCidr('x/24'), null);
  for (const cidr of ['10.0.0.0/8', '172.16.0.0/12', '192.168.0.0/16', '192.168.1.0/24', '10.1.2.3/32']) assert.ok(lanCidrValue(cidr));
  assert.equal(lanCidrValue('192.168.1.99/24'), '192.168.1.0/24');
  for (const cidr of ['0.0.0.0/0', '8.8.8.0/24', '10.0.0.0/7', '172.16.0.0/11', '192.168.0.0/15', '172.32.0.0/16', '100.64.0.0/10', '192.168.1.0', 'all', '', undefined]) {
    assert.throws(() => lanCidrValue(cidr), /not a private IPv4 range/, String(cidr));
  }
  assert.equal(inCidr('192.168.1.20', '192.168.1.0/24'), true);
  assert.equal(inCidr('192.168.2.20', '192.168.1.0/24'), false);
  assert.equal(inCidr('10.200.0.1', '10.0.0.0/8'), true);
  assert.equal(inCidr('172.32.0.1', '172.16.0.0/12'), false);
  assert.equal(inCidr('192.168.1.20', 'nonsense'), false);
});

test('the port is a whole number from 1024 to 65535', () => {
  assert.equal(lanPortValue('8080'), '8080');
  assert.equal(lanPortValue(8181), '8181');
  assert.equal(lanPortValue('65535'), '65535');
  for (const port of ['80', '1023', '65536', '08080x', '8080 ', '-1', '', 'http', undefined]) assert.throws(() => lanPortValue(port), /1024 to 65535/, String(port));
});

// ---------------------------------------------------------------- the host's interfaces
const NETWORKS = {
  lo: [{ address: '127.0.0.1', netmask: '255.0.0.0', family: 'IPv4', internal: true }],
  ens33: [{ address: '192.168.1.52', netmask: '255.255.255.0', family: 'IPv4', internal: false }, { address: 'fe80::1', netmask: 'ffff:ffff:ffff:ffff::', family: 'IPv6', internal: false }],
  docker0: [{ address: '172.17.0.1', netmask: '255.255.0.0', family: 'IPv4', internal: false }],
  wlan0: [{ address: '203.0.113.7', netmask: '255.255.255.0', family: 'IPv4', internal: false }],
};
const ROUTES = 'Iface\tDestination\tGateway \tFlags\tRefCnt\tUse\tMetric\tMask\t\tMTU\tWindow\tIRTT\n'
  + 'wlan0\t00000000\t0107A8C0\t0003\t0\t0\t600\t00000000\t0\t0\t0\n'
  + 'ens33\t00000000\t0101A8C0\t0003\t0\t0\t100\t00000000\t0\t0\t0\n'
  + 'ens33\t0001A8C0\t00000000\t0001\t0\t0\t100\t00FFFFFF\t0\t0\t0\n'
  + 'docker0\t000011AC\t00000000\t0001\t0\t0\t0\t0000FFFF\t0\t0\t0\n';

test('the host\'s addresses: IPv4 only, no loopback, with the network of each and the interface of the default route', () => {
  assert.equal(defaultRouteInterface(ROUTES), 'ens33', 'the lowest metric among the routes with a gateway');
  assert.equal(defaultRouteInterface('Iface\tDestination\tGateway\tFlags\tRefCnt\tUse\tMetric\tMask\nens33\t00000000\t0101A8C0\t0001\t0\t0\t100\t00000000\n'), null, 'a default route without the gateway flag is not one');
  assert.equal(defaultRouteInterface(''), null);
  const found = ipv4Addresses(NETWORKS, ROUTES);
  assert.deepEqual(found.map(item => [item.name, item.address, item.prefix, item.cidr, item.defaultRoute]), [
    ['ens33', '192.168.1.52', 24, '192.168.1.0/24', true],
    ['docker0', '172.17.0.1', 16, '172.17.0.0/16', false],
    ['wlan0', '203.0.113.7', 24, '203.0.113.0/24', false],
  ]);
  assert.equal(autoInterface(found).address, '192.168.1.52');
  // `auto` needs a default route, and a private address on it.
  assert.throws(() => autoInterface(ipv4Addresses(NETWORKS, '')), /no default route/);
  assert.throws(() => autoInterface(ipv4Addresses(NETWORKS, ROUTES.replace(/^ens33/gm, 'wlan0'))), /not a private address/);
});

// ---------------------------------------------------------------- the decision of `on`
const HOST = [
  { name: 'ens33', address: '192.168.1.52', prefix: 24, cidr: '192.168.1.0/24', defaultRoute: true },
  { name: 'docker0', address: '172.17.0.1', prefix: 16, cidr: '172.17.0.0/16', defaultRoute: false },
  { name: 'wlan0', address: '203.0.113.7', prefix: 24, cidr: '203.0.113.0/24', defaultRoute: false },
];
const free = async () => true;
const nobody = () => false;

test('on: auto takes the default-route address and the network of its interface; the port keeps what is set', async () => {
  const plan = await planOn({}, [], { interfaces: HOST, free, publishes: nobody });
  assert.deepEqual(plan, { ip: '192.168.1.52', port: '8080', cidr: '192.168.1.0/24', interface: 'ens33' });
  assert.deepEqual(await planOn({}, ['auto'], { interfaces: HOST, free, publishes: nobody }), plan);
  assert.deepEqual(await planOn({ LAN_HTTP_PORT: '8181' }, ['192.168.1.52'], { interfaces: HOST, free, publishes: nobody }), { ...plan, port: '8181' });
  assert.deepEqual(await planOn({ LAN_HTTP_PORT: '8181' }, ['192.168.1.52', '--port', '9090'], { interfaces: HOST, free, publishes: nobody }), { ...plan, port: '9090' });
  assert.deepEqual(await planOn({}, ['--cidr', '192.168.0.0/16', '192.168.1.52'], { interfaces: HOST, free, publishes: nobody }), { ...plan, cidr: '192.168.0.0/16' });
});

test('on refuses an address that is not private, not this host\'s, a range without the host, a bad port, a port in use', async () => {
  const refuse = (args, pattern, options = {}) => assert.rejects(planOn({}, args, { interfaces: HOST, free, publishes: nobody, ...options }), pattern, args.join(' '));
  await refuse(['203.0.113.7'], /not a private IPv4 address/);              // an address of this host, but public
  await refuse(['8.8.8.8'], /not a private IPv4 address/);
  await refuse(['192.168.1.99'], /not an address of this host \(it has 192\.168\.1\.52 on ens33, 172\.17\.0\.1 on docker0, 203\.0\.113\.7 on wlan0\)/);
  await refuse(['192.168.1.52', '--cidr', '192.168.5.0/24'], /does not contain the host's own address 192\.168\.1\.52/);
  await refuse(['192.168.1.52', '--cidr', '8.8.8.0/24'], /not a private IPv4 range/);
  await refuse(['192.168.1.52', '--cidr', '0.0.0.0/0'], /not a private IPv4 range/);
  await refuse(['192.168.1.52', '--port', '80'], /1024 to 65535/);
  await refuse(['192.168.1.52', '--port'], /--port needs a value/);
  await refuse(['192.168.1.52', '--bogus'], /Unknown option --bogus/);
  await refuse(['192.168.1.52', '10.0.0.1'], /Give one address/);
  await refuse([], /already in use/, { free: async () => false });
  await refuse([], /no default route/, { interfaces: HOST.map(item => ({ ...item, defaultRoute: false })) });
  // A port in use by this installation's own gateway-lan is fine (a rerun); one in use by a stranger is not.
  assert.equal((await planOn({ WAREHOUSE_PROJECT_NAME: 'warehouse-x' }, [], { interfaces: HOST, free: async () => false, publishes: (project, port) => project === 'warehouse-x' && port === 8080 })).port, '8080');
});

test('a bind to an address the host does not have is not "in use"; a port that is taken is', async () => {
  const { createServer } = await import('node:net');
  const server = createServer();
  await new Promise(done => server.listen(0, '127.0.0.1', done));
  const { port } = server.address();
  try {
    assert.equal(await addressFree('127.0.0.1', port), false);
    assert.equal(await addressFree('127.0.0.1', port === 65535 ? 65534 : port + 1) || true, true);
    assert.equal(await addressFree('192.0.2.77', 8080), true, 'EADDRNOTAVAIL is for Docker to report');
  } finally { server.close(); }
});

// ---------------------------------------------------------------- compose.env text
test('the compose.env text: on adds the four values and lan beside the other profiles, off puts the defaults back and removes lan only', () => {
  const base = 'A=1\nLAN_ENABLED=false\nLAN_BIND_IP=127.0.0.1\nLAN_HTTP_PORT=8080\nLAN_CIDR=\nB=2\n';
  const on = lanOnText(base, { ip: '192.168.1.20', port: '8181', cidr: '192.168.1.0/24' }, {});
  assert.equal(on, 'A=1\nLAN_ENABLED=true\nLAN_BIND_IP=192.168.1.20\nLAN_HTTP_PORT=8181\nLAN_CIDR=192.168.1.0/24\nB=2\nCOMPOSE_PROFILES=lan\n');
  assert.equal(lanOffText(on, { COMPOSE_PROFILES: 'lan' }), base, 'back to the lines of .env.example, and no profile line');
  // A state from before the lines gets them appended; off writes LAN_ENABLED=false and adds nothing else.
  assert.equal(lanOnText('A=1\n', { ip: '10.0.0.5', port: '8080', cidr: '10.0.0.0/8' }, {}), 'A=1\nLAN_ENABLED=true\nLAN_BIND_IP=10.0.0.5\nLAN_HTTP_PORT=8080\nLAN_CIDR=10.0.0.0/8\nCOMPOSE_PROFILES=lan\n');
  assert.equal(lanOffText('A=1\nCOMPOSE_PROFILES=lan\n', { COMPOSE_PROFILES: 'lan' }), 'A=1\nLAN_ENABLED=false\n');
  // Other profiles are kept, in order, and lan is not listed twice.
  const merged = lanOnText('COMPOSE_PROFILES=printing,sensors\n', { ip: '10.0.0.5', port: '8080', cidr: '10.0.0.0/8' }, { COMPOSE_PROFILES: 'printing,sensors' });
  assert.match(merged, /^COMPOSE_PROFILES=printing,sensors,lan$/m);
  assert.match(lanOnText(merged, { ip: '10.0.0.6', port: '8080', cidr: '10.0.0.0/8' }, { COMPOSE_PROFILES: 'printing,sensors,lan' }), /^COMPOSE_PROFILES=printing,sensors,lan$/m);
  assert.match(lanOffText(merged, { COMPOSE_PROFILES: 'printing,sensors,lan' }), /^COMPOSE_PROFILES=printing,sensors$/m);
  assert.equal(lanOffText(merged, { COMPOSE_PROFILES: 'printing,sensors,lan' }).includes('lan\n'), false);
});

test('the lines the operator reads: the address for the app, the allowed network, the one firewall line and why it is rarely needed', () => {
  const env = { LAN_ENABLED: 'true', LAN_BIND_IP: '192.168.1.52', LAN_HTTP_PORT: '8080', LAN_CIDR: '192.168.1.0/24' };
  assert.equal(lanAddressLine({ ip: '192.168.1.52', port: '8080' }), 'LAN address for the app: http://192.168.1.52:8080');
  assert.equal(ufwLine({ ip: '192.168.1.52', port: '8080', cidr: '192.168.1.0/24' }), 'sudo ufw route allow proto tcp from 192.168.1.0/24 to 192.168.1.52 port 8080');
  const lines = announceLines(env);
  assert.equal(lines[0], 'LAN address for the app: http://192.168.1.52:8080');
  assert.match(lines.join('\n'), /sudo ufw route allow proto tcp from 192\.168\.1\.0\/24 to 192\.168\.1\.52 port 8080/);
  assert.match(lines.join('\n'), /ufw does not filter Docker-published ports by default/);
  assert.match(lines.join('\n'), /bind address.*allow-list/);
  assert.match(lines.join('\n'), /tokens cross the Wi-Fi unencrypted/);
  assert.match(lines.join('\n'), /DHCP reservation/);
  // status: the address, whether the host still has it, and the container.
  assert.deepEqual(statusLines(env, { interfaces: HOST, container: 'running healthy' }), [
    'LAN address for the app: http://192.168.1.52:8080',
    'Allowed clients: 192.168.1.0/24; published on 192.168.1.52:8080 only.',
    'Interface: ens33 has 192.168.1.52.',
    'Container gateway-lan: running healthy',
  ]);
  const moved = statusLines(env, { interfaces: HOST.map(item => (item.name === 'ens33' ? { ...item, address: '192.168.1.53' } : item)), container: 'exited' });
  assert.match(moved.join('\n'), /^WARNING: this host no longer has 192\.168\.1\.52 \(it has 192\.168\.1\.53 on ens33, .*Run: bash scripts\/lan\.sh on auto/m);
  assert.deepEqual(statusLines({ LAN_ENABLED: 'false' }, { interfaces: HOST }), ['LAN fallback is off. Turn it on with: bash scripts/lan.sh on auto']);
  assert.deepEqual(statusLines({}, { interfaces: HOST }), ['LAN fallback is off. Turn it on with: bash scripts/lan.sh on auto']);
});

// ---------------------------------------------------------------- the guard of compose.sh
test('the guard leaves the lan profile out when the host no longer has the address or the address is not private, and otherwise not', () => {
  const on = { LAN_ENABLED: 'true', LAN_BIND_IP: '192.168.1.52', COMPOSE_PROFILES: 'printing,lan' };
  assert.equal(guardProfiles(on, HOST), null, 'the address is there');
  const moved = HOST.filter(item => item.name !== 'ens33');
  const gone = guardProfiles(on, moved);
  assert.equal(gone.profiles, 'printing');
  assert.match(gone.reason, /^this host no longer has 192\.168\.1\.52, so the gateway-lan service is left out of this command \(the public gateway is not affected\)\. Run: bash scripts\/lan\.sh on auto$/);
  assert.equal(guardProfiles({ ...on, COMPOSE_PROFILES: 'lan' }, moved).profiles, '', 'nothing else listed: an empty list');
  assert.equal(guardProfiles({ ...on, COMPOSE_PROFILES: 'printing' }, moved), null, 'lan is not listed');
  assert.equal(guardProfiles({ ...on, LAN_ENABLED: 'false' }, moved), null, 'the fallback is not on: the container would be published on the address of compose.env, which the host did have');
  assert.equal(guardProfiles({ ...on, LAN_BIND_IP: '127.0.0.1' }, moved), null, 'loopback publishes nothing outside the host');
  assert.equal(guardProfiles({ ...on, LAN_BIND_IP: '' }, moved), null, 'empty: Compose publishes on loopback');
  assert.equal(guardProfiles({}, moved), null);
  // A hand-edited address that is not private is never published, whether or not the host has it (203.0.113.7 is on wlan0 in HOST).
  for (const address of ['0.0.0.0', '203.0.113.7', '8.8.8.8', '::', '192.168.1.256']) {
    for (const enabled of ['true', 'false']) {
      const refused = guardProfiles({ ...on, LAN_ENABLED: enabled, LAN_BIND_IP: address }, HOST);
      assert.equal(refused.profiles, 'printing', `${address} ${enabled}`);
      assert.match(refused.reason, new RegExp(`LAN_BIND_IP is "${address.replace(/\./g, '\\.')}", which is not a private IPv4 address, so the gateway-lan service is left out of this command`));
    }
  }
});

// ---------------------------------------------------------------- the doctor checks
const MANIFEST_ID = '11111111-2222-3333-4444-555555555555';
const lanEnv = { LAN_ENABLED: 'true', LAN_BIND_IP: '192.168.1.52', LAN_HTTP_PORT: '8080', LAN_CIDR: '192.168.1.0/24', COMPOSE_PROFILES: 'lan', WAREHOUSE_PROJECT_NAME: 'warehouse-test' };
const answering = { ok: true, status: 200, headers: new Headers({ 'x-warehouse-path': 'lan' }), json: async () => ({ success: true, data: { instanceId: MANIFEST_ID } }) };
const runPorts = ports => () => ({ ok: true, output: `${ports}\n` });
const check = (env, options = {}) => lanChecks(env, { instanceId: MANIFEST_ID, interfaces: HOST, run: runPorts('192.168.1.52:8080->8080/tcp'), fetchImpl: async () => answering, ...options });
const levels = checks => checks.map(item => item.level);

test('doctor checks: silent while off; nothing to report when the listener answers as this installation', async () => {
  assert.deepEqual(await check({ ...lanEnv, LAN_ENABLED: 'false' }), []);
  assert.deepEqual(await check({}), []);
  assert.deepEqual(await check(lanEnv), []);
  let asked;
  await check(lanEnv, { fetchImpl: async (url, options) => { asked = [url, options.redirect]; return answering; } });
  assert.deepEqual(asked, ['http://192.168.1.52:8080/functions/v1/get-public-config', 'error']);
});

test('doctor checks: the address gone, the publisher wrong, the listener silent, the wrong answer, the profile missing, a bad value', async () => {
  const gone = await check(lanEnv, { interfaces: HOST.filter(item => item.name !== 'ens33') });
  assert.deepEqual(levels(gone), ['fail']);
  assert.match(gone[0].text, /LAN_BIND_IP 192\.168\.1\.52 is not an address of this host \(it has 172\.17\.0\.1 on docker0, 203\.0\.113\.7 on wlan0\).*Run: bash scripts\/lan\.sh on auto/);
  // Published on more than the bind address.
  const wide = await check(lanEnv, { run: runPorts('0.0.0.0:8080->8080/tcp, [::]:8080->8080/tcp') });
  assert.deepEqual(levels(wide), ['fail']);
  assert.match(wide[0].text, /published on 0\.0\.0\.0:8080, \[::\]:8080, not only on 192\.168\.1\.52:8080/);
  const other = await check(lanEnv, { run: runPorts('192.168.1.52:9999->8080/tcp') });
  assert.match(other[0].text, /not only on 192\.168\.1\.52:8080/);
  // No container, or Docker not answering.
  assert.match((await check(lanEnv, { run: runPorts('') }))[0].text, /gateway-lan container is not running/);
  assert.deepEqual(levels(await check(lanEnv, { run: () => ({ ok: false, output: '' }) })), ['warn']);
  // The listener: refused, an error status (a 403 says why), another installation, not the LAN listener.
  assert.match((await check(lanEnv, { fetchImpl: async () => { throw Object.assign(new Error('fetch failed'), { cause: { code: 'ECONNREFUSED' } }); } }))[0].text, /http:\/\/192\.168\.1\.52:8080 does not answer from this host \(ECONNREFUSED\)/);
  const refused = await check(lanEnv, { fetchImpl: async () => ({ ok: false, status: 403 }) });
  assert.match(refused[0].text, /answered HTTP 403 .*allow-list: LAN_CIDR does not include the address the host connects from/);
  assert.match((await check(lanEnv, { fetchImpl: async () => ({ ...answering, json: async () => ({ success: true, data: { instanceId: 'other' } }) }) }))[0].text, /not as this installation/);
  assert.match((await check(lanEnv, { fetchImpl: async () => ({ ...answering, headers: new Headers({ 'x-warehouse-path': 'public' }) }) }))[0].text, /without the header X-Warehouse-Path: lan/);
  assert.match((await check(lanEnv, { fetchImpl: async () => ({ ...answering, headers: new Headers() }) }))[0].text, /without the header X-Warehouse-Path: lan/);
  // compose.env: lan missing from the profiles, a value that is not valid.
  assert.match((await check({ ...lanEnv, COMPOSE_PROFILES: '' }))[0].text, /COMPOSE_PROFILES in config\/compose\.env does not include lan/);
  assert.match((await check({ ...lanEnv, LAN_BIND_IP: '8.8.8.8' }))[0].text, /LAN_BIND_IP is "8\.8\.8\.8", not a private IPv4 address/);
  assert.match((await check({ ...lanEnv, LAN_CIDR: '' }))[0].text, /LAN_CIDR is "", not a private IPv4 range: the gateway-lan container refuses to start/);
  assert.match((await check({ ...lanEnv, LAN_CIDR: '192.168.9.0/24' }))[0].text, /LAN_CIDR 192\.168\.9\.0\/24 does not contain LAN_BIND_IP 192\.168\.1\.52/);
  assert.match((await check({ ...lanEnv, LAN_HTTP_PORT: '80' }))[0].text, /LAN_HTTP_PORT is "80"/);
  // No address of the host inside the range is a warning, not a failure.
  const lonely = await check({ ...lanEnv, LAN_CIDR: '192.168.1.0/24' }, { interfaces: [{ name: 'ens33', address: '192.168.1.52', prefix: 8, cidr: '192.0.0.0/8', defaultRoute: true }] });
  assert.deepEqual(levels(lonely), []);
});

test('the published ports of gateway-lan are read from docker ps in each form', () => {
  const ask = output => lanPublishers('warehouse-test', () => ({ ok: true, output }));
  assert.deepEqual(ask('192.168.1.52:8080->8080/tcp\n'), [{ host: '192.168.1.52', port: 8080, target: 8080 }]);
  assert.deepEqual(ask('0.0.0.0:8080->8080/tcp, [::]:8080->8080/tcp\n'), [{ host: '0.0.0.0', port: 8080, target: 8080 }, { host: '[::]', port: 8080, target: 8080 }]);
  assert.deepEqual(ask('8080/tcp\n'), [], 'exposed, not published');
  assert.deepEqual(ask(''), []);
  assert.equal(lanPublishers('warehouse-test', () => ({ ok: false, output: '' })), null);
  let asked;
  lanPublishers('warehouse-test', (command, args) => { asked = [command, ...args]; return { ok: true, output: '' }; });
  assert.deepEqual(asked, ['docker', 'ps', '--filter', 'label=com.docker.compose.project=warehouse-test', '--filter', 'label=com.docker.compose.service=gateway-lan', '--format', '{{.Ports}}']);
});

// ---------------------------------------------------------------- lan.sh against a fake docker
// Every docker call is logged, with the COMPOSE_PROFILES the call saw. Behaviours: FAKE_STOPPED=yes (the gateway is not running),
// FAKE_FAIL_UP=yes (gateway-lan does not become healthy), FAKE_LAN_PORTS (what `docker ps` says gateway-lan publishes).
const fakeDocker = `#!/bin/sh
printf '%s\\n' "$*" >> "$FAKE_DOCKER_LOG"
printf '%s\\n' "\${COMPOSE_PROFILES+profiles=}\${COMPOSE_PROFILES-}" >> "$FAKE_ENV_LOG"
case "$1" in
  ps) case "$*" in
        *service=gateway-lan*Ports*) printf '%s\\n' "\${FAKE_LAN_PORTS:-}" ;;
        *Ports*) printf '%s\\n' "\${FAKE_PORTS:-}" ;;
      esac; exit 0 ;;
  inspect) echo true; exit 0 ;;
  compose)
    case "$*" in
      *' ps -q gateway'|*' ps -q functions') if [ "\${FAKE_STOPPED:-}" = yes ]; then exit 0; fi; echo abcabcabcabc; exit 0 ;;
      *'ps --all --format'*gateway-lan) echo 'running healthy'; exit 0 ;;
      *' up -d --no-deps --wait'*gateway-lan*) if [ "\${FAKE_FAIL_UP:-}" = yes ]; then echo 'fake: gateway-lan unhealthy' >&2; exit 1; fi; exit 0 ;;
    esac
    exit 0 ;;
esac
`;
// The fetch of the doctor step: an answer of this installation, from the LAN listener (replaces fetch in the child Node process).
const fetchStub = `globalThis.fetch = async url => {
  (await import('node:fs')).appendFileSync(process.env.FAKE_FETCH_LOG, url + '\\n');
  return { ok: true, status: 200, headers: new Headers({ 'x-warehouse-path': 'lan' }), json: async () => ({ success: true, data: { instanceId: process.env.FAKE_INSTANCE_ID } }) };
};
`;
const INTERFACES = JSON.stringify([
  { name: 'ens33', address: '192.168.77.5', prefix: 24, defaultRoute: true },
  { name: 'docker0', address: '172.17.0.1', prefix: 16, defaultRoute: false },
]);

function fixture({ env } = {}) {
  const scratch = mkdtempSync(join(tmpdir(), 'warehouse-lan-'));
  const state = join(scratch, 'state');
  const bin = join(scratch, 'bin');
  mkdirSync(bin);
  writeFileSync(join(scratch, 'provider.env'), 'SMS_PROVIDER=msg91\nMSG91_AUTH_KEY=isolated-no-delivery-key\nMSG91_TEMPLATE_ID=000000000000000000000001\nMSG91_PE_ID=1\nMSG91_SENDER_ID=CHECK\n', { mode: 0o600 });
  configure(root, { stateDir: state, apiUrl: 'https://api.example.test', company: 'Acme', providerEnv: join(scratch, 'provider.env') });
  writeFileSync(join(bin, 'docker'), fakeDocker, { mode: 0o700 });
  writeFileSync(join(scratch, 'fetch-stub.mjs'), fetchStub);
  const envPath = join(state, 'config/compose.env');
  if (env) writeFileSync(envPath, env(readFileSync(envPath, 'utf8')), { mode: 0o600 });
  const log = join(scratch, 'docker.log');
  const envLog = join(scratch, 'env.log');
  const fetchLog = join(scratch, 'fetch.log');
  for (const file of [log, envLog, fetchLog]) writeFileSync(file, '');
  const base = {
    ...process.env, PATH: `${bin}:${process.env.PATH}`, WAREHOUSE_STATE_DIR: state, FAKE_DOCKER_LOG: log, FAKE_ENV_LOG: envLog, FAKE_FETCH_LOG: fetchLog,
    FAKE_INSTANCE_ID: JSON.parse(readFileSync(join(state, 'public/instance.json'), 'utf8')).instanceId, WAREHOUSE_LAN_INTERFACES: INTERFACES,
    FAKE_PORTS: '127.0.0.1:18000->8000/tcp', FAKE_LAN_PORTS: '192.168.77.5:8080->8080/tcp', NODE_OPTIONS: `--import=${join(scratch, 'fetch-stub.mjs')}`,
  };
  delete base.COMPOSE_PROFILES;
  const lan = (args, extra = {}) => spawnSync('bash', [join(root, 'scripts/lan.sh'), ...args], { encoding: 'utf8', env: { ...base, ...extra }, timeout: 60000 });
  const compose = (args, extra = {}) => spawnSync('bash', [join(root, 'scripts/compose.sh'), ...args], { encoding: 'utf8', env: { ...base, ...extra }, timeout: 60000 });
  return { scratch, state, envPath, lan, compose, env: () => readFileSync(envPath, 'utf8'), calls: () => readFileSync(log, 'utf8'), profiles: () => readFileSync(envLog, 'utf8').trim().split('\n'), fetched: () => readFileSync(fetchLog, 'utf8').trim() };
}
const clean = f => rmSync(f.scratch, { recursive: true, force: true });

test('lan.sh on auto: writes the values, starts gateway-lan and the function runtime, checks it, and prints the address and the firewall line', () => {
  const f = fixture();
  try {
    const before = f.env();
    assert.match(before, /^LAN_ENABLED=false\b/m);
    assert.doesNotMatch(before, /^COMPOSE_PROFILES=/m);
    const run = f.lan(['on', 'auto']);
    assert.equal(run.status, 0, run.stderr + run.stdout);
    const env = readEnv(f.envPath);
    assert.deepEqual([env.LAN_ENABLED, env.LAN_BIND_IP, env.LAN_HTTP_PORT, env.LAN_CIDR, env.COMPOSE_PROFILES], ['true', '192.168.77.5', '8080', '192.168.77.0/24', 'lan']);
    assert.equal(statSync(f.envPath).mode & 0o777, 0o600);
    assert.equal(existsSync(`${f.envPath}.lan`) || existsSync(`${f.envPath}.lan-previous`), false, 'no staging file is left');
    // Everything else in the file is as it was.
    assert.equal(f.env().replace(/^LAN_[A-Z_]+=.*\n/gm, '').replace(/^COMPOSE_PROFILES=.*\n/m, ''), before.replace(/^LAN_[A-Z_]+=.*\n/gm, ''));
    assert.match(f.calls(), / --profile lan up -d --no-deps --wait --wait-timeout 180 gateway-lan functions$/m);
    // The answer: what an operator reads.
    const lines = run.stdout.split('\n');
    assert.ok(lines.includes('LAN fallback: 192.168.77.5:8080 on ens33, allowing 192.168.77.0/24'), run.stdout);
    assert.ok(lines.includes('LAN address for the app: http://192.168.77.5:8080'), run.stdout);
    assert.match(run.stdout, /sudo ufw route allow proto tcp from 192\.168\.77\.0\/24 to 192\.168\.77\.5 port 8080/);
    assert.match(run.stdout, /ufw does not filter Docker-published ports by default/);
    assert.match(run.stdout, /DHCP reservation/);
    // The doctor step probed the address with the fake fetch.
    assert.equal(f.fetched(), 'http://192.168.77.5:8080/functions/v1/get-public-config');
    assert.match(run.stdout, /The LAN fallback answers from this host as this installation\./);
    // Safe to repeat, and nothing grows.
    const again = f.lan(['on']);
    assert.equal(again.status, 0, again.stderr);
    assert.equal(f.env().match(/^COMPOSE_PROFILES=.*$/gm).length, 1);
    assert.equal(f.env().match(/^LAN_CIDR=.*$/gm).length, 1);
    // status: the same address line, the interface, the container.
    const status = f.lan(['status']);
    assert.equal(status.status, 0, status.stderr);
    assert.equal(status.stdout, 'LAN address for the app: http://192.168.77.5:8080\nAllowed clients: 192.168.77.0/24; published on 192.168.77.5:8080 only.\nInterface: ens33 has 192.168.77.5.\nContainer gateway-lan: running healthy\n');
  } finally { clean(f); }
});

test('lan.sh on with an address, a range and a port; other profiles in COMPOSE_PROFILES are kept, and off removes lan only', () => {
  const f = fixture({ env: text => `${text}COMPOSE_PROFILES=printing\n` });
  try {
    const run = f.lan(['on', '192.168.77.5', '--cidr', '192.168.0.0/16', '--port', '8181'], { FAKE_LAN_PORTS: '192.168.77.5:8181->8080/tcp' });
    assert.equal(run.status, 0, run.stderr + run.stdout);
    const env = readEnv(f.envPath);
    assert.deepEqual([env.LAN_BIND_IP, env.LAN_HTTP_PORT, env.LAN_CIDR, env.COMPOSE_PROFILES], ['192.168.77.5', '8181', '192.168.0.0/16', 'printing,lan']);
    assert.match(run.stdout, /LAN address for the app: http:\/\/192\.168\.77\.5:8181/);
    assert.match(run.stdout, /ufw route allow proto tcp from 192\.168\.0\.0\/16 to 192\.168\.77\.5 port 8181/);
    // A rerun without --port keeps 8181.
    assert.equal(f.lan(['on'], { FAKE_LAN_PORTS: '192.168.77.5:8181->8080/tcp' }).status, 0);
    assert.equal(readEnv(f.envPath).LAN_HTTP_PORT, '8181');
    // off
    const off = f.lan(['off']);
    assert.equal(off.status, 0, off.stderr);
    const after = readEnv(f.envPath);
    assert.deepEqual([after.LAN_ENABLED, after.LAN_BIND_IP, after.LAN_HTTP_PORT, after.LAN_CIDR, after.COMPOSE_PROFILES], ['false', '127.0.0.1', '8080', '', 'printing']);
    assert.match(f.calls(), / --profile lan rm -sf gateway-lan$/m);
    assert.match(f.calls(), / up -d --no-deps --wait --wait-timeout 180 functions$/m, 'the function runtime stops offering the address');
    assert.match(off.stdout, /The LAN fallback is off.*Phones that saved the address stop using it and keep working over the internet\./);
    assert.deepEqual(f.lan(['status']).stdout.trim().split('\n'), ['LAN fallback is off. Turn it on with: bash scripts/lan.sh on auto']);
  } finally { clean(f); }
});

test('lan.sh off with nothing else in COMPOSE_PROFILES removes the line, and does not start a stopped function runtime', () => {
  const f = fixture();
  try {
    assert.equal(f.lan(['on', 'auto']).status, 0);
    assert.match(f.env(), /^COMPOSE_PROFILES=lan$/m);
    const off = f.lan(['off'], { FAKE_STOPPED: 'yes' });
    assert.equal(off.status, 0, off.stderr);
    assert.doesNotMatch(f.env(), /^COMPOSE_PROFILES=/m);
    assert.match(f.env(), /^LAN_ENABLED=false$/m);
    // The calls of the off step: remove the container; no `up` of functions while it is stopped.
    const calls = f.calls().split('\n');
    const afterOn = calls.slice(calls.findIndex(line => / rm -sf gateway-lan$/.test(line)));
    assert.equal(afterOn.some(line => / up -d .*functions$/.test(line)), false);
  } finally { clean(f); }
});

test('lan.sh refuses before it changes anything: a public address, an address the host does not have, a range without the host, a stopped stack', () => {
  const f = fixture();
  try {
    const before = f.env();
    for (const [args, pattern, extra] of [
      [['on', '8.8.8.8'], /not a private IPv4 address/, {}],
      [['on', '192.168.77.99'], /not an address of this host \(it has 192\.168\.77\.5 on ens33, 172\.17\.0\.1 on docker0\)/, {}],
      [['on', '192.168.77.5', '--cidr', '192.168.5.0/24'], /does not contain the host's own address/, {}],
      [['on', '192.168.77.5', '--cidr', '0.0.0.0/0'], /not a private IPv4 range/, {}],
      [['on', '192.168.77.5', '--port', '80'], /1024 to 65535/, {}],
      [['on', 'auto'], /gateway service is not running/, { FAKE_STOPPED: 'yes' }],
      [['on', 'auto'], /no default route/, { WAREHOUSE_LAN_INTERFACES: JSON.stringify([{ name: 'ens33', address: '192.168.77.5', prefix: 24, defaultRoute: false }]) }],
      [['bogus'], /Usage: bash scripts\/lan\.sh/, {}],
      [[], /Usage: bash scripts\/lan\.sh/, {}],
      [['off', 'now'], /Usage: bash scripts\/lan\.sh/, {}],
    ]) {
      const run = f.lan(args, extra);
      assert.notEqual(run.status, 0, args.join(' '));
      assert.match(run.stderr, pattern, args.join(' '));
      assert.equal(f.env(), before, `${args.join(' ')} changed compose.env`);
    }
    assert.doesNotMatch(f.calls(), /\bup -d\b/, 'nothing was started');
    assert.equal(existsSync(`${f.envPath}.lan`), false);
  } finally { clean(f); }
});

test('lan.sh on: a gateway-lan that does not become healthy leaves compose.env as it was, removes the container and says so', () => {
  const f = fixture();
  try {
    const before = f.env();
    const run = f.lan(['on', 'auto'], { FAKE_FAIL_UP: 'yes' });
    assert.equal(run.status, 1);
    assert.match(run.stderr, /The LAN fallback was not turned on and config\/compose\.env is as it was\./);
    assert.equal(f.env(), before);
    assert.match(f.calls(), / --profile lan rm -sf gateway-lan$/m);
    assert.equal(existsSync(`${f.envPath}.lan-previous`), false);
  } finally { clean(f); }
});

test('lan.sh on: when the LAN check after the start fails it says so and stays on (the service runs; the operator fixes the cause)', () => {
  const f = fixture();
  try {
    const run = f.lan(['on', 'auto'], { FAKE_LAN_PORTS: '0.0.0.0:8080->8080/tcp' });
    assert.equal(run.status, 1);
    assert.match(run.stderr, /Doctor: LAN fallback: gateway-lan is published on 0\.0\.0\.0:8080, not only on 192\.168\.77\.5:8080/);
    assert.match(run.stderr, /The LAN fallback is on, but a check above failed\. Fix it, then run: node scripts\/doctor\.mjs --lan/);
    assert.equal(readEnv(f.envPath).LAN_ENABLED, 'true');
  } finally { clean(f); }
});

test('compose.sh leaves the lan profile out of a command when the host no longer has the address, and only then', () => {
  const f = fixture();
  try {
    assert.equal(f.lan(['on', 'auto']).status, 0);
    const ps = args => { const run = f.compose(args); assert.equal(run.status, 0, run.stderr); return run; };
    // The address is there: the profile in compose.env decides, nothing is overridden.
    ps(['ps', '-q']);
    assert.equal(f.profiles().at(-1), '');
    // The router gave the host another address: the profile is left out of this command, with the reason on stderr.
    const moved = JSON.stringify([{ name: 'ens33', address: '192.168.77.9', prefix: 24, defaultRoute: true }]);
    const run = f.compose(['ps', '-q'], { WAREHOUSE_LAN_INTERFACES: moved });
    assert.equal(run.status, 0, run.stderr);
    assert.match(run.stderr, /LAN fallback: this host no longer has 192\.168\.77\.5, so the gateway-lan service is left out of this command \(the public gateway is not affected\)\. Run: bash scripts\/lan\.sh on auto/);
    assert.equal(f.profiles().at(-1), 'profiles=', 'COMPOSE_PROFILES is set, and empty');
    // With another profile listed, that one stays.
    writeFileSync(f.envPath, f.env().replace(/^COMPOSE_PROFILES=.*$/m, 'COMPOSE_PROFILES=printing,lan'), { mode: 0o600 });
    f.compose(['ps', '-q'], { WAREHOUSE_LAN_INTERFACES: moved });
    assert.equal(f.profiles().at(-1), 'profiles=printing');
    // An address that is not private (hand-edited compose.env) is never published, even though the host has it.
    writeFileSync(f.envPath, f.env().replace(/^LAN_BIND_IP=.*$/m, 'LAN_BIND_IP=0.0.0.0'), { mode: 0o600 });
    const wide = f.compose(['ps', '-q']);
    assert.match(wide.stderr, /LAN fallback: LAN_BIND_IP is "0\.0\.0\.0", which is not a private IPv4 address, so the gateway-lan service is left out of this command/);
    assert.equal(f.profiles().at(-1), 'profiles=printing');
    // A state that never used the fallback: no override, no node call.
    const none = fixture();
    try {
      const plain = none.compose(['ps', '-q'], { WAREHOUSE_LAN_INTERFACES: moved });
      assert.equal(plain.stderr, '');
      assert.equal(none.profiles().at(-1), '');
    } finally { clean(none); }
  } finally { clean(f); }
});

test('a rerun of configure keeps every LAN line and the profile exactly as lan.sh wrote them', () => {
  const f = fixture();
  try {
    assert.equal(f.lan(['on', 'auto']).status, 0);
    const lines = text => text.split('\n').filter(line => /^(?:LAN_|COMPOSE_PROFILES)/.test(line));
    const written = lines(f.env());
    assert.deepEqual(written, ['LAN_ENABLED=true', 'LAN_BIND_IP=192.168.77.5', 'LAN_HTTP_PORT=8080', 'LAN_CIDR=192.168.77.0/24', 'COMPOSE_PROFILES=lan']);
    const result = configure(root, { stateDir: f.state });
    assert.equal(result.created, false);
    assert.deepEqual(lines(f.env()), written);
    // Also while changing something else the rerun may change.
    configure(root, { stateDir: f.state, gatewayPort: '18123', containersRunning: () => false, portFree: () => true });
    assert.deepEqual(lines(f.env()), written);
    assert.match(f.env(), /^GATEWAY_HTTP_PORT=18123$/m);
  } finally { clean(f); }
});

test('a new state has the LAN block of .env.example: off, loopback, 8080, no range, no profile', () => {
  const f = fixture();
  try {
    const env = readEnv(f.envPath);
    assert.deepEqual([env.LAN_ENABLED, env.LAN_BIND_IP, env.LAN_HTTP_PORT, env.LAN_CIDR, env.COMPOSE_PROFILES], ['false', '127.0.0.1', '8080', '', undefined]);
    assert.equal(readFileSync(join(root, '.env.example'), 'utf8').match(/^LAN_CIDR=.*$/m)[0], 'LAN_CIDR=', 'no comment after the empty value');
  } finally { clean(f); }
});
