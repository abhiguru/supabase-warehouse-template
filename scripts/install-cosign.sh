#!/usr/bin/env bash
# Installs cosign, the tool that checks the signatures of the release images (scripts/verify-image-signature.sh), into the operator state:
#   bash scripts/install-cosign.sh [STATE_DIR]      (default: $WAREHOUSE_STATE_DIR)  ->  <state>/bin/cosign
# setup.sh runs it for a release whose tree has docker/images-signed. It needs no root: the binary lives in the state, not in /usr/local/bin.
# The official release binary for this architecture is downloaded from github.com/sigstore/cosign and installed only when its SHA-256 equals
# the value pinned below (read from cosign_checksums.txt of the release on 2026-11-07). Moving the version means moving the checksums with it.
set -euo pipefail
umask 022
VERSION=v3.1.4
SHA_AMD64=424e2c97d0b45fd7a6b608a87f090f35633f4c23ece5f092d48bba11aaf4bbfa
SHA_ARM64=ade83b7aac62e131cacfe96d958948b2150cc9efec46a570a2649b8e27dedad2
die() { echo "Refusing: $*" >&2; exit 1; }
state="${1:-${WAREHOUSE_STATE_DIR:-}}"
[[ "$state" == /* && -d "$state" ]] || die 'give the absolute path of the operator state (or set WAREHOUSE_STATE_DIR).'
case "$(uname -m 2>/dev/null || true)" in
  x86_64|amd64) asset=cosign-linux-amd64; want="$SHA_AMD64" ;;
  aarch64|arm64) asset=cosign-linux-arm64; want="$SHA_ARM64" ;;
  *) die "cosign has no pinned checksum for this architecture ($(uname -m 2>/dev/null || echo unknown))." ;;
esac
command -v curl >/dev/null || die 'curl is not installed.'
command -v sha256sum >/dev/null || die 'sha256sum is not installed.'
dest="$state/bin/cosign"
if [[ -f "$dest" && ! -L "$dest" ]] && [[ "$(sha256sum "$dest" | cut -d' ' -f1)" == "$want" ]]; then
  echo "cosign $VERSION is already installed ($dest)."
  exit 0
fi
install -d -m 755 "$state/bin"
tmp="$(mktemp "$state/bin/.cosign.XXXXXX")" || die "a temporary file cannot be made in $state/bin."
trap 'rm -f -- "$tmp"' EXIT
curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' --tlsv1.2 --connect-timeout 15 --max-time 300 --retry 3 \
  --output "$tmp" "https://github.com/sigstore/cosign/releases/download/$VERSION/$asset" || die "cosign $VERSION could not be downloaded."
echo "$want  $tmp" | sha256sum -c --quiet - || die "the downloaded cosign does not match the pinned SHA-256, so it is not installed."
chmod 755 "$tmp"
mv -f -- "$tmp" "$dest"
echo "Installed cosign $VERSION ($dest), checked against its pinned SHA-256."
