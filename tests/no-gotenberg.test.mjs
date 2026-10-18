import test from 'node:test';
import assert from 'node:assert/strict';
import { existsSync, readFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';

const root = new URL('..', import.meta.url).pathname;

// Gotenberg was replaced by docker/pdf-renderer. These files may still name it, and only for
// the reasons given: history, the upgrade path, and the parity of the renderer's settings.
const allowed = new Map([
  ['CHANGELOG.md', 'history'],
  ['docs/OPERATOR_INSTALL.md', 'the upgrade note'],
  ['docs/CONTAINER_SECURITY.md', 'history and the renderer posture compared with Gotenberg'],
  ['docs/PDF_GENERATION.md', 'what the renderer replaced'],
  ['setup.sh', 'upgrade path: remove the old container and image'],
  ['start.sh', 'upgrade path: remove the old container and image'],
  ['stop.sh', 'the --remove-orphans comment'],
  ['scripts/retire-gotenberg.sh', 'upgrade path'],
  ['tests/retire-gotenberg.test.mjs', 'tests the upgrade path'],
  ['tests/compose-networks.test.mjs', 'asserts the service is gone'],
  ['tests/no-gotenberg.test.mjs', 'this test'],
]);

test('no Gotenberg reference remains except in history, the upgrade path and the renderer parity notes', () => {
  const files = spawnSync('git', ['ls-files', '-z', '--cached', '--others', '--exclude-standard'], { cwd: root, encoding: 'utf8' }).stdout.split('\0').filter(Boolean);
  assert.ok(files.length > 100, 'the file list was read');
  const found = [];
  for (const file of files) {
    if (!existsSync(root + file) || /\.(?:png|jpe?g|ico|woff2?|zip|gz|tgz|pdf)$/i.test(file) || file === 'package-lock.json') continue;
    const text = readFileSync(root + file, 'utf8');
    if (!/gotenberg/i.test(text)) continue;
    // The renderer says in its own files which Gotenberg settings it keeps.
    if (file.startsWith('docker/pdf-renderer/') || allowed.has(file)) continue;
    found.push(file);
  }
  assert.deepEqual(found, [], 'these files still name Gotenberg');
  for (const path of ['docker/gotenberg', 'LICENSES/gotenberg']) assert.equal(existsSync(root + path), false, `${path} is removed`);
});

test('no function, Compose file or workflow reads or sets a Gotenberg variable or service', () => {
  for (const file of ['docker/docker-compose.yml', 'docker/docker-compose.override.yml', 'functions/main/worker-env.ts', 'health-check.sh', 'scripts/backup.sh', '.github/workflows/ci.yml', 'docker/image-exceptions.json', '.github/dependabot.yml']) {
    assert.doesNotMatch(readFileSync(root + file, 'utf8'), /gotenberg/i, file);
  }
  assert.match(readFileSync(root + 'CHANGELOG.md', 'utf8'), /^## Unreleased: pdf-renderer replaces Gotenberg$/m);
});
