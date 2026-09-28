# Scheduled local recovery backups

`scripts/scheduled-recovery-backup.py` creates a new v4 backup, runs the
disposable restore verifier, exports a new unencrypted tar to a UUID-pinned
filesystem, and validates the exported tar with safe intake. It records a
mode-0600 receipt containing the source snapshot time, archive hash and size.
Raw command output stays in a private run directory. Run it as the installation
user with Docker access; do not run it as root or place its configuration in
Git.

Before enabling a timer, ask the operator one input at a time for the exact
partition, mount point, archive directory and retention rule. Confirm that the
partition is mounted from the chosen UUID with private directory and file
permissions. The pilot's approved retention is **48 hours**, keeping at least
two verified generations. A new archive must pass every check before any old
job-created archive is removed. The job leaves unrelated files and archives
without its receipt alone. It refuses a missing or different filesystem so
files cannot silently fall back onto the root disk.

Create a mode-0600 JSON configuration outside Git with these keys:
`state_dir`, `source_checkout`, `recovery_secrets_dir`, `mountpoint`,
`mount_uuid`, `archive_dir`, `local_backup_dir`, `evidence_dir`,
`retention_hours`, `minimum_generations`, and `freshness_minutes`. The
private directories must be owned by the installation user and mode 0700.
Use `48`, `2`, and at most `50` for the final three pilot values. The script
rejects other retention or freshness values until a reviewed policy change.

From the pinned checkout, run `python3 -B
scripts/scheduled-recovery-backup.py PRIVATE_CONFIG check-config`, then one
`backup`, then `health`. The health action fails if the latest *source
snapshot* is older than 50 minutes, the archive hash changes, or the pinned
disk is unavailable. A 30-minute backup timer gives a margin before the
one-hour RPO. A separate health timer should run every 10 minutes and have a
delivered external alert connected to any failure or stale result. A local
systemd failed unit alone does not alert an off-host operator.

Run the service as the installation user, after Docker is available, with
`UMask=0077`. The example calendar expressions are
`*-*-* *:00,30:00` for the backup and `*-*-* *:00/10:00` for health.
Use `Persistent=true` for the backup timer. Verify the systemd expressions,
the resulting units and the next elapse time. A timer is not an assurance of
RPO until missed runs, unavailable media, full media, backup age and delivered
alert behavior have been observed. `db:backup` briefly stops write-facing
services, so measure the pause and schedule it with the operator.

This is a **local second disk** tier when its virtual disk lives on the same
physical host. The operator accepts it as the pilot destination for a VM or
system-disk failure while the host and backup disk survive. Physical-host
loss, theft, fire and shared-storage failure are excluded; covering those
would require an independent copy. The core v4 backup also excludes optional
monitoring and CUPS volumes. A single timed local rehearsal met the one-hour
simulated RPO and local RTO, but sustained backups, actual retention and public
recovery remain separate evidence. The operator deferred delivered alerts;
do not infer unattended RPO protection or cutover acceptance from this drill.
