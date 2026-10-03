# Staff GRN permissions and cache consistency

The operator selected this policy on 3 October 2026: active, approved staff may
view, create and edit warehouse GRNs. GRN deletion remains limited to admins
and supervisors. Customers retain their assigned-customer read boundary.

Migration 18 adds an explicit GRN RPC allowlist and read policies for GRN
headers, items and attachments, plus customer lookup needed by the receipt
form. Existing business RPCs retain their quantity/stock and dependency checks.
Direct staff table writes, soft deletion, arbitrary stock edits, administration,
invoice creation and general dispatch permissions are not granted.

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
