#!/usr/bin/env bash
# Normalizes the permissions of this checkout's tracked files after an update.
#
# `git pull` and `git checkout` write files with the caller's umask. Under
# Ubuntu's default umask 0002 they become group-writable, and the root-run
# helpers (scripts/backup-usb.sh setup, scripts/backup-disk.sh) then refuse to
# run. Under umask 077 they become owner-only, and the containers can no longer
# read the bootstrap SQL. This script removes group/world write and restores
# world read (and execute where the owner has it) on tracked files and their
# directories, so every update ends in the same state as a `umask 022` clone.
#
# Only paths git tracks are touched: ignored runtime files that may live in a
# development checkout (docker/.env, docker/volumes/...) keep their private
# modes. Symlinks and paths owned by another user are left alone and reported.
# setup.sh runs this on every install and rerun; it is safe to run at any time.
set -euo pipefail
umask 022
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
QUIET=no
[[ "${1:-}" == --quiet ]] && QUIET=yes

if ! command -v git >/dev/null 2>&1 || ! git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1; then
  [[ "$QUIET" == yes ]] || echo "checkout-permissions: $ROOT is not a git checkout; nothing changed." >&2
  exit 0
fi

me="$(id -u)"
changed=0
foreign=()
declare -A dirs=(["$ROOT"]=1)

fix() { # $1 path, $2 chmod spec; chmod only when the mode is not already right
  local m ok=no
  m=$((8#$(stat -c %a -- "$1")))
  if (( (m & 8#022) == 0 && (m & 8#044) == 8#044 )); then
    if [[ -d "$1" ]]; then
      (( (m & 8#011) == 8#011 )) && ok=yes
    elif (( (m & 8#100) == 0 || (m & 8#011) == 8#011 )); then
      ok=yes
    fi
  fi
  [[ "$ok" == yes ]] && return 0
  chmod "$2" -- "$1"
  changed=$((changed + 1))
}

# -s prints "mode object stage<TAB>path"; mode 120000 is a symlink, 160000 a submodule.
while IFS= read -r -d '' entry; do
  mode="${entry%% *}"
  path="$ROOT/${entry#*$'\t'}"
  [[ "$mode" == 120000 || "$mode" == 160000 ]] && continue
  [[ -e "$path" && ! -L "$path" ]] || continue
  if [[ "$(stat -c %u -- "$path")" != "$me" ]]; then foreign+=("$path"); continue; fi
  fix "$path" go-w,a+rX
  dir="$(dirname -- "$path")"
  while [[ "$dir" == "$ROOT"/* && -z "${dirs[$dir]:-}" ]]; do
    dirs["$dir"]=1
    dir="$(dirname -- "$dir")"
  done
done < <(git -C "$ROOT" ls-files -s -z)

for dir in "${!dirs[@]}"; do
  [[ -d "$dir" && ! -L "$dir" ]] || continue
  if [[ "$(stat -c %u -- "$dir")" != "$me" ]]; then foreign+=("$dir"); continue; fi
  fix "$dir" go-w,a+rx
done

if ((${#foreign[@]})); then
  echo "checkout-permissions: ${#foreign[@]} tracked path(s) are owned by another user and were not changed, for example ${foreign[0]}." >&2
  echo 'The checkout must belong to the installation user; fix the ownership and run this script again.' >&2
  exit 1
fi
if [[ "$QUIET" == no || "$changed" -gt 0 ]]; then
  echo "checkout-permissions: normalized $changed path(s) in $ROOT."
fi
