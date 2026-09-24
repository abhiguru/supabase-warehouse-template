# Remaining production work

Updated 2026-09-24. This is the current handoff checklist. It uses the existing
nine-item production follow-up numbering, which differs from the eleven local
work areas in [LOCAL_PRODUCTION_READINESS.md](LOCAL_PRODUCTION_READINESS.md).
The operator has not supplied production services or operating policies.
Production remains gated; existing demo release tags are unchanged. Counts and
versions below describe dated scan evidence, not a new scan or verification of
currently patched publisher versions.

The item 9 closure below applies to its explicitly tested merged pair. A later
gateway DNS fix in merged [PR #42](https://github.com/abhiguru/supabase-warehouse-template/pull/42)
passed an affected physical-iPhone retest at mobile
`c943de56b460852e8bca71fbe481b40d0c5265e6` / backend
`53b983d3916dd44ec22c6ac2db05136ca81f3875` on 2026-09-23. Reviewed PR CI
and exact-main CI subsequently passed
for backend `f96f49f94e61bd7a57d7758c93b07c1324728d89` and mobile
`f818c325b4d314b308187e3d12fd8d2e16d59db1`. The later merge pair is
runtime-equivalent to the affected phone-tested pair; the phone did not run
those merge commits. See the [current readiness note](READINESS.md#gateway-regression--reviewed-merges-and-ci-complete-2026-09-23)
for exact runs and the separate historical HTTP 500 limit. Future runtime
changes need affected-case testing before inheriting physical acceptance.

## Technical follow-ups that can start now

- **Item 1 — image security gate:** Security/build maintainers should obtain a
  compatible patched Grafana publisher release or publisher-signed replacement
  plugins, preserve signature enforcement, rebuild from current package
  repositories, and repeat the complete 19-image scan. They should also obtain
  a trustworthy image-bound dependency inventory/SBOM for the static PostgREST
  image, or review a reproducible source build with equivalent evidence, and
  assess its components. Acceptance requires 19 valid image-matched reports
  passing the fixed HIGH/CRITICAL gate, zero remaining Grafana findings at that
  threshold, and a complete PostgREST Haskell/native inventory tied to the
  exact per-platform binaries with an applicable vulnerability assessment.
  Trivy's empty Haskell result cannot satisfy it. The last recorded all-profile
  inventory had **17/19** valid passing reports: the
  locally patched Grafana had **102 HIGH** findings and PostgREST had no package
  results. Publisher binary provenance for PostgREST is established for amd64,
  but it is not a component inventory; arm64 was not attested by that hash.
  A fresh 2026-09-24 targeted **amd64** rebuild and Trivy 0.74.0 scan of the
  current signed-plugin recipe confirmed **9 HIGH, 0 CRITICAL**: one Grafana
  core Thrift finding and eight in six plugin executables (gRPC and Tempo).
  The image-report validator rejected it. Grafana 13.2.2 remained the latest
  stable publisher release, and no patched compatible signed plugin release
  was verified. The [native arm64 Grafana run
  35987888412](https://github.com/abhiguru/supabase-warehouse-template/actions/runs/35987888412)
  passed at backend `80869391f2c8dfb7e700ffa99a68382ba7e769c4` and
  reported the same **9 HIGH, 0 CRITICAL** and the same CVEs and embedded
  versions in its targeted image scan. Workflow success records valid scan
  evidence; these findings still fail the strict image gate. Neither targeted
  scan is a full 19-image rescan. Exact PostgREST binaries on both platforms
  contain affected `aeson` versions under HIGH advisory HSEC-2026-0007;
  inspected v14.18 and v16.3 images also remain affected. No complete
  image-bound Haskell/native inventory is available. See
  [CONTAINER_SECURITY.md](CONTAINER_SECURITY.md),
  the [platform-specific investigation](POSTGREST_IMAGE_INVESTIGATION.md), and
  the [patched source build plan](POSTGREST_PATCHED_BUILD_PLAN.md). The manual
  [arm64 native build evidence](POSTGREST_NATIVE_BUILD_EVIDENCE.md) workflow is
  **NOT RUN, deferred** because no suitable native arm64 machine or VM is
  available. Its dependency-resolution dry run is separate evidence; no patched
  binary or image has been built or installed, and this gate remains open.
- **Disabled Auth source advisory:** Security/build maintainers should track
  the unfixed HIGH `GHSA-jqcq-xjh3-6g23` in `pgproto3/v2` and assess an
  upstream fix or separately tested driver migration before enabling Auth.
  Acceptance is a source dependency audit at the stated threshold and
  compatible Auth tests, with the optional service's status recorded. This is
  separate from the current image-scan gate and does not make demo Auth enabled.
  Lower-severity upstream source findings also remain recorded in
  [CONTAINER_SECURITY.md](CONTAINER_SECURITY.md); they are not cleared by this
  handoff.
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
  See [READINESS.md](READINESS.md#gateway-regression--reviewed-merges-and-ci-complete-2026-09-23).

## Operator inputs and later acceptance

| # | Work and required owner input | Next action and acceptance evidence |
|---|---|---|
| 2 | **SMS authentication and onboarding.** Operator chooses an SMS provider, owns credentials, and approves registration, account activation and abuse rules. Demo session/RLS/refresh/revocation checks already pass. | Backend and mobile maintainers implement real delivery and failure handling with no fixed-OTP fallback. Accept after rate-limit/abuse, provider-outage, account lifecycle and real-device receipt tests with owned credentials. |
| 3 | **Public domain and HTTPS.** Operator supplies target host, DNS control and trusted certificate provisioning, after production authentication in item 2. Loopback CORS, body limits and local TLS checks already pass. | Deployment owner configures the real origin, proxy, certificate and network boundaries. Accept after authenticated end-to-end access, TLS/CORS/body-limit and firewall/mount/privilege checks on the target host; demo mode stays private. |
| 4 | **External alerts.** Operator supplies an owned receiver, credentials, incident contacts and escalation policy. Local targets, rules and synthetic ingestion already pass. | Operations owner wires the receiver and runbook. Accept after a delivered test alert, acknowledgement/escalation and recovery notification reach the intended contacts. |
| 5 | **Off-host backups and disaster recovery.** Operator chooses encrypted off-host destination, key custody, schedule, retention and RTO/RPO. Private logical/storage backup and isolated restore integrity checks already pass. | Operations owner exercises host loss using only off-host copies. Accept after data and object integrity, access controls, measured recovery time and point, and runbook evidence meet the approved objectives. Local copies do not close this gate. |
| 6 | **Production retention.** Operator/legal owner approves retention, deletion and legal-hold rules for business documents, invoices, PDFs, images and backups. Ephemeral/audit database retention supports preview/apply. | Backend/operations owner maps approved policy to preview, deletion and hold behavior. Accept after representative records prove retention and hold boundaries, with reviewed deletion evidence. No business-data deletion is inferred from the demo. |
| 7 | **Billing and accounting.** Business/finance owner approves rates, taxes, rounding and reconciliation examples; payment requirements and provider only if payments are in scope. Fictional-policy calculations, stock, concurrency and rollback checks pass. | Backend/mobile owners implement approved rules and independently compare invoices, credits and reconciliation against expected examples. Accept after business sign-off and provider settlement tests if payments are required. |
| 8 | **Capacity and resilience.** Operator supplies target host, representative data volume and concurrency, latency/error SLOs, soak duration, storage-growth assumptions and recovery objectives. Local API/database load and owned-service recovery smoke pass. | Deployment owner runs target-scale load, soak, restart and recovery exercises. Accept with measured SLO, capacity, storage and recovery evidence against approved thresholds; local smoke alone is insufficient. |
| 9 | **Realtime application acceptance — closed for source-demo orders/cart.** Physical iPhone 15/iOS 26.6.2 passed the complete live-update matrix on 2026-09-23 at mobile `c943de56b460852e8bca71fbe481b40d0c5265e6` / backend `8c682e4d4b83d4f4a8cb2dc252a00702478b11f9`. Reviewed mobile PR #26/backend PR #40 and exact-main CI passed; backend delivery/isolation/token/reconnect probe passed. | Preserve the exact-pair [readiness evidence](READINESS.md) and mobile `docs/NATIVE_ACCEPTANCE.md`. Refresh after reconnect is part of the accepted scope. Production Realtime resilience is part of item 8. Stock/invoice subscriptions are outside the accepted scope; future runtime changes require affected-case acceptance. |

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
