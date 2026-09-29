import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

function gate(name, type = 'tag') {
  const result = spawnSync('bash', ['scripts/check-release.sh'], {
    cwd: fileURLToPath(new URL('..', import.meta.url)),
    env: { ...process.env, GITHUB_REF_NAME: name, GITHUB_REF_TYPE: type },
    encoding: 'utf8',
  });
  return result;
}
test('current operator branch does not approve the historical demo tag', () => {
  const result = gate('v0.2.2-demo');
  assert.notEqual(result.status, 0);
  assert.match(result.stdout + result.stderr, /No operator release tag is approved/);
});
test('production and unreviewed demo tags remain gated', () => {
  for (const name of ['v0.2.1-demo', 'v0.2.0-demo', 'v0.2.2', 'v1.0.0', 'v0.3.0-demo', '']) {
    assert.notEqual(gate(name).status, 0);
  }
});
test('a branch with the demo name cannot authorize a release', () => {
  assert.notEqual(gate('v0.2.2-demo', 'branch').status, 0);
});
