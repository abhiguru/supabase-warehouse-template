# Operator installation

One warehouse per installation: a fresh Linux x86-64 host or VM owns its
database, document storage, credentials and canonical HTTPS origin. The
installer writes every private file to a state directory outside the Git
checkout and never touches another installation. This guide is current for
`main`. What is still open before production use is listed in
[PRODUCTION_DEPENDENCIES.md](PRODUCTION_DEPENDENCIES.md). When something goes wrong,
see [TROUBLESHOOTING.md](TROUBLESHOOTING.md).

Sections: [host prerequisites](#host-prerequisites),
[private inputs](#private-inputs), [setup](#setup),
[several facilities on one host](#several-facilities-on-one-host),
[authentication and OTP limits](#authentication-and-otp-limits),
[central sign-in](#central-sign-in),
[Cloudflare Tunnel ingress](#cloudflare-tunnel-ingress),
[external doctor](#external-doctor), [first-use checks](#first-use-checks),
[ordinary operation](#ordinary-operation), [retention](#retention),
[rotate signing keys](#rotate-signing-keys),
[backup and restore](#backup-and-restore),
[rerun and upgrade](#rerun-and-upgrade),
[baseline reload](#baseline-reload) (for a database built before PostgreSQL 17; the reload builds the current major, 18),
[major PostgreSQL upgrade](#major-postgresql-upgrade) (17 to 18),
[Windows host with Linux VM](#windows-host-with-linux-vm).

## Host prerequisites

- Linux x86-64 with Docker Engine and the Compose plugin, enabled at boot; Ubuntu 24.04 is the tested baseline. ARM64 is
  not supported. The requirement is a Compose plugin whose `docker compose up` accepts
  `--wait-timeout`: setup, start and the backup scripts wait for services with it, and `doctor` stops with a message
  if the plugin does not know the flag. No version number is required. The central identity service states the same
  requirement, so one host can run both services. Tested with:
  - Docker Compose v2.40.3 with Docker Engine 29.9.1 (the review host; verified for
    this service and for the facility backend);
  - Docker Compose v5.6.0 with Docker Engine 29.9.1 (the development host; verified
    for this service and for the facility backend).
- Network access to `storage.googleapis.com` while the pdf-renderer image is built (it downloads Chrome headless shell).
- Node.js 22.18 or newer with npm, Git, OpenSSL, `curl` and util-linux (`flock`), and `dig` (package `dnsutils`).
- `tmux` (or another way to keep a process running after you log out) for the Expo development server of the app, if you
  run one on this host. The backend itself needs it for nothing.
- A non-root user in the `docker` group. Do not run setup as root or make the Docker socket world-writable.
- At least 10 GiB free on a persistent filesystem for the installation, plus capacity for the data; the doctor enforces
  the minimum.
- Recommended for a real facility: a **USB drive formatted exFAT for backups** (an existing drive is fine; it is not
  reformatted) and `sudo` once to set up the automatic copy ([USB backup drive](#usb-backup-drive)). Setup does not need
  it; without one, `doctor` warns and the backups stay on the host, so copy them off the host yourself.
- `cloudflared` for the tunnel ([Cloudflare Tunnel ingress](#cloudflare-tunnel-ingress)).

Record the host before changing it (`cat /etc/os-release`, `uname -m`, `free -h`, `df -h`, `docker ps`) so that an existing
runtime is never removed by accident.

### Ubuntu 24.04 sequence

Ubuntu's packaged Node 18 is too old. Install a user-owned Node 22 without replacing the OS package (substitute the
current 22.x release; the checksum file comes from Node's HTTPS site, which is not a release-signature verification):

```bash
sudo apt-get update
sudo apt-get install -y ca-certificates curl git openssl util-linux xz-utils dnsutils tmux
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

Repeat the `PATH` export in every shell that runs setup, doctor, start or stop, and add it to `~/.profile`.

Install Docker from [Docker's Ubuntu repository](https://docs.docker.com/engine/install/ubuntu/). Any Compose plugin whose
`up` accepts `--wait-timeout` works; the commands below install the build the review verified. That build can leave the
repository's index later: if `apt-get install` cannot find `docker-compose-plugin=2.40.3-…`, take a current build from the
`apt-cache madison` list instead of stopping.

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

Open a new login session (or `sg docker`), repeat the Node `PATH` export and confirm `docker version`,
`docker compose version` and `docker ps` work without sudo.

Clone the repository with `umask 022` so that container service users can read the bootstrap files; keep `umask 077` for
private state and provider files. A checkout cloned under 077 makes PostgreSQL fail its first start with
`Permission denied` while still reporting a healthy process.

```bash
(umask 022; git clone https://github.com/abhiguru/supabase-warehouse-template.git backend)
cd backend
```

The operator scripts use only Node's built-in modules; `npm ci` is needed only to run the test suite.

## Private inputs

**Gather these before running setup.** Each is explained below or in the section linked.

| Input | Setup option | Notes |
|---|---|---|
| State directory (and its parent) | `--state-dir` (required) | Absolute path outside the checkout, mode 0700, owned by the installation user; see **State directory** below. |
| Public API address | `--api-url` | HTTPS hostname of this facility (no path or port), such as `https://warehouse.example.com`. Required on a first install; the hostname must be routed by the tunnel below. |
| App origin | `--app-url` (optional) | HTTPS origin (no path or port) stored as the trusted browser origin. Leave it out and it is the `--api-url` origin. |
| Company name | `--company` | Display name of the facility, up to 120 characters. Required on a first install. |
| Cloudflare Tunnel | `scripts/tunnel.sh adopt` (needs the state, so after setup) | A **new** tunnel for this host with a route for the `--api-url` hostname: its `config.yml` with the credentials JSON, or a dashboard token file. Not a config copied from another machine. See [Cloudflare Tunnel ingress](#cloudflare-tunnel-ingress). |
| MSG91 provider file | `--provider-env` | Mode-0600 file with five keys; see **MSG91 provider file** below. Required on a first install. |
| First administrator | `--admin-phone`, `--admin-name` (both required) | `91` and ten digits, and a display name; see **First administrator** below. |
| Slack webhook file | `--alert-webhook-file` | Private file with the facility's incoming-webhook URL. `off` only for a non-production install; without the option a terminal is asked and no terminal means setup refuses. See [Setup](#setup). |
| Central sign-in (members only) | `--central-issuer` with `--central-jwks-url` or `--central-jwks-file` | The issuer and the public key set (an address or a file) that the association gives you; see [Central sign-in](#central-sign-in). Leave out for SMS sign-in only. |
| PDF letterhead | `--letterhead-file` | A JPEG or PNG banner (at most 2 MiB) that the GRN, dispatch, invoice and customer stock PDFs print at the top, or `off` for plain PDFs. On a first install setup asks for it on a terminal (Enter means plain PDFs) and, with no terminal and without the option, refuses; a rerun without the option asks nothing and keeps what is there. See [Letterhead image](#letterhead-image-optional). |

**State directory.** An empty absolute path outside the checkout, not reached through a symlink, on the persistent
filesystem, mode 0700 and owned by the installation user. The installer builds the state next to its final path
(`<state>.installing-<random>`) and renames it into place, so the **parent** directory must belong to the installation user
as well. Create both, the second command without `sudo`:

```bash
sudo install -d -m 0755 -o "$(id -un)" -g "$(id -gn)" /srv/warehouse
install -d -m 0700 /srv/warehouse/acme
```

If you create only the leaf with `sudo install -d … /srv/warehouse/acme`, the parent is created root-owned and setup stops
with `EACCES` ([TROUBLESHOOTING.md](TROUBLESHOOTING.md#installation-and-setup)).

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

`MSG91_TEMPLATE_ID` is the MSG91 **Flow ID** (24 lowercase hex characters), not the DLT template ID. `MSG91_PE_ID` is
numeric and `MSG91_SENDER_ID` is six uppercase alphanumerics; the installer validates all three. The Flow's variable must
be named exactly `OTP`. Do not copy a complete legacy `.env` into this file: `SMS_PRODUCTION_MODE` and any other key are
rejected. The OTP worker accepts a request only after MSG91 confirms it, but an accepted API response does not prove
handset delivery, so test with an owned phone. Real credentials are mandatory: there is no fixed-OTP or local delivery
mode. Keep the file out of shell history and version control, and include it in your encrypted off-host backups.

**Notes from an older (pre-template) deployment do not apply.** This backend stores the sign-in codes itself, as an HMAC
(the `otp_verifications` table, checked by `operator_verify_otp`), and setup writes the `public.sms_config` row from the
provider file: do not create either by hand, and do not carry over a `.env` or SQL from the old system. `rotate-keys.sh` takes
only `--yes` and rotates the signing keys ([Rotate signing keys](#rotate-signing-keys)); it does not set up SMS.

**Test installations (CI, review fixtures).** An installation that is not a real facility never gets a real MSG91 key,
because every accepted code request is a real SMS. It uses the sentinel `MSG91_AUTH_KEY=isolated-no-delivery-key` (any
value that starts with `isolated-`) and an address under the reserved `.test`
domain, for example `https://backend-core.example.test`. The installer and the doctor accept the sentinel only for such an
address, and never accept the template text of this file's example (`your-…`, `changeme…`, `fake_…`). The OTP function
sends nothing to MSG91 when the key or the Flow ID is empty, template text or the sentinel (the same rule,
`scripts/provider-placeholder.mjs`). Do not rely on that alone: start a fixture's `functions` container
without a route to the internet (for example on an `internal: true` Compose network, or with a firewall rule for its
address) and prove it with a request from inside that must fail. Tests that need the provider's answer inject their own `fetch`.

A test installation also passes `--alert-webhook-file off` (no Slack channel exists for it; alerts stay on the host) and
`--letterhead-file off` (plain PDFs).
A real facility gives its own Slack webhook, see [Setup](#setup).

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
  --alert-webhook-file /secure/warehouse-slack-webhook.txt \
  --letterhead-file /secure/letterhead.png        # or: --letterhead-file off (plain PDFs)
node scripts/doctor.mjs --local
```

`setup.sh` checks the host (`doctor --host-preflight`), generates a unique Compose project name, signing keys and
`config/compose.env` (mode 0600) in the state directory, takes the per-state operator lock, verifies the configuration and
gateway port (`doctor --preflight`), checks that Docker can create the internal renderer network (it stops before changing
anything when no address pool is free), starts only the database, applies the migration ledger, configures auth, SMS and
storage, bootstraps the administrator, starts every service with `--wait` and runs the local doctor. The gateway listens
on `127.0.0.1:18000` only; the database, CUPS and the sensor bridge are never published.

Optional services are Compose profiles that setup does not start: `printing`, `pooler` and `sensors`. The pooler is off by default and is switched with `bash scripts/pooler.sh on|off|status`, not with `--profile` (see [Pooler (optional)](#pooler-optional)); `sensors` is the Tapo sensor
bridge; set up as in [SENSORS.md](SENSORS.md#run-it-as-a-profile-of-the-installation), then
`node scripts/set-capability.mjs sensors on` and a new `db:backup`).

**Monitoring is not a Compose profile.** One small program, the checker (`scripts/watch.mjs`), runs from a systemd
timer every 5 minutes, tells the facility's Slack channel when something is wrong, and once a day makes and verifies a
backup and applies retention ([MONITORING.md](MONITORING.md)). Installing a unit needs root, which setup never uses, so
when it finishes it prints the command to run from the installation user's account (the same pattern as the tunnel
service and the USB backup drive):

```bash
sudo bash scripts/watch-timer.sh install --state "$WAREHOUSE_STATE_DIR"
```

Run it after every install, after a move of the checkout, and after `db:restore-host`; `start.sh` prints it when the timer
is missing, and `npm run doctor` warns when the timer is not active or the checker has not run in 15 minutes. The timer is
installed even with `--alert-webhook-file off`: the checks and the daily backup still run, only the Slack posts are off.

Alerts go to the facility's own Slack channel, so setup needs its incoming-webhook URL (the owner creates it in
Slack: Apps, Incoming Webhooks). Give `--alert-webhook-file /absolute/path` (a private file, mode 0600, one line), or
let setup ask for it on a terminal; without a terminal and without the option setup refuses.
`--alert-webhook-file off` is for a non-production install. The prompt, the test message, the stored file, the daily
"Monitoring is alive" message and muting before a planned stop are in [MONITORING.md](MONITORING.md).

The PDF letterhead is asked the same way: give `--letterhead-file /absolute/path` (a JPEG or PNG of at most 2 MiB) or
`--letterhead-file off` for plain PDFs, or let setup ask on a terminal (the path, or Enter for plain PDFs). Without a
terminal and without the option a first install refuses, so whoever runs setup for the installer has to ask them first
(see [Letterhead image](#letterhead-image-optional)).

Running the same command again is safe: a rerun preserves identity, keys, database and stored files
([rerun and upgrade](#rerun-and-upgrade)). Setup refuses an active administrator with a different phone, a state path
through a symlink or inside the checkout, a running project owned by another checkout, and another operator command
holding the lock. Private configuration belongs outside the checkout; no source edit is needed.

### Letterhead image (optional)

The GRN, dispatch, invoice and customer stock PDFs can print the facility's letterhead (logo, name and address as a picture) at the
top of the first page. The report PDFs are not changed. The choice is the installer's, so a first install always asks for it:

- **With the option.** `--letterhead-file /absolute/path/letterhead.png` uses that image; `--letterhead-file off` makes the PDFs plain.
  Nothing is asked.
- **On a terminal, without the option.** Setup asks for the path of a JPEG or PNG image (at most 2 MiB), or Enter for plain PDFs. A
  file that cannot be used is explained and asked for again, three tries in all; then setup refuses. `--letterhead-file ask` asks
  on a rerun as well.
- **No terminal (a script, or an agent running setup), without the option, on a first install.** Setup refuses before it changes
  anything: `Refusing: choose the PDF letterhead. Give --letterhead-file /absolute/path/letterhead.png (a JPEG or PNG of at most 2 MiB) ...,
  or --letterhead-file off for plain PDFs. Nothing was changed.` Ask the installer which they want and run it again with the option.
- **A rerun without the option** asks nothing and keeps what is there, so an unattended upgrade needs no change.

```bash
bash setup.sh --operator --state-dir "$WAREHOUSE_STATE_DIR" --admin-phone 91XXXXXXXXXX --admin-name 'Warehouse Administrator' \
  --letterhead-file /secure/letterhead.png
```

- **Format.** A JPEG or a PNG of at most 2 MiB; setup reads the file's first bytes, not its name, and refuses anything else (GIF, WebP,
  SVG, PDF, a renamed text file), a relative path or a larger file, and copies nothing. The image is scaled to the printable width of
  the A4 page (the page minus its side margins), so a wide, short banner works best: **2480 pixels wide** is the width of A4 at 300 dpi
  and is more than enough; a photograph of letterhead paper wastes the page. Save a photo-like picture as JPEG and a logo with flat
  colour as PNG to stay under 2 MiB.
- **Where it goes.** Setup copies it to `public/letterhead.jpg` or `public/letterhead.png` in the state (mode 0644) and records the name
  in `config/compose.env` as `LETTERHEAD_FILE`. Replacing the image needs no restart: the functions container reads the file when a PDF
  is made and notices a changed file.
- **Change or remove it.** Rerun `setup.sh --operator` with your usual inputs plus `--letterhead-file <new image>`, or
  `--letterhead-file off` for plain PDFs again. A rerun without the option keeps what is there. Switching between JPEG and PNG
  removes the old file.
- **Never a failed PDF.** If the file is missing, unreadable, too large or not an image, the PDF is made without it and the functions
  log one line (`letterhead: ...`). `npm run doctor` prints a warning, and the checker (`scripts/watch.mjs`) raises an alert
  "Letterhead image is missing or unusable", with the rerun command, while `LETTERHEAD_FILE` names a file that cannot be used.
- **Backups.** A backup carries the image (`letterhead.jpg` or `letterhead.png`, signed with the rest), `db:verify-restore` checks it,
  and `db:restore-host` puts it back. A backup made before this option has none and restores to plain PDFs.

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
  --alert-webhook-file /secure/second-slack-webhook.txt --letterhead-file off \
  --gateway-port 18001
```

- Setup test-binds `127.0.0.1:<port>` first and refuses a port that is in use. The port is saved as `KONG_HTTP_PORT` in
  the state's `config/compose.env`; `doctor` and the smoke scripts read it from there.
- A rerun without `--gateway-port` keeps the saved port. A rerun with another port replaces only that line, and only while
  the installation's containers are stopped (`bash stop.sh`, then setup again).
- Each tunnel's ingress must point at its own port: change the `service:` line of that facility's `cloudflared`
  configuration to `http://127.0.0.1:<port>` and restart that tunnel
  ([Cloudflare Tunnel ingress](#cloudflare-tunnel-ingress)). Setup prints this reminder when it sets a port.
- **Give every facility a state directory with a different last part** (here `second`, not `state`).
  `scripts/tunnel.sh install-service` names the tunnel's systemd unit
  `warehouse-<last part of the state path>-tunnel.service`, so two facilities whose state paths end the same would share a
  unit name, and installing the second would replace the first one's unit.
- **The automatic USB backup serves one installation per host:** `/etc/warehouse-usb-backup.conf` holds one state path, and
  `backup-usb.sh setup` for a second state refuses with "already set up". Back the second facility up with
  `npm run db:backup -- /absolute/destination` (with that facility's `WAREHOUSE_STATE_DIR`) to a drive or directory of its
  own, and keep each facility's backup key separate.
- The host's Docker daemon and its resources are shared. Never point two installations at the same state directory or port.

## Authentication and OTP limits

Login is phone OTP only, delivered through MSG91. Customers who sign up stay
pending until an administrator approves them from Enrollment Review; staff and
administrators are created by an administrator. There is no create-user
screen: the person signs in once, an administrator approves them, and then
sets their role under Settings → Users → edit. Every accepted code request
is a real SMS billed by MSG91 (there is no test or fixed-OTP mode), so budget
for it. Limits enforced by the database:

- OTPs expire after 5 minutes.
- A code is stored only as a keyed hash, HMAC-SHA256 over `phone:code:request id`
  keyed with the instance's JWT secret (the `jwt_secret` entry of
  `warehouse_security.auth_config`), never as the code itself and never as a bare
  SHA-256 of it. A signing-key rotation changes that secret
  ([Rotate signing keys](#rotate-signing-keys)), so codes issued before it stop
  verifying and the user asks for a new one.
- A resend does not void the earlier code: every delivered code stays valid
  until its own expiry, and a successful verification consumes all of them.
- Expired OTP rows are not removed on a database timer, and not when a new code is issued. The 7-day `ephemeral_auth` retention
  rule deletes expired OTP rows older than 7 days (see [Retention](#retention)). That pass runs once a day from the checker's daily run
  when the checker timer is installed; without the timer, run `npm run retention:apply` yourself. Sessions are HS256 JWTs signed with the instance's `JWT_SECRET`.

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

- The hourly open-lane counter is a **fixed window**: a window opens at the first
  request after the previous one has expired and lasts one hour, so a phone whose
  requests straddle a boundary can receive up to ten open-lane codes within sixty
  minutes. The 24 hour counts are sliding: each code stops counting 24 hours
  after it was requested. The limits are checked before the cooldown, and a
  refused request sends no SMS.
- No phone is sent more than 30 codes in any 24 hours, whoever asks. Of these,
  sources that are not trusted can cause at most 20.
- Someone who requests codes for the administrator's number uses up the open
  lane: 5 an hour, 20 in 24 hours. **While that goes on, the administrator can
  still get a code on a network they have signed in from before** (trusted
  lane, at least 10 in 24 hours that nobody else can use), **but may get none
  from a brand-new network** (a new SIM, a changed carrier address, another
  Wi-Fi) until the attack stops, the window passes, or the operator clears the
  phone's counters (next paragraph). The trusted sources of one phone share the
  reserve between them.
- Someone who guesses codes for another person's number can use up two of the
  five attempts of each code. The person who requested the code keeps at least
  three, as long as they verify from the address they requested it from. A
  phone that changes network between request and verification counts as
  another source and has the two shared attempts; requesting a new code on the
  new network gives the full five again.
- A caller who shares the user's public address (same Wi-Fi, or the same
  mobile-carrier gateway) is the same source and can use up that user's
  attempts, cooldown and trusted allowance, and a flood from many addresses can
  fill the warehouse cap. If either happens, add a Cloudflare WAF rate rule on
  `/functions/v1/operator-otp/request` and `/verify`.

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
them again re-activates a disabled profile. It does not approve a request: a pending
one answers ENROLLMENT_PENDING and a rejected one ENROLLMENT_REJECTED; an administrator's
"Review again" (`review_enrollment_again`) puts a rejected request back in Access requests.

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

(On a first installation, the command also carries `--alert-webhook-file` and `--letterhead-file`, or setup asks for both on a terminal.)

- `--central-issuer` goes with exactly one of `--central-jwks-url` and `--central-jwks-file`. The issuer and the address
  must be `https://`; the issuer is stored exactly as typed, because it is compared with the token as a string.
- **Address or file?** With the address the functions container fetches the keys over HTTPS when a sign-in needs them, and
  a key the association rotates is picked up without you; if the container cannot reach it, central sign-in answers
  "temporarily unavailable" and SMS sign-in is unaffected. With the file nothing is fetched, but when the association
  rotates its keys it sends you the new file and you rerun the command with it; until you do, central sign-in fails and
  SMS sign-in still works.
- The file is checked (a JSON key set of at most 64 KB with at least one usable P-256 public key; a file that contains a
  private key is refused) and copied to `public/central-jwks.json` in the state directory; your original is not needed
  afterwards, and a rerun with the option replaces the copy. The running service reads it when it starts a worker for a
  sign-in; `bash stop.sh && bash start.sh` makes new keys certain.
- **If the association withdraws a signing key in an emergency:** with the address the facility refuses the withdrawn key
  within 300 seconds (a fetched key set is used for at most 4 minutes). With the **file** the withdrawn key stays trusted
  until you get the new key set from the association, rerun the command with `--central-jwks-file <new file>` and the same
  `--central-issuer`, and restart as above. Do this as soon as the association tells you.
- The settings are `CENTRAL_ISSUER`, `CENTRAL_JWKS_URL` and `CENTRAL_JWKS_FILE` in `config/compose.env`; setup also
  writes the issuer to the database. A later rerun without the central options keeps everything. Changing them recreates
  the functions container during that setup run; the database container is not touched.
- Turn it off with `--central-issuer off` (and no key option). People who signed in centrally keep their profiles and
  sessions; they sign in with an SMS code from then on.
- `--central-local-code on|off` (default **off**): with `on`, this facility also sends its own SMS code and asks for it at
  **every** new central sign-in, for every approved profile. Leave it off to let the association's single sign-in open this
  facility; the price is that whoever controls the central service, or a number's SMS there, can open any person profile
  with that number here. It is refused unless central sign-in is configured. A rerun without the flag keeps the stored
  value; `--central-issuer off` clears it with the rest. It is stored as `CENTRAL_LOCAL_CODE` in `config/compose.env` and
  as the `auth_config` key `central_local_code`. A service account (a machine, migration 78) is never opened by the
  central sign-in whatever this says.
- Check: `curl -s https://<your origin>/functions/v1/get-public-config` shows
  `"centralLogin":{"issuer":"…","localCode":false}` when it is on (`localCode` is `true` with `--central-local-code on`)
  and `"centralLogin":null` when it is off or a value is unusable.

**Restores.** The trusted issuer lives in the database as well as in `compose.env`,
and setup is what makes the two agree. After an in-place restore of a database
made before you turned central sign-in on (or off), central sign-in answers
"not available" until you have run `setup.sh` again with your usual inputs.
`public/central-jwks.json` (public keys only) is copied into every backup as
`central-jwks.json`, covered by the signature, and `db:restore-host` puts it
back, mode 0644, with no setup run. A backup written before that holds no copy:
`db:restore-host` then ends by printing the exact `setup.sh --operator …
--central-issuer … --central-jwks-file …` rerun (keep the key set the
association sent you for that case). An in-place `db:restore --restore-config`
can bring back a `compose.env` that names a key file this state no longer has;
it finishes with a warning and prints the same rerun.

After any restore that brought back `central-jwks.json` (a copied key-set file
rather than `--central-jwks-url`), install the association's newest key-set
file before people sign in: rerun `setup.sh` with your usual inputs and
`--central-jwks-file <newest file>`. The restored copy is as old as the backup,
so it may still trust a key the association has since withdrawn, or lack the
key it signs with now. Ask the association for the current file and compare
the key ids with it.

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

Reference file with placeholders:
[deploy/cloudflared-config.example.yml](../deploy/cloudflared-config.example.yml).
`scripts/tunnel.sh install-service` writes the systemd unit itself; it needs
`tunnel.sh adopt` first (it stops with an error if the state holds no credential).

Install `cloudflared` from [Cloudflare's package repository](https://developers.cloudflare.com/tunnel/features/locally-managed-tunnels/create-local-tunnel/#1-download-and-install-cloudflared):

```bash
sudo install -m 0755 -d /usr/share/keyrings
curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg | sudo tee /usr/share/keyrings/cloudflare-main.gpg >/dev/null
printf 'deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared any main\n' | sudo tee /etc/apt/sources.list.d/cloudflared.list
sudo apt-get update && sudo apt-get install -y cloudflared
cloudflared --version
```

Decide the hostname and the tunnel before routing anything:

1. Use the complete API hostname (for example `warehouse-api.example.com`), the same value as `--api-url`. Check its DNS
   and confirm nothing else serves it.
2. Use a tunnel dedicated to this host: [Cloudflare sends requests to any replica of a shared tunnel](https://developers.cloudflare.com/tunnel/configuration/#replicas-and-high-availability),
   so an occupied tunnel does not isolate this installation.
3. Choose [dashboard-managed](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/get-started/create-remote-tunnel/)
   (create the tunnel and a public hostname route to `http://127.0.0.1:18000` in the dashboard, store the connector token in
   a mode-0600 file) or [locally managed](https://developers.cloudflare.com/tunnel/features/locally-managed-tunnels/create-local-tunnel/)
   (`cloudflared tunnel login` writes `cert.pem`; create a new named tunnel with its own JSON credentials; route only the
   confirmed hostname). For a locally managed tunnel, after moving `cert.pem` into a mode-0700 private directory:

   ```bash
   cloudflared tunnel --origincert /private/path/cert.pem list --output json > /private/path/tunnels-before.json   # confirm the new name is unused
   cloudflared tunnel --origincert /private/path/cert.pem create --credentials-file /private/path/new-tunnel.json NEW_TUNNEL_NAME
   cloudflared tunnel --origincert /private/path/cert.pem route dns NEW_TUNNEL_UUID warehouse-api.example.com
   ```

Run `route dns` without `--overwrite-dns`; if it reports a conflict, inspect that record instead of overwriting it. Never
reuse, delete or clean up a tunnel or connector that belongs to another machine. Keep every token, JSON credential and
account certificate mode 0600 in that private directory and out of logs and unit files.

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

To keep the credential out of backups instead, skip `adopt` and write the unit
by hand (a unit that runs as the installation user, not root (`User=` and `Group=`), with `ExecStart=/usr/bin/cloudflared --no-autoupdate --config <private config.yml> tunnel run`, or for a dashboard tunnel `ExecStart=/usr/bin/cloudflared --no-autoupdate tunnel run --token-file <private token file>`; never put `--token` on the command line; `sudo systemctl daemon-reload && sudo systemctl enable --now <unit>`); a
restore on a new host then needs your private copy or a new tunnel.

If the LAN router cannot hairpin to the public hostname, configure local DNS
for the same name; the app must always use the same HTTPS origin.

## External doctor

```bash
export WAREHOUSE_STATE_DIR=/srv/warehouse/acme
node scripts/doctor.mjs
```

The external doctor repeats the local health check, then fetches the public configuration through the canonical origin
(no redirects allowed) and verifies that the anon key, instance ID and canonical origin it returns are this installation's.
Repeat it from warehouse Wi-Fi and from cellular data. `doctor --local` covers the loopback gateway only;
`--host-preflight` and `--preflight` are the checks setup runs before touching anything.

If the external doctor reports `fetch failed` right after you routed the hostname, see
[TROUBLESHOOTING.md](TROUBLESHOOTING.md#tunnel-and-public-address).

## First-use checks

Install the companion app ([rn-warehouse-template](https://github.com/abhiguru/rn-warehouse-template)), select this
origin and confirm the company name it discovers. Then, with fictional data and owned phones:

1. Sign in as the administrator with a real SMS code.
2. Create two fictional customers (Settings → Customers) and an item with a price (Settings → Items, Item Pricing). Sign up
   a customer login from a second phone; it stays pending until you approve it from Enrollment Review, and the assignment
   list there is empty until customers exist. Approve it with an assignment to the first customer, sign in, and confirm it
   sees only that customer's records.
3. Create a staff account. There is no create-user screen: the person signs in once, you approve them, then set the role
   under Settings → Users → edit. As staff, create a goods receipt for the customer who is **not** assigned to that person
   (the app requires a photo of the GRN book entry), a partial and a final dispatch (a photo is optional and can only be
   attached while the dispatch is being created), and save the invoice: totals are computed by the server and staff see no
   price list.
4. Download the GRN, dispatch, invoice and stock PDFs as an authorized user; confirm an anonymous or foreign request is
   denied.
5. Disable a user (Settings → Users → edit → Account Status) and confirm login is refused (the code can still be requested,
   verification is rejected), then re-enable and sign in again.
6. Take a backup and verify it (below), and copy `config/backup.key` away from this machine and from the backup drive
   ([Backup key](#backup-key)).

One phone is enough to exercise every role if you sign out and in again for each, but each role needs its own number that
can receive an SMS. To reuse a number for the staff role, change that login's role only after the customer checks are
finished.

[INVOICE_RULES.md](INVOICE_RULES.md) and [STAFF_GRN_POLICY.md](STAFF_GRN_POLICY.md)
describe the expected behaviour. The fictional billing example there (subtotal
950, tax 48, total 998) holds only for its fixture dates. Record what you tested.

## Ordinary operation

Use the installed checkout, the recorded state directory and a shell with Node 22 and effective Docker access. The Compose
wrapper refuses a running project owned by another checkout.

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

`compose ps` shows every service `Up (healthy)` except `rest`, which defines no healthcheck and appears as plain `Up`; the
doctor, not the status column, is the health verdict. Start and stop the tunnel service separately through its systemd
unit. Do not run `down -v`, a broad Docker prune, or delete state as a restart procedure.

To look at the data, open a SQL prompt inside the database container:

```bash
bash scripts/compose.sh exec db psql -U supabase_admin -d postgres
```

For a session that cannot change anything, use the read-only variant:

```bash
bash scripts/compose.sh exec -e PGOPTIONS='-c default_transaction_read_only=on' db psql -U supabase_admin -d postgres
```

This signs in as the database superuser, so read first and change data only
through the app or a reviewed script. There is no web dashboard.

Every operator command (`setup.sh`, `start.sh`, `stop.sh`, `rotate-keys.sh`, `db:backup`, `db:restore`,
`backup-usb.sh run`, `test:recovery`, `retention:*`, `test:gateway-dns`, `test:pooler` (runs `pooler.sh on` itself), `test:cups`, `test:sensors`, and
`scripts/migrate.sh` when run by itself) takes an exclusive per-state lock on `config/operator.lock` before touching Docker.
A second command for the same state fails immediately with "Another operator command ... is running for this state."; wait
for the first to finish and never delete the lock file. The automatic USB backup is the one exception that waits: it
retries for up to 15 minutes, then records a failure.

## Retention

Retention is the owner-approved clean-up of expired sign-in records and generated PDFs (owner decision of 2026-10-19). With
the checker timer installed (see "Monitoring is not a Compose profile" in the installation section above), the checker's daily pass runs `scripts/retention.sh apply`
once a day, after a verified backup and after it has pruned the local backups to the newest 7. To stop it, do not install
the timer, or run `sudo bash scripts/watch-timer.sh uninstall`; nothing else deletes on a schedule. Run the retention command
yourself at any time:

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
removed by it. The daily pass also deletes local backup directories beyond the newest 7 in `<state>/backups`
([MONITORING.md](MONITORING.md#the-daily-backup-verify-prune-and-retention)); the USB backup drive is not pruned by it.

## Rotate signing keys

Rotate when the JWT secret, anon key or service key may have been exposed, when a device or backup holding them leaves
your control, or on a planned schedule:

```bash
cd /path/to/installed/backend
export WAREHOUSE_STATE_DIR=/absolute/path/to/this/warehouse
bash rotate-keys.sh --yes
```

Without `--yes` the command prints a usage message, changes nothing and exits with status 1. With `--yes` it takes the
operator lock, requires a healthy database, and then:

1. stages a copy of `config/compose.env` with a new 96-hex `JWT_SECRET` and newly signed `ANON_KEY` and
   `SERVICE_ROLE_KEY` (only those three lines change);
2. in one database transaction under advisory lock 71042: stores the new secret in `warehouse_security.auth_config`,
   deletes every refresh session and voids pending OTP challenges. The secret reaches `psql` only on standard input,
   never as an argument;
3. renames the staged file over `config/compose.env` (mode 0600);
4. recreates the running key consumers (`db kong rest storage functions`, plus `supavisor` when the pooler is on (`POOLER_ENABLED=true` and
   running) with `--force-recreate --wait`, and runs `node scripts/doctor.mjs --local`.

Consequences: every signed-in device is logged out and must complete OTP login again; any copied anon key is invalid and
`get-public-config` advertises the new one; the service key changes. A failure before step 3 leaves the file and database
untouched. If the process is interrupted between steps 2 and 3, the database already holds a secret the file does not;
rerun `bash rotate-keys.sh --yes`, which stages and applies a newer secret end to end. Take a fresh `db:backup` afterwards:
earlier backups restore the previous keys together with the previous database state, but no longer match the running
instance.

An external `doctor` run immediately afterwards can fail once while the recreated services settle behind the tunnel; rerun it
after about thirty seconds. Already-open apps are not sent to the login screen: their next requests are rejected with HTTP 401
and the client shows load errors or empty lists. Ask every user to sign out (Settings → Sign Out) and sign in again.

## Backup and restore

`npm run db:backup -- /absolute/destination` writes a private, signed
`warehouse-backup-v5` directory (default `$WAREHOUSE_STATE_DIR/backups/warehouse-<utc>`).
It stops ingress and every write-facing service for the capture and restarts
only the services that were running. The directory contains:

| File | Content |
| --- | --- |
| `database.dump` | `pg_dump --format=custom` of the `postgres` database **with owners** (needed by the in-place restore). |
| `storage.tar.gz` | The object storage directory, sorted, with fixed owner and mtime. File contents and the catalog are captured; filesystem extended attributes are not, so restored objects are served with the metadata recorded in the catalog. |
| `storage_objects.txt` | The `storage.objects` catalog as `<bucket>/<name>/<version>`, byte-ordered. |
| `integrity.txt` | Output of `scripts/backup-integrity.sql`: migration fingerprint, row counts, representative grants. From migration 48 on it also counts the three history tables (invoice discounts, zero charges, item prices) and records that the internal `invoice` columns are closed to the app role; from migration 95 on it also counts payments, order lines and order revisions. A backup taken earlier has no such lines and is still compared line for line. |
| `roles.txt` | Cluster role names, so runtime-created roles can be recreated before ownership replays. |
| `compose.env`, `instance.json` | Private configuration and public manifest at backup time. |
| `central-jwks.json` | Only when the installation reads the central sign-in keys from a file (`--central-jwks-file`): a copy of `public/central-jwks.json`, public keys only. `db:restore-host` puts it back. |
| `letterhead.jpg` or `letterhead.png` | Only when the installation has a letterhead image (`--letterhead-file`): a copy of `public/letterhead.jpg` or `.png`. `db:restore-host` puts it back; a backup without it restores to plain PDFs. |
| `metadata.txt`, `SHA256SUMS` | Format, timestamp, source commit, `database_image=` (the database image the dump was taken on; restores refuse an earlier one) and checksums of every file above. |
| `SHA256SUMS.hmac` | The signature: HMAC-SHA256 of `SHA256SUMS` under the [backup key](#backup-key). |

The backup directory is **unencrypted** and contains every credential of the instance. Keep it mode 0700/0600 on protected
storage. `db:backup` warns when the destination shares a filesystem with `data/`: a backup on the same disk does not
survive loss of that disk. Copy every retained backup to an operator-provided encrypted off-host destination
([PRODUCTION_DEPENDENCIES.md](PRODUCTION_DEPENDENCIES.md) keeps off-host custody, schedule and retention open). Never use `down -v` on a production instance. The optional CUPS and sensor bridge volumes are not in
this backup either (the bridge's volume holds only readings not yet delivered).

`npm run db:verify-restore -- /path/to/backup` checks every checksum and the signature first (see
[Backup key](#backup-key)), rejects absolute paths, `..` segments and links in the
storage archive, proves that every catalogued object is a file in the archive
(extra files are reported as a warning), restores both dumps into a disposable
`--network none` container with `--exit-on-error`, replays the archived
ACLs, and compares the integrity report and the restored object catalog with
the backup. Run it against every retained backup; it never touches the installed
instance.

Only format v5 is accepted: the verifier, `db:restore` and `db:restore-host`
refuse any other with "Refusing: backup format 'warehouse-backup-vN' is no longer supported; take a new backup with this version".
A backup whose signature is missing is refused unless you add `--allow-unsigned`,
which prints a warning and proves nothing about where the backup came from; it
is only for when the backup key is lost (see [Backup key](#backup-key)). If the
`SHA256SUMS.hmac` file is missing and the key is available, all three commands
refuse the backup even with the flag, because the signature was taken away. Use
another copy.

The disposable database is sized from the backup: the two dumps times 10, the same again (up to 1 GiB) for the write-ahead
log, plus 256 MiB, and never less than 768 MiB. It lives in memory when that much memory is available, otherwise in a
temporary directory under `$WAREHOUSE_STATE_DIR` that is removed afterwards; the command prints the size and the place it
chose, checks free space first, and when it does not fit it stops with the numbers. Override when needed:

| Variable | Meaning |
| --- | --- |
| `WAREHOUSE_VERIFY_DATA_MB` | Size of the disposable data directory in MiB. |
| `WAREHOUSE_VERIFY_SIZE_FACTOR` | Multiplier applied to the dump size (default 10). |
| `WAREHOUSE_VERIFY_STORAGE` | `auto` (default), `tmpfs` or `disk`. |
| `WAREHOUSE_VERIFY_SCRATCH_DIR` | Parent of the disk-backed directory (default `$WAREHOUSE_STATE_DIR`). |
| `WAREHOUSE_VERIFY_MEMORY_MB` | Memory limit of the container. |

A failed verification leaves the container log, its state and the database sessions in
`$WAREHOUSE_STATE_DIR/diagnostics/verify-restore-<utc>-<id>/` (`WAREHOUSE_DIAGNOSTICS_DIR` overrides the place). The log
can contain rows of the backup; keep the directory private and delete it when the problem is understood.

### Backup key

`config/backup.key` in the state directory (mode 0600) is a random 256-bit key. `setup.sh` creates it; on an installation
made before signed backups, the next `setup.sh` run or `db:backup` creates it and says so. It is used for three things:

- every backup is **signed** with it (`SHA256SUMS.hmac`). `db:verify-restore`, `db:restore` and `db:restore-host` check the
  signature before they read anything else from the backup. Plain checksums only detect damage; anyone who can write to a
  backup drive can regenerate them, and a restore replays the dump as the database superuser and adopts the backup's
  `compose.env`. The signature is what tells your backup from an edited one. For an archive, `db:restore-host` also
  requires its `.sha256` to hold exactly one record, naming that archive, with the SHA-256 of its bytes, so a checksum and
  signature copied from another archive are refused before anything is opened;
- a USB drive is **enrolled** with it ([USB backup drive](#usb-backup-drive));
- USB archives are **encrypted** with it when you switch encryption on.

The key is never written into a backup and must never be stored on the backup drive. **Keep a copy away from the server and
away from the drive**: a password manager, or a file on a different device kept somewhere else.

```bash
cat "$WAREHOUSE_STATE_DIR/config/backup.key"     # 64 hexadecimal characters; copy them exactly
```

After the host is lost, `db:restore-host` refuses a backup unless you give it the key (`--backup-key FILE`), and an
encrypted archive cannot be opened at all without it. Without the key (lost), a signed backup can only be restored with
`--allow-unsigned`, on your own judgement that the drive never left your hands; an encrypted archive is lost. Check your
copy once: put it in a file and run
`WAREHOUSE_BACKUP_KEY_FILE=/path/to/copy npm run db:verify-restore -- /path/to/backup`.

The restored installation keeps the same key. If the key itself may have been disclosed: move `config/backup.key` aside
(keep it with the old backups, which only verify with it), take a new `db:backup` (it creates a new key), store the new
copy, and enroll each USB drive again. On each drive, also move the archives written before the change
(`warehouse-<utc>.tar*` with their `.sha256` and `.hmac` files) into another folder, for example
`warehouse-backups/<state name>/old-key-<date>/`: they carry signatures of the old key, and as long as an older backup is
still under `backups/` the USB run would report its archive as "not signed with the current backup key" on every attach.
Do the same after a `db:restore-host --allow-unsigned` that was run without the key (its first backup creates a new one).

### USB backup drive

A backup on the same disk as `data/` is lost with it, which is why `db:backup` warns. The backup script copies every
backup to a **USB drive formatted exFAT**, which the operator attaches; exFAT is readable by a Linux host and by the Linux
VM of a [Windows host](#windows-host-with-linux-vm), so a restore works on either. The drive is never partitioned or
formatted, and other files on it are left alone. Backups go under `warehouse-backups/<state name>/` as one `.tar` archive
(file modes kept inside) per backup, with a `.tar.sha256` checksum and a `.tar.hmac` signature made with the
[backup key](#backup-key) (`.tar.enc` instead of `.tar` with encryption, below).

The operator's only job is to **attach the drive**. `scripts/backup-usb.sh` installs a udev rule and a systemd unit once;
after that, attaching an **enrolled** drive takes a fresh `db:backup` (write-facing services stop briefly), writes each
backup not yet on the drive, reads every new archive back from the drive and compares checksums, runs `db:verify-restore`
on the newest archive extracted from the drive, and unmounts the drive. Only an enrolled drive receives anything.
Enrolling writes a marker file, `warehouse-backups/.drive-enrolment`: a signature made with the backup key over the drive's
filesystem UUID, its partition UUID and this installation's identity, recomputed before a run takes a backup or copies a
byte. The exFAT volume serial alone does not enrol a drive (it is 32 bits and can be chosen when formatting), so a stick
that imitates it receives nothing.

1. Set it up once, as the installation user with `sudo`, with the drive attached (on VMware connect it to the VM under
   Removable Devices first). Find the partition with `lsblk -o NAME,TRAN,FSTYPE,LABEL,MOUNTPOINTS`; it must show `usb` and
   `exfat`:

   ```bash
   cd /path/to/installed/backend
   sudo bash scripts/backup-usb.sh setup --state /absolute/path/to/this/warehouse --enroll /dev/sdb1
   ```

   Run it in an interactive terminal on the host: `sudo` asks for your password, and a shell without a terminal cannot
   answer it. The copy itself always runs as the installation user, never as root. **Setup does not copy anything to a
   drive that is already attached**: unplug it and attach it again to make the first copy. The unit runs
   `scripts/backup-usb.sh` from this checkout, so do not move or delete the checkout, or switch it to a branch or release
   without that script, while USB backup is set up. Setup copies its root helper to
   `/usr/local/libexec/warehouse-usb-backup` and writes `/etc/warehouse-usb-backup.conf`, the enrolled-drive list
   `/etc/warehouse-usb-backup.drives` (root only, mode 0600), `/etc/udev/rules.d/90-warehouse-usb-backup.rules` and the
   `warehouse-usb-backup@.service` unit. Options: `--daily` for a drive that stays attached (a daily timer starts the same
   run), `--no-fresh-backup` to copy only existing backups, `--encrypt` to encrypt the archives (below). A later setup run
   that does not name one keeps what you chose; switch one back with `--no-daily`, `--fresh-backup` or `--no-encrypt`.
   Enroll a second drive for rotation with `sudo bash scripts/backup-usb.sh enroll --device /dev/sdX1`; enrolling needs the
   backup key, so take one `npm run db:backup` first on an installation that has none yet. **Run setup again after updating
   the checkout** ([Rerun and upgrade](#rerun-and-upgrade); `setup.sh` runs first) so the installed helper matches it
   (`status` warns when it does not). `sudo bash scripts/backup-usb.sh uninstall` removes everything it installed and never
   touches a drive.
2. From then on: plug the drive in and wait. The run takes a few minutes; when the drive disappears from the file manager
   (or `lsblk` shows no mount point for it), it is unmounted and safe to remove. Do not unplug during a copy; an
   interrupted archive is left as a `.partial` file that the next run removes.
3. Check the result as the installation user:

   ```bash
   bash scripts/backup-usb.sh status            # last result, enrolled drives, last success age
   journalctl -u 'warehouse-usb-backup@*' -n 50  # the run's own output
   ```

   Until the first run, `journalctl` answers "Failed to add filter for units: No data available"; that only means no run
   has happened yet. The result is also written to `warehouse-backups/<state name>/LAST-RESULT.txt` on the drive, and
   `npm run doctor` warns when the last run failed or the last successful copy is older than 7 days
   (`WAREHOUSE_USB_BACKUP_MAX_AGE_DAYS`).

Nothing is ever deleted from the drive or from `backups/`; remove old archives yourself. A run that finds an archive that no
longer matches its checksum reports it and leaves it alone. Problems: [TROUBLESHOOTING.md](TROUBLESHOOTING.md#backup-usb-drive-and-restore).

**Encryption is off unless you switch it on.** By default the archives are **not encrypted** and contain `compose.env`,
which holds every credential of the instance, the whole customer database, and, after `tunnel.sh adopt`, the tunnel
credential: whoever holds the drive could run a connector for your hostname and receive part of the phones' traffic,
sign-in codes included. Keep the drive locked away. To encrypt, first store a copy of the [backup key](#backup-key) away
from the server and the drive, then run setup again with `--encrypt`:

```bash
sudo bash scripts/backup-usb.sh setup --state "$WAREHOUSE_STATE_DIR" --encrypt
```

From the next run on, each new archive is written as `warehouse-<utc>.tar.enc` (AES-256, key derived from the backup key,
with a signed checksum next to it) and the run verifies the restore from the encrypted copy. A lost key makes the
encrypted archives unrecoverable, which is why encryption is not the default. It is covered by automated tests that
encrypt and decrypt an archive with the database replay simulated; it has not been through a lost-host drill on real
containers, so until you have done one restore from an encrypted archive yourself, keep another copy you know you can
restore. Archives already on the drive stay as they are; the run names them in a warning until you delete them. Run setup
without `--encrypt` to switch it off again.

If an unencrypted drive is ever lost, act at once: run `./rotate-keys.sh --yes`, rotate the MSG91 key, and replace the
tunnel credential (for a dashboard tunnel, refresh its token in the Cloudflare dashboard; for a locally managed tunnel,
create a new tunnel, route the hostname to it with `route dns --overwrite-dns` and delete the old one), then
`mv "$WAREHOUSE_STATE_DIR/config/tunnel" <private place>`, `tunnel.sh adopt` the new credential,
`sudo bash scripts/tunnel.sh install-service`, replace the passwords listed under
[Secrets that rotate-keys does not change](#secrets-that-rotate-keys-does-not-change), and take a new backup. A drive kept
on site is local custody only; taking it (or a second drive in rotation) to another location is what protects against
loss of the host, theft or fire.

To use an archive from the drive: on the **same** installation (its state directory intact) extract it into
`$WAREHOUSE_STATE_DIR/backups/` and follow [In-place restore of the same instance](#in-place-restore-of-the-same-instance);
after losing the host, follow [Recover a lost host from the USB drive](#recover-a-lost-host-from-the-usb-drive).

**Record a fingerprint with each backup you may need to prove later.** Right after a USB run, before anyone uses the app
again:

```bash
bash scripts/data-fingerprint.sh > ~/fingerprint-<backup name>.txt
```

It prints a row count and a SHA-256 for every business table (customers, items, prices, GRNs, dispatches, invoices, stock
movements, users, orders with their lines and revisions, and payments), for the three append-only histories (invoice
discounts, zero charges, item prices), the storage catalog and the stored files. Take both fingerprints to compare on the
same release: one from an earlier release has fewer lines, so a restore does not print `IDENTICAL` against it. A fingerprint recorded before this release sorted with the database
collation; its sha256 values can differ for identical data. Compare the `rows=` counts, and take a new fingerprint after
upgrading. It holds no secrets; keep a copy off the host (for example next to the archive on the drive). After a restore the same command must
print identical lines.

### In-place restore of the same instance

`npm run db:restore -- --yes /path/to/backup` replaces the installed database
and stored objects with a signed v5 backup **of the same instance** (older
formats are refused). For a replacement host see
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
`warehouse-backup-v5` (an older format is refused); the backup's
`instance.json` equals `public/instance.json`; the backup's `compose.env` equals
`config/compose.env`, or `--restore-config` is given and the backup names the
same project and state paths; and `db:verify-restore` passes for the backup.

It then moves `data/db` and `data/storage` to `data/db.pre-restore-<utc>` and `data/storage.pre-restore-<utc>`, recreates
both with mode 0700, extracts the storage archive, optionally replaces `config/compose.env` (keeping
`config/compose.env.pre-restore-<utc>`), starts a fresh cluster, recreates missing roles from `roles.txt` as `NOLOGIN`,
recreates the `postgres` database from `template0` (connected to `template1`) and replays its dump with `--exit-on-error` and the
archived owners and ACLs (as the verifier does), diffs `scripts/backup-integrity.sql` against the backup's `integrity.txt`,
runs `scripts/migrate.sh --operator` (a no-op unless this checkout added migrations after the backup), starts every service
with `--wait` and runs `doctor --local`. Role passwords always come from the active `compose.env`; the backup never
contains them. Pass `--restore-config` only when the keys in the backup are the ones the restored data was signed with,
that is, when `rotate-keys.sh` ran after the backup and the restored sessions must match the old keys.

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

> **Status:** CI runs a lost-host drill on real containers (fresh backup, containers
> removed, restore into a different path, identical fingerprint). Record the result of your first drill on a
> real new host.

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

   `--yes` confirms that the original host is permanently off. Before it creates
   the state the command checks, in this order: the archive, unopened, against its
   `.sha256` and its `.hmac` signature against your key (an archive without a
   `.hmac` file is not opened; copy the `.hmac` from the drive with the archive,
   and only an archive you packed yourself has none and needs `--allow-unsigned`);
   then, after unpacking into a temporary folder next to the new state (an
   encrypted `.tar.enc` is decrypted with the same key; the folder is removed
   again if anything fails), the backup inside: its signature, its contents
   (only the backup folder, no links, exactly the signed files) and its own
   checksums; that this checkout contains every migration the backup applied
   (otherwise it names the `source_commit` to check out); that no container and
   no database of this installation exists on the host; the host prerequisites; and 10 GiB of free space.
   A backup that fails the signature check was changed after it was written or
   belongs to another installation: do not restore it. A backup of an older
   format than v5 is refused. A v5 backup whose `SHA256SUMS.hmac` is missing is
   accepted only with `--allow-unsigned` and without `--backup-key`, for a drive
   that never left your custody; leave `--backup-key` out only when the key is
   really lost. The command then creates the state from the backup's `compose.env`
   and `instance.json`, changing only the three state-path lines (and installs
   `public/central-jwks.json` when the backup carries one), keeps a copy of the
   backup under `backups/`, and runs the in-place restore: a new database from
   the pinned image, replay of both databases and the stored files, integrity
   comparison, newer migrations, all services started and `doctor --local`. It
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

   A fingerprint recorded by an earlier release has fewer lines (see above), so
   compare the other lines and record a new one after upgrading.

   A fingerprint recorded before this release sorted with the database collation; its sha256 values can differ for
   identical data. Compare the `rows=` counts, and take a new fingerprint after upgrading.

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
   in `config/compose.env` ([Central sign-in](#central-sign-in)). A recent backup
   brought `public/central-jwks.json` back, and `node scripts/doctor.mjs --local`
   confirms it. For an older one, run the `setup.sh --operator ... --central-issuer ...
   --central-jwks-file ...` command that `db:restore-host` printed, with your usual
   administrator phone and name and the key set the association sent you. Setup
   keeps the instance identity and the data and rebuilds the images once. Until
   then every central sign-in fails while the app still offers it, and `doctor`
   says so; SMS sign-in is unaffected.
8. **Protect the new host.** Set up the [USB backup drive](#usb-backup-drive)
   again (`sudo bash scripts/backup-usb.sh setup …`, then re-plug the drive) and
   check that a new backup appears next to the old ones.

   Install the monitoring checker again too, with the command `db:restore-host` printed
   (`sudo bash scripts/watch-timer.sh install --state <state>`). The Slack webhook URL is a
   secret and is not in a backup: if this installation sent alerts to Slack,
   alerts are local only until you run `setup.sh --operator` again with your
   usual inputs, leaving out `--alert-webhook-file off` (it then asks for the URL on a terminal), or with `--alert-webhook-file` ([MONITORING.md](MONITORING.md#alert-delivery)).
9. **Rotate if the drive may have been exposed.** Unencrypted archives hold every
   key in plain text. `bash rotate-keys.sh --yes` replaces the signing keys (every phone
   signs in again). Rotate the MSG91 key in its console and apply it as in
   [Replacing MSG91 credentials](#authentication-and-otp-limits), replace
   the tunnel credential (see [USB backup drive](#usb-backup-drive)) and the
   passwords under
   [Secrets that rotate-keys does not change](#secrets-that-rotate-keys-does-not-change),
   then take a new backup.
### Secrets that rotate-keys does not change

`rotate-keys.sh` replaces the JWT secret and the two API keys derived from it. `compose.env`, and so every unencrypted
backup, holds more. After a backup medium was exposed, these stay valid until you change them by hand. Except
`SENSOR_INGEST_KEY`, which posts sensor readings through the tunnel and so must be replaced at once, none of them is usable
from the internet through the tunnel: they matter to someone who also reaches the host or its network.

| Secret | What it opens | How to replace it |
| --- | --- | --- |
| `CUPS_ADMIN_PASSWORD` | The CUPS administration page (printing profile). | Manual, below. |
| The Slack webhook URL (`config/slack-webhook-url`) | Posting messages to the facility's Slack channel, by anyone who holds the URL. | Revoke it in Slack (Apps → Incoming Webhooks) and create a new one, then rerun `setup.sh --operator` with your usual inputs and `--alert-webhook-file ask` (or a file holding the new URL; create it with `install -m 600 /dev/null FILE` and an editor, so the URL stays out of the shell history). |
| `TAPO_PASSWORD` (with `TAPO_USERNAME`) | The Tapo account of the hubs: the hubs on the LAN, and the account in the Tapo app and cloud (sensors profile). | Change it in the Tapo app, set the new value in `compose.env`, then `bash scripts/compose.sh --profile sensors up -d --force-recreate sensor-bridge`. |
| `SENSOR_INGEST_KEY` | Posting sensor readings to this installation's ingest function, from anywhere the gateway is reachable (sensors profile). | Mint a new key with a new label (`bash scripts/compose.sh exec -T db psql -X -qAt -v ON_ERROR_STOP=1 -U supabase_admin -d postgres -v label=<new label> < scripts/sensor-ingest-key.sql`, which prints it once), set it, recreate the bridge, then revoke the old one (`bash scripts/compose.sh exec -T db psql -X -q -v ON_ERROR_STOP=1 -U supabase_admin -d postgres -c "UPDATE warehouse_security.sensor_ingest_keys SET revoked_at = now() WHERE label = '<old label>' AND revoked_at IS NULL"`); [SENSORS.md](SENSORS.md#ingest-keys). |
| `POSTGRES_PASSWORD` | The superuser login (`supabase_admin`), from inside the Compose network or the host. | `npm run db:rotate-passwords -- --yes --superuser`; see [Rotating the database passwords](#rotating-the-database-passwords). |
| `DB_PASSWORD_AUTHENTICATOR`, `DB_PASSWORD_STORAGE` (every install), `DB_PASSWORD_POOLER` (only after `pooler.sh on`) | Each one database login of one service (PostgREST, Storage, the pooler's pool user), from inside the Compose network. | `npm run db:rotate-passwords -- --yes`; see [Rotating the database passwords](#rotating-the-database-passwords). |
| `SECRET_KEY_BASE`, `VAULT_ENC_KEY` (only after `pooler.sh on`) | Pooler session signing; encryption of the pooler's stored tenant credentials. | No supported procedure yet; see below. |

These procedures are **not exercised by CI**. Take a `db:backup` first and check with `node scripts/doctor.mjs --local`
afterwards. The command for `CUPS_ADMIN_PASSWORD` (the rows above say how to set the others):

```bash
cd /path/to/installed/backend
export WAREHOUSE_STATE_DIR=/absolute/path/to/this/warehouse
npm run db:backup
new="$(openssl rand -hex 32)"
# Replace one line of the private configuration, keeping its mode (only where printing is used):
sed -i "s/^CUPS_ADMIN_PASSWORD=.*/CUPS_ADMIN_PASSWORD=$new/" "$WAREHOUSE_STATE_DIR/config/compose.env"
bash scripts/compose.sh --profile printing up -d --force-recreate cups
node scripts/doctor.mjs --local
```

`SECRET_KEY_BASE` (present only once the pooler has been turned on) signs the pooler's sessions and `VAULT_ENC_KEY` encrypts the pooler's stored tenant (which holds the pool
user's password). Changing them is not scripted and has not been rehearsed, so this guide gives no procedure that could
leave the pooler unable to read its tenant. They cannot be used from outside the host and its Docker network (the database
publishes no port and the gateway listens on loopback only); keep the host's logins and network closed. If you must replace
them now, rehearse on a copy first: restore the newest backup onto a spare machine with `db:restore-host`, try the change
there, and only then repeat it on the real host.

### Rotating the database passwords

Every database login has its own password in `compose.env`
([CONTAINER_SECURITY.md](CONTAINER_SECURITY.md#database-passwords-one-per-login)):
`POSTGRES_PASSWORD` is the superuser's (`supabase_admin`), and
PostgREST, Storage and the pooler's pool user (when it is on)
each sign in with their own. One command
replaces them:

```bash
cd /path/to/installed/backend
export WAREHOUSE_STATE_DIR=/absolute/path/to/this/warehouse
npm run db:backup
npm run db:rotate-passwords -- --yes                # every service login
npm run db:rotate-passwords -- --yes --superuser    # also POSTGRES_PASSWORD
npm run test:db-roles                               # each login refuses the superuser password and takes its own
npm run db:backup                                   # older backups carry the previous values
```

What it does, in this order:

1. Writes new values into `config/compose.env.rotating-db` (only those lines
   differ from `compose.env`).
2. Sets them in the database in one transaction, signed in with the current
   superuser password. It sends SCRAM verifiers on standard input, never the
   passwords, so nothing reaches a log, an argument list or
   `pg_stat_statements`.
3. Keeps the previous file as `config/compose.env.before-db-rotation`, puts
   the new one in place, and recreates the database and every running service
   that signs in to it (PostgREST, Storage, and the pooler when it runs). The
   command takes about a minute, with about 11 seconds in which the app cannot
   load data. A service you stopped on purpose stays stopped and reads its new
   value when it next starts. No session ends and no phone signs in again: the
   JWT signing keys are `rotate-keys.sh`'s.
4. Proves each login (`npm run test:db-roles`) and runs `node scripts/doctor.mjs --local`.
   If a service does not come back or a login misbehaves, it sets the previous
   values in the database again, moves the previous file back, recreates the
   services and exits with an error: nothing is rotated.

If the command stops half-way (a power cut, a killed shell, a full disk), it
leaves `compose.env.rotating-db`, `compose.env.before-db-rotation` or both
behind. Do not move or delete them yourself: run
`npm run db:rotate-passwords -- --yes` again. It does not rotate then; it finds
out which values the database has by signing in over the network with each
file's values, keeps the file that matches as `compose.env`, removes the others
and says so. Then do what its last line says: run `bash start.sh` so every
service uses these values, check with `npm run test:db-roles`, and rotate again
if you still want new ones. If the database is not running, start it alone
first (`bash scripts/compose.sh up -d --wait db`). If the database takes the
values of none of the files, or gives no clear answer, the command changes
nothing and says so; keep every file and ask for help, quoting the message.

A restore of a backup taken before a rotation brings that backup's values
back together with its data (`db:restore -- --restore-config`, or
`db:restore-host`); the restored database gets them at start.

## Pooler (optional)

The pooler (supavisor) is off by default; a new installation has no pgbouncer role, schema or `get_auth`, no `_supabase` database and no
`DB_PASSWORD_POOLER`, `SECRET_KEY_BASE` or `VAULT_ENC_KEY` (`compose.env` has `POOLER_ENABLED=false`). It needs a running, healthy
database and takes the operator lock.

```bash
bash scripts/pooler.sh on       # generates the three secrets where missing, creates role pgbouncer, schema pgbouncer (get_auth) and
                                # database _supabase (scripts/configure-pooler.sql), records POOLER_ENABLED=true, starts supavisor
                                # with --profile pooler up -d --no-deps (db is not recreated); idempotent
bash scripts/pooler.sh off      # stops and removes the container, records POOLER_ENABLED=false; deletes nothing (role, schema,
                                # database and secrets stay, the pgbouncer password is not rotated while off; `on` reuses them)
bash scripts/pooler.sh status   # prints on, off or unset
```

**One-time clean-up on upgrade.** `setup.sh` runs `bash scripts/pooler.sh cleanup` (after migrations, before the roles are applied) for an
installation whose `compose.env` has no `POOLER_ENABLED` line. If a supavisor container exists, it records `on`. Otherwise, if `_supabase`
holds no relation and no schema besides `_supavisor` and `public`, it drops the schema `pgbouncer`, the role `pgbouncer` and the database
`_supabase`, removes the three secrets from `compose.env`, records `off` and prints what it removed. If `_supabase` holds relations or other
schemas it prints `Pooler clean-up refused ...`, changes nothing and exits 1; `setup.sh` warns and goes on, and asks again at the next setup.

After an in-place or lost-host restore the pooler is not started (the restore starts the core services only); while `POOLER_ENABLED=true`
the restore recreates its role, schema and `_supabase` database, and `bash scripts/pooler.sh on` starts it again. Backups made before
2026-10-21 also hold `_supabase.dump`; restore and verify-restore skip it with a note. Test: `npm run test:pooler`.

## Rerun and upgrade

A rerun is the same `setup.sh --operator ...` command with the same inputs against the same state directory. It
regenerates nothing that already exists: identity, signing keys, database, stored files, the administrator and the provider
lines are preserved (a different `--provider-env` file replaces only the MSG91 lines; the `--central-…` options set or
replace only the [central sign-in](#central-sign-in) lines and its key file; `--gateway-port` replaces only
`KONG_HTTP_PORT`, and only while the containers are stopped). A rerun also adds what an older state lacks and never replaces
what exists: the per-role database passwords and the backup key. Run it a second time right after installation and compare
`public/instance.json` and the administrator record before and after.

To upgrade to a newer `main` within one PostgreSQL major (an installation built before the PostgreSQL 17 release needs the
[Baseline reload](#baseline-reload) once; one that runs PostgreSQL 17 needs the [Major PostgreSQL upgrade](#major-postgresql-upgrade) once):

```bash
cd /path/to/installed/backend
export WAREHOUSE_STATE_DIR=/absolute/path/to/this/warehouse
npm run db:backup                      # prints the backup directory
npm run db:verify-restore -- "$WAREHOUSE_STATE_DIR/backups/warehouse-<utc>"
(umask 022; git pull --ff-only)
bash setup.sh --operator ...           # the same inputs as the installation
bash scripts/compose.sh up -d --force-recreate functions   # needed when the pull changed anything under functions/
node scripts/doctor.mjs --local && node scripts/doctor.mjs
sudo bash scripts/backup-usb.sh setup --state "$WAREHOUSE_STATE_DIR"   # only if you use a USB backup drive
```

The last line keeps the USB choices of your earlier setup (`--encrypt`, `--daily`, `--no-fresh-backup`); it prints them, so
check that line. The `--force-recreate functions` line is needed because the edge functions (`functions/`, including
`functions/_shared/`) are bind-mounted into the `functions` container and the edge runtime keeps the modules it has loaded:
a setup rerun neither rebuilds an image for them nor recreates the container. Database migrations need no such step: setup
applies them. If setup prints a `sudo bash scripts/watch-timer.sh install …` command, run it.

**What the slimming release (migration 123) asks of you.**

- The `db`, `storage` and `pdf-renderer` recipes changed, so setup rebuilds those three images; the first run is slower.
- Setup (and a restore) rewrites an old default `PGRST_DB_SCHEMAS` (`public,storage` or `public,storage,graphql_public`) in
  `compose.env` to `public` and recreates `rest`; a list you edited yourself is left alone. `/rest/v1/` then serves no OpenAPI
  document and cannot reach the `storage` schema.
- `get-public-config` can answer 503 between the code update (`git pull`) and migration 123, because the function it calls
  (`get_public_config`) does not exist yet. Run `setup.sh` at once after the pull; do not leave the new code on the old schema.
- Migration 123 refuses to run if a table or column it drops holds data. It stops with `Migration 123 would drop data: ...` and
  changes nothing. Look at what it names, export what you need, empty those objects, and run `setup.sh` again. A database that
  never held such data passes without a message.

**Setup rebuilds the images whose recipes changed.** Before it starts
anything, `setup.sh` runs `scripts/build-images.sh`. That script compares each
image recipe (the files under its `docker/` build directory, its Dockerfile
path, build target and build arguments) with a record of what it built last
(`config/image-recipes.sha256` in the state directory) and rebuilds the images
whose recipe differs or whose tag no longer names the image it built. Setup's
start then replaces only the containers whose image changed. What to expect:

- A state with no record (a new one, or one made by `restore-host`) rebuilds
  every image in use once. That needs the network and can take a good while on
  a small machine; later reruns print "Images match their recipes; nothing to
  rebuild." and need no network.
- A build needs the network when a recipe changed. If it fails, setup stops
  before it starts or stops anything and records nothing as built. Running
  services stay as they are. Run setup again when the network is back rather
  than leaving the installation half way.
- **Setup tries the address once and warns.** With `--central-jwks-url`, setup fetches it from this host (10 seconds, no
  redirect) after it has written the state. If that fails (no connection, an error status, an answer that is not JSON or has
  no `keys` list) it prints "Warning: could not fetch the central keys from ... (reason)" and carries on, because a host may
  be set up before it is online. A pass proves only that **this host** can reach the address, not that the `functions`
  container can; a wrong or unreachable address still shows at the first sign-in as "temporarily unavailable". Test it from
  this host first: `curl -fsS https://login.association.example/.well-known/jwks.json`. A host resolver that cached an
  NXDOMAIN answer fails here too ([TROUBLESHOOTING.md](TROUBLESHOOTING.md#tunnel-and-public-address)).
- **The app must be built for central sign-in too.** The backend setting alone leaves the app on its single "warehouse
  server" screen: build the app with `EXPO_PUBLIC_CENTRAL_ORIGIN=https://login.association.example` (the app repository's
  `.env.example`). The value is inlined when the app is bundled, so restart Metro with `--clear` after changing it.
- **The central service has its own Cloudflare Tunnel and hostname**, separate from this facility's; see the OPERATOR.md of
  the central identity repository ([CENTRAL_LOGIN.md](CENTRAL_LOGIN.md#built-and-not-built)).
- The pooler's objects follow `POOLER_ENABLED` (see [Pooler (optional)](#pooler-optional)).
- Optional services (`printing`, `pooler`, `sensors`) are rebuilt only if
  this installation has a container of them, and setup replaces the running
  ones whose image or configuration changed. A failure there is printed as a
  warning; the core services stay up. A running optional service whose image
  does not match this checkout is left running with the warning "the
  <service> image does not match this checkout"; `bash scripts/build-images.sh`
  or the next setup rerun builds it, and the following start replaces it.
- `start.sh` never builds: a host that restarts offline starts what it has.
- Every built image is tagged for its installation (`<project>-<service>`).

The build cache also keeps the operating-system packages of the day an image
was first built. Now and then, rebuild without it:
`bash scripts/build-images.sh --no-cache`, then `bash start.sh`.
`bash scripts/build-images.sh --all` rebuilds everything in use with the cache.

Update the checkout under `umask 022`, as for the first clone. Git writes the
files it changes with the current umask: Ubuntu's default `0002` makes them
group-writable, which the root-run backup helpers refuse, and `077` makes them
unreadable by the containers. `setup.sh` restores the modes of every tracked
file on each run, and `bash scripts/checkout-permissions.sh` does the same on
its own, for example after a `git pull` or `git checkout` made without
`umask 022`.

**Migration 42 and tables of your own.** Migration 42 closes direct writes on the template's nineteen business tables and
verifies only those; a table you added, with its grants and row policies, is left as it is. The migration stops with
`authenticated still holds a direct write on: <table>` or
`Unexpected write policy on a business table: <table>.<policy>` only when one of the nineteen tables carries an extra write
policy; drop that policy or make it `FOR SELECT`, then rerun.

The rerun applies only the migrations the ledger has not seen (append-only and
checksum-verified; a changed applied file is refused) and recreates the
services whose definition changed. Read `CHANGELOG.md` for the release first:
a release that changes the mobile contract needs the matching app build. If
the upgraded instance is rejected, stop it and restore the pre-upgrade backup
with the in-place restore above.

## Baseline reload

The release that introduced PostgreSQL 17 (the official `postgres:17.11-trixie` image) made the schema one migration,
`migrations/00000000000000_baseline.sql`, in place of the chain of migrations 000 to 110 (110 files; there is no 050). A
database built before this release (the Supabase PostgreSQL 15 image and that chain) **cannot be upgraded in place**:
PostgreSQL 15 data files do not open in 17, the roles differ, and the ledger names files that no longer exist. Do not run
`setup.sh` or `start.sh` of a later release on such an installation: both stop before they rebuild or start anything
(`scripts/db-version-preflight.sh`; `setup.sh` checks before it rewrites `compose.env`), and no database, container or image is changed:

```
Refusing: <the running database reports server_version_num 150008 (PostgreSQL 15). | the data directory <path> holds a PostgreSQL 15 database (PG_VERSION).> This release runs PostgreSQL 18 and cannot start on that data. No database, container or image was changed. Back the installation up with the release tagged migrations-pre-baseline, then reload the data into a new PostgreSQL 18 database: docs/OPERATOR_INSTALL.md, "Baseline reload".
```

(The reload below was written for the PostgreSQL 17 release; the new database it builds is the one of the release you check out in step 5, and the restore of a pre-baseline backup works the same.)

`scripts/migrate.sh` run on its own against such a database stops at the ledger guard, with nothing changed:

```
This database recorded migrations that are not in this release (...). Either it was built by an earlier migration chain and cannot be migrated in place (reload it: docs/OPERATOR_INSTALL.md, "Baseline reload"), or it is newer than this checkout (check out the release that recorded those migrations).
```

The way forward is a reload: a data-only dump goes into a new cluster that this release builds. A new installation needs
none of this. The services are down from step 4 to step 8, so plan a window. The old data directory is only moved, and the
old database image is kept under a second tag, so the way back (step 9) stays open. The old migration files are in the git
tag `migrations-pre-baseline`, the last release with the chain (`git show migrations-pre-baseline:migrations/<file>`).

The dump holds every secret of the installation (configuration, sessions, one-time-code hashes). Keep it in a mode 0700
directory and treat it like a backup. Use one shell for all steps; start with these helpers:

```bash
cd /path/to/installed/backend
export WAREHOUSE_STATE_DIR=/absolute/path/to/this/warehouse
B="$WAREHOUSE_STATE_DIR/backups/baseline-reload-$(date -u +%Y%m%dT%H%M%SZ)"; (umask 077; mkdir -p "$B")
dbsql() { bash scripts/compose.sh exec -T db psql -X -q -U supabase_admin -d postgres -v ON_ERROR_STOP=1 "$@"; }
cat > "$B/record.sql" <<'SQL'
SELECT line FROM (
  SELECT 'rows ' || table_schema || '.' || table_name || ' ' || (xpath('/row/c/text()', query_to_xml(format('SELECT count(*) AS c FROM %I.%I', table_schema, table_name), false, true, '')))[1]::text AS line
    FROM information_schema.tables WHERE table_type = 'BASE TABLE' AND table_schema || '.' || table_name <> 'storage.migrations'
     AND table_schema IN ('public', 'storage', 'utils', 'warehouse_maintenance', 'warehouse_security')
  UNION ALL
  SELECT 'sequence ' || schemaname || '.' || sequencename || ' ' || coalesce(last_value::text, 'unused') FROM pg_sequences
   WHERE schemaname IN ('public', 'storage', 'utils', 'warehouse_maintenance', 'warehouse_security')
  UNION ALL
  SELECT 'trigger ' || n.nspname || '.' || c.relname || ' ' || t.tgname || ' ' || t.tgenabled::text
    FROM pg_trigger t JOIN pg_class c ON c.oid = t.tgrelid JOIN pg_namespace n ON n.oid = c.relnamespace
   WHERE NOT t.tgisinternal AND n.nspname IN ('public', 'storage', 'utils', 'warehouse_maintenance', 'warehouse_security')
  UNION ALL
  SELECT 'storage_migrations ' || count(*) FROM storage.migrations
) s ORDER BY line COLLATE "C";
SQL
record() { dbsql -At < "$B/record.sql"; }
```

`record` prints the row count of every table, the sequence positions, which triggers are enabled and the number of
Storage migrations. It is taken before and after, and the two outputs must be equal.

**Step 1. Bring the installation to the last old release.** Check out `migrations-pre-baseline` first, then deploy it
the normal way (backup, then `setup.sh`), so the database has the whole old chain. The backup comes after the checkout on
purpose: the backup script of this release refuses a PostgreSQL 15 server, the one of the tag does not. Make sure the
network is up: step 5 builds an image while the facility is down.

```bash
git fetch --tags origin
(umask 022; git checkout --detach migrations-pre-baseline); bash scripts/checkout-permissions.sh
npm run db:backup
bash setup.sh --operator ...        # the same inputs as the installation; write them down, step 8 needs them again
git ls-tree --name-only migrations-pre-baseline migrations/ | grep '\.sql$' | while read -r f; do printf '%s|%s\n' "${f#migrations/}" "$(git show "migrations-pre-baseline:$f" | sha256sum | cut -d' ' -f1)"; done | LC_ALL=C sort > "$B/ledger-tag.txt"
dbsql -At -c 'SELECT name, checksum FROM warehouse_migrations.applied ORDER BY name COLLATE "C"' > "$B/ledger-db.txt"; diff "$B/ledger-tag.txt" "$B/ledger-db.txt" && echo 'ledger equals the tag'
```

Run any `sudo` command that `setup.sh` prints at its end (the checker timer: `watch-timer.sh install`; the USB backup:
`backup-usb.sh setup`). The ledger has 110 lines (000 to 110; there is no 050). Mute the checker for the window (`node scripts/watch.mjs mute 240`);
unmute it after step 8.

**Step 2. Take the lock, a verified backup, the fingerprints and the record, with the writers stopped.** Hold the operator
lock in this shell until step 8 (`backup.sh`, `build-images.sh` and `migrate.sh` accept the inherited lock). Database and
Storage keep running (the file fingerprint reads the files through the Storage container). The old images are tagged so that
a rollback uses them instead of building them again:

```bash
exec 9>"$WAREHOUSE_STATE_DIR/config/operator.lock"; flock -n 9 && echo 'operator lock held'    # stop if this prints nothing
npm run db:backup -- "$B/backup"
bash scripts/compose.sh --profile '*' ps --status running --services > "$B/running-services.txt"
cp -p "$WAREHOUSE_STATE_DIR/config/compose.env" "$B/compose.env"   # the old configuration, put back by the rollback (step 9)
P=$(sed -n 's/^WAREHOUSE_PROJECT_NAME=//p' "$WAREHOUSE_STATE_DIR/config/compose.env"); : > "$B/old-images.txt"
while read -r s; do c=$(bash scripts/compose.sh --profile '*' ps -q "$s"); i=$(docker inspect --format '{{.Config.Image}}' "$c")
  case "$i" in "$P-"*@*|"") continue;; "$P-"*) docker tag "$(docker inspect --format '{{.Image}}' "$c")" "$P-$s:pre-baseline" && echo "$s" >> "$B/old-images.txt";; esac
done < "$B/running-services.txt"
grep -qx db "$B/old-images.txt" && cp -p "$WAREHOUSE_STATE_DIR/config/image-recipes.sha256" "$B/" && echo 'old images kept'
(cd "$B/backup" && sha256sum -c --quiet SHA256SUMS) && npm run db:verify-restore -- "$B/backup"   # must pass before anything is stopped
dbsql -At -c "SELECT n.nspname || '.' || c.relname || ' ' || (xpath('/row/c/text()', query_to_xml(format('SELECT count(*) AS c FROM %I.%I', n.nspname, c.relname), false, true, '')))[1]::text FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE c.relkind IN ('r','p') AND n.nspname IN ('cron','net','graphql','graphql_public','vault','supabase_functions','realtime','_realtime','warehouse_migrations','auth') AND n.nspname || '.' || c.relname NOT IN ('auth.schema_migrations','warehouse_migrations.applied')" | awk '$2 != 0'   # must print nothing
bash scripts/compose.sh --profile '*' stop kong functions rest pdf-renderer supavisor cups sensor-bridge
bash scripts/data-fingerprint.sh > "$B/fingerprint-before.txt"
bash scripts/data-fingerprint.sh --all > "$B/fingerprint-all-before.txt"
record > "$B/record-before.txt"
```

"old images kept" must print: it means the image of `db` was found. Any line of the schema check is a stop: those rows would
not be carried over. Do not run `docker image prune` or `docker builder prune` until the reload is accepted.

**Step 3. Dump the data only, with the old image's own `pg_dump`.** Stop Storage first:

```bash
bash scripts/compose.sh stop storage
(umask 077; bash scripts/compose.sh exec -T db pg_dump -U supabase_admin -d postgres \
  --data-only --format=custom --compress=6 \
  --exclude-schema=cron --exclude-schema=net --exclude-schema=graphql --exclude-schema=graphql_public \
  --exclude-schema=vault --exclude-schema=supabase_functions --exclude-schema=realtime --exclude-schema=_realtime \
  --exclude-schema=warehouse_migrations --exclude-schema=auth --exclude-table=storage.migrations \
  > "$B/data-only.dump")
record > "$B/record-after-dump.txt"; diff "$B/record-before.txt" "$B/record-after-dump.txt" && echo 'nothing wrote during the dump'
```

If the two records differ, something wrote during the dump: start again at step 2. Do not add `--load-via-partition-root`:
a partition that the baseline lacks must make the load fail, not re-route rows. The dump keeps the sequence positions
(`SEQUENCE SET` entries). The schemas left out belong to the old image's extensions and services (the baseline has none of
them), `warehouse_migrations` is the ledger (the baseline run writes it), and `auth` holds GoTrue tables that nothing uses.
The `_supabase` database (the pooler's tenant) is no longer in backups at all; while `POOLER_ENABLED=true`, setup recreates it with the pooler's role and schema.

**Step 4. Move the old data directory aside. Never delete it.**

```bash
bash scripts/compose.sh --profile '*' down --remove-orphans
D="$WAREHOUSE_STATE_DIR/data/db"; test ! -e "$D.pre-baseline" && mv -T "$D" "$D.pre-baseline" && mkdir -m 700 "$D"
```

The files in `data/storage` stay where they are; the reload does not touch them.

If you copy files into `data/storage` by hand (for example to bring over the photos of another server), make the folders
mode 755 and the files mode 644, whatever the source had. Files that keep a source mode such as 700, or that belong to
root, make `db:backup` fail with `tar: ./stub/stub/<bucket>: Cannot open: Permission denied`.

**Step 5. Check out this release, build the new database, apply the baseline, let Storage migrate.**

```bash
git checkout --detach <this release>        # the tag or commit you are installing
bash scripts/checkout-permissions.sh
bash scripts/build-images.sh                 # builds the new db image; needs the network (if the build fails, go to step 9)
bash scripts/compose.sh up -d --wait --wait-timeout 180 db
bash scripts/migrate.sh --operator --through 00000000000000_baseline.sql   # applies the baseline only; the ledger gets one row
bash scripts/compose.sh up -d --no-deps --wait --wait-timeout 180 storage
dbsql -At -c "SELECT count(*) FROM storage.migrations"   # must equal the storage_migrations line of record-before.txt
bash scripts/compose.sh stop storage
```

`--through` stops the migration run after the named file. Without it `migrate.sh` applies every file of the directory, and
the files after the baseline (111 onward) must not run yet: migration 123 drops tables and columns that the old data fills,
so the dump of step 6 would no longer load, and its guard (which refuses to drop objects that hold rows) would only look at
the new, empty database. Step 8 applies 111 onward on the loaded data. An unknown name is refused before the database is touched.

The first start of the empty data directory runs only `docker/volumes/db/00-bootstrap.sql` and `roles.sql` (no `_supabase.sql`, no `pooler.sql`, no pgbouncer role; [roles](CONTAINER_SECURITY.md#database-roles)). Storage builds its own tables in the schema `storage`. It is
stopped again so that nothing writes during the load.

**Step 6. Empty the tables the dump fills, then load.** The baseline seeded rows that the dump holds too, and
`storage.buckets` and `storage.objects` must equal the old catalog. A check constraint added `NOT VALID` because old rows
break it (the two blank-number checks on `dispatch` and `goodsreceived`) is still enforced while rows load, so it is
taken off for the load and put back with the same definition, still `NOT VALID`:

```bash
bash scripts/compose.sh cp "$B/data-only.dump" db:/tmp/data-only.dump
tables=$(bash scripts/compose.sh exec -T db pg_restore -l /tmp/data-only.dump | awk '$4=="TABLE" && $5=="DATA" {print $6"."$7}' | paste -sd, -)
{ echo 'SET session_replication_role = replica;'; echo "TRUNCATE $tables;"; } | dbsql   # one statement for all tables; never CASCADE; replica: the history tables' TRUNCATE guards do not fire
dbsql -At -c "SELECT format('ALTER TABLE %s ADD CONSTRAINT %I %s;', conrelid::regclass, conname, pg_get_constraintdef(oid)) FROM pg_constraint WHERE contype = 'c' AND NOT convalidated" > "$B/add-not-valid.sql"
dbsql -At -c "SELECT format('ALTER TABLE %s DROP CONSTRAINT %I;', conrelid::regclass, conname) FROM pg_constraint WHERE contype = 'c' AND NOT convalidated" | dbsql
bash scripts/compose.sh exec -T db pg_restore -U supabase_admin -d postgres \
  --data-only --single-transaction --disable-triggers --exit-on-error --no-owner --no-acl /tmp/data-only.dump
dbsql < "$B/add-not-valid.sql"
bash scripts/compose.sh exec -T db rm /tmp/data-only.dump
```

`session_replication_role = replica` keeps the TRUNCATE guards of the history tables (and the trigger that records a
price-table truncate) from firing. `--single-transaction` means that a failed load leaves the new database empty. To retry,
first run `dbsql < "$B/add-not-valid.sql"` (the checks are off after a failed load), then repeat this step; do not regenerate
`add-not-valid.sql` while the checks are off. `--disable-triggers` switches off the foreign-key triggers and the
application triggers (audit, stock movement, number generation, direct-write guard) for the load, which is wanted: the rows
are already consistent.

**Step 7. Check the result.** The load did not check foreign keys, so check them (empty output means pass; any line is an
orphan count other than 0), then compare the record and the fingerprints with the ones from step 2:

```bash
cat > "$B/fk-check.sql" <<'SQL'
SELECT c.conrelid::regclass AS child, c.conname,
       (xpath('/row/n/text()', query_to_xml(format(
         'SELECT count(*) AS n FROM %s ch WHERE %s AND NOT EXISTS (SELECT 1 FROM %s pa WHERE %s)',
         c.conrelid::regclass, j.nonnull, c.confrelid::regclass, j.joined), false, true, '')))[1]::text::int AS orphans
FROM pg_constraint c
CROSS JOIN LATERAL (
  SELECT string_agg(format('ch.%I IS NOT NULL', ca.attname), ' AND ' ORDER BY k.ord) AS nonnull,
         string_agg(format('pa.%I = ch.%I', fa.attname, ca.attname), ' AND ' ORDER BY k.ord) AS joined
  FROM unnest(c.conkey, c.confkey) WITH ORDINALITY AS k(ck, fk, ord)
  JOIN pg_attribute ca ON ca.attrelid = c.conrelid AND ca.attnum = k.ck
  JOIN pg_attribute fa ON fa.attrelid = c.confrelid AND fa.attnum = k.fk) j
WHERE c.contype = 'f' AND c.conparentid = 0
ORDER BY 1, 2;
SQL
dbsql -At < "$B/fk-check.sql" | awk -F'|' '$3 != 0'     # empty output = pass
dbsql -c ANALYZE                                   # a new cluster has no statistics
record > "$B/record-after.txt"; diff "$B/record-before.txt" "$B/record-after.txt" && echo 'rows, sequences, triggers equal'
bash scripts/compose.sh up -d --no-deps --wait --wait-timeout 180 storage
bash scripts/data-fingerprint.sh > "$B/fingerprint-after.txt"; diff "$B/fingerprint-before.txt" "$B/fingerprint-after.txt" && echo IDENTICAL
bash scripts/data-fingerprint.sh --all > "$B/fingerprint-all-after.txt"; diff "$B/fingerprint-all-before.txt" "$B/fingerprint-all-after.txt" && echo IDENTICAL
```

Any orphan, any `diff` output or a missing `IDENTICAL` is a stop: go to step 9. The fingerprints also cover the storage
catalog and the stored files.

**Step 8. Run setup.** With the arguments written down in step 1. It runs the migrations after the baseline (111 onward) on
the data you loaded. Migration 123 refuses to drop a table or column that holds rows: if the old database used any of them,
setup stops with `Migration 123 would drop data: ...` and nothing of 123 is applied (the database stays at the migrations before it). Check
that the named data is not needed, export it if it is, empty those objects (`dbsql -c 'TRUNCATE <table>'`, or set the named
column to NULL), and run the same setup command again. If you cannot decide, go to step 9: the old database is untouched. It is idempotent, sets the role passwords and the
configuration, and starts the core services. Release the lock first (setup takes it again), then start the optional
services that ran before. The pooler exists only while it is turned on, and the new cluster has no `_supabase` database, so setup
keeps the pooler secrets and records it off (it prints the path of a saved copy of `compose.env`). If `supavisor` was in
`running-services.txt`, turn the pooler on with `pooler.sh on` instead of starting it with `up`:

```bash
exec 9>&-
bash setup.sh --operator ...
bash scripts/compose.sh --profile '*' up -d --wait --wait-timeout 180 $(grep -vx supavisor "$B/running-services.txt")   # the optional services that ran before
if grep -qx supavisor "$B/running-services.txt"; then bash scripts/pooler.sh on; fi   # role, schema, _supabase and the supavisor service
node scripts/doctor.mjs --local && node scripts/doctor.mjs
npm run db:backup                                  # the first backup of the new database
node scripts/watch.mjs unmute
```

Run any `sudo` command that `setup.sh` printed (`watch-timer.sh install`, `backup-usb.sh setup`). Sign in from a phone with
one role before the window ends. Keep `data/db.pre-baseline` for at least a day of use. Remove it
(with `sudo rm -rf` on that exact path, the files belong to the container's user) only after `npm run db:verify-restore`
passed on the first new backup, and delete `$B/data-only.dump` once the reload is accepted. At the same time remove what the earlier release left and
this one does not use: `docker network rm "${P}_admin"` and `docker volume rm "${P}_db-config" "${P}_prometheus_data"`
(`P` is `WAREHOUSE_PROJECT_NAME` from `compose.env`, as in step 2; a name that does not exist is not an error to worry about).

**Step 9. Rollback** (any failure before the new database is accepted). The old directory was only moved and the old
database image is still tagged `<project>-db:pre-baseline` (step 2). Do not run `docker image prune` before the reload is
accepted. Files uploaded or deleted after step 8 are not rolled back:

```bash
exec 9>&-
bash scripts/data-fingerprint.sh | diff "$B/fingerprint-after.txt" - || echo 'the new database changed after step 7: those writes are lost by the rollback'   # only if step 7 got that far
bash stop.sh
D="$WAREHOUSE_STATE_DIR/data/db"; test ! -e "$D.failed" && mv -T "$D" "$D.failed" && mv -T "$D.pre-baseline" "$D"
(umask 022; git checkout --detach migrations-pre-baseline); bash scripts/checkout-permissions.sh
P=$(sed -n 's/^WAREHOUSE_PROJECT_NAME=//p' "$WAREHOUSE_STATE_DIR/config/compose.env")
while read -r s; do docker tag "$P-$s:pre-baseline" "$P-$s"; done < "$B/old-images.txt"
cp -p "$B/image-recipes.sha256" "$WAREHOUSE_STATE_DIR/config/image-recipes.sha256"
cp -p "$B/compose.env" "$WAREHOUSE_STATE_DIR/config/compose.env"   # the configuration from step 2: the old release needs DB_PASSWORD_POOLER, which the new setup may have removed
bash scripts/compose.sh up -d --no-build --wait --wait-timeout 180 db storage
bash scripts/data-fingerprint.sh | diff "$B/fingerprint-before.txt" - && echo IDENTICAL   # before any writer starts; a difference: stop here
bash start.sh
bash scripts/compose.sh --profile '*' up -d --no-build --wait --wait-timeout 180 $(cat "$B/running-services.txt")
```

Stored files were never changed by the reload. Anything written to the new database after the load is lost by a rollback.
The old data directory still has its `pgbouncer` role. If you roll back with the new database kept (`data/db` not moved back), or run an
older release's `setup.sh` against a database where the pooler objects were removed, create the role first, because the older
`setup.sh` runs `ALTER ROLE pgbouncer`: `bash scripts/compose.sh exec -T db psql -X -U supabase_admin -d postgres -c 'CREATE ROLE pgbouncer LOGIN'`
(skip it if `\du pgbouncer` shows the role).

### Restoring a pre-baseline backup

A backup made before this release (format `warehouse-backup-v5`, taken on the Supabase image) holds the old schema,
roles and ledger. `db:restore`, `db:restore-host` and `db:verify-restore` refuse it before the backup's own signature check and
before anything of the installation is changed:

```
Refusing: the backup was made on the database image 'supabase/postgres...', which this version no longer runs. Restore it with the release tagged migrations-pre-baseline, then reload the data into this version (docs/OPERATOR_INSTALL.md, "Baseline reload").
```

A backup with no `database_image=` line is refused the same way, with the message `Refusing: the backup records no database_image= line in metadata.txt, so it was made before the move to PostgreSQL 17. Restore it with the release tagged migrations-pre-baseline, then reload the data into this version (docs/OPERATOR_INSTALL.md, "Baseline reload").` A backup whose `roles.txt` lists `postgres`, `supabase_auth_admin` or `dashboard_user` is refused with `Refusing: the backup lists the role '<role>', which this version does not have: it was dumped from the earlier image, whatever its database_image= line says. Restore it with the release tagged migrations-pre-baseline, then reload the data into this version (docs/OPERATOR_INSTALL.md, "Baseline reload").`, and `db:verify-restore` refuses a dump written by a server below PostgreSQL 17. `db:backup` itself refuses to back up a server that is not this release's (`Refusing: the running database reports ...`): such an installation has not been moved yet.

Restore an old backup only with the release tagged `migrations-pre-baseline`, then follow the reload above from step 2.
On an installation that already runs this release, bring the old database image back first: after
`(umask 022; git checkout --detach migrations-pre-baseline)`, run `docker tag <project>-db:pre-baseline <project>-db` if you
kept it, else `bash scripts/build-images.sh` (needs the network); then `npm run db:restore -- --yes <backup>`; then the
reload from step 2, after moving any `data/db.pre-baseline` left by an earlier reload out of the way. Backups made by this
release restore with this release.

## Major PostgreSQL upgrade

This section moves an installation from PostgreSQL 17 to 18. This release runs the official PostgreSQL 18 image (`postgres:18.6-trixie`, pinned in `docker/postgres/Dockerfile`; `scripts/db-image.sh`
prints the pin and is the one source every script reads). The schema is the same baseline plus the migrations after it. PostgreSQL 17
data files do not open in 18, so an installation that runs PostgreSQL 17 **cannot be upgraded in place**: `setup.sh` and `start.sh` of this
release stop before they build or recreate anything (`scripts/db-version-preflight.sh`), and `db:backup` refuses the running 17 server:

```
Refusing: the data directory <path> holds a PostgreSQL 17 database (PG_VERSION). This release runs PostgreSQL 18 and cannot start on PostgreSQL 17 data. No database, container or image was changed. The data moves with a major upgrade: back up with the checkout that runs PostgreSQL 17, then restore on this one (docs/OPERATOR_INSTALL.md, "Major PostgreSQL upgrade").
```

The way forward is the ordinary backup and in-place restore ([In-place restore of the same instance](#in-place-restore-of-the-same-instance)),
taken across the two releases: a backup made by the PostgreSQL 17 checkout restores on this one (the restore builds a new 18 cluster and
replays the logical dump; a backup from a newer major than the checkout runs is refused, so the other way round does not work). The
services are down from step 4 until step 7 ends, so plan a window. The old data directory is only moved and the old images are kept under a
second tag, so the way back (step 9) stays open. The data directory inside the container stays `/var/lib/postgresql/data` (the stack sets
`PGDATA` to it); the official 18 image's own default is elsewhere, so nothing else needs changing on the host.

Data checksums: a new PostgreSQL 18 cluster has data checksums on by default, and an upgraded facility gets them through the restore (the restore creates a
new cluster). No action is needed.

Use one shell for all steps. Start with these helpers and the disk check: the new
cluster, the backup and the kept 17 directory exist side by side, so check the free space first.

```bash
cd /path/to/installed/backend
export WAREHOUSE_STATE_DIR=/absolute/path/to/this/warehouse
B="$WAREHOUSE_STATE_DIR/backups/pg18-upgrade-$(date -u +%Y%m%dT%H%M%SZ)"; (umask 077; mkdir -p "$B")
df -h "$WAREHOUSE_STATE_DIR" /var/lib/docker       # free space must be at least 3 times the size of data/db plus the new images (about 1 GiB)
du -sh "$WAREHOUSE_STATE_DIR/data/db" "$WAREHOUSE_STATE_DIR/data/storage"
```

The lock is held by this shell on descriptor 9 from step 1 until the start of step 4. Run `bash scripts/backup.sh` directly, never
`npm run db:backup`, in that stretch: npm does not pass descriptor 9 on, so the backup could not take the lock. `stop.sh` and `restore.sh` take the
lock themselves, so the lock is released before them (step 4 and step 6). `verify-restore.sh` takes no lock.

**Step 1. Take the operator lock, record the old commit and stop every writer.** Stop what writes from outside the stack: a sensor bridge on
another host, a script that posts readings or uploads. Mute the checker for the window (`node scripts/watch.mjs mute 240`). Then stop the
stack's own writers; the database and Storage stay up for the backup and the fingerprints. With the writers already stopped, `backup.sh`
finds nothing to pause and restarts nothing but Storage (which it stops for the capture itself), so no write can sneak in between the backup and the restore.
Steps 1 to 3 run on the OLD checkout, so a `backup.sh` older than this release brings Storage back with `compose up` without `--no-deps`, and that also starts `rest`
again (Storage depends on it). Step 2 therefore stops `rest` again right after the backup. From this release on, `backup.sh` restarts with `--no-deps` and does not do this.

```bash
exec 9>"$WAREHOUSE_STATE_DIR/config/operator.lock"; flock -n 9 && echo 'operator lock held'    # stop if this prints nothing
git rev-parse HEAD > "$B/old-commit.txt"; cat "$B/old-commit.txt"
bash scripts/compose.sh --profile '*' ps --status running --services > "$B/running-services.txt"
bash scripts/compose.sh --profile '*' stop kong functions rest pdf-renderer supavisor cups sensor-bridge
bash scripts/compose.sh --profile '*' ps --status running --services     # only db and storage may remain
```

**Step 2. With the OLD checkout (still PostgreSQL 17), take a verified backup and record the data.** Right after the backup, the configuration directory is copied whole
for the rollback (`config/` holds `compose.env`, the backup key and the other private files; the copy is as private as the backup). It sits before the checks so that
a failing check cannot skip it, and `mkdir` (without `-p`) refuses a rerun instead of nesting a second copy inside the first. The row counts come from the query file `$B/counts.sql`,
written here and run again unchanged in step 8, because the old checkout has no `data-fingerprint.sh --counts` (that mode exists from this release on and
runs the same query, for later moves).

```bash
bash scripts/db-image.sh                         # must print postgres:17.…: this is still the old checkout
bash scripts/backup.sh "$B/backup"
bash scripts/compose.sh stop rest                # a backup.sh older than this release starts rest again with Storage; stop it (a no-op when it is already stopped)
mkdir "$B/config" && cp -a "$WAREHOUSE_STATE_DIR/config/." "$B/config/"   # compose.env, backup.key, image-recipes.sha256 and the rest, for the rollback
(cd "$B/backup" && sha256sum -c --quiet SHA256SUMS) && npm run db:verify-restore -- "$B/backup"   # must pass
bash scripts/data-fingerprint.sh > "$B/fingerprint-before.txt"
bash scripts/data-fingerprint.sh --all > "$B/fingerprint-all-before.txt"
cat > "$B/counts.sql" <<'SQL'
SELECT n.nspname || '.' || c.relname || ' ' || (xpath('/row/c/text()', query_to_xml(format('SELECT count(*) AS c FROM %I.%I', n.nspname, c.relname), false, true, '')))[1]::text FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE c.relkind IN ('r','p') AND n.nspname IN ('public','storage','warehouse_security','warehouse_maintenance') ORDER BY (n.nspname || '.' || c.relname) COLLATE "C"
SQL
bash scripts/compose.sh exec -T db psql -X -At -v ON_ERROR_STOP=1 -U supabase_admin -d postgres < "$B/counts.sql" > "$B/counts-before.txt"
```

**Step 3. Tag the current images** (of stopped containers too: `ps -a`, because step 1 stopped most of them) so that a rollback uses them instead of building them again (the db image is the one that matters):

```bash
P=$(sed -n 's/^WAREHOUSE_PROJECT_NAME=//p' "$WAREHOUSE_STATE_DIR/config/compose.env"); : > "$B/old-images.txt"
while read -r s; do c=$(bash scripts/compose.sh --profile '*' ps -a -q "$s" | head -n 1); [ -n "$c" ] || continue; i=$(docker inspect --format '{{.Config.Image}}' "$c")
  case "$i" in "$P-"*@*|"") continue;; "$P-"*) docker tag "$(docker inspect --format '{{.Image}}' "$c")" "$P-$s:pre-pg18" && echo "$s" >> "$B/old-images.txt";; esac
done < "$B/running-services.txt"
grep -qx db "$B/old-images.txt" && echo 'old images kept'
```

"old images kept" must print. Do not run `docker image prune` or `docker builder prune` until the upgrade is accepted.

**Step 4. Stop the stack with the old checkout, check out the new release and build the images.** Release the lock first (`stop.sh` takes it
itself). The facility is down from here. The build needs the network; if it fails, nothing has been moved yet: use rollback A.

```bash
exec 9>&-
bash stop.sh                                     # the old checkout stops the old containers
git fetch --tags origin
git checkout --detach <this release>             # the tag or commit you are installing
bash scripts/checkout-permissions.sh
bash scripts/db-image.sh                         # must print postgres:18.…
bash scripts/build-images.sh                     # takes the lock itself; builds the images whose recipe changed, the db image among them
```

**Step 5. Rehearse the restore.** The rehearsal restores the backup into a disposable PostgreSQL 18 container and compares the integrity report
and the object catalog; it touches nothing of the installation and takes no lock. It refuses a backup made by a newer major than 18.

```bash
npm run db:verify-restore -- "$B/backup"      # must pass
```

**Step 6. Restore.** `db:restore` takes the lock itself and needs the stack down (step 4). It moves `data/db` to `data/db.pre-restore-<utc>` and
`data/storage` to `data/storage.pre-restore-<utc>`, creates a new PostgreSQL 18 cluster from the db image of this checkout (it rebuilds a stale db image
first and refuses, before moving anything, if it cannot), replays the dump, analyzes every database (`vacuumdb --all --analyze-in-stages`: a dump made by
`pg_dump` 18 does not carry planner statistics, so without this the restored tables stay unanalyzed until autovacuum reaches them; the disposable rehearsal of
step 5 does not need it, because it only compares the integrity report and the catalog), runs `migrate.sh --operator`, starts the services and runs `doctor --local`:

```bash
npm run db:restore -- --yes "$B/backup"
```

**Step 7. Run setup.** With the arguments of the installation (the same `setup.sh --operator ...` command as the last rerun). It is idempotent,
sets the role passwords and the configuration, starts the core services, and now reports the running server's version. The restored cluster has no
`_supabase` database, so setup keeps the pooler secrets and records the pooler off. If `supavisor` was in `running-services.txt`, `pooler.sh on`
recreates its role, schema, database and service. Then start the other optional services that ran before:

```bash
bash setup.sh --operator ...
bash scripts/compose.sh --profile '*' up -d --wait --wait-timeout 180 $(grep -vx supavisor "$B/running-services.txt")
if grep -qx supavisor "$B/running-services.txt"; then bash scripts/pooler.sh on; fi
```

**Step 8. Check the result.** Every line must pass; the first failure is a stop, go to step 9.

```bash
bash scripts/compose.sh exec -T db psql -X -At -U supabase_admin -d postgres -c 'SELECT version()'          # PostgreSQL 18.6
bash scripts/compose.sh exec -T db cat /var/lib/postgresql/data/PG_VERSION                          # 18 (read inside the container, no sudo)
bash scripts/data-fingerprint.sh | diff "$B/fingerprint-before.txt" - && echo IDENTICAL
bash scripts/data-fingerprint.sh --all | diff "$B/fingerprint-all-before.txt" - && echo IDENTICAL   # run on a quiet system (the file says which tables move on their own)
bash scripts/compose.sh exec -T db psql -X -At -v ON_ERROR_STOP=1 -U supabase_admin -d postgres < "$B/counts.sql" | diff "$B/counts-before.txt" - && echo 'counts equal'
ORIGIN=$(sed -n 's/.*"canonicalOrigin": *"\([^"]*\)".*/\1/p' "$WAREHOUSE_STATE_DIR/public/instance.json")
curl -s -o /dev/null -w '%{url_effective} %{http_code}\n' "$ORIGIN/functions/v1/get-public-config"     # prints the URL it hit, then 200
bash scripts/compose.sh ps                                  # every service Up (healthy); rest has no healthcheck and shows plain Up
node scripts/doctor.mjs --local && node scripts/doctor.mjs
npm run test:gateway
bash scripts/compose.sh exec -T db psql -X -q -U supabase_admin -d postgres -c "NOTIFY pgrst, 'reload schema'"
npm run db:backup                                           # the first backup of the new database
npm run db:verify-restore -- "$(ls -dt "$WAREHOUSE_STATE_DIR"/backups/warehouse-* | head -n 1)"     # adjust the path if backups are written elsewhere
node scripts/watch.mjs unmute
bash scripts/compose.sh exec -T db psql -X -At -U supabase_admin -d postgres -c 'SELECT max(measured_at) FROM sensor_readings'   # newest sensor reading: run it again a minute later; a later value shows the sensor bridge writes again
```

Run any `sudo` command that `setup.sh` printed. Sign in from a phone with one role before the window ends. Restart what you stopped outside the
stack in step 1. Keep `data/db.pre-restore-<utc>` and `data/storage.pre-restore-<utc>` for at least a day of use, then remove the two exact
paths with `sudo rm -rf` (the files belong to the containers' users) only after the first new backup passed `db:verify-restore`.
Remove the `pre-pg18` image tags (`docker image rm "$P-<service>:pre-pg18"`) at the same time.

**Step 9. Rollback** (any failure before the new database is accepted). Do not run `docker image prune` before the upgrade is accepted. Writes made after
step 6 are lost by a rollback. First find out whether `restore.sh` moved the data:

```bash
D="$WAREHOUSE_STATE_DIR/data"; ls -d "$D"/db.pre-restore-* 2>/dev/null || echo 'data not moved'
```

**Rollback A, data not moved** (the build, the rehearsal or `db:restore` failed or refused before moving anything; no `db.pre-restore-*` directory).
`data/db` is the live PostgreSQL 17 directory and is not touched. Go back to the old commit and the old images:

```bash
exec 9>&-
git checkout --detach "$(cat "$B/old-commit.txt")"; bash scripts/checkout-permissions.sh
P=$(sed -n 's/^WAREHOUSE_PROJECT_NAME=//p' "$WAREHOUSE_STATE_DIR/config/compose.env")
while read -r s; do docker tag "$P-$s:pre-pg18" "$P-$s"; done < "$B/old-images.txt"
cp -p "$B/config/image-recipes.sha256" "$WAREHOUSE_STATE_DIR/config/image-recipes.sha256"
cp -p "$B/config/compose.env" "$WAREHOUSE_STATE_DIR/config/compose.env"   # the saved configuration (the pooler secrets setup may have removed)
bash start.sh
bash scripts/data-fingerprint.sh | diff "$B/fingerprint-before.txt" - && echo IDENTICAL
bash scripts/compose.sh --profile '*' up -d --no-build --wait --wait-timeout 180 $(cat "$B/running-services.txt")
```

If setup of this release already ran, the pooler role `pgbouncer` was dropped when the pooler was off. Before running the old release's
`setup.sh`, create it: `bash scripts/compose.sh exec -T db psql -X -U supabase_admin -d postgres -c 'CREATE ROLE pgbouncer LOGIN'` (skip it if the role exists).

**Rollback B, data moved by `restore.sh`** (a `db.pre-restore-<utc>` and a `storage.pre-restore-<utc>` directory exist). Every command after the
guard sits inside it: nothing is moved or changed unless both kept directories are there. If `Stop:` is printed, run nothing more and investigate.

```bash
exec 9>&-
bash stop.sh
U=$(ls "$D" | sed -n 's/^db\.pre-restore-//p' | sort | tail -n 1); echo "kept: $U"
if test -n "$U" && test -d "$D/db.pre-restore-$U" && test -d "$D/storage.pre-restore-$U" && test ! -e "$D/db.failed" && test ! -e "$D/storage.failed" \
   && mv -T "$D/db" "$D/db.failed" && mv -T "$D/db.pre-restore-$U" "$D/db" \
   && mv -T "$D/storage" "$D/storage.failed" && mv -T "$D/storage.pre-restore-$U" "$D/storage"; then
  git checkout --detach "$(cat "$B/old-commit.txt")"; bash scripts/checkout-permissions.sh
  cp -a "$B/config/." "$WAREHOUSE_STATE_DIR/config/"       # the configuration as it was before step 4 (undoes setup.sh and --restore-config; puts the pooler secrets back)
  P=$(sed -n 's/^WAREHOUSE_PROJECT_NAME=//p' "$WAREHOUSE_STATE_DIR/config/compose.env")
  while read -r s; do docker tag "$P-$s:pre-pg18" "$P-$s"; done < "$B/old-images.txt"
  bash start.sh
  bash scripts/data-fingerprint.sh | diff "$B/fingerprint-before.txt" - && echo IDENTICAL
  bash scripts/compose.sh --profile '*' up -d --no-build --wait --wait-timeout 180 $(cat "$B/running-services.txt")
else
  echo 'Stop: the kept directories are missing, db.failed already exists, or a move failed; check the directories by hand.'
fi
```

The kept database is the old one and has its `pgbouncer` role. If you instead keep a database where this release's `setup.sh` or `pooler.sh off`
removed the pooler objects, create the role before an older release's `setup.sh` (it runs `ALTER ROLE pgbouncer`):
`bash scripts/compose.sh exec -T db psql -X -U supabase_admin -d postgres -c 'CREATE ROLE pgbouncer LOGIN'`.

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
