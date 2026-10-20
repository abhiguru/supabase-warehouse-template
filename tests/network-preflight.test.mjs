import test from 'node:test';
import assert from 'node:assert/strict';
import { chmodSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

const root = new URL('..', import.meta.url).pathname.replace(/\/$/, '');
const read = path => readFileSync(join(root, path), 'utf8');

// A fake `docker` that creates or refuses the throwaway network.
function preflight({ createFails = false, leftover = false } = {}) {
  const scratch = mkdtempSync(join(tmpdir(), 'network-preflight-'));
  try {
    mkdirSync(join(scratch, 'state/config'), { recursive: true });
    mkdirSync(join(scratch, 'bin'));
    writeFileSync(join(scratch, 'state/config/compose.env'), 'WAREHOUSE_PROJECT_NAME=warehouse-upgrade-test\n');
    writeFileSync(join(scratch, 'bin/docker'), `#!/usr/bin/env bash
echo "$*" >> "${scratch}/calls"
case "$1 $2" in
  "network inspect") ${leftover ? 'echo warehouse-upgrade-test' : 'exit 1'} ;;
  "network create") ${createFails ? 'exit 1' : 'exit 0'} ;;
  "network rm") exit 0 ;;
esac
`);
    chmodSync(join(scratch, 'bin/docker'), 0o755);
    const result = spawnSync('bash', [join(root, 'scripts/network-preflight.sh')], {
      encoding: 'utf8', env: { ...process.env, PATH: `${scratch}/bin:${process.env.PATH}`, WAREHOUSE_STATE_DIR: join(scratch, 'state') },
    });
    let calls = '';
    try { calls = readFileSync(join(scratch, 'calls'), 'utf8'); } catch { /* none */ }
    return { ...result, calls };
  } finally { rmSync(scratch, { recursive: true, force: true }); }
}

test('the address-pool preflight creates and removes an internal, labelled network of the project', () => {
  const ok = preflight();
  assert.equal(ok.status, 0, ok.stderr);
  assert.match(ok.calls, /^network create --internal --label warehouse\.preflight=warehouse-upgrade-test warehouse-upgrade-test_netcheck$/m);
  assert.match(ok.calls, /^network rm warehouse-upgrade-test_netcheck$/m);
  const stale = preflight({ leftover: true });
  assert.equal(stale.status, 0);
  assert.ok(stale.calls.indexOf('network rm') < stale.calls.indexOf('network create'), 'a leftover check network of this project is removed first');
});

test('the preflight aborts with a clear message when Docker cannot allocate a subnet, before touching anything else', () => {
  const failed = preflight({ createFails: true });
  assert.notEqual(failed.status, 0);
  assert.match(failed.stderr, /Docker cannot create a network for warehouse-upgrade-test: no free address pool/);
  assert.match(failed.stderr, /nothing was changed/);
  assert.doesNotMatch(failed.calls, /^(?:rm|ps|image)/m);
});

test('the network preflight runs before anything is built or started, and stop.sh stops every profile', () => {
  for (const name of ['setup.sh', 'start.sh']) {
    const code = read(name).split('\n').map((line, index) => [line, index]).filter(([line]) => !line.startsWith('#'));
    const preflight = code.find(([line]) => line === 'bash "$ROOT/scripts/network-preflight.sh"');
    assert.ok(preflight, `${name}: calls the network preflight`);
    const firstChange = code.find(([line]) => /compose\.sh" up|build-images\.sh"|migrate\.sh/.test(line));
    assert.ok(preflight[1] < firstChange[1], `${name}: the network preflight runs before anything is built or started`);
  }
  assert.match(read('stop.sh'), /^bash "\$ROOT\/scripts\/compose\.sh" --profile '\*' down --remove-orphans$/m);
});
