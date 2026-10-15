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

Counts at backend `3c32394` and app `MOBILE_REF` `d8af378`, re-run on
2026-10-13:

| Surface | Static result |
| --- | --- |
| Mobile RPC names | 94 found, 0 missing |
| Typed RPC calls (argument names compared) | 133, 0 mismatches |
| Dynamic RPC calls (name in a variable; not checked) | 2: `src/config/supabaseConfig.ts`, `src/utils/serviceErrorHandler.ts` |
| Direct mobile table names | 6 found, 0 missing |
| Literal Edge Function names | 8 found, 0 missing |
| Printing functions | `print-grn-preprinted`, `print-dispatch-preprinted`, `print-invoice-preprinted` (and `print-via-ipp`, `get-printer-status`) exist and answer 503 "Printing is not configured" by design (`functions/main/index.ts`); the app names the three preprinted ones through a variable, so they are not in the literal count |
| `manage-print-jobs` | absent; the app does not call it |

The checker exits 1 only for a missing name or, with `--live`, a mismatch; the
pinned pair above exits 0. Name presence is not signature, security or
behaviour validation, and a missing endpoint is never replaced with a success
stub to make the check pass.

## Tested runtime behaviour

The runtime behaviour is tested by the five operator fixture drivers that CI's
install job runs against a fresh installation, all through
`tests/operator-fixture.mjs`: `operator-api-core.mjs`,
`operator-realtime-core.mjs`, `operator-api-final.mjs`,
`operator-api-rotation.mjs` (`npm run test:rotation`) and
`operator-api-restore.mjs` ([DEVELOPER_HANDOFF.md](DEVELOPER_HANDOFF.md)).
`npm run test:migrations` tests the database itself: real roles, active and
inactive profiles, effective grants and the role policy of every granted
function. `tests/api-demo.mjs` and `tests/review-core.mjs` are the historical
fixed-OTP demos and are not run.

The duplicate five-argument customer-item selector was removed; the remaining
six-argument RPC returns `{ success, data: [], pagination }`. The mobile adapter
now reads this envelope.

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
  p_staleness_threshold_minutes)` (new; administrator only).
- Table `sensor_latest` (one row per device), readable by administrator,
  supervisor and staff, published to Realtime; the app subscribes to it and
  refetches on a change. Customers and `anon` read no sensor table.
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

Migration 71 (2026-10-13) removed the unused Tally accounting integration: the
invoice sync trigger on `invoice` and its never-read queue, the customer-rename
trigger that kept a ledger map, receipt and contra vouchers, bank statement
reconciliation and the company configuration, with 46 functions and 14 tables.
It also dropped 24 dead functions of the baseline that nothing called and that
did not work against the final schema (review 2026-10-13, L1-L10; among them
`create_order`, `cancel_order`, `get_order_queue`, `ignore_order`,
`reactivate_order`, `delete_dispatch_with_stock_restore`, `safe_delete_invoice`,
`auto_generate_invoice_for_dispatch`, `get_customers_with_stock` and the older
sensor and credential functions). None was granted to the app; the app called
none of them.

Recorded payments remain: the `payments` table and its policies are unchanged
and drive Paid and Pending in `get_customer_invoice_summary` and
`get_customer_activity_detail`. The app does not write payments; after
migration 71 only the service role or the database owner does. A future
accounting integration starts from a new design, not from the removed code.

The baseline still holds other functions that are not granted to `anon` or
`authenticated`. They are not API: do not grant one to make a call work; add a
guarded RPC in a new migration instead.

The five printing functions (`print-grn-preprinted`, `print-dispatch-preprinted`,
`print-invoice-preprinted`, `print-via-ipp`, `get-printer-status`) answer 503
from the router until printing is accepted ([PRINTING.md](PRINTING.md),
"Activation acceptance").

## Settings UX batch (migrations 76 to 78, 2026-10-14)

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
must start at 0 and follow on without gaps; customer bands may have gaps. Roles: admin, supervisor,
staff.

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
- Staff: `p_starts_on` today or later, and for a move both `p_move_from` and `p_starts_on` after
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

### `undo_rate_change(p_item_id uuid, p_customer_id uuid, p_price_type text, p_starts_on date)`

Undoes the change of one scope that starts on `p_starts_on` in one transaction: the rows with
`effective_from = p_starts_on` are deleted, and the rows that ended the day before
(`effective_to = p_starts_on - 1`) are opened again, up to the day before the next planned rate of
the scope, or without an end if there is none. This is how "cancel the new rate" and "undo the
stop" work: the rate in force before the change continues. Roles: admin, supervisor, staff; staff
only for a change that has not begun (`p_starts_on` after today), managers also for one that has.
The history trigger records the deletes and updates. Answer:
`{success:true, message:'Change undone', data:{item_id, customer_id, price_type, starts_on, removed:[{id,effective_from}], reopened:[{id,effective_from,effective_to}]}}`.
`error_code`: `INVALID_PRICE_TYPE`, `INVALID_DATE` (same range as `replace_item_rates`; since migration 86 the earliest day is the rate start floor, `data.earliest`),
`PAST_DATE_NOT_ALLOWED` (staff, change starting today or earlier), `ITEM_NOT_FOUND`,
`CUSTOMER_NOT_FOUND`, `NOTHING_TO_UNDO` ("There is no change starting on that day to undo"),
`BANDS_OVERLAP` (reopening would overlap another row; nothing is changed). A customer account is
refused with SQLSTATE 42501.

### Changed price functions

- `create_item_storage_price`, `update_item_storage_price`: refuse an overlap of the same item,
  customer, price type, weight and days (`BANDS_OVERLAP`); a one-day rate is valid
  (`effective_to >= effective_from`); `one_time` stores labour 0; staff get
  `RATE_IN_FORCE_MANAGER_ONLY` (message "Only administrators and supervisors can change a rate that
  is already in force") when the row has started or the new start is in the past.
- `delete_item_storage_price`: the same refusal for staff on a row that has started. The old
  nine-argument `update_item_storage_price` follows the same staff rule.
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

## Customers: deactivate, delete, restore (migration 82, 2026-10-15)

A deactivated business (`active = false`) is offered by no staff customer picker (`search_customers`: new GRN, dispatch, order, and the list-filter
customer search) and not by the all-customers branch of `search_customer_items_for_order`, and
`assign_customer_to_user` cannot give it a new customer login. Everything else keeps working for it: its
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
  message}` for an unknown id (`Customer not found`) or a missing argument.
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
  business answers `{success:false, message:'Customer not found or not deleted'}`.
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

Roles: admin, supervisor, staff. Answer
`{ success: true, data: { tiers: [tier, ...] (by weight_min; [] when never saved), updated_at, updated_by_name } }`
(`updated_at` and `updated_by_name` are null when never saved).

### `set_standard_rate(p_tiers jsonb)`

Roles: admin, supervisor. The role is checked first: anyone else who passes the guard, staff, gets
`STANDARD_RATE_MANAGER_ONLY` whatever tiers they send (a customer is refused by the guard). Then the
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
`{ success: true, data: { tiers: [tier, ...], items_priced } }`.

### `create_item(p_name, p_packaging, p_description, p_active, p_rate_from_item uuid DEFAULT NULL)`

One overload (the four-argument call works unchanged). Same checks and answer as before, and
`data.rate_source`: `copied` when `p_rate_from_item` has default rows in force today, which are copied
(monthly and one-time, one-time labour 0, no customer rates) as new rows from today without an end;
else `standard` when a standard rate is saved (its tiers from today); else `none` and no rate rows.

### `update_item` (signature unchanged)

An item that turns from inactive to active and has no default rate row at all gets the standard tiers
from today (nothing when no standard rate is saved). The answer is unchanged.

## Rates on the GRN sheet and the rate start floor (migration 86, 2026-10-15)

Errors are `{ success: false, error, error_code, data }`; those of `save_grn` and `update_grn` also carry
`message` (the same text), which is what the app reads there. Dates are India days. A band is whole
kilograms, inclusive at both ends.

### `save_grn(..., p_rates jsonb DEFAULT NULL)` and `update_grn(..., p_rates jsonb DEFAULT NULL)`

`p_rates` is the last parameter of each (one overload each; every call that does not name it, the
app's before this migration and fas-sync's, works unchanged). Roles as before: admin, supervisor, staff.

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
     `data.item_id`); two GRN-only bands of one item that share a weight -> `BANDS_OVERLAP`.
  2. `customer` (the GRN's business) and `everyone` (the default rate) entries change the item's rate
     of the GRN's price type from the GRN's India day, any day, for staff too (the staff past-day rule
     of `replace_item_rates` does not apply here). For the rows of that scope that share a weight and a
     day with the days from the GRN day to `to`: a row of a different band -> `BANDS_OVERLAP`
     (`data.index`); a row of the same band that starts after the GRN day -> `RATE_PLANNED`
     (`data.index`, `data.starts_on`); a row of the same band that starts on the GRN day is replaced,
     else it ends the day before the GRN day; with `to` set and the old row open or ending after `to`,
     a copy of it with its old figures starts the day after `to`. The new row runs from the GRN day to
     `to` (open when `to` is null: the old row then ends for good). Entries are applied in list order;
     the history rows name the caller.
  3. The `grn` entries replace the GRN's own rates in `grn_rates`. When the GRN is invoiced and the new
     set differs from the stored one (item, band, figures) -> `GRN_INVOICED` ('The rates of an invoiced
     GRN cannot change'); an equal set is accepted without change.
  4. Every line must have a rate: a GRN-only rate whose band holds the line's weight, else the item's
     rate (`find_storage_price`, for the GRN's business, India day and price type). Otherwise
     `RATE_MISSING` with `data.lines = [{item_id, item_name, weight}]` (distinct, by item name and
     weight).
- The success answers are unchanged.

### `grn_rates` and where a GRN-only rate is used

`grn_rates` (`gr_id`, `item_id`, `price_type`, `weight_min`, `weight_max`, `unit_price`, `labour_rate`,
`tax_percent`, `created_by`, `created_at`) is written only by `save_grn` / `update_grn`; administrators,
supervisors can read it directly (like `item_storage_prices`); customer accounts never can. Invoice rows
(`build_invoice_recalculation_rows`, and so the invoice preview and `save_invoice`) take rent, labour
and tax of a line from one source: the stored invoice figure if the line is already invoiced, else the
GRN-only rate whose band holds the line's weight (the narrowest wins), else the item's rate. Once an
invoice is saved its figures win and the GRN-only rate is "archived"; delete the invoice and it applies
again.

### `get_grn_details(p_grn_id)`: `data.grn.rates`

The `grn` object gains `rates`: `[{id, item_id, item_name, price_type, weight_min, weight_max,
unit_price, labour_rate, tax_percent, archived}]` ordered by item name and `weight_min` (`[]` when none);
`archived` is true when the GRN is invoiced. For a customer account `rates` is always `[]`.

### `get_item_grn_rates(p_item_id uuid)`

Roles: admin, supervisor, staff (a customer account is refused with SQLSTATE 42501). Answer
`{success:true, data:{rates:[{id, gr_id, gr_no, grn_date:'YYYY-MM-DD', customer_id, customer_name,
price_type, weight_min, weight_max, unit_price, labour_rate, tax_percent, archived, created_at}]}}` for
GRNs that are not deleted: not archived first, then newest GRN first, then GRN number.

### The rate start floor

`warehouse_security.rate_start_floor()` is the India day of the first GRN that is not deleted, never
after today (today when there is no GRN). `replace_item_rates` (`p_starts_on`, `p_move_from`) and
`undo_rate_change` (`p_starts_on`) accept a start from the floor to two years after today (it used to be
three years before today). `INVALID_DATE` reads 'The start date must be on or after <floor> and within
two years after today' and carries `data.earliest` (ISO date). `get_item_storage_prices` answers
`earliest_start` (ISO date) as a key of the answer next to `data` and `pagination` (`data` is the list of
rows). `create_item_storage_price` has no window, as before.
