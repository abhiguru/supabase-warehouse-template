# Independent warehouse installation

Use a fresh Linux x86-64 host or Linux VM for each warehouse instance. Each
instance owns its database, document storage, credentials and canonical HTTPS
origin. The installer writes private state outside the Git checkout. The
[operator acceptance ledger](PRODUCTION_DEPENDENCIES.md#independent-operator-installation-work)
records which integrations and physical tests remain open.
Read [OPERATOR_SETUP_NOTES.md](OPERATOR_SETUP_NOTES.md) before provisioning for
the pilot's observed failures, remedies, configuration traps and detailed
remaining edge-case acceptance matrix.

This is the pilot installation path. A successful setup does not enable the
unfinished printer/sensor integrations or complete replacement-host recovery.
Backend PR #68 is merged; mobile PR #33 remains a draft. Use the exact source
pair below. Historical pilot results do not validate this fresh installation.

## Select the reviewed repository version

Backend [PR #68](https://github.com/abhiguru/supabase-warehouse-template/pull/68)
merged on 2026-09-29 at `f18f51d4625e7f8c0d977ac69645804e318a9d49`.
[Post-merge CI 36591024357](https://github.com/abhiguru/supabase-warehouse-template/actions/runs/36591024357)
passed all seven jobs. Verify availability and pin both repositories before setup:

```bash
git ls-remote https://github.com/abhiguru/supabase-warehouse-template.git HEAD refs/heads/main
git ls-remote https://github.com/abhiguru/rn-warehouse-template.git refs/heads/codex/operator-mobile refs/pull/33/head
(umask 022; git clone https://github.com/abhiguru/supabase-warehouse-template.git backend)
(umask 022; git clone https://github.com/abhiguru/rn-warehouse-template.git mobile)
git -C backend switch --detach f18f51d4625e7f8c0d977ac69645804e318a9d49
git -C mobile switch --detach 8240cce9121a797fd0cf2e00e568a61985814ddb
git -C backend rev-parse HEAD
git -C mobile rev-parse HEAD
git -C backend status --porcelain
git -C mobile status --porcelain
```

Public source must be readable by container service users: clone in a subshell
with `umask 022` as above. Keep `umask 077` for private state, provider files and
raw evidence. Do not use a recursive permission change on the whole workspace:
that could expose private configuration. A fresh-VM clone under 077 produced
mode-0600 initialization SQL; PostgreSQL failed with `Permission denied`,
restarted and became healthy despite incomplete initialization. Healthy process
status alone was misleading. Inspect initialization failures before rerunning;
retain and stop an incomplete owned attempt and use a separate empty state for
an independently diagnosed reinstall. Never delete another instance or copy its
state. Record the failed attempt and new instance identity.

Require clean source status and record both full commits. Mobile `main` does not
contain this draft candidate. If either checkout fails, stop and explain the
missing baseline before selecting a substitute. Keep the installed checkout
pinned and make corrections in a separate review branch/worktree. The current
release gate still blocks publishing an operator release. See the
[backend acceptance record](BACKEND_CORE_ACCEPTANCE.md) for test-only setup and
remaining release gates. Instance configuration belongs outside the checkout;
no source edits should be necessary for the documented installation.

## Linux host preparation

Before starting, the developer must give the AI installation agent noninteractive
`sudo` access on this isolated VM. Configure the agent's installation account in
`sudoers` with `sudo visudo`, then verify from the agent's session that
`sudo -n true` succeeds. A later matching group rule can override an earlier
user rule, so check the effective result rather than relying on the file's
appearance. Remove the installation grant after the handoff if it is no longer
needed; never give the agent the sudo password in chat.

Install Node.js 22.18 or newer, npm, Git, OpenSSL, util-linux (`flock`), Docker
Engine and Compose v2.
After an operator-approved VM resource change, recheck effective CPUs, RAM,
disk, sudo/Docker access and pinned Node in the new session. Compare saved private
configuration/identity fingerprints without printing values; then run the installed
instance's local/public doctor before resuming optional fixtures. Resource changes
do not authorize replacing state, credentials, DNS or another connector. See
OPERATOR_SETUP_NOTES.md for the scoped eight-CPU/KVM post-reboot results.

Choose a persistent filesystem with at least 10 GiB free for this initial
installation check, plus capacity for the operator's actual data. Maintain that
minimum at every setup/doctor invocation, including when adding SDKs, AVD images
or compiling Android. Finish disposable backend checks before heavy native
builds on a constrained host, and record free space again. If space falls below
the guard, stop and reclaim only your own completed generated compiler outputs
after verifying their exact APKs are retained elsewhere; preserve warehouse
state, logs, artifacts and signing files. Never weaken the guard or globally
prune Docker to make installation pass. Start Docker
at boot with `sudo systemctl enable --now docker`. The installer checks its
availability and Linux x86-64 architecture before creating state.

### Ubuntu 24.04 x86-64 prerequisite sequence

Record the host before changing it: `cat /etc/os-release`, `uname -m`, `id`,
`sudo -n true`, `command -v node npm git docker`, `node --version`,
`npm --version`, `git --version`, `free -h`, `df -h`, `ss -lntup`, and
`stat -c '%a %U:%G %n' "$HOME"`. If Docker exists, also record `docker version`,
`docker compose version`, and `docker ps`. Inspect existing paths and projects;
never delete them to resolve a collision. Keep raw output in a mode-0700 evidence
directory outside Git, creating evidence files under `umask 077`.

The fresh-VM run found Ubuntu's Node 18 inadequate. This installs a user-owned
Node 22 binary without replacing the OS package. Start with these packages:

```bash
sudo -n apt-get update
sudo -n apt-get install -y ca-certificates curl git openssl util-linux xz-utils dnsutils
mkdir -p "$HOME/.local/opt" "$HOME/.cache/warehouse-node-download"
cd "$HOME/.cache/warehouse-node-download"
curl -fSLO https://nodejs.org/dist/v22.23.3/node-v22.23.3-linux-x64.tar.xz
curl -fSLO https://nodejs.org/dist/v22.23.3/SHASUMS256.txt
rg ' node-v22.23.3-linux-x64.tar.xz$' SHASUMS256.txt | sha256sum -c -
tar -xJf node-v22.23.3-linux-x64.tar.xz -C "$HOME/.local/opt"
export PATH="$HOME/.local/opt/node-v22.23.3-linux-x64/bin:$PATH"
node --version
npm --version
```

If `rg` is unavailable, use `grep` for the checksum selection above. Checksum
comparison uses Node's published HTTPS checksum file; this is not a claim that
a release signature was verified. Repeat the PATH export in every installation,
health-check and build shell; a change in a different terminal does not update
the agent or a system service. Avoid overwriting an existing version directory.

Install Docker using its [official Ubuntu repository procedure](https://docs.docker.com/engine/install/ubuntu/).
Inspect conflicting packages first; do not remove an existing container runtime
without assessing the services it owns. On this fresh host none were present:

```bash
sudo -n install -m 0755 -d /etc/apt/keyrings
sudo -n curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
sudo -n chmod a+r /etc/apt/keyrings/docker.asc
printf 'Types: deb\nURIs: https://download.docker.com/linux/ubuntu\nSuites: noble\nComponents: stable\nArchitectures: amd64\nSigned-By: /etc/apt/keyrings/docker.asc\n' | sudo -n tee /etc/apt/sources.list.d/docker.sources
sudo -n apt-get update
apt-cache madison docker-compose-plugin
sudo -n apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin=2.40.3-1~ubuntu.24.04~noble
sudo -n systemctl enable --now docker
sudo -n usermod -aG docker "$(id -un)"
```

The unversioned Compose package installed v5.5.1 on 2026-09-30; the guide calls
for v2. This sequence explicitly selects available v2.40.3. If another Compose
version is already installed, inspect its use before changing it. Do not call
Compose v5 tested by these instructions. Open a new login session, or use
`sg docker` to open a shell with effective Docker-group access. In that shell,
repeat the Node PATH export and verify:

```bash
id
docker version
docker compose version
docker buildx version
docker info --format '{{.ServerVersion}}'
docker ps --format '{{.Names}} {{.Status}} {{.Ports}}'
```

Do not run warehouse setup as root or make the Docker socket world-writable.
Record actual package versions with `dpkg-query -W`; repository package versions
can change. This run installed Engine 29.8.1, containerd 2.3.6, Buildx 0.37.1,
Node 22.23.3 and npm 10.9.9. These prerequisite checks alone do not establish
service or business acceptance.

Choose an empty state path outside the checkout, such as
`/srv/warehouse/acme`. Its existing parent must be owned by the installation
user. Keep the provider file elsewhere outside the checkout, mode 0600.

For example, prepare the state directory as the non-root installation user:

```bash
sudo install -d -m 0700 -o "$(id -un)" -g "$(id -gn)" /srv/warehouse/acme
```

Write the following settings to the private provider file, then set its mode to
0600 before setup. Use unquoted, nonempty `KEY=value` entries without whitespace,
quotes, backticks, backslashes, `$` or `#` in values. Keep the values out of shell
history and version control:

```dotenv
SMS_PROVIDER=msg91
MSG91_AUTH_KEY=replace-with-owned-key
MSG91_TEMPLATE_ID=replace-with-approved-flow-template-id
MSG91_PE_ID=replace-with-owned-entity-id
MSG91_SENDER_ID=replace-with-owned-sender-id
```

This provider input accepts only those five keys. Do not copy a complete legacy
`.env` into it: `SMS_PRODUCTION_MODE` is set to `true` by the installer and is not
an accepted input-file key. The separate DLT Template ID is not an input-file key
either. The database synchronizer validates a 24-character lowercase hex Flow
ID, a numeric PE ID and six uppercase alphanumeric sender characters.

`MSG91_TEMPLATE_ID` holds the MSG91 **Flow ID**, not the separate DLT Template
ID. Do not copy another warehouse's provider identifiers or credentials. Obtain a
Flow, entity and sender owned and approved for this test instance from the
operator's protected provider file. The historical pilot's Flow and DLT values
remain dated evidence in [OPERATOR_SETUP_NOTES.md](OPERATOR_SETUP_NOTES.md), not
fresh-install defaults. The Flow variable is exactly `OTP`, including capitalization. The operator OTP
worker sends this variable through MSG91's Flow endpoint and reads the active
provider settings from the latest protected `public.sms_config` row. It accepts
the request only after MSG91 confirms success. [MSG91's Send SMS
documentation](https://docs.msg91.com/sms/send-sms) notes that an accepted API
response does not confirm delivery to the handset; test receipt with an owned
phone.

The installer copies the private generated `config/compose.env` values into
that protected row after migrations, including on setup reruns. The provider
file seeds a new instance; changing it later does not rotate a running
instance. For an authorized credential rotation, update this instance's
mode-0600 `config/compose.env`, rerun the same setup command to synchronize the
database, and verify a real OTP. Keep both private files outside Git and
include them in the encrypted off-host backup. Never commit either file.

For an AI-led installation, ask the operator for missing setup inputs **one at a
time**, only when the next step needs them. After host preflight, request the
**complete API hostname** (for example, `pilot-api.example.com`), not merely
the parent domain, and wait for the answer. If Cloudflare Tunnel is used,
check whether the selected hostname and tunnel are already in use, then request
each missing tunnel input separately when configuring that route. Next request
the warehouse company name, the `91`-prefixed administrator phone, the
administrator display name, and the path to the existing mode-0600 MSG91
provider file, waiting for each answer before asking the next question. Do not
combine these into one questionnaire. Ask the operator to create the provider
file in a VM terminal if it is missing; never ask for its credential values in
chat. Continue independent checks while waiting for an answer.

If the operator supplies ten Indian digits, prepend `91` once before invoking
setup; the CLI requires the final 12-digit number. A required missing input stops
its dependent stage. State the blocker and next action, respect an operator's
request to stop, and do not repeat a deferred OTP test. Ask whether the operator
is ready at the phone and hidden-input VM terminal before sending a five-minute
code. Record each attempt separately; stale helper results are not a new pass.

Run this from a reviewed backend checkout, replacing the example domain and
administrator details with the warehouse's values:

```bash
export WAREHOUSE_STATE_DIR=/srv/warehouse/acme
export COMPOSE_PARALLEL_LIMIT=1 # Limit simultaneous startup on small VMs.
export WAREHOUSE_ADMIN_PHONE=91XXXXXXXXXX
bash setup.sh --operator \
  --state-dir "$WAREHOUSE_STATE_DIR" \
  --api-url https://warehouse.example.com \
  --company 'Example Cold Storage' \
  --provider-env /secure/warehouse-msg91.env \
  --admin-phone "$WAREHOUSE_ADMIN_PHONE" \
  --admin-name 'Warehouse Administrator'
node scripts/doctor.mjs --local
```

The first administrator phone is installed locally and must complete real SMS
verification before receiving a session. Setup reruns preserve instance identity,
credentials, database and stored files. Run the same setup command a second time
to verify that behavior before loading business data. Do not copy another
instance's state directory or credentials.

Keep before/after comparisons in private evidence: hash this instance's manifest
and credential file without printing contents, compare the existing administrator
record/database identity and migration count, and hash a fictional stored document.
Rerun with exactly the same inputs, then compare those values and verify local
health. Do not treat a maintenance Storage upload as customer authorization
evidence; test signed documents separately using a real customer session.

## HTTPS and network

Only the HTTPS reverse proxy or an integrator-managed tunnel should accept
warehouse and cellular traffic. The gateway stays on `127.0.0.1:18000`; database,
Studio, CUPS and Home Assistant stay private. Configure DNS and a trusted
certificate for the canonical origin supplied at installation. A minimal Caddy
reference is [Caddyfile.example](../deploy/Caddyfile.example); replace its
hostname and adjust its upstream port only if the private Compose configuration
uses a different gateway port.

### Cloudflare Tunnel for an operator-selected hostname

If the operator chooses Cloudflare Tunnel, install `cloudflared` from
[Cloudflare's signed Debian/Ubuntu package repository](https://developers.cloudflare.com/tunnel/features/locally-managed-tunnels/create-local-tunnel/#1-download-and-install-cloudflared).
The fresh Ubuntu run used the signed `any` package repository:

```bash
sudo -n install -m 0755 -d /usr/share/keyrings
curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg | sudo -n tee /usr/share/keyrings/cloudflare-main.gpg >/dev/null
printf 'deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared any main\n' | sudo -n tee /etc/apt/sources.list.d/cloudflared.list
sudo -n apt-get update
sudo -n apt-get install -y cloudflared
cloudflared --version
```

This installed cloudflared 2026.9.3. Inspect any existing package-repository files
before replacing them on a reused host. Package installation does not create a
route or start a connector.

The provided Windows configuration was a **sample**, not an approved hostname,
tunnel, credential path, or authorization to change Cloudflare DNS. Ask the
operator for these details **one question at a time**, at the step that needs
each answer:

1. Ask which complete API subdomain this VM should use. Do not infer one from
   the parent's website domain or a sample configuration. Check its current DNS
   and whether it serves another application before using it as `--api-url`.
2. Ask whether the operator has access to the hostname's Cloudflare zone and
   whether a tunnel is already dedicated to this VM. If one is offered, ask
   whether it is locally or remotely managed and check whether other connectors
   use it. [Cloudflare can send requests to any replica of a shared
   tunnel](https://developers.cloudflare.com/tunnel/configuration/#replicas-and-high-availability),
   so an occupied tunnel does not isolate this VM.
3. If a new tunnel is needed, ask whether the operator wants a
   [dashboard-managed tunnel](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/get-started/create-remote-tunnel/)
   or a [locally managed tunnel](https://developers.cloudflare.com/tunnel/features/locally-managed-tunnels/create-local-tunnel/).
   For dashboard management, ask the operator to create the tunnel and route
   there, then put its connector **token** in a private mode-0600 file on the
   VM. Run the connector with `cloudflared tunnel run --token-file <path>`;
   neither `cert.pem` nor a tunnel JSON credentials file is needed. For local
   management, ask whether the operator can complete `cloudflared tunnel
   login` on this VM; that login creates `cert.pem`. Ask for a path to an
   existing account certificate only if login is not used. Create the new
   tunnel with the CLI and use its generated JSON credentials file. Never ask
   the operator to paste a certificate, JSON credential or token in chat.
4. Check the hostname's Cloudflare DNS route. For a dashboard-managed tunnel,
   have the operator create the route in the dashboard. For a locally managed
   tunnel, use `cloudflared tunnel route dns` only after the selected hostname
   is confirmed and CLI authentication is available. Verify the resulting DNS
   record before enabling the connector.
5. Ask about nondefault tunnel and origin settings only when applying them;
   the sample values are not automatically approved for this installation.

The Cloudflare login may be shared with another machine. Treat its existing
tunnels, DNS records and connectors as in-use state. For a new VM installation,
create a new named tunnel and credentials file; do not reuse or delete an
existing tunnel, stop another connector, run tunnel cleanup on another
connector, or use `route dns --overwrite-dns`. Before creating the new DNS
route, confirm the exact hostname has no existing record. Limit the CLI changes
to the new tunnel and that hostname, then record the new UUID and route.

For account-side inspection after local login, keep the certificate private and
save tunnel inventory in private evidence:

```bash
cloudflared tunnel --origincert /private/path/cert.pem list --output json > /private/path/tunnels-before.json
```

Inspect the exact hostname's DNS records in the authenticated Cloudflare zone,
including all record types. This attempt used the following read-only API check
with cloudflared 2026.9.3's login certificate. It prints only the vacancy result;
the token stays in memory. Replace the certificate path and hostname. If access
is denied or the certificate format differs, stop route creation and use an
authenticated dashboard inspection; never infer vacancy from NXDOMAIN alone.

```bash
export WAREHOUSE_TUNNEL_CERT=/private/path/cert.pem
export WAREHOUSE_API_HOSTNAME=confirmed-api.example.com
python3 - <<'CHECK_DNS'
import base64, json, os, urllib.parse, urllib.request
from pathlib import Path
pem = Path(os.environ['WAREHOUSE_TUNNEL_CERT']).read_text()
body = ''.join(line for line in pem.splitlines() if not line.startswith('-----'))
cert = {key.lower(): value for key, value in json.loads(base64.b64decode(body)).items()}
url = 'https://api.cloudflare.com/client/v4/zones/' + cert['zoneid'] + '/dns_records?'
url += urllib.parse.urlencode({'name': os.environ['WAREHOUSE_API_HOSTNAME'], 'per_page': 100})
request = urllib.request.Request(url, headers={'Authorization': 'Bearer ' + cert['apitoken']})
try:
    with urllib.request.urlopen(request, timeout=20) as response:
        result = json.load(response)
except Exception:
    raise SystemExit('Authenticated DNS inspection failed; stop before configuring ingress.')
if not result.get('success') or result.get('result'):
    raise SystemExit('Hostname occupied or inspection unsuccessful; stop before configuring ingress.')
print('Authenticated exact-hostname DNS vacancy confirmed.')
CHECK_DNS
```

Verify the proposed **new** tunnel name is absent from inventory. Recheck DNS
immediately before routing, and route without overwrite. Do not inspect private
warehouse endpoints on the existing pilot as part of this fresh test exercise.

For CLI management, `cloudflared tunnel login` opens a browser authorization
flow and writes a new `cert.pem` for the selected zone. Move that file into the
private directory before continuing. Use the confirmed private path to create
a **new** named tunnel and its own credentials file, then route only the
confirmed hostname. For example, after replacing every placeholder:

```bash
cloudflared tunnel --origincert /private/path/cert.pem create \
  --credentials-file /private/path/new-tunnel.json NEW_TUNNEL_NAME
cloudflared tunnel --origincert /private/path/cert.pem route dns \
  NEW_TUNNEL_UUID CONFIRMED_API_HOSTNAME
```

The `route dns` command must be run without `--overwrite-dns`; if it reports a
record conflict, inspect that record and ask the operator before changing it.

Keep any JSON credential, token and account certificate in a mode-0700 private
directory outside the checkout, with each file mode 0600. Do not print their
contents in logs. A Windows path such as `C:\Users\admin\.cloudflared\`
cannot be used as a Linux credentials path. A locally managed tunnel uses its
JSON credentials to run; a remotely managed tunnel uses its token file.

The sample's `http://localhost:8000` referred to its original host. This Linux
operator Compose stack publishes container port 8000 at **`127.0.0.1:18000`**.
Check the generated `KONG_HTTP_PORT` and use the actual loopback port.

For a **locally managed** tunnel, write a private Linux `config.yml` outside
the checkout using its generated JSON credential path. Replace all placeholders
below with confirmed values before enabling the service:

```yaml
tunnel: <confirmed-tunnel-uuid>
credentials-file: /private/path/<confirmed-tunnel-uuid>.json
ingress:
  - hostname: <confirmed-hostname>
    service: http://127.0.0.1:18000
    originRequest:
      noTLSVerify: false
      httpHostHeader: <confirmed-hostname>
  - service: http_status:404
```

The supplied `http2-origin: true` is omitted because [HTTP/2 to an origin
requires HTTPS](https://developers.cloudflare.com/tunnel/reference/origin-parameters/),
while this gateway is private HTTP. Keep TLS verification enabled for any future
HTTPS origin. The other sample settings (`protocol`, `max-fetch-size`,
`retries`, `grace-period`, `edge-ip-version`, `connection-per-region` and
`originRequest` tuning) require operator confirmation and support checks against
the installed `cloudflared` version before use; do not assume an unrecognized
key takes effect.
For a remotely managed tunnel, configure the hostname and loopback origin in
the Cloudflare dashboard and run with the private token file instead of this
YAML. For a locally managed tunnel, validate the file with `cloudflared
--config /private/path/config.yml tunnel ingress validate` and test the
hostname rule. Verify that the Cloudflare DNS record for the confirmed hostname
points to `<confirmed-tunnel-uuid>.cfargotunnel.com`. Install and enable a
`cloudflared` system service so the tunnel survives a reboot. For local
management, use [Cloudflare's Linux service procedure](https://developers.cloudflare.com/tunnel/features/locally-managed-tunnels/as-a-service/linux/)
with the explicit config path. For remote management, configure the service to
read the private `--token-file` without placing its contents on a command line
or in the service unit. Check that only the gateway is exposed through the
tunnel, then run the local and external doctor checks and test from warehouse
Wi-Fi and cellular data.

For this fresh VM, a dedicated local unit avoided changing an existing connector.
Use a new **unoccupied unit name**, replacing the user, paths and unit name below
with this instance's recorded values. Validate ingress and confirm file ownership
before enabling it. The service user must be able to read its private directory;
keep credentials/configuration mode 0600. Do not put tokens in the unit.

```ini
# /etc/systemd/system/warehouse-NEW-INSTANCE-tunnel.service
[Unit]
Description=Dedicated test warehouse HTTPS tunnel
Wants=network-online.target
After=network-online.target docker.service
[Service]
User=YOUR_INSTALL_USER
Group=YOUR_INSTALL_USER
ExecStart=/usr/bin/cloudflared --no-autoupdate --config /private/path/config.yml tunnel run
Restart=on-failure
RestartSec=5
[Install]
WantedBy=multi-user.target
```

Write that new unit using noninteractive sudo, then run `sudo systemctl
daemon-reload`, `sudo systemctl enable --now warehouse-NEW-INSTANCE-tunnel.service`
and `systemctl is-active warehouse-NEW-INSTANCE-tunnel.service`. Inspect its logs
privately if inactive. An active/enabled service is not evidence of an unattended
restart; do not reboot without separate authorization.

After the proxy or tunnel is live, run:

```bash
export WAREHOUSE_STATE_DIR=/srv/warehouse/acme
node scripts/doctor.mjs
```

Then check the same origin from warehouse Wi-Fi and cellular data. DNS,
certificate, gateway and upstream container recovery are separate acceptance
checks. An HTTP 500 needs its own diagnosis even when DNS and stale-IP recovery
pass.

Enable the reverse proxy's system service at boot as well as Docker. If the
router cannot send LAN clients back through its public address, configure local
DNS for the same canonical domain; the app must still use the same HTTPS origin.

## Verify fictional warehouse behavior before acceptance

After local/public doctor, build/install the pinned mobile candidate using its
[operator Android guide](https://github.com/abhiguru/rn-warehouse-template/blob/codex/fresh-vm-operator-notes/docs/OPERATOR_INSTALL_NOTES.md).
Record both source commits and any native identity overrides. Choose this new
server and confirm its company/origin/instance identity before authentication.
Lift any no-SMS restriction explicitly for this instance before requesting codes;
use owned phones and local hidden input. Never use a fixed OTP or fixture issuer
against this installed warehouse.

Sign in as the first administrator. Create **Fictional Customer A**, using a
second owned phone only for authentication. Verify its first login remains pending
without warehouse access; approve it from Enrollment Review and request a new
code for Customer A. A third owned phone is required for a real Customer B session.
If unavailable, mark reciprocal A/B authentication/isolation BLOCKED. A disposable
fixture or one-way denial of access to a B record does not close that case.

Use the existing fictional billing example, with deliberately fictional items,
receipt/dispatch numbers and rack names. This exercise used:

| Step | Input / expected check |
| --- | --- |
| Administrator catalog/price | Fictional potatoes in bags; monthly price 5, labour 2, tax 5%, effective January 1, 2026 for Customer A |
| Receipt | April 1, 2026; 100 bags, 10 kg per bag; verify 100 bags / 1000 kg |
| Customer cart/order | Add 7 bags from that receipt; staff queue sees the same order; other customers cannot read/change it |
| Partial dispatch | May 2, 2026; 20 bags; 80 bags / 800 kg remain |
| Final dispatch | Same day; remaining 80 bags; zero stock remains |
| Invoice, existing legacy-duration example | Subtotal 950, rounded tax 48, total 998; compare preview and persisted invoice |
| Private documents | Authorized GRN, dispatch, invoice and stock PDFs download with valid PDF bytes; anonymous/foreign access denied |

Retain each first attempt and retry result separately. Check duplicate receipt
and dispatch retries do not duplicate records/subtract stock twice; reject
negative, zero and overstock quantities without changing balance. In a separate
fictional 10-bag receipt, submit two conflicting 7-bag dispatches concurrently;
exactly one succeeds and 3 remain. Test authorized image upload/confirmation,
private reads, duplicate/oversize rejection and deletion; do not count arbitrary
non-image bytes as proof of a native photo workflow. Refresh/replay/logout,
natural token expiry, Realtime updates/reconnect and actual native offline
behavior require their own results. Record PASS, FAIL, BLOCKED or NOT TESTED per
case; compilation and historical device passes are insufficient.

Also compare a fractional-tax native example against its saved invoice. This
installation found mobile e54 showing tax8.50/total178.50 while the unchanged
backend saved CEIL-rounded tax9/total179. The integer950/48/998 example passing
does not close this mismatch. Preserve the failed result, keep native financial
acceptance open, and agree a reviewed display/rounding correction before retesting.
Do not change production rules or delete the evidence to obtain a PASS.
Treat a preview/save mismatch as a blocker before long mobile acceptance runs.
Verify create and edit recalculation paths, confirmation, saved header and the
private PDF. Keep storage, discount and rounding adjustment separate; the
existing backend ceilings tax and total independently and preserves discount.
Use the documented 30/31/46-day boundaries and a fractional discount/surcharge.
Do not change billing policy or rewrite historical invoices to hide a failure.


These values validate the [documented fictional billing rules](INVOICE_RULES.md).
They are not approved production pricing, tax or calendar policy. Ask the operator
for business decisions before adopting production rules. Read the
[guarded disposable backend acceptance instructions](BACKEND_CORE_ACCEPTANCE.md)
for repository fixtures: they require their own fictional identity, origin,
state name and port. Preserve those guards and never point them at this warehouse.

## Optional unattended fictional fixture checks

For unattended backend/native checks, follow [the isolated fixture sequence](UNATTENDED_FIXTURE.md)
in a **new disposable checkout and state**. It uses an explicit no-delivery
provider and the repository's unchanged ownership/fictional-identity guards.
Never point those scripts or the mock-delivery bridge at the installed warehouse.
Mock delivery does not establish MSG91 acceptance. Emulator execution also needs
its own resource checks; boot completion and compilation alone are insufficient.

## Ordinary operation

Use the **installed checkout**, the recorded state directory and a shell with
Node 22 and effective Docker access. The Compose wrapper refuses a running
project owned by another checkout; a review worktree is not its service owner.

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

Start/stop the dedicated tunnel service separately using its recorded systemd
unit name. Never stop a connector belonging to another instance. Do not run
`down -v`, broad Docker prune, or delete state as a restart procedure. Docker
restart policies and an enabled tunnel service are configuration evidence;
unattended host restart remains untested until an authorized test occurs.

## Windows host with Linux VM

Install the same Linux stack inside an x86-64 VM and keep its state on a durable
VM disk. For a Hyper-V host, configure automatic start and a graceful stop from
an elevated PowerShell session, substituting the actual VM name:

```powershell
Set-VM -Name WarehouseVM -AutomaticStartAction Start -AutomaticStopAction ShutDown
```

Expose only the selected HTTPS ingress to the VM. Reboot the Windows host
without logging in, then verify that the VM, Docker services, local doctor and
external doctor recover. The Windows USB printer queue shared privately to
CUPS through Samba is a separate physical acceptance path; its presence must
be checked after the same unattended reboot. The start and stop settings are
documented by [Microsoft's Set-VM reference](https://learn.microsoft.com/en-us/powershell/module/hyper-v/set-vm).

For VMware or another hypervisor, obtain the host's actual product/version and
use its own startup/shutdown procedure; the Hyper-V command does not apply.
A successful guest reboot does not prove host autostart, USB reattachment or
operation without a host login. Arrange the host test with its operator.

## Recovery and test boundary

The manual `db:backup` command produces a private **unencrypted** archive
directory containing the database, stored documents, public manifest and private
configuration. Store it only on protected storage. `db:verify-restore` checks a
disposable database and archived objects; it does not install the backup as a
replacement operator instance. Optional CUPS and monitoring volumes are not in
this core backup. CUPS spools are project-scoped and persist independently of
the source checkout.

Encrypted off-host transfer, scheduled retention, optional-service recovery and
the replacement-host restore procedure remain open in the acceptance ledger.
Back up to an operator-provided encrypted off-host destination before production.
Define schedule, retention and key custody before enabling automation. Restore
onto a replacement host and verify credentials, document access and mobile
reconnection before declaring recovery complete. Record physical MSG91 receipt,
printer forms, Tapo uploads and each phone-platform case independently against
exact code and build IDs. The dated [pilot notes](OPERATOR_SETUP_NOTES.md) record
real SMS/API login and partial Android Wi-Fi acceptance; printing, sensors and
the remaining native cases are still open. These pilot results do not carry over
to a fresh operator instance without its own checks.


### Resuming after an operator-managed VM reboot

Keep the private inputs and instance state; do not run initial setup against a
new state path merely to restart. Recheck disk/memory, effective noninteractive
sudo/Docker access, private port ownership, tunnel service and both doctor modes.
Use the pinned Node PATH in the same shell (and any `sg docker` shell) that runs
the commands. The system Node may differ after reopening a terminal. Consult
[FRESH_VM_INSTALL_LEDGER.md](FRESH_VM_INSTALL_LEDGER.md) before repeating suites:
repeat health after a reboot, and failed or changed cases, rather than every
completed fixture test. Never delete volumes or another instance to resume.
