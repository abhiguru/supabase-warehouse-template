import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, copyFileSync, existsSync, rmSync, chmodSync, readdirSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

// scripts/upgrade-prepull.sh, run by the target's preflight before the API is closed. Here it runs from a copy of a tree (the real script and
// image-recipes.mjs, a docker-compose.yml of the test's own) with curl, docker and uname shims on the PATH that log what they were asked.
const root = new URL('..', import.meta.url).pathname;
const SHA = 'c'.repeat(40);
const REGISTRY = 'ghcr.io/abhiguru/supabase-warehouse-template';
const digest = letter => `sha256:${letter.repeat(64)}`;
const SERVICES = { db: 'a', functions: 'b' };
const HUB = `postgrest/postgrest:v16.5@${digest('d')}`;
const manifest = ({ release = 'v1.2.3', commit = SHA, services = SERVICES } = {}) => {
  const images = {};
  for (const [name, letter] of Object.entries(services)) images[name] = { ref: `${REGISTRY}/${name}@${digest(letter)}`, fingerprint: createHash('sha256').update(name).digest('hex') };
  const recipes = createHash('sha256').update(Object.entries(images).sort(([a], [b]) => a.localeCompare(b)).map(([name, { fingerprint }]) => `${fingerprint}  ${name}\n`).join('')).digest('hex');
  return JSON.stringify({ release, commit, recipes, images });
};

function world() {
  const scratch = mkdtempSync(join(tmpdir(), 'warehouse-prepull-'));
  const tree = join(scratch, 'tree');
  const state = join(scratch, 'state');
  const bin = join(scratch, 'bin');
  for (const dir of [join(tree, 'scripts'), join(tree, 'docker'), join(state, 'config'), bin]) mkdirSync(dir, { recursive: true });
  for (const file of ['scripts/upgrade-prepull.sh', 'scripts/image-recipes.mjs']) copyFileSync(join(root, file), join(tree, file));
  writeFileSync(join(tree, 'docker/docker-compose.yml'), `services:
  gateway:
    image: \${WAREHOUSE_PROJECT_NAME:?Run setup.sh to write the project name}-gateway
  rest:
    # Index digest.
    image: ${HUB}
  other:
    image: busybox:latest
`);
  const shim = (name, body) => { writeFileSync(join(bin, name), `#!/bin/bash\n${body}\n`); chmodSync(join(bin, name), 0o755); };
  shim('uname', 'if [ "$1" = -m ]; then echo "${FAKE_ARCH:-x86_64}"; else exec /usr/bin/uname "$@"; fi');
  shim('curl', `echo "curl $*" >> "$FAKE_LOG"
[ -z "$FAKE_CURL_FAIL" ] || { echo "curl: (22) The requested URL returned error: 404" >&2; exit 22; }
out=''; while [ $# -gt 0 ]; do if [ "$1" = --output ]; then out="$2"; fi; shift; done
printf '%s' "$FAKE_JSON" > "$out"`);
  shim('docker', `echo "docker $*" >> "$FAKE_LOG"
case "$1 $2" in
  "pull --quiet")
    case " $FAKE_PULL_FAIL " in *" $3 "*) echo "Error response from daemon: manifest unknown (fake)" >&2; exit 1 ;; esac
    if [ -n "$FAKE_PULL_SLEEP" ]; then exec sleep "$FAKE_PULL_SLEEP"; fi
    echo "$3" ;;
  "image inspect")
    case "$4" in
      *RepoDigests*) if [ -n "$FAKE_DIGEST_OTHER" ]; then echo "$5@sha256:$(printf 'e%.0s' $(seq 64))"; else echo "$5"; fi ;;
      *Labels*) echo "\${FAKE_REVISION-${SHA}}" ;;
    esac ;;
  "image rm") ;;
  *) echo "unexpected docker $*" >&2; exit 9 ;;
esac`);
  const log = join(scratch, 'fake.log');
  writeFileSync(log, '');
  const run = (extra = {}) => {
    writeFileSync(log, '');
    const r = spawnSync('bash', [join(tree, 'scripts/upgrade-prepull.sh')], { cwd: tree, encoding: 'utf8',
      env: { ...process.env, PATH: `${bin}:${process.env.PATH}`, STATE: state, TO_SHA: SHA, TO_LABEL: 'v1.2.3', DRY: 'no', FAKE_LOG: log, FAKE_JSON: manifest(), ...extra } });
    return { ...r, calls: readFileSync(log, 'utf8').split('\n').filter(Boolean), leftovers: readdirSync(join(state, 'config')) };
  };
  return { run, cleanup: () => rmSync(scratch, { recursive: true, force: true }) };
}
const pulls = calls => calls.filter(line => line.startsWith('docker pull ')).map(line => line.replace('docker pull --quiet ', ''));

test('every image of release-images.json and every digest-pinned image of the compose file is pulled by its digest, in a fixed order, and nothing is tagged', () => {
  const w = world();
  try {
    const r = w.run();
    assert.equal(r.status, 0, r.stdout + r.stderr);
    assert.deepEqual(pulls(r.calls), [`${REGISTRY}/db@${digest('a')}`, `${REGISTRY}/functions@${digest('b')}`, HUB]);
    assert.ok(!r.calls.some(line => /^docker tag\b/.test(line)), `docker tag must never run: ${r.calls.join(' | ')}`);
    assert.ok(!r.calls.some(line => /busybox|-gateway/.test(line)), 'an image without a digest is not pulled');
    assert.match(r.stdout, /Pre-pull of images: pulling 2 image\(s\) of v1\.2\.3 and 1 base image\(s\) while the facility still serves/);
    assert.match(r.stdout, /Pre-pull of images: done \(2 image\(s\) of v1\.2\.3, 1 base image\(s\)\)\./);
    assert.deepEqual(r.leftovers, [], 'the downloaded file is removed');
  } finally { w.cleanup(); }
});

test('the file is fetched with the address and the curl flags of scripts/build-images.sh', () => {
  const w = world();
  try {
    const fetched = w.run({ TO_LABEL: 'v1.2.3+build.5', FAKE_JSON: manifest({ release: 'v1.2.3+build.5' }) }).calls.find(line => line.startsWith('curl '));
    assert.match(fetched, /^curl --fail --silent --show-error --location --proto =https --proto-redir =https --tlsv1\.2 --max-time 60 --max-filesize 1048576 --output \S+ https:\/\/github\.com\/abhiguru\/supabase-warehouse-template\/releases\/download\/v1\.2\.3%2Bbuild\.5\/release-images\.json$/);
    const flags = text => /curl (--fail .*?) --output/.exec(text)?.[1];
    assert.ok(flags(readFileSync(join(root, 'scripts/build-images.sh'), 'utf8')), 'build-images.sh has the curl line');
    assert.equal(flags(readFileSync(join(root, 'scripts/upgrade-prepull.sh'), 'utf8')), flags(readFileSync(join(root, 'scripts/build-images.sh'), 'utf8')), 'the flags are the same');
    const address = file => /url="(https:[^"]*release-images\.json)"/.exec(readFileSync(join(root, file), 'utf8'))?.[1];
    assert.equal(address('scripts/upgrade-prepull.sh'), address('scripts/build-images.sh')?.replace('${tag//', '${TO_LABEL//'), 'the address is built the same way (the variable is TO_LABEL here, tag there)');
  } finally { w.cleanup(); }
});

test('a target that is not a release tag, and a host that is not x86-64, pull nothing and fetch nothing', () => {
  const w = world();
  try {
    const ref = w.run({ TO_LABEL: `${SHA.slice(0, 12)} (--ref main)` });
    assert.equal(ref.status, 0, ref.stderr);
    assert.match(ref.stdout, /Pre-pull of images: not done: .* is not a release tag/);
    assert.deepEqual(ref.calls, []);
    const arm = w.run({ FAKE_ARCH: 'aarch64' });
    assert.equal(arm.status, 0, arm.stderr);
    assert.match(arm.stdout, /not done: the release images are built for x86-64 and this host is aarch64/);
    assert.deepEqual(arm.calls, []);
  } finally { w.cleanup(); }
});

test('a dry run fetches and checks the file and says what a real run pulls, and pulls nothing', () => {
  const w = world();
  try {
    const r = w.run({ DRY: 'yes' });
    assert.equal(r.status, 0, r.stdout + r.stderr);
    assert.match(r.stdout, /a real run would pull 2 image\(s\) of v1\.2\.3 and 1 base image\(s\) before the API is closed \(this dry run pulls nothing\)/);
    assert.equal(r.calls.length, 1);
    assert.match(r.calls[0], /^curl /);
    const bad = w.run({ DRY: 'yes', FAKE_JSON: manifest({ commit: 'f'.repeat(40) }) });
    assert.equal(bad.status, 1, 'a file that does not fit the release is found in the dry run too');
  } finally { w.cleanup(); }
});

test('a download that fails, or a file of another release or commit, refuses with "Nothing was changed" and pulls nothing', () => {
  const w = world();
  try {
    const down = w.run({ FAKE_CURL_FAIL: '1' });
    assert.equal(down.status, 1);
    assert.match(down.stderr, /Refusing: https:\/\/github\.com\/.*release-images\.json could not be fetched \(curl: \(22\)[^)]*\)[^]*Nothing was changed\./);
    for (const [label, json, pattern] of [
      ['another commit', manifest({ commit: 'f'.repeat(40) }), /is not usable: it names commit/],
      ['another release', manifest({ release: 'v9.9.9' }), /is not usable: it is for release "v9\.9\.9", not v1\.2\.3/],
      ['not JSON', 'not json', /cannot be read/],
    ]) {
      const r = w.run({ FAKE_JSON: json });
      assert.equal(r.status, 1, label);
      assert.match(r.stderr, pattern, label);
      assert.match(r.stderr, /Nothing was changed\./, label);
      assert.deepEqual(pulls(r.calls), [], `${label}: nothing was pulled`);
    }
    assert.deepEqual(w.run({ FAKE_CURL_FAIL: '1' }).leftovers, [], 'no temporary file is left');
  } finally { w.cleanup(); }
});

test('a pull that fails or times out refuses, naming the image, and the images after it are not pulled', () => {
  const w = world();
  try {
    const failing = `${REGISTRY}/db@${digest('a')}`;
    const r = w.run({ FAKE_PULL_FAIL: failing });
    assert.equal(r.status, 1);
    assert.match(r.stderr, new RegExp(`Refusing: could not pull ${failing.replace(/[./]/g, '\\$&')}: Error response from daemon: manifest unknown \\(fake\\)\\. .*Nothing was changed\\.`));
    assert.deepEqual(pulls(r.calls), [failing]);
    const slow = w.run({ WAREHOUSE_IMAGE_PULL_TIMEOUT: '1', FAKE_PULL_SLEEP: '30' });
    assert.equal(slow.status, 1);
    assert.match(slow.stderr, /Refusing: pulling \S+ took longer than 1 seconds and was stopped\..*Nothing was changed\./);
    const hub = w.run({ FAKE_PULL_FAIL: HUB });
    assert.equal(hub.status, 1, 'a Docker Hub image that cannot be pulled refuses too');
    assert.match(hub.stderr, /could not pull postgrest\/postgrest/);
  } finally { w.cleanup(); }
});

test('a pulled image of another digest or of another commit is refused, and the one of another commit is removed by its exact name', () => {
  const w = world();
  try {
    const digestOther = w.run({ FAKE_DIGEST_OTHER: '1' });
    assert.equal(digestOther.status, 1);
    assert.match(digestOther.stderr, /the pulled image does not carry the digest sha256:a{64} that was asked for/);
    const other = w.run({ FAKE_REVISION: 'f'.repeat(40) });
    assert.equal(other.status, 1);
    assert.match(other.stderr, /was built from commit f{40}, not from the commit c{12} of v1\.2\.3\./);
    assert.ok(other.calls.includes(`docker image rm ${REGISTRY}/db@${digest('a')}`), other.calls.join('\n'));
    const none = w.run({ FAKE_REVISION: '' });
    assert.equal(none.status, 1);
    assert.match(none.stderr, /<no revision label>/);
    assert.ok(!none.calls.some(line => /^docker tag\b/.test(line)));
  } finally { w.cleanup(); }
});
