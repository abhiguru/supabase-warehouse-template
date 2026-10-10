# Staff GRN permissions and cache consistency

This document is a dated record of role decisions. The current rules for every
role are in the last section, [The server admits what the app offers, 11 October
2026](#the-server-admits-what-the-app-offers-11-october-2026); where an earlier
section says otherwise, a note marks it as superseded.

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

> Superseded in part on 11 October 2026 (migration 45): staff may remove a
> confirmed photo with `delete_grn_image` / `delete_dispatch_image` and then
> delete its file. A file that an image row still names cannot be deleted or
> overwritten by staff.

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

> Superseded in part on 11 October 2026 (migration 45): staff may now read and
> change item prices and remove photos. Invoice deletion and role
> administration stay refused for staff.

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
  **Superseded on 11 October 2026 (migration 45):** the owner decided that
  staff read the whole price list and may add, change and delete prices,
  because the app offers them the pricing screens. The header of migration 23,
  which calls the refusal deliberate, describes the rule that held from 8 to
  11 October. The table policy is still closed; staff reach prices through the
  RPCs only.
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
  **Superseded in part on 11 October 2026 (migration 45):** of the explicit
  delete RPCs, `delete_grn_image` and `delete_dispatch_image` are open to staff
  within the rule given in the last section. `delete_grn_safe`,
  `delete_dispatch_with_order_cleanup`, `delete_invoice` and the customer and
  item deletes stay refused.
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

Added on 11 October 2026 (migration 45): staff also have a read policy on the
`orders` table. Without it Realtime delivered no order change to a staff
session, so the queue did not refresh live although the RPCs answered.

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

## An image belongs to its own document's folder, 10 October 2026

A customer can download a stored photo when a confirmed `grn_images` or
`dispatch_images` row of one of that customer's documents names the file
(`scripts/configure-storage.sql`). Until migration 43 three RPCs wrote such a
row with whatever path the caller sent, as confirmed and without looking in the
bucket: `upload_grn_image`, and the `p_images` list of `save_grn` and of
`update_grn`. One staff call for customer B's receipt naming customer A's file
made A's photo readable by B; a path that was never uploaded left a confirmed
row with no file.

Since migration 43 the database accepts a path only when all of these hold,
whichever RPC attaches it:

- it lies in the folder the register RPCs issue for that document:
  `headers/<grn id>/...` or `items/<grn id>/...` in `grn-images`,
  `<dispatch id>/...` in `dispatch-images`;
- a file with that name is in the bucket;
- no other image row carries the path (a unique index keeps it so, unless
  older rows already share a path);
- an item photo's line belongs to the receipt.

What that means for each entry point:

- `register_*_image_upload` issues the path and writes a pending row, as
  before; an item photo for a line of another receipt is refused
  (`ITEM_NOT_IN_GRN`). Dispatch paths now carry a random part instead of a
  timestamp.
- `confirm_*_image_upload` confirms only after the file was uploaded to the
  registered path (`IMAGE_NOT_VERIFIED` otherwise).
- `update_grn` keeps the images already on the receipt, named by id (or by
  their path). An id of another receipt's image no longer re-links that image.
  Any other entry is a new attachment and must pass the rule.
- `save_grn` creates the receipt id itself, so no file can be in its folder
  yet: a `p_images` entry is refused. Photos of a new receipt are registered
  after the save, which is what the app does.
- `upload_grn_image` (and `upload_dispatch_image`, which is not part of the
  granted API) attach a file that is already in the document's folder. Only
  administrators and supervisors can put a file there without a registered
  row, so staff have nothing to attach through it.
- A row inserted without a status is `pending`. Customers read confirmed image
  rows only; the row of a pending upload, with its upload token, is no longer
  visible to the document's customer.

Rows saved before migration 43 are not changed. The migration prints a warning
with the number of rows whose path is outside their document's folder; list
them as the database owner with
`SELECT * FROM warehouse_maintenance.misplaced_image_paths();` and remove the
ones that should not be there with `delete_grn_image` / `delete_dispatch_image`.
`tests/image_path_rules.sql` proves the refusals at every entry point, the
unchanged register/upload/confirm flow and `update_grn` answer, and what each
customer can read.

## The server admits what the app offers, 11 October 2026

The 10 October review found screens that the app shows to a role and whose RPCs
the server refused, so the screen opened and then failed. The owner decided:
**where the app offers a screen to a role, the server allowlist is widened so
the screen works**, instead of hiding the screen. Migration 45 implements it and
`tests/role_allowlist.sql` proves it. This supersedes the staff pricing refusal
of 8 October (migration 23) and the administrator-only user management that
held since migration 3; the notes in the sections above say where.

The list below was taken from the app (the RPCs each screen calls and the role
it is shown to), not from the review text.

### What was opened, and to whom

**Staff — reports.** Reports tab and the report screens, both the all-customers
list and one customer:
`get_all_stock_summary`, `get_customer_stock_summary`,
`get_all_customer_activity_summary`, `get_customer_activity_detail`,
`get_customer_dispatch_activity`, `get_stock_aging_report`,
`get_item_wise_stock_list`. (`get_all_dispatch_activity`, `get_all_grn_activity`,
`get_customer_grn_activity` and `get_customer_invoice_summary` were open
already.) The operations dashboard is not shown to staff by the app and
`get_operations_dashboard` stays with administrators and supervisors.

**Staff — item pricing, read and write. This is a material change: staff can
change what customers are charged.** `get_item_storage_prices` (every
customer's prices), `create_item_storage_price`, `update_item_storage_price`,
`delete_item_storage_price` and `find_or_create_item_storage_price`. A price
change is not written to a history table; the invoice discount history of
migration 41 does not cover it. The `item_storage_prices` table itself stays
closed to staff: they read prices through the RPC.

**Staff — sensors.** `get_sensor_polling_data` and `get_sensor_history`. The
sensor tables stay closed to staff.

**Staff — photo removal in the receipt and dispatch edit forms.**
`delete_grn_image` and `delete_dispatch_image`, for a photo of a receipt or
dispatch that is not deleted (the documents staff can already edit), when the
photo is confirmed or the caller registered it. Another person's unconfirmed
upload is refused, as for `cancel_*_image_upload`. After the row is removed the
app deletes the file; staff may read and delete a file in the `grn-images` and
`dispatch-images` buckets only once no image row names it
(`scripts/configure-storage.sql`). A file a document still shows cannot be
deleted or overwritten by staff.

**Staff — live order queue.** A read policy on `orders`
(`starter_order_staff_read`), matching what staff already read through the
order RPCs. Orders are still written through the cart RPCs only.

**Supervisors — user management.** `update_user_role`, `update_user_status`,
`assign_customer_to_user` and `remove_customer_assignment` (the list and detail
RPCs were open already). A supervisor:

- cannot change an administrator's role, status or customer assignments, and
  does not see administrators in the list;
- cannot give anyone the administrator role;
- cannot change the own role, status or customer assignments;
- cannot review enrollment requests (`operator_review_enrollment` stays with
  administrators).

A supervisor can make another user a supervisor, and can deactivate or
reactivate any user who is not an administrator. The last-administrator rule of
migration 44 is unchanged.

### What was not opened

**Customer accounts are not widened to other customers' data.** A customer
account, also one assigned to several customers, is refused every
all-customers RPC (`get_all_stock_summary`, `get_all_customer_activity_summary`,
`get_all_dispatch_activity`, `get_all_grn_activity`,
`get_customer_invoice_summary` without a customer, `get_stock_aging_report` and
`get_item_wise_stock_list` without a customer), pricing and sensors.

The two stock reports that the app offers to customers and that take a
customer id are admitted for a customer account **only with the id of an
assigned customer**: `get_stock_aging_report(p_customer_uuid)` and
`get_item_wise_stock_list(p_customer_id)`. Each call names one customer and the
guard checks that id against the account's active assignments; an account with
several customers calls once per customer.

### Other changes of migration 45

- **Supervisor contact details.** `get_grn_details` and `get_dispatch_details`
  return `supervisor_details` to a customer account with `id`, `name` and
  `display_name` only. `mobile` (which is also that person's sign-in
  identifier) and `role` go to administrators, supervisors and staff. There was
  no owner decision on this; it is the privacy-safe default and the owner can
  reverse it (the app then shows the Call action to customers again).
- **Supervisor picker.** `get_supervisors` lists active profiles only. It still
  returns the mobile number, which both pickers show.
- **Role from the database.** `get_customer_dispatch_activity`,
  `get_customer_stock_summary`, `get_operations_dashboard` and
  `get_recent_dispatched_orders` took the caller's role from the token, where
  it outlives a role change. They now read it from the profile, like the guard.
  A role change still takes effect on the next request without signing the
  user out.
- **`printer_status`** is readable by signed-in administrators, supervisors and
  staff only; it was readable with the public key. `feature_flags` stays
  public.
- **`find_or_create_item_storage_price`** refused every role (it looked the
  caller up in a table that operator sign-in does not fill); it now works for
  the roles that may write prices.
- `is_admin_or_supervisor()` is true for staff as well, despite its name; it is
  not what keeps staff out of anything, the guard is.
  `tests/role_allowlist.sql` lists the granted functions that call it.

### Roles after migration 45

| Capability | Administrator | Supervisor | Staff | Customer account |
|---|---|---|---|---|
| Receipts, dispatches, invoices: create, read, edit | yes | yes | yes | read own |
| Delete a receipt, dispatch or invoice | yes | yes | no | no |
| Remove a photo in the edit forms | yes | yes | **yes** (confirmed or own, live document) | no |
| Orders and queue through the RPCs | yes | yes | yes | own carts |
| Live order queue (row read on `orders`) | yes | yes | **yes** | own |
| Reports: all customers | yes | yes | **yes** | no |
| Reports: one customer | yes | yes | **yes** | assigned customers (**now also stock aging and item-wise stock**) |
| Operations dashboard | yes | yes | no | no |
| Item pricing: read | yes | yes | **yes** | no |
| Item pricing: add, change, delete | yes | yes | **yes** | no |
| Sensors | yes | yes | **yes** | no |
| Customers and items: create, edit, delete | yes | yes | no | no |
| User list and details | yes | yes, without administrators | no | no |
| Change role, status, customer assignments | yes | **yes**, not of an administrator or the own profile, never to administrator | no | no |
| Review enrollment requests | yes | no | no | no |
| Supervisor's mobile number on a receipt or dispatch | yes | yes | yes | **no** (name only) |
| `printer_status` | yes | yes | yes | **no** (and no longer without sign-in) |

Bold marks what migration 45 changed.

`tests/role_allowlist.sql` classifies every function the app role may execute
(staff yes/no; customer any/own/no). It calls each one that a customer account
or staff may not use and expects the guard's refusal, also with another
customer's id, so a function granted later fails the test until it is
classified. `tests/staff_dispatch_invoice_access.sql` and
`tests/staff_grn_access.sql` were changed where they asserted the old pricing
and photo refusals.

## One lock order and stricter document input, 11 October 2026

Migration 46 changes how the document RPCs take their locks and what they
accept. It adds no role and opens nothing.

### Lock order

Every write to `customers`, `goodsreceived`, `goodsreceived_trl`, `dispatch` or
`dispatch_trl` ends by refreshing the list views under advisory lock 71040
(migrations 4, 19 and 20). The statement trigger takes that lock *after* the
statement has locked its rows. `update_grn` takes it before its first write
(migration 26), so a receipt edit (lock, then rows) and a dispatch of the same
lot being created, edited or deleted (rows, then lock) could wait for each
other; PostgreSQL ended that by failing one of the two with "deadlock
detected". Migration 39 added a second pair: a dispatch edit key-share locked
the receipt before its header update took the lock.

The rule now: **every function an API role may call that writes one of those
five tables takes lock 71040 before it locks any row.** That is `save_grn`,
`update_grn`, `delete_grn_safe`, both `create_dispatch_with_stock_check`
wrappers (in the body they share), `update_dispatch_smart`,
`delete_dispatch_with_order_cleanup`, both `save_invoice` functions,
`update_invoice`, `delete_invoice`, `create_customer`, `update_customer`,
`restore_customer` and `safe_delete_customer`. Document writes were already
serialized by that lock from their first write to their commit; they are now
serialized from their start. `tests/document_write_consistency.sql` fails for a
granted function that writes one of the tables without taking the lock, and
`tests/grn_edit_lock_order.sh` runs three two-session cases on real rows (a
receipt edit against a lock holder, a dispatch being created against a receipt
edit of the same lot, a dispatch edit against a lock holder). The cart RPCs
write `orders` and `order_items` only, which have no refresh trigger, and do not
take the lock.

### Input rules

These are the rules the app's forms already apply; the server did not.

- A receipt line needs a quantity above zero and a weight that is not negative
  (`save_grn`, `update_grn`). A weight of 0 still means "not recorded".
- A dispatch edit needs, for every line, a lot that exists and a whole quantity
  above zero. `update_dispatch_smart` stored a line of quantity 0 and silently
  dropped a line whose lot did not exist. An empty list still removes every
  line.
- A receipt or dispatch number made only of white space or invisible characters
  (tab, no-break space, zero-width space and the like) is blank: refused by
  `save_grn`, `update_grn`, dispatch creation (as the validation error
  `disp_no is required`), `update_dispatch_smart` and by the two table checks,
  which stay `NOT VALID` so that an installation holding such a number still
  migrates.
- A receipt's `customer_name` is taken from the customer record when the
  receipt is created and when it moves to another customer. The name the client
  sends is ignored; a later rename of the customer still does not rewrite old
  receipts. Sender and supervisor names and the receipt date are stored as sent.
- An idempotency key answers only the function and the user that stored it.
  `save_grn` keeps a key for one hour and dispatch creation for 24 hours; the
  stored row now expires at the same moment, so retention no longer removes a
  dispatch key that would still be honoured.
- The field filters of the receipt lists (`item_name`, `customer_name`,
  `gr_no`, `package_mark`, `rack` in `get_customer_grn_items`; `package_mark`
  in `get_all_grn_items`) take `%`, `_` and `\` literally, like the quick
  search.

### Other changes of migration 46

- `delete_grn_safe` removes the cart lines of the receipt's lots, as before, and
  now records them in the order history: one `order_revisions` entry with the
  action `grn_deleted` per order, the removed lines at quantity 0.
- `delete_dispatch_with_order_cleanup` asks `is_admin_or_supervisor_strict()` in
  its body. It used the helper that also admits staff and, failing that, let
  through anyone assigned to the dispatch's customer; only the guard in front
  refused them.
- Four internal dispatch functions that nothing called and no role could
  execute are dropped: `create_dispatch_with_stock_check_2arg_internal(jsonb,
  jsonb[])`, `..._internal_3param(jsonb,jsonb[],integer)`,
  `..._internal_4param(jsonb,jsonb[],boolean,integer)` and
  `..._internal(jsonb,jsonb[],boolean)`. The first was the only code that
  soft-deleted an order, which `get_or_create_cart` cannot recover from (the
  one-cart-per-customer index is unconditional). No RPC sets
  `orders.deleted_at` now, and no app role can write the table directly
  (migration 42).

Not changed: document numbers are still suggested by `get_next_*_number` and
chosen by the client, so two people saving at once can still collide on a
number and the second gets the duplicate-number refusal; and the RPCs still
return PostgreSQL's own message text for an unexpected error.
