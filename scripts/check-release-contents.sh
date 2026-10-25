#!/usr/bin/env bash
# The second half of the release gate (release.yml runs it after scripts/check-release.sh, which checks the tag's name): what a
# release must contain so that operators can move to it with `bash upgrade.sh vX.Y.Z` (docs/RELEASE_CHECKLIST.md, "Changelog before
# the tag"). It reads the checkout it lives in; GITHUB_REF_NAME (or the first argument) is the tag.
#   - CHANGELOG.md has the section `## vX.Y.Z (date)`; a pre-release tag (vX.Y.Z-rc.1) may use its release's section `## vX.Y.Z`,
#     which is what upgrade.sh prints for it
#   - upgrade.sh and scripts/pg-major.sh exist (upgrade.sh refuses a release without upgrade.sh)
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
grep -q 'operator_lock_or_inherited' "$ROOT/setup.sh" 2>/dev/null || fail 'setup.sh does not call operator_lock_or_inherited: upgrade.sh holds the operator lock while it runs setup.sh.'
grep -Eq '^bash "\$ROOT/scripts/compose\.sh" up -d --force-recreate --no-deps .*functions$' "$ROOT/setup.sh" 2>/dev/null || fail 'setup.sh does not recreate the functions container (up -d --force-recreate --no-deps ... functions): new SQL would run under old function code.'
((failed == 0)) || exit 1
echo "Release contents: $tag has its CHANGELOG section, upgrade.sh, scripts/pg-major.sh, the inherited operator lock and the functions recreate in setup.sh."
