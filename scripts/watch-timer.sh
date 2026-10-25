#!/usr/bin/env bash
# The systemd units for scripts/watch.mjs, the installation's one monitoring check: every 5 minutes it runs the
# checks and posts to the facility's Slack webhook; once a day it also makes and verifies a backup and applies retention.
# A second unit starts the services at boot, so the ones a power cut left stopped come back by themselves.
#
#   sudo bash scripts/watch-timer.sh install [--state DIR] [--node PATH] [--daily-at HH:MM]
#   sudo bash scripts/watch-timer.sh uninstall [--state DIR]
#   bash scripts/watch-timer.sh status
#   bash scripts/watch-timer.sh hint
#
# hint is what setup.sh, start.sh and restore-host.sh run: silent when the units are installed for this state, else
# it prints the install command. Those scripts never run sudo themselves (like tunnel.sh and backup-usb.sh).
#
# Units written (<base> is <Compose project>-watch):
#   <base>.service/.timer                  the 5-minute checks (watch.mjs run); never runs a backup
#   <project>-daily.service/.timer         the daily backup, verification, pruning and retention (watch.mjs daily), at the
#                                          chosen time and each of the 5 hours after it (a pass that failed, or found the
#                                          services down, is tried again at the next one; one that is done does nothing)
#   <project>-stack.service                boot: `compose up -d` for the default profile after docker.service. It is enabled,
#                                          not started, by install (so install never changes what is running). A reboot
#                                          therefore also undoes a deliberate stop.sh; to keep the stack down:
#                                          sudo systemctl disable <project>-stack.service
# --daily-at is the host's local time (the time zone is printed by install and status); a rerun without it keeps the
# installed time. The daily backup, verification, pruning and retention may run up to 6 hours after it (a missed time
# is caught up inside that window, never later), and not more than 3 times a day.
# All commands read WAREHOUSE_STATE_DIR (install and uninstall also accept --state DIR). The units run as the user who ran
# sudo (the installation user), never as root, with that user's Node.js. Node is installed per user (~/.local/opt), and
# a unit that named its versioned directory would stop for good the day that directory is removed: install makes the link
# ~/.local/opt/node-current point at the Node.js prefix in use, and the units name the link (ExecStart and PATH). After a
# Node.js upgrade, move the link (`ln -sfn NEW_PREFIX ~/.local/opt/node-current`) or run install again with --node.
# WAREHOUSE_NODE_LINK overrides the link's path.
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
unit_setting() { sed -n "s/^Environment=$2=//p" "$1" 2>/dev/null | head -n 1 || true; }
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

# systemd OnCalendar for the daily pass: the chosen time and the 5 hours after it, all at the same minute (24-hour clock, so a
# window that crosses midnight works: 22:30 gives 22,23,00,01,02,03).
daily_calendar() {
  local hour="${1%%:*}" minute="${1##*:}" i list=''
  for ((i = 0; i < 6; i++)); do list+="${list:+,}$(printf '%02d' $(( (10#$hour + i) % 24 )))"; done
  printf '*-*-* %s:%s:00\n' "$list" "$minute"
}

# The other units of the same installation share the base name: <project>-watch -> <project>-stack.
unit_sibling() { printf '%s-%s\n' "${1%-watch}" "$2"; }

# The Node.js the units run: the link ~/.local/opt/node-current -> the prefix of the given node (its bin/node), made as the
# installation user and replaced in one step. Sets NODE_UNIT_PATH to the path the units should name: LINK/bin/node. A node
# that is not in a bin/ directory has no prefix to link and is named as it is.
NODE_UNIT_PATH=''
link_node() {
  local node="$1" uid="$2" user="$3" real prefix link home version
  real="$(readlink -f -- "$node")"
  if [[ "$(basename -- "$(dirname -- "$real")")" != bin ]]; then
    echo "Warning: $node is not in a bin/ directory, so the units name it directly and a Node.js upgrade needs this command again." >&2
    NODE_UNIT_PATH="$node"; return 0
  fi
  prefix="$(dirname -- "$(dirname -- "$real")")"
  link="${WAREHOUSE_NODE_LINK:-}"
  if [[ -z "$link" ]]; then
    home="$(getent passwd "$uid" | cut -d: -f6)"
    [[ -n "$home" ]] || die "Cannot find the home directory of user $user for the Node.js link; set WAREHOUSE_NODE_LINK=/absolute/path."
    link="$home/.local/opt/node-current"
  fi
  safe_path "$link" 'The Node.js link'
  [[ ! -e "$link" || -L "$link" ]] || die "$link exists and is not a link; move it away or set WAREHOUSE_NODE_LINK."
  runuser -u "$user" -- mkdir -p -- "$(dirname -- "$link")" || die "Cannot create $(dirname -- "$link") as $user."
  runuser -u "$user" -- ln -s -- "$prefix" "$link.new.$$" && runuser -u "$user" -- mv -T -f -- "$link.new.$$" "$link" \
    || { runuser -u "$user" -- rm -f -- "$link.new.$$" 2>/dev/null; die "Cannot make the Node.js link $link."; }
  version="$(runuser -u "$user" -- "$link/bin/node" --version 2>/dev/null || true)"
  node_at_least_22_18 "$version" || die "The Node.js link $link does not give Node.js 22.18 or newer (${version:-nothing})."
  echo "Node.js link: $link -> $prefix ($version)"
  NODE_UNIT_PATH="$link/bin/node"
}

cmd_install() {
  local state='' node='' daily='' uid gid user group base stack daily_name tmp home path existing version
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
  base="$(unit_base "$state")"
  existing="$UNITS/$base.service"
  daily_name="$(unit_sibling "$base" daily)"
  if [[ -f "$existing" ]]; then
    [[ "$(unit_setting "$existing" WAREHOUSE_STATE_DIR)" == "$state" ]] \
      || die "$existing already belongs to another state ($(unit_setting "$existing" WAREHOUSE_STATE_DIR)); the unit name comes from the facility's Compose project. Uninstall it first."
    # The time lives in the daily unit; an install from before that unit kept it in the checker's.
    [[ -n "$daily" ]] || daily="$(unit_setting "$UNITS/$daily_name.service" WAREHOUSE_WATCH_DAILY_AT)"
    [[ -n "$daily" ]] || daily="$(unit_setting "$existing" WAREHOUSE_WATCH_DAILY_AT)"
  fi
  [[ "$daily" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]] || daily='02:30'
  link_node "$node" "$uid" "$user"
  node="$NODE_UNIT_PATH"
  home="$(dirname "$node")"
  path="$home:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
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
Environment=PATH=$path
ExecStart=$node $ROOT/scripts/watch.mjs run
# A run takes seconds. A hung one must not hold the timer's next runs off (a oneshot that is still running is not started
# again), so it is stopped after half an hour. The backup is not part of it (the daily unit).
TimeoutStartSec=30min
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
  tmp="$(mktemp "$UNITS/.$daily_name.service.XXXXXX")"
  cat > "$tmp" <<UNIT
# Managed by scripts/watch-timer.sh: the daily backup, verification, pruning and retention for $state (scripts/watch.mjs daily).
[Unit]
Description=Warehouse daily backup and retention for $state
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
ExecStart=$node $ROOT/scripts/watch.mjs daily
# scripts/watch-daily.sh limits its steps to 90 + 60 + 15 minutes plus the prune: well inside this.
TimeoutStartSec=4h
TimeoutStopSec=5min
UNIT
  chmod 0644 "$tmp"; mv -f -- "$tmp" "$UNITS/$daily_name.service"
  tmp="$(mktemp "$UNITS/.$daily_name.timer.XXXXXX")"
  cat > "$tmp" <<UNIT
# Managed by scripts/watch-timer.sh. The chosen time and each of the 5 hours after it (the 6-hour window of the daily pass):
# a pass that failed or found the services down is tried again at the next trigger, one that is done does nothing.
[Unit]
Description=Warehouse daily backup and retention at $daily for $state

[Timer]
OnCalendar=$(daily_calendar "$daily")
AccuracySec=10s
Persistent=true
Unit=$daily_name.service

[Install]
WantedBy=timers.target
UNIT
  chmod 0644 "$tmp"; mv -f -- "$tmp" "$UNITS/$daily_name.timer"
  stack="$(unit_sibling "$base" stack)"
  tmp="$(mktemp "$UNITS/.$stack.service.XXXXXX")"
  cat > "$tmp" <<UNIT
# Managed by scripts/watch-timer.sh: starts the services of $state at boot.
# Docker does not restart a container that was stopped (only one that exited), and the daily backup stops four services
# for a while: a power cut inside that time leaves them stopped, and nothing else starts them before someone runs start.sh.
# --no-build: a boot never builds an image (a missing one is a job for setup.sh or db:restore-host).
[Unit]
Description=Warehouse services for $state at boot
Requires=docker.service
After=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
User=$user
Group=$group
WorkingDirectory=$ROOT
Environment=WAREHOUSE_STATE_DIR=$state
Environment=PATH=$path
ExecStart=/bin/bash $ROOT/scripts/compose.sh up -d --no-build
TimeoutStartSec=10min

[Install]
WantedBy=multi-user.target
UNIT
  chmod 0644 "$tmp"; mv -f -- "$tmp" "$UNITS/$stack.service"
  systemctl daemon-reload
  systemctl enable --now "$base.timer" >/dev/null
  systemctl enable --now "$daily_name.timer" >/dev/null
  # Enabled, not started: install must not change what is running (a stack stopped with stop.sh stays stopped until a boot).
  systemctl enable "$stack.service" >/dev/null
  echo "$base.timer is enabled: checks every 5 minutes as $user (it never runs a backup)."
  echo "$daily_name.timer is enabled: the daily backup, verification and retention run at $daily."
  echo "$stack.service is enabled: the services start at boot (after a power cut or a reboot)."
  echo "Time zone: $(host_zone) (the daily time is local to it; a pass may run up to 6 hours after $daily)."
  echo "Check it with: bash scripts/watch-timer.sh status   and   node scripts/watch.mjs status"
}

cmd_uninstall() {
  local state='' base stack daily unit
  while (($#)); do
    case "$1" in
      --state) (($# > 1)) || usage; state="$2"; shift 2 ;;
      *) usage ;;
    esac
  done
  [[ "$(id -u)" == 0 ]] || die 'uninstall removes systemd units: run it with sudo.'
  # The shape of the path is enough: the state directory may already be gone.
  state="$(state_shape "$state")"
  base="$(unit_base "$state")"; stack="$(unit_sibling "$base" stack)"; daily="$(unit_sibling "$base" daily)"
  systemctl disable --now "$base.timer" "$daily.timer" >/dev/null 2>&1 || true
  for unit in "$base" "$daily"; do
    if systemctl is-active --quiet "$unit.service" 2>/dev/null; then
      systemctl stop "$unit.service" || echo "Warning: $unit.service is still running and could not be stopped; a daily pass may be in progress." >&2
    fi
  done
  # The boot unit only ran `compose up`: disabling it leaves the containers as they are.
  systemctl disable "$stack.service" >/dev/null 2>&1 || true
  rm -f -- "$UNITS/$base.timer" "$UNITS/$base.service" "$UNITS/$daily.timer" "$UNITS/$daily.service" "$UNITS/$stack.service"
  systemctl daemon-reload
  systemctl reset-failed "$base.service" "$base.timer" "$daily.service" "$daily.timer" "$stack.service" >/dev/null 2>&1 || true
  echo "Removed $base.timer, $base.service, $daily.timer, $daily.service and $stack.service."
  echo "The Node.js link (~/.local/opt/node-current) is left in place."
}

# The Node.js path the checker unit runs (its ExecStart), and a note when that path is a link that points nowhere.
unit_node() { sed -n 's/^ExecStart=\([^ ]*\) .*/\1/p' "$1" 2>/dev/null | head -n 1 || true; }
node_gone_note() {
  local link="${1%/bin/node}"
  if [[ -L "$link" ]]; then printf ' - the link %s points at %s, which is not there' "$link" "$(readlink -- "$link")"; fi
}

cmd_status() {
  local state base stack daily node
  state="$(state_dir)"; base="$(unit_base "$state")"; stack="$(unit_sibling "$base" stack)"; daily="$(unit_sibling "$base" daily)"
  [[ -z "${WAREHOUSE_WATCH_UNIT_DIR:-}" ]] || echo "Test override: WAREHOUSE_WATCH_UNIT_DIR=$UNITS"
  echo "Time zone: $(host_zone)"
  if [[ -f "$UNITS/$base.timer" ]]; then
    if grep -qxF -- "Environment=WAREHOUSE_STATE_DIR=$state" "$UNITS/$base.service" 2>/dev/null; then echo "Timer: $base.timer is installed for $state."
    else echo "Timer: $base.timer is installed but its service does not name $state; run: sudo bash scripts/watch-timer.sh install --state $state"; fi
    echo "Timer state: $(systemctl is-active "$base.timer" 2>/dev/null || true)"
    node="$(unit_node "$UNITS/$base.service")"
    if [[ -n "$node" && ! -x "$node" ]]; then echo "Node.js: $node is MISSING$(node_gone_note "$node"): run sudo bash scripts/watch-timer.sh install --state $state --node /absolute/path/to/node"
    elif [[ -n "$node" ]]; then echo "Node.js: $node ($("$node" --version 2>/dev/null || echo 'does not run'))"; fi
  else
    echo "Timer: $base.timer is not installed. Run: sudo bash scripts/watch-timer.sh install --state $state"
  fi
  if [[ -f "$UNITS/$daily.timer" ]]; then
    echo "Daily timer: $daily.timer is installed (at $(unit_setting "$UNITS/$daily.service" WAREHOUSE_WATCH_DAILY_AT), state: $(systemctl is-active "$daily.timer" 2>/dev/null || true))."
  else
    echo "Daily timer: $daily.timer is not installed: no backup runs. Run: sudo bash scripts/watch-timer.sh install --state $state"
  fi
  if [[ -f "$UNITS/$stack.service" ]]; then
    echo "Boot unit: $stack.service is installed ($(systemctl is-enabled "$stack.service" 2>/dev/null || echo 'not enabled')); it starts the services after a boot."
  else
    echo "Boot unit: $stack.service is not installed: after a power cut the services stay stopped until start.sh is run. Run: sudo bash scripts/watch-timer.sh install --state $state"
  fi
}

cmd_hint() {
  local state base svc stack daily node missing=()
  state="$(state_shape)"; base="$(unit_base "$state")"; svc="$UNITS/$base.service"; stack="$(unit_sibling "$base" stack)"; daily="$(unit_sibling "$base" daily)"
  if [[ -f "$UNITS/$base.timer" ]] && grep -qxF -- "Environment=WAREHOUSE_STATE_DIR=$state" "$svc" 2>/dev/null; then
    # Installed for this state: say so only when something is wrong: the Node.js is gone, it runs another checkout (a moved
    # or replaced checkout), or a unit that a later release added is missing (an install from before it).
    node="$(unit_node "$svc")"
    if [[ -n "$node" && ! -x "$node" ]]; then
      echo "The monitoring checker timer is installed for $state, but the Node.js it runs is gone ($node$(node_gone_note "$node")). No check, Slack alert, daily backup or retention runs until this is fixed. Point it at the Node.js you have now (needs sudo):"
      echo "  sudo bash $ROOT/scripts/watch-timer.sh install --state $state --node /absolute/path/to/node"
      return 0
    fi
    if ! grep -qxF -- "WorkingDirectory=$ROOT" "$svc" 2>/dev/null || [[ "$(sed -n 's/^ExecStart=[^ ]* //p' "$svc" | head -n 1)" != "$ROOT/scripts/watch.mjs run" ]]; then
      echo "The monitoring checker timer is installed for $state but runs another checkout of this software. Refresh it (needs sudo):"
      echo "  sudo bash $ROOT/scripts/watch-timer.sh install --state $state"
      return 0
    fi
    [[ -f "$UNITS/$daily.timer" ]] && grep -qxF -- "Environment=WAREHOUSE_STATE_DIR=$state" "$UNITS/$daily.service" 2>/dev/null \
      || missing+=('the daily backup timer (the checker no longer makes the backup, so none is made without it)')
    grep -qxF -- "Environment=WAREHOUSE_STATE_DIR=$state" "$UNITS/$stack.service" 2>/dev/null \
      || missing+=('the unit that starts the services at boot (after a power cut they stay stopped until start.sh is run)')
    if ((${#missing[@]})); then
      echo "The monitoring checker timer is installed for $state, but these are missing: $(printf '%s; ' "${missing[@]}" | sed 's/; $//'). Refresh it (needs sudo):"
      echo "  sudo bash $ROOT/scripts/watch-timer.sh install --state $state"
    fi
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
