# Maintained container security recipes

Source review: 2026-09-22. These recipes preserve the demo's production gates.
Existing release tags are unchanged. No image binaries are published.

Each source recipe pins the upstream source archive checksum, builder image
digest, and runtime base digest. Copied dependency manifests record the modified
resolution. Go module verification and selected upstream tests run during the
build. Shared BuildKit caches avoid duplicating module/build data in image layers.
OS package repositories remain live: rebuild without stale layers and rescan
before deployment. A previous passing scan is not a current security guarantee.

| Service | Upstream application/source | Patch boundary |
|---|---|---|
| Alertmanager | 0.34.1 | Patched gRPC and Go; retain matching official web UI |
| Node exporter | 1.12.1 | Patched Go/crypto dependency; upstream collector tests with unpacked fixtures |
| Postgres exporter | 0.20.1 | Patched Go/crypto and required net/text versions; collector/config/exporter tests |
| cAdvisor | 0.60.6 | Upgrade from 0.55.1, patch command module Go/crypto/gRPC; preserve matching native runtime |
| Prometheus | 3.14.0 | Patched Go/crypto/gRPC; matching official UI embedded in both executables |
| Auth (disabled profile) | 2.196.0 | Patched Go/crypto/mod/gRPC and Alpine OpenSSL; unchanged auth application and migrations |
| Storage | 1.79.14 | Upgrade from 1.74.0; same-major runtime leaf fixes in locked npm manifest; remove unused npm CLI |
| Gotenberg | 8.37.0 / pdfcpu 0.15.0 | Debian security updates; rebuild bundled pdfcpu with patched Go/crypto/image; retain Gotenberg application |
| imgproxy | 3.31.4 | Patched Go/crypto/image/mod/gRPC; matching vips builder; retain native libraries and apply Debian updates |
| Supavisor (pooler profile) | 2.9.13 | Patch release from 2.9.12 plus Debian updates |
| PostgreSQL | 15.8.1.060 | Same database server/extensions; upgrade linux-libc-dev, rebuild gosu 1.19 and WAL-G 3.0.9 with patched Go/gRPC |

Go rebuilds use the versions locked in their Dockerfiles. No vulnerability
ignore list is added. Required applications are retained. The source and license
inventory is in [THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md).

## Acceptance boundaries

The supported backup path remains `db:backup` / `db:verify-restore` (logical
Postgres dump plus private storage files). WAL archiving stays disabled. The
updated WAL-G executable is not acceptance of PITR, external object storage,
legacy WAL-G backup compatibility, or operator RTO/RPO. Those require a separate
recovery drill with approved storage and policies. GoTrue remains disabled and
is not production SMS authentication acceptance.

The final 19-image Compose inventory on 2026-09-22 passed 16 images at the fixed
HIGH/CRITICAL threshold (Trivy 0.74.0, `--ignore-unfixed`). All eleven new recipes
above passed, as did Kong, PostgREST, CUPS, Edge Runtime and Realtime. The gate
correctly failed for three unchanged upstream images:

| Image | Critical | High |
|---|---:|---:|
| Grafana 13.2.2 | 0 | 104 |
| Studio 2026.09.07-sha-7996410 | 3 | 90 |
| postgres-meta 0.99.0 | 1 | 29 |

Each scan report was validated for presence, format, nonempty results, image
identity and findings. Private machine-readable inventory stays outside Git.
The commands to reproduce are `npm run scan:images`, `test:api`,
`test:monitoring`, `test:pooler`, `test:realtime`, `test:recovery`, `db:backup`,
and `db:verify-restore`, with a unique owned loopback demo project.

Acceptance passed: 19 backend unit tests; source/history secret scans; generated
setup/rerun; full demo API (roles, sessions, images, all four PDFs and business
regressions); authenticated 2x2-to-1x1 PNG resize through Storage/imgproxy;
monitoring configuration, five targets and local alert ingestion; both pooler
ports with valid/invalid credentials; Realtime delivery/isolation/reconnect;
logical backup/storage integrity and isolated restore; owned-service recovery.
The live contract against mobile `989ade8e86f313ae4b173ad1bb5b56607ecbe353`
had no missing RPCs or signature mismatches. Realtime now has a 90-second
initialization grace period because the first database-recreate rehearsal
briefly marked it unhealthy before it recovered; corrected setup passed.

Required GitHub CI must still pass the reviewed commit pair before merge.
None of this closes the remaining three-image security gate or the external
production/iPhone requirements.

The remaining upstream Grafana, Studio, and postgres-meta images still
have findings. Grafana includes several separately built plugins; Studio needs a
coherent Next/sharp rebuild; postgres-meta requires a supported Fastify/router
upgrade. Do not force major dependency overrides into prebuilt applications.
These are unresolved engineering items, not missing SMS/provider credentials.
