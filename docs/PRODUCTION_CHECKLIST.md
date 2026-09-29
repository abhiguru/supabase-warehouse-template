# Production acceptance gate

Current development source has an operator installer and real SMS code, but
operator acceptance remains open. Use the [independent operator ledger](PRODUCTION_DEPENDENCIES.md#independent-operator-installation-work)
for current status. This historical checklist records the earlier local-demo
readiness pass and is not an installation procedure.
Provider-independent evidence from 2026-09-22 is linked in
[LOCAL_PRODUCTION_READINESS.md](LOCAL_PRODUCTION_READINESS.md). Checked local
items below do not clear their separately stated target-production gates.
See [PRODUCTION_DEPENDENCIES.md](PRODUCTION_DEPENDENCIES.md) for the current
nine-item follow-up and its concrete dependencies.

## Credentials and deployment boundaries

- [ ] Design a new deployment independently; never run this schema baseline
  against an existing/private database.
- [ ] Generate unique credentials for the **new installation**. The setup generator
  creates its environment only when absent, with mode 0600. Existing credentials
  and environment files must not be overwritten, revoked or rotated by this
  release workflow. Do not use the legacy `rotate-keys.sh` as a setup prerequisite.
- [ ] Implement real SMS, operator onboarding, delivery failures and abuse limits
  without any fixed-code fallback. A configuration flag alone is not implementation.
- [x] Review custom-session JWT verification, refresh/logout behavior, RLS and
  every exposed RPC/Storage/Edge permission. Do not assume GoTrue sessions.
- [ ] Review all images/dependencies, renderer isolation, mounts, resource limits,
  service privileges, network boundaries and secret/log handling. The current
  all-profile scan remains blocked by fixed HIGH/CRITICAL findings.

## Data correctness and operations

- [x] Verify the source-demo baseline for concurrent mutations, idempotency,
  prices/taxes/invoice calculations and orders with independent expected values.
  The API and physical-device evidence remains a fixture-level acceptance result.
- [ ] Obtain operator approval for production prices, taxes and billing policy;
  implement and verify payments, reconciliation, soft deletion and recovery with
  production-specific expected values.
- [x] Restore backups into a separate isolated database and compare integrity;
  scheduling a backup alone is not a restore test.
- [x] Test startup failure, migration mismatch, service restart and recovery paths
  without resetting an existing database.
- [x] Configure and verify preview/apply retention for approved session, auth,
  rate-limit, idempotency and audit/config data.
- [ ] Approve and implement target-operator retention for business documents,
  images, PDFs, backups, legal holds and optional telemetry.
- [x] Set local resource budgets and connection thresholds; run API/database load
  smoke and collect disk/memory/container metrics.
- [ ] Define target-production SLOs, capacity/soak tests and growth budgets.
  Review synchronous materialized-view refresh before scaling beyond small demos.
- [ ] Establish incident contacts, alert delivery, operator access and recovery
  runbooks. Optional monitoring integrations remain disabled until tested.

## Network and native acceptance

- [x] Verify exact-origin CORS, request/body limits and self-signed HTTPS on the
  loopback gateway.
- [ ] After the production auth gate is implemented, configure and verify the
  public domain, trusted TLS certificate and authenticated reverse proxy.
  **Do not tunnel or publicly expose the current fixed-OTP demo.**
- [x] Keep database, Studio and renderer on explicit loopback host bindings in
  the supported local configuration.
- [x] Complete local source-demo physical Android and iOS acceptance with fictional
  data and development signing; see the mobile `docs/NATIVE_ACCEPTANCE.md`.
- [ ] Complete production signing and App Store/TestFlight distribution review,
  final app permissions/privacy declarations and native artifact inspection using
  newly owned production credentials.
- [x] Verify Realtime update delivery, customer isolation, reconnect, and invalid-token denial.
- [x] Verify CUPS credential rejection, spool preservation and local HTTP startup
  without hardware; rebuilt local image has zero fixed HIGH/CRITICAL findings.
- [ ] Verify printer/sensor hardware and authorization before enabling optional
  features. Presence of an exported endpoint is not hardware acceptance.
- [x] Record scoped ownership/redistribution confirmation and reconcile source-only
  license notices in both repositories.
- [x] Recheck the development Android APK for forbidden files/text, permissions,
  public certificates and applicable notices.
- [ ] Recheck the exact release-signed artifacts and verify deployed privacy/contact
  information and actual data collection.

The default demo uses API `127.0.0.1:18000`, Studio `127.0.0.1:54325`,
database `127.0.0.1:15433`, and renderer `127.0.0.1:13100`.
See [READINESS.md](READINESS.md), [RELEASE_CHECKLIST.md](RELEASE_CHECKLIST.md),
and [CLEAN_INSTALL.md](CLEAN_INSTALL.md) for demonstrated checks and open work.
