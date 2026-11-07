#!/usr/bin/env bash
# Read-only check that every catalogued photo and document file is really on disk (WH-55). It writes nothing to the database
# or to the storage; it only reads names (no hashing).
#   npm run storage:check                          (an installed instance: WAREHOUSE_STATE_DIR names its state)
#   bash scripts/storage-file-check.sh --catalog CATALOG.tsv --files FILES.txt     (offline: needs no database and no Docker)
# Compares storage.objects with the files under data/storage in both directions and prints, per bucket, the rows, the files, the
# rows with no file and the files with no row; each row with no file is listed with the GRN or dispatch that points at it.
# Exit 0: all files present (files with no row are listed but are not a failure, as in scripts/verify-restore.sh).
# Exit 1: at least one row has no file. Exit 2: the catalog or the files could not be read (never reported as clean).
# The object-to-path rule is the one of scripts/verify-restore.sh and scripts/backup.sh: <bucket_id>/<name>/<version>, matched as a
# path suffix of a file (Storage keeps files under a tenant prefix).
# Offline inputs (for a copy, or for an older install such as the old Windows box, with nothing installed there):
#   CATALOG.tsv  the output of the query printed by `bash scripts/storage-file-check.sh --print-query`, run with psql -A -t -F "<TAB>"
#   FILES.txt    the paths of the files under the storage directory, relative to it: (cd STORAGE_DIR && find . -type f | sed 's|^\./||')
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Same projection as verify-restore.sh (catalog_query), then a tab and the app rows that use the object.
catalog_query="SELECT o.bucket_id||'/'||o.name||COALESCE('/'||o.version,'') || E'\\t'
  || COALESCE((SELECT string_agg('GRN '||g.gr_no||CASE WHEN i.status = 'pending' THEN ' (pending upload)' ELSE '' END, '; ') FROM public.grn_images i JOIN public.goodsreceived g ON g.id = i.grn_id WHERE o.bucket_id = 'grn-images' AND i.storage_path = o.name), '')
  || COALESCE((SELECT string_agg('Dispatch '||d.disp_no||CASE WHEN i.status = 'pending' THEN ' (pending upload)' ELSE '' END, '; ') FROM public.dispatch_images i JOIN public.dispatch d ON d.id = i.dispatch_id WHERE o.bucket_id = 'dispatch-images' AND i.storage_path = o.name), '')
  FROM storage.objects o ORDER BY 1 COLLATE \"C\""

usage() { echo 'Usage: npm run storage:check   |   bash scripts/storage-file-check.sh --catalog CATALOG.tsv --files FILES.txt   |   --print-query' >&2; exit 2; }
catalog=''; files=''
while (($#)); do
  case "$1" in
    --catalog) (($# >= 2)) || usage; catalog="$2"; shift ;;
    --files) (($# >= 2)) || usage; files="$2"; shift ;;
    --print-query) printf '%s\n' "$catalog_query"; exit 0 ;;
    *) usage ;;
  esac
  shift
done
fail() { echo "Storage file check FAILED to read: $*. This is not a clean result." >&2; exit 2; }

scratch="$(mktemp -d "${TMPDIR:-/tmp}/storage-file-check.XXXXXX")"
trap 'rm -rf -- "$scratch"' EXIT
started="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

if [[ -n "$catalog" || -n "$files" ]]; then
  [[ -n "$catalog" && -n "$files" ]] || usage
  [[ -r "$catalog" && -r "$files" ]] || fail "$catalog or $files is not readable"
  cp -- "$catalog" "$scratch/catalog.tsv"; cp -- "$files" "$scratch/files.txt"
else
  state="${WAREHOUSE_STATE_DIR:-}"
  [[ "$state" == /* && -d "$state/data/storage" ]] || fail 'WAREHOUSE_STATE_DIR does not name an installed state with data/storage'
  compose() { bash "$ROOT/scripts/compose.sh" "$@"; }
  compose exec -T db psql -X -A -t -F $'\t' -v ON_ERROR_STOP=1 -U supabase_admin -d postgres -c "$catalog_query" > "$scratch/catalog.tsv" \
    || fail 'the database query'
  (cd "$state/data/storage" && find . -type f | sed 's|^\./||' | LC_ALL=C sort) > "$scratch/files.txt" || fail 'the file listing'
fi
# A reply that is not rows (an error text, a stray banner) must not read as an empty catalog.
if [[ -s "$scratch/catalog.tsv" ]] && ! LC_ALL=C awk -F'\t' 'NF != 2 || index($1, "/") == 0 { bad = 1 } END { exit bad }' "$scratch/catalog.tsv"; then
  fail 'the catalog has lines that are not "<bucket>/<name>[/<version>]<TAB><app rows>"'
fi

# Suffix matching as in verify-restore.sh. Output lines: ROW|bucket|object|refs, EXTRA|bucket|path, COUNT|bucket|rows|files|missing|extra.
LC_ALL=C awk -F'\t' -v out="$scratch/result.txt" '
  FILENAME == ARGV[1] { if (length($1)) { want[$1] = 1; refs[$1] = $2; split($1, b, "/"); bucket[$1] = b[1]; rows[b[1]]++; buckets[b[1]] = 1 } next }
  {
    n = split($0, parts, "/"); suffix = ""; hit = 0
    for (i = n; i >= 1; i--) {
      suffix = (i == n) ? parts[i] : parts[i] "/" suffix
      if (suffix in want) { found[suffix] = 1; hit = 1; fb = bucket[suffix]; break }
    }
    if (hit) { nfiles[fb]++ }
    else { eb = (n >= 3) ? parts[2] : "(unknown)"; nfiles[eb]++; nextra[eb]++; buckets[eb] = 1; print "EXTRA|" eb "|" $0 > out }
  }
  END {
    for (e in want) if (!(e in found)) { m[bucket[e]]++; print "ROW|" bucket[e] "|" e "|" (refs[e] == "" ? "nothing" : refs[e]) > out }
    for (k in buckets) print "COUNT|" k "|" rows[k] + 0 "|" nfiles[k] + 0 "|" m[k] + 0 "|" nextra[k] + 0 > out
    close(out)
  }
' "$scratch/catalog.tsv" "$scratch/files.txt" || fail 'the comparison'
touch "$scratch/result.txt"

echo "Storage file check (read-only), run at $started"
printf '%-20s %8s %8s %12s %12s\n' bucket rows files 'rows-no-file' 'files-no-row'
grep '^COUNT|' "$scratch/result.txt" | LC_ALL=C sort | awk -F'|' '{ printf "%-20s %8d %8d %12d %12d\n", $2, $3, $4, $5, $6 }' || true
if grep -q '^ROW|' "$scratch/result.txt"; then
  echo; echo 'Rows with no file (bucket, object, used by):'
  grep '^ROW|' "$scratch/result.txt" | LC_ALL=C sort | awk -F'|' '{ printf "  %s  %s  used by: %s\n", $2, $3, $4 }'
fi
if grep -q '^EXTRA|' "$scratch/result.txt"; then
  echo; echo "Files with no row (not a failure; first 20 shown of $(grep -c '^EXTRA|' "$scratch/result.txt")):"
  grep '^EXTRA|' "$scratch/result.txt" | LC_ALL=C sort | head -n 20 | awk -F'|' '{ printf "  %s  %s\n", $2, $3 }'
fi
total="$(grep -c '^ROW|' "$scratch/result.txt" || true)"
used="$({ grep '^ROW|' "$scratch/result.txt" || true; } | awk -F'|' '$4 ~ /(GRN|Dispatch) / { c++ } END { print c + 0 }')"
echo
if ((total == 0)); then echo 'All files present'; exit 0; fi
echo "$total rows have no file; $used of them are used by a GRN or dispatch"
exit 1
