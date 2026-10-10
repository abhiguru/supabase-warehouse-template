#!/usr/bin/env bash
# Restore a backup into a disposable, network-isolated database and compare integrity.
#   npm run db:verify-restore -- [--allow-unsigned] PATH_TO_BACKUP
# The backup signature is checked first with the backup key
# (WAREHOUSE_BACKUP_KEY_FILE, else $WAREHOUSE_STATE_DIR/config/backup.key).
# Optional environment:
#   WAREHOUSE_VERIFY_DATA_MB      size of the disposable data directory (default: from the dump sizes, at least 768)
#   WAREHOUSE_VERIFY_SIZE_FACTOR  restored size estimate per dump byte (default 10)
#   WAREHOUSE_VERIFY_MEMORY_MB    memory limit of the disposable container
#   WAREHOUSE_VERIFY_STORAGE      auto (default: memory when it fits, else disk), tmpfs or disk
#   WAREHOUSE_VERIFY_SCRATCH_DIR  parent of the disk-backed data directory (default: $WAREHOUSE_STATE_DIR)
#   WAREHOUSE_DIAGNOSTICS_DIR     where a failed run leaves the container log (default: $WAREHOUSE_STATE_DIR/diagnostics)
set -euo pipefail
umask 077
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Same image, by digest, as docker/postgres/Dockerfile builds the production database from.
IMAGE='supabase/postgres:15.8.1.060@sha256:0e2279598bc0224fb5960c3a61eb23270cd60119427f3a7bdec86ba282600dcc'
usage() { echo 'Usage: npm run db:verify-restore -- [--allow-unsigned] PATH_TO_BACKUP' >&2; exit 1; }
allow_unsigned=false
backup=''
while (($#)); do
  case "$1" in
    --allow-unsigned) allow_unsigned=true ;;
    -h|--help) usage ;;
    -*) echo "Unknown option: $1" >&2; usage ;;
    *) [[ -z "$backup" ]] || usage; backup="$1" ;;
  esac
  shift
done
[[ -n "$backup" ]] || backup="${WAREHOUSE_BACKUP_DIR:-}"
[[ -n "$backup" && -d "$backup" ]] || usage
for file in database.dump storage.tar.gz integrity.txt metadata.txt SHA256SUMS; do
  [[ -f "$backup/$file" ]] || { echo "Incomplete backup: missing $file" >&2; exit 1; }
done
# shellcheck source=scripts/backup-key.sh
source "$ROOT/scripts/backup-key.sh"
# Checksums and signature come first: nothing below reads the backup before this passes.
backup_authenticate "$backup" "$allow_unsigned" || exit 1
format="$(sed -n 's/^format=//p' "$backup/metadata.txt")"
has_roles=false
has_supabase=false
case "$format" in
  warehouse-backup-v1) ;;
  warehouse-backup-v2|warehouse-backup-v3|warehouse-backup-v4|warehouse-backup-v5)
    for file in compose.env instance.json; do
      [[ -f "$backup/$file" && ! -L "$backup/$file" ]] || { echo "Incomplete backup: missing $file" >&2; exit 1; }
      grep -Fq "  $file" "$backup/SHA256SUMS" || { echo "Backup checksum missing for $file" >&2; exit 1; }
    done
    if [[ "$format" != warehouse-backup-v2 ]]; then
      has_roles=true
      [[ -f "$backup/roles.txt" && ! -L "$backup/roles.txt" ]] || { echo 'Incomplete backup: missing roles.txt' >&2; exit 1; }
      grep -Fq '  roles.txt' "$backup/SHA256SUMS" || { echo 'Backup checksum missing for roles.txt' >&2; exit 1; }
    fi
    if [[ "$format" == warehouse-backup-v4 || "$format" == warehouse-backup-v5 ]]; then
      has_supabase=true
      for file in _supabase.dump storage_objects.txt; do
        [[ -f "$backup/$file" && ! -L "$backup/$file" ]] || { echo "Incomplete backup: missing $file" >&2; exit 1; }
        grep -Fq "  $file" "$backup/SHA256SUMS" || { echo "Backup checksum missing for $file" >&2; exit 1; }
      done
    fi
    ;;
  *) echo 'Unsupported backup format.' >&2; exit 1 ;;
esac
# From v5 on every backup is signed; a v5 backup without a verified signature was tampered with or mislabelled.
if [[ "$format" == warehouse-backup-v5 && "$BACKUP_SIGNED" != true && "$allow_unsigned" != true ]]; then
  echo 'Refusing: a warehouse-backup-v5 backup must carry a valid signature.' >&2; exit 1
fi
# Optional tunnel credential (scripts/tunnel.sh): only known regular files, each checksummed.
if [[ -e "$backup/tunnel" || -L "$backup/tunnel" ]]; then
  [[ -d "$backup/tunnel" && ! -L "$backup/tunnel" ]] || { echo 'Backup tunnel entry is not a directory.' >&2; exit 1; }
  while IFS= read -r -d '' entry; do
    file="${entry#"$backup/"}"
    [[ "$file" =~ ^tunnel/(config\.yml|credentials\.json|token)$ && -f "$entry" && ! -L "$entry" ]] || { echo "Unexpected entry in the backup tunnel directory: $file" >&2; exit 1; }
    grep -Fqx "$(cd "$backup" && sha256sum "$file")" "$backup/SHA256SUMS" || { echo "Backup checksum missing for $file" >&2; exit 1; }
  done < <(find "$backup/tunnel" -mindepth 1 -print0)
fi
# Same catalog projection as scripts/backup.sh: <bucket>/<name>/<version> in byte order.
catalog_query="SELECT p FROM (SELECT bucket_id||'/'||name||COALESCE('/'||version,'') AS p FROM storage.objects) s ORDER BY p COLLATE \"C\""

if tar -tzf "$backup/storage.tar.gz" | grep -Eq '(^/|(^|/)\.\.(/|$))'; then
  echo 'Unsafe path in storage archive.' >&2
  exit 1
fi
if tar -tvzf "$backup/storage.tar.gz" | grep -Eq '^[lh]'; then
  echo 'Storage archive contains a link; refusing unsafe extraction.' >&2
  exit 1
fi
scratch=$(mktemp -d "${TMPDIR:-/tmp}/warehouse-restore.XXXXXX")
container="warehouse-restore-$(openssl rand -hex 6)"
created=false
disk_dir=''
# A failed run keeps the evidence: the container log, its state and the database
# sessions are saved before the disposable container is removed.
save_diagnostics() {
  local base dir
  base="${WAREHOUSE_DIAGNOSTICS_DIR:-}"
  if [[ -z "$base" && "${WAREHOUSE_STATE_DIR:-}" == /* && -d "${WAREHOUSE_STATE_DIR:-}" ]]; then base="$WAREHOUSE_STATE_DIR/diagnostics"; fi
  [[ -n "$base" ]] || base="${TMPDIR:-/tmp}/warehouse-diagnostics"
  dir="$base/verify-restore-$(date -u +%Y%m%dT%H%M%SZ)-${container#warehouse-restore-}"
  mkdir -p -m 700 "$dir" 2>/dev/null || return 0
  docker logs --tail 400 "$container" > "$dir/container.log" 2>&1 || true
  docker inspect --format '{{json .State}}' "$container" > "$dir/container-state.json" 2>/dev/null || true
  docker exec -e PGPASSWORD=disposable-restore-only "$container" psql -X -A -U supabase_admin -d postgres \
    -c 'SELECT pid, backend_type, datname, usename, state, wait_event_type, wait_event, backend_start, left(query, 200) AS query FROM pg_stat_activity ORDER BY backend_start' \
    > "$dir/pg_stat_activity.txt" 2>&1 || true
  echo "Restore verification failed. Container log, state and database sessions were saved in $dir" >&2
  if grep -Eq 'No space left on device|Check free disk space|could not extend file' "$dir/container.log" 2>/dev/null; then
    echo "The disposable database ran out of space: its data directory was ${data_mb:-?} MiB (${sized:-default}) on ${storage:-?}. This says nothing about the backup. Repeat with a larger WAREHOUSE_VERIFY_DATA_MB or WAREHOUSE_VERIFY_SIZE_FACTOR." >&2
  fi
  echo 'Sessions at the time of the failure (pid|backend|database|state):' >&2
  docker exec -e PGPASSWORD=disposable-restore-only "$container" psql -X -A -t -U supabase_admin -d postgres \
    -c 'SELECT pid, backend_type, datname, state FROM pg_stat_activity ORDER BY backend_start' >&2 2>/dev/null || echo '  (the database did not answer)' >&2
}
cleanup() {
  local status=$?
  trap - EXIT
  if [[ "$created" == true ]]; then
    if ((status != 0)); then save_diagnostics || true; fi
    docker rm -f "$container" >/dev/null 2>&1 || true
  fi
  if [[ -n "$disk_dir" && -d "$disk_dir" ]]; then
    # PostgreSQL files belong to the container's postgres user, so the image removes them.
    docker run --rm --network none --user 0:0 --entrypoint /bin/rm -v "$disk_dir:/scratch" "$IMAGE" -rf /scratch/data >/dev/null 2>&1 || true
    rm -rf -- "$disk_dir" 2>/dev/null || echo "Could not remove the disposable data directory $disk_dir; remove it with: sudo rm -rf $disk_dir" >&2
  fi
  rm -rf "$scratch"
  exit "$status"
}
trap cleanup EXIT

# Size the disposable database from the backup. The restored cluster holds the
# initialized image, both databases with their rebuilt indexes and the WAL the
# load writes, so the dump size is multiplied and the WAL allowance added.
natural() { [[ "$2" =~ ^[1-9][0-9]*$ ]] || { echo "$1 must be a positive whole number: $2" >&2; exit 1; }; }
mib() { echo $(( ($1 + 1048575) / 1048576 )); }
dump_bytes="$(stat -c %s -- "$backup/database.dump")"
if [[ "$has_supabase" == true ]]; then dump_bytes=$((dump_bytes + $(stat -c %s -- "$backup/_supabase.dump"))); fi
dump_mb="$(mib "$dump_bytes")"
factor="${WAREHOUSE_VERIFY_SIZE_FACTOR:-10}"; natural WAREHOUSE_VERIFY_SIZE_FACTOR "$factor"
estimate_mb=$((dump_mb * factor))
wal_mb=$((estimate_mb < 1024 ? estimate_mb : 1024))
data_mb=$((256 + estimate_mb + wal_mb))
((data_mb >= 768)) || data_mb=768
sized="dumps of $dump_mb MiB x $factor, plus WAL and the empty cluster"
if [[ -n "${WAREHOUSE_VERIFY_DATA_MB:-}" ]]; then natural WAREHOUSE_VERIFY_DATA_MB "$WAREHOUSE_VERIFY_DATA_MB"; data_mb="$WAREHOUSE_VERIFY_DATA_MB"; sized='WAREHOUSE_VERIFY_DATA_MB'; fi
storage="${WAREHOUSE_VERIFY_STORAGE:-auto}"
[[ "$storage" == auto || "$storage" == tmpfs || "$storage" == disk ]] || { echo "WAREHOUSE_VERIFY_STORAGE must be auto, tmpfs or disk: $storage" >&2; exit 1; }
tmpfs_memory_mb=$((data_mb + 256))
available_mb="$(awk '/^MemAvailable:/ { print int($2 / 1024) }' /proc/meminfo 2>/dev/null || true)"
[[ "$available_mb" =~ ^[0-9]+$ ]] || available_mb=0
scratch_parent="${WAREHOUSE_VERIFY_SCRATCH_DIR:-}"
if [[ -z "$scratch_parent" && "${WAREHOUSE_STATE_DIR:-}" == /* ]]; then scratch_parent="$WAREHOUSE_STATE_DIR"; fi
if [[ "$storage" == auto ]]; then
  if ((tmpfs_memory_mb <= available_mb)); then storage=tmpfs; else storage=disk; fi
elif [[ "$storage" == tmpfs ]] && ((tmpfs_memory_mb > available_mb)); then
  echo "Restore verification needs a $data_mb MiB in-memory database ($sized) and $tmpfs_memory_mb MiB of memory, but only $available_mb MiB are available. Use WAREHOUSE_VERIFY_STORAGE=disk, or free memory." >&2
  exit 1
fi
if [[ "$storage" == tmpfs ]]; then
  memory_mb="$tmpfs_memory_mb"
  data_args=(--tmpfs "/var/lib/postgresql/data:rw,size=${data_mb}m")
else
  memory_mb=1024
  if [[ -z "$scratch_parent" ]]; then
    echo "Restore verification needs a $data_mb MiB database ($sized); $tmpfs_memory_mb MiB of memory are not available ($available_mb MiB free), and no directory is set for a disk-backed run. Set WAREHOUSE_STATE_DIR or WAREHOUSE_VERIFY_SCRATCH_DIR." >&2
    exit 1
  fi
  [[ "$scratch_parent" == /* && -d "$scratch_parent" && -w "$scratch_parent" ]] || { echo "The directory for the disk-backed restore verification is not a writable absolute directory: $scratch_parent" >&2; exit 1; }
  free_mb="$(df -B1M --output=avail -- "$scratch_parent" | tail -n1 | tr -d ' ')"
  if ((free_mb < data_mb + 64)); then
    echo "Restore verification needs $data_mb MiB for the disposable database ($sized) but only $free_mb MiB are free in $scratch_parent. Free space there, or point WAREHOUSE_VERIFY_SCRATCH_DIR at a directory with room." >&2
    exit 1
  fi
fi
if [[ -n "${WAREHOUSE_VERIFY_MEMORY_MB:-}" ]]; then natural WAREHOUSE_VERIFY_MEMORY_MB "$WAREHOUSE_VERIFY_MEMORY_MB"; memory_mb="$WAREHOUSE_VERIFY_MEMORY_MB"; fi
echo "Restore verification: disposable database of $data_mb MiB ($sized) on $storage, memory limit $memory_mb MiB."

if [[ "$has_supabase" == true ]]; then
  # Every catalogued object must be present in the archive. Storage keeps files
  # under a tenant prefix, so a catalog entry is matched as a path suffix.
  # Archive files without a catalog entry are reported but do not fail.
  tar -tzf "$backup/storage.tar.gz" | sed -n 's#^\./##; /[^/]$/p' > "$scratch/archive_files.txt"
  awk -v missing="$scratch/missing_objects.txt" -v extra="$scratch/extra_files.txt" '
    FILENAME == ARGV[1] { if (length($0)) want[$0] = 1; next }
    {
      n = split($0, parts, "/"); suffix = ""; hit = 0
      for (i = n; i >= 1; i--) {
        suffix = (i == n) ? parts[i] : parts[i] "/" suffix
        if (suffix in want) { found[suffix] = 1; hit = 1; break }
      }
      if (!hit) print $0 > extra
    }
    END { for (entry in want) if (!(entry in found)) print entry > missing }
  ' "$backup/storage_objects.txt" "$scratch/archive_files.txt"
  if [[ -s "$scratch/missing_objects.txt" ]]; then
    echo 'Catalogued storage objects are missing from storage.tar.gz:' >&2
    sort "$scratch/missing_objects.txt" >&2
    exit 1
  fi
  if [[ -s "$scratch/extra_files.txt" ]]; then
    echo "Warning: $(wc -l < "$scratch/extra_files.txt") archived storage file(s) have no catalog entry (first 20 shown):" >&2
    sort "$scratch/extra_files.txt" | head -n 20 >&2
  fi
fi
tar -xzf "$backup/storage.tar.gz" -C "$scratch"

if [[ "$storage" == disk ]]; then
  disk_dir="$(mktemp -d "$scratch_parent/.verify-restore.XXXXXX")"
  mkdir -m 700 "$disk_dir/data"
  data_args=(-v "$disk_dir/data:/var/lib/postgresql/data")
fi
docker run -d --pull missing --name "$container" --label purpose=warehouse-restore-test \
  --network none --memory "${memory_mb}m" --cpus 1 \
  "${data_args[@]}" \
  -e JWT_SECRET=isolated-restore-secret-not-for-deployment-12345 -e JWT_EXP=3600 \
  -e AUTH_MODE=disabled -e APP_ENV=verification \
  -e POSTGRES_PASSWORD=disposable-restore-only \
  "$IMAGE" >/dev/null
created=true
ready=false
for ((i=0; i<60; i++)); do
  if docker exec "$container" pg_isready -U postgres -h 127.0.0.1 >/dev/null 2>&1; then ready=true; break; fi
  # A container that has already exited will not become ready.
  [[ "$(docker inspect --format '{{.State.Running}}' "$container" 2>/dev/null || true)" != false ]] || break
  sleep 2
done
[[ "$ready" == true ]] || { echo "Restore database did not start (data directory of $data_mb MiB on $storage, memory limit $memory_mb MiB)." >&2; exit 1; }
# The logical dump preserves ACLs, while Compose init scripts may add grant
# targets that the bare pinned image lacks. Recreate absent names in this
# disposable database so pg_restore verifies the original ACLs.
if [[ "$has_roles" == true ]]; then
  docker cp "$backup/roles.txt" "$container:/tmp/roles.txt"
  docker exec -i -e PGPASSWORD=disposable-restore-only "$container" \
    psql -X -q -v ON_ERROR_STOP=1 -U supabase_admin -d postgres <<'SQL'
CREATE TEMP TABLE restore_roles (role_name name NOT NULL);
\copy restore_roles(role_name) FROM '/tmp/roles.txt'
DO $$
DECLARE missing_role name;
BEGIN
  FOR missing_role IN SELECT role_name FROM restore_roles LOOP
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = missing_role) THEN
      EXECUTE format('CREATE ROLE %I NOLOGIN', missing_role);
    END IF;
  END LOOP;
END $$;
SQL
fi
docker cp "$backup/database.dump" "$container:/tmp/database.dump"
# template0, never template1: the image's own start-up sessions attach to template1
# and CREATE DATABASE refuses a template that anyone is connected to. template0
# accepts no connections, and a dump restores completely into a copy of it.
docker exec -e PGPASSWORD=disposable-restore-only "$container" createdb \
  -U supabase_admin -T template0 warehouse_restore
docker exec -e PGPASSWORD=disposable-restore-only "$container" pg_restore \
  -U supabase_admin -d warehouse_restore --no-owner --clean --if-exists \
  --no-acl --section=pre-data --exit-on-error /tmp/database.dump
docker exec -e PGPASSWORD=disposable-restore-only "$container" pg_restore \
  -U supabase_admin -d warehouse_restore --no-owner --no-acl \
  --section=data --exit-on-error /tmp/database.dump
docker exec -e PGPASSWORD=disposable-restore-only "$container" pg_restore \
  -U supabase_admin -d warehouse_restore --no-owner --no-acl \
  --section=post-data --exit-on-error /tmp/database.dump
# pg_graphql registers this wrapper only when graphql_public exists during
# extension initialization. Logical replay may create that schema afterward.
docker exec -i -e PGPASSWORD=disposable-restore-only "$container" \
  psql -X -q -v ON_ERROR_STOP=1 -U supabase_admin -d warehouse_restore <<'SQL'
CREATE OR REPLACE FUNCTION graphql_public.graphql(
  "operationName" text DEFAULT NULL, query text DEFAULT NULL,
  variables jsonb DEFAULT NULL, extensions jsonb DEFAULT NULL
) RETURNS jsonb LANGUAGE sql AS $$
  SELECT graphql.resolve(
    query := query, variables := coalesce(variables, '{}'::jsonb),
    "operationName" := "operationName", extensions := extensions
  );
$$;
SQL
# Replay ACLs only after all objects, including extension-owned wrappers, exist.
docker exec "$container" sh -c "pg_restore -l /tmp/database.dump | awk '/^[0-9]+; .* ACL / { print }' > /tmp/acl.list"
docker exec -e PGPASSWORD=disposable-restore-only "$container" pg_restore \
  -U supabase_admin -d warehouse_restore --no-owner -L /tmp/acl.list \
  --exit-on-error /tmp/database.dump
if [[ "$has_supabase" == true ]]; then
  # The pooler/analytics database must replay completely as well.
  docker cp "$backup/_supabase.dump" "$container:/tmp/_supabase.dump"
  docker exec -e PGPASSWORD=disposable-restore-only "$container" createdb \
    -U supabase_admin -T template0 _supabase_restore
  docker exec -e PGPASSWORD=disposable-restore-only "$container" pg_restore \
    -U supabase_admin -d _supabase_restore --no-owner --no-acl \
    --exit-on-error /tmp/_supabase.dump
fi
docker exec -i -e PGPASSWORD=disposable-restore-only "$container" \
  psql -X -q -v ON_ERROR_STOP=1 -U supabase_admin -d warehouse_restore \
  < "$ROOT/scripts/backup-integrity.sql" > "$scratch/integrity.txt"
diff -u "$backup/integrity.txt" "$scratch/integrity.txt"
if [[ "$has_supabase" == true ]]; then
  # The restored catalog must list exactly what the backup catalogued, and the
  # archive listing above already proved every entry has a file.
  docker exec -e PGPASSWORD=disposable-restore-only "$container" \
    psql -X -A -t -v ON_ERROR_STOP=1 -U supabase_admin -d warehouse_restore \
    -c "$catalog_query" > "$scratch/storage_objects.txt"
  diff -u "$backup/storage_objects.txt" "$scratch/storage_objects.txt"
fi
if [[ "$BACKUP_SIGNED" == true ]]; then
  echo 'Backup signature, checksums, storage archive safety, database restore, and integrity comparison passed.'
else
  echo 'Backup checksums, storage archive safety, database restore, and integrity comparison passed. The backup is UNSIGNED: its origin was not proven.'
fi
