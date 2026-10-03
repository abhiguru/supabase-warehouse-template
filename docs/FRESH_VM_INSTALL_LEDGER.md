# Fresh VM installation and acceptance ledger — 2026-09-30

This ledger records this Ubuntu/VMware installation, including the operator's
later unattended fictional-fixture/emulator scope. It is evidence for the
specified source/artifact and environment only. Preserve this dated record:
append new attempts rather than rewriting failures or transferring a PASS to a
new APK, device or production instance. Consult it before running checks again.
Repeat only when the source/configuration/artifact changed, a prerequisite
changed materially, a failure remains unresolved, or an explicitly required new
acceptance scope is being tested. Successful compilation is not end-to-end
acceptance. No release or merge is authorized by these results.

## Exact sources and artifacts

| Role | Source / installed modifications |
| --- | --- |
| Requested and installed Test Warehouse 1 backend | `f18f51d4625e7f8c0d977ac69645804e318a9d49`; remote available; PR68 merged. Source content unchanged; public checkout permission metadata corrected to readable files/executable scripts. Private configuration/instance state generated separately |
| Requested mobile candidate | `8240cce9121a797fd0cf2e00e568a61985814ddb`; remote codex/operator-mobile and draftPR33 verified. Mobile main272e434844b58d68fd714023a6ae11885a0f1a21 was different; no substitution |
| Installed physical test APK | Mobile `8d9da8ecb3afb873422011cce4c6615b63163a88`, derived from candidate plus review fixes; generated native identity `in.gurucold.warehouse.test1`, label Test Warehouse 1, scheme warehouse-test1. Version0.1.0/code2026093001; arm64-v8a; test debug signer |
| Tested unattended backend | `ee5b4936e2aa644667fe617f79e2a48b2eb67bbb`; separate owned fictional state. Declared local CI Docker network overlay10.233.245.0/24; private gateway18080; loopback TLS/mock-delivery bridge18443. Installed Test1 retains18000 |
| Pre-pause tested emulator APK | Mobile `43b832092bb8157e73b012add6a57f2e6dd724a1`; `in.gurucold.warehouse.fixture`, Fictional Core Warehouse, warehouse-fixture, version0.1.0/code2026093005, x86_64. Generated native identity and restricted public fixture CA trust overlay; private CA key excluded. Actual Edge verifier used with generated fixture codes via protected local IPC; no SMS call or code in HTTP/logs |

Physical APK SHA-256:
`969d4fba6f21b7940897fb67aa8d09174f9e33cf376c964f4798ff96b15c25d4`.
Pre-pause emulator APK SHA-256:
`c9a8052dff9834a9450c8afa82a22911cda4332222b7fc128699d15c16dd68fe`.
Both passed their exact artifact audit/signature/package checks and installed
read-back comparisons. The physical phone remains on8d9da8e; later source fixes
and emulator results do not update or close its acceptance.

Earlier fixture94ead7e/code3002 and rebuilt943ab86/code3003 failed the artifact
audit on a public .pem resource. An earlier PASS report was inaccurate and is
explicitly corrected; the first APK had already been installed and its UI
observations remain historical. The failed rebuilt APK was not installed.
The unchanged audit passed after packaging the public CA as .crt, with a
meaningful positive/negative overlay regression. Prior audited d4540c8/code3004,
SHA `f8f1ad67bfea96bf3b286b78103f0b9df1b04cff1398ecb0f26eb1f0c5817ed7`,
retains its own image-upload and expired-access-refresh evidence. Failed APKs,
raw logs and prior metadata remain private; gates were not weakened.

## Resumed current source and artifact boundary

The physical phone still has8d9da8e/code2026093001 and was untouched during the
resumed unattended run. The currently installed emulator is review source
`e54c8268f6f5dd67652d3779d2b4a111292a59fa`, fixture code2026093007/x86_64,
SHA `f8ed582a6e37398cab49c0682c6d377a39f4b17249c1f6d04315b42f8c95dfe7`.
Clean build11m6s/983 executed, exact audit/signature/package/install/read-back PASS.
It retains the declared generated identity and restricted public CA overlay.

Separate normal Test1 arm64 build from the same e54 source, code2026093008,
SHA `7ad6e19aee694865a4fdcc9753fddb19ddd5bce317f39e4da56d08464935fb3e`,
passed the revised guide from a clean checkout, build11m8s/983 executed and exact
audit/signature/package checks. No fixture CA overlay. It is NOT INSTALLED;
physical read-back/native acceptance for that exact APK remains open.

## Environment and checks

Ubuntu24.04.3 x86_64 VMware; effective noninteractive sudo verified. Git2.43.0,
Node22.23.3/npm10.9.9, Docker29.8.1/containerd2.3.6, Compose2.40.3v2;
effective Docker access through `sg docker -c`. Ownership, port and memory/disk
inventory preceded mutation. Initial5.7GiB host build did not establish completion;
resumed host17.2GiB completed builds. We did not reboot or resize the VM.
JDK17.0.20.1, Android command-line tools22.0, SDK/build-tools36, NDK27.1.12297006,
Gradle8.14.3; documented supplementary35/NDK27.0/CMake versions installed.
ADB37.0.1-15733141. Selected phone SamsungSM-A346E, Android15/API35, arm64-v8a;
serial remains private. Emulator37.1.11/build15917651, API30 default x86_64 rev11,
software SwiftShader with no KVM/VMX/SVM. API35 Google APIs rev9 was unstable.

| Backend required case | Result | Evidence / limitation |
| --- | --- | --- |
| Host prerequisites, effective sudo/Docker, versions/ports/ownership | PASS | Fresh inventory; dependencies installed as documented |
| First literal setup | FAIL | umask077 public checkout made98-webhooks.sql unreadable by container; later pg_isready was misleading. Failed state retained/stopped |
| Corrected setup, local/public doctor and public identity | PASS | Readable source, new independent Test1 state, dedicated HTTPS hostname; local/private services only |
| Ingress occupancy/isolation | PASS | Selected DNS unoccupied, preexisting tunnels retained; only new dedicated tunnel/hostname configured |
| Same-input Test1 setup preservation | PASS | Private config/manifest hashes, administrator, database OID, document metadata/bytes unchanged |
| Baseline unit run under077 | FAIL |47/48; deliberately insecure test file became0600 due umask |
| Corrected unit tests | PASS |48/48 under077 and022; explicit test fixture chmod0644; runtime private-file guard unchanged |
| Locked dependencies, migration/auth/billing, shell syntax, contracts and source/history scans | PASS | Exact source/command evidence in setup notes; current43 mobile contract checked locally |
| Current container dependency audit | FAIL | Historical Storage undici7.29 HIGH/ip-address MODERATE; resumed18b5317 CI now fails metadata brace-expansion HIGH/fast-uri MODERATE before Storage. Existing findings/gates preserved |
| Initial fixture image pull | FAIL then PASS | DNS lookup/pinned image pull initially failed, later succeeded with no DNS/source changes |
| Real administrator/customerA OTP, pending registration/approval/login | PASS | Test1 only, operator explicitly authorized SMS; OTP entered locally, no plaintext code recorded |
| Refresh, replay/logout, expired access denial/legitimate refresh | PASS API | Real installed Test1 and disposable fixture evidence; native scope below |
| Fictional receipt/inventory/idempotent retries | PASS | Test1 and isolated API fixture;100 bags×10kg receipt; repeated request preserved first result |
| Cart/order/staff queue | PASS API | A cart7, order/queue and isolation checks; native current cart result below |
| Partial/final dispatch and retries | PASS API |20→80 balance, then80→0; retry did not subtract again |
| Invalid quantities and concurrent stock | PASS API |negative/0/excess denied; two concurrent7-of10 requests produced one success and stock3 |
| Fictional billing/invoice reconciliation | PASS API |subtotal950, tax48, total998 according to documented fictional example; no invented production rule |
| Private PDFs | PASS API |Receipt/dispatch/invoice/stock PDFs valid; authorized signed downloads, foreign/anonymous reads denied |
| Customer A/B isolation | PASS reciprocal fixture; installed scope partial | Fictional guarded fixture tested both directions. Installed A→fictionalB denial passed; real reciprocalB authentication BLOCKED: no third owned phone |
| Image lifecycle/privacy/retries/oversize/deletion | PASS API |Real Test1 fictional files and isolated fixture; not proof of physical native upload |
| Customer Realtime and bad-token denial | PASS API after initial FAIL |Initial installed join invalid_byte/timeouts retained; later fresh join/update/reconnect and bad-JWT rejection passed without source change |
| Default Python public probe | FAIL |Cloudflare403, root cause unestablished; Node/curl/Android-like/public doctor succeeded. No WAF bypass |
| Clean corrected installation/revised guide repeat | PASS after preserved disk-guard FAIL |Clean ee5b493 checkout, new suffix04 state, declared network/port overlay, setup and doctor; private same-input comparison preserved identity/credentials/admin/database and at least4 stored PDFs |
| Recovery/archives/cutover/reboot, printing/sensors/iPhone/external alerts/rotation/image research | NOT TESTED; outside scope |Closed or explicitly deferred; existing release gates retained |

| Historical Android required case (superseded only by explicit resumed rows below) | Physical8d9da8e | Audited emulator43b8320 / limitation |
| --- | --- | --- |
| Dependencies/setup/unit/lint/type/contract/compatibility/Doctor | PASS |PASS:36 setup tests,217 Jest/33 suites, lint0errors/1468 existing warnings, typecheck, SDK compatibility, Doctor18/18, public bootstrap and contract |
| Dependency audit | Earlier PASS retained |Final43 PASS0; intervening FAIL3 packages retained, targeted compatible lock updates for brace-expansion/fast-uri/moment |
| Clean native build, audit and exact installation bytes | PASS |PASS x86 code3005,11m37s/983 tasks executed; separate normal arm64 final build recorded below |
| Manual server selection and displayed identity | PASS |PASS fixture discovery/current saved selection, restricted TLS CA/hosts-label/reverse overlay documented |
| Malformed HTTP/path origins | PASS scoped |Earlier initial fixture observations do not transfer to final43; other malformed variants NOT TESTED |
| QR selection with real camera | PASS |NOT TESTED emulator; initial invisible QR window FAIL retained, visible fullscreen viewer scan later passed |
| Cold launch and lifecycle/server persistence |PASS unauthenticated cold/Home, authenticated Home |Current43 saved session restore PASS, resumed cold probe FAIL behind SystemUI ANR; explicit Wait recovered separately. Full physical authenticated force-stop NOT TESTED |
| No Metro / no USB standalone |Metro absent observed; no-USB NOT TESTED |Bundled APK, Metro absent; ADB reverse required for local fixture, so no-USB NOT TESTED |
| Administrator login |PASS real SMS/current phone |PASS fixture actual verifier; no provider/SMS acceptance implied |
| Customer login/permissions/cart |NOT TESTED native |PASS fictionalA, Customer role/staff controls omitted, only A Orders, native cart quantity1 persisted |
| Fresh pending enrollment and native approval |BLOCKED no third real phone |PASS fourth fictional account had no refresh session; native admin assigned only A, saved assignment checked |
| Logout/revoked sessions |NOT TESTED native |PASS current43 native logout and prior admin refresh-session revocation |
| Expired access/legitimate refresh |NOT TESTED native |PASS prior auditedd4540c8: verification age4339s exceededTTL3600, hash rotation/no extra OTP; final43 NOT TESTED |
| Native receipt/partial-final dispatch/invoice creation |NOT TESTED |Current43 receipt/partial PASS after resume; final-draft attempts FAIL before submission; invoice creation NOT TESTED. New e54 fix/artifact validation pending; API results separate |
| Stock/dispatch/invoice display |NOT TESTED beyond dashboard |PASS scoped: current43 BAA01 stock0/100 and BAC01 stock3/10; invoice998 displayed on earlier artifact, not transferred |
| Native image upload/render |NOT TESTED |Prior d454 upload retained; current43 upload PASS after resume with confirmed WebP/storage object, existing authorized render PASS16500/16500 pixels |
| Authorized PDF download/view |NOT TESTED |Download PASS valid20982-byte GRN PDF/chooser; viewing BLOCKED no PDF VIEW activity in default API30 image |
| Endpoint loss/offline |NOT TESTED |FAIL expected feedback not observed within bounded window after only emulator reverse443 removal; cause unestablished. Offline writes NOT TESTED |
| Reconnect |NOT TESTED |PASS restored fixture route/manual refresh recovered cart; not cellular acceptance |
| Realtime |NOT TESTED |PASS current43 foreground Orders1→2 after guarded admin RPC without manual refresh/navigation |
| Reciprocal native B / account-disable sequence |BLOCKED real third phone |NOT TESTED native; reciprocal API isolation/disabled-session denial PASS |
| Wi-Fi/cellular |Wi-Fi PASS observed; cellular NOT TESTED |Emulator transport scoped; cellular NOT TESTED |
| Authenticated cross-instance switching/replacement |BLOCKED |NOT TESTED; suitable second authenticated emulator instance not prepared. Pilot excluded |
| USB stability |PASS bounded trial |61 probes/300.06s with forced libusb, no restart/reset/disconnect; earlier native transport failures/kernel resets retained, root cause unresolved |

## Resumed current-artifact acceptance — e54/code2026093007

These rows supersede only their stated scope. Historical phone8d9da8e,
emulator43 and d454 results stay attached to those artifacts. The new normal
arm64 code2026093008 is built/audited but NOT INSTALLED.

| Required current scope | Result | Exact evidence or remaining limitation |
| --- | --- | --- |
| Revised clean normal guide, locked dependencies/setup/unit/lint/type/Expo/audit/bootstrap | PASS |36 setup;217 Jest/33 suites;0 lint errors/1468 existing warnings;Doctor18/18;npm audit0; normal arm64 build11m8s/983 executed |
| Mobile/backend live contract | PASS after FAIL |128 typed calls/94 names/3 dynamic wrappers,106 catalog signatures; first separate-checkout/state mismatch refused, corrected owning checkout guard retained |
| Fixture x86 build/artifact/signature/package/install/read-back | PASS |e54/code3007,11m6s/983 executed; exact SHA recorded above; generated restricted CA/native identity overlay declared |
| Physical corrected-artifact installation/acceptance | NOT TESTED |Phone remains8d9da8e; no new phone/SMS interaction in resumed scope |
| First new-artifact cold Orders launch | FAIL |SystemUI ANR; one explicit owned Wait recovered session separately. No KVM; cold reliability unresolved |
| Recovered administrator session and naturally expired access refresh | PASS |Age10832s>TTL3600; exactly one refresh hash rotated; session IDs and OTP verification count/time unchanged |
| Native logout/backend revocation | PASS |Normal Sign Out; private comparison exactly one refresh session removed, none added, no new OTP |
| Native disabled-B denial | PASS |Actual generated-OTP verifier showed Account unavailable; disabled profile/no active sessions/assignments confirmed |
| Reapproved B native login and Orders/role scope | PASS |Preparation by isolated admin API, then actual native verifier; only B Orders/customer tabs and Settings, no admin controls. Not native reapproval evidence |
| Same-artifact native A/B Orders isolation and switch return | PASS scoped |B-only then A-only through fresh actual verifier logins on e54; returned stored fixture identity matched; no stale B/Queue. Native deep-link/privileged denial not implied |
| Fresh pending enrollment/native approval | NOT TESTED on e54 |Earlier43 native fourth-account pending/sole-A approval PASS retained separately |
| Native cleared dispatch number regression | PASS |Empty field remains enabled/editable; normal I0002 re-entry and named suggestion accepted; private433 |
| Native final dispatch | PASS |I0002 quantity1/BAC01 stock1→0 and empty A cart; normal Submit/success plus guarded rows |
| Native receipt/image upload/partial dispatch | NOT TESTED on e54 |Earlier43 A0001 receipt/upload and I0001 partial2/stock3→1 PASS retained separately |
| Native invoice persistence | PASS scoped |20260930/BAC01,3 lines/10 dispatched; storage150/labour20/saved tax9/total179,stock0 |
| Native invoice preview/persisted financial reconciliation | FAIL |Preview tax8.50/total178.50 versus existing backend CEIL9/179; no rule change; correction/review/new-artifact retest open |
| Native image render, Realtime, PDF download | NOT TESTED on e54 |Earlier exact-artifact passes preserved; no transfer |
| PDF viewing | BLOCKED |Default API30 image has no PDF VIEW application; earlier download proof does not close viewing |
| Link-offline banner and reconnect | PASS scoped |Owned emulator Wi-Fi/data and reverse removed; banner observed; finally restored; manual refresh recovered empty queues |
| Endpoint-only loss and offline writes | FAIL earlier endpoint case; NOT TESTED writes |Keeping Wi-Fi on did not show expected feedback on43; no offline write/replay acceptance |
| Malformed origin rejection | PASS scoped |Actual HTTP and HTTPS-with-path rejection on e54; first keyboard-contacts prompt blocked attempt retained FAIL |
| Owned-instance discovery/switch-out | PASS scoped |Distinct Test1 identity displayed/persisted; prior fixture B refresh count1→0; target login reached without OTP |
| Test1 unauthenticated cold persistence/direct network | PASS scoped |Force-stop/launch retained Test1 public server key; fresh discovery succeeded with fixture reverse absent. No Test1 OTP/Metro; first boot ANR remains FAIL |
| Both-instance authenticated switching/same-origin identity replacement | NOT TESTED |No Test1 OTP in unattended scope; same-origin replacement not exercised; pilot excluded |
| QR/camera, cellular, physical no-USB, complete physical workflows | NOT TESTED current |Historical phone camera/Wi-Fi evidence separate; emulator transport is not hardware acceptance |

## Evidence, review and ordinary operation

[Backend review PR79](https://github.com/abhiguru/supabase-warehouse-template/pull/79),
[mobile review PR34](https://github.com/abhiguru/rn-warehouse-template/pull/34)
remain draft. PR34 is stacked on codex/operator-mobile; PR33/main were not merged.
[Baseline CI36591024357](https://github.com/abhiguru/supabase-warehouse-template/actions/runs/36591024357)
passed seven jobs historically. Review documentation-head
[CI36664842242](https://github.com/abhiguru/supabase-warehouse-template/actions/runs/36664842242)
on23db880 failed validation at container audit; contract and redacted scan passed;
dependent operator/migrations/Grafana jobs SKIPPED. No skipped job is a PASS.
Mobile main-only workflow does not run for the stacked PR base; local evidence
is recorded rather than claiming a mobile CI pass. Latest PR checks supersede
these dated runs; see PR bodies for final documentation-head status.

Use [OPERATOR_INSTALL.md](OPERATOR_INSTALL.md),
[OPERATOR_SETUP_NOTES.md](OPERATOR_SETUP_NOTES.md),
[UNATTENDED_FIXTURE.md](UNATTENDED_FIXTURE.md) and the
[mobile operator guide](https://github.com/abhiguru/rn-warehouse-template/blob/codex/fresh-vm-operator-notes/docs/OPERATOR_INSTALL_NOTES.md).
Main sequence corrections cover source permissions, effective Docker access,
provider file/Linux paths, dedicated ingress occupancy, native identity/tools,
scoped picker, fixture certificate/audit and resource checks. Historical failures
and deferred gates remain in the notes. Raw evidence/private comparisons are
outside Git at `/home/jay/warehouse-install-private/evidence`; phone numbers,
OTP/session values, credentials and device serials are excluded from this ledger.
The private fixture/backend ledgers preserve attempt history and exact APK/source
metadata; completed checks need not be repeated merely to regenerate this prose.

Installed Test1 source: `/home/jay/warehouse-src/backend`.
State: `/home/jay/warehouse-state/test1-install2` (0700; container-owned DB/storage
permissions must not be recursively changed). Provider file:
`/home/jay/warehouse-install-private/test1-msg91.env` (0600).
Tunnel: `warehouse-test1-tunnel.service`, private config
`/home/jay/warehouse-install-private/tunnel/config.yml`.
Public API: `https://test1.gurucold.in`; Studio/database/optional services private.
APKs: `/home/jay/warehouse-artifacts/test1` and `/home/jay/warehouse-artifacts/fixture`.
Failed/clean fixture state and AVDs retained; disposable services/emulator/bridge
are stopped after tests. Production pilot and recovery host were not contacted.

```bash
cd /home/jay/warehouse-src/backend
export PATH=/home/jay/.local/opt/node-v22.23.3-linux-x64/bin:$PATH
export WAREHOUSE_STATE_DIR=/home/jay/warehouse-state/test1-install2
sg docker -c 'bash start.sh'
sg docker -c 'node scripts/doctor.mjs --local'
sg docker -c 'node scripts/doctor.mjs'
sg docker -c 'bash stop.sh'
sudo systemctl start warehouse-test1-tunnel.service
sudo systemctl stop warehouse-test1-tunnel.service
systemctl status warehouse-test1-tunnel.service
```

Start/stop commands are alternatives, not a script to run all at once. Do not
use down-v, delete state or stop another connector. Enabled tunnel service is
not host-reboot evidence. Keep secrets entered locally, never in chat/Git.

Remaining decisions/resources: third owned phone for real reciprocal B and fresh
physical enrollment; physical native customer/expiry/images/PDF/offline/Realtime
and corrected APK retest; available cellular and disconnected operation; suitable
both-instance authenticated switch and same-origin replacement; PDF viewer for emulator viewing; provider
fault/rate-limit test window; documented business-rule sign-off and outstanding
security/release gates. No production readiness is asserted.


## Final repeat, corrected normal APK and requested pause

The revised disposable guide was repeated from clean ee5b493 source using a new
private core-backend-test-2026093004 state. Only the documented CI subnet
overlay and private gateway18080 differ. Unit48, migrations, setup, core API,
Realtime, final accounts/images, Studio, gateway CORS/size, upstream-IP
replacement and retention preview PASS. Container audit FAIL remains open.
The first local doctor failed at the10GiB free-space guard, when duplicate SDK,
AVD and native compiler trees left9.4GiB. After preserving each exact APK and
reclaiming three owned completed app/build output trees, local doctor PASS.
The same-input setup rerun preserved private config/manifest hashes, administrator
profile, databaseOID, document metadata and stored-file hashes. Both disposable
fixtures03/04, bridge and owned emulator were stopped without deleting state
or volumes; installed Test1 and its dedicated tunnel remain running.

Clean normal mobile source43b8320 (full SHA above), generated Test1 native identity
only, no fixture CA overlay, built arm64-v8a version0.1.0/code2026093006 in
10m22s with983 tasks executed. Exact unchanged artifact audit PASS. Retained at
/home/jay/warehouse-artifacts/test1/test1-43b8320-build2026093006-arm64.apk,
SHA-256 `f4f8dedafb3000bc602fd5c83620c7480d6bb19fa976694f8a3310e4af81befb`. This APK is NOT INSTALLED. Signature inspection,
installed read-back and physical workflows for it remain NOT TESTED; do not
transfer acceptance from the older phone or emulator artifact. Its build uses
the revised mobile guide's two-worker/3GiB Gradle command.

The operator explicitly requested more VM disk capacity, documentation completion
and a pause before reboot. No host reboot or resize was performed by the agent.
Paused after saving/pushing these docs and review updates; no new test run is
started. Private resume record: /home/jay/warehouse-install-private/RESUME_AFTER_DISK_EXPANSION.md.
After the operator's reboot/resume, inventory effective sudo, disk/memory, Docker
access, ports and installed service health because those prerequisites changed.
Reuse this ledger's completed source/artifact-scoped results rather than rerunning
unit/API/native suites by default. Current review CI/security failures and
explicitly open physical/native cases remain open. A short-lived fixture CA
may expire; recheck it before any resumed emulator run, without disabling TLS.

Assessment: the corrected backend guide was reproduced on this VM from clean
source and separate state, including populated-document preservation. The
corrected normal arm64 build guide was reproduced from clean43b8320 source.
Another operator can follow those documented sequences in the tested Linux
environment with their own inputs/state/ingress. This is not full physical
end-to-end, no-USB/cellular, provider-fault or production-ready acceptance.


## Operator-authorized resume after disk expansion — 2026-09-30

The operator resumed the exercise after their own reboot/expansion. A changed
private boot identifier and fresh inventory show root157GiB with86GiB available,
RAM17GiB and swap4GiB. Effective sudo and Docker access PASS. Installed Test1
local/public doctor PASS (private evidence387/388); its dedicated tunnel remains
active. No pilot or recovery host was contacted and no agent reboot was issued.
Completed unit/API/build results above were reused, not rerun indiscriminately.

Only the retained disposable fixture03 and owned API30 emulator were restarted.
Ports18080/18443 and5556/5557 and the selected subnet were checked before startup.
The first fixture restart FAILed the Node22.18+ guard because the private driver
omitted the pinned PATH; retry with Node22.23.3 inside `sg docker` PASS. No source
or ownership guard was changed. The emulator ready probe took127.4s; its own log
later reports full boot205.797s (different readiness measurements). A native
cold-launch Orders probe FAILed behind a SystemUI ANR. One explicit Wait on the
owned emulator recovered the saved administrator session/Orders; this separate
PASS does not establish an uninterrupted reliable cold launch.

Normal arm64 code2026093006 signature/package inspection now PASS (389/390/398),
SHA unchanged `f4f8dedafb3000bc602fd5c83620c7480d6bb19fa976694f8a3310e4af81befb`.
It remains NOT INSTALLED; no physical acceptance is transferred.

The pre-resume backend review head89b999c CI
[36674599390](https://github.com/abhiguru/supabase-warehouse-template/actions/runs/36674599390)
FAILed container-audit validation; contract and redacted source/history scans
PASS, dependent operator/migrations/Grafana jobs SKIPPED. Existing security and
release gates remain open.


Current audited emulator43b8320/code3005 native receipt A0001 PASS: normal
header/item/review/Create workflow, Customer A, MONTHLY,10 bags×10kg, guarded
stock10. Image-required validation passed; the ordinary system picker uploaded
the sole fictional PNG through the client pipeline, confirmed header WebP and
scoped storage object PASS. Current native partial dispatch I0001 PASS: A queue2
from BAC01 stock3→1, normal confirmation and queue cleared. Invalid hyphenated
fictional registration was rejected; uppercase/digits/spaces retry passed.

A private verifier incorrectly required a persisted automatic invoice after
dispatch and FAILed. Actual pinned create_dispatch_with_stock_check_internal
returns invoice data when requested; this path does not persist the invoice.
The misleading mobile comment does not change that contract. Preserve the null
invoice observation and corrected stock-only assertion; the separate native
invoice workflow is required. No production billing rule or source was changed.
Private evidence400/402/404 and the native attempt ledger retain exact artifact
and fictional metadata; no successful input event alone counts as acceptance.


Final-dispatch private-driver attempts FAILed before submission: one named
registration placeholder disappeared under ghost text; another synthetic Back
after input returned to Dispatch list despite the reported IME input-shown flag.
No final stock change was claimed. Private helper backups/history are retained;
automatic Back was removed, and normal next-step controls are used. This is a
harness correction, not a backend/mobile source fix. The registration ghost
input lacks an accessible name in this state; that limitation remains open.


### Resumed mobile source correction — e54c826

The final native draft exposed a real recoverability defect in mobile43b8320:
clearing the dispatch number hides its input behind a spinner after generation
has already settled. DispatchHeaderStep rendered loading from `!header.disp_no`
while useDispatchForm's one-shot initializer would not generate again. Review
commit `e54c8268f6f5dd67652d3779d2b4a111292a59fa` tracks actual number generation
(including rejection/finally), leaving an empty field editable after completion.
It also names Dispatch number/Vehicle registration and the normal Use suggestion
button for accessibility. No backend/authentication/billing rule changed.
Typecheck PASS; existing217 Jest tests/33 suites PASS; changed-file lint PASS
0errors/57 existing warnings (private406/407/408). Native verification on a new
audited artifact is required;43/code3005's earlier passes stay on that artifact.
The owned emulator was stopped before the heavy build; fixture state retained.


Resumed backend documentation head18b5317 CI
[36683411636](https://github.com/abhiguru/supabase-warehouse-template/actions/runs/36683411636)
FAIL: validate now stops at postgres-meta's dependency audit (brace-expansion
HIGH and fast-uri MODERATE), before reaching Storage's audit. Contract and
redacted source/history scans PASS; dependent migrations/operator/Grafana jobs
SKIPPED. Preserve earlier metadata-clean/Storage-failure observations as dated
evidence, not current clean metadata assurance. The separate historical Storage
undici/ip-address findings remain unresolved. Image-security investigation and
upgrades stay deferred; no dependency gate was relaxed. Private413/414/415 retain
the exact run/job/failed-command evidence.


New e54 fixture APK clean build/audit/signature/identity PASS: version0.1.0/
code2026093007,x86_64,11m6s/983 tasks executed, restricted public CA overlay,
SHA `f8ed582a6e37398cab49c0682c6d377a39f4b17249c1f6d04315b42f8c95dfe7`.
Retained private fixture/fixture-e54c826-build2026093007-x86_64.apk. Installation
and affected native verification remain pending at this dated point; current
physical phone remains8d9da8e.

New-source live contract first attempt FAILed the ownership-checked catalog
request: the driver used the separate backend review checkout with fixture03's
state. Keep the owning checkout and state together, even for `--live` read-only
checks; never disable Compose ownership checks to make a cross-checkout command
work. Retry uses warehouse-reproduce/unattended-backend and its own fixture03.
Private416 preserves failure; corrected421 records the retry.


The corrected e54 live contract check from its owning fixture checkout PASS
(private421):128 typed calls/94 RPC names and3 explicitly reported dynamic wrappers; no
name/overload/argument/grant mismatches. This remains a lower-bound inventory.
Separate clean normal e54 checkout ran the revised main sequence: locked npm ci,
36 setup tests,217 Jest/33 suites, lint0errors/1468 existing warnings, typecheck,
Expo compatibility/Doctor18/18, npm audit0 and Test1 public bootstrap PASS. Native
arm64 compilation remains in progress at this dated point. The prior successful
suites were repeated here because a new shared-hook source change and revised
clean-guide verification required new evidence; backend API suites were reused.


The revised normal mobile guide completed from a separate clean e54 checkout
with only the declared native Test1 identity, no fixture CA overlay. All main
checks above and arm64-v8a assembleRelease PASS in11m8s/983 tasks executed.
Exact artifact audit/signature/package PASS, version0.1.0/code2026093008,
SHA `7ad6e19aee694865a4fdcc9753fddb19ddd5bce317f39e4da56d08464935fb3e`.
Retained /home/jay/warehouse-artifacts/test1/test1-e54c826-build2026093008-arm64.apk
(0600). It is NOT INSTALLED; physical read-back/native acceptance remains open.
The normal clean source/build guide is reproduced; compilation is not E2E
acceptance. New fixture APK installation and the affected native case are next.


New e54/code3007 fixture installation/signature-match/read-back PASS (427–429),
without uninstall/data clear. New emulator ready probe97.7s and full-boot log
169.421s are separate measurements. Temporary labeled hosts/reverse mapping
PASS; SELinux Enforcing. First Orders launch probe FAIL behind SystemUI ANR;
one explicit owned Wait recovered actual Orders A1/Bempty and staff tabs.
Cold-launch reliability remains FAIL; recovered session is a separate PASS.

New e54 native naturally expired-access refresh PASS (430–432): before launch
last administrator OTP verification age10832s exceeded accessTTL3600; after
normal authenticated Orders restore, exactly one refresh hash rotated, session
IDs and OTP verification timestamp/count stayed unchanged. No new challenge,
fixed code, token injection or authentication lifetime change was used. Private
hashes were compared without printing values. Old cached UI was not reused as
new-artifact proof; the private driver now excludes cache predating installation.


### Resumed audited e54 native dispatch and invoice findings

Exact e54c8268f6f5dd67652d3779d2b4a111292a59fa/code2026093007 native
cleared-number recovery PASS (private433): clearing generated I0002 left an
enabled, named empty Dispatch number input. Normal re-entry and the explicit
Use suggestion button restored a valid one-bag draft. Earlier queue navigation
FAIL remains: an expanded recent-dispatch section hid the target below the
viewport; collapse it and inspect a fresh screen before acting. No offscreen
ADB tap or app-state injection was used for the successful case.

Normal native final dispatch I0002 PASS: BAC01 stock1→0, quantity1 saved for
Customer A, order/cart empty, success dialog matched; guarded private404-final
confirmed rows. Prior43/code3005 partial dispatch2/stock3→1 and receipt A0001
are separate artifact evidence, not transferred to e54.

Native invoice creation saved invoice20260930/BAC01 and three dispatch lines
(total quantity10) PASS for persistence, but preview/persisted reconciliation
FAIL. Review and confirmation displayed storage150 + labour20 + tax8.50 =
178.50; saved header tax9/total179. Root cause established: mobile
src/utils/invoiceCalculations.ts rounds money to two decimals, while pinned
backend migration00000000000006_invoice_line_integrity.sql save_invoice
applies CEIL to header tax and total. Saved per-line rate/duration/quantity
calculations reconcile to storage150/labour20; stock remains0 (private434).
The earlier documented950/48/998 API example still passed separately.

A private verifier initially expected178.50 and failed. Its surrounding shell
continued and wrote a premature PASS; this has been explicitly superseded by
FAIL while retaining attempt history. Subsequent action sequences stop on
command failure. A separate guarded persistence check against the existing
backend rule PASSed. Success dialogs and ADB delivery alone cannot establish
financial acceptance. No invoice was deleted/recreated to hide the mismatch.

OPEN: align native review/confirmation/success amounts with the agreed backend
rounding contract and repeat on a newly audited artifact. No billing rule or
production behavior was changed during this installation exercise. Until that
work is reviewed, this case is FAIL; operator/business sign-off remains required
before using financial output beyond fictional tests.


Exact e54/code3007 link-offline banner/reconnect PASS: only the owned emulator's
Wi-Fi/data were disabled and its reverse443 removed; No internet connection was
observed within90s. A finally block restored previous links/reverse. Banner
disappeared and ordinary Refresh orders restored A/B empty queues. This does
not erase prior43 endpoint-only feedback FAIL (Wi-Fi remained on), establish
offline writes, or demonstrate cellular/physical/no-USB behavior.

Current e54 native administrator logout/revocation PASS: normal Sign Out reached
login with selected fixture server retained; private431/437 comparison showed
exactly one refresh session removed, none added, OTP verification count unchanged.
Native disabled fictional B login denial PASS: actual generated challenge went
through the Edge verifier and displayed Verification Failed / Account unavailable;
guarded private435 confirmed disabled profile, empty assignments and no active
refresh session. No real SMS or fixed OTP was used. First immediate OTP-screen
hierarchy attempts FAILed (UIAutomator idle-state unavailable); private436
screenshot established the actual empty-code focused screen before input. A
private read-only verifier's initial nonexistent revoked_at-column assumption
FAILed and was corrected to this schema's deletion-based revocation; backup
retained. No backend/session enforcement was weakened.


Reapproved B native login/Orders scope PASS on e54/code3007. Preparation used
the existing isolated administrator API to approve only B (private435); it is
not native reapproval evidence. Fresh generated code went through the actual
verifier, and settled Orders contained only Customer B; customer tabs and
Settings omitted Queue, Customers, Enrollment Review and Users. A prior43 native
A-only result remains separately dated; same-artifact reciprocal A is not yet
claimed. First denial/OK already returned to login; an extra Back-label attempt
FAILed within90s without a tap. Inspect actual current UI rather than assuming
a particular post-error route.


Malformed-origin attempt initially FAILed because a previously unseen AOSP
keyboard contacts permission dialog took foreground, not a warehouse-camera
prompt. Private439 screenshot established it; ordinary DENY closed it without
grants or app/phone setting changes. The HTTP text was already present but
Check server had not completed. Retain the failed attempt and confirm actual
foreground/keyboard state before retry; a sent tap is not validation evidence.
This was on the disposable emulator only.


Exact e54/code3007 native malformed HTTP and HTTPS-with-path origin rejection
PASS after the established keyboard prompt was declined. No selection/credentials
were substituted and earlier failed attempts remain. Native Check server then
retrieved/displayed Test Warehouse 1 at https://test1.gurucold.in over the
emulator's restored network. Test1 and fixture03 manifests have different
instance IDs and independent state/credentials. This is the second owned test
instance; the production pilot is excluded. Target login/authentication is not
implied by public identity discovery.


Current e54 native cross-instance switch to owned Test1 PASS, scoped:
Check server displayed the distinct Test Warehouse1 identity, Use this server
reached unauthenticated login, the persisted public selected-server key matched
Test1's manifest, and prior fictional B refresh-session count changed1→0. Only
the public selected-server SQLite key was read; no native session values were
retrieved or written. First state-read command FAILed; bounded retry with
SQLite5s busy timeout PASSed. Initial root cause is unestablished; do not infer
database locking from the successful retry. Both attempts remain in private440.
No Test1 OTP, business-data request, pilot contact or old-session injection.
This closes authenticated-fixture switch-out/target-selection only, not login
on both instances or same-origin identity replacement.


Current e54 Test1 unauthenticated cold persistence/direct network PASS (private441):
force-stop/launch with fixture reverse443 absent reached login, read-only
persisted public server identity still matched Test1, and fresh native
Check server retrieved/displayed Test Warehouse1 through the emulator's direct
network. Finally restored only the emulator fixture route. No Metro, target OTP
or native session value used. This scoped successful cold launch does not erase
the first boot/SystemUI failure or establish authenticated Test1, physical
no-USB, cellular or reliable cold behavior across runs.


Current e54 ordinary switch-return/reciprocal native Orders scope PASS:
selected fixture03 again from Test1, public persisted server key matched the
original fixture manifest, login showed no stale B Orders, and fresh generated
A challenge used the actual verifier. Same exact artifact showed only B during
B login and only A during A login; customer tabs omitted Queue. Deep-linked
foreign native records/privileged-RPC denial are not implied; reciprocal API
denial evidence remains separate. No target Test1 OTP/session or source/app-state
injection. Private442 and artifact-scoped native attempt ledger retain proof.

Resumed tests complete to their recorded scope. Bridge stopped with Ctrl+C,
owned emulator stopped through its explicit ADB target, fixture03 ownership-checked
Compose down(no-v) PASS; fixture04 was already stopped. Socket and owned
ports18443/18080/5556/5557 absent (private443). State/AVDs/artifacts/signing/failed
logs retained; shared ADB server and physical phone untouched. Installed Test1
final local/public doctor and active dedicated tunnel PASS (private444/445);
backend source clean at f18f51d. Host root157GiB/free81GiB.

The corrected installation and normal e54 Android build were reproduced from
clean source with separate disposable state and declared overlays. Another
operator can follow those revised sequences on the recorded prerequisites;
the entire current end-to-end suite has not passed. Financial-preview mismatch,
container audit, no-KVM cold reliability, physical corrected-artifact workflows,
cellular/no-USB, PDF viewing, offline writes, both-instance authentication and
same-origin replacement remain open. No skipped/historical/build-only evidence
closes those gates. No release/merge, recovery/cutover or agent reboot.
