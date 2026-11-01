#!/usr/bin/env bash
# The daily pass of scripts/watch.mjs, under ONE operator lock from start to end: backup, verify-restore of that
# backup, pruning of the older backups, then retention. Pruning and retention run whatever the backup and the verify said
# (a backup refused for lack of space, or one that fails its verify, is exactly when old backups must still age out); only a
# database that is not running or not healthy ends the pass before them. A backup is recorded as verified (and so protected
# from pruning, and preferred as the next night's link base) only when its verify passed. Run by watch.mjs; not meant to be
# run by hand.
#
#   WAREHOUSE_STATE_DIR=STATE bash scripts/watch-daily.sh RESULT_FILE
#
# RESULT_FILE (absolute) is rewritten as key=value lines that watch.mjs reads:
#   lock=held|acquired
#   backup=ok|failed|skipped    backup_message=...   backup_dir=...   backup_warning=...
#   verify=ok|failed|skipped    verify_message=...
#   prune=ok|failed|skipped     prune_message=...    pruned=N    verified_kept=NAME (newest verified backup, kept whatever its age)
#   retention=ok|failed|skipped retention_message=...
#   done=1                      (last line; missing means the pass was cut short)
# backup_warning is set when the backup succeeded but had something to say: it found a damaged copy of stored files in the
# earlier backup it links from and re-copied them (the sentence scripts/backup.sh prints as "WARNING: N files re-copied: backup
# NAME has a damaged copy"), and/or df gave no free space for the free-space check and stat -f stood in ("WARNING: df gave no
# free space for DIR, so stat -f was used ..."); the pass stays ok, the sentences (joined by "; ") go into the daily state and the
# status line.
# "skipped" for the backup means the database was not running or not healthy yet (a boot, a deliberate stop): not a
# failure. Each step has its own time limit, below the systemd unit's, enforced with `timeout -k`.
# Exit codes: 0 finished (see the file), 75 another operator command holds the lock, 2 bad usage.
set -uo pipefail
umask 077
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RESULT="${1:-}"
[[ "$RESULT" == /* && $# -eq 1 ]] || { echo 'Usage: WAREHOUSE_STATE_DIR=STATE bash scripts/watch-daily.sh ABSOLUTE_RESULT_FILE' >&2; exit 2; }
# shellcheck source=scripts/operator-lock.sh
. "$ROOT/scripts/operator-lock.sh"
state="$(operator_state)" || exit 2
: > "$RESULT" || exit 2

BACKUP_SECS="${WAREHOUSE_WATCH_BACKUP_SECS:-5400}"        # 90 min
VERIFY_SECS="${WAREHOUSE_WATCH_VERIFY_SECS:-3600}"        # 60 min
RETENTION_SECS="${WAREHOUSE_WATCH_RETENTION_SECS:-900}"   # 15 min
PRUNE_SECS=300
KILL_AFTER="${WAREHOUSE_WATCH_KILL_AFTER:-2m}"
NODE="${WAREHOUSE_WATCH_NODE:-node}"

put() { printf '%s=%s\n' "$1" "$(printf '%s' "$2" | tr '\r\n' '  ' | cut -c1-400)" >> "$RESULT"; }
last_line() { grep -v '^[[:space:]]*$' "$1" 2>/dev/null | tail -n 1; }
OUT="$(mktemp)"; ERR="$(mktemp)"
trap 'rm -f "$OUT" "$ERR"' EXIT
# Runs one step with its time limit; stdout in $OUT, stderr in $ERR (and passed on), status in $RC.
step() {
  local secs="$1"; shift
  timeout -k "$KILL_AFTER" "$secs" "$@" > "$OUT" 2> "$ERR"
  RC=$?
  cat "$ERR" >&2
}
why() {
  if ((RC == 124 || RC == 137)); then echo "timed out after the step's limit"; else last_line "$ERR"; fi
}

if ! operator_lock "$state"; then put lock held; put done 1; exit 75; fi
put lock acquired
unset WAREHOUSE_BACKUP_DIR

backup_ok=false
step "$BACKUP_SECS" bash "$ROOT/scripts/backup.sh"
if ((RC == 0)); then
  dir="$(sed -n 's/^Backup created at \(\/.*\)$/\1/p' "$OUT" | tail -n 1)"
  name="${dir##*/}"
  if [[ "$dir" == "$state/backups/"* && "$name" =~ ^warehouse-[0-9]{8}T[0-9]{6}Z$ && "$dir" == "$state/backups/$name" ]]; then
    put backup ok; put backup_dir "$dir"
    backup_ok=true
    warning="$(sed -n 's/^WARNING: \([0-9][0-9]* files\{0,1\} re-copied: backup warehouse-[0-9]\{8\}T[0-9]\{6\}Z has a damaged copy\)\..*$/\1/p' "$ERR" | tail -n 1)"
    space_warning="$(sed -n 's/^WARNING: \(df gave no free space for \/[^;]*, so stat -f was used for the free-space check\); .*$/\1/p' "$ERR" | tail -n 1)"
    [[ -z "$space_warning" ]] || warning="${warning:+$warning; }$space_warning"
    [[ -z "$warning" ]] || put backup_warning "$warning"
  else
    put backup failed; put backup_message 'backup finished but its location could not be read'
  fi
elif grep -qE 'Database service is not (healthy|running)' "$ERR"; then
  put backup skipped; put backup_message "$(why)"
  put verify skipped; put prune skipped; put retention skipped
  put done 1
  exit 0
else
  put backup failed; put backup_message "$(why)"
fi

verified=false
if [[ "$backup_ok" == true ]]; then
  step "$VERIFY_SECS" bash "$ROOT/scripts/verify-restore.sh" "$dir"
  if ((RC == 0)); then put verify ok; verified=true; else put verify failed; put verify_message "$(why)"; fi
else
  put verify skipped; put verify_message 'no backup was made'
fi

# Pruning and retention do not wait for the verify. The backup just made (when there is one) is never pruned; it is recorded as
# verified only when its verify passed. The newest backup already on record as verified is kept in every case.
prune_args=(prune-backups)
if [[ "$backup_ok" == true ]]; then prune_args+=("$dir"); fi
if [[ "$verified" == true ]]; then prune_args+=(--verified "$dir"); fi
step "$PRUNE_SECS" "$NODE" "$ROOT/scripts/watch.mjs" "${prune_args[@]}"
if ((RC == 0)); then
  put prune ok
  put pruned "$(sed -n 's/^removed=//p' "$OUT" | tail -n 1)"
  put prune_message "$(sed -n 's/^note=//p' "$OUT" | tail -n 1)"
  put verified_kept "$(sed -n 's/^verified_kept=//p' "$OUT" | tail -n 1)"
else
  put prune failed; put prune_message "$(why)"
fi
step "$RETENTION_SECS" bash "$ROOT/scripts/retention.sh" apply
if ((RC == 0)); then put retention ok; else put retention failed; put retention_message "$(why)"; fi
put done 1
exit 0
