# Remaining production work

Updated 2026-10-08. This is the acceptance ledger for the operator installation
path on `main`: what is implemented, what evidence closes each work package and
which inputs only the operator can supply. Production remains gated until the
open rows close. Counts and versions in the dispositions below describe dated
scan evidence, not a new scan. The dated pilot narrative that used to sit in
this file is kept with the private pilot evidence (see [HISTORY.md](HISTORY.md)).

## Independent operator installation work

The target is one backend and database per cold-storage business, with one
native app selecting an instance by its canonical HTTPS origin. Linux x86-64 is
the server baseline. On Windows, unattended operation uses an automatically
started Linux VM; WSL2/Docker Desktop remains a development option. ARM64 and
native store publication are deferred. Developers install the service;
warehouse administrators manage their instance afterward. Credentials remain
private to each installation, outside the source checkout. Historical demo
device results do not carry over to an operator installation. This table is
the authoritative status ledger; the sections after it keep the technical
dispositions and the owner inputs.

| Work package | Status | Evidence required to close |
| --- | --- | --- |
| Operator installer, versioned manifest, persistent storage, first-admin bootstrap, safe rerun, preflight and doctor | Implemented; CI isolated installation and the pilot VM setup/rerun/guest reboot PASS | Physical-host unattended VM startup/shutdown and host reboot remain. No demo users or fixed OTP. |
| Canonical HTTPS origin and private network boundary | Partial pilot acceptance; ingress is cloudflared-only | Cloudflare Tunnel is the only supported ingress: Kong trusts `CF-Connecting-IP` from the loopback tunnel hop and rate-limits per client address, and the Caddy example was removed (`deploy/cloudflared-config.example.yml`, `deploy/warehouse-tunnel.service.example`). Dedicated Cloudflare route, local/public doctor, Android Wi-Fi discovery and gateway upstream recovery passed. Cellular remains untested; keep database, Studio, CUPS and Home Assistant private. Historical stale-IP 502 and HTTP 500 are separate findings. |
| MSG91 OTP and customer approval | Implemented; automated tests and live pilot API enrollment/login PASS | Handset receipt, administrator login, pending customer, approval and post-approval login passed through hidden-input helpers. Native UI and live provider-outage/account-lifecycle acceptance remain. Provider credentials are replaced by rerunning setup with a new `--provider-env` file; signing keys are rotated with `bash rotate-keys.sh --yes` (new JWT secret and anon/service keys, database update, every session revoked, consumers recreated; CI proves old keys and sessions are rejected). |
| Mobile server selection and isolation | Implemented; automated tests and partial physical Android acceptance | Android Wi-Fi HTTPS discovery/selection and cold-launch selected-server persistence passed. QR, two-server/replacement-instance isolation, authenticated restoration and iPhone acceptance remain. |
| Warehouse onboarding and business flow | Pending; staff policy corrected 2026-10-08 | Editable warehouse identity/branding/customer/pricing configuration; approval, receipt, inventory, orders, queue, dispatch, invoices and cart accepted against existing billing semantics. The staff policy was corrected by migrations 23–25 and is proven by the SQL tests: staff pricing only through invoice generation for a specific GRN, invoice totals computed server-side for every role, edits may remove lines and images but whole documents cannot be deleted, dispatch picker/feed/photo RPCs allowlisted, disabled users can be re-approved. See [STAFF_GRN_POLICY.md](STAFF_GRN_POLICY.md#second-pass-corrections-8-october-2026) and [INVOICE_RULES.md](INVOICE_RULES.md). |
| Epson LQ-1310 printing | Pending | Authorized durable jobs with queue/state/duplicate handling; actual continuous forms, alignment and fault recovery on Linux USB and Windows shared-queue VM paths. Disappeared jobs remain uncertain, not proof of paper output. |
| Tapo T310/H100/H200 and Home Assistant monitoring | Pending | Sanitized integration assets, narrow ingestion credential, device mapping, source timestamps, idempotent five-minute uploads/fifteen-minute replay, missing values and stale/offline state; real-device acceptance before enabling mobile capability. Cooling control excluded. |
| Recovery, upgrades, diagnostics and alerts | Partially implemented; backup format v5 (both databases, owners, object catalog, signed with the installation's backup key; optional encryption of USB archives), disposable restore verification, same-instance in-place restore (`scripts/restore.sh`, CI restore drill), an isolated replacement-host drill (pilot evidence, see [HISTORY.md](HISTORY.md)), and owned-service recovery PASS for their recorded scope | Encrypted off-host backup custody, schedule and retention, and full host-loss recovery onto a replacement host with nonempty objects, paired-version upgrade with preflight and rollback path, redacted diagnostics and delivered external alert test remain. Local monitoring/CI acceptance does not establish external delivery. |
| Final handoff | Pending | Both repositories' checks, reviewed PRs/CI, exact main commits and native build IDs, plus physical results and exceptions recorded. Hardware-dependent cases stay **not tested** until performed. |

## Technical follow-ups and dispositions

- **Item 1 — image security gate: Won’t fix in current scope — user disposition.**
  The active Grafana recipe's recorded scan has **3 HIGH** findings: core Thrift and
  gRPC in the required Prometheus and PostgreSQL plugins. The separate combined
  core rebuild/prune **amd64** candidate removes Thrift but retains the two
  plugin gRPC HIGH findings. PostgREST's platform binaries contain affected
  `aeson` versions under HIGH advisory HSEC-2026-0007, and a complete image-bound
  Haskell/native inventory is unavailable. These remaining findings are unresolved;
  this disposition grants no production risk acceptance, and the strict
  19-image gate still fails. Stop scheduling research, rebuilds and scans for
  this item unless the user reopens it. See the [security evidence](CONTAINER_SECURITY.md).
  The Grafana candidate and PostgREST investigation records, their research
  workflows, helper scripts and the candidate Dockerfile were removed from the
  public repository under this disposition.
- **Disabled Auth source advisory:** A reviewed candidate locally replaces
  `pgproto3/v2` v2.3.3 with the same tagged source plus a negative DataRow field
  length guard. Its [source provenance and regression tests](../docker/auth/internal/forks/pgproto3/PATCH.md)
  cover invalid `-2` and minimum-int32 lengths and the valid `-1` null marker;
  the Auth Docker build runs them with `go mod verify` for downloaded modules,
  selected upstream tests and compilation. The [HIGH advisory](https://github.com/advisories/GHSA-jqcq-xjh3-6g23)
  still has no patched publisher version. The final image includes the fork's
  MIT notice; its targeted Trivy 0.74.0 scan passed the strict validator at the
  fixed HIGH/CRITICAL threshold. A scanner may retain the published v2.3.3
  finding or lack a version for the local replacement. This scan cannot prove
  the decoder patch, so source review and build evidence remain necessary with
  Auth runtime/database integration checks before enabling the service. GoTrue
  remains disabled; the full 19-image gate and production authentication remain
  open. Track a maintained upstream driver and the lower-severity findings recorded
  in [CONTAINER_SECURITY.md](CONTAINER_SECURITY.md).
- **OpenTelemetry-Go LOW advisory candidate:** The Prometheus, imgproxy,
  Alertmanager and disabled Auth build manifests now align their
  `go.opentelemetry.io/otel` module family at v1.45.0, the fixed release for
  [GHSA-8wmf-6v46-5gfg](https://github.com/advisories/GHSA-8wmf-6v46-5gfg).
  This covers the 16 LOW alerts for `otel/sdk` and the OTLP trace exporters
  across those four images. The corresponding `go.sum` files record the new
  modules and required transitive updates. All four isolated Docker image
  builds passed `go mod verify` and compilation; Alertmanager additionally
  passed its config/API tests, Prometheus its config test, and Auth its local
  `pgproto3` and crypto tests. Imgproxy's build has no test stage. These are
  candidate build checks, not runtime telemetry delivery tests, a new
  all-profile image scan, or confirmation that GitHub alerts closed. Auth
  remains disabled. Its separate `pgx/v4` LOW alert has no v4 fix and is
  addressed by the following candidate. The full 19-image gate and production
  telemetry acceptance remain open.
- **Disabled Auth PostgreSQL driver LOW advisory candidate:** The Auth build
  manifest now selects Buffalo Pop v6.1.2, the earliest Pop v6 release using
  `pgx/v5/stdlib`, and pins `github.com/jackc/pgx/v5` v5.9.2, the fixed release
  for [GHSA-j88v-2chj-qfwx](https://github.com/advisories/GHSA-j88v-2chj-qfwx).
  The pinned Go 1.27.1 module graph and compiled image binary contain Pop
  v6.1.2 and pgx/v5 v5.9.2 with no pgx/v4; `pgconn` v1.14.3 and the local
  `pgproto3/v2` replacement remain. The isolated Docker build passed module
  verification, local decoder tests, crypto tests and compilation. Against a
  disposable Postgres 15 database, the candidate binary completed migrations
  (23 `auth` tables), upstream storage and model packages passed, and the
  complete `go test -p 1 -count=1 ./internal/api/...` tree passed (11 tested
  packages; one package had no tests). The serial run used deterministic
  `example.com` resolution and a test-only proxy that rejected that site's
  outbound HTTPS connection promptly; other HTTPS connections were tunneled.
  This was necessary because the upstream custom OAuth test expects a failed
  discovery fetch, while the isolated network otherwise timed out or could not
  resolve the site. An earlier parallel API run caused shared-schema test
  collisions; serial execution removed those failures. The built Auth service
  also returned HTTP 200 for health, signup and password grant against the
  disposable database, with a confirmed user row persisted. A targeted Trivy
  0.74.0 scan of the built candidate image passed the repository's strict
  HIGH/CRITICAL report validator with zero findings. No production code or
  test assertions changed. The complete upstream `./...` suite, production
  authentication acceptance, the full 19-image scan, and GitHub alert closure
  remain unverified. Auth stays disabled.
- **Metadata dependency candidates:** The tracked postgres-meta graph now pins
  Vitest and its coverage package to 4.1.11, resolving the patched
  `@vitest/mocker` 4.1.11 for
  [GHSA-82fw-gwwq-j7x9](https://github.com/advisories/GHSA-82fw-gwwq-j7x9).
  Paired Sentry Node/profiling 10.75.2 resolves `@opentelemetry/core` 2.11.0,
  above the [2.8.0 fix](https://github.com/advisories/GHSA-8988-4f7v-96qf).
  The combined image passed TypeScript, compilation and 12 selected upstream
  tests; `npm ci` and full npm audit reported zero vulnerabilities. Its targeted
  Trivy 0.74.0 scan passed the strict validator at the fixed HIGH/CRITICAL
  threshold. The earlier Sentry-only candidate passed isolated initialization,
  sensitive span redaction and health checks. A separate in-memory transport
  probe captured a synthetic Sentry event and completed `flush`; external
  delivery and production DSN behavior were not tested. The first full upstream
  run failed during collection because one test used the older timeout argument
  position. A [test-only Vitest 4 patch](../docker/postgres-meta/vitest4.patch)
  corrected that signature without changing production code; the combined
  candidate then passed **13/13 files and 197/197 tests** against a fresh
  disposable database. CI, applicable runtime checks, the full 19-image gate
  and GitHub alert verification after merge remain. These targeted candidate
  checks do not establish alert auto-closure or production readiness.
- **Separate historical CI HTTP 500 investigation:** Backend maintainers should
  capture redacted diagnostics for the fresh loopback demo/config bootstrap
  HTTP 500 on attempt 2 of backend-main CI
  [35842102994](https://github.com/abhiguru/supabase-warehouse-template/actions/runs/35842102994),
  reproduce and identify its cause, implement a scoped correction if needed,
  and rerun the affected setup/gateway test in isolated CI. Acceptance is a
  cause and fix (or a documented reproducible non-defect explanation), passing
  affected regression and exact-head CI. This was a CI observation, not a
  physical-device HTTP 500 or an established current source-demo regression.
  The Kong stale-IP HTTP 502 cause was fixed and its gateway/phone retest
  closed; that work does not explain the separate 500.
  The dated readiness evidence is archived (see [HISTORY.md](HISTORY.md)).

## Operator inputs and later acceptance

| # | Work and required owner input | Next action and acceptance evidence |
|---|---|---|
| 2 | **SMS authentication and onboarding.** Pilot credentials and approved Flow/sender/PE identifiers were supplied; actual receipt and terminal/API enrollment/approval/login passed. Automated operator session/RLS/refresh/revocation checks pass. | Native login, live provider-outage and account-lifecycle acceptance remain. Honor the no-more-delivery-tests instruction; no fixed-OTP fallback. Key rotation is an operator command: `bash rotate-keys.sh --yes` rotates the JWT secret and anon/service keys, updates the database and revokes every session (see [OPERATOR_INSTALL.md](OPERATOR_INSTALL.md#rotate-signing-keys)); the pilot operator decides when to run it. A new operator supplies their own configuration and abuse policy. |
| 3 | **Public domain and HTTPS.** The pilot has a dedicated Cloudflare hostname/tunnel with local/public doctor and Android Wi-Fi discovery passing. Gateway CORS/body limits and upstream recovery also passed. | Cellular and native authenticated end-to-end acceptance remain. Preserve the private boundary and other machines' routes. Current installation has no demo mode; new deployments require their own domain/ingress checks. |
| 4 | **External alerts.** Operator supplies an owned receiver, credentials, incident contacts and escalation policy. Local targets, rules and synthetic ingestion already pass. | Operations owner wires the receiver and runbook. Accept after a delivered test alert, acknowledgement/escalation and recovery notification reach the intended contacts. |
| 5 | **Off-host backups and disaster recovery.** Operator chooses encrypted off-host destination, key custody, schedule, retention and RTO/RPO. Private v4 backup, isolated restore verification and same-instance in-place restore (`db:restore`) already pass in CI; the backup is unencrypted and local. | Operations owner exercises host loss using only off-host copies. Accept after data and object integrity, access controls, measured recovery time and point, and runbook evidence meet the approved objectives. Local copies and the in-place restore do not close this gate, and neither does a second local backup disk prepared with `scripts/backup-disk.sh`: it protects against failure of the data disk only, not against loss of the host, theft or ransomware. |
| 6 | **Production retention.** Operator/legal owner approves retention, deletion and legal-hold rules for business documents, invoices, PDFs, images and backups. Ephemeral/audit database retention supports preview/apply; the same command removes generated PDFs older than 7 days (configurable) through the Storage API. It is not scheduled: the operator runs it. | Backend/operations owner maps approved policy to preview, deletion and hold behavior. Accept after representative records prove retention and hold boundaries, with reviewed deletion evidence. No business-data deletion is inferred from the demo. |
| 7 | **Billing and accounting.** Business/finance owner approves rates, taxes, rounding and reconciliation examples; payment requirements and provider only if payments are in scope. Fictional-policy calculations, stock, concurrency and rollback checks pass. | Backend/mobile owners implement approved rules and independently compare invoices, credits and reconciliation against expected examples. Accept after business sign-off and provider settlement tests if payments are required. |
| 8 | **Capacity and resilience.** Operator supplies target host, representative data volume and concurrency, latency/error SLOs, soak duration, storage-growth assumptions and recovery objectives. Local API/database load and owned-service recovery smoke pass. | Deployment owner runs target-scale load, soak, restart and recovery exercises. Accept with measured SLO, capacity, storage and recovery evidence against approved thresholds; local smoke alone is insufficient. |
| 9 | **Realtime application acceptance — closed for source-demo orders/cart.** Physical iPhone 15/iOS 26.6.2 passed the complete live-update matrix on 2026-09-23 at mobile `c943de56b460852e8bca71fbe481b40d0c5265e6` / backend `8c682e4d4b83d4f4a8cb2dc252a00702478b11f9`. Reviewed mobile PR #26/backend PR #40 and exact-main CI passed; backend delivery/isolation/token/reconnect probe passed. | The exact-pair readiness evidence and the mobile native acceptance record are archived (see [HISTORY.md](HISTORY.md)). Refresh after reconnect is part of the accepted scope. Production Realtime resilience is part of item 8. Stock/invoice subscriptions are outside the accepted scope; future runtime changes require affected-case acceptance. |

The companion mobile handoff separately owns release signing/store distribution,
enabled telemetry delivery and actual printer/sensor hardware acceptance. These
are not item 9 regressions or blockers to the accepted source-demo orders/cart
scope; they remain production/optional-integration work. See the companion
[mobile developer handoff](https://github.com/abhiguru/rn-warehouse-template/blob/main/docs/DEVELOPER_HANDOFF.md)
for its artifact and hardware acceptance steps.

Names and non-secret operating requirements can be recorded in a reviewed change.
Credentials belong in the operator's secret store, never this document. None of
these entries authorizes production deployment, new billing policy, deletion,
public demo exposure, or publication of rebuilt third-party container binaries.

## Maintained image patch boundaries

`docker/edge-runtime/Dockerfile` upgrades only Debian's PCRE2 library and checks
the minimum fixed version. `docker/realtime/Dockerfile` applies Debian package
updates while retaining the digest-pinned Realtime application. Package indexes
remain live: rebuild and rescan when deploying; Docker layer cache is not proof
of current patch status. These Dockerfiles are source build instructions, not
published container binaries. Upstream notices remain in the base image.

The remaining images need package-by-package review. Do not waive findings,
remove required services, or force incompatible transitive dependency versions
merely to obtain a green scanner result. The all-profile gate stays nonzero
until every included image passes.
