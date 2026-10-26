// Shared fixture of the USB backup tests: fake device tools on PATH and a scratch tree for /etc, /usr/local/libexec and /run.
// No test touches a real device, mount, udev rule or systemd unit.
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, existsSync, readdirSync, rmSync, statSync, chmodSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { makeBackup, makeState, fakeDocker, scriptRoot, composeEnv, backupKey, hmacHex, writeEscrow } from './backup-test-helpers.mjs';

export const UUID = '6A38-179A';
export const PART = 'a1b2c3d4-01';
export const INSTANCE = '0f0f0f0f-0f0f-4f0f-8f0f-0f0f0f0f0f0f';
export const devRow = ({ fstype = 'exfat', ro = '0', part = PART } = {}) => `NAME="sdb1" TYPE="part" FSTYPE="${fstype}" UUID="${UUID}" RO="${ro}" PKNAME="sdb" PARTUUID="${part}"\n`;
// The marker `enroll` writes onto a drive: an HMAC under the backup key over the drive and the instance.
export const marker = ({ uuid = UUID, part = PART, instance = INSTANCE, key = backupKey } = {}) =>
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
  // The root helper drops to the installation user with setpriv; the stand-in makes `id -u` answer that uid.
  setpriv: String.raw`#!/bin/sh
uid=''
while [ $# -gt 0 ] && [ "$1" != -- ]; do if [ "$1" = --reuid ]; then uid="$2"; fi; shift; done
shift
echo "setpriv reuid=$uid" >> "$FAKE_LOG"
FAKE_UID="$uid" exec "$@"
`,
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

export function fixture(prefix, { escrow = true } = {}) {
  const scratch = mkdtempSync(join(tmpdir(), prefix));
  const state = makeState(scratch);
  // The operator has confirmed a copy of the backup key (scripts/backup-key-escrow.sh); tests of the gate remove the record.
  if (escrow) writeEscrow(state);
  const root = scriptRoot(scratch);
  chmodSync(join(root, 'scripts'), 0o755);
  for (const name of readdirSync(join(root, 'scripts'))) chmodSync(join(root, 'scripts', name), 0o755);
  const fake = join(scratch, 'fake'); mkdirSync(fake);
  const bin = join(scratch, 'shims'); mkdirSync(bin);
  for (const [name, body] of Object.entries(shims)) writeFileSync(join(bin, name), body, { mode: 0o755 });
  const dockerBin = fakeDocker(join(scratch, 'dockerbin'));
  // A stand-in df for the free-space rules: the drive folder has FAKE_DRIVE_CAP bytes minus what is stored on it (never below
  // zero), the state directory has FAKE_STATE_AVAIL; every other question is the real df's. FAKE_DF_BROKEN=drive|state makes the
  // answer for that place fail, as a df that cannot read the file system does. Put on PATH only by dfEnv().
  const dfBin = join(scratch, 'dfbin'); mkdirSync(dfBin);
  writeFileSync(join(dfBin, 'df'), String.raw`#!/bin/sh
for last; do :; done
case "$last" in
  "$FAKE_MOUNT"/*)
    if [ "$FAKE_DF_BROKEN" = drive ]; then echo 'df: cannot read the file system' >&2; exit 1; fi
    if [ -n "$FAKE_DRIVE_CAP" ]; then used=$(du -sb "$FAKE_MOUNT" | cut -f1); free=$((FAKE_DRIVE_CAP - used)); [ "$free" -ge 0 ] || free=0; printf 'Avail\n%s\n' "$free"; exit 0; fi ;;
  "$FAKE_STATE")
    if [ "$FAKE_DF_BROKEN" = state ]; then echo 'df: cannot read the file system' >&2; exit 1; fi
    if [ -n "$FAKE_STATE_AVAIL" ]; then printf 'Avail\n%s\n' "$FAKE_STATE_AVAIL"; exit 0; fi ;;
esac
exec /usr/bin/df "$@"
`, { mode: 0o755 });
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
    FAKE_DIR: fake, FAKE_LOG: log, FAKE_MOUNT: drive, FAKE_STATE: state, FAKE_UID: String(process.getuid()), FAKE_DOCKER_LOG: dockerLog,
    SUDO_UID: String(process.getuid()), SUDO_GID: String(process.getgid()), ...extra,
  });
  const run = (args, extra = {}) => spawnSync('bash', [join(root, 'scripts/backup-usb.sh'), ...args], { encoding: 'utf8', env: env(extra) });
  const asRoot = (args, extra = {}) => run(args, { FAKE_UID: '0', ...extra });
  const calls = () => readFileSync(log, 'utf8');
  const dockerCalls = () => readFileSync(dockerLog, 'utf8');
  const dest = join(drive, 'warehouse-backups', 'state');
  const last = () => readFileSync(join(state, 'config/usb-backup.last'), 'utf8');
  // Local backups warehouse-202601DDT000000Z for DD = first..first+count-1 (v6 by default, as backup.sh writes them).
  const bname = day => `warehouse-202601${String(day).padStart(2, '0')}T000000Z`;
  const localBackup = (name, options = {}) => makeBackup(join(state, 'backups', name), { env: composeEnv(state), format: 'warehouse-backup-v6', ...options });
  const backups = (count = 1, options = {}, first = 1) => {
    const names = [];
    for (let i = first; i < first + count; i += 1) { localBackup(bname(i), options); names.push(bname(i)); }
    return names;
  };
  const archives = () => (existsSync(dest) ? readdirSync(dest).filter(n => /^warehouse-.*\.tar(\.enc)?$/.test(n)).sort() : []);
  const dfEnv = (extra = {}) => ({ PATH: `${dfBin}:${bin}:${dockerBin}:${process.env.PATH}`, ...extra });
  const verifyEnv = () => ({ FAKE_CATALOG_FILE: join(state, 'backups', readdirSync(join(state, 'backups')).sort()[0], 'storage_objects.txt') });
  return { scratch, state, root, fake, etc, libexec, runDir, drive, dest, run, asRoot, calls, dockerCalls, put, enroll, writeMarker, markerPath, last, backups, bname, localBackup, archives, dfEnv, verifyEnv,
    cleanup: () => rmSync(scratch, { recursive: true, force: true }) };
}

