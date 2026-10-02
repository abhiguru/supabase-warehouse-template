import test from 'node:test';
import assert from 'node:assert/strict';
import { createServer } from 'node:net';
import { mkdtempSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';
import { serviceSpec, portListening } from '../scripts/fixture-service-supervisor.mjs';

const config = { scope: 'isolated-fictional-fixture', runId: 'diagnostic-1', node: '/opt/node/bin/node', logDir: '/private/logs' };
const service = { kind: 'core', checkout: "/private/fixture's checkout", state: '/private/core-backend-test-1', tlsDir: '/private/tls', socketPath: '/private/otp.sock' };
test('long-lived fixture helpers use independent user supervision without hidden restart', () => {
  const s = serviceSpec(config, service);
  assert.equal(s.unit, 'warehouse-fixture-core-diagnostic-1.service');
  assert.ok(s.content.includes('KillMode=control-group\n'));
  assert.ok(s.content.includes('UMask=0077\n'));
  assert.ok(s.content.includes("'\\\\''"));
  assert.equal(s.port, 18443);
  assert.ok(s.content.includes('Restart=no\n'));
  assert.ok(s.content.includes('RuntimeMaxSec=43200\n'));
  assert.ok(!s.content.includes('[Install]'));
  assert.ok(s.content.includes('ExecStart='));
  assert.ok(s.content.includes('StandardError=append:' + s.log + '\n'));
  assert.equal(serviceSpec(config, { ...service, kind: 'switch' }).port, 18444);
  assert.ok(serviceSpec(config, { ...service, kind: 'switch' }).content.includes('Environment="WAREHOUSE_SWITCH_FIXTURE_SOCKET=' + service.socketPath + '"'));
  assert.ok(serviceSpec(config, { ...service, kind: 'switch' }).content.includes('Environment="WAREHOUSE_SWITCH_FIXTURE_TLS_DIR=' + service.tlsDir + '"'));
  assert.equal(serviceSpec(config, { ...service, kind: 'fault' }).port, 18643);
});
test('generated unit is accepted by systemd, including a checkout path with spaces', () => {
  const directory = mkdtempSync(join(tmpdir(), 'fixture-supervisor-unit-'));
  const spec = serviceSpec(config, service);
  const file = join(directory, spec.unit);
  try {
    writeFileSync(file, spec.content);
    const r = spawnSync('systemd-analyze', ['verify', file], { encoding: 'utf8' });
    assert.equal(r.status, 0, r.stderr);
  } finally { rmSync(directory, { recursive: true, force: true }); }
});
test('unit names and helpers cannot inject arbitrary system services or commands', () => {
  for (const runId of ['../production', 'test.service\nRestart=always', ''])
    assert.throws(() => serviceSpec({ ...config, runId }, service));
  assert.throws(() => serviceSpec(config, { ...service, kind: 'production' }));
  assert.throws(() => serviceSpec({ ...config, scope: 'installed-warehouse' }, service));
  assert.throws(() => serviceSpec(config, { ...service, socketPath: '/private/otp\nfile' }));
});
test('listener health distinguishes an absent loopback server without replacing it', async () => {
  const server = createServer(s => s.end());
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  const port = server.address().port;
  try { assert.equal(await portListening(port), true); }
  finally { await new Promise(resolve => server.close(resolve)); }
  assert.equal(await portListening(port), false);
});
test('replacement and header-presence options are explicit core-only booleans',()=>{
 const original=serviceSpec(config,service);assert.ok(!original.content.includes('WAREHOUSE_FIXTURE_REPLACEMENT_AUTH'));assert.ok(!original.content.includes('WAREHOUSE_FIXTURE_OBSERVE_AUTH_PRESENCE'));
 const s=serviceSpec(config,{...service,observeAuthenticationPresence:true,replacementAuthentication:true});assert.ok(s.content.includes('WAREHOUSE_FIXTURE_OBSERVE_AUTH_PRESENCE=true'));assert.ok(s.content.includes('WAREHOUSE_FIXTURE_REPLACEMENT_AUTH=true'));assert.ok(s.content.includes('RuntimeMaxSec=43200\n'));
 for(const option of ['observeAuthenticationPresence','replacementAuthentication']){assert.throws(()=>serviceSpec(config,{...service,[option]:'true'}));assert.throws(()=>serviceSpec(config,{...service,kind:'switch',[option]:true}));assert.throws(()=>serviceSpec(config,{...service,kind:'fault',[option]:true}));}
});
test('separate helper source keeps a hash-bound original checkout ownership guard',()=>{
 const s=serviceSpec(config,{...service,owningCheckout:'/private/original-core',ownerGuardSHA256:'a'.repeat(64)});assert.equal(s.guard,'/private/original-core/tests/operator-fixture.mjs');assert.ok(s.content.includes('WAREHOUSE_FIXTURE_OWNING_CHECKOUT=/private/original-core'));assert.ok(s.content.includes('WAREHOUSE_FIXTURE_OWNER_GUARD_SHA256='+'a'.repeat(64)));
 assert.throws(()=>serviceSpec(config,{...service,owningCheckout:'/private/core'}));assert.throws(()=>serviceSpec(config,{...service,ownerGuardSHA256:'a'.repeat(64)}));assert.throws(()=>serviceSpec(config,{...service,kind:'fault',owningCheckout:'/private/core',ownerGuardSHA256:'a'.repeat(64)}));
});
test('discovery delay is explicit switching-only and retains the twelve-hour service cap',()=>{
 const s=serviceSpec(config,{...service,kind:'switch',discoveryDelayMs:3000});assert.ok(s.content.includes('WAREHOUSE_SWITCH_FIXTURE_DISCOVERY_DELAY_MS=3000'));assert.ok(s.content.includes('RuntimeMaxSec=43200\n'));assert.ok(!serviceSpec(config,{...service,kind:'switch'}).content.includes('DISCOVERY_DELAY'));
 for(const kind of ['core','fault'])assert.throws(()=>serviceSpec(config,{...service,kind,discoveryDelayMs:3000}));
 for(const value of [0,499,5001,'3000',3.5])assert.throws(()=>serviceSpec(config,{...service,kind:'switch',discoveryDelayMs:value}));
});

test('fresh switching helper keeps the hash-bound original switching container guard',()=>{
 const spec=serviceSpec(config,{...service,kind:'switch',owningCheckout:'/private/original-switch',ownerGuardSHA256:'b'.repeat(64),discoveryDelayMs:3000});
 assert.equal(spec.guard,'/private/original-switch/scripts/switch-fixture-common.mjs');assert.equal(spec.validator,'switchingFixture');
 assert.ok(spec.content.includes('WAREHOUSE_FIXTURE_OWNER_GUARD_SHA256='+'b'.repeat(64)));assert.ok(spec.content.includes('WAREHOUSE_FIXTURE_OWNING_CHECKOUT=/private/original-switch'));assert.ok(spec.content.includes('RuntimeMaxSec=43200\n'));
 for(const value of ['','not-a-hash'])assert.throws(()=>serviceSpec(config,{...service,kind:'switch',owningCheckout:'/private/switch',ownerGuardSHA256:value}));
});
