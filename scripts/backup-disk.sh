#!/usr/bin/env bash
# Prepare a dedicated second disk for backups and copy verified backups onto it.
#   status                     read-only: where backups are and whether a backup disk is ready
#   plan [--device DEV]        read-only: list eligible disks, or show what apply would do
#   apply --device DEV --yes (--confirm-serial SERIAL | --confirm-size BYTES) [--state DIR]
#                              destructive and root-only: partition, format and mount an EMPTY second disk
#   sync [--from DIR] [--skip-verify-restore]
#                              copy every backup to the disk and verify the copies
# Only an empty, unmounted second disk is ever used. The system disk is never touched,
# nothing is resized or wiped, and a partition on the system disk is deliberately not offered:
# it would not survive failure of that disk.
set -euo pipefail
umask 077
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SELF="${BASH_SOURCE[0]}"
# The overrides below exist for the test suite. They are printed by plan so they are never silent.
MOUNT="${WAREHOUSE_BACKUP_DISK_MOUNT:-/srv/warehouse-backups}"
FSTAB="${WAREHOUSE_BACKUP_DISK_FSTAB:-/etc/fstab}"
SYSFS="${WAREHOUSE_BACKUP_DISK_SYSFS:-/sys}"
LABEL=warehouse-backup
MARKER=.warehouse-backup-disk
MIN_BYTES=$((10 * 1024 * 1024 * 1024))
STATE=''
PROBE_STRICT=0
PHASE=''
STAGE=''
FAILED=0
NO_SECOND_DISK='No second disk found. Attach a new empty disk to this host (cloud: create and attach a volume; VMware: add a hard disk, ideally on a different datastore; hardware: install a drive), rescan or reboot, then run plan again. A partition on the system disk is not offered because it would not survive failure of that disk.'

die() { echo "$*" >&2; exit 1; }
usage() {
  die 'Usage: backup-disk.sh status | plan [--device DEV] | apply --device DEV --yes (--confirm-serial SERIAL | --confirm-size BYTES) [--state DIR] | sync [--from DIR] [--skip-verify-restore]'
}
kv() { sed -n "s/.*\\b$2=\"\\([^\"]*\\)\".*/\\1/p" <<<"$1" | head -n1; }
gib() { echo "$(($1 / 1073741824)) GiB"; }

disk_row() { lsblk -dnPb -o NAME,TYPE,SIZE,RM,RO,SERIAL,MODEL,MAJ:MIN,FSTYPE "$1" 2>/dev/null | head -n1 || true; }

# Whole disks that back a device path (follows partitions, LVM and md upward).
disks_of() {
  local row
  while IFS= read -r row; do
    [[ -n "$row" && "$(kv "$row" TYPE)" == disk ]] && echo "/dev/$(kv "$row" NAME)"
  done < <(lsblk -nsP -o NAME,TYPE "$1" 2>/dev/null || true)
}
system_disks() {
  local path src
  for path in / /boot /boot/efi "${STATE:+$STATE/data}"; do
    [[ -n "$path" && -e "$path" ]] || continue
    src="$(findmnt -n -o SOURCE -T "$path" 2>/dev/null || true)"
    [[ "$src" == /dev/* ]] && disks_of "$src"
  done | sort -u
}

fstab_has_mount() { [[ -f "$FSTAB" ]] && awk -v m="$MOUNT" '$1 !~ /^#/ && $2 == m { found = 1 } END { exit found ? 0 : 1 }' "$FSTAB"; }

# Prints the reason and returns 1 when the disk may not be used for backups.
disk_problem() {
  local dev="$1" real row majmin tree line sys sysdisks size need used sig wipe
  real="$(readlink -f -- "$dev" 2>/dev/null || true)"
  if [[ ! "$real" =~ ^/dev/(sd[a-z]+|vd[a-z]+|xvd[a-z]+|nvme[0-9]+n[0-9]+)$ ]]; then
    echo "$dev is not a whole sdX, vdX, xvdX or nvmeXnY disk."; return 1
  fi
  row="$(disk_row "$real")"
  [[ -n "$row" ]] || { echo "$real is not a block device."; return 1; }
  [[ "$(kv "$row" TYPE)" == disk ]] || { echo "$real is not a whole disk."; return 1; }
  majmin="$(kv "$row" MAJ:MIN)"
  case "${majmin%%:*}" in 1|7|11) echo "$real is a ram, loop or optical device."; return 1 ;; esac
  if [[ "$(kv "$row" RM)" == 1 || "$(kv "$row" RO)" == 1 ]]; then echo "$real is removable or read-only."; return 1; fi
  sysdisks="$(system_disks)"
  [[ -n "$sysdisks" ]] || { echo "Cannot determine which disk holds the operating system; refusing to use any disk."; return 1; }
  while IFS= read -r sys; do
    [[ -n "$sys" && "$sys" == "$real" ]] && { echo "$real holds the operating system or the operator data; it is never used for backups."; return 1; }
  done <<<"$sysdisks"
  tree="$(lsblk -nPb -o NAME,TYPE,FSTYPE,MOUNTPOINT "$real" 2>/dev/null || true)"
  while IFS= read -r line; do
    [[ -n "$line" && -n "$(kv "$line" MOUNTPOINT)" ]] && { echo "$real or one of its partitions is mounted or used as swap."; return 1; }
  done <<<"$tree"
  while IFS= read -r line; do
    [[ -n "$line" && "$(kv "$line" TYPE)" != disk ]] && { echo "$real already has partitions or child devices."; return 1; }
  done <<<"$tree"
  if [[ -n "$(ls -A "$SYSFS/block/${real##*/}/holders" 2>/dev/null || true)" ]]; then
    echo "$real is in use by an md or device-mapper device."; return 1
  fi
  sig="$(blkid -p -o value -s TYPE "$real" 2>/dev/null || true)"
  [[ -n "$sig" ]] || sig="$(kv "$row" FSTYPE)"
  [[ -z "$sig" ]] || { echo "$real already carries a $sig signature; it must be a blank disk."; return 1; }
  if ! wipe="$(wipefs -n "$real" 2>/dev/null)"; then
    [[ "$PROBE_STRICT" == 1 ]] && { echo "Could not probe $real for signatures."; return 1; }
    wipe=''
  fi
  [[ -z "$wipe" ]] || { echo "$real already has a partition table or filesystem signature; it must be a blank disk."; return 1; }
  size="$(kv "$row" SIZE)"; need="$MIN_BYTES"
  if [[ -n "$STATE" && -d "$STATE/data" ]]; then
    used="$(du -sb "$STATE/data" "$STATE/backups" 2>/dev/null | awk '{ s += $1 } END { print s + 0 }' || true)"
    (( ${used:-0} * 2 > need )) && need=$((used * 2))
  fi
  if (( size < need )); then echo "$real is $(gib "$size"); at least $(gib "$need") is required."; return 1; fi
  return 0
}

candidates() {
  local row dev
  while IFS= read -r row; do
    [[ -n "$row" && "$(kv "$row" TYPE)" == disk ]] || continue
    dev="/dev/$(kv "$row" NAME)"
    if disk_problem "$dev" >/dev/null; then
      printf '%s|%s|%s|%s\n' "$dev" "$(kv "$row" SIZE)" "$(kv "$row" SERIAL)" "$(kv "$row" MODEL)"
    fi
  done < <(lsblk -dnPb -o NAME,TYPE,SIZE,RM,RO,SERIAL,MODEL,MAJ:MIN,FSTYPE 2>/dev/null || true)
}

confirm_hint() {
  local row="$1"
  if [[ -n "$(kv "$row" SERIAL)" ]]; then printf -- '--confirm-serial %s' "$(kv "$row" SERIAL)"
  else printf -- '--confirm-size %s' "$(kv "$row" SIZE)"; fi
}

print_plan() {
  local real="$1" row
  row="$(disk_row "$real")"
  echo "Plan for $real ($(kv "$row" MODEL), serial '$(kv "$row" SERIAL)', $(gib "$(kv "$row" SIZE)")):"
  echo "  1. create a GPT with one partition covering the whole disk (label $LABEL)"
  echo "  2. format it ext4 (label $LABEL); the disk has no partitions or signatures, so nothing is overwritten"
  echo "  3. mount it at $MOUNT, owned by the installation user, mode 0700, and write $MARKER"
  echo "  4. add one UUID line with nofail to $FSTAB (a dated copy of the file is kept)"
  [[ -z "${WAREHOUSE_BACKUP_DISK_MOUNT:-}${WAREHOUSE_BACKUP_DISK_FSTAB:-}${WAREHOUSE_BACKUP_DISK_SYSFS:-}" ]] ||
    echo "  Test overrides active: mount=$MOUNT fstab=$FSTAB sysfs=$SYSFS"
}

require_state() {
  local state
  # shellcheck source=scripts/operator-lock.sh
  . "$ROOT/scripts/operator-lock.sh"
  state="$(operator_state)" || exit 1
  STATE="$state"
}

cmd_plan() {
  local device='' row line
  while (($#)); do
    case "$1" in
      --device) (($# > 1)) || usage; device="$2"; shift 2 ;;
      --state) (($# > 1)) || usage; STATE="$2"; shift 2 ;;
      *) usage ;;
    esac
  done
  [[ -n "$STATE" || "${WAREHOUSE_STATE_DIR:-}" != /* ]] || STATE="$WAREHOUSE_STATE_DIR"
  if [[ -z "$device" ]]; then
    local found=0
    while IFS= read -r line; do
      [[ -n "$line" ]] || continue
      found=1
      IFS='|' read -r dev size serial model <<<"$line"
      echo "Candidate: $dev, $(gib "$size"), model '$model', serial '$serial'"
    done < <(candidates)
    ((found)) || die "$NO_SECOND_DISK"
    echo "Next: bash scripts/backup-disk.sh plan --device DEVICE"
    return 0
  fi
  reason="$(disk_problem "$device")" || die "$reason"
  device="$(readlink -f -- "$device")"
  row="$(disk_row "$device")"
  print_plan "$device"
  echo
  echo "To apply (destructive; run as root):"
  echo "  sudo bash scripts/backup-disk.sh apply --device $device --yes $(confirm_hint "$row")"
}

cmd_status() {
  local state_note='' src instance last row cand=0
  [[ "${WAREHOUSE_STATE_DIR:-}" != /* ]] || STATE="$WAREHOUSE_STATE_DIR"
  src="$(findmnt --mountpoint "$MOUNT" -n -o SOURCE 2>/dev/null || true)"
  if [[ -n "$src" ]]; then
    if [[ ! -f "$MOUNT/$MARKER" ]]; then
      echo "$MOUNT is mounted from $src but is not a prepared backup disk (no $MARKER)."; return 0
    fi
    if fstab_has_mount; then echo "Backup disk: prepared and mounted at $MOUNT (from $src)."
    else echo "Backup disk: mounted at $MOUNT (from $src) but $FSTAB has no entry for it; it will be missing after a reboot."; fi
    if [[ -n "$STATE" && -d "$STATE/data" && "$(findmnt -n -o MAJ:MIN -T "$MOUNT" 2>/dev/null)" == "$(findmnt -n -o MAJ:MIN -T "$STATE/data" 2>/dev/null)" ]]; then
      echo "WARNING: $MOUNT is on the same device as the operator data."
    fi
    instance="$(basename "${STATE:-none}")"
    last="$(ls -1t "$MOUNT/$instance" 2>/dev/null | head -n1 || true)"
    echo "Free space: $(df -h --output=avail "$MOUNT" 2>/dev/null | tail -n1 | tr -d ' ')."
    [[ -z "$last" ]] || echo "Latest synced backup: $last"
    return 0
  fi
  if fstab_has_mount; then
    echo "Backup disk: prepared but not mounted. $FSTAB has an entry for $MOUNT; try: sudo mount $MOUNT"; return 0
  fi
  if [[ -d "$MOUNT" && -n "$(ls -A "$MOUNT" 2>/dev/null || true)" ]]; then
    echo "DANGER: $MOUNT exists on the system disk, holds files and is not a mount point. sync will refuse to use it."; return 0
  fi
  while IFS= read -r row; do
    [[ -n "$row" && "$(kv "$row" TYPE)" == part && "$(kv "$row" PARTLABEL)" == "$LABEL" ]] || continue
    echo "Backup disk: partitioned but not finished (/dev/$(kv "$row" NAME) has label $LABEL but is not mounted). See the troubleshooting entry in docs/OPERATOR_INSTALL.md."
    return 0
  done < <(lsblk -nP -o NAME,TYPE,PARTLABEL 2>/dev/null || true)
  while IFS= read -r row; do
    [[ -n "$row" ]] || continue
    cand=1
    IFS='|' read -r dev size serial model <<<"$row"
    echo "Second disk candidate (empty): $dev, $(gib "$size"), model '$model', serial '$serial'. Next: bash scripts/backup-disk.sh plan --device $dev"
  done < <(candidates)
  ((cand)) || echo "No second disk. $NO_SECOND_DISK"
}

# Drops back to a clear message if apply stops half way. Nothing is wiped automatically.
on_apply_exit() {
  local status=$?
  trap - EXIT
  if ((status != 0)) && [[ -n "$PHASE" ]]; then
    echo "apply stopped during: $PHASE. Nothing was wiped or undone automatically. Run 'bash scripts/backup-disk.sh status' and see the Backup disk troubleshooting entry in docs/OPERATOR_INSTALL.md." >&2
  fi
  exit "$status"
}

add_fstab_line() {
  local uuid="$1" stamp copy tmp
  [[ -f "$FSTAB" && ! -L "$FSTAB" ]] || die "$FSTAB is not a regular file; refusing to edit it."
  fstab_has_mount && die "$FSTAB already has an entry for $MOUNT."
  ! grep -Fq "UUID=$uuid" "$FSTAB" || die "$FSTAB already mentions UUID $uuid."
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  copy="$FSTAB.warehouse-backup-disk.$stamp"
  cp -p -- "$FSTAB" "$copy"
  tmp="$(mktemp "$FSTAB.new.XXXXXX")"
  cat -- "$FSTAB" > "$tmp"
  [[ ! -s "$tmp" || -z "$(tail -c1 "$tmp")" ]] || printf '\n' >> "$tmp"
  printf 'UUID=%s %s ext4 defaults,nofail,x-systemd.device-timeout=10 0 2\n' "$uuid" "$MOUNT" >> "$tmp"
  chmod --reference="$FSTAB" -- "$tmp"
  if command -v findmnt >/dev/null && ! findmnt --verify --tab-file "$tmp" >/dev/null 2>&1; then
    echo "Note: findmnt --verify reported warnings for the new fstab; review $tmp's replacement after the run." >&2
  fi
  sync
  mv -T -- "$tmp" "$FSTAB"
  FSTAB_COPY="$copy"
  echo "Added to $FSTAB (previous copy: $copy):"
  echo "  UUID=$uuid $MOUNT ext4 defaults,nofail,x-systemd.device-timeout=10 0 2"
}

cmd_apply() {
  local device='' yes=0 confirm_serial='' confirm_size='' real row serial size uid gid mode tool part uuid captured reason
  while (($#)); do
    case "$1" in
      --device) (($# > 1)) || usage; device="$2"; shift 2 ;;
      --yes) yes=1; shift ;;
      --confirm-serial) (($# > 1)) || usage; confirm_serial="$2"; shift 2 ;;
      --confirm-size) (($# > 1)) || usage; confirm_size="$2"; shift 2 ;;
      --state) (($# > 1)) || usage; STATE="$2"; shift 2 ;;
      *) usage ;;
    esac
  done
  [[ -n "$device" ]] || die 'apply needs --device. Run plan first to see the eligible disks.'
  ((yes)) || die 'apply is destructive: run plan, then repeat the command with --yes and the confirmation printed by plan.'
  [[ "$(id -u)" == 0 ]] || die 'apply needs root; run: sudo bash scripts/backup-disk.sh apply --device DEVICE --yes --confirm-serial SERIAL'
  uid="${SUDO_UID:-}"; gid="${SUDO_GID:-}"
  [[ "$uid" =~ ^[0-9]+$ && "$uid" != 0 ]] || die 'Run apply through sudo from the installation user (SUDO_UID is not set); the backup disk must be owned by that user, not root.'
  [[ "$gid" =~ ^[0-9]+$ ]] || gid="$(getent passwd "$uid" | cut -d: -f4)"
  [[ "$gid" =~ ^[0-9]+$ ]] || die "Cannot resolve the group of user id $uid."
  mode="$(stat -c %a -- "$SELF")"
  if (( (8#$mode & 8#022) != 0 )) || (( (8#$(stat -c %a -- "$(dirname "$SELF")") & 8#022) != 0 )); then
    die 'Refusing to run as root: this script or its directory is group- or world-writable.'
  fi
  [[ -n "$STATE" || "${WAREHOUSE_STATE_DIR:-}" != /* ]] || STATE="${WAREHOUSE_STATE_DIR:-}"
  [[ "$MOUNT" == /* && "$MOUNT" != / ]] || die "The mount point must be an absolute path other than /: $MOUNT"
  for tool in lsblk blkid wipefs findmnt sgdisk mkfs.ext4 mount umount partprobe; do
    command -v "$tool" >/dev/null || die "Missing required tool: $tool"
  done
  PROBE_STRICT=1
  real="$(readlink -f -- "$device" 2>/dev/null || true)"

  # Already prepared? Then there is nothing to do, and a second disk is never swapped in silently.
  if [[ -n "$(findmnt --mountpoint "$MOUNT" -n -o SOURCE 2>/dev/null || true)" ]]; then
    if [[ -f "$MOUNT/$MARKER" ]] && fstab_has_mount; then
      local current
      current="$(disks_of "$(findmnt --mountpoint "$MOUNT" -n -o SOURCE)" | head -n1)"
      if [[ "$current" == "$real" ]]; then echo "Backup disk already prepared at $MOUNT; nothing changed."; return 0; fi
      die "$MOUNT is already configured with another disk ($current)."
    fi
    die "$MOUNT is already a mount point but not a prepared backup disk."
  fi

  reason="$(disk_problem "$device")" || die "$reason"
  row="$(disk_row "$real")"; captured="$row"
  serial="$(kv "$row" SERIAL)"; size="$(kv "$row" SIZE)"
  if [[ -n "$serial" && "$confirm_serial" == "$serial" ]] || [[ -n "$confirm_size" && "$confirm_size" == "$size" ]]; then :; else
    die "Confirmation missing or wrong: repeat with $(confirm_hint "$row") (the values come from the disk itself)."
  fi
  if [[ -e "$MOUNT" ]]; then
    [[ -d "$MOUNT" && ! -L "$MOUNT" && -z "$(ls -A "$MOUNT")" ]] || die "$MOUNT exists and is not an empty directory."
  else
    [[ -d "$(dirname "$MOUNT")" ]] || die "Parent of the mount point does not exist: $(dirname "$MOUNT")"
  fi
  ! fstab_has_mount || die "$FSTAB already has an entry for $MOUNT."

  print_plan "$real"
  if [[ -b "$real" ]]; then
    exec 8<"$real"
    flock -n 8 || die "$real is being modified by another process."
  fi

  PHASE='final safety re-check'
  trap on_apply_exit EXIT
  reason="$(disk_problem "$real")" || die "$reason"
  [[ "$(disk_row "$real")" == "$captured" ]] || die "$real changed while the plan was being printed; nothing was written."

  PHASE='partitioning (sgdisk); the disk may now carry a partition table'
  sgdisk --new=1:0:0 --typecode=1:8300 --change-name=1:"$LABEL" "$real" >/dev/null
  PHASE='waiting for the new partition node'
  partprobe "$real" 2>/dev/null || true
  command -v udevadm >/dev/null && udevadm settle 2>/dev/null || true
  part=''
  for _ in $(seq 1 20); do
    part="$(lsblk -nP -o NAME,TYPE "$real" 2>/dev/null | while IFS= read -r row; do
      [[ "$(kv "$row" TYPE)" == part ]] && echo "/dev/$(kv "$row" NAME)"
    done | head -n1 || true)"
    [[ -n "$part" ]] && break
    sleep 0.5
  done
  [[ -n "$part" ]] || die "The new partition did not appear under $real."
  PHASE="formatting $part (mkfs.ext4); this partition is new and holds nothing else"
  mkfs.ext4 -q -m 0 -L "$LABEL" "$part"
  uuid="$(blkid -s UUID -o value "$part" 2>/dev/null || true)"
  [[ -n "$uuid" ]] || die "Could not read the UUID of $part."
  PHASE="mounting $part at $MOUNT"
  install -d -m 0700 -- "$MOUNT"
  mount "$part" "$MOUNT"
  chown "$uid:$gid" "$MOUNT"
  chmod 0700 "$MOUNT"
  printf '%s\n' "$uuid" > "$MOUNT/$MARKER"
  chown "$uid:$gid" "$MOUNT/$MARKER"
  PHASE="writing the $FSTAB entry (the disk is mounted but will not survive a reboot yet)"
  FSTAB_COPY=''
  add_fstab_line "$uuid"
  PHASE='remount round trip to prove the fstab entry'
  if ! { umount "$MOUNT" && mount "$MOUNT"; }; then
    [[ -z "$FSTAB_COPY" ]] || mv -T -- "$FSTAB_COPY" "$FSTAB"
    die "The fstab entry did not mount; $FSTAB was restored from its copy."
  fi
  [[ "$FSTAB" != /etc/fstab ]] || { command -v systemctl >/dev/null && systemctl daemon-reload 2>/dev/null || true; }
  PHASE=''
  echo "Backup disk ready at $MOUNT (UUID $uuid), owned by user id $uid, mode 0700."
  echo "Next, as the installation user: bash scripts/backup-disk.sh sync"
}

sync_fail() { echo "FAILED: $*" >&2; FAILED=$((FAILED + 1)); }

cmd_sync() {
  local from='' verify=1 state name dest backup_name b target need avail instance_id id_file leftovers
  while (($#)); do
    case "$1" in
      --from) (($# > 1)) || usage; from="$2"; shift 2 ;;
      --skip-verify-restore) verify=0; shift ;;
      *) usage ;;
    esac
  done
  require_state
  state="$STATE"
  operator_lock "$state" || exit 1
  [[ -n "$from" ]] || from="$state/backups"
  [[ "$from" == /* && -d "$from" && ! -L "$from" && "$(realpath -m "$from")" != "$state/data"/* ]] || die "The backup source must be a real directory outside $state/data: $from"

  # The mount point must be a real mount of a different disk; an unmounted directory is just the system disk.
  [[ -n "$(findmnt --mountpoint "$MOUNT" -n -o SOURCE 2>/dev/null || true)" ]] || die "$MOUNT is not mounted. Run: bash scripts/backup-disk.sh status"
  [[ -f "$MOUNT/$MARKER" && ! -L "$MOUNT/$MARKER" ]] || die "$MOUNT is mounted but is not a prepared backup disk (missing $MARKER)."
  [[ "$(head -n1 "$MOUNT/$MARKER")" == "$(findmnt --mountpoint "$MOUNT" -n -o UUID 2>/dev/null || true)" ]] || die "$MOUNT is not the disk that was prepared (UUID mismatch with $MARKER)."
  [[ "$(findmnt -n -o MAJ:MIN -T "$MOUNT" 2>/dev/null || true)" != "$(findmnt -n -o MAJ:MIN -T "$state/data" 2>/dev/null || true)" ]] || die "$MOUNT is on the same device as the operator data; copying there protects nothing."
  [[ "$(stat -c %u -- "$MOUNT")" == "$(id -u)" && "$(stat -c %a -- "$MOUNT")" == 700 ]] || die "$MOUNT must be owned by the installation user with mode 0700."

  name="$(basename "$state" | tr -c 'A-Za-z0-9._\n-' '_')"
  [[ -n "$name" && "$name" != . && "$name" != .. ]] || die "Cannot derive a safe directory name from $state."
  dest="$MOUNT/$name"
  instance_id="$(sed -n 's/.*"instanceId"[^"]*"\([^"]*\)".*/\1/p' "$state/public/instance.json" 2>/dev/null | head -n1 || true)"
  mkdir -p -m 0700 -- "$dest"
  id_file="$dest/.instance-id"
  if [[ -f "$id_file" && -n "$instance_id" && "$(cat "$id_file")" != "$instance_id" ]]; then
    die "$dest belongs to a different instance; choose another state directory name."
  fi
  [[ -z "$instance_id" ]] || printf '%s\n' "$instance_id" > "$id_file"

  # The lock is held, so staging directories from an interrupted run are safe to remove.
  leftovers="$(find "$dest" -maxdepth 1 -name '.sync-staging.*' -print 2>/dev/null || true)"
  [[ -z "$leftovers" ]] || { echo "Removing leftovers of an interrupted sync."; find "$dest" -maxdepth 1 -name '.sync-staging.*' -exec rm -rf -- {} +; }

  local copied=0 skipped=0
  trap '[[ -z "$STAGE" || ! -d "$STAGE" ]] || rm -rf -- "$STAGE"' EXIT
  while IFS= read -r b; do
    backup_name="$(basename "$b")"
    [[ -f "$b/SHA256SUMS" && -f "$b/metadata.txt" ]] || { sync_fail "$backup_name is not a complete backup (missing SHA256SUMS or metadata.txt)."; continue; }
    if [[ -n "$(find "$b" -type l -print -quit)" ]]; then sync_fail "$backup_name contains symbolic links."; continue; fi
    if ! (cd "$b" && sha256sum -c --quiet SHA256SUMS >/dev/null 2>&1); then sync_fail "source backup $backup_name already fails its checksums; nothing copied."; continue; fi
    target="$dest/$backup_name"
    if [[ -e "$target" ]]; then
      if (cd "$target" && sha256sum -c --quiet SHA256SUMS >/dev/null 2>&1); then skipped=$((skipped + 1)); echo "Already on the backup disk and verified: $backup_name"
      else sync_fail "the copy of $backup_name on the backup disk is corrupt; it was not overwritten."; fi
      continue
    fi
    need="$(du -sb "$b" | cut -f1)"
    avail="$(df -B1 --output=avail "$dest" | tail -n1 | tr -d ' ')"
    if (( avail < need + 67108864 )); then sync_fail "not enough free space on $MOUNT for $backup_name."; continue; fi
    STAGE="$(mktemp -d "$dest/.sync-staging.XXXXXXXX")"
    if ! cp -a -- "$b/." "$STAGE/"; then sync_fail "copy of $backup_name failed."; rm -rf -- "$STAGE"; STAGE=''; continue; fi
    find "$STAGE" -type d -exec chmod 0700 {} +
    find "$STAGE" -type f -exec chmod 0600 {} +
    if ! (cd "$STAGE" && sha256sum -c --quiet SHA256SUMS >/dev/null 2>&1) ||
       [[ "$(cd "$b" && find . -type f | sort)" != "$(cd "$STAGE" && find . -type f | sort)" ]]; then
      sync_fail "checksum or file-list mismatch in the copy of $backup_name; nothing was kept."
      rm -rf -- "$STAGE"; STAGE=''; continue
    fi
    sync
    mv -T -- "$STAGE" "$target"; STAGE=''
    copied=$((copied + 1)); echo "Copied and checksum-verified: $backup_name"
    if ((verify)); then
      if ! bash "$ROOT/scripts/verify-restore.sh" "$target"; then sync_fail "restore verification of the copy of $backup_name failed (the checksum-verified copy was kept)."; fi
    fi
  done < <(find "$from" -mindepth 1 -maxdepth 1 -type d ! -name '.*' | sort)
  echo "Summary: copied=$copied already-present=$skipped failed=$FAILED. Nothing is ever deleted from either side; remove old backups yourself."
  echo 'WARNING: the copies contain compose.env, which holds every credential of this instance. Keep the disk physically controlled.'
  echo 'A second disk in the same host is local custody only: it does not replace an encrypted off-host copy.'
  ((FAILED == 0)) || exit 1
}

sub="${1:-plan}"
(($#)) && shift
case "$sub" in
  status) cmd_status "$@" ;;
  plan) cmd_plan "$@" ;;
  apply) cmd_apply "$@" ;;
  sync) cmd_sync "$@" ;;
  -h|--help|help) usage ;;
  *) usage ;;
esac
