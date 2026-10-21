# Changelog

Older entries (every release and every dated section before the baseline reload) are in git: the full text is
`git show migrations-pre-baseline:CHANGELOG.md`. The full text of the entries written after that tag (the post-baseline history) is in
main at `5561868`: `git show 5561868:CHANGELOG.md`. Each section below is the short form. "Migration N", for N up to 110, names
a file in that tag; the baseline `migrations/00000000000000_baseline.sql` is their squash.

## Unreleased

### Operator actions

An installation on this release's predecessor (PostgreSQL 15 image, migrations 000 to 110) first goes through the **Baseline
reload** in `docs/OPERATOR_INSTALL.md`; a new installation needs none of that. An installation on PostgreSQL 17 needs the one-time
[Major PostgreSQL upgrade](docs/OPERATOR_INSTALL.md#major-postgresql-upgrade). On every update, run `setup.sh` again, and:

1. **Images rebuild.** The `db`, `storage` and `pdf-renderer` recipes changed, so `setup.sh` rebuilds those three images
   (`scripts/build-images.sh` sees the new `image-recipes.sha256`). The first run takes a few minutes longer and the Storage
   image is about half the size (1.01 GB to 553 MB).
2. **`PGRST_DB_SCHEMAS` becomes `public`.** `setup.sh` and the restore scripts rewrite an old default (`public,storage` or
   `public,storage,graphql_public`) in `compose.env` to `public` and recreate `rest`. A list you changed yourself is left alone.
   `/rest/v1/` no longer serves an OpenAPI document (`PGRST_OPENAPI_MODE=disabled`) and no longer reaches the `storage` schema.
3. **Migration 123 refuses to run if a table or column it drops holds data.** It checks 16 tables and 12 columns first and
   stops with `Migration 123 would drop data: ...` and "Nothing was changed". Export what you need, empty those objects, then run
   `setup.sh` again. A facility that never held such data passes without a message.
4. **`get-public-config` can answer 503 between the code update and migration 123** (it calls the new function
   `get_public_config`, which does not exist before the migration), and until a rollback if 123 fails. Run `setup.sh` once;
   do not leave the new code running on the old schema.
5. **Docker Compose files.** `docker/docker-compose.override.yml` is merged into `docker/docker-compose.yml`; a script or
   alias that names the override file must name the one file (`scripts/compose.sh` passes it).
6. **Before migration 117 (customer names), check for names that already clash.** The unique index `customers_name_norm_key`
   fails to build, and so does the whole migration, if two customers have the same name apart from capitals and spaces. Run as
   `supabase_admin`, against the facility database:

   ```sql
   SELECT pg_catalog.btrim(pg_catalog.regexp_replace(pg_catalog.lower(name),
          '[\s   -     　﻿]+', ' ', 'g'), ' ') AS key,
          array_agg(name) AS names
   FROM public.customers GROUP BY 1 HAVING count(*) > 1;
   ```

   Rename one of each pair in the app (Customers, Edit) first; no rows: go on.
7. **After the baseline reload:** run the `sudo` commands `setup.sh` prints (checker timer, USB backup helper); delete by hand any
   of `REALTIME_DB_ENC_KEY`, `STUDIO_*`, `OPENAI_API_KEY`, `DASHBOARD_*` that `compose.env` still has (`setup.sh` removes
   `DB_PASSWORD_AUTH` and `DB_PASSWORD_MONITORING` itself); the Slack webhook moves to `config/slack-webhook-url`; take a new
   backup (a backup from before the reload restores only with the tag `migrations-pre-baseline`); remove the network
   `<project>_admin`, the volumes `<project>_db-config` and `<project>_prometheus_data` and the images of removed services.
8. The daily pass of the checker (`scripts/watch.mjs`) applies the retention in `docs/OPERATOR_INSTALL.md`, "Retention".
9. **The pooler is off unless you turn it on.** On an existing installation `setup.sh` runs a one-time clean-up of the unused pooler
   objects (role and schema `pgbouncer`, database `_supabase`, three secrets) and records `POOLER_ENABLED=false`; an installation that
   ran supavisor is recorded as on. If `_supabase` holds data the clean-up is refused with a warning and asked again at the next setup.
   To use the pooler: `bash scripts/pooler.sh on` (`off`, `status`); see "Pooler (optional)" in `docs/OPERATOR_INSTALL.md`.

### Changed

- **Pooler on/off.** The pooler is only on when turned on (`bash scripts/pooler.sh on|off|status`); a new install has no pgbouncer
  objects, no `_supabase` database and no pooler secrets, and backups no longer contain `_supabase.dump` (old backups still restore;
  the file is skipped with a note). Existing installs: setup cleans up the unused pooler objects once (Operator actions, item 9).
- **View jobs** works for administrator, supervisor and staff (`get_print_jobs`, `cancel_print_job`).
- **Direct table reads removed on 18 tables** (migration 123); 12 stay readable (list in `CLAUDE.md`, `tests/role_allowlist.sql`).
- **`audit_log` keeps 2 years (730 days)**; monthly partitions are created 3 months ahead and older ones are dropped by the daily retention.
- **Three RPCs dropped** in migration 123: `restore_customer`, `safe_delete_customer`, `get_open_invoices_for_customer`.
- **Edge CORS removed.** Only Kong answers CORS; the edge functions no longer add `*` headers.
- **Renderer image fonts trimmed** (941 to 826 MB); the golden PDFs are unchanged at fuzz 0.
- **`scripts/migrate.sh --through <file>`** applies pending migrations up to the named file (an unknown name is refused); the Baseline reload uses it.
- **Slimming round 2, database (migration 123).** About 110 functions that nothing calls (90 in `public`, 2 in `auth`, 19 that only
  tests called, among them the second invoice-save path `save_invoice(jsonb)` and the `*_item_storage_price` helpers the app never
  uses), 8 views, 16 tables, 12 columns and 13 duplicate indexes are dropped; five live functions lose a dead reference
  (`delete_grn_safe` and `save_invoice_internal` still answer `auto_invoice_errors` and `resolved_errors_count`, now as 0;
  `run_database_retention` no longer lists four counts). New anon-callable `get_public_config(text)` returns
  `{app_version, maintenance_mode, feature_flags}`, so `get-public-config` no longer holds the service-role key. The 17 ordinary
  `uuid_generate_v1()` defaults become `gen_random_uuid()`; `dispatch_trl`, `goodsreceived_trl` and `invoice_trl` keep v1 ids and
  the `uuid-ossp` extension stays (the app's `string().uuid()` accepts versions 1 to 5 only). The OTP cleanup trigger is gone; the
  7-day `ephemeral_auth` retention rule is the only OTP clean-up. `trg_restore_stock_on_dispatch_delete` stays. The contract
  docs ([API_CONTRACT](docs/API_CONTRACT.md), [STAFF_GRN_POLICY](docs/STAFF_GRN_POLICY.md), [INVOICE_RULES](docs/INVOICE_RULES.md)) mark the dropped entries.
- **Edge functions call PostgREST and Storage directly** (`rest:3000`, `storage:5000`) for reports, PDFs and config, not through Kong;
  `operator-otp`, `central-exchange`, `ingest-sensor-readings` and the profile read of `_shared/auth-helpers.ts` do too (only
  `apikey` and `Authorization` are sent). Only the client to Kong path remains under Kong's limits.
- **Images.** Storage is a two-stage build on a clean pinned `node:24.21.0-alpine3.23` (no compiler); the db image replaces the
  base image's Go `gosu` with a `setpriv` shell shim (no Go build, no Go CVE rows); the `pdf-renderer` `GIT_SHA` and label moved
  to the end of the Dockerfile so a commit no longer rebuilds the `apt-get` layer.
- **Health.** `health-check.sh` is a thin wrapper over `node scripts/watch.mjs health`, also used by `doctor --local` and
  `tests/recovery-check.sh`. Only the default services can fail it; optional ones (sensors, printing, pooler) show `warn`.
  `--wait 0` makes one attempt; the gateway probe reads a `feature_flags` row through Kong, not `/rest/v1/`.
- **Scripts.** `scripts/check-readiness.sh` is folded into `doctor --host-preflight` (run by `setup.sh`); one `operator-lock.sh`
  replaces three inline `flock` copies; `setup.sh` and `restore-host.sh` check for `node` before the first `node` call
  (`scripts/require-node.sh`); the CI-only drivers (`gateway-smoke`, `gateway-dns-check`, `load-smoke`, `recovery-check`,
  `cups-check`, `sensor-bridge-check`, `pooler-check`) live in `tests/`; the npm script `keys:rotate` is gone.
- **Tests, docs and CI.** About 1,000 lines of tests went: the three hand-run HTTP drivers and their refusal tests, tests that pinned exact doc sentences, gates that were always true, text checks of the frozen baseline (its hash
  pin stays), CI step-order checks, the pre-migration-61 report code and its tests. One table (`tests/removed-components.test.mjs`)
  guards every removed component; one test checks that every `tests/*.sql` is registered once in `tests/migrations.sh`; the report
  HTML hashes were re-taken. `THIRD_PARTY_NOTICES.md` is the only place that names pinned versions and holds the ownership
  review (`docs/ATTRIBUTION_REVIEW.md` is merged into it). CI: the `pdf-renderer` and golden-page jobs are one job that runs only when `docker/pdf-renderer/`, `tests/golden-pdf/`, `functions/_shared/` or `ci.yml` changed (a `changes` job decides; none is a required check); no npm cache in `validate`, one `CI_RUNNER` comment, no duplicate
  verify in `operator-install`, and the `contract` job runs `tests/rpc-callers.test.mjs` against the pinned app. The alert-webhook
  terminal test skips on a runner without a usable pty. `tests/sensor-bridge-check.sh` fails, not "Skipped", without its Dockerfile.

### Removed

- `docker/docker-compose.override.yml` (merged), `scripts/drop-logical-slots.sh` (the cluster is built with `wal_level=replica`),
  `scripts/check-readiness.sh`, the Go build of `gosu` and `LICENSES/gosu/`, `BIND_ADDRESS`, `PGRST_DB_USE_LEGACY_GUCS` and Storage's
  `POSTGREST_URL` and its `rest` dependency, `docs/ATTRIBUTION_REVIEW.md`.
- Earlier in this release (all in the tag `migrations-pre-baseline`): Supabase Realtime (the app re-reads on a timer), the list-refresh
  machinery and `pg_cron`, GoTrue (the `DB_PASSWORD_AUTH` line), Studio and postgres-meta, imgproxy and the `customer-images` bucket,
  Grafana, the Prometheus stack and the wal-g binary, `pgjwt`, `pg_net`, `pg_graphql`, `supabase_vault` and `http`, the GraphQL route,
  supabase-js in the functions image, the Gotenberg upgrade path, the second-disk backup helper and backup formats before v5.

### Earlier in this release (not yet tagged)

- **PostgreSQL 18.** `postgres:18.6-trixie` by index digest (was 17.11); no migration changes. A PostgreSQL 17 data directory does
  not open in 18: use the Major PostgreSQL upgrade. `PGDATA` is set to `/var/lib/postgresql/data`; the version guards read the
  major from the pin; `restore.sh` rebuilds a stale db image first; `scripts/data-fingerprint.sh --counts` is the row-count query
  of the upgrade; `restore.sh` runs `vacuumdb --all --analyze-in-stages`. Data checksums are on for new clusters.
- **PostgreSQL 17 on the official image and one baseline migration.** `migrations/00000000000000_baseline.sql` (sha256
  `fcd627d11323af7ef35f101dd0827dff55adee3970cb420355e33a6b007b6ed8`) is an exact squash of migrations 0 to 110; the next
  migration was 111 (it is 125 now: 123 is this round, 124 is reserved). One superuser, `supabase_admin`; the agreed roles are
  `anon`, `authenticated`, `service_role`, `authenticator`, `supabase_storage_admin` and (optional pooler) `pgbouncer`. Version
  preflight and ledger guard refuse older installations before anything changes; backups record `database_image=` and a
  pre-baseline backup restores only with the tag.
- **Kong 3.9.4** and the sensor bridge on **Python 3.15-slim-bookworm** (by digest).
- **Migrations 111 to 122** (server side of the app reviews; details and every `reason` code in
  [docs/API_CONTRACT.md](docs/API_CONTRACT.md)). New optional arguments and answer fields only, except where noted:
  - 111 sensor temperature limits (`update_sensor_device` takes the limits; the old four-argument form is dropped);
  - 112 customers: `DUPLICATE_MOBILE`, `DUPLICATE_NAME`, `STALE_CUSTOMER`, `search_customers(p_include_inactive)`; the old
    signatures are dropped, so **deploy the backend before a new app** (PGRST202 otherwise);
  - 113 and the users review: `user_profiles.deleted_at`, access-request tags, `review_enrollment_again`;
  - 114 items: `update_item` keeps `p_active` when omitted, `get_item_usage`; 115 pricing: `set_standard_rate` stale check and dry run,
    `undo_rate_change(p_seen_rows)`;
  - 116 activate refuses a shared mobile, assignments only for the Customer role; 117 one customer name per case-and-space key
    (the clash query above); 118 customer names of only blanks refused, `delete_user_account` sets `disabled`;
  - 119 dead GoTrue-era functions dropped; 120 review fixes: a lost answer can be read back (`request_key`,
    `get_submission_result`, answers kept 7 days), cancelled invoices keep their lines, `NUMBER_TAKEN`, financial-year checks;
  - 121 owner decisions D1 to D24: stale edits (`STALE_RECORD`, `invoice.updated_at`, `get_grn_edit_state`), locks after invoicing,
    date rules, orders kept in step with dispatch edits, no invoice while stock remains, GRN history in `audit_log`;
  - 122 push review: lower-after-raise gives back what the order lent, a save of lines alone moves the version token.

### Fixed

- `tests/rpc-callers.test.mjs` imported a script that no longer existed and skipped silently; it runs the contract scanner now.
- The v0.6.1 release gate failed on a hosted runner at the alert-webhook terminal test (see Changed).
- Report PDFs print each invoice once, from its total: no code for a database without migrations 59, 61, 62 or 63 remains.

## v0.6.1 (2026-10-19)

Grafana removed; alerts go to the facility's Slack (`config/slack-webhook-url`, asked by `setup.sh`).

## v0.6.0 (2026-10-18)

pdf-renderer (own headless-Chromium renderer) replaces Gotenberg; GRN lists page by receipt and gain a low-stock filter
(migration 98); the last wave of the ops review (hashed Python requirements, storage lockfile guard, build-date drift).

## v0.5.0 (2026-10-18)

The ops review (migrations 91 to 97, in four waves): lists refresh after the commit, one database password per login, a signing
secret and unsigned-backup refusal, image advisories and the exception ledger, PostgREST pinned. One association sign-in for
every facility (migration 81); deactivated businesses (82 to 84); every item always has a rate (85, 86, 88 to 90); report PDFs
(`generate-report-pdf`) with the screen's choices and India-day dates; Paid and Pending follow the money; Tapo sensors through
the template (5-minute samples kept 90 days); central login token exchange; Settings UX batch (item rate changes, approving staff,
service accounts); Storage v1.80.2, Realtime v2.143.x, Studio 2026.10.05, Prometheus 3.15.0, Go 1.27.2 builders; the
operator-install CI job can run on a self-hosted runner. Release candidates `v0.5.0-rc.1` to `rc.6` led up to it.

## v0.5.0-rc.6 (2026-10-18)

Ops review wave 4: hashed Python requirements, storage lockfile guard, build-date drift.

## v0.5.0-rc.5 (2026-10-18)

Ops review wave 3: receipts, sign-in refusals, OTP provider answers, monitoring, operations (migrations 95 to 97).

## v0.5.0-rc.4 (2026-10-18)

Ops review: image advisories, the exception ledger, PostgREST pinned.

## v0.5.0-rc.3 (2026-10-18)

Ops review wave 2, part 2: one database password per login (migration 94).

## v0.5.0-rc.2 (2026-10-18)

Ops review wave 2, part 1: signing secret, pg_net, key cache, gateway log, unsigned backups (migrations 92, 93).

## v0.5.0-rc.1 (2026-10-18)

Ops review wave 1: lists refresh after the commit (migration 91), the key file in backups; staff lose item pricing (migration 90).

## v0.4.0 (2026-10-11)

Owner decisions of 2026-10-11 and the infrastructure review: signed backups and a restore verifier that does not flake; the last
administrator cannot be removed; OTP limits a stranger cannot turn against a user; a replayed refresh token ends the session;
the server admits only what the app offers each role; business tables are written only through the guarded RPCs; an image is
confirmed only for a file in its own document's folder; generated PDFs expire; invoice line rules (rate ranges, one invoice per
dispatch line, India dates, discount history); one lock order for document writes; container networks and pinned dependencies.

## v0.3.0 (2026-10-08)

The first public template with a fresh repository history: second-pass review fixes, the gateway merge, setup failure
diagnostics and HTTP readiness, image remediation and the production-dependency list, Studio and metadata security, the
orders/cart companion and maintained image recipes, iOS acceptance handoff. Earlier prereleases: `0.2.2-demo` (2026-09-18) and
`0.1.0` (2026-03-10, the first import).

## Older history

Every entry before the baseline reload is in the tag `migrations-pre-baseline` (`git show migrations-pre-baseline:CHANGELOG.md`).
Statements in it that are superseded by this release:

- "Operator action: rerun `setup.sh`; it applies migration 10x" was step 1 of the Baseline reload (run with the tag checked out).
- The restore filters for `pg_net`, `pg_cron` and GraphQL, "an older backup restores cleanly", the repair of `warehouse_monitoring`
  and `supabase_auth_admin` (NOLOGIN) by `configure-db-roles.sql`, and the role `supabase_realtime_admin` that "belongs to the
  database image and is kept": none of these exists any more. A backup from before the baseline restores only with the tag.
- `wal-g.conf`, the `db-config` volume, the list-refresh lock 71046 and the pg_cron preload are gone with the old image.
- "Delete a leftover `DB_PASSWORD_*` or `REALTIME_DB_ENC_KEY` line by hand": `setup.sh` removes `DB_PASSWORD_AUTH` and
  `DB_PASSWORD_MONITORING` itself; the other leftover lines are in the Operator actions above.
