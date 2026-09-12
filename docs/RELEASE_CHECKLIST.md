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

### 4. Clean-install and native acceptance — pending

- [ ] Reproduce setup from public-only source in a clean, isolated environment,
      including prerequisite documentation, generated credentials, and safe reruns.
- [ ] Build native Android and iOS applications and test fresh install, login,
      restart, refresh, logout, offline/retry, camera, secure storage, deep links and
      role-dependent screens.
- [ ] Record platform/device/build evidence. JavaScript export is not an APK,
      an iOS build, or a physical-device test.

### 5. Authorization and business-flow coverage — pending

- [ ] Image upload/confirmation/deletion and cross-customer Storage denial.
- [ ] Disabled users, changed assignments/roles, refresh/logout races and replay.
- [ ] Concurrent dispatch, idempotency, oversell prevention, invoice calculations,
      payments, orders, reports and recovery.
- [ ] Review all imported RPC signatures, return shapes, grants and callers.
      Existing tests cover selected flows, not every RPC or business calculation.

### 6. Distribution, privacy and rights — in progress

- [x] Scan source and Git history for secrets/customer data (Gitleaks verified 0 leaks in publishable files and history).
- [x] Confirm rights to code, fonts, images and other assets; retain applicable third-party notices.
      Both repositories now include `THIRD_PARTY_NOTICES.md` documenting upstream Apache 2.0, SIL OFL 1.1,
      and MIT licenses for icons, SDKs, and Supabase bootstrap files.
- [x] Replace or clearly label placeholder privacy/terms/contact information;
      added `EXPO_PUBLIC_LEGAL_EMAIL` support with documented placeholder defaults.
- [ ] Review optional telemetry and redaction of user data, tokens, URLs, headers
      and breadcrumbs. Establish retention/cleanup expectations.

### 7. Documentation and release integrity — pending

- [ ] Reconcile current setup, ports and production instructions; do not prescribe
      rotating another installation's credentials.
- [ ] Record a tested frontend/backend commit pair and known limitations.
- [ ] Prepare an explicitly scoped demo/prerelease; do not repoint historical
      tags or claim production readiness.
- [ ] Keep unverified printing, sensors and Realtime disabled/unsupported.

## Separate production gate

Open-source availability does not imply safe production deployment. Before a
production release, implement and test real SMS/operator onboarding without
fixed-code fallback; TLS/CORS and service hardening; container/renderer isolation;
backup restoration and startup-failure recovery; concurrency/scale behavior;
monitoring, incident response and data retention. Provider choice, real-device
access, legal ownership and maintainer-only GitHub settings need explicit human
input or access where unavailable.

## Evidence log

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
