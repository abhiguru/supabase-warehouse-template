# Architecture

## Containers and networks

The Compose project has three networks. A container resolves and reaches
another only on a network both are attached to
(`docker/docker-compose.yml`; `tests/compose-networks.test.mjs` asserts the
network table from the rendered configuration).

```
 cloudflared ──▶ 127.0.0.1:18000
                      │                    LAN address:8080 (only while the LAN fallback is on)
              ┌───────▼────────────────── default ──────────────────────────┐
              │  gateway :8000 ──▶ REST :3000   Storage :5000               │
              │              └──▶ Functions :9000                           │
              │  gateway-lan :8080 (profile; the same routes, plain http)   │
              │  CUPS :631 (profile)                                        │
              │  sensor-bridge ──▶ gateway (profile; polls hubs on the LAN) │
              └────────────────────┬────────────────────────────────────────┘
                          REST, Storage
              ┌────────────────────▼────── database ────────────────────────┐
              │  PostgreSQL :5432            Supavisor (only while on)      │
              └────────────────────┬────────────────────────────────────────┘
              ┌─────────────────────────── renderer (internal) ─────────────┐
              │  Functions ──▶ pdf-renderer :3000   (no route out)          │
              └─────────────────────────────────────────────────────────────┘
```

| Service | Image | Port (inside) | Started |
|---|---|---|---|
| gateway | nginx 1.30.x (official image, alpine-slim variant), one worker; [`docker/nginx`](../docker/nginx) | 8000, published on `127.0.0.1:${GATEWAY_HTTP_PORT}` (default 18000) | always |
| rest | PostgREST v16.4 | 3000 | always |
| storage | Supabase storage-api 1.80.2 | 5000 | always |
| functions | Supabase edge-runtime 1.77.4 | 9000 | always |
| db | PostgreSQL 18 (official `postgres:18.6-trixie` image; roles from `docker/volumes/db/00-bootstrap.sql`, superuser `supabase_admin`, no `postgres` role; schema from the one baseline migration, [DEVELOPER_HANDOFF.md](DEVELOPER_HANDOFF.md#migration-conventions)) | 5432 | always |
| pdf-renderer | own recipe, chrome-headless-shell | 3000 | always |
| gateway-lan | the gateway's image and routes with a plain-http LAN server ([`docker/nginx/lan`](../docker/nginx/lan)) | 8080, published on `${LAN_BIND_IP}:${LAN_HTTP_PORT}` (the host's own private address) | profile `lan`; off by default, switched with `bash scripts/lan.sh on\|off` ([OPERATOR_INSTALL.md](OPERATOR_INSTALL.md#lan-fallback-plain-http-on-the-warehouse-network)) |
| supavisor | Supavisor 2.9.13 | 4000, 5432, 6543 | profile `pooler`; off by default, switched with `bash scripts/pooler.sh on\|off` |
| cups | CUPS on Ubuntu 22.04 | 631 | profile `printing` |
| sensor-bridge | own recipe (GPL-3.0-or-later) | none | profile `sensors` |

Only the gateway publishes a host port, on loopback; while the LAN fallback is on, gateway-lan also publishes one, on the host's own private address. Addresses are assigned by Docker; nothing uses a fixed container address.

| Network | Attached services | Purpose |
|---|---|---|
| `default` | gateway, gateway-lan, rest, storage, functions, cups, sensor-bridge | The gateway and everything it or a function calls; the sensor bridge's calls to the gateway |
| `database` | db, rest, storage, supavisor (only while the pooler is on) | Connections to PostgreSQL |
| `renderer` | functions, pdf-renderer | The PDF renderer. The network is `internal`: Docker gives it no route to the host, the internet or any other network, so the renderer cannot reach the database or the gateway, and only the function runtime can reach it |

The gateway, gateway-lan, CUPS and the sensor bridge are on `default` only; the function runtime is on `default` and `renderer`; the PDF
renderer is on `renderer` only. None of them can open a connection to PostgreSQL. There is no web dashboard for the
database; operators use `psql` (see [OPERATOR_INSTALL.md](OPERATOR_INSTALL.md#ordinary-operation)). Rules for each image
and network: [CONTAINER_SECURITY.md](CONTAINER_SECURITY.md).

The monitoring checker (`scripts/watch.mjs`, run every 5 minutes by a systemd timer on the host) is not a container and
is on no network: it asks Docker and the database container what they see, and posts to Slack
([MONITORING.md](MONITORING.md)).

## Request flow

### API request (PostgREST)
```
Client → gateway :8000 → PostgREST :3000 → PostgreSQL :5432
         (key check,     (JWT verify,       (RLS and guarded
          rate limit)     check_session)     RPCs)
```

### Edge function request
```
Client → gateway :8000 → Edge Runtime :9000 → worker (Deno isolate)
         (CORS,           (main router)        → PostgREST :3000 / Storage :5000     (REST over HTTP, direct)
          rate limit)                          → gateway :8000 → PostgREST           (sign-in, ingest; see below)
                                               → pdf-renderer :3000                  (PDF)
                                               → CUPS                                (print, when enabled)
```

The main router checks the caller's JWT for every function except the public ones (`hello`, `get-public-config`,
`operator-otp`, `central-exchange`, `ingest-sensor-readings`).

A function never opens a connection to PostgreSQL: the `functions` container is not on the `database` network. It reaches
the data over HTTP, with plain `fetch` calls. Every call goes straight to PostgREST and Storage
(`SUPABASE_REST_URL=http://rest:3000`, `SUPABASE_STORAGE_URL=http://storage:5000`; `functions/_shared/supabase-rest.ts` for reports, PDFs and
configuration, `_shared/rest-url.ts` for `operator-otp`, `central-exchange`, `ingest-sensor-readings` and the profile read of
`_shared/auth-helpers.ts`), so none of them is under the gateway's per-client limits; only the client to gateway path remains. The calls carry either the caller's own token (document functions, so the RPC
guard and row policies decide) or the service key (sign-in, configuration, sensor ingest and PDF upload).

The gateway compresses JSON and text answers with gzip (nginx `gzip`, set in
`docker/nginx/nginx.conf`; the routes, key check, limits and buffers are in
`docker/nginx/api-locations.conf`). Only answers of 1,024 bytes
or more whose type is `application/json`, the PostgREST variants
(`application/vnd.pgrst.object+json`, `application/vnd.pgrst.array+json`),
`application/openapi+json`, `application/geo+json`, `text/plain` or `text/csv`
are compressed, and only for a client that sends `Accept-Encoding: gzip`. Images and
other storage downloads, PDFs, range answers, websocket upgrades and
answers that already carry a `Content-Encoding` (`get-public-config`) pass
through unchanged. The reason is the tunnel's upload speed: a 3,055-line invoice
preview is about 2.2 MB of JSON (after migration 101) and compresses to a small
fraction of that. A change to these files needs
`bash scripts/build-images.sh` and `bash scripts/compose.sh up -d --force-recreate --wait gateway`
(`bash setup.sh --operator` does both).

### Sign-in with an SMS code
```
App → gateway → operator-otp /request → operator_prepare_otp (limits, stores the keyed hash of a new code)
                                   → MSG91 (sends the code) → operator_finish_otp (records the outcome)
App → gateway → operator-otp /verify  → operator_verify_otp
              → warehouse_security.issue_session(user) → access token (HS256, one hour) + refresh token
App → gateway (Authorization: Bearer access token) → PostgREST → public.check_session → RPCs / RLS
```
`operator-otp` calls the `operator_*` RPCs with the service key. A pending customer gets an enrollment token instead of a
session until an administrator approves them. `refresh_jwt_token` (a PostgREST call, no function) renews the access token and replaces the refresh token each time.

### Sign-in with the association's central login (optional)
```
App → gateway → central-exchange → verifies the identity token (ES256, issuer, audience = this facility, lifetime, type)
                              → operator_central_exchange (accepts the token once)
                              → warehouse_security.issue_session(user) → the same session as above
```
Described in [CENTRAL_LOGIN.md](CENTRAL_LOGIN.md).

### Sensor readings
```
Tapo hubs (LAN) ◀── sensor-bridge ──▶ gateway :8000 ──▶ ingest-sensor-readings ──▶ record_sensor_batch
   (poll 5 min)     (queue in volume)  (no user JWT;   (service key, ingest       → sensor_readings, sensor_latest,
                                        ingest key)     key checked in SQL)          sensor_hubs ◀── app re-reads
```
The bridge is the optional `sensors` profile, or the same image as its own
Compose project posting through the tunnel ([SENSORS.md](SENSORS.md)).

## Lists

Every list RPC reads the tables directly, so a committed write is in the next list read; there is no refresh job
(see [API_CONTRACT.md](API_CONTRACT.md#list-freshness-migration-106-2026-10-19)). The app re-reads open order and
sensor screens on a timer; there is no live push.
