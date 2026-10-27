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
//   pull --quiet REF                logged; gives the reference an image ID and its repository digest (fails for the services in FAKE_FAIL_PULL;
//                                   FAKE_WRONG_DIGEST names those whose image carries another digest than the one asked for)
//   tag SOURCE TARGET               logged; the target names the source's image
//   push TARGET                     logged; answers with a digest made from the target (fails for FAKE_FAIL_PUSH, answers without one for FAKE_PUSH_NO_DIGEST)
//   build ... --label L --tag T -   (the publish script's labelling build, the Dockerfile on standard input `FROM X`) logged with the labels; T becomes a
//                                   new image with X's layers and the labels (other layers for FAKE_RELABEL_LAYERS=changed, a failure for FAKE_FAIL_RELABEL=yes)
//   image inspect --format ... IMAGE  also answers the revision label ({{index .Config.Labels ...}}) and the layers ({{json .RootFS.Layers}}); a pulled image
//                                   carries the checkout's commit (FAKE_ROOT) unless its service is in FAKE_WRONG_REVISION (another commit) or FAKE_NO_REVISION (no label)
//   buildx imagetools create --prefer-index=false --tag T SOURCE / inspect T --format ...   the pre-release retag: T gets SOURCE's digest (FAKE_RETAG_DIGEST
//                                   names services that get another one, FAKE_FAIL_RETAG services whose retag fails); both logged to retag.log
// and a fake mktemp that fails for the download of release-images.json (FAKE_MKTEMP_FAIL=yes), a fake gh that serves `release download TAG` from rc-lists/TAG.json in the scratch directory, a fake uname (FAKE_ARCH) and, for FAKE_PULL_HANG services,
// a pull that does not return.
// and a fake curl that serves release-images.json from the scratch directory (FAKE_CURL=http404 fails like a missing release).
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
  services.rest = { image: 'postgrest/postgrest:v16.4' };
  const config = join(scratch, 'config.json');
  const writeConfig = () => writeFileSync(config, JSON.stringify({ name: PROJECT, services }));
  writeConfig();
  mkdirSync(join(scratch, 'images'));
  mkdirSync(join(scratch, 'digests'));
  for (const dir of ['labels', 'layers', 'registry', 'rc-lists']) mkdirSync(join(scratch, dir));
  const bin = join(scratch, 'bin');
  mkdirSync(bin, { mode: 0o700 });
  writeFileSync(join(bin, 'curl'), `#!/bin/sh
out=''; prev=''
for arg; do if [ "$prev" = --output ]; then out="$arg"; fi; prev="$arg"; done
printf '%s\\n' "$*" >> "$FAKE_DIR/curl.log"
if [ "$FAKE_CURL" = http404 ]; then echo 'curl: (22) The requested URL returned error: 404' >&2; exit 22; fi
cp "$FAKE_DIR/release-images.json" "$out"
`, { mode: 0o700 });
  writeFileSync(join(bin, 'uname'), `#!/bin/sh
if [ -n "$FAKE_ARCH" ] && [ "$1" = -m ]; then echo "$FAKE_ARCH"; exit 0; fi
exec /usr/bin/uname "$@"
`, { mode: 0o700 });
  writeFileSync(join(bin, 'mktemp'), `#!/bin/sh
if [ "$FAKE_MKTEMP_FAIL" = yes ]; then case "$*" in *.release-images.*) echo 'mktemp: failed to create file: Read-only file system' >&2; exit 1 ;; esac; fi
exec /usr/bin/mktemp "$@"
`, { mode: 0o700 });
  writeFileSync(join(bin, 'gh'), `#!/bin/sh
printf '%s\\n' "$*" >> "$FAKE_DIR/gh.log"
[ "$1 $2" = 'release download' ] || { echo "unexpected gh call: $*" >&2; exit 2; }
tag="$3"; out=''; prev=''
for arg; do if [ "$prev" = --output ]; then out="$arg"; fi; prev="$arg"; done
[ -f "$FAKE_DIR/rc-lists/$tag.json" ] || { echo "release not found" >&2; exit 1; }
cp "$FAKE_DIR/rc-lists/$tag.json" "$out"
`, { mode: 0o700 });
  writeFileSync(join(bin, 'docker'), `#!/bin/sh
file() { printf '%s' "$1" | tr '/:' '__'; }
head_commit() { git -C "$FAKE_ROOT" rev-parse HEAD 2>/dev/null; }
case "$1" in
  ps)
    case "$2" in
      -aq) exit 0 ;;
      -a) for service in $FAKE_CONTAINERS; do echo "$service"; done ;;
      *) for service in $FAKE_RUNNING; do echo "$service"; done ;;
    esac ;;
  image)
    if [ "$4" = '{{.Size}}' ]; then echo 1000
    elif [ "$4" = '{{range .RepoDigests}}{{println .}}{{end}}' ]; then cat "$FAKE_DIR/digests/$(file "$5")" 2>/dev/null || exit 1
    elif [ "$4" = '{{index .Config.Labels "org.opencontainers.image.revision"}}' ]; then cat "$FAKE_DIR/labels/$(file "$5")" 2>/dev/null || exit 1
    elif [ "$4" = '{{json .RootFS.Layers}}' ]; then cat "$FAKE_DIR/layers/$(file "$5")" 2>/dev/null || cat "$FAKE_DIR/images/$(file "$5")" 2>/dev/null || exit 1
    else cat "$FAKE_DIR/images/$(file "$5")" 2>/dev/null || exit 1; fi ;;
  pull)
    echo "$3" >> "$FAKE_DIR/pull.log"
    service=$(printf '%s' "$3" | sed 's|.*/\\([^@]*\\)@.*|\\1|')
    case " $FAKE_PULL_HANG " in *" $service "*) exec sleep 30 ;; esac
    case " $FAKE_FAIL_PULL " in *" $service "*) echo 'Error response from daemon: manifest unknown' >&2; exit 1 ;; esac
    count=$(( $(cat "$FAKE_DIR/counter" 2>/dev/null || echo 100) + 1 )); echo "$count" > "$FAKE_DIR/counter"
    printf 'sha256:%064d\\n' "$((count + 5000))" > "$FAKE_DIR/images/$(file "$3")"
    case " $FAKE_WRONG_REVISION " in *" $service "*) printf 'b%.0s' $(seq 1 40) > "$FAKE_DIR/labels/$(file "$3")" ;; *) case " $FAKE_NO_REVISION " in *" $service "*) : > "$FAKE_DIR/labels/$(file "$3")" ;; *) head_commit > "$FAKE_DIR/labels/$(file "$3")" ;; esac ;; esac
    case " $FAKE_WRONG_DIGEST " in
      *" $service "*) printf '%s@sha256:%064d\\n' "\${3%%@*}" 7 > "$FAKE_DIR/digests/$(file "$3")" ;;
      *) printf '%s\\n' "$3" > "$FAKE_DIR/digests/$(file "$3")" ;;
    esac
    echo "$3" ;;
  tag)
    echo "$2 $3" >> "$FAKE_DIR/tag.log"; cp "$FAKE_DIR/images/$(file "$2")" "$FAKE_DIR/images/$(file "$3")"
    for kind in labels layers; do if [ -f "$FAKE_DIR/$kind/$(file "$2")" ]; then cp "$FAKE_DIR/$kind/$(file "$2")" "$FAKE_DIR/$kind/$(file "$3")"; fi; done ;;
  build)
    base=$(sed -n 's/^FROM //p'); target=''; labels=''; prev=''
    for arg; do
      case "$prev" in --tag) target="$arg" ;; --label) labels="$labels $arg" ;; esac
      prev="$arg"
    done
    echo "$* | FROM $base" >> "$FAKE_DIR/relabel.log"
    if [ "$FAKE_FAIL_RELABEL" = yes ]; then echo 'ERROR: failed to solve' >&2; exit 1; fi
    count=$(( $(cat "$FAKE_DIR/counter" 2>/dev/null || echo 100) + 1 )); echo "$count" > "$FAKE_DIR/counter"
    # Layers of the base unless the stand-in is told to change them; labels as given.
    if [ "$FAKE_RELABEL_LAYERS" = changed ]; then echo '["sha256:other"]' > "$FAKE_DIR/layers/$(file "$target")"
    else cp "$FAKE_DIR/layers/$(file "$base")" "$FAKE_DIR/layers/$(file "$target")" 2>/dev/null || cp "$FAKE_DIR/images/$(file "$base")" "$FAKE_DIR/layers/$(file "$target")"; fi
    printf 'sha256:%064d\\n' "$((count + 9000))" > "$FAKE_DIR/images/$(file "$target")"
    for label in $labels; do case "$label" in org.opencontainers.image.revision=*) printf '%s' "\${label#*=}" > "$FAKE_DIR/labels/$(file "$target")" ;; esac; done ;;
  buildx)
    # docker buildx imagetools create --prefer-index=false --tag T SOURCE | inspect T --format F
    case "$3" in
      create)
        echo "$*" >> "$FAKE_DIR/retag.log"
        target="$6"; source="$7"; service=$(printf '%s' "$source" | sed 's|.*/\\([^@]*\\)@.*|\\1|')
        [ "$4" = --prefer-index=false ] || { echo 'carbon copy not asked for' >&2; exit 3; }
        case " $FAKE_FAIL_RETAG " in *" $service "*) echo 'denied: permission_denied: write_package' >&2; exit 1 ;; esac
        case " $FAKE_RETAG_DIGEST " in *" $service "*) printf 'sha256:%064d' 99 > "$FAKE_DIR/registry/$(file "$target")" ;; *) printf '%s' "\${source##*@}" > "$FAKE_DIR/registry/$(file "$target")" ;; esac ;;
      inspect) echo "$*" >> "$FAKE_DIR/retag.log"; cat "$FAKE_DIR/registry/$(file "$4")" 2>/dev/null || { echo 'not found' >&2; exit 1; } ;;
    esac ;;
  push)
    echo "$2" >> "$FAKE_DIR/push.log"
    service=$(printf '%s' "$2" | sed 's|.*/\\([^:]*\\):.*|\\1|')
    case " $FAKE_FAIL_PUSH " in *" $service "*) echo 'denied: permission_denied: write_package' >&2; exit 1 ;; esac
    echo "The push refers to repository [\${2%%:*}]"
    echo 'a1b2c3d4e5f6: Pushed'
    if [ "$FAKE_PUSH_NO_DIGEST" != yes ]; then echo "\${2##*:}: digest: sha256:$(printf '%s' "$2" | sha256sum | cut -d' ' -f1) size: 1234"; fi ;;
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
  for (const log of ['build.log', 'up.log', 'curl.log', 'pull.log', 'tag.log', 'push.log']) writeFileSync(join(scratch, log), '');
  const script = join(root, 'scripts/build-images.sh');
  const command = wrap ? ['bash', ['-c', wrap, 'wrap', script, join(state, 'config/operator.lock')]] : ['bash', [script, ...args]];
  const result = spawnSync(...command, {
    encoding: 'utf8',
    env: { ...process.env, PATH: `${join(scratch, 'bin')}:${process.env.PATH}`, WAREHOUSE_STATE_DIR: state, FAKE_DIR: scratch, FAKE_ROOT: root,
      FAKE_CONTAINERS: containers, FAKE_RUNNING: running, [`FAKE_FAIL_${fail.toUpperCase()}`]: 'yes',
      // The disk of the machine running the tests decides nothing: the 5 GiB reserve is lifted unless a test sets it.
      WAREHOUSE_IMAGE_SAVE_RESERVE: '0', ...env },
  });
  const log = name => readFileSync(join(scratch, name), 'utf8').trim();
  return { ...result, builds: log('build.log'), ups: log('up.log'), curls: log('curl.log'), pulls: log('pull.log'), tags: log('tag.log'), pushes: log('push.log') };
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

test('gateway-lan runs the gateway\'s image (M4 of the review of WS-L): it is never built, recorded or saved on its own, and it is not replaced by the optional step', () => {
  const f = fixture();
  try {
    // As docker/docker-compose.yml: the gateway is built; gateway-lan names the tag Compose gives that build and has no `build` of its own.
    const dir = join(f.root, 'docker/nginx');
    mkdirSync(dir, { recursive: true });
    writeFileSync(join(dir, 'Dockerfile'), 'FROM example.invalid/nginx:1\n');
    f.services.gateway = { build: { context: dir, dockerfile: 'Dockerfile' } };
    f.services['gateway-lan'] = { image: `${PROJECT}-gateway`, pull_policy: 'never', profiles: ['lan'] };
    f.writeConfig();
    // A first installation, with a gateway-lan container already on this host (the fallback was on before the upgrade): the gateway image is built once.
    const first = run(f, { containers: 'gateway-lan', running: 'gateway-lan' });
    assert.equal(first.status, 0, first.stderr);
    assert.equal(first.builds, 'db functions gateway', 'one build of the gateway recipe, none for gateway-lan');
    assert.deepEqual(recorded(f.record).map(line => line[1]), ['db', 'functions', 'gateway'], 'nothing is recorded under gateway-lan');
    assert.deepEqual(tarballs(f).filter(name => name.endsWith('.tar')), ['db.tar', 'functions.tar', 'gateway.tar'], 'one saved image serves both services');
    // --all rebuilds the image once as well. The recipe changing reaches gateway-lan through the same image: one build, one record.
    writeFileSync(join(dir, 'Dockerfile'), 'FROM example.invalid/nginx:2\n');
    const changed = run(f, { containers: 'gateway-lan', running: 'gateway-lan' });
    assert.equal(changed.status, 0, changed.stderr);
    assert.equal(changed.builds, 'gateway', 'an upgrade that changes the nginx recipe rebuilds the one image the fallback runs');
    assert.match(changed.stdout, /Building the gateway image: recipe changed\./);
    const all = run(f, { args: ['--all'], containers: 'gateway-lan', running: 'gateway-lan' });
    assert.equal(all.builds, 'db functions gateway');
    assert.deepEqual(recorded(f.record).map(line => line[1]), ['db', 'functions', 'gateway']);
    // The step that replaces running optional services does not take gateway-lan: scripts/lan.sh start starts it (and its failure is its own warning).
    const replace = run(f, { args: ['--replace-optional'], running: 'gateway-lan supavisor' });
    assert.equal(replace.status, 0, replace.stderr);
    assert.match(replace.stdout, /Optional services that are running: supavisor\./);
    assert.equal(replace.ups, '--wait --wait-timeout 180 supavisor', 'only supavisor is started or replaced (the log keeps what follows `up -d`)');
    const onlyLan = run(f, { args: ['--replace-optional'], running: 'gateway-lan' });
    assert.equal(onlyLan.status, 0, onlyLan.stderr);
    assert.equal(onlyLan.ups, '', 'nothing to replace');
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
    const containers = 'db functions supavisor rest';
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
  const containers = 'db functions supavisor sensor-bridge rest';
  assert.equal(run(f, { containers }).status, 0);
  return containers;
};

test('--replace-optional starts only the optional services that are running, and builds nothing', () => {
  const f = fixture();
  try {
    const containers = builtAll(f);
    const none = run(f, { args: ['--replace-optional'], containers, running: 'db functions rest' });
    assert.equal(none.status, 0, none.stderr);
    assert.equal(none.ups, '');
    const some = run(f, { args: ['--replace-optional'], containers, running: 'db supavisor sensor-bridge rest' });
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
    const result = run(f, { args: ['--replace-optional'], containers, running: 'db supavisor sensor-bridge rest' });
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
  const buildStep = setup.indexOf('bash "$ROOT/scripts/build-images.sh" --from-release');
  const firstStart = setup.findIndex(line => line.includes('compose.sh" up -d'));
  assert.ok(buildStep > 0 && buildStep < firstStart, 'setup.sh builds before the first start');
  for (const [name, script] of [['setup.sh', setup], ['start.sh', lines('start.sh')]]) {
    // The full start leaves the LAN fallback out and waits for the public services only (WAREHOUSE_COMPOSE_WITHOUT_LAN); lan.sh starts it
    // on its own, before the optional services are replaced (tests/lan-switch.test.mjs).
    const fullStart = script.indexOf('WAREHOUSE_COMPOSE_WITHOUT_LAN=1 bash "$ROOT/scripts/compose.sh" up -d --remove-orphans --wait --wait-timeout 180');
    const lanStart = script.findIndex(line => line.startsWith('bash "$ROOT/scripts/lan.sh" start'));
    const replace = script.findIndex(line => line.startsWith('bash "$ROOT/scripts/build-images.sh" --replace-optional'));
    assert.ok(fullStart > 0 && lanStart === fullStart + 1 && replace > lanStart, `${name} replaces optional services after the full start and the LAN start`);
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

// ---------------------------------------------------------------- release images: published by the release workflow, pulled by digest
// scripts/build-images.sh --from-release against a checkout that is (or is not) at a release tag, a fake curl that serves
// release-images.json and a fake docker that pulls. The file is made with scripts/image-recipes.mjs manifest from the fixture's tree,
// so its fingerprints are the ones a facility with that tree computes.
const REGISTRY = 'ghcr.io/abhiguru/supabase-warehouse-template';
const refOf = service => `${REGISTRY}/${service}@sha256:${sha(service)}`;
function git(f, ...args) {
  const result = spawnSync('git', ['-C', f.root, '-c', 'user.name=Release Test', '-c', 'user.email=release@example.invalid', '-c', 'commit.gpgsign=false', '-c', 'tag.gpgsign=false', ...args], { encoding: 'utf8' });
  assert.equal(result.status, 0, result.stderr);
  return result.stdout.trim();
}
// The checkout is a git repository whose one commit carries the tag(s).
function atTag(f, ...names) {
  git(f, 'init', '-q');
  git(f, 'add', '-A');
  git(f, 'commit', '-q', '-m', 'release');
  for (const name of names) git(f, 'tag', name);
}
// What the maintainer's recipe check recomputes: the hash over "<fingerprint>  <service>" lines, in service order.
const recipesOf = images => sha(Object.entries(images).sort(([a], [b]) => a.localeCompare(b)).map(([service, { fingerprint }]) => `${fingerprint}  ${service}\n`).join(''));
function releaseFile(f, tag = 'v1.2.3', change) {
  const refs = Object.entries(f.services).filter(([, definition]) => definition.build).map(([service]) => `${service}=${refOf(service)}`);
  const made = spawnSync('node', [join(f.root, 'scripts/image-recipes.mjs'), 'manifest', tag, git(f, 'rev-parse', 'HEAD'), ...refs], { input: readFileSync(join(f.scratch, 'config.json')), encoding: 'utf8' });
  assert.equal(made.status, 0, made.stderr);
  const manifest = JSON.parse(made.stdout);
  if (change) { change(manifest); manifest.recipes = recipesOf(manifest.images); }
  writeFileSync(join(f.scratch, 'release-images.json'), JSON.stringify(manifest));
  return manifest;
}
const URL_OF = tag => `https://github.com/abhiguru/supabase-warehouse-template/releases/download/${tag}/release-images.json`;
const FROM_RELEASE = { args: ['--from-release'] };

test('--from-release at a release tag pulls each image that needs building by digest, checks it, tags and records it as a build would, saves it, and builds nothing', () => {
  const f = fixture();
  try {
    atTag(f, 'v1.2.3');
    const manifest = releaseFile(f);
    const result = run(f, FROM_RELEASE);
    assert.equal(result.status, 0, result.stderr);
    assert.equal(result.builds, '', 'nothing is built');
    assert.equal(result.pulls, `${refOf('db')}\n${refOf('functions')}`, 'by digest, only the images that need building (the optional ones have no container)');
    assert.equal(result.tags, `${refOf('db')} ${PROJECT}-db\n${refOf('functions')} ${PROJECT}-functions`, 'tagged as Compose tags a build');
    assert.match(result.stdout, new RegExp(`Pulled the db image from release v1\\.2\\.3: image missing \\(${refOf('db').replace(/[.]/g, '\\.')}\\)\\.`));
    assert.match(result.stdout, /Pulled 2 image\(s\) from the release \(db functions\) and built 0 here \(none\)\./);
    // The URL is the release's asset over https, and the call refuses anything else.
    assert.equal(result.curls.split('\n').length, 1);
    assert.match(result.curls, /^--fail .*--proto =https --proto-redir =https --tlsv1\.2 --max-time 60 --max-filesize \d+ --output \S+ https:\/\/github\.com\/abhiguru\/supabase-warehouse-template\/releases\/download\/v1\.2\.3\/release-images\.json$/);
    assert.deepEqual(readdirSync(join(f.state, 'config')).filter(name => name.startsWith('.release-images')), [], 'the download is removed');
    // Recorded with the recipe's fingerprint and the pulled image's ID, like a build; saved and signed like a build.
    const lines = recorded(f.record);
    assert.deepEqual(lines.map(line => [line[0], line[1]]), [[manifest.images.db.fingerprint, 'db'], [manifest.images.functions.fingerprint, 'functions']]);
    for (const [, , id] of lines) assert.match(id, /^sha256:0*5\d{3}$/, 'the ID of the pulled image');
    assert.deepEqual(tarballs(f), [...SIGNED, 'db.tar', 'functions.tar', 'image-recipes.sha256']);
    assert.deepEqual(authenticate(f), { ok: true, stderr: '' });
    // The record is as good as a build's: the next run finds nothing to do, and does not ask the network.
    const again = run(f, FROM_RELEASE);
    assert.equal(again.status, 0, again.stderr);
    assert.match(again.stdout, /Images match their recipes; nothing to rebuild\./);
    assert.equal(again.curls, ''); assert.equal(again.pulls, '');
  } finally { cleanup(f); }
});

test('--from-release: a recipe that differs from the released one is built here, the others are pulled', () => {
  const f = fixture();
  try {
    atTag(f, 'v1.2.3');
    releaseFile(f);
    // This checkout's functions recipe is not the released one (a local change below docker/functions).
    writeFileSync(join(f.root, 'docker/functions/Dockerfile'), 'FROM example.invalid/functions:changed\n');
    const result = run(f, FROM_RELEASE);
    assert.equal(result.status, 0, result.stderr);
    assert.equal(result.pulls, refOf('db'));
    assert.equal(result.builds, 'functions');
    assert.match(result.stdout, /Building the functions image: image missing; not taken from release v1\.2\.3: its recipe differs from the release's/);
    assert.match(result.stdout, /Pulled 1 image\(s\) from the release \(db\) and built 1 here \(functions\)\./);
    assert.deepEqual(recorded(f.record).map(line => line[1]), ['db', 'functions']);
    assert.deepEqual(tarballs(f), [...SIGNED, 'db.tar', 'functions.tar', 'image-recipes.sha256'], 'a pulled and a built image are both saved');
    // A service the release has no image of is built too.
    const f2 = fixture();
    try {
      atTag(f2, 'v1.2.3');
      releaseFile(f2, 'v1.2.3', manifest => { delete manifest.images.functions; });
      const missing = run(f2, FROM_RELEASE);
      assert.equal(missing.pulls, refOf('db'));
      assert.equal(missing.builds, 'functions');
      assert.match(missing.stdout, /not taken from release v1\.2\.3: the release has no image of it/);
    } finally { cleanup(f2); }
  } finally { cleanup(f); }
});

test('--from-release: a download that fails builds everything and says why in one line', () => {
  const f = fixture();
  try {
    atTag(f, 'v1.2.3');
    releaseFile(f);
    const result = run(f, { ...FROM_RELEASE, env: { FAKE_CURL: 'http404' } });
    assert.equal(result.status, 0, result.stderr);
    assert.equal(result.builds, 'db functions');
    assert.equal(result.pulls, '');
    assert.match(result.stdout, new RegExp(`Not pulling the images of release v1\\.2\\.3: ${URL_OF('v1.2.3').replace(/[./]/g, '\\$&')} could not be fetched \\(curl: \\(22\\) The requested URL returned error: 404\\), so the images are built here\\.`));
    assert.match(result.stdout, /Pulled 0 image\(s\) from the release \(none\) and built 2 here \(db functions\)\./);
    assert.deepEqual(readdirSync(join(f.state, 'config')).filter(name => name.startsWith('.release-images')), [], 'no download is left');
  } finally { cleanup(f); }
});

test('--from-release never asks the network when this checkout is not exactly at a release tag, or when nothing needs building', () => {
  const f = fixture();
  try {
    // Not a git checkout at all (a development copy).
    const plain = run(f, FROM_RELEASE);
    assert.equal(plain.status, 0, plain.stderr);
    assert.equal(plain.curls, ''); assert.equal(plain.pulls, '');
    assert.equal(plain.builds, 'db functions');
    assert.match(plain.stdout, /Not pulling release images: this checkout is not at a release tag, so the images are built here\./);
    // A commit after the tag (main, a branch): the tag is not at HEAD any more. Other tags do not count.
    atTag(f, 'v1.2.3', 'not-a-release');
    releaseFile(f);
    writeFileSync(join(f.root, 'later.txt'), 'a commit after the release\n');
    git(f, 'add', 'later.txt'); git(f, 'commit', '-q', '-m', 'later');
    rmSync(f.record); rmSync(join(f.state, 'images'), { recursive: true });
    const later = run(f, FROM_RELEASE);
    assert.equal(later.curls, ''); assert.equal(later.pulls, '');
    assert.equal(later.builds, 'db functions');
    assert.match(later.stdout, /this checkout is not at a release tag/);
    // At the tag, but every image matches its recipe already: no fetch.
    git(f, 'checkout', '-q', 'v1.2.3');
    const current = run(f, FROM_RELEASE);
    assert.equal(current.status, 0, current.stderr);
    assert.equal(current.curls, ''); assert.equal(current.pulls, '');
    assert.match(current.stdout, /Images match their recipes; nothing to rebuild\./);
    // A tag that is not a release name (no leading v and digits) is not one either.
    git(f, 'tag', '-d', 'v1.2.3');
    rmSync(f.record);
    const named = run(f, FROM_RELEASE);
    assert.equal(named.curls, '');
    assert.match(named.stdout, /not at a release tag/);
  } finally { cleanup(f); }
});

test('--from-release uses the final release when a pre-release is tagged on the same commit, and writes a + build suffix as %2B', () => {
  const f = fixture();
  try {
    atTag(f, 'v1.2.3-rc.1', 'v1.2.3', 'v1.2.2');
    releaseFile(f, 'v1.2.3');
    const result = run(f, FROM_RELEASE);
    assert.equal(result.status, 0, result.stderr);
    assert.match(result.curls, new RegExp(`${URL_OF('v1.2.3').replace(/[./]/g, '\\$&')}$`));
    assert.equal(result.builds, '');
    // Only a pre-release tag: that one.
    const g = fixture();
    try {
      atTag(g, 'v1.2.3-rc.2', 'v1.2.3-rc.10');
      releaseFile(g, 'v1.2.3-rc.10');
      assert.match(run(g, FROM_RELEASE).curls, new RegExp(`/download/v1\\.2\\.3-rc\\.10/release-images\\.json$`), 'the highest by version order, not by text');
    } finally { cleanup(g); }
    const h = fixture();
    try {
      atTag(h, 'v1.2.3+build.5');
      releaseFile(h, 'v1.2.3+build.5');
      const built = run(h, FROM_RELEASE);
      assert.match(built.curls, /\/download\/v1\.2\.3%2Bbuild\.5\/release-images\.json$/);
      assert.equal(built.pulls, `${refOf('db')}\n${refOf('functions')}`);
    } finally { cleanup(h); }
  } finally { cleanup(f); }
});

test('--from-release: a pulled image that does not carry the released digest is refused and built; a pull that fails is built', () => {
  const f = fixture();
  try {
    atTag(f, 'v1.2.3');
    releaseFile(f);
    const wrong = run(f, { ...FROM_RELEASE, env: { FAKE_WRONG_DIGEST: 'db' } });
    assert.equal(wrong.status, 0, wrong.stderr);
    assert.match(wrong.stderr, new RegExp(`Warning: the pulled db image does not carry the digest sha256:${sha('db')} that release v1\\.2\\.3 names, so it is not used\\.`));
    assert.equal(wrong.builds, 'db');
    assert.equal(wrong.tags, `${refOf('functions')} ${PROJECT}-functions`, 'the refused image was never tagged as the project\'s');
    assert.match(wrong.stdout, /Building the db image: image missing; the release image could not be used\./);
    assert.deepEqual(recorded(f.record).map(line => line[1]), ['db', 'functions']);
    assert.match(recorded(f.record)[0][2], /^sha256:0*[1-9]\d{2}$/, 'the db image recorded is the one built here, not the refused one');
    // The pull itself fails (the package is private, offline).
    const g = fixture();
    try {
      atTag(g, 'v1.2.3');
      releaseFile(g);
      const failed = run(g, { ...FROM_RELEASE, env: { FAKE_FAIL_PULL: 'functions' } });
      assert.equal(failed.status, 0, failed.stderr);
      assert.match(failed.stderr, new RegExp(`Warning: could not pull the functions image of release v1\\.2\\.3 \\(${refOf('functions').replace(/[./]/g, '\\$&')}\\): Error response from daemon: manifest unknown`));
      assert.equal(failed.builds, 'functions');
      assert.equal(failed.tags, `${refOf('db')} ${PROJECT}-db`);
    } finally { cleanup(g); }
  } finally { cleanup(f); }
});

test('--from-release: a release-images.json that cannot be trusted is not used at all', () => {
  const f = fixture();
  try {
    atTag(f, 'v1.2.3');
    const cases = [
      ['another release', manifest => { manifest.release = 'v1.2.2'; }, /release-images\.json is not usable: it is for release "v1\.2\.2", not v1\.2\.3/],
      ['another commit', manifest => { manifest.commit = 'a'.repeat(40); }, /it names commit "a{40}", and this checkout is at [0-9a-f]{40}/],
      ['an image from another registry', manifest => { manifest.images.db.ref = `ghcr.io/someone-else/warehouse/db@sha256:${sha('db')}`; }, /the reference of db is not ghcr\.io\/abhiguru\/supabase-warehouse-template\/db@sha256:<digest>/],
      ['a reference of another service', manifest => { manifest.images.db.ref = refOf('functions'); }, /the reference of db is not /],
      ['a tag instead of a digest', manifest => { manifest.images.db.ref = `${REGISTRY}/db:v1.2.3`; }, /the reference of db is not /],
      ['a short digest', manifest => { manifest.images.db.ref = `${REGISTRY}/db@sha256:${'a'.repeat(63)}`; }, /the reference of db is not /],
      ['a fingerprint that is not a SHA-256', manifest => { manifest.images.db.fingerprint = 'not-a-hash'; }, /the recipe fingerprint of db is not a SHA-256/],
      ['no image', manifest => { manifest.images = {}; }, /it lists no image/],
    ];
    for (const [label, change, why] of cases) {
      releaseFile(f, 'v1.2.3', change);
      const result = run(f, FROM_RELEASE);
      assert.equal(result.status, 0, `${label}: ${result.stderr}`);
      assert.equal(result.pulls, '', `${label}: nothing pulled`);
      assert.equal(result.builds, 'db functions', label);
      assert.match(result.stdout, why, label);
      assert.match(result.stdout, /Not pulling the images of release v1\.2\.3: release-images\.json is not usable: .*; the images are built here\./, label);
      rmSync(f.record, { force: true });
    }
    // Edited after it was made: the recipes hash no longer matches the images it lists. Not JSON at all.
    releaseFile(f);
    const edited = JSON.parse(readFileSync(join(f.scratch, 'release-images.json'), 'utf8'));
    edited.images.db.fingerprint = 'f'.repeat(64);
    writeFileSync(join(f.scratch, 'release-images.json'), JSON.stringify(edited));
    const hash = run(f, FROM_RELEASE);
    assert.equal(hash.pulls, ''); assert.match(hash.stdout, /its recipes hash does not match the images it lists/);
    rmSync(f.record, { force: true });
    writeFileSync(join(f.scratch, 'release-images.json'), '<html>Not Found</html>');
    const html = run(f, FROM_RELEASE);
    assert.equal(html.pulls, ''); assert.equal(html.builds, 'db functions');
    assert.match(html.stdout, /release-images\.json cannot be read: /);
  } finally { cleanup(f); }
});

test('without --from-release nothing is fetched or pulled, whatever the tag; the option takes no other option', () => {
  const f = fixture();
  try {
    atTag(f, 'v1.2.3');
    releaseFile(f);
    const plain = run(f);
    assert.equal(plain.status, 0, plain.stderr);
    assert.equal(plain.curls, ''); assert.equal(plain.pulls, '');
    assert.equal(plain.builds, 'db functions');
    assert.match(plain.stdout, /Built 2 image\(s\)\. The next start replaces the containers whose image changed\./);
    for (const args of [['--from-release', '--all'], ['--all', '--from-release']]) {
      const refused = run(f, { args });
      assert.notEqual(refused.status, 0);
      assert.match(refused.stderr, /Usage: bash scripts\/build-images\.sh \[--all \| --no-cache \| --replace-optional \| --save\]\n   or: bash scripts\/build-images\.sh --from-release/);
    }
    // setup.sh passes it; start.sh never builds.
    assert.match(readFileSync(join(repo, 'setup.sh'), 'utf8'), /^bash "\$ROOT\/scripts\/build-images\.sh" --from-release$/m);
  } finally { cleanup(f); }
});

// ---------------------------------------------------------------- scripts/publish-images.sh
// The release workflow's job: push what the scan built and write release-images.json.
function publish(f, args, env = {}) {
  for (const log of ['relabel.log', 'retag.log', 'gh.log']) writeFileSync(join(f.scratch, log), '');
  const result = spawnSync('bash', [join(f.root, 'scripts/publish-images.sh'), ...args], { encoding: 'utf8',
    env: { ...process.env, PATH: `${join(f.scratch, 'bin')}:${process.env.PATH}`, WAREHOUSE_STATE_DIR: f.state, FAKE_DIR: f.scratch, FAKE_ROOT: f.root, ...env } });
  const log = name => (existsSync(join(f.scratch, name)) ? readFileSync(join(f.scratch, name), 'utf8').trim() : '');
  return { ...result, tags: log('tag.log'), pushes: log('push.log'), relabels: log('relabel.log'), retags: log('retag.log'), gh: log('gh.log'), builds: log('build.log') };
}
// What the scan leaves behind: an image of every recipe, built (the fixture has five; `rest` is pulled, so it is not one of them).
const SCANNED = ['cups', 'db', 'functions', 'sensor-bridge', 'supavisor'];
const scanned = f => { for (const log of ['tag.log', 'push.log']) writeFileSync(join(f.scratch, log), ''); f.haveImages(...SCANNED.map(service => `${PROJECT}-${service}`)); };

test('publish-images tags and pushes the image of every recipe, optional ones included, and writes release-images.json with the digests and the fingerprints of the recipes', () => {
  const f = fixture();
  try {
    atTag(f, 'v1.2.3');
    scanned(f);
    const out = join(f.scratch, 'out.json');
    const result = publish(f, ['v1.2.3', out]);
    assert.equal(result.status, 0, result.stderr);
    assert.equal(result.tags, SCANNED.map(service => `${PROJECT}-${service} ${REGISTRY}/${service}:v1.2.3`).join('\n'));
    assert.equal(result.pushes, SCANNED.map(service => `${REGISTRY}/${service}:v1.2.3`).join('\n'), 'not rest, which Compose pulls');
    const manifest = JSON.parse(readFileSync(out, 'utf8'));
    assert.deepEqual(Object.keys(manifest), ['release', 'commit', 'recipes', 'images']);
    assert.equal(manifest.release, 'v1.2.3');
    assert.equal(manifest.commit, git(f, 'rev-parse', 'HEAD'));
    assert.deepEqual(Object.keys(manifest.images), SCANNED);
    for (const service of SCANNED) {
      // The digest the registry answered with (the fake derives it from the pushed name).
      assert.equal(manifest.images[service].ref, `${REGISTRY}/${service}@sha256:${sha(`${REGISTRY}/${service}:v1.2.3`)}`);
      assert.match(manifest.images[service].fingerprint, /^[0-9a-f]{64}$/);
    }
    assert.equal(manifest.recipes, recipesOf(manifest.images));
    assert.match(result.stdout, new RegExp(`Wrote ${out.replace(/[./]/g, '\\$&')} for release v1\\.2\\.3 \\(commit ${manifest.commit}\\): 5 image\\(s\\)\\.`));
    // The fingerprints are the ones a facility with this tree records when it builds the same recipes.
    assert.equal(run(f, { args: ['--all'], containers: 'cups db functions sensor-bridge supavisor' }).status, 0);
    assert.deepEqual(recorded(f.record).map(line => [line[1], line[0]]), SCANNED.map(service => [service, manifest.images[service].fingerprint]));
    assert.deepEqual(readdirSync(f.scratch).filter(name => name.startsWith('out.json.')), [], 'no temporary file');
    // A + in the tag is not allowed in an image tag.
    const g = fixture();
    try {
      atTag(g, 'v1.2.3+build.5');
      scanned(g);
      const built = publish(g, ['v1.2.3+build.5', join(g.scratch, 'out.json')]);
      assert.equal(built.status, 0, built.stderr);
      assert.equal(built.pushes.split('\n')[0], `${REGISTRY}/cups:v1.2.3_build.5`);
      assert.equal(JSON.parse(readFileSync(join(g.scratch, 'out.json'), 'utf8')).release, 'v1.2.3+build.5');
    } finally { cleanup(g); }
  } finally { cleanup(f); }
});

test('publish-images publishes nothing for a missing image, a tag this checkout is not at, or a name that is not a release', () => {
  const f = fixture();
  try {
    atTag(f, 'v1.2.3');
    scanned(f);
    const out = join(f.scratch, 'out.json');
    // An image of the scan is missing: stopped before the first push.
    rmSync(join(f.scratch, 'images', imageFile(`${PROJECT}-supavisor`)));
    const missing = publish(f, ['v1.2.3', out]);
    assert.notEqual(missing.status, 0);
    assert.match(missing.stderr, new RegExp(`The supavisor image \\(${PROJECT}-supavisor\\) is not on this host\\. scripts/scan-images\\.sh builds and scans every image first.* Nothing was published\\.`));
    assert.equal(missing.pushes, ''); assert.equal(existsSync(out), false);
    f.haveImages(`${PROJECT}-supavisor`);
    // The checkout is not at the tag it is asked to publish.
    const elsewhere = publish(f, ['v1.2.4', out]);
    assert.notEqual(elsewhere.status, 0);
    assert.match(elsewhere.stderr, /This checkout is not at the tag v1\.2\.4, so the images built from it are not the release's\. Nothing was published\./);
    assert.equal(elsewhere.pushes, ''); assert.equal(existsSync(out), false);
    for (const name of ['main', 'v1.2', 'v1.2.3;echo', '']) {
      const refused = publish(f, [name, out]);
      assert.notEqual(refused.status, 0, name);
      assert.equal(refused.pushes, '', name);
    }
    assert.match(publish(f, ['v1.2.3']).stderr, /Usage: bash scripts\/publish-images\.sh TAG RELEASE_IMAGES_JSON/);
  } finally { cleanup(f); }
});

test('publish-images writes no list when a push fails or the registry reports no digest', () => {
  const f = fixture();
  try {
    atTag(f, 'v1.2.3');
    scanned(f);
    const out = join(f.scratch, 'out.json');
    const denied = publish(f, ['v1.2.3', out], { FAKE_FAIL_PUSH: 'functions' });
    assert.notEqual(denied.status, 0);
    assert.match(denied.stderr, /denied: permission_denied: write_package/);
    assert.match(denied.stderr, new RegExp(`Pushing ${REGISTRY.replace(/[./]/g, '\\$&')}/functions:v1\\.2\\.3 failed\\. The list of images was not written\\.`));
    assert.equal(existsSync(out), false, 'no list for a release that is only partly published');
    assert.deepEqual(readdirSync(f.scratch).filter(name => name.startsWith('out.json')), []);
    scanned(f);
    const silent = publish(f, ['v1.2.3', out], { FAKE_PUSH_NO_DIGEST: 'yes' });
    assert.notEqual(silent.status, 0);
    assert.match(silent.stderr, /The registry did not report a digest for .*\/cups:v1\.2\.3\. The list of images was not written\./);
    assert.equal(existsSync(out), false);
  } finally { cleanup(f); }
});

test('image-recipes manifest refuses a list that does not match the recipes: a missing, extra or foreign reference', () => {
  const f = fixture();
  try {
    atTag(f, 'v1.2.3');
    const commit = git(f, 'rev-parse', 'HEAD');
    const config = readFileSync(join(f.scratch, 'config.json'));
    const all = Object.entries(f.services).filter(([, definition]) => definition.build).map(([service]) => `${service}=${refOf(service)}`);
    const manifest = (...items) => spawnSync('node', [join(f.root, 'scripts/image-recipes.mjs'), 'manifest', ...items], { input: config, encoding: 'utf8' });
    assert.equal(manifest('v1.2.3', commit, ...all).status, 0);
    const without = manifest('v1.2.3', commit, ...all.filter(item => !item.startsWith('cups=')));
    assert.equal(without.status, 1); assert.match(without.stderr, /No published image was given for the cups recipe\./);
    const extra = manifest('v1.2.3', commit, ...all, `nosuch=${refOf('nosuch')}`);
    assert.equal(extra.status, 1); assert.match(extra.stderr, /services without a recipe: nosuch/);
    const foreign = manifest('v1.2.3', commit, ...all.map(item => (item.startsWith('db=') ? `db=docker.io/library/postgres@sha256:${sha('db')}` : item)));
    assert.equal(foreign.status, 1); assert.match(foreign.stderr, /Not a ghcr\.io\/abhiguru\/supabase-warehouse-template\/db@sha256:<digest> reference/);
    const short = manifest('v1.2.3', 'abc123', ...all);
    assert.equal(short.status, 1); assert.match(short.stderr, /COMMIT is the 40-digit commit/);
  } finally { cleanup(f); }
});

test('publish-images puts the commit and the release on every image as OCI labels, on the scanned image and without changing its layers; a failure or a changed layer stops the run before the first push', () => {
  const f = fixture();
  try {
    atTag(f, 'v1.2.3');
    scanned(f);
    const out = join(f.scratch, 'out.json');
    const commit = git(f, 'rev-parse', 'HEAD');
    const result = publish(f, ['v1.2.3', out]);
    assert.equal(result.status, 0, result.stderr);
    // The labelling build starts FROM the tag it is about to replace, so it is the scanned image's layers plus two labels.
    assert.equal(result.relabels, SCANNED.map(service => `build --pull=false --label org.opencontainers.image.revision=${commit} --label org.opencontainers.image.version=v1.2.3 --tag ${REGISTRY}/${service}:v1.2.3 - | FROM ${REGISTRY}/${service}:v1.2.3`).join('\n'));
    assert.equal(result.pushes, SCANNED.map(service => `${REGISTRY}/${service}:v1.2.3`).join('\n'), 'the labelled images are the ones pushed');
    // The label is what a facility reads back from the pushed tag.
    for (const service of SCANNED) assert.equal(readFileSync(join(f.scratch, 'labels', `${REGISTRY}/${service}:v1.2.3`.replace(/[/:]/g, '_')), 'utf8'), commit);
    // The build fails: nothing is pushed and no list is written.
    const g = fixture();
    try {
      atTag(g, 'v1.2.3');
      scanned(g);
      const failed = publish(g, ['v1.2.3', join(g.scratch, 'out.json')], { FAKE_FAIL_RELABEL: 'yes' });
      assert.notEqual(failed.status, 0);
      assert.match(failed.stderr, new RegExp(`Could not label the cups image \\(${REGISTRY.replace(/[./]/g, '\\$&')}/cups:v1\\.2\\.3\\) with its commit and release\\. Nothing was published\\.`));
      assert.equal(failed.pushes, ''); assert.equal(existsSync(join(g.scratch, 'out.json')), false);
    } finally { cleanup(g); }
    // The layers of the labelled image are not those that were scanned: nothing is pushed.
    const h = fixture();
    try {
      atTag(h, 'v1.2.3');
      scanned(h);
      const changed = publish(h, ['v1.2.3', join(h.scratch, 'out.json')], { FAKE_RELABEL_LAYERS: 'changed' });
      assert.notEqual(changed.status, 0);
      assert.match(changed.stderr, new RegExp(`The labelled cups image \\(${REGISTRY.replace(/[./]/g, '\\$&')}/cups:v1\\.2\\.3\\) does not have the layers of the image that was scanned \\(${PROJECT}-cups\\)\\. Nothing was published\\.`));
      assert.equal(changed.pushes, ''); assert.equal(existsSync(join(h.scratch, 'out.json')), false);
    } finally { cleanup(h); }
  } finally { cleanup(f); }
});

test('--from-release: a pulled image built from another commit, or with no revision label, is refused and built here', () => {
  const f = fixture();
  try {
    atTag(f, 'v1.2.3');
    releaseFile(f);
    const commit = git(f, 'rev-parse', 'HEAD');
    const result = run(f, { ...FROM_RELEASE, env: { FAKE_WRONG_REVISION: 'db', FAKE_NO_REVISION: 'functions' } });
    assert.equal(result.status, 0, result.stderr);
    assert.equal(result.pulls, `${refOf('db')}\n${refOf('functions')}`, 'both were pulled, by digest');
    assert.match(result.stderr, new RegExp(`Warning: the pulled db image was built from commit bbbbbbbbbbbb, not from this checkout's commit ${commit.slice(0, 12)}, so it is not used\\.`));
    assert.match(result.stderr, new RegExp(`Warning: the pulled functions image has no org\\.opencontainers\\.image\\.revision label, so it is not known to be built from this checkout's commit ${commit.slice(0, 12)}, and it is not used\\.`));
    assert.equal(result.tags, '', 'neither refused image was tagged as the project\'s');
    assert.equal(result.builds, 'db functions', 'both are built here instead');
    assert.match(result.stdout, /Building the db image: image missing; the release image could not be used\./);
    assert.match(result.stdout, /Pulled 0 image\(s\) from the release \(none\) and built 2 here \(db functions\)\./);
    for (const [, , id] of recorded(f.record)) assert.match(id, /^sha256:0*[1-9]\d{2}$/, 'the images recorded are the ones built here');
  } finally { cleanup(f); }
});

test('--from-release: a pull that takes longer than the limit is stopped and that image is built here; the others are pulled', () => {
  const f = fixture();
  try {
    atTag(f, 'v1.2.3');
    releaseFile(f);
    const started = Date.now();
    const result = run(f, { ...FROM_RELEASE, env: { FAKE_PULL_HANG: 'db', WAREHOUSE_IMAGE_PULL_TIMEOUT: '1' } });
    assert.ok(Date.now() - started < 20000, 'the hanging pull was stopped, not waited for');
    assert.equal(result.status, 0, result.stderr);
    assert.match(result.stderr, new RegExp(`Warning: pulling the db image of release v1\\.2\\.3 \\(${refOf('db').replace(/[./]/g, '\\$&')}\\) took longer than 1 seconds and was stopped; it is built here\\.`));
    assert.equal(result.builds, 'db');
    assert.equal(result.tags, `${refOf('functions')} ${PROJECT}-functions`, 'the pull that finished was used');
    assert.match(result.stdout, /Pulled 1 image\(s\) from the release \(functions\) and built 1 here \(db\)\./);
    // The limit is 20 minutes unless a test lowers it.
    assert.match(readFileSync(join(repo, 'scripts/build-images.sh'), 'utf8'), /limit="\$\{WAREHOUSE_IMAGE_PULL_TIMEOUT:-1200\}"/);
  } finally { cleanup(f); }
});

test('--from-release builds here, and says why, on a host that is not x86-64 or where no temporary file can be made; nothing is fetched then', () => {
  const f = fixture();
  try {
    atTag(f, 'v1.2.3');
    releaseFile(f);
    const arm = run(f, { ...FROM_RELEASE, env: { FAKE_ARCH: 'aarch64' } });
    assert.equal(arm.status, 0, arm.stderr);
    assert.match(arm.stdout, /Not pulling the images of release v1\.2\.3: they are built for x86-64 and this host is aarch64, so the images are built here\./);
    assert.equal(arm.curls, ''); assert.equal(arm.pulls, ''); assert.equal(arm.builds, 'db functions');
    rmSync(f.record, { force: true });
    const nowhere = run(f, { ...FROM_RELEASE, env: { FAKE_MKTEMP_FAIL: 'yes' } });
    assert.equal(nowhere.status, 0, nowhere.stderr);
    assert.match(nowhere.stdout, new RegExp(`Not pulling the images of release v1\\.2\\.3: a temporary file cannot be made in ${f.state}/config, so the images are built here\\.`));
    assert.equal(nowhere.curls, ''); assert.equal(nowhere.pulls, ''); assert.equal(nowhere.builds, 'db functions');
  } finally { cleanup(f); }
});

// ---------------------------------------------------------------- a final release re-tags the images of its pre-release (publish-images.sh --rehearsed / --retag)
// The list a pre-release's job attached to its release, served by the fake gh.
function preReleaseList(f, tag, change) {
  const manifest = releaseFile(f, tag, change);
  copyFileSync(join(f.scratch, 'release-images.json'), join(f.scratch, 'rc-lists', `${tag}.json`));
  return manifest;
}
const quote = text => text.replace(/[.*+?^${}()|[\]\\/]/g, '\\$&');

test('a final tag on the commit of its newest pre-release reuses that pre-release: its list is downloaded for it alone, the tag may carry build metadata', () => {
  const f = fixture();
  try {
    atTag(f, 'v1.2.3-rc.1', 'v1.2.3', 'v1.2.3+build.5');
    const manifest = preReleaseList(f, 'v1.2.3-rc.1');
    for (const tag of ['v1.2.3', 'v1.2.3+build.5']) {
      const list = join(f.scratch, `rehearsed-${tag}.json`);
      const result = publish(f, ['--rehearsed', tag, list], { GITHUB_REPOSITORY: 'example/warehouse' });
      assert.equal(result.status, 0, result.stderr);
      assert.equal(result.stdout, 'v1.2.3-rc.1\n', `${tag}: only the pre-release's tag is printed`);
      assert.match(result.stderr, new RegExp(`${quote(tag)} is the same commit as the pre-release v1\\.2\\.3-rc\\.1, whose images were built, scanned and rehearsed: they are re-tagged, not built again\\.`));
      assert.deepEqual(JSON.parse(readFileSync(list, 'utf8')), manifest);
    }
    assert.equal(publish(f, ['--rehearsed', 'v1.2.3', join(f.scratch, 'again.json')]).gh.split('\n').pop(), `release download v1.2.3-rc.1 --repo abhiguru/supabase-warehouse-template --pattern release-images.json --output ${join(f.scratch, 'again.json')} --clobber`, 'the repository defaults to this one');
    assert.equal(publish(f, ['--rehearsed', 'v1.2.3', join(f.scratch, 'x.json')], { GITHUB_REPOSITORY: 'example/warehouse' }).gh.split('\n').pop(), `release download v1.2.3-rc.1 --repo example/warehouse --pattern release-images.json --output ${join(f.scratch, 'x.json')} --clobber`);
  } finally { cleanup(f); }
});

test('a tag that is not a final release on the commit of its newest pre-release builds as before: nothing is printed and the reason is said', () => {
  const f = fixture();
  try {
    const list = join(f.scratch, 'rehearsed.json');
    // A pre-release is always built.
    atTag(f, 'v1.2.3-rc.1', 'v1.2.3-rc.2');
    preReleaseList(f, 'v1.2.3-rc.1');
    let result = publish(f, ['--rehearsed', 'v1.2.3-rc.2', list]);
    assert.equal(result.status, 0, result.stderr); assert.equal(result.stdout, '');
    assert.match(result.stderr, /Building and scanning the images: v1\.2\.3-rc\.2 is a pre-release, which is always built\./);
    assert.equal(result.gh, '', 'GitHub is not asked');
    // No pre-release at all.
    const g = fixture();
    try {
      atTag(g, 'v1.2.3');
      result = publish(g, ['--rehearsed', 'v1.2.3', join(g.scratch, 'rehearsed.json')]);
      assert.equal(result.status, 0, result.stderr); assert.equal(result.stdout, '');
      assert.match(result.stderr, /Building and scanning the images: there is no pre-release tag v1\.2\.3-rc\.N\./);
    } finally { cleanup(g); }
    // The newest pre-release is at another commit (the final differs from what was rehearsed).
    const h = fixture();
    try {
      atTag(h, 'v1.2.3-rc.1');
      preReleaseList(h, 'v1.2.3-rc.1');
      writeFileSync(join(h.root, 'NOTES'), 'changed after the pre-release\n');
      git(h, 'add', '-A'); git(h, 'commit', '-q', '-m', 'after the rc'); git(h, 'tag', 'v1.2.3');
      result = publish(h, ['--rehearsed', 'v1.2.3', join(h.scratch, 'rehearsed.json')]);
      assert.equal(result.status, 0, result.stderr); assert.equal(result.stdout, '');
      assert.match(result.stderr, new RegExp(`the newest pre-release, v1\\.2\\.3-rc\\.1, is at [0-9a-f]{40}, and v1\\.2\\.3 is at ${git(h, 'rev-parse', 'HEAD')}\\.`));
      assert.equal(result.gh, '');
    } finally { cleanup(h); }
    // "Newest" is by version, not by letters: rc.10 is newer than rc.9 even though it sorts before it.
    const i = fixture();
    try {
      atTag(i, 'v1.2.3-rc.10');
      writeFileSync(join(i.root, 'NOTES'), 'a later commit\n');
      git(i, 'add', '-A'); git(i, 'commit', '-q', '-m', 'later'); git(i, 'tag', 'v1.2.3-rc.9'); git(i, 'tag', 'v1.2.3');
      preReleaseList(i, 'v1.2.3-rc.9');
      result = publish(i, ['--rehearsed', 'v1.2.3', join(i.scratch, 'rehearsed.json')]);
      assert.equal(result.status, 0, result.stderr); assert.equal(result.stdout, '', 'rc.10 is the newest and is at another commit');
      assert.match(result.stderr, /the newest pre-release, v1\.2\.3-rc\.10, is at/);
    } finally { cleanup(i); }
  } finally { cleanup(f); }
});

test('a pre-release list that cannot be had or does not fit this checkout is not reused: the final builds, with the reason, and no list file is left', () => {
  const cases = [
    ['no list attached to the release', () => {}, /the list of images of v1\.2\.3-rc\.1 could not be downloaded \(release not found\)\./],
    ['a list for another commit', f => preReleaseList(f, 'v1.2.3-rc.1', manifest => { manifest.commit = 'a'.repeat(40); }), /the list of images of v1\.2\.3-rc\.1 cannot be used for v1\.2\.3 \(release-images\.json is not usable: it names commit "a{40}"/],
    ['a list for another release', f => { preReleaseList(f, 'v1.2.3-rc.1', manifest => { manifest.release = 'v1.2.2-rc.1'; }); }, /cannot be used for v1\.2\.3 \(release-images\.json is not usable: it is for release "v1\.2\.2-rc\.1", not v1\.2\.3-rc\.1/],
    ['a recipe that is not the one of the list', f => preReleaseList(f, 'v1.2.3-rc.1', manifest => { manifest.images.db.fingerprint = 'f'.repeat(64); }), /the list of v1\.2\.3-rc\.1 has no usable image of db \(its recipe differs from the release's/],
    ['an image from another registry', f => preReleaseList(f, 'v1.2.3-rc.1', manifest => { manifest.images.db.ref = `ghcr.io/someone-else/warehouse/db@sha256:${sha('db')}`; }), /the reference of db is not ghcr\.io\/abhiguru\/supabase-warehouse-template\/db@sha256:<digest>/],
  ];
  for (const [label, make, why] of cases) {
    const f = fixture();
    try {
      atTag(f, 'v1.2.3-rc.1', 'v1.2.3');
      make(f);
      const list = join(f.scratch, 'rehearsed.json');
      const result = publish(f, ['--rehearsed', 'v1.2.3', list]);
      assert.equal(result.status, 0, `${label}: ${result.stderr}`);
      assert.equal(result.stdout, '', `${label}: nothing is reused`);
      assert.match(result.stderr, why, label);
      assert.match(result.stderr, /^Building and scanning the images: /m, label);
      assert.equal(existsSync(list), false, `${label}: no list is left behind`);
    } finally { cleanup(f); }
  }
});

test('--retag re-tags each image of the pre-release by digest as a carbon copy, builds, scans and pushes nothing, and lists the same digests for the final release', () => {
  const f = fixture();
  try {
    atTag(f, 'v1.2.3-rc.1', 'v1.2.3');
    const manifest = preReleaseList(f, 'v1.2.3-rc.1');
    const list = join(f.scratch, 'rehearsed.json');
    assert.equal(publish(f, ['--rehearsed', 'v1.2.3', list]).stdout, 'v1.2.3-rc.1\n');
    const out = join(f.scratch, 'out.json');
    const result = publish(f, ['--retag', 'v1.2.3', 'v1.2.3-rc.1', list, out]);
    assert.equal(result.status, 0, result.stderr);
    // The images are copied by digest to the final tag, and what the registry says the tag is gets compared with the digest.
    assert.equal(result.retags, SCANNED.map(service => `buildx imagetools create --prefer-index=false --tag ${REGISTRY}/${service}:v1.2.3 ${refOf(service)}\nbuildx imagetools inspect ${REGISTRY}/${service}:v1.2.3 --format {{.Manifest.Digest}}`).join('\n'));
    // Nothing is built, labelled, tagged or pushed with docker's own commands, and the scan's build never ran.
    assert.equal(result.builds, ''); assert.equal(result.relabels, ''); assert.equal(result.tags, ''); assert.equal(result.pushes, '');
    const released = JSON.parse(readFileSync(out, 'utf8'));
    assert.deepEqual(Object.keys(released), ['release', 'commit', 'recipes', 'images']);
    assert.equal(released.release, 'v1.2.3');
    assert.equal(released.commit, manifest.commit);
    assert.deepEqual(released.images, manifest.images, 'the same digests, with the same fingerprints');
    assert.equal(released.recipes, manifest.recipes);
    assert.match(result.stdout, new RegExp(`Re-tagged the db image of v1\\.2\\.3-rc\\.1 as ${quote(REGISTRY)}/db:v1\\.2\\.3: ${quote(refOf('db'))}`));
    assert.match(result.stdout, /Nothing was built or scanned for v1\.2\.3: the images are those of v1\.2\.3-rc\.1, built and scanned for it from this commit\./);
    // A facility at the final tag takes the list as it takes any other: the same checks, and the digests it pulls are the rehearsed ones.
    copyFileSync(out, join(f.scratch, 'release-images.json'));
    const pulled = run(f, FROM_RELEASE);
    assert.equal(pulled.status, 0, pulled.stderr);
    assert.equal(pulled.pulls, `${refOf('db')}\n${refOf('functions')}`);
    assert.match(pulled.stdout, /Pulled 2 image\(s\) from the release \(db functions\) and built 0 here \(none\)\./);
    assert.match(pulled.stdout, /Pulled the db image from release v1\.2\.3: image missing/);
  } finally { cleanup(f); }
});

test('--retag writes no list when a re-tag fails, when the registry answers another digest for the new tag, or when it is not a final release on the pre-release\'s commit', () => {
  const f = fixture();
  try {
    atTag(f, 'v1.2.3-rc.1', 'v1.2.3');
    preReleaseList(f, 'v1.2.3-rc.1');
    const list = join(f.scratch, 'rehearsed.json');
    assert.equal(publish(f, ['--rehearsed', 'v1.2.3', list]).stdout, 'v1.2.3-rc.1\n');
    const out = join(f.scratch, 'out.json');
    const denied = publish(f, ['--retag', 'v1.2.3', 'v1.2.3-rc.1', list, out], { FAKE_FAIL_RETAG: 'functions' });
    assert.notEqual(denied.status, 0);
    assert.match(denied.stderr, new RegExp(`Could not re-tag the functions image of v1\\.2\\.3-rc\\.1 as ${quote(REGISTRY)}/functions:v1\\.2\\.3\\. The list of images was not written\\.`));
    assert.equal(existsSync(out), false);
    const other = publish(f, ['--retag', 'v1.2.3', 'v1.2.3-rc.1', list, out], { FAKE_RETAG_DIGEST: 'db' });
    assert.notEqual(other.status, 0);
    assert.match(other.stderr, new RegExp(`${quote(REGISTRY)}/db:v1\\.2\\.3 is sha256:0+99 after the re-tag, not the sha256:${sha('db')} of v1\\.2\\.3-rc\\.1\\. The list of images was not written\\.`));
    assert.equal(existsSync(out), false); assert.deepEqual(readdirSync(f.scratch).filter(name => name.startsWith('out.json')), []);
    // Not a pre-release of this tag, not a final tag, a missing list, a list that is not the pre-release's.
    for (const [args, why] of [
      [['v1.2.3', 'v1.2.4-rc.1', list, out], /v1\.2\.4-rc\.1 is not a pre-release \(vX\.Y\.Z-rc\.N\) of v1\.2\.3\. Nothing was published\./],
      [['v1.2.3', 'v1.2.3', list, out], /v1\.2\.3 is not a pre-release \(vX\.Y\.Z-rc\.N\) of v1\.2\.3\./],
      [['v1.2.3', 'v1.2.3-rc.1', join(f.scratch, 'missing.json'), out], /The list of images of v1\.2\.3-rc\.1 \(.*missing\.json\) is missing\. Nothing was published\./],
    ]) {
      const refused = publish(f, ['--retag', ...args]);
      assert.notEqual(refused.status, 0, args.join(' '));
      assert.match(refused.stderr, why, args.join(' '));
      assert.equal(refused.retags, '', 'nothing was copied');
    }
    assert.equal(publish(f, ['--retag', 'v1.2.3', 'v1.2.3-rc.1', list]).status, 1, 'the arguments are checked');
    assert.match(publish(f, ['--retag', 'v1.2.3', 'v1.2.3-rc.1', list]).stderr, /Usage: bash scripts\/publish-images\.sh .*--retag TAG PRERELEASE LIST_FILE RELEASE_IMAGES_JSON/);
    // A list made for another pre-release is refused by the checks a facility applies.
    preReleaseList(f, 'v1.2.3-rc.1', manifest => { manifest.release = 'v1.2.3-rc.2'; });
    copyFileSync(join(f.scratch, 'rc-lists', 'v1.2.3-rc.1.json'), list);
    const wrong = publish(f, ['--retag', 'v1.2.3', 'v1.2.3-rc.1', list, out]);
    assert.notEqual(wrong.status, 0);
    assert.match(wrong.stderr, /The list of images of v1\.2\.3-rc\.1 cannot be used for v1\.2\.3: release-images\.json is not usable: it is for release "v1\.2\.3-rc\.2", not v1\.2\.3-rc\.1\. Nothing was published\./);
    // A pre-release tag is never "retagged".
    const rc = publish(f, ['--retag', 'v1.2.3-rc.1', 'v1.2.3-rc.1', list, out]);
    assert.notEqual(rc.status, 0);
    assert.match(rc.stderr, /v1\.2\.3-rc\.1 is a pre-release: only a final release re-tags the images of a pre-release\. Nothing was published\./);
    // A pre-release tag that is not at this checkout's commit is refused, whatever the list says (here the list names this commit).
    preReleaseList(f, 'v1.2.3-rc.1');
    copyFileSync(join(f.scratch, 'rc-lists', 'v1.2.3-rc.1.json'), list);
    git(f, 'tag', '-f', 'v1.2.3-rc.1', git(f, 'commit-tree', 'HEAD^{tree}', '-m', 'another commit'));
    const moved = publish(f, ['--retag', 'v1.2.3', 'v1.2.3-rc.1', list, out]);
    assert.notEqual(moved.status, 0);
    assert.match(moved.stderr, /The pre-release v1\.2\.3-rc\.1 is not at this checkout's commit\. Nothing was published\./);
    assert.equal(moved.retags, '', 'nothing was copied');
    assert.equal(existsSync(out), false);
  } finally { cleanup(f); }
});
