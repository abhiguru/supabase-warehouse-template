#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
check_id="$$-$RANDOM"
image="warehouse-grafana-smoke:$check_id"
container="warehouse-grafana-smoke-$check_id"
report_dir=$(mktemp -d)
cleanup() {
  docker rm -f "$container" >/dev/null 2>&1 || true
  docker image rm "$image" >/dev/null 2>&1 || true
  rm -rf "$report_dir"
}
trap cleanup EXIT

docker build --no-cache --pull=false -t "$image" -f "$root/docker/grafana/Dockerfile" "$root/docker"
arch=$(docker image inspect --format '{{.Architecture}}' "$image")
docker run --rm -d --name "$container" --network none --read-only \
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

auth_header='Authorization: Basic YWRtaW46ZXBoZW1lcmFsLXRlc3Qtb25seQ=='
docker exec "$container" wget -qO- --header "$auth_header" \
  'http://127.0.0.1:3000/api/plugins?core=false' > "$report_dir/plugins.json"
docker exec "$container" wget -qO- --header "$auth_header" \
  'http://127.0.0.1:3000/api/datasources' > "$report_dir/datasources.json"

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
// The container has no network, so this checks provisioning records, not live backend queries.
if (!datasources.some(item => item.name === 'Prometheus' && item.type === 'prometheus' && item.uid === 'PBFA97CFB590B2093') ||
    !datasources.some(item => item.name === 'PostgreSQL-Sec' && item.type === 'grafana-postgresql-datasource' && item.uid === 'PG_SEC_001')) {
  throw new Error('Monitoring datasource provisioning mismatch');
}
console.log(`Grafana 13.2.2 healthy; ${bundled.length} signed plugins and datasource provisioning records passed (no backend queries).`);
NODE
