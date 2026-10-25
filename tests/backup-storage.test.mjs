// Backup format v6: the object storage as a tree of hard-linked files with a signed manifest (scripts/backup.sh), the
// tree checks of backup-key.sh and verify-restore.sh, and restores of v5 and v6 backups. Everything runs against a fake
// `docker` on PATH and the real rsync, tar and sha256sum; tests that need extended attributes skip themselves where the
// temporary directory cannot hold them.
import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, existsSync, readdirSync, rmSync, statSync, symlinkSync, utimesSync, chmodSync, openSync, writeSync, closeSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { makeBackup, makeState, fakeDocker, fakeBackupDocker, scriptRoot, composeEnv, signBackup, writeKey, xattrTool, xattrSkip, filesUnder, manifestOf } from './backup-test-helpers.mjs';

const script = name => new URL(`../scripts/${name}`, import.meta.url).pathname;
const OBJECT = 'stub/stub/documents/a.pdf/v1';
const meta = dir => Object.fromEntries(readFileSync(join(dir, 'metadata.txt'), 'utf8').trim().split('\n').map(line => [line.slice(0, line.indexOf('=')), line.slice(line.indexOf('=') + 1)]));

// A state with live object storage, and the fake docker for backup.sh.
function installation(prefix) {
  const scratch = mkdtempSync(join(tmpdir(), prefix));
  const state = makeState(scratch);
  rmSync(join(state, 'data/storage/current-object'));
  mkdirSync(join(state, 'backups'), { mode: 0o700 });
  const bin = fakeBackupDocker(join(scratch, 'bin'));
  let runs = 0;
  const f = {
    scratch, state, bin, live: join(state, 'data/storage'),
    put(path, body = `bytes of ${path}`, mtime = null) {
      mkdirSync(dirname(join(f.live, path)), { recursive: true });
      writeFileSync(join(f.live, path), body);
      if (mtime) utimesSync(join(f.live, path), mtime, mtime);
    },
    // Runs scripts/backup.sh into state/backups/NAME; `extra` adds environment (and PATH entries in `path`).
    backup(name, extra = {}, { path = '' } = {}) {
      const log = join(scratch, `docker-${++runs}.log`);
      const dest = join(state, 'backups', name);
      const result = spawnSync('bash', [script('backup.sh'), dest], { encoding: 'utf8', env: {
        ...process.env, PATH: `${path ? path + ':' : ''}${bin}:${process.env.PATH}`, WAREHOUSE_STATE_DIR: state,
        FAKE_DOCKER_LOG: log, FAKE_STAGE_PARENT: join(state, 'backups'), ...extra } });
      return { ...result, dest, calls: existsSync(log) ? readFileSync(log, 'utf8') : '' };
    },
    done() { rmSync(scratch, { recursive: true, force: true }); },
  };
  return f;
}
const ok = (result, label = 'backup') => { assert.equal(result.status, 0, `${label}: ${result.stderr}`); return result; };
const inode = path => statSync(path).ino;

test('a second backup of unchanged photos hard-links them and stores no new bytes; a new photo costs only itself', () => {
  const f = installation('warehouse-backup-links-');
  try {
    f.put(OBJECT, 'a'.repeat(1000));
    f.put('stub/stub/documents/b.pdf/v1', 'b'.repeat(2000));
    const first = ok(f.backup('warehouse-20260101T000001Z'));
    assert.equal(meta(first.dest).link_base, 'none');
    assert.equal(meta(first.dest).storage_new_bytes, '3000');
    assert.equal(statSync(join(first.dest, 'storage', OBJECT)).nlink, 1);
    assert.match(first.stdout, /Object storage: 2 files, 3\.0KiB new, no earlier tree backup to link from\./);

    const second = ok(f.backup('warehouse-20260101T000002Z'));
    const m = meta(second.dest);
    assert.equal(m.link_base, 'warehouse-20260101T000001Z');
    assert.equal(m.storage_files, '2');
    assert.equal(m.storage_bytes, '3000');
    assert.equal(m.storage_new_bytes, '0', 'nothing was copied');
    for (const path of [OBJECT, 'stub/stub/documents/b.pdf/v1']) {
      assert.equal(inode(join(first.dest, 'storage', path)), inode(join(second.dest, 'storage', path)), `${path} is one file in both backups`);
      assert.equal(statSync(join(second.dest, 'storage', path)).nlink, 2);
    }
    assert.match(second.stdout, /Object storage: 2 files, 0B new, linked from warehouse-20260101T000001Z\./);
    assert.match(second.stdout, /Services were stopped for \d+s \(0 files copied or removed in the final pass\)/);

    // One photo added, one removed from the live storage: the third backup holds the new bytes only, and the removed photo
    // stays in the older backups (photos are never deleted from a snapshot).
    f.put('stub/stub/documents/c.pdf/v1', 'c'.repeat(500));
    rmSync(join(f.live, 'stub/stub/documents/b.pdf/v1'));
    const third = ok(f.backup('warehouse-20260101T000003Z'));
    assert.equal(meta(third.dest).link_base, 'warehouse-20260101T000002Z');
    assert.equal(meta(third.dest).storage_files, '2');
    assert.equal(meta(third.dest).storage_new_bytes, '500');
    assert.equal(statSync(join(third.dest, 'storage', OBJECT)).nlink, 3, 'a is shared by all three');
    assert.equal(statSync(join(third.dest, 'storage/stub/stub/documents/c.pdf/v1')).nlink, 1);
    assert.equal(existsSync(join(third.dest, 'storage/stub/stub/documents/b.pdf/v1')), false, 'the third backup is the live storage as it was');
    assert.equal(readFileSync(join(first.dest, 'storage/stub/stub/documents/b.pdf/v1'), 'utf8'), 'b'.repeat(2000), 'the first backup still holds it');
    assert.equal(readFileSync(join(second.dest, 'storage/stub/stub/documents/b.pdf/v1'), 'utf8'), 'b'.repeat(2000), 'and the second');
    assert.deepEqual(readFileSync(join(third.dest, 'storage.manifest'), 'utf8').trim().split('\n').map(line => line.slice(66)), [OBJECT, 'stub/stub/documents/c.pdf/v1']);
    // The backups are independent of the live storage: no hard link between them.
    assert.equal(statSync(join(f.live, OBJECT)).nlink, 1);
    assert.notEqual(inode(join(f.live, OBJECT)), inode(join(third.dest, 'storage', OBJECT)));
    // Every one of them verifies on its own.
    for (const backup of [first, second, third]) {
      const checked = spawnSync('bash', ['-c', 'source "$1"; WAREHOUSE_BACKUP_KEY_FILE="$2" backup_authenticate "$3" false', 'x', script('backup-key.sh'), join(f.state, 'config/backup.key'), backup.dest], { encoding: 'utf8' });
      assert.equal(checked.status, 0, checked.stderr);
    }
  } finally { f.done(); }
});

test('the link base is the newest verified backup, else the newest tree backup, else none; the list file may not exist', () => {
  const f = installation('warehouse-backup-base-');
  try {
    f.put(OBJECT);
    const names = [1, 2, 3].map(n => `warehouse-2026010${n}T000000Z`);
    assert.equal(meta(ok(f.backup(names[0])).dest).link_base, 'none');
    // No list at all: the newest v6 backup.
    assert.equal(meta(ok(f.backup(names[1])).dest).link_base, names[0]);
    assert.equal(meta(ok(f.backup(names[2])).dest).link_base, names[1]);
    // A v5 backup newer than all of them is no base (no tree to link to).
    makeBackup(join(f.state, 'backups', 'warehouse-20260105T000000Z'));
    assert.equal(meta(ok(f.backup('warehouse-20260106T000000Z')).dest).link_base, names[2]);
    // The list names the verified ones: the newest verified is chosen over the newer unverified ones, whatever else it lists.
    const list = join(f.state, 'config/backups-verified.list');
    writeFileSync(list, `${names[0]} 1790000000\nwarehouse-20260105T000000Z 1790000001\nwarehouse-20260101T999999Z 1790000002\nnot a backup name\n`);
    assert.equal(meta(ok(f.backup('warehouse-20260107T000000Z')).dest).link_base, names[0], 'the v5 and the missing entries are skipped');
    writeFileSync(list, `${names[1]} 1790000000\n${names[0]} 1789999999\n`);
    const based = ok(f.backup('warehouse-20260108T000000Z'));
    assert.equal(meta(based.dest).link_base, names[1]);
    assert.equal(statSync(join(based.dest, 'storage', OBJECT)).nlink >= 2, true);
    // A list that names nothing usable falls back to the newest tree backup.
    writeFileSync(list, 'warehouse-20260101T999999Z 1\n');
    assert.equal(meta(ok(f.backup('warehouse-20260109T000000Z')).dest).link_base, 'warehouse-20260108T000000Z');
  } finally { f.done(); }
});

test('the services stop only for the dump and the last copy pass: the copy starts with the API up and the hashing waits for the restart', () => {
  const f = installation('warehouse-backup-window-');
  try {
    f.put(OBJECT);
    f.put('stub/stub/documents/b.pdf/v1');
    // At the moment the first service stops, the Storage service finishes one more upload and removes another file.
    const result = ok(f.backup('warehouse-20260101T000001Z', {
      FAKE_ON_STOP: `mkdir -p "${join(f.live, 'stub/stub/documents/late.pdf')}" && printf late > "${join(f.live, 'stub/stub/documents/late.pdf/v1')}"; rm -f "${join(f.live, 'stub/stub/documents/b.pdf/v1')}"`,
    }));
    const lines = result.calls.split('\n');
    const at = needle => { const index = lines.findIndex(line => line.includes(needle)); assert.ok(index >= 0, `no call ${needle}`); return index; };
    const stop = at('SNAPSHOT stop'), dump = at('SNAPSHOT pg_dump'), up = at('SNAPSHOT up');
    assert.ok(stop < dump && dump < up, 'stop, then the dump, then the restart');
    assert.equal(lines.filter(line => / stop /.test(line)).length >= 1 && at(' stop ') < dump, true, 'every stop precedes the dump');
    // Before anything stopped, the first pass had already copied both files (the API was up for it).
    assert.match(lines[stop], /tree=pass1 files=2 manifest=no dump=no/);
    assert.match(lines[dump], /tree=pass1 files=2 manifest=no dump=no/, 'the last pass has not run when the dump starts');
    // At the restart the dump exists, the tree is final (made by the last pass, under the stop), and the manifest is not made
    // yet: hashing happens with the API up.
    assert.match(lines[up], /tree=final files=2 manifest=no dump=yes/);
    // The final pass settled the late changes: the new file is in, the removed one is out.
    assert.deepEqual(filesUnder(join(result.dest, 'storage')), [OBJECT, 'stub/stub/documents/late.pdf/v1']);
    assert.deepEqual(readFileSync(join(result.dest, 'storage.manifest'), 'utf8').trim().split('\n').map(line => line.slice(66)), [OBJECT, 'stub/stub/documents/late.pdf/v1']);
    assert.match(result.stdout, /\(2 files copied or removed in the final pass\)/, 'the late upload was copied and the removed file deleted by the last pass');
    // Both services that were running came back, with the dependency-free restart of before.
    assert.match(result.calls, /up -d --no-recreate --no-deps --wait --wait-timeout 180 gateway storage/);
  } finally { f.done(); }
});

test('a link, a special file or an unwritable name in the live storage refuses the backup before any service stops', () => {
  const f = installation('warehouse-backup-unsafe-');
  try {
    f.put(OBJECT);
    symlinkSync('/etc/passwd', join(f.live, 'stub-link'));
    let result = f.backup('warehouse-20260101T000001Z');
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /Refusing: the object storage holds a link, a special file or a name with a newline or backslash: .*stub-link/);
    assert.doesNotMatch(result.calls, / stop |pg_dump/, 'nothing was stopped or dumped');
    assert.equal(existsSync(result.dest), false);
    rmSync(join(f.live, 'stub-link'));
    f.put('stub/stub/documents/odd\\name.pdf/v1');
    result = f.backup('warehouse-20260101T000002Z');
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /Refusing: the object storage holds a link, a special file or a name with a newline or backslash/);
    rmSync(join(f.live, 'stub/stub/documents/odd\\name.pdf'), { recursive: true });
    f.put('stub/stub/documents/odd\nname.pdf/v1');
    result = f.backup('warehouse-20260101T000003Z');
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /Refusing: the object storage holds a link, a special file or a name with a newline or backslash/);
    assert.doesNotMatch(result.calls, / stop |pg_dump/);
    assert.deepEqual(readdirSync(join(f.state, 'backups')), [], 'no staging directory is left behind');
  } finally { f.done(); }
});

test('a copy that cannot read the live storage fails before anything is stopped', { skip: process.getuid?.() === 0 && 'root reads every file' }, () => {
  const f = installation('warehouse-backup-unreadable-');
  try {
    f.put(OBJECT);
    f.put('stub/stub/documents/secret.pdf/v1');
    chmodSync(join(f.live, 'stub/stub/documents/secret.pdf/v1'), 0o000);
    const result = f.backup('warehouse-20260101T000001Z');
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /Refusing: copying the object storage failed \(rsync exit 23\)\. Nothing was stopped\./);
    assert.doesNotMatch(result.calls, / stop |pg_dump/);
    assert.deepEqual(readdirSync(join(f.state, 'backups')), []);
  } finally { chmodSync(join(f.live, 'stub/stub/documents/secret.pdf/v1'), 0o600); f.done(); }
});

test('a staging directory older than two hours is removed, a recent one is left alone', () => {
  const f = installation('warehouse-backup-stale-');
  try {
    f.put(OBJECT);
    const old = join(f.state, 'backups/.warehouse-backup-staging.OLDOLD01');
    const recent = join(f.state, 'backups/.warehouse-backup-staging.NEWNEW01');
    for (const dir of [old, recent]) { mkdirSync(join(dir, 'storage/sub'), { recursive: true }); writeFileSync(join(dir, 'storage/sub/file'), 'partial'); }
    chmodSync(join(old, 'storage/sub'), 0o500);
    const longAgo = new Date(Date.now() - 3 * 3600 * 1000);
    utimesSync(old, longAgo, longAgo);
    ok(f.backup('warehouse-20260101T000001Z'));
    assert.equal(existsSync(old), false, 'the stale staging directory is gone');
    assert.equal(existsSync(recent), true, 'a recent one may belong to something still running');
  } finally { f.done(); }
});

// ---- A damaged copy in the link base ----------------------------------------------------------------------------

const SEVEN = new Date('2026-01-01T00:00:00Z');
const authenticate = (f, dir) => spawnSync('bash', ['-c', 'source "$1"; WAREHOUSE_BACKUP_KEY_FILE="$2" backup_authenticate "$3" false', 'x', script('backup-key.sh'), join(f.state, 'config/backup.key'), dir], { encoding: 'utf8' });
const lastLine = text => text.trim().split('\n').pop();
// Bit rot: same size, same time, other bytes.
function rot(path) { const fd = openSync(path, 'r+'); writeSync(fd, 'X', 3); closeSync(fd); utimesSync(path, SEVEN, SEVEN); }
const RESTARTED = /up -d --no-recreate --no-deps --wait --wait-timeout 180 gateway storage/;
// A sha256sum that fails the way a bad sector does for the file whose path ends in FAKE_UNREADABLE (it reports it and reads the
// rest); with FAKE_UNREADABLE_SHARED=yes only while that file is shared with another backup (link count above 1), as a bad
// sector belongs to one inode and not to a fresh copy.
function unreadableShim(scratch) {
  const shim = join(scratch, 'sha-shim'); mkdirSync(shim);
  const real = spawnSync('which', ['sha256sum'], { encoding: 'utf8' }).stdout.trim();
  writeFileSync(join(shim, 'sha256sum'), `#!/bin/sh
bad=0
for a in "$@"; do
  shift
  case "$a" in *"$FAKE_UNREADABLE") if [ -n "$FAKE_UNREADABLE" ] && { [ "$FAKE_UNREADABLE_SHARED" != yes ] || [ "$(stat -c %h -- "$a" 2>/dev/null)" -gt 1 ]; }; then echo "sha256sum: $a: Input/output error" >&2; bad=1; continue; fi ;; esac
  set -- "$@" "$a"
done
${real} "$@"; rc=$?
[ "$bad" = 0 ] || rc=1
exit $rc
`, { mode: 0o755 });
  return shim;
}

test('a shared file that no longer matches the base manifest is copied again from the live storage: the backup goes on, says so, and holds a good copy', () => {
  const f = installation('warehouse-backup-rot-');
  try {
    f.put(OBJECT, 'a'.repeat(100), SEVEN);
    f.put('stub/stub/documents/b.pdf/v1', 'b'.repeat(100), SEVEN);
    f.put('stub/stub/documents/c.pdf/v1', 'c'.repeat(100), SEVEN);
    const first = ok(f.backup('warehouse-20260101T000001Z'));
    const damaged = join(first.dest, 'storage', OBJECT);
    rot(damaged);
    rot(join(first.dest, 'storage/stub/stub/documents/b.pdf/v1'));
    const second = ok(f.backup('warehouse-20260101T000002Z'), 'a damaged copy in the base does not stop the backup');
    const m = meta(second.dest);
    assert.equal(m.link_base, 'warehouse-20260101T000001Z');
    assert.equal(m.rot_repaired, '2');
    assert.deepEqual(readFileSync(join(second.dest, 'metadata.txt'), 'utf8').split('\n').filter(line => line.startsWith('rot_repaired_file=')), [`rot_repaired_file=${OBJECT}`, 'rot_repaired_file=stub/stub/documents/b.pdf/v1']);
    assert.equal(m.storage_new_bytes, '200', 'the two photos copied again are the new bytes');
    // The warning is the last line on standard error, in the shape the daily status reads; the repair does not fail the night.
    assert.match(lastLine(second.stderr), /^WARNING: 2 files re-copied: backup warehouse-20260101T000001Z has a damaged copy\./);
    assert.match(second.stderr, /^  stub\/stub\/documents\/a\.pdf\/v1$/m, 'the files are named');
    // The new backup holds the live bytes in files of its own; the untouched photo is still shared; the older backup is as it was.
    assert.equal(readFileSync(join(second.dest, 'storage', OBJECT), 'utf8'), 'a'.repeat(100));
    assert.equal(statSync(join(second.dest, 'storage', OBJECT)).nlink, 1);
    assert.notEqual(inode(join(second.dest, 'storage', OBJECT)), inode(damaged));
    assert.equal(statSync(join(second.dest, 'storage/stub/stub/documents/c.pdf/v1')).nlink, 2, 'an intact photo stays shared');
    assert.equal(readFileSync(damaged, 'utf8')[3], 'X', 'the damaged copy of the older backup was not touched');
    assert.equal(statSync(damaged).nlink, 1, 'and is no longer shared with the new backup');
    // Signed, whole, and the manifest is in byte order of the path with the fresh lines in place.
    const checked = authenticate(f, second.dest);
    assert.equal(checked.status, 0, checked.stderr);
    assert.equal(readFileSync(join(second.dest, 'storage.manifest'), 'utf8'), manifestOf(join(second.dest, 'storage')));
    assert.notEqual(authenticate(f, first.dest).status, 0, 'the older backup fails its checksum: the damage is real and stays visible');
    assert.match(second.calls, RESTARTED, 'the services were up again before any of this');
    // The next night links from the good copy and has nothing to say.
    const third = ok(f.backup('warehouse-20260101T000003Z'));
    assert.equal(meta(third.dest).link_base, 'warehouse-20260101T000002Z');
    assert.equal(meta(third.dest).rot_repaired, '0');
    assert.doesNotMatch(third.stderr, /WARNING/);
    assert.equal(statSync(join(third.dest, 'storage', OBJECT)).nlink, 2);
  } finally { f.done(); }
});

test('a shared file that cannot be read (a disk error) is copied again too; an unreadable file of the new copy itself fails the night, naming it last', () => {
  const f = installation('warehouse-backup-eio-');
  try {
    f.put(OBJECT, 'a'.repeat(100), SEVEN);
    f.put('stub/stub/documents/b.pdf/v1', 'b'.repeat(100), SEVEN);
    const shim = unreadableShim(f.scratch);
    // First backup: a file of the copy itself cannot be read back. Nothing to repair it from: refused.
    const refused = f.backup('warehouse-20260101T000001Z', { FAKE_UNREADABLE: 'documents/b.pdf/v1' }, { path: shim });
    assert.notEqual(refused.status, 0);
    assert.match(refused.stderr, /sha256sum: .*documents\/b\.pdf\/v1: Input\/output error/);
    assert.match(lastLine(refused.stderr), /^Refusing: 1 file\(s\) of the new backup could not be read back to take their checksum .*first: stub\/stub\/documents\/b\.pdf\/v1\./);
    assert.equal(existsSync(refused.dest), false);
    assert.match(refused.calls, RESTARTED, 'the services came back');
    // A good first backup, then the same unreadable file in the base while it is shared: copied again from the live storage.
    ok(f.backup('warehouse-20260101T000002Z'));
    const second = ok(f.backup('warehouse-20260101T000003Z', { FAKE_UNREADABLE: 'documents/b.pdf/v1', FAKE_UNREADABLE_SHARED: 'yes' }, { path: shim }));
    assert.equal(meta(second.dest).rot_repaired, '1');
    assert.match(lastLine(second.stderr), /^WARNING: 1 file re-copied: backup warehouse-20260101T000002Z has a damaged copy\./);
    assert.equal(statSync(join(second.dest, 'storage/stub/stub/documents/b.pdf/v1')).nlink, 1);
    assert.equal(statSync(join(second.dest, 'storage', OBJECT)).nlink, 2);
    assert.equal(authenticate(f, second.dest).status, 0, 'readable again for the check (the shim only fails the backup run)');
  } finally { f.done(); }
});

test('a shared file whose live copy disagrees with the recorded checksum too fails that night, and the next one copies everything instead of linking', () => {
  const f = installation('warehouse-backup-rot-both-');
  try {
    f.put(OBJECT, 'a'.repeat(100), SEVEN);
    f.put('stub/stub/documents/b.pdf/v1', 'b'.repeat(100), SEVEN);
    const first = ok(f.backup('warehouse-20260101T000001Z'));
    rot(join(first.dest, 'storage', OBJECT));
    // The live file rotted too: same size and time, other bytes than the ones the base recorded.
    const fd = openSync(join(f.live, OBJECT), 'r+'); writeSync(fd, 'Y', 5); closeSync(fd); utimesSync(join(f.live, OBJECT), SEVEN, SEVEN);
    const second = f.backup('warehouse-20260101T000002Z');
    assert.notEqual(second.status, 0);
    assert.match(second.stderr, /^  stub\/stub\/documents\/a\.pdf\/v1$/m, 'the file is named');
    assert.match(lastLine(second.stderr), /^Refusing: the stored files cannot be backed up as they are\. Repair the files named above .*storage file fails its checksum.*The next backup copies all stored files again instead of linking them from warehouse-20260101T000001Z\./);
    assert.equal(existsSync(second.dest), false);
    assert.match(second.calls, RESTARTED);
    assert.deepEqual(readdirSync(join(f.state, 'backups')), ['warehouse-20260101T000001Z'], 'no staging directory is left');
    assert.equal(readFileSync(join(f.state, 'config/link-base-rejected'), 'utf8'), 'warehouse-20260101T000001Z\n');
    assert.equal(readFileSync(join(first.dest, 'storage/stub/stub/documents/b.pdf/v1'), 'utf8'), 'b'.repeat(100), 'the older backup is untouched');
    const third = ok(f.backup('warehouse-20260101T000003Z'));
    assert.equal(meta(third.dest).link_base, 'none', 'the rejected backup is not used as a base any more');
    assert.match(third.stderr, /Note: warehouse-20260101T000001Z is not used as the link base: a night found its stored files damaged/);
    assert.equal(meta(third.dest).storage_new_bytes, '200');
    assert.equal(authenticate(f, third.dest).status, 0);
    assert.equal(meta(ok(f.backup('warehouse-20260101T000004Z')).dest).link_base, 'warehouse-20260101T000003Z', 'and the one after that is linked from the new copy');
  } finally { f.done(); }
});

test('a link base that fails its own signature check is skipped, with a warning naming it: the next older one is used, else a full copy', () => {
  const f = installation('warehouse-backup-badbase-');
  try {
    f.put(OBJECT, 'a'.repeat(100), SEVEN);
    f.put('stub/stub/documents/b.pdf/v1', 'b'.repeat(100), SEVEN);
    const names = [1, 2, 3, 4].map(n => `warehouse-2026010${n}T000000Z`);
    const backups = names.map(name => ok(f.backup(name)).dest);
    // The newest has lost its signature; the one before it has a damaged storage.manifest (what the cross-check trusts).
    rmSync(join(backups[3], 'SHA256SUMS.hmac'));
    writeFileSync(join(backups[2], 'storage.manifest'), readFileSync(join(backups[2], 'storage.manifest'), 'utf8').replace(/^./, c => (c === '0' ? '1' : '0')));
    const fifth = ok(f.backup('warehouse-20260105T000000Z'));
    assert.equal(meta(fifth.dest).link_base, names[1], 'the newest backup that authenticates');
    assert.match(fifth.stderr, new RegExp(`Warning: ${names[3]} is not used as the link base: it fails its signature and checksum check \\(`));
    assert.match(fifth.stderr, new RegExp(`Warning: ${names[2]} is not used as the link base: it fails its signature and checksum check \\(`));
    assert.match(fifth.stderr, new RegExp(`db:verify-restore -- ${f.state}/backups/${names[3]}`));
    assert.equal(meta(fifth.dest).storage_new_bytes, '0', 'the good older backup is linked from');
    assert.equal(meta(fifth.dest).rot_repaired, '0');
    assert.equal(authenticate(f, fifth.dest).status, 0);
    // The verified list does not change that: it names the bad ones first, they are still skipped, each is named once.
    writeFileSync(join(f.state, 'config/backups-verified.list'), `${names[3]} 1790000003\n${names[2]} 1790000002\n${names[1]} 1790000001\n`);
    const sixth = ok(f.backup('warehouse-20260106T000000Z'));
    assert.equal(meta(sixth.dest).link_base, names[1]);
    assert.equal(sixth.stderr.split(`Warning: ${names[3]} is not used`).length, 2, 'warned once, although both lists name it');
    // No usable backup at all: a full copy.
    for (const name of [...names.slice(0, 2), 'warehouse-20260105T000000Z', 'warehouse-20260106T000000Z']) rmSync(join(f.state, 'backups', name, 'SHA256SUMS.hmac'));
    const seventh = ok(f.backup('warehouse-20260107T000000Z'));
    assert.equal(meta(seventh.dest).link_base, 'none');
    assert.equal(meta(seventh.dest).storage_new_bytes, '200');
    assert.equal(authenticate(f, seventh.dest).status, 0);
  } finally { f.done(); }
});

test('a link base on another filesystem is skipped', () => {
  const f = installation('warehouse-backup-otherfs-');
  try {
    f.put(OBJECT);
    ok(f.backup('warehouse-20260101T000001Z'));
    // A stat that reports another device for that backup's storage/, as a mount point inside backups/ would.
    const shim = join(f.scratch, 'stat-shim'); mkdirSync(shim);
    const real = spawnSync('which', ['stat'], { encoding: 'utf8' }).stdout.trim();
    writeFileSync(join(shim, 'stat'), `#!/bin/sh
case "$*" in *"%d"*"warehouse-20260101T000001Z/storage"*) echo 4242; exit 0 ;; esac
exec ${real} "$@"
`, { mode: 0o755 });
    const second = ok(f.backup('warehouse-20260101T000002Z', {}, { path: shim }));
    assert.equal(meta(second.dest).link_base, 'none');
    assert.match(second.stderr, /Warning: warehouse-20260101T000001Z is not used as the link base: it is on another filesystem than the new backup/);
    assert.equal(statSync(join(second.dest, 'storage', OBJECT)).nlink, 1);
  } finally { f.done(); }
});

// ---- The last pass must not change what earlier backups share -----------------------------------------------------

// The premise, with rsync alone: a file that exists at the destination (a hard link to the base after pass 1) gets its extended
// attributes and mode changed in place when size and time match, which changes the base's file. The scheme backup.sh uses
// (pass 2 into a new directory that links from pass 1 and the base) leaves the older file alone.
test('rsync sets attributes of an existing hard-linked destination file in place; a new destination with --link-dest does not touch the older file', { skip: xattrSkip() }, () => {
  const scratch = mkdtempSync(join(tmpdir(), 'warehouse-rsync-inplace-'));
  try {
    const tool = xattrTool();
    const make = name => { const dir = join(scratch, name); mkdirSync(dir); return dir; };
    const live = make('live'), base = make('base');
    for (const name of ['f', 'g']) { writeFileSync(join(live, name), `bytes of ${name}`); utimesSync(join(live, name), SEVEN, SEVEN); tool.set(join(live, name), 'user.supabase.content-type', 'application/pdf'); }
    const rsync = (...args) => { const r = spawnSync('rsync', args, { encoding: 'utf8' }); assert.equal(r.status, 0, r.stderr); return r.stdout; };
    rsync('-rptX', `${live}/`, `${base}/`);
    const pass1 = join(scratch, 'pass1');
    rsync('-rptX', `--link-dest=${base}`, `${live}/`, `${pass1}/`);
    assert.equal(inode(join(pass1, 'f')), inode(join(base, 'f')), 'pass 1 links the unchanged files');
    // After pass 1 the live files change attributes only (neither changes the modification time).
    tool.set(join(live, 'f'), 'user.supabase.content-type', 'text/plain');
    chmodSync(join(live, 'g'), 0o640);
    const baseMode = statSync(join(base, 'g')).mode & 0o777;
    const inPlace = join(scratch, 'in-place');
    assert.equal(spawnSync('cp', ['-al', pass1, inPlace]).status, 0);
    rsync('-rptX', `--link-dest=${base}`, '--delete', `${live}/`, `${inPlace}/`);
    assert.equal(tool.get(join(base, 'f'), 'user.supabase.content-type'), 'text/plain', 'premise: the in-place pass changed the BASE file');
    assert.equal(statSync(join(base, 'g')).mode & 0o777, 0o640, 'premise: and its mode');
    // Again from the start, with a new destination for pass 2.
    tool.set(join(base, 'f'), 'user.supabase.content-type', 'application/pdf'); chmodSync(join(base, 'g'), baseMode);
    const final = join(scratch, 'final');
    rsync('-rptX', `--link-dest=${pass1}`, `--link-dest=${base}`, `${live}/`, `${final}/`);
    assert.equal(tool.get(join(base, 'f'), 'user.supabase.content-type'), 'application/pdf', 'the base keeps its attribute');
    assert.equal(tool.get(join(pass1, 'f'), 'user.supabase.content-type'), 'application/pdf');
    assert.equal(statSync(join(base, 'g')).mode & 0o777, baseMode, 'and its mode');
    assert.equal(tool.get(join(final, 'f'), 'user.supabase.content-type'), 'text/plain');
    assert.equal(statSync(join(final, 'g')).mode & 0o777, 0o640);
    assert.notEqual(inode(join(final, 'f')), inode(join(base, 'f')));
  } finally { rmSync(scratch, { recursive: true, force: true }); }
});

test('attributes or mode changed in the live storage while the services are stopped do not reach the files that earlier backups share', { skip: xattrSkip() }, () => {
  const f = installation('warehouse-backup-passtwo-');
  try {
    const tool = xattrTool();
    const A = OBJECT, B = 'stub/stub/documents/b.pdf/v1', C = 'stub/stub/documents/c.pdf/v1';
    for (const path of [A, B, C]) { f.put(path, `bytes of ${path}`, SEVEN); tool.set(join(f.live, path), 'user.supabase.content-type', 'application/pdf'); }
    const first = ok(f.backup('warehouse-20260101T000001Z'));
    const second = ok(f.backup('warehouse-20260101T000002Z'));
    const modes = { [A]: statSync(join(first.dest, 'storage', A)).mode & 0o777, [B]: statSync(join(first.dest, 'storage', B)).mode & 0o777 };
    // At the moment the services stop (after the first pass linked everything), one file gets another content type and another
    // one another mode; neither changes the modification time.
    const third = ok(f.backup('warehouse-20260101T000003Z', {
      FAKE_ON_STOP: `${tool.shell(join(f.live, A), 'user.supabase.content-type', 'text/plain')} && chmod 640 '${join(f.live, B)}'`,
    }));
    for (const dest of [first.dest, second.dest]) {
      assert.equal(tool.get(join(dest, 'storage', A), 'user.supabase.content-type'), 'application/pdf', `${dest}: the older backup keeps its content type`);
      assert.equal(statSync(join(dest, 'storage', B)).mode & 0o777, modes[B], `${dest}: and its mode`);
      assert.equal(statSync(join(dest, 'storage', A)).mode & 0o777, modes[A]);
    }
    assert.equal(tool.get(join(third.dest, 'storage', A), 'user.supabase.content-type'), 'text/plain', 'the new backup has the live attributes');
    assert.equal(statSync(join(third.dest, 'storage', B)).mode & 0o777, 0o640);
    assert.equal(statSync(join(third.dest, 'storage', A)).nlink, 1, 'copied, not linked');
    assert.equal(statSync(join(third.dest, 'storage', B)).nlink, 1);
    assert.equal(statSync(join(third.dest, 'storage', C)).nlink, 3, 'the file that did not change is still one file in three backups');
    assert.equal(statSync(join(first.dest, 'storage', A)).nlink, 2, 'the two older backups still share theirs');
    assert.match(third.stdout, /\(2 files copied or removed in the final pass\)/);
    for (const dest of [first.dest, second.dest, third.dest]) assert.equal(authenticate(f, dest).status, 0, `${dest} is whole`);
  } finally { f.done(); }
});

test('an unchanged photo whose attributes changed is copied again; attributes and times survive the backup', { skip: xattrSkip() }, () => {
  const f = installation('warehouse-backup-xattr-');
  try {
    const tool = xattrTool();
    const when = new Date('2026-02-03T04:05:06Z');
    f.put(OBJECT, '%PDF-fictional', when);
    tool.set(join(f.live, OBJECT), 'user.supabase.content-type', 'application/pdf');
    tool.set(join(f.live, OBJECT), 'user.supabase.cache-control', 'max-age=3600');
    const first = ok(f.backup('warehouse-20260101T000001Z'));
    const copy = join(first.dest, 'storage', OBJECT);
    assert.equal(tool.get(copy, 'user.supabase.content-type'), 'application/pdf');
    assert.equal(tool.get(copy, 'user.supabase.cache-control'), 'max-age=3600');
    assert.equal(statSync(copy).mtimeMs, when.getTime(), 'the modification time of the photo is kept, not reset');
    // The next night the attribute is unchanged: linked, attributes still there.
    const second = ok(f.backup('warehouse-20260101T000002Z'));
    assert.equal(statSync(join(second.dest, 'storage', OBJECT)).nlink, 2);
    assert.equal(tool.get(join(second.dest, 'storage', OBJECT), 'user.supabase.content-type'), 'application/pdf');
    // The type changes in the live storage (same bytes, same time): a link would keep the old type, so the file is copied.
    tool.set(join(f.live, OBJECT), 'user.supabase.content-type', 'text/plain');
    const third = ok(f.backup('warehouse-20260101T000003Z'));
    const changed = join(third.dest, 'storage', OBJECT);
    assert.equal(tool.get(changed, 'user.supabase.content-type'), 'text/plain');
    assert.equal(statSync(changed).nlink, 1, 'not shared with the older backups');
    assert.equal(meta(third.dest).storage_new_bytes, String('%PDF-fictional'.length));
    assert.equal(tool.get(join(first.dest, 'storage', OBJECT), 'user.supabase.content-type'), 'application/pdf', 'the older backup keeps its own type');
  } finally { f.done(); }
});

test('a backup destination that drops extended attributes is detected by the empty dry run and the backup is refused', { skip: xattrSkip() }, () => {
  const f = installation('warehouse-backup-nodrop-');
  try {
    f.put(OBJECT);
    xattrTool().set(join(f.live, OBJECT), 'user.supabase.content-type', 'application/pdf');
    // An rsync that copies without -X, as a destination filesystem without attributes would behave.
    const shim = join(f.scratch, 'shim'); mkdirSync(shim);
    const real = spawnSync('which', ['rsync'], { encoding: 'utf8' }).stdout.trim();
    writeFileSync(join(shim, 'rsync'), `#!/bin/sh
case " $* " in *' -n '*|*' -rptXn '*) exec ${real} "$@" ;; esac
args=""
for a in "$@"; do case "$a" in -rptX) a=-rpt ;; esac; args="$args '$a'"; done
eval exec ${real} $args
`, { mode: 0o755 });
    const result = f.backup('warehouse-20260101T000001Z', {}, { path: shim });
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /Refusing: the copy of the object storage is not identical to the live storage after the final pass/);
    assert.match(result.stderr, /x/, 'the first differing entries are printed');
    assert.equal(existsSync(result.dest), false);
    assert.match(result.calls, /up -d --no-recreate --no-deps --wait --wait-timeout 180 gateway storage/, 'the services come back');
  } finally { f.done(); }
});

test('a facility with no stored files yet still backs up, backs up and authenticates: an empty tree and an empty manifest', () => {
  const f = installation('warehouse-backup-empty-');
  try {
    const made = ok(f.backup('warehouse-20260101T000001Z'));
    assert.equal(readFileSync(join(made.dest, 'storage.manifest'), 'utf8'), '');
    assert.equal(meta(made.dest).storage_files, '0');
    assert.equal(meta(made.dest).storage_bytes, '0');
    assert.ok(statSync(join(made.dest, 'storage')).isDirectory());
    assert.match(made.stdout, /Object storage: 0 files, 0B new, no earlier tree backup to link from\./);
    const checked = spawnSync('bash', ['-c', 'source "$1"; WAREHOUSE_BACKUP_KEY_FILE="$2" backup_authenticate "$3" false', 'x', script('backup-key.sh'), join(f.state, 'config/backup.key'), made.dest], { encoding: 'utf8' });
    assert.equal(checked.status, 0, checked.stderr);
    const second = ok(f.backup('warehouse-20260101T000002Z'));
    assert.equal(meta(second.dest).link_base, 'warehouse-20260101T000001Z');
  } finally { f.done(); }
});

// ---- Verification, restores -------------------------------------------------------------------------------------

function verify(backup, scratch, { env = {}, args = [] } = {}) {
  const log = join(scratch, 'docker.log');
  writeFileSync(log, '');
  const result = spawnSync('bash', [script('verify-restore.sh'), ...args, backup], { encoding: 'utf8', env: {
    ...process.env, PATH: `${fakeDocker(join(scratch, 'bin'))}:${process.env.PATH}`, FAKE_DOCKER_LOG: log,
    FAKE_CATALOG_FILE: join(backup, 'storage_objects.txt'), WAREHOUSE_STATE_DIR: '', WAREHOUSE_VERIFY_SCRATCH_DIR: '',
    WAREHOUSE_BACKUP_KEY_FILE: writeKey(join(scratch, 'backup.key')), WAREHOUSE_DIAGNOSTICS_DIR: join(scratch, 'diagnostics'), ...env } });
  return { ...result, calls: readFileSync(log, 'utf8') };
}
const v6 = (dir, options = {}) => makeBackup(dir, { format: 'warehouse-backup-v6', ...options });
// Rewrites the label of a backup, lists its files again and signs: what only the key holder could do, to give a label and a
// list that disagree.
function relabel(backup, format) {
  const names = readFileSync(join(backup, 'SHA256SUMS'), 'utf8').trim().split('\n').map(line => line.slice(66));
  writeFileSync(join(backup, 'metadata.txt'), readFileSync(join(backup, 'metadata.txt'), 'utf8').replace(/^format=.*$/m, `format=${format}`));
  const sums = spawnSync('sha256sum', names, { cwd: backup, encoding: 'utf8' });
  writeFileSync(join(backup, 'SHA256SUMS'), sums.stdout);
  signBackup(backup);
}

test('the verifier accepts v6 and v5, takes the file list from the manifest for v6 and checks every file of the tree', () => {
  const scratch = mkdtempSync(join(tmpdir(), 'warehouse-verify-v6-'));
  try {
    const good = v6(join(scratch, 'good'), { objects: ['documents/a.pdf/v1', 'dispatch-images/c1/photo.jpg/v7'] });
    const passed = verify(good, scratch);
    assert.equal(passed.status, 0, passed.stderr);
    assert.match(passed.stdout, /Backup signature, checksums, storage tree, database restore, and integrity comparison passed\./);
    assert.match(passed.calls, /^run -d --pull missing/m);
    assert.equal(verify(makeBackup(join(scratch, 'five')), scratch).status, 0, 'v5 still verifies');

    // An object of the catalog that the manifest does not list; an extra file is a warning only.
    const missing = v6(join(scratch, 'missing'), { objects: ['documents/a.pdf/v1', 'documents/lost.pdf/v2'], files: [OBJECT] });
    const failed = verify(missing, scratch);
    assert.notEqual(failed.status, 0);
    assert.match(failed.stderr, /Catalogued storage objects are missing from the storage tree \(storage\.manifest\):\ndocuments\/lost\.pdf\/v2/);
    assert.doesNotMatch(failed.calls, /^run /m, 'no container is started');
    const extra = v6(join(scratch, 'extra'), { objects: ['documents/a.pdf/v1'], files: [OBJECT, 'stub/stub/documents/orphan.pdf/v9'] });
    const warned = verify(extra, scratch);
    assert.equal(warned.status, 0, warned.stderr);
    assert.match(warned.stderr, /Warning: 1 archived storage file\(s\) have no catalog entry[\s\S]*orphan\.pdf/);
  } finally { rmSync(scratch, { recursive: true, force: true }); }
});

test('a v6 tree is checked against its manifest: an altered, extra, missing or linked file refuses the backup before any container', () => {
  const scratch = mkdtempSync(join(tmpdir(), 'warehouse-verify-tree-'));
  const refused = (backup, pattern, label) => {
    const result = verify(backup, scratch);
    assert.notEqual(result.status, 0, label);
    assert.match(result.stderr, pattern, label);
    assert.equal(result.calls, '', `${label}: no container is started`);
  };
  try {
    const altered = v6(join(scratch, 'altered'), { objects: ['documents/a.pdf/v1', 'documents/b.pdf/v1'] });
    writeFileSync(join(altered, 'storage', 'stub/stub/documents/b.pdf/v1'), 'planted bytes');
    refused(altered, /a file of the backup storage\/ tree does not match storage\.manifest/, 'altered');

    const extra = v6(join(scratch, 'extra'));
    writeFileSync(join(extra, 'storage/stub/stub/documents/planted.pdf'), 'x');
    refused(extra, /not exactly the files its signed storage\.manifest lists/, 'extra file');

    const gone = v6(join(scratch, 'gone'), { objects: ['documents/a.pdf/v1', 'documents/b.pdf/v1'] });
    rmSync(join(gone, 'storage/stub/stub/documents/b.pdf/v1'));
    refused(gone, /not exactly the files its signed storage\.manifest lists/, 'missing file');

    const linked = v6(join(scratch, 'linked'));
    symlinkSync('/etc/passwd', join(linked, 'storage/stub/stub/documents/link'));
    refused(linked, /the backup contains a link or special file/, 'symlink in the tree');

    const noTree = v6(join(scratch, 'notree'));
    rmSync(join(noTree, 'storage'), { recursive: true });
    refused(noTree, /missing the storage\/ directory|no storage\/ tree|not exactly the files/, 'tree removed');

    // The signed top-level list is not the place for tree paths: naming one there is a forged list.
    const forged = v6(join(scratch, 'forged'));
    const sums = readFileSync(join(forged, 'SHA256SUMS'), 'utf8') + spawnSync('sha256sum', [`storage/${OBJECT}`], { cwd: forged, encoding: 'utf8' }).stdout;
    writeFileSync(join(forged, 'SHA256SUMS'), sums);
    signBackup(forged);
    refused(forged, /not exactly the files its signed SHA256SUMS lists/, 'tree path in the signed list');

    // Edited and re-checksummed by someone without the key: the signature fails first.
    const edited = v6(join(scratch, 'edited'));
    writeFileSync(join(edited, 'storage.manifest'), '0'.repeat(64) + '  ' + OBJECT + '\n');
    spawnSync('sh', ['-c', 'sha256sum database.dump storage.manifest storage_objects.txt integrity.txt metadata.txt compose.env instance.json roles.txt > SHA256SUMS'], { cwd: edited });
    refused(edited, /signature of this backup does not match the backup key/, 'manifest edited');
  } finally { rmSync(scratch, { recursive: true, force: true }); }
});

test('a manifest that names a path outside the tree is refused even when the key is lost and the list is only checksummed', () => {
  const scratch = mkdtempSync(join(tmpdir(), 'warehouse-verify-manifest-paths-'));
  try {
    for (const [label, line] of [['parent', `${'0'.repeat(64)}  ../outside.txt`], ['absolute', `${'0'.repeat(64)}  /etc/passwd`], ['inner parent', `${'0'.repeat(64)}  stub/../../x`], ['not a checksum', 'hello']]) {
      const backup = v6(join(scratch, label.replace(' ', '-')), { key: null });
      writeFileSync(join(backup, 'storage.manifest'), readFileSync(join(backup, 'storage.manifest'), 'utf8') + line + '\n');
      spawnSync('sh', ['-c', 'sha256sum database.dump storage.manifest storage_objects.txt integrity.txt metadata.txt compose.env instance.json roles.txt > SHA256SUMS'], { cwd: backup });
      const result = verify(backup, scratch, { env: { WAREHOUSE_BACKUP_KEY_FILE: join(scratch, 'absent.key') }, args: ['--allow-unsigned'] });
      assert.notEqual(result.status, 0, label);
      assert.match(result.stderr, /storage\.manifest names a path outside the storage tree, or has a line that is not a checksum/, label);
      assert.equal(result.calls, '', label);
    }
  } finally { rmSync(scratch, { recursive: true, force: true }); }
});

test('--no-storage-tree verifies the chain (signature, list, manifest) and leaves the tree alone', () => {
  const scratch = mkdtempSync(join(tmpdir(), 'warehouse-verify-notree-'));
  try {
    const backup = v6(join(scratch, 'backup'), { objects: ['documents/a.pdf/v1', 'documents/b.pdf/v1'] });
    writeFileSync(join(backup, 'storage', 'stub/stub/documents/b.pdf/v1'), 'planted bytes');
    assert.notEqual(verify(backup, scratch).status, 0, 'the whole check sees the damaged file');
    const chain = verify(backup, scratch, { args: ['--no-storage-tree'] });
    assert.equal(chain.status, 0, chain.stderr);
    // The small files alone: the tree is not there at all (the USB check unpacks only these).
    rmSync(join(backup, 'storage'), { recursive: true });
    const small = verify(backup, scratch, { args: ['--no-storage-tree'] });
    assert.equal(small.status, 0, small.stderr);
    // The chain is still checked: a changed manifest or list fails.
    writeFileSync(join(backup, 'storage.manifest'), readFileSync(join(backup, 'storage.manifest'), 'utf8') + `${'0'.repeat(64)}  other\n`);
    const forged = verify(backup, scratch, { args: ['--no-storage-tree'] });
    assert.notEqual(forged.status, 0);
    assert.match(forged.stderr, /does not match the backup key|does not match its SHA256SUMS/);
    // For v5 the flag changes nothing: the archive is listed as always.
    assert.equal(verify(makeBackup(join(scratch, 'five')), scratch, { args: ['--no-storage-tree'] }).status, 0);
  } finally { rmSync(scratch, { recursive: true, force: true }); }
});

test('the label must agree with the signed list: v6 is a manifest and a tree, v5 a tarball, and a mismatch is refused after authentication', () => {
  const scratch = mkdtempSync(join(tmpdir(), 'warehouse-verify-mismatch-'));
  try {
    const labelledSix = makeBackup(join(scratch, 'five-as-six'));
    relabel(labelledSix, 'warehouse-backup-v6');
    let result = verify(labelledSix, scratch);
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /Incomplete backup: missing storage\.manifest/, 'caught before the signature check by the file it needs');

    const labelledFive = v6(join(scratch, 'six-as-five'));
    relabel(labelledFive, 'warehouse-backup-v5');
    result = verify(labelledFive, scratch);
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /Incomplete backup: missing storage\.tar\.gz/);
    assert.equal(result.calls, '');

    // Both files present, so only the signed list can tell: a v5 label whose list names the manifest and has the tree.
    const mixed = v6(join(scratch, 'mixed-five'));
    writeFileSync(join(mixed, 'storage.tar.gz'), 'not used');
    writeFileSync(join(mixed, 'metadata.txt'), readFileSync(join(mixed, 'metadata.txt'), 'utf8').replace('warehouse-backup-v6', 'warehouse-backup-v5'));
    spawnSync('sh', ['-c', 'sha256sum database.dump storage.tar.gz storage.manifest storage_objects.txt integrity.txt metadata.txt compose.env instance.json roles.txt > SHA256SUMS'], { cwd: mixed });
    signBackup(mixed);
    result = verify(mixed, scratch);
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /labelled warehouse-backup-v5, but its signed file list does not describe that layout|not exactly the files/);
    assert.equal(result.calls, '');

    const mixedSix = v6(join(scratch, 'mixed-six'));
    writeFileSync(join(mixedSix, 'storage.tar.gz'), 'not used');
    spawnSync('sh', ['-c', 'sha256sum database.dump storage.tar.gz storage.manifest storage_objects.txt integrity.txt metadata.txt compose.env instance.json roles.txt > SHA256SUMS'], { cwd: mixedSix });
    signBackup(mixedSix);
    result = verify(mixedSix, scratch);
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /labelled warehouse-backup-v6, but its signed file list does not describe that layout/);
    assert.equal(result.calls, '');

    // A label that is neither: the message names both accepted formats.
    const other = makeBackup(join(scratch, 'other'));
    writeFileSync(join(other, 'metadata.txt'), readFileSync(join(other, 'metadata.txt'), 'utf8').replace('warehouse-backup-v5', 'warehouse-backup-v7'));
    result = verify(other, scratch);
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /Refusing: backup format 'warehouse-backup-v7' is no longer supported; take a new backup with this version \(only warehouse-backup-v5 and -v6 are accepted\)\./);
    assert.equal(result.calls, '');
  } finally { rmSync(scratch, { recursive: true, force: true }); }
});

// restore.sh from a private copy of the scripts, against the fake docker.
function restoreRun(scratch, args, env = {}, prepare = () => {}) {
  const log = join(scratch, 'restore-docker.log');
  writeFileSync(log, '');
  const root = scriptRoot(scratch);
  writeFileSync(join(root, 'scripts/migrate.sh'), '#!/usr/bin/env bash\nexit 0\n');
  writeFileSync(join(root, 'scripts/doctor.mjs'), "console.log('Local operator services and gateway are healthy.');\n");
  prepare(root);
  const result = spawnSync('bash', [join(root, 'scripts/restore.sh'), ...args], { encoding: 'utf8', env: {
    ...process.env, PATH: `${fakeDocker(join(scratch, 'bin'))}:${process.env.PATH}`, WAREHOUSE_STATE_DIR: join(scratch, 'state'), FAKE_DOCKER_LOG: log, ...env } });
  return { ...result, calls: readFileSync(log, 'utf8') };
}
function restoreFixture(prefix, options = {}) {
  const scratch = mkdtempSync(join(tmpdir(), prefix));
  const state = makeState(scratch);
  const backup = (options.format === 'warehouse-backup-v5' ? makeBackup : v6)(join(scratch, 'backup'), { env: composeEnv(state), ...options.backup });
  return { scratch, state, backup, env: { FAKE_CATALOG_FILE: join(backup, 'storage_objects.txt') } };
}

test('a v6 backup restores by copying the tree: files, modes and times arrive, and the live storage shares nothing with the backup', () => {
  const f = restoreFixture('warehouse-restore-v6-', { backup: { objects: ['documents/a.pdf/v1', 'documents/b.pdf/v1'] } });
  try {
    const stored = join(f.backup, 'storage', 'stub/stub/documents/b.pdf/v1');
    const when = new Date('2026-03-04T05:06:07Z');
    utimesSync(stored, when, when);
    chmodSync(stored, 0o640);
    // The manifest and signature are of the bytes, not of times or modes, so the backup stays valid.
    const result = restoreRun(f.scratch, ['--yes', f.backup], { ...f.env, FAKE_PROBE_RC: '0' });
    assert.equal(result.status, 0, result.stderr);
    const restored = join(f.state, 'data/storage/stub/stub/documents/b.pdf/v1');
    assert.equal(readFileSync(restored, 'utf8'), 'bytes of stub/stub/documents/b.pdf/v1');
    assert.equal(statSync(restored).mtimeMs, when.getTime(), 'the modification time is kept');
    assert.equal(statSync(restored).mode & 0o777, 0o640, 'the mode is kept');
    assert.equal(statSync(restored).nlink, 1, 'a copy, not a link into the backup');
    assert.notEqual(inode(restored), inode(stored));
    assert.equal(statSync(stored).nlink, 1);
    assert.equal(readFileSync(join(f.state, 'data/storage.pre-restore-' + readdirSync(join(f.state, 'data')).find(name => name.startsWith('storage.pre-restore-')).slice(20), 'current-object'), 'utf8'), 'current object data', 'the replaced storage is kept');
    assert.match(result.stdout, /format warehouse-backup-v6/);
    assert.match(result.calls, /^RETAG-CALL probe$/m, 'a sample of the restored files is looked at');
    assert.doesNotMatch(result.calls, /^RETAG-CALL all$/m, 'and none lacks a content type, so nothing is set again');
    assert.match(result.stdout, /The stored files carry their content types; nothing to set\./);
    assert.doesNotMatch(result.stderr, /storage metadata/i);
  } finally { rmSync(f.scratch, { recursive: true, force: true }); }
});

test('a v6 restore verifies first, copies the tree before it starts the new cluster, keeps the replaced data and says how to roll back when the start fails', () => {
  const f = restoreFixture('warehouse-restore-v6-flow-', { backup: { objects: ['documents/a.pdf/v1', 'documents/b.pdf/v1'] } });
  try {
    const result = restoreRun(f.scratch, ['--yes', f.backup], { ...f.env, FAKE_FAIL_START: 'yes' });
    assert.notEqual(result.status, 0, 'the injected start failure propagates');
    assert.match(result.stderr, /Restore failed during: start services/);
    assert.match(result.stderr, /Rollback: bash stop\.sh/);
    const kept = readdirSync(join(f.state, 'data')).sort();
    const keptStorage = kept.find(name => /^storage\.pre-restore-\d{8}T\d{6}Z$/.test(name));
    assert.ok(kept.some(name => /^db\.pre-restore-/.test(name)) && keptStorage, `the replaced data is kept: ${kept}`);
    assert.equal(readFileSync(join(f.state, 'data', keptStorage, 'current-object'), 'utf8'), 'current object data');
    for (const object of ['documents/a.pdf/v1', 'documents/b.pdf/v1']) assert.equal(readFileSync(join(f.state, 'data/storage/stub/stub', object), 'utf8'), `bytes of stub/stub/${object}`);
    const lines = result.calls.split('\n');
    const index = needle => { const at = lines.findIndex(line => line.includes(needle)); assert.ok(at >= 0, needle); return at; };
    assert.ok(index('run -d --pull missing') < index('up -d --wait --wait-timeout 180 db'), 'the disposable verification comes first');
    assert.doesNotMatch(result.calls, /RETAG-CALL/, 'nothing is looked at or set while the services failed to start');
  } finally { rmSync(f.scratch, { recursive: true, force: true }); }
});

test('attributes survive backup.sh and restore.sh: a restored photo is served with its content type', { skip: xattrSkip() }, () => {
  const f = installation('warehouse-roundtrip-');
  try {
    const tool = xattrTool();
    const when = new Date('2026-03-04T05:06:07Z');
    f.put(OBJECT, '%PDF-fictional', when);
    tool.set(join(f.live, OBJECT), 'user.supabase.content-type', 'application/pdf');
    tool.set(join(f.live, OBJECT), 'user.supabase.cache-control', 'max-age=3600');
    const made = ok(f.backup('warehouse-20260101T000001Z'));
    // Lose the photo's attributes in the live storage, then restore the backup over it (the PostgreSQL major-upgrade path).
    rmSync(join(f.live, 'stub'), { recursive: true });
    f.put(OBJECT, 'wrong bytes');
    const result = restoreRun(f.scratch, ['--yes', made.dest], { FAKE_CATALOG_FILE: join(made.dest, 'storage_objects.txt') });
    assert.equal(result.status, 0, result.stderr);
    const restored = join(f.live, OBJECT);
    assert.equal(readFileSync(restored, 'utf8'), '%PDF-fictional');
    assert.equal(tool.get(restored, 'user.supabase.content-type'), 'application/pdf');
    assert.equal(tool.get(restored, 'user.supabase.cache-control'), 'max-age=3600');
    assert.equal(statSync(restored).mtimeMs, when.getTime());
  } finally { f.done(); }
});

test('a restore needs room for the stored files again and checks before it moves anything', () => {
  const f = restoreFixture('warehouse-restore-space-', { backup: { storageBytes: 500_000_000_000_000 } });
  try {
    const refused = restoreRun(f.scratch, ['--yes', f.backup], f.env);
    assert.notEqual(refused.status, 0);
    assert.match(refused.stderr, /Refusing: restoring the stored files needs about 476837158 MiB plus 1 GiB of free space in .*\/data, but only \d+ MiB are free\. .* Nothing was moved\./);
    assert.deepEqual(readdirSync(join(f.state, 'data')).sort(), ['db', 'storage'], 'no data directory was moved');
    assert.equal(readFileSync(join(f.state, 'data/db/PG_VERSION'), 'utf8'), '15\n');
    assert.doesNotMatch(refused.calls, /up -d --wait --wait-timeout 180 db/, 'no cluster was started');
  } finally { rmSync(f.scratch, { recursive: true, force: true }); }
  const noSize = restoreFixture('warehouse-restore-nosize-');
  try {
    const metadata = join(noSize.backup, 'metadata.txt');
    writeFileSync(metadata, readFileSync(metadata, 'utf8').replace(/^storage_bytes=.*\n/m, ''));
    spawnSync('sh', ['-c', 'sha256sum database.dump storage.manifest storage_objects.txt integrity.txt metadata.txt compose.env instance.json roles.txt > SHA256SUMS'], { cwd: noSize.backup });
    signBackup(noSize.backup);
    const result = restoreRun(noSize.scratch, ['--yes', noSize.backup], noSize.env);
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /records no usable size for its stored files \(storage_bytes= in metadata\.txt\)\. Nothing was moved\./);
    assert.deepEqual(readdirSync(join(noSize.state, 'data')).sort(), ['db', 'storage']);
  } finally { rmSync(noSize.scratch, { recursive: true, force: true }); }
});

test('a v5 backup still restores with tar, and the attributes are set again from the catalog once the services run', () => {
  const f = restoreFixture('warehouse-restore-v5-retag-', { format: 'warehouse-backup-v5' });
  try {
    const catalog = join(f.scratch, 'retag-catalog.jsonl');
    writeFileSync(catalog, JSON.stringify({ path: 'documents/a.pdf/v1', mimetype: 'application/pdf', cacheControl: 'max-age=3600' }) + '\n');
    const sent = join(f.scratch, 'retag-stdin.txt');
    const result = restoreRun(f.scratch, ['--yes', f.backup], { ...f.env, FAKE_RETAG_CATALOG: catalog, FAKE_RETAG_STDIN: sent });
    assert.equal(result.status, 0, result.stderr);
    assert.deepEqual(result.calls.split('\n').filter(line => line.startsWith('RETAG-CALL')), ['RETAG-CALL probe', 'RETAG-CALL all'], 'a v5 tarball has no attributes: the sample says so, then every file is set');
    assert.equal(readFileSync(join(f.state, 'data/storage', OBJECT), 'utf8'), `bytes of ${OBJECT}`);
    const lines = result.calls.split('\n');
    const started = lines.findIndex(line => line.endsWith('up -d --wait --wait-timeout 180'));
    const query = lines.findIndex(line => line.includes('jsonb_build_object') && line.includes('storage.objects'));
    const retag = lines.findIndex(line => line.includes('exec -T storage node -e'));
    assert.ok(started >= 0 && query > started && retag >= 0, `the catalog is read and the storage container is called after the services start (${started} ${query} ${retag})`);
    assert.equal(readFileSync(sent, 'utf8'), readFileSync(catalog, 'utf8'), 'the catalog lines reach the script in the storage container');
    assert.match(result.stdout, /format warehouse-backup-v5/);
    // A failing re-tag is a warning: the files are intact.
    const second = restoreFixture('warehouse-restore-v5-retag-fail-', { format: 'warehouse-backup-v5' });
    try {
      const failing = restoreRun(second.scratch, ['--yes', second.backup], second.env, root => writeFileSync(join(root, 'scripts/storage-retag.sh'), '#!/usr/bin/env bash\nexit 3\n'));
      assert.equal(failing.status, 0, 'the restore itself succeeded');
      assert.match(failing.stderr, /Warning: the storage metadata \(content type, cache control\) could not be checked or set again\. The files are intact\. Run: npm run storage:retag/);
      assert.doesNotMatch(failing.stderr, /Restore failed/);
    } finally { rmSync(second.scratch, { recursive: true, force: true }); }
  } finally { rmSync(f.scratch, { recursive: true, force: true }); }
});

test('a v6 restore sets the content types again from the catalog when the restored files lack them (a USB copy from before archives kept them), and says so', () => {
  const f = restoreFixture('warehouse-restore-v6-retag-', { backup: { objects: ['documents/a.pdf/v1', 'documents/b.pdf/v1'] } });
  try {
    const catalog = join(f.scratch, 'retag-catalog.jsonl');
    writeFileSync(catalog, ['documents/a.pdf/v1', 'documents/b.pdf/v1'].map(path => JSON.stringify({ path, mimetype: 'application/pdf', cacheControl: 'max-age=3600' })).join('\n') + '\n');
    const probed = join(f.scratch, 'probe-stdin.txt'), sent = join(f.scratch, 'retag-stdin.txt');
    // The probe finds a restored file without a content type (the fake storage container answers 10).
    const result = restoreRun(f.scratch, ['--yes', f.backup], { ...f.env, FAKE_PROBE_RC: '10', FAKE_RETAG_CATALOG: catalog, FAKE_PROBE_STDIN: probed, FAKE_RETAG_STDIN: sent });
    assert.equal(result.status, 0, result.stderr);
    assert.deepEqual(result.calls.split('\n').filter(line => line.startsWith('RETAG-CALL')), ['RETAG-CALL probe', 'RETAG-CALL all']);
    assert.equal(readFileSync(probed, 'utf8'), readFileSync(catalog, 'utf8'), 'the sample is taken from the catalog');
    assert.equal(readFileSync(sent, 'utf8'), readFileSync(catalog, 'utf8'), 'and every catalogued file is then set');
    assert.match(result.stdout, /Some stored files have no content type .*: setting them for every file\./);
    const lines = result.calls.split('\n');
    assert.ok(lines.findIndex(line => line.endsWith('up -d --wait --wait-timeout 180')) < lines.indexOf('RETAG-CALL probe'), 'after the services are up');
    assert.match(result.stdout, /In-place restore completed from/);
    // The probe or the setting fails: the restore is still complete, with a warning.
    const second = restoreFixture('warehouse-restore-v6-retag-fail-', { backup: { objects: ['documents/a.pdf/v1'] } });
    try {
      const failed = restoreRun(second.scratch, ['--yes', second.backup], { ...second.env, FAKE_PROBE_RC: '3' });
      assert.equal(failed.status, 0, failed.stderr);
      assert.match(failed.stderr, /Warning: the storage metadata \(content type, cache control\) could not be checked or set again\. The files are intact\. Run: npm run storage:retag/);
      assert.match(failed.stdout, /In-place restore completed from/);
      assert.doesNotMatch(failed.calls, /RETAG-CALL all/, 'a failed look does not set anything blindly');
    } finally { rmSync(second.scratch, { recursive: true, force: true }); }
  } finally { rmSync(f.scratch, { recursive: true, force: true }); }
});

test('a restore whose copy lost the attributes is refused by the dry run', { skip: xattrSkip() }, () => {
  const f = restoreFixture('warehouse-restore-nodrop-', { backup: { xattrs: { [OBJECT]: { 'user.supabase.content-type': 'application/pdf' } } } });
  try {
    const shim = join(f.scratch, 'shim'); mkdirSync(shim);
    const real = spawnSync('which', ['rsync'], { encoding: 'utf8' }).stdout.trim();
    writeFileSync(join(shim, 'rsync'), `#!/bin/sh
case " $* " in *' -rptXn '*) exec ${real} "$@" ;; esac
args=""
for a in "$@"; do case "$a" in -rptX) a=-rpt ;; esac; args="$args '$a'"; done
eval exec ${real} $args
`, { mode: 0o755 });
    const result = restoreRun(f.scratch, ['--yes', f.backup], { ...f.env, PATH: `${shim}:${join(f.scratch, 'bin')}:${process.env.PATH}` });
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /The restored stored files differ from the backup after the copy/);
    assert.match(result.stderr, /Restore failed during: extract storage/);
  } finally { rmSync(f.scratch, { recursive: true, force: true }); }
});
