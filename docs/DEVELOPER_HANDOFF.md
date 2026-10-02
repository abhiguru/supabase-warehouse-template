# Independent operator developer handoff

## Active VM-only campaign handoff — 2 October 2026

Use [VM_ONLY_ACCEPTANCE_20261001.md](VM_ONLY_ACCEPTANCE_20261001.md) and the mobile
[dated matrix](https://github.com/abhiguru/rn-warehouse-template/blob/codex/post-soak-session-tests/docs/OPERATOR_VM_ACCEPTANCE_20261001.md).
Campaign deadline is3October16:27:13UTC. This is an in-progress fictional VM
campaign, not release readiness. Production pilot/recovery hosts, SMS, public DNS,
tunnels, reboot, restoration/cutover, printing/sensors and ARM/physical tests are
outside its approved scope. Test1 is unchanged apart from read-only health checks.
Earlier installation history below does not authorize those excluded actions.

Application installation is pinned to `bed4eeee4a008073aa453c32da27cade50a32a2f`
with recorded overlays. Review source and optional helper tooling are separate;
current normal helper source is `71a7ac8` with delay disabled. Reproduce setup
from clean pinned source using a new empty private disposable state according to
[OPERATOR_INSTALL.md](OPERATOR_INSTALL.md), in dependency order: prerequisites,
private configuration, migrations, first administrator, identity/local doctor,
then fictional HTTPS discovery. Keep source readable by container users and
private state/configuration0700/0600. Record port/subnet/container overlays and
new genuine identities; do not copy credentials, stored documents or configuration
from an existing warehouse. The VM has eight CPUs/about17GiB; no new hardware is
needed. Preserve existing archives and both successful/failed attempts.

| Owned fixture | Installed checkout | Private state | Loopback gateway |
| --- | --- | --- | --- |
| Primary | `/home/jay/warehouse-backend-guide-check-2026100102` | `/home/jay/warehouse-state/core-backend-test-2026100102` |18080|
| Switching | `/home/jay/warehouse-switch-backend-2026100102` | `/home/jay/warehouse-state/cross-instance-test-2026100102` |18590|
| Same-origin replacement | `/home/jay/warehouse-replacement-backend-2026100103` | `/home/jay/warehouse-state/core-backend-test-2026100103` |18690|
| Compatibility rejection | `/home/jay/warehouse-compatibility-backend-2026100104` | `/home/jay/warehouse-state/cross-instance-test-2026100104` |19490|

For an owned fixture, use its installed checkout and state, never the review
worktree. These ordinary commands preserve warehouse data; they are a handoff,
not permission to interrupt an active native/soak actor:

```bash
cd /home/jay/warehouse-backend-guide-check-2026100102
export PATH=/home/jay/.local/opt/node-v22.23.3-linux-x64/bin:$PATH
export WAREHOUSE_STATE_DIR=/home/jay/warehouse-state/core-backend-test-2026100102
sg docker -c 'node scripts/doctor.mjs --local'
sg docker -c 'bash scripts/compose.sh ps'
# Start or stop only after ownership/run-release checks:
sg docker -c 'bash start.sh'
sg docker -c 'bash stop.sh'
```

Never use `down -v`, prune, state deletion, archive restoration or production
host commands. Replacement helper remains stopped; no old credentials may be
forwarded there. Warehouse records, credentials and successful documents are
preserved. The API-prepared concurrency receipt FXQ993 retains stock3; neither
FXQ994 norFXQ995 was committed. Three failed native attempts and their API
sessions remain retained; no fourth run or blind session cleanup.

Private campaign root is `/home/jay/warehouse-install-private/vm-campaign-20261001`.
Current core helper config is `helpers-primary-normal10.json`, unit
`warehouse-fixture-core-vm2026100110-normal10.service`, TLS18443/owned private IPC;
switch config `helpers-switch-return07.json` must be read from the recorded
fixture bindings before reuse, unit `warehouse-fixture-switch-vm2026100102-return07.service`,
TLS18444. Fault unit `warehouse-fixture-fault-vm2026100102-renew03.service`,
TLS18643, is DISARMED; config `helpers-fault-renew03.json` and its socket remain bound in the native
configuration. Read-only monitor22 covers current units. Inspect actual remaining
lifetimes before starting a bounded stage. All helpers retain twelve-hour caps,
Restart=no and real TLS/IPC readiness requirements.

```bash
sg docker -c '/home/jay/.local/opt/node-v22.23.3-linux-x64/bin/node /home/jay/warehouse-primary-helper-2026100110-concurrency02/scripts/fixture-service-supervisor.mjs /home/jay/warehouse-install-private/vm-campaign-20261001/helpers-primary-normal10.json status'
systemctl --user show warehouse-fixture-core-vm2026100110-normal10.service -p ActiveState -p SubState -p RuntimeMaxUSec -p NRestarts
# Stop only this owned helper after actor release; logs/state remain preserved:
sg docker -c '/home/jay/.local/opt/node-v22.23.3-linux-x64/bin/node /home/jay/warehouse-primary-helper-2026100110-concurrency02/scripts/fixture-service-supervisor.mjs /home/jay/warehouse-install-private/vm-campaign-20261001/helpers-primary-normal10.json stop'
```

Fixture switching observation tooling now optionally accepts
`observeAuthenticationPresence: true` for the independently guarded switching
bridge as well as the core bridge. It records only credential-presence booleans
for HTTP and Realtime upgrades; the safe route allowlist also identifies ordinary
`logout_session` completion without logging its body. Replacement authentication
remains core-only. Default behavior, ownership guards, Restart=no and the existing
12-hour caps remain unchanged. Eighteen focused proxy/supervisor tests passed.
This source change is not installed in the currently running switching helper;
native credential-forwarding acceptance remains open until a fresh supervised
helper and real bounded case produce independent evidence.

Starting again requires a new private helper config/runId/socket/log identity:
invoke the same supervisor with the new config and `start`, then verify actual
TLS/IPC readiness. Do not overwrite frozen config, replace a listener blindly or
extend RuntimeMaxSec. Mobile normal-route preflight uses
`native-config0110-normal10.json`; it passed along with cold Orders HTTP200 and
unchanged-state reconciliation. No Metro is needed.

Complete backend Node22 unit suite97/97 and redacted source/history scans PASS.
Exact CI37067498320 at review33825bd remains live at the inspected checkpoint;
its final result is not assumed. Mobile dependency and native gates remain open.
Final freeze/readiness/new eight-hour soak are unstarted; the older artifact's
completed soak stays separate. Dedicated natural expiry is unscheduled until an
eligible final freeze, new owned API30 AVD and ordinary reserved-account session
exist. No appointment may substitute the original AVD/session or altered expiry.


See the [consolidated backend installation candidate](BACKEND_CORE_ACCEPTANCE.md)
for exact version boundaries, backend verification and the closed recovery scope.
The running pilot update is a separate operator action.

Use [OPERATOR_INSTALL.md](OPERATOR_INSTALL.md) for the fresh Linux x86-64 host or
Windows/Linux VM installation. Current setup accepts `--operator` only. Keep
credentials and persistent state outside the checkout; obtain real MSG91 and
HTTPS settings for the selected warehouse before its integration test.
Read [OPERATOR_SETUP_NOTES.md](OPERATOR_SETUP_NOTES.md) for the dated VM findings,
resolved setup shortcomings, safe operator-question sequence and remaining edge
cases. The installation guide incorporates the prerequisites and configuration
traps discovered during that pilot.

[PRODUCTION_DEPENDENCIES.md](PRODUCTION_DEPENDENCIES.md#independent-operator-installation-work)
is the authoritative work and acceptance ledger. It distinguishes implemented
software, automated verification, unfinished software, and external or physical
acceptance. Green CI does not close the production handoff.

The backend operator changes merged in [backend PR #68](https://github.com/abhiguru/supabase-warehouse-template/pull/68)
and [mobile PR #33](https://github.com/abhiguru/rn-warehouse-template/pull/33).
Use the exact companion commit pinned in the active backend CI workflow when
reproducing a tested pair. Record both checked-out commits and the native build
ID in the VM acceptance record. Backend merge baseline is
`f18f51d4625e7f8c0d977ac69645804e318a9d49`;
[post-merge CI 36591024357](https://github.com/abhiguru/supabase-warehouse-template/actions/runs/36591024357)
passed all seven jobs. Mobile PR #33 remains draft at
`8240cce9121a797fd0cf2e00e568a61985814ddb`; do not substitute mobile `main`.

For the new VM, first run local setup and doctor, then verify HTTPS discovery
from warehouse Wi-Fi and cellular data. Verify real SMS login for the locally
bootstrapped administrator, pending customer enrollment and approval, and the
business flows. Reboot without an interactive login and verify reconnection.
Run the backup and isolated restore drill before loading real warehouse data;
replacement-host restoration remains a separate acceptance test.
The [2026-09-27 replacement-host restore drill](REPLACEMENT_HOST_RESTORE_DRILL.md)
records a successful isolated logical restore on a fresh VM, its failed attempts,
and the remaining off-host recovery and cutover gates. The original pilot stayed
live; that drill is not production recovery approval.

Printing and sensor capabilities stay disabled until their software and hardware
acceptance is recorded in the ledger. The existing image security findings remain
**won't fix in current scope**; they are not patched, passed, or an unconditional
production security approval.

[Historical source-demo handoff](SOURCE_DEMO_DEVELOPER_HANDOFF.md) preserves the
original exact commits and device evidence. Its installation commands apply only
to the historical code. Preserve the immutable `v0.2.2-demo` tag.
