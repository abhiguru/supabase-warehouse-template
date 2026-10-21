#!/usr/bin/env bash
# Usage: data-fingerprint.sh [--all | --counts]
#   --all  also fingerprints every other table in the business schemas (public,
#          warehouse_security, warehouse_maintenance), not just the 23 fixed ones below.
#   --counts  prints only "schema.table rowcount" for every table of the business schemas and storage,
#          sorted by name in the C collation (no hashes, no stored files). Steps 2 and 8 of the major upgrade run it
#          before and after and diff the two outputs.
# Every sort uses the C collation, so the fingerprint does not depend on the database's
# collation and survives a glibc or major-version change. --all also hashes tables that change on
# their own (OTPs, rate limits, the audit log, auth_config), so use it only on a quiet system and
# compare two runs of --all with each other.
# Read-only fingerprint of a running instance's business data: a row count and a SHA-256
# of every business table's rows, the storage catalog and the stored files. Take one
# before a backup and one after restoring it elsewhere; `diff` of the two must be empty.
# The default output holds no secrets (counts and hashes only), so it may be kept with the evidence.
# The --all output hashes whole tables such as warehouse_security.auth_config, refresh_sessions,
# enrollment_tokens, sensor_ingest_keys, secrets_vault and sms_config: the values are hashes, but keep
# the --all output private.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
compose() { bash "$ROOT/scripts/compose.sh" "$@"; }
[[ -n "${WAREHOUSE_STATE_DIR:-}" ]] || { echo 'Set WAREHOUSE_STATE_DIR to the installed operator state.' >&2; exit 1; }

# Tables that change on their own (OTPs, rate limits, idempotency keys, audit log,
# materialized views, queues) are left out; everything an operator enters is in,
# and so are the three append-only histories of what was entered (discounts, zero
# charges, item prices), which must come back from a restore row for row. The orders
# and what hangs on them (lines, revisions, payments) are in as well.
tables=(customers users_customers_new items item_storage_prices goodsreceived goodsreceived_trl
  grn_images dispatch dispatch_trl dispatch_images invoice invoice_trl stock_movements user_profiles
  invoice_discount_history invoice_zero_charge_history item_price_history standard_rate_tiers grn_rates
  payments orders order_items order_revisions)
all=false
counts=false
case "${1:-}" in
  '') ;;
  --all) all=true ;;
  --counts) counts=true ;;
  *) echo 'Usage: data-fingerprint.sh [--all | --counts]' >&2; exit 2 ;;
esac
if [[ "$counts" == true ]]; then
  # The sort key is the qualified name, a text expression; a sort by column position with a collation fails on an integer.
  IFS= read -r -d '' counts_sql <<'SQL' || true
SELECT n.nspname || '.' || c.relname || ' ' || (xpath('/row/c/text()', query_to_xml(format('SELECT count(*) AS c FROM %I.%I', n.nspname, c.relname), false, true, '')))[1]::text FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE c.relkind IN ('r','p') AND n.nspname IN ('public','storage','warehouse_security','warehouse_maintenance') ORDER BY (n.nspname || '.' || c.relname) COLLATE "C"
SQL
  compose exec -T db psql -X -q -A -t -v ON_ERROR_STOP=1 -U supabase_admin -d postgres -c "$counts_sql"
  exit 0
fi
# Qualified names (schema.table) in the order of the list above; --all adds the other tables of the
# business schemas, sorted by name in the C collation. Their lines are in the same format.
names=()
for t in "${tables[@]}"; do names+=("public.$t"); done
if [[ "$all" == true ]]; then
  fixed=" ${names[*]} "
  # Captured first: set -e does not see a failure inside a process substitution.
  extra=$(compose exec -T db psql -X -q -A -t -v ON_ERROR_STOP=1 -U supabase_admin -d postgres -c \
    "SELECT format('%I.%I', n.nspname, c.relname) FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE c.relkind IN ('r', 'p') AND NOT c.relispartition AND n.nspname IN ('public', 'warehouse_security', 'warehouse_maintenance') ORDER BY format('%I.%I', n.nspname, c.relname) COLLATE \"C\"")
  while IFS= read -r q; do
    [[ -n "$q" && "$fixed" != *" $q "* ]] && names+=("$q")
  done <<< "$extra"
fi
# Pin the settings that shape the text of a row, so r::text does not depend on the session or role defaults.
sql="SET TimeZone='UTC'; SET DateStyle='ISO, MDY'; SET extra_float_digits=1; SET bytea_output='hex'; SET IntervalStyle='postgres';"$'\n'
for t in "${names[@]}"; do
  sql+="SELECT 'table $t rows=' || count(*) || ' sha256=' || encode(sha256(convert_to(coalesce(string_agg(r::text, E'\n' ORDER BY r::text COLLATE \"C\"), ''), 'UTF8')), 'hex') FROM $t r;"$'\n'
done
sql+="SELECT 'table storage.objects rows=' || count(*) || ' sha256=' || encode(sha256(convert_to(coalesce(string_agg(bucket_id || '/' || name || ' ' || coalesce(metadata->>'size', '') || ' ' || coalesce(metadata->>'eTag', ''), E'\n' ORDER BY bucket_id COLLATE \"C\", name COLLATE \"C\"), ''), 'UTF8')), 'hex') FROM storage.objects;"$'\n'
if [[ "$all" == true ]]; then
  sql+="SELECT 'table storage.buckets rows=' || count(*) || ' sha256=' || encode(sha256(convert_to(coalesce(string_agg(id || ' ' || public || ' ' || coalesce(file_size_limit::text, '') || ' ' || coalesce(allowed_mime_types::text, ''), E'\n' ORDER BY id COLLATE \"C\"), ''), 'UTF8')), 'hex') FROM storage.buckets;"$'\n'
fi
compose exec -T db psql -X -q -A -t -v ON_ERROR_STOP=1 -U supabase_admin -d postgres <<< "$sql"
# Stored files, hashed inside the storage container (the files belong to its user).
files="$(compose exec -T storage sh -c 'cd /var/lib/storage && find . -type f | LC_ALL=C sort | while IFS= read -r f; do sha256sum "$f"; done')"
printf 'storage files=%s sha256=%s\n' "$(grep -c . <<< "$files" || true)" "$(printf '%s' "$files" | sha256sum | cut -d' ' -f1)"
