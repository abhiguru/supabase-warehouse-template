# Golden PDFs

`corpus/` holds 10 fictional documents (the template's GRN, dispatch, invoice and stock PDFs, and the
English and Gujarati customer-activity, GRN-activity and item-stock reports): `index.html`, `footer.html` where the
document has one, and `options.json`, the options the function passes to `htmlToPdf`. `golden/<case>/page-<n>.png`
are the pages, rasterised at 150 dpi.

`run.sh` renders each case through a running `pdf-renderer`, posting the same fields the function client posts
(`fields.mjs` mirrors `functions/_shared/pdf-renderer-client.ts`; `tests/golden-pdf-fields.test.mjs` fails if the two
disagree) with the case's `options.json` on top. It rasterises the PDF with `pdftoppm` and compares every page with
`golden/` by **decoded pixels** (ImageMagick `compare -metric AE -fuzz 0`: not one pixel may differ), never by PNG
file bytes. On a mismatch the new page, the golden and a diff image are written to `failures/` (ignored by git); the
CI job uploads that folder as the `golden-pdf-failures` artifact.

The rasteriser is byte-stable because `Dockerfile` installs poppler-utils and ImageMagick from a fixed
snapshot.debian.org timestamp. **This is a test container only.** The rule for production images (owner decision D5:
build from the live mirrors, rescan before every release, no snapshot mirrors) does not apply to it, because nothing
from this image ships and its whole purpose is that the same PDF always gives the same pixels. To move to a newer
poppler, change `SNAPSHOT` in the Dockerfile, run `run.sh`, review every page that moved, and regenerate with `--update`.

The `pdf-golden` job in `.github/workflows/ci.yml` runs it on every change. A moved pixel is either a regression or an
intended change (Chrome for Testing pin, puppeteer-core or fonts); in the second case regenerate with
`RENDERER_URL=... bash tests/golden-pdf/run.sh --update`, review the changed pages and commit them. Cases use
fictional data only.
