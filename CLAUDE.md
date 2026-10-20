# CLAUDE.md — supabase-warehouse-template

Guidance for Claude Code (and other contributors) working in this repository.

## What this backend is for

This is the backend that **one cold-storage facility runs on its own premises**. It serves
the [rn-warehouse-template](https://github.com/abhiguru/rn-warehouse-template) app, which
the facility's **owner**, **staff** and **clients** use for orders, tracking, goods receipts
(GRN), dispatch, invoices and stock.

- The app is meant to be launched by the **Gujarat Cold Storage Association (GCSA)** for its
  members. Every member **self-hosts** this backend; owners with **several facilities** run
  one installation per facility.
- **Login is central; data is not.** A central association service will only prove who a
  user is. There is **no central data store**: all business data stays in this backend.
- A user adds a facility in the app and sees nothing until **this facility authorizes
  them** (role and customers, decided here). This facility can **revoke** access at any time
  without the central service.
- Intended flow: central sign-in → the user picks this facility → the app exchanges a
  short-lived, facility-specific identity token here for a local session → data comes from
  this backend only.

The target design is in the app repository's
[docs/CENTRAL_LOGIN.md](https://github.com/abhiguru/rn-warehouse-template/blob/main/docs/CENTRAL_LOGIN.md).
The facility half of it is implemented here (migrations 49 and 64, 2026-10-12; 81, 2026-10-15). The central
service and the app's central screens were built and tested on 2026-10-12 (what ran and what
did not: [docs/CENTRAL_LOGIN.md](docs/CENTRAL_LOGIN.md), "Tested, and not tested"); central
login stays off by default.

## Central login in this backend

The contract (token, endpoint, answers, what is stored) is [docs/CENTRAL_LOGIN.md](docs/CENTRAL_LOGIN.md).

- Operator settings `CENTRAL_ISSUER` with `CENTRAL_JWKS_URL` (keys fetched) or
  `CENTRAL_JWKS_FILE` (keys from a file copied into the state): `setup.sh --central-issuer`
  with `--central-jwks-url` or `--central-jwks-file`; all empty = off, the default for
  installs that are not members.
- `functions/central-exchange` verifies the identity token (ES256 signature against the
  issuer's key set, issuer, audience = this facility only, lifetime, type) and calls
  `operator_central_exchange`, which accepts a token once and then does what a correct SMS
  code does: a pending access request (the existing enrollment review), the existing
  session for an approved active profile, or a refusal for a rejected or disabled one.
- **One association sign-in opens every facility (owner decision of 2026-10-15, migration 81).**
  The central token opens an existing **person** profile: found by the central-verified mobile
  the first time (the profile is then linked to the identity), by central `sub` afterwards, with
  no SMS code of this facility. This deliberately replaces the earlier rule "the central
  service's word alone never opens an existing profile": the reason is that one association
  sign-in, with one code sent by the association, must work at every facility. **Accepted
  consequence:** whoever controls the central service (or a number's SMS there) can open any
  profile with that number at a facility that leaves the extra code off, administrators
  included. Do not "fix" this back without the owner. New people still file an access request
  that an administrator approves (no code); revocation stays local; `identity_conflict` stays.
  The decision order is in the header of migration 81 and `docs/CENTRAL_LOGIN.md`.
- **Service accounts are never opened by a central token** (`user_profiles.is_service_account`,
  migration 78): the exchange answers `account_unavailable` for one, found by phone or by
  subject, and does not link it. Keep that guard whenever the exchange changes.
- **The facility's own code is optional and off by default** (`setup.sh --central-local-code
  on|off`, `auth_config` key `central_local_code`): with it on, an approved profile is asked
  for a facility SMS code (`otp_code`, `operator_verify_otp`; `link_required` without it) at
  **every** new sign-in, linked or not.
- A profile carries its central identity (`user_profiles.central_issuer`,
  `central_subject`). An administrator unlinks one with `clear_user_central_identity`.
- Revocation stays local: `update_user_status(false)` revokes a profile's sessions.
- Local SMS login (`functions/operator-otp`, `operator_*` RPCs) stays for bootstrap and
  non-member installs. Keep the two paths answering alike: a change to what
  `operator_verify_otp` does after a correct code belongs in `operator_central_exchange` too.

## How it works today

- Operator install and upgrades: [docs/OPERATOR_INSTALL.md](docs/OPERATOR_INSTALL.md)
  (`setup.sh --operator`, one Cloudflare Tunnel per installation, MSG91 SMS).
- Every business RPC is guarded by `warehouse_security.authorize_rpc` (latest version in
  the baseline until a migration after it redefines it, then in the newest such migration), and business data is written only through
  those RPCs: no app role, administrator included, can insert, update or delete a
  business table directly (migration 42). Direct table reads remain, limited by the row
  policies; on `invoice` the six internal columns (discount and zero-charge reason,
  author and time) are not readable from the table, so a read names its columns
  (migration 48; [docs/INVOICE_RULES.md](docs/INVOICE_RULES.md), "Internal columns").
  What supervisors, staff and customers may do is in
  [docs/STAFF_GRN_POLICY.md](docs/STAFF_GRN_POLICY.md) (role table under "Roles after
  migration 45", current through migration 90; `tests/role_allowlist.sql` classifies every granted function);
  invoice amounts in
  [docs/INVOICE_RULES.md](docs/INVOICE_RULES.md).

## Working rules

- Schema changes are **new, append-only migrations** in `migrations/`; applied files are
  checksum-locked and must never be edited. Migrations 000-110 are the one file `00000000000000_baseline.sql`
  (the old files: tag `migrations-pre-baseline`); the next migration is `00000000000111_<topic>.sql`. Patch large baseline functions with the
  `DO $patch$` + marker-count pattern used by earlier migrations.
- Roles are never created, altered or dropped in a migration (`tests/migration-roles.test.mjs`): they live in
  `docker/volumes/db/00-bootstrap.sql`, and a database-level bootstrap fix also ships as a migration
  ([docs/CONTAINER_SECURITY.md](docs/CONTAINER_SECURITY.md), "Roles and migrations").
- Every new RPC calls `warehouse_security.authorize_rpc` first, sets
  `search_path`, and is granted explicitly; new tables enable RLS and revoke default grants.
- Checks before a pull request: `npm test` and `npm run test:migrations` (Docker); add a SQL
  test under `tests/` for each policy or RPC change and register it in `tests/migrations.sh`.
  CI's `contract` job checks the backend against the app commit in `MOBILE_REF` (`.github/workflows/ci.yml`): bump it with
  every change that needs the app, and run `npm run check:contract -- <app checkout>` first. `npm run baseline:verify` is
  needed only when the baseline file is regenerated, never for an ordinary migration.
- Use fictional names and phone numbers in tests and fixtures; never commit secrets.
- Security-relevant findings go to a private GitHub security advisory, not a public issue.
