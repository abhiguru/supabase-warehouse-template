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
