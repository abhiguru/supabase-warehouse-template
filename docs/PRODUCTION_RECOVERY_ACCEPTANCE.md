# Production recovery acceptance

The [2026-09-27 replacement-host drill](REPLACEMENT_HOST_RESTORE_DRILL.md)
established that one local backup can restore in isolation. It did not test
off-host custody, a protected backup, a backup with existing objects, full
host loss, or cutover. Keep those results separate.

On 2026-09-28 the operator chose an **unencrypted off-host backup with an
explicit risk exception** for this pilot. This does not make the archive
confidential: anyone who obtains it can read warehouse data, role password
hashes and live service credentials. The exception does not waive access
control, physical custody, inventory, retrieval, retention or restore tests.
Record the exception in the final acceptance evidence; do not describe the
backup as encrypted or close a separate confidentiality requirement with it.

## Backup and custody gate

1. Agree on maximum acceptable data loss (RPO), maximum time to usable service
   (RTO), backup frequency, retention, custodian, and which optional volumes
   (monitoring, pooler, CUPS and other integrations) must be recoverable. Record
   the decision before claiming production recovery. Choose an off-host
   destination independent of the warehouse VM.
2. Put a representative, authorized document in private storage and nontrivial
   business data in the pilot, then record safe hashes/counts for the later
   comparison. Do not use a synthetic upload to claim recovery of an existing
   object. Schedule a quiet period: `db:backup` stops write-facing services
   while capturing database and storage, then restarts the services it stopped.
3. On the original host, use the reviewed code to run `db:backup` with
   `WAREHOUSE_STATE_DIR` set to the installed state. The v4 directory contains
   the logical database dump, storage archive, instance manifest, private
   Compose configuration, integrity output, role-name inventory and
   `globals.sql`. The globals file includes role definitions and password
   hashes. Every file is sensitive; keep the entire directory outside Git,
   owned by the installation user, mode 0700/0600. Run `db:verify-restore` on
   that backup. This disposable test does not replay cluster globals or prove a
   complete replacement host.
4. Prepare a separate 0700 `recovery-secrets` directory outside Git containing
   only the other credentials needed for the chosen recovery path, such as the
   dedicated tunnel credential and provider input. Make its files mode 0600.
   Inventory each file and its purpose privately. Do not place the account-wide
   Cloudflare certificate or credentials from another connector in this bundle.
5. For the operator's unencrypted exception, prepare an off-host destination
   whose parent directory is owned by the installation user and mode 0700.
   Keep the resulting archive mode 0600, on physically controlled storage with
   no public or shared-network access. The exporter refuses weak input
   permissions, symlinks, incomplete v4 backups, existing output files and
   checkout destinations. With the destination already mounted:

   ```bash
   bash scripts/export-recovery-backup.sh --plain \
     /private/path/warehouse-backup-v4 \
     /private/path/recovery-secrets \
     /off-host/private/path/warehouse-backup.tar
   ```

   The recommended encrypted alternative uses `--gpg` with an output `.tar.gpg`
   and a separately verified 40-character recipient fingerprint. Keep its
   private key off the source VM and destination. Record the exported file's
   SHA-256, backup creation time, transfer result,
   destination and retention record. Confirm that the file is retrievable from
   the other host after disconnecting the original VM. Do not copy an
   unencrypted archive to public or shared storage. The local unencrypted
   staging backup also needs a restricted retention and deletion policy.

## Replacement-host gate

The current manual sequence in the drill note is **not** a finished installer.
The reviewed intake step requires Python 3. On the replacement host, mount the
off-host media with private file permissions, verify the recorded SHA-256, and
run `python3 scripts/prepare-recovery-bundle.py ARCHIVE_TAR EXPECTED_SHA256
NEW_PRIVATE_DIR`. It rejects unsafe paths, links, duplicates, missing files,
bad checksums and storage-archive hazards, then writes only 0700 directories
and 0600 files. It starts no service and makes no network change. This intake
step alone is not a restore.

Implement a reviewed, fail-closed `restore` command that accepts only a
verified v4 bundle in new private state. It must inspect all tar
paths, links and duplicates; reject path or project collisions; validate and
deliberately remap saved absolute paths; reconstruct cluster-global roles and
settings before ACL replay; stage the database before promotion; and verify
instance identity, credentials, rows, sequences, document bytes, and access
controls. It must prove no outbound connection and no public listener before
loading live credentials or starting services. Test failures must leave
diagnostic evidence outside Git without disclosing secrets. Never run
`setup.sh` for a saved instance.

Exercise that command on another fresh host using only the off-host archive
(and independently held private key if encryption is later adopted). Test at
least two backups, including one
with nonempty documents and business data. Verify local health, restricted
document reads, administrator/customer boundaries without sending an OTP,
owned-service restart, unattended guest restart and physical-host restart.
Record exact source/image versions, backup age at recovery, usable-service
time, hashes, all failures and anything untested. Compare the measured RPO and
RTO to the approved targets. The earlier 27.7-minute preparation interval is
not an RTO measurement.

## Separate cutover gate

A controlled cutover requires its own authorization while the original pilot
is live. The plan must identify the original-writer freeze, final consistent
backup or delta, single active tunnel connector, route ownership, external
HTTPS/mobile/document checks, rollback triggers and data reconciliation. Do not
start the copied connector, alter DNS, or send an OTP as part of an isolated
restore rehearsal. Only close the production recovery ledger after the
off-host rehearsal meets its targets and the separately authorized cutover
checks pass.
