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
errf="$tmp.err"
trap 'rm -f -- "$tmp" "$errf"' EXIT
# A partial file left by an older run that was killed (its trap never ran) is removed; only ones untouched for an hour, so a live run is spared.
find "$state/bin" -maxdepth 1 -type f -name '.cosign.*' -mmin +60 ! -name "${tmp##*/}" -delete 2>/dev/null || true
# The download gives up only when it STALLS, not when it is slow: curl stops an attempt that runs under 50 KB/s for 60 s in a row (a line that
# moves at 300 KB/s finishes the 146 MB in about 8 minutes). The per-attempt ceiling of 3600 s only bounds a trickle that stays just above that
# floor (146 MB at 50 KB/s takes 2900 s). An attempt that stops part-way is carried on from the byte where it stopped (--continue-at -, into the same
# temporary file); a server that ignores the range (curl exit 33) is started again from zero. The SHA-256 check below is on the finished file.
url="https://github.com/sigstore/cosign/releases/download/$VERSION/$asset"
size_of() { stat -c %s -- "$tmp" 2>/dev/null || echo 0; }
# The whole loop has a deadline of 2 h, checked before each attempt; an attempt's own ceiling is cut to what is left of it.
# A transient failure is retried after a pause of 3 s that grows by 3 s for each attempt in a row that brought nothing (at most 15 s):
# a stalled or reset connection (curl 6, 7, 16, 18, 28, 35, 52, 55, 56, 92) and an HTTP 408, 429 or 5xx. Any other HTTP error (404, 403 ...)
# ends it at once. --fail keeps an error page out of the partial file.
deadline=7200 started=$SECONDS
fails=0 attempts=0 ok='' late='' lastrc=0 lastcode='' lasterr=''
while (( attempts < 30 && fails < 4 )); do
  left=$(( deadline - (SECONDS - started) ))
  if (( left <= 0 )); then late=yes; break; fi
  attempts=$((attempts + 1))
  before="$(size_of)"
  rc=0
  code="$(curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' --tlsv1.2 \
    --connect-timeout 15 --speed-limit 50000 --speed-time 60 --max-time $(( left < 3600 ? left : 3600 )) --continue-at - \
    --write-out '%{http_code}' --output "$tmp" "$url" 2> "$errf")" || rc=$?
  lastrc=$rc lastcode=$code
  if [[ -s "$errf" ]]; then cat "$errf" >&2; lasterr="$(tail -n 1 "$errf")"; lasterr="${lasterr#curl: }"; lasterr="${lasterr#\([0-9]*\) }"; fi
  if (( rc == 0 )); then ok=yes; break; fi
  case "$rc" in
    33) : > "$tmp"; echo "cosign download: the server does not resume a partial file; starting again from the beginning." >&2 ;;
    6|7|16|18|28|35|52|55|56|92) ;;   # a stalled, reset or refused connection: worth another try
    22) case "$code" in
          408|429|5??) ;;             # the server is busy or failing for now
          416)                        # Range not satisfiable: the file may already be whole; the SHA-256 decides
            if [[ "$(sha256sum "$tmp" | cut -d' ' -f1)" == "$want" ]]; then ok=yes; break; fi
            : > "$tmp" ;;
          *) break ;;                 # 404, 403 ...: another try would end the same way
        esac ;;
    *) break ;;                       # a local problem: another try would end the same way
  esac
  # Progress is not a failure: only attempts that brought no new bytes count towards giving up.
  if (( $(size_of) > before )); then fails=0; else fails=$((fails + 1)); fi
  sleep $(( 3 * (fails < 5 ? fails + 1 : 5) ))
done
if [[ "$ok" != yes ]]; then
  # Name what failed, and the one command that works from where the operator is. Run as "git show <release>:scripts/install-cosign.sh | bash -s"
  # (what upgrade-prepull.sh prints during an upgrade) there is no script file; from setup.sh or a checkout there is.
  if [[ -f "${BASH_SOURCE[0]:-}" ]]; then again="bash scripts/install-cosign.sh \"$state\" (from a checkout of the release)"
  else again="the same command again (git show <release>:scripts/install-cosign.sh | bash -s -- \"$state\", as the upgrade printed it)"; fi
  fix='the connection is better'
  if [[ -n "$late" ]]; then why="the 2-hour deadline for the download was reached (last attempt: curl $lastrc, ${lasterr:-no message})"
  else case "$lastrc" in
    22) why="HTTP ${lastcode:-error} from github.com"
        case "$lastcode" in 408|429|5??|'') ;; *) fix='that is fixed' ;; esac ;;
    23) why="cosign could not be written to $state/bin (curl 23: ${lasterr:-write failed}); check the free disk space and that the folder is writable"; fix='that is fixed' ;;
    6|7|16|18|28|35|52|55|56|92) why="the connection stalled, timed out or was refused (curl $lastrc: ${lasterr:-no message})" ;;
    *) why="curl failed (curl $lastrc: ${lasterr:-no message})"; fix='that is fixed' ;;
  esac; fi
  die "cosign $VERSION could not be downloaded: $why. Without cosign the release images will NOT be signature-checked. Run $again once $fix."
fi
echo "$want  $tmp" | sha256sum -c --quiet - || die "the downloaded cosign does not match the pinned SHA-256, so it is not installed."
chmod 755 "$tmp"
mv -f -- "$tmp" "$dest"
echo "Installed cosign $VERSION ($dest), checked against its pinned SHA-256."
