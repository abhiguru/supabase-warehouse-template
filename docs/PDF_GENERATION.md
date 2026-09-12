# PDF generation

Current main implements four mobile endpoints:

| Endpoint | POST body |
| --- | --- |
| generate-grn-pdf | `{ "gr_no": "..." }` |
| generate-dispatch-pdf | `{ "disp_no": "..." }` |
| generate-invoice-pdf | `{ "inv_no": 1, "fin_year": 2026 }` |
| generate-customer-stock-pdf | `{ "customer_id": "<uuid>" }` |

Each requires a valid, active custom user session and returns
`{ success, pdf_url, expires_in, document }`. Customer access follows assignment
RLS. A document outside the caller's scope returns 404. The business reads use
the caller JWT; the server key is used only for the subsequent private upload.

Gotenberg renders escaped HTML with a restrictive content policy. The generic
starter layout omits company-specific branding, private addresses, original
terms and preprinted-paper positioning. The default name is Warehouse Manager.
To customize it, supply COMPANY_NAME in the functions service environment and
review the document terms/layout for your organization.

Generated PDFs live in the private documents bucket. Links expire after one hour;
there is no direct client-read policy. Signed links are bearer capabilities:
do not log, share publicly, or send them to unrelated services. Expiration does
not delete the PDF; add a retention policy before sustained use.

After `bash setup.sh --demo`, run `npm run test:api` to create fictional documents
and verify all four PDF downloads. The smoke test leaves its fixtures in the
new demo. Demo OTP rate limits apply.

The authenticated `generate-sample-pdf` endpoint remains a staff-only renderer
example. Printer-specific/preprinted endpoints are separate incomplete optional
integrations; see [READINESS.md](READINESS.md).
