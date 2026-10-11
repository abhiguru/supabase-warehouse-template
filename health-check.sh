#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
compose() { bash "$ROOT/scripts/compose.sh" "$@"; }
failed=0
for service in db kong rest realtime storage imgproxy meta studio functions gotenberg; do
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
# Each probe runs in a container that shares a network with its target
# (docker/docker-compose.yml, `networks:`): the storage service for the gateway
# and its upstreams, Studio for postgres-meta, which nothing else can reach.
probe_from() {
  { cat "$ROOT/scripts/http-readiness.mjs"; cat; } | compose exec -T "$1" node --input-type=module
}
probe_from storage <<'JS' || failed=1
for (const [name,url,headers] of [
  ['REST','http://kong:8000/rest/v1/',{apikey:process.env.ANON_KEY}],
  ['configuration','http://kong:8000/functions/v1/get-public-config',{}],
  ['PDF renderer','http://gotenberg:3000/health',{}],
  ['Realtime','http://realtime-dev:4000/api/tenants/realtime-dev/health',{Authorization:`Bearer ${process.env.ANON_KEY}`}],
]) {
  await waitForHttp(name,url,headers);
  console.log(`${name}: available`);
}
JS
probe_from studio <<'JS' || failed=1
await waitForHttp('metadata','http://meta:8080/health',{});
console.log('metadata: available');
JS
if [[ "$failed" != 0 ]]; then
  node "$ROOT/scripts/service-diagnostics.mjs" kong functions rest
fi
exit "$failed"
