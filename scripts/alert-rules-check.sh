#!/usr/bin/env bash
# Checks the monitoring rules with the promtool of the pinned Prometheus image, without a state
# directory and without a network:
#   promtool check config   the prometheus.yml that setup.sh would render (scripts/monitoring-config.mjs)
#   promtool check rules    docker/alert-rules.yml
#   promtool test rules     docker/alert-rules.test.yml (every rule has a firing and a quiet case:
#                           tests/alert-rules.test.mjs)
# The image is the one docker/prometheus/Dockerfile builds on, by digest; the containers run with
# --network none. `docker run` pulls the image once if it is not on the host.
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
image=$(sed -n 's/^FROM \(prom\/prometheus:[^ ]*@sha256:[0-9a-f]\{64\}\)$/\1/p' "$root/docker/prometheus/Dockerfile" | tail -n 1)
[[ -n "$image" ]] || { echo 'Could not read the pinned Prometheus image from docker/prometheus/Dockerfile.' >&2; exit 1; }
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
node --input-type=module - "$root" "$work/prometheus.yml" <<'NODE'
import { readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';
const [root, out] = process.argv.slice(2);
const { renderPrometheusConfig } = await import(pathToFileURL(join(root, 'scripts/monitoring-config.mjs')).href);
writeFileSync(out, renderPrometheusConfig(readFileSync(join(root, 'docker/prometheus.yml'), 'utf8'), 'warehouse-rules-check'));
NODE
promtool() {
  docker run --rm --network none --read-only --tmpfs /tmp:rw,nosuid,size=64m --cap-drop ALL --security-opt no-new-privileges --entrypoint promtool \
    -v "$work/prometheus.yml:/etc/prometheus/prometheus.yml:ro" \
    -v "$root/docker/alert-rules.yml:/etc/prometheus/alert-rules.yml:ro" \
    -v "$root/docker/alert-rules.test.yml:/etc/prometheus/alert-rules.test.yml:ro" \
    "$image" "$@"
}
promtool check config /etc/prometheus/prometheus.yml
promtool check rules /etc/prometheus/alert-rules.yml
promtool test rules /etc/prometheus/alert-rules.test.yml
echo 'Alert rules and the rendered Prometheus configuration passed promtool.'
