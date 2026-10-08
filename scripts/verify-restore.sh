#!/usr/bin/env bash
# Restore a backup into a disposable, network-isolated database and compare integrity.
set -euo pipefail
umask 077
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
backup="${1:-${WAREHOUSE_BACKUP_DIR:-}}"
[[ -n "$backup" && -d "$backup" ]] || { echo 'Usage: npm run db:verify-restore -- PATH_TO_BACKUP' >&2; exit 1; }
for file in database.dump storage.tar.gz integrity.txt metadata.txt SHA256SUMS; do
  [[ -f "$backup/$file" ]] || { echo "Incomplete backup: missing $file" >&2; exit 1; }
done
(cd "$backup" && sha256sum -c SHA256SUMS)
format="$(sed -n 's/^format=//p' "$backup/metadata.txt")"
has_roles=false
has_supabase=false
case "$format" in
  warehouse-backup-v1) ;;
  warehouse-backup-v2|warehouse-backup-v3|warehouse-backup-v4)
    for file in compose.env instance.json; do
      [[ -f "$backup/$file" && ! -L "$backup/$file" ]] || { echo "Incomplete backup: missing $file" >&2; exit 1; }
      grep -Fq "  $file" "$backup/SHA256SUMS" || { echo "Backup checksum missing for $file" >&2; exit 1; }
    done
    if [[ "$format" != warehouse-backup-v2 ]]; then
      has_roles=true
      [[ -f "$backup/roles.txt" && ! -L "$backup/roles.txt" ]] || { echo 'Incomplete backup: missing roles.txt' >&2; exit 1; }
      grep -Fq '  roles.txt' "$backup/SHA256SUMS" || { echo 'Backup checksum missing for roles.txt' >&2; exit 1; }
    fi
    if [[ "$format" == warehouse-backup-v4 ]]; then
      has_supabase=true
      for file in _supabase.dump storage_objects.txt; do
        [[ -f "$backup/$file" && ! -L "$backup/$file" ]] || { echo "Incomplete backup: missing $file" >&2; exit 1; }
        grep -Fq "  $file" "$backup/SHA256SUMS" || { echo "Backup checksum missing for $file" >&2; exit 1; }
      done
    fi
    ;;
  *) echo 'Unsupported backup format.' >&2; exit 1 ;;
esac
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
cleanup() {
  if [[ "$created" == true ]]; then docker rm -f "$container" >/dev/null 2>&1 || true; fi
  rm -rf "$scratch"
}
trap cleanup EXIT

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

docker run -d --pull missing --name "$container" --label purpose=warehouse-restore-test \
  --network none --memory 1g --cpus 1 \
  --tmpfs /var/lib/postgresql/data:rw,size=768m \
  -e JWT_SECRET=isolated-restore-secret-not-for-deployment-12345 -e JWT_EXP=3600 \
  -e AUTH_MODE=disabled -e APP_ENV=verification \
  -e POSTGRES_PASSWORD=disposable-restore-only \
  supabase/postgres:15.8.1.060 >/dev/null
created=true
ready=false
for ((i=0; i<60; i++)); do
  if docker exec "$container" pg_isready -U postgres -h 127.0.0.1 >/dev/null 2>&1; then ready=true; break; fi
  sleep 2
done
[[ "$ready" == true ]] || { echo 'Restore database did not start.' >&2; exit 1; }
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
docker exec -e PGPASSWORD=disposable-restore-only "$container" createdb \
  -U supabase_admin -T template1 warehouse_restore
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
    -U supabase_admin -T template1 _supabase_restore
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
echo 'Backup checksums, storage archive safety, database restore, and integrity comparison passed.'
