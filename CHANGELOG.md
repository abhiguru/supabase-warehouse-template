# Changelog

Older entries (every release and every dated section before the baseline reload) are in git: the full text is
`git show migrations-pre-baseline:CHANGELOG.md`. The full text of the entries written after that tag (the post-baseline history) is in
main at `5561868`: `git show 5561868:CHANGELOG.md`. Each section below is the short form. "Migration N", for N up to 110, names
a file in that tag; the baseline `migrations/00000000000000_baseline.sql` is their squash. The upgrade notes ("Operator actions") that this
file used to carry for earlier installations are in git: `git show b45ae0b:CHANGELOG.md`.

## Unreleased

### Added

- `scripts/notify.mjs`: alerts leave the checker through one channel-neutral delivery layer (adapters, targets with stable ids, per-target state `delivery` in `config/watch-state.json`; the old `lastPostError` and `lastHeartbeat` keys move into `delivery`; sensor failures are tracked in `delivery` per channel). Slack is still the only channel; the options and files are the same, and some wording changed: `watch.mjs status` shows the alert channels (the line "Slack webhook: ..." is replaced by channel lines), `test-message` and its help say "alert channel" instead of "Slack webhook" (including the "nothing was sent" message when none is configured); the alert, heartbeat and failed-post texts are otherwise as before. For one release the state file also still writes all the mirrored old keys (`lastPostError`, `lastHeartbeat`, and `lastSensorPostError` / `lastSensorHeartbeat` when set; and the old `via` values) from `delivery`, and reads state written by a pre-release build, as pre-release and rollback compatibility, so a rollback to such a build or an older daily pass keeps working; the mirror can go in a later release. Every delivery attempt is also kept in `logs/alerts.jsonl` (mode 0600, 12 months, no URLs), read with `node scripts/watch.mjs history [--days N]`.
- A separate Slack webhook for sensor alerts: `setup.sh --sensor-webhook-file ABSOLUTE|off` stores it at `config/sensor-webhook-url` (mode 0600; required when Slack alerts and sensors are on). `sensors_stale`, `check_error:sensors_stale` and the `sensor-bridge` service, restart, out-of-memory and memory alerts go there, and an alert's repeat and clear follow its start (fallback: the facility webhook); the daily heartbeat is posted to both, a sensor post failure is tracked separately in `delivery["sensors-slack"]` (shown by `watch.mjs status`); `watch.mjs test-message sensors` tests it; the doctor warns when it is missing, invalid, equals the facility webhook or recently failed, and `set-capability.mjs sensors on` and `setup.sh` print a notice when it is missing. The sensor webhook is an addition to the facility one: `configure.mjs` refuses `--sensor-webhook-file` when no facility webhook is stored or given in the same run, and `--alert-webhook-file off` while a sensor webhook is stored (unless `--sensor-webhook-file off` is given too); facility alerts never go to the sensor channel. `docs/MONITORING.md`, `docs/SENSORS.md`, `docs/OPERATOR_INSTALL.md`.
- Sensor bridge: a hub whose IP address changed (power cut, router reboot) is found again by itself. While a hub is offline the bridge sweeps `SENSOR_BRIDGE_SCAN` (default the /24 of each hub address; private networks of /22 or smaller, or `off`) at most every `SENSOR_BRIDGE_RELOCATE_SECONDS` (600) with unicast TCP connects and a login, matches the hub by its own id, switches to the new address (`event=hub_moved`), keeps the queued readings and stores the move across restarts. Two hubs that swapped addresses work; a never-reached hub is claimed only by an H100/H200 hub that logs in, reports a temperature or humidity sensor and that no other entry follows (logged as a warning; undo with `--forget-hub <address>`). The sweep runs in the background (other hubs and delivery are not held), refuses python-kasa's "less secure" MD5 login, skips an address whose login was refused for 6 sweeps, covers at most 1024 addresses, and with the sweep on an unknown hub at an address is a failed poll, not a replacement, until a sweep misses the old hub. Per-hub state is keyed by the hub id (older state keyed by address is still read). `docker/sensor-bridge`, `docs/SENSORS.md` ("Keep the hub addresses fixed"), `docs/TROUBLESHOOTING.md`; new variables `SENSOR_BRIDGE_SCAN`, `SENSOR_BRIDGE_RELOCATE_SECONDS`.
- `node scripts/doctor.mjs` warns, while the `sensors` capability is on, when readings do not reach the database: no hub row, a hub offline (for how long) or not reported for the limit, no reading newer than the limit (3 x the larger of `SENSOR_BRIDGE_HEARTBEAT_SECONDS` and `_POLL_SECONDS`, plus `_POST_SECONDS`: 16 minutes by default), or `SENSOR_BRIDGE_HUBS` set with no `sensor-bridge` container. A warning only; `scripts/sensors-check.mjs`, `docs/SENSORS.md`. The 5-minute checker judges the same things and sends the alert `sensors_stale` (two failing runs in a row; not judged for the first 16 minutes after the database or the bridge started); `docs/MONITORING.md`.
- `scripts/windows/register-tasks.ps1`: registers the Windows (WSL2) tasks "Warehouse WSL" and, with `-BusId`, "Warehouse USB" from an elevated PowerShell, replacing the two paste-in blocks of `docs/OPERATOR_INSTALL.md`; verified on Windows (see `docs/OPERATOR_INSTALL.md`).
- `bash scripts/tunnel.sh create [--name NAME]`: one guided step for a locally managed tunnel. It runs `cloudflared tunnel login`
  (a link to open on any machine), refuses a tunnel name that already exists, creates the tunnel, routes the installation's hostname
  to it without `--overwrite-dns`, writes and validates the config and adopts the credential into the state. The account
  certificate is held in a private temporary directory and shredded on every exit path. `adopt` and `install-service` are unchanged;
  the manual sequence and the dashboard route stay in `docs/OPERATOR_INSTALL.md`.

### Fixed

- `scripts/watch.mjs`: the disk check skips read-only mounts (the stack cannot fill them), which removes the false
  `disk_low` alert for the full read-only image WSL2 mounts under `/usr/src`. A read-only mount does not hide a read-write mount of the same device.
- `scripts/watch.mjs`: no false `service_down` or `container_restarts` alerts after a host or distro restart. The 5-minute checker tolerates a health state of "starting" for 4 minutes after the container's start (not for a container that restarted in the last hour; `health`, `doctor --local` and the daily gate are unchanged), and a restart of the whole stack (every running container started again within 5 minutes; usually that is one start of the stack, also from `start.sh`) is not counted per container. One new alert, `stack_restarts`, fires when the whole stack restarted more than 3 times in an hour; one container or a subset restarting still counts as before.

### Documentation

- `docs/SENSORS.md`, `docs/OPERATOR_INSTALL.md`: sensors are optional; when configured, verifying ingest in the database (SQL, timing, `sensor_status`, capability check, exit code 1 with a failed hub, backup while the bridge runs, key into `compose.env` without printing it) is a required step of the install.
- `docs/OPERATOR_INSTALL.md`, Windows (WSL2) section: the results of a second round on Windows 10 22H2 (what is verified and what is
  not), the keep-alive task registered before `tunnel.sh create`, a wait for systemd after a cold start, the planned-work and
  `wsl --update` notes, the USB drive through `usbipd-win` (works; without the Warehouse USB task below the attach does not survive a restart).
  Setting `otp_daily_provider_attempt_cap` is now a required go-live step for an installation reachable from the
  internet. `docs/RELEASE_CHECKLIST.md` has a manual Windows acceptance section.
- `docs/OPERATOR_INSTALL.md`, Windows (WSL2) section: a "Warehouse USB" scheduled task (`usbipd attach --wsl Ubuntu-24.04 --auto-attach --unplugged`,
  boot plus every 2 minutes) that attaches the USB backup drive to the distro again after a restart, with `backup-usb.sh setup --daily`;
  verified (see `docs/OPERATOR_INSTALL.md`). `docs/RELEASE_CHECKLIST.md` checks it after a reboot and after `wsl --shutdown`.
- `docs/OPERATOR_INSTALL.md`, `docs/SENSORS.md`: the operator guide and the sensors guide are trimmed to the current release: notes for installations made before a release or migration are removed; "Baseline reload" and "Major PostgreSQL upgrade" are short stubs (the full procedures are in the git history of the file), and the matching `docs/TROUBLESHOOTING.md` entries are shortened.

### Operator actions

None for a new installation from this release: there is no earlier installation to bring forward, and an installation of v0.6.1 or earlier is not
upgraded; install afresh.

### Changed

- **Windows hosts: the operator guide describes Ubuntu 24.04 in WSL2 and no longer a Linux virtual machine.** The new section
  [Windows host (Ubuntu in WSL2)](docs/OPERATOR_INSTALL.md#windows-host-ubuntu-in-wsl2) replaces "Windows host with Linux VM": prerequisites,
  Docker Engine inside Ubuntu, a keep-alive scheduled task that starts the distro at boot and after `wsl --shutdown`, the tunnel as the only
  ingress (no LAN fallback on WSL2's NAT), planned work, where the data lives and an acceptance list, with each step marked verified or not
  yet verified. The USB backup path through `usbipd-win` and the "Warehouse USB" task is verified (the acceptance list marks what is not). A Linux operator need not act. The Linux guide gains: the tunnel service in the steps for taking an installation out of
  service, a pointer from the tunnel section to the SMS cap (`otp_daily_provider_attempt_cap`) and the test-installation rule, `health-check.sh`
  in "Ordinary operation", a note to decide the hostname before the first setup (`--api-url` cannot change later) with a link to the DNS
  negative-cache note, and the instruction to delete the account `cert.pem` (which `cloudflared tunnel login` always writes to
  `~/.cloudflared/`) once the tunnel exists. No script, workflow or migration changed.
- **GRN, dispatch and invoice numbers follow a per-facility numbering rule (migration 127).** `warehouse_security.document_numbering` holds one
  rule per document type (letters, financial year, sequence or free text; invoices: restart each financial year or keep counting) and
  `document_numbering_history` records every change, never pruned. New RPCs: `suggest_document_number(p_document_type, p_date)` (the next number, its
  pattern and, where there is none, the reason `TYPE_IT` or `SERIES_FULL`), `get_document_numbering()` (administrators and supervisors) and
  `set_document_numbering(p_document_type, p_rule)` (administrators). `get_next_grn_number`, `get_next_dispatch_number` and `get_next_invoice_number`
  keep their signatures and answer with the same suggestion (they raise the reason where there is no number). `save_grn`, the dispatch create and a
  dispatch edit that changes the number (their bodies are definition files; `update_dispatch_smart` has one now) refuse a number outside the rule with `NUMBER_FORMAT` and the pattern; the letter rule accepts any letter and
  at least `digits` digits, so FAS's series is saved whatever the first letter. The GRN suggestion no longer returns a taken number at a facility whose
  series runs W, X, Y, Z, A, B (the earlier generator stopped at A1000), and it always starts the order of the letters after the longest run of unused letters,
  so W0818-W1000 followed by X, Y, Z and A0257 gives A0258 under `first=W`, `X` and `A`, and one mistyped letter far from the series does not take the
  suggestion over (in a series that runs W to A, a stray from B to K can, and one at L does under `first=W` only, where two runs of unused letters are equally long and the one nearer the first letter wins); `doctor` names GRN letters in use outside the main series (the one that holds the most numbers) and a highest letter that follows a letter that is not full. Each rule has a **check** (`check=on|off` in the setup option, `check` in
  `set_document_numbering`): off, a number outside the rule is saved (a taken number is still refused) and the rule still suggests the next one; a
  document type whose existing numbers do not follow the rule it starts with starts with the check off, and `doctor` warns until it is switched on. `setup.sh --operator --grn-numbering`,
  `--dispatch-numbering` and `--invoice-numbering` choose the rules; `doctor` prints them. `goodsreceived.gr_no`, `invoice.gr_no` and
  `dispatch.disp_no` hold 20 characters (`v_orders_list` is made again). See [Document numbers](docs/OPERATOR_INSTALL.md#document-numbers).

- **A fix to an RPC body or to `authorize_rpc` no longer needs a migration: those functions are definition files that setup applies again when they change.**
  `migrations/definitions/` holds the current text of `warehouse_security.authorize_rpc` and of the eleven RPCs that migrations 111 to 126 had patched
  (`save_grn`, `update_grn`, `delete_grn_safe`, `create_dispatch_with_stock_check_internal`, `get_invoice_data`, `get_invoice_detail`,
  `get_sensor_polling_data`, `refresh_jwt_token`, `operator_prepare_otp`, `operator_verify_otp`, `apply_grn_rates`), each with its grants. After the numbered migrations,
  `setup.sh` applies each file whose checksum differs from the row in the new table `warehouse_migrations.definitions` (the first run after this
  release applies all twelve, which changes no function: the bodies equal what the migrations leave, and `tests/migrations.sh` compares the two
  catalogs), and tells the API to reload. A file may hold only function statements about its one function; the plan refuses anything else before it touches the database,
  stops at a file whose function a migration dropped, and applies every file again after a run that applied a numbered migration.
  So an SQL security fix to one of these functions can now ship as a patch of the current line and as a backport to the previous line
  (`ci.yml` lets a pull request into `release/*` change an existing definition file, and still refuses a numbered migration). Tables, data and
  signature changes stay in numbered migrations. No operator action.
- **Storage's schema version is recorded, frozen on purpose and rehearsed on a populated catalog.** `docker/storage/migrations-head.txt` names the newest
  migration of the Storage image (73, `revoke-grants-to-unused-operations` for v1.80.2); `DB_MIGRATIONS_FREEZE_AT` on the `storage` service holds the
  same name, so an image that moves by accident (a merged Dependabot bump, a rebuilt tag) applies no migration beyond the release's own. Every backup
  records `storage_image=` and `storage_schema_head=` in `metadata.txt`, and `storage_migrations_count=` and `storage_migrations_head=` in
  `integrity.txt`; `db:verify-restore`, `db:restore` and `db:restore-host` refuse, before anything is changed, a backup whose Storage schema is newer than
  the checkout's image knows (an older one, or a backup made before these lines, restores as before: Storage migrates it forward at its next start).
  `pg-boss` in the Storage recipe is pinned to a commit (the one the lock already resolved) instead of a branch. The new `tests/storage-drill.sh`
  (CI job `storage-drill`, weekly and on a change to `docker/storage`; not a required check) seeds thousands of objects, reads every one and a signed URL
  through the API, and rehearses the move to the next tag of the same major, with the freeze still set (the new code must still serve the old schema) and then
  set to that tag's own newest migration, printing how long Storage's migrations took. Dependabot may propose Storage minor updates again (majors stay ignored); each is a notice, because the tests fail until the tag,
  `ENV VERSION`, `migrations-head.txt` and the freeze move together. The quarterly procedure is in `docker/storage/README.md`. Nothing for the
  operator to do: the next `setup.sh` rebuilds the Storage image and recreates the container with the freeze.
- **An upgrade is a planned downtime: the API is closed to phones from before the backup to the end of setup, and the checker follows it.**
  After its preflight, before the backup, `upgrade.sh` runs `bash scripts/maintenance.sh on`: both gateways (`gateway`, and `gateway-lan` when it
  runs) answer every request for `/rest/v1/`, `/storage/v1/` and `/functions/v1/` with HTTP 503, `Retry-After: 120` and the body
  `{"code":"upgrading","message":"The facility's server is being updated. Try again in a few minutes."}`, before the key check and the path check;
  the CORS preflight, `/health` and the `X-Warehouse-Path` header are as before. After the setup of the new release it runs that release's
  `maintenance.sh off`, which recreates the gateways and ends with the health check. The state is the marker `config/maintenance` (not a line of
  `compose.env`): `scripts/compose.sh` hands Compose `WAREHOUSE_MAINTENANCE=upgrading` for every command while it exists, so nothing that
  recreates a gateway meanwhile (the setup of the new release, `start.sh`, a restore) can open the API half way; the gateway reads the word
  `off` or `upgrading` and refuses any other at start. **When a step fails after the checkout has moved, the API stays closed** (the facility may be
  half upgraded): the printed way forward says so, and the way back gains the line `bash scripts/maintenance.sh off` before its health check;
  when nothing was changed yet (a refused check, a failed backup or proof, a checkout that did not move) it is opened again at once. `bash scripts/maintenance.sh on|off|status` is also
  for a planned stop of the API by hand: `on` removes a gateway container that is not running or cannot be recreated (so none can start again open), and `off` creates the gateway again if it has no container; `off` exits 2 when the API is open but the health check failed, and the record then says `maintenance=opened`. The record gains `maintenance=on`, and the way back says that phones recorded nothing after the backup.
  `backup.sh` now stops `gateway-lan` with the gateway (the nightly dump is consistent for phones on the warehouse network too) and starts it
  again apart, as a warning when it will not start; it never lifts maintenance mode. Checker: while an upgrade is recorded the operator lock is
  called stuck after the longer of 2 hours and twice the last backup plus the last verify (at most a day; the verify time is the third field
  of `config/backups-verified.list` that `upgrade.sh` records, the backup's own time stands in for a nightly one that has none); the new alert
  `upgrade_interrupted` fires at once when the record exists and the lock is free, and is never muted; self-healing starts and restarts nothing
  while the record exists; `node scripts/watch.mjs status` says "Maintenance mode: upgrading". `doctor --local` and the health check cannot probe the
  API through a gateway that is closed on purpose and say so as a warning (the LAN probe is skipped the same way); `maintenance.sh off` runs the
  health check again. `scripts/check-release-contents.sh` requires `scripts/maintenance.sh`, because the `upgrade.sh` of the release an
  installation runs now opens the API with the one of the release it moved to.
- **Migrations: a lock timeout, the schema reload per file, and a rule that keeps the order.** Each file runs in its own transaction with a
  10 s `lock_timeout`; one that cannot get its lock (a session of the API holds the table) rolls back whole, and `scripts/migrate.sh` runs the
  plan again, three attempts five seconds apart, before it stops with a message that says what to do. PostgREST is told to reload its schema
  after every file's `COMMIT`, not only at the end. `scripts/check-migration-order.mjs` (CI job `migration-order`) fails a change that
  removes, renames or edits a file of `migrations/` or adds one that sorts before an existing one (`CONTRIBUTING.md`); a later squash of
  the chain is a snapshot kept outside `migrations/` for fresh installs only. `tests/storage_policy_deps.sql` fails when a migration drops a
  column that the storage policies of `scripts/configure-storage.sql` read, and `tests/migrations.sh` applies the newest migration to a
  database that already has those policies, as an upgrade does. A weekly `seeded-upgrade` CI job upgrades a facility with data
  (`tests/seed/`, 300 receipts, 200 dispatches, 40 invoices, photos) and, in a second variant, proves that clashing customer names refuse the
  upgrade before the checkout with migration 117 named.
- **The backend tells the app which release it is, and the minimum app build comes from the release.** `setup.sh` writes
  `<state>/public/release.json` (the tag or `git describe`, the commit, the newest applied migration, the time) and
  `<state>/public/app-compat.json` (copied from `app-compat.json` of the checkout) on every run, after the migrations. `get-public-config`
  answers `backendRelease` and `schemaHead` from the first (`null` while it is absent) and `minimumClientVersion` from the second; it no
  longer reads the minimum from `instance.json`, which keeps the field for older readers, and it answers 503 until `setup.sh` has written
  `app-compat.json`. `get-config` reports the same `backendRelease`. A backend
  release supports the newest app release; an older build is told to update ([docs/API_CONTRACT.md](docs/API_CONTRACT.md)). Nothing to do
  beyond `setup.sh`/`upgrade.sh`; the two files appear under `public/` and are not part of a backup. `setup.sh` and `scripts/restore.sh` write them
  again for the checkout they run from (`scripts/release-info.sh`, after the migrations), so they are right after a rollback with an older checkout too.
  A missing or invalid `app-compat.json` makes `get-public-config` answer 503 saying so, and `doctor` names the file.
- **A restore compares the identity of the instance, not the bytes of `instance.json`.** `scripts/restore.sh` refuses a backup of another
  facility (different `instanceId`, `canonicalOrigin` or `companyName`, and names the field) but no longer refuses one whose
  `instance.json` differs only in the capabilities, the supported API versions, the display name or the minimum app version.
- **The contract checker reads `DROP`.** `scripts/check-mobile-contract.mjs` follows the migrations in order, so a function, table or view
  that the app calls and a later migration drops is reported missing (it passed before); `tests/rpc_callers_exist.sql` also fails when
  a parameter without a default is added to a function fas-sync calls.
- **The REST contract is tested against the real service.** `tests/migrations.sh` starts the pinned PostgREST image on its test database
  and `tests/postgrest-contract.test.mjs` asserts the status, code and message of every refusal the app keys on; the table is in
  [docs/API_CONTRACT.md](docs/API_CONTRACT.md), "What the app may match: codes, not texts".
- **jose 6.2.12 (was 5.10.0)** in `functions/vendor` and the unit tests; Dependabot proposes jose updates again.
- **`upgrade.sh` runs the release's own preflight before the backup, enforces an oldest release to upgrade from, and keeps the old images for the
  way back.** `upgrade.sh` is the script of the release you run now and cannot know what the release you move to needs, so every release now
  carries `scripts/upgrade-preflight.sh` and `scripts/upgrade-floor.txt`; `upgrade.sh` reads them out of the release (`git archive`, as it reads the
  PostgreSQL major) and runs the preflight first, in `--dry-run` too. It prints the operator actions of `CHANGELOG.md` for the whole span **before
  anything is changed** (they are still printed at the end): **run `bash upgrade.sh --dry-run vX.Y.Z` first** and do what it lists under "before";
  the real run, at a terminal and when the list has operator actions, then waits ("Press Enter to continue, Ctrl-C to stop"), and the new option
  `--yes` skips that pause (a run without a terminal on standard input, such as cron, CI or `</dev/null`, never pauses). It checks the host against
  what that release needs (Node.js, Docker and Compose, `rsync` and `tar` with extended attributes, free space: the checks of the release's own
  `setup.sh`, which used to stop an upgrade only after the checkout), refuses an installation older than the release's floor and names the release
  to upgrade to first (no floor yet), and refuses when the free space is below the stored files of the newest verified backup, plus the size of its
  database dump, plus 1 GiB, because the way back is an in-place restore that needs that room (a minimum: the photos added since and new images
  come on top). A refusal says "Nothing was changed". Only an installation that already runs this release (or a later one) reads a release's
  preflight: the move **to** this release is still made by the `upgrade.sh` you have now, which does not, so the preflight works from the next
  release on; a release without one is moved to as before, with a line saying so. The upgrade record gains `preflight=` and `pre_images=`. The backup
  the upgrade takes and proves is put on `config/backups-verified.list`, so the 60-day keep below applies to it, not only to the nightly one before it.
  Before the checkout, `upgrade.sh` tags the images the containers use (running ones, and stopped optional services) as
  `<project>-<service>:pre-<old release>` (`scripts/pre-images.sh`) and keeps a copy of the build record; the printed way back puts them back
  (`bash scripts/pre-images.sh restore <old release>`) so that the old release's setup normally builds nothing and needs no network, and then runs
  `bash scripts/build-images.sh --save` (builds nothing) so that `<state>/images`, the signed copy a lost-host restore loads, holds the old images
  again; after a successful upgrade only the newest set is kept (older tags are removed one by exact name, never with an image prune). A rerun of
  an interrupted upgrade never tags the images again. `restore.sh` now checks, before it moves anything, that the
  checkout contains every migration the backup applied (the check `db:restore-host` already made), so a way back from the wrong checkout stops while the data is
  intact. The checker raises `restore_space_low` when the free space in `data/` is below that same size (it repeats once a day), and the nightly pruning keeps,
  for 60 days, the newest verified backup of each migration state besides the newest 7 (the copy from before a schema change). The install guide has a
  disk-sizing rule, "at least 3 × the photos + 3 × the database + the images + 20 %" ("Disk space"), and the Major PostgreSQL upgrade's disk check now counts
  the photo copy. Every run of `setup.sh` now renames a `KONG_HTTP_PORT` line of `compose.env` to `GATEWAY_HTTP_PORT` (same port; it used to happen only
  with `--gateway-port`), which is what lets a later release drop the old name; the compatibility shims name the release that may drop them. Nothing to do.
- **The USB drive: encrypted by default, pruned, self-contained archives, verified without unpacking the photos** (see [USB backup drive](docs/OPERATOR_INSTALL.md#usb-backup-drive)).
  `scripts/backup-usb.sh` writes one pax tar per run of the newest verified backup (`scripts/backup-archive.sh`: small files first, the
  `storage/` tree last, hard links written out, `user.*` attributes kept), `warehouse-<utc>.tar.enc` unless `--no-encrypt` was typed, with
  the checksum and signature files; the restore check unpacks only the small files (`verify-restore.sh --no-storage-tree`) after
  checking that the state directory has room (the archive is hashed before it is listed or opened); the drive keeps the newest three
  valid archives and never deletes the newest, a damaged, unsigned or foreign one, and deletes nothing to make room when deleting could
  not make enough or when the free space cannot be read (the run is then refused); `scripts/backup-key-escrow.sh` records that the whole
  backup key was given back from a copy kept elsewhere (`show` asks for the whole key, `confirm --key-file FILE` compares a file;
  `config/backup-key.escrow` holds a fingerprint), which enrolment and encrypted runs require; the `usb_backup` alert and `npm run
  doctor` warn when it is missing, and when an installation still writes readable archives because it never reran the USB setup. A
  step of the copy that fails (the rename, the checksum file) fails the run, and checksum or signature files left without an archive
  by an interrupted copy are removed. Readable archives are never deleted on a run with restore verification switched off. The
  lost-host restore accepts stored files whose names have spaces. CI's lost-host drill rebuilds a host from an encrypted USB archive and
  the key copy alone.
- **LAN fallback (`gateway-lan`, `scripts/lan.sh`).** A second, optional nginx container (Compose profile `lan`) that serves the
  gateway's routes over plain http on the host's own private address, for phones on the warehouse network while the internet is down:
  the same key check, body limits and rate limits, no trust in a client-supplied address (the per-phone limits and the per-source OTP
  limits see each phone's own address), `allow <warehouse network>; deny all;`, a pinned `Host` (the server's own address, with or
  without the port, or 404), and `X-Warehouse-Path: lan` on every answer (the public server sends `public`). It is **the gateway's own
  image** (the LAN server and a copy of the http template are kept in it under `/etc/nginx/templates-lan`; no second build, no mount from
  the checkout), so an upgrade that rebuilds the gateway rebuilds the fallback with it. `get-config` offers the address to signed-in
  phones as `urls.lan` while it is on; `get-public-config` never does. `doctor` (`--lan`, and `--local` as a warning) and the checker
  (`lan_http_down`, `lan_ip_changed`, and the `gateway-lan` log in the gateway rates) look after it, including a REST request with the
  installation's anon key, which catches a container that holds the keys from before a rotation. `doctor --lan` also warns about a range
  with fewer than 4 addresses, rootless Docker, Docker Desktop, `"iptables": false` and a `LAN_CIDR` that overlaps a Docker network. A
  caller's `COMPOSE_PROFILES` no longer reaches Compose through `scripts/compose.sh` (compose.env alone decides). See
  [LAN fallback](docs/OPERATOR_INSTALL.md#lan-fallback-plain-http-on-the-warehouse-network).
- **The gateway is plain nginx from the official image; Kong is gone.** `docker/nginx` replaces `docker/kong.yml` and the
  `eval` entrypoint: nginx 1.30 (alpine-slim variant, pinned by tag and digest, no HIGH or CRITICAL finding at the time of the
  change), the routes, key check, CORS, body limits and the redacted access log as before, 128 MB instead of 512 MB, a read-only
  root file system, no capability and a non-root user. The configuration is plain nginx files plus two templates in which
  the image's own envsubst puts the origin and the two API keys (only those three variables, and the container refuses to start
  on a value that could change the configuration); the old `eval` of a shell string over `kong.yml` is gone, which closes the open item
  in `docs/CONTAINER_SECURITY.md`. Real-IP trust is in the public server block only, in front of a routes file shared with the
  LAN server of the optional `gateway-lan` service. Upstream names are looked up again every 5 seconds without a reload. The Compose service
  is `gateway`, the in-network name `http://gateway:8000`, and the variable `GATEWAY_HTTP_PORT` (`KONG_HTTP_PORT` still works).
- **Rate limits are a leaky bucket, not a counter per clock minute.** REST: 30 requests a second per client address with a burst
  of 1800 (`rate=30r/s burst=1800 nodelay`), which is the same 1800 a minute on average and 18 a minute for each of 100 phones,
  but 1800 may now come at once and the next is refused until the bucket drains at 30 a second (HTTP 429 with the same JSON
  body and a `Retry-After: 1`). Functions: 100 a minute with a burst of 100; the hourly cap of 6000 is gone, since 100 a minute
  adds up to 6000 an hour. Storage still has no limit. The gateway no longer sends the `X-RateLimit-*` headers.
  `tests/gateway-smoke.mjs` checks the new behaviour per client address.
- **Differences from Kong that a client can see.** A preflight is answered 204 (Kong: 200); a request whose `Content-Length` is
  over the body limit is answered 413 before the key is looked at (Kong: 401 first); the API key is read from the `apikey` header
  only, not also from a query parameter, and its letter case is ignored (nginx matches the keys of a map that way; the anon key
  is public and PostgREST checks the user's token itself); `Retry-After` on a 429 is always `1` (Kong sent the seconds until its
  window reset, up to 60, and the app counts down from it on a 429 from a function); Storage no longer receives `X-Real-IP` and
  `X-Forwarded-For` (Kong could not remove them); the upstreams receive no `X-Forwarded-Proto`, `-Host`, `-Port`, `-Path` or
  `-Prefix` (checked: no function, SQL or app path uses them); every route sets `CF-Connecting-IP` from the address the
  gateway settled on; the `Server` header reads `nginx` without a version; no `X-Kong-*` or `Via` headers.
- **New at the gateway.** A path with a dot segment (`/./`, `/../`, also written `%2e` or with the slash as `%2F`) is answered
  404 on every route, so a `..` that an upstream might resolve never reaches it (the app creates no such names). A request body
  that arrives slowly is cut off after 20 seconds between two reads on REST and functions. `/health` answers the container's
  own check only; through the tunnel it is a 404. Response buffers are 0.5 MB a request (Kong: up to 10 MB) so that slow readers fit
  the 128 MB of the container; a larger answer is passed on as the client takes it (`docs/CONTAINER_SECURITY.md`, Memory).
- **Request bodies are streamed to the upstream** instead of being written to a file first, and a Storage download is passed on as it
  arrives, because the gateway's only writable place is a small memory-backed `/tmp`.
- **Built images are saved, and signed.** After a successful build `scripts/build-images.sh` writes the images it built to
  `<state>/images/<service>.tar` (`docker save`, about 2.5 GiB in all; skipped with a warning if under 5 GiB, or the size of the newest
  backup when larger, would stay free) with a copy of the build record, and `db:restore-host` loads them (`--images DIR`, or an `images`
  folder next to the backup) before the restore, so a lost-host rebuild does not need Debian, npm and Chrome for Testing (Docker Hub is still needed for the postgres and PostgREST images).
  The folder is signed like a backup (`SHA256SUMS` over every file, `SHA256SUMS.hmac` with the backup key) and `db:restore-host` loads
  nothing that does not authenticate with the key it is given: a folder named with `--images` is refused, one found next to the backup is
  ignored, and `--allow-unsigned` never uses saved images. A tarball whose save was skipped or failed, or that the record no longer
  names, is removed. The folder is not in a backup, but the USB backup copies it to the drive beside the archives (below);
  `bash scripts/build-images.sh --save` writes it for an installation that is already built
  ([docs/OPERATOR_INSTALL.md](docs/OPERATOR_INSTALL.md#backup-and-restore)).
- **Release images: built and scanned once by the release workflow, pulled by digest at a facility; the USB drive carries the saved
  images.** The `v*` tag workflow has a second job, `publish-images`: it builds every image with `--no-cache`, scans each with the
  repository's scan and exception ledger (a HIGH or CRITICAL row no valid exception covers fails the run before anything is pushed),
  pushes them to `ghcr.io/abhiguru/supabase-warehouse-template/<service>` and attaches `release-images.json` (each image by digest, with the
  fingerprint of its recipe) to a draft GitHub Release. `setup.sh` now runs `scripts/build-images.sh --from-release`: a checkout exactly at
  a release tag downloads that file and, for each image it would build whose recipe fingerprint is the released one, pulls the image by
  digest, checks the digest and records it as a build would; it prints which services were pulled and which built. The facility's
  build stays the fallback and is what runs for `main`, a branch or a changed recipe, when the file or `ghcr.io` cannot be reached, or when
  a digest does not match, each with one line that says why. What is scanned is what runs for a pulled image
  ([docs/CONTAINER_SECURITY.md](docs/CONTAINER_SECURITY.md), "Release images"). `scripts/backup-usb.sh` copies the saved images
  (`<state>/images`, signed with the backup key) to `warehouse-backups/<state name>/images` on the drive, once and again after a change,
  unencrypted (they hold nothing of the installation) and outside the archives; `db:restore-host` finds them next to the archive it is given.
  The enrolment output says how much room they add (twice that while the images change). The copy is the last step of a run: when it fails
  the archive copy still counts, pruning has already happened, and the run says "saved images NOT copied" (shown by `npm run doctor`).
  The release checklist gains the publication steps (public packages after the first push, the asset check, publishing the draft).
- **Release images carry their commit; a final release re-tags its candidate's images; the owner switches on immutable releases.** Every
  published image has the labels `org.opencontainers.image.revision` (the commit) and `org.opencontainers.image.version` (the tag);
  `build-images.sh --from-release` refuses a pulled image whose revision is not the checkout's commit (or has none) and builds it instead. A
  `vX.Y.Z` tag on the commit of its newest `vX.Y.Z-rc.N` builds and scans nothing: it re-tags the candidate's images by digest and lists
  the same digests, so what ships is what was scanned and rehearsed (the release checklist says what that means for a vulnerability
  published between the two). The checklist makes GitHub's immutable releases a step before the first candidate, and
  [docs/CONTAINER_SECURITY.md](docs/CONTAINER_SECURITY.md) states the trust honestly: the account, TLS, the digest, the immutable release and
  the revision label; there is no cryptographic signature of the images. A pull is stopped after 20 minutes
  (`WAREHOUSE_IMAGE_PULL_TIMEOUT`, seconds) and the image is built here; a host that is not x86-64 builds instead of pulling.
  `db:restore-host`, at a checkout exactly at a release tag, runs `build-images.sh --from-release` before the restore, so images the
  saved ones do not cover are pulled rather than built (`scripts/restore.sh` is unchanged). A pre-release is now recognised from the tag
  without its `+build` part.
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
  `daily_timer_legacy`. The gateway-log checks (`api_error_rate_high`, `api_latency_p95_high`, `api_429_rate_high`) read
  `docker logs -t --tail 5000` and cut to 5 minutes by the time stamps: `docker logs --since` returned nothing for any window up to
  an hour on a Docker 29.9.1 host, which would have kept them at "too few requests" for good (`tests/gateway-smoke.mjs` likewise).
- **Release channel, support window and `upgrade.sh`.** `upgrade.sh` ([Rerun and upgrade](docs/OPERATOR_INSTALL.md#rerun-and-upgrade)) with its upgrade record
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
- **Backup format v6: the stored files as a hard-linked tree with a signed manifest, and a short stop.** `db:backup` copies
  `data/storage` with `rsync -rptX --link-dest=<previous backup>/storage` into `storage/` (first pass with the API up, then the
  services stop for `pg_dump`, the catalog queries and a last `--delete` pass, then restart), instead of a gzip tar of every
  photo each night; `storage.manifest` (sha256 of every file) replaces `storage.tar.gz` in the signed `SHA256SUMS`, and
  `metadata.txt` records `link_base=`, `storage_files=`, `storage_bytes=`, `storage_new_bytes=`, `stop_seconds=` and
  `duration_seconds=`. The backup it links from must pass its own signature check (else the next older one is used, with a
  warning); a shared file whose bytes no longer match that backup's manifest, or cannot be read, is not linked: it is copied
  again from the live storage, the night ends ok with `WARNING: N files re-copied: backup <name> has a damaged copy` (daily status
  line, `rot_repaired=` in `metadata.txt`), and only a live file that does not match the recorded checksum either fails the night.
  The last pass of the copy goes into a new directory, so a change of extended attributes or mode made while the services are stopped
  never reaches a file that earlier backups share. `db:verify-restore`, `db:restore` and `db:restore-host` accept v5 and v6 (`backup_check_format`); the label must
  agree with the signed list; `db:verify-restore --no-storage-tree` checks everything except the hashing of the tree. `db:restore`
  copies a v6 tree with `rsync -rptX` and checks free space first; a v5 restore keeps `tar` (now with `--xattrs`). After either restore,
  once the services run, it looks at up to 20 restored files and, when any has no content type, runs the new `scripts/storage-retag.sh`
  (`npm run storage:retag`, `scripts/retag-storage-metadata.cjs` inside the storage container; `-- --if-missing` is the look at a
  sample first). `db:restore-host` checks the disk for an archive or a backup folder before copying it, and unpacks with
  `tar -p --xattrs` (modes kept). `doctor` checks for
  `rsync` (built with extended-attribute support) and GNU tar `--xattrs`: a refusal for `setup.sh` and `db:restore-host`, a warning
  for `start.sh`. The USB copy archives the whole backup folder as one self-contained archive, see [USB backup drive](docs/OPERATOR_INSTALL.md#usb-backup-drive).
- **A backup checks the free space first, and old backups are pruned whatever the verify says.** `db:backup` now refuses, before it
  stops any service or writes anything, when the disk of the backup folder has less free than it needs plus a reserve
  (`WAREHOUSE_BACKUP_RESERVE_MB`, 2048 by default). Linking from an earlier backup it needs twice the new stored files (and their
  folders) plus the database dump plus 256 MiB; with nothing to link from (the first v6 backup) it needs the whole photo tree once plus
  10%, plus the dump, plus 256 MiB. The free space is read with `df`, else with `stat -f`; if neither answers the backup is refused
  (the check is never silently off), and when `stat -f` had to stand in, the daily status line carries a warning. The numbers are the
  last line on standard error and in Slack `backup_failed`, and a backup that goes ahead records `preflight_need_mb=` and
  `preflight_avail_mb=` in `metadata.txt`. Until now `watch-daily.sh` skipped pruning and retention whenever the day's backup or its
  verify failed, which is when a full disk needed them most, and each failed attempt left another backup behind. The daily pass now
  prunes and applies retention after every attempt (only a database that is not running or not healthy ends it before them). A backup
  whose verify passed is written to `config/backups-verified.list`; pruning keeps the newest 7 backups **and the newest verified one**,
  however old, **and the backup that an interrupted `upgrade.sh` recorded as its way back**, so nights of failing verifies cannot push
  the last good backup out. The next backup links from the newest backup verified within the last two days, else from the newest one
  that passes its signature check, so failing verifies do not make every night copy the same new photos again. The failed-verify
  message in the daily status names the verified backup that is kept. The local restore points stay at 7. The first v6 backup needs room on the backup disk; otherwise nothing to do (the list fills at the first night that
  verifies; until then the newest 7 are kept, as before). TROUBLESHOOTING has an entry "backup refused: not enough free space".
- **Setup asks for the PDF letterhead.** A first `setup.sh --operator` without `--letterhead-file` asks on a terminal for the path of a
  JPEG or PNG (Enter means plain PDFs) and, with no terminal (a script or an agent running setup), refuses with "choose the PDF
  letterhead" until `--letterhead-file PATH` or `--letterhead-file off` is given, as for the Slack webhook. A rerun without the option
  asks nothing and keeps the letterhead; `--letterhead-file ask` asks on a rerun. CI passes `--letterhead-file off`.
- **Pooler on/off.** The pooler is only on when turned on (`bash scripts/pooler.sh on|off|status`); a new install has no pgbouncer
  objects, no `_supabase` database and no pooler secrets, and backups no longer contain `_supabase.dump` (old backups still restore;
  the file is skipped with a note).
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
- **Images: supabase/edge-runtime 1.77.8 and PostgREST 16.5.** Bug-fix releases of both (v1.77.4 and v16.4 before), pinned by digest as
  before; edge-runtime also updates its TLS library (rustls) and root certificates, which the functions use for outbound HTTPS. Nothing to do beyond the normal upgrade: `setup.sh` rebuilds the `functions` image (its recipe changed) and pulls the new `rest`
  image. The image-scan exception `rest-no-package-inventory` now names the v16.5 digest, and `THIRD_PARTY_NOTICES.md` the new versions.
- **Release and CI gates: the Chrome pin warns, the npm audit leaves the required check, base images are watched.** (1) A Chrome for
  Testing pin more than 14 days behind Stable no longer blocks a release tag, security backports included: `release.yml` runs
  `scripts/check-cft-freshness.mjs --mode warn` (a warning with the pinned and Stable versions and the age, always exit 0); the weekly
  `cft-freshness.yml` (`--mode fail`) keeps opening its issue, and that issue is the only signal (`docs/CONTAINER_SECURITY.md`, "PDF
  renderer", now states the renderer's threat model). (2) The live `npm audit` of `docker/storage` and `docker/pdf-renderer` is no longer in
  the required `validate` check: a pull request fails only for a HIGH or CRITICAL advisory it adds itself (`scripts/audit-compare.mjs`
  compares the change's audit with the base commit's, only for a tree whose manifests it touches), unless
  `docker/npm-audit-exceptions.json` covers it (reviewed, owner named, at most 90 days, an expired entry covers nothing; the ledger starts
  empty). The new weekly `dependency-audit.yml` runs the live audit and opens or closes one issue. (3) The new weekly `base-images.yml`
  (`scripts/check-base-images.mjs`) opens one issue when a pinned official base image (node, nginx, python, postgres, debian, ubuntu) is no
  longer published in its variant (node dropping `alpine3.23`, which Storage pins, is the first; nginx stopping 1.30; python dropping
  `slim-bookworm`) or its tag was last pushed more than 120 days ago. A Docker Hub rate limit (429) or outage is neutral; any other
  Docker Hub answer the check cannot use fails the run, so the age check cannot stop unseen. When one of these two issues is already open
  and a finding is new in it, the run adds one comment with only the new lines (an edit alone notifies nobody). The keep-alive
  workflow enables the two new schedules too. (4) The nginx pin test accepts any even minor from 1.30 in the `-alpine-slim` variant, so the
  yearly stable move needs no test edit. (5) The `functions` image runs `edge-runtime --version` once at build, so a base that no longer
  matches the binary's libc fails the build and not the start of every edge function; `setup.sh` rebuilds that image once (it already
  rebuilds for this release), and nothing else changes for an operator.

- **A maintenance calendar, host warnings and a collation check.** [docs/MAINTENANCE_CALENDAR.md](docs/MAINTENANCE_CALENDAR.md) lists every dated
  obligation of the next four years (renewals, end-of-life dates, the PostgreSQL move planned for 2029 H1), where each is checked and what
  happens if it is missed; forecasts are marked as such. The monitoring checker raises three weekly warnings that call no network:
  `cloudflared_old` (the installed version is 11 months old, or the tunnel still runs a replaced binary), `host_node_eol` (the host's Node.js
  major is within 60 days of its end) and `root_copy_stale` (a file installed with `sudo` was written by an earlier release; the USB-backup rule and
  unit and the checker, daily and boot units now carry a `# Recipe: sha256:` line, so `watch-timer.sh install` and `backup-usb.sh setup` are
  the commands the alert names after an upgrade). `node scripts/doctor.mjs` fails when the `postgres` database's recorded collation version
  differs from its C library's (`rotate-keys.sh` and `db:rotate-passwords` run that check first and refuse before changing anything), pointing at the new "Collation changes" section of `docs/OPERATOR_INSTALL.md`, which also records the rule that
  the database image's Debian base is never changed in place. See [docs/MONITORING.md](docs/MONITORING.md).

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
    (the clash query is in the git copy of the file, above); 118 customer names of only blanks refused, `delete_user_account` sets `disabled`;
  - 119 dead GoTrue-era functions dropped; 120 review fixes: a lost answer can be read back (`request_key`,
    `get_submission_result`, answers kept 7 days), cancelled invoices keep their lines, `NUMBER_TAKEN`, financial-year checks;
  - 121 owner decisions D1 to D24: stale edits (`STALE_RECORD`, `invoice.updated_at`, `get_grn_edit_state`), locks after invoicing,
    date rules, orders kept in step with dispatch edits, no invoice while stock remains, GRN history in `audit_log`;
  - 122 push review: lower-after-raise gives back what the order lent, a save of lines alone moves the version token.

### Fixed

- **Setup waits for the Docker daemon before refusing.** Right after a cold start of the host or of a WSL distro (or a Linux reboot),
  `setup.sh` and `doctor` stopped with "Missing or unavailable prerequisite: docker" because the daemon was not answering yet. When the
  docker CLI is there, `doctor` now retries the daemon check every 2 s for up to 60 s, prints one line while it waits, and then refuses
  with "Docker did not answer within 60 s; check `systemctl status docker`". A missing CLI or Compose plugin is still refused at once.
  The manual wait loop is gone from the Windows host section of `docs/OPERATOR_INSTALL.md`. A Linux operator need not act.
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
  `DB_PASSWORD_MONITORING` itself. The other leftover lines are in the git copy of the upgrade notes (`git show b45ae0b:CHANGELOG.md`).
