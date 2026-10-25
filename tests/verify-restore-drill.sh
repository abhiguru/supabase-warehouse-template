#!/usr/bin/env bash
# Restore drill on real containers, run by tests/migrations.sh against its disposable
# database: dump that database into a signed warehouse-backup-v5 fixture and let
# scripts/verify-restore.sh replay it twice.
#   1. While another session is attached to template1 in the verifier's container
#      (the CI failure of 2026-10-09: "source database template1 is being accessed
#      by other users"), with the data directory in memory.
#   2. With the disk-backed data directory, which must be gone afterwards.
#   2b. With the _supabase.dump that backups from before the pooler became optional also hold:
#      verified, with a note that it is skipped.
#   2c. The same dump as a warehouse-backup-v6 fixture (the storage as a storage/ tree with a signed storage.manifest, which
#      scripts/backup.sh writes): verified, and refused when one file of the tree is not the one the manifest names.
#   3. With an integrity report that claims one more price-history row than the
#      dump holds: the verification must fail on exactly that line. Before, the
#      three append-only histories were in no comparison, so a restore that lost
#      them passed.
# Before the replays: the integrity report of this database counts the histories
# and the closed invoice columns, and the same file run on a ledger without the
# baseline prints only the lines an earlier backup recorded.
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
# One row in each append-only history, so that the comparison has something to lose.
sql -d postgres <<'SQL'
INSERT INTO public.invoice_discount_history(invoice_id,inv_fin_year,inv_no,old_discount,new_discount,reason,changed_by_name,changed_by_role)
 VALUES (gen_random_uuid(),2026,90011,0,5,'Restore drill','Restore Drill Author','staff');
INSERT INTO public.invoice_zero_charge_history(invoice_id,inv_fin_year,inv_no,old_lines,new_lines,new_reason,changed_by_name,changed_by_role)
 VALUES (gen_random_uuid(),2026,90011,'{}','{}','Restore drill','Restore Drill Author','staff');
INSERT INTO public.item_price_history(price_id,item_name,action,new_values,changed_by_name,changed_by_role)
 VALUES (gen_random_uuid(),'Restore Drill Item','insert','{"unit_price":5}','Restore Drill Author','staff');
SQL
dump -d postgres > "$backup/database.dump"
sql -d postgres < "$ROOT/scripts/backup-integrity.sql" > "$backup/integrity.txt"
for line in '^invoice_discount_history_count=[1-9][0-9]*$' '^invoice_zero_charge_history_count=[1-9][0-9]*$' '^item_price_history_count=[1-9][0-9]*$' \
  '^acl_authenticated_invoice_internal_columns=0$' '^acl_authenticated_invoice_total_select=true$'; do
  grep -Eq "$line" "$backup/integrity.txt" || { echo "Restore drill: the integrity report has no line $line:" >&2; cat "$backup/integrity.txt" >&2; exit 1; }
done
# A backup taken before migration 48 recorded none of those lines, and restore.sh
# compares before it applies newer migrations. The baseline migration stands for all of
# migrations 0 to 110, so with its row renamed to an earlier marker (in a transaction that is rolled
# back), and no row for 48, the report must be the earlier one, line for line by name.
earlier="$( { printf "BEGIN;\nUPDATE warehouse_migrations.applied SET name='00000000000047_earlier_marker.sql' WHERE name='00000000000000_baseline.sql';\n"; cat "$ROOT/scripts/backup-integrity.sql"; printf '\nROLLBACK;\n'; } | sql -d postgres | sed 's/=.*//' | tr '\n' ' ')"
expected='migration_count migration_fingerprint public_table_count public_function_count customer_count user_profile_count grn_count dispatch_count invoice_count order_count storage_object_count acl_anon_feature_flags_select acl_anon_orders_select acl_authenticated_orders_select acl_service_operator_prepare acl_anon_operator_prepare acl_anon_legacy_send_otp acl_authenticated_enrollment_review '
[[ "$earlier" == "$expected" ]] || { echo "Restore drill: on a ledger without the baseline and migration 48 the integrity report is not the earlier one: $earlier" >&2; exit 1; }
# TW-BE-011: the payment, order line and order revision counts belong to a release with
# migration 95 or later. A database without one prints none of them; with the
# baseline row renamed to 48 and a row for 95 (in a transaction that is rolled back) it prints exactly these three, after the
# earlier lines. Neither is in the report of this database unless it already carries one.
with95="$( { printf "BEGIN;\nUPDATE warehouse_migrations.applied SET name='00000000000048_owner_decisions.sql' WHERE name='00000000000000_baseline.sql';\nINSERT INTO warehouse_migrations.applied(name,checksum) VALUES ('00000000000095_restore_drill_marker.sql','drill');\n"; cat "$ROOT/scripts/backup-integrity.sql"; printf '\nROLLBACK;\n'; } | sql -d postgres | sed -n 's/^\(payment_count\|order_item_count\|order_revision_count\)=.*/\1/p' | tr '\n' ' ')"
[[ "$with95" == 'payment_count order_item_count order_revision_count ' ]] || { echo "Restore drill: with migration 95 in the ledger the report lacks the order detail counts: $with95" >&2; exit 1; }
if ! sql -A -t -d postgres -c "SELECT 1 FROM warehouse_migrations.applied WHERE name >= '00000000000095' OR name = '00000000000000_baseline.sql' LIMIT 1" | grep -q 1; then
  ! grep -Eq '^(payment|order_item|order_revision)_count=' "$backup/integrity.txt" || { echo 'Restore drill: the order detail counts are printed without migration 95' >&2; exit 1; }
fi
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
printf 'format=warehouse-backup-v5\ncreated_at_utc=20260101T000000Z\nsource_commit=drill\ndatabase_image=%s\n' "$(bash "$ROOT/scripts/db-image.sh")" > "$backup/metadata.txt"
(cd "$backup" && sha256sum database.dump storage.tar.gz storage_objects.txt integrity.txt metadata.txt compose.env instance.json roles.txt > SHA256SUMS)
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

# 2b. An old backup also holds the pooler's _supabase database as _supabase.dump. The verifier skips it with a note, and the
#     verification still passes.
sql -d postgres -c 'CREATE DATABASE _supabase TEMPLATE template0'
dump -d _supabase > "$backup/_supabase.dump"
sql -d postgres -c 'DROP DATABASE _supabase WITH (FORCE)'
(cd "$backup" && sha256sum database.dump _supabase.dump storage.tar.gz storage_objects.txt integrity.txt metadata.txt compose.env instance.json roles.txt > SHA256SUMS)
backup_sign_dir "$backup" "$BACKUP_KEY"
legacy="$(verify WAREHOUSE_VERIFY_STORAGE=tmpfs 2>&1)" || { echo "Restore drill: a backup holding _supabase.dump was refused: $legacy" >&2; exit 1; }
grep -q 'Note: the backup contains _supabase.dump (the pooler tenant). It is skipped' <<<"$legacy" || { echo "Restore drill: no note that _supabase.dump is skipped: $legacy" >&2; exit 1; }
rm -f "$backup/_supabase.dump"
(cd "$backup" && sha256sum database.dump storage.tar.gz storage_objects.txt integrity.txt metadata.txt compose.env instance.json roles.txt > SHA256SUMS)
backup_sign_dir "$backup" "$BACKUP_KEY"
echo 'Restore drill 2b passed: a backup from before the pooler became optional verifies, and its _supabase.dump is skipped with a note.'

# 2c. The v6 form of the same backup: the object files as a tree (cp -a keeps their modes and times) and the manifest of their
#     hashes in the signed list instead of the tarball.
backup6="$work/warehouse-20260102T000000Z"
mkdir "$backup6"
cp "$backup/database.dump" "$backup/storage_objects.txt" "$backup/integrity.txt" "$backup/roles.txt" "$backup/compose.env" "$backup/instance.json" "$backup6/"
cp -a "$work/objects" "$backup6/storage"
(cd "$backup6/storage" && find . -type f -printf '%P\0' | LC_ALL=C sort -z | xargs -0 -r sha256sum --) > "$backup6/storage.manifest"
printf 'format=warehouse-backup-v6\ncreated_at_utc=20260102T000000Z\nsource_commit=drill\ndatabase_image=%s\nlink_base=none\nstorage_files=%s\nstorage_bytes=%s\nstorage_new_bytes=%s\n' \
  "$(bash "$ROOT/scripts/db-image.sh")" "$(wc -l < "$backup6/storage.manifest")" "$(find "$backup6/storage" -type f -printf '%s\n' | awk '{ b += $1 } END { print b + 0 }')" "$(find "$backup6/storage" -type f -printf '%s\n' | awk '{ b += $1 } END { print b + 0 }')" > "$backup6/metadata.txt"
(cd "$backup6" && sha256sum database.dump storage.manifest storage_objects.txt integrity.txt metadata.txt compose.env instance.json roles.txt > SHA256SUMS)
backup_sign_dir "$backup6" "$BACKUP_KEY"
verify6() {
  env -u WAREHOUSE_STATE_DIR WAREHOUSE_BACKUP_KEY_FILE="$work/backup.key" WAREHOUSE_DIAGNOSTICS_DIR="$work/diagnostics" \
    WAREHOUSE_VERIFY_SCRATCH_DIR="$work/scratch" "$@" bash "$ROOT/scripts/verify-restore.sh" "$backup6"
}
six="$(verify6 WAREHOUSE_VERIFY_STORAGE=tmpfs 2>&1)" || { echo "Restore drill: a v6 backup was refused: $six" >&2; exit 1; }
grep -q 'Backup signature, checksums, storage tree, database restore, and integrity comparison passed.' <<<"$six" || { echo "Restore drill: the v6 verification did not report the storage tree: $six" >&2; exit 1; }
if [[ -s "$backup6/storage_objects.txt" ]]; then
  victim="$(find "$backup6/storage" -type f | head -n 1)"
  printf 'another object\n' > "$victim"
  if damaged="$(verify6 WAREHOUSE_VERIFY_STORAGE=tmpfs 2>&1)"; then echo 'Restore drill: a v6 backup with a file that is not the one its manifest names was verified.' >&2; exit 1; fi
  grep -q 'does not match storage.manifest' <<<"$damaged" || { echo "Restore drill: the damaged v6 tree was refused for another reason: $damaged" >&2; exit 1; }
fi
echo 'Restore drill 2c passed: a v6 backup (storage tree and manifest) verifies, and a tree file that differs from its manifest is refused.'

# 3. A history row fewer than the backup recorded is a failed verification.
recorded="$(sed -n 's/^item_price_history_count=//p' "$backup/integrity.txt")"
sed -i "s/^item_price_history_count=.*/item_price_history_count=$((recorded + 1))/" "$backup/integrity.txt"
(cd "$backup" && sha256sum database.dump storage.tar.gz storage_objects.txt integrity.txt metadata.txt compose.env instance.json roles.txt > SHA256SUMS)
backup_sign_dir "$backup" "$BACKUP_KEY"
if lost="$(verify WAREHOUSE_VERIFY_STORAGE=tmpfs 2>&1)"; then
  echo 'Restore drill: a backup that recorded one more price-history row than its dump holds was verified.' >&2; exit 1
fi
grep -q "^-item_price_history_count=$((recorded + 1))\$" <<<"$lost" && grep -q "^+item_price_history_count=$recorded\$" <<<"$lost" || {
  echo 'Restore drill: the verification of the short history failed for another reason:' >&2; echo "$lost" >&2; exit 1;
}
echo 'Restore drill 3 passed: a restore with fewer price-history rows than the backup recorded is refused.'
