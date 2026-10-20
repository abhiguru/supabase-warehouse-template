# Staff GRN permissions

This document is a dated record of role decisions. The role table under
[Roles after migration 45](#roles-after-migration-45) is current; later sections add migrations 46–90 and 69.
Where an earlier section says otherwise, a note marks it as superseded.

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
>
> Completed on 13 October 2026 (migration 69): the same rule applies inside
> `get_grn_details` and `update_grn`, which list and remove only the photo rows
> the caller may read; see [Unfinished photos in the receipt RPCs](#unfinished-photos-in-the-receipt-rpcs-13-october-2026-migration-69).

The mobile GRN activity report includes staff. Its GRN edit dispatch-presence
helper uses the existing authorized GRN detail summary instead of a direct
dispatch-table read. Missing or malformed history fails closed. No application
RPC signature changed.

Administrators and supervisors can delete an image object only when no image row or document header column still
names it (`scripts/configure-storage.sql`, run by every setup).

## Staff dispatch and invoice access, 5 October 2026

The operator explicitly authorized staff dispatch and invoice work. Migration 21 permits the existing
create/read/update document RPCs for active staff and adjusts only the dispatch implementations' legacy role checks and
the invoiceable-GRN lookup. It does not change shared ownership helpers, direct table or storage policies, pricing
mutations or destructive permissions. Staff cannot delete invoices or administer roles.

> Superseded in part on 11 October 2026 (migration 45): staff may now read and
> change item prices and remove photos. Invoice deletion and role
> administration stay refused for staff.
> **Superseded again on 16 October 2026 (migration 90):** staff lose item pricing
> again (see "Staff lose item pricing, 16 October 2026").

Migration 22: active staff read dispatch and invoice headers and lines warehouse-wide, plus confirmed dispatch-image
metadata or their own pending metadata. No direct pricing read, write, delete, storage-object or customer-role policy is
added. Private PDFs keep caller-RLS authorization and server-only expiring document links. Assigned customers keep access
to their own documents only, and a disabled staff account or a revoked session reads nothing.

## Second-pass corrections, 8 October 2026

An independent review found the earlier description wider than the code in two
places and narrower in one. The operator decided the following; migrations 23
to 25 implement it and `tests/staff_dispatch_invoice_access.sql`,
`tests/core_pilot.sql` and `tests/user_status_enrollment.sql` prove it.

- **Pricing.** Staff do not read the price list or change prices. They obtain a GRN's applicable rates through
  `get_grn_item_rates` (migration 88) and the invoice preview through `generate_invoice_data_for_grn_with_pricing` for a
  specific GRN. (Migration 45 opened pricing to staff on 11 October and migration 90 took it away again on 16 October; see
  "Staff lose item pricing, 16 October 2026". The table policy was always closed; prices are reached through RPCs only.)
- **Totals are server-computed.** `save_invoice` (both signatures) and
  `update_invoice` ignore client-supplied `labour`, `tax_amount` and `total` for
  every role and derive them from the saved lines and the stored `discount`
  (migration 24, see [INVOICE_RULES.md](INVOICE_RULES.md)). Line rates remain
  inputs within a range: charge and labour rate from 0 to 999999, tax from 0 to
  100 (migration 41). A charge of 0 needs a reason from staff (migration 48,
  [Zero charge needs a reason from staff](#zero-charge-needs-a-reason-from-staff)). A missing, duplicate or unrelated line rolls the whole
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
  within the rule given in [What was opened, and to whom](#what-was-opened-and-to-whom). `delete_grn_safe`,
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
  The answer is `success:true` with `storage_path` for a pending upload,
  `code:'NOT_FOUND'` when there is no such pending upload for the caller, and
  (migration 87) `code:'ALREADY_CONFIRMED'` with `image_id` and `storage_path` when the
  upload was confirmed meanwhile: nothing is deleted and the caller must keep the file.
- **Refusals roll back.** A refused dispatch edit (invoiced lines, insufficient
  stock) no longer leaves a half-applied header (migration 25).
- **Status changes.** `update_user_status(false)` disables the enrollment and
  revokes sessions; `update_user_status(true)` re-activates a disabled profile
  only. A pending request answers ENROLLMENT_PENDING (decide it with
  `operator_review_enrollment`) and a rejected one ENROLLMENT_REJECTED
  ("Review again", `review_enrollment_again`, puts it back in Access requests).

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

Until migration 42 administrators and supervisors could write the nineteen business tables with a plain table call, which
went around the server-computed invoice totals, the rate and discount rules, the stock checks and the dependency checks of
the delete RPCs. The owner decided to remove that path and keep the reads.
(Since migration 48 the read of `invoice` is by named column and leaves six
internal columns out; see [The discount and zero-charge records are not read from the table](#the-discount-and-zero-charge-records-are-not-read-from-the-table).)

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
  the service key, operator scripts), as before.
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
(`scripts/configure-storage.sql`). Until migration 43 three RPCs (`upload_grn_image`, and the
`p_images` list of `save_grn` and of `update_grn`) wrote such a row as confirmed
with whatever path the caller sent, without looking in the bucket.

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
- `cancel_*_image_upload` removes a pending row (`success:true`, `storage_path`, the app then
  deletes the file); a confirmed row is answered `ALREADY_CONFIRMED` (`success:false`, with
  `image_id` and `storage_path`) and kept; no such row is `NOT_FOUND`. The app deletes the stored
  file only after `success:true`.
- `update_grn` keeps the images already on the receipt, named by id (or by
  their path). An id of another receipt's image no longer re-links that image.
  Any other entry is a new attachment and must pass the rule.
  (Migration 69: the images it removes, keeps and lists are only those the
  caller may read; another person's pending upload is left alone. See the last
  section.)
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

**Staff — item pricing.** Opened by migration 45 (`get_item_storage_prices` and the four price writers) and taken away
again by migration 90; see "Staff lose item pricing, 16 October 2026".

**Staff — sensors.** `get_sensor_polling_data` and `get_sensor_history`. The
sensor tables stay closed to staff.

**Staff — photo removal in the receipt and dispatch edit forms.**
`delete_grn_image` and `delete_dispatch_image`, for a photo of a receipt or
dispatch that is not deleted (the documents staff can already edit), when the
photo is confirmed or the caller registered it. Another person's unconfirmed
upload is refused, as for `cancel_*_image_upload`. After the row is removed the
app deletes the file; staff may read and delete a file in the `grn-images` and
`dispatch-images` buckets only when it lies in the folder of a receipt or
dispatch that is not deleted and no image row names it
(`scripts/configure-storage.sql`; narrowed by migration 47, which before
covered every unnamed file, the photos of deleted documents included). A file a
document still shows, and any file of a deleted document, cannot be read,
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

A supervisor can make another user a supervisor and can deactivate any user who
is not an administrator. Since migration 47 a supervisor acts only on a profile
whose access request is approved: a deactivated, rejected or pending profile is
answered with `ENROLLMENT_NOT_APPROVED` ("Only an administrator can change a
user whose access is not approved"), for the status and for the role. Giving
access back is therefore an administrator's action, also for a user the
supervisor deactivated. For every caller, the role
of a pending request cannot be changed before the review (`ENROLLMENT_PENDING`,
"Review the access request before changing the role"); a role other than
customer made the request unreviewable. The last-administrator rule of
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
- **Supervisor picker.** `get_supervisors` lists active profiles only. Since
  migration 47 each row is `id`, `name`, `display_name` and `role`; `phone` is
  added for administrators and supervisors only. Staff, who pick a colleague by
  name, no longer receive every colleague's mobile number.
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
| Item pricing: read | yes | yes | **no** (migration 90) | no |
| Item pricing: add, change, delete (`create/update/delete_item_storage_price`, `replace_item_rates`, `undo_rate_change`) | yes | yes | **no** (migration 90) | no |
| Standard rate (`get_standard_rate`, `set_standard_rate`, migration 85): read / set | yes / yes | yes / yes | **no / no** (refused by the guard, migration 90) | no |
| Rates typed on the GRN sheet (`p_rates` of `save_grn` / `update_grn`, `get_item_grn_rates`, migration 86): a rate for this GRN only, or for the business or everyone from the GRN's day, on any day | yes | yes | **no** (migration 90): a staff call with `p_rates`, `[]` included, is answered `RATES_MANAGER_ONLY`; `get_item_grn_rates` is refused; `get_grn_details` answers `rates` = `[]` | no |
| The rate of each line of a GRN (`get_grn_item_rates`, migration 88): read | yes | yes | yes | **yes, for the GRNs of its own customer** (owner, 2026-10-16), each rate as its own: no source but `invoice`, no band edges (migration 89) |
| Price history (`get_item_price_history`, migration 48) | yes | yes | no | no |
| Sensors | yes | yes | **yes** | no |
| Customers and items: create, edit, delete (items also `get_item_usage`) | yes | yes | no | no |
| User list and details | yes | yes, without administrators | no | no |
| Change role, status, customer assignments | yes | **yes**, not of an administrator or the own profile, never to administrator; only for a profile whose access request is approved (migration 47). Customer assignments are for the Customer role only (`ROLE_NOT_CUSTOMER`, migration 116) | no | no |
| Reactivate a user; change a rejected or disabled profile | yes | no (migration 47) | no | no |
| Change a rejected profile (any change, by anyone) | **no one** until an administrator uses "Review again" (`review_enrollment_again`); the call answers `ENROLLMENT_REJECTED` | no | no | no |
| Colleagues' mobile numbers in the supervisor picker | yes | yes | no (migration 47) | no |
| Review enrollment requests | yes | no | no | no |
| Put a rejected access request back to pending (`review_enrollment_again`, migration 113) | yes | no (`PERMISSION_DENIED`) | no | no |
| Disconnect a service account (`update_user_status(false)` on a service account) | yes | **no** (`PERMISSION_DENIED`, migration 113) | no | no |
| Unlink a profile from its central sign-in (`clear_user_central_identity`, migration 49) | yes | no | no | no |
| Supervisor's mobile number on a receipt or dispatch | yes | yes | yes | **no** (name only) |
| `printer_status` | yes | yes | yes | **no** (and no longer without sign-in) |

Bold marks what migration 45 changed. Migration 49 added the unlink row; it is
the one function the guard names that a supervisor may not call
([CENTRAL_LOGIN.md](CENTRAL_LOGIN.md)).

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

Writes to `customers`, `goodsreceived`, `goodsreceived_trl`, `dispatch` and
`dispatch_trl` are serialized by advisory lock 71040. Before migration 46 some
functions took it after they had locked rows and others before, so a receipt edit
and a dispatch of the same lot could wait for each other and PostgreSQL ended that
by failing one of the two with "deadlock detected".

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
write `orders` and `order_items` only and do not take the lock.

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

## Review follow-ups, 11 October 2026 (migration 47)

Migration 47 narrows three things migration 45 opened (described where they
are listed above: the supervisor picker, user management by supervisors, and
the photo files staff may remove) and adds one parameter. It opens nothing.

### `update_grn` takes an idempotency key

`update_grn` has a last, optional parameter `p_idempotency_key text DEFAULT
NULL`. With a key, a save that is repeated by the same user for the same
receipt within 24 hours changes nothing and returns the answer of the first
save with `"idempotent": true` added, as `save_grn` does. The key is stored in
`idempotency_keys` under the function name `update_grn`; a key that another
user or another function stored is neither replayed nor overwritten, and the
same key for another receipt is treated as a new save. Only successful saves
are stored. Without the key the function behaves as before, so an app build
that does not send it keeps working; there is still exactly one `update_grn`.

What the key changes: without it, a second save after a lost answer removes the
line the first save added (the app does not know its id yet) and adds it again
as a new row. That is one line, not two, but under a new id, and it fails with
"Cannot delete item" if the first row was dispatched in between.

### Still open from the first review

- **Names and dates on a receipt.** Migration 46 takes `customer_name` from the
  customer record. `sender_name` and `supervisor_name` are still stored as the
  client sends them, and any date is accepted, past or future. Binding the two
  names needs a decision on which name of the record to store (`name` or
  `display_name`), and a limit on dates needs one on how far back a receipt may
  be entered.
- **A role change and the token.** The server takes the caller's role from the
  profile on every request (migration 45), so a changed role applies at once.
  `update_user_role` does not end the user's sessions: the `user_role` claim
  inside the access token keeps the old role until the token is renewed (at
  most `JWT_EXP`, one hour by default). Nothing on the server reads that
  claim; an app that reads it shows the old role until then.

## Owner decisions, 11 October 2026 (migration 48)

The owner took nine decisions on 11 October 2026; these are the ones that
change what a role may do on this server. Migration 48 implements them. No
role is added and no RPC is opened to a role that did not have it.

### Zero charge needs a reason from staff

An invoice line may have a storage charge of 0. **Staff must give a reason** (`zero_charge_reason`) on every save of an
invoice that has such a line, on all three save paths; administrators and supervisors may leave it empty. Without it staff
are refused with `Enter a reason for the zero charge`. Every change of the reason is appended to
`invoice_zero_charge_history`, which administrators and supervisors read and nobody can change. Details, and what happens to
invoices saved before the rule, are in [INVOICE_RULES.md](INVOICE_RULES.md). `tests/zero_charge_reason.sql` covers each path
and role. The discount reason of migration 30 is a separate rule and unchanged.

### The discount and zero-charge records are not read from the table

All app roles share one database role, so a table grant cannot tell a customer account from staff. Migration 48 therefore
grants the app role SELECT on every column of `invoice` except `discount_reason`, `discount_set_by`, `discount_set_at`,
`zero_charge_reason`, `zero_charge_set_by` and `zero_charge_set_at`. **For every role, administrator included, those six are
read through `get_invoice_detail` only**, which gives them to administrators, supervisors and staff and not to a customer
account. A direct read of `invoice` must name its columns (`select=*` is refused with HTTP 403), and a column added later is
closed until a migration grants it. See [INVOICE_RULES.md](INVOICE_RULES.md), "Internal columns";
`tests/invoice_column_grants.sql`, `tests/security_baseline.sql`.

## Staff lose item pricing, 16 October 2026

The owner decided that item pricing is for administrators and supervisors only
(migration 90). This supersedes the staff access of 11 October 2026 (migration
45, widened by migrations 76, 85 and 86), which the sections above describe.

- **Refused to staff by the guard** (SQLSTATE `42501`, "Staff access required"):
  `get_item_storage_prices`, `create_item_storage_price`,
  `update_item_storage_price`, `delete_item_storage_price`, `replace_item_rates`,
  `undo_rate_change`, `get_standard_rate`, `set_standard_rate` and
  `get_item_grn_rates`. (`find_or_create_item_storage_price` was already refused,
  migration 76.) The staff branches inside those function bodies (the rate in force
  rule of migration 76, `STANDARD_RATE_MANAGER_ONLY` of migration 85) are left in
  place and can no longer be reached by staff.
- **Rates typed on the GRN sheet.** A staff call of `save_grn` or `update_grn`
  that carries `p_rates` (any value that is not NULL, `[]` included) is answered
  `{success: false, error_code: 'RATES_MANAGER_ONLY'}` before anything is written.
  The same calls without `p_rates` work for staff as before.
- **`get_grn_details`** answers `grn.rates` = `[]` to staff, as it does to customers;
  administrators, supervisors and the service role get the rates as before.
- **What staff keep:** `get_grn_item_rates` (the rate each line of a GRN is
  invoiced at, with its source and band; migration 88, answer unchanged) and
  `generate_invoice_data_for_grn_with_pricing`, so staff still see applicable
  rates on a GRN and still invoice.
- The rate tables were already readable by administrators and supervisors only;
  no row policy changes. The app release that hides the pricing screens and the
  rate fields of the GRN sheet from staff must go first or together with this
  migration. `tests/staff_pricing_90.sql` proves it.

### Every price change is recorded

**Every insert, update and delete of `item_storage_prices`
writes one row to `item_price_history`**: when, the profile with its name and
role as they were, the
price, its item and customer (ids and names as they were), the action
(`insert`, `update` or `delete`; `truncate` is described below) and the price
before and after. A trigger on
the table writes it, so `create_item_storage_price`,
`update_item_storage_price`, `delete_item_storage_price` and
`find_or_create_item_storage_price` are all covered, as is a write with the
service key or by an operator in the database (recorded without a profile). A
save that changes no value is still a row: it records who saved. A refused
write leaves none.

`TRUNCATE` of the price table, which no app role may run but the service key
and the database owner may, does not go through the row trigger. A statement
trigger records it as one row with the action `truncate`, no price, item or
customer, and `old_values` = `{"rows": n}`, the number of prices removed; the
prices themselves are not copied into the row. `get_item_price_history` lists
a truncate under every customer and item filter, since it removed their
prices with all the others.

The history is append-only (no role is granted a write, and a trigger refuses
changes and deletes even for the database owner) and has no foreign keys, so a
price, an item or a profile can still be deleted afterwards.

**The author stays named.** Every signed-in user may delete the own account
(`delete_user_account`), which renames the profile to "Deleted User". The
price history, the zero-charge history and the discount history therefore
store the author's name and role with each row (`changed_by_name`,
`changed_by_role`), and `get_item_price_history` and `get_invoice_detail`
return that stored name. Deleting an account no longer removes the person's
name from the record of the prices, discounts and zero charges that person
entered; it still removes the name everywhere else.

**Administrators and supervisors read it**, with
`get_item_price_history(p_customer_id, p_item_id, p_limit, p_offset)` (newest
first; all four arguments optional; `{success, data, pagination}`; a page is 1
to 200 rows, and an offset past the end, up to the largest integer, is an
empty page) or from the table. **Staff and customer accounts cannot**: the guard refuses the RPC
(`Staff access required`) and the table's row policy shows them no row. The
app has no screen for the history yet. The record starts with migration 48;
prices created before it have no insert row. `tests/item_price_history.sql`.

### Invoice number per financial year

`get_next_invoice_number` takes the financial year and counts within it
([INVOICE_RULES.md](INVOICE_RULES.md), "Invoice numbers"). The roles are the
same as before: administrators, supervisors and staff; a customer account is
refused. `tests/invoice_number_per_year.sql`.

## Unfinished photos in the receipt RPCs, 13 October 2026 (migration 69)

The external review of 13 October (SEC-1, SEC-2) found two SECURITY DEFINER
functions that did not apply the `grn_images` row rules: administrators and
supervisors read every row, staff read confirmed rows and the pending rows they
registered, a customer reads confirmed rows of its own receipts (migrations 18,
42, 43). Migration 69 puts the rule in one helper,
`warehouse_security.grn_image_visible(status, uploaded_by)` (not granted to the
app roles), and uses it in both and in three other readers of `grn_images`:

- `get_grn_details` lists in `header_images` and in each line's `item_images`
  only the rows the caller may read. Before, a customer or another staff member
  got a pending upload's path, file name, size, type and uploader. The answer's
  shape is unchanged.
- `update_grn` with a non-empty `p_images` removes only the omitted rows the
  caller may read: an administrator or supervisor any omitted row, staff the
  confirmed rows and their own pending ones (the rule of `delete_grn_image` and
  `cancel_grn_image_upload`). Another person's pending upload stays, and that
  person can still confirm it. A row the caller may not read that the list
  names (by id or path) is kept as it is: not moved to another line, not counted
  in `images_updated` and not attached a second time. `grn.images` in the answer
  lists the rows the caller may read. An empty `p_images` still changes no
  photo.
- `get_customer_items_for_order_selection` (`image_url`), `get_invoiceable_grns`
  (`gr_image_url`) and `get_customer_grn_activity` (`image_count`,
  `total_images`) take only those rows into account. Before, a customer's order
  picker could show the storage path of a pending upload, and the GRN activity
  report counted every row. Their keys and rows are unchanged.

The roles in the table of migration 45 are unchanged. `tests/grn_image_visibility.sql`
reads `get_grn_details` as each role and edits as two staff members and an
administrator.
