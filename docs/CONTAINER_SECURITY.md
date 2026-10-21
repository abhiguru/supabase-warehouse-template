# Container security

What is in force today for the images, networks, gateway, logs and database logins of an installation. It states the
current rules and recipes only; dated history is in [CHANGELOG.md](../CHANGELOG.md). The source and licence inventory is
in [THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md). No image binaries are published: each operator builds the recipes
on the installation's host.

## Images

| Service | Image or recipe | Patch boundary |
|---|---|---|
| `kong` (gateway) | `kong:3.9.4-ubuntu`, pulled by digest | none (no recipe of its own) |
| `rest` | `postgrest/postgrest:v16.4`, pulled by digest | none; static binary, see "Exceptions" |
| `storage` | `docker/storage`: `supabase/storage-api` v1.80.2 by digest | Two stages: the locked npm manifest with same-major leaf fixes (`@fastify/busboy` 3.2.3, `fast-copy` 4.1.2, an `undici` override scoped to `undici@^7`) is built on the publisher image, then the patched `/app` is copied onto a clean `node:24.21.0-alpine3.23` (no g++, make or python3; the image is about 550 MB, was 1 GB). Keep that Node in step with the publisher's: `docker/storage/README.md` |
| `functions` | `docker/edge-runtime`: supabase/edge-runtime v1.77.4 binary on `debian:bookworm-slim` (both by digest) | Full `apt-get upgrade` and a minimum PCRE2 version check |
| `db` | `docker/postgres`: the official `postgres:18.6-trixie` image (Debian 13), pinned by tag and index digest in the `FROM` line (`scripts/db-image.sh` prints it) | The recipe deletes the base image's `gosu` (a Go binary built with an old toolchain, which Trivy reported) in a layer of its own and copies in `docker/postgres/gosu`, a shell shim over util-linux `setpriv`; the build checks that it drops to `postgres` with the same ids, groups and `HOME`. No Go is built or shipped. Operating-system rows with no fix are covered by the ledger entry `db-os-no-fix`. The earlier Supabase database image is no longer used |
| `pdf-renderer` | `docker/pdf-renderer`: Node 24 (by digest), chrome-headless-shell from Chrome for Testing, puppeteer-core | Our own code; see "PDF renderer" |
| `supavisor` (profile `pooler`) | `docker/supavisor`: 2.9.13 by digest | Debian package upgrade |
| `cups` (profile `printing`) | `docker/cups`: `ubuntu:22.04` by digest | Ubuntu package upgrade |
| `sensor-bridge` (profile `sensors`) | `docker/sensor-bridge`: `python:3.15-slim-bookworm` by digest | Hashed `requirements.txt`; pip uninstalled after the install |

Every service image is either built from a Dockerfile whose `FROM` lines carry a digest, or referenced with a digest in
Compose. `tests/gateway-config.test.mjs` fails on a tag-only image and on a version in
[THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md) that differs from Compose or the Dockerfiles (the only place that must name versions). Dependabot proposes a new
digest when a tag is rebuilt. Operating-system package repositories stay live: rebuild without stale layers and rescan
before deploying; a previous passing scan is not a current guarantee.

A source or dependency audit of the npm graphs of Storage and the PDF renderer (production dependencies only) runs in CI:
`npm run check:container-dependencies` at HIGH/CRITICAL severity. Moving Storage to a new publisher tag is described in
`docker/storage/README.md`.

## Networks

The project has three networks; the table of members is in
[ARCHITECTURE.md](ARCHITECTURE.md#containers-and-networks) and `tests/compose-networks.test.mjs` holds it against the
rendered configuration.

- `database`: the database and the services that hold a database connection (rest, storage, supavisor). Kong, the
  function runtime, the PDF renderer, CUPS and the sensor bridge cannot open a connection to PostgreSQL at all.
- `renderer`: `internal: true` (Docker adds no route out: no internet, no host, no Kong, no database). Only the function
  runtime and the PDF renderer are on it.
- `default`: the gateway and everything it or a function calls.
- Operator probes follow the same rule: `health-check.sh` and `tests/gateway-dns-check.sh` call the gateway from the
  `storage` container.

The functions call PostgREST and Storage directly (`SUPABASE_REST_URL=http://rest:3000`, `SUPABASE_STORAGE_URL=http://storage:5000`) for
reports, PDFs and config, so those calls are not under Kong's 1800 a minute bucket or its key check; PostgREST verifies the JWT and
`check_session` itself, and Storage still never sees `CF-Connecting-IP`. `operator-otp`, `central-exchange`, `ingest-sensor-readings` and
the profile read of `_shared/auth-helpers.ts` still go through Kong.

What this does not do: services on `default` still reach each other without Kong's limits (`functions:9000`,
`storage:5000`, `rest:3000`), so PostgREST, Storage and the functions check tokens themselves. A service on `database`
can open a connection to PostgreSQL; what it can do there is decided by the login it holds, and each has its own
password ("Database passwords"). `database` and `default` are ordinary bridges, not `internal`. `default` needs outbound HTTPS: the OTP function calls MSG91
and central sign-in can fetch the association's keys. Nothing on `database` needs a route out since migration 103; making
it `internal` has not been tried.

Each installation creates three Docker networks. A host that runs many Compose projects can exhaust Docker's default
address pools (about 30 networks); `docker network prune` removes unused ones.

## Gateway limits and routes

Only Kong publishes a host port, on loopback (`127.0.0.1:${KONG_HTTP_PORT}`, default 18000). The Cloudflare Tunnel
connector is the only ingress: Kong reads the client address from `CF-Connecting-IP` (`KONG_REAL_IP_HEADER`) and trusts
it only from the loopback hop and Docker's private ranges, with recursion off. Do not put another reverse proxy in front
of it.

| Route | Upstream | Limit per client address | Other |
|---|---|---|---|
| `/rest/v1/` | `rest:3000` | 1800 a minute, no hourly window | key-auth, 10 MB body limit, `public.check_session` before every request |
| `/functions/v1/` | `functions:9000` | 100 a minute, 6000 an hour | 10 MB body limit; the functions check tokens themselves |
| `/storage/v1/` | `storage:5000` | none | 50 MB body limit; `CF-Connecting-IP` is not passed on |

CORS allows the one configured origin. The gateway has no metrics plugin, status listener or GraphQL route. The ingest
function `ingest-sensor-readings` is public at the router: it checks only the shape of the bridge's ingest key (64 hex);
the key itself is checked inside `record_sensor_batch` against a SHA-256 in `warehouse_security.sensor_ingest_keys`.

`docker/kong.yml` is filled in by a shell `eval` in the gateway entrypoint, so a double quote, backtick or backslash
anywhere in the file, comments included, is silently altered. `tests/gateway-config.test.mjs` runs the same evaluation
and compares the result. A running gateway keeps the limits it started with: `docker/kong.yml` is read when the
container starts.

### REST request limit

Owner decision of 2026-10-11: the REST route (every RPC and table read of the app) allows **1800 requests a minute per
client address and has no hourly window**.

- **Whose budget it is.** Kong limits by `CF-Connecting-IP`, and every phone on the facility network has the same public
  address, so the number is the budget of the whole facility, not of one phone.
- **The limit.** 1800 per fixed minute: 18 requests a minute for each of 100 phones working in the same minute, about 30
  a second on average for the facility, with no per-second brake. Kong counts in fixed windows that start with each
  clock minute, not over the last 60 seconds. No window is longer than a minute, so a
  busy spell cannot lock anyone out afterwards: a refused request can be sent again when the next minute starts, at most 60
  seconds later (an hourly window was dropped on purpose).
- **What a burst can do.** The count is per minute, not per second. One address may send all 1800 requests in the first
  second of a minute, and 1800 more as soon as the next minute starts: 3600 requests within a few seconds around the
  turn of a minute are passed on. A ceiling per second would need a `second:` window in `docker/kong.yml`; none is set,
  and adding one is a decision for the owner.
- **What counts.** Each request counts when it arrives, so requests answered with an error count too, and so do retries
  while PostgREST is restarting.
- **What it still stops.** One address sending more than 1800 requests in one minute. It is the only brake at the
  gateway on a signed-in client that loops and on the three RPCs that need no sign-in (`refresh_jwt_token`,
  `logout_session`, `check_session`). The OTP limits are not affected: they are counted in the database and on the
  functions route ([OPERATOR_INSTALL.md](OPERATOR_INSTALL.md#authentication-and-otp-limits)).
- **Timed re-reads.** The app has no socket; a screen that is shown, with the app in the foreground and online, asks
  again on a timer, one REST call each time: an open order list, order queue or order detail every 15 s (4 requests a
  minute); the sensor list and a sensor detail every 60 s (1 a minute). Only the screen on top re-reads. With every phone
  on an order screen, 100 phones send 400 requests a minute (22% of 1800, leaving 14 a minute for each phone's own
  taps) and 300 phones send 1200 (67%). The limit is kept at 1800 for a facility of about 100 phones; a facility of 300
  raises `minute` in `docker/kong.yml` and the numbers in `tests/gateway-config.test.mjs` together.
- **The functions route: 100 a minute, 6000 an hour (owner decision of 2026-10-11).** 6000 is exactly 100 a minute for
  sixty minutes, so the hourly window cannot refuse an address that stays within the minute limit; the minute limit is
  the one that acts. This route is also the gateway's brake per address on OTP requests; the database has its own OTP
  limits per source (30 codes sent an hour, 20 failed verifications an hour), so the route allows no more SMS.
- **Storage has no limit.** A list screen loads one image per row and every phone at a facility shares one public
  address, so a limit low enough to matter could refuse ordinary use; it needs request counts from a running facility
  before a number is chosen.

`tests/gateway-config.test.mjs` pins the table above, the per-minute arithmetic and this wording.

## Logs

What a service log may hold, for the 3 x 10 MB of `json-file` log each service keeps (`docker/docker-compose.yml`,
`x-logging`; the oldest file is dropped when the third fills, and a recreated container starts with an empty log).

- **The rule.** No log line holds a token, a key, an OTP, a password or a query string. A signed storage link
  (`?token=`) is a credential in a query string: a retained log that holds one can replay a still-valid document link.
- **Client addresses are allowed in the gateway log, for its rotation life** (owner decision of 2026-10-17). Nothing else
  identifies a person: no user agent, no referer, no phone number, no session.
- **Gateway access log** (`docker/docker-compose.yml`, Kong environment): the format `warehouse_redacted` replaces Kong's
  default, which wrote the whole request line, query string and all. A line is
  `client-address [time] "METHOD /path HTTP/x" status bytes seconds`, for example
  `203.0.113.7 [17/Oct/2026:17:43:35 +0000] "GET /storage/v1/object/sign/docs/a.pdf HTTP/1.1" 200 478 0.034`. `$uri` is
  the path without the query. Do not add `$request`, `$request_uri`, `$args`, `$query_string`, `$http_referer` or
  `$http_user_agent`; `tests/gateway-config.test.mjs` fails if one appears, and `npm run test:gateway` sends a fictional
  signed-link request and an `apikey` query and fails if the running gateway's log holds `token=` or `apikey=`. The
  format is defined with `KONG_NGINX_HTTP_LOG_FORMAT` and selected with `KONG_PROXY_ACCESS_LOG`, not in `docker/kong.yml`,
  which is `eval`ed by the entrypoint; in the Compose file `$` is written `$$`.
- **Storage.** The storage service redacts `token` and the `X-Amz-*` signature parameters in the URL it logs. It also
  writes two request headers into its log: `cf-connecting-ip` and `x-real-ip`. The gateway no longer passes
  `CF-Connecting-IP` to storage (`request-transformer` on the `storage-v1` service). It cannot do the same for `X-Real-IP`
  and `X-Forwarded-For`: Kong sets them itself from the client address after the plugins have run (checked on 3.9.3). The client
  address therefore still reaches storage and its log, which rotates like the gateway's. Storage does not use it: its
  image-render rate limit is off (`RATE_LIMITER_ENABLED` is unset).
- **Residual: the gateway's error log.** nginx quotes the request line, query string included, in an error line (for
  example `upstream timed out ..., request: "GET /storage/v1/object/sign/...?token=..."`). These lines appear only while
  a service fails, but a signed link that failed while it was valid stays in the log until it rotates out. The document
  functions make a signed link valid for one hour, so the exposure ends then.
- The function logs, the sensor bridge (replaces any query with `***`) and the PDF functions follow the rules in their
  own sections.

## Image pins

Kong and PostgREST are referenced in `docker/docker-compose.yml` with the index digest of their tag (the multi-platform
manifest list), read with `docker buildx imagetools inspect`. To move one, read the new digest the same way and change
tag and digest together. The PostgREST image has no package inventory, so its exception is bound to this digest
("Exceptions"). Kong has no recipe of its own, so its Ubuntu packages are as old as the pinned build; a
`docker/kong/Dockerfile` with an `apt-get upgrade` step, as Supavisor has, would need a build and a gateway run.

## Exception ledger and the image scan

Owner decisions: D3, the repository owner `abhiguru` is the named owner of every exception, each for at most 90 days;
D5, no snapshot mirrors, a `--no-cache` rebuild and rescan before each release instead
([RELEASE_CHECKLIST.md](RELEASE_CHECKLIST.md#image-scan-before-a-release)).

**The gate.** `npm run scan:images` (`scripts/scan-images.sh`) builds every Compose image with `--no-cache`, then scans
each image once with Trivy (`--scanners vuln --severity HIGH,CRITICAL --list-all-pkgs`, no `--ignore-unfixed`): the report
holds every HIGH/CRITICAL row, the ones with no fix included. `scripts/validate-image-report.mjs` checks the report (image
identity, a versioned package inventory in every result) and then requires every HIGH/CRITICAL row to match a valid entry
of [`docker/image-exceptions.json`](../docker/image-exceptions.json) for the image's recipe (`docker/<name>/Dockerfile`
for a built image, the pinned reference for a pulled one). A report is counted as passed only on the validator's "Image
scan evidence accepted" line.

| Class | Covers | Bound by |
|---|---|---|
| `no-fix` | rows with no fixed version, by Trivy status (`affected`, `fix_deferred`, `will_not_fix`, ...) and severity; never a row with a listed fix | recipe, statuses, severities, optional `os-pkgs`/`lang-pkgs` |
| `advisory` | the named advisories in the named packages, fixed upstream or not: a fix the publisher has not shipped yet | recipe, advisory IDs, package names, severities |
| `no-package-inventory` | a report with no package results at all | recipe and the exact image digest, in the reference and in the scanned image's repository digests; compensating controls listed |

`no-fix` and `advisory` entries may also name `targets` (prefixes of the result's target, such as a binary's path), and a
`no-fix` entry may name `packages`; then a row in another package is not covered.
The scan prints a warning for an entry that covered no row, so a stale one is noticed.

**Renewal rule.** Every entry has an owner, a reason, the date the owner reviewed it and an expiry at most 90 days after
that review. An entry that has expired, has no owner, was reviewed in the future or has an unknown field rejects the whole
ledger, so the scan fails until the entry is renewed (new `reviewed` date, `expires` at most 90 days later, reason updated
with the scan's counts) or removed. `no-fix` rows are renewed the same way. `tests/image-scan.test.mjs` covers the scan
and each rule.

**Current entries** (all reviewed by the owner, expiring 2027-01-15 unless renewed): `db-os-no-fix`,
`functions-os-no-fix`, `pdf-renderer-os-no-fix`, `supavisor-os-no-fix`, `sensor-bridge-os-no-fix` and
`rest-no-package-inventory`. The images of Kong, Storage and CUPS need none.

**Where to run it.** Run the scan with a throwaway operator state of its own project name, never with an installation's
state: every image is rebuilt with `--no-cache` and gets a new image ID, so on an installation the scan would move every
`<project>-*` tag under the running containers to that day's packages, images no recorded build made, which the next
start would pick up. `scripts/scan-images.sh` refuses while the state's project has any container, running or stopped.
Remove the throwaway project's `<project>-*` images afterwards.

**Build-date drift (decision D5).** Recipes that run `apt-get` or `apk` read live repositories, so two builds on different
days can differ; base-image digests, npm lockfiles and hashed Python requirements are fixed. Build with `--no-cache` before
reading scan numbers, record the build date with the scan, and cut no release from cached images (see the
[release checklist](RELEASE_CHECKLIST.md#image-scan-before-a-release)).

- Python (sensor bridge): `requirements.txt` carries `--hash=sha256:` lines and is installed with `--require-hashes`
  (Dockerfile and `.github/workflows/ci.yml`); `tests/supply-chain.test.mjs` fails if a package has no hash or either
  install drops the flag.
- Storage: the Dockerfile keeps `npm install` but fails the build if `package-lock.json` changes during it and then
  runs `npm ls --omit=dev --all`, which fails on an invalid, missing or extraneous package.

**Database image rule.** The database image is the official PostgreSQL image, pinned by digest in `docker/postgres/Dockerfile`
and bumped by Dependabot within major 18 (a new major needs a planned dump and restore on every installation; the PostgreSQL 17 to 18 move is in
[Major PostgreSQL upgrade](OPERATOR_INSTALL.md#major-postgresql-upgrade), the 15 to 17 move in [Baseline reload](OPERATOR_INSTALL.md#baseline-reload)). The data directory is set explicitly (`PGDATA=/var/lib/postgresql/data`, the mount of the `db` service): the official 18 image defaults elsewhere. The cluster uses the `en_US.UTF-8` collation of the image's
glibc, so a base-image bump that changes glibc or its locale data can change index order. Check the base image's changes
before moving the digest, and plan a reindex if the collation changed.

### Exceptions in detail

- **`rest-no-package-inventory`.** Trivy returns no OS or language package results for the static PostgREST image, so
  the gate cannot assess it, and a report without package results is rejected rather than counted as clean. The
  exception is bound to the image digest and lists its compensating controls: no host port; outside requests only
  through Kong with key-auth, a 10 MB body limit and the REST rate limit; `public.check_session` before every request;
  business writes only through RPCs guarded by `authorize_rpc`. It does not establish that the image is free of the
  `aeson` advisory HSEC-2026-0007 (HIGH, memory exhaustion), which the publisher binaries are known to carry; it records an
  accepted, dated gap. Closing it needs an image-bound dependency inventory (for example a source build whose cabal freeze
  or Nix lock becomes the inventory) and a vulnerability assessment, then API regressions. Do not add fabricated packages
  or dummy scan results to pass the gate.
- **OS rows with no fix** (`db`, `functions`, `supavisor`, `sensor-bridge`, `pdf-renderer`): rows in operating-system
  packages that the distribution has not fixed. For the database (`db-os-no-fix`) they are Debian 13 packages of the
  official image (util-linux, gnupg, libxml2, perl, ncurses, systemd, acl) with no fixed version. The database has no host
  port and is on the `database` network only.
- **The Chrome for Testing binary** is invisible to Trivy; see "PDF renderer".

## PDF renderer

`docker/pdf-renderer` is a small Node 24 service (`src/server.mjs`) that drives chrome-headless-shell (CHS) through
puppeteer-core and answers `POST /render` and `GET /health`; the API, limits and environment are in
`docker/pdf-renderer/README.md`. There is no LibreOffice, no pdftk and no Go toolchain in the image.

**Posture.** The service sits alone with `functions` on the `internal: true` network `renderer` and publishes no port.
The root filesystem is read-only with a 256 MB tmpfs at `/tmp`; all capabilities are dropped; `no-new-privileges`; 512
pids; 1.5 GiB memory with no extra swap (the renderer's thresholds are sized for exactly that limit; a smaller one lets a
large image render hit the kernel's OOM kill); tini is PID 1; the process runs as uid 10001. The service refuses a request
body over 48 MB before reading it, queues at most 10 jobs and 100 MB of input, and gives each job 25 s. Every job gets a
fresh browser context that is closed afterwards; the browser restarts after 100 jobs or at 650 MB of Chrome memory, and is
killed at 1100 MB; the container's working set only holds back the next body at 1200 MiB. In the page, JavaScript is off
(before navigation) and every request except the document itself and `data:` images and fonts is refused (in the normal
in-memory mode the document is also sent with a Content-Security-Policy that blocks `data:` frames and objects; bodies of
8 MiB or more are rendered from a file in a per-job directory, which cannot carry that header, so a `data:` frame renders
there, still without any network access), with `--host-resolver-rules="MAP * ~NOTFOUND"` as a second layer.

**Why `--no-sandbox` is acceptable here.** Chromium's own sandbox needs user namespaces or a setuid helper, which the
capability-free, read-only container deliberately lacks. The compensating controls are layered: the HTML is built on the
server from escaped values (no user-supplied document or URL is rendered), JavaScript is disabled, the page cannot load
anything from the network, the container is on an internal network with no route to the database or the internet, the
filesystem is read-only, there are no capabilities, and the input and the run time are bounded. A renderer exploit would
land in an unprivileged process that can reach nothing except the function runtime that called it. Do not weaken any of
these without a new review: in particular, never feed the renderer a URL or an HTML page that a user wrote.

**Update cadence.** CHS is a Chrome for Testing build, pinned by `ARG CHS_VERSION` and `ARG CHS_SHA256` in the Dockerfile
(never `@stable`), puppeteer-core by an exact version in `package.json`, Node by digest, and the fonts and libraries by
Debian package name only (security revisions replace and remove exact versions; see "Fonts"). Chrome has security
releases about every week. `release.yml` fails a release when the pinned `CHS_VERSION` is more than 14 days behind the
current Stable in Chrome for Testing's `last-known-good-versions.json`, and `.github/workflows/cft-freshness.yml` runs the
same check weekly and opens or updates an issue. If the release dates cannot be read the result is "unknown" (exit 2): the
run fails, and no issue is opened or closed for it. Each network fetch is tried three times. To bump: change both args and
puppeteer-core together (take the puppeteer-core release that pins that Chrome major), run the renderer's unit tests and
`test/integration.sh`, check the golden pages in the `pdf-renderer` job, then rebuild with `bash scripts/build-images.sh --no-cache` and scan. The
golden job renders a fictional corpus, rasterises it in a poppler container built from a fixed Debian snapshot and compares
decoded pixels with the committed goldens at fuzz 0, so a font, Chrome or puppeteer change that moves a pixel is seen and
judged (Gujarati shaping by eye, the rest as a failure).

**Why Trivy cannot see the CfT binary.** CHS arrives as a zip from `storage.googleapis.com/chrome-for-testing-public`, not
as a Debian package, so a scan covers only Node, the Debian libraries and fonts, and the npm tree (also audited by `npm audit
--prefix docker/pdf-renderer --omit=dev` in `check:container-dependencies`). The Chrome release notes, the freshness check
above and the pinned SHA-256 are the control for Chrome itself. No Chrome findings in a scan is not a clean bill.

**Fonts.** The image installs these font packages by name, without versions: `fonts-liberation`, `fonts-liberation2`,
`fonts-dejavu`, `fonts-noto-core` (Gujarati), `fonts-noto-cjk`, `fonts-noto-color-emoji`, `fonts-crosextra-carlito`,
`fonts-crosextra-caladea` and `fonts-opensymbol`, with a fontconfig file, so documents paginate and look the same from
build to build. The build fails unless the sorted `fc-list` file list hashes to the value in `ARG FONT_FILELIST_SHA256`,
which proves the font set did not change; a font package that Debian drops or updates therefore stops the build instead of
changing the output silently. Exact version pins are deliberately not used: the `+debNuM` security revisions vanish from the
archive within weeks and would break every build. Drift is caught by the file-list hash at build time and by the
golden-PDF job on every change.

## Sensor bridge

The optional `sensor-bridge` service (profile `sensors`, [SENSORS.md](SENSORS.md)) is the one container that talks to
devices on the facility LAN. What limits it:

- **Network:** `default` only, so it reaches Kong and cannot open a connection to PostgreSQL. It publishes no port. Its
  only call into the project is `http://kong:8000/functions/v1/ingest-sensor-readings`, fixed in Compose rather than taken
  from a variable. Outbound it needs the hubs' LAN addresses.
- **Credential:** an ingest key of its own that opens only that function; the database keeps its SHA-256 and checks it
  inside `record_sensor_batch` (service role only). Revoking it stops the bridge without touching any other key. The bridge
  never holds the service key or a user session.
- **Process:** non-root (uid 10001), `cap_drop: [ALL]`, `no-new-privileges`, a read-only root filesystem (`/tmp` a tmpfs;
  the queue, change detector and health file are in the `/data` volume), limited to 0.25 CPU and 128 MB, logs bounded like
  every service. The log formatter replaces the Tapo password, the ingest key and any URL query with `***`;
  `tests/sensor-bridge-check.sh` fails if the configuration check prints a fictional password or key.
- **Image:** pinned by digest; python-kasa and its dependencies are pinned in `requirements.txt` and updated by
  Dependabot (`pip`). The image is built on the operator's host.
- **Not done:** the Tapo password and the ingest key are container environment variables, readable with `docker inspect`
  by anyone who can use Docker on the host, like every other secret of the installation.

`npm run test:sensors` runs the image with the same flags; the Compose service itself is not started in CI.

## Edge function modules and image

The functions load nothing from the network when a worker starts.

- **One vendored file.** `functions/vendor/jose.mjs` (jose 5.10.0) is one self-contained module; the functions import it by
  relative path. `functions/vendor/LICENSES.txt` holds the licence of every package it may contain.
  `functions/_shared/supabase-rest.ts` makes the few REST, RPC and Storage calls the functions need with plain `fetch`, and
  adds a 60 s timeout to each call (the worker's own wall-clock limit is 60 s, `functions/main/index.ts`). There is no
  import map and no standard-library import: the functions call the runtime's own `Deno.serve`.
- **How it is built.** `scripts/vendor-edge-modules.sh` installs the exact packages of
  `scripts/edge-vendor/package-lock.json` (integrity-hashed, without install scripts) into a temporary directory and
  bundles them with esbuild. Two runs give byte-identical files. `functions/vendor/SHA256SUMS` records them, and
  `tests/edge-imports.test.mjs` fails when a file differs from its checksum, when a vendored file imports anything, when a
  function imports anything that is not a file of this repository, or when a version in the manifest is not exact.
- **To change a version:** edit `scripts/edge-vendor/package.json`, run `npm install --package-lock-only --ignore-scripts` in
  that directory, run the script, then start the stack and call `get-public-config`, `operator-otp`, `get-config` and one
  PDF function before committing. The root `package.json` pins the same jose for the unit tests.
- **The image.** `docker/edge-runtime/Dockerfile` is multi-stage: it copies only `/usr/local/bin/edge-runtime` from the
  upstream image (which also holds a 277 MB symbols file and an unused 50 MB ONNX runtime that the binary does not link)
  onto `debian:bookworm-slim` (the same Debian release as upstream, pinned by digest), adds `ca-certificates` and `tzdata`,
  runs a full `apt-get upgrade` with the PCRE2 minimum-version check, and keeps the upstream entrypoint.
- **Still open:** the printing functions, which the router refuses with 503, import `npm:ipp@2.0.1` on demand; vendor it
  the same way before printing is enabled.

## Database roles

The first start of an empty data directory runs `docker/volumes/db/00-bootstrap.sql` as `supabase_admin`, the bootstrap
superuser of the official image (`POSTGRES_USER`). There is **no role named `postgres`**. The bootstrap makes these roles,
and `tests/baseline_roles.sql` asserts exactly this set after the baseline is applied (no other role outside `pg_*`):

| Role | Login | Superuser | Inherits | Notes |
|---|---|---|---|---|
| `supabase_admin` | yes | yes | yes | owns the database and every object outside the schemas `storage` and `pgbouncer`; used by operator scripts, the migrations and `SECURITY DEFINER` functions |
| `authenticator` | yes | no | **no** (NOINHERIT) | PostgREST's login; member of `anon`, `authenticated`, `service_role`, which it takes with `SET ROLE` |
| `supabase_storage_admin` | yes | no | **no** (NOINHERIT) | Storage's login; member of `authenticator`; owns the schema `storage`; no `CREATEROLE` |
| `pgbouncer` | yes | no | yes | Supavisor's pool user (profile `pooler`) |
| `anon`, `authenticated` | no | no | yes | API roles; statement timeouts 3 s and 8 s |
| `service_role` | no | no | yes | `BYPASSRLS`; the edge functions' role |

No `ALTER DEFAULT PRIVILEGES` is made by the bootstrap: the baseline's grants are written relative to the built-in
defaults, and a default privilege would widen them. `service_role` keeps `ALL` on the business tables as before; the image has no `pg-safeupdate`, so nothing stops an
unqualified `UPDATE` or `DELETE` by that role. Supavisor's lookup function
`pgbouncer.get_auth` never returns a superuser's verifier. A role of the earlier image (`postgres`, `dashboard_user`,
`supabase_auth_admin`, `supabase_functions_admin`, `supabase_realtime_admin`, `warehouse_monitoring` and the like) must not
exist, and no ACL may name one.

**Extension member ACLs.** The extensions are `pg_stat_statements`, `pg_trgm`, `pgcrypto` and `uuid-ossp`. The functions
and operators of `pg_trgm` live in `public`, where the chain had revoked them from `PUBLIC` and granted them to
`service_role`. A fresh extension install does not do that, so the baseline replays those `REVOKE` and `GRANT` statements
right after `CREATE EXTENSION` (section "Privileges of extension members" at the top of
`migrations/00000000000000_baseline.sql`). Without them `PUBLIC` could execute `pg_trgm` functions such as `similarity`.

**The old chain is refused.** `setup.sh` and `start.sh` stop before they rebuild or start anything when the database is below
PostgreSQL 18 (`scripts/db-version-preflight.sh`; a PostgreSQL 17 database is pointed to the [Major PostgreSQL upgrade](OPERATOR_INSTALL.md#major-postgresql-upgrade), an earlier one to the reload); a database whose ledger names a migration this release does not contain
stops `scripts/migrate.sh` with `This database recorded migrations that are not in this release (...)` (full text in
[OPERATOR_INSTALL.md](OPERATOR_INSTALL.md#baseline-reload)) and changes nothing. `db:restore`, `db:restore-host` and `db:verify-restore` call
`scripts/backup-image.sh` first and refuse a backup whose `database_image=` line is missing or names `supabase/postgres...`, or
whose `roles.txt` lists a role of the earlier image, before the backup's own signature check and before anything of the
installation is changed.

### Roles and migrations

A restore takes the roles from `docker/volumes/db/00-bootstrap.sql` and the objects from the backup, so a migration is never
the place for a role. A migration after the baseline must not `CREATE`, `ALTER` or `DROP` a role or grant membership in one
(`tests/migration-roles.test.mjs` fails on it). A role change goes into the bootstrap (and into
`scripts/configure-db-roles.sql` for installations that already exist). A database-level fix made in the bootstrap (a schema, a
grant, a setting of the database) also ships as a migration, so that an existing facility gets it and a restored one keeps it.

## Database passwords: one per login

Each database login has its own password in `config/compose.env`, so the credential of one service does not open the others.

| Login | Password (`config/compose.env`) | Used by | Set by |
|---|---|---|---|
| `supabase_admin` (the only superuser) | `POSTGRES_PASSWORD` | operator scripts (`compose exec db psql -U supabase_admin`), Supavisor's metadata database (`_supabase`) | the image's entrypoint at the first start; `npm run db:rotate-passwords -- --yes --superuser` |
| `authenticator` | `DB_PASSWORD_AUTHENTICATOR` | PostgREST | `docker/volumes/db/roles.sql` at the first start; `scripts/configure-db-roles.sql` on every setup run, after both restores and on rotation |
| `supabase_storage_admin` | `DB_PASSWORD_STORAGE` | Storage | the same |
| `pgbouncer` | `DB_PASSWORD_POOLER` | Supavisor's pool user (pooler profile) | the same; `docker/volumes/pooler/pooler.exs` writes it into the stored tenant at every pooler start |

`scripts/configure.mjs` generates the three service values (64 hexadecimal characters each) with every fresh state, and its
existing-state branch appends any that a state lacks; it never replaces a value that exists. The doctor refuses a state
where one is missing, malformed, or repeats `POSTGRES_PASSWORD` or another one. The Compose files name each value with
`${NAME:?…}`, so a state without it fails at `compose config` with "Run setup.sh to generate the per-role database
passwords". In the rendered configuration `POSTGRES_PASSWORD` appears only in db and supavisor; each service value only in
its own service and in db, whose first-start init script reads them (`tests/compose-networks.test.mjs`).

`scripts/db-roles.sh apply` turns each value into a SCRAM-SHA-256 verifier (`scripts/db-roles.mjs`, the format PostgreSQL
stores; `tests/db-roles.test.mjs` compares it with one PostgreSQL made) and sends the verifiers, with the superuser password
to sign in, on standard input of `compose exec`. `ALTER ROLE … PASSWORD` stores a verifier as it is, so no password can
appear in a log, in `pg_stat_activity` or in `pg_stat_statements`, and no value is a command-line argument or an
environment variable of a docker command. Supavisor stores its tenant, with the pool user's password, in `_supabase`,
encrypted with `VAULT_ENC_KEY`; `pooler.exs` rewrites the pool user's credentials of an existing tenant at every start,
which covers a rotation and a restore of an older `_supabase` database.

Still the same: `SECRET_KEY_BASE` and `VAULT_ENC_KEY` have no rotation procedure
([OPERATOR_INSTALL.md](OPERATOR_INSTALL.md#secrets-that-rotate-keys-does-not-change)). Inside the database
container, connections from 127.0.0.1 and ::1 are trusted by the image's `pg_hba.conf` for every role. JWT signing-key rotation is its own command (`rotate-keys.sh`).

**Checking the logins.** `npm run test:db-roles` (`scripts/db-roles.sh check`) proves first that `POSTGRES_PASSWORD` is the
superuser password the database has (otherwise no refusal proves anything and the check fails), then for each service login
that `POSTGRES_PASSWORD` is refused and its own value accepted. It connects from inside the database container to the name `db`, a network address that
`pg_hba.conf` authenticates with SCRAM, and checks that the server saw a non-loopback client. A check through
`-h 127.0.0.1` would pass with any password, because the image trusts loopback connections. CI's operator-install job runs
it after the fresh install, after both rotations and after the in-place and lost-host restores.
`tests/baseline_roles.sql` asserts the role set above, and `tests/security_baseline.sql` that `warehouse_monitoring` does not exist.

**Restores.** `db:backup` dumps databases, not roles, so no role password is in a backup's dump; its `compose.env` copy
carries the values of the moment. `db:restore` with the installation's own configuration compares `compose.env` with the
backup's copy, so a backup taken before a `db:rotate-passwords` needs `--restore-config`, as one taken before a signing-key
rotation does. `db:restore -- --restore-config` and `db:restore-host` put the backup's `compose.env` in place and then add
the values it lacks (`node scripts/db-roles.mjs add-missing`) before the database starts. Both then start from an empty data
directory: `roles.sql` sets the three logins that exist before the migrations, and after the replay and the migrations
`configure-db-roles.sql` sets all of them.

**Rotation.** `npm run db:rotate-passwords -- --yes` replaces every service login's password; `--superuser` also replaces
`POSTGRES_PASSWORD`. After an interruption the next run asks the database which of the files left behind matches
(`scripts/db-roles.sh matches`) and keeps that one. The procedure is in
[OPERATOR_INSTALL.md](OPERATOR_INSTALL.md#rotating-the-database-passwords).

**Adding a login.** A new service login is one entry in `DB_ROLE_LOGINS` in `scripts/db-roles.mjs` (its `compose.env` name,
role and psql variable), one `ALTER ROLE … WITH LOGIN PASSWORD :'…'` line in `scripts/configure-db-roles.sql`, a migration
that creates the role `NOLOGIN` with its grants, and a `${NAME:?…}` reference in the service that uses it. Fresh states
then generate the value, existing ones gain it on the next setup, restores add it, the rotation replaces it and
`npm run test:db-roles` checks it; `tests/db-roles.test.mjs` fails until the list and the SQL agree.

## Other hardening in force

- The database setting `app.settings.jwt_secret` is not set: the database code reads `warehouse_security.auth_config`, and
  PostgREST (`PGRST_JWT_SECRET`) and Storage take the secret from their own environment (migration 92). A separate key for
  the one-time-code HMAC was not made, by owner decision D13, because it would void pending codes.
- The database has no `http`, `pg_net`, `pg_graphql` or `supabase_vault` extension and no pgjwt; the database has no way to
  send a web request. A session's access token is signed by `warehouse_security.jwt_sign_hs256` (pgcrypto's `hmac`), which
  no API role can execute. `PGRST_DB_SCHEMAS` is `public` (an old `public,storage` is rewritten by `setup.sh` and the restore scripts), so the REST API cannot reach the `storage` schema, and `PGRST_OPENAPI_MODE=disabled`: `/rest/v1/` serves no OpenAPI document.
- `no-new-privileges`, dropped capabilities and a read-only root filesystem are set on the PDF renderer and the sensor
  bridge. Kong's entrypoint writes `/tmp/kong.yml` and the other services have not been trialled, so they are not hardened
  this way.
- **CUPS runs privileged** (optional profile). It also accepts print jobs from any container on `default` without a login;
  no function reaches it while the router refuses the printing functions.
- Every service except CUPS has a CPU and memory limit (`docker/docker-compose.yml`) and bounded logs.

## Open items

- **Scheduled image scan.** No workflow runs `npm run scan:images`. The release checklist requires it before each release
  and the exceptions expire, but a scheduled workflow would catch an expiry or a new fixed advisory between releases.
- **Gateway configuration through shell `eval`.** Replacing the entrypoint's `eval` with Kong's own environment references
  needs Kong to load the result; the test catches a character the `eval` would alter.
- **Storage `npm install`.** `npm ci` would fail on lock drift but deletes `node_modules` first, and the recipe keeps the
  publisher's prebuilt native modules and runs no install scripts, so they would not be rebuilt. Moving to `npm ci` needs a
  build that proves Storage still starts.
- **PostgREST scan coverage**, above.
- **jose 5 to 6.** A version move, not made.
- **No recovery from WAL.** WAL archiving is off (`archive_mode=off`) and the image has no WAL archiving tool, so there is no
  point-in-time recovery. The supported backup path is `db:backup` and `db:verify-restore`; PITR, external object storage
  and RTO/RPO need a separate recovery drill with approved storage and policies.
