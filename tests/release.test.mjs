import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import test from 'node:test';

function gate(name, type = 'tag') {
  const result = spawnSync('bash', ['scripts/check-release.sh'], {
    cwd: new URL('..', import.meta.url),
    env: { ...process.env, GITHUB_REF_NAME: name, GITHUB_REF_TYPE: type },
    encoding: 'utf8',
  });
  if (result.error) throw result.error;
  return result;
}
test('allows exactly the reviewed source-demo tag', () => {
  const result = gate('v0.2.0-demo');
  assert.equal(result.status, 0);
  assert.match(result.stdout + result.stderr, /Source-only prerelease/);
});
test('production and unreviewed demo tags remain gated', () => {
  for (const name of ['v0.2.0', 'v1.0.0', 'v0.3.0-demo', '']) {
    assert.notEqual(gate(name).status, 0);
  }
});
test('a branch with the demo name cannot authorize a release', () => {
  assert.notEqual(gate('v0.2.0-demo', 'branch').status, 0);
});
