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
# Run alone, this takes the lock; scripts/watch-daily.sh runs it under its own lock and the inherited one is used.
# shellcheck source=scripts/operator-lock.sh
. "$ROOT/scripts/operator-lock.sh"
if ! operator_lock_or_inherited "$state" 2>/dev/null; then echo 'Another operator setup, start, or backup is running for this state.' >&2; exit 1; fi
# shellcheck source=scripts/backup-key.sh
source "$ROOT/scripts/backup-key.sh"
backup_key_ensure "$state"
backup_key_load "$state/config/backup.key"
# Recorded before anything is stopped; a source archive without .git has no commit.
source_commit="$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || true)"
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
# Only the services this script stopped come back: --no-deps keeps compose from also starting what they depend
# on (restarting storage would start rest, which the operator may have stopped on purpose).
cleanup() {
  status=$?
  trap - EXIT
  if ((${#restart[@]})); then
    if ! compose up -d --no-recreate --no-deps --wait --wait-timeout 180 "${restart[@]}"; then
      if command -v node >/dev/null 2>&1; then node "$ROOT/scripts/service-diagnostics.mjs" --unhealthy || true; else echo 'Service diagnostics skipped (node not on PATH): run node scripts/service-diagnostics.mjs --unhealthy' >&2; fi
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

# The backup records the database image of this checkout (database_image= in metadata.txt), so the
# running server must be that release's: an install that pulled this release but still runs the earlier
# container (another PostgreSQL major) would dump the old schema under the new label that every restore accepts.
# Checked before any service is stopped.
pin="$(bash "$ROOT/scripts/db-image.sh")"
pin_major="${pin#postgres:}"; pin_major="${pin_major%%[!0-9]*}"
server="$(compose exec -T db psql -X -A -t -v ON_ERROR_STOP=1 -U supabase_admin -d postgres \
  -c "SELECT current_setting('server_version_num')::int / 10000 || '|' || (to_regrole('postgres') IS NULL)" | tr -d '[:space:]')"
if [[ "$server" != "$pin_major|true" ]]; then
  echo "Refusing: the running database reports '$server' (major version | has no role postgres), but this release runs PostgreSQL $pin_major with no role postgres. A backup of it would carry the wrong image label. This installation has not been moved to this release's database yet. From PostgreSQL $((pin_major - 1)): follow docs/OPERATOR_INSTALL.md, \"Major PostgreSQL upgrade\" (back up with the checkout that runs the old server first). From before PostgreSQL 17: back it up with the release tagged migrations-pre-baseline, then follow \"Baseline reload\"." >&2
  exit 1
fi

# Stop ingress first, then all services that can write the database or object
# storage. Capture only running services so the cleanup never starts an optional
# service the operator had intentionally stopped.
for service in kong functions rest storage supavisor; do
  id=$(compose ps -q "$service")
  if [[ -n "$id" && "$(docker inspect --format '{{.State.Running}}' "$id")" == true ]]; then restart+=("$service"); fi
done
for service in "${restart[@]}"; do compose stop "$service"; done

echo 'Creating transaction-consistent logical database dumps.'
# Owners are kept so scripts/restore.sh can replay the dump in place with the
# original ownership; scripts/verify-restore.sh still restores it with --no-owner.
compose exec -T db pg_dump -U supabase_admin -d postgres \
  --format=custom --compress=6 > "$stage/database.dump"
# The pooler's _supabase database is not dumped: it holds only the pooler's own metadata, and the pooler writes its
# tenant again at every start (volumes/pooler/pooler.exs). Backups from before this change carry _supabase.dump;
# restore.sh and verify-restore.sh skip it.
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
# The central sign-in key set (public keys only) that setup.sh --central-jwks-file copied into the
# state. compose.env keeps naming it, so db:restore-host must be able to put it back: without it the
# restored host offers central sign-in and every exchange fails. Absent for an installation that
# fetches the keys or has no central sign-in.
optional_files=()
key_file="$state/public/central-jwks.json"
if [[ -e "$key_file" || -L "$key_file" ]]; then
  [[ -f "$key_file" && ! -L "$key_file" ]] || { echo "Refusing: $key_file is not a regular file." >&2; exit 1; }
  cp "$key_file" "$stage/central-jwks.json"
  chmod 600 "$stage/central-jwks.json"
  optional_files+=(central-jwks.json)
fi
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
format=warehouse-backup-v5
created_at_utc=$timestamp
source_commit=${source_commit:-unknown}
database_image=$pin
consistency=write-facing services stopped during database/storage capture
EOF
(cd "$stage" && sha256sum database.dump storage.tar.gz storage_objects.txt integrity.txt metadata.txt compose.env instance.json roles.txt "${optional_files[@]}" "${tunnel_files[@]}" > SHA256SUMS)
# The signature covers SHA256SUMS and so every file; the key itself is never copied into the backup.
backup_sign_dir "$stage" "$BACKUP_KEY"
find "$stage" -mindepth 1 -type f -exec chmod 600 {} +
find "$stage" -mindepth 1 -type d -exec chmod 700 {} +
mv "$stage" "$destination"
if ((${#restart[@]})); then compose up -d --no-recreate --no-deps --wait --wait-timeout 180 "${restart[@]}"; restart=(); fi
echo "Backup created at $destination"
echo 'Treat this directory as sensitive and test every retained backup with db:verify-restore.'
echo "It is signed with $state/config/backup.key; keep a copy of that key away from this machine and from the backup drive."
