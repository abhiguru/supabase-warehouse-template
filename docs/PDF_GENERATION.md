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

Gotenberg renders escaped HTML with a restrictive content policy. The generic
layout uses the warehouse name installed in `system_settings.app_name`. It
omits private addresses, organization-specific terms and preprinted-paper
positioning. Review the document terms/layout for your organization.

Generated PDFs live in the private documents bucket. Links expire after one hour;
there is no direct client-read policy. Signed links are bearer capabilities:
do not log, share publicly, or send them to unrelated services. Expiration does
not delete the PDF; add a retention policy before sustained use.

After [operator setup](OPERATOR_INSTALL.md), verify all four document downloads
with approved test accounts and records in the isolated pilot. Confirm the
warehouse name and customer access restrictions. Historical demo smoke
commands do not apply to the current checkout.

The authenticated `generate-sample-pdf` endpoint remains a staff-only renderer
example. Printer-specific/preprinted endpoints are separate incomplete optional
integrations; see [PRODUCTION_DEPENDENCIES.md](PRODUCTION_DEPENDENCIES.md).
> The demo setup command below applies only to the immutable `v0.2.2-demo` tag. Current checkout accepts `setup.sh --operator` only.
