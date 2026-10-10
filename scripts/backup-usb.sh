#!/usr/bin/env bash
# Copy verified backups to an operator-attached exFAT USB drive, automatically when it is attached.
#   setup --state DIR [--enroll DEV] [--daily] [--no-fresh-backup] [--encrypt]
#                          root (sudo): install the udev rule, systemd units and root helper; enroll a drive
#   enroll --device DEV    root: allow another drive (writes a signed enrolment marker onto it)
#   uninstall              root: remove the rule, units, helper and configuration; drives are untouched
#   status                 installation user, read-only: installation, enrolled drives, last result
#   run --device NAME      installation user (the service runs this): fresh backup, copy, verify, record
#   mount NAME | unmount NAME | scan
#                          root, run by systemd from the installed helper copy
# Only enrolled drives receive a backup. Enrolment is not the volume serial alone, which is 32 bits
# and can be copied: enroll writes warehouse-backups/.drive-enrolment onto the drive, an HMAC made
# with the backup key (<state>/config/backup.key) over the filesystem UUID, the partition UUID and
# the instance id, and run copies nothing unless that marker verifies for the drive it is on.
# The drive is never partitioned or formatted and nothing outside warehouse-backups/ is touched.
# Archives are signed with the backup key. They are encrypted only when WAREHOUSE_BACKUP_ENCRYPT=1
# (setup --encrypt); otherwise they are readable and contain compose.env, which holds every credential.
set -euo pipefail
umask 077
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SELF="$(realpath "${BASH_SOURCE[0]}")"
# The overrides below exist for the test suite; status prints them when set.
ETC="${WAREHOUSE_USB_BACKUP_ETC:-/etc}"
LIBEXEC="${WAREHOUSE_USB_BACKUP_LIBEXEC:-/usr/local/libexec}"
RUNDIR="${WAREHOUSE_USB_BACKUP_RUN:-/run/warehouse-usb-backup}"
SETTLE="${WAREHOUSE_USB_BACKUP_SETTLE:-5}"
LOCK_WAIT="${WAREHOUSE_USB_BACKUP_LOCK_WAIT:-900}"
CONF="$ETC/warehouse-usb-backup.conf"
DRIVES="$ETC/warehouse-usb-backup.drives"
RULE="$ETC/udev/rules.d/90-warehouse-usb-backup.rules"
UNITS="$ETC/systemd/system"
HELPER="$LIBEXEC/warehouse-usb-backup"
UNIT=warehouse-usb-backup
TOP=warehouse-backups
ENROLMENT=.drive-enrolment
LAST_ERR=''
RECORDED=1
TMPDIRS=()

die() { LAST_ERR="$*"; echo "$*" >&2; exit 1; }
usage() {
  die 'Usage: backup-usb.sh setup --state DIR [--enroll DEV] [--daily] [--no-fresh-backup] [--encrypt] | enroll --device DEV | uninstall | status | run --device NAME | mount NAME | unmount NAME | scan'
}
kv() { sed -n "s/.*\\b$2=\"\\([^\"]*\\)\".*/\\1/p" <<<"$1" | head -n1; }
conf_get() { [[ -f "$CONF" ]] || return 0; sed -n "s/^$1=//p" "$CONF" | head -n1; }
require_root() { [[ "$(id -u)" == 0 ]] || die "$1 needs root; run: sudo bash scripts/backup-usb.sh $1 ..."; }
kname() { local n="${1#/dev/}"; [[ "$n" =~ ^sd[a-z]+[0-9]*$ ]] || die "$1 is not a USB disk or partition name such as sdb1."; printf '%s\n' "$n"; }

# Sets D_UUID and D_PARTUUID for a USB-attached, writable exFAT filesystem; dies with the reason otherwise.
# D_PARTUUID is '-' for a filesystem written to the whole disk, which has no partition entry.
D_UUID=''
D_PARTUUID=''
probe_drive() {
  local name="$1" row type parent tran
  row="$(lsblk -dnP -o NAME,TYPE,FSTYPE,UUID,RO,PKNAME,PARTUUID "/dev/$name" 2>/dev/null | head -n1 || true)"
  [[ -n "$row" ]] || die "/dev/$name is not attached."
  type="$(kv "$row" TYPE)"; parent="$(kv "$row" PKNAME)"
  [[ "$type" == part || "$type" == disk ]] || die "/dev/$name is a $type, not a disk or partition."
  [[ "$type" == disk ]] && parent="$name"
  tran="$(lsblk -dn -o TRAN "/dev/$parent" 2>/dev/null | tr -d ' ' || true)"
  [[ "$tran" == usb ]] || die "/dev/$name is not on a USB drive (transport: ${tran:-none})."
  [[ "$(kv "$row" FSTYPE)" == exfat ]] || die "/dev/$name is not exFAT (found: $(kv "$row" FSTYPE)); format the drive exFAT on any computer first."
  [[ "$(kv "$row" RO)" == 0 ]] || die "/dev/$name is read-only."
  D_UUID="$(kv "$row" UUID)"
  [[ -n "$D_UUID" ]] || die "/dev/$name has no filesystem UUID."
  D_PARTUUID="$(kv "$row" PARTUUID)"
  [[ -n "$D_PARTUUID" ]] || D_PARTUUID=-
  [[ "$D_UUID" =~ ^[A-Za-z0-9-]+$ && "$D_PARTUUID" =~ ^[A-Za-z0-9-]+$ ]] || die "/dev/$name reports an unusable filesystem or partition UUID."
}
# The root-only list holds one "<filesystem UUID> <partition UUID>" line per enrolled drive.
enrolled() { [[ -f "$DRIVES" ]] && grep -qxF -- "$D_UUID $D_PARTUUID" "$DRIVES"; }
not_enrolled() {
  if [[ -f "$DRIVES" ]] && grep -qxF -- "$D_UUID" "$DRIVES"; then
    die "Drive $D_UUID (/dev/$1) was enrolled by an earlier release, by its volume serial only. Enroll it again: sudo bash scripts/backup-usb.sh enroll --device /dev/$1"
  fi
  die "Drive $D_UUID (/dev/$1) is not enrolled; $2"
}
load_backup_key_lib() {
  local lib="$ROOT/scripts/backup-key.sh"
  [[ -f "$lib" ]] || lib="$(conf_get CHECKOUT)/scripts/backup-key.sh"
  [[ -f "$lib" ]] || die 'scripts/backup-key.sh is missing from the checkout.'
  # shellcheck source=scripts/backup-key.sh
  source "$lib"
}
# The text the enrolment marker signs: this drive, this partition, this instance.
enrolment_hmac() { printf '%s\n%s\n%s\n' "$D_UUID" "$D_PARTUUID" "$2" | backup_hmac "$1" warehouse-usb-enrolment-v1; }
instance_id_of() { sed -n 's/.*"instanceId"[^"]*"\([^"]*\)".*/\1/p' "$1/public/instance.json" 2>/dev/null | head -n1 || true; }

# ---------------------------------------------------------------- root: installation
write_rule() {
  local tmp uuid
  (umask 022; mkdir -p "$(dirname "$RULE")")
  tmp="$(mktemp "$RULE.XXXXXX")"
  {
    echo '# Managed by scripts/backup-usb.sh: attaching an enrolled drive starts a warehouse backup.'
    while read -r uuid _; do
      [[ "$uuid" =~ ^[A-Za-z0-9-]+$ ]] || continue
      printf 'ACTION=="add", SUBSYSTEM=="block", ENV{ID_BUS}=="usb", ENV{ID_FS_TYPE}=="exfat", ENV{ID_FS_UUID}=="%s", TAG+="systemd", ENV{SYSTEMD_WANTS}+="%s@%%k.service"\n' "$uuid" "$UNIT"
    done < "$DRIVES"
  } > "$tmp"
  chmod 0644 "$tmp"; mv -f -- "$tmp" "$RULE"
  udevadm control --reload-rules
}

# Mounts /dev/NAME privately for the installation user and prints the mount point.
mount_private() {
  local name="$1" uid gid mp
  uid="$(conf_get UID)"; gid="$(conf_get GID)"
  [[ "$uid" =~ ^[1-9][0-9]*$ && "$gid" =~ ^[0-9]+$ ]] || die "$CONF has no valid UID/GID; run setup again."
  mkdir -p -m 0755 "$RUNDIR"
  mp="$RUNDIR/$name"
  mkdir -p -m 0700 "$mp"
  mount -t exfat -o "nosuid,nodev,noexec,uid=$uid,gid=$gid,fmask=0177,dmask=0077,errors=remount-ro" "/dev/$name" "$mp"
  printf '%s\n' "$mp"
}

do_enroll() {
  local name state instance mp ours=0 tmp mac
  name="$(kname "$1")"
  probe_drive "$name"
  state="$(conf_get STATE)"
  [[ -n "$state" && -d "$state/config" ]] || die "$CONF names no operator state; run setup again."
  load_backup_key_lib
  [[ -f "$state/config/backup.key" ]] || die "The backup key $state/config/backup.key does not exist yet. As the installation user run: npm run db:backup (it creates the key), then enroll the drive again."
  backup_key_load "$state/config/backup.key" || exit 1
  instance="$(instance_id_of "$state")"
  [[ -n "$instance" ]] || die "$state/public/instance.json has no instanceId."
  # The marker is written onto the drive itself, so it must be mounted for a moment.
  mp="$(findmnt -n -o TARGET -S "/dev/$name" 2>/dev/null | head -n1 || true)"
  if [[ -z "$mp" ]]; then mp="$(mount_private "$name")"; ours=1; fi
  mac="$(enrolment_hmac "$BACKUP_KEY" "$instance")" || die 'Could not sign the enrolment marker.'
  tmp="$mp/$TOP/$ENROLMENT.partial"
  if ! { mkdir -p -- "$mp/$TOP" &&
         printf 'warehouse-usb-enrolment-v1\nfs_uuid=%s\npart_uuid=%s\ninstance_id=%s\nhmac=%s\n' "$D_UUID" "$D_PARTUUID" "$instance" "$mac" > "$tmp" &&
         mv -f -- "$tmp" "$mp/$TOP/$ENROLMENT"; }; then
    # Never leave the drive mounted by a failed enrolment.
    if ((ours)); then umount -- "$mp" || true; rmdir -- "$mp" 2>/dev/null || true; fi
    die "Could not write the enrolment marker onto /dev/$name; the drive was not enrolled."
  fi
  sync -f "$mp/$TOP/$ENROLMENT" 2>/dev/null || sync
  if ((ours)); then umount -- "$mp"; rmdir -- "$mp" 2>/dev/null || true; fi
  # One line per drive; a line left by an earlier release (the bare volume serial) is replaced.
  tmp="$(mktemp "$DRIVES.XXXXXX")"
  { grep -v -E -- "^$D_UUID( |\$)" "$DRIVES" 2>/dev/null || true; printf '%s %s\n' "$D_UUID" "$D_PARTUUID"; } > "$tmp"
  chmod 0600 "$tmp"; chown root:root "$tmp"; mv -f -- "$tmp" "$DRIVES"
  echo "Enrolled drive $D_UUID (/dev/$name, partition $D_PARTUUID) and wrote its signed enrolment marker."
  write_rule
}

safe_path() { [[ "$1" == /* && "$1" != *[[:space:]%\\\"\']* ]] || die "$2 must be an absolute path without spaces, quotes or %: $1"; }

cmd_setup() {
  local state='' enroll='' daily=no fresh=yes encrypt=no uid gid user group old
  while (($#)); do
    case "$1" in
      --state) (($# > 1)) || usage; state="$2"; shift 2 ;;
      --enroll) (($# > 1)) || usage; enroll="$2"; shift 2 ;;
      --daily) daily=yes; shift ;;
      --no-fresh-backup) fresh=no; shift ;;
      --encrypt) encrypt=yes; shift ;;
      *) usage ;;
    esac
  done
  require_root setup
  uid="${SUDO_UID:-}"; gid="${SUDO_GID:-}"
  [[ "$uid" =~ ^[1-9][0-9]*$ && "$gid" =~ ^[0-9]+$ ]] || die 'Run setup through sudo from the installation user (SUDO_UID is missing or 0); the backup must not run as root.'
  user="$(getent passwd "$uid" | cut -d: -f1)"; group="$(getent group "$gid" | cut -d: -f1)"
  [[ -n "$user" && -n "$group" ]] || die "Cannot resolve user $uid or group $gid."
  [[ -n "$state" ]] || die 'setup needs --state /absolute/path/to/the/warehouse/state.'
  safe_path "$state" 'The state directory'; safe_path "$ROOT" 'The checkout'
  [[ "$(realpath -m "$state")" == "$state" && -d "$state" && -f "$state/config/compose.env" ]] || die "$state is not an installed operator state (no symlinks, needs config/compose.env)."
  [[ "$(stat -c %u -- "$state")" == "$uid" ]] || die "$state is not owned by $user."
  [[ "$(stat -c %u -- "$ROOT")" == "$uid" ]] || die "The checkout $ROOT is not owned by $user."
  # The helper copy runs as root, so its source must not be writable by anyone but its owner.
  [[ "$(stat -c %a -- "$SELF")" =~ ^[0-7][0145][0145]$ && "$(stat -c %a -- "$ROOT/scripts")" =~ ^[0-7][0145][0145]$ ]] || die "$SELF or its directory is group- or world-writable (a git pull under umask 0002 does this). As $user run: bash $ROOT/scripts/checkout-permissions.sh, then this setup again."
  old="$(conf_get STATE)"
  [[ -z "$old" || "$old" == "$state" ]] || die "USB backup is already set up for $old; run uninstall first."

  # System directories created here must stay world-readable: under umask 077 a new
  # /usr/local/libexec became 0700, and the Docker CLI, which searches
  # /usr/local/libexec/docker/cli-plugins first, then failed every plugin with EACCES.
  (umask 022; mkdir -p "$LIBEXEC" "$UNITS")
  install -m 0755 -- "$SELF" "$HELPER"; chown root:root "$HELPER"
  local tmp; tmp="$(mktemp "$CONF.XXXXXX")"
  printf 'STATE=%s\nCHECKOUT=%s\nUSER=%s\nUID=%s\nGID=%s\nFRESH_BACKUP=%s\nDAILY=%s\nENCRYPT=%s\n' "$state" "$ROOT" "$user" "$uid" "$gid" "$fresh" "$daily" "$encrypt" > "$tmp"
  chmod 0644 "$tmp"; mv -f -- "$tmp" "$CONF"
  # The enrolment list names the drives; only root reads it.
  [[ -f "$DRIVES" ]] || : > "$DRIVES"
  chmod 0600 "$DRIVES"; chown root:root "$DRIVES"

  cat > "$UNITS/$UNIT@.service" <<EOF
[Unit]
Description=Warehouse backup to USB drive %I
Wants=docker.service
After=docker.service

[Service]
Type=oneshot
User=$user
Group=$group
Environment=WAREHOUSE_STATE_DIR=$state
Environment=WAREHOUSE_USB_BACKUP_FRESH=$fresh
Environment=WAREHOUSE_BACKUP_ENCRYPT=$([[ "$encrypt" == yes ]] && echo 1 || echo 0)
ExecStartPre=+$HELPER mount %I
ExecStart=/bin/bash $ROOT/scripts/backup-usb.sh run --device %I
ExecStopPost=+$HELPER unmount %I
TimeoutStartSec=2h
EOF
  cat > "$UNITS/$UNIT-scan.service" <<EOF
[Unit]
Description=Start warehouse USB backups for attached enrolled drives

[Service]
Type=oneshot
ExecStart=$HELPER scan
EOF
  cat > "$UNITS/$UNIT.timer" <<EOF
[Unit]
Description=Daily warehouse USB backup for a drive that stays attached

[Timer]
OnCalendar=daily
RandomizedDelaySec=30min
Persistent=true
Unit=$UNIT-scan.service

[Install]
WantedBy=timers.target
EOF
  chmod 0644 "$UNITS/$UNIT@.service" "$UNITS/$UNIT-scan.service" "$UNITS/$UNIT.timer"
  systemctl daemon-reload
  if [[ -n "$enroll" ]]; then do_enroll "$enroll"; else write_rule; fi
  if [[ "$daily" == yes ]]; then systemctl enable --now "$UNIT.timer"; else systemctl disable --now "$UNIT.timer" >/dev/null 2>&1 || true; fi

  echo "USB backup is set up for $state, running as $user (fresh backup on attach: $fresh, daily timer: $daily, encrypted archives: $encrypt)."
  if [[ "$encrypt" == yes ]]; then
    echo "Archives are encrypted with the backup key $state/config/backup.key. Without a copy of that key, kept away from this machine and from the drive, the archives cannot be restored after the host is lost."
  else
    echo 'Archives are NOT encrypted. Run setup again with --encrypt to encrypt them with the backup key (keep a copy of the key off this machine first).'
  fi
  [[ -s "$DRIVES" ]] || echo 'No drive is enrolled yet: attach the exFAT USB drive and run: sudo bash scripts/backup-usb.sh enroll --device /dev/sdX1'
  echo "From now on, attaching an enrolled drive runs the backup; it is unmounted when done."
  echo "Watch a run:  journalctl -f -u '$UNIT@*'      Last result:  bash scripts/backup-usb.sh status"
  echo 'After updating this checkout, run setup again so the installed root helper matches it.'
}

cmd_enroll() {
  local dev=''
  while (($#)); do case "$1" in --device) (($# > 1)) || usage; dev="$2"; shift 2 ;; *) usage ;; esac; done
  [[ -n "$dev" ]] || usage
  require_root enroll
  [[ -f "$CONF" ]] || die 'USB backup is not set up; run setup first.'
  do_enroll "$dev"
}

cmd_uninstall() {
  require_root uninstall
  systemctl disable --now "$UNIT.timer" >/dev/null 2>&1 || true
  rm -f -- "$RULE" "$UNITS/$UNIT@.service" "$UNITS/$UNIT-scan.service" "$UNITS/$UNIT.timer" "$HELPER" "$CONF" "$DRIVES"
  systemctl daemon-reload
  udevadm control --reload-rules
  echo 'USB backup automation removed. Drives and the archives on them were not touched.'
}

# ---------------------------------------------------------------- root: called by systemd
cmd_mount() {
  local name mp existing i
  name="$(kname "${1:-}")"
  require_root mount
  probe_drive "$name"
  enrolled || not_enrolled "$name" 'nothing mounted.'
  # A desktop session may be mounting it at the same moment; use that mount if it appears.
  for ((i = 0; i <= SETTLE; i++)); do
    existing="$(findmnt -n -o TARGET -S "/dev/$name" 2>/dev/null | head -n1 || true)"
    [[ -z "$existing" ]] || { echo "Using the existing mount $existing for /dev/$name."; return 0; }
    ((i == SETTLE)) || sleep 1
  done
  mp="$(mount_private "$name")"
  echo "Mounted /dev/$name at $mp."
}

cmd_unmount() {
  local name targets t ours=0 failed=0
  name="$(kname "${1:-}")"
  require_root unmount
  # Unmount every mount of an enrolled drive so it is safe to remove; otherwise only our own mount.
  if ( probe_drive "$name" >/dev/null 2>&1 && enrolled ) 2>/dev/null; then
    targets="$(findmnt -n -o TARGET -S "/dev/$name" 2>/dev/null || true)"
  else
    ours=1; targets=''
    [[ ! -d "$RUNDIR/$name" ]] || targets="$(findmnt -n -o TARGET --mountpoint "$RUNDIR/$name" 2>/dev/null || true)"
  fi
  sync
  while IFS= read -r t; do
    [[ -n "$t" ]] || continue
    umount -- "$t" || { echo "Could not unmount $t; close any window or terminal using it." >&2; failed=1; }
  done <<<"$targets"
  [[ ! -d "$RUNDIR/$name" ]] || rmdir -- "$RUNDIR/$name" 2>/dev/null || true
  ((failed == 0)) || exit 1
  if ((ours == 0)); then echo "/dev/$name is unmounted; it is safe to remove the drive."; fi
}

cmd_scan() {
  local uuid name started=0
  require_root scan
  [[ -f "$DRIVES" ]] || die 'No drives are enrolled.'
  while read -r uuid _; do
    [[ -n "$uuid" ]] || continue
    name="$(lsblk -nr -o NAME,UUID 2>/dev/null | awk -v u="$uuid" '$2 == u { print $1; exit }')"
    [[ -n "$name" ]] || continue
    systemctl start --no-block "$UNIT@$name.service"; started=$((started + 1))
    echo "Started the backup for drive $uuid (/dev/$name)."
  done < "$DRIVES"
  ((started)) || echo 'No enrolled drive is attached.'
}

# ---------------------------------------------------------------- installation user
STATE=''; RESULT_FILE=''; DEST=''; DEVICE=''; ENCRYPT=0
COPIED=0; PRESENT=0; FAILED=0; FAILURES=''
fail() { echo "FAILED: $*" >&2; FAILED=$((FAILED + 1)); FAILURES="${FAILURES:+$FAILURES; }$*"; }

# Hash a file as stored on the drive: direct I/O bypasses the page cache where the filesystem allows it.
media_hash() {
  local h
  h="$(dd if="$1" iflag=direct bs=1M status=none 2>/dev/null | sha256sum | cut -d' ' -f1)" || h=''
  [[ "$h" == "$(printf '' | sha256sum | cut -d' ' -f1)" && -s "$1" ]] && h=''
  [[ -n "$h" ]] || h="$(sha256sum < "$1" | cut -d' ' -f1)"
  printf '%s\n' "$h"
}
# An archive is good when it matches its checksum and, where it has one, its signature.
# Archives written before signing have no .hmac file; an encrypted archive always needs one.
archive_ok() {
  [[ -f "$1.sha256" ]] && [[ "$(media_hash "$1")" == "$(cut -d' ' -f1 "$1.sha256")" ]] || return 1
  if [[ -e "$1.hmac" || "$1" == *.enc ]]; then backup_check_archive "$1" "$BACKUP_KEY" || return 1; fi
}

record() {
  local result="$1" message="$2" now last_ok tmp report
  now="$(date +%s)"
  last_ok="$(sed -n 's/^last_success_epoch=//p' "$RESULT_FILE" 2>/dev/null | head -n1 || true)"
  [[ "$result" != ok ]] || last_ok="$now"
  report="$(printf 'result=%s\nfinished_utc=%s\nfinished_epoch=%s\nlast_success_epoch=%s\ndrive_uuid=%s\ndevice=%s\ncopied=%s\nalready_present=%s\nfailed=%s\nmessage=%s\n' \
    "$result" "$(date -u -d "@$now" +%Y-%m-%dT%H:%M:%SZ)" "$now" "$last_ok" "$D_UUID" "$DEVICE" "$COPIED" "$PRESENT" "$FAILED" "${message//$'\n'/ }")"
  tmp="$(mktemp "$STATE/config/.usb-backup.last.XXXXXX")"
  printf '%s\n' "$report" > "$tmp"; mv -f -- "$tmp" "$RESULT_FILE"
  if [[ -n "$DEST" && -d "$DEST" && -w "$DEST" ]]; then
    { printf '%s\n' "$report"
      if ((ENCRYPT)); then
        echo 'Archives written by this run are encrypted with the backup key of the installation (config/backup.key).'
        echo 'Without a copy of that key they cannot be restored. Archives named .tar (not .tar.enc) are NOT encrypted.'
      else
        echo 'These archives are NOT encrypted and contain every credential of the instance. Keep this drive locked away;'
        echo 'if it is lost, run ./rotate-keys.sh --yes on the server and take a new backup.'
      fi
    } > "$DEST/.LAST-RESULT.txt.partial" 2>/dev/null && mv -f -- "$DEST/.LAST-RESULT.txt.partial" "$DEST/LAST-RESULT.txt" 2>/dev/null || true
  fi
  RECORDED=1
}
on_run_exit() {
  local status=$?
  local d
  for d in "${TMPDIRS[@]}"; do [[ ! -d "$d" ]] || rm -rf -- "$d"; done
  ((RECORDED)) || record failed "${LAST_ERR:-run stopped unexpectedly (exit $status)}"
  exit "$status"
}

cmd_run() {
  local name mp data_mm mp_mm label b n archive need avail hash newest tmp instance_id id_file marker recorded suffix other plain=0
  while (($#)); do case "$1" in --device) (($# > 1)) || usage; DEVICE="$2"; shift 2 ;; *) usage ;; esac; done
  [[ -n "$DEVICE" ]] || usage
  [[ "$(id -u)" != 0 ]] || die 'run copies as the installation user, never as root.'
  # shellcheck source=scripts/operator-lock.sh
  source "$ROOT/scripts/operator-lock.sh"
  STATE="$(operator_state)" || exit 1
  RESULT_FILE="$STATE/config/usb-backup.last"
  RECORDED=0
  trap on_run_exit EXIT
  name="$(kname "$DEVICE")"; DEVICE="/dev/$name"
  probe_drive "$name"
  [[ "${WAREHOUSE_BACKUP_ENCRYPT:-0}" != 1 ]] || ENCRYPT=1
  mp="$(findmnt -n -o TARGET -S "$DEVICE" 2>/dev/null | head -n1 || true)"
  [[ -n "$mp" ]] || die "$DEVICE is not mounted."
  [[ "$(findmnt -n -o FSTYPE --mountpoint "$mp" 2>/dev/null || true)" == exfat ]] || die "$mp is not an exFAT mount."
  data_mm="$(findmnt -n -o MAJ:MIN -T "$STATE/data" 2>/dev/null | tr -d ' ' || true)"; mp_mm="$(findmnt -n -o MAJ:MIN -T "$mp" 2>/dev/null | tr -d ' ' || true)"
  [[ -n "$mp_mm" && "$mp_mm" != "$data_mm" ]] || die "$mp is on the same device as the operator data; copying there protects nothing."
  [[ -w "$mp" ]] || die "$mp is not writable by $(id -un)."
  # Enrolment: the marker on the drive must be the HMAC, under this installation's backup key, of
  # this drive's filesystem UUID, partition UUID and this instance. A drive that only imitates the
  # volume serial of an enrolled one has no such marker, and nothing is backed up or copied.
  load_backup_key_lib
  instance_id="$(instance_id_of "$STATE")"
  marker="$mp/$TOP/$ENROLMENT"
  recorded=''
  if [[ -f "$marker" && ! -L "$marker" ]]; then recorded="$(sed -n 's/^hmac=//p' "$marker" | head -n1)"; fi
  if [[ ! -f "$STATE/config/backup.key" || -z "$instance_id" || -z "$recorded" ]] || ! backup_key_load "$STATE/config/backup.key" 2>/dev/null ||
     [[ "$recorded" != "$(enrolment_hmac "$BACKUP_KEY" "$instance_id")" ]]; then
    die "Drive $D_UUID ($DEVICE) is not enrolled for this installation (no valid enrolment marker for this drive); nothing was copied. Run: sudo bash scripts/backup-usb.sh enroll --device $DEVICE"
  fi
  echo "Backing up to drive $D_UUID ($DEVICE, mounted at $mp)."

  if [[ "${WAREHOUSE_USB_BACKUP_FRESH:-yes}" != no ]]; then
    # backup.sh takes the operator lock itself; wait until no other operator command holds it.
    if ( exec 9>"$STATE/config/operator.lock"; flock -w "$LOCK_WAIT" 9 ); then
      echo 'Taking a fresh backup (write-facing services stop briefly).'
      bash "$ROOT/scripts/backup.sh" || fail 'the fresh backup failed; existing backups are still copied'
    else
      fail "another operator command held the lock for ${LOCK_WAIT}s; no fresh backup was taken"
    fi
  fi
  exec 9>"$STATE/config/operator.lock"
  flock -w "$LOCK_WAIT" 9 || die "Another operator command held the lock for ${LOCK_WAIT}s; nothing was copied."

  label="$(basename "$STATE" | tr -c 'A-Za-z0-9._\n-' '_')"
  [[ -n "$label" && "$label" != . && "$label" != .. ]] || die "Cannot derive a safe directory name from $STATE."
  DEST="$mp/$TOP/$label"
  mkdir -p -- "$DEST"
  id_file="$DEST/.instance-id"
  if [[ -f "$id_file" && -n "$instance_id" && "$(cat "$id_file")" != "$instance_id" ]]; then
    die "$DEST belongs to a different instance; nothing was copied."
  fi
  [[ -z "$instance_id" ]] || printf '%s\n' "$instance_id" > "$id_file"
  # The lock is held, so partial files are leftovers of an interrupted run.
  find "$DEST" -maxdepth 1 -name '.*.partial' -type f -delete

  suffix=tar; other=tar.enc
  if ((ENCRYPT)); then suffix=tar.enc; other=tar; fi
  while IFS= read -r b; do
    n="$(basename "$b")"; archive="$DEST/$n.$suffix"
    # An archive written before the encryption setting changed still counts as this backup.
    [[ -e "$archive" || ! -e "$DEST/$n.$other" ]] || archive="$DEST/$n.$other"
    if [[ -e "$archive" ]]; then
      if archive_ok "$archive"; then PRESENT=$((PRESENT + 1)); echo "Already on the drive and verified: ${archive##*/}"
      else fail "the archive of $n on the drive does not match its checksum or signature; it was not overwritten"; fi
      continue
    fi
    [[ -f "$b/SHA256SUMS" && -f "$b/metadata.txt" ]] || { fail "$n is not a complete backup"; continue; }
    [[ -z "$(find "$b" -type l -print -quit)" ]] || { fail "$n contains symbolic links"; continue; }
    (cd "$b" && sha256sum -c --quiet SHA256SUMS >/dev/null 2>&1) || { fail "source backup $n fails its checksums; nothing copied"; continue; }
    need="$(du -sb "$b" | cut -f1)"; avail="$(df -B1 --output=avail "$DEST" | tail -n1 | tr -d ' ')"
    (( avail > need + 67108864 )) || { fail "not enough free space on the drive for $n"; continue; }
    # Hash the stream as it is written, then read the file back from the drive and compare.
    if ! hash="$(tar -C "$STATE/backups" -cf - "$n" | { if ((ENCRYPT)); then backup_encrypt "$BACKUP_KEY"; else cat; fi; } | tee "$DEST/.$n.$suffix.partial" | sha256sum | cut -d' ' -f1)"; then
      rm -f -- "$DEST/.$n.$suffix.partial"; fail "writing the archive of $n failed"; continue
    fi
    sync -f "$DEST/.$n.$suffix.partial" 2>/dev/null || sync
    if [[ "$(media_hash "$DEST/.$n.$suffix.partial")" != "$hash" ]]; then
      rm -f -- "$DEST/.$n.$suffix.partial"; fail "the archive of $n read back from the drive does not match what was written"; continue
    fi
    printf '%s  %s\n' "$hash" "$n.$suffix" > "$DEST/.$n.sha.partial"
    mv -f -- "$DEST/.$n.sha.partial" "$archive.sha256"
    # The signature covers the checksum line, so the archive cannot be swapped with its checksum.
    if ! backup_sign_archive "$archive" "$BACKUP_KEY"; then
      rm -f -- "$DEST/.$n.$suffix.partial" "$archive.sha256" "$archive.hmac"; fail "signing the archive of $n failed"; continue
    fi
    mv -f -- "$DEST/.$n.$suffix.partial" "$archive"
    sync -f "$archive" 2>/dev/null || sync
    COPIED=$((COPIED + 1)); echo "Copied and verified from the drive: ${archive##*/}"
  done < <(find "$STATE/backups" -mindepth 1 -maxdepth 1 -type d -name 'warehouse-*' 2>/dev/null | sort)

  newest="$(find "$DEST" -maxdepth 1 -type f \( -name 'warehouse-*.tar' -o -name 'warehouse-*.tar.enc' \) -printf '%f\n' | sort | tail -n1)"
  n="${newest%.enc}"; n="${n%.tar}"
  if [[ -z "$newest" ]]; then
    fail 'there is no backup on the drive; take one with npm run db:backup'
  elif [[ "${WAREHOUSE_USB_BACKUP_VERIFY_RESTORE:-yes}" != no ]]; then
    tmp="$(mktemp -d "$STATE/.usb-verify.XXXXXX")"; TMPDIRS+=("$tmp")
    if archive_ok "$DEST/$newest" &&
       { if [[ "$newest" == *.enc ]]; then backup_decrypt "$BACKUP_KEY" < "$DEST/$newest" | tar -C "$tmp" -xf -; else tar -C "$tmp" -xf "$DEST/$newest"; fi; } &&
       [[ -f "$tmp/$n/SHA256SUMS.hmac" ]] && bash "$ROOT/scripts/verify-restore.sh" "$tmp/$n"; then
      echo "Restore verification of the copy on the drive passed: $n"
    elif [[ -d "$tmp/$n" && ! -e "$tmp/$n/SHA256SUMS.hmac" ]]; then
      fail "the newest backup on the drive ($n) is unsigned, written by an earlier release, so its restore was not verified; take a new backup with npm run db:backup"
    else
      fail "restore verification of $n from the drive failed"
    fi
    rm -rf -- "$tmp"
  fi
  [[ -z "$(find "$DEST" -maxdepth 1 -type f -name 'warehouse-*.tar' -print -quit)" ]] || plain=1

  echo "Summary: copied=$COPIED already-present=$PRESENT failed=$FAILED. Nothing is deleted on either side; remove old backups yourself."
  if ((ENCRYPT == 0)); then
    echo 'WARNING: the archives are not encrypted and contain every credential of this instance. Keep the drive locked away.'
  elif ((plain)); then
    echo 'WARNING: archives written by this run are encrypted, but the drive still holds unencrypted .tar archives from earlier runs; they contain every credential of this instance. Remove them once you no longer need them.'
  else
    echo "The archives are encrypted with the backup key $STATE/config/backup.key. Keep a copy of that key away from this machine and from the drive: without it they cannot be restored."
  fi
  if ((FAILED)); then record failed "$FAILURES"; exit 1; fi
  record ok "copied $COPIED, already present $PRESENT, restore verified $n"
}

cmd_status() {
  local name uuid state last epoch age
  for v in WAREHOUSE_USB_BACKUP_ETC WAREHOUSE_USB_BACKUP_LIBEXEC WAREHOUSE_USB_BACKUP_RUN; do
    [[ -z "${!v:-}" ]] || echo "Test override in effect: $v=${!v}"
  done
  if [[ ! -f "$CONF" ]]; then
    echo 'USB backup is not set up. Run: sudo bash scripts/backup-usb.sh setup --state "$WAREHOUSE_STATE_DIR" --enroll /dev/sdX1'
    return 0
  fi
  state="$(conf_get STATE)"
  echo "Set up for $state as $(conf_get USER) (fresh backup on attach: $(conf_get FRESH_BACKUP), daily timer: $(conf_get DAILY), encrypted archives: $(conf_get ENCRYPT))."
  if [[ -f "$HELPER" ]] && ! cmp -s -- "$HELPER" "$SELF"; then
    echo 'WARNING: the installed root helper differs from this checkout; run setup again.'
  fi
  if [[ ! -r "$DRIVES" ]]; then
    echo 'The list of enrolled drives is readable by root only: sudo bash scripts/backup-usb.sh status'
  else
    [[ -s "$DRIVES" ]] || echo 'No drive is enrolled.'
    while read -r uuid part; do
      [[ -n "$uuid" ]] || continue
      [[ -n "$part" ]] || { echo "Drive $uuid was enrolled by an earlier release and is no longer accepted: enroll it again."; continue; }
      name="$(lsblk -nr -o NAME,UUID 2>/dev/null | awk -v u="$uuid" '$2 == u { print $1; exit }' || true)"
      if [[ -n "$name" ]]; then echo "Enrolled drive $uuid: attached as /dev/$name"; else echo "Enrolled drive $uuid: not attached"; fi
    done < "$DRIVES"
  fi
  last="$state/config/usb-backup.last"
  if [[ -r "$last" ]]; then
    epoch="$(sed -n 's/^last_success_epoch=//p' "$last" | head -n1)"
    echo "Last run: $(sed -n 's/^result=//p' "$last") at $(sed -n 's/^finished_utc=//p' "$last") - $(sed -n 's/^message=//p' "$last")"
    if [[ -n "$epoch" ]]; then age=$(( ($(date +%s) - epoch) / 86400 )); echo "Last successful copy: $age day(s) ago."
    else echo 'No successful copy yet.'; fi
  else
    echo 'No copy has been made yet: attach an enrolled drive.'
  fi
}

sub="${1:-status}"
(($#)) && shift
case "$sub" in
  setup) cmd_setup "$@" ;;
  enroll) cmd_enroll "$@" ;;
  uninstall) cmd_uninstall "$@" ;;
  mount) cmd_mount "$@" ;;
  unmount) cmd_unmount "$@" ;;
  scan) cmd_scan "$@" ;;
  run) cmd_run "$@" ;;
  status) cmd_status "$@" ;;
  -h|--help|help) usage ;;
  *) usage ;;
esac
