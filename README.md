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
