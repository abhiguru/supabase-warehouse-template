#!/usr/bin/env bash
# Golden-PDF check for the PDF renderer: render every fictional case of the corpus through a
# running renderer, rasterise each PDF in the pinned poppler container (tests/golden-pdf/Dockerfile)
# and compare every page byte for byte (fuzz 0) with the committed PNGs.
#
#   RENDERER_URL=http://127.0.0.1:3000 bash tests/golden-pdf/run.sh            compare
#   RENDERER_URL=http://127.0.0.1:3000 bash tests/golden-pdf/run.sh --update   rewrite the goldens
#
# Corpus: tests/golden-pdf/corpus/<case>/index.html, optionally footer.html, header.html and
# fields.txt (one `name=value` per line: paperWidth, landscape, ...). Fictional data only.
# Goldens: tests/golden-pdf/golden/<case>/page-<n>.png (100 dpi). Required on every change to
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
image=pdf-golden-poppler:local
# Image builds on the shared host take the heavy lock (DOCKER_HEAVY_LOCK); CI sets none.
${DOCKER_HEAVY_LOCK:+flock "$DOCKER_HEAVY_LOCK"} docker build -q -t "$image" "$HERE" >/dev/null
shopt -s nullglob
cases=("$CORPUS"/*/)
((${#cases[@]})) || { echo "No corpus cases in $CORPUS." >&2; exit 1; }
failed=0
for dir in "${cases[@]}"; do
  name="$(basename "$dir")"
  args=(-sS --max-time 40 -o "$work/$name.pdf" -w '%{http_code}' -F "files=@$dir/index.html;filename=index.html")
  [[ ! -f "$dir/header.html" ]] || args+=(-F "files=@$dir/header.html;filename=header.html")
  [[ ! -f "$dir/footer.html" ]] || args+=(-F "files=@$dir/footer.html;filename=footer.html")
  if [[ -f "$dir/fields.txt" ]]; then
    while IFS='=' read -r key value; do [[ -z "$key" ]] || args+=(-F "$key=$value"); done < "$dir/fields.txt"
  else
    args+=(-F paperWidth=8.27 -F paperHeight=11.69 -F printBackground=true -F emulatedMediaType=print -F preferCssPageSize=true)
  fi
  status="$(curl "${args[@]}" "$URL/render")"
  [[ "$status" == 200 ]] || { echo "FAIL $name: renderer answered HTTP $status" >&2; failed=1; continue; }
  mkdir -p "$work/png/$name"
  docker run --rm --network none --read-only -v "$work:/w" "$image" -r 100 -png "/w/$name.pdf" "/w/png/$name/page" >/dev/null
  # pdftoppm numbers pages page-1.png or page-01.png by the page count; normalise to page-<n>.png.
  for file in "$work/png/$name"/page-*.png; do
    number="$(basename "$file" .png)"; number="page-$((10#${number#page-}))"
    [[ "$file" == "$work/png/$name/$number.png" ]] || mv "$file" "$work/png/$name/$number.png"
  done
  if [[ "$mode" == update ]]; then
    rm -rf "${GOLDEN:?}/$name"; mkdir -p "$GOLDEN/$name"; cp "$work/png/$name"/page-*.png "$GOLDEN/$name/"
    echo "updated $name ($(ls "$work/png/$name" | wc -l) pages)"
    continue
  fi
  if [[ ! -d "$GOLDEN/$name" ]]; then echo "FAIL $name: no goldens (run with --update and commit them)" >&2; failed=1; continue; fi
  if ! diff -rq "$GOLDEN/$name" "$work/png/$name" >"$work/diff.txt"; then
    echo "FAIL $name: pages differ or the page count changed:" >&2; sed 's/^/  /' "$work/diff.txt" >&2
    mkdir -p "${GOLDEN_FAILURES:-$HERE/failures}/$name"; cp "$work/png/$name"/page-*.png "${GOLDEN_FAILURES:-$HERE/failures}/$name/"
    failed=1
  else
    echo "ok   $name"
  fi
done
exit "$failed"
