# Central login: the facility side

The association runs a central identity service that proves who a person is.
The app gets from it a short-lived signed token for **one** facility and hands
it to that facility. This document is the facility half of that contract: how
this backend checks the token and what it answers.

The overall design, the app screens and the open questions are in the app
repository's
[docs/CENTRAL_LOGIN.md](https://github.com/abhiguru/rn-warehouse-template/blob/main/docs/CENTRAL_LOGIN.md).

- The central service only proves identity. It never sees this facility's data
  and does not decide who may use it.
- This facility decides: an unknown person becomes a **pending access request**,
  an approved person gets this facility's **own session**, a rejected or
  disabled person is refused. That is exactly what a correct SMS code does.
- Local SMS sign-in (`functions/operator-otp`) is unchanged and keeps working,
  for the first administrator and for installations that are not members.

Central login is **off** until the operator configures the association's
issuer (see [Operator settings](#operator-settings)).

## The identity token

A JWT signed by the central service.

| Part | Requirement |
|---|---|
| Header `alg` | `ES256`. Nothing else is accepted. |
| Header `typ` | `facility-identity+jwt`, exactly. |
| Header `kid` | The id of the signing key in the issuer's key set. |
| `iss` | The issuer. Compared with `CENTRAL_ISSUER` as an exact string. |
| `aud` | This facility's canonical origin (`SUPABASE_PUBLIC_URL`, for example `https://warehouse.example.com`): that string, or a list that contains it. |
| `sub` | The central user id: 1 to 64 characters of `A-Z a-z 0-9 _ -`. |
| `phone_number` | `91` followed by ten digits. |
| `phone_number_verified` | `true`. |
| `iat`, `exp` | `exp - iat` is at most 600 seconds. Clock tolerance: 30 seconds. |
| `jti` | 16 to 128 characters of `A-Z a-z 0-9 _ -`. A `jti` is accepted **once**. |
| `name` | Optional text. Used for a new access request when the app sends no name; cleaned like a name typed before an SMS sign-in. |

A token for another facility, from another issuer, of another type, expired,
too long-lived, already used, or signed with a key the issuer does not publish
is refused.

## Keys

The facility fetches the issuer's public keys from `CENTRAL_JWKS_URL`:
`https` only, no redirects, a 5 second timeout, at most 64 KB. Only public
`EC` / `P-256` signature keys that carry a `kid` are used. The keys are kept in
the function's memory for 10 minutes. A token that names a `kid` the facility
does not hold causes a new fetch, at most once a minute, so a rotated key is
picked up within a minute of its first use.

## Endpoint

`POST /functions/v1/central-exchange`, public like `operator-otp` (the caller
has only the anon key).

```json
{ "identity_token": "<jwt>", "name": "optional", "display_name": "optional" }
```

`name` and `display_name` are used only when this exchange creates a new access
request. The answers have the shape of `operator-otp/verify`, plus a `code` on
every failure:

| Case | Status | Body |
|---|---|---|
| Approved, active profile | 200 | `{ "success": true, "data": { "action": "login", "user": {…}, "session": {…} } }` |
| Unknown person (request created), or request still pending | 200 | `{ "success": true, "data": { "action": "pending", "enrollment_token": "…", "expires_at": "…", "user": {…} } }` |
| Central login not configured here | 503 | `code: "central_unavailable"`, `error: "Central sign-in is not available at this facility"` |
| Token invalid in any way | 401 | `code: "invalid_identity_token"`, `error: "Sign-in could not be verified"` |
| Token already used | 401 | `code: "identity_token_used"`, the same `error` |
| Rejected or disabled profile | 403 | `code: "account_unavailable"`, `error: "Account unavailable"` |
| This phone's profile is linked to another central identity | 409 | `code: "identity_conflict"`, `error: "This phone number is linked to another sign-in. Ask the facility administrator."` |
| Too many new access requests | 429 | `code: "enrollment_limited"`, `error: "Too many new access requests. Try again tomorrow."` |
| The issuer's keys cannot be fetched | 503 | `code: "central_keys_unavailable"`, `error: "Sign-in is temporarily unavailable. Try again."` |
| The request has no JSON body with an `identity_token` | 400 | `code: "invalid_request"` |
| The facility's database cannot be reached | 503 | `code: "unavailable"` |

Every reason for an invalid token gets the same message. The reason is written
to the functions log (`docker compose logs functions`), without the token and
without the identity it carried.

The `session` is this facility's ordinary session (access token and refresh
token); it is refreshed, checked and revoked like one from an SMS sign-in. The
`enrollment_token` is read with `operator-otp/status` as today.

`GET /functions/v1/get-public-config` carries `centralLogin`: `{ "issuer": "…" }`
when central login is configured here, `null` when it is not, so the app knows
whether to offer it.

## How a profile is found

1. By the central identity `(iss, sub)` it is linked to. Such a profile is used
   even when its mobile number differs from the token's: the facility's record
   of the number is **not** changed, and the number is marked verified only
   when the two are equal.
2. Otherwise by the token's phone number. A profile found this way that has no
   central identity yet (it was enrolled with an SMS code) is **linked** to
   this identity. A profile that is linked to another identity is a conflict:
   the answer is `identity_conflict` and nothing changes.
3. Otherwise a new pending profile is created with the identity, under the
   same limit on new access requests as an SMS sign-in (3 per source address
   and 30 for the facility in 24 hours).

## What the facility administrator does

- **Approve or reject** a request: Enrollment Review, as for SMS sign-ins
  (`operator_review_enrollment`). Until then the person sees nothing.
- **Revoke**: deactivate the user (`update_user_status(false)`). The sessions
  are deleted at once and every later exchange answers `account_unavailable`.
  The central service is not involved and cannot undo it.
- **Resolve a conflict**: `clear_user_central_identity(user id)`,
  administrators only. It removes the link from the profile and signs the
  profile out, without changing its role, status or number. The next central
  sign-in with that phone number links the profile to the identity that
  presents it. Use it when a person legitimately has a new central account, or
  when a phone number has changed hands and you have first corrected or
  disabled the profile. The app has no screen for it yet; call the RPC as a
  signed-in administrator.

A person who deletes the own account (`delete_user_account`) gives up the link
together with the phone number and can ask for access again.

## What is stored

| Where | What |
|---|---|
| `public.user_profiles.central_issuer`, `central_subject` | The identity a profile is linked to. Both set or both empty; one identity belongs to one profile. |
| `warehouse_security.central_token_use` | One row per accepted token: the SHA-256 of `iss`, a space and `jti`, with the time after which the token is refused anyway. Removed when the next token is recorded and by `npm run retention:apply`. |
| `warehouse_security.auth_config`, key `central_issuer` | The trusted issuer. `public.operator_central_exchange` refuses every other issuer, also from a caller that holds the service key. |
| `config/compose.env`: `CENTRAL_ISSUER`, `CENTRAL_JWKS_URL` | The operator's two settings. |

The token itself is never stored or logged. The facility does not tell the
central service what it decided.

## Operator settings

Both are empty by default, and central login is off unless both are set.

| Setting | Meaning |
|---|---|
| `CENTRAL_ISSUER` | The association's issuer, an `https://` origin or URL, exactly as the tokens name it in `iss`. |
| `CENTRAL_JWKS_URL` | The `https://` address of the issuer's public keys (JWKS). |

Set, replace or remove them with `setup.sh`; see
[OPERATOR_INSTALL.md](OPERATOR_INSTALL.md#central-sign-in).

## Not built yet

- The central identity service itself (sign-in, token issuing, key set,
  facility catalogue). Until it exists nothing can produce a valid token; the
  tests make their own keys.
- The app: central sign-in, My facilities, the call to this endpoint, and an
  administrator screen for `clear_user_central_identity`.
- Binding a token to a device key (DPoP).
