#!/usr/bin/env bash
# CI helper for the upgrade drill (the operator-upgrade job in .github/workflows/ci.yml): chooses what the drill installs
# before it moves to the commit under test with `upgrade.sh --ref`.
#
#   bash scripts/ci-previous-tag.sh [BASE_BRANCH]     (default main) run in a full clone (fetch-depth 0, tags fetched); prints
#                                                     lines for $GITHUB_OUTPUT:
#     skip=false
#     kind=tag                                        the newest stable release tag (else the newest tag) reachable from the
#     ref=v0.7.0                                      merge base of HEAD and origin/BASE_BRANCH (for a push to the branch, from
#                                                     HEAD), newest by version number; the drill runs that tag's own upgrade.sh
#   or, when no tag can start the drill,
#     skip=false
#     kind=merge-base                                 the merge base with origin/BASE_BRANCH (the commit before HEAD when HEAD is
#     ref=<full commit>                               the branch tip, as on a push), so the drill runs on every change, tag or no
#     note=...                                        tag, and also proves "this change applies on top of an install of the
#                                                     branch"; the drill adds this change's upgrade.sh to that tree
#   or
#     skip=true
#     reason=...                                      why there is nothing to drill (one line; it is also printed on stderr)
#
# A starting point can take part in an upgrade.sh move when it has scripts/backup.sh and scripts/verify-restore.sh, its
# scripts/operator-lock.sh has operator_lock_or_inherited, and it runs the same PostgreSQL major as HEAD (another major is the
# separate "Major PostgreSQL upgrade" procedure, which upgrade.sh refuses; tests/upgrade.test.mjs covers the refusal). The script
# skips, never fails: when HEAD is itself a release tag, or when neither a tag nor the merge base qualifies.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
skip() { printf 'skip=true\nreason=%s\n' "$1"; printf 'Upgrade drill skipped: %s\n' "$1" >&2; exit 0; }

branch="${1:-main}"
now="$(bash scripts/pg-major.sh)"
head="$(git rev-parse HEAD)"
base="$(git merge-base HEAD "origin/$branch" 2>/dev/null || printf '%s' "$head")"

# Prints why REF ($2 names it in the message) cannot start an upgrade.sh move to HEAD; prints nothing when it can.
unusable() {
  local ref="$1" label="$2" path before
  for path in scripts/backup.sh scripts/verify-restore.sh; do
    git cat-file -e "$ref:$path" 2>/dev/null || { printf '%s has no %s' "$label" "$path"; return 0; }
  done
  git show "$ref:scripts/operator-lock.sh" 2>/dev/null | grep -q '^operator_lock_or_inherited()' || { printf '%s predates the inherited operator lock that upgrade.sh relies on' "$label"; return 0; }
  before="$(bash scripts/pg-major.sh "$ref" 2>/dev/null)" || { printf 'the PostgreSQL major of %s cannot be read (it predates scripts/db-image.sh)' "$label"; return 0; }
  [[ "$before" == "$now" ]] || printf "%s runs PostgreSQL %s and this commit runs PostgreSQL %s: a new major is the separate 'Major PostgreSQL upgrade' procedure, not an upgrade.sh move" "$label" "$before" "$now"
  return 0
}

tags="$(git tag --merged "$base" --list 'v[0-9]*' --sort=-v:refname | LC_ALL=C grep -E '^v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?$' || true)"
tag_reason="no release tag (v*) is reachable from the merge base with origin/$branch"
if [[ -n "$tags" ]]; then
  tag="$(LC_ALL=C grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' <<< "$tags" | head -n 1 || true)"
  [[ -n "$tag" ]] || tag="$(head -n 1 <<< "$tags")"
  [[ "$(git rev-parse "$tag^{commit}")" != "$head" ]] || skip "HEAD is the release $tag itself"
  tag_reason="$(unusable "$tag" "$tag")"
  if [[ -z "$tag_reason" ]]; then
    printf 'skip=false\nkind=tag\nref=%s\n' "$tag"
    exit 0
  fi
fi

# No tag can start the drill: the merge base with the branch does (on a push to the branch that is HEAD itself, so its parent).
previous="$base"
[[ "$previous" != "$head" ]] || previous="$(git rev-parse -q --verify 'HEAD^1' || true)"
[[ -n "$previous" ]] || skip "$tag_reason; and there is no earlier commit to start from"
label="the merge base with origin/$branch ($(git rev-parse --short "$previous"))"
reason="$(unusable "$previous" "$label")"
[[ -z "$reason" ]] || skip "$tag_reason; $reason"
note="no release tag can start the drill ($tag_reason), so it starts from $label and proves that this change applies on top of an installation of $branch"
printf 'skip=false\nkind=merge-base\nref=%s\nnote=%s\n' "$previous" "$note"
printf 'Upgrade drill: %s.\n' "$note" >&2
