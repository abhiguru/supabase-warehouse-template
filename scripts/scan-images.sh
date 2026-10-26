#!/usr/bin/env bash
set -euo pipefail
umask 077
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
compose() { bash "$ROOT/scripts/compose.sh" "$@"; }
command -v node >/dev/null || { echo 'Node.js is required to validate scan evidence.' >&2; exit 1; }
command -v trivy >/dev/null || { echo 'Trivy is required for container image scanning.' >&2; exit 1; }
ledger="$ROOT/docker/image-exceptions.json"
[[ -f "$ledger" ]] || { echo "Exception ledger $ledger is missing; scan refused." >&2; exit 1; }

# The scan rebuilds every image of the state's project with --no-cache, so each
# gets a new image ID. On an installation that would move every tag under its
# running containers to that day's packages, which no recorded build made
# (scripts/build-images.sh) and the next start would pick up. Scan with a
# throwaway state of its own project name (docs/RELEASE_CHECKLIST.md), never an
# installation's: refuse while the project has any container, running or not.
containers=$(compose --profile '*' ps -a -q)
if [[ -n "$containers" ]]; then
  echo "Refusing: this state's project has containers. Scan with a throwaway operator state of its own project name, never with an installation's state (docs/RELEASE_CHECKLIST.md, \"Image scan before a release\")." >&2
  exit 1
fi

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
  const services = Object.entries(config.services ?? {});
  // A service that names the image another service builds (gateway-lan runs the gateway image) is that image already: it is scanned once, with the
  // recipe that builds it, not a second time with the image name standing in for a recipe.
  const built = new Set(services.filter(([, definition]) => definition.build).map(([service, definition]) => definition.image ?? `${config.name}-${service}`));
  for (const [service, definition] of services) {
    const image = definition.image ?? `${config.name}-${service}`;
    if (!definition.build && built.has(image)) continue;
    const recipe = definition.build
      ? relative(process.argv[1], resolve(definition.build.context, definition.build.dockerfile ?? "Dockerfile"))
      : definition.image;
    if (!image || !recipe || /\s/.test(image + recipe)) throw new Error(`cannot name the image or recipe of ${service}`);
    console.log(`${image}\t${recipe}`);
  }
' "$ROOT" | sort -u)
[[ -n "$images" ]] || { echo "No Compose images found; scan refused." >&2; exit 1; }
failed=0
accepted_log="$report_dir/accepted.log"
: > "$accepted_log"
while IFS=$'\t' read -r image recipe; do
  [[ -n "$image" ]] || continue
  base="$report_dir/$(printf '%s' "$image" | tr '/:@' '___')"
  # One full pass: every HIGH/CRITICAL row, the ones with no fix included. The
  # validator tells the two apart by the row itself (a row with a listed fix is
  # covered only by an advisory exception, never by a no-fix one), so an
  # --ignore-unfixed pass would add nothing.
  report="$base.json"
  echo "Scanning $image"
  if ! trivy image --quiet --scanners vuln --severity HIGH,CRITICAL --list-all-pkgs \
    --exit-code 0 --format json --output "$report" "$image"; then
    echo "Image scan failed for $image; no usable report was produced." >&2
    failed=1
  fi
  # Only the validator's acceptance line counts as a pass, never a bare exit 0.
  if verdict=$(node "$ROOT/scripts/validate-image-report.mjs" "$report" "$image" --exceptions "$ledger" --recipe "$recipe" 2>&1) &&
    [[ "$verdict" == "Image scan evidence accepted for $image: "* && "$verdict" != *$'\n'* ]]; then
    printf '%s\n' "$verdict" | tee -a "$accepted_log"
  else
    printf '%s\n' "${verdict:-Image scan evidence for $image: the validator printed no verdict.}" >&2
    failed=1
  fi
done <<< "$images"
[[ "$failed" == 0 ]] || exit 1
# An entry that covered nothing in a complete scan is stale (a fixed tag, a
# removed package): a warning, so the owner removes it or checks its recipe.
node --input-type=module -e '
  import { readFileSync } from "node:fs";
  const [ledgerPath, logPath] = process.argv.slice(1);
  const log = readFileSync(logPath, "utf8");
  for (const { id } of JSON.parse(readFileSync(ledgerPath, "utf8")).exceptions) {
    const named = log.split(/[\s,]+/).includes(id);
    if (!named) console.error(`Warning: exception ${id} of docker/image-exceptions.json covered no row in this scan; remove it or check its recipe.`);
  }
' "$ledger" "$accepted_log"
echo "Container image scan passed; machine-readable reports: $report_dir"
