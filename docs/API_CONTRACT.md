# Mobile/backend API coverage

The app and the backend are checked as a pair. CI's `contract` job checks out
the app at the commit pinned in `.github/workflows/ci.yml` (`MOBILE_REF`) and
runs the checker against it; locally, with the app checked out beside this
repository:

```bash
npm run check:contract -- ../rn-warehouse-template
```

(`check:contract` is `node scripts/check-mobile-contract.mjs`; `--live` also
compares overloads, SQL return types and effective grants against a running
database.) The checker parses the app's TypeScript calls to `.rpc()` and
`executeRPC()`, direct table calls, `functions.invoke()` and literal Edge URLs.
Comments and tests are excluded.

Counts at backend `3c32394` and app `MOBILE_REF` `d8af378`, re-run on
2026-10-13:

| Surface | Static result |
| --- | --- |
| Mobile RPC names | 94 found, 0 missing |
| Typed RPC calls (argument names compared) | 133, 0 mismatches |
| Dynamic RPC calls (name in a variable; not checked) | 2: `src/config/supabaseConfig.ts`, `src/utils/serviceErrorHandler.ts` |
| Direct mobile table names | 6 found, 0 missing |
| Literal Edge Function names | 8 found, 0 missing |
| Printing functions | `print-grn-preprinted`, `print-dispatch-preprinted`, `print-invoice-preprinted` (and `print-via-ipp`, `get-printer-status`) exist and answer 503 "Printing is not configured" by design (`functions/main/index.ts`); the app names the three preprinted ones through a variable, so they are not in the literal count |
| `manage-print-jobs` | absent; the app does not call it |

The checker exits 1 only for a missing name or, with `--live`, a mismatch; the
pinned pair above exits 0. Name presence is not signature, security or
behaviour validation, and a missing endpoint is never replaced with a success
stub to make the check pass.

## Tested runtime behaviour

The runtime behaviour is tested by the five operator fixture drivers that CI's
install job runs against a fresh installation, all through
`tests/operator-fixture.mjs`: `operator-api-core.mjs`,
`operator-realtime-core.mjs`, `operator-api-final.mjs`,
`operator-api-rotation.mjs` (`npm run test:rotation`) and
`operator-api-restore.mjs` ([DEVELOPER_HANDOFF.md](DEVELOPER_HANDOFF.md)).
`npm run test:migrations` tests the database itself: real roles, active and
inactive profiles, effective grants and the role policy of every granted
function. `tests/api-demo.mjs` and `tests/review-core.mjs` are the historical
fixed-OTP demos and are not run.

The duplicate five-argument customer-item selector was removed; the remaining
six-argument RPC returns `{ success, data: [], pagination }`. The mobile adapter
now reads this envelope.

The four PDF functions return the mobile contract:
`{ success, pdf_url, expires_in, document }`. Their layouts are generic starter
documents, not the original company's branded/preprinted forms. All business
reads use the caller's JWT/RLS; only subsequent private PDF upload uses the
server key.

The imported schema includes unexposed internal/legacy/admin functions.
Do not grant blanket API execution to make an unsupported call work.
See [PRODUCTION_DEPENDENCIES.md](PRODUCTION_DEPENDENCIES.md) for the remaining business, Storage and native acceptance.

## Legacy and dormant functions

Migration 71 (2026-10-13) removed the unused Tally accounting integration: the
invoice sync trigger on `invoice` and its never-read queue, the customer-rename
trigger that kept a ledger map, receipt and contra vouchers, bank statement
reconciliation and the company configuration, with 46 functions and 14 tables.
It also dropped 24 dead functions of the baseline that nothing called and that
did not work against the final schema (review 2026-10-13, L1-L10; among them
`create_order`, `cancel_order`, `get_order_queue`, `ignore_order`,
`reactivate_order`, `delete_dispatch_with_stock_restore`, `safe_delete_invoice`,
`auto_generate_invoice_for_dispatch`, `get_customers_with_stock` and the older
sensor and credential functions). None was granted to the app; the app called
none of them.

Recorded payments remain: the `payments` table and its policies are unchanged
and drive Paid and Pending in `get_customer_invoice_summary` and
`get_customer_activity_detail`. The app does not write payments; after
migration 71 only the service role or the database owner does. A future
accounting integration starts from a new design, not from the removed code.

The baseline still holds other functions that are not granted to `anon` or
`authenticated`. They are not API: do not grant one to make a call work; add a
guarded RPC in a new migration instead.

The five printing functions (`print-grn-preprinted`, `print-dispatch-preprinted`,
`print-invoice-preprinted`, `print-via-ipp`, `get-printer-status`) answer 503
from the router until printing is accepted ([PRINTING.md](PRINTING.md),
"Activation acceptance").
