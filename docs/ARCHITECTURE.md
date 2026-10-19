# Architecture

## Containers and networks

The Compose project has three networks. A container resolves and reaches
another only on a network both are attached to
(`docker/docker-compose.yml`; `tests/compose-networks.test.mjs` asserts this
table from the rendered configuration).

```
 cloudflared ──▶ 127.0.0.1:18000
                      │
              ┌───────▼────────────────── default ──────────────────────────┐
              │  Kong :8000 ──▶ REST :3000   Storage :5000                  │
              │            └──▶ Functions :9000                             │
              │  CUPS :631 (profile)                                        │
              │  sensor-bridge ──▶ Kong (profile; polls hubs on the LAN)    │
              └────────────────────┬────────────────────────────────────────┘
                          REST, Storage
              ┌────────────────────▼────── database ────────────────────────┐
              │  PostgreSQL :5432            Supavisor (profile)            │
              └────────────────────┬────────────────────────────────────────┘
              ┌─────────────────────────── renderer (internal) ─────────────┐
              │  Functions ──▶ pdf-renderer :3000   (no route out)          │
              └─────────────────────────────────────────────────────────────┘
```

The monitoring checker (`scripts/watch.mjs`, run every 5 minutes by a systemd timer on the host) is not a container and
is on no network: it asks Docker and the database container what they see, and posts to Slack
([MONITORING.md](MONITORING.md)).

| Network | Attached services | Purpose |
|---|---|---|
| `default` | kong, rest, storage, functions, cups, sensor-bridge | The gateway and everything it or a function calls; the sensor bridge's calls to the gateway |
| `database` | db, rest, storage, supavisor | Connections to PostgreSQL |
| `renderer` | functions, pdf-renderer | The PDF renderer. The network is `internal`: Docker gives it no route to the host, the internet or any other network, so the renderer cannot reach the database or Kong, and only the function runtime can reach it |

Kong, CUPS and the sensor bridge are on `default` only;
the function runtime is on `default` and `renderer`; the PDF renderer is on
`renderer` only. None of them can open a connection to PostgreSQL. There is
no web dashboard for the database; operators use `psql` (see
[OPERATOR_INSTALL.md](OPERATOR_INSTALL.md), "Ordinary operation"). Only Kong publishes a
host port, on loopback. Addresses are assigned by Docker; nothing uses a fixed
container address.

## Request Flow

### API Request (PostgREST)
```
Client → Kong :8000 → PostgREST :3000 → PostgreSQL :5432
         (key-auth)   (JWT verify)       (RLS enforced)
```

Kong compresses JSON and text answers with gzip (nginx `gzip`, set by the
`KONG_NGINX_PROXY_GZIP*` variables of the `kong` service in
`docker/docker-compose.yml`, which land in the proxy server block of Kong's
rendered `nginx-kong.conf` next to `proxy_buffers`). Only answers of 1,024 bytes
or more whose type is `application/json`, the PostgREST variants
(`application/vnd.pgrst.object+json`, `application/vnd.pgrst.array+json`),
`application/openapi+json`, `application/geo+json`, `text/plain` or `text/csv`
are compressed, and only for a client that sends `Accept-Encoding: gzip`. Images and
other storage downloads, PDFs, range answers, websocket upgrades and
answers that already carry a `Content-Encoding` (`get-public-config`) pass
through unchanged. The reason is the tunnel's upload speed: a 3,055-line invoice
preview is about 2.2 MB of JSON (after migration 101) and compresses to a small
fraction of that. A change to these variables needs
`bash scripts/compose.sh up -d --force-recreate --wait kong`.

### Edge Function Request
```
Client → Kong :8000 → Edge Runtime :9000 → Worker (Deno V8 isolate)
         (CORS)       (JWT verify)          → PostgreSQL (direct)
                                            → pdf-renderer (PDF)
                                            → CUPS (print)
```

### OTP Authentication
```
Client → Kong → PostgREST → send_otp() → Twilio/MSG91
Client → Kong → PostgREST → verify_otp_or_register() → JWT token
Client → Kong (with JWT) → PostgREST → Data (RLS enforced)
```

### Sensor readings
```
Tapo hubs (LAN) ◀── sensor-bridge ──▶ Kong :8000 ──▶ ingest-sensor-readings ──▶ record_sensor_batch
   (poll 5 min)     (queue in volume)  (no user JWT;   (service key, ingest       → sensor_readings, sensor_latest,
                                        ingest key)     key checked in SQL)          sensor_hubs ◀── app re-reads
```
The bridge is the optional `sensors` profile, or the same image as its own
Compose project posting through the tunnel ([SENSORS.md](SENSORS.md)).

## Lists

Every list RPC reads the tables directly, so a committed write is in the next list read. Until migration
106 the Invoices list read a materialized view that a pg_cron job refreshed after each write; that view,
its refresh queue, the job and the `pg_cron` extension are gone (see [API_CONTRACT.md](API_CONTRACT.md),
"List freshness").
