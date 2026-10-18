# Golden PDFs

TODO: the fictional corpus has not been added yet. Until `corpus/` exists, the `pdf-golden` job in
`.github/workflows/ci.yml` is skipped.

`run.sh` renders each case in `corpus/` through a running `pdf-renderer`, rasterises the PDF with the pinned
poppler of `Dockerfile` and compares the pages with the PNGs in `golden/` byte for byte (fuzz 0). It is required on
every change to the Chrome for Testing pin, puppeteer-core or the fonts: a moved pixel is either a regression or a
reviewed, intended change, in which case regenerate with `--update` and review the changed pages in the pull request.
Cases use fictional data only. See the header of `run.sh` for the layout.
