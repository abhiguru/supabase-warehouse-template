# Local monitoring profile

The monitoring profile is loopback-only and optional. It validates local metric
collection and Alertmanager ingestion without contacting an external provider.

```bash
export WAREHOUSE_PROJECT_NAME=warehouse-local-readiness
npm run test:monitoring
```

The check validates Prometheus and Alertmanager configuration, starts the owned
profile, waits for all five scrape targets, submits a synthetic alert, and proves
that Alertmanager retained it. The 2026-09-22 run validated 15 rules and these
targets: Prometheus, PostgreSQL exporter, node exporter, cAdvisor, and Kong.

## Loopback endpoints

The generated `docker/.env` controls the host ports. Defaults are:

| Service | Default endpoint | Purpose |
|---|---|---|
| Grafana | `http://127.0.0.1:13001` | Local dashboards |
| Prometheus | `http://127.0.0.1:19095` | Metrics and rules |
| Alertmanager | `http://127.0.0.1:19093` | Local alert ingestion |
| cAdvisor | `http://127.0.0.1:19998` | Container CPU, memory, start-time and OOM metrics |

Node and PostgreSQL exporters are available only inside the Compose network.
Grafana credentials come from the private generated environment; do not place
them in documentation or source.

## Collected signals

- Host CPU, memory, filesystems and network from node exporter.
- Database availability, connections, transaction duration, cache and dead tuples
  from PostgreSQL exporter.
- Warehouse container CPU, memory, start time and OOM events from cAdvisor.
- Gateway request latency, status and availability from Kong's Prometheus plugin.

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
