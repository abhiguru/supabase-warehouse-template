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

The PR #22 19-image Compose inventory on 2026-09-22 passed 15 images at the fixed
HIGH/CRITICAL threshold (Trivy 0.74.0, `--ignore-unfixed`). All eleven new recipes
above passed, as did Kong, CUPS, Edge Runtime and Realtime. PostgREST returned
no package results and was rejected by the evidence validator; it is not a
passing vulnerability scan. Its static binary needs trusted package/SBOM
evidence tied to the image before this coverage gap can close. The gate
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

The earlier report counted PostgREST as clean based only on an empty findings
list; the strict validator correctly rejected that report. This correction
preserves the fail-closed gate and distinguishes absence of findings from proof
of coverage.

Required GitHub CI must still pass the reviewed commit pair before merge.
That PR #22 evidence did not close the three vulnerable images, the PostgREST
coverage gap, or the external
production/iPhone requirements.

## Studio / metadata follow-up

The publisher released Studio `2026.09.21-sha-512201d`; its application fixes the
previous Next/sharp findings. Its 13 remaining fixed findings were exclusively
in global npm/pnpm tools. The maintained recipe pins that image by digest and
removes those tools; its entrypoint continues to run Node directly.

Postgres-meta remains based on source v0.99.0, rebuilt coherently against Fastify
5.12.5 and compatible CORS/Swagger/type-provider/metrics plugins. The reviewed
`fastify5.patch` passes the logger as `loggerInstance`, handles unknown thrown
errors, and declares the existing error responses for the stricter type provider.
Locked leaf updates, Debian security updates and removal of unused npm/pnpm tools
complete the patch. No warehouse API or public database schema changes are made.

The final follow-up inventory has 17 valid passing reports out of 19 images.
Grafana has 104 HIGH findings; PostgREST lacks scannable package results and is
rejected for insufficient evidence. Both new candidates scan with zero fixed
HIGH/CRITICAL findings. The metadata source
passed TypeScript/build and all 197 upstream tests against a disposable database
using upstream fixtures, with no host ports. Each image build repeats the three
upstream app/admin/helper test files; CI runs `npm run test:studio`, which checks
Studio's project HTML, JavaScript asset, profile/project inventory, metadata table
inventory and a read-only SQL query. The full warehouse API/PDF/image regression
passed against the updated pair. Physical-iPhone and production gates remain open.

For the full upstream suite, build the recipe's `build` target, run the source
archive's `test/db` database fixture on an isolated Docker network without host
ports, and run `PG_META_MAX_RESULT_SIZE_MB=20 PG_QUERY_TIMEOUT_SECS=5
PG_CONN_TIMEOUT_SECS=30 npm exec -- vitest run --maxWorkers=1
--no-file-parallelism` against it. Never target an existing warehouse database.

## Remaining publisher dependency: Grafana

Stable Grafana 13.2.2 still has 104 HIGH findings: two Alpine OpenSSL, one main
binary Thrift, and 101 across bundled plugin executables. The affected plugins
have PGP-signed `MANIFEST.txt` files. Local binary replacement would invalidate
the publisher signatures; signature enforcement must not be bypassed or required
plugins removed to make the scan green. A patched compatible publisher release
(or publisher-signed replacement plugins plus a tested core rebuild) is required.
Nightly images are not treated as accepted stable replacements. No findings are
suppressed; the all-profile gate remains blocked until Grafana passes and the
PostgREST coverage gap is resolved.

## Remaining scan-coverage dependency: PostgREST

Trivy detects no OS or language package results in the static PostgREST v14.17
image. `docker buildx imagetools inspect --format '{{json .SBOM}}'
postgrest/postgrest:v14.17` returned an empty object during this review. The
validator correctly rejects that report. Closure needs trustworthy dependency
inventory/SBOM tied to the published image and an applicable vulnerability
assessment, or a separately reviewed reproducible source build with equivalent
evidence. Do not fabricate scanner results or add dummy packages to manufacture
a passing result. The earlier zero-finding count is explicitly corrected above.


## Source dependency audit follow-up

The image gate scans runtime packages at the fixed HIGH/CRITICAL threshold; it
is not a complete audit of source/build dependencies or unfixed advisories.
GitHub's manifest analysis exposed vulnerable metadata build/test tooling after
the manifests were published. The follow-up updates compatible Vitest/Vite,
Rollup, shell-quote, PostCSS, nanoid and glob dependencies. The previously tested
PostgreSQL type definitions and type generator are pinned to preserve compilation
and the original generated-type snapshots. No snapshot is rewritten to hide a
behavior change. Storage's manifest now contains only the runtime dependencies
used by its precompiled Node entrypoint, with current Fastify/protobuf fixes.

`npm run check:container-dependencies` audits both complete tracked npm graphs in
CI at HIGH/CRITICAL severity. Metadata passes that threshold with 20 moderate
findings remaining; Storage reports zero findings. The metadata source passed all
197 upstream tests on a fresh isolated fixture database, and the deployed
Studio/API/image/PDF checks passed. Test databases must be recreated between full
upstream runs: upstream fixtures retain a helper function after completion.

The manifest inventory also reports an unfixed HIGH advisory
`GHSA-jqcq-xjh3-6g23` for `github.com/jackc/pgproto3/v2` in the optional disabled
Auth service, plus lower-severity upstream findings. These are not erased by
`--ignore-unfixed`; an upstream fix or separately tested driver migration remains
necessary. GoTrue is still disabled and production authentication is not accepted.

The first GitHub integration runs failed during pooler startup although a fresh
local database/pooler passed. Redacted diagnostics identified the cause: the
upstream entrypoint raises `RLIMIT_NOFILE` to 100000, which fails when the
container inherits CI's lower hard limit. Compose now declares both soft and
hard `nofile` limits as 100000. The failure is reproducible with Docker's
`--ulimit nofile=65536:65536`; the declared 100000 limit permits startup without
adding privileges. Migration/tenant/server startup also has a 60-second health
grace period, probe connections are bounded, and failures produce redacted
diagnostics. CI confirmation remains required; local success alone does not
close that failure.
