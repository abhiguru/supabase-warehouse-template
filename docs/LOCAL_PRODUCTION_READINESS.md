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
| 10 | Realtime | Passed locally. The current Realtime image started, an authenticated database-change channel joined, and an invalid JWT was rejected. | Define production volume/resilience objectives and test them on the target deployment. |
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
profile; a missing image or scanner failure is also a failure.

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
`--ignore-unfixed` on 2026-09-22. Kong 3.9.3-ubuntu and PostgREST v14.17 were
clean at that threshold. Current upstream tags for the remaining core and
monitoring images still produced findings. Machine-readable reports stay in the
private scan directory because they can contain detailed deployment inventory.
No finding is suppressed or waived by this record.

| Image | Critical | High |
|---|---:|---:|
| `darthsim/imgproxy:v3.31.4` | 0 | 21 |
| `gcr.io/cadvisor/cadvisor:v0.55.1` | 4 | 71 |
| `gotenberg/gotenberg:8.37.0` | 17 | 78 |
| `grafana/grafana:13.2.2` | 0 | 104 |
| `kong:3.9.3-ubuntu` | 0 | 0 |
| `postgrest/postgrest:v14.17` | 0 | 0 |
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
| locally built CUPS printing image | 4 | 52 |

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
