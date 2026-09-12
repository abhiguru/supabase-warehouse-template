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
compose exec -T studio node --input-type=module <<'JS' || failed=1
for (const [name,url,headers] of [
  ['REST','http://kong:8000/rest/v1/',{apikey:process.env.SUPABASE_ANON_KEY}],
  ['configuration','http://kong:8000/functions/v1/get-public-config',{}],
  ['PDF renderer','http://gotenberg:3000/health',{}],
]) {
  const response=await fetch(url,{headers,signal:AbortSignal.timeout(30000)});
  if (!response.ok) throw new Error(`${name}: HTTP ${response.status}`);
  console.log(`${name}: available`);
}
JS
exit "$failed"
