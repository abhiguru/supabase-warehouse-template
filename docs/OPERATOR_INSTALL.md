# Operator installation

One warehouse per installation: a fresh Linux x86-64 host or VM owns its
database, document storage, credentials and canonical HTTPS origin. The
installer writes every private file to a state directory outside the Git
checkout and never touches another installation. This guide is current for
`main`. What is still open before production use is tracked in the
[acceptance ledger](PRODUCTION_DEPENDENCIES.md); nothing recorded elsewhere
validates a new installation.

Sections: [host prerequisites](#host-prerequisites),
[private inputs](#private-inputs), [setup](#setup),
[several facilities on one host](#several-facilities-on-one-host),
[authentication and OTP limits](#authentication-and-otp-limits),
[Cloudflare Tunnel ingress](#cloudflare-tunnel-ingress),
[external doctor](#external-doctor), [first-use checks](#first-use-checks),
[ordinary operation](#ordinary-operation),
[rotate signing keys](#rotate-signing-keys),
[backup and restore](#backup-and-restore),
[rerun and upgrade](#rerun-and-upgrade),
[Windows host with Linux VM](#windows-host-with-linux-vm),
[troubleshooting](#troubleshooting).

## Host prerequisites

- Linux x86-64 with Docker Engine and the Compose plugin, enabled at boot;
  Ubuntu 24.04 is the tested baseline. ARM64 is not supported.
  The requirement is a Compose plugin whose `docker compose up` accepts
  `--wait-timeout`. Setup, start and the backup scripts wait for services with
  `docker compose up --wait --wait-timeout`; `doctor` checks at the start that
  the plugin knows the flag and stops with a message if not. It checks nothing
  else about the version, and no version number is required. The central
  identity service states the same requirement and the same list below, so one
  host can run both services. Tested with:
  - Docker Compose v2.40.3 with Docker Engine 29.9.1 (the review host; verified for
    this service and for the facility backend);
  - Docker Compose v5.6.0 with Docker Engine 29.9.1 (the development host; verified
    for this service and for the facility backend).
- Node.js 22.18 or newer with npm, Git, OpenSSL, `curl` and util-linux (`flock`).
- A non-root user in the `docker` group. Do not run setup as root and do not
  make the Docker socket world-writable.
- At least 10 GiB free on a persistent filesystem for the initial installation,
  plus capacity for the warehouse's data; the doctor enforces the minimum.
- A **USB drive formatted exFAT for backups** (an existing drive is fine; it is
  not reformatted), and `sudo` once to set up the automatic copy. A backup on
  the same disk as the data does not survive loss of that disk; see
  [USB backup drive](#usb-backup-drive).
- `cloudflared` for the tunnel (installed in the ingress section).

Record the host before changing it (`cat /etc/os-release`, `uname -m`,
`free -h`, `df -h`, `docker ps`) so that an existing runtime is never removed
by accident.

### Ubuntu 24.04 sequence

Ubuntu's packaged Node 18 is too old. Install a user-owned Node 22 without
replacing the OS package, substituting the current 22.x release and verifying
it against Node's published checksum file:

```bash
sudo apt-get update
sudo apt-get install -y ca-certificates curl git openssl util-linux xz-utils dnsutils
NODE=v22.23.3
mkdir -p "$HOME/.local/opt" "$HOME/.cache/warehouse-node-download"
cd "$HOME/.cache/warehouse-node-download"
curl -fSLO "https://nodejs.org/dist/$NODE/node-$NODE-linux-x64.tar.xz"
curl -fSLO "https://nodejs.org/dist/$NODE/SHASUMS256.txt"
grep " node-$NODE-linux-x64.tar.xz\$" SHASUMS256.txt | sha256sum -c -
tar -xJf "node-$NODE-linux-x64.tar.xz" -C "$HOME/.local/opt"
export PATH="$HOME/.local/opt/node-$NODE-linux-x64/bin:$PATH"
node --version && npm --version
```

Repeat the `PATH` export in every shell that runs setup, doctor, start or stop,
and add it to `~/.profile` so new logins see it. The checksum file comes from
Node's HTTPS site; this is not a release-signature verification.

Install Docker from [Docker's Ubuntu repository](https://docs.docker.com/engine/install/ubuntu/).
Any Compose plugin whose `up` accepts `--wait-timeout` works (see the host
prerequisites for the tested builds). The commands below install the build the
review verified.

```bash
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc
printf 'Types: deb\nURIs: https://download.docker.com/linux/ubuntu\nSuites: noble\nComponents: stable\nArchitectures: amd64\nSigned-By: /etc/apt/keyrings/docker.asc\n' | sudo tee /etc/apt/sources.list.d/docker.sources
sudo apt-get update
apt-cache madison docker-compose-plugin        # lists the available builds
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin=2.40.3-1~ubuntu.24.04~noble
sudo systemctl enable --now docker
sudo usermod -aG docker "$(id -un)"
```

Open a new login session (or `sg docker`), repeat the Node `PATH` export and
confirm `docker version`, `docker compose version` and `docker ps` work
without sudo.

Clone the repository with `umask 022` so that container service users can read
the bootstrap files; keep `umask 077` for private state and provider files. A
checkout cloned under 077 produces mode-0600 initialization SQL, and PostgreSQL
then fails its first start with `Permission denied` while still reporting a
healthy process.

```bash
(umask 022; git clone https://github.com/abhiguru/supabase-warehouse-template.git backend)
cd backend
```

The operator scripts use only Node's built-in modules; `npm ci` is needed only
to run the test suite.

## Private inputs

**State directory.** An empty absolute path outside the checkout, not reached
through a symlink, on the persistent filesystem, mode 0700 and owned by the
installation user. The installer builds the state next to its final path
(`<state>.installing-<random>`) and renames it into place, so the **parent**
directory must belong to the installation user as well. Create both, the
second command without `sudo`:

```bash
sudo install -d -m 0755 -o "$(id -un)" -g "$(id -gn)" /srv/warehouse
install -d -m 0700 /srv/warehouse/acme
```

If you create only the leaf with `sudo install -d … /srv/warehouse/acme`, the
parent `/srv/warehouse` is created root-owned and setup stops with
`EACCES: permission denied, mkdir '/srv/warehouse/acme.installing-…'`
(see Troubleshooting).

**MSG91 provider file.** A mode-0600 file outside the checkout with exactly
these five keys. Values are unquoted and contain no whitespace, quotes,
backticks, backslashes, `$` or `#`:

```dotenv
SMS_PROVIDER=msg91
MSG91_AUTH_KEY=replace-with-owned-key
MSG91_TEMPLATE_ID=replace-with-approved-flow-id
MSG91_PE_ID=replace-with-owned-entity-id
MSG91_SENDER_ID=replace-with-owned-sender-id
```

`MSG91_TEMPLATE_ID` is the MSG91 **Flow ID** (24 lowercase hex characters),
not the DLT template ID. `MSG91_PE_ID` is numeric and `MSG91_SENDER_ID` is six
uppercase alphanumerics; the installer validates all three. The Flow's variable
must be named exactly `OTP`. Do not copy a complete legacy `.env` into this
file: `SMS_PRODUCTION_MODE` and any other key are rejected. The OTP worker
accepts a request only after MSG91 confirms it; an accepted API response still
does not prove handset delivery, so test with an owned phone. Real credentials
are mandatory: there is no fixed-OTP or local delivery mode. Keep the file out
of shell history and version control, and include it in your encrypted
off-host backups.

**Test installations (CI, review fixtures).** An installation that is not a real
facility never gets a real MSG91 key, because every accepted code request is a
real SMS. It uses the sentinel `MSG91_AUTH_KEY=isolated-no-delivery-key` (any
value that starts with `isolated-`) and an address under the reserved `.test`
domain, for example `https://backend-core.example.test`. The installer and the
doctor accept the sentinel only for such an address, and they never accept the
template text of this file's example (`your-…`, `changeme…`, `fake_…`). The OTP
function sends nothing to MSG91 when the key or the Flow ID is empty, template
text or the sentinel (the same rule, `scripts/provider-placeholder.mjs`), so no
SMS leaves even if the container has internet access. Do not rely on that alone:
start a fixture's `functions` container without a route to the internet (for
example on an `internal: true` Compose network, or with a firewall rule for its
address) and prove it with a request from inside that must fail. Tests that
need the provider's answer inject their own `fetch` and never call the real
service.

**First administrator.** The 12-digit phone number with the `91` prefix
(prepend `91` to ten Indian digits) and a display name. The administrator is
created locally and must complete a real SMS login before receiving a session.

## Setup

```bash
export WAREHOUSE_STATE_DIR=/srv/warehouse/acme
export COMPOSE_PARALLEL_LIMIT=1          # optional: gentler startup on small VMs
bash setup.sh --operator \
  --state-dir "$WAREHOUSE_STATE_DIR" \
  --api-url https://warehouse.example.com \
  --company 'Example Cold Storage' \
  --provider-env /secure/warehouse-msg91.env \
  --admin-phone 91XXXXXXXXXX \
  --admin-name 'Warehouse Administrator' \
  --alert-webhook-file /secure/warehouse-slack-webhook.txt
node scripts/doctor.mjs --local
```

`setup.sh` checks the host (`doctor --host-preflight`), generates a unique
Compose project name, signing keys and `config/compose.env` (mode 0600) in the
state directory, takes the per-state operator lock, verifies the configuration
and gateway port (`doctor --preflight`), starts only the database, applies the
migration ledger, configures auth, SMS and storage, bootstraps the
administrator, starts every service with `--wait` and runs the local doctor.
The gateway listens on `127.0.0.1:18000` only; database, Studio, CUPS,
the sensor bridge and monitoring are never published.

Optional services are Compose profiles that setup does not start:
`monitoring`, `printing`, `pooler` and `sensors` (the Tapo sensor bridge; set
up as in [SENSORS.md](SENSORS.md#run-it-as-a-profile-of-the-installation),
then `node scripts/set-capability.mjs sensors on` and a new `db:backup`). A new
state's `compose.env` carries the `SENSOR_*` and `TAPO_*` lines empty.

Setup also renders the monitoring files of this installation into the state
(`config/monitoring/`, and the empty `metrics/` directory the backup scripts
write), whether or not the `monitoring` profile is ever started. Alerts go
to the facility's own Slack channel, so the installer needs its Slack
incoming-webhook URL (the owner creates it in Slack: Apps → Incoming Webhooks).
`--alert-webhook-file /absolute/path` names a private file (mode 0600, one line)
holding the URL. Without the option, setup asks for the URL on a terminal (what
you type is not shown) and offers to post a test message, and without a terminal
it refuses. `--alert-webhook-file off` is for a non-production install: alerts
then stay on this host, setup warns, and `npm run doctor` warns `No Slack
webhook: alerts are not delivered` while the monitoring profile is running.
A rerun that already has a stored URL asks nothing. What each file is, the alert
rules, the daily "Monitoring is alive" message (a day without it means alerting
is broken) and the backup alerts are
in [MONITORING.md](MONITORING.md); several installations on one host each get
their own, distinguished by an `installation` label.

Running the same command again is safe: a rerun preserves identity, keys,
database and stored files (see [rerun and upgrade](#rerun-and-upgrade)). Setup
refuses an active administrator with a different phone, a state path through
a symlink or inside the checkout, a running project owned by another checkout,
and another operator command holding the lock. Private configuration belongs
outside the checkout; no source edit is needed for the documented installation.

## Several facilities on one host

One installation serves one facility: its own state directory, its own Compose
project (`warehouse-<instance id>`) and its own Cloudflare Tunnel. To run a
second facility on the same host, give it a separate state directory and its
own loopback gateway port with `--gateway-port` (1024 to 65535; the default is
18000):

```bash
bash setup.sh --operator --state-dir /srv/warehouse/second \
  --api-url https://backend-two.example.test --company 'Second Facility' \
  --provider-env /srv/warehouse/second-provider.env \
  --admin-phone 91XXXXXXXXXX --admin-name 'Second Administrator' \
  --gateway-port 18001
```

- Setup test-binds `127.0.0.1:<port>` first and refuses a port that is in use.
  The port is saved as `KONG_HTTP_PORT` in the state's `config/compose.env`;
  no manual edit is needed, and `doctor` and the smoke scripts read it from there.
- A rerun without `--gateway-port` keeps the saved port. A rerun with another
  port replaces only the `KONG_HTTP_PORT` line, and only while that
  installation's containers are stopped (`bash stop.sh`, then setup again).
- Each tunnel's ingress must point at its own port: change the `service:` line
  of that facility's `cloudflared` configuration to `http://127.0.0.1:<port>`
  and restart that tunnel ([Cloudflare Tunnel ingress](#cloudflare-tunnel-ingress)).
  Setup prints this reminder when it sets a port.
- **Give every facility a state directory with a different last part** (here
  `second`, not `state`). `scripts/tunnel.sh install-service` names the
  tunnel's systemd unit `warehouse-<last part of the state path>-tunnel.service`,
  so two facilities whose state paths end the same would share a unit name, and
  installing the second would replace the first one's unit and restart it with
  the second facility's credential.
- **The automatic USB backup serves one installation per host:**
  `/etc/warehouse-usb-backup.conf` holds one state path, and
  `backup-usb.sh setup` for a second state refuses with "already set up". Back
  the second facility up with `npm run db:backup -- /absolute/destination` (run
  with that facility's `WAREHOUSE_STATE_DIR`) to a drive or directory of its
  own, or with the backup disk, and keep each facility's backup key separate.
- The host's Docker daemon and its resources are shared. Never point two
  installations at the same state directory or port.

## Authentication and OTP limits

Login is phone OTP only, delivered through MSG91. Customers who sign up stay
pending until an administrator approves them from Enrollment Review; staff and
administrators are created by an administrator. There is no create-user
screen: the person signs in once, an administrator approves them, and then
sets their role under Settings → Users → edit. Every accepted code request
is a real SMS billed by MSG91 (there is no test or fixed-OTP mode), so budget
for it: a full acceptance run with three roles, a restore and a key rotation
used about 24 codes. Limits enforced by the database:

- OTPs expire after 5 minutes.
- A code is stored only as a keyed hash, HMAC-SHA256 over `phone:code:request id`
  keyed with the instance's JWT secret (the `jwt_secret` entry of
  `warehouse_security.auth_config`), never as the code itself and never as a bare
  SHA-256 of it. A signing-key rotation changes that secret
  ([Rotate signing keys](#rotate-signing-keys)), so codes issued before it stop
  verifying and the user asks for a new one.
- A resend does not void the earlier code: every delivered code stays valid
  until its own expiry, and a successful verification consumes all of them.
- Expired OTP rows are not removed on a timer. Every 100th new code removes the rows that expired more than an
  hour ago or were verified more than a day ago, and `npm run retention:apply`
  removes expired OTP rows older than 7 days (the `ephemeral_auth` retention
  policy; see [Retention](#retention)). On a site with few sign-ins the rows stay
  until then, so run the retention command from the same scheduler as your
  backups. Sessions are HS256 JWTs signed with the instance's `JWT_SECRET`.

Anyone can ask for a code for any number. The limits therefore have a fixed
order of priority: first, a code cannot be guessed more than five times;
second, one phone is not sent more than 30 SMS in 24 hours; third, inside
those two bounds, a stranger cannot keep a real user from signing in on a
network that user has signed in from before. A phone is **known** when it has
an approved, active profile; a **source** is the caller's address
(Cloudflare's `CF-Connecting-IP`); a source is **trusted** for a known phone
when a sign-in for that phone was completed from it in the last 90 days (the
last five such sources are kept).

| Limit | Value | Applies to | When it is reached |
| --- | --- | --- | --- |
| Per phone, all sends | `otp_phone_daily_cap`, default 30 in any 24 hours, every source and lane together | every phone | 429 "Too many OTP requests. Try again later." |
| Open lane | 5 per hour per phone, and the daily cap less the trusted reserve (30 − 10 = 20) in any 24 hours, shared by all sources that are not trusted | every request that is not from a trusted source | same 429 |
| Trusted lane | 5 per hour per phone and trusted source, up to the per-phone cap of 30; `otp_trusted_daily_reserve` (default 10) of the 30 cannot be used by other sources | known phones, from a trusted source | same 429 |
| Resend cooldown | 60 s per phone and source | every request | 429 "Please wait before requesting another OTP." with `retry_after_seconds` |
| Per source, sends | 30 per hour over all phones | every request with a source | 429 "Too many OTP requests. Try again later." |
| Warehouse cap | `otp_global_hourly_cap`, default 300 per hour; text `0` is the no-send switch (below) | every request | same 429 |
| Provider requests | `otp_daily_provider_attempt_cap`, **off until you set it**: the most requests made to MSG91 in any 24 hours, a retry counted as a second request, a refused or timed-out one counted too | every request | same 429, and no SMS is sent |
| Unknown-number share | `otp_unknown_hourly_cap`, default 60 per hour, part of the warehouse cap | phones that are not known | same 429; known phones are still served |
| Wrong codes | 5 per issued code in all, from every source together; sources other than the one that requested the code share 2 of the 5 | every verification | 400 "Invalid or expired OTP" |
| Per source, failed verifications | 20 per hour over all phones | every verification with a source | 429 "Too many OTP requests. Try again later." |
| New access requests | 3 per source and `enrollment_daily_cap` (default 30) for the warehouse, per 24 hours | a verified number that has no profile yet | No SMS is sent for a number that would exceed it (429 "Too many OTP requests..."); a verification that exceeds it answers 429 "Too many new access requests. Try again tomorrow." |

What this means in practice:

- The hourly open-lane counter is a **fixed window**, not a sliding one: a
  window opens at the first request after the previous one has expired and
  lasts one hour, so a phone whose requests straddle a boundary can receive up
  to ten open-lane codes within sixty minutes. The 24 hour counts are sliding:
  each code stops counting 24 hours after it was requested. The limits are
  checked before the cooldown, and a refused request sends no SMS.
- No phone is sent more than 30 codes in any 24 hours, whoever asks. Of these,
  sources that are not trusted can cause at most 20.
- Someone who requests codes for the administrator's number from one address
  or from many uses up the open lane: 5 an hour, 20 in 24 hours. **While that
  goes on, the administrator can still get a code on a network they have
  signed in from before** (trusted lane, 5 an hour, at least 10 in 24 hours
  that nobody else can use), **but may get none from a brand-new network** (a
  new SIM, a carrier address that changed, another Wi-Fi) until the attack
  stops, the window passes, or the operator clears the phone's counters (next
  paragraph). The trusted sources of one phone share the reserve between them.
- Someone who guesses codes for another person's number can use up two of the
  five attempts of each code. The person who requested the code keeps at least
  three, as long as they verify from the address they requested it from. A
  phone that changes network between request and verification (Wi-Fi to mobile
  data) counts as another source and has the two shared attempts; requesting a
  new code on the new network gives the full five again. No code can be tried
  wrongly more than five times, so a guesser's chance per code is the same as
  before these lanes existed.
- What remains possible: a caller who shares the user's public address (same
  Wi-Fi, or the same mobile-carrier gateway) is the same source and can use up
  that user's attempts, cooldown and trusted allowance. A single address is
  enough to keep the open lane of a phone full, and a flood from many
  addresses can also fill the warehouse cap. If either happens, add a
  Cloudflare WAF rate rule on `/functions/v1/operator-otp/request` and
  `/verify`.

**Clearing one phone's counters.** When a user cannot get a code because
someone else has used up the limits of their number, run on the server (the
number is the user's 10-digit mobile):

```bash
export WAREHOUSE_STATE_DIR=/absolute/path/to/this/warehouse
bash scripts/compose.sh exec -T db psql -X -U supabase_admin -d postgres \
  -c "SELECT warehouse_security.reset_otp_limits('9XXXXXXXXX')"
```

It prints how many counted codes it cleared and the user can request a code at
once; only `supabase_admin` may run it, no app role can. It clears the
per-phone counts only (not the per-source or warehouse limits, and not the
60 s cooldown), leaves codes already sent valid and keeps the phone's trusted
sources. If the requests continue, the limits fill again within the hour: put
the WAF rule in place first, then clear. Each clearing allows up to 30 further
SMS to that number.

- A send that MSG91 did not accept (outage, rejection) is not counted against
  the phone or the warehouse cap, so a provider outage does not lock users out.
  Two outcomes stay counted: a number MSG91 calls invalid, and a **timeout**
  (`provider_ambiguous`), because MSG91 may have accepted and billed the request
  before the answer was lost. The per-source count is kept either way.
- **Spend ceiling.** Those allowances count codes, not what MSG91 bills: a
  refunded send may still have cost a request, and one code can cost two
  requests (the function repeats a request once when MSG91 answers 429, 502, 503
  or 504 with an explicit error; it never repeats after a timeout). The database
  therefore also counts every request made to MSG91 for every code, whatever the
  outcome, in `warehouse_security.otp_provider_attempts` (kept two days, never
  refunded). To cap them, set `otp_daily_provider_attempt_cap` to the number of
  requests you are willing to pay for in 24 hours; when it is reached the
  request answers 429 and nothing is sent until older requests leave the 24-hour
  window or you raise it. It does not exist until you create it, and a value that
  is not a whole number means no ceiling:

  ```sql
  -- as supabase_admin: set, or change, the ceiling
  INSERT INTO warehouse_security.auth_config(key,value) VALUES ('otp_daily_provider_attempt_cap','2000')
    ON CONFLICT(key) DO UPDATE SET value=excluded.value;
  -- requests made in the last 24 hours
  SELECT COALESCE(sum(attempts),0) FROM warehouse_security.otp_provider_attempts WHERE created_at>now()-interval '24 hours';
  -- remove the ceiling
  DELETE FROM warehouse_security.auth_config WHERE key='otp_daily_provider_attempt_cap';
  ```
- **No-send switch.** A cap of text `0` is accepted and blocks every send: set
  `otp_global_hourly_cap` to `0` to stop all SMS at once (every request answers
  429 and no code is created), then back to its value (default `300`) to resume.
  `otp_daily_provider_attempt_cap` set to `0` does the same.
- **What the facility keeps of MSG91's answer** (the contract the central
  identity service mirrors). A success answer carries MSG91's request ID in its
  `message`. The facility trims it, accepts 1 to 255 characters of
  `A-Z a-z 0-9 . _ : -`, and stores it in `otp_verifications.msg91_request_id`
  with `msg91_status` `success`. It lives in that sign-in row and goes with it
  (the cleanup bullet above; `retention:apply` removes it 7 days after the code
  expired). It is never returned to a client or written to a log, and nothing
  else of MSG91's answer is stored or logged. A success **without** such an ID (no message, a blank or non-text one, one over
  255 characters, other text) is still a success: the code is
  treated as sent and stays valid, no second SMS is sent, the status is
  `success_no_id` and the function logs the fixed line
  `operator-otp: MSG91 accepted a send without a request ID`. An answer whose
  `type` and `status` disagree (one says success, the other error) is not an
  acceptance: with HTTP 200 it is refused as `provider_invalid_response`, with a
  failing status as `provider_unavailable`, and it is not repeated.
  To count the sends without an ID in the last two days:

  ```sql
  SELECT count(*) FROM warehouse_security.otp_provider_attempts WHERE status='success_no_id';
  ```
- While the unknown-number share of the warehouse cap is used up, a known and
  an unknown number get different answers, so a caller can tell during that
  time whether a number is registered. A used-up open lane answers the same
  for both.
- The name typed by a new user is shown in Enrollment Review. Letters of any
  script, digits, spaces and `. , ' & ( ) / -` are kept, cut to 30 characters;
  a name with anything else (markup, a link) is stored as "New customer".

Change a cap with, for example,
`UPDATE warehouse_security.auth_config SET value='500' WHERE key='otp_global_hourly_cap'`
(as `supabase_admin`). The unknown-number share can never exceed the warehouse
cap. The trusted reserve can never exceed the per-phone cap; a reserve equal
to the cap closes the open lane, so only trusted sources get codes.

**Sessions.** The access token lives one hour (`JWT_EXP`); the app renews it
with a refresh token that is replaced at every renewal and is valid for 7 days
from sign-in. If the app repeats a renewal within 60 seconds because the answer
was lost on a slow network, it receives the same new token again
(`refresh_grace_seconds` in `warehouse_security.auth_config`, 0 to 300). A
replaced refresh token that is presented later, or one from an earlier
generation, means two devices hold tokens of one session: the session is ended
for both and the user signs in again. The database log then carries
`Refresh token reuse: session ... revoked`.

Disabling a user (`update_user_status(false)`) revokes their sessions; enabling
them again re-approves a disabled or rejected profile.

**The last administrator.** The only active administrator cannot delete their
own account, and an administrator cannot be deactivated or given another role
when no other active administrator would remain. If a warehouse nevertheless
has no administrator who can sign in (for example one deleted before this
rule existed), rerun the setup command with `--admin-phone` and `--admin-name`:
when no approved, active administrator exists, setup makes the profile with
that phone an administrator again, or creates one. An existing profile keeps
its name. Setup still refuses to act when another administrator is active.

**Replacing MSG91 credentials.** Write the new values to a mode-0600 provider
file and rerun the same setup command with `--provider-env` pointing at it.
The rerun replaces only the `SMS_PROVIDER` and four `MSG91_*` lines of
`config/compose.env` (atomically, mode preserved), reports "Updated MSG91
provider settings in existing operator state.", recreates the database
container with the new environment and synchronizes the protected
`public.sms_config` row. Identity, paths and signing keys are untouched; an
unchanged provider file leaves the configuration byte-identical. Send yourself
a code afterwards.

## Central sign-in

Optional, and off by default. A member of the association can let people sign
in with the association's central identity service instead of an SMS code
sent by this facility. SMS sign-in keeps working. What you then rely on the
central service for, and what you do not, is the first section of
[CENTRAL_LOGIN.md](CENTRAL_LOGIN.md#what-the-facility-relies-on-the-central-service-for):
in short, it vouches that a phone number belongs to a central account; it
cannot approve anyone here, but its sign-in alone opens an existing person
profile with that number (administrators included) unless you switch on this
facility's own extra code, `--central-local-code on` below.

Turn it on with the issuer the association gives you and **one** source for
its public keys, added to the usual setup command (first installation or
rerun):

```bash
# keys fetched from the association
bash setup.sh --operator \
  --state-dir "$WAREHOUSE_STATE_DIR" \
  --admin-phone 91XXXXXXXXXX --admin-name 'Warehouse Administrator' \
  --central-issuer https://login.association.example \
  --central-jwks-url https://login.association.example/.well-known/jwks.json

# or: keys from a file the association sent you
bash setup.sh --operator \
  --state-dir "$WAREHOUSE_STATE_DIR" \
  --admin-phone 91XXXXXXXXXX --admin-name 'Warehouse Administrator' \
  --central-issuer https://login.association.example \
  --central-jwks-file /secure/association-jwks.json
```

- `--central-issuer` goes with exactly one of `--central-jwks-url` and
  `--central-jwks-file`. The issuer and the address must be `https://`. The
  issuer is stored exactly as typed, because it is compared with the token as
  a string.
- **Address or file?** With the address the functions container fetches the
  keys over HTTPS when a sign-in needs them, and a key the association rotates
  is picked up without you. With the file nothing is fetched at all, so
  sign-in does not depend on reaching the association; but when the
  association rotates its keys it has to send you the new file first, and you
  rerun the command above with it. Until you do, central sign-in fails and SMS
  sign-in still works.
- The file is checked (a JSON key set of at most 64 KB with at least one
  usable P-256 public key; a file that contains a private key is refused) and
  copied to `public/central-jwks.json` in the state directory. Your original
  is not needed afterwards. A rerun with the option replaces the copy. The
  running service reads the file when it starts a worker for a sign-in, so
  the new keys should be in use within about a minute; this has not been
  measured, and `bash stop.sh && bash start.sh` makes it certain.
- **If the association withdraws a signing key in an emergency.** With the
  address, nothing is needed: the facility refuses the withdrawn key within
  300 seconds (it uses a fetched key set for at most 4 minutes). With the
  **file**, the withdrawn key stays trusted until you replace the copy: get the
  new key set file from the association (without the withdrawn key, with the
  key that now signs) and rerun the command above with
  `--central-jwks-file <new file>` and the same `--central-issuer`. Then run
  `bash stop.sh && bash start.sh` so the next sign-in surely reads the new file
  (it is read when a worker starts, within about a minute without a restart).
  Do this as soon as the association tells you; nothing else ends the trust.
- The settings are `CENTRAL_ISSUER`, `CENTRAL_JWKS_URL` and
  `CENTRAL_JWKS_FILE` in `config/compose.env`; setup also writes the issuer to
  the database. A later rerun without the central options keeps everything.
- Turn it off again with `--central-issuer off` (and no key option). People
  who signed in centrally keep their profiles and sessions; they sign in with
  an SMS code from then on.
- `--central-local-code on|off` (default **off**): with `on`, this facility also
  sends its own SMS code and asks for it at **every** new central sign-in, for
  every approved profile. Leave it off to let the association's single sign-in
  open this facility; the price is that whoever controls the central service,
  or a number's SMS there, can open any person profile with that number here.
  It is refused unless central sign-in is configured (in the same command or
  already). A rerun without the flag **keeps** the stored value, like the
  other central settings (also when the issuer or the keys change);
  `--central-local-code off` switches it off and `--central-issuer off` clears
  it with the rest. It is stored as `CENTRAL_LOCAL_CODE` in `config/compose.env`
  and written to the database (`auth_config` key `central_local_code`) by the
  setup run. A service account (a machine, migration 78) is never opened by the
  central sign-in whatever this says.
- Changing these settings recreates the functions container during that setup
  run. The database container is not touched.
- Check: `curl -s https://<your origin>/functions/v1/get-public-config` shows
  `"centralLogin":{"issuer":"…","localCode":false}` when it is on (`localCode` is
  `true` with `--central-local-code on`) and `"centralLogin":null` when
  it is off or a value is unusable.

With an address, the functions container must be able to reach it over HTTPS.
When it cannot, central sign-in answers "temporarily unavailable" and SMS
sign-in is unaffected.

**After an in-place restore, check that the database and the configuration
agree.** The trusted issuer lives in the database as well as in `compose.env`,
and setup is what makes the two agree: a database restored from before you
turned central sign-in on (or off) otherwise disagrees with the configuration,
and central sign-in answers "not available" until you have run `setup.sh` again
with your usual inputs.

**The key file travels with the backup.** `public/central-jwks.json` (public
keys only) is copied into every backup as `central-jwks.json`, listed in
`SHA256SUMS` and so covered by the signature; `db:verify-restore` checks it and
a [lost-host restore](#recover-a-lost-host-from-the-usb-drive)
(`db:restore-host`) puts it back, mode 0644, with no setup run. A backup written
before that holds no copy: `db:restore-host` then ends by printing the exact
`setup.sh --operator … --central-issuer … --central-jwks-file …` rerun, which
keeps the instance identity and replaces nothing but the key file, and
`node scripts/doctor.mjs` fails until you have run it. Keep the key set the
association sent you for that case.

An in-place `db:restore --restore-config` can bring back a `compose.env` that names
a key file this state no longer has (setup deletes it when central sign-in moves
to an address or off). `db:restore` does not touch `public/`, so it finishes,
its last `doctor --local` only warns, and it prints the same `setup.sh` rerun.

`doctor` (`--local` and the full run) fails whenever `CENTRAL_JWKS_FILE` is set
and `public/central-jwks.json` is missing, not a regular file, larger than
64 KB, not JSON or without a usable P-256 key: without the file every central
sign-in fails while the app still offers it.

A person who already has a profile here is linked to the central account by
the first central sign-in with the same phone number (no code, unless the
facility's own code is on); approving, revoking and the one new
administrator action (unlinking a profile) are described in
[CENTRAL_LOGIN.md](CENTRAL_LOGIN.md#what-the-facility-administrator-does).

## Cloudflare Tunnel ingress

Cloudflare Tunnel is the only supported ingress. The `cloudflared` connector on
the host is the sole path from the internet to the gateway on
`127.0.0.1:18000`; Cloudflare terminates TLS for the canonical origin given as
`--api-url`, so no certificate is installed locally. Kong trusts
`CF-Connecting-IP` only from that loopback hop and keys its per-client rate
limits on it. Do not place another reverse proxy (Caddy, nginx, Traefik) in
front of the gateway: it would not set the header, clients could supply their
own address and every phone would share one rate-limit budget.

Reference files with placeholders:
[deploy/cloudflared-config.example.yml](../deploy/cloudflared-config.example.yml)
and [deploy/warehouse-tunnel.service.example](../deploy/warehouse-tunnel.service.example).

Install `cloudflared` from [Cloudflare's package repository](https://developers.cloudflare.com/tunnel/features/locally-managed-tunnels/create-local-tunnel/#1-download-and-install-cloudflared):

```bash
sudo install -m 0755 -d /usr/share/keyrings
curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg | sudo tee /usr/share/keyrings/cloudflare-main.gpg >/dev/null
printf 'deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared any main\n' | sudo tee /etc/apt/sources.list.d/cloudflared.list
sudo apt-get update && sudo apt-get install -y cloudflared
cloudflared --version
```

Decide the hostname and the tunnel before routing anything:

1. Use the complete API hostname (for example `warehouse-api.example.com`),
   the same value as `--api-url`. Check its DNS and confirm nothing else
   serves it.
2. Use a tunnel dedicated to this host.
   [Cloudflare sends requests to any replica of a shared tunnel](https://developers.cloudflare.com/tunnel/configuration/#replicas-and-high-availability),
   so an occupied tunnel does not isolate this installation.
3. Choose [dashboard-managed](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/get-started/create-remote-tunnel/)
   (create the tunnel and a public hostname route to `http://127.0.0.1:18000`
   in the dashboard, store the connector token in a mode-0600 file, run
   `cloudflared tunnel run --token-file <path>`) or
   [locally managed](https://developers.cloudflare.com/tunnel/features/locally-managed-tunnels/create-local-tunnel/)
   (`cloudflared tunnel login` writes `cert.pem`; create a new named tunnel
   with its own JSON credentials; route only the confirmed hostname).

For a locally managed tunnel, after moving `cert.pem` into a mode-0700 private
directory:

```bash
cloudflared tunnel --origincert /private/path/cert.pem list --output json > /private/path/tunnels-before.json   # confirm the new name is unused
cloudflared tunnel --origincert /private/path/cert.pem create --credentials-file /private/path/new-tunnel.json NEW_TUNNEL_NAME
cloudflared tunnel --origincert /private/path/cert.pem route dns NEW_TUNNEL_UUID warehouse-api.example.com
```

Run `route dns` without `--overwrite-dns`; if it reports a conflict, inspect
that record instead of overwriting it. Never reuse, delete or clean up a tunnel
or connector that belongs to another machine. Keep every token, JSON
credential and account certificate mode 0600 in that private directory and out
of logs and unit files.

Copy the example config to a private path (mode 0600) and replace the tunnel
UUID, credentials path and hostname. It routes the hostname to
`http://127.0.0.1:18000` with `httpHostHeader` set to the hostname and ends
with an `http_status:404` catch-all; change the port only if the private
`compose.env` sets a different `KONG_HTTP_PORT` (chosen with
`--gateway-port`, see [several facilities on one host](#several-facilities-on-one-host)). `http2-origin` stays off
because [HTTP/2 to an origin requires HTTPS](https://developers.cloudflare.com/tunnel/reference/origin-parameters/)
and this origin is private HTTP. Validate with
`cloudflared --config /private/path/config.yml tunnel ingress validate` and
confirm the hostname's DNS record points to `<tunnel-uuid>.cfargotunnel.com`.
For a dashboard-managed tunnel the hostname and origin live in the dashboard
and the YAML is not used.

**Keep the tunnel credential in the state, so backups carry it.** Copy it into
the installation's state directory (`config/tunnel/`, mode 0700/0600) and make
the connector a system service that reads that copy and survives reboots:

```bash
export WAREHOUSE_STATE_DIR=/srv/warehouse/acme
bash scripts/tunnel.sh adopt --config /private/path/config.yml     # locally managed
# or: bash scripts/tunnel.sh adopt --token-file /private/path/tunnel.token   (dashboard)
sudo bash scripts/tunnel.sh install-service --state "$WAREHOUSE_STATE_DIR"
bash scripts/tunnel.sh status
```

`adopt` copies the config with its credentials JSON (rewriting the
`credentials-file:` path) or the token. It refuses the account certificate
(`cert.pem`, or a config with an `origincert:` line), which can create and
delete any tunnel or DNS record of the account and must never be in a backup,
and it refuses a config that does not route this installation's hostname.
`install-service` writes `/etc/systemd/system/warehouse-<state name>-tunnel.service`
(keeping a dated copy of an existing unit of that name), runs it as the user who
ran `sudo`, then enables and restarts it. From then on every backup, and every
USB copy, includes the credential, and
[restoring onto a new host](#recover-a-lost-host-from-the-usb-drive) brings the
public address back without a Cloudflare login. Keep `cert.pem` in your private
directory only. Once the service runs from the state copy you may delete the
old private copies of the config and credentials JSON.

An installation from before `tunnel.sh` runs the same two commands once; the
connector restarts, so the public address is unavailable for a few seconds. To
keep the credential out of backups instead, skip `adopt` and install the unit
by hand from [deploy/warehouse-tunnel.service.example](../deploy/warehouse-tunnel.service.example)
(`sudo systemctl daemon-reload && sudo systemctl enable --now <unit>`); a
restore on a new host then needs your private copy or a new tunnel.

If the LAN router cannot hairpin to the public hostname, configure local DNS
for the same name; the app must always use the same HTTPS origin.

## External doctor

```bash
export WAREHOUSE_STATE_DIR=/srv/warehouse/acme
node scripts/doctor.mjs
```

The external doctor repeats the local health check, then fetches the public
configuration through the canonical origin (no redirects allowed) and verifies
that the anon key, instance ID and canonical origin it returns are this
installation's. Repeat it from warehouse Wi-Fi and from cellular data.
`doctor --local` covers the loopback gateway only; `--host-preflight` and
`--preflight` are the checks setup runs before touching anything.

If the external doctor reports `fetch failed` right after you routed the
hostname, check name resolution before suspecting the tunnel. A lookup made
*before* the route existed (for example the `dig` that confirms the name is
free) leaves an NXDOMAIN in the host's resolver cache for the zone's negative
TTL, up to 30 minutes on a Cloudflare zone, while the public internet already
resolves the name. Compare `dig +short <hostname> @1.1.1.1` with
`dig +short <hostname>`; `resolvectl flush-caches` helps on systemd-resolved
hosts, but an upstream router may cache the answer too. Once the name resolves
on the host the doctor passes.

## First-use checks

Install the companion app
([rn-warehouse-template](https://github.com/abhiguru/rn-warehouse-template)),
select this origin and confirm the company name it discovers. Then, with
fictional data and owned phones:

1. Sign in as the administrator with a real SMS code.
2. Create two fictional customers (Settings → Customers) and an item with a
   price (Settings → Items, Item Pricing). Sign up a customer login from a
   second phone; its login stays pending until you approve it from Enrollment
   Review, and the assignment list there is empty until customers exist.
   Approve it with an assignment to the first customer, sign in, and confirm
   it sees only that customer's records.
3. Create a staff account. There is no create-user screen: the person signs
   in once, you approve them, then set the role under Settings → Users → edit.
   As staff, create a goods receipt for the customer who is **not** assigned
   to that person (the app requires a photo of the GRN book entry), a partial
   and a final dispatch (a photo is optional and can only be attached while
   the dispatch is being created, not afterwards), and save the invoice:
   totals are computed by the server and staff see no price list.
4. Download the GRN, dispatch, invoice and stock PDFs as an authorized user;
   confirm an anonymous or foreign request is denied.
5. Disable a user (Settings → Users → edit → Account Status) and confirm login
   is refused (the code can still be requested, verification is rejected),
   then re-enable and sign in again.
6. Take a backup and verify it (below).

One phone is enough to exercise every role if you sign out and in again for
each, but each role needs its own number that can receive an SMS. To reuse a
number for the staff role, change that login's role only after the customer
checks are finished.

[INVOICE_RULES.md](INVOICE_RULES.md) and [STAFF_GRN_POLICY.md](STAFF_GRN_POLICY.md)
describe the expected behaviour. The fictional billing example there (subtotal
950, tax 48, total 998) holds only for its fixture dates: received on 1 April,
dispatched on 2 May, 31 billable days, so 1.5 periods. If you receive and
dispatch on the same day one period applies, and 100 bags at price 5, labour 2
and tax 5 % give 700 + 35 = **735**. Record what you tested.

## Ordinary operation

Use the installed checkout, the recorded state directory and a shell with
Node 22 and effective Docker access. The Compose wrapper refuses a running
project owned by another checkout.

```bash
cd /path/to/installed/backend
export PATH="$HOME/.local/opt/node-v22.23.3-linux-x64/bin:$PATH"
export WAREHOUSE_STATE_DIR=/absolute/path/to/this/warehouse
bash start.sh
node scripts/doctor.mjs --local
node scripts/doctor.mjs
bash scripts/compose.sh ps
# Stop this instance while preserving its data:
bash stop.sh
```

`compose ps` shows every service `Up (healthy)` except `rest`, which defines no
healthcheck and appears as plain `Up`; the doctor, not the status column, is
the health verdict.

Start and stop the tunnel service separately through its systemd unit. Do not
run `down -v`, a broad Docker prune, or delete state as a restart procedure.

Every operator command (`setup.sh`, `start.sh`, `stop.sh`, `rotate-keys.sh`,
`db:backup`, `db:restore`, `backup-disk.sh sync`, `backup-usb.sh run`,
`test:recovery`, `retention:*`, `test:gateway-dns`, `test:pooler`,
`test:monitoring`, `test:cups`, `test:sensors`, and `scripts/migrate.sh` when run by itself)
takes an exclusive per-state lock on `config/operator.lock` before touching
Docker. A second command for the same state fails immediately with "Another
operator command ... is running for this state." Wait for the first to finish;
never delete the lock file to force a run. The automatic USB backup is the one
exception that waits: it retries for up to 15 minutes, then records a failure.

## Retention

Nothing is deleted on a timer. Run the retention command yourself, or from the
same scheduler as your backups:

```bash
cd /path/to/installed/backend
export WAREHOUSE_STATE_DIR=/absolute/path/to/this/warehouse
npm run retention:preview   # counts only
npm run retention:apply
```

It removes expired sign-in records and old security logs from the database
(`warehouse_maintenance.retention_policy`), and generated PDF files older than
7 days from the private `documents` bucket (the PDFs are removed through the
Storage API, so the storage container must be running; see
[PDF_GENERATION.md](PDF_GENERATION.md)). Business records and photos are never
removed by it.

## Rotate signing keys

Rotate when the JWT secret, anon key or service key may have been exposed, when
a device or backup holding them leaves your control, or on a planned schedule.
Rotation is one explicit command for the installed checkout and state:

```bash
cd /path/to/installed/backend
export WAREHOUSE_STATE_DIR=/absolute/path/to/this/warehouse
bash rotate-keys.sh --yes
```

Without `--yes` the command prints a usage message, changes nothing and exits
with status 1. With `--yes` it takes the operator lock, requires a healthy
database, and then:

1. stages a copy of `config/compose.env` with a new 96-hex `JWT_SECRET` and
   newly signed `ANON_KEY` and `SERVICE_ROLE_KEY` (only those three lines change);
2. in one database transaction under advisory lock 71042: stores the new secret
   in `warehouse_security.auth_config`, deletes every refresh session, voids
   pending OTP challenges, and removes the self-hosted Realtime tenant row so the
   recreated service re-seeds it with the new secret. The secret is not stored as
   a database setting (migration 92 removed `app.settings.jwt_secret`, which
   every database role could read). It reaches `psql` only on standard input,
   never as an argument;
3. renames the staged file over `config/compose.env` (mode 0600);
4. recreates the running key consumers (`db kong rest realtime storage functions
   studio`, plus `supavisor` when the pooler profile is running) with
   `--force-recreate --wait`, and runs `node scripts/doctor.mjs --local`.

Consequences: every signed-in device is logged out and must complete OTP login
again; any copied anon key is invalid and `get-public-config` advertises the
new one; the service key changes. A failure before step 3 leaves the file and
database untouched. If the process is interrupted between steps 2 and 3, the
database already holds a secret the file does not; rerun
`bash rotate-keys.sh --yes`, which stages and applies a newer secret end to
end. Take a fresh `db:backup` after rotation: earlier backups restore the
previous keys together with the previous database state and remain internally
consistent, but they no longer match the running instance.

Two things to expect afterwards. `doctor --local` passes at the end of the
command, but an external `doctor` run immediately afterwards can fail once with
a local-service message while the recreated services settle behind the tunnel;
rerun it after about thirty seconds. And already-open apps are not sent to the
login screen: their next requests are rejected with HTTP 401, and the current
client shows load errors or empty lists instead of prompting. Ask every user to
sign out (Settings → Sign Out) and sign in again after a rotation.

## Backup and restore

`npm run db:backup -- /absolute/destination` writes a private, signed
`warehouse-backup-v5` directory (default `$WAREHOUSE_STATE_DIR/backups/warehouse-<utc>`).
It stops ingress and every write-facing service for the capture and restarts
only the services that were running. The directory contains:

| File | Content |
| --- | --- |
| `database.dump` | `pg_dump --format=custom` of the `postgres` database **with owners** (needed by the in-place restore). |
| `_supabase.dump` | `pg_dump --format=custom` of the `_supabase` database (pooler and analytics schemas). |
| `storage.tar.gz` | The object storage directory, sorted, with fixed owner and mtime. File contents and the catalog are captured; filesystem extended attributes are not, so restored objects are served with the metadata recorded in the catalog. |
| `storage_objects.txt` | The `storage.objects` catalog as `<bucket>/<name>/<version>`, byte-ordered. |
| `integrity.txt` | Output of `scripts/backup-integrity.sql`: migration fingerprint, row counts, representative grants. From migration 48 on it also counts the three history tables (invoice discounts, zero charges, item prices) and records that the internal `invoice` columns are closed to the app role; from migration 95 on it also counts payments, order lines and order revisions. A backup taken earlier has no such lines and is still compared line for line. |
| `roles.txt` | Cluster role names, so runtime-created roles can be recreated before ownership replays. |
| `compose.env`, `instance.json` | Private configuration and public manifest at backup time. |
| `central-jwks.json` | Only when the installation reads the central sign-in keys from a file (`--central-jwks-file`): a copy of `public/central-jwks.json`, public keys only. `db:restore-host` puts it back. |
| `metadata.txt`, `SHA256SUMS` | Format, timestamp, source commit and checksums of every file above. |
| `SHA256SUMS.hmac` | The signature: HMAC-SHA256 of `SHA256SUMS` under the [backup key](#backup-key). |

The backup directory is **unencrypted** and contains every credential of the instance.
Keep it mode 0700/0600 on protected storage. `db:backup` warns when the
destination shares a filesystem with `data/`: a backup on the same disk does not
survive loss of that disk. Copy every retained backup to an operator-provided
encrypted off-host destination; the acceptance ledger keeps encrypted off-host
custody, schedule and retention open. The `db-config` Docker volume (PostgreSQL
custom configuration and the pgsodium root key) is not part of the backup and
is preserved by `stop.sh`; never use `down -v` on a production instance.
Optional CUPS, monitoring and sensor bridge volumes are not in this core
backup (the bridge's volume holds only readings not yet delivered).

`npm run db:verify-restore -- /path/to/backup` accepts v1 to v5 backups. It
checks every checksum and the signature first (see [Backup key](#backup-key)),
rejects absolute paths, `..` segments and links in the
storage archive, proves that every catalogued object is a file in the archive
(extra files are reported as a warning), restores both dumps into a disposable
`--network none` container with `--exit-on-error`, replays the archived
ACLs, and compares the integrity report and the restored object catalog with
the backup. Run it against every retained backup; it never touches the installed
instance. Backups written before v5 carry no signature: the verifier, `db:restore`
and `db:restore-host` refuse them unless you add `--allow-unsigned`, which prints
a warning and proves nothing about where the backup came from.
`--allow-unsigned` is only for a backup written before format v5, or when the
backup key is lost (see [Backup key](#backup-key)). A v5 backup is always signed:
if its `SHA256SUMS.hmac` file is missing and the key is available, all three
commands refuse it even with `--allow-unsigned`, because the signature was taken
away. Use another copy of the backup. (The format is read from `metadata.txt`,
which is not signed in an unsigned copy; someone who can edit the backup can
relabel it v4 and use the flag. That residual is accepted: the flag and its
warning stay required, and the medium must never have left your custody.)

The disposable database is sized from the backup: the two dumps times 10, the
same again (up to 1 GiB) for the write-ahead log, plus 256 MiB, and never less
than 768 MiB. It lives in memory when that much memory is available, otherwise
in a temporary directory under `$WAREHOUSE_STATE_DIR` that is removed
afterwards; the command prints the size and the place it chose, checks free
space first, and when it does not fit it stops with the numbers instead of a
restore error. Override when needed:

| Variable | Meaning |
| --- | --- |
| `WAREHOUSE_VERIFY_DATA_MB` | Size of the disposable data directory in MiB. |
| `WAREHOUSE_VERIFY_SIZE_FACTOR` | Multiplier applied to the dump size (default 10). |
| `WAREHOUSE_VERIFY_STORAGE` | `auto` (default), `tmpfs` or `disk`. |
| `WAREHOUSE_VERIFY_SCRATCH_DIR` | Parent of the disk-backed directory (default `$WAREHOUSE_STATE_DIR`). |
| `WAREHOUSE_VERIFY_MEMORY_MB` | Memory limit of the container. |

A failed verification leaves the container log, its state and the database
sessions in `$WAREHOUSE_STATE_DIR/diagnostics/verify-restore-<utc>-<id>/`
(`WAREHOUSE_DIAGNOSTICS_DIR` overrides the place) before the container is
removed. The log can contain rows of the backup; keep the directory private and
delete it when the problem is understood.

### Backup key

`config/backup.key` in the state directory (mode 0600) is a random 256-bit key.
`setup.sh` creates it; on an installation made before signed backups, the next
`setup.sh` run or the next `db:backup` creates it and says so. It is used for
three things:

- every backup is **signed** with it (`SHA256SUMS.hmac`). `db:verify-restore`,
  `db:restore` and `db:restore-host` check the signature before they read
  anything else from the backup. Plain checksums only detect damage; anyone who
  can write to a backup drive can regenerate them, and a restore replays the
  dump as the database superuser and adopts the backup's `compose.env`. The
  signature is what tells your backup from an edited one;
  for an archive, `db:restore-host` also requires its `.sha256` to hold exactly one
  record, naming that archive, with the SHA-256 of its bytes, so a checksum and
  signature copied from another archive are refused before anything is opened;
- a USB drive is **enrolled** with it (see [USB backup drive](#usb-backup-drive));
- USB archives are **encrypted** with it when you switch encryption on.

The key is never written into a backup and must never be stored on the backup
drive. **Keep a copy away from the server and away from the drive**: a
password manager, or a file on a different device kept somewhere else.

```bash
cat "$WAREHOUSE_STATE_DIR/config/backup.key"     # 64 hexadecimal characters; copy them exactly
```

What the copy is for: after the host is lost, `db:restore-host` refuses a backup
unless you give it the key (`--backup-key FILE`), and an encrypted archive
cannot be opened at all without it. Without the key (lost), a signed backup can
only be restored with `--allow-unsigned`, on your own judgement that the drive
never left your hands; an encrypted archive is lost. This is the one case where
the flag accepts a v5 backup; it does not accept a v5 backup whose signature
file is missing while a key is given or installed. Check your copy once: put it in
a file and run
`WAREHOUSE_BACKUP_KEY_FILE=/path/to/copy npm run db:verify-restore -- /path/to/backup`.

The restored installation keeps the same key. If the key itself may have been
disclosed: move `config/backup.key` aside
(keep it with the old backups, which only verify with it), take a new
`db:backup` (it creates a new key), store the new copy, and enroll each USB
drive again. On each drive, also move the archives written before the change
(`warehouse-<utc>.tar*` with their `.sha256` and `.hmac` files) into another
folder, for example `warehouse-backups/<state name>/old-key-<date>/`: they
carry signatures of the old key, and as long as an older backup is still under
`backups/` the USB run would report its archive as "not signed with the current
backup key" on every attach. Do the same after a `db:restore-host
--allow-unsigned` that was run without the key (its first backup creates a new
one).

### USB backup drive

A backup on the same disk as `data/` is lost with it, which is why `db:backup`
warns. Pilot installs copy every backup to a **USB drive formatted exFAT**,
which the operator attaches; exFAT is readable by a Linux host and by the Linux
VM of a [Windows host](#windows-host-with-linux-vm), so a restore works on
either. The drive is never partitioned or formatted, and other files on it are
left alone; backups go under `warehouse-backups/<state name>/` as one `.tar`
archive (file modes kept inside) per backup, with a `.tar.sha256` checksum and
a `.tar.hmac` signature made with the [backup key](#backup-key). With
encryption switched on the archive is `.tar.enc` instead (see below).

The operator's only job is to **attach the drive**; the host does the rest.
`scripts/backup-usb.sh` installs a udev rule and a systemd unit once; after
that, attaching an **enrolled** drive takes a fresh `db:backup` (write-facing
services stop briefly), writes each backup not yet on the drive, reads every new
archive back from the drive and compares checksums, runs `db:verify-restore` on
the newest archive extracted from the drive, and unmounts the drive. Only an
**enrolled** drive receives anything. Enrolling writes a small marker file,
`warehouse-backups/.drive-enrolment`, onto the drive: a signature made with the
backup key over the drive's filesystem UUID, its partition UUID and this
installation's identity. Before a run takes a backup or copies a byte it
recomputes that signature for the drive in front of it. The exFAT volume serial
alone no longer enrols a drive (it is 32 bits and can be chosen when
formatting), so a stick that imitates the serial of your drive receives nothing.

1. Set it up once, as the installation user with `sudo`, with the drive attached
   (on VMware connect it to the VM under Removable Devices first). Find the
   partition with `lsblk -o NAME,TRAN,FSTYPE,LABEL,MOUNTPOINTS`; it must show
   `usb` and `exfat`:

   ```bash
   cd /path/to/installed/backend
   sudo bash scripts/backup-usb.sh setup --state /absolute/path/to/this/warehouse --enroll /dev/sdb1
   ```

   Run it in an interactive terminal on the host: `sudo` asks for your
   password, and a shell without a terminal (a script, a scheduler or an
   automation agent) cannot answer it. It refuses to run without `sudo` from
   the installation user, and the copy itself always runs as that user, never
   as root. **Setup does not copy anything to a drive that is already
   attached**: unplug the drive and attach it again to make the first copy.
   The unit runs `scripts/backup-usb.sh` from this checkout, so do not move or
   delete the checkout, or switch it to a branch or release without that
   script, while USB backup is set up. It copies its root helper to
   `/usr/local/libexec/warehouse-usb-backup`, writes
   `/etc/warehouse-usb-backup.conf`, the enrolled-drive list
   `/etc/warehouse-usb-backup.drives` (root only, mode 0600),
   `/etc/udev/rules.d/90-warehouse-usb-backup.rules` and the
   `warehouse-usb-backup@.service` unit. Add `--daily` for a drive that stays
   attached (a daily timer starts the same run), `--no-fresh-backup` to copy
   only existing backups, and `--encrypt` to encrypt the archives (below).
   A later setup run that does not name one of these keeps what you chose;
   switch one back with `--no-daily`, `--fresh-backup` or `--no-encrypt`.
   Enroll a second drive for rotation with
   `sudo bash scripts/backup-usb.sh enroll --device /dev/sdX1`; enrolling needs
   the backup key, so take one `npm run db:backup` first on an installation
   that has none yet. **Run setup again
   after updating the checkout** (see [Rerun and upgrade](#rerun-and-upgrade);
   `setup.sh` runs first) so the installed helper matches it (`status` warns
   when it does not); `sudo bash scripts/backup-usb.sh uninstall` removes
   everything it installed and never touches a drive.
2. From then on: plug the drive in and wait. The run takes a few minutes; when
   the drive disappears from the file manager (or `lsblk` shows no mount point
   for it), it is unmounted and safe to remove. Do not unplug during a copy; an
   interrupted archive is left as a `.partial` file that the next run removes.
3. Check the result as the installation user:

   ```bash
   bash scripts/backup-usb.sh status            # last result, enrolled drives, last success age
   journalctl -u 'warehouse-usb-backup@*' -n 50  # the run's own output
   ```

   Until the first run after setup, `journalctl` answers "Failed to add filter
   for units: No data available"; that only means no run has happened yet.
   The result is also written to `warehouse-backups/<state name>/LAST-RESULT.txt`
   on the drive, and `npm run doctor` adds a warning when the last run failed or
   the last successful copy is older than 7 days
   (`WAREHOUSE_USB_BACKUP_MAX_AGE_DAYS`).

Nothing is ever deleted from the drive or from `backups/`; remove old archives
yourself. A run that finds an archive that no longer matches its checksum
reports it and leaves it alone.

**Encryption is off unless you switch it on.** By default the archives are
**not encrypted** and contain `compose.env`, which holds every
credential of the instance, the whole customer database, and, after
`tunnel.sh adopt`, the tunnel
credential: whoever holds the drive could run a connector for your hostname and
receive part of the phones' traffic, sign-in codes included. Keep the drive
locked away.

To encrypt, first store a copy of the [backup key](#backup-key) away from the
server and the drive, then run setup again with `--encrypt`:

```bash
sudo bash scripts/backup-usb.sh setup --state "$WAREHOUSE_STATE_DIR" --encrypt
```

From the next run on, each new archive is written as `warehouse-<utc>.tar.enc`
(AES-256, key derived from the backup key, with a signed checksum next to it)
and the run verifies the restore from the encrypted copy. A lost drive then
gives away nothing without the key, and a lost key makes the encrypted archives
unrecoverable, which is why encryption is not the default. It is covered by
automated tests that really encrypt and decrypt an archive, with the database
replay simulated; it has not yet been through a lost-host drill on real
containers. Until you have done one lost-host restore from an encrypted archive
yourself, keep at least one other copy you know you can restore. Archives already on the drive stay as they are; the run
names them in a warning until you delete them. Run setup without `--encrypt` to
switch it off again.

If an unencrypted drive is ever lost, act at once: run `./rotate-keys.sh --yes`,
rotate the MSG91 key, and replace the tunnel credential (for a dashboard
tunnel, refresh its token in the Cloudflare dashboard; for a locally managed
tunnel, create a new tunnel, route the hostname to it with `route dns
--overwrite-dns` and delete the old one), then
`mv "$WAREHOUSE_STATE_DIR/config/tunnel" <private place>`, `tunnel.sh adopt`
the new credential, `sudo bash scripts/tunnel.sh install-service`, replace the
passwords listed under
[Secrets that rotate-keys does not change](#secrets-that-rotate-keys-does-not-change),
and take a new backup. A drive kept on site is
local custody only; taking it (or a second drive in rotation) to another
location is what protects against loss of the host, theft or fire.

To use an archive from the drive: on the **same** installation (its state
directory intact) extract it into `$WAREHOUSE_STATE_DIR/backups/` and follow
[In-place restore of the same instance](#in-place-restore-of-the-same-instance);
after losing the host, follow
[Recover a lost host from the USB drive](#recover-a-lost-host-from-the-usb-drive).

**Record a fingerprint with each backup you may need to prove later.** Right
after a USB run, before anyone uses the app again:

```bash
bash scripts/data-fingerprint.sh > ~/fingerprint-<backup name>.txt
```

It prints a row count and a SHA-256 for every business table (customers, items,
prices, GRNs, dispatches, invoices, stock movements, users, orders with their
lines and revisions, and payments), for the three
append-only histories (invoice discounts, zero charges, item prices), the
storage catalog and the stored files. A fingerprint taken before the upgrade to
migration 48 has no lines for the histories and cannot be compared with one
taken after it, and a fingerprint recorded before the release that added orders,
order lines, order revisions and payments lacks those four tables' lines, so a
restore will not print `IDENTICAL` against it; take a new one after upgrading.
It holds no secrets; keep a copy off the host (for
example next to the archive on the drive). After a restore the same command
must print identical lines.

### Backup disk

Alternative to the USB drive for hosts with a spare internal disk; new installs
should use the [USB backup drive](#usb-backup-drive).
The protection here is a **second, empty disk** used only for backups.
`scripts/backup-disk.sh` prepares that disk and copies verified backups onto it;
`db:backup` itself is unchanged. A partition carved out of the system disk is
deliberately not offered, because it would not survive failure of that disk,
and the helper never shrinks, resizes or wipes anything.

A second disk is **local custody only**. A separate physical drive (or, on a
hypervisor, a disk on a different datastore) protects against failure of the
data disk. It does not protect against loss of the host or datastore, theft,
fire, or ransomware that reaches the guest; only an encrypted off-host copy
does, and the acceptance ledger keeps that open.

1. Attach an empty disk (VMware: VM settings, add a hard disk, preferably on a
   different datastore or drive; cloud: create and attach a volume; hardware:
   install a drive), then rescan or reboot. It must be blank: no partitions, no
   filesystem or other signature, not mounted.
2. Look first. These commands are read-only and run as the installation user:

   ```bash
   cd /path/to/installed/backend
   export WAREHOUSE_STATE_DIR=/absolute/path/to/this/warehouse
   bash scripts/backup-disk.sh status
   bash scripts/backup-disk.sh plan                      # lists eligible disks
   bash scripts/backup-disk.sh plan --device /dev/sdb    # shows exactly what apply would do
   ```

   `plan` prints the apply command with the confirmation value taken from the
   disk itself (its serial number, or its exact size when it reports none).
   With no eligible second disk it stops with "No second disk found".
3. Prepare the disk. This is the only destructive command and the only one that
   needs root. It never escalates by itself; run it through `sudo` from the
   installation user so the disk is owned by that user and not by root:

   ```bash
   sudo bash scripts/backup-disk.sh apply --device /dev/sdb --yes --confirm-serial SERIAL
   ```

   It refuses the system disk and any disk that holds the operator data; any
   disk with a partition, filesystem, LVM, RAID, swap or encryption signature,
   or even an empty partition table; mounted, removable or read-only disks; and
   disks smaller than 10 GiB or twice the current data and backups. It creates
   one GPT partition with an ext4 filesystem labelled `warehouse-backup`,
   mounts it at `/srv/warehouse-backups` (owned by you, mode 0700), writes
   `.warehouse-backup-disk` there and appends one `UUID=… nofail` line to
   `/etc/fstab`, keeping a dated copy of the file. It re-checks the disk
   immediately before writing. Running it again on the prepared disk changes
   nothing. If it stops part way it says where and wipes nothing automatically;
   run `status` and clean up by hand only if you are sure.
4. Copy and verify, as the installation user, after every backup (including
   the one you take after a key rotation, which is the one that matches the
   running keys):

   ```bash
   npm run db:backup
   bash scripts/backup-disk.sh sync
   ```

   `sync` takes the operator lock and refuses unless `/srv/warehouse-backups`
   is a real mount of a different device than `data/` (an unmounted directory
   would quietly fill the system disk instead). It copies each backup to
   `/srv/warehouse-backups/<state name>/`, checks `SHA256SUMS` on the copy and
   runs `db:verify-restore` against it (`--skip-verify-restore` omits that
   step). It never overwrites or deletes anything: a corrupt existing copy is
   reported and left alone, and retention is manual. An unsigned backup from
   before format v5 is copied and checksum-verified, and the command says that
   its restore verification was skipped.

The copies are signed but **not encrypted** (the key would sit on the system
disk of the same machine) and contain `compose.env`, which holds every
credential of the instance, so the disk itself must be physically controlled. `nofail` lets the host boot if
the disk is missing; `status` then reports it as not mounted and `sync` refuses
to write into the empty mount point.

### In-place restore of the same instance

`npm run db:restore -- --yes /path/to/backup` replaces the installed database
and stored objects with a signed v5 backup **of the same instance** (an
unsigned v4 backup only with `--allow-unsigned`). For a replacement host see
[Recover a lost host from the USB drive](#recover-a-lost-host-from-the-usb-drive).

```bash
cd /path/to/installed/backend
export WAREHOUSE_STATE_DIR=/absolute/path/to/this/warehouse
npm run db:verify-restore -- /path/to/backup
bash stop.sh
npm run db:restore -- --yes /path/to/backup   # add --restore-config if keys were rotated after the backup
bash start.sh
node scripts/doctor.mjs --local
bash setup.sh --operator ...   # only if you use central sign-in: makes the restored database agree with compose.env
```

A restore returns the instance to the moment of the backup: everything recorded
after it is gone. To rehearse a restore without losing current data, take a
fresh `db:backup` immediately beforehand and restore that one.

The restore refuses, without touching anything, unless all of the following hold:
`--yes` is given; no other operator command holds the state lock; `compose ps -q`
is empty (run `stop.sh` first); the backup's checksums and its signature under
this installation's `config/backup.key` are valid; the backup is
`warehouse-backup-v5` (or v4 with `--allow-unsigned`); the backup's
`instance.json` equals `public/instance.json`; the backup's `compose.env` equals
`config/compose.env`, or `--restore-config` is given and the backup names the
same project and state paths; and `db:verify-restore` passes for the backup.

It then moves `data/db` and `data/storage` to `data/db.pre-restore-<utc>` and
`data/storage.pre-restore-<utc>`, recreates both with mode 0700, extracts the
storage archive, optionally replaces `config/compose.env` (keeping
`config/compose.env.pre-restore-<utc>`), initializes a fresh cluster with
`compose up -d --wait db`, recreates missing roles from `roles.txt` as `NOLOGIN`,
recreates the `postgres` database from `template0` (the same template the
verifier restores into; `template1` is not used because a session attached to
it right after start-up makes `CREATE DATABASE` fail), replays `database.dump` by section with
`--exit-on-error` and the archived owners (event triggers are replayed last,
owned by the restoring superuser, because PostgreSQL requires a superuser owner
and the archived owner is not one in this image), repairs the pg_graphql
wrapper and replays ACLs exactly as the verifier does, recreates `_supabase`
the same way and restores `_supabase.dump`, re-asserts the database JWT
settings from `compose.env`, diffs `scripts/backup-integrity.sql` against the
backup's `integrity.txt`, runs `scripts/migrate.sh --operator` (a no-op unless
this checkout added migrations after the backup), runs
`scripts/configure-list-refresh.sql` (the list refresher's role came back
without `LOGIN`; see [Lists refresh after the commit](#lists-refresh-after-the-commit)), starts every service with
`--wait` and runs `doctor --local`. Role passwords always come from the active
`compose.env`; the backup never contains them. Pass `--restore-config` only when
the keys in the backup are the ones the restored data was signed with, that is,
when `rotate-keys.sh` ran after the backup and the restored sessions must match
the old keys.

**Rollback.** The pre-restore directories are kept until the operator removes
them. If the restore fails or the restored instance is rejected:

```bash
bash stop.sh
rm -rf "$WAREHOUSE_STATE_DIR/data/db" "$WAREHOUSE_STATE_DIR/data/storage"   # sudo may be required: PostgreSQL files belong to the container's postgres user
mv "$WAREHOUSE_STATE_DIR/data/db.pre-restore-<utc>" "$WAREHOUSE_STATE_DIR/data/db"
mv "$WAREHOUSE_STATE_DIR/data/storage.pre-restore-<utc>" "$WAREHOUSE_STATE_DIR/data/storage"
mv "$WAREHOUSE_STATE_DIR/config/compose.env.pre-restore-<utc>" "$WAREHOUSE_STATE_DIR/config/compose.env"   # only after --restore-config
bash start.sh
```

A failed restore prints this sequence with the actual paths. Remove the kept
directories only after the restored instance is accepted. They contain files
owned by the containers' users (PostgreSQL's data, and objects written by the
storage container), so removing them needs root; use the two exact paths the
restore printed, never a wildcard:

```bash
sudo rm -rf "$WAREHOUSE_STATE_DIR/data/db.pre-restore-<utc>" "$WAREHOUSE_STATE_DIR/data/storage.pre-restore-<utc>"
ls "$WAREHOUSE_STATE_DIR/data"   # only db and storage remain
```

### Recover a lost host from the USB drive

Use this when the original host is gone (disk failure, reinstall, stolen or
destroyed machine) and the USB drive is the only thing left. The rebuilt host
becomes **the same warehouse**: same instance identity, HTTPS origin, signing
keys, MSG91 settings, users, sessions and data, exactly as at the moment of the
backup. Phones keep working without selecting the server again. Everything
recorded after the backup is lost.

> **Status:** `db:restore-host` is exercised in CI by a lost-host drill on real
> containers (fresh backup, containers and database volume removed, restore into a
> different path, identical fingerprint). Record the result of your first drill
> on a real new host. The tunnel credential comes back too when the backup was
> taken after `tunnel.sh adopt` (step 6).

**Never run the old and the new host at the same time.** They would answer as
the same warehouse with the same keys. If the old host might come back, wipe
its disk or keep it disconnected; if in doubt, rotate the keys afterwards
(step 9).

Before you start you need: the new host prepared as in
[host prerequisites](#host-prerequisites) (Node 22, Docker with a Compose plugin that accepts `up --wait-timeout`,
`cloudflared`, your user in the `docker` group), the USB drive, and **your
copy of the [backup key](#backup-key)** in a file on the new host (for example
`~/backup.key`, mode 0600; one line of 64 hexadecimal characters). Backups taken
after `tunnel.sh adopt` carry the tunnel credential; for older backups you also
need your private copy of it (the tunnel `config.yml` plus its credentials
JSON, or the dashboard token file). If this facility's central sign-in reads its
keys from a file, backups taken with this release carry that file too
(`central-jwks.json`); for older backups keep the key set the association sent
you (step 7). **Do not run `setup.sh` before the restore**: on the new host it
would create a new, different warehouse. After `db:restore-host` has finished,
`setup.sh` on the restored state keeps the identity. Step 7 needs it, and so
does step 8 when the installation sent alerts to Slack; when both apply,
one rerun with both sets of options does.

1. **Get the code.** Clone the repository with `umask 022` as in the Ubuntu
   sequence. Any release at least as new as the backup works (the backup's
   `metadata.txt` records `source_commit`); newer migrations are applied during
   the restore.
2. **Attach the drive and choose the backup.** On VMware connect it under
   Removable Devices. The desktop usually mounts it under `/media/$USER/`;
   otherwise `udisksctl mount -b /dev/sdX1` (find it with
   `lsblk -o NAME,TRAN,FSTYPE,LABEL,MOUNTPOINTS`: `usb`, `exfat`).

   ```bash
   DRIVE="/media/$USER/<label>"
   ls "$DRIVE"/warehouse-backups/*/                       # one folder per installation
   cd "$DRIVE/warehouse-backups/<state name>"
   sha256sum -c warehouse-<utc>.tar.sha256                # the newest that says OK (.tar.enc.sha256 for an encrypted archive)
   ```

3. **Restore.** Choose the state directory for this host. The original path is
   a good choice (the drive's folder name is its last part), but any new path
   works. Its parent must belong to you, and the state itself must
   not exist yet or be empty:

   ```bash
   export WAREHOUSE_STATE_DIR=/srv/warehouse/acme
   sudo install -d -m 0755 -o "$(id -un)" -g "$(id -gn)" "$(dirname "$WAREHOUSE_STATE_DIR")"
   npm run db:restore-host -- --state-dir "$WAREHOUSE_STATE_DIR" --backup-key ~/backup.key --yes \
     "$DRIVE/warehouse-backups/<state name>/warehouse-<utc>.tar"
   ```

   `--yes` confirms that the original host is permanently off. The command
   checks all of the following before it creates the state. First the archive,
   unopened: against its `.sha256`, and its signature file (`.hmac`) against
   your key. An archive without a `.hmac` file is not opened; copy the `.hmac`
   from the drive with the archive (only an archive from before format v5, or
   one you packed yourself, has none, and needs `--allow-unsigned`). The
   archive is then unpacked into a temporary folder next to the new state
   (an encrypted `.tar.enc` is decrypted with the same key; the folder is
   removed again if anything fails) and the backup inside is checked: its
   signature against your key, its contents (only the backup folder, no links,
   exactly the signed files) and its own checksums. Then: that this checkout contains every migration the backup applied (otherwise it
   names the `source_commit` to check out), that no container and no
   database volume of this installation exists on the host (a left-over
   `<project>_db-config` volume would hand the restored database the previous
   cluster's configuration and key material; the message names the
   `docker volume rm` command; monitoring and print-spool volumes hold no
   restored state, are reported and kept), the host prerequisites and 10 GiB of free
   space. A backup that fails the signature check was changed after it was
   written or belongs to another installation: do not restore it. A backup
   written before format v5 has no signature and is accepted only with
   `--allow-unsigned` (then `--backup-key` may be left out); use that only for
   a drive that never left your custody. A v5 backup whose `SHA256SUMS.hmac` is
   missing is refused even with `--allow-unsigned` while `--backup-key` is given:
   leave `--backup-key` out only when the key is really lost. It then creates the state from the backup's `compose.env` and
   `instance.json`, changing only the three state-path lines (and installs the
   central sign-in key file, `public/central-jwks.json`, when the backup
   carries one), keeps a copy of the
   backup under `backups/`, and runs the in-place restore: a new database from
   the pinned image, replay of both databases and the stored files, integrity
   comparison, newer migrations, all services started and `doctor --local` (for a
   backup that lacks the central key file named by `compose.env`, that one finding
   is only a warning, and step 7 says how to fix it). It
   ends by printing the remaining steps. A backup directory (already extracted)
   works as well as the `.tar`. If it fails after creating the state, it says so
   and how to start over; nothing else on the host is changed.
4. **Check the summary line.** The command prints the instance ID and the path the
   installation used before. Use `export WAREHOUSE_STATE_DIR=<the new path>` for
   every operator command on this host from now on.
5. **Prove it.** If you recorded a fingerprint with this backup:

   ```bash
   bash scripts/data-fingerprint.sh | diff ~/fingerprint-warehouse-<utc>.txt - && echo IDENTICAL
   ```

   A fingerprint recorded before this release lacks the lines for orders, order
   lines, order revisions and payments, so the `diff` shows those four lines
   added and never prints `IDENTICAL`: compare the other lines, and record a new
   fingerprint after upgrading.

   Otherwise sign in to the app and check the latest GRNs, dispatches and
   invoices you remember. Record the result.
6. **Bring the public address back.** If the backup carried the tunnel
   credential, `db:restore-host` put it in `config/tunnel/` and says so; then:

   ```bash
   sudo bash scripts/tunnel.sh install-service --state "$WAREHOUSE_STATE_DIR"
   node scripts/doctor.mjs
   ```

   Otherwise adopt your private copy first (`bash scripts/tunnel.sh adopt
   --config …` or `--token-file …`, as in
   [Cloudflare Tunnel ingress](#cloudflare-tunnel-ingress)), then run the same
   two commands. The DNS route already exists; do not create a new tunnel. If
   the credential is lost too, create a new tunnel and point the existing
   hostname at it in the Cloudflare dashboard, replacing the old tunnel's record.
7. **Central sign-in from a key file.** Skip this unless `CENTRAL_JWKS_FILE` is set
   in `config/compose.env` (central sign-in with keys from a file, see
   [Central sign-in](#central-sign-in)). A backup taken with this release brought
   `public/central-jwks.json` back with the rest, and
   `node scripts/doctor.mjs --local` confirms it. A backup written before that did
   not, and `db:restore-host` printed a step with this command; run it with your
   usual administrator phone and name and the key set the association sent you:

   ```bash
   bash setup.sh --operator --state-dir "$WAREHOUSE_STATE_DIR" \
     --admin-phone 91XXXXXXXXXX --admin-name 'Warehouse Administrator' \
     --central-issuer https://login.association.example \
     --central-jwks-file /secure/association-jwks.json
   ```

   Setup keeps the instance identity and the data, copies the file to
   `public/central-jwks.json`, and rebuilds the images once (a restored state has no
   build record). Until then every central sign-in fails while the app still
   offers it, and `doctor` says so; SMS sign-in is unaffected.
8. **Protect the new host.** Set up the [USB backup drive](#usb-backup-drive)
   again (`sudo bash scripts/backup-usb.sh setup …`, then re-plug the drive) and
   check that a new backup appears next to the old ones.

   `db:restore-host` also rendered the monitoring files for the restored
   project, so the `monitoring` profile starts. The Slack webhook URL is a
   secret and is not in a backup: if this installation sent alerts to Slack,
   alerts are local only until you run `setup.sh --operator` again with your
   usual inputs (it asks for the URL on a terminal) or `--alert-webhook-file` ([MONITORING.md](MONITORING.md#alert-delivery)).
9. **Rotate if the drive may have been exposed.** Unencrypted archives hold every
   key in plain text. `bash rotate-keys.sh --yes` replaces the signing keys (every phone
   signs in again). Rotate the MSG91 key in its console and apply it as in
   [Replacing MSG91 credentials](#authentication-and-otp-limits), replace
   the tunnel credential (see [USB backup drive](#usb-backup-drive)) and the
   passwords under
   [Secrets that rotate-keys does not change](#secrets-that-rotate-keys-does-not-change),
   then take a new backup.

### Secrets that rotate-keys does not change

`rotate-keys.sh` replaces the JWT secret and the two API keys derived from it.
`compose.env`, and so every unencrypted backup, holds more. After a backup
medium was exposed, these stay valid until you change them by hand. Except
`SENSOR_INGEST_KEY`, which posts sensor readings through the tunnel and so
must be replaced at once, none of them is usable from the internet through the
tunnel: they matter to someone who also reaches the host or its network.

| Secret | What it opens | How to replace it |
| --- | --- | --- |
| `DASHBOARD_PASSWORD` | Nothing in this release: it is passed to the gateway container, but the gateway configuration (`docker/kong.yml`) has no route that asks for it. | Manual, below, so that a later route never trusts a disclosed value. |
| `CUPS_ADMIN_PASSWORD` | The CUPS administration page (printing profile). | Manual, below. |
| `TAPO_PASSWORD` (with `TAPO_USERNAME`) | The Tapo account of the hubs: the hubs on the LAN, and the account in the Tapo app and cloud (sensors profile). | Change it in the Tapo app, set the new value in `compose.env`, then `bash scripts/compose.sh --profile sensors up -d --force-recreate sensor-bridge`. |
| `SENSOR_INGEST_KEY` | Posting sensor readings to this installation's ingest function, from anywhere the gateway is reachable (sensors profile). | Mint a new key with a new label (`bash scripts/compose.sh exec -T db psql -X -qAt -v ON_ERROR_STOP=1 -U supabase_admin -d postgres -v label=<new label> < scripts/sensor-ingest-key.sql`, which prints it once), set it, recreate the bridge, then revoke the old one (`bash scripts/compose.sh exec -T db psql -X -q -v ON_ERROR_STOP=1 -U supabase_admin -d postgres -c "UPDATE warehouse_security.sensor_ingest_keys SET revoked_at = now() WHERE label = '<old label>' AND revoked_at IS NULL"`); [SENSORS.md](SENSORS.md#ingest-keys). |
| `POSTGRES_PASSWORD` | The superuser logins (`postgres`, `supabase_admin`), from inside the Compose network or the host. | `npm run db:rotate-passwords -- --yes --superuser`; see [Rotating the database passwords](#rotating-the-database-passwords). |
| `DB_PASSWORD_AUTHENTICATOR`, `DB_PASSWORD_STORAGE`, `DB_PASSWORD_AUTH`, `DB_PASSWORD_POOLER`, `DB_PASSWORD_MONITORING` | Each one database login of one service (PostgREST, Storage, the disabled Auth service, the pooler's pool user, the Postgres exporter), from inside the Compose network. | `npm run db:rotate-passwords -- --yes`; see [Rotating the database passwords](#rotating-the-database-passwords). |
| `REALTIME_DB_ENC_KEY` | Decrypts the database credentials Realtime stores for its tenant. | Rotated with the superuser password (`--superuser`). |
| `SECRET_KEY_BASE`, `VAULT_ENC_KEY` | Realtime and pooler session signing; encryption of the pooler's stored tenant credentials. | No supported procedure yet; see below. |

These procedures are written from the service definitions and are **not
exercised by CI**. Take a `db:backup` first and check with
`node scripts/doctor.mjs --local` afterwards.

```bash
cd /path/to/installed/backend
export WAREHOUSE_STATE_DIR=/absolute/path/to/this/warehouse
npm run db:backup
new="$(openssl rand -hex 32)"
# Replace one line of the private configuration, keeping its mode (repeat per secret):
sed -i "s/^DASHBOARD_PASSWORD=.*/DASHBOARD_PASSWORD=$new/" "$WAREHOUSE_STATE_DIR/config/compose.env"
bash scripts/compose.sh up -d --force-recreate --wait kong            # DASHBOARD_PASSWORD
bash scripts/compose.sh --profile printing up -d --force-recreate cups   # CUPS_ADMIN_PASSWORD, if you run printing
node scripts/doctor.mjs --local
```

`SECRET_KEY_BASE` signs Realtime's and the pooler's sessions and
`VAULT_ENC_KEY` encrypts the pooler's stored tenant (which holds the pool
user's password). Changing them is not scripted and has not been rehearsed,
so this guide gives no procedure that could leave the pooler unable to read
its tenant. These values cannot be used from outside the host and its Docker
network (the database publishes no port and the gateway listens on loopback
only); keep the host's logins and network closed. If you must replace them
now, rehearse on a copy first: restore the newest backup onto a spare machine
with `db:restore-host`, try the change there, and only then repeat it on the
real host.

### Rotating the database passwords

Every database login has its own password in `compose.env`
([CONTAINER_SECURITY.md](CONTAINER_SECURITY.md#database-passwords-one-per-login)):
`POSTGRES_PASSWORD` is the superuser's (`postgres`, `supabase_admin`), and
PostgREST, Storage, the disabled Auth service, the pooler's pool user, the
and the Postgres exporter each sign in with their own. One command
replaces them:

```bash
cd /path/to/installed/backend
export WAREHOUSE_STATE_DIR=/absolute/path/to/this/warehouse
npm run db:backup
npm run db:rotate-passwords -- --yes                # every service login
npm run db:rotate-passwords -- --yes --superuser    # also POSTGRES_PASSWORD and the Realtime key
npm run test:db-roles                               # each login refuses the superuser password and takes its own
npm run db:backup                                   # older backups carry the previous values
```

What it does, in this order:

1. Writes new values into `config/compose.env.rotating-db` (only those lines
   differ from `compose.env`).
2. Sets them in the database in one transaction, signed in with the current
   superuser password. It sends SCRAM verifiers on standard input, never the
   passwords, so nothing reaches a log, an argument list or
   `pg_stat_statements`. If this step fails, the command asks the database
   whether it still has the values of `compose.env`; only then does it remove
   the staged file (nothing has changed). Otherwise it keeps the file and says
   so, and the next run sorts it out (below).
3. Keeps the previous file as `config/compose.env.before-db-rotation`, puts
   the new one in place, and recreates the database and every running service
   that signs in to it (PostgREST, Storage, Realtime, postgres-meta, Studio,
   and the pooler and exporter when they run). The command takes
   about a minute; in the rehearsal the app could not load data for about 11
   seconds of it (both with and without `--superuser`). A service you stopped on purpose stays
   stopped and reads its new value when it next starts. No session ends and
   no phone signs in again: the JWT signing keys are `rotate-keys.sh`'s.
4. Proves each login (`npm run test:db-roles`) and runs `node scripts/doctor.mjs --local`.
   If a service does not come back or a login misbehaves, it sets the previous
   values in the database again, moves the previous file back, recreates the
   services and exits with an error: nothing is rotated.

If the command stops half-way (a power cut, a killed shell, a full disk, a
reversal that failed too), it leaves `compose.env.rotating-db`,
`compose.env.before-db-rotation` or both behind. Do not move or delete them
yourself: run `npm run db:rotate-passwords -- --yes` again. It does not rotate
then; it finds out which values the database has, by signing in over the
network with each file's superuser and PostgREST values as
`npm run test:db-roles` does. It keeps the file that matches as `compose.env`,
removes the others (the database does not have their values) and says so:

```text
The database has the values of compose.env.rotating-db: it is compose.env now.
Nothing was rotated. Run bash start.sh so every service uses these values, check with npm run test:db-roles, then run npm run db:rotate-passwords -- --yes again if you still want new ones.
```

Then do what the last line says. If the database is not running, start it
alone first (`bash scripts/compose.sh up -d --wait db`). If the database takes
the values of none of the files, or gives no clear answer, the command changes
nothing and says so; keep every file and ask for help, quoting the message.

A restore of a backup taken before a rotation brings that backup's values
back together with its data (`db:restore -- --restore-config`, or
`db:restore-host`); the restored database gets them at start. A backup taken
before every login had its own password (before this release) has none: both
restore paths then give the restored configuration new ones before the
database starts.

## Lists refresh after the commit

Since migration 91 the invoice list, the dispatch list of `get_dispatch_list` and
the legacy GRN list are materialized views that a background job refreshes
after each write, instead of the write itself (on a populated warehouse that
refresh took most of a dispatch's 8 s and made concurrent writers time out).
What to know:

- **The job.** pg_cron (preloaded by the database image and
  `docker-compose.override.yml`) runs `warehouse-list-refresh` every 5 seconds
  as the role `warehouse_list_refresher`, inside the db container. Nothing new
  runs outside it and no port, image or Compose service is added. The role has
  no password: it connects over 127.0.0.1 inside the container, and every
  network address needs a password.
- **Staleness.** A committed change reaches those lists within 15 seconds:
  at most one 5-second interval plus the refresh (about 2 s on a site with
  12,000 GRNs), typically 3 to 4 seconds. The answer of the write itself is
  immediate. Other lists read the tables directly.
- **The doctor** (`health-check.sh`, also run by setup and restore) fails with
  `list refresh: ...` when the job is missing or paused, the role cannot log in,
  a refresh fails, the last run failed, a list has waited more than 15 s, or a
  session other than the job's holds the refresh lock 71046 (it names that
  session's pid, user and application). The first run after a start gets 30 s
  to catch up. `setup.sh` (or
  `bash scripts/compose.sh exec -T db psql -X -q -U supabase_admin -d postgres < scripts/configure-list-refresh.sql`)
  puts the job and the role back.
- **By hand.** `SELECT warehouse_security.list_refresh_status();` shows the same
  as the doctor. To refresh now, run the worker once, in its own short session:

  ```bash
  bash scripts/compose.sh exec -T db psql -X -U supabase_admin -d postgres \
    -c 'CALL warehouse_security.refresh_dirty_lists_worker()'
  ```

  Do not run that CALL inside an open interactive psql: if it stops on an error
  or Ctrl-C, that session keeps the refresh lock 71046 until it ends, and every
  run of the job returns at once meanwhile (the doctor names the session; end
  it to recover). Outside a transaction block only.
- **Logs.** The db runs with `cron.log_statement=off`
  (`docker-compose.override.yml`), so a run writes no `cron job ... starting` or
  `completed` line; `cron.job_run_details` keeps one day of runs, and the doctor
  reads that. Each run is still one connection with three lines
  (`connection received`, `connection authorized`, `disconnection`), about 9 MB
  a day in Docker's log format. With the db healthcheck's own connection lines
  (about as many), the db log's 3 x 10 MB rotation holds about a day and a
  half. The setup rerun that brings migration 91 recreates the db container,
  because its command changed.
- **Upgrade.** Setup applies migration 91 and the job starts at once; no extra
  step. Migrations run under the refresh lock 71046 (`scripts/migration-plan.mjs`),
  so no refresh runs during them; a refresh in progress finishes first, and setup
  stops with the holder's pid if the lock is not free within 120 s. **Restore** runs `scripts/configure-list-refresh.sql` itself, after the
  migrations. `db:verify-restore` leaves pg_cron's own objects (the job table
  and its history) out of its check, because that extension can only be created
  in the `postgres` database.

## Rerun and upgrade

A rerun is the same `setup.sh --operator ...` command with the same inputs
against the same state directory. It regenerates nothing that already exists:
identity, signing keys, database, stored files, the administrator and the
provider lines are preserved (a different `--provider-env` file replaces only
the MSG91 lines; the `--central-…` options set or replace only the
[central sign-in](#central-sign-in) lines and its key file; `--gateway-port`
replaces only `KONG_HTTP_PORT`, and only while the containers are stopped).
A rerun also adds what an older state lacks and never replaces what exists:
the per-role database passwords, the backup key, and the monitoring files and
Slack webhook URL under `config/monitoring` ([MONITORING.md](MONITORING.md)).
Run it a second time right after installation and compare
`public/instance.json` and the administrator record before and after.

To upgrade to a newer `main`:

```bash
cd /path/to/installed/backend
export WAREHOUSE_STATE_DIR=/absolute/path/to/this/warehouse
npm run db:backup                      # prints the backup directory
npm run db:verify-restore -- "$WAREHOUSE_STATE_DIR/backups/warehouse-<utc>"
bash scripts/backup-disk.sh sync       # only if you use a backup disk
(umask 022; git pull --ff-only)
bash setup.sh --operator ...           # the same inputs as the installation
bash scripts/compose.sh up -d --force-recreate functions   # needed when the pull changed anything under functions/
node scripts/doctor.mjs --local && node scripts/doctor.mjs
sudo bash scripts/backup-usb.sh setup --state "$WAREHOUSE_STATE_DIR"   # only if you use a USB backup drive
```

The last line keeps the USB choices of your earlier setup (`--encrypt`,
`--daily`, `--no-fresh-backup`); it prints them, so check that line.

### Upgrading from Gotenberg to the PDF renderer

The PDF service is now `pdf-renderer` (chrome-headless-shell driven by puppeteer-core; no LibreOffice, much
smaller image) on a new internal Compose network `renderer`. Gotenberg is gone from the Compose file. The
ordinary upgrade above does everything; what to know:

- `setup.sh` and `start.sh` remove this project's old `gotenberg` container by its Compose labels and, after the
  start, the old `<project>-gotenberg` image, and print a line for each. `stop.sh` runs `down --remove-orphans`.
  If you start the new checkout with `docker compose` by hand instead, run
  `docker rm -f $(docker ps -aq --filter label=com.docker.compose.project=<project> --filter label=com.docker.compose.service=gotenberg)`
  first, or the old container keeps running unmanaged.
- The first `setup.sh` after the pull builds the `pdf-renderer` image: it downloads chrome-headless-shell from
  Chrome for Testing (the version and SHA-256 are pinned in `docker/pdf-renderer/Dockerfile`), so the host needs
  outbound HTTPS to `storage.googleapis.com` during that one build. Nothing is downloaded at run time.
- `GOTENBERG_URL` is now `PDF_RENDERER_URL` (set by the Compose file; there is nothing to change in `compose.env`).
- PDFs look the same: the renderer uses Gotenberg's Chromium launch flags, print settings and fonts. Document
  and report functions only need `bash scripts/compose.sh up -d --force-recreate functions`, which the upgrade
  step above already does.
- The renderer container is limited to 1.5 GiB of memory (`mem_limit: 1536m`, no swap), 512 MiB more than Gotenberg's
  1 GB; its thresholds are sized for that value, so do not lower it. Its `/health` reports `memoryMB` (Chrome) and
  `containerMB` (the container).
- Backups no longer stop a Gotenberg container (`scripts/backup.sh`); the renderer is stateless.
- Before anything is changed, `setup.sh` and `start.sh` create and remove a throwaway internal network
  `<project>_netcheck`. If Docker has no free address pool for it they stop with a message and leave the installation
  as it was. The old Gotenberg container is removed only after the images are built and the migrations ran, right
  before the full start.
- Rollback to the previous release: the old release's `stop.sh` is a plain `down`, so it would leave the renderer
  running as an orphan, and the old `restore.sh` refuses while any container of the project exists. So, from the
  **new** checkout first:
  `bash scripts/compose.sh --profile '*' down --remove-orphans` (this removes the renderer and its network), then
  check out the old release and run its `setup.sh --operator ...`. The upgrade removed the old
  `<project>-gotenberg` image, so the old release rebuilds Gotenberg from its recipe (an image build with internet
  access, several minutes).

**The upgrade that splits the database password** (the first release with
`npm run db:rotate-passwords`) adds a password of its own for every database
login of the services to `compose.env` and sets them in the database. Run
`setup.sh` right after the pull, before any other command: until then every
Compose command, `stop.sh` and `start.sh` included, stops with "Run setup.sh
to generate the per-role database passwords". The run restarts the database
and the services that sign in to it; in the rehearsal of 2026-10-18 two of
225 API requests made every half second during the run failed (once when the
database restarted, once when PostgREST did), and the whole setup run took two
minutes. Afterwards check with `npm run test:db-roles`, then replace the
superuser password too:

```bash
npm run test:db-roles
npm run db:rotate-passwords -- --yes --superuser   # about a minute, the API down about 11 s
npm run db:backup
```

The upgrade gives every service login a new password but keeps
`POSTGRES_PASSWORD`, the value that until now every login shared. That value
sat in the environment of PostgREST, Storage, the Auth service and the Postgres
exporter. Whoever read it from
one of those places still holds the superuser password until it is rotated.
The new backup is taken after the rotation; backups taken before it remain
restorable (see
[Rotating the database passwords](#rotating-the-database-passwords)).

The `--force-recreate functions` line is needed because the edge functions
(`functions/`, including `functions/_shared/`) are bind-mounted into the
`functions` container and the edge runtime keeps the modules it has loaded: a
setup rerun neither rebuilds an image for them nor recreates the container, so
without that line the running functions keep serving the old code. Database
migrations need no such step: setup applies them.

**Setup rebuilds the images whose recipes changed.** Before it starts
anything, `setup.sh` runs `scripts/build-images.sh`. That script compares each
image recipe (the files under its `docker/` build directory, its Dockerfile
path, build target and build arguments) with a record of what it built last
(`config/image-recipes.sha256` in the state directory: the recipe's
fingerprint and the ID of the image built from it) and rebuilds the images
whose recipe differs or whose tag no longer names the image it built. Setup's
start then replaces only the containers whose image changed. What to expect:

- The first setup rerun after this behaviour arrived finds no record and
  rebuilds every image in use once. That needs the network and can take a
  good while on a small machine; later reruns print "Images match their
  recipes; nothing to rebuild." and need no network. A state directory made
  by `restore-host` has no record either, so the first setup there rebuilds
  once as well.
- A build needs the network when a recipe changed. If it fails, setup stops
  before it starts or stops anything and records nothing as built. Running
  services stay as they are. An image that did finish building before the
  failure is used the next time its service is started, so run setup again
  when the network is back rather than leaving the installation half way.
- Optional services (`monitoring`, `printing`, `pooler`, `sensors`) are rebuilt only if
  this installation has a container of them. Setup and `start.sh` start only
  the core services, so after their own start they replace the optional
  services that are running and whose image or configuration changed. A
  failure there is printed as a warning; the core services stay up.
- A running optional service whose image does not match this checkout (the
  image is missing, its recipe changed, or its tag names an image this
  checkout did not build) is left running unchanged with the warning "the
  <service> image does not match this checkout"; `bash scripts/build-images.sh`
  or the next setup rerun builds it, and the following start replaces it.
- The monitoring files (`config/monitoring/`, `metrics/`) are written by every setup run; the
  first run after the release that added them creates them, and the next
  replacement of Prometheus and Alertmanager (the same step) loads them. A
  Prometheus or Alertmanager that is running is replaced when those files or
  `docker/alert-rules.yml` changed. Run `npm run db:backup` once afterwards: the
  backup alerts (`BackupMissing` after 26 hours) read the time of the last backup
  that was written down after this release.
- `start.sh` never builds: a host that restarts offline starts what it has.
- Every built image is tagged for its installation (`<project>-<service>`).
- A setup from a release before this one did not rebuild anything: it kept
  every image of the first installation, and recipe changes never reached
  the running services. If you stay on such a release, run
  `bash scripts/compose.sh build` before the setup rerun (with
  `--profile monitoring` and so on for optional services, and start those
  again yourself).

The build cache also keeps the operating-system packages of the day an image
was first built. Now and then, and before reading scan numbers, rebuild
without it: `bash scripts/build-images.sh --no-cache`, then `bash start.sh`
([CONTAINER_SECURITY.md](CONTAINER_SECURITY.md), "Open items with their
steps"). `bash scripts/build-images.sh --all` rebuilds everything in use with
the cache.

**Upgrading to the release with signed backups (format v5).** Do these once,
in this order, after the commands above:

1. `setup.sh` created `config/backup.key`. Copy it somewhere away from this
   machine and from the backup drive now (see [Backup key](#backup-key)).
2. Take a new backup: `npm run db:backup`. Backups from before the upgrade are
   unsigned; `db:verify-restore`, `db:restore` and `db:restore-host` accept
   them only with `--allow-unsigned`.
3. USB drive: with each drive attached, enroll it again
   (`sudo bash scripts/backup-usb.sh enroll --device /dev/sdX1`). A drive
   enrolled by an earlier release is refused until then, and nothing is copied
   to it: the setup command above names each such drive, and from then on
   `bash scripts/backup-usb.sh status` and `npm run doctor` show a failed USB
   backup with the `enroll` command until a run succeeds. Then unplug the drive,
   plug it in again and check `status`.
4. Decide about `--encrypt` for the USB archives (see
   [USB backup drive](#usb-backup-drive)).
5. A lost-host restore now needs `--backup-key`; update your own recovery notes.

Update the checkout under `umask 022`, as for the first clone. Git writes the
files it changes with the current umask: Ubuntu's default `0002` makes them
group-writable, which the root-run backup helpers refuse, and `077` makes them
unreadable by the containers. `setup.sh` restores the modes of every tracked
file on each run, and `bash scripts/checkout-permissions.sh` does the same on
its own, for example after a `git pull` or `git checkout` made without
`umask 022`.

**Migration 42 and tables of your own.** Migration 42 closes direct writes on
the template's nineteen business tables and verifies only those. A table you
added to the `public` schema, and any grant or row policy on it, is left as it
is and does not stop the upgrade. The migration stops with
`authenticated still holds a direct write on: <table>` or
`Unexpected write policy on a business table: <table>.<policy>` only when one
of the nineteen tables itself carries an extra write policy; drop that policy
or make it `FOR SELECT`, then rerun.

The rerun applies only the migrations the ledger has not seen (append-only and
checksum-verified; a changed applied file is refused) and recreates the
services whose definition changed. Read `CHANGELOG.md` for the release first:
a release that changes the mobile contract needs the matching app build. If
the upgraded instance is rejected, stop it and restore the pre-upgrade backup
with the in-place restore above.

## Windows host with Linux VM

Install the same Linux stack inside an x86-64 VM and keep its state on a durable
VM disk. For a Hyper-V host, configure automatic start and a graceful stop from
an elevated PowerShell session, substituting the actual VM name:

```powershell
Set-VM -Name WarehouseVM -AutomaticStartAction Start -AutomaticStopAction ShutDown
```

Expose only the tunnel connector from the VM. Reboot the Windows host without
logging in, then verify that the VM, Docker services, the tunnel service and
both doctor modes recover. A Windows USB printer queue shared to CUPS through
Samba is a separate physical acceptance path; check it after the same
unattended reboot. The start and stop settings are documented by
[Microsoft's Set-VM reference](https://learn.microsoft.com/en-us/powershell/module/hyper-v/set-vm).
For VMware or another hypervisor use its own startup/shutdown procedure; a
successful guest reboot does not prove host autostart or USB reattachment.

## Troubleshooting

Service-level diagnostics (containers, logs, Kong, PostgREST, the PDF renderer and
CUPS checks) are in [TROUBLESHOOTING.md](TROUBLESHOOTING.md). Installation
problems seen so far and their causes:

- **`Another operator command ... is running for this state`** — a previous
  setup, start, backup or restore is still running, or was interrupted while
  holding `config/operator.lock`. Wait or inspect `ps`; never delete the lock
  file.
- **`... is group- or world-writable` from `backup-usb.sh setup` or
  `backup-disk.sh`** — the checkout was updated (`git pull`, `git checkout`)
  under a umask other than `022`; Ubuntu's default `0002` does this. As the
  installation user run `bash scripts/checkout-permissions.sh` (or rerun
  `setup.sh`), then repeat the command. Update with `(umask 022; git pull
  --ff-only)` from then on.
- **PostgreSQL restarts with `Permission denied` on first start** — the
  checkout was cloned under `umask 077`. Re-clone with `umask 022` into a new
  directory and use a fresh empty state; keep the failed state for diagnosis.
- **`Operator installation requires Linux x86-64` or `Missing prerequisite`** —
  `scripts/check-readiness.sh` refuses other architectures and missing
  `docker`, `node`, `npm`, `openssl` or `flock`; `doctor` additionally requires
  Node 22.18+, a Compose plugin that accepts `up --wait-timeout` and a reachable Docker daemon.
- **`node: command not found` in a new terminal or a service** — the user-owned
  Node is only on `PATH` where it was exported; repeat the export and keep it
  in `~/.profile`.
- **`State directory must be mode 0700` / `must not use a symlink` / `outside
  this checkout`** — the doctor's path rules; create the directory as shown in
  [private inputs](#private-inputs).
- **Public-configuration reads take seconds; gateway logs show
  `rest.localdomain` SERVFAIL** — the host's DHCP search domain leaked into
  the gateway's resolver. `docker/docker-compose.yml` pins `dns_search: "."`
  for Kong; keep it, and do not change host DNS or extend client timeouts.
- **`EACCES: permission denied, mkdir '…/<name>.installing-…'` during setup** —
  the parent of the state directory (for example `/srv/warehouse`) is not owned
  by the installation user, typically because `sudo install -d` created it with
  the leaf. Run `sudo chown "$(id -un):$(id -gn)" /srv/warehouse`, keep it mode
  0755, and rerun the same setup command.
- **External doctor fails while `--local` passes** — the tunnel service is
  inactive, the DNS record does not point to `<tunnel-uuid>.cfargotunnel.com`,
  the route targets the wrong loopback port, the origin redirects, or the host
  cached an NXDOMAIN from a lookup made before the route existed (compare
  `dig +short <hostname> @1.1.1.1` with `dig +short <hostname>`; wait for the
  negative TTL or flush the resolver cache). Check `systemctl status` of the
  unit and `cloudflared ... tunnel ingress validate`. Right after a key rotation
  one failure is normal; rerun after about thirty seconds.
- **Nothing happens when the USB drive is attached** — check that it is
  enrolled and visible to the host: `bash scripts/backup-usb.sh status` (on
  VMware the drive must be connected to the VM, not the Windows host), then
  `journalctl -u 'warehouse-usb-backup@*' -n 50`. Only exFAT partitions on USB
  drives whose UUID is enrolled start a run; reformatting a drive changes its
  UUID, so enroll it again.
- **Setup succeeded but no backup was copied** — setup does not start a run for
  a drive that is already attached. Unplug the drive (on VMware: Removable
  Devices → Disconnect) and attach it again, then follow the run with
  `journalctl -f -u 'warehouse-usb-backup@*'`.
- **`sudo: a terminal is required` or `a password is required` running setup**
  — the command was started from a shell without a terminal. Run it in a
  terminal window on the host or an SSH session.
- **`db:restore`: `the backup instance.json differs from this state`** — the
  backup belongs to another installation, typically because `setup.sh` was run
  on the new host before restoring. In-place restore only replaces the instance
  that produced the backup. Do not edit `instance.json` to get past the check:
  move the new state aside and follow
  [Recover a lost host from the USB drive](#recover-a-lost-host-from-the-usb-drive),
  which recreates the state from the backup instead of running setup.
- **`db:restore-host` refuses** — every refusal happens before anything is
  created. `backup has N migrations and this checkout only M` or `migrations this
  backup applied differ`: check out the commit the message names
  (`source_commit`) or a later release. `containers of … already exist`: this
  host still runs (or ran) that installation; restore-host is for a new host,
  use `db:restore` on the existing state instead. `already exists and is not
  empty`: choose a new state path; restore-host never overwrites an
  installation. `Missing checksum file` or `does not match`: use another
  archive from the drive.
- **`tunnel.sh adopt` refuses** — `certificate or key block` / `origincert`: you
  pointed it at `cert.pem` or at a config naming it; adopt only the tunnel's
  `config.yml` with its credentials JSON (remove the `origincert:` line) or the
  token file. `does not route <host>`: the config belongs to another installation
  or its `hostname:` differs from this installation's `--api-url`.
  `not the credentials JSON of tunnel`: the `credentials-file:` is another
  tunnel's. `already exists`: a credential is already adopted; move
  `config/tunnel` aside to replace it.
- **`tunnel.sh install-service`: `did not start`** — read
  `journalctl -u warehouse-<state name>-tunnel.service -n 50`; a dated copy of the
  previous unit is next to it in `/etc/systemd/system/` if you need to go back.
- **`backup-usb.sh`: `Could not unmount …`** — a file manager window or terminal
  is using the drive; close it and run
  `sudo /usr/local/libexec/warehouse-usb-backup unmount sdb1` (your partition).
- **USB run failed: `matches its checksum but was not signed with the current
  backup key`** — the archive is intact but its signature is from another key.
  After you replaced the backup key this is expected for the older archives:
  move them into another folder on the drive (see [Backup key](#backup-key)).
  If you did not replace the key, someone rewrote the archive and its checksum
  on the drive: do not use it, delete it, and the next run writes it again.
- **USB run failed: `carries no valid signature of this installation's backup
  key; it was not opened`** — the drive holds an archive newer than every
  archive this installation signed. Right after upgrading from a release with
  unsigned archives, take a new backup (`npm run db:backup`, or just attach
  the drive when fresh backups are on). Otherwise somebody put the file there:
  remove it. The run still verifies the newest archive it signed itself.
- **USB run failed: `does not match its checksum; it was not overwritten`** — an
  archive on the drive is damaged. Copy the drive's other files elsewhere, run
  `sha256sum -c` on each `.tar.sha256` to see which, and replace the drive if
  errors recur; delete a damaged archive yourself and the next run writes it
  again.
- **`backup-disk.sh`: `No second disk found`** — nothing but the system disk is
  attached. Attach an empty disk (see [Backup disk](#backup-disk)), rescan or
  reboot, and run `plan` again. The helper never offers a partition of the
  system disk.
- **`backup-disk.sh`: the disk `already carries a … signature` or `has a
  partition table`** — the helper only uses blank disks and never wipes. Inspect
  with `lsblk -f`; if you are certain the disk holds nothing you need, clear it
  yourself (for example `sudo wipefs -a /dev/sdX`) and run `plan` again.
- **`backup-disk.sh sync` or `status` says the mount point is not mounted, is
  missing its marker, or sits on the system disk** — the disk did not mount at
  boot (the fstab entry uses `nofail`). Run `bash scripts/backup-disk.sh status`,
  then `sudo mount /srv/warehouse-backups`. Never copy backups into an unmounted
  mount point: they would land on the system disk.
- **`apply stopped during: …`** — a step of `backup-disk.sh apply` failed after
  it had started writing. Nothing is undone or wiped automatically. Run
  `status` to see how far it got (a disk labelled `warehouse-backup` but not
  mounted is "partitioned but not finished") and finish or clean up by hand.
- **`An admin already exists with a different phone`** — an active
  administrator with another phone exists: the state directory belongs to
  another installation (use an empty one), or you gave the wrong
  `--admin-phone`. An administrator who was deleted or disabled does not cause
  this; see [the last administrator](#authentication-and-otp-limits).
- **OTP accepted by the API but not received** — verify the Flow ID (not the
  DLT template ID), the `OTP` variable name and the sender/entity approval in
  the MSG91 console. The per-phone, per-IP and warehouse-wide caps above return
  an explicit refusal, not silence.
- **`This Docker Compose plugin does not accept up --wait-timeout`** — the
  Compose plugin is too old for the flag the scripts use. Install a current
  plugin from Docker's repository (any build listed under the host
  prerequisites works); a newer major version is not a problem by itself.
