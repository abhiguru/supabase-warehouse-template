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
  for (const file of ['scripts/upgrade-prepull.sh', 'scripts/image-recipes.mjs', 'scripts/verify-image-signature.sh']) copyFileSync(join(root, file), join(tree, file));
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
  // cosign: FAKE_COSIGN=ok verifies, bad refuses; the shim logs the identity it was asked to accept.
  shim('cosign', 'echo "cosign $*" >> "$FAKE_LOG"; [ "$FAKE_COSIGN" = ok ] && exit 0; echo "no signatures found" >&2; exit 1');
  shim('uname', 'if [ "$1" = -m ]; then echo "${FAKE_ARCH:-x86_64}"; else exec /usr/bin/uname "$@"; fi');
  shim('curl', `echo "curl $*" >> "$FAKE_LOG"
case "$FAKE_CURL_FAIL" in
  '') ;;
  network) echo "curl: (6) Could not resolve host: github.com" >&2; printf 000; exit 6 ;;
  *) echo "curl: (22) The requested URL returned error: $FAKE_CURL_FAIL" >&2; printf '%s' "$FAKE_CURL_FAIL"; exit 22 ;;
esac
out=''; while [ $# -gt 0 ]; do if [ "$1" = --output ]; then out="$2"; fi; shift; done
printf '%s' "$FAKE_JSON" > "$out"
printf 200`);
  shim('docker', `echo "docker $*" >> "$FAKE_LOG"
case "$1 $2" in
  "pull --quiet")
    case " $FAKE_PULL_FAIL " in *" $3 "*) echo "Error response from daemon: manifest unknown (fake)" >&2; exit 1 ;; esac
    if [ -n "$FAKE_PULL_SLEEP" ]; then exec sleep "$FAKE_PULL_SLEEP"; fi
    echo "$3" ;;
  "image inspect")
    case "$4" in
      # As Docker does: a pulled image is listed as repository@digest, and the tag of a tag-and-digest reference is not kept.
      *RepoDigests*)
        name="\${5%%@*}"; case "\${name##*/}" in *:*) name="\${name%:*}" ;; esac
        other="$FAKE_DIGEST_OTHER"; case " $FAKE_DIGEST_OTHER_FOR " in *" $5 "*) other=1 ;; esac
        if [ -n "$other" ]; then echo "$name@sha256:$(printf 'e%.0s' $(seq 64))"; else echo "$name@\${5##*@}"; fi ;;
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
  return { tree, bin, state, run, cleanup: () => rmSync(scratch, { recursive: true, force: true }) };
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

// Docker lists a pulled image under RepoDigests as repository@digest. The compose file names PostgREST by tag and digest
// (postgrest/postgrest:v16.5@sha256:...), and the tag is not in that list, so the check must compare the repository and the digest (WH-95).
test('a Docker Hub image named by tag and digest is accepted, although Docker lists its digest without the tag', () => {
  const w = world();
  try {
    const r = w.run();
    assert.doesNotMatch(r.stderr, /does not carry the digest/, 'the tag of the reference must not make the digest check fail');
    assert.equal(r.status, 0, r.stdout + r.stderr);
    assert.ok(pulls(r.calls).includes(HUB), 'the reference is pulled as the compose file writes it');
  } finally { w.cleanup(); }
});

test('a Docker Hub image of another digest is still refused, naming the digest that was asked for', () => {
  const w = world();
  try {
    const r = w.run({ FAKE_DIGEST_OTHER_FOR: HUB });
    assert.equal(r.status, 1);
    assert.match(r.stderr, /the pulled image does not carry the digest sha256:d{64} that was asked for/);
    assert.match(r.stderr, /Nothing was changed\./);
    assert.deepEqual(pulls(r.calls), [`${REGISTRY}/db@${digest('a')}`, `${REGISTRY}/functions@${digest('b')}`, HUB], 'the release images before it were pulled and accepted');
  } finally { w.cleanup(); }
});

test('the file is fetched with the address and the curl flags of scripts/build-images.sh', () => {
  const w = world();
  try {
    const fetched = w.run({ TO_LABEL: 'v1.2.3+build.5', FAKE_JSON: manifest({ release: 'v1.2.3+build.5' }) }).calls.find(line => line.startsWith('curl '));
    assert.match(fetched, /^curl --fail --silent --show-error --location --proto =https --proto-redir =https --tlsv1\.2 --max-time 60 --max-filesize 1048576 --output \S+ --write-out %\{http_code\} https:\/\/github\.com\/abhiguru\/supabase-warehouse-template\/releases\/download\/v1\.2\.3%2Bbuild\.5\/release-images\.json$/);
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
    // The network, or the server, failing refuses; a 404 is the release having no file (see the next test).
    for (const [code, pattern] of [['network', /could not be fetched \(curl: \(6\) Could not resolve host: github\.com , HTTP 000\)/], ['403', /could not be fetched \(curl: \(22\)[^)]*403 , HTTP 403\)/], ['503', /could not be fetched \(curl: \(22\)[^)]*503 , HTTP 503\)/]]) {
      const down = w.run({ FAKE_CURL_FAIL: code });
      assert.equal(down.status, 1, code);
      assert.match(down.stderr, /Refusing: https:\/\/github\.com\/.*release-images\.json could not be fetched/);
      assert.match(down.stderr, pattern, code);
      assert.match(down.stderr, /Nothing was changed\./);
      assert.deepEqual(pulls(down.calls), [], code);
    }
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
    assert.deepEqual(w.run({ FAKE_CURL_FAIL: 'network' }).leftovers, [], 'no temporary file is left');
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

test('a release with no release-images.json (the download answers 404) is skipped with one warning, exit 0, nothing pulled and nothing left behind', () => {
  const w = world();
  try {
    const r = w.run({ FAKE_CURL_FAIL: '404' });
    assert.equal(r.status, 0, r.stdout + r.stderr);
    assert.match(r.stderr, /^Warning: https:\/\/github\.com\/.*\/v1\.2\.3\/release-images\.json answers 404 \(.*\): release v1\.2\.3 has no release-images\.json, so its images are not pulled ahead; setup pulls or builds them while the API is closed\.\n$/);
    assert.deepEqual(pulls(r.calls), []);
    assert.deepEqual(r.leftovers, []);
    // Only the 404 is let through: a dry run behaves the same, and a file that does not fit still refuses.
    assert.equal(w.run({ FAKE_CURL_FAIL: '404', DRY: 'yes' }).status, 0);
    assert.equal(w.run({ FAKE_JSON: manifest({ commit: 'f'.repeat(40) }) }).status, 1);
  } finally { w.cleanup(); }
});

// WH-116: the release images are signed (keyless cosign). The pre-pull checks the signatures first, before anything is pulled.
const SIGNED = tree => { mkdirSync(join(tree, 'docker'), { recursive: true }); writeFileSync(join(tree, 'docker/images-signed'), ''); };
const NO_COSIGN_PATH = bin => `${bin}:/usr/bin:/bin`;

test('a tree without docker/images-signed (an older release) is not checked: the cosign shim is never asked and the pull goes on', () => {
  const w = world();
  try {
    const r = w.run({ FAKE_COSIGN: 'bad' });
    assert.equal(r.status, 0, r.stderr);
    assert.ok(!r.calls.some(line => line.startsWith('cosign ')));
    assert.equal(pulls(r.calls).length, 3);
  } finally { w.cleanup(); }
});

test('a signed release whose signatures check: every image is verified against the release workflow identity, then pulled', () => {
  const w = world();
  try {
    SIGNED(w.tree);
    const r = w.run({ FAKE_COSIGN: 'ok' });
    assert.equal(r.status, 0, r.stdout + r.stderr);
    const verified = r.calls.filter(line => line.startsWith('cosign '));
    assert.equal(verified.length, 2, 'the two release images (the Docker Hub base image is not signed by this project)');
    assert.match(verified[0], /^cosign verify --certificate-identity-regexp \^https:\/\/github\\\.com\/abhiguru\/supabase-warehouse-template\/\\\.github\/workflows\/release\\\.yml@refs\/tags\/v\[0-9\]\.\*\$ --certificate-oidc-issuer https:\/\/token\.actions\.githubusercontent\.com ghcr\.io\/abhiguru\/supabase-warehouse-template\/db@sha256:a{64}$/);
    assert.ok(r.calls.findIndex(line => line.startsWith('cosign ')) < r.calls.findIndex(line => line.startsWith('docker pull ')), 'signatures first');
  } finally { w.cleanup(); }
});

test('a signature that does not check refuses the upgrade before anything is pulled, also with --unsigned (that is only for a missing cosign)', () => {
  for (const unsigned of ['', 'yes']) {
    const w = world();
    try {
      SIGNED(w.tree);
      const r = w.run({ FAKE_COSIGN: 'bad', WAREHOUSE_UNSIGNED: unsigned });
      assert.equal(r.status, 1);
      assert.match(r.stderr, /the signature of the image ghcr\.io\/abhiguru\/supabase-warehouse-template\/db@sha256:a{64} of v1\.2\.3 did not check/);
      assert.match(r.stderr, /Nothing was changed\./);
      assert.deepEqual(pulls(r.calls), []);
    } finally { w.cleanup(); }
  }
});

test('a signed release on a host without cosign is refused, naming how to install it; --unsigned goes on with a warning and a line in upgrades.log', () => {
  const w = world();
  try {
    SIGNED(w.tree);
    rmSync(join(w.bin, 'cosign'));
    const refused = w.run({ PATH: NO_COSIGN_PATH(w.bin), WAREHOUSE_STATE_DIR: '' });
    assert.equal(refused.status, 1, refused.stdout + refused.stderr);
    assert.match(refused.stderr, /cosign is not installed, so the signatures of the images of v1\.2\.3 cannot be checked/);
    assert.match(refused.stderr, /install-cosign\.sh/);
    assert.deepEqual(pulls(refused.calls), []);
    const unsigned = w.run({ PATH: NO_COSIGN_PATH(w.bin), WAREHOUSE_UNSIGNED: 'yes', FROM_LABEL: 'v1.2.2' });
    assert.equal(unsigned.status, 0, unsigned.stdout + unsigned.stderr);
    assert.match(unsigned.stderr, /Warning: cosign is not installed and --unsigned was given: the images of v1\.2\.3 are used WITHOUT checking their signatures/);
    assert.match(readFileSync(join(w.state, 'config/upgrades.log'), 'utf8'), /v1\.2\.2 unsigned: images of v1\.2\.3 used without a signature check \(cosign missing, --unsigned\)/);
    assert.equal(pulls(unsigned.calls).length, 3);
  } finally { w.cleanup(); }
});

test('a dry run checks the signatures too, and writes no log line', () => {
  const w = world();
  try {
    SIGNED(w.tree);
    const bad = w.run({ DRY: 'yes', FAKE_COSIGN: 'bad' });
    assert.equal(bad.status, 1);
    rmSync(join(w.bin, 'cosign'));
    const unsigned = w.run({ DRY: 'yes', PATH: NO_COSIGN_PATH(w.bin), WAREHOUSE_UNSIGNED: 'yes' });
    assert.equal(unsigned.status, 0, unsigned.stderr);
    assert.equal(existsSync(join(w.state, 'config/upgrades.log')), false);
  } finally { w.cleanup(); }
});
