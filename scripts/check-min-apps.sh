#!/usr/bin/env bash
# The oldest supported app builds (CONTRIBUTING.md, "Mobile companion pin"): MOBILE_MIN_REF in .github/workflows/ci.yml is a space-separated
# list of app commits, every build handed out with the version app-compat.json names as minimumClientVersion. For each commit this checks
# the app out into its own directory, installs its dependencies without running install scripts (the scanner needs only TypeScript), runs
# the contract scanner and scripts/check-app-compat.mjs, and, with --callers-test, tests/rpc-callers.test.mjs. Every commit is judged even
# when an earlier one fails. Used by the contract job of ci.yml and by release.yml, so both read the same pin.
#
#   bash scripts/check-min-apps.sh WORKDIR [--callers-test] [-- ARGS FOR check-app-compat.mjs]
#
# APP_REPO overrides the app repository URL (the tests and local runs use a path).
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
work="${1:-}"
[[ -n "$work" ]] || { echo "Usage: bash scripts/check-min-apps.sh WORKDIR [--callers-test] [-- ARGS FOR check-app-compat.mjs]" >&2; exit 2; }
shift
callers=false
if [[ "${1:-}" == --callers-test ]]; then callers=true; shift; fi
if [[ "${1:-}" == -- ]]; then shift; fi
workflow="${MIN_REF_WORKFLOW:-.github/workflows/ci.yml}"
line="$(sed -n 's/^  MOBILE_MIN_REF: //p' "$workflow")"
[[ "$(sed -n '/^  MOBILE_MIN_REF:/p' "$workflow" | wc -l)" -eq 1 ]] || { echo "::error title=MOBILE_MIN_REF::$workflow must declare MOBILE_MIN_REF exactly once."; exit 1; }
read -r -a refs <<< "$line"
[[ "${#refs[@]}" -ge 1 ]] || { echo "::error title=MOBILE_MIN_REF::MOBILE_MIN_REF lists no commit."; exit 1; }
for ref in "${refs[@]}"; do
  [[ "$ref" =~ ^[0-9a-f]{40}$ ]] || { echo "::error title=MOBILE_MIN_REF::MOBILE_MIN_REF must list full 40-digit commit SHAs separated by spaces; found '$ref'."; exit 1; }
done
if [[ "$(printf '%s\n' "${refs[@]}" | sort -u | wc -l)" -ne "${#refs[@]}" ]]; then echo "::error title=MOBILE_MIN_REF::MOBILE_MIN_REF lists a commit twice."; exit 1; fi

mkdir -p "$work"
git clone --quiet "${APP_REPO:-https://github.com/abhiguru/rn-warehouse-template.git}" "$work/app"
status=0
index=0
for ref in "${refs[@]}"; do
  index=$((index + 1))
  dir="$work/min-$index"
  echo "== Oldest supported app build $index of ${#refs[@]}: $ref"
  git -C "$work/app" worktree add --quiet --detach "$dir" "$ref"
  (cd "$dir" && npm ci --ignore-scripts --no-audit --no-fund --loglevel=error)
  node scripts/check-mobile-contract.mjs "$dir" --output "$work/min-report-$index.json" || status=1
  if [[ "$callers" == true ]]; then
    MOBILE_MIN_CHECKOUT="$dir" node --test tests/rpc-callers.test.mjs || status=1
  fi
  node scripts/check-app-compat.mjs --report "$work/min-report-$index.json" --app-json "$dir/app.json" "$@" || status=1
done
exit "$status"
