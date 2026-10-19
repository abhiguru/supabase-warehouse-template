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
| Canonical HTTPS origin and private network boundary | Partial pilot acceptance; ingress is cloudflared-only | Cloudflare Tunnel is the only supported ingress: Kong trusts `CF-Connecting-IP` from the loopback tunnel hop and rate-limits per client address, and the Caddy example was removed (`deploy/cloudflared-config.example.yml`). Dedicated Cloudflare route, local/public doctor, Android Wi-Fi discovery and gateway upstream recovery passed. Cellular remains untested; keep database, CUPS, the Tapo hubs and the sensor bridge private. Historical stale-IP 502 and HTTP 500 are separate findings. |
| MSG91 OTP and customer approval | Implemented; automated tests and live pilot API enrollment/login PASS | Handset receipt, administrator login, pending customer, approval and post-approval login passed through hidden-input helpers. Native UI and live provider-outage/account-lifecycle acceptance remain. Provider credentials are replaced by rerunning setup with a new `--provider-env` file; signing keys are rotated with `bash rotate-keys.sh --yes` (new JWT secret and anon/service keys, database update, every session revoked, consumers recreated; CI proves old keys and sessions are rejected). |
| Mobile server selection and isolation | Implemented; automated tests and partial physical Android acceptance | Android Wi-Fi HTTPS discovery/selection and cold-launch selected-server persistence passed. QR, two-server/replacement-instance isolation, authenticated restoration and iPhone acceptance remain. |
| Warehouse onboarding and business flow | Pending; staff policy corrected 2026-10-08 | Editable warehouse identity/branding/customer/pricing configuration; approval, receipt, inventory, orders, queue, dispatch, invoices and cart accepted against existing billing semantics. The staff policy was corrected by migrations 23–25 and is proven by the SQL tests: staff pricing only through invoice generation for a specific GRN, invoice totals computed server-side for every role, edits may remove lines and images but whole documents cannot be deleted, dispatch picker/feed/photo RPCs allowlisted, disabled users can be re-approved. See [STAFF_GRN_POLICY.md](STAFF_GRN_POLICY.md#second-pass-corrections-8-october-2026) and [INVOICE_RULES.md](INVOICE_RULES.md). |
| Epson LQ-1310 printing | Pending | Authorized durable jobs with queue/state/duplicate handling; actual continuous forms, alignment and fault recovery on Linux USB and Windows shared-queue VM paths. Disappeared jobs remain uncertain, not proof of paper output. |
| Tapo T310/H100/H200 sensors | Implemented without hardware (2026-10-13); real-device acceptance pending | Home Assistant is replaced by the template's own bridge ([SENSORS.md](SENSORS.md)): migration 74 (`record_sensor_batch`, `sensor_latest`, `sensor_status` with computed stale/offline state, hashed per-bridge ingest keys; readings kept 90 days since migration 75, 400 before), the `ingest-sensor-readings` function, and the GPL-3.0-or-later bridge image (`sensors` profile) with a durable queue, change-or-heartbeat readings sampled every 5 minutes by default and idempotent resend. `measured_at` is the bridge's observation time; the hub gives no source timestamp. Unit, SQL and image checks pass. Open: both hubs and every T310 seen by `--once --dump`, an hour of change and heartbeat rows, the sensor screen of a staff phone showing a new reading within 60 seconds (timed re-read), then `set-capability sensors on`. Cooling control excluded. |
| Recovery, upgrades, diagnostics and alerts | Partially implemented; alerts come from one checker program on the host (`scripts/watch.mjs`, a systemd timer every 5 minutes, Slack only; it also runs the daily backup, verification and retention), which replaced the Prometheus stack on 2026-10-19; backup format v5 (both databases, owners, object catalog, signed with the installation's backup key; optional encryption of USB archives), disposable restore verification, same-instance in-place restore (`scripts/restore.sh`, CI restore drill), an isolated replacement-host drill (pilot evidence, see [HISTORY.md](HISTORY.md)), and owned-service recovery PASS for their recorded scope | Encrypted off-host backup custody, schedule and retention, and full host-loss recovery onto a replacement host with nonempty objects, paired-version upgrade with preflight and rollback path, redacted diagnostics and delivered external alert test remain. CI runs the checker once; that does not establish external delivery. |
| Final handoff | Pending | Both repositories' checks, reviewed PRs/CI, exact main commits and native build IDs, plus physical results and exceptions recorded. Hardware-dependent cases stay **not tested** until performed. |

## Technical follow-ups and dispositions

- **Item 1 — image security gate: time-boxed exceptions since 2026-10-17
  (owner decisions D3 and D5 of the 2026-10-17 operational review).** The gate
  (`npm run scan:images`) builds every image without the build cache and, since
  2026-10-19, scans each once with Trivy (the full report; until then it also ran an
  `--ignore-unfixed` pass): rows with a listed fix fail unless an `advisory`
  exception names them, and every other HIGH/CRITICAL row, or a missing package
  inventory, must match an entry of [`docker/image-exceptions.json`](../docker/image-exceptions.json).
  Each entry names its recipe, the owner (`abhiguru`), a reason, the review date
  and an expiry at most 90 days later; expired or ownerless entries fail the
  scan. The owner accepts the listed rows until the expiry, not beyond it, and
  the release checklist requires a fresh scan before each release. Results and
  the remaining rows are in [CONTAINER_SECURITY.md](CONTAINER_SECURITY.md#exception-ledger-and-the-image-scan-2026-10-17).
  The disposition below is the earlier record; it granted no risk acceptance and
  is superseded by the ledger.
- **Item 1, earlier disposition: Won’t fix in current scope — user disposition.**
  PostgREST's platform binaries contain affected
  `aeson` versions under HIGH advisory HSEC-2026-0007, and a complete image-bound
  Haskell/native inventory is unavailable. These remaining findings are unresolved;
  this disposition grants no production risk acceptance, and the strict
  17-image gate still fails. Stop scheduling research, rebuilds and scans for
  this item unless the user reopens it. See the [security evidence](CONTAINER_SECURITY.md).
  The PostgREST investigation records, their research
  workflows, helper scripts and the candidate Dockerfile were removed from the
  public repository under this disposition.
- **Auth source advisories (removed):** the disabled Auth (GoTrue) recipe, with its `pgproto3/v2`
  replacement, its OpenTelemetry-Go module alignment and its `pgx/v4` to Pop v6 move, was deleted from the
  repository. Those three advisories no longer apply to anything this repository builds. (The Prometheus
  and Alertmanager manifests that kept their own `go.opentelemetry.io/otel` v1.45.0 alignment were removed on 2026-10-19
  with the monitoring stack.)
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

- **Review of 2026-10-10, container and dependency findings.** Done in the
  2026-10-11 changelog entry: network separation, per-function environment,
  pinned function modules, Kong digest, working API alerts. Open, each with
  its steps in [CONTAINER_SECURITY.md](CONTAINER_SECURITY.md): one database
  password for every role ("Database passwords"), no `deno.lock` ("Edge
  function modules"), PostgREST digest ("Image pins"), and the list under
  "Open items with their steps" (Go builders (only gosu is left),
  Chromium switches, container privileges, scheduled scan).
  The committed changes have not run on started containers; see "Changes
  awaiting a first run".

## Operator inputs and later acceptance

| # | Work and required owner input | Next action and acceptance evidence |
|---|---|---|
| 2 | **SMS authentication and onboarding.** Pilot credentials and approved Flow/sender/PE identifiers were supplied; actual receipt and terminal/API enrollment/approval/login passed. Automated operator session/RLS/refresh/revocation checks pass. | Native login, live provider-outage and account-lifecycle acceptance remain. Honor the no-more-delivery-tests instruction; no fixed-OTP fallback. Key rotation is an operator command: `bash rotate-keys.sh --yes` rotates the JWT secret and anon/service keys, updates the database and revokes every session (see [OPERATOR_INSTALL.md](OPERATOR_INSTALL.md#rotate-signing-keys)); the pilot operator decides when to run it. A new operator supplies their own configuration and abuse policy. |
| 3 | **Public domain and HTTPS.** The pilot has a dedicated Cloudflare hostname/tunnel with local/public doctor and Android Wi-Fi discovery passing. Gateway CORS/body limits and upstream recovery also passed. | Cellular and native authenticated end-to-end acceptance remain. Preserve the private boundary and other machines' routes. Current installation has no demo mode; new deployments require their own domain/ingress checks. |
| 4 | **External alerts.** Operator supplies an owned receiver, credentials, incident contacts and escalation policy. Local targets, rules and synthetic ingestion already pass. | Operations owner wires the receiver and runbook. Accept after a delivered test alert, acknowledgement/escalation and recovery notification reach the intended contacts. |
| 5 | **Off-host backups and disaster recovery.** Operator chooses encrypted off-host destination, key custody, schedule, retention and RTO/RPO. Private v5 backup, isolated restore verification and same-instance in-place restore (`db:restore`) already pass in CI; the backup is unencrypted and local. | Operations owner exercises host loss using only off-host copies. Accept after data and object integrity, access controls, measured recovery time and point, and runbook evidence meet the approved objectives. Local copies and the in-place restore do not close this gate. |
| 6 | **Production retention.** Operator/legal owner approves retention, deletion and legal-hold rules for business documents, invoices, PDFs, images and backups. Ephemeral/audit database retention supports preview/apply; the same command removes generated PDFs older than 7 days (configurable) through the Storage API. It is not scheduled: the operator runs it. | Backend/operations owner maps approved policy to preview, deletion and hold behavior. Accept after representative records prove retention and hold boundaries, with reviewed deletion evidence. No business-data deletion is inferred from the demo. |
| 7 | **Billing and accounting.** Business/finance owner approves rates, taxes, rounding and reconciliation examples; payment requirements and provider only if payments are in scope. Fictional-policy calculations, stock, concurrency and rollback checks pass. | Backend/mobile owners implement approved rules and independently compare invoices, credits and reconciliation against expected examples. Accept after business sign-off and provider settlement tests if payments are required. |
| 8 | **Capacity and resilience.** Operator supplies target host, representative data volume and concurrency, latency/error SLOs, soak duration, storage-growth assumptions and recovery objectives. Local API/database load and owned-service recovery smoke pass. | Deployment owner runs target-scale load, soak, restart and recovery exercises. Accept with measured SLO, capacity, storage and recovery evidence against approved thresholds; local smoke alone is insufficient. |
| 9 | **Live updates — accepted for orders/cart; Realtime removed on 2026-10-19, the app now re-reads every 15 seconds.** The history that follows is of the Realtime era. Physical iPhone 15/iOS 26.6.2 passed the complete live-update matrix on 2026-09-23 at mobile `c943de56b460852e8bca71fbe481b40d0c5265e6` / backend `8c682e4d4b83d4f4a8cb2dc252a00702478b11f9`. Reviewed mobile PR #26/backend PR #40 and exact-main CI passed; backend delivery/isolation/token/reconnect probe passed. | The exact-pair readiness evidence and the mobile native acceptance record are archived (see [HISTORY.md](HISTORY.md)). Refresh after reconnect is part of the accepted scope. Realtime is gone, so there is no Realtime resilience to accept; the timed re-read (every 15 seconds on order screens, 60 seconds on sensor screens) has no device acceptance yet: the matrix above was run against Realtime. Stock/invoice subscriptions are outside the accepted scope; future runtime changes require affected-case acceptance. |

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

`docker/edge-runtime/Dockerfile` applies Debian package updates (since
2026-10-17; it upgraded only PCRE2 before) and checks the minimum fixed PCRE2
version. The
Supavisor and CUPS recipes apply Debian package updates to their bases. Kong and PostgREST v16.4
(since 2026-10-17) are referenced by digest. The Go builder image (the gosu stage of the database recipe) is
`golang:1.27.2-bookworm` by digest since 2026-10-11 (they were 1.27.0 and
1.27.1, behind three fixed standard-library advisories). Package indexes
remain live: rebuild and rescan when deploying; Docker layer cache is not proof
of current patch status. These Dockerfiles are source build instructions, not
published container binaries. Upstream notices remain in the base image.

The remaining images need package-by-package review. Do not waive findings,
remove required services, or force incompatible transitive dependency versions
merely to obtain a green scanner result. The all-profile gate stays nonzero
until every HIGH/CRITICAL row of every included image is fixed or covered by a
valid entry of `docker/image-exceptions.json` (Item 1 above).
