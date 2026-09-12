#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Only this reviewed source-demo tag is eligible. Future tags require review;
# the production gate is not relaxed for arbitrary versions or other contexts.
if [[ "${GITHUB_REF_TYPE:-}" == tag && "${GITHUB_REF_NAME:-}" == v0.2.0-demo ]]; then
  bash "$ROOT/scripts/check-readiness.sh" --demo
  echo 'Source-only prerelease validation; native devices and production remain unaccepted.'
else
  bash "$ROOT/scripts/check-readiness.sh"
fi
