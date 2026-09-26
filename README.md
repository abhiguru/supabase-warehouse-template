# Supabase Warehouse Template

## Current operator installation work

The current development branch uses `setup.sh --operator` for a warehouse-owned
Linux x86-64 installation. It requires private MSG91 credentials, a canonical
HTTPS origin, an external state directory and a locally bootstrapped first
administrator. See [the installation guide](docs/OPERATOR_INSTALL.md) and the
[authoritative acceptance ledger](docs/PRODUCTION_DEPENDENCIES.md#independent-operator-installation-work).
The historical `v0.2.2-demo` tag remains available for its recorded source-demo
evidence. Operator hardware, external services and final mobile builds require
their own acceptance results.

## Local production-readiness work

Provider-independent work across backup/restore, owned-service recovery,
auth/RLS, loopback gateway controls, database retention, business regressions,
load smoke, local monitoring, Realtime, and companion Android artifact review is
implemented and reproducible. See
[LOCAL_PRODUCTION_READINESS.md](docs/LOCAL_PRODUCTION_READINESS.md) for the
eleven-area evidence and commands.

Production remains gated by the dated all-profile image scan: Grafana retained
HIGH findings, while PostgREST has a known affected `aeson` component and lacks
a complete, assessable image-bound inventory. Target-operator
and external-service acceptance also remains open: real SMS, public DNS/TLS,
external alert delivery, production data/retention and capacity policy, and
final mobile signing/stores. Payments, enabled telemetry delivery, and
printer/sensor hardware need acceptance if included in the operator's scope.
The historical fixed-OTP demo is confined to its immutable source tag.
See the [remaining production work checklist](docs/PRODUCTION_DEPENDENCIES.md#remaining-production-work)
for the required inputs, next actions and acceptance evidence. The historical
CI setup HTTP 500 follow-up is tracked there separately from the completed
source-demo phone acceptance.

## Historical release evidence

The immutable `v0.2.2-demo` source release and its dated device results remain
documented in [SOURCE_DEMO_ACCEPTANCE.md](docs/SOURCE_DEMO_ACCEPTANCE.md) and
[READINESS.md](docs/READINESS.md). Current installation accepts operator mode
only; those historical results do not validate this runtime.

## Connect the mobile application

Install the companion repository and select the operator's canonical HTTPS
origin in the app. Run `npm run check:backend` there for read-only discovery.
Recorded native-build and physical-device acceptance is scoped to the exact
pairs in [READINESS.md](docs/READINESS.md); production signing and distribution
remain separate gates.
Fresh public-clone setup and safe reruns are documented in
[CLEAN_INSTALL.md](docs/CLEAN_INSTALL.md), including isolated ports for a second checkout.

No private key is copied into the mobile app. It retrieves the public anon key
from bootstrap configuration.

## Isolation and migration safety

Operator scripts use a unique Compose project and state directory outside the
checkout. The database, Studio and PDF service are private to the project; the
gateway binds to loopback for the HTTPS proxy.

Startup brings up only the database first, then applies the complete schema,
permissions, and custom-auth configuration before starting APIs. Migrations use
checksums, a database advisory lock, and a transactional ledger. Changed applied
files and untracked existing warehouse databases are refused. Add new migrations
for later changes; do not transplant this baseline into an existing installation.

Setup never revokes or rotates another installation's credentials.

## Features and limits

The schema includes the warehouse business definitions; imported administrative,
legacy SMS, and debugging functions are not generally executable by API users.
Authenticated access uses explicit RPC grants, active sessions and customer RLS.
Generated PDFs use a generic, escaped starter layout, private storage, and
one-hour signed links. Configure business details and document terms before use.

Realtime supports order/cart live updates.
Printing and sensors still require hardware acceptance; monitoring is optional. The three preprinted document functions
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
