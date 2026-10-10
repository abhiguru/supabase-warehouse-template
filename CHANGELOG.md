# Changelog

## Unreleased — receipts sort by number in every accepted form (2026-10-10)

- Migration 31: `get_all_grn_items` and `get_grn_list` sort by receipt number with
  one key for every form `gr_no` accepts. One-letter prefixes keep their order
  (X, Y, Z, then A onward); numbers compare as numbers at any length, so A10000
  follows A9999; other forms (two-letter prefixes, digits only, separators) sort
  by prefix and then number. Before, every form other than a letter plus digits
  came back in ascending text order whichever direction was requested, and
  five-digit numbers collided with the next letter. No request or response changes.

## Unreleased — fresh-install preflight checks the state parent (2026-10-09)

- `doctor --host-preflight` (run by `setup.sh`) now refuses a fresh install
  whose state directory sits in a parent the installation user cannot write,
  and names the `sudo chown` fix. Before, a state directory pre-created under a
  root-owned parent such as `/srv/warehouse` passed the preflight and setup then
  failed with `EACCES` while staging `<state>.installing-*` next to it (testvm2
  known issue 3). Reruns of an installed state need no parent write access.

## Unreleased — checkout permissions after an update (2026-10-09)

- Fixed F3 from the testvm2 operator run: a `git pull` under Ubuntu's default
  umask `0002` left changed scripts group-writable, so the documented "run setup
  again after updating" step was refused by `scripts/backup-usb.sh` (and
  `scripts/backup-disk.sh`). `setup.sh` now runs the new
  `scripts/checkout-permissions.sh` first, which removes group/world write and
  restores world read on tracked files and their directories (ignored runtime
  files and symlinks are untouched). The refusals name that command.
- Operator guide: the upgrade steps update the checkout with
  `(umask 022; git pull --ff-only)`, rerun the USB backup setup after
  `setup.sh`, and troubleshooting covers the refusal.

## Unreleased — orders screen review fixes (2026-10-09)

- Migration 28: cart history moved from the ever-growing `orders.revisions`
  array to an append-only `order_revisions` table (backfilled). The column is
  pinned to `[]` by a CHECK, so audit rows and realtime payloads no longer carry
  the whole history. `get_order_change_log` and dispatch deletion use the table.
- Staff have full order access: list, open and edit carts, the queue, and
  order history (guard v5). Customers can read the history of their own orders.
- Quantity changes check order state, dispatched quantity and stock. A two-
  customer account can edit its carts again (the old `<> ANY` check denied it).
- Cart removals go through the new `remove_item_from_order` RPC, which records
  history; the direct customer delete policy on `order_items` is gone. A lot can
  appear in a cart once (`order_items_order_grn_item_key`, duplicates merged).
- Dropped `convert_order_to_dispatch` and `update_order_after_dispatch_creation`,
  which wrote columns that do not exist. Orders become dispatches through
  `create_dispatch_with_stock_check` with `source_order_id`.
- Migration 29: `get_orders_list` reads a live view instead of rebuilding
  `mv_orders_list` on every cart write, and pages stably by order id. Weight
  search accepts decimals (`12.5`) and its access denials carry `success=false`.
- Added `tests/order_screen.sql` to `npm run test:migrations`.

## Unreleased — second-pass review fixes (2026-10-08)

- Added `scripts/tunnel.sh`: `adopt` keeps the Cloudflare Tunnel credential
  (config and credentials JSON, or a dashboard token) in the state under
  `config/tunnel/`, refusing the account certificate and another
  installation's tunnel; `install-service` writes the systemd unit for that
  copy. Backups (and USB copies) now carry it, and `db:restore-host` restores it,
  so a rebuilt host gets its public address back without a Cloudflare login.
  A lost backup drive now also means replacing the tunnel credential.
- Added `npm run db:restore-host` (`scripts/restore-host.sh`): rebuilds a lost
  installation on a new host from a backup directory or a USB `.tar`, with the
  same identity, keys and data, without running setup. It checks the archive,
  the backup, the migration history against the checkout and that the host is
  new before creating anything, then runs the in-place restore
  (`restore.sh --relocated`). CI runs a lost-host drill on real containers.
- Operator guide: "Recover a lost host from the USB drive", which rebuilds the
  same warehouse on a new host from a USB archive (now with `db:restore-host`;
  the first version used manual steps). Added `scripts/data-fingerprint.sh`,
  a read-only row-count and SHA-256 fingerprint of business tables and stored
  files to compare before backup and after restore.
- Added `scripts/backup-disk.sh`: prepares an empty second disk for backups
  (`status`, `plan`, `apply`, `sync`) and copies verified backups onto it. It
  refuses the system disk and anything that is not blank, never wipes or
  resizes, and `db:backup` is unchanged.
- Backups for pilot installs go to an operator-attached exFAT USB drive (one
  verified `.tar` per backup, readable from Linux and Windows-hosted VMs);
  the operator guide and contributor guide describe it, and the second disk is
  now the alternative.
- Added `scripts/backup-usb.sh`: after a one-time `sudo … setup --enroll`,
  attaching an enrolled exFAT USB drive starts a systemd unit that takes a fresh
  backup, copies it as a read-back-verified `.tar`, runs verify-restore on the
  copy and unmounts the drive. Optional daily timer for a drive left attached;
  `status`, `enroll` and `uninstall`; `doctor` warns when the last USB copy
  failed or is older than 7 days. Only enrolled drives (by filesystem UUID)
  trigger a run, and the copy runs as the installation user.
- Fixed `tests/backup-disk.test.mjs` opening a real device when the host has a
  disk with the fixture's name (`/dev/sdb`).
- Operator guide corrected from a from-scratch acceptance run: the state
  directory's parent must be owned by the installation user (`sudo install -d`
  on the leaf made setup fail with `EACCES`); fixed-window OTP limits and SMS
  cost; DNS negative caching after the tunnel route; `rest` has no healthcheck;
  `rotate-keys.sh` without `--yes` exits 1, and an external doctor right after
  rotation can fail once; root is needed to remove `*.pre-restore-*`; staff are
  created through Users, GRNs need a photo, and the 998 invoice example holds
  only for its fixture dates (same-day is 735).

- Migration 23: staff dispatch workflow completed (GRN picker, recent dispatches,
  dispatch photo register/confirm/cancel with matching storage policies);
  `get_item_storage_prices` removed from the staff allowlist; pending-upload
  cancellation bound to the registering profile.
- Migration 24: invoice header labour, tax and total are computed on the server
  from the saved lines and stored discount for every role; client totals are
  ignored; missing, duplicate or unrelated lines roll the save back.
- Migration 25: refused dispatch edits roll back completely; administrator
  status changes update the enrollment state and revoke sessions.
- Migration 26: GRN edits take the list-refresh lock before the item-table lock.
- Migration 27: a resend keeps the earlier OTP valid, wrong attempts are shared,
  the warehouse-wide hourly cap is configurable (`otp_global_hourly_cap`).
- Gateway: Cloudflare Tunnel is the only supported ingress; Kong trusts
  `CF-Connecting-IP` and rate-limits per client IP; the Caddy example is gone.
- Operations: shared `operator.lock` for stop, recovery, retention and gateway
  checks; `rotate-keys.sh --yes` rotates the signing secret and keys; backup
  format v4 (adds `_supabase` and the storage catalog); `scripts/restore.sh`
  restores a verified backup in place; functions, meta, realtime and imgproxy
  health probes.
- Release: any semantic `v*` tag is validated; Dependabot covers every image
  directory; research workflows and their evidence docs are removed.
- Tests: real guarded-RPC denials replace a probe that could never fail; new
  `user_status_enrollment.sql`, `grn_edit_lock_order.sh`, rotation, restore and
  lock refusal suites.

## Unreleased — remaining handoff checklist (2026-09-24)

- Record the [backend production checklist](docs/PRODUCTION_DEPENDENCIES.md#remaining-production-work)
  with owner inputs, next actions and acceptance evidence. The 17/19 image
  inventory and Grafana 102 HIGH count remain dated evidence, not a new scan.
  Track the unexplained historical CI setup HTTP 500 separately from the
  closed gateway iPhone retest and source-demo orders/cart acceptance.

## Unreleased — gateway merge and evidence closure (2026-09-23)

- Record reviewed PR #42 and mobile PR #28 merges with passing PR and exact-main
  CI. Preserve the earlier full iPhone matrix and later gateway-affected retest
  at their exact tested commits; the merged source pair is runtime-equivalent,
  without claiming a new physical-device run.
- Close the stale gateway CI and iPhone retest handoff claims. The CI-only subnet,
  isolated holder label and cleanup fix precede the green regression; the Linux
  old-TTL control did not reproduce the Mac stale cache. The separate setup HTTP
  500 cause remains unknown, and production operator and container security
  gates remain open. No runtime, workflow, companion pin, tag or release changes.

## Unreleased — setup failure diagnostics (2026-09-23)

- Reduce Kong's Compose DNS cache to five seconds (one second stale/negative)
  after reproducing direct bootstrap HTTP200 versus gateway HTTP502 following
  a functions-container IP change. Add an owned-network regression that forces
  an upstream address change and requires gateway recovery without restarting it.
- Give only the CI demo network an explicit subnet so the regression can reserve
  the old upstream address on GitHub's Docker daemon. Keep its temporary holder
  outside the checkout's Compose ownership label. These test-only changes fix
  failures that occurred before the gateway recovery check ran.
- On a failed health check, collect bounded, redacted gateway/function/REST logs
  from ownership-validated containers. Preserve the failing exit status and all
  readiness checks. This diagnoses post-merge CI bootstrap HTTP 500/502 failures;
  the IP-cache fix addresses the reproduced502 cause, not the separate500 attempt.
  The earlier completed iPhone evidence is not a device run of this later change.

## Unreleased — physical-iPhone orders/cart evidence (2026-09-23)

- Record the completed final merged-pair source-demo iPhone live-update matrix
  and owned cleanup. Close dependency item 9 only; production operator choices,
  capacity, Grafana findings and PostgREST inventory/scan coverage remain open.
- Documentation only: no runtime, companion pin, tag or release changes.

## Unreleased — iPhone USB Realtime companion (2026-09-23)

- Pin both companion checks to the mobile USB WebSocket relay fix and its
  regression tests. Active and documented workflows remain identical.
- This changes no backend runtime and does not by itself close physical-device
  acceptance or any production/security gate.
- Make the pooler acceptance probe wait for a successful authenticated SQL query
  after HTTP health: CI observed a healthy endpoint before port 5432 accepted
  connections. Both pool modes still require SELECT 1 and invalid-password
  rejection. Twelve bounded attempts fail closed; regression tests cover startup
  recovery, permanent failures, empty results and wrong results.

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
