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
Name services (`db`, `kong`, `rest`, `storage`, `functions`, `pdf-renderer`, `cups`), never
containers: do not run `docker logs`, `docker exec` or `docker restart` with a
fixed container name such as `supabase-kong`. On a host that also runs a
separate Supabase deployment or a second installation, such a name belongs to
that other project, and the command changes it instead of this one.

`node scripts/doctor.mjs --local` is the health verdict for this installation;
`node scripts/doctor.mjs` adds the external checks through the tunnel
([OPERATOR_INSTALL.md](OPERATOR_INSTALL.md#ordinary-operation)).

## Services

### Services won't start

```bash
bash scripts/compose.sh ps
bash scripts/compose.sh logs --tail 100 db kong rest
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

Public-configuration reads that take seconds, with `rest.localdomain` SERVFAIL in
the gateway log, mean the host's DHCP search domain leaked into the gateway's
resolver. `docker/docker-compose.yml` pins `dns_search: "."` for Kong; keep it,
and do not change host DNS or extend client timeouts.

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
unchanged and is not recreated, so restart `functions` after the upgrade
([OPERATOR_INSTALL.md](OPERATOR_INSTALL.md#rerun-and-upgrade)) for the workers
to load the new code.

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
sits on the internal `renderer` network, so `storage` and `kong` cannot reach
it; only `functions` can.

## Monitoring and Slack alerts

- **No "Monitoring is alive" message today, or `npm run doctor` warns about the checker.** The checker is a systemd timer
  that setup cannot install for you. Check `bash scripts/watch-timer.sh status`; if it is not installed, run
  `sudo bash scripts/watch-timer.sh install --state "$WAREHOUSE_STATE_DIR"`. If it is installed, read
  `journalctl -u <unit>.service`, where `<unit>` is the name `bash scripts/watch-timer.sh status` prints before
  `.timer` (`warehouse-<instance>-watch`, from `WAREHOUSE_PROJECT_NAME` in `config/compose.env`), and `node scripts/watch.mjs status` (the last Slack failure is
  shown there); `node scripts/watch.mjs test-message` posts a test message to the stored webhook.
- **Right after install, `npm run doctor` warns "... the monitoring checker has never run ...".** Expected for the first
  few minutes: the timer runs the checker every 5 minutes, and the warning goes away after its first run. Rerun doctor after
  that; if it persists, read `journalctl -u <unit>.service` as above.
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
  `setup.sh`), then repeat the command. Update with `(umask 022; git pull
  --ff-only)` from then on.
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

## Sign-in codes

- **OTP accepted by the API but not received**: verify the Flow ID (not the
  DLT template ID), the `OTP` variable name and the sender/entity approval in
  the MSG91 console. The per-phone, per-source and warehouse-wide caps
  ([OPERATOR_INSTALL.md](OPERATOR_INSTALL.md#authentication-and-otp-limits)) return an explicit
  refusal, not silence.
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
  and no code screen, the `functions` container is an old one: `bash scripts/compose.sh up -d --force-recreate functions`. And it does not
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
  enrolled and visible to the host: `bash scripts/backup-usb.sh status` (on
  VMware the drive must be connected to the VM, not the Windows host), then
  `journalctl -u 'warehouse-usb-backup@*' -n 50`. Only exFAT partitions on USB
  drives whose UUID is enrolled start a run; reformatting a drive changes its
  UUID, so enroll it again.
- **Setup succeeded but no backup was copied**: setup does not start a run for
  a drive that is already attached. Unplug the drive (on VMware: Removable
  Devices, Disconnect) and attach it again, then follow the run with
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
  `sha256sum -c` on each `.tar.sha256` to see which, and replace the drive if
  errors recur; delete a damaged archive yourself and the next run writes it
  again.
- **`db:restore`: `the backup instance.json differs from this state`**: the
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
- **A backup is refused as `no longer supported`**: only format v5 is accepted. Take a new backup with this version.
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
