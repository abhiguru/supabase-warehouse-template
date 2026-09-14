import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, cpSync, writeFileSync, readFileSync, existsSync, statSync, rmSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { createServer } from 'node:net';
import { listening } from '../scripts/doctor.mjs';

function fixture() {
  const root = mkdtempSync(join(tmpdir(), 'warehouse-setup-failure-'));
  mkdirSync(join(root, 'docker')); mkdirSync(join(root, 'bin'));
  for (const path of ['scripts', 'setup.sh', '.env.example']) cpSync(new URL(`../${path}`, import.meta.url), join(root, path), { recursive: true });
  const bin = join(root, 'bin');
  writeFileSync(join(bin, 'docker'), `#!/bin/bash
if [[ "$1" == info || "$1 $2" == 'compose version' ]]; then exit 0; fi
if [[ "$1" == ps ]]; then if [[ "\${FOREIGN_OWNER:-}" == yes ]]; then echo fake-id; fi; exit 0; fi
if [[ "$1" == inspect ]]; then echo /another/checkout/docker; exit 0; fi
if [[ "$*" == *' up '* ]]; then exit 42; fi
exit 0
`, { mode: 0o700 });
  return { root, env: { ...process.env, PATH: `${bin}:${process.env.PATH}`, WAREHOUSE_PROJECT_NAME: 'warehouse-failure-fixture' } };
}

test('setup refuses missing --demo before generating configuration', () => {
  const { root, env } = fixture();
  try {
    const result = spawnSync('bash', [join(root, 'setup.sh')], { env });
    assert.notEqual(result.status, 0);
    assert.equal(existsSync(join(root, 'docker/.env')), false);
  } finally { rmSync(root, { recursive: true }); }
});
test('startup failure preserves generated configuration and rerun bytes/mode', () => {
  const { root, env } = fixture();
  try {
    // Fresh fixture chooses unallocated ports; fake Docker never starts services.
    const template = readFileSync(join(root, '.env.example'), 'utf8').replace(/18000/g, '38000').replace(/18443/g, '38443').replace(/54325/g, '58325').replace(/15433/g, '35433').replace(/13100/g, '33100');
    writeFileSync(join(root, '.env.example'), template);
    const run = () => spawnSync('bash', [join(root, 'setup.sh'), '--demo'], { env });
    assert.equal(run().status, 42);
    const bytes = readFileSync(join(root, 'docker/.env'));
    assert.equal(run().status, 42);
    assert.deepEqual(readFileSync(join(root, 'docker/.env')), bytes);
    assert.equal(statSync(join(root, 'docker/.env')).mode & 0o777, 0o600);
    const foreign = spawnSync('bash', [join(root, 'scripts/compose.sh'), 'up', '-d'], { env: { ...env, FOREIGN_OWNER: 'yes' }, encoding: 'utf8' });
    assert.notEqual(foreign.status, 0);
    assert.match(foreign.stderr, /belongs to another checkout/);
  } finally { rmSync(root, { recursive: true }); }
});
test('connectivity probe detects an occupied loopback port without changing the listener', async () => {
  const server = createServer(socket => socket.end());
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  try { assert.equal(await listening(server.address().port), true); assert.equal(server.listening, true); }
  finally { await new Promise(resolve => server.close(resolve)); }
});
