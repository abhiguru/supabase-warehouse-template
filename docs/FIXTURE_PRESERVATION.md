# Guarded fixture preservation and ordinary final-test authentication

The backend final workflow now obtains each fictional session through normal
OTP preparation, mocked provider completion and ordinary verification. It waits
for the existing cooldown and consumes normal quotas. It does not directly call
the internal session issuer, reset counters, use fixed OTPs or change timestamps.
Admin/customer A/customer B use at most3/4/4 challenges across core, Realtime and
final workflows. Final-test admin/A sessions are normally logged out; disabling
B follows its dependent cases and removes B sessions through the administrator
API. Earlier unrelated sessions and business records are preserved.

The optional private final-test binding contains mode
`ordinary-final-backend-fixture`, backendCheckout, backendState, instanceId,
fixtureGuardSHA256 and evidenceRoot. The driver imports that exact unchanged
fixture guard, validates the real identity and private owned evidence directory,
and cannot replace frozen backend inputs. Ordinary same-checkout runs need no
extra argument. For VM acceptance use the private binding so newly created image
bytes and metadata are saved before the intentional deletion lifecycle test.
Upload/download bytes must equal the actual1024-byte fixture input. No upload
secret or signed URL is serialized. Authentication and image lifecycle changes
remain explicitly dated test evidence, not production account acceptance.

`scripts/fixture-preservation-snapshot.mjs PRIVATE_CONFIG OUTPUT_JSON` is a
read-only observer. Its private binding has mode `read-only-preservation`,
backendCheckout/backendState/instanceId/fixtureGuardSHA256/evidenceRoot. It uses
the original guard and repeatable-read read-only SQL; credential/session/OTP
rows are hashed inside PostgreSQL and never exported in plaintext. Actual stored
files are bounded and hashed, without following symlinks. Outputs are private,
created once, and contain hashes/counts/fictional file paths only.

Compare configuration/identity, all table counts and stable hashes and all actual
file hashes across repeated setup. Preserve full hashes too. Existing setup
updates only the SMS configuration timestamp even when credentials are equal;
`public.sms_config.updated_at` is the sole declared stable-hash exception, never
an allowance for credential or business changes. Record any other difference
as failure and reconcile before retry. Do not infer a repeat-setup PASS from an
observer-only check.

Actual populated-fixture observer validation:85 tables/17 files read twice,
identical snapshots, no writes. Private proof under VM campaign
`backend-reproduction0110-01/observer-populated-primary-proof01.json`.
The fresh079ab4a VM setup/local doctor/unchanged guard now PASSed on its final
allowed corrected attempt. Business, repeat-setup, supporting and fixture HTTPS evidence now PASSed
separately; exact scope is recorded below. Both prior install failures,
exact preserved images and owned-cache reclamation remain recorded.

## Independent discovery listener

Fixture-only supervisor/bridge tooling accepts optional core TLS port19543
only with the original hash-bound owning checkout. The default remains18443;
switch/fault/privileged/arbitrary ports and missing ownership are refused.
The twelve-hour cap and restart prohibition remain unchanged. Use a new unit
and private IPC path; never replace the original core listener or emulator
reverse route. This enables HTTPS discovery against an independent current-source
VM fixture while the original native acceptance warehouse remains selected.
Backend source regressions, including explicit parser/ownership refusals,
PASS107/107. Actual TLS19543 and private IPC readiness PASSed in tls-readiness-proof02.json;
original TLS18443 identity and route were preserved, with zero OTP requests.

Fresh VM core API, Realtime, final ordinary-authentication/image/account cases
now PASSed once under application079ab4a and tooling1c2b724. Actual read-only
snapshots bracketed every group. All five earlier stored files remain unchanged;
both intentional1024-byte image lifecycle deletions have saved byte/metadata
evidence. No sessions were minted through the internal test issuer and no
quotas/timestamps were reset. Repeat setup, supporting gateway/Studio/load checks and exact current mobile
live contract subsequently PASSed in supporting-result02.json. Repeat setup
preserved85 tables and five actual files; only sms_config.updated_at changed. Private result:
`backend-reproduction0110-01/business-result01.json`.

## Normal rejection, disabling and replay

The explicitly bound operator-api-auth-states.mjs driver consumes normal quotas
for one administrator login, one disabled B challenge, and two challenges for
a new reserved fictional rejection account. It verifies pending/no session,
normal administrator rejection, rejected and disabled account_unavailable, and
OTP replay invalid_otp. Only the new administrator session is normally logged
out; business/files and earlier sessions remain preserved. There is no provider
delivery, counter reset or manual timestamp change.

Actual fresh-fixture assertions PASSed once under driver6fb66af. The surrounding
controller FAILed because its expected-change list omitted audit_log and its
October partition. Preserve that failure; do not replay login. Independent
read-only reconciliation proved all29 existing audit rows byte-equivalent by
hash, exactly five new user_profiles audit events for the reserved accounts,
and unchanged business, configuration, identity and actual stored files.
Private auth-states-result01.json remains FAIL; auth-states-proof01.json and
auth-states-reconciliation-proof01.json separately record assertions and
reconciliation PASS. Observer source1c2b724 and driver6fb66af are distinct.
The proof field timestampChanges:0 means no manual clock/timestamp manipulation;
normal backend authentication timestamps and audit entries changed as designed.
This is backend evidence and does not close native authentication acceptance.

## Mocked provider contract

The reviewed provider suite now explicitly covers malformed200 responses, absent/
trimmed/bounded request IDs, terminal429 after at most one explicit retry, and
malformed503 without retry. Existing cases cover missing authentication/template,
invalid payload, authentication/template rejection, ambiguous timeout, and
contradictory success on gateway error. All sends are injected in-memory mocks;
no provider transport or handset delivery occurs. Full source suite118/118 PASS.
This is source/provider-contract evidence, not real-provider acceptance.

## Prepared natural OTP expiry and limits

operator-api-otp-expiry.mjs is a separately bound backend-only driver. It requires
an unused ordinary quota budget/window, prepares and mock-accepts a random
challenge, observes resend_cooldown without consuming another challenge, waits
for its actual five-minute server expiry, and verifies invalid_otp with no
session. It then reaches the existing hourly five-challenge limit through at
most five ordinary challenges, retaining normal cooldowns, and verifies
rate_limited without counter resets. It never changes clocks/timestamps.
The reserved fictional rejection account remains unchanged; no administrator
session, external delivery or Android state is used.

Both auth drivers refuse eight unsafe bindings before fixture/Docker access.
Full source126/126 tests PASS. Fresh supervised OTP stage01 now PASSed on
its first execution. Actual server expiry09:30:24UTC was observed expired before
verification, with zero prior attempts and an unverified challenge. Three normal
challenges moved the reserved account's counters2→5; cooldown/rate rejections
consumed no additional challenge and reset timestamps remained identical.
No session was issued. Read-only before/after snapshots changed only the three
OTP quota/challenge tables; profiles, sessions, business and actual files stayed
unchanged. Private otp-natural-expiry-result01.json/proof01.json and snapshots
record exact source d3ab95c and observer1c2b724. No fourth/alias/replay was used.
This five-minute OTP test does not establish the separate seven-day Android
refresh-session expiry requirement or permit scheduling it before final freeze.
