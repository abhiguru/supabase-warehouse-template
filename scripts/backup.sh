#!/usr/bin/env bash
# Create a private logical/database + object-storage backup of this checkout.
set -euo pipefail
umask 077
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
compose() { bash "$ROOT/scripts/compose.sh" "$@"; }

timestamp=$(date -u +%Y%m%dT%H%M%SZ)
destination="${1:-${WAREHOUSE_BACKUP_DIR:-$ROOT/backups/warehouse-$timestamp}}"
if [[ -e "$destination" ]]; then
  echo "Refusing to overwrite existing backup path: $destination" >&2
  exit 1
fi
mkdir -p "$destination"
chmod 700 "$destination"

db_id=$(compose ps -q db)
[[ -n "$db_id" ]] || { echo 'Database service is not running.' >&2; exit 1; }
if ! docker inspect --format '{{.State.Health.Status}}' "$db_id" | grep -qx healthy; then
  echo 'Database service is not healthy.' >&2
  exit 1
fi

echo 'Creating transaction-consistent logical database dump.'
compose exec -T db pg_dump -U supabase_admin -d postgres \
  --format=custom --compress=6 --no-owner --no-privileges > "$destination/database.dump"
compose exec -T db psql -X -q -v ON_ERROR_STOP=1 -U supabase_admin -d postgres \
  < "$ROOT/scripts/backup-integrity.sql" > "$destination/integrity.txt"

storage="$ROOT/docker/volumes/storage"
if [[ -d "$storage" ]]; then
  tar --sort=name --mtime='@0' --owner=0 --group=0 --numeric-owner \
    -C "$storage" -czf "$destination/storage.tar.gz" .
else
  empty=$(mktemp -d "${TMPDIR:-/tmp}/warehouse-empty-storage.XXXXXX")
  trap 'rm -rf "$empty"' EXIT
  tar --sort=name --mtime='@0' --owner=0 --group=0 --numeric-owner \
    -C "$empty" -czf "$destination/storage.tar.gz" .
fi

cat > "$destination/metadata.txt" <<EOF
format=warehouse-backup-v1
created_at_utc=$timestamp
source_commit=$(git -C "$ROOT" rev-parse HEAD)
database_image=supabase/postgres:15.8.1.060
consistency=database-snapshot; quiesce application writes for database/storage atomicity
EOF
(cd "$destination" && sha256sum database.dump storage.tar.gz integrity.txt metadata.txt > SHA256SUMS)
chmod 600 "$destination"/*
echo "Backup created at $destination"
echo 'Treat this directory as sensitive and test every retained backup with db:verify-restore.'
