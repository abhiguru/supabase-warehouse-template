# Remaining production work and dependencies

Updated 2026-09-23. The operator requested continued local work and recording
external blockers. No production services or operating policies were supplied.
This record uses the nine-item follow-up numbering, which differs from the
eleven local work areas in [LOCAL_PRODUCTION_READINESS.md](LOCAL_PRODUCTION_READINESS.md).
Production remains gated; existing demo release tags are unchanged.

| # | Work | Available evidence / local work | What prevents final acceptance |
|---|---|---|---|
| 1 | Container vulnerabilities | All-profile scan; locally built Edge Runtime and Realtime apply Debian updates to digest-pinned upstream applications. CUPS was already patched. Grafana's local OS-only rebuild removes two Alpine OpenSSL findings while preserving all signed plugin files. Scan reports must exist, match the image, and contain valid results. | The current inventory has 17/19 valid passing reports. The patched Grafana still has 102 HIGH findings in its core and signed plugins; PostgREST lacks package scan results and fails evidence validation. Its image binary now has verified publisher-release provenance, but this does not supply a vulnerability-assessable component inventory. See [CONTAINER_SECURITY.md](CONTAINER_SECURITY.md). Grafana plugin signatures must remain enforced; await a compatible patched publisher release/signed artifacts. PostgREST needs trusted package/SBOM evidence tied to its static image. Local core/OS patches alone do not close these gates. The database major version is preserved. Source audits additionally retain an unfixed HIGH pgproto3/v2 advisory in disabled Auth and lower-severity upstream findings; see the security record. |
| 2 | SMS authentication and onboarding | Demo session/RLS/refresh/revocation checks pass. | Choose SMS provider and operator onboarding rules; then implement and test delivery, failures, abuse controls, and real-device receipt with owned credentials. No fixed-OTP fallback is acceptable. |
| 3 | Public domain and HTTPS | Loopback CORS, body limits and local TLS checks pass. | Production authentication from item 2, target host, DNS control and trusted certificate provisioning. Do not expose demo mode. |
| 4 | External alerts | Local monitoring targets, rules and synthetic alert ingestion pass. | An owned receiver, credentials, incident contacts and escalation policy; then prove delivery and recovery notification. |
| 5 | Off-host backups and disaster recovery | Private logical/storage backup and isolated restore integrity checks pass. | Storage destination, encryption/key custody, schedule, retention and RTO/RPO; then test host-loss recovery from that destination. Local copies alone do not meet this gate. |
| 6 | Production retention | Database ephemeral/audit retention supports preview/apply. | Approved retention/deletion/legal-hold rules for business documents, PDFs, images and backups. Do not infer permission to delete business data. |
| 7 | Billing and accounting | Fictional-policy calculations, stock, concurrency and rollback checks pass. | Approved rates, taxes, rounding and reconciliation examples; payment requirements/provider only if payments are required. These decisions precede implementation changes. |
| 8 | Capacity and resilience | Local API/database load and owned-service recovery smoke pass. | Target host, representative data volume/concurrency, latency/error SLOs, soak duration and recovery objectives. Local smoke is not production capacity certification. |
| 9 | Realtime application acceptance | Backend delivery/isolation/token/reconnect checks pass. Mobile PR #24 implements orders/cart only at `989ade8e86f313ae4b173ad1bb5b56607ecbe353`; local Android emulator acceptance covers remote cart changes and refresh after reconnect. Default demo setup starts Realtime. | User selected orders/cart only with refresh after reconnect. Physical-iPhone regression of this new feature remains pending on the separate Mac; earlier iPhone acceptance predates this change. Target-scale resilience depends on item 8. Stock/invoice subscriptions are outside this scope. |

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
