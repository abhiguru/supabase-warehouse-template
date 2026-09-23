#!/usr/bin/env bash

# Supavisor's HTTP health endpoint can precede its PostgreSQL listeners.
# Success still requires the real authenticated query, never health alone.
wait_for_pooler_query() {
  local port="$1" attempt result
  shift
  for ((attempt=1; attempt<=12; attempt++)); do
    if result=$("$@" 2>/dev/null) && [[ "$result" == 1 ]]; then
      return 0
    fi
    if ((attempt < 12)); then sleep 2; fi
  done
  echo "Pooler authenticated query did not become ready on port $port after 12 attempts." >&2
  return 1
}
