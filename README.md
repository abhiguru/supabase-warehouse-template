# Supabase Warehouse Template

Self-hosted backend for a cold-storage warehouse: goods receipts, dispatches,
invoices, customer orders and phone-OTP login on PostgreSQL, PostgREST,
Storage, Deno edge functions and a PDF renderer, one installation
per warehouse. It is used from the companion
[React Native app](https://github.com/abhiguru/rn-warehouse-template).

## Quickstart

Prerequisites, all required:

- A Linux x86-64 host or VM with Docker Engine + a Compose plugin whose `up` accepts `--wait-timeout`, Node.js 22.18+,
  Git, OpenSSL and util-linux `flock`.
- Real [MSG91](https://msg91.com) credentials (auth key, approved OTP Flow ID,
  DLT entity ID, sender ID) in a mode-0600 file outside the checkout. There is
  no local or fixed-OTP mode.
- A Cloudflare Tunnel from your canonical HTTPS hostname to the gateway on
  `127.0.0.1:18000`; it is the only supported ingress.
- The first administrator's phone number, 12 digits with the `91` prefix.

```bash
git clone https://github.com/abhiguru/supabase-warehouse-template.git
cd supabase-warehouse-template
bash setup.sh --operator \
  --state-dir /srv/warehouse/acme \
  --api-url https://warehouse.example.com \
  --company 'Example Cold Storage' \
  --provider-env /secure/warehouse-msg91.env \
  --admin-phone 91XXXXXXXXXX \
  --admin-name 'Warehouse Administrator' \
  --alert-webhook-file /secure/warehouse-slack-webhook.txt \
  --letterhead-file /secure/letterhead.png   # or: --letterhead-file off (plain PDFs)
export WAREHOUSE_STATE_DIR=/srv/warehouse/acme
node scripts/doctor.mjs --local      # every service healthy on the loopback gateway
# set the SMS ceiling first (required for a public install): docs/OPERATOR_INSTALL.md#authentication-and-otp-limits
# start the cloudflared connector for your hostname (deploy/cloudflared-config.example.yml)
node scripts/doctor.mjs              # the same instance answers through the public origin
```

Then install the app, select the HTTPS origin and sign in as the administrator
with a real SMS code.

- Full guide (host setup, tunnel, backup and restore, key rotation, upgrades): [docs/OPERATOR_INSTALL.md](docs/OPERATOR_INSTALL.md)
- Something went wrong: [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md)
- What staff and customers may do: [docs/STAFF_GRN_POLICY.md](docs/STAFF_GRN_POLICY.md)
- What is still open before production use: [docs/PRODUCTION_DEPENDENCIES.md](docs/PRODUCTION_DEPENDENCIES.md)
- What has to be done when, over the next years (renewals, end-of-life dates): [docs/MAINTENANCE_CALENDAR.md](docs/MAINTENANCE_CALENDAR.md)

## Install with an AI agent

Point an AI coding agent at this repository and tell it to install the backend. These are its instructions.

**First ask the operator, one question at a time:**

1. Backend only, or the backend plus the app run from Expo on a phone for a test?
2. The [private inputs](docs/OPERATOR_INSTALL.md#private-inputs), one question each, in this order:
   1. The public HTTPS hostname.
   2. The tunnel: either `tunnel.sh create` (it prints a Cloudflare login link for the operator to open), or a config or token **file** of a **new** tunnel that routes the hostname to `127.0.0.1:18000` (the operator must not run the dashboard's `cloudflared service install` command; this install starts the connector itself).
   3. The path of the MSG91 provider file.
   4. The company name (`--company`, the facility's display name, up to 120 characters).
   5. The first administrator's phone (`91` + ten digits) and name.
   6. A Slack webhook file (`off` only for a test install).
   7. A letterhead file, or `off`.
   8. Central sign-in, yes or no; if yes, the issuer and the key URL or file ([Central sign-in](docs/OPERATOR_INSTALL.md#central-sign-in)); if no, SMS sign-in only. If yes, also ask whether to require this facility's own SMS code at every central sign-in (`--central-local-code on`, default off; read the trade-off in [Central sign-in](docs/OPERATOR_INSTALL.md#central-sign-in)). The operator gives the association this facility's exact public origin (the `--api-url`) for its catalogue. The central identity service is not part of a facility install: the association's primary operator installs it once from its own repository (`central-identity-template`, private; ask the association). A facility needs only the issuer and the key set from the association.
   9. The daily SMS ceiling, the most MSG91 requests they will pay for in 24 hours (`otp_daily_provider_attempt_cap`).
   10. The host time zone, the facility's own.
   11. The state directory (absolute, outside the checkout; the guide uses `/srv/warehouse/<name>`).

The operator copies every secret file onto the host. Never ask for a secret value in chat, and never print one into a log or a report. Do not `cat` or `echo` a secret file to check it; setup and doctor validate them.

Run on the host itself, as the non-root installation user. When a command needs `sudo` and no password-less sudo is set up, give the operator the exact command to run in their own terminal and wait; never ask for the password. After the docker group change, use a new login shell or `sg docker -c '…'`.

**Then follow [docs/OPERATOR_INSTALL.md](docs/OPERATOR_INSTALL.md) in this order:**

1. [Host prerequisites](docs/OPERATOR_INSTALL.md#host-prerequisites): on Ubuntu 24.04 the
   [Ubuntu 24.04 sequence](docs/OPERATOR_INSTALL.md#ubuntu-2404-sequence); on Windows the
   [Windows host (Ubuntu in WSL2)](docs/OPERATOR_INSTALL.md#windows-host-ubuntu-in-wsl2) section; on anything else stop and ask.
   The sequence gives Node, Docker, then a clone made with `umask 022` (even if you were started inside a clone)
   and checked out at the newest release tag (not an `-rc` tag), and the
   [host time zone](docs/OPERATOR_INSTALL.md#host-time-zone) set to the facility's zone from the inputs.
   From here on, follow the checked-out tag's own README section "Install with an AI agent" and its
   docs/OPERATOR_INSTALL.md, not GitHub's main or this copy. If that tag's README has no such section, the tag is older than these instructions: stop and ask the operator.
2. Create the state directory as in [Private inputs](docs/OPERATOR_INSTALL.md#private-inputs) (**State directory**: the parent with
   `sudo install -d -m 0755 -o …`, which the operator runs, and the leaf without sudo), `export WAREHOUSE_STATE_DIR=<it>`, then
   [Setup](docs/OPERATOR_INSTALL.md#setup) with the inputs above, then `node scripts/doctor.mjs --local`.
3. Set the SMS cap ([Authentication and OTP limits](docs/OPERATOR_INSTALL.md#authentication-and-otp-limits), `otp_daily_provider_attempt_cap`)
   and read it back **before** the tunnel connector starts. Run the guide's `INSERT` and read-back through
   `bash scripts/compose.sh exec -T db psql -X -U supabase_admin -d postgres -c "…"`.
4. On a Windows host, first have the operator register the keep-alive task
   ([Keep the distro running and start it at boot](docs/OPERATOR_INSTALL.md#keep-the-distro-running-and-start-it-at-boot);
   an elevated PowerShell on Windows, which the operator runs).
   [Cloudflare Tunnel ingress](docs/OPERATOR_INSTALL.md#cloudflare-tunnel-ingress): install `cloudflared`, then `tunnel.sh create` or
   `tunnel.sh adopt --config|--token-file`, then `sudo bash scripts/tunnel.sh install-service --state "$WAREHOUSE_STATE_DIR"` (the operator runs it).
5. The monitoring timer: the operator runs `sudo bash scripts/watch-timer.sh install --state "$WAREHOUSE_STATE_DIR"`
   ([Setup](docs/OPERATOR_INSTALL.md#setup)), then the full
   [external doctor](docs/OPERATOR_INSTALL.md#external-doctor) through the public origin.

If the operator chose the app too, continue with the app's [Install with an AI agent](https://github.com/abhiguru/rn-warehouse-template#install-with-an-ai-agent) (Expo Go), using this origin and, with central sign-in, the issuer from input 8.

**Stop and ask the operator** when an input is missing, when a step needs a payment or licence decision or an account outside the host,
or when a step fails the same way twice; look in [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) first.

**Finish with a report:** the last step that worked, the doctor results, the SMS cap value and what is left running. Leave to the operator, and list in the report: the [first-use checks](docs/OPERATOR_INSTALL.md#first-use-checks), the backup key copy (`backup-key-escrow.sh show` prints a secret: never run it yourself) and the [USB backup drive](docs/OPERATOR_INSTALL.md#usb-backup-drive).

## Isolation and migration safety

Operator scripts use a unique Compose project and a state directory outside the
checkout. The database and PDF service are private to the project; the
gateway binds to loopback for the tunnel connector.

Startup brings up only the database first, then applies the complete schema,
permissions and custom-auth configuration before starting the APIs. Migrations
use checksums, a database advisory lock and a transactional ledger. Changed
applied files and untracked existing warehouse databases are refused. Add new
migrations for later changes; do not transplant this baseline into an existing
installation. The schema is one baseline migration (`migrations/00000000000000_baseline.sql`); a database built before
it cannot be upgraded in place ([Baseline reload](docs/OPERATOR_INSTALL.md#baseline-reload)). "Migration N" in the
documentation, for N up to 110, names a file of the old chain; those files are kept in the git tag
`migrations-pre-baseline`. New migrations continue at 111.

Setup never revokes or rotates another installation's credentials, and a rerun
preserves this installation's identity and signing keys. Rotating them is a
separate explicit command, `bash rotate-keys.sh --yes`
([docs/OPERATOR_INSTALL.md](docs/OPERATOR_INSTALL.md#rotate-signing-keys)).

## Features and limits

The schema includes the warehouse business definitions; imported administrative,
legacy SMS and debugging functions are not executable by API users.
Authenticated access uses explicit RPC grants, active sessions and customer RLS;
staff permissions are listed in [docs/STAFF_GRN_POLICY.md](docs/STAFF_GRN_POLICY.md)
and invoice totals are computed server-side ([docs/INVOICE_RULES.md](docs/INVOICE_RULES.md)).
Generated PDFs use a generic, escaped starter layout, private storage and
one-hour signed links. Configure business details and document terms before use.

The app re-reads order and cart screens every 15 seconds (there is no live push). Tapo temperature and humidity
sensors reach the backend through an optional bridge container (Compose profile `sensors`, GPL-3.0-or-later code in
`docker/sensor-bridge/`; [docs/SENSORS.md](docs/SENSORS.md)); the app sees them where the `sensors` capability is turned on.
Printing and sensors still require hardware acceptance; monitoring is one small checker program with a Slack webhook
([docs/MONITORING.md](docs/MONITORING.md)). The three preprinted document functions and print status monitoring are exported
for contract parity, but physical printing hardware remains unverified. See [docs/API_CONTRACT.md](docs/API_CONTRACT.md) for
the exported surface and [docs/PRODUCTION_DEPENDENCIES.md](docs/PRODUCTION_DEPENDENCIES.md) for what has been accepted.

There is no accounting integration. Recorded payments drive the Paid and Pending
figures of the invoice reports; the app does not write them. The ungranted
baseline functions are not API
([docs/API_CONTRACT.md](docs/API_CONTRACT.md), "Legacy and dormant functions").

## Contributing, CI and history

`npm test` runs the node tests without Docker; `bash tests/migrations.sh` runs
the migration ledger and SQL policy tests on a disposable database. Start with
[docs/DEVELOPER_HANDOFF.md](docs/DEVELOPER_HANDOFF.md) and
[CONTRIBUTING.md](CONTRIBUTING.md). GitHub Actions runs the unit checks, the
mobile name inventory, the disposable migration tests, a secret scan and a
complete isolated operator installation on every push and pull request to
`main`; any `v*` tag is validated separately and releases are published
manually.

The source-demo release `v0.2.2-demo` and the 2026 pilot are summarized in
[docs/HISTORY.md](docs/HISTORY.md).

MIT covers project code, except the optional sensor bridge in
`docker/sensor-bridge/`, which is GPL-3.0-or-later because it uses python-kasa
(GPL-3.0). See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)
and [LICENSES](LICENSES/) for bundled upstream material.
