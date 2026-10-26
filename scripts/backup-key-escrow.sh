#!/usr/bin/env bash
# Confirm that a copy of the backup key exists away from this machine and from the backup drive.
#   bash scripts/backup-key-escrow.sh show             print the key once, then ask you to type or paste the WHOLE key back from your
#                                                      copy; when every character matches, record the confirmation (needs a terminal)
#   bash scripts/backup-key-escrow.sh check [FILE]     does the record (default: config/backup-key.escrow) match the key in use?
#   bash scripts/backup-key-escrow.sh confirm --key-file FILE
#                                                      the same confirmation without a terminal (an unattended install, CI): FILE holds
#                                                      your copy of the key, and every character of it is compared
# Why: USB archives are encrypted with the backup key, so without a copy of it they cannot be opened after the host is lost;
# the key lives only in <state>/config/backup.key, on the disk that dies with the host. A copy with one wrong character is as
# useless as no copy, so the whole key is given back, not a part of it. A USB drive is not enrolled, and an
# encrypted archive is not written, until this record matches the key now in use. The record,
# <state>/config/backup-key.escrow (mode 0600), holds a fingerprint of the key (not the key), the time and the user.
# Uses WAREHOUSE_STATE_DIR (or WAREHOUSE_BACKUP_KEY_FILE for `check`), as the other operator commands do.
set -euo pipefail
umask 077
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
die() { echo "$*" >&2; exit 1; }
usage() { die 'Usage: bash scripts/backup-key-escrow.sh show | check [FILE] | confirm --key-file FILE'; }

# shellcheck source=scripts/operator-lock.sh
source "$ROOT/scripts/operator-lock.sh"
# shellcheck source=scripts/backup-key.sh
source "$ROOT/scripts/backup-key.sh"

write_record() {
  local state="$1" tmp
  tmp="$(mktemp "$state/config/.backup-key.escrow.XXXXXX")"
  printf '%s\nkey_fingerprint=%s\nconfirmed_utc=%s\nconfirmed_by=%s\n' "$BACKUP_ESCROW_HEADER" "$(backup_key_fingerprint "$BACKUP_KEY")" \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(id -un)" > "$tmp"
  chmod 600 "$tmp"
  mv -f -- "$tmp" "$state/config/backup-key.escrow"
}

# Sets `state` and BACKUP_KEY. Only `show`, which prints the key, creates one that is missing (create); `confirm` never mints a
# key that the operator has not seen.
load_state_key() {
  state="$(operator_state)" || exit 1
  [[ -d "$state/config" ]] || die "$state is not an installed operator state."
  if [[ "${1:-}" == create ]]; then
    backup_key_ensure "$state" || exit 1
  elif [[ ! -f "$state/config/backup.key" ]]; then
    die "This installation has no backup key yet ($state/config/backup.key). Run, in a terminal: bash scripts/backup-key-escrow.sh show (it creates the key and prints it), keep the copy, then confirm."
  fi
  backup_key_load "$state/config/backup.key" || exit 1
}

# What to do about the key left on the screen.
screen_hint() {
  echo 'The key is still on this terminal (screen and scrollback). Clear it: run clear, and close the window; in tmux or screen clear the history too, and do not keep a log of this session.'
}

cmd_show() {
  local state attempt answer got
  (($# == 0)) || usage
  [[ -t 0 && -t 1 ]] || die 'show prints the backup key and asks you to type it back, so it needs a terminal (not a pipe, a file or a service). Run it in a terminal on the host. An unattended install can use: bash scripts/backup-key-escrow.sh confirm --key-file FILE (FILE holds your copy of the key)'
  load_state_key create
  if backup_escrow_ok "$state"; then
    echo "A copy of this key was already confirmed ($(sed -n 's/^confirmed_utc=//p' "$state/config/backup-key.escrow" | head -n 1)). You can confirm again."
    echo
  fi
  cat <<MSG
This is the backup key of this installation. Every USB archive is encrypted with it. Without a copy of it an archive cannot
be opened, and if this machine is lost (fire, theft, a dead disk) every encrypted archive on the drive is lost with it.

    $BACKUP_KEY

Copy it now, exactly (64 characters, 0-9 and a-f), and keep the copy where this machine and the backup drive cannot
be lost with it: a password manager, or paper in a safe place away from the facility. Not on this machine, not on the
backup drive, not in a file next to the archives. (This machine's own copy is the file $state/config/backup.key; it
is lost with the machine.)

A copy with one wrong character cannot open anything, so you now give the whole key back, from your copy and not from the screen:
type it or paste it (capital letters and spaces do not matter; nothing is shown as you type).

MSG
  for attempt in 1 2 3; do
    read -r -s -p 'Your copy of the whole key: ' answer || { echo; die 'No answer; nothing was recorded.'; }
    echo
    answer="${answer,,}"; answer="${answer//[[:space:]]/}"
    if [[ "$answer" == "$BACKUP_KEY" ]]; then
      write_record "$state"
      echo "Confirmed: every character matches. Recorded in $state/config/backup-key.escrow."
      echo 'A USB drive can now be enrolled and encrypted archives can be written. If the backup key is ever replaced, confirm the new key the same way.'
      screen_hint
      return 0
    fi
    got="${#answer} characters"
    if ((${#answer} == 64)); then got='64 characters, but at least one is not the same as in the key'; fi
    echo "That does not match the key (attempt $attempt of 3): you gave $got; the key has 64. Check your copy against the key above."
  done
  screen_hint
  die 'Nothing was recorded. Run this again when you have a copy of the key in front of you.'
}

cmd_confirm() {
  local state keyfile='' copy
  while (($#)); do
    case "$1" in
      --key-file) (($# > 1)) || usage; keyfile="$2"; shift 2 ;;
      *) usage ;;
    esac
  done
  [[ -n "$keyfile" ]] || die 'confirm needs --key-file FILE: a file that holds your copy of the backup key (64 hexadecimal characters), brought from where you keep it.'
  [[ -f "$keyfile" && -r "$keyfile" ]] || die "$keyfile is not a readable file."
  load_state_key
  if [[ "$keyfile" -ef "$state/config/backup.key" ]]; then
    die "$keyfile is this installation's own key file, which is lost with this machine: it proves nothing. Give a file made from your copy kept elsewhere."
  fi
  copy="$(head -c 4096 -- "$keyfile" | tr -d '[:space:]' | tr 'A-F' 'a-f')"
  [[ "$copy" =~ ^[0-9a-f]{64}$ ]] || die "$keyfile does not hold a backup key (64 hexadecimal characters); nothing was recorded."
  [[ "$copy" == "$BACKUP_KEY" ]] || die "The key in $keyfile is not this installation's backup key (at least one character differs); nothing was recorded."
  write_record "$state"
  echo "Confirmed: every character matches. Recorded in $state/config/backup-key.escrow."
}

cmd_check() {
  local file="${1:-}" keyfile state
  (($# <= 1)) || usage
  if keyfile="$(backup_key_path)"; then :; else die 'Set WAREHOUSE_STATE_DIR (or WAREHOUSE_BACKUP_KEY_FILE) so the key can be found.'; fi
  backup_key_load "$keyfile" || exit 1
  if [[ -z "$file" ]]; then
    state="$(operator_state)" || exit 1
    file="$state/config/backup-key.escrow"
  fi
  if backup_escrow_check "$file" "$BACKUP_KEY"; then
    echo "Key copy confirmed: $(sed -n 's/^confirmed_utc=//p' "$file" | head -n 1) by $(sed -n 's/^confirmed_by=//p' "$file" | head -n 1)."
  else
    echo "Not confirmed: $BACKUP_ESCROW_PROBLEM. Run: bash scripts/backup-key-escrow.sh show" >&2
    exit 1
  fi
}

sub="${1:-}"
(($#)) && shift
case "$sub" in
  show) cmd_show "$@" ;;
  check) cmd_check "$@" ;;
  confirm) cmd_confirm "$@" ;;
  *) usage ;;
esac
