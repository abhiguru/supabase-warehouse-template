# Monitoring and Slack alerts

One small program, `scripts/watch.mjs` (the checker), watches an installation. A systemd timer runs it every 5 minutes.
It checks the host, the database, the containers, the gateway and the backups, tells the facility's own Slack channel
when something is wrong, and once a day makes and verifies a backup and applies retention. There are no dashboards, no
metric history and no extra containers: Slack is the only way an alert leaves the host.

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

It writes a second unit, `<project>-stack.service`, that runs `compose up -d` for the default profile after `docker.service`
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
| `pdf_renderer_down` | The function runtime cannot reach the PDF renderer |
| `central_key_file` | The central sign-in key file the configuration names is missing or unusable |
| `backup_missing` | No successful backup for 26 hours (or none yet, 26 hours after the first run) |
| `backup_failed` | The last daily backup failed |
| `usb_backup` | The USB backup is set up and stale or failed (the same rule as `npm run doctor`) |
| `retention_failed` | The last retention clean-up failed |
| `operator_lock_stuck` | A setup, backup or restore has held the operator lock for 2 hours or more |

While an operator command (setup, backup, restore, stop) holds the lock, the checker judges nothing: those commands stop
services on purpose.

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

Once a day, inside the 6 hours after the chosen time, and only while the database and every service are up, the checker
runs `scripts/watch-daily.sh` under one operator lock: `scripts/backup.sh`, then `scripts/verify-restore.sh` on that
backup, then it prunes older backups, then `scripts/retention.sh apply`. A failed pass is tried again after an hour, at
most 3 times a day. Pruning keeps the newest 7 backup directories of this installation in `<state>/backups` (backups made
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

## Status and testing

```bash
node scripts/watch.mjs status          # what is firing, muted, the daily jobs, the time zone, the last Slack failure
node scripts/watch.mjs run             # one pass now (what the timer does)
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

## What it does not cover

There is no metric history and no dashboard: the checker keeps only its state (`config/watch-state.json`,
`config/watch-mutes.json`) and the last backup and retention results (`config/watch-backup.last`,
`config/watch-retention.last`). Not covered: the Cloudflare tunnel process (the public-address check sees its effect),
certificate expiry, SMS delivery failures, application errors. Email and paging are not supported by this repository.
