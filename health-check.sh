#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
compose() { bash "$ROOT/scripts/compose.sh" "$@"; }
failed=0
for service in db kong rest realtime storage imgproxy meta studio functions pdf-renderer; do
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
# Lists (migration 91) are refreshed after the commit by the pg_cron job warehouse-list-refresh.
# The job must run, and no list may wait longer than the 15 s bound; the first run after a start
# or restore gets up to 30 s to catch up.
list_refresh=''
for ((attempt = 0; attempt < 7; attempt++)); do
  list_refresh=$(compose exec -T db psql -X -A -t -U supabase_admin -d postgres -v ON_ERROR_STOP=1 \
    -c "SELECT CASE WHEN (s->>'ok')::boolean THEN 'current' ELSE s->>'problems' END FROM warehouse_security.list_refresh_status() s" 2>/dev/null) \
    || list_refresh='status unavailable (is the database on migration 91? run setup.sh)'
  [[ "$list_refresh" == current ]] && break
  sleep 5
done
echo "list refresh: $list_refresh"
[[ "$list_refresh" == current ]] || failed=1
# Probe the intended project internally, never an unrelated server on a fixed host port.
# Each probe runs in a container that shares a network with its target
# (docker/docker-compose.yml, `networks:`): the storage service for the gateway
# and its upstreams, Studio for postgres-meta, which nothing else can reach, and the
# PDF renderer for itself.
probe_from() {
  { cat "$ROOT/scripts/http-readiness.mjs"; cat; } | compose exec -T "$1" node --input-type=module
}
probe_from storage <<'JS' || failed=1
for (const [name,url,headers] of [
  ['REST','http://kong:8000/rest/v1/',{apikey:process.env.ANON_KEY}],
  ['configuration','http://kong:8000/functions/v1/get-public-config',{}],
  ['Realtime','http://realtime-dev:4000/api/tenants/realtime-dev/health',{Authorization:`Bearer ${process.env.ANON_KEY}`}],
]) {
  await waitForHttp(name,url,headers);
  console.log(`${name}: available`);
}
JS
# The renderer sits on the internal `renderer` network with the function runtime only,
# so storage cannot reach it: the probe runs inside the renderer container (its image
# has node and no curl).
probe_from pdf-renderer <<'JS' || failed=1
await waitForHttp('PDF renderer','http://pdf-renderer:3000/health',{});
console.log('PDF renderer: available');
JS
probe_from studio <<'JS' || failed=1
await waitForHttp('metadata','http://meta:8080/health',{});
console.log('metadata: available');
JS
if [[ "$failed" != 0 ]]; then
  node "$ROOT/scripts/service-diagnostics.mjs" kong functions rest
fi
exit "$failed"
