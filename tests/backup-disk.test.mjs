// scripts/backup-disk.sh against fake disk tools on PATH. No test touches a real device,
// the real /etc/fstab or a real mount; every tool call is logged and asserted.
import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, existsSync, readdirSync, rmSync, statSync, chmodSync, symlinkSync } from 'node:fs';
import { spawn, spawnSync } from 'node:child_process';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { makeBackup, makeState, fakeDocker, scriptRoot, composeEnv } from './backup-test-helpers.mjs';

const SDA = 'NAME="sda" TYPE="disk" SIZE="214748364800" RM="0" RO="0" SERIAL="" MODEL="Root Disk" MAJ:MIN="8:0" FSTYPE=""';
const sdb = (extra = {}) => {
  const f = { SIZE: '107374182400', RM: '0', RO: '0', SERIAL: 'SER123', MODEL: 'Backup Disk', 'MAJ:MIN': '8:16', FSTYPE: '', ...extra };
  return `NAME="sdb" TYPE="disk" SIZE="${f.SIZE}" RM="${f.RM}" RO="${f.RO}" SERIAL="${f.SERIAL}" MODEL="${f.MODEL}" MAJ:MIN="${f['MAJ:MIN']}" FSTYPE="${f.FSTYPE}"`;
};

const shims = {
  lsblk: String.raw`#!/bin/sh
d="$FAKE_DIR"
for last; do :; done
base=$(basename "$last")
case "$*" in
  "-nsP -o NAME,TYPE "*) cat "$d/inverse.$base" 2>/dev/null; exit 0 ;;
  "-dnPb -o NAME,TYPE,SIZE,RM,RO,SERIAL,MODEL,MAJ:MIN,FSTYPE") cat "$d/disks"; exit 0 ;;
  "-dnPb -o NAME,TYPE,SIZE,RM,RO,SERIAL,MODEL,MAJ:MIN,FSTYPE "*) grep "NAME=\"$base\"" "$d/disks"; exit 0 ;;
  "-nPb -o NAME,TYPE,FSTYPE,MOUNTPOINT "*) cat "$d/tree.$base" 2>/dev/null; exit 0 ;;
  "-nP -o NAME,TYPE,PARTLABEL") cat "$d/partlabels" 2>/dev/null; exit 0 ;;
  "-nP -o NAME,TYPE "*) cat "$d/parts.$base" 2>/dev/null; exit 0 ;;
esac
echo "unexpected lsblk: $*" >&2; exit 2
`,
  findmnt: String.raw`#!/bin/sh
d="$FAKE_DIR"
for last; do :; done
case "$*" in
  "-n -o SOURCE -T /"|"-n -o SOURCE -T /boot"|"-n -o SOURCE -T /boot/efi") cat "$d/root.source"; exit 0 ;;
  "-n -o SOURCE -T "*) cat "$d/data.source"; exit 0 ;;
  "-n -o MAJ:MIN -T "*) if [ "$last" = "$FAKE_MOUNT" ]; then cat "$d/majmin.mount"; else cat "$d/majmin.data"; fi; exit 0 ;;
  "--mountpoint "*" -n -o SOURCE") if [ -f "$d/mounted" ]; then cat "$d/mounted"; exit 0; fi; exit 1 ;;
  "--mountpoint "*" -n -o UUID") cat "$d/mounted.uuid"; exit 0 ;;
  "--verify --tab-file "*) exit 0 ;;
esac
echo "unexpected findmnt: $*" >&2; exit 2
`,
  blkid: String.raw`#!/bin/sh
d="$FAKE_DIR"
case "$*" in
  "-p -o value -s TYPE "*)
    n=$(cat "$d/blkid.count" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" > "$d/blkid.count"
    if [ -f "$d/blkid.after" ] && [ "$n" -ge 2 ]; then cat "$d/blkid.after"; exit 0; fi
    if [ -f "$d/blkid.sig" ]; then cat "$d/blkid.sig"; exit 0; fi
    exit 2 ;;
  "-s UUID -o value "*) echo "1234-ABCD"; exit 0 ;;
esac
echo "unexpected blkid: $*" >&2; exit 2
`,
  wipefs: String.raw`#!/bin/sh
for last; do :; done
cat "$FAKE_DIR/wipefs.$(basename "$last")" 2>/dev/null
exit 0
`,
  sgdisk: String.raw`#!/bin/sh
echo "sgdisk $*" >> "$FAKE_LOG"
for last; do :; done
b=$(basename "$last")
printf 'NAME="%s" TYPE="disk"\nNAME="%s1" TYPE="part"\n' "$b" "$b" > "$FAKE_DIR/parts.$b"
exit 0
`,
  'mkfs.ext4': '#!/bin/sh\necho "mkfs.ext4 $*" >> "$FAKE_LOG"\nexit 0\n',
  partprobe: '#!/bin/sh\necho "partprobe $*" >> "$FAKE_LOG"\nexit 0\n',
  udevadm: '#!/bin/sh\necho "udevadm $*" >> "$FAKE_LOG"\nexit 0\n',
  umount: '#!/bin/sh\necho "umount $*" >> "$FAKE_LOG"\nexit 0\n',
  chown: '#!/bin/sh\necho "chown $*" >> "$FAKE_LOG"\nexit 0\n',
  mount: String.raw`#!/bin/sh
echo "mount $*" >> "$FAKE_LOG"
if [ "$FAKE_MOUNT_FAIL" = yes ] && [ "$#" -eq 1 ]; then exit 1; fi
exit 0
`,
  id: String.raw`#!/bin/sh
if [ "$1" = -u ]; then echo "$FAKE_UID"; exit 0; fi
exec /usr/bin/id "$@"
`,
  getent: '#!/bin/sh\necho "installer:x:1000:1000::/home/installer:/bin/sh"\n',
  cp: String.raw`#!/bin/sh
for last; do :; done
case "$last" in
  *.sync-staging.*) if [ "$FAKE_CP_FAIL" = yes ]; then mkdir -p "$last"; echo partial > "$last/partial"; exit 1; fi ;;
esac
exec /bin/cp "$@"
`,
};

function fixture(prefix, { second = true, disks } = {}) {
  const scratch = mkdtempSync(join(tmpdir(), prefix));
  const state = makeState(scratch);
  const root = scriptRoot(scratch);
  chmodSync(join(root, 'scripts'), 0o755);
  for (const name of readdirSync(join(root, 'scripts'))) chmodSync(join(root, 'scripts', name), 0o755);
  const fake = join(scratch, 'fake'); mkdirSync(fake);
  const bin = join(scratch, 'shims'); mkdirSync(bin);
  for (const [name, body] of Object.entries(shims)) writeFileSync(join(bin, name), body, { mode: 0o755 });
  const dockerBin = fakeDocker(join(scratch, 'dockerbin'));
  const mount = join(scratch, 'mnt/warehouse-backups'); mkdirSync(join(scratch, 'mnt'));
  const fstab = join(scratch, 'fstab'); writeFileSync(fstab, 'UUID=aaaa-bbbb / ext4 defaults 0 1\n');
  const sysfs = join(scratch, 'sys'); mkdirSync(sysfs);
  const log = join(scratch, 'tools.log'); writeFileSync(log, '');
  const dockerLog = join(scratch, 'docker.log'); writeFileSync(dockerLog, '');
  const put = (name, body) => writeFileSync(join(fake, name), body);
  put('disks', disks ?? [SDA, ...(second ? [sdb()] : [])].join('\n') + '\n');
  put('root.source', '/dev/sda2\n'); put('data.source', '/dev/sda2\n');
  put('inverse.sda2', 'NAME="sda2" TYPE="part"\nNAME="sda" TYPE="disk"\n');
  put('majmin.mount', '8:16\n'); put('majmin.data', '8:2\n');
  put('tree.sdb', 'NAME="sdb" TYPE="disk" FSTYPE="" MOUNTPOINT=""\n');
  const env = (extra = {}) => ({
    ...process.env, PATH: `${bin}:${dockerBin}:${process.env.PATH}`, WAREHOUSE_STATE_DIR: state,
    WAREHOUSE_BACKUP_DISK_MOUNT: mount, WAREHOUSE_BACKUP_DISK_FSTAB: fstab, WAREHOUSE_BACKUP_DISK_SYSFS: sysfs,
    FAKE_DIR: fake, FAKE_LOG: log, FAKE_MOUNT: mount, FAKE_UID: '0', SUDO_UID: '1000', SUDO_GID: '1000', FAKE_DOCKER_LOG: dockerLog, ...extra,
  });
  const run = (args, extra = {}) => spawnSync('bash', [join(root, 'scripts/backup-disk.sh'), ...args], { encoding: 'utf8', env: env(extra) });
  const calls = () => readFileSync(log, 'utf8');
  const dockerCalls = () => readFileSync(dockerLog, 'utf8');
  // A prepared, mounted backup disk for the sync tests.
  const mountDisk = ({ uuid = 'UUID-1', marker = uuid } = {}) => {
    mkdirSync(mount, { mode: 0o700, recursive: true });
    chmodSync(mount, 0o700);
    if (marker !== null) writeFileSync(join(mount, '.warehouse-backup-disk'), `${marker}\n`);
    put('mounted', '/dev/sdb1\n'); put('mounted.uuid', `${uuid}\n`);
  };
  return { scratch, state, root, fake, bin, mount, fstab, run, calls, dockerCalls, put, mountDisk, env,
    cleanup: () => rmSync(scratch, { recursive: true, force: true }) };
}

const DESTRUCTIVE = /^(sgdisk|mkfs\.ext4|mount|umount|chown) /m;
const APPLY = ['apply', '--device', '/dev/sdb', '--yes', '--confirm-serial', 'SER123'];
const pause = ms => Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);

test('plan and status report a missing second disk and never offer the system disk', () => {
  const f = fixture('warehouse-disk-none-', { second: false });
  try {
    const plan = f.run(['plan']);
    assert.equal(plan.status, 1);
    assert.match(plan.stderr, /No second disk found.*partition on the system disk is not offered/);
    const status = f.run(['status']);
    assert.equal(status.status, 0);
    assert.match(status.stdout, /No second disk/);
    const sys = f.run(['plan', '--device', '/dev/sda']);
    assert.equal(sys.status, 1);
    assert.match(sys.stderr, /operating system or the operator data/);
    assert.equal(f.calls(), '', 'no tool with side effects was called');
  } finally { f.cleanup(); }
});

test('plan lists the empty second disk, prints the plan and the confirmation, and changes nothing', () => {
  const f = fixture('warehouse-disk-plan-');
  try {
    const list = f.run(['plan']);
    assert.equal(list.status, 0, list.stderr);
    assert.match(list.stdout, /Candidate: \/dev\/sdb, 100 GiB, model 'Backup Disk', serial 'SER123'/);
    assert.doesNotMatch(list.stdout, /\/dev\/sda\b/);
    const plan = f.run(['plan', '--device', '/dev/sdb']);
    assert.equal(plan.status, 0, plan.stderr);
    assert.match(plan.stdout, /GPT with one partition/);
    assert.match(plan.stdout, /sudo bash scripts\/backup-disk\.sh apply --device \/dev\/sdb --yes --confirm-serial SER123/);
    assert.match(plan.stdout, /Test overrides active/);
    assert.doesNotMatch(f.calls(), DESTRUCTIVE);
    assert.equal(readFileSync(f.fstab, 'utf8'), 'UUID=aaaa-bbbb / ext4 defaults 0 1\n');
    assert.equal(f.run(['status']).stdout.includes('Second disk candidate (empty): /dev/sdb'), true);
  } finally { f.cleanup(); }
});

test('plan uses the exact size as confirmation when the disk reports no serial', () => {
  const f = fixture('warehouse-disk-noserial-', { disks: `${SDA}\n${sdb({ SERIAL: '' })}\n` });
  try {
    const plan = f.run(['plan', '--device', '/dev/sdb']);
    assert.equal(plan.status, 0, plan.stderr);
    assert.match(plan.stdout, /--confirm-size 107374182400/);
  } finally { f.cleanup(); }
});

test('refuses devices that are not an empty whole second disk', () => {
  const cases = [
    ['partition path', f => f.run(['plan', '--device', '/dev/sda1']), /not a whole sdX/],
    ['loop device', f => f.run(['plan', '--device', '/dev/loop0']), /not a whole sdX/],
    ['optical drive', f => f.run(['plan', '--device', '/dev/sr0']), /not a whole sdX/],
    ['device-mapper path', f => f.run(['plan', '--device', '/dev/mapper/root']), /not a whole sdX/],
    ['unknown disk', f => f.run(['plan', '--device', '/dev/sdz']), /not a block device/],
    ['removable', f => { f.put('disks', `${SDA}\n${sdb({ RM: '1' })}\n`); return f.run(['plan', '--device', '/dev/sdb']); }, /removable or read-only/],
    ['read-only', f => { f.put('disks', `${SDA}\n${sdb({ RO: '1' })}\n`); return f.run(['plan', '--device', '/dev/sdb']); }, /removable or read-only/],
    ['loop major', f => { f.put('disks', `${SDA}\n${sdb({ 'MAJ:MIN': '7:0' })}\n`); return f.run(['plan', '--device', '/dev/sdb']); }, /ram, loop or optical/],
    ['has a partition', f => { f.put('tree.sdb', 'NAME="sdb" TYPE="disk" FSTYPE="" MOUNTPOINT=""\nNAME="sdb1" TYPE="part" FSTYPE="" MOUNTPOINT=""\n'); return f.run(['plan', '--device', '/dev/sdb']); }, /already has partitions/],
    ['mounted partition', f => { f.put('tree.sdb', 'NAME="sdb" TYPE="disk" FSTYPE="" MOUNTPOINT=""\nNAME="sdb1" TYPE="part" FSTYPE="ext4" MOUNTPOINT="/mnt/x"\n'); return f.run(['plan', '--device', '/dev/sdb']); }, /mounted or used as swap/],
    ['swap', f => { f.put('tree.sdb', 'NAME="sdb" TYPE="disk" FSTYPE="" MOUNTPOINT=""\nNAME="sdb1" TYPE="part" FSTYPE="swap" MOUNTPOINT="[SWAP]"\n'); return f.run(['plan', '--device', '/dev/sdb']); }, /mounted or used as swap/],
    ['LVM signature', f => { f.put('blkid.sig', 'LVM2_member\n'); return f.run(['plan', '--device', '/dev/sdb']); }, /carries a LVM2_member signature/],
    ['filesystem signature', f => { f.put('blkid.sig', 'ext4\n'); return f.run(['plan', '--device', '/dev/sdb']); }, /carries a ext4 signature/],
    ['empty partition table only', f => { f.put('wipefs.sdb', 'DEVICE OFFSET TYPE\nsdb 0x200 gpt\n'); return f.run(['plan', '--device', '/dev/sdb']); }, /partition table or filesystem signature/],
    ['md/dm holder', f => { mkdirSync(join(f.scratch, 'sys/block/sdb/holders/md0'), { recursive: true }); return f.run(['plan', '--device', '/dev/sdb']); }, /md or device-mapper/],
    ['too small', f => { f.put('disks', `${SDA}\n${sdb({ SIZE: '5368709120' })}\n`); return f.run(['plan', '--device', '/dev/sdb']); }, /at least 10 GiB is required/],
    ['holds the operator data', f => { f.put('data.source', '/dev/sdb1\n'); f.put('inverse.sdb1', 'NAME="sdb1" TYPE="part"\nNAME="sdb" TYPE="disk"\n'); return f.run(['plan', '--device', '/dev/sdb']); }, /operating system or the operator data/],
  ];
  for (const [label, act, expected] of cases) {
    const f = fixture('warehouse-disk-refuse-');
    try {
      const result = act(f);
      assert.equal(result.status, 1, `${label}: ${result.stdout}`);
      assert.match(result.stderr, expected, label);
      assert.doesNotMatch(f.calls(), DESTRUCTIVE, label);
    } finally { f.cleanup(); }
  }
});

test('fails closed when the system disk cannot be determined', () => {
  const f = fixture('warehouse-disk-closed-');
  try {
    rmSync(join(f.fake, 'inverse.sda2'));
    const result = f.run(['plan', '--device', '/dev/sdb']);
    assert.equal(result.status, 1);
    assert.match(result.stderr, /Cannot determine which disk holds the operating system/);
  } finally { f.cleanup(); }
});

test('apply refuses without every explicit safeguard and never calls a destructive tool', () => {
  const cases = [
    ['no --device', f => f.run(['apply', '--yes']), /apply needs --device/],
    ['no --yes', f => f.run(['apply', '--device', '/dev/sdb']), /repeat the command with --yes/],
    ['not root', f => f.run(APPLY, { FAKE_UID: '1000' }), /apply needs root; run: sudo/],
    ['SUDO_UID unset', f => f.run(APPLY, { SUDO_UID: '' }), /installation user \(SUDO_UID is not set\)/],
    ['SUDO_UID is root', f => f.run(APPLY, { SUDO_UID: '0' }), /installation user/],
    ['no confirmation', f => f.run(['apply', '--device', '/dev/sdb', '--yes']), /Confirmation missing or wrong: repeat with --confirm-serial SER123/],
    ['wrong serial', f => f.run(['apply', '--device', '/dev/sdb', '--yes', '--confirm-serial', 'OTHER']), /Confirmation missing or wrong/],
    ['wrong size', f => f.run(['apply', '--device', '/dev/sdb', '--yes', '--confirm-size', '1']), /Confirmation missing or wrong/],
    ['system disk', f => f.run(['apply', '--device', '/dev/sda', '--yes', '--confirm-size', '214748364800']), /operating system or the operator data/],
    ['writable script directory', f => { chmodSync(join(f.root, 'scripts'), 0o775); return f.run(APPLY); }, /group- or world-writable/],
    ['non-empty mount point', f => { mkdirSync(f.mount, { recursive: true }); writeFileSync(join(f.mount, 'x'), 'x'); return f.run(APPLY); }, /not an empty directory/],
    ['existing fstab entry', f => { writeFileSync(f.fstab, `UUID=aaaa-bbbb / ext4 defaults 0 1\nUUID=zzzz ${f.mount} ext4 defaults 0 2\n`); return f.run(APPLY); }, /already has an entry/],
    ['disk with a signature', f => { f.put('blkid.sig', 'ext4\n'); return f.run(APPLY); }, /carries a ext4 signature/],
  ];
  for (const [label, act, expected] of cases) {
    const f = fixture('warehouse-disk-apply-refuse-');
    try {
      const result = act(f);
      assert.equal(result.status, 1, `${label}: ${result.stdout}`);
      assert.match(result.stderr, expected, label);
      assert.doesNotMatch(f.calls(), DESTRUCTIVE, label);
    } finally { f.cleanup(); }
  }
});

test('apply partitions, formats and mounts an empty second disk and adds exactly one fstab line', () => {
  const f = fixture('warehouse-disk-apply-');
  try {
    const before = readFileSync(f.fstab, 'utf8');
    const result = f.run(APPLY);
    assert.equal(result.status, 0, result.stderr + result.stdout);
    const calls = f.calls().trim().split('\n');
    const order = ['sgdisk', 'partprobe', 'udevadm', 'mkfs.ext4', 'mount', 'chown', 'chown', 'umount', 'mount'];
    assert.deepEqual(calls.map(line => line.split(' ')[0]), order, f.calls());
    assert.match(calls[0], /sgdisk --new=1:0:0 --typecode=1:8300 --change-name=1:warehouse-backup \/dev\/sdb$/);
    assert.doesNotMatch(f.calls(), /zap|--clear|-F |mkfs.ext4 -f/);
    assert.match(calls[3], /mkfs\.ext4 -q -m 0 -L warehouse-backup \/dev\/sdb1$/);
    assert.match(calls[4], new RegExp(`mount /dev/sdb1 ${f.mount}$`));
    assert.match(calls[5], new RegExp(`chown 1000:1000 ${f.mount}$`));
    const after = readFileSync(f.fstab, 'utf8');
    assert.equal(after, `${before}UUID=1234-ABCD ${f.mount} ext4 defaults,nofail,x-systemd.device-timeout=10 0 2\n`, 'old lines byte-identical, one line appended');
    assert.equal(readdirSync(f.scratch).filter(n => n.startsWith('fstab.warehouse-backup-disk.')).length, 1, 'dated copy kept');
    assert.equal(readFileSync(join(f.mount, '.warehouse-backup-disk'), 'utf8'), '1234-ABCD\n');
    assert.equal(statSync(f.mount).mode & 0o777, 0o700);
    assert.match(result.stdout, /Backup disk ready at/);
    assert.doesNotMatch(f.calls(), /\/etc\/fstab/);
  } finally { f.cleanup(); }
});

test('apply is a no-op on a prepared disk and refuses to swap in another disk', () => {
  const f = fixture('warehouse-disk-idempotent-');
  try {
    f.mountDisk({ uuid: '1234-ABCD' });
    f.put('inverse.sdb1', 'NAME="sdb1" TYPE="part"\nNAME="sdb" TYPE="disk"\n');
    writeFileSync(f.fstab, `UUID=aaaa-bbbb / ext4 defaults 0 1\nUUID=1234-ABCD ${f.mount} ext4 defaults,nofail 0 2\n`);
    const again = f.run(APPLY);
    assert.equal(again.status, 0, again.stderr);
    assert.match(again.stdout, /already prepared.*nothing changed/);
    assert.equal(f.calls(), '');
    f.put('disks', `${SDA}\n${sdb()}\nNAME="sdc" TYPE="disk" SIZE="107374182400" RM="0" RO="0" SERIAL="SER999" MODEL="Other" MAJ:MIN="8:32" FSTYPE=""\n`);
    const other = f.run(['apply', '--device', '/dev/sdc', '--yes', '--confirm-serial', 'SER999']);
    assert.equal(other.status, 1);
    assert.match(other.stderr, /already configured with another disk/);
    assert.equal(f.calls(), '');
  } finally { f.cleanup(); }
});

test('apply restores fstab when the mount round trip fails', () => {
  const f = fixture('warehouse-disk-rollback-');
  try {
    const before = readFileSync(f.fstab, 'utf8');
    const result = f.run(APPLY, { FAKE_MOUNT_FAIL: 'yes' });
    assert.equal(result.status, 1);
    assert.match(result.stderr, /fstab entry did not mount; .* was restored/);
    assert.equal(readFileSync(f.fstab, 'utf8'), before);
  } finally { f.cleanup(); }
});

test('apply stops before writing when the disk changes after the checks (TOCTOU)', () => {
  const f = fixture('warehouse-disk-toctou-');
  try {
    f.put('blkid.after', 'ext4\n');
    const result = f.run(APPLY);
    assert.equal(result.status, 1);
    assert.match(result.stderr, /carries a ext4 signature/);
    assert.match(result.stderr, /apply stopped during: final safety re-check/);
    assert.doesNotMatch(f.calls(), /^sgdisk /m, 'the partition table was never written');
  } finally { f.cleanup(); }
});

test('apply reports where it stopped when a step fails and wipes nothing', () => {
  const f = fixture('warehouse-disk-partial-');
  try {
    writeFileSync(join(f.bin, 'mkfs.ext4'), '#!/bin/sh\necho "mkfs.ext4 $*" >> "$FAKE_LOG"\nexit 1\n', { mode: 0o755 });
    const result = f.run(APPLY);
    assert.equal(result.status, 1);
    assert.match(result.stderr, /apply stopped during: formatting \/dev\/sdb1/);
    assert.match(result.stderr, /Nothing was wiped or undone automatically/);
    assert.doesNotMatch(f.calls(), /wipefs|--zap-all/);
  } finally { f.cleanup(); }
});

test('status distinguishes prepared, unmounted and dangerous mount points', () => {
  const f = fixture('warehouse-disk-status-');
  try {
    f.mountDisk();
    writeFileSync(f.fstab, `UUID=aaaa-bbbb / ext4 defaults 0 1\nUUID=1 ${f.mount} ext4 defaults,nofail 0 2\n`);
    assert.match(f.run(['status']).stdout, /prepared and mounted at/);
    writeFileSync(f.fstab, 'UUID=aaaa-bbbb / ext4 defaults 0 1\n');
    assert.match(f.run(['status']).stdout, /no entry for it; it will be missing after a reboot/);
    rmSync(join(f.fake, 'mounted'));
    writeFileSync(join(f.mount, 'leftover'), 'x');
    assert.match(f.run(['status']).stdout, /DANGER/);
    rmSync(join(f.mount, 'leftover'));
    rmSync(join(f.mount, '.warehouse-backup-disk'));
    writeFileSync(f.fstab, `UUID=aaaa-bbbb / ext4 defaults 0 1\nUUID=1 ${f.mount} ext4 defaults,nofail 0 2\n`);
    assert.match(f.run(['status']).stdout, /prepared but not mounted/);
  } finally { f.cleanup(); }
});

function withBackups(f, count = 1) {
  const names = [];
  for (let i = 1; i <= count; i += 1) {
    const name = `warehouse-2026010${i}T000000Z`;
    makeBackup(join(f.state, 'backups', name), { env: composeEnv(f.state) });
    names.push(name);
  }
  return names;
}
const syncEnv = f => ({ FAKE_UID: String(process.getuid()), FAKE_CATALOG_FILE: join(f.state, 'backups', readdirSync(join(f.state, 'backups'))[0], 'storage_objects.txt') });

test('sync refuses a mount point that is not a prepared second disk', () => {
  const cases = [
    ['not mounted', f => {}, /is not mounted/],
    ['no marker', f => f.mountDisk({ marker: null }), /missing \.warehouse-backup-disk/],
    ['marker for another disk', f => f.mountDisk({ marker: 'OTHER' }), /UUID mismatch/],
    ['same device as the data', f => { f.mountDisk(); f.put('majmin.mount', '8:2\n'); }, /same device as the operator data/],
    ['wrong mode', f => { f.mountDisk(); chmodSync(f.mount, 0o755); }, /owned by the installation user with mode 0700/],
  ];
  for (const [label, arrange, expected] of cases) {
    const f = fixture('warehouse-sync-refuse-');
    try {
      withBackups(f);
      mkdirSync(f.mount, { recursive: true, mode: 0o700 });
      arrange(f);
      const result = f.run(['sync', '--skip-verify-restore'], syncEnv(f));
      assert.equal(result.status, 1, `${label}: ${result.stdout}`);
      assert.match(result.stderr, expected, label);
      assert.equal(existsSync(join(f.mount, 'state')), false, `${label}: nothing written`);
    } finally { f.cleanup(); }
  }
});

test('sync copies every backup, verifies the copies and the restore, and warns about credentials', () => {
  const f = fixture('warehouse-sync-ok-');
  try {
    const [first, second] = withBackups(f, 2);
    f.mountDisk();
    const result = f.run(['sync'], syncEnv(f));
    assert.equal(result.status, 0, result.stderr + result.stdout);
    for (const name of [first, second]) {
      const copy = join(f.mount, 'state', name);
      assert.ok(existsSync(join(copy, 'SHA256SUMS')), `${name} copied`);
      assert.equal(statSync(copy).mode & 0o777, 0o700);
      assert.equal(statSync(join(copy, 'compose.env')).mode & 0o777, 0o600);
      assert.equal(spawnSync('sha256sum', ['-c', '--quiet', 'SHA256SUMS'], { cwd: copy }).status, 0);
    }
    assert.deepEqual(readdirSync(join(f.mount, 'state')).filter(n => n.startsWith('.sync-staging')), [], 'no staging directory left');
    assert.match(result.stdout, /copied=2 already-present=0 failed=0/);
    assert.match(result.stdout, /compose\.env, which holds every credential/);
    assert.match(result.stdout, /not replace an encrypted off-host copy/);
    assert.match(f.dockerCalls(), /run /, 'verify-restore ran against the copy');
    assert.equal(readdirSync(join(f.state, 'backups')).length, 2, 'the source is never touched');
    const again = f.run(['sync'], syncEnv(f));
    assert.equal(again.status, 0, again.stderr);
    assert.match(again.stdout, /copied=0 already-present=2 failed=0/);
  } finally { f.cleanup(); }
});

test('sync --skip-verify-restore never calls docker', () => {
  const f = fixture('warehouse-sync-skip-');
  try {
    withBackups(f); f.mountDisk();
    const result = f.run(['sync', '--skip-verify-restore'], syncEnv(f));
    assert.equal(result.status, 0, result.stderr);
    assert.equal(f.dockerCalls(), '');
  } finally { f.cleanup(); }
});

test('sync keeps nothing from a tampered source and never overwrites a corrupt copy', () => {
  const f = fixture('warehouse-sync-bad-');
  try {
    const [name] = withBackups(f);
    f.mountDisk();
    writeFileSync(join(f.state, 'backups', name, 'database.dump'), 'tampered\n');
    const tampered = f.run(['sync', '--skip-verify-restore'], syncEnv(f));
    assert.equal(tampered.status, 1);
    assert.match(tampered.stderr, /already fails its checksums/);
    assert.equal(existsSync(join(f.mount, 'state', name)), false);

    const g = fixture('warehouse-sync-corrupt-');
    try {
      const [good] = withBackups(g); g.mountDisk();
      assert.equal(g.run(['sync', '--skip-verify-restore'], syncEnv(g)).status, 0);
      writeFileSync(join(g.mount, 'state', good, 'database.dump'), 'bit rot\n');
      const result = g.run(['sync', '--skip-verify-restore'], syncEnv(g));
      assert.equal(result.status, 1);
      assert.match(result.stderr, /copy of .* on the backup disk is corrupt; it was not overwritten/);
      assert.equal(readFileSync(join(g.mount, 'state', good, 'database.dump'), 'utf8'), 'bit rot\n', 'left exactly as found');
    } finally { g.cleanup(); }
  } finally { f.cleanup(); }
});

test('sync cleans up a failed copy, rejects symlinks and removes leftover staging directories', () => {
  const f = fixture('warehouse-sync-fail-');
  try {
    const [name, linked] = withBackups(f, 2);
    f.mountDisk();
    symlinkSync('/etc/hostname', join(f.state, 'backups', linked, 'evil-link'));
    mkdirSync(join(f.mount, 'state/.sync-staging.OLD1'), { recursive: true });
    const result = f.run(['sync', '--skip-verify-restore'], { ...syncEnv(f), FAKE_CP_FAIL: 'yes' });
    assert.equal(result.status, 1);
    assert.match(result.stderr, /copy of .* failed/);
    assert.match(result.stderr, /contains symbolic links/);
    assert.match(result.stdout, /Removing leftovers of an interrupted sync/);
    assert.deepEqual(readdirSync(join(f.mount, 'state')).filter(n => n.startsWith('warehouse-') || n.startsWith('.sync-staging')), [], 'no partial copy or staging directory remains');
    assert.ok(existsSync(join(f.state, 'backups', name)));
  } finally { f.cleanup(); }
});

test('sync refuses while another operator command holds the state lock', () => {
  const f = fixture('warehouse-sync-lock-');
  let holder;
  try {
    withBackups(f); f.mountDisk();
    const lockfile = join(f.state, 'config/operator.lock');
    holder = spawn('flock', [lockfile, 'sleep', '30'], { stdio: 'ignore', detached: true });
    for (let i = 0; i < 100 && spawnSync('flock', ['-n', lockfile, 'true']).status === 0; i += 1) pause(50);
    const result = f.run(['sync', '--skip-verify-restore'], syncEnv(f));
    assert.equal(result.status, 1);
    assert.match(result.stderr, /Another operator/);
    assert.equal(existsSync(join(f.mount, 'state')), false, 'nothing copied while locked');
  } finally {
    if (holder) { try { process.kill(-holder.pid, 'SIGKILL'); } catch { /* already gone */ } }
    f.cleanup();
  }
});

test('the helper documents itself and rejects unknown subcommands', () => {
  const f = fixture('warehouse-disk-usage-');
  try {
    const result = f.run(['frobnicate']);
    assert.equal(result.status, 1);
    assert.match(result.stderr, /Usage: backup-disk\.sh status \| plan/);
  } finally { f.cleanup(); }
});
