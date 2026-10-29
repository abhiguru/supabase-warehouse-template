# Troubleshooting

This is the one place for fixing problems. Other guides link here.

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
Name services (`db`, `gateway`, `rest`, `storage`, `functions`, `pdf-renderer`, `cups`), never
containers: do not run `docker logs`, `docker exec` or `docker restart` with a
fixed container name such as `supabase-rest`. On a host that also runs a
separate Supabase deployment or a second installation, such a name belongs to
that other project, and the command changes it instead of this one.

`node scripts/doctor.mjs --local` is the health verdict for this installation;
`node scripts/doctor.mjs` adds the external checks through the tunnel
([OPERATOR_INSTALL.md](OPERATOR_INSTALL.md#ordinary-operation)).

For the five events most likely to hit a facility (internet down, power cut, disk full, SMS codes not arriving, a failed
backup) start with the [incident cards](#incident-cards) below.

## Incident cards

Five things that will happen. Each card is for the person at the host, not a database expert: what you see, what to do in
order, and what not to do. The commands run from the checkout with `WAREHOUSE_STATE_DIR` exported, as above.

### Internet down

**You see:** every phone says it cannot reach the server; no Slack message arrives (it cannot leave either);
`node scripts/doctor.mjs --local` still says healthy.

1. Do not restart anything on the host. The server is fine; the road to it is down.
2. Look at the router (lights; restart it once and wait three minutes). If a phone on mobile data cannot sign in either, the
   problem is the warehouse's line: call the internet provider.
3. From the host: `ping -c 3 1.1.1.1` (the line) and `ping -c 3 cloudflare.com` (name lookup). The first fails: the line. The
   second fails alone: the router's DNS (set `1.1.1.1` in the router).
4. When the line is back, wait two minutes. The tunnel reconnects by itself. Check `bash scripts/tunnel.sh status` and
   `node scripts/doctor.mjs`. If the public check still fails: `sudo systemctl restart warehouse-<state name>-tunnel.service`.
5. The app cannot save a receipt, dispatch or invoice meanwhile. Write them on paper and enter them afterwards in the order of
   the paper numbers; check the number the app suggests against the paper before saving. If the
   [LAN fallback](OPERATOR_INSTALL.md#lan-fallback-plain-http-on-the-warehouse-network) is on (`bash scripts/lan.sh status`) **and the
   phones have a version of the app that uses it (not released yet; until then it changes nothing for them)**, phones that are signed in
   and on the warehouse Wi-Fi switch to it after the public address fails and keep working; signing in still needs the internet, except
   for an administrator with a [break-glass code](OPERATOR_INSTALL.md#break-glass-administrator-sign-in). If they do not, see
   [the app says the LAN address is unreachable](#the-app-says-the-lan-address-is-unreachable).
6. Alerts that could not be sent are not sent later. After the outage run `node scripts/watch.mjs status`.

### Power cut

**You see:** the host was off or restarted; phones fail until it is back. After it is on again, most things return by
themselves (the host must be set to power on after a cut: the BIOS option "restore on AC power loss").

- **Comes back by itself:** Docker, the database (it repairs itself from its log; give it a minute), the gateway, the other
  services (the boot unit `<project>-stack.service`, installed by `watch-timer.sh install`; `bash scripts/watch-timer.sh status`
  shows it), the tunnel, the monitoring timers.
- **Needs you:** the host's power button if it stayed off. Then, after five minutes: `node scripts/doctor.mjs --local`. If it
  is not healthy, `bash start.sh`, and read `bash scripts/compose.sh ps` and `bash scripts/compose.sh logs --tail 50 db`.
- **If the cut came at night,** the backup may have been interrupted: `node scripts/watch.mjs status` shows the last backup. A
  folder `.warehouse-backup-staging.*` left in `$WAREHOUSE_STATE_DIR/backups` is from the interrupted run; delete it with
  `rm -rf` once `systemctl is-active <project>-daily.service` says `inactive` (`status` also shows a `Daily pass: running since`
  line while one is going on, or `marked running ... but cut short` after a cut). The next daily trigger notices the cut pass and
  makes a new backup at once.
- **A stack you stopped with `stop.sh` stays stopped through a power cut or a reboot** (`config/stopped-by-operator`): `status` and
  `doctor` say "stopped by the operator". Run `bash start.sh` when you want it back.
- Do not delete anything under `$WAREHOUSE_STATE_DIR/data`. Sign in on one phone and open the latest receipt to be sure.
- The cure is a UPS (a battery) that shuts the host down cleanly; without one every cut is a small risk to the database.

### Disk full

**You see:** Slack `disk_root_low` (under 20% free) weeks before; at 0% PostgreSQL stops and the app fails on every save.
Check: `df -h /`.

1. Never delete anything under `$WAREHOUSE_STATE_DIR/data` (the database and the photos) or `config`.
2. What is big: `du -sh "$WAREHOUSE_STATE_DIR"/{data,backups,images}` and `sudo du -xh --max-depth=2 /var/lib/docker | sort -h | tail`.
3. Free space in this order, until about 10 GiB is free:
   - Docker's build cache and untagged images (safe; never `-a`, never `--volumes`; on a host shared with other Docker
     projects they are affected too): `docker builder prune -f` and `docker image prune -f`.
   - Old local backups, keeping the newest three **and the newest verified one**, and only when the USB drive holds a recent
     archive. What one frees depends on its format: a `warehouse-backup-v5` backup (it has a `storage.tar.gz`) frees its whole
     photo archive, which is the big saving in the weeks after the update to v6; a `warehouse-backup-v6` backup shares its photos
     with the others, so it frees only its database dump and the photos no other backup holds (usually little). The newest verified
     backup (`config/backups-verified.list`) is the last one known to restore: never remove it.
     `newest=$(awk 'NF { print $1 }' "$WAREHOUSE_STATE_DIR/config/backups-verified.list" | sort | tail -n 1)`, then
     `ls -1d "$WAREHOUSE_STATE_DIR"/backups/warehouse-* | head -n -3 | grep -v "/$newest\$" | xargs -r rm -rf`.
     The USB drive keeps its own newest three archives and needs nothing from you.
   - The saved image tarballs, about 2.5 GiB, after copying them to the drive; they come back at the next build
     (`bash scripts/build-images.sh --save`): `rm -rf "$WAREHOUSE_STATE_DIR/images"`.
   - The system journal: `sudo journalctl --vacuum-size=200M`.
4. If the database stopped ("No space left on device" in `bash scripts/compose.sh logs --tail 50 db`): free space first, then
   `bash start.sh`. `start.sh` refuses only below 2 GiB free and warns below 10.
5. The lasting fix is a bigger disk. Photos are never deleted by the app and backups multiply them.

### SMS codes not arriving

**You see:** users say no code arrives. Slack `sms_delivery` (checked every hour: the provider refused requests or never answered) or
`api_429_rate_high` ("Too many OTP requests").

1. One number or everyone? One number: its limits are used up; clear them with `warehouse_security.reset_otp_limits`
   ([OPERATOR_INSTALL.md](OPERATOR_INSTALL.md#authentication-and-otp-limits)).
2. Everyone: ask the holder of the MSG91 account to open the console and check, in this order: the balance, the status of the
   flow (the DLT template must be approved), the sender ID (header), and the delivery report of one recent number.
3. What the server saw in the last day:
   `bash scripts/compose.sh exec -T db psql -X -U supabase_admin -d postgres -c "SELECT delivery_status, msg91_status, count(*) FROM public.otp_verifications WHERE created_at > now() - interval '24 hours' GROUP BY 1, 2 ORDER BY 3 DESC"`
   `accepted | success` means MSG91 took the request. `failed | provider_auth` is a wrong or expired key,
   `provider_rejected` or `provider_validation` a refused template or sender, `provider_rate_limited` too many requests,
   `provider_unavailable` or `provider_ambiguous` MSG91 did not answer.
4. All `accepted` and still nothing on the phones: the telecom operator is dropping the messages (a suspended DLT header or
   template). Only MSG91 support can fix that. A new key is applied as in
   [Replacing MSG91 credentials](OPERATOR_INSTALL.md#authentication-and-otp-limits).
5. Phones that are signed in keep working until their session ends; do not sign anyone out meanwhile.

### Backup failed

**You see:** Slack `backup_failed` or `backup_missing`. These two are never muted. Until it is fixed, the data since the last
good backup exists only on this disk.

1. Why: `node scripts/watch.mjs status` (the "Daily backup" line has the message) and
   `journalctl -u <project>-daily.service --since yesterday` (`bash scripts/watch-timer.sh status` names the unit).
2. The usual causes: the disk is full or too full for a backup (`Refusing: not enough free space`: see "backup refused" under
   Backup, USB drive and restore, and the Disk full card); a service the backup stops was down (`bash scripts/compose.sh ps`,
   then `bash start.sh`); another operator command still holds the lock (`status` says "operator lock is held"; find it with
   `fuser -v "$WAREHOUSE_STATE_DIR/config/operator.lock"` and let it finish); the database is not healthy.
3. Make one by hand to see the error. It stops the app for a few minutes, so do it when it is quiet:
   `npm run db:backup`, then `npm run db:verify-restore -- <the folder it printed>`. A good backup made by hand also clears
   both alerts.
4. After the cause is gone the daily timer tries again within the hour, up to three times a day; inside the window,
   `sudo systemctl start --no-block <project>-daily.service` does it now (`journalctl -u <project>-daily.service -f` shows it).
5. Copy the newest good backup to the USB drive (plug it in; [USB backup drive](OPERATOR_INSTALL.md#usb-backup-drive)).

## Services

### Services won't start

```bash
bash scripts/compose.sh ps
bash scripts/compose.sh logs --tail 100 db gateway rest
node scripts/doctor.mjs --local
```

`ps` shows every service `Up (healthy)` except `rest`, which has no healthcheck
and shows plain `Up`. A service that keeps restarting shows `Restarting`; its
last log lines say why. `bash start.sh` starts the core services again and
replaces the running optional ones. `bash health-check.sh` (a thin wrapper over
`node scripts/watch.mjs health`) fails only for the default services; an optional
one that is not running (sensors, printing, pooler) shows as a `warn` line.

### The API answers 502 or 503

```bash
bash scripts/compose.sh logs --tail 50 gateway
bash scripts/compose.sh logs --tail 50 rest
bash scripts/compose.sh restart gateway
```

A 502 from the gateway usually means the service behind it (`rest`,
`functions`, `storage`) is down or restarting. The printing routes
(`print-grn-preprinted`, `print-dispatch-preprinted`, `print-invoice-preprinted`,
`print-via-ipp`, `get-printer-status`) answer 503 "Printing is not configured
for this operator instance" **by design** (`functions/main/index.ts`): that 503
is not a fault ([PRINTING.md](PRINTING.md)).

A 503 whose body is `{"code":"upgrading","message":"The facility's server is being updated. Try again in a few minutes."}` (with
`Retry-After: 120`) is **maintenance mode**, not a fault: an upgrade is running, or stopped half way and left the API closed on purpose
(`bash scripts/maintenance.sh status` says which; Slack says `upgrade_interrupted` in the second case). While `upgrade.sh` runs, wait for it.
After it stopped, read what it printed, or `node scripts/upgrade-record.mjs report`: finish it with the same command, or go back, and
`bash scripts/maintenance.sh off` opens the API ([Rerun and upgrade](OPERATOR_INSTALL.md#rerun-and-upgrade), "While it upgrades"). Do not
open it to see whether the facility works if the upgrade is half done: the code may be the new release's on a schema that is only part migrated.

A 502 with `no live upstreams` or `... could not be resolved` in the gateway log names the
service behind the route that is down or was just replaced: the gateway looks the names up again every 5 seconds
(`resolver 127.0.0.11 valid=5s` in `docker/nginx/nginx.conf`) and finds the new container by itself, so the 502s stop
within about 10 seconds of the service answering; a gateway restart is not needed. The gateway asks Docker's resolver for the bare
service names and applies no search domain, so a host DHCP search domain cannot slow it down; do not change host DNS
or extend client timeouts.

A gateway that exits at start prints the reason as its last log line: `gateway: ANON_KEY is not set` (or
`SERVICE_ROLE_KEY`, `CORS_ALLOWED_ORIGIN`) or `... has a character that is not allowed` means `compose.env` holds an empty or odd
value (a key is letters, digits and `. _ ~ : / -`; the origin is `https://host`, nothing else); `nginx: [emerg]` names a
line of `docker/nginx` that nginx refused. Fix `compose.env` or the file, then
`bash scripts/compose.sh up -d --wait gateway`.

### Database connection issues

```bash
bash scripts/compose.sh exec -T db pg_isready -U supabase_admin -d postgres
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

### Edge functions not working

```bash
bash scripts/compose.sh logs --tail 50 functions
bash scripts/compose.sh exec -T functions ls /home/deno/functions/
bash scripts/compose.sh restart functions
```

The functions are mounted read-only from the checkout's `functions/`
directory. When an upgrade changed only that code, the container itself is
unchanged, so the workers keep the code they loaded: `setup.sh` (and so
`upgrade.sh`) recreates `functions` on every run for that reason
([OPERATOR_INSTALL.md](OPERATOR_INSTALL.md#rerun-and-upgrade)). After a hand-made
checkout without a setup run, restart it as above.

### Slow API responses

```bash
ids=$(bash scripts/compose.sh ps -q); [ -n "$ids" ] && docker stats --no-stream $ids
bash scripts/compose.sh ps
bash scripts/compose.sh logs rest 2>&1 | grep -i pool
```

`docker stats` here receives this installation's container IDs only, and is
skipped when none is running: given no IDs it would list every container on
the host. A service shown as `Restarting` in `ps` is in a crash loop; read its
logs.

### A new receipt, dispatch or invoice is missing from a list

The lists read the tables, so a document that the app said was saved is in the next list read.
If a list does not show it, check the filter and sort on the screen (a date range, a customer, a search word) and
pull to refresh. A document missing from every list and from its own detail screen was not saved: look at the
app's last error.

### Printer not responding

Printing is an optional profile (`printing`):

```bash
bash scripts/compose.sh --profile printing ps cups
bash scripts/compose.sh --profile printing logs --tail 50 cups
bash scripts/compose.sh --profile printing exec -T cups lpstat -p
bash scripts/compose.sh --profile printing exec -T cups curl -f http://localhost:631/
```

Setup, the printer queue and the 503 answer of the print routes are described
in [PRINTING.md](PRINTING.md).

### Sensors show no data

Sensors are an optional profile (`sensors`); the bridge polls the Tapo hubs
and posts to the `ingest-sensor-readings` function ([SENSORS.md](SENSORS.md)):

```bash
bash scripts/compose.sh --profile sensors ps sensor-bridge
bash scripts/compose.sh --profile sensors logs --tail 100 sensor-bridge
bash scripts/compose.sh --profile sensors run --rm sensor-bridge --check-config
bash scripts/compose.sh --profile sensors run --rm sensor-bridge --once --dump
```

The log has one line per event (`event=config_error`, `auth_refused`,
`hub_offline`, `post_failed`, ...) and never the password or the key. When the app has no Sensors screen at all, the `sensors`
capability is off or the `functions` service was not restarted after
`set-capability`. More:

- **`event=config_error`, exit code 78:** a variable is missing or invalid; the line
  names it, never its value. `--check-config` prints the settings with the secrets left out.
- **`event=auth_refused` (401 from the function):** the key is wrong, revoked, or was minted on
  another installation. Mint a new one ([SENSORS.md](SENSORS.md#ingest-keys)). While refused, the bridge
  keeps its queue and tries again every 5 minutes.
- **`event=post_failed` with 503:** migration 74 is not applied, or the function runtime or the database
  is down (`node scripts/doctor.mjs --local`). The queue keeps the readings.
- **`event=hub_error` or `hub_offline` for a hub:** check from the host that its address answers (`ping`,
  and that it has a DHCP reservation); a Docker network whose subnet overlaps the LAN (`docker network
  inspect`) hides it from containers. A wrong Tapo password shows as a login failure for that hub only.
- **The app shows "no recent data" while the bridge is healthy:** the sensor's battery, its distance to
  the hub, or a hub that is offline (`sensor_hubs`). `--once --dump` shows what the hub itself reports.
- The health file: `bash scripts/compose.sh --profile sensors exec -T sensor-bridge cat /data/health.json`.

### PDF generation fails

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
sits on the internal `renderer` network, so `storage` and `gateway` cannot reach
it; only `functions` can.

## Monitoring and Slack alerts

- **No "Monitoring is alive" message today, or `npm run doctor` warns about the checker.** The checker is a systemd timer
  that setup cannot install for you. Check `bash scripts/watch-timer.sh status`; if it is not installed, run
  `sudo bash scripts/watch-timer.sh install --state "$WAREHOUSE_STATE_DIR"`. If it is installed, read
  `journalctl -u <unit>.service`, where `<unit>` is the name `bash scripts/watch-timer.sh status` prints before
  `.timer` (`warehouse-<instance>-watch`, from `WAREHOUSE_PROJECT_NAME` in `config/compose.env`), and `node scripts/watch.mjs status` (the last Slack failure is
  shown there); `node scripts/watch.mjs test-message` posts a test message to the stored webhook.
- **No backup is made, or `backup_missing` fires, while the checks run.** The daily backup is a second timer,
  `<project>-daily.timer`, that the checker does not start. `bash scripts/watch-timer.sh status` shows whether it is
  installed (an install from before it existed needs `sudo bash scripts/watch-timer.sh install --state "$WAREHOUSE_STATE_DIR"`
  once; until then its old checker unit keeps making the backup inside the 5-minute run, and Slack says `daily_timer_legacy` with
  that command); `journalctl -u <project>-daily.service` shows what the last pass did, and `node scripts/watch.mjs status` shows
  `Daily pass last skipped ...` with the reason (a service the backup stops was down, or the operator lock was held).
- **`bash scripts/watch-timer.sh status` says the Node.js is `MISSING`.** A Node.js upgrade removed the directory the units
  pointed at. Install Node.js again, then
  `sudo bash scripts/watch-timer.sh install --state "$WAREHOUSE_STATE_DIR" --node /absolute/path/to/node`; the units then name
  the link `~/.local/opt/node-current`, and the next upgrade only needs `ln -sfn <new prefix> ~/.local/opt/node-current`.
- **Right after install, `npm run doctor` warns "... the monitoring checker has never run ...".** Expected for the first
  few minutes: the timer runs the checker every 5 minutes, and the warning goes away after its first run. Rerun doctor after
  that; if it persists, read `journalctl -u <unit>.service` as above.
- **`clock_unsynced` fires, or central sign-in is refused for everyone ("issued in the future" in the function log: the host
  clock is more than 30 s behind the association's).** The host clock is wrong. `timedatectl` shows `System clock synchronized: yes/no`. Run `sudo timedatectl set-ntp true`, wait a minute, run it
  again; if it stays `no`, the host cannot reach its time servers (check the router's DNS and that UDP 123 is not blocked).
  Correct the time zone with `sudo timedatectl set-timezone Asia/Kolkata`; a wrong zone is not a wrong clock, but it moves the
  backup time (OPERATOR_INSTALL.md, "Host time zone").
- **Alerts for services you stopped on purpose.** Mute before a planned stop: `node scripts/watch.mjs mute 60`
  ([MONITORING.md](MONITORING.md#mute-and-unmute)).
- **Nothing reaches Slack, but the checker runs.** `status` says `Slack webhook: none` when the install was made with
  `--alert-webhook-file off`; rerun `setup.sh --operator` with your usual inputs and the webhook.

## Installation and setup

- **`Refusing: choose the PDF letterhead. ...` from `setup.sh`**: a first install with no terminal needs the choice made
  for it. Ask the installer whether the GRN, dispatch, invoice and customer stock PDFs should print their letterhead, then
  rerun the same command with `--letterhead-file /absolute/path/letterhead.png` (a JPEG or PNG of at most 2 MiB) or
  `--letterhead-file off` for plain PDFs. Nothing was changed. A rerun of an installed state never gives this message.
- **`Another operator command ... is running for this state`**: a previous
  setup, start, backup or restore is still running, or was interrupted while
  holding `config/operator.lock`. Wait or inspect `ps`; never delete the lock
  file.
- **`... is group- or world-writable` from `backup-usb.sh setup`**: the checkout was updated (`git pull`, `git checkout`)
  under a umask other than `022`; Ubuntu's default `0002` does this. As the
  installation user run `bash scripts/checkout-permissions.sh` (or rerun
  `setup.sh`), then repeat the command. Update with `bash upgrade.sh vX.Y.Z`, which checks the tag out under `umask 022`
  ([OPERATOR_INSTALL.md](OPERATOR_INSTALL.md#rerun-and-upgrade)).
- **PostgreSQL restarts with `Permission denied` on first start**: the
  checkout was cloned under `umask 077`. Re-clone with `umask 022` into a new
  directory and use a fresh empty state; keep the failed state for diagnosis.
- **`Linux x86-64 required.`, `Missing prerequisite: node` or `Missing or unavailable prerequisite: <tool>`**:
  `setup.sh` runs `node scripts/doctor.mjs --host-preflight` first. `Missing prerequisite: node` comes from
  `scripts/require-node.sh`, before the first Node call (Node 22.18+ is required). The doctor refuses other
  architectures and a missing or unusable `npm`, `openssl`, `flock`, `docker` or Docker Compose, an unreachable Docker
  daemon and a Compose plugin that does not accept `up --wait-timeout`. Install the named tool and run `setup.sh` again.
- **`This Docker Compose plugin does not accept up --wait-timeout`**: the
  Compose plugin is too old for the flag the scripts use. Install a current
  plugin from Docker's repository (any build listed under the host
  prerequisites works); a newer major version is not a problem by itself.
- **`node: command not found` in a new terminal or a service**: the user-owned
  Node is only on `PATH` where it was exported; repeat the export and keep it
  in `~/.profile`.
- **`State directory must be mode 0700` / `must not use a symlink` / `outside
  this checkout`**: the doctor's path rules; create the directory as shown in
  [private inputs](OPERATOR_INSTALL.md#private-inputs).
- **`EACCES: permission denied, mkdir '…/<name>.installing-…'` during setup**:
  the parent of the state directory (for example `/srv/warehouse`) is not owned
  by the installation user, typically because `sudo install -d` created it with
  the leaf. Run `sudo chown "$(id -un):$(id -gn)" /srv/warehouse`, keep it mode
  0755, and rerun the same setup command.
- **`An admin already exists with a different phone`**: an active
  administrator with another phone exists: the state directory belongs to
  another installation (use an empty one), or you gave the wrong
  `--admin-phone`. An administrator who was deleted or disabled does not cause
  this; see [the last administrator](OPERATOR_INSTALL.md#authentication-and-otp-limits).
- **`sudo: a terminal is required` or `a password is required` running setup**:
  the command was started from a shell without a terminal. Run it in a
  terminal window on the host or an SSH session.
- **`setup.sh` or `start.sh` stops with `Refusing: ... This release runs PostgreSQL 18 and cannot start on PostgreSQL 17 data.`**: the
  full text is `Refusing: <the running database reports server_version_num 170011 (PostgreSQL 17). | the data directory <path>
  holds a PostgreSQL 17 database (PG_VERSION).> This release runs PostgreSQL 18 and cannot start on PostgreSQL 17 data. No
  database, container or image was changed. The data moves with a major upgrade: back up with the checkout that runs PostgreSQL 17,
  then restore on this one (docs/OPERATOR_INSTALL.md, "Major PostgreSQL upgrade").` The installation still runs PostgreSQL 17.
  Nothing was built or started. Follow [Major PostgreSQL upgrade](OPERATOR_INSTALL.md#major-postgresql-upgrade). `db:backup` run
  with this checkout against the 17 server refuses the same way (`the running database reports '17|true'`): take the backup with the old checkout.
- **`setup.sh` or `start.sh` stops with `Refusing: ... This release runs PostgreSQL 18 and cannot start on that data.`**: the
  full text is `Refusing: <the running database reports server_version_num 150008 (PostgreSQL 15). | the data directory <path>
  holds a PostgreSQL 15 database (PG_VERSION).> This release runs PostgreSQL 18 and cannot start on that data. No database,
  container or image was changed. Back the installation up with the release tagged migrations-pre-baseline, then reload the data into a new
  PostgreSQL 18 database: docs/OPERATOR_INSTALL.md, "Baseline reload".` The installation still runs the earlier PostgreSQL 15
  database. Nothing was built or started. Follow [Baseline reload](OPERATOR_INSTALL.md#baseline-reload).
- **`scripts/migrate.sh` stops with `This database recorded migrations that are not in this release (...)`**: the full text is
  `This database recorded migrations that are not in this release (<names>). Either it was built by an earlier migration chain
  and cannot be migrated in place (reload it: docs/OPERATOR_INSTALL.md, "Baseline reload"), or it is newer than this checkout
  (check out the release that recorded those migrations).` Nothing was changed. Usually the database was built before the
  PostgreSQL 17 release: follow [Baseline reload](OPERATOR_INSTALL.md#baseline-reload). The message also appears when the
  checkout is older than the database (check out the release that recorded those migrations) and when a migration file that
  was applied has been deleted from the checkout (restore the file).
- **Setup stops in a migration with a message about a pg_cron job, a database
  webhook or a vault secret** (migrations 103 and 106, which only the release
  tagged `migrations-pre-baseline` runs, in step 1 of the
  [Baseline reload](OPERATOR_INSTALL.md#baseline-reload), on a database that
  still carries them): the message names the object. Remove or change it as the
  message says (for a pg_cron job of your own,
  `SELECT jobid, jobname, command FROM cron.job`, run as `supabase_admin` in the SQL prompt of
  [OPERATOR_INSTALL.md](OPERATOR_INSTALL.md#ordinary-operation) (not the read-only one), then `SELECT cron.unschedule(<jobid>)`
  for each job that is not `warehouse-list-refresh` or `warehouse-list-refresh-history`),
  then run setup again. Nothing was changed.
- **Setup stops in migration 105 with a dependency on the schemas `realtime` or `_realtime`** (only on the release tagged
  `migrations-pre-baseline`): something of yours depends on them. Remove that dependency and run setup again.

## Tunnel and public address

- **External doctor fails while `--local` passes**: the tunnel service is
  inactive, the DNS record does not point to `<tunnel-uuid>.cfargotunnel.com`,
  the route targets the wrong loopback port, the origin redirects, or the host
  cached an NXDOMAIN from a lookup made before the route existed (compare
  `dig +short <hostname> @1.1.1.1` with `dig +short <hostname>`; wait for the
  negative TTL, up to 30 minutes on a Cloudflare zone, or flush the resolver
  cache with `resolvectl flush-caches`). Check `systemctl status` of the
  unit and `cloudflared ... tunnel ingress validate`. Right after a key rotation
  one failure is normal; rerun after about thirty seconds.
- **External doctor fails with `ENETUNREACH` and an IPv6 address**: this host has no IPv6 route, and the name either
  resolved only to IPv6 or its IPv4 lookup failed (often the NXDOMAIN cache described above). Check
  `dig +short A <hostname>` against `dig +short A <hostname> @1.1.1.1`; when only the second answers, flush the resolver cache
  as above and rerun.
- **`tunnel.sh adopt` refuses**: `certificate or key block` / `origincert`: you
  pointed it at `cert.pem` or at a config naming it; adopt only the tunnel's
  `config.yml` with its credentials JSON (remove the `origincert:` line) or the
  token file. `does not route <host>`: the config belongs to another installation
  or its `hostname:` differs from this installation's `--api-url`.
  `not the credentials JSON of tunnel`: the `credentials-file:` is another
  tunnel's. `already exists`: a credential is already adopted; move
  `config/tunnel` aside to replace it.
- **`tunnel.sh install-service`: `did not start`**: read
  `journalctl -u warehouse-<state name>-tunnel.service -n 50`; a dated copy of the
  previous unit is next to it in `/etc/systemd/system/` if you need to go back.

### The app says the LAN address is unreachable

A version of the app that has the [LAN fallback](OPERATOR_INSTALL.md#lan-fallback-plain-http-on-the-warehouse-network) (not released yet)
uses it (plain http, `http://<address>:<port>`) only after the public address has failed. If it then says the LAN address is
unreachable, work from the host:

1. `bash scripts/lan.sh status`. It prints `LAN address for the app: http://<address>:<port>`, whether the host still has that address,
   and the state of the `gateway-lan` container. Compare the address with the one the phone shows.
2. **`WARNING: this host no longer has <address>`** (also the alert `lan_ip_changed` and a warning in `doctor`): the router gave the host
   another address, usually after a power cut. Run `bash scripts/lan.sh on auto`, then give the host a DHCP reservation in the router so
   it stays put. Phones learn the new address the next time they connect over the internet; until then a phone holds the old one.
   Meanwhile the public path is unaffected: `compose.sh` leaves the `lan` profile out while the address is missing, so `start.sh` and
   the boot unit start everything else.
3. **The container is not running or not healthy**: `bash scripts/compose.sh --profile lan logs --tail 50 gateway-lan`. A message
   starting `gateway:` is the entrypoint refusing a missing or non-private `LAN_CIDR`: run `bash scripts/lan.sh on auto` again.
4. **The host answers but the phone does not** (`node scripts/doctor.mjs --lan` passes): doctor connects from the host, which is always
   inside `LAN_CIDR`, so it cannot see what a phone sees. Work through these:
   - **The phone is outside `LAN_CIDR`**: a `403` in the `gateway-lan` log (`bash scripts/compose.sh --profile lan logs --tail 50 gateway-lan`)
     means a connection from an address outside the range arrived. Compare the phone's Wi-Fi address (the Wi-Fi details of the phone) with
     `LAN_CIDR` (`bash scripts/lan.sh status`); if the Wi-Fi uses another range, run `bash scripts/lan.sh on <address> --cidr <the warehouse network>`.
   - **The phone is on a different network or isolated**: a guest network, "AP isolation" or "client isolation" on the access point, or a
     Wi-Fi on another subnet that the router does not route to the server. From a laptop on the same Wi-Fi:
     `curl -s -o /dev/null -w '%{http_code}\n' http://<address>:<port>/functions/v1/hello` should print 200.
   - **The phone holds an old address**: the router gave the host another one (`lan_ip_changed`), or the saved address is stale. Run
     `bash scripts/lan.sh status` and compare the address; the phone learns the new one when it next connects over the internet.
   - **The router has a port rule** for `LAN_HTTP_PORT`, or re-addresses traffic. Remove port forwarding for it.
   - **The request names the server by a DNS name** (`404` with `{"message":"no Route matched ..."}`): the listener answers only a `Host` that
     is the server's own address (`LAN_BIND_IP` or `LAN_BIND_IP:LAN_HTTP_PORT`). Use the address.
   - **The host's firewall: there is nothing to add for ufw.** ufw does not see the traffic of a port that Docker publishes, so
     `ufw default deny routed` does not block it and no `ufw route` rule helps. A host that filters Docker traffic in its `DOCKER-USER`
     chain has a rule there that matches it: look at that chain (`sudo iptables -S DOCKER-USER`;
     [CONTAINER_SECURITY.md](CONTAINER_SECURITY.md#lan-fallback-gateway-lan) has the form of a correct rule).
5. **`doctor` or the alert `lan_http_down` says the LAN listener refuses the anon key** (`HTTP 401 from the gateway`, "before a key rotation"):
   the `gateway-lan` container was not recreated after `rotate-keys.sh`, so it still has the old keys and refuses every REST request of
   every phone. Run `bash scripts/compose.sh --profile lan up -d --force-recreate --no-deps gateway-lan` (or `bash scripts/lan.sh on auto`),
   then `node scripts/doctor.mjs --lan`. (`rotate-keys.sh` recreates it itself; this appears only when that step failed or a rotation
   was done by hand.)
6. **Every phone says it with the internet working**: the app only uses the LAN address after a transport failure of the public one, so
   look at the public path first ([Tunnel and public address](#tunnel-and-public-address)).

Turn the fallback off with `bash scripts/lan.sh off`; the phones keep working over the internet.

## Sign-in codes

- **OTP accepted by the API but not received**: verify the Flow ID (not the
  DLT template ID), the `OTP` variable name and the sender/entity approval in
  the MSG91 console. The per-phone, per-source and warehouse-wide caps
  ([OPERATOR_INSTALL.md](OPERATOR_INSTALL.md#authentication-and-otp-limits)) return an explicit
  refusal, not silence.
- **`api_429_rate_high` fires: users see "Too many requests".** The gateway and the sign-in functions refuse a client that
  goes over a limit (OPERATOR_INSTALL.md, "Authentication and OTP limits"; the gateway limits are in
  [CONTAINER_SECURITY.md](CONTAINER_SECURITY.md#gateway-limits-and-routes)). See who is refused: the gateway log keeps the
  client address, `bash scripts/compose.sh logs -t --tail 3000 gateway | grep ' 429 '` (the newest lines with their times; `--since 10m` returned nothing on one Docker 29 host). One address with thousands of lines is one
  stuck client. Many phones behind **one** address are one Wi-Fi counted as one client: the per-address OTP and function limits
  apply to the whole warehouse Wi-Fi, so a wave of sign-ins (everyone's session ending the same week) can fill them.
- **A user cannot get a code because someone used up the limits of their number**: clear that phone's counters
  with `warehouse_security.reset_otp_limits` (same section).
- **Nobody can get a code at all (MSG91 balance, DLT header or provider outage) and an administrator cannot sign in**: use the
  break-glass sign-in. On the server, `bash scripts/break-glass-admin.sh 9XXXXXXXXX` prints a one-time code for that administrator, valid
  10 minutes; they type it instead of the SMS code ([Break-glass administrator sign-in](OPERATOR_INSTALL.md#break-glass-administrator-sign-in)).
  It refuses a number that is not an active administrator, and every code made and used is in `public.audit_log`
  (`table_name = 'break_glass'`). Staff and customers wait for the SMS service to be repaired; an administrator who is signed in
  can then help from the app. Sessions that are open keep working while they are used (30 days idle, 90 days at most).
  Three things to know. The command prints the code only to a terminal. If the administrator's app still answers "Too many OTP requests"
  on the code screen, switch their phone from the facility Wi-Fi to mobile data (the Wi-Fi's address may be at its limit) and check
  that `otp_global_hourly_cap` is not `0` and `otp_daily_provider_attempt_cap` is not used up. If the app shows "SMS delivery unavailable"
  and no code screen, the `functions` container is an old one: `setup.sh` recreates it on every run (a rerun fixes it); an installation last set up by an older release needs `bash scripts/compose.sh up -d --force-recreate functions`. And it does not
  help when the sign-in goes through the association and the association's SMS is down (OPERATOR_INSTALL.md, "Break-glass administrator
  sign-in").
- **Many people on the facility Wi-Fi get "Too many OTP requests" in the same hour** (after a key rotation, or a morning when sessions ended
  together): the Wi-Fi is one address and the limit is 30 requests an hour per address. List the facility's public address in
  `otp_trusted_source_list` (limit 120 an hour); see [The facility's own Wi-Fi address](OPERATOR_INSTALL.md#the-facilitys-own-wi-fi-address).
- **A phone is lost or stolen**: sessions now last weeks, so end the person's sessions at once. An administrator switches the user off
  (Settings → Users → edit → Account Status), which deletes every session of that user; switch them on again when they have a new phone and
  they sign in there with a code. An administrator cannot switch off their own account and the last administrator cannot be switched off: if
  it is an administrator's own phone and no other administrator can do it, run `bash rotate-keys.sh --yes`, which signs every user out
  ([Rotate signing keys](OPERATOR_INSTALL.md#rotate-signing-keys); [A lost or stolen phone](OPERATOR_INSTALL.md#authentication-and-otp-limits)).

## Backup, USB drive and restore

- **`db:restore`, `db:restore-host` or `db:verify-restore` prints `Refusing: the backup was made on 'postgres:19...', a newer
  PostgreSQL major than the 18 this checkout runs`** (or `the database dump was made by PostgreSQL '19.x', a newer major`): a
  dump cannot be restored on an older server. Nothing was touched. Check out the release the backup was made with, or a newer one.
  Backups from PostgreSQL 17 and 18 restore on this release.
- **`db:restore` prints `Refusing: the db image could not be rebuilt`** or `the db image still does not match this checkout`: the
  restore initialises a new cluster with the db image of this checkout and found an older image (the previous PostgreSQL major). It
  refused before moving any data. Run `bash scripts/build-images.sh` (needs the network), then retry.
- **`db:restore`, `db:restore-host` or `db:verify-restore` prints `Refusing: the backup was made on the database image
  'supabase/postgres...'`**: the full text is `Refusing: the backup was made on the database image '<image>', which this
  version no longer runs. Restore it with the release tagged migrations-pre-baseline, then reload the data into this
  version (docs/OPERATOR_INSTALL.md, "Baseline reload").` The backup was made before the PostgreSQL 17 release. Nothing
  was touched. A backup without a `database_image=` line in `metadata.txt` gets `Refusing: the backup records no
  database_image= line in metadata.txt, so it was made before the move to PostgreSQL 17. Restore it with the release
  tagged migrations-pre-baseline, then reload the data into this version (docs/OPERATOR_INSTALL.md, "Baseline reload").`
  A backup whose `roles.txt` lists `postgres`, `supabase_auth_admin` or `dashboard_user` gets `Refusing: the backup lists
  the role '<role>', which this version does not have: it was dumped from the earlier image, whatever its database_image=
  line says. Restore it with the release tagged migrations-pre-baseline, then reload the data into this version
  (docs/OPERATOR_INSTALL.md, "Baseline reload").`
  Follow [Restoring a pre-baseline backup](OPERATOR_INSTALL.md#restoring-a-pre-baseline-backup) and the
  [Baseline reload](OPERATOR_INSTALL.md#baseline-reload).
- **Nothing happens when the USB drive is attached**: check that it is
  enrolled and visible to the host: `bash scripts/backup-usb.sh status` (on a
  Windows host the drive must be attached to the Ubuntu distro, which has no tested way yet:
  [OPERATOR_INSTALL.md](OPERATOR_INSTALL.md#backups-off-the-host-windows)), then
  `journalctl -u 'warehouse-usb-backup@*' -n 50`. Only exFAT partitions on USB
  drives whose UUID is enrolled start a run; reformatting a drive changes its
  UUID, so enroll it again.
- **Setup succeeded but no backup was copied**: setup does not start a run for
  a drive that is already attached. Unplug the drive and attach it again, then follow the run with
  `journalctl -f -u 'warehouse-usb-backup@*'`.
- **`backup-usb.sh`: `Could not unmount …`**: a file manager window or terminal
  is using the drive; close it and run
  `sudo /usr/local/libexec/warehouse-usb-backup unmount sdb1` (your partition).
- **USB run failed: `matches its checksum but was not signed with the current
  backup key`**: the archive is intact but its signature is from another key.
  After you replaced the backup key this is expected for the older archives:
  move them into another folder on the drive ([Backup key](OPERATOR_INSTALL.md#backup-key)).
  If you did not replace the key, someone rewrote the archive and its checksum
  on the drive: do not use it, delete it, and the next run writes it again.
- **USB run failed: `carries no valid signature of this installation's backup
  key; it was not opened`**: the drive holds an archive newer than every
  archive this installation signed. Somebody put the file there:
  remove it. The run still verifies the newest archive it signed itself.
- **USB run failed: `does not match its checksum; it was not overwritten`**: an
  archive on the drive is damaged. Copy the drive's other files elsewhere, run
  `sha256sum -c` on each `.tar.enc.sha256` (`.tar.sha256` for a readable archive) to see which, and replace the drive if
  errors recur; delete a damaged archive yourself and the next run writes it
  again. A damaged archive is never deleted by the run and is not counted among the archives it keeps.
- **USB: confirm the backup key copy**: a run, `setup --enroll` or `enroll` stops with `The backup key copy is not confirmed
  (there is no key escrow record)` (or `... is for another backup key`), and `npm run doctor` and the `usb_backup` alert say that
  archives are encrypted but the key copy is not confirmed. Nothing was written to the drive. Archives on the drive are encrypted
  with `config/backup.key`, which lives on the disk that dies with the host, so the run waits until you have a copy elsewhere. In a
  terminal on the host, as the installation user: `bash scripts/backup-key-escrow.sh show` (with `WAREHOUSE_STATE_DIR` set). It prints
  the key once; copy it to a password manager or paper kept away from the facility and from the drive, then type or paste the **whole
  key** back from your copy (a copy with one wrong character is refused, with the number of characters you gave; three tries), clear the
  terminal as it says, and attach the drive again. After the key was replaced the old confirmation no longer counts: confirm the new
  key the same way. Without a terminal: `bash scripts/backup-key-escrow.sh confirm --key-file FILE`, where FILE holds your copy of the
  key. A rebuilt host (after `db:restore-host`) has no record either, because the record is not part of a backup: confirm again with
  the copy you restored from. `bash scripts/backup-key-escrow.sh check` says whether the record is good. Do not copy a
  `backup-key.escrow` file from another installation: it records another key's fingerprint and is refused. If you would rather not
  encrypt, `sudo bash scripts/backup-usb.sh setup --state "$WAREHOUSE_STATE_DIR" --no-encrypt` needs no confirmation, and then the
  drive holds every credential of the instance in the clear.
- **USB: `archives are still written unencrypted` (doctor, `usb_backup`, `backup-usb.sh status`)**: this installation's USB backup was
  set up by an earlier release, when readable archives were the default, and nobody has run the setup since. It keeps writing readable
  archives (every credential on the drive) with the old 2-hour limit. Run `sudo bash scripts/backup-usb.sh setup --state
  "$WAREHOUSE_STATE_DIR"` (a tty and your password), then confirm the key copy as above; or type `--no-encrypt` if readable archives are
  what you want, which clears the warning.
- **USB: `could not read the free space of the drive`** (or of the state directory): `df` and the file system gave no number, so the
  run could not tell whether the new archive fits. It stopped before writing or deleting anything. Look for a read error in `dmesg`,
  try another USB port or cable, and attach the drive again; a drive that keeps doing this is failing.
- **USB: drive too small**: the run stops with `drive too small: needs X, has Y`. The archive of the newest backup does not fit next
  to the newest valid archive already on the drive, even after the run deleted the older valid archives (it names each one it
  deleted). The drive must hold at least two archives while a new one is written, and three at rest with the default `--keep 3`:
  use a larger drive (or remove your own files from it). `--keep N` does not help with the size of one archive. The newest
  valid archive is never deleted, so the drive still holds a copy. Archives are written in full, without hard links (exFAT has none):
  each is the size of the whole backup, the database and every stored file.
- **USB: `not enough free space in <state> to check <backup> from the drive`**: the restore check unpacks the archive's small files
  (the database dump, the manifest, the configuration; never the photos) into the state directory first, and the free space there
  is under their size plus 256 MiB. The archive itself was written and is kept; free space on the data disk
  ([Disk full](#disk-full)), then attach the drive again.
- **USB: readable `.tar` archives disappeared from the drive**: expected after the first encrypted archive was written and verified:
  the run deletes this installation's readable archives (it prints each one), because they hold every credential. Archives it could not
  prove to be this installation's (an archive without a signature, one signed with another key) are named and left, on every run, until
  you remove them yourself. **Deleting is not wiping:** on an exFAT drive the contents of a deleted archive can still be recovered
  until they are overwritten. Before a drive that ever held readable archives leaves your hands, rotate the credentials they held
  (`./rotate-keys.sh --yes`, the MSG91 key, the tunnel credential: [OPERATOR_INSTALL.md](OPERATOR_INSTALL.md#usb-backup-drive)) or
  retire the drive and enrol a new one.
- **USB: the drive fills up with archives that are never deleted**: the run never prunes an archive that is damaged, unsigned or signed
  with another key, so the archives written under a replaced backup key stay (it cannot tell them from files somebody planted). After
  you change the backup key, delete the old ones yourself once you no longer need the backups they hold.
- **`db:restore`: `the backup instance.json differs from this state in its identity (...)`**: the field in
  brackets (`instanceId`, `canonicalOrigin` or `companyName`) differs, so the
  backup belongs to another installation, typically because `setup.sh` was run
  on the new host before restoring. In-place restore only replaces the instance
  that produced the backup. Do not edit `instance.json` to get past the check:
  move the new state aside and follow
  [Recover a lost host from the USB drive](OPERATOR_INSTALL.md#recover-a-lost-host-from-the-usb-drive),
  which recreates the state from the backup instead of running setup.
- **`db:restore-host` refuses**: every refusal happens before anything is
  created. `backup has N migrations and this checkout only M` or `migrations this
  backup applied differ`: check out the commit the message names
  (`source_commit`) or a later release. `containers of … already exist`: this
  host still runs (or ran) that installation; restore-host is for a new host,
  use `db:restore` on the existing state instead. `already exists and is not
  empty`: choose a new state path; restore-host never overwrites an
  installation. `Missing checksum file` or `does not match`: use another
  archive from the drive.
- **A backup is refused as `no longer supported`**: only formats v5 and v6 are accepted. Take a new backup with this version.
  A checkout older than the release that added format v6 gives the same message for a v6 backup (before it reaches the
  `source_commit` hint): check out this release or a later one.
- **A backup is refused: `labelled warehouse-backup-vN, but its signed file list does not describe that layout`**: the label in
  `metadata.txt` and the files the signed list names disagree (v6 lists `storage.manifest` and has a `storage/` tree; v5 lists
  `storage.tar.gz`). Do not edit either: use another copy of the backup.
- **`db:backup` ends with `WARNING: N files re-copied: backup warehouse-<utc> has a damaged copy`** (also in the daily status
  line of `node scripts/watch.mjs status`, and as `rot_repaired=` in the new backup's `metadata.txt`): the new backup is good, and
  the night counted as ok. The older backup it names holds a damaged copy of N stored files (bit rot, or a disk error: a
  hard link shares one copy of a file between backups, so one damaged file is damaged in every backup that links it). The
  backup found the file no longer matching the checksum that backup recorded, did not link it, and copied it again from the live
  storage. Nothing is needed for the new backup. To see how far the damage reaches, run `npm run db:verify-restore --
  backups/warehouse-<utc>` on the named backup and on the ones before it: they fail with `a file of the backup storage/ tree
  does not match storage.manifest` until they age out (they are removed by the usual retention), or until you repair them as
  below. Repeated warnings, or a read error in `dmesg`, mean the backup disk is failing: replace it and keep the USB copies.
- **A storage file fails its checksum** (`db:verify-restore` with `a file of the backup storage/ tree does not match
  storage.manifest`, or `db:backup` stops with `Files shared with warehouse-<utc> no longer have the checksum recorded for
  them there, and the live storage does not give a good copy of them either`): a photo or PDF in the backups changed on the
  disk (bit rot, a failing disk, a write into a backup). The second message means the live file does not match what that
  backup recorded either, so one of the two is damaged; the next `db:backup` then copies every stored file instead of linking
  (it prints a note that it does not use that backup as the base). For each file named (up to ten):
  0. **Check the backup first**: `npm run db:verify-restore -- backups/warehouse-<utc>`. If its signature or `SHA256SUMS`
     fails, or `storage.manifest` itself is damaged, the manifest is wrong and not the photo: do not conclude that the photo is
     lost from the checksum recorded in a damaged manifest. Use another backup (`db:backup` already skips a base whose signature
     fails, with a warning).
  1. Take the checksum recorded for the file: `awk -v p='<path>' 'substr($0, 67) == p' backups/warehouse-<utc>/storage.manifest`,
     with the `<path>` below `storage/` (this compares the whole name, so a name with `.`, `*`, `+`, `(` or `$` in it is read
     literally).
  2. If the live file `data/storage/<path>` has that checksum (`sha256sum`), it is the good copy: overwrite the damaged one
     in place, `cp --preserve=mode,timestamps,xattr data/storage/<path> backups/warehouse-<utc>/storage/<path>` (the same file as in every
     backup that links to it, so one copy repairs them all), then take a new backup.
  3. If the live file does not have it either, **restore the file from the newest USB archive** of this installation:
     extract that archive into a temporary folder and use `warehouse-<utc>/storage/<path>` there after checking its
     checksum against the same line of the manifest; put it into the live storage (stop the services first) and into the
     backup as above.
  4. If no copy has the recorded checksum (and the manifest passed step 0), the photo is lost in this installation; tell the
     maintainers, and replace the disk that damaged it.
- **Stored files are served as `application/octet-stream` and `no-cache` after a restore, or an installation went through the
  PostgreSQL 17 to 18 move**: the file attributes that hold each file's content type were not kept by the restore. Run
  `npm run storage:retag` ([Content types of stored files](OPERATOR_INSTALL.md#content-types-of-stored-files-npm-run-storageretag)):
  it sets them again from the catalog, is safe to repeat, and prints how many files it changed. It needs the services running.
- **Backup refused: not enough free space** (`db:backup` stops with `Refusing: not enough free space in <folder>: a backup needs
  about N MiB (...) plus a reserve of R MiB, but only A MiB are free. Nothing was stopped.`; Slack `backup_failed` shows the same
  line): `db:backup` measured the disk before it stopped a service or wrote a byte, so the app kept running and no partial backup is
  left. The part in brackets says how N was counted. With an earlier backup to link from: `2 x D MiB of new stored files and folders +
  P MiB for the database dump + 256 MiB of working room`, where D is what the copy would add (the photos new since that backup, and
  4 KiB for each folder of the tree). With none (the first v6 backup, or every earlier one is unusable): `D MiB of stored files,
  counted once + M MiB margin (10%) + P MiB for the database dump + 256 MiB of working room`, where D is the whole photo tree. P is the
  database dump (1.5 times the dump of the backup it links from, at least 96 MiB; with none, 1.5 times the database's size). R is a
  reserve the disk must keep beyond that so that a backup never fills the disk under the database (`WAREHOUSE_BACKUP_RESERVE_MB`, 2048
  by default), A what the disk that holds the backup folder has free. Free at least N + R - A MiB, in this order, each step safe:
  1. Docker leftovers: `docker image prune -f` (dangling images only; never `-a`, never `--volumes`) and `docker builder prune -f`
     (not during a major PostgreSQL upgrade or a baseline reload that is not accepted yet).
  2. The `data/storage.pre-restore-*` directories of earlier restores that you have accepted
     ([In-place restore](OPERATOR_INSTALL.md#in-place-restore-of-the-same-instance)).
  3. Old local backups. **In the weeks after the update to the v6 backup format** this is the usual fix and it frees a lot: every
     backup that still has a `storage.tar.gz` is a `warehouse-backup-v5` backup and holds a whole copy of the photos, so deleting
     one frees about the size of the photo volume (`du -sh data/storage`). The first v6 backup has nothing to link from and needs the
     tree once plus 10%, and **until the v5 backups age out a refused night makes no new backup, so nothing is pruned by itself**: delete
     the oldest v5 backups by hand until the numbers fit. (The USB script copies only the newest verified backup, so it keeps no old backup for you; to keep one, write its archive into a separate folder of the drive outside this installation's folder, for example `warehouse-backups/kept/`: [OPERATOR_INSTALL.md](OPERATOR_INSTALL.md#backup-and-restore).)
     Which one is the newest verified (**never delete that one**: it is the last backup known to restore, and the next backup links its
     photos from it):
     `awk 'NF { print $1 }' "$WAREHOUSE_STATE_DIR/config/backups-verified.list" | sort | tail -n 1`
     (`node scripts/watch.mjs status` names it too on a night whose verify failed). Delete the older backups that are not on the list
     first (their verify failed, or they were never checked), the oldest verified ones after. A `warehouse-backup-v6` backup frees
     only its own database dump and the photos no other backup holds: do not expect gigabytes from deleting v6 backups.
  4. The saved image tarballs in `$WAREHOUSE_STATE_DIR/images` (about 2.5 GiB) after copying them to the drive; they come back at
     the next build.
  5. If the disk is small and the numbers are right but the 2 GiB reserve is what stops it, lower the reserve: for the nightly run
     `sudo systemctl edit <project>-daily.service` and add `[Service]` and `Environment=WAREHOUSE_BACKUP_RESERVE_MB=512`
     (`bash scripts/watch-timer.sh status` names the unit); by hand, `WAREHOUSE_BACKUP_RESERVE_MB=512 npm run db:backup`. The fresh
     backup of the USB unit (`sudo systemctl edit warehouse-usb-backup@.service`, the same two lines) and the backup inside
     `upgrade.sh` (`WAREHOUSE_BACKUP_RESERVE_MB=512 bash upgrade.sh vX.Y.Z`) do not see the daily unit's setting: lower it there too.
     Do not set it to 0 on the disk that holds the database: PostgreSQL needs room for its write-ahead log. The lasting fix is a
     bigger disk.
  Then take the backup (`npm run db:backup`, or `sudo systemctl start --no-block <project>-daily.service` inside the window). The
  daily pass keeps pruning (beyond the newest 7, the newest verified one and the backup of an interrupted `upgrade.sh`) and applying
  retention on the nights the backup is refused. (If the refusal says `could not read the free space` instead of giving numbers, see
  the next entry.)
- **Backup refused: `could not read the free space of <folder> (df and stat -f both failed)`** (Slack `backup_failed` shows the same
  line; nothing was stopped): `db:backup` reads the free space with `df -B1 --output=avail -- <folder>`, and when that gives no number
  with `stat -f -c '%a %S' -- <folder>`. Run both by hand as the user the backup runs as and read the error. A `df` that is a wrapper
  or does not know `--output` (busybox) is the usual cause: install GNU coreutils. When only `df` fails, the backup goes ahead on the
  `stat -f` figure and the daily status line carries `df gave no free space for <folder>, so stat -f was used for the free-space check`;
  fix `df` so that the warning goes away.
- **`db:backup` stops with `copying the object storage failed (rsync exit 23)`**: two causes, both before anything was stopped.
  rsync could not read a file or folder of `data/storage` (a copied-in file owned by root or mode 700 is the usual cause; the
  lines above the message name it): make the folders mode 755 and the files mode 644 (`sudo chmod`), then back up again. Or the
  disk that holds `backups/` does not keep `user.*` extended attributes or hard links (FAT, exFAT, some NFS mounts: rsync prints
  `lsetxattr ... Operation not supported` or `link ... failed`): put `backups/` on a Linux filesystem such as ext4 or xfs and
  copy backups to other media afterwards.
- **`db:backup` stops with `the copy of the object storage is not identical to the live storage after the final pass`**: the
  disk that holds `backups/` does not keep extended attributes or modification times (a FAT or exFAT disk, an NFS mount without
  attribute support). The backup folder must be on a Linux filesystem such as ext4 or xfs; copy backups to other media
  afterwards. The services were restarted.
- **`setup.sh` or `db:restore-host` stops with `Missing or unavailable prerequisite: rsync ...` or `GNU tar with --xattrs`**, or
  `start.sh` / `doctor` warn about them: install the packages (`sudo apt-get install rsync tar`); `node scripts/doctor.mjs
  --host-preflight` checks both. `start.sh` only warns, so the services start, but `db:backup` and `db:restore` fail until
  `rsync` is installed.
- **`db:rotate-passwords` stopped half-way**: run it again; it works out which values the database has
  ([Rotating the database passwords](OPERATOR_INSTALL.md#rotating-the-database-passwords)).

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
  that exists, rebuilds the `db`, `storage` and `pdf-renderer` images when their recipes changed, and
  rewrites an old `PGRST_DB_SCHEMAS` default to `public`; a restore does the same);
- a new, empty installation: a new state directory and
  [Setup](OPERATOR_INSTALL.md#setup), not a deletion of an existing one.

Take `npm run db:backup` before any of these.
