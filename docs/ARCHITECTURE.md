# Architecture

## Containers and networks

The Compose project has four networks. A container resolves and reaches
another only on a network both are attached to
(`docker/docker-compose.yml`; `tests/compose-networks.test.mjs` asserts this
table from the rendered configuration).

```
 cloudflared ──▶ 127.0.0.1:18000
                      │
              ┌───────▼────────────────── default ──────────────────────────┐
              │  Kong :8000 ──▶ REST :3000   Realtime :4000   Storage :5000 │
              │            └──▶ Functions :9000                             │
              │  imgproxy :5001 (from Storage)      CUPS :631 (profile)     │
              │  sensor-bridge ──▶ Kong (profile; polls hubs on the LAN)    │
              │  Prometheus, Alertmanager, exporters, Grafana (profile)     │
              └────────────────────┬────────────────────────────────────────┘
                 REST, Realtime, Storage, Postgres exporter, Grafana
              ┌────────────────────▼────── database ────────────────────────┐
              │  PostgreSQL :5432            Supavisor (profile)            │
              └────────────────────┬────────────────────────────────────────┘
              ┌────────────────────▼────── admin ───────────────────────────┐
              │  PostgreSQL        postgres-meta :8080        Studio :3000  │
              └─────────────────────────────────────────────────────────────┘
              ┌─────────────────────────── renderer (internal) ─────────────┐
              │  Functions ──▶ pdf-renderer :3000   (no route out)          │
              └─────────────────────────────────────────────────────────────┘
```

| Network | Attached services | Purpose |
|---|---|---|
| `default` | kong, rest, realtime, storage, imgproxy, functions, cups, sensor-bridge, auth (disabled), prometheus, alertmanager, postgres-exporter, node-exporter, cadvisor, grafana | The gateway and everything it or a function calls; monitoring scrapes; the sensor bridge's calls to the gateway |
| `database` | db, rest, realtime, storage, auth (disabled), supavisor, postgres-exporter, grafana | Connections to PostgreSQL |
| `admin` | db, meta, studio | postgres-meta and Studio, which run SQL without a login |
| `renderer` | functions, pdf-renderer | The PDF renderer. The network is `internal`: Docker gives it no route to the host, the internet or any other network, so the renderer cannot reach the database, Kong or Studio, and only the function runtime can reach it |

Kong, imgproxy, CUPS, the sensor bridge and Prometheus are on `default` only;
the function runtime is on `default` and `renderer`; the PDF renderer is on
`renderer` only. None of them can open a connection to PostgreSQL,
postgres-meta or Studio: Studio is on `admin` only, so its panels that call the API gateway do
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
                                        ingest key)     key checked in SQL)          sensor_hubs → Realtime → app
```
The bridge is the optional `sensors` profile, or the same image as its own
Compose project posting through the tunnel ([SENSORS.md](SENSORS.md)).

## List refresh

Three list RPCs read materialized views (`get_invoices_list`, `get_dispatch_list` and the legacy
`get_all_grn_items` overload; the contract and the full list are in
[API_CONTRACT.md](API_CONTRACT.md), "List freshness"). Since migration 91 (TW-BE-016) they are refreshed
after the commit, never inside a write:

```
write RPC ──▶ statement trigger ──▶ mark_lists_dirty()      pg_cron (in the db container, every 5 s)
  (lock 71040,   (per table: every     mv_refresh_queue:         │  CALL warehouse_security.
   rows, commit)  list that reads it)   needs_refresh, mark_seq, │       refresh_dirty_lists_worker()
                                        dirty_since              ▼  as warehouse_list_refresher
                                                     claim (FOR UPDATE) ─ COMMIT
                                                     per list: REFRESH ... CONCURRENTLY ─ COMMIT
                                                               record (clean only if mark_seq unchanged) ─ COMMIT
```

- **Marking.** Every table that a list reads carries a statement trigger that marks that list
  (`warehouse_security.mark_lists_dirty`). A mark always raises the list's `mark_seq`, locks the queue
  rows in one order, and keeps `last_marked_dirty` as the start of the current wait.
- **The worker** takes the session advisory lock 71046 (a run already in progress makes the next one
  return), never the document lock 71040, so a writer never waits for a refresh. 71040 therefore no
  longer keeps anything away from a view refresh: a migration that refreshes or replaces a list, or locks
  a table one reads, must not rely on it (migrations 19 and 68 took 71040 for that). Instead the migration
  run itself holds 71046 from before the first migration to its end (`scripts/migration-plan.mjs`, with a
  120 s lock timeout naming the holder), so no refresh overlaps a migration. It claims the dirty
  lists with their `mark_seq` after any writer still marking one has committed, then refreshes each
  list (`CONCURRENTLY`; whole only when a view cannot be refreshed concurrently) and commits per list.
  A list becomes clean only if no mark arrived since the claim; a refresh that fails or is stopped
  leaves it marked, with the SQLSTATE in `last_error_code`.
- **The runner** is pg_cron, which the pinned image preloads (`docker-compose.override.yml`:
  `shared_preload_libraries`, `cron.database_name=postgres`). Job `warehouse-list-refresh` runs as the
  LOGIN role `warehouse_list_refresher`, which has no password: pg_cron connects over 127.0.0.1 inside
  the db container, which the image's `pg_hba.conf` trusts, and every network address needs a password.
  The role may execute the worker and its four helpers and nothing else. Job
  `warehouse-list-refresh-history` keeps one day of run history.
- `warehouse_security.ensure_list_refresher()` creates the role, its settings
  (`statement_timeout` 120 s, `lock_timeout` 30 s) and both jobs; migration 91 and
  `scripts/configure-list-refresh.sql` (setup and restore) call it.
- `health-check.sh` (doctor) reads `warehouse_security.list_refresh_status()`: the job active and run
  by the role, the role able to log in, no failing refresh, the last run succeeded, no list waiting
  more than 15 s, and no session other than the runner holding 71046 (a worker `CALL` that stops on an
  error keeps the lock for the rest of its session; the procedure cannot release it on an error). `public.get_list_freshness()` gives the app the same per list.
- SQL tests run in one transaction and cannot call a procedure that commits; they call
  `warehouse_security.refresh_dirty_lists()`, the same claim, refresh and record steps in the caller's
  transaction.
