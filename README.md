# Supabase Warehouse Template

Work-in-progress source release for a warehouse application. Companion:
[rn-warehouse-template](https://github.com/abhiguru/rn-warehouse-template).

**Not yet runnable end to end.** A fresh-database second pass found that the v0.1.0
schema does not apply and the export omits APIs required by the mobile app.
Read [READINESS.md](docs/READINESS.md) before trying to deploy. Setup/start
deliberately fail before accessing Docker or generating credentials until the
backend export is completed. Earlier "one-command setup" claims were incorrect.

## What you can do now

Use Node.js 22.18+ to run the isolated configuration and authentication checks:

```bash
git clone https://github.com/abhiguru/supabase-warehouse-template.git
cd supabase-warehouse-template
npm ci
npm test
docker compose --env-file .env.example -f docker/docker-compose.yml -f docker/docker-compose.override.yml config --quiet
```

Reproduce the database blocker with Docker Compose v2, Docker, and OpenSSL:

```bash
npm run test:migrations
```

This creates a disposable, network-isolated database, publishes no ports, mounts
no production data, stops on the first SQL error, and removes its own container.
It currently **fails**, as expected for the incomplete export.

With the mobile repository installed alongside this one:

```bash
node scripts/check-mobile-contract.mjs ../rn-warehouse-template
```

This reports missing literal RPC/table/function names from TypeScript syntax,
ignores comments/tests, and exits nonzero on gaps. Name coverage is not proof of
matching parameters, return shapes, SQL validity, security, or runtime behavior.

## Configuration and isolation

Only newly created `docker/.env` files receive fresh secrets. Existing files are
never read or overwritten by the configuration generator. No credentials from
another installation are needed. Automatic rotation is disabled.

The planned local ports are API **18000**, Studio **54325**, database **15433**,
and PDF service **13100**, bound to loopback. These are not the original Supabase
deployment's ports. Compose uses service DNS, not fixed container names or a
fixed subnet. Use `bash scripts/compose.sh ...` for project ownership checks;
`WAREHOUSE_PROJECT_NAME` must start with `warehouse-`.

Once the release gate is satisfied, `setup.sh` will create configuration,
start services, apply migrations transactionally, and run failing health checks.
The migration runner records applied filenames; checksum/concurrent-run
protection and JWT database synchronization still need completion.

For a physical phone on an isolated development LAN, both the backend
`SUPABASE_PUBLIC_URL` and mobile `EXPO_PUBLIC_CONFIG_API_URL` must use the
same phone-reachable address, for example `http://192.0.2.10:18000` (replace
with your actual LAN IP). Binding beyond loopback requires an explicit
`BIND_ADDRESS` change. Do not expose test OTP mode to the internet.

Only `hello` and `get-public-config` are public functions. Other functions
verify JWT signatures; configuration checks active profiles, and PDF/print
operations require an admin/supervisor. The service-role key is server-only.

## Scope and release requirements

The tree contains schema fragments, OTP/custom-JWT code, configuration functions,
sample PDF/IPP code, and Compose definitions. It is **not a complete export of
the original application**. The detailed completion and deployment-security
checklist is in [READINESS.md](docs/READINESS.md). Older architecture/operations
guides describe intended behavior, not tested guarantees.

MIT covers this project's code. [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)
and [LICENSES](LICENSES/) cover bundled upstream material.

## CI status

Definitions in `docs/github-workflows/` are **inactive**. The GitHub credential
used for the initial publication cannot manage workflows. A maintainer with
workflow permission must install them in `.github/workflows/`; no existing
credential needs to be revoked or rotated. The migration, contract, and release
gates must pass before advertising a working release.
