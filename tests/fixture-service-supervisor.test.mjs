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
