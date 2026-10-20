# Mobile/backend API coverage

The app and the backend are checked as a pair. CI's `contract` job checks out
the app at the commit pinned in `.github/workflows/ci.yml` (`MOBILE_REF`) and
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
`src/services/imageDeletion.ts`) are not checked. The pin in `.github/workflows/ci.yml` is app commit `e6a513b`: the
older pin `d8af378` still called `get_dispatch_list`, which this release drops, so it must not be used.
`get-config` still publishes `urls.realtime` although the `/realtime/v1` route is gone; the app ignores it, and it can be
dropped once `minimumClientVersion` is past the builds that read it. The printing functions (`print-grn-preprinted`, `print-dispatch-preprinted`, `print-invoice-preprinted`,
`print-via-ipp`, `get-printer-status`) exist and answer 503 "Printing is not configured" by design
(`functions/main/index.ts`); the app names the three preprinted ones through a variable, so they are not in the literal
count. `manage-print-jobs` is absent; the app does not call it.

The checker exits 1 only for a missing name or, with `--live`, a mismatch. Name presence is not signature, security or
behaviour validation, and a missing endpoint is never replaced with a success stub to make the check pass.

## Tested runtime behaviour

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

## Sensors (migration 74)

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
  (`HIGH`, `LOW` or null).
- Table `sensor_latest` (one row per device), readable by administrator,
  supervisor and staff; the app re-reads it on a timer. Customers and `anon` read no sensor table.
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

## Legacy and dormant functions

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

## Settings UX batch (migrations 76 to 78, 2026-10-14)

**Staff lose item pricing (migration 90, 2026-10-16, owner decision).** Every function of this section
and of the next ones that reads or writes rates (`get_item_storage_prices`, `create_item_storage_price`,
`update_item_storage_price`, `delete_item_storage_price`, `replace_item_rates`, `undo_rate_change`,
`get_standard_rate`, `set_standard_rate`, `get_item_grn_rates`) is for administrators and supervisors
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

### `replace_item_rates(p_item_id uuid, p_customer_id uuid, p_price_type text, p_starts_on date, p_bands jsonb, p_replace_later boolean DEFAULT false, p_mode text DEFAULT 'change', p_move_from date DEFAULT NULL, p_seen_rows uuid[] DEFAULT NULL)`

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

`find_or_create_item_storage_price` is for administrators and supervisors only (no app code calls
it); it uses the India day, stores labour 0 for one-time and refuses an overlapping row
(`BANDS_OVERLAP`). `get_item_storage_prices` without `include_expired` hides rows that ended before
the India day.

### `undo_rate_change(p_item_id uuid, p_customer_id uuid, p_price_type text, p_starts_on date, p_seen_rows uuid[] DEFAULT NULL)`

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

### Changed price functions

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

## Users screens (migration 113, tweak batch 2026-10-20)

All answers below are `{ success, ... }`; a refusal is `{ success: false, error, error_code, message }` (`error` keeps its
earlier value, `error_code` is the stable code the app reads). The user row carries the same keys in `get_users_list`
(`users[]`) and `get_user_details` (`user`).

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

## Customers: deactivate, delete, restore (migration 82, 2026-10-15)

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
- `safe_delete_customer(p_customer_id uuid, p_permanent boolean DEFAULT false)`. "Data" means any GRN,
  dispatch or invoice row (deleted rows count), any payment, any customer-specific rate
  (`item_storage_prices.customer_id`), any active user assignment, and any order that has lines or is not
  OPEN. For a business WITH data: soft (`p_permanent = false`) deactivates it instead and answers
  `{success:true, delete_type:'deactivated', message:'"<name>" has records, so it was deactivated instead of
  deleted.', related_records}`; permanent answers `{success:false, message:'Cannot delete "<name>": it has
  GRNs, dispatches, invoices, payments, rates, linked users or orders. Deactivate it instead.', related_records}`. `related_records` is
  `{grn_count, dispatch_count, invoice_count, order_count, payment_count, rate_count, assignment_count}`.
  A business without data: soft delete as before (`delete_type:'soft'`, its empty OPEN carts stay);
  permanent (`delete_type:'permanent'`) also removes its empty OPEN carts and switched-off assignments.
- `restore_customer(p_customer_id uuid)`: takes a business that is deleted OR inactive and makes it active
  with `deleted_at` / `deleted_by` cleared (same as `set_customer_active(id, true)`); an active, undeleted
  business answers `{success:false, message:'Customer not found or not deleted'}`; it is refused with `DUPLICATE_MOBILE` like Activate (see "Customers: duplicates, stale edit, deactivated search") when another active customer uses the number.
- `get_orders_list` leaves out orders of a deleted business.
- Five readers that no longer hide a deactivated business from staff and administrators (filter is
  `deleted_at IS NULL`): `get_invoices_list`, `get_all_stock_summary`, `get_item_wise_stock_list` (all
  customers), `get_all_customer_activity_summary`, `get_item_dispatch_records`.

## Standard rate (migration 85, 2026-10-15)

The facility's standard monthly rate: weight tiers (whole kilograms, inclusive, from 0, no gaps) with
rent, labour and tax, kept in `standard_rate_tiers` (read by administrators and supervisors, written
only by `set_standard_rate`). A tier is
`{ weight_min, weight_max, unit_price, labour_rate, tax_percent }`. Errors are
`{ success: false, error, error_code, data }`. A later change of the standard rate never changes an
item that already has a rate.

### `get_standard_rate()`

Roles: admin, supervisor (staff are refused by the guard since migration 90). Answer
`{ success: true, data: { tiers: [tier, ...] (by weight_min; [] when never saved), updated_at, updated_by_name } }`
(`updated_at` and `updated_by_name` are null when never saved).

### `set_standard_rate(p_tiers jsonb, p_expected_updated_at timestamptz DEFAULT NULL, p_dry_run boolean DEFAULT false)`

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

### `create_item(p_name, p_packaging, p_description, p_active, p_rate_from_item uuid DEFAULT NULL)`

One overload (the four-argument call works unchanged). Same checks and answer as before, and
`data.rate_source`: `copied` when `p_rate_from_item` has default rows in force today, which are copied
(monthly and one-time, one-time labour 0, no customer rates) as new rows from today without an end;
else `standard` when a standard rate is saved (its tiers from today); else `none` and no rate rows.

### `update_item` (signature unchanged)

An item that turns from inactive to active and has no default rate row at all gets the standard tiers
from today (nothing when no standard rate is saved). The answer is unchanged.

## Items screens (tweak 2026-10-20)

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

## Rates on the GRN sheet and the rate start floor (migration 86, 2026-10-15)

Errors are `{ success: false, error, error_code, data }`; those of `save_grn` and `update_grn` also carry
`message` (the same text), which is what the app reads there. Dates are India days. A band is whole
kilograms, inclusive at both ends.

Line lengths (migration 95): a GRN line's `item_name` can have 80 characters and its `packaging` 40, as the
catalog (`items.name`, `items.packaging`). `save_grn` and `update_grn` check every line first and write nothing
when one is longer: `{ success: false, error_code: 'item_name_too_long' | 'packaging_too_long', error, message,
data: { limit: 80 | 40, index } }`, `index` being the line's position in `p_items`, counted from 0.

### `save_grn(..., p_rates jsonb DEFAULT NULL)` and `update_grn(..., p_rates jsonb DEFAULT NULL)`

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
  `{scope:'customer'|'everyone', item_id, weight_min, weight_max, to:'YYYY-MM-DD'|null, unit_price, labour_rate, tax_percent}`.
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

### `grn_rates` and where a GRN-only rate is used

`grn_rates` (`gr_id`, `item_id`, `price_type`, `weight_min`, `weight_max`, `unit_price`, `labour_rate`,
`tax_percent`, `created_by`, `created_at`, `updated_by`, `updated_at`) is written only by `save_grn` / `update_grn`; administrators,
supervisors can read it directly (like `item_storage_prices`); customer accounts never can. Invoice rows
take rent, labour and tax of a line from one source: the GRN-only rate whose band holds the line's weight (the
narrowest wins), else the item's rate. The invoice form's preview (`build_invoice_form_lines`, migration 102) never
reads `invoice_trl`: it prices the GRN's dispatched lines afresh, with the duration from `calculate_invoice_duration`.
`save_invoice` calls `calculate_invoice_duration` itself and takes charge, tax and labour from the lines it is sent.
`build_invoice_recalculation_rows` (which also takes the stored invoice figure of an already invoiced line) is now
called only by `recalculate_invoice_items` (service_role only, not used by the app); `get_grn_item_rates` also takes
the stored invoice figure first (`source 'invoice'`, from the lines of any live invoice of the lot, migration 88),
then follows its rule. Once an invoice is saved its figures win and the GRN-only rate is "archived"; delete the
invoice and it applies again.

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

### `get_grn_details(p_grn_id)`: `data.grn.rates`

The `grn` object gains `rates`: `[{id, item_id, item_name, price_type, weight_min, weight_max,
unit_price, labour_rate, tax_percent, archived}]` ordered by item name and `weight_min` (`[]` when none);
`archived` is true when the GRN is invoiced. For a customer account and, since migration 90, for staff, `rates` is always `[]`.

### `get_item_grn_rates(p_item_id uuid)`

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

### The rate start floor

`warehouse_security.rate_start_floor()` is the earlier of the India day of the first GRN that is not
deleted and today minus 1095 days (so never later than the old three-year window; a facility with older
GRNs can start rates further back, one with no GRN keeps today minus 1095). `replace_item_rates` (`p_starts_on`, `p_move_from`) and
`undo_rate_change` (`p_starts_on`) accept a start from the floor to two years after today (it used to be
always three years before today). `INVALID_DATE` reads 'The start date must be on or after <floor> and within
two years after today' and carries `data.earliest` (ISO date). `get_item_storage_prices` answers
`earliest_start` (ISO date) as a key of the answer next to `data` and `pagination` (`data` is the list of
rows). `create_item_storage_price` has no window, as before.

## Outside review fixes (migration 87, 2026-10-15)

### Dispatch

- `create_dispatch_with_stock_check` (both overloads) and `update_dispatch_smart` refuse the same lot
  twice in the lines: `The same lot appears twice in the dispatch lines` (SQLSTATE `WH409`; the create answer
  is `{success:false, error, error_code:'WH409'}`, the edit answer `{success:false, error}`). Nothing is stored.
- A dispatch made from a cart (`source_order_id`) must be for the cart's customer: create refuses a missing,
  deleted or other customer's cart with `The order belongs to another customer` (`WH409`);
  `update_dispatch_smart` refuses moving a dispatch that has a `source_order_id` to a customer other than
  the cart's (same text and code; a dispatch already for another customer can still be edited without
  changing its customer). `get_cart_dispatches`, `get_orders_list` and `get_order_with_items` show only a dispatch of the cart customer's own.
- Create takes the document lock (advisory 71040) before it looks up the idempotency key, so a retry that
  overlaps its first call waits and is then answered from the cache (`from_cache:true`), never with a
  unique-key error. A dispatch from a cart reads the cart line `FOR UPDATE`: a concurrent change of the line's
  quantity is not lost.
- `get_grn_list` (`total_weight`) and `get_customer_dispatch_items` (`total_weight`) sum weight as numeric: a
  total above 2147483647 kg is a number, not an error.

### Users and rates

- `update_user_role` and `update_user_status` take the user lock (advisory 71043) after the caller check and
  read the target row `FOR UPDATE`: a supervisor who acts at the same moment as an administrator promoting
  the target waits and is refused (`Supervisors cannot modify admin users`).
- `create_item_storage_price` (with `p_price_type`), both `update_item_storage_price` overloads,
  `find_or_create_item_storage_price` and `delete_item_storage_price` take the same per-scope advisory lock as
  `replace_item_rates` (item, customer or `default`, price type) before they read the scope, so writers of one
  scope take turns and the later one sees the earlier one's rows (`BANDS_OVERLAP` for an overlap).
  `find_storage_price` breaks a last tie by row id (a fixed tie-break, the lower row id).

### Image upload cancellation

`cancel_grn_image_upload` and `cancel_dispatch_image_upload` answer, for an upload the caller may cancel:
`{success:true, storage_path, message}` (pending, removed), `{success:false, code:'ALREADY_CONFIRMED',
error:'Upload already confirmed', image_id, storage_path}` (confirmed; nothing is changed), or `{success:false,
code:'NOT_FOUND', error:'Pending upload not found'}` (no such row, or not the caller's to see). The app removes
the stored file only after `success:true`.

## List freshness (migration 106, 2026-10-19)

Every list RPC reads the tables, so a write that has committed is in the next list read: there is no
refresh job and no delay. `get_list_freshness()`, the legacy `get_dispatch_list` and the `get_all_grn_items(p_catalog_id, ...)`
overload no longer exist (migration 106). `get_invoices_list`
keeps its arguments, sorts, filters and answer; rows that tie on every sort key now come back in a fixed order
(by invoice id). The answer of a write RPC (`save_grn`, `update_grn`, `create_dispatch_with_stock_check`,
`update_dispatch_smart`, `save_invoice`, `update_invoice`, ...) is still the authoritative result of that
write.

## GRN lists by receipt, and low stock (migration 98, 2026-10-18)

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

## Customers: duplicates, stale edit, deactivated search (customers review, migration 112)

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
  found). Any other unique violation is `DATABASE_ERROR`. Other codes: `PERMISSION_DENIED` (not administrator or
  supervisor), `VALIDATION_FAILED` (`field` `name` or `mobile`), `DATABASE_ERROR`.
- `update_customer(..., p_image_urls, p_expected_updated_at timestamptz DEFAULT NULL)`: the mobile is checked only when
  `p_mobile` is sent AND its key differs from the customer's own (pairs that already share a number stay editable; a
  deactivated customer's number is allowed); same `DUPLICATE_MOBILE` / `DUPLICATE_NAME` / `details` object as above.
  With `p_expected_updated_at` given and different from the row's `updated_at`, answers `STALE_CUSTOMER` (no `field`) and
  changes nothing. Send `updated_at` back exactly as the string read from `customers` (microseconds): a JavaScript `Date`
  round-trip truncates to milliseconds and would always answer `STALE_CUSTOMER`. A blank `p_name` is `VALIDATION_FAILED`;
  a name is trimmed. Other codes: `PERMISSION_DENIED`, `CUSTOMER_NOT_FOUND` (unknown id), `DATABASE_ERROR`.
  `set_customer_active` has no `error.code` for an unknown id or a missing argument (it answers `{success:false, message}`).
  **Activate re-checks the mobile (owner decision 2026-10-20).** `set_customer_active(id, true)`, `update_customer(..., p_active => true)`
  on a deactivated or deleted customer (the number checked is the one sent in the same call, else the stored one) and the legacy
  `restore_customer` answer `{success:false, data:null, message:'<other name> already uses this mobile number. Change one of the numbers
  first.', error:{code:'DUPLICATE_MOBILE', field:'mobile', details:{customer_id, name, active:true}}}` when another ACTIVE, undeleted
  customer has the same mobile key; `details` is the OTHER customer, and nothing changes. A customer with no mobile is never refused,
  and an already active customer is not re-checked on a normal edit (`update_customer` with `p_active = true` on an active customer).
- `search_customers(p_search_query text, p_limit integer DEFAULT 20, p_include_inactive boolean DEFAULT false)`: rows
  now also carry `active` and `deleted` (booleans). `p_include_inactive = true` is honoured for administrators and
  supervisors only and then also returns deactivated customers; for staff and customers it is ignored (active customers
  they may access only). Soft-deleted customers are never returned. A query made only of digits and number punctuation
  also matches the mobile by its digits, by its key, and (when it starts `91` and is longer than 2 digits) by the digits
  after `91`, all as prefixes; any such match ranks first.
- The Customers list and the Edit form read the `customers` table directly (no list RPC): the "Deactivated" filter is
  `active = false` and the two counts are two `count: 'exact', head: true` reads (`active = true`, `active = false`);
  `updated_at` is already a column of that read.
