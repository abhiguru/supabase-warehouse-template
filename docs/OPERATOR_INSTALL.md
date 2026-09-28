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
Use the operator PR pair linked by [DEVELOPER_HANDOFF.md](DEVELOPER_HANDOFF.md)
until it has been reviewed and merged; do not assume the changes are on `main`.

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
Choose a persistent filesystem with at least 10 GiB free for this initial
installation check, plus capacity for the operator's actual data. Start Docker
at boot with `sudo systemctl enable --now docker`. The installer checks its
availability and Linux x86-64 architecture before creating state.

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
ID. For the current Guru Cold Storage flow, use Flow ID
`694a8ea0cd30ae1f432f445a`, PE ID `1101817660000088076`, sender/header
`GCSAMD`, and DLT Template ID `1107176638369238844`. Its approved message is
`{OTP} is your OTP code for Guru Cold Storage Private Limited, Ahmedabad. Valid for 5 mins. Please do not share this with anyone.`
The Flow variable is exactly `OTP`, including capitalization. The operator OTP
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
include them in the protected off-host recovery bundle under the custody
policy below. Never commit either file.

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

The [production recovery acceptance plan](PRODUCTION_RECOVERY_ACCEPTANCE.md)
lists the off-host, replacement-host and separate cutover gates, including the
operator's explicit unencrypted-backup risk exception for this pilot. New
v4 backups also include a sensitive cluster-globals SQL export containing role
definitions and password hashes. Protect it with the same permissions as the
private configuration and database dump.

The manual `db:backup` command produces a private **unencrypted** archive
directory containing the database, stored documents, public manifest and private
configuration. Store it only on protected storage. `db:verify-restore` checks a
disposable database and archived objects; it does not install the backup as a
replacement operator instance. Optional CUPS and monitoring volumes are not in
this core backup. CUPS spools are project-scoped and persist independently of
the source checkout.

Protected off-host transfer, scheduled retention, optional-service recovery and
the replacement-host restore procedure remain open in the acceptance ledger.
The default is an encrypted off-host destination; the pilot operator has chosen
an explicit unencrypted exception, which requires restricted physical custody
and must remain visible in acceptance evidence.
Define schedule, retention and key custody before enabling automation. Restore
onto a replacement host and verify credentials, document access and mobile
reconnection before declaring recovery complete. Record physical MSG91 receipt,
printer forms, Tapo uploads and each phone-platform case independently against
exact code and build IDs. The dated [pilot notes](OPERATOR_SETUP_NOTES.md) record
real SMS/API login and partial Android Wi-Fi acceptance; printing, sensors and
the remaining native cases are still open. These pilot results do not carry over
to a fresh operator instance without its own checks.
