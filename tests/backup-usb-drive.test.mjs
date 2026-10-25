// What scripts/backup-usb.sh does with the drive's contents: the restore check that unpacks no photo, the free-space guard,
// keeping the newest archives, never touching foreign ones, making room, and deleting readable archives only after an encrypted
// one has been written and verified. Fake drives only (tests/usb-test-helpers.mjs): nothing here touches a USB device.
import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdirSync, writeFileSync, readFileSync, existsSync, readdirSync, statSync, copyFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { join } from 'node:path';
import { composeEnv, makeBackup, backupKey, hmacHex } from './backup-test-helpers.mjs';
import { fixture } from './usb-test-helpers.mjs';

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

test('when no deletion can make room the run fails with "drive too small", and the newest valid archive is still there', () => {
  const f = fixture('warehouse-usb-toosmall-');
  try {
    f.enroll();
    for (const day of [1, 2, 3]) seed(f, day);
    f.localBackup(f.bname(4));
    const wanted = need(join(f.state, 'backups', f.bname(4)));
    const result = f.run(RUN, f.dfEnv({ ...f.verifyEnv(), WAREHOUSE_USB_KEEP: '99', FAKE_DRIVE_CAP: String(wanted - 1) }));
    assert.equal(result.status, 1);
    assert.match(result.stderr, /FAILED: drive too small: needs \S+, has \S+; the drive must hold the new archive next to the newest valid one it already has/);
    // The older two went; the newest valid one is never deleted; the new archive was not started.
    assert.deepEqual(f.archives(), [`${f.bname(3)}.tar.enc`]);
    assert.deepEqual(readdirSync(f.dest).filter(n => n.endsWith('.partial')), []);
    assert.match(f.last(), /^result=failed$/m);
    assert.match(f.last(), /drive too small: needs/);
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

test('with restore verification switched off an encrypted archive that was written and read back still lets the readable ones go', () => {
  const f = fixture('warehouse-usb-noverify-');
  try {
    f.enroll();
    seed(f, 1, PLAIN);
    f.localBackup(f.bname(2));
    const result = f.run(RUN, { ...f.verifyEnv(), ...NOVERIFY });
    assert.equal(result.status, 0, result.stderr + result.stdout);
    assert.deepEqual(f.archives(), [`${f.bname(2)}.tar.enc`]);
    assert.equal(f.dockerCalls(), '', 'no restore verification');
  } finally { f.cleanup(); }
});
