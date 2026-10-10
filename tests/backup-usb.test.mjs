// scripts/backup-usb.sh against fake device tools on PATH. No test touches a real device, mount,
// udev rule or systemd unit: /etc, /usr/local/libexec and /run are redirected into a scratch tree.
import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, existsSync, readdirSync, rmSync, statSync, chmodSync } from 'node:fs';
import { spawn, spawnSync } from 'node:child_process';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { makeBackup, makeState, fakeDocker, scriptRoot, composeEnv, backupKey, hmacHex, writeKey } from './backup-test-helpers.mjs';
import { usbBackupWarning } from '../scripts/usb-backup-status.mjs';

const UUID = '6A38-179A';
const PART = 'a1b2c3d4-01';
const INSTANCE = '0f0f0f0f-0f0f-4f0f-8f0f-0f0f0f0f0f0f';
const devRow = ({ fstype = 'exfat', ro = '0', part = PART } = {}) => `NAME="sdb1" TYPE="part" FSTYPE="${fstype}" UUID="${UUID}" RO="${ro}" PKNAME="sdb" PARTUUID="${part}"\n`;
// The marker `enroll` writes onto a drive: an HMAC under the backup key over the drive and the instance.
const marker = ({ uuid = UUID, part = PART, instance = INSTANCE, key = backupKey } = {}) =>
  `warehouse-usb-enrolment-v1\nfs_uuid=${uuid}\npart_uuid=${part}\ninstance_id=${instance}\nhmac=${hmacHex(key, 'warehouse-usb-enrolment-v1', `${uuid}\n${part}\n${instance}\n`)}\n`;
const shims = {
  lsblk: String.raw`#!/bin/sh
d="$FAKE_DIR"
for last; do :; done
b=$(basename "$last")
case "$*" in
  "-dnP -o NAME,TYPE,FSTYPE,UUID,RO,PKNAME,PARTUUID "*) cat "$d/dev.$b" 2>/dev/null || exit 32; exit 0 ;;
  "-dn -o TRAN "*) cat "$d/tran.$b" 2>/dev/null; exit 0 ;;
  "-nr -o NAME,UUID") cat "$d/uuids" 2>/dev/null; exit 0 ;;
esac
echo "unexpected lsblk: $*" >&2; exit 2
`,
  findmnt: String.raw`#!/bin/sh
d="$FAKE_DIR"
for last; do :; done
case "$*" in
  "-n -o TARGET -S "*) cat "$d/target.$(basename "$last")" 2>/dev/null || exit 1; exit 0 ;;
  "-n -o FSTYPE --mountpoint "*) cat "$d/fstype" 2>/dev/null || echo exfat; exit 0 ;;
  "-n -o TARGET --mountpoint "*) cat "$d/ours" 2>/dev/null || exit 1; exit 0 ;;
  "-n -o MAJ:MIN -T "*) case "$last" in "$FAKE_MOUNT"*) cat "$d/majmin.mount" ;; *) echo "  8:2  " ;; esac; exit 0 ;;
esac
echo "unexpected findmnt: $*" >&2; exit 2
`,
  mount: '#!/bin/sh\necho "mount $*" >> "$FAKE_LOG"\nexit 0\n',
  umount: '#!/bin/sh\necho "umount $*" >> "$FAKE_LOG"\nexit 0\n',
  chown: '#!/bin/sh\necho "chown $*" >> "$FAKE_LOG"\nexit 0\n',
  systemctl: '#!/bin/sh\necho "systemctl $*" >> "$FAKE_LOG"\nexit 0\n',
  udevadm: '#!/bin/sh\necho "udevadm $*" >> "$FAKE_LOG"\nexit 0\n',
  id: String.raw`#!/bin/sh
if [ "$1" = -u ]; then echo "$FAKE_UID"; exit 0; fi
exec /usr/bin/id "$@"
`,
  getent: String.raw`#!/bin/sh
case "$1" in
  passwd) echo "installer:x:$2:$2::/home/installer:/bin/sh" ;;
  group) echo "installer:x:$2:" ;;
esac
`,
};

function fixture(prefix) {
  const scratch = mkdtempSync(join(tmpdir(), prefix));
  const state = makeState(scratch);
  const root = scriptRoot(scratch);
  chmodSync(join(root, 'scripts'), 0o755);
  for (const name of readdirSync(join(root, 'scripts'))) chmodSync(join(root, 'scripts', name), 0o755);
  const fake = join(scratch, 'fake'); mkdirSync(fake);
  const bin = join(scratch, 'shims'); mkdirSync(bin);
  for (const [name, body] of Object.entries(shims)) writeFileSync(join(bin, name), body, { mode: 0o755 });
  const dockerBin = fakeDocker(join(scratch, 'dockerbin'));
  const etc = join(scratch, 'etc'); mkdirSync(etc);
  const libexec = join(scratch, 'libexec');
  const runDir = join(scratch, 'run');
  const drive = join(scratch, 'media/drive'); mkdirSync(drive, { recursive: true });
  writeFileSync(join(drive, 'holiday-photos.zip'), 'not ours');
  const log = join(scratch, 'tools.log'); writeFileSync(log, '');
  const dockerLog = join(scratch, 'docker.log'); writeFileSync(dockerLog, '');
  const put = (name, body) => writeFileSync(join(fake, name), body);
  // An exFAT partition on a USB stick, desktop-mounted at `drive`.
  put('dev.sdb1', devRow());
  put('tran.sdb', 'usb\n');
  put('uuids', `sda2 210f776f\nsdb1 ${UUID}\n`);
  put('target.sdb1', `${drive}\n`);
  put('majmin.mount', '  8:17 \n');
  // What `enroll` leaves behind: the root-only list entry and the signed marker on the drive.
  const markerPath = join(drive, 'warehouse-backups', '.drive-enrolment');
  const writeMarker = (options = {}) => { mkdirSync(join(drive, 'warehouse-backups'), { recursive: true }); writeFileSync(markerPath, marker(options)); };
  const enroll = () => { writeFileSync(join(etc, 'warehouse-usb-backup.drives'), `${UUID} ${PART}\n`); writeMarker(); };
  const env = (extra = {}) => ({
    ...process.env, PATH: `${bin}:${dockerBin}:${process.env.PATH}`, WAREHOUSE_STATE_DIR: state,
    WAREHOUSE_USB_BACKUP_ETC: etc, WAREHOUSE_USB_BACKUP_LIBEXEC: libexec, WAREHOUSE_USB_BACKUP_RUN: runDir,
    WAREHOUSE_USB_BACKUP_SETTLE: '0', WAREHOUSE_USB_BACKUP_FRESH: 'no', WAREHOUSE_USB_BACKUP_LOCK_WAIT: '1',
    FAKE_DIR: fake, FAKE_LOG: log, FAKE_MOUNT: drive, FAKE_UID: String(process.getuid()), FAKE_DOCKER_LOG: dockerLog,
    SUDO_UID: String(process.getuid()), SUDO_GID: String(process.getgid()), ...extra,
  });
  const run = (args, extra = {}) => spawnSync('bash', [join(root, 'scripts/backup-usb.sh'), ...args], { encoding: 'utf8', env: env(extra) });
  const asRoot = (args, extra = {}) => run(args, { FAKE_UID: '0', ...extra });
  const calls = () => readFileSync(log, 'utf8');
  const dockerCalls = () => readFileSync(dockerLog, 'utf8');
  const dest = join(drive, 'warehouse-backups', 'state');
  const last = () => readFileSync(join(state, 'config/usb-backup.last'), 'utf8');
  const backups = (count = 1) => {
    const names = [];
    for (let i = 1; i <= count; i += 1) {
      const name = `warehouse-2026010${i}T000000Z`;
      makeBackup(join(state, 'backups', name), { env: composeEnv(state) });
      names.push(name);
    }
    return names;
  };
  const verifyEnv = () => ({ FAKE_CATALOG_FILE: join(state, 'backups', readdirSync(join(state, 'backups')).sort()[0], 'storage_objects.txt') });
  return { scratch, state, root, fake, etc, libexec, runDir, drive, dest, run, asRoot, calls, dockerCalls, put, enroll, writeMarker, markerPath, last, backups, verifyEnv,
    cleanup: () => rmSync(scratch, { recursive: true, force: true }) };
}

const pause = ms => Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);

test('run copies each backup as a verified tar, verifies the restore, records the result and leaves other files alone', () => {
  const f = fixture('warehouse-usb-ok-');
  try {
    f.enroll();
    const names = f.backups(2);
    const result = f.run(['run', '--device', 'sdb1'], f.verifyEnv());
    assert.equal(result.status, 0, result.stderr + result.stdout);
    for (const name of names) {
      const archive = join(f.dest, `${name}.tar`);
      assert.ok(existsSync(archive), `${name} archived`);
      assert.equal(spawnSync('sha256sum', ['-c', '--quiet', `${name}.tar.sha256`], { cwd: f.dest }).status, 0);
      assert.equal(readFileSync(`${archive}.hmac`, 'utf8'), `warehouse-backup-hmac-v1 ${hmacHex(backupKey, 'warehouse-backup-archive-v1', readFileSync(`${archive}.sha256`))}\n`, 'the archive checksum is signed with the backup key');
      const listing = spawnSync('tar', ['-tvf', archive], { encoding: 'utf8' }).stdout;
      assert.match(listing, /^-rw------- .*compose\.env$/m, 'file modes are kept inside the archive');
    }
    assert.deepEqual(readdirSync(f.dest).filter(n => n.endsWith('.partial')), [], 'no partial file left');
    assert.equal(readFileSync(join(f.drive, 'holiday-photos.zip'), 'utf8'), 'not ours');
    assert.match(f.dockerCalls(), /run /, 'verify-restore ran on the copy from the drive');
    assert.match(result.stdout, /copied=2 already-present=0 failed=0/);
    assert.match(result.stdout, /not encrypted and contain every credential/);
    assert.match(f.last(), /^result=ok$/m);
    assert.match(f.last(), new RegExp(`^drive_uuid=${UUID}$`, 'm'));
    assert.match(readFileSync(join(f.dest, 'LAST-RESULT.txt'), 'utf8'), /result=ok[\s\S]*NOT encrypted/);
    assert.equal(statSync(join(f.state, 'config/usb-backup.last')).mode & 0o077, 0, 'result file is private');
    assert.equal(readdirSync(f.state).filter(n => n.startsWith('.usb-verify')).length, 0, 'verify directory removed');
    assert.doesNotMatch(f.calls(), /^(mount|umount) /m, 'run never mounts or unmounts');

    const before = statSync(join(f.dest, `${names[0]}.tar`)).mtimeMs;
    const again = f.run(['run', '--device', 'sdb1'], f.verifyEnv());
    assert.equal(again.status, 0, again.stderr);
    assert.match(again.stdout, /copied=0 already-present=2 failed=0/);
    assert.equal(statSync(join(f.dest, `${names[0]}.tar`)).mtimeMs, before, 'an existing archive is not rewritten');
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
    const [first, second] = f.backups(2);
    assert.equal(f.run(['run', '--device', 'sdb1'], f.verifyEnv()).status, 0);
    writeFileSync(join(f.dest, `${first}.tar`), 'damaged');
    writeFileSync(join(f.dest, '.warehouse-old.tar.partial'), 'interrupted');
    makeBackup(join(f.state, 'backups', 'warehouse-20260109T000000Z'), { env: composeEnv(f.state) });
    writeFileSync(join(f.state, 'backups', 'warehouse-20260109T000000Z', 'database.dump'), 'tampered');
    const result = f.run(['run', '--device', 'sdb1'], f.verifyEnv());
    assert.equal(result.status, 1);
    assert.match(result.stderr, new RegExp(`archive of ${first} on the drive does not match its checksum or signature; it was not overwritten`));
    assert.match(result.stderr, /source backup warehouse-20260109T000000Z fails its checksums/);
    assert.equal(readFileSync(join(f.dest, `${first}.tar`), 'utf8'), 'damaged');
    assert.equal(existsSync(join(f.dest, 'warehouse-20260109T000000Z.tar')), false);
    assert.equal(existsSync(join(f.dest, '.warehouse-old.tar.partial')), false, 'leftover removed under the lock');
    assert.match(result.stdout, new RegExp(`already-present=1 failed=2`));
    assert.match(f.last(), /^result=failed$/m);
    assert.match(f.last(), /^last_success_epoch=\d+$/m, 'the earlier success is kept');
    assert.ok(second);
  } finally { f.cleanup(); }
});

test('run takes a fresh backup first and still copies existing backups when it fails', () => {
  const f = fixture('warehouse-usb-fresh-');
  try {
    f.enroll();
    f.backups(1);
    // Stand-in for scripts/backup.sh: copies the fixture backup under a new name.
    writeFileSync(join(f.root, 'scripts/backup.sh'), `#!/usr/bin/env bash
set -e
[ "$FAKE_BACKUP_FAIL" = yes ] && { echo 'backup failed' >&2; exit 1; }
cp -a "$WAREHOUSE_STATE_DIR/backups/warehouse-20260101T000000Z" "$WAREHOUSE_STATE_DIR/backups/warehouse-20260102T000000Z"
`, { mode: 0o755 });
    const ok = f.run(['run', '--device', 'sdb1'], { ...f.verifyEnv(), WAREHOUSE_USB_BACKUP_FRESH: 'yes' });
    assert.equal(ok.status, 0, ok.stderr);
    assert.match(ok.stdout, /Taking a fresh backup/);
    assert.ok(existsSync(join(f.dest, 'warehouse-20260102T000000Z.tar')), 'the fresh backup was copied');

    const failed = f.run(['run', '--device', 'sdb1'], { ...f.verifyEnv(), WAREHOUSE_USB_BACKUP_FRESH: 'yes', FAKE_BACKUP_FAIL: 'yes' });
    assert.equal(failed.status, 1);
    assert.match(failed.stderr, /fresh backup failed; existing backups are still copied/);
    assert.match(failed.stdout, /already-present=2 failed=1/);
    assert.match(f.last(), /^result=failed$/m);
  } finally { f.cleanup(); }
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
    assert.match(conf, /^ENCRYPT=no$/m);
    assert.match(unit, /^Environment=WAREHOUSE_BACKUP_ENCRYPT=0$/m);
    assert.match(result.stdout, /Archives are NOT encrypted/);
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

test('run with WAREHOUSE_BACKUP_ENCRYPT=1 writes encrypted, signed archives that restore verification can open', () => {
  const f = fixture('warehouse-usb-encrypt-');
  const on = extra => ({ ...f.verifyEnv(), WAREHOUSE_BACKUP_ENCRYPT: '1', ...extra });
  try {
    f.enroll();
    const [first, second] = f.backups(2);
    // The first backup is already on the drive, unencrypted, from before the switch.
    assert.equal(f.run(['run', '--device', 'sdb1'], { ...f.verifyEnv(), WAREHOUSE_USB_BACKUP_VERIFY_RESTORE: 'no' }).status, 0);
    rmSync(join(f.dest, `${second}.tar`)); rmSync(join(f.dest, `${second}.tar.sha256`)); rmSync(join(f.dest, `${second}.tar.hmac`));
    const result = f.run(['run', '--device', 'sdb1'], on());
    assert.equal(result.status, 0, result.stderr + result.stdout);
    assert.match(result.stdout, /copied=1 already-present=1 failed=0/);
    const enc = join(f.dest, `${second}.tar.enc`);
    assert.ok(existsSync(enc) && !existsSync(join(f.dest, `${second}.tar`)), 'only the encrypted archive is written');
    const bytes = readFileSync(enc, 'latin1');
    assert.match(bytes, /^Salted__/, 'openssl salted format');
    for (const plain of ['compose.env', 'WAREHOUSE_PROJECT_NAME', 'fake database dump', second]) assert.ok(!bytes.includes(plain), `${plain} is not readable on the drive`);
    assert.equal(spawnSync('sha256sum', ['-c', '--quiet', `${second}.tar.enc.sha256`], { cwd: f.dest }).status, 0);
    assert.equal(readFileSync(`${enc}.hmac`, 'utf8'), `warehouse-backup-hmac-v1 ${hmacHex(backupKey, 'warehouse-backup-archive-v1', readFileSync(`${enc}.sha256`))}\n`);
    // Decrypting with the key gives back the backup, file modes included.
    const listing = spawnSync('bash', ['-c', 'set -euo pipefail; source "$1"; backup_key_load "$2"; backup_decrypt "$BACKUP_KEY" < "$3" | tar -tvf -', 'sh', join(f.root, 'scripts/backup-key.sh'), join(f.state, 'config/backup.key'), enc], { encoding: 'utf8' });
    assert.equal(listing.status, 0, listing.stderr);
    assert.match(listing.stdout, new RegExp(`^-rw------- .*${second}/compose\\.env$`, 'm'));
    assert.match(f.dockerCalls(), /^run -d /m, 'restore verification ran on the decrypted copy');
    assert.match(result.stdout, new RegExp(`Restore verification of the copy on the drive passed: ${second}`));
    assert.match(result.stdout, /still holds unencrypted \.tar archives/, 'the earlier plain archive is called out');
    assert.match(readFileSync(join(f.dest, 'LAST-RESULT.txt'), 'utf8'), /encrypted with the backup key[\s\S]*\.tar \(not \.tar\.enc\) are NOT encrypted/);
    assert.equal(readdirSync(f.state).filter(n => n.startsWith('.usb-verify')).length, 0, 'the decrypted copy is removed');
    assert.ok(first);

    const again = f.run(['run', '--device', 'sdb1'], on());
    assert.equal(again.status, 0, again.stderr);
    assert.match(again.stdout, /copied=0 already-present=2 failed=0/);
    // A wrong key cannot produce the signature, and the archive is then not trusted.
    writeFileSync(`${enc}.hmac`, `warehouse-backup-hmac-v1 ${'0'.repeat(64)}\n`);
    const forged = f.run(['run', '--device', 'sdb1'], on());
    assert.equal(forged.status, 1);
    assert.match(forged.stderr, new RegExp(`archive of ${second} on the drive does not match its checksum or signature`));
    rmSync(`${enc}.hmac`);
    assert.equal(f.run(['run', '--device', 'sdb1'], on()).status, 1, 'an encrypted archive without a signature is not accepted');
  } finally { f.cleanup(); }
});

test('run reports an unsigned newest backup instead of verifying it', () => {
  const f = fixture('warehouse-usb-unsigned-');
  try {
    f.enroll();
    makeBackup(join(f.state, 'backups', 'warehouse-20251201T000000Z'), { env: composeEnv(f.state), format: 'warehouse-backup-v4' });
    const result = f.run(['run', '--device', 'sdb1'], f.verifyEnv());
    assert.equal(result.status, 1);
    assert.ok(existsSync(join(f.dest, 'warehouse-20251201T000000Z.tar')), 'it is still copied');
    assert.match(result.stderr, /newest backup on the drive \(warehouse-20251201T000000Z\) is unsigned.*take a new backup/);
    assert.equal(f.dockerCalls(), '', 'no restore verification ran');
  } finally { f.cleanup(); }
});
