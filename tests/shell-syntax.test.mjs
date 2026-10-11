// Every tracked shell script must parse, including the two that run inside images
// (docker/cups/entrypoint.sh, docker/grafana/install-plugins.sh), and CI must check the same set.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { join } from 'node:path';

const root = new URL('..', import.meta.url).pathname;
const tracked = spawnSync('git', ['-C', root, 'ls-files', '*.sh'], { encoding: 'utf8' });

test('every tracked shell script passes a syntax check with its own interpreter', { skip: tracked.status !== 0 && 'not a git checkout' }, () => {
  const scripts = tracked.stdout.split('\n').filter(Boolean);
  for (const expected of ['setup.sh', 'scripts/verify-restore.sh', 'scripts/backup-key.sh', 'tests/verify-restore-drill.sh', 'docker/cups/entrypoint.sh', 'docker/grafana/install-plugins.sh']) assert.ok(scripts.includes(expected), expected);
  for (const script of scripts) {
    const shell = readFileSync(join(root, script), 'utf8').startsWith('#!/bin/sh') ? 'sh' : 'bash';
    const result = spawnSync(shell, ['-n', join(root, script)], { encoding: 'utf8' });
    assert.equal(result.status, 0, `${script}: ${result.stderr}`);
  }
});

test('the CI shell syntax step covers every tracked script, not a fixed list of directories', () => {
  const ci = readFileSync(join(root, '.github/workflows/ci.yml'), 'utf8');
  assert.match(ci, /for script in \$\(git ls-files '\*\.sh'\); do/);
  assert.doesNotMatch(ci, /for script in \*\.sh scripts\/\*\.sh tests\/\*\.sh/);
});

test('the disposable databases use the image digest the production database is built from', () => {
  const pinned = readFileSync(join(root, 'docker/postgres/Dockerfile'), 'utf8').match(/^FROM (supabase\/postgres:\S+@sha256:[0-9a-f]{64})$/m)[1];
  for (const script of ['scripts/verify-restore.sh', 'tests/migrations.sh', 'scripts/backup.sh']) {
    const refs = readFileSync(join(root, script), 'utf8').match(/supabase\/postgres:[^\s'"]+/g) || [];
    assert.ok(refs.length > 0, `${script} names the image`);
    for (const ref of refs) assert.equal(ref, pinned, `${script} must reference ${pinned}`);
  }
});

test('the Prometheus recipe compiles the release its runtime image is tagged with', () => {
  // The recipe puts its own build of Prometheus into the publisher's image. An
  // update of the FROM line alone would leave the old release running under a
  // new tag, so the source, the UI archive, the version string and the fixture
  // of the Grafana check move together.
  const recipe = readFileSync(join(root, 'docker/prometheus/Dockerfile'), 'utf8');
  const version = recipe.match(/^FROM prom\/prometheus:v(\d+\.\d+\.\d+)@sha256:[0-9a-f]{64}$/m)[1];
  assert.ok(recipe.includes(`/prometheus/prometheus/tar.gz/refs/tags/v${version} `), 'source tag');
  assert.ok(recipe.includes(`/releases/download/v${version}/prometheus-web-ui-${version}.tar.gz `), 'UI archive');
  const stamped = recipe.match(/version\.Version=[^\s']+/g) || [];
  assert.equal(stamped.length, 2);
  for (const stamp of stamped) assert.equal(stamp, `version.Version=${version}-warehouse.1`);
  const fixture = readFileSync(join(root, 'scripts/grafana-check.sh'), 'utf8').match(/prom\/prometheus:\S+/g) || [];
  assert.deepEqual(fixture, [`prom/prometheus:v${version}`]);
  assert.ok(readFileSync(join(root, 'docs/CONTAINER_SECURITY.md'), 'utf8').includes(`| Prometheus | ${version} |`));
});
