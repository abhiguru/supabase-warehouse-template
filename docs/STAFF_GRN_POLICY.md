# Staff GRN permissions and cache consistency

The operator selected this policy on 3 October 2026: active, approved staff may
view, create and edit warehouse GRNs. GRN deletion remains limited to admins
and supervisors. Customers retain their assigned-customer read boundary.

Migration 18 adds an explicit GRN RPC allowlist and read policies for GRN
headers, items and attachments, plus customer lookup needed by the receipt
form. Existing business RPCs retain their quantity/stock and dependency checks.
Direct staff table writes, soft deletion, arbitrary stock edits, administration,
invoice creation and general dispatch permissions were not granted by migration 18.
The later approved dispatch/invoice policy is recorded below.

Staff can register and confirm GRN images and insert/update their own pending
registered storage objects. They can read confirmed GRN attachments. Confirmed
image-object deletion/overwrite and unrelated buckets remain restricted. The
existing cancellation RPC can remove pending metadata; storage deletion is
still restricted and no new image-failure/retry acceptance is claimed.

The mobile GRN activity report includes staff. Its GRN edit dispatch-presence
helper uses the existing authorized GRN detail summary instead of a direct
dispatch-table read. Missing or malformed history fails closed. No application
RPC signature changed.

## Cache repair

Two defects kept the legacy GRN list stale. Fresh setup never initialized
mv_refresh_queue, so its existing dirty/refresh triggers had no entries to
process. Bulk update_grn then suppressed the item dirty trigger and marked
mv_refresh_status, which the starter's synchronous refresher does not consume.

Additive migration 19 registers the seven existing refresh targets and brings
their views up to date under the existing advisory lock. Migration 20 shares
one private refresh routine between the normal trigger and the bulk-edit
completion path. After an edit, it marks and refreshes the seven supported
lists before returning. This covers changes to quantity, customer, date, item
identity and weight without an external worker or a test-only refresh.

The helper is not callable by application roles. The existing authorization,
business logic and transaction boundaries are retained. A rejected edit rolls
back intermediate changes; the regression checks both stored and cached stock,
header preservation and restoration of the temporarily suppressed trigger.
This retains the starter's synchronous refresh model and makes no production
capacity claim.

## Installation and validation

Use the documented setup sequence from the reviewed source. Migrations 18–20
are additive; never edit an applied migration. Setup also runs
scripts/configure-storage.sql for the scoped Storage policies. Existing frozen
campaign warehouses and APK10 were not changed by this source/test work.

On 3 October at 15:25 UTC, the final authorized disposable database run passed
at source fc149114694c1d8e44810b20eeaa82648890549d (application cache repair
at a6c4d0d98cae6c0cb407b7acec45e26c5b5d5720). It exercised:

- Fresh migrations, an unchanged second migration pass and changed-checksum rejection.
- Ordinary fictional staff authentication; cross-warehouse GRN create/read/edit;
  immediate legacy-list, customer-stock and daily-receipt cache values.
- Invalid-edit rollback, unchanged unrelated customer stock, restored dirty
  trigger and denial of direct access to the refresh helper.
- Registered pending-image SQL insert/update/read and confirmed-image read;
  denial of unregistered uploads, unrelated buckets and confirmed overwrite/delete.
- Denial of staff GRN deletion, administration, invoice/customer creation and
  direct table writes; assigned-customer isolation, retained admin/supervisor deletion and
  loss of access after disabling the account or revoking its session.
- Existing core business/invoice, security, operator-authentication configuration
  and retention regressions.

The runner used a fresh network-disabled disposable database with no host ports
or warehouse mounts, and removed it after completion. Backend 127 unit checks,
the exact mobile contract and source/history scans passed. All 50 mobile suites
/ 323 tests had passed at mobile9db13ac; its terminal CI failed only dependencies.
Current backend publication still requires its own exact CI result.

These Storage checks exercise SQL policies against the actual setup script,
which runs twice. The fixture models later Storage bucket columns absent from
the pinned database's base schema. It leaves the unrelated nullable legacy
Storage owner field unset: operator sessions use registered GRN metadata
ownership rather than GoTrue auth.users. No production schema or policy was
weakened for this fixture. Actual Storage HTTP/file bytes and native staff
acceptance remain separate outstanding evidence. No new APK was built.

## Preserved failures and execution limits

All five failed local attempts remain preserved alongside the passing sixth:

1. The first exposed a denied-delete exception handler reading an unassigned
   record; migration 18 preserves the authorization error.
2. The second stopped on a test include path inaccessible inside the container.
3. The third stopped on missing modern bucket columns in the base Storage schema.
4. The operator authorized one extra run of the queue initialization. Initial
   listing passed, but edited stock remained stale; that case stopped as agreed.
5. The operator then reopened the cache repair with at most two additional
   five-minute tests. The first passed the cache/rollback assertions and stopped
   on the SQL fixture's unrelated legacy GoTrue owner foreign key.
6. The final allowed run, with that fixture corrected, passed the full suite.

Earlier backend CI run37121635390 failed the legacy-list assertion; its other
six jobs passed. The older mobile authentication-mock CI failure is also retained;
its correction requires the authenticated GRN-detail query and no direct table
query. No failure was erased or converted into a pass.

Both reopened local test slots are consumed. Native retry limits, other campaign
gates and the original deadline are unchanged. This closes the source/SQL cache
regression, not installed-APK/native, full campaign or production acceptance.

## Staff dispatch and invoice decision, 5 October 2026

The operator explicitly authorized staff dispatch and invoice work. Additive
migration 21 permits the existing create/read/update document RPCs for active
staff and adjusts only the dispatch implementations' legacy role checks and
invoiceable-GRN lookup. It does not change shared ownership helpers, direct
table/storage policies, pricing mutations or destructive permissions.

The isolated regression found an independent dispatch-list error: a varchar[]
materialized-view column was compared with a text[] GRN filter. The migration
casts that column to text[] for the existing predicate; API signatures and
business arithmetic remain unchanged.

The third and final bounded disposable migration run passed, including ordinary
mock-provider staff login, partial/final dispatch, idempotent retry with correct
stock, invoice preview/save/read/list and denials for invoice deletion, role
administration and pricing mutation. Both failed runs remain private evidence:
the original list assertion and the diagnosed array-operator failure. The
existing security, GRN, operator authentication, retention and immutable
migration-ledger checks also passed. No existing warehouse was changed.

Source validation passed all 142 Node 22 unit tests. The earlier Node 18 result
is preserved; it used an unsupported runtime. A refusal-fixture test now sets
its deliberately public binding mode explicitly, so a private umask cannot
silently convert it into an accepted private binding.

This is source/disposable-database evidence. Staff native acceptance remains
subject to the existing exhausted-attempt limit. Caller-RLS reads for staff
PDFs and Realtime require the separately prepared document-read proposal;
those policies are not installed by this RPC-only fix. New backend reproduction,
candidate binding, native qualification and final soak remain outstanding.

## Approved staff document reads, 5 October 2026

After review of the narrower concrete proposal, the operator separately
approved migration 22: active staff may read dispatch/invoice headers and lines
warehouse-wide, plus confirmed dispatch-image metadata or their own pending
metadata. No direct pricing read, write, delete, storage-object or customer-role
policy is added. Private PDFs retain caller-RLS authorization and server-only
expiring document links.

The first bounded network-isolated disposable database run passed. It checked
actual invoice-to-dispatch-to-GRN PDF joins, exact populated document counts,
confirmed/own-pending image metadata visibility, no direct document updates or
deletions, assigned-customer access and reciprocal unassigned-customer denial,
and zero document reads after disabling staff or revoking its ordinary session.
Existing migration-21 business/idempotency, GRN, authentication, security and
ledger regressions passed again as dependencies. The earlier migration-21
failures remain unchanged. This is SQL-policy evidence, not native Realtime
or generated-PDF acceptance. No installed warehouse was modified.

## Clean installation and HTTP acceptance, 5 October 2026

Application `d8da56f85ad7f3bd8b258b0828b42b1c1a405faa` passed all seven
exact CI jobs (run `37287883376`). Tooling
`da1038169ce285ffa8260fb737024dbd462fc91c` adds the guarded ordinary staff
HTTP/PDF driver; all 153 source unit tests and the source scan passed.

A clean pinned checkout with fresh state, independently generated warehouse
credentials and identity, declared loopback port/subnet overlays, and only
hash-proven unchanged container-image reuse passed installation, migrations,
administrator bootstrap, doctor and the unchanged fixture guard. The first
separate state used an incompatible generated fictional provider key and was
refused by the final guard after setup/doctor passed. That state and failure
remain preserved. The corrected attempt uses the documented no-delivery
sentinel; it does not rotate or copy another warehouse's actual credentials.

The existing backend business API regression passed on the fresh warehouse.
The staff-specific HTTP case enrolled normally, used the normal administrator
approval/role APIs, and authenticated as literal staff assigned only to B. It
created a fresh A receipt, partially/finally dispatched it, reconciled stock
10 → 7 → 7 → 0 across an unchanged retry, saved/read its invoice, downloaded
actual dispatch and invoice PDFs, and denied B's A invoice PDF and staff invoice
deletion. No external provider, counter reset or native actor was used.

Independent read-only reconciliation retained 65 whole table hashes and
historical row hashes for 18 affected tables, old sessions/OTPs/audits/object
catalogs, and old actual object bytes; ordinary OTP increments were exactly four.
The two incorrect imported-column subset queries remain preserved. A controller
syntax refusal occurred before any action; its separately corrected preparation
passed. Repeat setup preserved identity, credentials, administrator/business
records, all 85 table snapshots apart from the declared SMS configuration
updated_at timestamp, and all seven actual stored files.

A fresh supervised helper passed real TLS discovery, genuine instance identity,
private IPC readiness, unchanged 12-hour cap and normal stop, with zero OTP or
authentication requests and exact before/after state equality. Two earlier
pre-start helper preparations remain preserved; the final preparation verified
all 403 archived helper files against exact source `5786c4a` and used its existing
approved unused port. There is no restore or production acceptance claim.

Reproduce from the pinned application above using OPERATOR_INSTALL.md and the
fictional provider input kept with the private pilot tooling (see HISTORY.md). Run ordinary npm ci, preflight,
configure/setup, doctor and fixture guard from clean source with fresh state;
record the independently unused loopback port/subnet, configuration fingerprints,
and exact immutable image/context proof if reusing container binaries. Run
operator-api-core.mjs before the bounded, private-bound
operator-api-staff-documents.mjs tooling. Then rerun the exact setup inputs and
compare actual records/credentials/objects before and after. All provider delivery
is mocked using the existing service-only prepare/finish/verify functions with
ordinary limits; do not invoke the external SMS worker or use fixed OTPs.

These results do not transfer to the original campaign warehouse or establish
native staff controls, Android PDF handling, Realtime delivery or the final soak.
The original campaign source/artifact bindings and exhausted native-case limits
remain intact pending a separately qualified candidate transition.

## Preserved primary candidate transition, 5 October 2026

The original fictional primary was consistently backed up locally before retiring
its released TLS/fault helpers. All seven archive checksums verified, database
and Storage catalogs were readable, and before/after snapshots matched exactly:
85 protected tables and 20 actual stored files. No restore or transfer occurred.
The original owned API30 AVD was stopped cleanly and separately archived; its
archive checksum and catalog verified. Its own storage remains in place.

The operator authorized one additional transition after three pre-migration
refusals. Initial snapshot ownership, existing-container checkout ownership and
retained monitoring-profile containers were diagnosed; all failed attempts remain
preserved. The corrected handoff ran the unchanged old-checkout Compose wrapper
with its documented monitoring profile, without deleting volumes or images.
Setup then ran from a separate clean pinned d8da56f checkout using the same
private state, existing project/network overlay and eight independently verified
unchanged amd64 image contexts and identities. Migrations 21–22, doctor and the
unchanged fixture ownership guard passed. All 85 protected-table stable hashes,
20 stored-file hashes, identity, configuration and credentials were unchanged;
only the declared SMS-configuration updated_at timestamp differed.

A new supervised normal-route core helper, using verified frozen tooling5786c4a,
passed actual TLS discovery for that genuine primary and private IPC readiness.
Its 12-hour lifetime and no-restart rule remain intact. No OTP or authentication
requests were made, and before/after preservation snapshots matched exactly.
Private evidence: candidate-transition0505-01/primary-transition-result04.json
and staff-runtime0505-01/staff-normal-core01-proof01.json.

This closes the preserved primary installation/ownership transition. It does not
transfer old APK/native results to the new candidate or reopen exhausted native
cases. A new increasing standalone x86_64 APK is being built after all eleven
clean-source validation gates passed; installed native staff acceptance, other
remaining cases, final readiness, eight-hour soak and natural expiry remain open.

## Second-pass corrections, 8 October 2026

An independent review found the earlier description wider than the code in two
places and narrower in one. The operator decided the following; migrations 23
to 25 implement it and `tests/staff_dispatch_invoice_access.sql`,
`tests/core_pilot.sql` and `tests/user_status_enrollment.sql` prove it.

- **Pricing.** `get_item_storage_prices` is no longer in the staff allowlist; it
  returned every customer's price list to staff because its internal filter
  skips the staff role. Staff obtain prices only through
  `generate_invoice_data_for_grn_with_pricing` for a specific GRN. The table
  policy was already closed.
- **Totals are server-computed.** `save_invoice` (both signatures) and
  `update_invoice` ignore client-supplied `labour`, `tax_amount` and `total` for
  every role and derive them from the saved lines and the stored `discount`
  (migration 24, see [INVOICE_RULES.md](INVOICE_RULES.md)). Line rates remain
  inputs within a range: charge and labour rate from 0 to 999999, tax from 0 to
  100 (migration 41). A missing, duplicate or unrelated line rolls the whole
  save back.
- **A dispatch line is invoiced once.** A save for a receipt that is already
  invoiced, or with a line that is on another invoice, is refused for every
  role (migration 41). Only an administrator or supervisor can free a receipt,
  by deleting its invoice; an invoice with payments cannot be deleted.
- **Discount changes are kept.** Besides the last reason and author on the
  invoice, every change is appended to `invoice_discount_history`, readable by
  administrators and supervisors only (migration 41).
- **Edits may remove lines and images; whole documents cannot be deleted.**
  `update_grn` removes undispatched lines and unlisted images, `update_dispatch_smart`
  replaces dispatch lines and `update_invoice` replaces invoice lines. That is
  the accepted meaning of "edit". The explicit `delete_*` RPCs and direct table
  writes stay denied, which the test suite now proves through the real guarded
  RPCs rather than a direct probe that could never fail.
- **Dispatch workflow completion.** Staff may call the dispatch GRN picker
  (`get_customer_grns_with_stock_dispatch_sorted`), the recent-dispatch feed
  (`get_recent_dispatched_orders`) and the dispatch photo RPCs
  (`register_dispatch_image_upload`, `confirm_dispatch_image_upload`,
  `cancel_dispatch_image_upload`), with matching `dispatch-images` storage
  policies that mirror the GRN ones. Without these the staff dispatch form
  failed for unassigned customers and dropped photos silently.
- **Cancellation ownership.** Pending GRN and dispatch uploads can be cancelled
  only by the registering profile or an administrator/supervisor.
- **Refusals roll back.** A refused dispatch edit (invoiced lines, insufficient
  stock) no longer leaves a half-applied header (migration 25).
- **Status changes.** `update_user_status(false)` disables the enrollment and
  revokes sessions; `update_user_status(true)` re-approves a disabled or
  rejected profile. Pending enrollments still need `operator_review_enrollment`.

## Orders and queue, 9 October 2026

The operator decided that staff have the same order access as supervisors.
Migration 28 adds these RPCs to the staff allowlist: `get_orders_list`,
`get_order_with_items`, `get_or_create_cart`, `add_item_to_order`,
`update_order_item_quantity`, `remove_item_from_order`, `get_cart_dispatches`,
`search_customer_items_for_order`, `get_customer_items_for_order_selection` and
`get_order_change_log`. Staff can read `order_revisions`. Direct table writes to
orders and order items stay denied for staff. Customers keep access to their
own carts only, and can now read their own order history.
`tests/order_screen.sql` proves both.

## One customer per dispatch, 10 October 2026

Staff, supervisors and administrators may dispatch any customer's goods, but one
dispatch carries one customer's lots. Migration 39 enforces this for every role:

- `create_dispatch_with_stock_check` and `update_dispatch_smart` refuse a line
  whose receipt belongs to another customer than the dispatch.
- `update_dispatch_smart` lets the dispatch customer change only when every line
  the edit leaves belongs to the new customer.
- `update_grn` does not change the customer of a receipt that has dispatch
  lines, an invoice or a line in an open cart. Its quantity and stock rules are
  unchanged: a dispatched line keeps its quantity and cannot be removed.

Records saved before migration 39 are not checked or repaired.
`tests/dispatch_lot_ownership.sql` proves the rule and the dispatch-edit
refusals of migration 25 (invoiced lines, insufficient stock).

## No direct table writes for any role, 10 October 2026

Until migration 42 administrators and supervisors could insert, update and
delete rows of the nineteen business tables with a plain table call
(`PATCH /rest/v1/invoice`, `PATCH /rest/v1/goodsreceived_trl`,
`POST /rest/v1/stock_movements`, `DELETE /rest/v1/dispatch_trl`), which went
around the server-computed invoice totals, the rate and discount rules, the
stock checks, the one-customer-per-dispatch rule and the dependency checks of
the delete RPCs. The owner decided to remove that path and keep the reads.

Migration 42 revokes INSERT, UPDATE and DELETE on `customers`, `items`,
`item_storage_prices`, `goodsreceived`, `goodsreceived_trl`, `dispatch`,
`dispatch_trl`, `invoice`, `invoice_trl`, `payments`, `orders`, `order_items`,
`grn_images`, `dispatch_images`, `stock_movements`, `print_jobs`,
`sensor_devices`, `sensor_readings` and `sensor_health_events` from the app's
database role and makes the administrator/supervisor policy on each read-only.
A direct write now answers HTTP 403 for every role. Consequences:

- Every change to these tables by an app session goes through a guarded RPC
  (`save_grn`, `update_grn`, `create_dispatch_with_stock_check`,
  `update_dispatch_smart`, `save_invoice`, `update_invoice`, the `delete_*`
  RPCs, the customer, item, price, image and cart RPCs). Their role rules are
  unchanged.
- An order's note, priority and requested date are changed with
  `update_order_metadata(p_order_id, p_note, p_priority,
  p_requested_dispatch_date)`, now granted. Administrators and supervisors only;
  each change is written to the order history.
- `payments`, `stock_movements`, `print_jobs` and the three sensor tables have
  no write RPC. They are written by the server side only (Edge functions with
  the service key, operator scripts, Studio), as before.
- The staff and customer read policies of migrations 3, 18, 22 and 28 and the
  own-profile grant `UPDATE(name, display_name)` on `user_profiles` are
  unchanged.

`tests/direct_write_guard.sql` proves the refusals for administrator,
supervisor, staff and customer on all nineteen tables, the unchanged reads, and
that the RPC paths still apply their rules (a changed line rate recomputes the
header, an out-of-range rate and a dispatch above the stock are refused, the
delete RPCs keep their dependency checks).
