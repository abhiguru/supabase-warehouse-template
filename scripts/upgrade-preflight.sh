#!/usr/bin/env bash
# The preflight of THIS release. upgrade.sh is the script of the release an installation runs now, so it cannot know what the
# release it moves to needs. It reads this file out of the target's commit (`git archive`, as scripts/pg-major.sh reads db-image.sh),
# together with the files named on the `# needs:` line below (a directory counts), into a temporary directory, and runs it from there
# before it changes anything: with --dry-run too, and before the backup. Every release carries this file and scripts/upgrade-floor.txt
# (scripts/check-release-contents.sh), so a new minimum or a new floor takes effect on the move to that release, not one release later
# (for an installation whose upgrade.sh already reads preflights: this release's and later ones').
#
# needs: scripts CHANGELOG.md
#
# From upgrade.sh, in the environment: STATE (the installation's state directory), FROM_SHA, FROM_LABEL, FROM_TAG (the newest release
# tag at or below the checkout, empty when there is none), TO_SHA, TO_LABEL (a release tag, or "<commit> (--ref <name>)"), DRY (yes for
# --dry-run), ASSUME_YES (yes when upgrade.sh was given --yes; an upgrade.sh from before that option leaves it unset). It runs only from
# a temporary copy; the facility's own checkout is never changed by it. Its standard input is upgrade.sh's.
#   1. prints what CHANGELOG.md asks of the operator between the two releases, so that a "before" action is read before anything changes;
#      when that text lists operator actions, the run is real (not --dry-run), no --yes was given and standard input is a terminal,
#      it then waits for Enter ("Press Enter to continue, Ctrl-C to stop"): the one moment an action that says "before" can still be done
#   2. the host minimums of this release: the Node.js floor, then `node scripts/doctor.mjs --host-preflight` of this release (Docker
#      Engine and Compose with `up --wait-timeout`, rsync with extended attributes, GNU tar --xattrs, the free-space rule of setup)
#   3. the floor in scripts/upgrade-floor.txt: an installation older than from_floor goes to the stepping stone first
#   4. room for the way back: the free space of the state's filesystem against the stored files of the newest verified backup, plus its
#      database dump and 1 GiB (scripts/restore.sh's rule, and the replay of the dump), because the printed way back is an in-place restore
# Exit 0: go on. Any other exit refuses the upgrade; the message is on standard error and nothing has been changed.
set -euo pipefail

say() { printf '%s\n' "$*"; }
refuse() { printf 'Refusing: %s Nothing was changed.\n' "$*" >&2; exit 1; }

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TREE="$(dirname "$HERE")"
# shellcheck source=scripts/upgrade-lib.sh
. "$HERE/upgrade-lib.sh"

SEMVER='^v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?$'
# The same floor as supportedNode() in scripts/doctor-common.mjs (tests/upgrade-preflight.test.mjs compares the two).
NODE_FLOOR_MAJOR=22
NODE_FLOOR_MINOR=18
GIB=1073741824

: "${STATE:?upgrade.sh runs this script and sets STATE}"
: "${TO_SHA:?upgrade.sh runs this script and sets TO_SHA}"
: "${TO_LABEL:?upgrade.sh runs this script and sets TO_LABEL}"
FROM_LABEL="${FROM_LABEL:-${FROM_SHA:0:12}}"
FROM_TAG="${FROM_TAG:-}"
DRY="${DRY:-no}"
ASSUME_YES="${ASSUME_YES:-no}"
[[ "$STATE" == /* && -d "$STATE/config" ]] || refuse "STATE is not an installed operator state ('$STATE')."

# --- 1. what the release asks of the operator -------------------------------------------------------------------------------
CL_TO=Unreleased
[[ "$TO_LABEL" =~ $SEMVER ]] && CL_TO="$TO_LABEL"
if [[ -n "$FROM_TAG" ]]; then scope="the releases after $FROM_TAG, up to $TO_LABEL"
else scope="only the section of $TO_LABEL: this checkout is on no release tag, so there is no older release to count from"; fi
actions="$(changelog_between "$TREE/CHANGELOG.md" "$FROM_TAG" "$CL_TO")" || printf 'Warning: could not print the operator actions of CHANGELOG.md; read the file before you rely on this upgrade.\n' >&2
# A pause only where it can matter: a real run, at a terminal, with operator actions in the text. `tty -s` is the check (CI, a pipe or
# `</dev/null` never pause, and --yes skips it).
pause=no
if [[ "$DRY" != yes && "$ASSUME_YES" != yes ]] && grep -q '^### Operator actions' <<< "$actions" && tty -s 2>/dev/null; then pause=yes; fi
say
if [[ "$DRY" == yes ]]; then
  say "What $TO_LABEL asks of the operator (CHANGELOG.md, $scope). Do every action that says \"before\" before you run the upgrade for real; this dry run changes nothing:"
elif [[ "$pause" == yes ]]; then
  say "What $TO_LABEL asks of the operator (CHANGELOG.md, $scope). Do every action that says \"before\" now; nothing has been changed yet:"
else
  say "What $TO_LABEL asks of the operator (CHANGELOG.md, $scope). This run goes on after the list without stopping, so an action that says \"before\" should be done already (--dry-run prints this list without changing anything):"
fi
say
printf '%s\n' "$actions"
if [[ "$pause" == yes ]]; then
  printf '\nPress Enter to continue, Ctrl-C to stop (--yes skips this pause): '
  IFS= read -r _ || { echo >&2; refuse "no answer was read, so the upgrade did not go on. Do the actions listed above, then run this command again."; }
  say
fi

# --- 2. the host minimums of this release ----------------------------------------------------------------------------------
node_version="$(node -p 'process.versions.node' 2>/dev/null || true)"
[[ "$node_version" =~ ^([0-9]+)\.([0-9]+)\. ]] || refuse "could not read the Node.js version (node -p process.versions.node printed '$node_version')."
if ((BASH_REMATCH[1] < NODE_FLOOR_MAJOR || (BASH_REMATCH[1] == NODE_FLOOR_MAJOR && BASH_REMATCH[2] < NODE_FLOOR_MINOR))); then
  refuse "$TO_LABEL needs Node.js $NODE_FLOOR_MAJOR.$NODE_FLOOR_MINOR or newer on the host, and this host has $node_version. Install a newer Node.js (docs/OPERATOR_INSTALL.md, \"Host prerequisites\"), then run this command again."
fi
if ! WAREHOUSE_STATE_DIR="$STATE" node "$HERE/doctor.mjs" --host-preflight; then
  refuse "this host does not meet what $TO_LABEL needs (the doctor's message is above). Fix that (docs/OPERATOR_INSTALL.md, \"Host prerequisites\"), then run this command again."
fi

# --- 3. the floor ----------------------------------------------------------------------------------------------------------
# scripts/upgrade-floor.txt: `from_floor=` the oldest release this one can be upgraded from, `stepping_stone=` the release to upgrade
# to first when the installation is older. Both empty: no floor (the state of every release line until a compatibility shim is dropped).
floor_file="$HERE/upgrade-floor.txt"
[[ -f "$floor_file" ]] || refuse "$TO_LABEL does not ship scripts/upgrade-floor.txt, so it cannot say from which releases it accepts an upgrade."
floor_get() { grep -E "^$1=" "$floor_file" | head -n 1 | sed "s/^$1=//; s/[[:space:]]*\$//" || true; }
from_floor="$(floor_get from_floor)"
stepping_stone="$(floor_get stepping_stone)"
for value in "$from_floor" "$stepping_stone"; do
  [[ -z "$value" || "$value" =~ $SEMVER ]] || refuse "scripts/upgrade-floor.txt of $TO_LABEL holds '$value', which is not a release tag (vX.Y.Z)."
done
if [[ -n "$from_floor" ]]; then
  stone="${stepping_stone:-$from_floor}"
  if [[ -z "$FROM_TAG" ]]; then
    refuse "$TO_LABEL accepts an upgrade only from $from_floor or newer, and this checkout ($FROM_LABEL) is not on a release tag. Upgrade to $stone first (bash upgrade.sh $stone), then run this command again."
  fi
  if semver_lt "$FROM_TAG" "$from_floor"; then
    refuse "$TO_LABEL accepts an upgrade only from $from_floor or newer, and this checkout is at $FROM_TAG. Upgrade to $stone first (bash upgrade.sh $stone), then run this command again."
  fi
fi

# --- 4. room for the way back ----------------------------------------------------------------------------------------------
# The way back from an upgrade is scripts/restore.sh of the backup this upgrade takes: it keeps the stored files it replaces and
# copies them in again, so the free space has to hold them once more, with a gigabyte to spare (restore.sh refuses below that, and
# only after the upgrade has changed the facility), and the database is then replayed from the dump. The sizes are what the newest
# verified backup recorded: storage_bytes, and the size of database.dump as a stand-in for the replayed database (compressed, so a low
# one). The upgrade's own backup is a hard-linked copy of the same photos and about as large. This is a minimum: the photos added since
# that backup, the new dump and any image the release builds come on top.
backup_storage_bytes() {
  local dir="$1" bytes
  [[ -d "$dir" && ! -L "$dir" && -f "$dir/metadata.txt" ]] || return 1
  bytes="$(sed -n 's/^storage_bytes=//p' "$dir/metadata.txt" | head -n 1)"
  if [[ ! "$bytes" =~ ^[0-9]{1,15}$ && -f "$dir/storage.tar.gz" && ! -L "$dir/storage.tar.gz" ]]; then bytes="$(stat -c %s -- "$dir/storage.tar.gz")"; fi
  [[ "$bytes" =~ ^[0-9]{1,15}$ ]] || return 1
  printf '%s\n' "$bytes"
}
backup_dump_bytes() {
  local file="$1/database.dump"
  if [[ -f "$file" && ! -L "$file" ]]; then stat -c %s -- "$file"; else echo 0; fi
}
need_bytes='' dump_bytes=0 need_from=''
verified_list="$STATE/config/backups-verified.list"
if [[ -f "$verified_list" && ! -L "$verified_list" ]]; then
  while read -r name _; do
    [[ "$name" =~ ^warehouse-[0-9]{8}T[0-9]{6}Z$ ]] || continue
    if bytes="$(backup_storage_bytes "$STATE/backups/$name")"; then need_bytes="$bytes"; dump_bytes="$(backup_dump_bytes "$STATE/backups/$name")"; need_from="$name"; fi
  done < <(awk 'NF { print $1 }' "$verified_list" | LC_ALL=C sort -u)
fi
if [[ -z "$need_bytes" ]]; then
  say "Room for the way back: not checked (no verified backup is on record yet, so there is no size to compare; the backup itself checks its own space)."
else
  need_total=$((need_bytes + dump_bytes + GIB))
  covers="the stored files of $need_from, its database dump and 1 GiB; a minimum, since the photos added since, the new backup's dump and new images come on top"
  free_bytes="$(df -B1 --output=avail -- "$STATE/data" 2>/dev/null | tail -n 1 | tr -d ' ' || true)"
  if [[ ! "$free_bytes" =~ ^[0-9]+$ ]]; then
    say "Room for the way back: not checked (the free space of $STATE/data could not be read)."
  elif ((free_bytes < need_total)); then
    refuse "the way back from this upgrade is an in-place restore, which copies the stored files in again and replays the database while the replaced ones stay: it needs at least $((need_total / 1048576)) MiB free in $STATE/data ($((need_bytes / 1048576)) MiB of stored files of $need_from, $((dump_bytes / 1048576)) MiB of its database dump, and 1 GiB to spare), and only $((free_bytes / 1048576)) MiB are free. Free space first (the data/*.pre-restore-* directories of restores you have accepted, backups you no longer need) or add disk (docs/OPERATOR_INSTALL.md, \"Disk space\"), then run this command again."
  else
    say "Room for the way back: $((free_bytes / 1048576)) MiB free, $((need_total / 1048576)) MiB needed ($covers)."
  fi
fi

say
say "Preflight of $TO_LABEL passed$([[ "$DRY" == yes ]] && echo ' (dry run)')."
