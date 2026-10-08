# Architecture

## Container Diagram

```
                    ┌─────────────────────────────────────────────────┐
                    │                  Docker Network                  │
                    │                  172.20.0.0/24                   │
                    │                                                 │
 Client ──────────▶ │  ┌────────────────────┐                        │
                    │  │ Kong (.2)          │                         │
                    │  │ API Gateway :8000  │                         │
                    │  └──┬──┬──┬──┬──┬────┘                         │
                    │     │  │  │  │  │                               │
                    │     │  │  │  │  └──▶ Studio (.15) :3000        │
                    │     │  │  │  └─────▶ Meta (.14) :8080          │
                    │     │  │  └────────▶ Storage (.11) :5000       │
                    │     │  └───────────▶ Functions (.12) :9000     │
                    │     └──────────────▶ REST (.10) :3000          │
                    │                          │                      │
                    │                          ▼                      │
                    │                    ┌──────────┐                 │
                    │                    │ DB (.3)  │                 │
                    │                    │ PG :5432 │                 │
                    │                    └──────────┘                 │
                    │                                                 │
                    │  Optional:                                      │
                    │  ┌─────────────┐ ┌──────────┐ ┌─────────────┐ │
                    │  │ Gotenberg   │ │ CUPS     │ │ Prometheus  │ │
                    │  │ (.24) :3000 │ │ (.23)    │ │ + Grafana   │ │
                    │  └─────────────┘ │ :631     │ │ monitoring  │ │
                    │                  └──────────┘ └─────────────┘ │
                    └─────────────────────────────────────────────────┘
```

## Request Flow

### API Request (PostgREST)
```
Client → Kong :8000 → PostgREST :3000 → PostgreSQL :5432
         (key-auth)   (JWT verify)       (RLS enforced)
```

### Edge Function Request
```
Client → Kong :8000 → Edge Runtime :9000 → Worker (Deno V8 isolate)
         (CORS)       (JWT verify)          → PostgreSQL (direct)
                                            → Gotenberg (PDF)
                                            → CUPS (print)
```

### OTP Authentication
```
Client → Kong → PostgREST → send_otp() → Twilio/MSG91
Client → Kong → PostgREST → verify_otp_or_register() → JWT token
Client → Kong (with JWT) → PostgREST → Data (RLS enforced)
```

## Static IP Assignments

| Service | IP | Port |
|---------|-----|------|
| Kong | 172.20.0.2 | 8000 |
| DB | 172.20.0.3 | 5432 |
| REST | 172.20.0.10 | 3000 |
| Storage | 172.20.0.11 | 5000 |
| Functions | 172.20.0.12 | 9000 |
| Analytics | 172.20.0.13 | 4000 |
| Meta | 172.20.0.14 | 8080 |
| Studio | 172.20.0.15 | 3000 |
| Realtime | 172.20.0.16 | 4000 |
| imgproxy | 172.20.0.20 | 5001 |
| Vector | 172.20.0.21 | - |
| Supavisor | 172.20.0.22 | 5432 |
| CUPS | 172.20.0.23 | 631 |
| Gotenberg | 172.20.0.24 | 3000 |

Static IPs are used to populate Kong's `/etc/hosts` via `extra_hosts`, providing instant DNS resolution and eliminating the 4-second cold-start delay from Kong's internal DNS resolver.
