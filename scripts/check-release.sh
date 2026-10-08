#!/usr/bin/env bash
set -euo pipefail
# Release validation runs only for semantic version tags: vMAJOR.MINOR.PATCH with
# optional -prerelease and +build suffixes (v0.3.0, v0.3.0-rc.1, v1.2.3+build.5).
# Branch refs and any other name are refused. Publishing remains a manual
# maintainer step after this gate and the tag's checks pass.
# Bracket ranges are collation-dependent in UTF-8 locales ([A-Za-z] admits
# accented letters); match in the C locale so only ASCII tag names pass.
export LC_ALL=C
ref_type="${GITHUB_REF_TYPE:-}"
ref_name="${GITHUB_REF_NAME:-}"
semver='^v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?$'
if [[ "$ref_type" != tag ]]; then
  echo "Release gate: refusing ${ref_type:-untyped} ref '${ref_name}'. Only semantic version tags (vMAJOR.MINOR.PATCH[-prerelease][+build]) are validated for release." >&2
  exit 1
fi
if [[ ! "$ref_name" =~ $semver ]]; then
  echo "Release gate: refusing tag '${ref_name}'. Expected vMAJOR.MINOR.PATCH with optional -prerelease and +build suffixes, for example v0.3.0 or v0.3.0-rc.1." >&2
  exit 1
fi
echo "Release gate: tag ${ref_name} is a valid semantic version."
