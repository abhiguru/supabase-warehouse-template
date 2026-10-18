# Golden PDFs

`corpus/` holds 11 fictional documents (the template's GRN, dispatch, invoice, stock and sample PDFs, and the
English and Gujarati customer-activity, GRN-activity and item-stock reports): `index.html`, `footer.html` where the
document has one, and `options.json`, the options the function passes to `htmlToPdf`. `golden/<case>/page-<n>.png`
are the pages, rasterised at 150 dpi.

`run.sh` renders each case through a running `pdf-renderer` (posting exactly the fields of its `options.json`),
rasterises the PDF with the pinned poppler of `Dockerfile` and compares every page with the PNGs in `golden/` byte
for byte (fuzz 0). The `pdf-golden` job in `.github/workflows/ci.yml` runs it on every change. A moved pixel is
either a regression or an intended change (Chrome for Testing pin, puppeteer-core or fonts); in the second case
regenerate with `RENDERER_URL=... bash tests/golden-pdf/run.sh --update`, review the changed pages and commit them.
Failed pages are copied to `failures/` (ignored by git). Cases use fictional data only.
