#!/usr/bin/env bash
# Checks the monitoring rules with the promtool of the pinned Prometheus image, without a state
# directory and without a network:
#   promtool check config   the prometheus.yml that setup.sh would render (scripts/monitoring-config.mjs)
#   promtool check rules    docker/alert-rules.yml
#   promtool test rules     docker/alert-rules.test.yml (every rule has a firing and a quiet case:
#                           tests/alert-rules.test.mjs)
#   amtool check-config     the two Alertmanager files setup can render: docker/alertmanager.yml (local
#                           receiver) and docker/alertmanager.slack.yml rendered for a fictional
#                           facility, with a fictional Slack webhook file beside it
# The images are the ones docker/prometheus/Dockerfile and docker/alertmanager/Dockerfile build on, by digest;
# the containers run with --network none. `docker run` pulls an image once if it is not on the host.
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
image=$(sed -n 's/^FROM \(prom\/prometheus:[^ ]*@sha256:[0-9a-f]\{64\}\)$/\1/p' "$root/docker/prometheus/Dockerfile" | tail -n 1)
[[ -n "$image" ]] || { echo 'Could not read the pinned Prometheus image from docker/prometheus/Dockerfile.' >&2; exit 1; }
alertmanager=$(sed -n 's/^FROM \(prom\/alertmanager:[^ ]*@sha256:[0-9a-f]\{64\}\)$/\1/p' "$root/docker/alertmanager/Dockerfile" | tail -n 1)
[[ -n "$alertmanager" ]] || { echo 'Could not read the pinned Alertmanager image from docker/alertmanager/Dockerfile.' >&2; exit 1; }
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
# The two files setup can render: the local-only one as it is, and the Slack one rendered for a fictional facility.
mkdir "$work/local" "$work/slack"
cp "$root/docker/alertmanager.yml" "$work/local/alertmanager.yml"
node --input-type=module - "$root" "$work/slack/alertmanager.yml" <<'NODE'
import { readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';
const [root, out] = process.argv.slice(2);
const { renderSlackConfig } = await import(pathToFileURL(join(root, 'scripts/monitoring-config.mjs')).href);
writeFileSync(out, renderSlackConfig(readFileSync(join(root, 'docker/alertmanager.slack.yml'), 'utf8'), 'warehouse-rules-check', "Fictional Cold Storage's {{ Test }}"));
NODE
printf '%s%s\n' 'https://hooks.slack.com/services/' 'T0000000/B0000000/fictionalfictionalfictional' > "$work/slack/webhook-url" # split so secret scanners do not flag the fictional value
for dir in local slack; do
  docker run --rm --network none --read-only --cap-drop ALL --security-opt no-new-privileges --user "$(id -u):$(id -g)" --entrypoint amtool \
    -v "$work/$dir:/etc/alertmanager:ro" "$alertmanager" check-config /etc/alertmanager/alertmanager.yml
done
echo 'Alert rules, the rendered Prometheus configuration and both Alertmanager files passed promtool and amtool.'
