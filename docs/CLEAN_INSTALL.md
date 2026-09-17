# Public-clone clean-install verification

> The dated `v0.2.1-demo` evidence below is historical. For the current release,
> use matching `v0.2.2-demo` tags after publication or matching current `main`
> branches during preparation. Record both full SHAs and verify both backend CI
> workflow copies pin the mobile SHA before applying this isolation procedure.

## Evidence — 2026-09-12

Fresh unauthenticated HTTPS clones were tested at these exact commits:

- Backend: `c4ca1dec911b23f259315dee1154ef93ad1fe94c`.
- Mobile: `75e42324b6c9317d8432c1caebe122e4cafa4fdf`.

No files, secrets, database rows or signing assets were copied from private
repositories or existing deployments. npm used a new scratch cache and separate
empty user/global configuration files. This was a clean checkout/install test on
an existing Linux host, **not** a fresh operating system: installed Docker images
and build tools were reused. Only the scratch backend `.env.example` public port
settings were changed before setup generated a new private `docker/.env`.

| Check | Result |
| --- | --- |
| Backend `npm ci`, `npm test` | Pass; 7 tests, npm audit zero findings |
| Fresh `bash setup.sh --demo` | Pass; new database, all five migrations and nine services healthy |
| `npm run test:api` | Pass; auth/RLS, GRN/dispatch, image lifecycle, assignment changes, concurrent oversell denial, invoice save/rejection, reporting smoke checks, four PDFs, refresh/logout |
| Second `setup.sh --demo` | Pass; environment bytes and mode 0600 preserved; demo GRN rows retained; migrations skipped by checksum |
| `npm run test:migrations` | Pass; fresh disposable database, two ledger passes, SQL security/auth assertions and seed reruns |
| Mobile `bash setup.sh` | Pass; public dependencies and example configuration only |
| Mobile typecheck / ESLint error check | Pass |
| Mobile Jest / `test:setup` | Pass; 75 Jest tests and 7 Node tests |
| Mobile `check:backend` against scratch origin | Pass; no private configuration fields exposed |
| Static contract inventory | 100 RPC names, 8 table/view names, 10 Edge names; zero missing names |

Static inventory is not proof of all signatures, permissions, results or business
rules. Reporting smoke checks verify selected response fields, not all financial
calculations. Native/device acceptance is tracked separately in the mobile repo's
`docs/NATIVE_ACCEPTANCE.md`.

### Follow-up — 2026-09-13

Publicly fetched mobile `96d92a287f2ce8a27b2587fcebe482eb4fe988b2` passes a
fresh `npm ci`, Expo SDK compatibility validation and eight bootstrap/dependency
tests. Its ARM64 debug APK compiles successfully after explicitly aligning Expo
Font and NetInfo with SDK 54. The APK is local-only; no device or iOS acceptance
is claimed. SDK files were copied into scratch from installed public tools, not
from a private project; existing SDK files and signing assets were not changed.

Backend `73627e6b213fc0a1ca311f96a927024402e3c73e` passes public fetch, fresh
`npm ci`, ten Node tests (including three release-gate tests), and the expanded
API suite against the existing isolated scratch demo. This follow-up reuses only
that newly generated demo environment; the initial fresh-database evidence above
remains at its explicitly recorded baseline. Final tag commits and validation
results must be recorded in each GitHub release's notes.

## Reproduce without touching another installation

1. Make a fresh scratch directory. Clone only the two public repositories as
   siblings, using their README clone URLs. Record `git rev-parse HEAD` in each.
2. Follow each README's prerequisites. Run `npm ci` / `bash setup.sh` and checks.
   For a genuinely empty npm cache, select a new `npm_config_cache`; do not copy
   `.npmrc`, `.env`, `.git`, storage volumes or database backups from another app.
3. If another demo exists on this host, select a unique
   `WAREHOUSE_PROJECT_NAME` beginning with `warehouse-`, and unused loopback ports.
   In the **fresh clone's `.env.example`, before first setup**, configure:

   ```dotenv
   KONG_HTTP_PORT=28000
   KONG_HTTPS_PORT=28443
   STUDIO_PORT=55325
   DATABASE_HOST_PORT=25433
   GOTENBERG_HOST_PORT=23100
   SUPABASE_PUBLIC_URL=http://localhost:28000
   API_EXTERNAL_URL=http://localhost:28000
   ```

   Keep `BIND_ADDRESS=127.0.0.1`. These are only collision-avoidance examples;
   default documented ports remain API 18000, Studio 54325, database 15433.
   Do not edit an existing installation's generated `docker/.env`.
4. In the scratch backend terminal:

   ```bash
   export WAREHOUSE_PROJECT_NAME=warehouse-clean-example
   bash setup.sh --demo
   bash health-check.sh
   npm run test:api
   bash setup.sh --demo
   npm run test:migrations
   node scripts/check-mobile-contract.mjs ../rn-warehouse-template
   ```

   Every Compose/setup/stop command for this checkout must retain that project
   name. The ownership guard refuses a project owned by another checkout.
   API tests create fictional fixtures and consume demo OTP limits; do not reset
   another installation's rate limits to make a test pass.
5. In the scratch mobile checkout:

   ```bash
   EXPO_PUBLIC_CONFIG_API_URL=http://localhost:28000 npm run check:backend
   npm test -- --silent
   npm run typecheck
   npx eslint . --quiet
   npm run test:setup
   ```

6. Check setup reruns preserve the generated environment byte-for-byte, mode 0600,
   Git exclusion and existing fixture rows. Never print its contents in logs.
7. Stop only the scratch project with its ownership-checked `bash stop.sh` and
   the same project-name environment variable. Stop preserves files for diagnosis.
   Never run Docker prune, broad volume deletion or a reset of an existing database.

## Release boundary

This evidence supports a **source-only local-demo prerelease**, not production,
physical-device acceptance, ownership approval for all assets, a clean dependency
audit, backup restoration, or complete RPC/business-flow correctness. The mobile
audit still has eight moderate package findings from one URL-decoder advisory.
