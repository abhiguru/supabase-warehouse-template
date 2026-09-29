# Operator backend installation candidate

The purpose of this candidate is to install a separate working warehouse from
repository instructions. It is not a production security or native-app release.
Backend PR #68 consolidates installation/runtime fixes, backend core tests and
this handoff. Use the exact commit and CI run recorded in that PR; no release tag
is approved yet. The release gate remains closed while its native-device and
other release requirements are outstanding.

## Evidence and version boundaries

Historical pilot checkout: `4f1efb8dd4f8c748961a0f250c5af4fc202fb38a` plus
local installation fixes. Its application fixes were published at
`80cc90b435d7fee6a13e0beb1e2931536e5d75cf`; later local backup/restore changes
and scheduled-job code belong to separate recovery review branches. The running
pilot is not represented by one clean source commit. Do not reset it to this
candidate or apply a deployment as part of repository review.

The source tested before consolidation was backend `80cc90b435d7fee6a13e0beb1e2931536e5d75cf`.
Backend test commit `71e93279fc49a486003bc60b993121fd8e69bceb` added fictional
SQL, HTTP, Storage and Realtime probes. Its historical documentation is preserved
at `54dcb8b497e8de0f2390b09b5a8ab784c10d71b8` on the separate handoff branch;
that branch's recovery implementation is not a dependency of this candidate.

| Historical CI commit | Run | Result |
| --- | --- | --- |
| `831678619e175eeb3c1b656ea932d290da705c5b` | [36313593609](https://github.com/abhiguru/supabase-warehouse-template/actions/runs/36313593609) | Failed: offline MSG91 fixture identifiers |
| `9c891f4f4b1b480e8d545454efbfd323e7c9d1c2` | [36313952647](https://github.com/abhiguru/supabase-warehouse-template/actions/runs/36313952647) | Passed after fixture correction |
| `80cc90b435d7fee6a13e0beb1e2931536e5d75cf` | [36318005179](https://github.com/abhiguru/supabase-warehouse-template/actions/runs/36318005179) | Passed |
| `246c275787cfb05f3c58be62b3b2757496cc4e66` | [36337622464](https://github.com/abhiguru/supabase-warehouse-template/actions/runs/36337622464) | Passed; documentation-only successor |

These results do not apply to a newer candidate automatically. New exact-commit
results belong in PR #68 before merge. The existing contract CI pins companion
mobile source `8240cce9121a797fd0cf2e00e568a61985814ddb`; native acceptance is deferred.

## Backend verification

The earlier isolated review passed 47 unit tests, disposable migration/auth tests,
and the fictional SQL stock/invoice regression. Operator HTTP tests passed
identity, enrollment/approval, catalog/pricing, customer A/B lists/mutations,
cart, partial/final dispatch, retries, invalid quantities, concurrent stock,
invoice save, private Storage and four signed PDF flows, refresh/replay and logout.
Realtime A/B delivery and reconnect passed. Staff queue, GRN/dispatch image
lifecycle and disabled-account REST/Edge/refresh denial passed. Gateway, Studio,
local doctor and retention preview passed. Raw logs and fixture sessions are
private outside Git.

Preserve failed test-authoring attempts: missing transaction auth configuration,
wrong fixture response path, an overly specific denied-cart response assertion,
a stale has-items filter after dispatch, and repeated fictional logins reaching
normal OTP limits. The initial Realtime timeout was not a pass. The consolidated
probe now requires explicit invalid-token rejection rather than treating a
connection timeout as rejection. All affected probes must pass again.

The fictional invoice example is 100 bags received on April 1, 2026, then 20 and
80 dispatched on May 2: monthly price 5, labour 2, tax 5%, legacy duration 1.5.
Partial stock is 80 bags / 800 kg, final stock zero, subtotal 950, rounded header
tax 48 and total 998. See [existing invoice rules](INVOICE_RULES.md). The save API
accepts client-supplied header totals; this is not production accounting approval.

## Reproducing the backend fixture

Follow [OPERATOR_INSTALL.md](OPERATOR_INSTALL.md) from a clean checkout on a
fresh Linux x86-64 host. For isolated verification only, use a private state
basename `core-backend-test-<digits>`, company `Fictional Core Warehouse`, origin
`https://backend-core.example.test`, administrator `919888888871` and display
name `Core Demo Administrator`. The reserved example origin is not a public
route. Use these five entries in a private provider file outside Git:

```dotenv
SMS_PROVIDER=msg91
MSG91_AUTH_KEY=isolated-no-delivery-key
MSG91_TEMPLATE_ID=000000000000000000000001
MSG91_PE_ID=0000000000000000001
MSG91_SENDER_ID=CITEST
```

The repository CI uses exactly this fixture. With `WAREHOUSE_STATE_DIR` exported
and setup successful, run:

```bash
npm ci
npm test
npm run test:migrations
node tests/operator-api-core.mjs
node tests/operator-realtime-core.mjs
node tests/operator-api-final.mjs
```

Use a fresh fictional state for the sequence; later probes depend on earlier
fixtures and the final probe disables customer B. Tests verify private state,
fictional identity/provider values and running Compose ownership before mutations.
They use loopback and service-only SQL test facilities; no SMS request is made.
The final image/account probe uses the existing internal issuer only within the
disposable database. No production authentication bypass is introduced.

When the default local gateway port is occupied on a shared development host,
configure the fresh test state before setup using `node scripts/configure.mjs`
with the same `--state-dir`, `--api-url`, `--company` and `--provider-env` values.
Set only `KONG_HTTP_PORT=18080` in that test state's private `config/compose.env`,
retaining mode 0600, then run the documented setup command. This is test-instance
configuration, not a repository patch. Tests read the configured port. No public
DNS, HTTPS routing or live instance configuration is changed.

After verification, stop only that owned stack with
`bash scripts/compose.sh --profile '*' down`. Keep evidence and test credentials
private. Do not run these fixture scripts against an operational warehouse.

## Scope and remaining gates

Recovery rehearsal is closed. The pilot at `172.16.194.128` remains the only live
writer and connector. Do not contact `172.16.194.130`, transfer archives, request
SSH keys, resume proxy rehearsal, send OTPs, deploy drafts, change public routing
or cut over. Earlier recovery instructions are historical evidence only.

Android/app acceptance, printing, sensors, external alerts and credential rotation
remain deferred. The standalone Android build was stopped without an accepted
artifact. Production billing and retention rules, capacity targets, physical-host
unattended lifecycle and open image findings remain unresolved. No new image
research or security approval is implied by passing installation tests.

Existing backup receipts were observed only: 42 receipts at September 29 14:43 UTC,
newest snapshot age 804 seconds with matching hash/size and mode 0600. Natural
48-hour pruning first becomes eligible September 30 18:45:10 UTC; its execution
and protection of unrelated files remain unverified. No operator backup, restore,
retention apply or host reboot is authorized by this repository consolidation.
