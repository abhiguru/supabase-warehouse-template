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
| Final tested emulator APK | Mobile `43b832092bb8157e73b012add6a57f2e6dd724a1`; `in.gurucold.warehouse.fixture`, Fictional Core Warehouse, warehouse-fixture, version0.1.0/code2026093005, x86_64. Generated native identity and restricted public fixture CA trust overlay; private CA key excluded. Actual Edge verifier used with generated fixture codes via protected local IPC; no SMS call or code in HTTP/logs |

Physical APK SHA-256:
`969d4fba6f21b7940897fb67aa8d09174f9e33cf376c964f4798ff96b15c25d4`.
Final emulator APK SHA-256:
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
| Current container dependency audit | FAIL | Storage undici7.29 HIGH/ip-address MODERATE; metadata clean. Existing security findings/release gates preserved |
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

| Android required case | Physical8d9da8e | Audited emulator43b8320 / limitation |
| --- | --- | --- |
| Dependencies/setup/unit/lint/type/contract/compatibility/Doctor | PASS |PASS:36 setup tests,217 Jest/33 suites, lint0errors/1468 existing warnings, typecheck, SDK compatibility, Doctor18/18, public bootstrap and contract |
| Dependency audit | Earlier PASS retained |Final43 PASS0; intervening FAIL3 packages retained, targeted compatible lock updates for brace-expansion/fast-uri/moment |
| Clean native build, audit and exact installation bytes | PASS |PASS x86 code3005,11m37s/983 tasks executed; separate normal arm64 final build recorded below |
| Manual server selection and displayed identity | PASS |PASS fixture discovery/current saved selection, restricted TLS CA/hosts-label/reverse overlay documented |
| Malformed HTTP/path origins | PASS scoped |Earlier initial fixture observations do not transfer to final43; other malformed variants NOT TESTED |
| QR selection with real camera | PASS |NOT TESTED emulator; initial invisible QR window FAIL retained, visible fullscreen viewer scan later passed |
| Cold launch and lifecycle/server persistence |PASS unauthenticated cold/Home, authenticated Home |PASS authenticated server/session restore after fixture package update; initial premature idle/focus probes retained. Full physical authenticated force-stop remains NOT TESTED |
| No Metro / no USB standalone |Metro absent observed; no-USB NOT TESTED |Bundled APK, Metro absent; ADB reverse required for local fixture, so no-USB NOT TESTED |
| Administrator login |PASS real SMS/current phone |PASS fixture actual verifier; no provider/SMS acceptance implied |
| Customer login/permissions/cart |NOT TESTED native |PASS fictionalA, Customer role/staff controls omitted, only A Orders, native cart quantity1 persisted |
| Fresh pending enrollment and native approval |BLOCKED no third real phone |PASS fourth fictional account had no refresh session; native admin assigned only A, saved assignment checked |
| Logout/revoked sessions |NOT TESTED native |PASS current43 native logout and prior admin refresh-session revocation |
| Expired access/legitimate refresh |NOT TESTED native |PASS prior auditedd4540c8: verification age4339s exceededTTL3600, hash rotation/no extra OTP; final43 NOT TESTED |
| Native receipt/partial-final dispatch/invoice creation |NOT TESTED |NOT TESTED; backend fixture/installed API passes are separate |
| Stock/dispatch/invoice display |NOT TESTED beyond dashboard |PASS scoped: current43 BAA01 stock0/100 and BAC01 stock3/10; invoice998 displayed on earlier artifact, not transferred |
| Native image upload/render |NOT TESTED |Prior auditedd454 upload via scoped system picker→WebP metadata/remote bitmap PASS; final43 existing authorized render PASS16500/16500 pixels; final43 upload NOT TESTED |
| Authorized PDF download/view |NOT TESTED |Download PASS valid20982-byte GRN PDF/chooser; viewing BLOCKED no PDF VIEW activity in default API30 image |
| Endpoint loss/offline |NOT TESTED |FAIL expected feedback not observed within bounded window after only emulator reverse443 removal; cause unestablished. Offline writes NOT TESTED |
| Reconnect |NOT TESTED |PASS restored fixture route/manual refresh recovered cart; not cellular acceptance |
| Realtime |NOT TESTED |PASS current43 foreground Orders1→2 after guarded admin RPC without manual refresh/navigation |
| Reciprocal native B / account-disable sequence |BLOCKED real third phone |NOT TESTED native; reciprocal API isolation/disabled-session denial PASS |
| Wi-Fi/cellular |Wi-Fi PASS observed; cellular NOT TESTED |Emulator transport scoped; cellular NOT TESTED |
| Authenticated cross-instance switching/replacement |BLOCKED |NOT TESTED; suitable second authenticated emulator instance not prepared. Pilot excluded |
| USB stability |PASS bounded trial |61 probes/300.06s with forced libusb, no restart/reset/disconnect; earlier native transport failures/kernel resets retained, root cause unresolved |

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
second isolated authenticated instance; PDF viewer for emulator viewing; provider
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
