# Local monitoring profile

The monitoring profile is loopback-only and optional. It validates local metric
collection and Alertmanager ingestion without contacting an external provider.

```bash
export WAREHOUSE_PROJECT_NAME=warehouse-local-readiness
npm run test:monitoring
```

The check validates Prometheus and Alertmanager configuration (including the
17 alert rules), starts the owned profile, waits for all five scrape targets
(Prometheus, PostgreSQL exporter, node exporter, cAdvisor and Kong), requires
that Prometheus holds gateway request metrics (`kong_http_requests_total`),
submits a synthetic alert, and proves that Alertmanager retained it.

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
network can stop or reload it over HTTP; restart the service to load changed
rules.

## Collected signals

- Host CPU, memory, filesystems and network from node exporter.
- Database availability, connections, transaction duration, cache and dead tuples
  from PostgreSQL exporter.
- Warehouse container CPU, memory, start time and OOM events from cAdvisor.
- Gateway request counts by status code and latency per service from Kong's
  Prometheus plugin. The plugin is enabled for every route in `docker/kong.yml`
  with `status_code_metrics` and `latency_metrics`; Kong 3 exports
  `kong_http_requests_total` and `kong_request_latency_ms_bucket` only then.
  Until 2026-10-11 the plugin was loaded but not enabled and the two API rules
  queried Kong 2 names (`kong_http_status`, `kong_latency_bucket`), so they
  could never fire. The names were read from the plugin source in the pinned
  `kong:3.9.3-ubuntu` image; the rules pass `promtool check rules`.

## Alert rules and what they do not cover

`docker/alert-rules.yml` has rules for host CPU, memory and disk (the root
filesystem, and any other ext4/xfs/btrfs filesystem below 10% free), database
availability, connections and long transactions, container memory, restarts
and OOM events, gateway latency, error rate and availability, and any other
scrape target being down (`ScrapeTargetDown`).

There is no rule for:

- **Backup age or failure.** No backup script writes a metric and
  node exporter runs without a textfile collector, so Prometheus has nothing
  to evaluate. A stale or failed backup is reported by `npm run doctor` and by
  `bash scripts/backup-usb.sh status`. A rule needs the backup scripts to write
  a `warehouse_backup_last_success_timestamp_seconds` file into a directory
  node exporter reads with `--collector.textfile.directory`; neither exists.
- **The Cloudflare tunnel.** cloudflared runs on the host, outside Compose,
  and is not scraped.
- **Certificate expiry, SMS delivery failures or application errors.**

cAdvisor uses `--docker_only` and enables only CPU, memory and OOM metric groups.
This keeps the local check responsive and avoids scanning unrelated container
filesystems. It still requires privileged host mounts, so a target operator must
review or replace that collector before production use.

## Alert delivery boundary

The default `docker/alertmanager.yml` has a local receiver only. Fake webhooks are
not supplied, and a green local test does not prove on-call delivery. To evaluate
Slack separately, copy the structure in
`docker/alertmanager.slack.example.yml` into private deployment configuration,
provide an owned webhook through the deployment's secret manager, send a
synthetic alert, and record receipt/escalation evidence. Email, paging, or another
receiver requires the same provider-specific acceptance.

The profile does not establish public TLS, authentication for dashboards,
off-host retention, incident ownership, or production SLOs. Keep all host ports
on loopback until those controls are implemented and reviewed.
