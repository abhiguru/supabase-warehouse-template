# Central login: the facility side

The association runs a central identity service that proves who a person is.
The app gets from it a short-lived signed token for **one** facility and hands
it to that facility. This document is the facility half of that contract: how
this backend checks the token and what it answers.

The overall design, the app screens and the open questions are in the app
repository's
[docs/CENTRAL_LOGIN.md](https://github.com/abhiguru/rn-warehouse-template/blob/main/docs/CENTRAL_LOGIN.md).

Central login is **off** until the operator configures the association's
issuer (see [Operator settings](#operator-settings)). Local SMS sign-in
(`functions/operator-otp`) is unchanged and keeps working, for the first
administrator and for installations that are not members.

## What the facility relies on the central service for

A facility that turns central login on trusts the central service for one
statement: **this phone number belongs to this central account** (`sub`).

It relies on that statement in two places:

- **A new access request.** A person this facility has never seen becomes a
  pending request under the name and number the token carries. An
  administrator of this facility still decides; until then the person sees
  nothing.
- **Sign-ins of a profile that is already linked** to that central account.
  Whoever can make the central service issue a token for the account gets
  that profile's session here. A compromised central service, or a compromised
  central account, therefore reaches every profile linked to it, for as long
  as the profile is active.

It does **not** rely on it for these:

- **Taking over an existing profile.** A profile that exists here and is not
  linked yet (the administrator created at installation, staff and customers
  who enrolled with an SMS code) is linked only together with a correct SMS
  code that **this facility** sent to that number. The central service alone
  cannot reach it.
- **Approving anything.** A request is approved, limited to customers,
  rejected or disabled here.
- **Staying in.** Deactivating a user here ends the sessions at once, whatever
  the central service says afterwards.

The central service never sees this facility's data and is not told what the
facility decided.

## The identity token

A JWT signed by the central service.

| Part | Requirement |
|---|---|
| Header `alg` | `ES256`. Nothing else is accepted. |
| Header `typ` | `facility-identity+jwt`, exactly. |
| Header `kid` | The id of the signing key in the issuer's key set. |
| `iss` | The issuer. Compared with `CENTRAL_ISSUER` as an exact string. |
| `aud` | This facility's canonical origin (`SUPABASE_PUBLIC_URL`, for example `https://warehouse.example.com`) and nothing else: that string, or a list with that one entry. A token that also names another audience is refused. |
| `sub` | The central user id: 1 to 64 characters of `A-Z a-z 0-9 _ -`. |
| `phone_number` | `91` followed by ten digits. |
| `phone_number_verified` | `true`. |
| `iat`, `exp` | `exp - iat` is at most 600 seconds. Clock tolerance: 30 seconds. |
| `jti` | 16 to 128 characters of `A-Z a-z 0-9 _ -`. A `jti` is accepted **once**. |
| `name` | Optional text. Used for a new access request when the app sends no name; cleaned like a name typed before an SMS sign-in. |

A token for another facility, from another issuer, of another type, expired,
too long-lived, already used, or signed with a key the facility does not hold
is refused.

## Keys

The facility checks the signature against the issuer's public keys. Only
public `EC` / `P-256` signature keys that carry a `kid` are used. A key set
that names one `kid` twice is not used at all (the answer is
`central_keys_unavailable`): which key signs would be ambiguous.

The operator chooses one of two sources.

**An address** (`CENTRAL_JWKS_URL`). The facility fetches the key set: `https`
only, no redirects, a 5 second timeout, at most 64 KB.

- A fetched set is used for at most 10 minutes. It is held in the memory of
  the function's worker and is gone when that worker ends. The router creates
  workers with a 60 second timeout, so in practice the keys may be fetched
  about once a minute while sign-ins arrive. **How long a worker really lives
  has not been measured on the edge runtime.**
- A token that names a `kid` the facility does not hold causes a new fetch, at
  most once a minute, so a rotated key is picked up without anyone acting.
- After a fetch that failed, none is started for 30 seconds; central sign-in
  answers `central_keys_unavailable` meanwhile. These limits are per worker.

**A file** (`CENTRAL_JWKS_FILE`). The operator gives `setup.sh` a key set file
from the association; it is checked and copied into the installation
(`<state>/public/central-jwks.json`). The facility then **never** fetches
anything: a token that names a `kid` the file does not hold is simply invalid.

| | Address | File |
|---|---|---|
| Outbound connection from the facility | needed at sign-in time | none |
| The association rotates its keys | picked up automatically | the association must send every facility the new file **before** it signs with the new key; each operator reruns `setup.sh` with it. Until then central sign-in fails with "could not be verified"; SMS sign-in is unaffected. |
| The association withdraws a key | gone within 10 minutes | stays trusted until the operator installs a file without it |
| The issuer's site is down | central sign-in unavailable when the keys are next needed | no effect |

Choose the address unless the facility's server may not make outbound
connections or you do not want sign-in to depend on reaching the association.

## Endpoint

`POST /functions/v1/central-exchange`, public like `operator-otp` (the caller
has only the anon key).

```json
{ "identity_token": "<jwt>", "otp_code": "optional, six digits", "name": "optional", "display_name": "optional" }
```

`name` and `display_name` are used only when this exchange creates a new access
request. `otp_code` is used only for [linking an existing profile](#linking-an-existing-profile).
The answers have the shape of `operator-otp/verify`, plus a `code` on every
failure:

| Case | Status | Body |
|---|---|---|
| Approved, active profile | 200 | `{ "success": true, "data": { "action": "login", "user": {…}, "session": {…} } }` |
| Unknown person (request created), or request still pending | 200 | `{ "success": true, "data": { "action": "pending", "enrollment_token": "…", "expires_at": "…", "user": {…} } }` |
| Central login not configured here | 503 | `code: "central_unavailable"`, `error: "Central sign-in is not available at this facility"` |
| Token invalid in any way | 401 | `code: "invalid_identity_token"`, `error: "Sign-in could not be verified"` |
| Token already used | 401 | `code: "identity_token_used"`, the same `error` |
| Rejected or disabled profile | 403 | `code: "account_unavailable"`, `error: "Account unavailable"` |
| This phone has a profile here that is not linked yet, and no `otp_code` was sent | 409 | `code: "link_required"`, `error: "Confirm this phone number with a code from this facility to finish linking."` |
| `otp_code` was sent for such a profile and is wrong, expired or used up | 400 | `code: "invalid_otp"`, `error: "Invalid or expired OTP"` |
| Too many wrong codes from this address | 429 | `code: "rate_limited"`, `error: "Too many OTP requests. Try again later."` |
| This phone's profile is linked to another central identity | 409 | `code: "identity_conflict"`, `error: "This phone number is linked to another sign-in. Ask the facility administrator."` |
| Too many new access requests | 429 | `code: "enrollment_limited"`, `error: "Too many new access requests. Try again tomorrow."` |
| The issuer's keys cannot be fetched, or the key set or key file is unusable | 503 | `code: "central_keys_unavailable"`, `error: "Sign-in is temporarily unavailable. Try again."` |
| No JSON body with an `identity_token`, or an `otp_code` that is not six digits | 400 | `code: "invalid_request"` |
| The facility's database cannot be reached | 503 | `code: "unavailable"` |

Every reason for an invalid token gets the same message. The reason is written
to the functions log (`docker compose logs functions`), without the token, the
code and the identity it carried.

Every token that passes verification is spent by the call, whatever the answer
(also `link_required`, `invalid_otp` and `identity_conflict`). The app asks the
central service for a fresh token for each call.

The `session` is this facility's ordinary session (access token and refresh
token); it is refreshed, checked and revoked like one from an SMS sign-in. The
`enrollment_token` is read with `operator-otp/status` as today.

`GET /functions/v1/get-public-config` carries `centralLogin`: `{ "issuer": "…" }`
when central login is configured here with usable values, `null` when it is
not, so the app knows whether to offer it.

## How a profile is found

1. By the central identity `(iss, sub)` it is linked to. Such a profile is used
   even when its mobile number differs from the token's: the facility's record
   of the number is **not** changed, and the number is marked verified only
   when the two are equal.
2. Otherwise by the token's phone number.
   - A profile found this way that is linked to **another** identity is a
     conflict: `identity_conflict`, and nothing changes (a correct `otp_code`
     does not change that, and is not consumed).
   - A profile found this way that is **not linked** needs the facility's SMS
     code; see the next section.
3. Otherwise a new pending profile is created with the identity, under the
   same limit on new access requests as an SMS sign-in (3 per source address
   and 30 for the facility in 24 hours).

## Linking an existing profile

A person who already has a profile at this facility (enrolled with an SMS
code, or the administrator of the installation) links it to the central
account once, in two steps:

1. The app calls `central-exchange` with the identity token. The answer is
   409 `link_required`. Nothing has been written to the profile.
2. The app asks this facility for a code for that phone number
   (`POST /functions/v1/operator-otp/request`), the person reads it from the
   SMS, and the app calls `central-exchange` again with a **fresh** identity
   token and `otp_code`.

In step 2 the code is checked by the SMS sign-in itself
(`operator_verify_otp`), with all of its limits: five wrong attempts per code,
the per-address limit on wrong codes, the send limits of `operator-otp/request`.
Its answer is the answer:

- a correct code for an approved, active profile: the profile is linked and
  the answer is `login` with the session of that SMS sign-in;
- a correct code for a request that is still pending: linked, `pending`;
- a correct code for a rejected or disabled profile: `account_unavailable`,
  **not linked**;
- a wrong code: `invalid_otp`, not linked, and one attempt of the code is used.

After the link, every later exchange for that central account needs the token
only.

## What the facility administrator does

- **Approve or reject** a request: Enrollment Review, as for SMS sign-ins
  (`operator_review_enrollment`). Until then the person sees nothing.
- **Revoke**: deactivate the user (`update_user_status(false)`). The sessions
  are deleted at once and every later exchange answers `account_unavailable`.
  The central service is not involved and cannot undo it.
- **Resolve a conflict, or cut a link**: `clear_user_central_identity(user id)`,
  administrators only. It removes the link from the profile and signs the
  profile out, without changing its role, status or number. Afterwards:
  - linking the profile again, to the same or another central account, needs
    the facility's SMS code like any first link, so whoever receives SMS on
    the profile's number decides;
  - the central account that was removed is unknown here again. If it later
    presents a token for **another** phone number that has no profile, that
    is a new pending request like anyone's; the administrator judges it in
    Enrollment Review. Unlinking does not ban a central account.

  Use it when a person legitimately has a new central account. When a phone
  number has changed hands, correct or disable the profile first. The app has
  no screen for it yet; call the RPC as a signed-in administrator.

A person who deletes the own account (`delete_user_account`) gives up the link
together with the phone number and can ask for access again.

## What is stored

| Where | What |
|---|---|
| `public.user_profiles.central_issuer`, `central_subject` | The identity a profile is linked to. Both set or both empty; one identity belongs to one profile. |
| `warehouse_security.central_token_use` | One row per accepted token: the SHA-256 of `iss`, a space and `jti`, with the time after which the token is refused anyway. Removed when the next token is recorded and by `npm run retention:apply`. |
| `warehouse_security.auth_config`, key `central_issuer` | The trusted issuer. `public.operator_central_exchange` refuses every other issuer, also from a caller that holds the service key. Written by `setup.sh`. |
| `config/compose.env`: `CENTRAL_ISSUER`, `CENTRAL_JWKS_URL`, `CENTRAL_JWKS_FILE` | The operator's settings. |
| `public/central-jwks.json` in the state directory | The key file, when keys come from a file. Public keys only. **It is not part of a backup.** |

The token itself is never stored or logged. The table `public.central_user_links`
of an earlier design (migration 0) was never written and is dropped by
migration 51; the link is the two profile columns above.

## Operator settings

All empty by default. Central login is on when the issuer and exactly one key
source are set.

| Setting | Meaning |
|---|---|
| `CENTRAL_ISSUER` | The association's issuer, an `https://` origin or URL, exactly as the tokens name it in `iss`. |
| `CENTRAL_JWKS_URL` | The `https://` address of the issuer's public keys (JWKS). |
| `CENTRAL_JWKS_FILE` | `central-jwks.json` when the keys were installed from a file with `setup.sh --central-jwks-file`. |

Set, replace or remove them with `setup.sh`; see
[OPERATOR_INSTALL.md](OPERATOR_INSTALL.md#central-sign-in). The trusted issuer
in the database is written by `setup.sh`, so after restoring a database run
`setup.sh` again before relying on central login.

## Not built yet

- The central identity service itself (sign-in, token issuing, key set,
  facility catalogue). Until it exists nothing can produce a valid token; the
  tests make their own keys.
- The app: central sign-in, My facilities, the calls to this endpoint
  (including the two-step link), and an administrator screen for
  `clear_user_central_identity`.
- Binding a token to a device key (DPoP).

## Not tested

- Nothing here has run inside the edge runtime: the handler is tested under
  Node with its own keys, the database function in a disposable database. The
  router's reading of the key file, the mount of the state's `public/`
  directory into the functions container, and the lifetime of fetched keys in
  a worker are unmeasured.
- `setup.sh` has not been run end to end with the central options.
- Concurrent exchanges were not load-tested. Two exchanges for one phone or
  one central account are serialized by advisory locks, which is checked by
  reading the code, not under load.
