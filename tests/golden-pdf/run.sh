#!/usr/bin/env bash
# Golden-PDF check for the PDF renderer: render every fictional case of the corpus through a
# running renderer, rasterise each PDF in the pinned poppler container (tests/golden-pdf/Dockerfile)
# and compare every page by decoded pixels (ImageMagick `compare -metric AE -fuzz 0`: no pixel may differ) with the
# committed PNGs. The container is built from a fixed Debian snapshot (see its Dockerfile), so the rasteriser is stable.
#
#   RENDERER_URL=http://127.0.0.1:3000 bash tests/golden-pdf/run.sh            compare
#   RENDERER_URL=http://127.0.0.1:3000 bash tests/golden-pdf/run.sh --update   rewrite the goldens
#
# Corpus: tests/golden-pdf/corpus/<case>/index.html, options.json (the options the function passed to
# htmlToPdf; posted together with the client's default fields, see fields.mjs) and footer.html / header.html where the case has one. Fictional data only.
# Goldens: tests/golden-pdf/golden/<case>/page-<n>.png (150 dpi). Required on every change to
# the Chrome for Testing pin, puppeteer-core or the fonts (docs/CONTAINER_SECURITY.md).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORPUS="${CORPUS_DIR:-$HERE/corpus}"
GOLDEN="${GOLDEN_DIR:-$HERE/golden}"
URL="${RENDERER_URL:?Set RENDERER_URL, for example http://127.0.0.1:3000}"
mode=compare
[[ "${1:-}" != --update ]] || mode=update
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
image=pdf-golden-tools:local
# Image builds on the shared host take the heavy lock (DOCKER_HEAVY_LOCK); CI sets none.
${DOCKER_HEAVY_LOCK:+flock "$DOCKER_HEAVY_LOCK"} docker build -q -t "$image" "$HERE" >/dev/null
shopt -s nullglob
cases=("$CORPUS"/*/)
((${#cases[@]})) || { echo "No corpus cases in $CORPUS." >&2; exit 1; }
FAILURES="${GOLDEN_FAILURES:-$HERE/failures}"
rm -rf "$FAILURES"
failed=0
mkdir -p "$GOLDEN" "$work/failures"
for dir in "${cases[@]}"; do
  name="$(basename "$dir")"
  args=(-sS --max-time 40 -o "$work/$name.pdf" -w '%{http_code}' -F "files=@$dir/index.html;filename=index.html")
  [[ ! -f "$dir/header.html" ]] || args+=(-F "files=@$dir/header.html;filename=header.html")
  [[ ! -f "$dir/footer.html" ]] || args+=(-F "files=@$dir/footer.html;filename=footer.html")
  # The same fields the functions send (tests/golden-pdf/fields.mjs mirrors pdf-renderer-client.ts), with options.json on top.
  while IFS= read -r field; do [[ -z "$field" ]] || args+=(-F "$field"); done < <(node "$HERE/fields.mjs" "$dir/options.json")
  status="$(curl "${args[@]}" "$URL/render")"
  [[ "$status" == 200 ]] || { echo "FAIL $name: renderer answered HTTP $status" >&2; failed=1; continue; }
  golden_mount="$GOLDEN:/golden:ro"; [[ "$mode" != update ]] || golden_mount="$GOLDEN:/golden"
  # Rasterise and compare decoded pixels in the pinned container (compare-case.sh): no network, read-only root.
  docker run --rm --network none --read-only --tmpfs /tmp -u "$(id -u):$(id -g)" -v "$work:/w" -v "$golden_mount" \
    --entrypoint /usr/local/bin/compare-case "$image" "$name" "$mode" || failed=1
done
if [[ -d "$work/failures" ]] && [[ -n "$(ls -A "$work/failures")" ]]; then mkdir -p "$FAILURES"; cp -r "$work/failures/." "$FAILURES/"; echo "Pages that moved (new, golden, diff) are in $FAILURES" >&2; fi
exit "$failed"
