# Backend core-pilot acceptance — 2026-09-29

Status: **isolated backend core checks passed; wider production approval remains open**.
This ledger supersedes older next-action instructions, not historical evidence.
Recovery is closed. Preserve the sole live writer/connector at 172.16.194.128.
No recovery-host contact, archive transfer, proxy rehearsal, SMS delivery,
merge, deployment, route change, cutover or reboot belongs to this milestone.

## Version and review boundaries

| Component | Exact identity and disposition |
| --- | --- |
| Installed backend checkout | `4f1efb8dd4f8c748961a0f250c5af4fc202fb38a`, with local modifications; not a clean release commit |
| Installed application changes | MSG91 worker, migration 17, compose, setup and doctor files match `80cc90b435d7fee6a13e0beb1e2931536e5d75cf`; backup/restore script content matches `56b5f11b6a40d45579f004657a6b8dd2bb330f4e` with executable-mode differences |
| Scheduled job checkout | `6e479e241524a60010064635a35841d4b42b2de7`; separate from the installed application checkout |
| Mobile source / historical installed debug build | `8240cce9121a797fd0cf2e00e568a61985814ddb`; historical pilot app uses an untracked identity override and requires Metro |
| Backend tested baseline | `80cc90b435d7fee6a13e0beb1e2931536e5d75cf`, paired with mobile `8240cce9121a797fd0cf2e00e568a61985814ddb` as pinned in backend CI |
| Proposed backend test change | Local review commit `71e93279fc49a486003bc60b993121fd8e69bceb` in separate backend worktree: rollback-only fictional SQL regression and operator HTTP/Realtime probes; no API/schema/auth boundary change |
| Proposed mobile build | Separate `codex/android-core-review` worktree; identity `in.gurucold.warehousecoredemo`, version 0.1.0/build 20260929; release variant uses test/debug signing, not distribution signing |
| Proposed documentation | Separate `codex/android-core-handoff` based on `56b5f11b6a40d45579f004657a6b8dd2bb330f4e`; carries the two existing uncommitted closeout documents and reconciles the handoff/ledger |

Original checkouts and closeout edits are preserved. Raw logs, sessions and device
serials stay outside Git under the private pilot evidence directory. Build inputs
reuse installed dependency caches; a fresh dependency installation was not claimed.

## PR dependencies and CI

Read-only GitHub verification on 2026-09-29 found backend [PR 68](https://github.com/abhiguru/supabase-warehouse-template/pull/68)
open/draft at `246c275787cfb05f3c58be62b3b2757496cc4e66`, one documentation-only
commit beyond the tested baseline. Mobile [PR 33](https://github.com/abhiguru/rn-warehouse-template/pull/33)
is open/draft at `8240cce9121a797fd0cf2e00e568a61985814ddb`.

| Commit | Exact CI evidence | Result |
| --- | --- | --- |
| Backend `831678619e175eeb3c1b656ea932d290da705c5b` | [36313593609](https://github.com/abhiguru/supabase-warehouse-template/actions/runs/36313593609) | Failed: offline MSG91 fixture IDs did not meet format validation; preserve this attempt |
| Backend `9c891f4f4b1b480e8d545454efbfd323e7c9d1c2` | [36313952647](https://github.com/abhiguru/supabase-warehouse-template/actions/runs/36313952647) | Historical recorded success after fixture correction |
| Backend `80cc90b435d7fee6a13e0beb1e2931536e5d75cf` | [36318005179](https://github.com/abhiguru/supabase-warehouse-template/actions/runs/36318005179) | Success, verified via API |
| Backend `246c275787cfb05f3c58be62b3b2757496cc4e66` | [36337622464](https://github.com/abhiguru/supabase-warehouse-template/actions/runs/36337622464) | Success, verified via API |
| Mobile `8240cce9121a797fd0cf2e00e568a61985814ddb` | [36289818695](https://github.com/abhiguru/rn-warehouse-template/actions/runs/36289818695) | Success, verified via API |

Recovery PR chain remains separate and closed to further rehearsal:
68 → 69 (`e15cd6b`) → 70 (`b1945a2`) → 71 (`d8766b6`) → 72 (`e5e6436`)
→ 73 (`c56a8f3`) → 74 (`56b5f11`) → 75 (`e7c287c`) → 76 (`c74bf6a`).
PR 77 (`162e16c`) branches from the replacement-restore review, independently of
72–76. All were open drafts at inventory. PRs 1, 34, 35, 36, 52 and 78 are
separate dependency proposals, not installed changes or approval to resume image
research. No CI result above applies to these branches or the new local edits.

## Backend verification and acceptance matrix

Node 22.23.1 used for all JavaScript checks. Host default Node 18 was not used.

| Required behavior | Evidence / remaining boundary |
| --- | --- |
| Backend unit checks, including mocked provider rejection/timeout/retry | 47/47 passed; no SMS sent |
| Migration, authorization and OTP lifecycle | Existing disposable suite passed: network disabled, no host ports, fictional credentials; replay/expiry/limits, enrollment, refresh and disablement checks. Not HTTP/native evidence |
| Mobile unit and setup checks | 217/217 in 33 suites and 30/30 setup checks passed |
| Static mobile contract | Passed, no missing RPCs or argument mismatches; dynamic calls and access behavior still require runtime checks |
| Mobile typecheck and lint | Passed; 0 errors, 1,468 existing lint warnings |
| Identity, branding, catalog, assignments and pricing | Isolated public identity, administrator catalog/price creation, customer A/B enrollment and assignments, and role-scoped HTTP reads passed. Native branding remains deferred |
| Receipt → stock → partial/final dispatch → invoice | New rollback-only SQL regression passed: catalog/pricing, receipt, partial/final dispatch, retry, 80/0 stock balances, exact line/header totals, save and failed-invoice rollback; production billing sign-off remains outside this demo |
| Customer order/cart and staff queue | Customer A cart add/list, B denial, administrator table and staff queue reads passed over isolated HTTP |
| Duplicate submissions / concurrent stock / invalid quantities | Isolated HTTP suite passed: duplicate dispatch key, negative quantity, 81-bag oversell, and simultaneous 7+7 attempts against 10 bags with one success and stock 3 |
| Roles, rejection, disablement, refresh, revocation, logout | Operator SQL covers approval/rejection, expiry, replay and rate limits; isolated HTTP covers approval, refresh replay, logout, and disabled account denial through REST, Edge and refresh. Native lifecycle is deferred |
| Customer A/B lists, mutations, Realtime, images and PDFs | Isolated HTTP/Storage suite and operator Realtime probe passed A/B separation, image lifecycle, signed PDF download, direct bucket denial, event delivery and reconnect |
| Failed/retried uploads and private PDF viewing | Isolated Storage rejected unauthorized and duplicate uploads, preserved first object after a failed retry, rejected oversize registration; signed private PDFs downloaded and direct bucket reads failed. Native viewing is deferred |
| Android acceptance | Deferred by operator until backend testing is complete; no current candidate was completed |







The current full API business harness (`tests/api-demo.mjs`) requires historical
fixed-OTP demo mode. The operator Realtime wrapper explicitly refuses that mode.
Neither was run. A second isolated HTTPS operator instance will be needed later for Android server switching; do not point tests
at the pilot, enable a production bypass, or reuse the recovery host.

## Fictional billing policy selected for this milestone

The user explicitly requested a fictional demo. Use existing documented rules:
receive 100 bags of 10 kg on April 1, 2026; dispatch 20 and 80 on May 2;
monthly price 5, labour 2, tax 5%, legacy duration 31 days / 1.5 periods.
After the first dispatch and identical retry: 80 bags / 800 kg. Final stock: zero.
Line bases: 190 and 760; line taxes: 9.50 and 38.00. Header subtotal 950,
ceiling tax 48, total 998. Discount zero. The existing save API accepts supplied
header totals; this exercise does not make it server-authoritative or approve
production financial policy. See [invoice rules](INVOICE_RULES.md).

## Routine operations observation

At 2026-09-29 14:10:55 UTC, 41 existing receipts ranged from September 28
18:45:10 UTC to September 29 14:00:01 UTC. Maximum adjacent source gap was
1,822 seconds. Newest source age was 654 seconds; newest archive hash, size,
regular-file status and mode 0600 matched. This is receipt-history observation,
not independent verification of every archive or continuous monitoring.
Backup and health services reported success/status 0; timers remained scheduled.
Root disk: 141 GiB available; backup disk: 9.6 GiB available at observation.

No receipt was yet 48 hours old. First eligibility is **2026-09-30 18:45:10 UTC**
(October 1 00:15:10 IST). Actual natural pruning and protection of unrelated files
remain open; do not force expiry or trigger jobs to manufacture evidence.
No backup, restore, retention apply or service restart was triggered here.
A later read-only check at 2026-09-29 14:43:26 UTC found 42 receipts, newest source age 804 seconds, matching archive size/hash and mode 0600. Both scheduled services still reported success/status 0. No receipt was yet eligible for 48-hour pruning.

Daily operator checklist:

1. Read existing health and backup service results; investigate any nonzero exit
   or missing expected run. Preserve redacted timestamps and diagnostics.
2. Compare the newest source snapshot time against the configured 50-minute
   freshness limit; receipt verification time is not the snapshot time.
3. Check the backup mount identity, capacity and newest receipt/archive integrity.
   Check root-disk growth as well. Do not delete business data to regain space.
4. After natural retention eligibility, compare before/after owned archives and
   protected/unrelated-file inventory. Record actual pruning and job result.
5. If a check fails, notify the designated operator through the separately agreed
   escalation process. External alerts remain deferred; local success does not
   establish unattended failure detection. Do not cut over automatically.

Physical-host unattended startup/shutdown remains open. Schedule no reboot.
Printing, sensors, iPhone, external alerts, credential rotation, production
retention policy, distribution signing and wider production approval remain
explicitly deferred. Existing image findings remain open and are not waived.

## Test attempt preservation

The original migration suite passed before the new fixture was added. New fixture
attempts 1–2 failed at mocked login because its transaction did not initialize
the operator auth configuration; attempt 3 reached catalog/customer creation but
used an incorrect customer response path. The corrected fixture selects the
created customer by its unique fictional name and initializes its own rollback-only
auth/provider configuration. Attempt 4 passed the entire migration suite including
the core fixture. These were test-authoring failures, not demonstrated application
regressions. All four private logs are retained; no failed run is counted as a pass.

Backend production source is unchanged. The new test is exercised via
`npm run test:migrations` on the isolated backend review checkout. Its Docker
database uses `--network none`, tmpfs storage, no host ports and automatic cleanup.
The SQL transaction rolls back every fictional business row and test session.
No SMS worker or provider endpoint is involved.

## Backend-only isolated HTTP review

The operator redirected this milestone to backend testing before further Android
work. The standalone Android build was interrupted before producing an artifact;
no candidate APK hash or device acceptance is claimed. Earlier source mobile
unit results remain historical context only. No further mobile or Android tests
were run after the change in scope.

An operator stack was installed in a private test state outside all checkouts
with a unique Docker Compose project and a separate loopback gateway on port
18080. Its identity is `Fictional Core Warehouse` at the unused documentation
origin `https://backend-core.example.test`; the HTTP tests use loopback only.
All credentials, OTP codes and raw logs stay in private evidence. Sessions are
issued through the existing service-only prepare/finish/verify functions against
the disposable database with a mocked provider acceptance. No SMS worker or
provider endpoint was called. The pilot and recovery host were not used.

The backend-only `tests/operator-api-core.mjs` (separate backend review checkout) verifies public
identity, anonymous denial, fictional administrator and approved customer
sessions, customer A/B lists and mutations, catalog and price creation, cart,
receipt, partial/final dispatch, duplicate retry, invalid quantity and oversell
rejection, simultaneous conflicting dispatches, stock balances, invoice preview
and save, private image upload/download rules, duplicate upload retry, four
authorized PDF downloads and direct-bucket denial, refresh replay and logout.
Its second run passed on the fresh isolated installation. An initial run stopped
at a test assertion that expected a particular denied-cart response body; the
server denied the request. The corrected assertion accepts the documented HTTP
denial or an unsuccessful body. The first attempt remains in private logs.

Gateway CORS/body-size checks, Studio compatibility, local doctor and retention
preview passed on this isolated project. Retention preview changed no data.
The `tests/operator-realtime-core.mjs` (separate backend review checkout) first failed
on a WebSocket join timeout. Its corrected second run passed authenticated A/B
and administrator subscriptions, invalid-token rejection, A/B event isolation and
delivery after reconnect. Both private logs are retained; the first attempt is
not counted as a pass.

The `tests/operator-api-final.mjs` (separate backend review checkout) passed staff queue
visibility, GRN/dispatch image registration, upload, confirmation, customer A/B
read rules, deletion, oversize rejection, and disabled-account denial through
REST, Edge and refresh. Earlier attempts stopped on a stale `p_has_items` test
filter after dispatch and then on the real OTP resend/hourly limits. Those
limits were preserved. The final probe used the existing internal session issuer
only inside the disposable test database. Earlier operator HTTP and SQL suites
already tested actual OTP challenge/verification, replay and rate limits. No
production auth bypass was added. Failed attempts remain in private logs.

The backend test additions are committed locally for review at `71e93279fc49a486003bc60b993121fd8e69bceb` with no CI result yet.
They do not alter migrations, public RPC signatures, production authentication,
or running pilot code. The historical PR/CI results above apply only to their
listed commits. Isolated service/project was stopped after testing; test state
and private logs were retained outside Git for review.

Backend core behavior is demonstrated for fictional data and the existing demo
billing policy. Production billing rates/tax/rounding approval, business-data
retention policy, sustained capacity and availability targets, open image
security findings, external alert delivery and physical integrations are
separate unresolved gates. Do not treat this review as production approval.

Reproduce backend core verification only in a fresh isolated operator stack: run
`npm test` and `npm run test:migrations`, then set `WAREHOUSE_STATE_DIR` to that
stack's private test state and run `node tests/operator-api-core.mjs`,
`node tests/operator-realtime-core.mjs`, and
`node tests/operator-api-final.mjs` in that order. The latter two reuse fictional
customers created by the first. These scripts intentionally refuse a state path
without the `core-backend-test-<digits>` prefix and require loopback port 18080.
The test provider configuration must use fictional values and cannot deliver
SMS. If OTP cooldown is active, wait for the normal interval; do not change
production challenge or rate-limit code. Stop only the owned Compose project
after collecting sanitized results.
