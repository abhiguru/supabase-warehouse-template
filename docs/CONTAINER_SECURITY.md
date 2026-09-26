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
merged a manual Grafana 13.2.2 core-build recipe and its
[reproduction record](GRAFANA_CORE_CANDIDATE.md). A native amd64 build from the
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
Prometheus/PostgreSQL queries. Its targeted Trivy 0.74.0 image scan at the
fixed HIGH/CRITICAL threshold reported **3 HIGH, 0 CRITICAL**: one Apache
Thrift finding in Grafana core and one gRPC finding each in the retained
Prometheus and PostgreSQL plugins. The strict image-report validator still
rejects it. A native arm64 build and scan of this pruned candidate are pending;
the separate 2026-09-25 core-build result above has not been combined with it.
Neither the strict full 19-image inventory nor PostgREST coverage has been
rerun. These candidate results do not change production readiness.

A follow-up isolated query check found that the provisioned datasource hostnames
did not match the Compose service names. They now use `prometheus` and `db`.
With disposable Prometheus and PostgreSQL fixtures on a private Docker network,
Grafana returned the expected live metric and SQL row through `/api/ds/query`
on amd64. The CI smoke is configured to build and run the same signed-plugin,
provisioning, and query checks on native amd64 and arm64 runners. These checks
cover the two provisioned datasource paths; they do not clear the remaining
image findings or replace a full monitoring acceptance test.

## Remaining scan-coverage dependency: PostgREST

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

The [2026-09-24 platform-specific investigation](POSTGREST_IMAGE_INVESTIGATION.md)
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

The [patched source build plan](POSTGREST_PATCHED_BUILD_PLAN.md) records the
separate platform builds and evidence needed before proposing a replacement.
The [manual arm64 native build](POSTGREST_NATIVE_BUILD_EVIDENCE.md) is
**NOT RUN, deferred** as of 2026-09-24 because no suitable native arm64 machine
or VM is available. The passed
[dependency-resolution experiment](POSTGREST_RESOLUTION_EXPERIMENT.md) does not
supply a compiled binary, image-bound inventory, or runtime evidence; the
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
