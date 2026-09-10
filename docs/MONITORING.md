# Monitoring Stack

## Enable Monitoring

```bash
docker compose --profile monitoring up -d
```

## Services

| Service | URL | Purpose |
|---------|-----|---------|
| Grafana | http://localhost:3001 | Dashboards and visualization |
| Prometheus | http://localhost:9095 | Metrics collection |
| AlertManager | http://localhost:9093 | Alert routing |
| Node Exporter | :9100 | Host system metrics |
| Postgres Exporter | :9187 | Database metrics |
| cAdvisor | :9998 | Container metrics |

## Grafana Login

Default credentials (change in `.env`):
```
Username: admin
Password: (GRAFANA_ADMIN_PASS from .env)
```

## Metrics Collected

- **System**: CPU, memory, disk, network (node-exporter)
- **Database**: connections, queries, cache hit ratio, dead tuples (postgres-exporter)
- **Containers**: CPU, memory, restarts, OOM events (cAdvisor)
- **API Gateway**: request latency, error rates, throughput (Kong prometheus plugin)

## Alerts

Configured in `docker/alert-rules.yml`:

| Alert | Threshold | Severity |
|-------|-----------|----------|
| HighCPU | >80% for 5m | warning |
| HighMemory | >85% for 5m | warning |
| DiskSpaceLow | <20% free | critical |
| PostgresDown | pg_up == 0 | critical |
| DatabaseConnectionsHigh | >200 | warning |
| SlowQueries | >60s | warning |
| APIHighLatency | p95 >2s | warning |
| APIHighErrorRate | 5xx >5% | warning |
| ContainerOOM | any event | critical |
| ContainerRestarting | >3/hour | warning |

## Slack Integration

Configure webhook URLs in `docker/.env`:
```
SLACK_WEBHOOK_CRITICAL=https://hooks.slack.com/services/...
SLACK_WEBHOOK_DATABASE=https://hooks.slack.com/services/...
SLACK_WEBHOOK_INFRASTRUCTURE=https://hooks.slack.com/services/...
```

Alerts are routed by type to different Slack channels via `docker/alertmanager.yml`.
