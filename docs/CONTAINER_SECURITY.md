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
| Auth (disabled profile) | 2.196.0 | Patched Go/crypto/mod/gRPC and Alpine OpenSSL; local `pgproto3/v2` v2.3.3 DataRow length guard; unchanged auth application and migrations |
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

## Grafana OS patch and remaining publisher dependency

Stable Grafana 13.2.2 still has 104 HIGH findings: two Alpine OpenSSL, one main
binary Thrift, and 101 across bundled plugin executables. The affected plugins
have PGP-signed `MANIFEST.txt` files. Local binary replacement would invalidate
the publisher signatures; signature enforcement must not be bypassed or required
plugins removed to make the scan green. A patched compatible publisher release
(or publisher-signed replacement plugins plus a tested core rebuild) is required.
Nightly images are not treated as accepted stable replacements. No findings are
suppressed; the all-profile gate remains blocked until Grafana passes and the
PostgREST coverage gap is resolved.

The subsequent `docker/grafana/Dockerfile` rebuild pins the same publisher image
digest and upgrades only Alpine `libcrypto3` and `libssl3` from 3.5.7-r0 to
3.5.8-r0. A fresh local Trivy 0.74.0 scan with the same fixed HIGH/CRITICAL
threshold reports 102 HIGH findings: one main binary Thrift and 101 in signed
plugin executables. Checksums of all 681 bundled plugin files match the original
image byte for byte; no signature policy changed. The rebuilt image reports
Grafana 13.2.2 and a healthy local database on `/api/health`. The 102 findings
remain a hard gate. Rebuild from live Alpine repositories and rescan at deployment
time; this local scan is dated evidence, not a future patch guarantee.
The subsequent full 19-image inventory again had 17 valid passing reports,
Grafana's 102 findings, and an empty PostgREST package result. The strict gate
remained nonzero for exactly those two images.

On 2026-09-24, seven newer publisher-signed, Grafana-compatible bundled plugins
were pinned by version and publisher archive SHA-256, then installed into the
same Grafana 13.2.2 image. A fresh candidate-image Trivy 0.74.0 scan at the
fixed HIGH/CRITICAL threshold found **9 HIGH, 0 CRITICAL**: one in the core
binary and eight across the remaining bundled plugin executables. The candidate
passed an isolated startup check: all 13 bundled plugins retained valid Grafana
signatures, and the Prometheus/PostgreSQL datasource provisioning loaded. This
is a targeted candidate scan, not a new complete 19-image inventory or a passing
production image gate. The remaining findings and the PostgREST evidence gap
still require remediation and a complete strict rescan. The image and Compose
disable automatic catalog updates of preinstalled plugins, including the seven
pinned bundles; Grafana's separate first-install behavior remains unchanged.
See [Grafana's signing rules](https://grafana.com/developers/plugin-tools/publish-a-plugin/sign-a-plugin).

**2026-09-24 targeted amd64 recheck:** The current recipe was built on an amd64
host with `docker build --no-cache --pull=false -t
warehouse-grafana-review:20260924 -f docker/grafana/Dockerfile docker` from the
repository root. The resulting image ID was
`sha256:aa734a12badf82363db1cee53333339e5c1d6cbb52864c89c7ddba3a784c3abd`.
Trivy 0.74.0 ran `trivy image --quiet --scanners vuln --severity HIGH,CRITICAL
--ignore-unfixed --list-all-pkgs --exit-code 0 --format json --output <report>
warehouse-grafana-review:20260924`.
The image-specific report was rejected by
`node scripts/validate-image-report.mjs <report> <image>`: **9 HIGH, 0
CRITICAL**. The disposable image was removed. These are the exact fixed findings
in that Linux amd64 report (versions below are embedded dependency versions,
not plugin release numbers):

| Executable | Advisory | Embedded version | Fixed dependency version |
|---|---|---|---|
| Grafana core | [CVE-2026-43871](https://www.openwall.com/lists/oss-security/2026/07/24/33), Apache Thrift | `v0.23.1-0.20260429145742-d2acd3c49e58` | `0.24.0` |
| [PostgreSQL](https://grafana.com/grafana/plugins/grafana-postgresql-datasource/), [InfluxDB](https://grafana.com/grafana/plugins/influxdb/), [Jaeger](https://grafana.com/grafana/plugins/jaeger/), [Prometheus](https://grafana.com/grafana/plugins/prometheus/) plugin executables | [CVE-2026-84445](https://github.com/advisories/GHSA-2v4p-qf9q-27wj), gRPC | `v1.83.1` in each | `1.83.2` on the 1.83 line |
| [Google Cloud Monitoring](https://grafana.com/grafana/plugins/stackdriver/) plugin executable | [CVE-2026-84304](https://github.com/grpc/grpc-go/security/advisories/GHSA-vp52-pcj8-j9qc), gRPC | `v1.83.0` | `1.83.1` |
| Google Cloud Monitoring plugin executable | [CVE-2026-84445](https://github.com/advisories/GHSA-2v4p-qf9q-27wj), gRPC | `v1.83.0` | `1.83.2` on the 1.83 line |
| [Tempo](https://grafana.com/grafana/plugins/tempo/) plugin executable | [CVE-2026-21728](https://grafana.com/security/security-advisories/cve-2026-21728/), Tempo | `v1.5.1-0.20250529124718-87c2dc380cec` | `2.8.4`, `2.9.2`, or `2.10.2` on the respective release lines |
| Tempo plugin executable | [CVE-2026-28377](https://grafana.com/security/security-advisories/cve-2026-28377/), Tempo | Same `v1.5.1` pseudo-version | `2.10.3` |

The [Grafana publisher release list](https://github.com/grafana/grafana/releases)
still identified 13.2.2 as latest stable on 2026-09-24. The six affected
plugin catalog pages linked above did not provide a verified patched,
compatible signed release. A fixed dependency version in an advisory does not
establish that an installable publisher plugin contains it. No safe publisher
replacement candidate is identified yet. This was a targeted **amd64** image
scan, not a new full 19-image inventory. The last complete inventory remains
at 17/19 valid passing reports, with the older 102-HIGH Grafana result and the
PostgREST package-evidence gap. The strict full gate remains open and must be
rerun after a publisher fix.

**2026-09-24 targeted arm64 recheck:** The [native arm64 workflow run
35987888412](https://github.com/abhiguru/supabase-warehouse-template/actions/runs/35987888412)
passed at backend `80869391f2c8dfb7e700ffa99a68382ba7e769c4`. Its
`grafana-arm64-targeted-scan-35987888412-1` artifact records image
`warehouse-grafana-scan:35987888412-1`, image ID
`sha256:d7053286489f4c3d9f0f7e09c6bba3e00434c24f5984a31b05d2e2fc4e97eb24`,
and `linux/arm64`. The Trivy 0.74.0 JSON has **9 HIGH, 0 CRITICAL** at the same
fixed threshold. Its core Thrift finding and eight findings in the six arm64
plugin executables have the same CVEs, embedded versions and fix thresholds as
the amd64 table above. The workflow passes when it produces valid evidence; its
success does not mean the nine findings pass the strict image gate. This was a
targeted Grafana arm64 scan, not a new full 19-image inventory or a PostgREST
native build. The Grafana findings and PostgREST dependency evidence gap remain
open.

**2026-09-25 publisher-plugin recheck:** The [Grafana download page](https://grafana.com/grafana/download?edition=oss&pg=get)
still listed 13.2.2 as the stable application release. The publisher catalog
offered [Tempo 13.2.2](https://grafana.com/grafana/plugins/tempo/changelog/) and
[InfluxDB 13.1.5](https://grafana.com/grafana/plugins/influxdb/), both declaring
Grafana `>=12.3.0-0` compatibility. Their Linux amd64, arm64 and arm archives
were downloaded from
`https://grafana.com/api/plugins/<plugin>/versions/<version>/download?os=linux&arch=<arch>`.
Each archive contained a Grafana Labs PGP-signed `MANIFEST.txt`, and every
manifest-listed file matched its SHA-256. The archive SHA-256 values were:

| Plugin | amd64 | arm64 | arm |
|---|---|---|---|
| Tempo 13.2.2 | `36d53fdc7d0900b38f89e3e6da0babb7da99a2351caad6d19b736edda6deee8c` | `e174e7f0bb1fff4a729cec74290aaf848628ac7ac2d27c2fa5693092def69ecb` | `ad2dd2fc5c5f9ce04f81899f3083a9eb8caac9e408efe05846ae84f47fc39aa5` |
| InfluxDB 13.1.5 | `ef2234efde30055b51a1364f182ae20089b8f5cf712d93cefc3bc214e2bda38f` | `6d323f50a6c876a578be95c6f095516628ada410723b55e421a2796090beeb1d` | `8e30c1af7026524e180855a5facf144a6d998020280c3b4f00192bee79c05d02` |

All three InfluxDB executables still embed vulnerable gRPC
`v1.83.1`. All three Tempo executables embed patched gRPC `v1.83.2`, but retain
a `github.com/grafana/tempo` `v1.5.1-0.20260910130453-bcfe9f230c1d`
pseudo-version that Trivy still flags for CVE-2026-21728 and CVE-2026-28377.
An isolated Tempo-only lockfile candidate built on amd64 as image
`sha256:254f29240623a089f6dfb82852f57814de2973b259fe44548c7f4c06e37ed98e`.
Trivy 0.74.0 reported **9 HIGH, 0 CRITICAL**, and the strict image-report
validator rejected the candidate: the same core Thrift and plugin findings as
the prior candidate.
The isolated amd64 runtime check passed Grafana health, cryptographic validation
of all 13 publisher signatures, provisioning and live Prometheus/PostgreSQL
queries. The arm64 and arm archives were checked for signed-manifest presence
and manifest-listed file hashes only; they were not run. To reproduce the amd64
candidate, temporarily replace the three Tempo rows in `plugins.lock` with the
Tempo versions and checksums above, then run from the repository root:

```sh
docker build --no-cache --pull=false --platform linux/amd64 --build-arg TARGETARCH=amd64 -t warehouse-grafana-candidate:20260925 -f docker/grafana/Dockerfile docker
trivy image --quiet --scanners vuln --severity HIGH,CRITICAL --ignore-unfixed --list-all-pkgs --exit-code 0 --format json --output /tmp/grafana-candidate-20260925.json warehouse-grafana-candidate:20260925
node scripts/validate-image-report.mjs /tmp/grafana-candidate-20260925.json warehouse-grafana-candidate:20260925
bash scripts/grafana-check.sh
```

The validator is expected to reject the candidate's remaining findings. Because
the update did not reduce the fixed HIGH findings, the experimental lockfile
change was reverted.
This was an amd64 candidate scan; neither the arm64 candidate nor the complete
19-image inventory was rerun. The Grafana and PostgREST gates remain open.

**2026-09-25 core-build research:** [PR #63](https://github.com/abhiguru/supabase-warehouse-template/pull/63)
merged a manual Grafana 13.2.2 core-build recipe; that recipe and its
reproduction record were removed from the public repository under the
[won't-fix disposition](PRODUCTION_DEPENDENCIES.md#technical-follow-ups-and-dispositions). A native amd64 build from the
pinned release source with Apache Thrift 0.24.0 yielded a candidate whose Trivy
0.74.0 scan at the fixed HIGH/CRITICAL threshold no longer reports the single
Apache Thrift HIGH finding in Grafana's main executable. That scan reported
**8 HIGH, 0 CRITICAL** on the candidate image; all eight findings remain in
publisher-signed plugin executables, so the strict validator
rejected it. Startup, all 13 plugin signatures, provisioning, and live
Prometheus/PostgreSQL queries passed. The candidate build was not activated in
the ordinary Grafana recipe, and its native arm64 build has **not been run**.
The merged research commit is `3eda9686f71b48860464d74e9b42c3e3490fb239`;
[CI on that exact main commit](https://github.com/abhiguru/supabase-warehouse-template/actions/runs/36128411899)
passed all seven jobs. Those CI Grafana jobs exercise the ordinary signed-plugin
recipe on native amd64 and arm64 runners, not the manual core-build candidate.
The active Grafana image remains at **9 HIGH, 0 CRITICAL**, and the complete
19-image gate remains blocked by Grafana findings and PostgREST inventory.

**2026-09-26 unused-plugin prune candidate:** The candidate recipe
removes the InfluxDB, Jaeger, Google Cloud Monitoring (`stackdriver`) and Tempo
bundled plugin directories and their lockfile entries. The repository provisions
only Prometheus and PostgreSQL. A read-only audit of the owned local Grafana
volume found two data source types (`postgres` and `prometheus`), zero saved
dashboards and zero alert rules. This is local demo evidence, not an audit of
any production Grafana database. Before deployment, inspect each production
organization's saved data sources, dashboards and alert rules for references to
the four removed plugin IDs, and migrate any references before replacing the
image. Preserve a recoverable copy of that Grafana database.

The pruned recipe passed isolated native amd64 Grafana startup, validation of
the nine retained publisher signatures, provisioning and live
Prometheus/PostgreSQL queries. The [native targeted workflow run
36217948795](https://github.com/abhiguru/supabase-warehouse-template/actions/runs/36217948795)
passed on exact branch commit `d71f094`. It built image
`sha256:a3e89ab77dcee9b7e27334660f0ae2c648b5dfb6cf01df9181a312b924166ab3`
on amd64 and image
`sha256:8a9c4af83e68e93ebd9724b4d5ded8ccafa2aa9d4c76390c1971897b12fc2a62`
on arm64. Each targeted Trivy 0.74.0 report at the fixed HIGH/CRITICAL threshold
records **3 HIGH, 0 CRITICAL**: core Thrift CVE-2026-43871 and gRPC
CVE-2026-84445 in each of the retained Prometheus and PostgreSQL plugins.
Workflow success means both reports passed evidence validation; the findings
still fail the strict production image gate. The separate 2026-09-25 core-build
result above used the earlier 13-plugin recipe. Neither the strict full
19-image inventory nor PostgREST coverage has been rerun. These candidate
results do not change production readiness.

**2026-09-26 combined core and prune candidate, native amd64:** At repository
commit `f8fd060`, the pinned Grafana 13.2.2 source was rebuilt with Apache
Thrift 0.24.0 and packaged with the nine-plugin pruned recipe. The core binary
SHA-256 is
`232812b972f3a532faaed837a1389328785afa6ffa1a548cdf48c0d827c9dda9`;
the image contains that binary and has ID
`sha256:c0ab4d7141a31a2bfc277d5d476050e35739fd981c1ed6969dc6ed5173c77306`.
Its exact-image Trivy 0.74.0 report has **2 HIGH, 0 CRITICAL**, both
CVE-2026-84445 in gRPC v1.83.1 in the publisher-signed Prometheus and
PostgreSQL plugin executables. Grafana core's Thrift HIGH is absent. The smoke
check passed health, all nine publisher signatures, provisioning and live
Prometheus/PostgreSQL queries; the strict report validator rejected the two
remaining findings. The core candidate record, its build script and research
workflow were removed from the public repository; the
[won't-fix disposition](PRODUCTION_DEPENDENCIES.md#technical-follow-ups-and-dispositions) stands in for them. There is no combined
arm64 result or full 19-image rescan, and the production gate remains open.
The manual matrix requires explicit labels for larger, ephemeral
GitHub-hosted native runners with a conservative 25 GiB free-disk preflight
margin; it does not use a self-hosted Docker daemon. Standard hosted runners
have 14 GB total storage and fail that preflight. A qualified larger native
arm64 runner is not currently available.

A follow-up isolated query check found that the provisioned datasource hostnames
did not match the Compose service names. They now use `prometheus` and `db`.
With disposable Prometheus and PostgreSQL fixtures on a private Docker network,
Grafana returned the expected live metric and SQL row through `/api/ds/query`
on amd64. The CI smoke is configured to build and run the same signed-plugin,
provisioning, and query checks on native amd64 and arm64 runners. These checks
cover the two provisioned datasource paths; they do not clear the remaining
image findings or replace a full monitoring acceptance test.

## Remaining scan-coverage dependency: PostgREST

Compose has referenced `postgrest/postgrest:v16.4` since 2026-10-08. Everything
below was established for the v14.17 image and has not been repeated for
v16.4; the scan-coverage gap is assumed, not re-measured, for the new image.

Trivy detects no OS or language package results in the static PostgREST v14.17
image. `docker buildx imagetools inspect --format '{{json .SBOM}}'
postgrest/postgrest:v14.17` returned an empty object during this review. The
validator correctly rejects that report. Closure needs trustworthy dependency
inventory/SBOM tied to the published image and an applicable vulnerability
assessment, or a separately reviewed reproducible source build with equivalent
evidence. Do not fabricate scanner results or add dummy packages to manufacture
a passing result. The earlier zero-finding count is explicitly corrected above.

On 2026-09-23, the Linux amd64 image at
`postgrest/postgrest@sha256:c9dc201e555f5d8e37e7f39cdd4df0229774996e213bfd7de8d10ac609030f2c`
was compared with the publisher's v14.17
`postgrest-v14.17-linux-static-x86-64.tar.xz` release asset. The downloaded
archive matched its publisher SHA-256
`d6e13926457487c99b77366d795dcfa32700554d08d418131d9a4ea3f6ca25e3`;
the image's `/bin/postgrest` and extracted release executable both matched
SHA-256 `74a3ca24413d50071abc50d70ba77064c228c6dd7213d25c024e72b1ae167744`.
The [tagged build workflow](https://github.com/PostgREST/postgrest/blob/v14.17/.github/workflows/build.yaml)
uses Nix to produce the static executable and image from one source checkout;
its [release workflow](https://github.com/PostgREST/postgrest/blob/v14.17/.github/workflows/release.yaml)
publishes them. The tagged `flake.lock` pins Nix inputs. This establishes exact
publisher binary identity for amd64, but neither the image nor the release
contains an image-bound inventory of the bundled Haskell/native components.
Trivy still has no assessable package results, and the validator must continue
to reject this image. The amd64 hash does not attest the arm64 variant.

Publisher follow-up on 2026-09-23: [PostgREST v14.18](https://github.com/PostgREST/postgrest/releases/tag/v14.18)
has no SBOM release asset, and its container reports an empty SBOM. The attached
arm64 attestation records build provenance and the base-image digest, not an
inventory of statically linked components. GitHub's repository dependency-graph
SBOM lists documentation packages and CI actions, not the runtime Haskell/native
closure. None of these supplies the required image-bound vulnerability evidence;
updating the image to v14.18 solely for that purpose would not close the gate.
The [latest stable Grafana release](https://github.com/grafana/grafana/releases/tag/v13.2.2)
was still 13.2.2 on the same date, so no publisher-signed replacement is yet
available through a newer stable release.

The 2026-09-24 platform-specific investigation (its record was removed from
the public repository under the [won't-fix disposition](PRODUCTION_DEPENDENCIES.md#technical-follow-ups-and-dispositions))
found embedded `aeson` GHC unit IDs in the exact v14.17 publisher binaries:
2.2.3.0 on amd64 and 2.1.2.1 on arm64. Both are below the fixed 2.2.5.1 version
in [HSEC-2026-0007](https://github.com/haskell/security-advisories/blob/main/advisories/published/2026/HSEC-2026-0007.md),
a HIGH memory-exhaustion advisory. The inspected v14.18 and v16.3 publisher
images also contain affected `aeson` versions. Binary strings are partial and
cannot prove a complete inventory or absence of the separately affected
`text-iso8601` package. The current image therefore has both a known HIGH
component finding and an unresolved coverage gap. A remedial image needs an
image-bound Haskell/native component inventory and vulnerability assessment,
then warehouse API regressions and affected physical-iPhone retesting before a
PostgREST runtime change can inherit the accepted orders/cart evidence.

The patched source build plan, the manual arm64 native build (**NOT RUN,
deferred** as of 2026-09-24 because no suitable native arm64 machine or VM is
available) and the passed dependency-resolution experiment, together with their
research workflows and helper scripts, were removed from the public repository
under the [won't-fix disposition](PRODUCTION_DEPENDENCIES.md#technical-follow-ups-and-dispositions). None of them
supplied a compiled binary, image-bound inventory, or runtime evidence; the
PostgREST security gate remains open.

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
CI at HIGH/CRITICAL severity. At the earlier source follow-up, metadata passed
that threshold with 20 moderate findings remaining, while Storage reported zero
findings. At that earlier revision, the metadata source passed all 197 upstream
tests on a fresh isolated fixture database, and the deployed Studio/API/image/PDF
checks passed. Test databases must be recreated between full upstream runs:
upstream fixtures retain a helper function after completion.

On 2026-10-07 the metadata audit failed on advisories published after the last
green run: tinypool <=2.1.1 (GHSA-5gmw-xhrv-c9v3, GHSA-85c8-ppgw-ccpr, both
critical), shipped as a production dependency of the pinned type generator via
oxfmt; and the build-only shell-quote (GHSA-pqg4-j6r4-53mv) and source-map-js
(GHSA-68fv-2mgg-jv7q). Exact overrides select the first patched releases:
tinypool 2.1.2, shell-quote 1.11.0 and source-map-js 1.2.2. The type generator
and oxfmt stay pinned; oxfmt formatting of generated output was re-run against
tinypool 2.1.2. `npm ls --omit=dev` and the metadata audit pass. The VM's
currently running metadata image was built before this change and still
contained tinypool 2.1.0 until the final soak ended; it was then rebuilt
from `3d70f6a` (image `sha256:6042abe0…`, tinypool 2.1.2 only, no
shell-quote) and the metadata service recreated healthy with business and
authentication digests unchanged (pilot evidence, archived; see [HISTORY.md](HISTORY.md)).

**2026-09-24 metadata dependency candidate:** The tracked postgres-meta manifest
now pins `vitest` and `@vitest/coverage-v8` to 4.1.11, which resolves
`@vitest/mocker` 4.1.11. That is the patched 4.x version for
[GHSA-82fw-gwwq-j7x9](https://github.com/advisories/GHSA-82fw-gwwq-j7x9).
It also pins `@sentry/node` and `@sentry/profiling-node` together at 10.75.2;
the locked runtime graph resolves `@opentelemetry/core` 2.11.0, above the 2.8.0
fix for [GHSA-8988-4f7v-96qf](https://github.com/advisories/GHSA-8988-4f7v-96qf).
The combined postgres-meta image build passed TypeScript checking, compilation,
all 12 tests in the three selected upstream app/admin/helper files, production
pruning and `npm ls --omit=dev`. `npm ci` and the full npm audit reported zero
vulnerabilities for its locked graph. A targeted Trivy 0.74.0 fixed
HIGH/CRITICAL scan of that combined image passed the strict image-report
validator. The earlier Sentry-only candidate also passed a network-disabled
container probe with a dummy DSN: initialization, `pg` and
`x-connection-encrypted` span redaction, and `/health` HTTP 200. A separate
in-memory Sentry transport probe captured a synthetic event and completed
`flush`; it did not test delivery to an external Sentry endpoint or production
DSN.

The first full upstream run with Vitest 4 failed during test collection because
one existing test passed its timeout options after the callback. The
test-only [`vitest4.patch`](../docker/postgres-meta/vitest4.patch) moves the
timeout options before the callback for Vitest 4; production source is
unchanged. With that patch and a fresh disposable database, the combined
candidate passed **13/13 test files and 197/197 tests**. These local checks do
not establish GitHub alert state or production acceptance; CI and the full
19-image/runtime gates still apply.

The earlier manifest inventory also reported a HIGH advisory
`GHSA-jqcq-xjh3-6g23` for `github.com/jackc/pgproto3/v2` in the optional disabled
Auth service, plus lower-severity upstream findings. These are not erased by
`--ignore-unfixed`. The local source candidate below addresses the reported
decoder behavior while upstream v2 has no patched release. GoTrue is still
disabled and production authentication is not accepted.

**2026-09-24 Auth source candidate:** The [advisory](https://github.com/advisories/GHSA-jqcq-xjh3-6g23)
and [Go vulnerability record](https://pkg.go.dev/vuln/GO-2026-4518) list no
patched publisher version of `pgproto3/v2`. Auth still requires v2.3.3 through
`pgconn v1.14.3`, so its build now uses a local v2.3.3 source replacement.
[PATCH.md](../docker/auth/internal/forks/pgproto3/PATCH.md) records the upstream
tag commit `945c2126f6db8f3bea7eeebe307c01fe92bca007`, archive SHA-256,
license and one production change: `DataRow.Decode` rejects negative field
lengths other than the valid `-1` null sentinel before slicing. The local
regression tests exercise `-2`, minimum int32 and `-1`; the Auth Docker build
runs those tests, selected upstream Auth crypto tests, `go mod verify` for
downloaded modules and compilation. The final image copies the fork's MIT
license notice to `/usr/share/doc/warehouse-auth/pgproto3-LICENSE`. A targeted Trivy 0.74.0
fixed HIGH/CRITICAL scan of the Auth candidate passed the strict image-report
validator. The local `replace` makes the compiled source differ from the
published v2.3.3 module even though the requirement retains that version.
Scanners that identify dependencies only by published module versions cannot
attribute the patch to this unversioned local replacement; a remaining version
finding or a missing finding alone does not establish its source status. The
targeted scan's PASS therefore does not prove the patched decoder behavior;
that conclusion rests on source, regression and build review. GoTrue remains
disabled. The full 19-image gate, Auth runtime/database acceptance and GitHub
alert verification remain open. A maintained upstream driver remains the
long-term replacement.

The first GitHub integration runs failed during pooler startup although a fresh
local database/pooler passed. Redacted diagnostics identified the cause: the
upstream entrypoint raises `RLIMIT_NOFILE` to 100000, which fails when the
container inherits CI's lower hard limit. Compose now declares both soft and
hard `nofile` limits as 100000. The failure is reproducible with Docker's
`--ulimit nofile=65536:65536`; the declared 100000 limit permits startup without
adding privileges. Migration/tenant/server startup also has a 60-second health
grace period, probe connections are bounded, and failures produce redacted
diagnostics. All five PR #29 checks passed, and the resulting-main pooler check
also passed. That main run exposed a separate setup-rerun readiness race: the
gateway returned HTTP 502 for configuration immediately after function-container
recreation despite green container health. Internal HTTP probes now wait up to
90 seconds for transport failures and HTTP 502/503/504; other HTTP errors fail
immediately and persistent outages still fail. Final paired CI evidence is
recorded in the corrective PR rather than claiming closure from local checks.

## Source dependency refresh644 (not an image scan)

The failed operator-review CI36858689257 exposed stale pinned metadata leaves;
its short-circuited Storage audit separately reported22 findings. The operator
review candidate updates same-major leaf pins and locks; both source audits now
report zero locally. Metadata typecheck/build/12recipe tests, Storage clean install/
graph check and80backend tests passed. See
the pilot setup notes (archived with the private pilot evidence, see
[HISTORY.md](HISTORY.md)) for versions, commands and limits. No running container changed. Historical image
findings above are not cleared by npm audit; the deferred image/security and
production gates remain separate. Fresh CI/container integration is pending.

## Network boundaries (2026-10-11)

Until this change every service shared one Compose network. postgres-meta
answers on `meta:8080` without a credential and runs any SQL as
`supabase_admin`, and Studio (no login) forwards SQL to it, so a foothold in
any container, for example in the Chromium that renders PDFs, was superuser
SQL. The project now has three networks; the table is in
[ARCHITECTURE.md](ARCHITECTURE.md#containers-and-networks).

- `meta` is reachable from `studio` and `db` only; `studio` from `meta` and
  `db` only.
- `db` is reachable from the services that hold a database connection (rest,
  realtime, storage, supavisor, the disabled auth service, postgres-exporter,
  grafana) and from the admin pair. Kong, the function runtime, Gotenberg,
  imgproxy, CUPS, Prometheus, Alertmanager, node-exporter and cAdvisor cannot
  connect to it.
- Operator probes follow the same rule: `health-check.sh` and
  `scripts/gateway-dns-check.sh` call the gateway from the `storage` container
  (they used Studio), and postgres-meta from Studio.

What this does not do:

- Services on `default` still reach each other without Kong's limits
  (`functions:9000`, `imgproxy:5001`, `storage:5000`, `rest:3000`,
  `prometheus:9090`). PostgREST, Storage and the functions check tokens
  themselves; imgproxy and Prometheus do not.
- A service on `database` can open a connection to PostgreSQL; what it can do
  there is still decided by one shared password (next section).
- The networks are ordinary bridges, not `internal: true`: the database needs
  outbound HTTPS for the SMS provider, and Studio and postgres-meta were left
  with the outbound access they had. Making `admin` internal is a possible
  later step and needs a run on real containers.
- Studio's Storage, Auth and API panels call `http://kong:8000`, which Studio
  can no longer reach. No operator procedure uses Studio's interface and no
  host port is published for it. Attaching Studio to `default` to use those
  panels reopens the path this change closes.

Each install now creates three Docker networks instead of one. A host that
runs many Compose projects can exhaust Docker's default address pools
(about 30 networks); `docker network prune` removes unused ones.

## Edge function modules (2026-10-11)

The functions load three remote modules when a worker first starts: the Deno
standard library 0.192.0 from deno.land, and supabase-js 2.39.0 and jose 5.10.0
from esm.sh. The printing functions, which the router refuses with 503, import
`npm:ipp@2.0.1` on demand.

- `functions/import_map.json` is the one list of those URLs.
  `tests/edge-imports.test.mjs` fails on any remote import that is not in the
  list, on a list entry without an exact version, on a list entry nothing
  imports, and on an `npm:` import without an exact version.
- supabase-js was imported at 2.39.0 by the functions that run (configuration
  and PDFs) and at 2.39.3 by the printing functions that do not. All now use
  2.39.0, so no running function changed version.
- The unit tests verify tokens with jose 5.10.0, the release the runtime
  loads (`package.json` pins it; Dependabot version updates for it are held so
  the two move together). They ran on jose 6 before.

Still open:

- **No lock file.** A URL pins the top-level version only; esm.sh resolves that
  module's own dependencies when it serves it, and nothing checks content
  hashes. The module cache lives in the container and is refetched after the
  container is recreated. To close this, on a machine with the Deno release
  that matches the edge runtime in `docker/edge-runtime/Dockerfile` (Deno is
  not installed where this was written, so the command is a starting point
  and has not been run):

  ```bash
  cd functions
  deno cache --lock=deno.lock --frozen=false --import-map=import_map.json \
    main/index.ts hello/index.ts get-public-config/index.ts operator-otp/index.ts \
    get-config/index.ts generate-*-pdf/index.ts
  git add deno.lock
  ```

  Then make the runtime refuse a module that is not in the lock. How the
  pinned edge-runtime release takes a lock file (a `deno.json` beside the
  functions with `"lock": {"frozen": true}`, or a start-up flag) is not
  recorded in this repository and was not tested, so no such setting is
  committed. Confirm it against that release, start the stack, call
  `get-public-config`, `operator-otp`, `get-config` and one PDF function, and
  only then commit the setting. A second option that needs no runtime support
  is to vendor the three modules under `functions/vendor/` and point the
  import map at the files.
- **The functions import by full URL, not through the import map's names.**
  `functions/_shared/jwt.ts` is loaded by the main service as well as by the
  workers, and only the workers are given the import map
  (`functions/main/index.ts`). Switching to bare names therefore needs the
  main service to receive the map too, and a failure there leaves the
  functions container unhealthy. It needs a run on the edge runtime first.
- jose 5 to 6 and supabase-js 2.39 to a current 2.x release are version
  moves for the same run.

## Image pins (2026-10-11)

Every service image is either built from a Dockerfile whose `FROM` lines carry
a digest, or referenced with a digest in Compose, with one exception:

| Image | State |
|---|---|
| `kong:3.9.3-ubuntu` | Pinned to `sha256:12972ce1ab6396083e56e7d46fce084836c98cc819344bef44a1f583ec3ab191`, the multi-platform index (linux/amd64 and linux/arm64) published for that tag on 2026-09-16, read from a local copy of the image and confirmed against the registry. Dependabot's `docker-compose` updates propose a new digest when the tag is rebuilt. |
| `postgrest/postgrest:v16.4` | **Tag only.** The image was not available locally to read a digest from. On a host that has pulled it: `docker image inspect --format '{{index .RepoDigests 0}}' postgrest/postgrest:v16.4`, confirm with `docker buildx imagetools inspect` that the digest is an index covering amd64 and arm64, write it after the tag in `docker/docker-compose.yml`, and remove the exception in `tests/gateway-config.test.mjs`. |

Kong still has no recipe of its own, so its Ubuntu packages are as old as the
pinned build; the pin makes that explicit instead of leaving it to whichever
build a host pulled first. A `docker/kong/Dockerfile` with an
`apt-get upgrade` step, as Realtime and Supavisor have, would need a build and
a gateway run and is not part of this change.

`THIRD_PARTY_NOTICES.md` and `docs/ATTRIBUTION_REVIEW.md` named PostgREST
v14.17 and edge-runtime v1.76.2 after Compose and the Dockerfile had moved to
v16.4 and v1.77.4. They are corrected, and `tests/gateway-config.test.mjs` now
reads the versions from Compose and the Dockerfiles and fails when either
document names a different one.

## Gateway limits and metrics (2026-10-11)

- The GraphQL route and both Realtime routes had the public-key check but no
  rate limit. They now have the REST route's limit (300 requests a minute and
  6000 an hour per client address); on the WebSocket route it counts
  connection attempts, not messages. The Realtime HTTP route also has a 2 MB
  body limit.
- The storage route still has no rate limit. A list screen loads one image per
  row and every phone at a facility shares one public address, so a limit low
  enough to matter could refuse ordinary use; it needs request counts from a
  running facility before a number is chosen.
- The Prometheus plugin is enabled for all routes (see
  [MONITORING.md](MONITORING.md)). Its series are served on the status
  listener (port 8100, inside the Compose project only), not on the proxy port.
- `docker/kong.yml` is filled in by a shell `eval` in the gateway entrypoint,
  so a double quote, backtick or backslash anywhere in the file, comments
  included, is silently altered. `tests/gateway-config.test.mjs` now runs the
  same evaluation and compares the result; it found one such comment.
- These gateway changes were checked by parsing the evaluated file and by
  reading the plugin schemas in the pinned Kong image. Kong itself has not
  loaded the file.

## Database passwords: one shared value, and the plan to split it

Not changed in this release. This section is the design and the procedure for
the change, written from the files named in it; nothing in it has been run.

### Today

`POSTGRES_PASSWORD` is the password of every database login:

| Role | Set by | Used by |
|---|---|---|
| `postgres`, `supabase_admin` (superusers) | the database image's entrypoint, first start only | operator scripts (`compose exec db psql -U supabase_admin`), Realtime (`DB_USER`), postgres-meta, Supavisor's own metadata (`_supabase` database), Postgres exporter and Grafana (`postgres`) |
| `authenticator` | `docker/volumes/db/roles.sql`, first start only | PostgREST |
| `supabase_storage_admin` | same | Storage |
| `supabase_auth_admin` | same | the disabled Auth service |
| `supabase_functions_admin` | same | nothing |
| `pgbouncer` | same | Supavisor's pool user (pooler profile) |

Three more copies exist: Studio is given the value; Realtime stores its
tenant's database credentials in `_realtime.extensions`, encrypted with
`DB_ENC_KEY`, which is the fixed text `supabaserealtime` in
`docker/docker-compose.yml`; Supavisor stores the pool user's password in its
tenant record, encrypted with `VAULT_ENC_KEY`, written only when the tenant
does not exist yet (`docker/volumes/pooler/pooler.exs`).

`roles.sql` is an init script: it runs when the data directory is empty and
never again. `db:backup` dumps databases, not roles, so role passwords are not
in a backup; a restore onto an empty data directory sets them again from
`compose.env` through the same init scripts.

Since the network change above, only services on the `database` and `admin`
networks can present this password to PostgreSQL at all.

### Target

- New 64-hex values generated by `scripts/configure.mjs` next to
  `POSTGRES_PASSWORD`: `DB_PASSWORD_AUTHENTICATOR`, `DB_PASSWORD_STORAGE`,
  `DB_PASSWORD_AUTH`, `DB_PASSWORD_POOLER`, `DB_PASSWORD_MONITORING`, and
  `REALTIME_DB_ENC_KEY` (16 characters, the length Realtime requires).
- `supabase_functions_admin` gets a random password that is stored nowhere, or
  `NOLOGIN` if a start confirms nothing logs in as it.
- A new role `warehouse_monitoring` (`LOGIN`, member of `pg_monitor`, no other
  grant) for the Postgres exporter and the Grafana datasource, which today
  connect as the `postgres` superuser. The role itself can be created by a
  migration (`CREATE ROLE ... NOLOGIN` if absent, `GRANT pg_monitor`) and
  asserted in `tests/security_baseline.sql`; its password and `LOGIN` are set
  by the step below, because a migration must not contain a secret.
- `POSTGRES_PASSWORD` stays the superuser password, used by operator scripts,
  postgres-meta, Realtime and Supavisor's metadata connection. Giving Realtime
  a non-superuser role is a later, separate step: it creates its own schema
  and replication slot and its needs must be measured on a running stack.

### Changes, in order

1. `scripts/configure.mjs`: generate the new values for a fresh state. In the
   existing-state branch (where the backup key is created for older
   installs), append any that are missing; never replace one that exists.
   `tests/configure.test.mjs`: fresh state has them, rerun preserves them, a
   state written by the previous release gains them.
2. New `scripts/configure-db-roles.sql`, run by `setup.sh` after the migration
   ledger and before the services start, with `psql -v`: one
   `ALTER ROLE ... WITH LOGIN PASSWORD :'value'` per role above. It is
   idempotent and is what an existing install relies on, because `roles.sql`
   does not run again. Keep `roles.sql` (it still makes a first start usable
   before setup reaches this step) but have it read the per-role variables
   from the database container's environment, which then needs them added
   under `db: environment:`.
3. `docker/docker-compose.yml` and the override: `PGRST_DB_URI`
   (`DB_PASSWORD_AUTHENTICATOR`), Storage `DATABASE_URL`
   (`DB_PASSWORD_STORAGE`), `GOTRUE_DB_DATABASE_URL` (`DB_PASSWORD_AUTH`),
   exporter `DATA_SOURCE_NAME` and the Grafana datasource
   (`warehouse_monitoring`, `DB_PASSWORD_MONITORING`; drop `POSTGRES_PASSWORD`
   from the Grafana service and set the datasource `editable: false`),
   `pooler.exs` (`DB_PASSWORD_POOLER`), Realtime `DB_ENC_KEY`. Use
   `${NAME:?...}` so a state without the value fails at `compose config`
   with a message, not at first login. `tests/compose-networks.test.mjs` can
   then assert from the rendered configuration that the superuser password
   appears only in db, meta, realtime, supavisor and studio.
4. Stored copies. Supavisor: the script must update the tenant's user when it
   exists instead of skipping it (or `scripts/pooler-check.sh` must fail with
   a clear message telling the operator to remove the tenant row). Realtime:
   changing `DB_ENC_KEY` makes the existing `_realtime.extensions` row
   unreadable; delete the `realtime-dev` tenant rows in the same step so
   `SEED_SELF_HOST` writes them again with the new key. `rotate-keys.sh`
   already removes that tenant row for a signing-key rotation
   (`docs/OPERATOR_INSTALL.md`), so the statement exists.
5. `rotate-keys.sh` (or a new `db:rotate-passwords`): generate new per-role
   values into a staged `compose.env`, run `configure-db-roles.sql`, recreate
   the consumers, and roll back the file if a consumer does not become
   healthy, as the signing-key rotation does. Rotating the superuser password
   is the last piece: `ALTER ROLE postgres` and `supabase_admin`, then both
   stored tenants, then every service.
6. Backup and restore: `restore.sh` compares `compose.env` with the backup's
   copy and `restore-host.sh` adopts the backup's copy; both then start from
   an empty data directory, so `roles.sql` and `configure-db-roles.sql` apply
   whatever that file holds. A backup taken before this change has no
   per-role values: `configure.mjs`'s existing-state branch must run before
   the database starts in both restore paths.

### Upgrade of an existing install

`git pull`, then the same `setup.sh --operator ...` command. Expected
sequence: `configure.mjs` appends the missing values; the database starts;
migrations run; `configure-db-roles.sql` changes the passwords while the old
containers still hold open connections (those stay valid; a new connection
from an old container fails until it is recreated); `up -d --wait` recreates
every consumer with its new address. The window in which PostgREST or Storage
cannot open a new connection is the time between those two steps.

### Drill before release

On a disposable host, never on a facility:

1. Install the previous release with `setup.sh --operator`, run
   `tests/operator-api-core.mjs`, take a `db:backup`.
2. Check out the change, run the same `setup.sh` command. `node
   scripts/doctor.mjs --local` must pass.
3. For each of `authenticator`, `supabase_storage_admin`, `pgbouncer`:
   `compose exec -T db sh -c 'PGPASSWORD="$POSTGRES_PASSWORD" psql -h
   127.0.0.1 -U <role> -d postgres -c "select 1"'` must fail, and the same
   with the role's own value must succeed.
4. `tests/operator-api-core.mjs`, `tests/operator-realtime-core.mjs`,
   `npm run test:pooler`, `npm run test:monitoring`, `npm run test:grafana`.
5. `npm run keys:rotate`, then step 4 again (Realtime tenant re-seeded).
6. `db:backup`, `db:verify-restore`, `db:restore --yes`, and on a second
   state directory `db:restore-host` from the backup taken in step 1 (no
   per-role values) and from the new one. Step 4 after each.
7. The `operator-install` CI job covers a fresh install; add the upgrade from
   the previous tag as a second job before relying on it.

## Open items with their steps

Each of these was left unchanged because the change cannot be checked without
building an image or starting the stack.

- **Go builders (three fixed HIGH standard-library advisories).** Ten `FROM
  golang:` lines use 1.27.0 or 1.27.1: line 1 of
  `docker/{alertmanager,cadvisor,node-exporter,postgres-exporter}/Dockerfile`
  (`golang:1.27.0-bookworm@sha256:ded31c68...`), and line 1 of
  `docker/{auth,gotenberg,imgproxy,prometheus,postgres}/Dockerfile` plus line
  12 of `docker/postgres/Dockerfile` (`golang:1.27.1-bookworm@sha256:69a7b978...`).
  Replace all ten with the patch release that fixes the advisories and its
  digest (`docker pull golang:<version>-bookworm`, then `docker image inspect
  --format '{{index .RepoDigests 0}}'`); the fixed image was not available
  locally, so no digest could be read. Each recipe runs `go mod verify` and
  its selected tests during the build; follow with `npm run scan:images`.
  The Gotenberg server binary is the publisher's and is not rebuilt by any
  recipe.
- **Studio application advisories.** The recipe now applies Debian updates,
  which addresses the operating-system findings at build time. The Next.js
  and simple-git advisories are in the publisher's application and need a
  Studio tag that ships fixed versions (the review named next 16.3.6 and
  simple-git 4.0.1 as the first fixed releases); change the tag and digest in
  `docker/studio/Dockerfile`, then `npm run test:studio`. Until then the
  exposure is bounded by the network change: only postgres-meta and the
  database can reach Studio. The scan numbers in the table near the top of
  this page are from 2026-09-22 and an older tag; they have not been
  re-measured.
- **Edge runtime and Storage operating-system packages.**
  `docker/edge-runtime/Dockerfile` upgrades one package; replacing that with a
  full `apt-get upgrade` (keeping the PCRE2 version check) and adding
  `apk upgrade --no-cache` to `docker/storage/Dockerfile` both change images
  that every request depends on. Build, then run the operator API and
  document tests.
- **Storage `npm install`.** `npm ci` would fail on lock drift, but it deletes
  `node_modules` first, and the recipe keeps the publisher's prebuilt native
  modules and runs no install scripts, so they would not be rebuilt. Moving
  to `npm ci` needs a build that proves Storage still starts.
- **Gotenberg Chromium switches.** `CHROMIUM_DISABLE_JAVASCRIPT=true` and
  removing `CHROMIUM_ALLOW_FILE_ACCESS_FROM_FILES` look safe, since the
  templates carry no scripts or file links, but need a rendered PDF compared
  with the current output. Gotenberg can no longer reach the database,
  postgres-meta or Studio.
- **Gateway configuration through shell `eval`.** Replacing the entrypoint's
  `eval` with Kong's own environment references needs Kong to load the result.
  The new test catches a character the `eval` would alter.
- **`net.http_get` and `net.http_post` executable by `anon` and
  `authenticated`.** The grants come from `docker/volumes/db/webhooks.sql` (an
  init script) and from the event trigger it installs, which re-grants on
  `CREATE EXTENSION`. The fix is to remove the two roles from both `GRANT`
  lists there and add a migration that revokes them where the `net` schema
  exists. The migration test database is the plain publisher image without
  these init scripts, so the migration could not be exercised by
  `tests/migrations.sh`; mount `webhooks.sql` in that test first. The `net`
  schema is not exposed through PostgREST.
- **`app.settings.jwt_secret` readable by every database role.** Unchanged;
  see the earlier review note (needs a migration and the removal of
  `PGRST_APP_SETTINGS_JWT_SECRET`, then a check that nothing reads it).
- **`no-new-privileges`, dropped capabilities, read-only root filesystems.**
  Not a blanket change: Realtime's start script runs `sudo -u nobody`
  (`/app/run.sh` in the pinned image), which `no-new-privileges` blocks, and
  Kong's entrypoint writes `/tmp/kong.yml`. Each service needs its own trial.
- **cAdvisor and CUPS run privileged.** Both are optional profiles. CUPS also
  accepts print jobs from any container on `default` without a login; no
  function reaches it while the router refuses the printing functions.
- **Scheduled image scan.** No workflow runs `npm run scan:images`; the image
  gate was closed as "won't fix in current scope" in
  [PRODUCTION_DEPENDENCIES.md](PRODUCTION_DEPENDENCIES.md).

## Changes awaiting a first run (2026-10-11)

These were committed after unit tests, `docker compose config` on generated
state and, where noted, reading the pinned images. None has run on started
containers. The `operator-install` CI job is the first run; if it fails, the
step that fails points at the change.

| Change | What a first run proves | CI step that exercises it |
|---|---|---|
| Three networks; Studio and postgres-meta off `default` | every service starts healthy and resolves its peers | setup, then every later step |
| Health probes from `storage` instead of Studio | `node --input-type=module` from stdin works in the Storage image and reaches the gateway | setup (`doctor --local`), key rotation, recovery |
| `gateway-dns-check.sh` probes from `storage` | same | Gateway upstream IP replacement |
| Per-function worker environment | each function still has every variable it reads | setup health check, operator API, documents |
| supabase-js 2.39.0 and `npm:ipp@2.0.1` in the printing functions | nothing: the router refuses them | none |
| Kong image by digest | the digest pulls on the runner | setup |
| Prometheus plugin enabled globally; new rate limits | Kong accepts the declarative file; Realtime connects through the limit | setup, Realtime test, gateway test |
| Alert rules and `monitoring-check.sh` metric check | Prometheus scrapes `kong_http_requests_total` | Monitoring targets |
| Prometheus without `--web.enable-lifecycle` | Prometheus starts | Monitoring targets |
| Log cap on every service; imgproxy read-only mount | containers start; image transformation still reads files | setup, document tests |
| Pooler tenant with one user | tenant creation succeeds | Pooler authentication |
| Studio and CUPS `apt-get upgrade` | both images build | setup (Studio), CUPS startup |
| Actions pinned to commits | the hashes resolve | every job |

