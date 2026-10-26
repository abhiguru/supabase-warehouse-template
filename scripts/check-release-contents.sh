#!/usr/bin/env bash
# The second half of the release gate (release.yml runs it after scripts/check-release.sh, which checks the tag's name): what a
# release must contain so that operators can move to it with `bash upgrade.sh vX.Y.Z` (docs/RELEASE_CHECKLIST.md, "Changelog before
# the tag"). It reads the checkout it lives in; GITHUB_REF_NAME (or the first argument) is the tag.
#   - CHANGELOG.md has the section `## vX.Y.Z (date)`; a pre-release tag (vX.Y.Z-rc.1) may use its release's section `## vX.Y.Z`,
#     which is what upgrade.sh prints for it
#   - upgrade.sh and scripts/pg-major.sh exist (upgrade.sh refuses a release without upgrade.sh)
#   - scripts/upgrade-preflight.sh exists and every file on its `# needs:` line is in the release and is a path upgrade.sh will read from a
#     release (a relative path without `..`, the rule of run_target_preflight in upgrade.sh), and scripts/upgrade-floor.txt exists
#     with one `from_floor=` and one `stepping_stone=` line, each empty or a release tag: the upgrade.sh of the release an installation
#     runs now reads both out of THIS release before it changes anything, so a release without them cannot be moved to
#   - setup.sh takes the operator lock upgrade.sh holds (operator_lock_or_inherited)
#   - setup.sh recreates the functions container, because upgrade.sh no longer does it after the checkout (the release being
#     moved to decides how it is moved into)
# RELEASE_CONTENTS_ROOT points the script at another directory (tests/release.test.mjs).
set -euo pipefail
ROOT="${RELEASE_CONTENTS_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
tag="${GITHUB_REF_NAME:-${1:-}}"
[[ -n "$tag" ]] || { echo 'Release contents: give the tag (GITHUB_REF_NAME or the first argument).' >&2; exit 2; }
release="${tag%%+*}"
release="${release%%-*}"
failed=0
fail() { echo "Release contents: $*" >&2; failed=1; }
section() {
  local escaped
  escaped="$(printf '%s' "$1" | sed 's/[][\.*^$+?(){}|]/\\&/g')"
  grep -Eq "^## ${escaped}( |\$)" "$ROOT/CHANGELOG.md" 2>/dev/null
}
section "$tag" || section "$release" || fail "CHANGELOG.md has no section '## $release (YYYY-MM-DD)' for $tag: rename '## Unreleased' (docs/RELEASE_CHECKLIST.md, 'Changelog before the tag'). upgrade.sh prints the operator actions by that heading."
[[ -f "$ROOT/upgrade.sh" ]] || fail 'upgrade.sh is missing: a release without it cannot be moved to with upgrade.sh.'
[[ -f "$ROOT/scripts/pg-major.sh" ]] || fail 'scripts/pg-major.sh is missing: upgrade.sh needs it to tell a PostgreSQL major change.'
if [[ -f "$ROOT/scripts/upgrade-preflight.sh" ]]; then
  read -r -a needed <<< "$(sed -n 's/^# needs:[[:space:]]*//p' "$ROOT/scripts/upgrade-preflight.sh" | head -n 1)"
  for path in "${needed[@]+"${needed[@]}"}"; do
    # The same rule as run_target_preflight in upgrade.sh (tests/release.test.mjs compares the two patterns): a path outside it would pass
    # this gate and then stop every move to the release, because upgrade.sh refuses to extract it.
    if ! [[ "$path" =~ ^[A-Za-z0-9._][A-Za-z0-9._/-]*$ && "$path" != *..* ]]; then
      fail "scripts/upgrade-preflight.sh names '$path' on its '# needs:' line, which upgrade.sh will not read from a release (a relative path of letters, digits, . _ - and /, without '..'): upgrade.sh would stop every move to it."
      continue
    fi
    [[ -e "$ROOT/$path" ]] || fail "scripts/upgrade-preflight.sh names $path on its '# needs:' line, which this release does not contain: upgrade.sh would stop every move to it."
  done
else
  fail 'scripts/upgrade-preflight.sh is missing: upgrade.sh runs the preflight of the release it moves to, before the backup.'
fi
if [[ -f "$ROOT/scripts/upgrade-floor.txt" ]]; then
  for key in from_floor stepping_stone; do
    [[ "$(grep -c "^$key=" "$ROOT/scripts/upgrade-floor.txt" || true)" == 1 ]] || fail "scripts/upgrade-floor.txt must have exactly one '$key=' line (empty, or a release tag such as v0.7.0)."
    value="$(sed -n "s/^$key=//p" "$ROOT/scripts/upgrade-floor.txt" | head -n 1)"
    [[ -z "$value" || "$value" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?$ ]] || fail "scripts/upgrade-floor.txt: $key= holds '$value', which is not a release tag (vX.Y.Z) or empty."
  done
else
  fail 'scripts/upgrade-floor.txt is missing: the preflight reads the oldest release this one accepts an upgrade from.'
fi
grep -q 'operator_lock_or_inherited' "$ROOT/setup.sh" 2>/dev/null || fail 'setup.sh does not call operator_lock_or_inherited: upgrade.sh holds the operator lock while it runs setup.sh.'
grep -Eq '^bash "\$ROOT/scripts/compose\.sh" up -d --force-recreate --no-deps .*functions$' "$ROOT/setup.sh" 2>/dev/null || fail 'setup.sh does not recreate the functions container (up -d --force-recreate --no-deps ... functions): new SQL would run under old function code.'
((failed == 0)) || exit 1
echo "Release contents: $tag has its CHANGELOG section, upgrade.sh, scripts/pg-major.sh, scripts/upgrade-preflight.sh, scripts/upgrade-floor.txt, the inherited operator lock and the functions recreate in setup.sh."
