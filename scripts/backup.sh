#!/usr/bin/env bash
# Create a private logical database, object storage and instance-configuration backup.
set -euo pipefail
umask 077
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
compose() { bash "$ROOT/scripts/compose.sh" "$@"; }

timestamp=$(date -u +%Y%m%dT%H%M%SZ)
state="${WAREHOUSE_STATE_DIR:-}"
[[ "$state" == /* && -f "$state/config/compose.env" && -f "$state/public/instance.json" && -d "$state/data/storage" ]] || {
  echo 'Set WAREHOUSE_STATE_DIR to the installed operator state.' >&2; exit 1;
}
mkdir -p "$state/backups"
destination="${1:-${WAREHOUSE_BACKUP_DIR:-$state/backups/warehouse-$timestamp}}"
if [[ -e "$destination" || -L "$destination" || "$destination" == "$state/data"/* ]]; then
  echo "Refusing to overwrite existing backup path: $destination" >&2
  exit 1
fi
parent="$(dirname "$destination")"
[[ -d "$parent" ]] || { echo "Backup parent does not exist: $parent" >&2; exit 1; }
stage="$(mktemp -d "$parent/.warehouse-backup-staging.XXXXXXXX")"
restart=()
cleanup() {
  status=$?
  trap - EXIT
  if ((${#restart[@]})); then
    if ! compose start "${restart[@]}"; then
      echo 'Backup services did not restart cleanly; run doctor and start.sh.' >&2
      status=1
    fi
  fi
  [[ ! -d "$stage" ]] || rm -rf "$stage"
  exit "$status"
}
trap cleanup EXIT

db_id=$(compose ps -q db)
[[ -n "$db_id" ]] || { echo 'Database service is not running.' >&2; exit 1; }
if ! docker inspect --format '{{.State.Health.Status}}' "$db_id" | grep -qx healthy; then
  echo 'Database service is not healthy.' >&2
  exit 1
fi

# Stop ingress first, then all services that can write the database or object
# storage. Capture only running services so the cleanup never starts an optional
# service the operator had intentionally stopped.
for service in kong functions rest storage realtime studio meta imgproxy gotenberg; do
  id=$(compose ps -q "$service")
  if [[ -n "$id" && "$(docker inspect --format '{{.State.Running}}' "$id")" == true ]]; then restart+=("$service"); fi
done
for service in "${restart[@]}"; do compose stop "$service"; done

echo 'Creating transaction-consistent logical database dump.'
compose exec -T db pg_dump -U supabase_admin -d postgres \
  --format=custom --compress=6 --no-owner > "$stage/database.dump"
compose exec -T db psql -X -q -v ON_ERROR_STOP=1 -U supabase_admin -d postgres \
  < "$ROOT/scripts/backup-integrity.sql" > "$stage/integrity.txt"

storage="$state/data/storage"
tar --sort=name --mtime='@0' --owner=0 --group=0 --numeric-owner \
  -C "$storage" -czf "$stage/storage.tar.gz" .
cp "$state/config/compose.env" "$stage/compose.env"
cp "$state/public/instance.json" "$stage/instance.json"
chmod 600 "$stage/compose.env" "$stage/instance.json"

cat > "$stage/metadata.txt" <<EOF
format=warehouse-backup-v2
created_at_utc=$timestamp
source_commit=$(git -C "$ROOT" rev-parse HEAD)
database_image=supabase/postgres:15.8.1.060
consistency=write-facing services stopped during database/storage capture
EOF
(cd "$stage" && sha256sum database.dump storage.tar.gz integrity.txt metadata.txt compose.env instance.json > SHA256SUMS)
chmod 600 "$stage"/*
mv "$stage" "$destination"
if ((${#restart[@]})); then compose start "${restart[@]}"; restart=(); fi
echo "Backup created at $destination"
echo 'Treat this directory as sensitive and test every retained backup with db:verify-restore.'
