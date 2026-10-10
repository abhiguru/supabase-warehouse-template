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
              │  Kong :8000 ──▶ REST :3000   Realtime :4000   Storage :5000 │
              │            └──▶ Functions :9000 ──▶ Gotenberg :3000         │
              │  imgproxy :5001 (from Storage)      CUPS :631 (profile)     │
              │  Prometheus, Alertmanager, exporters, Grafana (profile)     │
              └────────────────────┬────────────────────────────────────────┘
                 REST, Realtime, Storage, Postgres exporter, Grafana
              ┌────────────────────▼────── database ────────────────────────┐
              │  PostgreSQL :5432            Supavisor (profile)            │
              └────────────────────┬────────────────────────────────────────┘
              ┌────────────────────▼────── admin ───────────────────────────┐
              │  PostgreSQL        postgres-meta :8080        Studio :3000  │
              └─────────────────────────────────────────────────────────────┘
```

| Network | Attached services | Purpose |
|---|---|---|
| `default` | kong, rest, realtime, storage, imgproxy, functions, gotenberg, cups, auth (disabled), prometheus, alertmanager, postgres-exporter, node-exporter, cadvisor, grafana | The gateway and everything it or a function calls; monitoring scrapes |
| `database` | db, rest, realtime, storage, auth (disabled), supavisor, postgres-exporter, grafana | Connections to PostgreSQL |
| `admin` | db, meta, studio | postgres-meta and Studio, which run SQL without a login |

Kong, the function runtime, Gotenberg, imgproxy, CUPS and Prometheus are on
`default` only: they cannot open a connection to PostgreSQL, postgres-meta or
Studio. Studio is on `admin` only, so its panels that call the API gateway do
not work; it is kept for the metadata acceptance check. Only Kong publishes a
host port, on loopback. Addresses are assigned by Docker; nothing uses a fixed
container address.

## Request Flow

### API Request (PostgREST)
```
Client → Kong :8000 → PostgREST :3000 → PostgreSQL :5432
         (key-auth)   (JWT verify)       (RLS enforced)
```

### Edge Function Request
```
Client → Kong :8000 → Edge Runtime :9000 → Worker (Deno V8 isolate)
         (CORS)       (JWT verify)          → PostgreSQL (direct)
                                            → Gotenberg (PDF)
                                            → CUPS (print)
```

### OTP Authentication
```
Client → Kong → PostgREST → send_otp() → Twilio/MSG91
Client → Kong → PostgREST → verify_otp_or_register() → JWT token
Client → Kong (with JWT) → PostgREST → Data (RLS enforced)
```
