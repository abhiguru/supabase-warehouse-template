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
| Prometheus | 3.15.0 | Patched Go/crypto/gRPC; matching official UI embedded in both executables |
| Auth (disabled profile) | 2.196.0 | Patched Go/crypto/mod/gRPC and Alpine OpenSSL; local `pgproto3/v2` v2.3.3 DataRow length guard; unchanged auth application and migrations |
| Storage | 1.80.2 | Upgrade from 1.79.14; same-major runtime leaf fixes in locked npm manifest (2026-10-13: `@fastify/busboy` 3.2.3 for [GHSA-gxm5-99cw-xjw9](https://github.com/advisories/GHSA-gxm5-99cw-xjw9), `fast-copy` 4.1.2 for [GHSA-jggr-w7fw-pc2j](https://github.com/advisories/GHSA-jggr-w7fw-pc2j), both moderate); Alpine package upgrade; remove unused npm CLI |
| PDF renderer | Node 24 LTS (digest), chrome-headless-shell 155.0.8059.84 from Chrome for Testing (SHA-256 pinned), puppeteer-core | Our own code (`docker/pdf-renderer`), no upstream patch; Debian font and library packages only; see "PDF renderer" |
| imgproxy | 3.31.4 | Patched Go/crypto/image/mod/gRPC; matching vips builder; retain native libraries and apply Debian updates |
| Supavisor (pooler profile) | 2.9.13 | Patch release from 2.9.12 plus Debian updates |
| PostgreSQL | 15.8.1.135 | Same database server/extensions; upgrade the Ubuntu packages with a fixed advisory (linux-libc-dev; since 2026-10-17 also OpenSSL, GnuPG, PackageKit, sudo) with glibc and locale data unchanged; rebuild gosu 1.19 and WAL-G 3.0.9 with patched Go/gRPC |

Go rebuilds use the versions locked in their Dockerfiles. Nothing is
suppressed in the scanner. Since 2026-10-17 the rows that cannot be fixed yet
are listed in `docker/image-exceptions.json`, a time-boxed ignore list: each
entry is bound to one recipe, has a named owner and expires at most 90 days
after its review (see "Exception ledger and the two-pass scan"). Required
applications are retained. The source and license
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
| Studio 2026.09.07-sha-7996410 | 3 | 90 |
| postgres-meta 0.99.0 | 1 | 29 |

Each scan report was validated for presence, format, nonempty results, image
identity and findings. Private machine-readable inventory stays outside Git.
The commands to reproduce are `npm run scan:images`, `npm run test:monitoring`,
`npm run test:pooler`, `npm run test:recovery`, `npm run db:backup` and
`npm run db:verify-restore`, with a unique owned loopback demo project. The API
contract is checked with `npm run check:contract -- <app path>` (CI's contract
job runs it against the pinned app commit); the API and Realtime drivers
(`tests/operator-api-core.mjs`, `tests/operator-realtime-core.mjs` and the
others listed in `docs/DEVELOPER_HANDOFF.md`) run in CI's operator-install job.

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
PostgREST lacks scannable package results and is
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

**2026-10-17, v16.4 pinned and a time-boxed exception (TW-BE-010, owner
decision D3, option c):** Compose now pins `postgrest/postgrest:v16.4` to its
index digest (see "Image pins"). A Trivy 0.74.0 scan of that image, with the
flags of `scripts/scan-images.sh`, again returned no package results, so the
gate still cannot assess it. Instead of a passing result it has the exception
`rest-no-package-inventory` in `docker/image-exceptions.json`: owner
`abhiguru`, reviewed 2026-10-17, expiring 2027-01-15, valid only for that
digest (the image reference and the scanned image's repository digest must
both carry it), with its compensating controls listed (no host port; outside
requests only through Kong with key-auth, a 10 MB body limit and the REST rate
limit; `public.check_session` before every request; business writes only
through RPCs guarded by `authorize_rpc`). The exception does not establish that
v16.4 is free of the `aeson` advisory above; it records an accepted, dated gap.
The planned closure is option (a), a source build whose dependency closure
(cabal freeze or Nix lock) becomes an image-bound inventory. Do not add
fabricated packages to the report instead.

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
CI at HIGH/CRITICAL severity (and, since 2026-10-18, the PDF renderer's production graph, `--omit=dev`, at the same HIGH/CRITICAL threshold). At the earlier source follow-up, metadata passed
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
SQL. The project now has four networks; the table is in
[ARCHITECTURE.md](ARCHITECTURE.md#containers-and-networks).

- `meta` is reachable from `studio` and `db` only; `studio` from `meta` and
  `db` only.
- `db` is reachable from the services that hold a database connection (rest,
  realtime, storage, supavisor, the disabled auth service, postgres-exporter) and from the admin pair. Kong, the function runtime, the PDF renderer,
  imgproxy, CUPS, the sensor bridge, Prometheus, Alertmanager, node-exporter
  and cAdvisor cannot connect to it.
- Operator probes follow the same rule: `health-check.sh` and
  `scripts/gateway-dns-check.sh` call the gateway from the `storage` container
  (they used Studio), and postgres-meta from Studio.

What this does not do:

- Services on `default` still reach each other without Kong's limits
  (`functions:9000`, `imgproxy:5001`, `storage:5000`, `rest:3000`,
  `prometheus:9090`). PostgREST, Storage and the functions check tokens
  themselves; imgproxy and Prometheus do not.
- A service on `database` can open a connection to PostgreSQL; what it can do
  there is decided by the login it holds, and each has its own password
  ("Database passwords: one per login" below).
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

## PDF renderer

`docker/pdf-renderer` replaced Gotenberg on 2026-10-18. It is a small Node 24 service (`src/server.mjs`) that drives
chrome-headless-shell (CHS) through puppeteer-core and answers `POST /render` and `GET /health`; the API, limits and
environment are in `docker/pdf-renderer/README.md`. There is no LibreOffice, no pdftk and no Go toolchain in the
image. The Gotenberg source rebuild, its flaky upstream tests and its ledger entry are retired.

**Posture.** The service sits alone with `functions` on the `internal: true` network `renderer` (Docker adds no route
out of it: no internet, no host, no Kong, no database, no Studio) and publishes no port. The root filesystem is
read-only with a 256 MB tmpfs at `/tmp`; all capabilities are dropped; `no-new-privileges`; 512 pids; 1.5 GiB memory
with no extra swap (the renderer's thresholds are sized for exactly that limit; a smaller one lets a large image
render hit the kernel's OOM kill); tini is PID 1; the process runs as uid 10001. The service refuses a request body over 48 MB
before reading it, queues at most 10 jobs and 100 MB of input, and gives each job 25 s. Every job gets a fresh
browser context that is closed afterwards; the browser restarts after 100 jobs or at 650 MB of Chrome memory, and is killed
at 1100 MB; the container's working set only holds back the next body at 1200 MiB. In the page, JavaScript is off (before navigation) and every request except the document itself and
`data:` images and fonts is refused (in the normal in-memory mode the document is also sent with a
Content-Security-Policy that blocks `data:` frames and objects; bodies of 8 MiB or more are rendered from a file in a
per-job directory, which cannot carry that header, so a `data:` frame renders there, still without any network access),
with `--host-resolver-rules="MAP * ~NOTFOUND"` as a second layer.

**Why `--no-sandbox` is acceptable here.** Chromium's own sandbox needs user namespaces or a setuid helper, which
the capability-free, read-only container deliberately lacks, and Gotenberg ran with the same flag. The compensating
controls are layered: the HTML is built on the server from escaped values (no user-supplied document or URL is
rendered), JavaScript is disabled, the page cannot load anything from the network, the container is on an internal
network with no route to the database or the internet, the filesystem is read-only, there are no capabilities, and
the input and the run time are bounded. A renderer exploit would therefore land in an unprivileged process that can
reach nothing except the function runtime that called it. Do not weaken any of these without a new review: in
particular, never feed the renderer a URL or an HTML page that a user wrote.

**Update cadence.** CHS is a Chrome for Testing build, pinned by `ARG CHS_VERSION` and `ARG CHS_SHA256` in the
Dockerfile (never `@stable`), puppeteer-core by an exact version in `package.json`, Node by digest, and the fonts and libraries
by Debian package name only (security revisions replace and remove exact versions; see "Fonts"). Chrome has security releases about every week. `release.yml` fails a release when the pinned
`CHS_VERSION` is more than 14 days behind the current Stable in Chrome for Testing's
`last-known-good-versions.json`, and `.github/workflows/cft-freshness.yml` runs the same check weekly and opens or
updates an issue. If the release dates cannot be read the result is "unknown" (exit 2): the run fails, and no
issue is opened or closed for it. Each network fetch is tried three times. To bump: change both args and puppeteer-core together (take the puppeteer-core release that pins
that Chrome major), run the renderer's unit tests and `test/integration.sh`, check the golden-PDF job, then rebuild
with `bash scripts/build-images.sh --no-cache` and scan. The golden job renders a fictional corpus, rasterises it in
a poppler container built from a fixed Debian snapshot and compares decoded pixels with the committed goldens at fuzz 0, so a font, Chrome or puppeteer change
that moves a pixel is seen and judged (Gujarati shaping by eye, the rest as a failure).

**Why Trivy cannot see the CfT binary.** CHS arrives as a zip from `storage.googleapis.com/chrome-for-testing-public`,
not as a Debian package, so the image has no package-manager record of it and Trivy's OS and language scanners find
nothing to match; a scan of the image covers only Node, the Debian libraries and fonts, and the npm tree (puppeteer-core
and its dependencies, also audited by `npm audit --prefix docker/pdf-renderer --omit=dev` in
`check:container-dependencies`). The Chrome release notes and the freshness check above are therefore the control
for Chrome itself, together with the pinned SHA-256 (a changed archive fails the build). The absence of Chrome
findings in a scan is not a clean bill: Debian's `chromium` package, which Gotenberg shipped, showed 116 findings in
the 2026-10-17 scan, and the CfT binary shows none only because Trivy does not look at it.

**Fonts.** The image installs the font packages of the Gotenberg 8.37.0 image, by package name, without
versions
(`fonts-liberation`, `fonts-liberation2`, `fonts-dejavu`, `fonts-noto-core` for Gujarati, `fonts-noto-cjk`,
`fonts-noto-color-emoji`, `fonts-crosextra-carlito`, `fonts-crosextra-caladea` and `fonts-opensymbol`) and Gotenberg's
`100-gotenberg.conf`, so documents paginate and look as before. The build fails unless the sorted `fc-list` file list
hashes to the value in `ARG FONT_FILELIST_SHA256`, which proves the font set did not change; a font package that
Debian drops or updates therefore stops the build instead of changing the output silently. Exact version pins are
deliberately not used: the `+debNuM` security revisions vanish from the archive within weeks and would break every
build. Drift is caught by the file-list hash at build time and by the golden-PDF job on every change, which is
consistent with the no-snapshot-mirror rule for production images (owner decision D5: a fresh build and scan before
each release instead).

## Sensor bridge (2026-10-13)

The optional `sensor-bridge` service (profile `sensors`, [SENSORS.md](SENSORS.md))
is the one container that talks to devices on the facility LAN. What limits it:

- **Network:** `default` only, so it reaches Kong and cannot open a connection
  to PostgreSQL, postgres-meta or Studio (`tests/compose-networks.test.mjs`).
  It publishes no port. Its only call into the project is
  `http://kong:8000/functions/v1/ingest-sensor-readings`, fixed in Compose
  rather than taken from a variable. Outbound it needs the hubs' LAN addresses.
- **Credential:** an ingest key of its own that opens only that function; the
  database keeps its SHA-256 and checks it inside `record_sensor_batch`
  (service role only). Revoking it stops the bridge without touching any other
  key. The bridge never holds the service key or a user session.
- **Process:** non-root (uid 10001 in the image), `cap_drop: [ALL]`,
  `no-new-privileges`, limited to 0.25 CPU and 128 MB, logs bounded like every
  service. The log formatter replaces the Tapo password, the ingest key and any
  URL query with `***`; `scripts/sensor-bridge-check.sh` fails if the
  configuration check prints a fictional password or key.
- **Image:** `python:3.14-slim-bookworm` pinned by digest in
  `docker/sensor-bridge/Dockerfile`; python-kasa and its dependencies pinned in
  `requirements.txt` and updated by Dependabot (`pip`). The image is built on
  the operator's host, like the other recipes.
- **Read-only root filesystem** (`read_only: true`, `/tmp` a tmpfs), as in the
  standalone project: the queue, change detector and health file are in the
  `/data` volume. Tried with the built image (`docker run --read-only`):
  `--check-config` and a `--once` against an unreachable hub write
  `/data/bridge.sqlite3` and nothing else.
- **Not done:** the Tapo password and the
  ingest key are container environment variables, readable with
  `docker inspect` by anyone who can use Docker on the host, like every other
  secret of the installation.

`ingest-sensor-readings` is in the router's public set: the router does not check a user token for it, and the function checks only the shape of the bridge's ingest key (64 hex). The key itself is checked inside `record_sensor_batch` against a SHA-256 in `warehouse_security.sensor_ingest_keys`, which PostgREST cannot reach. Its worker gets only `SUPABASE_URL` and `SUPABASE_SERVICE_ROLE_KEY`. It is subject to the gateway's functions limits (10 MB payload, 100 a minute per IP), and its log lines carry a reason code only, never the key or the body.

`cap_drop` and `no-new-privileges` are exercised by `npm run test:sensors`,
which runs the image with the same flags; the Compose service itself is not
started in CI, so the first `up` of the profile on an installation is its first
run under Compose.

## Edge function modules (2026-10-12)

The functions load nothing from the network when a worker starts. Until
2026-10-12 they imported the Deno standard library from deno.land and
supabase-js and jose from esm.sh on first start, and again after every
recreation of the container; a URL pinned only the top-level version, esm.sh
resolved supabase-js's own dependencies by range when it served the module,
and nothing checked content.

- **Two vendored files.** `functions/vendor/jose.mjs` (jose 5.10.0) and
  `functions/vendor/supabase-js.mjs` (supabase-js 2.39.0 with its
  dependencies) are each one self-contained module. The functions import them
  by relative path. `functions/vendor/LICENSES.txt` holds the licence of every
  package they may contain.
- **How they are built.** `scripts/vendor-edge-modules.sh` installs the exact
  packages of `scripts/edge-vendor/package-lock.json` (integrity-hashed,
  without install scripts) into a temporary directory and bundles them with
  esbuild. Two runs give byte-identical files. `functions/vendor/SHA256SUMS`
  records them, and `tests/edge-imports.test.mjs` fails when a file differs
  from its checksum, when a vendored file imports anything, when a function
  imports anything that is not a file of this repository, or when a version in
  the manifest is not exact.
- **To change a version:** edit `scripts/edge-vendor/package.json`, run
  `npm install --package-lock-only --ignore-scripts` in that directory, run
  the script, then start the stack and call `get-public-config`,
  `operator-otp`, `get-config` and one PDF function before committing. The
  root `package.json` pins the same jose for the unit tests.
- **The standard library is gone.** It was used for `serve` only; the
  functions call the runtime's own `Deno.serve`.
- **No import map.** `functions/import_map.json` is removed and the main
  service no longer passes one to the workers.
- **Checked on the dev instance (2026-10-12),** after recreating the functions
  container: `hello`, `get-public-config`, a sign-in through `operator-otp`
  (request, then verify, which returned a session), `get-config` with that
  session, and `generate-customer-stock-pdf`, which stored a PDF and returned
  its signed link. The container log names no download.

Still open:

- **Printing.** The printing functions, which the router refuses with 503,
  import `npm:ipp@2.0.1` on demand. Vendor it the same way before printing is
  enabled.
- jose 5 to 6 and supabase-js 2.39 to a current 2.x release are version
  moves; the pinned supabase-js resolves its Supabase dependencies at 2.117.3.

## Image pins (2026-10-11)

Every service image is either built from a Dockerfile whose `FROM` lines carry
a digest, or referenced with a digest in Compose (PostgREST since 2026-10-17):

| Image | State |
|---|---|
| `kong:3.9.3-ubuntu` | Pinned to `sha256:92035d16d7ff86b7bc12fb1d0090d29357d924238b1880f78735f3f2fea6b631`, the multi-platform index (linux/amd64 and linux/arm64) the registry serves for that tag on 2026-10-11, read with `docker buildx imagetools inspect`. The tag was rebuilt after the first pin (`sha256:12972ce1...`, the index of 2026-09-16). Dependabot's `docker-compose` updates propose a new digest when the tag is rebuilt. |
| `postgrest/postgrest:v16.4` | Pinned to `sha256:d155c6718ed9a9f990d159a2ab7c0a3f16944dbb6d0a0344557421042acfe0df` on 2026-10-17: the manifest list the registry serves for that tag (linux/amd64 `sha256:bee9e1ef...`, linux/arm64 `sha256:c3638ac2...`), read with `docker buildx imagetools inspect`, and the repository digest of the v16.4 image the dev hosts had pulled. `tests/gateway-config.test.mjs` no longer allows a tag-only image. The image has no package inventory; its time-boxed exception is bound to this digest (see "Exception ledger and the two-pass scan"). |

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

## Exception ledger and the two-pass scan (2026-10-17)

Operational review findings TW-BE-009 (HIGH/CRITICAL rows in the installed
images), TW-BE-010 (no PostgREST inventory) and TW-BE-005 part 1 (PostgREST
tag only). Owner decisions: D3, the repository owner `abhiguru` is the named
owner of every exception, each for at most 90 days; D5, no snapshot mirrors,
a `--no-cache` rebuild and rescan before each release instead
([RELEASE_CHECKLIST.md](RELEASE_CHECKLIST.md#image-scan-before-a-release)).

**The gate.** `npm run scan:images` (`scripts/scan-images.sh`) now builds every
Compose image with `--no-cache`, then scans each image twice with Trivy
(`--scanners vuln --severity HIGH,CRITICAL --list-all-pkgs`):

1. with `--ignore-unfixed`: the rows that have a listed fix;
2. without it: every HIGH/CRITICAL row, the ones with no fix included.

`scripts/validate-image-report.mjs` checks both reports as before (image
identity, a versioned package inventory in every result) and then requires every
HIGH/CRITICAL row to match a valid entry of
[`docker/image-exceptions.json`](../docker/image-exceptions.json) for the
image's recipe: `docker/<name>/Dockerfile` for a built image, the pinned
reference for a pulled one. The classes:

| Class | Covers | Bound by |
|---|---|---|
| `no-fix` | rows with no fixed version, by Trivy status (`affected`, `fix_deferred`, `will_not_fix`, ...) and severity; never a row with a listed fix | recipe, statuses, severities, optional `os-pkgs`/`lang-pkgs` |
| `advisory` | the named advisories in the named packages, fixed upstream or not: a fix the publisher has not shipped yet | recipe, advisory IDs, package names, severities |
| `no-package-inventory` | a report with no package results at all | recipe and the exact image digest, in the reference and in the scanned image's repository digests; compensating controls listed |

`no-fix` and `advisory` entries may also name `targets`, prefixes of the
result's target (a binary's path), and a `no-fix` entry may name `packages`;
then a row elsewhere is not covered (`db-os-no-fix` covers `linux-libc-dev`
only). The
scan prints a warning for an entry that covered no row, so a stale one is
noticed, and it counts a report as passed only on the validator's
"Image scan evidence accepted" line.

**Where to run it.** Because every image is rebuilt with `--no-cache`, each
gets a new image ID. Run the scan with a throwaway operator state of its own
project name, never with an installation's state: on an installation it would
move every `<project>-*` tag under the running containers to that day's
packages, images no recorded build made, which the next start would pick up.
`scripts/scan-images.sh` refuses while the state's project has any container,
running or stopped. Remove the throwaway project's `<project>-*` images
afterwards.

Every entry has an owner, a reason, the date the owner reviewed it and an
expiry at most 90 days after that review. An entry that has expired, has no
owner, was reviewed in the future or has an unknown field rejects the whole
ledger, so the scan fails until the entry is renewed or removed. The validator
with only a report and an image keeps the old strict behaviour.
`tests/image-scan.test.mjs` covers the passes and each rule.

**Scan of 2026-10-18.** Trivy 0.74.0 (the release binary, checksum checked),
one vulnerability database for every report (updated 2026-10-17 18:34 UTC),
the flags of `scripts/scan-images.sh`, linux/amd64 (the pdf-renderer row was scanned later, on 2026-10-18 with Trivy 0.76.0, the version installed on the build host; the ledger entry says so). Every built image was built
with `--no-cache` on 2026-10-17 or 2026-10-18; "before" is the recipe of `main`
198bbfa, built the same evening as "after". Counts are HIGH/CRITICAL rows.

| Image (recipe) | Rows with a fix, before | Rows with a fix, after | Rows with no fix, after | Covered by |
|---|---:|---:|---:|---|
| db (`postgres`) | 20 H | 0 | 3 C, 128 H | `db-os-no-fix` |
| functions (`edge-runtime`) | 3 C, 4 H | 0 | 1 C, 59 H | `functions-os-no-fix` |
| pdf-renderer (`pdf-renderer`), new on 2026-10-18 (replaces gotenberg) | n/a | 0 | 1 C, 54 H | `pdf-renderer-os-no-fix` |
| studio | 2 C, 4 H | 2 C, 3 H | 4 C, 246 H | `studio-app-awaiting-publisher`, `studio-os-no-fix` |
| sensor-bridge | 4 H | 0 | 2 C, 61 H | `sensor-bridge-os-no-fix` |
| meta (`postgres-meta`), unchanged | 0 | 0 | 1 C, 58 H | `meta-os-no-fix` |
| realtime, unchanged | 0 | 0 | 74 H | `realtime-os-no-fix` |
| supavisor, unchanged | 0 | 0 | 10 C, 379 H | `supavisor-os-no-fix` |
| rest (`postgrest/postgrest:v16.4@sha256:d155c671...`) | no package results | no package results | no package results | `rest-no-package-inventory` |
| kong, storage, imgproxy, cups, auth, prometheus, alertmanager, node-exporter, postgres-exporter, cadvisor, unchanged | 0 | 0 | 0 | none needed |

With the ledger, both passes of all nineteen images are accepted by the
validator. The review VM's numbers (TW-BE-009) were taken with an older
database; the rows with a fix match them.

What changed, per image:

- **db** (`docker/postgres/Dockerfile`): the recipe upgrades the Ubuntu packages
  with a fixed advisory (OpenSSL/`libssl3t64`, the GnuPG packages, PackageKit,
  `sudo`, `linux-libc-dev`) and fails the build if glibc, `locales` or
  `/usr/lib/locale/locale-archive` change: the Nix-built PostgreSQL reads that
  archive (`LOCALE_ARCHIVE`), so a locale update could change collation order
  under existing indexes. A full `apt-get upgrade` would touch about a hundred
  packages, glibc and `locales` among them, and is deliberately not used. The
  remaining rows are Linux kernel advisories reported against the
  `linux-libc-dev` header package, with no fixed version. If the guard trips, the build
  stops with a message saying so. The day Ubuntu lists a fix for a glibc or
  `locales` row, record it as an `advisory` exception, never as an upgrade in
  this recipe: a collation change needs a planned reindex of every
  installation.
- **functions** (`docker/edge-runtime/Dockerfile`): a full `apt-get upgrade`
  replaces the PCRE2-only upgrade (the PCRE2 version check stays); `perl-base`
  moves to `5.36.0-7+deb12u4`. edge-runtime v1.77.4 is still the newest tag.
- **gotenberg**: removed on 2026-10-18 with its source rebuild, its `gotenberg-os-no-fix` ledger entry (1 C, 126 H
  with no fix) and the timing-sensitive upstream tests it had to skip. `pdf-renderer` replaces it ("PDF renderer").
- **studio** (`docker/studio/Dockerfile`): moved to `2026.10.12-sha-3699278`,
  the newest tag, which fixes `@modelcontextprotocol/sdk` (1.32.0). It still
  ships simple-git 3.36.0, `@simple-git/argv-parser` 1.1.1 and next 16.3.6, so
  those advisories are the `advisory` exception `studio-app-awaiting-publisher`
  until a later tag; replacing packages inside the prebuilt application is not
  safe. Studio stays on the admin network only.
- **sensor-bridge** (`docker/sensor-bridge/Dockerfile`): not in the review's
  table (it was not installed there); this scan found msgpack 1.1.2, urllib3
  2.7.0 and setuptools 70.3.0 vendored by the base image's pip 26.2.1, each
  behind a fixed HIGH advisory. pip is a build tool there: the recipe now
  uninstalls it after `pip install` and checks that it is gone. The
  configuration check (exit 0 and 78) and the bridge's 92 unit tests passed on
  the rebuilt image, run as `scripts/sensor-bridge-check.sh` runs them.
- **rest**: pinned by digest; no package results, accepted by the digest-bound
  exception `rest-no-package-inventory` (see the PostgREST section).
- All other images: recipes unchanged; their rows with no fix are `no-fix`
  entries per recipe, with the counts of this scan in each reason.

## Gateway limits and metrics (2026-10-11)

- The GraphQL route and both Realtime routes had the public-key check but no
  rate limit. GraphQL and the Realtime HTTP route now have 300 requests a
  minute and 6000 an hour per client address, which was the REST route's limit
  at the time (the REST route itself was raised later the same day, see "REST
  request limit" below). The Realtime socket route has its own limit, 1800
  connection attempts a minute and no hourly window (next section). The
  Realtime HTTP route also has a 2 MB body limit.
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

### Realtime socket limit

The first version of the socket limit was the REST numbers, 300 a minute and
6000 an hour per client address. That could lock a whole facility out of
Realtime after an outage, so it was replaced. The reasoning:

- **One address per facility.** Kong limits by `CF-Connecting-IP`. Every
  phone on the facility network leaves through the same router, so the whole
  facility is one client address and shares one counter. (Phones on mobile
  data have their own, or a carrier-shared, address.)
- **Failed attempts count.** The limit applies to the upgrade request before
  it is passed on. When Realtime is down or restarting and the gateway is up,
  each retry is counted and then answered 502.
- **How the app retries.** `src/services/order-live-updates.ts` in the app
  opens one socket per live order screen (order list, supervisor queue, an
  open order), only while the app is in the foreground and online; a phone
  holds one, at most two at a time. The Realtime client retries a lost socket
  after 1, 2, 5 and 10 seconds and then every 10 seconds: 8 attempts in the
  first minute, 6 a minute after that, for as long as the outage lasts.
- **The arithmetic for 100 phones.** 100 phones x 2 sockets = 200 sockets:
  1600 attempts in the first minute, 1200 a minute afterwards, 72,000 an hour.
  Under the old limit a facility of 50 phones with one socket each (300 a
  minute) used the 6000-an-hour budget in 20 minutes; from then on every
  connection attempt of the facility was refused until the hour ended, also
  after Realtime was back.
- **The limit now.** 1800 attempts a minute per address, above the 1600 of a
  full facility's worst minute, and no hourly window. A per-minute window
  cannot lock anyone out: a refused attempt is retried 10 seconds later, and
  the counter starts again when the next minute begins. The window is a fixed
  minute: 1800 per fixed minute is about 30 a second on average, with no
  per-second brake, so what the limit stops is one address opening more than
  1800 sockets in one minute, not a burst inside the minute.
- **What this does not cover.** A facility with more than about 100 phones in
  the foreground at once would see some attempts refused in the first minute
  of an outage and reconnect a little later; raise `minute` in
  `docker/kong.yml` and the numbers in `tests/gateway-config.test.mjs`
  together. The REST and GraphQL limits were not changed here; they have the
  same one-address-per-facility property (see the storage note above). The
  REST limit was changed afterwards by an owner decision (next section). As
  with the other gateway changes, Kong has not loaded this file on a running
  stack.

### REST request limit

Owner decision of 2026-10-11: the REST route (`/rest/v1/`, every RPC and table
read of the app) allows **1800 requests a minute per client address and has no
hourly window**, like the socket route. It was 300 a minute and 6000 an hour.

- **Whose budget it is.** As above: Kong limits by `CF-Connecting-IP`, and
  every phone on the facility network has the same public address. The number
  is the budget of the whole facility, not of one phone.
- **The old limit, for 100 phones.** 300 a minute is 3 requests a minute for
  each phone, 5 a second for the facility. 6000 an hour is 60 requests an hour
  for each phone. At the full per-minute rate the hour was used up in 20
  minutes (6000 / 300); from then on every request of every phone at the
  facility was answered 429 until the hour ended, whatever the phone was
  doing, renewing its session included (`refresh_jwt_token` uses this route).
- **The limit now.** 1800 per fixed minute: 18 requests a minute for each of
  100 phones working in the same minute, about 30 a second on average for the
  facility, with no per-second brake. Kong counts in fixed windows that start
  with each clock minute, not over the last 60 seconds. With no window longer
  than a minute, a busy spell cannot lock anyone out afterwards: a refused
  request can be sent again when the next minute starts, at most 60 seconds
  later.
- **What a burst can do.** The count is per minute, not per second. One
  address may send all 1800 requests in the first second of a minute, and 1800
  more as soon as the next minute starts: 3600 requests within a few seconds
  around the turn of a minute are passed on. A ceiling per second would need a
  `second:` window in `docker/kong.yml` as well; none is set, and adding one
  is a decision for the owner (a list screen that loads many rows at once
  must still fit under it).
- **What counts.** Each request counts when it arrives, before it is passed
  on, so requests answered with an error count too, and so do the retries
  while PostgREST is restarting. That is why the hourly window is gone and not
  merely raised.
- **What the limit still stops, and what it stops less.** One address sending
  more than 1800 requests in one minute. It is the only brake at the gateway on a
  signed-in client that loops and on the three RPCs that need no sign-in
  (`refresh_jwt_token`, `logout_session`, `check_session`); for those one
  address may now send 108,000 requests in an hour where it could send 6000.
  The OTP limits are not affected: they are counted in the database and on the
  functions route (`docs/OPERATOR_INSTALL.md`, "Authentication and OTP
  limits").
- **Where the number comes from.** It is the owner's decision. It was not
  derived from request counts of a running facility; how many requests one app
  screen makes has not been measured. A facility with many more than 100
  phones working at once can raise `minute` in `docker/kong.yml` and the
  numbers in `tests/gateway-config.test.mjs` together.
- **The other routes** keep their limits; all of them count per client
  address, so each is likewise one budget for a whole facility:

  | Route | Limit per address | Used by the app | Note |
  |---|---|---|---|
  | `/rest/v1/` | 1800 a minute | every RPC and table read | this section |
  | `/realtime/v1/` (socket) | 1800 attempts a minute | live order screens | previous section |
  | `/functions/v1/` | 100 a minute, 6000 an hour | OTP sign-in, the four PDF functions, the two configuration reads, printer status | Owner decision of 2026-10-11: the hourly cap was 2000 and is now what the minute limit adds up to in an hour. See the next point. |
  | `/graphql/v1` | 300 a minute, 6000 an hour | not used | no change needed |
  | `/realtime/v1/api` | 300 a minute, 6000 an hour | not used | no change needed |
  | `/storage/v1/` | none | photos | see the storage note above |

- **The functions route: 100 a minute, 6000 an hour (owner decision of
  2026-10-11).** Until then `/functions/v1/` allowed 2000 requests an hour per
  client address. For a facility behind one address that was the lock-out the
  REST route had: once 2000 requests were used inside an hour, every phone
  there was refused OTP sign-in, the PDF documents, the configuration reads
  and printer status until the hour ended. The owner chose to keep 100 a
  minute and raise the hourly cap to 6000. 6000 is exactly 100 a minute for
  sixty minutes, so the hourly window can no longer refuse an address that
  stays within the minute limit; the minute limit is the one that acts. The
  window stays in the file as a stated ceiling. This route is also the
  gateway's brake per address on OTP requests: an address can now make the OTP
  function run up to 6000 times an hour where it could make it run 2000
  times. That does not allow more SMS: the database has its own OTP limits per
  source address (30 codes sent an hour, 20 failed verifications an hour;
  `docs/OPERATOR_INSTALL.md`, "Authentication and OTP limits").
- A running gateway keeps the limits it started with: `docker/kong.yml` is
  read when the gateway container starts. As with the other gateway changes,
  Kong has not loaded this file on a running stack; the check is
  `tests/gateway-config.test.mjs`, which pins the table above, the per-minute
  arithmetic and the wording about bursts.

## Logs (2026-10-17)

What a service log may hold, for the 3 x 10 MB of `json-file` log each service
keeps (`docker/docker-compose.override.yml`, `x-logging`; the oldest file is
dropped when the third fills, and a recreated container starts with an empty
log).

- **The rule.** No log line holds a token, a key, an OTP, a password or a query
  string. A signed storage link (`?token=`) and the anon key in a Realtime
  socket address (`?apikey=`) are credentials in a query string: a retained log
  that holds one can replay a still-valid document link or call the API as the
  public client.
- **Realtime still logs the anon key.** Realtime writes the socket address
  (`?apikey=`) to its own container log, independently of the gateway, so the
  redaction above does not cover it. The value is the public anon key, not a
  session token or a signed link; the Realtime log was not changed.
- **Client addresses are allowed in the gateway log, for its rotation life.**
  Owner decision of 2026-10-17. The address is useful to the operator (who is
  hammering the gateway) and leaves with the rotation. Nothing else identifies a
  person: no user agent, no referer, no phone number, no session.
- **Gateway access log** (`docker/docker-compose.yml`, Kong environment): the
  format `warehouse_redacted` replaces Kong's default, which wrote the whole
  request line, query string and all, plus the referer and user agent. A line is
  `client-address [time] "METHOD /path HTTP/x" status bytes seconds`, for
  example `203.0.113.7 [17/Oct/2026:17:43:35 +0000] "GET /storage/v1/object/sign/docs/a.pdf HTTP/1.1" 200 478 0.034`.
  `$uri` is the path without the query. Do not add `$request`, `$request_uri`,
  `$args`, `$query_string`, `$http_referer` or `$http_user_agent`;
  `tests/gateway-config.test.mjs` fails if one appears, and `npm run test:gateway`
  sends a fictional signed-link request and an `apikey` query and fails if the
  running gateway's log holds `token=` or `apikey=`. The format is defined with
  `KONG_NGINX_HTTP_LOG_FORMAT` and selected with `KONG_PROXY_ACCESS_LOG`, not in
  `docker/kong.yml`, which is `eval`ed by the entrypoint (a `$` there is replaced).
  In the Compose file `$` is written `$$`. Checked on the pinned Kong 3.9.3:
  `kong prepare` renders `log_format warehouse_redacted ...;` into
  `nginx-kong.conf` and `access_log /dev/stdout warehouse_redacted;` on the
  proxy listener, and the running gateway's log holds the path only.
- **Storage.** The storage service redacts `token` and the `X-Amz-*` signature
  parameters in the URL it logs (storage-api 1.80.2). It also writes two request
  headers into its log: `cf-connecting-ip` and `x-real-ip`. The gateway no
  longer passes `CF-Connecting-IP` to storage (`request-transformer` on the
  `storage-v1` service). It cannot do the same for `X-Real-IP` and
  `X-Forwarded-For`: Kong 3.9.3 sets them itself from the client address after
  the plugins have run, and a plugin that removes them removes only the copy the
  client sent (checked with an echo upstream behind the real `kong.yml`). The
  client address therefore still reaches storage and its log, which rotates like
  the gateway's. Storage does not use it: its image-render rate limit, the only
  reader of `x-real-ip`, is off (`RATE_LIMITER_ENABLED` is unset).
- **Residual: the gateway's error log.** nginx quotes the request line, query
  string included, in an error line (for example `upstream timed out ...,
  request: "GET /storage/v1/object/sign/...?token=..."`). This was reproduced by
  stopping an upstream. These lines appear only while a service fails, but a
  signed link that failed while it was valid stays in the log until it rotates
  out. The document functions make a signed link valid for one hour
  (`createSignedUrl(path, 3600)`), so the exposure ends then.
- **Not changed here.** The function logs, the sensor bridge (replaces any query
  with `***`, see "Sensor bridge") and the PDF functions follow the rules in
  their own sections; they were not re-checked for this change.
- **Upgrade.** The new format applies when the gateway container is recreated
  (`bash start.sh` after the update, or the setup rerun: Compose recreates a
  service whose configuration changed). The recreate also drops the old
  container's log. A signed link that the old format already wrote to a log stays
  valid until it expires, at most an hour after it was made; a copy of the old
  log made earlier still holds it.

## Database passwords: one per login

Changed on 2026-10-18 (review finding TW-BE-002, owner decision D4). Until
then `POSTGRES_PASSWORD` was the password of every database login, superusers
and service roles alike, so the credential of any one service opened all of
them on a reachable database. Since the network change above only services on
the `database` and `admin` networks can present a password to PostgreSQL at
all; now each of them presents its own.

### Who signs in as whom

| Login | Password (`config/compose.env`) | Used by | Set by |
|---|---|---|---|
| `postgres`, `supabase_admin` (superusers) | `POSTGRES_PASSWORD` | operator scripts (`compose exec db psql -U supabase_admin`), postgres-meta, Studio (it is given the value), Realtime (`DB_USER`), Supavisor's metadata database (`_supabase`) | the image's entrypoint at the first start; `npm run db:rotate-passwords -- --yes --superuser` |
| `authenticator` | `DB_PASSWORD_AUTHENTICATOR` | PostgREST | `docker/volumes/db/roles.sql` at the first start; `scripts/configure-db-roles.sql` on every setup run, after both restores and on rotation |
| `supabase_storage_admin` | `DB_PASSWORD_STORAGE` | Storage | the same |
| `supabase_auth_admin` | `DB_PASSWORD_AUTH` | the disabled Auth service | the same |
| `pgbouncer` | `DB_PASSWORD_POOLER` | Supavisor's pool user (pooler profile) | the same; `docker/volumes/pooler/pooler.exs` writes it into the stored tenant at every pooler start |
| `warehouse_monitoring` | `DB_PASSWORD_MONITORING` | the Postgres exporter (monitoring profile); it used `postgres` | migration 94 creates it `NOLOGIN`, a member of `pg_monitor` and of nothing else; `configure-db-roles.sql` gives it `LOGIN` and its password |
| `supabase_functions_admin` | none: `NOLOGIN`, no password | nothing; it owns the webhook functions, which run with its rights without a login | migration 94, `roles.sql`, `configure-db-roles.sql` |

`scripts/configure.mjs` generates the five service values (64 hexadecimal
characters each) and `REALTIME_DB_ENC_KEY` (16 characters) with every fresh
state, and its existing-state branch appends any that a state lacks; it never
replaces a value that exists. The doctor refuses a state where one is
missing, malformed, or repeats `POSTGRES_PASSWORD` or another one. The
Compose files name each value with `${NAME:?…}`, so a state without it fails
at `compose config` with "Run setup.sh to generate the per-role database
passwords", not at the first login. In the rendered configuration
`POSTGRES_PASSWORD` appears only in db, meta, realtime, supavisor and studio;
each service value only in its own service and in db, whose first-start init
script reads them (`tests/compose-networks.test.mjs`).

How the values reach the database: `scripts/db-roles.sh apply` turns each
into a SCRAM-SHA-256 verifier (`scripts/db-roles.mjs`, the format PostgreSQL
stores; `tests/db-roles.test.mjs` compares it with one PostgreSQL made) and
sends the verifiers, with the superuser password to sign in, on standard input
of `compose exec`. `ALTER ROLE … PASSWORD` stores a verifier as it is, so the
server never sees a password: none can appear in a log, in `pg_stat_activity`
or in `pg_stat_statements` (tracking is off for that transaction all the
same, because `warehouse_monitoring` may read it). No value is a command-line
argument or an environment variable of a docker command.

Stored copies:

- **Realtime** stores its tenant's database credentials (the superuser
  password) in `_realtime`, encrypted with `DB_ENC_KEY`, which was the fixed
  text `supabaserealtime` and is now `REALTIME_DB_ENC_KEY`. The pinned
  release (v2.144.0) deletes and rewrites the `realtime-dev` tenant at every
  start while `SEED_SELF_HOST` is on (`priv/repo/seeds.exs`), so a recreated
  container stores them under the current key and nothing has to clear the
  rows. Compose recreates Realtime whenever its key or password changes. A
  later Realtime that seeds only an absent tenant would need the rows removed
  in the same step (as `scripts/rotate-auth.sql` does for the signing key):
  check `seeds.exs` when the pin moves.
- **Supavisor** stores its tenant, with the pool user's password, in
  `_supabase`, encrypted with `VAULT_ENC_KEY`. `pooler.exs` used to write it
  only when the tenant was absent; it now also rewrites the pool user's
  credentials of an existing tenant at every start
  (`Supavisor.Tenants.update_manager_user_credentials`), which covers the
  upgrade, a rotation and a restore of an older `_supabase` database.

Still the same:

- Realtime connects as `supabase_admin`. Giving it a non-superuser role is a
  later, separate step: it creates its own schema and replication slot, and
  its needs must be measured on a running stack.
- `SECRET_KEY_BASE` and `VAULT_ENC_KEY` have no rotation procedure
  (`docs/OPERATOR_INSTALL.md`, "Secrets that rotate-keys does not change").
- The image's other login roles (`supabase_replication_admin`,
  `supabase_etl_admin`, `supabase_read_only_user`) have no password, so they
  cannot sign in over the network; inside the database container,
  connections from 127.0.0.1 and ::1 are trusted by the image's
  `pg_hba.conf` for every role, as before.
- JWT signing-key rotation is its own command (`rotate-keys.sh`).

### Checking the logins

`npm run test:db-roles` (`scripts/db-roles.sh check`) proves first that
`POSTGRES_PASSWORD` is the superuser password the database has
(`supabase_admin` signs in with it; otherwise no refusal proves anything and
the check fails), then for each service login that `POSTGRES_PASSWORD` is
refused and its own value accepted; that `warehouse_monitoring` has
`pg_monitor` and no superuser, role, database, replication or RLS-bypass
right; and that `supabase_functions_admin` cannot sign in and has no password
(a failed read of that state fails the check). It connects
from inside the database container to the name `db`, which is a network
address that `pg_hba.conf` authenticates with SCRAM; it also checks that the
server saw a non-loopback client. A check through `-h 127.0.0.1`, which the
design of this change proposed, would pass with any password, because the
image trusts loopback connections. CI's operator-install job runs it after the
fresh install, after both rotations and after the in-place and lost-host
restores. `tests/security_baseline.sql` asserts in the migration test database
that `warehouse_monitoring` is a member of `pg_monitor` only, holds no grant,
owns nothing and can read no application, Storage or private table.

### Upgrade of an existing install

`git pull`, then the same `setup.sh --operator …` command. Run setup before
any other operator command: until it has added the new values, every Compose
command (`stop.sh` and `start.sh` included) stops with the `${NAME:?…}`
message. Expected sequence:

1. `configure.mjs` appends the six values and says so.
2. The database container is recreated, because its environment changed (a
   restart of PostgreSQL).
3. The migrations run (94 creates `warehouse_monitoring`).
4. `configure-db-roles.sql` sets every service login's password. Running
   containers keep their open connections (those stay valid); a new
   connection from a container that still has the old value fails.
5. Setup starts Storage (recreated with its value), then everything else, and
   replaces the running optional services (pooler, monitoring) whose
   configuration changed.
6. The operator runs `npm run test:db-roles`, then
   `npm run db:rotate-passwords -- --yes --superuser`. The upgrade keeps
   `POSTGRES_PASSWORD`, the formerly shared value, which was in the
   environment of PostgREST, Storage, Auth and the exporter. Until it is
   rotated, a value leaked from any of those before the upgrade is still the
   superuser password. Then a new backup.

The window in which PostgREST or Storage cannot open a new connection is the
time between steps 4 and 5; see the drill below for the measured setup run.

### Restores

`db:backup` dumps databases, not roles, so no role password is in a backup's
dump; its `compose.env` copy carries the values of the moment.

- `db:restore` with the installation's own configuration compares
  `compose.env` with the backup's copy as before, except that the generated
  lines a backup made before this change lacks are left out of the
  comparison; that state's values are then the ones the restored database
  gets. A value the backup does carry must match, so a backup taken before a
  `db:rotate-passwords` needs `--restore-config`, as one taken before a
  signing-key rotation does.
- `db:restore -- --restore-config` and `db:restore-host` put the backup's
  `compose.env` in place and then add the values it lacks
  (`node scripts/db-roles.mjs add-missing`, the step of `configure.mjs`'s
  existing-state branch) before the database starts.
- Both then start from an empty data directory: `roles.sql` sets the four
  logins that exist before the migrations, and after the replay and the
  migrations `configure-db-roles.sql` sets all of them and gives
  `warehouse_monitoring` back its `pg_monitor` membership (the replay
  recreates a backup's roles as bare `NOLOGIN` names and does not rerun an
  applied migration). The pooler and Realtime rewrite their stored copies
  when they start.

### Rotation

`npm run db:rotate-passwords -- --yes` replaces every service login's
password; `--superuser` also replaces `POSTGRES_PASSWORD` and the Realtime
key. It stages the new values, sets them in the database in one transaction,
swaps `compose.env`, recreates the database and every running service that
signs in to it, runs `npm run test:db-roles` and the local doctor, and if a
service does not come back or a login misbehaves it puts the previous values
back in the database and in the file and recreates the services again. After
an interruption the next run does not rotate: it asks the database which of
the files left behind it matches (`scripts/db-roles.sh matches`, the network
sign-in of the login check), keeps that one as `compose.env` and removes the
others. The procedure is in
[OPERATOR_INSTALL.md](OPERATOR_INSTALL.md#rotating-the-database-passwords).

### Adding a login

A new service login (for example the runner of the list refresh) is one entry
in `DB_ROLE_LOGINS` in `scripts/db-roles.mjs` (its `compose.env` name, role
and psql variable), one `ALTER ROLE … WITH LOGIN PASSWORD :'…'` line in
`scripts/configure-db-roles.sql`, a migration that creates the role `NOLOGIN`
with its grants, and a `${NAME:?…}` reference in the service that uses it.
Fresh states then generate the value, existing ones gain it on the next setup,
restores add it, the rotation replaces it and `npm run test:db-roles` checks
it; `tests/db-roles.test.mjs` fails until the list and the SQL agree.

### Drill

Rehearsed on 2026-10-18 on a disposable, fictional install on the development
host (project `warehouse-b40b40b4-101`, its own state, loopback port, and an
override that gave its functions container no route to the SMS provider),
never on a facility. Each step ran the same checks afterwards:
`node scripts/doctor.mjs --local`, `npm run test:db-roles`, a probe of every
service login with `POSTGRES_PASSWORD` over `-h db`,
`tests/operator-realtime-core.mjs`, `npm run test:pooler`, and after a restore
`tests/operator-api-restore.mjs` with the restored backup.

| Step | Result |
|---|---|
| Install `main` (198bbfa) with `setup.sh --operator`; `tests/operator-api-core.mjs`, `test:pooler`, `test:monitoring` | Pass. The finding reproduced: `authenticator`, `supabase_storage_admin`, `supabase_auth_admin`, `pgbouncer` and `supabase_functions_admin` each accepted `POSTGRES_PASSWORD` over SCRAM. `db:backup` and `db:verify-restore` of this pre-change state |
| Upgrade: the change, then the same `setup.sh` command, with monitoring and the pooler running | Pass. `configure.mjs` added the six values; setup took 117 s; of 225 API requests sent every half second during it, 2 failed (one when the database restarted, one when PostgREST did). Every login refused `POSTGRES_PASSWORD` and accepted only its own; Realtime rewrote its tenant at start; the pooler rewrote the pool user of its existing tenant; the exporter worked as `warehouse_monitoring`; no login as `supabase_functions_admin` in the database log; a second setup run left `compose.env` byte for byte |
| `db:restore` of the pre-change backup, this state's configuration | Pass: the older backup was accepted, the restored data served, the pooler fixed the stale pool user of the restored `_supabase` |
| `db:rotate-passwords -- --yes`, then `--superuser`, then `test:rotation` (signing keys) | Pass. Each rotation took about a minute with about 11 s of failed API requests; every check passed after each of the three |
| `db:backup` after the rotations; `db:restore` of the pre-change backup | Refused without `--restore-config` (keys rotated since), as intended; with it the backup's configuration gained new values and the restore passed |
| `db:restore-host` from the pre-change backup on a new state directory, after removing the containers and the database volume | Pass: the backup had none of the six values, the new state all six |
| `db:restore-host` from the post-change backup | Pass: the backup carried all six values and the new state used them unchanged |

Not rehearsed: a facility with real data and a real tunnel, the pooler under
load during the upgrade, and an upgrade from a release older than 198bbfa.

## Open items with their steps

Each of these was left unchanged because the change cannot be checked without
building an image or starting the stack.

- **Go builders: done on 2026-10-11.** All nine `FROM golang:` lines (a tenth, the Gotenberg recipe's, was removed on 2026-10-18) (line 1 of
  `docker/{alertmanager,cadvisor,node-exporter,postgres-exporter,auth,imgproxy,prometheus,postgres}/Dockerfile`
  and line 12 of `docker/postgres/Dockerfile`) now use
  `golang:1.27.2-bookworm@sha256:5cf287a7...`, the multi-platform index the
  registry serves for that tag, read with `docker buildx imagetools inspect`.
  They used 1.27.0 and 1.27.1, which were behind three fixed HIGH
  standard-library advisories (CVE-2026-78667, CVE-2026-78669,
  CVE-2026-97031). Each recipe runs `go mod verify` and its selected tests
  during the build. CI builds nine of them; the Auth recipe belongs to a
  disabled service that CI does not build, and was built once by hand on
  2026-10-11.
  **Scan of 2026-10-11** (Trivy 0.74.0 with the flags of
  `scripts/scan-images.sh`, on the nine images of these recipes built from
  commit `bc2b110`; not the full `npm run scan:images` gate): no
  standard-library finding is left in the binaries the recipes build
  (alertmanager, amtool, auth, cadvisor, gosu, wal-g, imgproxy,
  node_exporter, postgres_exporter, prometheus, promtool).
- **`golang.org/x/net` 0.60.0: done on 2026-10-11.** The scan above found
  CVE-2026-78669 (HTTP/2, HIGH; fixed in `golang.org/x/net` 0.60.0) in every
  Go binary: the module was at v0.58.0 in alertmanager, amtool, auth,
  cadvisor, wal-g, imgproxy, prometheus and promtool, and at v0.57.0 in
  node_exporter and postgres_exporter. The module files of the eight recipes
  (`docker/{alertmanager,auth,cadvisor/cmd,imgproxy,node-exporter,postgres-exporter,prometheus}/go.{mod,sum}`
  and `docker/postgres/walg.go.{mod,sum}`) were regenerated with
  `go get golang.org/x/net@v0.60.0` in the upstream source at each recipe's
  tag; only `golang.org/x/*` versions and the `go` line (now 1.26.0, which
  the module requires) changed. The Prometheus recipe also runs
  `go work edit -go=1.26.0`, because the upstream workspace file names Go
  1.25.8 and the build refuses the mismatch. All eight images were built and
  scanned again the same day: each binary reports Go 1.27.2 and
  `golang.org/x/net` v0.60.0, and no fixed HIGH or CRITICAL finding is left
  in any of the eight images.
- **A cached build hides or shows operating-system findings.** In the same scan
  the imgproxy and (since removed) Gotenberg images first showed fixed HIGH
  findings in Ubuntu's and Debian's OpenSSL packages (CVE-2026-84782) and 116 in
  Debian's `chromium` packages. Both recipes already ran `apt-get upgrade`; the
  layer had been reused from an earlier build. Rebuilt with `--no-cache`, the
  images had no operating-system finding left (imgproxy kept the one
  `golang.org/x/net` finding). Build with `--no-cache` (or `--pull` and
  a pruned cache) before reading scan numbers or deploying.
- **Studio application advisories.** The recipe applies Debian updates, which
  addresses the operating-system findings at build time. On 2026-10-12 the
  tag moved from `2026.09.21-sha-512201d` to `2026.10.05-sha-94b8b06`, and on
  2026-10-17 to `2026.10.12-sha-3699278`, which fixes
  `@modelcontextprotocol/sdk` (1.32.0). Still in the publisher's application:
  simple-git 3.36.0 (one Critical, two High; fixed in 4.0.1),
  `@simple-git/argv-parser` 1.1.1 (Critical; 2.0.1) and next 16.3.6 (High;
  16.3.8). They are the exception `studio-app-awaiting-publisher` in
  `docker/image-exceptions.json` until a later Studio tag; then change the tag
  and digest in `docker/studio/Dockerfile` and the notices, remove the
  exception and run `npm run test:studio`. The exposure is bounded by the
  network change: only postgres-meta and the database can reach Studio. The
  scan numbers in the table near the top of this page are from 2026-09-22 and
  an older tag.
- **Edge runtime operating-system packages: done on 2026-10-17.**
  `docker/edge-runtime/Dockerfile` now runs a full `apt-get upgrade` (keeping
  the PCRE2 version check), which clears the seven fixed `perl-base` rows. The
  image was built and its `hello` function answered 200 on an isolated
  network; the operator API and document tests run in CI's operator-install
  job. (Storage got `apk upgrade --no-cache` with the move to v1.80.2 on
  2026-10-12: the Trivy scan of that build has no HIGH or CRITICAL finding,
  where the v1.79.14 build had 13 in Alpine packages.)
- **Storage `npm install`.** `npm ci` would fail on lock drift, but it deletes
  `node_modules` first, and the recipe keeps the publisher's prebuilt native
  modules and runs no install scripts, so they would not be rebuilt. Moving
  to `npm ci` needs a build that proves Storage still starts.
- **Chromium switches of the PDF service: done on 2026-10-18.** The renderer runs with JavaScript off and every
  network request refused, which was this item's plan for Gotenberg; the output was compared pixel for pixel with
  Gotenberg's before the switch ("PDF renderer"). The renderer cannot reach the database, postgres-meta or Studio.
- **Gateway configuration through shell `eval`.** Replacing the entrypoint's
  `eval` with Kong's own environment references needs Kong to load the result.
  The new test catches a character the `eval` would alter.
- **`net.http_get` and `net.http_post` executable by `anon` and
  `authenticated`: done on 2026-10-17 (migration 93).** The grants came from
  `docker/volumes/db/webhooks.sql` (an init script), from the event trigger
  it installs (which re-granted on `CREATE EXTENSION`) and from the publisher
  image's own migrations, which run after the init scripts at the first start
  (`20220713082019`, `20250220051611`). On an installed database the two
  functions were `SECURITY INVOKER` and executable by `PUBLIC`, `anon` and
  `authenticated` had `USAGE` on `net`, and pg_net itself grants `USAGE` on
  `net` and `ALL` on its request tables (`net.http_request_queue`,
  `net._http_response`) to `PUBLIC`: a role with `USAGE` could enqueue a
  request with the function or with a plain `INSERT`. Migration 93 revokes
  `USAGE` on `net` from `PUBLIC`, `anon` and `authenticated` (without it no
  object in `net` can be named) and `EXECUTE` on the two functions from the
  same three, then grants `USAGE` and `EXECUTE` explicitly to
  `supabase_functions_admin`, `postgres` and `service_role`, which had them
  only through `PUBLIC`. It does nothing where `net` does not exist, and
  replaces the event trigger function `extensions.grant_pg_net_access()` (owner
  and grants kept) with a body that grants nothing to `anon` or `authenticated`
  and takes `PUBLIC`'s `USAGE` back, so `DROP EXTENSION pg_net` followed by
  `CREATE EXTENSION pg_net` leaves the same state. `webhooks.sql` carries the
  same least-privilege lines, although the image's migrations run after it.
  Database webhooks (`supabase_functions.http_request`, a `SECURITY DEFINER`
  function of `supabase_functions_admin`) still send. `tests/migrations.sh`
  applies `webhooks.sql` and the image's two pg_net migrations to its database
  in the order a container runs them, and `tests/pg_net_grants.sql` checks the
  grants, the calls and a webhook, including after `DROP EXTENSION` and
  `CREATE EXTENSION`. The `net` schema is not exposed through PostgREST.
  Migration 93 also revokes `EXECUTE` on the trigger function
  `supabase_functions.http_request()` from `PUBLIC`, `anon` and `authenticated`
  (`webhooks.sql` likewise): it is `SECURITY DEFINER`, may call `net.http_post`,
  and takes the destination from the arguments of whoever creates the trigger,
  and `PUBLIC` may create temporary tables, so those roles could author a
  request without touching `net`. A webhook created by `postgres` (Studio) still
  fires on an insert by `anon`; `tests/pg_net_grants.sql` checks both, and that
  `anon` and `authenticated` cannot attach their own trigger.
  Remaining, by design: `net.http_delete`, `net.http_collect_response` and the
  request tables keep pg_net's `PUBLIC` privileges; they are unreachable without
  `USAGE` on `net`, so that one revoke is what protects them (defence in depth
  would be a further revoke on each, which pg_net undoes on every
  `CREATE EXTENSION`).
- **`app.settings.jwt_secret` readable by every database role: done on
  2026-10-17 (migration 92).** The migration resets the database setting (and a
  role-level copy, if any); `scripts/configure-auth.sql` repeats the reset on
  every setup run; `docker/volumes/db/jwt.sql`, `scripts/rotate-auth.sql` and
  the PostgREST variable `PGRST_APP_SETTINGS_JWT_SECRET` no longer set it. The
  database code reads `warehouse_security.auth_config`; no function in the
  database mentions the setting (checked by `tests/migrations.sh`). PostgREST
  (`PGRST_JWT_SECRET`), Realtime (`API_JWT_SECRET`) and Storage keep taking the
  secret from their own environment. Not done, by owner decision D13: a
  separate key for the one-time-code HMAC, which would void pending codes.
- **`no-new-privileges`, dropped capabilities, read-only root filesystems.**
  Not a blanket change: Realtime's start script runs `sudo -u nobody`
  (`/app/run.sh` in the pinned image), which `no-new-privileges` blocks, and
  Kong's entrypoint writes `/tmp/kong.yml`. Each service needs its own trial.
- **cAdvisor and CUPS run privileged.** Both are optional profiles. CUPS also
  accepts print jobs from any container on `default` without a login; no
  function reaches it while the router refuses the printing functions.
- **Scheduled image scan.** No workflow runs `npm run scan:images`. Since
  2026-10-17 the release checklist requires it before each release, and its
  exceptions expire (see "Exception ledger and the two-pass scan"); a
  scheduled workflow would catch an expiry or a new fixed advisory between
  releases.

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
| Sensor bridge service (profile `sensors`, `cap_drop: [ALL]`, `no-new-privileges`, read-only root, `default` network only) | the bridge starts under Compose, reaches the hubs and posts through Kong | none: `npm run test:sensors` runs the image with the same flags but without Compose or hubs; the first `up` on an installation is the first run |


## Build-date drift and the release rebuild (2026-10-18, decision D5)

Not every input of an image build is immutable. Each recipe that runs `apt-get upgrade`,
`apt-get install` or `apk upgrade` (for example pdf-renderer, realtime, storage and the sensor
bridge) reads the distribution's live repositories, so two builds of the same recipe on
different days can contain different operating-system packages. The base-image digests,
npm lockfiles and the hashed Python requirements are fixed; the operating-system layer is not.
This is accepted and documented, not hidden:

- **No snapshot mirrors.** The project does not pin the operating-system repositories to a
  dated snapshot. The cost of keeping a mirror for every recipe is higher than the risk it
  removes, and a frozen snapshot would also freeze security fixes.
- **Mandatory before every release:** one `--no-cache` rebuild and rescan, which is the
  `npm run scan:images` step of the
  [release checklist](RELEASE_CHECKLIST.md#image-scan-before-a-release) (throwaway state, exception
  ledger). It is not a second build. A release is not cut from images built from cache or
  from a scan older than the build.
- Record the build date with the scan. A finding is read against that date: a package that is
  fixed upstream after the build shows up at the next rebuild, not before.
- Python (sensor bridge): `requirements.txt` carries `--hash=sha256:` lines for every package
  and is installed with `--require-hashes` (Dockerfile and `.github/workflows/ci.yml`).
  `tests/supply-chain.test.mjs` fails if a package line has no hash or either install
  drops the flag.
- Storage: the Dockerfile keeps `npm install` but fails the build if `package-lock.json`
  changes during it (sha256 before and after) and then runs `npm ls --omit=dev --all`, which also fails the build (an invalid, missing or
  extraneous package). The `undici` override is scoped to `undici@^7` because
  `@kubernetes/client-node` needs 8.x; the earlier unscoped override made that listing invalid
  (resolved 2026-10-18).
