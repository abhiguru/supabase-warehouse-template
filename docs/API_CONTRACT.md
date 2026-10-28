# Mobile/backend API coverage

The app and the backend are checked as a pair. CI's `contract` job checks out
the app at the pinned commit ([CONTRIBUTING.md](../CONTRIBUTING.md#mobile-companion-pin-mobile_ref)) and
runs the checker against it; locally, with the app checked out beside this
repository:

```bash
npm run check:contract -- ../rn-warehouse-template
```

(`check:contract` is `node scripts/check-mobile-contract.mjs`; `--live` also
compares overloads, SQL return types and effective grants against a running
database.) The checker parses the app's TypeScript calls to `.rpc()` and
`executeRPC()`, direct table calls, `functions.invoke()` and literal Edge URLs.
Comments and tests are excluded.

What it reports, for the pinned pair: the app's RPC names (none missing), its typed RPC calls with argument names
compared (no mismatches), its direct table names and its literal Edge Function names (none missing). Five dynamic RPC
calls (the name is in a variable: `src/config/supabaseConfig.ts`, `src/utils/serviceErrorHandler.ts`,
`src/services/stock-service.ts`, `src/services/sensor-service.ts`, and the template `delete_${kind}_image` in
`src/services/imageDeletion.ts`) are not checked. An older pin than the current one may still call a function that this release drops
(for example `get_dispatch_list`), so it must not be used.
`get-config` still publishes `urls.realtime` for older app builds that require it; it will be removed only in a release whose app-compat minimum excludes them. The printing functions (`print-grn-preprinted`, `print-dispatch-preprinted`, `print-invoice-preprinted`,
`print-via-ipp`, `get-printer-status`) exist and answer 503 "Printing is not configured" by design
(`functions/main/index.ts`); the app names the three preprinted ones through a variable, so they are not in the literal
count. `manage-print-jobs` is absent; the app does not call it. `get_print_jobs` and `cancel_print_job` (the print "View jobs" sheet) are open to admin, supervisor and staff since migration 123; customers and anon are refused.

The checker exits 1 only for a missing name or, with `--live`, a mismatch. Name presence is not signature, security or
behaviour validation, and a missing endpoint is never replaced with a success stub to make the check pass.

**Topics:** [Conventions, error shapes and tests](#conventions-error-shapes-and-tests); [Writes: refusals, version tokens, request codes and locks](#writes-refusals-version-tokens-request-codes-and-locks); [Users, roles and service accounts](#users-roles-and-service-accounts); [Customers](#customers); [Items, rates and pricing](#items-rates-and-pricing); [GRNs](#grns); [Dispatches and orders](#dispatches-and-orders); [Invoices and invoice data](#invoices-and-invoice-data); [Images](#images); [Sensors](#sensors).

Each topic's sections keep their original headings (and anchors); a section's migration number and date say when its rule arrived, and the rule itself is current unless a note says superseded.

## Conventions, error shapes and tests

How answers are shaped, what is tested, and what is deliberately not API. Migration numbers below 113 name the migrations that are now folded into the one baseline (`migrations/00000000000000_baseline.sql`); 113 and later are separate files. Migration 125 (load-test fixes: rewrites of the dispatch list, invoices list and customer invoice summary, new indexes, the next dispatch and GRN number lookups) changed no function signature and no answer, so it has no section.

### Error shapes

Refusals do not have one shape; each family has its own, and the app reads the one of the function it calls.
- **Customer functions** (migrations 112, 116, 117, 118): `{success:false, data:null, message, error:{code, field?, details?}}`.
  One exception: `set_customer_active` answers an uncoded `{success:false, message}` (an unknown id, a missing
  argument), except `DUPLICATE_MOBILE`, which carries `error:{code, field, details}`.
- **Dispatch, GRN, invoice and order writes** (`NUMBER_TAKEN`, migration 120; the refusals of migration 121): `{success:false, error_code:'WH409',
  reason, error, message, ...fields}`, the fields at the top level, `error` and `message` the same English sentence; the app switches on `reason`
  ([Review decisions](#review-decisions-migration-121-2026-10-20); the warning `POSSIBLE_DUPLICATE` of migration 124: [Possible duplicate](#possible-duplicate-migration-124-2026-10-21)). The legacy GRN length refusals keep `{success:false, error, error_code, data:{limit}, message}`.
- **Users, items, pricing and sensors:** a flat `error_code`. Users put the code in `error` too (`error` = the code, `message` = the text);
  items put the English text in `error` and the code in `error_code`. `delete_item_safe` sets `error_code` only on `NOT_FOUND`.

### The gateway's "upgrading" answer (maintenance mode; stable)

While an upgrade runs, or has stopped half way and left the API closed on purpose, **every request for `/rest/v1/`, `/storage/v1/` and
`/functions/v1/`** is answered by the gateway, on the public path and on the LAN path alike, before the key check and before anything reaches
a service, with HTTP **503**, the header `Retry-After: 120` and the body

```json
{"code":"upgrading","message":"The facility's server is being updated. Try again in a few minutes."}
```

The answer carries the CORS headers and `X-Warehouse-Path` like every answer the gateway makes. The CORS preflight (`OPTIONS`) is answered 204 as
always, so a browser can send the request whose answer it reads; `/health` is unchanged. `code` is the word to test (`upgrading`; it will not
change), `message` can be shown as it is. Do not sign the user out on it (a stale key is also answered 503 then, not 401), and do not retry faster
than `Retry-After`. Any other 503 from the gateway keeps the body `{"message":"The upstream server is unavailable"}` and has no `Retry-After`.
It lasts for the backup, its verification and the migrations of one upgrade ([OPERATOR_INSTALL.md](OPERATOR_INSTALL.md#rerun-and-upgrade), "While it
upgrades"). The edge functions' own 503 bodies (below and in [CENTRAL_LOGIN.md](CENTRAL_LOGIN.md)) are unrelated.

### Which app builds a release supports, and what the backend tells the app

**Policy.** A backend release supports the newest app release. An older build is told to update, not served by a compatibility
shim: `get-public-config` answers `minimumClientVersion`, and the app refuses to open a facility whose minimum is above its own
version ("requires app version ..."). Where a section below says an older app keeps working (an optional parameter that defaults as
before, a check that is skipped when the argument is absent), that describes behaviour kept for other callers such as fas-sync; it is
not a promise to older builds, and the policy decides.

`get-public-config` (no sign-in) answers, besides the fields of the instance manifest:

| Field | Where it comes from |
|---|---|
| `minimumClientVersion` | `app-compat.json` of the running release (`setup.sh` copies it to `<state>/public/app-compat.json`). It is no longer read from `instance.json`, which keeps the field for readers of older releases and is not used. A missing or malformed file makes the function answer 503; `setup.sh` writes it on every run. |
| `backendRelease` | `public/release.json`: the tag (or `git describe --tags --always`) of the checkout `setup.sh` ran from, `unknown` for a source archive without `.git`. `null` when the file is absent. |
| `schemaHead` | `public/release.json`: the name of the newest applied migration. `null` when the file is absent. |
| `version` | `api_configurations.app_version`, seeded `0.2.0` and not updated by releases. Do not use it as the backend's version. |

`get-config` (signed in) reports the same `backendRelease` as `data.environment.backendRelease`. `release.json` holds, besides those two,
`backendCommit` and `writtenAt`; it is not part of a backup and a restore never brings it back (`setup.sh` and `restore.sh` write it
again for the checkout they run from, so it is right after a rollback too). `backendRelease` and `schemaHead` are public: `get-public-config` needs no
sign-in, so anyone who can reach the facility can read which release it runs.

### What the app may match: codes, not texts

Every refusal the app reacts to, as the real REST service (the pinned PostgREST image) answers it. `tests/postgrest-contract.test.mjs`
runs each row against that service in `npm run test:migrations`; a change that moves a status or a code fails there. **Code** means the
app may rely on the code (a client should switch on the code and show its own words); **text** means the app still matches the English
words of the message today. Those words must not change until the app's next release stops matching them, and a new client should not.

| Case | Status | Code | Message | The app matches |
|---|---|---|---|---|
| `unknown-function` | 404 | `PGRST202` | Could not find the function public.NAME without parameters in the schema cache | code |
| `unknown-parameter` | 404 | `PGRST202` | Could not find the function public.NAME(PARAMETER) in the schema cache | code |
| `unknown-table` | 404 | `PGRST205` | Could not find the table 'public.NAME' in the schema cache | code |
| `unknown-column` | 400 | `42703` | column TABLE.NAME does not exist | code |
| `bad-uuid` | 400 | `22P02` | invalid input syntax for type uuid: "VALUE" | code |
| `jwt-expired` | 401 | `PGRST303` | JWT expired | text |
| `jwt-wrong-key` | 401 | `PGRST301` | No suitable key or wrong key type | code |
| `jwt-garbage` | 401 | `PGRST301` | JWT cryptographic operation failed | code |
| `anon-denied` | 401 | `42501` | permission denied for function NAME | code |
| `session-revoked` | 403 | `42501` | Session expired or revoked | text |
| `account-inactive` | 403 | `42501` | Session expired or revoked | text |
| `staff-required` | 403 | `42501` | Staff access required | text |
| `administrator-required` | 403 | `42501` | Administrator required | text |
| `customer-denied` | 403 | `42501` | Customer access denied | text |
| `read-only-get` | 405 | `25006` | cannot execute INSERT in a read-only transaction | code |

Answers that are an HTTP 200 with an envelope (see [Error shapes](#error-shapes)):

| Case | Envelope | The app matches |
|---|---|---|
| `wrapped-refusal` | a guard refusal inside a function that wraps errors, such as `update_user_role`: `{success:false, error_code:'INTERNAL_ERROR', message:'Failed to update user role: Administrator required'}` | text |
| `report-refusal` | report functions such as `get_customer_grn_activity`: `{success:false, error_code:'42501', error:'Failed to retrieve ...: Customer access denied'}` | code |
| `duplicate-item-name` | `create_item` and `update_item`: `{success:false, error_code:'DUPLICATE_NAME', error, message}` | code |
| `duplicate-customer-name` | `create_customer` and `update_customer`: `{success:false, error:{code:'DUPLICATE_NAME', field:'name', details}, message}` | code |

The gateway answers a missing API key `401 {"message":"No API key found in request"}` and a wrong one `401 {"message":"Unauthorized"}` (`docker/nginx/`); after
`scripts/rotate-keys.sh` an installed app reads "Unauthorized" to end its session and reload the configuration, so these two words are text the app matches.
"Active account required" is the guard's word for a caller with no active role; over HTTP the session check answers first with `Session expired or revoked`
(the `account-inactive` row), so the sentence is reached only inside the database. The test checks that `authorize_rpc` still says all four guard texts
(`Staff access required`, `Administrator required`, `Customer access denied`, `Active account required`).

### Tested runtime behaviour

CI's install job runs four operator fixture drivers against a fresh installation (`operator-api-core.mjs`,
`operator-api-final.mjs`, `operator-api-rotation.mjs` and `operator-api-restore.mjs`; see
[DEVELOPER_HANDOFF.md](DEVELOPER_HANDOFF.md)). `npm run test:migrations` tests the database itself: real roles, effective
grants and the role policy of every granted function.

The customer-item selector has one six-argument RPC; it returns `{ success, data: [], pagination }`.

The four PDF functions return the mobile contract:
`{ success, pdf_url, expires_in, document }`. Their layouts are generic starter
documents, not the original company's branded/preprinted forms. All business
reads use the caller's JWT/RLS; only subsequent private PDF upload uses the
server key.

The imported schema includes unexposed internal/legacy/admin functions.
Do not grant blanket API execution to make an unsupported call work.
See [PRODUCTION_DEPENDENCIES.md](PRODUCTION_DEPENDENCIES.md) for the remaining business, Storage and native acceptance.

### Legacy and dormant functions

There is no accounting integration (migration 71 removed the unused Tally one, with the dead baseline functions that
nothing called). Recorded payments remain: the `payments` table and its policies drive Paid and Pending in
`get_customer_invoice_summary` and `get_customer_activity_detail`. The app does not write payments; only the service role
or the database owner does. A future accounting integration starts from a new design.

The baseline still holds other functions that are not granted to `anon` or
`authenticated`. They are not API: do not grant one to make a call work; add a
guarded RPC in a new migration instead.

The five printing functions (`print-grn-preprinted`, `print-dispatch-preprinted`,
`print-invoice-preprinted`, `print-via-ipp`, `get-printer-status`) answer 503
from the router until printing is accepted ([PRINTING.md](PRINTING.md),
"Activation acceptance").

### Removed in migration 123 (2026-10-21) and the public configuration

`tests/rpc_callers_exist.sql` lists every function the app, the edge functions and fas-sync call and proves it exists after all
migrations. About 115 functions that nothing called are dropped (116 `DROP FUNCTION` statements, overloads counted), among them (their entries elsewhere in this file are history, marked "removed in 123"):

- `save_invoice(jsonb)` (the one-argument form; `save_invoice(uuid, jsonb, jsonb[])` is the only save path) and the unused
  `get_invoiceable_grns(integer, integer)` overload;
- `create_item_storage_price`, `update_item_storage_price` (both overloads), `delete_item_storage_price` and
  `find_or_create_item_storage_price`: rates are written by `replace_item_rates`, `set_standard_rate` and the GRN `p_rates`;
- `get_cart_dispatches`, `get_item_dispatch_records`, `get_item_grn_rates(p_item_id)` (`get_grn_item_rates(p_grn_id)` stays),
  `recalculate_invoice_items` and `update_order_metadata`;
- the table `sensor_health_events` and 15 other empty tables, 8 views, 12 columns and 13 indexes. The migration refuses to run if
  one of those tables or columns holds data (it names each and says to export or empty it first).

`build_invoice_recalculation_rows` stays (tests and the lot-rate reader use it). The invoice-save path, `create_dispatch_with_stock_check`
(four-argument form, called by fas-sync) and `trg_restore_stock_on_dispatch_delete` are kept on purpose.

**`get_public_config(p_environment text)`** returns `json {app_version, maintenance_mode, feature_flags}` (`feature_flags` an object of
name to enabled), or NULL when the environment has no active row (the edge function `get-public-config` then answers 503, "not
seeded"). It is the one RPC callable by `anon` (and `service_role`): it is a narrow read of `api_configurations` and `feature_flags`,
so the function no longer holds the service-role key. Like `check_session` and `refresh_jwt_token`, it is the exception to "every
RPC calls `authorize_rpc` first". It does not exist before migration 123, so `get-public-config` answers 503 between the code update and
the migration.

`/rest/v1/` serves no OpenAPI document and exposes only the `public` schema (`PGRST_DB_SCHEMAS=public`, `PGRST_OPENAPI_MODE=disabled`).

### List freshness (migration 106, 2026-10-19)

Every list RPC reads the tables, so a write that has committed is in the next list read: there is no
refresh job and no delay. `get_list_freshness()`, the legacy `get_dispatch_list` and the `get_all_grn_items(p_catalog_id, ...)`
overload no longer exist (migration 106). `get_invoices_list`
keeps its arguments, sorts, filters and answer; rows that tie on every sort key now come back in a fixed order
(by invoice id). The answer of a write RPC (`save_grn`, `update_grn`, `create_dispatch_with_stock_check`,
`update_dispatch_smart`, `save_invoice`, `update_invoice`, ...) is still the authoritative result of that
write.

### Sessions: the refresh lifetime and the break-glass code (migration 126, 2026-10-26)

No function changes its arguments or the shape of an answer; the app needs no change. What changed is how long a refresh token's session lasts and one more code that `operator-otp/verify` accepts.

- **Session lifetime.** `refresh_jwt_token` and the sign-in answers (`operator_verify_otp`, `operator_central_exchange`) return the same fields as before (`access_token`, `expires_at` and `expires_in` of the access token, `refresh_token`; the refresh token's own end is not an answer field and the app does not read it). A session of an active, approved profile now ends `session_idle_seconds` (default 30 days) after its last refresh, never later than `session_max_seconds` (default 90 days) after sign-in; before, it ended 7 days after sign-in whatever the use. Any other active profile keeps the fixed 7 days. A refresh of a session past its absolute end answers by raising `Session expired` (`P0001`), the definitive answer the app already treats as "sign in again" (`isDefinitiveRefreshException`); every other rejection is still the data answer `{success:false, message:'Invalid refresh token'}`. Switching a user off (`update_user_status(false)`) deletes their sessions as before. Operator view and the two keys: [OPERATOR_INSTALL.md](OPERATOR_INSTALL.md), "Authentication and OTP limits", Sessions.
- **Per-source limits.** The answers of `operator-otp/request` and `/verify` are unchanged (429 "Too many OTP requests. Try again later."); the two limits per address (30 requests, 20 failed verifications an hour) are now `auth_config` keys, and a listed address gets more requests ([OPERATOR_INSTALL.md](OPERATOR_INSTALL.md), "The facility's own Wi-Fi address").
- **Break-glass code.** `operator-otp/verify` (`operator_verify_otp`) also accepts a six-digit code the operator made for an active administrator with `scripts/break-glass-admin.sh`: the same request, the same `{success:true, data:{action:'login', user, session}}` answer, and `invalid_otp` (400 "Invalid or expired OTP") for a wrong, used, expired or ended code. While such a code is open for the number, `operator-otp/request` answers `{success:true, ...}` ("OTP sent successfully") even when the SMS provider refuses the request (otherwise 503 "SMS delivery unavailable"), so the app reaches its code screen. `public.operator_break_glass_open(p_phone_number)` (service role only) is what the edge function asks; the function that makes a code, `warehouse_security.break_glass_code`, is for `supabase_admin` alone and is not an API.

### The LAN address in `get-config` (`urls.lan`, 2026-10-26)

`get-config` (signed-in users only) carries one more field in `data.urls` while the operator has the LAN fallback on
(`bash scripts/lan.sh on`, [OPERATOR_INSTALL.md](OPERATOR_INSTALL.md#lan-fallback-plain-http-on-the-warehouse-network)):

```json
"urls": { "api": "...", "storage": "...", "auth": "...", "lan": "http://192.168.1.20:8080" }
```

- **Optional.** `urls.lan` is absent while the fallback is off, and also when the configured address is not a private IPv4 address or
  the port is invalid (a damaged value is left out, never offered). A client treats a missing `urls.lan` as "no fallback" and removes
  an address it saved earlier (and any address typed in Settings).
- **`get-public-config` never has it.** That answer is readable by anyone on the internet; the facility's LAN address is for its own
  signed-in users. A client refreshes the saved address from every successful `get-config`, which also comes back over the LAN path.
- **Format.** `http://<IPv4 in 10/8, 172.16/12 or 192.168/16>:<port>`, the port always explicit (1024-65535), no path, no trailing slash.
  Validate it on the client with the same rule (`functions/_shared/lan-url.ts`) and refuse anything else, a typed address included.
- **Plain http, by owner decision (2026-10-26).** It is an origin with no path. It serves the same `/rest/v1`, `/storage/v1` and
  `/functions/v1` routes as the public origin. A client uses it only after a transport failure of the public path (the request is
  rejected, no answer in time, or HTTP 530 from Cloudflare), never when the public path works, and never resends a write that may have
  been applied (the lost-answer rule, [Request codes](#request-codes-and-get_submission_result-owner-decision-d22-one-rule-for-a-lost-answer)).
  Tokens and signed URLs are the same on both paths, and the identity of the installation (`instanceId`, the canonical origin, the
  token store key and the client URL) stays the public origin: the transport rewrites only scheme, host and port and keeps path and query,
  also in URLs the server hands out (storage signed URLs, the `pdf_url` of the PDF functions, which are built on the canonical host).

#### What the client does with the LAN path (the hand-off for the app; stable)

These are the rules the server is built to and tested against. `urls.lan`, the `X-Warehouse-Path` header and the status codes below
are stable: they are the interface, and a change to them is announced here.

1. **Which path answered.** The response header `X-Warehouse-Path` is `lan` or `public` on every answer the gateway makes: success and
   401/403/404/413/429/502/503/504, and the preflight. Answers that Cloudflare makes (530, 52x) do not carry it; a public-path error
   **without** the header is a Cloudflare or tunnel failure, not the server. The LAN `403` (an HTML page, not JSON) carries it.
2. **Probe before sending credentials to the LAN origin.** `GET <lan>/functions/v1/get-public-config` with no `Authorization` header.
   Accept the path only if the status is 200, `X-Warehouse-Path: lan` is present, and `data.instanceId` equals the saved
   `OperatorServer.instanceId`. Liveness only: `GET <lan>/functions/v1/hello` (public, 200, body `"Hello from Edge Functions!"`).
   Both count against the functions bucket (100 at once, then one every 0.6 s, per phone). The body's `canonicalOrigin` is the public
   https origin: do not apply the bootstrap origin-equality check to the LAN origin. The request must carry the host the way the URL
   writes it (`Host: <address>:<port>`, which any HTTP client does by itself): see the status codes.
3. **Check it while the internet is up.** While the phone is on Wi-Fi and the public path works, the app is to probe the saved LAN
   address (item 2, no credentials) about once a day and to show "reachable", "refused" or "unreachable" in Settings, so a wrong range,
   client isolation or a stale address shows before the outage and not during it. The server asks nothing more for this than to keep
   `urls.lan` and `X-Warehouse-Path` stable.
4. **The address can change** (DHCP). The probe is also what stops a phone from sending tokens to whichever device now holds an old
   address. The operator reads the current address with `bash scripts/lan.sh status` or `node scripts/doctor.mjs --local`
   (`LAN address for the app: http://...`).
5. **Status codes specific to the LAN path.**
   - `403` with `X-Warehouse-Path: lan` (nginx's HTML page): this phone's address is outside the allowed range. The LAN is unusable from
     this network. Do not retry in a loop.
   - `404` with `X-Warehouse-Path: lan` and the JSON body `{"message":"no Route matched with those values"}` on a path that exists on the
     public origin: the request carried another `Host` than the server's own address (the listener is pinned to it). The client used a name
     or another address for it. Treat the path as unusable.
   - Connection refused or a timeout: the listener is down or the address is stale. The LAN is unusable.
   - **`401` with a gateway key message (`{"message":"Unauthorized"}` or `{"message":"No API key found in request"}`) received over the LAN
     path: mark the LAN path unusable and do not end the session.** Ending the session is right only on the public path. Over the LAN it
     means the `gateway-lan` container holds other keys than the installation (after `rotate-keys.sh`, until it is recreated), and
     sign-in needs the internet, so signing the phone out would leave it unable to work until the line is back.
   - `429` and 5xx are answers from the server, not transport failures: they do not trigger a switch of path.
6. **Limits on the LAN path are per phone**: REST is a burst of 1800, then 30 a second; functions a burst of 100, then one every
   0.6 s. `429` carries `Retry-After: 1`.
7. **Sign-in.** `central-exchange` goes over the public path only. **`operator-otp` (`request` and `verify`) may go over the LAN path, for
   an administrator's break-glass sign-in during an outage:** with no internet the SMS provider cannot be reached, and while the operator has
   made a break-glass code for the number, `operator-otp/request` answers the normal success body ("OTP sent successfully") even though no
   SMS was sent, as in the break-glass item above, so the app reaches its code screen; any other number gets 503 "SMS delivery
   unavailable". The request can take up to 10 seconds to answer in that case (the provider call has a 10-second limit). The code
   is typed in clear on the Wi-Fi (valid 10 minutes, once). The refresh RPC (REST) may use the LAN path.
8. **Writes** are never resent after a transport failure or a switch of path (the lost-answer rule above).

## Writes: refusals, version tokens, request codes and locks

Rules shared by the dispatch, GRN, invoice and order writes. History: migrations 120, 121 and 124 (2026-10-20 and 21).

### Order, dispatch, GRN and invoice review fixes (migration 120, 2026-10-20)

Same signatures and grants as before (one new RPC, `get_submission_result`). Every new answer field and request option is
optional: an app that does not read or send it works as before.

### Review decisions (migration 121, 2026-10-20)

Server side of the owner decisions D1 to D18, D23 and D24 on dispatch, GRN, invoice and order writes. Every new request key and
trailing parameter is optional (absent: no check, the call behaves as before); every new answer field is optional to read. `fas-sync`
sends no version token, so D1 never refuses it; its date pushes go through D3 (and D23), its weight pushes through D2, and it never
sends a GRN number on an edit (D6).

### One refusal envelope

Every new refusal has the shape of `NUMBER_TAKEN`, plus `message`; its fields are top-level keys:

```
{ "success": false, "error_code": "WH409", "reason": "<CONSTANT>", "error": "<English sentence>", "message": "<same sentence>", ...fields }
```

The app switches on `reason`, not on the English. It is built by `warehouse_security.refuse(reason, text, fields)` (not granted to any
app role). A refusal is returned before the function's first write. The refusals that can only be known after a write (`RATES_NEED_MANAGER`,
`RATES_WOULD_DROP`, `TOTAL_CHANGED`) are raised as `rate_fail` with the refusal in `DETAIL`; the handler of `update_grn`, `update_invoice`
and `save_invoice_internal` rolls the whole block back and answers it (nothing is saved). The three legacy length refusals of the GRN
(`item_name_too_long`, `packaging_too_long`, and new `registration_too_long`) keep the older shape `{success:false, error, error_code, data:{limit, index?}, message}`.

| `reason` | Returned by | Fields (top level) | English `error` |
|---|---|---|---|
| `STALE_RECORD` | `update_dispatch_smart`, `update_grn`, `update_invoice`, `update_order_item_quantity`, `remove_item_from_order` | `what` (`dispatch`, `grn`, `invoice`, `order_line`), `id`, `expected_updated_at`, `current_updated_at` | Someone else changed this {dispatch / GRN / invoice / order line}. Open it again. |
| `LOT_INVOICED` | `update_grn` | `line_id`, `item_name`, `invoice_no`, `inv_fin_year`, `fields` (list of `item`, `packaging`, `weight`) | {item} is on invoice {no}. Item, packing and weight can't be changed. Delete or edit the invoice first. |
| `LOT_DISPATCHED` | `update_grn` | `line_id`, `item_name`, `fields` (`item`, `packaging`) | {item} has been dispatched. Its item and packing can't be changed. |
| `DISPATCH_INVOICED` | `update_dispatch_smart` | `dispatch_no`, `invoice_no`, `inv_fin_year`, `fields` (`disp_date`, `disp_no`) | Dispatch {no} is on invoice {inv}. Its date and number can't be changed. Delete or edit the invoice first. |
| `DISPATCH_DATE_FUTURE` | dispatch create, `update_dispatch_smart` | `date`, `today` (IST day, `YYYY-MM-DD`) | A dispatch can't be dated in the future. Today is {today}. |
| `DISPATCH_BEFORE_GRN` | dispatch create, `update_dispatch_smart` | `date`, `gr_no`, `grn_date` (the latest GRN day among the lots) | The dispatch date {date} is before GRN {gr_no} ({grn_date}). |
| `GRN_DATE_AFTER_DISPATCH` | `update_grn` | `gr_no`, `date`, `first_dispatch_date`, `dispatch_no` | GRN {gr_no} can't be dated {date}: dispatch {no} took goods from it on {first}. |
| `GRN_DATE_LOCKED` | `update_grn` | `gr_no`, `date`, `invoice_no`, `inv_fin_year` | This GRN is invoiced. Delete or edit the invoice first. |
| `ORDER_CHANGED` | dispatch create | `source_order_id`, `expected_updated_at`, `current_updated_at` | This order changed after you opened it. |
| `GRN_NUMBER_LOCKED` | `update_grn` | `gr_no` (stored), `requested` | The GRN number can't be changed. Delete the GRN and enter it again. |
| `GRN_HAS_STOCK` | `save_invoice` (both signatures), `update_invoice` | `gr_no`, `stock` (sum of the lots' stock), `lots` (lots with stock) | GRN {gr_no} still has {stock} in stock. Dispatch it first, then make the invoice. |
| `GRN_INVOICED` | `update_grn` | `gr_no`, `invoice_no`, `inv_fin_year` | GRN {gr_no} is on invoice {no}. A line can't be added. Delete the invoice first. |
| `RATES_NEED_MANAGER` | `update_grn` (staff only) | `gr_no`, `rates` (count dropped), `items` (their item names) | Ask a manager to make this change: it would remove a rate that was set for this GRN. |
| `RATES_WOULD_DROP` | `update_grn` (administrators and supervisors) | `gr_no`, `rates` (count), `items` | This change removes the rate set for this GRN. Set a new rate in Rates. |
| `LINE_ON_ORDER` | `update_grn` | `line_id`, `item_name`, `customer_name` | {item} is on {customer}'s order. Remove it from the order first. |
| `LINE_DISPATCHED_BEFORE` | `update_grn` | `line_id`, `item_name` | {item} was dispatched before, so this line can't be removed. |
| `TOTAL_CHANGED` | `save_invoice(uuid,jsonb,jsonb[])`, `update_invoice` | `current_total`, `expected_total`, `lines` (`[{disp_trl_id, duration, no_of_days}]` as the server recomputed them) | The total is now {current}, not {expected}. Review the figures and save again. |

`invoice_no` is the integer invoice number of the live invoice (the first by financial year and number); the app writes it in its own
form. Order RPCs still answer `{success:false, message, error:{code:'ORDER_NOT_OPEN'}}` when the order is not open; the new order
refusals carry `error` as a string.

### The version token (D1, `STALE_RECORD`)

The token is the row's `updated_at`: `dispatch.updated_at`, `goodsreceived.updated_at`, `order_items.updated_at` (all bumped by their
existing `BEFORE UPDATE` triggers) and the new `invoice.updated_at` (`NOT NULL DEFAULT now()`, trigger `trigger_invoice_updated_at`;
every existing invoice has the migration time until it is edited; the app role has no column grant on it, it is read only through the
RPCs). The caller sends the string it read, unchanged:

- `update_dispatch_smart`: `p_dispatch_data->>'expected_updated_at'`. `update_invoice`: `p_invoice_data->>'expected_updated_at'`.
- `update_grn`, `update_order_item_quantity`, `remove_item_from_order`: a new last parameter `p_expected_updated_at timestamptz DEFAULT NULL`
  (the old signatures are dropped; a call without it, by name or by position, still works). A call that names it on a server without
  migration 121 fails with PGRST202: the app repeats it without the parameter.

Compared to the millisecond (`date_trunc('milliseconds', ...)`), so a JavaScript `Date` round trip survives. An absent or NULL token:
no check. A token against a NULL stored value is stale. Nothing is written for a refusal. **Where it runs:** after the saved-answer
replay of a request code (D22), so a resend of one's own lost save is never refused: `update_dispatch_smart` right after the row lock
and "Dispatch not found"; `update_grn` inside the block after lock 71040, with the GRN row now locked (`FOR UPDATE`) and after its
idempotency lookup; `update_invoice` on its first read, which now locks the live invoice; `update_order_item_quantity` and
`remove_item_from_order` after the line's row lock and "Order item not found", before the order-not-open check (they take no
advisory lock). Every success answer carries the new token: `update_dispatch_smart` top-level `updated_at`; `update_grn`
`grn.updated_at`; `update_invoice` top-level `updated_at`; `update_order_item_quantity` and `add_item_to_order` `data.updated_at`
(the line's). `get_dispatch_details` (`data.dispatch.updated_at`) and `get_order_with_items` (`order_data.updated_at`, `items[].updated_at`)
already returned theirs; `get_invoice_detail` returns it as `invoice.updated_at` and `get_invoice_data` as `data.header.updated_at`.

Known and accepted: any write to the row bumps the token, so a dispatch that empties a lot (it flips `goodsreceived.out_of_stock`)
makes an open edit of that GRN stale, and after a lost answer the user's own retry reads as stale unless its request code replays first.

### Locks after dispatch and invoice (D2, D23)

A lot is *dispatched* when `dispatch_trl` rows point at it, *invoiced* when one of those lines is on a live invoice. `update_grn`,
per listed line that has an `id`, before any write, and only where a value really differs from the stored one (item = `item_id`;
packaging compared as `COALESCE(x,'')`; weight as `COALESCE(x,0)`): an invoiced lot whose item, packaging or weight changes is
`LOT_INVOICED` (the first offending line in the order sent, `fields` all its changed fields); else a dispatched lot whose item or
packaging changes is `LOT_DISPATCHED`. A dispatched lot keeps its stored `item_name` (the edit does not overwrite it); its weight and
the GRN date stay editable unless it is invoiced. D23: the GRN date of an invoiced GRN (a live invoice, or `invoiced` set) is locked:
a day (IST) that differs from the stored one is `GRN_DATE_LOCKED`; the same day sent back, at any time, is not a change.
`update_dispatch_smart`: when a line of the dispatch is on a live invoice and the request changes the date or the number it answers
`DISPATCH_INVOICED`. "Changed": `disp_no` differs from the stored text; the day sent (a date) differs from the IST day of the
stored `disp_date`; the UTC day plays no part (a legacy row with an odd time of day is not changed by the app sending its own day). Other header fields stay editable.

### Date rules (D3, IST days)

Dispatch create, after the deleted-lots check and before the stock check: a day after today is `DISPATCH_DATE_FUTURE`; a day before the
GRN day of any listed lot is `DISPATCH_BEFORE_GRN` (the latest GRN day and its number are reported). `update_dispatch_smart`, before the
header update: the same two checks when the day is changed (then against every line after the edit, or the present lines when no list
is sent), and with an unchanged day only the before-GRN check against the lines the edit adds; a legacy back-dated or future dispatch
therefore stays editable. A request without `disp_date` is not checked. `update_grn`: a `p_date` whose IST day differs from the stored
one and is later than the IST day of the earliest live dispatch line of any lot is `GRN_DATE_AFTER_DISPATCH`.

### `NUMBER_TAKEN`

A dispatch or invoice number that another document holds is answered by name, before anything is written, instead of the raw
unique-key error (SQLSTATE `23505`):

```
{ "success": false, "error_code": "WH409", "reason": "NUMBER_TAKEN", "number": "<the number>", "error": "<English text>" }
```

From `create_dispatch_with_stock_check` (`dispatch_disp_no_key`, checked over all rows, deleted ones too), `update_dispatch_smart`
(a number another dispatch holds), `save_invoice` (both signatures) and `update_invoice` (`unique_inv_no_per_year`, within the
financial year; an invoice that keeps its own number is not refused). The invoice answers of the three-argument path also carry
`function_version`. `save_grn` already refuses a duplicate GRN number by name and is unchanged. The answer has no `holder`.

### Document numbering (migration 127, 2026-10-27)

Each facility has one numbering rule per document type (`warehouse_security.document_numbering`, no direct grant: only these RPCs read or write it;
every change is kept in `document_numbering_history`). A rule is `{scheme, prefix, width, start, first_letter, per_letter, check}`; `check` (boolean) says whether a number outside the rule is refused on save (below):

| scheme | number | takes |
|---|---|---|
| `letters` | `A0001` ... `A1000`, `B0001` ... (GRN and dispatch) | `first_letter` (default `A`; `W` or `X` follows FAS: W, X, Y, Z, A, B ...), `width` (4, 1 to 7), `per_letter` (1000) |
| `year` | `GRN/26-27/0001`, starting again on 1 April (GRN and dispatch). For an invoice: a whole number that starts again every financial year | `prefix` (up to 10 of `A-Z 0-9 / -`), `width` (4), `start` (1). An invoice takes `start` only |
| `sequence` | `I0001`, or `1001` with no prefix. For an invoice: a whole number that keeps counting across years | `prefix`, `width`, `start` |
| `free` | any text of up to 20 characters, typed by hand (GRN and dispatch) | nothing |

Defaults, all with `check` true except where the migration found a number of the type that does not follow the rule it starts with (then that type starts with `check` false and the migration prints how many): GRN `letters` (from `W` where the facility held both W and X numbers when the migration ran, from `X` where it held X, Y or Z numbers), dispatch `sequence` with prefix `I`,
invoice `year`. Numbers have at most 20 characters (`gr_no` and `disp_no` are `varchar(20)`), and at most 7 digits after the prefix; a sequence ends at 9999999.

- `suggest_document_number(p_document_type text, p_date date DEFAULT NULL)`: `grn`, `dispatch` or `invoice`; staff and above. Answers
  `{success:true, number, hint, scheme, reason}`. `hint` is the pattern for the placeholder (`A####`, `GRN/26-27/####` with the year of `p_date`, `I####`, `#`; null for `free`).
  `number` is null with `reason` `TYPE_IT` (free text: the person types it) or `SERIES_FULL` (no number is left: all letters used, the digits no longer fit 20 characters,
  9999999 reached, or for an invoice the ceiling of 99999999).
  The order of the letters always starts after the longest run of unused letters, counted around the alphabet (so a facility whose books run W, X, Y, Z, A is offered A0258 after A0257 whether its rule says W, X or A,
  and a stray letter far from the series, such as Q0001, does not take the suggestion over; with a series that runs W to A, one between B and K can, and so can one at L when the rule says W). Of two runs of the same length (the L case) the
  one nearer `first_letter` wins; with no letter in use, or all 26, the order starts at `first_letter`. The suggestion is the same whether `check` is true or false. A suggestion reserves nothing: two phones are offered the same number and the second save is refused by
  name (`GRN number already exists`, `NUMBER_TAKEN`). Under a `year` rule the number depends on `p_date`: ask again when the date crosses 1 April.
- `get_document_numbering()`: administrators and supervisors. `{success:true, rules:[{document_type, scheme, prefix, width, start, first_letter, per_letter, check, fy_reset, hint, existing_documents, not_following, updated_at, updated_by}]}`
  in the order grn, dispatch, invoice; `existing_documents` counts the live documents that keep their numbers when the rule changes; `not_following` counts the numbers (deleted documents included) that do not follow the rule (always 0 for an invoice).
- `set_document_numbering(p_document_type text, p_rule jsonb)`: administrators (`Administrator required` for anyone else). A field left out takes its default; a field that does not
  belong to the scheme, a wrong value or a rule that does not fit 20 characters is raised as SQLSTATE `22023` with a sentence that says what to change. `check` (true or false) is allowed in a `letters`, `year` or `sequence` rule of a GRN or dispatch; left out, it stays as stored
  (a `free` rule has `check` true, and the rule after it starts with it true). It is refused for an invoice and for `free`. Switching `check` on where existing numbers do not follow the rule is allowed: they keep their numbers, and `not_following` says how many they are (show it in the confirm step). Answers
  `{success:true, changed, document_type, rule, previous_rule, existing_documents, not_following, next_number, hint, reason}` (`rule` and `previous_rule` carry `check`); the same rule again changes and records nothing, and a change of `check` alone is a change and is recorded. Existing numbers never change.
- `get_next_grn_number()`, `get_next_dispatch_number()` and `get_next_invoice_number(p_fin_year)` keep their signatures and return the suggestion's number. Where there is none they
  raise: `Type the GRN number.` (`free`, SQLSTATE `WH409`), `All GRN numbers A0001-Z1000 are used` (`WH409`), `Dispatch number sequence exhausted at I9999999` (`22003`, as before),
  `No invoice number is left in financial year N` (`WH409`, as before; `No invoice number is left` under a `sequence` rule, which counts across years).
- `NUMBER_FORMAT`: with `check` true, `save_grn`, `create_dispatch_with_stock_check` and `update_dispatch_smart` (only when the number is changed; the stored number may be sent back) answer a number that does not
  follow the rule with `{success:false, error_code:'WH409', reason:'NUMBER_FORMAT', number, document_type, pattern, error, message}` and write nothing. The message is
  `This number does not follow this facility's numbering (<pattern>)`; for `free`, and for any rule whose `check` is false, a number of more than 20 characters is refused with `This number can have at most 20 characters` and `pattern` null; with `check` false nothing else is refused (the duplicate check stays).
  The check comes before the duplicate check and is not made for an empty number (its own answer stays). A `letters` rule accepts any capital letter followed by at least `width` digits,
  whatever its first letter; a `year` rule accepts its prefix, two consecutive years (`26-27`, not `26-28`) and the digits, whichever year the date is in. An invoice number is a whole number
  from 1 to 99999999 whatever the rule (`WH422` as before); its rule decides the suggestion only. `update_grn` keeps `GRN_NUMBER_LOCKED`.
- Lists keep sorting by `document_number_sort_key`: numbers of the earlier letter form first, then by the text before the trailing digits, then the digits as a number.

### Request codes and `get_submission_result` (owner decision D22: one rule for a lost answer)

- **Request code.** `update_dispatch_smart` reads `p_dispatch_data->>'request_key'`; the three-argument `save_invoice` and
  `update_invoice` read `p_invoice_data->>'request_key'`. When present, then under the document lock (advisory 71040) and before
  any other check, a saved success answer of the calling user for that code (same function, and for an edit the same dispatch /
  invoice, not expired) is returned as it was while the record it saved still exists (dispatch or invoice not deleted); so a resend
  of a save whose answer was lost is never refused for what its own first try changed. After a successful write the answer is stored
  in `idempotency_keys` for 7 days (an expired row of the same code is replaced; a code another user or function holds is left
  alone). Without `request_key` nothing changes. The creates keep their own keys: `p_idempotency_key` of
  `create_dispatch_with_stock_check` and `save_grn` / `update_grn`; a replayed dispatch create or GRN save is not returned once its
  dispatch / GRN is deleted (the key is dropped and the call creates normally), `delete_dispatch_with_order_cleanup` and
  `delete_grn_safe` drop the keys that point at what they delete, and the `save_grn` key lives 7 days (it was 1 hour).
- **`get_submission_result(p_key text) RETURNS jsonb`.** For the calling user only: `{found:true, response:<the saved answer>}`
  for a non-expired saved success answer under `p_key` (any of the six keyed writes above) whose record still exists (dispatch or
  invoice not deleted; GRN not deleted, taken from `data.grn_id` of `save_grn` and `grn.id` of `update_grn`), else
  `{found:false}`. It never returns another user's answer and never hides a database error as `found:false` (an error is raised, so
  the caller asks again rather than sending the save again). Allowed for administrators, supervisors and staff (`authorize_rpc`);
  a customer account is refused (`Staff access required`).

### Possible duplicate (migration 124, 2026-10-21)

A WARNING on GRN create and on direct dispatch create, never a block, and **opt-in**: only a call that asks for it is checked
(`save_grn`: `p_warn_duplicate => true`; the dispatch: `warn_duplicate: true` in `p_dispatch_data`) and that sends a request key
(`p_idempotency_key`; the app always does). A call that does not ask (an older app build, `fas-sync`'s bulk push) behaves exactly as before
and never gets `POSSIBLE_DUPLICATE`; a call without a request key is not checked either, so an unkeyed resend cannot be warned about its own
first try. A call that asked is answered `POSSIBLE_DUPLICATE` and writes nothing; the same call sent again with the flag false (or absent)
saves. Owner decision of 2026-10-21.

**What counts as a duplicate.**
- **GRN** (`save_grn`): a live GRN (`deleted_at IS NULL`) of the same customer, created in the last 30 minutes by anyone, with the same
  GRN day (the Asia/Kolkata calendar day of `p_date`) and the same SET of (item, packaging) lines. The item is the item id; the
  packaging is compared trimmed, in one case, with runs of white space (tabs and new lines too) as one space. Quantity, weight, rack and
  package mark are ignored; line order and a repeated line do not matter.
- **Direct dispatch** (`create_dispatch_with_stock_check`, both signatures): only when `source_order_id` is absent. A live dispatch (from an order
  or not) of the same customer, created in the last 30 minutes, with the same SET of lots (`goodsreceived_trl` ids) and the same vehicle
  registration, compared upper-cased with spaces and hyphens removed (two blank registrations are the same vehicle). Quantity is ignored.
  A dispatch made from an order never gets the warning: its order line is used up.
- With several matches the newest is reported.

**Where it runs.** After the saved-answer lookup (a resend of a request that was saved returns its stored answer, not the warning) and
after every other validation and refusal, so a person who confirms "Save anyway" is not refused for another reason afterwards: it is the
**last step** of the write block. For `save_grn` that is after the lines, images and rates are written, so every refusal of the block
(a quantity or weight, an image path, `RATE_MISSING`, `RATE_PLANNED`, the rate start floor, a foreign-key or unique violation) is answered
instead of the warning; for the dispatch it is after the dispatch, its lines, the stock, the movements and the customer's cart are written, so
a stock, cart or trigger error comes first. A match raises `dup_warn` with the answer in `DETAIL`, the handler that already answers
`rate_fail` (`save_grn`) or the function's own handler (dispatch) returns it, and the rollback of the block leaves nothing behind (no GRN, no line, no
rate, no stock movement, no cart change). The answer is never stored under the request key.

**Answer** (HTTP 200), built by `warehouse_security.refuse('POSSIBLE_DUPLICATE', ...)` like `ORDER_CHANGED`:

```
{ "success": false, "error_code": "WH409", "reason": "POSSIBLE_DUPLICATE", "error": "<English sentence>", "message": "<same sentence>",
  "kind": "grn" | "dispatch",
  "existing_id": "<uuid>", "existing_number": "<gr_no / disp_no>",
  "existing_created_at": "<timestamptz, ISO 8601>", "existing_created_by": "<display name, or null>",
  "customer_name": "<text>",
  "items": [ { "item_name", "packaging" } ]                       // GRN
          | [ { "gr_no", "item_name", "packaging" } ],             // dispatch
  "vehicle": "<registration as stored>",                           // dispatch only
  "window_minutes": 30 }
```

`existing_created_by` is `user_profiles.name`, else `display_name`, else `null`. The sentence is "GRN {no} for {customer} was created
{just now | 1 minute ago | n minutes ago} with the same items." and "Dispatch {no} for {customer} was created {...} with the same lots and
vehicle."; the app words its own text from the fields. The dispatch wrappers add `retry_count` as for every answer.

**The flag.**
- `save_grn` gains the trailing parameter `p_warn_duplicate boolean DEFAULT false` (after `p_rates`); every existing argument keeps its
  name and position. The old 17-argument function is dropped and the new one made with the same owner, `SECURITY DEFINER`,
  `search_path`, `jit = off` and grants (`authenticated`, `service_role`), so PostgREST sees one `save_grn`. Absent, `NULL` and `false`
  mean no check; only `true` checks.
- The dispatch reads `warn_duplicate` (JSON `true`) in `p_dispatch_data`; no signature change. Absent, `false` or any other value means no check.
- The app sends `true` on a normal create and `false` after the person confirms "Save anyway". The flag is part of the request body, so
  the request key changes with it.

**Bulk callers.** `fas-sync` calls `save_grn` and `create_dispatch_with_stock_check` by name without the flag, so its pushes are not
checked and never get this answer.

**Implementation.** The lookups are `warehouse_security.possible_duplicate_grn` and `possible_duplicate_dispatch` (not granted to any API
role; they take the id of the record being written and skip it; fail-open: an error inside one is logged as a `WARNING` and means no warning, so
a malformed line is answered by the save as before). The GRN lookup is bounded by customer and by the business day, as a range of `date`
(served by `idx_goodsreceived_customer_deleted_active`); the dispatch lookup starts from `idx_dispatch_customer_id` and filters by `created_at`.
No index is added (measured: 0.16 ms and 0.5 ms for a customer with 3,000 rows). Tests: `tests/duplicate_warning_124.sql`, and two-session cases
in `tests/concurrent_rules.sh` (case 12).

## Users, roles and service accounts

History: migrations 76 to 78, 113, 116 and 118.

### Users screens (migrations 113, 116 and 118, tweak batch 2026-10-20)

All answers below are `{ success, ... }`; a refusal is `{ success: false, error, error_code, message }` (`error` keeps its
earlier value, `error_code` is the stable code the app reads). The user row carries the same keys in `get_users_list`
(`users[]`) and `get_user_details` (`user`).

- **`delete_user_account`** also sets `enrollment_status = 'disabled'` (migration 118), so a deleted profile never reads as approved.
- **`user_profiles.deleted_at`**: set by `delete_user_account`; accounts deleted earlier are backfilled (mobile `DEL` plus 12 hex
  characters, name `Deleted User`; whatever their state, they are also set inactive and `disabled`). A deleted profile keeps its row.
- **New row keys** in both reads: `enrollment_status` (`'pending'`, `'rejected'` or `null`: approved and disabled are `null`),
  `is_deleted` (boolean), `deleted_at` (timestamp or `null`). A deleted account has `mobile: null` (no phone is shown or
  searched).
- **`get_users_list(p_search_query, p_role_filter, p_active_filter, p_limit, p_offset)`** (signature unchanged).
  `pagination.total_count` counts live accounts only; new `pagination.total_with_deleted` counts every row the list can return.
  Rows are ordered live accounts first (by name, then id), deleted accounts after them, so the first `total_count` rows are live;
  `has_more` is `offset + limit < total_with_deleted`. Errors: `PERMISSION_DENIED`, `INTERNAL_ERROR`.
- **`get_user_details(p_user_id)`**: `assigned_customers[]` is sorted by customer name, then id, and each entry has the new key
  `customer_active` (the business's `active`). Errors: `PERMISSION_DENIED` (not admin or supervisor, or a supervisor asking for an
  administrator), `INVALID_INPUT`, `NOT_FOUND`, `INTERNAL_ERROR`. A staff or customer caller is refused by the guard with SQLSTATE 42501
  'Staff access required', but this function (and `get_users_list`) catches every error, so the caller actually gets
  `{ success: false, error: 'INTERNAL_ERROR', error_code: 'INTERNAL_ERROR', message: 'Failed to retrieve user details: Staff access required' }`
  (an old pattern, unchanged); the app must treat that as a refusal.
- **`update_user_status(p_user_id, p_active)`** (unchanged signature). Order of refusals: `PERMISSION_DENIED` (caller),
  `INVALID_INPUT`, `NOT_FOUND`, `ACCOUNT_DELETED`, `SERVICE_ACCOUNT_READ_ONLY` (switching a service account on),
  `PERMISSION_DENIED` (a supervisor switching a service account off: the FAS sync "Disconnect" is administrator only),
  `SELF_EDIT_FORBIDDEN`, `CANNOT_MODIFY_ADMIN` (supervisor on an administrator), `ENROLLMENT_NOT_APPROVED` (supervisor on a
  person whose access is not approved), `ENROLLMENT_PENDING` / `ENROLLMENT_REJECTED` (only when `p_active` is true: the switch
  never approves an access request; the pending one is reviewed in Access requests, the rejected one with `review_enrollment_again`),
  `LAST_ADMIN`, `INTERNAL_ERROR`. Setting a pending or rejected person inactive is "Status unchanged" (success).
- **`update_user_role(p_user_id, p_new_role)`** (unchanged signature). A Customer given another role has all active customer
  assignments set inactive in the same transaction; the answer has the new key `removed_customer_count` (integer, 0 when none or
  when the role is unchanged). Errors: `PERMISSION_DENIED`, `INVALID_INPUT`, `NOT_FOUND`, `ACCOUNT_DELETED`,
  `SERVICE_ACCOUNT_READ_ONLY`, `SELF_EDIT_FORBIDDEN`, `CANNOT_MODIFY_ADMIN` (supervisor on an administrator; `error` is still
  `PERMISSION_DENIED` for old apps), `CANNOT_PROMOTE_TO_ADMIN`, `ENROLLMENT_PENDING`, `ENROLLMENT_REJECTED` (a rejected person's role cannot be changed; use
  `review_enrollment_again` first), `ENROLLMENT_NOT_APPROVED`, `LAST_ADMIN`,
  `INTERNAL_ERROR`.
- **`review_enrollment_again(p_user_id uuid)`** (new, administrators only; a supervisor gets `PERMISSION_DENIED`, staff and
  customers are refused by the guard: the call raises SQLSTATE 42501, it is not turned into an INTERNAL_ERROR answer). A rejected
  request becomes `pending` with role `customer` (the request's original state; approval picks the role), the profile stays
  inactive, and it shows in Access requests again. Answer `{ success: true, user_id, enrollment_status: 'pending', changed, message }`; `changed` is
  `false` when it was already pending (idempotent). Errors: `PERMISSION_DENIED`, `INVALID_INPUT`, `NOT_FOUND`, `ACCOUNT_DELETED`,
  `SERVICE_ACCOUNT_READ_ONLY`, `NOT_REJECTED` (approved or disabled), `INTERNAL_ERROR`.
- **`assign_customer_to_user(target_user_mobile, target_customer_id, assigner_comment)`** and
  **`remove_customer_assignment(target_user_mobile, target_customer_id)`** still return a boolean and raise on refusal; the
  exception message now starts with a stable code and a colon (`CODE: text`): `PERMISSION_DENIED`, `NOT_FOUND` (person not found or
  inactive, or the customer does not exist or is deleted), `SELF_EDIT_FORBIDDEN` and `CANNOT_MODIFY_ADMIN` (supervisor, SQLSTATE
  42501), `SERVICE_ACCOUNT_READ_ONLY`, and for assign only `CUSTOMER_INACTIVE` (a deactivated business) and `ROLE_NOT_CUSTOMER`
  (owner decision 2026-10-20: the person's role is not Customer; message `ROLE_NOT_CUSTOMER: Customer assignments apply only to the
  Customer role.`, checked after the administrator and service-account rules, before the customer is looked up). Removing an
  assignment is allowed for any role, so a stale assignment of a person who is no longer a Customer can still be removed.
- **`delete_user_account()`**: a caller whose account is already deleted gets `{ success: true, message: 'Account deleted',
  already_deleted: true }` (the retry of a timed-out delete). Other answers unchanged; `LAST_ADMIN` now also carries `error_code`.
- **`warehouse_security.other_active_admin_exists`** leaves out deleted accounts.

### `operator_review_enrollment(p_user_id uuid, p_decision text, p_customer_ids uuid[] DEFAULT '{}', p_role text DEFAULT 'customer')`

Administrators only. `p_role` is `customer`, `staff` or `supervisor`. For staff and supervisor
`p_customer_ids` must be empty (`CUSTOMERS_NOT_ALLOWED`) and the profile takes that role with no
assignment; `customer` is as before. Answer `{success:true, data:{status, role}}`. `INVALID_ROLE`
for any other value; the earlier refusals are unchanged. Returned as `error_code` and `code`.

### Service accounts

- `user_profiles.is_service_account`; returned by `get_users_list` (each row) and `get_user_details` (`user`).
- `update_user_role`, `update_user_status`, `delete_user_account`, `clear_user_central_identity` and
  `operator_review_enrollment` answer `error_code` `SERVICE_ACCOUNT_READ_ONLY` for such a profile;
  `assign_customer_to_user` and `remove_customer_assignment` raise an exception whose message starts
  with `SERVICE_ACCOUNT_READ_ONLY`. A service account does not count as another
  administrator for the last-administrator rule.
- `set_service_account(p_user_id uuid, p_is_service boolean)`: administrators (and the service key).
  Answer `{success:true, user_id, is_service_account, message}`; `error_code` `INVALID_INPUT`,
  `NOT_FOUND`, `SELF_EDIT_FORBIDDEN`, `LAST_ADMIN`.

## Customers

History: migrations 82, 83, 112, 117, 118 and 121.

### Customers: deactivate, delete, restore (migration 82, 2026-10-15)

A deactivated business (`active = false`) is offered by no staff customer picker (`search_customers`: new GRN, dispatch, order, and the list-filter
customer search) and not by the all-customers branch of `search_customer_items_for_order`, and
`assign_customer_to_user` cannot give it a new customer login (and refuses any person whose role is not Customer: `ROLE_NOT_CUSTOMER`). Everything else keeps working for it: its
customer logins read all past records and order their goods out,
staff and administrators still see its stock, invoices and activity, and dispatch creation accepts it
(`update_grn` too, so an existing GRN can still be edited). Since migration 83 `save_grn` (a NEW GRN) refuses
it with `This business is deactivated. Activate it in Customers to receive new goods.` (P0001, every caller, bare text). Since migration 84 `update_grn` refuses to move an existing GRN onto a deactivated business with the same text (a deleted business keeps `Business is not active`); editing a GRN that already belongs to a deactivated business, without changing the business, stays allowed. A DELETED business (`deleted_at` set) is refused by `get_or_create_cart`, `save_grn`, `update_grn` (when moving a GRN to it) and both
`create_dispatch_with_stock_check` overloads with `Business is not active` (P0001). Nothing with data is
ever deleted.

- `set_customer_active(p_customer_id uuid, p_active boolean)`: administrators and supervisors (staff and
  customers get 42501). `false` sets `active = false` only (no stock check, never `deleted_at`); `true` sets
  `active = true` and clears `deleted_at` / `deleted_by`. Answer `{success:true, message, data:{id, active}}`
  (message `... is already inactive` / `... is already active` when nothing changes); `{success:false,
  message}` for an unknown id (`Customer not found`) or a missing argument. `true` is refused with `DUPLICATE_MOBILE` when another
  active customer uses the same mobile (owner decision 2026-10-20; details in "Customers: duplicates, stale edit, deactivated search").
- `update_customer(..., p_active)` (migration 83): `p_active = true` also clears `deleted_at` / `deleted_by`, so a
  business is never active and deleted at once; `false` and NULL leave `deleted_at` untouched.
- `get_orders_list` leaves out orders of a deleted business.
- Five readers that no longer hide a deactivated business from staff and administrators (filter is
  `deleted_at IS NULL`): `get_invoices_list`, `get_all_stock_summary`, `get_item_wise_stock_list` (all
  customers), `get_all_customer_activity_summary`, `get_item_dispatch_records`.

### Customers: duplicates, stale edit, deactivated search (migrations 112, 117 and 118)

Errors use the shape `{success:false, data:null, message, error:{code, field?, details?}}`.

- **Mobile key** (`utils.mobile_key`, used for every comparison). The digits of the number; a 12-digit number starting `91`
  is read as its 10-digit national number and an 11-digit number with a leading trunk `0` loses that `0` (the app's
  `nationalMobileDigits`). `+91 98765 43210`, `919876543210` and `9876543210` are one key.
- **Input clean-up.** `create_customer` and `update_customer` remove only spaces, `+`, `(`, `)`, `-` and `.` from `p_mobile`,
  then require 10-15 digits; anything else (letters) is `VALIDATION_FAILED` (`field:'mobile'`), never turned into other
  digits. The stored text is the digits as sent; no shortening (the app sends the 12-digit `91...` form today).
- `create_customer(...)` (signature unchanged): `DUPLICATE_MOBILE` (`field:'mobile'`) when another ACTIVE, undeleted customer
  has the same key; a deactivated customer's number does not block. `DUPLICATE_NAME` (`field:'name'`) for
  `customers_name_key`, a plain case-sensitive UNIQUE(name) that also covers deactivated and deleted rows. For both,
  `error.details` is a JSON object `{customer_id, name, active}` of the clashing customer (absent only if it cannot be
  found). Names that differ only in capitals or spaces are the same name (`utils.customer_name_key`: trimmed, runs of white space
  made one space, lower case) and are refused with `DUPLICATE_NAME` against every customer, active, deactivated or deleted;
  `details.name` is the stored name of the holder. The unique index `customers_name_norm_key` backs it, and so does the older `customers_name_key`
  (UNIQUE(name)); either violation is answered as `DUPLICATE_NAME`. A name whose key is empty (only tabs, new lines, no-break or other Unicode spaces) is
  `VALIDATION_FAILED` with `field:'name'` (migration 118). Any other unique violation is `DATABASE_ERROR`. Other codes: `PERMISSION_DENIED` (not administrator or
  supervisor), `VALIDATION_FAILED` (`field` `name` or `mobile`), `DATABASE_ERROR`.
- `update_customer(..., p_image_urls, p_expected_updated_at timestamptz DEFAULT NULL)`: the mobile is checked only when
  `p_mobile` is sent AND its key differs from the customer's own (pairs that already share a number stay editable; a
  deactivated customer's number is allowed); same `DUPLICATE_MOBILE` / `DUPLICATE_NAME` / `details` object as above.
  The name is checked only when `p_name` is sent AND its key differs from the customer's own (an unchanged name, in any capitals or spacing, never refuses).
  With `p_expected_updated_at` given and different from the row's `updated_at`, answers `STALE_CUSTOMER` (no `field`) and
  changes nothing. Send `updated_at` back exactly as the string read from `customers` (microseconds): a JavaScript `Date`
  round-trip truncates to milliseconds and would always answer `STALE_CUSTOMER`. A blank `p_name` (also only tabs or no-break spaces, migration 118) is `VALIDATION_FAILED`;
  a name is trimmed. Other codes: `PERMISSION_DENIED`, `CUSTOMER_NOT_FOUND` (unknown id), `DATABASE_ERROR`.
  `set_customer_active` has no `error.code` for an unknown id or a missing argument (it answers `{success:false, message}`).
  **Activate re-checks the mobile (owner decision 2026-10-20).** `set_customer_active(id, true)`, `update_customer(..., p_active => true)`
  on a deactivated or deleted customer (the number checked is the one sent in the same call, else the stored one) answer `{success:false, data:null, message:'<other name> already uses this mobile number. Change one of the numbers
  first.', error:{code:'DUPLICATE_MOBILE', field:'mobile', details:{customer_id, name, active:true}}}` when another ACTIVE, undeleted
  customer has the same mobile key; `details` is the OTHER customer, and nothing changes. A customer with no mobile is never refused,
  and an already active customer is not re-checked on a normal edit (`update_customer` with `p_active = true` on an active customer).
- `search_customers(p_search_query text, p_limit integer DEFAULT 20, p_include_inactive boolean DEFAULT false)`: rows
  now also carry `active` and `deleted` (booleans). `p_include_inactive = true` is honoured for administrators and
  supervisors only and then also returns deactivated customers; for staff it is ignored (active customers they may access
  only); customers are refused by the guard. Soft-deleted customers are never returned. A query made only of digits and number punctuation
  also matches the mobile by its digits, by its key, and (when it starts `91` and is longer than 2 digits) by the digits
  after `91`, all as prefixes; any such match ranks first.
- The Customers list and the Edit form read the `customers` table directly (no list RPC): the "Deactivated" filter is
  `active = false` and the two counts are two `count: 'exact', head: true` reads (`active = true`, `active = false`);
  `updated_at` is already a column of that read.

### Deactivated business (D16, corrected)

A deactivated business may still order and be dispatched: migration 121 adds no refusal to dispatch create, edit or delete, to
`add_item_to_order`, `update_order_item_quantity` or `remove_item_from_order`. Only a new GRN for it is refused, as before
(migrations 80 to 84: `save_grn`, and `update_grn` when it moves the GRN to a deactivated customer).

## Items, rates and pricing

History: migrations 76 to 78, 85, 86, 87, 90 and 114.

### Settings UX batch (migrations 76 to 78, 2026-10-14)

**Staff lose item pricing (migration 90, 2026-10-16, owner decision).** Every function of this section
and of the next ones that reads or writes rates (`get_item_storage_prices`, `create_item_storage_price`,
`update_item_storage_price`, `delete_item_storage_price`, `replace_item_rates`, `undo_rate_change`,
`get_standard_rate`, `set_standard_rate`, `get_item_grn_rates`; the `create/update/delete_item_storage_price` helpers and `get_item_grn_rates` were removed in 123) is for administrators and supervisors
only: a staff call is refused by the guard with SQLSTATE 42501 and the message 'Staff access required'
(the price functions that catch errors answer `{ success: false, error: 'Staff access required', error_code: '42501' }`).
The staff rules described below for these functions (`PAST_DATE_NOT_ALLOWED` for staff,
`RATE_IN_FORCE_MANAGER_ONLY`, `STANDARD_RATE_MANAGER_ONLY`) are therefore unreachable. New error code
`RATES_MANAGER_ONLY`: `save_grn` or `update_grn` called by staff with `p_rates` (see below). Staff keep
`get_grn_item_rates` and `generate_invoice_data_for_grn_with_pricing`.

Errors of `replace_item_rates`, `undo_rate_change` and the rate functions are
`{ success: false, error, error_code, data }`. The service-account answers (`set_service_account`
and `SERVICE_ACCOUNT_READ_ONLY`) are `{ success: false, error, error_code, message }` with no `data`
(`delete_user_account` and `operator_review_enrollment` also carry `code`); `assign_customer_to_user`
and `remove_customer_assignment` return a boolean and raise an exception whose message starts with
`SERVICE_ACCOUNT_READ_ONLY`. Days are India
days (`warehouse_security.business_date(now())`), not UTC days.

#### `replace_item_rates(p_item_id uuid, p_customer_id uuid, p_price_type text, p_starts_on date, p_bands jsonb, p_replace_later boolean DEFAULT false, p_mode text DEFAULT 'change', p_move_from date DEFAULT NULL, p_seen_rows uuid[] DEFAULT NULL)`

Changes one scope (item, customer or NULL for the default rate, price type) "from a date" in one
transaction (a refusal after the first write undoes all of them). A band is
`{weight_min, weight_max, unit_price, labour_rate, tax_percent}` (up to 10; whole kilograms; amounts
with at most two decimals; labour is not read and is stored as 0 for `one_time`). Default-rate bands
must start at 0 and follow on without gaps; customer bands may have gaps. Roles: admin, supervisor
(staff are refused since migration 90).

- `p_mode = 'change'` (default): rows in force on `p_starts_on` end the day before, rows starting on
  that day that are already in force are deleted, the bands are added from that day. A rate
  planned (not begun) to start on that day or later is refused with `LATER_RATES_EXIST` unless
  `p_replace_later` is true, which deletes it. Exception: new bands (not a stop) that start on a
  planned rate's own start day replace it when its id is listed in `p_seen_rows`.
  `p_bands = []` stops the rate. If every row in force that day shares one last day E and no row
  starts later, the new rows keep that stop (`effective_to = E`); `data.kept_end` is E, else null.
- `p_mode = 'correct'`: `p_starts_on` must be the start of the rows in force that day
  (`NOT_A_RATE_START` otherwise). Exactly the rows starting that day are replaced, the new rows keep
  their last day (`data.kept_end`, null when open), later rows are never touched and
  `p_replace_later` is ignored (`LATER_RATES_EXIST` is never returned). `p_bands` needs at least
  one band.
- `p_move_from` (only with `'change'`, else `INVALID_MODE`): first undoes the change that starts on
  `p_move_from` (as `undo_rate_change`: its rows go, the rows it ended are opened again,
  `data.reopened`), then applies the change from `p_starts_on`, in the same transaction.
  `NOTHING_TO_MOVE` if nothing starts on `p_move_from`.
- `p_seen_rows` (optional): the ids of the rows the editor loaded for this scope. A row the call would
  end, move or delete that is not listed was changed by someone else: the answer is `STALE_RATES`
  (`data.ids` = the unseen ids) and nothing is written. NULL skips the check. Moving or undoing a
  planned rate that carried a scheduled stop gives the stop back to the rows it reopens.
- Staff (before migration 90; now refused by the guard): `p_starts_on` today or later, and for a move both `p_move_from` and `p_starts_on` after
  today (`PAST_DATE_NOT_ALLOWED`); rows of the scope that start on `p_starts_on` when that day is
  today give `RATE_IN_FORCE_MANAGER_ONLY` (a rate that began today is for administrators and
  supervisors), in either mode.

Answer: `{success:true, message:'Rates saved', data:{item_id, customer_id, price_type, starts_on, mode, move_from, kept_end, ended:[{id,effective_from,effective_to}], removed:[{id,effective_from}], reopened:[{id,effective_from,effective_to}], added:[{id,weight_min,weight_max,unit_price,labour_rate,tax_percent}]}}`.
`error_code`: `INVALID_PRICE_TYPE`, `INVALID_MODE`, `INVALID_DATE` (outside 3 years back to 2 years
ahead; also for `p_move_from`), `PAST_DATE_NOT_ALLOWED`, `RATE_IN_FORCE_MANAGER_ONLY`,
`ITEM_NOT_FOUND`, `CUSTOMER_NOT_FOUND`, `INVALID_BANDS`, `INVALID_BAND` (`data.index`, and
`data.field` when a weight is wrong), `INVALID_AMOUNT` (`data.index`, `data.field`), `BANDS_OVERLAP`,
`BANDS_GAP` (`data.expected_min`), `LATER_RATES_EXIST` (`data.later`, change mode only),
`NOT_A_RATE_START`, `NOTHING_TO_MOVE`, `NOTHING_TO_STOP`. A customer account is refused with
SQLSTATE 42501.

`find_or_create_item_storage_price` (removed in migration 123) was for administrators and supervisors only (no app code called
it); it uses the India day, stores labour 0 for one-time and refuses an overlapping row
(`BANDS_OVERLAP`). `get_item_storage_prices` without `include_expired` hides rows that ended before
the India day.

#### `undo_rate_change(p_item_id uuid, p_customer_id uuid, p_price_type text, p_starts_on date, p_seen_rows uuid[] DEFAULT NULL)`

Undoes the change of one scope that starts on `p_starts_on` in one transaction: the rows with
`effective_from = p_starts_on` are deleted, and the rows that ended the day before
(`effective_to = p_starts_on - 1`) are opened again, up to the day before the next planned rate of
the scope, or without an end if there is none. This is how "cancel the new rate" and "undo the
stop" work: the rate in force before the change continues. Roles: admin, supervisor (staff are refused
since migration 90; before it staff could undo only a change that had not begun).
The history trigger records the deletes and updates. Answer:
`{success:true, message:'Change undone', data:{item_id, customer_id, price_type, starts_on, removed:[{id,effective_from}], reopened:[{id,effective_from,effective_to}]}}`.
`error_code`: `INVALID_PRICE_TYPE`, `INVALID_DATE` (same range as `replace_item_rates`; since migration 86 the earliest day is the rate start floor, `data.earliest`),
`PAST_DATE_NOT_ALLOWED` (unreachable since migration 90: it was staff, change starting today or earlier), `ITEM_NOT_FOUND`,
`CUSTOMER_NOT_FOUND`, `NOTHING_TO_UNDO` ("There is no change starting on that day to undo"),
`BANDS_OVERLAP` (reopening would overlap another row; nothing is changed), `STALE_RATES` (pricing review migration, below). A customer account is
refused with SQLSTATE 42501.

`p_seen_rows` (pricing review migration, default NULL = no check; an older app that sends four arguments is unchanged): the ids of the
rows the editor loaded for this scope (item, customer, price type), as in `replace_item_rates`. The caller must send EVERY row id
of the scope it loaded, ended and planned rows included (like `replace_item_rates`' `p_seen_rows`): a row of the scope that is
missing from the list and that the call would touch (see below) makes the answer `STALE_RATES`, so an app that leaves out a
planned later change always gets `STALE_RATES` when it cancels an earlier change. After the scope is locked,
a row of the scope that this call would delete (starts on `p_starts_on`), reopen (ended the day before) or that decides
where the reopened rate ends (starts later, or has no end) and whose id is not listed was added or changed by someone else:
nothing is written, answer `STALE_RATES` with `data.ids` = the unlisted ids that triggered it (sorted). Checked before `NOTHING_TO_UNDO`.
A row that ended before `p_starts_on - 1` is never touched and never counts, listed or not. A new app that sends `p_seen_rows` to a
facility without this migration gets PGRST202 (no such function), because the old signature has four arguments.

#### Changed price functions

(`create_item_storage_price`, `update_item_storage_price` and `delete_item_storage_price` were removed in migration 123; this list is history.)

- `create_item_storage_price`, `update_item_storage_price`: refuse an overlap of the same item,
  customer, price type, weight and days (`BANDS_OVERLAP`); a one-day rate is valid
  (`effective_to >= effective_from`); `one_time` stores labour 0. Roles: admin, supervisor. Staff were
  given `RATE_IN_FORCE_MANAGER_ONLY` (message "Only administrators and supervisors can change a rate
  that is already in force") when the row had started or the new start was in the past; since
  migration 90 staff are refused by the guard and that answer is unreachable.
- `delete_item_storage_price`: admin, supervisor (the same staff rule above, now unreachable). The old
  nine-argument `update_item_storage_price` follows the same rule.
- `get_item_storage_prices`: admin, supervisor (staff were admitted from migration 45 to migration 90).
- `get_item_storage_prices`: a final `id` sort key. `search_customers`: every typed word may occur
  anywhere in the name (mobile still by prefix); names starting with the text come first.

### Standard rate (migration 85, 2026-10-15)

The facility's standard monthly rate: weight tiers (whole kilograms, inclusive, from 0, no gaps) with
rent, labour and tax, kept in `standard_rate_tiers` (read by administrators and supervisors through `get_standard_rate` only since migration 123, which took the direct read away; written
only by `set_standard_rate`). A tier is
`{ weight_min, weight_max, unit_price, labour_rate, tax_percent }`. Errors are
`{ success: false, error, error_code, data }`. A later change of the standard rate never changes an
item that already has a rate.

#### `get_standard_rate()`

Roles: admin, supervisor (staff are refused by the guard since migration 90). Answer
`{ success: true, data: { tiers: [tier, ...] (by weight_min; [] when never saved), updated_at, updated_by_name } }`
(`updated_at` and `updated_by_name` are null when never saved).

#### `set_standard_rate(p_tiers jsonb, p_expected_updated_at timestamptz DEFAULT NULL, p_dry_run boolean DEFAULT false)`

Roles: admin, supervisor. Staff and customers are refused by the guard (SQLSTATE 42501) whatever tiers they
send; `STANDARD_RATE_MANAGER_ONLY`, which migration 85 answered to staff from the body, is unreachable since
migration 90. The
checks, in this order and with the limits and texts of `replace_item_rates`: not a list, no tier or more than 10 -> `INVALID_BANDS`; weights not whole 0 to
100000 or start after end -> `INVALID_BAND` (`data.index`, `data.field`); rent and labour 0 to 999999,
tax 0 to 100, two decimals at most, all three required -> `INVALID_AMOUNT` (`data.index`,
`data.field`); sorted by start, an overlap -> `BANDS_OVERLAP` (`data.index`), a first tier not at 0 or
a gap -> `BANDS_GAP` (`data.index`, `data.expected_min`). Tiers may be sent in any order.

In one transaction it replaces the tiers, then gives every **active item with no default rate row at
all** (any dates; customer rates do not count) one monthly default row per tier, starting on the India
day of the item's first GRN that is not deleted, else today, without an end date, authored by the
caller (so the price history names them). Items whose default rate ended or was stopped, and inactive
items, are not touched. Answer
`{ success: true, data: { tiers: [tier, ...], items_priced, dry_run: false, updated_at } }`
(`updated_at`: the new version, also what `get_standard_rate` returns next).

The two extra arguments belong to the pricing review migration. Older apps that send only `p_tiers` are unchanged; a new app that
sends the new arguments to a facility without this migration gets PGRST202 (no such function).

- `p_expected_updated_at`: the `updated_at` that `get_standard_rate` returned when the editor loaded the rate. After the
  validation and the save lock, if it is given and differs from the current version (`max(updated_at)` of the tiers; all
  tiers of a save carry one time) nothing is written and the answer is `error_code` `STALE_STANDARD_RATE`
  ("The standard rate was changed by someone else; reload and try again", `data.updated_at` = the current version, null if none).
  NULL skips the check (older apps). `'-infinity'` means "I loaded no tiers" (the rate was never saved): it matches only an empty
  tier table, so the very first save is protected too (a rate saved meanwhile gives `STALE_STANDARD_RATE`). An app must send the
  value as the `updated_at` STRING exactly as `get_standard_rate` returned it, or as the last `set_standard_rate` answer carried it
  (`data.updated_at`), never through a JS `Date` (milliseconds would cut the microseconds and every save would be stale). It must
  be the value from when the draft was built, not one from a later background refresh, or the check would not see the change.
- `p_dry_run`: true runs every check above (and the stale check), writes nothing and answers
  `{ success: true, data: { dry_run: true, items_priced, tiers: <as sent>, updated_at: <current> } }`, where `items_priced` is
  the number of **active items that never had a default rate row** (no `item_storage_prices` row with `customer_id` null, of any
  price type, dated any day) that a real save would price right now: the count for "Give this rate to N items that have no rate?".
  Only default rows matter, so an item with only customer rows is counted and priced. Not counted and not priced: inactive items,
  items whose default rate ended or was stopped, and items whose only default rate is planned (starts later). The app's "No rate"
  label (no default rate in force today) is therefore wider than this count. A real save can differ if items change between the
  two calls.
- Other `error_code`s of this function: `STANDARD_RATE_MANAGER_ONLY` (unreachable), `INVALID_BANDS`, `INVALID_BAND`,
  `INVALID_AMOUNT`, `BANDS_OVERLAP`, `BANDS_GAP` (all existed); `STALE_STANDARD_RATE` is new.

#### `create_item(p_name, p_packaging, p_description, p_active, p_rate_from_item uuid DEFAULT NULL)`

One overload (the four-argument call works unchanged). Same checks and answer as before, and
`data.rate_source`: `copied` when `p_rate_from_item` has default rows in force today, which are copied
(monthly and one-time, one-time labour 0, no customer rates) as new rows from today without an end;
else `standard` when a standard rate is saved (its tiers from today); else `none` and no rate rows.

#### `update_item` (signature unchanged)

An item that turns from inactive to active and has no default rate row at all gets the standard tiers
from today (nothing when no standard rate is saved). The answer is unchanged.

### Items screens (migration 114, tweak 2026-10-20)

Refusals of `create_item`, `update_item` and `get_item_usage` are `{ success: false, error_code, error, message }`
(`error_code` and `error` are new on these refusals; `message` is the English text they had before. The app reads
`error_code`). Codes:
`DUPLICATE_NAME` (another item has this name: the match ignores upper/lower case and spaces around the name (on both the sent and the stored name), and
covers deactivated items; saving an item under the name it already has is never refused, even if an older item differs from it only in case; the unique constraint `items_name_key` also maps to it when two saves race),
`NOT_FOUND` (`update_item`, `get_item_usage`: the item does not exist, for example deleted by someone else),
`INVALID_INPUT` (blank name; name over 80 characters; packaging or description over 40),
`PERMISSION_DENIED` (role check inside the body). Staff and customers never reach the body: the guard raises
SQLSTATE 42501 first.

- `create_item`: signature unchanged; the codes above (`DUPLICATE_NAME`, `INVALID_INPUT`, `PERMISSION_DENIED`).
- `update_item(p_item_id, p_name, p_packaging DEFAULT NULL, p_description DEFAULT NULL, p_active DEFAULT NULL)`:
  `p_active` not sent or NULL keeps the item's current value (it used to default to true and re-activate the item).
  Sending true or false sets it as before. `p_packaging` and `p_description` are different: not sent or NULL
  CLEARS them (as before), so the app must always send the current values. `create_item` with `p_active` NULL
  creates an active item. Codes: `NOT_FOUND`, `DUPLICATE_NAME`, `INVALID_INPUT`, `PERMISSION_DENIED`.
  The name is compared with the stored name after trimming both, so an item stored as `Garlic ` saved as `Garlic` is not re-checked for a duplicate.
  When the save switches an item from inactive to active and that gave it the standard rate tiers, `data` also carries `rate_source: 'standard'`; otherwise `data` has no `rate_source`.
- `delete_item_safe(p_item_id)`: for an item that does not exist the refusal also carries `error_code: 'NOT_FOUND'` (still `{ success: false, message: 'Item not found' }`); its other refusals and texts are unchanged.
- `get_items`: the search text also matches `packaging` (case-insensitive substring, like name and description).
  Order, paging and the answer are unchanged.
- `get_item_usage(p_item_id uuid)`, read-only, administrators and supervisors: answer
  `{ success: true, data: { item_id, name, active, grn_lines, order_lines, grn_rates, price_rows, rate_count,
  in_use, can_delete } }`. `grn_lines` (GRN lines, including lines of deleted GRNs, as `delete_item_safe` counts them), `order_lines` and `grn_rates` are what makes
  `delete_item_safe` refuse; `in_use` is true when any of the three is above 0 and `can_delete` is its opposite.
  `price_rows` are the item's storage price rows (deleted with the item) and `rate_count` the same rows counted as
  the Item pricing screens do (one per customer or default, price type and start date). Unknown id: `NOT_FOUND`.

### The rate start floor

`warehouse_security.rate_start_floor()` is the earlier of the India day of the first GRN that is not
deleted and today minus 1095 days (so never later than the old three-year window; a facility with older
GRNs can start rates further back, one with no GRN keeps today minus 1095). `replace_item_rates` (`p_starts_on`, `p_move_from`) and
`undo_rate_change` (`p_starts_on`) accept a start from the floor to two years after today (it used to be
always three years before today). `INVALID_DATE` reads 'The start date must be on or after <floor> and within
two years after today' and carries `data.earliest` (ISO date). `get_item_storage_prices` answers
`earliest_start` (ISO date) as a key of the answer next to `data` and `pagination` (`data` is the list of
rows). `create_item_storage_price` has no window, as before.

### Users and rates

- `update_user_role` and `update_user_status` take the user lock (advisory 71043) after the caller check and
  read the target row `FOR UPDATE`: a supervisor who acts at the same moment as an administrator promoting
  the target waits and is refused (`Supervisors cannot modify admin users`).
- `create_item_storage_price` (with `p_price_type`), both `update_item_storage_price` overloads,
  `find_or_create_item_storage_price` and `delete_item_storage_price` take the same per-scope advisory lock as
  `replace_item_rates` (item, customer or `default`, price type) before they read the scope, so writers of one
  scope take turns and the later one sees the earlier one's rows (`BANDS_OVERLAP` for an overlap).
  `find_storage_price` breaks a last tie by row id (a fixed tie-break, the lower row id).

## GRNs

History: migrations 86, 88, 89, 95, 98, 120 and 121.

### Rates on the GRN sheet and the rate start floor (migration 86, 2026-10-15)

Errors are `{ success: false, error, error_code, data }`; those of `save_grn` and `update_grn` also carry
`message` (the same text), which is what the app reads there. Dates are India days. A band is whole
kilograms, inclusive at both ends.

Line lengths (migration 95): a GRN line's `item_name` can have 80 characters and its `packaging` 40, as the
catalog (`items.name`, `items.packaging`). `save_grn` and `update_grn` check every line first and write nothing
when one is longer: `{ success: false, error_code: 'item_name_too_long' | 'packaging_too_long', error, message,
data: { limit: 80 | 40, index } }`, `index` being the line's position in `p_items`, counted from 0.

#### `save_grn(..., p_rates jsonb DEFAULT NULL, p_warn_duplicate boolean DEFAULT false)` and `update_grn(..., p_rates jsonb DEFAULT NULL)`

`p_rates` is the last parameter of each (one overload each; every call that does not name it, the
app's before this migration and fas-sync's, works unchanged). Roles as before: admin, supervisor, staff.
**Migration 90: `p_rates` is for administrators and supervisors.** A staff call that carries `p_rates`
(any value that is not NULL, `[]` included) is answered
`{ success: false, error: 'Only administrators and supervisors can set rates on a GRN', error_code: 'RATES_MANAGER_ONLY', data: {} }`
before anything is written; without `p_rates` a staff call works as before.

- `p_rates` NULL: exactly the old behaviour. No rate is checked or changed; a GRN with an unpriced line
  still saves.
- `p_rates` a list (also `[]`): checked and applied inside the GRN's transaction, after the GRN and its
  lines are written. A failure rolls the whole call back: the GRN is not saved, an update is undone.
  Entries are
  `{scope:'grn', item_id, weight_min, weight_max, unit_price, labour_rate, tax_percent}` or
  `{scope:'customer'|'everyone', item_id, weight_min, weight_max, to:'YYYY-MM-DD'|null, unit_price, labour_rate, tax_percent}`;
  a customer / everyone entry may also carry `seen_ids` (migration 120, see
  [Order, dispatch, GRN and invoice review fixes](#order-dispatch-grn-and-invoice-review-fixes-migration-120-2026-10-20)).
  A monthly GRN needs labour; a ONE_TIME GRN does not read it and stores 0.
  1. Validation: not a list or an entry not an object -> `INVALID_BANDS`; unknown scope ->
     `INVALID_SCOPE`; weights -> `INVALID_BAND` (`data.index`, `data.field`); amounts ->
     `INVALID_AMOUNT` (`data.index`, `data.field`); `to` not a date or before the GRN day ->
     `INVALID_DATE` (`data.index`); an item that is not on the GRN, or a band that holds none of that
     item's line weights (a line without weight counts as 0 kg) -> `RATE_NOT_FOR_GRN` (`data.index`,
     `data.item_id`; not checked for the `grn` entries of an invoiced GRN, whose stored set may no longer fit
     a changed line); two GRN-only bands of one item that share a weight -> `BANDS_OVERLAP`.
  2. `customer` (the GRN's business) and `everyone` (the default rate) entries change the item's rate
     of the GRN's price type from the GRN's India day, any day (the staff past-day rule
     of `replace_item_rates` does not apply here; staff cannot send `p_rates` since migration 90). For the rows of that scope that share a weight and a
     day with the days from the GRN day to `to`: a row of a different band -> `BANDS_OVERLAP`
     (`data.index`, `data.starts_on` = the earliest start of the clashing rows); a row of the same band that starts after the GRN day -> `RATE_PLANNED`
     (`data.index`, `data.starts_on`); a row of the same band that starts on the GRN day is replaced,
     else it ends the day before the GRN day; with `to` set and the old row open or ending after `to`,
     a copy of it with its old figures starts the day after `to`. The new row runs from the GRN day to
     `to` (open when `to` is null: the old row then ends for good). The other bands of the scope that
     are in force on the GRN day follow on the same days (ended the day before, copied unchanged from the
     GRN day to `to`, resumed after `to`), so every band of the scope still starts and ends together and
     Item pricing's Correct and Undo work on the day. Entries are applied in list order; the history rows
     name the caller.
  3. The `grn` entries replace the GRN's own rates in `grn_rates`, by item and band: a row that is no
     longer listed goes, a new one is added, an unchanged one keeps its id, author and time, a changed one
     gets `updated_by` / `updated_at`. When the GRN is invoiced and the new
     set differs from the stored one (item, band, figures) -> `GRN_INVOICED` ('The rates of an invoiced
     GRN cannot change'); an equal set is accepted without change.
  4. Every line must have a rate: a GRN-only rate whose band holds the line's weight, else the item's
     rate (`find_storage_price`, for the GRN's business, India day and price type). Otherwise
     `RATE_MISSING` with `data.lines = [{item_id, item_name, weight}]` (distinct, by item name and
     weight). Not checked for an invoiced GRN (its invoice carries its own figures); a note-only edit of an
     invoiced GRN saves even when a line has no rate.
  `update_grn` also deletes, whether or not `p_rates` came, the GRN's own rates of another pricing kind and
  those whose band holds no weight of that item's lines any more (not for an invoiced GRN, which keeps its
  archived rates). `delete_item_safe` refuses an item that has GRN-only rates, like one on a line.
- The success answers are unchanged.

#### `grn_rates` and where a GRN-only rate is used

`grn_rates` (`gr_id`, `item_id`, `price_type`, `weight_min`, `weight_max`, `unit_price`, `labour_rate`,
`tax_percent`, `created_by`, `created_at`, `updated_by`, `updated_at`) is written only by `save_grn` / `update_grn`; administrators,
supervisors could read it directly (like `item_storage_prices`) until migration 123 removed the direct read of both: the rates come through `get_grn_details` and `get_grn_item_rates`; customer accounts never could. Invoice rows
take rent, labour and tax of a line from one source: the GRN-only rate whose band holds the line's weight (the
narrowest wins), else the item's rate. The invoice form's preview (`build_invoice_form_lines`, migration 102) never
reads `invoice_trl`: it prices the GRN's dispatched lines afresh, with the duration from `calculate_invoice_duration`.
`save_invoice` calls `calculate_invoice_duration` itself and takes charge, tax and labour from the lines it is sent.
`build_invoice_recalculation_rows` (which also takes the stored invoice figure of an already invoiced line) is now
called only by tests and the lot-rate reader (`recalculate_invoice_items` was removed in 123); `get_grn_item_rates` also takes
the stored invoice figure first (`source 'invoice'`, from the lines of any live invoice of the lot, migration 88),
then follows its rule. Once an invoice is saved its figures win and the GRN-only rate is "archived"; delete the
invoice and it applies again.

### `get_grn_details(p_grn_id)`: `data.grn.rates`

The `grn` object gains `rates`: `[{id, item_id, item_name, price_type, weight_min, weight_max,
unit_price, labour_rate, tax_percent, archived}]` ordered by item name and `weight_min` (`[]` when none);
`archived` is true when the GRN is invoiced. For a customer account and, since migration 90, for staff, `rates` is always `[]`.

### `get_item_grn_rates(p_item_id uuid)` (removed in migration 123)

Roles: admin, supervisor (since migration 90; staff and a customer account are refused with SQLSTATE 42501). Answer
`{success:true, data:{rates:[{id, gr_id, gr_no, grn_date:'YYYY-MM-DD', customer_id, customer_name,
price_type, weight_min, weight_max, unit_price, labour_rate, tax_percent, archived, created_at}]}}` for
GRNs that are not deleted: not archived first, then newest GRN first, then GRN number.

### `get_grn_item_rates(p_grn_id uuid)` (migration 88)

Roles: admin, supervisor, staff, and a customer account for the GRNs of a customer it owns (owner decision of
2026-10-16; `get_grn_details` still answers `grn.rates = []` to a customer account). Another customer's GRN is
refused with 'Customer access denied' (42501). The rate each lot is invoiced at, chosen as
`build_invoice_recalculation_rows` does. Answer
`{success:true, data:{gr_id, grn_date:'YYYY-MM-DD', price_type:'monthly'|'one_time', invoiced, rates:[{grn_item_id,
item_id, item_name, weight, source:'invoice'|'grn'|'customer'|'item'|null, unit_price, labour_rate, tax_percent,
weight_min, weight_max, varies}]}}`, one entry per lot in the order of `get_grn_details` (by lot id). `source`:
`invoice` = the first line (by dispatch date, then id) of the lot on an invoice that is not deleted or cancelled
(`weight_min`/`weight_max` null; `varies` true when the lot's lines carry more than one charge / labour / tax);
`grn` = a GRN-only rate (narrowest band); `customer` / `item` = the business's or the item's default rate from
`find_storage_price`; null = no rate (figures null). A missing or deleted GRN answers
`{success:false, error:'GRN not found', error_code:'GRN_NOT_FOUND', data:null}`.

**A customer account's answer (migration 89, owner decision of 2026-10-16):** the same header, lots, order,
figures and `varies`, but `source` is `customer` for every rate that is not an invoice figure (`grn`,
`customer` and `item` alike: the rate is presented as the customer's own) and `weight_min` / `weight_max`
are null on every entry. `invoice` and null are unchanged. Staff, and a caller with no app role (service
role), get the full answer above.

### `seen_ids` and `STALE_RATES` on the GRN rates

Each `customer` / `everyone` entry of `p_rates` (`save_grn`, `update_grn`) MAY carry `seen_ids`: the list of the
`item_storage_prices` ids of that scope (the item for the GRN's business, or for everyone) that the sheet showed in force on the
GRN day. When it is present and a row of that scope, price type and band (`weight_min`, `weight_max`) that is in force on the GRN
day is not in the list, nothing is written and the answer is `{success:false, error_code:'STALE_RATES', reason:'STALE_RATES',
error, message, data:{index, ids}}`, `data.ids` the unlisted ids (sorted), the same shape family as `replace_item_rates`. A
`seen_ids` that is not a list of uuids is `INVALID_BANDS` (`data.field:'seen_ids'`). Without `seen_ids` nothing is checked (older
apps).

### `get_grn_edit_state(p_grn_id uuid)` (new)

For administrators, supervisors and staff (`authorize_rpc`: the staff list; a customer account is refused `Staff access required`). The
GRN edit form loads its rows by direct table reads, so the token is read here first (a token read after the rows could hide a change):

```
{ success:true, data:{ grn_id, gr_no, date, updated_at,
    invoice: null | {id, inv_no, inv_fin_year},            -- the GRN's first live invoice; when only the `invoiced` flag is set: the object with all three null
    first_dispatch_date: null | 'YYYY-MM-DD',              -- IST day of the earliest live dispatch line of any lot
    lines:[{ id, dispatched_qty, has_history, on_invoice, invoice_no, inv_fin_year, on_order, order_customer_name }] } }
```

`has_history`: a `dispatch_trl` or a `stock_movements` row exists for the lot; `on_invoice` / `invoice_no` / `inv_fin_year`: the lot
is on a line of a live invoice; `on_order`: an `order_items` row of a live order points at it; `order_customer_name`: the GRN's
customer. Not found (or deleted): `{success:false, error:'GRN not found', message:'GRN not found'}`.

### GRN number (D6, D8)

`update_grn`: a non-blank `p_gr_no` that differs from the stored number is `GRN_NUMBER_LOCKED` (after the blank-number check, before the
duplicate check); equal or NULL is fine. `get_next_grn_number` takes the letter from the highest letter in use
(`max(left(gr_no,1))` among `^[A-Z][0-9]{1,7}$`), not from the last-entered GRN; then as before: the highest number of that letter's
series, `>= 1000` moves to the next letter (`Z` to `A`): with `0001`, or, when that letter's series exists already, its next number; no GRN: `A0001`.
(Migration 127 replaced this generator: [Document numbering](#document-numbering-migration-127-2026-10-27). The default rule is the same up to Z; after Z the series is full.)

### GRN rates dropped by an edit (D10, D24)

`update_grn`'s clean-up of the GRN's own rates (a rate whose band holds no weight of its item's lines any more, or of another pricing
kind; an invoiced GRN keeps its rates) now collects what it removes. Staff (`warehouse_security.active_role() = 'staff'`): a removal of a rate that fitted a line before the edit is
`RATES_NEED_MANAGER` (they cannot send rates; a manager makes the change). Administrators and supervisors: `RATES_WOULD_DROP` when a line
whose weight, or the GRN's pricing mode, was changed by this save lost its GRN-only rate and is not priced by this save: not by a rate of any
scope for that item and weight in `p_rates`, and not by a GRN-only rate it still has. A rate removed on purpose in the Rates step, a removed
line, a changed item, and a service-key call are not this case. Both raise `rate_fail`: the whole edit rolls back.

### Removing a GRN line (D11)

`update_grn`, before writes, for each stored line missing from `p_items`: a lot with a `dispatch_trl` or a `stock_movements` row is
`LINE_DISPATCHED_BEFORE`; else a lot on an order line of a live order is `LINE_ON_ORDER` (this replaces the raw foreign-key text). The
in-loop `Cannot delete item "..." - has N existing dispatches` stays as a backstop.

### GRN history (D12), lengths (D13), rack and package mark (D15)

`public.audit_trigger_func()` (the audit of customers, dispatches and orders) is attached to `goodsreceived` and `goodsreceived_trl`:
every insert and delete, and every update except one that changes only `updated_at`, `updated_by`, `out_of_stock` or `invoiced` of a GRN, or
only the `stock` of a line (every dispatch moves stock; `stock_movements` records it). `delete_grn_safe` still hard-deletes and the DELETE
triggers keep a copy of the GRN and of each line; `audit_log.user_id` is the JWT `sub` (null for a service connection). History starts at the
deploy; nothing purges `audit_log`. `save_grn` and `update_grn` also refuse a registration over 20 characters:
`{success:false, error:'Registration can have at most 20 characters', error_code:'registration_too_long', data:{limit:20}, message}` (the column is
`varchar(20)`; before, a database text). `warehouse_security.ascii_digits(text)` turns Gujarati, Devanagari, Arabic-Indic and extended
Arabic-Indic digits into 0-9; `save_grn` and `update_grn` store `rack` and `package_mark` through it. Rows already stored are not converted.

### GRN lists by receipt, and low stock (migration 98, 2026-10-18)

`get_all_grn_items(p_date_from, p_date_to, p_filters, p_sort_by, p_sort_order, p_limit, p_offset)` (staff;
reads the tables) and `get_customer_grn_items(p_customer_id, p_date_from, p_date_to, p_filters, p_sort_by,
p_sort_order, p_limit, p_offset)` (a customer's own receipts) page item lines by default, so one receipt can
be split across two pages. Both accept one more, opt-in key in `p_filters`:

- **`page_by: 'receipt'`.** `p_limit` and `p_offset` then count receipts, and every line of each receipt on the
  page that passes the filters is returned (a receipt page is not bounded in lines). `pagination.total_count`
  (the customer function also `pagination.total` and `aggregations.total_count`) counts the receipts with at
  least one matching line; the sums (`aggregates` / `aggregations`: qty, stock, weight) stay over all filtered
  lines. The customer `has_more` follows the receipt count, and the `p_limit` 1 to 100 check counts receipts.
  Receipts are ordered by the sort, then by receipt number (raw text) for equal values; lines of one receipt are
  never interleaved with another's.
- **Sorts in receipt mode** are `date`, `gr_no` and `customer_name` only. In the staff function a NULL sort means
  `date`. The customer function accepts a NULL sort (and a NULL order) and does not default it: no sort term
  applies, so receipt mode orders by raw receipt number (text, ascending) alone, and line mode by line id alone.
  Any other sort answers `{success: false, message: 'Invalid list parameters', data: null}`.
- **`pagination.unit`** is `'receipt'` or `'line'` in both functions (new field; `'line'` without the key).
  Without `page_by` (or with any other value) nothing else changes, so older app builds keep working.
- **Staff list data order** is now explicit: `row_num`, then `grn_item_id` (line mode returned this order
  incidentally).
- **`stock_status: 'low_stock'`** selects lines with `0 < stock < 0.2 * qty` (exactly 20% is not low). The
  staff list ignored the value before; the customer list matched nothing. `in_stock`, `out_of_stock` and `all`
  are unchanged, and other unknown values still match nothing in the customer list.

`tests/grn_receipt_pages_98.sql` covers both functions.

## Dispatches and orders

History: migrations 87 (the outside review fixes of 2026-10-15), 120 and 121.

### Dispatch

- `create_dispatch_with_stock_check` (both overloads) and `update_dispatch_smart` refuse the same lot
  twice in the lines: `The same lot appears twice in the dispatch lines` (SQLSTATE `WH409`; the create answer
  is `{success:false, error, error_code:'WH409'}`, the edit answer `{success:false, error}`). Nothing is stored.
- A dispatch made from a cart (`source_order_id`) must be for the cart's customer: create refuses a missing,
  deleted or other customer's cart with `The order belongs to another customer` (`WH409`);
  `update_dispatch_smart` refuses moving a dispatch that has a `source_order_id` to a customer other than
  the cart's (same text and code; a dispatch already for another customer can still be edited without
  changing its customer). `get_cart_dispatches` (removed in 123), `get_orders_list` and `get_order_with_items` show only a dispatch of the cart customer's own.
- Create takes the document lock (advisory 71040) before it looks up the idempotency key, so a retry that
  overlaps its first call waits and is then answered from the cache (`from_cache:true`), never with a
  unique-key error. A dispatch from a cart reads the cart line `FOR UPDATE`: a concurrent change of the line's
  quantity is not lost.
- `get_grn_list` (`total_weight`) and `get_customer_dispatch_items` (`total_weight`) sum weight as numeric: a
  total above 2147483647 kg is a number, not an error.

### Dispatch create and edit

- **`order_lines_left`.** The success answer of `create_dispatch_with_stock_check` gains `order_lines_left`: an integer, the
  number of the source order's lines that are still open after this dispatch, counted the way the order queue counts them
  (only lines with `item_status = 'pending'`); `null` when the dispatch has no source order. `source_order_cleared` is
  unchanged (true whenever there is a source order, whether or not lines are left).
- **`source_order_no`.** Only the source order's own `order_no`; a client-sent `source_order_no` is ignored, and a dispatch
  without a source order has none (`NULL`).
- **Names.** Create stores `customer_name` and `supervisor_name` from the master tables (`customers.name`,
  `COALESCE(user_profiles.name, user_profiles.display_name)`), whatever names the client sends, and the supervisor must be an
  administrator, supervisor or staff member. `update_dispatch_smart` keeps the stored names unless `customer_id` /
  `supervisor_id` changes; then the stored name is the new customer's or the new supervisor's from the master tables, never the
  client's and never the old person's.
- **Edit.** `update_dispatch_smart` locks the dispatch and answers `{success:false, error:'Dispatch not found'}` for a dispatch
  that is deleted or gone; refuses a line list that is sent but empty (`A dispatch needs at least one line`, `WH409`); never
  removes a line that has no lot (old data); refuses a new or raised line of a deleted GRN (`Item belongs to a deleted GRN: ...`,
  `WH409`); and its stock movements reference the dispatch (the line id is in the note). Create refuses a lot deleted meanwhile
  (`A lot of this dispatch was removed meanwhile; reload and try again`, `WH409`) and the lots of a deleted GRN; `add_item_to_order`
  answers `GRN item not found` for a lot of a deleted GRN. Only live invoices count in the guards of edit and delete.
- **Cancelled invoices keep their lines.** `invoice_trl.disp_trl_id` may be empty and its foreign key is `ON DELETE SET NULL`:
  removing a dispatch line, or the dispatch, keeps the lines and amounts of a soft-deleted invoice with an empty link. A live
  invoice's line still blocks the removal (`Cannot modify invoiced items` for an edit; `Cannot delete dispatch <no>: <n> invoice items exist` for a delete).

### Generate Dispatch (D5)

`create_dispatch_with_stock_check` (through its wrappers) reads an optional `source_order_updated_at` in `p_dispatch_data` (the
`order_data.updated_at` of `get_order_with_items`). After the "belongs to another customer" check and before any write, when it is present and
a LINE of the order changed after that value (an `order_items.updated_at` later than it, or a line-change entry in `order_revisions`
written more than 2 seconds later: a line removed, or taken by a dispatch): `ORDER_CHANGED`. A changed note, priority or requested date is not a reason. A retry of the user's own committed create is answered from the idempotency
cache first. Absent: no check.

### Dispatch edits and deletes keep the order in step (D4)

A dispatch line records what it took from an order line (`cart_quantity_consumed`, with `source_order_item_id`, migration 67); the rule
after this change is `cart_quantity_consumed <= disp_qty`. New `warehouse_security.restore_to_order(...)` (not granted to any app role) is
the give-back of the delete function, moved out unchanged and shared. `update_dispatch_smart`, when a line list is sent: a line lowered
or removed gives back `GREATEST(consumed - new, 0)` (migration 122; before it `LEAST(consumed, old - new)`) to the order line of its lot:
only the bags that came from the order and are no longer dispatched, so a line raised past its order and lowered again gives back nothing
until it drops below what it took from the order (order of 10, dispatch raised to 15: 15 to 12 gives 0 back, 15 to 2 gives 8 back). The
give-back goes where the delete's goes, whatever the order's status (the dispatch's source order, else the order of the recorded line, else
the customer's OPEN order, else a new one); a source order that is not OPEN (DISPATCHED or soft-deleted) is opened as the delete opens it
(`status` OPEN, `deleted_at` and `deleted_by` cleared) instead of the bags being dropped. The line keeps `cart_quantity_consumed =
LEAST(consumed, new quantity)`. A line raised
or added takes `LEAST(order line, raise)` from the order line of its lot (the source order if it is OPEN, else the customer's OPEN order;
no order, no line or an order that is not OPEN: nothing is taken, the dispatch still gets the full quantity from stock), reducing or
deleting that line as a create does, and records it in `cart_quantity_consumed` / `source_order_item_id`. The answer gains
`order_sync: {given_back, taken}` (bags, 0 when none) and `updated_at`. A save that sends lines but no `p_dispatch_data` moves the
dispatch's `updated_at` too (migration 122), so the answered token is always new. `delete_dispatch_with_order_cleanup` gives back
`LEAST(cart_quantity_consumed, disp_qty)` per line, and writes the `dispatch_deleted` entry of the order's change log for **every** cart
that got something back (`restored_items` lists the lines actually given back to it, with the amount given back; the source order
keeps its entry, empty when nothing went back, and its status reset as before). The order change log (`get_order_change_log`, unchanged)
also shows what a dispatch took (`order_revisions` action `auto_quantity_reduction`, new format `{action, timestamp, by, dispatch_id,
dispatch_no, grn_item_id, previous_quantity, new_quantity}`, from create from an order, a direct create that reduces a line and an
edit that raises) and what an edit gave back (one `UPDATE` entry per order, `changes.source = 'dispatch_edit'`). A dispatch-driven change
is made whatever the state of the business.

### Dispatch and invoice numbers (D7)

Unchanged in code. The number of a dispatch or invoice that was deleted is free again and `get_next_dispatch_number` /
`get_next_invoice_number` offer it again; a saved create answer of a deleted document is not replayed (migration 120), so the same
document can be entered again; `I1` and `I0001` are different strings. A number another document holds is still refused by name
(`NUMBER_TAKEN`).

### Smaller

`confirm_dispatch_image_upload` and `confirm_grn_image_upload` lock the pending row and answer `{success:false, code:'NOT_FOUND'}` when
it went away; `update_order_item_quantity` and `remove_item_from_order` answer `Order item not found` for a cart line that no
longer exists (the guard lets a missing line through; a line of another customer is still refused with `Customer access denied`).

## Invoices and invoice data

History: migrations 100, 102, 109, 120 and 121.

### Invoices

- `update_invoice` keeps the stored `notes` and `duration_mode` when the request has no such key (the app sends neither; before, a
  missing key stored `NULL` notes and reset the duration mode to `legacy`). A key that is present is stored as sent (`duration_mode` is
  validated).
- The financial year (`inv_fin_year`) must be the one of the invoice date (`WH422`): checked by both `save_invoice` signatures on
  every save and by `update_invoice` only when the edit changes the invoice date or the year. `save_invoice(jsonb)` without a year
  takes the year of the invoice date (it took today's).
- `update_invoice` moving an invoice to another GRN clears the old GRN's `invoiced` flag only when no other live invoice holds it.
- The three-argument `save_invoice` no longer refuses on the phone's estimated header `total`, `labour` and `tax_amount` (the
  server recomputes them); the discount keeps its range check. `delete_invoice` locks the live invoice, re-checks payments, and
  clears `goodsreceived.invoiced` only when no other live invoice holds the GRN (also in its trigger).

### Unbilled bags (D9)

`save_invoice(uuid,jsonb,jsonb[])` (through `save_invoice_internal`) and `update_invoice` (and the one-argument `save_invoice(jsonb)` until 123): before any write, any stock
in any lot of the GRN the request names is `GRN_HAS_STOCK`. An existing invoice of a GRN that now holds stock is refused on its next edit
too. `update_grn`: a line without `id` while the GRN is invoiced is `GRN_INVOICED`.

### Invoice total (D18)

`save_invoice(uuid,jsonb,jsonb[])` and `update_invoice` read an optional number `expected_total` (rupees) in the invoice data. After
`recalculate_invoice_header`, when `abs(invoice.total - expected_total) > 1.00` the save is rolled back and answered `TOTAL_CHANGED` with
`lines` = each line's `disp_trl_id`, `duration`, `no_of_days` as the server just recomputed them. Absent (older apps): no check; their
`total` key stays an estimate.

### `generate_invoice_data_for_grn_with_pricing(p_gr_id uuid, p_duration_mode text DEFAULT 'legacy')`: the invoice form's preview

A successful answer is `{success, header, items, totals, message}`. `rows`, `data` and the 49 per-line second names
and unused figures were removed in migrations 100 and 101. Each of the `items` has 21 keys: `grn_items_id`,
`grn_items_item_id`, `grn_items_item_name`, `grn_items_original_qty`, `grn_items_package_mark`, `grn_items_rack`,
`grn_items_weight`, `grn_items_pricing_mode`, `dispatches_items_id`, `dispatches_items_disp_qty`, `dispatches_id`,
`dispatches_no`, `dispatches_date`, `items_catalog_name`, `grn_date`, `no_of_days`, `billable_days`, `duration`,
`unit_price`, `labour_rate`, `tax_percent`. Lines are ordered by item name, dispatch date, dispatch line id.

### `get_invoice_detail(p_invoice_id)`: lines (migrations 100 and 109)

`invoice.grn_pricing_mode` is returned (the value `get_invoice_data` returns as `header.grn.pricing_mode`). Each line
also carries `item_id` (the catalog item, `goodsreceived_trl.item_id`), `dispatch_id` and `rack`, and the lines come in
the order item name, dispatch date, dispatch line id (`disp_trl_id`). Naming trap: in `get_invoice_data` a line's `item_id` is `invoice_trl.id`;
in `get_invoice_detail` it is the catalog item.

## Images

History: migration 87 (the outside review fixes of 2026-10-15).

### Image upload cancellation

`cancel_grn_image_upload` and `cancel_dispatch_image_upload` answer, for an upload the caller may cancel:
`{success:true, storage_path, message}` (pending, removed), `{success:false, code:'ALREADY_CONFIRMED',
error:'Upload already confirmed', image_id, storage_path}` (confirmed; nothing is changed), or `{success:false,
code:'NOT_FOUND', error:'Pending upload not found'}` (no such row, or not the caller's to see). The app removes
the stored file only after `success:true`.

## Sensors

History: migrations 74 and 111.

### Sensors (migrations 74 and 111)

The sensor bridge, not the app, writes readings (key minted with
`scripts/sensor-ingest-key.sql`, stored hashed; guide:
[SENSORS.md](SENSORS.md#the-ingest-contract)).

`POST /functions/v1/ingest-sensor-readings` (sensor bridge only, no anon key or user token): `Authorization: Bearer <64 lowercase hex ingest key>`; body `{bridge:{id,version}, hub:{id,host,online,firmware}, readings:[{external_id,name,model,temperature,humidity,measured_at,battery_low,battery_percent,signal_level,report_interval_s,kind}]}`, at most 256 KiB and 500 readings. Answers: 200 `{success:true, accepted, duplicates, rejected, devices}`; 401 `Unauthorized` (key missing, malformed or not accepted); 400 `Invalid request` (body shape, or hub or readings refused by `record_sensor_batch`); 405; 503 `Ingestion unavailable` (database not configured, erroring or timing out after 15 s), which the bridge retries. Every answer has `Cache-Control: no-store`.

What the app reads:

- `get_sensor_polling_data(p_since_timestamp)`: same signature and envelope
  (`success`, `poll_timestamp`, `devices[]`, `new_readings[]`, `dashboard`).
  `is_stale`, `connectivity_status` (OFFLINE when the hub is offline, STALE,
  ONLINE) and `battery_status` (LOW, OK, UNKNOWN) are now computed from
  `sensor_status`; each device also carries `measured_at`, `temperature_at`,
  `humidity_at`, `hub_online`, `battery_low`, `signal_level` and
  `last_seen_at`. A temperature or humidity that was never reported is null,
  not 0.
- `get_sensor_history`: same signature, buckets on `measured_at`, averages
  ignore nulls, a sample count per bucket, and period `1` (today, 5-minute
  buckets).
- `get_sensor_device(p_device_id)` (new; administrator, supervisor and staff):
  one device's status, its first reading and its hub. `data` also carries the
  keys of a `devices[]` entry of `get_sensor_polling_data`, so the app reads it
  as the same device: `latest_temperature`, `latest_humidity`,
  `latest_reading_timestamp`, `is_stale` and `earliest_reading_at` repeat
  `temperature`, `humidity`, `measured_at`, `stale` and `first_reading_at`.
- `update_sensor_device(p_device_id, p_device_name, p_location,
  p_staleness_threshold_minutes, p_temperature_min, p_temperature_max,
  p_set_temperature_limits)` (administrator only). The limits (°C, stored in
  `alert_config`) are written only when `p_set_temperature_limits` is true, both as
  given (NULL clears one); the first four parameters work as before. `sensor_status`,
  `get_sensor_device` and `get_sensor_polling_data` carry `temperature_alert`
  (`HIGH`, `LOW` or null). A limit outside -100 to 100 °C, or a lowest not below the highest, is a 200
  `{success:false, error_code:'INVALID_TEMPERATURE_LIMIT', error}`; nothing is written.
- Table `sensor_latest` (one row per device), readable by administrator,
  supervisor and staff until migration 123, which removed the direct read of every sensor table (the app gets sensor data through the RPCs above; it re-read the table on a timer before). Customers and `anon` read no sensor table.
- `capabilities.sensors` in `get-public-config` (from the state's
  `instance.json`, set with `node scripts/set-capability.mjs`); the app shows
  the Sensors screen only when it is true.

A refusal by the guard is now an error, not an answer: migration 74 removed the
`EXCEPTION WHEN OTHERS` handler of `get_sensor_polling_data` and
`get_sensor_history`, so a caller without the role (a customer account) gets
PostgREST's 403 with code `42501` instead of a 200 `{success:false}`; the app's
`useReportQuery` treats `42501` as a refusal. `get_sensor_device` and
`update_sensor_device` answer the same way. An unknown device or period is
still a 200 `{success:false, error_code:'DEVICE_NOT_FOUND'|'INVALID_PERIOD'}`.

`record_sensor_reading` and `update_sensor` were dropped: they were granted to
the service role only and nothing called them.
