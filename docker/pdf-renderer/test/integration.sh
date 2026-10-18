#!/usr/bin/env bash
# Builds the image, runs it with the production hardening flags and checks the real service.
#   test/integration.sh                 build, run, check, clean up
#   IMAGE=pdf-renderer:dev test/integration.sh   use an existing image (skip the build)
# Needs docker, curl and node on the host. Test data is fictional. Nothing is printed to a printer.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
LOCK="${DOCKER_HEAVY_LOCK:-$HOME/ws/wt-pdf-1018/.docker-heavy.lock}"
NAME="pdfr-it-$$"
FAILS=0
CONTAINER_STARTED=0
TMP="$(mktemp -d)"

pass() { echo "PASS  $1"; }
fail() { echo "FAIL  $1"; FAILS=$((FAILS + 1)); }
check() { # check "description" command...
  local what="$1"; shift
  if "$@" >/dev/null 2>&1; then pass "$what"; else fail "$what"; fi
}
cleanup() {
  if [ "$CONTAINER_STARTED" = 1 ]; then docker rm -f "$NAME" >/dev/null 2>&1; fi
  rm -rf "$TMP"
}
trap cleanup EXIT

if [ -z "${IMAGE:-}" ]; then
  IMAGE="pdf-renderer:it-$$"
  BUILT=1
  ( cd "$ROOT" && mkdir -p "$(dirname "$LOCK")" && flock "$LOCK" docker build -t "$IMAGE" \
      --build-arg GIT_SHA="$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || echo unknown)" \
      ${CHS_VERSION:+--build-arg CHS_VERSION="$CHS_VERSION"} ${CHS_SHA256:+--build-arg CHS_SHA256="$CHS_SHA256"} . ) \
    || { echo "FAIL  image build"; exit 1; }
fi

docker run -d --name "$NAME" -p 127.0.0.1::3000 \
  --read-only --tmpfs /tmp:size=256m --cap-drop ALL --security-opt no-new-privileges \
  --pids-limit 512 --memory 1g --memory-swap 1g "$IMAGE" >/dev/null || { echo "FAIL  container start"; exit 1; }
CONTAINER_STARTED=1
PORT="$(docker port "$NAME" 3000/tcp | head -1 | sed 's/.*://')"
URL="http://127.0.0.1:$PORT"

# ---- health ------------------------------------------------------------------------------------------
UP=0
for _ in $(seq 1 60); do
  if curl -fsS "$URL/health" 2>/dev/null | grep -q '"status":"up"'; then UP=1; break; fi
  sleep 0.5
done
[ "$UP" = 1 ] && pass "health reports up" || { fail "health reports up"; docker logs "$NAME" | tail -20; exit 1; }
check "health has chromium version" bash -c "curl -fsS $URL/health | grep -q 'HeadlessChrome/'"

# ---- container hardening, as seen from inside -----------------------------------------------------------
check "runs as uid 10001" bash -c "[ \"\$(docker exec $NAME id -u)\" = 10001 ]"
check "tini is PID 1" bash -c "docker exec $NAME cat /proc/1/comm | grep -q tini"
check "root file system is read-only" bash -c "! docker exec $NAME sh -c 'touch /app/x' 2>/dev/null"
check "no npm in the image" bash -c "! docker exec $NAME sh -c 'command -v npm'"
check "image labels carry CHS and puppeteer-core versions" bash -c "docker inspect $IMAGE --format '{{index .Config.Labels \"pdf-renderer.chs-version\"}} {{index .Config.Labels \"pdf-renderer.puppeteer-core-version\"}}' | grep -Eq '^[0-9.]+ [0-9.]+\$'"

post() { # post <out> <status-file> [curl args...]
  local out="$1" code="$2"; shift 2
  curl -sS -o "$out" -w '%{http_code}' "$@" "$URL/render" >"$code" 2>"$TMP/curl.err" || echo 000 >"$code"
}
is_pdf() { [ "$(head -c 5 "$1")" = "%PDF-" ] && tail -c 64 "$1" | grep -aq '%%EOF'; }
pages() { node -e 'const s=require("fs").readFileSync(process.argv[1]).toString("latin1");console.log((s.match(/\/Type\s*\/Page(?![A-Za-z])/g)||[]).length)' "$1"; }

# ---- a fixture render -----------------------------------------------------------------------------------
post "$TMP/sample.pdf" "$TMP/code" \
  -F "files=@$HERE/fixtures/sample.html;filename=index.html;type=text/html" \
  -F "files=@$HERE/fixtures/footer.html;filename=footer.html;type=text/html" \
  -F paperWidth=8.27 -F paperHeight=11.69 -F marginTop=0.39 -F marginRight=0.55 -F marginBottom=1.0 -F marginLeft=0.55 \
  -F printBackground=true -F emulatedMediaType=print -F preferCssPageSize=true
[ "$(cat "$TMP/code")" = 200 ] && pass "sample render answers 200" || fail "sample render answers 200 (got $(cat "$TMP/code"))"
check "sample is a complete PDF (%PDF- ... %%EOF)" is_pdf "$TMP/sample.pdf"
[ "$(pages "$TMP/sample.pdf")" = 2 ] && pass "sample has 2 pages" || fail "sample has 2 pages (got $(pages "$TMP/sample.pdf"))"
check "sample embeds Liberation Sans" grep -aq 'LiberationSans' "$TMP/sample.pdf"
check "sample is untagged" bash -c "! grep -aq '/MarkInfo' $TMP/sample.pdf"

# ---- hostile input: blocked network, scripts off, render still succeeds ------------------------------------
post "$TMP/hostile.pdf" "$TMP/code" -F "files=@$HERE/fixtures/hostile.html;filename=index.html;type=text/html"
[ "$(cat "$TMP/code")" = 200 ] && pass "remote img/link/script/iframe: render still answers 200" || fail "hostile render answers 200 (got $(cat "$TMP/code"))"
check "hostile result is a PDF" is_pdf "$TMP/hostile.pdf"
check "inline script did not run (title unchanged)" bash -c "grep -aq 'static-title' $TMP/hostile.pdf && ! grep -aq 'SCRIPT-HAS-RUN' $TMP/hostile.pdf"
check "no request left the container for the remote host" bash -c "! docker logs $NAME 2>&1 | grep -aiq 'example.invalid'"

# ---- 400 cases ------------------------------------------------------------------------------------------
post "$TMP/o" "$TMP/code" -F "files=@$HERE/fixtures/sample.html;filename=other.html"
[ "$(cat "$TMP/code")" = 400 ] && pass "unknown file name gives 400" || fail "unknown file name gives 400 (got $(cat "$TMP/code"))"
post "$TMP/o" "$TMP/code" -F "files=@$HERE/fixtures/sample.html;filename=index.html" -F scale=9
[ "$(cat "$TMP/code")" = 400 ] && pass "scale 9 gives 400" || fail "scale 9 gives 400 (got $(cat "$TMP/code"))"
post "$TMP/o" "$TMP/code" -F "files=@$HERE/fixtures/sample.html;filename=index.html" -F pdfa=PDF/A-1b
[ "$(cat "$TMP/code")" = 400 ] && pass "unknown field gives 400" || fail "unknown field gives 400 (got $(cat "$TMP/code"))"
post "$TMP/o" "$TMP/code" -F "other=1"
[ "$(cat "$TMP/code")" = 400 ] && pass "missing index.html gives 400" || fail "missing index.html gives 400 (got $(cat "$TMP/code"))"
check "error body is JSON with error and code" bash -c "grep -q '\"error\"' $TMP/o && grep -q '\"code\":400' $TMP/o"

# ---- 413: 48 MB + 1 byte -----------------------------------------------------------------------------------
head -c $((48 * 1024 * 1024 + 1)) /dev/zero >"$TMP/huge"
post "$TMP/o" "$TMP/code" -H 'Content-Type: multipart/form-data; boundary=x' --data-binary "@$TMP/huge"
[ "$(cat "$TMP/code")" = 413 ] && pass "48 MB + 1 body gives 413" || fail "48 MB + 1 body gives 413 (got $(cat "$TMP/code"); $(cat "$TMP/curl.err"))"
rm -f "$TMP/huge"
curl -fsS "$URL/health" | grep -q '"inflightBytes":0' && pass "bytes released after the 413" || fail "bytes released after the 413"

# ---- still healthy, nothing left behind, nothing crashed -----------------------------------------------------------
check "health still up" bash -c "curl -fsS $URL/health | grep -q '\"status\":\"up\"'"
check "no files left in /tmp/jobs" bash -c "[ -z \"\$(docker exec $NAME ls -A /tmp/jobs)\" ]"
check "exactly one profile directory in /tmp/profiles" bash -c "[ \"\$(docker exec $NAME ls -A /tmp/profiles | wc -l)\" = 1 ]"
check "no browser restarts" bash -c "curl -fsS $URL/health | grep -q '\"restarts\":0'"
check "cold first render was logged" bash -c "docker logs $NAME 2>&1 | grep -q '\"cold\":true'"

# ---- graceful stop -----------------------------------------------------------------------------------------------
docker stop -t 30 "$NAME" >/dev/null 2>&1
[ "$(docker inspect "$NAME" --format '{{.State.ExitCode}}')" = 0 ] && pass "SIGTERM exits 0" || fail "SIGTERM exits 0 (got $(docker inspect "$NAME" --format '{{.State.ExitCode}}'))"

echo
if [ "$FAILS" = 0 ]; then echo "integration: all checks passed"; else echo "integration: $FAILS check(s) failed"; fi
exit "$FAILS"
