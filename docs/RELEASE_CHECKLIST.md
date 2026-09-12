# Open-source release checklist

Last updated: 2026-09-12.

This is the ordered work tracker for **both** public repositories:
[backend](https://github.com/abhiguru/supabase-warehouse-template) and
[mobile](https://github.com/abhiguru/rn-warehouse-template).
They are already public. Current main is a local-demo checkpoint, not a
production-ready release. The historical backend `v0.1.0` tag is incomplete.

## Boundaries

- Change only the new open-source repositories and isolated test environments.
- Never copy production data or credentials, or modify the original deployments.
- Do not revoke or rotate existing credentials. New installations generate their
  own secrets; existing environment files must be preserved.
- Do not mark a task complete without recorded evidence. A passing source scan
  does not prove application security or native-device compatibility.
- Keep demo authentication loopback-only. Production remains gated.

## Ordered work

### 1. Secure token persistence — implemented; device verification pending

- [x] Remove the mobile fallback that writes access/refresh tokens to AsyncStorage
      as Base64; encoding is not encryption.
- [x] Fail closed on secure-storage write failure and attempt cleanup of partial writes.
- [x] Preserve safe migration of legacy sessions into secure storage only.
- [x] Add failure-path tests and run authentication regression tests, typecheck,
      and lint.

### 2. Dependency remediation — partial; navigation compatibility work remains

- [x] Triage the fresh npm audit: 9 high, 20 moderate, 0 critical findings.
- [x] Apply reviewed Metro/PostCSS/UUID fixes, with no blind forced major SDK upgrade.
- [x] Re-run audit, tests, typecheck, and Android JavaScript export. Distinguish
      build-tool findings from verified runtime exposure.
- [x] Record remaining advisories and assess backend npm dependencies.
- [ ] Resolve remaining URL-decoder/navigation advisory through a tested
      compatibility change; 8 moderate / 0 high / 0 critical findings remain.
- [ ] Assess container and Edge/native dependencies beyond npm.
- [ ] Validate native builds after native dependency changes (see item 4).

### 3. Continuous integration and repository protection — completed

GitHub CLI maintainer authentication is verified (`abhiguru` with ADMIN and `workflow` scopes).
Repository security settings have been activated on both repositories:
secret scanning, push protection, Dependabot vulnerability alerts, automated security updates,
and private vulnerability reporting. Workflows have been activated under `.github/workflows/`.

- [x] Authenticate maintainer with workflow-capable access (`abhiguru` active).
- [x] Verify and enable secret scanning/push protection, dependency alerts, and a working private vulnerability-reporting channel.
- [x] Review and activate workflows from `docs/github-workflows/` into `.github/workflows/`.
- [x] Run unit, migration, contract, security and dependency checks in CI.
      Exported and reviewed the 3 preprinted document endpoints (`print-dispatch-preprinted`,
      `print-grn-preprinted`, `print-invoice-preprinted`) so mobile contract inventory has 0 missing endpoints.
- [x] Verify required checks, branch protection, and confirm workflow runs succeed on GitHub.

### 4. Clean-install verified; native/device acceptance pending

- [x] Reproduce setup from public-only source in a clean, isolated environment,
      including prerequisite documentation, generated credentials, and safe reruns.
      Fresh public clones at backend `c4ca1dec911b23f259315dee1154ef93ad1fe94c`
      and mobile `75e42324b6c9317d8432c1caebe122e4cafa4fdf` passed setup,
      75 mobile tests, API tests and migration reruns. See [CLEAN_INSTALL.md](CLEAN_INSTALL.md).
- [ ] Build native Android and iOS applications and test fresh install, login,
      restart, refresh, logout, offline/retry, camera, secure storage, deep links and
      role-dependent screens.
- [ ] Record platform/device/build evidence. JavaScript export is not an APK,
      an iOS build, or a physical-device test.

### 5. Authorization and business-flow coverage — selected flows verified; broader acceptance open

- [x] GRN image upload/confirmation/deletion, anonymous/customer upload denial,
      and assigned-customer read visibility before/after confirmation/deletion.
      Verified in `tests/api-demo.mjs`: anonymous upload to `grn-images` denied (HTTP 400/403 RLS violation),
      customer role upload denied, admin registers upload via `register_grn_image_upload` and uploads binary,
      unconfirmed image hidden from customer, confirmation via `confirm_grn_image_upload` grants read access to
      assigned customer, deletion via `delete_grn_image` immediately revokes customer read access, and admin cleans up storage.
- [x] Disabled-user login, changed customer assignments, staff/customer role boundaries,
      sequential refresh replay and logout revocation.
      Verified in `tests/auth_and_access.sql` and `tests/api-demo.mjs`: inactive accounts cannot authenticate,
      customer role is denied access to staff RPCs (`save_grn`), dynamic customer assignment removal immediately
      hides assigned customers from RLS and reassignment restores access, refresh token rotation with replay denial,
      and logout session revokes both REST and Edge Function credentials.
- [x] Concurrent dispatch oversell denial, invoice save/malformed-input rejection,
      and selected reporting response smoke checks.
      Verified in `tests/api-demo.mjs`: concurrent dispatches (2x50 units on 70 stock) serialize so exactly one succeeds
      and the other fails with "Insufficient stock", leaving exact stock of 20; single oversell requests (999 items) rejected;
      malformed invoice data structures rejected; the dashboard returns a finite stock KPI
      and the stock-aging response reports success. Expected financial totals are not asserted.
- [x] Static name inventory: all 100 mobile RPC names, 8 table/view names and 10 Edge names
      are present (0 missing). This is not signature or full runtime contract validation.
      `tests/auth_and_access.sql` enforces that anonymous function execution
      is restricted strictly to the 5 authentication endpoints (`send_otp`, `verify_otp_or_register`, `refresh_jwt_token`,
      `logout_session`, `check_session`).

- [ ] Verify cross-customer access to another customer's confirmed Storage images,
      dispatch-image/customer-image lifecycles and retention cleanup.
- [ ] Test actual refresh-versus-logout races, changed roles during an active session,
      retry/idempotency, payments, orders and recovery.
- [ ] Assert invoice/pricing/tax calculations and reporting values against independently
      specified expected results; review all RPC signatures, return shapes and grants.

### 6. Distribution, privacy and rights — source/redaction checks done; approval and artifacts open

- [x] Scan source and Git history for secrets/customer data (Gitleaks verified 0 leaks in publishable files and history).
- [x] Add third-party notice summaries for code, fonts and images.
      Both repositories now include `THIRD_PARTY_NOTICES.md` documenting upstream Apache 2.0, SIL OFL 1.1,
      and MIT licenses for icons, SDKs, and Supabase bootstrap files.
- [x] Replace or clearly label placeholder privacy/terms/contact information;
      added `EXPO_PUBLIC_LEGAL_EMAIL` support with documented placeholder defaults.
- [x] Review optional telemetry and redaction of user data, tokens, URLs, headers
      and breadcrumbs. Establish retention/cleanup expectations.
      Enhanced Sentry/GlitchTip configuration with client-side sanitization of URLs, query
      params, headers, user PII (phone, email, IP), recursive payloads, and real-time breadcrumbs
      before transmission. Documented retention window and cleanup policy in `docs/TELEMETRY_AND_PRIVACY.md`.
      Verified with 16 automated Jest tests in `src/config/__tests__/sentryConfig.test.ts`.

- [ ] Obtain maintainer confirmation of ownership/redistribution rights and complete
      bundled license texts/attributions where required; a notice list alone is not approval.
- [ ] Inspect tags, release attachments and native artifacts for secrets/customer data.
- [ ] Validate actual telemetry payloads/native crashes, privacy declarations and
      server retention/cleanup configuration. Documentation does not enforce server retention.

### 7. Documentation and release integrity — demo release preparation

- [x] Reconcile current setup, ports and production instructions; do not prescribe
      rotating another installation's credentials.
      Reconciled READMEs in both repositories: documented active GitHub Actions CI workflows,
      loopback demo ports (`127.0.0.1:18000`, `127.0.0.1:54325`, `127.0.0.1:15433`),
      and contract parity for preprinted document functions.
- [x] Record a tested frontend/backend commit pair and known limitations.
      Clean-install-tested source pair: mobile `75e42324b6c9317d8432c1caebe122e4cafa4fdf`,
      backend `c4ca1dec911b23f259315dee1154ef93ad1fe94c`. Release tags must record
      exact final commits, not the moving label "current main".
      Documented known limitations: - Dependency audit: 1 root moderate finding (`decode-uri-component` via `query-string`/Expo Router) tracked in `DEPENDENCY_SECURITY.md`. - Physical device acceptance (Item 4) requires real hardware testing: physical camera barcode scanning, Bluetooth/thermal printer hardware, deep links, biometric/keychain persistence across device reboots. - Separate production gate: production SMS and operator onboarding without fixed OTP, TLS/CORS hardening, container isolation, backup recovery, and production credentials.
- [x] Prepare an explicitly scoped demo/prerelease; do not repoint historical
      tags or claim production readiness.
      Both repositories define `main` as a verified local development and integration demo (`v0.2.0-demo checkpoint`).
      Historical `v0.1.0` tag remains untouched as an archived partial baseline.
- [x] Keep unverified printing, sensors and Realtime disabled/unsupported.
      Preprinted print endpoints are included for contract parity, but physical printer/sensor hardware
      and WebSocket Realtime remain unverified and default-disabled.

## Separate production gate

Open-source availability does not imply safe production deployment. Before a
production release, implement and test real SMS/operator onboarding without
fixed-code fallback; TLS/CORS and service hardening; container/renderer isolation;
backup restoration and startup-failure recovery; concurrency/scale behavior;
monitoring, incident response and data retention. Provider choice, real-device
access, legal ownership and maintainer-only GitHub settings need explicit human
input or access where unavailable.

## Evidence log

- 2026-09-12 follow-up: corrected earlier completion overstatements. Static inventory
  proves names, not all RPC signatures/results. Concurrent oversell and malformed
  invoices do not establish idempotency, payments/orders or invoice calculations.
  License summaries do not establish ownership approval, and documented telemetry
  retention is not a deployed cleanup mechanism. Earlier entries below are historical;
  the current unchecked items above are the authoritative remaining work.
- 2026-09-12 follow-up: fresh unauthenticated public clones passed backend install,
  all five migrations/full stack startup, API tests, byte-preserving setup rerun,
  data preservation and disposable SQL security tests. Mobile fresh install passed
  75 Jest tests, 7 bootstrap/dependency tests, typecheck, lint and public bootstrap.
  Android native generation passed; physical-device and iOS acceptance are not run.
- 2026-09-12: Completed Item 7 (Documentation and release integrity). Reconciled `README.md` and setup
  instructions across both repositories to reflect active CI workflows, loopback demo ports (`127.0.0.1:18000`,
  `127.0.0.1:54325`, `127.0.0.1:15433`), and preprinted printing status. Documented the verified commit pair,
  retained historical `v0.1.0` tag untouched while scoping current `main` as a tested local-demo checkpoint,
  and reinforced the separate production gating requirements.
- 2026-09-12: Completed Item 5 (Authorization and business-flow coverage). Expanded `tests/api-demo.mjs`
  to verify: Storage image upload/confirmation/read/deletion lifecycle with cross-customer and anonymous
  denials on `grn-images`; role boundaries preventing customer execution of staff RPCs (`save_grn`);
  dynamic customer assignment removal and restoration with immediate RLS reflection; concurrent dispatch
  race condition where 2 parallel 50-unit dispatches against 70 remaining stock serialize to prevent
  overselling with exact remainder of 20; malformed invoice structure rejection; operational reporting
  (`get_operations_dashboard` KPIs and `get_stock_aging_report`); and full contract coverage across 100 RPCs.
- 2026-09-12: Completed Item 6 (Distribution, privacy and rights). Implemented comprehensive
  client-side telemetry redaction in `src/config/sentryConfig.ts` with `beforeBreadcrumb` and `beforeSend`,
  sanitizing JWTs, Bearer tokens, phone numbers, OTPs, emails, API keys, sensitive query params
  and headers. Added 16 unit tests in `src/config/__tests__/sentryConfig.test.ts` (75 total mobile tests pass).
  Created `docs/TELEMETRY_AND_PRIVACY.md` establishing opt-in telemetry and 30-90 day data retention expectations.
  Verified in CI: Mobile run 34675088177 (`Lint & Type Check` 1m55s, `dependencies` 30s) and Backend run 34675093154
  (`validate` 9s, `contract` 27s, `migrations` 1m31s) both passed 100% green.
- 2026-09-12: Added mobile `THIRD_PARTY_NOTICES.md` documenting vector icons,
  React Native, and Expo SDK licensing. Parameterized privacy policy and terms of
  service with `EXPO_PUBLIC_LEGAL_EMAIL`. Mobile CI rerun (34674661061) passed 100% green.
- 2026-09-12: Backend CI (run 34674424611) passed 100% green across all three jobs:
  `validate` (10s), `contract` (26s), and `migrations` (1m21s). Branch protection
  rules were enabled on `main` for both repositories via GitHub API, enforcing required
  CI status checks (`Lint & Type Check`, `dependencies`, `validate`, `contract`, `migrations`).
- 2026-09-12: Exported and reviewed the three preprinted document endpoints
  (`print-dispatch-preprinted`, `print-grn-preprinted`, `print-invoice-preprinted`)
  and `functions/_shared/print-status-monitor.ts`. Sanitized key logging in `print-grn-preprinted`.
  Contract check (`check-mobile-contract.mjs`) now passes with 0 missing RPCs, 0 missing tables,
  and 0 missing Edge functions.
- 2026-09-12: Pushed commits to `origin/main` on both repositories:
  - Mobile (`rn-warehouse-template` run 34673422024): All CI jobs passed 100% green
    (`Lint & Type Check` passed in 1m19s, `dependencies` passed in 25s).
  - Backend (`supabase-warehouse-template` run 34673438189): `validate` (9s) and
    `migrations` (1m9s with full disposable postgres container test) passed. `contract`
    failed on the 3 unexported preprinted functions (`print-dispatch-preprinted`,
    `print-grn-preprinted`, `print-invoice-preprinted`), maintaining the intentional
    gate documented in `READINESS.md`.
- 2026-09-12: Maintainer authentication confirmed via GitHub CLI for `abhiguru`
  with ADMIN permission and `workflow` scope. Enabled secret scanning, secret scanning
  push protection, Dependabot vulnerability alerts, automated security fixes, and private
  vulnerability reporting on both repositories via API. CI and Release workflows copied
  to `.github/workflows/`.
- 2026-09-12: Gitleaks 8.30.1 re-scanned snapshots containing only publishable
  files (101 backend, 477 mobile files), with redacted output; no leaks found.
  Ignored environment files and deployment volumes were excluded. This does
  not complete the pending release-attachment/native-bundle/privacy review.
- 2026-09-12: Reviewed mobile overrides select Metro 0.83.8, PostCSS 8.5.28,
  UUID 11.1.1 only for Xcode/ngrok. Audit now reports 8 moderate, 0 high,
  0 critical; all remaining package findings trace to URL decoding in navigation.
  Backend npm audit reports zero findings. 59 Jest tests, TypeScript, full
  ESLint error checks, bootstrap/dependency tests and Android JS export pass.
  See [dependency review](../../rn-warehouse-template/docs/DEPENDENCY_SECURITY.md)
  in sibling local checkouts, or the mobile repository's `docs/DEPENDENCY_SECURITY.md`.
- 2026-09-12: Token-storage changes pass 59 Jest tests (5 suites), TypeScript,
  and targeted ESLint. Added write failures at each token/expiry step, partial
  session rejection, failed migration, failed OTP persistence, failed refresh
  persistence, and centralized refresh-token reading. Expiry is invalidated
  before replacing credentials and written last as a completion marker. Native
  storage deletion remains best-effort when the OS itself rejects cleanup;
  physical-device fault/restart testing remains under item 4.
- 2026-09-12: Initial review confirmed insecure mobile token fallback, inactive
  GitHub workflow definitions, and npm audit totals above. Earlier readiness
  results are recorded in [READINESS.md](READINESS.md); they are not evidence that
  all items in this checklist are complete.

## References

- [GitHub repository security quickstart](https://docs.github.com/en/code-security/getting-started/quickstart-for-securing-your-repository)
- [Mobile readiness](https://github.com/abhiguru/rn-warehouse-template/blob/main/docs/READINESS.md)
