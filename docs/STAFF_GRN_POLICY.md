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

Normal CI must verify the final migration test revision. Native staff GRN
acceptance and a new installed artifact remain separate outstanding evidence.
The user's permission decision is resolved; all other campaign gates remain.
