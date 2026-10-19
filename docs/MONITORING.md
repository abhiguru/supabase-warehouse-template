# Monitoring and Slack alerts

The monitoring profile is loopback-only and optional. Prometheus collects the
metrics, evaluates the alert rules, and Alertmanager sends the alerts to the
facility's own Slack channel. There are no dashboards: Slack is the only way
alerts leave the host (see [Alert delivery](#alert-delivery)). The check below
validates collection and Alertmanager ingestion without contacting Slack.

```bash
export WAREHOUSE_PROJECT_NAME=warehouse-local-readiness
npm run test:monitoring
```

The check validates Prometheus and Alertmanager configuration (including the
20 alert rules and their unit tests), starts the owned profile, waits for all
five scrape targets (Prometheus, PostgreSQL exporter, node exporter, cAdvisor
and Kong), requires that Prometheus holds gateway request metrics
(`kong_http_requests_total`), carries this installation's `installation` label,
holds the containers of this installation and of no other, reads a probe file
from the backup metrics directory, submits a synthetic alert (kept by Alertmanager, never posted to Slack), and proves that
Alertmanager retained it. It needs a state that `setup.sh --operator` has
configured since 2026-10-17 (see [Several installations on one host](#several-installations-on-one-host)).

`npm run test:alert-rules` runs only the rule checks: `promtool` from the
pinned Prometheus image, with no network, on the Prometheus configuration that
setup would render, on `docker/alert-rules.yml` and on every case in
`docker/alert-rules.test.yml`, and `amtool` from the pinned Alertmanager image
on both Alertmanager files setup can render. It needs Docker and no state.

## Endpoints

No monitoring service publishes a host port: Prometheus (`prometheus:9090`), Alertmanager (`alertmanager:9093`), cAdvisor
(`cadvisor:8080`) and the two exporters answer only inside the Compose project.
Reach one from the host with `bash scripts/compose.sh --profile monitoring exec
<service> wget -qO- http://localhost:<port>/...`. An earlier version of this
page listed loopback ports (13001, 19095, 19093, 19998); nothing in the Compose
files ever published them.

Prometheus is started without `--web.enable-lifecycle`, so no container on its
network can stop or reload it over HTTP. The Prometheus and Alertmanager
services carry a `com.warehouse.config-sha256` label that changes with the
rendered configuration and the alert rules, so `setup.sh` and `start.sh`
(through `scripts/build-images.sh --replace-optional`) replace a running one
whose files changed. Run by hand, `bash scripts/compose.sh --profile monitoring
up -d prometheus alertmanager` does the same.

## Several installations on one host

Several installations can run on one host, each with its own Compose project,
its own Prometheus and its own Alertmanager. cAdvisor reports every container
on the host, so a Prometheus that scraped it unfiltered would hold, and alert
on, the containers of the other installations: until 2026-10-17 one
installation's `ContainerHighMemory` fired for another's containers and for the
identity service's.

`setup.sh --operator` therefore renders, for each installation, from the
templates in `docker/`:

| File in the state directory | Rendered from | Mounted by |
| --- | --- | --- |
| `config/monitoring/prometheus.yml` (0644) | `docker/prometheus.yml` | `prometheus` |
| `config/monitoring/alertmanager/alertmanager.yml` (0644) | `docker/alertmanager.slack.yml` when the installation has a Slack webhook, else `docker/alertmanager.yml` | `alertmanager` (the directory, read-only) |
| `config/monitoring/alertmanager/webhook-url` (0600) | the Slack webhook URL typed at the setup prompt or read from `--alert-webhook-file` | `alertmanager` (same directory) |
| `metrics/` (0755) | created empty | `node-exporter` (read-only) |
| `data/alertmanager/` (0700) | created empty | `alertmanager` (read-write, at `/alertmanager`): silences and the notification log |

What the rendered Prometheus file does:

- `external_labels: {installation: <WAREHOUSE_PROJECT_NAME>}`. Prometheus adds
  the label to every alert it sends, so a receiver that serves several
  installations can tell them apart (`warehouse-4f2a9c1b3d7e`, the project name
  in the state's `compose.env`). Prometheus v3.15.0 expands `${VAR}` in external
  labels without a feature flag (the old `--enable-feature=expand-external-labels`
  is an unknown option there); the label is nevertheless written into the file,
  because the next item cannot use an environment variable.
- A `keep` rule on the cAdvisor scrape, on the labels project and container
  name joined as `project;name` with the regex `<project>;.*|;`: only the
  series of this installation's Compose project are stored, plus the series
  that have neither a project nor a name (`machine_*`, `cadvisor_version_info`,
  the root cgroup). A container that Compose did not start (a `docker run`
  helper or test database) is dropped too, so no container rule, `ContainerOOM`
  included, fires for another installation's or a helper's container.
  `promtool` cannot show that, because it feeds series straight to the rules;
  `tests/monitoring-config.test.mjs` applies the rendered rule to two projects'
  labels, and `npm run test:monitoring` asks the live Prometheus for series of
  any other project.

Rerun `setup.sh --operator` with your usual inputs after updating the checkout
(the normal upgrade) and the files are rendered or refreshed; an unchanged file
is left alone. A start without them stops with Docker's "bind source path does
not exist" for the file, instead of creating an empty directory.

`db:restore-host` never runs setup, but it renders these files for the
restored project itself (`node scripts/monitoring-config.mjs STATE PROJECT`,
the renderer setup uses), so the monitoring profile starts after a lost-host
restore. The Slack webhook URL is a secret and is not in a backup: alerts are
local only until you run `setup.sh --operator` again (it asks for the URL on a
terminal, or takes `--alert-webhook-file`), and restore-host's "Next" list says so.

Alertmanager keeps its silences and notification log in `data/alertmanager`,
so a replacement of the container (every setup that changes its files, every
change of `docker/alert-rules.yml`) keeps them. It is not part of a backup.

Host-level metrics (CPU, memory, disk from node exporter) are the same for every
installation on a host. Each installation scrapes its own node exporter.

## Alert delivery

Alerts go to Slack and nowhere else. Each facility owner creates their own
Slack incoming webhook (in Slack: Apps, Incoming Webhooks, Add to Slack, pick
the channel) and gives the URL to whoever installs the facility.
`setup.sh --operator` needs it:

- **On a terminal**, without `--alert-webhook-file`, setup asks
  `Slack incoming-webhook URL for <company> alerts (create one in Slack: Apps →
  Incoming Webhooks):`. What you type is not shown (text typed before the
  prompt appeared is echoed by the terminal: wait for the prompt). A URL that is
  not `https://hooks.slack.com/services/...` is refused and asked for again, up to
  three times. Then setup asks `Send a test message to Slack now? [Y/n]` and
  posts one short message naming the facility **before anything is stored**.
  If Slack does not accept it (revoked or mistyped URL, wrong workspace) or cannot
  be reached, setup says so with the HTTP status (never the URL) and asks
  `Store this URL anyway? [y/N]`; no means it asks for another URL, within the three
  tries. Nothing is stored after three failures. End of input at a question counts
  as no. A rerun that already has a stored URL asks nothing.
- **`--alert-webhook-file ask`** forces the prompt on a rerun and replaces the
  stored URL (a terminal is required). Use it when the webhook was revoked or the
  channel changed.
- **With `--alert-webhook-file PATH`**, setup reads the URL from that file (mode
  0600, owned by the installing user, outside the checkout, one line). Use this
  for scripted installs. Create the file without the URL entering the shell
  history: `install -m 600 /dev/null /secure/slack-webhook.txt` and then paste
  the URL into it with an editor, or `read -rs URL && printf '%s\n' "$URL" >
  /secure/slack-webhook.txt && unset URL` (the `read` prompt is silent).
- **Without a terminal and without the option**, setup refuses: `--alert-webhook-file
  PATH is required (a file holding the facility's Slack webhook URL), or
  --alert-webhook-file off for a non-production install`.
- **`--alert-webhook-file off`** is for a non-production install. Setup prints a
  warning that alerts stay on this host only, removes any stored URL and renders
  `docker/alertmanager.yml` (a receiver on this host). Monitoring stays optional
  (`bash scripts/compose.sh --profile monitoring up -d`), but `npm run doctor`
  warns `No Slack webhook: alerts are not delivered` on every run while no
  webhook is stored, whether or not monitoring runs.

**With a webhook stored, setup.sh and start.sh start the monitoring services**
(Prometheus, Alertmanager, the Postgres, node and cAdvisor exporters;
`scripts/start-monitoring.sh`), because a Prometheus that never runs sends
nothing. `start.sh` never builds: it starts the images setup built. `stop.sh`
stops them with everything else. A start that fails is a warning, and `npm run
doctor` then reports `Slack webhook stored but monitoring is not running`.

Setup stores the URL at `config/monitoring/alertmanager/webhook-url` (mode 0600,
in the state, never in git, a log, an environment variable or a command line)
and renders `alertmanager.yml` from `docker/alertmanager.slack.yml`:
`slack_configs` with `api_url_file` pointing at that file, `send_resolved: true`,
`group_wait: 30s`, `group_interval: 5m`, `repeat_interval: 4h`. Each message
title names the alert, the company and the installation (`WAREHOUSE_PROJECT_NAME`);
the text lists the firing alerts (summary and description), then a `Resolved:`
section with the alerts of the same group that resolved meanwhile. The preview
text is the title. Alertmanager runs as the installing user so that it can read the
0600 file, and `setup.sh` replaces it when its configuration changes.

To change the webhook later, rerun setup with `--alert-webhook-file ask` or with a
file holding the new URL. The webhook is a secret that `rotate-keys.sh` does not
change; see "Secrets that rotate-keys does not change" in
[OPERATOR_INSTALL.md](OPERATOR_INSTALL.md).

### Watchdog: the daily "monitoring is alive" message

`docker/alert-rules.yml` has an always-firing rule, `Watchdog` (`vector(1)`,
`severity: heartbeat`). Alertmanager routes it to its own Slack receiver,
`slack-heartbeat`, with `repeat_interval: 24h` and `send_resolved: false`, so the
facility's channel gets one message a day titled "Monitoring is alive". The
heartbeat never sends "resolved": when Prometheus dies the Watchdog resolves, and
a resolved message titled "Monitoring is alive" would say the opposite of the
truth. **A day without that message means monitoring is down**: Prometheus,
Alertmanager, the host or the Slack webhook (revoked, channel deleted) has
stopped, and nobody will be told about a failed backup either. Check `bash
scripts/compose.sh --profile monitoring ps`, the Alertmanager log and the webhook
in Slack, then `bash start.sh`. The first message arrives within a minute or so
of the monitoring services starting (30 s of grouping).

A webhook that is configured is not a webhook that works: answer the test
message prompt at setup, and keep the evidence that a real alert arrived before
relying on it. To send a synthetic alert through a running Alertmanager
(this one does reach Slack, after the 30 s group wait):

```bash
bash scripts/compose.sh --profile monitoring exec -T alertmanager wget -qO- \
  --header='Content-Type: application/json' \
  --post-data='[{"labels":{"alertname":"SlackTest","severity":"warning"},"annotations":{"summary":"delivery test"}}]' \
  http://localhost:9093/api/v2/alerts
```

`npm run test:monitoring` sends its own synthetic alert (`WarehouseSynthetic`);
Alertmanager routes that name to a receiver with no integration, so it is kept
(the check reads it back) but never posted to Slack. Email and paging are not
supported by this repository.

## Collected signals

- Host CPU, memory, filesystems and network from node exporter.
- Database availability, connections, transaction duration, cache and dead tuples
  from PostgreSQL exporter.
- Warehouse container CPU, memory, start time and OOM events from cAdvisor.
- Backup time and result from the backup scripts, through node exporter's
  textfile collector ([Backup alerts](#backup-alerts)).
- Gateway request counts by status code and latency per service from Kong's
  Prometheus plugin. The plugin is enabled for every route in `docker/kong.yml`
  with `status_code_metrics` and `latency_metrics`; Kong 3 exports
  `kong_http_requests_total` and `kong_request_latency_ms_bucket` only then.
  Until 2026-10-11 the plugin was loaded but not enabled and the two API rules
  queried Kong 2 names (`kong_http_status`, `kong_latency_bucket`), so they
  could never fire. The names were read from the plugin source in the pinned
  `kong:3.9.3-ubuntu` image; the rules pass `promtool check rules`.

`npm run test:monitoring` (`scripts/monitoring-check.sh`, run by CI's install
job) checks the configuration with `promtool check config`, runs the rule unit
tests in `docker/alert-rules.test.yml` with `promtool test rules`, and requires
live series for the gateway (`kong_http_requests_total`) and for client
connections (`pg_stat_activity_count{backend_type="client backend"}`).

## Alert rules and what they do not cover

`docker/alert-rules.yml` has rules for host CPU, memory and disk (the root
filesystem, and any other ext4/xfs/btrfs filesystem below 10% free), database
availability, connections and long transactions, container memory, restarts
and OOM events, gateway latency, error rate and availability, backup age and
backup failure ([Backup alerts](#backup-alerts)), any other scrape target
being down (`ScrapeTargetDown`), and the `Watchdog` heartbeat
([Alert delivery](#watchdog-the-daily-monitoring-is-alive-message)).

`DatabaseConnectionsHigh` fires when the **client** connections of one
PostgreSQL server (all databases, users, states and applications added up,
`sum by (instance, job)`) stay above 80 for 2 minutes, 80% of the configured
100-connection ceiling. Background workers (autovacuum, WAL writer and the
like) are not counted. Until 2026-10-13 the rule compared each exporter series
on its own; postgres-exporter splits the count by database, state, user,
application, backend type and wait event, so connections spread over several
series (for example 45 active and 45 idle) never fired it. The unit tests in
`docker/alert-rules.test.yml` cover that split and the background workers.

Every rule has a unit test that fires and one that stays quiet
(`docker/alert-rules.test.yml`; `tests/alert-rules.test.mjs` fails when a rule
has neither). `Watchdog` has only the firing case: it never stops.

## Backup alerts

`scripts/backup.sh` (`npm run db:backup`) and `scripts/backup-usb.sh` write
`<state>/metrics/warehouse_backup.prom` after every attempt, through a
temporary file and a rename, so node exporter (textfile collector,
`--collector.textfile.directory`, directory mounted read-only) never reads half
a file:

```
warehouse_backup_last_success_timestamp_seconds{kind="disk"}  Unix time of the last success
warehouse_backup_last_attempt_success{kind="disk"}            1 after a success, 0 after a failure
```

`kind="disk"` is `backup.sh` (also run by the USB backup for its fresh backup),
`kind="usb"` is the copy to the USB drive. A failure keeps the last success
time. The USB script and the disk script share the file: each rewrites its own
lines and carries the other's over. The file holds a kind, a time and 0 or 1,
no paths and no secrets. If it cannot be written the backup still succeeds and
prints a warning.

- **`BackupMissing`** (critical): no successful `disk` backup for 26 hours (a
  daily backup and two hours of slack; owner decision D9 of 2026-10-17), or no
  such series at all (`absent()`: no backup was ever made, the directory is not
  mounted, or node exporter has no textfile collector). It waits 10 minutes
  before firing. Only the disk backup is held to 26 hours, because a USB drive
  is attached when someone attaches it.
- **`BackupFailed`** (warning): the last attempt of a kind (`disk` or `usb`)
  failed; it fires after 5 minutes and stays until an attempt succeeds. A
  backup that stopped because another operator command held the lock did not
  run, so it is not a failure.

There is no separate backup monitor (D9): `BackupMissing` fires through the
same Prometheus and Alertmanager as everything else, and `npm run doctor` still
reports a stale or failed USB backup. If nothing receives alerts, neither
backup alert helps (see [Alert delivery](#alert-delivery)).

`BackupMissing` assumes a backup at least daily. Nothing in this repository
schedules `npm run db:backup` except the USB backup (attaching the enrolled
drive, or its `--daily` timer while the drive stays attached, takes a fresh
backup first). Schedule one with cron or a systemd timer before relying on the
alert, or it fires until you do. An installation that made its last backup
before this change has no metric until the next backup, so `BackupMissing`
fires 10 minutes after Prometheus first sees none; run `npm run db:backup` once
after upgrading.

There is no rule for:

- **The Cloudflare tunnel.** cloudflared runs on the host, outside Compose,
  and is not scraped.
- **Certificate expiry, SMS delivery failures or application errors.**

cAdvisor uses `--docker_only` and enables only CPU, memory and OOM metric groups.
This keeps the local check responsive and avoids scanning unrelated container
filesystems. It still requires privileged host mounts, so a target operator must
review or replace that collector before production use.

## Alert delivery boundary

`docker/alertmanager.yml`, used only with `--alert-webhook-file off`, has a local
receiver only. A green local test does not prove on-call delivery: see
[Alert delivery](#alert-delivery) for the Slack webhook and the evidence to
keep.

The profile does not establish public TLS, off-host retention, incident ownership, or production SLOs. Keep all host ports
on loopback until those controls are implemented and reviewed.
