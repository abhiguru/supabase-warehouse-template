# Readiness — 2026-09-12

## Active source-demo handoff candidate — 2026-09-18

PR #7 is the reviewed companion for mobile PR #10. Both CI workflow copies are
byte-identical and pin the exact reviewed mobile commit. The candidate passes 16
unit/setup tests, fresh and upgrade migration tests through migrations 00000–00010,
no-op reruns, static/live mobile contract checks (93 RPC names, 127 typed calls,
0 missing names, 0 mismatches), and isolated API coverage for auth/RLS,
GRN/dispatch/stock, idempotency/oversell/concurrency, cart/orders, invoices,
images/storage cleanup, reports, and all four PDF types. Fresh-clone onboarding
also proves generated configuration, health, rerun, owned stop/restart, data
preservation, and Android connectivity.

This is a local source-demo handoff candidate until both PRs merge and required
CI passes on the resulting default-branch pair. Production SMS/TLS/operations,
physical hardware, iOS, distribution, printing, sensors, and unsupported
integrations remain separate gates. Historical demo tags remain immutable.

## Decision

Current main is a tested **local-demo checkpoint**, not a production release or
complete native-app acceptance. The v0.1.0 tag remains an incomplete historical
export. Production setup stays gated; only explicit `setup.sh --demo` is enabled.

No original repository, service, data, or credential was changed.

## Verified

- Full schema-only baseline restores into a fresh Supabase Postgres 15.8.1.060:
  76 baseline tables and 351 non-test function definitions, plus starter migrations.
  No production rows or original signing keys are seeded.
- Transactional migration ledger, advisory lock, and checksums; an unchanged
  second migration pass skips all files. Auth configuration and demo seeds rerun.
  Existing environment files are byte-preserved.
- Full Compose startup and health checks: database, REST, gateway, Studio,
  storage, Edge Functions, image proxy and Gotenberg. Corrected required pg_net
  preload, dependency ordering, and checks that assumed curl existed in Kong.
- SQL tests execute as actual anonymous/authenticated roles: default-disabled
  demo OTP, wrong/replayed OTP, active/inactive accounts, refresh rotation/replay,
  secret/table/function grants, self-promotion denial, customer isolation,
  logout/session revocation, and populated materialized views.
- Live API tests: public bootstrap; admin/customer demo login; anonymous denial;
  customer-only reads; cross-customer RPC/PDF denial; role-promotion denial;
  staff RPC privilege enforcement; dynamic customer assignment revocation/restoration with RLS;
  GRN creation and customer lookup; storage image registration, upload, confirmation, customer read,
  and deletion; concurrent dispatch race prevention (serialized stock decrement, overselling rejection);
  invoice saving and malformed invoice rejection; four PDFs downloaded and verified as PDFs;
  operational KPI calculations (`get_operations_dashboard`) and stock aging reports;
  refresh replay denial; revoked REST and Edge access after logout.
- Mobile: custom-session renewal retained after access expiry; concurrent refresh
  serialized; temporary network failures do not delete refresh credentials;
  custom logout; GoTrue-free OTP authentication; paginated item lookup handling;
  client-side telemetry redaction across headers, URLs, breadcrumbs, and user PII.
  75 Jest tests (6 suites) and TypeScript/ESLint error checks pass after the token-storage
  and telemetry hardening follow-ups. Public bootstrap against
  this running demo passes.
- A fresh Android JavaScript export passes (2,934 modules, 45 assets). This is
  not a compiled APK or physical-device acceptance.

These are specific assertions, not proof that all business calculations, 100 RPC
names, concurrency paths, policies, native screens, or optional services work.

## Reproduce

From the backend checkout:

```bash
npm ci
npm test
npm run test:migrations
bash setup.sh --demo
npm run test:api
```

The isolated migration test removes only its own disposable container. API tests
write fictional records only after matching this demo's key; they leave those
fixtures in place. Demo login rate limits apply to repeated API-test runs.

From the installed mobile checkout:

```bash
npm test -- --silent
npm run typecheck
npx eslint . --quiet
npm run test:setup
npm run check:backend
```

The API inventory command verifies full name coverage across called RPCs,
tables, and Edge Functions.

## Publication scan

Gitleaks 8.30.1 scans of the publishable source trees found no remaining secrets.
The scan caught an embedded legacy SMS initializer in the unpublished schema;
that entire function was removed before publication and the new demo rebuilt.
The original credential was neither revoked nor rotated. Mobile history scans
are clean. Backend history has five individually reviewed documentation/demo-key
false positives, listed by exact historical fingerprints in `.gitleaksignore`;
no broad rule exclusions were added.

## Still required

1. Implement and test a real SMS provider with no fixed-code fallback, provider
   failures, delivery limits, registration controls, and operator-admin onboarding.
   The local demo permits only impossible subscriber numbers 0000000001–9.
2. Review and test all imported RPC signatures, return shapes, grants, and business
   rules. Expand coverage to prices/invoice calculations, payments, cart/order
   lifecycle, concurrent dispatch/idempotency, reports, soft deletion, and recovery.
3. Verify image upload/confirmation/deletion and cross-customer Storage access.
   Signed generated-document downloads have been tested; that does not cover all
   image workflows. Set retention/cleanup for generated PDFs and auth/audit data.
4. Export/review the three preprinted document endpoints and dynamic
   `manage-print-jobs`. Test actual printer hardware, sensors, Realtime and
   optional profiles before enabling them. Printing/sensor feature flags default
   off; Realtime is an opt-in profile.
5. Complete Android/iOS native builds, fresh-install/login/restart/offline/device
   flows, camera/secure-storage/deep-link checks, and frontend role acceptance.
   JS/Jest/API tests are not substitutes for this.
6. Decoder remediation and checked navigation/Metro adapters are included in
   v0.2.1-demo. Keep dependency audits and native regression checks current.
   See the [release tracker](RELEASE_CHECKLIST.md) for version-specific evidence.
7. Perform deployment review: TLS/CORS, gateway/body limits, privileged optional
   host mounts, renderer isolation, backups/restores, startup-failure recovery,
   service image updates, rights/assets/legal/privacy text, and release artifacts.
   Synchronous materialized-view refresh is intentionally for small demo installs;
   larger deployments need a reviewed refresh-worker design.
8. CI workflows are activated under `.github/workflows/` (validation, migrations,
   live demo API, redacted scans and mobile contract checks). The released backend
   main run failed after selecting an old mobile commit; see the release tracker. The 3 preprinted document endpoints
   are exported, closing the static contract gate. Do not tag a production-ready
   release from this checkpoint.

A local failed-initialization directory may be kept under ignored
`docker/volumes/db/data.failed-init-*/` for diagnosis. It is not public source.
Do not delete or reset an existing deployment to follow this guide.
