#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
compose() { bash "$ROOT/scripts/compose.sh" "$@"; }

docker run --rm -v "$ROOT/docker:/etc/prometheus:ro" --entrypoint promtool prom/prometheus:v3.14.0 \
  check config /etc/prometheus/prometheus.yml
docker run --rm -v "$ROOT/docker:/etc/alertmanager:ro" --entrypoint amtool prom/alertmanager:v0.34.1 \
  check-config /etc/alertmanager/alertmanager.yml
compose --profile monitoring up -d prometheus alertmanager postgres-exporter node-exporter cadvisor

for service in prometheus alertmanager postgres-exporter node-exporter; do
  ready=false
  for ((i=0; i<45; i++)); do
    id=$(compose --profile monitoring ps -q "$service")
    state=$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$id" 2>/dev/null || true)
    if [[ "$state" == healthy || "$state" == running ]]; then ready=true; break; fi
    sleep 2
  done
  [[ "$ready" == true ]] || { echo "$service did not become ready" >&2; exit 1; }
done

targets_ready=false
for ((i=0; i<30; i++)); do
  targets=$(compose --profile monitoring exec -T prometheus wget -qO- http://localhost:9090/api/v1/targets)
  if TARGETS='localhost:9090,postgres-exporter:9187,node-exporter:9100,cadvisor:8080,kong:8100' node -e "const a=JSON.parse(process.argv[1]).data.activeTargets;const wanted=process.env.TARGETS.split(',');if(!wanted.every(w=>a.some(t=>t.discoveredLabels.__address__===w&&t.health==='up')))process.exit(1)" "$targets"; then
    targets_ready=true; break
  fi
  sleep 2
done
[[ "$targets_ready" == true ]] || { echo 'One or more monitoring scrape targets remained down.' >&2; exit 1; }

now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
compose --profile monitoring exec -T alertmanager wget -qO- --header='Content-Type: application/json' \
  --post-data="[{\"labels\":{\"alertname\":\"WarehouseSynthetic\",\"severity\":\"warning\"},\"annotations\":{\"summary\":\"local delivery test\"},\"startsAt\":\"$now\"}]" \
  http://localhost:9093/api/v2/alerts >/dev/null
alerts=$(compose --profile monitoring exec -T alertmanager wget -qO- http://localhost:9093/api/v2/alerts)
node -e "if(!JSON.parse(process.argv[1]).some(a=>a.labels.alertname==='WarehouseSynthetic'))process.exit(1)" "$alerts"
echo 'Monitoring configs, scrape targets, and local Alertmanager delivery passed.'
