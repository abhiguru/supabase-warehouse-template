#!/usr/bin/env bash
# Copy verified backups to an operator-attached exFAT USB drive, automatically when it is attached.
#   setup --state DIR [--enroll DEV] [--daily|--no-daily] [--fresh-backup|--no-fresh-backup] [--encrypt|--no-encrypt] [--keep N]
#                          root (sudo): install the udev rule, systemd units and root helper; enroll a drive.
#                          Run again after every checkout update: an option that is not given keeps the
#                          value the previous setup stored (except that an installation set up before encryption became
#                          the default, and never told `--no-encrypt`, is switched to encrypted archives).
#   enroll --device DEV    root: allow another drive (writes a signed enrolment marker onto it)
#   uninstall              root: remove the rule, units, helper and configuration; drives are untouched
#   status                 installation user, read-only: installation, enrolled drives, last result
#   run --device NAME      installation user (the service runs this): a fresh backup only if the newest verified one is
#                          older than 20 hours, copy the newest verified backup as one archive, verify it, prune, record
#   mount NAME | unmount NAME | scan
#                          root, run by systemd from the installed helper copy
#   refused NAME UUID TEXT internal: the root helper, as the installation user, records a drive it did not mount
# Only enrolled drives receive a backup. Enrolment is not the volume serial alone, which is 32 bits
# and can be copied: enroll writes warehouse-backups/.drive-enrolment onto the drive, an HMAC made
# with the backup key (<state>/config/backup.key) over the filesystem UUID, the partition UUID and
# the instance id, and run copies nothing unless that marker verifies for the drive it is on.
# The drive is never partitioned or formatted and nothing outside warehouse-backups/ is touched.
# Archives are signed with the backup key and, unless `setup --no-encrypt` was typed (WAREHOUSE_BACKUP_ENCRYPT=0), encrypted
# with it. A readable archive contains compose.env, which holds every credential. The key must be confirmed as kept elsewhere
# (scripts/backup-key-escrow.sh) before a drive is enrolled and before an encrypted archive is written: without a copy of the
# key every encrypted archive is lost with the host.
# Each backup is one self-contained archive (scripts/backup-archive.sh). A run copies only the newest verified backup, checks
# the copy from the drive without unpacking the photos, and then keeps the newest N valid archives of this installation
# (setup --keep N, default 3), deleting older ones, and, once an encrypted archive is written and verified, the readable
# archives an earlier release left. Archives that are damaged, unsigned or signed with another key are reported and never deleted.
# The saved images (<state>/images, written and signed by scripts/build-images.sh) are copied too, as a folder beside the archives,
# warehouse-backups/<state name>/images: once, and again only when the folder's signed list (SHA256SUMS) is no longer the one on the
# drive. db:restore-host looks for an `images` folder next to the archive it is given, so a lost-host restore from the drive finds them.
# They are not inside the archives (every archive would carry the same few GiB) and are not encrypted: they are built from this
# repository's recipes and hold nothing of the installation; their signature, made with the backup key, is what db:restore-host checks
# before it loads one. The copy goes into a partial folder, is read back from the drive, and replaces the old folder only then (an
# interruption between the two renames leaves the old folder under another name, which the next run puts back first). It is the last
# step of a run, after the archive is copied and verified and the drive is pruned, and it deletes nothing: an image problem (too little
# room, a folder that does not authenticate, an unreadable drive) does not make the archive copy a failure and does not hold back the
# pruning or the removal of readable archives. The run is recorded as ok with "saved images NOT copied: <why>", warns on stderr, and
# `npm run doctor` shows it.
set -euo pipefail
umask 077
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SELF="$(realpath "${BASH_SOURCE[0]}")"
# Written into the udev rule and the unit as "# Recipe: sha256:...": scripts/watch.mjs (root_copy_stale) compares it with this script's hash.
RECIPE="$(sha256sum < "$SELF" | cut -d' ' -f1)"
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
  die 'Usage: backup-usb.sh setup --state DIR [--enroll DEV] [--daily|--no-daily] [--fresh-backup|--no-fresh-backup] [--encrypt|--no-encrypt] [--keep N] | enroll --device DEV | uninstall | status | run --device NAME | mount NAME | unmount NAME | scan'
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
# The mount step runs as root before `run` starts, so a drive refused there would leave no
# trace outside the journal while status and doctor kept showing the last success. The
# refusal is recorded where they read it, written as the installation user (the state
# directory is that user's; root does not write into it).
record_refusal() {
  local name="$1" message="$2" uid gid
  uid="$(conf_get UID)"; gid="$(conf_get GID)"
  [[ "$uid" =~ ^[1-9][0-9]*$ && "$gid" =~ ^[0-9]+$ ]] || return 0
  setpriv --reuid "$uid" --regid "$gid" --clear-groups -- /bin/bash "$SELF" refused "$name" "$D_UUID" "$message" ||
    echo 'Could not record this in the installation state; bash scripts/backup-usb.sh status will not show it.' >&2
}
not_enrolled() {
  local message
  if [[ -f "$DRIVES" ]] && grep -qxF -- "$D_UUID" "$DRIVES"; then
    message="Drive $D_UUID (/dev/$1) was enrolled by an earlier release, by its volume serial only. Enroll it again: sudo bash scripts/backup-usb.sh enroll --device /dev/$1"
  elif [[ -f "$DRIVES" ]] && grep -q -- "^$D_UUID " "$DRIVES"; then
    message="Drive $D_UUID (/dev/$1) is not enrolled; $2 An enrolled drive has this volume serial but another partition. If this is your drive, enroll it again: sudo bash scripts/backup-usb.sh enroll --device /dev/$1"
  else
    die "Drive $D_UUID (/dev/$1) is not enrolled; $2"
  fi
  record_refusal "$1" "$message"
  die "$message"
}
load_backup_key_lib() {
  local lib="$ROOT/scripts/backup-key.sh"
  [[ -f "$lib" ]] || lib="$(conf_get CHECKOUT)/scripts/backup-key.sh"
  [[ -f "$lib" ]] || die 'scripts/backup-key.sh is missing from the checkout.'
  # shellcheck source=scripts/backup-key.sh
  source "$lib"
}
load_archive_lib() {
  local lib="$ROOT/scripts/backup-archive.sh"
  [[ -f "$lib" ]] || lib="$(conf_get CHECKOUT)/scripts/backup-archive.sh"
  [[ -f "$lib" ]] || die 'scripts/backup-archive.sh is missing from the checkout.'
  # shellcheck source=scripts/backup-archive.sh
  source "$lib"
}
# The refusal for a key copy that was not confirmed (scripts/backup-key-escrow.sh). Needs backup-key.sh loaded.
escrow_refusal() {
  printf 'The backup key copy is not confirmed (%s). Archives on the drive are encrypted with the backup key, and without a copy of it kept away from this machine and from the drive they cannot be opened after the host is lost. As the installation user run: WAREHOUSE_STATE_DIR=%s bash scripts/backup-key-escrow.sh show   (it prints the key once and asks you to type the whole key back from your copy), then %s' \
    "$BACKUP_ESCROW_PROBLEM" "$1" "$2"
}
# Whether archives are (or, after the next setup, will be) encrypted according to the stored configuration: yes, or no that
# was not typed (an installation set up before encryption became the default is switched at its next setup).
conf_encrypts() {
  local stored; stored="$(conf_get ENCRYPT)"
  [[ "$stored" != no || "$(conf_get ENCRYPT_SET)" != typed ]]
}
# The text the enrolment marker signs: this drive, this partition, this instance.
enrolment_hmac() { printf '%s\n%s\n%s\n' "$D_UUID" "$D_PARTUUID" "$2" | backup_hmac "$1" warehouse-usb-enrolment-v1; }
instance_id_of() { sed -n 's/.*"instanceId"[^"]*"\([^"]*\)".*/\1/p' "$1/public/instance.json" 2>/dev/null | head -n1 || true; }
# What the saved images add to a drive, from the tarballs in the state's images folder (one copy, not one per archive).
images_space_note() {
  local dir="$1/images" bytes=0 size file
  if [[ -d "$dir" && ! -L "$dir" ]]; then
    for file in "$dir"/*.tar; do
      [[ -f "$file" && ! -L "$file" ]] || continue
      size="$(stat -c %s -- "$file" 2>/dev/null || echo 0)"; bytes=$((bytes + size))
    done
  fi
  if ((bytes > 0)); then
    echo "The saved images ($dir, $(numfmt --to=iec-i --suffix=B "$bytes" 2>/dev/null || echo "$bytes bytes") now) are copied to the drive as well, once and again after a change, beside the archives: the drive needs that much room more than the archives (about 2.5 GiB at the first install) and as much again free while a changed set is written beside the old one. A lost-host restore from the drive then needs no Debian, npm or Chrome for Testing to answer; Docker Hub is still needed for the postgres and PostgREST images."
  else
    echo "There are no saved images in $dir yet. Once bash scripts/build-images.sh --save has written them (about 2.5 GiB), the drive receives them too, beside the archives, and the drive needs that much more room (as much again free while a changed set is written beside the old one)."
  fi
}

# ---------------------------------------------------------------- root: installation
write_rule() {
  local tmp uuid
  (umask 022; mkdir -p "$(dirname "$RULE")")
  tmp="$(mktemp "$RULE.XXXXXX")"
  {
    echo '# Managed by scripts/backup-usb.sh: attaching an enrolled drive starts a warehouse backup.'
    echo "# Recipe: sha256:$RECIPE"
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
  # An encrypted archive is lost with the host unless a copy of the key exists elsewhere: no drive is enrolled before the
  # operator has confirmed one (a drive for plain archives, typed with --no-encrypt, needs no confirmation).
  if conf_encrypts && ! backup_escrow_ok "$state"; then die "$(escrow_refusal "$state" 'enroll the drive again.')"; fi
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
  images_space_note "$state"
  write_rule
}

safe_path() { [[ "$1" == /* && "$1" != *[[:space:]%\\\"\']* ]] || die "$2 must be an absolute path without spaces, quotes or %: $1"; }

# The value given on the command line, else the one the previous setup stored, else the default.
# The fourth argument is the pattern a stored value must match (yes or no unless given).
kept_setting() {
  local stored
  stored="$(conf_get "$2")"
  if [[ -n "$1" ]]; then printf '%s\n' "$1"
  elif [[ "$stored" =~ ${4:-^(yes|no)$} ]]; then printf '%s\n' "$stored"
  else printf '%s\n' "$3"; fi
}

cmd_setup() {
  local stack project state='' enroll='' daily='' fresh='' encrypt='' keep='' uid gid user group old legacy encrypt_set switched='' stored_encrypt escrow=unknown
  while (($#)); do
    case "$1" in
      --state) (($# > 1)) || usage; state="$2"; shift 2 ;;
      --enroll) (($# > 1)) || usage; enroll="$2"; shift 2 ;;
      --daily) daily=yes; shift ;;
      --no-daily) daily=no; shift ;;
      --fresh-backup) fresh=yes; shift ;;
      --no-fresh-backup) fresh=no; shift ;;
      --encrypt) encrypt=yes; shift ;;
      --no-encrypt) encrypt=no; shift ;;
      --keep) (($# > 1)) || usage; keep="$2"; [[ "$keep" =~ ^[1-9][0-9]?$ ]] || die '--keep needs a whole number from 1 to 99: how many archives the drive keeps.'; shift 2 ;;
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
  # Ordered after the stack's boot unit, named as scripts/watch-timer.sh names it (<project>-stack; the same hash name when the project is unreadable).
  project="$(sed -n 's/^WAREHOUSE_PROJECT_NAME=//p' "$state/config/compose.env" 2>/dev/null | head -n 1)"
  if [[ "$project" =~ ^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$ ]]; then stack="$project-stack"
  else stack="warehouse-h$(printf '%s' "$state" | sha256sum | cut -c1-12)-stack"; fi
  [[ "$(stat -c %u -- "$state")" == "$uid" ]] || die "$state is not owned by $user."
  [[ "$(stat -c %u -- "$ROOT")" == "$uid" ]] || die "The checkout $ROOT is not owned by $user."
  # The helper copy runs as root, so its source must not be writable by anyone but its owner.
  [[ "$(stat -c %a -- "$SELF")" =~ ^[0-7][0145][0145]$ && "$(stat -c %a -- "$ROOT/scripts")" =~ ^[0-7][0145][0145]$ ]] || die "$SELF or its directory is group- or world-writable (a git pull under umask 0002 does this). As $user run: bash $ROOT/scripts/checkout-permissions.sh, then this setup again."
  old="$(conf_get STATE)"
  [[ -z "$old" || "$old" == "$state" ]] || die "USB backup is already set up for $old; run uninstall first."
  # Setup is run again after every checkout update, usually with nothing but --state.
  # That must not switch encryption or the daily timer off: only a named option changes a choice.
  daily="$(kept_setting "$daily" DAILY no)"; fresh="$(kept_setting "$fresh" FRESH_BACKUP yes)"
  keep="$(kept_setting "$keep" KEEP 3 '^[1-9][0-9]?$')"
  # Encryption is the default. A stored `no` is kept only when the operator typed --no-encrypt (ENCRYPT_SET=typed); a `no`
  # that is merely the old default is switched to `yes`, with a notice below, because it was never a choice.
  stored_encrypt="$(conf_get ENCRYPT)"
  if [[ -n "$encrypt" ]]; then
    encrypt_set=typed
    # A typed --encrypt over a stored `no` (typed or not) also starts the deletion of the readable archives: it gets the notice too.
    if [[ "$encrypt" == yes && "$stored_encrypt" == no ]]; then switched=typed; fi
  elif [[ "$stored_encrypt" == yes ]]; then encrypt=yes; encrypt_set="$(conf_get ENCRYPT_SET)"; [[ "$encrypt_set" == typed ]] || encrypt_set=default
  elif [[ "$stored_encrypt" == no && "$(conf_get ENCRYPT_SET)" == typed ]]; then encrypt=no; encrypt_set=typed
  else
    encrypt=yes; encrypt_set=default
    [[ "$stored_encrypt" != no ]] || switched=default
  fi
  # The key copy must be confirmed before a drive is enrolled for encrypted archives: checked before anything is installed.
  if [[ "$encrypt" == yes && -f "$state/config/backup.key" ]]; then
    load_backup_key_lib
    if backup_escrow_ok "$state"; then escrow=ok; else escrow=missing; fi
    if [[ -n "$enroll" && "$escrow" == missing ]]; then die "$(escrow_refusal "$state" 'run setup again.')"; fi
  fi

  # System directories created here must stay world-readable: under umask 077 a new
  # /usr/local/libexec became 0700, and the Docker CLI, which searches
  # /usr/local/libexec/docker/cli-plugins first, then failed every plugin with EACCES.
  (umask 022; mkdir -p "$LIBEXEC" "$UNITS")
  install -m 0755 -- "$SELF" "$HELPER"; chown root:root "$HELPER"
  local tmp; tmp="$(mktemp "$CONF.XXXXXX")"
  printf 'STATE=%s\nCHECKOUT=%s\nUSER=%s\nUID=%s\nGID=%s\nFRESH_BACKUP=%s\nDAILY=%s\nENCRYPT=%s\nENCRYPT_SET=%s\nKEEP=%s\n' "$state" "$ROOT" "$user" "$uid" "$gid" "$fresh" "$daily" "$encrypt" "$encrypt_set" "$keep" > "$tmp"
  chmod 0644 "$tmp"; mv -f -- "$tmp" "$CONF"
  # The enrolment list names the drives; only root reads it.
  [[ -f "$DRIVES" ]] || : > "$DRIVES"
  chmod 0600 "$DRIVES"; chown root:root "$DRIVES"

  cat > "$UNITS/$UNIT@.service" <<EOF
# Recipe: sha256:$RECIPE
[Unit]
Description=Warehouse backup to USB drive %I
Wants=docker.service
After=docker.service $stack.service

[Service]
Type=oneshot
User=$user
Group=$group
Environment=WAREHOUSE_STATE_DIR=$state
Environment=WAREHOUSE_USB_BACKUP_FRESH=$fresh
Environment=WAREHOUSE_BACKUP_ENCRYPT=$([[ "$encrypt" == yes ]] && echo 1 || echo 0)
Environment=WAREHOUSE_USB_KEEP=$keep
ExecStartPre=+$HELPER mount %I
ExecStart=/bin/bash $ROOT/scripts/backup-usb.sh run --device %I
ExecStopPost=+$HELPER unmount %I
TimeoutStartSec=6h
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

  echo "USB backup is set up for $state, running as $user (fresh backup on attach: $fresh, daily timer: $daily, encrypted archives: $encrypt, archives kept on a drive: $keep)."
  if [[ "$encrypt" == yes ]]; then
    echo "Archives are encrypted with the backup key $state/config/backup.key. Without a copy of that key, kept away from this machine and from the drive, the archives cannot be restored after the host is lost."
    if [[ -n "$switched" ]]; then
      if [[ "$switched" == default ]]; then
        echo 'NOTICE: this installation had USB backup set up with unencrypted archives, which was the default of earlier releases. Archives are now encrypted by default, so this setup switched them to encrypted ones. From the first encrypted archive that is written and verified, the unencrypted archives on enrolled drives are deleted. To keep readable archives, which put every credential on the drive, run setup again with --no-encrypt.'
      else
        echo 'NOTICE: this installation wrote unencrypted archives and you typed --encrypt, so they are now encrypted. From the first encrypted archive that is written and verified, the unencrypted archives on enrolled drives are deleted. To keep readable archives, which put every credential on the drive, run setup again with --no-encrypt.'
      fi
      echo 'Deleting a file does not wipe it from an exFAT drive: a drive that ever held readable archives still holds their contents until the space is overwritten. Before such a drive leaves your hands, rotate the credentials (rotate-keys.sh, the MSG91 key, the tunnel credential) or retire the drive; see "USB backup drive" in docs/OPERATOR_INSTALL.md.'
    fi
    if [[ "$escrow" == missing ]]; then
      echo "ACTION NEEDED: the backup key copy is not confirmed ($BACKUP_ESCROW_PROBLEM). Encrypted runs and enrolling a drive are refused until you run, as $user: WAREHOUSE_STATE_DIR=$state bash scripts/backup-key-escrow.sh show"
    fi
  else
    echo 'Archives are NOT encrypted (you typed --no-encrypt). They contain every credential of the instance. Run setup again with --encrypt to encrypt them with the backup key (confirm a copy of the key off this machine first: bash scripts/backup-key-escrow.sh show).'
  fi
  echo "Each drive keeps the newest $keep valid archives of this installation; older ones are deleted after a run that finishes without a failure (change it with --keep N)."
  [[ -n "$enroll" ]] || images_space_note "$state"
  # Lines of one column were written by a release that enrolled a drive by its volume serial alone.
  legacy="$(grep -E '^[A-Za-z0-9-]+$' "$DRIVES" || true)"
  while IFS= read -r D_UUID; do
    [[ -n "$D_UUID" ]] || continue
    echo "WARNING: drive $D_UUID was enrolled by an earlier release and is no longer accepted. Nothing is copied to it until you attach it and run: sudo bash scripts/backup-usb.sh enroll --device /dev/sdX1"
    record_refusal '' "Drive $D_UUID was enrolled by an earlier release and is no longer accepted; nothing is copied to it. Attach it and enroll it again: sudo bash scripts/backup-usb.sh enroll --device /dev/sdX1"
  done <<<"$legacy"
  [[ -s "$DRIVES" ]] || echo 'No drive is enrolled yet: attach the exFAT USB drive and run: sudo bash scripts/backup-usb.sh enroll --device /dev/sdX1'
  echo "From now on, attaching an enrolled drive runs the backup; it is unmounted when done."
  echo "Watch a run:  journalctl -f -u '$UNIT@*'      Last result:  bash scripts/backup-usb.sh status"
  echo 'After updating this checkout, run setup again so the installed root helper matches it; the choices above are kept unless you name another (--no-encrypt, --no-daily, --fresh-backup, --keep N).'
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
STATE=''; RESULT_FILE=''; DEST=''; DEVICE=''; ENCRYPT=0; KEEP=3; SUFFIX=tar
COPIED=0; PRESENT=0; FAILED=0; FAILURES=''; PRUNED=0; PLAIN_REMOVED=0; FRESH_TAKEN=0; ENC_VERIFIED=0; ROOM_MSG=''
ARCHIVE_NAME='^warehouse-[0-9]{8}T[0-9]{6}Z\.tar(\.enc)?$'
declare -A VCACHE=()
fail() { echo "FAILED: $*" >&2; FAILED=$((FAILED + 1)); FAILURES="${FAILURES:+$FAILURES; }$*"; }
human() { numfmt --to=iec-i --suffix=B "$1" 2>/dev/null || echo "$1 bytes"; }
# The free bytes of the file system holding $1. Returns 1, printing nothing, when no number can be read: an unreadable figure is
# never taken for zero, because a caller that deletes to make room would then delete for nothing.
free_bytes() {
  local n
  n="$(df -B1 --output=avail -- "$1" 2>/dev/null | tail -n1 | tr -d ' ')" || n=''
  [[ "$n" =~ ^[0-9]+$ ]] || return 1
  printf '%s\n' "$n"
}

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
# Returns 1 when the bytes do not match the checksum, 2 when they do and only the signature
# is not one of the current backup key (a replaced key, or a rewritten archive and checksum).
archive_ok() {
  [[ -f "$1.sha256" ]] && [[ "$(media_hash "$1")" == "$(cut -d' ' -f1 "$1.sha256")" ]] || return 1
  if [[ -e "$1.hmac" || "$1" == *.enc ]]; then backup_check_archive "$1" "$BACKUP_KEY" || return 2; fi
}
# archive_ok, remembered for the run, and whether the archive counts as one of this installation's: it matches its checksum and
# carries a valid signature of the current backup key (archive_ok alone also passes an archive from before signing).
archive_state() {
  local file="$1" state=0
  archive_ok "$file" || state=$?
  if ((state == 0)) && [[ -f "$file.hmac" && ! -L "$file.hmac" ]]; then VCACHE[$file]=ok; else VCACHE[$file]=bad; fi
  return "$state"
}
archive_valid() {
  case "${VCACHE[$1]:-}" in ok) return 0 ;; bad) return 1 ;; esac
  archive_state "$1" || true
  [[ "${VCACHE[$1]}" == ok ]]
}
# Archive files in the drive folder, newest name first (an encrypted archive before a readable one of the same backup).
drive_archives() { find "$DEST" -maxdepth 1 -type f \( -name 'warehouse-*.tar' -o -name 'warehouse-*.tar.enc' \) -printf '%f\n' | LC_ALL=C sort -r; }
drop_archive() { rm -f -- "$DEST/$1" "$DEST/$1.sha256" "$DEST/$1.hmac"; unset "VCACHE[$DEST/$1]"; }

# Local backups the run may copy, newest first: the ones the daily check verified (config/backups-verified.list, "name epoch"
# per line, written by scripts/watch.mjs; the file may not exist) that are still there, else every signed one. With `all`
# (a fresh backup was just taken, and nothing has verified it yet) every signed one.
backup_candidates() {
  local list="$STATE/config/backups-verified.list" name found=0
  if [[ "${1:-}" != all && -f "$list" && ! -L "$list" ]]; then
    while read -r name; do
      if [[ "$name" =~ ^warehouse-[0-9]{8}T[0-9]{6}Z$ && -d "$STATE/backups/$name" && ! -L "$STATE/backups/$name" ]]; then printf '%s\n' "$name"; found=1; fi
    done < <(awk 'NF { print $1 }' "$list" | LC_ALL=C sort -ru)
    if ((found)); then return 0; fi
  fi
  while read -r name; do
    if [[ -f "$STATE/backups/$name/SHA256SUMS.hmac" && ! -L "$STATE/backups/$name" ]]; then printf '%s\n' "$name"; fi
  done < <(find "$STATE/backups" -mindepth 1 -maxdepth 1 -type d -name 'warehouse-*' -printf '%f\n' 2>/dev/null | LC_ALL=C sort -r)
}
backup_epoch() { local t="${1#warehouse-}"; date -u -d "${t:0:4}-${t:4:2}-${t:6:2} ${t:9:2}:${t:11:2}:${t:13:2}" +%s 2>/dev/null || echo 0; }

# Makes room for an archive of NEED bytes on the drive by deleting the oldest valid archives of this installation while more
# than one remains (the newest valid archive is never deleted). Returns 1 when the room cannot be made; ROOM_MSG says why.
# Nothing is deleted when the free space cannot be read, nor when deleting every archive that may go would still not make room.
make_room() {
  local need="$1" avail f size i reclaim=0
  local -a own=()
  if ! avail="$(free_bytes "$DEST")"; then
    ROOM_MSG="could not read the free space of the drive ($DEST), so it cannot be checked that the new archive fits; nothing was written and nothing was deleted. Check the drive (dmesg, another USB port), then attach it again"
    return 1
  fi
  if ((avail > need)); then return 0; fi
  while IFS= read -r f; do
    if [[ "$f" =~ $ARCHIVE_NAME ]] && archive_valid "$DEST/$f"; then own+=("$f"); fi
  done < <(drive_archives)
  # The archives that may go are all but the newest valid one (own is newest first), with their checksum and signature files.
  for ((i = 1; i < ${#own[@]}; i++)); do
    size="$(stat -c %s -- "$DEST/${own[i]}" 2>/dev/null || echo 0)"
    reclaim=$((reclaim + size))
  done
  if ((avail + reclaim <= need)); then
    ROOM_MSG="drive too small: needs $(human "$need"), has $(human "$avail"); the drive must hold the new archive next to the newest valid one it already has (that one is never deleted), so use a larger drive"
    if ((${#own[@]} > 1)); then ROOM_MSG+=". No archive was deleted: deleting the $(( ${#own[@]} - 1 )) older one(s) would still not make room"; fi
    return 1
  fi
  while ((avail <= need && ${#own[@]} > 1)); do
    f="${own[${#own[@]} - 1]}"
    echo "Making room for the new archive: deleting the oldest valid archive on the drive, $f"
    drop_archive "$f"; unset "own[${#own[@]} - 1]"; sync; PRUNED=$((PRUNED + 1))
    if ! avail="$(free_bytes "$DEST")"; then
      ROOM_MSG="could not read the free space of the drive ($DEST) after deleting $f; nothing more was deleted and nothing was written"
      return 1
    fi
  done
  if ((avail > need)); then return 0; fi
  ROOM_MSG="drive too small: needs $(human "$need"), has $(human "$avail"); the drive must hold the new archive next to the newest valid one it already has (that one is never deleted), so use a larger drive"
  return 1
}

# Copies one local backup to the drive as one archive, reads it back and signs it. Returns 1 when the source backup is not
# good (the caller may try an older one) and 2 when the drive side failed.
copy_backup() {
  local n="$1" b="$STATE/backups/$1" archive="$DEST/$1.$SUFFIX" partial="$DEST/.$1.$SUFFIX.partial" need files problem hash
  local -a enc_arg=()
  # The signature, the list, every file and (v6) every file of the tree, before a byte is written.
  if ! problem="$(WAREHOUSE_BACKUP_KEY_FILE="$STATE/config/backup.key" backup_authenticate "$b" false 2>&1)"; then
    problem="${problem%%$'\n'*}"
    fail "source backup $n fails its checksums or signature, nothing copied (${problem#Refusing: })"
    return 1
  fi
  need="$(du -sb -- "$b" | cut -f1)"; files="$(find "$b" -type f | wc -l)"
  need=$((need + files * 2048 + 67108864))
  if ! make_room "$need"; then fail "$ROOM_MSG"; return 2; fi
  if ((ENCRYPT)); then enc_arg=(encrypt); fi
  # Hash the stream as it is written, then read the file back from the drive and compare.
  if ! hash="$(backup_archive_write "$b" "$partial" "${enc_arg[@]}")"; then
    rm -f -- "$partial"; fail "writing the archive of $n failed"; return 2
  fi
  sync -f "$partial" 2>/dev/null || sync
  if [[ "$(media_hash "$partial")" != "$hash" ]]; then
    rm -f -- "$partial"; fail "the archive of $n read back from the drive does not match what was written"; return 2
  fi
  # This function runs inside `|| copy_rc=$?` in the caller, where errexit does not apply: every step is checked by hand, and a
  # step that fails leaves neither the archive nor a sidecar file behind.
  if ! { printf '%s  %s\n' "$hash" "$n.$SUFFIX" > "$DEST/.$n.sha.partial" && mv -f -- "$DEST/.$n.sha.partial" "$archive.sha256"; }; then
    rm -f -- "$partial" "$DEST/.$n.sha.partial" "$archive.sha256"; fail "writing the checksum file of the archive of $n failed"; return 2
  fi
  # The signature covers the checksum line, so the archive cannot be swapped with its checksum.
  if ! backup_sign_archive "$archive" "$BACKUP_KEY"; then
    rm -f -- "$partial" "$archive.sha256" "$archive.hmac"; fail "signing the archive of $n failed"; return 2
  fi
  if ! mv -f -- "$partial" "$archive"; then
    rm -f -- "$partial" "$archive.sha256" "$archive.hmac"; fail "moving the archive of $n into place failed"; return 2
  fi
  sync -f "$archive" 2>/dev/null || sync
  VCACHE[$archive]=ok
  COPIED=$((COPIED + 1)); echo "Copied and verified from the drive: ${archive##*/}"
}

# Deletes the readable archives of this installation once an encrypted archive has been written and checked (they hold every
# credential). Only archives that carry this installation's signature are deleted; the others are reported by the caller.
remove_plaintext() {
  local f
  while IFS= read -r f; do
    [[ "$f" == *.tar && "$f" =~ $ARCHIVE_NAME ]] || continue
    if archive_valid "$DEST/$f"; then
      echo "Deleting the unencrypted archive $f: an encrypted archive has been written and verified in this run, and the backup key copy is confirmed."
      drop_archive "$f"; PLAIN_REMOVED=$((PLAIN_REMOVED + 1))
    fi
  done < <(drive_archives)
  if ((PLAIN_REMOVED)); then
    echo "NOTE: deleting a file does not wipe it from an exFAT drive: the readable archives just deleted can still be recovered with data-recovery tools until the space is overwritten, which is not certain. Before this drive leaves your hands, rotate the credentials they held (rotate-keys.sh, the MSG91 key, the tunnel credential) or retire the drive: docs/OPERATOR_INSTALL.md, \"USB backup drive\"."
  fi
}
# Keeps the newest KEEP valid archives of this installation. Damaged archives, unsigned ones and ones signed with another key
# are not counted and never deleted.
prune_drive() {
  local f listed
  local -a own=() other=()
  while IFS= read -r f; do
    if [[ "$f" =~ $ARCHIVE_NAME ]] && archive_valid "$DEST/$f"; then own+=("$f"); else other+=("$f"); fi
  done < <(drive_archives)
  for f in "${own[@]:KEEP}"; do
    echo "Deleting the archive $f: the drive keeps the newest $KEEP valid archives of this installation."
    drop_archive "$f"; PRUNED=$((PRUNED + 1))
  done
  if ((${#other[@]})); then
    listed="$(printf '%s, ' "${other[@]}")"
    echo "Not counted and not deleted (damaged, unsigned, or signed with another key): ${listed%, }. Remove them yourself if you no longer need them."
  fi
}

# The saved images on the drive (see the head of this file). SHA256SUMS lists every file of the folder except itself and its signature.
IMAGES_NOTE='none yet'; IMAGES_PROBLEM=''
# What went wrong with the images, said once, on stderr, and recorded; the archive copy stands (see the head of this file).
images_problem() {
  IMAGES_PROBLEM="$1"; IMAGES_NOTE="NOT copied: $1"
  echo "WARNING: saved images NOT copied: $1" >&2
}
# 0 when DIR has a signature and every file its SHA256SUMS names has the recorded hash as the drive returns it (media_hash).
images_verify() {
  local dir="$1" hash name
  [[ -f "$dir/SHA256SUMS" && ! -L "$dir/SHA256SUMS" && -f "$dir/SHA256SUMS.hmac" && ! -L "$dir/SHA256SUMS.hmac" ]] || return 1
  while read -r hash name; do
    [[ "$name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ && -f "$dir/$name" && ! -L "$dir/$name" ]] || return 1
    [[ "$(media_hash "$dir/$name")" == "$hash" ]] || return 1
  done < <(sed -n 's/^\([0-9a-f]\{64\}\)  \(.*\)$/\1 \2/p' "$dir/SHA256SUMS")
}
copy_images() {
  local src="$STATE/images" dst="$DEST/images" partial="$DEST/.images.partial" old="$DEST/.images.old" name size need=0 avail problem
  local -a names=()
  if [[ ! -d "$src" || -L "$src" ]]; then
    echo "No saved images in $src yet, so none were copied. bash scripts/build-images.sh --save writes them; the next copy to the drive takes them."
    return 0
  fi
  # The folder on the drive is current when it has the same signed list and signature, and every file is as the list says.
  if [[ -f "$src/SHA256SUMS" && -f "$src/SHA256SUMS.hmac" ]] && cmp -s -- "$src/SHA256SUMS" "$dst/SHA256SUMS" 2>/dev/null && cmp -s -- "$src/SHA256SUMS.hmac" "$dst/SHA256SUMS.hmac" 2>/dev/null; then
    if images_verify "$dst"; then IMAGES_NOTE='already present'; echo 'The saved images are already on the drive and verified.'; return 0; fi
    echo 'The saved images on the drive do not match their list; copying them again.'
  fi
  # Only a folder that proves itself genuine is copied, as db:restore-host will only load one that does.
  if ! problem="$(WAREHOUSE_BACKUP_KEY_FILE="$STATE/config/backup.key" backup_authenticate "$src" false 2>&1)"; then
    problem="${problem%%$'\n'*}"
    images_problem "$src does not authenticate with the backup key (${problem#Refusing: }). Run bash scripts/build-images.sh --save, which signs the images with the key in use, then attach the drive again"
    return 0
  fi
  mapfile -t names < <(sed -n 's/^[0-9a-f]\{64\}  //p' "$src/SHA256SUMS")
  for name in "${names[@]}"; do
    if [[ ! "$name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then images_problem "the signed list in $src names a file that cannot be copied safely: $name"; return 0; fi
    size="$(stat -c %s -- "$src/$name" 2>/dev/null || echo 0)"; need=$((need + size))
  done
  need=$((need + 67108864))
  if ! avail="$(free_bytes "$DEST")"; then
    images_problem "could not read the free space of the drive ($DEST), so it cannot be checked that they fit. Check the drive (dmesg, another USB port), then attach it again"
    return 0
  fi
  if ((avail <= need)); then
    images_problem "drive too small: they need $(human "$need") next to what is on the drive after this run's pruning, and it has $(human "$avail") free (a changed set is written beside the old one, so a drive needs room for both while it is replaced). The archives are not touched by this. Use a larger drive"
    return 0
  fi
  rm -rf -- "$partial" "$old"
  mkdir -- "$partial" || { images_problem 'writing them to the drive failed'; return 0; }
  for name in "${names[@]}" SHA256SUMS SHA256SUMS.hmac; do
    cp -- "$src/$name" "$partial/$name" || { rm -rf -- "$partial"; images_problem "writing them to the drive failed (copying $name)"; return 0; }
  done
  sync -f "$partial" 2>/dev/null || sync
  if ! cmp -s -- "$src/SHA256SUMS" "$partial/SHA256SUMS" || ! cmp -s -- "$src/SHA256SUMS.hmac" "$partial/SHA256SUMS.hmac" || ! images_verify "$partial"; then
    rm -rf -- "$partial"; images_problem 'what was read back from the drive does not match what was written'; return 0
  fi
  if [[ -e "$dst" ]] && ! mv -- "$dst" "$old"; then rm -rf -- "$partial"; images_problem 'replacing the earlier copy on the drive failed; it is untouched'; return 0; fi
  if ! mv -- "$partial" "$dst"; then
    [[ ! -e "$old" ]] || mv -- "$old" "$dst" || true
    rm -rf -- "$partial"; images_problem 'moving them into place on the drive failed'; return 0
  fi
  rm -rf -- "$old"
  sync
  IMAGES_NOTE='copied'
  echo "Copied the saved images to the drive and verified them: $((${#names[@]})) file(s), $(human "$((need - 67108864))"), in ${dst#"$DEST"/}/ beside the archives."
}

record() {
  local result="$1" message="$2" now last_ok tmp report
  now="$(date +%s)"
  last_ok="$(sed -n 's/^last_success_epoch=//p' "$RESULT_FILE" 2>/dev/null | head -n1 || true)"
  [[ "$result" != ok ]] || last_ok="$now"
  report="$(printf 'result=%s\nfinished_utc=%s\nfinished_epoch=%s\nlast_success_epoch=%s\ndrive_uuid=%s\ndevice=%s\ncopied=%s\nalready_present=%s\nfailed=%s\nimages_problem=%s\nmessage=%s\n' \
    "$result" "$(date -u -d "@$now" +%Y-%m-%dT%H:%M:%SZ)" "$now" "$last_ok" "$D_UUID" "$DEVICE" "$COPIED" "$PRESENT" "$FAILED" "${IMAGES_PROBLEM//$'\n'/ }" "${message//$'\n'/ }")"
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
      echo "A run keeps the newest $KEEP valid archives of this installation on this drive and deletes older ones."
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
  local name mp data_mm mp_mm label n archive newest candidate unsigned first_unsigned tmp instance_id id_file marker recorded plain=0 state copy_rc small avail age f base
  local -a cands=()
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
  # Archives are encrypted unless the operator typed --no-encrypt at setup (the unit then sets WAREHOUSE_BACKUP_ENCRYPT=0).
  [[ "${WAREHOUSE_BACKUP_ENCRYPT:-1}" == 0 ]] || ENCRYPT=1
  KEEP="${WAREHOUSE_USB_KEEP:-3}"
  [[ "$KEEP" =~ ^[1-9][0-9]?$ ]] || die "WAREHOUSE_USB_KEEP must be a whole number from 1 to 99 (setup --keep N): $KEEP"
  SUFFIX=tar; if ((ENCRYPT)); then SUFFIX=tar.enc; fi
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
  load_archive_lib
  instance_id="$(instance_id_of "$STATE")"
  marker="$mp/$TOP/$ENROLMENT"
  recorded=''
  if [[ -f "$marker" && ! -L "$marker" ]]; then recorded="$(sed -n 's/^hmac=//p' "$marker" | head -n1)"; fi
  if [[ ! -f "$STATE/config/backup.key" || -z "$instance_id" || -z "$recorded" ]] || ! backup_key_load "$STATE/config/backup.key" 2>/dev/null ||
     [[ "$recorded" != "$(enrolment_hmac "$BACKUP_KEY" "$instance_id")" ]]; then
    die "Drive $D_UUID ($DEVICE) is not enrolled for this installation (no valid enrolment marker for this drive); nothing was copied. Run: sudo bash scripts/backup-usb.sh enroll --device $DEVICE"
  fi
  # An encrypted archive is lost with the host unless a copy of the key exists elsewhere: nothing is written, and no fresh
  # backup is taken for it, until the operator has confirmed one.
  if ((ENCRYPT)) && ! backup_escrow_ok "$STATE"; then
    die "$(escrow_refusal "$STATE" 'attach the drive again. Nothing was written to the drive.')"
  fi
  echo "Backing up to drive $D_UUID ($DEVICE, mounted at $mp)."

  # A fresh backup stops the write-facing services briefly, so it is taken only when the newest verified backup is older than
  # 20 hours: a drive attached in the morning after the night's backup copies that one and stops nothing.
  if [[ "${WAREHOUSE_USB_BACKUP_FRESH:-yes}" != no ]]; then
    mapfile -t cands < <(backup_candidates)
    age=-1
    if ((${#cands[@]})); then age=$(( $(date +%s) - $(backup_epoch "${cands[0]}") )); fi
    if ((age >= 0 && age < 72000)); then
      echo "The newest verified backup (${cands[0]}) is $((age / 3600)) hours old; no fresh backup is taken."
    # backup.sh takes the operator lock itself; wait until no other operator command holds it.
    elif ( exec 9>"$STATE/config/operator.lock"; flock -w "$LOCK_WAIT" 9 ); then
      echo 'Taking a fresh backup (write-facing services stop briefly).'
      if bash "$ROOT/scripts/backup.sh"; then FRESH_TAKEN=1; else fail 'the fresh backup failed; existing backups are still copied'; fi
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
  # A copy of the saved images that was interrupted between its two renames (copy_images) leaves the only good copy as .images.old and
  # no `images` folder: it is put back first, before the leftovers are cleared. The copy below checks it and writes a new one if needed.
  if [[ ! -e "$DEST/images" && ! -L "$DEST/images" && -d "$DEST/.images.old" && ! -L "$DEST/.images.old" ]]; then
    if mv -- "$DEST/.images.old" "$DEST/images"; then echo 'The earlier saved images were put back (images/): the last copy to the drive was interrupted while it replaced them.'
    else echo 'Warning: could not put the earlier saved images (.images.old) back; they are left where they are.' >&2; fi
  fi
  rm -rf -- "$DEST/.images.partial"
  if [[ -e "$DEST/images" || -L "$DEST/images" ]]; then rm -rf -- "$DEST/.images.old"; fi
  # A checksum or signature file whose archive is not there is what an interrupted copy leaves (the sidecars are written before
  # the archive is moved into place); nothing else would ever remove it.
  while IFS= read -r f; do
    base="${f%.sha256}"; base="${base%.hmac}"
    if [[ "$base" =~ $ARCHIVE_NAME && ! -e "$DEST/$base" ]]; then
      echo "Removing the leftover checksum or signature file $f: its archive is not on the drive."
      rm -f -- "$DEST/$f"
    fi
  done < <(find "$DEST" -maxdepth 1 -type f \( -name 'warehouse-*.sha256' -o -name 'warehouse-*.hmac' \) -printf '%f\n' | LC_ALL=C sort)

  # Only the newest verified backup is copied, as one archive: the drive keeps the newest few, so an older local backup is
  # not copied now. A backup that fails its own check is named and the next older one is tried.
  if ((FRESH_TAKEN)); then mapfile -t cands < <(backup_candidates all); else mapfile -t cands < <(backup_candidates); fi
  if ((${#cands[@]} == 0)); then fail 'there is no verified or signed backup to copy; take one with npm run db:backup'; fi
  for n in "${cands[@]}"; do
    archive="$DEST/$n.$SUFFIX"
    # A readable archive of this backup does not stand in for the encrypted one (the run replaces it); an encrypted archive
    # does stand in for a readable one, which would put the credentials in the clear next to it.
    if ((ENCRYPT == 0)) && [[ ! -e "$archive" && -e "$DEST/$n.tar.enc" ]]; then archive="$DEST/$n.tar.enc"; fi
    if [[ -e "$archive" ]]; then
      state=0; archive_state "$archive" || state=$?
      if ((state == 0)); then PRESENT=$((PRESENT + 1)); echo "Already on the drive and verified: ${archive##*/}"
      elif ((state == 2)); then fail "the archive of $n on the drive matches its checksum but was not signed with the current backup key; it was not overwritten. If you replaced the backup key, move the archives written before that into another folder on the drive (they verify only with the old key); otherwise the archive was changed on the drive"
      else fail "the archive of $n on the drive does not match its checksum or signature; it was not overwritten"; fi
      break
    fi
    copy_rc=0; copy_backup "$n" || copy_rc=$?
    # Done, or the drive side failed (an older backup would fail the same way); only a bad source backup tries the next one.
    if ((copy_rc != 1)); then break; fi
  done

  # The restore check opens the newest archive this installation signed. An archive
  # without a valid signature is never unpacked: anyone holding the drive can add a
  # later-dated file with a matching checksum, and it must neither be opened nor take
  # the place of the genuine newest backup.
  newest=''; n=''; unsigned=0; first_unsigned=''
  while IFS= read -r candidate; do
    if backup_check_archive "$DEST/$candidate" "$BACKUP_KEY"; then newest="$candidate"; break; fi
    unsigned=$((unsigned + 1)); [[ -n "$first_unsigned" ]] || first_unsigned="$candidate"
  done < <(drive_archives)
  if ((unsigned)); then
    fail "the archive $first_unsigned on the drive carries no valid signature of this installation's backup key; it was not opened ($unsigned such archive(s) are newer than every archive this installation signed). An earlier release wrote unsigned archives: take a new backup with npm run db:backup. Otherwise remove them from the drive unless you put them there"
  fi
  n="${newest%.enc}"; n="${n%.tar}"
  if [[ -z "$newest" ]]; then
    ((unsigned)) || fail 'there is no backup on the drive; take one with npm run db:backup'
  elif [[ "${WAREHOUSE_USB_BACKUP_VERIFY_RESTORE:-yes}" != no ]]; then
    # The archive is hashed and its signature checked before anything is read out of it: the size estimate below lists it.
    small=''
    if ! archive_valid "$DEST/$newest"; then
      fail "restore verification of $n from the drive failed: the archive $newest does not match its checksum or its signature (it is damaged); it was not opened"
    elif small="$(backup_archive_small_bytes "$DEST/$newest")"; then
      # Only the small files are unpacked, onto the data disk: the photos are vouched for by the manifest the signature covers
      # and by the hash made as the archive was written, and unpacking them would fill the disk the application runs on.
      if avail="$(free_bytes "$STATE")"; then
        if ((avail < small + 268435456)); then
          fail "not enough free space in $STATE to check $n from the drive: its small files need $(human "$small") plus 256 MiB, and $(human "$avail") are free; free disk space, then attach the drive again"
          small=''
        fi
      else
        fail "could not read the free space of $STATE, so the restore check of $n from the drive was not run; check the disk, then attach the drive again"
        small=''
      fi
    else
      fail "restore verification of $n from the drive failed: the archive could not be listed"
      small=''
    fi
    if [[ -n "$small" ]]; then
      tmp="$(mktemp -d "$STATE/.usb-verify.XXXXXX")"; TMPDIRS+=("$tmp")
      if backup_archive_extract "$DEST/$newest" "$tmp" --no-tree &&
         [[ -f "$tmp/$n/SHA256SUMS.hmac" ]] && bash "$ROOT/scripts/verify-restore.sh" --no-storage-tree "$tmp/$n"; then
        echo "Restore verification of the copy on the drive passed: $n"
        if [[ "$newest" == *.enc ]]; then ENC_VERIFIED=1; fi
      elif [[ -d "$tmp/$n" && ! -e "$tmp/$n/SHA256SUMS.hmac" ]]; then
        fail "the newest backup on the drive ($n) is unsigned, written by an earlier release, so its restore was not verified; take a new backup with npm run db:backup"
      else
        fail "restore verification of $n from the drive failed"
      fi
      rm -rf -- "$tmp"
    fi
  else
    # Restore verification was switched off (a test switch): the archive written in this run was read back and compared, but it
    # was not opened, and deleting the readable archives is not done on a hash alone.
    echo 'Restore verification is switched off (WAREHOUSE_USB_BACKUP_VERIFY_RESTORE=no): no unencrypted archive is deleted in this run.'
  fi

  # Deleting happens only after a run that finished without a failure, and only with the key copy confirmed (the run is not
  # here otherwise).
  if ((FAILED == 0)); then
    if ((ENCRYPT && ENC_VERIFIED)); then remove_plaintext; fi
    prune_drive
  fi

  # The saved images come last: the room they need is measured on the drive as it is after the pruning, and a problem with them is
  # recorded apart from the archive copy (images_problem) and never holds the deletions above back.
  copy_images
  [[ -z "$(find "$DEST" -maxdepth 1 -type f -name 'warehouse-*.tar' -print -quit)" ]] || plain=1

  echo "Summary: copied=$COPIED already-present=$PRESENT failed=$FAILED pruned=$PRUNED unencrypted-removed=$PLAIN_REMOVED. The drive keeps the newest $KEEP valid archives of this installation; damaged, unsigned and foreign archives are reported and never deleted."
  if ((ENCRYPT == 0)); then
    echo 'WARNING: the archives are not encrypted and contain every credential of this instance. Keep the drive locked away.'
  elif ((plain)); then
    echo 'WARNING: archives written by this run are encrypted, but the drive still holds unencrypted .tar archives from earlier runs; they contain every credential of this instance. They are deleted by a run that writes and verifies an encrypted archive and finishes without a failure; otherwise remove them yourself.'
  else
    echo "The archives are encrypted with the backup key $STATE/config/backup.key. Keep a copy of that key away from this machine and from the drive: without it they cannot be restored."
  fi
  if ((FAILED)); then record failed "$FAILURES"; exit 1; fi
  record ok "copied $COPIED, already present $PRESENT, pruned $PRUNED, unencrypted removed $PLAIN_REMOVED, restore verified $n, saved images $IMAGES_NOTE"
}

# Internal: called by the root helper through setpriv, as the installation user.
cmd_refused() {
  local name="${1:-}" uuid="${2:-}" message="${3:-}"
  [[ "$(id -u)" != 0 ]] || die 'refused records as the installation user, never as root.'
  STATE="$(conf_get STATE)"
  [[ -n "$STATE" && -d "$STATE/config" && ! -L "$STATE/config" && -O "$STATE/config" ]] || die "$CONF names no operator state of this user."
  [[ "$uuid" =~ ^[A-Za-z0-9-]+$ && -n "$message" ]] || usage
  [[ -z "$name" ]] || DEVICE="/dev/$(kname "$name")"
  RESULT_FILE="$STATE/config/usb-backup.last"; D_UUID="$uuid"
  record failed "$message"
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
  echo "Set up for $state as $(conf_get USER) (fresh backup on attach: $(conf_get FRESH_BACKUP), daily timer: $(conf_get DAILY), encrypted archives: $(conf_get ENCRYPT), archives kept on a drive: $(conf_get KEEP))."
  if [[ -f "$HELPER" ]] && ! cmp -s -- "$HELPER" "$SELF"; then
    echo 'WARNING: the installed root helper differs from this checkout; run setup again.'
  fi
  # The udev rule and the unit carry the recipe hash of the script that wrote them (the root_copy_stale alert of scripts/watch.mjs compares it).
  for f in "$RULE" "$UNITS/$UNIT@.service"; do
    [[ -f "$f" ]] && ! grep -qxF -- "# Recipe: sha256:$RECIPE" "$f" 2>/dev/null || continue
    echo "WARNING: $f was written by an earlier release of this script; run setup again."
  done
  if [[ "$(conf_get ENCRYPT)" == no && "$(conf_get ENCRYPT_SET)" != typed ]]; then
    echo 'WARNING: archives are still written unencrypted, which was the default of earlier releases. Run setup again (sudo bash scripts/backup-usb.sh setup --state "$WAREHOUSE_STATE_DIR"): it switches them to encrypted archives.'
  fi
  if conf_encrypts && [[ -f "$state/config/backup.key" ]]; then
    load_backup_key_lib
    if backup_escrow_ok "$state"; then echo 'Backup key copy: confirmed.'
    else echo "WARNING: the backup key copy is not confirmed ($BACKUP_ESCROW_PROBLEM). Encrypted runs and enrolling a drive are refused until you run: WAREHOUSE_STATE_DIR=$state bash scripts/backup-key-escrow.sh show"; fi
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
  refused) cmd_refused "$@" ;;
  status) cmd_status "$@" ;;
  -h|--help|help) usage ;;
  *) usage ;;
esac
