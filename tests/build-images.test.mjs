import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, readdirSync, copyFileSync, rmSync, statSync, chmodSync, symlinkSync, existsSync, truncateSync, openSync, closeSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { makeState, scriptRoot, repo, backupKey, hmacHex } from './backup-test-helpers.mjs';
import { createHash } from 'node:crypto';

// scripts/build-images.sh from a private copy of the operator scripts, against a
// fake docker that keeps its "images" as files (name -> image ID):
//   compose config --format json   prints the fixture (fails with FAKE_FAIL_CONFIG=yes)
//   compose build [opts] SERVICE..  logged; gives every named image a new ID (fails with FAKE_FAIL_BUILD=yes)
//   compose up -d ... SERVICE..     logged (fails with FAKE_FAIL_UP=yes)
//   image inspect                   the stored ID (--format {{.Size}}: 1000), or exit 1
//   save --output FILE IMAGE        writes "image NAME id ID" to FILE (fails after a partial write with FAKE_FAIL_SAVE=yes)
//   ps -a / ps (with --format)      the services in FAKE_CONTAINERS / FAKE_RUNNING
//   ps -aq                          nothing (the ownership check of scripts/compose.sh)
const PROJECT = 'warehouse-backup-test';
const imageFile = name => name.replace(/[/:]/g, '_');
function fixture() {
  const scratch = mkdtempSync(join(tmpdir(), 'warehouse-build-images-'));
  const state = makeState(scratch);
  const root = scriptRoot(scratch);
  copyFileSync(join(repo, 'scripts/image-recipes.mjs'), join(root, 'scripts/image-recipes.mjs'));
  const services = {};
  const recipe = (service, { profiles, context = service } = {}) => {
    const dir = join(root, 'docker', context);
    mkdirSync(join(dir, 'sub'), { recursive: true });
    writeFileSync(join(dir, 'Dockerfile'), `FROM example.invalid/${service}:1\n`);
    writeFileSync(join(dir, 'sub/go.mod'), `module ${service}\n`);
    services[service] = { build: { context: dir, dockerfile: 'Dockerfile' }, ...(profiles ? { profiles } : {}) };
  };
  recipe('db', { context: 'postgres' });
  recipe('functions');
  recipe('supavisor', { profiles: ['pooler'] });
  recipe('cups', { profiles: ['printing'] });
  // No `image:`: Compose tags every built image `<project>-<service>`, the sensor bridge included.
  recipe('sensor-bridge', { profiles: ['sensors'] });
  services.kong = { image: 'kong:3.9.4-ubuntu' };
  const config = join(scratch, 'config.json');
  const writeConfig = () => writeFileSync(config, JSON.stringify({ name: PROJECT, services }));
  writeConfig();
  mkdirSync(join(scratch, 'images'));
  const bin = join(scratch, 'bin');
  mkdirSync(bin, { mode: 0o700 });
  writeFileSync(join(bin, 'docker'), `#!/bin/sh
file() { printf '%s' "$1" | tr '/:' '__'; }
case "$1" in
  ps)
    case "$2" in
      -aq) exit 0 ;;
      -a) for service in $FAKE_CONTAINERS; do echo "$service"; done ;;
      *) for service in $FAKE_RUNNING; do echo "$service"; done ;;
    esac ;;
  image) if [ "$4" = '{{.Size}}' ]; then echo 1000; else cat "$FAKE_DIR/images/$(file "$5")" 2>/dev/null || exit 1; fi ;;
  save)
    if [ "$FAKE_FAIL_SAVE" = yes ]; then echo partial > "$3"; echo 'write error: no space left on device' >&2; exit 5; fi
    printf 'image %s id %s\n' "$4" "$(cat "$FAKE_DIR/images/$(file "$4")")" > "$3" ;;
  compose)
    case "$*" in
      *' config --format json') if [ "$FAKE_FAIL_CONFIG" = yes ]; then echo 'yaml: broken' >&2; exit 15; fi; cat "$FAKE_DIR/config.json" ;;
      *' build '*)
        args=$(printf '%s\\n' "$*" | sed 's/.* build //')
        echo "$args" >> "$FAKE_DIR/build.log"
        if [ "$FAKE_FAIL_BUILD" = yes ]; then exit 9; fi
        for service in $args; do
          case "$service" in -*) continue ;; esac
          count=$(( $(cat "$FAKE_DIR/counter" 2>/dev/null || echo 100) + 1 )); echo "$count" > "$FAKE_DIR/counter"
          image=${PROJECT}-$service
          printf 'sha256:%064d\\n' "$count" > "$FAKE_DIR/images/$(file "$image")"
        done ;;
      *' up -d '*) printf '%s\\n' "$*" | sed 's/.* up -d //' >> "$FAKE_DIR/up.log"; if [ "$FAKE_FAIL_UP" = yes ]; then exit 4; fi ;;
    esac ;;
esac
`, { mode: 0o700 });
  // An image that exists before the script ever ran, as on an installation from an earlier release.
  let seed = 0;
  const haveImages = (...names) => names.forEach(name => writeFileSync(join(scratch, 'images', imageFile(name)), `sha256:${String(++seed).padStart(64, '0')}\n`));
  return { scratch, state, root, services, writeConfig, haveImages, record: join(state, 'config/image-recipes.sha256') };
}

function run({ scratch, state, root }, { args = [], containers = '', running = '', fail = '', wrap, env = {} } = {}) {
  for (const log of ['build.log', 'up.log']) writeFileSync(join(scratch, log), '');
  const script = join(root, 'scripts/build-images.sh');
  const command = wrap ? ['bash', ['-c', wrap, 'wrap', script, join(state, 'config/operator.lock')]] : ['bash', [script, ...args]];
  const result = spawnSync(...command, {
    encoding: 'utf8',
    env: { ...process.env, PATH: `${join(scratch, 'bin')}:${process.env.PATH}`, WAREHOUSE_STATE_DIR: state, FAKE_DIR: scratch,
      FAKE_CONTAINERS: containers, FAKE_RUNNING: running, [`FAKE_FAIL_${fail.toUpperCase()}`]: 'yes',
      // The disk of the machine running the tests decides nothing: the 5 GiB reserve is lifted unless a test sets it.
      WAREHOUSE_IMAGE_SAVE_RESERVE: '0', ...env },
  });
  const log = name => readFileSync(join(scratch, name), 'utf8').trim();
  return { ...result, builds: log('build.log'), ups: log('up.log') };
}
const CORE = [`${PROJECT}-db`, `${PROJECT}-functions`];
const recorded = record => readFileSync(record, 'utf8').trim().split('\n').map(line => line.split('  '));
const cleanup = f => rmSync(f.scratch, { recursive: true, force: true });

test('a first installation builds the core images, leaves optional services alone and records fingerprint and image ID', () => {
  const f = fixture();
  try {
    const result = run(f);
    assert.equal(result.status, 0, result.stderr);
    assert.equal(result.builds, 'db functions');
    assert.match(result.stdout, /Building the db image: image missing\./);
    assert.match(result.stdout, /Built 2 image\(s\)\./);
    const lines = recorded(f.record);
    assert.deepEqual(lines.map(line => line[1]), ['db', 'functions']);
    for (const [fingerprint, , id] of lines) { assert.match(fingerprint, /^[0-9a-f]{64}$/); assert.match(id, /^sha256:[0-9]{64}$/); }
    assert.equal(statSync(f.record).mode & 0o777, 0o600);
    assert.equal(result.ups, '', 'the build step starts nothing');
  } finally { cleanup(f); }
});

const images = f => join(f.state, 'images');
const tarballs = f => (existsSync(images(f)) ? readdirSync(images(f)).sort() : []);
const SIGNED = ['SHA256SUMS', 'SHA256SUMS.hmac'];
const sha = bytes => createHash('sha256').update(bytes).digest('hex');
// What backup_authenticate (scripts/backup-key.sh) says about the folder, run with the backup key as restore-host does.
function authenticate(f) {
  const r = spawnSync('bash', ['-c', 'source "$1/scripts/backup-key.sh"; backup_authenticate "$2" false', 'sh', f.root, images(f)], { encoding: 'utf8',
    env: { ...process.env, WAREHOUSE_BACKUP_KEY_FILE: join(f.state, 'config/backup.key') } });
  return { ok: r.status === 0, stderr: r.stderr };
}

test('a build saves each built image to <state>/images/<service>.tar with a copy of the build record, and a later build replaces only what it rebuilt', () => {
  const f = fixture();
  try {
    const first = run(f);
    assert.equal(first.status, 0, first.stderr);
    assert.deepEqual(tarballs(f), [...SIGNED, 'db.tar', 'functions.tar', 'image-recipes.sha256']);
    assert.match(first.stdout, new RegExp(`Saved the db image to ${images(f)}/db\\.tar\\.`));
    assert.match(first.stdout, /Saved the functions image to /);
    assert.equal(readFileSync(join(images(f), 'db.tar'), 'utf8'), `image ${PROJECT}-db id sha256:${'0'.repeat(61)}101\n`);
    assert.equal(readFileSync(join(images(f), 'image-recipes.sha256'), 'utf8'), readFileSync(f.record, 'utf8'), 'the record is kept beside the tarballs');
    assert.equal(statSync(images(f)).mode & 0o777, 0o700);
    for (const name of ['db.tar', 'functions.tar', 'image-recipes.sha256', ...SIGNED]) assert.equal(statSync(join(images(f), name)).mode & 0o777, 0o600, name);
    // Signed like a backup: SHA256SUMS lists every file, SHA256SUMS.hmac is the HMAC of it with the backup key (computed here with Node, not the script's shell code).
    const sums = readFileSync(join(images(f), 'SHA256SUMS'), 'utf8');
    assert.equal(sums, ['db.tar', 'functions.tar', 'image-recipes.sha256'].map(name => `${sha(readFileSync(join(images(f), name)))}  ${name}\n`).join(''));
    assert.equal(readFileSync(join(images(f), 'SHA256SUMS.hmac'), 'utf8'), `warehouse-backup-hmac-v1 ${hmacHex(backupKey, 'warehouse-backup-manifest-v1', sums)}\n`);
    assert.deepEqual(authenticate(f), { ok: true, stderr: '' });
    // The records that failed or were never saved are not the tarballs' concern; a rebuild of one service replaces its tarball only.
    const dbBefore = readFileSync(join(images(f), 'db.tar'), 'utf8');
    writeFileSync(join(f.root, 'docker/functions/Dockerfile'), 'FROM example.invalid/functions:2\n');
    const second = run(f);
    assert.equal(second.status, 0, second.stderr);
    assert.equal(second.builds, 'functions');
    assert.match(second.stdout, /Saved the functions image/); assert.doesNotMatch(second.stdout, /Saved the db image/);
    assert.equal(readFileSync(join(images(f), 'db.tar'), 'utf8'), dbBefore);
    assert.equal(readFileSync(join(images(f), 'functions.tar'), 'utf8'), `image ${PROJECT}-functions id sha256:${'0'.repeat(61)}103\n`, 'replaced by the new image');
    assert.equal(readFileSync(join(images(f), 'image-recipes.sha256'), 'utf8'), readFileSync(f.record, 'utf8'));
    assert.deepEqual(tarballs(f), [...SIGNED, 'db.tar', 'functions.tar', 'image-recipes.sha256'], 'no temporary file is left');
    assert.deepEqual(authenticate(f), { ok: true, stderr: '' }, 'the signature was made again over the new list');
    // An optional service that this installation uses is saved too; one without a container is not built, so not saved.
    const third = run(f, { containers: 'db functions supavisor', args: ['--all'] });
    assert.equal(third.status, 0, third.stderr);
    assert.deepEqual(tarballs(f), [...SIGNED, 'db.tar', 'functions.tar', 'image-recipes.sha256', 'supavisor.tar']);
    assert.deepEqual(authenticate(f), { ok: true, stderr: '' });
  } finally { cleanup(f); }
});

test('a save that fails or that would fill the disk is a warning: the build stands, the stale tarball of that service is removed, nothing is left over and the folder is signed again', () => {
  const f = fixture();
  try {
    assert.equal(run(f).status, 0);
    const dbTar = readFileSync(join(images(f), 'db.tar'), 'utf8');
    writeFileSync(join(f.root, 'docker/functions/Dockerfile'), 'FROM example.invalid/functions:2\n');
    const failed = run(f, { fail: 'save' });
    assert.equal(failed.status, 0, failed.stderr);
    assert.match(failed.stderr, /Warning: could not save the functions image to .*functions\.tar\. The image itself is fine\./);
    assert.match(failed.stdout, /Built 1 image\(s\)\./);
    // The record names the new functions image; the old tarball holds the old one, so restore-host must not load it.
    assert.deepEqual(tarballs(f), [...SIGNED, 'db.tar', 'image-recipes.sha256'], 'no functions.tar, no temporary file');
    assert.equal(readFileSync(join(images(f), 'db.tar'), 'utf8'), dbTar, 'the other tarball is untouched');
    assert.match(readFileSync(f.record, 'utf8'), /functions/, 'the record was written before the save');
    assert.doesNotMatch(readFileSync(join(images(f), 'SHA256SUMS'), 'utf8'), /functions\.tar/);
    assert.deepEqual(authenticate(f), { ok: true, stderr: '' });
    // No room: refused before anything is written, whatever the image size is.
    assert.equal(run(f, { args: ['--save'] }).status, 0);
    assert.ok(tarballs(f).includes('functions.tar'), 'saved again by --save');
    writeFileSync(join(f.root, 'docker/functions/Dockerfile'), 'FROM example.invalid/functions:3\n');
    const full = run(f, { env: { WAREHOUSE_IMAGE_SAVE_RESERVE: String(2 ** 60) } });
    assert.equal(full.status, 0, full.stderr);
    assert.match(full.stderr, /Warning: the functions image was not saved to .*: less than \d+ GiB would be left on the disk\..*build-images\.sh --save/);
    assert.deepEqual(tarballs(f), [...SIGNED, 'db.tar', 'image-recipes.sha256'], 'the stale functions.tar was removed');
    assert.deepEqual(authenticate(f), { ok: true, stderr: '' });
    // The default reserve is 5 GiB, or the size of the newest backup when that is larger.
    assert.match(readFileSync(join(repo, 'scripts/build-images.sh'), 'utf8'), /local reserve=\$\(\(5 \* 1024 \*\* 3\)\)/);
  } finally { cleanup(f); }
});

test('the reserve is the size of the newest backup when that is larger than 5 GiB, so the next backup still fits', () => {
  const f = fixture();
  try {
    const big = join(f.state, 'backups/warehouse-20261019T020000Z');
    mkdirSync(big, { recursive: true });
    const fd = openSync(join(big, 'database.dump'), 'w');
    try { truncateSync(join(big, 'database.dump'), 2 ** 42); } catch { closeSync(fd); cleanup(f); return; }   // a file system without sparse files that large: nothing to show
    closeSync(fd);
    mkdirSync(join(f.state, 'backups/warehouse-20261018T020000Z'), { recursive: true });   // older and empty: the newest is the one that counts
    const result = run(f, { env: { WAREHOUSE_IMAGE_SAVE_RESERVE: '' } });
    assert.equal(result.status, 0, result.stderr);
    assert.match(result.stderr, /Warning: the db image was not saved to .*: less than 4096 GiB would be left on the disk\./, '4 TiB newest backup');
    assert.deepEqual(tarballs(f).filter(name => name.endsWith('.tar')), []);
    // Without that backup the reserve is 5 GiB, which the test disk is assumed to have (the images are 1000 bytes).
    rmSync(big, { recursive: true });
    const small = run(f, { env: { WAREHOUSE_IMAGE_SAVE_RESERVE: '' } });
    assert.equal(small.status, 0, small.stderr);
    assert.doesNotMatch(small.stderr, /less than/);
  } finally { cleanup(f); }
});

test('tarballs of services the record does not name are removed; a folder that cannot be signed is said so and carries no signature', () => {
  const f = fixture();
  try {
    assert.equal(run(f).status, 0);
    writeFileSync(join(images(f), 'removed-service.tar'), 'a service the compose file no longer has\n');
    writeFileSync(join(images(f), 'notes.txt'), 'not mine\n');
    assert.equal(run(f, { args: ['--save'] }).status, 0);
    assert.deepEqual(tarballs(f), [...SIGNED, 'db.tar', 'functions.tar', 'image-recipes.sha256', 'notes.txt'], 'the unnamed tarball is gone; other files are not touched, and are listed in the signature');
    assert.match(readFileSync(join(images(f), 'SHA256SUMS'), 'utf8'), /  notes\.txt\n/);
    assert.deepEqual(authenticate(f), { ok: true, stderr: '' });
    // A backup key that is not private cannot sign: no signature is left (restore-host refuses such a folder).
    chmodSync(join(f.state, 'config/backup.key'), 0o644);
    const loose = run(f, { args: ['--save'] });
    assert.equal(loose.status, 0, loose.stderr);
    assert.match(loose.stderr, /The backup key .*backup\.key must be a regular file owned by this user with mode 0600\./);
    assert.match(loose.stderr, /Warning: could not sign the saved images in .* with the backup key, so db:restore-host will not use them\./);
    assert.equal(tarballs(f).some(name => SIGNED.includes(name)), false);
    chmodSync(join(f.state, 'config/backup.key'), 0o600);
    assert.equal(run(f, { args: ['--save'] }).status, 0);
    assert.deepEqual(authenticate(f), { ok: true, stderr: '' });
    // A tarball changed after signing: the folder no longer authenticates.
    writeFileSync(join(images(f), 'db.tar'), 'changed after signing\n');
    const changed = authenticate(f);
    assert.equal(changed.ok, false); assert.match(changed.stderr, /Refusing: the backup does not match its SHA256SUMS\./);
    // Without a key file at all, the first save creates one (as the first backup does) and signs with it.
    rmSync(join(f.state, 'config/backup.key'));
    const created = run(f, { args: ['--save'] });
    assert.equal(created.status, 0, created.stderr);
    assert.match(created.stderr, /Created the backup key /);
    assert.deepEqual(authenticate(f), { ok: true, stderr: '' });
  } finally { cleanup(f); }
});

test('--save writes the images in use without building; with nothing to rebuild and no copy yet, a build prints the tip', () => {
  const f = fixture();
  try {
    f.haveImages(...CORE, `${PROJECT}-supavisor`);
    // An installation built before images were saved: records exist, tarballs do not.
    assert.equal(run(f, { containers: 'db functions' }).status, 0);
    rmSync(images(f), { recursive: true });
    const tip = run(f, { containers: 'db functions' });
    assert.equal(tip.builds, '');
    assert.match(tip.stdout, /Images match their recipes; nothing to rebuild\.\nTip: no copy of the built images is kept yet\. bash scripts\/build-images\.sh --save writes one to /);
    const saved = run(f, { args: ['--save'], containers: 'db functions' });
    assert.equal(saved.status, 0, saved.stderr);
    assert.equal(saved.builds, '', 'nothing is built');
    assert.deepEqual(tarballs(f), [...SIGNED, 'db.tar', 'functions.tar', 'image-recipes.sha256']);
    assert.equal(run(f, { containers: 'db functions' }).stdout.trim(), 'Images match their recipes; nothing to rebuild.', 'no tip once there is a copy');
    // An optional service is saved only where this installation has a container of it.
    // (Its image exists but the build record has no line for it, so restore-host would never load it: it is not saved, and the note says how to record it.)
    const optional = run(f, { args: ['--save'], containers: 'db functions supavisor' });
    assert.equal(optional.status, 0, optional.stderr);
    assert.match(optional.stderr, /Note: the supavisor image was not saved: the build record has no entry for it, so db:restore-host would not use it\. Build it with bash scripts\/build-images\.sh --all, which records it\./);
    assert.equal(tarballs(f).includes('supavisor.tar'), false);
    assert.equal(run(f, { args: ['--all'], containers: 'db functions supavisor' }).status, 0);
    assert.ok(tarballs(f).includes('supavisor.tar'), 'built with --all: recorded, so saved');
    // No image at all: nothing to save, not an error.
    rmSync(join(f.scratch, 'images'), { recursive: true }); mkdirSync(join(f.scratch, 'images')); rmSync(images(f), { recursive: true });
    const none = run(f, { args: ['--save'], containers: 'db functions' });
    assert.equal(none.status, 0, none.stderr);
    assert.match(none.stdout, /No built image of this installation exists on this host; nothing to save\./);
    assert.equal(existsSync(images(f)), false);
    assert.match(run(f, { args: ['--save', '--all'] }).stderr, /Usage: bash scripts\/build-images\.sh \[--all \| --no-cache \| --replace-optional \| --save\]/);
  } finally { cleanup(f); }
});

test('image-recipes adopt: a saved record line is taken over only where the image ID exists on this host', () => {
  const f = fixture();
  try {
    const line = (service, id, n = 1) => `${String(n).repeat(64)}  ${service}  ${id}\n`;
    const ids = { db: `sha256:${'a'.repeat(64)}`, functions: `sha256:${'b'.repeat(64)}`, cups: `sha256:${'c'.repeat(64)}` };
    for (const id of [ids.db, ids.cups]) writeFileSync(join(f.scratch, 'images', imageFile(id)), `${id}\n`);   // loaded: db and cups; not functions
    const saved = join(f.scratch, 'saved-record');
    writeFileSync(saved, line('db', ids.db, 1) + line('functions', ids.functions, 2) + line('cups', ids.cups, 3) + `${'4'.repeat(64)}  nosuchid\n`);
    const target = join(f.scratch, 'new-record');
    writeFileSync(target, line('functions', `sha256:${'d'.repeat(64)}`, 5));
    const adopt = spawnSync('node', [join(f.root, 'scripts/image-recipes.mjs'), 'adopt', target, saved], {
      encoding: 'utf8', env: { ...process.env, PATH: `${join(f.scratch, 'bin')}:${process.env.PATH}`, FAKE_DIR: f.scratch } });
    assert.equal(adopt.status, 0, adopt.stderr);
    assert.equal(adopt.stdout, 'adopted db\nadopted cups\n');
    assert.equal(readFileSync(target, 'utf8'), line('cups', ids.cups, 3) + line('db', ids.db, 1) + line('functions', `sha256:${'d'.repeat(64)}`, 5), 'sorted by service; functions keeps its own line');
    assert.equal(statSync(target).mode & 0o777, 0o600);
    const usage = spawnSync('node', [join(f.root, 'scripts/image-recipes.mjs'), 'adopt', target], { encoding: 'utf8' });
    assert.equal(usage.status, 2); assert.match(usage.stderr, /adopt RECORD SAVED_RECORD/);
  } finally { cleanup(f); }
});

test('an installation from before the record rebuilds once what it uses; an image without a container is not in use', () => {
  const f = fixture();
  try {
    // The image scan and the checks build optional images that are never started:
    // The sensor bridge and CUPS have an image here, but only the pooler has a container.
    f.haveImages(...CORE, `${PROJECT}-supavisor`, `${PROJECT}-cups`, `${PROJECT}-sensor-bridge`);
    const containers = 'db functions supavisor kong';
    const first = run(f, { containers });
    assert.equal(first.status, 0, first.stderr);
    assert.equal(first.builds, 'db functions supavisor');
    assert.match(first.stdout, /Building the supavisor image: no build record\./);
    const second = run(f, { containers });
    assert.equal(second.status, 0, second.stderr);
    assert.equal(second.builds, '');
    assert.match(second.stdout, /Images match their recipes; nothing to rebuild\./);
  } finally { cleanup(f); }
});

test('only the image whose recipe changed is rebuilt: a file, its executable bit, a link, the Dockerfile path, target or arguments', () => {
  const f = fixture();
  try {
    assert.equal(run(f).status, 0);
    const changed = (what, service) => {
      const result = run(f);
      assert.equal(result.status, 0, result.stderr);
      assert.equal(result.builds, service, what);
      assert.match(result.stdout, new RegExp(`Building the ${service} image: recipe changed\\.`), what);
      assert.equal(run(f).builds, '', `${what}: the new fingerprint was recorded`);
    };
    writeFileSync(join(f.root, 'docker/postgres/sub/go.mod'), 'module db\n\nrequire golang.org/x/net v0.60.0\n');
    changed('a module file below the build directory', 'db');
    chmodSync(join(f.root, 'docker/functions/Dockerfile'), 0o755);
    changed('the executable bit', 'functions');
    symlinkSync('Dockerfile', join(f.root, 'docker/functions/link'));
    changed('a new symbolic link', 'functions');
    f.services.db.build.dockerfile = 'Dockerfile.next';
    f.writeConfig();
    changed('the Dockerfile path', 'db');
    f.services.db.build.target = 'runtime';
    f.writeConfig();
    changed('the build target', 'db');
    f.services.functions.build.args = { TARGETARCH: 'arm64' };
    f.writeConfig();
    changed('a build argument', 'functions');
  } finally { cleanup(f); }
});

test('an image whose tag was moved by something else is built again', () => {
  const f = fixture();
  try {
    assert.equal(run(f).status, 0);
    // Another checkout sharing the tag, a manual build, or a build that failed half way.
    writeFileSync(join(f.scratch, 'images', imageFile(`${PROJECT}-functions`)), `sha256:${'9'.repeat(64)}\n`);
    const result = run(f);
    assert.equal(result.status, 0, result.stderr);
    assert.equal(result.builds, 'functions');
    assert.match(result.stdout, /Building the functions image: image was replaced by something else\./);
    assert.equal(run(f).builds, '');
  } finally { cleanup(f); }
});

test('a failed build records nothing, so the next run builds again', () => {
  const f = fixture();
  try {
    assert.equal(run(f).status, 0);
    const before = readFileSync(f.record, 'utf8');
    writeFileSync(join(f.root, 'docker/functions/Dockerfile'), 'FROM example.invalid/functions:2\n');
    const failed = run(f, { fail: 'build' });
    assert.notEqual(failed.status, 0);
    assert.match(failed.stderr, /Image build failed\. No service was started or stopped by this step, and nothing\nof this run was recorded as built\./);
    assert.equal(readFileSync(f.record, 'utf8'), before);
    assert.equal(run(f).builds, 'functions');
  } finally { cleanup(f); }
});

test('the plan fails closed: a broken Compose configuration or an unreadable recipe builds nothing', { skip: process.getuid?.() === 0 && 'root reads every directory' }, () => {
  const f = fixture();
  try {
    const noConfig = run(f, { fail: 'config' });
    assert.notEqual(noConfig.status, 0);
    assert.match(noConfig.stderr, /Could not read the Compose configuration\./);
    assert.equal(noConfig.builds, '');
    const closed = join(f.root, 'docker/postgres/closed');
    mkdirSync(closed, { mode: 0o000 });
    const unreadable = run(f);
    chmodSync(closed, 0o700);
    assert.notEqual(unreadable.status, 0);
    assert.match(unreadable.stderr, /Cannot read the build recipe of the db image: .*closed/);
    assert.match(unreadable.stderr, /Could not work out which images to rebuild\./);
    assert.doesNotMatch(unreadable.stderr, /\n\s+at /, 'no stack trace');
    assert.equal(unreadable.builds, '');
    assert.equal(existsSync(f.record), false);
  } finally { cleanup(f); }
});

test('--all and --no-cache rebuild every image in use; anything else is refused', () => {
  const f = fixture();
  try {
    assert.equal(run(f).status, 0);
    assert.equal(run(f, { args: ['--all'] }).builds, 'db functions');
    assert.equal(run(f, { args: ['--no-cache'] }).builds, '--no-cache db functions');
    for (const args of [['--pull'], ['--all', '--no-cache']]) {
      const refused = run(f, { args });
      assert.notEqual(refused.status, 0);
      assert.match(refused.stderr, /Usage: bash scripts\/build-images\.sh/);
      assert.equal(refused.builds, '');
    }
  } finally { cleanup(f); }
});

// What setup.sh leaves behind: every image built from this checkout and recorded.
const builtAll = f => {
  const containers = 'db functions supavisor sensor-bridge kong';
  assert.equal(run(f, { containers }).status, 0);
  return containers;
};

test('--replace-optional starts only the optional services that are running, and builds nothing', () => {
  const f = fixture();
  try {
    const containers = builtAll(f);
    const none = run(f, { args: ['--replace-optional'], containers, running: 'db functions kong' });
    assert.equal(none.status, 0, none.stderr);
    assert.equal(none.ups, '');
    const some = run(f, { args: ['--replace-optional'], containers, running: 'db supavisor sensor-bridge kong' });
    assert.equal(some.status, 0, some.stderr);
    assert.equal(some.ups, '--wait --wait-timeout 180 sensor-bridge supavisor');
    assert.equal(some.builds, '');
    assert.match(some.stdout, /Optional services that are running: sensor-bridge supavisor\./);
    // An image of this project that has no build record yet (`compose build` by the pooler
    // check, an installation from before the record) is still replaced.
    rmSync(f.record);
    const unrecorded = run(f, { args: ['--replace-optional'], containers, running: 'sensor-bridge supavisor' });
    assert.equal(unrecorded.status, 0, unrecorded.stderr);
    assert.equal(unrecorded.ups, '--wait --wait-timeout 180 sensor-bridge supavisor');
    const failed = run(f, { args: ['--replace-optional'], containers, running: 'supavisor', fail: 'up' });
    assert.notEqual(failed.status, 0);
    assert.match(failed.stderr, /An optional service did not start \(supavisor\)\. The core services are not affected/);
  } finally { cleanup(f); }
});

test('--replace-optional leaves a running optional service alone when its image is missing: start never builds', () => {
  const f = fixture();
  try {
    const containers = builtAll(f);
    // An upgrade renamed the image (a shared tag became `<project>-sensor-bridge`), or it was removed.
    rmSync(join(f.scratch, 'images', imageFile(`${PROJECT}-sensor-bridge`)));
    const result = run(f, { args: ['--replace-optional'], containers, running: 'db supavisor sensor-bridge kong' });
    assert.equal(result.status, 1, 'start.sh turns this into a warning');
    assert.equal(result.builds, '');
    assert.equal(result.ups, '--wait --wait-timeout 180 supavisor', 'the others are still replaced');
    assert.match(result.stderr, /the sensor-bridge image does not match this checkout \(image missing\); run `bash scripts\/build-images\.sh`/);
  } finally { cleanup(f); }
});

test('--replace-optional leaves a running optional service alone when its image was replaced by something else', () => {
  const f = fixture();
  try {
    const containers = builtAll(f);
    // Another checkout, a manual build: the tag names an image this checkout did not record.
    writeFileSync(join(f.scratch, 'images', imageFile(`${PROJECT}-sensor-bridge`)), `sha256:${'9'.repeat(64)}\n`);
    const result = run(f, { args: ['--replace-optional'], containers, running: 'sensor-bridge' });
    assert.equal(result.status, 1);
    assert.equal(result.builds, '');
    assert.equal(result.ups, '', 'nothing else is running, so nothing is started');
    assert.match(result.stderr, /the sensor-bridge image does not match this checkout \(image was replaced by something else\); run `bash scripts\/build-images\.sh`/);
    // The image setup.sh builds next puts it right.
    assert.equal(run(f, { containers }).builds, 'sensor-bridge');
    const after = run(f, { args: ['--replace-optional'], containers, running: 'sensor-bridge' });
    assert.equal(after.status, 0, after.stderr);
    assert.equal(after.ups, '--wait --wait-timeout 180 sensor-bridge');
  } finally { cleanup(f); }
});

test('it runs under the lock of the command that called it and refuses while another command holds the lock', () => {
  const f = fixture();
  try {
    // $1 is the script, $2 the lock file. Descriptor 9 is what setup.sh passes on.
    const inherited = run(f, { wrap: 'exec 9>"$2"; flock -n 9 || exit 70; bash "$1"' });
    assert.equal(inherited.status, 0, inherited.stderr);
    assert.equal(inherited.builds, 'db functions');
    const held = run(f, { wrap: 'exec 8>"$2"; flock -n 8 || exit 70; bash "$1"' });
    assert.notEqual(held.status, 0);
    assert.notEqual(held.status, 70);
    assert.match(held.stderr, /Another operator command/);
    assert.equal(held.builds, '');
  } finally { cleanup(f); }
});

test('setup.sh builds before its first start; setup.sh and start.sh replace optional services after their start', () => {
  const lines = name => readFileSync(join(repo, name), 'utf8').split('\n');
  const setup = lines('setup.sh');
  // The exact line, not commented out and without anything that would hide a failed build.
  const buildStep = setup.indexOf('bash "$ROOT/scripts/build-images.sh"');
  const firstStart = setup.findIndex(line => line.includes('compose.sh" up -d'));
  assert.ok(buildStep > 0 && buildStep < firstStart, 'setup.sh builds before the first start');
  for (const [name, script] of [['setup.sh', setup], ['start.sh', lines('start.sh')]]) {
    const fullStart = script.indexOf('bash "$ROOT/scripts/compose.sh" up -d --remove-orphans --wait --wait-timeout 180');
    const replace = script.findIndex(line => line.startsWith('bash "$ROOT/scripts/build-images.sh" --replace-optional'));
    assert.ok(fullStart > 0 && replace > fullStart, `${name} replaces optional services after the full start`);
  }
  assert.ok(!lines('start.sh').includes('bash "$ROOT/scripts/build-images.sh"'), 'start.sh never builds');
});

test('every recipe is its own build directory', () => {
  // A context of `.` would put every file under docker/ into one image's fingerprint.
  assert.doesNotMatch(readFileSync(join(repo, 'docker/docker-compose.yml'), 'utf8'), /^\s+context: \.$/m);
});

test('the PDF renderer image is pinned, verified and minimal', () => {
  // docker/pdf-renderer/Dockerfile downloads chrome-headless-shell from Chrome for Testing at
  // build time. Trivy cannot see that binary, so the version and the archive checksum are the
  // controls: both are build args, the checksum is checked, and nothing floats.
  const recipe = readFileSync(join(repo, 'docker/pdf-renderer/Dockerfile'), 'utf8');
  const instructions = recipe.replace(/\\\n/g, ' ').split('\n').filter(line => !line.trim().startsWith('#'));
  const text = instructions.join('\n');
  assert.match(recipe, /^FROM node:24-trixie-slim@sha256:[0-9a-f]{64} AS base$/m, 'the base is one literal FROM (Dependabot reads it): Node 24 LTS on Debian trixie, pinned by digest');
  assert.equal([...recipe.matchAll(/^FROM node:/gm)].length, 1, 'the digest is written once');
  assert.deepEqual(instructions.filter(line => /^FROM /.test(line) && !/^FROM base AS \S+$/.test(line) && !/@sha256:[0-9a-f]{64}/.test(line)), [], 'every other stage starts from the digest-pinned base');
  const version = /^ARG CHS_VERSION=(\d+\.\d+\.\d+\.\d+)$/m.exec(recipe)?.[1];
  const sha = /^ARG CHS_SHA256=([0-9a-f]{64})$/m.exec(recipe)?.[1];
  assert.ok(version, 'ARG CHS_VERSION has a four-part default');
  assert.ok(sha, 'ARG CHS_SHA256 has a SHA-256 default');
  assert.match(text, /sha256sum -c -/, 'the downloaded archive is checked against CHS_SHA256');
  assert.match(text, /\$\{?CHS_SHA256\}?/);
  assert.match(text, /storage\.googleapis\.com\/chrome-for-testing-public\/\$\{?CHS_VERSION\}?\//, 'the archive URL is built from CHS_VERSION');
  assert.doesNotMatch(text, /@stable|\blatest\b|last-known-good/, 'no floating Chrome channel or tag');
  // Debian security revisions are removed from the archive; an exact pin would break the build. The font-file
  // hash (FONT_FILELIST_SHA256) and the golden-PDF job are the drift guards instead.
  for (const install of text.split('\n').filter(line => /apt-get install/.test(line))) assert.doesNotMatch(install, /\s[a-z0-9.+-]+=\d/, 'apt packages are named without versions');
  assert.match(text, /ARG FONT_FILELIST_SHA256=[0-9a-f]{64}/);
  assert.match(text, /npm ci --omit=dev --ignore-scripts/);
  assert.match(text, /rm -rf [^\n]*(?:\/npm|corepack|yarn)/, 'npm, corepack and yarn are removed');
  assert.match(text, /\btini\b/, 'tini is installed');
  assert.match(recipe, /^ENTRYPOINT \[[^\]]*"(?:\/usr\/bin\/)?tini"/m, 'tini is PID 1');
  const user = [...recipe.matchAll(/^USER (\S+)$/gm)].map(match => match[1]).pop();
  assert.ok(user && !/^(?:0|root)(?::|$)/.test(user), `the image runs as a non-root user (${user})`);
  assert.match(recipe, /TARGETARCH/, 'the build checks the architecture');
  assert.match(text, /amd64/, 'only amd64 builds (the Chrome for Testing archive is linux64)');
  const pkg = JSON.parse(readFileSync(join(repo, 'docker/pdf-renderer/package.json'), 'utf8'));
  assert.match(pkg.dependencies['puppeteer-core'], /^\d+\.\d+\.\d+$/, 'puppeteer-core is pinned exactly');
  const dependabot = readFileSync(join(repo, '.github/dependabot.yml'), 'utf8');
  assert.match(dependabot, /package-ecosystem: npm\n\s+directory: "\/docker\/pdf-renderer"/);
});

test('no built service names its own image: Compose tags each `<project>-<service>`, so installations never share one', () => {
  // A fixed tag (one was `warehouse-<service>:local`) is shared by every
  // installation on the host: one checkout's build replaced another's running image.
  for (const file of ['docker/docker-compose.yml']) {
    const text = readFileSync(join(repo, file), 'utf8');
    const blocks = text.split(/\n(?=  [a-z][a-z0-9-]*:\n)/);
    for (const block of blocks.filter(item => /^    build:/m.test(item))) {
      assert.doesNotMatch(block, /^    image:/m, `${file}: ${block.split('\n')[0].trim()} has both build: and image:`);
    }
  }
});
