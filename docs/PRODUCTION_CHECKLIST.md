# Production acceptance gate

Current source supports only an isolated local demo. Production setup remains
blocked by `scripts/check-readiness.sh`. This document is an acceptance checklist,
not instructions to expose the fixed-OTP demo or upgrade an existing deployment.

## Credentials and deployment boundaries

- [ ] Design a new deployment independently; never run this schema baseline
  against an existing/private database.
- [ ] Generate unique credentials for the **new installation**. The setup generator
  creates its environment only when absent, with mode 0600. Existing credentials
  and environment files must not be overwritten, revoked or rotated by this
  release workflow. Do not use the legacy `rotate-keys.sh` as a setup prerequisite.
- [ ] Implement real SMS, operator onboarding, delivery failures and abuse limits
  without any fixed-code fallback. A configuration flag alone is not implementation.
- [ ] Review custom-session JWT verification, refresh/logout behavior, RLS and
  every exposed RPC/Storage/Edge permission. Do not assume GoTrue sessions.
- [ ] Review all images/dependencies, renderer isolation, mounts, resource limits,
  service privileges, network boundaries and secret/log handling.

## Data correctness and operations

- [x] Verify the source-demo baseline for concurrent mutations, idempotency,
  prices/taxes/invoice calculations and orders with independent expected values.
  The API and physical-device evidence remains a fixture-level acceptance result.
- [ ] Obtain operator approval for production prices, taxes and billing policy;
  implement and verify payments, reconciliation, soft deletion and recovery with
  production-specific expected values.
- [ ] Restore backups into a separate isolated database and compare integrity;
  scheduling a backup alone is not a restore test.
- [ ] Test startup failure, migration mismatch, service restart and recovery paths
  without resetting an existing database.
- [ ] Configure retention/deletion for documents, images, auth/audit data and
  optional telemetry; verify the cleanup actually executes.
- [ ] Set resource budgets, connection limits and monitor disk/memory growth.
  Review synchronous materialized-view refresh before scaling beyond small demos.
- [ ] Establish incident contacts, alert delivery, operator access and recovery
  runbooks. Optional monitoring integrations remain disabled until tested.

## Network and native acceptance

- [ ] After the production auth gate is implemented and verified, review TLS,
  CORS, request/body limits and an authenticated deployment's reverse proxy.
  **Do not tunnel or publicly expose the current fixed-OTP demo.**
- [ ] Keep database, Studio and renderer off public interfaces.
- [x] Complete local source-demo physical Android and iOS acceptance with fictional
  data and development signing; see the mobile `docs/NATIVE_ACCEPTANCE.md`.
- [ ] Complete production signing and App Store/TestFlight distribution review,
  final app permissions/privacy declarations and native artifact inspection using
  newly owned production credentials.
- [ ] Verify printer/sensor/Realtime hardware and authorization before enabling
  optional features. Presence of an exported endpoint is not hardware acceptance.
- [x] Record scoped ownership/redistribution confirmation and reconcile source-only
  license notices in both repositories.
- [ ] Recheck the exact third-party material bundled into production artifacts and
  verify deployed privacy/contact information and actual data collection.

The default demo uses API `127.0.0.1:18000`, Studio `127.0.0.1:54325`,
database `127.0.0.1:15433`, and renderer `127.0.0.1:13100`.
See [READINESS.md](READINESS.md), [RELEASE_CHECKLIST.md](RELEASE_CHECKLIST.md),
and [CLEAN_INSTALL.md](CLEAN_INSTALL.md) for demonstrated checks and open work.
