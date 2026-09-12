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

- [ ] Verify concurrent mutations, idempotency, prices/taxes/invoice calculations,
  payments, orders, reconciliation, soft deletion and recovery with expected values.
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
- [ ] Complete native Android/iOS and physical-device acceptance, app permissions,
  privacy declarations and artifact/signing review using newly owned credentials.
- [ ] Verify printer/sensor/Realtime hardware and authorization before enabling
  optional features. Presence of an exported endpoint is not hardware acceptance.
- [ ] Obtain ownership/redistribution approval and complete applicable license
  notices; verify privacy/contact information and actual data collection.

The default demo uses API `127.0.0.1:18000`, Studio `127.0.0.1:54325`,
database `127.0.0.1:15433`, and renderer `127.0.0.1:13100`.
See [READINESS.md](READINESS.md), [RELEASE_CHECKLIST.md](RELEASE_CHECKLIST.md),
and [CLEAN_INSTALL.md](CLEAN_INSTALL.md) for demonstrated checks and open work.
