# Contributor guide

Orientation for changing this backend. Operator instructions are in [OPERATOR_INSTALL.md](OPERATOR_INSTALL.md); the README quickstart is the entry point for a new installation.

## Repository layout

- `setup.sh`, `start.sh`, `stop.sh`, `rotate-keys.sh`, `health-check.sh` — operator commands; each takes the per-state lock (`scripts/operator-lock.sh`) before touching Docker.
- `scripts/` — `configure.mjs` (state and config generation), `doctor.mjs` (host preflight, local and external checks), `migrate.sh` + `migration-plan.mjs` (checksummed ledger), `backup.sh` / `verify-restore.sh` / `restore.sh`, `backup-usb.sh` (automatic copy to an enrolled USB drive; see below) and `usb-backup-status.mjs` (its doctor warning), `backup-disk.sh` (second-disk alternative), `restore-host.sh` (rebuild a lost host from a backup), `tunnel.sh` (tunnel credential in the state, its systemd unit), `data-fingerprint.sh` (before/after restore comparison), `rotate-keys.mjs` + `keys.mjs`, `compose.sh` (project-owned Compose wrapper), `check-mobile-contract.mjs`, and the smoke/check scripts CI runs.
- `migrations/` — numbered SQL applied in order. `functions/` — Deno edge functions. `docker/` — Compose files and digest-pinned image recipes. `deploy/` — cloudflared examples. `config/` — seed SQL.
- `tests/` — node tests (`*.test.mjs`), SQL tests run by `tests/migrations.sh`, and the HTTP/Realtime drivers (`operator-api-*.mjs`, `operator-realtime-core.mjs`, `operator-fixture.mjs`) the CI install job runs against a live instance.

## Running checks

- `npm ci && npm test` — node unit tests; no Docker, no network.
- `bash tests/migrations.sh` — applies every migration twice to a disposable, network-isolated `supabase/postgres` container (the second pass must skip unchanged files) and runs the SQL tests. Needs Docker.
- `for f in *.sh scripts/*.sh tests/*.sh; do bash -n "$f"; done` — shell syntax, as in CI.
- `node scripts/check-mobile-contract.mjs <mobile checkout>` — static name inventory against the app (needs the app's `node_modules`).
- Everything else (`npm run test:gateway`, `test:rotation`, `db:backup`, ...) needs an installed operator state; CI exercises them in the `operator-install` job.

## Backup disk helper (`scripts/backup-disk.sh`)

- Subcommands: `status` and `plan` (read-only), `apply` (destructive, root, never self-escalates), `sync` (copies and verifies backups under the operator lock). `db:backup` is deliberately unchanged; its tests and warning text do not depend on this helper.
- Safety rules to preserve in any change: only a blank, whole, non-removable, unmounted second disk; refuse the system disk and the disk holding `data/` (fail **closed** if the system disk cannot be determined); never wipe, resize or shrink; confirmation comes from the disk itself (`--confirm-serial`, else `--confirm-size`); re-check right before writing; `sync` must prove the mount point is a real mount of a different device before writing anything.
- `tests/backup-disk.test.mjs` runs the script against PATH shims for `lsblk`, `blkid`, `wipefs`, `findmnt`, `sgdisk`, `mkfs.ext4`, `mount` and friends, so no test touches a device or the real `/etc/fstab`. The `WAREHOUSE_BACKUP_DISK_*` variables (mount point, fstab, sysfs) exist for those tests only and are printed by `plan`. The shims pin the `lsblk` argument forms (`-P` and `-r` are mutually exclusive in real `lsblk`; a real run once caught this), so change both together.
- **Not verifiable in CI:** the real `apply` path. Before a release that touches it, attach a spare virtual disk to a throwaway VM and run: `plan` → `sudo bash scripts/backup-disk.sh apply …` → reboot (the fstab entry must remount it) → `db:backup` + `sync` → `db:verify-restore` on the copy → `apply` again (must be a no-op). Also confirm `plan --device` on the system disk and on a partition is refused.
- **Direction:** pilot operators use the **USB drive** (next section). Keep `backup-disk.sh` working for hosts with a spare disk; do not extend it.

## USB backup drive

Decided for pilot installs: the operator attaches an **existing exFAT USB drive** and the system does the rest. exFAT because the install may run on Linux or in the Linux VM of a Windows host, and a restore must work on either; the drive is never partitioned or formatted, so existing files on it stay untouched. Archives are **not encrypted** (decision): anyone holding the drive can read every credential in `compose.env`, so the drive is kept locked away and a lost drive means `rotate-keys.sh --yes`. A drive kept on site does not close the off-host custody gate in [PRODUCTION_DEPENDENCIES.md](PRODUCTION_DEPENDENCIES.md); rotating it to another location does.

`scripts/backup-usb.sh` automates it. Layout and trust boundaries:

- **Root, installed once** by `sudo bash scripts/backup-usb.sh setup --state DIR --enroll /dev/sdX1`: copies the script itself to `/usr/local/libexec/warehouse-usb-backup` (root-owned, so root never runs code from the user-writable checkout; setup refuses a group/world-writable script), writes `/etc/warehouse-usb-backup.conf` (state, checkout, user, uid/gid, options), `/etc/warehouse-usb-backup.drives` (enrolled filesystem UUIDs), a udev rule with one line per enrolled UUID (`ID_BUS==usb`, `ID_FS_TYPE==exfat`) that adds `SYSTEMD_WANTS=warehouse-usb-backup@%k.service`, the template unit, and a scan service + daily timer (enabled only with `--daily`). `enroll`, `uninstall` and `status` complete the set.
- **The unit** runs `ExecStartPre=+helper mount %I` (root: re-checks USB/exFAT/enrolled, waits a few seconds for a desktop automount and uses it, otherwise mounts privately under `/run/warehouse-usb-backup/` with `uid/gid`, `fmask=0177`, `dmask=0077`, `nosuid,nodev,noexec`), then `ExecStart=bash <checkout>/scripts/backup-usb.sh run --device %I` **as the installation user**, then `ExecStopPost=+helper unmount %I` (always, also after a failure: `sync`, unmount every mount of the enrolled drive). The checkout path is baked into the unit: run setup again after moving or updating the checkout (`status` compares the helper with the checkout).
- **`run`** (installation user): refuses root, unenrolled/non-USB/non-exFAT/read-only drives, an unmounted drive, a mount on the data device, and a folder whose `.instance-id` belongs to another instance. It waits up to 15 minutes for the operator lock, runs `scripts/backup.sh` (which takes the lock itself), then holds the lock while it writes `warehouse-backups/<state name>/<backup>.tar` via `.partial` + rename, hashing the stream as written and comparing with a direct-I/O read back from the drive; writes `<backup>.tar.sha256`; never overwrites or deletes; extracts the newest archive into a private temp dir under the state and runs `verify-restore.sh` on it. It records the result in `<state>/config/usb-backup.last` (read by `scripts/usb-backup-status.mjs` for the doctor warning) and in `LAST-RESULT.txt` on the drive; a failed fresh backup still copies the existing ones but marks the run failed.
- Tests: `tests/backup-usb.test.mjs` runs every subcommand against PATH shims (`lsblk`, `findmnt`, `mount`, `umount`, `systemctl`, `udevadm`, `chown`, `id`, `getent`) and the fake `docker`; `WAREHOUSE_USB_BACKUP_ETC`, `_LIBEXEC`, `_RUN`, `_SETTLE`, `_LOCK_WAIT`, `_FRESH` and `_VERIFY_RESTORE` exist for them (`status` prints the first three when set).
- **Not verifiable in CI:** udev, systemd and the real mount. Before a release that touches them, on a VM with a real exFAT USB stick: `setup --enroll` (it needs `sudo` with a password prompt, so a human runs it in a real terminal unless the tester has temporary passwordless sudo; it does not start a run for the already-attached drive, and `journalctl -u 'warehouse-usb-backup@*'` says "No data available" until the first run) → re-plug → `journalctl -u 'warehouse-usb-backup@*'` shows the fresh backup, copies, read-back and verify-restore, and the drive ends unmounted → re-plug again (everything "already present") → plug an unenrolled exFAT stick (no run, still mounted by the desktop) → pull the drive mid-copy (only a `.partial` is left; the next run removes it) → `--daily` and `systemctl start warehouse-usb-backup-scan.service` with the drive attached → `uninstall`.

Manual fallback (same layout; for a host where `setup` cannot be run), as the installation user with the drive mounted by the desktop:

```bash
export WAREHOUSE_STATE_DIR=/srv/warehouse/<instance>
DRIVE="/media/$USER/<label>"            # lsblk -o NAME,TRAN,FSTYPE,LABEL,MOUNTPOINTS: TRAN usb, FSTYPE exfat
findmnt "$DRIVE"                        # must be a real mount, not a plain directory on the system disk
npm run db:backup                       # fresh backup; briefly stops write-facing services

set -euo pipefail; umask 077
SRC="$WAREHOUSE_STATE_DIR/backups"; DST="$DRIVE/warehouse-backups/<instance>"; mkdir -p "$DST"
for b in "$SRC"/warehouse-*; do n=$(basename "$b")
  [ -e "$DST/$n.tar" ] && { (cd "$DST" && sha256sum -c --quiet "$n.tar.sha256"); continue; }   # never overwrite
  (cd "$b" && sha256sum -c --quiet SHA256SUMS)                                                   # source intact
  tar -C "$SRC" -cf "$DST/.$n.tar.partial" "$n"; sync -f "$DST/.$n.tar.partial"
  (cd "$DST" && sha256sum ".$n.tar.partial" | sed "s/\.$n\.tar\.partial/$n.tar/" > ".$n.sha.partial")
  mv "$DST/.$n.tar.partial" "$DST/$n.tar"; mv "$DST/.$n.sha.partial" "$DST/$n.tar.sha256"
  (cd "$DST" && sha256sum -c --quiet "$n.tar.sha256")
done; sync

T=$(mktemp -d); tar -C "$T" -xf "$DST/<newest>.tar"                    # prove the copy restores
npm run db:verify-restore -- "$T/<newest>"; rm -rf "$T"
udisksctl unmount -b /dev/<partition>                                  # then unplug
```

- One `.tar` per backup keeps the 0600/0700 modes inside the archive (exFAT has no Unix permissions) and avoids exFAT name and attribute quirks. The `.tar.sha256` file lets anyone, on any OS, check the archive.
- Write only under `warehouse-backups/<instance>/`; never touch other files on the drive, never delete or overwrite an existing archive (a mismatching archive is a failure to investigate, not to replace).
- Using an archive (Linux, or the Linux VM of a Windows host with the USB device passed through): mount the drive, `sha256sum -c <name>.tar.sha256`, extract into `$WAREHOUSE_STATE_DIR/backups/`, `db:verify-restore`, then `db:restore` as in [OPERATOR_INSTALL.md](OPERATOR_INSTALL.md), **same instance only**.
- **Lost host: `scripts/restore-host.sh` (`npm run db:restore-host -- --state-dir NEW --yes BACKUP_DIR_OR_TAR`).** `setup.sh` on a new host mints a new identity that `scripts/restore.sh` (L58) refuses, so restore-host never runs setup. In order:
  - Validates everything first, creating nothing: `.tar` against its `.sha256` and its entries (only `<name>/`, regular files and directories), backup `SHA256SUMS`, format v4, migration ledger (the checkout's first `migration_count` files must reproduce the backup's `migration_fingerprint`, computed exactly like `scripts/backup-integrity.sql`), no container labelled with the project, `check-readiness.sh` and `doctor --host-preflight`. NEW must be absent or empty, symlink-free, outside the checkout, under a parent owned by the user.
  - Builds the state in `NEW.restoring-*` and renames it: the backup's `compose.env` with only `WAREHOUSE_DB_PATH`, `WAREHOUSE_STORAGE_PATH` and `WAREHOUSE_MANIFEST_PATH` rewritten, the backup's `instance.json`, and a copy of the backup under `backups/`.
  - Runs `restore.sh --yes --relocated`. `--relocated` (internal; not combinable with `--restore-config`) compares `compose.env` ignoring only those three lines. Every in-place restore already starts from an empty cluster, and the setup SQL (auth, SMS, storage, admin, operator) only changes the `postgres` database, which the dump carries. The `db-config` volume, which is not in backups, holds nothing the app uses (`vault.secrets` is empty).
  - Removes the empty `*.pre-restore-*` directories.
  - Tests: `tests/restore-host.test.mjs` (stub `restore.sh` for the command's own logic; real `restore.sh` for `--relocated`). CI "Lost-host restore drill" does it for real: backup, fingerprint, `compose down`, `docker volume rm <project>_db-config`, restore-host into a different path, identical fingerprint and integrity report, `operator-api-restore.mjs`.
  - Tunnel credential: carried when the backup has `tunnel/` (see below). restore-host copies it into `config/tunnel/`, rewrites `credentials-file:` to the new state, and prints `sudo bash scripts/tunnel.sh install-service`.
- **Tunnel credential in the state: `scripts/tunnel.sh`.**
  - `adopt --config FILE | --token-file FILE` (installation user) copies a locally managed `config.yml` plus its credentials JSON, or a dashboard token, into `config/tunnel/` (0700/0600) through a staging directory. It rewrites `credentials-file:` to the state copy.
  - `adopt` refuses: any `-----BEGIN` block (`cert.pem`, keys); an `origincert:` line; a credentials JSON whose `TunnelID` differs from `tunnel:` or that lacks `TunnelSecret`/`AccountTag`; a config whose `hostname:` lines do not include the host of `instance.json` `canonicalOrigin`; a multi-line token; an existing `config/tunnel`.
  - `install-service` (root through sudo, `SUDO_UID` non-zero, state owned by that user) writes `warehouse-<state basename>-tunnel.service`, the name the operator guide always used. It keeps a dated copy of an existing unit, then runs `daemon-reload`, `enable` and `restart`, and checks `is-active`.
  - `status` reports the credential type and whether the unit reads the state copy.
  - `backup.sh` copies `config/tunnel/{config.yml,credentials.json,token}` to `tunnel/` in the backup and lists them in `SHA256SUMS`; the format stays v4. `verify-restore.sh` accepts only those names as regular, checksummed files. In-place `restore.sh` leaves the running credential alone.
  - Tests: `tests/tunnel.test.mjs` (PATH shims for `systemctl`, `id`, `getent`; `WAREHOUSE_TUNNEL_UNIT_DIR` override, printed by `status`), plus tunnel cases in the backup, verify-restore and restore-host tests. The CI lost-host drill adopts a placeholder credential (fictional values, never run) and checks it after the restore. A real connector start is only exercised by hand.
  - Security: the credential lets its holder run a connector for the hostname, so a lost drive means replacing it (operator guide, "USB backup drive"). `cert.pem` must never be adopted.
- `scripts/data-fingerprint.sh` (read-only) prints a row count and SHA-256 per business table, the storage catalog and the stored files (hashed inside the storage container); compare before backup and after restore. It excludes self-changing tables (OTPs, rate limits, idempotency keys, audit log, materialized views, queues); `user_profiles` changes on sign-in, so take it before anyone uses the app again.
- VMware USB passthrough can drop a device; do not detach during a copy.

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
