#!/usr/bin/env bash
set -euo pipefail
umask 077
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
compose() { bash "$ROOT/scripts/compose.sh" "$@"; }
command -v node >/dev/null || { echo 'Node.js is required to validate scan evidence.' >&2; exit 1; }
command -v trivy >/dev/null || { echo 'Trivy is required for container image scanning.' >&2; exit 1; }
ledger="$ROOT/docker/image-exceptions.json"
[[ -f "$ledger" ]] || { echo "Exception ledger $ledger is missing; scan refused." >&2; exit 1; }

report_dir="${WAREHOUSE_SCAN_REPORT_DIR:-${TMPDIR:-/tmp}/warehouse-image-scan}"
mkdir -p "$report_dir"
report_dir=$(mktemp -d "$report_dir/run.XXXXXX")
# Operating-system packages come from live repositories: a cached layer keeps
# the packages of the day it was built, so the scan builds every image afresh.
echo 'Building locally defined Compose images without the build cache before scanning all profiles.'
compose --profile '*' build --no-cache
config=$(compose --profile '*' config --format json)
# One line per service: the image to scan and its recipe (the Dockerfile of a
# built image, relative to the checkout, or the pinned reference of a pulled
# one), which is what docker/image-exceptions.json entries name.
images=$(printf '%s' "$config" | node --input-type=module -e '
  import { relative, resolve } from "node:path";
  let text = "";
  for await (const chunk of process.stdin) text += chunk;
  const config = JSON.parse(text);
  for (const [service, definition] of Object.entries(config.services ?? {})) {
    const image = definition.image ?? `${config.name}-${service}`;
    const recipe = definition.build
      ? relative(process.argv[1], resolve(definition.build.context, definition.build.dockerfile ?? "Dockerfile"))
      : definition.image;
    if (!image || !recipe || /\s/.test(image + recipe)) throw new Error(`cannot name the image or recipe of ${service}`);
    console.log(`${image}\t${recipe}`);
  }
' "$ROOT" | sort -u)
[[ -n "$images" ]] || { echo "No Compose images found; scan refused." >&2; exit 1; }
failed=0
while IFS=$'\t' read -r image recipe; do
  [[ -n "$image" ]] || continue
  base="$report_dir/$(printf '%s' "$image" | tr '/:@' '___')"
  # Pass "fixed" (--ignore-unfixed): rows with a listed fix; only an advisory
  # exception covers one. Pass "all": every row, the ones with no fix included.
  for pass in fixed all; do
    unfixed=(--ignore-unfixed)
    [[ "$pass" == all ]] && unfixed=()
    report="$base.$pass.json"
    echo "Scanning $image ($pass)"
    if ! trivy image --quiet --scanners vuln --severity HIGH,CRITICAL "${unfixed[@]}" --list-all-pkgs \
      --exit-code 0 --format json --output "$report" "$image"; then
      echo "Image scan failed for $image ($pass); no usable report was produced." >&2
      failed=1
    fi
    if ! node "$ROOT/scripts/validate-image-report.mjs" "$report" "$image" --exceptions "$ledger" --recipe "$recipe"; then
      failed=1
    fi
  done
done <<< "$images"
[[ "$failed" == 0 ]] || exit 1
echo "Container image scan passed; machine-readable reports: $report_dir"
