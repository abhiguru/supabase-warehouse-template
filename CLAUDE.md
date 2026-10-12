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
The facility half of it is implemented here (migration 49, 2026-10-12); the central service
and the app screens are not built yet, so no real token exists and it is off by default.

## Central login in this backend

The contract (token, endpoint, answers, what is stored) is [docs/CENTRAL_LOGIN.md](docs/CENTRAL_LOGIN.md).

- Operator settings `CENTRAL_ISSUER` and `CENTRAL_JWKS_URL` (`setup.sh --central-issuer
  --central-jwks-url`; both empty = off, the default for installs that are not members).
- `functions/central-exchange` verifies the identity token (ES256 signature against the
  issuer's key set, issuer, audience = this facility, lifetime, type) and calls
  `operator_central_exchange`, which accepts a token once and then does what a correct SMS
  code does: a pending access request (the existing enrollment review), the existing
  session for an approved active profile, or a refusal for a rejected or disabled one.
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
  the newest migration that redefines it), and business data is written only through
  those RPCs: no app role, administrator included, can insert, update or delete a
  business table directly (migration 42). Direct table reads remain, limited by the row
  policies; on `invoice` the six internal columns (discount and zero-charge reason,
  author and time) are not readable from the table, so a read names its columns
  (migration 48; [docs/INVOICE_RULES.md](docs/INVOICE_RULES.md), "Internal columns").
  What supervisors, staff and customers may do is in
  [docs/STAFF_GRN_POLICY.md](docs/STAFF_GRN_POLICY.md) (role table in its last
  section; `tests/role_allowlist.sql` classifies every granted function);
  invoice amounts in
  [docs/INVOICE_RULES.md](docs/INVOICE_RULES.md).

## Working rules

- Schema changes are **new, append-only migrations** in `migrations/`; applied files are
  checksum-locked and must never be edited. Patch large baseline functions with the
  `DO $patch$` + marker-count pattern used by earlier migrations.
- Every new RPC calls `warehouse_security.authorize_rpc` first, sets
  `search_path`, and is granted explicitly; new tables enable RLS and revoke default grants.
- Checks before a pull request: `npm test` and `npm run test:migrations` (Docker); add a SQL
  test under `tests/` for each policy or RPC change and register it in `tests/migrations.sh`.
- Use fictional names and phone numbers in tests and fixtures; never commit secrets.
- Security-relevant findings go to a private GitHub security advisory, not a public issue.
