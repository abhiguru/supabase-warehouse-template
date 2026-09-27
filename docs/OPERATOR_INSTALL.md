# Independent warehouse installation

Use a fresh Linux x86-64 host or Linux VM for each warehouse instance. Each
instance owns its database, document storage, credentials and canonical HTTPS
origin. The installer writes private state outside the Git checkout. The
[operator acceptance ledger](PRODUCTION_DEPENDENCIES.md#independent-operator-installation-work)
records which integrations and physical tests remain open.

This is the pilot installation path. A successful setup does not enable the
unfinished printer/sensor integrations or complete replacement-host recovery.
Use the operator PR pair linked by [DEVELOPER_HANDOFF.md](DEVELOPER_HANDOFF.md)
until it has been reviewed and merged; do not assume the changes are on `main`.

## Linux host preparation

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

The MSG91 template must be an approved Flow SMS template using `VAR1` for the
six-digit code. [MSG91's Send SMS documentation](https://docs.msg91.com/sms/send-sms)
notes that an accepted API response does not confirm delivery to the handset;
test receipt with an owned phone. Keep the provider file and
the generated `config/compose.env` private and include them in the encrypted
off-host backup. Never commit either file.

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
uses a different gateway port. After the proxy is live, run:

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
reconnection before declaring recovery complete. Physical MSG91 receipt,
printer forms, Tapo uploads and both phone platforms remain **not tested** for
this operator until their results are recorded against exact code and build IDs.
