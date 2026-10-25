// scripts/backup-usb.sh against fake device tools on PATH (tests/usb-test-helpers.mjs). No test touches a real device, mount,
// udev rule or systemd unit: /etc, /usr/local/libexec and /run are redirected into a scratch tree. The rules of the drive's
// contents (which backup is copied, what is deleted, the key escrow gate) are in tests/backup-usb-drive.test.mjs.
import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, existsSync, readdirSync, rmSync, statSync, chmodSync, copyFileSync } from 'node:fs';
import { spawn, spawnSync } from 'node:child_process';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { makeBackup, composeEnv, backupKey, hmacHex, writeKey, writeEscrow, xattrTool, xattrSkip } from './backup-test-helpers.mjs';
import { fixture, UUID, PART, marker, devRow } from './usb-test-helpers.mjs';
import { usbBackupWarning } from '../scripts/usb-backup-status.mjs';

const pause = ms => Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);
const PLAIN = { WAREHOUSE_BACKUP_ENCRYPT: '0' };
// The archive as a tar listing, decrypted with the key when it is an .enc file.
const listing = (f, archive) => {
  const result = archive.endsWith('.enc')
    ? spawnSync('bash', ['-c', 'set -euo pipefail; source "$1"; backup_key_load "$2"; backup_decrypt "$BACKUP_KEY" < "$3" | tar -tvf -', 'sh', join(f.root, 'scripts/backup-key.sh'), join(f.state, 'config/backup.key'), archive], { encoding: 'utf8' })
    : spawnSync('tar', ['-tvf', archive], { encoding: 'utf8' });
  assert.equal(result.status, 0, result.stderr);
  return result.stdout;
};

test('run copies the newest backup as one encrypted, signed, self-contained archive, checks it from the drive and leaves other files alone', () => {
  const f = fixture('warehouse-usb-ok-');
  try {
    f.enroll();
    const [older, newest] = f.backups(2);
    const result = f.run(['run', '--device', 'sdb1'], f.verifyEnv());
    assert.equal(result.status, 0, result.stderr + result.stdout);
    // Encrypted by default (nothing was typed), and only the newest backup is copied: the drive keeps a few archives, not every
    // local backup. The older backup is not on the drive.
    assert.deepEqual(f.archives(), [`${newest}.tar.enc`]);
    assert.ok(!existsSync(join(f.dest, `${older}.tar.enc`)) && !existsSync(join(f.dest, `${older}.tar`)));
    const archive = join(f.dest, `${newest}.tar.enc`);
    assert.equal(spawnSync('sha256sum', ['-c', '--quiet', `${newest}.tar.enc.sha256`], { cwd: f.dest }).status, 0);
    assert.equal(readFileSync(`${archive}.hmac`, 'utf8'), `warehouse-backup-hmac-v1 ${hmacHex(backupKey, 'warehouse-backup-archive-v1', readFileSync(`${archive}.sha256`))}\n`, 'the archive checksum is signed with the backup key');
    const bytes = readFileSync(archive, 'latin1');
    assert.match(bytes, /^Salted__/, 'openssl salted format');
    for (const plain of ['compose.env', 'WAREHOUSE_PROJECT_NAME', 'fake database dump', newest, 'bytes of stub']) assert.ok(!bytes.includes(plain), `${plain} is not readable on the drive`);
    // One self-contained tar of the backup folder: the signed list and the small files first, then the manifest, then the whole tree.
    const text = listing(f, archive);
    assert.match(text, /^-rw------- .*compose\.env$/m, 'file modes are kept inside the archive');
    const names = text.split('\n').filter(Boolean).map(line => line.split(/\s+/).slice(5).join(' '));
    const at = name => names.indexOf(`${newest}/${name}`);
    const tree = names.findIndex(name => name.startsWith(`${newest}/storage/`));
    assert.ok(at('SHA256SUMS') >= 0 && at('SHA256SUMS') < at('SHA256SUMS.hmac') && at('SHA256SUMS.hmac') < at('database.dump'), names.join('\n'));
    assert.ok(at('database.dump') < at('storage.manifest') && at('storage.manifest') < tree, 'small files, then the manifest, then the tree');
    assert.ok(names.includes(`${newest}/storage/stub/stub/documents/a.pdf/v1`), 'the stored files are in the archive');
    assert.deepEqual(readdirSync(f.dest).filter(n => n.endsWith('.partial')), [], 'no partial file left');
    assert.equal(readFileSync(join(f.drive, 'holiday-photos.zip'), 'utf8'), 'not ours');
    assert.match(f.dockerCalls(), /^run -d /m, 'restore verification ran on the copy from the drive');
    assert.match(result.stdout, /copied=1 already-present=0 failed=0 pruned=0/);
    assert.match(result.stdout, /encrypted with the backup key/);
    assert.match(f.last(), /^result=ok$/m);
    assert.match(f.last(), new RegExp(`^drive_uuid=${UUID}$`, 'm'));
    const report = readFileSync(join(f.dest, 'LAST-RESULT.txt'), 'utf8');
    assert.match(report, /result=ok[\s\S]*encrypted with the backup key[\s\S]*keeps the newest 3 valid archives/);
    assert.doesNotMatch(report, /These archives are NOT encrypted/);
    assert.equal(statSync(join(f.state, 'config/usb-backup.last')).mode & 0o077, 0, 'result file is private');
    assert.equal(readdirSync(f.state).filter(n => n.startsWith('.usb-verify')).length, 0, 'verify directory removed');
    assert.doesNotMatch(f.calls(), /^(mount|umount) /m, 'run never mounts or unmounts');

    const before = statSync(archive).mtimeMs;
    const again = f.run(['run', '--device', 'sdb1'], f.verifyEnv());
    assert.equal(again.status, 0, again.stderr);
    assert.match(again.stdout, /copied=0 already-present=1 failed=0/);
    assert.equal(statSync(archive).mtimeMs, before, 'an existing archive is not rewritten');
  } finally { f.cleanup(); }
});

test('run refuses a drive that is not enrolled, not USB, not exFAT, read-only, unmounted or on the data device', () => {
  const cases = [
    ['not enrolled', f => {}, /not enrolled/],
    ['not usb', f => { f.enroll(); f.put('tran.sdb', 'sata\n'); }, /not on a USB drive/],
    ['not exfat', f => { f.enroll(); f.put('dev.sdb1', devRow({ fstype: 'ntfs' })); }, /not exFAT/],
    ['read-only', f => { f.enroll(); f.put('dev.sdb1', devRow({ ro: '1' })); }, /read-only/],
    ['not mounted', f => { f.enroll(); rmSync(join(f.fake, 'target.sdb1')); }, /is not mounted/],
    ['same device', f => { f.enroll(); f.put('majmin.mount', '8:2\n'); }, /same device as the operator data/],
    ['system disk name', f => { f.enroll(); }, /not a USB disk or partition name/, ['run', '--device', 'nvme0n1p1']],
  ];
  for (const [label, arrange, pattern, args = ['run', '--device', 'sdb1']] of cases) {
    const f = fixture('warehouse-usb-refuse-');
    try {
      f.backups();
      arrange(f);
      const result = f.run(args, f.verifyEnv());
      assert.equal(result.status, 1, `${label}: ${result.stdout}`);
      assert.match(result.stderr, pattern, label);
      assert.equal(existsSync(f.dest), false, `${label}: nothing written to the drive`);
      if (label !== 'system disk name') assert.match(f.last(), /^result=failed$/m, `${label}: failure recorded`);
    } finally { f.cleanup(); }
  }
});

test('run refuses to run as root and refuses another instance\'s folder', () => {
  const f = fixture('warehouse-usb-root-');
  try {
    f.enroll(); f.backups();
    const root = f.run(['run', '--device', 'sdb1'], { FAKE_UID: '0' });
    assert.equal(root.status, 1);
    assert.match(root.stderr, /never as root/);
    mkdirSync(f.dest, { recursive: true });
    writeFileSync(join(f.dest, '.instance-id'), 'another-instance\n');
    const other = f.run(['run', '--device', 'sdb1'], f.verifyEnv());
    assert.equal(other.status, 1);
    assert.match(other.stderr, /belongs to a different instance/);
    assert.deepEqual(readdirSync(f.dest).filter(n => n.endsWith('.tar')), []);
  } finally { f.cleanup(); }
});

test('run never overwrites a corrupt archive, skips a tampered source and removes leftover partial files', () => {
  const f = fixture('warehouse-usb-corrupt-');
  try {
    f.enroll();
    const [, second] = f.backups(2);
    assert.equal(f.run(['run', '--device', 'sdb1'], f.verifyEnv()).status, 0);
    const archive = join(f.dest, `${second}.tar.enc`);
    assert.ok(existsSync(archive));
    writeFileSync(archive, 'damaged');
    writeFileSync(join(f.dest, '.warehouse-old.tar.partial'), 'interrupted');
    const tampered = f.bname(9);
    f.localBackup(tampered);
    writeFileSync(join(f.state, 'backups', tampered, 'database.dump'), 'tampered');
    const result = f.run(['run', '--device', 'sdb1'], f.verifyEnv());
    assert.equal(result.status, 1);
    // The newest backup fails its own check, so the next older one is tried: its archive is on the drive and damaged.
    assert.match(result.stderr, new RegExp(`source backup ${tampered} fails its checksums or signature, nothing copied`));
    assert.match(result.stderr, new RegExp(`archive of ${second} on the drive does not match its checksum or signature; it was not overwritten`));
    assert.match(result.stderr, new RegExp(`restore verification of ${second} from the drive failed`));
    assert.equal(readFileSync(archive, 'utf8'), 'damaged');
    assert.equal(existsSync(join(f.dest, `${tampered}.tar.enc`)), false);
    assert.equal(existsSync(join(f.dest, '.warehouse-old.tar.partial')), false, 'leftover removed under the lock');
    assert.match(result.stdout, /already-present=0 failed=3/);
    assert.match(f.last(), /^result=failed$/m);
    assert.match(f.last(), /^last_success_epoch=\d+$/m, 'the earlier success is kept');
  } finally { f.cleanup(); }
});

test('run takes a fresh backup first and still copies the newest existing backup when it fails', () => {
  const f = fixture('warehouse-usb-fresh-');
  try {
    f.enroll();
    const [first] = f.backups(1);
    // Stand-in for scripts/backup.sh: copies the fixture backup under a new name.
    writeFileSync(join(f.root, 'scripts/backup.sh'), `#!/usr/bin/env bash
set -e
[ "$FAKE_BACKUP_FAIL" = yes ] && { echo 'backup failed' >&2; exit 1; }
cp -a "$WAREHOUSE_STATE_DIR/backups/${first}" "$WAREHOUSE_STATE_DIR/backups/${f.bname(2)}"
`, { mode: 0o755 });
    const ok = f.run(['run', '--device', 'sdb1'], { ...f.verifyEnv(), WAREHOUSE_USB_BACKUP_FRESH: 'yes' });
    assert.equal(ok.status, 0, ok.stderr);
    assert.match(ok.stdout, /Taking a fresh backup/);
    assert.deepEqual(f.archives(), [`${f.bname(2)}.tar.enc`], 'the fresh backup was copied, and only it');

    const failed = f.run(['run', '--device', 'sdb1'], { ...f.verifyEnv(), WAREHOUSE_USB_BACKUP_FRESH: 'yes', FAKE_BACKUP_FAIL: 'yes' });
    assert.equal(failed.status, 1);
    assert.match(failed.stderr, /fresh backup failed; existing backups are still copied/);
    assert.match(failed.stdout, /already-present=1 failed=1/);
    assert.match(f.last(), /^result=failed$/m);
  } finally { f.cleanup(); }
});

test('run takes a fresh backup only when the newest verified backup is 20 hours old or more, and copies a verified one, not a newer unverified one', () => {
  const f = fixture('warehouse-usb-freshage-');
  try {
    f.enroll();
    const stamp = hours => new Date(Date.now() - hours * 3600e3).toISOString().replace(/[-:]/g, '').replace(/\.\d+Z$/, 'Z');
    const calls = join(f.scratch, 'backup-calls');
    writeFileSync(join(f.root, 'scripts/backup.sh'), `#!/usr/bin/env bash\necho called >> "${calls}"\n`, { mode: 0o755 });
    const old = `warehouse-${stamp(30)}`, recent = `warehouse-${stamp(5)}`;
    f.localBackup(old); f.localBackup(recent);
    const fresh = { ...f.verifyEnv(), WAREHOUSE_USB_BACKUP_FRESH: 'yes' };
    // Without a verified list the newest signed backup counts as verified: it is 5 hours old, so no stop window is spent.
    let result = f.run(['run', '--device', 'sdb1'], fresh);
    assert.equal(result.status, 0, result.stderr + result.stdout);
    assert.equal(existsSync(calls), false, 'no fresh backup');
    assert.match(result.stdout, /newest verified backup \(warehouse-\d{8}T\d{6}Z\) is 5 hours old; no fresh backup is taken/);
    assert.deepEqual(f.archives(), [`${recent}.tar.enc`]);
    // The daily check verified only the 30-hour-old backup: the newer one is not verified, so a fresh backup is due (the stand-in
    // makes none) and then the newest signed backup, which has not been verified by anyone, is the one copied.
    writeFileSync(join(f.state, 'config/backups-verified.list'), `${old} 1\n`);
    result = f.run(['run', '--device', 'sdb1'], fresh);
    assert.equal(result.status, 0, result.stderr + result.stdout);
    assert.equal(readFileSync(calls, 'utf8'), 'called\n', 'a fresh backup was taken');
    assert.match(result.stdout, /Taking a fresh backup/);
  } finally { f.cleanup(); }
  // Without a fresh backup the verified list decides which backup is copied: the newest verified one, not a newer unverified one.
  const g = fixture('warehouse-usb-verified-');
  try {
    g.enroll();
    const names = g.backups(3);
    writeFileSync(join(g.state, 'config/backups-verified.list'), `${names[0]} 1\n${names[1]} 2\nwarehouse-20250101T000000Z 3\n`);
    const result = g.run(['run', '--device', 'sdb1'], g.verifyEnv());
    assert.equal(result.status, 0, result.stderr + result.stdout);
    assert.deepEqual(g.archives(), [`${names[1]}.tar.enc`], 'the newest verified backup that still exists');
  } finally { g.cleanup(); }
});

test('run waits for the operator lock and records a failure when it stays busy', () => {
  const f = fixture('warehouse-usb-lock-');
  let holder;
  try {
    f.enroll(); f.backups();
    const lockfile = join(f.state, 'config/operator.lock');
    holder = spawn('flock', [lockfile, 'sleep', '30'], { stdio: 'ignore', detached: true });
    for (let i = 0; i < 100 && spawnSync('flock', ['-n', lockfile, 'true']).status === 0; i += 1) pause(50);
    const result = f.run(['run', '--device', 'sdb1'], { ...f.verifyEnv(), WAREHOUSE_USB_BACKUP_FRESH: 'yes' });
    assert.equal(result.status, 1);
    assert.match(result.stderr, /held the lock for 1s; no fresh backup was taken/);
    assert.match(result.stderr, /held the lock for 1s; nothing was copied/);
    assert.equal(existsSync(f.dest), false);
    assert.match(f.last(), /^result=failed$/m);
  } finally {
    if (holder) { try { process.kill(-holder.pid, 'SIGKILL'); } catch { /* already gone */ } }
    f.cleanup();
  }
});

test('setup is root-only through sudo and installs the helper, units, rule and configuration', () => {
  const f = fixture('warehouse-usb-setup-');
  try {
    const user = f.run(['setup', '--state', f.state]);
    assert.equal(user.status, 1);
    assert.match(user.stderr, /needs root/);
    const noSudo = f.asRoot(['setup', '--state', f.state], { SUDO_UID: '' });
    assert.equal(noSudo.status, 1);
    assert.match(noSudo.stderr, /through sudo/);
    const otherOwner = f.asRoot(['setup', '--state', f.state], { SUDO_UID: '54321' });
    assert.equal(otherOwner.status, 1);
    assert.match(otherOwner.stderr, /not owned by/);
    assert.equal(existsSync(join(f.etc, 'warehouse-usb-backup.conf')), false, 'nothing installed by a refused setup');

    const result = f.asRoot(['setup', '--state', f.state, '--enroll', '/dev/sdb1']);
    assert.equal(result.status, 0, result.stderr + result.stdout);
    const helper = join(f.libexec, 'warehouse-usb-backup');
    assert.equal(readFileSync(helper, 'utf8'), readFileSync(join(f.root, 'scripts/backup-usb.sh'), 'utf8'));
    assert.equal(statSync(helper).mode & 0o777, 0o755);
    // Directories setup creates stay world-readable despite umask 077 (a 0700
    // /usr/local/libexec broke every Docker CLI plugin on the host).
    for (const dir of [f.libexec, join(f.etc, 'systemd/system'), join(f.etc, 'udev/rules.d')]) {
      assert.equal(statSync(dir).mode & 0o777, 0o755, dir);
    }
    assert.match(f.calls(), new RegExp(`^chown root:root ${helper}$`, 'm'));
    const conf = readFileSync(join(f.etc, 'warehouse-usb-backup.conf'), 'utf8');
    assert.match(conf, new RegExp(`^STATE=${f.state}$`, 'm'));
    assert.match(conf, /^FRESH_BACKUP=yes$/m);
    const unit = readFileSync(join(f.etc, 'systemd/system/warehouse-usb-backup@.service'), 'utf8');
    assert.match(unit, /^User=installer$/m);
    assert.match(unit, new RegExp(`^ExecStartPre=\\+${helper} mount %I$`, 'm'));
    assert.match(unit, new RegExp(`^ExecStart=/bin/bash ${f.root}/scripts/backup-usb.sh run --device %I$`, 'm'));
    assert.match(unit, new RegExp(`^ExecStopPost=\\+${helper} unmount %I$`, 'm'));
    assert.match(unit, new RegExp(`^Environment=WAREHOUSE_STATE_DIR=${f.state}$`, 'm'));
    const rule = readFileSync(join(f.etc, 'udev/rules.d/90-warehouse-usb-backup.rules'), 'utf8');
    assert.match(rule, new RegExp(`ENV\\{ID_FS_UUID\\}=="${UUID}".*SYSTEMD_WANTS\\}\\+="warehouse-usb-backup@%k\\.service"`));
    assert.match(rule, /ENV\{ID_BUS\}=="usb", ENV\{ID_FS_TYPE\}=="exfat"/);
    const drives = join(f.etc, 'warehouse-usb-backup.drives');
    assert.equal(readFileSync(drives, 'utf8'), `${UUID} ${PART}\n`, 'the list binds the filesystem UUID to the partition UUID');
    assert.equal(statSync(drives).mode & 0o777, 0o600, 'the enrolment list is not world-readable');
    assert.match(f.calls(), new RegExp(`^chown root:root ${drives}`, 'm'));
    assert.equal(readFileSync(f.markerPath, 'utf8'), marker(), 'the drive carries the marker signed with the backup key');
    assert.doesNotMatch(f.calls(), /^(mount|umount) /m, 'the existing mount was used to write the marker');
    assert.match(conf, /^ENCRYPT=yes\nENCRYPT_SET=default\nKEEP=3$/m, 'encrypted by default, 3 archives kept');
    assert.match(unit, /^Environment=WAREHOUSE_BACKUP_ENCRYPT=1$/m);
    assert.match(unit, /^Environment=WAREHOUSE_USB_KEEP=3$/m);
    assert.match(result.stdout, /Archives are encrypted with the backup key/);
    assert.doesNotMatch(result.stdout, /NOTICE/, 'a new installation has nothing to be told about');
    assert.match(f.calls(), /^systemctl daemon-reload$/m);
    assert.match(f.calls(), /^udevadm control --reload-rules$/m);
    assert.match(f.calls(), /^systemctl disable --now warehouse-usb-backup\.timer$/m);

    const daily = f.asRoot(['setup', '--state', f.state, '--daily', '--no-fresh-backup']);
    assert.equal(daily.status, 0, daily.stderr);
    assert.match(f.calls(), /^systemctl enable --now warehouse-usb-backup\.timer$/m);
    assert.match(readFileSync(join(f.etc, 'warehouse-usb-backup.conf'), 'utf8'), /^FRESH_BACKUP=no$/m);
    assert.equal(readFileSync(drives, 'utf8'), `${UUID} ${PART}\n`, 'enrolment survives a rerun');
    const encrypted = f.asRoot(['setup', '--state', f.state, '--encrypt']);
    assert.equal(encrypted.status, 0, encrypted.stderr);
    assert.match(readFileSync(join(f.etc, 'warehouse-usb-backup.conf'), 'utf8'), /^ENCRYPT=yes$/m);
    assert.match(readFileSync(join(f.etc, 'systemd/system/warehouse-usb-backup@.service'), 'utf8'), /^Environment=WAREHOUSE_BACKUP_ENCRYPT=1$/m);
    assert.match(encrypted.stdout, /cannot be restored after the host is lost/);
    assert.match(readFileSync(join(f.etc, 'warehouse-usb-backup.conf'), 'utf8'), /^ENCRYPT_SET=typed$/m);

    const other = f.asRoot(['setup', '--state', f.root]);
    assert.equal(other.status, 1);
    assert.match(other.stderr, /not an installed operator state|already set up/);
  } finally { f.cleanup(); }
});

test('setup refuses a writable script, enroll refuses unsuitable drives and does not duplicate', () => {
  const f = fixture('warehouse-usb-enroll-');
  try {
    chmodSync(join(f.root, 'scripts/backup-usb.sh'), 0o775);
    const writable = f.asRoot(['setup', '--state', f.state]);
    assert.equal(writable.status, 1);
    assert.match(writable.stderr, /group- or world-writable/);
    assert.match(writable.stderr, /checkout-permissions\.sh/);
    chmodSync(join(f.root, 'scripts/backup-usb.sh'), 0o755);
    assert.equal(f.asRoot(['setup', '--state', f.state]).status, 0);
    f.put('tran.sdb', 'sata\n');
    const sata = f.asRoot(['enroll', '--device', '/dev/sdb1']);
    assert.equal(sata.status, 1);
    assert.match(sata.stderr, /not on a USB drive/);
    f.put('tran.sdb', 'usb\n');
    assert.equal(f.asRoot(['enroll', '--device', '/dev/sdb1']).status, 0);
    rmSync(f.markerPath);
    const again = f.asRoot(['enroll', '--device', 'sdb1']);
    assert.equal(again.status, 0);
    assert.equal(readFileSync(join(f.etc, 'warehouse-usb-backup.drives'), 'utf8'), `${UUID} ${PART}\n`, 'one line per drive');
    assert.equal(readFileSync(f.markerPath, 'utf8'), marker(), 'enrolling again rewrites the marker');
    assert.equal(f.run(['enroll', '--device', 'sdb1']).status, 1, 'enroll needs root');
    // A drive that is not mounted is mounted privately for the marker and released again.
    rmSync(join(f.fake, 'target.sdb1'));
    const unmounted = f.asRoot(['enroll', '--device', 'sdb1']);
    assert.equal(unmounted.status, 0, unmounted.stderr);
    assert.match(f.calls(), new RegExp(`^mount -t exfat -o nosuid,nodev,noexec,uid=\\d+,gid=\\d+,fmask=0177,dmask=0077,errors=remount-ro /dev/sdb1 ${f.runDir}/sdb1$`, 'm'));
    assert.match(f.calls(), new RegExp(`^umount -- ${f.runDir}/sdb1$`, 'm'));
    assert.match(readFileSync(join(f.runDir, 'sdb1/warehouse-backups/.drive-enrolment'), 'utf8'), /^hmac=[0-9a-f]{64}$/m);
    // A drive that cannot be written is released again and is not enrolled.
    rmSync(join(f.runDir, 'sdb1/warehouse-backups'), { recursive: true });
    writeFileSync(join(f.runDir, 'sdb1/warehouse-backups'), 'a file where the folder should be');
    writeFileSync(join(f.etc, 'warehouse-usb-backup.drives'), '');
    writeFileSync(join(f.scratch, 'tools.log'), '');
    const unwritable = f.asRoot(['enroll', '--device', 'sdb1']);
    assert.equal(unwritable.status, 1);
    assert.match(unwritable.stderr, /Could not write the enrolment marker onto \/dev\/sdb1; the drive was not enrolled/);
    assert.match(f.calls(), new RegExp(`^umount -- ${f.runDir}/sdb1$`, 'm'), 'the private mount is released');
    assert.equal(readFileSync(join(f.etc, 'warehouse-usb-backup.drives'), 'utf8'), '');
    rmSync(join(f.runDir, 'sdb1'), { recursive: true, force: true });
    // Without the backup key there is nothing to sign the marker with.
    rmSync(join(f.state, 'config/backup.key'));
    const noKey = f.asRoot(['enroll', '--device', 'sdb1']);
    assert.equal(noKey.status, 1);
    assert.match(noKey.stderr, /backup key .* does not exist yet/);
  } finally { f.cleanup(); }
});

test('mount uses an existing desktop mount or mounts privately; unmount releases an enrolled drive', () => {
  const f = fixture('warehouse-usb-mount-');
  try {
    f.enroll();
    writeFileSync(join(f.etc, 'warehouse-usb-backup.conf'), `STATE=${f.state}\nUID=1000\nGID=1000\n`);
    const existing = f.asRoot(['mount', 'sdb1']);
    assert.equal(existing.status, 0, existing.stderr);
    assert.match(existing.stdout, /Using the existing mount/);
    assert.doesNotMatch(f.calls(), /^mount /m);

    rmSync(join(f.fake, 'target.sdb1'));
    const fresh = f.asRoot(['mount', 'sdb1']);
    assert.equal(fresh.status, 0, fresh.stderr);
    assert.match(f.calls(), new RegExp(`^mount -t exfat -o nosuid,nodev,noexec,uid=1000,gid=1000,fmask=0177,dmask=0077,errors=remount-ro /dev/sdb1 ${f.runDir}/sdb1$`, 'm'));

    f.put('target.sdb1', `${f.drive}\n${f.runDir}/sdb1\n`);
    const out = f.asRoot(['unmount', 'sdb1']);
    assert.equal(out.status, 0, out.stderr);
    assert.match(f.calls(), new RegExp(`^umount -- ${f.drive}$`, 'm'));
    assert.match(f.calls(), new RegExp(`^umount -- ${f.runDir}/sdb1$`, 'm'));
    assert.match(out.stdout, /safe to remove the drive/);

    assert.equal(f.run(['mount', 'sdb1']).status, 1, 'mount needs root');
  } finally { f.cleanup(); }
});

test('mount refuses a drive that is not enrolled, and unmount then leaves its other mounts alone', () => {
  const f = fixture('warehouse-usb-stranger-');
  try {
    writeFileSync(join(f.etc, 'warehouse-usb-backup.conf'), `STATE=${f.state}\nUID=1000\nGID=1000\n`);
    rmSync(join(f.fake, 'target.sdb1'));
    const m = f.asRoot(['mount', 'sdb1']);
    assert.equal(m.status, 1);
    assert.match(m.stderr, /not enrolled; nothing mounted/);
    f.put('target.sdb1', `${f.drive}\n`);
    const u = f.asRoot(['unmount', 'sdb1']);
    assert.equal(u.status, 0, u.stderr);
    assert.doesNotMatch(f.calls(), /^(mount|umount) /m);
  } finally { f.cleanup(); }
});

test('scan starts a backup for each attached enrolled drive; uninstall removes everything it installed', () => {
  const f = fixture('warehouse-usb-scan-');
  try {
    assert.equal(f.asRoot(['setup', '--state', f.state, '--enroll', 'sdb1']).status, 0);
    const scan = f.asRoot(['scan']);
    assert.equal(scan.status, 0, scan.stderr);
    assert.match(f.calls(), /^systemctl start --no-block warehouse-usb-backup@sdb1\.service$/m);
    f.put('uuids', 'sda2 210f776f\n');
    assert.match(f.asRoot(['scan']).stdout, /No enrolled drive is attached/);

    const status = f.run(['status']);
    assert.equal(status.status, 0, status.stderr);
    assert.match(status.stdout, /Test override in effect/);
    assert.match(status.stdout, new RegExp(`Enrolled drive ${UUID}: not attached`));
    assert.match(status.stdout, /No copy has been made yet/);

    const gone = f.asRoot(['uninstall']);
    assert.equal(gone.status, 0, gone.stderr);
    for (const path of ['warehouse-usb-backup.conf', 'warehouse-usb-backup.drives', 'udev/rules.d/90-warehouse-usb-backup.rules',
      'systemd/system/warehouse-usb-backup@.service', 'systemd/system/warehouse-usb-backup.timer']) assert.equal(existsSync(join(f.etc, path)), false, path);
    assert.equal(existsSync(join(f.libexec, 'warehouse-usb-backup')), false);
    assert.match(f.run(['status']).stdout, /not set up/);
  } finally { f.cleanup(); }
});

test('doctor warning covers not set up, never copied, failed and stale USB backups', () => {
  const scratch = mkdtempSync(join(tmpdir(), 'warehouse-usb-doctor-'));
  try {
    const state = join(scratch, 'state'); mkdirSync(join(state, 'config'), { recursive: true });
    const etc = join(scratch, 'etc'); mkdirSync(etc);
    const now = Date.UTC(2026, 9, 9);
    assert.equal(usbBackupWarning(state, { etc, now }), null, 'not set up: no warning');
    writeFileSync(join(etc, 'warehouse-usb-backup.conf'), `STATE=${state}\n`);
    assert.match(usbBackupWarning(state, { etc, now }), /no copy has been made yet/);
    const last = (result, days) => writeFileSync(join(state, 'config/usb-backup.last'),
      `result=${result}\nfinished_utc=x\nlast_success_epoch=${Math.floor(now / 1000) - days * 86400}\nmessage=disk full\n`);
    last('ok', 1);
    assert.equal(usbBackupWarning(state, { etc, now, maxAgeDays: 7 }), null);
    last('ok', 9);
    assert.match(usbBackupWarning(state, { etc, now, maxAgeDays: 7 }), /9 days old/);
    last('failed', 0);
    assert.match(usbBackupWarning(state, { etc, now }), /failed at x: disk full/);
  } finally { rmSync(scratch, { recursive: true, force: true }); }
});

test('run copies nothing to a drive that only imitates an enrolled drive', () => {
  // The exFAT volume serial is 32 bits and can be set when formatting; it no longer enrols a drive.
  const cases = [
    ['same serial, no marker', f => { writeFileSync(join(f.etc, 'warehouse-usb-backup.drives'), `${UUID} ${PART}\n`); }],
    ['marker copied from the enrolled drive onto another partition', f => { f.enroll(); f.put('dev.sdb1', devRow({ part: 'ffffffff-01' })); }],
    ['marker for another filesystem', f => { f.enroll(); f.writeMarker({ uuid: 'AAAA-BBBB' }); }],
    ['marker of another instance', f => { f.enroll(); f.writeMarker({ instance: '11111111-1111-4111-8111-111111111111' }); }],
    ['marker signed with another key', f => { f.enroll(); f.writeMarker({ key: 'd4'.repeat(32) }); }],
    ['marker with the signature cut off', f => { f.enroll(); writeFileSync(f.markerPath, marker().replace(/^hmac=.*$/m, 'hmac=')); }],
    ['installation without a backup key', f => { f.enroll(); rmSync(join(f.state, 'config/backup.key')); }],
  ];
  for (const [label, arrange] of cases) {
    const f = fixture('warehouse-usb-forged-');
    try {
      f.backups();
      writeFileSync(join(f.root, 'scripts/backup.sh'), '#!/usr/bin/env bash\necho called >> "$WAREHOUSE_STATE_DIR/backup-called"\n', { mode: 0o755 });
      arrange(f);
      const result = f.run(['run', '--device', 'sdb1'], { ...f.verifyEnv(), WAREHOUSE_USB_BACKUP_FRESH: 'yes' });
      assert.equal(result.status, 1, `${label}: ${result.stdout}`);
      assert.match(result.stderr, /is not enrolled for this installation \(no valid enrolment marker for this drive\); nothing was copied/, label);
      assert.equal(existsSync(f.dest), false, `${label}: no archive folder was created`);
      assert.equal(existsSync(join(f.state, 'backup-called')), false, `${label}: no backup was taken for it`);
      assert.equal(f.dockerCalls(), '', `${label}: docker was not used`);
      assert.match(f.last(), /^result=failed$/m, label);
    } finally { f.cleanup(); }
  }
});

test('mount refuses a drive enrolled by serial only or with another partition UUID', () => {
  const f = fixture('warehouse-usb-mount-old-');
  try {
    writeFileSync(join(f.etc, 'warehouse-usb-backup.conf'), `STATE=${f.state}\nUID=1000\nGID=1000\n`);
    rmSync(join(f.fake, 'target.sdb1'));
    writeFileSync(join(f.etc, 'warehouse-usb-backup.drives'), `${UUID}\n`);
    const old = f.asRoot(['mount', 'sdb1']);
    assert.equal(old.status, 1);
    assert.match(old.stderr, /enrolled by an earlier release, by its volume serial only\. Enroll it again/);
    writeFileSync(join(f.etc, 'warehouse-usb-backup.drives'), `${UUID} 99999999-01\n`);
    const other = f.asRoot(['mount', 'sdb1']);
    assert.equal(other.status, 1);
    assert.match(other.stderr, /not enrolled; nothing mounted/);
    assert.doesNotMatch(f.calls(), /^mount /m);
    assert.match(f.run(['status']).stdout, /not set up|Enrolled drive/);
  } finally { f.cleanup(); }
});

test('run with --no-encrypt typed (WAREHOUSE_BACKUP_ENCRYPT=0) writes readable signed archives and needs no key copy confirmation', () => {
  const f = fixture('warehouse-usb-plain-', { escrow: false });
  try {
    f.enroll();
    const [, newest] = f.backups(2);
    const result = f.run(['run', '--device', 'sdb1'], { ...f.verifyEnv(), ...PLAIN });
    assert.equal(result.status, 0, result.stderr + result.stdout);
    assert.deepEqual(f.archives(), [`${newest}.tar`]);
    const archive = join(f.dest, `${newest}.tar`);
    assert.equal(spawnSync('sha256sum', ['-c', '--quiet', `${newest}.tar.sha256`], { cwd: f.dest }).status, 0);
    assert.equal(readFileSync(`${archive}.hmac`, 'utf8'), `warehouse-backup-hmac-v1 ${hmacHex(backupKey, 'warehouse-backup-archive-v1', readFileSync(`${archive}.sha256`))}\n`);
    assert.match(listing(f, archive), /^-rw------- .*compose\.env$/m);
    assert.match(result.stdout, /WARNING: the archives are not encrypted and contain every credential/);
    assert.match(readFileSync(join(f.dest, 'LAST-RESULT.txt'), 'utf8'), /result=ok[\s\S]*NOT encrypted/);
    assert.match(f.dockerCalls(), /^run -d /m, 'restore verification ran on the readable copy');
  } finally { f.cleanup(); }
});

test('run copies nothing when no local backup is signed, and says so', () => {
  const f = fixture('warehouse-usb-unsigned-');
  try {
    f.enroll();
    makeBackup(join(f.state, 'backups', 'warehouse-20251201T000000Z'), { env: composeEnv(f.state), key: null });
    const result = f.run(['run', '--device', 'sdb1'], f.verifyEnv());
    assert.equal(result.status, 1);
    assert.deepEqual(f.archives(), []);
    assert.match(result.stderr, /there is no verified or signed backup to copy; take one with npm run db:backup/);
    assert.equal(f.dockerCalls(), '', 'no restore verification ran');
  } finally { f.cleanup(); }
});

test('setup run again without options keeps what was typed, the daily timer and the fresh-backup choice', () => {
  const f = fixture('warehouse-usb-rerun-');
  const conf = () => readFileSync(join(f.etc, 'warehouse-usb-backup.conf'), 'utf8');
  const unit = () => readFileSync(join(f.etc, 'systemd/system/warehouse-usb-backup@.service'), 'utf8');
  try {
    assert.equal(f.asRoot(['setup', '--state', f.state, '--encrypt', '--daily', '--no-fresh-backup']).status, 0);
    assert.match(conf(), /^FRESH_BACKUP=no\nDAILY=yes\nENCRYPT=yes\nENCRYPT_SET=typed\nKEEP=3$/m);
    // The documented upgrade step: setup again with nothing but the state.
    writeFileSync(join(f.scratch, 'tools.log'), '');
    const again = f.asRoot(['setup', '--state', f.state]);
    assert.equal(again.status, 0, again.stderr);
    assert.match(conf(), /^FRESH_BACKUP=no\nDAILY=yes\nENCRYPT=yes\nENCRYPT_SET=typed\nKEEP=3$/m, 'the stored choices survive');
    assert.match(unit(), /^Environment=WAREHOUSE_BACKUP_ENCRYPT=1$/m, 'archives stay encrypted');
    assert.match(unit(), /^Environment=WAREHOUSE_USB_BACKUP_FRESH=no$/m);
    assert.match(f.calls(), /^systemctl enable --now warehouse-usb-backup\.timer$/m);
    assert.doesNotMatch(f.calls(), /^systemctl disable/m, 'the daily timer is not switched off');
    assert.match(again.stdout, /fresh backup on attach: no, daily timer: yes, encrypted archives: yes/);
    // Each choice is switched back only by naming it; a typed --no-encrypt then survives a plain rerun.
    const off = f.asRoot(['setup', '--state', f.state, '--no-encrypt', '--no-daily', '--fresh-backup', '--keep', '5']);
    assert.equal(off.status, 0, off.stderr);
    assert.match(conf(), /^FRESH_BACKUP=yes\nDAILY=no\nENCRYPT=no\nENCRYPT_SET=typed\nKEEP=5$/m);
    assert.match(unit(), /^Environment=WAREHOUSE_BACKUP_ENCRYPT=0$/m);
    assert.match(unit(), /^Environment=WAREHOUSE_USB_KEEP=5$/m);
    assert.match(f.calls(), /^systemctl disable --now warehouse-usb-backup\.timer$/m);
    assert.match(off.stdout, /Archives are NOT encrypted \(you typed --no-encrypt\)/);
    const rerun = f.asRoot(['setup', '--state', f.state]);
    assert.equal(rerun.status, 0, rerun.stderr);
    assert.match(conf(), /^ENCRYPT=no\nENCRYPT_SET=typed\nKEEP=5$/m, 'a typed --no-encrypt is kept');
    assert.doesNotMatch(rerun.stdout, /NOTICE/);
    // A configuration written before the encryption setting existed has no ENCRYPT line: the default, encrypted, applies.
    writeFileSync(join(f.etc, 'warehouse-usb-backup.conf'), `STATE=${f.state}\nFRESH_BACKUP=no\nDAILY=yes\n`);
    assert.equal(f.asRoot(['setup', '--state', f.state]).status, 0);
    assert.match(conf(), /^FRESH_BACKUP=no\nDAILY=yes\nENCRYPT=yes\nENCRYPT_SET=default\nKEEP=3$/m);
  } finally { f.cleanup(); }
});

test('a drive refused at the mount step is recorded as a failed run that status and doctor report at once', () => {
  const f = fixture('warehouse-usb-refusal-');
  try {
    const drives = join(f.etc, 'warehouse-usb-backup.drives');
    const confLine = `STATE=${f.state}\nUID=1000\nGID=1000\n`;
    writeFileSync(join(f.etc, 'warehouse-usb-backup.conf'), confLine);
    // The last run before the upgrade succeeded yesterday.
    const yesterday = Math.floor(Date.now() / 1000) - 86400;
    writeFileSync(join(f.state, 'config/usb-backup.last'), `result=ok\nfinished_utc=2026-01-01T00:00:00Z\nlast_success_epoch=${yesterday}\nmessage=copied 1\n`);
    assert.equal(usbBackupWarning(f.state, { etc: f.etc }), null, 'no warning before the refusal');
    rmSync(join(f.fake, 'target.sdb1'));
    writeFileSync(drives, `${UUID}\n`);
    const old = f.asRoot(['mount', 'sdb1']);
    assert.equal(old.status, 1);
    assert.match(old.stderr, /enrolled by an earlier release/);
    assert.match(f.calls(), /^setpriv reuid=1000$/m, 'the record is written as the installation user, not as root');
    assert.match(f.last(), /^result=failed$/m);
    assert.match(f.last(), new RegExp(`^message=Drive ${UUID} \\(/dev/sdb1\\) was enrolled by an earlier release.*Enroll it again: sudo bash scripts/backup-usb\\.sh enroll --device /dev/sdb1$`, 'm'));
    assert.match(f.last(), new RegExp(`^last_success_epoch=${yesterday}$`, 'm'), 'the earlier success is kept');
    assert.match(f.last(), new RegExp(`^drive_uuid=${UUID}\\ndevice=/dev/sdb1$`, 'm'));
    assert.match(usbBackupWarning(f.state, { etc: f.etc }), /The last USB backup failed at .*enrolled by an earlier release.*Enroll it again/);
    assert.match(f.run(['status']).stdout, /Last run: failed at .*enrolled by an earlier release/);
    assert.doesNotMatch(f.calls(), /^mount /m);
    // The same serial on another partition is refused and recorded too.
    rmSync(join(f.state, 'config/usb-backup.last'));
    writeFileSync(drives, `${UUID} 99999999-01\n`);
    assert.equal(f.asRoot(['mount', 'sdb1']).status, 1);
    assert.match(f.last(), /^message=Drive .* is not enrolled; nothing mounted\..*another partition/m);
    // A drive this installation never heard of leaves no record.
    rmSync(join(f.state, 'config/usb-backup.last'));
    writeFileSync(drives, 'FFFF-0000 a1b2c3d4-01\n');
    assert.equal(f.asRoot(['mount', 'sdb1']).status, 1);
    assert.equal(existsSync(join(f.state, 'config/usb-backup.last')), false);
    // The internal step refuses to write as root.
    const asRoot = f.asRoot(['refused', 'sdb1', UUID, 'text']);
    assert.equal(asRoot.status, 1); assert.match(asRoot.stderr, /never as root/);
  } finally { f.cleanup(); }
});

test('setup after an upgrade says which drives must be enrolled again and records it for doctor', () => {
  const f = fixture('warehouse-usb-upgrade-');
  try {
    assert.equal(f.asRoot(['setup', '--state', f.state]).status, 0);
    assert.equal(existsSync(join(f.state, 'config/usb-backup.last')), false, 'nothing is recorded for an installation without old drives');
    writeFileSync(join(f.etc, 'warehouse-usb-backup.drives'), `${UUID}\n`);
    const result = f.asRoot(['setup', '--state', f.state]);
    assert.equal(result.status, 0, result.stderr);
    assert.match(result.stdout, new RegExp(`WARNING: drive ${UUID} was enrolled by an earlier release[\\s\\S]*enroll --device /dev/sdX1`));
    assert.match(f.last(), /^result=failed$/m);
    assert.match(usbBackupWarning(f.state, { etc: f.etc }), /enrolled by an earlier release.*enroll/i);
    // Enrolling replaces the old line, and the next setup has nothing to warn about.
    assert.equal(f.asRoot(['enroll', '--device', 'sdb1']).status, 0);
    assert.doesNotMatch(f.asRoot(['setup', '--state', f.state]).stdout, /earlier release/);
  } finally { f.cleanup(); }
});

test('an archive signed with a replaced backup key is reported as such, apart from a damaged one', () => {
  const f = fixture('warehouse-usb-oldkey-');
  try {
    f.enroll();
    const [first, second] = f.backups(2);
    assert.equal(f.run(['run', '--device', 'sdb1'], f.verifyEnv()).status, 0);
    const archive = join(f.dest, `${second}.tar.enc`);
    // An older archive that carries the signature of the key in use before it was replaced is not this installation's any more:
    // reported, not counted, never deleted, and not a failure of the run.
    const oldArchive = join(f.dest, `${first}.tar.enc`);
    copyFileSync(archive, oldArchive);
    writeFileSync(`${oldArchive}.sha256`, readFileSync(`${archive}.sha256`, 'utf8').replace(second, first));
    const oldSignature = file => writeFileSync(`${file}.hmac`, `warehouse-backup-hmac-v1 ${hmacHex('d4'.repeat(32), 'warehouse-backup-archive-v1', readFileSync(`${file}.sha256`))}\n`);
    oldSignature(oldArchive);
    let result = f.run(['run', '--device', 'sdb1'], f.verifyEnv());
    assert.equal(result.status, 0, result.stderr + result.stdout);
    assert.match(result.stdout, new RegExp(`Not counted and not deleted \\(damaged, unsigned, or signed with another key\\): ${first}\\.tar\\.enc`));
    assert.ok(existsSync(oldArchive) && existsSync(`${oldArchive}.hmac`), 'never deleted');
    // The archive of the backup being copied carries such a signature: it is not overwritten and the run says what to do.
    oldSignature(archive);
    result = f.run(['run', '--device', 'sdb1'], f.verifyEnv());
    assert.equal(result.status, 1);
    assert.match(result.stderr, new RegExp(`archive of ${second} on the drive matches its checksum but was not signed with the current backup key.*move the archives written before`));
    assert.doesNotMatch(result.stderr, /does not match its checksum or signature/);
    assert.match(result.stderr, /carries no valid signature of this installation's backup key; it was not opened/);
  } finally { f.cleanup(); }
});

test('run never opens an archive without a valid signature, and still verifies the newest one it signed', () => {
  const f = fixture('warehouse-usb-planted-');
  try {
    f.enroll();
    const [genuine] = f.backups(1);
    assert.equal(f.run(['run', '--device', 'sdb1'], { ...f.verifyEnv(), ...PLAIN }).status, 0);
    // Someone with the drive adds a later-dated archive with a matching checksum and no signature.
    const planted = 'warehouse-99991231T000000Z';
    const tree = join(f.scratch, 'planted', planted); mkdirSync(tree, { recursive: true });
    writeFileSync(join(tree, 'SHA256SUMS'), 'planted\n');
    assert.equal(spawnSync('tar', ['-C', join(f.scratch, 'planted'), '-cf', join(f.dest, `${planted}.tar`), planted]).status, 0);
    writeFileSync(join(f.dest, `${planted}.tar.sha256`), spawnSync('sha256sum', [`${planted}.tar`], { cwd: f.dest, encoding: 'utf8' }).stdout);
    // The stand-in tar records every archive that is opened for extraction.
    const opened = join(f.scratch, 'tar-extractions.log'); writeFileSync(opened, '');
    const wrap = join(f.scratch, 'tarwrap'); mkdirSync(wrap);
    writeFileSync(join(wrap, 'tar'), `#!/bin/sh\ncase " $* " in *" -xf "*) printf '%s\\n' "$*" >> "${opened}" ;; esac\nexec /usr/bin/tar "$@"\n`, { mode: 0o755 });
    const result = f.run(['run', '--device', 'sdb1'], { ...f.verifyEnv(), ...PLAIN, PATH: `${wrap}:${join(f.scratch, 'shims')}:${join(f.scratch, 'dockerbin')}:${process.env.PATH}` });
    assert.equal(result.status, 1, 'the run reports the foreign archive');
    assert.match(result.stderr, new RegExp(`${planted}\\.tar on the drive carries no valid signature of this installation's backup key; it was not opened`));
    assert.doesNotMatch(readFileSync(opened, 'utf8'), /99991231/, 'the planted archive was never unpacked');
    assert.match(readFileSync(opened, 'utf8'), new RegExp(`${genuine}\\.tar`), 'the genuine archive was');
    assert.match(result.stdout, new RegExp(`Restore verification of the copy on the drive passed: ${genuine}`));
    assert.match(f.last(), /^result=failed$/m);
    assert.ok(existsSync(join(f.dest, `${planted}.tar`)), 'and it was not deleted');
  } finally { f.cleanup(); }
});

test('setup switches an installation set up before encryption became the default to encrypted archives, with a notice, and keeps a typed --no-encrypt', () => {
  const f = fixture('warehouse-usb-flip-');
  const conf = () => readFileSync(join(f.etc, 'warehouse-usb-backup.conf'), 'utf8');
  const unit = () => readFileSync(join(f.etc, 'systemd/system/warehouse-usb-backup@.service'), 'utf8');
  // The configuration the previous release wrote: no ENCRYPT_SET, ENCRYPT=no because that was the default.
  const previous = lines => writeFileSync(join(f.etc, 'warehouse-usb-backup.conf'),
    `STATE=${f.state}\nCHECKOUT=${f.root}\nUSER=installer\nUID=${process.getuid()}\nGID=${process.getgid()}\nFRESH_BACKUP=yes\nDAILY=no\n${lines}`);
  try {
    previous('ENCRYPT=no\n');
    const before = f.run(['status']);
    assert.match(before.stdout, /WARNING: archives are still written unencrypted, which was the default of earlier releases\. Run setup again/);
    const flipped = f.asRoot(['setup', '--state', f.state]);
    assert.equal(flipped.status, 0, flipped.stderr);
    assert.match(conf(), /^ENCRYPT=yes\nENCRYPT_SET=default$/m);
    assert.match(unit(), /^Environment=WAREHOUSE_BACKUP_ENCRYPT=1$/m);
    assert.match(flipped.stdout, /NOTICE: this installation had USB backup set up with unencrypted archives[\s\S]*switched them to encrypted ones[\s\S]*unencrypted archives on enrolled drives are deleted[\s\S]*--no-encrypt/);
    assert.doesNotMatch(f.run(['status']).stdout, /still written unencrypted/);
    // The notice is for the switch only.
    assert.doesNotMatch(f.asRoot(['setup', '--state', f.state]).stdout, /NOTICE/);
    // A `no` the operator typed is a choice, and stays.
    previous('ENCRYPT=no\nENCRYPT_SET=typed\n');
    const kept = f.asRoot(['setup', '--state', f.state]);
    assert.equal(kept.status, 0, kept.stderr);
    assert.match(conf(), /^ENCRYPT=no\nENCRYPT_SET=typed$/m);
    assert.match(unit(), /^Environment=WAREHOUSE_BACKUP_ENCRYPT=0$/m);
    assert.doesNotMatch(kept.stdout, /NOTICE/);
    // A `yes` stays a `yes`, typed or not.
    previous('ENCRYPT=yes\n');
    assert.equal(f.asRoot(['setup', '--state', f.state]).status, 0);
    assert.match(conf(), /^ENCRYPT=yes\nENCRYPT_SET=default$/m);
  } finally { f.cleanup(); }
});

test('the key copy must be confirmed before a drive is enrolled or an encrypted archive is written: refused without a record, with another key\'s record, and after the key changed', () => {
  const f = fixture('warehouse-usb-escrow-', { escrow: false });
  const record = join(f.state, 'config/backup-key.escrow');
  const drives = join(f.etc, 'warehouse-usb-backup.drives');
  const refusal = /backup key copy is not confirmed \(.*\)\. Archives on the drive are encrypted with the backup key[\s\S]*bash scripts\/backup-key-escrow\.sh show/;
  try {
    // setup --enroll stops before it installs anything.
    let result = f.asRoot(['setup', '--state', f.state, '--enroll', '/dev/sdb1']);
    assert.equal(result.status, 1);
    assert.match(result.stderr, refusal);
    assert.match(result.stderr, /there is no key escrow record/);
    assert.equal(existsSync(join(f.etc, 'warehouse-usb-backup.conf')), false, 'nothing installed by a refused setup');
    assert.equal(existsSync(drives), false);
    assert.equal(existsSync(f.markerPath), false, 'no marker on the drive');
    // setup alone installs, and tells what is missing; status says so too.
    result = f.asRoot(['setup', '--state', f.state]);
    assert.equal(result.status, 0, result.stderr);
    assert.match(result.stdout, /ACTION NEEDED: the backup key copy is not confirmed \(there is no key escrow record\)[\s\S]*backup-key-escrow\.sh show/);
    assert.match(f.run(['status']).stdout, /WARNING: the backup key copy is not confirmed[\s\S]*backup-key-escrow\.sh show/);
    // enroll is refused the same way, and leaves the list empty.
    result = f.asRoot(['enroll', '--device', 'sdb1']);
    assert.equal(result.status, 1);
    assert.match(result.stderr, refusal);
    assert.equal(readFileSync(drives, 'utf8'), '');
    assert.equal(existsSync(f.markerPath), false);
    // A record for another key (the key was replaced, or the record copied from another installation) is no confirmation.
    writeEscrow(f.state, 'd4'.repeat(32));
    result = f.asRoot(['enroll', '--device', 'sdb1']);
    assert.equal(result.status, 1);
    assert.match(result.stderr, /the key escrow record is for another backup key/);
    // A damaged record is not one either.
    writeFileSync(record, 'warehouse-backup-key-escrow-v1\nkey_fingerprint=nothex\n');
    assert.match(f.asRoot(['enroll', '--device', 'sdb1']).stderr, /the key escrow record has no key fingerprint/);
    // The matching record: the drive is enrolled.
    writeEscrow(f.state);
    result = f.asRoot(['enroll', '--device', 'sdb1']);
    assert.equal(result.status, 0, result.stderr);
    assert.match(f.run(['status']).stdout, /Backup key copy: confirmed\./);

    // run: an encrypted write needs the confirmation, and nothing happens before it (no fresh backup, no folder on the drive).
    f.backups(1);
    writeFileSync(join(f.root, 'scripts/backup.sh'), '#!/usr/bin/env bash\necho called >> "$WAREHOUSE_STATE_DIR/backup-called"\n', { mode: 0o755 });
    rmSync(record);
    result = f.run(['run', '--device', 'sdb1'], { ...f.verifyEnv(), WAREHOUSE_USB_BACKUP_FRESH: 'yes' });
    assert.equal(result.status, 1);
    assert.match(result.stderr, refusal);
    assert.match(result.stderr, /Nothing was written to the drive/);
    assert.equal(existsSync(f.dest), false, 'nothing written to the drive');
    assert.equal(existsSync(join(f.state, 'backup-called')), false, 'no fresh backup was taken for a run that cannot write');
    assert.match(f.last(), /^result=failed$/m);
    assert.match(f.last(), /^message=The backup key copy is not confirmed \(there is no key escrow record\)/m);
    assert.match(usbBackupWarning(f.state, { etc: f.etc }), /archives are encrypted but the backup key copy is not confirmed .*backup-key-escrow\.sh show/);
    // A run for readable archives, which the operator typed --no-encrypt for, needs none.
    result = f.run(['run', '--device', 'sdb1'], { ...f.verifyEnv(), ...PLAIN });
    assert.equal(result.status, 0, result.stderr + result.stdout);
    // The key is replaced after the copy was confirmed: the record no longer matches, and the new key needs its own confirmation.
    writeEscrow(f.state);
    assert.equal(f.run(['run', '--device', 'sdb1'], f.verifyEnv()).status, 0, 'confirmed: an encrypted run writes');
    const newKey = 'c3'.repeat(32);
    writeKey(join(f.state, 'config/backup.key'), newKey);
    f.writeMarker({ key: newKey });   // the drive is enrolled again with the new key
    f.localBackup(f.bname(5), { key: newKey });
    result = f.run(['run', '--device', 'sdb1'], f.verifyEnv());
    assert.equal(result.status, 1);
    assert.match(result.stderr, /the key escrow record is for another backup key \(the key was replaced since the copy was confirmed\)/);
    assert.equal(f.archives().includes(`${f.bname(5)}.tar.enc`), false);
    writeEscrow(f.state, newKey);
    result = f.run(['run', '--device', 'sdb1'], f.verifyEnv());
    assert.equal(result.status, 0, result.stderr + result.stdout);
    assert.ok(f.archives().includes(`${f.bname(5)}.tar.enc`));
  } finally { f.cleanup(); }
});

test('the doctor warning asks for the key copy when archives are encrypted and the record is missing or for another key', () => {
  const scratch = mkdtempSync(join(tmpdir(), 'warehouse-usb-doctor-escrow-'));
  try {
    const state = join(scratch, 'state'); mkdirSync(join(state, 'config'), { recursive: true });
    const etc = join(scratch, 'etc'); mkdirSync(etc);
    writeKey(join(state, 'config/backup.key'));
    const now = Date.UTC(2026, 9, 9);
    writeFileSync(join(state, 'config/usb-backup.last'), `result=ok\nfinished_utc=x\nlast_success_epoch=${Math.floor(now / 1000) - 86400}\nmessage=copied 1\n`);
    const conf = lines => writeFileSync(join(etc, 'warehouse-usb-backup.conf'), `STATE=${state}\n${lines}`);
    conf('ENCRYPT=yes\n');
    assert.match(usbBackupWarning(state, { etc, now }), /archives are encrypted but the backup key copy is not confirmed \(there is no key escrow record\)/);
    writeEscrow(state, 'd4'.repeat(32));
    assert.match(usbBackupWarning(state, { etc, now }), /record is for another backup key/);
    writeFileSync(join(state, 'config/backup-key.escrow'), 'not a record\n');
    assert.match(usbBackupWarning(state, { etc, now }), /the key escrow record is not valid/);
    writeEscrow(state);
    assert.equal(usbBackupWarning(state, { etc, now }), null, 'confirmed for the key in use');
    rmSync(join(state, 'config/backup-key.escrow'));
    conf('ENCRYPT=no\nENCRYPT_SET=typed\n');
    assert.equal(usbBackupWarning(state, { etc, now }), null, 'readable archives need no key copy');
  } finally { rmSync(scratch, { recursive: true, force: true }); }
});

test('a drive for readable archives, with --no-encrypt typed, is enrolled without a key copy confirmation', () => {
  const f = fixture('warehouse-usb-plainenroll-', { escrow: false });
  try {
    const result = f.asRoot(['setup', '--state', f.state, '--no-encrypt', '--enroll', '/dev/sdb1']);
    assert.equal(result.status, 0, result.stderr);
    assert.match(result.stdout, /Archives are NOT encrypted \(you typed --no-encrypt\)/);
    assert.doesNotMatch(result.stdout, /ACTION NEEDED/);
    assert.equal(readFileSync(join(f.etc, 'warehouse-usb-backup.drives'), 'utf8'), `${UUID} ${PART}\n`);
    assert.ok(existsSync(f.markerPath));
    // A later plain `enroll` follows the stored choice.
    rmSync(f.markerPath);
    assert.equal(f.asRoot(['enroll', '--device', 'sdb1']).status, 0);
    assert.doesNotMatch(f.run(['status']).stdout, /key copy is not confirmed/);
  } finally { f.cleanup(); }
});
