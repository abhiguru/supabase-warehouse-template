#!/usr/bin/env bash
# Sourced by scripts/restore.sh and scripts/restore-host.sh. Appends one line per finished phase to <state>/restores.log (mode 0600):
#   <utc time> <script> phase=<verify|database|storage|start|total> seconds=<n>
# so an operator can tell how long a restore of this installation takes (docs/OPERATOR_INSTALL.md, "Recovery point and recovery time").
# Information only: a failure to write the line never stops a restore.

# restore_timing_append STATE SCRIPT PHASE SECONDS
restore_timing_append() {
  local state="$1" script="$2" phase="$3" seconds="$4" file
  [[ -d "$state" ]] || return 0
  file="$state/restores.log"
  [[ ! -L "$file" ]] || return 0
  { printf '%s %s phase=%s seconds=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$script" "$phase" "$seconds" >> "$file" && chmod 600 -- "$file"; } 2>/dev/null || true
}

# restore_timing_start STATE SCRIPT: remembers the state and the start; restore_timing_phase NAME writes the seconds since the previous
# mark (or the start); restore_timing_total writes the seconds since the start.
restore_timing_start() { RT_STATE="$1"; RT_SCRIPT="$2"; RT_START=$SECONDS; RT_MARK=$SECONDS; }
restore_timing_phase() { restore_timing_append "$RT_STATE" "$RT_SCRIPT" "$1" "$((SECONDS - RT_MARK))"; RT_MARK=$SECONDS; }
restore_timing_total() { restore_timing_append "$RT_STATE" "$RT_SCRIPT" total "$((SECONDS - RT_START))"; }
