// What scripts/backup-usb.sh does with the drive's contents: the restore check that unpacks no photo, the free-space guard,
// keeping the newest archives, never touching foreign ones, making room, and deleting readable archives only after an encrypted
// one has been written and verified. Fake drives only (tests/usb-test-helpers.mjs): nothing here touches a USB device.
import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdirSync, writeFileSync, readFileSync, existsSync, readdirSync, statSync, copyFileSync, rmSync, renameSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { join } from 'node:path';
import { composeEnv, makeBackup, backupKey, hmacHex, signBackup } from './backup-test-helpers.mjs';
import { fixture } from './usb-test-helpers.mjs';
import { usbBackupWarning } from '../scripts/usb-backup-status.mjs';

const PLAIN = { WAREHOUSE_BACKUP_ENCRYPT: '0' };
const NOVERIFY = { WAREHOUSE_USB_BACKUP_VERIFY_RESTORE: 'no' };
const RUN = ['run', '--device', 'sdb1'];
// Writes the archive of backup `day` to the drive by running the script (nothing is deleted while seeding: keep 99).
const seed = (f, day, extra = {}) => {
  if (!existsSync(join(f.state, 'backups', f.bname(day)))) f.localBackup(f.bname(day));
  const result = f.run(RUN, { ...f.verifyEnv(), ...NOVERIFY, WAREHOUSE_USB_KEEP: '99', ...extra });
  assert.equal(result.status, 0, result.stderr + result.stdout);
};
const sizeOf = path => statSync(path).size;
// The room the script wants for a backup folder: its bytes, 2 KiB of tar header per file and 64 MiB.
const need = dir => {
  const bytes = Number(spawnSync('du', ['-sb', dir], { encoding: 'utf8' }).stdout.split('\t')[0]);
  const files = spawnSync('find', [dir, '-type', 'f'], { encoding: 'utf8' }).stdout.split('\n').filter(Boolean).length;
  return bytes + files * 2048 + 67108864;
};

test('the restore check of the drive unpacks the small files only, never the photos, and runs verify-restore.sh --no-storage-tree', () => {
  const f = fixture('warehouse-usb-smallfiles-');
  try {
    f.enroll();
    const [newest] = f.backups(1);
    // A stand-in for verify-restore.sh records its arguments and what the unpacked folder holds.
    const seen = join(f.scratch, 'verify-seen.txt');
    writeFileSync(join(f.root, 'scripts/verify-restore.sh'), `#!/usr/bin/env bash\n{ echo "ARGS $*"; for a; do if [ -d "$a" ]; then (cd "$a" && find . | sort); fi; done; } >> "${seen}"\n`, { mode: 0o755 });
    const result = f.run(RUN, f.verifyEnv());
    assert.equal(result.status, 0, result.stderr + result.stdout);
    assert.deepEqual(f.archives(), [`${newest}.tar.enc`]);
    const log = readFileSync(seen, 'utf8');
    assert.match(log, new RegExp(`^ARGS --no-storage-tree ${f.state}/\\.usb-verify\\.[A-Za-z0-9]+/${newest}$`, 'm'));
    for (const small of ['./SHA256SUMS', './SHA256SUMS.hmac', './database.dump', './metadata.txt', './storage.manifest', './storage_objects.txt', './compose.env']) assert.ok(log.split('\n').includes(small), `${small} is unpacked`);
    assert.doesNotMatch(log, /storage\/|\.\/storage$/m, 'no storage/ tree, not even its folder, was written to the data disk');
    assert.equal(readdirSync(f.state).filter(n => n.startsWith('.usb-verify')).length, 0, 'removed afterwards');
    assert.match(result.stdout, new RegExp(`Restore verification of the copy on the drive passed: ${newest}`));
  } finally { f.cleanup(); }
});

test('the restore check needs room for the small files in the state directory, and says so instead of filling the disk the application runs on', () => {
  const f = fixture('warehouse-usb-dfguard-');
  try {
    f.enroll();
    const [newest] = f.backups(1);
    const marker = join(f.scratch, 'verify-ran');
    writeFileSync(join(f.root, 'scripts/verify-restore.sh'), `#!/usr/bin/env bash\necho ran >> "${marker}"\n`, { mode: 0o755 });
    // 1 MiB free in the state directory: not enough for the small files plus the 256 MiB the check keeps in reserve.
    let result = f.run(RUN, f.dfEnv({ ...f.verifyEnv(), FAKE_STATE_AVAIL: String(1024 * 1024) }));
    assert.equal(result.status, 1);
    assert.match(result.stderr, new RegExp(`not enough free space in ${f.state} to check ${newest} from the drive: its small files need .* plus 256 MiB, and 1(\\.0)?MiB are free`));
    assert.equal(existsSync(marker), false, 'verify-restore.sh did not run');
    assert.equal(readdirSync(f.state).filter(n => n.startsWith('.usb-verify')).length, 0, 'nothing was unpacked');
    assert.deepEqual(f.archives(), [`${newest}.tar.enc`], 'the archive itself was written and is kept');
    assert.match(f.last(), /^result=failed$/m);
    // With room, the same archive is checked.
    result = f.run(RUN, f.dfEnv({ ...f.verifyEnv(), FAKE_STATE_AVAIL: String(10 * 1024 ** 3) }));
    assert.equal(result.status, 0, result.stderr + result.stdout);
    assert.equal(readFileSync(marker, 'utf8'), 'ran\n');
  } finally { f.cleanup(); }
});

test('a v5 backup is still copied and checked: its storage.tar.gz is the last member and counts as a small file', () => {
  const f = fixture('warehouse-usb-v5-');
  try {
    f.enroll();
    const [newest] = f.backups(1, { format: 'warehouse-backup-v5' });
    const result = f.run(RUN, f.verifyEnv());
    assert.equal(result.status, 0, result.stderr + result.stdout);
    const archive = join(f.dest, `${newest}.tar.enc`);
    const names = spawnSync('bash', ['-c', 'set -euo pipefail; source "$1"; backup_key_load "$2"; backup_decrypt "$BACKUP_KEY" < "$3" | tar -tf -', 'sh', join(f.root, 'scripts/backup-key.sh'), join(f.state, 'config/backup.key'), archive], { encoding: 'utf8' }).stdout.split('\n').filter(Boolean);
    assert.equal(names.at(-1), `${newest}/storage.tar.gz`);
    assert.equal(names[0], `${newest}/`);
    assert.match(result.stdout, new RegExp(`Restore verification of the copy on the drive passed: ${newest}`));
  } finally { f.cleanup(); }
});

test('the drive keeps the newest 3 valid archives: older ones go with their checksum and signature files, after a run without a failure', () => {
  const f = fixture('warehouse-usb-keep3-');
  try {
    f.enroll();
    for (const day of [1, 2, 3, 4, 5]) seed(f, day);
    assert.equal(f.archives().length, 5, 'seeding deletes nothing');
    f.localBackup(f.bname(6));
    const result = f.run(RUN, f.verifyEnv());
    assert.equal(result.status, 0, result.stderr + result.stdout);
    assert.deepEqual(f.archives(), [4, 5, 6].map(day => `${f.bname(day)}.tar.enc`));
    for (const day of [1, 2, 3]) assert.deepEqual(readdirSync(f.dest).filter(n => n.includes(f.bname(day))), [], `nothing of ${f.bname(day)} is left, sidecars included`);
    for (const day of [4, 5, 6]) assert.deepEqual(readdirSync(f.dest).filter(n => n.includes(f.bname(day))).sort(), [`${f.bname(day)}.tar.enc`, `${f.bname(day)}.tar.enc.hmac`, `${f.bname(day)}.tar.enc.sha256`]);
    assert.match(result.stdout, /Deleting the archive warehouse-20260101T000000Z\.tar\.enc: the drive keeps the newest 3 valid archives/);
    assert.match(result.stdout, /copied=1 already-present=0 failed=0 pruned=3/);
    assert.match(f.last(), /^message=copied 1, already present 0, pruned 3, /m);
    // The count is the operator's: --keep N / WAREHOUSE_USB_KEEP.
    const two = f.run(RUN, { ...f.verifyEnv(), WAREHOUSE_USB_KEEP: '2' });
    assert.equal(two.status, 0, two.stderr);
    assert.deepEqual(f.archives(), [5, 6].map(day => `${f.bname(day)}.tar.enc`));
    const bad = f.run(RUN, { ...f.verifyEnv(), WAREHOUSE_USB_KEEP: '0' });
    assert.equal(bad.status, 1);
    assert.match(bad.stderr, /WAREHOUSE_USB_KEEP must be a whole number from 1 to 99/);
    assert.equal(f.archives().length, 2);
  } finally { f.cleanup(); }
});

test('setup --keep N sets how many archives a drive keeps, rejects nonsense, and a rerun keeps it', () => {
  const f = fixture('warehouse-usb-keepopt-');
  const conf = () => readFileSync(join(f.etc, 'warehouse-usb-backup.conf'), 'utf8');
  const unit = () => readFileSync(join(f.etc, 'systemd/system/warehouse-usb-backup@.service'), 'utf8');
  try {
    for (const bad of ['0', 'x', '100', '-1', '']) {
      const refused = f.asRoot(['setup', '--state', f.state, '--keep', bad]);
      assert.equal(refused.status, 1, `--keep '${bad}'`);
      assert.match(refused.stderr, /--keep needs a whole number from 1 to 99/);
    }
    assert.equal(existsSync(join(f.etc, 'warehouse-usb-backup.conf')), false);
    const set = f.asRoot(['setup', '--state', f.state, '--keep', '2']);
    assert.equal(set.status, 0, set.stderr);
    assert.match(conf(), /^KEEP=2$/m);
    assert.match(unit(), /^Environment=WAREHOUSE_USB_KEEP=2$/m);
    assert.match(set.stdout, /Each drive keeps the newest 2 valid archives/);
    assert.equal(f.asRoot(['setup', '--state', f.state]).status, 0);
    assert.match(conf(), /^KEEP=2$/m, 'kept by a rerun');
  } finally { f.cleanup(); }
});

test('archives that are foreign, unsigned or damaged are reported and never counted or deleted', () => {
  const f = fixture('warehouse-usb-foreign-');
  try {
    f.enroll();
    for (const day of [1, 2, 3, 4]) seed(f, day);
    const own = [1, 2, 3, 4].map(day => `${f.bname(day)}.tar.enc`);
    const plant = (name, { hmac = 'other-key', hashOf = null } = {}) => {
      const path = join(f.dest, name);
      copyFileSync(join(f.dest, own[3]), path);
      const hash = hashOf ?? spawnSync('sha256sum', [path], { encoding: 'utf8' }).stdout.split(' ')[0];
      writeFileSync(`${path}.sha256`, `${hash}  ${name}\n`);
      if (hmac === 'other-key') writeFileSync(`${path}.hmac`, `warehouse-backup-hmac-v1 ${hmacHex('d4'.repeat(32), 'warehouse-backup-archive-v1', readFileSync(`${path}.sha256`))}\n`);
      else if (hmac === 'own-key') writeFileSync(`${path}.hmac`, `warehouse-backup-hmac-v1 ${hmacHex(backupKey, 'warehouse-backup-archive-v1', readFileSync(`${path}.sha256`))}\n`);
      return name;
    };
    const foreign = [
      plant('warehouse-20250101T000000Z.tar.enc'),                                        // signed with another key
      plant('warehouse-20250102T000000Z.tar.enc', { hmac: 'own-key', hashOf: '0'.repeat(64) }),   // signed, but the bytes do not match
      plant('warehouse-20250103T000000Z.tar', { hmac: 'none' }),                          // an archive from before signing
    ];
    writeFileSync(join(f.dest, 'notes.txt'), 'the operator\'s own file');
    f.localBackup(f.bname(5));
    const result = f.run(RUN, f.verifyEnv());
    assert.equal(result.status, 0, result.stderr + result.stdout);
    for (const name of foreign) assert.ok(existsSync(join(f.dest, name)), `${name} is still there`);
    assert.ok(existsSync(join(f.dest, `${foreign[0]}.hmac`)) && existsSync(join(f.dest, `${foreign[0]}.sha256`)), 'and so are its checksum and signature');
    assert.equal(readFileSync(join(f.dest, 'notes.txt'), 'utf8'), 'the operator\'s own file');
    // Only this installation's valid archives were counted: 5 of them, 3 kept.
    assert.deepEqual(f.archives().filter(name => !foreign.includes(name)), [3, 4, 5].map(day => `${f.bname(day)}.tar.enc`));
    const line = result.stdout.split('\n').find(l => l.startsWith('Not counted and not deleted'));
    assert.ok(line, result.stdout);
    for (const name of foreign) assert.ok(line.includes(name), `${name} is named`);
    assert.match(result.stdout, /pruned=2/);
  } finally { f.cleanup(); }
});

test('a run that fails never deletes anything, and the next one that does not fail prunes', () => {
  const f = fixture('warehouse-usb-failprune-');
  try {
    f.enroll();
    for (const day of [1, 2, 3, 4]) seed(f, day);
    // Some failure unrelated to the copy: the fresh backup cannot be made. The newest verified backup is old (January), so one is due.
    writeFileSync(join(f.root, 'scripts/backup.sh'), '#!/usr/bin/env bash\necho nope >&2\nexit 1\n', { mode: 0o755 });
    const failing = f.run(RUN, { ...f.verifyEnv(), WAREHOUSE_USB_BACKUP_FRESH: 'yes' });
    assert.equal(failing.status, 1);
    assert.match(failing.stderr, /fresh backup failed/);
    assert.equal(f.archives().length, 4, 'four archives: nothing was pruned by a failed run');
    assert.doesNotMatch(failing.stdout, /Deleting the archive/);
    assert.match(failing.stdout, /failed=1 pruned=0/);
    const ok = f.run(RUN, f.verifyEnv());
    assert.equal(ok.status, 0, ok.stderr + ok.stdout);
    assert.deepEqual(f.archives(), [2, 3, 4].map(day => `${f.bname(day)}.tar.enc`));
  } finally { f.cleanup(); }
});

test('a damaged archive of the backup being copied is a failure, and a run that fails keeps every archive', () => {
  const f = fixture('warehouse-usb-damaged-');
  try {
    f.enroll();
    for (const day of [1, 2, 3, 4]) seed(f, day);
    writeFileSync(join(f.dest, `${f.bname(4)}.tar.enc`), 'bit rot');
    const result = f.run(RUN, f.verifyEnv());
    assert.equal(result.status, 1);
    assert.match(result.stderr, /does not match its checksum or signature; it was not overwritten/);
    // The restore check hashes the archive before it lists or opens it.
    assert.match(result.stderr, new RegExp(`restore verification of ${f.bname(4)} from the drive failed: the archive ${f.bname(4)}\\.tar\\.enc does not match its checksum or its signature \\(it is damaged\\); it was not opened`));
    assert.doesNotMatch(result.stderr, /could not be listed/);
    assert.equal(f.archives().length, 4);
    assert.equal(readFileSync(join(f.dest, `${f.bname(4)}.tar.enc`), 'utf8'), 'bit rot');
  } finally { f.cleanup(); }
});

test('when the new archive will not fit, the oldest valid archives go one at a time while more than one remains', () => {
  const f = fixture('warehouse-usb-room-');
  try {
    f.enroll();
    for (const day of [1, 2, 3]) seed(f, day);
    f.localBackup(f.bname(4));
    const per = [`${f.bname(1)}.tar.enc`, `${f.bname(1)}.tar.enc.sha256`, `${f.bname(1)}.tar.enc.hmac`].reduce((sum, name) => sum + sizeOf(join(f.dest, name)), 0);
    const used = Number(spawnSync('du', ['-sb', f.drive], { encoding: 'utf8' }).stdout.split('\t')[0]);
    const wanted = need(join(f.state, 'backups', f.bname(4)));
    // Room for the new archive appears only when one old archive has gone: free = cap - used; free before < wanted <= free after.
    const cap = wanted + used - Math.round(per / 2);
    const result = f.run(RUN, f.dfEnv({ ...f.verifyEnv(), WAREHOUSE_USB_KEEP: '99', FAKE_DRIVE_CAP: String(cap) }));
    assert.equal(result.status, 0, result.stderr + result.stdout);
    assert.deepEqual(f.archives(), [2, 3, 4].map(day => `${f.bname(day)}.tar.enc`), 'one archive was deleted to make room, and no more');
    assert.match(result.stdout, new RegExp(`Making room for the new archive: deleting the oldest valid archive on the drive, ${f.bname(1)}\\.tar\\.enc`));
    assert.doesNotMatch(result.stdout, new RegExp(`deleting the oldest valid archive on the drive, ${f.bname(2)}`));
  } finally { f.cleanup(); }
});

test('when no deletion can make room the run fails with "drive too small", deletes nothing, and the newest valid archive is still there', () => {
  const f = fixture('warehouse-usb-toosmall-');
  try {
    f.enroll();
    for (const day of [1, 2, 3]) seed(f, day);
    f.localBackup(f.bname(4));
    const wanted = need(join(f.state, 'backups', f.bname(4)));
    const before = readdirSync(f.dest).sort();
    // Even every older archive deleted would leave less than the new archive needs: the cap is below what one archive wants.
    const result = f.run(RUN, f.dfEnv({ ...f.verifyEnv(), WAREHOUSE_USB_KEEP: '99', FAKE_DRIVE_CAP: String(wanted - 1) }));
    assert.equal(result.status, 1);
    assert.match(result.stderr, /FAILED: drive too small: needs \S+, has \S+; the drive must hold the new archive next to the newest valid one it already has/);
    assert.match(result.stderr, /No archive was deleted: deleting the 2 older one\(s\) would still not make room/);
    assert.doesNotMatch(result.stdout, /Making room for the new archive/);
    assert.deepEqual(f.archives(), [1, 2, 3].map(day => `${f.bname(day)}.tar.enc`), 'every archive is still on the drive: deleting could not have helped');
    assert.deepEqual(readdirSync(f.dest).sort(), before, 'and so is everything else');
    assert.match(f.last(), /^result=failed$/m);
    assert.match(f.last(), /drive too small: needs/);
  } finally { f.cleanup(); }
});

test('a free-space reading that fails is not zero: the run is refused with a clear message, nothing is deleted and nothing is written', () => {
  const f = fixture('warehouse-usb-dfbroken-');
  try {
    f.enroll();
    for (const day of [1, 2, 3]) seed(f, day);
    f.localBackup(f.bname(4));
    const before = readdirSync(f.dest).sort();
    const result = f.run(RUN, f.dfEnv({ ...f.verifyEnv(), WAREHOUSE_USB_KEEP: '99', FAKE_DF_BROKEN: 'drive' }));
    assert.equal(result.status, 1);
    assert.match(result.stderr, /FAILED: could not read the free space of the drive .*so it cannot be checked that the new archive fits; nothing was written and nothing was deleted/);
    assert.doesNotMatch(result.stderr + result.stdout, /drive too small|has 0 ?B|Making room|Deleting/);
    assert.deepEqual(readdirSync(f.dest).sort(), before, 'the drive folder is exactly as it was');
    assert.match(f.last(), /^result=failed$/m);
    assert.match(f.last(), /could not read the free space of the drive/);
  } finally { f.cleanup(); }
});

test('a free-space reading of the state directory that fails stops the restore check with a message instead of passing it or reporting zero', () => {
  const f = fixture('warehouse-usb-dfbroken-state-');
  try {
    f.enroll();
    const [newest] = f.backups(1);
    const marker = join(f.scratch, 'verify-ran');
    writeFileSync(join(f.root, 'scripts/verify-restore.sh'), `#!/usr/bin/env bash\necho ran >> "${marker}"\n`, { mode: 0o755 });
    const result = f.run(RUN, f.dfEnv({ ...f.verifyEnv(), FAKE_DF_BROKEN: 'state' }));
    assert.equal(result.status, 1);
    assert.match(result.stderr, new RegExp(`could not read the free space of ${f.state}, so the restore check of ${newest} from the drive was not run`));
    assert.doesNotMatch(result.stderr, /not enough free space/);
    assert.equal(existsSync(marker), false, 'verify-restore.sh did not run');
    assert.deepEqual(f.archives(), [`${newest}.tar.enc`], 'the archive itself was written and is kept');
  } finally { f.cleanup(); }
});

test('a rename that fails is a failure of the copy, not "Copied and verified", and leaves no archive and no sidecar file behind', () => {
  const f = fixture('warehouse-usb-renamefails-');
  try {
    f.enroll();
    const [newest] = f.backups(1);
    // A mv that fails for the archive's final name only (the checksum and signature files move normally).
    const wrap = join(f.scratch, 'mvwrap'); mkdirSync(wrap);
    writeFileSync(join(wrap, 'mv'), '#!/bin/sh\nfor last; do :; done\ncase "$last" in */warehouse-*.tar.enc) echo "mv: simulated failure" >&2; exit 1 ;; esac\nexec /usr/bin/mv "$@"\n', { mode: 0o755 });
    const result = f.run(RUN, { ...f.verifyEnv(), PATH: `${wrap}:${join(f.scratch, 'shims')}:${join(f.scratch, 'dockerbin')}:${process.env.PATH}` });
    assert.equal(result.status, 1, result.stdout);
    assert.match(result.stderr, new RegExp(`FAILED: moving the archive of ${newest} into place failed`));
    assert.doesNotMatch(result.stdout, /Copied and verified/);
    assert.match(result.stdout, /copied=0 /);
    assert.match(f.last(), /^result=failed$/m);
    assert.deepEqual(readdirSync(f.dest).filter(n => n.startsWith('warehouse-') || n.endsWith('.partial')), [], 'no archive, no sidecar, no partial file');
  } finally { f.cleanup(); }
});

test('checksum and signature files left without an archive by an interrupted copy are removed; other files are left alone', () => {
  const f = fixture('warehouse-usb-orphans-');
  try {
    f.enroll();
    const [newest] = f.backups(1);
    mkdirSync(f.dest, { recursive: true });
    const orphans = ['warehouse-20251230T000000Z.tar.enc.sha256', 'warehouse-20251230T000000Z.tar.enc.hmac', 'warehouse-20251229T000000Z.tar.sha256'];
    for (const name of orphans) writeFileSync(join(f.dest, name), 'left by an interrupted copy\n');
    for (const name of ['warehouse-notes.sha256', 'backup.sha256', 'warehouse-20251228T000000Z.tar.enc.sha256.old']) writeFileSync(join(f.dest, name), 'the operator\'s own file\n');
    const result = f.run(RUN, f.verifyEnv());
    assert.equal(result.status, 0, result.stderr + result.stdout);
    for (const name of orphans) {
      assert.equal(existsSync(join(f.dest, name)), false, `${name} was removed`);
      assert.match(result.stdout, new RegExp(`Removing the leftover checksum or signature file ${name.replace(/\./g, '\\.')}: its archive is not on the drive`));
    }
    for (const name of ['warehouse-notes.sha256', 'backup.sha256', 'warehouse-20251228T000000Z.tar.enc.sha256.old']) assert.equal(readFileSync(join(f.dest, name), 'utf8'), 'the operator\'s own file\n', `${name} is untouched`);
    assert.deepEqual(f.archives(), [`${newest}.tar.enc`]);
    assert.ok(existsSync(join(f.dest, `${newest}.tar.enc.sha256`)) && existsSync(join(f.dest, `${newest}.tar.enc.hmac`)), 'the new archive keeps its own');
  } finally { f.cleanup(); }
});

test('readable archives are deleted once an encrypted one is written and verified in the run, and only then', () => {
  const f = fixture('warehouse-usb-plaindel-');
  try {
    f.enroll();
    // The drive as an earlier release left it: readable archives of three backups (and a readable archive nobody signed).
    for (const day of [1, 2, 3]) seed(f, day, PLAIN);
    writeFileSync(join(f.dest, 'warehouse-20241201T000000Z.tar'), 'an older, unsigned archive');
    writeFileSync(join(f.dest, 'warehouse-20241201T000000Z.tar.sha256'), `${spawnSync('sha256sum', [join(f.dest, 'warehouse-20241201T000000Z.tar')], { encoding: 'utf8' }).stdout.split(' ')[0]}  warehouse-20241201T000000Z.tar\n`);
    assert.deepEqual(f.archives().filter(n => n.endsWith('.tar')).length, 4);
    f.localBackup(f.bname(4));

    // 1. The new encrypted archive does not verify (the catalog names an object the backup does not hold): nothing is deleted.
    const catalog = join(f.scratch, 'catalog-extra.txt');
    writeFileSync(catalog, `${readFileSync(join(f.state, 'backups', f.bname(1), 'storage_objects.txt'), 'utf8')}documents/not-in-the-backup.pdf/v1\n`);
    let result = f.run(RUN, { FAKE_CATALOG_FILE: catalog });
    assert.equal(result.status, 1, result.stdout);
    assert.match(result.stderr, new RegExp(`restore verification of ${f.bname(4)} from the drive failed`));
    assert.ok(existsSync(join(f.dest, `${f.bname(4)}.tar.enc`)), 'the encrypted archive is written');
    assert.equal(f.archives().filter(n => n.endsWith('.tar')).length, 4, 'the readable archives are all still there');
    assert.doesNotMatch(result.stdout, /Deleting the unencrypted archive/);
    assert.match(result.stdout, /WARNING: archives written by this run are encrypted, but the drive still holds unencrypted \.tar archives/);
    assert.match(result.stdout, /unencrypted-removed=0/);

    // 2. The next run verifies it: the readable archives of this installation go with their checksum and signature files; the
    // unsigned one is not provably this installation's, so it stays, named.
    result = f.run(RUN, f.verifyEnv());
    assert.equal(result.status, 0, result.stderr + result.stdout);
    for (const day of [1, 2, 3]) {
      assert.match(result.stdout, new RegExp(`Deleting the unencrypted archive ${f.bname(day)}\\.tar: an encrypted archive has been written and verified in this run, and the backup key copy is confirmed\\.`));
      assert.deepEqual(readdirSync(f.dest).filter(n => n.includes(`${f.bname(day)}.tar`)), []);
    }
    assert.match(result.stdout, /unencrypted-removed=3/);
    // Deleting is not wiping: the run says so where it deletes.
    assert.match(result.stdout, /NOTE: deleting a file does not wipe it from an exFAT drive[\s\S]*rotate the credentials they held \(rotate-keys\.sh, the MSG91 key, the tunnel credential\) or retire the drive/);
    assert.deepEqual(f.archives(), ['warehouse-20241201T000000Z.tar', `${f.bname(4)}.tar.enc`]);
    assert.match(result.stdout, /Not counted and not deleted .*warehouse-20241201T000000Z\.tar/);
    assert.match(result.stdout, /WARNING: archives written by this run are encrypted, but the drive still holds unencrypted \.tar archives/);
  } finally { f.cleanup(); }
});

test('the first encrypted archive of an installation switched at setup replaces the readable one of the same backup, and the readable one is deleted', () => {
  const f = fixture('warehouse-usb-flipdrive-');
  try {
    f.enroll();
    seed(f, 1, PLAIN);
    seed(f, 2, PLAIN);
    // The newest backup already has a readable archive on the drive: it does not stand in for the encrypted one.
    const result = f.run(RUN, f.verifyEnv());
    assert.equal(result.status, 0, result.stderr + result.stdout);
    assert.deepEqual(f.archives(), [`${f.bname(2)}.tar.enc`]);
    assert.match(result.stdout, /copied=1 already-present=0 failed=0 pruned=0 unencrypted-removed=2/);
    // With --no-encrypt typed it works the other way: an encrypted archive stands in for the readable one.
    const plain = f.run(RUN, { ...f.verifyEnv(), ...PLAIN });
    assert.equal(plain.status, 0, plain.stderr + plain.stdout);
    assert.match(plain.stdout, /copied=0 already-present=1 failed=0/);
    assert.deepEqual(f.archives(), [`${f.bname(2)}.tar.enc`], 'no readable archive was written next to the encrypted one');
  } finally { f.cleanup(); }
});

test('with restore verification switched off no readable archive is deleted: a hash alone is not enough, and the newest archive need not be the one just written', () => {
  const f = fixture('warehouse-usb-noverify-');
  try {
    f.enroll();
    seed(f, 1, PLAIN);
    f.localBackup(f.bname(2));
    const result = f.run(RUN, { ...f.verifyEnv(), ...NOVERIFY });
    assert.equal(result.status, 0, result.stderr + result.stdout);
    assert.deepEqual(f.archives(), [`${f.bname(1)}.tar`, `${f.bname(2)}.tar.enc`], 'the readable archive stays');
    assert.match(result.stdout, /Restore verification is switched off .*no unencrypted archive is deleted in this run/);
    assert.doesNotMatch(result.stdout, /Deleting the unencrypted archive/);
    assert.match(result.stdout, /unencrypted-removed=0/);
    assert.equal(f.dockerCalls(), '', 'no restore verification');
    // The same drive with verification on: now they go.
    const checked = f.run(RUN, f.verifyEnv());
    assert.equal(checked.status, 0, checked.stderr + checked.stdout);
    assert.deepEqual(f.archives(), [`${f.bname(2)}.tar.enc`]);
  } finally { f.cleanup(); }
});

test('the newest archive on the drive holds an unsigned backup (written by an earlier release): the run names it and does not verify it', () => {
  const f = fixture('warehouse-usb-unsignedinside-');
  try {
    f.enroll();
    f.backups(1);
    // A signed archive, as an earlier release wrote them, of a backup that carries no SHA256SUMS.hmac, and newer than the local one.
    const planted = 'warehouse-20260201T000000Z';
    const folder = join(f.scratch, 'planted-src', planted);
    makeBackup(folder, { env: composeEnv(f.state), format: 'warehouse-backup-v6', key: null });
    mkdirSync(f.dest, { recursive: true });
    const out = join(f.dest, `${planted}.tar.enc`);
    const made = spawnSync('bash', ['-c', 'set -euo pipefail; source "$1"; source "$2"; backup_key_load "$3"; hash="$(backup_archive_write "$4" "$5" encrypt)"; printf "%s  %s\\n" "$hash" "$6" > "$5.sha256"; backup_sign_archive "$5" "$BACKUP_KEY"',
      'sh', join(f.root, 'scripts/backup-key.sh'), join(f.root, 'scripts/backup-archive.sh'), join(f.state, 'config/backup.key'), folder, out, `${planted}.tar.enc`], { encoding: 'utf8' });
    assert.equal(made.status, 0, made.stderr);
    const result = f.run(RUN, f.verifyEnv());
    assert.equal(result.status, 1, result.stdout);
    assert.match(result.stderr, new RegExp(`FAILED: the newest backup on the drive \\(${planted}\\) is unsigned, written by an earlier release, so its restore was not verified; take a new backup with npm run db:backup`));
    assert.equal(f.dockerCalls(), '', 'no restore verification ran');
    assert.doesNotMatch(result.stdout, /Restore verification of the copy on the drive passed/);
    assert.ok(existsSync(out), 'the archive is kept');
    assert.match(f.last(), /^result=failed$/m);
  } finally { f.cleanup(); }
});

// ---------------------------------------------------------------- the saved images (<state>/images) go to the drive beside the archives
// What scripts/build-images.sh leaves in <state>/images: the tarballs, a copy of the build record and SHA256SUMS signed with the backup key.
const sha = bytes => createHash('sha256').update(bytes).digest('hex');
function savedImages(f, files = { 'db.tar': 'db image bytes', 'functions.tar': 'functions image bytes' }) {
  const dir = join(f.state, 'images');
  mkdirSync(dir, { recursive: true, mode: 0o700 });
  rmSync(join(dir, 'SHA256SUMS'), { force: true }); rmSync(join(dir, 'SHA256SUMS.hmac'), { force: true });
  for (const [name, body] of Object.entries({ ...files, 'image-recipes.sha256': `${'1'.repeat(64)}  db  sha256:${'a'.repeat(64)}\n` })) writeFileSync(join(dir, name), body, { mode: 0o600 });
  const names = readdirSync(dir).sort();
  writeFileSync(join(dir, 'SHA256SUMS'), names.map(name => `${sha(readFileSync(join(dir, name)))}  ${name}\n`).join(''), { mode: 0o600 });
  signBackup(dir);
  return dir;
}
// What db:restore-host checks before it loads anything from a folder: backup_authenticate with the backup key.
const authentic = (f, dir) => spawnSync('bash', ['-c', 'source "$1/scripts/backup-key.sh"; backup_authenticate "$2" false', 'sh', f.root, dir], { encoding: 'utf8',
  env: { ...process.env, WAREHOUSE_BACKUP_KEY_FILE: join(f.state, 'config/backup.key') } }).status === 0;
const files = dir => readdirSync(dir).sort();

test('the saved images are copied to the drive beside the archives, unencrypted and signed as they are, once, and again only when their signed list changes', () => {
  const f = fixture('warehouse-usb-images-');
  try {
    f.enroll();
    const [newest] = f.backups(1);
    const source = savedImages(f);
    const first = f.run(RUN, f.verifyEnv());
    assert.equal(first.status, 0, first.stderr + first.stdout);
    // Where db:restore-host looks: an `images` folder next to the archive it is given, as build-images.sh wrote it.
    const copy = join(f.dest, 'images');
    assert.deepEqual(f.archives(), [`${newest}.tar.enc`]);
    assert.deepEqual(files(copy), files(source));
    for (const name of files(source)) assert.equal(readFileSync(join(copy, name), 'utf8'), readFileSync(join(source, name), 'utf8'), `${name} is byte for byte what is signed`);
    assert.equal(authentic(f, copy), true, 'the copy authenticates with the backup key, as restore-host requires');
    assert.match(first.stdout, /Copied the saved images to the drive and verified them: 3 file\(s\), \d+(\.\d+)?\w*B?, in images\/ beside the archives\./);
    assert.match(f.last(), /^message=copied 1, .*, saved images copied$/m);
    assert.match(first.stdout, /copied=1 already-present=0 failed=0/, 'the images are not counted as archives');
    // Nothing of them is inside the archive, and the archive's rules (the newest three) are not applied to the folder.
    assert.doesNotMatch(spawnSync('bash', ['-c', 'set -euo pipefail; source "$1"; backup_key_load "$2"; backup_decrypt "$BACKUP_KEY" < "$3" | tar -tf -', 'sh', join(f.root, 'scripts/backup-key.sh'), join(f.state, 'config/backup.key'), join(f.dest, `${newest}.tar.enc`)], { encoding: 'utf8' }).stdout, /db\.tar|image-recipes/);
    assert.deepEqual(readdirSync(f.dest).filter(name => name.startsWith('.images')), [], 'no partial or old folder is left');

    // Unchanged list: verified on the drive, not written again.
    const before = ['db.tar', 'functions.tar', 'SHA256SUMS'].map(name => { const s = statSync(join(copy, name)); return [s.ino, s.mtimeMs]; });
    const second = f.run(RUN, f.verifyEnv());
    assert.equal(second.status, 0, second.stderr);
    assert.match(second.stdout, /The saved images are already on the drive and verified\./);
    assert.doesNotMatch(second.stdout, /Copied the saved images/);
    assert.match(f.last(), /saved images already present$/m);
    assert.deepEqual(['db.tar', 'functions.tar', 'SHA256SUMS'].map(name => { const s = statSync(join(copy, name)); return [s.ino, s.mtimeMs]; }), before, 'not rewritten');

    // A rebuild changed the folder (a new signed list): the new folder replaces the old one whole, a file that is gone is gone.
    rmSync(join(source, 'functions.tar'));
    savedImages(f, { 'db.tar': 'db image bytes, rebuilt', 'storage.tar': 'a new storage image' });
    const third = f.run(RUN, f.verifyEnv());
    assert.equal(third.status, 0, third.stderr + third.stdout);
    assert.match(third.stdout, /Copied the saved images to the drive and verified them: 3 file\(s\)/);
    assert.deepEqual(files(copy), files(source));
    assert.equal(readFileSync(join(copy, 'db.tar'), 'utf8'), 'db image bytes, rebuilt');
    assert.equal(authentic(f, copy), true);
    assert.deepEqual(readdirSync(f.dest).filter(name => name.startsWith('.images')), []);

    // Same list, but the drive's copy was damaged: copied again, which repairs it.
    writeFileSync(join(copy, 'db.tar'), 'damaged on the drive');
    const fourth = f.run(RUN, f.verifyEnv());
    assert.equal(fourth.status, 0, fourth.stderr + fourth.stdout);
    assert.match(fourth.stdout, /The saved images on the drive do not match their list; copying them again\./);
    assert.match(fourth.stdout, /Copied the saved images to the drive and verified them/);
    assert.equal(readFileSync(join(copy, 'db.tar'), 'utf8'), 'db image bytes, rebuilt');
    assert.equal(readFileSync(join(f.drive, 'holiday-photos.zip'), 'utf8'), 'not ours');
  } finally { f.cleanup(); }
});

test('without saved images the run says so and succeeds, and the drive gets none; a copy from an earlier run stays', () => {
  const f = fixture('warehouse-usb-images-none-');
  try {
    f.enroll();
    f.backups(1);
    const result = f.run(RUN, f.verifyEnv());
    assert.equal(result.status, 0, result.stderr + result.stdout);
    assert.match(result.stdout, new RegExp(`No saved images in ${f.state}/images yet, so none were copied\\. bash scripts/build-images\\.sh --save writes them`));
    assert.match(f.last(), /^result=ok$/m);
    assert.match(f.last(), /saved images none yet$/m);
    assert.equal(existsSync(join(f.dest, 'images')), false);
    // A folder on the drive from an earlier run is not removed because the host's folder is gone.
    savedImages(f);
    assert.equal(f.run(RUN, f.verifyEnv()).status, 0);
    rmSync(join(f.state, 'images'), { recursive: true });
    assert.equal(f.run(RUN, f.verifyEnv()).status, 0);
    assert.ok(existsSync(join(f.dest, 'images', 'db.tar')));
  } finally { f.cleanup(); }
});

test('saved images that do not authenticate with the backup key are not copied: the archive copy still succeeds, the run says so and records it, and the earlier copy on the drive is untouched', () => {
  const f = fixture('warehouse-usb-images-forged-');
  try {
    f.enroll();
    const [newest] = f.backups(1);
    savedImages(f);
    assert.equal(f.run(RUN, f.verifyEnv()).status, 0);
    const good = readFileSync(join(f.dest, 'images', 'db.tar'), 'utf8');
    // Changed after signing (the list on the drive then differs from the host's only if the list was re-made, so change both kinds).
    writeFileSync(join(f.state, 'images', 'db.tar'), 'changed after signing');
    writeFileSync(join(f.state, 'images', 'SHA256SUMS'), readFileSync(join(f.state, 'images', 'SHA256SUMS'), 'utf8').replace(/^[0-9a-f]{64}  db\.tar$/m, `${sha('changed after signing')}  db.tar`));
    const result = f.run(RUN, f.verifyEnv());
    assert.equal(result.status, 0, 'the archive was copied and verified; only the images were not: ' + result.stderr + result.stdout);
    assert.match(result.stderr, new RegExp(`WARNING: saved images NOT copied: ${f.state}/images does not authenticate with the backup key \\(.*\\)\\. Run bash scripts/build-images\\.sh --save, which signs the images with the key in use, then attach the drive again`));
    assert.doesNotMatch(result.stderr, /FAILED/);
    assert.equal(readFileSync(join(f.dest, 'images', 'db.tar'), 'utf8'), good, 'the copy that was authentic stays');
    assert.ok(existsSync(join(f.dest, `${newest}.tar.enc`)), 'the archive is not affected');
    assert.match(f.last(), /^result=ok$/m);
    assert.match(f.last(), /^failed=0$/m);
    assert.match(f.last(), /^images_problem=.*does not authenticate with the backup key/m);
    assert.match(f.last(), /, saved images NOT copied: .*does not authenticate with the backup key/);
    // A folder with no signature at all is the same.
    rmSync(join(f.state, 'images', 'SHA256SUMS.hmac'));
    rmSync(join(f.dest, 'images'), { recursive: true });
    const unsigned = f.run(RUN, f.verifyEnv());
    assert.equal(unsigned.status, 0, unsigned.stderr);
    assert.match(unsigned.stderr, /saved images NOT copied: .*does not authenticate with the backup key/);
    assert.equal(existsSync(join(f.dest, 'images')), false, 'nothing unproven reaches the drive');
  } finally { f.cleanup(); }
});

test('saved images that do not fit are recorded as not copied and the archive copy stands; the room is measured and the sizes named, and nothing is deleted to make room', () => {
  const f = fixture('warehouse-usb-images-room-');
  try {
    f.enroll();
    f.backups(1);
    // The archive first, with room to spare; then the images, with less room than they and the 64 MiB reserve need.
    seed(f, 1, f.dfEnv({ FAKE_DRIVE_CAP: String(2 ** 30) }));
    const archives = f.archives();
    savedImages(f, { 'db.tar': 'x'.repeat(3 * 1024 * 1024) });
    const used = Number(spawnSync('du', ['-sb', f.drive], { encoding: 'utf8' }).stdout.split('\t')[0]);
    const tight = f.run(RUN, f.dfEnv({ ...f.verifyEnv(), FAKE_DRIVE_CAP: String(used + 20 * 1024 * 1024) }));
    assert.equal(tight.status, 0, tight.stderr + tight.stdout);
    assert.match(tight.stderr, /WARNING: saved images NOT copied: drive too small: they need \d+MiB next to what is on the drive after this run's pruning, and it has 20MiB free \(a changed set is written beside the old one, so a drive needs room for both while it is replaced\)\. The archives are not touched by this\. Use a larger drive\n/);
    assert.doesNotMatch(tight.stderr, /keep fewer archives|--keep|FAILED/, 'pruning has already run, so fewer archives cannot be the remedy');
    assert.deepEqual(f.archives(), archives, 'nothing was deleted');
    assert.equal(existsSync(join(f.dest, 'images')), false);
    assert.deepEqual(readdirSync(f.dest).filter(name => name.startsWith('.images')), []);
    assert.match(f.last(), /^result=ok$/m);
    assert.match(f.last(), /, saved images NOT copied: drive too small: /);
    // With room it goes through.
    const roomy = f.run(RUN, f.dfEnv({ ...f.verifyEnv(), FAKE_DRIVE_CAP: String(used + 200 * 1024 * 1024) }));
    assert.equal(roomy.status, 0, roomy.stderr + roomy.stdout);
    assert.ok(existsSync(join(f.dest, 'images', 'db.tar')));
    assert.match(f.last(), /^images_problem=$/m, 'the problem is gone from the record once the images are copied');
    // The free space cannot be read: not zero, not a guess.
    savedImages(f, { 'db.tar': 'x'.repeat(1024) });
    const blind = f.run(RUN, f.dfEnv({ ...f.verifyEnv(), FAKE_DF_BROKEN: 'drive' }));
    assert.equal(blind.status, 0, blind.stderr);
    assert.match(blind.stderr, /WARNING: saved images NOT copied: could not read the free space of the drive .* so it cannot be checked that they fit/);
  } finally { f.cleanup(); }
});

test('an images problem does not hold back the pruning or the removal of readable archives, does not mark the archive copy failed, and the next run with room copies the images', () => {
  const f = fixture('warehouse-usb-images-prune-');
  try {
    f.enroll();
    // The drive as the first encrypted run of this release finds it: readable archives of earlier releases and three encrypted ones.
    for (const day of [1, 2]) seed(f, day, PLAIN);
    for (const day of [3, 4, 5]) seed(f, day);
    assert.equal(f.archives().length, 5);
    savedImages(f, { 'db.tar': 'x'.repeat(3 * 1024 * 1024) });
    const used = Number(spawnSync('du', ['-sb', f.drive], { encoding: 'utf8' }).stdout.split('\t')[0]);
    // The images do not fit even on the pruned drive; the run keeps one archive.
    const result = f.run(RUN, f.dfEnv({ ...f.verifyEnv(), WAREHOUSE_USB_KEEP: '1', FAKE_DRIVE_CAP: String(used + 20 * 1024 * 1024) }));
    assert.equal(result.status, 0, result.stderr + result.stdout);
    assert.deepEqual(f.archives(), [`${f.bname(5)}.tar.enc`], 'the readable archives are removed and the archives beyond --keep are deleted, although the images were not copied');
    assert.match(result.stdout, /copied=0 already-present=1 failed=0 pruned=2 unencrypted-removed=2/);
    assert.match(result.stderr, /WARNING: saved images NOT copied: drive too small: /);
    assert.equal(existsSync(join(f.dest, 'images')), false);
    // Recorded as a successful archive copy (last_success moves) with the images said apart; doctor shows it.
    const record = Object.fromEntries(f.last().split('\n').filter(line => line.includes('=')).map(line => [line.slice(0, line.indexOf('=')), line.slice(line.indexOf('=') + 1)]));
    assert.equal(record.result, 'ok');
    assert.equal(record.failed, '0');
    assert.equal(record.last_success_epoch, record.finished_epoch, 'the archive copy counts as the last success');
    assert.match(record.message, /pruned 2, unencrypted removed 2, restore verified .*, saved images NOT copied: drive too small/);
    assert.match(usbBackupWarning(f.state, { etc: f.etc }), /The last USB backup copied the archive but not the saved images: drive too small: /);
    // The next run, with room (the same drive after the pruning), copies the images and clears the record.
    const next = f.run(RUN, f.dfEnv({ ...f.verifyEnv(), WAREHOUSE_USB_KEEP: '1', FAKE_DRIVE_CAP: String(used + 200 * 1024 * 1024) }));
    assert.equal(next.status, 0, next.stderr + next.stdout);
    assert.ok(existsSync(join(f.dest, 'images', 'db.tar')));
    assert.match(f.last(), /^images_problem=$/m);
    assert.equal(usbBackupWarning(f.state, { etc: f.etc }), null);
  } finally { f.cleanup(); }
});

test('the room for the saved images is measured after the pruning of the run: images that fit only once the archives beyond --keep are gone are copied in that same run', () => {
  const f = fixture('warehouse-usb-images-afterprune-');
  try {
    f.enroll();
    for (const day of [1, 2, 3, 4]) seed(f, day);
    const source = savedImages(f, { 'db.tar': 'x'.repeat(3 * 1024 * 1024) });
    // What the script wants for the images: their files (not the list and its signature) and 64 MiB; and what the run is about to delete.
    const imageBytes = readdirSync(source).filter(name => !name.startsWith('SHA256SUMS')).reduce((sum, name) => sum + sizeOf(join(source, name)), 0);
    const wanted = imageBytes + 64 * 1024 * 1024;
    const doomed = readdirSync(f.dest).filter(name => [1, 2, 3].some(day => name.startsWith(f.bname(day)))).reduce((sum, name) => sum + sizeOf(join(f.dest, name)), 0);
    assert.ok(doomed > 1000, 'the archives about to be pruned take room');
    const used = Number(spawnSync('du', ['-sb', f.drive], { encoding: 'utf8' }).stdout.split('\t')[0]);
    // Free before the pruning: half of what the pruning frees short of the need; after it: half of it above the need.
    const cap = used + wanted - Math.floor(doomed / 2);
    const result = f.run(RUN, f.dfEnv({ ...f.verifyEnv(), WAREHOUSE_USB_KEEP: '1', FAKE_DRIVE_CAP: String(cap) }));
    assert.equal(result.status, 0, result.stderr + result.stdout);
    assert.deepEqual(f.archives(), [`${f.bname(4)}.tar.enc`]);
    assert.match(result.stdout, /copied=0 already-present=1 failed=0 pruned=3/);
    assert.doesNotMatch(result.stderr, /NOT copied/);
    assert.match(result.stdout, /Copied the saved images to the drive and verified them/);
    assert.equal(authentic(f, join(f.dest, 'images')), true);
    assert.ok(result.stdout.indexOf('Deleting the archive') < result.stdout.indexOf('Copied the saved images'), 'the archives go first, then the images are copied');
  } finally { f.cleanup(); }
});

test('an interrupted replacement of the saved images on the drive never costs the only good copy: the older folder is put back before the leftovers are cleared', () => {
  const f = fixture('warehouse-usb-images-swap-');
  try {
    f.enroll();
    f.backups(1);
    const source = savedImages(f);
    assert.equal(f.run(RUN, f.verifyEnv()).status, 0);
    // The run died after `mv images .images.old` and before `mv .images.partial images`: the good copy is under the old name.
    renameSync(join(f.dest, 'images'), join(f.dest, '.images.old'));
    mkdirSync(join(f.dest, '.images.partial')); writeFileSync(join(f.dest, '.images.partial', 'db.tar'), 'half written');
    // The host's folder is gone as well (a rebuilt host), so nothing could replace it: only the old copy is left.
    rmSync(source, { recursive: true });
    const result = f.run(RUN, f.verifyEnv());
    assert.equal(result.status, 0, result.stderr + result.stdout);
    assert.match(result.stdout, /The earlier saved images were put back \(images\/\): the last copy to the drive was interrupted while it replaced them\./);
    assert.equal(readFileSync(join(f.dest, 'images', 'db.tar'), 'utf8'), 'db image bytes', 'the good copy is back');
    assert.equal(authentic(f, join(f.dest, 'images')), true);
    assert.deepEqual(readdirSync(f.dest).filter(name => name.startsWith('.images')), [], 'the half-written folder is gone');
    // When the images folder is there, an old one is only a leftover.
    mkdirSync(join(f.dest, '.images.old')); writeFileSync(join(f.dest, '.images.old', 'db.tar'), 'older');
    assert.equal(f.run(RUN, f.verifyEnv()).status, 0);
    assert.equal(readFileSync(join(f.dest, 'images', 'db.tar'), 'utf8'), 'db image bytes');
    assert.deepEqual(readdirSync(f.dest).filter(name => name.startsWith('.images')), []);
    // When the old copy cannot be put back (the move fails), it is left where it is, with the warning: it is never deleted as a leftover.
    renameSync(join(f.dest, 'images'), join(f.dest, '.images.old'));
    const shim = join(f.scratch ?? f.drive, 'mv-shim'); mkdirSync(shim);
    writeFileSync(join(shim, 'mv'), '#!/bin/sh\ncase "$*" in *"/.images.old "*"/images") echo "mv: cannot move" >&2; exit 1 ;; esac\nexec /bin/mv "$@"\n', { mode: 0o755 });
    const stuck = f.run(RUN, { ...f.verifyEnv(), PATH: `${shim}:${f.dfEnv().PATH}` });
    assert.match(stuck.stderr, /Warning: could not put the earlier saved images \(\.images\.old\) back; they are left where they are\./);
    assert.equal(readFileSync(join(f.dest, '.images.old', 'db.tar'), 'utf8'), 'db image bytes', 'the only good copy was not deleted');
  } finally { f.cleanup(); }
});

test('a folder left by an interrupted copy of the images is removed at the next run, and the enrolment output says how much room the images add', () => {
  const f = fixture('warehouse-usb-images-leftover-');
  try {
    const none = f.asRoot(['setup', '--state', f.state, '--enroll', '/dev/sdb1']);
    assert.equal(none.status, 0, none.stderr + none.stdout);
    assert.match(none.stdout, new RegExp(`There are no saved images in ${f.state}/images yet\\. Once bash scripts/build-images\\.sh --save has written them \\(about 2\\.5 GiB\\), the drive receives them too, beside the archives`));
    assert.equal((none.stdout.match(/saved images/gi) ?? []).length, 1, 'said once for the enrolment, not again by the setup that enrolled');
    assert.match(none.stdout, /the drive needs that much more room \(as much again free while a changed set is written beside the old one\)\./, 'the room while the images change is said too');
    savedImages(f, { 'db.tar': 'x'.repeat(3 * 1024 * 1024), 'functions.tar': 'y'.repeat(2 * 1024 * 1024) });
    const enrol = f.asRoot(['enroll', '--device', '/dev/sdb1']);
    assert.equal(enrol.status, 0, enrol.stderr + enrol.stdout);
    assert.match(enrol.stdout, new RegExp(`The saved images \\(${f.state}/images, 5\\.0MiB now\\) are copied to the drive as well, once and again after a change, beside the archives: the drive needs that much room more than the archives`));
    assert.match(enrol.stdout, /\(about 2\.5 GiB at the first install\) and as much again free while a changed set is written beside the old one\. A lost-host restore from the drive then needs no Debian, npm or Chrome for Testing to answer; Docker Hub is still needed for the postgres and PostgREST images\./);
    const setup = f.asRoot(['setup', '--state', f.state]);
    assert.equal(setup.status, 0, setup.stderr);
    assert.match(setup.stdout, /The saved images \(.*\/images, 5\.0MiB now\) are copied to the drive as well/);
    f.backups(1);
    const plantLeftovers = () => {
      mkdirSync(join(f.dest, '.images.partial'), { recursive: true }); writeFileSync(join(f.dest, '.images.partial', 'db.tar'), 'interrupted');
      mkdirSync(join(f.dest, '.images.old'), { recursive: true }); writeFileSync(join(f.dest, '.images.old', 'db.tar'), 'older');
    };
    // The copy that follows an interruption clears them before it writes...
    mkdirSync(f.dest, { recursive: true });
    plantLeftovers();
    const result = f.run(RUN, f.verifyEnv());
    assert.equal(result.status, 0, result.stderr + result.stdout);
    assert.deepEqual(readdirSync(f.dest).filter(name => name.startsWith('.images')), []);
    assert.equal(readFileSync(join(f.dest, 'images', 'db.tar'), 'utf8').length, 3 * 1024 * 1024);
    // ...and a run with nothing to copy (the drive is current) clears them too.
    plantLeftovers();
    const current = f.run(RUN, f.verifyEnv());
    assert.equal(current.status, 0, current.stderr + current.stdout);
    assert.match(current.stdout, /The saved images are already on the drive and verified\./);
    assert.deepEqual(readdirSync(f.dest).filter(name => name.startsWith('.images')), []);
  } finally { f.cleanup(); }
});
