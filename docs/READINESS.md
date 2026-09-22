# Readiness

Current 2026-09-22 follow-up: the default demo starts authenticated Realtime for
mobile orders/cart updates. Both companion jobs pin mobile
`989ade8e86f313ae4b173ad1bb5b56607ecbe353`. See
[container patch evidence](CONTAINER_SECURITY.md) and
[remaining dependencies](PRODUCTION_DEPENDENCIES.md) for current closure status.
Existing release tags and historical native acceptance are unchanged; the new
live-update feature still needs its physical-iPhone regression on the Mac.


## Provider-independent production-readiness pass — 2026-09-22

The local portions of all eleven operational work areas have been exercised.
Backup/isolated restore, owned-service recovery, custom auth/RLS, exact-origin
gateway controls, approved database retention, business correctness, load smoke,
local monitoring/alert ingestion, authenticated Realtime, and the companion
Android debug-artifact audit pass. The durable matrix, reproduction commands,
and limits are in
[LOCAL_PRODUCTION_READINESS.md](LOCAL_PRODUCTION_READINESS.md).

Production is still blocked. The all-profile Trivy scan reports fixed
HIGH/CRITICAL findings in current upstream images; no findings were suppressed.
Real SMS, public DNS/trusted TLS, external alert delivery, operator retention and
business policy, production capacity/DR, final signed mobile artifacts/stores,
payments, telemetry delivery, and printer/sensor hardware require their actual
providers, credentials, infrastructure, or owner decisions. These results do
not change the source-demo acceptance or existing `v0.2.2-demo` tags.

## Final physical-iPhone closure — 2026-09-22

Current `main` passed the complete local source-demo physical-iPhone gate at
backend `cf18f1e43ab613310b1b13339ab97e8533861f9b` paired with mobile
`9ba56ff122dc38dc57d6100de4c27599023d22b1`. Backend PR #13 and mobile PR #18
merged after review; exact-main CI runs `35686198287` and `35686164009` passed.
The complete iPhone 15 / iOS 26.6.2 matrix is recorded in the mobile
`docs/NATIVE_ACCEPTANCE.md`. Its earlier merged customer-history pair also
passed Android API-36 emulator smoke; the final pair passed Android JS export
and shared regression tests but was not rerun in an emulator on this Mac, which
had no Android SDK. Existing `v0.2.2-demo` tags remain immutable.

## Current source-demo status — 2026-09-18

The Android-first source-demo scope is accepted and published. Matching
`v0.2.2-demo` source-only prereleases identify backend commit
`2959881d0e46a8797a98d10da8c7139217477476` and mobile commit
`6e6885786912fe9186285103e19de762e4ba88f8`. Use those matching tags for
the verified release pair and current `main` branches for contribution work.

The verified scope and separate gates are recorded in
[SOURCE_DEMO_ACCEPTANCE.md](SOURCE_DEMO_ACCEPTANCE.md). The scoped maintainer
redistribution attestation and reconciled third-party inventory are recorded in
[ATTRIBUTION_REVIEW.md](ATTRIBUTION_REVIEW.md). There is no unresolved
source-only attribution blocker.

Post-release physical Android and physical-iPhone source-demo acceptance are
complete. Production SMS/TLS/operations, app-store/native-binary distribution,
enabled telemetry, printing, sensors, payments, unsupported integrations, and
production Realtime capacity/resilience remain separate gates. Local
authenticated Realtime startup and authorization now pass.

## Historical readiness records

### Source-demo handoff candidate — 2026-09-18 (historical pre-merge record)

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

Current main is a tested **local-demo checkpoint** with completed source-demo
physical Android and iPhone acceptance. It is not a production release or a
production-signed/app-store distribution. The v0.1.0 tag remains an incomplete
historical export. Production setup stays gated; only explicit
`setup.sh --demo` is enabled.

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

## Still required for production

1. Implement and test a real SMS provider with no fixed-code fallback, provider
   failures, delivery limits, registration controls and operator onboarding. The
   local demo permits only impossible subscriber numbers 0000000001–9.
2. Define and deploy retention/cleanup for generated PDFs and auth/audit data;
   complete legal/privacy and rights/assets review for the target operator.
3. Review TLS/CORS, gateway/body limits, privileged optional host mounts,
   renderer isolation, backups/restores, startup recovery, service updates and
   scale. The synchronous materialized-view refresh is intended for small demos.
4. Test optional printing, sensors, payments and imported unsupported
   integrations with their actual hardware, credentials and business rules;
   test Realtime application delivery, capacity and resilience on the target.
5. Complete production mobile signing/distribution and enabled telemetry delivery
   validation. Keep dependency audits and native regressions current.

A local failed-initialization directory may be kept under ignored
`docker/volumes/db/data.failed-init-*/` for diagnosis. It is not public source.
Do not delete or reset an existing deployment to follow this guide.
