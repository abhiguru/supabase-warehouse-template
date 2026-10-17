#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
compose() { bash "$ROOT/scripts/compose.sh" "$@"; }
# Builds and starts the monitoring profile: one operator command at a time per state.
# shellcheck source=scripts/operator-lock.sh
. "$ROOT/scripts/operator-lock.sh"
state="$(operator_state)"
operator_lock "$state"
state_dir="$state"   # the loop below reuses `state` for container health

# setup.sh renders the per-installation files the monitoring services mount (docs/MONITORING.md); an
# installation set up before that has none until setup runs again.
for path in config/monitoring/prometheus.yml config/monitoring/alertmanager/alertmanager.yml metrics; do
  [[ -e "$state_dir/$path" ]] || { echo "$state_dir/$path is missing: run setup.sh --operator again (docs/MONITORING.md, Several installations on one host)." >&2; exit 1; }
done
project="$(sed -n 's/^WAREHOUSE_PROJECT_NAME=//p' "$state_dir/config/compose.env")"
textfile_probe="$state_dir/metrics/warehouse_monitoring_check.prom"
trap 'rm -f -- "$textfile_probe"' EXIT

compose --profile monitoring build prometheus alertmanager
compose --profile monitoring run --rm --no-deps --entrypoint promtool prometheus \
  check config /etc/prometheus/prometheus.yml
# Unit tests of the alert rules (docker/alert-rules.test.yml), with the image's own promtool.
compose --profile monitoring run --rm --no-deps \
  -v "$ROOT/docker/alert-rules.test.yml:/etc/prometheus/alert-rules.test.yml:ro" \
  --entrypoint promtool prometheus \
  test rules /etc/prometheus/alert-rules.test.yml
compose --profile monitoring run --rm --no-deps --entrypoint amtool alertmanager \
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

# The gateway must export per-request series, not only node-level ones: the API
# alert rules have nothing to evaluate without them. Send one request through
# the gateway from a container on its network, then wait for a scrape.
compose exec -T storage node -e "fetch('http://kong:8000/functions/v1/hello').then(r=>r.arrayBuffer())" >/dev/null 2>&1 || true
gateway_metrics=false
for ((i=0; i<30; i++)); do
  series=$(compose --profile monitoring exec -T prometheus wget -qO- 'http://localhost:9090/api/v1/query?query=sum(kong_http_requests_total)' || true)
  if node -e "const r=JSON.parse(process.argv[1]).data.result;if(!(r.length===1&&Number(r[0].value[1])>0))process.exit(1)" "$series" 2>/dev/null; then
    gateway_metrics=true; break
  fi
  sleep 2
done
[[ "$gateway_metrics" == true ]] || { echo 'Prometheus has no gateway request metrics (kong_http_requests_total).' >&2; exit 1; }

# DatabaseConnectionsHigh adds up the series labelled backend_type="client backend". An exporter
# that stopped exporting that label would leave the rule with nothing to add, and it would never
# fire. The query is sum(pg_stat_activity_count{backend_type="client backend"}), URL-encoded.
client_connections=false
for ((i=0; i<30; i++)); do
  series=$(compose --profile monitoring exec -T prometheus wget -qO- 'http://localhost:9090/api/v1/query?query=sum(pg_stat_activity_count%7Bbackend_type%3D%22client%20backend%22%7D)' || true)
  if node -e "const r=JSON.parse(process.argv[1]).data.result;if(!(r.length===1&&Number(r[0].value[1])>0))process.exit(1)" "$series" 2>/dev/null; then
    client_connections=true; break
  fi
  sleep 2
done
[[ "$client_connections" == true ]] || { echo 'Prometheus has no client connection series (pg_stat_activity_count{backend_type="client backend"}).' >&2; exit 1; }

# The installation label is part of the running configuration, not only of the file setup rendered.
config=$(compose --profile monitoring exec -T prometheus wget -qO- http://localhost:9090/api/v1/status/config)
node -e "const yaml=JSON.parse(process.argv[1]).data.yaml;if(!yaml.includes('installation: '+process.argv[2]+'\n'))process.exit(1)" "$config" "$project" ||
  { echo "Prometheus does not carry the external label installation: $project." >&2; exit 1; }

# Every shipped rule is loaded and healthy, the backup rules among them.
expected_rules=$(grep -c '^ *- alert: ' "$ROOT/docker/alert-rules.yml")
rules_loaded=false
for ((i=0; i<30; i++)); do
  rules=$(compose --profile monitoring exec -T prometheus wget -qO- http://localhost:9090/api/v1/rules || true)
  # A rule is "unknown" until its group has been evaluated once.
  if node -e "const rules=JSON.parse(process.argv[1]).data.groups.flatMap(group=>group.rules);const names=rules.map(rule=>rule.name);if(rules.length!==Number(process.argv[2])||!['BackupMissing','BackupFailed'].every(name=>names.includes(name))||rules.some(rule=>rule.health!=='ok'))process.exit(1)" "$rules" "$expected_rules" 2>/dev/null; then rules_loaded=true; break; fi
  sleep 2
done
[[ "$rules_loaded" == true ]] || { echo "Prometheus did not load all $expected_rules alert rules, or a rule is unhealthy." >&2; exit 1; }

# Prometheus holds this installation's containers and none of another installation's. cAdvisor reports
# every container on the host; the scrape job keeps one Compose project (docker/prometheus.yml).
query() { node -e 'console.log("http://localhost:9090/api/v1/query?query="+encodeURIComponent(process.argv[1]))' "$1"; }
own_containers=false
for ((i=0; i<30; i++)); do
  series=$(compose --profile monitoring exec -T prometheus wget -qO- "$(query "count(container_memory_usage_bytes{container_label_com_docker_compose_project=\"$project\"})")" || true)
  if node -e "const r=JSON.parse(process.argv[1]).data.result;if(!(r.length===1&&Number(r[0].value[1])>0))process.exit(1)" "$series" 2>/dev/null; then own_containers=true; break; fi
  sleep 2
done
[[ "$own_containers" == true ]] || { echo "Prometheus has no container series of the project $project." >&2; exit 1; }
series=$(compose --profile monitoring exec -T prometheus wget -qO- "$(query "count(container_memory_usage_bytes{container_label_com_docker_compose_project!=\"\",container_label_com_docker_compose_project!=\"$project\"})")")
node -e "if(JSON.parse(process.argv[1]).data.result.length!==0)process.exit(1)" "$series" ||
  { echo "Prometheus holds container series of another Compose project than $project." >&2; exit 1; }

# The textfile directory the backup scripts write (scripts/backup-metrics.sh) reaches Prometheus through node
# exporter. A probe file of its own, so a real backup metric is never faked; removed on exit.
printf '# TYPE warehouse_monitoring_check_textfile gauge\nwarehouse_monitoring_check_textfile 1\n' > "$textfile_probe"
chmod 644 -- "$textfile_probe"
textfile=false
for ((i=0; i<30; i++)); do
  series=$(compose --profile monitoring exec -T prometheus wget -qO- "$(query 'warehouse_monitoring_check_textfile and on() (node_textfile_scrape_error == 0)')" || true)
  if node -e "const r=JSON.parse(process.argv[1]).data.result;if(!(r.length===1&&Number(r[0].value[1])===1))process.exit(1)" "$series" 2>/dev/null; then textfile=true; break; fi
  sleep 2
done
[[ "$textfile" == true ]] || { echo 'Prometheus did not read the textfile metrics directory through node exporter.' >&2; exit 1; }

now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
compose --profile monitoring exec -T alertmanager wget -qO- --header='Content-Type: application/json' \
  --post-data="[{\"labels\":{\"alertname\":\"WarehouseSynthetic\",\"severity\":\"warning\"},\"annotations\":{\"summary\":\"local delivery test\"},\"startsAt\":\"$now\"}]" \
  http://localhost:9093/api/v2/alerts >/dev/null
alerts=$(compose --profile monitoring exec -T alertmanager wget -qO- http://localhost:9093/api/v2/alerts)
node -e "if(!JSON.parse(process.argv[1]).some(a=>a.labels.alertname==='WarehouseSynthetic'))process.exit(1)" "$alerts"
echo 'Monitoring configs, alert rule tests, the installation label, per-installation container series, the backup textfile directory, scrape targets, and local Alertmanager delivery passed.'
