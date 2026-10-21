#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
compose() { bash "$ROOT/scripts/compose.sh" "$@"; }
failed=0
for service in db kong rest storage functions pdf-renderer; do
  id=$(compose ps -q "$service")
  if [[ -z "$id" ]]; then
    echo "$service: missing"; failed=1; continue
  fi
  # `index`, not `.State.Health`: some docker CLIs stop with "map has no entry for key Health" for a container without a healthcheck.
  state=$(docker inspect --format '{{.State.Status}} {{with index .State "Health"}}{{index . "Status"}}{{end}}' "$id")
  echo "$service: $state"
  if [[ "$state" != running* || "$state" == *unhealthy* || "$state" == *starting* ]]; then
    failed=1
  fi
done
compose exec -T db pg_isready -U supabase_admin -d postgres || failed=1
# Probe the intended project internally, never an unrelated server on a fixed host port.
# Each probe runs in a container that shares a network with its target
# (docker/docker-compose.yml, `networks:`): the storage service for the gateway
# and its upstreams, and the function runtime for the PDF renderer.
probe_from() {
  { cat "$ROOT/scripts/http-readiness.mjs"; cat; } | compose exec -T "$1" node --input-type=module
}
probe_from storage <<'JS' || failed=1
for (const [name,url,headers] of [
  // A table read through the gateway: PostgREST's OpenAPI document at /rest/v1/ is off (PGRST_OPENAPI_MODE=disabled).
  ['REST','http://kong:8000/rest/v1/feature_flags?select=id&limit=1',{apikey:process.env.ANON_KEY}],
  ['configuration','http://kong:8000/functions/v1/get-public-config',{}],
]) {
  await waitForHttp(name,url,headers);
  console.log(`${name}: available`);
}
JS
# PDFs reach the renderer from the function runtime over the internal `renderer` network, which
# storage cannot see. So the probe runs in `functions` (bash with /dev/tcp, as its own health check does):
# it proves the path the PDF functions really use, not only that the renderer answers to itself.
if compose exec -T functions bash -c 'exec 3<>/dev/tcp/pdf-renderer/3000 && printf "GET /health HTTP/1.1\r\nHost: pdf-renderer\r\nConnection: close\r\n\r\n" >&3 && head -n 1 <&3 | grep -q " 200 "'; then
  echo 'PDF renderer: available'
else
  echo 'PDF renderer: not reachable from functions (docker/docker-compose.yml, network renderer)'
  failed=1
fi
if [[ "$failed" != 0 ]]; then
  node "$ROOT/scripts/service-diagnostics.mjs" kong functions rest
fi
exit "$failed"
