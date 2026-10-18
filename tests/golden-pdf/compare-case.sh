#!/bin/sh
# Runs inside the golden container (tests/golden-pdf/Dockerfile) for one case.
#   compare-case <name> compare|update
# /w/<name>.pdf is the rendered PDF; /golden/<name>/page-<n>.png are the goldens (read-only in compare mode,
# writable in update mode); /w/failures/<name>/ receives what moved.
# Pages are rasterised at 150 dpi and compared by DECODED PIXELS (`compare -metric AE -fuzz 0`: the number of pixels
# that differ at all), never by the bytes of the PNG files, which may differ for identical pictures.
set -eu
name="$1"; mode="$2"
out="/w/png/$name"
mkdir -p "$out"
pdftoppm -r 150 -png "/w/$name.pdf" "$out/page"
# pdftoppm pads the page number to the width of the page count (page-1 or page-01); normalise to page-<n>.png
for file in "$out"/page-*.png; do
  number="${file##*/page-}"; number="${number%.png}"
  number=$(printf '%s' "$number" | sed 's/^0*//')
  [ "$file" = "$out/page-$number.png" ] || mv "$file" "$out/page-$number.png"
done
if [ "$mode" = update ]; then
  rm -rf "/golden/$name"; mkdir -p "/golden/$name"; cp "$out"/page-*.png "/golden/$name/"
  echo "updated $name ($(ls "$out" | wc -l) pages)"
  exit 0
fi
[ -d "/golden/$name" ] || { echo "FAIL $name: no goldens (run with --update and commit them)"; exit 1; }
want=$(ls "/golden/$name" | wc -l); got=$(ls "$out" | wc -l)
status=0
if [ "$want" != "$got" ]; then echo "FAIL $name: $got pages, the goldens have $want"; status=1; fi
fail="/w/failures/$name"
for golden in /golden/"$name"/page-*.png; do
  page="${golden##*/}"
  if [ ! -f "$out/$page" ]; then continue; fi
  # AE prints the count of differing pixels on stderr; a size difference is an error (status 2) and counts as different.
  diff_count=$(compare -metric AE -fuzz 0 "$golden" "$out/$page" "/w/diff.png" 2>&1 || true)
  case "$diff_count" in 0|"0 (0)") ;; *)
    echo "FAIL $name $page: $diff_count pixel(s) differ"
    mkdir -p "$fail"; cp "$out/$page" "$fail/${page%.png}-new.png"; cp "$golden" "$fail/${page%.png}-golden.png"
    [ -f /w/diff.png ] && mv /w/diff.png "$fail/${page%.png}-diff.png"
    status=1 ;;
  esac
  rm -f /w/diff.png
done
[ "$status" = 0 ] && echo "ok   $name"
exit "$status"
