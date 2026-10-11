#!/usr/bin/env bash
# Sourced helper, not a command. The caller defines compose().
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  echo 'scripts/service-diagnostics.sh is a sourced helper, not a command.' >&2
  exit 1
fi
# Why the start failed: every service that is not running and healthy, with its
# last log lines. `up --wait` itself only names the container.
show_unhealthy_services() {
  local rows service state health
  rows="$(compose ps --all --format '{{.Service}} {{.State}} {{.Health}}' 2>/dev/null)" || return 0
  while read -r service state health; do
    [[ -n "$service" ]] || continue
    if [[ "$state" == running && ( -z "$health" || "$health" == healthy ) ]]; then continue; fi
    echo "Service $service is ${state}${health:+ ($health)}. Its last log lines:" >&2
    compose logs --no-color --tail 30 "$service" 1>&2 || true
  done <<< "$rows"
}
