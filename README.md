# Supabase Warehouse Template

An open-source warehouse backend, paired with
[rn-warehouse-template](https://github.com/abhiguru/rn-warehouse-template).

The current main branch supports a **local development demo**. Fresh schema
restore, custom login, customer isolation, GRN, dispatch, invoice saving, and
four PDF/download flows have passed integration tests. This is **not a
production-ready release**. Production SMS, optional printing, native-device
acceptance, and broader workflow/security review remain open. The older
v0.1.0 tag contains an incomplete export; use current main for these changes.

## Start the local demo

Prerequisites: Node.js 22.18+, npm, Docker with Compose v2, and OpenSSL.
Allow several GB of free memory/disk and internet access for image/module downloads.

```bash
git clone https://github.com/abhiguru/supabase-warehouse-template.git
cd supabase-warehouse-template
npm ci
npm test
bash setup.sh --demo
```

Setup generates credentials **only if** `docker/.env` does not exist. Existing
configuration bytes are preserved. Demo startup requires `AUTH_MODE=demo`,
`APP_ENV=development`, and `BIND_ADDRESS=127.0.0.1`; an incompatible existing
configuration fails rather than being overwritten.

- API: `http://localhost:18000`
- Studio: `http://localhost:54325` (local access only)
- Demo admin: **0000000001**
- Assigned demo customer: **0000000002**
- Demo OTP: **123456** — no SMS is sent.

Demo authentication accepts only numbers 0000000001 through 0000000009.
OTP expiry, attempt limits, replay protection, and five-per-hour/twenty-per-day
request limits still apply. Never expose this demo to the internet.

```bash
bash health-check.sh
npm run test:migrations
npm run test:api
bash start.sh --demo
bash stop.sh
```

Migration tests use and remove their own network-isolated disposable database.
API tests require the running demo, verify its generated key before writes,
and leave fictional GRN/dispatch/invoice fixtures for exploration. Each API-test
run consumes a demo OTP request per account. Stop preserves database/files.

## Connect the mobile application

Install the companion repository and set its `EXPO_PUBLIC_CONFIG_API_URL` to
`http://localhost:18000`. Run `npm run check:backend` there.

For Android connected to the backend host, run `adb reverse tcp:18000 tcp:18000`
so the device can use the same localhost origin. If Metro runs on that host,
also use `adb reverse tcp:8081 tcp:8081`. iOS simulator access assumes the backend
is reachable on the Mac; a remote backend requires an appropriate local tunnel.
Native app builds and physical-device flows are still acceptance tasks.
Fresh public-clone setup and safe reruns are documented in
[CLEAN_INSTALL.md](docs/CLEAN_INSTALL.md), including isolated ports for a second checkout.

No private key is copied into the mobile app. It retrieves the public anon key
from bootstrap configuration.

## Isolation and migration safety

All scripts operate on this checkout's Compose project and verify container
ownership. The project name defaults to `warehouse-template` and must begin
with `warehouse-`. Database/storage mounts live inside this new checkout.
The database host port is 15433; the PDF-service host port is 13100.

Startup brings up only the database first, then applies the complete schema,
permissions, and custom-auth configuration before starting APIs. Migrations use
checksums, a database advisory lock, and a transactional ledger. Changed applied
files and untracked existing warehouse databases are refused. Add new migrations
for later changes; do not transplant this baseline into an existing installation.

Original repositories, production data, credentials, and Git history are not
needed. Setup never revokes or rotates another installation's credentials.
Account refresh-token renewal affects only that new demo login session.

## Features and limits

The schema includes the warehouse business definitions; imported administrative,
legacy SMS, and debugging functions are not generally executable by API users.
Authenticated access uses explicit RPC grants, active sessions and customer RLS.
Generated PDFs use a generic, escaped starter layout, private storage, and
one-hour signed links. Configure business details and document terms before use.

Printing, sensors, Realtime, monitoring and other optional integrations are not
validated by the default demo. The three preprinted document functions
(`print-dispatch-preprinted`, `print-grn-preprinted`, `print-invoice-preprinted`)
and print status monitoring are exported for contract parity, but physical
printing hardware remains unverified.
See [READINESS.md](docs/READINESS.md) and [API_CONTRACT.md](docs/API_CONTRACT.md)
for the exact boundary of testing. Older operational documents are not deployment
guarantees.

GitHub Actions CI runs unit checks, a static name inventory and disposable
PostgreSQL migration/security tests on pushes and pull requests to `main`.
Tag validation is separate; releases are explicitly published as prereleases
after their validation passes. A green name inventory is not full RPC acceptance.

MIT covers project code. See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)
and [LICENSES](LICENSES/) for bundled upstream material.
