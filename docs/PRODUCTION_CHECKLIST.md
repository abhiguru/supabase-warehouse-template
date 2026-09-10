# Production Checklist

## Before Going Live

### Security
- [ ] Run `./rotate-keys.sh` to generate production JWT keys
- [ ] Change `DASHBOARD_PASSWORD` to a strong password
- [ ] Change `GRAFANA_ADMIN_PASS`
- [ ] Change `CUPS_ADMIN_PASSWORD`
- [ ] Set `FUNCTIONS_VERIFY_JWT=true`
- [ ] Set `SMS_PRODUCTION_MODE=true`
- [ ] Configure real SMS provider credentials (Twilio or MSG91)
- [ ] Bind all ports to `127.0.0.1` (use reverse proxy for external access)
- [ ] Set up SSL/TLS termination (Cloudflare Tunnel, nginx, or Caddy)
- [ ] Set `.env` file permissions to `600`

### Database
- [ ] Change `POSTGRES_PASSWORD` to a strong password
- [ ] Enable SSL for database connections
- [ ] Set up automated backups (pg_dump + cron)
- [ ] Configure WAL archiving for point-in-time recovery
- [ ] Review and test RLS policies

### Monitoring
- [ ] Enable monitoring profile: `docker compose --profile monitoring up -d`
- [ ] Configure Slack webhook URLs for alerts
- [ ] Set up Grafana dashboards
- [ ] Test alert routing (fire a test alert)

### Performance
- [ ] Adjust `shared_buffers` in override (25% of available RAM)
- [ ] Adjust `effective_cache_size` (75% of available RAM)
- [ ] Set `PGRST_DB_POOL` based on expected concurrency
- [ ] Enable connection pooler if >50 concurrent users

### Operations
- [ ] Set up log rotation (configured in override, verify)
- [ ] Set up health check cron job
- [ ] Document runbook for common issues
- [ ] Test `./stop.sh` and `./start.sh` recovery
- [ ] Set up systemd service for auto-start on boot

## Reverse Proxy Setup

### Cloudflare Tunnel (recommended)
```bash
cloudflared tunnel create my-warehouse
cloudflared tunnel route dns my-warehouse api.example.com
cloudflared tunnel run --url http://localhost:8000 my-warehouse
```

### nginx
```nginx
server {
    listen 443 ssl;
    server_name api.example.com;

    location / {
        proxy_pass http://127.0.0.1:8000;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
```
