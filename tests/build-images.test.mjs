import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, existsSync, copyFileSync, rmSync, statSync, chmodSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { makeState, scriptRoot, repo } from './backup-test-helpers.mjs';

// scripts/build-images.sh from a private copy of the operator scripts, against a
// fake docker: `compose config --format json` prints the fixture, `image
// inspect` succeeds for the images named in FAKE_IMAGES, `compose build` is
// logged and fails when FAKE_FAIL_BUILD=yes.
function fixture() {
  const scratch = mkdtempSync(join(tmpdir(), 'warehouse-build-images-'));
  const state = makeState(scratch);
  const root = scriptRoot(scratch);
  copyFileSync(join(repo, 'scripts/image-recipes.mjs'), join(root, 'scripts/image-recipes.mjs'));
  const services = {};
  const recipe = (service, { profiles, image, context = service } = {}) => {
    const dir = join(root, 'docker', context);
    mkdirSync(join(dir, 'sub'), { recursive: true });
    writeFileSync(join(dir, 'Dockerfile'), `FROM example.invalid/${service}:1\n`);
    writeFileSync(join(dir, 'sub/go.mod'), `module ${service}\n`);
    services[service] = { build: { context: dir, dockerfile: 'Dockerfile' }, ...(profiles ? { profiles } : {}), ...(image ? { image } : {}) };
  };
  recipe('db', { context: 'postgres' });
  recipe('imgproxy');
  recipe('prometheus', { profiles: ['monitoring'] });
  recipe('cups', { profiles: ['printing'] });
  recipe('grafana', { profiles: ['monitoring'], image: 'warehouse-grafana:local' });
  services.kong = { image: 'kong:3.9.3-ubuntu' };
  writeFileSync(join(scratch, 'config.json'), JSON.stringify({ name: 'warehouse-backup-test', services }));
  const bin = join(scratch, 'bin');
  mkdirSync(bin, { mode: 0o700 });
  writeFileSync(join(bin, 'docker'), `#!/bin/sh
case "$1" in
  ps) exit 0 ;;
  image) for image in $FAKE_IMAGES; do [ "$image" = "$5" ] && exit 0; done; exit 1 ;;
  compose)
    case "$*" in
      *' config --format json') cat "$FAKE_CONFIG" ;;
      *' build '*) printf '%s\\n' "$*" | sed 's/.* build //' >> "$FAKE_BUILD_LOG"; if [ "$FAKE_FAIL_BUILD" = yes ]; then exit 9; fi ;;
    esac ;;
esac
`, { mode: 0o700 });
  return { scratch, state, root, record: join(state, 'config/image-recipes.sha256') };
}

function build({ scratch, state, root }, { args = [], images = '', fail = false } = {}) {
  const log = join(scratch, 'build.log');
  writeFileSync(log, '');
  const result = spawnSync('bash', [join(root, 'scripts/build-images.sh'), ...args], {
    encoding: 'utf8',
    env: { ...process.env, PATH: `${join(scratch, 'bin')}:${process.env.PATH}`, WAREHOUSE_STATE_DIR: state,
      FAKE_CONFIG: join(scratch, 'config.json'), FAKE_IMAGES: images, FAKE_BUILD_LOG: log, FAKE_FAIL_BUILD: fail ? 'yes' : '' },
  });
  return { ...result, builds: readFileSync(log, 'utf8').trim() };
}
const CORE = 'warehouse-backup-test-db warehouse-backup-test-imgproxy';
const recorded = record => readFileSync(record, 'utf8').trim().split('\n').map(line => line.split('  ')[1]);

test('a first run builds the core images, leaves unused optional services alone and records what it built', () => {
  const f = fixture();
  try {
    const result = build(f);
    assert.equal(result.status, 0, result.stderr);
    assert.equal(result.builds, 'db imgproxy');
    assert.match(result.stdout, /Building the db image: image missing\./);
    assert.match(result.stdout, /Built 2 image\(s\)\./);
    assert.deepEqual(recorded(f.record), ['db', 'imgproxy']);
    assert.equal(statSync(f.record).mode & 0o777, 0o600);
  } finally { rmSync(f.scratch, { recursive: true, force: true }); }
});

test('an installation from before the record rebuilds every image in use once, then nothing', () => {
  const f = fixture();
  try {
    // Existing images and no record: the state every installation is in at its first upgrade.
    const images = `${CORE} warehouse-backup-test-prometheus warehouse-grafana:local`;
    const first = build(f, { images });
    assert.equal(first.status, 0, first.stderr);
    assert.equal(first.builds, 'db grafana imgproxy prometheus', 'cups has no image, so printing is not in use');
    assert.match(first.stdout, /Building the prometheus image: no build record\./);
    const second = build(f, { images });
    assert.equal(second.status, 0, second.stderr);
    assert.equal(second.builds, '');
    assert.match(second.stdout, /Images match their recipes; nothing to rebuild\./);
  } finally { rmSync(f.scratch, { recursive: true, force: true }); }
});

test('only the image whose recipe changed is rebuilt', () => {
  const f = fixture();
  try {
    assert.equal(build(f, { images: CORE }).status, 0);
    // A file below the build context, not the Dockerfile itself: a module file.
    writeFileSync(join(f.root, 'docker/postgres/sub/go.mod'), 'module db\n\nrequire golang.org/x/net v0.60.0\n');
    const changed = build(f, { images: CORE });
    assert.equal(changed.status, 0, changed.stderr);
    assert.equal(changed.builds, 'db');
    assert.match(changed.stdout, /Building the db image: recipe changed\./);
    assert.equal(build(f, { images: CORE }).builds, '', 'the new fingerprint was recorded');
    // The executable bit of a file is part of the recipe.
    chmodSync(join(f.root, 'docker/imgproxy/Dockerfile'), 0o755);
    assert.equal(build(f, { images: CORE }).builds, 'imgproxy');
  } finally { rmSync(f.scratch, { recursive: true, force: true }); }
});

test('a failed build leaves the record as it was, so the next run tries again', () => {
  const f = fixture();
  try {
    assert.equal(build(f, { images: CORE }).status, 0);
    const before = readFileSync(f.record, 'utf8');
    writeFileSync(join(f.root, 'docker/imgproxy/Dockerfile'), 'FROM example.invalid/imgproxy:2\n');
    const failed = build(f, { images: CORE, fail: true });
    assert.notEqual(failed.status, 0);
    assert.match(failed.stderr, /Image build failed\. Nothing was started or stopped/);
    assert.equal(readFileSync(f.record, 'utf8'), before);
    assert.equal(build(f, { images: CORE }).builds, 'imgproxy');
  } finally { rmSync(f.scratch, { recursive: true, force: true }); }
});

test('--all and --no-cache rebuild every image in use; an unknown option is refused', () => {
  const f = fixture();
  try {
    assert.equal(build(f, { images: CORE }).status, 0);
    assert.equal(build(f, { images: CORE, args: ['--all'] }).builds, 'db imgproxy');
    assert.equal(build(f, { images: CORE, args: ['--no-cache'] }).builds, '--no-cache db imgproxy');
    const refused = build(f, { images: CORE, args: ['--pull'] });
    assert.notEqual(refused.status, 0);
    assert.match(refused.stderr, /Usage: bash scripts\/build-images\.sh/);
    assert.equal(refused.builds, '');
  } finally { rmSync(f.scratch, { recursive: true, force: true }); }
});

test('setup.sh rebuilds changed images before it starts the database', () => {
  const setup = readFileSync(join(repo, 'setup.sh'), 'utf8');
  const buildStep = setup.indexOf('scripts/build-images.sh');
  assert.ok(buildStep > 0, 'setup.sh calls scripts/build-images.sh');
  assert.ok(buildStep < setup.indexOf('up -d --wait --wait-timeout 180 db'), 'before the first start');
  assert.equal(existsSync(join(repo, 'scripts/image-recipes.mjs')), true);
});
