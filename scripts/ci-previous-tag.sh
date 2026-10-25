#!/usr/bin/env bash
# CI helper for the upgrade drill (the operator-upgrade job in .github/workflows/ci.yml): chooses the release the drill installs
# before it moves to the commit under test with `upgrade.sh --ref`.
#
#   bash scripts/ci-previous-tag.sh        run in a full clone (fetch-depth 0, tags fetched); prints lines for $GITHUB_OUTPUT:
#     skip=false                           and
#     tag=v0.7.0                           the newest stable release tag (else the newest tag) reachable from the merge base of
#                                          HEAD and origin/main (for a push to main, from HEAD), newest by version number
#   or
#     skip=true
#     reason=...                           why there is nothing to drill (one line; it is also printed on stderr)
#
# It skips, never fails, when: there is no release tag; HEAD is the tag; the tag cannot take part in an upgrade.sh move
# (its scripts/operator-lock.sh has no operator_lock_or_inherited, or scripts/backup.sh or scripts/verify-restore.sh are
# missing); or the tag runs another PostgreSQL major than HEAD (that is the separate "Major PostgreSQL upgrade" procedure,
# which upgrade.sh refuses; tests/upgrade.test.mjs covers the refusal). Until a release after the PostgreSQL 18 move exists
# the drill is therefore skipped, with the notice.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
skip() { printf 'skip=true\nreason=%s\n' "$1"; printf 'Upgrade drill skipped: %s\n' "$1" >&2; exit 0; }

head="$(git rev-parse HEAD)"
base="$(git merge-base HEAD origin/main 2>/dev/null || printf '%s' "$head")"
tags="$(git tag --merged "$base" --list 'v[0-9]*' --sort=-v:refname | LC_ALL=C grep -E '^v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?$' || true)"
[[ -n "$tags" ]] || skip 'no release tag (v*) is reachable from the merge base with main'
tag="$(LC_ALL=C grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' <<< "$tags" | head -n 1 || true)"
[[ -n "$tag" ]] || tag="$(head -n 1 <<< "$tags")"
[[ "$(git rev-parse "$tag^{commit}")" != "$head" ]] || skip "HEAD is the release $tag itself"

for path in scripts/backup.sh scripts/verify-restore.sh; do
  git cat-file -e "$tag:$path" 2>/dev/null || skip "$tag has no $path"
done
git show "$tag:scripts/operator-lock.sh" 2>/dev/null | grep -q '^operator_lock_or_inherited()' || skip "$tag predates the inherited operator lock that upgrade.sh relies on"

before="$(bash scripts/pg-major.sh "$tag" 2>/dev/null)" || skip "the PostgreSQL major of $tag cannot be read (it predates scripts/db-image.sh)"
now="$(bash scripts/pg-major.sh)"
[[ "$before" == "$now" ]] || skip "$tag runs PostgreSQL $before and this commit runs PostgreSQL $now: a new major is the separate 'Major PostgreSQL upgrade' procedure, not an upgrade.sh move"

printf 'skip=false\ntag=%s\n' "$tag"
