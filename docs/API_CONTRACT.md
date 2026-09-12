# Mobile/backend API coverage

Inventory updated 2026-09-12 using:

```bash
node scripts/check-mobile-contract.mjs ../rn-warehouse-template
```

The checker parses TypeScript calls to `.rpc()` and `executeRPC()`, direct
table calls, and literal Edge URLs. Comments/tests are excluded.

| Surface | Static result |
| --- | --- |
| Mobile RPC names | 100 found, 0 missing (includes new logout_session) |
| Direct mobile table names | 8 found, 0 missing |
| Literal Edge Function names | 7 of 10 found |
| Remaining literal functions | print-grn-preprinted, print-dispatch-preprinted, print-invoice-preprinted |
| Additional dynamic endpoint | manage-print-jobs is also not implemented |

The checker deliberately exits nonzero while optional printing is incomplete.
Do not replace these endpoints with success stubs or treat name presence as
signature/security/behavior validation.

## Tested runtime subset

`npm run test:api` uses the demo API to exercise login, assigned-customer reads,
GRN creation/details, the paginated customer-item selector, dispatch creation and
oversell rejection, invoice saving, PDF generation/download, refresh/replay and
REST/Edge logout revocation. `npm run test:migrations` additionally tests real
database roles, active/inactive profiles and effective grants.

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
See [READINESS.md](READINESS.md) for remaining business, Storage and native tests.
