#!/bin/bash
# Fills the runtime's module cache (see main/index.ts). Fails the build if the worker does not answer.
set -u
edge-runtime start --main-service /opt/warmup/main -p 9000 >/tmp/warmup.log 2>&1 &
pid=$!
status=1
for _ in $(seq 1 60); do
  if exec 3<>/dev/tcp/127.0.0.1/9000 2>/dev/null; then
    printf 'GET / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n' >&3
    reply=$(cat <&3)
    exec 3>&-
    if grep -q '^HTTP/1.1 200' <<<"$reply" && grep -q 'warm 4 1 function' <<<"$reply"; then status=0; fi
    break
  fi
  sleep 1
done
kill "$pid" 2>/dev/null
wait "$pid" 2>/dev/null
[ "$status" -eq 0 ] || { echo 'edge-runtime warm-up failed:' >&2; cat /tmp/warmup.log >&2; }
exit "$status"
