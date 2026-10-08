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
const validTags = [
  'v0.3.0', 'v1.2.3', 'v10.20.30', 'v0.3.0-rc.1', 'v0.3.0-demo', 'v1.0.0-alpha',
  'v1.0.0+build.7', 'v1.0.0-beta.2+exp.sha.5114f85', 'v2.0.0-0.3.7', 'v1.2.3-x-y-z.--',
];
const invalidTags = [
  '', 'v', 'v1', 'v1.2', '1.2.3', 'V1.2.3', 'v1.2.3.', 'v1.2.3.4', 'v1.2.3-', 'v1.2.3+',
  'v1.2.3-rc_1', 'v1.2.3 ', ' v1.2.3', 'v1.2.3\n', 'v1.2.3-rc.1/extra', 'release-1.2.3',
  'v1.2.3-rc.1;echo', 'va.b.c', 'v1.2.3-ä',
];
test('semantic version tags pass the release gate', () => {
  for (const name of validTags) {
    const result = gate(name);
    assert.equal(result.status, 0, `${JSON.stringify(name)} should be accepted: ${result.stderr}`);
    assert.match(result.stdout, /valid semantic version/);
  }
});
test('nonconforming tag names are refused with a clear message', () => {
  for (const name of invalidTags) {
    const result = gate(name);
    assert.notEqual(result.status, 0, `${JSON.stringify(name)} should be refused`);
    assert.match(result.stderr, /^Release gate: refusing tag '[\s\S]*'\. Expected vMAJOR\.MINOR\.PATCH/);
    assert.equal(result.stdout, '');
  }
});
test('a branch cannot authorize a release even with a semantic name', () => {
  for (const [name, type] of [['v0.3.0', 'branch'], ['v0.3.0-rc.1', 'branch'], ['main', 'branch'], ['v0.3.0', ''], ['v0.3.0', 'Tag']]) {
    const result = gate(name, type);
    assert.notEqual(result.status, 0, `${name} as ${JSON.stringify(type)} should be refused`);
    assert.match(result.stderr, /Release gate: refusing .*Only semantic version tags/);
  }
});
