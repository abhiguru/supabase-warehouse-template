# Independent operator developer handoff

## Current VM campaign checkpoint, 3 October 2026

The VM-only campaign remains incomplete, with deadline 16:27:13 UTC today.
Installed x86_64 APK2026100110 is application c422f62, SHA256
a7df6781bdcd889eb9ccaa01ee0973890effd4d187bb6ac45f100284e1b04b69; backend
application remains bed4eeee plus declared overlays. See the dated acceptance
matrix for exact native scope. No final freeze, new eight-hour soak or dedicated
natural-expiry appointment exists. Historical results below do not transfer.

Current original owned API30 emulator is logged out after genuine Customer A
normal logout and two cold login requirements. That account remains active;
its two older API sessions remain preserved. The earlier native login and role
controls passed; their removed native session must not be assumed present.
The prior supervisor session804 was removed by normal logout; that account remains
active. Customer B remains rejected/inactive and must not be reapproved to reuse
historical acceptance. Private current A login/receipt denial/image and PDF API
proofs are under the campaign root. The final A-to-B native receipt-denial attempt
passed; its two failures remain preserved and no fourth attempt is allowed.
API image and PDF denial preserve the current native session and actual stored
bytes; they do not establish native image rendering or full reciprocal isolation.

Latest complete fixture source validation passed325/325 under Node22.23.3.
Revalidated source audits report26 high mobile dependency paths and8 high
backend metadata paths, rooted in unpatched node-forge/braces advisories.
Do not use audit fix --force, downgrade Expo/nodemon or waive gates. Backend
storage busboy3.2.2 patch is source-only, not installed container acceptance.
The installed application remains bed4eeee plus its four declared overlays.
No final freeze, readiness soak or delayed-expiry appointment is eligible yet.
Core helper14 uses pinned e3126a0, switching08 uses7699364, and fault04 is disarmed.
Core's single-use Orders delay controller is consumed; normal traffic is restored.
Each helper retains its12-hour cap; verify actual remaining lifetime before work.

Current read-only monitor is `warehouse-vm-campaign-monitor-20261001-27.service`,
frozen tooling e1194f8, private root
`/home/jay/warehouse-install-private/vm-campaign-20261001`. Its configuration is
`monitor27-config.json`, output `monitor27.jsonl`, transition record
`monitor27-transition.json`. First full integrity pass checked all 7,848 bound
files: no unreadable input/current/older-soak failure; 17 historical changes
remain recorded. The prior 4,096-file limit was insufficient; the corrected
finite limit is 16,384 with the unchanged 256-stage limit. Prior monitor26 logs
are preserved. Restart is disabled and lifetime ends at the campaign deadline.

Health: `systemctl --user status warehouse-vm-campaign-monitor-20261001-27.service`.
Stop: `systemctl --user stop warehouse-vm-campaign-monitor-20261001-27.service`.
Use the recorded supervised invocation and remaining deadline to start a new
identity; do not resume old transient identities or extend the campaign.
Current core14, switching08 and fault04 helpers retain their own twelve-hour
caps; the core Orders controller is consumed and the fault relay disarmed.
No helper, emulator session or business state was changed for this correction.


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
Current core helper14 source is `e3126a0`; switching08 source is `7699364`.
The core single-use Orders delay controller is consumed; optional credential-presence
observation is enabled only for the fictional bridges. Reproduce setup
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
Current core helper config is `helpers-primary-normal11.json`, unit
`warehouse-fixture-core-vm2026100110-normal11.service`, TLS18443/owned private IPC;
switch config `helpers-switch-observe08.json` must be read from the recorded
fixture bindings before reuse, unit `warehouse-fixture-switch-vm2026100110-observe08.service`,
TLS18444. Fault unit `warehouse-fixture-fault-vm2026100110-renew04.service`,
TLS18643, is DISARMED; config `helpers-fault-renew04.json` and its socket remain bound in the native
configuration. Read-only monitor23 covers current units. Inspect actual remaining
lifetimes before starting a bounded stage. All helpers retain twelve-hour caps,
Restart=no and real TLS/IPC readiness requirements.

```bash
sg docker -c '/home/jay/.local/opt/node-v22.23.3-linux-x64/bin/node /home/jay/warehouse-switching-helper-2026100110-observe01/scripts/fixture-service-supervisor.mjs /home/jay/warehouse-install-private/vm-campaign-20261001/helpers-primary-normal11.json status'
systemctl --user show warehouse-fixture-core-vm2026100110-normal11.service -p ActiveState -p SubState -p RuntimeMaxUSec -p NRestarts
# Stop only this owned helper after actor release; logs/state remain preserved:
sg docker -c '/home/jay/.local/opt/node-v22.23.3-linux-x64/bin/node /home/jay/warehouse-switching-helper-2026100110-observe01/scripts/fixture-service-supervisor.mjs /home/jay/warehouse-install-private/vm-campaign-20261001/helpers-primary-normal11.json stop'
```

Fixture switching observation tooling now optionally accepts
`observeAuthenticationPresence: true` for the independently guarded switching
bridge as well as the core bridge. It records only credential-presence booleans
for HTTP and Realtime upgrades; the safe route allowlist also identifies ordinary
`logout_session` completion without logging its body. Replacement authentication
remains core-only. Default behavior, ownership guards, Restart=no and the existing
12-hour caps remain unchanged. Eighteen focused proxy/supervisor tests passed.
The fresh core/switch helpers now include this tooling. Actual TLS/IPC readiness
and exact before/after protected warehouse and stored-byte reconciliation passed.
The initial fresh-relay IDLE-versus-DISARMED assertion failed and remains preserved;
a separate completion verified no observations and initialized only that new relay.
Old units/configurations/logs remain preserved. The original app is stopped
without logout, and no native confirmation or authentication occurred. Native
credential-forwarding acceptance still requires a real bounded case.

Starting again requires a new private helper config/runId/socket/log identity:
invoke the same supervisor with the new config and `start`, then verify actual
TLS/IPC readiness. Do not overwrite frozen config, replace a listener blindly or
extend RuntimeMaxSec. Mobile normal-route preflight uses
`native-config0110-normal11.json`. The earlier normal10 cold Orders HTTP200 proof
remains historical; the fresh helper transition proves unchanged state, TLS/IPC
and supervision. Native route/cold health must be verified on the new stage. No
Metro is needed.

Complete backend Node22 unit suite98/98 and redacted source/history scans PASS.
Exact CI37069464095 at071806b completed successfully. New exact CI37071784558
at7699364 remains live at the inspected checkpoint; its final result is not assumed. Mobile dependency and native gates remain open.
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

Fixture-only confirmed Orders hold tooling (not installed): optional
confirmedOrdersReadDelayMs=30000 is separate from the existing <=5000ms
ordersReadDelayMs. It matches only authenticated POST get_orders_list at
backend-core.example.test forwarded to127.0.0.1:18080, with no query. Writes,
discovery, refresh, foreign hosts, replacement and other state/routes cannot
match. Supervisor requires a separate core helper, auth-presence observation
and no other delay/concurrency mode, retaining RuntimeMaxSec43200/Restartno.
Only a matching read gets a45-second transport deadline; original request
deadlines and delay bounds remain unchanged. Genuine buffered response bytes
are held for exactly30 seconds and cancelled on normal connection closure.
25 focused transport/supervisor tests and101 complete source tests passed with
the documented edge-import loader. The initial full-suite invocation omitted
that loader and failed two imports; private failed log is preserved separately.
No running helper, APK, database schema or application API changed. Native
confirmed in-flight switching remains NOT TESTED pending guarded installation,
actual timing, same-process continuation and normal-route cleanup/reconciliation.

Confirmed in-flight Orders attempt01 FAIL, preserved. The separate pinned
helper da5c75c was installed as core confirmread12 only after preserving old
normal11 configuration/logs, stopping the owned app without logout and proving
identical two-warehouse snapshots plus actual TLS/private IPC readiness.
Switch observe08 and disarmed fault renew04 remained unchanged; monitor24
covers the new owned units. Native frozenf6dc954 attempt01 stopped at the
explicit Refresh orders phase before confirmation: zero confirmations, business
submissions and OTP requests. Actual helper metadata shows overlapping
automatic successful held Orders reads, including a start before the explicit
request timestamp; the intended single pending read was not established.
The first-stage FAIL is retained. App was subsequently stopped without logout
under its actor lock, and independent stopped reconciliation passed protected
source state, source session identity/fixed dates, destination state and stored
bytes. Private confirmed-orders-read-switch0110-01-stopped-reconciliation.json
records owned-session hash/history comparisons separately. No blind request
replay, OTP, logout or business cleanup occurred. A corrected one-shot armed
read helper is required before using at most two remaining corrected attempts.
Actual in-flight confirmation/destination continuation remain NOT TESTED;
current app is stopped and current core helper still has the bounded hold.

In-flight Orders attempt02 preserves native FAIL but independently reconciles
the actual guarded refusal. Fresh pinned e3126a0 core confirmread13 passed
sequential ownership/TLS/private IPC and identical before/after warehouse
snapshots; monitor25 covers it. Single-use private arm created one safe read
identifier. Actual read started00:25:08.135UTC, confirmation was attempted
00:25:32.102007UTC, and genuine HTTP200 completed00:25:38.136UTC. The app
source/compiled candidate's operation guard refuses activation while a request
is active. Read-only actual screen capture showed Operation In Progress and
Finish the current operation before switching servers. No source logout was
observed, primary public selection remained intact and independent entire
source/destination/auth/storage reconciliation passed exactly unchanged.
No OTP or business submission occurred. The owned app was stopped without
logout after preserving its screen/selection. Core controller is consumed;
subsequent reads are normal and it cannot be rearmed. Failed first ADB public
selection query quoting produced incomplete input before any mutation; the
corrected read-only query used shell quoting and passed.

Private proofs: confirmed-orders-read-switch0110-02-independent-refusal-proof.json
and confirmed-orders-read-switch0110-02-independent-timing-proof.json. These
preserve originalNativeStatus=FAIL and do not claim a completed server switch.
Alert appearance before read settlement was not recorded precisely enough.
Final allowed corrected attempt03 must expect the documented refusal, record
the actual alert during the held read, reconcile unchanged selection/session,
then verify normal-route cold reads. No application behavior needs relaxing to
make the switch occur; earlier successful header-draft switches were idle.

Literal-staff APK10 check (3 October): ordinary login and logout PASS; cold
Orders200/no Queue PASS, GRN denied with Staff access required. Mobile/backend
permission-policy mismatch remains BLOCKED. Normal administrator API restored
reserved profile947 to active/approved supervisor; no target native session,
original emulator logged out. Business/assignments/other accounts/stored bytes
preserved. Role-cycle hash qualification and failed attempt retained privately.
Reviewed fixture tooling7b717d0 has328 passing source tests.
