# Tapo temperature and humidity sensors

Sensor readings reach this backend through a small bridge container that polls
the facility's Tapo hubs on the local network and posts what it sees to the
`ingest-sensor-readings` function. The app reads the result from the database
(`sensor_status`, history RPCs) and re-reads it on a timer
(`sensor_latest`; there is no live push). The `sensors` capability in the public manifest is off by
default; the app shows the Sensors screen only where it is on.

Built and tested without hardware so far: the bridge's unit tests, the image
check (`npm run test:sensors`), the function's handler tests and the database
tests (`tests/sensor_ingest.sql`). A run against real hubs, the heartbeat
interval against real T310 reporting and the app's timed re-read on a staff phone are
recorded separately before anyone is told the screen works.

## The hardware

- **Hubs:** Tapo H200 (the H100 belongs to the same device family). The sensors
  are children of a hub; the bridge never talks to a sensor directly.
- **Sensors:** Tapo T310 (temperature and humidity). A sensor reports to its hub
  on its own schedule; the hub keeps the latest values, battery-low flag,
  signal level and report interval of each child.
- **Login:** the hub accepts the Tapo account (e-mail and password) it was set
  up with, checked locally (python-kasa: `SmartTapoHub` family, AES transport,
  login version 3, HTTPS). No Tapo cloud call is made.
- **No reading time:** the hub exposes the current values but not when the
  sensor reported them. `measured_at` is therefore the time **the bridge
  observed** a value (UTC), not the sensor's own time.
- Each sensor is identified by its hub child id (`external_id`, 40 hex
  characters), each hub by its device id (`hub_id`). Names are set from the hub
  on the first reading only; a rename in this backend survives later readings.

## How a reading travels

```
 T310 ──▶ H200 hub ◀── poll every 5 min ─ sensor-bridge ── post every 60 s ──▶ gateway ──▶ ingest-sensor-readings
                                          (queue in /data)                          │ service key
                                                                                    ▼
                         sensor_readings (history) ◀── record_sensor_batch ──▶ sensor_latest ◀── app re-reads
                                                                          └──▶ sensor_hubs
```

- **Sampled every 5 minutes.** The bridge polls each hub every 5 minutes
  (`SENSOR_BRIDGE_POLL_SECONDS=300`) and queues a reading when a value changes,
  the battery flag flips, or 5 minutes (`SENSOR_BRIDGE_HEARTBEAT_SECONDS=300`)
  have passed since the last one for that sensor. With both at 300 every poll
  queues one reading per sensor, a change or a heartbeat, so each sensor has
  one row per 5 minutes (about 288 a day, about 26,000 in the 90 days kept). A
  heartbeat carries the unchanged values (`kind: "heartbeat"`) and is stored as
  a reading. Polls are about 5 minutes apart, not on the clock's 5-minute
  marks. Its change detector is stored in the volume, so a restart sends
  nothing new until the next sample falls due.
- **Stale.** A sensor is stale when `last_seen_at` is older than its
  `staleness_threshold_minutes`: 30 minutes by default, about six missed
  5-minute samples, so a restart or a failed poll or two does not flag it.
  `sensor_status` computes `stale` and `values_stale` at read time; nothing is
  written when a sensor goes quiet, so the app recomputes it from the clock.
- **Temperature limits.** An administrator sets a lowest and a highest temperature
  per sensor (`update_sensor_device`, parameters `p_temperature_min`,
  `p_temperature_max`, written only when `p_set_temperature_limits` is true; stored in
  `sensor_devices.alert_config`). `sensor_status`, `get_sensor_device` and
  `get_sensor_polling_data` then carry `temperature_alert`: `HIGH` above the highest,
  `LOW` below the lowest, null otherwise. No flag while the hub is offline or the
  temperature (`temperature_at`) is older than the sensor's staleness threshold.
- **Hub offline.** After three failed polls of a hub (about 10 minutes with the
  5-minute poll) the bridge sends heartbeats
  with `online=false` for it and keeps reconnecting with backoff; the app shows
  its sensors as OFFLINE.
- **Delivery.** Readings wait in an SQLite queue (`/data/bridge.sqlite3` in the
  `sensor-bridge-data` volume) until the function accepts them. A network
  error or a 5xx is retried with backoff from 15 seconds to 10 minutes; a 401
  pauses posting for 5 minutes; any other 4xx is dropped after three tries.
  Sending a batch twice is harmless: `(device_id, measured_at)` is unique.
  Duplicates appear only when the bridge re-sends a batch whose answer it did
  not get (a timeout or a lost 200); a bridge that runs normally reports
  `duplicates=0`.
- **Retention.** `sensor_readings` older than 90 days (3 months) are removed by the database retention job (key
  `sensor_readings`, `npm run retention:preview`, deleted at the next
  `retention:apply`).

## The ingest contract

`POST /functions/v1/ingest-sensor-readings` with
`Authorization: Bearer <ingest key>` (64 hex characters; not a Supabase JWT,
and no `apikey` header is needed). Body at most 256 KiB and 500 readings:

```json
{
  "bridge": { "id": "sensor-bridge", "version": "1.0.0" },
  "hub": { "id": "<hub device id>", "host": "192.0.2.74", "online": true, "firmware": "1.2.3" },
  "readings": [
    { "external_id": "<40 hex>", "name": "TH2", "model": "T310", "kind": "change",
      "temperature": 3.4, "humidity": 61, "measured_at": "2026-10-13T08:15:30Z",
      "battery_low": false, "battery_percent": null, "signal_level": 3, "report_interval_s": 16 }
  ]
}
```

`temperature` (-50 to 80 °C) and `humidity` (0 to 100 %) may each be null, not
both; a value that is null keeps the previous value and its age in
`sensor_latest` (`temperature_at`, `humidity_at`). `kind` is `change` or
`heartbeat`. `measured_at` must lie
within the last 30 days and at most 5 minutes ahead. A reading out of range is
counted in `rejected` and the rest of the batch is stored.

| Answer | When |
| --- | --- |
| 200 `{ success: true, accepted, duplicates, rejected, devices }` | the batch was read; each reading is accepted, a duplicate, or rejected with a reason |
| 400 `Invalid request` | not JSON, too large, more than 500 readings, or a malformed hub |
| 401 `Unauthorized` | no bearer, not 64 hex (no database call is made), or a wrong or revoked key |
| 405 | any method but POST |
| 503 `Ingestion unavailable` | the function or the database cannot take the batch now (retry) |

Every answer carries `Cache-Control: no-store`; the key is never logged or
echoed. The gateway limits the functions route to 100 requests a minute per
client address; one bridge posts once a minute per hub.

## Ingest keys

A key belongs to one bridge and opens nothing but this function: the database
stores its SHA-256 only (`warehouse_security.sensor_ingest_keys`, readable by
no API role). Mint one on the installation, as the installation user:

```bash
cd /path/to/installed/backend
export WAREHOUSE_STATE_DIR=/absolute/path/to/this/warehouse
bash scripts/compose.sh exec -T db psql -X -qAt -v ON_ERROR_STOP=1 -U supabase_admin -d postgres \
  -v label=main-bridge < scripts/sensor-ingest-key.sql
```

The script is read from standard input (`-f` would look for it inside the
database container). `label` names the bridge (1 to 64 letters, digits,
spaces, dots, underscores or hyphens) and is required. It prints the key
**once**, as the only line of output. Put it straight into `SENSOR_INGEST_KEY` (below);
do not paste it into a chat, a ticket or a shared document. To revoke a key
(the bridge then gets 401 and pauses), and to see which keys exist:

```bash
bash scripts/compose.sh exec -T db psql -X -q -v ON_ERROR_STOP=1 -U supabase_admin -d postgres \
  -c "UPDATE warehouse_security.sensor_ingest_keys SET revoked_at = now() WHERE label = 'main-bridge' AND revoked_at IS NULL"
bash scripts/compose.sh exec -T db psql -X -q -v ON_ERROR_STOP=1 -U supabase_admin -d postgres \
  -c "SELECT label, created_at, last_used_at, revoked_at FROM warehouse_security.sensor_ingest_keys ORDER BY created_at"
```

To replace a key: mint a new one under a new label (`main-bridge-2`; the
UPDATE above revokes every key of a label), put it in the bridge's
configuration, recreate the bridge, then revoke the old label.

## Run it as a profile of the installation

The bridge is the optional Compose service `sensor-bridge` (profile `sensors`,
image `<project>-sensor-bridge` built from `docker/sensor-bridge/`). It is on
the `default` network only: it calls the gateway at
`http://gateway:8000/functions/v1/ingest-sensor-readings` and cannot reach the
database. It needs the hubs' LAN addresses to be
reachable from the host (on a Windows host, see
[Sensors (Windows)](OPERATOR_INSTALL.md#sensors-windows)). `setup.sh` and `start.sh` start the core services
only; once a bridge container exists they replace it when its image or
configuration changed, and `stop.sh` stops it with everything else.

1. **Mint a key** (above).
2. **Configure.** Set these lines in `$WAREHOUSE_STATE_DIR/config/compose.env`
   (setup writes them empty). Keep the file mode 0600.

   | Variable | Value |
   | --- | --- |
   | `SENSOR_BRIDGE_HUBS` | hub addresses, comma-separated: `192.0.2.74,192.0.2.79` |
   | `TAPO_USERNAME`, `TAPO_PASSWORD` | the Tapo account the hubs were set up with |
   | `SENSOR_INGEST_KEY` | the key from step 1 |
   | `SENSOR_BRIDGE_ID` | optional name shown in `sensor_hubs.bridge_id` (default `sensor-bridge`) |
   | `SENSOR_BRIDGE_POLL_SECONDS`, `_POST_SECONDS`, `_HEARTBEAT_SECONDS`, `_MAX_BATCH`, `_LOG_LEVEL` | optional: 300, 60, 300, 200, INFO (poll and heartbeat 300: sampled every 5 minutes) |
   | `SENSOR_BRIDGE_REBOOT_CRON` | optional five-field cron in UTC for a hub reboot, e.g. `30 21 * * 6` (Saturday 21:30 UTC, Sunday 03:00 IST); empty = never |

   Compose reads this file with variable substitution: a password that
   contains `$`, a quote, or a space followed by `#` goes in single quotes
   (`TAPO_PASSWORD='p$ss#word'`), which Compose takes literally.
3. **Look before posting.** `--dump` connects to every hub and prints what it
   reports (ids, values, battery, report interval; no secret), storing and
   sending nothing (`--once --dump` is the same as `--dump`); `--once` polls
   and posts once, and a second `--once` straight after it posts nothing,
   because the change detector already holds every value:

   ```bash
   bash scripts/compose.sh --profile sensors run --rm sensor-bridge --check-config
   bash scripts/compose.sh --profile sensors run --rm sensor-bridge --once --dump
   bash scripts/compose.sh --profile sensors run --rm sensor-bridge --once
   bash scripts/compose.sh --profile sensors run --rm sensor-bridge --once   # again at once: event=once ... posts=0 (nothing changed)
   ```

4. **Start it:** `bash scripts/compose.sh --profile sensors up -d --wait sensor-bridge`.
   The first start builds the image (network needed).
5. **Turn the capability on**, so the app shows the screen, and restart the
   function runtime (the manifest is mounted as a file; a running container
   keeps the old one):

   ```bash
   node scripts/set-capability.mjs sensors on
   bash scripts/compose.sh restart functions
   ```

6. **Check that readings arrive.** Wait about 20 minutes, then run
   `node scripts/doctor.mjs --local`. While the capability is on it warns, for example
   `Sensors: hub 192.0.2.10 offline for 5 days; newest reading 5 days ago (limit 16 minutes)`, when
   no hub has reported, a hub is offline (the warning says for how long) or silent (online, but the bridge has not posted for it),
   or no reading is newer than the limit. The limit is three times the larger of `SENSOR_BRIDGE_HEARTBEAT_SECONDS` and
   `SENSOR_BRIDGE_POLL_SECONDS` plus `SENSOR_BRIDGE_POST_SECONDS`: 16 minutes with the defaults (300, 300, 60). When
   `SENSOR_BRIDGE_HUBS` is set in `compose.env` it also warns that no `sensor-bridge` container exists (an existing container that
   is stopped or unhealthy is reported by the health check). It is a warning only and never stops a setup or upgrade. The 5-minute
   checker judges the same things and sends the alert `sensors_stale` to Slack (after two failing runs in a row, not in the first
   16 minutes after a start), so a bridge that polls dead addresses is noticed without anyone running the doctor. The cause
   is usually a hub whose address changed ([Troubleshooting](TROUBLESHOOTING.md#sensors-show-no-data)).
7. **Take a backup:** `npm run db:backup`. `db:restore` refuses a backup whose
   `instance.json` or `compose.env` differs from the state, so a backup taken
   before steps 2 and 5 can be restored only with `db:restore-host` (or with
   `--restore-config`, which brings back the old configuration).

To turn sensors off: `node scripts/set-capability.mjs sensors off`, restart
`functions`, `bash scripts/compose.sh --profile sensors rm -sf sensor-bridge`,
revoke the key, and take a backup. Stored readings stay.

## Run it as its own Compose project

The same image runs on any Docker host on the hubs' network, posting to the
installation's public address through the tunnel. Run only one bridge per hub:
two bridges would each send their own observation times.

1. **Mint a key** on the installation the bridge posts to (as in
   [Ingest keys](#ingest-keys), on that installation's host), and keep it for
   step 3 only.
2. **Make a private folder** from `docker/sensor-bridge/` of this repository:

   ```bash
   mkdir -p ~/sensor-bridge && cd ~/sensor-bridge
   cp /path/to/repo/docker/sensor-bridge/docker-compose.standalone.yml docker-compose.yml
   cp /path/to/repo/docker/sensor-bridge/sensor-bridge.env.example sensor-bridge.env
   chmod 600 sensor-bridge.env
   echo "SENSOR_BRIDGE_SOURCE=/path/to/repo/docker/sensor-bridge" > .env
   ```

3. **Configure** `sensor-bridge.env` with an editor: `SENSOR_BRIDGE_HUBS`,
   `TAPO_USERNAME`, `TAPO_PASSWORD`, `SENSOR_INGEST_KEY` (step 1) and
   `SENSOR_INGEST_URL=https://<facility origin>/functions/v1/ingest-sensor-readings`;
   the optional variables are those of the table above. As in `compose.env`, a
   password that contains `$`, a quote, or a space followed by `#` goes in
   single quotes.
4. **Look, post once, start:**

   ```bash
   docker compose build
   docker compose run --rm sensor-bridge --check-config
   docker compose run --rm sensor-bridge --once --dump
   docker compose run --rm sensor-bridge --once     # event=once hubs_ok=N/N posts=... accepted=...
   docker compose run --rm sensor-bridge --once     # again at once: posts=0
   docker compose up -d
   docker compose logs -f
   ```

   The queue and change detector live in the volume `sensor-bridge_data`;
   `docker compose down` keeps it, `down -v` deletes it with anything not yet
   delivered. `docker/sensor-bridge/README.md` describes every setting.

   The doctor judges this bridge by the data alone: keep `SENSOR_BRIDGE_HUBS` empty in the installation's `compose.env` (the
   container is checked only for the profile way above, where a missing one would otherwise be a false alarm). The doctor reads
   the limit from `compose.env`: copy a raised `SENSOR_BRIDGE_HEARTBEAT_SECONDS`, `_POLL_SECONDS` or `_POST_SECONDS` there too, or
   accept the 16 minute limit.

## What is in a backup

`compose.env`, and so every backup, holds `TAPO_PASSWORD` and
`SENSOR_INGEST_KEY`. Stored readings, `sensor_latest` and `sensor_hubs` are in
the database dump. The `sensor-bridge-data` volume (queue and change detector)
is not backed up, like the print spool: readings the bridge had not delivered
when a host was lost are lost; a restored host's bridge starts with an empty
queue and sends every sensor's current values once. `db:restore-host` keeps the
volume when one is left (it holds no database state).

## Troubleshooting

See [TROUBLESHOOTING.md](TROUBLESHOOTING.md#sensors-show-no-data). The Slack alert `sensors_stale` (docs/MONITORING.md) and the
warning of `node scripts/doctor.mjs --local` have the same causes; the doctor names each fault and the command to read the bridge log.

## Licence

`docker/sensor-bridge/` is licensed **GPL-3.0-or-later**
(`docker/sensor-bridge/LICENSE`) because it uses python-kasa (GPL-3.0). The
rest of this repository stays MIT: the bridge is a separate program that talks
to the backend over HTTP only. Distributing a built bridge image means offering
its complete source under the GPL; running it on your own premises does not.
See [THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md).
