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
function world({ floor = 'from_floor=\nstepping_stone=\n', doctor = 0, changelog = CHANGELOG, withFloorFile = true, definitions = [] } = {}) {
  const scratch = mkdtempSync(join(tmpdir(), 'warehouse-preflight-'));
  const tree = join(scratch, 'tree');
  const state = join(scratch, 'state');
  for (const dir of [join(tree, 'scripts'), join(state, 'config'), join(state, 'data'), join(state, 'backups'), join(scratch, 'bin')]) mkdirSync(dir, { recursive: true });
  for (const file of ['scripts/upgrade-preflight.sh', 'scripts/upgrade-lib.sh', 'scripts/upgrade-rehearse.sh', 'scripts/migration-plan.mjs', 'scripts/is-main.mjs']) copyFileSync(join(root, file), join(tree, file));
  // The rehearsal's two outside parts are stand-ins that log to rehearsal.log: verify-restore.sh (--keep names a container, --rm removes it;
  // FAKE_VERIFY_FAIL makes it fail) and docker (`docker exec ... psql` reads the plan, echoes its "Applying:" lines and fails with an
  // ERROR at the file named by FAKE_FAIL_FILE). The migrations are two small files of the test's own.
  mkdirSync(join(tree, 'migrations'));
  writeFileSync(join(tree, 'migrations/00000000000001_one.sql'), 'SELECT 1;\n');
  writeFileSync(join(tree, 'migrations/00000000000002_two.sql'), 'SELECT 2;\n');
  // Definition files of the target (migrations/definitions/), when the test asks for some: each holds one function and its REVOKE line.
  if (definitions.length) mkdirSync(join(tree, 'migrations/definitions'));
  for (const name of definitions) {
    const fn = name.replace(/\.sql$/, '').replace(/^[0-9]+_/, '');
    writeFileSync(join(tree, 'migrations/definitions', name), `CREATE OR REPLACE FUNCTION public.${fn}() RETURNS integer LANGUAGE sql AS $$ SELECT 1 $$;\nREVOKE ALL ON FUNCTION public.${fn}() FROM PUBLIC;\n`);
  }
  writeFileSync(join(tree, 'scripts/verify-restore.sh'), `#!/bin/bash
echo "verify-restore $*" >> "$FAKE_LOG"
if [ "$1" = --rm ]; then exit 0; fi
if [ -n "$FAKE_VERIFY_SLEEP" ]; then sleep "$FAKE_VERIFY_SLEEP"; fi
if [ "$FAKE_VERIFY_FAIL" = diag ]; then echo "Restore database did not start (fake)." >&2; echo "Restore verification failed. Container log, state and database sessions were saved in /x" >&2; echo "  (the database did not answer)" >&2; exit 1; fi
if [ "$FAKE_VERIFY_FAIL" = offline ]; then echo "docker: Error response from daemon: Get \\"https://registry-1.docker.io/v2/\\": dial tcp: lookup registry-1.docker.io: no such host (fake)." >&2; echo >&2; echo "Run 'docker run --help' for more information" >&2; exit 125; fi
if [ -n "$FAKE_VERIFY_FAIL" ]; then echo "Integrity comparison differs (fake)." >&2; exit 1; fi
echo "Restore verification: disposable database of 768 MiB (fake)."
echo "Kept disposable database: warehouse-restore-0123456789ab (database warehouse_restore, user supabase_admin; remove it with: bash scripts/verify-restore.sh --rm warehouse-restore-0123456789ab)"
`);
  writeFileSync(join(scratch, 'bin/docker'), `#!/bin/sh
echo "docker $*" >> "$FAKE_LOG"
cat > "$FAKE_LOG.plan"
awk -v fail="$FAKE_FAIL_FILE" '/echo Applying: / { name = $3; print "Applying: " name; if (name == fail) { print "psql:<stdin>:7: ERROR:  fixture failure in " name > "/dev/stderr"; exit 3 } }
/echo Checking definition: / { name = $4; print "Checking definition: " name; if (name == fail) { print "psql:<stdin>:9: ERROR:  fixture failure in " name > "/dev/stderr"; exit 3 } }
/echo Applying definition: / { print "Applying definition: " $4 }
/echo Definition unchanged: / { print "Definition unchanged: " $4 }' "$FAKE_LOG.plan"
`);
  chmodSync(join(scratch, 'bin/docker'), 0o755);
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
  const run = (extra = {}, { terminal = false, input = undefined, pty = false, hold = false } = {}) => {
    if (terminal) { writeFileSync(join(scratch, 'bin/tty'), '#!/bin/sh\nexit 0\n'); chmodSync(join(scratch, 'bin/tty'), 0o755); } else rmSync(join(scratch, 'bin/tty'), { force: true });
    // `pty`: through the `script` command, which gives the preflight a real pseudo-terminal as standard input (the repo's other terminal tests do the same).
    const [command, args] = pty ? ['script', ['-qec', `bash ${join(tree, 'scripts/upgrade-preflight.sh')}`, '/dev/null']] : ['bash', [join(tree, 'scripts/upgrade-preflight.sh')]];
    // `hold`: standard input is a pipe that stays open for 5 seconds (the message tells a time-out from the input ending) and says nothing (an operator who walked away).
    const r = hold ? spawnSync('sh', ['-c', 'sleep 5 | bash "$0"', join(tree, 'scripts/upgrade-preflight.sh')], { cwd: tree, encoding: 'utf8',
      env: { ...process.env, PATH: `${join(scratch, 'bin')}:${process.env.PATH}`, STATE: state, FAKE_LOG: join(scratch, 'rehearsal.log'), ...env, ...extra } })
      : spawnSync(command, args, { cwd: tree, encoding: 'utf8', input,
      env: { ...process.env, PATH: `${join(scratch, 'bin')}:${process.env.PATH}`, STATE: state, FAKE_LOG: join(scratch, 'rehearsal.log'), ...env, ...extra } });
    return { ...r, rehearsalLog: existsSync(join(scratch, 'rehearsal.log')) ? readFileSync(join(scratch, 'rehearsal.log'), 'utf8') : '',
      plan: existsSync(join(scratch, 'rehearsal.log.plan')) ? readFileSync(join(scratch, 'rehearsal.log.plan'), 'utf8') : '', doctorLog: existsSync(join(tree, 'scripts/doctor.log')) ? readFileSync(join(tree, 'scripts/doctor.log'), 'utf8') : '' };
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
    // The pause is the LAST step: the host check ran (and would have refused first) before the operator was asked anything, and "passed" was not printed.
    assert.equal(eof.doctorLog, `${entered.doctorLog}${entered.doctorLog.split('\n').slice(-2)[0]}\n`, 'the doctor was asked again: the refusal came after the host checks');
    assert.ok(!eof.stdout.includes('Preflight of v0.2.0 passed'));
    // A host that fails its check is refused WITHOUT the question: the operator is not asked to confirm a run that is then refused.
    const bad = world({ doctor: 1 });
    try {
      const refused = bad.run({}, { terminal: true, input: '\n' });
      assert.equal(refused.status, 1);
      assert.ok(!refused.stdout.includes('Press Enter'), 'no prompt before a refusal');
      assert.match(refused.stderr, /this host does not meet what v0\.2\.0 needs/);
    } finally { bad.cleanup(); }
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

test('the pause ends by itself when nobody answers: refused with "Nothing was changed", and a window of silence is not mistaken for an answer', () => {
  const w = world();
  try {
    const silent = w.run({ UPGRADE_PAUSE_SECONDS: '1' }, { terminal: true, hold: true });
    assert.equal(silent.status, 1, silent.stdout + silent.stderr);
    assert.match(silent.stderr, /Refusing: nobody pressed Enter within 1 seconds, so the upgrade did not go on and the operator lock is released\. Do the actions listed above, then run this command again\. Nothing was changed\./);
    assert.ok(!silent.stdout.includes('Preflight of v0.2.0 passed'));
    // An unusable limit falls back to 30 minutes (here: Enter arrives at once, so the run passes).
    const fallback = w.run({ UPGRADE_PAUSE_SECONDS: 'soon' }, { terminal: true, input: '\n' });
    assert.equal(fallback.status, 0, fallback.stderr);
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

test('the migrations of the target are rehearsed on a restored copy of the newest verified backup, with --dry-run too, and the copy is removed', () => {
  const w = world();
  try {
    w.backup('warehouse-20260101T000000Z', 1024, { dump: 1024 });
    w.backup('warehouse-20260102T000000Z', 1024, { dump: 1024 });
    for (const DRY of ['no', 'yes']) {
      const r = w.run({ DRY });
      assert.equal(r.status, 0, r.stdout + r.stderr);
      assert.match(r.stdout, /Rehearsal of the migrations of v0\.2\.0: restoring warehouse-20260102T000000Z into a disposable database/, 'the newest verified backup is the one restored');
      assert.match(r.stdout, /Rehearsal of the migrations: passed \(2 to apply, 0 already applied\) on a copy of warehouse-20260102T000000Z; applying them took \d+ s\./);
      assert.ok(r.stdout.indexOf('Rehearsal of the migrations: passed') < r.stdout.indexOf('Preflight of v0.2.0 passed'), 'the rehearsal is part of the preflight');
      assert.match(r.rehearsalLog, /verify-restore --keep --no-storage-tree .*\/backups\/warehouse-20260102T000000Z\n/);
      assert.match(r.rehearsalLog, /docker exec -i -e PGPASSWORD=disposable-restore-only warehouse-restore-0123456789ab psql .* -d warehouse_restore/, 'the plan goes to the kept container');
      assert.match(r.plan, /Applying: 00000000000001_one\.sql[^]*Applying: 00000000000002_two\.sql/, 'the plan is the target tree\'s own migrations');
      assert.match(r.rehearsalLog, /verify-restore --rm warehouse-restore-0123456789ab\n$/, 'the disposable database is removed at the end');
      rmSync(join(w.scratch, 'rehearsal.log'), { force: true });
    }
  } finally { w.cleanup(); }
});

test('a migration that fails on the copy refuses the upgrade before anything changes, naming the file and the database\'s message, and still removes the copy', () => {
  const w = world();
  try {
    w.backup(NAME, 1024, { dump: 1024 });
    const r = w.run({ FAKE_FAIL_FILE: '00000000000002_two.sql' });
    assert.equal(r.status, 1);
    assert.match(r.stderr, /ERROR:  fixture failure in 00000000000002_two\.sql/, 'the database\'s own message is shown');
    assert.match(r.stderr, /Refusing: v0\.2\.0 cannot be installed on this facility: the migration 00000000000002_two\.sql does not apply to a copy of your data[^]*the facility is unchanged[^]*Nothing was changed\./);
    assert.doesNotMatch(r.stdout, /Rehearsal of the migrations: passed|Preflight of v0\.2\.0 passed/);
    assert.match(r.rehearsalLog, /verify-restore --rm warehouse-restore-0123456789ab\n$/, 'a refusal removes the copy too');
  } finally { w.cleanup(); }
});

test('a definition file that fails on the copy is named as the definition, and the pass line counts the definition files', () => {
  const w = world({ definitions: ['00_first.sql', 'second.sql'] });
  try {
    w.backup(NAME, 1024, { dump: 1024 });
    const bad = w.run({ FAKE_FAIL_FILE: 'second.sql' });
    assert.equal(bad.status, 1);
    assert.match(bad.stderr, /ERROR:  fixture failure in second\.sql/);
    assert.match(bad.stderr, /Refusing: v0\.2\.0 cannot be installed on this facility: the definition second\.sql does not apply to a copy of your data/);
    assert.doesNotMatch(bad.stderr, /the migration 00000000000002_two\.sql does not apply/, 'not blamed on the last migration, which applied');
    assert.match(bad.rehearsalLog, /verify-restore --rm warehouse-restore-0123456789ab\n$/);
    const good = w.run();
    assert.equal(good.status, 0, good.stdout + good.stderr);
    assert.match(good.stdout, /Rehearsal of the migrations: passed \(2 to apply, 0 already applied\) on a copy of warehouse-20260101T000000Z; applying them took \d+ s\. Definition files: 2 applied, 2 unchanged\./);
  } finally { w.cleanup(); }
});

test('a backup that cannot be restored for the rehearsal refuses the upgrade; with no verified backup the rehearsal says it was not made', () => {
  const w = world();
  try {
    const none = w.run();
    assert.equal(none.status, 0, none.stderr);
    assert.match(none.stderr, /Warning: the migrations were NOT rehearsed: no verified backup is on record yet/, 'a warning on standard error, not a line among the others');
    assert.doesNotMatch(none.stdout, /not made|NOT rehearsed/);
    assert.equal(none.rehearsalLog, '', 'nothing was started');
    w.backup(NAME, 1024, { dump: 1024 });
    const r = w.run({ FAKE_VERIFY_FAIL: '1' });
    assert.equal(r.status, 1);
    assert.match(r.stderr, /Integrity comparison differs \(fake\)\.[^]*Refusing: the newest verified backup \(warehouse-20260101T000000Z\) could not be restored into the disposable database[^]*Nothing was changed\./);
    assert.doesNotMatch(r.rehearsalLog, /docker exec/, 'no plan was sent');
  } finally { w.cleanup(); }
});

// The name of a backup made `hours` ago, as scripts/backup.sh names it (UTC).
const backupNamed = hours => `warehouse-${new Date(Date.now() - hours * 3600e3).toISOString().replace(/[-:]/g, '').replace(/\.\d+Z$/, 'Z')}`;

test('the rehearsal restores only (no integrity comparison) and says which backup it used and how old it is; an old one is warned about on standard error', () => {
  const w = world();
  try {
    const fresh = backupNamed(5);
    w.backup(fresh, 1024, { dump: 1024 });
    const r = w.run();
    assert.equal(r.status, 0, r.stdout + r.stderr);
    assert.match(r.rehearsalLog, /verify-restore --keep --no-storage-tree --restore-only .*\/backups\/warehouse-/, 'the copy is restored without the target\'s integrity comparison');
    assert.match(r.stdout, new RegExp(`restoring ${fresh} into[^]*That backup was made \\d{4}-\\d\\d-\\d\\d \\d\\d:\\d\\d:\\d\\d UTC, 5 hours ago\\.`), 'name, time and age are printed');
    assert.doesNotMatch(r.stderr, /Warning: this backup is/, 'a recent backup is not warned about');
    const w2 = world();
    try {
      w2.backup('warehouse-20260101T030405Z', 1024, { dump: 1024 });
      const o = w2.run();
      assert.equal(o.status, 0, o.stdout + o.stderr);
      assert.match(o.stdout, /That backup was made 2026-01-01 03:04:05 UTC, \d+ days ago\./);
      assert.match(o.stderr, /Warning: this backup is \d+ days old\. Rows entered after 2026-01-01 03:04:05 UTC are not on the copy[^]*node scripts\/watch\.mjs record-verified/);
    } finally { w2.cleanup(); }
    // A name that has the pattern but no valid date (month 99) has no age: not "20000+ days", and no age warning.
    const w3 = world();
    try {
      w3.backup('warehouse-20269999T030405Z', 1024, { dump: 1024 });
      const bad = w3.run();
      assert.equal(bad.status, 0, bad.stdout + bad.stderr);
      assert.match(bad.stdout, /That backup was made 2026-99-99 03:04:05 UTC \(of unknown age: its name holds no valid date\)\./);
      assert.doesNotMatch(bad.stdout + bad.stderr, /\d{4,} days/);
      assert.doesNotMatch(bad.stderr, /Warning: this backup is/);
    } finally { w3.cleanup(); }
  } finally { w.cleanup(); }
});

test('only the migrations are timed, not the restore; a failed restore shows its own last line and advice that works', () => {
  const w = world();
  try {
    w.backup(backupNamed(1), 1024, { dump: 1024 });
    const r = w.run({ FAKE_VERIFY_SLEEP: '3' });
    assert.equal(r.status, 0, r.stdout + r.stderr);
    const took = Number(/applying them took (\d+) s\./.exec(r.stdout)?.[1]);
    assert.ok(took < 3, `the restore (3 s here) is not in the time: ${took}`);
    const failed = w.run({ FAKE_VERIFY_FAIL: '1' });
    assert.equal(failed.status, 1);
    assert.match(failed.stderr, /The restore said: Integrity comparison differs \(fake\)\./, 'the restore\'s own last line is in the refusal');
    assert.match(failed.stderr, /free disk space or memory[^]*bash scripts\/backup\.sh[^]*verify-restore\.sh[^]*record-verified/);
    const diag = w.run({ FAKE_VERIFY_FAIL: 'diag' });
    assert.match(diag.stderr, /The restore said: Restore database did not start \(fake\)\. The host may be/, 'the message before the diagnostics, not the diagnostics\' last line');
    const offline = w.run({ FAKE_VERIFY_FAIL: 'offline' });
    assert.match(offline.stderr, /The restore said: docker: Error response from daemon: .*no such host \(fake\)\. The host may be/, 'the error, not Docker\'s help hint after it');
    assert.doesNotMatch(offline.stderr, /The restore said: Run /);
    assert.doesNotMatch(failed.stderr, /Take a new backup/, 'a backup that is only made is not used; the advice no longer says that');
  } finally { w.cleanup(); }
});
