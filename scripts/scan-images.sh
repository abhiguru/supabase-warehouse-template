#!/usr/bin/env bash
set -euo pipefail
umask 077
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
compose() { bash "$ROOT/scripts/compose.sh" "$@"; }
command -v trivy >/dev/null || { echo 'Trivy is required for container image scanning.' >&2; exit 1; }

report_dir="${WAREHOUSE_SCAN_REPORT_DIR:-${TMPDIR:-/tmp}/warehouse-image-scan}"
mkdir -p "$report_dir"
report_dir=$(mktemp -d "$report_dir/run.XXXXXX")
echo 'Building locally defined Compose images before scanning all profiles.'
compose --profile '*' build
images=$(compose --profile '*' config --images | sort -u)
[[ -n "$images" ]] || { echo "No Compose images found; scan refused." >&2; exit 1; }
failed=0
while IFS= read -r image; do
  [[ -n "$image" ]] || continue
  report="$report_dir/$(printf '%s' "$image" | tr '/:@' '___').json"
  echo "Scanning $image"
  if ! trivy image --quiet --scanners vuln --severity HIGH,CRITICAL --ignore-unfixed \
    --exit-code 1 --format json --output "$report" "$image"; then
    if [[ -s "$report" ]]; then
      echo "Fixed HIGH/CRITICAL vulnerability remains in $image (report: $report)" >&2
    else
      echo "Image scan failed for $image; no report was produced." >&2
    fi
    failed=1
  fi
done <<< "$images"
[[ "$failed" == 0 ]] || exit 1
echo "Container image scan passed; machine-readable reports: $report_dir"
