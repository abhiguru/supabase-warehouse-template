# Replacement-host restore drill — 2026-09-27

An isolated restore of the pilot's backup **passed on a fresh Ubuntu 24.04 x86-64
VM**. It restored the database into persistent private state, started the core
services without external connectivity, and verified local health, saved instance
identity, credentials, database data, access controls, and service recovery.
This is evidence for one backup on one VM. **Production recovery is not accepted**:
the backup was local and unencrypted, contained no stored objects, omitted
optional monitoring/CUPS volumes and cluster-global role definitions, and no
cutover or external/mobile reconnection was attempted. The original pilot VM
remained live throughout. No DNS, tunnel, original services/data, or OTP provider
operation was changed or invoked.

On the original VM, read this note from a separate worktree or read-only clone.
Do not pull these documentation changes into a running checkout with uncommitted
pilot changes, replace its installed runtime, or rerun setup as part of reading
the handoff.

## Later rehearsal evidence — scope update, 2026-09-29

The September 27 results below are historical. Their empty-storage and missing
globals limitations must not be applied to every later archive, and later passes
must not be reassigned to this original attempt. Follow the
[installer procedure](REPLACEMENT_HOST_RESTORE_INSTALLER.md) and
[consolidated setup lessons](OPERATOR_SETUP_NOTES.md#replacement-host-recovery-lessons-2026-09-29)
for another attempt.

- The later clean-host rehearsal at detached `d8766b6` passed private intake,
  disposable restore and prepare/restore/build/cache/verify/stop. It matched
  globals, 274 rows across 113 exports, nine sequences and one private PDF,
  plus identity, access controls, internal isolation, ten services and owned
  database-restart recovery. The approximately 15-minute-10-second interval
  from disposable check through stop was not an approved RTO measurement.
- Later representative data included fictional receipt `T2609281`, one
  RECOVERY TEST line (quantity 2, stock 2, weight 10, rack TEST, package mark
  PILOT-NOT-PHYSICAL), zero dispatches/invoices/orders and one private object.
  Compare exact values and IDs against the selected archive, not this summary.
- The September 28 19:30:15 UTC archive used for candidate verification was
  2,150,400 bytes, SHA-256
  `0cfe1f2d029bc39bab2bbf2409b83f3aee9eb6fbe8e73074e26508780d5ee069`.
  Candidate author validation at full commit
  `2c8346b670953c0b91f796a703d18f4f31c1f9f4` matched 278 rows, 113 exports,
  nine sequences and the PDF. A reused VM and this retained archive do not
  establish a new clean-host or fresh one-hour RPO result.
- The September 29 public attempt passed disposable, prepare, restore, build,
  cache and verify, and its local exact-path PDF/denial checks. Public identity
  readiness failed, so that attempt did not prove public PDF delivery or expiry.
  The temporary connector, DNS record and tunnel were removed; proxy and drill
  containers stopped. The temporary object was removed, business rows and
  original object remained unchanged, and pilot DNS/identity comparisons passed.
  No pilot cutover occurred. Raw outputs and stage times remain private.

- Public attempt 02 reached matching identity using public DNS but stopped when
  a subsequent DNS lookup returned a negative answer. Its cleanup passed.
- Public attempt 03 passed after the diagnostic client used normal positive DNS
  caching bounded by the returned TTL. Public identity, signed PDF GET/HEAD,
  identical bytes, Cloudflare BYPASS/no-store, denied writes/alternate paths and
  expired-link denial (400, no PDF bytes) passed. The client retained TLS hostname
  verification and ran on the recovery VM; independent remote/mobile access and
  the default VM resolver remain unaccepted. The unique isolated-only test object
  was removed, original business/storage data remained unchanged, and all temporary
  route/tunnel/proxy/container resources were stopped or removed. Pilot DNS and
  identity were unchanged. Disposable through completed stop took about 5 minutes
  31 seconds on a reused VM with cached images, excluding prior failed attempts
  and retrieval; this is not an RPO/RTO measurement.

The verifier's author review found an additional quoted/non-ALL peer-ACL gap
beyond the initial owner/attachment/ACL findings. The candidate fix passed seven
failure-gate tests and a fresh isolated restore. This is author validation, not
independent approval. Keep the pinned installer and candidate review results
separate. Public/mobile reconnection, approved recovery objectives, independent
custody and single-writer cutover remain separate acceptance work.

## Partition review closure — 2026-09-29

The separate agent's three PR #77 findings (ownership, actual attachment and
complete peer ACLs) were reproduced and fixed. Author review then found a quoted
peer-grant bypass at `2c8346b`. A final check found another case: a new
Realtime-named standalone table owned by `anon`, with no grants, returned zero
reviewed grants and escaped inspection. Commit
`e91622a019d2cf5403ffe81e5fdaf1affd373c7a` checks every new daily table in
the live PostgreSQL catalog and requires its complete peer grant pattern,
including when the actual grant list is empty.

Seven focused failure-gate tests passed. A fresh private attempt using the retained
verified archive then passed disposable, prepare, restore, build, cache, verify
and stop in order. The full verifier again matched the original globals, rows,
sequences, storage bytes and role/access gates, with ten healthy services and
owned database-restart recovery; the drill project was stopped. Exact commands
and elapsed times remain in private evidence. This is an author review and local
runtime validation of the final candidate. The separate agent did not review the
later commits. Its original findings are closed as fixed, while independent
signoff of the final commit and promotion of the pinned installer remain separate
PR decisions. No new RPO/RTO or cutover claim follows from this check.

## Exact inputs and measured results

| Item | Result |
| --- | --- |
| Source | Cloned `codex/operator-install`, then detached at `80cc90b435d7fee6a13e0beb1e2931536e5d75cf`; source remained clean. The backup metadata names the pilot's older installed HEAD, whose local runtime changes are represented in this reviewed commit. |
| Host | Fresh Ubuntu 24.04.3 LTS x86-64 VM; noninteractive sudo verified before work. Host disks, mounts, listeners and running services inventoried first. |
| Prerequisites | Git 2.43.0, private Node.js 22.23.3/npm 10.9.9, Docker Engine 29.8.1, Compose v2.40.3, OpenSSL and util-linux. The agent selected its private Node 22 path explicitly; system Node 18 remained installed. |
| Source media | SanDisk USB filesystem UUID `6A38-179A`, remounted read-only. `Archive.zip` was untouched. |
| Backup | `warehouse-pilot-backups/warehouse-20260927T124556Z.tar`, 2,129,920 bytes, **unencrypted**. SHA-256 `46bd2989a18b5eb9463e91720f9fd60556ecce445612021df8f16d077303f20e` matched before extraction and on the private copy. Archive paths, types, links and duplicate names were inspected before extraction. Its internal checksums passed. |
| Disposable restore | The unmodified `npm run db:verify-restore -- BACKUP_DIRECTORY` passed in **78 seconds**, including the first PostgreSQL image download. This was completed before replacement-state preparation. |
| Replacement database | Successful logical restore with original object owners and ACLs: **10 seconds** for that successful attempt, excluding builds, preparation and earlier failed attempts. Every archived table row and sequence matched a fresh export; the repository integrity query matched. |
| Replacement preparation and checks | Preparation through final isolated checks took **1,660 seconds (27.7 minutes)**, including image builds, diagnosis and retries. It excludes host prerequisites, USB extraction and the disposable restore; this is not a production recovery-time objective measurement. |
| Restart | The repository's owned API/storage restart check passed. A database restart recovered all ten core containers with **30 seconds of stable health in 46.73 seconds** after the reviewed restart policy was restored. |
| Final state | All restored containers and the temporary local gateway forwarder were stopped. Private backup, restored state, images and evidence were retained outside Git. |

The backup contains a logical database dump, storage archive, instance manifest,
runtime configuration, provider settings and a dedicated tunnel credential. It
does **not** contain a ready-to-run PostgreSQL data directory. It had zero
storage object files and zero object catalog rows. That empty state was verified;
recovery of a pre-existing document could not be tested from this backup.

## Procedure established on the drill VM

The manual procedure and full attempt logs are in private, mode-restricted state
on the replacement VM. They are intentionally not in this repository because
they include rendered configuration, SQL exports, role password hashes or
unredacted runtime diagnostics. The following is the reproducible sequence and
the acceptance gate at each stage, not a general-purpose installer:

1. Verify `sudo -n true`; inventory disks, mounts, ports, services and available
   capacity. Locate the USB by **filesystem UUID**, remount it read-only, verify
   the operator-provided SHA-256, and inspect all tar entries and links before
   extracting into a new installation-user-owned 0700 directory outside Git.
   Keep extracted files mode 0600. Verify the nested `SHA256SUMS` and storage
   archive safety. Do not touch `Archive.zip`.
2. Check out the exact reviewed commit above. Read the operator docs and
   `scripts/backup.sh`, `scripts/verify-restore.sh`, `scripts/compose.sh`, and
   `start.sh`. Run `db:verify-restore` **first**. Do not run `setup.sh` against a
   saved instance; that is a new-instance bootstrap path.
3. Create a new private replacement state. Preserve the saved config and public
   manifest bytes except for deliberate remapping of `WAREHOUSE_DB_PATH`,
   `WAREHOUSE_STORAGE_PATH`, and `WAREHOUSE_MANIFEST_PATH` to the new state.
   Validate all other absolute paths. The saved tunnel credential path was
   remapped into an **inactive** config; no connector was started. Compare the
   manifest byte-for-byte and verify project name, origin, keys and state path
   consistency with `doctor --preflight` and Compose rendering before services.
4. Build the pinned core images with no live credentials. The Edge functions
   imported remote modules at runtime, so a credential-free dummy invocation
   warmed their module cache. The unchanged main/discovery functions were then
   proven to boot with networking disabled before restored credentials entered
   any running service.
5. Start only PostgreSQL on an internal Docker network, with no published
   database port and `cron.launch_active_jobs=off`. Initialize a fresh private
   PGDATA; create an independent staging database and restore the logical dump
   in pre-data, data and post-data sections with original owners. Recreate the
   missing `supabase_realtime_admin` non-login role from the exact pinned
   Realtime image definition, compare the archived role-name inventory, repair
   the extension-created GraphQL wrapper, then replay saved ACLs. The archived
   pg_net event trigger required a **temporary** bootstrap superuser state for
   its original owner; an exit trap revoked it. Complete role attributes and
   password hashes matched before/after. Promote the staging database only
   after the repository integrity output and every table row/sequence match.
6. Verify private SQL grants/RLS before starting APIs. Start only the ten core
   services on the internal network. The rendered config must have no host
   networking, privileged service, optional profile, public binding, or tunnel.
   Confirm the live containers actually use that network and that an outbound
   TCP probe fails. Run `doctor --local`, test saved public identity and keys,
   anonymous denial of business/secret access, service-role access, rejection
   of nonexistent/expired sessions, and private storage bucket settings.
7. Because this backup had no objects, upload a **synthetic** private PDF only
   for the drill. Its bytes survived API and database restarts; anonymous read
   failed and a short-lived signed download succeeded. Delete the synthetic
   object and prove no storage file remains. Compare application, security,
   authentication, migration and storage rows and sequences to the backup once
   more. This test is separate from recovering an existing object.
8. Stop every drill container and temporary gateway forwarder. Preserve backup,
   state and failure evidence; do not prune another project or delete the
   original VM's files. Cutover is a separate decision while the original
   writer is live.

The internal Docker network suppressed actual host port publication even though
Compose requested `127.0.0.1` for Kong. For host-side API checks only, the drill
used a temporary process listening on `127.0.0.1` and forwarding to the private
Kong bridge address. This process was stopped. There was no public gateway.

## Failed attempts and corrections retained in evidence

- The first configuration parser rejected saved quoted values with inline
  comments. Parsing was aligned with the repository reader; only the three
  approved filesystem path lines changed in the runtime copy. No service had
  started at this point.
- A private clone's umask made bind-mounted initialization SQL unreadable to
  PostgreSQL. Tracked source permissions were restored from Git to 0644/0755
  behind a 0700 parent. The failed PGDATA was retained; a new empty directory
  was initialized. Backup/secret file permissions were not relaxed.
- Database bootstrap alone lacked the Realtime administration role. The pinned
  image's role definition and memberships resolved the mismatch before replay.
- Owner-preserving replay first failed on the pg_net event trigger. Temporary
  bootstrap privilege was scoped to the isolated database and revoked before
  API startup; the role-attribute comparison passed.
- Bundling Edge modules alone did not cache every npm type dependency. A
  credential-free dummy runtime downloaded the missing dependency. An offline
  startup probe passed afterward.
- A temporary `restart: no` setting left Realtime stopped after a database
  restart. The original `unless-stopped` policy was applied to only the verified
  isolated core containers; repeat restart and stable health passed. The
  immediate doctor failure in the first restart attempt remains a failed result.

## What must be done before a production-recovery claim

1. **Backup completeness and custody.** Produce an encrypted off-host backup
   with a known creation time and protected decryption key. Include nonempty,
   representative document objects, all core configuration and secrets,
   tunnel/provider credentials held outside the core state, and a full
   PostgreSQL cluster-global role/settings capture. Inventory optional pooler,
   monitoring, CUPS and other required volumes separately. Approve backup
   schedule, retention, legal hold and key custody. Test independent retrieval
   and decryption on a clean host.
2. **Repeatable software.** Turn this VM-specific manual sequence into a
   reviewed, fail-closed replacement-host procedure. It must preserve instance
   identity, data, keys and ACLs; validate every host path and archive entry;
   stage the logical restore before promotion; reject collisions; prove
   isolation before credentials are loaded; and retain failures for diagnosis.
   Test it with more than one backup, including one with real objects and
   nontrivial business data. No available `setup.sh` path replaces this work.
3. **Full host-loss rehearsal.** On another fresh host, start with only the
   encrypted off-host copy and independently held keys. Verify representative
   row and object hashes, restricted document reads, administrative/customer
   access boundaries, local health, owned service restart and unattended
   guest/physical-host restart. Measure backup age at recovery and complete
   time to usable service against approved RPO/RTO thresholds. The 27.7-minute
   drill number above is not an RTO result.
4. **Controlled cutover, separately authorized.** While the original pilot is
   still serving traffic, do not start its copied tunnel connector or change
   DNS. A cutover plan must name the original-writer freeze, final consistent
   backup/delta, route ownership, one active connector, external HTTPS checks,
   document and mobile reconnection checks, rollback triggers and data
   reconciliation. Obtain separate authorization for the cutover and any OTP
   delivery test. Record measured recovery point/time and every failed test.

Optional monitoring and CUPS volumes are excluded from the core backup. Phone,
printer, sensor, cellular, external alerting, off-host recovery and physical-host
startup acceptance remain at their respective gates in
[PRODUCTION_DEPENDENCIES.md](PRODUCTION_DEPENDENCIES.md). A successful isolated
restore must not be represented as production recovery.
