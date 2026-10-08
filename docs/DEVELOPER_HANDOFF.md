# Contributor guide

Orientation for changing this backend. Operator instructions are in [OPERATOR_INSTALL.md](OPERATOR_INSTALL.md); the README quickstart is the entry point for a new installation.

## Repository layout

- `setup.sh`, `start.sh`, `stop.sh`, `rotate-keys.sh`, `health-check.sh` — operator commands; each takes the per-state lock (`scripts/operator-lock.sh`) before touching Docker.
- `scripts/` — `configure.mjs` (state and config generation), `doctor.mjs` (host preflight, local and external checks), `migrate.sh` + `migration-plan.mjs` (checksummed ledger), `backup.sh` / `verify-restore.sh` / `restore.sh`, `rotate-keys.mjs` + `keys.mjs`, `compose.sh` (project-owned Compose wrapper), `check-mobile-contract.mjs`, and the smoke/check scripts CI runs.
- `migrations/` — numbered SQL applied in order. `functions/` — Deno edge functions. `docker/` — Compose files and digest-pinned image recipes. `deploy/` — cloudflared examples. `config/` — seed SQL.
- `tests/` — node tests (`*.test.mjs`), SQL tests run by `tests/migrations.sh`, and the HTTP/Realtime drivers (`operator-api-*.mjs`, `operator-realtime-core.mjs`, `operator-fixture.mjs`) the CI install job runs against a live instance.

## Running checks

- `npm ci && npm test` — node unit tests; no Docker, no network.
- `bash tests/migrations.sh` — applies every migration twice to a disposable, network-isolated `supabase/postgres` container (the second pass must skip unchanged files) and runs the SQL tests. Needs Docker.
- `for f in *.sh scripts/*.sh tests/*.sh; do bash -n "$f"; done` — shell syntax, as in CI.
- `node scripts/check-mobile-contract.mjs <mobile checkout>` — static name inventory against the app (needs the app's `node_modules`).
- Everything else (`npm run test:gateway`, `test:rotation`, `db:backup`, ...) needs an installed operator state; CI exercises them in the `operator-install` job.

## Migration conventions

- Append-only: add `migrations/000000000000NN_<topic>.sql` with the next number and a leading comment that says what changed and why. Never edit an applied file; the ledger stores checksums and refuses changed files.
- Patch an existing function body with a `DO $$ ... $$` block that reads the current definition, counts the expected marker text, `RAISE EXCEPTION`s when the marker is missing or found more than once, and only then replaces it. A silent no-op is a bug.
- End every migration that changes the API surface with `NOTIFY pgrst, 'reload schema';` as the last statement.
- Grant staff access only through the explicit RPC allowlist and prove each change in `tests/*.sql` with the real guarded RPCs (see `tests/staff_dispatch_invoice_access.sql`), not with a probe that cannot fail.

## CI (`.github/workflows/ci.yml`)

| Job | Proves |
| --- | --- |
| `validate` | `npm test`, the container source dependency audit (`npm run check:container-dependencies`) and shell syntax. |
| `migrations` | `tests/migrations.sh` on a disposable database: idempotent ledger, security baseline, operator auth, staff/customer policies, invoice rules, enrollment status, retention. |
| `contract` | `check-mobile-contract.mjs` against the pinned mobile commit (below). |
| `secrets` | Redacted source and history scan (`scripts/scan-secrets.sh`). |
| `operator-install` | A complete isolated `setup.sh --operator` with fictional inputs: local doctor, key rotation and session revocation, API/document/Realtime/account lifecycle, Studio, gateway (CORS, payload, TLS, upstream IP change), retention preview, load smoke, monitoring, backup with isolated and in-place restore drills, pooler, CUPS, owned-service recovery, and a configuration-preserving rerun. |
| `grafana` (amd64, arm64) | The local Grafana recipe builds, its plugin signatures verify and live Prometheus/PostgreSQL queries answer. |

`release.yml` runs on any `v*` tag: the release readiness gate (`scripts/check-release.sh`), tests, `npm audit` and Compose validation against generated operator state. Publishing a release stays manual.

## Mobile companion pin

`env.MOBILE_REF` at the top of `ci.yml` is the full SHA of the `abhiguru/rn-warehouse-template` commit the `contract` job checks out. When a change here alters an endpoint, response shape or manifest field the app consumes, or when the mobile branch moves: run `node scripts/check-mobile-contract.mjs <mobile checkout>` at the new mobile commit, set `MOBILE_REF` to that 40-character SHA (never a branch or tag), and record the backend/mobile pair in the pull request. Do not merge a backend change that needs a mobile change until the mobile commit exists and the pin points at it.

## Where things are documented

Operator: `OPERATOR_INSTALL.md`, `TROUBLESHOOTING.md`, `MONITORING.md`, `PRINTING.md`. Policy and contracts: `STAFF_GRN_POLICY.md`, `INVOICE_RULES.md`, `API_CONTRACT.md`, `PDF_GENERATION.md`, `TELEMETRY_AND_PRIVACY.md`. Status, security and release: `PRODUCTION_DEPENDENCIES.md`, `RELEASE_CHECKLIST.md`, `CONTAINER_SECURITY.md`, `ATTRIBUTION_REVIEW.md`, `ARCHITECTURE.md`. Past releases and the pilot: `HISTORY.md`.
