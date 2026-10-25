#!/usr/bin/env bash
# Set the content type and cache control of every stored file again from the catalog (npm run storage:retag).
#
# The Storage service keeps them in the extended attributes user.supabase.content-type and user.supabase.cache-control of each
# file and serves application/octet-stream and no-cache for a file without them. A restore from a v5 backup brings back the
# files without attributes, and so did every restore before backups kept them: an installation that moved to PostgreSQL 18
# through the in-place restore has files in that state, and so has a restore from a USB copy made before the USB archive kept
# attributes. Backups of format v6 keep the attributes; this is then a no-op. Safe to run at any time, as often as you like: a
# file that already carries the catalog's values is not touched. It reads the catalog and changes only those two attributes; no
# file content, no database row.
#
#   WAREHOUSE_STATE_DIR=STATE npm run storage:retag
#   WAREHOUSE_STATE_DIR=STATE npm run storage:retag -- --if-missing
#
# --if-missing (scripts/restore.sh runs it after every restore, v5 or v6): first look at up to 20 catalogued files, spread over the
# whole list; set the attributes of every file only when any of them has no content type, else say so and stop.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
compose() { bash "$ROOT/scripts/compose.sh" "$@"; }
. "$ROOT/scripts/operator-lock.sh"
state="$(operator_state)"
# scripts/restore.sh runs this under its own lock; run alone, it takes the lock.
operator_lock_or_inherited "$state"
if_missing=false
case "${1:-}" in
  '') ;;
  --if-missing) if_missing=true ;;
  *) echo 'Usage: npm run storage:retag [-- --if-missing]' >&2; exit 1 ;;
esac
# One JSON object per object, on one line: names may hold any character, JSON escapes them. The script runs inside the
# storage container because only there the files are reachable as the Storage service sees them, as root, with fs-xattr.
catalog() {
  compose exec -T db psql -X -qAt -v ON_ERROR_STOP=1 -U supabase_admin -d postgres \
    -c "SELECT jsonb_build_object('path', bucket_id || '/' || name || COALESCE('/' || version, ''), 'mimetype', metadata->>'mimetype', 'cacheControl', metadata->>'cacheControl')::text FROM storage.objects ORDER BY bucket_id, name, version"
}
if [[ "$if_missing" == true ]]; then
  rc=0
  catalog | compose exec -T storage node -e "$(cat "$ROOT/scripts/retag-storage-metadata.cjs")" probe || rc=$?
  if ((rc == 0)); then
    echo 'The stored files carry their content types; nothing to set.'
    exit 0
  elif ((rc != 10)); then
    exit "$rc"
  fi
  echo 'Some stored files have no content type (a restore from a backup that did not keep them): setting them for every file.'
fi
catalog | compose exec -T storage node -e "$(cat "$ROOT/scripts/retag-storage-metadata.cjs")" all
