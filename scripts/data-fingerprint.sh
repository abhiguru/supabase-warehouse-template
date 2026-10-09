#!/usr/bin/env bash
# Read-only fingerprint of a running instance's business data: a row count and a SHA-256
# of every business table's rows, the storage catalog and the stored files. Take one
# before a backup and one after restoring it elsewhere; `diff` of the two must be empty.
# Holds no secrets (counts and hashes only), so it may be kept with the evidence.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
compose() { bash "$ROOT/scripts/compose.sh" "$@"; }
[[ -n "${WAREHOUSE_STATE_DIR:-}" ]] || { echo 'Set WAREHOUSE_STATE_DIR to the installed operator state.' >&2; exit 1; }

# Tables that change on their own (OTPs, rate limits, idempotency keys, audit log,
# materialized views, queues) are left out; everything an operator enters is in.
tables=(customers users_customers_new items item_storage_prices goodsreceived goodsreceived_trl
  grn_images dispatch dispatch_trl dispatch_images invoice invoice_trl stock_movements user_profiles)
sql=''
for t in "${tables[@]}"; do
  sql+="SELECT 'table public.$t rows=' || count(*) || ' sha256=' || encode(sha256(convert_to(coalesce(string_agg(r::text, E'\n' ORDER BY r::text), ''), 'UTF8')), 'hex') FROM public.$t r;"$'\n'
done
sql+="SELECT 'table storage.objects rows=' || count(*) || ' sha256=' || encode(sha256(convert_to(coalesce(string_agg(bucket_id || '/' || name || ' ' || coalesce(metadata->>'size', '') || ' ' || coalesce(metadata->>'eTag', ''), E'\n' ORDER BY bucket_id, name), ''), 'UTF8')), 'hex') FROM storage.objects;"$'\n'
compose exec -T db psql -X -q -A -t -v ON_ERROR_STOP=1 -U supabase_admin -d postgres <<< "$sql"
# Stored files, hashed inside the storage container (the files belong to its user).
files="$(compose exec -T storage sh -c 'cd /var/lib/storage && find . -type f | LC_ALL=C sort | while IFS= read -r f; do sha256sum "$f"; done')"
printf 'storage files=%s sha256=%s\n' "$(grep -c . <<< "$files" || true)" "$(printf '%s' "$files" | sha256sum | cut -d' ' -f1)"
