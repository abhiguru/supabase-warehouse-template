#!/usr/bin/env bash
# Restore drill on real containers, run by tests/migrations.sh against its disposable
# database: dump that database into a signed warehouse-backup-v5 fixture and let
# scripts/verify-restore.sh replay it twice.
#   1. While another session is attached to template1 in the verifier's container
#      (the CI failure of 2026-10-09: "source database template1 is being accessed
#      by other users"), with the data directory in memory.
#   2. With the disk-backed data directory, which must be gone afterwards.
# Only disposable, network-isolated containers are used; no operator state is read.
set -euo pipefail
umask 077
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source_db="${1:?usage: verify-restore-drill.sh MIGRATION_TEST_CONTAINER}"
sql() { docker exec -i -e PGPASSWORD=disposable-test-database-only "$source_db" psql -X -q -v ON_ERROR_STOP=1 -U supabase_admin "$@"; }
dump() { docker exec -e PGPASSWORD=disposable-test-database-only "$source_db" pg_dump -U supabase_admin --format=custom --compress=6 "$@"; }

work="$(mktemp -d "${TMPDIR:-/tmp}/warehouse-restore-drill.XXXXXX")"
holder=''
cleanup() {
  status=$?
  trap - EXIT
  [[ -z "$holder" ]] || kill "$holder" 2>/dev/null || true
  # WAREHOUSE_DRILL_KEEP=1 keeps the fixture and any diagnostics for inspection.
  if [[ -n "${WAREHOUSE_DRILL_KEEP:-}" ]]; then echo "Restore drill files kept in $work" >&2; else rm -rf "$work"; fi
  exit "$status"
}
trap cleanup EXIT
backup="$work/warehouse-20260101T000000Z"
mkdir "$backup" "$work/objects" "$work/scratch"

# The fixture, file for file what scripts/backup.sh writes. The Storage service adds
# storage.objects.version in an installed instance; the bare image lacks the column
# that the object catalog query reads.
sql -d postgres -c 'ALTER TABLE storage.objects ADD COLUMN IF NOT EXISTS version text'
dump -d postgres > "$backup/database.dump"
sql -d postgres -c 'CREATE DATABASE _supabase TEMPLATE template0' 2>/dev/null || true
dump -d _supabase > "$backup/_supabase.dump"
sql -d postgres < "$ROOT/scripts/backup-integrity.sql" > "$backup/integrity.txt"
sql -A -t -d postgres -c "SELECT rolname FROM pg_roles WHERE rolname !~ '^pg_' ORDER BY rolname" > "$backup/roles.txt"
sql -A -t -d postgres -c "SELECT p FROM (SELECT bucket_id||'/'||name||COALESCE('/'||version,'') AS p FROM storage.objects) s ORDER BY p COLLATE \"C\"" > "$backup/storage_objects.txt"
while IFS= read -r object; do
  [[ -n "$object" ]] || continue
  mkdir -p "$work/objects/stub/stub/$(dirname "$object")"
  printf 'fictional object\n' > "$work/objects/stub/stub/$object"
done < "$backup/storage_objects.txt"
tar --sort=name --mtime='@0' --owner=0 --group=0 --numeric-owner -C "$work/objects" -czf "$backup/storage.tar.gz" .
printf 'WAREHOUSE_PROJECT_NAME=warehouse-restore-drill\n' > "$backup/compose.env"
printf '{"schemaVersion":1,"instanceId":"0f0f0f0f-0f0f-4f0f-8f0f-0f0f0f0f0f0f"}\n' > "$backup/instance.json"
printf 'format=warehouse-backup-v5\ncreated_at_utc=20260101T000000Z\nsource_commit=drill\n' > "$backup/metadata.txt"
(cd "$backup" && sha256sum database.dump _supabase.dump storage.tar.gz storage_objects.txt integrity.txt metadata.txt compose.env instance.json roles.txt > SHA256SUMS)
# shellcheck source=scripts/backup-key.sh
source "$ROOT/scripts/backup-key.sh"
openssl rand -hex 32 > "$work/backup.key"
backup_key_load "$work/backup.key"
backup_sign_dir "$backup" "$BACKUP_KEY"

verify() {
  env -u WAREHOUSE_STATE_DIR WAREHOUSE_BACKUP_KEY_FILE="$work/backup.key" WAREHOUSE_DIAGNOSTICS_DIR="$work/diagnostics" \
    WAREHOUSE_VERIFY_SCRATCH_DIR="$work/scratch" "$@" bash "$ROOT/scripts/verify-restore.sh" "$backup"
}

# 1. Hold a session on template1 in the verifier's container for as long as it runs.
#    The container is found by its label; containers that existed before are ignored.
existing="$(docker ps -aq --filter label=purpose=warehouse-restore-test | sort)"
(
  while :; do
    target="$(comm -13 <(printf '%s\n' "$existing") <(docker ps -q --filter label=purpose=warehouse-restore-test | sort) | head -n1)"
    if [[ -n "$target" ]] && docker exec -e PGPASSWORD=disposable-restore-only "$target" psql -X -q -h 127.0.0.1 -U supabase_admin -d template1 -c 'SELECT 1' >/dev/null 2>&1; then
      date -u +%H:%M:%S.%N >> "$work/held"
      docker exec -e PGPASSWORD=disposable-restore-only "$target" psql -X -q -h 127.0.0.1 -U supabase_admin -d template1 -c 'SELECT pg_sleep(900)' >/dev/null 2>&1 || true
    fi
    sleep 0.2
  done
) &
holder=$!
verify WAREHOUSE_VERIFY_STORAGE=tmpfs
kill "$holder" 2>/dev/null || true; wait "$holder" 2>/dev/null || true; holder=''
[[ -s "$work/held" ]] || { echo 'Restore drill: no session was ever attached to template1, so the drill proved nothing.' >&2; exit 1; }
echo "Restore drill 1 passed with a session attached to template1 (since $(head -n1 "$work/held") UTC)."

# 2. The disk-backed data directory used when the database does not fit in memory.
verify WAREHOUSE_VERIFY_STORAGE=disk
[[ -z "$(ls -A "$work/scratch")" ]] || { echo "Restore drill: the disk-backed data directory was left behind: $(ls -A "$work/scratch")" >&2; exit 1; }
echo 'Restore drill 2 passed with the disk-backed data directory, which was removed afterwards.'
