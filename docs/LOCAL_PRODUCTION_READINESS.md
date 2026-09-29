# Local production-readiness evidence

**Evidence date:** 2026-09-22  
**Scope:** provider-independent checks on the isolated `warehouse-local-readiness`
Compose project. This is operational evidence for the source template. It does
not authorize a public deployment or change the immutable `v0.2.2-demo` tags.

## Status of the eleven work areas

| # | Area | Local result | Remaining production gate |
|---|---|---|---|
| 1 | Backup and restore | Passed. A private logical database and object-storage backup was checksummed, restored into a disposable network-isolated database, and compared with the source integrity manifest. | Choose encrypted off-host storage, schedule, retention, access, and recovery objectives for the operator. |
| 2 | Failure and recovery | Passed. The owned REST, Storage, Edge Runtime, and Kong services restarted; health, configuration bytes, and representative business data survived. Migration checksum drift is rejected. | Run host-loss and off-host disaster exercises on the target infrastructure. |
| 3 | Authentication and RLS | Passed for the custom local flow. Signature/issuer/expiry checks, refresh rotation and replay denial, logout revocation, role grants, customer isolation, and live REST/Edge denial paths passed. | Implement and test production SMS delivery, registration/onboarding, abuse controls, and provider failure handling. |
| 4 | Containers and network | Partial. Services have loopback host bindings, explicit limits, current reviewed upstream tags, optional profiles, and an ownership guard. | **Blocked:** the all-profile Trivy scan still reports fixed HIGH/CRITICAL findings in current upstream images. Review/remediate every finding and repeat target-host firewall, mount, privilege, and network segmentation review. |
| 5 | Gateway and TLS | Passed locally. Exact-origin CORS, request-size rejection, rate-limit configuration, and the self-signed loopback HTTPS endpoint passed. | Configure the real domain, DNS, trusted certificate, reverse proxy, and authenticated public-deployment test. Never expose demo OTP mode. |
| 6 | Retention | Passed for approved database categories. Preview/apply tests cover expired session/auth records, rate-limit rows, idempotency records, and audit/config logs; the live preview is read-only. | Obtain the operator's policy for business documents, invoices, PDFs, stored images, legal holds, and off-host backups before enabling their deletion. |
| 7 | Business correctness | Passed for the documented fictional demo policy, including concurrency, stock, GRN/dispatch, order idempotency, invoice rounding, reports, private images, and four PDF types. | Approve operator-specific rates, taxes, reconciliation, payments, deletion, and document branding with independent expected values. |
| 8 | Load and resources | Passed as a local smoke test: 100 API requests at concurrency 10 had 0 failures and 121.3 ms p95; a 10-client/10-second read-only `pgbench` run processed 342,889 transactions with 0 failures. | Define real SLOs, data volume, concurrent users, soak duration, storage growth, and production capacity. |
| 9 | Monitoring and runbooks | Passed locally. Prometheus validated 15 rules and all five targets; Alertmanager accepted a synthetic local alert. cAdvisor collects only CPU, memory, and OOM metrics to avoid unrelated host filesystem scans. | Configure and test an owned external receiver, on-call contacts, escalation, access, and target-host recovery runbooks. |
| 10 | Realtime | Passed locally. Actual database updates reached the administrator and assigned customer; the unrelated customer update was excluded, reconnect restored delivery, and an invalid JWT was rejected. | Define production volume/resilience objectives and test them on the target deployment. |
| 11 | Android artifact and notices | Passed for a development APK in the companion mobile repository. The audit checked archive paths, embedded text, permissions, notices, and the Expo public root certificate; blocked media/SMS permissions were absent. | Audit the final release-signed AAB/APK with owned signing credentials, privacy declarations, and store metadata. |

## Reproduce the provider-independent checks

Use a unique project name and an isolated demo. Backup directories and scan
reports are sensitive local evidence and are intentionally ignored.

```bash
export WAREHOUSE_PROJECT_NAME=warehouse-local-readiness
npm ci
npm test
npm run test:migrations
bash setup.sh --demo
npm run doctor
npm run test:api
npm run test:gateway
npm run test:realtime
npm run retention:preview
npm run test:load
npm run test:monitoring
npm run db:backup -- /tmp/warehouse-readiness-backup
npm run db:verify-restore -- /tmp/warehouse-readiness-backup
npm run test:recovery
WAREHOUSE_SCAN_REPORT_DIR=/tmp/warehouse-image-scan npm run scan:images
```

The image scan is expected to remain nonzero until its recorded production
blocker is cleared. It builds local profile images and scans every Compose
profile; failed or empty image enumeration, a missing image, or scanner failure is also a failure. Each invocation creates a fresh mode-0700 report directory.

From the companion mobile checkout:

```bash
npm ci
npm test -- --runInBand
npm run test:setup
npm run lint
npm run typecheck
npx expo install --check
npx expo-doctor
npx expo export --platform android
npx expo prebuild --platform android --clean --no-install
(cd android && ./gradlew assembleDebug)
npm run audit:artifact -- android/app/build/outputs/apk/debug/app-debug.apk
```

The audited development APK contained 1,350 entries and only these requested
permissions: network/Wi-Fi state, camera, internet, debug system-alert-window,
biometric/fingerprint, and vibration. Its locally generated SHA-256 was
`f5b6eadab73bd2d47e968e0c54901a73e33dce4739cf8e2afd55c43debbf210f`.
The hash identifies this local debug artifact; no binary is committed or
published, and a release-signed artifact requires a fresh audit.

## Container scan blocker

Trivy 0.74.0 scanned fixed HIGH/CRITICAL OS and library findings with
`--ignore-unfixed` on 2026-09-22. Kong 3.9.3-ubuntu was clean at that
threshold. PostgREST v14.17 returned no package results and lacks scan coverage. Current upstream tags for the remaining core and
monitoring images still produced findings. Machine-readable reports stay in the
private scan directory during review because they can contain detailed deployment inventory; temporary reports are removed after verification.
No finding is suppressed or waived by this record. The table below records the
upstream-image baseline; follow-up locally patched image results are recorded
below and do not erase that baseline.

| Image | Critical | High |
|---|---:|---:|
| `darthsim/imgproxy:v3.31.4` | 0 | 21 |
| `gcr.io/cadvisor/cadvisor:v0.55.1` | 4 | 71 |
| `gotenberg/gotenberg:8.37.0` | 17 | 78 |
| `grafana/grafana:13.2.2` | 0 | 104 |
| `kong:3.9.3-ubuntu` | 0 | 0 |
| `postgrest/postgrest:v14.17` | not assessed | not assessed |
| `prom/alertmanager:v0.34.1` | 0 | 2 |
| `prom/node-exporter:v1.12.1` | 0 | 9 |
| `prom/prometheus:v3.14.0` | 0 | 6 |
| `prometheuscommunity/postgres-exporter:v0.20.1` | 0 | 12 |
| `supabase/edge-runtime:v1.76.2` | 0 | 3 |
| `supabase/gotrue:v2.196.0` | 0 | 25 |
| `supabase/postgres-meta:v0.99.0` | 1 | 29 |
| `supabase/postgres:15.8.1.060` | 7 | 132 |
| `supabase/realtime:v2.134.10` | 3 | 52 |
| `supabase/storage-api:v1.74.0` | 1 | 37 |
| `supabase/studio:2026.09.07-sha-7996410` | 3 | 90 |
| `supabase/supavisor:2.9.12` | 0 | 1 |
| locally built CUPS printing image (after follow-up) | 0 | 0 |

The database remains on Supabase Postgres 15.8.1.060 because the current
upstream stack uses a different PostgreSQL major version; that upgrade needs a
separately planned data migration. Optional GoTrue, Supavisor, monitoring, and
printing images are included in the all-profile scan even though the supported
demo does not start all of them.

## Work that needs external services or operator decisions

The local work above does not require an SMS vendor, public DNS, a certificate
authority, Slack/email/paging, payment processors, app stores, production
telemetry, or printer/sensor hardware. Those services are needed only for their
corresponding production acceptance gates. The image vulnerability blocker and
operator retention/business-policy approvals also remain open independently of
third-party service availability.

## Follow-up verification

The Realtime probe now verifies event delivery and isolation, rather than only
channel join. It waits for the database subscription, updates fictional customer
cart notes with unique markers, verifies administrator/customer delivery, reconnects
the customer, verifies another update, and restores the notes in cleanup. New
fixture carts are removed. Ownership and explicit loopback demo mode are checked
before login or mutation. Target-volume soak and mobile UI subscription behavior
remain outside this backend probe.

The image enumeration failure regression and private report-directory checks pass.
A repeat all-profile scan still reports the image findings above. These require
patched upstream images or maintained replacement builds; the scan remains a
production blocker. SMS, external notification delivery, public TLS, signing,
hardware, and operator policy/capacity decisions retain their existing gates.

The locally maintained CUPS image now installs explicit required packages without
APT recommendations. This removes the unused `ipp-usb` daemon and all 56 of its
fixed HIGH/CRITICAL findings; the rebuilt image reports zero at that threshold.
The entrypoint requires a supplied administrator password and preserves queued
spool files on restart. `npm run test:cups` verifies missing-password rejection,
spool-marker preservation, configuration and HTTP service in network-isolated
containers, without host USB access. CI repeats this check. IPP-over-USB discovery
is not provided by this image; physical printer/driver acceptance still needs
actual hardware. Other third-party image findings remain open.


## Nine-item production follow-up

[PRODUCTION_DEPENDENCIES.md](PRODUCTION_DEPENDENCIES.md) records the current
nine-item work list, distinguishing unfinished engineering from missing services
and operator decisions. Production acceptance remains open.

The Edge Runtime build now pins upstream v1.76.2 by digest and upgrades Debian
PCRE2; Realtime pins v2.134.10 by digest and applies Debian updates. Trial images
scanned with zero fixed HIGH/CRITICAL findings (previously 3 and 55 respectively
in this follow-up scan). No application major-version upgrade or database schema
change is included. Source build recipes are tracked; binaries are not published.
The scanner now rejects missing, malformed, empty, mismatched, or vulnerable
reports even if the scanner process returns success.

The historical PR #21 scan contained 19 images and initially reported five clean
images. The coverage audit corrects that interpretation: four had valid passing
reports (Kong, CUPS, patched Edge Runtime and patched Realtime), PostgREST lacked
package results, and 14 had findings. Empty findings alone do not prove coverage. Backend unit tests passed 19/19; the mobile contract
had zero missing RPCs or signature mismatches. Local API acceptance covered
sessions, roles, images and all four PDF flows; the patched Realtime passed
update delivery, customer isolation, reconnect and invalid-token denial.
Owned-service restart also passed health recovery, configuration preservation
and business-data preservation after the patch.

## Orders/cart and additional image follow-up

The user selected orders/cart only with refresh after reconnect. Mobile PR #24
introduced the feature; after physical-device fixes in PR #26, both companion
jobs and documented copies pin runtime commit
`c127ef622d84f50ba15eb2fb41609e703b82bfcc`. Local API-36 emulator checks passed
remote order refresh, cart quantity changes, missed-event refresh after Realtime
restart, and empty-cart refresh on 2026-09-22; no Android device rerun occurred
on the Mac. The full physical-iPhone regression passed on 2026-09-23, with final
merged mobile `c943de56b460852e8bca71fbe481b40d0c5265e6` and backend
`8c682e4d4b83d4f4a8cb2dc252a00702478b11f9`. Exact-main CI passed in mobile
run 35828897266/backend run 35829262796. See [READINESS.md](READINESS.md) and the
mobile `docs/NATIVE_ACCEPTANCE.md` for case-by-case evidence, local USB/Mirroring
limitations and cleanup. Owned demo fixtures were removed, token lifetime
restored to 3,600 seconds and test services stopped; unrelated stacks/volumes and
existing release tags were preserved. This closes source-demo item 9 only.

New source image recipes and current acceptance boundaries are recorded in
[CONTAINER_SECURITY.md](CONTAINER_SECURITY.md). The earlier 14-image failure
count above is historical, not the latest candidate result. The PR #22 inventory passes 15/19 images; PostgREST is rejected for missing package
results, while Grafana, Studio and postgres-meta
remain failing. The all-profile release gate remains enforced.

The Studio/postgres-meta follow-up uses the newer official Studio application and
a source-tested metadata migration. Both candidates scan clean; all 197 upstream
metadata tests and the deployed Studio/metadata/API smoke passed. See the current
[container security record](CONTAINER_SECURITY.md) for final inventory and the
remaining Grafana publisher-signature dependency.

The final Studio/metadata follow-up inventory has 17 valid passing reports out
of 19. Grafana retains 104 HIGH findings; PostgREST has no package results and
fails coverage validation. The scanner remains fail-closed for both conditions.
> Historical source-demo evidence. Current checkout accepts `setup.sh --operator` only; see [operator installation](OPERATOR_INSTALL.md).
