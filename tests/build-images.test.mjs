import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, copyFileSync, rmSync, statSync, chmodSync, symlinkSync, existsSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { makeState, scriptRoot, repo } from './backup-test-helpers.mjs';

// scripts/build-images.sh from a private copy of the operator scripts, against a
// fake docker that keeps its "images" as files (name -> image ID):
//   compose config --format json   prints the fixture (fails with FAKE_FAIL_CONFIG=yes)
//   compose build [opts] SERVICE..  logged; gives every named image a new ID (fails with FAKE_FAIL_BUILD=yes)
//   compose up -d ... SERVICE..     logged (fails with FAKE_FAIL_UP=yes)
//   image inspect                   the stored ID, or exit 1
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
  recipe('imgproxy');
  recipe('prometheus', { profiles: ['monitoring'] });
  recipe('cups', { profiles: ['printing'] });
  // No `image:`: Compose tags every built image `<project>-<service>`, Grafana included.
  recipe('grafana', { profiles: ['monitoring'] });
  services.kong = { image: 'kong:3.9.3-ubuntu' };
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
  image) cat "$FAKE_DIR/images/$(file "$5")" 2>/dev/null || exit 1 ;;
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

function run({ scratch, state, root }, { args = [], containers = '', running = '', fail = '', wrap } = {}) {
  for (const log of ['build.log', 'up.log']) writeFileSync(join(scratch, log), '');
  const script = join(root, 'scripts/build-images.sh');
  const command = wrap ? ['bash', ['-c', wrap, 'wrap', script, join(state, 'config/operator.lock')]] : ['bash', [script, ...args]];
  const result = spawnSync(...command, {
    encoding: 'utf8',
    env: { ...process.env, PATH: `${join(scratch, 'bin')}:${process.env.PATH}`, WAREHOUSE_STATE_DIR: state, FAKE_DIR: scratch,
      FAKE_CONTAINERS: containers, FAKE_RUNNING: running, [`FAKE_FAIL_${fail.toUpperCase()}`]: 'yes' },
  });
  const log = name => readFileSync(join(scratch, name), 'utf8').trim();
  return { ...result, builds: log('build.log'), ups: log('up.log') };
}
const CORE = [`${PROJECT}-db`, `${PROJECT}-imgproxy`];
const recorded = record => readFileSync(record, 'utf8').trim().split('\n').map(line => line.split('  '));
const cleanup = f => rmSync(f.scratch, { recursive: true, force: true });

test('a first installation builds the core images, leaves optional services alone and records fingerprint and image ID', () => {
  const f = fixture();
  try {
    const result = run(f);
    assert.equal(result.status, 0, result.stderr);
    assert.equal(result.builds, 'db imgproxy');
    assert.match(result.stdout, /Building the db image: image missing\./);
    assert.match(result.stdout, /Built 2 image\(s\)\./);
    const lines = recorded(f.record);
    assert.deepEqual(lines.map(line => line[1]), ['db', 'imgproxy']);
    for (const [fingerprint, , id] of lines) { assert.match(fingerprint, /^[0-9a-f]{64}$/); assert.match(id, /^sha256:[0-9]{64}$/); }
    assert.equal(statSync(f.record).mode & 0o777, 0o600);
    assert.equal(result.ups, '', 'the build step starts nothing');
  } finally { cleanup(f); }
});

test('an installation from before the record rebuilds once what it uses; an image without a container is not in use', () => {
  const f = fixture();
  try {
    // The image scan and the checks build optional images that are never started:
    // Grafana and CUPS have an image here, but only Prometheus has a container.
    f.haveImages(...CORE, `${PROJECT}-prometheus`, `${PROJECT}-cups`, `${PROJECT}-grafana`);
    const containers = 'db imgproxy prometheus kong';
    const first = run(f, { containers });
    assert.equal(first.status, 0, first.stderr);
    assert.equal(first.builds, 'db imgproxy prometheus');
    assert.match(first.stdout, /Building the prometheus image: no build record\./);
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
    chmodSync(join(f.root, 'docker/imgproxy/Dockerfile'), 0o755);
    changed('the executable bit', 'imgproxy');
    symlinkSync('Dockerfile', join(f.root, 'docker/imgproxy/link'));
    changed('a new symbolic link', 'imgproxy');
    f.services.db.build.dockerfile = 'Dockerfile.next';
    f.writeConfig();
    changed('the Dockerfile path', 'db');
    f.services.db.build.target = 'runtime';
    f.writeConfig();
    changed('the build target', 'db');
    f.services.imgproxy.build.args = { TARGETARCH: 'arm64' };
    f.writeConfig();
    changed('a build argument', 'imgproxy');
  } finally { cleanup(f); }
});

test('an image whose tag was moved by something else is built again', () => {
  const f = fixture();
  try {
    assert.equal(run(f).status, 0);
    // Another checkout sharing the tag, a manual build, or a build that failed half way.
    writeFileSync(join(f.scratch, 'images', imageFile(`${PROJECT}-imgproxy`)), `sha256:${'9'.repeat(64)}\n`);
    const result = run(f);
    assert.equal(result.status, 0, result.stderr);
    assert.equal(result.builds, 'imgproxy');
    assert.match(result.stdout, /Building the imgproxy image: image was replaced by something else\./);
    assert.equal(run(f).builds, '');
  } finally { cleanup(f); }
});

test('a failed build records nothing, so the next run builds again', () => {
  const f = fixture();
  try {
    assert.equal(run(f).status, 0);
    const before = readFileSync(f.record, 'utf8');
    writeFileSync(join(f.root, 'docker/imgproxy/Dockerfile'), 'FROM example.invalid/imgproxy:2\n');
    const failed = run(f, { fail: 'build' });
    assert.notEqual(failed.status, 0);
    assert.match(failed.stderr, /Image build failed\. No service was started or stopped by this step, and nothing\nof this run was recorded as built\./);
    assert.equal(readFileSync(f.record, 'utf8'), before);
    assert.equal(run(f).builds, 'imgproxy');
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
    assert.equal(run(f, { args: ['--all'] }).builds, 'db imgproxy');
    assert.equal(run(f, { args: ['--no-cache'] }).builds, '--no-cache db imgproxy');
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
  const containers = 'db imgproxy prometheus grafana kong';
  assert.equal(run(f, { containers }).status, 0);
  return containers;
};

test('--replace-optional starts only the optional services that are running, and builds nothing', () => {
  const f = fixture();
  try {
    const containers = builtAll(f);
    const none = run(f, { args: ['--replace-optional'], containers, running: 'db imgproxy kong' });
    assert.equal(none.status, 0, none.stderr);
    assert.equal(none.ups, '');
    const some = run(f, { args: ['--replace-optional'], containers, running: 'db prometheus grafana kong' });
    assert.equal(some.status, 0, some.stderr);
    assert.equal(some.ups, '--wait --wait-timeout 180 grafana prometheus');
    assert.equal(some.builds, '');
    assert.match(some.stdout, /Optional services that are running: grafana prometheus\./);
    // An image of this project that has no build record yet (`compose build` by the monitoring
    // check, an installation from before the record) is still replaced.
    rmSync(f.record);
    const unrecorded = run(f, { args: ['--replace-optional'], containers, running: 'grafana prometheus' });
    assert.equal(unrecorded.status, 0, unrecorded.stderr);
    assert.equal(unrecorded.ups, '--wait --wait-timeout 180 grafana prometheus');
    const failed = run(f, { args: ['--replace-optional'], containers, running: 'prometheus', fail: 'up' });
    assert.notEqual(failed.status, 0);
    assert.match(failed.stderr, /An optional service did not start \(prometheus\)\. The core services are not affected/);
  } finally { cleanup(f); }
});

test('--replace-optional leaves a running optional service alone when its image is missing: start never builds', () => {
  const f = fixture();
  try {
    const containers = builtAll(f);
    // An upgrade renamed the image (Grafana's shared tag became `<project>-grafana`), or it was removed.
    rmSync(join(f.scratch, 'images', imageFile(`${PROJECT}-grafana`)));
    const result = run(f, { args: ['--replace-optional'], containers, running: 'db prometheus grafana kong' });
    assert.equal(result.status, 1, 'start.sh turns this into a warning');
    assert.equal(result.builds, '');
    assert.equal(result.ups, '--wait --wait-timeout 180 prometheus', 'the others are still replaced');
    assert.match(result.stderr, /the grafana image does not match this checkout \(image missing\); run `bash scripts\/build-images\.sh`/);
  } finally { cleanup(f); }
});

test('--replace-optional leaves a running optional service alone when its image was replaced by something else', () => {
  const f = fixture();
  try {
    const containers = builtAll(f);
    // Another checkout, a manual build: the tag names an image this checkout did not record.
    writeFileSync(join(f.scratch, 'images', imageFile(`${PROJECT}-grafana`)), `sha256:${'9'.repeat(64)}\n`);
    const result = run(f, { args: ['--replace-optional'], containers, running: 'grafana' });
    assert.equal(result.status, 1);
    assert.equal(result.builds, '');
    assert.equal(result.ups, '', 'nothing else is running, so nothing is started');
    assert.match(result.stderr, /the grafana image does not match this checkout \(image was replaced by something else\); run `bash scripts\/build-images\.sh`/);
    // The image setup.sh builds next puts it right.
    assert.equal(run(f, { containers }).builds, 'grafana');
    const after = run(f, { args: ['--replace-optional'], containers, running: 'grafana' });
    assert.equal(after.status, 0, after.stderr);
    assert.equal(after.ups, '--wait --wait-timeout 180 grafana');
  } finally { cleanup(f); }
});

test('it runs under the lock of the command that called it and refuses while another command holds the lock', () => {
  const f = fixture();
  try {
    // $1 is the script, $2 the lock file. Descriptor 9 is what setup.sh passes on.
    const inherited = run(f, { wrap: 'exec 9>"$2"; flock -n 9 || exit 70; bash "$1"' });
    assert.equal(inherited.status, 0, inherited.stderr);
    assert.equal(inherited.builds, 'db imgproxy');
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
    const fullStart = script.indexOf('bash "$ROOT/scripts/compose.sh" up -d --wait --wait-timeout 180');
    const replace = script.findIndex(line => line.startsWith('bash "$ROOT/scripts/build-images.sh" --replace-optional'));
    assert.ok(fullStart > 0 && replace > fullStart, `${name} replaces optional services after the full start`);
  }
  assert.ok(!lines('start.sh').includes('bash "$ROOT/scripts/build-images.sh"'), 'start.sh never builds');
});

test('the Grafana recipe is its own build directory, like every other recipe', () => {
  const override = readFileSync(join(repo, 'docker/docker-compose.override.yml'), 'utf8');
  // A context of `.` would put every file under docker/ into the Grafana fingerprint.
  assert.doesNotMatch(`${readFileSync(join(repo, 'docker/docker-compose.yml'), 'utf8')}\n${override}`, /^\s+context: \.$/m);
  assert.match(override, /grafana:\n    build:\n(?:\s+#.*\n)*\s+context: \.\/grafana\n/);
  assert.match(readFileSync(join(repo, 'docker/grafana/Dockerfile'), 'utf8'), /^COPY plugins\.lock install-plugins\.sh \/tmp\/$/m);
});

test('the PDF renderer image is pinned, verified and minimal', () => {
  // docker/pdf-renderer/Dockerfile downloads chrome-headless-shell from Chrome for Testing at
  // build time. Trivy cannot see that binary, so the version and the archive checksum are the
  // controls: both are build args, the checksum is checked, and nothing floats.
  const recipe = readFileSync(join(repo, 'docker/pdf-renderer/Dockerfile'), 'utf8');
  const instructions = recipe.replace(/\\\n/g, ' ').split('\n').filter(line => !line.trim().startsWith('#'));
  const text = instructions.join('\n');
  assert.match(recipe, /^ARG NODE_IMAGE=node:24-trixie-slim@sha256:[0-9a-f]{64}$/m, 'the base is Node 24 LTS on Debian trixie, pinned by digest');
  assert.deepEqual(instructions.filter(line => /^FROM /.test(line) && !/^FROM \$\{NODE_IMAGE\}( AS \S+)?$/.test(line) && !/@sha256:[0-9a-f]{64}/.test(line)), [], 'every base is the digest-pinned NODE_IMAGE');
  const version = /^ARG CHS_VERSION=(\d+\.\d+\.\d+\.\d+)$/m.exec(recipe)?.[1];
  const sha = /^ARG CHS_SHA256=([0-9a-f]{64})$/m.exec(recipe)?.[1];
  assert.ok(version, 'ARG CHS_VERSION has a four-part default');
  assert.ok(sha, 'ARG CHS_SHA256 has a SHA-256 default');
  assert.match(text, /sha256sum -c -/, 'the downloaded archive is checked against CHS_SHA256');
  assert.match(text, /\$\{?CHS_SHA256\}?/);
  assert.match(text, /storage\.googleapis\.com\/chrome-for-testing-public\/\$\{?CHS_VERSION\}?\//, 'the archive URL is built from CHS_VERSION');
  assert.doesNotMatch(text, /@stable|\blatest\b|last-known-good/, 'no floating Chrome channel or tag');
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
  // A fixed tag (Grafana's was `warehouse-grafana:local` until 2026-10-13) is shared by every
  // installation on the host: one checkout's build replaced another's running image.
  for (const file of ['docker/docker-compose.yml', 'docker/docker-compose.override.yml']) {
    const text = readFileSync(join(repo, file), 'utf8');
    const blocks = text.split(/\n(?=  [a-z][a-z0-9-]*:\n)/);
    for (const block of blocks.filter(item => /^    build:/m.test(item))) {
      assert.doesNotMatch(block, /^    image:/m, `${file}: ${block.split('\n')[0].trim()} has both build: and image:`);
    }
  }
  const override = readFileSync(join(repo, 'docker/docker-compose.override.yml'), 'utf8');
  assert.match(override, /\n  grafana:\n    build:\n/, 'the Grafana service is still built here');
});
