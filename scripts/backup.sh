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
compose config --quiet
exec 9>"$state/config/operator.lock"
if ! flock -n 9; then echo 'Another operator setup, start, or backup is running for this state.' >&2; exit 1; fi
mkdir -p "$state/backups"
destination="${1:-${WAREHOUSE_BACKUP_DIR:-$state/backups/warehouse-$timestamp}}"
if [[ "$destination" != /* || -e "$destination" || -L "$destination" || "$(realpath -m "$destination")" == "$state/data"/* ]]; then
  echo "Refusing to overwrite existing backup path: $destination" >&2
  exit 1
fi
parent="$(dirname "$destination")"
[[ -d "$parent" ]] || { echo "Backup parent does not exist: $parent" >&2; exit 1; }
if [[ "$(stat -c %d "$parent")" == "$(stat -c %d "$state/data")" ]]; then
  echo "Warning: $parent shares a filesystem with $state/data; a backup there does not survive loss of this disk. Copy it to protected off-host storage." >&2
fi
stage="$(mktemp -d "$parent/.warehouse-backup-staging.XXXXXXXX")"
restart=()
cleanup() {
  status=$?
  trap - EXIT
  if ((${#restart[@]})); then
    if ! compose up -d --no-recreate --wait --wait-timeout 180 "${restart[@]}"; then
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
for service in kong functions rest storage realtime studio meta imgproxy gotenberg auth supavisor; do
  id=$(compose ps -q "$service")
  if [[ -n "$id" && "$(docker inspect --format '{{.State.Running}}' "$id")" == true ]]; then restart+=("$service"); fi
done
for service in "${restart[@]}"; do compose stop "$service"; done

echo 'Creating transaction-consistent logical database dumps.'
# Owners are kept so scripts/restore.sh can replay the dump in place with the
# original ownership; scripts/verify-restore.sh still restores it with --no-owner.
compose exec -T db pg_dump -U supabase_admin -d postgres \
  --format=custom --compress=6 > "$stage/database.dump"
# _supabase holds the pooler (_supavisor) and analytics schemas outside the
# application database; the in-place restore needs it for a complete instance.
compose exec -T db pg_dump -U supabase_admin -d _supabase \
  --format=custom --compress=6 > "$stage/_supabase.dump"
compose exec -T db psql -X -q -v ON_ERROR_STOP=1 -U supabase_admin -d postgres \
  < "$ROOT/scripts/backup-integrity.sql" > "$stage/integrity.txt"
compose exec -T db psql -X -A -t -v ON_ERROR_STOP=1 -U supabase_admin -d postgres \
  -c "SELECT rolname FROM pg_roles WHERE rolname !~ '^pg_' ORDER BY rolname" > "$stage/roles.txt"
# Object catalog as <bucket>/<name>/<version>: every entry must exist as a path
# suffix inside storage.tar.gz. Byte order keeps the listing diffable after restore.
compose exec -T db psql -X -A -t -v ON_ERROR_STOP=1 -U supabase_admin -d postgres \
  -c "SELECT p FROM (SELECT bucket_id||'/'||name||COALESCE('/'||version,'') AS p FROM storage.objects) s ORDER BY p COLLATE \"C\"" > "$stage/storage_objects.txt"

storage="$state/data/storage"
tar --sort=name --mtime='@0' --owner=0 --group=0 --numeric-owner \
  -C "$storage" -czf "$stage/storage.tar.gz" .
cp "$state/config/compose.env" "$stage/compose.env"
cp "$state/public/instance.json" "$stage/instance.json"
chmod 600 "$stage/compose.env" "$stage/instance.json"
# The tunnel credential kept by scripts/tunnel.sh, so db:restore-host can bring the
# public address back on a new host. Only its known regular files are copied.
tunnel_files=()
if [[ -d "$state/config/tunnel" && ! -L "$state/config/tunnel" ]]; then
  mkdir -m 700 "$stage/tunnel"
  for file in config.yml credentials.json token; do
    path="$state/config/tunnel/$file"
    [[ -e "$path" || -L "$path" ]] || continue
    [[ -f "$path" && ! -L "$path" ]] || { echo "Refusing: $path is not a regular file." >&2; exit 1; }
    cp "$path" "$stage/tunnel/$file"
    tunnel_files+=("tunnel/$file")
  done
fi

cat > "$stage/metadata.txt" <<EOF
format=warehouse-backup-v4
created_at_utc=$timestamp
source_commit=$(git -C "$ROOT" rev-parse HEAD)
database_image=supabase/postgres:15.8.1.060
consistency=write-facing services stopped during database/storage capture
EOF
(cd "$stage" && sha256sum database.dump _supabase.dump storage.tar.gz storage_objects.txt integrity.txt metadata.txt compose.env instance.json roles.txt "${tunnel_files[@]}" > SHA256SUMS)
find "$stage" -mindepth 1 -type f -exec chmod 600 {} +
find "$stage" -mindepth 1 -type d -exec chmod 700 {} +
mv "$stage" "$destination"
if ((${#restart[@]})); then compose up -d --no-recreate --wait --wait-timeout 180 "${restart[@]}"; restart=(); fi
echo "Backup created at $destination"
echo 'Treat this directory as sensitive and test every retained backup with db:verify-restore.'
