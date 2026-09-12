# Readiness — 2026-09-12

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
  GRN creation and customer lookup; dispatch with an exact stock decrement;
  overselling denial; invoice saving; four PDFs downloaded and verified as PDFs;
  refresh replay denial; revoked REST and Edge access after logout.
- Mobile: custom-session renewal retained after access expiry; concurrent refresh
  serialized; temporary network failures do not delete refresh credentials;
  custom logout; GoTrue-free OTP authentication; paginated item lookup handling.
  59 Jest tests and TypeScript/ESLint error checks pass after the token-storage
  follow-up. Public bootstrap against
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

The API inventory command still intentionally fails on missing optional print
endpoints. Do not suppress that full-contract/release failure.

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
6. Resolve remaining mobile dependency findings (2026-09-12 follow-up audit:
   0 high, 8 moderate, 0 critical), with navigation-compatible fixes and native
   regression tests. See the [ordered release tracker](RELEASE_CHECKLIST.md).
7. Perform deployment review: TLS/CORS, gateway/body limits, privileged optional
   host mounts, renderer isolation, backups/restores, startup-failure recovery,
   service image updates, rights/assets/legal/privacy text, and release artifacts.
   Synchronous materialized-view refresh is intentionally for small demo installs;
   larger deployments need a reviewed refresh-worker design.
8. CI workflows are activated under `.github/workflows/` (validation and migrations pass in CI).
   Resolve the 3 unexported preprinted endpoints (`print-dispatch-preprinted`, `print-grn-preprinted`,
   `print-invoice-preprinted`) to achieve a full green contract gate. Do not tag a production-ready
   release from this checkpoint.

A local failed-initialization directory may be kept under ignored
`docker/volumes/db/data.failed-init-*/` for diagnosis. It is not public source.
Do not delete or reset an existing deployment to follow this guide.
