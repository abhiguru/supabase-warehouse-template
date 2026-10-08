#!/usr/bin/env bash
# Replace this instance's database and stored objects in place from a
# warehouse-backup-v4 directory created by scripts/backup.sh on the same instance.
# Destructive by design: requires --yes, stopped services and a backup that passes
# scripts/verify-restore.sh. The replaced data directories are kept for rollback.
set -euo pipefail
umask 077
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
compose() { bash "$ROOT/scripts/compose.sh" "$@"; }
usage() { echo 'Usage: npm run db:restore -- --yes PATH_TO_BACKUP [--restore-config]' >&2; exit 1; }

confirm=false
restore_config=false
backup=''
while (($#)); do
  case "$1" in
    --yes) confirm=true ;;
    --restore-config) restore_config=true ;;
    -h|--help) usage ;;
    -*) echo "Unknown option: $1" >&2; usage ;;
    *) [[ -z "$backup" ]] || usage; backup="$1" ;;
  esac
  shift
done
[[ -n "$backup" ]] || usage
if [[ "$confirm" != true ]]; then
  echo 'Refusing: in-place restore replaces the database and stored objects of this instance. Pass --yes to confirm.' >&2
  exit 1
fi
[[ -d "$backup" && ! -L "$backup" ]] || { echo "Backup directory not found: $backup" >&2; exit 1; }
backup="$(realpath -e "$backup")"

# shellcheck source=scripts/operator-lock.sh
source "$ROOT/scripts/operator-lock.sh"
state="$(operator_state)"
[[ -f "$state/config/compose.env" && -f "$state/public/instance.json" && -d "$state/data/db" && -d "$state/data/storage" ]] || {
  echo 'Set WAREHOUSE_STATE_DIR to the installed operator state.' >&2; exit 1;
}
[[ "$backup" != "$state/data"/* ]] || { echo 'Refusing: the backup must not live inside the state data directory that is being replaced.' >&2; exit 1; }
operator_lock "$state"

# 1. Nothing may hold the data directories: the operator stops the project first.
compose config --quiet
if [[ -n "$(compose --profile '*' ps -q)" ]]; then
  echo 'Refusing: operator services are running. Run bash stop.sh first, then retry the restore.' >&2
  exit 1
fi

# 2. Only v4 backups carry owners, the _supabase database and the object catalog.
format="$(sed -n 's/^format=//p' "$backup/metadata.txt" 2>/dev/null || true)"
if [[ "$format" != warehouse-backup-v4 ]]; then
  echo "Refusing: in-place restore requires format=warehouse-backup-v4; this backup is '${format:-unknown}'. Older backups remain checkable with db:verify-restore." >&2
  exit 1
fi
for file in database.dump _supabase.dump storage.tar.gz storage_objects.txt integrity.txt metadata.txt compose.env instance.json roles.txt SHA256SUMS; do
  [[ -f "$backup/$file" && ! -L "$backup/$file" ]] || { echo "Incomplete backup: missing $file" >&2; exit 1; }
done
if ! cmp -s "$backup/instance.json" "$state/public/instance.json"; then
  echo 'Refusing: the backup instance.json differs from this state; in-place restore only replaces the instance that produced the backup.' >&2
  exit 1
fi
if [[ "$restore_config" == true ]]; then
  for key in WAREHOUSE_PROJECT_NAME WAREHOUSE_DB_PATH WAREHOUSE_STORAGE_PATH WAREHOUSE_MANIFEST_PATH; do
    if [[ "$(sed -n "s/^$key=//p" "$backup/compose.env")" != "$(sed -n "s/^$key=//p" "$state/config/compose.env")" ]]; then
      echo "Refusing: $key in the backup configuration differs from this state; --restore-config only restores the same instance at the same path." >&2
      exit 1
    fi
  done
elif ! cmp -s "$backup/compose.env" "$state/config/compose.env"; then
  echo 'Refusing: config/compose.env differs from the backup copy (keys rotated or configuration changed after it was taken). Pass --restore-config to restore the backup configuration together with its data, or use a backup taken after the change.' >&2
  exit 1
fi

# 3. The disposable restore proves checksums, archive safety, replay and integrity
#    before anything here is touched.
bash "$ROOT/scripts/verify-restore.sh" "$backup"

ts="$(date -u +%Y%m%dT%H%M%SZ)"
old_db="$state/data/db.pre-restore-$ts"
old_storage="$state/data/storage.pre-restore-$ts"
old_config="$state/config/compose.env.pre-restore-$ts"
for path in "$old_db" "$old_storage" "$old_config"; do
  [[ ! -e "$path" && ! -L "$path" ]] || { echo "Refusing: pre-restore path already exists: $path" >&2; exit 1; }
done
scratch="$(mktemp -d "${TMPDIR:-/tmp}/warehouse-inplace-restore.XXXXXX")"
phase='prepare'
finish() {
  status=$?
  trap - EXIT
  rm -rf "$scratch"
  if ((status != 0)) && [[ "$phase" != done ]]; then
    cat >&2 <<MSG
Restore failed during: $phase
The replaced data was kept for rollback:
  $old_db
  $old_storage
MSG
    if [[ "$restore_config" == true ]]; then echo "  $old_config" >&2; fi
    cat >&2 <<MSG
Rollback: bash stop.sh
  rm -rf "$state/data/db" "$state/data/storage"   # may need sudo: files are owned by the container's postgres user
  mv "$old_db" "$state/data/db" && mv "$old_storage" "$state/data/storage"
MSG
    if [[ "$restore_config" == true ]]; then echo "  mv \"$old_config\" \"$state/config/compose.env\"" >&2; fi
    echo '  bash start.sh' >&2
  fi
  exit "$status"
}
trap finish EXIT

echo "Restoring $backup into $state (format $format, created $(sed -n 's/^created_at_utc=//p' "$backup/metadata.txt"))."
phase='move current data aside'
mv "$state/data/db" "$old_db"
mv "$state/data/storage" "$old_storage"
mkdir -m 700 "$state/data/db" "$state/data/storage"
phase='extract storage'
# Archive safety (no absolute paths, no .., no links) was proven by verify-restore.sh.
# -p keeps the archived modes so the storage container reads the files exactly as before.
tar --no-same-owner -p -xzf "$backup/storage.tar.gz" -C "$state/data/storage"
if [[ "$restore_config" == true ]]; then
  phase='restore configuration'
  cp "$state/config/compose.env" "$old_config"
  chmod 600 "$old_config"
  cp "$backup/compose.env" "$state/config/compose.env.restoring"
  chmod 600 "$state/config/compose.env.restoring"
  mv "$state/config/compose.env.restoring" "$state/config/compose.env"
  compose config --quiet
fi

# 4. Fresh cluster initialization from the pinned image, then logical replay with
#    the original owners. Role passwords come from compose.env through the init
#    scripts; the backup never contains them.
phase='initialize database'
compose up -d --wait --wait-timeout 180 db
db_psql() { compose exec -T db psql -X -q -v ON_ERROR_STOP=1 -U supabase_admin "$@"; }
db_restore() { compose exec -T db pg_restore -U supabase_admin --exit-on-error "$@"; }
compose cp "$backup/database.dump" db:/tmp/database.dump
compose cp "$backup/_supabase.dump" db:/tmp/_supabase.dump
phase='create missing roles'
# Roles that a service creates at runtime (for example the Realtime admin role)
# must exist before ownership and ACLs replay. Names arrive as COPY data, never
# as interpolated SQL.
{
  printf 'CREATE TEMP TABLE restore_roles (role_name name NOT NULL);\n'
  printf 'COPY restore_roles(role_name) FROM stdin;\n'
  grep -v '^$' "$backup/roles.txt" || true
  printf '\\.\n'
  cat <<'SQL'
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
} | db_psql -d postgres
phase='recreate application database'
# A clean restore into the freshly initialised database collides with the
# image's event triggers (their functions cannot be dropped while the triggers
# exist), so the application database is recreated from template1, the same
# template verify-restore.sh restores into. Every non-extension object of the
# application database, including CREATE EXTENSION statements and the event
# triggers, is in the dump; per-database settings are not, which is why
# docker/volumes/db/jwt.sql is replayed below.
db_psql -d _supabase -c 'DROP DATABASE postgres WITH (FORCE)' \
  -c 'CREATE DATABASE postgres OWNER postgres TEMPLATE template1'
phase='restore database'
# Sections replay with the archived owners, as the storage service's own
# migrations require. Event triggers are the exception: PostgreSQL only lets a
# superuser own them and the archived owner (postgres) is not one in this image,
# so they are replayed last, owned by the restoring superuser. ACLs are replayed
# after the pg_graphql wrapper exists, exactly as verify-restore.sh does.
compose exec -T db sh -c "pg_restore -l /tmp/database.dump > /tmp/full.list && grep -v ' EVENT TRIGGER ' /tmp/full.list > /tmp/main.list && { grep ' EVENT TRIGGER ' /tmp/full.list > /tmp/triggers.list || :; }"
for section in pre-data data post-data; do
  db_restore -d postgres --no-acl --section="$section" -L /tmp/main.list /tmp/database.dump
done
if compose exec -T db sh -c 'test -s /tmp/triggers.list'; then
  db_restore -d postgres --no-owner --no-acl -L /tmp/triggers.list /tmp/database.dump
fi
db_psql -d postgres <<'SQL'
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
compose exec -T db sh -c "pg_restore -l /tmp/database.dump | awk '/^[0-9]+; .* ACL / { print }' > /tmp/acl.list"
db_restore -d postgres -L /tmp/acl.list /tmp/database.dump
phase='restore _supabase'
# Same approach for the analytics/pooler database: recreate, then replay.
db_psql -d postgres -c 'DROP DATABASE _supabase WITH (FORCE)' \
  -c 'CREATE DATABASE _supabase OWNER postgres TEMPLATE template1'
db_restore -d _supabase /tmp/_supabase.dump
phase='database settings'
# ALTER DATABASE settings are not part of a logical dump; the init script reads
# JWT_SECRET and JWT_EXP from the container environment, which compose.env defines.
db_psql -d postgres < "$ROOT/docker/volumes/db/jwt.sql"
compose exec -T db rm -f /tmp/database.dump /tmp/_supabase.dump /tmp/acl.list /tmp/full.list /tmp/main.list /tmp/triggers.list

# 5. The restored database must report exactly what the backup recorded.
phase='integrity comparison'
db_psql -d postgres < "$ROOT/scripts/backup-integrity.sql" > "$scratch/integrity.txt"
diff -u "$backup/integrity.txt" "$scratch/integrity.txt"

# 6. Apply migrations this checkout added after the backup (a no-op otherwise),
#    start everything and run the local doctor.
phase='migrations'
bash "$ROOT/scripts/migrate.sh" --operator
phase='start services'
compose up -d --wait --wait-timeout 180
phase='doctor'
node "$ROOT/scripts/doctor.mjs" --local
phase=done
cat <<MSG
In-place restore completed from $backup.
The replaced data was kept; remove it once the restored instance is accepted:
  $old_db
  $old_storage
MSG
if [[ "$restore_config" == true ]]; then echo "  $old_config"; fi
cat <<MSG
Rollback if needed: bash stop.sh, remove data/db and data/storage (sudo may be
required because PostgreSQL files belong to the container's postgres user), move
the kept directories back to data/db and data/storage, then bash start.sh.
MSG
