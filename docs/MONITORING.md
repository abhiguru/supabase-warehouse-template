# Monitoring and Slack alerts

One small program, `scripts/watch.mjs` (the checker), watches an installation. A systemd timer runs it every 5 minutes.
It checks the host, the database, the containers, the gateway and the backups, and tells the facility's own Slack channel
when something is wrong. A second timer runs `watch.mjs daily` once a day: it makes and verifies a backup and applies
retention. The two are separate units, so a long backup never holds the 5-minute checks off and a broken checker does not
stop the backups. There are no dashboards, no metric history and no extra containers: Slack is the only way an alert leaves
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

The command writes four units: `<project>-watch.service` and `.timer` (the 5-minute checks), `<project>-daily.service` and
`.timer` (the daily backup, below) and `<project>-stack.service` (boot, below). The units name the Node.js through a link,
`~/.local/opt/node-current`, that `install` points at the Node.js prefix it was given, not at a versioned directory. After a
Node.js upgrade, unpack the new version, run `sudo bash scripts/watch-timer.sh install --state "$WAREHOUSE_STATE_DIR" --node
<new prefix>/bin/node` (or only `ln -sfn <new prefix> ~/.local/opt/node-current`), then `node scripts/watch.mjs status`. If the
Node.js the units run is gone, `bash scripts/watch-timer.sh status` says `MISSING`, and `start.sh`, `setup.sh` and
`db:restore-host` print the same fix. `npm run doctor` warns when the daily timer is not active.

The boot unit, `<project>-stack.service`, runs `compose up -d` for the default profile after `docker.service`
at every boot. Docker restarts a container that exited but not one that was stopped, and the daily backup stops four
services for a while: after a power cut inside that time they would stay stopped until someone ran `start.sh`. The unit
is enabled, not started, by `install` (so installing never changes what is running). A reboot therefore also undoes a
deliberate `stop.sh`; to keep the stack down after reboots run `sudo systemctl disable <project>-stack.service`. It never
builds an image (`--no-build`): a missing image is a job for `setup.sh` or `db:restore-host`.

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
| `service_down:<name>` | A service of the default profile is not running, or is unhealthy; the optional `supavisor`, `cups` and `sensor-bridge` only while their container exists (`supavisor` only after `pooler.sh on`) |
| `service_healed:<name>` | The checker started or restarted that service itself (see "Self-healing"; at once; stays for an hour) |
| `container_oom:<name>` | A container was killed for lack of memory (at once; stays for an hour) |
| `container_restarts:<name>` | More than 3 restarts in the last hour |
| `container_memory:<name>` | A container uses 90% or more of its memory limit |
| `api_down` | The gateway does not answer `get-public-config` on this host |
| `public_https_down` | The public HTTPS address does not answer, or answers as another installation |
| `api_error_rate_high` | More than 5% of the gateway's requests in the last 5 minutes were 5xx (judged from 10 requests up) |
| `api_latency_p95_high` | The gateway's p95 latency over the last 5 minutes is above 2 s (same minimum) |
| `api_429_rate_high` | More than 2% of the gateway's requests in the last 5 minutes (judged from 50 requests up), or more than 20 of them, were answered 429 (rate limit): a client, or every phone on one Wi-Fi, is being refused |
| `pdf_renderer_down` | The function runtime cannot reach the PDF renderer |
| `sms_delivery` | Once a day, after 09:00: more than 20% of the last 24 hours' sign-in code requests (judged from 10 requests up), or more than 10, were not accepted by the SMS provider (at once; see "SMS delivery") |
| `clock_unsynced` | `timedatectl` says the clock is not synchronised, or the host clock is more than 10 s from the public address's `Date` header |
| `central_key_file` | The central sign-in key file the configuration names is missing or unusable |
| `backup_missing` | No successful backup for 26 hours (or none yet, 26 hours after the first run); never muted |
| `backup_failed` | The last daily backup failed; never muted |
| `usb_backup` | The USB backup is set up and stale or failed (the same rule as `npm run doctor`) |
| `retention_failed` | The last retention clean-up failed |
| `operator_lock_stuck` | A setup, backup or restore has held the operator lock for 2 hours or more |

While an operator command (setup, backup, restore, stop) holds the lock, the checker judges nothing: those commands stop
services on purpose.

## SMS delivery and the clock

`sms_delivery` reads `public.otp_verifications` once a day. Every code request ends as `accepted` (MSG91 took it) or `failed`
(MSG91 refused it: balance used up, DLT header or template rejected, wrong sender ID; or the request expired), and a request
that is still `sending` after 5 minutes never got an answer. All of those count as "not accepted"; requests younger than
5 minutes are left out. The alert fires at once (its next judgement is a day away) and clears at the next daily check. It sees
refusals and lost answers. It does **not** see a code MSG91 accepted and the telecom operator then dropped (a DLT suspension
after acceptance): that shows as users saying no code arrives, and the cure is in the MSG91 console
([TROUBLESHOOTING.md](TROUBLESHOOTING.md#sms-codes-not-arriving)). There is no balance check: MSG91's balance endpoint needs
a key with more rights than the sending key.

`clock_unsynced` compares two things: systemd's own verdict (`timedatectl show -p NTPSynchronized`) and the difference between
the host clock and the `Date` header of an HTTPS `HEAD` to the facility's public address (Cloudflare's clock). Central sign-in
refuses a token when the host clock is more than 30 s off, so 10 s is the warning. When the public address does not answer,
only the first part is judged. Fix: `timedatectl set-ntp true`; if `NTPSynchronized` stays `no`, check that the host can reach
its time servers.

## Self-healing

Each run, while no operator command holds the lock, the checker looks at the services of the default profile:

- a service that is `exited` is started again (`compose up -d --no-recreate <service>`);
- a service that is `unhealthy` for 3 runs in a row (15 minutes) is restarted (`compose restart <service>`), except the
  database: a database in crash recovery also reports unhealthy, and a restart only begins the recovery again.

At most once an hour per service, and the action is reported as the alert `service_healed:<name>`. Nothing is done to a
service whose `service_down:<name>` alert is muted: **mute before a planned stop of one service**, as before a `stop.sh`
(`stop.sh` removes the containers, which the checker never recreates). The checker never recreates a container, so a
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
(`kong`, `functions`, `rest`, `storage`) are up, `watch.mjs daily` runs `scripts/watch-daily.sh` under one operator lock:
`scripts/backup.sh`, then `scripts/verify-restore.sh` on that backup, then it prunes older backups, then
`scripts/retention.sh apply`. An unhealthy optional service or the PDF renderer does not hold the backup back. The daily timer
fires at the chosen time and at each of the 5 hours after it: a trigger with nothing to do (the day is done, or the last
attempt was under an hour ago) exits at once, and a pass that failed or found the services down is tried again at the next
one. At most 3 times a day. Pruning keeps the newest 7 backup directories of this installation in `<state>/backups` (backups made
by hand there, with the same name pattern and instance, count towards the 7) and removes nothing if a backup is dated in
the future. Retention runs only after a verified backup. The USB backup drive is separate
([OPERATOR_INSTALL.md](OPERATOR_INSTALL.md#usb-backup-drive)).

## Mute and unmute

```bash
node scripts/watch.mjs mute 60                # silence every alert for 60 minutes (1 to 20160)
node scripts/watch.mjs mute 60 "service_down:rest"   # one alert only
node scripts/watch.mjs unmute                 # end all mutes
node scripts/watch.mjs unmute "service_down:rest"
```

**Mute before a planned `stop.sh`**: the checker keeps running while the services are stopped and reports each stopped
service as an alert. `stop.sh` says so when it finishes. The commands need `WAREHOUSE_STATE_DIR`.

**`backup_missing` and `backup_failed` are never muted.** A mute, whole or of one alert, covers every other alert; these two
are posted anyway, and `mute 60 backup_missing` is refused. They are the only warning that the data is not being saved, and a
week-long mute while a service was being repaired must not hide it. The daily "Monitoring is alive" message says so whenever
a mute is active.

## Status and testing

```bash
node scripts/watch.mjs status          # what is firing, muted, the daily jobs, the time zone, the last Slack failure
node scripts/watch.mjs run             # one pass of the checks now (what the 5-minute timer does)
node scripts/watch.mjs daily           # the daily pass now, if the window is open and today's is not done (what the daily timer does)
node scripts/watch.mjs test-message    # post a test message to the stored webhook
```

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
