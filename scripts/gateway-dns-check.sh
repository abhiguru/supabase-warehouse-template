#!/usr/bin/env bash
# Exercise a changed IP for this checkout's functions service, not a Kong restart.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
compose() { bash "$ROOT/scripts/compose.sh" "$@"; }
project="${WAREHOUSE_PROJECT_NAME:-warehouse-template}"
id=$(compose ps -q functions) # validates checkout ownership first
[[ "$id" =~ ^[a-f0-9]{12,64}$ ]] || { echo 'Owned functions container unavailable.' >&2; exit 1; }
read -r network old_ip <<< "$(docker inspect --format '{{range $name, $value := .NetworkSettings.Networks}}{{$name}} {{$value.IPAddress}}{{println}}{{end}}' "$id")"
[[ "$network" == "${project}_default" && "$old_ip" =~ ^[0-9.]+$ ]] || { echo 'Unexpected service network.' >&2; exit 1; }
holder_name="${project}-dns-test-holder"
if docker inspect "$holder_name" >/dev/null 2>&1; then
  echo 'DNS test holder already exists; refusing to overwrite it.' >&2; exit 1
fi
image=$(docker inspect --format '{{.Config.Image}}' "$id")
holder_id=''
disconnected=false
cleanup() {
  # The holder ID came from this invocation only. Never remove by a broad label.
  if [[ "$holder_id" =~ ^[a-f0-9]{12,64}$ ]]; then docker rm -f "$holder_id" >/dev/null; fi
  if [[ "$disconnected" == true ]]; then docker network connect --alias functions "$network" "$id"; fi
}
trap cleanup EXIT
probe() {
  {
    cat "$ROOT/scripts/http-readiness.mjs"
    printf '\nawait waitForHttp("functions", "http://functions:9000/get-public-config", {}, {timeoutMs:30000});\n'
    printf 'await waitForHttp("gateway", "http://kong:8000/functions/v1/get-public-config", {}, {timeoutMs:30000});\n'
  } | compose exec -T studio node --input-type=module
}
probe # warms the gateway cache and checks the direct upstream
docker network disconnect "$network" "$id"
disconnected=true
holder_id=$(docker run -d --name "$holder_name" --label "warehouse.test.owner=$project" \
  --network "$network" --ip "$old_ip" --entrypoint /bin/sh "$image" -c 'sleep 300')
docker network connect --alias functions "$network" "$id"
disconnected=false
new_ip=$(docker inspect --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$id")
[[ "$new_ip" != "$old_ip" ]] || { echo 'Test did not change the upstream address.' >&2; exit 1; }
probe
echo 'Gateway recovered after an owned upstream IP change without restarting Kong.'
