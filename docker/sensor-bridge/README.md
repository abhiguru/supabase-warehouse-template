# Sensor bridge (Tapo hubs to the warehouse backend)

A small container that reads the temperature and humidity sensors (Tapo T310/T315 and
the like) paired to one or more Tapo hubs (H100, H200) on the facility's network, and
posts their readings to this backend's `ingest-sensor-readings` edge function. It talks to
the hubs with [python-kasa](https://github.com/python-kasa/python-kasa) 0.11.0.1 over the
local network; nothing goes through the Tapo cloud.

**Licence.** python-kasa is GPL-3.0, so everything in this folder is
GPL-3.0-or-later ([LICENSE](LICENSE)). The rest of the repository stays MIT.

## What it does

1. Every `SENSOR_BRIDGE_POLL_SECONDS` (300) it asks each hub for its sensors.
2. For each sensor it compares temperature, humidity and the battery-low flag with what it
   last sent. A difference is a **change** and is queued at once. A sensor that has not
   changed for `SENSOR_BRIDGE_HEARTBEAT_SECONDS` (300) is queued once as a **heartbeat**
   with its current values, so the backend knows it is alive. Anything else is not sent.
   With both at their default of 300, every poll queues one reading per sensor (a change
   or a heartbeat): each sensor is **sampled every 5 minutes**, one row per 5 minutes. A
   poll starts 300 s after the previous one began plus up to a second of loop time, so
   samples are about 5 minutes apart, not on the clock's 5-minute marks.
   What was last sent is kept on disk, so a restart sends nothing new until a value
   changes or a heartbeat falls due.
3. The queue (SQLite in `/data`) is posted every `SENSOR_BRIDGE_POST_SECONDS` (60), at
   most `SENSOR_BRIDGE_MAX_BATCH` (200) readings per request, oldest first. A reading
   leaves the queue only when the backend answered 200. Readings are identified by
   (sensor, `measured_at`), as in the backend, so a resend is stored once.
4. The hub's own status (`online`, firmware) travels with every request and is also sent
   alone when it changes and every heartbeat interval.

### `measured_at`

A hub reports a sensor's current values but not when the sensor sent them. `measured_at`
is therefore the time **the bridge observed** the values (its own clock, UTC, ISO-8601
with `Z`, whole seconds). With the 5-minute poll it is at most about 5 minutes plus the
sensor's report interval after the real change; set a shorter `SENSOR_BRIDGE_POLL_SECONDS`
(with the heartbeat at 300) to catch changes sooner at the cost of more rows. Keep the
host's clock synchronised (NTP): the backend refuses readings more than 5 minutes in the
future or older than 30 days.

### Heartbeats and stale sensors

- A sensor that does not change still produces one reading every 5 minutes (heartbeat).
- The backend marks a sensor **stale** when its last reading is older than the device's
  `staleness_threshold_minutes` (30 by default), that is after about six missed 5-minute
  samples, so a bridge restart or one or two failed polls do not flag it:
  the sensor's battery died, it lost its hub, or the bridge or the hub is down.
- A sensor the hub reports as **offline** (its `status` is `offline`: the hub cannot hear it
  and only holds its last cached values) is **not posted at all**, neither as a change nor
  as a heartbeat. Its last reading therefore ages, and after the staleness threshold the
  app shows "No recent data" (this holds only for a sensor the backend already knows). A
  sensor that is offline the first time the bridge sees it (a new install, a fresh `/data`,
  a newly paired sensor) is never posted, so the backend never registers it and the app does
  not list it until it first reports online. When the hub reports it online again it is handled as
  usual: a changed value is sent at once, an unchanged one as a heartbeat once the
  heartbeat interval has passed since the last value sent. A sensor whose firmware reports
  no `status` is treated as online.
- A hub that fails three polls (or connections) in a row is reported `online=false` (with
  the 5-minute poll, about 10 minutes after the first failed poll), and
  that status is repeated every heartbeat interval while it lasts; the app shows its
  sensors as offline. Readings already queued are kept and still delivered.

### Hub states

| State | Meaning | Next |
|---|---|---|
| DISCONNECTED | not connected yet | connect and poll; on failure retry after 5 s, 10 s, 20 s ... up to 5 min |
| POLLING | connected | poll every `POLL_SECONDS`; a failed poll is retried on the same connection |
| OFFLINE | 3 failures in a row | `online=false` sent; reconnect with the same backoff; `online=true` sent when it works |
| REBOOTING | rebooted on `SENSOR_BRIDGE_REBOOT_CRON` | reconnect after 2 min; failures in the first 5 min do not count |

### A hub that moves to another address

Reserve each hub's address on the router (docs/SENSORS.md in the stack); if one moves anyway, the
bridge finds it. While a hub is OFFLINE, at most every `SENSOR_BRIDGE_RELOCATE_SECONDS`, its entry asks the
bridge's locator for a sweep of `SENSOR_BRIDGE_SCAN` (at most 1024 addresses in all). The sweep is a background
task: the other hubs, the delivery and the health file carry on while it runs, and the entry reads the result on
a later step. It makes a TCP connect to port 443 of every address (32 at a time, 1 s each), then a hub login
with the Tapo account at each address that answers (8 at a time, 8 s each) to read the device's id, model and
sensors. One sweep runs at a time and its result (kept 60 s) serves every hub that moved together.

- **What a probe sends.** Only the hub login's challenge exchange; the sweep's transport refuses python-kasa's
  "less secure" fallback, which would send an MD5 hash of the password to whatever listens on 443. The account
  e-mail is still sent, inside TLS that does not check the certificate, to every host that answers on the
  scanned networks; narrow `SENSOR_BRIDGE_SCAN` to limit that. An address whose login is refused is skipped for
  the next 6 sweeps.
- **Matching.** A hub is matched by the id the bridge learned, and only a Tapo H100/H200 counts. A hub that was
  never reached claims a hub only if it is an H100/H200 that logs in, reports at least one temperature or
  humidity sensor, and no other entry follows it; a claim is logged as a warning. A device without an id is an
  error, never known by its address. Two entries never follow one hub id (a duplicate stored id is dropped from
  the later entry at start) and an entry never points at an address another entry is polling.
- **On a match** the log says `event=hub_moved hub=<id> old=<address> new=<address>` (`claimed=true` for a claim),
  the move is stored in the state volume (`host_of:<id>`, used at the next start only while the sweep is on) and
  the backend's hub row follows the new address. The queued readings are kept. Two hubs that swapped addresses
  are sorted out the same way.
- **Another hub at the address.** With the sweep on, a configured address that answers with a different hub is a
  failed poll (so the search runs), not a replacement. A replacement is adopted only at the configured address
  and only after a sweep did not find the old hub anywhere. With `SENSOR_BRIDGE_SCAN=off` the answering hub is
  adopted at once, as before this feature.
- **A dead stored address.** If the address restored at start is offline, the entry tries its configured address
  while the sweep runs.
- **Undo a claim.** Stop the bridge and run `--forget-hub <address>` (below).

The sweep uses no broadcast, so it works in Docker's bridge network and under WSL2. `--once` does not search
(it makes one pass), and `--dump` always connects to the configured addresses, not to a stored move.

### Delivery

| Answer | What the bridge does |
|---|---|
| 200 | removes the readings from the queue |
| 401 (key refused or revoked) | keeps everything, waits 5 minutes before the next request |
| other 4xx (400 invalid batch) | keeps the batch for 3 tries in all, then drops it and logs `post_refused ... dropped=N` |
| 5xx, 408, 429, network error, timeout (20 s) | keeps everything, retries after 15 s, doubling up to 10 min |

Redirects are not followed (the key goes to the configured URL only). Readings older
than 29 days are dropped from the queue, and it never holds more than 200,000.

## Settings (environment)

| Variable | Default | |
|---|---|---|
| `SENSOR_BRIDGE_HUBS` | (required) | hub addresses, comma-separated, e.g. `192.0.2.10,192.0.2.11`; give each hub a fixed address (DHCP reservation) |
| `TAPO_USERNAME`, `TAPO_PASSWORD` | (required) | the Tapo account the hubs belong to |
| `SENSOR_INGEST_URL` | (required) | `https://<backend>/functions/v1/ingest-sensor-readings`; inside the warehouse stack `http://gateway:8000/functions/v1/ingest-sensor-readings` |
| `SENSOR_INGEST_KEY` | (required) | 64 lowercase hex characters, minted with `scripts/sensor-ingest-key.sql` |
| `SENSOR_BRIDGE_ID` | `sensor-bridge` | names this bridge in the backend's hub table |
| `SENSOR_BRIDGE_POLL_SECONDS` | `300` | 5 to 3600 |
| `SENSOR_BRIDGE_POST_SECONDS` | `60` | 5 to 3600 |
| `SENSOR_BRIDGE_HEARTBEAT_SECONDS` | `300` | 60 to 86400 |
| `SENSOR_BRIDGE_MAX_BATCH` | `200` | readings per request, 1 to 500 |
| `SENSOR_BRIDGE_REBOOT_CRON` | (off) | reboot every hub on this schedule, five cron fields **in UTC**, minute and hour as single numbers; `30 21 * * 6` is Sunday 03:00 in India |
| `SENSOR_BRIDGE_SCAN` | the /24 of each hub address | where to look for a hub that moved to another address: comma-separated private (RFC 1918) CIDR networks of /22 or smaller, or `off`; at most 1024 addresses in all; hubs given by name or at a non-private address add nothing |
| `SENSOR_BRIDGE_RELOCATE_SECONDS` | `600` | an OFFLINE hub asks for a sweep at most this often, 60 to 86400 |
| `SENSOR_BRIDGE_QUEUE_PATH` | `/data/bridge.sqlite3` | queue and sent-state |
| `SENSOR_BRIDGE_HEALTH_PATH` | `/data/health.json` | rewritten every second, whatever the poll interval |
| `SENSOR_BRIDGE_HEALTH_MAX_AGE` | `120` | seconds; the HEALTHCHECK fails beyond it |
| `SENSOR_BRIDGE_LOG_LEVEL` | `INFO` | `DEBUG` also shows python-kasa's own messages |

When a required setting is missing or a value is invalid the bridge logs
`event=config_error` with the variable's name (never its value) and exits with **78**, so
a container without settings stops instead of restarting in a loop.

## Commands

The image's entrypoint passes options to the bridge and runs any other command as given.

```sh
docker run --rm --env-file sensor-bridge.env IMAGE --check-config   # validate, print settings without secrets
docker run --rm --env-file sensor-bridge.env -v sensor-bridge-data:/data IMAGE --forget-hub 192.0.2.10   # undo what was learned for one entry
docker run --rm --env-file sensor-bridge.env IMAGE --once --dump    # print what each hub reports; sends nothing
docker run --rm --env-file sensor-bridge.env -v sensor-bridge-data:/data IMAGE --once   # one poll, one post
docker run --rm --network none IMAGE python -m unittest discover -s tests   # unit tests, no hub needed
```

- `--dump` connects to every hub and prints, per sensor, its id, name, model, values,
  battery, signal, report interval, its `status` exactly as the hub sends it (any string, for example `online` or
  `offline`; null only when it is missing or not text), and the **names** of the fields the hub reports and
  the modules python-kasa found (not their raw values). It needs no backend settings and
  stores nothing. Exit 0 when every hub answered.
- `--once` polls each hub once, posts what is due and exits 0 when every hub answered and
  the queue is empty. Run twice in a row, the second run sends nothing (`posts=0`): the
  change detector is kept in `/data`. The backend counts a reading as a duplicate only
  when the bridge re-sends a batch whose answer it did not get (a timeout or a lost 200).
- `--once --dump` is the same as `--dump`.
- No option: run until stopped (`SIGTERM`).

Logs go to standard error, one line per event (`event=hub_online`, `readings`, `post_ok`,
`post_failed`, `post_refused`, `auth_refused`, `hub_error`, `hub_offline`,
`offline_heartbeat`, `sensor_offline` / `sensor_online` (a sensor the hub reports offline
is not posted; each change is logged once per process, so after a restart `sensor_offline` is logged again for each sensor still offline), `hub_reboot`, ...). The password, the key and the URL's query are
never written; every line is also filtered for them.

## Standalone run (outside the warehouse stack)

For a bridge on its own host or VM, next to the hubs: the one description is in
[docs/SENSORS.md](../../docs/SENSORS.md#run-it-as-its-own-compose-project) (mint and revoke a key, copy
`docker-compose.standalone.yml` and `sensor-bridge.env.example`, check, post once, start). The queue lives in the volume
`sensor-bridge_data`.

## Image

`python:3.15-slim-bookworm` pinned by digest; dependencies pinned in `requirements.txt` and
installed from wheels only; runs as uid 10001 with `/data` as its only writable place;
HEALTHCHECK `python -m sensor_bridge.health` (the health file is younger than 120 s).

## Not verified here

The unit tests use a fake hub and a fake backend. The hub protocol itself (python-kasa
against a real H200 with this login) is only proven by a run against real hubs.
