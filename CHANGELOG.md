# Changelog

## Unreleased — the last administrator cannot be removed (2026-10-11)

- Migration 44: `delete_user_account` refuses the only active administrator
  (`{success:false, code:'LAST_ADMIN'}` with a sentence in `error` and
  `message`); `update_user_status` and `update_user_role` answer
  `error:'LAST_ADMIN'` when the change would leave no active administrator.
  Before, the only administrator could delete the own account and nothing
  short of editing the database could create another.
- Recovery: `setup.sh` and `warehouse_security.bootstrap_first_admin` now look
  for an approved, **active** administrator. When there is none, a setup rerun
  makes the profile with `--admin-phone` an administrator again, or creates
  one. See "The last administrator" in `docs/OPERATOR_INSTALL.md`.
- `operator_review_enrollment` refuses a caller with no active role by itself
  (it relied on the PostgREST session hook having refused first).
- Tests: new `tests/admin_guards.sql`.

## Unreleased — OTP limits a stranger cannot turn against a user (2026-10-11)

- Migration 44 changes the OTP limits; the table is in
  `docs/OPERATOR_INSTALL.md`, "Authentication and OTP limits". Before, anyone
  could keep a chosen phone (the only administrator's included) from signing
  in with five code requests an hour or five wrong guesses per code, and about
  ten addresses could use up the warehouse cap for everybody.
  - Wrong codes are counted on each issued code in two budgets of five: one for
    the address that requested the code, one shared by all other addresses.
    Each address is also limited to 20 failed verifications an hour.
  - A phone with an approved, active profile is no longer refused after 5
    requests an hour or 20 a day: it gets one code every 15 minutes instead,
    and 5 an hour from an address it has signed in from before, which other
    addresses cannot use up. Other phones keep the hard limit.
  - The 60 s resend cooldown is per phone and address.
  - Phones without an approved profile may use only `otp_unknown_hourly_cap`
    (default 60) of the warehouse cap (`otp_global_hourly_cap`, default 300).
  - A send MSG91 did not accept no longer counts against the phone or the
    warehouse cap.
  - New access requests are limited to 3 per address and
    `enrollment_daily_cap` (default 30) per day, and the name a new user types
    is checked (markup or links are replaced by "New customer").
- `operator_verify_otp` takes the caller's address as a fifth argument; the
  four-argument function is gone. Only the edge worker calls it.
- The edge function answers two new cases: verification from an address over
  its failure limit gets 429 "Too many OTP requests. Try again later.", and an
  access request over the limit gets 429 "Too many new access requests. Try
  again tomorrow.". A cooldown answer now carries `retry_after_seconds` and a
  `Retry-After` header.
- The edge function's request handling moved to
  `functions/operator-otp/handler.ts` so it can be tested.
- Tests: new `tests/otp_abuse_limits.sql` and
  `tests/operator-otp-handler.test.mjs` (mode gate, routing, CF-Connecting-IP
  checks, formats, status mapping, provider failure order).

## Unreleased — a replayed refresh token ends the session; a retried renewal does not (2026-10-11)

- Migration 44: `refresh_jwt_token` now tells a retry from reuse. A refresh
  token that was already replaced and is presented again within 60 seconds
  (`refresh_grace_seconds` in `warehouse_security.auth_config`, 0 to 300) gets
  the same successor again with a newly signed access token, so an app whose
  first answer was lost on a slow network is not signed out. Presented later,
  or when it is two generations old, it is reuse: the session is deleted, the
  token that was current stops working and the database log carries
  `Refresh token reuse: session ... revoked`. Before, the replay was refused
  but a session held by whoever had rotated the stolen token stayed alive for
  up to 7 days.
- The answer shape is unchanged: `{success, access_token, refresh_token,
  expires_at, expires_in, token_type}` or `{success:false, message:'Invalid
  refresh token'}`.
- The table still stores hashes only. The successor is kept encrypted under a
  key derived from the replaced token, so it can be returned only to a caller
  who presents that token.
- Tests: new `tests/refresh_reuse.sql` (rotation, retry inside the grace
  period, replay after it, old generations, logout with a pre-rotation token,
  forged and expired tokens); `tests/operator_auth.sql` and the CI drill
  `tests/operator-api-core.mjs` now expect the retry answer. The drill was not
  run against a live stack in this change.

## Unreleased — printer status check validates the printer name (2026-10-10)

- `get-printer-status` (still answered with 503 by the function router until
  printing is configured) accepts only a CUPS queue name
  (`[a-zA-Z0-9_-]`, 1 to 127 characters) as `printer_name`, as `print-via-ipp`
  does; before, the value went into the CUPS URL path unchecked. An error that
  is neither "cannot connect" nor "printer not found" is answered as
  `Printer status unavailable`; the detail stays in the server log.
- Tests: new `tests/printer-name.test.mjs`.

## Unreleased — generated PDFs expire (2026-10-10)

- Every `generate-*-pdf` request stores a new file in the private `documents`
  bucket and nothing removed it, so the bucket grew with every request.
  `npm run retention:apply` now also removes generated PDFs older than the new
  `generated_documents` retention policy (7 days by default; the download link
  lives one hour). `npm run retention:preview` prints how many it would remove.
- Migration 43 adds the policy row and
  `warehouse_maintenance.expired_generated_documents()`, which names the
  expired files. `scripts/retention.sh` deletes them through the Storage API
  from inside the storage container (`scripts/remove-expired-documents.cjs`),
  because deleting the `storage.objects` row alone leaves the file on disk,
  then checks that none remain. Only names the PDF functions produce
  (`<kind>/<document id>/<uuid>.pdf`) are removed.
- **Action for operators:** retention is still a command you run; schedule
  `npm run retention:apply` (for example daily, with the backups). See
  `docs/PDF_GENERATION.md`.
- Tests: `tests/retention.sql` (which files are named),
  new `tests/retention-documents.test.mjs` (the Storage API call and the
  command's preview/apply steps, against stand-ins). The deletion was not run
  against a live Storage container in this change.

## Unreleased — an image is confirmed only for a file in its own document's folder (2026-10-10)

- Migration 43: `upload_grn_image` and the `p_images` lists of `save_grn` and
  `update_grn` no longer write a confirmed image row for any path the caller
  sends. A path is accepted only if it lies in that document's folder
  (`headers/<grn id>/`, `items/<grn id>/`, `<dispatch id>/`), a file with that
  name is in the bucket, no other image row carries it, and an item photo's
  line belongs to the receipt. Before, one staff call could attach customer A's
  photo to customer B's receipt, which let B download it, or leave a confirmed
  row with no file.
- `confirm_grn_image_upload` and `confirm_dispatch_image_upload` answer
  `IMAGE_NOT_VERIFIED` until the file is uploaded to the registered path.
  `register_grn_image_upload` refuses a line of another receipt
  (`ITEM_NOT_IN_GRN`). `update_grn` no longer re-links an image of another
  receipt named by id. Dispatch photo paths carry a random part instead of a
  timestamp. `upload_dispatch_image` gets the same checks and the RPC guard.
- An image row inserted without a status is `pending`. Customers read confirmed
  image rows only; a pending row and its upload token are no longer visible to
  the document's customer.
- The app's flow is unchanged: register, upload to the issued path, confirm;
  `update_grn` still answers `item_mapping` and `grn.images`.
- **Action for operators:** existing rows are not changed. If the migration
  warns about rows outside their document's folder, list them with
  `SELECT * FROM warehouse_maintenance.misplaced_image_paths();` and delete the
  ones that should not be there. See `docs/STAFF_GRN_POLICY.md`.
- Tests: new `tests/image_path_rules.sql`.

## Unreleased — business tables are written only through the guarded RPCs (2026-10-10)

- Migration 42: administrators and supervisors can no longer insert, update or
  delete rows of the business tables with a direct table call
  (`/rest/v1/<table>`); the request answers HTTP 403. Before, one such call
  could set an invoice total, a line rate, a discount or a lot's stock, or
  delete dispatch lines, without the server totals, rate limits, stock checks
  and dependency checks the RPCs apply. Reads are unchanged for every role.
  The tables: `customers`, `items`, `item_storage_prices`, `goodsreceived`,
  `goodsreceived_trl`, `dispatch`, `dispatch_trl`, `invoice`, `invoice_trl`,
  `payments`, `orders`, `order_items`, `grn_images`, `dispatch_images`,
  `stock_movements`, `print_jobs`, `sensor_devices`, `sensor_readings`,
  `sensor_health_events`.
- **Action for API clients:** anything that wrote these tables directly with an
  administrator or supervisor session must call the RPC instead
  (`safe_delete_customer` / `restore_customer` / `update_customer`,
  `update_invoice`, `update_grn`, `update_dispatch_smart`, the `delete_*` RPCs).
  Edge functions using the service key, operator scripts and Studio are not
  affected.
- Migration 42: `update_order_metadata(p_order_id, p_note, p_priority,
  p_requested_dispatch_date)` is granted to signed-in users. Administrators and
  supervisors only; each change is written to the order history. It replaces a
  direct update of an order's note.
- The own-profile grant `UPDATE(name, display_name)` on `user_profiles` is
  unchanged.
- Tests: new `tests/direct_write_guard.sql`. `tests/staff_grn_access.sql`,
  `tests/staff_dispatch_invoice_access.sql` and `tests/order_screen.sql` now
  expect a refusal where a direct write used to match no row. The HTTP drivers
  `tests/operator-api-core.mjs`, `tests/operator-realtime-core.mjs` and
  `tests/review-core.mjs` use the RPCs instead of direct writes.

## Unreleased — invoice line rules: rate ranges, one invoice per dispatch line, India dates, discount history (2026-10-10)

- Migration 41: `save_invoice` (both signatures) and `update_invoice` refuse a
  line whose `charge` or `labour_rate` is outside 0 to 999999 or whose `tax` is
  outside 0 to 100 (`Invoice line charge must be between 0 and 999999`,
  `Invoice line labour rate must be between 0 and 999999`, `Invoice line tax must
  be between 0 and 100`). Zero rates are still accepted and a negative discount
  is still a surcharge. Before, a negative labour rate or tax could bring an
  invoice to nothing without a discount reason.
- Migration 41: a dispatch line is invoiced once. A save for a receipt already
  marked invoiced is refused (`GRN is already invoiced`, code `WH409`), as is a
  line that is on another invoice (`A dispatch line is already on another
  invoice`). `update_invoice` cannot move an invoice onto an invoiced receipt.
  Before, a second save under a new invoice number billed the same lines twice.
  After `delete_invoice` the receipt can be invoiced again.
- Migration 41: billable days are counted between calendar dates in India
  (`Asia/Kolkata`) in the preview and all save paths, not in the database
  session's time zone. **Amounts change** for a receipt whose stored time falls
  between 18:30 and 24:00 UTC (00:00 to 05:30 in India): it loses the extra day
  it was given, which mattered at the 30/45/60-day steps. Saved invoices are not
  recalculated; an invoice edited after the upgrade gets the corrected days.
- Migration 41: every discount change is appended to the new
  `invoice_discount_history` table (old and new discount, reason, profile, role,
  time). It cannot be updated or deleted, administrators and supervisors read
  it, and it stays when the invoice is deleted. A discount reason made only of
  white space or invisible characters is treated as empty for staff.
- Migration 41: `get_invoice_detail` returns `discount_reason`,
  `discount_set_by`, `discount_set_by_name` and `discount_set_at` to
  administrators, supervisors and staff (not to customer accounts).
  `get_invoice_items_detailed` computes line tax and total as the header does;
  a one-time line no longer includes duration and labour.
- Migration 41: `delete_invoice` refuses an invoice that payments refer to
  (`Cannot delete an invoice that has payments`).
- Existing invoices are not validated or changed. Applying the migration prints
  a warning with the number of dispatch lines that are already on more than one
  invoice, if any.

## Unreleased — a line can be added to an existing receipt (2026-10-10)

- Migration 40: `update_grn` saves a line that has no `id` as a new line of the
  receipt, with its whole quantity in stock, and reports it in `item_mapping`.
  Before, every edit that added a line failed with `column "pricing_mode" of
  relation "goodsreceived_trl" does not exist` and saved nothing: the insert named
  a column the line table does not have. The pricing mode stays on the receipt
  header (`p_pricing_mode`); a `pricing_mode` sent on a line is ignored.
- No request or response changes. A photo attached to a line added during an
  edit still needs the app to send the new line's id (`item_mapping`).

## Unreleased — a dispatch carries only its own customer's lots (2026-10-10)

- Migration 39: `create_dispatch_with_stock_check` and `update_dispatch_smart`
  refuse a line whose receipt belongs to another customer than the dispatch
  (`Item belongs to another customer: <item> (<receipt>)`, code `WH409`), for
  every role. `update_dispatch_smart` also refuses a change of the dispatch
  customer unless every line the edit leaves belongs to the new customer
  (`Cannot change the dispatch customer: items belong to another customer: ...`).
  Before, a dispatch for one customer could take another customer's stock and
  show that customer's receipt details to the first.
- Migration 39: `update_grn` refuses a change of the receipt's customer once the
  receipt has dispatch lines, an invoice or a line in an open cart (error
  `Cannot change the customer of a GRN that has dispatches, invoices or order
  items`). Sending the present customer again is still an ordinary edit.
- Existing records are not validated or changed. Applying the migration prints a
  warning with the number of dispatch lines that already mix customers, if any;
  such a dispatch can still be edited, but no further foreign line can be added.

## Unreleased — receipts sort by number in every accepted form (2026-10-10)

- Migration 31: `get_all_grn_items` and `get_grn_list` sort by receipt number with
  one key for every form `gr_no` accepts. One-letter prefixes keep their order
  (X, Y, Z, then A onward); numbers compare as numbers at any length, so A10000
  follows A9999; other forms (two-letter prefixes, digits only, separators) sort
  by prefix and then number. Before, every form other than a letter plus digits
  came back in ascending text order whichever direction was requested, and
  five-digit numbers collided with the next letter. No request or response changes.
- Migration 32: `get_customer_grn_items` sorts by number with the same key, so
  customer accounts and warehouse roles see one order (it compared numbers as
  plain text: B10 before B9).
- Migration 33: `get_dispatch_list_with_items` sorts by dispatch number with the
  same key. Same-day dispatches follow the requested direction, and every order
  ends in the key, so paging cannot repeat or skip a dispatch. CLR numbers now
  sort after the one-letter prefixes.
- Migration 34: a receipt or dispatch number made only of spaces, or an empty
  receipt number, is refused (`save_grn` answers with its "required" message;
  both tables carry a NOT VALID check, so existing records still migrate).
- Migration 35: quick search on the receipt lists. `get_all_grn_items` and
  `get_customer_grn_items` accept `p_filters.search`; every word must match the
  receipt number, customer, item, package, rack or vehicle number
  (case-insensitive; `%` and `_` are literal). `gr_no_from` / `gr_no_to` now
  compare in document order, so B9..B10 is a real range.
- Migration 36: quick search on the dispatch, invoice and order lists, and the
  filters those lists showed but did not apply.
  `get_dispatch_list_with_items` accepts `p_filters.search` (dispatch number,
  customer, vehicle number, or the item, package, rack or receipt number of a
  line) and `p_filters.package_mark`; `disp_no_from` / `disp_no_to` follow
  document order. `get_invoices_list` gains `p_search` (invoice number, also as
  `2026-12` or `2026-0012`, customer, receipt number), `p_date_from`,
  `p_date_to` and `p_customer_ids`. `get_orders_list` gains `p_search` (customer
  name or city, or the item, package or receipt number of a pending line). The
  new parameters are optional, so current app versions keep working.
- Migration 37: the dispatch list's `date_from` / `date_to` are moments in time,
  not whole days in the database's time zone, so "up to 7 Oct" includes all of
  7 Oct for the person asking. A plain date still means the start of that day.
- Migration 38: the language a person chose in the app is kept on their profile.
  `user_profiles.preferred_language` holds `en`, `gu` or NULL; `set_my_language(p_language)`
  stores the caller's own choice (NULL clears it) and `get_my_language()` returns it.
  Both need a signed-in, active account with a valid session. Server text stays English.
- Documents: text in Gujarati (a customer or item name) is set in Noto Sans Gujarati, to
  match the sans-serif page. It was already drawn correctly, in the serif face.

## Unreleased — invoice discount reason and author (2026-10-09)

- Migration 30: a changed invoice discount records its reason, the profile that
  set it and the time (`discount_reason`, `discount_set_by`, `discount_set_at`).
  Staff must give a reason (`discount_reason` in the invoice data) for any
  discount; administrators and supervisors may leave it empty. Applies to both
  `save_invoice` signatures and `update_invoice`. Apps that let staff set a
  discount must send the reason; see `docs/INVOICE_RULES.md`.

## Unreleased — fresh-install preflight checks the state parent (2026-10-09)

- `doctor --host-preflight` (run by `setup.sh`) now refuses a fresh install
  whose state directory sits in a parent the installation user cannot write,
  and names the `sudo chown` fix. Before, a state directory pre-created under a
  root-owned parent such as `/srv/warehouse` passed the preflight and setup then
  failed with `EACCES` while staging `<state>.installing-*` next to it (testvm2
  known issue 3). Reruns of an installed state need no parent write access.

## Unreleased — checkout permissions after an update (2026-10-09)

- Fixed F3 from the testvm2 operator run: a `git pull` under Ubuntu's default
  umask `0002` left changed scripts group-writable, so the documented "run setup
  again after updating" step was refused by `scripts/backup-usb.sh` (and
  `scripts/backup-disk.sh`). `setup.sh` now runs the new
  `scripts/checkout-permissions.sh` first, which removes group/world write and
  restores world read on tracked files and their directories (ignored runtime
  files and symlinks are untouched). The refusals name that command.
- Operator guide: the upgrade steps update the checkout with
  `(umask 022; git pull --ff-only)`, rerun the USB backup setup after
  `setup.sh`, and troubleshooting covers the refusal.

## Unreleased — orders screen review fixes (2026-10-09)

- Migration 28: cart history moved from the ever-growing `orders.revisions`
  array to an append-only `order_revisions` table (backfilled). The column is
  pinned to `[]` by a CHECK, so audit rows and realtime payloads no longer carry
  the whole history. `get_order_change_log` and dispatch deletion use the table.
- Staff have full order access: list, open and edit carts, the queue, and
  order history (guard v5). Customers can read the history of their own orders.
- Quantity changes check order state, dispatched quantity and stock. A two-
  customer account can edit its carts again (the old `<> ANY` check denied it).
- Cart removals go through the new `remove_item_from_order` RPC, which records
  history; the direct customer delete policy on `order_items` is gone. A lot can
  appear in a cart once (`order_items_order_grn_item_key`, duplicates merged).
- Dropped `convert_order_to_dispatch` and `update_order_after_dispatch_creation`,
  which wrote columns that do not exist. Orders become dispatches through
  `create_dispatch_with_stock_check` with `source_order_id`.
- Migration 29: `get_orders_list` reads a live view instead of rebuilding
  `mv_orders_list` on every cart write, and pages stably by order id. Weight
  search accepts decimals (`12.5`) and its access denials carry `success=false`.
- Added `tests/order_screen.sql` to `npm run test:migrations`.

## Unreleased — second-pass review fixes (2026-10-08)

- Added `scripts/tunnel.sh`: `adopt` keeps the Cloudflare Tunnel credential
  (config and credentials JSON, or a dashboard token) in the state under
  `config/tunnel/`, refusing the account certificate and another
  installation's tunnel; `install-service` writes the systemd unit for that
  copy. Backups (and USB copies) now carry it, and `db:restore-host` restores it,
  so a rebuilt host gets its public address back without a Cloudflare login.
  A lost backup drive now also means replacing the tunnel credential.
- Added `npm run db:restore-host` (`scripts/restore-host.sh`): rebuilds a lost
  installation on a new host from a backup directory or a USB `.tar`, with the
  same identity, keys and data, without running setup. It checks the archive,
  the backup, the migration history against the checkout and that the host is
  new before creating anything, then runs the in-place restore
  (`restore.sh --relocated`). CI runs a lost-host drill on real containers.
- Operator guide: "Recover a lost host from the USB drive", which rebuilds the
  same warehouse on a new host from a USB archive (now with `db:restore-host`;
  the first version used manual steps). Added `scripts/data-fingerprint.sh`,
  a read-only row-count and SHA-256 fingerprint of business tables and stored
  files to compare before backup and after restore.
- Added `scripts/backup-disk.sh`: prepares an empty second disk for backups
  (`status`, `plan`, `apply`, `sync`) and copies verified backups onto it. It
  refuses the system disk and anything that is not blank, never wipes or
  resizes, and `db:backup` is unchanged.
- Backups for pilot installs go to an operator-attached exFAT USB drive (one
  verified `.tar` per backup, readable from Linux and Windows-hosted VMs);
  the operator guide and contributor guide describe it, and the second disk is
  now the alternative.
- Added `scripts/backup-usb.sh`: after a one-time `sudo … setup --enroll`,
  attaching an enrolled exFAT USB drive starts a systemd unit that takes a fresh
  backup, copies it as a read-back-verified `.tar`, runs verify-restore on the
  copy and unmounts the drive. Optional daily timer for a drive left attached;
  `status`, `enroll` and `uninstall`; `doctor` warns when the last USB copy
  failed or is older than 7 days. Only enrolled drives (by filesystem UUID)
  trigger a run, and the copy runs as the installation user.
- Fixed `tests/backup-disk.test.mjs` opening a real device when the host has a
  disk with the fixture's name (`/dev/sdb`).
- Operator guide corrected from a from-scratch acceptance run: the state
  directory's parent must be owned by the installation user (`sudo install -d`
  on the leaf made setup fail with `EACCES`); fixed-window OTP limits and SMS
  cost; DNS negative caching after the tunnel route; `rest` has no healthcheck;
  `rotate-keys.sh` without `--yes` exits 1, and an external doctor right after
  rotation can fail once; root is needed to remove `*.pre-restore-*`; staff are
  created through Users, GRNs need a photo, and the 998 invoice example holds
  only for its fixture dates (same-day is 735).

- Migration 23: staff dispatch workflow completed (GRN picker, recent dispatches,
  dispatch photo register/confirm/cancel with matching storage policies);
  `get_item_storage_prices` removed from the staff allowlist; pending-upload
  cancellation bound to the registering profile.
- Migration 24: invoice header labour, tax and total are computed on the server
  from the saved lines and stored discount for every role; client totals are
  ignored; missing, duplicate or unrelated lines roll the save back.
- Migration 25: refused dispatch edits roll back completely; administrator
  status changes update the enrollment state and revoke sessions.
- Migration 26: GRN edits take the list-refresh lock before the item-table lock.
- Migration 27: a resend keeps the earlier OTP valid, wrong attempts are shared,
  the warehouse-wide hourly cap is configurable (`otp_global_hourly_cap`).
- Gateway: Cloudflare Tunnel is the only supported ingress; Kong trusts
  `CF-Connecting-IP` and rate-limits per client IP; the Caddy example is gone.
- Operations: shared `operator.lock` for stop, recovery, retention and gateway
  checks; `rotate-keys.sh --yes` rotates the signing secret and keys; backup
  format v4 (adds `_supabase` and the storage catalog); `scripts/restore.sh`
  restores a verified backup in place; functions, meta, realtime and imgproxy
  health probes.
- Release: any semantic `v*` tag is validated; Dependabot covers every image
  directory; research workflows and their evidence docs are removed.
- Tests: real guarded-RPC denials replace a probe that could never fail; new
  `user_status_enrollment.sql`, `grn_edit_lock_order.sh`, rotation, restore and
  lock refusal suites.

## Unreleased — remaining handoff checklist (2026-09-24)

- Record the [backend production checklist](docs/PRODUCTION_DEPENDENCIES.md#remaining-production-work)
  with owner inputs, next actions and acceptance evidence. The 17/19 image
  inventory and Grafana 102 HIGH count remain dated evidence, not a new scan.
  Track the unexplained historical CI setup HTTP 500 separately from the
  closed gateway iPhone retest and source-demo orders/cart acceptance.

## Unreleased — gateway merge and evidence closure (2026-09-23)

- Record reviewed PR #42 and mobile PR #28 merges with passing PR and exact-main
  CI. Preserve the earlier full iPhone matrix and later gateway-affected retest
  at their exact tested commits; the merged source pair is runtime-equivalent,
  without claiming a new physical-device run.
- Close the stale gateway CI and iPhone retest handoff claims. The CI-only subnet,
  isolated holder label and cleanup fix precede the green regression; the Linux
  old-TTL control did not reproduce the Mac stale cache. The separate setup HTTP
  500 cause remains unknown, and production operator and container security
  gates remain open. No runtime, workflow, companion pin, tag or release changes.

## Unreleased — setup failure diagnostics (2026-09-23)

- Reduce Kong's Compose DNS cache to five seconds (one second stale/negative)
  after reproducing direct bootstrap HTTP200 versus gateway HTTP502 following
  a functions-container IP change. Add an owned-network regression that forces
  an upstream address change and requires gateway recovery without restarting it.
- Give only the CI demo network an explicit subnet so the regression can reserve
  the old upstream address on GitHub's Docker daemon. Keep its temporary holder
  outside the checkout's Compose ownership label. These test-only changes fix
  failures that occurred before the gateway recovery check ran.
- On a failed health check, collect bounded, redacted gateway/function/REST logs
  from ownership-validated containers. Preserve the failing exit status and all
  readiness checks. This diagnoses post-merge CI bootstrap HTTP 500/502 failures;
  the IP-cache fix addresses the reproduced502 cause, not the separate500 attempt.
  The earlier completed iPhone evidence is not a device run of this later change.

## Unreleased — physical-iPhone orders/cart evidence (2026-09-23)

- Record the completed final merged-pair source-demo iPhone live-update matrix
  and owned cleanup. Close dependency item 9 only; production operator choices,
  capacity, Grafana findings and PostgREST inventory/scan coverage remain open.
- Documentation only: no runtime, companion pin, tag or release changes.

## Unreleased — iPhone USB Realtime companion (2026-09-23)

- Pin both companion checks to the mobile USB WebSocket relay fix and its
  regression tests. Active and documented workflows remain identical.
- This changes no backend runtime and does not by itself close physical-device
  acceptance or any production/security gate.
- Make the pooler acceptance probe wait for a successful authenticated SQL query
  after HTTP health: CI observed a healthy endpoint before port 5432 accepted
  connections. Both pool modes still require SELECT 1 and invalid-password
  rejection. Twelve bounded attempts fail closed; regression tests cover startup
  recovery, permanent failures, empty results and wrong results.

## Unreleased — Grafana OS patch and PostgREST provenance (2026-09-23)

- Rebuild digest-pinned Grafana 13.2.2 with Alpine OpenSSL 3.5.8 while preserving
  every publisher-signed bundled plugin file; local startup and health pass.
- Record byte-for-byte publisher release provenance for the PostgREST v14.17
  static binary. Its bundled dependency inventory and vulnerability assessment
  remain a release gate; the publisher evidence is not a substitute for them.

## Unreleased — setup HTTP readiness (2026-09-23)

- Wait up to 90 seconds per internal HTTP probe for transient gateway/transport
  failures after service recreation. Authentication, route and application errors
  still fail immediately; persistent outages fail at the deadline.
- Cover transient recovery, permanent errors, deadline exhaustion and redacted
  transport diagnostics. The exact-main follow-up caught a configuration HTTP 502
  during setup rerun after all container health checks had passed.

## Unreleased — source dependency audit and pooler diagnostics (2026-09-22)

- Audit container npm source manifests in CI, including metadata build/test
  tooling; update vulnerable dependencies while preserving generated-type output.
- Remove unused Storage development scripts/dependencies from its runtime
  manifest and apply compatible Fastify/protobuf patches.
- Declare the pooler entrypoint's required open-file limit so CI/container host
  defaults cannot prevent startup. Allow initialization time, bound probe
  connections, and report redacted
  failure diagnostics; cover credential-redaction regressions.
- Explicitly retain moderate and unfixed upstream advisory boundaries.

## Unreleased — Studio and metadata security (2026-09-22)

- Adopt the patched official September 21 Studio application and remove unused
  package-manager tools from its runtime image.
- Rebuild postgres-meta v0.99.0 against a compatible Fastify 5 plugin set, with
  a reviewable source patch, locked dependencies and retained upstream license.
- Verify Studio HTML/assets and metadata endpoints in CI; record 197 passing
  upstream metadata tests and retain Grafana publisher signatures as a gate.

## Unreleased — orders/cart companion and maintained image recipes (2026-09-22)

- Start Realtime in the default demo and pin both mobile companion jobs to
  `989ade8e86f313ae4b173ad1bb5b56607ecbe353` for orders/cart live updates.
- Add digest/checksum-pinned source recipes and dependency locks for patched
  monitoring, Auth, Storage, PDF, PostgreSQL helper, and pooler images; preserve
  the PostgreSQL server version and production gates.
- Verify pooler session/transaction queries and invalid-password denial in CI;
  validate monitoring configuration using the actual maintained images.
- Retain upstream license texts and notices for copied dependency manifests;
  record patch/acceptance boundaries in `docs/CONTAINER_SECURITY.md`.

## Unreleased — image remediation and production dependencies (2026-09-22)

- Build Edge Runtime and Realtime from digest-pinned upstream images with Debian
  security updates; preserve their upstream application versions.
- Reject missing, invalid, mismatched and vulnerable image-scan reports even when
  the scanner exits successfully; cover false-success regressions.
- Record the nine remaining production areas with specific external inputs and
  distinguish those blockers from unfinished image/mobile Realtime engineering.

## Unreleased — remaining local gates (2026-09-22)

- Verified actual Realtime update delivery, customer isolation and reconnect;
  restore fictional fixture notes after the probe.
- Image scanning now rejects failed/empty Compose inventory and uses a fresh
  private report directory per run.

- Removed unused recommended CUPS packages, clearing its 56 fixed HIGH/CRITICAL
  findings. Require an administrator password and preserve the spool on startup;
  CI verifies the hardware-free startup path.

## Unreleased — provider-independent local readiness (2026-09-22)

- Added private backup plus isolated restore verification, owned-service recovery,
  database retention preview/apply boundaries, gateway CORS/body/TLS checks,
  local load smoke, monitoring validation, and authenticated Realtime smoke.
- Updated current upstream service images and their required configuration,
  constrained cAdvisor metrics, removed the unused analytics service, and kept
  host ports on loopback with explicit resource budgets.
- Added an all-profile Trivy scanner. Its unsuppressed fixed HIGH/CRITICAL
  findings remain a production blocker, including optional service images.
- Extended CI to exercise the new local operational checks and preserved
  byte-identical tracked workflow copies.
- Made the Realtime smoke tolerate only bounded transient Kong 502/connection
  errors while the newly started upstream becomes routable; authentication and
  protocol failures still fail immediately.
- Paired the backend evidence with a native Android debug build and artifact
  contents/permissions/notices audit in the mobile repository. No binary or
  signing credential is published.

## Unreleased — iOS acceptance handoff (2026-09-21)

- Reconciled the release and production checklists after final acceptance: all
  evidenced source-demo dependency, device, authorization, business-flow and
  ownership items are closed; only production deployment and future-binary gates
  remain open.
- Closed the complete physical-iPhone source-demo matrix on the final merged pair:
  backend PR #13 / `cf18f1e43ab613310b1b13339ab97e8533861f9b` with mobile PR #18 /
  `9ba56ff122dc38dc57d6100de4c27599023d22b1`; exact-main CI and affected
  iPhone reruns passed.
- Added customer-authorized per-GRN dispatch history, readable demo fixtures and
  stable order-item snapshots supporting the final mobile acceptance fixes.
- Recorded the end-user pricing, code-level billing-day and PDF/cold-storage
  branding customization boundaries in the durable handoff.
- Added guarded customer-history RPCs for the post-release mobile repair:
  customer GRN filtering/pagination now matches the exposed view controls, and
  a paginated customer dispatch-header list returns only assigned-customer data.
  The associated live API coverage verifies pagination and cross-customer denial.
- Fresh isolated-demo migration and live companion-contract checks passed. The
  repair subsequently passed paired PR review, exact-main CI, the earlier
  customer-history pair's Android smoke and the final physical-iPhone closure;
  published source-only tags are unchanged.
- Fixed configuration, doctor and migration-plan CLI execution through symlinked
  checkout paths, including macOS temporary directories. Added regression coverage
  and restored the setup-failure/configuration-preservation test.
- Aligned the developer handoff with complete physical-iOS evidence, closed mobile
  defects, reproducible USB onboarding and pricing/PDF customization contracts.
- Pinned both CI workflow copies to the submitted mobile handoff commit.
- Preserved published source-release tags; the follow-up passed paired review and
  exact-main CI.

## 0.2.2-demo — source-only prerelease (2026-09-18)

- Added checksummed forward migrations for padded dispatch suggestions and
  protected invoice line-detail compatibility without changing stored document
  identifiers.
- Added numeric ordering, rollover/exhaustion, authorization, fresh/upgrade,
  mobile-validator, and isolated API regression coverage.
- Added ownership-aware clean onboarding, loopback isolation, configuration and
  data-preservation checks, and exact mobile companion pinning in both workflow
  copies.
- Verified the complete source-demo API matrix and paired Android onboarding;
  production and physical-device release gates remain separate.
- Reconciled public onboarding, acceptance scope, maintainer redistribution
  attestation, Supabase-derived configuration provenance, and included license text.
- Restricted the release workflow to the exact `v0.2.2-demo` tag with positive
  and negative regression coverage; publication contains source archives only.

## Unreleased — second-pass review

- Corrected readiness claims: fresh migrations and mobile API coverage fail;
  setup/start and future releases are gated pending a complete sanitized export.
- Added isolated migration/contract tests, credential-preservation and JWT/profile
  regression tests, Compose ownership checks, and explicit readiness documentation.
- Hardened custom-auth function checks and corrected public configuration URLs.

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0] - 2026-03-10

### Added
- Initial release of the Supabase Warehouse Template
- Custom phone OTP authentication (no GoTrue dependency)
- Docker Compose setup with 10+ containers
- Edge Functions: router, config, PDF generation, printing
- CUPS printing integration via IPP
- Gotenberg HTML-to-PDF conversion
- Prometheus + Grafana monitoring stack (optional profile)
- Connection pooler via Supavisor (optional profile)
- One-command setup script with automatic secret generation
- Health check script
- Comprehensive .env.example with all variables documented
- CI/CD workflows for GitHub Actions
- Consolidated database migration with warehouse schema
