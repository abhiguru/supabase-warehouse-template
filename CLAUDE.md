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
Nothing of it is implemented yet.

## What the backend will need for central login

- An operator setting to trust the association's token issuer and public keys (off for
  installs that are not association members).
- An exchange endpoint that verifies the central token (signature, issuer, audience = this
  facility, expiry, single use) and then: creates a pending access request (reuse
  `operator_enrollment` / enrollment review), issues the existing session for an approved
  active profile, or refuses a disabled one.
- Revocation stays local: `update_user_status(false)` already revokes a profile's sessions.
- Local SMS login (`functions/operator-otp`, `operator_*` RPCs) stays for bootstrap and
  non-member installs.

## How it works today

- Operator install and upgrades: [docs/OPERATOR_INSTALL.md](docs/OPERATOR_INSTALL.md)
  (`setup.sh --operator`, one Cloudflare Tunnel per installation, MSG91 SMS).
- Every business RPC is guarded by `warehouse_security.authorize_rpc` (latest version in
  the newest migration that redefines it), and business data is written only through
  those RPCs: no app role, administrator included, can insert, update or delete a
  business table directly (migration 42). Direct table reads remain, limited by the row
  policies. What staff and customers may do is in
  [docs/STAFF_GRN_POLICY.md](docs/STAFF_GRN_POLICY.md); invoice amounts in
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
