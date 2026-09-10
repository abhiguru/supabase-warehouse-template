# Supabase Warehouse Template

An open-source, self-hosted Supabase starter for warehouse and cold storage management. Features custom phone OTP authentication, CUPS printing, PDF generation, and an optional monitoring stack.

## Quick Start

```bash
git clone https://github.com/abhiguru/supabase-warehouse-template.git
cd supabase-warehouse-template
./setup.sh
```

That's it. Open http://localhost:54323 for Supabase Studio.

## What's Included

| Feature | Description |
|---------|-------------|
| **Custom Phone OTP Auth** | JWT-based phone authentication without GoTrue dependency |
| **Warehouse Schema** | Customers, GRN, invoices, dispatch, stock tracking |
| **PDF Generation** | HTML-to-PDF via Gotenberg (Chromium-based) |
| **CUPS Printing** | IPP-based print server for receipts and documents |
| **Monitoring** | Prometheus + Grafana + AlertManager with Slack alerts |
| **Edge Functions** | Deno-based serverless functions with router pattern |
| **Connection Pooling** | Supavisor for high-concurrency deployments |
| **API Gateway** | Kong with rate limiting, CORS, and key-auth |

## Architecture

```
┌─────────┐     ┌──────┐     ┌──────┐     ┌────┐
│ Client  │────▶│ Kong │────▶│ REST │────▶│ DB │
└─────────┘     │ :8000│     │:3000 │     │:5432│
                │      │     └──────┘     └────┘
                │      │────▶┌──────────┐
                │      │     │Functions  │──▶ Gotenberg (PDF)
                │      │     │:9000     │──▶ CUPS (Print)
                │      │     └──────────┘
                │      │────▶┌──────────┐
                └──────┘     │ Storage  │
                             │:5000     │
                             └──────────┘
```

**Core containers** (~10): db, kong, rest, studio, storage, imgproxy, meta, functions, vector, gotenberg

**Optional profiles:**
- `printing` — CUPS print server
- `pooler` — Supavisor connection pooler
- `monitoring` — Prometheus, Grafana, AlertManager, exporters

## Usage

```bash
./start.sh              # Start services
./stop.sh               # Stop services
./health-check.sh       # Check all services
./rotate-keys.sh        # Regenerate JWT keys
```

### Enable optional services

```bash
# Printing
docker compose --profile printing up -d

# Monitoring (Grafana at localhost:3001)
docker compose --profile monitoring up -d

# Connection pooler
docker compose --profile pooler up -d
```

### Test the API

```bash
# Hello function
curl http://localhost:8000/functions/v1/hello \
  -H "Authorization: Bearer YOUR_ANON_KEY"

# Generate a PDF
curl -X POST http://localhost:8000/functions/v1/generate-sample-pdf \
  -H "Authorization: Bearer YOUR_ANON_KEY" \
  -H "Content-Type: application/json" \
  -d '{"title": "My Report"}' --output report.pdf
```

## Custom OTP Authentication

This template replaces Supabase's GoTrue with a custom phone OTP system:

1. Client calls `send_otp(phone_number)` RPC
2. Server generates OTP, sends via Twilio/MSG91 (or returns test OTP in dev mode)
3. Client calls `verify_otp_or_register(phone, otp_code)` RPC
4. Server validates OTP, creates/finds user, returns JWT token
5. Client uses JWT for all subsequent API calls

**Test mode** (default): OTP is always `123456`, no SMS sent.

See [docs/CUSTOM_AUTH.md](docs/CUSTOM_AUTH.md) for details.

## Environment Variables

All configuration is in `.env.example` (~70 variables), organized by group:
- Database, JWT & Auth, API Gateway, Studio, Edge Functions
- SMS Provider (Twilio/MSG91), CUPS Printing, Monitoring
- Slack Webhooks, Feature Flags

Run `./setup.sh` to auto-generate all secrets.

## Project Structure

```
├── setup.sh                  # One-command bootstrap
├── start.sh / stop.sh        # Service management
├── health-check.sh           # Health verification
├── rotate-keys.sh            # JWT key rotation
├── .env.example              # All env vars documented
├── docker/
│   ├── docker-compose.yml    # Core services
│   ├── docker-compose.override.yml  # Tuning + monitoring
│   ├── kong.yml              # API gateway config
│   ├── prometheus.yml        # Metrics collection
│   ├── alertmanager.yml      # Alert routing
│   └── cups/                 # Print server
├── functions/
│   ├── main/                 # Edge function router
│   ├── _shared/              # Auth, CORS, Gotenberg, IPP helpers
│   ├── hello/                # Health check function
│   ├── get-config/           # Dynamic config endpoint
│   ├── generate-sample-pdf/  # PDF generation demo
│   └── print-via-ipp/        # CUPS printing
├── migrations/
│   └── 00000000000000_initial_schema.sql
├── config/
│   └── seed-config.sql
└── docs/
    ├── ARCHITECTURE.md
    ├── CUSTOM_AUTH.md
    ├── PRINTING.md
    ├── MONITORING.md
    ├── PDF_GENERATION.md
    └── PRODUCTION_CHECKLIST.md
```

## Requirements

- Docker 24+ with Compose v2
- 4GB RAM minimum (8GB recommended)
- 10GB disk space
- `openssl` (for key generation)

## License

MIT — see [LICENSE](LICENSE).
