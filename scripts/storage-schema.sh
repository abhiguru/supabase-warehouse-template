#!/usr/bin/env bash
# Sourced by scripts/backup.sh, scripts/verify-restore.sh, scripts/restore.sh and scripts/restore-host.sh.
# The Storage service (docker/storage) keeps its own schema version in storage.migrations and migrates the catalog forward
# when it starts, up to the migration named by DB_MIGRATIONS_FREEZE_AT (docker/docker-compose.yml). A backup records the
# newest migration its catalog has applied (storage_migrations_head=, the id, in integrity.txt, which the restore compares with
# the restored database; storage_schema_head= and storage_image= in metadata.txt for people). An older head is fine: Storage
# migrates it forward at the next start. A NEWER head than this checkout's Storage image knows is refused before anything is
# touched: an older Storage image would start without complaint on a schema it was not built for, and a migration cannot be undone.
# docker/storage/migrations-head.txt holds the head of the image in the Dockerfile; tests/migrations.sh keeps it true.

# storage_image_version: the Storage version this checkout's image reports (ENV VERSION in docker/storage/Dockerfile), or unknown.
storage_image_version() {
  local version
  version="$(sed -n 's/^ENV VERSION=//p' "$ROOT/docker/storage/Dockerfile" 2>/dev/null | head -n 1)"
  printf '%s\n' "${version:-unknown}"
}

# storage_checkout_head: the id of the newest Storage migration of this checkout's image; returns 1 when the file is unreadable.
storage_checkout_head() {
  local head
  head="$(sed -n 's/^id=//p' "$ROOT/docker/storage/migrations-head.txt" 2>/dev/null | head -n 1)"
  [[ "$head" =~ ^[0-9]{1,6}$ ]] || return 1
  printf '%s\n' "$head"
}

# storage_check_backup_head BACKUP_DIR: run after the backup's signature and checksums passed. Returns 1, with the reason on
# standard error, when the backup's catalog is on a newer Storage schema than this checkout's image migrates to. A backup
# whose integrity.txt records no storage head (made before it was recorded) passes: nothing is known, Storage migrates it.
storage_check_backup_head() {
  local backup="$1" recorded here
  recorded="$(sed -n 's/^storage_migrations_head=//p' "$backup/integrity.txt" | head -n 1)"
  [[ -n "$recorded" ]] || return 0
  if [[ ! "$recorded" =~ ^[0-9]{1,6}$ ]]; then
    echo "Refusing: the backup records a Storage schema version that is not a number (storage_migrations_head=$recorded). Nothing was moved." >&2
    return 1
  fi
  if ! here="$(storage_checkout_head)"; then
    echo 'Refusing: this checkout has no readable docker/storage/migrations-head.txt, so it cannot tell whether it can read the backup. Nothing was moved.' >&2
    return 1
  fi
  if ((10#$recorded > 10#$here)); then
    echo "Refusing: the backup was taken with Storage schema version $recorded (storage_image=$(sed -n 's/^storage_image=//p' "$backup/metadata.txt" | head -n 1), source_commit=$(sed -n 's/^source_commit=//p' "$backup/metadata.txt" | head -n 1)), newer than version $here, the newest that this checkout's Storage image $(storage_image_version) migrates to. Check out a release at least as new as the backup, then retry. Nothing was moved." >&2
    return 1
  fi
}

# storage_integrity_align BACKUP_INTEGRITY RESTORED_INTEGRITY: before the two reports are diffed. A backup made before the
# Storage head was recorded has no storage_migrations_* lines; the restored database's report then loses them too, so the
# comparison stays about what that backup recorded (as for every other later line, scripts/backup-integrity.sql).
storage_integrity_align() {
  grep -q '^storage_migrations_head=' "$1" && return 0
  grep -v '^storage_migrations_\(count\|head\)=' "$2" > "$2.aligned" || true
  mv "$2.aligned" "$2"
}
