# Container security

What is in force today for the images, networks, gateway, logs and database logins of an installation. It states the
current rules and recipes only; dated history is in [CHANGELOG.md](../CHANGELOG.md). The source and licence inventory is
in [THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md). No image binaries are published: each operator builds the recipes
on the installation's host.

## Images

| Service | Image or recipe | Patch boundary |
|---|---|---|
| `gateway` | `docker/nginx`: the official `nginx:1.30.6-alpine-slim` (the stable 1.30 branch), pinned by tag and index digest in the `FROM` line | `apk upgrade` in the recipe. Alpine-slim was chosen over the Debian-based variant for its package inventory: 21 packages and no HIGH or CRITICAL Trivy row on 1.30.6, against 60 on `1.30.6-trixie`. Runs as the `nginx` user (101) with a read-only root file system, no capability and 128 MB. Move to the next stable branch (1.32) once a year |
| `rest` | `postgrest/postgrest:v16.5`, pulled by digest | none; static binary, see "Exceptions" |
| `storage` | `docker/storage`: `supabase/storage-api` v1.80.2 by digest | Two stages: the locked npm manifest with same-major leaf fixes (`@fastify/busboy` 3.2.3, `fast-copy` 4.1.2, an `undici` override scoped to `undici@^7`) is built on the publisher image, then the patched `/app` is copied onto a clean `node:24.21.0-alpine3.23` (no g++, make or python3; the image is about 550 MB, was 1 GB). Keep that Node in step with the publisher's: `docker/storage/README.md` |
| `functions` | `docker/edge-runtime`: supabase/edge-runtime v1.77.8 binary on `debian:bookworm-slim` (both by digest) | Full `apt-get upgrade` and a minimum PCRE2 version check |
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

The npm graphs of Storage and the PDF renderer (production dependencies only) are audited at HIGH/CRITICAL severity in two
places, neither of which is a live audit in the required check: a pull request fails only when it **adds** an advisory the base
commit did not have, and a weekly run audits both trees and opens one issue ("Dependency advisory exceptions" below).
`npm run check:container-dependencies` still runs the live audit by hand. Moving Storage to a new publisher tag is described in
`docker/storage/README.md`.

## Networks

The project has three networks; the table of members is in
[ARCHITECTURE.md](ARCHITECTURE.md#containers-and-networks) and `tests/compose-networks.test.mjs` holds it against the
rendered configuration.

- `database`: the database and the services that hold a database connection (rest, storage, supavisor). The gateway, the
  function runtime, the PDF renderer, CUPS and the sensor bridge cannot open a connection to PostgreSQL at all.
- `renderer`: `internal: true` (Docker adds no route out: no internet, no host, no gateway, no database). Only the function
  runtime and the PDF renderer are on it.
- `default`: the gateway and everything it or a function calls.
- Operator probes follow the same rule: `health-check.sh` and `tests/gateway-dns-check.sh` call the gateway from the
  `storage` container.

All edge functions call PostgREST and Storage directly (`SUPABASE_REST_URL=http://rest:3000`, `SUPABASE_STORAGE_URL=http://storage:5000`), including
`operator-otp`, `central-exchange`, `ingest-sensor-readings` and the profile read of `_shared/auth-helpers.ts`, so none of those calls is under
the gateway's REST bucket or its key check; PostgREST verifies the JWT and `check_session` itself, and Storage still never sees
`CF-Connecting-IP`. Only the client to gateway path remains.

What this does not do: services on `default` still reach each other without the gateway's limits (`functions:9000`,
`storage:5000`, `rest:3000`), so PostgREST, Storage and the functions check tokens themselves. A service on `database`
can open a connection to PostgreSQL; what it can do there is decided by the login it holds, and each has its own
password ("Database passwords"). `database` and `default` are ordinary bridges, not `internal`. `default` needs outbound HTTPS: the OTP function calls MSG91
and central sign-in can fetch the association's keys. Nothing on `database` needs a route out since migration 103; making
it `internal` has not been tried.

Each installation creates three Docker networks. A host that runs many Compose projects can exhaust Docker's default
address pools (about 30 networks); `docker network prune` removes unused ones.

## Gateway limits and routes

The gateway is plain nginx (`docker/nginx`; Kong until 2026-10). Only it publishes a host port, on loopback
(`127.0.0.1:${GATEWAY_HTTP_PORT}`, default 18000; `KONG_HTTP_PORT`, the name it had, is still read), apart from the optional
`gateway-lan` service, which publishes the host's own private address while the LAN fallback is on ([LAN fallback](#lan-fallback-plain-http-on-the-warehouse-network)). The Cloudflare Tunnel
connector is the only ingress: nginx reads the client address from `CF-Connecting-IP` (`real_ip_header`) and trusts it
only from the loopback hop and Docker's private ranges, with recursion off. That trust is written in the public server only
(`templates/gateway.conf.template`), never in the routes file `api-locations.conf` that a second server shares, so a server
that is reached directly cannot be told a client address by a request header. Do not put another reverse proxy in front of it.

| Route | Upstream | Limit per client address | Other |
|---|---|---|---|
| `/rest/v1/` | `rest:3000` | a bucket of 1800 that empties at 30 a second, no hourly window | `apikey` check, 10 MB body limit, `public.check_session` before every request |
| `/functions/v1/` | `functions:9000` | a bucket of 100 that empties at 100 a minute | 10 MB body limit; the functions check tokens themselves |
| `/storage/v1/` | `storage:5000` | none | 50 MB body limit; `CF-Connecting-IP`, `X-Real-IP` and `X-Forwarded-For` are not passed on |

How the pieces map: the routes, the prefix removal (`/rest/v1/rpc/f?x=1` goes to `rest:3000/rpc/f?x=1`, the path as the client
wrote it), the key check, CORS, the body limits, the buffers and the error bodies are `docker/nginx/api-locations.conf`; the
limit zones, the upstreams and the preflight test are `api-http.conf`; the worker, the logs, the resolver and gzip are
`nginx.conf`; the origin and the two keys come in through `templates/http.conf.template`. Every rule carries the reason for it
in a comment. Order of checks on a route, as with Kong: the CORS preflight is answered first, then the key check (REST only),
then the body size, then the rate limit, so a request refused by an earlier step does not use up the rate limit. One exception,
nginx's own: a request whose `Content-Length` is over the route's limit gets 413 when nginx picks the route, before the
preflight, the 404 and the key check (Kong looked at the key first); a chunked body over the limit is refused while it is read.
A path with a dot segment (`/./` or `/../`, also written `%2e` or with the slash as `%2F`) is answered 404 on every route, so a
`..` that an upstream might resolve never reaches it; no name the app creates has one. A body that arrives slowly is cut off
after 20 seconds between two reads on REST and functions (`client_body_timeout`), because it is streamed to the upstream.
`/health` answers the container's own check only; a request for it through the tunnel is a 404 like any unknown path.

CORS is answered only by the gateway, for the one configured origin (`CORS_ALLOWED_ORIGIN`, always sent as the allowed origin,
with credentials and `Vary: Origin`); the edge functions add no CORS headers of their own (the former `cors.ts` is
`security-headers.ts`), and an upstream's own `Access-Control-*` headers are dropped so the browser never reads two values.
The preflight is answered 204 with the methods, headers and one day of cache of the route. The gateway has no metrics plugin, status listener or GraphQL route. The ingest
function `ingest-sensor-readings` is public at the router: it checks only the shape of the bridge's ingest key (64 hex);
the key itself is checked inside `record_sensor_batch` against a SHA-256 in `warehouse_security.sensor_ingest_keys`.

The mobile app reads the 401 answer of the key check: `{"message":"Unauthorized"}` for a key the gateway does not know (what
every installed app holds after `rotate-keys.sh`) and `{"message":"No API key found in request"}` for none; both end the app's
session and reload the configuration (`GATEWAY_KEY_REJECTIONS` in the app's `src/config/supabaseConfig.ts`). Do not change those words.
**That is the rule for the public path only.** A 401 with these messages that arrives over the LAN path (the answer carries
`X-Warehouse-Path: lan`) must never end the session: it means the `gateway-lan` container holds other keys than the installation (a
container that was not recreated after `rotate-keys.sh`), and ending the session there would sign the phone out at the moment it cannot
sign in again, because sign-in needs the internet. The app marks the LAN path unusable and goes on (see "LAN fallback" below).

**The configuration is not filled in by a shell.** The image's entrypoint (`/docker-entrypoint.d/20-envsubst-on-templates.sh`)
puts the three values in the two templates with `envsubst`, restricted by `NGINX_ENVSUBST_FILTER` to `CORS_ALLOWED_ORIGIN`,
`ANON_KEY` and `SERVICE_ROLE_KEY` (and `LAN_CIDR`, `LAN_BIND_IP` and `LAN_HTTP_PORT`, which only the `gateway-lan` container has); every other `$` in the templates is nginx's own. Before it,
`docker-entrypoint.d/18-require-env.sh` stops the container with a message if one of the three is empty or holds a character
outside letters, digits and `. _ ~ : / -` (a quote, a semicolon, a dollar sign or a space would change the configuration), or
if the origin is not `http(s)://host`; in the `gateway-lan` container (the one that reads the LAN template directory, `GATEWAY_ROLE=lan`) it also refuses a `LAN_CIDR` that is not one private IPv4 range, a `LAN_BIND_IP` that is not one private IPv4 address and a `LAN_HTTP_PORT` outside 1024 to 65535. This closes the earlier open item about Kong's `eval` of `kong.yml`. A running gateway
keeps the configuration it started with, **and so does `gateway-lan`, which is the same image**: a change to `docker/nginx` needs the image rebuilt and both containers recreated
(`bash setup.sh --operator ...`, or `bash scripts/build-images.sh` and `bash scripts/compose.sh up -d --force-recreate --wait gateway`, plus
`bash scripts/compose.sh --profile lan up -d --force-recreate --no-deps gateway-lan` while the LAN fallback is on; a key rotation needs the same, `rotate-keys.sh` does it).

**Hardening.** The container runs as the `nginx` user (101) with `cap_drop: [ALL]`, `no-new-privileges`, a read-only root file
system and two small tmpfs (`/tmp` for the pid file, and the directory the templates are rendered into), one worker, 128 MB and
half a CPU. Request bodies are streamed to the upstream and a Storage download is passed on as it arrives, because nothing may be
written to a file there (the tmpfs is memory, and the anon key is public). The `Server` header says `nginx` and no version.

**Memory.** REST and function answers are buffered 0.5 MB at a time (32k for the headers, 16 buffers of 32k for the body); a
larger answer is passed on as the client takes it, and the invoice-form preview (2.2 MB of JSON) is sent compressed. Kong's
buffers (up to 10 MB a request) were sized for 512 MB. What a reader that stops reading costs is more than the buffers: the two
sockets of the request hold up to 3 MiB of kernel buffers that count against the container's memory, and no nginx setting here
changes that. Measured with readers that stop reading a 10 MB answer: about 4 MiB a request with these buffers (Kong's: 7 MiB), so
20 such readers fit in 128 MB and 30 do not (`tests/gateway-nginx.test.mjs` holds 20, with swap off, and fails on Kong's buffers).
Real answers are far smaller and compress by 90% or more; a facility with much bigger answers or many slow clients raises the
limit in `docker/docker-compose.yml`.

**Compared with Kong.** Same: the routes and upstreams, the prefix removal, the key check on REST only and the key not passed
on, CORS lists, body limits, per-address limits on the address from `CF-Connecting-IP`, gzip, the redacted access log, loopback
publication. Different: the rate limits are a leaky bucket (below); `Retry-After` on a 429 is always `1` (Kong sent the seconds
until its window reset, up to 60); the preflight is 204 where Kong answered 200; 413 comes before the key check; the key is read
from the `apikey` header only (Kong also read a query parameter, which the app never used) and its letter case is ignored
(`templates/http.conf.template`); there are no `X-RateLimit-*`, `X-Kong-*` or `Via` headers; the upstreams get no
`X-Forwarded-Proto`, `-Host`, `-Port`, `-Path` or `-Prefix` (nothing reads them); Storage no longer receives `X-Real-IP`
and `X-Forwarded-For`; every route sets `CF-Connecting-IP` from the address the gateway settled on; response buffers are 0.5 MB a
request instead of 10 MB (above, Memory); a path with a dot segment is a 404; a slow request body is cut off after 20 seconds
between reads; upstream connections are reused for at most 15 seconds idle (Kong 60), so a request is less likely to meet a
connection that the upstream has just closed.

### REST request limit

Owner decision of 2026-10-11: the REST route (every RPC and table read of the app) allows **1800 requests a minute per
client address and has no hourly window**. Since the gateway became nginx (2026-10) the limit is a leaky bucket:
`limit_req_zone ... rate=30r/s` with `limit_req ... burst=1800 nodelay` (`docker/nginx/api-http.conf`, `api-locations.conf`).

- **Whose budget it is.** The gateway limits by `CF-Connecting-IP`, and every phone on the facility network has the same
  public address, so the number is the budget of the whole facility, not of one phone.
- **The limit.** A leaky bucket that holds a burst of 1800 requests and empties at 30 a second: 1800 a minute on average, which
  is 18 requests a minute for each of 100 phones working in the same minute. Up to 1800 requests may arrive at once; the next
  one is refused (HTTP 429) until the bucket has drained, which it does at 30 a second, so a refused request can be sent again
  within a second or two. There is no hourly window (it was dropped on purpose): a busy spell cannot lock anyone out afterwards,
  because the bucket is as full as the traffic made it and no fuller. Kong counted per clock minute; nginx has no clock minute.
- **What a burst can do.** An address that has been quiet for a minute has an empty bucket, and may send 1800 requests in the
  first second and then 30 a second: about 3600 in the first minute from a cold start, then 1800 a minute for as long as it keeps
  sending. A ceiling below that rate would be a lower `rate` or a smaller `burst`; changing either is a decision for the owner.
- **What counts.** Each request counts when it arrives, so requests answered with an error count too, and so do retries
  while PostgREST is restarting. A request answered 401 (no or wrong key), 413 (body too large) or as a CORS preflight is
  refused before the rate limit and does not count.
- **What it still stops.** One address sending more than 30 requests a second for long. It is the only brake at the
  gateway on a signed-in client that loops and on the three RPCs that need no sign-in (`refresh_jwt_token`,
  `logout_session`, `check_session`). The OTP limits are not affected: they are counted in the database and on the
  functions route ([OPERATOR_INSTALL.md](OPERATOR_INSTALL.md#authentication-and-otp-limits)).
- **Timed re-reads.** The app has no socket; a screen that is shown, with the app in the foreground and online, asks
  again on a timer, one REST call each time: an open order list, order queue or order detail every 15 s (4 requests a
  minute); the sensor list and a sensor detail every 60 s (1 a minute). Only the screen on top re-reads. With every phone
  on an order screen, 100 phones send 400 requests a minute (22% of 1800, leaving 14 a minute for each phone's own
  taps) and 300 phones send 1200 (67%). The limit is kept at 1800 for a facility of about 100 phones; a facility of 300
  raises `rate` and `burst` in `docker/nginx` (together) and the numbers in `tests/gateway-config.test.mjs`.
- **The functions route: a bucket of 100 that empties at 100 a minute (owner decision of 2026-10-11).** `rate=100r/m burst=100 nodelay`.
  The earlier hourly cap of 6000 is gone: 6000 is exactly 100 a minute for sixty minutes, so a bucket that empties at 100 a minute
  passes no more than 6000 an hour and a second, hourly rule would refuse nothing the first does not. This route is also the
  gateway's brake per address on OTP requests; the database has its own OTP
  limits per source. They are `auth_config` keys with defaults (`otp_source_hourly_sends`, 30 codes sent an hour;
  `otp_source_hourly_failures`, 20 failed verifications an hour; `otp_trusted_source_hourly_sends`, 120 sends an hour for an address
  the operator lists in `otp_trusted_source_list`, [OPERATOR_INSTALL.md](OPERATOR_INSTALL.md#the-facilitys-own-wi-fi-address)), so the
  route allows no more SMS.
- **Storage has no limit.** A list screen loads one image per row and every phone at a facility shares one public
  address, so a limit low enough to matter could refuse ordinary use; it needs request counts from a running facility
  before a number is chosen.
- **An answer of 429** has the body `{"message":"API rate limit exceeded"}` and `Retry-After: 1`; the access log line has status 429
  (the checker's `api_429_rate_high` counts them). The error log is not written for a refusal (`limit_req_log_level info`).

- **Maintenance mode** (`WAREHOUSE_MAINTENANCE`, `off` or `upgrading`; docs/OPERATOR_INSTALL.md, "Rerun and upgrade", "While it upgrades"). It is not
  a setting of the installation: `scripts/maintenance.sh` and `upgrade.sh` write the marker `config/maintenance`, which `scripts/compose.sh`
  turns into the word for every Compose command. While it is `upgrading` each of the three API routes answers 503 with the body
  `{"code":"upgrading",...}` and `Retry-After: 120` after the CORS preflight and before the path and key checks, so a request does not use
  a rate-limit bucket and nothing reaches an upstream. It is an `if` that only does `return` (the one safe use of `if` in a location), the
  word is one `map` value written by the entrypoint, and the container refuses to start on any word but `off` and `upgrading` (an unset
  word is `off`: `docker-entrypoint.d/17-maintenance-default.envsh`). `/health`, the LAN Host pin and the allow list are in front of or
  beside it and unchanged. `gateway-lan` takes the same word.

`tests/gateway-config.test.mjs` pins the table above, the arithmetic and this wording; `tests/gateway-nginx.test.mjs` runs the
real image against stand-in upstreams and checks that a burst of 1800 is passed and the next request is refused (the request that opens the bucket makes it 1801), and that another address is not affected.

## LAN fallback (gateway-lan)

**Owner decision of 2026-10-26: cleartext to a private LAN address, fallback only.** This amends the rule of the app's decision log
(D24) that the app never uses cleartext http: for exactly one case, an internet outage, the app may talk plain http to the server's own
private address on the warehouse network. The app uses it only after a transport failure of the public https address, and returns to
the public address when that works again. No other cleartext is allowed: the app still refuses an `http` address anywhere else.

**What runs.** The optional Compose service `gateway-lan` (profile `lan`, switched by `bash scripts/lan.sh on|off`, off by default).
It is **the gateway's own image**, not a second build: the image holds the public server in `/etc/nginx/templates` and the LAN server
(`docker/nginx/lan/gateway-lan.conf.template`) with a copy of the http-level template in `/etc/nginx/templates-lan`, and the
service tells the image's entrypoint to render that directory (`NGINX_ENVSUBST_TEMPLATE_DIR`). So an upgrade that rebuilds the
gateway rebuilds this too, nothing is mounted from the checkout, and the two containers can never run different versions of the
routes. It has the same hardening and limits as the gateway (read-only root, no capability, 128 MB, half a CPU) and is on `default`
only. It listens on 8080 inside the container, plain http, no TLS and no HTTP/2, and is published on
`${LAN_BIND_IP}:${LAN_HTTP_PORT}` only; the default bind is loopback, where nothing outside the host can reach it. A separate
container, so a failed bind (the router gave the host another address) or a mistake in the LAN server cannot take the public gateway
down; `scripts/compose.sh` also leaves the profile out of a command while the host does not have the address, so the public services
still start. **A fault of the fallback never stops a start, a setup, an upgrade or a restore**: `start.sh`, `setup.sh` and `restore.sh`
wait for the public services only and start `gateway-lan` on its own afterwards (`scripts/lan.sh start`), where a failure is a
warning, and the health check (`doctor --local`) counts it as a warning like an optional service.

**Trust boundary.**

- *No trust in a header for the client address.* The LAN server has no `set_real_ip_from` or `real_ip_header`; the client address is the
  connection's. Every route that passes an address on sets `CF-Connecting-IP`, `X-Real-IP` and `X-Forwarded-For` from `$remote_addr`
  (the routes file is shared with the public server, which takes the address from the tunnel hop instead), so a phone cannot choose the
  address that the rate limits and the per-source OTP limits of `operator-otp` and `central-exchange` see. The limits are per phone, not
  per facility. A request that names another address in a header gets nothing from it (`tests/gateway-nginx.test.mjs` forges the
  headers and reads what the upstream sees).
- *The same checks.* One routes file: the `apikey` check on REST, the 10 / 50 MB body limits, the 1800 and 100 buckets, the 404 for a
  dot segment, the error bodies the app reads. The functions and PostgREST check tokens, sessions and roles exactly as they do for
  the public path.
- *Who may connect.* Four layers: the published address (the host's own private address, never `0.0.0.0`), `allow ${LAN_CIDR}; deny all;`
  inside the server (a private range, checked by `18-require-env.sh`, which refuses to start the container without one), the Host pin
  (below), and, if the host needs it, a filter of its own in Docker's `DOCKER-USER` chain (below). The allow-list is checked after the
  rewrite-phase answers of the routes (the 401 of the key check, the 404 of an unknown path), which show a client nothing it could use;
  a refused client gets 403 and no upstream is reached.
- *The Host header is pinned* (owner decision of 2026-10-26). The LAN server answers only when the request's `Host` is `LAN_BIND_IP` or
  `LAN_BIND_IP:LAN_HTTP_PORT` (the app addresses the server by its IP address, so a phone writes exactly that), plus `127.0.0.1:8080` and
  `localhost:8080` for the container's own health check. Any other Host is a 404 (the JSON body of any unknown path, with
  `X-Warehouse-Path: lan`) answered before the location, the allow list and any rate-limit bucket, so nothing reaches an upstream. This
  closes DNS rebinding: a web page in a browser on the Wi-Fi that was moved onto the server's address by its own DNS name carries that
  name as Host and reads nothing from the API. It is a `map` on `$http_host` in the LAN template, with the two values written into it at
  start by the entrypoint. Do not forward `LAN_HTTP_PORT` on the router: some routers re-address forwarded traffic to their own LAN
  address, which is inside `LAN_CIDR`.
- *`/health`* answers the container's own check only, as on the public server.
- *The path is named.* Every API answer carries `X-Warehouse-Path: lan` (the public server sends `public`), which the app shows and
  `doctor` and the checker use to tell the two listeners apart. It is on the answers the gateway makes itself too: 401, 403, 404, 413,
  429, 502, 503, 504 and the preflight. Answers that Cloudflare makes (530, 52x) do not carry it.

**The firewall of the host.** Nothing needs to be added, and no ufw command helps. Docker puts its own FORWARD rules (`DOCKER-USER`,
then `DOCKER`) in front of ufw's and accepts the traffic of a published port there, so ufw rules, incoming or routed
(`ufw default deny routed` included), never see these packets. The controls that count are the bind address and the allow-list of the
LAN server. A host that must filter Docker-published traffic itself does it in the `DOCKER-USER` chain (Docker documents this under
"Packet filtering and firewalls"), where the packet has already been translated: its destination is the container's address and port
8080, so a rule has to name the original address and port with conntrack. For example, to drop connections to this published address
from outside the warehouse network (default iptables firewall backend; adjust the address, port and range to `lan.sh status`; rules in
`DOCKER-USER` are not saved across a reboot by Docker, so the host's own firewall tooling has to restore them):

```
sudo iptables -I DOCKER-USER -p tcp -m conntrack --ctorigdst 192.168.1.20 --ctorigdstport 8080 ! -s 192.168.1.0/24 -j DROP
```

**The source address (an assumption).** The allow-list, the per-phone limits and the per-source OTP limits all rest on `$remote_addr`
being the phone's own address. That holds on the documented baseline: a **rootful Docker Engine with its iptables rules**, where a port
published on a specific host address is forwarded by address translation in the host's nat table and the packets keep their source (the
userland proxy only carries loopback and hairpin traffic). It does not hold with rootless Docker (its port driver presents every phone as
the bridge's address), with `"iptables": false` in `/etc/docker/daemon.json`, or with Docker Desktop: every phone then appears as one
Docker address, which a normal `LAN_CIDR` answers 403, and one that overlaps Docker's own networks (`192.168.0.0/16` against Compose's
`192.168.x.0/20` pools, or `172.16.0.0/12`) lets every device in and gives them all one rate-limit bucket. `doctor` and `lan.sh` warn about
rootless Docker, Docker Desktop, `"iptables": false` and a `LAN_CIDR` that overlaps a Docker network of the installation. A host
that probes from itself cannot see the phone's side, so also compare one phone's Wi-Fi address with `LAN_CIDR`.

**The keys.** `gateway-lan` holds the API keys in its configuration, like the gateway (the map of the `apikey` header, written at
start). After `rotate-keys.sh` a container that was not recreated still has the old keys and answers the gateway's
`401 {"message":"Unauthorized"}` to every REST request of every phone, while `get-public-config`, which has no key check, keeps
answering. `rotate-keys.sh` therefore recreates `gateway-lan` whenever a container of it exists (a failure there is a warning that
names the repair), and `doctor` and the checker (`lan_http_down`) send the anon key of `compose.env` to the LAN address on `GET /rest/v1/`
and fail on the gateway's 401. **The app must not end its session on a 401 that arrives over the LAN path**: that is what makes this
fault dangerous (see the note under "Gateway limits and routes").

**The exposure the owner accepted** (decision of 2026-10-26; stated in full here). Plain http means that, while a phone is on
this path, its access token (one hour), any refresh token it exchanges, and every photo and document it sends or receives are readable by
anyone who can see the warehouse Wi-Fi traffic. In particular:

- **A token that is read works from anywhere, not only on the LAN.** Access tokens and the session check are not bound to an origin, so a
  token sniffed on the Wi-Fi works through the public address as well, including from the attacker's own mobile data during the
  facility's outage, until it ends (one hour).
- **A stolen refresh token keeps a session alive.** The refresh call goes over REST, so a phone uses the LAN path for it during an outage,
  and its answer carries the next refresh token. With sliding sessions (30 days idle, 90 days at most), a thief who refreshes first keeps
  the session going until the real phone presents the token it had; reuse detection then deletes the session for both. The same
  mechanism lets anyone on the Wi-Fi sign real phones out during an outage, when they cannot sign back in.
- **Administrator tokens carry administrator rights.** A sniffed administrator token can do whatever the administrator can, until it ends.
- **A stale saved address can send tokens to another device.** If the host's address changes (a DHCP lease) and a phone still holds the old
  one, it would send its token to whichever device now has that address, unless the app checks first. The app that uses the fallback
  (not released yet) is to probe the saved address without credentials before it sends any (`GET /functions/v1/get-public-config`,
  which must answer 200 with `X-Warehouse-Path: lan` and this installation's `instanceId`), and to check it once a day while the
  internet is up and the phone is on Wi-Fi, so a stale address shows before the outage.
- **A break-glass sign-in code crosses the Wi-Fi in clear** when an administrator signs in over the LAN path during an outage
  (OPERATOR_INSTALL.md, "Break-glass administrator sign-in"): it is valid for 10 minutes and works once, so a code read from the traffic
  is a race the administrator wins by typing it first.

Mitigations that stay: refresh tokens rotate at every use and a stolen one used beside the real phone deletes the session (reuse
detection, [OPERATOR_INSTALL.md](OPERATOR_INSTALL.md#authentication-and-otp-limits)); sessions are deleted when a person is deactivated;
the app uses the LAN address only while the public address fails; the listener answers the warehouse network only and only by its own
address; the SMS code and the central identity token still never cross it (sign-in needs the internet, except the break-glass case
above). The facility's Wi-Fi password is therefore a credential of this system
([OPERATOR_INSTALL.md](OPERATOR_INSTALL.md#lan-fallback-plain-http-on-the-warehouse-network)). Turning the fallback off
(`bash scripts/lan.sh off`) removes the listener entirely.

**Logs.** `gateway-lan` writes the gateway's access-log format (path without the query, no credential), with the phone's own address in
front; the checker reads both logs together (`checkApiLogs`).

## Logs

What a service log may hold, for the 3 x 10 MB of `json-file` log each service keeps (`docker/docker-compose.yml`,
`x-logging`; the oldest file is dropped when the third fills, and a recreated container starts with an empty log).

- **The rule.** No log line holds a token, a key, an OTP, a password or a query string. A signed storage link
  (`?token=`) is a credential in a query string: a retained log that holds one can replay a still-valid document link.
- **Client addresses are allowed in the gateway log, for its rotation life** (owner decision of 2026-10-17). Nothing else
  identifies a person: no user agent, no referer, no phone number, no session.
- **Gateway access log** (`docker/nginx/nginx.conf`, `log_format warehouse_redacted`, on the container's stdout): a short
  format that replaces nginx's default `combined` one, which writes the whole request line, query string and all. A line is
  `client-address [time] "METHOD /path HTTP/x" status bytes seconds`, for example
  `203.0.113.7 [17/Oct/2026:17:43:35 +0000] "GET /storage/v1/object/sign/docs/a.pdf HTTP/1.1" 200 478 0.034`. `$uri` is
  the path without the query. Do not add `$request`, `$request_uri`, `$args`, `$query_string`, `$http_referer` or
  `$http_user_agent`; `tests/gateway-config.test.mjs` fails if one appears, and `npm run test:gateway` sends a fictional
  signed-link request and fails if the running gateway's log holds `token=`. The
  format is the same one Kong wrote, so the checker (`checkApiLogs` in `scripts/watch.mjs`) reads it unchanged. The health
  check of the container is not logged.
- **Storage.** The storage service redacts `token` and the `X-Amz-*` signature parameters in the URL it logs. It also
  writes request headers into its log: `cf-connecting-ip` and `x-real-ip`. The gateway passes none of the three client-address
  headers (`CF-Connecting-IP`, `X-Real-IP`, `X-Forwarded-For`) to storage, and clears any value the client sent under those
  names, so the client address no longer reaches storage or its log. (Kong could remove `CF-Connecting-IP` only: it added
  `X-Real-IP` and `X-Forwarded-For` itself after its plugins had run.) Storage does not use the address: its
  image-render rate limit is off (`RATE_LIMITER_ENABLED` is unset).
- **Residual: the gateway's error log.** nginx quotes the request line, query string included, in an error line (for
  example `upstream timed out ..., request: "GET /storage/v1/object/sign/...?token=..."`). These lines appear only while
  a service fails (or for a body over its size limit, which nginx also logs with the request line), but a signed link that failed while it was valid stays in the log until it rotates out. The document
  functions make a signed link valid for one hour, so the exposure ends then. A request refused by the rate limit writes no
  error line (it is in the access log as 429 only), so a flood cannot fill the error log.
- **Database log** (`docker/docker-compose.yml`, the `db` command; the same 3 x 10 MB). It holds warnings and errors, lock
  waits (`log_lock_waits=on`), every statement slower than 1 s (`log_min_duration_statement=1000`), and every temporary file of
  10 MB or more (`log_temp_files=10240`, in kB). Until 2026-10 it also held one line per connection and disconnection
  (`log_connections` and `log_disconnections` on) and every temporary file (`log_temp_files=0`), which filled the 30 MB with
  noise and pushed out the lines that explain an incident; both connection settings are now `off`. **`log_parameter_max_length=0`
  keeps parameter values out of the slow-statement log.** PostgREST sends the request body as a parameter, and a sign-in request
  carries the code: without this setting a slow `operator_verify_otp` would log it. The statement text is logged with `$1`,
  `$2` in place of values. `log_statement` stays `none`. How to read it: [MONITORING.md](MONITORING.md#finding-a-slow-query).
- The function logs, the sensor bridge (replaces any query with `***`) and the PDF functions follow the rules in their
  own sections.

## Image pins

PostgREST is referenced in `docker/docker-compose.yml` with the index digest of its tag (the multi-platform
manifest list), and the gateway's nginx in the `FROM` line of `docker/nginx/Dockerfile` with its tag and index digest; both
are read with `docker buildx imagetools inspect`. To move one, read the new digest the same way and change
tag and digest together. The PostgREST image has no package inventory, so its exception is bound to this digest
("Exceptions"). The nginx recipe runs `apk upgrade`, so its Alpine packages follow the live repository; it stays on the stable
branch (1.30; Dependabot proposes patch releases only, `.github/dependabot.yml`), and the move to the next stable branch
(1.32, due in 2027) is made by hand: read the nginx release notes for the changed directives, rebuild and run
`node --test tests/gateway-nginx.test.mjs` and `npm run test:gateway`. `tests/gateway-config.test.mjs` accepts any even nginx
minor from 1.30 in the `-alpine-slim` variant, so that move needs no test edit.

**Base image watch.** A pin by digest does not notice that its base stops receiving patches: node drops the Alpine release
a tag names (the Storage image's `node:24.22.1-alpine3.23` is the first, expected around the end of 2026), nginx stops a stable
branch when the next one ships, python drops a Debian release. Nothing fails; a later scan is the first sign.
`.github/workflows/base-images.yml` runs `scripts/check-base-images.mjs` weekly: for every `FROM name:tag@sha256:` in
`docker/*/Dockerfile` and every `image:` of `docker/docker-compose.yml` that is an official Docker image (node, nginx, python,
postgres, debian, ubuntu, alpine) it reads `library/<name>` in `docker-library/official-images` and **fails** when no tag of the
pin's line (node 24, postgres 18, python 3.15, nginx 1.30) with the pin's variant is published any more, and asks Docker Hub
once per pin and **warns** when the pinned tag was last pushed more than 120 days ago. Either opens or updates one issue, "Base
image pins need attention", and a clean week closes it; when the issue is already open and a FAIL or WARN is new in it (a pin
the issue did not list), the run adds one comment that lists only the new lines, because an edit notifies nobody. A pin may be
written `name:tag`, `library/name:tag` or `docker.io/library/name:tag`. Docker Hub rate limits anonymous clients: a 429, or a 5xx
or a timeout on both of two tries, ends the age check for that run with exit code 3, which the workflow treats as neutral (no
issue change, green run); the next week asks again. **Nothing else is neutral.** Any other answer the age check cannot use (a 401,
403 or 410, a redirect because the API moved, a 200 without a push date) is exit code 2: the run fails and the issue is left
alone, so the age check cannot stop for good without a red run. A run whose script crashes (exit 1 with no FAIL line) fails too
and never closes the issue as clean.

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
`rest-no-package-inventory`. The images of the gateway, Storage and CUPS need none.

**Where to run it.** Run the scan with a throwaway operator state of its own project name, never with an installation's
state: every image is rebuilt with `--no-cache` and gets a new image ID, so on an installation the scan would move every
`<project>-*` tag under the running containers to that day's packages, images no recorded build made, which the next
start would pick up. `scripts/scan-images.sh` refuses while the state's project has any container, running or stopped.
Remove the throwaway project's `<project>-*` images afterwards.

**Release images: what was scanned is what runs (owner decision of 2026-10-26).** For a release tag, the `publish-images` job of
`.github/workflows/release.yml` runs this gate on the tagged commit (`npm run scan:images`, Trivy pinned and checksum-verified in the
workflow, the ledger above; a row no valid entry covers, an expired entry or a failed scan fails the job) and only then logs in to the
registry and pushes the images it just scanned, as `ghcr.io/abhiguru/supabase-warehouse-template/<service>:<tag>`
(`scripts/publish-images.sh`; the services that are pulled, such as `rest`, are not republished). Each image carries the labels
`org.opencontainers.image.revision` (the commit) and `org.opencontainers.image.version` (the tag), added to the scanned image without
changing its layers (the script checks that). A final release on the commit of its newest release candidate builds and scans nothing: it
re-tags the candidate's images by digest, so the bytes released are the bytes that were scanned and rehearsed for the candidate
([RELEASE_CHECKLIST.md](RELEASE_CHECKLIST.md#image-publication)). `release-images.json`, attached to the GitHub Release, lists each image by
digest next to the fingerprint of its recipe. A facility at that tag pulls an image by that digest when its checkout's recipe has that
fingerprint (`scripts/build-images.sh --from-release`, run by `setup.sh`; [OPERATOR_INSTALL.md](OPERATOR_INSTALL.md#rerun-and-upgrade)),
checks the digest of the image it got and that its revision label is its checkout's commit, so the bytes that run are the bytes the scan read.

**The trust statement, in full.** What a facility relies on, in this order: (1) the maintainer's GitHub account and TLS to `github.com` and
`ghcr.io`, as for `git fetch` of the tag; (2) the digest, which pins the content of an image once the list is trusted; (3) the release being
**immutable**: with GitHub's immutable releases switched on for the repository (the release checklist makes it a step before the first
candidate), a published release's tag and assets, `release-images.json` among them, cannot be changed or deleted afterwards; (4) the
revision label: the facility refuses an image built from any other commit than its own checkout's, which closes the substitution of an older
release's genuine image for a current one in a replaced list. It also refuses a file for another release or commit and any reference
outside `ghcr.io/abhiguru/supabase-warehouse-template`. **What it does not do:** no cryptographic signature of the images or the list is
checked on the host (no `cosign` or attestation tool is installed there), so the label is a statement by whoever pushed the image, not proof
of who built it; a maintainer account that is taken over can publish a new release with images of its own, exactly as it could publish new
code. Before immutable releases are switched on, the list is an ordinary release asset that anyone with write access to the repository's
releases can replace. A facility whose checkout is not the released tree (a changed recipe, `main`, a branch), or that cannot fetch the
file or an image, builds the image from the same recipe on its own host, as before: that image has the packages of the day it was built,
and is not the scanned one. The scan of the release is then the check of the recipe, and the weekly base-image and dependency checks and each
release's own scan stay the check of what a rebuild gets.

**Release-day packages.** A published image keeps the operating-system packages of the day it was built, and nothing rescans a published
digest. A facility that installs an old tag later gets older packages than a build on its host would, and a final release re-tags the images of
its candidate, so its packages are those of the candidate's day. What is new is found by the weekly base-image and dependency checks and by the
scan of the next release, not by the published image.

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
  through the gateway with its `apikey` check, a 10 MB body limit and the REST rate limit; `public.check_session` before every request;
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

### Dependency advisory exceptions

The two frozen npm trees (`docker/storage`, the dependency set of the pinned Storage release, about 900 packages, and
`docker/pdf-renderer`) meet a new advisory in any week, and Storage's tree moves only with its publisher's tag
([docker/storage/README.md](../docker/storage/README.md)). Owner decision of 2026-10-26: the live `npm audit` is not a required
check. On 2026-10-24 advisories published after the last merge turned every pull request red until the lock was rebuilt.

- **A pull request** runs `scripts/audit-compare.mjs --base-ref <base commit>` in the `validate` job. For each tree whose
  `package.json` or `package-lock.json` the pull request changes, it runs `npm audit --json` on the change and on the base, and fails
  for an advisory **only** when the change introduces a HIGH or CRITICAL advisory (identified by advisory id and package) that the base did not have and
  that no valid exception covers. A tree the pull request does not touch is not audited, so a documentation change, a Dependabot bump of
  another tree and a pull request on a day with a newly published advisory all pass. If the audit cannot be read (registry down,
  base commit missing) the check fails; it never passes unread, and neither does a tree whose `package-lock.json` is deleted while
  its `package.json` stays (npm audit and the image build need the lock; removing both files removes the tree). The ledger is read
  from the pull request's own tree, so a pull request can add a dependency and the exception for it together: every advisory an
  exception covers is shown as a warning annotation on the checks page, with its reason and expiry, for the reviewer.
- **Every week** `.github/workflows/dependency-audit.yml` runs `scripts/audit-compare.mjs --live`: both trees as they are, at HIGH
  and CRITICAL. It lists advisories with no valid exception, expired exceptions, and exceptions that expire within 14 days, in one
  issue ("Dependency advisories, <date>", closed when the audit is clean). An edit notifies nobody, and this issue is the only
  signal for an advisory published after the last merge, so when the issue is already open and a finding line is new in it, the run
  adds one comment that lists only the new lines; a week with nothing new edits the body silently. A finding never fails the run, so
  there is no weekly failure e-mail; an unreadable audit does.
- **The exception ledger** `docker/npm-audit-exceptions.json` (`schemaVersion` 1, empty to start) lists
  `{id, package, manifest, reason, owner, reviewed, expires}`: `id` is the advisory (`GHSA-xxxx-xxxx-xxxx`, as in npm's advisory
  URL; the numeric npm id when npm prints no GHSA), `package` the vulnerable package, `manifest` `docker/storage` or
  `docker/pdf-renderer`. Like the image ledger, `expires` may be at most 90 days after `reviewed`, an entry that breaks a rule
  rejects the whole ledger (`tests/audit-compare.test.mjs` checks the committed file), and an entry past its `expires` date covers
  nothing: an advisory only it covered fails the pull request with a message to renew it, and the weekly issue lists it. Prefer to
  raise the dependency; an exception states why the advisory does not apply or why the fix cannot be taken yet.

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
releases about every week. `.github/workflows/cft-freshness.yml` runs `scripts/check-cft-freshness.mjs --mode fail` weekly:
a pinned `CHS_VERSION` more than 14 days behind the current Stable in Chrome for Testing's `last-known-good-versions.json` opens or
updates an issue, and a current pin closes it. **That issue is the only signal: a stale pin never blocks a release.** `release.yml`
runs the same script in `--mode warn` (the default), which prints a warning with the pinned and Stable versions and the age and
exits 0, for an old pin, an unknown age and a network error alike, so a tag, a security backport included, is never held up by a
Chrome bump (owner decision of 2026-10-26; the release needs no bump made in the previous two weeks). If the release dates
cannot be read, `--mode fail` exits 2: the weekly run fails, and no issue is opened or closed for it. Each network fetch is tried three times.

**Threat model of this gate.** The renderer draws only HTML that this backend itself built, on the internal `renderer` network that
has no route out, with JavaScript off and no network access from the page: no outside markup, script or URL reaches Chrome. The only
outside data is text that signed-in users entered or that fas-sync imported (company, customer and item names, document metadata and
table rows), always escaped, and the operator's letterhead image; escaped text and an image still reach Chrome's text shaping, layout
and image decoders. The risk a stale Chrome adds is therefore a browser bug triggered by such text or by that image, inside a container
that has no sandbox but also no capabilities and no network, which is small, and a release is not held for it; the weekly issue keeps
the pin honest, and a pin that stays stale is a decision to take in that issue, not a blocked tag. The image scan does not cover Chrome
itself (below). To bump: change both args and
puppeteer-core together (take the puppeteer-core release that pins that Chrome major), run the renderer's unit tests and
`test/integration.sh`, check the golden pages in the `pdf-renderer` job, then rebuild with `bash scripts/build-images.sh --no-cache` and scan. The
golden job renders a fictional corpus, rasterises it in a poppler container built from a fixed Debian snapshot and compares
decoded pixels with the committed goldens at fuzz 0, so a font, Chrome or puppeteer change that moves a pixel is seen and
judged (Gujarati shaping by eye, the rest as a failure).

**Why Trivy cannot see the CfT binary.** CHS arrives as a zip from `storage.googleapis.com/chrome-for-testing-public`, not
as a Debian package, so a scan covers only Node, the Debian libraries and fonts, and the npm tree (also audited weekly and on
every pull request that changes it, "Dependency advisory exceptions" above). The Chrome release notes, the freshness check
above and the pinned SHA-256 are the control for Chrome itself. No Chrome findings in a scan is not a clean bill.

**Fonts.** The image installs these font packages by name, without versions: `fonts-liberation`, `fonts-liberation2`,
`fonts-dejavu-core`, `fonts-noto-core` (Gujarati) and `fonts-noto-mono`, with a fontconfig file, so documents paginate and look the same from
build to build. The build fails unless the sorted `fc-list` file list hashes to the value in `ARG FONT_FILELIST_SHA256`,
which proves the font set did not change (since 2026-10-21 the hash starts `9ebf7b69` and the image is 826 MB instead of 941 MB: CJK, colour emoji, Carlito, Caladea, OpenSymbol and the extra DejaVu fonts were dropped; the golden PDFs match at fuzz 0); a font package that Debian drops or updates therefore stops the build instead of
changing the output silently. Exact version pins are deliberately not used: the `+debNuM` security revisions vanish from the
archive within weeks and would break every build. Drift is caught by the file-list hash at build time and by the
golden-PDF job on every change.

## audit_log retention

`audit_log` keeps 730 days (2 years). Its monthly partitions are created ahead (3 months), and partitions older than the cutoff are dropped by
the daily chain (`watch.mjs`, `watch-daily.sh`, `retention.sh apply`, `run_database_retention`); see "Retention" in
[OPERATOR_INSTALL.md](OPERATOR_INSTALL.md#retention).

## Sensor bridge

The optional `sensor-bridge` service (profile `sensors`, [SENSORS.md](SENSORS.md)) is the one container that talks to
devices on the facility LAN. What limits it:

- **Network:** `default` only, so it reaches the gateway and cannot open a connection to PostgreSQL. It publishes no port. Its
  only call into the project is `http://gateway:8000/functions/v1/ingest-sensor-readings`, fixed in Compose rather than taken
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
| `pgbouncer` | yes | no | yes | Supavisor's pool user; exists only while the pooler is on (`pooler.sh on`), not created by the bootstrap |
| `anon`, `authenticated` | no | no | yes | API roles; statement timeouts 3 s and 8 s (applied by PostgREST: `PGRST_DB_CONFIG: "true"`, see below) |
| `service_role` | no | no | yes | `BYPASSRLS`; the edge functions' role |

**The two statement timeouts only work with `PGRST_DB_CONFIG: "true"`** (`docker/docker-compose.yml`, `rest`). PostgREST logs in
as `authenticator` and switches to `anon` or `authenticated` with `SET ROLE`, which does not apply the role's own `ALTER ROLE ...
SET` values; with the option off it never reads them, so an anonymous call ran under the `authenticator`'s 8 s and a change to
the two API roles' settings did nothing. Measured on PostgREST v16.4 and PostgreSQL 18 with a function that sleeps: `pg_sleep(5)`
as `anon` took 5.0 s with the option off and was cut at 3.0 s with `canceling statement due to statement timeout` (SQLSTATE
57014) with it on; as `authenticated` it stays at 8 s either way. No `pgrst.*` setting is stored in the database, so the option
changes nothing else. The `db` container also gets `shm_size: 256m` (Docker's default `/dev/shm` is 64 MB, which a parallel
query at a larger `work_mem` can fill; it counts against the 1 GiB limit only when used).

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
the place for a role. The pooler's role, schema and database are the one exception to "roles come from the bootstrap": they exist only while the pooler is on (`bash scripts/pooler.sh on`) and come from `scripts/configure-pooler.sql`, which `scripts/db-roles.sh apply` runs while `POOLER_ENABLED=true` and undoes (`scripts/drop-pooler.sql`) while it is `false`; they are not in a migration or in the bootstrap. A migration after the baseline must not `CREATE`, `ALTER` or `DROP` a role or grant membership in one
(`tests/migration-roles.test.mjs` fails on it). A role change goes into the bootstrap (and into
`scripts/configure-db-roles.sql` for installations that already exist). A database-level fix made in the bootstrap (a schema, a
grant, a setting of the database) also ships as a migration, so that an existing facility gets it and a restored one keeps it.

## Database passwords: one per login

Each database login has its own password in `config/compose.env`, so the credential of one service does not open the others.

| Login | Password (`config/compose.env`) | Used by | Set by |
|---|---|---|---|
| `supabase_admin` (the only superuser) | `POSTGRES_PASSWORD` | operator scripts (`compose exec db psql -U supabase_admin`), Supavisor's metadata database (`_supabase`, only while the pooler is on) | the image's entrypoint at the first start; `npm run db:rotate-passwords -- --yes --superuser` |
| `authenticator` | `DB_PASSWORD_AUTHENTICATOR` | PostgREST | `docker/volumes/db/roles.sql` at the first start; `scripts/configure-db-roles.sql` on every setup run, after both restores and on rotation |
| `supabase_storage_admin` | `DB_PASSWORD_STORAGE` | Storage | the same |
| `pgbouncer` | `DB_PASSWORD_POOLER` (exists only after `pooler.sh on`) | Supavisor's pool user (pooler profile) | `scripts/db-roles.sh apply` while the pooler is on; `docker/volumes/pooler/pooler.exs` writes it into the stored tenant at every pooler start |

`scripts/configure.mjs` generates the three service values (64 hexadecimal characters each) with every fresh state, and its
existing-state branch appends any that a state lacks; it never replaces a value that exists. The doctor refuses a state
where one is missing, malformed, or repeats `POSTGRES_PASSWORD` or another one. The Compose files name each value with
`${NAME:?…}`, so a state without it fails at `compose config` with "Run setup.sh to generate the per-role database
passwords". In the rendered configuration `POSTGRES_PASSWORD` appears only in db and (when the pooler profile is rendered) supavisor; each service value only in
its own service and in db, whose first-start init script reads them (`tests/compose-networks.test.mjs`).

`scripts/db-roles.sh apply` turns each value into a SCRAM-SHA-256 verifier (`scripts/db-roles.mjs`, the format PostgreSQL
stores; `tests/db-roles.test.mjs` compares it with one PostgreSQL made) and sends the verifiers, with the superuser password
to sign in, on standard input of `compose exec`. `ALTER ROLE … PASSWORD` stores a verifier as it is, so no password can
appear in a log, in `pg_stat_activity` or in `pg_stat_statements`, and no value is a command-line argument or an
environment variable of a docker command. While the pooler is on, Supavisor stores its tenant, with the pool user's password, in `_supabase`,
encrypted with `VAULT_ENC_KEY`; `pooler.exs` rewrites the pool user's credentials of an existing tenant at every start,
which covers a rotation. `_supabase` is not in backups; setup recreates it while `POOLER_ENABLED=true`.

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
- `no-new-privileges`, dropped capabilities and a read-only root filesystem are set on the gateway, `gateway-lan`, the PDF renderer and the
  sensor bridge. The other services have not been trialled, so they are not hardened this way.
- **CUPS runs privileged** (optional profile). It also accepts print jobs from any container on `default` without a login;
  no function reaches it while the router refuses the printing functions.
- Every service except CUPS has a CPU and memory limit (`docker/docker-compose.yml`) and bounded logs.

## Open items

- **Scheduled image scan.** No workflow runs `npm run scan:images`. The release checklist requires it before each release
  and the exceptions expire, but a scheduled workflow would catch an expiry or a new fixed advisory between releases.
- **Storage `npm install`.** `npm ci` would fail on lock drift but deletes `node_modules` first, and the recipe keeps the
  publisher's prebuilt native modules and runs no install scripts, so they would not be rebuilt. Moving to `npm ci` needs a
  build that proves Storage still starts.
- **PostgREST scan coverage**, above.
- **jose 5 to 6.** A version move, not made.
- **No recovery from WAL.** WAL archiving is off (`archive_mode=off`) and the image has no WAL archiving tool, so there is no
  point-in-time recovery. The supported backup path is `db:backup` and `db:verify-restore`; PITR, external object storage
  and RTO/RPO need a separate recovery drill with approved storage and policies.

> The role and schema `pgbouncer`, the database `_supabase` and the secrets `DB_PASSWORD_POOLER`, `SECRET_KEY_BASE`, `VAULT_ENC_KEY` exist only after `bash scripts/pooler.sh on`; a new install has six database roles (`anon`, `authenticated`, `service_role`, `authenticator`, `supabase_storage_admin`, `supabase_admin`).
