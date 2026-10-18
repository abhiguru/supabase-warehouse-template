import test from 'node:test';
import assert from 'node:assert/strict';
import { chmodSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

const root = new URL('..', import.meta.url).pathname.replace(/\/$/, '');
const read = path => readFileSync(join(root, path), 'utf8');

// A fake `docker` on PATH records every call and answers like a host with one old gotenberg container.
function run(argument, { project = 'warehouse-upgrade-test', workingDir = `${root}/docker`, imageExists = true, removeImageFails = false } = {}) {
  const scratch = mkdtempSync(join(tmpdir(), 'retire-gotenberg-'));
  try {
    mkdirSync(join(scratch, 'state/config'), { recursive: true });
    mkdirSync(join(scratch, 'bin'));
    writeFileSync(join(scratch, 'state/config/compose.env'), `WAREHOUSE_PROJECT_NAME=${project}\n`);
    writeFileSync(join(scratch, 'bin/docker'), `#!/usr/bin/env bash
echo "$*" >> "${scratch}/calls"
case "$1 $2" in
  "ps -aq") echo abc123def456 ;;
  "inspect --format") echo "${workingDir}" ;;
  "rm -f") ;;
  "image inspect") ${imageExists ? 'exit 0' : 'exit 1'} ;;
  "image rm") ${removeImageFails ? 'exit 1' : 'exit 0'} ;;
esac
`);
    chmodSync(join(scratch, 'bin/docker'), 0o755);
    const result = spawnSync('bash', [join(root, 'scripts/retire-gotenberg.sh'), argument], {
      encoding: 'utf8', env: { ...process.env, PATH: `${scratch}/bin:${process.env.PATH}`, WAREHOUSE_STATE_DIR: join(scratch, 'state') },
    });
    let calls = '';
    try { calls = readFileSync(join(scratch, 'calls'), 'utf8'); } catch { /* no docker call was made */ }
    return { ...result, calls };
  } finally { rmSync(scratch, { recursive: true, force: true }); }
}

test('the old gotenberg container of this project and checkout is found by its Compose labels and removed', () => {
  const result = run('container');
  assert.equal(result.status, 0, result.stderr);
  assert.match(result.calls, /^ps -aq --filter label=com\.docker\.compose\.project=warehouse-upgrade-test --filter label=com\.docker\.compose\.service=gotenberg$/m);
  assert.match(result.calls, /^rm -f abc123def456$/m);
  assert.match(result.stdout, /Removed the old gotenberg container of warehouse-upgrade-test/);
});

test('a gotenberg container that belongs to another checkout of the project is left alone', () => {
  const result = run('container', { workingDir: '/somewhere/else/docker' });
  assert.equal(result.status, 0);
  assert.doesNotMatch(result.calls, /^rm /m);
  assert.match(result.stderr, /belongs to another checkout/);
});

test('the old <project>-gotenberg image is removed after the start, and a refusal only warns', () => {
  const removed = run('image');
  assert.equal(removed.status, 0);
  assert.match(removed.calls, /^image rm warehouse-upgrade-test-gotenberg$/m);
  assert.match(removed.stdout, /Removed the old image warehouse-upgrade-test-gotenberg/);
  const absent = run('image', { imageExists: false });
  assert.equal(absent.status, 0);
  assert.doesNotMatch(absent.calls, /^image rm/m);
  const refused = run('image', { removeImageFails: true });
  assert.equal(refused.status, 0, 'a image Docker will not remove never fails an upgrade');
  assert.match(refused.stderr, /Kept the old image/);
});

test('an invalid project name or argument is refused before docker is called', () => {
  const bad = run('container', { project: 'not-a-warehouse' });
  assert.notEqual(bad.status, 0);
  assert.equal(bad.calls, '');
  assert.notEqual(run('everything').status, 0);
});

test('setup.sh and start.sh retire the container before they start and the image after, and stop.sh removes orphans', () => {
  for (const name of ['setup.sh', 'start.sh']) {
    const lines = read(name).split('\n');
    const container = lines.indexOf('bash "$ROOT/scripts/retire-gotenberg.sh" container');
    const image = lines.indexOf('bash "$ROOT/scripts/retire-gotenberg.sh" image');
    const firstStart = lines.findIndex(line => line.startsWith('bash "$ROOT/scripts/compose.sh" up -d'));
    const fullStart = lines.indexOf('bash "$ROOT/scripts/compose.sh" up -d --wait --wait-timeout 180');
    assert.ok(container > 0 && container < firstStart, `${name}: the container goes before any start`);
    assert.ok(image > fullStart && fullStart > 0, `${name}: the image goes after the full start`);
  }
  assert.match(read('stop.sh'), /^bash "\$ROOT\/scripts\/compose\.sh" --profile '\*' down --remove-orphans$/m);
  // Under set -e a lookup of a service that no longer exists would fail the backup.
  assert.doesNotMatch(read('scripts/backup.sh'), /\bgotenberg\b/);
});
