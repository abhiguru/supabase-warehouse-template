# Production recovery acceptance

The [2026-09-27 replacement-host drill](REPLACEMENT_HOST_RESTORE_DRILL.md)
established that one local backup can restore in isolation. It did not test
off-host custody, a protected backup, a backup with existing objects, full
host loss, or cutover. Keep those results separate.

On 2026-09-28 the operator chose an **unencrypted backup with an explicit
risk exception** for this pilot. It was first carried on a detached USB and
later configured on the accepted same-host disk. This does not make the archive
confidential: anyone who obtains it can read warehouse data, role password
hashes and live service credentials. The exception does not waive access
control, physical custody, inventory, retrieval, retention or restore tests.
Record the exception in the final acceptance evidence; do not describe the
backup as encrypted or close a separate confidentiality requirement with it.

The operator has set a **one-hour RPO and one-hour RTO** and supplied a new
backup virtual disk on the **same physical machine**. On 2026-09-29 the
operator explicitly accepted this disk as sufficient for the **pilot's scoped
recovery destination**, with the condition that the host and backup disk
survive a VM or system-disk failure. Independent off-host custody is waived
for that scope. Physical-host loss, theft, fire and shared-storage failure are
excluded from the accepted scenario; the local disk cannot recover them.
This is a scope and risk decision, not proof of the one-hour targets. The
prior restore intervals did not run from failure detection to externally
usable service, so they do not prove the RTO.

## Backup and custody gate

1. Agree on maximum acceptable data loss (RPO), maximum time to usable service
   (RTO), backup frequency, retention, custodian, and which optional volumes
   (monitoring, pooler, CUPS and other integrations) must be recoverable. Record
   the decision before claiming production recovery. A full-host-loss scope
   requires a destination independent of the warehouse host. For this pilot,
   record the operator's explicit same-host exception and excluded failures.
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
   checkout destinations. On exFAT, mount with `uid`/`gid` set to the
   installation user, `fmask=0177` and `dmask=0077`; `fmask=0077` presents
   files as 0700 and is rejected. Identify the device by filesystem UUID and
   verify the effective mount options before writing. With the destination
   already mounted:

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

### Operator choice of destination and overwrite policy

Ask for these inputs **one at a time, when each is needed**. Do not infer a
destination from an available disk, partition, automount, or example path.

1. Inventory disks, filesystem UUIDs, mounts, free space, ownership and existing
   files without changing them. Ask: “Which exact partition should hold the
   backups?” Show the operator its UUID, size, filesystem and current mount
   point. Confirm whether the partition is on the warehouse host or a separate
   physical machine, and whether any existing files must be preserved. Never
   format, repartition or erase a candidate as part of discovery.
2. Once the partition is identified, ask: “What exact directory on that
   partition should receive warehouse backups?” Require an absolute mounted
   path outside every Git checkout and database/storage data directory. Confirm
   it resolves to the selected filesystem UUID, has enough capacity, and can
   present owner-only 0700 directories and 0600 files. Do not use a permissive
   desktop automount for an unencrypted archive. Mount by UUID with restrictive
   options and verify the effective mount before writing.
3. Before deleting or replacing anything, ask separately: “May older warehouse
   backups in this directory be pruned, and what retention rule applies?” Record
   the exact scope, minimum number of verified generations, age limit, and any
   protected/manual copies. The safe default is **append-only unique timestamped
   filenames**. The exporter refuses an existing output file. Do not overwrite
   the latest good archive in place; create, checksum, restore-check and record
   the new one first. Apply an approved prune rule only to matching warehouse
   archives on the selected partition after a newer verified generation exists.
   Never overwrite unrelated files or infer permission to delete from the word
   “backup.”
4. A same-host second drive is a local recovery tier, not the independent
   off-host copy required for full-host recovery. Ask for a separate physical
   destination and custody plan before accepting that gate. For the approved
   one-hour RPO, design a schedule with margin for backup/transfer duration and
   missed runs, an alert for failed or stale backups, and a tested retrieval
   path. Do not claim the target from one manually observed backup age.

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

## Pilot execution checkpoint — 2026-09-28

The first v4 backup published valid files and passed a disposable restore, but
the command exited nonzero after Storage's first post-backup health check was
transiently unhealthy. Cleanup recovered the services. Review commit `5bae4e9`
adds a bounded retry for owned-service restart checks. A second v4 backup at
`2026-09-28T06:50:55Z` exited cleanly, passed local doctor and disposable
restore, and contained a private PDF already stored on the original pilot. Its
archived bytes matched SHA-256
`2219425cb01f43b44b541b24508b6bb45ea0d5f433c50b3004876e5d0832c789`;
anonymous download was denied and authorized download matched the source.

The operator-approved **unencrypted** USB copy on SanDisk filesystem UUID
`6A38-179A` is `warehouse-pilot-backups/warehouse-20260928T065055Z.tar`,
2,140,160 bytes, SHA-256
`f527d7fdf85b802d18f2e39f0083c4aef8b70276b1470232e2e53cc2e5e3d602`.
The exact USB copy passed hash verification, private safe extraction, nested
checksums and a disposable database/storage restore. The drive was unmounted
after the final hash check. The original pilot remained the only active
connector; no DNS, tunnel, OTP or cutover action occurred. These results close
the **backup-copy preparation** check only. The pilot still has no goods-receipt
rows, so representative business-data restoration and the full replacement-host
rehearsal remain open.

The [candidate v4 replacement installer and 2026-09-28 isolated VM drill](REPLACEMENT_HOST_RESTORE_INSTALLER.md)
subsequently passed cluster-global replay, staged database promotion, original
private-object bytes, local credentials/access controls, network isolation and
owned database restart recovery on the **previously used** replacement VM. It
does not close the clean-host, representative business-data, RPO/RTO, optional
volume, custody, confidentiality or separately authorized cutover gates above.

Subsequently, the operator reported that a clean Ubuntu host restored the
first USB archive with exact globals, 274 rows, nine sequences and the private
PDF, and that a second isolated restore on the now-used recovery VM restored a
new USB archive containing GRN `T2609281` and its single test-stock line with
matching IDs and values. Both reports say the drill services were stopped,
the USB unmounted and the original pilot left as the only connector. Detailed
raw evidence is private on the recovery VM and has not been independently
reviewed in this checkout. The second backup's observed age at verification
was 19 minutes 21.68 seconds. These results advance the replacement-data
rehearsal; they do not establish the approved **one-hour RPO** without a
recurring, monitored copy for the chosen failure scope. The same-host backup
disk was subsequently supplied, as recorded below. The **one-hour RTO**
remains unproven because
the full host-loss-to-usable-service interval was not measured. Retention,
physical-host restart, optional volumes and separately authorized cutover
remain open.

On 2026-09-29 the operator supplied a new 10 GiB virtual disk and chose
`/mnt/warehouse-backups/archives` with **48-hour retention**. The disk is
mounted by filesystem UUID with private permissions and a protected empty
mount point underneath. A local job now takes a new v4 backup every 30
minutes, verifies a disposable restore, exports a new unencrypted archive,
checks safe intake and archive hash, and keeps at least two verified
generations while pruning its own archives older than 48 hours. A separate
10-minute job fails locally if the latest source snapshot is older than 50
minutes or its archive hash changes. One direct run, one run through the
systemd service and the first automatic timer run passed; all three produced
private archives, and local operator health passed after each backup pause.
The unit tests cover stale backup,
missing mount, and safe pruning. A real 48-hour prune, unattended reboot,
media failure, and delivered external failure alert remain untested. The
second virtual disk is still on the original physical host. The operator has
excluded full-host loss from this pilot's recovery acceptance. The destination
decision for the narrower VM/system-disk-loss scope is **accepted**; the
one-hour RPO/RTO results, delivered failure alert, unattended reboot and an
end-to-end timed recovery remain open. Do not label the scoped decision as
full-host disaster recovery.
