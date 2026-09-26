#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" != --operator ]]; then
  echo 'Use ./setup.sh --operator with an explicitly selected state directory. Demo installation is no longer supported.' >&2
  exit 1
fi
if [[ "$(uname -s)" != Linux || "$(uname -m)" != x86_64 ]]; then
  echo 'Operator installation requires Linux x86-64.' >&2
  exit 1
fi
for command in docker node npm openssl; do
  command -v "$command" >/dev/null || { echo "Missing prerequisite: $command" >&2; exit 1; }
done
