# Troubleshooting

Every command below acts on **one installation**: the one whose state directory
you export. Run them from the installed backend checkout:

```bash
cd /path/to/installed/backend
export WAREHOUSE_STATE_DIR=/absolute/path/to/this/warehouse
bash scripts/compose.sh ps
```

`scripts/compose.sh` selects this installation's Compose project
(`warehouse-<instance>`, containers `warehouse-<instance>-<service>-1`) from
`WAREHOUSE_STATE_DIR` and refuses a running project that another checkout owns.
Name services (`db`, `kong`, `rest`, `functions`, `pdf-renderer`, `cups`), never
containers: do not run `docker logs`, `docker exec` or `docker restart` with a
fixed container name such as `supabase-kong`. On a host that also runs a
separate Supabase deployment or a second installation, such a name belongs to
that other project, and the command changes it instead of this one.

`node scripts/doctor.mjs --local` is the health verdict for this installation;
`node scripts/doctor.mjs` adds the external checks through the tunnel
([OPERATOR_INSTALL.md](OPERATOR_INSTALL.md#ordinary-operation)).

## Services won't start

```bash
bash scripts/compose.sh ps
bash scripts/compose.sh logs --tail 100 db kong rest
node scripts/doctor.mjs --local
```

`ps` shows every service `Up (healthy)` except `rest`, which has no healthcheck
and shows plain `Up`. A service that keeps restarting shows `Restarting`; its
last log lines say why. `bash start.sh` starts the core services again and
replaces the running optional ones.

## The API answers 502 or 503

```bash
bash scripts/compose.sh logs --tail 50 kong
bash scripts/compose.sh logs --tail 50 rest
bash scripts/compose.sh restart kong
```

A 502 from the gateway usually means the service behind it (`rest`,
`functions`, `storage`) is down or restarting. The printing routes
(`print-grn-preprinted`, `print-dispatch-preprinted`, `print-invoice-preprinted`,
`print-via-ipp`, `get-printer-status`) answer 503 "Printing is not configured
for this operator instance" **by design** (`functions/main/index.ts`): that 503
is not a fault ([PRINTING.md](PRINTING.md)).

## Database connection issues

```bash
bash scripts/compose.sh exec -T db pg_isready -U postgres
bash scripts/compose.sh exec -T db psql -X -U supabase_admin -d postgres \
  -c "SELECT backend_type, state, count(*) FROM pg_stat_activity GROUP BY 1, 2 ORDER BY 3 DESC;"
bash scripts/compose.sh exec -T db psql -X -U supabase_admin -d postgres -c "
  SELECT pid, now() - query_start AS duration, left(query, 120) AS query
  FROM pg_stat_activity
  WHERE state <> 'idle' AND backend_type = 'client backend'
  ORDER BY duration DESC
  LIMIT 5;"
```

The `db_connections_high` alert counts client connections (not background
workers) against the configured ceiling of 100 ([MONITORING.md](MONITORING.md)).

## Edge functions not working

```bash
bash scripts/compose.sh logs --tail 50 functions
bash scripts/compose.sh exec -T functions ls /home/deno/functions/
bash scripts/compose.sh restart functions
```

The functions are mounted read-only from the checkout's `functions/`
directory. When an upgrade changed only that code, the container itself is
unchanged and is not recreated, so restart `functions` after the upgrade
([OPERATOR_INSTALL.md](OPERATOR_INSTALL.md#rerun-and-upgrade)) for the workers
to load the new code.

## Slow API responses

```bash
ids=$(bash scripts/compose.sh ps -q); [ -n "$ids" ] && docker stats --no-stream $ids
bash scripts/compose.sh ps
bash scripts/compose.sh logs rest 2>&1 | grep -i pool
```

`docker stats` here receives this installation's container IDs only, and is
skipped when none is running: given no IDs it would list every container on
the host. A service shown as `Restarting` in `ps` is in a crash loop; read its
logs.

## A new receipt, dispatch or invoice is missing from a list

The lists read the tables (migration 106), so a document that the app said was saved is in the next list read.
If a list does not show it, check the filter and sort on the screen (a date range, a customer, a search word) and
pull to refresh. A document missing from every list and from its own detail screen was not saved: look at the
app's last error. Before migration 106 a background job refreshed some lists; if `setup.sh` has not been rerun
since, run it, so that the database is on the current migrations.

## Printer not responding

Printing is an optional profile (`printing`):

```bash
bash scripts/compose.sh --profile printing ps cups
bash scripts/compose.sh --profile printing logs --tail 50 cups
bash scripts/compose.sh --profile printing exec -T cups lpstat -p
bash scripts/compose.sh --profile printing exec -T cups curl -f http://localhost:631/
```

Setup, the printer queue and the 503 answer of the print routes are described
in [PRINTING.md](PRINTING.md).

## Sensors show no data

Sensors are an optional profile (`sensors`); the bridge polls the Tapo hubs
and posts to the `ingest-sensor-readings` function:

```bash
bash scripts/compose.sh --profile sensors ps sensor-bridge
bash scripts/compose.sh --profile sensors logs --tail 100 sensor-bridge
bash scripts/compose.sh --profile sensors run --rm sensor-bridge --check-config
bash scripts/compose.sh --profile sensors run --rm sensor-bridge --once --dump
```

The log has one line per event (`event=config_error`, `auth_refused`,
`hub_offline`, `post_failed`, ...) and never the password or the key. Exit
code 78 means a missing or invalid variable; a 401 means the ingest key is
wrong or revoked. When the app has no Sensors screen at all, the `sensors`
capability is off or the `functions` service was not restarted after
`set-capability`. Details: [SENSORS.md](SENSORS.md#troubleshooting).

## PDF generation fails

```bash
bash scripts/compose.sh exec -T pdf-renderer node -e "fetch('http://localhost:3000/health').then(async r=>{console.log(r.status,await r.text());process.exit(r.ok?0:1)})"
bash scripts/compose.sh logs --tail 50 pdf-renderer
bash scripts/compose.sh restart pdf-renderer   # also clears Chromium's memory
```

The image has no `curl` or `wget`; use `node -e` inside the renderer as above.
The health answer is `{"status":"up","chromium":{...}}` with `memoryMB` (Chrome's resident memory) and `containerMB` (the container's working set against its 1.5 GiB limit) (or `"restarting"` for a few seconds
during a planned browser restart); `503 {"status":"down"}` means the browser
did not answer twice in a row; it is killed and relaunched after five failed probes, and the process exits (so Docker
restarts the container) only after five failed launches in a row. The log has
one JSON line per render with `outcome` and `code` (400 invalid input, 413 body
too large, 503 queue full or browser restarting, 504 deadline). The renderer
sits on the internal `renderer` network, so `storage` and `kong` cannot reach
it; only `functions` can.

## Restore or recover (there is no reset)

There is no command that wipes an installation and starts over, and none is
needed for a repair: the database and stored objects live in
`$WAREHOUSE_STATE_DIR/data`, next to the installation's configuration, and
setup never deletes them. Use the documented paths in
[OPERATOR_INSTALL.md](OPERATOR_INSTALL.md):

- the database or stored objects are damaged, or data must be rolled back:
  [In-place restore of the same instance](OPERATOR_INSTALL.md#in-place-restore-of-the-same-instance)
  (`npm run db:restore` from a signed backup; the replaced data is kept beside
  it until you remove it);
- the host is gone and only the USB drive is left:
  [Recover a lost host from the USB drive](OPERATOR_INSTALL.md#recover-a-lost-host-from-the-usb-drive);
- the configuration or images look wrong after an upgrade:
  [Rerun and upgrade](OPERATOR_INSTALL.md#rerun-and-upgrade) (the same
  `setup.sh --operator ...` command with the same inputs; it regenerates nothing
  that exists);
- a new, empty installation: a new state directory and
  [Setup](OPERATOR_INSTALL.md#setup), not a deletion of an existing one.

Take `npm run db:backup` before any of these.

## Monitoring and Slack alerts

- **No "Monitoring is alive" message today, or `npm run doctor` warns about the checker.** The checker is a systemd timer
  that setup cannot install for you. Check `bash scripts/watch-timer.sh status`; if it is not installed, run
  `sudo bash scripts/watch-timer.sh install --state "$WAREHOUSE_STATE_DIR"`. If it is installed, read
  `journalctl -u warehouse-<state name>-watch.service` and `node scripts/watch.mjs status` (the last Slack failure is
  shown there); `node scripts/watch.mjs test-message` posts a test message to the stored webhook.
- **Alerts for services you stopped on purpose.** Mute before a planned stop: `node scripts/watch.mjs mute 60`
  ([MONITORING.md](MONITORING.md)).
- **Nothing reaches Slack, but the checker runs.** `status` says `Slack webhook: none` when the install was made with
  `--alert-webhook-file off`; rerun `setup.sh --operator` with your usual inputs and the webhook.
