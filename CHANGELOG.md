# Changelog

## Unreleased — Grafana OS patch and PostgREST provenance (2026-09-23)

- Rebuild digest-pinned Grafana 13.2.2 with Alpine OpenSSL 3.5.8 while preserving
  every publisher-signed bundled plugin file; local startup and health pass.
- Record byte-for-byte publisher release provenance for the PostgREST v14.17
  static binary. Its bundled dependency inventory and vulnerability assessment
  remain a release gate; the publisher evidence is not a substitute for them.

## Unreleased — setup HTTP readiness (2026-09-23)

- Wait up to 90 seconds per internal HTTP probe for transient gateway/transport
  failures after service recreation. Authentication, route and application errors
  still fail immediately; persistent outages fail at the deadline.
- Cover transient recovery, permanent errors, deadline exhaustion and redacted
  transport diagnostics. The exact-main follow-up caught a configuration HTTP 502
  during setup rerun after all container health checks had passed.

## Unreleased — source dependency audit and pooler diagnostics (2026-09-22)

- Audit container npm source manifests in CI, including metadata build/test
  tooling; update vulnerable dependencies while preserving generated-type output.
- Remove unused Storage development scripts/dependencies from its runtime
  manifest and apply compatible Fastify/protobuf patches.
- Declare the pooler entrypoint's required open-file limit so CI/container host
  defaults cannot prevent startup. Allow initialization time, bound probe
  connections, and report redacted
  failure diagnostics; cover credential-redaction regressions.
- Explicitly retain moderate and unfixed upstream advisory boundaries.

## Unreleased — Studio and metadata security (2026-09-22)

- Adopt the patched official September 21 Studio application and remove unused
  package-manager tools from its runtime image.
- Rebuild postgres-meta v0.99.0 against a compatible Fastify 5 plugin set, with
  a reviewable source patch, locked dependencies and retained upstream license.
- Verify Studio HTML/assets and metadata endpoints in CI; record 197 passing
  upstream metadata tests and retain Grafana publisher signatures as a gate.

## Unreleased — orders/cart companion and maintained image recipes (2026-09-22)

- Start Realtime in the default demo and pin both mobile companion jobs to
  `989ade8e86f313ae4b173ad1bb5b56607ecbe353` for orders/cart live updates.
- Add digest/checksum-pinned source recipes and dependency locks for patched
  monitoring, Auth, Storage, PDF, PostgreSQL helper, and pooler images; preserve
  the PostgreSQL server version and production gates.
- Verify pooler session/transaction queries and invalid-password denial in CI;
  validate monitoring configuration using the actual maintained images.
- Retain upstream license texts and notices for copied dependency manifests;
  record patch/acceptance boundaries in `docs/CONTAINER_SECURITY.md`.

## Unreleased — image remediation and production dependencies (2026-09-22)

- Build Edge Runtime and Realtime from digest-pinned upstream images with Debian
  security updates; preserve their upstream application versions.
- Reject missing, invalid, mismatched and vulnerable image-scan reports even when
  the scanner exits successfully; cover false-success regressions.
- Record the nine remaining production areas with specific external inputs and
  distinguish those blockers from unfinished image/mobile Realtime engineering.

## Unreleased — remaining local gates (2026-09-22)

- Verified actual Realtime update delivery, customer isolation and reconnect;
  restore fictional fixture notes after the probe.
- Image scanning now rejects failed/empty Compose inventory and uses a fresh
  private report directory per run.

- Removed unused recommended CUPS packages, clearing its 56 fixed HIGH/CRITICAL
  findings. Require an administrator password and preserve the spool on startup;
  CI verifies the hardware-free startup path.

## Unreleased — provider-independent local readiness (2026-09-22)

- Added private backup plus isolated restore verification, owned-service recovery,
  database retention preview/apply boundaries, gateway CORS/body/TLS checks,
  local load smoke, monitoring validation, and authenticated Realtime smoke.
- Updated current upstream service images and their required configuration,
  constrained cAdvisor metrics, removed the unused analytics service, and kept
  host ports on loopback with explicit resource budgets.
- Added an all-profile Trivy scanner. Its unsuppressed fixed HIGH/CRITICAL
  findings remain a production blocker, including optional service images.
- Extended CI to exercise the new local operational checks and preserved
  byte-identical tracked workflow copies.
- Made the Realtime smoke tolerate only bounded transient Kong 502/connection
  errors while the newly started upstream becomes routable; authentication and
  protocol failures still fail immediately.
- Paired the backend evidence with a native Android debug build and artifact
  contents/permissions/notices audit in the mobile repository. No binary or
  signing credential is published.

## Unreleased — iOS acceptance handoff (2026-09-21)

- Reconciled the release and production checklists after final acceptance: all
  evidenced source-demo dependency, device, authorization, business-flow and
  ownership items are closed; only production deployment and future-binary gates
  remain open.
- Closed the complete physical-iPhone source-demo matrix on the final merged pair:
  backend PR #13 / `cf18f1e43ab613310b1b13339ab97e8533861f9b` with mobile PR #18 /
  `9ba56ff122dc38dc57d6100de4c27599023d22b1`; exact-main CI and affected
  iPhone reruns passed.
- Added customer-authorized per-GRN dispatch history, readable demo fixtures and
  stable order-item snapshots supporting the final mobile acceptance fixes.
- Recorded the end-user pricing, code-level billing-day and PDF/cold-storage
  branding customization boundaries in the durable handoff.
- Added guarded customer-history RPCs for the post-release mobile repair:
  customer GRN filtering/pagination now matches the exposed view controls, and
  a paginated customer dispatch-header list returns only assigned-customer data.
  The associated live API coverage verifies pagination and cross-customer denial.
- Fresh isolated-demo migration and live companion-contract checks passed. The
  repair subsequently passed paired PR review, exact-main CI, the earlier
  customer-history pair's Android smoke and the final physical-iPhone closure;
  published source-only tags are unchanged.
- Fixed configuration, doctor and migration-plan CLI execution through symlinked
  checkout paths, including macOS temporary directories. Added regression coverage
  and restored the setup-failure/configuration-preservation test.
- Aligned the developer handoff with complete physical-iOS evidence, closed mobile
  defects, reproducible USB onboarding and pricing/PDF customization contracts.
- Pinned both CI workflow copies to the submitted mobile handoff commit.
- Preserved published source-release tags; the follow-up passed paired review and
  exact-main CI.

## 0.2.2-demo — source-only prerelease (2026-09-18)

- Added checksummed forward migrations for padded dispatch suggestions and
  protected invoice line-detail compatibility without changing stored document
  identifiers.
- Added numeric ordering, rollover/exhaustion, authorization, fresh/upgrade,
  mobile-validator, and isolated API regression coverage.
- Added ownership-aware clean onboarding, loopback isolation, configuration and
  data-preservation checks, and exact mobile companion pinning in both workflow
  copies.
- Verified the complete source-demo API matrix and paired Android onboarding;
  production and physical-device release gates remain separate.
- Reconciled public onboarding, acceptance scope, maintainer redistribution
  attestation, Supabase-derived configuration provenance, and included license text.
- Restricted the release workflow to the exact `v0.2.2-demo` tag with positive
  and negative regression coverage; publication contains source archives only.

## Unreleased — second-pass review

- Corrected readiness claims: fresh migrations and mobile API coverage fail;
  setup/start and future releases are gated pending a complete sanitized export.
- Added isolated migration/contract tests, credential-preservation and JWT/profile
  regression tests, Compose ownership checks, and explicit readiness documentation.
- Hardened custom-auth function checks and corrected public configuration URLs.

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0] - 2026-03-10

### Added
- Initial release of the Supabase Warehouse Template
- Custom phone OTP authentication (no GoTrue dependency)
- Docker Compose setup with 10+ containers
- Edge Functions: router, config, PDF generation, printing
- CUPS printing integration via IPP
- Gotenberg HTML-to-PDF conversion
- Prometheus + Grafana monitoring stack (optional profile)
- Connection pooler via Supavisor (optional profile)
- One-command setup script with automatic secret generation
- Health check script
- Comprehensive .env.example with all variables documented
- CI/CD workflows for GitHub Actions
- Consolidated database migration with warehouse schema
