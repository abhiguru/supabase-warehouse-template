# Operator pilot setup findings and edge cases

Recovery rehearsal has ended. Do not resume historical recovery-host, archive
transfer or routing instructions. See the [current backend acceptance record](BACKEND_CORE_ACCEPTANCE.md).

Updated 2026-09-27 from the isolated Linux VM pilot. Read this alongside
[OPERATOR_INSTALL.md](OPERATOR_INSTALL.md) and the
[production acceptance ledger](PRODUCTION_DEPENDENCIES.md#independent-operator-installation-work).
These are observed shortcomings, remedies and remaining test cases, not a claim
that every deployment or failure mode has been accepted. Keep instance-specific
phones, credentials, device serials and raw authentication results in private
evidence outside Git. A future operator must supply their own values.

## Current independent installation — 2026-09-30

This fresh VM installed **Test Warehouse 1** at its dedicated HTTPS origin.
Backend installed content is exactly `f18f51d4625e7f8c0d977ac69645804e318a9d49`;
tracked source permissions were corrected to public-readable 0644/0755 after the
failed first attempt. No runtime source content was edited. Review changes live
in [draft PR #79](https://github.com/abhiguru/supabase-warehouse-template/pull/79).
Mobile baseline is `8240cce9121a797fd0cf2e00e568a61985814ddb`; the native test
identity/build correction is a separate review commit, recorded in the mobile
operator notes and [draft PR #34](https://github.com/abhiguru/rn-warehouse-template/pull/34).
Nothing was merged or released.

The operator explicitly lifted the no-SMS restriction **only for this new test
warehouse**. Real administrator OTP delivery/verification/login, Customer A
pending enrollment without a session, administrator approval and Customer A's
new post-approval OTP login passed. Codes were entered hidden in local terminals;
phones, sessions, provider credentials and raw responses remain outside Git.
The earlier no-SMS checkpoint below remains historical evidence, not current
permission. Neither protected host was contacted. Recovery and deferred gates
remain closed.

| Required case / environment and trigger | Status | Exact evidence and limitation |
| --- | --- | --- |
| Ubuntu 24.04.3 x86-64 VMware prerequisites, sudo, ownership, ports | PASS | Node 22.23.3/npm 10.9.9; Git 2.43.0; Docker 29.8.1/containerd 2.3.6; Compose 2.40.3; cloudflared 2026.9.3; effective noninteractive sudo and Docker group access |
| First target installation, source umask 077 | FAIL, preserved | PostgreSQL initialization denied reading `98-webhooks.sql`; later pg_isready was misleading. Stopped this partial state without deleting data. Public source permissions corrected; private state permissions retained |
| Second independent state `setup.sh --operator`, local doctor | PASS | Same backend content, new private state and identity; complete migrations/private Storage policies, loopback gateway |
| Authenticated hostname/tunnel occupancy, dedicated HTTPS ingress | PASS | Initially zero selected-hostname DNS records; four preexisting tunnels untouched. Created new tunnel/credential JSON and proxied CNAME only after rechecking vacancy. Dedicated unprivileged enabled systemd unit active; no reboot tested |
| Public doctor and warehouse identity discovery | PASS | Public company/origin/instance matched local manifest; Android-like okhttp and curl-like clients received HTTP 200 JSON |
| Supplemental default Python urllib discovery | FAIL | HTTP 403 text/plain from Cloudflare; cause unestablished. Custom operator/Android-like clients succeeded; no edge bypass or WAF change applied. Actual app compatibility remains its own case |
| Same-input setup rerun | PASS | Private comparisons preserved config/manifest hashes, administrator aggregate, database OID/migration count and stored sentinel PDF object/bytes. Sentinel upload used this instance's maintenance credential; not customer PDF permission evidence |
| Backend dependency installation/unit checks | PASS with historical failure | npm ci; corrected review 48/48 tests under umasks 077 and 022. Baseline under 077 initially failed 1 permission fixture; only test fixture chmod changed in review |
| Disposable migrations/auth/billing checks | PASS | Separate owned disposable database; original guards unchanged; no fixture issuer used against installed warehouse |
| Current container dependency audit | FAIL | Storage undici 7.29.0 HIGH and ip-address MODERATE advisories; metadata clean. Historical seven-job green CI is retained but does not override current failure |
| Review CI | FAIL overall | Latest recorded [run 36664842242](https://github.com/abhiguru/supabase-warehouse-template/actions/runs/36664842242) at documentation head `23db88011e45d20777ff4319f3ab2b9000e6d933`: contract and secret scan PASS, validation audit FAIL, dependent jobs SKIPPED. Prior [run 36644865092](https://github.com/abhiguru/supabase-warehouse-template/actions/runs/36644865092) has the same recorded outcome. No skipped job counted as pass |
| Clean corrected-guide reproduction | PASS, scoped | Clean checkout of review commit `8bca643230961e2c91ace9b5a1a2491dd89c5126`, readable public source, separate `core-backend-test` state, fictional guard identity/origin and port 18080. Setup and safe rerun preserved private config/object hashes; owned fixture services stopped and state retained. This is local reproduction, not a second public tunnel/device installation |
| Guarded core-backend fixture APIs | PASS, disposable only | Identity/roles, A/B customer isolation, receipt/cart/order/queue, invalid quantity/retry/concurrent dispatch, partial/final stock, invoice 998, four private signed PDFs, refresh/replay/logout, Realtime/reconnect, image lifecycle/privacy/oversize and disabled-account revocation. No guards weakened |
| Real installed administrator/customer authentication | PASS | Real SMS login, pending enrollment, authenticated approval and post-approval login; provider acceptance also confirmed by received/verified codes |
| Real session refresh/replay/logout | PASS | Proper refresh rotated the token; replay denied; logout revoked access and refresh. Naturally expired administrator token rejected and legitimate refresh succeeded without another SMS |
| Real GRN image lifecycle | PASS | Real administrator uploaded/confirmed a tiny fictional PNG, Customer A gained read only after confirmation, anonymous access denied, duplicate/oversize upload rejected, delete revoked read and removed test bytes |
| Real dispatch image lifecycle probe | PASS after harness correction | First private helper failed on const assignment before the API call; preserved. Corrected helper uploaded/confirmed/read/deleted fictional dispatch PNG with authorization, duplicate and oversize checks on the installed warehouse |
| Real public Realtime customer update/reconnect | PASS on final retry; earlier FAIL retained | First and corrected helper customer joins timed out; cold-start/invalid-byte log cause remains unestablished. Fresh real customer joins then passed under both compression settings; final public customer update/reconnect and malformed-JWT rejection passed without runtime changes. This does not establish flawless startup reliability |
| Real installed receipt/inventory/cart/order/staff queue | PASS | Fictional 100-bag receipt and retry produce one receipt; Customer A seven-bag cart; customer catalog mutation denied; administrator queue sees order |
| Real installed partial/final dispatch and invalid quantities | PASS | 20 then 80 bags; balances 80 then 0; repeat dispatch does not subtract twice; negative/zero/81-of-80 dispatch rejected |
| Real installed fictional billing/invoice | PASS | Existing documented Apr 1/May 2 legacy example: price 5, labour 2, tax 5%; subtotal 950, rounded tax 48, total 998. This validates the example, not an invented production billing policy |
| Real installed PDFs/concurrent stock | PASS | Real Customer A generated/downloaded all four valid signed PDFs; anonymous/customer direct reads denied. Two simultaneous 7-of-10 dispatches produced exactly one success and balance 3 |
| Real installed Customer A/B isolation | BLOCKED | Operator has no third owned phone. Real Customer A cannot read a separate fictional B record, create its cart or generate its stock PDF (PASS one-way); reciprocal real B authentication remains blocked. Disposable two-session fixture passes are separate evidence |
| Android native acceptance | PASS, scoped | Clean corrected 8d9da8e APK built, audited, installed and read back with matching hash on Samsung SM-A346E / Android 15. Manual/QR dedicated-server identity, HTTP/path rejection, real administrator SMS login, Wi-Fi and authenticated Home/launcher persistence passed. Customer native workflows, authenticated cold restore, cellular and disconnected operation remain open; libusb ADB trial passed 61 probes over five minutes without a restart/reset/disconnect; root cause of earlier native-backend read failures remains unresolved. See mobile notes for full source/artifact boundary |
| Cross-instance native switching | BLOCKED | No suitable second isolated public instance; do not use the pilot |
| Cellular, unattended restart | NOT TESTED | No evidence yet; enabled restart configuration does not prove host restart recovery |

Private locations on this VM: `/home/jay/warehouse-install-private` (0700),
provider file `test1-msg91.env` (0600), active state
`/home/jay/warehouse-state/test1-install2`, failed retained state
`/home/jay/warehouse-state/test1`, installed source
`/home/jay/warehouse-src/backend`. Dedicated connector unit:
`warehouse-test1-tunnel.service`; its private configuration is in the evidence
root's `tunnel` directory. State config/credentials stay private. Raw evidence
and private hashes are deliberately not committed.

Current review fixes also integrate fresh prerequisites, source/state umask
separation, Compose v2 selection, Node PATH/effective groups, authenticated DNS
occupancy, Cloudflare installation and ordinary operation into the main guide.
GitHub browser authorization completed locally; review commits were pushed.
Earlier failed no-prompt push and all setup attempts remain in private evidence.

Printing, sensors, iPhone, external alerts, credential rotation, image-security
research, recovery rehearsal and reboot remain outside scope. Existing release
gates stay open. This record does not claim flawless installation or production
readiness.

## Initial fresh-VM checkpoint — historical, superseded below

This attempt preserves the existing pilot and closed recovery rehearsal. It
contacts neither pilot nor recovery host, sends no SMS, and makes no release,
cutover, reboot, credential-rotation or optional hardware changes. The operator
must lift the no-SMS restriction before real authentication can be tested.

Source checkouts are clean and detached: backend
`f18f51d4625e7f8c0d977ac69645804e318a9d49`, mobile
`8240cce9121a797fd0cf2e00e568a61985814ddb`. Corrections live in separate review
worktrees. The independent warehouse setup has now started from the clean pinned checkout;
service health and integration acceptance are still pending. Public GitHub API confirmed
backend PR #68 merged at that SHA on September 29 and all seven jobs passed in
[run 36591024357](https://github.com/abhiguru/supabase-warehouse-template/actions/runs/36591024357).
Mobile PR #33 remains open/draft; mobile `main` is a different commit.

Host inventory: Ubuntu 24.04.3 LTS / x86-64 VMware guest, kernel 7.0.0-34,
Git 2.43.0, 5.7 GiB total RAM (about 3 GiB available), 4 GiB swap and 63 GiB free
on the 79 GiB root filesystem. Home is owned by the installation user, mode 0750.
`sudo -n true` passed. Warehouse gateway ports were unoccupied. Initially Node
18.19.1/npm 9.2.0 were installed; Docker, curl, GitHub CLI and Android tooling
were absent. No repository AGENTS.md was found at the pinned checkouts or their
workspace parents. Private evidence is outside Git, under a mode-0700 directory.

| Finding / triggering command | Expected versus actual / cause | Correction and verification | Remaining limit |
| --- | --- | --- | --- |
| Read `OPERATOR_INSTALL.md` at backend baseline | Guide said PR #68 was unmerged; GitHub reports merged | Pin merge SHA; update active guide/handoffs and clearly date historical evidence | Merge is not production acceptance |
| Host `node --version` | Required >=22.18; actual 18.19.1 | Install official Node 22.23.3 tarball, compare published SHA-256, export PATH; Node 22.23.3/npm 10.9.9 verified | No signature verification claimed |
| Fresh-host package sequence | Guide listed tools without install commands or an effective session sequence | Integrate Ubuntu package commands and Docker-group/Node PATH checks in the main guide | Clean-source service installation still pending |
| `apt-get install ... docker-compose-plugin` | Guide requires v2; official repository selected v5.5.1 | Select repository v2.40.3 explicitly; retain initial package evidence privately | v5 runtime compatibility not tested |
| `umask 077; npm test` on Node 22.23.3 | 48 expected passes; 47 passed / 1 failed in provider-permission rejection fixture | `writeFileSync(... mode: 0644)` is masked to 0600; explicitly chmod the disposable insecure fixture to 0644 in review source | 48/48 PASS under umasks 077 and 022; runtime guard unchanged |
| `npm run check:container-dependencies` at clean backend baseline, npm 10.9.9 | Historical CI passed; current Storage audit exits 1 with HIGH `undici` 7.29.0 findings and MODERATE `ip-address` findings; metadata audit passes | Preserve failed audit and upstream advisory links in private evidence; no dependency/runtime security patch made in this exercise | Deferred image-security work remains open; do not claim all current checks pass |
| Fixture `setup.sh --operator` in clean baseline checkout, Docker 29.8.1 / Compose 2.40.3 | Host/configuration preflights PASS; first database build FAIL while resolving `registry-1.docker.io` through 127.0.0.53 | Preserve exact first attempt; diagnose DNS and retry the same pinned image without changing source or deleting state | Subsequent DNS lookup and pinned-image pull PASS without DNS/source changes; warehouse health remains pending |
| First target `setup.sh --operator`, source cloned under umask 077 | Database built, but setup exited 1 on unhealthy state; PostgreSQL then restarted and appeared healthy | Full startup log establishes `98-webhooks.sql: Permission denied`; tracked SQL was 0600. Correct public tracked files to 0644/executables 0755 and directories 0755; integrate clone `umask 022` in guide | First incomplete state stopped without deleting volumes/data; second separate state setup in progress, same source baseline |
| Database full-log diagnostic in a new shell | Expected owned logs; wrapper refused unset WAREHOUSE_STATE_DIR | Repeat with explicit recorded-state export; retain refused attempt | Shell environment must be set for each command session |
| Selected-hostname `dig` and HTTPS probe | New route expected; NXDOMAIN and curl exit 6 before provisioning | Retain occupancy results; require authenticated zone/tunnel check before configuring ingress | NXDOMAIN alone cannot prove account-side vacancy |
| Agent shell execution | Sandbox failed before command with `bwrap: loopback: Failed RTM_NEWADDR` | Approved execution outside broken sandbox allowed host inspection | VM execution-environment issue; not an application defect |

Current cases: prerequisite/version availability PASS; installed local/public
doctor, discovery, safe rerun, persistent documents and clean-source reproduction
NOT TESTED. Backend npm ci PASS; baseline unit run FAIL (47/48), corrected review unit runs PASS (48/48 under both umasks); disposable migration/auth/billing checks PASS; container dependency audit FAIL. Syntax and redacted baseline source/history secret checks PASS. Real administrator/customer login,
enrollment and approval are BLOCKED by the no-SMS instruction. Installed
warehouse business flows, permissions, retries, invalid quantity, concurrent
stock, isolation, invoice and private PDFs are NOT TESTED; disposable fictional
fixture coverage will be recorded separately. Review correction commit `60031d8e7603c42e5c698294243f909853741e18` contains
documentation plus the unit-fixture chmod correction; it has not changed installed
runtime source. A fresh checkout of that commit with source umask 022 has
readable bind mounts. GitHub review push is currently BLOCKED by missing local
authentication; the failed no-prompt push is retained privately.

Android phase is BLOCKED until
backend local/public checks pass. Wi-Fi/cellular/device/QR/lifecycle/standalone,
Realtime, images and authenticated PDF acceptance are NOT TESTED. Cross-instance
switching is BLOCKED until a second isolated running instance is available;
the live pilot cannot serve as that instance. Printing, sensors, iPhone, alerts,
rotation, image research and recovery rehearsal remain outside this exercise.

The operator explicitly requested creation of the private provider file. It was
created outside Git with mode 0600 and validated without printing credential
values. Cloudflare browser authorization completed. Authenticated zone query found zero
records for the selected hostname; four existing tunnels were inspected without
modification. A new tunnel and credentials were created and its ingress validated
with cloudflared 2026.9.3. DNS remains unrouted until local health passes. No reproducible
installation or current end-to-end acceptance is claimed by this progress record.

## Evidence and version boundaries

The VM initially checked out backend
`4f1efb8dd4f8c748961a0f250c5af4fc202fb38a` and mobile
`8240cce9121a797fd0cf2e00e568a61985814ddb`, both detached. The installed backend
then gained local MSG91 and doctor fixes; at runtime acceptance its twelve changed
files matched review commit `831678619e175eeb3c1b656ea932d290da705c5b`. Review head
`9c891f4f4b1b480e8d545454efbfd323e7c9d1c2` adds a CI fixture correction.
Backend [PR #68](https://github.com/abhiguru/supabase-warehouse-template/pull/68)
and mobile [PR #33](https://github.com/abhiguru/rn-warehouse-template/pull/33)
were the operator review references at that historical checkpoint; it did not
claim a merge. The current merge status is recorded below.

Backend [CI run 36313952647](https://github.com/abhiguru/supabase-warehouse-template/actions/runs/36313952647)
passed all jobs at `9c891f4`. Mobile
[CI run 36289818695](https://github.com/abhiguru/rn-warehouse-template/actions/runs/36289818695)
passed at the pinned mobile commit. Later documentation edits are not new runtime
or physical-device evidence. Record the installed HEAD **and** local changes;
HEAD alone would incorrectly identify the running VM as the unmodified starter.
This notes update adds documentation changes to that installed source record.

| Area | Observed result | Limit or open work |
| --- | --- | --- |
| Linux setup, rerun, local/public doctor | PASS after the doctor deadline correction | One Ubuntu x86-64 VMware guest; not every host or hypervisor |
| Dedicated Cloudflare tunnel and HTTPS | PASS; existing host's API remained reachable | Shared account resources must remain separate; cellular not tested |
| MSG91 and enrollment | Owned handsets received SMS; hidden-input administrator login, customer pending enrollment, approval and post-approval login passed | Provider acceptance is not delivery proof; native login and live provider-outage acceptance remain open |
| Gateway, metadata and load | CORS/body limits, upstream IP recovery and read-only Studio/meta checks passed; 100 HTTP requests had zero failures and p95 approximately 4.1 s | Smoke observations, no approved production SLO or sustained-load acceptance |
| Local backup and restore | Checksum, archived objects, database integrity and ACL comparison passed in an isolated disposable restore | Unencrypted local archive; no encrypted off-host or replacement-host recovery |
| VM reboot | Boot ID changed; Docker, tunnel and local/public health recovered | Host reboot, guest autostart without host login and USB reattachment remain untested |
| Android | Build/audit/install, Wi-Fi HTTPS discovery, selection and cold-launch server persistence passed | Debug build on Samsung SM-A346E / Android 15; no cellular, native authenticated workflow or iPhone acceptance |
| Pooler | VM session/transaction SQL queries and invalid-password rejection passed | Optional service; health alone is insufficient and restart/load behavior needs its own evidence |
| Monitoring | VM image builds, configuration checks, live scrape targets and local synthetic Alertmanager ingestion PASS; test exited 0 | Local receiver only; no external delivery or Grafana acceptance |
| Printing and sensors | Isolated CUPS software checks passed; no configured printer | Physical printing and sensor ingestion unfinished and unsupported |

The private VM ledger records build hashes, exact device identity, timestamps,
individual attempts and exceptions. The monitoring run survived a conversation
interruption and subsequently completed; its build-only intermediate state was
not counted as a pass. Pooler and the five tested monitoring services remain
running; their reboot recovery has not been repeated since they were enabled.

## Operator interaction and blockers

The first agent prompt bundled hostname, company, administrator details and
credentials. This caused confusion and unnecessary back-and-forth. Ask one
question, wait for its answer, validate it, then request the next required input:

1. Establish noninteractive sudo and host prerequisites before installation.
2. Ask for the **complete API hostname**, for example `pilot-api.example.com`.
3. Inspect occupancy; ask each needed Cloudflare ownership/management question
   separately. Complete the selected authorization and new route.
4. Ask for the exact warehouse company name.
5. Ask for the first administrator's Indian phone number; normalize before setup.
6. Ask for that administrator's display name.
7. Ask only for the path to the protected MSG91 provider file when setup needs it.
8. Request a second owned handset, hardware or recovery destination only when
   starting the corresponding acceptance case.

Reuse answers already given. Do not ask for certificates copied from an example
Windows host when VM CLI login is the chosen route. Offer browser assistance
when an authorization URL cannot be opened or copied, and never treat an elapsed
wait as authorization. A login link may expire; confirm the local command's
completion and presence of its protected output before proceeding.
The current installer is a CLI requiring explicit arguments; it does not provide
this conversational wizard itself. The agent must collect and validate the
answers in order, retain the non-secret choices and invoke setup once its
required inputs are ready. Do not describe these notes as a new interactive
installer implementation.

If a required input or failed prerequisite blocks the current stage, stop that
stage and state the exact blocker, next operator action and what remains
untested. Independent read-only/preparation work can continue unless the
operator asked to stop all work. Do not start dependent services or repeatedly
send OTPs to appear to be making progress. A user instruction to skip further
OTP delivery tests stays in force until changed. Record a waived test as
deferred, never passed. User interruption may leave a build or test running;
inspect its process and affected services before starting another copy.

## Host privileges, packages, paths and reruns

| Shortcoming or edge case | Required handling |
| --- | --- |
| Agent could not install Docker because sudo required a password | Developer/operator configures sudo with `visudo`; verify `sudo -n true` in the actual agent session. Never request the password in chat. |
| A visible `NOPASSWD` user rule still did not establish effective access | Later matching sudoers rules, including group rules and included files, can change the result. Validate syntax with `visudo -c` and test the effective grant. Avoid deleting unrelated rules. |
| Docker is installed but the agent cannot use its socket | Check daemon status and effective group membership. A newly granted group may require a new login/session or a deliberate `sg docker` invocation. Do not make the socket world-writable. |
| Interactive terminal succeeds but agent/service fails | Confirm Node/npm and SDK paths in that session. User-local PATH changes do not automatically reach existing agents, `sg`, sudo or systemd. Record versions and validate Docker Compose v2, not just the Docker client. |
| Compose warns that Bake is configured but buildx is absent | This VM continued with the default builder. Record the warning; distinguish fallback from an actual build failure. Install a compatible buildx plugin if the selected workflow requires it. |
| Initial capacity check passes but builds consume much more space/time | The 10 GiB preflight threshold is only an installation floor. Allow separately for container layers, Go caches, Node dependencies, Android SDK/Gradle, database growth and backup copies. Monitor actual free space and memory. |
| Security-patched images rebuild from source | The first Prometheus dependency/test/compile step alone took about 12 minutes and could be quiet while Go worked. Check process activity and resource pressure before diagnosing a hang. A started build or one completed image is not a passed monitoring test. |
| Port, state path, Compose project or service already exists | Inventory before mutation. Use the owned wrapper and selected absolute `WAREHOUSE_STATE_DIR`; resolve a collision explicitly. Never delete another project, volume or state directory to make setup pass. |
| State created as root or through a symlink | State/config ownership and private modes are enforced. Use the non-root installation account, mode-0700 state and mode-0600 secret files, outside every checkout. Repair only the intended directory. |
| Running from a separate review worktree | `scripts/compose.sh` refuses a project owned by another checkout. Run installed-stack checks from the installed checkout; review/build worktrees do not transfer container ownership. |
| Fresh configuration partially failed or rerun parameters differ | Inspect staged/existing state and installer diagnostics. Rerun preserves identity, keys, administrator and business data; it is not a rename, credential-rotation or instance-cloning interface. Do not regenerate state to bypass a mismatch. |
| Multiple installers/backups or a previous interrupted command | Respect the repository's locks and inspect active commands. Do not run concurrent mutations or remove lock/state files without establishing ownership and process state. |
| Local doctor reported failure during otherwise progressing readiness | Its original subprocess deadline was too short for the underlying container/HTTP probes. The reviewed fix allows 300 seconds for the local health script. Diagnose endpoint failures separately; merely extending a timeout does not fix them. |

Keep Git checkouts for source only. Database, document storage, configuration,
backups and acceptance evidence belong outside them. An isolated build worktree
may hold ignored build artifacts; signing credentials and operator data still
belong in private storage. Do not use broad Docker prune or Git reset/clean as a
setup recovery step.

## Git authentication, review and CI

GitHub write access was not ready initially. The operator completed browser/device
authorization on the VM; keep login codes, tokens and credential-store contents
out of chat and evidence. GitHub CLI authentication and Git's credential helper
are separate checks. Confirm the account can access the intended repository
without printing its token before attempting an authorized push.

Preserve the pinned installation checkout and use a review worktree/branch for
changes. Check the existing PR base/head and remote branch before a fast-forward;
do not replace another contributor's work or force-push to resolve divergence.
Execute an already authorized update without repeatedly asking the same question,
but do not infer permission to merge, publish or alter another branch from it.

The first backend run
[36313593609](https://github.com/abhiguru/supabase-warehouse-template/actions/runs/36313593609)
failed on the offline MSG91 fixtures; the corrected run linked above passed.
Record failed and replacement runs with their exact commits. A green older run
or unrelated main branch does not validate a new runtime commit.

`gh pr edit` encountered a deprecated Projects Classic GraphQL field during this
pilot. The intended PR body update succeeded through the supported repository
pull-request REST endpoint using the same authenticated account. If this occurs,
verify whether any edit already applied before retrying and limit a fallback to
the intended PR/body. Keep multiline bodies in a private file or structured
request; do not embed secrets or let shell interpolation rewrite their content.
Updating these notes alone does not push or merge the PR.

## Cloudflare and HTTPS isolation

The supplied Windows tunnel configuration was only a sample. Its hostname and
tunnel were already serving another machine. The initial request for a
"hostname" also led the operator to supply the parent website domain. Ask for a
full API subdomain and check DNS plus the current application before creating it.
An existing website response does not establish ownership of its warehouse API.

- Sharing a Cloudflare login does not mean sharing a tunnel is safe. Another
  connector on the same tunnel can receive traffic. Create a distinct named
  tunnel and credentials for the new VM; record the selected UUID privately.
- Never overwrite an occupied DNS record, delete/clean up another tunnel, stop
  another connector or reuse a sample tunnel UUID. A conflict blocks routing
  until the operator resolves ownership. Verify the existing service remains
  healthy after the new route is established.
- Locally managed CLI setup uses an account `cert.pem` to manage tunnels and a
  tunnel-specific JSON file to run the connector. Remotely managed setup uses a
  connector token. These credentials are not interchangeable. The account
  certificate is not the website's HTTPS certificate.
- When CLI management is chosen, run login on the VM and let the operator select
  the zone in a browser. Check command completion and restricted file ownership;
  do not infer completion from the browser alone. Keep all outputs outside Git.
- Windows credential paths do not exist on Linux. Use actual private Linux paths
  in the service configuration and ensure the service account can read them.
- The sample origin port 8000 is the container port; this VM's host gateway is
  loopback port 18000. Read the generated configuration before selecting it.
  A tunnel pointing at the wrong port can have a healthy connector but fail API
  requests. Do not expose the database, Studio, CUPS or Home Assistant to fix it.
- Do not copy sample tuning keys blindly. Validate them against the installed
  CLI and check ingress matching, including the final 404 rule. HTTP/2 origin
  transport requires a compatible HTTPS origin; the pilot gateway uses private
  HTTP. Preserve TLS verification for HTTPS origins.
- Inspect the route through Cloudflare's authenticated configuration as well as
  public DNS/HTTPS. Proxied DNS may answer with edge A/AAAA records rather than
  display a tunnel CNAME. An absent public CNAME alone is not proof of failure.
- Local health, correct public instance discovery, certificate trust, service
  boot persistence, Wi-Fi access and cellular access are separate checks.
  Record each. Test upstream container replacement separately from DNS and from
  unexplained application HTTP 500 responses.
- The IP limiter currently uses `CF-Connecting-IP` at the intended loopback
  gateway/tunnel boundary. If using a different proxy or allowing other ingress,
  establish trusted header handling and test spoofing/missing-header behavior;
  do not assume arbitrary forwarded headers are trustworthy. Phone/global limits
  remain active when a usable client IP is absent.

## MSG91 configuration, delivery and authentication

### Configuration traps

The first configuration supplied an auth-key placeholder and a prefix/suffix,
not the complete secret. A masked value cannot authenticate. Confirm presence
and validity using safe boolean checks; do not print a key to prove it was read.
If a key is pasted into chat, keep it out of subsequent messages, logs and Git,
and record the required rotation without copying the value. The pilot operator
deferred rotation and requested no further delivery retests; do not silently
rotate credentials shared with the existing server or resend another OTP.

The installer provider input accepts exactly `SMS_PROVIDER`, `MSG91_AUTH_KEY`,
`MSG91_TEMPLATE_ID`, `MSG91_PE_ID` and `MSG91_SENDER_ID`. Use the five-line example
in the installation guide. **Do not paste the full production environment into
that input file:** `SMS_PRODUCTION_MODE` and a separate DLT Template ID entry are
not accepted provider-input keys. Setup itself writes
`SMS_PRODUCTION_MODE=true` into the generated runtime environment.

Values must be nonempty, unquoted `KEY=value` entries without whitespace, inline
comments or the unsupported characters listed in the guide. The protected file
must be owned by the installation user. Validate identifiers before starting a
long installation: the SQL synchronizer expects a 24-character lowercase hex
Flow ID, numeric PE ID and six uppercase alphanumeric sender characters. These
format checks cannot prove provider ownership, DLT approval or account balance.

`MSG91_TEMPLATE_ID` is the **Flow ID**, not the numeric DLT Template ID. Keep the
DLT registration as separate documentation. The Flow API body uses the exact
case-sensitive variable `OTP`, `short_url="0"`, `realTimeResponse="1"` and a
`91`-prefixed 12-digit recipient. A ten-digit Indian number supplied by the
operator is normalized before invoking `setup.sh`; the setup CLI itself requires
12 digits. Do not prepend `91` twice. Reject ambiguous/invalid numbers rather
than guessing a different country's number.
PE/sender values are synchronized to the database, but the shown Flow request
does not transmit them as separate fields. Verify the selected Flow's approved
sender, message text and DLT mapping in the provider account; correct-looking
environment values alone do not establish that mapping.

The runtime reads the latest protected `public.sms_config` row, not the original
provider file. A seed-file edit alone does not update a running instance. For an
authorized rotation, update the private generated `config/compose.env` and rerun
the same operator setup to synchronize the database; then verify safely and keep
the retained seed file consistent. The existing Windows server's `.env` and
`rotate-keys.sh` instructions do not describe this Linux operator installation.
Confirm the selected instance before any synchronization and never grant public
read access to `sms_config` or copy a service-role key into the app.

### Reliability behavior and its remaining limits

The existing production example could swallow HTTP exceptions and return success
after marking a send. The reviewed pilot adapter checks both HTTP status and
MSG91's parsed success response before finalizing acceptance. It stores the
provider request ID when present or a fixed safe failure code, and suppresses raw
provider responses and secrets in client errors.

- Each provider attempt has a 10-second timeout. There are at most two attempts,
  with one 250 ms delay only for explicit error responses at 429/502/503/504.
- Authentication/validation errors are not retried. Neither are ambiguous
  network failures/timeouts, malformed responses or a contradictory success body
  with a failing HTTP status. An ambiguous timeout can follow provider acceptance;
  an automatic resend could create duplicate SMS.
- A five-minute challenge that expires while delivery completes fails closed.
  Failed/expired finalization does not become a successful client response.
  A database outage after provider acceptance can also leave an SMS arriving
  despite a client error; inspect safe state and never promise non-delivery.
- Success means MSG91 accepted the request. It does not prove the handset received
  it. Record provider acceptance, physical receipt, OTP verification, customer
  approval and application access separately.
- The operator implementation uses a cryptographically generated six-digit code
  and a keyed HMAC-SHA256 over phone, code and challenge ID. It is not an unkeyed
  SHA-256 digest of the code from the legacy description. Only the derived hash
  is persisted; plaintext exists only in the protected generation/send path.
  Verification is local, not MSG91's verify-OTP API.
- The current client path is the protected `operator-otp` Edge handler with
  internal SQL RPCs. Do not assume the legacy public `send_otp` endpoint is the
  operator app contract. Verify against the pinned companion mobile code.
- Circuit breaker/fallback-provider operation has not been accepted here.
  Automated rejected-provider tests are not a live outage/balance/template test
  against the operator's provider account.

Offline CI initially failed because its dummy Flow/PE identifiers did not meet
the new format checks. The fix supplied syntactically valid, non-deliverable test
values. Keep CI isolated from real credentials and SMS; never weaken production
validation or enable a fixed production OTP to make tests pass.

### Human timing, resends and approval

Several attempts were delayed by the operator moving between phone and VM
terminal. A five-minute expiry caused a real verification failure. One delayed
receipt also prompted uncertainty over which message was newest. Use this order:

1. Prepare the hidden-input verification helper before requesting an SMS.
2. Confirm the operator has the intended phone and terminal ready now.
3. Send one request, record only safe request ID/status/expiry, and prompt for
   immediate entry in the terminal. Never ask for the OTP in chat.
4. Inspect a newly timestamped result for that attempt. An older safe result file
   showing `pending` or success is not evidence that the latest attempt ran.
5. On failure, distinguish missing SMS, expired/superseded code, incorrect code,
   rate limiting and a helper that never ran. Do not immediately loop resends.
   Respect cooldown and phone/IP/global limits, and use the latest valid code.

A second customer number must be owned, able to receive SMS and different from
the administrator. Initial verification can correctly return `pending` without a
session. An administrator must approve and assign the customer; receipt or
approval alone is not proof of post-approval login. The pilot eventually passed
that login through the terminal helper. Administrator/customer JWTs were not
retained. These terminal/API results do not establish native UI acceptance.

## Android build, USB and app acceptance

- A fresh VM lacked JDK/Android SDK/ADB. Install compatible tooling and verify it
  from the build session. Record actual tool versions, source pair, build mode,
  app version/build number and APK hash; a successful JS test suite is not an APK.
- USB must be attached to the VMware **guest**, not just the host. Use a data
  cable, enable debugging, keep the phone unlocked and approve its RSA prompt.
  Treat `unauthorized`, `offline` and no device as different states. On this VM,
  restarting ADB with `ADB_USB_LEGACY=1` restored visibility; this is a recorded
  workaround, not a requirement for every host. Keep the exact serial private.
- The phone may show separate USB-installation or Play Protect prompts after
  debugging is approved. A long transfer is not proof of installed/launched APK;
  check the installation exit result and actual app on the handset.
- Use an isolated build worktree and a pilot package/name/scheme to avoid replacing
  an existing warehouse app. This pilot used `in.gurucold.warehousepilot`, version
  0.1.0/build 1, with local configuration overrides. A commit alone therefore does
  not completely describe the installed artifact; record those overrides too.
- The tested ARM64 debug APK passed the artifact audit and installed on Samsung
  SM-A346E / Android 15. Its SHA-256 is
  `192f22fc4d6af6c762124f4e9fb92d9e6be59f4beceb570a8138fea94883a530`.
  It requires Metro plus the intended USB forwarding. Metro/forwarding were
  stopped after acceptance; inability to relaunch without them is not evidence
  that the public API is down. A standalone signed release is still required
  for unattended use away from the build VM.
- USB/Metro connectivity must not be mistaken for the API network under test.
  Confirm the selected canonical public origin, returned identity and actual
  handset network. The observed Wi-Fi discovery and cold launch preserved the
  chosen server and reached login; they did not restore an authenticated session.
- This phone has no cellular data. Record cellular as NOT TESTED; turning off
  Wi-Fi cannot establish the missing network. Use a cellular-capable device for
  that case when available. No iPhone was supplied for this operator runtime.
- Honor the no-more-OTP instruction. Native login, authenticated restoration,
  business workflows, camera/documents and network recovery stay open until a
  permitted authenticated device test is possible. Historical source-demo phone
  evidence cannot be reassigned to this changed runtime.

## Monitoring, backups, reboot and hardware

Optional profiles are not enabled by core setup. Record which services a test
starts and leaves running, their bindings and their recovery scope. The pooler
test starts Supavisor; it must pass real authenticated queries on internal
session port 5432 and transaction port 6543 and reject bad passwords. Its HTTP
health can become ready before the SQL listeners.

The monitoring test builds and starts Prometheus, Alertmanager, PostgreSQL/node
exporters and cAdvisor. Some exporters mount host resources and cAdvisor uses
privileged access; inspect the selected manifest before enabling the profile.
The test checks live scrape targets and a synthetic alert stored in local
Alertmanager. The default receiver is `local-only`; this does not send an email,
SMS or incident notification. Grafana acceptance is separate. Ask for an owned
external receiver only when that delivery test is ready, then request remaining
credentials/escalation details one at a time and store them privately.

The manual backup contains private configuration, database and documents in an
**unencrypted** local archive. A mode-0700 directory does not encrypt it. A local
backup or VM snapshot can be lost with the host. The passed disposable restore
checks integrity and ACLs, not a bootable replacement deployment. Core backup
does not cover optional monitoring/CUPS volumes or automatically capture every
separately stored tunnel, provider, signing or sensor credential. Inventory them
explicitly in the recovery plan and protect key custody separately.

Before production, obtain the encrypted off-host destination first, then the
missing key-custody, schedule, retention and recovery objectives as each step
needs them. Test a replacement host using only those copies, including document
access, instance identity, tunnel routing and mobile reconnection. Disable the
old writer during an authorized cutover; do not accidentally leave two restored
instances writing independently behind one hostname/tunnel. Do not prune backups
or delete business records before the operator approves retention/hold policy.

The VM reboot passed with a changed boot ID and recovered services. That says
nothing about VMware host autostart without login, suspend/resume, disk unlock,
USB passthrough after host reboot or power-loss durability. The guide's Hyper-V
PowerShell example is not a VMware procedure. Identify the actual hypervisor
and configure/test host-side startup and graceful shutdown using its own tools.
Do not reboot a shared host or disrupt another machine's services by inference.

CUPS software startup/spool checks cannot establish Epson form alignment, paper
output, duplicate handling or fault recovery. No printer is configured on this
pilot. The Home Assistant/Tapo integration is likewise unfinished. Before any
sensor checkout, inspect its instructions: the existing `GCSTapoIntegration`
repository tracks `homeassistant/tokens.yaml`. Never place new tokens there;
use private external files/mounts. Real hardware, narrow ingestion credentials,
mapping, stale/missing timestamps and replay/idempotency still require work.
Printing and sensor capabilities remain disabled until their own acceptance.

## Remaining edge-case acceptance matrix

These are outstanding operator acceptance cases, not assertions that every case
is an observed defect. Some have automated coverage; that does not close the
real-instance, physical-device or business sign-off named here.

| Boundary | Cases to exercise before claiming that scope accepted |
| --- | --- |
| Authentication and abuse | Provider rejection/outage, delayed/ambiguous acceptance, expired/replayed/superseded codes, max attempts and resend cooldown, phone/IP/hourly/daily limits, missing/spoofed client-IP headers, pending/rejected/disabled users, revocation and expired enrollment; do not use real-SMS fault tests without an agreed window. |
| Native server isolation | Manual and QR input, malformed/untrusted origin, identity/API-version mismatch, switch during request/upload/mutation, cleared old cache/session, delayed old response, replacement instance at the same URL and cold restart on both platforms. |
| Native lifecycle and networking | Authenticated cold restore, refresh/revocation, logout, background/foreground, Wi-Fi/cellular transition, offline retry/reconnect, USB loss for debug builds and standalone operation without Metro. |
| Warehouse workflows | Editable identity/branding, customer assignment/pricing, receipt and inventory, orders/cart/queue, partial/final dispatch, invoices, PDF/image access; double submission, concurrent stock changes and failed/retried uploads must not create duplicate or unauthorized results. |
| Business calculations | Owner-approved rates, units, dates, taxes, rounding, partial dispatch, credits and reconciliation examples; compare independently expected values. Fictional calculation tests do not approve the warehouse's accounting policy. |
| Data isolation | Customer A/B and staff boundaries for lists, mutations, Realtime, images and private PDFs; expired/revoked links and sessions, no stale previous-instance data after a switch. |
| Capacity | Representative data/concurrency, declared latency/error thresholds, sustained load, memory/disk growth and bounded recovery. Existing smoke numbers are not an SLO pass. |
| Recovery | Scheduled encrypted off-host copy, failure alert, retention/legal hold, independent decryption/key custody, replacement-host restoration, restored permissions/documents and measured RPO/RTO. |
| Host lifecycle | Guest and physical-host unattended reboot, correct start order, graceful shutdown, tunnel recovery and any required USB reattachment. |
| Alerts | Real recipient delivery, acknowledgement, escalation, outage/recovery notification and behavior when the VM itself cannot send. |
| Physical integrations | Epson continuous forms/alignment/jams/offline/retry/duplicate outcomes; actual Tapo/Home Assistant ingestion, stale/offline indicators, clock/timestamp boundaries and replay. Cooling control remains excluded. |
| Release and security | Review/merge plus checks on the exact final pair, signed standalone native artifacts, required platform acceptance and recorded exceptions. Existing image-security findings remain unresolved under their recorded scope disposition; no new scan or security approval is implied. |

For each case record time, code pair plus local changes, tool/build/device identity,
expected and observed result, evidence location, cleanup and any reason for NOT
TESTED/FAILED/DEFERRED. Do not overwrite failed attempts with a later pass or mark
initialization, CI success and complete production acceptance as the same state.

## Unattended fixture/emulator run requested — in progress

The operator selected isolated fictional fixtures and emulator tests with no
further phone/OTP prompts. The production pilot remains excluded. A new private
`core-backend-test-2026093003` state belongs to a separate disposable checkout of
`09584d626d2a9f531aa9f467276a334aa98b949d`. Its private gateway was changed to
18080 before startup; the checkout received the CI-documented dedicated
10.233.245.0/24 network overlay after verifying no existing network overlaps.
Record that overlay as a local configuration change, not pristine HEAD. A
diagnostic initially mishandled null Docker IPAM.Config before any mutation;
corrected null handling passed the occupancy check.

Fresh unit, migrations, setup, local doctor, core API, customer A/B Realtime,
final account/image probes, Studio, gateway CORS/size, upstream-IP replacement
and retention preview passed. Container audit failed again. No skipped case
or fictional mock delivery counts as real SMS acceptance.

`scripts/emulator-fixture-bridge.mjs` uses the original fixture ownership,
identity and non-delivery-key guards before listening. Its HTTPS listener is
loopback-only. It forwards ordinary API and WebSocket traffic; only fictional
OTP requests use the existing service-only challenge/finish functions, with
cryptographically generated one-time values retained only in memory. The app's
HTTP response never includes a code. A private 0600 Unix socket in a 0700
directory supplies a code to the local test driver; no SMS provider is called.
This is a mock delivery harness for the disposable fixture, not a replacement
for warehouse authentication or provider acceptance. Nonfixture guard rejection
and syntax checks passed; positive emulator integration is still pending.

The bridge routing review found that URL resolution could accept an absolute or
scheme-relative request target. Restrict every HTTP/WebSocket upstream to the
owned fixture origin before forwarding. Runtime smoke passed normal forwarding
and rejected absolute, scheme-relative and backslash external targets. The first
restart diagnostic matched only absolute argv[0], while Node used relative
argv[0]=node; it refused to signal anything. A source copy therefore left old
code running and a new candidate refused the occupied socket. Correct exact
process selection stopped only the owned bridge, its handler removed the IPC
socket, and the restarted candidate passed the boundary smoke. No protected
host was contacted; original attempts remain private.


### Current unattended results and repeat instructions

The fixture checkout subsequently advanced to
`ee5b4936e2aa644667fe617f79e2a48b2eb67bbb` for the bridge boundary fix; the
local CI network overlay remains recorded. [UNATTENDED_FIXTURE.md](UNATTENDED_FIXTURE.md)
now gives the full disposable state, no-delivery provider, port, network,
ordered checks, TLS/IPC bridge and cleanup sequence. The installed Test Warehouse
1 runtime remains baseline f18f51d without source-content changes.

Current review CI [36659188131](https://github.com/abhiguru/supabase-warehouse-template/actions/runs/36659188131)
on ee5b493 completed with validation FAIL, contract PASS and redacted source/history
scan PASS; dependent operator installation, migrations and Grafana jobs were
SKIPPED. Preserve the merged baseline's seven passing jobs as historical evidence,
not evidence for this review head. The current container-audit failure remains
unresolved; no dependency upgrade/security disposition is implied.

Android API 35 software emulation booted and the fixture APK installed with a
matching read-back hash, but repeated System UI ANRs/crashes prevented reliable
UI automation. Reduced rendering resolution, disabled animations and emulated
Bluetooth did not establish stability. Crash-buffer inspection found system
failures and no fixture-package crash entry; this does not establish an app
root cause. The private UI driver initially used cached bounds; actions were
corrected to require a fresh hierarchy and foreground ownership, and refused
action when the app was no longer foreground. No stale-coordinate tap counts
as native acceptance. A separate API 30 software-emulator trial is recorded in
the mobile notes. No physical lock bypass, host change or host reboot occurred.


Current documentation-head CI 36664842242 on 23db880 again completed validation
FAIL, contract and redacted source/history scan PASS, dependent operator,
migrations and Grafana jobs SKIPPED. No skipped check counts as a pass.
The mobile raw fixture APK audit was rechecked: initial source94ead7e and
rebuilt943ab86 both failed on the public CA's .pem resource, correcting a
previous inaccurate PASS claim. The initial fixture APK was already installed;
observations/failures are retained. A later d4540c8 clean fixture build packages
the public CA as .crt and passes the unchanged audit, signature, package,
certificate-fingerprint and installed read-back checks. The normal physical APK
audit is separate and passed. See the mobile notes for exact source/artifact
identifiers and the Android scoped-picker functional correction.


### Repeat of the revised disposable guide

A new clean checkout pinned ee5b493 and new private state suffix2026093004
followed UNATTENDED_FIXTURE.md. Locked dependencies/configuration were prepared
while the earlier fixture ran; before applying the declared10.233.245.0/24
overlay/startup, the earlier bridge/emulator/fixture were stopped, and fresh
port/network occupancy checks passed. Only the documented network override and
private Kong port18080 differ from source. No hidden source edits occurred.

The first local doctor invocation failed at its10GiB disk guard: retained SDK/AVD
images and compiler trees reduced free space to9.4GiB during the concurrent
normal APK build. This is an established host prerequisite failure, not a
reason to weaken the guard. Three completed owned app/build directories were
reclaimed after matching each exact APK to its separately retained artifact.
Evidence, warehouse state, AVDs and signing material were preserved; no global
Docker prune was used. Free space returned to12GiB. The main installation and
mobile sequence now require maintaining the disk minimum throughout and
finishing disposable backend checks before heavy builds on constrained hosts.
The local doctor rerun PASS; clean unit48/migrations/setup/core API/Realtime/final
accounts/images/Studio/gateway CORS+size/upstream-IP replacement/retention preview
PASS. Container audit FAIL remains open. Same-input setup private comparisons
preserved config/manifest hashes, administrator, databaseOID, document metadata
and stored-file bytes (at least4 PDFs). New fixture04 was stopped without deleting
state/volumes. The original disk-guard failure remains in private evidence.


See [FRESH_VM_INSTALL_LEDGER.md](FRESH_VM_INSTALL_LEDGER.md) for the consolidated
dated source/artifact matrix and repeat policy. Preserve historical attempts;
rerun only for new changes, changed prerequisites or unresolved scope/failures.


Operator-requested pause: docs completed before the operator expands disk/reboots.
See the consolidated ledger for completed normal43b8320 arm64 build/audit, exact
artifact SHA and open signature/device checks; no reboot or physical update done.


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


Review-command findings on Ubuntu24.04.3/Git2.43.0/GitHub CLI2.45.0:
resumed git commit initially FAILed with Author identity unknown (private410).
Supply an explicit local author for review commits, for example
`git -c user.name='Warehouse Installation Agent' -c user.email='warehouse-install-agent@localhost' commit ...`; do not change global operator settings merely for this exercise.
`gh pr edit` again FAILed on deprecated Projects Classic projectCards GraphQL
(private422). Structured REST PATCH with a protected JSON input file updated
only the existing draft PR body; return only number/URL/draft/head. Prior bodies
and failures retained. Do not put credentials, multiline expansions or raw logs
in CLI arguments/PRs. Corrected commits/updates passed; no merge/release.


### Invoice blocker correction under verification — 2026-09-30

The operator promoted invoice reconciliation to the first blocker before long
unattended runs. Mobile review commit4709056c6abe07c8f583ae5e30788b38ddc91213
replaces duplicate two-decimal header calculations with the existing whole-rupee
preview/save contract and shows the rounding adjustment separately. No backend
pricing policy or installed Test1 source was changed. The native create path
actually uses the three-argument save_invoice wrapper/save_invoice_internal in
the initial schema; the earlier note referenced the one-argument migration,
which has the same header ceiling behavior. Preserve the historical e54
₹178.50 displayed versus ₹179 saved FAIL.

Exact current fixture03 checkout is c0a6db16a8e6ff23d56a8563703231b2f76b5da4
plus its declared local bridge boundary correction (byte-identical to reviewed
ee5b493) and subnet10.233.245/24. Earlier shorthand attributing that checkout to
ee5b493 omitted its actual HEAD/local-patch boundary; current private diff469
records it explicitly. Business runtime remains unchanged. Fixture04's clean
checkout evidence is separate.

Five new fictional API cases compare the same three-argument save overload,
server-calculated duration and private PDF metadata: 30days/storage100/labour40/
tax7/total147; 31days/150/40/10/200; 46days/200/40/12/252; storage150/labour20/
tax9 with discount2.50 gives177, and discount-2.50 gives182. All PASS (private468).
The supplied duration99 is ignored by the server as expected; saved duration
comes from receipt/dispatch dates. These are API/PDF tests, not native review or
confirmation evidence. IRN01 is a new fictional receipt left for the native
original-mismatch case; the old BAC01 invoice is retained.

Source checks230Jest/36setup/typecheck/lint0errorsPASS. Exact APK/native verification
is pending; invoice gate remains open. New one-day fixture certificate generated
in a separate private directory expires2026-10-01T09:51:45Z; verifiedTLS identity
PASS471. Rebuild/audit the fixture APK embedding that public certificate; never
reuse expired trust or disable TLS. Other blockers remain queued one at a time;
no overnight suite has started.


Follow-up native evidence on mobile4709056, fixture APK version2026093009,
SHA2562676332d1ba574782dd20a25332623434e6861382d104a0484d59f9ef67b2095:
IRN01 review/confirmation PASS at179 (no discount),177 (discount2.50),182
(surcharge2.50); native saved invoice20261006 at179, saved tax9/three server
durations and generated private PDF metadata PASS491. First cold launch had
system/SystemUI ANRs; recovering the app did not close unattended reliability.

Further mobile corrections9867569 and57add44 fix saved net-before-tax labelling,
hidden surcharge and binary half-cent rounding (0.29x1.5 must be0.44; x3.5 must
be1.02). Full239Jest/typecheck/lint0errorsPASS. Guarded SQL and backend preview
for new IRH01 storage0.44/tax1/total2 PASS505; it remains uninvoiced for the
follow-up native artifact. These fixes do not change the backend billing policy.

Other pre-run blockers: mobile6fa6553 restores CI for the stacked candidate PR;
run36705487757 appeared (job outcomes remain separately recorded). fa74f28 adds
a requested certificate lifetime guard, tested for invalid/insufficient horizons.
Mobile812d5ac adds a private bounded/checkpointed fixture runner; six runner
regressions and42setupchecks PASS. Its successful infrastructure tests are not
a completed long acceptance plan. See mobile docs/UNATTENDED_RUN.md.

PDF viewing remains BLOCKED: MJ PDF3.1.0 does not accept PDF SEND, Librera9.6.17
crashes on API30, and verified9.5.7 requires manage-all-files before copying the
shared PDF. Automatic approval review rejected granting that broad permission;
no permission was granted or rejection bypassed. An explicit emulator-only
approval question is pending. Existing PDF API authorization/content PASS is
separate from external reader rendering. No overnight suite, production change,
physical-phone change or real SMS was performed in this blocker-fix run.


Final invoice follow-up checkpoint: mobile57add4456cf47465771e3962f041928f8d6029d7
fixture version2026093010/x86_64 built7m32s, artifact audit/signature and installed
readback PASS. SHA256 c642950d24922b89119b9dacf91e0565a04f75f47e83bb3d286af07d12457676.
Native saved list/overview/breakdown PASS: net173+tax9=182, surcharge2.50 and
labour20 shown as included, discount case net168+tax9=177. New IRH01 native
review/confirmation/save invoice20261007 PASS: storage0.44, tax1, rounding0.56,
total2. Guarded PostgreSQL numeric line calculation, saved header/duration and
generated private PDF metadata PASS528. The PDF renders saved header and
quantity/rate/duration fields; it does not separately print a storage subtotal.

First final-artifact cold launch again encountered SystemUI ANR (private525),
so overnight readiness remains FAIL. One recorded Wait recovery allowed only
targeted invoice diagnostics. User explicitly approved Librera9.5.7/code7222
manage-all-files permission on the disposable emulator; verified grant520.
Native PDF rendering remains a separate check. Physical phone unchanged.
Mobile runner correctionb22c3b5 fixes eight CI lint errors without weaker rules;
local lint0errors/1468existingwarnings and six regression tests PASS. Full42setup
checks and guarded read-only runner/resume smoke remain separately scoped.
Backend CI36706798289 on9568421: contract/secrets PASS; Container source
dependency audit FAIL (brace-expansion/fast-uri), downstream jobs SKIPPED.
Deferred security findings and release gates remain open. No overnight run.

Final native PDF prerequisite result: after the explicit emulator-only permission
approval, final57/code3010 normal SharePDF -> verified Librera7222 -> Scroll mode
rendered invoice20261007. Visible tax1/total2 and line fields matched; the actual
reader-copy PDF number/header/line text reconciled529 PASS. Native rendering527
and prior viewer failures remain preserved. This closes the reader prerequisite
for this owned emulator only; cold readiness remains FAIL and the full overnight
plan/fault controls/second-instance work remain incomplete. Mobile main install
examples now pinb22c3b5 (same app/config/dependency files as built57, corrected
safeguards); example3011/full clean new-pin build remains NOT TESTED.

Cleanup follow-up on Ubuntu24.04.3/Node22.23.3/current fixture03: interrupting
the wrapped bridge session returned143 and closed its TCP listener, but left
its owned0600 IPC socket. Expected a clean restart; actual next bridge would
refuse the occupied path. Exact interruption/cleanup cause is not established.
After confirming owned services/listeners stopped, private parent ownership,
socket type/mode, ECONNREFUSED and unchanged inode, only that stale socket was
removed537 PASS. The same guarded recovery is integrated into UNATTENDED_FIXTURE
stop/start instructions. Live sockets and other instance state are never removed.


### Operator-requested pause before CPU upgrade — 2026-09-30

The operator will assign six total CPU cores to this VM and reboot it. At pause
the guest still exposes two CPUs/17GiB RAM/77GiB free; no KVM or vmx/svm. The
interrupted turn performed inventory and read existing ANR evidence; it did not
start a new emulator diagnostic. No host setting change or reboot was issued.
Private539 confirms fixture03/bridge/emulator stopped, owned ports/socket absent
and Test1 loopback18000/tunnel active. Persistent state, credentials, AVDs and
artifact/evidence are preserved; protected540 captures boot/source/artifact and
configuration fingerprints without displaying secret values.

On explicit resume, inventory six guest CPUs and compare boot/configuration
privately, verify installed Test1 local/public doctor and warehouse identity,
then perform bounded emulator OS-startup/ANR collection before app launch. The
launcher still uses two emulated cores; document a separate four-core trial if
needed instead of assuming the guest CPU change updates AVD configuration.
Recheck short-lived fixture certificate horizon and exact installed artifact.
Three clean app cold launches and a30-minute unattended rehearsal are proposed
prerequisites; no ANR dismissal is counted as readiness. Then complete clean
pinned mobile build, bound executable plan, guarded fault controls and second
authenticated fixture for dependent cases. Mobile docs/CPU_UPGRADE_RESUME.md
provides the full ordered procedure. No overnight run is started by this pause;
deferred security/hardware/provider/recovery/release gates remain unchanged.


### Eight-CPU/KVM resume and guarded lost-response controls — 2026-09-30

Operator resumed after reconfiguring this VM:8guest CPUs,17GiB RAM/78GiB free,
VT-x and accessible KVM API12. Effective sudo, Node22.23.3/npm10.9.9, Docker29.8.1/
Compose2.40.3 and Git2.43.0 verified. Installed f18 Test1 private config/input/
identity/source preservation and local/public doctor PASS543. A comparison-helper
octal-string formatting error caused one false refusal; correcting the helper,
without touching state, passed. Dedicated Test1 tunnel stayed active. No pilot,
recovery host, production credentials or ingress were used.

One KVM emulator startup was interrupted at the operator's permission pause;
its emulator-exited FAIL is preserved. Resumed API30/two-emulated-core startup
boot25.2s plus120s OS observation PASS, followed by retained code3010 three cold
launches and1804s/29cycles controlled native read/navigation/background rehearsal
PASS550. This closes that resource/artifact-scoped bounded gate only; previous
ANR failures and unsupported VMware acceleration limitation remain recorded.

Review2bbc681 adds optional fixture-fault-relay.mjs and
FIXTURE_FAULT_REHEARSAL.md. Normal start/setup never loads it. It keeps the
original operatorFixture guard, dummy provider, private state and Compose ownership
requirements; Test1 state was rejected before listeners571. Loopback18643/private
0600 IPC can drop exactly one supported fictional write before forwarding or
only after a complete successful upstream reply. Separate read-only database
postconditions prove commit; transport success alone is insufficient. Size limits,
absolute timeouts, exact-key/reserved-document matching and no overwrite of pending
arms have12regressions; full60backend unit checks PASS560. Its source file is a
declared overlay from2bbc681 in the existing c0a6 owning fixture checkout, alongside
the prior bridge-boundary/subnet overlays. Original guard and schema unchanged.

Four actual guarded API cases FXF101/102 receipts and FXF103/104 dispatches passed
pre-forward/no-commit and post-success/commit observations, same-key retry, stock
10->7 once and exactly one header/line/cache row566/572. Dispatches deliberately
used generate_invoice:false. These are new fictional cases, not reruns of the
completed core business scripts. Native lost-response/invoice effects remain
separate. Mobileb03f197 corrects the new-key-per-submit issue for identical numbered
RPC bodies; fresh246Jest/42setup/static/contract and clean code3012 standalone
build/audit/install PASS, native gate still open. Backend CI36717964417 contract
and secret/history scans PASS, validate FAIL at Container source dependency audit (unit step PASS), Shell syntax
and downstream SKIPPED; do not count
skipped checks or assume the explicitly deferred container audit gate closed.
No overnight suite, release, merge or recovery activity started.


### Native lost-response reconciliation and clean cache isolation — 2026-09-30

Ubuntu24.04.3/Node22.23.3/Docker29.8.1; guarded fixture03 backendc0a6db1 plus
declared bridge/relay overlays, standalone mobileb03f197/code2026093012/API30.
Before-upstream FXF201 and after-success FXF202 each displayed the expected
network error; private native-fault-state.mjs after-loss independently established
no commit versus one commit before the unchanged-form retry. Both native retries
showed Dispatch Created Successfully!; one dispatch header/line/cache and two
units each, reserved FXF200 stock10→8→6, no invoice error. PASS582/cleanup584.

The first after-retry verifier incorrectly required one persisted auto invoice
and failed583 despite correct dispatch/stock. Reading the existing SQL established
that p_generate_invoice calculates data, without calling save_invoice. Corrected
the private assertion to zero invoices and rechecked read-only; preserve the
initial FAIL. No business rule or installed warehouse data was changed. A read-only
wait for an invented success label was interrupted; exact native label is now
used. Native receipt fault acceptance and independent saved PDF acceptance remain
open. See FIXTURE_FAULT_REHEARSAL.md for the permanent verification sequence.

A fresh clean checkoutd068d77872110ede3b2c5097ae1d04ad2a3b9876 and separately
owned fixture05 (new identity/credentials/state, loopback18580, declared subnet
10.233.246/24) passed revised setup and full core API including known staff cache
keys denied to fictional CustomersA/B577–581. State is retained stopped after
the run; fixture03 successful writes were not repeated. Remote run36724067923:
contract/redacted scan PASS; validate fails at the existing deferred container
dependency audit; shell/downstream jobs SKIPPED. This is not all-green backend CI.


### Separate switching fixture backend prerequisite — 2026-09-30

Revieweda9a49863600dbb33935b49a721f3d406ede9302f adds a separate optional exact
fictional switching guard/bridge; original core validator and bridge remain unchanged.
62backend units PASS587; installed Test1 startup refusal before listeners PASS.
Fresh independent checkout/state/credentials/database/storage, loopback18590 and
declared nonoverlapping10.233.247/24, company Fictional Switching Warehouse,
canonical https://backend-switch.example.test. Supported setup PASS; first private
wrapper doctor failed because it omitted the already documented state environment.
Corrected export/local doctor PASS; failed log retained.

Own72-hour TLS key/public certificate differs from primary. A private Python
metadata accessor not_valid_after_utc was unavailable after generation; preserve
the successful material and use documented Node22 X509Certificate, without new
dependency or regeneration. Pinned TLS discovery on18444 and a dedicated VM
loopback443 transient socket passthrough, real OTP verifier with fresh private
crypto mock delivery, authenticated admin read and primary-phone refusal PASS.
The pass-through runs as the operator, reads no private TLS key and alters no DNS,
firewall, physical device, tunnel or production route. Native second-origin
switching now has exact dual-CA APK3013/native secondary login/profile/cache/
persistence evidence; one return discovery timeout remains a preserved FAIL,
with explicit Retry/primary login/read PASS separately. No full clean trip claim.

Use SWITCHING_FIXTURE.md for the full corrected setup/routing/start/stop sequence.
Backend nondefault canonical ports/replacing identity remain prohibited; do not
patch configure or reuse another instance to fit one ADB reverse. Mobilec4cb8d2
new independent certificate overlay43setup/lint PASS and code3013 exact build/audit/
install PASS592–594; no full overnight/physical/release claim. Remotea9 CIrun36731753334
is confirmed FAIL at Container source dependency audit. Contract and redacted
source/history scan PASS; migrations, Isolated operator installation and Grafana
jobs SKIPPED. Preserve deferred dependency and downstream release gates.

### Inherited Kong DNS search suffix delays native discovery

Ubuntu24.04.3/VMware, Docker29.8.1/Compose2.40.3/Kong3.9.3 on both owned
fixtures: `GET /functions/v1/get-public-config` took8.09–8.14s; a native
code3013 return/cold discovery timed out. Independent ownership-guarded direct
REST reads15–39ms; gateway reads4014–4071ms with X-Kong-Proxy-Latency4001–4002
and upstream10–33ms. Private namespace DNS-only trace showed SERVFAIL for
rest.localdomain at0/2/4s while rest A answered immediately. Docker resolver
inherited search localdomain despite ndots:0. This establishes the gateway
search delay; the exact individual native timeout cause remains unproven.

Review2584496f20a86595be2cf1996e9b4e5f82164fd8 sets Kong dns_search to the
DNS root, preserving host/other-container resolvers, TTLs, credentials,
authentication and upstream-IP refresh. Fresh clean fixture06 (new identity,
state and credentials; loopback18780/subnet10.233.248/24 declared) setup and
local doctor PASS599. Effective DnsSearch[.] confirmed; three REST reads4–40ms,
proxy0–2ms, missing/invalidkeys401 and identity discovery84ms PASS.62units,
migrations, gateway, upstream-IP replacement without Kong restart, full core API,
A/B Realtime, final API/private images/PDFs, Studio and retention preview PASS
once in the separately owned fixture. All raw results retained privately.
The installed Test1 and emulator fixtures have not yet received this correction
at this checkpoint; original latency/native failures remain preserved. The
container audit remains an existing FAIL. Main installation and fixture sequences
now pin the explicit reviewed correction before creating new state.

### DNS correction applied to both owned emulator fixtures

Exact reviewed258 Kong dns_search root overlay applied only to both owned
fixture gateways601, retaining credentials/identity/private state and unchanged
strict validators. Three local/direct/pinned TLS read probes returned promptly;
fresh clean core source258 full functional checks599 and same-input private
identity/credentials/administrator/business/Storage-metadata preservation605 PASS.
Fixture06 stopped normally with state retained. Stored PDF file bytes were not
rehashed by this preservation comparison; preserve that evidence limit.

Code3013 clean two-origin native actual-verifier trip602 PASS; corrected code3014
full ordinary two-origin trip610 PASS with no Retry/human/ANR dismissal/ADB reset.
Current3014 native receipts608 before/after response loss each showed native
error, independently proven no-commit/commit, unchanged retry and exactly one
receipt line/qty4/stock4/cached success; header images confirmed privately.
These use separate fictional fixture03 only. Test1 requestedf18 source stays
unchanged; no pilot/recovery/host DNS/production connector touched.

[Current backend CI36748327886](https://github.com/abhiguru/supabase-warehouse-template/actions/runs/36748327886):
validate dependency audit FAIL(brace-expansion HIGH/fast-uri MODERATE), contract
and redacted-history scan PASS; dependent functional jobs SKIPPED. Local fresh
checks do not turn skipped CI jobs into PASS or close deferred release gates.

### Scoped overnight run actually started — 2026-10-01 IST

After all required exact3014 launch cases/readiness/short-helper checks passed,
the owned user unit warehouse-fixture-overnight-3014 started at00:30:19IST
(19:00:19UTC30September). Actual unit active/running, PID2141593, first native
block RUNNING after two PASS preflights;44bound inputs/nine3200second blocks.
The plan performs native force-refresh/backend-observed reads, cold/background
cycles, reserved business invariant checks and same-session renewal observation.
No completed overnight PASS yet. All raw logs/session metadata/configs stay
private; no real provider, pilot/recovery/Test1 business mutation.

Exact read-only observer tooling98687380dc95e7200bf9888a9794a7a0dea12443 was
pushed and remotely verified. Installed primary/secondary fixture source heads
and every bridge/relay/DNS/subnet overlay are separately frozen in private hashes;
review tooling HEAD is not the installed backend HEAD. Unit Restart=no and
10hour maximum; ordinary stop is systemctl --user stop for that exact unit.
Next require every runner case/verify/final aggregate PASS, preserve any failure,
then update sanitized matrix/PRs. Dependency/physical/provider/release gates stay
open. See mobile UNATTENDED_RUN.md for the complete reproducible plan recipe.

## Current overnight status — 2026-10-01: FAIL, stopped

The supervised run started at 00:30:19 IST and stopped at 04:46:13 IST on
1 October (`warehouse-fixture-overnight-3014.service`, exit status 1, no restart).
Blocks 01–04 and their postconditions PASS: 208 native cycles over
12,801.18 seconds (3 hours 33 minutes) of completed soak. Block 05 FAIL after
40 additional successful cycles; its final assertion was
`Actual Orders RPC200 not observed within deadline`. Blocks 06–09 and the final
aggregate are NOT RUN. This does not establish eight-hour acceptance or a
completed session-renewal aggregate.

The installed artifact remains source
42a5559b4abcad3ddd7601b2e4885e3c29101c76, code 2026093014, SHA-256
6e882894ff4a0533b31e755fda6930aad6fea8c875030c083a887d445be5bb17.
The private plan/ledger and original failed evidence are retained. Diagnosis 615
preserved the owned gateway failure-window logs and emulator logcat without
clearing buffers or changing business data. Gateway Orders RPCs returned 200
through 23:15:00 UTC on 30 September; none was observed after that in the
23:13–23:18 UTC window. No matching gateway timeout/connection/DNS error was
found in that window. Android recorded `Network request failed` at 04:45:53–55
IST; cause is not yet established. The observer retries currently suppress
helper assertion details, so its final timeout alone cannot distinguish a
missing request from an observation failure.

Next: reconcile the failed interval with read-only bridge, emulator transport,
fixture session and business-state evidence. Preserve the failed plan; do not
blindly resume it, repeat receipt/dispatch writes, or change its bound inputs.
Make any established correction in a review branch and verify it in a separate
attempt. A new long plan needs a valid TLS horizon: the current fixture CA
expires at 09:51:45 UTC on 1 October and cannot cover a fresh eight-hour run
from this morning. Rebuilding with new trust requires auditing the new exact
artifact and repeating affected prerequisites, rather than carrying forward
old artifact acceptance. No operator input is currently needed for diagnosis.

Mobile tooling CI 36761863580 completed with all four jobs PASS. Backend
9868738 CI 36761784926 remains FAIL at the dependency audit; dependent checks
were SKIPPED. Existing security, real-provider and physical-device gaps remain.
Earlier RUNNING checkpoints below are historical observations.

## Network failure investigation and local backup — 2026-10-01

Evidence 615/616 supersedes the earlier unexplained block-05 timeout. Ubuntu
24.04.3 x86_64 VMware/eight CPUs/17GiB RAM, Node22.23.3, Docker29.8.1,
Compose2.40.3, disposable API30 emulator and unchanged source42/code3014 APK.
The prior four PASS blocks and fifth FAIL remain historical; no blind resume.

| Case | Result and evidence |
| --- | --- |
| Failure boundary | Established listener loss: core18443, switch18444 and relay18643 absent, all three helper processes absent; Docker18080 and emulator still active, reverse443 still targeted18443. Pinned TLS curl exited7. Old tool process sessions unavailable; private0600 IPC sockets stale. Exact termination cause NOT ESTABLISHED |
| Failure-window logs | Gateway Orders200 through23:15:00UTC; no later request in23:13–23:18 window. Native Network request failed at04:45:53–55IST. Checked window contains no gateway timeout/DNS/connection-error category, kernel OOM/segfault or Android crash/ANR evidence; this does not prove the process termination mechanism |
| Read-only reconciliation | PASS616: reserved quantities/business counts/saved invoice unchanged, original administrator session present, OTP verification count and session-ID set unchanged; refresh hash changed. No credential values logged |
| Diagnostic preservation | PASS616: original failed logs/results/plan and all44 original bound inputs retained with matching SHA-256, plus private failure-window gateway/Android logs and original transport source bytes |
| Consistent local fixture backup | PASS616 using owning checkout's scripts/backup.sh with explicit core fixture state and unused private destination. Script paused that fixture's write-facing services, captured database/Storage/config and restarted previous services. All7 archive checksum entries pass; pg_restore --list reads2201 catalog lines, Storage tar has71 members. Post-backup business invariants PASS. Unencrypted same-VM archive; no restore, off-host transfer or recovery-host test performed |
| Supervised dependency lifecycle | PASS616: persistent mode0600 unenabled user units core/switch/fault-network-616-v3, independent private append logs, Restart=no, NRestarts0, KillMode=control-group,12hour cap. Original owning guards unchanged. Actual core stop removed listener/IPC; explicit start restored them |
| Failed lifecycle attempts | Preserved616: stopped transient unit was discarded and start failed Unit not found; first persistent unit incorrectly quoted WorkingDirectory and systemd refused it. Reviewed generator now uses correct scalar syntax and real systemd-analyze verification before start |
| Bounded proxy handling | PASS75 backend tests including real socket refusal502, stall504, truncated response, client cancellation, genuine WebSocket exchange/reconnection, rejected/stalled upgrade. No HTTP fallback or silent retry of a write added; metadata excludes bodies, headers, queries and credentials |
| Native graceful failure | PASS616 on exact code3014: deliberate core bridge stop caused visible network error, retained already loaded order and login; harness explicitly refused dead dependency. Existing Snackbar expires after3seconds: persistent stale-data marking remains a limitation, not proof of current data |
| Native recovery | PASS616 on exact code3014: original restored-bridge60second case/verify; final reviewed transport120second case/verify,2 cycles with actual Orders200, invoice read/background/foreground/business invariants. Same original native session, no OTP request. These short cases are not overnight acceptance |
| Live fixture WebSocket transport | PASS616 both pinned TLS bridges: handshake/ping/close/reconnect twice. Does not establish every authenticated Realtime topic/event permission |
| Clean fetched source checks | PASS616: backend7e3f66a locked npm ci/13 transport tests, mobilec0824db/5 helper tests, status and complete preflight from unchanged fetched checkouts against existing owned disposable states. Review trees75 backend/48 mobile setup tests PASS. Full installation into a new state at7e3f66a NOT TESTED; prior258 clean installation599 remains separately scoped |

The infrastructure defect was supervising only the runner while depending on
terminal/tool-backed bridges. Exact original kill/disconnect cause remains
unknown. Helpers now retain independent process/journal/private request evidence.
Mobile preflight and native health require explicit managedUnits and refuse a
disappeared or automatically restarted helper. Observation separates missing
requests from ownership/observer/auth/server errors, retains safe categories/
counters/UTC windows and enforces the actual15second polling deadline.

Source fixes are reviewed backend7e3f66a34bb729d80e25c6a4a0975f072c05d03a and
mobilec0824db72b73a049f066a2259352c5207e393bb6. Installed backend fixture HEADs
remain c0a6db1/a9a4986 with previously declared overlays plus the exact reviewed
bridge/proxy files from7e3f66a; these runtime changes are explicitly hashed in
private evidence616. Installed APK remains42a5559/code3014/SHA256
6e882894ff4a0533b31e755fda6930aad6fea8c875030c083a887d445be5bb17.
Test1 source/state/ingress, live pilot, recovery host and physical phone were not
changed. No real SMS, business-write replay, insecure origin fallback, merge or
release occurred.

Next gate: renew independently owned fixture TLS and build/audit an APK with the
new trust before a new long run; current CA expires09:51:45UTC1October. Complete
affected exact-artifact prerequisites, freeze new config/unit/helper/source/CA
bindings and use an unused plan/evidence directory. Never relabel the failed
3014 run as PASS. The long suite remains incomplete and stopped; no timer is
scheduled. No operator input is required for the retained diagnosis. Backend
7e3f66a CI36819232397 FAIL at the existing dependency audit; inspect its exact
job results before claiming any downstream checks. Mobilec082 CI36819240073
was still running at this documentation checkpoint. Deferred security, provider,
physical-device/cellular and persistent stale-display findings remain open.

## Clean supervised-network reproduction — 2026-10-01

Ubuntu24.04.3/eight CPUs/17GiB, Node22.23.3/npm10.9.9, Docker29.8.1/Compose2.40.3.
Clean remotely fetched7e3f66a34bb729d80e25c6a4a0975f072c05d03a checkout, new owned
core-backend-test-2026100101 state, fresh fictional identity/credentials/DB/Storage,
dummy non-delivery provider and documented10.233.245.0/24 overlay only.
The earlier fixture03 was read-only reconciled and stopped with Compose down
without volumes; its failed-run evidence, consistent local backup and state remain.

Literal corrected configure/setup/local doctor PASS618. Required commands were
run once in guide order, preserving individual exits:75 unit tests, migrations,
operator-api-core, operator-realtime-core, operator-api-final, Studio, gateway,
gateway-DNS replacement, retention preview and live mobile contract all PASS.
check:container-dependencies remains FAIL at the deferred dependency findings;
this does not establish release readiness. No hidden source patch or guard change.

Renewed separate private core/switch certificates expire2026-10-02T05:43:04Z.
Reviewed persistent unit generator started core/switch/fault-renewed-2026100101
with independent private append logs, Restart=no/NRestarts0 and original ownership
guards. The switching loopback443 socket/service is a system unit, while these
three helpers are user units; checking only systemctl --user for the443 proxy
gives an incorrect inactive result. Its existing system listener was verified
without replacement. Fresh fictional625 API fault cases prove both receipt and
dispatch no-commit/commit and same-key reconciliation; invoice179/147/200/252/177/182
headers/durations/private PDFs PASS. This is API evidence, not new native evidence.

Mobilee217c1f2b22f74ea5aaabca5101c27aa166c5f68/code2026100101 built620/audited and
installed621 with both exact embedded public CAs and readback SHA-256
238ba669f3e14e1e0ea6d0dd396b8766fe5ce1482eae48e264a9af2f95900ed0.
Persistent stale-warning fix has RED/GREEN source evidence617; native gates
remain pending. New long run NOT STARTED at this checkpoint. No installedTest1,
pilot, recovery or physical phone change; no real SMS or old fixture write replay.

Native receipt checkpoint624: initial new-APK FXF301 case FAIL because the
armed control never fired; app reported successful creation. Read-only state
reconciliation retained exactly one receipt/line/received4/stock4/confirmed image.
No write replay. Revised main fault instructions configure the relay route
before cold app launch/draft preparation; unused FXF303 before-upstream then
PASS with independently proved no-commit before unchanged same-key retry and
actual native success. Existing connection reuse is not conclusively established.
After-success302 and other native gates are pending; no new long run yet.

Corrected after-upstream-success302 now PASS624 with actual native Error,
DROPPED_AFTER_UPSTREAM_SUCCESS, independently committed data before unchanged
retry, one header/line/qty4/stock4/cache and native success. Confirmed private
WebP images for retained301/302/303 PASS. This does not relabel301 fault failure.

Fresh same-input setup preservation628 PASS: same literal setup arguments,
then local doctor; instance/configuration hashes, administrator/customer/business/
Storage-catalog row hashes and all13 actual stored-file hashes unchanged.
No secret or row values were printed. This completes current7e clean guide
reproduction to the functional scope, while its dependency gate stays FAIL.

Native switching623b secondary login/data-isolation/cold launch PASS, primary
return FAIL at the unchanged administrator five/hour OTP limit. Daily/hourly
counts5, natural hour reset06:53:50Z1October, no new challenge after return.
The generic native60second countdown underreports that quota window; keep this
limitation. Supervised629 waits for the real reset before one normal request,
new clean round trip and30minute readiness. No counters/auth guards changed.
PDF626 current native SEND/render/new export/hash reconciles saved invoice182.
New8hour plan remains unlaunched pending remaining gates.

Automatic gated preparation/launch pipeline629/630 is now active under separate
owned user units (Restart=no, private logs,70/100minute caps). It waits the real
quota window, runs new clean switching and30minute readiness, captures private
actual native-session/business baselines, explicitly resets only owned helper
lifetimes before the plan, requires short native read/verify and all8 exact-APK
gates, freezes source/config/helper/unit/CA bindings and starts a new9×3200second
read-only native plan. First failure stops; no automatic retry or old write replay.
It has NOT started the8hour unit at this checkpoint. No current physical,
provider, revocation or release acceptance is inferred. Installation/build guides
are independently exercised; the operator-specific private UI/plan assembly
is not a published turnkey unattended suite. Preserve that reproducibility limit.

Current supervised progression: natural quota reset12:23:50IST, normal primary
login and unused clean native623c full authenticated two-origin trip PASS on
e217/code2026100101. Three cold launches PASS;30minute readiness is RUNNING.
630 will capture baselines/renew only owned helper lifetime before freeze and
perform final read/preflight/8-gate verification, then automatically launch the
new8hour unit. That unit is NOT STARTED at this checkpoint. No source/business
write or rate-limit modification was needed to clear the blocker.

### Prelaunch IPC readiness failure633 — 2026-10-01

Ubuntu24.04.3/Node22.23.3/systemd user services, current backend7e3f66a and
APK e217c1f/code2026100101. Native629 readiness PASS: three cold launches,
1802.6seconds/30cycles. Pipeline630 successfully captured business/session
baselines and explicitly stopped/started its three owned helpers, then failed
`socket.connect(faultSocket)` with ENOENT. Expected ready control IPC; actual
systemd start had returned before Node created it. Traceback establishes this
ordering defect; later all three units/listeners/private sockets were healthy.
Original630 FAIL/logs retained. The main supervised startup instructions now
wait at most30seconds for owned running services, mode0600 IPC and listeners,
then require DISARMED. No automatic service restart, authentication bypass or
business replay. Separate633 verification/short-read/launch remains pending
at this checkpoint; do not count readiness as eight-hour acceptance.

## Renewed eight-hour run started — 2026-10-01 13:17 IST

Separate corrected final gates633 PASS: bounded owned service/IPC/listener
readiness and relay DISARMED, preserved business/native-session/verified-OTP
count reconciliation, complete preflight, actual60second native read rehearsal
and its verify. Original630 ENOENT failure and successful captured baselines
remain retained; no transaction was replayed. All eight current-artifact
prerequisites PASS. Current readiness629 completed three cold launches and
1802.6seconds/30cycles. This corrects the earlier RUNNING/pending checkpoints.

Actual start2026-10-01T07:47:00.288137Z (13:17:00IST), active PID2211555,
unit `warehouse-fixture-overnight-2026100101.service`, first native block
soak-01 RUNNING after two PASS preflights.54 inputs frozen; plan SHA256
b18bcbd1cc1159a5e94f1ac196c58ee5ddca381a8fd26ddbe2ece19cf0150542.
Nine3200second read blocks plus postconditions/aggregate; no completed8hour
PASS yet. Native time alone ends no earlier than21:17IST; checks add time.
The runner has a10-hour cap, Restart=no and stops at the first failure.
No timer, automatic failed-case resume, authentication reset or write replay.

Runtime source remains clean backend7e3f66a in new fictional2026100101 state
plus documented subnet overlay; separately owned secondary retains declared
transport/DNS overlays. Current emulator APK sourcee217c1f/code2026100101,
SHA256238ba669f3e14e1e0ea6d0dd396b8766fe5ce1482eae48e264a9af2f95900ed0.
Plan froze backend toolinge85b152b2df5f5d6c8cb7fe81fd8e53f129ac1b4 and
mobile tooling73dc51c1b3911508c1f3a2d3a046685902f6ece8. Later documentation-only
commits do not change frozen executable inputs. Both private CAs expire
2026-10-02T05:43:04Z; helper12-hour windows cover this run and its cap.

Inspect the exact unit and protected631 start result/overnight ledger/results;
keep raw logs, phone/device/session values and hashes private. Do not run another
UI actor or edit bound inputs. Ordinary health/stop:

```bash
systemctl --user show warehouse-fixture-overnight-2026100101.service \
  --property=ActiveState,SubState,MainPID,NRestarts,Result
systemctl --user stop warehouse-fixture-overnight-2026100101.service
```

Next: observe without interacting with the emulator. If it fails, preserve the
ledger and diagnose/reconcile before a new separately frozen attempt. If it
finishes, require all nine block verifies and final business/session/duration/
actual-request/refresh-rotation aggregate PASS, then publish sanitized results.
A start or compilation is not end-to-end acceptance. Real SMS/current revoked
sessions, physical phone/Wi-Fi/cellular/noUSB, same-origin/unsaved-form switching,
current native dispatch faults, undefined related-GRN Breakdown label and
existing security/release gates remain open. Test1/pilot/recovery unchanged.

### Post-soak retry observer preparation639 — 2026-10-01

Source review found that fault-control `status` retains the first dropped key;
comparing it after retry does not independently observe the retry key. The optional
fixture relay now has bounded/redacted `observations` with ordering, changed-key
and overflow evidence. Follow the corrected main sequence in
[fixture fault rehearsal](FIXTURE_FAULT_REHEARSAL.md), including empty observations
before retry and exactly one matching observation afterward.

Separate review checkout, Ubuntu24.04.3, Node22.23.3; `npm ci --ignore-scripts
--no-audit --no-fund`, `node --test tests/fixture-fault-relay.test.mjs` PASS17 and
`npm test` PASS80, no skips. These use local stub sockets, not warehouse writes.
Active soak/runtime sources are unchanged; installing the reviewed relay and
native driver integration remain pending exclusive fixture access. No historical
transaction was replayed or erased. This is not new end-to-end acceptance.
