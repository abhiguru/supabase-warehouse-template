# Changelog

## Unreleased: Grafana removed; alerts go to the facility's Slack

No dashboards any more, and no upgrade or retire path for them: no facility ran this code yet. Alerts reach people
through Slack only.

- **Grafana is gone.** The `grafana` service and its volume, `docker/grafana/` (recipe, plugin lock), the provisioning and
  the dashboard, `scripts/grafana-check.sh` with `npm run test:grafana` and its CI job, `GRAFANA_ADMIN_USER` and
  `GRAFANA_ADMIN_PASS` (no longer generated), the two ledger exceptions in `docker/image-exceptions.json`, the vendored
  AGPL-3.0 licence text and the notices. One image fewer. The `warehouse_monitoring` login stays: the Postgres exporter
  uses it (its description and the password rotation text no longer mention Grafana; migration 94 is unchanged).
- **Slack is the alert receiver.** Alertmanager renders `docker/alertmanager.slack.yml` (`slack_configs`,
  `api_url_file`, `send_resolved: true`; group wait 30 s, interval 5 m, repeat 4 h) with the facility's company name and
  `WAREHOUSE_PROJECT_NAME` in every title. It replaces the generic `docker/alertmanager.webhook.yml` and
  `docker/alertmanager.slack.example.yml`. The stored value must be `https://hooks.slack.com/services/...`; it stays in
  the state at mode 0600 and no message prints it.
- **`Watchdog` alert.** An always-firing rule (`vector(1)`, `severity: heartbeat`) routed to Slack with
  `repeat_interval: 24h`: a daily "Monitoring is alive" message. A day without it means alerting is broken. 20 rules now.
- **Monitoring starts when a webhook is stored.** `setup.sh` and `start.sh` start Prometheus, Alertmanager and the exporters (`scripts/start-monitoring.sh`); `doctor` warns when a stored webhook has no running monitoring. The heartbeat has its own receiver with `send_resolved: false`; mixed groups list resolved alerts apart; `npm run test:monitoring`'s synthetic alert never reaches Slack.
- **`setup.sh --operator` asks for the webhook.** The test message is posted before the URL is stored (refused: ask again or store anyway); `--alert-webhook-file ask` replaces a stored URL. On a terminal, without `--alert-webhook-file`, it prompts (no echo,
  three tries) and offers a Slack test message. With no terminal and no option it refuses. `--alert-webhook-file off`
  stays for non-production installs (warning; `doctor` reports "No Slack webhook: alerts are not delivered" on every run while none is stored, whether or not monitoring runs; to add a webhook later, rerun without `--alert-webhook-file off`, which then asks on a terminal, or pass a file). CI's
  operator-install job passes `off`.

## Unreleased: Realtime v2.144.0 (2026-10-19)

No migration. `docker/realtime/Dockerfile`: the setup rerun rebuilds the Realtime image.

- **Realtime v2.144.0** (was v2.143.3; Dependabot #123), a minor release: a decimal dependency upgrade, and extra
  region mappings for read replicas (new optional `DB_HOST_REPLICA_*` variables, unused here), which include the
  2.143.4 region-mapping fix. No setting changes. `THIRD_PARTY_NOTICES.md`, `docs/ATTRIBUTION_REVIEW.md`,
  `docs/CONTAINER_SECURITY.md` and `scripts/rotate-auth.sql` name the new version.

## Unreleased: GRN lists page by receipt, and a low-stock filter (migration 98)

Migration 98. The receipt lists of the app page item lines, so a receipt could be split across two pages and show
partial stock. Both functions keep their old behaviour unless the new key is sent.

- **Opt-in receipt paging (migration 98).** `get_all_grn_items` (staff) and `get_customer_grn_items` (customer) accept
  `p_filters.page_by = 'receipt'`: `p_limit` / `p_offset` then count receipts and all matching lines of each receipt
  on the page are returned. A receipt page is unbounded in lines (accepted). Without the key (older app builds) the
  line paging is unchanged. In line mode the customer function's first page got slower for very large customers
  (about 100 ms at 60,000 lines, measured by the review): accepted.
- **Receipt counts and `pagination.unit`.** In receipt mode `pagination.total_count` counts receipts (the customer
  function's `total` and `aggregations.total_count` too, and `has_more` follows); sums stay over all filtered lines.
  Both functions add `pagination.unit` (`'receipt'` or `'line'`).
- **Receipt-mode sort restriction.** Only `date`, `gr_no` and `customer_name`; a line sort
  answers `Invalid list parameters`. A NULL sort means `date` in the staff function only; the customer function
  accepts NULL and orders by raw receipt number alone (receipt mode) or by line id alone (line mode). Receipts with equal sort values order by receipt number and never interleave.
- **`stock_status = 'low_stock'`.** Lines with `0 < stock < 20% of qty`, in both functions (the staff list ignored
  the value, the customer list matched nothing). `in_stock` and `out_of_stock` are unchanged.
- **The staff list pins its item order** (`row_num`, then `grn_item_id`); it was only incidental before.
- Test: `tests/grn_receipt_pages_98.sql` (receipts whose line ids interleave, NULL dates and names, equal timestamps
  across customers, no match, offset past the end; it fails if either tie-break term is dropped). The customer function's document-number key (checked by
  `tests/document_number_sort.sql`) is not duplicated.

## Unreleased: pdf-renderer replaces Gotenberg

Gotenberg (rebuilt from source for CVEs, 2.2-2.6 GB with LibreOffice and pdftk we never used) is replaced by
`pdf-renderer`, a small service in `docker/pdf-renderer` that drives chrome-headless-shell through puppeteer-core with
Gotenberg's launch flags, print parameters and fontconfig. No migration, and no change to what the five PDF
functions send or return.

- **`functions/_shared/gotenberg-client.ts` is now `pdf-renderer-client.ts`** (same `htmlToPdf` and `createFooterHtml`).
  It posts to `${PDF_RENDERER_URL}/render` (default `http://pdf-renderer:3000`), keeps the 30 s timeout and
  `redirect: 'error'`, and logs at most 2 KB of the renderer's JSON error body. `GOTENBERG_URL` is `PDF_RENDERER_URL` in
  the Compose file and the function environment allowlist. The sample PDF's visible text no longer says Gotenberg.
- **Compose:** a `pdf-renderer` service on a new `internal: true` network `renderer`, shared with `functions` only
  (`functions` now has `default` and `renderer`, and does not `depends_on` the renderer). Read-only root, tmpfs `/tmp`
  256 MB, all capabilities dropped, `no-new-privileges`, 512 pids, 1.5 GiB memory with no extra swap, 30 s stop grace,
  no host port. The renderer cannot reach the internet, the database, Kong or Studio.
- **Scripts:** `health-check.sh` probes the renderer from inside its own container (storage cannot reach the internal
  network). `scripts/gateway-dns-check.sh` reads the functions address on `<project>_default` by name (functions has two
  networks now). `scripts/backup.sh` no longer stops a `gotenberg` service (under `set -e` the lookup would fail once the
  service is gone). `setup.sh` and `start.sh` remove an old gotenberg container of the project by Compose labels and,
  after the start, the old image; `stop.sh` runs `down --remove-orphans` (`scripts/retire-gotenberg.sh`).
- **Supply chain:** `docker/gotenberg/`, `LICENSES/gotenberg/` and the `gotenberg-os-no-fix` ledger entry (126 HIGH,
  1 CRITICAL, expiring 2027-01-15) are removed, and with them the Go-toolchain rebuild and its flaky upstream
  `go test` workaround. Dependabot tracks `docker/pdf-renderer` (npm; puppeteer-core is held back to patches because it
  moves with the pinned Chrome). `check:container-dependencies` runs `npm audit` on it. CI builds the renderer image and
  runs its unit tests and `test/integration.sh` with the hardening flags; a golden-PDF job renders 11 fictional template
  documents (`tests/golden-pdf/`), rasterises them at 150 dpi in a poppler container built from a fixed Debian snapshot and compares every page
  with the committed goldens at fuzz 0. `release.yml` fails when the pinned `CHS_VERSION` is more than
  14 days behind Chrome for Testing's current Stable, and `.github/workflows/cft-freshness.yml` checks the same weekly
  and opens or updates an issue.
- **Review fixes.** Debian packages in the renderer image are installed by name (security revisions vanish from the
  archive); the font-file hash and the golden job guard against drift. One literal `FROM` carries the Node digest so
  Dependabot reads it. `setup.sh` and `start.sh` check that Docker can allocate the renderer network
  (`scripts/network-preflight.sh`) before anything is changed, and remove the old container only after the build and
  migrations, right before the full start. The golden job compares decoded pixels in a container built from a fixed
  Debian snapshot, posts the same fields as the function client and uploads diff images on failure. The CfT freshness
  check answers "unknown" (exit 2) when release dates cannot be read and retries its fetches. `health-check.sh` probes
  the renderer from `functions`. The renderer audit runs at HIGH, a fresh browser starts with a zero memory figure,
  two flaky tests are deterministic, and `integration.sh` fails a skipped check in CI and has no host-specific lock.
- **Docs and notices:** ARCHITECTURE, CONTAINER_SECURITY (renderer posture, the `--no-sandbox` reasoning, update
  cadence, why Trivy cannot see the Chrome for Testing binary), PDF_GENERATION, TROUBLESHOOTING (the image has no
  curl; use `node -e`), OPERATOR_INSTALL (upgrade note), ATTRIBUTION_REVIEW and THIRD_PARTY_NOTICES (Chrome for Testing
  BSD-3 with its bundled notices, puppeteer-core Apache-2.0). `config/seed-config.sql` describes the capability as
  "PDF generation via the built-in renderer"; installations already seeded keep their old description text
  (the seed is `ON CONFLICT DO NOTHING`).

## Unreleased: ops review wave 4 — hashed Python requirements, storage lockfile guard, build-date drift

The rest of TW-BE-005 from the 2026-10-17 operational review (owner decision D5). No migration.

- **The sensor bridge installs only hashed packages.** `docker/sensor-bridge/requirements.txt` pins every package of
  the closure with its sha256 hashes (CPython 3.14, Linux amd64 and arm64); the image and CI install with
  `pip install --require-hashes`, and pip is removed from the image afterwards.
- **The storage build fails if `npm install` changes `package-lock.json`, or if the production tree is invalid**
  (`npm ls --omit=dev --all`). The `undici` override is now `undici@^7`, so `@kubernetes/client-node` keeps the undici
  8 it declares (the old override forced every copy to 7.30.0). Regenerate the lockfile with npm 11.12.1 (see
  `docker/storage/README.md`).
- **Build-date drift (D5).** OS packages in the image recipes come from live mirrors, so a rebuild on another day can
  differ; `docs/CONTAINER_SECURITY.md` says so, and the release checklist's one image step (`npm run scan:images`
  on a throwaway state, which builds with `--no-cache`) is mandatory before every release.

## Unreleased: ops review wave 3 — receipts, sign-in refusals, OTP provider answers, monitoring, realtime, operations (migrations 95–97)

Fixes from the 2026-10-17 operational review: TW-BE-012/013, TW-BE-017, TW-CFG-001…006, TW-BE-014, TW-BE-008,
TW-BE-018, TW-BE-021, TW-BE-015, TW-BE-011, X-6 and X-7.

- **A receipt takes the catalog's widths (migration 95, TW-BE-012/013, owner decision D7).** `goodsreceived_trl`
  holds item names of 80 and packaging of 40 characters (was 30/20), so an accepted catalog item no longer fails
  `save_grn` with `string_column_length`. The four dependent views are recreated with identical definitions, indexes,
  owners and grants; `save_grn`/`update_grn` answer `item_name_too_long` / `packaging_too_long` with the limit before
  writing anything. The migration takes the document lock 71040 first, so GRN, dispatch and invoice saves wait for
  the rebuild (seconds) instead of failing.
- **A refused central sign-in writes nothing (migration 96, TW-BE-017).** A rejected, disabled or service-account
  profile found by (issuer, subject) is no longer marked verified before the refusal; `operator_verify_otp` follows
  the same order. Migration 81's rules are unchanged.
- **OTP provider answers (migration 97, TW-CFG-001…005, X-7; decisions D13–D15).** A success without a usable request
  ID counts as sent and is stored as `success_no_id` (the code stays valid; no second SMS); a contradictory answer is
  `provider_invalid_response`, never retried; a timeout or abort is `provider_ambiguous` and is not refunded; a
  never-refunded provider-attempt counter with an optional `otp_daily_provider_attempt_cap` (off until set; text `0`
  stays the no-send switch). The OTP hash is documented as HMAC-SHA256; the docs no longer claim pg_cron cleanup
  (TW-BE-014). One placeholder rule for the provider, `doctor` and `configure`: an empty, `your-`, `changeme`,
  `fake_` or `isolated-` value never sends.
- **Monitoring (TW-BE-008, TW-BE-018, TW-BE-021; decisions D6, D9, D11).** Each installation renders its own
  Prometheus configuration with an `installation` label, and cAdvisor keeps only its own project's containers; an
  optional `setup.sh --alert-webhook-file` sends alerts to an https webhook (unset by default; `doctor` warns while
  alerts are local only). Backups write `warehouse_backup.prom`; new `BackupMissing` (26 h) and `BackupFailed` rules;
  promtool tests for all 19 rules, run in CI. Grafana ships the "Warehouse overview" dashboard (read-only); Grafana
  alerting is out of scope. Alertmanager keeps its state across recreates. `restore-host` renders the monitoring files.
- **Realtime joins on the first try (TW-BE-015).** `dns_search: "."` on realtime (the IPv6 lookup of `db` took about
  8 s); setup and start run a best-effort warm-up join.
- **Operations.** Backup fingerprints cover payments, orders, order items and order revisions (TW-BE-011; a fingerprint
  recorded before this release is not line-comparable). `setup.sh --gateway-port` chooses the loopback port of a
  second facility on one host (TW-CFG-006). The Compose requirement is a plugin whose `up` accepts `--wait-timeout`,
  tested with v2.40.3 and v5.6.0 on Engine 29.9.1, the same list as the central identity service (X-6); `doctor`
  checks it.
- Upgrade: `setup.sh --operator` (renders the monitoring files and applies 95–97); schedule `db:backup`, or
  `BackupMissing` fires.

## Unreleased: ops review — image advisories, exception ledger, PostgREST pinned

Fixes from the 2026-10-17 operational review (TW-BE-009, TW-BE-010, TW-BE-005 part 1; owner decisions D3, D5). No
migration, no new environment value.

- **Images.** The database recipe upgrades OpenSSL, GnuPG, PackageKit and sudo (glibc, locales and the locale archive
  are checked unchanged in the build, so collations stay valid); edge-runtime takes all Debian updates; Gotenberg's
  8.37.0 binary is rebuilt from source with Go 1.27.2 and x/net 0.60.0; Studio 2026.10.12-sha-3699278; Grafana
  13.2.4 with the newest signed plugins; the sensor bridge image no longer ships pip. Rows with a listed fix:
  db 20→0, functions 7→0, gotenberg 4→0, sensor bridge 4→0, Studio 6→5 and Grafana 47→41 (no fixed publisher
  release yet; covered by the ledger).
- **Exception ledger and two-pass scan.** `npm run scan:images` builds with `--no-cache` on a throwaway state (it
  refuses while the project has containers) and scans every image with and without `--ignore-unfixed`; every
  HIGH/CRITICAL row must be fixed or covered by an entry of `docker/image-exceptions.json` (owner, reason, review
  date, expiry within 90 days; an entry names its advisories, packages and targets; expired, ownerless or unused
  entries fail or warn). The ledger expires on 2027-01-15.
- **PostgREST** v16.4 is pinned by its index digest; its missing package inventory is a time-boxed exception bound to
  that digest, with compensating controls.
- **The Gotenberg build runs no upstream test suite.** Upstream's timing-sensitive tests failed on a loaded CI
  runner ("expected queue size to be 10 but got 8"), and every operator install builds this image; `go mod verify`
  and the pinned read-only build stay.
- **Release checklist:** image scan before every release (D5). Dependabot no longer proposes Gotenberg tag bumps (the
  source build must move with the base tag).
- Upgrade: `setup.sh --operator` rebuilds the changed recipes; the db container restarts once.

## Unreleased: ops review wave 2, part 2 — one database password per login (migration 94)

Review finding TW-BE-002, owner decision D4. `POSTGRES_PASSWORD` was the password of every database login; it is now
the superuser's only (`postgres`, `supabase_admin`).

- `setup.sh` (through `scripts/configure.mjs`) generates `DB_PASSWORD_AUTHENTICATOR`, `DB_PASSWORD_STORAGE`,
  `DB_PASSWORD_AUTH`, `DB_PASSWORD_POOLER`, `DB_PASSWORD_MONITORING` and `REALTIME_DB_ENC_KEY`. An existing state
  gains the missing ones on the next setup run; a value that exists is never replaced.
- `scripts/configure-db-roles.sql` sets each login's password on every setup run and after both restores. Values
  travel as SCRAM-SHA-256 verifiers on standard input (`scripts/db-roles.sh`): no password reaches the server, a
  log, `pg_stat_statements` or a command line.
- Migration `00000000000094_monitoring_role.sql`: `warehouse_monitoring` (member of `pg_monitor`, nothing else) for
  the Postgres exporter and the Grafana datasource, which signed in as `postgres`; `supabase_functions_admin` can no
  longer sign in.
- Compose: PostgREST, Storage, Auth, the pooler's pool user, the exporter and Grafana use their own value
  (`${NAME:?...}`: a state without it stops at `compose config`). Realtime's `DB_ENC_KEY` is the generated
  `REALTIME_DB_ENC_KEY` instead of the fixed `supabaserealtime`. The pooler rewrites its pool user's password at every
  start. The Grafana datasource is no longer editable.
- New commands: `npm run db:rotate-passwords -- --yes [--superuser]` (rotation with automatic rollback; an
  interrupted rotation is recovered by asking the database which file it matches) and `npm run test:db-roles` (it
  first proves the superuser password, then that each login refuses `POSTGRES_PASSWORD` and accepts only its own,
  over SCRAM and the network).
- Restores: a backup taken before this release restores in place with the installation's values;
  `--restore-config` and `db:restore-host` give its configuration new values before the database starts.
- **Upgrade:** run `setup.sh` right after `git pull`, before any other command; it restarts the database and every
  service once. Then `npm run test:db-roles`, `npm run db:rotate-passwords -- --yes --superuser` (the old shared
  value sat in five service environments and in Grafana's datasource store) and a new backup.
- Docs: `docs/CONTAINER_SECURITY.md` ("Database passwords: one per login"), `docs/OPERATOR_INSTALL.md` ("Rotating
  the database passwords", the upgrade note).

## Unreleased: ops review wave 2, part 1 — signing secret, pg_net, key cache, gateway log, unsigned backups (migrations 92, 93)

Fixes from the 2026-10-17 operational review (TW-BE-001, TW-BE-003, TW-BE-004, TW-BE-019, TW-BE-022). Ships with
central identity 0.8.1 (key-set caching, TW-ID-001).

- **The JWT signing secret is no longer a database setting (migration 92, TW-BE-003).** The template stored it as
  `app.settings.jwt_secret` (and PostgREST set it again per request), readable by every role with `current_setting()`.
  The migration resets it at database level and for any role that holds it; `scripts/configure-auth.sql` repeats the
  reset on every setup run; `jwt.sql`, `rotate-auth.sql` and the `rest` service no longer set it. Nothing read it.
- **pg_net is for the service roles only (migration 93, TW-BE-004).** anon, authenticated and PUBLIC lose USAGE on
  schema `net`, EXECUTE on `net.http_get`/`net.http_post` and EXECUTE on `supabase_functions.http_request()` (which a
  role with TEMP could otherwise drive from its own trigger); `supabase_functions_admin`, postgres and service_role
  keep them, so database webhooks still fire. The event-trigger function no longer re-grants on `CREATE EXTENSION`;
  `webhooks.sql` is corrected for new installs.
- **The facility's key cache honours the 5-minute withdrawal (TW-BE-001, cross-repo X-1).** A fetched key set is used
  for at most 4 minutes (was 10), or for the answer's `max-age` less `Age` if shorter, and is fetched with
  `cache: 'no-store'` and `Cache-Control: no-cache`. The unknown-key-id limit and the back-off are unchanged.
  Facilities that use a key file rerun `setup.sh --central-jwks-file` with the new file in an emergency.
- **The gateway access log keeps no query strings (TW-BE-019).** Format `warehouse_redacted`: client address, method,
  path, status, size, time; signed-URL `?token=` and Realtime `?apikey=` are no longer kept, nor referer or user
  agent. Storage no longer receives `CF-Connecting-IP` (Kong itself sets `X-Real-IP` and `X-Forwarded-For`, which
  storage still logs; accepted under owner decision D10). New "Logs" contract in `docs/CONTAINER_SECURITY.md`.
- **A stripped v5 backup is refused (TW-BE-022).** `db:verify-restore`, `db:restore` and `db:restore-host` refuse a v5
  backup whose `SHA256SUMS.hmac` is missing while the backup key is available, even with `--allow-unsigned`, which is
  now only for backups written before v5 or a lost key.
- Upgrade: `setup.sh --operator` recreates `rest` and Kong (the recreate drops the old gateway logs; links already
  logged stay valid until they expire).

## Unreleased: ops review wave 1 — lists refresh after the commit (migration 91), the key file in backups

Fixes from the 2026-10-17 operational review, wave 1 (the acceptance gate TW-BE-016, plus TW-BE-023 and TW-BE-020).

Migration `00000000000091_list_refresh_off_write_path.sql` (TW-BE-016, TW-BE-023; owner decision D2):
- **Writes no longer refresh materialized views.** They mark the lists they change and return. The pg_cron job
  `warehouse-list-refresh` refreshes the marked lists every 5 seconds as the password-less LOGIN role
  `warehouse_list_refresher` (`CALL warehouse_security.refresh_dirty_lists_worker()`): CONCURRENTLY, one commit per
  list, lock 71046, never the document lock 71040. Measured at 4,000 and 12,000 GRNs: a one-line dispatch takes
  13–17 ms (was 0.9–5.6 s) and 10 concurrent dispatches all commit with no statement timeout (before: 1 to 8 of 10).
- `get_invoices_list`, `get_dispatch_list` and the legacy `get_all_grn_items(p_catalog_id, ...)` overload are
  eventually consistent within 15 s (typically 3–4 s); write answers are authoritative. New `get_list_freshness()`
  (staff, supervisors, administrators).
- Every table marks every list that reads it: line changes reach both daily summaries (TW-BE-023), and receipt and
  customer header changes reach the stock, dispatch and invoice lists. Marks always count (`mark_seq`), so a write
  committed during a refresh is not lost. `update_grn` marks the seven lists and no longer refreshes them.
- The migration run holds lock 71046 (waits up to 120 s and names the holder), so no list refresh runs during a
  migration. The db runs with `cron.log_statement=off`.
- Setup and restore run `scripts/configure-list-refresh.sql`; `db:verify-restore` leaves pg_cron's own objects out;
  the doctor (`health-check.sh`) checks the job, the runner, the 15 s bound and names a foreign holder of 71046. For a
  manual run use the one-shot command in `docs/OPERATOR_INSTALL.md`, never an open psql session.
- Upgrade: run `setup.sh --operator` (it recreates the db with the new command line and creates the job).
- Tests: new `tests/list_refresh_worker.sql` and `tests/list_refresh_worker.sh` (lost-refresh race, five parallel
  dispatches under an 8 s statement timeout, migration/worker overlap); five SQL tests run the refresh before reading.

Backups carry the central sign-in key file (TW-BE-020):
- `db:backup` copies `public/central-jwks.json` (when the keys come from a file) as `central-jwks.json`, listed in
  `SHA256SUMS` and so signed; `db:verify-restore` accepts it only as a regular, checksummed file; `db:restore-host`
  installs it as `public/central-jwks.json` (0644). Format stays `warehouse-backup-v5`: the file is optional.
- A restore from a backup that names a key file it does not carry (an older backup), by `db:restore-host` or
  `db:restore --restore-config`, finishes and prints the exact `setup.sh --operator ... --central-jwks-file` rerun;
  its final `doctor --local` only warns about the missing file.
- `doctor` fails when `CENTRAL_JWKS_FILE` is set and the file is missing, not a regular file, over 64 KB, not JSON or
  without a usable P-256 key.
- Docs: `docs/OPERATOR_INSTALL.md` (restore paragraph reconciled with the lost-host section; new lost-host step 7),
  `docs/CENTRAL_LOGIN.md` (the key file is part of a backup).

## Unreleased: staff lose item pricing (migration 90)

Migration `00000000000090_staff_no_pricing.sql`, owner decision of 2026-10-16: item pricing is for administrators
and supervisors only. This takes back the staff access of 11 October 2026 (migrations 45, 76, 85, 86).

- The guard (`warehouse_security.authorize_rpc`) no longer lists `get_item_storage_prices`,
  `create_item_storage_price`, `update_item_storage_price`, `delete_item_storage_price`, `replace_item_rates`,
  `undo_rate_change`, `get_standard_rate`, `set_standard_rate` and `get_item_grn_rates` for staff: a staff call is
  refused with SQLSTATE 42501, 'Staff access required'. Administrators and supervisors are unchanged. Staff keep
  `get_grn_item_rates` (migration 88, answer unchanged) and `generate_invoice_data_for_grn_with_pricing`, so they still
  see the rate that applies to a GRN and still invoice.
- `save_grn` and `update_grn`: a staff call with `p_rates` (a list or `[]`) is answered `RATES_MANAGER_ONLY` before
  anything is written; without `p_rates` it works as before.
- `get_grn_details` answers `grn.rates = []` to staff (as to a customer account).
- The staff branches inside the bodies (migration 76 rate-in-force rule, migration 85 `STANDARD_RATE_MANAGER_ONLY`)
  are left in place and are now unreachable. No row policy changes.
- Tests: new `tests/staff_pricing_90.sql`; the staff blocks of `tests/role_allowlist.sql`, `tests/item_rate_changes.sql`,
  `tests/standard_rate.sql`, `tests/grn_rates.sql`, `tests/item_price_history.sql`,
  `tests/staff_dispatch_invoice_access.sql`, `tests/grn_item_rates_88.sql` and `tests/concurrent_rules.sh` now assert the
  refusal, and the changes they ran as staff run as a supervisor.
- Deploy order: the app release that hides the pricing screens and the rate fields of the GRN sheet from staff must go
  first or together with this migration; an older app shows those screens to staff and they fail.
- Docs: [docs/STAFF_GRN_POLICY.md](docs/STAFF_GRN_POLICY.md) (role table, "Staff lose item pricing, 16 October 2026"),
  [docs/API_CONTRACT.md](docs/API_CONTRACT.md) (`RATES_MANAGER_ONLY`, roles).

## Unreleased: a customer sees its GRN rates as its own (migration 89)

Migration `00000000000089_customer_rate_view.sql`, owner decision of 2026-10-16: a customer account must see
only the rate that applies to it, the default rate presented as its own. An audit of everything a customer
account can call or read found one function that said more: `get_grn_item_rates` named the default rate
(`source = 'item'`) and returned the band edges of the default or customer rate row. It now answers a
customer account with `source = 'customer'` for every rate that is not an invoice figure and
`weight_min` / `weight_max` null; figures, lots and order are unchanged, and staff get the full answer.
No other function or table gives a customer default rates, standard tiers or another customer's rates
(the rate tables are administrator and supervisor only; invoices and dispatches carry only the
customer's own invoiced figures). Test: `tests/grn_item_rates_88.sql` (customer view, sections 4 and 5).

## Unreleased: `get_grn_item_rates` (migration 88)

Migration `00000000000088_grn_item_rates.sql`. New `get_grn_item_rates(p_grn_id)`: the rate each lot of a GRN
is invoiced at and where it comes from (`invoice`, `grn`, `customer`, `item` or none), with the weight band and
a `varies` flag for an invoiced lot whose lines differ. The guard admits it for staff and, owner decision of
2026-10-16, for a customer account on the GRNs of a customer it owns (`get_grn_details` still answers
`grn.rates = []` to them). Test `tests/grn_item_rates_88.sql`.

## Unreleased — fixes from the outside backend review of 2026-10-15 (migration 87)

Migration `00000000000087_review_fixes.sql` (patches existing functions in place; no new RPC, no
signature change) plus two operator scripts that `setup.sh` re-applies. The review's ten findings
(seven Medium, three Low; none High) against main `b41ec58`; all were still present on `02ec401`.
App: the matching rn-warehouse-template release (photo rollback after a lost confirm, Leon flag).

- **Users** (BR-01): `update_user_role` and `update_user_status` take the last-administrator lock
  and read the target row `FOR UPDATE` before any check, so a supervisor's change can no longer
  overwrite an administrator promotion committed meanwhile (the supervisor is refused instead).
- **Dispatch** (BR-02, 03, 06, 07): a dispatch locks the cart line it consumes, so a quantity edit
  committed meanwhile is not lost; the same lot twice in the lines is refused ("The same lot appears
  twice in the dispatch lines", on create and edit) instead of writing duplicate stock movements; a
  `source_order_id` must be a live cart of the dispatch's customer ("The order belongs to another
  customer"; an edit may not move a cart-sourced dispatch to another customer), and
  `get_cart_dispatches` lists only that customer's dispatches; the document lock is taken before the
  idempotency lookup, so an overlapping retry with the same key answers the cached result
  (`from_cache: true`) instead of a `23505` duplicate-number error.
- **Rates** (BR-04): `create_item_storage_price`, both `update_item_storage_price` overloads,
  `find_or_create_item_storage_price` and `delete_item_storage_price` take the same per-scope
  advisory lock as `replace_item_rates`, so two concurrent writers cannot commit overlapping bands;
  `find_storage_price` has a final `id` tie-break.
- **GRN list** (BR-08): `total_weight` in `get_grn_list` and the weight sum in
  `get_customer_dispatch_items` are computed in numeric (a 50 000 kg × 50 000 line no longer
  overflows the list).
- **Photos** (BR-05): `cancel_grn_image_upload` / `cancel_dispatch_image_upload` answer
  `ALREADY_CONFIRMED` (with `image_id`, `storage_path`) for a row the confirm already committed, so
  the app keeps the file and reports the photo as attached. `scripts/configure-storage.sql`: an
  administrator or supervisor can delete an object in `grn-images`, `dispatch-images` or
  `customer-images` only when no `grn_images` / `dispatch_images` row and no document image URL
  references it (policy `starter_staff_images` replaced by `starter_manager_images_*`).
- **Restore** (BR-10): `scripts/restore-host.sh` binds the checksum record to the selected
  archive — exactly one record, its filename must be the selected archive, and the archive's bytes
  are hashed directly — before the signature check and before anything is listed or extracted.
  A companion copied from another archive is refused.
- **From the second (Opus) review of this change:** the duplicate-lot check compares lot ids as
  uuids, so the same lot in a different spelling is refused too; the old nine-argument
  `update_item_storage_price` refuses overlapping rates of its own price type (`BANDS_OVERLAP`);
  the order list and the order detail show only a dispatch of the cart's own customer; cancelling an
  upload waits for a confirm that is still open and then answers `ALREADY_CONFIRMED`;
  `get_dispatch_list_with_items` sums weights in numeric; the rate delete re-reads the start date
  under its lock. Migration 87 ends with a notice counting dispatches linked to another customer's
  cart (0 on the three development facilities). `restore-host.sh` hashes the archive from standard
  input and refuses a checksum file with CRLF line endings, naming CRLF.
- Tests: `tests/concurrent_rules.sh` cases 7–11 (role lock, cart line lock, overlapping retry,
  rate writers, cancel during confirm), new `tests/storage_delete_rules.sql`, cases in
  `document_write_consistency`, `dispatch_lot_ownership`, `grn_list_end_day`, `item_rate_changes`,
  `staff_dispatch_invoice_access`, `restore-host.test.mjs`.

## Unreleased — every item always has a rate: standard rate (migration 85) and rates set on the GRN sheet (migration 86) (2026-10-15)

Migrations `00000000000085_standard_rate.sql` and `00000000000086_grn_rates.sql`, applied by the setup
rerun. App: the matching rn-warehouse-template release (Standard rate screen, Add on the Item pricing
list, Rates section on the GRN Review step). Owner decisions of 2026-10-15; the design is in the app
repository's plan record. Deploy at a quiet moment: migration 86 re-creates `save_grn` and `update_grn`
in one transaction and reloads PostgREST.

- **Standard rate** (`standard_rate_tiers`, `get_standard_rate`, `set_standard_rate`): the facility's
  monthly weight tiers (0–10, 11–20, 21–30, 31–50 kg by default) with rent, labour and tax each,
  set by administrators and supervisors. Saving it gives every active item that has no default rate
  rows the tiers from the India day of the item's first non-deleted GRN (today without a GRN) and
  answers `items_priced`. A later change applies to items added after it only (no bulk change).
- **`create_item(…, p_rate_from_item)`**: a new item gets the standard tiers from today, or a copy of
  another item's default rows in force today (both price types, one row per band, no customer rows);
  `data.rate_source` = `standard` | `copied` | `none`. `update_item` gives a reactivated item without
  default rows the standard tiers. Both take the shared `standard_rate` advisory lock so a save of the
  standard rate and an item creation never cross.
- **Rates set on the GRN sheet** (`save_grn` and `update_grn` gain `p_rates jsonb DEFAULT NULL`, last
  parameter; old named calls, FAS sync included, are unchanged). With an array the save refuses
  `RATE_MISSING` when a line has no rate for the GRN's customer, weight, India day and price type, and
  applies the entries first: `customer` / `everyone` entries insert one bounded rate row from the GRN
  day (the overlapped row ends the day before, resumes after `to` with its old figures, and the
  scope's other bands are split on the same days so Correct and Undo on Item pricing keep working;
  a planned later rate answers `RATE_PLANNED`, a partial band clash `BANDS_OVERLAP` with
  `data.starts_on`); `grn` entries are the GRN's own rates in the new table `grn_rates` (upserted by
  band, `updated_by`/`updated_at` on change). Staff may do all three from the GRN day (the Item
  pricing past-day rule does not apply here). An invoiced GRN keeps its set (`GRN_INVOICED` on a
  change) and is not checked line by line, so a note-only edit saves. `update_grn` drops a GRN's own
  rates whose price type or band no longer fits its lines. `delete_item_safe` refuses an item with
  `grn_rates`. Customers never read `grn_rates`; `get_grn_details` answers `rates` = `[]` to them.
- **Invoices** (`build_invoice_recalculation_rows`): a line's rent, labour and tax come from one
  source — the stored invoice figure, else the GRN's own rate, else `find_storage_price`. A saved
  invoice keeps its figures ("archived once invoiced"); deleting it lets the GRN rate apply again.
  `get_grn_details` returns `grn.rates` with `archived`; new `get_item_grn_rates(p_item_id)` lists an
  item's GRN-only rates (administrators, supervisors, staff).
- **Rate start floor** (`warehouse_security.rate_start_floor`): `replace_item_rates` and
  `undo_rate_change` accept a start as far back as the facility's oldest non-deleted GRN or three
  years, whichever is earlier (the three-year guard of migration 76 only grows backwards);
  `INVALID_DATE` names the day in `data.earliest`, and `get_item_storage_prices` answers a top-level
  `earliest_start`.
- `replace_item_rates` and `set_standard_rate` accept weights written as `50.0`.
- `scripts/data-fingerprint.sh` and `scripts/backup-integrity.sql` cover `standard_rate_tiers` and
  `grn_rates`. Tests `tests/standard_rate.sql`, `tests/grn_rates.sql`, two new cases in
  `tests/concurrent_rules.sh`; `docs/API_CONTRACT.md`, `docs/INVOICE_RULES.md`,
  `docs/STAFF_GRN_POLICY.md` updated.

## Unreleased — no GRN moved onto a deactivated business (migration 84); bridge skips offline sensors (2026-10-15)

Migration `00000000000084_grn_move_deactivated_business.sql`, applied by the setup rerun; the sensor
bridge image is rebuilt. No app change: the app's Edit GRN customer picker (`search_customers`) never
offers a deactivated business, and its save path already shows the migration 83 text.

- **`update_grn` refuses to move a GRN onto a business with `active = false`**, with the migration 83 text
  `This business is deactivated. Activate it in Customers to receive new goods.` (P0001, every caller, bare
  text). This closes the gap noted under migration 83 below. A deleted business keeps `Business is not
  active`; editing a GRN that already belongs to a deactivated business, without changing the business,
  stays allowed. FAS sync is not affected: its `update_grn` call never passes a business (a business that
  differs between FAS and the facility is left as it is), and its new GRNs were already refused by
  migration 83.
- Migration 84 drops a `pg_temp.patch_rpc` left by migration 83 before it creates its own, so the
  migrations still run in one session.
- **Sensor bridge: a sensor the hub reports offline is no longer posted.** The hub keeps returning the
  last values of a sensor it cannot hear; the bridge sent them as fresh heartbeats, so the app showed a
  dead sensor as live (seen on the dev facility: "th4 anti chamber" at a constant 31.6 °C / 68 % for two
  days with the hub reporting it offline). The bridge now reads the hub's `status` for each sensor and
  skips one that is `offline`: no change and no heartbeat, so the app shows "No recent data" once the
  sensor's staleness threshold (30 minutes by default) passes. `event=sensor_offline` and
  `event=sensor_online` are logged once per transition, and `--dump` shows each sensor's status. A
  sensor without a `status` field is handled as before. The queue and change-detector state on `/data`
  are unchanged.
- New test `tests/grn_move_deactivated_84.sql`, registered after `grn_deactivated_83.sql`; ten new
  bridge unit tests.

## Unreleased — no new GRN for a deactivated business, migration 83 (2026-10-15)

Migration `00000000000083_grn_deactivated_business.sql`, applied by the setup rerun. The matching
app branch is rn-warehouse-template's `fix/grn-deactivated-2026-10-15`, which shows the message.

- **`save_grn` refuses a business with `active = false`** (owner decision, 2026-10-15): `This business
  is deactivated. Activate it in Customers to receive new goods.` (P0001), for every caller, next to the
  deleted-business refusal of migration 82. Only NEW GRNs: `update_grn`, dispatches and orders of a
  deactivated business are unchanged. `update_grn` can still move an existing GRN to a deactivated business (the owner's rule covers only
  new GRNs). The refusal is raised outside `save_grn`'s inner exception block, so the client gets the bare text
  (P0001), not wrapped in "Error creating GRN". This narrows migration 82's entry below, which said `save_grn`
  accepts a deactivated business.
- **FAS sync:** its GRN push (`create_grn` in `fassync/push.py`) calls `save_grn`, so a push for a
  deactivated business now fails with that message until the business is activated in Customers.
- **`update_customer(p_active => true)` also clears `deleted_at` / `deleted_by`**, so a business is never
  active and deleted at once (as `set_customer_active(true)` and `restore_customer`). `false` and NULL
  are unchanged.
- New test `tests/grn_deactivated_83.sql`, registered before `report_grn_invoices.sql`.

## Unreleased — deactivated businesses can still order, migration 82 (2026-10-15)

Migration `00000000000082_inactive_business_orders.sql`, applied by the setup rerun. The matching
app branch is rn-warehouse-template's `fix/open-items-2026-10-15`; an older app ignores the new
field and keeps working.

- **`get_or_create_cart` refuses only a deleted business.** Migration 80 also refused a business
  with `active = false`; that is reversed (owner decision, 2026-10-15) and migration 80's entry
  below about deactivated businesses is superseded by this one. A deactivated business is treated like an
  active one, for its customer logins and for staff: existing order, new order, DISPATCHED to OPEN
  reset. A deleted business (`deleted_at` set) is still refused with `Business is not active`
  (P0001) for everyone; since only a business without data can be deleted (below), no order is stuck.
- **Deactivate is not delete (owner decisions A and B).** New `set_customer_active(p_customer_id,
  p_active)` (administrators and supervisors; staff and customers are refused): `false` sets
  `active = false` only, with no stock check and never `deleted_at`; `true` sets `active = true` and
  clears `deleted_at`/`deleted_by`. What deactivation hides, exactly: the business is no longer
  offered by the staff pickers that use `search_customers` (new GRN, dispatch, order, and the list-filter
  customer search) and by the all-customers branch of `search_customer_items_for_order`, and
  `assign_customer_to_user` cannot give it a new customer login. Nothing else is hidden: its customer logins
  still see all its GRNs, dispatches, invoices, stock and reports and can order their goods out; `save_grn`,
  `update_grn` and the dispatch RPCs do not check `customers.active`; and staff and administrators see it in
  five readers that used to hide it (the filter is now `deleted_at IS NULL`): `get_invoices_list`,
  `get_all_stock_summary`, `get_item_wise_stock_list` (all customers), `get_all_customer_activity_summary`
  and `get_item_dispatch_records`.
  (`get_customers_with_stock` was already removed by migration 71.)
- **Nothing with data is ever deleted.** Data = any GRN, dispatch or invoice row (deleted rows too), any
  payment, any customer-specific rate, any active assignment, any order with lines or not OPEN.
  `safe_delete_customer` for such a business: soft deactivates it instead (`delete_type: 'deactivated'`,
  message `"<name>" has records, so it was deactivated instead of deleted.`; `active = false` only), permanent
  refuses with `Cannot delete "<name>": it has GRNs, dispatches, invoices, payments, rates, linked users or orders. Deactivate it instead.`
  and `related_records` with the counts. Without data the old delete flow applies; only a permanent delete
  removes the empty OPEN carts (and switched-off assignments). `restore_customer` takes a deleted or an
  inactive business and makes it active. So the released app's Deactivate and Activate keep working.
- **Deleted businesses get no new documents:** `save_grn`, both `create_dispatch_with_stock_check`
  overloads, and `update_grn` when it moves a GRN to a deleted business, raise `Business is not active` (P0001) for a deleted business; a deactivated one is accepted.
- **Data fix in migration 82:** a soft-deleted business that has such data gets `deleted_at` and
  `deleted_by` cleared and stays `active = false`, so it shows as deactivated; the count is logged
  with `RAISE NOTICE`.
- **`get_orders_list`** leaves out orders of a deleted business (so its leftover empty cart is never listed) and adds `active` (boolean) inside each row's `customer` object, next to `name`.
  Nothing else changes. The released app on migration 82 keeps working (its Deactivate and Activate calls are
  handled above), but still disables "+" for a deactivated business until the new app ships.
- **Tests:** `tests/backlog_80.sql` cart section follows the new rule; new `tests/open_items_82.sql`
  covers the `active` flag (administrator, staff, customer), `set_customer_active`, the delete rules and the data fix.

## Unreleased — one association sign-in for every facility, migration 81 (2026-10-15)

Migration `00000000000081_central_single_sign_in.sql`, applied by the setup rerun; then recreate
the functions container (`bash scripts/compose.sh up -d --force-recreate functions`). Owner
decision of 2026-10-15, which replaces the earlier rule "the central service's word alone never
opens an existing profile": the association sends the only sign-in code, and with it a person
opens every facility that trusts the association.

- **The association's token opens an existing person profile.** A profile found by the
  central-verified phone number and not linked yet is linked to the identity and signed in (an
  approved one), made pending (a waiting request) or refused (`account_unavailable`: rejected,
  disabled, deactivated; a refused profile is not linked), with no SMS code of this facility. After that it is found by the central
  subject. **Accepted consequence:** whoever controls the central service, or a number's SMS
  there, can open any person profile with that number at a facility that leaves the extra code
  off, administrators included. `identity_conflict` (the number's profile is linked to another
  identity) is unchanged.
- **A service account is never opened this way**: `account_unavailable`, found by phone or by
  subject, and it is not linked (migration 78's `is_service_account`).
- **A facility's own code, optional, default off.** `setup.sh --central-local-code on|off`
  (stored as `CENTRAL_LOCAL_CODE` in `compose.env` and as `auth_config` key `central_local_code`
  by `scripts/configure-central.sql`). With it on, an approved profile, linked or not, gets
  `link_required` without `otp_code` at **every** exchange, and with `otp_code` the code is checked
  by `operator_verify_otp` (all its limits) and its answer, with the link fields, is returned.
  Refused unless central sign-in is configured. A rerun without the flag keeps the stored value,
  as for the issuer and the keys; `--central-issuer off` clears it. The `link_required` message is
  now "This facility asks for its own code each time you sign in."
- **`get-public-config`** adds `centralLogin.localCode` (boolean), only when `centralLogin` is
  advertised; `CENTRAL_LOCAL_CODE` is passed to that function's worker and the functions
  container.
- **Pending answers name the link** (`central_issuer`, `central_subject` in their short
  `data.user`), as the link answer already did since migration 64.
- **Tests:** `tests/central_login.sql` rewritten for the new rule (setting off and on),
  `tests/configure.test.mjs` and `tests/migrations.sh` for the flag, `tests/central-exchange.test.mjs`
  for the message and `localCode`.
- **Docs:** `CLAUDE.md`, `docs/CENTRAL_LOGIN.md`, `docs/OPERATOR_INSTALL.md`.

## Unreleased — backlog fixes, migration 80 (2026-10-14)

Migration `00000000000080_backlog_fixes.sql`, applied by the setup rerun; then recreate the
functions container (`bash scripts/compose.sh up -d --force-recreate functions`). The matching app
change is rn-warehouse-template's `fix/backlog-2026-10-14`; an older app keeps working (it never
sends a service account as supervisor on its own and treats a missing `get_my_access_status` as
"no business linked").

- **A service account may be a supervisor only when it is the one saving.** `save_grn`,
  `update_grn`, `create_dispatch_with_stock_check` (both overloads) and `update_dispatch_smart`
  refuse a service-account profile named as supervisor with `Supervisor must be a person, not a
  service account` (P0001), unless it is the caller's own profile (FAS sync acting as itself keeps
  working) or the document's unchanged supervisor. `update_grn` answers `GRN not found` first.
  `update_dispatch_smart` reports it in its usual `{success: false, error}` form. New helper
  `warehouse_security.require_person_supervisor`.
- **`get_or_create_cart` and a switched-off business (superseded by migration 82: only a deleted business is refused).** For a business with `active = false` or
  `deleted_at` set it raises `Business is not active` (P0001): no new order for anyone (also no
  DISPATCHED → OPEN reset), and a customer login is refused even for an existing order. Admin,
  supervisor and staff can still open an existing OPEN order to look at it or clear it.
- **`get_my_access_status()`** (new, read-only, SECURITY DEFINER, `search_path` pg_catalog;
  authenticated and service_role only): `'active'`, `'revoked'` (an active profile whose customer
  assignments were all switched off) or `'none'` for the caller. The app shows "Your cold storage
  has removed your businesses" instead of "No business linked"; nobody is signed out.
- **Two totals no screen shows now multiply by the bags.** `get_grn_details` →
  `statistics.total_weight` is weight × bags received; `get_stock_aging_report` →
  `summary.total_weight_kg` and each `by_bucket[*].total_weight` are weight × bags in stock. Field
  names and shapes are unchanged; each line's `weight` stays the weight of one bag.
- **Document PDFs print their date as 13-10-2026** (India's calendar) instead of ISO text, on the
  GRN, dispatch, invoice and stock documents; the JSON `document.date` is unchanged.
- **Print functions** add `"unconfirmed": true` to every "The printer did not confirm the job" 502
  (also when the job could not be logged and `print_job_id` is null), so the app can warn against a
  reprint.
- **Docs:** `docs/OPERATOR_INSTALL.md` "Rerun and upgrade" now includes the functions container
  recreate in the upgrade commands. Earlier entries below that say "the normal upgrade recreates
  the functions container" are wrong on this point: a change under `functions/` needs that command.
- **Tests:** `tests/backlog_80.sql` (each rule above, all roles); `tests/restore.test.mjs` no longer
  fails about 1 run in 128 when the random verification container name ends in `db`.

## Unreleased — supabase/postgres 15.8.1.135 (2026-10-14)

No migration. `docker/postgres/Dockerfile`: the setup rerun rebuilds the database image; the database container is recreated on the next start.

- **supabase/postgres 15.8.1.135** (was 15.8.1.060), same PostgreSQL 15.8 line and Ubuntu base.
  The backup script, the restore check (`scripts/verify-restore.sh`) and the migration test
  (`tests/migrations.sh`) use the same image digest, so a backup is checked against the
  image it came from. `docs/CONTAINER_SECURITY.md` names the new tag.

## Unreleased — Sensor bridge on Python 3.14 (2026-10-14)

No migration. `docker/sensor-bridge/Dockerfile`: the setup rerun rebuilds the sensor bridge image.

- **Python 3.14-slim-bookworm** (was 3.12-slim-bookworm), by digest. The CI `bridge` job and the
  notices, attribution review, container security note and developer handoff name 3.14.
- Tested against the built image: 82 unit tests pass on Python 3.14.8 with the pinned
  requirements. Not verified: a real Tapo hub.

## Unreleased — python-kasa 0.11.0.1 (sensor bridge) (2026-10-14)

No migration. `docker/sensor-bridge/requirements.txt`: the setup rerun rebuilds the sensor bridge image.

- **python-kasa 0.11.0.1** (was 0.10.2), with its pinned dependencies. The bridge code is unchanged
  (see the test line below). `THIRD_PARTY_NOTICES.md`, `docs/ATTRIBUTION_REVIEW.md` and the bridge
  README name the new version.
- Tested against the built image: 82 unit tests pass on Python 3.12.15 with python-kasa 0.11.0.1; the `kasa` names the bridge imports and the hub connection settings still exist. Not verified: a real Tapo hub.

## Unreleased — Realtime v2.143.3 (2026-10-14)

No migration. `docker/realtime/Dockerfile`: the setup rerun rebuilds the Realtime image.

- **Realtime v2.143.3** (was v2.143.1), a patch release. `THIRD_PARTY_NOTICES.md` and
  `docs/ATTRIBUTION_REVIEW.md` name the new version.

## Unreleased — PDFs: one-package weight, no total weights (2026-10-14)

No migration. Recreate the `functions` container (`scripts/compose.sh up -d --force-recreate functions`).
The matching app change is rn-warehouse-template PR #45.

- GRN document PDF (`generate-grn-pdf`): the line table's weight column header is now `Kg each`
  (it is the weight of one package, `goodsreceived_trl.weight`; the values are unchanged).
  A weight of 0 or none prints `—`, like the app (0 means not recorded).
  English only, like the rest of that PDF.
- Report PDFs (`generate-report-pdf`) no longer print weights: the weight column, its total and
  the weight summary figure are gone from GRN activity (one customer and all customers) and Stock
  summary (both levels), and the weight figure from the Dispatch activity summary of one customer.
  The Weight and kg labels are removed from `report-labels.ts`. A request that sorts by `weight`
  gets the report's default order, like any unknown sort field; this replaces the `weight` sort fields
  listed in the migration 53 entry. The RPCs still return their weights.
- The pre-printed slips (`print-grn-preprinted`, `print-invoice-preprinted`) are unchanged.

## Unreleased — Settings UX batch: item rate changes, approving staff, service accounts (2026-10-14)

Migrations 76, 77 and 78; apply with the normal setup rerun, then update the app.

- Migration 76: `replace_item_rates` (change an item's default or customer rate from a date in
  one step) and `undo_rate_change` (undo the change that starts on a day: its rows go and the rows it
  ended are opened again); a one-day rate is valid; creating or editing a rate refuses overlapping rows
  (`BANDS_OVERLAP`); one-time rates store labour 0; staff can no longer change, delete or
  back-date a rate that is already in force (`RATE_IN_FORCE_MANAGER_ONLY`); `search_customers`
  matches words anywhere in the name; the price list pages stably. Dates use the India day.
  Code-review fixes: `replace_item_rates` has `p_mode` ('change' keeps a scheduled stop; 'correct'
  replaces only the rows starting that day and never touches later rates) and `p_move_from` (move a
  planned rate in one step); new `error_code`s `INVALID_MODE`, `NOT_A_RATE_START`, `NOTHING_TO_MOVE`;
  staff get `RATE_IN_FORCE_MANAGER_ONLY` for a rate that began today; `find_or_create_item_storage_price`
  is administrators and supervisors only and checks overlap, one-time labour and the India day;
  `get_item_storage_prices` hides expired rows by the India day.
- Migration 77: `operator_review_enrollment` takes `p_role` (customer, staff, supervisor); the
  three-argument call still works. `scripts/backup-integrity.sql` now checks it by name.
- Migration 78: `user_profiles.is_service_account`, `set_service_account`; such a profile cannot be
  given another role, deactivated or deleted and does not count as an administrator. Nothing is
  marked by the migration: mark the FAS sync profile with `set_service_account`. Customer
  assignment, its removal, clearing the central link and the access-request review refuse such a
  profile too (`SERVICE_ACCOUNT_READ_ONLY`).

## Unreleased — sensors sampled every 5 minutes, kept 90 days (2026-10-13)

The owner wants a sample every 5 minutes and three months of history.

**Operator action** (only where sensors are used): apply migration 75 (the
normal setup rerun does). Then either accept the new bridge defaults (leave
`SENSOR_BRIDGE_POLL_SECONDS` and `SENSOR_BRIDGE_HEARTBEAT_SECONDS` empty in
`config/compose.env`, or the standalone `sensor-bridge.env`) or set them there,
and recreate the bridge (`bash scripts/compose.sh --profile sensors up -d
--force-recreate sensor-bridge`). At its next `retention:apply` the retention
job deletes every reading older than 90 days, legacy history included; check
the count with `npm run retention:preview` first, and take a backup or export
before that run if older readings are still wanted.

- Bridge defaults: `SENSOR_BRIDGE_POLL_SECONDS` 30 -> 300 and
  `SENSOR_BRIDGE_HEARTBEAT_SECONDS` 900 -> 300 (`config.py`, the Compose
  service, both env examples). With both at 300 every poll queues one reading
  per sensor, a change or a heartbeat, so each sensor is sampled every 5
  minutes: one row per 5 minutes, about 288 a day. The allowed ranges are
  unchanged (poll 5 to 3600, heartbeat 60 to 86400). A shorter poll with the
  heartbeat at 300 still catches changes sooner. Consequences of the longer
  poll: a value change reaches the backend up to about 5 minutes later than
  before, and a hub is reported offline after three failed polls, about 10
  minutes after the first one instead of about a minute. The hub status is
  re-sent every 5 minutes instead of every 15. The container healthcheck is
  unaffected: the health file is rewritten on every pass of the 1-second loop,
  not per poll, so `SENSOR_BRIDGE_HEALTH_MAX_AGE` (120 s) still holds.
- Migration 75 `sensor_retention_90_days`: retention key `sensor_readings` is
  90 days instead of 400 (it stops with an error unless exactly one policy row
  is updated). Nothing is deleted by the migration itself.
- Staleness is unchanged: `staleness_threshold_minutes` stays 30 by default.
  With 5-minute samples that is about six missed samples; two missed samples
  (10 minutes, for example a bridge restart or a failed poll or two) do not
  mark a sensor stale, so 30 stays a safe default.
- Tests: the bridge unit tests pin the new defaults and check that the default
  settings give one reading per sensor per 5 minutes (the state-machine tests
  keep a 30 s poll and a 15-minute heartbeat); `tests/sensor_ingest.sql`
  checks 90 days and that retention deletes a reading of 91 days and keeps one
  of 89 days.

## Unreleased — Tapo sensors through the template (2026-10-13)

Tapo T310 temperature and humidity sensors on H200 hubs now reach this backend
through the template itself, replacing the Home Assistant stack that posted to
the legacy server. Guide: [docs/SENSORS.md](docs/SENSORS.md).

**Operator action** (only where sensors are used; nothing changes elsewhere):
apply migration 74 (the normal setup rerun does; it clears the legacy zero
placeholders and prints NOTICE counts of what it cleared, merged or removed);
mint an ingest key and keep it only in the bridge's private configuration
(`compose.env`, or the standalone `sensor-bridge.env`):
`bash scripts/compose.sh exec -T db psql -X -qAt -v ON_ERROR_STOP=1 -U supabase_admin -d postgres -v label=main-bridge < scripts/sensor-ingest-key.sql`
(prints the key once); set `SENSOR_BRIDGE_HUBS`, `TAPO_USERNAME`,
`TAPO_PASSWORD` and `SENSOR_INGEST_KEY` in `config/compose.env`; start the
bridge with `bash scripts/compose.sh --profile sensors up -d --wait sensor-bridge`
(or run the same image as its own Compose project); then
`node scripts/set-capability.mjs sensors on`, `bash scripts/compose.sh restart
functions`, and take a new `npm run db:backup` (an older backup can then only be
restored with `db:restore-host`). A key is revoked with
`UPDATE warehouse_security.sensor_ingest_keys SET revoked_at = now() WHERE label = '<label>' AND revoked_at IS NULL`.

- Migration 74 `sensor_ingest` adds sensor ingestion. `sensor_readings` gains
  `measured_at` (when the bridge observed the value; the hub reports no time),
  backfilled from `recorded_at`; temperature and humidity are now nullable (at
  least one, each in range), legacy zero placeholders become NULL, and a
  reading is stored once per sensor and time (`(device_id, measured_at)`
  unique), so a resend is harmless. `sensor_devices` gains the hub child id
  (`external_id`, 40 hex, stored upper case), hub, model, battery, signal,
  report interval and `last_seen_at`. New `sensor_hubs`; new `sensor_latest`
  with the newest value of each kind per sensor (RLS for administrator,
  supervisor and staff, published over Realtime to them); and the view
  `sensor_status`, which derives stale (nothing seen within the device's
  threshold, 30 minutes) and offline (hub reported offline) when read.
- Migration 74: `record_sensor_batch(p_key, p_hub, p_readings)`, service key
  only and called by the edge function, checks a per-bridge ingest key
  (SHA-256 in `warehouse_security.sensor_ingest_keys`, readable by no API
  role), validates every reading and counts rejections by reason, accepts a
  child id in either case, creates devices on first sight (names set once, so
  renames survive), stores a heartbeat that carries values as a reading and
  counts heartbeats by their `kind`, and moves `sensor_latest` only forward in
  time. The two readers `get_sensor_polling_data` and `get_sensor_history` keep
  their signatures and answers, now computed (status OFFLINE, STALE, ONLINE;
  battery LOW, OK, UNKNOWN; nulls ignored instead of read as 0; per-bucket
  sample counts); history gains a 1-day period (5-minute buckets). Their
  `EXCEPTION WHEN OTHERS` handler is gone, so a refused caller now gets a
  PostgREST `42501` error instead of `{success:false}` (the app's
  `useReportQuery` treats it as a refusal). New `get_sensor_device` (staff and
  above) and `update_sensor_device` (administrator). `record_sensor_reading` and
  `update_sensor` are removed (service role only, never called). Readings are
  kept 400 days (retention key `sensor_readings`).
- Edge function `ingest-sensor-readings`: `POST` with the ingest key as bearer
  (no user session), at most 256 KiB and 500 readings; 200 with accepted,
  duplicate and rejected counts, 401 for a missing, malformed, wrong or revoked
  key (a malformed one never reaches the database), 400 for a bad body shape
  or a hub or readings refused by `record_sensor_batch`, 405, and 503 when the
  database is not configured, errors or times out after 15 s (the bridge
  retries). It is in the router's public set; its worker gets only
  `SUPABASE_URL` and `SUPABASE_SERVICE_ROLE_KEY`; every answer has
  `Cache-Control: no-store`, and its log lines carry a reason code only, never
  the key or the body.
- The bridge, `docker/sensor-bridge/` (Python 3.12, python-kasa 0.10.2): polls
  each hub every 30 seconds, queues a reading on a change or every 15 minutes
  as a heartbeat, keeps the queue and its change detector in SQLite in the
  `sensor-bridge-data` volume, posts every 60 seconds with backoff, marks a hub
  offline after three failed polls, and offers `--check-config`, `--once` and
  `--dump`. Because the change detector persists, a second `--once` straight
  after the first posts nothing (`posts=0`); the backend reports duplicates
  only when the bridge re-sends a batch whose answer it did not get. It runs as the optional Compose service `sensor-bridge` (profile
  `sensors`, `default` network only, fixed URL `http://kong:8000/functions/v1/ingest-sensor-readings`,
  every variable optional so `compose config` is unchanged for installations
  without it, non-root, all capabilities dropped, read-only root filesystem,
  0.25 CPU / 128 MB), or as its
  own Compose project (`docker-compose.standalone.yml`). `.env.example` has an
  empty SENSORS block.
- `scripts/set-capability.mjs <sensors|printing> <on|off>` changes one flag of
  `public/instance.json` in place (staging file and rename, mode kept, every
  other byte unchanged) and prints the restart and backup steps.
- Checks: `npm run test:sensors` (`scripts/sensor-bridge-check.sh`, under the
  operator lock: builds the image; `--check-config` exits 0 with fictional
  values without printing them and 78 without any; the unit tests run inside
  the image), also a step of CI `operator-install`; a new CI job `bridge`
  (`compileall` and the unit tests on Python 3.12); `tests/sensor_ingest.sql`;
  the function's handler tests; the network table and notice-version tests
  cover the new service.
- Licence: the bridge's code is **GPL-3.0-or-later** (`docker/sensor-bridge/LICENSE`)
  because python-kasa is GPL-3.0; it is a separate program that talks to the
  backend over HTTP, and the rest of the repository stays MIT.
  `THIRD_PARTY_NOTICES.md` and `docs/ATTRIBUTION_REVIEW.md` list python-kasa
  0.10.2 and the Python 3.12-slim-bookworm base image. Distributing a built
  bridge image carries the GPL source offer.
- Not yet verified: the hub protocol on the facility's real H200 hubs, the
  heartbeat against real T310 reporting, Realtime delivery to a staff phone,
  and the profile started under Compose on an installation.

## Unreleased — report PDFs keep the screen's choices (2026-10-13)

- `generate-report-pdf` takes three optional request fields (no migration): `invoicing` ('invoiced' | 'not_invoiced', GRN activity of one customer), `bucket` ('0-120' | '121-240' | '241-364' | 'over-364', stock aging of one customer) and `search` (trimmed text of at most 80 characters, no control characters; item stock summary). The first two drop the other rows after the RPC answered and work the summary out from the rows listed, as `status` does; the search goes to `get_item_wise_stock_list` as `p_search_query`. Each prints a line under the title ("Invoicing: Not invoiced", "Stock age: Over 364 days", "Search: “cumin”"); `invoicing` and `bucket` are echoed in the answer's `document`, the search never is. A field on another report, without the customer, or with another value is refused with 400 and a fixed message. Both stock aging PDFs now label their oldest-stock figure "Lots over 364 days" (it is a count of stock lines; it said "Items over 364 days"). The matching app change ships separately; against a server without this change the app asks before sharing the report without the choice (the old server answers "Unknown field in report request").

## Unreleased — invoice numbers run from 1 to 99999999 (2026-10-13)

- Migration 73 `invoice_number_ceiling`: `save_invoice` (both signatures) and `update_invoice` refuse an invoice number outside 1..99999999 (eight digits, so year-prefixed numbers such as 20260929 stay valid) with "Invoice number must be between 1 and 99999999" (WH422), an edit keeping the invoice's own stored number excepted, and `get_next_invoice_number` ignores numbers above 99999999, so one typed 2147483647 no longer blocks its financial year (WH409 now comes at 99999999); no operator action. The app's cap on the number field is a separate app pull request; this backend change merges first. Rules: [docs/INVOICE_RULES.md](docs/INVOICE_RULES.md), "Invoice numbers"; test `tests/invoice_number_ceiling.sql`.

## Unreleased — Backend review fixes 2026-10-13

### Migrations 65-67

**Operator action:** none beyond applying the migrations (the normal upgrade
does). Migration 65 reports (a WARNING when there are any) saved invoices whose
stored total differs from a recomputation of their lines under the receipt's
current pricing mode (whatever the cause); it changes none. Migration 67 prints a NOTICE with the number of old stock
movements whose sign or type it corrected, and a WARNING with the probable
duplicates it kept (not deleted) when there are any.

- Migration 65 `grn_edit_integrity`, `update_grn` (review I1, P1): an edit
  of receipt B that sent a line id of receipt A changed A's line (to "Foreign
  Mutation", weight 99 in the review) and deleted B's own line; a line id sent
  twice was applied twice; an unknown id deleted the real line. Now refused
  before anything is written: "A GRN line is sent more than once in this
  edit; reload the GRN and edit again" and "GRN line <id> is not a line of
  this GRN; reload the GRN and edit again". The line SELECT is bound to the
  receipt and row-locked, and both line UPDATEs are bound to the receipt and
  must change exactly one row. The image "keep" UPDATE is bound to the
  receipt too (its id lookup already was).
- Migration 65, `update_grn` (review I3): changing the pricing mode of a
  receipt that has an invoice (of the receipt, or a line of one of its lots)
  is refused: "Cannot change the pricing mode of a GRN that has invoices:
  delete invoices first, then change the pricing mode and invoice again".
  Before, a MONTHLY invoice of 108.00 read 40.00 in
  `get_invoice_items_detailed` after its receipt became ONE_TIME, while its
  stored total stayed 108.00. Sending the mode the receipt already has (the
  app always does) or none is an ordinary edit; a receipt without invoices
  changes freely.
- Migration 66 `stock_history_cutoff`, `get_customer_stock_analysis_v2`
  (review I2): with a date, each lot's balance is now its received quantity
  less what was dispatched from it up to that date, and the in-stock filter is
  applied after that. Before, 10 received on 1 April with 4 dispatched on
  1 June read 10 / 0 / 6 on 15 April (now 10 / 0 / 10), and a lot emptied
  after the date was left out. Without a date the answer is unchanged.
- Migration 67 `dispatch_cart_and_movements` (review I4): a dispatch now
  records on each line the cart line it lowered and by how much
  (`source_order_item_id`, `cart_quantity_consumed`; `source_type` 'cart' for
  a dispatch from the cart), and `delete_dispatch_with_order_cleanup` gives
  that quantity back: a cart of 10 that a dispatch of 4 lowered to 6 is 10
  again (before: 6), a used-up line comes back pending with the quantity it
  had (before: recreated as fulfilled with the dispatched quantity), and a
  direct dispatch that lowered the cart gives back too. Lines of a dispatch
  from the cart saved before migration 67 carry no record: nothing is given
  back for them, the answer counts them in the new `cart_lines_not_restored`
  and `cart_restoration.lines_not_restored`, and its message says so.
  A direct dispatch lowers, and its deletion gives back to, only the
  customer's OPEN cart (oldest first, then lowest id). When the dispatch used
  the line up and the customer has no OPEN cart, a cart is made as
  `get_or_create_cart` makes it; the unique index `one_cart_per_customer`
  allows one order per customer, so when that order exists but is not OPEN
  (or is deleted) it is left untouched, nothing is given back for the line,
  and the answer counts it in the new `cart_lines_without_open_cart` and
  `cart_restoration.lines_without_open_cart` with a message (before: the
  pending line went into the closed order, or, with no order, nothing was
  given back).
- Migration 67 (review I5): `update_dispatch_smart` logs a movement only for
  lines it actually adds (before, every line sent, so an unchanged resave
  logged a dispatch that never happened and made an old empty lot look
  emptied today in the stock summary). One sign rule: `dispatch` negative,
  `return` positive, quantity = balance after - balance before (creation was
  positive; a lowered quantity was a `dispatch` of +q). Deleting a dispatch
  now logs the stock it restores. The trigger
  `restore_stock_on_dispatch_delete` wrote a movement type the table refuses,
  so a database owner's `DELETE FROM dispatch` with lines failed; it now
  writes a `return` of what the lot really got back: when the restore is
  capped at the received quantity (stock 7 of 10, a dispatch of 6 deleted)
  it logs `return 3 7>10`, not `return 6 4>10`. Old movements are corrected where their balances show
  the meaning; probable duplicates are counted, not deleted (the count also
  includes a line legitimately removed and added again).
- Tests: `tests/grn_edit_integrity.sql`, `tests/stock_history_cutoff.sql`,
  `tests/dispatch_cart_and_movements.sql` (each failed before its migration).
- What the app sees: two new `update_grn` refusal texts (shown in English;
  the Gujarati fallback is the generic save error) and four added keys in the
  dispatch deletion answer (lines not given back, by reason). No shape the app
  reads changes.
### Operations, documents and dependencies

**Operator action:** run the normal upgrade (`npm run db:backup`,
`db:verify-restore`, `git pull`, `setup.sh --operator ...` with the same
inputs). Setup rebuilds the Storage image (new lock) and, where monitoring
runs, builds Grafana under its new tag `<project>-grafana` and replaces the
Grafana container; its data volume is kept. After **every** installation on
the host has been upgraded, remove the old shared tag once with
`docker image rm warehouse-grafana:local` (Docker refuses while a container
still uses it). Nothing removes it automatically.

- OPS-1, `docker/alert-rules.yml`: `DatabaseConnectionsHigh` compared each
  `pg_stat_activity_count` series with 80, but postgres-exporter splits the
  count by database, state, user, application, backend type and wait event,
  so 90 connections spread as 45 active and 45 idle never fired it. The rule
  is now `sum by (instance, job) (pg_stat_activity_count{backend_type="client
  backend"}) > 80` (background workers left out). New
  `docker/alert-rules.test.yml` (`promtool test rules`: the split fires at
  5 minutes with its labels and annotations, not at 1; 80 clients plus 10
  autovacuum workers do not fire); `scripts/monitoring-check.sh` runs it after
  `promtool check config` and requires live client-backend series;
  `tests/gateway-config.test.mjs` pins the expression; `docs/MONITORING.md`.
- OPS-2, Grafana image tag: Grafana was the only built service with a fixed
  image name (`warehouse-grafana:local`), shared by every installation on a
  host, and `build-images.sh --replace-optional` (run by `start.sh` and
  `setup.sh`) recreated running optional services without checking the image,
  so another checkout's Grafana build replaced this installation's Grafana at
  its next start. The `image:` line is gone (Compose tags `<project>-grafana`),
  and `--replace-optional` now runs the build step's image check: a running
  optional service whose image is missing, whose recipe changed or whose tag
  names an image this checkout did not build is left running with "the
  <service> image does not match this checkout (...)", the others are
  replaced, and `start.sh` prints the warning (start still never builds).
  Tests in `tests/build-images.test.mjs` ("image missing", "image was
  replaced", no built service with `image:`); `THIRD_PARTY_NOTICES.md`,
  `docs/OPERATOR_INSTALL.md`.
- OPS-3, `docs/TROUBLESHOOTING.md`: the guide ran `docker logs/exec/restart`
  on fixed `supabase-*` container names, which on a shared host belong to
  another Compose project, and ended with a reset (`down -v`, a stale data
  path). Every command now goes through `WAREHOUSE_STATE_DIR` and
  `bash scripts/compose.sh`; "Reset Everything" is replaced by "Restore or
  recover (there is no reset)" pointing at the documented restore, USB
  recovery, rerun and setup paths. `tests/operator-docs.test.mjs`.
- DOC-1, `docs/API_CONTRACT.md`: it named the removed `npm run test:api` and
  said the checker exits nonzero by design. It now gives
  `npm run check:contract -- ../rn-warehouse-template` and CI's pinned pair,
  the counts at backend `3c32394` and app `d8af378` (94 RPC names, 0 missing;
  133 typed calls, 0 mismatches; 2 dynamic calls; 6 tables; 8 literal Edge
  names), when the checker fails, and the operator fixture drivers plus
  `npm run test:migrations`. `tests/operator-docs.test.mjs`.
- Storage dependencies: `@fastify/busboy` 3.2.1 → 3.2.3
  ([GHSA-gxm5-99cw-xjw9](https://github.com/advisories/GHSA-gxm5-99cw-xjw9))
  and a new `fast-copy@^4` override to 4.1.2
  ([GHSA-jggr-w7fw-pc2j](https://github.com/advisories/GHSA-jggr-w7fw-pc2j)),
  both moderate: parser and logging leaf fixes; not exploitable as shown in
  this warehouse. Lock regenerated with npm 11.12.1, only those two packages
  changed; `npm audit --omit=dev` 0 (was 2 moderate).
  `docs/CONTAINER_SECURITY.md`, `docker/storage/README.md`. **Operator
  action:** `setup.sh` rebuilds Storage.
### Migrations 71-72 and printing

Migrations 71 and 72 and changes to the dormant printing functions (the five
printing routes still answer 503). **Operator action:** take and verify a
backup before upgrading (`npm run db:backup`, then `npm run db:verify-restore --
<backup directory>`); `setup.sh` does not take one. Migration 71 discards the
never-sent Tally invoice sync queue, the sync logs and the voucher counters
(a NOTICE gives the row counts) and STOPS, naming the table, if any Tally
voucher, receipt or contra voucher, bank statement or line, ledger map or
company configuration row exists. The edge changes are in the printing
functions only, which still answer 503.

- Migration 71, `retire_tally_and_dead_functions`, retires the Tally accounting
  integration and dead legacy functions (review 2026-10-13, L1-L10): the invoice
  sync trigger and its queue are removed (the trigger on `invoice` and the
  ledger-map trigger on `customers` with four more on Tally tables); 46
  Tally/receipt/contra functions and 14 tables are dropped; 24 dead functions
  (L1, L2, L7's 17, L8, L9, L10 and `generate_order_number`) are dropped. All
  70 were service-role only and uncalled. Before the first drop it refuses if
  one is granted to an app role, called by another trigger, depended on, or
  named by a kept function, or a retired table is named by a kept function or a
  policy. `payments`, its policies and the Paid/Pending reports are unchanged;
  nothing in the product writes `payments` now (the Tally functions were the
  only writers; the app never did). Test: `tests/legacy_functions.sql`.
- Migration 72, `print_invoice_line_amounts` (PRINT2, PRINT3):
  `get_invoice_range_for_print` gives each line `pricing_mode`,
  `storage_amount` and `labour_amount` by the invoice rule (ONE_TIME storage
  charged once, no labour), patched at one counted marker;
  `print_jobs_status_check` accepts `unknown`. Test:
  `tests/print_invoice_range.sql`.
- Printing (PRINT1-5), new modules under `functions/_shared/` with node tests:
  invoice pages built from printed rows with `contd.` group headers
  (`invoice-print-layout.ts`); line and page amounts from the server, a missing
  one stops the print, and the default financial year is India's
  (`invoice-print-amounts.ts`); IPP replies validated before success is reported,
  an unconfirmed job recorded as `unknown` with 502, only an idle printer online
  (`ipp-validate.ts`; `ipp-types.ts` re-exports its constants); the status
  monitor finishes a job only on a final CUPS state and otherwise records
  `unknown` within 44 s, and the Print-Job submission of the three preprinted
  routes is given up after 8 s (no answer: `unknown`), so the submission and
  the monitor take at most 52 s of the 60 s worker (`print-monitor-rule.ts`).
  Tests:
  `tests/print-paginator.test.mjs`, `print-amounts.test.mjs`,
  `ipp-validation.test.mjs`, `print-monitor.test.mjs`.
- Documents: `docs/PRINTING.md` ("Activation acceptance"), README ("Features
  and limits") and `docs/API_CONTRACT.md` ("Legacy and dormant functions").
### Migrations 68-70

Migrations 68, 69 and 70. **Operator action:** none beyond applying the
migrations (the normal upgrade does). Migration 68 drops and recreates the
materialized view `mv_invoice_list` (same columns, indexes, owner and grants;
filled again in the migration). No setting, service or container changes;
no function signature changes.

- Migration 68 (I6), `get_dispatch_details`: `invoices_summary.total_amount`
  summed an invoice once per dispatch line on it (two lines on invoice 90101
  of 357: 714); it now sums each invoice once (357; two invoices of 357 each
  still give 714). `statistics.total_invoice_amount` was SUM(charge x
  duration) (30); it is now the invoiced amount of the dispatch's own lines,
  each as `get_invoice_items_detailed` computes it (357), without the
  header's whole-rupee rounding or the discount.
- Migration 68 (I7), `get_all_dispatch_items`: LIMIT/OFFSET applied to the
  one aggregated row (limit 1 gave 2 rows, offset 1 gave none); rows are now
  numbered in the requested order (ties by line id), paged, then aggregated:
  1 row, then the other.
- Migration 68 (I8), `get_all_dispatch_items`: staff got `items: []` with
  `total` 2; the rows now admit staff as the count and sums do (2 rows).
- Migration 68 (I9), `mv_invoice_list.total_qty` (`get_invoices_list`): was
  sum(DISTINCT lot quantity), 10 for two lots of 10 bags; now the bags
  billed, sum(disp_qty) = 20.
- Migration 68 (I10), `get_customer_invoice_summary` line items: quantity
  1.5 -> 10 (bags), rate 6.67 -> 10 (charge), labour_amount 3 -> 20,
  tax_percent 50 -> 5, tax_amount 5 -> 8.50, line_total 18 -> 178.50 (ONE_TIME:
  no labour, 42 = the header); `total_quantity` 3.0 -> 20. The lines now add
  up to the invoice total. Keys, types and rows unchanged.
- Migration 68 (I11): invoice numbers longer than four digits were cut
  (`2026-9010` for 90101); now `2026-90101` in `get_customer_invoice_summary`
  and `get_customer_activity_detail` (104 stays `2026-0104`), and the same
  expression in `get_grn_invoices` (dormant) and the `get_invoices_list`
  search.
- Migration 69 (SEC-1, SEC-2): new helper
  `warehouse_security.grn_image_visible(status, uploaded_by)` (not granted to
  app roles) holds the `grn_images` read rule. `get_grn_details` lists only
  the photo rows the caller may read (a customer or other staff no longer get
  a pending upload's path, name and uploader). `update_grn` with a non-empty
  `p_images` removes only omitted rows the caller may read, so a staff edit
  no longer deletes another person's pending upload (which could then not be
  confirmed); such a row named in the list is kept as it is; `grn.images`
  lists what the caller may read. The same filter is applied to the image
  subqueries of `get_customer_items_for_order_selection` (a customer got a
  pending upload's path as `image_url`), `get_invoiceable_grns`
  (`gr_image_url`) and `get_customer_grn_activity` (`image_count`,
  `total_images`); keys and rows unchanged. `docs/STAFF_GRN_POLICY.md`.
- Migration 70 (EDGE-RENDER-1), `get_customer_stock_summary`: after an item
  rename, `items` and `out_of_stock_items` had one row per received name,
  each listing every lot (three names, 35 bags: 105 bags in the rows); now
  one row per item, named as its latest receipt, with its lots (35).
- Tests: `tests/dispatch_invoice_read_figures.sql`,
  `tests/grn_image_visibility.sql`, `tests/stock_summary_item_identity.sql`
  (each fails before its migration).

## Unreleased — central login: the link answer names the link (2026-10-12)

Migration 64. **Operator action:** none beyond applying the migration (the
normal upgrade does). No setting, service or container changes.

- Migration 64, `operator_central_exchange`: when a token and a correct SMS
  code of this facility link an existing profile, the answer now carries the
  link. Before, the function wrote `central_issuer` and `central_subject` to
  the profile and then returned `operator_verify_otp`'s answer as it was built
  before the link, so `data.user.central_subject` was null in a `login` answer
  and missing in a `pending` one, while the stored profile was already linked
  (external review 2026-10-12, R8). Now, after the link is written, the two
  fields are set in `data.user`: the `login` answer's `data.user` equals the
  stored profile, and the `pending` answer's short `data.user` gains the two
  fields and nothing else. Success, action, session and enrollment token are
  unchanged, and a refusal is still returned before anything is linked. The
  function is patched in place (marker count checked), and the migration
  checks that SECURITY DEFINER, its grants and its `search_path` are
  unchanged. Migration 49 is not edited.
- What an app sees: the reply of a correct-code link names the central
  account it linked. The mobile app reads none of the `central_*` fields, so
  it needs no change.
- Tests: `tests/central_login.sql` checks both answer shapes (the two fields,
  `data.user` equal to the stored profile for `login`, and the exact key set
  for `pending`).
- Documents: `docs/CENTRAL_LOGIN.md` (the link answer; "Built" and "Tested,
  and not tested" replace "Not built yet" and "Not tested") and `CLAUDE.md`.

## Unreleased — review fixes in the reports (2026-10-12)

Migration 63 and four changes to the report PDFs (`generate-report-pdf`).
**Operator action:** none beyond applying the migration (the normal upgrade
does). No setting, service or container changes.

- Migration 63, `get_customer_grn_activity` (one customer): a goods receipt is
  listed once, whatever its number of invoices. The CTE `invoice_status` held
  one row per non-deleted invoice and was joined straight to the receipts, so
  a receipt with two invoices (old data: before migration 41 a second save for
  a receipt succeeded, and migration 41 changes no earlier row) came out twice
  and inflated `summary.total_grns`, `total_items`, `total_quantity`,
  `total_weight_kg`, `total_invoiced_grns` and `total_images`. Example: a
  customer with three receipts, 7 bags, 70 kg, one receipt (1 bag, 10 kg) with
  a second invoice, was answered as 4 receipts, 8 bags, 80 kg, 3 invoiced, the
  receipt twice; it is now 3, 7, 70, 2 invoiced, each receipt once.
  `invoice_status` is now one row per receipt: the latest non-deleted invoice
  (by invoice date, then financial year, then number, then id) gives
  `invoice_id` and `invoice_number`, and the new key `invoice_count` is the
  number of non-deleted invoices (`0` for a receipt without one, `1` for an
  ordinary one, `2` or more for doubled old data). Names and JSON types of
  every existing key are unchanged; the guard (not redefined), SECURITY
  DEFINER, search_path, grants, India day cuts, weight expressions of migration
  59, key order and row order are unchanged, and the all-customers branch and
  `get_all_grn_activity` (no invoice join) are not touched. Compared with
  `pg_get_functiondef` before and after in a throwaway database, only the CTE
  (`SELECT DISTINCT ON (i.gr_id)`, the `ORDER BY`, the new key) and the default
  object of a receipt without an invoice differ.
- What an app sees: `invoice_status.invoice_count` is new and is ignored by an
  app that does not know it (the mobile app reads `invoice_number` only; the
  GRN activity PDF too). A receipt with several invoices shows once, with its
  latest invoice. The figures of the summary count each receipt once.
- Report PDFs, item stock summary: `packaging` is no longer accepted as a sort
  (the database function sorts by `item`, `stock`, `received` and `grns` only).
  It used to sort the first 2,001 rows of the item-name order and print
  "Packaging (ascending)", so a list of more than 2,001 items lost the item that
  comes first by packaging. A packaging request now gives the default sort, like
  any unknown field: "Item (ascending)". Other reports' sorts are unchanged.
- Report PDFs, invoice history of one customer: an invoice whose status word is
  neither `paid` nor `pending` is worked out by the app's rule instead of
  being left out of Paid and Pending (and out of both choices): the payment
  amount, when it can be read, is the money received; otherwise a `paid` word
  means the whole total and anything else nothing. An unknown word with no
  payment is Pending for its whole total, and Paid + Pending = Amount for
  every invoice. Invoices of 0 or more with a `paid` or `pending` word print as
  before.
- Report PDFs, invoice history of one customer: a database without migration 61
  answers an invoice once per payment row. The rows of one `invoice_id` are now
  merged before the table is built (first row's fields and position, the
  payments added up in whole paise, `paid` if any row says paid, the date and
  reference of the latest payment), so an invoice of 14.00 with payments of
  4.00 and 10.00 prints once: Amount 14.00, Paid 14.00, Pending 0.00, Paid.
  The summary counts the invoices listed. Rows with no `invoice_id` are not
  merged; an answer without duplicates prints exactly as before.
- Report PDFs, a table cut at the 2,000-row limit: its totals row adds up the
  rows printed while the summary above covers the whole report, so the row is
  labelled "Total of rows shown" (Gujarati: "દેખાતી લાઇનનો કુલ", put together
  from the app's words for the owner's check) instead of "Total". A table that
  was not cut keeps "Total".
- Developer handoff: migration files are run only through the ledger; run
  directly a second time, migrations 57 and 58 add their fragment again, so a
  new marker-patch migration must have no before-text inside its after-text
  (migration 63 is checked by running it twice in a throwaway database).
- Tests: `tests/report_grn_invoices.sql` (registered last in
  `tests/migrations.sh`) and new cases in `tests/report-pdf.test.mjs`.

## Unreleased — Paid and Pending follow the money in the invoice reports (2026-10-12)

Migration 62. **Operator action:** none beyond applying the migration (the
normal upgrade does). No setting, service or container changes.

- The rule (the owner's choice): "Paid is the money received and Pending is what
  is still owed. An invoice counts as Paid only when nothing is owed; a
  part-paid invoice stays Pending with the balance." Per invoice, **received** is
  the sum of its `payments.amount`, never below 0 and never above the invoice
  `total`; **balance** is `total` minus received; the status is `paid` when the
  balance is 0.50 or less (the tolerance `get_open_invoices_for_customer`
  already uses: an invoice is open when more than 0.50 is owed), otherwise
  `pending`. An invoice of 0 owes nothing and is paid. Until now an invoice was
  paid as soon as any payment row named it, and its whole `total` counted as
  paid. Example: an invoice of 14.00 with 4.00 received was `paid` and counted 14
  as paid; it is now `pending`, received 4.00, balance 10.00. With 108.50
  received of 109.00 (0.50 owed) it is paid; with 65.49 of 66.00 (0.51 owed) it
  is pending; with 120.00 received of 108.00 only 108.00 counts as received.
  Two rows of 60.00 and 51.00 against 111.00 are paid. Paid + Pending = the
  total, for an invoice and for any set of invoices; the up to 0.50 still owed
  on an invoice that is listed as paid is in Pending (an invoice of 20.00 with
  19.50 received is `paid`, Paid 19.50, Pending 0.50).
- Keys whose values change (names and JSON types unchanged), with the numbers
  they hold now:
  - `get_customer_invoice_summary`, one customer: `invoices[].payment_status.status`
    (by the rule; the other keys of `payment_status` keep their meaning:
    `amount` is the sum of the payment rows, `paid_date`, `payment_ref` and
    `payment_mode` those of the latest row, so a part-paid invoice is `pending`
    and still carries them), `summary.paid_amount` (the sum of received),
    `summary.pending_amount` (the sum of balances), `summary.paid_count` and
    `summary.pending_count` (the invoices that are paid / pending by the rule),
    and `by_month[].paid_amount` and `by_month[].pending_amount` (received and
    balances of the month).
  - `get_customer_activity_detail`: `recent_invoices[].status` (by the rule) and
    `summary.total_pending_amount` (the sum of the balances of the period's
    invoices; it was invoiced minus paid, which went negative for an
    over-payment).
- Two new keys on each invoice of `get_customer_invoice_summary`'s `invoices[]`
  (one customer): `paid_amount` (received) and `balance_amount` (balance), both
  numbers.
- Not changed: `summary.total_paid_amount` of the activity detail (the sum of
  the period's payments, an over-payment included, so with an over-payment it
  and `total_pending_amount` add up to more than `total_invoice_amount`; the
  invoice history has the capped figures), every other key, the all-customers
  branch of `get_customer_invoice_summary` and
  `get_all_customer_activity_summary` (neither returns a paid or pending
  figure), the `authorize_rpc` guard (not redefined), SECURITY DEFINER, the
  search_path and jit setting, the grants, the India day cuts, the order of the
  rows. Compared with `pg_get_functiondef` before and after in a throwaway
  database, the only differences in the two definitions are these expressions:
  the payment status set (one added column), two lateral values and the status
  expression of the invoice list, the month and summary sums, the two new keys,
  and in the activity detail the pending sum and the status of the recent
  invoices.
- What an app shows, before and after. Before, an invoice with any payment row
  was `paid`: a part-paid invoice of 14.00 with 4.00 received was Paid in full
  (14.00) in its status, the counts, the months and the summary. After, it is
  `pending`, with `paid_amount` 4.00 and `balance_amount` 10.00 on the invoice,
  and the summary and the months hold the money received (4.00) and the balance
  (10.00). An app that works the same rule out itself from `total` and the
  payment amount (`payment_status.amount`, the sum of the payment rows since
  migration 61) shows the same numbers as these keys, and may read the two new
  keys instead. The mobile app does exactly that in its invoice history from
  its change "Paid and Pending follow the money in invoice history"
  (rn-warehouse-template CHANGELOG, 2026-10-12), so its screen is the same with
  or without this migration. An app before that change (commit e79515d and
  older) takes each invoice's `payment_status.status` and its whole `total`:
  with this migration it shows a part-paid invoice under Pending for its whole
  `total`. The customer activity screen's recent invoices show the new status,
  and its pending amount is never negative.
- Report PDFs (`generate-report-pdf`), the invoice history of one customer: the
  status of each invoice, the Paid / Pending choice (`status`) and the summary
  follow the rule, worked out from each invoice's `total` and
  `payment_status.amount`, so the document is the same on a database with and
  without this migration. A `paid` status with no usable amount is taken as paid
  in full. A part payment shows in the status cell, in the app's words for
  Pending and Paid: `Pending (Paid 4.00)` (`બાકી (ચૂકવેલ 4.00)` in Gujarati). In
  the summary, Paid is the sum of the money received, Pending the sum of the
  balances, and together they are Amount; under the Pending choice a part-paid
  invoice is listed with its full amount, Paid its received part and Pending its
  balance. The all-customers invoice history and the customer activity PDF are
  unchanged and follow the RPC.
- Four Gujarati labels of the report PDFs are reworded, as the wording review
  suggested and the owner chose (`overOneYear` is left as it is):
  `Sort by` was `આ મુજબ સૉર્ટ કરો`, now `સૉર્ટનો ક્રમ` (the app's
  `filters.sheet.sortOrder`; a fact line on paper, not the sort sheet's
  command); `Showing {{shown}} of {{total}}` was `{{total}}માંથી {{shown}} બતાવ્યા છે`,
  now `{{total}}માંથી {{shown}} દેખાય છે` (no gender; the app's screen still says
  `બતાવ્યા છે`); the column `GRN number` was `આવક પાવતી નંબર`, now `આવક નં.`
  (the app's `filters.sort.grnNumberChip`); the column `Stock age` was
  `માલ કેટલા દિવસથી પડ્યો છે`, now `કેટલા દિવસથી` (the app's `reports.sort.age`;
  printed with its unit, `કેટલા દિવસથી (દિવસ)`). The stock aging report's title is
  its own label and keeps `માલ કેટલા દિવસથી પડ્યો છે`. English PDFs are unchanged.
- Checks: `tests/report_invoice_paid.sql` (registered after
  `tests/report_invoice_amounts.sql`) makes nine invoices with `save_invoice` and
  adds payments: none, a part payment, an exact payment, two rows that pay in
  full, 0.50 and 0.51 short, two over-payments and an invoice of 0, and checks
  every key above as staff, an administrator and a customer account, that
  received + balance = total on every invoice, month and summary, that the key
  sets are unchanged apart from the two new keys, and that the functions keep
  their guard, search_path and grants; it fails without the migration and under
  mutants (the old "any row" status, an uncapped received sum, a tolerance of 0,
  0.51 or "less than"). `tests/report_invoice_amounts.sql` keeps its figures
  (its invoices are paid in full or not at all) and its key set of an invoice
  gains the two new keys. `tests/report-pdf.test.mjs` checks the PDF rule, the
  `status` choice, the summary sums, both languages and the same document from the
  answer of a database with and without the migration, and the byte-for-byte
  comparison of the 28 report documents puts the old Gujarati label text back
  where it changed on purpose (all 14 Gujarati documents).

## Unreleased — stock reports cut days on India's calendar (2026-10-12)

Migration 60. **Operator action:** none beyond applying the migration (the
normal upgrade does). No setting, service or container changes.

- The facility's books are kept in India (Asia/Kolkata, UTC+05:30), and
  migrations 41 and 56 already cut the billable day and every period report on
  that calendar. The stock reports did not: every day they took from a receipt,
  a dispatch or a stock movement, and every age in days, was a day in the
  database session's time zone (UTC), so a receipt made at 02:30 India time on
  1 October was reported on 30 September by the stock summary and on 1 October
  by the GRN activity report. They now use India's day, as the period reports.
- Functions and keys that change (names, types and order unchanged: a date
  stays a `YYYY-MM-DD` string, an age stays a whole number):
  - `get_customer_stock_summary`: `summary.oldest_stock_date`,
    `summary.last_grn_date`, `summary.last_dispatch_date`, `date` of every lot
    in `items[].grns[]` and in `out_of_stock_items[].grns[]`, and
    `emptied_date` of the lots in `out_of_stock_items[]`. The list of lots
    emptied "within the last 360 days" also counts those days: a lot emptied on
    India's day 360 days ago or later is listed (it was a rolling 360 x 24
    hours before, so a lot emptied early on that day could drop out for part of
    the day).
  - `get_all_stock_summary`: `summary.oldest_stock_date`,
    `customers[].oldest_date`, `customers[].latest_date`.
  - `get_stock_aging_report` (one customer and all customers): `aging_days` is
    India's today minus India's day of the receipt, and so are the bucket a lot
    falls in (`aging_bucket`, `by_bucket`, `aging_distribution`),
    `oldest_stock_days`, `average_age_days`, `items_over_365_days` and
    `qty_over_365_days`; `dispatch_info.days_since_last_dispatch` and
    `dispatch_info.avg_days_between_dispatches` use India's days too.
  - `get_customer_stock_analysis_v2`: the day named in `message`
    ("... as of 2026-10-01 retrieved successfully") is India's day of the
    date given.
- Figures change only for activity between 00:00 and 05:30 India time (18:30 to
  24:00 UTC), for ages in the hours around India's midnight, and at the edge of
  the 360-day window. Everything else is unchanged: the guard, grants, key
  sets, the weight figures, the sort and summary of migration 52, and the order
  of every list (receipts are still ordered by the moment).
- Not changed: moments stay moments (`grn_date` and
  `dispatch_info.last_dispatch_date` of the aging report, `as_of_date`,
  `retrieved_at`, the `date` of `get_customer_grn_items`). `get_item_wise_stock_list`
  and `get_customer_grn_items` take no day from a moment and need nothing.
- App: no app change is needed; the app shows the dates and ages as returned.

## Unreleased — GRN activity report weights are bags times bag weight (2026-10-12)

Migration 59. **Operator action:** none beyond applying the migration (the
normal upgrade does). No setting, service or container changes.

- `get_customer_grn_activity` added up the per-bag weights of a receipt's lines
  (`goodsreceived_trl.weight`, kg **per bag**) without the bags, so its weight
  totals were not weights: a receipt of 100 bags of 25 kg and 40 bags of 50 kg
  answered `75`. Every weight **total** of the function is now the kg received:
  the sum, over the received lines, of the line's received quantity (`qty`, not
  the stock left) times its per-bag weight, in kg. The same receipt answers
  `4500`. A line with no per-bag weight counts as 0, and a receipt without such
  lines is `0` (a number). Keys and types are unchanged (numbers):
  - one customer: `data.grns[].total_weight` (kg of the receipt) and
    `data.summary.total_weight_kg` (the sum of the listed receipts);
  - no customer given (all customers): `data.by_customer[].total_weight` and
    `data.summary.total_weight_kg`.
- Per bag, not changed: `data.grns[].items[].weight` is the kg per bag as typed
  in (`null` when a line has none). It is not a total.
- `get_all_grn_activity` (the all-customers report the app calls) already
  multiplied bags by bag weight in `summary.total_weight` and
  `by_customer[].total_weight`, since the first schema. It is unchanged; the
  migration only checks the two expressions are still there and fails, applying
  nothing, if not. So the all-customers GRN PDF, which prints those two, was
  right before and stays right, and it now agrees with the other function. (A
  customer whose lines all have no per-bag weight is a `null` `total_weight`
  there, as before.)
- The stock reports use the same per-bag weight times the quantity they count:
  bags still in storage (`get_customer_stock_summary`, `get_all_stock_summary`,
  `get_operations_dashboard`) and, since migration 58, bags dispatched. Weight
  received uses the bags received. Not touched here: `get_stock_aging_report`
  adds per-bag weights the same way (`summary.total_weight_kg` and the bucket
  totals); that is for a decision of its own.
- App: the mobile app reads `total_weight` on a receipt and `total_weight_kg` in
  the summary (`src/services/reporting/grn-activity-service.ts`) but shows
  neither on a screen today, so nothing on a screen changes and no app change is
  needed. The one-customer GRN PDF (`generate-report-pdf`) keeps computing each
  GRN's weight from its lines, which is right with or without this migration.
- Nothing else changes: the `authorize_rpc` guard, SECURITY DEFINER, the
  search_path and jit setting, the grants, the India day cut of migration 56, the
  end-day rule of migration 54, every other key and the order of the receipts
  and customers. Compared in a throwaway database, the only difference in the
  two function definitions is the two lines of the per-receipt sum.
- `tests/report_grn_weight.sql` checks, as staff, an administrator and a
  customer account, a customer with three receipts in a period (100 x 25 + 40 x
  50 = 4500; 60 x 30 + 10 with no weight = 1800; 20 x 40 = 800; summary 7100),
  that the received bags are used and not the stock left (after two dispatches),
  that each total equals the figure worked out from the tables, that a deleted
  receipt and one before the period are not counted, that periods move the
  weights, a second customer (310) and a customer whose lines have no weight
  (0), all customers (7410 = 7100 + 310 + 0) against `get_all_grn_activity`,
  that the key sets and the per-bag line weight are unchanged, that a customer
  account is still refused another customer, all customers and
  `get_all_grn_activity`, and that both functions are single and keep their
  guard, search_path and grants. No earlier SQL test asserted the old figures.

## Unreleased — the invoice PDF follows the Paid / Pending choice; two labels in Gujarati (2026-10-12)

No migration: `functions/generate-report-pdf` only. **Operator action:** none
beyond the normal upgrade, which recreates the functions container. No setting,
service or SQL change.

- The invoice history PDF of one customer ignored the app's Paid / Pending
  choice. `generate-report-pdf` now takes an optional `"status": "paid" |
  "pending"` (`null` is the same as leaving it out). It is accepted only with
  `"report": "invoice-history"` and a `customer_id`; anything else is a 400 with
  a fixed message that does not echo the body:
  - `status is only for the invoice history of one customer` (any other report,
    or the invoice history without a customer, with either value);
  - `status must be 'paid' or 'pending'` (any other value).
  An unknown key still gets `Unknown field in report request`, as before.
- With `status` set, only the invoices whose `payment_status.status` equals it
  are listed (the app reads the status the same way), and every figure of the PDF
  is over those invoices: the totals row and the summary (Invoices, Net amount,
  Paid, Pending; Paid and Pending are net amounts, as in the RPC, so the other
  status shows `0.00`). The summary covers all the listed invoices also when the
  table is cut at 2000 rows. The header, under the title and again in the
  table's header row, gets one more line between the period and the sort:
  `Payment: Paid` or `Payment: Pending` (`ચુકવણી: ચૂકવેલ`, `ચુકવણી: બાકી` in
  Gujarati, the app's `reports.filters.payment`, `reports.customerActivity.paid`
  and `common.pending`). The answer's `document` carries `status` when it was
  set. The function still calls the same report RPC with the caller's token; the
  invoices of the other status are dropped afterwards, so no access rule changes.
- Without `status` the PDF is exactly what it was (the tests compare the HTML
  of every report fixture, both levels, both languages, with the earlier output).
- An app that sends `status` to a function without this change gets `Unknown
  field in report request` (400) and retries without it; the PDF then lists
  every invoice. Upgrade the backend first and the choice is followed.
- Two labels that printed in English in a Gujarati PDF now have Gujarati, made
  of the app's own words: `Latest invoice` is `છેલ્લું ઇન્વૉઇસ` (the "Latest"
  of an invoice row, `reports.invoiceHistory.latestInvoice`, with the app's word
  for invoices) in the all-customers invoice history, and `Last activity` is
  `છેલ્લી કામગીરી` (`reports.sort.lastActive`, `reports.customerActivity.lastActive`)
  in the all-customers customer activity report. English PDFs are unchanged.
  The wording is for the owner to check.
- The stock aging PDF's figure for the oldest stock now matches the app's screen: it prints the item count of the
  over-364-days bucket (`by_bucket['364+'].item_count` of the RPC's answer, the figure of the screen's tile and red
  bar) under the app's own label, `Items over 364 days` (`૩૬૪ દિવસથી વધુ જૂની આઇટમ`), in the summary at the
  one-customer and the all-customers level; before, it printed the bags over 365 days (`summary.qty_over_365_days`)
  as `Over 1 year`. The all-customers table keeps its per-customer `Over 1 year` column (items older than 365 days),
  because the answer carries no per-customer count of that bucket.
- The report PDFs print India's calendar day for every date that the database returns as a moment, so a PDF agrees
  with the app's screen for a document made between 00:00 and 05:30 India time. They printed the first ten characters
  of the time, which is the UTC day: a receipt made at 02:30 India time on 1 October (`2026-09-30T21:00:00+00:00`)
  was printed as 30 September. The moments are the GRN activity of one customer (`Date`), the invoice history
  (`Date` of one customer, `Latest invoice` of all customers), the stock aging of one customer (`Date`, `Last
  dispatch`) and the customer activity of all customers (`Last activity`). The dates the database already gives as
  India days (the dispatch activity, `Latest GRN`, the stock summary, the months of the customer activity) are
  printed as they are. A report sorted by a date column is ordered by the day that is printed, and two moments of
  one day by their time. The `Last updated` line of every report is India's day and clock too
  (`Last updated 12-10-2026 13:30 IST`; it was the UTC day and clock, `... 08:00 UTC`).
- Checks: `tests/report-pdf.test.mjs` (`npm test`).

## Unreleased — invoice amounts in the reports are the invoice total (2026-10-12)

Migration 61. **Operator action:** none beyond applying the migration (the
normal upgrade does). No setting, service or container changes.

- What was wrong: an invoice's payable amount is `invoice.total`
  (`recalculate_invoice_header` stores the ceiling of the line bases plus the tax
  minus the discount; a line base already holds the labour). Payments, Tally, the
  invoice PDF and the invoice screens all use `total`. Three report functions
  built a "net" figure as `total + labour + tax_amount - discount`, which adds
  the labour and the tax a second time and takes the discount off a second time.
  Example: 1 bag, charge 10, labour rate 2.50, tax 5%: base 12.50, tax
  ceil(0.625) = 1, `total` = ceil(13.50) = 14. The reports said 14 + 2.50 + 1 =
  17.50.
- Every key whose value changes is a number before and after, with the same name;
  the new value is the invoice total:
  - `get_customer_invoice_summary`, one customer: `invoices[].net_total` (now =
    `total`), `summary.net_amount` (now = `summary.total_amount`),
    `summary.paid_amount` and `summary.pending_amount` (the totals of the
    invoices with / without a payment row, so paid + pending = `total_amount`),
    and `by_month[].paid_amount` and `by_month[].pending_amount`;
  - `get_customer_invoice_summary`, no customer (all customers):
    `by_customer[].net_amount` (now = `total_amount`) and `summary.net_amount`;
  - `get_customer_activity_detail`: `summary.total_invoice_amount`,
    `monthly_trends[].invoice_amount`, `summary.total_pending_amount` (the
    invoiced amount minus `total_paid_amount`, so it follows) and
    `recent_invoices[].net_total`;
  - `get_all_customer_activity_summary`: `summary.total_invoice_amount` and
    `customers[].total_invoice_amount`.
  `total_amount`, `total_labour`, `total_tax`, `total_discount`, the counts,
  `invoices[].total`, `labour`, `tax_amount`, `discount` and
  `summary.total_paid_amount` (the payments themselves) are not touched.
- **Figures go down.** In the invoice history and customer activity reports and
  their PDFs, every amount above falls to the real one: the worked invoice shows
  14 and not 17.50, and an invoice with a discount no longer has it deducted
  twice. Nothing is lost: no stored value changes, only what the reports add up.
- Duplicate rows: `get_customer_invoice_summary` listed an invoice once per row
  in `payments` and added it once per row, so an invoice with two payment rows (a
  part payment and the balance, as Tally writes them) appeared twice and counted
  twice in `total_invoices`, `total_amount`, `paid_count` and every other sum.
  Its payment status is now one entry per invoice: `payment_status.amount` is the
  sum of the invoice's payment rows (it was the one row's amount), and
  `paid_date`, `payment_ref` and `payment_mode` are those of the latest payment
  row (the latest `payment_date`, then `payment_no`). The keys of `payment_status`
  are unchanged, and an invoice with one payment row or none is answered as
  before.
- "Paid" still means "has a payment row": an invoice with a part payment counts
  as paid in full in `paid_count`, `paid_amount` and `status`. Changing that is
  the owner's decision and this migration does not.
- What an app shows: the invoice history screen's "Net amount" tile, its paid and
  pending tiles, the customer rows and each invoice's amount, and the customer
  activity screen's invoiced amount, monthly amounts and recent invoices read
  these keys, so they show the lower, real amounts, the same as the invoice
  itself, with no app change. Before: 17.50 for the worked invoice, and an
  invoice with two payment rows listed twice. After: 14, listed once.
- Report PDFs (`generate-report-pdf`): both levels of the invoice history print
  one amount. Neither prints a "Net amount" column or figure any more (it
  repeated "Amount"); the app's net sort, which it still sends for the amount
  sort of both levels, is still accepted and sorts by the amount, and the report
  names the real column. The invoice history of one customer works its amount,
  paid and pending figures out from the totals of the invoices it lists, so it
  is right on a database with or without this migration. The all-customers
  invoice history prints the RPC's `total_amount` (right on every database) in
  its Amount column and figure. The customer activity PDF reads the corrected
  keys and has no invoice total to work from, so its amounts are right from
  migration 61 on.
- Nothing else changes: the `authorize_rpc` guard, SECURITY DEFINER, the
  search_path and jit setting, the grants, the India day cuts of migrations 54 and
  56, the key sets and the order of the rows. Compared in a throwaway database,
  the only differences in the three function definitions are the sum expressions
  (six places) and the payment status (three lines).
- `tests/report_invoice_amounts.sql` makes seven invoices with `save_invoice`
  (the worked example, discounts, labour and tax rates, one invoice with two
  payment rows, one paid with one row, pending ones, one outside the period, a
  second customer) and checks every key above as staff, an administrator and a
  customer account, that the old sum is gone, and that the three functions keep
  their guard, search_path and grants; `tests/report-pdf.test.mjs` checks the PDF
  with the answer of a database with and without the migration.

## Unreleased — dispatch activity report returns weights (2026-10-12)

Migration 58. **Operator action:** none beyond applying the migration (the
normal upgrade does). No setting, service or container changes.

- `get_customer_dispatch_activity` returned a weight only for the whole period
  (`summary.total_weight`). It now also returns, all in kilograms:
  - `weight` on each item (line) of a dispatch: the quantity dispatched from that
    received line times its per-bag weight (`goodsreceived_trl.weight`, kg per
    bag). 5 bags of 50 kg is `250`. A received line with no per-bag weight (or
    no quantity) is `0`.
  - `total_weight` on each dispatch: the sum of the `weight` of its items. A
    dispatch without lines is `0`.
  - `summary.total_weight` is unchanged (it was already the sum of dispatched
    quantity times per-bag weight, in kg, over the not deleted dispatches of the
    customer in the period): it equals the sum of the returned dispatches'
    `total_weight`. The migration fails, and applies nothing, if that expression
    is no longer in the function.
- App: the dispatch activity report of the mobile app shows a dispatch's weight
  on its card and offers a Weight sort once the server sends these keys. That
  needs the app change "dispatch weights and a Weight sort when the server sends
  them" (rn-warehouse-template CHANGELOG, 2026-10-12). An app without that
  change keeps working: it reads `weight` on an item (default 0) and shows it on
  the item row when above 0, and it ignores the dispatch's `total_weight`. Order
  of rollout does not matter: the new app against an older server shows no
  weights and no Weight sort.
- Nothing else changes: the other keys and their values, the order of the
  dispatches and of the lines, the period and the India day cut of migration 56,
  `disp_id` of migration 57, the access rules (a customer account still gets only
  its own customer's dispatches) and the grants. `get_all_dispatch_activity`
  (all customers) returns no weight, as before.
- `tests/report_dispatch_weight.sql` checks, as staff, an administrator and a
  customer account, a customer with three dispatches (5 bags of 50 kg with 3 of
  25 kg is 325, a line with no per-bag weight is 0, 2 bags of 50 kg is 100): the
  weight of each line, the total of each dispatch, a summary of 425 that equals
  the sum of the dispatches and the table's own figure, that a period which
  excludes a dispatch excludes its weight, that a deleted dispatch and another
  customer's are not counted, that a dispatch without lines is 0, that a
  customer account is still refused another customer's dispatches, and that the
  function is single and keeps its guard, search_path and grants. The key sets
  asserted in `tests/report_dispatch_id.sql` now include the two new keys.

## Unreleased — dispatch activity report returns the dispatch id (2026-10-12)

Migration 57. **Operator action:** none beyond applying the migration (the
normal upgrade does). No setting, service or container changes.

- Each dispatch in the answer of `get_customer_dispatch_activity` now carries
  `disp_id`, the id of the dispatch (`dispatch.id`). The app's dispatch
  activity report shows its "Open dispatch" control only when a dispatch has
  that field, and opens the dispatch details screen with it, so until now the
  control never appeared. With this migration applied it does, with no app
  change.
- Nothing else changes: the other keys of a dispatch and of its items, the
  summary, the order, the period and the India day cut of migration 56, the
  access rules (a customer account still gets only its own customer's
  dispatches) and the grants are as they were. The id is only that of a
  dispatch the caller is already given.
- `tests/report_dispatch_id.sql` checks, as staff, an administrator and a
  customer account, that each listed dispatch carries the id of its own row in
  `dispatch` (compared with the table), that the exact set of keys is the
  earlier one plus `disp_id`, that a deleted dispatch and another customer's
  are not in the answer, that a customer account is still refused another
  customer's dispatches, and that the function is single, guarded and keeps
  its grants.

## Unreleased — report days follow India's calendar (2026-10-12)

Migration 56. **Operator action:** none beyond applying the migration (the
normal upgrade does). No setting, service or container changes.

- The facilities keep their books in India and billing already counts India
  days (migration 41), but the reports cut their days in the database's time
  zone (UTC). Activity between midnight and 05:30 in India counted against the
  day before, and a period also took in the first five and a half hours after
  its last day. Every day a report cuts is now an India day: both ends of a
  period, the per-day and per-month lists, the latest-activity day, the
  month-end stock, the stock age in days, and "today" when a report is called
  without days. Functions changed: `get_all_dispatch_activity`,
  `get_all_grn_activity`, `get_all_customer_activity_summary`,
  `get_customer_dispatch_activity`, `get_customer_grn_activity`,
  `get_customer_activity_detail`, `get_customer_invoice_summary`,
  `get_operations_dashboard`, and the receipt list `get_grn_list`.
- **Figures for a period may change** for activity between midnight and 05:30
  India time on its boundary days: such a receipt, dispatch or invoice now
  belongs to its India day (in a period that starts that day, out of one that
  ends the day before), and the per-day and per-month lists show it under that
  day or month. Nothing else in the figures changes.
- The whole last day stays in (migrations 54 and 55). A period is compared as
  two moments, so the date indexes on receipts, dispatches and invoices are
  still used. New private helper `warehouse_security.business_day_start(date)`,
  the first moment of a day in India, the counterpart of
  `warehouse_security.business_date`, which is unchanged.
- The app needs no change: it already sends report periods as plain days of
  India's calendar.
- `tests/report_ist_day.sql` puts rows a second before and at midnight India
  time, at 01:30 and 23:30 India time on the last day, at 00:00 and 00:15 the
  day after, and on both sides of a month end, and checks every function's
  counts, totals and day and month keys, with the session in UTC and in another
  zone, plus the role rules. `tests/report_to_date.sql` and
  `tests/grn_list_end_day.sql` now state their moments in India time.

## Unreleased — GRN list includes the end day (2026-10-12)

Migration 55. **Operator action:** none beyond applying the migration (the
normal upgrade does). No setting, service or container changes.

- A GRN list filtered by dates now includes the last day's receipts.
  `get_grn_list` compared the end day of its date filter (`p_date_to`, a date)
  directly with the receipt time, which reads the day as midnight at its start,
  so every receipt on the last day was left out. The filter now runs to the end
  of its last day (`< p_date_to + 1`, the form migration 54 uses for the
  reports). The start day was already included. Nothing else in the function
  changes; the guard, grants, role rules and the receipt-number ordering are as
  they were.
- Not changed: a day in this filter is still a day in the database's time zone
  (UTC), not India's.
- `tests/grn_list_end_day.sql` puts receipts at 02:00 and 23:30 UTC on the last
  day, on the day after, on the first day and on the day before, and checks the
  list, its total and its order for staff, and that a customer account is still
  refused.

## Unreleased — report periods include the end day (2026-10-12)

Migration 54. **Operator action:** none beyond applying the migration (the
normal upgrade does). No setting, service or container changes.

- `get_all_dispatch_activity`, `get_all_grn_activity`,
  `get_customer_grn_activity` and `get_customer_invoice_summary` compared the
  last day of the period (`p_to_date`, a date) directly with the receipt,
  dispatch or invoice time, which reads the day as midnight at its start. Every
  receipt and invoice on the last day was left out, and every dispatch with a
  time of day after midnight (the app's dispatch form stores the start of the
  dispatch date, so those were counted). The app always asks for a period that
  ends today, so today's receipts and invoices were missing from these reports. The period now runs to the end of its last day (`< p_to_date + 1`),
  in the summaries, the per-customer and per-day lists and the receipt and
  invoice lists. Nothing else in the four functions changes; the guard, grants,
  role rules and the migration 52 order are as they were.
- **Figures for a period now include its last day.** Totals people saw before
  for the same period may rise by that day's activity; earlier days are
  unchanged.
- The other four report functions that take a period
  (`get_all_customer_activity_summary`, `get_customer_activity_detail`,
  `get_customer_dispatch_activity`, `get_operations_dashboard`) already
  included the last day and are not changed.
- Not changed: a day in these reports is still a day in the database's time
  zone (UTC), not India's.
- `tests/report_to_date.sql` puts rows at 02:00 and 23:30 UTC on the last day,
  on the day after, on the first day and on the day before, and checks the
  summaries and lists of each of the four functions, and that staff may and a
  customer account may not run the all-customers reports.

## Unreleased — report lists: server-side sort and totals (2026-10-12)

Migration 52. **Operator action:** none beyond applying the migration (the
normal upgrade does). No setting, service or container changes.

For the sort control on the app's report screens:

- `get_item_wise_stock_list`, the only paged report list, takes two new
  optional parameters: `p_sort_by` (`item_name`, `total_stock`, `total_qty` or
  `grn_count`; default `item_name`) and `p_sort_order` (`asc` or `desc`;
  default `asc`), compared without regard to case. Any other value, `null`
  included, means the default of that parameter; it is never an error and is
  never built into SQL. Equal rows are ordered by item name and then item id,
  so pages neither repeat nor skip an item. A call with only the four old
  parameters works as before and keeps the item-name order.
- Its answer gains `data.summary` = `{ total_stock, total_qty, item_count }`
  over the whole filtered list (the same customer and search as the rows), on
  every page. `data.items` and `data.total_count` are unchanged. The app no
  longer has to add up the pages it has loaded.
- The function was replaced, not overloaded: there is one
  `get_item_wise_stock_list`, with the same guard, grants and role rules.
- `get_all_stock_summary` (`customers`), `get_all_grn_activity` and
  `get_all_dispatch_activity` (`by_customer`) ordered their customers by the
  total read as text, so 9 came before 100 and 100 before 10. They now order by
  the number, largest first, a missing total last, and equal totals by customer
  name. Nothing else in those answers changes.
- `tests/report_sort.sql` covers each sort in both directions, paging, the
  summary with search and customer filters, hostile sort values, the numeric
  order of the three lists and the unchanged role rules.

## Unreleased — central login: facility token exchange (2026-10-12)

Migration 49, `functions/central-exchange`, `setup.sh`. **Operator action:**
none, unless you configure the association's issuer: central sign-in is off
until `setup.sh` is run with `--central-issuer` and a key source
([docs/OPERATOR_INSTALL.md](docs/OPERATOR_INSTALL.md#central-sign-in)). The
upgrade applies migration 49 and recreates the functions container; the
database container is not recreated. SMS sign-in is unchanged.

The facility half of central login
([docs/CENTRAL_LOGIN.md](docs/CENTRAL_LOGIN.md)). The association's central
service and the app screens do not exist yet, so nothing can produce a valid
token today.

- New public endpoint `POST /functions/v1/central-exchange`. It verifies an
  identity token signed by the central service (ES256 only, type
  `facility-identity+jwt`, exact issuer, this facility's origin as the only
  audience, at most 10 minutes of life, verified phone number) and then
  answers as `operator-otp/verify` does: a pending access request for an
  unknown person, this facility's session for an approved one, a refusal for a
  rejected or disabled one. A token is accepted once.
- **An existing profile is never opened on the central service's word alone.**
  A profile that is already here (the installation's administrator, anyone
  enrolled with an SMS code) is linked to a central account only together with
  a correct SMS code that this facility sent to its number: the first exchange
  answers `link_required`, the app requests a code from `operator-otp/request`
  and repeats the exchange with a fresh token and `otp_code`. After that the
  token is enough. What the facility relies on the central service for is
  stated at the top of docs/CENTRAL_LOGIN.md.
- New settings, all empty by default: `CENTRAL_ISSUER` and one key source,
  `CENTRAL_JWKS_URL` (the facility fetches the keys) or `CENTRAL_JWKS_FILE`
  (the keys come from a file copied into the state; nothing is fetched).
  `setup.sh --central-issuer URL` with `--central-jwks-url URL` or
  `--central-jwks-file PATH` sets or replaces them on a fresh setup or a rerun;
  `--central-issuer off` removes them. `setup.sh` reads the issuer from
  `compose.env` and writes it to the database; run it again after a restore.
- The functions container mounts the state's `public/` directory read-only
  (for the key file), next to the instance manifest.
- `get-public-config` answers `centralLogin`: `{ issuer }` when central sign-in
  is configured with usable values, `null` when not.
- `user_profiles` has two new columns, `central_issuer` and `central_subject`.
  A phone number whose profile is linked to another central account is refused
  (`identity_conflict`) until an administrator unlinks the profile with the new
  `clear_user_central_identity` (administrators only; it also signs that
  profile out).
- `delete_user_account` drops the central link of the deleted profile, as it
  already gives up the phone number.
- `npm run retention:apply` also removes expired single-use records
  (`central_token_use`).
- Migration 51 drops `public.central_user_links`, the empty table of an earlier
  central-login design (migration 0) that nothing read or wrote; the link lives
  on `user_profiles`.
- The sign-in answers of both paths now include the two new profile columns in
  `user` (they are `null` for a profile that never signed in centrally).
- Not measured: how long fetched keys stay in a function worker's memory (at
  most 10 minutes; possibly about a minute, the worker timeout), and nothing
  of this has run inside the edge runtime yet.

## Unreleased — report PDFs: generate-report-pdf (2026-10-12)

Migration 53, `functions/generate-report-pdf`. **Operator action:** none
beyond the normal upgrade (it applies migration 53 and recreates the functions
container). No new setting or environment variable. Report PDFs are removed by
`npm run retention:apply` like the document PDFs.

A new signed-in endpoint renders one report screen of the app as a PDF. It
reads the report's existing RPC with the **caller's token** (no new SQL for
data; `authorize_rpc` and each function's customer rules apply unchanged), then
stores the file in the private `documents` bucket as
`report/<report>/<customer id or all>/<random uuid>.pdf` and returns a signed
link. The app has called it since its reports rebuild.

`POST /functions/v1/generate-report-pdf`, `Authorization: Bearer <session>`,
JSON body of at most 4096 bytes:

```
{
  "report": "grn-activity" | "dispatch-activity" | "invoice-history" | "stock-summary"
          | "stock-aging" | "item-stock-summary" | "customer-activity",   // required
  "customer_id": "<uuid>",          // optional; absent or null = all customers (refused to customer accounts)
  "from": "YYYY-MM-DD",             // required for grn-activity, dispatch-activity, invoice-history,
  "to":   "YYYY-MM-DD",             //   customer-activity; refused for the three stock reports
  "sort": { "field": "<name>", "order": "asc" | "desc" },   // optional
  "lang": "en" | "gu"               // optional, default "en": language of the labels
}
```

- No other field is accepted. `from` and `to` are real calendar dates from
  2000-01-01, `from <= to`, at most 450 days with both ends included.
- `sort.field` is a lower-case name; a name the report does not sort by gives
  the report's default order (not an error). `sort.order` must be `asc` or
  `desc`. Fields by report (one-customer level / all-customers level; default
  first):
  - grn-activity: `date` desc, `gr_no`, `items`, `quantity`, `weight`, `stock`,
    `invoice` / `quantity` desc, `customer`, `grns`, `weight`, `latest`
  - dispatch-activity: `date` desc, `disp_no`, `grn`, `items`, `quantity` /
    `quantity` desc, `customer`, `dispatches`, `latest`
  - invoice-history: `date` desc, `invoice_no`, `grn`, `amount`, `tax`, `net`,
    `status` / `amount` desc, `customer`, `invoices`, `net`, `latest`
  - stock-summary: `item` asc, `gr_no`, `date`, `mark`, `rack`, `stock`,
    `weight` / `stock` desc, `customer`, `items`, `grns`, `weight`
  - stock-aging: `age` desc, `item`, `gr_no`, `date`, `rack`, `stock`,
    `last_dispatch` / `stock` desc, `customer`, `average_age`, `over_one_year`
  - item-stock-summary (both levels): `item` asc, `packaging`, `grns`,
    `received`, `stock`
  - customer-activity: `month` asc, `grns`, `received`, `dispatches`,
    `dispatched`, `amount`, `stock_end` / `stock` desc, `customer`, `city`,
    `grns`, `dispatches`, `amount`, `last_activity`

Success (HTTP 200), the shape of `generate-customer-stock-pdf`:

```
{ "success": true,
  "pdf_url": "<SUPABASE_PUBLIC_URL>/storage/v1/object/sign/documents/report/...?token=...",
  "expires_in": 3600,
  "document": { "type": "report", "report": "<report>",
                "customer": "<customer name>",          // only with customer_id
                "from": "YYYY-MM-DD", "to": "YYYY-MM-DD", // only for reports with a period
                "rows_count": 123,                      // table rows printed
                "rows_total": 123,                      // rows the report has
                "truncated": false,                     // true when rows_total > 2000
                "sort": { "field": "date", "order": "desc" } } }  // the order applied
```

Errors: `{ "success": false, "error": "<message>" }` with 400 (invalid body or
request), 401 (no or invalid token), 403 (session revoked, profile inactive, or
the RPC refused this account: a customer account asking for another customer or
for the all-customers level), 404 (unknown customer), 405 (not POST), 503 (data,
renderer, storage or link unavailable), 500 otherwise. Same envelope and codes
as the document PDFs.

The PDF: warehouse name and report title; the customer (or "All customers"),
period, sort and time in the header and again as the first header row of the
table on every page; a summary block with the RPC's own figures (they cover
every row); one table of at most 7 columns, numbers right-aligned in
figures of one width with Indian digit grouping, dates DD-MM-YYYY; a totals row
over the rows printed; the page footer with title, warehouse name and page
numbers. At most 2000 rows; a longer report is cut, with "Showing 2,000 of N"
under the table and in the footer of every page. Labels in Gujarati are the
app's own wording; `Sort by`, `ascending`, `descending`, `Tax`, `Status` and
`City` now print in Gujarati too, copied from the app's filters, data-table,
invoice, users and customers translations, and the two labels the app has no
Gujarati for yet (`Latest invoice`, `Last activity`) print in English, listed
in `functions/_shared/report-labels.ts`.

- Migration 53 widens `warehouse_maintenance.expired_generated_documents` so
  the `report/...` names (the seven report names, a customer id or `all`, a
  UUID file name) are listed for removal with the document PDFs; any other name
  in the bucket is still never listed. `tests/report_pdf_retention.sql`.
- `tests/report-pdf.test.mjs`: every request refusal, the RPC and arguments of
  each report and level, the columns in English and Gujarati, sorting,
  the 2000-row cut, refusal mapping, the HTML and footer, the router entry and
  the worker environment.
- Not covered by a test here: a real render through Gotenberg and the HTTP path
  on an installed stack.

## Unreleased — edge functions download nothing at start (2026-10-12)

`functions/`. **Operator action:** none; the next start recreates the
functions container. A facility server no longer needs to reach esm.sh or
deno.land for sign-in codes, app configuration or PDFs.

- The functions imported supabase-js and jose from esm.sh and the Deno
  standard library from deno.land every time their container was recreated,
  with no check of what came back (review finding X5-1). Both libraries are
  now files in the repository, `functions/vendor/jose.mjs` and
  `functions/vendor/supabase-js.mjs`, built by
  `scripts/vendor-edge-modules.sh` from an integrity-locked manifest and
  checked against `functions/vendor/SHA256SUMS` by a unit test.
- The standard library was used for `serve` only; the functions use the
  runtime's `Deno.serve`. `functions/import_map.json` is removed.
- Versions are unchanged (jose 5.10.0, supabase-js 2.39.0). supabase-js's own
  Supabase dependencies are now fixed at 2.117.3; before, esm.sh chose them
  when it served the module.
- Not changed: the printing functions still import `ipp` at run time. The
  router refuses them, so nothing loads it today.

## Unreleased — image transformation works again (2026-10-12)

`docker/docker-compose.yml`, `scripts/compose.sh`. **Operator action:** none;
the next start recreates the imgproxy container.

- Every image transformation (`/storage/v1/render/image/...`) failed with
  "Internal error". imgproxy ran as its image's user (999), and the storage
  directory is private to the installing user (mode 0700), so imgproxy could
  not open any stored picture. It now runs as the owner of that directory;
  the mount stays read-only. The app does not request transformed pictures
  today, so nothing visible was broken, and no test asked for one: the
  operator API test now uploads a 2x2 picture and requires a 1x1 back.
- Found on the dev instance while checking Storage v1.80.2; the fault is
  older than that update (the pictures it failed on were stored the day
  before).

## Unreleased — Storage v1.80.2 (2026-10-12)

`docker/storage`. **Operator action:** none beyond the usual upgrade; the
setup rerun rebuilds the Storage image, and Storage applies its own schema
changes when it starts.

- Storage moves from v1.79.14 to v1.80.2, with the dependency manifest
  rebuilt from the new tag (`docker/storage/README.md` describes the steps).
  The new tag pins fastify 5.11.2 and `@fastify/busboy` 3.1.1, which have
  HIGH findings; the manifest raises them to 5.12.5 and 3.2.1.
- The recipe now applies Alpine's package updates (`apk upgrade`). A Trivy
  scan of the build has no HIGH or CRITICAL finding; the v1.79.14 build had
  13, all in Alpine packages (Python and libexpat).

## Unreleased — Studio 2026.10.05 (2026-10-12)

`docker/studio/Dockerfile`. **Operator action:** none beyond the usual
upgrade; the setup rerun rebuilds the Studio image.

- Studio moves from `2026.09.21-sha-512201d` to `2026.10.05-sha-94b8b06`. The
  new tag ships next 16.3.6 and a fixed sharp, which closes one Critical and
  one High finding; six findings with a fixed release remain in the
  publisher's application (simple-git, its argument parser, next and the MCP
  SDK), listed in `docs/CONTAINER_SECURITY.md` under "Open items".
- The new image adds two more links to pnpm (`pn`, `pnx`); the recipe removes
  them with the other package-manager tools.

## Unreleased — Realtime v2.143.1; PostgreSQL 15.19 image held (2026-10-12)

`docker/realtime/Dockerfile`. **Operator action:** none beyond the usual
upgrade; the setup rerun rebuilds the Realtime image, and Realtime applies its
own schema changes when it starts.

- **Realtime v2.143.1** (was v2.134.10). The publisher's image now runs as
  `nobody`; the recipe switches to root only for the package upgrade.
- **Not taken: `supabase/postgres` 15.19.0.004.** It is not a newer build of
  the image in use but a different one: Alpine in place of Ubuntu (the
  recipe's `apt-get` step cannot run), another user id for `postgres` (100,
  was 105, and an existing data directory belongs to 105), no `wal-g`, and the
  migration tests stop on it because the Storage schema is missing. That is a
  planned upgrade. Not examined: whether text sorts the same on both.
  `.github/dependabot.yml` holds minor updates of that image with these
  reasons. PostgreSQL stays at 15.8.
- Dependabot, corrected after one day: the two recipe manifests
  (`docker/postgres-meta`, `docker/storage`) get security updates only. The
  weekly group added on 2026-10-12 proposed 44 minor and patch updates at
  once and the metadata image did not build with them. `supabase/storage-api` minor
  updates are held as well: a new tag needs the manifest rebuilt from it.

## Unreleased — dependency updates, Prometheus 3.15.0 (2026-10-12)

Image recipes only. **Operator action:** none beyond the usual upgrade; the
setup rerun rebuilds the four images whose recipes changed (Prometheus, the
print service, the metadata service and storage).

- **Prometheus 3.15.0** (was 3.14.0). The recipe compiles Prometheus from
  source into the publisher's image, so the source tag, the UI archive, both
  checksums, the version string and `go.mod`/`go.sum` moved together with the
  image. `golang.org/x/net` stays at v0.60.0 and `golang.org/x/crypto` is
  v0.57.0, both above what the release pins. The release's workspace file
  already asks for Go 1.26, so the recipe no longer edits it.
- A new unit test fails when the image tag of that recipe changes without the
  source it compiles. Dependabot proposed exactly that (the image alone), which
  would have left 3.14.0 running under a 3.15.0 tag.
- The print service's `ubuntu:22.04` base moves to the current digest.
- Minor and patch updates in the two recipe manifests: `@fastify/swagger`
  9.9.1 (both), and in `docker/postgres-meta` `@fastify/cors` 11.3.1 and
  `prettier-plugin-sql` 0.20.0.
- Not taken: `@types/pg` 8.23.1 and `@sentry/node` 10.76.2. Each fails the
  type check of the postgres-meta source the recipe builds, so the image does
  not build. `.github/dependabot.yml` now holds their minor updates.
- Dependabot now proposes the minor and patch updates of those two manifests
  as one pull request a week, not one per package.

## Unreleased — metadata service: longer start allowance (2026-10-12)

`docker/docker-compose.yml` and two scripts. **Operator action:** none; the
next start applies the new health check.

- The metadata service (`meta`, a quarter of a CPU) was reported unhealthy 90
  seconds after a start twice in CI, once in the lost-host restore and once
  when a backup restarted the services, and the drill failed. Its health check
  now has a start period of 120 seconds instead of 30. The cause is inferred
  from the timing and the CPU limit; no log of a failing start exists yet.
- For the next time: a backup whose services do not restart cleanly now lists
  the services that are not healthy with their last log lines, as a restore
  already does (`scripts/service-diagnostics.sh`, shared by both).

## Unreleased — Dependabot: four more holds (2026-10-12)

Repository maintenance. After the rules of 2026-10-11 Dependabot proposed the
next versions it was still allowed to: Ubuntu 22.10 for the print service (a
release that is not long-term), the imgproxy build base v4, PostgreSQL 17 and
the postgres-meta v0.100.0 image. Each needs a planned upgrade (a matching
source tag, or a data directory upgrade for PostgreSQL), so
`.github/dependabot.yml` holds these version updates too, each with its
reason. Security updates are still proposed.

## Unreleased — functions route: hourly cap 6000 (2026-10-11)

`docker/kong.yml` only. **Operator action:** restart the gateway container
after the upgrade (`bash scripts/compose.sh restart kong`); it reads
`docker/kong.yml` when it starts, and a setup rerun does not restart it.

- Owner decision: `/functions/v1/` keeps 100 requests a minute per client
  address and its hourly cap goes from 2000 to 6000. A facility whose phones
  share one address was refused sign-in codes, PDF documents and
  configuration reads for the rest of the hour once 2000 requests were used.
  6000 is what 100 a minute adds up to in an hour, so the minute limit is now
  the one that acts. The OTP limits in the database are unchanged.
  `docs/CONTAINER_SECURITY.md`, "REST request limit";
  `tests/gateway-config.test.mjs`.
## Unreleased — Dependabot no longer proposes majors that cannot be taken as they are (2026-10-11)

Repository maintenance; nothing changes for an installation.

- Six of Dependabot's pull requests were major updates that would not have
  been safe to merge although most of them passed CI:
  - `darthsim/imgproxy` v4 changed the runtime image only, while the recipe
    still compiles the v3.31.4 source: a v3 binary on v4 libraries.
  - `@supabase/postgrest-typegen` 0.4 makes its formatter an optional peer
    dependency that postgres-meta v0.99.0 does not install, and no check calls
    the type generator.
  - TypeScript 7, `fastify-metrics` 14 and `@sentry/node` 11 are majors in the
    dependency set of an upstream application built from a pinned source tag;
    `npm audit` reports nothing for that set, so there is no security reason
    to carry more patches to its source. The Sentry one failed CI.
  - Ubuntu 26.04 for the print service changes CUPS and its drivers, which CI
    cannot check without a printer; 22.04 is supported and the recipe applies
    its updates at build time.
- `.github/dependabot.yml` now ignores version updates of those kinds, each
  with its reason. Every ignore entry names its update types, so security
  updates are still proposed; `tests/workflows.test.mjs` checks that.

## Unreleased — Grafana 13.2.3 (2026-10-11)

No migration. **Operator action:** none beyond the setup rerun if you run the
monitoring profile; setup rebuilds the Grafana image and replaces the running
container.

- The Grafana recipe moves from 13.2.2 to 13.2.3, the publisher's security
  release of 2026-09-29 (CVE-2026-13719, CVE-2026-13720, CVE-2026-81841), by
  digest. The check script, the notices, the licence note and the attribution
  review name the new version.
- On 13.2.3 the recipe's OpenSSL upgrade and its four plugin replacements
  change nothing, because the base already has those versions; they stay as
  pins.
- Scan of the rebuilt image: 42 fixed HIGH findings (43 before), none
  CRITICAL, all in the publisher's Go executables, which need a Grafana
  release built with a fixed Go. `docs/CONTAINER_SECURITY.md`, "Grafana OS
  patch and remaining publisher dependency".
- Replaces Dependabot's pull request 45, which changed the base image only and
  failed the notices test.

## Unreleased — the operator-install CI job can run on a self-hosted runner (2026-10-11)

CI only; nothing changes for an installation.

- `operator-install` takes `runs-on` from the repository variable
  `OPERATOR_INSTALL_RUNNER` and falls back to `ubuntu-latest` without it, so a
  fork is unaffected. In this repository the variable names the owner's
  runner machine, which keeps Docker's build cache: the job took 29.7 minutes
  on a hosted runner and 15.0 minutes there (second run in a row). Every
  other job, the three required checks among them, stays on hosted runners.
- `docs/DEVELOPER_HANDOFF.md`, "A self-hosted runner for operator-install":
  what the runner must provide (one job at a time, a cleanup after every
  job) and why it must be an isolated machine with nothing of value on it.
  `tests/workflows.test.mjs` refuses a self-hosted label written into a
  workflow.

## Unreleased — setup rebuilds the images whose recipes changed (2026-10-11)

No migration. **Operator action:** none, but expect the first setup rerun
after this change to rebuild every image in use once (it needs the network
and takes a while); later reruns rebuild only what changed.

- **What was wrong.** `setup.sh` and `start.sh` run `compose up`, which builds
  only an image that is missing. The documented upgrade (`git pull`, setup
  rerun) therefore left every locally built image as it was at the first
  installation: recipe changes under `docker/`, the Go 1.27.2 builders and
  `golang.org/x/net` 0.60.0 among them, never reached a running installation,
  and setup still reported "healthy". Found on the development instance on
  2026-10-11: after a setup rerun at `2b9a870` the database image was still
  the one built on 2026-09-22.
- **Now.** `setup.sh` runs the new `scripts/build-images.sh` before it starts
  anything. It fingerprints each image recipe (every file under the build
  directory, the Dockerfile path, target and build arguments), compares it
  with `config/image-recipes.sha256` in the state directory and rebuilds the
  images whose recipe differs, that are missing, that have no record, or
  whose tag no longer names the image it built. A failed build stops setup
  before it starts or stops anything and records nothing; an image that did
  finish building is used at the next start of its service. `start.sh` still
  never builds. `--all` rebuilds everything in use; `--no-cache` does so
  without the build cache, for current operating-system packages.
- **Optional services.** Monitoring, printing and pooler images are rebuilt
  only where the installation has a container of them. Because setup and
  `start.sh` start only the core services, both now end with
  `build-images.sh --replace-optional`, which replaces the running optional
  services whose image or configuration changed; until now nothing did, so a
  running Prometheus kept its old image through every upgrade.
- **Grafana** builds from `docker/grafana` instead of the whole `docker/`
  directory (`docker/docker-compose.override.yml`, its Dockerfile,
  `scripts/grafana-check.sh`), so that a change to another recipe is not
  taken for a changed Grafana recipe. The same two files are copied into the
  image as before.
- `docs/OPERATOR_INSTALL.md`, "Rerun and upgrade"; `tests/build-images.test.mjs`.
- An installation upgraded from v0.3.0 to v0.4.0 (whose setup does not
  rebuild) still runs the functions runtime 1.76.2 instead of 1.77.4 and
  lacks the dependency and operating-system updates of the storage, metadata
  and Studio recipes, until `bash scripts/compose.sh build` or a setup rerun
  from this change. Whether v0.4.0 behaves differently on those old images
  was not tested.

## Unreleased — golang.org/x/net 0.60.0 in the Go-based images (2026-10-11)

No migration. **Operator action:** none beyond the setup rerun, which rebuilds
the changed images (see "setup rebuilds the images whose recipes changed"
above).

- CVE-2026-78669 (HTTP/2, HIGH) was in every Go binary the recipes build
  (`golang.org/x/net` v0.57.0 or v0.58.0). The module files of the eight
  recipes now select v0.60.0; only `golang.org/x/*` versions and the `go` line
  changed. The Prometheus recipe sets the Go version of the upstream workspace
  file to match.
- Built and scanned (Trivy 0.74.0): alertmanager, auth, cadvisor, the database
  image (wal-g, gosu), imgproxy, node-exporter, postgres-exporter and
  prometheus have no fixed HIGH or CRITICAL finding left. The publisher's
  Gotenberg binary, which no recipe rebuilds, still has four.
  `docs/CONTAINER_SECURITY.md`, "Open items with their steps".

## Unreleased — scan of the Go-based images after the 1.27.2 builders (2026-10-11)

Documentation only (`docs/CONTAINER_SECURITY.md`, "Open items with their steps").

- The nine images whose recipes have a Go build stage were built from
  `bc2b110` and scanned with Trivy 0.74.0. The three standard-library
  advisories are gone from every binary the recipes build. They remain in the
  publisher's Gotenberg binary, which no recipe rebuilds.
- New open item: `golang.org/x/net` below 0.60.0 (CVE-2026-78669, HIGH) in
  every Go binary; the steps are listed.
- Operating-system findings seen at first in imgproxy and Gotenberg came from
  a reused `apt-get upgrade` layer and disappear with a `--no-cache` build.

## Unreleased — Go 1.27.2 builders, refreshed Kong digest and CI action (2026-10-11)

No migration. **Operator action:** none beyond the setup rerun, which rebuilds
the changed images (see "setup rebuilds the images whose recipes changed"
above).

- **Go builders (review finding X5-4).** All ten `FROM golang:` lines use
  `golang:1.27.2-bookworm` by digest; they used 1.27.0 and 1.27.1, behind
  three fixed HIGH standard-library advisories. CI builds nine of the recipes;
  the Auth recipe (a disabled service) was built by hand. `npm run
  scan:images` has not been rerun on the rebuilt images
  (`docs/CONTAINER_SECURITY.md`, "Open items with their steps").
- **Kong** stays `3.9.3-ubuntu`; the pin moves to the index the registry
  serves for the rebuilt tag (`sha256:92035d16...`, amd64 and arm64).
- `pino-pretty` 13.2.0 in the postgres-meta lock file; `actions/setup-node`
  v7.1.0 in both workflows.
- These replace Dependabot pull requests 40, 41, 42, 44, 46, 49, 51 and 53.
  Left open for a decision: Grafana 13.2.3 (#45; the recipe's plugin pins,
  check script and scan numbers name 13.2.2) and the major updates (#9, #43,
  #47, #48, #50, #52).
## Unreleased — a restore whose services do not start says which and why (2026-10-11)

- `scripts/restore.sh` (also behind `restore-host`): when the final start
  fails, the script now lists every service that is not running and healthy
  and prints its last 30 log lines, before the rollback instructions. Until
  now the only clue was Compose's one line, for example
  `container ...-meta-1 is unhealthy`. Seen in CI on 2026-10-11, where the
  lost-host drill failed once on that line with nothing to diagnose it from;
  the cause of that one failure is not known. `tests/restore.test.mjs`.
  No migration; nothing to do on an installed system.

## Unreleased — owner decisions of 2026-10-11

Migration 48 and `docker/kong.yml`. **Operator action:** rerun `setup.sh` as
for every upgrade, and restart the gateway container if the rerun did not
recreate it (it reads `docker/kong.yml` when it starts; until then the old
request limit applies). Use the app build that follows these decisions: an
older build still gets a suggested invoice number (for the current financial
year), but it does not send a zero-charge reason, so staff using it are
refused when they save an invoice that has a line with a charge of 0. An
administrator or supervisor on an older build can still save such an invoice,
and a reason already stored on it is kept.

- **The suggested invoice number is per financial year.**
  `get_next_invoice_number(p_fin_year integer DEFAULT NULL)` replaces the
  no-argument function (one signature; a call without an argument still
  works). It returns the highest number among that year's invoice rows plus
  1, and `1` for a year without invoices; numbers below 1 are ignored. A
  soft-deleted invoice (`deleted_at` set; written only with the service key or
  in the database) counts, because the unique constraint still reserves its
  number and a suggestion that ignored it could never be saved; an invoice
  removed with `delete_invoice` frees its number. Without a year it uses the
  financial year of today in India. Before,
  it returned the highest number of all years plus 1, so April continued the
  old year's numbers. An invoice numbered 2147483647 no longer breaks the
  suggestion for every year with "integer out of range": only that year is
  refused, with `No invoice number is left in financial year <year>`
  (`WH409`). Guard and grants are unchanged. `docs/INVOICE_RULES.md`, "Invoice
  numbers"; `tests/invoice_number_per_year.sql`.
- **A zero storage charge needs a reason from staff.** The three invoice save
  RPCs read `zero_charge_reason` from the invoice data. While a line of the
  invoice has a charge of 0, staff must send a reason that is not blank, on a
  new invoice and on every edit; administrators and supervisors may leave it
  empty; with no zero-charge line the reason is stored as NULL. The refusal is
  `Enter a reason for the zero charge` (SQLSTATE 22023, same shape as the
  discount-reason refusal). The invoice records `zero_charge_reason`,
  `zero_charge_set_by` and `zero_charge_set_at` when the reason or the set of
  zero-charge lines changes, and each change is appended to the new
  `invoice_zero_charge_history` (read by administrators and supervisors,
  changed by nobody, kept when the invoice is deleted). `get_invoice_detail`
  returns the three fields and `zero_charge_set_by_name` to administrators,
  supervisors and staff. Charges outside 0 to 999999 and a zero duration are
  refused as before. **Consequence for existing data:** nothing is checked or
  changed by the migration; an invoice that already has a zero-charge line and
  no reason can be read and can be edited by an administrator or supervisor as
  it is, and staff who edit it must enter a reason at that edit. **For API
  clients:** staff must send the reason on every save. For an administrator or
  supervisor a request that has the `zero_charge_reason` key states the reason
  (`null` or a blank value clears a stored one, which is recorded), and a
  request without the key keeps the stored reason, so an edit from an older
  app build does not erase what staff entered.
  `docs/INVOICE_RULES.md`; `tests/zero_charge_reason.sql`.
- **A customer account can no longer read the internal reasons from the
  `invoice` table.** `get_invoice_detail` kept `discount_reason`,
  `discount_set_by`, `discount_set_at` (migration 30) and the three
  `zero_charge_*` columns from a customer account, but a customer login could
  read all six for its own invoices with `GET /rest/v1/invoice`, because every
  app role is the one database role. Migration 48 replaces the app role's
  SELECT on `invoice` by a SELECT on every other column. **For API clients:**
  no app role, administrator included, reads those six columns from the table
  any more (use `get_invoice_detail`); a direct read of `invoice` must name its
  columns, and `select=*`, a missing `select` or an embedded `invoice(*)` is
  answered HTTP 403 `permission denied for table invoice`. The app does not
  read the table; the invoice PDF function now names its header columns
  (`functions/_shared/document-columns.ts`). A column a later migration adds to
  `invoice` is closed until that migration grants it, and
  `tests/security_baseline.sql` fails until it is either granted or listed as
  internal. `docs/INVOICE_RULES.md`, "Internal columns";
  `tests/invoice_column_grants.sql`, `tests/document-columns.test.mjs`.
- **The three histories keep the author's name.** `invoice_discount_history`
  (migration 41), `invoice_zero_charge_history` and `item_price_history`
  stored the author as a profile id and looked the name up when read, and any
  signed-in user can rename the own profile to "Deleted User" with
  `delete_user_account`, so the record of who changed a price or gave a
  discount could be emptied by the person it names. Each history row now
  stores `changed_by_name` beside `changed_by_role`, as they were at the
  change, and `get_item_price_history` (`changed_by_name`) and
  `get_invoice_detail` (`discount_set_by_name`, `zero_charge_set_by_name`)
  return the stored name; the profile's present name is used only for a row
  that has none. **Consequence for existing data:** discount history rows from
  before this migration get the name their author's profile has at the
  upgrade (an account already deleted reads "Deleted User"). **Consequence for
  account deletion:** a deleted account's name stays in these three records.
  `tests/zero_charge_reason.sql` (section 7), `tests/item_price_history.sql`
  (section 5), `tests/invoice_line_rules.sql`,
  `tests/history_author_backfill.sh`.
- **Every price change is recorded.** Staff have been able to create, change
  and delete item prices since migration 45, with nothing kept of what a price
  was or who changed it. A trigger on `item_storage_prices` now writes one row
  to the new append-only `item_price_history` for every insert, update and
  delete, whichever RPC made it: time, profile and role (from the session; none
  for a write with the service key or in the database), price, item and
  customer with their names, the action and the values before and after. New
  RPC `get_item_price_history(p_customer_id uuid DEFAULT NULL, p_item_id uuid
  DEFAULT NULL, p_limit integer DEFAULT 50, p_offset integer DEFAULT 0)`
  returns `{success, data, pagination}`, newest first, to administrators and
  supervisors; staff and customer accounts are refused and cannot read the
  table either. A `TRUNCATE` of the price table (service key or database
  owner only) is recorded as one row with the action `truncate` and the number
  of prices removed, and is listed under every customer and item filter. A
  page is 1 to 200 rows; an offset past the end is an empty page. The record
  starts with this migration. No app screen yet.
  `docs/STAFF_GRN_POLICY.md`, "Every price change is recorded";
  `tests/item_price_history.sql`.
- **The REST request limit is 1800 a minute per client address, with no hourly
  window** (was 300 a minute and 6000 an hour). All phones of a facility share
  one public address and so one counter: the old limit gave 100 phones 3
  requests a minute and 60 an hour each, and once the hour was used up every
  phone was refused until it ended. The new one gives them 18 a minute each
  and cannot lock anyone out for longer than the rest of a minute. It is
  1800 per fixed minute, about 30 a second on average, with no per-second
  brake: one address may use a minute's budget in a burst.
  **Consequence:** this is also the only gateway brake on the RPCs that need
  no sign-in (`refresh_jwt_token`, `logout_session`, `check_session`); one
  address may now send 108,000 requests an hour where it could send 6000. The
  OTP limits are unaffected. The other routes are unchanged. **The functions
  route was left with its hourly cap** (100 a minute, 2000 an hour per
  address): it has the same hourly lock-out for a facility behind one address,
  but it is also the gateway's per-address brake on OTP requests, so it is
  left for the owner to decide.
  `docs/CONTAINER_SECURITY.md`, "REST request limit", has the arithmetic and a
  table of every route; `tests/gateway-config.test.mjs` pins both. Kong has
  not loaded the file on a running stack.

- **A restore that loses a history no longer compares as identical.**
  `scripts/data-fingerprint.sh` now fingerprints `invoice_discount_history`,
  `invoice_zero_charge_history` and `item_price_history` with the business
  tables, and `scripts/backup-integrity.sql` (the report `verify-restore.sh`
  and `restore.sh` compare) counts the three tables and records the column
  grant on `invoice`. **Operator note:** a fingerprint file taken before this
  upgrade has three lines fewer; take a new one after upgrading. Backups taken
  before migration 48 still verify and restore: the new report lines are
  printed only for a database that has migration 48.
  `tests/verify-restore-drill.sh` (the report with and without migration 48; a
  backup that recorded more history rows than its dump holds is refused),
  `tests/history-backup-coverage.test.mjs`.

New and changed answers: `get_next_invoice_number` takes `p_fin_year`, counts
soft-deleted invoices of the year and can raise `No invoice number is left in
financial year <year>` (`WH409`); `save_invoice` (both signatures) and
`update_invoice` read `zero_charge_reason` and can refuse with `Enter a reason
for the zero charge` (22023), and for an administrator or supervisor an edit
without that key keeps the stored reason; `get_invoice_detail` adds
`zero_charge_reason`, `zero_charge_set_by`, `zero_charge_set_by_name` and
`zero_charge_set_at` for the warehouse roles, and its `discount_set_by_name`
and `zero_charge_set_by_name` are the names stored at the change;
`get_item_price_history` is new (its `action` can be `truncate`, with
`price_id` null); `GET /rest/v1/invoice` must name its columns and cannot
name the six internal ones.

## Unreleased — follow-ups to the review of migrations 39 to 46 (2026-10-11)

Migration 47. **Operator action:** rerun `setup.sh` as for every upgrade (it
applies the migration and the storage policies); read the new OTP limits in
`docs/OPERATOR_INSTALL.md`, "Authentication and OTP limits".

- **OTP limits rebalanced.** The lanes of migration 44 kept a known phone from
  being locked out, but one address could still hold the phone's single
  "slow lane" slot, a known phone could be sent about 116 SMS a day (20
  before), and a code could be tried ten times (5 before). Now, in this order
  of priority: a code can be tried wrongly **5 times in all** (other sources
  than the requester share 2 of the 5, so the requester keeps at least 3); one
  phone is sent at most **30 codes in any 24 hours** (`otp_phone_daily_cap`);
  and inside those bounds sources that have signed in for the phone keep **10
  of the 30** for themselves (`otp_trusted_daily_reserve`), so sources that
  have not share 20 a day and 5 an hour. The slow lane is gone: a used-up
  limit answers 429 "Too many OTP requests. Try again later."; only the 60 s
  resend cooldown still answers "Please wait before requesting another OTP."
  with `retry_after_seconds`.
  **Consequence:** while someone keeps requesting codes for a user's number,
  that user can still sign in from a network they have used before, but may
  get no code from a brand-new network until the requests stop or the operator
  runs `SELECT warehouse_security.reset_otp_limits('<mobile>')` (new; steps in
  the same section, with the Cloudflare WAF rule).
- **`get_supervisors` no longer gives staff every colleague's mobile number.**
  Each row is `id`, `name`, `display_name`, `role`; `phone` is added for
  administrators and supervisors only. The app picks by name and does not
  show the number.
- **A supervisor can no longer re-approve a rejected access request.**
  `update_user_status` and `update_user_role` refuse a supervisor when the
  target's access request is not approved (`ENROLLMENT_NOT_APPROVED`). A
  supervisor still deactivates a user; **giving access back is now an
  administrator's action**, also for a user the supervisor deactivated.
  `update_user_role` refuses, for every caller, to change the role of a
  pending request (`ENROLLMENT_PENDING`), which made it unreviewable.
- **Staff can remove only the photo files of live documents.** The storage
  policies of migration 45 let staff read and delete every file no image row
  names, which included all photos of deleted receipts and dispatches. They
  now cover such a file only inside the folder of a receipt or dispatch that
  is not deleted. The migration applies the rule at once;
  `scripts/configure-storage.sql` (run by `setup.sh`) names the new helper.
- **`update_grn` takes an optional `p_idempotency_key`.** The same key from
  the same user for the same receipt within 24 hours returns the stored answer
  with `"idempotent": true` and changes nothing. Without the key nothing
  changes for the current app build. A repeated save without a key did not
  duplicate an added line, as the review had it: it removed the line and added
  it again under a new id; the key keeps the first row.
- **Two-session tests** (`tests/concurrent_rules.sh`, run by
  `tests/migrations.sh`): two administrators deactivating and demoting each
  other, and two users invoicing one receipt. These rules were asserted
  before only by the function's source text or by two calls in one session.
- **Upgrade note for installations with tables of their own.** Migration 42
  stops when `public` holds a table of the operator's that `authenticated`
  may write. The migration is not changed (applied migrations are
  checksum-locked); `docs/OPERATOR_INSTALL.md`, "Rerun and upgrade", now has
  the two queries to run before upgrading and what to do with a hit.
- **Record corrected** (`docs/STAFF_GRN_POLICY.md`, "Still open from the first
  review"): a receipt still stores the client's `sender_name`,
  `supervisor_name` and any date; and a role change still leaves the old
  `user_role` claim in the access token until it is renewed, which only an
  app that reads the claim would notice.

Changed answers: `operator_prepare_otp` no longer answers `resend_cooldown`
with a 15 minute `retry_at`; `get_supervisors` rows gain `display_name` and
`role` and lose `phone` for staff; `update_user_status` / `update_user_role`
gain the errors `ENROLLMENT_NOT_APPROVED` and `ENROLLMENT_PENDING`;
`update_grn` gains `p_idempotency_key` and, on a replay, `"idempotent": true`.

## Unreleased — backup, restore and gateway follow-ups from the infrastructure review (2026-10-11)

No migration. Operator actions are named in each item.

- **A lost-host restore is no longer stopped by monitoring or print-spool
  volumes.** `db:restore-host` refused any left-over `<project>_*` Docker
  volume, so a host that had run the monitoring profile (and the CI lost-host
  drill itself) was refused and told to delete metric history. It now refuses
  only `<project>_db-config`, the one named volume of the services whose data
  a restore replaces, and reports the others as kept.
  `tests/restore-host.test.mjs` compares that list with the Compose files.
- **`db:restore-host` no longer unpacks an archive that has no signature
  file.** A `.tar` without its `.hmac` was unpacked next to the new state
  before anything in it had been checked against the backup key. It is now
  refused unless `--allow-unsigned` is given (the signed backup inside is
  still checked). **Operator action:** copy the `.hmac` file from the drive
  together with the `.tar` and its `.sha256`. The restore section of
  `docs/OPERATOR_INSTALL.md` now states the real order of the checks.
- **A backup's signature is checked before its checksum list is used.**
  `sha256sum -c SHA256SUMS` ran first, on a list nobody had vouched for, and
  opens whatever path a line names (a file outside the backup, a device that
  never ends). The signature over the list is now checked first; the checksums
  run after it. For a backup accepted with `--allow-unsigned` the list is
  refused when a line names an absolute path or one with `..`, or when the
  backup contains a link.
- **Restore verification no longer unpacks the stored files.**
  `db:verify-restore` (and so every USB run and every `db:restore`) extracted
  the whole storage archive into `/tmp` and never read it, so a facility with
  more photos than free space on the root filesystem could not verify a backup,
  or filled the disk under the running stack. The archive is now only listed.
- **The storage-archive safety checks read the whole listing.** With an early
  link or `..` path in a long listing, the check stopped reading, the lister
  was killed by the closed pipe, and under `pipefail` the answer became "safe".
  This mattered for backups accepted with `--allow-unsigned`. The check now
  also refuses device and other special entries, not only links.
- **Running USB setup again no longer switches encryption or the daily timer
  off.** The documented upgrade step is `backup-usb.sh setup --state DIR` with
  no other option, and that rewrote the configuration with encryption off and
  disabled the timer, so later archives were plain `.tar` files holding every
  credential. A setup run now keeps the stored choices; `--no-encrypt`,
  `--no-daily` and `--fresh-backup` change them. **Operator action:** if an
  earlier setup rerun switched your daily timer off, run setup once with
  `--daily`; setup prints the choices in effect.
- **A USB drive enrolled by the previous release shows up as a failed backup
  at once.** Such a drive is refused before the backup run starts, so nothing
  was recorded and `status` and `doctor` kept showing the last success for
  seven days while no backup reached the drive. The refusal is now recorded as
  a failed run with the `enroll` command, both when the drive is attached and
  when setup finds its old line.
- **The USB run opens only archives it can prove are its own.** A later-dated
  `.tar` with a matching checksum and no signature became "the newest backup",
  was unpacked into the state directory and replaced the genuine newest backup
  in the restore check. Such a file is now reported and never opened, and the
  newest signed archive is verified as before.
- **An archive signed with a replaced backup key is named as that**, apart from
  a damaged archive, and the key-replacement steps in
  `docs/OPERATOR_INSTALL.md` now say to move the older archives aside on the
  drive; without that every later run ended as failed.
- **The backup key is created atomically.** An interrupted setup could leave
  an empty `config/backup.key` that every later command accepted as present
  and then rejected. Setup now writes the key to a temporary file and links it
  into place, replaces an empty key file, and refuses, without touching it, a
  key file whose content is not a key.
- **The Realtime socket limit can no longer lock a facility out.** The limit
  added on this branch (300 a minute, 6000 an hour per client address) counts
  failed connection attempts, and every phone of a facility shares one
  address: during a Realtime outage 50 phones used the hourly budget in 20
  minutes and were then refused until the hour ended. The socket route now has
  1800 attempts a minute and no hourly window, sized for 100 phones
  (arithmetic in `docs/CONTAINER_SECURITY.md`, "Realtime socket limit").
- **CI runs `retention:apply` against the real Storage API.** The removal of
  expired generated PDFs had only met a stand-in server, and CI ran the
  preview. The operator-install job now ages one generated PDF in SQL, runs
  `retention:apply` as its last step and requires the catalog row and the
  stored file to be gone. The step was written without a running stack; its
  first CI run is the check of the Storage API call.

## Unreleased — one lock order for document writes; stricter document input (2026-10-11)

Migration 46. No role gains or loses a function; nothing needs an operator's
action. Details in `docs/STAFF_GRN_POLICY.md`, "One lock order and stricter
document input".

- **Saving a dispatch no longer deadlocks with an edit of the same receipt.**
  A receipt edit takes the list-refresh lock and then its rows; creating,
  editing or deleting a dispatch locked the rows first and the refresh lock
  afterwards, so the two could wait for each other and one of them failed with
  "deadlock detected" (the edit of a dispatch or receipt was never retried).
  Every function that writes a customer, receipt or dispatch now takes the
  refresh lock before it locks a row. `tests/grn_edit_lock_order.sh` runs the
  dispatch-against-receipt-edit case with two sessions; without the migration
  it ends in the deadlock.
- **Receipt and dispatch input the app already refuses is refused by the
  server too:** a receipt line with quantity 0 or less or a negative weight; a
  dispatch edit with quantity 0, a fractional quantity or a lot that does not
  exist (such a line used to be stored, or silently dropped); a receipt or
  dispatch number made of tabs, no-break spaces or other invisible characters.
  A blank dispatch number at creation is now the validation error
  `disp_no is required`, not a database error.
- **A receipt carries the customer record's name.** `save_grn` stored whatever
  name the client sent next to the customer id, and every list shows and
  searches that name. The name now comes from the customer record at creation
  and when a receipt moves to another customer.
- **An idempotency key answers only its own function and user.** Dispatch
  creation answered with whatever any function or user had stored under the
  key, and `save_grn` with another user's receipt. A dispatch key is also kept
  for the 24 hours it is honoured; it used to expire, and be removed by
  retention, after one hour.
- **The Package, Rack, Item, Customer and Receipt-number filters of the receipt
  lists are literal.** `%` and `_` were wildcards there (typing `PKG_50` also
  found `PKG-50`), and a trailing `\` matched nothing.
- **Deleting a receipt leaves a trace in the order history** of every cart that
  lost a line (`grn_deleted`, the lines at quantity 0).
- `delete_dispatch_with_order_cleanup` checks for administrator or supervisor in
  its own body as well as in the guard. Four internal dispatch functions that
  nothing called are dropped.
- **Edge functions no longer accept the service key as a user.** A request
  carrying the service key was treated as an administrator by every function
  behind sign-in. The router and `validateUserAccess` now accept a signed-in
  user's token only; nothing in this repository called a function with the
  service key.
- Tests that could not fail were rewritten: the list tests now read the order
  and the pages the list functions return (they sorted the result themselves),
  the customer refusals expect the refusal (any outcome passed, and the list of
  "other customers" was read through the customer's own row filter), and the
  language test covers a disabled profile. New assertions: retention cannot be
  run by an API role, a customer account cannot write to the image buckets,
  receipt lists filter by moment, and Gujarati or full-width digits in a number
  sort after ordinary ones.
- `MOBILE_REF` in CI is still the app commit of 2026-10-08 (51 commits behind
  the app head reviewed on 2026-10-10); a test now refuses anything but a full
  commit there, and `docs/RELEASE_CHECKLIST.md` starts with the step that moves
  it and runs the live contract comparison.

## Unreleased — container networks, function environment and pinned dependencies (2026-10-11)

None of the changes in this entry has run on a started stack yet; each was
checked with the unit tests and `docker compose config` named in
`docs/CONTAINER_SECURITY.md`, "Changes awaiting a first run". The
`operator-install` CI job is their first run on real containers.

- **Containers are on three networks instead of one.** postgres-meta runs any
  SQL as the database superuser for whoever can connect to it, and Studio
  forwards SQL to it without a login; both were reachable from every
  container. They are now on an `admin` network with the database only. The
  database is on a `database` network with the services that connect to it;
  Kong, the function runtime, Gotenberg, imgproxy, CUPS and Prometheus can no
  longer open a connection to it. `health-check.sh` and
  `scripts/gateway-dns-check.sh` probe the gateway from the `storage`
  container, because Studio is no longer on the gateway's network; for the
  same reason Studio's panels that call the gateway do not work.
  `tests/compose-networks.test.mjs` renders the Compose configuration and
  asserts which services share a network and that each service still reaches
  every host it is configured to call. See `docs/ARCHITECTURE.md` and
  `docs/CONTAINER_SECURITY.md`, "Network boundaries".
- **The API alert rules can fire.** They queried Kong 2 metric names and the
  gateway's Prometheus plugin was loaded but never enabled, so there were no
  request metrics at all. `docker/kong.yml` enables the plugin with status-code
  and latency metrics, the two rules use `kong_http_requests_total` and
  `kong_request_latency_ms_bucket`, and `npm run test:monitoring` fails when
  Prometheus holds no gateway request series. New rules: any scrape target
  down, and low space on a second disk. There is still no backup-age rule,
  because nothing exports a backup metric (`docs/MONITORING.md`). Prometheus
  no longer accepts shutdown and reload requests over HTTP.
- **GraphQL and Realtime routes are rate-limited** per client address like the
  REST route (300 a minute, 6000 an hour); the Realtime HTTP route has a 2 MB
  body limit. The storage route is unchanged.
- **A function's worker receives only the variables it reads.** The router
  copied the whole container environment into every worker, so the three
  functions that take no token (`hello`, `get-public-config`, `operator-otp`)
  held the token-signing secret. `functions/main/worker-env.ts` now lists the
  names per function and `tests/worker-env.test.mjs` compares each list with
  the `Deno.env.get()` calls the function and its shared modules make.
  `SUPABASE_DB_URL`, a superuser database address that no function read, is
  removed from the functions container.
- **Edge function modules are pinned in one list.** Five imports of `npm:ipp`
  had no version, supabase-js was imported at two versions, and
  `functions/import_map.json` listed versions that no file imported. Every
  remote import is now an exact version listed in the import map
  (`tests/edge-imports.test.mjs`); the functions that run keep the versions
  they had. The unit tests verify tokens with jose 5.10.0, the release the
  runtime loads, instead of jose 6. There is still no `deno.lock`; the steps
  are in `docs/CONTAINER_SECURITY.md`, "Edge function modules".
- **Kong is pinned by digest.** PostgREST v16.4 is still referenced by tag
  (`docs/CONTAINER_SECURITY.md`, "Image pins"). `THIRD_PARTY_NOTICES.md` and
  `docs/ATTRIBUTION_REVIEW.md` now name PostgREST v16.4 and edge-runtime
  v1.77.4, and a test fails when they drift from Compose and the Dockerfiles.
- The quantity-in-words fallback of the two pre-printed slip functions threw
  for 1,01,000 and above (it assigned to a constant). The functions are still
  refused with 503 by the router; `tests/print-number-words.test.mjs` runs the
  fallback.
- Every service's container log is capped at three 10 MB files; ten services
  had no cap. imgproxy mounts the stored files read-only. The pooler no longer
  registers a `pgbouncer_reporting` user that no database role backed, and
  `POOLER_REPORTING_POOL_SIZE` is gone from `.env.example`.
- The Studio and CUPS recipes apply their distribution's package updates at
  build time, as the other recipes do. Studio's Next.js and simple-git
  advisories are in the application and remain
  (`docs/CONTAINER_SECURITY.md`, "Open items with their steps").
- GitHub Actions steps name a commit (`actions/checkout` v7.0.1,
  `actions/setup-node` v6.5.0) instead of a movable major tag.

## Unreleased — signed backups, a restore verifier that does not flake or run out of room (2026-10-11)

**Operators must act after this upgrade** (details in `docs/OPERATOR_INSTALL.md`,
"Rerun and upgrade" and "Backup key"):

1. `setup.sh` (or the first `db:backup`) creates `config/backup.key` in the
   state. Copy it somewhere away from the server and from the backup drive. A
   lost-host restore refuses without it.
2. Take a new backup. Backups are now format `warehouse-backup-v5` and signed;
   older ones are accepted by `db:verify-restore`, `db:restore` and
   `db:restore-host` only with `--allow-unsigned`.
3. Enroll every USB backup drive again
   (`sudo bash scripts/backup-usb.sh enroll --device /dev/sdX1`, after running
   its `setup` again). A drive enrolled by an earlier release receives nothing
   until then.
4. `npm run db:restore-host` now takes `--backup-key FILE`.

- **Backups are signed.** `SHA256SUMS.hmac` is an HMAC-SHA256 of `SHA256SUMS`
  under the backup key. The verifier, the in-place restore and the lost-host
  restore check it, and that the backup holds exactly the listed files, before
  they read anything else. Until now a backup was trusted on plain checksums
  that anyone with the drive could regenerate, and a restore replays the dump
  as the database superuser and adopts the backup's `compose.env`. A wrong
  signature is refused even with `--allow-unsigned`.
- **A USB drive is enrolled by a signed marker, not by its volume serial.**
  The 32-bit exFAT serial was the only check and stood in two world-readable
  files, so a stick formatted with that serial received every credential.
  `enroll` now writes `warehouse-backups/.drive-enrolment`, an HMAC over the
  filesystem UUID, the partition UUID and the instance id; `run` takes no
  backup and copies nothing unless it verifies. The enrolment list is mode
  0600 and binds both UUIDs.
- **USB archives can be encrypted** (`backup-usb.sh setup --encrypt`, or
  `WAREHOUSE_BACKUP_ENCRYPT=1` for `run`): AES-256-CTR with a key derived from
  the backup key, written as `.tar.enc` with a signed checksum.
  `db:restore-host` opens such an archive with `--backup-key`. This is **off by
  default**: a lost key makes the archives unrecoverable, and the encrypted
  path is covered by tests with real encryption but a simulated database, not
  yet by a restore drill on real containers. Backup-disk copies are not
  encrypted. Archives are signed (`.tar.hmac`) in both modes.
- **The restore verifier no longer fails at random.** It created its databases
  from `template1` the moment the server answered, and a start-up session
  attached to `template1` made `createdb` fail (CI, 2026-10-09). It and
  `db:restore` now use `template0`. `tests/migrations.sh` ends with a drill on
  real containers that holds a session on `template1` while the verifier runs.
- **The restore verifier grows with the database.** It was fixed at 1 GiB of
  memory and a 768 MiB data directory, and `db:restore` requires it, so a
  database past that size could no longer be restored. The data directory is
  now sized from the dumps, placed in memory when it fits and otherwise in a
  temporary directory under the state, with a free-space check and a message
  that names the numbers. `WAREHOUSE_VERIFY_DATA_MB`, `_SIZE_FACTOR`,
  `_STORAGE`, `_SCRATCH_DIR` and `_MEMORY_MB` override it.
- A failed verification keeps the container log, its state and the database
  sessions under `diagnostics/` in the state before the container is removed.
- The verifier and the migration test run the database image by the digest the
  production image is built from; `metadata.txt` records it, and records
  `source_commit=unknown` instead of an empty value outside a git checkout.
- `db:restore-host` refuses a host that still has a Docker volume of the
  project (`<project>_db-config` would give the restored database the old
  cluster's configuration and key material).
- `test:pooler`, `test:monitoring`, `test:cups` and a stand-alone
  `scripts/migrate.sh` take the operator lock, so they cannot start or build
  services while a backup or restore is running.
- CI checks the syntax of every tracked shell script, including the two that
  run inside images.
- `.env.example` and the generated `compose.env` no longer carry variables
  nothing reads (four Logflare tokens, the Google sign-in block,
  `DOCKER_SOCKET_LOCATION`, `ENABLE_PROM_METRICS`,
  `POOLER_PROXY_PORT_TRANSACTION`). Existing installations keep their lines;
  they are harmless.
- Documentation: which secrets `rotate-keys.sh` does not change and what to do
  about each (`docs/OPERATOR_INSTALL.md`, "Secrets that rotate-keys does not
  change"). There is still no rotation for `POSTGRES_PASSWORD`,
  `SECRET_KEY_BASE` and `VAULT_ENC_KEY`. `docs/TELEMETRY_AND_PRIVACY.md` now
  says what a Sentry event still contains with `sendDefaultPii: false`.

## Unreleased — the server admits what the app offers to each role (2026-10-11)

Owner decision: where the app shows a screen to a role and the server refused
its RPCs, the server allowlist is widened so the screen works. Migration 45;
the full list and the role table are in `docs/STAFF_GRN_POLICY.md`, "The server
admits what the app offers".

- **Staff can now read and change item prices** (`get_item_storage_prices`,
  `create_`, `update_`, `delete_` and `find_or_create_item_storage_price`).
  This supersedes the refusal of migration 23. A price change is not written to
  a history table. (It is since migration 48: see "owner decisions of
  2026-10-11" above.)
- Staff can run the reports the app shows them, for all customers and for one
  (`get_all_stock_summary`, `get_customer_stock_summary`,
  `get_all_customer_activity_summary`, `get_customer_activity_detail`,
  `get_customer_dispatch_activity`, `get_stock_aging_report`,
  `get_item_wise_stock_list`), and read sensors (`get_sensor_polling_data`,
  `get_sensor_history`). The operations dashboard stays with administrators and
  supervisors.
- Staff can remove a photo in the receipt and dispatch edit forms
  (`delete_grn_image`, `delete_dispatch_image`): a confirmed photo, or one the
  caller registered, of a document that is not deleted. They can then delete
  the file, but only a file that no image row names any more
  (`scripts/configure-storage.sql`, applied by a setup rerun).
- Staff get order changes live: a read policy on `orders`.
- Supervisors can change the role, the active status and the customer
  assignments of users who are not administrators. They cannot target an
  administrator or themselves and cannot grant the administrator role. The
  last-administrator rule of migration 44 is unchanged.
- **Customer accounts are not widened.** Every all-customers report, pricing
  and sensors stay refused, also for an account assigned to several customers.
  `get_stock_aging_report` and `get_item_wise_stock_list` are admitted for a
  customer account only with the id of an assigned customer.
- **Behaviour change:** `get_grn_details` and `get_dispatch_details` no longer
  give a customer account the supervisor's `mobile` and `role` in
  `supervisor_details`; the name stays. No owner decision was given; this is
  the privacy-safe default and can be reversed.
- `get_supervisors` lists active profiles only.
- `get_customer_dispatch_activity`, `get_customer_stock_summary`,
  `get_operations_dashboard` and `get_recent_dispatched_orders` read the
  caller's role from the profile, not from the token.
- `printer_status` can no longer be read with the public key; signed-in
  administrators, supervisors and staff read it. `feature_flags` stays public.
- `find_or_create_item_storage_price` refused every role under operator
  sign-in; fixed.
- Tests: new `tests/role_allowlist.sql` classifies every function the app role
  may execute and calls each one a customer account or staff may not use,
  expecting the guard's refusal, so a function granted later fails until it is
  classified. `tests/staff_dispatch_invoice_access.sql`,
  `tests/staff_grn_access.sql` and `tests/direct_write_guard.sql` were changed
  where they asserted the old pricing, photo and order-read refusals;
  `tests/security_baseline.sql` no longer allows an anonymous grant on
  `printer_status`.

## Unreleased — function router refuses the anon key; PDF footer escapes its values (2026-10-11)

- The function router answers 401 "User access token required" for every
  function except `hello`, `get-public-config` and `operator-otp` when the
  caller presents the public anon key. Each of those functions already refused
  it in its own code; the router check covers a function added later without
  one.
- `createFooterHtml` escapes the company name, document type and number. Its
  only caller passes fixed text, so no output changes.
- Tests: `tests/jwt.test.mjs`, new `tests/gotenberg-footer.test.mjs`.

## Unreleased — the auth and access test runs again (2026-10-11)

- `tests/auth_and_access.sql` was never run by `tests/migrations.sh` and used
  the demo sign-in that migration 15 turned off. It now signs in through the
  operator OTP flow and is registered. Its assertions held against the current
  schema; only the test was out of date. It is the only place that checks the
  list of functions an anonymous caller may run (now `refresh_jwt_token`,
  `logout_session`, `check_session`), that every materialized view is
  populated, and the GRN and dispatch number suggestions. It also checks the
  stock report RPCs for customer and administrator.
- `tests/security_baseline.sql` now also fails when a `SECURITY DEFINER`
  function an app role can call has no `search_path`, when a new one without
  `search_path` appears at all (the baseline has 48 that no app role can call),
  when an exposed table has RLS but no policy, or when an app role can reach
  the private schemas.

## Unreleased — the last administrator cannot be removed (2026-10-11)

- Migration 44: `delete_user_account` refuses the only active administrator
  (`{success:false, code:'LAST_ADMIN'}` with a sentence in `error` and
  `message`); `update_user_status` and `update_user_role` answer
  `error:'LAST_ADMIN'` when the change would leave no active administrator.
  Before, the only administrator could delete the own account and nothing
  short of editing the database could create another.
- Recovery: `setup.sh` and `warehouse_security.bootstrap_first_admin` now look
  for an approved, **active** administrator. When there is none, a setup rerun
  makes the profile with `--admin-phone` an administrator again, or creates
  one. See "The last administrator" in `docs/OPERATOR_INSTALL.md`.
- `operator_review_enrollment` refuses a caller with no active role by itself
  (it relied on the PostgREST session hook having refused first).
- Tests: new `tests/admin_guards.sql`.

## Unreleased — OTP limits a stranger cannot turn against a user (2026-10-11)

- Migration 44 changes the OTP limits; the table is in
  `docs/OPERATOR_INSTALL.md`, "Authentication and OTP limits". Before, anyone
  could keep a chosen phone (the only administrator's included) from signing
  in with five code requests an hour or five wrong guesses per code, and about
  ten addresses could use up the warehouse cap for everybody.
  - Wrong codes are counted on each issued code in two budgets of five: one for
    the address that requested the code, one shared by all other addresses.
    Each address is also limited to 20 failed verifications an hour.
  - A phone with an approved, active profile is no longer refused after 5
    requests an hour or 20 a day: it gets one code every 15 minutes instead,
    and 5 an hour from an address it has signed in from before, which other
    addresses cannot use up. Other phones keep the hard limit.
  - The 60 s resend cooldown is per phone and address.
  - Phones without an approved profile may use only `otp_unknown_hourly_cap`
    (default 60) of the warehouse cap (`otp_global_hourly_cap`, default 300).
  - A send MSG91 did not accept no longer counts against the phone or the
    warehouse cap.
  - New access requests are limited to 3 per address and
    `enrollment_daily_cap` (default 30) per day, and the name a new user types
    is checked (markup or links are replaced by "New customer").
- `operator_verify_otp` takes the caller's address as a fifth argument; the
  four-argument function is gone. Only the edge worker calls it.
- The edge function answers two new cases: verification from an address over
  its failure limit gets 429 "Too many OTP requests. Try again later.", and an
  access request over the limit gets 429 "Too many new access requests. Try
  again tomorrow.". A cooldown answer now carries `retry_after_seconds` and a
  `Retry-After` header.
- The edge function's request handling moved to
  `functions/operator-otp/handler.ts` so it can be tested.
- Tests: new `tests/otp_abuse_limits.sql` and
  `tests/operator-otp-handler.test.mjs` (mode gate, routing, CF-Connecting-IP
  checks, formats, status mapping, provider failure order).

## Unreleased — a replayed refresh token ends the session; a retried renewal does not (2026-10-11)

- Migration 44: `refresh_jwt_token` now tells a retry from reuse. A refresh
  token that was already replaced and is presented again within 60 seconds
  (`refresh_grace_seconds` in `warehouse_security.auth_config`, 0 to 300) gets
  the same successor again with a newly signed access token, so an app whose
  first answer was lost on a slow network is not signed out. Presented later,
  or when it is two generations old, it is reuse: the session is deleted, the
  token that was current stops working and the database log carries
  `Refresh token reuse: session ... revoked`. Before, the replay was refused
  but a session held by whoever had rotated the stolen token stayed alive for
  up to 7 days.
- The answer shape is unchanged: `{success, access_token, refresh_token,
  expires_at, expires_in, token_type}` or `{success:false, message:'Invalid
  refresh token'}`.
- The table still stores hashes only. The successor is kept encrypted under a
  key derived from the replaced token, so it can be returned only to a caller
  who presents that token.
- Tests: new `tests/refresh_reuse.sql` (rotation, retry inside the grace
  period, replay after it, old generations, logout with a pre-rotation token,
  forged and expired tokens); `tests/operator_auth.sql` and the CI drill
  `tests/operator-api-core.mjs` now expect the retry answer. The drill was not
  run against a live stack in this change.

## Unreleased — printer status check validates the printer name (2026-10-10)

- `get-printer-status` (still answered with 503 by the function router until
  printing is configured) accepts only a CUPS queue name
  (`[a-zA-Z0-9_-]`, 1 to 127 characters) as `printer_name`, as `print-via-ipp`
  does; before, the value went into the CUPS URL path unchecked. An error that
  is neither "cannot connect" nor "printer not found" is answered as
  `Printer status unavailable`; the detail stays in the server log.
- Tests: new `tests/printer-name.test.mjs`.

## Unreleased — generated PDFs expire (2026-10-10)

- Every `generate-*-pdf` request stores a new file in the private `documents`
  bucket and nothing removed it, so the bucket grew with every request.
  `npm run retention:apply` now also removes generated PDFs older than the new
  `generated_documents` retention policy (7 days by default; the download link
  lives one hour). `npm run retention:preview` prints how many it would remove.
- Migration 43 adds the policy row and
  `warehouse_maintenance.expired_generated_documents()`, which names the
  expired files. `scripts/retention.sh` deletes them through the Storage API
  from inside the storage container (`scripts/remove-expired-documents.cjs`),
  because deleting the `storage.objects` row alone leaves the file on disk,
  then checks that none remain. Only names the PDF functions produce
  (`<kind>/<document id>/<uuid>.pdf`) are removed.
- **Action for operators:** retention is still a command you run; schedule
  `npm run retention:apply` (for example daily, with the backups). See
  `docs/PDF_GENERATION.md`.
- Tests: `tests/retention.sql` (which files are named),
  new `tests/retention-documents.test.mjs` (the Storage API call and the
  command's preview/apply steps, against stand-ins). The deletion was not run
  against a live Storage container in this change.

## Unreleased — an image is confirmed only for a file in its own document's folder (2026-10-10)

- Migration 43: `upload_grn_image` and the `p_images` lists of `save_grn` and
  `update_grn` no longer write a confirmed image row for any path the caller
  sends. A path is accepted only if it lies in that document's folder
  (`headers/<grn id>/`, `items/<grn id>/`, `<dispatch id>/`), a file with that
  name is in the bucket, no other image row carries it, and an item photo's
  line belongs to the receipt. Before, one staff call could attach customer A's
  photo to customer B's receipt, which let B download it, or leave a confirmed
  row with no file.
- `confirm_grn_image_upload` and `confirm_dispatch_image_upload` answer
  `IMAGE_NOT_VERIFIED` until the file is uploaded to the registered path.
  `register_grn_image_upload` refuses a line of another receipt
  (`ITEM_NOT_IN_GRN`). `update_grn` no longer re-links an image of another
  receipt named by id. Dispatch photo paths carry a random part instead of a
  timestamp. `upload_dispatch_image` gets the same checks and the RPC guard.
- An image row inserted without a status is `pending`. Customers read confirmed
  image rows only; a pending row and its upload token are no longer visible to
  the document's customer.
- The app's flow is unchanged: register, upload to the issued path, confirm;
  `update_grn` still answers `item_mapping` and `grn.images`.
- **Action for operators:** existing rows are not changed. If the migration
  warns about rows outside their document's folder, list them with
  `SELECT * FROM warehouse_maintenance.misplaced_image_paths();` and delete the
  ones that should not be there. See `docs/STAFF_GRN_POLICY.md`.
- Tests: new `tests/image_path_rules.sql`.

## Unreleased — business tables are written only through the guarded RPCs (2026-10-10)

- Migration 42: administrators and supervisors can no longer insert, update or
  delete rows of the business tables with a direct table call
  (`/rest/v1/<table>`); the request answers HTTP 403. Before, one such call
  could set an invoice total, a line rate, a discount or a lot's stock, or
  delete dispatch lines, without the server totals, rate limits, stock checks
  and dependency checks the RPCs apply. Reads are unchanged for every role.
  The tables: `customers`, `items`, `item_storage_prices`, `goodsreceived`,
  `goodsreceived_trl`, `dispatch`, `dispatch_trl`, `invoice`, `invoice_trl`,
  `payments`, `orders`, `order_items`, `grn_images`, `dispatch_images`,
  `stock_movements`, `print_jobs`, `sensor_devices`, `sensor_readings`,
  `sensor_health_events`.
- **Action for API clients:** anything that wrote these tables directly with an
  administrator or supervisor session must call the RPC instead
  (`safe_delete_customer` / `restore_customer` / `update_customer`,
  `update_invoice`, `update_grn`, `update_dispatch_smart`, the `delete_*` RPCs).
  Edge functions using the service key, operator scripts and Studio are not
  affected.
- Migration 42: `update_order_metadata(p_order_id, p_note, p_priority,
  p_requested_dispatch_date)` is granted to signed-in users. Administrators and
  supervisors only; each change is written to the order history. It replaces a
  direct update of an order's note.
- The own-profile grant `UPDATE(name, display_name)` on `user_profiles` is
  unchanged.
- Tests: new `tests/direct_write_guard.sql`. `tests/staff_grn_access.sql`,
  `tests/staff_dispatch_invoice_access.sql` and `tests/order_screen.sql` now
  expect a refusal where a direct write used to match no row. The HTTP drivers
  `tests/operator-api-core.mjs`, `tests/operator-realtime-core.mjs` and
  `tests/review-core.mjs` use the RPCs instead of direct writes.

## Unreleased — invoice line rules: rate ranges, one invoice per dispatch line, India dates, discount history (2026-10-10)

- Migration 41: `save_invoice` (both signatures) and `update_invoice` refuse a
  line whose `charge` or `labour_rate` is outside 0 to 999999 or whose `tax` is
  outside 0 to 100 (`Invoice line charge must be between 0 and 999999`,
  `Invoice line labour rate must be between 0 and 999999`, `Invoice line tax must
  be between 0 and 100`). Zero rates are still accepted and a negative discount
  is still a surcharge. Before, a negative labour rate or tax could bring an
  invoice to nothing without a discount reason.
- Migration 41: a dispatch line is invoiced once. A save for a receipt already
  marked invoiced is refused (`GRN is already invoiced`, code `WH409`), as is a
  line that is on another invoice (`A dispatch line is already on another
  invoice`). `update_invoice` cannot move an invoice onto an invoiced receipt.
  Before, a second save under a new invoice number billed the same lines twice.
  After `delete_invoice` the receipt can be invoiced again.
- Migration 41: billable days are counted between calendar dates in India
  (`Asia/Kolkata`) in the preview and all save paths, not in the database
  session's time zone. **Amounts change** for a receipt whose stored time falls
  between 18:30 and 24:00 UTC (00:00 to 05:30 in India): it loses the extra day
  it was given, which mattered at the 30/45/60-day steps. Saved invoices are not
  recalculated; an invoice edited after the upgrade gets the corrected days.
- Migration 41: every discount change is appended to the new
  `invoice_discount_history` table (old and new discount, reason, profile, role,
  time). It cannot be updated or deleted, administrators and supervisors read
  it, and it stays when the invoice is deleted. A discount reason made only of
  white space or invisible characters is treated as empty for staff.
- Migration 41: `get_invoice_detail` returns `discount_reason`,
  `discount_set_by`, `discount_set_by_name` and `discount_set_at` to
  administrators, supervisors and staff (not to customer accounts).
  `get_invoice_items_detailed` computes line tax and total as the header does;
  a one-time line no longer includes duration and labour.
- Migration 41: `delete_invoice` refuses an invoice that payments refer to
  (`Cannot delete an invoice that has payments`).
- Existing invoices are not validated or changed. Applying the migration prints
  a warning with the number of dispatch lines that are already on more than one
  invoice, if any.

## Unreleased — a line can be added to an existing receipt (2026-10-10)

- Migration 40: `update_grn` saves a line that has no `id` as a new line of the
  receipt, with its whole quantity in stock, and reports it in `item_mapping`.
  Before, every edit that added a line failed with `column "pricing_mode" of
  relation "goodsreceived_trl" does not exist` and saved nothing: the insert named
  a column the line table does not have. The pricing mode stays on the receipt
  header (`p_pricing_mode`); a `pricing_mode` sent on a line is ignored.
- No request or response changes. A photo attached to a line added during an
  edit still needs the app to send the new line's id (`item_mapping`).

## Unreleased — a dispatch carries only its own customer's lots (2026-10-10)

- Migration 39: `create_dispatch_with_stock_check` and `update_dispatch_smart`
  refuse a line whose receipt belongs to another customer than the dispatch
  (`Item belongs to another customer: <item> (<receipt>)`, code `WH409`), for
  every role. `update_dispatch_smart` also refuses a change of the dispatch
  customer unless every line the edit leaves belongs to the new customer
  (`Cannot change the dispatch customer: items belong to another customer: ...`).
  Before, a dispatch for one customer could take another customer's stock and
  show that customer's receipt details to the first.
- Migration 39: `update_grn` refuses a change of the receipt's customer once the
  receipt has dispatch lines, an invoice or a line in an open cart (error
  `Cannot change the customer of a GRN that has dispatches, invoices or order
  items`). Sending the present customer again is still an ordinary edit.
- Existing records are not validated or changed. Applying the migration prints a
  warning with the number of dispatch lines that already mix customers, if any;
  such a dispatch can still be edited, but no further foreign line can be added.

## Unreleased — receipts sort by number in every accepted form (2026-10-10)

- Migration 31: `get_all_grn_items` and `get_grn_list` sort by receipt number with
  one key for every form `gr_no` accepts. One-letter prefixes keep their order
  (X, Y, Z, then A onward); numbers compare as numbers at any length, so A10000
  follows A9999; other forms (two-letter prefixes, digits only, separators) sort
  by prefix and then number. Before, every form other than a letter plus digits
  came back in ascending text order whichever direction was requested, and
  five-digit numbers collided with the next letter. No request or response changes.
- Migration 32: `get_customer_grn_items` sorts by number with the same key, so
  customer accounts and warehouse roles see one order (it compared numbers as
  plain text: B10 before B9).
- Migration 33: `get_dispatch_list_with_items` sorts by dispatch number with the
  same key. Same-day dispatches follow the requested direction, and every order
  ends in the key, so paging cannot repeat or skip a dispatch. CLR numbers now
  sort after the one-letter prefixes.
- Migration 34: a receipt or dispatch number made only of spaces, or an empty
  receipt number, is refused (`save_grn` answers with its "required" message;
  both tables carry a NOT VALID check, so existing records still migrate).
- Migration 35: quick search on the receipt lists. `get_all_grn_items` and
  `get_customer_grn_items` accept `p_filters.search`; every word must match the
  receipt number, customer, item, package, rack or vehicle number
  (case-insensitive; `%` and `_` are literal). `gr_no_from` / `gr_no_to` now
  compare in document order, so B9..B10 is a real range.
- Migration 36: quick search on the dispatch, invoice and order lists, and the
  filters those lists showed but did not apply.
  `get_dispatch_list_with_items` accepts `p_filters.search` (dispatch number,
  customer, vehicle number, or the item, package, rack or receipt number of a
  line) and `p_filters.package_mark`; `disp_no_from` / `disp_no_to` follow
  document order. `get_invoices_list` gains `p_search` (invoice number, also as
  `2026-12` or `2026-0012`, customer, receipt number), `p_date_from`,
  `p_date_to` and `p_customer_ids`. `get_orders_list` gains `p_search` (customer
  name or city, or the item, package or receipt number of a pending line). The
  new parameters are optional, so current app versions keep working.
- Migration 37: the dispatch list's `date_from` / `date_to` are moments in time,
  not whole days in the database's time zone, so "up to 7 Oct" includes all of
  7 Oct for the person asking. A plain date still means the start of that day.
- Migration 38: the language a person chose in the app is kept on their profile.
  `user_profiles.preferred_language` holds `en`, `gu` or NULL; `set_my_language(p_language)`
  stores the caller's own choice (NULL clears it) and `get_my_language()` returns it.
  Both need a signed-in, active account with a valid session. Server text stays English.
- Documents: text in Gujarati (a customer or item name) is set in Noto Sans Gujarati, to
  match the sans-serif page. It was already drawn correctly, in the serif face.

## Unreleased — invoice discount reason and author (2026-10-09)

- Migration 30: a changed invoice discount records its reason, the profile that
  set it and the time (`discount_reason`, `discount_set_by`, `discount_set_at`).
  Staff must give a reason (`discount_reason` in the invoice data) for any
  discount; administrators and supervisors may leave it empty. Applies to both
  `save_invoice` signatures and `update_invoice`. Apps that let staff set a
  discount must send the reason; see `docs/INVOICE_RULES.md`.

## Unreleased — fresh-install preflight checks the state parent (2026-10-09)

- `doctor --host-preflight` (run by `setup.sh`) now refuses a fresh install
  whose state directory sits in a parent the installation user cannot write,
  and names the `sudo chown` fix. Before, a state directory pre-created under a
  root-owned parent such as `/srv/warehouse` passed the preflight and setup then
  failed with `EACCES` while staging `<state>.installing-*` next to it (testvm2
  known issue 3). Reruns of an installed state need no parent write access.

## Unreleased — checkout permissions after an update (2026-10-09)

- Fixed F3 from the testvm2 operator run: a `git pull` under Ubuntu's default
  umask `0002` left changed scripts group-writable, so the documented "run setup
  again after updating" step was refused by `scripts/backup-usb.sh` (and
  `scripts/backup-disk.sh`). `setup.sh` now runs the new
  `scripts/checkout-permissions.sh` first, which removes group/world write and
  restores world read on tracked files and their directories (ignored runtime
  files and symlinks are untouched). The refusals name that command.
- Operator guide: the upgrade steps update the checkout with
  `(umask 022; git pull --ff-only)`, rerun the USB backup setup after
  `setup.sh`, and troubleshooting covers the refusal.

## Unreleased — orders screen review fixes (2026-10-09)

- Migration 28: cart history moved from the ever-growing `orders.revisions`
  array to an append-only `order_revisions` table (backfilled). The column is
  pinned to `[]` by a CHECK, so audit rows and realtime payloads no longer carry
  the whole history. `get_order_change_log` and dispatch deletion use the table.
- Staff have full order access: list, open and edit carts, the queue, and
  order history (guard v5). Customers can read the history of their own orders.
- Quantity changes check order state, dispatched quantity and stock. A two-
  customer account can edit its carts again (the old `<> ANY` check denied it).
- Cart removals go through the new `remove_item_from_order` RPC, which records
  history; the direct customer delete policy on `order_items` is gone. A lot can
  appear in a cart once (`order_items_order_grn_item_key`, duplicates merged).
- Dropped `convert_order_to_dispatch` and `update_order_after_dispatch_creation`,
  which wrote columns that do not exist. Orders become dispatches through
  `create_dispatch_with_stock_check` with `source_order_id`.
- Migration 29: `get_orders_list` reads a live view instead of rebuilding
  `mv_orders_list` on every cart write, and pages stably by order id. Weight
  search accepts decimals (`12.5`) and its access denials carry `success=false`.
- Added `tests/order_screen.sql` to `npm run test:migrations`.

## Unreleased — second-pass review fixes (2026-10-08)

- Added `scripts/tunnel.sh`: `adopt` keeps the Cloudflare Tunnel credential
  (config and credentials JSON, or a dashboard token) in the state under
  `config/tunnel/`, refusing the account certificate and another
  installation's tunnel; `install-service` writes the systemd unit for that
  copy. Backups (and USB copies) now carry it, and `db:restore-host` restores it,
  so a rebuilt host gets its public address back without a Cloudflare login.
  A lost backup drive now also means replacing the tunnel credential.
- Added `npm run db:restore-host` (`scripts/restore-host.sh`): rebuilds a lost
  installation on a new host from a backup directory or a USB `.tar`, with the
  same identity, keys and data, without running setup. It checks the archive,
  the backup, the migration history against the checkout and that the host is
  new before creating anything, then runs the in-place restore
  (`restore.sh --relocated`). CI runs a lost-host drill on real containers.
- Operator guide: "Recover a lost host from the USB drive", which rebuilds the
  same warehouse on a new host from a USB archive (now with `db:restore-host`;
  the first version used manual steps). Added `scripts/data-fingerprint.sh`,
  a read-only row-count and SHA-256 fingerprint of business tables and stored
  files to compare before backup and after restore.
- Added `scripts/backup-disk.sh`: prepares an empty second disk for backups
  (`status`, `plan`, `apply`, `sync`) and copies verified backups onto it. It
  refuses the system disk and anything that is not blank, never wipes or
  resizes, and `db:backup` is unchanged.
- Backups for pilot installs go to an operator-attached exFAT USB drive (one
  verified `.tar` per backup, readable from Linux and Windows-hosted VMs);
  the operator guide and contributor guide describe it, and the second disk is
  now the alternative.
- Added `scripts/backup-usb.sh`: after a one-time `sudo … setup --enroll`,
  attaching an enrolled exFAT USB drive starts a systemd unit that takes a fresh
  backup, copies it as a read-back-verified `.tar`, runs verify-restore on the
  copy and unmounts the drive. Optional daily timer for a drive left attached;
  `status`, `enroll` and `uninstall`; `doctor` warns when the last USB copy
  failed or is older than 7 days. Only enrolled drives (by filesystem UUID)
  trigger a run, and the copy runs as the installation user.
- Fixed `tests/backup-disk.test.mjs` opening a real device when the host has a
  disk with the fixture's name (`/dev/sdb`).
- Operator guide corrected from a from-scratch acceptance run: the state
  directory's parent must be owned by the installation user (`sudo install -d`
  on the leaf made setup fail with `EACCES`); fixed-window OTP limits and SMS
  cost; DNS negative caching after the tunnel route; `rest` has no healthcheck;
  `rotate-keys.sh` without `--yes` exits 1, and an external doctor right after
  rotation can fail once; root is needed to remove `*.pre-restore-*`; staff are
  created through Users, GRNs need a photo, and the 998 invoice example holds
  only for its fixture dates (same-day is 735).

- Migration 23: staff dispatch workflow completed (GRN picker, recent dispatches,
  dispatch photo register/confirm/cancel with matching storage policies);
  `get_item_storage_prices` removed from the staff allowlist; pending-upload
  cancellation bound to the registering profile.
- Migration 24: invoice header labour, tax and total are computed on the server
  from the saved lines and stored discount for every role; client totals are
  ignored; missing, duplicate or unrelated lines roll the save back.
- Migration 25: refused dispatch edits roll back completely; administrator
  status changes update the enrollment state and revoke sessions.
- Migration 26: GRN edits take the list-refresh lock before the item-table lock.
- Migration 27: a resend keeps the earlier OTP valid, wrong attempts are shared,
  the warehouse-wide hourly cap is configurable (`otp_global_hourly_cap`).
- Gateway: Cloudflare Tunnel is the only supported ingress; Kong trusts
  `CF-Connecting-IP` and rate-limits per client IP; the Caddy example is gone.
- Operations: shared `operator.lock` for stop, recovery, retention and gateway
  checks; `rotate-keys.sh --yes` rotates the signing secret and keys; backup
  format v4 (adds `_supabase` and the storage catalog); `scripts/restore.sh`
  restores a verified backup in place; functions, meta, realtime and imgproxy
  health probes.
- Release: any semantic `v*` tag is validated; Dependabot covers every image
  directory; research workflows and their evidence docs are removed.
- Tests: real guarded-RPC denials replace a probe that could never fail; new
  `user_status_enrollment.sql`, `grn_edit_lock_order.sh`, rotation, restore and
  lock refusal suites.

## Unreleased — remaining handoff checklist (2026-09-24)

- Record the [backend production checklist](docs/PRODUCTION_DEPENDENCIES.md#remaining-production-work)
  with owner inputs, next actions and acceptance evidence. The 17/19 image
  inventory and Grafana 102 HIGH count remain dated evidence, not a new scan.
  Track the unexplained historical CI setup HTTP 500 separately from the
  closed gateway iPhone retest and source-demo orders/cart acceptance.

## Unreleased — gateway merge and evidence closure (2026-09-23)

- Record reviewed PR #42 and mobile PR #28 merges with passing PR and exact-main
  CI. Preserve the earlier full iPhone matrix and later gateway-affected retest
  at their exact tested commits; the merged source pair is runtime-equivalent,
  without claiming a new physical-device run.
- Close the stale gateway CI and iPhone retest handoff claims. The CI-only subnet,
  isolated holder label and cleanup fix precede the green regression; the Linux
  old-TTL control did not reproduce the Mac stale cache. The separate setup HTTP
  500 cause remains unknown, and production operator and container security
  gates remain open. No runtime, workflow, companion pin, tag or release changes.

## Unreleased — setup failure diagnostics (2026-09-23)

- Reduce Kong's Compose DNS cache to five seconds (one second stale/negative)
  after reproducing direct bootstrap HTTP200 versus gateway HTTP502 following
  a functions-container IP change. Add an owned-network regression that forces
  an upstream address change and requires gateway recovery without restarting it.
- Give only the CI demo network an explicit subnet so the regression can reserve
  the old upstream address on GitHub's Docker daemon. Keep its temporary holder
  outside the checkout's Compose ownership label. These test-only changes fix
  failures that occurred before the gateway recovery check ran.
- On a failed health check, collect bounded, redacted gateway/function/REST logs
  from ownership-validated containers. Preserve the failing exit status and all
  readiness checks. This diagnoses post-merge CI bootstrap HTTP 500/502 failures;
  the IP-cache fix addresses the reproduced502 cause, not the separate500 attempt.
  The earlier completed iPhone evidence is not a device run of this later change.

## Unreleased — physical-iPhone orders/cart evidence (2026-09-23)

- Record the completed final merged-pair source-demo iPhone live-update matrix
  and owned cleanup. Close dependency item 9 only; production operator choices,
  capacity, Grafana findings and PostgREST inventory/scan coverage remain open.
- Documentation only: no runtime, companion pin, tag or release changes.

## Unreleased — iPhone USB Realtime companion (2026-09-23)

- Pin both companion checks to the mobile USB WebSocket relay fix and its
  regression tests. Active and documented workflows remain identical.
- This changes no backend runtime and does not by itself close physical-device
  acceptance or any production/security gate.
- Make the pooler acceptance probe wait for a successful authenticated SQL query
  after HTTP health: CI observed a healthy endpoint before port 5432 accepted
  connections. Both pool modes still require SELECT 1 and invalid-password
  rejection. Twelve bounded attempts fail closed; regression tests cover startup
  recovery, permanent failures, empty results and wrong results.

## Unreleased — Grafana OS patch and PostgREST provenance (2026-09-23)

- Rebuild digest-pinned Grafana 13.2.2 with Alpine OpenSSL 3.5.8 while preserving
  every publisher-signed bundled plugin file; local startup and health pass.
- Record byte-for-byte publisher release provenance for the PostgREST v14.17
  static binary. Its bundled dependency inventory and vulnerability assessment
  remain a release gate; the publisher evidence is not a substitute for them.

## Unreleased — setup HTTP readiness (2026-09-23)

- Wait up to 90 seconds per internal HTTP probe for transient gateway/transport
  failures after service recreation. Authentication, route and application errors
  still fail immediately; persistent outages fail at the deadline.
- Cover transient recovery, permanent errors, deadline exhaustion and redacted
  transport diagnostics. The exact-main follow-up caught a configuration HTTP 502
  during setup rerun after all container health checks had passed.

## Unreleased — source dependency audit and pooler diagnostics (2026-09-22)

- Audit container npm source manifests in CI, including metadata build/test
  tooling; update vulnerable dependencies while preserving generated-type output.
- Remove unused Storage development scripts/dependencies from its runtime
  manifest and apply compatible Fastify/protobuf patches.
- Declare the pooler entrypoint's required open-file limit so CI/container host
  defaults cannot prevent startup. Allow initialization time, bound probe
  connections, and report redacted
  failure diagnostics; cover credential-redaction regressions.
- Explicitly retain moderate and unfixed upstream advisory boundaries.

## Unreleased — Studio and metadata security (2026-09-22)

- Adopt the patched official September 21 Studio application and remove unused
  package-manager tools from its runtime image.
- Rebuild postgres-meta v0.99.0 against a compatible Fastify 5 plugin set, with
  a reviewable source patch, locked dependencies and retained upstream license.
- Verify Studio HTML/assets and metadata endpoints in CI; record 197 passing
  upstream metadata tests and retain Grafana publisher signatures as a gate.

## Unreleased — orders/cart companion and maintained image recipes (2026-09-22)

- Start Realtime in the default demo and pin both mobile companion jobs to
  `989ade8e86f313ae4b173ad1bb5b56607ecbe353` for orders/cart live updates.
- Add digest/checksum-pinned source recipes and dependency locks for patched
  monitoring, Auth, Storage, PDF, PostgreSQL helper, and pooler images; preserve
  the PostgreSQL server version and production gates.
- Verify pooler session/transaction queries and invalid-password denial in CI;
  validate monitoring configuration using the actual maintained images.
- Retain upstream license texts and notices for copied dependency manifests;
  record patch/acceptance boundaries in `docs/CONTAINER_SECURITY.md`.

## Unreleased — image remediation and production dependencies (2026-09-22)

- Build Edge Runtime and Realtime from digest-pinned upstream images with Debian
  security updates; preserve their upstream application versions.
- Reject missing, invalid, mismatched and vulnerable image-scan reports even when
  the scanner exits successfully; cover false-success regressions.
- Record the nine remaining production areas with specific external inputs and
  distinguish those blockers from unfinished image/mobile Realtime engineering.

## Unreleased — remaining local gates (2026-09-22)

- Verified actual Realtime update delivery, customer isolation and reconnect;
  restore fictional fixture notes after the probe.
- Image scanning now rejects failed/empty Compose inventory and uses a fresh
  private report directory per run.

- Removed unused recommended CUPS packages, clearing its 56 fixed HIGH/CRITICAL
  findings. Require an administrator password and preserve the spool on startup;
  CI verifies the hardware-free startup path.

## Unreleased — provider-independent local readiness (2026-09-22)

- Added private backup plus isolated restore verification, owned-service recovery,
  database retention preview/apply boundaries, gateway CORS/body/TLS checks,
  local load smoke, monitoring validation, and authenticated Realtime smoke.
- Updated current upstream service images and their required configuration,
  constrained cAdvisor metrics, removed the unused analytics service, and kept
  host ports on loopback with explicit resource budgets.
- Added an all-profile Trivy scanner. Its unsuppressed fixed HIGH/CRITICAL
  findings remain a production blocker, including optional service images.
- Extended CI to exercise the new local operational checks and preserved
  byte-identical tracked workflow copies.
- Made the Realtime smoke tolerate only bounded transient Kong 502/connection
  errors while the newly started upstream becomes routable; authentication and
  protocol failures still fail immediately.
- Paired the backend evidence with a native Android debug build and artifact
  contents/permissions/notices audit in the mobile repository. No binary or
  signing credential is published.

## Unreleased — iOS acceptance handoff (2026-09-21)

- Reconciled the release and production checklists after final acceptance: all
  evidenced source-demo dependency, device, authorization, business-flow and
  ownership items are closed; only production deployment and future-binary gates
  remain open.
- Closed the complete physical-iPhone source-demo matrix on the final merged pair:
  backend PR #13 / `cf18f1e43ab613310b1b13339ab97e8533861f9b` with mobile PR #18 /
  `9ba56ff122dc38dc57d6100de4c27599023d22b1`; exact-main CI and affected
  iPhone reruns passed.
- Added customer-authorized per-GRN dispatch history, readable demo fixtures and
  stable order-item snapshots supporting the final mobile acceptance fixes.
- Recorded the end-user pricing, code-level billing-day and PDF/cold-storage
  branding customization boundaries in the durable handoff.
- Added guarded customer-history RPCs for the post-release mobile repair:
  customer GRN filtering/pagination now matches the exposed view controls, and
  a paginated customer dispatch-header list returns only assigned-customer data.
  The associated live API coverage verifies pagination and cross-customer denial.
- Fresh isolated-demo migration and live companion-contract checks passed. The
  repair subsequently passed paired PR review, exact-main CI, the earlier
  customer-history pair's Android smoke and the final physical-iPhone closure;
  published source-only tags are unchanged.
- Fixed configuration, doctor and migration-plan CLI execution through symlinked
  checkout paths, including macOS temporary directories. Added regression coverage
  and restored the setup-failure/configuration-preservation test.
- Aligned the developer handoff with complete physical-iOS evidence, closed mobile
  defects, reproducible USB onboarding and pricing/PDF customization contracts.
- Pinned both CI workflow copies to the submitted mobile handoff commit.
- Preserved published source-release tags; the follow-up passed paired review and
  exact-main CI.

## 0.2.2-demo — source-only prerelease (2026-09-18)

- Added checksummed forward migrations for padded dispatch suggestions and
  protected invoice line-detail compatibility without changing stored document
  identifiers.
- Added numeric ordering, rollover/exhaustion, authorization, fresh/upgrade,
  mobile-validator, and isolated API regression coverage.
- Added ownership-aware clean onboarding, loopback isolation, configuration and
  data-preservation checks, and exact mobile companion pinning in both workflow
  copies.
- Verified the complete source-demo API matrix and paired Android onboarding;
  production and physical-device release gates remain separate.
- Reconciled public onboarding, acceptance scope, maintainer redistribution
  attestation, Supabase-derived configuration provenance, and included license text.
- Restricted the release workflow to the exact `v0.2.2-demo` tag with positive
  and negative regression coverage; publication contains source archives only.

## Unreleased — second-pass review

- Corrected readiness claims: fresh migrations and mobile API coverage fail;
  setup/start and future releases are gated pending a complete sanitized export.
- Added isolated migration/contract tests, credential-preservation and JWT/profile
  regression tests, Compose ownership checks, and explicit readiness documentation.
- Hardened custom-auth function checks and corrected public configuration URLs.

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0] - 2026-03-10

### Added
- Initial release of the Supabase Warehouse Template
- Custom phone OTP authentication (no GoTrue dependency)
- Docker Compose setup with 10+ containers
- Edge Functions: router, config, PDF generation, printing
- CUPS printing integration via IPP
- Gotenberg HTML-to-PDF conversion
- Prometheus + Grafana monitoring stack (optional profile)
- Connection pooler via Supavisor (optional profile)
- One-command setup script with automatic secret generation
- Health check script
- Comprehensive .env.example with all variables documented
- CI/CD workflows for GitHub Actions
- Consolidated database migration with warehouse schema
