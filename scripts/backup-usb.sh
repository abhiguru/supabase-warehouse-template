#!/usr/bin/env bash
# Copy verified backups to an operator-attached exFAT USB drive, automatically when it is attached.
#   setup --state DIR [--enroll DEV] [--daily] [--no-fresh-backup]
#                          root (sudo): install the udev rule, systemd units and root helper; enroll a drive
#   enroll --device DEV    root: allow another drive (identified by its filesystem UUID)
#   uninstall              root: remove the rule, units, helper and configuration; drives are untouched
#   status                 installation user, read-only: installation, enrolled drives, last result
#   run --device NAME      installation user (the service runs this): fresh backup, copy, verify, record
#   mount NAME | unmount NAME | scan
#                          root, run by systemd from the installed helper copy
# Only enrolled drives start a backup, so a stranger's USB stick never receives the credentials.
# The drive is never partitioned or formatted and nothing outside warehouse-backups/<state name>/
# is touched. Archives are not encrypted: they contain compose.env, which holds every credential.
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
LAST_ERR=''
RECORDED=1
TMPDIRS=()

die() { LAST_ERR="$*"; echo "$*" >&2; exit 1; }
usage() {
  die 'Usage: backup-usb.sh setup --state DIR [--enroll DEV] [--daily] [--no-fresh-backup] | enroll --device DEV | uninstall | status | run --device NAME | mount NAME | unmount NAME | scan'
}
kv() { sed -n "s/.*\\b$2=\"\\([^\"]*\\)\".*/\\1/p" <<<"$1" | head -n1; }
conf_get() { [[ -f "$CONF" ]] || return 0; sed -n "s/^$1=//p" "$CONF" | head -n1; }
require_root() { [[ "$(id -u)" == 0 ]] || die "$1 needs root; run: sudo bash scripts/backup-usb.sh $1 ..."; }
kname() { local n="${1#/dev/}"; [[ "$n" =~ ^sd[a-z]+[0-9]*$ ]] || die "$1 is not a USB disk or partition name such as sdb1."; printf '%s\n' "$n"; }

# Sets D_UUID for a USB-attached, writable exFAT filesystem; dies with the reason otherwise.
D_UUID=''
probe_drive() {
  local name="$1" row type parent tran
  row="$(lsblk -dnP -o NAME,TYPE,FSTYPE,UUID,RO,PKNAME "/dev/$name" 2>/dev/null | head -n1 || true)"
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
}
enrolled() { [[ -f "$DRIVES" ]] && grep -qxF -- "$1" "$DRIVES"; }

# ---------------------------------------------------------------- root: installation
write_rule() {
  local tmp uuid
  mkdir -p "$(dirname "$RULE")"
  tmp="$(mktemp "$RULE.XXXXXX")"
  {
    echo '# Managed by scripts/backup-usb.sh: attaching an enrolled drive starts a warehouse backup.'
    while IFS= read -r uuid; do
      [[ -n "$uuid" ]] || continue
      printf 'ACTION=="add", SUBSYSTEM=="block", ENV{ID_BUS}=="usb", ENV{ID_FS_TYPE}=="exfat", ENV{ID_FS_UUID}=="%s", TAG+="systemd", ENV{SYSTEMD_WANTS}+="%s@%%k.service"\n' "$uuid" "$UNIT"
    done < "$DRIVES"
  } > "$tmp"
  chmod 0644 "$tmp"; mv -f -- "$tmp" "$RULE"
  udevadm control --reload-rules
}

do_enroll() {
  local name
  name="$(kname "$1")"
  probe_drive "$name"
  if enrolled "$D_UUID"; then echo "Drive $D_UUID (/dev/$name) is already enrolled."
  else printf '%s\n' "$D_UUID" >> "$DRIVES"; echo "Enrolled drive $D_UUID (/dev/$name)."; fi
  write_rule
}

safe_path() { [[ "$1" == /* && "$1" != *[[:space:]%\\\"\']* ]] || die "$2 must be an absolute path without spaces, quotes or %: $1"; }

cmd_setup() {
  local state='' enroll='' daily=no fresh=yes uid gid user group old
  while (($#)); do
    case "$1" in
      --state) (($# > 1)) || usage; state="$2"; shift 2 ;;
      --enroll) (($# > 1)) || usage; enroll="$2"; shift 2 ;;
      --daily) daily=yes; shift ;;
      --no-fresh-backup) fresh=no; shift ;;
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
  [[ "$(stat -c %a -- "$SELF")" =~ ^[0-7][0145][0145]$ && "$(stat -c %a -- "$ROOT/scripts")" =~ ^[0-7][0145][0145]$ ]] || die "$SELF or its directory is group- or world-writable."
  old="$(conf_get STATE)"
  [[ -z "$old" || "$old" == "$state" ]] || die "USB backup is already set up for $old; run uninstall first."

  mkdir -p "$LIBEXEC" "$UNITS"
  install -m 0755 -- "$SELF" "$HELPER"; chown root:root "$HELPER"
  local tmp; tmp="$(mktemp "$CONF.XXXXXX")"
  printf 'STATE=%s\nCHECKOUT=%s\nUSER=%s\nUID=%s\nGID=%s\nFRESH_BACKUP=%s\nDAILY=%s\n' "$state" "$ROOT" "$user" "$uid" "$gid" "$fresh" "$daily" > "$tmp"
  chmod 0644 "$tmp"; mv -f -- "$tmp" "$CONF"
  [[ -f "$DRIVES" ]] || { : > "$DRIVES"; chmod 0644 "$DRIVES"; }

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

  echo "USB backup is set up for $state, running as $user (fresh backup on attach: $fresh, daily timer: $daily)."
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
  local name mp existing i uid gid
  name="$(kname "${1:-}")"
  require_root mount
  probe_drive "$name"
  enrolled "$D_UUID" || die "Drive $D_UUID (/dev/$name) is not enrolled; nothing mounted."
  # A desktop session may be mounting it at the same moment; use that mount if it appears.
  for ((i = 0; i <= SETTLE; i++)); do
    existing="$(findmnt -n -o TARGET -S "/dev/$name" 2>/dev/null | head -n1 || true)"
    [[ -z "$existing" ]] || { echo "Using the existing mount $existing for /dev/$name."; return 0; }
    ((i == SETTLE)) || sleep 1
  done
  uid="$(conf_get UID)"; gid="$(conf_get GID)"
  [[ "$uid" =~ ^[1-9][0-9]*$ && "$gid" =~ ^[0-9]+$ ]] || die "$CONF has no valid UID/GID; run setup again."
  mkdir -p -m 0755 "$RUNDIR"
  mp="$RUNDIR/$name"
  mkdir -p -m 0700 "$mp"
  mount -t exfat -o "nosuid,nodev,noexec,uid=$uid,gid=$gid,fmask=0177,dmask=0077,errors=remount-ro" "/dev/$name" "$mp"
  echo "Mounted /dev/$name at $mp."
}

cmd_unmount() {
  local name targets t ours=0 failed=0
  name="$(kname "${1:-}")"
  require_root unmount
  # Unmount every mount of an enrolled drive so it is safe to remove; otherwise only our own mount.
  if ( probe_drive "$name" >/dev/null 2>&1 && enrolled "$D_UUID" ) 2>/dev/null; then
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
  while IFS= read -r uuid; do
    [[ -n "$uuid" ]] || continue
    name="$(lsblk -nr -o NAME,UUID 2>/dev/null | awk -v u="$uuid" '$2 == u { print $1; exit }')"
    [[ -n "$name" ]] || continue
    systemctl start --no-block "$UNIT@$name.service"; started=$((started + 1))
    echo "Started the backup for drive $uuid (/dev/$name)."
  done < "$DRIVES"
  ((started)) || echo 'No enrolled drive is attached.'
}

# ---------------------------------------------------------------- installation user
STATE=''; RESULT_FILE=''; DEST=''; DEVICE=''
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
archive_ok() { [[ -f "$1.sha256" ]] && [[ "$(media_hash "$1")" == "$(cut -d' ' -f1 "$1.sha256")" ]]; }

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
      echo 'These archives are NOT encrypted and contain every credential of the instance. Keep this drive locked away;'
      echo 'if it is lost, run ./rotate-keys.sh --yes on the server and take a new backup.'
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
  local name mp data_mm mp_mm label b n archive need avail hash newest tmp instance_id id_file
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
  enrolled "$D_UUID" || die "Drive $D_UUID ($DEVICE) is not enrolled; run: sudo bash scripts/backup-usb.sh enroll --device $DEVICE"
  mp="$(findmnt -n -o TARGET -S "$DEVICE" 2>/dev/null | head -n1 || true)"
  [[ -n "$mp" ]] || die "$DEVICE is not mounted."
  [[ "$(findmnt -n -o FSTYPE --mountpoint "$mp" 2>/dev/null || true)" == exfat ]] || die "$mp is not an exFAT mount."
  data_mm="$(findmnt -n -o MAJ:MIN -T "$STATE/data" 2>/dev/null | tr -d ' ' || true)"; mp_mm="$(findmnt -n -o MAJ:MIN -T "$mp" 2>/dev/null | tr -d ' ' || true)"
  [[ -n "$mp_mm" && "$mp_mm" != "$data_mm" ]] || die "$mp is on the same device as the operator data; copying there protects nothing."
  [[ -w "$mp" ]] || die "$mp is not writable by $(id -un)."
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
  instance_id="$(sed -n 's/.*"instanceId"[^"]*"\([^"]*\)".*/\1/p' "$STATE/public/instance.json" 2>/dev/null | head -n1 || true)"
  id_file="$DEST/.instance-id"
  if [[ -f "$id_file" && -n "$instance_id" && "$(cat "$id_file")" != "$instance_id" ]]; then
    die "$DEST belongs to a different instance; nothing was copied."
  fi
  [[ -z "$instance_id" ]] || printf '%s\n' "$instance_id" > "$id_file"
  # The lock is held, so partial files are leftovers of an interrupted run.
  find "$DEST" -maxdepth 1 -name '.*.partial' -type f -delete

  while IFS= read -r b; do
    n="$(basename "$b")"; archive="$DEST/$n.tar"
    if [[ -e "$archive" ]]; then
      if archive_ok "$archive"; then PRESENT=$((PRESENT + 1)); echo "Already on the drive and verified: $n"
      else fail "the archive of $n on the drive does not match its checksum; it was not overwritten"; fi
      continue
    fi
    [[ -f "$b/SHA256SUMS" && -f "$b/metadata.txt" ]] || { fail "$n is not a complete backup"; continue; }
    [[ -z "$(find "$b" -type l -print -quit)" ]] || { fail "$n contains symbolic links"; continue; }
    (cd "$b" && sha256sum -c --quiet SHA256SUMS >/dev/null 2>&1) || { fail "source backup $n fails its checksums; nothing copied"; continue; }
    need="$(du -sb "$b" | cut -f1)"; avail="$(df -B1 --output=avail "$DEST" | tail -n1 | tr -d ' ')"
    (( avail > need + 67108864 )) || { fail "not enough free space on the drive for $n"; continue; }
    # Hash the stream as it is written, then read the file back from the drive and compare.
    if ! hash="$(tar -C "$STATE/backups" -cf - "$n" | tee "$DEST/.$n.tar.partial" | sha256sum | cut -d' ' -f1)"; then
      rm -f -- "$DEST/.$n.tar.partial"; fail "writing the archive of $n failed"; continue
    fi
    sync -f "$DEST/.$n.tar.partial" 2>/dev/null || sync
    if [[ "$(media_hash "$DEST/.$n.tar.partial")" != "$hash" ]]; then
      rm -f -- "$DEST/.$n.tar.partial"; fail "the archive of $n read back from the drive does not match what was written"; continue
    fi
    printf '%s  %s\n' "$hash" "$n.tar" > "$DEST/.$n.sha.partial"
    mv -f -- "$DEST/.$n.sha.partial" "$archive.sha256"
    mv -f -- "$DEST/.$n.tar.partial" "$archive"
    sync -f "$archive" 2>/dev/null || sync
    COPIED=$((COPIED + 1)); echo "Copied and verified from the drive: $n"
  done < <(find "$STATE/backups" -mindepth 1 -maxdepth 1 -type d -name 'warehouse-*' 2>/dev/null | sort)

  newest="$(find "$DEST" -maxdepth 1 -type f -name 'warehouse-*.tar' -printf '%f\n' | sort | tail -n1)"
  if [[ -z "$newest" ]]; then
    fail 'there is no backup on the drive; take one with npm run db:backup'
  elif [[ "${WAREHOUSE_USB_BACKUP_VERIFY_RESTORE:-yes}" != no ]]; then
    tmp="$(mktemp -d "$STATE/.usb-verify.XXXXXX")"; TMPDIRS+=("$tmp")
    if archive_ok "$DEST/$newest" && tar -C "$tmp" -xf "$DEST/$newest" && bash "$ROOT/scripts/verify-restore.sh" "$tmp/${newest%.tar}"; then
      echo "Restore verification of the copy on the drive passed: ${newest%.tar}"
    else
      fail "restore verification of ${newest%.tar} from the drive failed"
    fi
    rm -rf -- "$tmp"
  fi

  echo "Summary: copied=$COPIED already-present=$PRESENT failed=$FAILED. Nothing is deleted on either side; remove old backups yourself."
  echo 'WARNING: the archives are not encrypted and contain every credential of this instance. Keep the drive locked away.'
  if ((FAILED)); then record failed "$FAILURES"; exit 1; fi
  record ok "copied $COPIED, already present $PRESENT, restore verified ${newest%.tar}"
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
  echo "Set up for $state as $(conf_get USER) (fresh backup on attach: $(conf_get FRESH_BACKUP), daily timer: $(conf_get DAILY))."
  if [[ -f "$HELPER" ]] && ! cmp -s -- "$HELPER" "$SELF"; then
    echo 'WARNING: the installed root helper differs from this checkout; run setup again.'
  fi
  [[ -s "$DRIVES" ]] || echo 'No drive is enrolled.'
  while IFS= read -r uuid; do
    [[ -n "$uuid" ]] || continue
    name="$(lsblk -nr -o NAME,UUID 2>/dev/null | awk -v u="$uuid" '$2 == u { print $1; exit }' || true)"
    if [[ -n "$name" ]]; then echo "Enrolled drive $uuid: attached as /dev/$name"; else echo "Enrolled drive $uuid: not attached"; fi
  done < <(cat "$DRIVES" 2>/dev/null || true)
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
