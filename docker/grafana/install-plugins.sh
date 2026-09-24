#!/bin/sh
set -eu

case "${TARGETARCH:-}" in
  amd64|arm64|arm) ;;
  *) echo "Unsupported Grafana plugin architecture: ${TARGETARCH:-unset}" >&2; exit 1 ;;
esac

base=/usr/share/grafana/data/plugins-bundled
installed=0
while read -r plugin version arch checksum; do
  [ "$arch" = "$TARGETARCH" ] || continue
  archive=$(mktemp /tmp/grafana-plugin.XXXXXX)
  staging=$(mktemp -d /tmp/grafana-plugin.XXXXXX)
  wget -q -O "$archive" "https://grafana.com/api/plugins/$plugin/versions/$version/download?os=linux&arch=$arch"
  printf '%s  %s\n' "$checksum" "$archive" | sha256sum -c -
  unzip -q "$archive" -d "$staging"
  [ -f "$staging/$plugin/MANIFEST.txt" ]
  [ -f "$staging/$plugin/plugin.json" ]
  grep -Eq '"id"[[:space:]]*:[[:space:]]*"'"$plugin"'"' "$staging/$plugin/plugin.json"
  rm -rf "$base/$plugin"
  mv "$staging/$plugin" "$base/$plugin"
  rm -rf "$staging" "$archive"
  installed=$((installed + 1))
done < /tmp/plugins.lock
[ "$installed" -eq 7 ]
