import test from 'node:test';
import assert from 'node:assert/strict';
import { existsSync, readFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';

const root = new URL('..', import.meta.url).pathname;

// Grafana was removed (no dashboards; alerts go to the facility's Slack). Only the changelog may name it, and
// this test, which names it to enforce that.
// migrations/00000000000094_monitoring_role.sql is applied and checksum-locked: a comment there stays as it is.
const allowed = new Set(['CHANGELOG.md', 'tests/no-grafana.test.mjs', 'migrations/00000000000094_monitoring_role.sql']);

test('no Grafana reference remains except in the changelog', () => {
  const files = spawnSync('git', ['ls-files', '-z', '--cached', '--others', '--exclude-standard'], { cwd: root, encoding: 'utf8' }).stdout.split('\0').filter(Boolean);
  assert.ok(files.length > 100, 'the file list was read');
  const found = [];
  for (const file of files) {
    if (!existsSync(root + file) || /\.(?:png|jpe?g|ico|woff2?|zip|gz|tgz|pdf)$/i.test(file) || file === 'package-lock.json' || allowed.has(file)) continue;
    // docker/prometheus/go.sum and go.mod pin a Go library that is called grafana/regexp: a dependency of
    // Prometheus' own build, not of this repository's deployment.
    if (file === 'docker/prometheus/go.mod' || file === 'docker/prometheus/go.sum') continue;
    if (/grafana/i.test(readFileSync(root + file, 'utf8')) || /grafana/i.test(file)) found.push(file);
  }
  assert.deepEqual(found, [], 'these files still name Grafana');
  for (const path of ['docker/grafana', 'docker/volumes/grafana', 'LICENSES/grafana', 'scripts/grafana-check.sh']) assert.equal(existsSync(root + path), false, `${path} is removed`);
});

test('no Compose file, script or workflow starts, builds or checks Grafana, and nothing generates its credentials', () => {
  for (const file of ['docker/docker-compose.yml', 'docker/docker-compose.override.yml', 'package.json', '.github/workflows/ci.yml', '.github/dependabot.yml', '.env.example', 'scripts/configure.mjs', 'scripts/db-roles.mjs', 'scripts/image-recipes.mjs', 'docker/image-exceptions.json']) {
    assert.doesNotMatch(readFileSync(root + file, 'utf8'), /grafana/i, file);
  }
  assert.match(readFileSync(root + 'CHANGELOG.md', 'utf8'), /^## Unreleased: Grafana removed; alerts go to the facility's Slack$/m);
});
