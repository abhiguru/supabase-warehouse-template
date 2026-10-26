# Monitoring and Slack alerts

One small program, `scripts/watch.mjs` (the checker), watches an installation. A systemd timer runs it every 5 minutes.
It checks the host, the database, the containers, the gateway and the backups, and tells the facility's own Slack channel
when something is wrong. A second timer runs `watch.mjs daily` once a day: it makes and verifies a backup and applies
retention. The two are separate units, so a broken checker does not stop the backups and a long backup does not stop the
checks: while it runs, the host, disk and database checks go on, and only the checks that need the services the backup
stops wait ([below](#what-it-checks)). There are no dashboards, no metric history and no extra containers: Slack is the only way an alert leaves
the host, and the optional external heartbeat ([below](#external-heartbeat-the-dead-man-switch)) is how a dead checker is noticed.

## Install the timer

Installing a systemd unit needs root, which `setup.sh`, `start.sh` and `db:restore-host` never use. Like the tunnel
service and the USB backup drive, the operator runs one command, from the installation user's account:

```bash
sudo bash scripts/watch-timer.sh install --state "$WAREHOUSE_STATE_DIR"
```

`setup.sh` prints this command when it finishes, and `start.sh` prints it whenever the timer is missing. Run it again
after a move of the checkout, a change of Node.js, or to change the time of the daily pass (`--daily-at HH:MM`, the
host's local time; default 02:30). `bash scripts/watch-timer.sh status` shows whether it is installed;
`sudo bash scripts/watch-timer.sh uninstall --state "$WAREHOUSE_STATE_DIR"` removes it.

The command writes five unit files: `<project>-watch.service` and `.timer` (the 5-minute checks), `<project>-daily.service`
and `.timer` (the daily backup, below) and `<project>-stack.service` (boot, below). The units name the Node.js through a link,
`~/.local/opt/node-current`, that `install` points at the Node.js prefix it was given, not at a versioned directory. After a
Node.js upgrade, unpack the new version, run `sudo bash scripts/watch-timer.sh install --state "$WAREHOUSE_STATE_DIR" --node
<new prefix>/bin/node` (or only `ln -sfn <new prefix> ~/.local/opt/node-current`), then `node scripts/watch.mjs status`. If the
Node.js the units run is gone, `bash scripts/watch-timer.sh status` says `MISSING`, and `start.sh` and `setup.sh` print the same fix. `npm run doctor` warns when the daily timer is not active.

**An installation updated from before the daily timer existed keeps making its backup** from its old checker unit (the one that
sets `WAREHOUSE_WATCH_DAILY_AT`): that `run` makes the pass as it always did, so an update never leaves a gap in the backups.
It is the old design (a long backup holds the checks off, and there is no boot unit), so the checker raises `daily_timer_legacy`
at once, in Slack, `status`, `doctor` and the `start.sh` hint, with the command to run: the `install` above. That alert is never muted.
Installing while the old unit is running warns first: it may be in the middle of the backup, and the install re-reads the unit's
time limit.

The boot unit, `<project>-stack.service`, runs `compose up -d --no-build --no-recreate` for the default profile after
`docker.service` at every boot. Docker restarts a container that exited but not one that was stopped, and the daily backup
stops four services for a while: after a power cut inside that time they would stay stopped until someone ran `start.sh`.
The unit starts stopped containers and creates missing ones, and nothing more: it never recreates a container or builds an
image, so a checkout that was pulled but not yet set up is not applied by a reboot (that is `setup.sh`, with its preflights and
the operator lock; a missing image is a job for `setup.sh` or `db:restore-host`). It `Wants=` Docker rather than requiring it, so
restarting Docker (an `apt` upgrade of docker-ce) does not run it again, and the checker and daily units run after it
(`After=<project>-stack.service`), so at boot neither heals nor backs up against containers it is still starting. The unit is
enabled, not started, by `install` (so installing never changes what is running).

**`stop.sh` survives a reboot.** It writes `<state>/config/stopped-by-operator`; `start.sh`, `setup.sh` and `restore.sh` remove it
when they bring the stack up. While the file exists the boot unit does nothing (`ConditionPathExists=!`), the checker does not
self-heal, and `status`, `doctor` and the `start.sh` hint say "stopped by the operator; run start.sh". So a reboot in the middle
of a manual procedure (the Baseline reload, the Major PostgreSQL upgrade, a restore) does not start the stack on an empty or half-replaced
data directory. If you stop the containers some other way, create the file yourself (`touch "$WAREHOUSE_STATE_DIR/config/stopped-by-operator"`).

The timer runs without a Slack webhook too (`--alert-webhook-file off`): the checks still run and record their state,
and the daily backup and retention still run. Only the Slack posts are off. `npm run doctor` warns when the timer is
not installed or not active, when the checker has not run in the last 15 minutes (the age of
`config/watch-state.json`), and when no webhook is stored.

## What it checks

An alert fires after two failing runs in a row (10 minutes), except the event alerts marked "at once".

| Alert | Fires when |
| --- | --- |
| `cpu_high` | CPU use averaged since the previous run is above 80% |
| `memory_high` | Memory use is above 85% |
| `disk_root_low` | `/` has less than 20% free |
| `disk_low:<path>` | Another ext4, xfs or btrfs filesystem has less than 10% free (Docker's own mounts are skipped) |
| `postgres_down` | `pg_isready` fails inside the database container |
| `db_connections_high` | More than 80 client connections (the ceiling is 100) |
| `db_long_transaction` | The oldest open transaction is older than 300 s |
| `db_cache_hit_low` | The cache hit ratio is below 90%, judged only once at least 10,000 blocks were read since the last restart |
| `db_dead_tuples_high` | More than 100,000 dead tuples (consider `VACUUM`) |
| `service_down:<name>` | A service of the default profile is not running, or is unhealthy; the optional `supavisor`, `cups` and `sensor-bridge` only while their container exists (`supavisor` only after `pooler.sh on`); `service_down:gateway-lan` only while the LAN fallback is on (`COMPOSE_PROFILES` lists `lan`) |
| `service_healed:<name>` | The checker started or restarted that service itself, or has done so 6 times in 24 hours and stopped (see "Self-healing"; at once; stays for an hour, or while it is stopped trying) |
| `container_oom:<name>` | A container was killed for lack of memory (at once; stays for an hour) |
| `container_restarts:<name>` | More than 3 restarts in the last hour |
| `container_memory:<name>` | A container uses 90% or more of its memory limit |
| `api_down` | The gateway does not answer `get-public-config` on this host |
| `public_https_down` | The public HTTPS address does not answer, or answers as another installation |
| `lan_http_down` | The LAN fallback is on (`LAN_ENABLED=true`) and `http://<LAN address>:<port>/functions/v1/get-public-config` does not answer from this host, answers as another installation, or answers without `X-Warehouse-Path: lan`; or a REST request to `/rest/v1/` with this installation's anon key is refused by the LAN gateway's key check (HTTP 401: the container was not recreated after `rotate-keys.sh`) or does not reach the REST service (5xx) (two failing runs; silent while the fallback is off; see "LAN fallback") |
| `lan_ip_changed` | The LAN fallback is on and the host no longer has the address `LAN_BIND_IP` (the router gave it another one): phones cannot reach the fallback and the `gateway-lan` service is not started; the public path is not affected. Run `bash scripts/lan.sh on auto` |
| `api_error_rate_high` | More than 5% of the gateway's requests in the last 5 minutes were 5xx (judged from 10 requests up) |
| `api_latency_p95_high` | The gateway's p95 latency over the last 5 minutes is above 2 s (same minimum) |
| `api_429_rate_high` | More than 2% of the gateway's requests in the last 5 minutes (judged from 50 requests up), or more than 20 of them, were answered 429 (rate limit): a client, or every phone on one Wi-Fi, is being refused |
| `pdf_renderer_down` | The function runtime cannot reach the PDF renderer |
| `sms_delivery` | Checked every hour: more than 20% of the last 24 hours' sign-in code requests (judged from 10 requests up), or more than 10, or at least half of the last hour's (from 5 requests up), were not accepted by the SMS provider (at once; see "SMS delivery") |
| `break_glass_used` | A break-glass administrator code was made or used in the last 24 hours (at once; see "Break-glass sign-in") |
| `clock_unsynced` | `timedatectl` says the clock is not synchronised, or the host clock is more than 10 s from the clock of the public address's Cloudflare edge |
| `central_key_file` | The central sign-in key file the configuration names is missing or unusable |
| `backup_missing` | No successful backup for 26 hours (or none yet, 26 hours after the first run); never muted |
| `backup_failed` | The last daily backup failed; never muted |
| `usb_backup` | The USB backup is set up and stale or failed; or it still writes readable archives although nobody typed `--no-encrypt` (the installation never reran `sudo bash scripts/backup-usb.sh setup --state <state>` after encryption became the default); or its archives are encrypted and the key copy is not confirmed (no `config/backup-key.escrow`, or one for another key: `bash scripts/backup-key-escrow.sh show`); the same rule as `npm run doctor` |
| `retention_failed` | The last retention clean-up failed |
| `daily_timer_legacy` | The checker unit is from before the daily timer: the backup still runs inside it (at once; never muted; see "Install the timer") |
| `operator_lock_stuck` | A setup or restore (or any command but the daily pass) has held the operator lock for 2 hours or more; the daily pass, 4 hours or more |

While an operator command (setup, backup, restore, stop) holds the lock, the checker judges nothing: those commands stop
services on purpose. The daily pass is the exception, because it takes hours by design: while it holds the lock the checker keeps
running the checks that need none of the services the backup stops (`cpu`, `memory`, `disk`, the database, the backup files and
the break-glass check) and posts their alerts, and leaves the service, gateway and PDF checks and self-healing alone until the
pass is over. The lock counts as stuck after 2 hours, or after 4 hours when the state says the daily pass is the one running
(the daily unit's own time limit; a pass the state still calls running after 4 hours is taken as cut short). A stuck lock turns
every check, but not self-healing, back on.

The gateway rates (`api_error_rate_high`, `api_latency_p95_high`, `api_429_rate_high`) are read from the last 5000 lines of the gateway
log with their time stamps, cut to the last 5 minutes (`docker logs --since` is not used: on one Docker 29 host it returned nothing for
any window up to an hour). While the LAN fallback is on, the `gateway-lan` log (the same format) is read the same way and its requests
are counted in the same rates, so a phone that is refused on the warehouse network shows up here too.

### LAN fallback

The two alerts above are silent while `LAN_ENABLED` is not `true` (an alert left from before `bash scripts/lan.sh off` is cleared at the
next run). `lan_ip_changed` is the usual one after a power cut: Docker cannot publish the container on an address the host no longer
has, so `scripts/compose.sh` leaves the `lan` profile out of the command (`start.sh` and the boot unit still bring the public services
up), `service_down:gateway-lan` is not raised (the service is not expected without the profile), and this alert says what happened.
Repair: `bash scripts/lan.sh on auto`, and give the host a DHCP reservation. `lan_http_down` with the address still on the host means
the container is stopped or unhealthy (`bash scripts/lan.sh status`, `bash scripts/compose.sh --profile lan logs --tail 50 gateway-lan`),
or, when its text says the listener "refuses the anon key of this installation", that the container holds the keys from before a
`rotate-keys.sh` (the public-configuration probe has no key check and stays green, which is why the REST probe exists): recreate it with
`bash scripts/compose.sh --profile lan up -d --force-recreate --no-deps gateway-lan`. `service_down:gateway-lan` is an alert here, but
`doctor --local` (what `start.sh`, `setup.sh`, `upgrade.sh`, `restore.sh` and `rotate-keys.sh` end with) shows the same fault as a
warning only: a fault of the fallback never stops them.
See [TROUBLESHOOTING.md](TROUBLESHOOTING.md#the-app-says-the-lan-address-is-unreachable) and
[OPERATOR_INSTALL.md](OPERATOR_INSTALL.md#lan-fallback-plain-http-on-the-warehouse-network).

## SMS delivery and the clock

`sms_delivery` reads `public.otp_verifications` every hour. Every code request ends as `accepted` (MSG91 took it) or `failed`
(MSG91 refused it: balance used up, DLT header or template rejected, wrong sender ID; or the request expired), and a request
that is still `sending` after 5 minutes never got an answer. All of those count as "not accepted"; requests younger than
5 minutes are left out. Two rules: more than 20% of the last 24 hours' requests (from 10 requests up) or more than 10 of them, and
at least half of the last hour's (from 5 requests up), so a balance that lapses during the Monday sign-in wave is told in the hour.
The alert fires at once (its next judgement is an hour away) and clears at the next hourly check. It sees
refusals and lost answers. It does **not** see a code MSG91 accepted and the telecom operator then dropped (a DLT suspension
after acceptance): that shows as users saying no code arrives, and the cure is in the MSG91 console
([TROUBLESHOOTING.md](TROUBLESHOOTING.md#sms-codes-not-arriving)). There is no balance check: MSG91's balance endpoint needs
a key with more rights than the sending key.

`clock_unsynced` compares two things: systemd's own verdict (`timedatectl show -p NTPSynchronized`) and the difference between
the host clock and the clock of the facility's public address. The reference is the `ts=` line of `<public address>/cdn-cgi/trace`,
which the Cloudflare edge answers itself: the request never reaches the gateway (no log line, no rate-limit budget), and the
answer does not come from this host's clock. An address that is not behind Cloudflare has no such page; the check then uses the
`Date` header of an HTTPS `HEAD` to the function route, which the gateway may pass through from this host (it then shows a wrong
clock less well). Central sign-in
refuses a token when the host clock is more than 30 s off, so 10 s is the warning. When the public address does not answer,
only the first part is judged. Fix: `timedatectl set-ntp true`; if `NTPSynchronized` stays `no`, check that the host can reach
its time servers.

## Break-glass sign-in

`scripts/break-glass-admin.sh` (migration 126) prints a one-time sign-in code for an administrator while SMS does not work. Making
a code and signing in with one each write a row to `public.audit_log` (`table_name` `break_glass`, `action` `CODE_ISSUED` or
`SIGN_IN`; the code itself is never written). It is a way past the SMS code, so `break_glass_used` fires **at once** when such a
row is younger than 24 hours, and stays until the last one is a day old. The alert names the actions and the time of the latest
row, not the number. If it was you or your staff, nothing is wrong; if not, a person with shell access to the host did it: look
at `select created_at, action, user_id, ip_address from public.audit_log where table_name = 'break_glass' order by created_at desc`
(as `supabase_admin`, through `bash scripts/compose.sh exec db psql -U supabase_admin -d postgres`), end the sessions of that
administrator, and change who has access to the host. A database without migration 126 has no such rows, so the check passes.

## Self-healing

Each run, while no operator command holds the lock, the checker looks at the services of the default profile:

- a service that is `exited`, or `created` (a power cut during `up`), is started again
  (`compose up -d --no-build --no-recreate --no-deps --pull never <service>`: that one container, nothing built, pulled or recreated,
  none of its dependencies touched);
- a service that is `unhealthy` for 3 runs in a row (15 minutes) is restarted (`compose restart <service>`), except the
  database: a database in crash recovery also reports unhealthy, and a restart only begins the recovery again.

At most once an hour per service and **at most 6 times in any 24 hours**: after that the checker stops, and `service_healed:<name>`
says "it needs a person" until the service is back (a service that never recovers is not restarted for ever). The action is
reported as the alert `service_healed:<name>`. Nothing is done to a
service whose `service_down:<name>` alert is muted: **mute before a planned stop of one service**, as before a `stop.sh`
(`stop.sh` removes the containers, which the checker never recreates). Nothing is done while `config/stopped-by-operator` exists
(see "Install the timer"). The checker never recreates a container, so a
changed compose file or image is applied only by `setup.sh`. The optional `supavisor`, `cups` and `sensor-bridge` are left
alone.

## How alerts behave

- An alert is posted once when it starts, again every 4 hours while it keeps firing, and once when it clears. New alerts
  of one run go out as one message.
- Once a day, after 09:00 local time, one "Monitoring is alive" message says how many alerts are firing. **A day
  without that message means monitoring is down**: the timer, the host or the webhook (revoked, channel deleted).
- If Slack does not accept a post, it is tried again at the next run; `status` shows the last failure.
- Nothing printed or posted carries a secret: passwords, tokens, database URLs and the webhook are replaced by `[REDACTED]`.

## The daily backup, verify, prune and retention

Once a day, inside the 6 hours after the chosen time, and only while the database and the services the backup stops
(`gateway`, `functions`, `rest`, `storage`) are up, `watch.mjs daily` runs `scripts/watch-daily.sh` under one operator lock:
`scripts/backup.sh`, then `scripts/verify-restore.sh` on that backup, then it prunes older backups, then
`scripts/retention.sh apply`. **Pruning and retention do not wait for the backup or its verify**: they run after every attempt,
also when the backup was refused for lack of free space (the very night the disk needs them) or failed its verify. Only a
database that is not running or not healthy ends the pass before them (nothing was tried that day). The PDF renderer, a stopped or unhealthy `cups` or `sensor-bridge`, and a pooler that was stopped
on purpose do not hold the backup back; a pooler that runs but is unhealthy does (the backup restarts it and waits for it).
A pass that a power cut or a kill cut short is recognised at the next trigger (the operator lock is free while the state still
says "running") and made again at once. The daily timer
fires at the chosen time and at each of the 5 hours after it: a trigger with nothing to do (the day is done, or the last
attempt was under an hour ago) exits at once, and a pass that failed or found the services down is tried again at the next
one. At most 3 times a day. Pruning keeps the newest 7 backup directories of this installation in `<state>/backups` (backups made
by hand there, with the same name pattern and instance, count towards the 7) and removes nothing if a backup is dated in
the future. **On top of the 7 it always keeps the newest backup that passed its verify**, however old, and never removes the one just
made. A backup counts as verified when `verify-restore.sh` passed on it: the pass then writes its name and the time to
`<state>/config/backups-verified.list` (one `name epoch` line per backup, mode 0600; the lines of backups that no longer exist
are dropped). So a run of nights whose backup or verify fails cannot push the last good backup out of the 7, and a bad week
does not leave the disk with seven unchecked copies and nothing known to restore. **It also keeps the backup of an interrupted
`upgrade.sh`** (the one `config/upgrade-in-progress` names as the way back; the prune line says "kept ..., the backup of the
interrupted upgrade"), so the nightly backups cannot push it out while the upgrade waits to be finished or undone. The newest backup
verified within the last two days is also the one the next night's backup links its photos from; when none is that recent (nights
whose verify keeps failing), it links from the newest backup that passes its signature check instead, so the same new photos are not
copied again every night ([OPERATOR_INSTALL.md](OPERATOR_INSTALL.md#backup-and-restore)). If nothing has been verified yet
(the list is empty until the first night that passes, for example right after an update to this release), the newest 7 are
kept, as before. When pruning is cut short, the backups that were never verified and are older than the newest verified one are
removed first; a backup that was half removed is finished at the next pass.
The daily status line (`node scripts/watch.mjs status`) shows what ran even on a night that failed: `Daily backup` carries the
failure, and when the verify failed it names the verified backup that is kept ("… verification failed (the newest verified backup,
warehouse-…, is kept): <reason>"); `Daily retention` says whether pruning and retention ran, how many old backups pruning removed and
anything else pruning had to say. A backup that went ahead with something to report carries it on a verified night's line: stored files
re-copied from a damaged earlier copy, or free space read with `stat -f` because `df` gave no number. A backup refused for
lack of space (or because the free space could not be read at all) is reported by `backup_failed` with the numbers
([TROUBLESHOOTING.md](TROUBLESHOOTING.md#backup-usb-drive-and-restore), "backup refused: not enough free space"). The USB
backup drive is separate: it keeps its own newest three archives ([OPERATOR_INSTALL.md](OPERATOR_INSTALL.md#usb-backup-drive)).

### USB run and the checker

A USB backup run holds the operator lock from the moment it starts writing until it ends (it hashes every archive on the drive, checks
the restore of the newest, and prunes). For that time the 5-minute checker finds the lock held and **skips all its checks**: it pings
the external heartbeat but judges nothing and alerts on nothing, and it does not self-heal. A run is normally minutes; with 20 GB of
photos, three archives kept and a USB 2.0 stick it can take about an hour, and a slow stick longer. This is accepted: it is no
different from a `setup.sh` or a restore. `operator_lock_stuck` fires when a command other than the daily pass has held the lock
for **2 hours** (the 4-hour limit is the daily pass's own), so a very slow drive can raise it; the alert clears when the run ends.
If a run really hangs, the unit's own limit (6 hours) ends it.

## Mute and unmute

```bash
node scripts/watch.mjs mute 60                # silence every alert for 60 minutes (1 to 20160)
node scripts/watch.mjs mute 60 "service_down:rest"   # one alert only
node scripts/watch.mjs unmute                 # end all mutes
node scripts/watch.mjs unmute "service_down:rest"
```

**Mute before a planned `stop.sh`**: the checker keeps running while the services are stopped and reports each stopped
service as an alert. `stop.sh` says so when it finishes. The commands need `WAREHOUSE_STATE_DIR`.

**`backup_missing`, `backup_failed` and `daily_timer_legacy` are never muted.** A mute, whole or of one alert, covers every other alert; these
are posted anyway, and `mute 60 backup_missing` is refused. They are the only warning that the data is not being saved (or that
the backup hangs on an out-of-date unit), and a
week-long mute while a service was being repaired must not hide it. The daily "Monitoring is alive" message says so whenever
a mute is active.

## Status and testing

```bash
node scripts/watch.mjs status          # what is firing, muted, the daily jobs and whether a pass is running, the time zone, the last Slack failure
node scripts/watch.mjs run             # one pass of the checks now (what the 5-minute timer does)
node scripts/watch.mjs daily           # the daily pass, if the window is open and today's is not done (what the daily timer does)
node scripts/watch.mjs test-message    # post a test message to the stored webhook
```

The window of `daily` is computed from `WAREHOUSE_WATCH_DAILY_AT`, which only the unit sets: to run the pass now with the installed
time, use `sudo systemctl start --no-block <project>-daily.service` and read it with `journalctl -u <project>-daily.service`.

`test-message` prints the HTTP status Slack answered and exits 0 only for a 2xx. Keep the evidence that a real message
arrived before relying on alerts.

## Alert delivery

Each facility creates its own Slack incoming webhook (Slack: Apps, Incoming Webhooks) and gives the URL to whoever
installs it. `setup.sh --operator` needs it:

- **On a terminal**, without `--alert-webhook-file`, setup asks for the URL (nothing is echoed; a URL that is not
  `https://hooks.slack.com/services/...` is refused, three tries), posts a test message **before anything is stored**,
  and stores the URL only after that. A rerun that already has a stored URL asks nothing.
- **`--alert-webhook-file ask`** forces the prompt on a rerun and replaces the stored URL.
- **`--alert-webhook-file PATH`** reads the URL from a private file (mode 0600, owned by the installing user, outside the
  checkout, one line). Create it without the URL entering the shell history: `install -m 600 /dev/null FILE` and an editor.
- **Without a terminal and without the option**, setup refuses.
- **`--alert-webhook-file off`** is for a non-production install: setup warns, removes any stored URL, and the checker
  records alerts without posting them. `npm run doctor` warns `No Slack webhook` on every run.

The URL is stored at `config/slack-webhook-url` in the state (mode 0600; never in git, a log, an environment variable or a
command line). The URL is not in a backup, so after `db:restore-host` run setup again to give it back. It is a secret
that `rotate-keys.sh` does not change
([OPERATOR_INSTALL.md](OPERATOR_INSTALL.md#secrets-that-rotate-keys-does-not-change)).

## External heartbeat (the dead-man switch)

The checker cannot tell anyone that it has died. For that, give it the address of a dead-man switch: a service that expects
a ping every few minutes and alerts (by email, SMS or its own app) when the pings stop. healthchecks.io is one (create a
check with a 10 minute period and a 5 minute grace time); any address that does this works. Put the https URL it gives you in
a private file:

```bash
install -m 600 /dev/null "$WAREHOUSE_STATE_DIR/config/heartbeat-url"
$EDITOR "$WAREHOUSE_STATE_DIR/config/heartbeat-url"      # one line: the https URL
```

At the end of each successful 5-minute run the checker fetches that URL (a GET with a 5 second limit); it does so also when
an operator command holds the lock (the checker is alive then). A run that fails before it has saved its state sends no ping,
which is the point. If the ping itself fails, or the file is not mode 0600 and a single https URL, the reason is written to
the log (`journalctl -u <project>-watch.service`) and `node scripts/watch.mjs status` shows `External heartbeat: not sent`; it
is never an alert, because Slack may be what is down. The URL is a secret (anyone who knows it can fake the ping), is not in
backups, and has to be put back after `db:restore-host`. The daily "Monitoring is alive" Slack line stays: it covers a
checker that runs but cannot reach Slack the other way round.

## Finding a slow query

The database logs every statement slower than 1 second (and every temporary file of 10 MB or more), with its text and no
parameter values; connections are not logged. The log is the `db` container's, 3 x 10 MB, and starts empty when the container is
recreated. To see the slow ones of the last day, newest last:

```bash
bash scripts/compose.sh logs --since 24h db | grep -A2 'duration:'
```

A line reads `duration: 1523.419 ms  execute <unnamed>: SELECT ... WHERE id = $1`. `$1` stays `$1` on purpose (a value could be a
sign-in code). The same statements, summed, are in `pg_stat_statements` (`bash scripts/compose.sh exec db psql -U supabase_admin -d
postgres -c "SELECT calls, round(total_exec_time) AS ms, left(query, 80) FROM pg_stat_statements ORDER BY total_exec_time DESC LIMIT 10"`).
The API roles are cut off by the database itself: `anon` after
3 seconds, `authenticated` after 8 (an answer with `canceling statement due to statement timeout`; [CONTAINER_SECURITY.md](CONTAINER_SECURITY.md#database-roles)).

## What it does not cover

There is no metric history and no dashboard: the checker keeps only its state (`config/watch-state.json`,
`config/watch-mutes.json`) and the last backup and retention results (`config/watch-backup.last`,
`config/watch-retention.last`). Not covered: the Cloudflare tunnel process (the public-address check sees its effect),
certificate expiry, a code the SMS provider accepted but never delivered, application errors. Email and paging are not supported by this repository.
