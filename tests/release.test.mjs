import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
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

// The second half of the gate: what the release must contain for upgrade.sh (scripts/check-release-contents.sh).
function contents(tag, files) {
  const root = mkdtempSync(join(tmpdir(), 'warehouse-release-contents-'));
  try {
    for (const [path, text] of Object.entries(files)) {
      mkdirSync(dirname(join(root, path)), { recursive: true });
      writeFileSync(join(root, path), text);
    }
    return spawnSync('bash', ['scripts/check-release-contents.sh'], {
      cwd: fileURLToPath(new URL('..', import.meta.url)),
      env: { ...process.env, GITHUB_REF_NAME: tag, RELEASE_CONTENTS_ROOT: root },
      encoding: 'utf8',
    });
  } finally { rmSync(root, { recursive: true, force: true }); }
}
const releaseFiles = {
  'CHANGELOG.md': '# Changelog\n\n## Unreleased\n\n## v0.7.0 (2026-11-01)\n\nText.\n',
  'upgrade.sh': '#!/usr/bin/env bash\n',
  'scripts/pg-major.sh': '#!/usr/bin/env bash\n',
  'setup.sh': 'operator_lock_or_inherited "$STATE"\nbash "$ROOT/scripts/compose.sh" up -d --force-recreate --no-deps --wait --wait-timeout 180 functions\n',
};
test('the release contents gate passes a complete release and a pre-release of it', () => {
  for (const tag of ['v0.7.0', 'v0.7.0-rc.1', 'v0.7.0+build.5']) {
    const result = contents(tag, releaseFiles);
    assert.equal(result.status, 0, `${tag}: ${result.stderr}`);
  }
});
test('the release contents gate names what is missing', () => {
  const missing = (tag, files, pattern) => {
    const result = contents(tag, files);
    assert.notEqual(result.status, 0, tag);
    assert.match(result.stderr, pattern, result.stderr);
  };
  missing('v0.7.1', releaseFiles, /no section '## v0\.7\.1 \(YYYY-MM-DD\)' for v0\.7\.1/);
  missing('v0.7.0', { ...releaseFiles, 'CHANGELOG.md': '## Unreleased\n' }, /no section '## v0\.7\.0/);
  const { 'upgrade.sh': _a, ...noUpgrade } = releaseFiles;
  missing('v0.7.0', noUpgrade, /upgrade\.sh is missing/);
  const { 'scripts/pg-major.sh': _b, ...noMajor } = releaseFiles;
  missing('v0.7.0', noMajor, /scripts\/pg-major\.sh is missing/);
  missing('v0.7.0', { ...releaseFiles, 'setup.sh': 'operator_lock "$STATE"\nbash "$ROOT/scripts/compose.sh" up -d --force-recreate --no-deps --wait functions\n' }, /does not call operator_lock_or_inherited/);
  missing('v0.7.0', { ...releaseFiles, 'setup.sh': 'operator_lock_or_inherited "$STATE"\n' }, /does not recreate the functions container/);
});
test('this repository has the files and the setup.sh lines the contents gate asks for, and release.yml runs the gate', () => {
  const root = fileURLToPath(new URL('..', import.meta.url));
  const own = spawnSync('bash', ['scripts/check-release-contents.sh'], { cwd: root, env: { ...process.env, GITHUB_REF_NAME: 'v9.9.9-rc.1' }, encoding: 'utf8' });
  // Only the CHANGELOG section is missing for an invented tag; the files upgrade.sh needs are all here.
  assert.notEqual(own.status, 0);
  assert.match(own.stderr, /no section/);
  assert.doesNotMatch(own.stderr, /upgrade\.sh is missing|pg-major\.sh is missing|operator_lock_or_inherited|recreate the functions/);
  assert.match(readFileSync(join(root, '.github/workflows/release.yml'), 'utf8'), /run: bash scripts\/check-release-contents\.sh/);
});
