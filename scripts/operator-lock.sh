#!/usr/bin/env bash
# Shared operator lock. Source this file from an operator command; do not run it.
#   state="$(operator_state)"   # validated absolute WAREHOUSE_STATE_DIR
#   operator_lock "$state"      # exclusive per-state lock for the calling shell
#   operator_lock_or_inherited "$state"   # the same, for a step that locked commands also run
# The lock lives on descriptor 9 for the lifetime of the calling process so
# setup, start, stop, backup, restore, rotation and checks never interleave.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  echo 'scripts/operator-lock.sh is a sourced helper, not a command.' >&2
  exit 1
fi

operator_state() {
  local state="${WAREHOUSE_STATE_DIR:-}"
  if [[ -z "$state" || "$state" != /* ]]; then
    echo 'Set WAREHOUSE_STATE_DIR to the absolute installed operator state path.' >&2
    return 1
  fi
  if [[ "$(realpath -m "$state")" != "$(realpath -ms "$state")" ]]; then
    echo 'Operator state path must not use a symlink.' >&2
    return 1
  fi
  state="$(realpath -ms "$state")"
  if [[ ! -d "$state" || -L "$state" ]]; then
    echo "Operator state directory does not exist: $state" >&2
    return 1
  fi
  if [[ ! -d "$state/config" || -L "$state/config" ]]; then
    echo "Missing operator configuration directory: $state/config" >&2
    return 1
  fi
  printf '%s\n' "$state"
}

operator_lock() {
  local state="${1:-}"
  if [[ -z "$state" ]]; then state="$(operator_state)" || return 1; fi
  exec 9>"$state/config/operator.lock"
  if ! flock -n 9; then
    echo 'Another operator command (setup, start, stop, backup, restore, rotation or check) is running for this state.' >&2
    return 1
  fi
}

# For a command that other operator commands run as one of their steps
# (scripts/migrate.sh from setup.sh and restore.sh). The caller's lock arrives as
# the inherited descriptor 9; run alone, the command takes the lock itself.
operator_lock_or_inherited() {
  local state="${1:-}"
  if [[ -z "$state" ]]; then state="$(operator_state)" || return 1; fi
  if [[ -e "/proc/$$/fd/9" && "/proc/$$/fd/9" -ef "$state/config/operator.lock" ]]; then return 0; fi
  operator_lock "$state"
}
