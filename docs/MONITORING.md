# Local monitoring profile

The monitoring profile is loopback-only and optional. It validates local metric
collection and Alertmanager ingestion without contacting an external provider.

```bash
export WAREHOUSE_PROJECT_NAME=warehouse-local-readiness
npm run test:monitoring
```

The check validates Prometheus and Alertmanager configuration (including the
19 alert rules and their unit tests), starts the owned profile, waits for all
five scrape targets (Prometheus, PostgreSQL exporter, node exporter, cAdvisor
and Kong), requires that Prometheus holds gateway request metrics
(`kong_http_requests_total`), carries this installation's `installation` label,
holds the containers of this installation and of no other, reads a probe file
from the backup metrics directory, submits a synthetic alert, and proves that
Alertmanager retained it. It needs a state that `setup.sh --operator` has
configured since 2026-10-17 (see [Several installations on one host](#several-installations-on-one-host)).

`npm run test:alert-rules` runs only the rule checks: `promtool` from the
pinned Prometheus image, with no network, on the Prometheus configuration that
setup would render, on `docker/alert-rules.yml` and on every case in
`docker/alert-rules.test.yml`. It needs Docker and no state.

## Endpoints

No monitoring service publishes a host port: Grafana (`grafana:3000`),
Prometheus (`prometheus:9090`), Alertmanager (`alertmanager:9093`), cAdvisor
(`cadvisor:8080`) and the two exporters answer only inside the Compose project.
Reach one from the host with `bash scripts/compose.sh --profile monitoring exec
<service> wget -qO- http://localhost:<port>/...`. An earlier version of this
page listed loopback ports (13001, 19095, 19093, 19998); nothing in the Compose
files ever published them. Grafana credentials come from the private generated
environment; do not place them in documentation or source.

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
| `config/monitoring/alertmanager/alertmanager.yml` (0644) | `docker/alertmanager.yml`, or `docker/alertmanager.webhook.yml` with `--alert-webhook-file` | `alertmanager` (the directory, read-only) |
| `config/monitoring/alertmanager/webhook-url` (0600) | the file given to `--alert-webhook-file` | `alertmanager` (same directory) |
| `metrics/` (0755) | created empty | `node-exporter` (read-only) |

What the rendered Prometheus file does:

- `external_labels: {installation: <WAREHOUSE_PROJECT_NAME>}`. Prometheus adds
  the label to every alert it sends, so a receiver that serves several
  installations can tell them apart (`warehouse-4f2a9c1b3d7e`, the project name
  in the state's `compose.env`). Prometheus v3.15.0 expands `${VAR}` in external
  labels without a feature flag (the old `--enable-feature=expand-external-labels`
  is an unknown option there); the label is nevertheless written into the file,
  because the next item cannot use an environment variable.
- A `keep` rule on the cAdvisor scrape: only the series whose
  `container_label_com_docker_compose_project` is this installation's project
  are stored, plus the series that belong to no container (`machine_*`,
  `cadvisor_version_info`). The container rules therefore see one installation.
  `promtool` cannot show that, because it feeds series straight to the rules;
  `tests/monitoring-config.test.mjs` applies the rendered rule to two projects'
  labels, and `npm run test:monitoring` asks the live Prometheus for series of
  any other project.

Rerun `setup.sh --operator` with your usual inputs after updating the checkout
(the normal upgrade) and the files are rendered or refreshed; an unchanged file
is left alone. A start without them stops with Docker's "bind source path does
not exist" for the file, instead of creating an empty directory.

`db:restore-host` never runs setup, so a state it builds has none of these
files. Create them with `node scripts/configure.mjs --state-dir "$WAREHOUSE_STATE_DIR"`
(on an installed state it changes nothing else), then start the monitoring
profile again.

Host-level metrics (CPU, memory, disk from node exporter) are the same for every
installation on a host. Each installation scrapes its own node exporter.

## Alert delivery

By default Alertmanager holds alerts on this host and sends them nowhere
(receiver `local-only`). `npm run doctor` warns while it is running like that.
To send them to a webhook:

1. Put one `https://` address in a private file (mode 0600, owned by the
   installing user, outside the checkout). Do not put it in the repository.
2. Rerun setup with your usual inputs and `--alert-webhook-file /absolute/path/webhook.txt`.
   Setup validates the file, copies the address to
   `config/monitoring/alertmanager/webhook-url` (mode 0600) and renders
   `alertmanager.yml` from `docker/alertmanager.webhook.yml`. A rerun without
   the option keeps the address; `--alert-webhook-file off` removes it and
   returns to the local-only receiver.
3. Alertmanager is replaced by `setup.sh`. It reads the address from the file
   for every notification (`url_file`), so the address is in no environment
   variable, label or configuration text, and runs as the installing user so
   that it can read a 0600 file.

Alertmanager posts its standard JSON for a webhook to the address
([format](https://prometheus.io/docs/alerting/latest/configuration/#webhook_config)):
the alert's labels (including `installation`), annotations, status and
`startsAt`, grouped by alert name. Point it at something that accepts that body:
an automation service, a paging gateway or a chat bridge. A Slack incoming
webhook takes a different body; for that use the structure in
`docker/alertmanager.slack.example.yml` in your private deployment configuration.
Email and paging need the same provider-specific acceptance.

A webhook that is configured is not a webhook that works: send a synthetic alert
and watch it arrive, and keep that evidence, before relying on it.

```bash
bash scripts/compose.sh --profile monitoring exec -T alertmanager wget -qO- \
  --header='Content-Type: application/json' \
  --post-data='[{"labels":{"alertname":"WebhookTest","severity":"warning"},"annotations":{"summary":"delivery test"}}]' \
  http://localhost:9093/api/v2/alerts
```

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
backup failure ([Backup alerts](#backup-alerts)), and any other scrape target
being down (`ScrapeTargetDown`).

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
has neither).

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

## Grafana

The monitoring profile's Grafana (`grafana:3000`, loopback only) provisions one
dashboard, **Warehouse overview**, in the folder "Warehouse Monitoring", from
`docker/volumes/grafana/dashboards/warehouse-overview.json` (mounted read-only at
`/etc/grafana/dashboards`; `allowUiUpdates: false`, so it cannot be saved over
from the screen: edit the file and let Grafana reload it, which takes up to 30
seconds). It is built from the series above and shows PostgreSQL up, client
connections, the longest transaction, gateway requests by status, 5xx ratio and
p95 latency per service, free filesystem space, container memory per Compose
service, backup age by kind, scrape targets and the number of firing alerts.
It names no installation: each installation has its own Grafana and Prometheus.
The datasource it uses is the provisioned Prometheus datasource with the fixed
uid `PBFA97CFB590B2093` (`provisioning/datasources/datasources.yml`).

`npm run test:grafana` (CI job "Grafana plugins and live queries") starts
Grafana with the provisioning and the dashboard mounted, requires the dashboard
to be provisioned and read-only, and runs every panel query through
`/api/ds/query` against a live Prometheus; a rejected query fails the check.

**Grafana alerting is out of scope** (owner decision D11 of 2026-10-17). Alerts
come from Prometheus' rules and leave through Alertmanager; there is no
`provisioning/alerting` directory and none is planned. Do not create alert rules
in the Grafana screen: a rule stored only in Grafana's database is not in the
repository and is lost with the volume.

## Alert delivery boundary

The default `docker/alertmanager.yml` has a local receiver only. Fake webhooks are
not supplied, and a green local test does not prove on-call delivery: see
[Alert delivery](#alert-delivery) for the webhook option and for the evidence to
keep.

The profile does not establish public TLS, authentication for dashboards,
off-host retention, incident ownership, or production SLOs. Keep all host ports
on loopback until those controls are implemented and reviewed.
