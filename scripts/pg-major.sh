#!/usr/bin/env bash
# Prints the PostgreSQL major version that a tree of this repository runs: the number after "postgres:" in the pin that
# the tree's own scripts/db-image.sh prints (the FROM line of docker/postgres/Dockerfile).
#
#   bash scripts/pg-major.sh           this checkout
#   bash scripts/pg-major.sh REF       the tree at a tag or commit; its scripts/db-image.sh and docker/postgres/Dockerfile are
#                                      read from git and the REF's own db-image.sh is run on them (nothing is checked out)
#
# upgrade.sh and the CI upgrade drill compare the two: a release that changes the major is not an upgrade.sh move but the
# separate "Major PostgreSQL upgrade" procedure (docs/OPERATOR_INSTALL.md). Exits 1 with a message when the major cannot
# be determined, for example a release from before scripts/db-image.sh existed.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ref="${1:-}"
tree="$ROOT"
if [[ -n "$ref" ]]; then
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  if ! git -C "$ROOT" archive "$ref" scripts/db-image.sh docker/postgres/Dockerfile 2>/dev/null | tar -x -C "$tree"; then
    echo "Cannot read the PostgreSQL version of $ref: it has no scripts/db-image.sh and docker/postgres/Dockerfile." >&2
    exit 1
  fi
fi
pin="$(bash "$tree/scripts/db-image.sh")" || { echo "Cannot read the PostgreSQL version of ${ref:-this checkout}: scripts/db-image.sh failed (message above)." >&2; exit 1; }
major="${pin#postgres:}"
major="${major%%[!0-9]*}"
[[ "$major" =~ ^[0-9]+$ ]] || { echo "Cannot read the PostgreSQL version of ${ref:-this checkout}: the pin '$pin' is not a postgres:<major> image." >&2; exit 1; }
printf '%s\n' "$major"
