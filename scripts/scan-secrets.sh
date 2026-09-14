#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
scratch=$(mktemp -d "${TMPDIR:-/tmp}/warehouse-secret-scan.XXXXXX")
trap 'rm -rf "$scratch"' EXIT
curl --fail --silent --show-error --location \
  --connect-timeout 15 --max-time 120 --retry 3 --retry-max-time 180 \
  https://github.com/gitleaks/gitleaks/releases/download/v8.30.1/gitleaks_8.30.1_linux_x64.tar.gz \
  --output "$scratch/gitleaks.tar.gz"
echo "551f6fc83ea457d62a0d98237cbad105af8d557003051f41f3e7ca7b3f2470eb  $scratch/gitleaks.tar.gz" | sha256sum -c -
tar -xzf "$scratch/gitleaks.tar.gz" -C "$scratch" gitleaks
mkdir "$scratch/source"
git -C "$ROOT" archive HEAD | tar -xf - -C "$scratch/source"
"$scratch/gitleaks" dir "$scratch/source" --redact --no-banner
"$scratch/gitleaks" git "$ROOT" --redact --no-banner --log-opts=--all --gitleaks-ignore-path "$ROOT/.gitleaksignore"
