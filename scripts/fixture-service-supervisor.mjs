import { coreFixtureTlsPort } from './fixture-core-tls-port.mjs';
// Optional fixture infrastructure only. Never loaded by ordinary installation.
// Private configuration is trusted executable input, like the fixture test plan.
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { lstatSync, readFileSync, realpathSync, existsSync, openSync, closeSync } from 'node:fs';
import { resolve, isAbsolute } from 'node:path';
import { spawnSync } from 'node:child_process';
import { createConnection } from 'node:net';
import { pathToFileURL } from 'node:url';
import { homedir } from 'node:os';
import { mkdirSync, writeFileSync } from 'node:fs';
import { isMain } from './is-main.mjs';
import { dispatchConcurrencyDelayMilliseconds } from './fixture-dispatch-concurrency-delay.mjs';

const helpers = {
  core: ['scripts/emulator-fixture-bridge.mjs', 'tests/operator-fixture.mjs', 'operatorFixture', 18443, 'WAREHOUSE_FIXTURE_SOCKET'],
  switch: ['scripts/switch-fixture-bridge.mjs', 'scripts/switch-fixture-common.mjs', 'switchingFixture', 18444, 'WAREHOUSE_SWITCH_FIXTURE_SOCKET'],
  fault: ['scripts/fixture-fault-relay.mjs', 'tests/operator-fixture.mjs', 'operatorFixture', 18643, 'WAREHOUSE_FIXTURE_FAULT_SOCKET'],
};
let phase = 'CONFIGURATION';
const quote = value => "'" + value.replaceAll("'", "'\\''") + "'";
const unitQuote = (value, executable = false) => '"' + value.replaceAll('\\', '\\\\').replaceAll('"', '\\"').replaceAll('%', '%%').replaceAll('$', executable ? '$$' : '$') + '"';
function absolute(value) {
  assert.ok(typeof value === 'string' && isAbsolute(value) && !/[\r\n\0]/.test(value), 'Absolute single-line path required');
  return value;
}
function ownedPrivate(path, directory = false) {
  absolute(path);
  const s = lstatSync(path);
  assert.ok(!s.isSymbolicLink() && s.uid === process.getuid() && (s.mode & 0o077) === 0 &&
    (directory ? s.isDirectory() : s.isFile()), 'Owned private path required');
  assert.equal(realpathSync(path), resolve(path), 'Private path must not traverse symlinks');
}
export function serviceSpec(config, service) {
  assert.equal(config.scope, 'isolated-fictional-fixture');
  assert.match(config.runId, /^[a-z0-9][a-z0-9-]{0,39}$/);
  assert.ok(Object.hasOwn(helpers, service.kind), 'Only declared fixture helpers allowed');
  for (const key of ['checkout', 'state', 'tlsDir', 'socketPath']) absolute(service[key]);
  // Linux pathname sockets reserve one of sun_path's 108 bytes for NUL.
  // Refuse before fixture guards or any unit/listener creation.
  assert.ok(Buffer.byteLength(service.socketPath, 'utf8') <= 107, 'Fixture IPC pathname exceeds Linux 107-byte limit');
  absolute(config.node); absolute(config.logDir);
  for (const option of ['observeAuthenticationPresence','replacementAuthentication']) {
    if (Object.hasOwn(service,option)) {
      assert.equal(typeof service[option],'boolean','Fixture options require booleans');
      assert.ok(option==='observeAuthenticationPresence' ? ['core','switch'].includes(service.kind) : service.kind==='core','Fictional bridge option kind refused');
    }
  }
  if(Object.hasOwn(service,'confirmedOrdersReadDelayMs')){assert.equal(service.kind,'core');assert.equal(service.confirmedOrdersReadDelayMs,30000);assert.equal(service.observeAuthenticationPresence,true);assert.notEqual(service.replacementAuthentication,true);for(const key of ['ordersReadDelayMs','dispatchConcurrency','discoveryDelayMs'])assert.ok(!Object.hasOwn(service,key),'INDEPENDENT_CONFIRMED_READ_HELPER_REQUIRED');}
  if(Object.hasOwn(service,'ordersReadDelayMs')){assert.equal(service.kind,'core');assert.ok(Number.isInteger(service.ordersReadDelayMs)&&service.ordersReadDelayMs>=500&&service.ordersReadDelayMs<=5000,'Bounded core Orders read delay only');assert.notEqual(service.replacementAuthentication,true);}
  if(Object.hasOwn(service,'dispatchConcurrency')){assert.equal(service.kind,'core');assert.notEqual(service.replacementAuthentication,true);assert.ok(!Object.hasOwn(service,'ordersReadDelayMs'),'Independent concurrency helper required');assert.ok(service.dispatchConcurrency.milliseconds>0);dispatchConcurrencyDelayMilliseconds({},{},null,service.dispatchConcurrency);}
  if(Object.hasOwn(service,'discoveryDelayMs')){assert.equal(service.kind,'switch');assert.ok(Number.isInteger(service.discoveryDelayMs)&&service.discoveryDelayMs>=500&&service.discoveryDelayMs<=5000,'Bounded switching discovery delay only');}
  if (Object.hasOwn(service,'owningCheckout')) {
    assert.ok(['core','switch'].includes(service.kind),'Only core/switch hash-bound helper ownership'); absolute(service.owningCheckout);
    assert.match(service.ownerGuardSHA256,/^[a-f0-9]{64}$/);
  } else assert.ok(!Object.hasOwn(service,'ownerGuardSHA256'));
  const [helper, guard, validator, defaultPort, socketVariable] = helpers[service.kind];
  let port = defaultPort;
  if (Object.hasOwn(service, 'tlsPort')) {
    assert.equal(service.kind, 'core');
    assert.equal(service.tlsPort, 19543);
    assert.ok(service.owningCheckout, 'Independent TLS listener requires hash-bound fixture ownership');
    port = coreFixtureTlsPort(service.tlsPort);
  }
  const unit = `warehouse-fixture-${service.kind}-${config.runId}.service`;
  const log = resolve(config.logDir, unit + '.log');
  const command = [config.node, resolve(service.checkout, helper)].map(quote).join(' ');
  const variables = [
    'PATH=' + resolve(config.node, '..') + ':' + process.env.PATH,
    'WAREHOUSE_STATE_DIR=' + service.state,
    (service.kind === 'switch' ? 'WAREHOUSE_SWITCH_FIXTURE_TLS_DIR' : 'WAREHOUSE_FIXTURE_TLS_DIR') + '=' + service.tlsDir,
    socketVariable + '=' + service.socketPath,
  ];
  if (Object.hasOwn(service, 'tlsPort')) variables.push('WAREHOUSE_FIXTURE_TLS_PORT=' + port);
  if (service.owningCheckout) {
    variables.push('WAREHOUSE_FIXTURE_OWNING_CHECKOUT='+service.owningCheckout);
    variables.push('WAREHOUSE_FIXTURE_OWNER_GUARD_SHA256='+service.ownerGuardSHA256);
  }
  if(Object.hasOwn(service,'confirmedOrdersReadDelayMs'))variables.push('WAREHOUSE_FIXTURE_CONFIRMED_ORDERS_READ_DELAY_MS='+service.confirmedOrdersReadDelayMs);
  if(Object.hasOwn(service,'ordersReadDelayMs'))variables.push('WAREHOUSE_FIXTURE_ORDERS_READ_DELAY_MS='+service.ordersReadDelayMs);
  if(Object.hasOwn(service,'dispatchConcurrency'))variables.push('WAREHOUSE_FIXTURE_DISPATCH_CONCURRENCY='+JSON.stringify(service.dispatchConcurrency));
  if(Object.hasOwn(service,'discoveryDelayMs'))variables.push('WAREHOUSE_SWITCH_FIXTURE_DISCOVERY_DELAY_MS='+service.discoveryDelayMs);
  if (service.observeAuthenticationPresence === true) variables.push('WAREHOUSE_FIXTURE_OBSERVE_AUTH_PRESENCE=true');
  if (service.replacementAuthentication === true) variables.push('WAREHOUSE_FIXTURE_REPLACEMENT_AUTH=true');
  const content = '[Unit]\nDescription=Owned fictional fixture ' + service.kind + '\n\n[Service]\n' +
    'Type=exec\nRestart=no\nUMask=0077\nKillMode=control-group\nTimeoutStopSec=20\nRuntimeMaxSec=43200\n' +
    'WorkingDirectory=' + service.checkout.replaceAll('%', '%%') + '\n' +
    variables.map(v => 'Environment=' + unitQuote(v)).join('\n') + '\n' +
    'StandardOutput=append:' + log.replaceAll('%', '%%') + '\nStandardError=append:' + log.replaceAll('%', '%%') + '\n' +
    'ExecStart=' + ['/usr/bin/sg', 'docker', '-c', command].map(v => unitQuote(v, true)).join(' ') + '\n';
  return { unit, log, port, guard: resolve(service.owningCheckout || service.checkout, guard), validator, content };
}
function command(program, args) {
  const r = spawnSync(program, args, { encoding: 'utf8', timeout: 45000, maxBuffer: 8 * 1024 * 1024 });
  assert.equal(r.status, 0, 'Owned infrastructure command failed; inspect protected logs');
  return r.stdout;
}
export async function portListening(port) {
  return new Promise(resolveResult => {
    const connection = createConnection({ host: '127.0.0.1', port });
    let done = false;
    const finish = value => { if (done) return; done = true; connection.destroy(); resolveResult(value); };
    connection.setTimeout(2000, () => finish(false));
    connection.once('connect', () => finish(true)); connection.once('error', () => finish(false));
  });
}
async function main(path, action) {
  process.umask(0o077);
  assert.ok(['start', 'status', 'stop'].includes(action));
  ownedPrivate(path); ownedPrivate(resolve(path, '..'), true);
  const c = JSON.parse(readFileSync(path));
  ownedPrivate(c.logDir, true);
  assert.ok(Array.isArray(c.services) && c.services.length > 0 && c.services.length <= 3);
  assert.equal(new Set(c.services.map(x => x.kind)).size, c.services.length);
  const specs = [];
  // Validate every owning checkout before starting or stopping any service.
  for (const s of c.services) {
    phase = 'OWNING_FIXTURE_GUARD';
    const spec = serviceSpec(c, s);
    ownedPrivate(s.state, true); ownedPrivate(s.tlsDir, true);
    ownedPrivate(resolve(s.socketPath, '..'), true);
    if (s.owningCheckout) {
      assert.equal(realpathSync(s.owningCheckout),resolve(s.owningCheckout));
      const st=lstatSync(spec.guard); assert.ok(st.isFile()&&!st.isSymbolicLink()&&st.uid===process.getuid());
      assert.equal(createHash('sha256').update(readFileSync(spec.guard)).digest('hex'),s.ownerGuardSHA256,'Original owning fixture guard changed');
    }
    const guard = `import {${spec.validator}} from ${JSON.stringify(pathToFileURL(spec.guard).href)}; ${spec.validator}();`;
    const r = spawnSync(c.node, ['--input-type=module', '-e', guard], {
      cwd: s.checkout, env: { ...process.env, WAREHOUSE_STATE_DIR: s.state },
      encoding: 'utf8', timeout: 45000,
    });
    assert.equal(r.status, 0, 'Original owning fixture guard refused; output suppressed');
    specs.push(spec);
  }
  if (action === 'start') {
    phase = 'OCCUPANCY_AND_EVIDENCE_GUARD';
    for (const [i, spec] of specs.entries()) {
      assert.ok(!existsSync(c.services[i].socketPath), 'Occupied IPC path; inspect and explicitly clean only proven stale owned sockets');
      assert.ok(!await portListening(spec.port), 'Occupied fixture port; no existing listener replaced');
      const r = spawnSync('systemctl', ['--user', 'show', spec.unit, '--property=LoadState', '--value'], { encoding: 'utf8' });
      assert.ok(r.stdout.trim() === 'not-found', 'Use a new unit identity; no unit overwritten');
      assert.ok(!existsSync(spec.log), 'Never overwrite infrastructure evidence');
    }
    for (const spec of specs) {
      phase = 'PRIVATE_UNIT_CREATION';
      closeSync(openSync(spec.log, 'wx', 0o600));
      const unitDirectory = resolve(homedir(), '.config/systemd/user');
      mkdirSync(unitDirectory, { recursive: true });
      const directory = lstatSync(unitDirectory);
      assert.ok(directory.isDirectory() && !directory.isSymbolicLink() && directory.uid === process.getuid());
      writeFileSync(resolve(unitDirectory, spec.unit), spec.content, { flag: 'wx', mode: 0o600 });
      phase = 'SYSTEMD_UNIT_VERIFICATION';
      command('systemd-analyze', ['--user', 'verify', resolve(unitDirectory, spec.unit)]);
      phase = 'SYSTEMD_START';
      command('systemctl', ['--user', 'daemon-reload']);
      command('systemctl', ['--user', 'start', spec.unit]);
      console.log(JSON.stringify({ unit: spec.unit, log: spec.log }));
      phase = 'LISTENER_READINESS';
      const deadline = Date.now() + 20000;
      while (!await portListening(spec.port) && Date.now() < deadline) await new Promise(r => setTimeout(r, 200));
      assert.ok(await portListening(spec.port), 'Supervised helper did not become ready; preserve its unit/log');
    }
  }
  phase = 'OWNED_UNIT_STATUS_OR_STOP';
  if (action === 'stop') for (const spec of [...specs].reverse()) command('systemctl', ['--user', 'stop', spec.unit]);
  for (const spec of specs) {
    const info = command('systemctl', ['--user', 'show', spec.unit, '--property=ActiveState,SubState,MainPID,Result,NRestarts']);
    console.log(JSON.stringify({ unit: spec.unit, listenerPresent: await portListening(spec.port), properties: info.trim().split('\n') }));
  }
}
if (isMain(import.meta.url)) main(process.argv[2], process.argv[3]).catch(() => {
  console.error(JSON.stringify({ status: 'FAIL', phase, message: 'Inspect protected configuration, generated unit and logs. No automatic restart or socket replacement.' }));
  process.exitCode = 1;
});
