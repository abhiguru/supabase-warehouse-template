#!/usr/bin/env bash
# Backup results for Prometheus (docs/MONITORING.md, "Backup alerts"). Source this file; do not run it.
#   backup_metrics_exit STATE KIND STATUS   KIND is disk (scripts/backup.sh) or usb (scripts/backup-usb.sh);
#                                           STATUS 0 = the backup succeeded, anything else = it failed
# It rewrites <state>/metrics/warehouse_backup.prom, which node exporter reads through its textfile
# collector (docker/docker-compose.override.yml mounts the directory read-only):
#   warehouse_backup_last_success_timestamp_seconds{kind="disk"}   Unix time of the last success
#   warehouse_backup_last_attempt_success{kind="disk"}             1 after a success, 0 after a failure
# The file is replaced through a temporary in the same directory, so node exporter never reads a
# half-written file, and the other kind's lines are carried over unchanged. A failure keeps the last
# success time. Nothing here can fail a backup: a problem is a warning on stderr. The metrics hold no
# paths, names or secrets, only the kind, a time and 0 or 1.
backup_metrics_record() {
  local state="$1" kind="$2" status="$3" dir file now
  dir="$state/metrics"
  file="$dir/warehouse_backup.prom"
  [[ "$kind" == disk || "$kind" == usb ]] || return 1
  if [[ ! -e "$dir" && ! -L "$dir" ]]; then mkdir -m 755 -- "$dir" || return 1; fi
  # Not a link, and ours: a directory that Docker created for a missing mount belongs to root.
  [[ -d "$dir" && ! -L "$dir" && -O "$dir" ]] || return 1
  now="$(date +%s)"
  (
    exec 8>"$dir/.warehouse_backup.lock" || exit 1
    flock -w 10 8 || exit 1
    local tmp k ts attempt
    value() { sed -n "s/^$1{kind=\"$2\"} \\([0-9][0-9]*\\)\$/\\1/p" "$file" 2>/dev/null | head -n 1 || true; }
    declare -A success_ts=() attempt_ok=()
    for k in disk usb; do
      success_ts[$k]="$(value warehouse_backup_last_success_timestamp_seconds "$k")"
      attempt_ok[$k]="$(value warehouse_backup_last_attempt_success "$k")"
    done
    if [[ "$status" == 0 ]]; then success_ts[$kind]="$now"; attempt_ok[$kind]=1; else attempt_ok[$kind]=0; fi
    tmp="$(mktemp "$dir/.warehouse_backup.prom.XXXXXX")" || exit 1
    {
      echo '# HELP warehouse_backup_last_success_timestamp_seconds Unix time of the last successful backup, by kind.'
      echo '# TYPE warehouse_backup_last_success_timestamp_seconds gauge'
      for k in disk usb; do [[ -z "${success_ts[$k]}" ]] || echo "warehouse_backup_last_success_timestamp_seconds{kind=\"$k\"} ${success_ts[$k]}"; done
      echo '# HELP warehouse_backup_last_attempt_success 1 when the last backup attempt succeeded, 0 when it failed, by kind.'
      echo '# TYPE warehouse_backup_last_attempt_success gauge'
      for k in disk usb; do [[ -z "${attempt_ok[$k]}" ]] || echo "warehouse_backup_last_attempt_success{kind=\"$k\"} ${attempt_ok[$k]}"; done
    } > "$tmp" || { rm -f -- "$tmp"; exit 1; }
    # node exporter runs as another user and must be able to read it.
    chmod 644 -- "$tmp" && mv -f -- "$tmp" "$file" || { rm -f -- "$tmp"; exit 1; }
  )
}

backup_metrics_exit() {
  backup_metrics_record "$@" ||
    echo "Warning: could not write $1/metrics/warehouse_backup.prom; the backup alerts may be wrong until the next backup (setup.sh creates the directory)." >&2
  return 0
}
