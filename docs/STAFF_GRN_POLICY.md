# Staff GRN permissions

The operator selected this policy on3 October2026: active, approved staff may
view, create and edit warehouse GRNs. GRN deletion remains limited to admins
and supervisors. Customers retain their assigned-customer read boundary.

Migration18 adds an explicit GRN RPC allowlist and read policies for GRN
headers, items and attachments, plus customer lookup needed by the receipt
form. Existing business RPCs retain quantity/stock and dependency checks.
Direct staff table writes, soft deletion, arbitrary stock edits, administration,
invoice creation and general dispatch permissions are not granted.

Staff can register and confirm GRN images and insert/update their own pending
registered storage objects. They can read confirmed GRN attachments. Confirmed
image-object deletion/overwrite and unrelated buckets remain restricted. The
existing cancellation RPC can remove pending metadata; storage deletion is
still restricted and no new image-failure/retry acceptance is claimed.

The mobile GRN activity report includes staff. Its GRN edit dispatch-presence
helper uses the existing authorized GRN detail summary rather than assuming a
direct dispatch-table read is available. Missing or malformed history fails
closed. No API signature changed.

## Installation and validation

Apply through the documented setup sequence using the new reviewed source:
migration18 is additive; never edit old applied migrations. Setup also runs
scripts/configure-storage.sql to install the scoped Storage policies. Preserve
installed application and fixture snapshots; this source change has not been
applied to the frozen campaign warehouses or installed APK10.

Backend127 unit checks, mobile10 focused service tests, mobile typecheck/lint
and the exact mobile contract passed locally. Lint retained existing warnings.
Three local disposable migration runs are preserved: the first reached staff
create/read/edit and exposed the denied-delete error handler; the second
stopped on a test include path; the third stopped on missing modern bucket
columns in the PostgreSQL image's base Storage schema. The source corrects
those issues. No fourth local migration run is claimed. The test-only Storage
fixture now declares the later API bucket columns before exercising the actual
policy setup twice. This proves SQL policy behavior when executed; it does not
prove actual Storage HTTP/file-byte acceptance.

CI run37121635390 reached the staff regression and failed the strict legacy
GRN-list count assertion. Source tracing found that fresh installation never
initialized mv_refresh_queue: the existing dirty/refresh triggers only update
existing entries. The newer mobile list reads live rows and passed its count
assertion before this failure. Additive migration19 registers the seven existing
runtime refresh targets and reconciles their views under the same advisory lock
as the refresh trigger. The assertion is retained without a test-only refresh.
The operator explicitly authorized one additional five-minute isolated test of
commit9a6a9d8. That test passed the initial legacy-list count, staff edit RPC and
underlying quantity/stock reconciliation, then failed the retained-list stock
check after the edit. The disposable database was removed and the fourth local
log/result were preserved. Migration19 remains unpublished; no fifth local
attempt or further correction was started.

Source inspection explains the remaining refresh mismatch: update_grn disables
the item dirty trigger, then marks mv_refresh_status, while the starter's
synchronous refresher consumes mv_refresh_queue. Initial queue registration
does not repair that edit path. A complete cache correction and independent
validation remain open; the passing earlier assertions do not establish full
staff permission, attachment or native acceptance.

The mobile CI run37121658351 also exposed an older authentication test that
still mocked the replaced dispatch-table query. Its correction checks use of
the authenticated GRN-detail RPC and absence of direct table access.

The authorized extra attempt is consumed; this case stopped as agreed.
Native staff GRN acceptance and a new installed artifact remain outstanding.
The user's permission decision is resolved; all other campaign gates remain.
