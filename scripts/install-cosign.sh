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
# A partial file left by an older run that was killed (its trap never ran) is removed; only ones untouched for an hour, so a live run is spared.
find "$state/bin" -maxdepth 1 -type f -name '.cosign.*' -mmin +60 ! -name "${tmp##*/}" -delete 2>/dev/null || true
# The download gives up only when it STALLS, not when it is slow: curl stops an attempt that runs under 50 KB/s for 60 s in a row (a line that
# moves at 300 KB/s finishes the 146 MB in about 8 minutes). The per-attempt ceiling of 3600 s only bounds a trickle that stays just above that
# floor (146 MB at 50 KB/s takes 2900 s). An attempt that stops part-way is carried on from the byte where it stopped (--continue-at -, into the same
# temporary file); a server that ignores the range (curl exit 33) is started again from zero. The SHA-256 check below is on the finished file.
url="https://github.com/sigstore/cosign/releases/download/$VERSION/$asset"
size_of() { stat -c %s -- "$tmp" 2>/dev/null || echo 0; }
fails=0 attempts=0 ok=''
while (( attempts < 30 && fails < 4 )); do
  attempts=$((attempts + 1))
  before="$(size_of)"
  rc=0
  curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' --tlsv1.2 \
    --connect-timeout 15 --speed-limit 50000 --speed-time 60 --max-time 3600 --continue-at - \
    --output "$tmp" "$url" || rc=$?
  if (( rc == 0 )); then ok=yes; break; fi
  case "$rc" in
    33) : > "$tmp"; echo "cosign download: the server does not resume a partial file; starting again from the beginning." >&2 ;;
    6|7|18|28|35|52|55|56) ;;   # a stalled, reset or refused connection: worth another try
    *) break ;;                  # an HTTP error or a local problem: another try would end the same way
  esac
  # Progress is not a failure: only attempts that brought no new bytes count towards giving up.
  if (( $(size_of) > before )); then fails=0; else fails=$((fails + 1)); fi
  sleep 3
done
[[ "$ok" == yes ]] || die "cosign $VERSION could not be downloaded (the connection stalled or was refused). Without cosign the release images will NOT be signature-checked. Run it again when the connection is better: bash scripts/install-cosign.sh \"$state\""
echo "$want  $tmp" | sha256sum -c --quiet - || die "the downloaded cosign does not match the pinned SHA-256, so it is not installed."
chmod 755 "$tmp"
mv -f -- "$tmp" "$dest"
echo "Installed cosign $VERSION ($dest), checked against its pinned SHA-256."
