# VM-only backend reproduction checkpoint

The 48-hour acceptance campaign started on 1 October 2026 at 16:27:13 UTC and ends on 3 October at the same time. This is an in-progress checkpoint, not release or production acceptance. Test1 was not changed; no pilot or recovery host, real SMS, public DNS, tunnel, restore, transfer or cutover was used.

The backend application source remains `bed4eeee4a008073aa453c32da27cade50a32a2f`. The application was not changed to simplify acceptance.

Consistent owner-only database/storage backups of the two retired fictional stacks passed checksum and archive-catalog checks. Their state and containers remain preserved. Readability does not claim restoration.

Follow [OPERATOR_INSTALL.md](OPERATOR_INSTALL.md) from clean pinned source using fresh disposable state. The campaign did this in dependency order: private configuration, setup and migrations, administrator bootstrap, public identity, local doctor and fictional HTTPS discovery. The only networking installation overlays were separately declared fixture subnets and loopback gateway ports. Independent primary, switching and same-origin replacement warehouses have separate state, credentials and genuine UUIDs.

| Executed backend scope | Evidence result |
| --- | --- |
| Clean primary installation and local doctor | PASS |
| Independent switching and same-origin replacement installs/guards | PASS; native replacement test remains pending |
| Repeat setup | PASS; identity, credentials, administrator, observed records and five actual stored-document hashes retained |
| Unit and scratch migration checks | PASS; 80 source tests and migrations |
| Container/source dependency audits, secret scan and mobile contract | PASS |
| Business API, quantities, stock, concurrent/duplicate/idempotent operations | PASS |
| Reciprocal fictional customer/staff REST, Realtime, image and private PDF boundaries | PASS |
| Authentication/replay/logout/disabled account and mocked provider contracts | PASS within local API/source scope; no real delivery |
| Gateway CORS, payload/private exposure, discovery and upstream DNS/IP behavior | PASS |
| Studio/metadata, retention preview and private local monitoring | PASS; local-only alert receiver, no external delivery |
| Bounded load smoke | PASS declared workload/thresholds; no production-capacity claim |

Some historical API validation helpers issue sessions internally. Those results remain API evidence. New native and campaign preparation logins use ordinary fictional authentication through the guarded local mock-provider bridge; no fixed OTP or counter reset is used.

Each fictional certificate has a 14-day lifetime, exact test hostname and independent key. Primary, switching and fault helpers run under fresh supervised identities with the existing 12-hour caps and actual pinned TLS/IPC readiness. Before another long stage, check their remaining lifetime; do not replace helpers during a frozen run.

Private evidence retains all failed attempts. Native after-commit dispatch committed exactly once and reconciled stock/cache; an observer audit-timestamp mismatch stopped the case before retry. Its successful document is preserved and unchanged retry is not claimed. Other bounded native dispatch attempts exhausted their corrected reruns and remain blocked. These do not invalidate the separate backend API results or permit a gate bypass.

The new-artifact eight-hour soak and dedicated natural-expiry appointment have not started. Mobile native business, switching, lifecycle and document acceptance must be completed or explicitly recorded as blocked first. ARM execution, physical-device acceptance, real-provider acceptance, production policies, recovery and release remain outside this VM-only campaign.
