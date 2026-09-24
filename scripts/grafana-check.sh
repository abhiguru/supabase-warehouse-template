#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
check_id="$$-$RANDOM"
image="warehouse-grafana-smoke:$check_id"
container="warehouse-grafana-smoke-$check_id"
network="warehouse-grafana-smoke-$check_id"
prometheus="warehouse-prometheus-smoke-$check_id"
postgres="warehouse-postgres-smoke-$check_id"
report_dir=$(mktemp -d)
cleanup() {
  docker rm -f "$container" >/dev/null 2>&1 || true
  docker rm -f "$prometheus" "$postgres" >/dev/null 2>&1 || true
  docker network rm "$network" >/dev/null 2>&1 || true
  docker image rm "$image" >/dev/null 2>&1 || true
  rm -rf "$report_dir"
}
trap cleanup EXIT

docker build --no-cache --pull=false -t "$image" -f "$root/docker/grafana/Dockerfile" "$root/docker"
arch=$(docker image inspect --format '{{.Architecture}}' "$image")
if [[ -n ${EXPECTED_ARCH:-} && "$arch" != "$EXPECTED_ARCH" ]]; then
  echo "Expected Grafana architecture $EXPECTED_ARCH, found $arch." >&2
  exit 1
fi
cat > "$report_dir/prometheus.yml" <<'YAML'
global:
  scrape_interval: 1s
scrape_configs:
  - job_name: prometheus-fixture
    static_configs:
      - targets: ['prometheus:9090']
YAML
docker network create --internal "$network" >/dev/null
docker run --rm -d --name "$prometheus" --network "$network" --network-alias prometheus \
  --read-only --tmpfs /prometheus:rw,uid=65534,gid=65534 \
  --mount "type=bind,src=$report_dir/prometheus.yml,dst=/etc/prometheus/prometheus.yml,readonly" \
  prom/prometheus:v3.14.0 >/dev/null
docker run --rm -d --name "$postgres" --network "$network" --network-alias db \
  --tmpfs /var/lib/postgresql/data:rw,mode=0700 \
  -e POSTGRES_PASSWORD=ephemeral-test-only postgres:16-alpine >/dev/null
docker run --rm -d --name "$container" --network "$network" --read-only \
  --tmpfs /var/lib/grafana:rw,uid=472,gid=0,mode=0700 \
  --tmpfs /tmp:rw,uid=472,gid=0,mode=1777 \
  --mount "type=bind,src=$root/docker/volumes/grafana/provisioning,dst=/etc/grafana/provisioning,readonly" \
  -e GF_SECURITY_ADMIN_PASSWORD=ephemeral-test-only \
  -e POSTGRES_PASSWORD=ephemeral-test-only \
  "$image" >/dev/null

if [[ $(docker exec "$container" printenv GF_PLUGINS_PREINSTALL_AUTO_UPDATE) != false ]]; then
  echo 'Grafana image did not retain its pinned plugin update policy.' >&2
  exit 1
fi

ready=false
for ((attempt=0; attempt<45; attempt++)); do
  if docker exec "$container" wget -qO- http://127.0.0.1:3000/api/health > "$report_dir/health.json" 2>/dev/null; then
    ready=true
    break
  fi
  sleep 1
done
if [[ "$ready" != true ]]; then
  docker logs --tail 100 "$container" >&2
  echo 'Grafana did not become healthy.' >&2
  exit 1
fi

ready=false
for ((attempt=0; attempt<45; attempt++)); do
  if docker exec "$postgres" pg_isready -U postgres -d postgres >/dev/null 2>&1 &&
    docker exec "$container" wget -qO- http://prometheus:9090/-/ready >/dev/null 2>&1; then
    ready=true
    break
  fi
  sleep 1
done
if [[ "$ready" != true ]]; then
  docker logs --tail 100 "$prometheus" >&2
  docker logs --tail 100 "$postgres" >&2
  echo 'Grafana datasource fixtures did not become ready.' >&2
  exit 1
fi
docker exec "$postgres" psql -v ON_ERROR_STOP=1 -U postgres -d postgres \
  -c 'CREATE TABLE grafana_smoke_reading (observed_at timestamptz NOT NULL, reading integer NOT NULL); INSERT INTO grafana_smoke_reading VALUES (now(), 4242)' >/dev/null

scraped=false
for ((attempt=0; attempt<30; attempt++)); do
  if docker exec "$container" wget -qO- \
    'http://prometheus:9090/api/v1/query?query=up%7Bjob%3D%22prometheus-fixture%22%7D' 2>/dev/null |
    node -e 'let body="";process.stdin.on("data",chunk=>body+=chunk).on("end",()=>{try{const response=JSON.parse(body);if(response.data.result.some(item=>item.value[1]==="1"))process.exit(0)}catch{}process.exit(1)})'; then
    scraped=true
    break
  fi
  sleep 1
done
if [[ "$scraped" != true ]]; then
  docker logs --tail 100 "$prometheus" >&2
  echo 'Prometheus fixture did not produce an up sample.' >&2
  exit 1
fi

auth_header='Authorization: Basic YWRtaW46ZXBoZW1lcmFsLXRlc3Qtb25seQ=='
docker exec "$container" wget -qO- --header "$auth_header" \
  'http://127.0.0.1:3000/api/plugins?core=false' > "$report_dir/plugins.json"
docker exec "$container" wget -qO- --header "$auth_header" \
  'http://127.0.0.1:3000/api/datasources' > "$report_dir/datasources.json"

cat > "$report_dir/prometheus-query.json" <<'JSON'
{"queries":[{"refId":"A","datasource":{"uid":"PBFA97CFB590B2093"},"expr":"up{job=\"prometheus-fixture\"}","instant":true,"range":false}],"from":"now-5m","to":"now"}
JSON
cat > "$report_dir/postgres-query.json" <<'JSON'
{"queries":[{"refId":"A","datasource":{"uid":"PG_SEC_001"},"rawQuery":true,"editorMode":"code","rawSql":"SELECT observed_at AS time, reading AS value FROM grafana_smoke_reading","format":"time_series"}],"from":"now-5m","to":"now"}
JSON
for source in prometheus postgres; do
  expected=1
  [[ "$source" == postgres ]] && expected=4242
  queried=false
  for ((attempt=0; attempt<15; attempt++)); do
    if docker exec "$container" wget -qSO- --header "$auth_header" \
      --header 'Content-Type: application/json' \
      --post-data "$(<"$report_dir/$source-query.json")" \
      'http://127.0.0.1:3000/api/ds/query' \
      > "$report_dir/$source-response.json" 2> "$report_dir/$source-http.txt" &&
      node -e 'const fs=require("node:fs");try{const response=JSON.parse(fs.readFileSync(process.argv[1]));const result=response.results?.A;const values=result?.frames?.flatMap(frame=>frame.data?.values??[]).flat()??[];process.exit(!result?.error&&values.includes(Number(process.argv[2]))?0:1)}catch{process.exit(1)}' \
        "$report_dir/$source-response.json" "$expected"; then
      queried=true
      break
    fi
    sleep 1
  done
  if [[ "$queried" != true ]]; then
    status=$(awk '/HTTP\// {status=$2} END {print status}' "$report_dir/$source-http.txt")
    echo "Grafana $source query did not return fixture value $expected after 15 attempts (last HTTP status ${status:-unknown})." >&2
    exit 1
  fi
done

node --input-type=module - "$report_dir" "$root/docker/grafana/plugins.lock" "$arch" <<'NODE'
import { readFileSync } from 'node:fs';
import { join } from 'node:path';

const [directory, lockfile, arch] = process.argv.slice(2);
const read = name => JSON.parse(readFileSync(join(directory, name), 'utf8'));
const health = read('health.json');
if (health.database !== 'ok' || health.version !== '13.2.2') {
  throw new Error('Grafana health or version mismatch');
}

const bundled = 'elasticsearch grafana-postgresql-datasource grafana-pyroscope-datasource influxdb jaeger loki mssql mysql opentsdb prometheus stackdriver tempo zipkin'.split(' ');
const plugins = read('plugins.json');
for (const id of bundled) {
  const plugin = plugins.find(item => item.id === id);
  if (!plugin || plugin.signature !== 'valid' || plugin.signatureType !== 'grafana' || plugin.signatureOrg !== 'Grafana Labs') {
    throw new Error(`Missing or invalid publisher signature for ${id}`);
  }
}

let updated = 0;
for (const line of readFileSync(lockfile, 'utf8').split('\n')) {
  if (!line || line.startsWith('#')) continue;
  const [id, version, packageArch] = line.split(' ');
  if (packageArch !== arch) continue;
  const plugin = plugins.find(item => item.id === id);
  if (plugin?.info?.version !== version) throw new Error(`Wrong installed version for ${id}`);
  updated++;
}
if (updated !== 7) throw new Error(`Expected seven updated plugins, found ${updated}`);

const datasources = read('datasources.json');
if (!datasources.some(item => item.name === 'Prometheus' && item.type === 'prometheus' && item.uid === 'PBFA97CFB590B2093') ||
    !datasources.some(item => item.name === 'PostgreSQL-Sec' && item.type === 'grafana-postgresql-datasource' && item.uid === 'PG_SEC_001')) {
  throw new Error('Monitoring datasource provisioning mismatch');
}
for (const [source, expected] of [['prometheus', 1], ['postgres', 4242]]) {
  const response = read(`${source}-response.json`);
  const result = response.results?.A;
  if (result?.error || !result?.frames?.length) {
    throw new Error(`${source} query failed: ${result?.error ?? JSON.stringify(response)}`);
  }
  const values = result.frames.flatMap(frame => frame.data?.values ?? []).flat();
  if (!values.includes(expected)) {
    throw new Error(`${source} query returned no fixture value ${expected}: ${JSON.stringify(response)}`);
  }
}
console.log(`Grafana 13.2.2 healthy; ${bundled.length} signed plugins, provisioning, and live Prometheus/PostgreSQL queries passed.`);
NODE
