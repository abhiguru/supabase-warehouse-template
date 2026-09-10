#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
compose() { bash "$ROOT/scripts/compose.sh" "$@"; }
failed=0
for service in db kong rest studio storage functions gotenberg; do
  id=$(compose ps -q "$service")
  if [[ -z "$id" ]]; then
    echo "$service: missing"; failed=1; continue
  fi
  state=$(docker inspect --format '{{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{end}}' "$id")
  echo "$service: $state"
  if [[ "$state" != running* || "$state" == *unhealthy* || "$state" == *starting* ]]; then
    failed=1
  fi
done
compose exec -T db pg_isready -U postgres || failed=1
# Probe the intended project internally, never an unrelated server on a fixed host port.
compose exec -T kong bash -c 'curl --fail --silent --show-error --max-time 15 http://localhost:8000/rest/v1/ -H "apikey: $SUPABASE_ANON_KEY" -o /dev/null' || failed=1
compose exec -T kong curl --fail --silent --show-error --max-time 30 http://localhost:8000/functions/v1/get-public-config -o /dev/null || failed=1
compose exec -T gotenberg curl --fail --silent --show-error --max-time 15 http://localhost:3000/health -o /dev/null || failed=1
exit "$failed"
