#!/usr/bin/env bash
# The systemd timer for scripts/watch.mjs, the installation's one monitoring check: every 5 minutes it runs the
# checks and posts to the facility's Slack webhook; once a day it also makes and verifies a backup and applies retention.
#
#   sudo bash scripts/watch-timer.sh install [--state DIR] [--node PATH] [--daily-at HH:MM]
#   sudo bash scripts/watch-timer.sh uninstall [--state DIR]
#   bash scripts/watch-timer.sh status
#   bash scripts/watch-timer.sh hint
#
# hint is what setup.sh, start.sh and restore-host.sh run: silent when the timer is installed for this state, else
# it prints the install command. Those scripts never run sudo themselves (like tunnel.sh and backup-usb.sh).
# --daily-at is the host's local time (the time zone is printed by install and status); a rerun without it keeps the
# installed time. The daily backup, verification, pruning and retention may run up to 6 hours after it (a missed time
# is caught up inside that window, never later), and not more than 3 times a day.
# All commands read WAREHOUSE_STATE_DIR (install and uninstall also accept --state DIR). The units run as the user who ran
# sudo (the installation user), never as root, with that user's Node.js: Node is installed per user (~/.local/opt), so
# the unit names its absolute path and puts its directory first in PATH.
set -euo pipefail
umask 077
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Test override; printed by status whenever it is set.
UNITS="${WAREHOUSE_WATCH_UNIT_DIR:-/etc/systemd/system}"
die() { echo "$*" >&2; exit 1; }
usage() {
  cat >&2 <<'USAGE'
sudo bash scripts/watch-timer.sh install [--state DIR] [--node PATH] [--daily-at HH:MM]
sudo bash scripts/watch-timer.sh uninstall [--state DIR]
bash scripts/watch-timer.sh status
bash scripts/watch-timer.sh hint
USAGE
  exit 1
}
# The same rule backup-usb.sh applies to paths that go into a unit file, plus a stricter alphabet for the state.
safe_path() { [[ "$1" == /* && "$1" =~ ^/[A-Za-z0-9._/+-]+$ ]] || die "$2 must be an absolute path of letters, digits, '.', '_', '-', '+' and '/' only: $1"; }
host_zone() {
  local zone
  zone="$(timedatectl show -p Timezone --value 2>/dev/null || true)"
  [[ -n "$zone" ]] || zone="$(cat /etc/timezone 2>/dev/null || true)"
  [[ -n "$zone" ]] || zone="$(date +%Z)"
  printf '%s\n' "$zone"
}
# The value an installed unit already carries, so a rerun without the option keeps it (like backup-usb.sh).
unit_setting() { sed -n "s/^Environment=$2=//p" "$1" 2>/dev/null | head -n 1; }
node_at_least_22_18() {
  local version="${1#v}"
  [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]] || return 1
  [[ "$(printf '22.18.0\n%s\n' "$version" | sort -V | head -n 1)" == 22.18.0 ]]
}

state_shape() {
  local state="${1:-${WAREHOUSE_STATE_DIR:-}}"
  [[ -n "$state" ]] || die 'Set WAREHOUSE_STATE_DIR (or --state) to the operator state path.'
  safe_path "$state" 'The state path'
  printf '%s\n' "$state"
}
state_dir() {
  local state
  state="$(state_shape "${1:-}")"
  [[ ! -L "$state" && -f "$state/config/compose.env" && -f "$state/public/instance.json" ]] \
    || die 'Set WAREHOUSE_STATE_DIR (or --state) to the installed operator state.'
  printf '%s\n' "$state"
}
# The unit name comes from the facility, not from the directory name (two installs may both end in /state): the
# Compose project WAREHOUSE_PROJECT_NAME in config/compose.env, which is unique per host. When that cannot be read
# (the state is gone) an installed unit that names this state is found first (so uninstall still works), else a short
# hash of the state path is used. scripts/doctor.mjs (timerBase) must build the same name.
unit_base() {
  local project='' file
  [[ -f "$1/config/compose.env" && ! -L "$1/config/compose.env" ]] && project="$(sed -n 's/^WAREHOUSE_PROJECT_NAME=//p' "$1/config/compose.env" 2>/dev/null | head -n 1)"
  if [[ "$project" =~ ^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$ ]]; then printf '%s-watch\n' "$project"
  else
    for file in "$UNITS"/*-watch.service; do
      [[ -f "$file" && "$(unit_setting "$file" WAREHOUSE_STATE_DIR)" == "$1" ]] || continue
      basename "$file" .service; return 0
    done
    printf 'warehouse-h%s-watch\n' "$(printf '%s' "$1" | sha256sum | cut -c1-12)"
  fi
}

cmd_install() {
  local state='' node='' daily='' uid gid user group base tmp home path existing version
  while (($#)); do
    case "$1" in
      --state) (($# > 1)) || usage; state="$2"; shift 2 ;;
      --node) (($# > 1)) || usage; node="$2"; shift 2 ;;
      --daily-at) (($# > 1)) || usage; daily="$2"; shift 2 ;;
      *) usage ;;
    esac
  done
  [[ -z "$daily" || "$daily" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]] || die "--daily-at must be HH:MM (24-hour, local time): $daily"
  [[ "$(id -u)" == 0 ]] || die 'install writes systemd units: run it with sudo from the installation user.'
  safe_path "$ROOT" 'The checkout path'
  state="$(state_dir "$state")"
  uid="${SUDO_UID:-}"; gid="${SUDO_GID:-}"
  [[ "$uid" =~ ^[1-9][0-9]*$ && "$gid" =~ ^[0-9]+$ ]] || die 'Run install through sudo from the installation user (SUDO_UID is missing or 0); monitoring must not run as root.'
  [[ "$(stat -c %u -- "$state")" == "$uid" ]] || die "$state is not owned by the user who ran sudo."
  user="$(getent passwd "$uid" | cut -d: -f1)"; group="$(getent group "$gid" | cut -d: -f1)"
  [[ -n "$user" && -n "$group" ]] || die "Cannot resolve user $uid or group $gid."
  # Node: --node, else WAREHOUSE_NODE, else the installation user's own login PATH, else this shell's.
  [[ -n "$node" ]] || node="${WAREHOUSE_NODE:-}"
  if [[ -z "$node" ]] && command -v runuser >/dev/null 2>&1; then
    node="$(runuser -u "$user" -- bash -lc 'command -v node' 2>/dev/null || true)"
  fi
  [[ -n "$node" ]] || node="$(command -v node || true)"
  [[ "$node" =~ ^/[A-Za-z0-9._/+-]+$ && -x "$node" ]] || die 'Cannot find the installation user'"'"'s Node.js; pass --node /absolute/path/to/node.'
  command -v runuser >/dev/null 2>&1 || die 'runuser is needed to check Node.js and Docker as the installation user.'
  version="$(runuser -u "$user" -- "$node" --version 2>/dev/null || true)"
  node_at_least_22_18 "$version" || die "Node.js 22.18 or newer is needed as user $user; $node reports: ${version:-nothing}."
  runuser -u "$user" -- docker info >/dev/null 2>&1 || die "Docker does not answer for user $user (docker info failed): is the user in the docker group and the daemon running?"
  home="$(dirname "$node")"
  path="$home:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
  base="$(unit_base "$state")"
  existing="$UNITS/$base.service"
  if [[ -f "$existing" ]]; then
    [[ "$(unit_setting "$existing" WAREHOUSE_STATE_DIR)" == "$state" ]] \
      || die "$existing already belongs to another state ($(unit_setting "$existing" WAREHOUSE_STATE_DIR)); the unit name comes from the facility's Compose project. Uninstall it first."
    [[ -n "$daily" ]] || daily="$(unit_setting "$existing" WAREHOUSE_WATCH_DAILY_AT)"
  fi
  [[ "$daily" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]] || daily='02:30'
  mkdir -p -- "$UNITS"
  tmp="$(mktemp "$UNITS/.$base.service.XXXXXX")"
  cat > "$tmp" <<UNIT
# Managed by scripts/watch-timer.sh: one monitoring pass for $state (scripts/watch.mjs run).
[Unit]
Description=Warehouse monitoring check for $state
Wants=network-online.target
After=network-online.target docker.service

[Service]
Type=oneshot
User=$user
Group=$group
WorkingDirectory=$ROOT
Environment=WAREHOUSE_STATE_DIR=$state
Environment=WAREHOUSE_WATCH_DAILY_AT=$daily
Environment=PATH=$path
ExecStart=$node $ROOT/scripts/watch.mjs run
# The daily pass (scripts/watch-daily.sh) limits its steps to 90 + 60 + 15 minutes plus the prune: well inside this.
TimeoutStartSec=4h
TimeoutStopSec=5min
UNIT
  chmod 0644 "$tmp"; mv -f -- "$tmp" "$UNITS/$base.service"
  tmp="$(mktemp "$UNITS/.$base.timer.XXXXXX")"
  cat > "$tmp" <<UNIT
# Managed by scripts/watch-timer.sh.
[Unit]
Description=Warehouse monitoring check every 5 minutes for $state

[Timer]
OnCalendar=*:0/5
AccuracySec=10s
Persistent=true
Unit=$base.service

[Install]
WantedBy=timers.target
UNIT
  chmod 0644 "$tmp"; mv -f -- "$tmp" "$UNITS/$base.timer"
  systemctl daemon-reload
  systemctl enable --now "$base.timer" >/dev/null
  echo "$base.timer is enabled: checks every 5 minutes as $user; the daily backup, verification and retention run at $daily."
  echo "Time zone: $(host_zone) (the daily time is local to it; a pass may run up to 6 hours after $daily)."
  echo "Check it with: bash scripts/watch-timer.sh status   and   node scripts/watch.mjs status"
}

cmd_uninstall() {
  local state='' base
  while (($#)); do
    case "$1" in
      --state) (($# > 1)) || usage; state="$2"; shift 2 ;;
      *) usage ;;
    esac
  done
  [[ "$(id -u)" == 0 ]] || die 'uninstall removes systemd units: run it with sudo.'
  # The shape of the path is enough: the state directory may already be gone.
  state="$(state_shape "$state")"
  base="$(unit_base "$state")"
  systemctl disable --now "$base.timer" >/dev/null 2>&1 || true
  if systemctl is-active --quiet "$base.service" 2>/dev/null; then
    systemctl stop "$base.service" || echo "Warning: $base.service is still running and could not be stopped; a daily pass may be in progress." >&2
  fi
  rm -f -- "$UNITS/$base.timer" "$UNITS/$base.service"
  systemctl daemon-reload
  systemctl reset-failed "$base.service" "$base.timer" >/dev/null 2>&1 || true
  echo "Removed $base.timer and $base.service."
}

cmd_status() {
  local state base
  state="$(state_dir)"; base="$(unit_base "$state")"
  [[ -z "${WAREHOUSE_WATCH_UNIT_DIR:-}" ]] || echo "Test override: WAREHOUSE_WATCH_UNIT_DIR=$UNITS"
  echo "Time zone: $(host_zone)"
  if [[ -f "$UNITS/$base.timer" ]]; then
    if grep -qxF -- "Environment=WAREHOUSE_STATE_DIR=$state" "$UNITS/$base.service" 2>/dev/null; then echo "Timer: $base.timer is installed for $state."
    else echo "Timer: $base.timer is installed but its service does not name $state; run: sudo bash scripts/watch-timer.sh install --state $state"; fi
    echo "Timer state: $(systemctl is-active "$base.timer" 2>/dev/null || true)"
  else
    echo "Timer: $base.timer is not installed. Run: sudo bash scripts/watch-timer.sh install --state $state"
  fi
}

cmd_hint() {
  local state base svc
  state="$(state_shape)"; base="$(unit_base "$state")"; svc="$UNITS/$base.service"
  if [[ -f "$UNITS/$base.timer" ]] && grep -qxF -- "Environment=WAREHOUSE_STATE_DIR=$state" "$svc" 2>/dev/null; then
    # Installed for this state: say so only when it runs another checkout (a moved or replaced checkout).
    if grep -qxF -- "WorkingDirectory=$ROOT" "$svc" 2>/dev/null && [[ "$(sed -n 's/^ExecStart=[^ ]* //p' "$svc" | head -n 1)" == "$ROOT/scripts/watch.mjs run" ]]; then return 0; fi
    echo "The monitoring checker timer is installed for $state but runs another checkout of this software. Refresh it (needs sudo):"
    echo "  sudo bash $ROOT/scripts/watch-timer.sh install --state $state"
    return 0
  fi
  echo "The monitoring checker timer is not installed for $state: no check, Slack alert, daily backup or retention runs until it is. Install it (needs sudo):"
  echo "  sudo bash $ROOT/scripts/watch-timer.sh install --state $state"
}

(($#)) || usage
cmd="$1"; shift
case "$cmd" in
  install) cmd_install "$@" ;;
  uninstall) cmd_uninstall "$@" ;;
  status) (($# == 0)) || usage; cmd_status ;;
  hint) (($# == 0)) || usage; cmd_hint ;;
  *) usage ;;
esac
