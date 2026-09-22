#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
compose() { bash "$ROOT/scripts/compose.sh" "$@"; }
compose --profile realtime up -d realtime
ready=false
for ((i=0; i<45; i++)); do
  id=$(compose --profile realtime ps -q realtime)
  state=$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$id" 2>/dev/null || true)
  if [[ "$state" == healthy ]]; then ready=true; break; fi
  sleep 2
done
[[ "$ready" == true ]] || { compose --profile realtime logs realtime; exit 1; }
node "$ROOT/scripts/realtime-smoke.mjs"
