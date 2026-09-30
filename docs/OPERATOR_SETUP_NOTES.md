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
| Review CI | FAIL overall | Current [run 36647977248](https://github.com/abhiguru/supabase-warehouse-template/actions/runs/36647977248) at `11e8069aac8d81ce788800909c4ec58f411af0f5`: contract and secret scan PASS, validation audit FAIL, dependent jobs SKIPPED. Prior [run 36644865092](https://github.com/abhiguru/supabase-warehouse-template/actions/runs/36644865092) has the same recorded outcome. No skipped job counted as pass |
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
| Android native acceptance | PASS for build/install/manual discovery only | Clean corrected 8d9da8e APK built, audited, installed and read back with matching hash on Samsung SM-A346E / Android 15. Manual dedicated-server identity and HTTP/path rejection passed. Other native cases remain open; libusb ADB trial passed 61 probes over five minutes without a restart/reset/disconnect; root cause of earlier native-backend read failures remains unresolved. See mobile notes for full source/artifact boundary |
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
