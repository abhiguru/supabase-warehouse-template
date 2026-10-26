import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, existsSync, rmSync, chmodSync, readdirSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { scriptRoot } from './backup-test-helpers.mjs';

// scripts/pre-images.sh against a fake docker: the images an upgrade moves away from are tagged <project>-<service>:pre-<label> before the
// checkout, put back by the way back, and the older sets are removed by exact name. The fake keeps its "images" in files, so a tag that
// the script makes can be seen afterwards.
const PROJECT = 'warehouse-fixture-1';
const OTHER = 'warehouse-other-9';
const RECORD = `${'a'.repeat(64)}  db  sha256:${'1'.repeat(64)}\n${'b'.repeat(64)}  gateway  sha256:${'2'.repeat(64)}\n`;

// containers: [{ id, service, image, imageId, stopped? }] (a stopped one is listed by `ps -a` only); images: ['repo:tag', ...] that exist on the fake host.
function world({ containers, images = [], record = RECORD } = {}) {
  const scratch = mkdtempSync(join(tmpdir(), 'warehouse-pre-images-'));
  const state = join(scratch, 'state');
  for (const dir of ['config', 'data']) mkdirSync(join(state, dir), { recursive: true, mode: 0o700 });
  writeFileSync(join(state, 'config/compose.env'), `WAREHOUSE_PROJECT_NAME=${PROJECT}\n`, { mode: 0o600 });
  if (record !== null) writeFileSync(join(state, 'config/image-recipes.sha256'), record, { mode: 0o600 });
  const root = scriptRoot(scratch);
  const bin = join(scratch, 'bin');
  mkdirSync(bin);
  const dir = join(scratch, 'fake');
  mkdirSync(join(dir, 'containers'), { recursive: true });
  mkdirSync(join(dir, 'stopped'), { recursive: true });
  writeFileSync(join(dir, 'images'), images.map(image => `${image}\n`).join(''));
  for (const c of containers ?? []) writeFileSync(join(dir, c.stopped ? 'stopped' : 'containers', c.id), `${c.image} ${c.imageId}\n`);
  // ps -q --filter label=...project=P: the running containers of that project (a file per container, its first line "<config image> <image id>");
  // ps -aq: the stopped ones first, then the running ones (an order a service with an old stopped container and a new running one can have);
  // `docker tag SRC DST` adds DST (repo:latest when it has no tag) to the image list; `image ls` and `image rm` read and write it.
  writeFileSync(join(bin, 'docker'), `#!/bin/sh
printf '%s\\n' "$*" >> "${dir}/calls"
case "$1" in
  ps) case "$*" in *"label=com.docker.compose.project=${PROJECT}"*) case "$2" in -aq|-a) ls "${dir}/stopped" ;; esac; ls "${dir}/containers" ;; esac ;;
  inspect) cat "${dir}/containers/$4" 2>/dev/null || cat "${dir}/stopped/$4" ;;
  tag) case "$3" in *:*) dst="$3" ;; *) dst="$3:latest" ;; esac; printf '%s\\n' "$dst" >> "${dir}/images"; printf '%s -> %s\\n' "$2" "$dst" >> "${dir}/tagged" ;;
  image)
    case "$2" in
      ls) sed 's/:\\([^:/]*\\)$/ \\1/' "${dir}/images" ;;
      rm) grep -vxF "$3" "${dir}/images" > "${dir}/images.new"; mv "${dir}/images.new" "${dir}/images"; if [ "$FAKE_RM_FAILS" = "$3" ]; then echo "conflict: unable to remove $3" >&2; exit 1; fi ;;
      prune) echo 'image prune must never be called' >&2; exit 99 ;;
    esac ;;
esac
`, { mode: 0o755 });
  const run = (...args) => {
    const r = spawnSync('bash', [join(root, 'scripts/pre-images.sh'), ...args], { encoding: 'utf8',
      env: { ...process.env, PATH: `${bin}:${process.env.PATH}`, WAREHOUSE_STATE_DIR: state } });
    return { ...r, calls: existsSync(join(dir, 'calls')) ? readFileSync(join(dir, 'calls'), 'utf8') : '',
      images: readFileSync(join(dir, 'images'), 'utf8').split('\n').filter(Boolean).sort(),
      tagged: existsSync(join(dir, 'tagged')) ? readFileSync(join(dir, 'tagged'), 'utf8').split('\n').filter(Boolean).sort() : [] };
  };
  return { scratch, state, run, cleanup: () => rmSync(scratch, { recursive: true, force: true }) };
}
const built = (service, n) => ({ id: `c${n}`, service, image: `${PROJECT}-${service}`, imageId: `sha256:${String(n).repeat(64)}` });

test('name makes the tag suffix of a release label, and needs no state', () => {
  const run = label => spawnSync('bash', [new URL('../scripts/pre-images.sh', import.meta.url).pathname, 'name', label], { encoding: 'utf8', env: { ...process.env, WAREHOUSE_STATE_DIR: '' } });
  assert.equal(run('v0.6.1').stdout, 'pre-v0.6.1\n');
  assert.equal(run('v0.7.0-rc.1').stdout, 'pre-v0.7.0-rc.1\n');
  assert.equal(run('v0.7.0+build 5/x').stdout, 'pre-v0.7.0_build_5_x\n', 'characters a Docker tag cannot hold become _');
  assert.equal(run('1a2b3c4').stdout, 'pre-1a2b3c4\n');
});

test('tag: every image this installation built and runs gets :pre-<label>; pulled images, digests and other projects do not; the build record is kept', () => {
  const w = world({
    containers: [built('db', 1), built('gateway', 2), { id: 'c3', service: 'gateway-lan', image: `${PROJECT}-gateway`, imageId: `sha256:${'2'.repeat(64)}` },
      { id: 'c4', service: 'rest', image: 'postgrest/postgrest:v14.0', imageId: `sha256:${'3'.repeat(64)}` },
      { id: 'c5', service: 'functions', image: `${PROJECT}-functions@sha256:${'4'.repeat(64)}`, imageId: `sha256:${'4'.repeat(64)}` },
      { id: 'c6', service: 'storage', image: `${PROJECT}-storage:latest`, imageId: `sha256:${'5'.repeat(64)}` }],
    images: [`${PROJECT}-db:latest`, `${PROJECT}-gateway:latest`, `${PROJECT}-storage:latest`],
  });
  try {
    const r = w.run('tag', 'v0.6.1');
    assert.equal(r.status, 0, r.stderr);
    // gateway and gateway-lan share one image: one tag. A tag that named an image by id leaves the :latest names where they were.
    assert.deepEqual(r.tagged, [
      `sha256:${'1'.repeat(64)} -> ${PROJECT}-db:pre-v0.6.1`,
      `sha256:${'2'.repeat(64)} -> ${PROJECT}-gateway:pre-v0.6.1`,
      `sha256:${'5'.repeat(64)} -> ${PROJECT}-storage:pre-v0.6.1`,
    ]);
    assert.match(r.stdout, /Tagged 3 image\(s\) of warehouse-fixture-1 as :pre-v0\.6\.1/);
    assert.equal(readFileSync(join(w.state, 'config/image-recipes.pre-v0.6.1.sha256'), 'utf8'), RECORD, 'the build record that matches those images is kept');
    assert.equal(readFileSync(join(w.state, 'config/image-recipes.sha256'), 'utf8'), RECORD, 'the live record is untouched');
    assert.doesNotMatch(r.calls, /image prune|system prune|builder prune/);
  } finally { w.cleanup(); }
});

test('tag also takes the image of a stopped container (an optional service that is stopped), and where a service has both, the image that runs', () => {
  const w = world({
    containers: [built('db', 1),
      { ...built('cups', 7), stopped: true },
      // gateway: an old stopped container (id sorts first) and the running one of the new image
      { ...built('gateway', 8), id: 'c0', stopped: true },
      { ...built('gateway', 2), id: 'c2' }],
    images: [`${PROJECT}-db:latest`, `${PROJECT}-cups:latest`, `${PROJECT}-gateway:latest`],
  });
  try {
    const r = w.run('tag', 'v0.6.1');
    assert.equal(r.status, 0, r.stderr);
    assert.deepEqual(r.tagged, [
      `sha256:${'1'.repeat(64)} -> ${PROJECT}-db:pre-v0.6.1`,
      `sha256:${'2'.repeat(64)} -> ${PROJECT}-gateway:pre-v0.6.1`,
      `sha256:${'7'.repeat(64)} -> ${PROJECT}-cups:pre-v0.6.1`,
    ].sort(), 'the stopped optional service is tagged; for the gateway the running container\'s image (2...), not the stopped one\'s (8...)');
    assert.match(r.calls, /ps -q --filter/);
    assert.match(r.calls, /ps -aq --filter/);
  } finally { w.cleanup(); }
});

test('tag exits 3 and says why when there is nothing to tag, and does not touch Docker beyond looking', () => {
  const none = world({ containers: [], images: [] });
  try {
    const r = none.run('tag', 'v0.6.1');
    assert.equal(r.status, 3, r.stderr);
    assert.match(r.stderr, /no container of warehouse-fixture-1 uses an image it built/);
    assert.deepEqual(r.tagged, []);
    assert.equal(existsSync(join(none.state, 'config/image-recipes.pre-v0.6.1.sha256')), false);
  } finally { none.cleanup(); }
  const pulledOnly = world({ containers: [{ id: 'c1', service: 'rest', image: 'postgrest/postgrest:v14.0', imageId: `sha256:${'3'.repeat(64)}` }] });
  try { assert.equal(pulledOnly.run('tag', 'v0.6.1').status, 3); } finally { pulledOnly.cleanup(); }
});

test('restore puts the tagged images back as the installation\'s own and the build record with them, so nothing is built', () => {
  const w = world({
    containers: [],
    images: [`${PROJECT}-db:latest`, `${PROJECT}-db:pre-v0.6.1`, `${PROJECT}-gateway:latest`, `${PROJECT}-gateway:pre-v0.6.1`,
      `${PROJECT}-gateway:pre-v0.5.0`, `${OTHER}-db:pre-v0.6.1`],
    record: `${'c'.repeat(64)}  db  sha256:${'9'.repeat(64)}\n`,
  });
  try {
    writeFileSync(join(w.state, 'config/image-recipes.pre-v0.6.1.sha256'), RECORD, { mode: 0o600 });
    const r = w.run('restore', 'v0.6.1');
    assert.equal(r.status, 0, r.stderr);
    assert.deepEqual(r.tagged, [`${PROJECT}-db:pre-v0.6.1 -> ${PROJECT}-db:latest`, `${PROJECT}-gateway:pre-v0.6.1 -> ${PROJECT}-gateway:latest`],
      'only this installation\'s images of that release, and not the other release\'s or another project\'s');
    assert.equal(readFileSync(join(w.state, 'config/image-recipes.sha256'), 'utf8'), RECORD, 'the build record of the old release is back');
    assert.match(r.stdout, /Put back 2 image\(s\) of warehouse-fixture-1 from :pre-v0\.6\.1/);
  } finally { w.cleanup(); }
});

test('restore with nothing saved says so and succeeds: the old release\'s setup then builds as it always did', () => {
  const w = world({ containers: [], images: [`${PROJECT}-db:latest`] });
  try {
    const r = w.run('restore', 'v0.6.1');
    assert.equal(r.status, 0, r.stderr);
    assert.match(r.stdout, /no image of warehouse-fixture-1 is tagged :pre-v0\.6\.1[^]*builds its images again/);
    assert.deepEqual(r.tagged, []);
    assert.equal(readFileSync(join(w.state, 'config/image-recipes.sha256'), 'utf8'), RECORD, 'the record is left alone');
  } finally { w.cleanup(); }
});

test('prune removes the pre-* tags of this installation except the kept set, one exact name at a time, and the other saved records', () => {
  const w = world({
    containers: [],
    images: [`${PROJECT}-db:latest`, `${PROJECT}-db:pre-v0.6.1`, `${PROJECT}-db:pre-v0.5.0`, `${PROJECT}-gateway:pre-v0.5.0`, `${PROJECT}-gateway:pre-v0.6.1`,
      `${PROJECT}-db:previous`, `${OTHER}-db:pre-v0.5.0`, 'postgres:18.6:pre-x'],
  });
  try {
    for (const label of ['v0.6.1', 'v0.5.0', 'v0.4.0']) writeFileSync(join(w.state, `config/image-recipes.pre-${label}.sha256`), RECORD, { mode: 0o600 });
    const r = w.run('prune', 'v0.6.1');
    assert.equal(r.status, 0, r.stderr);
    assert.deepEqual(r.images, [`${OTHER}-db:pre-v0.5.0`, `${PROJECT}-db:latest`, `${PROJECT}-db:pre-v0.6.1`, `${PROJECT}-db:previous`, `${PROJECT}-gateway:pre-v0.6.1`, 'postgres:18.6:pre-x'].sort(),
      'the kept set, every :latest, another project\'s tags and a tag that only starts like pre- are left');
    assert.deepEqual(readdirSync(join(w.state, 'config')).filter(name => name.startsWith('image-recipes.')).sort(), ['image-recipes.pre-v0.6.1.sha256', 'image-recipes.sha256']);
    assert.deepEqual(r.calls.split('\n').filter(line => line.startsWith('image rm')), [`image rm ${PROJECT}-db:pre-v0.5.0`, `image rm ${PROJECT}-gateway:pre-v0.5.0`], 'exact names, nothing else removed');
    assert.doesNotMatch(r.calls, /prune/);
  } finally { w.cleanup(); }
});

test('prune with a third argument keeps the set of that tag, not the one the label would name; only prune takes it, and only as a pre- tag', () => {
  const w = world({
    containers: [],
    images: [`${PROJECT}-db:latest`, `${PROJECT}-db:pre-v0.6.1`, `${PROJECT}-db:pre-0.6.1-recorded`, `${PROJECT}-db:pre-v0.5.0`],
  });
  try {
    for (const label of ['v0.6.1', '0.6.1-recorded', 'v0.5.0']) writeFileSync(join(w.state, `config/image-recipes.pre-${label}.sha256`), RECORD, { mode: 0o600 });
    // The label would name pre-v0.6.1; the recorded tag is another one (a naming that changed between releases): that set is kept.
    const r = w.run('prune', 'v0.6.1', 'pre-0.6.1-recorded');
    assert.equal(r.status, 0, r.stderr);
    assert.deepEqual(r.images, [`${PROJECT}-db:latest`, `${PROJECT}-db:pre-0.6.1-recorded`].sort());
    assert.deepEqual(readdirSync(join(w.state, 'config')).filter(name => name.startsWith('image-recipes.')).sort(), ['image-recipes.pre-0.6.1-recorded.sha256', 'image-recipes.sha256']);
    for (const bad of [['tag', 'v0.6.1', 'pre-x'], ['restore', 'v0.6.1', 'pre-x'], ['name', 'v0.6.1', 'pre-x'], ['prune', 'v0.6.1', 'not-a-pre-tag'], ['prune', 'v0.6.1', 'pre-x; rm -rf /'], ['prune', 'v0.6.1', 'pre-']]) {
      assert.equal(w.run(...bad).status, 2, bad.join(' '));
    }
  } finally { w.cleanup(); }
});

test('prune reports a tag it could not remove and still removes the others', () => {
  const w = world({ containers: [], images: [`${PROJECT}-db:pre-v0.5.0`, `${PROJECT}-gateway:pre-v0.5.0`] });
  try {
    const r = spawnSync('bash', [join(scriptRoot(w.scratch), 'scripts/pre-images.sh'), 'prune', 'v0.6.1'], { encoding: 'utf8',
      env: { ...process.env, PATH: `${join(w.scratch, 'bin')}:${process.env.PATH}`, WAREHOUSE_STATE_DIR: w.state, FAKE_RM_FAILS: `${PROJECT}-db:pre-v0.5.0` } });
    assert.equal(r.status, 1);
    assert.match(r.stderr, new RegExp(`could not remove the image tag ${PROJECT}-db:pre-v0\\.5\\.0; remove it by hand with: docker image rm ${PROJECT}-db:pre-v0\\.5\\.0`));
    assert.equal(readFileSync(join(w.scratch, 'fake/images'), 'utf8').includes(`${PROJECT}-gateway:pre-v0.5.0`), false, 'the other tag was still removed');
  } finally { w.cleanup(); }
});

test('without Docker or an installation name the commands say so; tag exits 3, the others 0', () => {
  const w = world({ containers: [] });
  try {
    writeFileSync(join(w.state, 'config/compose.env'), 'JWT_SECRET=x\n');
    assert.equal(w.run('tag', 'v0.6.1').status, 3);
    assert.equal(w.run('restore', 'v0.6.1').status, 0);
    assert.equal(w.run('prune', 'v0.6.1').status, 0);
    assert.equal(w.run('frobnicate', 'v0.6.1').status, 2);
    assert.equal(w.run('tag').status, 2);
  } finally { w.cleanup(); }
});
