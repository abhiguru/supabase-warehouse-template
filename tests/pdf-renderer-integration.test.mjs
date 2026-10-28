import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, existsSync, rmSync, symlinkSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

// docker/pdf-renderer/test/integration.sh with a fake docker, on a PATH that has no pdftotext, so that it builds the pinned poppler image.
// The fake health check never comes up, which ends the script early; what is read is the cleanup that follows: which image it removes.
const SCRIPT = new URL('../docker/pdf-renderer/test/integration.sh', import.meta.url).pathname;
const id = c => `sha256:${c.repeat(64)}`;
const POPPLER = id('a');
const OTHER = id('0');
const TOOLS = ['env', 'bash', 'dirname', 'mktemp', 'git', 'seq', 'curl', 'grep', 'tail', 'head', 'sed', 'rm', 'mkdir', 'chmod', 'cat', 'id', 'tr', 'sort', 'wc', 'awk'];

function run({ snapshot = [], build = POPPLER, listFails = false } = {}) {
  const scratch = mkdtempSync(join(tmpdir(), 'warehouse-pdfr-it-test-'));
  const bin = join(scratch, 'bin');
  mkdirSync(bin);
  for (const tool of TOOLS) {
    const found = spawnSync('bash', ['-c', `command -v ${tool}`], { encoding: 'utf8' }).stdout.trim();
    if (found) symlinkSync(found, join(bin, tool));
  }
  assert.ok(!existsSync(join(bin, 'pdftotext')));
  const calls = join(scratch, 'calls');
  writeFileSync(join(scratch, 'snapshot'), snapshot.map(i => `${i}\n`).join(''));
  writeFileSync(join(bin, 'sleep'), '#!/bin/sh\nexit 0\n', { mode: 0o755 });
  writeFileSync(join(bin, 'docker'), `#!/bin/bash
printf '%s\\n' "$*" >> "${calls}"
case "$1" in
  build) echo "$FAKE_BUILD_ID" ;;
  image) case "$2" in
    ls) [ "$FAKE_LS_FAILS" = 1 ] && exit 1; cat "${scratch}/snapshot" ;;
    prune) echo 'image prune must never be called' >&2; exit 99 ;;
  esac ;;
  rmi) echo 'rmi must not be used' >&2 ;;
  port) echo '3000/tcp -> 127.0.0.1:1' ;;
  inspect) echo 172.20.0.9 ;;
esac
exit 0
`, { mode: 0o755 });
  const r = spawnSync('/usr/bin/env', ['bash', SCRIPT], { encoding: 'utf8', timeout: 120000, cwd: scratch,
    env: { PATH: bin, HOME: scratch, TMPDIR: scratch, IMAGE: 'pdf-renderer:fake', FAKE_BUILD_ID: build, FAKE_LS_FAILS: listFails ? '1' : '0' } });
  const lines = existsSync(calls) ? readFileSync(calls, 'utf8').split('\n').filter(Boolean) : [];
  rmSync(scratch, { recursive: true, force: true });
  return { ...r, lines, removals: lines.filter(l => /^(image rm|rmi)( |$)/.test(l)) };
}

test('integration.sh: the poppler image is built untagged after the listing, and tagged for this run and removed by that tag, without -f, when the build made it', () => {
  const r = run({ snapshot: [OTHER] });
  const build = r.lines.find(l => l.startsWith('build '));
  assert.match(build, /^build -q [^ ]+\/tests\/golden-pdf$/, 'untagged: no -t');
  assert.ok(r.lines.indexOf('image ls -aq --no-trunc') >= 0 && r.lines.indexOf('image ls -aq --no-trunc') < r.lines.indexOf(build), 'snapshot before the build');
  const tag = r.lines.find(l => l.startsWith('tag '));
  assert.match(tag, new RegExp(`^tag ${POPPLER} pdf-golden-tools:it-\\d+$`), 'the new id gets this run\'s tag');
  assert.deepEqual(r.removals, [`image rm ${tag.split(' ')[2]}`], 'only that tag is removed, never the id: another run on the host may share the image');
  assert.ok(r.lines.indexOf(tag) > r.lines.indexOf(build), 'tagged after the build');
  // A second run on the same host gets its own tag, so neither removes the other's name.
  assert.notEqual(run({ snapshot: [OTHER] }).lines.find(l => l.startsWith('tag ')), tag);
});

test('integration.sh: an image id that was on the host before the build is never removed', () => {
  const r = run({ snapshot: [OTHER, POPPLER] });
  assert.ok(r.lines.some(l => l.startsWith('build -q ')), 'the build ran');
  assert.deepEqual(r.removals, [], r.lines.join('\n'));
  assert.ok(!r.lines.some(l => l.startsWith('tag ')), 'an id that was there gets no tag of ours');
});

test('integration.sh: when the listing fails or the build prints no id, nothing is built on trust and nothing is removed', () => {
  let r = run({ listFails: true });
  assert.ok(!r.lines.some(l => l.startsWith('build -q ')), 'no build without a snapshot');
  assert.deepEqual(r.removals, []);
  r = run({ build: 'not-an-id' });
  assert.deepEqual(r.removals, []);
});
