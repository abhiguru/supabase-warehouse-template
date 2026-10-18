#!/usr/bin/env bash
# Builds the image, runs it with the production hardening flags and checks the real service.
#   test/integration.sh                           build, run, check, clean up
#   IMAGE=pdf-renderer:dev test/integration.sh    use an existing image (skip the build)
# Needs docker, curl and node on the host; pdftotext (poppler-utils) is used when present. Test data is fictional.
# Nothing is printed to a printer. All containers and the network are named pdfr-it-<pid> and removed at the end.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
LOCK="${DOCKER_HEAVY_LOCK:-$HOME/ws/wt-pdf-1018/.docker-heavy.lock}"
SUF="$$"
NET="pdfr-it-net-$SUF"
FAILS=0
TMP="$(mktemp -d)"
CONTAINERS=()
HARDEN=(--read-only --tmpfs /tmp:size=256m --cap-drop ALL --security-opt no-new-privileges --pids-limit 512 --memory 1536m --memory-swap 1536m)

pass() { echo "PASS  $1"; }
fail() { echo "FAIL  $1"; FAILS=$((FAILS + 1)); }
check() { local what="$1"; shift; if "$@" >/dev/null 2>&1; then pass "$what"; else fail "$what"; fi; }
eq() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (got '$2', wanted '$3')"; fi; }
cleanup() {
  for c in "${CONTAINERS[@]}"; do docker rm -f "$c" >/dev/null 2>&1; done
  docker network rm "$NET" >/dev/null 2>&1
  rm -rf "$TMP"
}
trap cleanup EXIT

if [ -z "${IMAGE:-}" ]; then
  IMAGE="pdf-renderer:it-$SUF"
  ( cd "$ROOT" && mkdir -p "$(dirname "$LOCK")" && flock "$LOCK" docker build -t "$IMAGE" \
      --build-arg GIT_SHA="$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || echo unknown)" \
      ${CHS_VERSION:+--build-arg CHS_VERSION="$CHS_VERSION"} ${CHS_SHA256:+--build-arg CHS_SHA256="$CHS_SHA256"} . ) \
    || { echo "FAIL  image build"; exit 1; }
fi

docker network create "$NET" >/dev/null || { echo "FAIL  network"; exit 1; }

# start <name> [extra docker args...]: a renderer with the hardening flags on the test network
start() {
  local name="pdfr-it-$1-$SUF"; shift
  CONTAINERS+=("$name")
  docker run -d --name "$name" --network "$NET" -p 127.0.0.1::3000 "${HARDEN[@]}" "$@" "$IMAGE" >/dev/null || return 1
  echo "$name"
}
port_of() { docker port "$1" 3000/tcp | head -1 | sed 's/.*://'; }
wait_up() { # wait_up <container>: waits for health "up"
  local url="http://127.0.0.1:$(port_of "$1")/health" _
  for _ in $(seq 1 80); do curl -fsS "$url" 2>/dev/null | grep -q '"status":"up"' && return 0; sleep 0.5; done
  return 1
}
health_status() { curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$(port_of "$1")/health"; }
health_json() { curl -s "http://127.0.0.1:$(port_of "$1")/health"; }

post() { # post <container> <out> <code-file> [curl args...]
  local c="$1" out="$2" code="$3"; shift 3
  curl -sS -o "$out" -w '%{http_code}' "$@" "http://127.0.0.1:$(port_of "$c")/render" >"$code" 2>"$TMP/curl.err" || echo 000 >"$code"
}
doc() { echo "-Ffiles=@$1;filename=index.html;type=text/html"; }
is_pdf() { [ "$(head -c 5 "$1")" = "%PDF-" ] && tail -c 64 "$1" | grep -aq '%%EOF'; }
pages() { node -e 'const s=require("fs").readFileSync(process.argv[1]).toString("latin1");console.log((s.match(/\/Type\s*\/Page(?![A-Za-z])/g)||[]).length)' "$1"; }
HAVE_PDFTOTEXT=0; command -v pdftotext >/dev/null 2>&1 && HAVE_PDFTOTEXT=1
ptext() { pdftotext "$1" - 2>/dev/null; }
skip() { echo "SKIP  $1 (pdftotext not installed)"; }

# ---- the listener the renderer must never reach (an IP literal bypasses the host-resolver rule, so it tests interception)
LISTENER="pdfr-it-listener-$SUF"; CONTAINERS+=("$LISTENER")
docker run -d --name "$LISTENER" --network "$NET" -v "$HERE/fixtures:/f:ro" --entrypoint node "$IMAGE" /f/listener.mjs >/dev/null
for _ in $(seq 1 30); do docker logs "$LISTENER" 2>&1 | grep -q LISTENING && break; sleep 0.3; done
LIP="$(docker inspect -f "{{(index .NetworkSettings.Networks \"$NET\").IPAddress}}" "$LISTENER")"
# control: the listener does log a connection that reaches it
docker run --rm --network "$NET" --entrypoint node "$IMAGE" -e "fetch('http://$LIP:8080/control').then(r=>r.text()).then(console.log)" >/dev/null 2>&1
check "listener control: a direct request is logged" bash -c "docker logs $LISTENER 2>&1 | grep -q 'HIT GET /control'"
listener_hits() { docker logs "$LISTENER" 2>&1 | grep -cE '^(CONN|HIT|UPGRADE)'; }
BASE_HITS="$(listener_hits)"
mkdir -p "$TMP/pages"
chmod 755 "$TMP"
for f in hostile-ip hostile-js; do sed "s/@IP@/$LIP/g" "$HERE/fixtures/$f.html" >"$TMP/pages/$f.html"; done

# ===================================================================================================================
MAIN="$(start main)" || { echo "FAIL  container start"; exit 1; }
wait_up "$MAIN" && pass "health reports up" || { fail "health reports up"; docker logs "$MAIN" | tail -20; exit 1; }
check "health has chromium version" bash -c "curl -fsS http://127.0.0.1:$(port_of "$MAIN")/health | grep -q 'HeadlessChrome/'"

# ---- container, as seen from inside ------------------------------------------------------------------------------
check "runs as uid 10001" bash -c "[ \"\$(docker exec $MAIN id -u)\" = 10001 ]"
check "tini is PID 1" bash -c "docker exec $MAIN cat /proc/1/comm | grep -q tini"
check "root file system is read-only" bash -c "! docker exec $MAIN sh -c 'touch /app/x' 2>/dev/null"
check "no npm in the image" bash -c "! docker exec $MAIN sh -c 'command -v npm'"
check "image labels carry CHS and puppeteer-core versions" bash -c "docker inspect $IMAGE --format '{{index .Config.Labels \"pdf-renderer.chs-version\"}} {{index .Config.Labels \"pdf-renderer.puppeteer-core-version\"}}' | grep -Eq '^[0-9.]+ [0-9.]+\$'"
eq "font file list hash is the target's" "$(docker exec "$MAIN" sh -c "fc-list --format '%{file}\n' | LC_ALL=C sort | sha256sum | cut -d' ' -f1")" bb94b4513fc8a1aba5b2d7949632f3fc9311cad45ad288dc204555be0814986d
eq "MALLOC_ARENA_MAX is set" "$(docker exec "$MAIN" printenv MALLOC_ARENA_MAX)" 2

# ---- a fixture render: parameters that reach printToPDF ---------------------------------------------------------------
post "$MAIN" "$TMP/sample.pdf" "$TMP/code" \
  -F "files=@$HERE/fixtures/sample.html;filename=index.html;type=text/html" \
  -F "files=@$HERE/fixtures/footer.html;filename=footer.html;type=text/html" \
  -F paperWidth=8.27 -F paperHeight=11.69 -F marginTop=0.39 -F marginRight=0.55 -F marginBottom=1.0 -F marginLeft=0.55 \
  -F printBackground=true -F emulatedMediaType=print -F preferCssPageSize=true
eq "sample render answers 200" "$(cat "$TMP/code")" 200
check "sample is a complete PDF (%PDF- ... %%EOF)" is_pdf "$TMP/sample.pdf"
eq "sample has 2 pages" "$(pages "$TMP/sample.pdf")" 2
check "sample embeds Liberation Sans" grep -aq 'LiberationSans' "$TMP/sample.pdf"
check "sample is untagged (no /StructTreeRoot, no /MarkInfo)" bash -c "! grep -aq -e '/StructTreeRoot' -e '/MarkInfo' $TMP/sample.pdf"
check "sample page size is A4 (595 x 842 pt)" bash -c "grep -aEq '/MediaBox *\[ *0 +0 +59[45](\.[0-9]*)? +84[12](\.[0-9]*)? *\]' $TMP/sample.pdf"
if [ "$HAVE_PDFTOTEXT" = 1 ]; then
  check "footer shows 'Page 1 of 2'" bash -c "pdftotext -f 1 -l 1 $TMP/sample.pdf - | grep -q 'Page 1 of 2'"
  check "footer shows 'Page 2 of 2'" bash -c "pdftotext -f 2 -l 2 $TMP/sample.pdf - | grep -q 'Page 2 of 2'"
else skip "footer page numbers"; fi
# the same document without a footer uses the 0.55 bottom margin: text sits lower, so the page count can differ; the
# status and untagged output must still hold
post "$MAIN" "$TMP/nofooter.pdf" "$TMP/code" $(doc "$HERE/fixtures/hostile.html") -F landscape=true -F scale=0.9 -F emulatedMediaType=screen -F preferCssPageSize=false
eq "landscape + scale + screen media answers 200" "$(cat "$TMP/code")" 200
check "landscape page is wider than tall" bash -c "grep -aEq '/MediaBox *\[ *0 +0 +84[12](\.[0-9]*)? +59[45](\.[0-9]*)? *\]' $TMP/nofooter.pdf"

# ---- hostile input: nothing may leave the container ---------------------------------------------------------------------
post "$MAIN" "$TMP/hostile.pdf" "$TMP/code" $(doc "$HERE/fixtures/hostile.html")
eq "remote img/link/script/iframe: render still answers 200" "$(cat "$TMP/code")" 200
check "hostile result is a PDF" is_pdf "$TMP/hostile.pdf"
check "inline script did not run (title unchanged)" bash -c "grep -aq 'static-title' $TMP/hostile.pdf && ! grep -aq 'SCRIPT-HAS-RUN' $TMP/hostile.pdf"
post "$MAIN" "$TMP/hip.pdf" "$TMP/code" $(doc "$TMP/pages/hostile-ip.html")
eq "IP-literal hostile page (img, srcset, poster, svg, object, embed, iframes, @import, font, background, refresh): 200" "$(cat "$TMP/code")" 200
eq "listener saw no connection from the renderer (JS off, intercept)" "$(( $(listener_hits) - BASE_HITS ))" 0
post "$MAIN" "$TMP/df.pdf" "$TMP/code" $(doc "$HERE/fixtures/dataframe.html")
eq "data: frame document answers 200" "$(cat "$TMP/code")" 200
if [ "$HAVE_PDFTOTEXT" = 1 ]; then
  check "outer text is rendered" bash -c "pdftotext $TMP/df.pdf - | grep -q OUTER-MARKER"
  check "data: iframe is blocked by the Content-Security-Policy" bash -c "! pdftotext $TMP/df.pdf - | grep -q DATA-FRAME-MARKER"
else skip "data: iframe blocked"; fi

# ---- 400 cases ------------------------------------------------------------------------------------------------------------
post "$MAIN" "$TMP/o" "$TMP/code" -F "files=@$HERE/fixtures/sample.html;filename=other.html"; eq "unknown file name gives 400" "$(cat "$TMP/code")" 400
post "$MAIN" "$TMP/o" "$TMP/code" $(doc "$HERE/fixtures/sample.html") -F scale=9; eq "scale 9 gives 400" "$(cat "$TMP/code")" 400
post "$MAIN" "$TMP/o" "$TMP/code" $(doc "$HERE/fixtures/sample.html") -F pdfa=PDF/A-1b; eq "unknown field gives 400" "$(cat "$TMP/code")" 400
post "$MAIN" "$TMP/o" "$TMP/code" -F "other=1"; eq "missing index.html gives 400" "$(cat "$TMP/code")" 400
check "error body is JSON with error and code" bash -c "grep -q '\"error\"' $TMP/o && grep -q '\"code\":400' $TMP/o"

# ---- 413: 48 MiB + 1 byte, by header --------------------------------------------------------------------------------------
head -c $((48 * 1024 * 1024 + 1)) /dev/zero >"$TMP/huge"
post "$MAIN" "$TMP/o" "$TMP/code" -H 'Content-Type: multipart/form-data; boundary=x' --data-binary "@$TMP/huge"
eq "48 MiB + 1 body gives 413" "$(cat "$TMP/code")" 413
rm -f "$TMP/huge"
check "bytes released after the 413" bash -c "curl -fsS http://127.0.0.1:$(port_of "$MAIN")/health | grep -q '\"inflightBytes\":0'"

# ---- nothing left behind, nothing crashed ----------------------------------------------------------------------------------------
check "health still up" bash -c "curl -fsS http://127.0.0.1:$(port_of "$MAIN")/health | grep -q '\"status\":\"up\"'"
check "no files left in /tmp/jobs" bash -c "[ -z \"\$(docker exec $MAIN ls -A /tmp/jobs)\" ]"
eq "exactly one profile directory in /tmp/profiles" "$(docker exec "$MAIN" ls -A /tmp/profiles | wc -l)" 1
check "no browser restarts" bash -c "curl -fsS http://127.0.0.1:$(port_of "$MAIN")/health | grep -q '\"restarts\":0'"
check "cold first render was logged" bash -c "docker logs $MAIN 2>&1 | grep -q '\"cold\":true'"

# ---- health probe: a hung Chrome (SIGSTOP) must show as down, and a CONT or a kill must recover -----------------------------------
CPID="$(docker logs "$MAIN" 2>&1 | grep '"event":"launch"' | tail -1 | sed 's/.*"pid":\([0-9]*\).*/\1/')"
sig() { docker exec "$MAIN" node -e "process.kill($CPID, '$1')"; }
sig SIGSTOP
DOWN=0
for _ in $(seq 1 24); do [ "$(health_status "$MAIN")" = 503 ] && { DOWN=1; break; }; sleep 0.5; done
[ "$DOWN" = 1 ] && pass "SIGSTOPped Chrome: /health answers 503 within 12 s" || fail "SIGSTOPped Chrome: /health answers 503 within 12 s"
check "the down answer says status down" bash -c "curl -s http://127.0.0.1:$(port_of "$MAIN")/health | grep -q '\"status\":\"down\"'"
sig SIGCONT
UP=0; for _ in $(seq 1 24); do [ "$(health_status "$MAIN")" = 200 ] && { UP=1; break; }; sleep 0.5; done
[ "$UP" = 1 ] && pass "SIGCONT: /health recovers to 200" || fail "SIGCONT: /health recovers to 200"
eq "SIGCONT recovery needed no relaunch" "$(health_json "$MAIN" | sed 's/.*"restarts":\([0-9]*\).*/\1/')" 0
sig SIGSTOP
REPLACED=0
for _ in $(seq 1 120); do
  if health_json "$MAIN" | grep -q '"status":"up"' && [ "$(health_json "$MAIN" | sed 's/.*"restarts":\([0-9]*\).*/\1/')" -ge 1 ]; then REPLACED=1; break; fi
  sleep 0.5
done
[ "$REPLACED" = 1 ] && pass "a Chrome that stays stopped is killed and replaced; /health is 200 again" || fail "a Chrome that stays stopped is killed and replaced"
post "$MAIN" "$TMP/after.pdf" "$TMP/code" $(doc "$HERE/fixtures/sample.html"); eq "render works on the replacement browser" "$(cat "$TMP/code")" 200
check "the stopped Chrome's profile was removed" bash -c "[ \"\$(docker exec $MAIN ls -A /tmp/profiles | wc -l)\" = 1 ]"

# ===================================================================================================================
# JS on: scripts run, and still nothing can leave the container (fetch, XHR, WebSocket, beacon, image, open, EventSource)
JS="$(start js -e RENDERER_JS=on)"; wait_up "$JS" || fail "js container up"
post "$JS" "$TMP/js.pdf" "$TMP/code" $(doc "$TMP/pages/hostile-js.html")
eq "JS-on hostile page answers 200" "$(cat "$TMP/code")" 200
check "JS-on: the script did run (title changed)" grep -aq 'SCRIPT-HAS-RUN' "$TMP/js.pdf"
post "$JS" "$TMP/o" "$TMP/code" $(doc "$TMP/pages/hostile-ip.html"); eq "JS-on IP-literal page answers 200" "$(cat "$TMP/code")" 200
docker logs "$JS" 2>&1 | grep -E '"code":5' | tail -3
eq "listener saw no connection from the renderer (JS on)" "$(( $(listener_hits) - BASE_HITS ))" 0

# File mode: the document goes through /tmp/jobs; only that file and data: may load
FM="$(start file -e RENDERER_LOAD=file)"; wait_up "$FM" || fail "file-mode container up"
check "file mode is active" bash -c "docker logs $FM 2>&1 | grep -q '\"load\":\"file\"'"
post "$FM" "$TMP/fm.pdf" "$TMP/code" \
  -F "files=@$HERE/fixtures/sample.html;filename=index.html;type=text/html" -F "files=@$HERE/fixtures/footer.html;filename=footer.html;type=text/html"
eq "file mode: sample answers 200" "$(cat "$TMP/code")" 200
eq "file mode: sample has 2 pages" "$(pages "$TMP/fm.pdf")" 2
post "$FM" "$TMP/o" "$TMP/code" $(doc "$TMP/pages/hostile-ip.html"); eq "file mode: hostile page answers 200" "$(cat "$TMP/code")" 200
post "$FM" "$TMP/o" "$TMP/code" $(doc "$HERE/fixtures/hostile.html"); eq "file mode: file:// iframe page answers 200" "$(cat "$TMP/code")" 200
eq "listener saw no connection from the renderer (file mode)" "$(( $(listener_hits) - BASE_HITS ))" 0
check "file mode: /tmp/jobs is empty afterwards" bash -c "[ -z \"\$(docker exec $FM ls -A /tmp/jobs)\" ]"

# ===================================================================================================================
# A plain `fetch` client (Node 24, no Expect header) must READ the refusals while it is still uploading
node "$HERE/fixtures/gen-big.mjs" "$TMP/big.html" 22 && chmod 644 "$TMP/big.html"
RF="$(start refuse -e CONCURRENCY=1 -e MAX_QUEUE=1)"; wait_up "$RF" || fail "refusal container up"
RFNAME="$RF"
docker run --rm --network "$NET" -v "$HERE/fixtures:/f:ro" -v "$TMP:/data:ro" --entrypoint node "$IMAGE" /f/client.mjs "http://$RFNAME:3000" /data/big.html > "$TMP/client.out" 2>&1
RC=$?
cat "$TMP/client.out" | sed 's/^/      /'
eq "fetch client refusal checks (queue 503, 413 by header, 400 content type)" "$RC" 0

# ===================================================================================================================
# SIGTERM during a ~30 MB render: the client must receive the complete PDF and the process must exit 0
TM="$(start term)"; wait_up "$TM" || fail "term container up"
( curl -sS -o "$TMP/term.pdf" -D "$TMP/term.hdr" -w '%{http_code} %{size_download}' -F "files=@$TMP/big.html;filename=index.html" "http://127.0.0.1:$(port_of "$TM")/render" >"$TMP/term.res" 2>"$TMP/term.err" ) &
CURLPID=$!
for _ in $(seq 1 100); do curl -s "http://127.0.0.1:$(port_of "$TM")/health" | grep -q '"queue":0' && docker exec "$TM" sh -c 'ls /tmp/jobs | grep -q .' 2>/dev/null && break; sleep 0.1; done
docker stop -t 30 "$TM" >/dev/null 2>&1
wait "$CURLPID"
read -r TCODE TSIZE <"$TMP/term.res"
eq "SIGTERM during a render: client got 200" "$TCODE" 200
TLEN="$(grep -i '^content-length:' "$TMP/term.hdr" | tr -d '\r' | awk '{print $2}')"
eq "SIGTERM during a render: Content-Length matches the bytes received" "$TSIZE" "$TLEN"
check "SIGTERM during a render: the PDF is complete (%%EOF)" is_pdf "$TMP/term.pdf"
check "response is at least 25 MB (large enough to expose truncation)" bash -c "[ ${TSIZE:-0} -ge 25000000 ]"
check "the job finished after the signal arrived" bash -c "docker logs $TM 2>&1 | awk '/\"event\":\"signal\"/{s=1} s && /\"event\":\"job\"/ && /\"outcome\":\"ok\"/{f=1} END{exit !f}'"
eq "SIGTERM exits 0" "$(docker inspect "$TM" --format '{{.State.ExitCode}}')" 0

# ---- the main container stops cleanly too ----------------------------------------------------------------------------------------------
docker stop -t 30 "$MAIN" >/dev/null 2>&1
eq "SIGTERM (idle) exits 0" "$(docker inspect "$MAIN" --format '{{.State.ExitCode}}')" 0

echo
if [ "$FAILS" = 0 ]; then echo "integration: all checks passed"; else echo "integration: $FAILS check(s) failed"; fi
exit "$FAILS"
