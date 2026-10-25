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
8. The daily pass (`watch.mjs daily`, run by its own timer, see item 10) applies the retention in `docs/OPERATOR_INSTALL.md`, "Retention".
9. **The pooler is off unless you turn it on.** On an existing installation `setup.sh` runs a one-time clean-up of the unused pooler
   objects (role and schema `pgbouncer`, database `_supabase`, three secrets) and records `POOLER_ENABLED=false`; an installation that
   ran supavisor is recorded as on. If `_supabase` holds data the clean-up is refused with a warning and asked again at the next setup.
   To use the pooler: `bash scripts/pooler.sh on` (`off`, `status`); see "Pooler (optional)" in `docs/OPERATOR_INSTALL.md`.
10. **Run `sudo bash scripts/watch-timer.sh install --state "$WAREHOUSE_STATE_DIR"` again.** The daily backup is no longer inside the
   5-minute checker: it is `watch.mjs daily`, run by its own timer `<project>-daily.timer` (same `--daily-at` time, kept from the old
   unit). **Until you rerun `install`, the backup keeps running** from the old checker unit: that unit sets `WAREHOUSE_WATCH_DAILY_AT`,
   and a `run` that sees it makes the pass inside itself, as before, so an update never leaves a gap in the backups. The old design
   holds the 5-minute checks off during a long backup and has no boot unit, so the checker raises `daily_timer_legacy` at once in Slack
   (never muted), and `start.sh`, `status` and `doctor` print the command to run. Installing while the old unit is running warns first: it
   may be in the middle of the backup. The command also writes `<project>-stack.service` (starts the stopped services at boot, never
   recreating or building, so a power cut during the backup window no longer leaves them stopped and a reboot cannot apply a release that
   `setup.sh` has not) and moves the units to a Node.js link (`~/.local/opt/node-current`) so a Node.js upgrade only moves the link.
   Optional: `config/heartbeat-url` for an external dead-man switch
   ([docs/MONITORING.md](docs/MONITORING.md#external-heartbeat-the-dead-man-switch)).
11. **`setup.sh` recreates the `db` and `rest` containers** (a few seconds of downtime): `PGRST_DB_CONFIG` is now `true`, so anonymous API
    calls are cut at 3 s (they ran under 8 s); the database gets `shm_size: 256m`, logs statements slower than 1 s without their
    parameter values, and no longer logs connections ([docs/MONITORING.md](docs/MONITORING.md#finding-a-slow-query)).
12. **Migration 126 (sessions, per-source limits, break-glass) and the `functions` recreate.** Runs with `setup.sh`; no data is changed. Sessions
   now slide (30 days idle, 90 days at most; before: 7 days from sign-in), so an SMS outage no longer signs everybody out within a week;
   a lost phone is therefore ended by switching the user off (`docs/OPERATOR_INSTALL.md`, "A lost or stolen phone"). If many phones share
   the facility Wi-Fi, list its public address once as `otp_trusted_source_list` (`docs/OPERATOR_INSTALL.md`, "The facility's own Wi-Fi
   address"). Learn `bash scripts/break-glass-admin.sh <admin number>` ("Break-glass administrator sign-in") before the day SMS stops.
   **`setup.sh` recreates the `functions` container since this release** (the functions are bind-mounted and the edge runtime keeps the
   modules it has loaded, so a new checkout alone never reloaded them; see "Rerun and upgrade" in `docs/OPERATOR_INSTALL.md`). Releases
   before this one did not: after the pull they needed `bash scripts/compose.sh up -d --force-recreate functions` by hand. Running the
   `setup.sh` of this release does it, so nothing more is needed. Without the recreate the old `operator-otp` keeps running, and while the SMS
   provider refuses requests the app shows "SMS delivery unavailable" instead of its code screen, so a break-glass code cannot be typed.
   The app needs no change.
13. **Follow release tags, and upgrade with `bash upgrade.sh vX.Y.Z`.** `main` is no longer the operator channel; a release is a tag
   (`vMAJOR.MINOR.PATCH`) with a GitHub release note. `upgrade.sh` takes the operator lock, backs up and verifies the backup, checks the tag
   out (detached HEAD), reruns `setup.sh --operator` with your installation's own values (the administrator is read from the database;
   nothing else needs repeating; setup also recreates the `functions` container and runs `doctor --local`) and prints the operator actions of this
   file between your release and the new one. `bash upgrade.sh --dry-run vX.Y.Z` runs the checks and prints the plan. It refuses to run as
   root, a dirty checkout, a name that is not a release tag on origin, a release the checkout is already past (it only moves forward), a
   release on another PostgreSQL major (that stays the separate "Major PostgreSQL upgrade" procedure) and a database that recorded
   migrations the release does not contain. Run it inside `tmux` or `screen` over SSH. **If it stops, the same command finishes it:**
   before its first change it writes `config/upgrade-in-progress` (the old commit, the target, the step, then the verified backup), a rerun
   reuses that backup and takes no new one of the half-upgraded database (and works with the database down), `doctor`, `start.sh` and the
   status commands report the interrupted upgrade while the file exists, and a failed step prints the complete way back (old commit,
   `stop.sh`, `npm run db:restore -- --yes --restore-config <backup>`, the old release's `setup.sh`, the `functions` recreate, `doctor`; again
   with `node scripts/upgrade-record.mjs rollback`). **The first move to a release that contains `upgrade.sh` uses the manual sequence** in
   `docs/OPERATOR_INSTALL.md` ("Rerun and upgrade", "What upgrade.sh does"): your checkout has no `upgrade.sh` yet. Security fixes are
   supported for the current and the previous minor release (`SECURITY.md`); a backport never carries a migration (`CONTRIBUTING.md`).
   `setup.sh` now accepts the operator lock when its caller already holds it (`upgrade.sh` does), as `migrate.sh` and `backup.sh` already
   did; a descriptor 9 that only names the lock file no longer counts as holding it.

### Changed

- **Built images are saved, and signed.** After a successful build `scripts/build-images.sh` writes the images it built to
  `<state>/images/<service>.tar` (`docker save`, about 2.5 GiB in all; skipped with a warning if under 5 GiB, or the size of the newest
  backup when larger, would stay free) with a copy of the build record, and `db:restore-host` loads them (`--images DIR`, or an `images`
  folder next to the backup) before the restore, so a lost-host rebuild does not need Docker Hub, Debian, npm and Chrome for Testing.
  The folder is signed like a backup (`SHA256SUMS` over every file, `SHA256SUMS.hmac` with the backup key) and `db:restore-host` loads
  nothing that does not authenticate with the key it is given: a folder named with `--images` is refused, one found next to the backup is
  ignored, and `--allow-unsigned` never uses saved images. A tarball whose save was skipped or failed, or that the record no longer
  names, is removed. The folder is not in a backup: `bash scripts/build-images.sh --save` writes it for an installation that is
  already built, and the operator copies it with the drive ([docs/OPERATOR_INSTALL.md](docs/OPERATOR_INSTALL.md#backup-and-restore)).
- **`stop.sh` survives a reboot.** It writes `<state>/config/stopped-by-operator`; `start.sh`, `setup.sh` and `restore.sh` remove it.
  While it exists the boot unit does nothing, the checker does not self-heal, and `status`, `doctor` and the `start.sh` hint say
  "stopped by the operator; run start.sh". A reboot in the middle of a manual procedure (Baseline reload, Major PostgreSQL upgrade,
  restore) no longer starts the stack on an empty data directory.
- **Self-healing is narrower.** It starts `exited` and `created` services with `up -d --no-build --no-recreate --no-deps --pull never`
  (it can neither build, pull, recreate nor start dependencies) and does so at most 6 times per service in 24 hours; after that
  `service_healed` says the service needs a person.
- **The 5-minute checks go on during the daily pass.** The host, disk, database and backup-file checks keep running while the pass
  holds the operator lock, and `operator_lock_stuck` fires after 4 hours for the pass (its own limit), not 2. A pass cut off by a power
  cut is recognised at the next trigger and made again at once (it used to wait 4 hours). The checker's and the pass's writes to
  `config/watch-state.json` are serialised with a lock file. The pass also waits for a running pooler that is unhealthy (`supavisor`).
- **New and changed alerts.** `sms_delivery` is checked every hour (it was once a day), with a second rule for the last hour;
  `break_glass_used` fires at once when `public.audit_log` holds a break-glass row (`CODE_ISSUED` or `SIGN_IN`) from the last 24 hours;
  `clock_unsynced` compares with Cloudflare's own clock (`/cdn-cgi/trace`) and falls back to the `Date` header;
  `daily_timer_legacy` (item 10). The gateway-log checks (`api_error_rate_high`, `api_latency_p95_high`, `api_429_rate_high`) read
  `docker logs -t --tail 5000` and cut to 5 minutes by the time stamps: `docker logs --since` returned nothing for any window up to
  an hour on a Docker 29.9.1 host, which would have kept them at "too few requests" for good (`tests/gateway-smoke.mjs` likewise).
- **Release channel, support window and `upgrade.sh`.** `upgrade.sh` (operator action 13) with its upgrade record
  (`scripts/upgrade-record.mjs`), `scripts/pg-major.sh` (the PostgreSQL major of a tree or a tag, which `upgrade.sh` and CI compare),
  `SECURITY.md` (the current line gets a patch from `main` when `main` holds nothing unreleased beyond the fix, else the next minor; the
  previous minor gets a backport of a code-only fix for 6 months after the next minor; a fix that needs SQL is never backported; a fix is
  announced in a GitHub release note with "Security" in its title), `SUPPORT.md`, `CONTRIBUTING.md` (release flow, how a security fix ships,
  what belongs in `setup.sh`) and `docs/RELEASE_CHECKLIST.md` (the release note template, the `upgrade.sh` rehearsal on a release candidate
  `vX.Y.Z-rc.N` before the same commit is tagged `vX.Y.Z`). A new baseline must list the migration names it replaces (`CONTRIBUTING.md`),
  because `upgrade.sh` refuses a release whose migrations lack a name the database recorded. `release.yml` also runs
  `scripts/check-release-contents.sh` (the `CHANGELOG.md` section, `upgrade.sh`, `scripts/pg-major.sh`, the inherited lock and the
  functions recreate in `setup.sh`).
- **`setup.sh` recreates the `functions` container** after its full start (`up -d --force-recreate --no-deps --wait`), so the code on disk
  is the code that runs, whether the move was made by `upgrade.sh` or by hand. `upgrade.sh` no longer recreates it or runs the doctor
  itself: after the checkout it is the old release's script, so everything that depends on the release moved to is a step of that release's
  `setup.sh`.
- **CI.** A new `operator-upgrade` job installs the newest release tag before the change (its own `upgrade.sh`, unchanged), or, when no
  tag on the same PostgreSQL major exists, the merge base with the target branch (with this change's `upgrade.sh` added), and moves it to
  the commit with `upgrade.sh --ref`; it checks the record is gone, the doctor, the identity, the administrator and that no table lost
  rows. `ci.yml` runs for `release/**` branches and fails a pull request into one that changes `migrations/`.
  `.github/workflows/keep-alive.yml` commits a timestamp once a month to the orphan branch `keep-alive` and calls the documented endpoint
  that enables the scheduled workflows (`actions: write`, this workflow only). That this keeps GitHub from disabling them after 60 days is
  unverified; the owner checks the Actions tab after a long absence (`docs/PRODUCTION_DEPENDENCIES.md`).
- **Setup asks for the PDF letterhead.** A first `setup.sh --operator` without `--letterhead-file` asks on a terminal for the path of a
  JPEG or PNG (Enter means plain PDFs) and, with no terminal (a script or an agent running setup), refuses with "choose the PDF
  letterhead" until `--letterhead-file PATH` or `--letterhead-file off` is given, as for the Slack webhook. A rerun without the option
  asks nothing and keeps the letterhead; `--letterhead-file ask` asks on a rerun. CI passes `--letterhead-file off`.
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

### Possible duplicate warning (migration 124)

New migration (`duplicate_warning`), the server half of the owner decision of 2026-10-21: a **warning**, never a block, when a GRN or a
direct dispatch looks like one that was just saved. It is **opt-in**: only a call that asks for it, and sends a request key, is checked, so an
older app build and `fas-sync`'s bulk push (named arguments, no flag) behave exactly as before. Details and every field of the answer:
[docs/API_CONTRACT.md](docs/API_CONTRACT.md), "Possible duplicate (migration 124, 2026-10-21)". No data is changed and no index is added.

- **GRN.** `save_grn` gains the trailing parameter `p_warn_duplicate boolean DEFAULT false` (after `p_rates`; every existing argument keeps
  its name). With `true` and a request key, a live GRN of the same customer, the same GRN day (Asia/Kolkata) and the same SET of (item,
  packaging) lines, created in the last 30 minutes by anyone, is answered `POSSIBLE_DUPLICATE` (`success:false, error_code:'WH409'`, the
  `NUMBER_TAKEN` shape) and nothing is written. Quantity, weight, line order and repeated lines are ignored; packaging is compared trimmed, in one
  case, with white space runs as one space. The old 17-argument function is dropped and the new one made with the same owner, security,
  `search_path`, `jit` and grants, so PostgREST sees one `save_grn`.
- **Direct dispatch.** `p_dispatch_data.warn_duplicate = true` with a request key (no signature change; both `create_dispatch_with_stock_check`
  signatures): a live dispatch of the same customer with the same SET of lots and the same vehicle (upper-cased, spaces and hyphens removed),
  created in the last 30 minutes, is answered `POSSIBLE_DUPLICATE`. A dispatch from an order (`source_order_id`) is never checked.
- **Order of checks.** After the saved-answer lookup (a resend of a saved request still returns its stored answer) and after every other
  validation and refusal: the check is the **last step of the write block** (for `save_grn` after the lines, images and rates; for the dispatch
  after the lines, stock, movements and cart handling). A match raises `dup_warn`, the existing handler returns the answer, and the rollback leaves
  nothing written, so a quantity, rate (`RATE_MISSING`, `RATE_PLANNED`...) or image refusal is answered instead of the warning, never after
  "Save anyway". The answer is never stored under the request key. The newest match is reported, with `existing_id`, `existing_number`,
  `existing_created_at`, `existing_created_by` (a name, or null), `customer_name`, `items`, `vehicle` (dispatch) and `window_minutes: 30`.
- **Helpers.** `warehouse_security.possible_duplicate_grn` and `possible_duplicate_dispatch` (not granted to any API role; they skip the record
  being written; an error inside one is logged as a `WARNING` and means no warning, so the save then answers as before). The GRN lookup is
  bounded by customer and by the business day as a range of `date`. Both functions are patched from their latest definition with the
  marker-count pattern.
- Tests: `tests/duplicate_warning_124.sql` (new, registered in `tests/migrations.sh`); case 12 of `tests/concurrent_rules.sh` (two sessions: the
  second of two creates is warned and names the first; an overlapping resend gets the stored answer); `tests/grn_rates.sql` names the new last parameter.


### Sliding sessions, per-source limits and break-glass sign-in (migration 126)

New migration (`sessions_and_source_limits`), the owner decisions of 2026-10-25 for review items 2 and 20 of the production-readiness review.
The app needs no change (it never reads the refresh token's lifetime; the one answer it treats as definitive, `Session expired`, is kept).

- **Sliding sessions.** `warehouse_security.issue_session`: for an active, approved profile each refresh moves the session's end to
  `now() + session_idle_seconds` (default 2592000, 30 days; kept between 1 hour and 365 days) but never past `refresh_sessions.created_at +
  session_max_seconds` (default 7776000, 90 days; never below the idle time, at most 1095 days). A new sign-in ends after the idle time (was
  a fixed 7 days). Another active profile keeps 7 days and is not extended. A session already past the absolute limit is not renewed
  (`Session expired`, `P0001`). `update_user_status(false)` still deletes sessions. `refresh_jwt_token` keeps its reuse rule but is patched
  (marker): the record of a replaced token now lasts until `created_at + session_max_seconds` at the latest (never less than the end the
  session had), where it used to end with the session's end at the time of the refresh. Sessions used to end within 7 days, so the two
  coincided; a sliding session would have outlived its records and a stolen, replaced token would have been refused without ending the
  session. Cost: the small rows of replaced tokens stay up to 90 days instead of 7, and go with the session. The two clamps are read by
  new helpers `session_idle_seconds()` and `session_max_seconds()`. The keys are seeded once by the migration and
  `scripts/configure-auth.sql` (`ON CONFLICT DO NOTHING`: a rerun of setup keeps an operator's value, unlike `access_seconds`, which is
  rewritten from `JWT_EXP`).
- **Per-source OTP limits are `auth_config` keys.** `otp_source_hourly_sends` (30; was the literal in `operator_prepare_otp`) and
  `otp_source_hourly_failures` (20; was the literal in `operator_verify_otp`), same defaults. New optional `otp_trusted_source_list`
  (comma separated addresses and CIDR ranges; the facility's Wi-Fi address; named apart from the table `warehouse_security.otp_trusted_sources`,
  which holds a phone's own trusted networks) gets `otp_trusted_source_hourly_sends` (default 120; the larger of the two limits applies).
  A range wider than /8 (IPv4) or /32 (IPv6) is an error where the list is read (`22023`, the entry named), and a trigger on `auth_config`
  refuses to store such a list, so a typo like `0.0.0.0/0` cannot make the whole internet a trusted source. `reset_otp_limits` is unchanged
  (per-phone counts only). New helpers `warehouse_security.address_in_list`, `otp_source_send_cap`, `otp_source_failure_cap`,
  `check_trusted_source_list` (trigger function), `session_idle_seconds`, `session_max_seconds` (not granted to any API role).
- **Break-glass administrator sign-in.** `warehouse_security.break_glass_code(phone)` (`supabase_admin` only) makes a one-time six-digit code,
  valid 10 minutes, for an existing active, approved administrator; `operator_verify_otp` accepts it after looking for an SMS code, once,
  until five wrong tries, without marking the number verified or the address trusted, and writes `audit_log` rows (`break_glass`,
  `CODE_ISSUED` and `SIGN_IN`). `scripts/break-glass-admin.sh <number>` runs it under the operator lock and prints the code once with a
  warning. New table `warehouse_security.break_glass_codes` (keyed hash, RLS on, no API grants). The `operator-otp` edge function answers a
  request as sent while a code is open for the number and the SMS provider refuses it (new service-role function
  `operator_break_glass_open`), so the app reaches its code screen; a request the SMS provider accepted never asks. Making a code also clears
  that number's own per-phone request counters (the two statements of `reset_otp_limits`), because they fill while the provider refuses
  requests and would refuse the administrator's request for the code screen; per-address and warehouse-wide counts stay (use mobile
  data if the Wi-Fi's address is at its limit, `docs/OPERATOR_INSTALL.md`). A code is issued, and accepted, only for a person (not a service
  account, not a deleted profile). The script prints the code only to a terminal (`--to-stdout` overrides it on purpose). It does not help a
  build that signs in through the association when the association's SMS is down (`docs/OPERATOR_INSTALL.md`, `docs/CENTRAL_LOGIN.md`).
  The three `operator_*` and `refresh_jwt_token` bodies are patched from their latest definition with the marker-count pattern;
  `issue_session` is replaced as a whole.
- Tests: `tests/sessions_sliding.sql`, `tests/break_glass.sql`, `tests/otp_source_limits.sql` (new, registered in `tests/migrations.sh`, which
  also checks that a rerun of `configure-auth.sql` keeps an operator's values); `tests/break-glass-admin.test.mjs` and a new case in
  `tests/operator-lock.test.mjs` for the script; new cases in `tests/operator-otp-handler.test.mjs`; classification assertions in
  `tests/role_allowlist.sql` and `tests/security_baseline.sql`. The cases cover reuse of a replaced token 40 days after a slide, the cleared
  per-phone counters (open and trusted lane) with per-address and warehouse counts kept, a source at its failure limit before a correct
  break-glass code is read, a live SMS code with an open break-glass code, service accounts and deleted profiles, and the refusal of
  ranges wider than /8 or /32.

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

- **Optional letterhead image on the document PDFs.** `setup.sh --operator --letterhead-file ABSOLUTE|off` (also `scripts/configure.mjs`)
  adds a JPEG or PNG banner (at most 2 MiB, checked by its first bytes) at the top of the GRN, dispatch, invoice and customer stock
  PDFs; report PDFs and QR images are unchanged and plain PDFs stay the default. The image is copied to `public/letterhead.jpg` or
  `.png` and recorded as `LETTERHEAD_FILE` in `config/compose.env` (a rerun without the flag keeps it, `off` removes it); the functions
  router reads it and `documentHtml` prints it only for an exact `data:image/(jpeg|png);base64` address, with `img-src data:` added to that
  document's content policy only then. A missing or unusable file never fails a PDF: it is logged and the PDF is plain. Backups carry the
  image, `db:verify-restore` checks it, `db:restore-host` puts it back (an older backup restores to plain PDFs), and doctor and the checker
  warn when `LETTERHEAD_FILE` names a file that cannot be used. See `docs/OPERATOR_INSTALL.md`, "Letterhead image".
- **Operator install fixes.** `setup.sh` tries `--central-jwks-url` once from the host (10 seconds) and prints a warning, without
  stopping, when the keys cannot be fetched; `npm run doctor` prints the cause of an external fetch failure (`ENETUNREACH`,
  `ENOTFOUND`) instead of "fetch failed". `docs/OPERATOR_INSTALL.md` has a list of the inputs to gather (state directory, API
  address, company, tunnel, MSG91 file, administrator, Slack webhook, central sign-in), notes on host prerequisites, central
  sign-in and the storage permission, and says that notes from an older deployment do not apply;
  `docs/TROUBLESHOOTING.md` explains the "checker has never run" warning right after install and `ENETUNREACH` from the external doctor.
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
