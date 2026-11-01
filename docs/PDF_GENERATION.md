# PDF generation

The operator branch implements four mobile endpoints:

| Endpoint | POST body |
| --- | --- |
| generate-grn-pdf | `{ "gr_no": "..." }` |
| generate-dispatch-pdf | `{ "disp_no": "..." }` |
| generate-invoice-pdf | `{ "inv_no": 1, "fin_year": 2026 }` |
| generate-customer-stock-pdf | `{ "customer_id": "<uuid>" }` |

Each requires a valid, active custom user session and returns
`{ success, pdf_url, expires_in, document }`. Customer access follows assignment
RLS. A document outside the caller's scope returns 404. The business reads use
the caller JWT; the server key reads the warehouse branding setting and performs
the subsequent private upload.

`generate-report-pdf` renders one of the seven report screens
(`{ "report": "...", "customer_id"?, "from"?, "to"?, "sort"?, "lang"?, "status"?, "invoicing"?, "bucket"?, "search"? }`;
`status` is `paid` or `pending` and only for the invoice history of one
customer; `invoicing` is `invoiced` or `not_invoiced` and only for the GRN
activity of one customer; `bucket` is `0-120`, `121-240`, `241-364` or
`over-364` and only for the stock aging of one customer; `search` is text of
at most 80 characters after trimming, without control characters, and only for
the item stock summary (a blank search is none). `null` is the same as leaving
a field out. A field on another report, without the customer it needs, or with
another value is refused with 400 and a fixed message that never repeats the
value. `status`, `invoicing` and `bucket` drop the other rows after the RPC
answered and the summary is worked out from the rows listed; `search` goes to
the item RPC as `p_search_query`. Each choice prints a line under the title;
`status`, `invoicing` and `bucket` are echoed in the answer's `document`, the
search never is. The full contract is in the CHANGELOG entries for migration
53, for `status` and for these three fields; the `weight` sort field of grn-activity and stock-summary that entry lists no longer exists, and a request naming it falls back to the report's default sort: the parser still accepts the name and `buildReport` uses `defaultSort`). It reads the
report's existing RPC with the caller JWT, so the RPC guard decides access
(a refusal is 403, an unknown customer 404), prints at most 2000 rows with a
note when cut, and returns the same `{ success, pdf_url, expires_in, document }`
answer with `document.type = "report"`. Code: `functions/_shared/report-*.ts`.

The `pdf-renderer` service (`docker/pdf-renderer`: chrome-headless-shell driven by
puppeteer-core) renders escaped HTML with a restrictive
content policy: JavaScript is off, and every network request the page makes is
refused. The functions call `POST /render`
(`functions/_shared/pdf-renderer-client.ts`, URL from `PDF_RENDERER_URL`, default
`http://pdf-renderer:3000`). A render has a 30 s client timeout and a 25 s
renderer deadline; a refusal (queue full, browser restarting) is HTTP 503 and
a document too large for the 48 MB request limit is 413. The renderer logs one
JSON line per job (size, pages, time, outcome) and never the document. Posture
and update rules: [CONTAINER_SECURITY.md](CONTAINER_SECURITY.md#pdf-renderer). The generic
layout uses the warehouse name installed in `system_settings.app_name`. It
omits private addresses, organization-specific terms and preprinted-paper
positioning. Review the document terms/layout for your organization.

**Long documents.** A GRN, dispatch, invoice or customer stock PDF reads its lines in pages of 1,000
(`functions/_shared/document-lines.ts`), so a document is not limited by the 2,000 rows one PostgREST read may return. The paging is by key:
each page is `id > <the last id of the page before>` ordered by `id` (the line tables have no sequence column), so lines added or removed
while the document is read cannot leave a gap or print a line twice. The first page asks for the exact count; when the lines read are not
that many at the end, the answer is 503 "The document changed while printing. Try again." Lines are then put in the order the screens
show them: a GRN by line id (`get_grn_details`), a dispatch and an invoice by the time in the line's id, then the id
(`get_dispatch_details`, `get_invoice_data`), the stock list by id.

Two limits apply, both answered 400 before the render:

- `MAX_PDF_ROWS` = 3,500 lines: "Document exceeds the limit of 3,500 lines" (after the first read when the count is known). The system
  supports invoices of 3,055 lines.
- `MAX_PDF_PAGES` = 120 estimated printed pages (`functions/_shared/document-pages.ts`): "Document is too long to print (about N
  pages; the limit is 120)". The renderer's memory grows with the pages of one document, not the lines, and a row whose cell wraps takes
  half as much room again. The estimate counts, for every row, the lines its longest cell needs (about 55 characters per line in the item
  column, 24 in the others; Gujarati text sets a little taller) at about 31 one-line rows to a page. It agrees with the measurements
  below within a page or two, and is a little high for Gujarati.

The table's header row is repeated on every page and a row is never split across two pages (the browser's table defaults plus
`tr{break-inside:avoid}`); `tests/golden-pdf/golden/invoice-paged`, a four-page invoice with wrapped rows, pins it.

A document of more than 50 estimated pages (`SOLO_PDF_PAGES`) is rendered alone: the function sends `X-Render-Solo: true` and the renderer
starts nothing beside it ([docker/pdf-renderer/README.md](../docker/pdf-renderer/README.md), "Limits and queueing"). Without it the renderer
runs two jobs at once, and two jobs of 3,055 or 3,500 lines together failed 6 of 6 (503, the memory watchdog). The function sends a renderer failure
of any kind as 503 "PDF renderer unavailable".

Measured through the real renderer (the `pdf-renderer` image with the 1.5 GiB limit of `docker/docker-compose.yml`, one invoice, seven
columns; HTML bytes are the `index.html` posted; single jobs, 2 to 3 s apart):

| Lines and names | HTML | Pages | Render | Result |
| --- | --- | --- | --- | --- |
| 3,000, mixed lengths | 356 KB | 98 | about 1.1 s | 3 of 3 |
| 3,055, mixed lengths | 354 KB | 99 | 0.9 to 1.5 s | 9 of 9 |
| 3,500, mixed lengths | 416 KB | 114 | 1.5 to 2.3 s | 15 of 15 (with a quarter of the names three times as long, 122 pages: 6 of 6) |
| 4,000 | 475 KB | about 130 | 2.9 to 4.4 s | 2 of 3 |
| 4,500 | 534 KB | about 146 | about 3 s | 1 of 3 |
| 5,000 | 594 KB | 162 | 2 to 3.5 s | 1 of 8 |
| 3,055, every name 80 characters (invoice) | 516 KB | 146 | 1.0 to 1.4 s | 1 of 1 |
| 3,055, every name 80 characters (GRN layout) | 536 KB | 146 | 1.1 s | 1 of 1 |
| 3,055, 80-character Gujarati names (invoice) | 516 KB | 153 | 1.3 to 1.4 s | 3 of 3 |
| 3,055, 80-character Gujarati names (GRN layout) | 536 KB | 153 | 1.2 to 1.5 s | 11 of 14 |

Two jobs together (3,055 and 3,500 lines, mixed lengths): 6 of 6 failed without the solo header; with it 10 of 10 rendered, the second
job waiting for the first, 3 to 11 s from the request to the PDF (the renderer allows 25 s). Two 49-page jobs without the header: 5 of 5.

Time is not the limit; memory is. From about 130 pages Chrome reaches the renderer's 1,100 MB watchdog (`KILL_MEMORY_MB`) and the job fails
with 503 "browser crashed"; a job just after another large one fails more often. The page limit is below the first failure, so a
3,055-line invoice whose every name is 80 characters (146 pages) is refused rather than printed, as a 153-page one fails about one time in four; raise the limit only
with a new measurement.

**Letterhead (optional).** The GRN, dispatch, invoice and customer stock PDFs print the facility's letterhead image at the top, full
width, when the operator supplied one with `setup.sh --letterhead-file` (a JPEG or PNG of at most 2 MiB, copied to
`public/letterhead.jpg` or `.png` and named by `LETTERHEAD_FILE`; [OPERATOR_INSTALL.md](OPERATOR_INSTALL.md#letterhead-image-optional)).
The functions router reads the file and hands the document functions a `data:image/jpeg|png;base64,...` address
(`functions/main/letterhead-reader.ts`, `functions/_shared/letterhead.ts`); `documentHtml` uses it only when it matches that exact shape, adds `img-src data:` to the
document's content policy only then, and otherwise produces the same HTML as before. The renderer already lets `data:` images load
(`docker/pdf-renderer/README.md`, also with `RENDERER_CSP=on`, whose policy allows `img-src data:`). A missing or unusable file is logged
once and the PDF is made without it; report PDFs and QR images never carry it.

Generated PDFs live in the private documents bucket. Links expire after one hour;
there is no direct client-read policy. Signed links are bearer capabilities:
do not log, share publicly, or send them to unrelated services.

Every request stores a new file `<kind>/<document id>/<random>.pdf`
(reports: `report/<report>/<customer id or all>/<random>.pdf`); the link
expiring does not delete it. `npm run retention:apply` removes generated PDFs
older than the `generated_documents` policy (7 days by default, far longer than
the one-hour link), and `npm run retention:preview` shows how many it would
remove. The command asks the database for the expired names and deletes them
through the Storage API from inside the storage container, because deleting the
`storage.objects` row alone would leave the file on disk. Only names the PDF
functions produce are removed; any other file in the bucket stays. Nothing
runs it for you: put `retention:apply` on the same schedule as the backups (see
[OPERATOR_INSTALL.md](OPERATOR_INSTALL.md#retention)), or the bucket grows with every
request. To change the age, as the database owner:
`UPDATE warehouse_maintenance.retention_policy SET days = 14 WHERE key = 'generated_documents';`
(1 to 3650 days). A removed PDF is simply generated again on the next request.

After [operator setup](OPERATOR_INSTALL.md), verify all four document downloads
with approved test accounts and records. Confirm the warehouse name and customer
access restrictions.

Printer-specific/preprinted endpoints are separate incomplete optional
integrations; see [PRINTING.md](PRINTING.md) and
[PRODUCTION_DEPENDENCIES.md](PRODUCTION_DEPENDENCIES.md).
