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
53, for `status` and for these three fields). It reads the
report's existing RPC with the caller JWT, so the RPC guard decides access
(a refusal is 403, an unknown customer 404), prints at most 2000 rows with a
note when cut, and returns the same `{ success, pdf_url, expires_in, document }`
answer with `document.type = "report"`. Code: `functions/_shared/report-*.ts`.

Gotenberg renders escaped HTML with a restrictive content policy. The generic
layout uses the warehouse name installed in `system_settings.app_name`. It
omits private addresses, organization-specific terms and preprinted-paper
positioning. Review the document terms/layout for your organization.

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
with approved test accounts and records in the isolated pilot. Confirm the
warehouse name and customer access restrictions. Historical demo smoke
commands do not apply to the current checkout.

The authenticated `generate-sample-pdf` endpoint remains a staff-only renderer
example. Printer-specific/preprinted endpoints are separate incomplete optional
integrations; see [PRODUCTION_DEPENDENCIES.md](PRODUCTION_DEPENDENCIES.md).
> The demo setup command below applies only to the immutable `v0.2.2-demo` tag. Current checkout accepts `setup.sh --operator` only.
