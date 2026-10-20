#!/usr/bin/env bash
# Prints the database image reference (name:tag@sha256:digest) the production database is built from:
# the FROM line of docker/postgres/Dockerfile, which Dependabot bumps. The disposable databases of
# tests/migrations.sh and scripts/verify-restore.sh, and the database_image= line of a backup, read it
# here so there is one pin (tests/shell-syntax.test.mjs compares).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ref="$(sed -n 's/^FROM \(postgres:[^[:space:]]*@sha256:[0-9a-f]\{64\}\)$/\1/p' "$ROOT/docker/postgres/Dockerfile")"
[[ -n "$ref" && "$ref" != *$'\n'* ]] || { echo 'docker/postgres/Dockerfile has no single FROM postgres:<tag>@sha256:<digest> line.' >&2; exit 1; }
printf '%s\n' "$ref"
