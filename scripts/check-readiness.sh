#!/usr/bin/env bash
set -euo pipefail
# Production stays gated until provider, full API, and deployment checks are complete.
if [[ "${1:-}" == '--demo' && "$#" == 1 ]]; then
  echo 'LOCAL DEMO ONLY: production SMS, native-device acceptance and optional printing are not release-ready.' >&2
  exit 0
fi
echo 'Production setup is not ready. Use ./setup.sh --demo for an isolated, loopback-only demonstration.' >&2
echo 'See docs/READINESS.md for remaining acceptance checks.' >&2
exit 1
