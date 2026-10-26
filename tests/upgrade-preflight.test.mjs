import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, copyFileSync, existsSync, rmSync, chmodSync, truncateSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { supportedNode } from '../scripts/doctor-common.mjs';

// scripts/upgrade-preflight.sh, the file every release carries and upgrade.sh runs from the TARGET release before the backup. Here it runs
// from a copy of a tree as upgrade.sh extracts it (the real preflight and upgrade-lib.sh, a stand-in doctor.mjs, a floor file and a
// CHANGELOG.md of the test's own), with the environment upgrade.sh gives it. tests/upgrade.test.mjs runs it through upgrade.sh.
const root = new URL('..', import.meta.url).pathname;
const GIB = 1024 ** 3;
const CHANGELOG = `# Changelog

## Unreleased

### Operator actions

1. Not released yet: UNRELEASED-ACTION

## v0.2.0 (2026-03-01)

### Operator actions

1. Before the upgrade, do the thing: BEFORE-ACTION-TWO.

### Changed

- HIDDEN-CHANGE.

## v0.1.0 (2026-01-01)

The first release.

## Older history

Git has it.
`;
const NAME = 'warehouse-20260101T000000Z';

// `doctor` is the exit status of the stand-in doctor.mjs (it records its arguments and WAREHOUSE_STATE_DIR in doctor.log next to it).
function world({ floor = 'from_floor=\nstepping_stone=\n', doctor = 0, changelog = CHANGELOG, withFloorFile = true } = {}) {
  const scratch = mkdtempSync(join(tmpdir(), 'warehouse-preflight-'));
  const tree = join(scratch, 'tree');
  const state = join(scratch, 'state');
  for (const dir of [join(tree, 'scripts'), join(state, 'config'), join(state, 'data'), join(state, 'backups'), join(scratch, 'bin')]) mkdirSync(dir, { recursive: true });
  for (const file of ['scripts/upgrade-preflight.sh', 'scripts/upgrade-lib.sh']) copyFileSync(join(root, file), join(tree, file));
  writeFileSync(join(tree, 'scripts/doctor.mjs'), `import { appendFileSync } from 'node:fs';
appendFileSync(new URL('doctor.log', import.meta.url), process.argv.slice(2).join(' ') + ' state=' + process.env.WAREHOUSE_STATE_DIR + '\\n');
if (${doctor} !== 0) { console.error('Doctor: Missing or unavailable prerequisite: rsync (fake).'); process.exit(${doctor}); }
console.log('Host prerequisites and state filesystem preflight passed.');
`);
  if (withFloorFile) writeFileSync(join(tree, 'scripts/upgrade-floor.txt'), `# comment\n${floor}`);
  writeFileSync(join(tree, 'CHANGELOG.md'), changelog);
  // `df` answers FAKE_DF_AVAIL as `df -B1 --output=avail -- DIR` does; `node -p process.versions.node` answers FAKE_NODE_VERSION when set.
  writeFileSync(join(scratch, 'bin/df'), '#!/bin/sh\nif [ -z "$FAKE_DF_AVAIL" ]; then exec /usr/bin/df "$@"; fi\nprintf "Avail\\n%s\\n" "$FAKE_DF_AVAIL"\n');
  writeFileSync(join(scratch, 'bin/node'), `#!/bin/sh\nif [ "$1" = -p ] && [ -n "$FAKE_NODE_VERSION" ]; then echo "$FAKE_NODE_VERSION"; exit 0; fi\nexec "${process.execPath}" "$@"\n`);
  chmodSync(join(scratch, 'bin/df'), 0o755); chmodSync(join(scratch, 'bin/node'), 0o755);
  const env = { FROM_SHA: 'a'.repeat(40), FROM_LABEL: 'v0.1.0', FROM_TAG: 'v0.1.0', TO_SHA: 'b'.repeat(40), TO_LABEL: 'v0.2.0', DRY: 'no' };
  // `terminal: true` puts a `tty` on the PATH that says standard input is a terminal (the preflight asks `tty -s`); no pseudo-terminal is opened,
  // and without it the child's standard input is a pipe. `input` is what that pipe holds.
  const run = (extra = {}, { terminal = false, input = undefined, pty = false } = {}) => {
    if (terminal) { writeFileSync(join(scratch, 'bin/tty'), '#!/bin/sh\nexit 0\n'); chmodSync(join(scratch, 'bin/tty'), 0o755); } else rmSync(join(scratch, 'bin/tty'), { force: true });
    // `pty`: through the `script` command, which gives the preflight a real pseudo-terminal as standard input (the repo's other terminal tests do the same).
    const [command, args] = pty ? ['script', ['-qec', `bash ${join(tree, 'scripts/upgrade-preflight.sh')}`, '/dev/null']] : ['bash', [join(tree, 'scripts/upgrade-preflight.sh')]];
    const r = spawnSync(command, args, { cwd: tree, encoding: 'utf8', input,
      env: { ...process.env, PATH: `${join(scratch, 'bin')}:${process.env.PATH}`, STATE: state, ...env, ...extra } });
    return { ...r, doctorLog: existsSync(join(tree, 'scripts/doctor.log')) ? readFileSync(join(tree, 'scripts/doctor.log'), 'utf8') : '' };
  };
  // A verified backup with the size of its stored files (format v6: storage_bytes in metadata.txt) and, when `dump` is given, of its database
  // dump, put on the verified list.
  const backup = (name, bytes, { v5 = false, dump = 0 } = {}) => {
    const dir = join(state, 'backups', name);
    mkdirSync(dir, { recursive: true });
    if (dump) { writeFileSync(join(dir, 'database.dump'), ''); truncateSync(join(dir, 'database.dump'), dump); }   // sparse: only its size counts
    writeFileSync(join(dir, 'metadata.txt'), v5 ? 'format=warehouse-backup-v5\n' : `format=warehouse-backup-v6\nstorage_bytes=${bytes}\n`);
    if (v5) writeFileSync(join(dir, 'storage.tar.gz'), Buffer.alloc(bytes));
    writeFileSync(join(state, 'config/backups-verified.list'), `${name} 1\n`, { flag: 'a' });
    return dir;
  };
  return { scratch, tree, state, run, backup, cleanup: () => rmSync(scratch, { recursive: true, force: true }) };
}

test('the preflight prints the operator actions of the target\'s CHANGELOG for the span before anything changes, and passes', () => {
  const w = world();
  try {
    const r = w.run();
    assert.equal(r.status, 0, r.stdout + r.stderr);
    assert.match(r.stdout, /What v0\.2\.0 asks of the operator[^]*before the upgrade, do the thing: BEFORE-ACTION-TWO/i, 'the "before" action is printed in the preflight');
    assert.match(r.stdout, /== v0\.2\.0 \(2026-03-01\)[^]*Also in this release: Changed/);
    assert.doesNotMatch(r.stdout, /HIDDEN-CHANGE|UNRELEASED-ACTION|The first release/);
    assert.match(r.stdout, /Preflight of v0\.2\.0 passed\./);
    assert.match(r.doctorLog, /^--host-preflight state=.*\/state\n$/, 'the doctor of the target release is asked for the host minimums, for this state');
    // A branch or commit has no section named by a tag: Unreleased is what it can hold.
    const ref = w.run({ TO_LABEL: 'bbbbbbb (--ref main)', DRY: 'yes' });
    assert.equal(ref.status, 0, ref.stderr);
    assert.match(ref.stdout, /== Unreleased[^]*UNRELEASED-ACTION/);
    assert.match(ref.stdout, /\(dry run\)/);
  } finally { w.cleanup(); }
});

test('a host that fails the target\'s own host check is refused with "Nothing was changed"', () => {
  const w = world({ doctor: 1 });
  try {
    const r = w.run();
    assert.equal(r.status, 1);
    assert.match(r.stderr, /Doctor: Missing or unavailable prerequisite: rsync \(fake\)/, 'the doctor\'s own message is shown');
    assert.match(r.stderr, /Refusing: this host does not meet what v0\.2\.0 needs[^]*Nothing was changed\./);
    assert.doesNotMatch(r.stdout, /Preflight of v0\.2\.0 passed/);
  } finally { w.cleanup(); }
});

test('the Node.js floor is the one of doctor-common.mjs: refused below it, accepted from it', () => {
  const w = world();
  try {
    for (const version of ['21.9.9', '22.0.0', '22.17.9', '22.18.0', '22.23.3', '23.0.0', '24.1.0']) {
      const r = w.run({ FAKE_NODE_VERSION: version });
      assert.equal(r.status === 0, supportedNode(version), `${version}: the preflight and supportedNode() agree (${r.stderr})`);
      if (!supportedNode(version)) assert.match(r.stderr, new RegExp(`Refusing: v0\\.2\\.0 needs Node\\.js 22\\.18 or newer on the host, and this host has ${version.replaceAll('.', '\\.')}[^]*Nothing was changed\\.`));
    }
    const odd = w.run({ FAKE_NODE_VERSION: 'not a version' });
    assert.equal(odd.status, 1);
    assert.match(odd.stderr, /could not read the Node\.js version/);
  } finally { w.cleanup(); }
});

test('the floor: an installation older than from_floor is refused and told the stepping stone; at or above it passes', () => {
  const floor = 'from_floor=v0.5.0\nstepping_stone=v0.5.2\n';
  const w = world({ floor });
  try {
    for (const old of ['v0.4.0', 'v0.4.9', 'v0.5.0-rc.2']) {
      const r = w.run({ FROM_TAG: old });
      assert.equal(r.status, 1, `${old} is below v0.5.0`);
      assert.match(r.stderr, new RegExp(`Refusing: v0\\.2\\.0 accepts an upgrade only from v0\\.5\\.0 or newer, and this checkout is at ${old.replaceAll('.', '\\.')}\\. Upgrade to v0\\.5\\.2 first \\(bash upgrade\\.sh v0\\.5\\.2\\)[^]*Nothing was changed\\.`));
      assert.doesNotMatch(r.stdout, /Preflight of v0\.2\.0 passed/);
    }
    for (const ok of ['v0.5.0', 'v0.5.1', 'v0.6.1', 'v1.0.0']) {
      const r = w.run({ FROM_TAG: ok });
      assert.equal(r.status, 0, `${ok}: ${r.stderr}`);
    }
    // A checkout that is on no release tag cannot be compared with the floor: refused, with the stone.
    const none = w.run({ FROM_TAG: '' });
    assert.equal(none.status, 1);
    assert.match(none.stderr, /is not on a release tag\. Upgrade to v0\.5\.2 first/);
  } finally { w.cleanup(); }
  // No stone named: the floor release itself. No floor: every installation passes, whatever its release.
  const bare = world({ floor: 'from_floor=v0.5.0\nstepping_stone=\n' });
  try {
    const r = bare.run({ FROM_TAG: 'v0.4.0' });
    assert.equal(r.status, 1);
    assert.match(r.stderr, /Upgrade to v0\.5\.0 first \(bash upgrade\.sh v0\.5\.0\)/);
  } finally { bare.cleanup(); }
  const none = world();
  try {
    assert.equal(none.run({ FROM_TAG: 'v0.0.1' }).status, 0);
    assert.equal(none.run({ FROM_TAG: '' }).status, 0);
  } finally { none.cleanup(); }
});

test('a floor file that is missing or holds something that is not a release tag stops the upgrade', () => {
  const missing = world({ withFloorFile: false });
  try {
    const r = missing.run();
    assert.equal(r.status, 1);
    assert.match(r.stderr, /does not ship scripts\/upgrade-floor\.txt[^]*Nothing was changed\./);
  } finally { missing.cleanup(); }
  const bad = world({ floor: 'from_floor=0.5\nstepping_stone=\n' });
  try {
    const r = bad.run();
    assert.equal(r.status, 1);
    assert.match(r.stderr, /holds '0\.5', which is not a release tag/);
  } finally { bad.cleanup(); }
});

test('the way back must fit: free space below the newest verified backup\'s stored files plus 1 GiB refuses, from that size on it passes', () => {
  const w = world();
  try {
    w.backup(NAME, 5 * GIB);
    const need = 5 * GIB + GIB;
    const short = w.run({ FAKE_DF_AVAIL: String(need - 1) });
    assert.equal(short.status, 1);
    assert.match(short.stderr, new RegExp(`Refusing: the way back from this upgrade is an in-place restore[^]*needs at least 6144 MiB free in ${w.state.replaceAll('.', '\\.')}/data \\(5120 MiB of stored files of ${NAME}, 0 MiB of its database dump, and 1 GiB to spare\\), and only ${Math.floor((need - 1) / 1048576)} MiB are free[^]*Nothing was changed\\.`));
    assert.doesNotMatch(short.stdout, /Preflight of v0\.2\.0 passed/);
    const exact = w.run({ FAKE_DF_AVAIL: String(need) });
    assert.equal(exact.status, 0, exact.stderr);
    assert.match(exact.stdout, /Room for the way back: 6144 MiB free, 6144 MiB needed \(the stored files of warehouse-20260101T000000Z, its database dump and 1 GiB; a minimum, since the photos added since, the new backup's dump and new images come on top\)/);
  } finally { w.cleanup(); }
});

test('the size comes from the newest verified backup that records one: a v5 backup counts by its tarball, and one without a size is skipped', () => {
  const w = world();
  try {
    w.backup('warehouse-20260101T000000Z', 9 * GIB);
    w.backup('warehouse-20260102T000000Z', 1024 * 1024, { v5: true });
    // The newest one is a v5 backup of 1 MiB: 1 MiB + 1 GiB is needed, not the 9 GiB of the older one.
    assert.equal(w.run({ FAKE_DF_AVAIL: String(GIB + 1024 * 1024) }).status, 0);
    assert.equal(w.run({ FAKE_DF_AVAIL: String(GIB + 1024 * 1024 - 1) }).status, 1);
    // A newer name on the list whose directory is gone, or that records no size, is passed over for the next older one.
    mkdirSync(join(w.state, 'backups/warehouse-20260103T000000Z'));
    writeFileSync(join(w.state, 'backups/warehouse-20260103T000000Z/metadata.txt'), 'format=warehouse-backup-v6\n');
    writeFileSync(join(w.state, 'config/backups-verified.list'), 'warehouse-20260104T000000Z 1\nwarehouse-20260103T000000Z 1\n', { flag: 'a' });
    assert.equal(w.run({ FAKE_DF_AVAIL: String(GIB + 1024 * 1024) }).status, 0, 'still the 1 MiB backup');
  } finally { w.cleanup(); }
});

test('with no verified backup, or free space that cannot be read, the room is not checked and the preflight still passes', () => {
  const w = world();
  try {
    const none = w.run({ FAKE_DF_AVAIL: '1' });
    assert.equal(none.status, 0, none.stderr);
    assert.match(none.stdout, /Room for the way back: not checked \(no verified backup is on record yet/);
    w.backup(NAME, 5 * GIB);
    const unreadable = w.run({ FAKE_DF_AVAIL: 'n/a' });
    assert.equal(unreadable.status, 0, unreadable.stderr);
    assert.match(unreadable.stdout, /Room for the way back: not checked \(the free space of .*\/data could not be read\)/);
  } finally { w.cleanup(); }
});

test('the way back must also fit the newest verified backup\'s database dump: it counts besides the stored files and 1 GiB, and the message says what it covers', () => {
  const w = world();
  try {
    const dump = 512 * 1024 * 1024;
    w.backup(NAME, 5 * GIB, { dump });
    const need = 6 * GIB + dump;
    const short = w.run({ FAKE_DF_AVAIL: String(need - 1) });
    assert.equal(short.status, 1, 'the stored files plus 1 GiB would have been enough');
    assert.match(short.stderr, /needs at least 6656 MiB free[^]*\(5120 MiB of stored files of warehouse-20260101T000000Z, 512 MiB of its database dump, and 1 GiB to spare\), and only 6655 MiB are free/);
    const exact = w.run({ FAKE_DF_AVAIL: String(need) });
    assert.equal(exact.status, 0, exact.stderr);
    assert.match(exact.stdout, /Room for the way back: 6656 MiB free, 6656 MiB needed \(the stored files of warehouse-20260101T000000Z, its database dump and 1 GiB; a minimum, since the photos added since/);
    // A backup with no dump file (or one that is not a plain file) adds nothing: the rule is the old one.
    const bare = world();
    try {
      bare.backup(NAME, 5 * GIB);
      assert.equal(bare.run({ FAKE_DF_AVAIL: String(6 * GIB) }).status, 0);
    } finally { bare.cleanup(); }
  } finally { w.cleanup(); }
});

test('the heading says what is printed: the releases after the old one, or only the target\'s section when the checkout is on no release tag', () => {
  const w = world();
  try {
    const tagged = w.run();
    assert.equal(tagged.status, 0, tagged.stderr);
    assert.match(tagged.stdout, /What v0\.2\.0 asks of the operator \(CHANGELOG\.md, the releases after v0\.1\.0, up to v0\.2\.0\)\./);
    const none = w.run({ FROM_TAG: '' });
    assert.equal(none.status, 0, none.stderr);
    assert.match(none.stdout, /What v0\.2\.0 asks of the operator \(CHANGELOG\.md, only the section of v0\.2\.0: this checkout is on no release tag, so there is no older release to count from\)\./);
    assert.doesNotMatch(none.stdout, /oldest release it lists/);
    // ... and that is all it prints: the section of the target, not v0.1.0's.
    assert.match(none.stdout, /== v0\.2\.0 \(2026-03-01\)/);
    assert.doesNotMatch(none.stdout, /== v0\.1\.0|The first release/);
  } finally { w.cleanup(); }
});

test('the pause after the operator actions: at a terminal in a real run it waits for Enter; a pipe, --yes, a dry run and a span with no operator actions never wait', () => {
  const w = world();
  try {
    const prompt = 'Press Enter to continue, Ctrl-C to stop (--yes skips this pause): ';
    // A terminal and Enter: the prompt follows the list, the text says nothing has been changed yet, and the preflight goes on to pass.
    const entered = w.run({}, { terminal: true, input: '\n' });
    assert.equal(entered.status, 0, entered.stderr);
    assert.match(entered.stdout, /Do every action that says "before" now; nothing has been changed yet:/);
    assert.ok(entered.stdout.indexOf('BEFORE-ACTION-TWO') < entered.stdout.indexOf(prompt) && entered.stdout.indexOf(prompt) < entered.stdout.indexOf('Preflight of v0.2.0 passed'));
    // A terminal and no answer: refused with "Nothing was changed", and the checks after the pause are not made.
    const eof = w.run({}, { terminal: true });
    assert.equal(eof.status, 1);
    assert.match(eof.stderr, /Refusing: no answer was read, so the upgrade did not go on\. Do the actions listed above, then run this command again\. Nothing was changed\./);
    assert.equal(eof.doctorLog, entered.doctorLog, 'the doctor was not asked again: the refusal came before the host checks');
    // No terminal: no prompt, a different line, the run passes. ASSUME_YES=yes at a terminal: no prompt. DRY=yes at a terminal: no prompt.
    const piped = w.run();
    assert.equal(piped.status, 0, piped.stderr);
    assert.ok(!piped.stdout.includes('Press Enter'));
    assert.match(piped.stdout, /This run goes on after the list without stopping, so an action that says "before" should be done already/);
    for (const [label, extra] of [['--yes', { ASSUME_YES: 'yes' }], ['a dry run', { DRY: 'yes' }]]) {
      const r = w.run(extra, { terminal: true });
      assert.equal(r.status, 0, `${label}: ${r.stderr}`);
      assert.ok(!r.stdout.includes('Press Enter'), label);
    }
    // A span with no operator actions in it: nothing to stop for.
    const quiet = world({ changelog: CHANGELOG.replace('### Operator actions\n\n1. Before the upgrade, do the thing: BEFORE-ACTION-TWO.\n\n', '') });
    try {
      const r = quiet.run({}, { terminal: true });
      assert.equal(r.status, 0, r.stderr);
      assert.ok(!r.stdout.includes('Press Enter'));
      assert.match(r.stdout, /\(no operator actions listed\)/);
    } finally { quiet.cleanup(); }
  } finally { w.cleanup(); }
});

const haveScript = spawnSync('script', ['--version'], { encoding: 'utf8' }).status === 0;
test('on a real pseudo-terminal the preflight waits for Enter after the operator actions, and stops when the input ends', { skip: !haveScript && 'the script command (util-linux) is not installed' }, () => {
  const w = world();
  try {
    const prompt = 'Press Enter to continue, Ctrl-C to stop (--yes skips this pause): ';
    const entered = w.run({}, { pty: true, input: '\n' });
    assert.equal(entered.status, 0, entered.stdout + entered.stderr);
    assert.ok(entered.stdout.includes(prompt), 'a terminal: the pause is made');
    assert.match(entered.stdout, /Preflight of v0\.2\.0 passed\./);
    const eof = w.run({}, { pty: true, input: '' });
    assert.notEqual(eof.status, 0, 'no answer: the preflight refuses');
    assert.match(eof.stdout + eof.stderr, /no answer was read, so the upgrade did not go on/);
    // --yes on the same terminal: no pause at all, nothing to answer.
    const yes = w.run({ ASSUME_YES: 'yes' }, { pty: true, input: '' });
    assert.equal(yes.status, 0, yes.stdout + yes.stderr);
    assert.ok(!yes.stdout.includes('Press Enter'));
  } finally { w.cleanup(); }
});
