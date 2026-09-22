# Developer handoff — v0.2.2-demo

## Final post-release closure — 2026-09-22

The local physical-iPhone source-demo handoff is complete. Mobile PR
[#18](https://github.com/abhiguru/rn-warehouse-template/pull/18) merged as
`9ba56ff122dc38dc57d6100de4c27599023d22b1`; backend PR
[#13](https://github.com/abhiguru/supabase-warehouse-template/pull/13) merged as
`cf18f1e43ab613310b1b13339ab97e8533861f9b`. Exact-main CI passed in mobile run
[`35686164009`](https://github.com/abhiguru/rn-warehouse-template/actions/runs/35686164009)
and backend run
[`35686198287`](https://github.com/abhiguru/supabase-warehouse-template/actions/runs/35686198287).

The final pair closes customer-authorized GRN/dispatch history, stable readable
fixtures and order snapshots, per-GRN dispatch history, invoice navigation and
the mobile session/onboarding fixes. Backend gates passed the complete migration,
health/doctor, API, contract and scan matrix, including 94 RPC names / 129 typed
calls with zero missing names or mismatches. The assigned fictional customer
history and related flows passed on an iPhone 15 running iOS 26.6.2; shared
runtime/navigation changes also passed a fresh Android API-36 emulator smoke.
See the mobile repository's `docs/NATIVE_ACCEPTANCE.md` and closed dated review.

The release-tag commands below reproduce the immutable baseline. Existing
`v0.2.2-demo` tags remain unchanged. Enabled telemetry and production/distribution
gates remain separate.

## Active source-demo release — 2026-09-18

Source-demo acceptance and publication are complete. Use `v0.2.2-demo` in
both sibling repositories for the verified release pair. The backend tag targets
`2959881d0e46a8797a98d10da8c7139217477476`; the mobile tag targets
`6e6885786912fe9186285103e19de762e4ba88f8`. At publication, the active and
documented CI copies pinned that mobile commit. Current review pins are above.

Follow `CLEAN_INSTALL.md` with a unique Compose project and unused loopback
ports. Run setup, doctor, health, rerun, stop, and restart with the same project
name. Generate the sibling mobile environment through its script and use the
same localhost API origin. Do not copy configuration, credentials, or database
files from another checkout. Prove configuration and data preservation plus an
Android debug login/connectivity smoke before treating onboarding as
reproducible.

This is a source-demo release, not a production or all-platform release.
Post-release physical Android and iOS evidence has its own qualified scope,
described above. Production SMS/TLS/operations, distribution, enabled telemetry,
printing, sensors, and unsupported integrations remain separate gates.
The reviewed merges, default-branch CI, exact-tag validation, and
matching source-only prerelease publication completed on 2026-09-18.

The 2026-09-18 fresh-clone rehearsal passes generated configuration, migrations,
doctor/health, isolated API fixtures, setup rerun, owned stop/restart, preserved
data/configuration, and the companion Android debug build/login/native smoke.
The durable result is summarized in [SOURCE_DEMO_ACCEPTANCE.md](SOURCE_DEMO_ACCEPTANCE.md),
and ownership/attribution evidence is in [ATTRIBUTION_REVIEW.md](ATTRIBUTION_REVIEW.md).

This pair is a local warehouse development demo, Android first. Production setup
remains blocked.

## Historical `v0.2.1-demo` record

The earlier release notes identify that historical commit pair and verification:
[mobile](https://github.com/abhiguru/rn-warehouse-template/releases/tag/v0.2.1-demo),
[backend](https://github.com/abhiguru/supabase-warehouse-template/releases/tag/v0.2.1-demo).
The tags were published on 2026-09-14. See [release verification](RELEASE_CHECKLIST.md)
for the backend CI checkout failure and subsequent follow-up evidence.

## Prerequisites and paired checkout

Use Node.js 22.18+ with npm, Git, Docker with Compose v2, and OpenSSL. Android
native development needs a compatible JDK (17 or 21), SDK platform 36, build tools
36.0.0, platform tools, and an emulator or USB device. Expo SDK 54 / React Native
0.81.5 remain selected by the lockfile. Allow space for Docker images, npm,
the Android SDK/NDK, and Gradle caches. iOS requires macOS, full Xcode and
CocoaPods; see the mobile native-acceptance record for device evidence.

```bash
git clone --branch v0.2.2-demo https://github.com/abhiguru/supabase-warehouse-template.git
git clone --branch v0.2.2-demo https://github.com/abhiguru/rn-warehouse-template.git
cd supabase-warehouse-template
npm ci
bash setup.sh --demo
npm run doctor
```

Setup exclusively creates `docker/.env` with mode 0600. Reruns preserve its bytes
and permissions. It starts the database, applies checksummed migrations and demo
authorization, then starts the API. Do not copy keys from another installation.
The scripts check both Compose project name and owning checkout before operating.

```bash
cd ../rn-warehouse-template
npm ci
node scripts/create-env.mjs
npm run doctor
adb reverse tcp:18000 tcp:18000
adb reverse tcp:8081 tcp:8081
npm run android
```

The app's `.env` must contain `EXPO_PUBLIC_CONFIG_API_URL=http://localhost:18000`.
Both backend public URL settings must use that exact origin. Android USB devices
and emulators use `adb reverse`; the supported demo does not use a LAN origin.
Physical iOS requires its own USB connection procedure; `adb reverse` does not
apply, and the acceptance-only relays are not supplied by this repository.
With several attached devices, select one using `adb -s SERIAL reverse ...`.
Run `npm start -- --localhost` for later Metro sessions. Doctor is read-only; it
checks prerequisites/configuration/connectivity without starting services or
printing credentials. It does not start ADB or prove device connectivity: inspect
`adb devices` and `adb reverse --list` yourself. `doctor -- --backend-only` checks
the mobile bootstrap without requiring the Android SDK.

## First login and warehouse walkthrough

Enter admin **0000000001**, then demo OTP **123456**. For the assigned customer,
use **0000000002** and the same code. No SMS is sent. Only fictional numbers
0000000001–0000000009 work in explicit demo mode. OTP limits still apply (five
requests/hour, twenty/day); repeated automated runs consume those allowances.

1. As admin, open the seeded customer and create a GRN with the example item,
   100 bags at 10 kg each, a receipt date, and a rack. Note the GRN number.
2. Dispatch 20 bags from that GRN. Stock should be 80 bags / 800 kg. Reopening
   stock and customer reports should show the committed movement.
3. Sign out, then sign in as the assigned customer. View that customer's stock,
   add an item to a cart, change its quantity, and remove it. Customers cannot
   create GRNs, dispatch stock, or access another customer's images.
4. Sign back in as admin. Configure a monthly item price using `price_type` and
   `unit_price`. Dispatch the remaining stock before generating an invoice
   preview; preview requires a fully dispatched, uninvoiced GRN. Review rates,
   duration, labour, tax and rounding before saving.
5. Download a GRN, dispatch, invoice or customer-stock PDF. Documents use generic
   starter layouts. GRN/dispatch images use register → upload → confirm;
   deletion revokes metadata access and removes stored bytes. A storage cleanup
   failure is reported, not treated as complete deletion.

### Pricing and document customization

This is a customizable source template. Authorized warehouse staff can maintain
default or customer-specific item rates, pricing type, weight bands, labour,
tax and effective dates through Item Pricing. The billing-day calculation is a
code-level business-policy extension point, not a runtime end-user setting in
this release: customize the backend `calculate_invoice_duration` contract and
its invoice-preview/save consumers when onboarding a cold-storage operator that
uses different day, fortnight or month boundaries. Update `docs/INVOICE_RULES.md`
and the duration, preview and rounding fixtures with every policy change.

Generated PDFs are also starter templates. `COMPANY_NAME` supplies the displayed
cold-storage name, while `functions/_shared/document-html.ts` defines the shared
header, styling, metadata, table and footer used by GRN, dispatch, invoice and
stock PDFs. Customize that template for the operator's name, logo, address,
registration/tax details, terms and document header, then redeploy the PDF Edge
functions and verify all four private-document flows. This customization is
source/deployment work; the current app does not provide a branding editor.

`npm run test:api` in the backend creates fictional fixtures for these API flows.
The test uses a customer-specific monthly rate of 5, labour rate 2 and tax 5%.
For 100 units dispatched after 31 days in legacy duration mode, preview asserts
1.5 periods, storage 750, labour 200, subtotal 950, rounded tax 48 and total 998.
Existing invoice save accepts client-supplied totals and rounds total/tax upward
to whole units; it does not independently recalculate all supplied business values.
These are preserved demo rules. See the backend
[formula reference](https://github.com/abhiguru/supabase-warehouse-template/blob/main/docs/INVOICE_RULES.md)
for duration boundaries, row/header rounding and unsupported contracts.

## Architecture and contribution workflow

`app/` contains Expo Router screens. Mobile services call PostgREST RPCs and
private Storage; Redux holds UI state. Public bootstrap discovers the anon key.
Only SecureStore restores session identity. Public configuration is cached by
origin for one hour; full configuration uses origin/user/session for 60 seconds.
Logout/account changes invalidate pending work and authenticated configuration.
Server session checks, current roles and RLS remain authoritative.

The backend runs Kong, PostgREST, PostgreSQL, Storage, Edge functions and the PDF
renderer in a checkout-owned Compose project. Custom OTP sessions use opaque,
rotating refresh credentials; GoTrue is not the demo login path. PDF Edge
functions authorize the caller before rendering and private signed download.

For changes, branch from current main in both public repositories. Use `npm ci`;
commit lockfile changes deliberately. Mobile checks: `npm test`, `npm run typecheck`, `npm run lint`, `npm run test:setup`, `npx expo install --check`,
`npm audit`, and Android export/native validation when applicable. Backend
checks: `npm test`, `npm run test:migrations`, `npm run test:api`, and
`node scripts/check-mobile-contract.mjs ../rn-warehouse-template --live`.
Migration tests create/remove their own disposable database. Add a migration;
never edit an already applied migration or broaden grants to satisfy a screen.
Submit PRs and wait for required checks. Source-only demo releases retain the
separate production gate and preserve historical tags.

## Troubleshooting and shutdown

| Symptom | Action |
| --- | --- |
| Missing prerequisite | Run doctor; install prerequisites yourself, then retry. |
| Project belongs to another checkout | Export a unique `WAREHOUSE_PROJECT_NAME=warehouse-your-name` for every backend command. |
| Port conflict | Before starting a fresh checkout, select distinct unused API/HTTPS/Studio/DB/renderer ports in its generated env. Update both backend public URLs, the mobile origin and ADB reverse mapping. |
| Phone cannot fetch bootstrap | Verify USB authorization, selected device, reverse mappings, API health, and matching localhost origins. |
| Existing env rejected | Inspect only your checkout's settings; setup intentionally preserves them. Never overwrite another installation's credentials. |
| OTP throttled | Wait for the limit window; do not disable auth protections or reset a production database. |
| Session expired/offline | Restore connectivity and retry; definitive authorization rejection requires login. Logout clears local credentials even if server revocation cannot be reached. |
| Image cleanup failed | Metadata access is revoked, but a maintainer must inspect remaining bytes in this demo's private bucket before claiming complete removal. |
| Invoice preview unavailable | Fully dispatch the GRN, check its pricing configuration and ensure it is not already invoiced. |
| Decoder installation refused | Dependency version/content changed. Review the adapter and consumer tests; do not bypass postinstall or suppress the advisory. |

Stop Metro with Ctrl-C. In the backend checkout run `bash stop.sh`; restart with
`bash start.sh --demo`. Keep the same `WAREHOUSE_PROJECT_NAME` when customized.
Stop preserves database/files. Remove only the reverse mappings you created:
`adb reverse --remove tcp:18000` and `adb reverse --remove tcp:8081`.

## Unsupported and separately untested

Physical printing, sensors, Realtime, customer document uploads, production SMS,
barcode scanning and automatic offline/SQLite synchronization are unsupported.
Printing/sensor UI explains unavailability; hardware Edge endpoints return 503.
The imported dual-rate pricing overload is not the mobile contract and currently
fails its legacy table constraints; combined-rate semantics require a separate
review. Change-category filtering is unavailable; other change-log filters remain.
Payments/accounting integrations are not part of the documented demo workflow.

Production scale/security, native telemetry delivery, distribution signing,
retention enforcement, and privacy declarations remain separate checks. The
complete source-demo physical-iPhone evidence is recorded in the mobile handoff.
The scoped ownership and attribution review is complete; see
ATTRIBUTION_REVIEW.md. A successful bundle is not a physical-device test.
